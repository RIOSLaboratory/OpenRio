`timescale 1ns/1ps

`ifdef ORBE_DUT_MOCK

// MOCK_RTL-near observation source.
//
// mock_rtl already registers its alloc/execute/commit/recovery observation
// events. This probe therefore only normalizes those signals into the same
// obs_* bundle shape used by rtl_v1_obs_probe; it intentionally does not add
// another event cycle of latency.
module mock_obs_probe (
  input logic clk,
  input logic rst_n,

  input logic [mock_rtl_pkg::MOCK_ISSUE_NUM-1:0] mock_rob_alloc_valid,
  input mock_rtl_pkg::rob_alloc_pld_t
      [mock_rtl_pkg::MOCK_ISSUE_NUM-1:0] mock_rob_alloc_pld,
  input logic [mock_rtl_pkg::MOCK_ISSUE_NUM-1:0]
      [mock_rtl_pkg::MOCK_ROB_ADDR_W-1:0] mock_rob_alloc_rob_idx,
  input logic [mock_rtl_pkg::MOCK_ISSUE_NUM-1:0]
      [mock_rtl_pkg::MOCK_ROB_PTR_W-1:0] mock_rob_alloc_rob_ptr,

  input logic [mock_rtl_pkg::MOCK_ISSUE_NUM-1:0] mock_rob_commit_valid,
  input mock_rtl_pkg::rob_commit_pld_t
      [mock_rtl_pkg::MOCK_ISSUE_NUM-1:0] mock_rob_commit_pld,
  input logic [mock_rtl_pkg::MOCK_ISSUE_NUM-1:0]
      [mock_rtl_pkg::MOCK_ROB_ADDR_W-1:0] mock_rob_commit_rob_idx,

  input logic [mock_rtl_pkg::MOCK_ROB_CMT_NUM-1:0] mock_exe_rob_wr_vld,
  input logic [mock_rtl_pkg::MOCK_ROB_CMT_NUM-1:0]
      [mock_rtl_pkg::MOCK_ROB_ADDR_W-1:0] mock_exe_rob_wr_idx,

  input logic [mock_rtl_pkg::MOCK_FLUSH_ALL_DUP-1:0] mock_flush_all,
  input logic mock_pflush,
  input logic [mock_rtl_pkg::MOCK_ROB_ADDR_W-1:0] mock_pflush_rob_idx,
  input logic mock_redirect_valid,
  input logic [mock_rtl_pkg::MOCK_VPC_W-1:0] mock_redirect_pc,

  output logic [mock_rtl_pkg::MOCK_ISSUE_NUM-1:0] obs_alloc_valid,
  output mock_rtl_pkg::rob_alloc_pld_t
      [mock_rtl_pkg::MOCK_ISSUE_NUM-1:0] obs_alloc_pld,
  output logic [mock_rtl_pkg::MOCK_ISSUE_NUM-1:0]
      [mock_rtl_pkg::MOCK_ROB_ADDR_W-1:0] obs_alloc_tag,
  output logic [mock_rtl_pkg::MOCK_ISSUE_NUM-1:0]
      [mock_rtl_pkg::MOCK_ROB_PTR_W-1:0] obs_alloc_ptr,

  output logic [mock_rtl_pkg::MOCK_ROB_CMT_NUM-1:0] obs_exec_valid,
  output logic [mock_rtl_pkg::MOCK_ROB_CMT_NUM-1:0]
      [mock_rtl_pkg::MOCK_ROB_ADDR_W-1:0] obs_exec_tag,

  output logic [mock_rtl_pkg::MOCK_ISSUE_NUM-1:0] obs_commit_valid,
  output logic [mock_rtl_pkg::MOCK_ISSUE_NUM-1:0]
      [mock_rtl_pkg::MOCK_ROB_ADDR_W-1:0] obs_commit_tag,
  output logic [mock_rtl_pkg::MOCK_ISSUE_NUM-1:0]
      [mock_rtl_pkg::MOCK_ROB_PTR_W-1:0] obs_commit_ptr,
  output logic [mock_rtl_pkg::MOCK_ISSUE_NUM-1:0][63:0] obs_commit_pc,
  output logic [$clog2(mock_rtl_pkg::MOCK_ISSUE_NUM+1)-1:0]
      obs_commit_count,

  output logic obs_global_flush,
  output logic obs_redirect_valid,
  output logic [mock_rtl_pkg::MOCK_VPC_W-1:0] obs_redirect_pc,
  output orbe_cosim_obs_pkg::orbe_recovery_kind_e obs_redirect_kind,
  output logic obs_recovery_valid,
  output orbe_cosim_obs_pkg::orbe_recovery_kind_e obs_recovery_kind,
  output logic [mock_rtl_pkg::MOCK_ROB_ADDR_W-1:0] obs_recovery_origin_tag,
  output logic [mock_rtl_pkg::MOCK_ROB_ADDR_W-1:0] obs_recovery_squash_tag,
  output logic [63:0] obs_recovery_redirect_pc,

  output logic obs_csr_valid,
  output logic [orbe_cosim_obs_pkg::COSIM_CSR_STATE_NUM-1:0]
      obs_csr_state_valid,
  output logic [orbe_cosim_obs_pkg::COSIM_CSR_STATE_NUM-1:0][11:0]
      obs_csr_state_addr,
  output logic [orbe_cosim_obs_pkg::COSIM_CSR_STATE_NUM-1:0][63:0]
      obs_csr_state,
  output logic obs_csr_event_valid,
  output logic [11:0] obs_csr_event_addr,
  output logic [63:0] obs_csr_event_wdata,
  output logic [63:0] obs_csr_event_rdata
);
  import mock_rtl_pkg::*;
  import orbe_cosim_obs_pkg::*;

  initial begin
    if (MOCK_ROB_ADDR_W < MOCK_ROB_TAG_W)
      $fatal(1, "[MOCK_OBS] observation ROB index width %0d is narrower than tag width %0d",
             MOCK_ROB_ADDR_W, MOCK_ROB_TAG_W);
  end

  always_comb begin
    logic [MOCK_ROB_ADDR_W-1:0] recovery_origin;
    logic [MOCK_ROB_ADDR_W-1:0] recovery_squash;

    obs_alloc_valid = rst_n ? mock_rob_alloc_valid : '0;
    obs_alloc_pld = rst_n ? mock_rob_alloc_pld : '{default:'0};
    obs_alloc_tag = rst_n ? mock_rob_alloc_rob_idx : '0;
    obs_alloc_ptr = rst_n ? mock_rob_alloc_rob_ptr : '0;

    obs_exec_valid = rst_n ? mock_exe_rob_wr_vld : '0;
    obs_exec_tag = rst_n ? mock_exe_rob_wr_idx : '0;

    obs_commit_valid = rst_n ? mock_rob_commit_valid : '0;
    obs_commit_tag = rst_n ? mock_rob_commit_rob_idx : '0;
    obs_commit_ptr = '0;
    obs_commit_pc = '0;
    obs_commit_count = '0;
    for (int group = 0; group < MOCK_ISSUE_NUM; group++) begin
      obs_commit_ptr[group] = mock_rob_commit_pld[group].rob_idx;
      obs_commit_pc[group] = mock_rob_commit_pld[group].pc;
      if (rst_n)
        obs_commit_count += mock_rob_commit_valid[group];
    end

    obs_global_flush = rst_n && ((|mock_flush_all) || mock_pflush);
    obs_redirect_valid = rst_n && mock_redirect_valid;
    obs_redirect_pc = mock_redirect_pc;
    obs_recovery_valid = obs_global_flush;
    obs_recovery_kind = (|mock_flush_all) ? ORBE_RECOVERY_EXCEPTION
                                          : ORBE_RECOVERY_MISPREDICT;
    obs_redirect_kind = obs_recovery_kind;

    recovery_origin = mock_pflush ? mock_pflush_rob_idx
                                  : mock_rob_commit_rob_idx[0];
    recovery_squash = recovery_origin;
    if (mock_pflush)
      recovery_squash[MOCK_ROB_TAG_W-1:0] =
          recovery_origin[MOCK_ROB_TAG_W-1:0] + 1'b1;
    obs_recovery_origin_tag = recovery_origin;
    obs_recovery_squash_tag = recovery_squash;
    obs_recovery_redirect_pc = mock_redirect_pc;
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
