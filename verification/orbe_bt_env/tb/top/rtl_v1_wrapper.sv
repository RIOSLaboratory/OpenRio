`timescale 1ns/1ps

`ifdef ORBE_DUT_RTL_V1

module rtl_v1_wrapper (
  input logic clk,
  input logic rst_n,
  orbe_fe_if fe,
  or_be_lsu_if lsu,
  ob_if ob,
  ob_cosim_if #(
    .ISSUE_NUM(or_be_types_pkg::ISSUE_WIDTH),
    .ROB_ADDR_W(or_be_types_pkg::TAG_W),
    .REG_ADDR_W(or_be_types_pkg::REG_ADDR_W),
    .FFLAGS_W(or_be_types_pkg::FFLAGS_W),
    .EXCP_CAUSE_W(or_be_types_pkg::EXCP_CAUSE_W),
    .RECOVERY_KIND_W(or_be_types_pkg::RECOVERY_KIND_W)
  ) ob_cosim
);
  import orbe_cosim_obs_pkg::*;
  import or_be_lsu_protocol_pkg::*;
  import or_be_types_pkg::*;
  import fe_be_protocol_pkg::*;
  typedef struct packed {
    logic [63:0] pc;
    logic [31:0] inst_bits;
    logic is_compressed;
    logic fetch_excp_vld;
    logic [FETCH_EXCP_CAUSE_W-1:0] exception_cause;
    logic [63:0] exception_tval;
    logic is_lsu;
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

  // Level-2 decode observation wires mirror internal RTL decode signals.
  logic [4:0] rtl_rs1_idx [ISSUE_WIDTH];
  logic [4:0] rtl_rs2_idx [ISSUE_WIDTH];
  logic [4:0] rtl_rs3_idx [ISSUE_WIDTH];
  logic [4:0] rtl_rd_idx [ISSUE_WIDTH];
  logic rtl_rs1_is_fp [ISSUE_WIDTH];
  logic rtl_rs2_is_fp [ISSUE_WIDTH];
  logic rtl_rs3_is_fp [ISSUE_WIDTH];
  logic rtl_rd_is_fp [ISSUE_WIDTH];
  logic rtl_use_rs1 [ISSUE_WIDTH];
  logic rtl_use_rs2 [ISSUE_WIDTH];
  logic rtl_use_rs3 [ISSUE_WIDTH];
  logic rtl_use_rd [ISSUE_WIDTH];
  logic rtl_is_store [ISSUE_WIDTH];
  logic rtl_is_lsu [ISSUE_WIDTH];
  logic [2:0] rtl_mem_funct3 [ISSUE_WIDTH];
  logic rtl_imm_valid [ISSUE_WIDTH];
  logic [63:0] rtl_imm_data [ISSUE_WIDTH];
  logic [23:0] rtl_exe_subop [ISSUE_WIDTH];
  logic rtl_is_serial [ISSUE_WIDTH];
  logic rtl_is_fp_instruction [ISSUE_WIDTH];
  logic rtl_is_atomic [ISSUE_WIDTH];
  logic rtl_dec_is_fp_opcode [ISSUE_WIDTH];
  logic [16:0] rtl_full_decode [ISSUE_WIDTH];

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

  logic [ISSUE_WIDTH-1:0] rtl_fe_valid;
  fe_be_instr_pld_t rtl_fe_instr_pld [ISSUE_WIDTH];
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
  logic [TAG_W-1:0] rtl_be_lsu_store_wakeup_tag;
  logic rtl_global_flush;
  logic rtl_lsu_be_writeback_valid;

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

  logic [ISSUE_WIDTH-1:0] obs_alloc_valid;
  rtl_v1_obs_alloc_pld_t [ISSUE_WIDTH-1:0] obs_alloc_pld;
  logic [ISSUE_WIDTH-1:0][TAG_W-1:0] obs_alloc_tag;

  logic [NUM_LANES-1:0] obs_exec_valid;
  logic [63:0] obs_fu_result [NUM_LANES];
  logic obs_fu_mispredict [NUM_LANES];
  logic obs_fu_exception [NUM_LANES];
  logic [63:0] obs_fu_target [NUM_LANES];
  logic [EXCP_CAUSE_W-1:0] obs_fu_cause [NUM_LANES];
  logic [63:0] obs_fu_tval [NUM_LANES];
  logic obs_fu_is_mret [NUM_LANES];
  logic obs_fu_is_sret [NUM_LANES];
  logic [FFLAGS_W-1:0] obs_fu_fflags [NUM_LANES];
  logic [NUM_LANES-1:0][TAG_W-1:0] obs_exec_tag;

  logic [ISSUE_WIDTH-1:0] obs_commit_valid;
  logic [ISSUE_WIDTH-1:0][TAG_W-1:0] obs_commit_tag;
  logic [ISSUE_WIDTH-1:0][63:0] obs_commit_pc;
  logic [ISSUE_WIDTH-1:0][63:0] obs_commit_result;
  logic [ISSUE_WIDTH-1:0][REG_ADDR_W-1:0] obs_commit_rd_idx;
  logic [ISSUE_WIDTH-1:0] obs_commit_rd_is_fp;
  logic [ISSUE_WIDTH-1:0] obs_commit_rd_write_enable;
  logic [ISSUE_WIDTH-1:0][FFLAGS_W-1:0] obs_commit_fflags;
  logic [$clog2(ISSUE_WIDTH+1)-1:0] obs_commit_count;

  logic obs_global_flush;
  logic obs_redirect_valid;
  logic [XLEN-1:0] obs_redirect_pc;
  orbe_recovery_kind_e obs_redirect_kind;
  logic obs_recovery_valid;
  orbe_recovery_kind_e obs_recovery_kind;
  logic [TAG_W-1:0] obs_recovery_origin_tag;
  logic [TAG_W-1:0] obs_recovery_squash_tag;
  logic [63:0] obs_recovery_redirect_pc;
  logic obs_commit_exception_valid;
  logic [EXCP_CAUSE_W-1:0] obs_commit_exception_cause;
  logic [63:0] obs_commit_exception_tval;
  logic obs_commit_redirect_valid;
  logic [RECOVERY_KIND_W-1:0] obs_commit_recovery_kind;
  logic [63:0] obs_commit_redirect_pc;

  logic [COSIM_ARF_REG_NUM-1:0][63:0] obs_int_arf;
  logic [COSIM_ARF_REG_NUM-1:0][63:0] obs_fp_arf;
  logic obs_csr_valid;
  logic [COSIM_CSR_STATE_NUM-1:0] obs_csr_state_valid;
  logic [COSIM_CSR_STATE_NUM-1:0][11:0] obs_csr_state_addr;
  logic [COSIM_CSR_STATE_NUM-1:0][63:0] obs_csr_state;
  logic obs_csr_event_valid;
  logic [11:0] obs_csr_event_addr;
  logic [63:0] obs_csr_event_wdata;
  logic [63:0] obs_csr_event_rdata;

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
  assign rtl_isq3_issue_pld = '{rs1_data:u_backend.isq3_rs1_data, store_data:u_backend.isq3_store_data, imm_valid:u_backend.isq3_imm_valid, imm_data:u_backend.isq3_imm_data, mem_funct3:u_backend.isq3_mem_funct3, rd_is_fp:u_backend.isq3_rd_is_fp, self_tag:u_backend.isq3_entry_self_tag, exe_subop:u_backend.isq3_exe_subop};

  always_comb begin
    for (int group = 0; group < ISSUE_WIDTH; group++) begin
      rtl_fe_valid[group] = fe.fe_be_instr_valid[group];
      rtl_fe_instr_pld[group] = '0;
      rtl_fe_instr_pld[group].pc = fe.fe_be_instr_pld[group].pc;
      rtl_fe_instr_pld[group].inst_bits = fe.fe_be_instr_pld[group].inst_bits;
      rtl_fe_instr_pld[group].is_compressed =
          fe.fe_be_instr_pld[group].is_compressed;
      rtl_fe_instr_pld[group].pred_taken =
          fe.fe_be_instr_pld[group].pred_taken;
      rtl_fe_instr_pld[group].pred_target_pc =
          fe.fe_be_instr_pld[group].pred_target_pc;
      rtl_fe_instr_pld[group].fetch_excp_vld =
          fe.fe_be_instr_pld[group].fetch_excp_vld;
      rtl_fe_instr_pld[group].fetch_excp_cause =
          fe.fe_be_instr_pld[group].exception_cause;
      rtl_fe_instr_pld[group].fetch_excp_tval =
          fe.fe_be_instr_pld[group].exception_tval;
      fe.be_fe_instr_ready[group] = rtl_fe_ready[group];
    end
  end

  always_comb begin
    orbe_recovery_kind_e kind;

    kind = orbe_recovery_kind_e'(rtl_redirect_kind);
    fe.be_fe_redirect_valid = rtl_redirect_valid;
    fe.be_fe_redirect_pld = '0;
    fe.be_fe_redirect_pld.redirect_pc = rtl_redirect_pc;
    fe.be_fe_redirect_pld.interrupt_valid =
        rtl_redirect_valid && (kind == ORBE_RECOVERY_INTERRUPT);
    fe.be_fe_redirect_pld.trap_valid =
        rtl_redirect_valid &&
        ((kind == ORBE_RECOVERY_EXCEPTION) ||
         (kind == ORBE_RECOVERY_MRET) ||
         (kind == ORBE_RECOVERY_SRET));
  end

  assign lsu.be_lsu_issue_valid = rtl_be_lsu_issue_valid;
  // Connect Level-2 LSU boundary signals to the generic observation interface.
  assign ob_cosim.lsu_be_issue_ready = lsu.lsu_be_issue_ready;
  assign ob_cosim.be_lsu_issue_valid = rtl_be_lsu_issue_valid;
  assign ob_cosim.be_lsu_issue_pld = rtl_be_lsu_issue_pld;
  assign ob_cosim.lsu_be_done_valid = lsu.lsu_be_done_valid;
  assign ob_cosim.lsu_be_exception_valid = lsu.lsu_be_exception_valid;
  assign ob_cosim.lsu_be_bypass_valid = lsu.lsu_be_bypass_valid;
  assign ob_cosim.lsu_be_writeback_pld = lsu.lsu_be_writeback_pld;
  assign ob_cosim.lsu_be_bypass_pld = lsu.lsu_be_bypass_pld;
  // Connect the registered allocation snapshot as the decode lifecycle payload.
  genvar decode_group;
  generate
    for (decode_group = 0; decode_group < ISSUE_WIDTH; decode_group++) begin : g_decode_observation
      assign ob_cosim.decode_issue_valid[decode_group] =
          obs_alloc_valid[decode_group];
      assign ob_cosim.decode_issue_pld[decode_group].pc =
          obs_alloc_pld[decode_group].pc;
      assign ob_cosim.decode_issue_pld[decode_group].inst_bits =
          obs_alloc_pld[decode_group].inst_bits;
      assign ob_cosim.decode_issue_pld[decode_group].is_compressed =
          obs_alloc_pld[decode_group].is_compressed;
      assign ob_cosim.decode_issue_pld[decode_group].rs1_idx =
          obs_alloc_pld[decode_group].rs1_idx;
      assign ob_cosim.decode_issue_pld[decode_group].rs2_idx =
          obs_alloc_pld[decode_group].rs2_idx;
      assign ob_cosim.decode_issue_pld[decode_group].rs3_idx =
          obs_alloc_pld[decode_group].rs3_idx;
      assign ob_cosim.decode_issue_pld[decode_group].rd_idx =
          obs_alloc_pld[decode_group].rd_idx;
      assign ob_cosim.decode_issue_pld[decode_group].rs1_is_fp =
          obs_alloc_pld[decode_group].rs1_is_fp;
      assign ob_cosim.decode_issue_pld[decode_group].rs2_is_fp =
          obs_alloc_pld[decode_group].rs2_is_fp;
      assign ob_cosim.decode_issue_pld[decode_group].rs3_is_fp =
          obs_alloc_pld[decode_group].rs3_is_fp;
      assign ob_cosim.decode_issue_pld[decode_group].rd_is_fp =
          obs_alloc_pld[decode_group].rd_is_fp;
      assign ob_cosim.decode_issue_pld[decode_group].use_rs1 =
          obs_alloc_pld[decode_group].use_rs1;
      assign ob_cosim.decode_issue_pld[decode_group].use_rs2 =
          obs_alloc_pld[decode_group].use_rs2;
      assign ob_cosim.decode_issue_pld[decode_group].use_rs3 =
          obs_alloc_pld[decode_group].use_rs3;
      assign ob_cosim.decode_issue_pld[decode_group].use_rd =
          obs_alloc_pld[decode_group].use_rd;
      assign ob_cosim.decode_issue_pld[decode_group].is_store =
          obs_alloc_pld[decode_group].is_store;
      assign ob_cosim.decode_issue_pld[decode_group].mem_funct3 =
          obs_alloc_pld[decode_group].mem_funct3;
      assign ob_cosim.decode_issue_pld[decode_group].imm_valid =
          obs_alloc_pld[decode_group].imm_valid;
      assign ob_cosim.decode_issue_pld[decode_group].imm_data =
          obs_alloc_pld[decode_group].imm_data;
      assign ob_cosim.decode_issue_pld[decode_group].exe_subop =
          obs_alloc_pld[decode_group].exe_subop;
      assign ob_cosim.decode_issue_pld[decode_group].is_serial =
          obs_alloc_pld[decode_group].is_serial;
      assign ob_cosim.decode_issue_pld[decode_group].is_fp_instruction =
          obs_alloc_pld[decode_group].is_fp_instruction;
      assign ob_cosim.decode_issue_pld[decode_group].is_atomic =
          obs_alloc_pld[decode_group].is_atomic;
      assign ob_cosim.decode_issue_pld[decode_group].dec_is_fp_opcode =
          obs_alloc_pld[decode_group].dec_is_fp_opcode;
      assign ob_cosim.decode_issue_pld[decode_group].full_decode =
          obs_alloc_pld[decode_group].full_decode;
    end
  endgenerate
  // Connect the registered FU-after snapshot for writeback lifecycle logging.
  assign ob_cosim.fu_after_valid = obs_exec_valid;
  genvar lane;
  generate
    for (lane = 0; lane < ISSUE_WIDTH; lane++) begin : g_l2_fu
    assign ob_cosim.fu_after_tag[lane] = obs_exec_tag[lane];
    assign ob_cosim.fu_after_result[lane] = obs_fu_result[lane];
    assign ob_cosim.fu_after_mispredict[lane] = obs_fu_mispredict[lane];
    assign ob_cosim.fu_after_exception[lane] = obs_fu_exception[lane];
    assign ob_cosim.fu_after_target[lane] = obs_fu_target[lane];
    assign ob_cosim.fu_after_cause[lane] = obs_fu_cause[lane];
    assign ob_cosim.fu_after_tval[lane] = obs_fu_tval[lane];
    assign ob_cosim.fu_after_is_mret[lane] = obs_fu_is_mret[lane];
    assign ob_cosim.fu_after_is_sret[lane] = obs_fu_is_sret[lane];
    assign ob_cosim.fu_after_fflags[lane] = obs_fu_fflags[lane];
    end
  endgenerate
  assign lsu.be_lsu_issue_pld = rtl_be_lsu_issue_pld;
  assign lsu.be_lsu_store_wakeup_valid = rtl_be_lsu_store_wakeup_valid;
  assign lsu.global_flush_late = rtl_global_flush;
  assign lsu.be_lsu_entry_ready = rst_n && !rtl_global_flush;
  assign rtl_lsu_be_writeback_valid =
      lsu.lsu_be_done_valid || lsu.lsu_be_exception_valid;

  always_comb begin
    ob.alloc_valid = '0;
    ob.alloc_pld = '{default:'0};
    ob.alloc_tag = '0;
    ob.rob_alloc_valid = '0;
    ob.rob_alloc_pld = '{default:'0};
    ob.rob_alloc_rob_idx = '0;
    ob.rob_alloc_rob_ptr = '0;
    for (int group = 0; group < ISSUE_WIDTH; group++) begin
      ob.alloc_valid[group] = obs_alloc_valid[group];
      ob.alloc_tag[group] = obs_alloc_tag[group];
      ob.alloc_pld[group].pc = obs_alloc_pld[group].pc;
      ob.alloc_pld[group].inst_bits = obs_alloc_pld[group].inst_bits;
      ob.alloc_pld[group].is_compressed =
          obs_alloc_pld[group].is_compressed;
      ob.alloc_pld[group].fetch_excp_vld =
          obs_alloc_pld[group].fetch_excp_vld;
      ob.alloc_pld[group].exception_cause =
          obs_alloc_pld[group].exception_cause;
      ob.alloc_pld[group].exception_tval =
          obs_alloc_pld[group].exception_tval;
      ob.alloc_pld[group].is_lsu = obs_alloc_pld[group].is_lsu;

      ob.rob_alloc_valid[group] = ob.alloc_valid[group];
      ob.rob_alloc_pld[group] = ob.alloc_pld[group];
      ob.rob_alloc_rob_idx[group] = ob.alloc_tag[group];
      ob.rob_alloc_rob_ptr[group][TAG_W-1:0] =
          obs_alloc_tag[group][TAG_W-1:0];
    end

    ob.exec_valid = '0;
    ob.exec_tag = '0;
    ob.exe_rob_wr_vld = '0;
    ob.exe_rob_wr_idx = '0;
    for (int source = 0; source < NUM_LANES; source++) begin
      ob.exec_valid[source] = obs_exec_valid[source];
      ob.exec_tag[source] = obs_exec_tag[source];
      ob.exe_rob_wr_vld[source] = ob.exec_valid[source];
      ob.exe_rob_wr_idx[source] = ob.exec_tag[source];
    end

    ob.commit_valid = '0;
    ob.commit_tag = '0;
    ob.commit_pc = '0;
    ob.rob_commit_valid = '0;
    ob.rob_commit_pld = '{default:'0};
    ob.rob_commit_rob_idx = '0;
    for (int group = 0; group < ISSUE_WIDTH; group++) begin
      ob.commit_valid[group] = obs_commit_valid[group];
      ob.commit_tag[group] = obs_commit_tag[group];
      ob.commit_pc[group] = obs_commit_pc[group];
      ob.rob_commit_valid[group] = ob.commit_valid[group];
      ob.rob_commit_pld[group].pc = ob.commit_pc[group];
      ob.rob_commit_pld[group].rob_idx = ob.commit_tag[group];
      ob.rob_commit_rob_idx[group] = ob.commit_tag[group];
    end
    ob.commit_count = obs_commit_count;

    ob.global_flush = obs_global_flush;
    ob.redirect_valid = obs_redirect_valid;
    ob.redirect_pc = obs_redirect_pc;
    ob.redirect_kind = obs_redirect_kind;
    ob.recovery_valid = obs_recovery_valid;
    ob.recovery_kind = obs_recovery_kind;
    ob.recovery_origin_tag = obs_recovery_origin_tag;
    ob.recovery_squash_tag = obs_recovery_squash_tag;
    ob.recovery_redirect_pc = obs_recovery_redirect_pc;

    ob.flush_all = '0;
    if (ob.recovery_valid &&
        ((obs_recovery_kind == ORBE_RECOVERY_EXCEPTION) ||
         (obs_recovery_kind == ORBE_RECOVERY_INTERRUPT)))
      ob.flush_all = '1;
    ob.pflush = ob.recovery_valid && (ob.flush_all == '0);
    ob.pflush_rob_idx = obs_recovery_origin_tag;
  end

  assign ob_cosim.commit_valid = obs_commit_valid;
  assign ob_cosim.commit_rob_idx = obs_commit_tag;
  assign ob_cosim.commit_pc = obs_commit_pc;
  assign ob_cosim.commit_result = obs_commit_result;
  assign ob_cosim.commit_rd_idx = obs_commit_rd_idx;
  assign ob_cosim.commit_rd_is_fp = obs_commit_rd_is_fp;
  assign ob_cosim.commit_rd_write_enable = obs_commit_rd_write_enable;
  assign ob_cosim.commit_fflags = obs_commit_fflags;
  assign ob_cosim.commit_exception_valid = obs_commit_exception_valid;
  assign ob_cosim.commit_exception_cause = obs_commit_exception_cause;
  assign ob_cosim.commit_exception_tval = obs_commit_exception_tval;
  assign ob_cosim.commit_redirect_valid = obs_commit_redirect_valid;
  assign ob_cosim.commit_recovery_kind = obs_commit_recovery_kind;
  assign ob_cosim.commit_redirect_pc = obs_commit_redirect_pc;
  assign ob_cosim.int_arf = obs_int_arf;
  assign ob_cosim.fp_arf = obs_fp_arf;
  assign ob_cosim.csr_valid = obs_csr_valid;
  assign ob_cosim.csr_state_valid = obs_csr_state_valid;
  assign ob_cosim.csr_state_addr = obs_csr_state_addr;
  assign ob_cosim.csr_state = obs_csr_state;
  assign ob_cosim.csr_event_valid = obs_csr_event_valid;
  assign ob_cosim.csr_event_addr = obs_csr_event_addr;
  assign ob_cosim.csr_event_wdata = obs_csr_event_wdata;
  assign ob_cosim.csr_event_rdata = obs_csr_event_rdata;

  backend_top u_backend (
    .clk(clk),
    .rst_n(rst_n),
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
    .be_lsu_store_wakeup_tag(rtl_be_lsu_store_wakeup_tag),
    .global_flush(rtl_global_flush),
    .lsu_be_issue_ready(lsu.lsu_be_issue_ready),
    .lsu_be_writeback_valid(rtl_lsu_be_writeback_valid),
    .lsu_be_writeback_pld(lsu.lsu_be_writeback_pld),
    .lsu_be_bypass_valid(lsu.lsu_be_bypass_valid),
    .lsu_be_bypass_pld(lsu.lsu_be_bypass_pld),
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

  rtl_v1_obs_probe u_obs_probe (
    .clk                   (clk),
    .rst_n                 (rst_n),
    .rtl_alloc_valid       (rtl_alloc_valid),
    .rtl_is_lsu            (rtl_is_lsu),
    .rtl_alloc_tag         (rtl_alloc_tag),
    .rtl_alloc_payload     (u_backend.head_IB_Payload),
    .rtl_rs1_idx           (rtl_rs1_idx),
    .rtl_rs2_idx           (rtl_rs2_idx),
    .rtl_rs3_idx           (rtl_rs3_idx),
    .rtl_rd_idx            (rtl_rd_idx),
    .rtl_rs1_is_fp         (rtl_rs1_is_fp),
    .rtl_rs2_is_fp         (rtl_rs2_is_fp),
    .rtl_rs3_is_fp         (rtl_rs3_is_fp),
    .rtl_rd_is_fp          (rtl_rd_is_fp),
    .rtl_use_rs1           (rtl_use_rs1),
    .rtl_use_rs2           (rtl_use_rs2),
    .rtl_use_rs3           (rtl_use_rs3),
    .rtl_use_rd            (rtl_use_rd),
    .rtl_is_store          (rtl_is_store),
    .rtl_mem_funct3        (rtl_mem_funct3),
    .rtl_imm_valid         (rtl_imm_valid),
    .rtl_imm_data          (rtl_imm_data),
    .rtl_exe_subop         (rtl_exe_subop),
    .rtl_is_serial         (rtl_is_serial),
    .rtl_is_fp_instruction (rtl_is_fp_instruction),
    .rtl_is_atomic         (rtl_is_atomic),
    .rtl_dec_is_fp_opcode  (rtl_dec_is_fp_opcode),
    .rtl_full_decode       (rtl_full_decode),
    .rtl_exec_valid        (rtl_exec_valid),
    .rtl_exec_tag          (rtl_exec_tag),
    .rtl_fu_result         (u_backend.lane_result_data),
    .rtl_fu_mispredict     (u_backend.lane_mispredict_flag),
    .rtl_fu_exception      (u_backend.lane_exception_flag),
    .rtl_fu_target         (u_backend.lane_mispredict_target_pc),
    .rtl_fu_cause          (u_backend.lane_exception_cause),
    .rtl_fu_tval           (u_backend.lane_exception_tval),
    .rtl_fu_is_mret        (u_backend.lane_is_mret),
    .rtl_fu_is_sret        (u_backend.lane_is_sret),
    .rtl_fu_fflags         (u_backend.lane_fpu_fflags),
    .rtl_isq_g0_issue_valid (u_backend.isq0_issue_valid),
    .rtl_isq_g0_issue_pld   (rtl_isq0_issue_pld),
    .rtl_isq_g1_issue_valid (u_backend.isq1_issue_valid),
    .rtl_isq_g1_issue_pld   (rtl_isq1_issue_pld),
    .rtl_isq_g2_issue_valid (u_backend.isq2_issue_valid),
    .rtl_isq_g2_issue_pld   (rtl_isq2_issue_pld),
    .rtl_isq_g3_issue_valid (u_backend.isq3_issue_valid),
    .rtl_isq_g3_issue_pld   (rtl_isq3_issue_pld),
    .rtl_csr_in_valid       (u_backend.u_csr_unit.accept),
    .rtl_csr_in_tag         (u_backend.isq0_self_tag),
    .rtl_csr_in_addr        (u_backend.csrfu_csr_addr),
    .rtl_csr_in_rdata       (u_backend.sih_csr_rdata),
    .rtl_csr_in_current_priv(u_backend.sih_current_priv),
    .rtl_csr_in_fs_enabled  (u_backend.sih_fs_enabled),
    .rtl_csr_out_valid       (u_backend.arbG0_csr_sideband_valid),
    .rtl_csr_out_write_enable(u_backend.arbG0_csr_write_enable),
    .rtl_csr_out_addr        (u_backend.arbG0_csr_addr),
    .rtl_csr_out_wdata       (u_backend.arbG0_csr_wdata),
    .rtl_csr_out_exec_tag    (u_backend.exec_tag[0]),
    .rtl_commit_valid      (rtl_commit_valid),
    .rtl_commit_tag        (rtl_commit_tag),
    .rtl_commit_rd_idx     (rtl_commit_rd_idx),
    .rtl_commit_rd_is_fp   (rtl_commit_rd_is_fp),
    .rtl_commit_rd_write_enable(rtl_commit_rd_write_enable),
    .rtl_commit_fflags     (rtl_commit_fflags),
    .rtl_commit_result     (rtl_commit_data),
    .rtl_commit_count      (rtl_commit_count),
    .rtl_trace_pc          (rtl_trace_pc),
    .rtl_global_flush      (rtl_global_flush),
    .rtl_redirect_valid    (rtl_redirect_valid),
    .rtl_redirect_pc       (rtl_redirect_pc),
    .rtl_redirect_kind     (rtl_redirect_kind),
    .rtl_recovery_flush_tag(u_backend.scb_flush_tag),
    .rtl_exception_cause   (u_backend.scb_recovery_exception_cause),
    .rtl_exception_tval    (u_backend.scb_recovery_exception_tval),
    .rtl_int_arf           (u_backend.u_INT_ARF.entry_arf),
    .rtl_fp_arf            (u_backend.u_FP_ARF.entry_arf),
    .obs_alloc_valid       (obs_alloc_valid),
    .obs_alloc_pld         (obs_alloc_pld),
    .obs_alloc_tag         (obs_alloc_tag),
    .obs_exec_valid        (obs_exec_valid),
    .obs_fu_result         (obs_fu_result),
    .obs_fu_mispredict     (obs_fu_mispredict),
    .obs_fu_exception      (obs_fu_exception),
    .obs_fu_target         (obs_fu_target),
    .obs_fu_cause          (obs_fu_cause),
    .obs_fu_tval           (obs_fu_tval),
    .obs_fu_is_mret        (obs_fu_is_mret),
    .obs_fu_is_sret        (obs_fu_is_sret),
    .obs_fu_fflags         (obs_fu_fflags),
    .obs_exec_tag          (obs_exec_tag),
    .obs_commit_valid      (obs_commit_valid),
    .obs_commit_tag        (obs_commit_tag),
    .obs_commit_pc         (obs_commit_pc),
    .obs_commit_result     (obs_commit_result),
    .obs_commit_rd_idx     (obs_commit_rd_idx),
    .obs_commit_rd_is_fp   (obs_commit_rd_is_fp),
    .obs_commit_rd_write_enable(obs_commit_rd_write_enable),
    .obs_commit_fflags     (obs_commit_fflags),
    .obs_commit_count      (obs_commit_count),
    .obs_global_flush      (obs_global_flush),
    .obs_redirect_valid    (obs_redirect_valid),
    .obs_redirect_pc       (obs_redirect_pc),
    .obs_redirect_kind     (obs_redirect_kind),
    .obs_recovery_valid    (obs_recovery_valid),
    .obs_recovery_kind     (obs_recovery_kind),
    .obs_recovery_origin_tag(obs_recovery_origin_tag),
    .obs_recovery_squash_tag(obs_recovery_squash_tag),
    .obs_recovery_redirect_pc(obs_recovery_redirect_pc),
    .obs_commit_exception_valid(obs_commit_exception_valid),
    .obs_commit_exception_cause(obs_commit_exception_cause),
    .obs_commit_exception_tval(obs_commit_exception_tval),
    .obs_commit_redirect_valid(obs_commit_redirect_valid),
    .obs_commit_recovery_kind(obs_commit_recovery_kind),
    .obs_commit_redirect_pc(obs_commit_redirect_pc),
    .obs_int_arf           (obs_int_arf),
    .obs_fp_arf            (obs_fp_arf),
    .obs_csr_valid         (obs_csr_valid),
    .obs_csr_state_valid   (obs_csr_state_valid),
    .obs_csr_state_addr    (obs_csr_state_addr),
    .obs_csr_state         (obs_csr_state),
    .obs_csr_event_valid   (obs_csr_event_valid),
    .obs_csr_event_addr    (obs_csr_event_addr),
    .obs_csr_event_wdata   (obs_csr_event_wdata),
    .obs_csr_event_rdata   (obs_csr_event_rdata),
    .obs_isq_g0_issue_valid (ob_cosim.isq_g0_issue_valid),
    .obs_isq_g0_issue_pld   (ob_cosim.isq_g0_issue_pld),
    .obs_isq_g1_issue_valid (ob_cosim.isq_g1_issue_valid),
    .obs_isq_g1_issue_pld   (ob_cosim.isq_g1_issue_pld),
    .obs_isq_g2_issue_valid (ob_cosim.isq_g2_issue_valid),
    .obs_isq_g2_issue_pld   (ob_cosim.isq_g2_issue_pld),
    .obs_isq_g3_issue_valid (ob_cosim.isq_g3_issue_valid),
    .obs_isq_g3_issue_pld   (ob_cosim.isq_g3_issue_pld),
    .obs_csr_in_valid        (ob_cosim.csr_in_valid),
    .obs_csr_in_tag          (ob_cosim.csr_in_tag),
    .obs_csr_in_addr         (ob_cosim.csr_in_addr),
    .obs_csr_in_rdata        (ob_cosim.csr_in_rdata),
    .obs_csr_in_current_priv (ob_cosim.csr_in_current_priv),
    .obs_csr_in_fs_enabled   (ob_cosim.csr_in_fs_enabled),
    .obs_csr_out_valid        (ob_cosim.csr_out_valid),
    .obs_csr_out_write_enable (ob_cosim.csr_out_write_enable),
    .obs_csr_out_addr         (ob_cosim.csr_out_addr),
    .obs_csr_out_wdata        (ob_cosim.csr_out_wdata),
    .obs_csr_out_exec_tag     (ob_cosim.csr_out_exec_tag)
  );

endmodule

`endif
