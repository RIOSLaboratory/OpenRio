// OR_CACHE_MISSQ: ops needing replay -- payload, wait reason, wakeup, oldest-first select; two allocation ports (E3 / E4)
module dc_missq
  import or_cache_pkg::*;
(
  input  logic                   clk,
  input  logic                   rst_n,
  input  logic                   flush,
  // allocation port 0 (E3)
  input  logic                   alloc,
  input  dc_op_t                 alloc_op,
  input  mq_wait_e               alloc_wait,
  input  logic [MSHR_ID_W-1:0]   alloc_wait_id,    // for W_TLB, low TMQ_ID_W bits valid
  // allocation port 1 (E4: merge path creates part1 after cross-line part0 completes, ready)
  input  logic                   alloc1,
  input  dc_op_t                 alloc1_op,
  // wakeup events
  input  logic                   ptw_done,
  input  logic [TMQ_ID_W-1:0]    ptw_done_id,
  input  logic [4:0]             ptw_done_rcause,
  input  logic [4:0]             ptw_done_wcause,
  input  logic                   tlb_inval,
  input  logic                   mshr_done,
  input  logic [MSHR_ID_W-1:0]   mshr_done_id,
  input  logic                   isb_change,
  // select
  input  logic [SEQ_W-1:0]       cur_seq,
  output logic                   sel_valid,
  output dc_op_t                 sel_op,
  input  logic                   sel_take,
  output logic [MQ_IDX_W:0]      count
);
  logic                 v   [MISSQ_N];
  dc_op_t               op  [MISSQ_N];
  mq_wait_e             wt  [MISSQ_N];
  logic [MSHR_ID_W-1:0] wid [MISSQ_N];

  // a wait is woken this cycle; fault is brought in by the PTW response per class
  function automatic logic woken(input mq_wait_e w, input logic [MSHR_ID_W-1:0] id);
    case (w)
      W_NONE:     return 1'b1;
      W_TLB:      return tlb_inval || (ptw_done && (ptw_done_id == TMQ_ID_W'(id)));
      W_TLB_ANY:  return tlb_inval || ptw_done;
      W_MSHR:     return mshr_done && (mshr_done_id == id);
      W_MSHR_ANY: return mshr_done;
      W_ISB:      return isb_change;
      default:    return 1'b0;
    endcase
  endfunction

  function automatic dc_op_t apply_fault(input dc_op_t o, input mq_wait_e w, input logic [MSHR_ID_W-1:0] id);
    dc_op_t r;
    logic [4:0] c;
    r = o;
    c = is_store_class(o.prop) ? ptw_done_wcause : ptw_done_rcause;
    if ((w == W_TLB) && ptw_done && (ptw_done_id == TMQ_ID_W'(id)) && !tlb_inval && (c != 5'd0)) begin
      r.pre_fault = 1'b1;
      r.pre_cause = c;
    end
    return r;
  endfunction

  // select: oldest among ready entries (seq farthest from cur_seq)
  logic [MQ_IDX_W-1:0] sel_idx;
  always_comb begin
    logic [SEQ_W-1:0] best_age, age;
    sel_valid = 1'b0; sel_idx = '0; best_age = '0;
    for (int i = 0; i < MISSQ_N; i++) begin
      age = cur_seq - op[i].seq;
      if (v[i] && (wt[i] == W_NONE) && (!sel_valid || (age > best_age))) begin
        sel_valid = 1'b1; sel_idx = MQ_IDX_W'(i); best_age = age;
      end
    end
  end
  assign sel_op = op[sel_idx];

  // two free slots: port 0 takes the lowest-numbered, port 1 the highest-numbered
  logic                free_hit, free1_hit;
  logic [MQ_IDX_W-1:0] free_idx, free1_idx;
  always_comb begin
    free_hit = 1'b0; free_idx = '0; free1_hit = 1'b0; free1_idx = '0;
    for (int i = MISSQ_N-1; i >= 0; i--) if (!v[i]) begin free_hit = 1'b1; free_idx = MQ_IDX_W'(i); end
    for (int i = 0; i < MISSQ_N; i++) if (!v[i]) begin free1_hit = 1'b1; free1_idx = MQ_IDX_W'(i); end
  end

  always_comb begin
    count = '0;
    for (int i = 0; i < MISSQ_N; i++) count = count + (MQ_IDX_W+1)'(v[i]);
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      for (int i = 0; i < MISSQ_N; i++) begin v[i] <= 1'b0; op[i] <= '0; wt[i] <= W_NONE; wid[i] <= '0; end
    end else if (flush) begin
      for (int i = 0; i < MISSQ_N; i++) v[i] <= 1'b0;
    end else begin
      for (int i = 0; i < MISSQ_N; i++)
        if (v[i] && (wt[i] != W_NONE) && woken(wt[i], wid[i])) begin
          wt[i] <= W_NONE;
          op[i] <= apply_fault(op[i], wt[i], wid[i]);
        end
      if (sel_take) v[sel_idx] <= 1'b0;
      if (alloc) begin                      // same-cycle wakeup applies to the entry being allocated
        v[free_idx]   <= 1'b1;
        op[free_idx]  <= apply_fault(alloc_op, alloc_wait, alloc_wait_id);
        wt[free_idx]  <= woken(alloc_wait, alloc_wait_id) ? W_NONE : alloc_wait;
        wid[free_idx] <= alloc_wait_id;
      end
      if (alloc1) begin
        v[free1_idx]   <= 1'b1;
        op[free1_idx]  <= alloc1_op;
        wt[free1_idx]  <= W_NONE;
        wid[free1_idx] <= '0;
      end
    end
  end

`ifndef SYNTHESIS
  always_ff @(posedge clk) if (rst_n && !flush) begin
    if (alloc) assert (free_hit) else $error("[MISSQ] overflow");
    if (alloc1) assert (free1_hit && !(alloc && (free_idx == free1_idx))) else $error("[MISSQ] overflow (port 1)");
    if (sel_take) assert (sel_valid) else $error("[MISSQ] take without a ready entry");
  end
`endif
endmodule
