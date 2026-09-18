// ORBE COSIM observation boundary.
//
// This interface intentionally carries only primitive observation fields.
// It must not depend on MOCK_RTL, BETA, P600, or any RTL-specific payload type.
interface ob_cosim_if #(
    parameter int unsigned ISSUE_NUM = 1,
    parameter int unsigned ROB_ADDR_W = 1,
    parameter int unsigned REG_ADDR_W = 5,
    parameter int unsigned FFLAGS_W = 5,
    parameter int unsigned EXCP_CAUSE_W = 63,
    parameter int unsigned RECOVERY_KIND_W = 3,
    // The address-keyed CSR snapshot capacity stays independent of the
    // eventual ISA-case CSR list. Unused entries are marked invalid.
    parameter int unsigned CSR_STATE_NUM = 16
) (input logic clk);
  import orbe_cosim_obs_pkg::*;
  // Level-2 BE-LSU observation payloads (be_lsu_issue_pld_t et al.) come from
  // the frozen OR-BE <-> LSU protocol package.
  import or_be_lsu_protocol_pkg::*;

  logic rst_n;

  // A valid group represents one architectural commit event. The BE sampler
  // consumes valid groups in increasing group order.
  logic [ISSUE_NUM-1:0] commit_valid;
  logic [ISSUE_NUM-1:0][63:0] commit_pc;
  logic [ISSUE_NUM-1:0][ROB_ADDR_W-1:0] commit_rob_idx;
  logic [ISSUE_NUM-1:0][63:0] commit_result;
  logic [ISSUE_NUM-1:0][REG_ADDR_W-1:0] commit_rd_idx;
  logic [ISSUE_NUM-1:0] commit_rd_is_fp;
  logic [ISSUE_NUM-1:0] commit_rd_write_enable;
  logic [ISSUE_NUM-1:0][FFLAGS_W-1:0] commit_fflags;

  logic commit_exception_valid;
  logic [EXCP_CAUSE_W-1:0] commit_exception_cause;
  logic [63:0] commit_exception_tval;
  logic commit_redirect_valid;
  logic [RECOVERY_KIND_W-1:0] commit_recovery_kind;
  logic [63:0] commit_redirect_pc;

  // Architectural register-file snapshots. These are continuous DUT
  // observations; they are not per-commit payloads and have no valid bit.
  logic [31:0][63:0] int_arf;
  logic [31:0][63:0] fp_arf;

  // CSR state is carried as an address-keyed table so the real DUT binding
  // can freeze the compared CSR set per ISA case without changing this
  // product-neutral interface. csr_valid qualifies the complete snapshot;
  // csr_state_valid qualifies individual entries in the table.
  logic                         csr_valid;
  logic [CSR_STATE_NUM-1:0]     csr_state_valid;
  logic [CSR_STATE_NUM-1:0][11:0] csr_state_addr;
  logic [CSR_STATE_NUM-1:0][63:0] csr_state;

  // Decode payload sampled at allocation and consumed at commit.
  logic [ISSUE_NUM-1:0] decode_issue_valid;
  cosim_decode_pld_t decode_issue_pld [ISSUE_NUM];

  // Optional CSR instruction observation for diagnostics. The checker must
  // not infer architectural state solely from this event payload.
  logic        csr_event_valid;
  logic [11:0] csr_event_addr;
  logic [63:0] csr_event_wdata;
  logic [63:0] csr_event_rdata;

  // Memory state changes are independent of the ROB commit pulse. In
  // particular, a tohost store can set the model exit state before its
  // normal commit observation is visible to the environment.
  logic        mem_store_commit_valid;
  logic [63:0] mem_store_commit_order;
  logic [63:0] mem_store_commit_vaddr;
  logic [63:0] mem_store_commit_data;
  logic [7:0]  mem_store_commit_mask;
  logic [63:0] mem_store_commit_pc;
  logic [63:0] mem_store_commit_rob_idx;
  logic        mem_store_commit_terminal;

  // Level-2 ISQ issue observation channels.
  logic isq_g0_issue_valid;
  cosim_isq_g0_issue_pld_t isq_g0_issue_pld;
  logic isq_g1_issue_valid;
  cosim_isq_g1_issue_pld_t isq_g1_issue_pld;
  logic isq_g2_issue_valid;
  cosim_isq_g2_issue_pld_t isq_g2_issue_pld;
  logic isq_g3_issue_valid;
  cosim_isq_g3_issue_pld_t isq_g3_issue_pld;

  // Level-2 CSR unit boundary observation channels.
  logic csr_in_valid;
  logic [ROB_ADDR_W-1:0] csr_in_tag;
  logic [11:0] csr_in_addr;
  logic [63:0] csr_in_rdata;
  logic [2:0] csr_in_current_priv;
  logic csr_in_fs_enabled;
  logic csr_out_valid;
  logic csr_out_write_enable;
  logic [11:0] csr_out_addr;
  logic [63:0] csr_out_wdata;
  logic [ROB_ADDR_W-1:0] csr_out_exec_tag;

  // Level-2 BE-LSU issue and response observation channels.
  logic lsu_be_issue_ready;
  logic be_lsu_issue_valid;
  be_lsu_issue_pld_t be_lsu_issue_pld;
  logic lsu_be_done_valid;
  logic lsu_be_exception_valid;
  logic lsu_be_bypass_valid;
  lsu_be_writeback_pld_t lsu_be_writeback_pld;
  lsu_be_bypass_pld_t lsu_be_bypass_pld;

  // Level-2 FU-after/writeback observation channels.
  logic [ISSUE_NUM-1:0] fu_after_valid;
  logic [ROB_ADDR_W-1:0] fu_after_tag [ISSUE_NUM];
  logic [ISSUE_NUM-1:0][63:0] fu_after_result;
  logic [ISSUE_NUM-1:0] fu_after_mispredict;
  logic [ISSUE_NUM-1:0] fu_after_exception;
  logic [ISSUE_NUM-1:0][63:0] fu_after_target;
  logic [ISSUE_NUM-1:0][63:0] fu_after_tval;
  logic [ISSUE_NUM-1:0][EXCP_CAUSE_W-1:0] fu_after_cause;
  logic [ISSUE_NUM-1:0] fu_after_is_mret;
  logic [ISSUE_NUM-1:0] fu_after_is_sret;
  logic [ISSUE_NUM-1:0][FFLAGS_W-1:0] fu_after_fflags;
endinterface
