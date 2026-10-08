// OR_FE_top: OR_FE top-level integration; the top itself holds the registers of the three inter-stage handoff channels (valid, pc and
//            the Expand data of the predecoded result line), and generates each channel's rdy / hsk and post-clear valid
//   channel naming: <src>_<dst>, valid register <chan>_vld_q, valid this cycle and not cleared <chan>_vld,
//                   receiver can accept <chan>_rdy, handoff this cycle <chan>_hsk
//     pcgen_ic         PC_GEN fetch request   → ICACHE / ITLB / L1BTB                                   (S0 → S1)
//     ic_predcd        ICACHE result line     → PREDECODE / INSTR_DATA_EXPAND                           (S1 → S2)
//     predcd_prechk    predecoded result line → PRECHECK / DIRECT_JUMP / RAS                            (S2 → S3)
//     prechk_ib_alloc  PRECHECK whole line    → IB_ENQ_WINDOW, same cycle writes BPF and submits to RAS  (S3 → S4)
module or_fe_top
  import or_fe_pkg::*;
(
  input  logic                          clk,
  input  logic                          rst_n,
  // ---------------- Backend ----------------
  input  logic                          be_redirect,
  input  logic [VA_W-1:0]               be_redirect_pc,
  input  logic                          be_commit_br,
  input  logic [VA_W-1:0]               be_commit_br_pc,
  input  logic                          be_commit_br_taken,
  input  logic [VA_W-1:0]               be_commit_br_target,
  input  bp_type_t                      be_commit_br_type,
  input  logic [ISSUE_W-1:0]            be_commit,          // Backend commit (lane 0 is older)
  input  logic [ISSUE_W-1:0][VA_W-1:0]  be_commit_pc,
  input  logic                          be_sfence,
  input  logic                          be_fence_i,
  // ---------------- BE IB enqueue (connected to backend_top's fe_valid / fe_instr_pld / fe_ready via be_tb_top glue logic) ----------------
  output logic [ISSUE_W-1:0]            ib_enq_vld,
  output ib_inst_t [ISSUE_W-1:0]        ib_enq_payload,
  input  logic [ISSUE_W-1:0]            ib_enq_rdy,
  // ---------------- L2TLB / PTW (isa_model) ----------------
  output logic                          ptw_req_vld,
  output logic [VPN_W-1:0]              ptw_req_vpn,
  input  logic                          ptw_req_ready,
  input  logic                          ptw_resp,
  input  logic [PPN_W-1:0]              ptw_resp_ppn,
  input  pg_lvl_t                       ptw_resp_lvl,
  input  logic                          ptw_resp_x,
  input  logic                          ptw_resp_u,
  input  logic [1:0]                    ptw_resp_pbmt,
  input  logic                          ptw_resp_fault,
  input  logic [CAUSE_W-1:0]            ptw_resp_cause,
  // ---------------- L2 Icache / Memory (isa_model) ----------------
  output logic                          l2_req_vld,
  output logic [MSHR_ID_W-1:0]          l2_req_id,
  output logic [PA_W-OFF_W-1:0]         l2_req_pa_line,
  input  logic                          l2_req_ready,
  output logic                          l2_cancel,
  output logic [MSHR_ID_W-1:0]          l2_cancel_id,
  input  logic                          l2_resp,
  input  logic [MSHR_ID_W-1:0]          l2_resp_id,
  input  logic [LINE_W-1:0]             l2_resp_data,
  // ---------------- misc ----------------
  input  logic [VA_W-1:0]               boot_pc,
  input  logic                          sleep_req,
  input  logic                          csr_vm_en,
  input  priv_t                         csr_priv,
  input  logic [PMP_CFG_W-1:0]          csr_pmp_cfg
);

  // =====================================================================
  // submodule output wires: <module>_<port>
  // =====================================================================
  // PC_GEN
  logic                  pcgen_fetch_req_vld;
  logic [VA_W-1:0]       pcgen_fetch_pc;
  // BE_CTRL_REG
  logic                  bectl_redirect;
  logic [VA_W-1:0]       bectl_redirect_pc;
  logic                  bectl_flush;
  logic                  bectl_commit_br;
  logic [VA_W-1:0]       bectl_commit_br_pc;
  logic                  bectl_commit_br_taken;
  logic [VA_W-1:0]       bectl_commit_br_target;
  bp_type_t              bectl_commit_br_type;
  logic [ISSUE_W-1:0]    bectl_commit;
  logic [ISSUE_W-1:0][VA_W-1:0] bectl_commit_pc;
  logic                  bectl_tlb_flush;
  logic                  bectl_ic_inv;
  logic                  bectl_sleep_flush;
  logic                  bectl_sleep_stall;
  logic                  bectl_vm_en;
  priv_t                 bectl_priv;
  logic [PMP_CFG_W-1:0]  bectl_pmp_cfg;
  // FLUSH_CONTROL
  logic                  pcgen_ic_kill, ic_predcd_kill, predcd_prechk_kill;
  logic                  flush_ifu_flush, flush_xline_clear, flush_ib_enq_flush, flush_ras_recover;
  // ITLB
  logic                  itlb_refill_done;
  logic                  itlb_hit;
  logic [IC_TAG_W-1:0]   itlb_pa_tag;
  logic                  itlb_excp_vld;
  logic [CAUSE_W-1:0]    itlb_excp_cause;
  logic                  itlb_ptw_idle;
  // ICACHE
  logic                  ic_miss_drop;
  logic                  ic_replay;
  logic [VA_W-1:0]       ic_replay_pc;
  logic                  ic_req_rdy;
  logic                  ic_rsp_vld;
  logic [SLOT_NUM-1:0][15:0] ic_rsp_half;
  logic                  ic_rsp_excp_vld;
  logic [CAUSE_W-1:0]    ic_rsp_excp_cause;
  // L1BTB
  logic                  l1btb_redirect;
  logic [VA_W-1:0]       l1btb_redirect_pc;
  logic                  l1btb_pred_taken;
  l1btb_meta_t           l1btb_meta;
  // INSTR_DATA_EXPAND
  logic [SLOT_NUM-1:0][31:0] expd_inst;
  logic [SLOT_NUM-1:0][31:0] expd_raw;
  logic [SLOT_NUM-1:0]   expd_is_rvc;
  logic [SLOT_NUM-1:0]   expd_rvc_ill;
  operand_info_t [SLOT_NUM-1:0] expd_opnd;
  // PREDECODE
  logic                  predcd_xline_vld;
  logic [15:0]           predcd_xline_half;
  logic [SLOT_NUM-1:0]   predcd_dec_vld;
  logic [SLOT_NUM-1:0]   predcd_dec_start;
  bp_type_t [SLOT_NUM-1:0] predcd_dec_type;
  logic [SLOT_NUM-1:0][VA_W-1:0] predcd_dec_imm;
  logic [SLOT_NUM-1:0][VA_W-1:0] predcd_dec_ipc;
  logic [SLOT_NUM-1:0][VA_W-1:0] predcd_dec_ret_pc;
  logic                  predcd_dec_excp_vld;
  logic [CAUSE_W-1:0]    predcd_dec_excp_cause;
  // DIRECT_JUMP
  logic [SLOT_NUM-1:0]   dj_cand_vld;
  logic [SLOT_NUM-1:0][VA_W-1:0] dj_cand_target;
  // RAS
  logic [SLOT_NUM-1:0]   ras_cand_vld;
  logic [VA_W-1:0]       ras_cand_target;
  // PRECHECK
  logic                  prechk_redirect;
  logic [VA_W-1:0]       prechk_redirect_pc;
  logic                  prechk_ras_op, prechk_ras_op_push, prechk_ras_op_pop;
  logic [VA_W-1:0]       prechk_ras_op_push_pc;
  logic                  prechk_bpf_alloc;
  logic [VA_W-1:0]       prechk_bpf_alloc_line_pc;
  l1btb_meta_t           prechk_bpf_alloc_meta;
  logic [SLOT_NUM-1:0]   prechk_bpf_alloc_br_mask;
  logic                  prechk_bpf_alloc_xline;
  logic                  prechk_btb_clear;
  logic [VA_W-1:0]       prechk_btb_clear_pc;
  logic [BTB_WAY_W-1:0]  prechk_btb_clear_way;
  logic [SLOT_NUM-1:0]   prechk_ib_alloc_vmask;
  logic [SLOT_W-1:0]     prechk_ib_alloc_end_slot;
  logic                  prechk_ib_alloc_end_taken;
  logic [VA_W-1:0]       prechk_ib_alloc_end_target;
  logic                  prechk_ib_alloc_excp_vld;
  logic [CAUSE_W-1:0]    prechk_ib_alloc_excp_cause;
  logic                  prechk_ib_alloc_bpf_vld;
  logic [BPF_IDX_W-1:0]  prechk_ib_alloc_bpf_idx;
  // IB_ENQ_WINDOW
  logic                  ib_enq_alloc_rdy;
  // BPF
  logic                  bpf_l1_update;
  logic [VA_W-1:0]       bpf_upd_pc;
  logic [BTB_WAY_W-1:0]  bpf_upd_way;
  btb_wr_mode_t          bpf_upd_mode;
  logic [SLOT_W-1:0]     bpf_upd_slot;
  bp_type_t              bpf_upd_type;
  logic [1:0]            bpf_upd_ctr;
  logic [VA_W-1:0]       bpf_upd_target;
  logic                  bpf_upd_wr_tgt;
  logic                  bpf_alloc_rdy;
  logic [BPF_IDX_W-1:0]  bpf_alloc_idx;

  // =====================================================================
  // top-level own logic: inter-stage handoff channels
  // =====================================================================
  logic                  pcgen_ic_vld_q;
  logic [VA_W-1:0]       pcgen_ic_pc_q;
  logic                  ic_predcd_vld_q;
  logic [VA_W-1:0]       ic_predcd_pc_q;
  logic                  predcd_prechk_vld_q;
  logic [VA_W-1:0]       predcd_prechk_pc_q;
  // Expand data of the predecoded result line (loaded on predcd_prechk_hsk together with the PREDECODE control path)
  logic [SLOT_NUM-1:0][31:0] predcd_prechk_inst_q;
  logic [SLOT_NUM-1:0][31:0] predcd_prechk_raw_q;
  logic [SLOT_NUM-1:0]   predcd_prechk_is_rvc_q;
  logic [SLOT_NUM-1:0]   predcd_prechk_rvc_ill_q;
  operand_info_t [SLOT_NUM-1:0] predcd_prechk_opnd_q;
  logic                  predcd_prechk_xline_q;

  logic pcgen_ic_vld,      pcgen_ic_rdy,      pcgen_ic_hsk;
  logic ic_predcd_vld,     ic_predcd_rdy,     ic_predcd_hsk;
  logic predcd_prechk_vld, predcd_prechk_rdy, predcd_prechk_hsk;
  logic                    prechk_ib_alloc_rdy, prechk_ib_alloc_hsk;
  logic [ISSUE_W-1:0]      ib_enq_hsk;

  assign pcgen_ic_vld      = pcgen_ic_vld_q      & ~pcgen_ic_kill;
  assign ic_predcd_vld     = ic_predcd_vld_q     & ~ic_predcd_kill;
  assign predcd_prechk_vld = predcd_prechk_vld_q & ~predcd_prechk_kill;

  assign prechk_ib_alloc_rdy = ib_enq_alloc_rdy & bpf_alloc_rdy;
  assign prechk_ib_alloc_hsk = predcd_prechk_vld & prechk_ib_alloc_rdy;

  assign predcd_prechk_rdy = ~predcd_prechk_vld_q | prechk_ib_alloc_hsk | predcd_prechk_kill;
  assign predcd_prechk_hsk = ic_predcd_vld & predcd_prechk_rdy;

  assign ic_predcd_rdy     = ~ic_predcd_vld_q | predcd_prechk_hsk | ic_predcd_kill;
  assign ic_predcd_hsk     = pcgen_ic_vld & ic_rsp_vld & ic_predcd_rdy;

  assign pcgen_ic_rdy      = (~pcgen_ic_vld_q | ic_predcd_hsk | pcgen_ic_kill) & ic_req_rdy;
  assign pcgen_ic_hsk      = pcgen_fetch_req_vld & pcgen_ic_rdy;

  assign ib_enq_hsk        = ib_enq_vld & ib_enq_rdy;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      pcgen_ic_vld_q      <= 1'b0;
      ic_predcd_vld_q     <= 1'b0;
      predcd_prechk_vld_q <= 1'b0;
    end else begin
      pcgen_ic_vld_q      <= pcgen_ic_hsk      | (pcgen_ic_vld_q      & ~ic_predcd_hsk       & ~pcgen_ic_kill & ~ic_miss_drop);
      ic_predcd_vld_q     <= ic_predcd_hsk     | (ic_predcd_vld_q     & ~predcd_prechk_hsk   & ~ic_predcd_kill);
      predcd_prechk_vld_q <= predcd_prechk_hsk | (predcd_prechk_vld_q & ~prechk_ib_alloc_hsk & ~predcd_prechk_kill);
    end
  end

  always_ff @(posedge clk) begin
    if (pcgen_ic_hsk) begin
      pcgen_ic_pc_q <= pcgen_fetch_pc;
    end
    if (ic_predcd_hsk) begin
      ic_predcd_pc_q <= pcgen_ic_pc_q;
    end
    if (predcd_prechk_hsk) begin
      predcd_prechk_pc_q      <= ic_predcd_pc_q;
      predcd_prechk_inst_q    <= expd_inst;
      predcd_prechk_raw_q     <= expd_raw;
      predcd_prechk_is_rvc_q  <= expd_is_rvc;
      predcd_prechk_rvc_ill_q <= expd_rvc_ill;
      predcd_prechk_opnd_q    <= expd_opnd;
      predcd_prechk_xline_q   <= predcd_xline_vld;
    end
  end

  // =====================================================================
  // submodules
  // =====================================================================
  pc_gen u_pc_gen (
    .clk                (clk),
    .rst_n              (rst_n),
    .fetch_req_rdy      (pcgen_ic_rdy),
    .be_redirect        (bectl_redirect),
    .be_redirect_pc     (bectl_redirect_pc),
    .prechk_redirect    (prechk_redirect),
    .prechk_redirect_pc (prechk_redirect_pc),
    .l1btb_redirect     (l1btb_redirect),
    .l1btb_redirect_pc  (l1btb_redirect_pc),
    .replay             (ic_replay),
    .replay_pc          (ic_replay_pc),
    .miss_drop          (ic_miss_drop),
    .boot_pc            (boot_pc),
    .sleep_stall        (bectl_sleep_stall),
    .fetch_req_vld      (pcgen_fetch_req_vld),
    .fetch_pc           (pcgen_fetch_pc)
  );

  be_ctrl_reg u_be_ctrl_reg (
    .clk                  (clk),
    .rst_n                (rst_n),
    .be_redirect          (be_redirect),
    .be_redirect_pc       (be_redirect_pc),
    .be_commit_br         (be_commit_br),
    .be_commit_br_pc      (be_commit_br_pc),
    .be_commit_br_taken   (be_commit_br_taken),
    .be_commit_br_target  (be_commit_br_target),
    .be_commit_br_type    (be_commit_br_type),
    .be_commit            (be_commit),
    .be_commit_pc         (be_commit_pc),
    .be_sfence            (be_sfence),
    .be_fence_i           (be_fence_i),
    .sleep_req            (sleep_req),
    .csr_vm_en            (csr_vm_en),
    .csr_priv             (csr_priv),
    .csr_pmp_cfg          (csr_pmp_cfg),
    .redirect             (bectl_redirect),
    .redirect_pc          (bectl_redirect_pc),
    .flush                (bectl_flush),
    .commit_br            (bectl_commit_br),
    .commit_br_pc         (bectl_commit_br_pc),
    .commit_br_taken      (bectl_commit_br_taken),
    .commit_br_target     (bectl_commit_br_target),
    .commit_br_type       (bectl_commit_br_type),
    .commit               (bectl_commit),
    .commit_pc            (bectl_commit_pc),
    .tlb_flush            (bectl_tlb_flush),
    .ic_inv               (bectl_ic_inv),
    .sleep_flush          (bectl_sleep_flush),
    .sleep_stall          (bectl_sleep_stall),
    .vm_en                (bectl_vm_en),
    .priv                 (bectl_priv),
    .pmp_cfg              (bectl_pmp_cfg)
  );

  flush_control u_flush_control (
    .l1btb_redirect      (l1btb_redirect),
    .prechk_redirect     (prechk_redirect),
    .be_flush            (bectl_flush),
    .sleep_flush         (bectl_sleep_flush),
    .pcgen_ic_kill       (pcgen_ic_kill),
    .ic_predcd_kill      (ic_predcd_kill),
    .predcd_prechk_kill  (predcd_prechk_kill),
    .ifu_flush           (flush_ifu_flush),
    .xline_clear         (flush_xline_clear),
    .ib_enq_flush        (flush_ib_enq_flush),
    .ras_recover         (flush_ras_recover)
  );

  itlb u_itlb (
    .clk           (clk),
    .rst_n         (rst_n),
    .ptw_resp      (ptw_resp),
    .resp_ppn      (ptw_resp_ppn),
    .resp_lvl      (ptw_resp_lvl),
    .resp_x        (ptw_resp_x),
    .resp_u        (ptw_resp_u),
    .resp_pbmt     (ptw_resp_pbmt),
    .resp_fault    (ptw_resp_fault),
    .resp_cause    (ptw_resp_cause),
    .tlb_flush     (bectl_tlb_flush),
    .lookup_vld    (pcgen_ic_vld),
    .lookup_pc     (pcgen_ic_pc_q),
    .vm_en         (bectl_vm_en),
    .priv          (bectl_priv),
    .pmp_cfg       (bectl_pmp_cfg),
    .ptw_req_ready (ptw_req_ready),
    .ptw_req_vld   (ptw_req_vld),
    .ptw_req_vpn   (ptw_req_vpn),
    .refill_done   (itlb_refill_done),
    .hit           (itlb_hit),
    .pa_tag        (itlb_pa_tag),
    .excp_vld      (itlb_excp_vld),
    .excp_cause    (itlb_excp_cause),
    .ptw_idle      (itlb_ptw_idle)
  );

  icache u_icache (
    .clk             (clk),
    .rst_n           (rst_n),
    .req_hsk         (pcgen_ic_hsk),
    .req_pc          (pcgen_fetch_pc),
    .rsp_hsk         (ic_predcd_hsk),
    .ifu_flush       (flush_ifu_flush),
    .inv_all         (bectl_ic_inv),
    .tlb_refill_done (itlb_refill_done),
    .l2_resp         (l2_resp),
    .l2_resp_id      (l2_resp_id),
    .l2_resp_data    (l2_resp_data),
    .lookup_vld      (pcgen_ic_vld),
    .lookup_pc       (pcgen_ic_pc_q),
    .tlb_hit         (itlb_hit),
    .tlb_pa_tag      (itlb_pa_tag),
    .tlb_excp_vld    (itlb_excp_vld),
    .tlb_excp_cause  (itlb_excp_cause),
    .tlb_ptw_idle    (itlb_ptw_idle),
    .l2_req_ready    (l2_req_ready),
    .miss_drop       (ic_miss_drop),
    .replay          (ic_replay),
    .replay_pc       (ic_replay_pc),
    .l2_req_vld      (l2_req_vld),
    .l2_req_id       (l2_req_id),
    .l2_req_pa_line  (l2_req_pa_line),
    .l2_cancel       (l2_cancel),
    .l2_cancel_id    (l2_cancel_id),
    .req_rdy         (ic_req_rdy),
    .rsp_vld         (ic_rsp_vld),
    .rsp_half        (ic_rsp_half),
    .rsp_excp_vld    (ic_rsp_excp_vld),
    .rsp_excp_cause  (ic_rsp_excp_cause)
  );

  l1btb u_l1btb (
    .clk             (clk),
    .rst_n           (rst_n),
    .req_hsk         (pcgen_ic_hsk),
    .req_pc          (pcgen_fetch_pc),
    .rd_hsk          (ic_predcd_hsk),
    .pred_hsk        (predcd_prechk_hsk),
    .pred_kill       (ic_predcd_kill),
    .update          (bpf_l1_update),
    .upd_pc          (bpf_upd_pc),
    .upd_way         (bpf_upd_way),
    .upd_mode        (bpf_upd_mode),
    .upd_slot        (bpf_upd_slot),
    .upd_type        (bpf_upd_type),
    .upd_ctr         (bpf_upd_ctr),
    .upd_target      (bpf_upd_target),
    .upd_wr_tgt      (bpf_upd_wr_tgt),
    .pred_vld        (ic_predcd_vld),
    .pred_pc         (ic_predcd_pc_q),
    .redirect        (l1btb_redirect),
    .redirect_pc     (l1btb_redirect_pc),
    .pred_taken      (l1btb_pred_taken),
    .meta            (l1btb_meta)
  );

  instr_data_expand u_instr_data_expand (
    .half       (ic_rsp_half),
    .xline_vld  (predcd_xline_vld),
    .xline_half (predcd_xline_half),
    .inst       (expd_inst),
    .raw        (expd_raw),
    .is_rvc     (expd_is_rvc),
    .rvc_ill    (expd_rvc_ill),
    .opnd       (expd_opnd)
  );

  predecode u_predecode (
    .clk             (clk),
    .rst_n           (rst_n),
    .line_hsk        (predcd_prechk_hsk),
    .xline_clear     (flush_xline_clear),
    .line_half       (ic_rsp_half),
    .line_pc         (ic_predcd_pc_q),
    .line_excp_vld   (ic_rsp_excp_vld),
    .line_excp_cause (ic_rsp_excp_cause),
    .line_pred_taken (l1btb_pred_taken),
    .dec_pc          (predcd_prechk_pc_q),
    .xline_vld       (predcd_xline_vld),
    .xline_half      (predcd_xline_half),
    .dec_vld         (predcd_dec_vld),
    .dec_start       (predcd_dec_start),
    .dec_type        (predcd_dec_type),
    .dec_imm         (predcd_dec_imm),
    .dec_ipc         (predcd_dec_ipc),
    .dec_ret_pc      (predcd_dec_ret_pc),
    .dec_excp_vld    (predcd_dec_excp_vld),
    .dec_excp_cause  (predcd_dec_excp_cause)
  );

  direct_jump u_direct_jump (
    .valid       (predcd_dec_vld),
    .btype       (predcd_dec_type),
    .ipc         (predcd_dec_ipc),
    .imm         (predcd_dec_imm),
    .cand_vld    (dj_cand_vld),
    .cand_target (dj_cand_target)
  );

  ras u_ras (
    .clk         (clk),
    .rst_n       (rst_n),
    .op          (prechk_ras_op),
    .op_push     (prechk_ras_op_push),
    .op_pop      (prechk_ras_op_pop),
    .op_push_pc  (prechk_ras_op_push_pc),
    .enq_hsk     (ib_enq_hsk),
    .commit      (bectl_commit),
    .recover     (flush_ras_recover),
    .valid       (predcd_dec_vld),
    .btype       (predcd_dec_type),
    .enq_inst    (ib_enq_payload),
    .commit_pc   (bectl_commit_pc),
    .cand_vld    (ras_cand_vld),
    .cand_target (ras_cand_target)
  );

  precheck u_precheck (
    .clk                 (clk),
    .rst_n               (rst_n),
    .alloc_hsk           (prechk_ib_alloc_hsk),
    .line_kill           (predcd_prechk_kill),
    .line_vld            (predcd_prechk_vld),
    .line_pc             (predcd_prechk_pc_q),
    .valid               (predcd_dec_vld),
    .start               (predcd_dec_start),
    .btype               (predcd_dec_type),
    .ipc                 (predcd_dec_ipc),
    .ret_pc              (predcd_dec_ret_pc),
    .excp_vld            (predcd_dec_excp_vld),
    .excp_cause          (predcd_dec_excp_cause),
    .meta                (l1btb_meta),
    .dj_vld              (dj_cand_vld),
    .dj_target           (dj_cand_target),
    .ras_vld             (ras_cand_vld),
    .ras_target          (ras_cand_target),
    .bpf_alloc_idx       (bpf_alloc_idx),
    .redirect            (prechk_redirect),
    .redirect_pc         (prechk_redirect_pc),
    .ras_op              (prechk_ras_op),
    .ras_op_push         (prechk_ras_op_push),
    .ras_op_pop          (prechk_ras_op_pop),
    .ras_op_push_pc      (prechk_ras_op_push_pc),
    .bpf_alloc           (prechk_bpf_alloc),
    .bpf_alloc_line_pc   (prechk_bpf_alloc_line_pc),
    .bpf_alloc_meta      (prechk_bpf_alloc_meta),
    .bpf_alloc_br_mask   (prechk_bpf_alloc_br_mask),
    .bpf_alloc_xline     (prechk_bpf_alloc_xline),
    .btb_clear           (prechk_btb_clear),
    .btb_clear_pc        (prechk_btb_clear_pc),
    .btb_clear_way       (prechk_btb_clear_way),
    .ib_alloc_vmask      (prechk_ib_alloc_vmask),
    .ib_alloc_end_slot   (prechk_ib_alloc_end_slot),
    .ib_alloc_end_taken  (prechk_ib_alloc_end_taken),
    .ib_alloc_end_target (prechk_ib_alloc_end_target),
    .ib_alloc_excp_vld   (prechk_ib_alloc_excp_vld),
    .ib_alloc_excp_cause (prechk_ib_alloc_excp_cause),
    .ib_alloc_bpf_vld    (prechk_ib_alloc_bpf_vld),
    .ib_alloc_bpf_idx    (prechk_ib_alloc_bpf_idx)
  );

  // S4: window that enqueues to BE IB. The only IB in the whole pipeline is in Backend (p1/IB.sv); FE holds just one line and advances on enq handshake
  ib_enq_window u_ib_enq_window (
    .clk              (clk),
    .rst_n            (rst_n),
    .alloc_hsk        (prechk_ib_alloc_hsk),
    .flush            (flush_ib_enq_flush),
    .alloc_inst       (predcd_prechk_inst_q),
    .alloc_raw        (predcd_prechk_raw_q),
    .alloc_is_rvc     (predcd_prechk_is_rvc_q),
    .alloc_rvc_ill    (predcd_prechk_rvc_ill_q),
    .alloc_opnd       (predcd_prechk_opnd_q),
    .alloc_pc         (predcd_prechk_pc_q),
    .alloc_xline      (predcd_prechk_xline_q),
    .alloc_vmask      (prechk_ib_alloc_vmask),
    .alloc_end_slot   (prechk_ib_alloc_end_slot),
    .alloc_end_taken  (prechk_ib_alloc_end_taken),
    .alloc_end_target (prechk_ib_alloc_end_target),
    .alloc_excp_vld   (prechk_ib_alloc_excp_vld),
    .alloc_excp_cause (prechk_ib_alloc_excp_cause),
    .alloc_bpf_vld    (prechk_ib_alloc_bpf_vld),
    .alloc_bpf_idx    (prechk_ib_alloc_bpf_idx),
    .enq_rdy          (ib_enq_rdy),
    .alloc_rdy        (ib_enq_alloc_rdy),
    .enq_vld          (ib_enq_vld),
    .enq_payload      (ib_enq_payload)
  );

  bpf u_bpf (
    .clk           (clk),
    .rst_n         (rst_n),
    .alloc         (prechk_bpf_alloc),
    .alloc_line_pc (prechk_bpf_alloc_line_pc),
    .alloc_meta    (prechk_bpf_alloc_meta),
    .alloc_br_mask (prechk_bpf_alloc_br_mask),
    .alloc_xline   (prechk_bpf_alloc_xline),
    .clear         (prechk_btb_clear),
    .clear_pc      (prechk_btb_clear_pc),
    .clear_way     (prechk_btb_clear_way),
    .commit        (bectl_commit_br),
    .commit_pc     (bectl_commit_br_pc),
    .commit_taken  (bectl_commit_br_taken),
    .commit_target (bectl_commit_br_target),
    .commit_type   (bectl_commit_br_type),
    .l1_update     (bpf_l1_update),
    .upd_pc        (bpf_upd_pc),
    .upd_way       (bpf_upd_way),
    .upd_mode      (bpf_upd_mode),
    .upd_slot      (bpf_upd_slot),
    .upd_type      (bpf_upd_type),
    .upd_ctr       (bpf_upd_ctr),
    .upd_target    (bpf_upd_target),
    .upd_wr_tgt    (bpf_upd_wr_tgt),
    .alloc_rdy     (bpf_alloc_rdy),
    .alloc_idx     (bpf_alloc_idx)
  );

endmodule
