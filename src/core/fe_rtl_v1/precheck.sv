// PRECHECK: S3 per-slot compare of three candidate sources + single earliest redirect by slot
module precheck
  import or_fe_pkg::*;
(
  input  logic                          clk,
  input  logic                          rst_n,
  // In-event
  input  logic                          alloc_hsk,
  input  logic                          line_kill,
  // In Static Info
  input  logic                          line_vld,
  input  logic [VA_W-1:0]               line_pc,
  input  logic [SLOT_NUM-1:0]           valid,
  input  logic [SLOT_NUM-1:0]           start,
  input  bp_type_t [SLOT_NUM-1:0]       btype,
  input  logic [SLOT_NUM-1:0][VA_W-1:0] ipc,
  input  logic [SLOT_NUM-1:0][VA_W-1:0] ret_pc,
  input  logic                          excp_vld,
  input  logic [CAUSE_W-1:0]            excp_cause,
  input  l1btb_meta_t                   meta,
  input  logic [SLOT_NUM-1:0]           dj_vld,
  input  logic [SLOT_NUM-1:0][VA_W-1:0] dj_target,
  input  logic [SLOT_NUM-1:0]           ras_vld,
  input  logic [VA_W-1:0]               ras_target,
  input  logic [BPF_IDX_W-1:0]          bpf_alloc_idx,
  // Out-event: redirect
  output logic                          redirect,
  output logic [VA_W-1:0]               redirect_pc,
  // Out-event: ras_op
  output logic                          ras_op,
  output logic                          ras_op_push,
  output logic                          ras_op_pop,
  output logic [VA_W-1:0]               ras_op_push_pc,
  // Out-event: bpf_alloc
  output logic                          bpf_alloc,
  output logic [VA_W-1:0]               bpf_alloc_line_pc,
  output l1btb_meta_t                   bpf_alloc_meta,
  output logic [SLOT_NUM-1:0]           bpf_alloc_br_mask,
  output logic                          bpf_alloc_xline,
  // Out-event: btb_clear
  output logic                          btb_clear,
  output logic [VA_W-1:0]               btb_clear_pc,
  output logic [BTB_WAY_W-1:0]          btb_clear_way,
  // Out Static Info: ib_ctrl (loaded into IB_ENQ_WINDOW with this line on prechk_ib_alloc_hsk)
  output logic [SLOT_NUM-1:0]           ib_alloc_vmask,
  output logic [SLOT_W-1:0]             ib_alloc_end_slot,
  output logic                          ib_alloc_end_taken,
  output logic [VA_W-1:0]               ib_alloc_end_target,
  output logic                          ib_alloc_excp_vld,
  output logic [CAUSE_W-1:0]            ib_alloc_excp_cause,
  output logic                          ib_alloc_bpf_vld,
  output logic [BPF_IDX_W-1:0]          ib_alloc_bpf_idx
);

  logic done_q;

  // ---------------- per-slot decision ----------------
  logic [SLOT_NUM-1:0]           tk_here;
  logic [SLOT_NUM-1:0]           in_rng;
  logic [SLOT_NUM-1:0]           fh;
  logic [SLOT_NUM-1:0]           dir_need;
  logic [SLOT_NUM-1:0]           ret_need;
  logic [SLOT_NUM-1:0]           need;
  logic [SLOT_NUM-1:0][VA_W-1:0] seq_after;
  logic [SLOT_NUM-1:0][VA_W-1:0] fh_tgt;
  logic [SLOT_NUM-1:0][VA_W-1:0] tgt;
  logic                          nxt_found;

  always_comb begin
    for (int s = 0; s < SLOT_NUM; s++) begin
      tk_here[s]  = meta.taken && (meta.tk_slot == SLOT_W'(s));
      in_rng[s]   = !meta.taken || (SLOT_W'(s) <= meta.tk_slot);
      fh[s]       = tk_here[s] && (!valid[s] || (btype[s] == BP_NO_BR));
      dir_need[s] = dj_vld[s] && (tk_here[s] ? (meta.tk_target != dj_target[s]) : (btype[s] != BP_BR));
      ret_need[s] = ras_vld[s] && (!tk_here[s] || (meta.tk_target != ras_target));
      need[s]     = !excp_vld && in_rng[s] && (fh[s] || dir_need[s] || ret_need[s]);
      // seq_after[s]: pc of the first start after slot s, or the next line base if none
      seq_after[s] = line_base(line_pc) + VA_W'(FETCH_BYTES);
      nxt_found    = 1'b0;
      for (int p = s + 1; p < SLOT_NUM; p++) begin
        if (start[p] && !nxt_found) begin
          seq_after[s] = ipc[p];
          nxt_found    = 1'b1;
        end
      end
      fh_tgt[s] = (start[s] && !valid[s]) ? ipc[s] : seq_after[s];
      tgt[s]    = fh[s] ? fh_tgt[s] : (dir_need[s] ? dj_target[s] : ras_target);
    end
  end

  logic              win_vld;
  logic [SLOT_W-1:0] win_slot;
  logic [VA_W-1:0]   win_target;

  slot_arb u_slot_arb (
    .need       (need),
    .target     (tgt),
    .win_vld    (win_vld),
    .win_slot   (win_slot),
    .win_target (win_target)
  );

  // ---------------- redirect (same cycle in S3, once per line) ----------------
  assign redirect     = line_vld & win_vld & ~done_q;
  assign redirect_pc = win_target;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      done_q <= 1'b0;
    end else if (alloc_hsk || line_kill) begin
      done_q <= 1'b0;
    end else if (redirect) begin
      done_q <= 1'b1;
    end
  end

  // ---------------- truncation and submission ----------------
  logic [SLOT_W-1:0]   end_slot;
  logic [SLOT_NUM-1:0] vmask;
  logic [SLOT_NUM-1:0] br_mask;
  logic [SLOT_NUM-1:0] rs;
  logic [SLOT_W-1:0]   c;

  function automatic logic is_push(input bp_type_t t);
    return (t == BP_FCALL) || (t == BP_INFCALL) || (t == BP_FRC);
  endfunction

  function automatic logic is_pop(input bp_type_t t);
    return (t == BP_FRET) || (t == BP_FRC);
  endfunction

  assign end_slot = win_vld ? win_slot : (meta.taken ? meta.tk_slot : SLOT_W'(SLOT_NUM - 1));

  always_comb begin
    for (int s = 0; s < SLOT_NUM; s++) begin
      vmask[s]   = valid[s] && (SLOT_W'(s) <= end_slot);
      br_mask[s] = vmask[s] && (btype[s] != BP_NO_BR);
      rs[s]      = vmask[s] && (is_push(btype[s]) || is_pop(btype[s]));
    end
    c = '0;
    for (int s = SLOT_NUM - 1; s >= 0; s--) begin
      if (rs[s]) c = SLOT_W'(s);
    end
  end

  assign ras_op         = alloc_hsk & (|rs);
  assign ras_op_push    = is_push(btype[c]);
  assign ras_op_pop     = is_pop(btype[c]);
  assign ras_op_push_pc = ret_pc[c];

  assign bpf_alloc         = alloc_hsk & (|br_mask);
  assign bpf_alloc_line_pc = line_pc;
  assign bpf_alloc_meta    = meta;
  assign bpf_alloc_br_mask = br_mask;
  assign bpf_alloc_xline   = (ipc[0] != line_base(line_pc));

  assign btb_clear     = alloc_hsk & win_vld & fh[win_slot];
  assign btb_clear_pc  = line_pc;
  assign btb_clear_way = meta.tk_way;

  assign ib_alloc_vmask      = vmask;
  assign ib_alloc_end_slot   = end_slot;
  assign ib_alloc_end_taken  = win_vld ? ~fh[win_slot] : meta.taken;
  assign ib_alloc_end_target = win_vld ? win_target : meta.tk_target;
  assign ib_alloc_excp_vld   = excp_vld;
  assign ib_alloc_excp_cause = excp_cause;
  assign ib_alloc_bpf_vld    = |br_mask;
  assign ib_alloc_bpf_idx    = bpf_alloc_idx;

endmodule
