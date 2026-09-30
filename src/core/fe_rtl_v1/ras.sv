// RAS: speculative / committed return address stack, S3 peek, speculative update on prechk_ib_alloc_hsk
//
// the committed stack is maintained by RAS itself: each call/ret IB delivers to Backend is recorded in program order in the in-flight queue;
// for each instruction (pc) Backend commits, if it equals the queue-head pc it is dequeued and applied to the committed stack.
// on Backend redirect, same-cycle commits are processed first, then the in-flight queue is cleared and the speculative stack is restored to the committed stack.
module ras
  import or_fe_pkg::*;
(
  input  logic                        clk,
  input  logic                        rst_n,
  // In-event
  input  logic                        op,
  input  logic                        op_push,
  input  logic                        op_pop,
  input  logic [VA_W-1:0]             op_push_pc,
  input  logic [ISSUE_W-1:0]          enq_hsk,          // IB lane k delivered to Backend this cycle
  input  logic [ISSUE_W-1:0]          commit,       // Backend lane k committed this cycle (registered via BE_CTRL_REG)
  input  logic                        recover,
  // In Static Info
  input  logic [SLOT_NUM-1:0]         valid,
  input  bp_type_t [SLOT_NUM-1:0]     btype,
  input  ib_inst_t [ISSUE_W-1:0]      enq_inst,
  input  logic [ISSUE_W-1:0][VA_W-1:0] commit_pc,
  // Out Static Info
  output logic [SLOT_NUM-1:0]         cand_vld,
  output logic [VA_W-1:0]             cand_target
);

  typedef struct packed {
    logic [RAS_DEPTH-1:0][VA_W-1:0] stk;
    logic [RAS_PTR_W-1:0]           sp;
    logic [RAS_CNT_W-1:0]           cnt;
  } stack_t;

  typedef struct packed {
    logic [VA_W-1:0] pc;
    logic            push;
    logic            pop;
    logic [VA_W-1:0] ret_pc;
  } cq_ent_t;

  // stack_upd: pop then push / push / pop
  function automatic stack_t stack_upd(input stack_t s, input logic push, input logic pop,
                                       input logic [VA_W-1:0] pc);
    stack_t r;
    r = s;
    if (push && pop) begin
      if (s.cnt == '0) begin
        r.stk[s.sp] = pc;
        r.sp        = s.sp + 1'b1;
        r.cnt       = RAS_CNT_W'(1);
      end else begin
        r.stk[s.sp - 1'b1] = pc;
      end
    end else if (push) begin
      r.stk[s.sp] = pc;
      r.sp        = s.sp + 1'b1;
      r.cnt       = (s.cnt == RAS_CNT_W'(RAS_DEPTH)) ? s.cnt : s.cnt + 1'b1;
    end else if (pop) begin
      if (s.cnt != '0) begin
        r.sp  = s.sp - 1'b1;
        r.cnt = s.cnt - 1'b1;
      end
    end
    return r;
  endfunction

  function automatic logic is_push(input bp_type_t t);
    return (t == BP_FCALL) || (t == BP_INFCALL) || (t == BP_FRC);
  endfunction

  function automatic logic is_pop(input bp_type_t t);
    return (t == BP_FRET) || (t == BP_FRC);
  endfunction

  logic [RAS_DEPTH-1:0][VA_W-1:0] spec_stk_q, cmt_stk_q;
  logic [RAS_PTR_W-1:0]           spec_sp_q,  cmt_sp_q;
  logic [RAS_CNT_W-1:0]           spec_cnt_q, cmt_cnt_q;
  stack_t                         spec_q, cmt_q;
  stack_t                         spec_n, cmt_n;

  assign spec_q = '{stk: spec_stk_q, sp: spec_sp_q, cnt: spec_cnt_q};
  assign cmt_q  = '{stk: cmt_stk_q,  sp: cmt_sp_q,  cnt: cmt_cnt_q};
  cq_ent_t [RAS_CQ_DEPTH-1:0]     cq_q;
  logic [RAS_CQ_W:0]              cq_head_q, cq_tail_q;

  // ---------------- commit matching: committed stack ----------------
  logic [RAS_CQ_W:0]              head_n;

  always_comb begin
    cq_ent_t e;
    cmt_n  = cmt_q;
    head_n = cq_head_q;
    for (int k = 0; k < ISSUE_W; k++) begin
      e = cq_q[head_n[RAS_CQ_W-1:0]];
      if (commit[k] && (head_n != cq_tail_q) && (e.pc == commit_pc[k])) begin
        cmt_n      = stack_upd(cmt_n, e.push, e.pop, e.ret_pc);
        head_n     = head_n + 1'b1;
      end
    end
  end

  // ---------------- delivery record: in-flight queue enqueue ----------------
  logic [ISSUE_W-1:0]             d_is;
  cq_ent_t [ISSUE_W-1:0]          d_ent;

  always_comb begin
    bp_type_t t;
    for (int k = 0; k < ISSUE_W; k++) begin
      t              = bp_classify(enq_inst[k].inst);
      d_is[k]        = enq_hsk[k] && !enq_inst[k].excp_vld && (is_push(t) || is_pop(t));
      d_ent[k].pc     = enq_inst[k].pc;
      d_ent[k].push   = is_push(t);
      d_ent[k].pop    = is_pop(t);
      d_ent[k].ret_pc = enq_inst[k].pc + (enq_inst[k].is_rvc ? VA_W'(2) : VA_W'(4));
    end
  end

  // ---------------- speculative stack ----------------
  always_comb begin
    if (recover) begin
      spec_n = cmt_n;
    end else if (op) begin
      spec_n = stack_upd(spec_q, op_push, op_pop, op_push_pc);
    end else begin
      spec_n = spec_q;
    end
  end

  // ---------------- state ----------------
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      spec_sp_q  <= '0;
      spec_cnt_q <= '0;
      cmt_sp_q   <= '0;
      cmt_cnt_q  <= '0;
      cq_head_q  <= '0;
      cq_tail_q  <= '0;
    end else begin
      spec_sp_q  <= spec_n.sp;
      spec_cnt_q <= spec_n.cnt;
      cmt_sp_q   <= cmt_n.sp;
      cmt_cnt_q  <= cmt_n.cnt;
      if (recover) begin
        // same-cycle commits already counted in cmt_n; all remaining in-flight entries are wrong-path
        cq_head_q <= '0;
        cq_tail_q <= '0;
      end else begin
        logic [RAS_CQ_W:0] tail;
        tail = cq_tail_q;
        for (int k = 0; k < ISSUE_W; k++) begin
          // drop when full (only affects committed stack accuracy, not correctness)
          if (d_is[k] && ((tail - head_n) < (RAS_CQ_W+1)'(RAS_CQ_DEPTH))) begin
            tail = tail + 1'b1;
          end
        end
        cq_head_q <= head_n;
        cq_tail_q <= tail;
      end
    end
  end

  always_ff @(posedge clk) begin
    spec_stk_q <= spec_n.stk;
    cmt_stk_q  <= cmt_n.stk;
    if (!recover) begin
      logic [RAS_CQ_W:0] tail;
      tail = cq_tail_q;
      for (int k = 0; k < ISSUE_W; k++) begin
        if (d_is[k] && ((tail - head_n) < (RAS_CQ_W+1)'(RAS_CQ_DEPTH))) begin
          cq_q[tail[RAS_CQ_W-1:0]] <= d_ent[k];
          tail = tail + 1'b1;
        end
      end
    end
  end

`ifndef SYNTHESIS
  // in-flight call/ret should not exceed the queue depth (sum of Backend IB + ROB)
  always_ff @(posedge clk) begin
    if (!recover) begin
      for (int k = 0; k < ISSUE_W; k++) begin
        assert (!(d_is[k] && ((cq_tail_q - head_n) >= (RAS_CQ_W+1)'(RAS_CQ_DEPTH))))
          else $error("RAS commit queue overflow");
      end
    end
  end
`endif

  // ---------------- candidate ----------------
  logic top_vld;
  assign top_vld     = (spec_q.cnt != '0);
  assign cand_target = spec_q.stk[spec_q.sp - 1'b1];

  always_comb begin
    for (int s = 0; s < SLOT_NUM; s++) begin
      cand_vld[s] = valid[s] && ((btype[s] == BP_FRET) || (btype[s] == BP_FRC)) && top_vld;
    end
  end

endmodule
