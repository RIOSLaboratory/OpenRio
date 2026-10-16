// [This file] Raw observation bundle + dpi_be_phase_seq ordering component
interface ob_if (input logic clk);
  import orbe_be_dim_pkg::*;
  import orbe_cosim_obs_pkg::*;

  logic [BE_ISSUE_NUM-1:0] alloc_valid;
  rob_alloc_pld_t [BE_ISSUE_NUM-1:0] alloc_pld;
  logic [BE_ISSUE_NUM-1:0][BE_ROB_ADDR_W-1:0] alloc_tag;

  logic [BE_ROB_CMT_NUM-1:0] exec_valid;
  logic [BE_ROB_CMT_NUM-1:0][BE_ROB_ADDR_W-1:0] exec_tag;

  logic [BE_ISSUE_NUM-1:0] commit_valid;
  logic [BE_ISSUE_NUM-1:0][BE_ROB_ADDR_W-1:0] commit_tag;
  logic [BE_ISSUE_NUM-1:0][63:0] commit_pc;
  logic [$clog2(BE_ISSUE_NUM+1)-1:0] commit_count;

  logic global_flush;
  orbe_recovery_kind_e redirect_kind;
  logic recovery_valid;
  orbe_recovery_kind_e recovery_kind;
  logic [BE_ROB_ADDR_W-1:0] recovery_origin_tag;
  logic [BE_ROB_ADDR_W-1:0] recovery_squash_tag;
  logic [63:0] recovery_redirect_pc;

  logic [BE_ISSUE_NUM-1:0] rob_alloc_valid;
  rob_alloc_pld_t [BE_ISSUE_NUM-1:0] rob_alloc_pld;
  logic [BE_ISSUE_NUM-1:0][BE_ROB_ADDR_W-1:0] rob_alloc_rob_idx;
  logic [BE_ISSUE_NUM-1:0][BE_ROB_PTR_W-1:0] rob_alloc_rob_ptr;

  logic [BE_ISSUE_NUM-1:0] rob_commit_valid;
  rob_commit_pld_t [BE_ISSUE_NUM-1:0] rob_commit_pld;
  logic [BE_ISSUE_NUM-1:0][BE_ROB_ADDR_W-1:0] rob_commit_rob_idx;

  logic [BE_ROB_CMT_NUM-1:0] exe_rob_wr_vld;
  logic [BE_ROB_CMT_NUM-1:0][BE_ROB_ADDR_W-1:0] exe_rob_wr_idx;

  logic [BE_FLUSH_ALL_DUP-1:0] flush_all;
  logic pflush;
  logic [BE_ROB_ADDR_W-1:0] pflush_rob_idx;
  logic redirect_valid;
  logic [BE_VPC_W-1:0] redirect_pc;
  longint unsigned dpi_be_phase_seq;
endinterface
