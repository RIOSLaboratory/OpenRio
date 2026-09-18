`timescale 1ns/1ps

`ifdef ORBE_DUT_RTL_V1

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

// RTL-near observation source for rtl_v1/backend_top.
//
// This module owns the temporary white-box observation points needed by the
// verification environment.  rtl_v1_wrapper maps its stable outputs to ob_if
// and ob_cosim_if; be_agent and COSIM code must not read backend_top internals.
module rtl_v1_obs_probe (
  input logic clk,
  input logic rst_n,

  // Allocation and decode observation inputs.
  input logic rtl_alloc_valid [or_be_types_pkg::ISSUE_WIDTH],
  input logic rtl_is_lsu [or_be_types_pkg::ISSUE_WIDTH],
  input logic [or_be_types_pkg::TAG_W-1:0]
      rtl_alloc_tag [or_be_types_pkg::ISSUE_WIDTH],
  input or_be_types_pkg::ib_payload_t
      rtl_alloc_payload [or_be_types_pkg::ISSUE_WIDTH],
  input logic [4:0] rtl_rs1_idx [or_be_types_pkg::ISSUE_WIDTH],
  input logic [4:0] rtl_rs2_idx [or_be_types_pkg::ISSUE_WIDTH],
  input logic [4:0] rtl_rs3_idx [or_be_types_pkg::ISSUE_WIDTH],
  input logic [4:0] rtl_rd_idx [or_be_types_pkg::ISSUE_WIDTH],
  input logic rtl_rs1_is_fp [or_be_types_pkg::ISSUE_WIDTH],
  input logic rtl_rs2_is_fp [or_be_types_pkg::ISSUE_WIDTH],
  input logic rtl_rs3_is_fp [or_be_types_pkg::ISSUE_WIDTH],
  input logic rtl_rd_is_fp [or_be_types_pkg::ISSUE_WIDTH],
  input logic rtl_use_rs1 [or_be_types_pkg::ISSUE_WIDTH],
  input logic rtl_use_rs2 [or_be_types_pkg::ISSUE_WIDTH],
  input logic rtl_use_rs3 [or_be_types_pkg::ISSUE_WIDTH],
  input logic rtl_use_rd [or_be_types_pkg::ISSUE_WIDTH],
  input logic rtl_is_store [or_be_types_pkg::ISSUE_WIDTH],
  input logic [2:0] rtl_mem_funct3 [or_be_types_pkg::ISSUE_WIDTH],
  input logic rtl_imm_valid [or_be_types_pkg::ISSUE_WIDTH],
  input logic [63:0] rtl_imm_data [or_be_types_pkg::ISSUE_WIDTH],
  input logic [23:0] rtl_exe_subop [or_be_types_pkg::ISSUE_WIDTH],
  input logic rtl_is_serial [or_be_types_pkg::ISSUE_WIDTH],
  input logic rtl_is_fp_instruction [or_be_types_pkg::ISSUE_WIDTH],
  input logic rtl_is_atomic [or_be_types_pkg::ISSUE_WIDTH],
  input logic rtl_dec_is_fp_opcode [or_be_types_pkg::ISSUE_WIDTH],
  input logic [16:0] rtl_full_decode [or_be_types_pkg::ISSUE_WIDTH],

  input logic rtl_exec_valid [or_be_types_pkg::NUM_LANES],
  input logic [or_be_types_pkg::TAG_W-1:0]
      rtl_exec_tag [or_be_types_pkg::NUM_LANES],
  input logic [63:0] rtl_fu_result [or_be_types_pkg::NUM_LANES],
  input logic rtl_fu_mispredict [or_be_types_pkg::NUM_LANES],
  input logic rtl_fu_exception [or_be_types_pkg::NUM_LANES],
  input logic [63:0] rtl_fu_target [or_be_types_pkg::NUM_LANES],
  input logic [or_be_types_pkg::EXCP_CAUSE_W-1:0] rtl_fu_cause [or_be_types_pkg::NUM_LANES],
  input logic [63:0] rtl_fu_tval [or_be_types_pkg::NUM_LANES],
  input logic rtl_fu_is_mret [or_be_types_pkg::NUM_LANES],
  input logic rtl_fu_is_sret [or_be_types_pkg::NUM_LANES],
  input logic [or_be_types_pkg::FFLAGS_W-1:0] rtl_fu_fflags [or_be_types_pkg::NUM_LANES],

  input logic rtl_commit_valid [or_be_types_pkg::ISSUE_WIDTH],
  input logic [or_be_types_pkg::TAG_W-1:0]
      rtl_commit_tag [or_be_types_pkg::ISSUE_WIDTH],
  input logic [or_be_types_pkg::REG_ADDR_W-1:0]
      rtl_commit_rd_idx [or_be_types_pkg::ISSUE_WIDTH],
  input logic rtl_commit_rd_is_fp [or_be_types_pkg::ISSUE_WIDTH],
  input logic rtl_commit_rd_write_enable [or_be_types_pkg::ISSUE_WIDTH],
  input logic [or_be_types_pkg::FFLAGS_W-1:0]
      rtl_commit_fflags [or_be_types_pkg::ISSUE_WIDTH],
  input logic [or_be_types_pkg::XLEN-1:0]
      rtl_commit_result [or_be_types_pkg::ISSUE_WIDTH],
  input logic [or_be_types_pkg::COMMIT_COUNT_W-1:0] rtl_commit_count,
  input logic [or_be_types_pkg::XLEN-1:0]
      rtl_trace_pc [or_be_types_pkg::ISSUE_WIDTH],

  input logic rtl_global_flush,
  input logic rtl_redirect_valid,
  input logic [or_be_types_pkg::XLEN-1:0] rtl_redirect_pc,
  input logic [or_be_types_pkg::RECOVERY_KIND_W-1:0] rtl_redirect_kind,
  input logic [or_be_types_pkg::TAG_W-1:0] rtl_recovery_flush_tag,
  input logic [or_be_types_pkg::EXCP_CAUSE_W-1:0] rtl_exception_cause,
  input logic [or_be_types_pkg::XLEN-1:0] rtl_exception_tval,

  input logic [or_be_types_pkg::XLEN-1:0]
      rtl_int_arf [or_be_types_pkg::NUM_GPR],
  input logic [or_be_types_pkg::XLEN-1:0]
      rtl_fp_arf [or_be_types_pkg::NUM_FPR],

  output logic [or_be_types_pkg::ISSUE_WIDTH-1:0] obs_alloc_valid,
  output rtl_v1_obs_alloc_pld_t
      [or_be_types_pkg::ISSUE_WIDTH-1:0] obs_alloc_pld,
  output logic [or_be_types_pkg::ISSUE_WIDTH-1:0]
      [or_be_types_pkg::TAG_W-1:0] obs_alloc_tag,

  output logic [or_be_types_pkg::NUM_LANES-1:0] obs_exec_valid,
  output logic [or_be_types_pkg::NUM_LANES-1:0]
      [or_be_types_pkg::TAG_W-1:0] obs_exec_tag,

  output logic [or_be_types_pkg::ISSUE_WIDTH-1:0] obs_commit_valid,
  output logic [or_be_types_pkg::ISSUE_WIDTH-1:0]
      [or_be_types_pkg::TAG_W-1:0] obs_commit_tag,
  output logic [or_be_types_pkg::ISSUE_WIDTH-1:0][63:0] obs_commit_pc,
  output logic [or_be_types_pkg::ISSUE_WIDTH-1:0][63:0] obs_commit_result,
  output logic [or_be_types_pkg::ISSUE_WIDTH-1:0][or_be_types_pkg::REG_ADDR_W-1:0]
      obs_commit_rd_idx,
  output logic [or_be_types_pkg::ISSUE_WIDTH-1:0] obs_commit_rd_is_fp,
  output logic [or_be_types_pkg::ISSUE_WIDTH-1:0] obs_commit_rd_write_enable,
  output logic [or_be_types_pkg::ISSUE_WIDTH-1:0][or_be_types_pkg::FFLAGS_W-1:0]
      obs_commit_fflags,
  output logic [$clog2(or_be_types_pkg::ISSUE_WIDTH+1)-1:0]
      obs_commit_count,

  output logic obs_global_flush,
  output logic obs_redirect_valid,
  output logic [or_be_types_pkg::XLEN-1:0] obs_redirect_pc,
  output orbe_cosim_obs_pkg::orbe_recovery_kind_e obs_redirect_kind,
  output logic obs_recovery_valid,
  output orbe_cosim_obs_pkg::orbe_recovery_kind_e obs_recovery_kind,
  output logic [or_be_types_pkg::TAG_W-1:0] obs_recovery_origin_tag,
  output logic [or_be_types_pkg::TAG_W-1:0] obs_recovery_squash_tag,
  output logic [63:0] obs_recovery_redirect_pc,
  output logic obs_commit_exception_valid,
  output logic [or_be_types_pkg::EXCP_CAUSE_W-1:0] obs_commit_exception_cause,
  output logic [63:0] obs_commit_exception_tval,
  output logic obs_commit_redirect_valid,
  output logic [or_be_types_pkg::RECOVERY_KIND_W-1:0] obs_commit_recovery_kind,
  output logic [63:0] obs_commit_redirect_pc,

  output logic [orbe_cosim_obs_pkg::COSIM_ARF_REG_NUM-1:0][63:0]
      obs_int_arf,
  output logic [orbe_cosim_obs_pkg::COSIM_ARF_REG_NUM-1:0][63:0]
      obs_fp_arf,
  output logic obs_csr_valid,
  output logic [orbe_cosim_obs_pkg::COSIM_CSR_STATE_NUM-1:0]
      obs_csr_state_valid,
  output logic [orbe_cosim_obs_pkg::COSIM_CSR_STATE_NUM-1:0][11:0]
      obs_csr_state_addr,
  output logic [orbe_cosim_obs_pkg::COSIM_CSR_STATE_NUM-1:0][63:0]
      obs_csr_state,
  output logic [63:0] obs_fu_result [or_be_types_pkg::NUM_LANES],
  output logic obs_fu_mispredict [or_be_types_pkg::NUM_LANES],
  output logic obs_fu_exception [or_be_types_pkg::NUM_LANES],
  output logic [63:0] obs_fu_target [or_be_types_pkg::NUM_LANES],
  output logic [or_be_types_pkg::EXCP_CAUSE_W-1:0] obs_fu_cause [or_be_types_pkg::NUM_LANES],
  output logic [63:0] obs_fu_tval [or_be_types_pkg::NUM_LANES],
  output logic obs_fu_is_mret [or_be_types_pkg::NUM_LANES],
  output logic obs_fu_is_sret [or_be_types_pkg::NUM_LANES],
  output logic [or_be_types_pkg::FFLAGS_W-1:0] obs_fu_fflags [or_be_types_pkg::NUM_LANES],
  output logic obs_csr_event_valid,
  output logic [11:0] obs_csr_event_addr,
  output logic [63:0] obs_csr_event_wdata,
  output logic [63:0] obs_csr_event_rdata,
  input logic rtl_isq_g0_issue_valid,
  input orbe_cosim_obs_pkg::cosim_isq_g0_issue_pld_t rtl_isq_g0_issue_pld,
  input logic rtl_isq_g1_issue_valid,
  input orbe_cosim_obs_pkg::cosim_isq_g1_issue_pld_t rtl_isq_g1_issue_pld,
  input logic rtl_isq_g2_issue_valid,
  input orbe_cosim_obs_pkg::cosim_isq_g2_issue_pld_t rtl_isq_g2_issue_pld,
  input logic rtl_isq_g3_issue_valid,
  input orbe_cosim_obs_pkg::cosim_isq_g3_issue_pld_t rtl_isq_g3_issue_pld,
  input logic rtl_csr_in_valid,
  input logic [or_be_types_pkg::TAG_W-1:0] rtl_csr_in_tag,
  input logic [11:0] rtl_csr_in_addr,
  input logic [63:0] rtl_csr_in_rdata,
  input logic [2:0] rtl_csr_in_current_priv,
  input logic rtl_csr_in_fs_enabled,
  input logic rtl_csr_out_valid,
  input logic rtl_csr_out_write_enable,
  input logic [11:0] rtl_csr_out_addr,
  input logic [63:0] rtl_csr_out_wdata,
  input logic [or_be_types_pkg::TAG_W-1:0] rtl_csr_out_exec_tag,
  output logic obs_isq_g0_issue_valid,
  output orbe_cosim_obs_pkg::cosim_isq_g0_issue_pld_t obs_isq_g0_issue_pld,
  output logic obs_isq_g1_issue_valid,
  output orbe_cosim_obs_pkg::cosim_isq_g1_issue_pld_t obs_isq_g1_issue_pld,
  output logic obs_isq_g2_issue_valid,
  output orbe_cosim_obs_pkg::cosim_isq_g2_issue_pld_t obs_isq_g2_issue_pld,
  output logic obs_isq_g3_issue_valid,
  output orbe_cosim_obs_pkg::cosim_isq_g3_issue_pld_t obs_isq_g3_issue_pld,
  output logic obs_csr_in_valid,
  output logic [or_be_types_pkg::TAG_W-1:0] obs_csr_in_tag,
  output logic [11:0] obs_csr_in_addr,
  output logic [63:0] obs_csr_in_rdata,
  output logic [2:0] obs_csr_in_current_priv,
  output logic obs_csr_in_fs_enabled,
  output logic obs_csr_out_valid,
  output logic obs_csr_out_write_enable,
  output logic [11:0] obs_csr_out_addr,
  output logic [63:0] obs_csr_out_wdata,
  output logic [or_be_types_pkg::TAG_W-1:0] obs_csr_out_exec_tag
);
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

  initial begin
    if (OBS_ISSUE_NUM != ISSUE_WIDTH)
      $fatal(1, "[RTL_V1_OBS] issue width mismatch env=%0d rtl=%0d",
             OBS_ISSUE_NUM, ISSUE_WIDTH);
    if (OBS_ROB_NUM != NUM_LANES)
      $fatal(1, "[RTL_V1_OBS] completion source mismatch env=%0d rtl=%0d",
             OBS_ROB_NUM, NUM_LANES);
    if (OBS_ROB_ADDR_W < TAG_W)
      $fatal(1, "[RTL_V1_OBS] observation ROB index width %0d is narrower than rtl tag width %0d",
             OBS_ROB_ADDR_W, TAG_W);
    if (COSIM_ARF_REG_NUM != NUM_GPR || COSIM_ARF_REG_NUM != NUM_FPR)
      $fatal(1, "[RTL_V1_OBS] ARF snapshot count mismatch cosim=%0d int=%0d fp=%0d",
             COSIM_ARF_REG_NUM, NUM_GPR, NUM_FPR);
  end

  // Register only the event observation copy.  rtl_v1's commit/recovery
  // outputs are cycle-start combinational requests; be_agent samples at
  // negedge and must see them after the RTL sequential state has consumed
  // them at posedge.
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
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
endmodule

`endif
