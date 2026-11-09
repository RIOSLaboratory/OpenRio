// [This file] Slot contract item (2): product-neutral observable event stream
// ORBE COSIM observation boundary.
//
// This interface intentionally carries only primitive observation fields.
// It must not depend on BETA, P600, or any RTL-specific payload type.
interface ob_cosim_if #(
    parameter int unsigned ISSUE_NUM = 1,
    parameter int unsigned ROB_ADDR_W = 1,
    parameter int unsigned REG_ADDR_W = 5,
    parameter int unsigned FFLAGS_W = 5,
    parameter int unsigned EXCP_CAUSE_W = 63,
    parameter int unsigned RECOVERY_KIND_W = 3,
    // The address-keyed CSR snapshot capacity stays independent of the
    // eventual ISA-case CSR list. Unused entries are marked invalid.
    parameter int unsigned CSR_STATE_NUM = 16,
    // [2026-09-22] Number of completion lanes. A different dimension from ISSUE_NUM (number of commit groups):
    // on rtl_v1 there are 4 completion sources (G0 ALU/BRU, G1 ALU/MUL, G2 FPU, G3 LSU),
    // but only 2 commit channel groups. This parameter is used only by the fu_after_* group. ob_if has always kept them separate
    // (BE_ISSUE_NUM / BE_ROB_CMT_NUM); this interface is now aligned with it.
    //
    // **Placing it at the end of the parameter list, with the default taken from the single source of truth, are both deliberate.** The environment has six places
    // that pass parameters by position: `ob_cosim_if #(ISSUE_NUM, ROB_ADDR_W)` (be_agent.sv,
    // cache_agent.sv, cosim_agent.sv). Inserting this parameter in the middle would make
    // ROB_ADDR_W land in LANE_NUM, and Verilator immediately reports an interface type mismatch
    // (cannot convert ob_cosim_if__I2_L4_R6* to ob_cosim_if__I2_L6*).
    // With it at the end + default from orbe_be_dim_pkg (which describes itself as "the single source for ob_if / ob_cosim_if and
    // be_agent; change one place and the whole environment changes"), those positional call sites need no change,
    // and cannot pick up a value inconsistent with the top-level instance.
    parameter int unsigned LANE_NUM = orbe_be_dim_pkg::BE_ROB_CMT_NUM
) (input logic clk);
  import orbe_cosim_obs_pkg::*;
  // Level-2 BE-LSU observation payloads (be_lsu_issue_pld_t et al.) come from
  // the frozen OR-BE <-> LSU protocol package.
  import or_be_lsu_protocol_pkg::*;

  logic rst_n;

  // A valid group represents one architectural commit event. The BE sampler
  // consumes valid groups in increasing group order.
  logic [ISSUE_NUM-1:0] commit_valid;
  // [E-02] Number of commits this cycle. Previously only on ob_if, nowhere on the COSIM observation surface,
  // leaving the assertion
  // (commit_count == commit_valid[0] + commit_valid[1]) with nowhere to check.
  // Width is derived the same way as in ob_if.sv; both sides declare it over a "group count + 1" counting domain.
  logic [$clog2(ISSUE_NUM+1)-1:0] commit_count;
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

  // [E-02] Value surface of the Commit control / recovery interface.
  //
  // Previously there were only the "anchored to the commit event" recovery fields in the commit_* group above; the standalone flush /
  // recovery control surface lived only on ob_if (the identity surface), so a checker wanting values had to read another bus.
  // This group fills that in on the value surface, sourced from the same batch of obs_* samples as ob_if, not sampled separately.
  //
  // Inclusion criterion = whether stage 1 can model it. be_bfm has the corresponding concepts of flush / recovery / redirect,
  // so this group can be driven by both DUT kinds, in line with "ob_cosim_if has the same shape for both DUT kinds".
  // scoreboard_*/Buffer_tail/can_alloc_*/buffer_empty/head*_tag have
  // zero counterpart in be_bfm; if put into this interface, stage 1 could only drive constants, stage 1 verification of those fields would be void,
  // violating the requirement that both DUT kinds align. That group belongs to ob_if's structural surface and stays out of this interface.
  logic flush_valid;
  logic [ROB_ADDR_W-1:0] flush_tag;
  logic recovery_valid;
  logic [RECOVERY_KIND_W-1:0] recovery_kind;
  logic [ROB_ADDR_W-1:0] recovery_origin_tag;
  logic [ROB_ADDR_W-1:0] recovery_squash_tag;
  logic [63:0] recovery_redirect_pc;

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
  // [R7] Split types in step with or_be_lsu_if: the observation bus copies the shape of the observed boundary.
  lsu_be_done_pld_t      lsu_be_done_pld;
  lsu_be_exception_pld_t lsu_be_exception_pld;
  lsu_be_done_pld_t      lsu_be_bypass_pld;

  // Level-2 FU-after/writeback observation channels.
  //
  // [2026-09-22] This group is now declared by LANE_NUM instead of ISSUE_NUM. Previously all were declared by ISSUE_NUM(=2),
  // while semantically they are NUM_LANES(=4) completion lanes, with two consequences:
  //   1. The observation logic's `assign fu_after_valid = obs_exec_valid` assigned 4 bits to
  //      2 bits, silently truncating lanes 2/3; its generate also connected only the two lanes < ISSUE_WIDTH;
  //   2. be_agent.sv's observe_execution_writebacks() loops over BE_ROB_CMT_NUM=4,
  //      reading fu_after_result[2]/[3] out of bounds and getting X.
  // I.e. writeback observation for the two completion lanes G2 FPU and G3 LSU was previously unusable.
  logic [LANE_NUM-1:0] fu_after_valid;
  logic [ROB_ADDR_W-1:0] fu_after_tag [LANE_NUM];
  logic [LANE_NUM-1:0][63:0] fu_after_result;
  logic [LANE_NUM-1:0] fu_after_mispredict;
  logic [LANE_NUM-1:0] fu_after_exception;
  logic [LANE_NUM-1:0][63:0] fu_after_target;
  logic [LANE_NUM-1:0][63:0] fu_after_tval;
  logic [LANE_NUM-1:0][EXCP_CAUSE_W-1:0] fu_after_cause;
  logic [LANE_NUM-1:0] fu_after_is_mret;
  logic [LANE_NUM-1:0] fu_after_is_sret;
  logic [LANE_NUM-1:0][FFLAGS_W-1:0] fu_after_fflags;
endinterface
