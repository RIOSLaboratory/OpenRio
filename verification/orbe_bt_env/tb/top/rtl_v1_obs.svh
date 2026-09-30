// [This file] rtl_v1 observation logic, expanded via `include inside be_tb_top's `ifdef ORBE_DUT_RTL_V1 scope
//
// Why `include instead of pasting everything into be_tb_top.sv:
//   `include is textual expansion and creates no new module hierarchy; it is circuit-wise identical to inlining everything;
//   it just keeps be_tb_top.sv readable. To merge into one file, simply paste this file's content over.

typedef struct packed {
  logic [63:0] pc;
  logic [31:0] inst_bits;
  logic is_compressed;
  logic fetch_excp_vld;
  logic [or_be_types_pkg::FETCH_EXCP_CAUSE_W-1:0] exception_cause;
  logic [63:0] exception_tval;
  logic is_lsu;
  // Decode fields sampled from the RTL allocation boundary.
  logic [4:0] rs1_idx;
  logic [4:0] rs2_idx;
  logic [4:0] rs3_idx;
  logic [4:0] rd_idx;
  logic rs1_is_fp;
  logic rs2_is_fp;
  logic rs3_is_fp;
  logic rd_is_fp;
  logic use_rs1;
  logic use_rs2;
  logic use_rs3;
  logic use_rd;
  logic is_store;
  logic [2:0] mem_funct3;
  logic imm_valid;
  logic [63:0] imm_data;
  logic [23:0] exe_subop;
  logic is_serial;
  logic is_fp_instruction;
  logic is_atomic;
  logic dec_is_fp_opcode;
  logic [16:0] full_decode;
} rtl_v1_obs_alloc_pld_t;
  import or_be_lsu_protocol_pkg::*;
  import fe_be_protocol_pkg::*;

  // ── Former ports, now internal signals ──────────────────────────────
  // Allocation and decode observation inputs.
  logic rtl_is_lsu [or_be_types_pkg::ISSUE_WIDTH];
  or_be_types_pkg::ib_payload_t rtl_alloc_payload [or_be_types_pkg::ISSUE_WIDTH];
  logic [4:0] rtl_rs1_idx [or_be_types_pkg::ISSUE_WIDTH];
  logic [4:0] rtl_rs2_idx [or_be_types_pkg::ISSUE_WIDTH];
  logic [4:0] rtl_rs3_idx [or_be_types_pkg::ISSUE_WIDTH];
  logic [4:0] rtl_rd_idx [or_be_types_pkg::ISSUE_WIDTH];
  logic rtl_rs1_is_fp [or_be_types_pkg::ISSUE_WIDTH];
  logic rtl_rs2_is_fp [or_be_types_pkg::ISSUE_WIDTH];
  logic rtl_rs3_is_fp [or_be_types_pkg::ISSUE_WIDTH];
  logic rtl_rd_is_fp [or_be_types_pkg::ISSUE_WIDTH];
  logic rtl_use_rs1 [or_be_types_pkg::ISSUE_WIDTH];
  logic rtl_use_rs2 [or_be_types_pkg::ISSUE_WIDTH];
  logic rtl_use_rs3 [or_be_types_pkg::ISSUE_WIDTH];
  logic rtl_use_rd [or_be_types_pkg::ISSUE_WIDTH];
  logic rtl_is_store [or_be_types_pkg::ISSUE_WIDTH];
  logic [2:0] rtl_mem_funct3 [or_be_types_pkg::ISSUE_WIDTH];
  logic rtl_imm_valid [or_be_types_pkg::ISSUE_WIDTH];
  logic [63:0] rtl_imm_data [or_be_types_pkg::ISSUE_WIDTH];
  logic [23:0] rtl_exe_subop [or_be_types_pkg::ISSUE_WIDTH];
  logic rtl_is_serial [or_be_types_pkg::ISSUE_WIDTH];
  logic rtl_is_fp_instruction [or_be_types_pkg::ISSUE_WIDTH];
  logic rtl_is_atomic [or_be_types_pkg::ISSUE_WIDTH];
  logic rtl_dec_is_fp_opcode [or_be_types_pkg::ISSUE_WIDTH];
  logic [16:0] rtl_full_decode [or_be_types_pkg::ISSUE_WIDTH];
  logic [63:0] rtl_fu_result [or_be_types_pkg::NUM_LANES];
  logic rtl_fu_mispredict [or_be_types_pkg::NUM_LANES];
  logic rtl_fu_exception [or_be_types_pkg::NUM_LANES];
  logic [63:0] rtl_fu_target [or_be_types_pkg::NUM_LANES];
  logic [or_be_types_pkg::EXCP_CAUSE_W-1:0] rtl_fu_cause [or_be_types_pkg::NUM_LANES];
  logic [63:0] rtl_fu_tval [or_be_types_pkg::NUM_LANES];
  logic rtl_fu_is_mret [or_be_types_pkg::NUM_LANES];
  logic rtl_fu_is_sret [or_be_types_pkg::NUM_LANES];
  logic [or_be_types_pkg::FFLAGS_W-1:0] rtl_fu_fflags [or_be_types_pkg::NUM_LANES];
  logic [or_be_types_pkg::XLEN-1:0] rtl_commit_result [or_be_types_pkg::ISSUE_WIDTH];
  logic [or_be_types_pkg::TAG_W-1:0] rtl_recovery_flush_tag;
  logic [or_be_types_pkg::EXCP_CAUSE_W-1:0] rtl_exception_cause;
  logic [or_be_types_pkg::XLEN-1:0] rtl_exception_tval;
  logic [or_be_types_pkg::XLEN-1:0] rtl_int_arf [or_be_types_pkg::NUM_GPR];
  logic [or_be_types_pkg::XLEN-1:0] rtl_fp_arf [or_be_types_pkg::NUM_FPR];
  logic [or_be_types_pkg::ISSUE_WIDTH-1:0] obs_alloc_valid;
  rtl_v1_obs_alloc_pld_t [or_be_types_pkg::ISSUE_WIDTH-1:0] obs_alloc_pld;
  logic [or_be_types_pkg::ISSUE_WIDTH-1:0] [or_be_types_pkg::TAG_W-1:0] obs_alloc_tag;
  logic [or_be_types_pkg::NUM_LANES-1:0] obs_exec_valid;
  logic [or_be_types_pkg::NUM_LANES-1:0] [or_be_types_pkg::TAG_W-1:0] obs_exec_tag;
  logic [or_be_types_pkg::ISSUE_WIDTH-1:0] obs_commit_valid;
  logic [or_be_types_pkg::ISSUE_WIDTH-1:0] [or_be_types_pkg::TAG_W-1:0] obs_commit_tag;
  logic [or_be_types_pkg::ISSUE_WIDTH-1:0][63:0] obs_commit_pc;
  logic [or_be_types_pkg::ISSUE_WIDTH-1:0][63:0] obs_commit_result;
  logic [or_be_types_pkg::ISSUE_WIDTH-1:0][or_be_types_pkg::REG_ADDR_W-1:0] obs_commit_rd_idx;
  logic [or_be_types_pkg::ISSUE_WIDTH-1:0] obs_commit_rd_is_fp;
  logic [or_be_types_pkg::ISSUE_WIDTH-1:0] obs_commit_rd_write_enable;
  logic [or_be_types_pkg::ISSUE_WIDTH-1:0][or_be_types_pkg::FFLAGS_W-1:0] obs_commit_fflags;
  logic [$clog2(or_be_types_pkg::ISSUE_WIDTH+1)-1:0] obs_commit_count;
  logic obs_global_flush;
  logic obs_redirect_valid;
  logic [or_be_types_pkg::XLEN-1:0] obs_redirect_pc;
  orbe_cosim_obs_pkg::orbe_recovery_kind_e obs_redirect_kind;
  logic obs_recovery_valid;
  orbe_cosim_obs_pkg::orbe_recovery_kind_e obs_recovery_kind;
  logic [or_be_types_pkg::TAG_W-1:0] obs_recovery_origin_tag;
  logic [or_be_types_pkg::TAG_W-1:0] obs_recovery_squash_tag;
  logic [63:0] obs_recovery_redirect_pc;
  logic obs_commit_exception_valid;
  logic [or_be_types_pkg::EXCP_CAUSE_W-1:0] obs_commit_exception_cause;
  logic [63:0] obs_commit_exception_tval;
  logic obs_commit_redirect_valid;
  logic [or_be_types_pkg::RECOVERY_KIND_W-1:0] obs_commit_recovery_kind;
  logic [63:0] obs_commit_redirect_pc;
  logic [orbe_cosim_obs_pkg::COSIM_ARF_REG_NUM-1:0][63:0] obs_int_arf;
  logic [orbe_cosim_obs_pkg::COSIM_ARF_REG_NUM-1:0][63:0] obs_fp_arf;
  logic obs_csr_valid;
  logic [orbe_cosim_obs_pkg::COSIM_CSR_STATE_NUM-1:0] obs_csr_state_valid;
  logic [orbe_cosim_obs_pkg::COSIM_CSR_STATE_NUM-1:0][11:0] obs_csr_state_addr;
  logic [orbe_cosim_obs_pkg::COSIM_CSR_STATE_NUM-1:0][63:0] obs_csr_state;
  logic [63:0] obs_fu_result [or_be_types_pkg::NUM_LANES];
  logic obs_fu_mispredict [or_be_types_pkg::NUM_LANES];
  logic obs_fu_exception [or_be_types_pkg::NUM_LANES];
  logic [63:0] obs_fu_target [or_be_types_pkg::NUM_LANES];
  logic [or_be_types_pkg::EXCP_CAUSE_W-1:0] obs_fu_cause [or_be_types_pkg::NUM_LANES];
  logic [63:0] obs_fu_tval [or_be_types_pkg::NUM_LANES];
  logic obs_fu_is_mret [or_be_types_pkg::NUM_LANES];
  logic obs_fu_is_sret [or_be_types_pkg::NUM_LANES];
  logic [or_be_types_pkg::FFLAGS_W-1:0] obs_fu_fflags [or_be_types_pkg::NUM_LANES];
  logic obs_csr_event_valid;
  logic [11:0] obs_csr_event_addr;
  logic [63:0] obs_csr_event_wdata;
  logic [63:0] obs_csr_event_rdata;
  logic rtl_isq_g0_issue_valid;
  orbe_cosim_obs_pkg::cosim_isq_g0_issue_pld_t rtl_isq_g0_issue_pld;
  logic rtl_isq_g1_issue_valid;
  orbe_cosim_obs_pkg::cosim_isq_g1_issue_pld_t rtl_isq_g1_issue_pld;
  logic rtl_isq_g2_issue_valid;
  orbe_cosim_obs_pkg::cosim_isq_g2_issue_pld_t rtl_isq_g2_issue_pld;
  logic rtl_isq_g3_issue_valid;
  orbe_cosim_obs_pkg::cosim_isq_g3_issue_pld_t rtl_isq_g3_issue_pld;
  logic rtl_csr_in_valid;
  logic [or_be_types_pkg::TAG_W-1:0] rtl_csr_in_tag;
  logic [11:0] rtl_csr_in_addr;
  logic [63:0] rtl_csr_in_rdata;
  logic [2:0] rtl_csr_in_current_priv;
  logic rtl_csr_in_fs_enabled;
  logic rtl_csr_out_valid;
  logic rtl_csr_out_write_enable;
  logic [11:0] rtl_csr_out_addr;
  logic [63:0] rtl_csr_out_wdata;
  logic [or_be_types_pkg::TAG_W-1:0] rtl_csr_out_exec_tag;
  logic obs_isq_g0_issue_valid;
  orbe_cosim_obs_pkg::cosim_isq_g0_issue_pld_t obs_isq_g0_issue_pld;
  logic obs_isq_g1_issue_valid;
  orbe_cosim_obs_pkg::cosim_isq_g1_issue_pld_t obs_isq_g1_issue_pld;
  logic obs_isq_g2_issue_valid;
  orbe_cosim_obs_pkg::cosim_isq_g2_issue_pld_t obs_isq_g2_issue_pld;
  logic obs_isq_g3_issue_valid;
  orbe_cosim_obs_pkg::cosim_isq_g3_issue_pld_t obs_isq_g3_issue_pld;
  logic obs_csr_in_valid;
  logic [or_be_types_pkg::TAG_W-1:0] obs_csr_in_tag;
  logic [11:0] obs_csr_in_addr;
  logic [63:0] obs_csr_in_rdata;
  logic [2:0] obs_csr_in_current_priv;
  logic obs_csr_in_fs_enabled;
  logic obs_csr_out_valid;
  logic obs_csr_out_write_enable;
  logic [11:0] obs_csr_out_addr;
  logic [63:0] obs_csr_out_wdata;
  logic [or_be_types_pkg::TAG_W-1:0] obs_csr_out_exec_tag;

  // ── Taken directly from the DUT ───────────────────────────────────────
  assign rtl_alloc_payload = u_backend.head_IB_Payload;
  assign rtl_fu_result = u_backend.lane_result_data;
  assign rtl_fu_mispredict = u_backend.lane_mispredict_flag;
  assign rtl_fu_exception = u_backend.lane_exception_flag;
  assign rtl_fu_target = u_backend.lane_mispredict_target_pc;
  assign rtl_fu_cause = u_backend.lane_exception_cause;
  assign rtl_fu_tval = u_backend.lane_exception_tval;
  assign rtl_fu_is_mret = u_backend.lane_is_mret;
  assign rtl_fu_is_sret = u_backend.lane_is_sret;
  assign rtl_fu_fflags = u_backend.lane_fpu_fflags;
  assign rtl_isq_g0_issue_valid = u_backend.isq0_issue_valid;
  assign rtl_isq_g0_issue_pld = rtl_isq0_issue_pld;
  assign rtl_isq_g1_issue_valid = u_backend.isq1_issue_valid;
  assign rtl_isq_g1_issue_pld = rtl_isq1_issue_pld;
  assign rtl_isq_g2_issue_valid = u_backend.isq2_issue_valid;
  assign rtl_isq_g2_issue_pld = rtl_isq2_issue_pld;
  assign rtl_isq_g3_issue_valid = u_backend.isq3_issue_valid;
  assign rtl_isq_g3_issue_pld = rtl_isq3_issue_pld;
  assign rtl_csr_in_valid = u_backend.u_csr_unit.accept;
  assign rtl_csr_in_tag = u_backend.isq0_self_tag;
  assign rtl_csr_in_addr = u_backend.csrfu_csr_addr;
  assign rtl_csr_in_rdata = u_backend.sih_csr_rdata;
  assign rtl_csr_in_current_priv = u_backend.sih_current_priv;
  assign rtl_csr_in_fs_enabled = u_backend.sih_fs_enabled;
  assign rtl_csr_out_valid = u_backend.arbG0_Result_valid && u_backend.arbG0_is_csr;
  assign rtl_csr_out_write_enable = u_backend.arbG0_csr_write_enable;
  assign rtl_csr_out_addr = u_backend.arbG0_csr_addr;
  assign rtl_csr_out_wdata = u_backend.arbG0_csr_wdata;
  assign rtl_csr_out_exec_tag = u_backend.exec_tag[0];
  // [2026-09-22] The top level already gets this value via backend_top's commit_data port; no longer a hierarchical reference.
  assign rtl_commit_result = rtl_commit_data;
  assign rtl_recovery_flush_tag = u_backend.scb_flush_tag;
  assign rtl_exception_cause = u_backend.scb_recovery_exception_cause;
  assign rtl_exception_tval = u_backend.scb_recovery_exception_tval;
  assign rtl_int_arf = u_backend.u_INT_ARF.entry_arf;
  assign rtl_fp_arf = u_backend.u_FP_ARF.entry_arf;

  // ── The former wrapper's observation pipeline, moved here ────────────────────
  always_comb begin
    for (int group = 0; group < ISSUE_WIDTH; group++) begin
      rtl_rs1_idx[group] = u_backend.ib_rs1_idx[group];
      rtl_rs2_idx[group] = u_backend.ib_rs2_idx[group];
      rtl_rs3_idx[group] = u_backend.ib_rs3_idx[group];
      rtl_rd_idx[group] = u_backend.ib_rd_idx[group];
      rtl_rs1_is_fp[group] = u_backend.ib_rs1_is_fp[group];
      rtl_rs2_is_fp[group] = u_backend.ib_rs2_is_fp[group];
      rtl_rs3_is_fp[group] = u_backend.ib_rs3_is_fp[group];
      rtl_rd_is_fp[group] = u_backend.ib_rd_is_fp[group];
      rtl_use_rs1[group] = u_backend.ib_use_rs1[group];
      rtl_use_rs2[group] = u_backend.ib_use_rs2[group];
      rtl_use_rs3[group] = u_backend.ib_use_rs3[group];
      rtl_use_rd[group] = u_backend.ib_use_rd[group];
      rtl_is_store[group] = u_backend.ib_is_store[group];
      rtl_is_lsu[group] = (u_backend.dl_slot_FU_Group[group] == 3);
      rtl_mem_funct3[group] = u_backend.dec_info[group].mem_funct3;
      rtl_imm_valid[group] = u_backend.dec_info[group].imm_valid;
      rtl_imm_data[group] = u_backend.dec_info[group].imm_data;
      rtl_exe_subop[group] = u_backend.ib_exe_subop[group];
      rtl_is_serial[group] = u_backend.ib_is_serial[group];
      rtl_is_fp_instruction[group] = u_backend.ib_is_fp_instruction[group];
      rtl_is_atomic[group] = u_backend.dl_is_atomic[group];
      rtl_dec_is_fp_opcode[group] = u_backend.ib_is_fp_opcode[group];
      rtl_full_decode[group] = u_backend.ib_full_decode[group];
    end
  end

  // Level-2 ISQ snapshots are exposed through the observation interface.
  cosim_isq_g0_issue_pld_t rtl_isq0_issue_pld;
  cosim_isq_g1_issue_pld_t rtl_isq1_issue_pld;
  cosim_isq_g2_issue_pld_t rtl_isq2_issue_pld;
  cosim_isq_g3_issue_pld_t rtl_isq3_issue_pld;
  // Group 0 carries the full ISQ payload.
  assign rtl_isq0_issue_pld = '{rs1_data:u_backend.isq0_rs1_data, rs2_data:u_backend.isq0_rs2_data, fu_group:u_backend.isq0_FU_Group, imm_valid:u_backend.isq0_imm_valid, imm_data:u_backend.isq0_imm_data, pc:u_backend.isq0_pc, inst_bits:u_backend.isq0_inst_bits, is_compressed:u_backend.isq0_is_compressed, pred_taken:u_backend.isq0_pred_taken, pred_target_pc:u_backend.isq0_pred_target_pc, self_tag:u_backend.isq0_self_tag, exe_subop:u_backend.isq0_exe_subop, full_decode:u_backend.isq0_full_decode, fetch_excp_vld:u_backend.isq0_fetch_excp_vld, fetch_excp_cause:u_backend.isq0_fetch_excp_cause, fetch_excp_tval:u_backend.isq0_fetch_excp_tval};
  // Group 1 carries the second ISQ payload.
  assign rtl_isq1_issue_pld = '{rs1_data:u_backend.isq1_rs1_data, rs2_data:u_backend.isq1_rs2_data, fu_group:u_backend.isq1_FU_Group, imm_data:u_backend.isq1_imm_data, self_tag:u_backend.isq1_self_tag, exe_subop:u_backend.isq1_exe_subop};
  // Group 2 carries the third ISQ payload.
  assign rtl_isq2_issue_pld = '{rs1_data:u_backend.isq2_rs1_data, rs2_data:u_backend.isq2_rs2_data, rs3_data:u_backend.isq2_rs3_data, self_tag:u_backend.isq2_self_tag, exe_subop:u_backend.isq2_exe_subop, full_decode:u_backend.isq2_full_decode};
  // Group 3 carries the LSU-oriented ISQ payload.
  assign rtl_isq3_issue_pld = '{rs1_data:u_backend.isq3_rs1_data, store_data:u_backend.isq3_rs2_data, imm_valid:u_backend.isq3_imm_valid, imm_data:u_backend.isq3_imm_data, mem_funct3:u_backend.isq3_mem_funct3, rd_is_fp:u_backend.isq3_rd_is_fp, self_tag:u_backend.isq3_self_tag, exe_subop:u_backend.isq3_exe_subop};

  // Connect Level-2 LSU boundary signals to the generic observation interface.
  assign ob_cosim_vif.lsu_be_issue_ready = lsu_vif.lsu_be_issue_ready;
  assign ob_cosim_vif.be_lsu_issue_valid = u_backend.be_lsu_issue_valid;
  assign ob_cosim_vif.be_lsu_issue_pld = u_backend.be_lsu_issue_pld;
  assign ob_cosim_vif.lsu_be_done_valid = lsu_vif.lsu_be_done_valid;
  assign ob_cosim_vif.lsu_be_exception_valid = lsu_vif.lsu_be_exception_valid;
  assign ob_cosim_vif.lsu_be_bypass_valid = lsu_vif.lsu_be_bypass_valid;
  // [R7] The observation bus splits types in step with the observed boundary.
  assign ob_cosim_vif.lsu_be_done_pld      = lsu_vif.lsu_be_done_pld;
  assign ob_cosim_vif.lsu_be_exception_pld = lsu_vif.lsu_be_exception_pld;
  assign ob_cosim_vif.lsu_be_bypass_pld = lsu_vif.lsu_be_bypass_pld;
  // Connect the registered allocation snapshot as the decode lifecycle payload.
  genvar decode_group;
  generate
    for (decode_group = 0; decode_group < ISSUE_WIDTH; decode_group++) begin : g_decode_observation
      assign ob_cosim_vif.decode_issue_valid[decode_group] =
          obs_alloc_valid[decode_group];
      assign ob_cosim_vif.decode_issue_pld[decode_group].pc =
          obs_alloc_pld[decode_group].pc;
      assign ob_cosim_vif.decode_issue_pld[decode_group].inst_bits =
          obs_alloc_pld[decode_group].inst_bits;
      assign ob_cosim_vif.decode_issue_pld[decode_group].is_compressed =
          obs_alloc_pld[decode_group].is_compressed;
      assign ob_cosim_vif.decode_issue_pld[decode_group].rs1_idx =
          obs_alloc_pld[decode_group].rs1_idx;
      assign ob_cosim_vif.decode_issue_pld[decode_group].rs2_idx =
          obs_alloc_pld[decode_group].rs2_idx;
      assign ob_cosim_vif.decode_issue_pld[decode_group].rs3_idx =
          obs_alloc_pld[decode_group].rs3_idx;
      assign ob_cosim_vif.decode_issue_pld[decode_group].rd_idx =
          obs_alloc_pld[decode_group].rd_idx;
      assign ob_cosim_vif.decode_issue_pld[decode_group].rs1_is_fp =
          obs_alloc_pld[decode_group].rs1_is_fp;
      assign ob_cosim_vif.decode_issue_pld[decode_group].rs2_is_fp =
          obs_alloc_pld[decode_group].rs2_is_fp;
      assign ob_cosim_vif.decode_issue_pld[decode_group].rs3_is_fp =
          obs_alloc_pld[decode_group].rs3_is_fp;
      assign ob_cosim_vif.decode_issue_pld[decode_group].rd_is_fp =
          obs_alloc_pld[decode_group].rd_is_fp;
      assign ob_cosim_vif.decode_issue_pld[decode_group].use_rs1 =
          obs_alloc_pld[decode_group].use_rs1;
      assign ob_cosim_vif.decode_issue_pld[decode_group].use_rs2 =
          obs_alloc_pld[decode_group].use_rs2;
      assign ob_cosim_vif.decode_issue_pld[decode_group].use_rs3 =
          obs_alloc_pld[decode_group].use_rs3;
      assign ob_cosim_vif.decode_issue_pld[decode_group].use_rd =
          obs_alloc_pld[decode_group].use_rd;
      assign ob_cosim_vif.decode_issue_pld[decode_group].is_store =
          obs_alloc_pld[decode_group].is_store;
      assign ob_cosim_vif.decode_issue_pld[decode_group].mem_funct3 =
          obs_alloc_pld[decode_group].mem_funct3;
      assign ob_cosim_vif.decode_issue_pld[decode_group].imm_valid =
          obs_alloc_pld[decode_group].imm_valid;
      assign ob_cosim_vif.decode_issue_pld[decode_group].imm_data =
          obs_alloc_pld[decode_group].imm_data;
      assign ob_cosim_vif.decode_issue_pld[decode_group].exe_subop =
          obs_alloc_pld[decode_group].exe_subop;
      assign ob_cosim_vif.decode_issue_pld[decode_group].is_serial =
          obs_alloc_pld[decode_group].is_serial;
      assign ob_cosim_vif.decode_issue_pld[decode_group].is_fp_instruction =
          obs_alloc_pld[decode_group].is_fp_instruction;
      assign ob_cosim_vif.decode_issue_pld[decode_group].is_atomic =
          obs_alloc_pld[decode_group].is_atomic;
      assign ob_cosim_vif.decode_issue_pld[decode_group].dec_is_fp_opcode =
          obs_alloc_pld[decode_group].dec_is_fp_opcode;
      assign ob_cosim_vif.decode_issue_pld[decode_group].full_decode =
          obs_alloc_pld[decode_group].full_decode;
    end
  endgenerate
  // Connect the registered FU-after snapshot for writeback lifecycle logging.
  //
  // [2026-09-22] Loop upper bound changed from ISSUE_WIDTH(2) to NUM_LANES(4), and fu_after_valid
  // also changed to per-element assignment. Previously `assign fu_after_valid = obs_exec_valid` assigned 4 bits to
  // 2 bits, silently truncating, and the generate connected only two lanes, so completion events of G2 FPU and G3 LSU never reached
  // the observation surface; meanwhile the consumer be_agent.sv loops over BE_ROB_CMT_NUM=4, an out-of-bounds read for lanes 2/3.
  genvar lane;
  generate
    for (lane = 0; lane < or_be_types_pkg::NUM_LANES; lane++) begin : g_l2_fu
    assign ob_cosim_vif.fu_after_valid[lane] = obs_exec_valid[lane];
    assign ob_cosim_vif.fu_after_tag[lane] = obs_exec_tag[lane];
    assign ob_cosim_vif.fu_after_result[lane] = obs_fu_result[lane];
    assign ob_cosim_vif.fu_after_mispredict[lane] = obs_fu_mispredict[lane];
    assign ob_cosim_vif.fu_after_exception[lane] = obs_fu_exception[lane];
    assign ob_cosim_vif.fu_after_target[lane] = obs_fu_target[lane];
    assign ob_cosim_vif.fu_after_cause[lane] = obs_fu_cause[lane];
    assign ob_cosim_vif.fu_after_tval[lane] = obs_fu_tval[lane];
    assign ob_cosim_vif.fu_after_is_mret[lane] = obs_fu_is_mret[lane];
    assign ob_cosim_vif.fu_after_is_sret[lane] = obs_fu_is_sret[lane];
    assign ob_cosim_vif.fu_after_fflags[lane] = obs_fu_fflags[lane];
    end
  endgenerate
  always_comb begin
    ob_vif.alloc_valid = '0;
    ob_vif.alloc_pld = '{default:'0};
    ob_vif.alloc_tag = '0;
    ob_vif.rob_alloc_valid = '0;
    ob_vif.rob_alloc_pld = '{default:'0};
    ob_vif.rob_alloc_rob_idx = '0;
    ob_vif.rob_alloc_rob_ptr = '0;
    for (int group = 0; group < ISSUE_WIDTH; group++) begin
      ob_vif.alloc_valid[group] = obs_alloc_valid[group];
      ob_vif.alloc_tag[group] = obs_alloc_tag[group];
      ob_vif.alloc_pld[group].pc = obs_alloc_pld[group].pc;
      ob_vif.alloc_pld[group].inst_bits = obs_alloc_pld[group].inst_bits;
      ob_vif.alloc_pld[group].is_compressed =
          obs_alloc_pld[group].is_compressed;
      ob_vif.alloc_pld[group].fetch_excp_vld =
          obs_alloc_pld[group].fetch_excp_vld;
      ob_vif.alloc_pld[group].exception_cause =
          obs_alloc_pld[group].exception_cause;
      ob_vif.alloc_pld[group].exception_tval =
          obs_alloc_pld[group].exception_tval;
      ob_vif.alloc_pld[group].is_lsu = obs_alloc_pld[group].is_lsu;

      ob_vif.rob_alloc_valid[group] = ob_vif.alloc_valid[group];
      ob_vif.rob_alloc_pld[group] = ob_vif.alloc_pld[group];
      ob_vif.rob_alloc_rob_idx[group] = ob_vif.alloc_tag[group];
      ob_vif.rob_alloc_rob_ptr[group][TAG_W-1:0] =
          obs_alloc_tag[group][TAG_W-1:0];
    end

    ob_vif.exec_valid = '0;
    ob_vif.exec_tag = '0;
    ob_vif.exe_rob_wr_vld = '0;
    ob_vif.exe_rob_wr_idx = '0;
    for (int source = 0; source < NUM_LANES; source++) begin
      ob_vif.exec_valid[source] = obs_exec_valid[source];
      ob_vif.exec_tag[source] = obs_exec_tag[source];
      ob_vif.exe_rob_wr_vld[source] = ob_vif.exec_valid[source];
      ob_vif.exe_rob_wr_idx[source] = ob_vif.exec_tag[source];
    end

    ob_vif.commit_valid = '0;
    ob_vif.commit_tag = '0;
    ob_vif.commit_pc = '0;
    ob_vif.rob_commit_valid = '0;
    ob_vif.rob_commit_pld = '{default:'0};
    ob_vif.rob_commit_rob_idx = '0;
    for (int group = 0; group < ISSUE_WIDTH; group++) begin
      ob_vif.commit_valid[group] = obs_commit_valid[group];
      ob_vif.commit_tag[group] = obs_commit_tag[group];
      ob_vif.commit_pc[group] = obs_commit_pc[group];
      ob_vif.rob_commit_valid[group] = ob_vif.commit_valid[group];
      ob_vif.rob_commit_pld[group].pc = ob_vif.commit_pc[group];
      ob_vif.rob_commit_pld[group].rob_idx = ob_vif.commit_tag[group];
      ob_vif.rob_commit_rob_idx[group] = ob_vif.commit_tag[group];
    end
    ob_vif.commit_count = obs_commit_count;

    ob_vif.global_flush = obs_global_flush;
    ob_vif.redirect_valid = obs_redirect_valid;
    ob_vif.redirect_pc = obs_redirect_pc;
    ob_vif.redirect_kind = obs_redirect_kind;
    ob_vif.recovery_valid = obs_recovery_valid;
    ob_vif.recovery_kind = obs_recovery_kind;
    ob_vif.recovery_origin_tag = obs_recovery_origin_tag;
    ob_vif.recovery_squash_tag = obs_recovery_squash_tag;
    ob_vif.recovery_redirect_pc = obs_recovery_redirect_pc;

    ob_vif.flush_all = '0;
    if (ob_vif.recovery_valid &&
        ((obs_recovery_kind == ORBE_RECOVERY_EXCEPTION) ||
         (obs_recovery_kind == ORBE_RECOVERY_INTERRUPT)))
      ob_vif.flush_all = '1;
    ob_vif.pflush = ob_vif.recovery_valid && (ob_vif.flush_all == '0);
    ob_vif.pflush_rob_idx = obs_recovery_origin_tag;
  end

  assign ob_cosim_vif.commit_valid = obs_commit_valid;
  // [E-02] commit_count is connected to the COSIM observation surface, sourced from the same
  // obs_commit_count as ob_vif.commit_count; the two buses do not sample separately.
  assign ob_cosim_vif.commit_count = obs_commit_count;
  // [E-03] commit_rob_idx changed to per-element assignment.
  //
  // Previously `assign commit_rob_idx = obs_commit_tag` assigned [1:0][TAG_W-1:0] (4-bit elements,
  // 8 bits total) as a whole to [1:0][ROB_ADDR_W-1:0] (6-bit elements, 12 bits total). Packed arrays align as
  // flat bit vectors; after the RHS is zero-extended and right-aligned:
  //     commit_rob_idx[0] = {obs_commit_tag[1][1:0], obs_commit_tag[0][3:0]}
  //     commit_rob_idx[1] = {4'b0,                   obs_commit_tag[1][3:2]}
  // so the group boundaries are misaligned. The side of this same file that drives ob_if has always been per-element and correct.
  //
  // be_tb_top's `BE_ROB_ADDR_W < TAG_W` $fatal cannot catch this: 6 >= 4 always holds;
  // it guards against narrower, not against the flat misalignment caused by wider. Same class of bug as E-05 (whole-array assignment).
  genvar cmt_group;
  generate
    for (cmt_group = 0; cmt_group < or_be_types_pkg::ISSUE_WIDTH; cmt_group++) begin : g_l1_cmt_idx
    assign ob_cosim_vif.commit_rob_idx[cmt_group] = obs_commit_tag[cmt_group];
    end
  endgenerate
  assign ob_cosim_vif.commit_pc = obs_commit_pc;
  assign ob_cosim_vif.commit_result = obs_commit_result;
  assign ob_cosim_vif.commit_rd_idx = obs_commit_rd_idx;
  assign ob_cosim_vif.commit_rd_is_fp = obs_commit_rd_is_fp;
  assign ob_cosim_vif.commit_rd_write_enable = obs_commit_rd_write_enable;
  assign ob_cosim_vif.commit_fflags = obs_commit_fflags;
  assign ob_cosim_vif.commit_exception_valid = obs_commit_exception_valid;
  assign ob_cosim_vif.commit_exception_cause = obs_commit_exception_cause;
  assign ob_cosim_vif.commit_exception_tval = obs_commit_exception_tval;
  assign ob_cosim_vif.commit_redirect_valid = obs_commit_redirect_valid;
  assign ob_cosim_vif.commit_recovery_kind = obs_commit_recovery_kind;
  assign ob_cosim_vif.commit_redirect_pc = obs_commit_redirect_pc;

  // [E-02] The flush / recovery control surface is connected to the value bus. All taken from the same batch of
  // obs_* samples that drive ob_if; nothing is sampled or derived separately here -- the two buses sharing a source is required by R-5.1.
  // flush_valid / flush_tag use the same definition as ob_vif.pflush / pflush_rob_idx:
  // a recovery implies a flush, and the tag is the recovery origin entry.
  // Scalar assignment; TAG_W(4) → ROB_ADDR_W(6) is zero-extension, so no E-03-style flat misalignment.
  assign ob_cosim_vif.flush_valid = obs_global_flush;
  assign ob_cosim_vif.flush_tag = obs_recovery_origin_tag;
  assign ob_cosim_vif.recovery_valid = obs_recovery_valid;
  assign ob_cosim_vif.recovery_kind = obs_recovery_kind;
  assign ob_cosim_vif.recovery_origin_tag = obs_recovery_origin_tag;
  assign ob_cosim_vif.recovery_squash_tag = obs_recovery_squash_tag;
  assign ob_cosim_vif.recovery_redirect_pc = obs_recovery_redirect_pc;
  assign ob_cosim_vif.int_arf = obs_int_arf;
  assign ob_cosim_vif.fp_arf = obs_fp_arf;
  assign ob_cosim_vif.csr_valid = obs_csr_valid;
  assign ob_cosim_vif.csr_state_valid = obs_csr_state_valid;
  assign ob_cosim_vif.csr_state_addr = obs_csr_state_addr;
  assign ob_cosim_vif.csr_state = obs_csr_state;
  assign ob_cosim_vif.csr_event_valid = obs_csr_event_valid;
  assign ob_cosim_vif.csr_event_addr = obs_csr_event_addr;
  assign ob_cosim_vif.csr_event_wdata = obs_csr_event_wdata;
  assign ob_cosim_vif.csr_event_rdata = obs_csr_event_rdata;


  // ── Write back into ob_cosim (formerly in the wrapper) ────────────────────
  assign ob_cosim_vif.isq_g0_issue_valid = obs_isq_g0_issue_valid;
  assign ob_cosim_vif.isq_g0_issue_pld = obs_isq_g0_issue_pld;
  assign ob_cosim_vif.isq_g1_issue_valid = obs_isq_g1_issue_valid;
  assign ob_cosim_vif.isq_g1_issue_pld = obs_isq_g1_issue_pld;
  assign ob_cosim_vif.isq_g2_issue_valid = obs_isq_g2_issue_valid;
  assign ob_cosim_vif.isq_g2_issue_pld = obs_isq_g2_issue_pld;
  assign ob_cosim_vif.isq_g3_issue_valid = obs_isq_g3_issue_valid;
  assign ob_cosim_vif.isq_g3_issue_pld = obs_isq_g3_issue_pld;
  assign ob_cosim_vif.csr_in_valid = obs_csr_in_valid;
  assign ob_cosim_vif.csr_in_tag = obs_csr_in_tag;
  assign ob_cosim_vif.csr_in_addr = obs_csr_in_addr;
  assign ob_cosim_vif.csr_in_rdata = obs_csr_in_rdata;
  assign ob_cosim_vif.csr_in_current_priv = obs_csr_in_current_priv;
  assign ob_cosim_vif.csr_in_fs_enabled = obs_csr_in_fs_enabled;
  assign ob_cosim_vif.csr_out_valid = obs_csr_out_valid;
  assign ob_cosim_vif.csr_out_write_enable = obs_csr_out_write_enable;
  assign ob_cosim_vif.csr_out_addr = obs_csr_out_addr;
  assign ob_cosim_vif.csr_out_wdata = obs_csr_out_wdata;
  assign ob_cosim_vif.csr_out_exec_tag = obs_csr_out_exec_tag;
  import orbe_cosim_obs_pkg::*;
  import or_be_types_pkg::*;
  localparam int OBS_ISSUE_NUM = ISSUE_WIDTH;
  localparam int OBS_ROB_NUM = NUM_LANES;
  localparam int OBS_ROB_ADDR_W = TAG_W;

  function automatic bit recovery_commits_origin(
      input orbe_recovery_kind_e kind);
    case (kind)
      ORBE_RECOVERY_MISPREDICT,
      ORBE_RECOVERY_MRET,
      ORBE_RECOVERY_FENCE_I,
      ORBE_RECOVERY_SRET:
        return 1'b1;
      default:
        return 1'b0;
    endcase
  endfunction

  // [2026-09-22] The former initial parameter self-check block is removed: its three $fatal compared a localparam
  // with its own assignment expression (OBS_ISSUE_NUM = ISSUE_WIDTH, then asserted they differ), always false,
  // never firing. The real cross-package check now lives in be_tb_top's rtl_v1 branch.

  // Register only the event observation copy.  rtl_v1's commit/recovery
  // outputs are cycle-start combinational requests; be_agent samples at
  // negedge and must see them after the RTL sequential state has consumed
  // them at posedge.
  always_ff @(posedge clk or negedge rstn) begin
    if (!rstn) begin
      obs_alloc_valid <= '0;
      obs_alloc_pld <= '{default:'0};
      obs_alloc_tag <= '0;
      obs_exec_valid <= '0;
      obs_exec_tag <= '0;
      for (int source = 0; source < NUM_LANES; source++) begin
        obs_fu_result[source] <= '0;
        obs_fu_mispredict[source] <= 1'b0;
        obs_fu_exception[source] <= 1'b0;
        obs_fu_target[source] <= '0;
        obs_fu_cause[source] <= '0;
        obs_fu_tval[source] <= '0;
        obs_fu_is_mret[source] <= 1'b0;
        obs_fu_is_sret[source] <= 1'b0;
        obs_fu_fflags[source] <= '0;
      end
      obs_commit_valid <= '0;
      obs_commit_tag <= '0;
      obs_commit_pc <= '0;
      obs_commit_result <= '0;
      obs_commit_rd_idx <= '0;
      obs_commit_rd_is_fp <= '0;
      obs_commit_rd_write_enable <= '0;
      obs_commit_fflags <= '0;
      obs_commit_count <= '0;
      obs_global_flush <= 1'b0;
      obs_redirect_valid <= 1'b0;
      obs_redirect_pc <= '0;
      obs_redirect_kind <= ORBE_RECOVERY_MISPREDICT;
      obs_recovery_valid <= 1'b0;
      obs_recovery_kind <= ORBE_RECOVERY_MISPREDICT;
      obs_recovery_origin_tag <= '0;
      obs_recovery_squash_tag <= '0;
      obs_recovery_redirect_pc <= '0;
      obs_commit_exception_valid <= 1'b0;
      obs_commit_exception_cause <= '0;
      obs_commit_exception_tval <= '0;
      obs_commit_redirect_valid <= 1'b0;
      obs_commit_recovery_kind <= '0;
      obs_commit_redirect_pc <= '0;
      obs_isq_g0_issue_valid <= 1'b0;
      obs_isq_g0_issue_pld <= '0;
      obs_isq_g1_issue_valid <= 1'b0;
      obs_isq_g1_issue_pld <= '0;
      obs_isq_g2_issue_valid <= 1'b0;
      obs_isq_g2_issue_pld <= '0;
      obs_isq_g3_issue_valid <= 1'b0;
      obs_isq_g3_issue_pld <= '0;
      obs_csr_in_valid <= 1'b0;
      obs_csr_in_tag <= '0;
      obs_csr_in_addr <= '0;
      obs_csr_in_rdata <= '0;
      obs_csr_in_current_priv <= '0;
      obs_csr_in_fs_enabled <= 1'b0;
      obs_csr_out_valid <= 1'b0;
      obs_csr_out_write_enable <= 1'b0;
      obs_csr_out_addr <= '0;
      obs_csr_out_wdata <= '0;
      obs_csr_out_exec_tag <= '0;
    end else begin
      orbe_recovery_kind_e kind;
      logic [OBS_ROB_ADDR_W-1:0] recovery_origin;
      logic [OBS_ROB_ADDR_W-1:0] recovery_squash;

      kind = orbe_recovery_kind_e'(rtl_redirect_kind);
      recovery_origin = '0;
      recovery_origin[TAG_W-1:0] = rtl_recovery_flush_tag;
      recovery_squash = recovery_origin;
      if (recovery_commits_origin(kind))
        recovery_squash[TAG_W-1:0] = rtl_recovery_flush_tag + 1'b1;

      obs_alloc_valid <= '0;
      obs_alloc_pld <= '{default:'0};
      obs_alloc_tag <= '0;
      for (int group = 0; group < ISSUE_WIDTH; group++) begin
        obs_alloc_valid[group] <= rtl_alloc_valid[group];
        obs_alloc_tag[group][TAG_W-1:0] <= rtl_alloc_tag[group];
        obs_alloc_pld[group].pc <= rtl_alloc_payload[group].pc;
        obs_alloc_pld[group].inst_bits <= rtl_alloc_payload[group].inst_bits;
        obs_alloc_pld[group].is_compressed <=
            rtl_alloc_payload[group].is_compressed;
        obs_alloc_pld[group].fetch_excp_vld <=
            rtl_alloc_payload[group].fetch_excp_vld;
        obs_alloc_pld[group].exception_cause <=
            rtl_alloc_payload[group].fetch_excp_cause;
        obs_alloc_pld[group].exception_tval <=
            rtl_alloc_payload[group].fetch_excp_tval;
        obs_alloc_pld[group].is_lsu <= rtl_is_lsu[group];
        obs_alloc_pld[group].rs1_idx <= rtl_rs1_idx[group];
        obs_alloc_pld[group].rs2_idx <= rtl_rs2_idx[group];
        obs_alloc_pld[group].rs3_idx <= rtl_rs3_idx[group];
        obs_alloc_pld[group].rd_idx <= rtl_rd_idx[group];
        obs_alloc_pld[group].rs1_is_fp <= rtl_rs1_is_fp[group];
        obs_alloc_pld[group].rs2_is_fp <= rtl_rs2_is_fp[group];
        obs_alloc_pld[group].rs3_is_fp <= rtl_rs3_is_fp[group];
        obs_alloc_pld[group].rd_is_fp <= rtl_rd_is_fp[group];
        obs_alloc_pld[group].use_rs1 <= rtl_use_rs1[group];
        obs_alloc_pld[group].use_rs2 <= rtl_use_rs2[group];
        obs_alloc_pld[group].use_rs3 <= rtl_use_rs3[group];
        obs_alloc_pld[group].use_rd <= rtl_use_rd[group];
        obs_alloc_pld[group].is_store <= rtl_is_store[group];
        obs_alloc_pld[group].mem_funct3 <= rtl_mem_funct3[group];
        obs_alloc_pld[group].imm_valid <= rtl_imm_valid[group];
        obs_alloc_pld[group].imm_data <= rtl_imm_data[group];
        obs_alloc_pld[group].exe_subop <= rtl_exe_subop[group];
        obs_alloc_pld[group].is_serial <= rtl_is_serial[group];
        obs_alloc_pld[group].is_fp_instruction <= rtl_is_fp_instruction[group];
        obs_alloc_pld[group].is_atomic <= rtl_is_atomic[group];
        obs_alloc_pld[group].dec_is_fp_opcode <= rtl_dec_is_fp_opcode[group];
        obs_alloc_pld[group].full_decode <= rtl_full_decode[group];
      end

      obs_exec_valid <= '0;
      obs_exec_tag <= '0;
      for (int source = 0; source < NUM_LANES; source++) begin
        obs_exec_valid[source] <= rtl_exec_valid[source];
        obs_exec_tag[source][TAG_W-1:0] <= rtl_exec_tag[source];
        obs_fu_result[source] <= rtl_fu_result[source];
        obs_fu_mispredict[source] <= rtl_fu_mispredict[source];
        obs_fu_exception[source] <= rtl_fu_exception[source];
        obs_fu_target[source] <= rtl_fu_target[source];
        obs_fu_cause[source] <= rtl_fu_cause[source];
        obs_fu_tval[source] <= rtl_fu_tval[source];
        obs_fu_is_mret[source] <= rtl_fu_is_mret[source];
        obs_fu_is_sret[source] <= rtl_fu_is_sret[source];
        obs_fu_fflags[source] <= rtl_fu_fflags[source];
      end

      obs_commit_valid <= '0;
      obs_commit_tag <= '0;
      obs_commit_pc <= '0;
      obs_commit_result <= '0;
      obs_commit_rd_idx <= '0;
      obs_commit_rd_is_fp <= '0;
      obs_commit_rd_write_enable <= '0;
      obs_commit_fflags <= '0;
      for (int group = 0; group < ISSUE_WIDTH; group++) begin
        obs_commit_valid[group] <= rtl_commit_valid[group];
        obs_commit_tag[group][TAG_W-1:0] <= rtl_commit_tag[group];
        obs_commit_pc[group] <= rtl_trace_pc[group];
        obs_commit_result[group] <= rtl_commit_result[group];
        obs_commit_rd_idx[group] <= rtl_commit_rd_idx[group];
        obs_commit_rd_is_fp[group] <= rtl_commit_rd_is_fp[group];
        obs_commit_rd_write_enable[group] <= rtl_commit_rd_write_enable[group];
        obs_commit_fflags[group] <= rtl_commit_fflags[group];
      end
      obs_commit_count <= rtl_commit_count;

      obs_global_flush <= rtl_global_flush;
      obs_redirect_valid <= rtl_redirect_valid;
      obs_redirect_pc <= rtl_redirect_pc;
      obs_redirect_kind <= kind;
      obs_recovery_valid <= rtl_global_flush || rtl_redirect_valid;
      obs_recovery_kind <= kind;
      obs_recovery_origin_tag <= recovery_origin;
      obs_recovery_squash_tag <= recovery_squash;
      obs_recovery_redirect_pc <= rtl_redirect_pc;
      obs_commit_redirect_valid <= rtl_redirect_valid;
      obs_commit_recovery_kind <= rtl_redirect_kind;
      obs_commit_redirect_pc <= rtl_redirect_pc;
      obs_commit_exception_valid <=
          rtl_redirect_valid && (kind == ORBE_RECOVERY_EXCEPTION);
      obs_commit_exception_cause <= rtl_exception_cause;
      obs_commit_exception_tval <= rtl_exception_tval;
      obs_isq_g0_issue_valid <= rtl_isq_g0_issue_valid;
      obs_isq_g0_issue_pld <= rtl_isq_g0_issue_pld;
      obs_isq_g1_issue_valid <= rtl_isq_g1_issue_valid;
      obs_isq_g1_issue_pld <= rtl_isq_g1_issue_pld;
      obs_isq_g2_issue_valid <= rtl_isq_g2_issue_valid;
      obs_isq_g2_issue_pld <= rtl_isq_g2_issue_pld;
      obs_isq_g3_issue_valid <= rtl_isq_g3_issue_valid;
      obs_isq_g3_issue_pld <= rtl_isq_g3_issue_pld;
      for (int lane = 0; lane < NUM_LANES; lane++) begin
        obs_fu_result[lane] <= rtl_fu_result[lane];
        obs_fu_mispredict[lane] <= rtl_fu_mispredict[lane];
        obs_fu_exception[lane] <= rtl_fu_exception[lane];
        obs_fu_target[lane] <= rtl_fu_target[lane];
        obs_fu_cause[lane] <= rtl_fu_cause[lane];
        obs_fu_tval[lane] <= rtl_fu_tval[lane];
        obs_fu_is_mret[lane] <= rtl_fu_is_mret[lane];
        obs_fu_is_sret[lane] <= rtl_fu_is_sret[lane];
        obs_fu_fflags[lane] <= rtl_fu_fflags[lane];
      end
      obs_csr_in_valid <= rtl_csr_in_valid;
      obs_csr_in_tag <= rtl_csr_in_tag;
      obs_csr_in_addr <= rtl_csr_in_addr;
      obs_csr_in_rdata <= rtl_csr_in_rdata;
      obs_csr_in_current_priv <= rtl_csr_in_current_priv;
      obs_csr_in_fs_enabled <= rtl_csr_in_fs_enabled;
      obs_csr_out_valid <= rtl_csr_out_valid;
      obs_csr_out_write_enable <= rtl_csr_out_write_enable;
      obs_csr_out_addr <= rtl_csr_out_addr;
      obs_csr_out_wdata <= rtl_csr_out_wdata;
      obs_csr_out_exec_tag <= rtl_csr_out_exec_tag;
    end
  end

  // ARF snapshot is intentionally not registered here.  The COSIM sampler
  // observes it at negedge, after backend_top's ARF flops have updated on the
  // preceding posedge.
  always_comb begin
    for (int index = 0; index < COSIM_ARF_REG_NUM; index++) begin
      obs_int_arf[index] = (index == 0) ? '0 : rtl_int_arf[index];
      obs_fp_arf[index] = rtl_fp_arf[index];
    end
  end

  // CSR comparison remains disabled until the compared CSR set is frozen.
  assign obs_csr_valid = 1'b0;
  assign obs_csr_state_valid = '0;
  assign obs_csr_state_addr = '0;
  assign obs_csr_state = '0;
  assign obs_csr_event_valid = 1'b0;
  assign obs_csr_event_addr = '0;
  assign obs_csr_event_wdata = '0;
  assign obs_csr_event_rdata = '0;
