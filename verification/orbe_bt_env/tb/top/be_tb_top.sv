// [This file] Wiring: five interface instances, dispatch between the two DUT kinds, agent start/stop
`timescale 1ns/1ps

module be_tb_top;
  import orbe_be_dim_pkg::*;
  import be_tb_pkg::*;
  import or_be_lsu_protocol_pkg::*;
  import orbe_cosim_obs_pkg::*;

  localparam time CLK_PERIOD = 10ns;

  logic clk;
  logic rstn;
  bit cfg_ready;
  bit sim_done;
  be_config cfg;
  initial_agent init_agent_h;
  fe_agent fe_agent_h;
  be_agent be_agent_h;
  cache_agent #(BE_ISSUE_NUM, BE_ROB_ADDR_W) cache_agent_h;
  cosim_agent #(BE_ISSUE_NUM, BE_ROB_ADDR_W) cosim_agent_h;
  // Stage 1: feed the stand-in's observations to the same checker (cosim_agent/cosim_pkg).
  cosim_stage1_feeder cosim_feeder_h;
  mailbox #(cosim_commit_event_t) cosim_commit_events;
  mailbox #(cosim_arch_state_event_t) cosim_arch_state_events;

  orbe_fe_if fe_vif(clk, rstn);
  or_be_lsu_if lsu_vif(clk);
  ob_if ob_vif(clk);
  // LANE_NUM is deliberately not passed here: its default is exactly orbe_be_dim_pkg::BE_ROB_CMT_NUM,
  // same source and same value as what could be passed here. But Verilator names interface types by "explicitly overridden parameters":
  // with the top passing it explicitly and consumers using the default, you get ob_cosim_if__I2_R6_L4 and ob_cosim_if__I2_R6,
  // two different types, and virtual interface assignment fails to compile outright (even with equal values).
  // All six positional-parameter consumers take the default, so the top must take the default too.
  ob_cosim_if #(.ISSUE_NUM(BE_ISSUE_NUM), .ROB_ADDR_W(BE_ROB_ADDR_W))
      ob_cosim_vif(clk);

  assign lsu_vif.rst_n = rstn;
  assign ob_cosim_vif.rst_n = rstn;

  // Keep interface-derived lines in the structural top so the observer sees
  // stable interface values during time-zero settling.
  //
  // The folding of lsu_be_issue_ready has moved into or_be_lsu_if itself (see that file's [R5] comment):
  // it is the LSU side's obligation, belongs to the bus definition, and should not be computed by the top on its behalf.
  assign lsu_vif.lsu_be_done_valid =
      lsu_vif.lsu_be_done_valid_q && !lsu_vif.global_flush_late;
  assign lsu_vif.lsu_be_exception_valid =
      lsu_vif.lsu_be_exception_valid_q && !lsu_vif.global_flush_late;
  assign lsu_vif.lsu_be_bypass_valid =
      lsu_vif.lsu_be_bypass_valid_q && !lsu_vif.global_flush_late;

`ifdef ORBE_DUT_RTL_V1
  // backend_top is a direct instance of the top (hierarchical path be_tb_top.u_backend); whatever
  // internal signals the observation logic needs are taken from that path.

  import orbe_cosim_obs_pkg::*;
  import or_be_lsu_protocol_pkg::*;
  import or_be_types_pkg::*;
  import fe_be_protocol_pkg::*;

  // Cross-check of environment dimensions against RTL dimensions. Placed at the top: packages of both sides are visible here.
  // All package names are explicitly qualified to avoid import ::* name clashes.
  initial begin
    if (orbe_be_dim_pkg::BE_ISSUE_NUM != or_be_types_pkg::ISSUE_WIDTH)
      $fatal(1, "[TB] issue width mismatch: env BE_ISSUE_NUM=%0d rtl ISSUE_WIDTH=%0d",
             orbe_be_dim_pkg::BE_ISSUE_NUM, or_be_types_pkg::ISSUE_WIDTH);
    if (orbe_be_dim_pkg::BE_ROB_CMT_NUM != or_be_types_pkg::NUM_LANES)
      $fatal(1, "[TB] completion lane mismatch: env BE_ROB_CMT_NUM=%0d rtl NUM_LANES=%0d",
             orbe_be_dim_pkg::BE_ROB_CMT_NUM, or_be_types_pkg::NUM_LANES);
    if (orbe_be_dim_pkg::BE_ROB_ADDR_W < or_be_types_pkg::TAG_W)
      $fatal(1, "[TB] observation ROB index width %0d narrower than rtl TAG_W=%0d",
             orbe_be_dim_pkg::BE_ROB_ADDR_W, or_be_types_pkg::TAG_W);
    if ((orbe_cosim_obs_pkg::COSIM_ARF_REG_NUM != or_be_types_pkg::NUM_GPR) ||
        (orbe_cosim_obs_pkg::COSIM_ARF_REG_NUM != or_be_types_pkg::NUM_FPR))
      $fatal(1, "[TB] ARF snapshot count mismatch: cosim=%0d int=%0d fp=%0d",
             orbe_cosim_obs_pkg::COSIM_ARF_REG_NUM,
             or_be_types_pkg::NUM_GPR, or_be_types_pkg::NUM_FPR);
  end

  logic [ISSUE_WIDTH-1:0] rtl_fe_valid;
  fe_be_instr_pld_t rtl_fe_instr_pld [ISSUE_WIDTH];
  // BE IB needs FE's expanded word / rvc_ill / opnd:
  //   rtl_fe / rtl_full: taken directly from OR_FE RTL's ib_enq_payload (see the ORBE_FE_RTL section);
  //   rtl_v1 / rtl_cache: fe_agent gives only raw; generated below by calling the same or_fe_pkg functions, same source as FE RTL.
  logic [31:0]      fe2be_inst_exp [ISSUE_WIDTH];
  logic             fe2be_rvc_ill  [ISSUE_WIDTH];
  ib_operand_info_t fe2be_opnd     [ISSUE_WIDTH];

  function automatic ib_operand_info_t fe2be_opnd_cvt(input or_fe_pkg::operand_info_t o);
    ib_operand_info_t r;
    r.rs1          = o.rs1;
    r.rs2          = o.rs2;
    r.rs3          = o.rs3;
    r.rd           = o.rd;
    r.use_rs1      = o.use_rs1;
    r.use_rs2      = o.use_rs2;
    r.use_rs3      = o.use_rs3;
    r.use_rd       = o.use_rd;
    r.rs1_is_fp    = o.rs1_is_fp;
    r.rs2_is_fp    = o.rs2_is_fp;
    r.rs3_is_fp    = o.rs3_is_fp;
    r.rd_is_fp     = o.rd_is_fp;
    r.is_fp_opcode = o.is_fp_opcode;
    return r;
  endfunction

