// BPF: history ring of prediction contexts; pairs branch pc with Backend's predictor_update to generate L1BTB training writes
//
// Backend only returns the branch pc (no bpf index), so BPF keeps a ring of "the contexts of the most recent BPF_DEPTH fetch lines":
//   - alloc always accepted, overwrites the oldest entry when full (ready always 1, no backpressure on S3);
//   - commit looks up by pc in the ring for the youngest entry whose slot is a branch, and uses its meta to decide UPD / ALLOC;
//   - not reclaimed on flush: entries are only historical contexts, not in-flight state.
module bpf
  import or_fe_pkg::*;
(
  input  logic                  clk,
  input  logic                  rst_n,
  // In-event
  input  logic                  alloc,
  input  logic [VA_W-1:0]       alloc_line_pc,
  input  l1btb_meta_t           alloc_meta,
  input  logic [SLOT_NUM-1:0]   alloc_br_mask,
  input  logic                  alloc_xline,
  input  logic                  clear,
  input  logic [VA_W-1:0]       clear_pc,
  input  logic [BTB_WAY_W-1:0]  clear_way,
  input  logic                  commit,
  input  logic [VA_W-1:0]       commit_pc,
  input  logic                  commit_taken,
  input  logic [VA_W-1:0]       commit_target,
  input  bp_type_t              commit_type,
  // Out-event
  output logic                  l1_update,
  output logic [VA_W-1:0]       upd_pc,
  output logic [BTB_WAY_W-1:0]  upd_way,
  output btb_wr_mode_t          upd_mode,
  output logic [SLOT_W-1:0]     upd_slot,
  output bp_type_t              upd_type,
  output logic [1:0]            upd_ctr,
  output logic [VA_W-1:0]       upd_target,
  output logic                  upd_wr_tgt,
  // Out Static Info
  output logic                  alloc_rdy,
  output logic [BPF_IDX_W-1:0]  alloc_idx
);

  logic [VA_W-1:0]      line_pc_q [BPF_DEPTH];
  l1btb_meta_t          meta_q    [BPF_DEPTH];
  logic [SLOT_NUM-1:0]  br_mask_q [BPF_DEPTH];
  logic [BPF_DEPTH-1:0] xline_q;
  logic [BPF_DEPTH-1:0] vld_q;
  logic [BPF_IDX_W-1:0] wptr_q;
  logic                 clr_pend_q;
  logic [VA_W-1:0]      clr_pc_q;
  logic [BTB_WAY_W-1:0] clr_way_q;
  logic [BTB_WAY_W-1:0] victim_q;

  // ---------------- lookup ----------------
  // instruction address of slot s in entry e: slot 0 of an xline entry is the cross-line instruction, starting at line base - 2
  logic [BPF_DEPTH-1:0]              m_vec;
  logic [BPF_DEPTH-1:0][SLOT_W-1:0]  m_slot;
  logic                              m_any;
  logic [BPF_IDX_W-1:0]              m_idx;
  logic [SLOT_W-1:0]                 c_slot;

  always_comb begin
    for (int e = 0; e < BPF_DEPTH; e++) begin
      if (xline_q[e] && (commit_pc == line_base(line_pc_q[e]) - VA_W'(2))) begin
        m_slot[e] = '0;
      end else begin
        m_slot[e] = slot_of(commit_pc);
      end
      m_vec[e] = vld_q[e] &&
                 ((xline_q[e] && (commit_pc == line_base(line_pc_q[e]) - VA_W'(2))) ||
                  (line_base(commit_pc) == line_base(line_pc_q[e]))) &&
                 br_mask_q[e][m_slot[e]];
    end
    // youngest: search back from wptr-1 for the first hit
    m_any = 1'b0;
    m_idx = '0;
    for (int d = 1; d <= BPF_DEPTH; d++) begin
      if (!m_any && m_vec[BPF_IDX_W'(wptr_q - BPF_IDX_W'(d))]) begin
        m_any = 1'b1;
        m_idx = BPF_IDX_W'(wptr_q - BPF_IDX_W'(d));
      end
    end
  end

  assign c_slot = m_slot[m_idx];

  // ---------------- training write ----------------
  /* verilator lint_off UNUSEDSIGNAL */
  l1btb_meta_t          ent_meta;   // only hit_w, slot_w, ctr_w are read
  /* verilator lint_on UNUSEDSIGNAL */
  logic [BTB_WAYS-1:0]  hw_vec;
  logic                 hit_any;
  logic [BTB_WAY_W-1:0] hw;
  logic                 upd_commit;
  logic                 clr_wr;

  assign ent_meta = meta_q[m_idx];

  always_comb begin
    for (int w = 0; w < BTB_WAYS; w++) begin
      hw_vec[w] = ent_meta.hit_w[w] && (ent_meta.slot_w[w] == c_slot);
    end
    hw = '0;
    for (int w = BTB_WAYS - 1; w >= 0; w--) begin
      if (hw_vec[w]) hw = BTB_WAY_W'(w);
    end
  end

  assign hit_any    = |hw_vec;
  assign upd_commit = commit & m_any & (hit_any | commit_taken);
  assign clr_wr  = clr_pend_q & ~upd_commit;

  assign l1_update  = upd_commit | clr_wr;
  assign upd_pc     = upd_commit ? line_pc_q[m_idx] : clr_pc_q;
  assign upd_way    = upd_commit ? (hit_any ? hw : victim_q) : clr_way_q;
  assign upd_mode   = upd_commit ? (hit_any ? BTB_UPD : BTB_ALLOC) : BTB_CLR;
  assign upd_slot   = c_slot;
  assign upd_type   = commit_type;
  assign upd_ctr    = hit_any ? sat_ctr(ent_meta.ctr_w[hw], commit_taken) : CTR_WT;
  assign upd_target = commit_target;
  assign upd_wr_tgt = commit_taken;

  // ---------------- ring ----------------
  assign alloc_rdy     = 1'b1;
  assign alloc_idx = wptr_q;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      wptr_q     <= '0;
      vld_q      <= '0;
      clr_pend_q <= 1'b0;
      victim_q   <= '0;
    end else begin
      if (alloc) begin
        wptr_q         <= wptr_q + 1'b1;
        vld_q[wptr_q]  <= 1'b1;
      end
      if (clear) begin
        clr_pend_q <= 1'b1;
      end else if (clr_wr) begin
        clr_pend_q <= 1'b0;
      end
      if (upd_commit && !hit_any) begin
        victim_q <= (victim_q == BTB_WAY_W'(BTB_WAYS - 1)) ? '0 : victim_q + 1'b1;
      end
    end
  end

  always_ff @(posedge clk) begin
    if (alloc) begin
      line_pc_q[wptr_q] <= alloc_line_pc;
      meta_q[wptr_q]    <= alloc_meta;
      br_mask_q[wptr_q] <= alloc_br_mask;
      xline_q[wptr_q]   <= alloc_xline;
    end
    if (clear) begin
      clr_pc_q  <= clear_pc;
      clr_way_q <= clear_way;
    end
  end

endmodule
