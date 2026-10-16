// [This file] Environment dimension parameters and observation-surface payload types
// Environment dimension parameters, plus the two observation payload types on ob_if.
// These parameters are the single source for ob_if / ob_cosim_if and be_agent; change one place and the whole environment changes.
package orbe_be_dim_pkg;
  localparam int unsigned BE_ISSUE_NUM     = 2;
  localparam int unsigned BE_ROB_SLOT_W    = 4;
  localparam int unsigned BE_ROB_TAG_W     = 4;
  localparam int unsigned BE_ROB_ADDR_W    = 6;
  localparam int unsigned BE_ROB_PTR_W     = 7;
  localparam int unsigned BE_ROB_CMT_NUM   = 4;
  localparam int unsigned BE_FLUSH_ALL_DUP = 2;
  localparam int unsigned BE_VPC_W         = 64;

  typedef logic [4:0] exception_cause_t;

  typedef struct packed {
    logic [63:0] pc;
    logic [31:0] inst_bits;
    logic        is_compressed;
    logic        fetch_excp_vld;
    exception_cause_t exception_cause;
    logic [63:0] exception_tval;
    logic        is_lsu;
  } rob_alloc_pld_t;

  typedef struct packed {
    logic [63:0] pc;
    logic [BE_ROB_PTR_W-1:0] rob_idx;
  } rob_commit_pld_t;
endpackage
