// IB_ENQ_WINDOW: S4 window that enqueues to BE IB (p1/IB.sv, the only IB in the whole pipeline), holds one line;
//               on alloc compacts valid slots into a contiguous sequence, each cycle offers ISSUE_W entries starting at rd_q, advances on enq handshake;
//               the next line can be allocated in the same cycle the whole line is delivered
module ib_enq_window
  import or_fe_pkg::*;
(
  input  logic                          clk,
  input  logic                          rst_n,
  // In-event
  input  logic                          alloc_hsk,     // PRECHECK whole-line handoff
  input  logic                          flush,
  // In Static Info (sampled on alloc_hsk)
  input  logic [SLOT_NUM-1:0][31:0]     alloc_inst,
  input  logic [SLOT_NUM-1:0][31:0]     alloc_raw,
  input  logic [SLOT_NUM-1:0]           alloc_is_rvc,
  input  logic [SLOT_NUM-1:0]           alloc_rvc_ill,
  input  operand_info_t [SLOT_NUM-1:0]  alloc_opnd,
  input  logic [VA_W-1:0]               alloc_pc,
  input  logic                          alloc_xline,
  input  logic [SLOT_NUM-1:0]           alloc_vmask,
  input  logic [SLOT_W-1:0]             alloc_end_slot,
  input  logic                          alloc_end_taken,
  input  logic [VA_W-1:0]               alloc_end_target,
  input  logic                          alloc_excp_vld,
  input  logic [CAUSE_W-1:0]            alloc_excp_cause,
  input  logic                          alloc_bpf_vld,
  input  logic [BPF_IDX_W-1:0]          alloc_bpf_idx,
  // In Static Info: BE IB's fe_ready
  input  logic [ISSUE_W-1:0]            enq_rdy,
  // Out Static Info
  output logic                          alloc_rdy,     // window empty, or last batch delivered this cycle
  output logic [ISSUE_W-1:0]            enq_vld,
  output ib_inst_t [ISSUE_W-1:0]        enq_payload
);

  // ---------------- compact on alloc ----------------
  logic [SLOT_NUM-1:0][SLOT_W-1:0] c_slot;
  logic [SLOT_W:0]                 c_cnt;

  always_comb begin
    c_slot = '0;
    c_cnt  = '0;
    for (int s = 0; s < SLOT_NUM; s++) begin
      if (alloc_vmask[s]) begin
        c_slot[c_cnt[SLOT_W-1:0]] = SLOT_W'(s);
        c_cnt = c_cnt + (SLOT_W+1)'(1);
      end
    end
  end

  // ---------------- window registers ----------------
  logic                            vld_q;
  logic [SLOT_W:0]                 rd_q;          // entries of this line already delivered
  logic [SLOT_W:0]                 cnt_q;         // total entries of this line to deliver (1 for an exception line)
  logic [SLOT_NUM-1:0][SLOT_W-1:0] slot_q;        // original slot of compacted entry j
  logic [SLOT_NUM-1:0][31:0]       inst_q;
  logic [SLOT_NUM-1:0][31:0]       raw_q;
  logic [SLOT_NUM-1:0]             is_rvc_q;
  logic [SLOT_NUM-1:0]             rvc_ill_q;
  operand_info_t [SLOT_NUM-1:0]    opnd_q;
  logic [VA_W-1:0]                 pc_q;
  logic                            xline_q;
  logic [SLOT_W-1:0]               end_slot_q;
  logic                            end_taken_q;
  logic [VA_W-1:0]                 end_target_q;
  logic                            excp_vld_q;
  logic [CAUSE_W-1:0]              excp_cause_q;
  logic                            bpf_vld_q;
  logic [BPF_IDX_W-1:0]            bpf_idx_q;

  // ---------------- delivery and advance ----------------
  logic [SLOT_W:0]                 rem_cnt;
  logic [ISSUE_W-1:0]              enq_hsk;
  logic [$clog2(ISSUE_W+1)-1:0]    acc_cnt;
  logic                            consume_fire;
  logic                            pop_fire;

  assign rem_cnt = cnt_q - rd_q;

  always_comb begin
    for (int k = 0; k < ISSUE_W; k++) begin
      // in the flush cycle (Backend redirect arrives after being registered by BE_CTRL_REG) do not deliver to IB: IB is no longer flushing in this cycle and would accept it
      enq_vld[k] = vld_q && ((SLOT_W+1)'(k) < rem_cnt) && !flush;
    end
    enq_hsk = enq_vld & enq_rdy;
    acc_cnt = '0;
    for (int k = 0; k < ISSUE_W; k++) begin
      acc_cnt = acc_cnt + ($clog2(ISSUE_W+1))'(enq_hsk[k]);
    end
  end

  assign consume_fire = vld_q & (acc_cnt != '0) & ((SLOT_W+1)'(acc_cnt) < rem_cnt) & ~flush;
  assign pop_fire     = vld_q & ((SLOT_W+1)'(acc_cnt) == rem_cnt) & ~flush;
  assign alloc_rdy    = ~vld_q | pop_fire;

  // ---------------- output lane k = entry rd_q + k of the compacted sequence ----------------
  always_comb begin
    logic [SLOT_W-1:0] j;
    logic [SLOT_W-1:0] s;
    for (int k = 0; k < ISSUE_W; k++) begin
      j = rd_q[SLOT_W-1:0] + SLOT_W'(k);
      s = slot_q[j];
      enq_payload[k] = '0;
      if (excp_vld_q) begin
        // fetch exception: when the second half of a cross-line instruction faults in this line, the exception belongs to that instruction (pc = line base - 2), tval is the faulting address
        enq_payload[k].pc          = xline_q ? (line_base(pc_q) - VA_W'(2)) : pc_q;
        enq_payload[k].raw         = 32'h0000_0013;
        enq_payload[k].excp_tval   = pc_q;
        enq_payload[k].excp_vld    = 1'b1;
        enq_payload[k].excp_cause  = excp_cause_q;
        enq_payload[k].bpf_slot    = slot_of(pc_q);
      end else begin
        enq_payload[k].pc          = ((s == '0) && xline_q) ? (line_base(pc_q) - VA_W'(2))
                                                            : (line_base(pc_q) + VA_W'({s, 1'b0}));
        enq_payload[k].inst        = inst_q[j];
        enq_payload[k].raw         = raw_q[j];
        enq_payload[k].is_rvc      = is_rvc_q[j];
        enq_payload[k].rvc_ill     = rvc_ill_q[j];
        enq_payload[k].opnd        = opnd_q[j];
        enq_payload[k].pred_taken  = end_taken_q && (s == end_slot_q);
        enq_payload[k].pred_target = end_target_q;
        enq_payload[k].bpf_vld     = bpf_vld_q;
        enq_payload[k].bpf_idx     = bpf_idx_q;
        enq_payload[k].bpf_slot    = s;
      end
    end
  end

  // ---------------- state ----------------
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      vld_q <= 1'b0;
      rd_q  <= '0;
    end else if (flush) begin
      vld_q <= 1'b0;
      rd_q  <= '0;
    end else if (alloc_hsk) begin
      vld_q <= 1'b1;
      rd_q  <= '0;
    end else if (pop_fire) begin
      vld_q <= 1'b0;
      rd_q  <= '0;
    end else if (consume_fire) begin
      rd_q  <= rd_q + (SLOT_W+1)'(acc_cnt);
    end
  end

  always_ff @(posedge clk) begin
    if (alloc_hsk && !flush) begin
      cnt_q        <= alloc_excp_vld ? (SLOT_W+1)'(1) : c_cnt;
      slot_q       <= c_slot;
      for (int j = 0; j < SLOT_NUM; j++) begin
        inst_q[j]    <= alloc_inst[c_slot[j]];
        raw_q[j]     <= alloc_raw[c_slot[j]];
        is_rvc_q[j]  <= alloc_is_rvc[c_slot[j]];
        rvc_ill_q[j] <= alloc_rvc_ill[c_slot[j]];
        opnd_q[j]    <= alloc_opnd[c_slot[j]];
      end
      pc_q         <= alloc_pc;
      xline_q      <= alloc_xline;
      end_slot_q   <= alloc_end_slot;
      end_taken_q  <= alloc_end_taken;
      end_target_q <= alloc_end_target;
      excp_vld_q   <= alloc_excp_vld;
      excp_cause_q <= alloc_excp_cause;
      bpf_vld_q    <= alloc_bpf_vld;
      bpf_idx_q    <= alloc_bpf_idx;
    end
  end

`ifndef SYNTHESIS
  // alloc_hsk allowed only when the window can be loaded
  always_ff @(posedge clk) begin
    if (alloc_hsk && !flush) begin
      assert (alloc_rdy) else $error("IB_ENQ_WINDOW alloc while not ready");
    end
  end
`endif

endmodule