`ifndef ORBE_FE_RTL
  always_comb begin
    for (int group = 0; group < ISSUE_WIDTH; group++) begin
      logic [31:0] raw;
      raw = fe_vif.fe_be_instr_pld[group].inst_bits;
      if (fe_vif.fe_be_instr_pld[group].fetch_excp_vld) begin
        // Consistent with the FE window's exception entry: no encoding, opnd all 0
        fe2be_inst_exp[group] = raw;
        fe2be_rvc_ill[group]  = 1'b0;
        fe2be_opnd[group]     = '0;
      end else if (fe_vif.fe_be_instr_pld[group].is_compressed) begin
        fe2be_inst_exp[group] = or_fe_pkg::rvc_expand(raw[15:0]);
        fe2be_rvc_ill[group]  = or_fe_pkg::rvc_illegal(raw[15:0]);
        fe2be_opnd[group]     = fe2be_opnd_cvt(or_fe_pkg::operand_extract(fe2be_inst_exp[group]));
      end else begin
        fe2be_inst_exp[group] = raw;
        fe2be_rvc_ill[group]  = 1'b0;
        fe2be_opnd[group]     = fe2be_opnd_cvt(or_fe_pkg::operand_extract(raw));
      end
    end
  end
`endif
  logic [ISSUE_WIDTH-1:0] rtl_fe_ready;
  logic [ISSUE_WIDTH-1:0] rtl_accepted_slot;

  logic rtl_redirect_valid;
  logic [XLEN-1:0] rtl_redirect_pc;
  logic [RECOVERY_KIND_W-1:0] rtl_redirect_kind;
  logic rtl_frontend_icache_invalidate;
  logic rtl_predictor_update_valid;
  logic [XLEN-1:0] rtl_predictor_update_branch_pc;
  logic rtl_predictor_update_actual_taken;
  logic [XLEN-1:0] rtl_predictor_update_actual_target;
  cf_class_e rtl_predictor_update_cf_class;

  logic rtl_be_lsu_issue_valid;
  be_lsu_issue_pld_t rtl_be_lsu_issue_pld;
  logic rtl_be_lsu_store_wakeup_valid;
  // [2026-09-20] rtl_be_lsu_store_wakeup_tag removed: backend_top only has
  // be_lsu_store_wakeup_valid, lsu_if.sv also only has valid; nobody on the whole chain consumed it.
  logic rtl_global_flush;

  logic rtl_alloc_valid [ISSUE_WIDTH];
  logic [TAG_W-1:0] rtl_alloc_tag [ISSUE_WIDTH];
  logic rtl_exec_valid [NUM_LANES];
  logic [TAG_W-1:0] rtl_exec_tag [NUM_LANES];
  logic rtl_commit_valid [ISSUE_WIDTH];
  logic [TAG_W-1:0] rtl_commit_tag [ISSUE_WIDTH];
  logic [REG_ADDR_W-1:0] rtl_commit_rd_idx [ISSUE_WIDTH];
  logic rtl_commit_rd_is_fp [ISSUE_WIDTH];
  logic rtl_commit_rd_write_enable [ISSUE_WIDTH];
  logic [FFLAGS_W-1:0] rtl_commit_fflags [ISSUE_WIDTH];
  logic [COMMIT_COUNT_W-1:0] rtl_commit_count;
  logic [XLEN-1:0] rtl_commit_data [ISSUE_WIDTH];
  logic [XLEN-1:0] rtl_trace_pc [ISSUE_WIDTH];

  always_comb begin
    for (int group = 0; group < ISSUE_WIDTH; group++) begin
      rtl_fe_valid[group] = fe_vif.fe_be_instr_valid[group];
      rtl_fe_instr_pld[group] = '0;
      rtl_fe_instr_pld[group].pc = fe_vif.fe_be_instr_pld[group].pc;
      rtl_fe_instr_pld[group].inst_bits = fe_vif.fe_be_instr_pld[group].inst_bits;
      rtl_fe_instr_pld[group].is_compressed =
          fe_vif.fe_be_instr_pld[group].is_compressed;
      rtl_fe_instr_pld[group].pred_taken =
          fe_vif.fe_be_instr_pld[group].pred_taken;
      rtl_fe_instr_pld[group].pred_target_pc =
          fe_vif.fe_be_instr_pld[group].pred_target_pc;
      rtl_fe_instr_pld[group].fetch_excp_vld =
          fe_vif.fe_be_instr_pld[group].fetch_excp_vld;
      rtl_fe_instr_pld[group].fetch_excp_cause =
          fe_vif.fe_be_instr_pld[group].exception_cause;
      rtl_fe_instr_pld[group].fetch_excp_tval =
          fe_vif.fe_be_instr_pld[group].exception_tval;
      rtl_fe_instr_pld[group].inst_expanded = fe2be_inst_exp[group];
      rtl_fe_instr_pld[group].rvc_ill       = fe2be_rvc_ill[group];
      rtl_fe_instr_pld[group].opnd          = fe2be_opnd[group];
      fe_vif.be_fe_instr_ready[group] = rtl_fe_ready[group];
    end
  end

  always_comb begin
    orbe_recovery_kind_e kind;

    kind = orbe_recovery_kind_e'(rtl_redirect_kind);
    fe_vif.be_fe_redirect_valid = rtl_redirect_valid;
    fe_vif.be_fe_redirect_pld = '0;
    fe_vif.be_fe_redirect_pld.redirect_pc = rtl_redirect_pc;
    fe_vif.be_fe_redirect_pld.interrupt_valid =
        rtl_redirect_valid && (kind == ORBE_RECOVERY_INTERRUPT);
    fe_vif.be_fe_redirect_pld.trap_valid =
        rtl_redirect_valid &&
        ((kind == ORBE_RECOVERY_EXCEPTION) ||
         (kind == ORBE_RECOVERY_MRET) ||
         (kind == ORBE_RECOVERY_SRET));
  end

  assign lsu_vif.be_lsu_issue_valid = rtl_be_lsu_issue_valid;
  assign lsu_vif.be_lsu_issue_pld = rtl_be_lsu_issue_pld;
  assign lsu_vif.be_lsu_store_wakeup_valid = rtl_be_lsu_store_wakeup_valid;
  assign lsu_vif.global_flush_late = rtl_global_flush;
  assign lsu_vif.be_lsu_entry_ready = rstn && !rtl_global_flush;


  backend_top u_backend (
    .clk(clk),
    .rst_n(rstn),
    .fe_valid(rtl_fe_valid),
    .fe_instr_pld(rtl_fe_instr_pld),
    .fe_ready(rtl_fe_ready),
    .accepted_slot(rtl_accepted_slot),
    .redirect_valid(rtl_redirect_valid),
    .redirect_pc(rtl_redirect_pc),
    .redirect_kind(rtl_redirect_kind),
    .frontend_icache_invalidate(rtl_frontend_icache_invalidate),
    .predictor_update_valid(rtl_predictor_update_valid),
    .predictor_update_branch_pc(rtl_predictor_update_branch_pc),
    .predictor_update_actual_taken(rtl_predictor_update_actual_taken),
    .predictor_update_actual_target(rtl_predictor_update_actual_target),
    .predictor_update_cf_class(rtl_predictor_update_cf_class),
    .be_lsu_issue_valid(rtl_be_lsu_issue_valid),
    .be_lsu_issue_pld(rtl_be_lsu_issue_pld),
    .be_lsu_store_wakeup_valid(rtl_be_lsu_store_wakeup_valid),
    // backend_top's port name is global_flush_late; :342 was connected to
    // lsu_vif.global_flush_late anyway, so the names just need to match; semantics unchanged.
    .global_flush_late(rtl_global_flush),
    .lsu_be_issue_ready(lsu_vif.lsu_be_issue_ready),
    // [R7] After the type split these two port groups align with rtl_v1's g3_lsu_iface.sv.
    // [2026-09-20] The pre-split merged port lsu_be_writeback_valid used to still hang here,
    // while backend_top had long since had two independent valids, done / exception. After the fix it matches the source
    // of the two _pld above (lsu_vif.*).
    .lsu_be_done_valid(lsu_vif.lsu_be_done_valid),
    .lsu_be_exception_valid(lsu_vif.lsu_be_exception_valid),
    .lsu_be_done_pld(lsu_vif.lsu_be_done_pld),
    .lsu_be_exception_pld(lsu_vif.lsu_be_exception_pld),
    .lsu_be_bypass_valid(lsu_vif.lsu_be_bypass_valid),
    .lsu_be_bypass_pld(lsu_vif.lsu_be_bypass_pld),
    .mip_meip(1'b0),
    .mip_mtip(1'b0),
    .mip_msip(1'b0),
    .alloc_valid(rtl_alloc_valid),
    .alloc_tag(rtl_alloc_tag),
    .exec_valid(rtl_exec_valid),
    .exec_tag(rtl_exec_tag),
    .commit_valid(rtl_commit_valid),
    .commit_tag(rtl_commit_tag),
    .commit_rd_idx(rtl_commit_rd_idx),
    .commit_rd_is_fp(rtl_commit_rd_is_fp),
    .commit_rd_write_enable(rtl_commit_rd_write_enable),
    .commit_fflags(rtl_commit_fflags),
    .commit_count(rtl_commit_count),
    .commit_data(rtl_commit_data),
    .trace_pc(rtl_trace_pc)
  );

`ifdef ORBE_FE_RTL
  // ════════════════════════════════════════════════════════════════════
  // DUT_KIND=rtl_fe: OR_FE RTL occupies the FE slot, replacing fe_agent.
  //   FE -> BE  : IB's two lanes drive fe_vif directly (pc/target sign-extended from VA_W to 64 bits)
  //   BE -> FE  : redirect, frontend_icache_invalidate, predictor_update (trained by branch pc),
  //               commit_valid/trace_pc (RAS committed stack pairs by commit pc)
  //   CSR       : priv / satp taken from Backend's system_instruction_handler
  //   Downstream: L2 line refill and PTW served/answered by cache_agent's I side (orbe_fe_mem_if)
  // FE reset is released only after initial_agent has loaded the ELF and provided the entry PC.
  // ════════════════════════════════════════════════════════════════════
  logic                                         fe_go = 1'b0;
  logic                                         fe_rstn;
  logic [63:0]                                  fe_boot_pc = '0;
  logic [or_fe_pkg::ISSUE_W-1:0]                fe_inst_valid;
  or_fe_pkg::ib_inst_t [or_fe_pkg::ISSUE_W-1:0] fe_inst_payload;
  logic [1:0]                                   fe_priv;
  logic                                         fe_vm_en;
  or_fe_pkg::bp_type_t                          fe_cbr_type;
  logic                                         fe_sfence;
  int                                           fe_inject = 0;
  initial void'($value$plusargs("FE_INJECT=%d", fe_inject));
  logic [or_fe_pkg::ISSUE_W-1:0]                fe_commit_vld;
  logic [or_fe_pkg::ISSUE_W-1:0][or_fe_pkg::VA_W-1:0] fe_commit_pc;

  orbe_fe_mem_if fe_mem_vif(clk);

  assign fe_rstn          = rstn & fe_go;
  assign fe_mem_vif.rst_n = fe_rstn;
  assign fe_mem_vif.satp  = u_backend.u_system_instruction_handler.satp_q;
  assign fe_priv          = u_backend.u_system_instruction_handler.current_priv_q;
  assign fe_vm_en         = (fe_mem_vif.satp[63:60] == 4'd8) && (fe_priv != 2'b11);
  // Address-translation state may have changed: every Backend redirect except branch mispredict (trap / xRET / fence.i) flushes the ITLB
  assign fe_sfence        = rtl_redirect_valid &&
                            (recovery_kind_e'(rtl_redirect_kind) != RECOVERY_MISPREDICT);

  function automatic logic [63:0] fe_sext(input logic [or_fe_pkg::VA_W-1:0] v);
    return {{(64-or_fe_pkg::VA_W){v[or_fe_pkg::VA_W-1]}}, v};
  endfunction

  always_comb begin
    case (rtl_predictor_update_cf_class)
      CF_COND_BRANCH:   fe_cbr_type = or_fe_pkg::BP_BR;
      CF_JUMP_DIRECT:   fe_cbr_type = or_fe_pkg::BP_JUMP;
      CF_JUMP_INDIRECT: fe_cbr_type = or_fe_pkg::BP_INJP;
      default:          fe_cbr_type = or_fe_pkg::BP_NO_BR;
    endcase
  end

  always_comb begin
    for (int k = 0; k < or_fe_pkg::ISSUE_W; k++) begin
      fe_vif.fe_be_instr_valid[k]               = fe_inst_valid[k];
      fe_vif.fe_be_instr_pld[k]                 = '0;
      fe_vif.fe_be_instr_pld[k].pc              = fe_sext(fe_inst_payload[k].pc);
      fe_vif.fe_be_instr_pld[k].inst_bits       = fe_inst_payload[k].raw;
      fe_vif.fe_be_instr_pld[k].is_compressed   = fe_inst_payload[k].is_rvc;
      fe_vif.fe_be_instr_pld[k].pred_taken      = fe_inst_payload[k].pred_taken;
      fe_vif.fe_be_instr_pld[k].pred_target_pc  =
          fe_inst_payload[k].pred_taken ? fe_sext(fe_inst_payload[k].pred_target)
                                        : fe_sext(fe_inst_payload[k].pc) +
                                          (fe_inst_payload[k].is_rvc ? 64'd2 : 64'd4);
      fe_vif.fe_be_instr_pld[k].fetch_excp_vld  = fe_inst_payload[k].excp_vld;
      fe_vif.fe_be_instr_pld[k].exception_cause = 5'(fe_inst_payload[k].excp_cause);
      fe_vif.fe_be_instr_pld[k].exception_tval  = fe_sext(fe_inst_payload[k].excp_tval);
      // Only for negative-testing the FE equivalence check (+FE_INJECT=1): artificially add 2 to the fetch exception's tval
      if ((fe_inject == 1) && fe_inst_payload[k].excp_vld)
        fe_vif.fe_be_instr_pld[k].exception_tval = fe_vif.fe_be_instr_pld[k].exception_tval + 64'd2;
      // Only for negative-testing COSIM (+FE_INJECT=2): flip the LSB of the immediate of addi rd!=0
      if ((fe_inject == 2) && !fe_inst_payload[k].excp_vld && !fe_inst_payload[k].is_rvc &&
          (fe_inst_payload[k].raw[6:0] == 7'h13) && (fe_inst_payload[k].raw[14:12] == 3'b000) &&
          (fe_inst_payload[k].raw[11:7] != 5'd0))
        fe_vif.fe_be_instr_pld[k].inst_bits = fe_inst_payload[k].raw ^ 32'h0010_0000;
      // RAS committed stack: Backend commit observation port (commit_valid / trace_pc are backend_top output ports)
      fe_commit_vld[k]  = rtl_commit_valid[k];
      fe_commit_pc[k]   = rtl_trace_pc[k][or_fe_pkg::VA_W-1:0];
    end
  end

  or_fe_top u_fe (
    .clk                  (clk),
    .rst_n                (fe_rstn),
    .be_redirect          (rtl_redirect_valid),
    .be_redirect_pc       (rtl_redirect_pc[or_fe_pkg::VA_W-1:0]),
    .be_commit_br         (rtl_predictor_update_valid),
    .be_commit_br_pc      (rtl_predictor_update_branch_pc[or_fe_pkg::VA_W-1:0]),
    .be_commit_br_taken   (rtl_predictor_update_actual_taken),
    .be_commit_br_target  (rtl_predictor_update_actual_target[or_fe_pkg::VA_W-1:0]),
    .be_commit_br_type    (fe_cbr_type),
    .be_commit            (fe_commit_vld),
    .be_commit_pc         (fe_commit_pc),
    .be_sfence            (fe_sfence),
    .be_fence_i           (rtl_frontend_icache_invalidate),
    .ib_enq_rdy           (rtl_fe_ready),
    .ib_enq_vld           (fe_inst_valid),
    .ib_enq_payload       (fe_inst_payload),
    .ptw_req_vld          (fe_mem_vif.ptw_req_vld),
    .ptw_req_vpn          (fe_mem_vif.ptw_req_vpn),
    .ptw_req_ready        (fe_mem_vif.ptw_req_ready),
    .ptw_resp             (fe_mem_vif.ptw_resp),
    .ptw_resp_ppn         (fe_mem_vif.ptw_resp_ppn),
    .ptw_resp_lvl         (fe_mem_vif.ptw_resp_lvl),
    .ptw_resp_x           (fe_mem_vif.ptw_resp_x),
    .ptw_resp_u           (fe_mem_vif.ptw_resp_u),
    .ptw_resp_pbmt        (fe_mem_vif.ptw_resp_pbmt),
    .ptw_resp_fault       (fe_mem_vif.ptw_resp_fault),
    .ptw_resp_cause       (fe_mem_vif.ptw_resp_cause),
    .l2_req_vld           (fe_mem_vif.l2_req_vld),
    .l2_req_id            (fe_mem_vif.l2_req_id),
    .l2_req_pa_line       (fe_mem_vif.l2_req_pa_line),
    .l2_req_ready         (fe_mem_vif.l2_req_ready),
    .l2_cancel            (fe_mem_vif.l2_cancel),
    .l2_cancel_id         (fe_mem_vif.l2_cancel_id),
    .l2_resp              (fe_mem_vif.l2_resp),
    .l2_resp_id           (fe_mem_vif.l2_resp_id),
    .l2_resp_data         (fe_mem_vif.l2_resp_data),
    .boot_pc              (fe_boot_pc[or_fe_pkg::VA_W-1:0]),
    .sleep_req            (1'b0),
    .csr_vm_en            (fe_vm_en),
    .csr_priv             (or_fe_pkg::priv_t'(fe_priv)),
    .csr_pmp_cfg          ('0)
  );

  // ════════════════════════════════════════════════════════════════════
  // FE equivalence check: using fe_agent's own build_offer as reference, compare one by one the instructions that OR_FE RTL delivers
  // and that take architectural effect (commit, or flushed as an exception source).
  //   At allocation: next_pc = that instruction's pc, call fe_agent.build_offer, take lane 0 as reference;
  //                  record it by tag together with the payload BE actually allocated (i.e. what FE delivered).
  //   At effect:     compare pc / inst_bits / is_compressed / fetch_excp_vld / cause / tval.
  // Prediction fields are not compared: fe_agent never predicts (pred_taken = 0), OR_FE does, and BE corrects the difference.
  // The reference is computed after the negedge model phase (#1): the model then already includes this cycle's commits, the same convention as fe_agent's
  // "wait for the model to enter the trap before fetching" (R9-g). Wrong-path instructions never take effect and are not compared.
  // ════════════════════════════════════════════════════════════════════
  localparam int unsigned FEQ_N = 1 << BE_ROB_ADDR_W;
  bit                                     feq_rec_vld [FEQ_N];
  bit                                     feq_ref_vld [FEQ_N];
  orbe_fe_types_pkg::orbe_fe_instr_pld_t  feq_ref     [FEQ_N];
  rob_alloc_pld_t                         feq_dut     [FEQ_N];
  longint unsigned                        feq_checked, feq_excp, feq_mismatch, feq_noref;

  function automatic string feq_fmt(input logic [63:0] pc, input logic [31:0] ib, input logic c,
                                    input logic ev, input logic [4:0] cause, input logic [63:0] tval);
    return $sformatf("pc=0x%016h inst=0x%08h rvc=%0b excp=%0b cause=%0d tval=0x%016h",
                     pc, ib, c, ev, cause, tval);
  endfunction

  task automatic feq_compare(input int unsigned tag, input string why);
    orbe_fe_types_pkg::orbe_fe_instr_pld_t r;
    rob_alloc_pld_t d;
    bit same;
    if (!feq_rec_vld[tag]) return;
    feq_rec_vld[tag] = 1'b0;
    if (!feq_ref_vld[tag]) begin feq_noref++; return; end
    r = feq_ref[tag];
    d = feq_dut[tag];
    same = (d.pc == r.pc) && (d.fetch_excp_vld == r.fetch_excp_vld) &&
           (d.fetch_excp_vld ? ((d.exception_cause == r.exception_cause) &&
                                (d.exception_tval  == r.exception_tval))
                             : ((d.inst_bits == r.inst_bits) &&
                                (d.is_compressed == r.is_compressed)));
    feq_checked++;
    if (d.fetch_excp_vld) feq_excp++;
    if (!same) begin
      feq_mismatch++;
      cfg.reporter.error($sformatf("[FE_EQUIV] %s tag=%0d  OR_FE: %s  |  fe_agent: %s", why, tag,
          feq_fmt(d.pc, d.inst_bits, d.is_compressed, d.fetch_excp_vld, d.exception_cause, d.exception_tval),
          feq_fmt(r.pc, r.inst_bits, r.is_compressed, r.fetch_excp_vld, r.exception_cause, r.exception_tval)));
    end
  endtask

  initial begin : fe_equiv_check
    logic [orbe_fe_types_pkg::ORBE_FE_LANES-1:0] v;
    orbe_fe_types_pkg::orbe_fe_instr_pld_t pl [orbe_fe_types_pkg::ORBE_FE_LANES];
    logic [63:0] adv;
    bit fpn, exited;
    int unsigned tag;
    feq_checked = 0; feq_excp = 0; feq_mismatch = 0; feq_noref = 0; exited = 0;
    foreach (feq_rec_vld[i]) begin feq_rec_vld[i] = 0; feq_ref_vld[i] = 0; end
    wait (fe_go === 1'b1);
    // +FE_EQUIV=0 disables this check (only for negative testing that observes COSIM alone)
    if ($value$plusargs("FE_EQUIV=%d", tag) && (tag == 0)) begin
      $display("[FE_EQUIV] disabled by +FE_EQUIV=0");
      disable fe_equiv_check;
    end
    forever begin
      @(negedge clk);
      #1;
      if (sim_done) break;
      // Effect: commits (lane 0 is older) and the source of an exception flush
      for (int k = 0; k < BE_ISSUE_NUM; k++)
        if (ob_vif.commit_valid[k] === 1'b1) feq_compare(int'(ob_vif.commit_tag[k]), "commit");
      if ((ob_vif.recovery_valid === 1'b1) && (ob_vif.recovery_kind == ORBE_RECOVERY_EXCEPTION))
        feq_compare(int'(ob_vif.recovery_origin_tag), "exception");
      // Allocation: record the delivered value and compute the reference with fe_agent
      if (!exited) exited = (isa_dpi_pkg::isa_dpi_is_to_exit() != 0);
      for (int g = 0; g < BE_ISSUE_NUM; g++) begin
        if (ob_vif.alloc_valid[g] !== 1'b1) continue;
        tag = int'(ob_vif.alloc_tag[g]);
        feq_rec_vld[tag] = 1'b1;
        feq_dut[tag]     = ob_vif.alloc_pld[g];
        feq_ref_vld[tag] = 1'b0;
        if (exited || (fe_agent_h == null)) continue;
        fe_agent_h.next_pc          = ob_vif.alloc_pld[g].pc;
        fe_agent_h.fault_entry_sent = 1'b0;
        fe_agent_h.build_offer(v, pl, adv, fpn);
        if (v[0] !== 1'b1) begin
          // fe_agent would not deliver at this pc (EOF: halfword is 0)
          feq_ref[tag]     = '0;
          feq_ref[tag].pc  = ~ob_vif.alloc_pld[g].pc;   // guaranteed unequal; reported at effect
          feq_ref_vld[tag] = 1'b1;
        end else begin
          feq_ref[tag]     = pl[0];
          feq_ref_vld[tag] = 1'b1;
        end
      end
    end
  end

  // FE RTL's expanded word / rvc_ill / opnd pass straight through to BE
  always_comb begin
    for (int k = 0; k < or_fe_pkg::ISSUE_W; k++) begin
      fe2be_inst_exp[k] = fe_inst_payload[k].inst;
      fe2be_rvc_ill[k]  = fe_inst_payload[k].rvc_ill;
      fe2be_opnd[k]     = fe2be_opnd_cvt(fe_inst_payload[k].opnd);
      // +FE_INJECT=2 flips in step with raw (BE executes the expanded word)
      if ((fe_inject == 2) && !fe_inst_payload[k].excp_vld && !fe_inst_payload[k].is_rvc &&
          (fe_inst_payload[k].raw[6:0] == 7'h13) && (fe_inst_payload[k].raw[14:12] == 3'b000) &&
          (fe_inst_payload[k].raw[11:7] != 5'd0))
        fe2be_inst_exp[k] = fe_inst_payload[k].inst ^ 32'h0010_0000;
    end
  end

  final begin
    if (cfg != null)
      $display("[FE_EQUIV] checked=%0d (fetch_excp=%0d) mismatch=%0d no_ref=%0d",
               feq_checked, feq_excp, feq_mismatch, feq_noref);
  end
`endif

  // The observation logic expands within this scope; hierarchical references are written directly as u_backend.xxx; the
  // rtl_* signals sharing names with the top are already brought out by backend_top's ports above.
  // `include is textual expansion, creates no new module hierarchy, equivalent to inlining everything.
  `include "rtl_v1_obs.svh"

`ifdef ORBE_CACHE_RTL
  // ════════════════════════════════════════════════════════════════════
  // DUT_KIND=rtl_cache / rtl_full: OR_Cache RTL occupies the LSU slot, replacing cache_agent's D side.
  //   BE <-> LSU: frozen interface lsu_vif mapped as-is; LSU outputs driven by RTL (cache_agent does not drive them in RTL kinds)
  //   CSR       : satp / priv / SUM / MXR taken from Backend's system_instruction_handler
  //   sfence    : one pulse in the cycle Backend commits SFENCE.VMA (identified by the instruction encoding recorded at allocation)
  //   Downstream: L2 refill, PTW, eviction check and model sync done by cache_agent's D-side RTL service (orbe_dc_mem_if)
  // Reset is released only after initial_agent has loaded the ELF.
  // Only for negative testing: +CACHE_INJECT=1 flips the LSB of read-side done data (CACHE_EQUIV expected to error);
  //                 +CACHE_INJECT=3 flips the LSB of plain store data sent into the RTL (RTL writes wrong data into L1D,
  //                 CACHE_EQUIV expected to error on drain and subsequent loads); with +CACHE_EQUIV=0 only checks whether COSIM catches it.
  // ════════════════════════════════════════════════════════════════════
  logic                                   dc_go = 1'b0;
  logic                                   dc_rstn;
  int                                     dc_inject = 0;
  initial void'($value$plusargs("CACHE_INJECT=%d", dc_inject));

  orbe_dc_mem_if dc_mem_vif(clk);
  assign dc_rstn          = rstn & dc_go;
  assign dc_mem_vif.rst_n = dc_rstn;

  logic                                   dc_sb_full;
  logic                                   dc_done_v, dc_exc_v, dc_byp_v;
  lsu_be_done_pld_t                       dc_done_p, dc_byp_p;
  lsu_be_exception_pld_t                  dc_exc_p;
  logic [63:0]                            dc_satp;
  logic [1:0]                             dc_priv;
  logic                                   dc_sum, dc_mxr, dc_sfence;
  logic [(1 << TAG_W)-1:0]                dc_is_sfence_q;
  be_lsu_issue_pld_t                      dc_issue_pld;

  always_comb begin
    dc_issue_pld = lsu_vif.be_lsu_issue_pld;
    if ((dc_inject == 3) && req_property_from_subop(dc_issue_pld.exe_subop).is_store)
      dc_issue_pld.rs2_data = dc_issue_pld.rs2_data ^ 64'h1;
  end

  assign dc_satp = u_backend.u_system_instruction_handler.satp_q;
  assign dc_priv = 2'(u_backend.u_system_instruction_handler.current_priv_q);
  assign dc_sum  = u_backend.u_system_instruction_handler.mstatus_sum_q;
  assign dc_mxr  = u_backend.u_system_instruction_handler.mstatus_mxr_q;

  function automatic logic dc_inst_is_sfence(input logic [31:0] ib, input logic rvc);
    return !rvc && (ib[6:0] == 7'h73) && (ib[14:7] == 8'h00) && (ib[31:25] == 7'b0001001);
  endfunction
  always_ff @(posedge clk) begin
    for (int g = 0; g < ISSUE_WIDTH; g++)
      if (obs_alloc_valid[g] === 1'b1)
        dc_is_sfence_q[obs_alloc_tag[g]] <= dc_inst_is_sfence(obs_alloc_pld[g].inst_bits,
                                                              obs_alloc_pld[g].is_compressed);
  end
  always_comb begin
    dc_sfence = 1'b0;
    for (int k = 0; k < ISSUE_WIDTH; k++)
      if ((obs_commit_valid[k] === 1'b1) && dc_is_sfence_q[obs_commit_tag[k]]) dc_sfence = 1'b1;
  end

  or_cache_top u_cache (
    .clk                      (clk),
    .rst_n                    (dc_rstn),
    .global_flush_late        (rtl_global_flush),
    .be_lsu_issue_valid       (lsu_vif.be_lsu_issue_valid),
    .be_lsu_issue_pld         (dc_issue_pld),
    .lsu_be_issue_ready       (lsu_vif.lsu_be_issue_ready),
    .be_lsu_entry_ready       (lsu_vif.be_lsu_entry_ready),
    .be_lsu_store_wakeup_valid(lsu_vif.be_lsu_store_wakeup_valid),
    .lsu_store_buffer_full    (dc_sb_full),
    .lsu_be_done_valid_q      (dc_done_v),
    .lsu_be_done_pld          (dc_done_p),
    .lsu_be_exception_valid_q (dc_exc_v),
    .lsu_be_exception_pld     (dc_exc_p),
    .lsu_be_bypass_valid_q    (dc_byp_v),
    .lsu_be_bypass_pld        (dc_byp_p),
    .dc_l2_req_vld            (dc_mem_vif.l2_req_vld),
    .dc_l2_req_id             (dc_mem_vif.l2_req_id),
    .dc_l2_req_pa_line        (dc_mem_vif.l2_req_pa_line),
    .dc_l2_req_ready          (dc_mem_vif.l2_req_ready),
    .dc_l2_resp               (dc_mem_vif.l2_resp),
    .dc_l2_resp_id            (dc_mem_vif.l2_resp_id),
    .dc_l2_resp_data          (dc_mem_vif.l2_resp_data),
    .dc_l2_resp_err           (dc_mem_vif.l2_resp_err),
    .dc_evict_vld             (dc_mem_vif.evict_vld),
    .dc_evict_pa_line         (dc_mem_vif.evict_pa_line),
    .dc_evict_data            (dc_mem_vif.evict_data),
    .dc_ptw_req_vld           (dc_mem_vif.ptw_req_vld),
    .dc_ptw_req_vpn           (dc_mem_vif.ptw_req_vpn),
    .dc_ptw_req_id            (dc_mem_vif.ptw_req_id),
    .dc_ptw_req_ready         (dc_mem_vif.ptw_req_ready),
    .dc_ptw_resp              (dc_mem_vif.ptw_resp),
    .dc_ptw_resp_id           (dc_mem_vif.ptw_resp_id),
    .dc_ptw_resp_ppn          (dc_mem_vif.ptw_resp_ppn),
    .dc_ptw_resp_lvl          (dc_mem_vif.ptw_resp_lvl),
    .dc_ptw_resp_rcause       (dc_mem_vif.ptw_resp_rcause),
    .dc_ptw_resp_wcause       (dc_mem_vif.ptw_resp_wcause),
    .csr_satp                 (dc_satp),
    .csr_priv                 (dc_priv),
    .csr_sum                  (dc_sum),
    .csr_mxr                  (dc_mxr),
    .sfence_vma               (dc_sfence),
    .ms_drain_vld             (dc_mem_vif.ms_drain_vld),
    .ms_drain_tag             (dc_mem_vif.ms_drain_tag),
    .ms_drain_kind            (dc_mem_vif.ms_drain_kind),
    .ms_drain_data            (dc_mem_vif.ms_drain_data),
    .ms_drain_sc_ok           (dc_mem_vif.ms_drain_sc_ok)
  );

  // LSU outputs: RTL → frozen interface (the interface layer then masks presentation with !global_flush_late)
  always_comb begin
    lsu_vif.lsu_store_buffer_full    = dc_sb_full;
    lsu_vif.lsu_be_done_valid_q      = dc_done_v;
    lsu_vif.lsu_be_done_pld          = dc_done_p;
    lsu_vif.lsu_be_exception_valid_q = dc_exc_v;
    lsu_vif.lsu_be_exception_pld     = dc_exc_p;
    lsu_vif.lsu_be_bypass_valid_q    = dc_byp_v;
    lsu_vif.lsu_be_bypass_pld        = dc_byp_p;
    if ((dc_inject == 1) && dc_done_v && dc_byp_v) begin
      lsu_vif.lsu_be_done_pld.data   = dc_done_p.data ^ 64'h1;
      lsu_vif.lsu_be_bypass_pld.data = dc_byp_p.data ^ 64'h1;
    end
  end

  final begin
    if (cache_agent_h != null) cache_agent_h.dside_report();
  end
`endif


`elsif ORBE_DUT_AGENT
  // Full-chain configuration: FE agent -> be_bfm -> CacheAgent closed loop of the three, jointly driving one
  // ISA model. This configuration has no DUT and no COSIM observer.
  //
  // be_bfm directly drives both the fe and lsu boundaries; no separate slot placeholder or probe is needed.
  // be_agent is not started: it and be_bfm would double-drive the same model (decode_and_issue /
  // execute_insn / commit_auto / tick_finish), and when ob_if is undriven it would fatal outright because
  // recovery_valid is X.
  be_bfm u_be_bfm (
    .clk     (clk),
    .rst_n   (rstn),
    .fe      (fe_vif),
    .lsu     (lsu_vif),
    .ob      (ob_vif),
    // [Split-1] Slot contract item (2): in this DUT kind be_bfm publishes the observable event stream itself;
    // with rtl_v1 it is instead captured from RTL by rtl_v1_obs.svh, `included by this file, with the same shape.
    .ob_cosim(ob_cosim_vif)
  );

  // be_checker is retired: stage 1 runs, via cosim_stage1_feeder, the same checker as stage 2
  // (cosim_agent/cosim_pkg). The two cannot coexist: both need isa_cosim_dpi_create on the same independent reference instance,
  // and whichever is created later gets rc=-1.
  //
  // The file is kept under tb/agents/checker/ but has been removed from tb.f and is no longer compiled.

`else
  // This environment supports only DUT_KIND = agent / rtl_v1 / rtl_fe / rtl_cache / rtl_full;
  // tools/verilator_cosim.sh already rejects other values at build time; this adds a compile-time backstop.
  initial $fatal(1, "[TB] unsupported DUT_KIND: expected rtl_v1, rtl_fe, rtl_cache, rtl_full or agent");
`endif


  initial begin : clock_generator
    clk = 1'b0;
    forever #(CLK_PERIOD / 2) clk = ~clk;
  end

  initial begin : configure
    cfg_ready = 1'b0;
    sim_done = 1'b0;
    cfg = new();
    cosim_commit_events = new();
    cosim_arch_state_events = new();
    cfg.apply_plusargs();
    cfg.validate(BE_ISSUE_NUM);
    cfg.print();
    cfg_ready = 1'b1;
  end

  initial begin : sim_watchdog
    int unsigned timeout_cycles;
    time timeout_time;

    wait (cfg_ready);
    timeout_cycles = cfg.timeout_cycles;
    timeout_time = timeout_cycles * CLK_PERIOD;
    @(posedge rstn);
    #(timeout_time);
    #1;
    if (!sim_done)
      cfg.reporter.fatal($sformatf(
          "[TB] simulation timeout after %0d clock cycles (%0t)",
          timeout_cycles, timeout_time));
  end

  initial begin : reset_and_run
    string elf_path;

    wait (cfg_ready);
    rstn = 1'b0;
    repeat (5) @(posedge clk);
    rstn = 1'b1;

    // Environment setup comes before everything: create the shared model instance, load config and ELF, get the entry PC.
    // The other Agents start only after this blocking call completes, so no extra handshake is needed to guarantee ordering.
    init_agent_h = new(cfg);
    init_agent_h.initialize();

`ifdef ORBE_DUT_AGENT
    // Full-chain configuration: start only the two classes FE agent and CacheAgent.
    // be_bfm is a module, runs along with the top, not in the fork.
    // be_agent is not started -- it and be_bfm would double-drive the same ISA model.
    fe_agent_h = new(fe_vif, cfg, init_agent_h.initial_pc);
    cache_agent_h = new(lsu_vif, ob_vif, ob_cosim_vif, cfg);

    // This DUT kind feeds cosim_publisher's events via cosim_stage1_feeder to **the same** checker as the rtl kinds.
    if (cfg.cosim_enable) begin
      if (!$value$plusargs("ISA_ELF=%s", elf_path) || (elf_path.len() == 0))
        cfg.reporter.fatal("[TB] COSIM_ENABLE requires +ISA_ELF=<test.elf>");
      cosim_feeder_h = new(ob_vif, ob_cosim_vif, cosim_commit_events,
                           cosim_arch_state_events, cfg);
      cosim_agent_h = new(ob_cosim_vif, cosim_commit_events,
                          cosim_arch_state_events, cfg);
      cosim_agent_h.initialize_model(elf_path);
    end

    if (cfg.cosim_enable) begin
      fork
        fe_agent_h.run();
        cache_agent_h.run();
        cosim_feeder_h.run();
        cosim_agent_h.run();
      join
    end else begin
      fork
        fe_agent_h.run();
        cache_agent_h.run();
      join
    end
`else
    // In the rtl_fe kind fe_agent is only constructed, not run: only its wrap-up sequence is used (print is_good, destroy the model).
    fe_agent_h = new(fe_vif, cfg, init_agent_h.initial_pc);
    be_agent_h = new(ob_vif, fe_vif, ob_cosim_vif,
                     cosim_commit_events, cosim_arch_state_events, cfg);
    cache_agent_h = new(lsu_vif, ob_vif, ob_cosim_vif, cfg);
`ifdef ORBE_CACHE_RTL
    // The D side is executed by OR_Cache RTL; cache_agent only does model sync / CACHE_EQUIV / downstream responses
    cache_agent_h.attach_dside(dc_mem_vif);
    dc_go = 1'b1;
`endif
`ifdef ORBE_FE_RTL
    cache_agent_h.attach_ifetch(fe_mem_vif);
    fe_boot_pc = init_agent_h.initial_pc;
    @(negedge clk);
    fe_go = 1'b1;
`endif
    if (cfg.cosim_enable) begin
      if (!$value$plusargs("ISA_ELF=%s", elf_path) || (elf_path.len() == 0))
        cfg.reporter.fatal("[TB] COSIM_ENABLE requires +ISA_ELF=<test.elf>");
      cosim_agent_h = new(ob_cosim_vif, cosim_commit_events,
                          cosim_arch_state_events, cfg);
      cosim_agent_h.initialize_model(elf_path);
    end

`ifdef ORBE_FE_RTL
    if (cfg.cosim_enable) begin
      fork
        be_agent_h.run();
        cache_agent_h.run();
        cosim_agent_h.run();
      join
    end else begin
      fork
        be_agent_h.run();
        cache_agent_h.run();
      join
    end
`else
    if (cfg.cosim_enable) begin
      fork
        fe_agent_h.run();
        be_agent_h.run();
        cache_agent_h.run();
        cosim_agent_h.run();
      join
    end else begin
      fork
        fe_agent_h.run();
        be_agent_h.run();
        cache_agent_h.run();
      join
    end
`endif
`endif
    fe_agent_h.finish_model();
    if (cosim_agent_h != null)
      cosim_agent_h.finish_model();
    sim_done = 1'b1;
    $finish;
  end

  final begin
    if (cfg != null)
      cfg.reporter.print_summary();
  end
endmodule
