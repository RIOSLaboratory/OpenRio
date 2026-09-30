`ifndef BACKEND_TOP_SV
`define BACKEND_TOP_SV

/* verilator lint_off IMPORTSTAR */
import or_be_lsu_protocol_pkg::*;
import or_be_types_pkg::*;
import fe_be_protocol_pkg::*;
/* verilator lint_on IMPORTSTAR */

// backend_top -- OR-BE top-level wiring.
//
// **Pure wiring**: 33 instances connected, no new module logic.
// The only combinational content allowed in this file is seven pieces of glue logic, each marked below:
//
//   glue#1  field extraction of head_IB_Payload[s]
//           IB outputs a whole ib_payload_t, while dependency_check / dispatch_logic /
//           INT_ARF / INT_tag_mapping / FP_tag_mapping / FP_read_address_mux /
//           CompletionScoreboard / PC_File take loose fields.
//           Also produces the gated opnd (ib_opnd_g, feeds isq_payload_assembly).
//   glue#2  aggregation of the four completion lanes
//           lane0 = p3_arbiter_G0, lane1 = p3_arbiter_G1, lane2 = fpu_simple
//           direct, lane3 = g3_lsu_iface. **Each group of arrays is aggregated once**, then fanned out to
//           Buffer / CompletionScoreboard / dependency_check / the four ISQ_Groups /
//           isq_payload_assembly -- aggregating twice separately could misalign the b of bypass_data[b] and
//           bypass_valid[b]/bypass_tag[b], and no tool can catch that misalignment.
//   glue#3  each FU's completion request aggregated by **in-group requester number** to the arbiter
//           (G0_FU_ALU/CSR/DIV, G1_FU_ALU/MUL, taken from the types package, no literals).
//   glue#4  per-group aggregation of isq_free_for_dispatch[NUM_LANES] and FU_ready[G*_NUM_FU].
//   glue#5  field extraction of fe_instr_pld[s]
//           Same nature as glue#1, opposite direction: the boundary carries one frozen fe_be_instr_pld_t,
//           the enqueue side takes loose fields. **Extraction happens only here**, and it is struct ->
//           loose fields, so missing a field here is a compile error rather than silently dropped data.
//   glue#6  enqueue payload assembly (FE pass-through fields, including FE's expanded word, rvc_ill, opnd)
//   glue#7  the five head -> decode inputs (inst_expanded / inst_bits[15:0] /
//           is_compressed / rvc_ill / fetch_excp_vld)
//
// Top-level ports are **discrete signals**, not interfaces: this module must be synthesizable; the fe_if / lsu_if
// interface adaptation is done by the TB-side adapter.
//
// The observation surface (alloc_* / exec_* / commit_* / trace_pc / global_flush_valid)
// **adds no logic**: each is either directly the net connected to some instance's output port, or
// the very group of arrays aggregated by glue#2. Top-level output ports are readable inside the module, so these nets
// are also the source for internal consumers -- no separate alias for observation, the same discipline as "global_flush_late
// allows only one net".
module backend_top (
    input  logic                        clk,
    input  logic                        rst_n,

    // ==================================================================
    // FE side (discretized fe_if): `FE -> decode`,
    // `IB -> FE fe_ready` / `flush_model -> FE redirect_*` /
    // `G0's BRU -> FE predictor_update`.
    // fe_valid / fe_ready / accepted_slot are packed 2-bit vectors.
    //
    // **The handshake is plain per-lane valid/ready.** At the same posedge FE uses
    // `fe_valid & fe_ready` to know how many went in this cycle; no second accept is needed:
    // `accepted_slot` in IB is exactly this AND, not another checker (IB (3)).
    //
    // **The instruction payload goes through one frozen struct, not flat ports.**
    // With flat ports every field would have to be copied by hand in an adapter layer outside the library, and a missed copy raises no error
    // (e.g. the three fetch-exception fields).
    // Schema in fe_be_protocol_pkg.sv; same discipline as the LSU side's be_lsu_issue_pld_t.
    // ==================================================================
    input  logic [ISSUE_WIDTH-1:0]      fe_valid,
    input  fe_be_instr_pld_t            fe_instr_pld                   [ISSUE_WIDTH],

    output logic [ISSUE_WIDTH-1:0]      fe_ready,
    // For the observation surface: which ones were actually enqueued this cycle. Equal to fe_valid & fe_ready,
    // carries no extra information, FE does not need to read it.
    output logic [ISSUE_WIDTH-1:0]      accepted_slot,

    output logic                        redirect_valid,
    output logic [XLEN-1:0]             redirect_pc,
    output logic [RECOVERY_KIND_W-1:0]  redirect_kind,
    // Mock FE has no counterpart -- left dangling in the TB after export, not a defect.
    output logic                        frontend_icache_invalidate,

    // Same as above: the five predictor_update wires; mock FE has no predictor channel.
    output logic                        predictor_update_valid,
    output logic [XLEN-1:0]             predictor_update_branch_pc,
    output logic                        predictor_update_actual_taken,
    output logic [XLEN-1:0]             predictor_update_actual_target,
    output cf_class_e                   predictor_update_cf_class,

    // ==================================================================
    // LSU side (discretized lsu_if). All of it is g3_lsu_iface's external half,
    // plus global_flush_late driving the same-named lsu_if wire.
    // ==================================================================
    output logic                        be_lsu_issue_valid,
    output be_lsu_issue_pld_t           be_lsu_issue_pld,
    output logic                        be_lsu_entry_ready,
    output logic                        be_lsu_store_wakeup_valid,
    output logic                        global_flush_late,

    input  logic                        lsu_be_issue_ready,
    input  logic                        lsu_be_done_valid,
    input  lsu_be_done_pld_t            lsu_be_done_pld,
    input  logic                        lsu_be_exception_valid,
    input  lsu_be_exception_pld_t       lsu_be_exception_pld,
    input  logic                        lsu_be_bypass_valid,
    input  lsu_be_done_pld_t            lsu_be_bypass_pld,

    // ==================================================================
    // Interrupts. "top -> system_instruction_handler  mip external interrupt bits";
    // their semantics are level (no fire, not latched).
    // ==================================================================
    input  logic                        mip_meip,
    input  logic                        mip_mtip,
    input  logic                        mip_msip,

    // ==================================================================
    // Observation surface (ob_if / cosim). All taken directly from module outputs or glue#2's aggregated arrays.
    // ==================================================================
    output logic                        alloc_valid                    [ISSUE_WIDTH],
    output logic [TAG_W-1:0]            alloc_tag                      [ISSUE_WIDTH],
    output logic                        exec_valid                     [NUM_LANES],
    output logic [TAG_W-1:0]            exec_tag                       [NUM_LANES],
    output logic                        commit_valid                   [ISSUE_WIDTH],
    output logic [TAG_W-1:0]            commit_tag                     [ISSUE_WIDTH],
    output logic [REG_ADDR_W-1:0]       commit_rd_idx                  [ISSUE_WIDTH],
    output logic                        commit_rd_is_fp                [ISSUE_WIDTH],
    output logic                        commit_rd_write_enable         [ISSUE_WIDTH],
    output logic [FFLAGS_W-1:0]         commit_fflags                  [ISSUE_WIDTH],
    output logic [COMMIT_COUNT_W-1:0]   commit_count,
    output logic [XLEN-1:0]             commit_data                    [ISSUE_WIDTH],
    output logic [XLEN-1:0]             trace_pc                       [ISSUE_WIDTH],
    output logic                        global_flush_valid
);

    // ------------------------------------------------------------------
    // lane / group indices. The drivers of the four lanes are lane0 = p3_arbiter_G0,
    // lane1 = p3_arbiter_G1, lane2 = FPU direct, lane3 = g3_lsu_iface;
    // the g of ISQ_Group_g equals the lane number (dispatch_logic's GRP_G0..G3 are also 0..3),
    // so the same constants serve both as lane numbers and group numbers. Readability names only, no second value.
    // In-group requester numbers are not redefined here -- use the types package's G0_FU_* / G1_FU_*.
    // ------------------------------------------------------------------
    localparam int LANE_G0 = 0;
    localparam int LANE_G1 = 1;
    localparam int LANE_G2 = 2;
    localparam int LANE_G3 = 3;

    // ==================================================================
    // Internal nets. Naming is always <producer prefix>_<producer port name>; different names at the two ends are normal;
    // each end follows its own naming, and this layer does the wiring.
    // ==================================================================

    // ---- product of glue#6: enqueue payload (**pure wiring**) -------------------
    ib_payload_t                    enq_IB_Payload            [ISSUE_WIDTH];

    // ---- RVC expansion is in FE, there is no rvc_expand instance in BE ----

    // ---- IB -----------------------------------------------------------
    ib_payload_t                    head_IB_Payload           [ISSUE_WIDTH];
    logic [ISSUE_WIDTH-1:0]         ib_inst_valid;

    // ---- decode (**after** IB) --------------------------------------
    decoded_info_t                  dec_info                  [ISSUE_WIDTH];
    // product of glue#1: the IB head opnd after illegal gating (feeds dependency_check / tag_mapping /
    // isq_payload_assembly); use_* / *_is_fp cleared on illegal / fetch exception.
    ib_operand_info_t               ib_opnd_g                 [ISSUE_WIDTH];

    // ---- product of glue#1: head fields (RAW + opnd) + loose fields of the dequeue-side decode products --------
    logic [REG_ADDR_W-1:0]          ib_rd_idx                 [ISSUE_WIDTH];
    logic                           ib_rd_is_fp               [ISSUE_WIDTH];
    logic                           ib_use_rd                 [ISSUE_WIDTH];
    logic                           ib_is_serial              [ISSUE_WIDTH];
    // **Gated version**: feeds dispatch_logic's fp_illegal (architectural decision, must be gated).
    logic                           ib_is_fp_instruction      [ISSUE_WIDTH];
    // **Ungated version**: feeds dependency_check's fp0/fp1 (dual-FP stall) and
    // FP_read_address_mux's select bit. Both must share one source; reason in the mux.
    // Source is the IB head opnd.is_fp_opcode (provided by FE), not through decode.
    logic                           ib_is_fp_opcode           [ISSUE_WIDTH];
    logic                           ib_use_rs1                [ISSUE_WIDTH];
    logic                           ib_use_rs2                [ISSUE_WIDTH];
    logic                           ib_use_rs3                [ISSUE_WIDTH];
    logic [REG_ADDR_W-1:0]          ib_rs1_idx                [ISSUE_WIDTH];
    logic [REG_ADDR_W-1:0]          ib_rs2_idx                [ISSUE_WIDTH];
    logic [REG_ADDR_W-1:0]          ib_rs3_idx                [ISSUE_WIDTH];
    logic                           ib_rs1_is_fp              [ISSUE_WIDTH];
    logic                           ib_rs2_is_fp              [ISSUE_WIDTH];
    logic                           ib_rs3_is_fp              [ISSUE_WIDTH];
    logic                           ib_is_store               [ISSUE_WIDTH];
    logic [XLEN-1:0]                ib_pc                     [ISSUE_WIDTH];
    logic [EXE_SUBOP_W-1:0]         ib_exe_subop              [ISSUE_WIDTH];
    full_decode_t                   ib_full_decode            [ISSUE_WIDTH];
    // The 4 INT-side read addresses, shaped [ISSUE_WIDTH][1:2] (frozen),
    // matching INT_ARF / INT_tag_mapping read-outs cell by cell in the same shape and order.
    logic [REG_ADDR_W-1:0]          ib_int_rs_idx             [ISSUE_WIDTH][1:INT_SRC_PER_SLOT];

    // ---- dependency_check ---------------------------------------------
    // self_tag is the observation surface's alloc_tag, see module header comment.
    logic                           dc_rd_write_enable        [ISSUE_WIDTH];
    logic                           dc_slot0_present;
    logic                           dc_slot1_present;
    logic                           dc_serial0;
    logic                           dc_serial_inst;
    logic                           dc_fp0;
    logic                           dc_fp1;
    logic                           dc_slot_missed_wakeup     [ISSUE_WIDTH];
    logic                           dc_rsX_ready              [ISSUE_WIDTH][1:FP_READ_PORTS];
    logic [TAG_W-1:0]               dc_rsX_wait_tag           [ISSUE_WIDTH][1:FP_READ_PORTS];
    logic [RS_DATA_SEL_W-1:0]       dc_rs_data_sel_t          [ISSUE_WIDTH][1:FP_READ_PORTS];

    // ---- dispatch_logic -------------------------------------------------
    // accept is the observation surface's alloc_valid.
    logic                           dl_ib_dequeue             [ISSUE_WIDTH];
    logic                           dl_isq_wr_en              [NUM_LANES];
    logic [FU_GROUP_W-1:0]          dl_slot_FU_Group          [ISSUE_WIDTH];
    rm_e                            dl_effective_rm           [ISSUE_WIDTH];
    logic                           dl_is_fence_i             [ISSUE_WIDTH];
    logic                           dl_may_flush              [ISSUE_WIDTH];
    logic                           dl_is_atomic              [ISSUE_WIDTH];
    logic                           dl_serial_set;
    logic [TAG_W-1:0]               dl_serial_set_tag;
    logic                           dl_select_payload         [NUM_LANES][ISSUE_WIDTH];

    // ---- register files / tag mapping / read address mux ---------------------------
    logic [XLEN-1:0]                intarf_ARF                [ISSUE_WIDTH][1:INT_SRC_PER_SLOT];
    logic [XLEN-1:0]                fparf_ARF                 [1:FP_READ_PORTS];
    logic [TAG_W-1:0]               intmap_tag                [ISSUE_WIDTH][1:INT_SRC_PER_SLOT];
    logic                           intmap_busy               [ISSUE_WIDTH][1:INT_SRC_PER_SLOT];
    logic [TAG_W-1:0]               fpmap_tag                 [1:FP_READ_PORTS];
    logic                           fpmap_busy                [1:FP_READ_PORTS];
    logic [REG_ADDR_W-1:0]          fpmux_fp_read_idx         [1:FP_READ_PORTS];

    // ---- payload assembly and the 4 p1_ISQ_input_mux ------------------------
    isq_payload_t                   asm_slot_payload          [ISSUE_WIDTH];
    isq_payload_t                   mux_ISQ_payload_in        [NUM_LANES];

    // ---- ISQ_Group0..3 ------------------------------------------------
    logic                           isq0_issue_valid;
    logic [XLEN-1:0]                isq0_rs1_data;
    logic [XLEN-1:0]                isq0_rs2_data;
    logic [FU_GROUP_W-1:0]          isq0_FU_Group;
    logic                           isq0_imm_valid;
    logic [XLEN-1:0]                isq0_imm_data;
    logic [XLEN-1:0]                isq0_pc;
    logic [31:0]                    isq0_inst_bits;
    logic                           isq0_is_compressed;
    logic                           isq0_pred_taken;
    logic [XLEN-1:0]                isq0_pred_target_pc;
    logic [TAG_W-1:0]               isq0_self_tag;
    logic [EXE_SUBOP_W-1:0]         isq0_exe_subop;
    logic [FULL_DECODE_W-1:0]       isq0_full_decode;
    logic                           isq0_fetch_excp_vld;
    logic [FETCH_EXCP_CAUSE_W-1:0]  isq0_fetch_excp_cause;
    logic [XLEN-1:0]                isq0_fetch_excp_tval;
    logic                           isq0_isq_free_for_dispatch;

    logic                           isq1_issue_valid;
    logic [XLEN-1:0]                isq1_rs1_data;
    logic [XLEN-1:0]                isq1_rs2_data;
    logic [FU_GROUP_W-1:0]          isq1_FU_Group;
    logic                           isq1_imm_valid;
    logic [XLEN-1:0]                isq1_imm_data;
    logic [TAG_W-1:0]               isq1_self_tag;
    logic [EXE_SUBOP_W-1:0]         isq1_exe_subop;
    logic                           isq1_isq_free_for_dispatch;

    logic                           isq2_issue_valid;
    logic [XLEN-1:0]                isq2_rs1_data;
    logic [XLEN-1:0]                isq2_rs2_data;
    logic [XLEN-1:0]                isq2_rs3_data;
    logic [TAG_W-1:0]               isq2_self_tag;
    logic [EXE_SUBOP_W-1:0]         isq2_exe_subop;
    logic [FULL_DECODE_W-1:0]       isq2_full_decode;
    logic                           isq2_isq_free_for_dispatch;

    logic                           isq3_issue_valid;
    logic [XLEN-1:0]                isq3_rs1_data;
    logic [XLEN-1:0]                isq3_rs2_data;
    logic                           isq3_imm_valid;
    logic [XLEN-1:0]                isq3_imm_data;
    logic                           isq3_is_store;
    logic [MEM_FUNCT3_W-1:0]        isq3_mem_funct3;
    logic                           isq3_rd_is_fp;
    logic [TAG_W-1:0]               isq3_self_tag;
    logic [EXE_SUBOP_W-1:0]         isq3_exe_subop;
    logic                           isq3_isq_free_for_dispatch;
    logic                           isq3_occupied;

    // ---- G0's three FUs -------------------------------------------------
    logic                           alu0_FU_ready;
    logic                           alu0_request_valid;
    logic [TAG_W-1:0]               alu0_req_tag;
    logic [XLEN-1:0]                alu0_req_result_data;
    logic                           alu0_req_mispredict_flag;
    logic [XLEN-1:0]                alu0_req_mispredict_target_pc;
    logic                           alu0_req_exception_flag;
    logic [EXCP_CAUSE_W-1:0]        alu0_req_exception_cause;
    logic [XLEN-1:0]                alu0_req_exception_tval;
    logic                           alu0_req_is_mret;
    logic                           alu0_req_is_sret;
    logic [FFLAGS_W-1:0]            alu0_req_fpu_fflags;
    logic                           alu0_req_is_csr;
    logic                           alu0_req_csr_write_enable;
    logic [CSR_ADDR_W-1:0]          alu0_req_csr_addr;
    logic [XLEN-1:0]                alu0_req_csr_wdata;

    logic [CSR_ADDR_W-1:0]          csrfu_csr_addr;
    logic                           csrfu_FU_ready;
    logic                           csrfu_request_valid;
    logic [TAG_W-1:0]               csrfu_req_tag;
    logic [XLEN-1:0]                csrfu_req_result_data;
    logic                           csrfu_req_mispredict_flag;
    logic [XLEN-1:0]                csrfu_req_mispredict_target_pc;
    logic                           csrfu_req_exception_flag;
    logic [EXCP_CAUSE_W-1:0]        csrfu_req_exception_cause;
    logic [XLEN-1:0]                csrfu_req_exception_tval;
    logic                           csrfu_req_is_mret;
    logic                           csrfu_req_is_sret;
    logic [FFLAGS_W-1:0]            csrfu_req_fpu_fflags;
    logic                           csrfu_req_is_csr;
    logic                           csrfu_req_csr_write_enable;
    logic [CSR_ADDR_W-1:0]          csrfu_req_csr_addr;
    logic [XLEN-1:0]                csrfu_req_csr_wdata;

    logic                           div_FU_ready;
    logic                           div_request_valid;
    logic [TAG_W-1:0]               div_req_tag;
    logic [XLEN-1:0]                div_req_result_data;
    logic                           div_req_mispredict_flag;
    logic [XLEN-1:0]                div_req_mispredict_target_pc;
    logic                           div_req_exception_flag;
    logic [EXCP_CAUSE_W-1:0]        div_req_exception_cause;
    logic [XLEN-1:0]                div_req_exception_tval;
    logic                           div_req_is_mret;
    logic                           div_req_is_sret;
    logic [FFLAGS_W-1:0]            div_req_fpu_fflags;
    logic                           div_req_is_csr;
    logic                           div_req_csr_write_enable;
    logic [CSR_ADDR_W-1:0]          div_req_csr_addr;
    logic [XLEN-1:0]                div_req_csr_wdata;

    // ---- G1's two FUs -------------------------------------------------
    logic                           alu1_FU_ready;
    logic                           alu1_request_valid;
    logic [TAG_W-1:0]               alu1_req_tag;
    logic [XLEN-1:0]                alu1_req_result_data;
    logic                           alu1_req_mispredict_flag;
    logic [XLEN-1:0]                alu1_req_mispredict_target_pc;
    logic                           alu1_req_exception_flag;
    logic [EXCP_CAUSE_W-1:0]        alu1_req_exception_cause;
    logic [XLEN-1:0]                alu1_req_exception_tval;
    logic                           alu1_req_is_mret;
    logic                           alu1_req_is_sret;
    logic [FFLAGS_W-1:0]            alu1_req_fpu_fflags;
    // No counterpart (normal): p3_arbiter_G1 has no csr_sideband layer; these four outputs of G1's alu_simple
    // are always zero in the G1 position and consumed by no one. Still connected by name; port lines are not omitted.
    logic                           alu1_req_is_csr;
    logic                           alu1_req_csr_write_enable;
    logic [CSR_ADDR_W-1:0]          alu1_req_csr_addr;
    logic [XLEN-1:0]                alu1_req_csr_wdata;
    // Same as above: only G0's BRU has a counterpart for predictor_update;
    // these five wires of the G1 instance are naturally always zero by routing and consumed by no one.
    logic                           alu1_predictor_update_valid;
    logic [XLEN-1:0]                alu1_predictor_update_branch_pc;
    logic                           alu1_predictor_update_actual_taken;
    logic [XLEN-1:0]                alu1_predictor_update_actual_target;
    cf_class_e                      alu1_predictor_update_cf_class;

    logic                           mul_FU_ready;
    logic                           mul_request_valid;
    logic [TAG_W-1:0]               mul_req_tag;
    logic [XLEN-1:0]                mul_req_result_data;
    logic                           mul_req_mispredict_flag;
    logic [XLEN-1:0]                mul_req_mispredict_target_pc;
    logic                           mul_req_exception_flag;
    logic [EXCP_CAUSE_W-1:0]        mul_req_exception_cause;
    logic [XLEN-1:0]                mul_req_exception_tval;
    logic                           mul_req_is_mret;
    logic                           mul_req_is_sret;
    logic [FFLAGS_W-1:0]            mul_req_fpu_fflags;

    // ---- G2's FPU (no arbiter, completion directly on lane 2) ------------------
    logic                           g2fu_FU_ready;
    logic                           g2fu_Result_valid;
    logic [TAG_W-1:0]               g2fu_tag_out;
    logic [XLEN-1:0]                g2fu_result_data;
    logic                           g2fu_mispredict_flag;
    logic [XLEN-1:0]                g2fu_mispredict_target_pc;
    logic                           g2fu_exception_flag;
    logic [EXCP_CAUSE_W-1:0]        g2fu_exception_cause;
    logic                           g2fu_bypass_valid;
    logic [TAG_W-1:0]               g2fu_bypass_tag;
    logic [XLEN-1:0]                g2fu_bypass_data;
    logic [XLEN-1:0]                g2fu_exception_tval;
    logic                           g2fu_is_mret;
    logic                           g2fu_is_sret;
    logic [FFLAGS_W-1:0]            g2fu_fpu_fflags;

    // ---- the two in-group arbiters -------------------------------------------------
    logic                           arbG0_Result_valid;
    logic [TAG_W-1:0]               arbG0_tag_out;
    logic [XLEN-1:0]                arbG0_result_data;
    logic                           arbG0_mispredict_flag;
    logic [XLEN-1:0]                arbG0_mispredict_target_pc;
    logic                           arbG0_exception_flag;
    logic [EXCP_CAUSE_W-1:0]        arbG0_exception_cause;
    logic [XLEN-1:0]                arbG0_exception_tval;
    logic                           arbG0_is_mret;
    logic                           arbG0_is_sret;
    logic [FFLAGS_W-1:0]            arbG0_fpu_fflags;
    logic                           arbG0_is_csr;
    logic                           arbG0_csr_write_enable;
    logic [CSR_ADDR_W-1:0]          arbG0_csr_addr;
    logic [XLEN-1:0]                arbG0_csr_wdata;
    logic                           arbG0_bypass_valid;
    logic [TAG_W-1:0]               arbG0_bypass_tag;
    logic [XLEN-1:0]                arbG0_bypass_data;
    logic                           arbG0_winner_grant        [G0_NUM_FU];
    logic                           arbG0_loser_hold          [G0_NUM_FU];

    logic                           arbG1_Result_valid;
    logic [TAG_W-1:0]               arbG1_tag_out;
    logic [XLEN-1:0]                arbG1_result_data;
    logic                           arbG1_exception_flag;
    logic [EXCP_CAUSE_W-1:0]        arbG1_exception_cause;
    logic [XLEN-1:0]                arbG1_exception_tval;
    logic                           arbG1_mispredict_flag;
    logic [XLEN-1:0]                arbG1_mispredict_target_pc;
    logic                           arbG1_is_mret;
    logic                           arbG1_is_sret;
    logic [FFLAGS_W-1:0]            arbG1_fpu_fflags;
    logic                           arbG1_bypass_valid;
    logic [TAG_W-1:0]               arbG1_bypass_tag;
    logic [XLEN-1:0]                arbG1_bypass_data;
    logic                           arbG1_winner_grant        [G1_NUM_FU];
    logic                           arbG1_loser_hold          [G1_NUM_FU];

    // ---- g3_lsu_iface (driver of lane 3) --------------------------------
    logic                           lsuif_FU_ready;
    logic                           lsuif_Result_valid;
    logic [TAG_W-1:0]               lsuif_tag_out;
    logic [XLEN-1:0]                lsuif_result_data;
    logic                           lsuif_mispredict_flag;
    logic [XLEN-1:0]                lsuif_mispredict_target_pc;
    logic                           lsuif_exception_flag;
    logic [EXCP_CAUSE_W-1:0]        lsuif_exception_cause;
    logic [XLEN-1:0]                lsuif_exception_tval;
    logic                           lsuif_is_mret;
    logic                           lsuif_is_sret;
    logic [FFLAGS_W-1:0]            lsuif_fpu_fflags;
    logic                           lsuif_bypass_valid;
    logic [TAG_W-1:0]               lsuif_bypass_tag;
    logic [XLEN-1:0]                lsuif_bypass_data;

    // ---- P4 -----------------------------------------------------------
    logic [XLEN-1:0]                pcf_inst_pc;
    logic                           sit_serial_inflight_valid;

    trap_state_write_t              fm_trap_state_write;
    logic [EXCP_CAUSE_W-1:0]        fm_cause;
    logic                           fm_is_interrupt;

    logic [XLEN-1:0]                sih_csr_rdata;
    logic [PRIV_W-1:0]              sih_current_priv;
    rm_e                            sih_frm;
    logic                           sih_fs_enabled;
    logic [XLEN-1:0]                sih_trap_vector;
    logic                           sih_interrupt_pending;
    logic [EXCP_CAUSE_W-1:0]        sih_interrupt_cause;
    logic [XLEN-1:0]                sih_mepc;
    logic [XLEN-1:0]                sih_sepc;
    logic                           sih_mstatus_tvm;
    logic                           sih_mstatus_tw;
    logic                           sih_mstatus_tsr;

    logic                           scb_store_wakeup_valid;
    logic [TAG_W-1:0]               scb_store_wakeup_tag;
    logic                           scb_flush_valid;
    logic [TAG_W-1:0]               scb_flush_tag;
    logic [RECOVERY_KIND_W-1:0]     scb_recovery_kind;
    logic [TAG_W-1:0]               scb_head0_tag;
    logic [TAG_W-1:0]               scb_head1_tag;
    logic [XLEN-1:0]                scb_recovery_mispredict_target_pc;
    logic [EXCP_CAUSE_W-1:0]        scb_recovery_exception_cause;
    logic [XLEN-1:0]                scb_recovery_exception_tval;
    logic                           scb_st_br_resolve;
    logic [ROB_DEPTH-1:0]           scb_scoreboard_valid_bits;
    logic [ROB_DEPTH-1:0]           scb_scoreboard_exec_done_bits;
    logic [TAG_W-1:0]               scb_Buffer_tail;
    logic                           scb_can_alloc_1;
    logic                           scb_can_alloc_2;
    logic                           scb_buffer_empty;

    // ---- product of glue#2: aggregated arrays of the four lanes ---------------------------
    // exec_valid / exec_tag are the Result_valid[NUM_LANES] / tag_out[NUM_LANES] here
    // (see module header comment: no separate alias for the observation surface).
    logic [XLEN-1:0]                lane_result_data          [NUM_LANES];
    logic                           lane_mispredict_flag      [NUM_LANES];
    logic [XLEN-1:0]                lane_mispredict_target_pc [NUM_LANES];
    logic                           lane_exception_flag       [NUM_LANES];
    logic [EXCP_CAUSE_W-1:0]        lane_exception_cause      [NUM_LANES];
    logic [XLEN-1:0]                lane_exception_tval       [NUM_LANES];
    logic                           lane_is_mret              [NUM_LANES];
    logic                           lane_is_sret              [NUM_LANES];
    logic [FFLAGS_W-1:0]            lane_fpu_fflags           [NUM_LANES];
    logic                           lane_bypass_valid         [NUM_LANES];
    logic [TAG_W-1:0]               lane_bypass_tag           [NUM_LANES];
    logic [XLEN-1:0]                lane_bypass_data          [NUM_LANES];

    // ---- product of glue#3: requests aggregated by in-group requester number ------------
    logic                           g0_request_valid          [G0_NUM_FU];
    logic [TAG_W-1:0]               g0_req_tag                [G0_NUM_FU];
    logic [XLEN-1:0]                g0_req_result_data        [G0_NUM_FU];
    logic                           g0_req_mispredict_flag    [G0_NUM_FU];
    logic [XLEN-1:0]                g0_req_mispredict_target_pc [G0_NUM_FU];
    logic                           g0_req_exception_flag     [G0_NUM_FU];
    logic [EXCP_CAUSE_W-1:0]        g0_req_exception_cause    [G0_NUM_FU];
    logic [XLEN-1:0]                g0_req_exception_tval     [G0_NUM_FU];
    logic                           g0_req_is_mret            [G0_NUM_FU];
    logic                           g0_req_is_sret            [G0_NUM_FU];
    logic [FFLAGS_W-1:0]            g0_req_fpu_fflags         [G0_NUM_FU];
    logic                           g0_req_is_csr             [G0_NUM_FU];
    logic                           g0_req_csr_write_enable   [G0_NUM_FU];
    logic [CSR_ADDR_W-1:0]          g0_req_csr_addr           [G0_NUM_FU];
    logic [XLEN-1:0]                g0_req_csr_wdata          [G0_NUM_FU];

    logic                           g1_request_valid          [G1_NUM_FU];
    logic [TAG_W-1:0]               g1_req_tag                [G1_NUM_FU];
    logic [XLEN-1:0]                g1_req_result_data        [G1_NUM_FU];
    logic                           g1_req_mispredict_flag    [G1_NUM_FU];
    logic [XLEN-1:0]                g1_req_mispredict_target_pc [G1_NUM_FU];
    logic                           g1_req_exception_flag     [G1_NUM_FU];
    logic [EXCP_CAUSE_W-1:0]        g1_req_exception_cause    [G1_NUM_FU];
    logic [XLEN-1:0]                g1_req_exception_tval     [G1_NUM_FU];
    logic                           g1_req_is_mret            [G1_NUM_FU];
    logic                           g1_req_is_sret            [G1_NUM_FU];
    logic [FFLAGS_W-1:0]            g1_req_fpu_fflags         [G1_NUM_FU];

    // ---- product of glue#4: per-group aggregated ready / free ------------------------
    logic                           g0_FU_ready               [G0_NUM_FU];
    logic                           g1_FU_ready               [G1_NUM_FU];
    logic                           isq_free_for_dispatch     [NUM_LANES];

    // ==================================================================
    // glue#1 · head field extraction
    //
    // The eight edges "IB -> dependency_check / dispatch_logic / FP_read_address_mux /
    // INT_ARF / INT_tag_mapping / FP_tag_mapping / CompletionScoreboard /
    // PC_File" take loose fields.
    //
    // RVC expansion and Operand_Extract are in FE:
    //
    //   **Register index = field of the IB head opnd, wired directly to ARF / tag_mapping, no combinational logic at all.**
    //   Indices are not gated by illegal -- safety is guaranteed on the consumer side (triple qualification by use_rs* / use_rd /
    //   rd_write_enable), see the comment on `decoded_info_t` in or_be_types_pkg.
    //
    //   **is_fp_opcode = head opnd.is_fp_opcode, not gated.** Wired directly to dependency_check
    //   (two slots -> fp0/fp1 -> dispatch_logic's dual-FP stall) and FP_read_address_mux
    //   (slot0). Both share one source.
    //
    //   **use_* / *_is_fp are gated by decode's full_decode.illegal**: on illegal or fetch
    //   exception all are cleared (i.e. decode's d_no_encoding condition),
    //   so an illegal instruction neither waits for operands nor allocates a tag for rd.
    //
    //   Other decoded products come from `dec_info[s]`, same-cycle and same-source as the head.
    // ==================================================================
    always_comb begin
        for (int unsigned s = 0; s < ISSUE_WIDTH; s++) begin
            ib_opnd_g[s] = head_IB_Payload[s].opnd;
            if (dec_info[s].full_decode.illegal) begin
                ib_opnd_g[s].use_rs1   = 1'b0;
                ib_opnd_g[s].use_rs2   = 1'b0;
                ib_opnd_g[s].use_rs3   = 1'b0;
                ib_opnd_g[s].use_rd    = 1'b0;
                ib_opnd_g[s].rs1_is_fp = 1'b0;
                ib_opnd_g[s].rs2_is_fp = 1'b0;
                ib_opnd_g[s].rs3_is_fp = 1'b0;
                ib_opnd_g[s].rd_is_fp  = 1'b0;
            end

            // -- head RAW --
            ib_pc               [s] = head_IB_Payload[s].pc;
            // -- address branch: IB head opnd wired directly --
            ib_rs1_idx          [s] = head_IB_Payload[s].opnd.rs1;
            ib_rs2_idx          [s] = head_IB_Payload[s].opnd.rs2;
            ib_rs3_idx          [s] = head_IB_Payload[s].opnd.rs3;
            ib_rd_idx           [s] = head_IB_Payload[s].opnd.rd;
            // The source number is the index, base 1, no rs0.
            ib_int_rs_idx       [s][1] = head_IB_Payload[s].opnd.rs1;
            ib_int_rs_idx       [s][2] = head_IB_Payload[s].opnd.rs2;
            // -- FP checker: not gated, IB head wired directly --
            ib_is_fp_opcode     [s] = head_IB_Payload[s].opnd.is_fp_opcode;

            // -- source / destination qualifier bits: gated opnd --
            ib_rd_is_fp         [s] = ib_opnd_g[s].rd_is_fp;
            ib_use_rd           [s] = ib_opnd_g[s].use_rd;
            ib_use_rs1          [s] = ib_opnd_g[s].use_rs1;
            ib_use_rs2          [s] = ib_opnd_g[s].use_rs2;
            ib_use_rs3          [s] = ib_opnd_g[s].use_rs3;
            ib_rs1_is_fp        [s] = ib_opnd_g[s].rs1_is_fp;
            ib_rs2_is_fp        [s] = ib_opnd_g[s].rs2_is_fp;
            ib_rs3_is_fp        [s] = ib_opnd_g[s].rs3_is_fp;

            // -- dequeue-side decode --
            ib_is_serial        [s] = dec_info[s].is_serial;
            ib_is_fp_instruction[s] = dec_info[s].is_fp_instruction;
            ib_is_store         [s] = dec_info[s].is_store;
            ib_exe_subop        [s] = dec_info[s].exe_subop;
            ib_full_decode      [s] = dec_info[s].full_decode;
        end
    end

    // ==================================================================
    // glue#2 · aggregation of the four completion lanes
    //
    //   lane0 = p3_arbiter_G0   lane1 = p3_arbiter_G1
    //   lane2 = fpu_simple direct (G2 single member, no arbiter)
    //   lane3 = g3_lsu_iface
    //
    // **Each group of arrays is aggregated only here, once**, then purely fanned out to Buffer /
    // CompletionScoreboard / dependency_check / the four ISQ_Groups /
    // isq_payload_assembly. Aggregated only once, the b of bypass_data[b] and
    // bypass_valid[b]/bypass_tag[b] is naturally the same.
    //
    // Always-zero fields are driven by the FUs themselves, the arbiters do not fabricate them,
    // so not a single field is synthesized or zero-filled here.
    // ==================================================================
    always_comb begin
        // ---------------- lane 0 : p3_arbiter_G0 ----------------
        exec_valid               [LANE_G0] = arbG0_Result_valid;
        exec_tag                 [LANE_G0] = arbG0_tag_out;
        lane_result_data         [LANE_G0] = arbG0_result_data;
        lane_mispredict_flag     [LANE_G0] = arbG0_mispredict_flag;
        lane_mispredict_target_pc[LANE_G0] = arbG0_mispredict_target_pc;
        lane_exception_flag      [LANE_G0] = arbG0_exception_flag;
        lane_exception_cause     [LANE_G0] = arbG0_exception_cause;
        lane_exception_tval      [LANE_G0] = arbG0_exception_tval;
        lane_is_mret             [LANE_G0] = arbG0_is_mret;
        lane_is_sret             [LANE_G0] = arbG0_is_sret;
        lane_fpu_fflags          [LANE_G0] = arbG0_fpu_fflags;
        lane_bypass_valid        [LANE_G0] = arbG0_bypass_valid;
        lane_bypass_tag          [LANE_G0] = arbG0_bypass_tag;
        lane_bypass_data         [LANE_G0] = arbG0_bypass_data;

        // ---------------- lane 1 : p3_arbiter_G1 ----------------
        exec_valid               [LANE_G1] = arbG1_Result_valid;
        exec_tag                 [LANE_G1] = arbG1_tag_out;
        lane_result_data         [LANE_G1] = arbG1_result_data;
        lane_mispredict_flag     [LANE_G1] = arbG1_mispredict_flag;
        lane_mispredict_target_pc[LANE_G1] = arbG1_mispredict_target_pc;
        lane_exception_flag      [LANE_G1] = arbG1_exception_flag;
        lane_exception_cause     [LANE_G1] = arbG1_exception_cause;
        lane_exception_tval      [LANE_G1] = arbG1_exception_tval;
        lane_is_mret             [LANE_G1] = arbG1_is_mret;
        lane_is_sret             [LANE_G1] = arbG1_is_sret;
        lane_fpu_fflags          [LANE_G1] = arbG1_fpu_fflags;
        lane_bypass_valid        [LANE_G1] = arbG1_bypass_valid;
        lane_bypass_tag          [LANE_G1] = arbG1_bypass_tag;
        lane_bypass_data         [LANE_G1] = arbG1_bypass_data;

        // ---------------- lane 2 : fpu_simple direct ----------------
        // "lane driver -> bypass_valid[b]/bypass_tag[b]/bypass_data[b]" is required
        // on all four lanes. G2 has no arbiter; fpu_simple itself has the three outputs bypass_valid /
        // bypass_tag / bypass_data (see u_fpu_simple's wiring below);
        // lane 2's bypass takes them directly, not substituted by a fan-out of lane 2's completion.
        exec_valid               [LANE_G2] = g2fu_Result_valid;
        exec_tag                 [LANE_G2] = g2fu_tag_out;
        lane_result_data         [LANE_G2] = g2fu_result_data;
        lane_mispredict_flag     [LANE_G2] = g2fu_mispredict_flag;
        lane_mispredict_target_pc[LANE_G2] = g2fu_mispredict_target_pc;
        lane_exception_flag      [LANE_G2] = g2fu_exception_flag;
        lane_exception_cause     [LANE_G2] = g2fu_exception_cause;
        lane_exception_tval      [LANE_G2] = g2fu_exception_tval;
        lane_is_mret             [LANE_G2] = g2fu_is_mret;
        lane_is_sret             [LANE_G2] = g2fu_is_sret;
        lane_fpu_fflags          [LANE_G2] = g2fu_fpu_fflags;
        // The FPU drives lane 2's bypass itself; the top does not derive it.
        lane_bypass_valid        [LANE_G2] = g2fu_bypass_valid;
        lane_bypass_tag          [LANE_G2] = g2fu_bypass_tag;
        lane_bypass_data         [LANE_G2] = g2fu_bypass_data;

        // ---------------- lane 3 : g3_lsu_iface ----------------
        exec_valid               [LANE_G3] = lsuif_Result_valid;
        exec_tag                 [LANE_G3] = lsuif_tag_out;
        lane_result_data         [LANE_G3] = lsuif_result_data;
        lane_mispredict_flag     [LANE_G3] = lsuif_mispredict_flag;
        lane_mispredict_target_pc[LANE_G3] = lsuif_mispredict_target_pc;
        lane_exception_flag      [LANE_G3] = lsuif_exception_flag;
        lane_exception_cause     [LANE_G3] = lsuif_exception_cause;
        lane_exception_tval      [LANE_G3] = lsuif_exception_tval;
        lane_is_mret             [LANE_G3] = lsuif_is_mret;
        lane_is_sret             [LANE_G3] = lsuif_is_sret;
        lane_fpu_fflags          [LANE_G3] = lsuif_fpu_fflags;
        lane_bypass_valid        [LANE_G3] = lsuif_bypass_valid;
        lane_bypass_tag          [LANE_G3] = lsuif_bypass_tag;
        lane_bypass_data         [LANE_G3] = lsuif_bypass_data;
    end

    // ==================================================================
    // glue#3 · each FU's completion request aggregated by in-group requester number
    //
    // Numbers come from the types package's G0_FU_* / G1_FU_* ("a count is not an identity"),
    // no literal 0/1/2: the arbiter's static priority chain is ordered by exactly this index.
    // ==================================================================
    always_comb begin
        // -------- G0 : ALU0/BRU, CSR, DIV --------
        g0_request_valid           [G0_FU_ALU] = alu0_request_valid;
        g0_req_tag                 [G0_FU_ALU] = alu0_req_tag;
        g0_req_result_data         [G0_FU_ALU] = alu0_req_result_data;
        g0_req_mispredict_flag     [G0_FU_ALU] = alu0_req_mispredict_flag;
        g0_req_mispredict_target_pc[G0_FU_ALU] = alu0_req_mispredict_target_pc;
        g0_req_exception_flag      [G0_FU_ALU] = alu0_req_exception_flag;
        g0_req_exception_cause     [G0_FU_ALU] = alu0_req_exception_cause;
        g0_req_exception_tval      [G0_FU_ALU] = alu0_req_exception_tval;
        g0_req_is_mret             [G0_FU_ALU] = alu0_req_is_mret;
        g0_req_is_sret             [G0_FU_ALU] = alu0_req_is_sret;
        g0_req_fpu_fflags          [G0_FU_ALU] = alu0_req_fpu_fflags;
        g0_req_is_csr              [G0_FU_ALU] = alu0_req_is_csr;
        g0_req_csr_write_enable    [G0_FU_ALU] = alu0_req_csr_write_enable;
        g0_req_csr_addr            [G0_FU_ALU] = alu0_req_csr_addr;
        g0_req_csr_wdata           [G0_FU_ALU] = alu0_req_csr_wdata;

        g0_request_valid           [G0_FU_CSR] = csrfu_request_valid;
        g0_req_tag                 [G0_FU_CSR] = csrfu_req_tag;
        g0_req_result_data         [G0_FU_CSR] = csrfu_req_result_data;
        g0_req_mispredict_flag     [G0_FU_CSR] = csrfu_req_mispredict_flag;
        g0_req_mispredict_target_pc[G0_FU_CSR] = csrfu_req_mispredict_target_pc;
        g0_req_exception_flag      [G0_FU_CSR] = csrfu_req_exception_flag;
        g0_req_exception_cause     [G0_FU_CSR] = csrfu_req_exception_cause;
        g0_req_exception_tval      [G0_FU_CSR] = csrfu_req_exception_tval;
        g0_req_is_mret             [G0_FU_CSR] = csrfu_req_is_mret;
        g0_req_is_sret             [G0_FU_CSR] = csrfu_req_is_sret;
        g0_req_fpu_fflags          [G0_FU_CSR] = csrfu_req_fpu_fflags;
        g0_req_is_csr              [G0_FU_CSR] = csrfu_req_is_csr;
        g0_req_csr_write_enable    [G0_FU_CSR] = csrfu_req_csr_write_enable;
        g0_req_csr_addr            [G0_FU_CSR] = csrfu_req_csr_addr;
        g0_req_csr_wdata           [G0_FU_CSR] = csrfu_req_csr_wdata;

        g0_request_valid           [G0_FU_DIV] = div_request_valid;
        g0_req_tag                 [G0_FU_DIV] = div_req_tag;
        g0_req_result_data         [G0_FU_DIV] = div_req_result_data;
        g0_req_mispredict_flag     [G0_FU_DIV] = div_req_mispredict_flag;
        g0_req_mispredict_target_pc[G0_FU_DIV] = div_req_mispredict_target_pc;
        g0_req_exception_flag      [G0_FU_DIV] = div_req_exception_flag;
        g0_req_exception_cause     [G0_FU_DIV] = div_req_exception_cause;
        g0_req_exception_tval      [G0_FU_DIV] = div_req_exception_tval;
        g0_req_is_mret             [G0_FU_DIV] = div_req_is_mret;
        g0_req_is_sret             [G0_FU_DIV] = div_req_is_sret;
        g0_req_fpu_fflags          [G0_FU_DIV] = div_req_fpu_fflags;
        g0_req_is_csr              [G0_FU_DIV] = div_req_is_csr;
        g0_req_csr_write_enable    [G0_FU_DIV] = div_req_csr_write_enable;
        g0_req_csr_addr            [G0_FU_DIV] = div_req_csr_addr;
        g0_req_csr_wdata           [G0_FU_DIV] = div_req_csr_wdata;

        // -------- G1 : ALU1, MUL (no csr_sideband layer) --------
        g1_request_valid           [G1_FU_ALU] = alu1_request_valid;
        g1_req_tag                 [G1_FU_ALU] = alu1_req_tag;
        g1_req_result_data         [G1_FU_ALU] = alu1_req_result_data;
        g1_req_mispredict_flag     [G1_FU_ALU] = alu1_req_mispredict_flag;
        g1_req_mispredict_target_pc[G1_FU_ALU] = alu1_req_mispredict_target_pc;
        g1_req_exception_flag      [G1_FU_ALU] = alu1_req_exception_flag;
        g1_req_exception_cause     [G1_FU_ALU] = alu1_req_exception_cause;
        g1_req_exception_tval      [G1_FU_ALU] = alu1_req_exception_tval;
        g1_req_is_mret             [G1_FU_ALU] = alu1_req_is_mret;
        g1_req_is_sret             [G1_FU_ALU] = alu1_req_is_sret;
        g1_req_fpu_fflags          [G1_FU_ALU] = alu1_req_fpu_fflags;

        g1_request_valid           [G1_FU_MUL] = mul_request_valid;
        g1_req_tag                 [G1_FU_MUL] = mul_req_tag;
        g1_req_result_data         [G1_FU_MUL] = mul_req_result_data;
        g1_req_mispredict_flag     [G1_FU_MUL] = mul_req_mispredict_flag;
        g1_req_mispredict_target_pc[G1_FU_MUL] = mul_req_mispredict_target_pc;
        g1_req_exception_flag      [G1_FU_MUL] = mul_req_exception_flag;
        g1_req_exception_cause     [G1_FU_MUL] = mul_req_exception_cause;
        g1_req_exception_tval      [G1_FU_MUL] = mul_req_exception_tval;
        g1_req_is_mret             [G1_FU_MUL] = mul_req_is_mret;
        g1_req_is_sret             [G1_FU_MUL] = mul_req_is_sret;
        g1_req_fpu_fflags          [G1_FU_MUL] = mul_req_fpu_fflags;
    end

    // ==================================================================
    // glue#4 · per-group aggregated FU_ready and isq_free_for_dispatch
    //
    //   FU_ready[k]              "each FU in group -> ISQ_Group_g", k is the in-group
    //                            requester number, taken from the types package as in glue#3.
    //   isq_free_for_dispatch[g] "ISQ_Group_g -> dispatch_logic",
    //                            g is the group number (dispatch_logic's GRP_G0..G3).
    // ==================================================================
    always_comb begin
        g0_FU_ready[G0_FU_ALU] = alu0_FU_ready;
        g0_FU_ready[G0_FU_CSR] = csrfu_FU_ready;
        g0_FU_ready[G0_FU_DIV] = div_FU_ready;

        g1_FU_ready[G1_FU_ALU] = alu1_FU_ready;
        g1_FU_ready[G1_FU_MUL] = mul_FU_ready;

        isq_free_for_dispatch[LANE_G0] = isq0_isq_free_for_dispatch;
        isq_free_for_dispatch[LANE_G1] = isq1_isq_free_for_dispatch;
        isq_free_for_dispatch[LANE_G2] = isq2_isq_free_for_dispatch;
        isq_free_for_dispatch[LANE_G3] = isq3_isq_free_for_dispatch;
    end

    // ==================================================================
    // The observation surface's only alias: global_flush_valid is the same source and same net as the
    // global_flush_late sent to lsu_if, just the observation-surface name (only one net is allowed;
    // there is no second driver here, the same net is just routed to one more top-level port).
    // ==================================================================
    assign global_flush_valid = global_flush_late;

    // ==================================================================
    // P1 fetch to dispatch
    // ==================================================================

    // ---- glue#5: fe_instr_pld[s] -> enqueue-side loose fields -------------------
    // All eleven fields are unpacked here (including inst_expanded / rvc_ill / opnd).
    // The downstream port list is authoritative; missing one fails compilation.
    logic [XLEN-1:0]               fe_pc               [ISSUE_WIDTH];
    logic [31:0]                   fe_inst_bits        [ISSUE_WIDTH];
    logic                          fe_is_compressed    [ISSUE_WIDTH];
    logic                          fe_pred_taken       [ISSUE_WIDTH];
    logic [XLEN-1:0]               fe_pred_target_pc   [ISSUE_WIDTH];
    logic                          fe_fetch_excp_vld   [ISSUE_WIDTH];
    logic [FETCH_EXCP_CAUSE_W-1:0] fe_fetch_excp_cause [ISSUE_WIDTH];
    logic [XLEN-1:0]               fe_fetch_excp_tval  [ISSUE_WIDTH];
    logic [31:0]                   fe_inst_expanded    [ISSUE_WIDTH];
    logic                          fe_rvc_ill          [ISSUE_WIDTH];
    ib_operand_info_t              fe_opnd             [ISSUE_WIDTH];

    always_comb begin
        for (int unsigned s = 0; s < ISSUE_WIDTH; s++) begin
            fe_pc[s]               = fe_instr_pld[s].pc;
            fe_inst_bits[s]        = fe_instr_pld[s].inst_bits;
            fe_is_compressed[s]    = fe_instr_pld[s].is_compressed;
            fe_pred_taken[s]       = fe_instr_pld[s].pred_taken;
            fe_pred_target_pc[s]   = fe_instr_pld[s].pred_target_pc;
            fe_fetch_excp_vld[s]   = fe_instr_pld[s].fetch_excp_vld;
            fe_fetch_excp_cause[s] = fe_instr_pld[s].fetch_excp_cause;
            fe_fetch_excp_tval[s]  = fe_instr_pld[s].fetch_excp_tval;
            fe_inst_expanded[s]    = fe_instr_pld[s].inst_expanded;
            fe_rvc_ill[s]          = fe_instr_pld[s].rvc_ill;
            fe_opnd[s]             = fe_instr_pld[s].opnd;
        end
    end

    // ---- glue#6: enqueue payload assembly (**pure wiring**) -----------------------
    // The fetch cycle (FE's flop -> IB's flop) **allows no logic at all**: measured,
    // this cycle cannot fit even one RVC expansion. So here the eleven fields of the FE payload are just
    // copied as-is into ib_payload_t, without even the `fetch_excp` clearing mask -- consumers already
    // qualify with `fetch_excp_vld` (alu_simple); that mask would only be hygiene.
    //
    // The field sets on both sides must match, pinned by or_be_types_check's
    // `IB_PAYLOAD_W == FE_BE_INSTR_PLD_W`.
    always_comb begin
        for (int unsigned s = 0; s < ISSUE_WIDTH; s++) begin
            enq_IB_Payload[s] = '0;

            enq_IB_Payload[s].pc               = fe_pc[s];
            enq_IB_Payload[s].inst_bits        = fe_inst_bits[s];
            enq_IB_Payload[s].is_compressed    = fe_is_compressed[s];
            enq_IB_Payload[s].pred_taken       = fe_pred_taken[s];
            enq_IB_Payload[s].pred_target_pc   = fe_pred_target_pc[s];
            enq_IB_Payload[s].fetch_excp_vld   = fe_fetch_excp_vld[s];
            enq_IB_Payload[s].fetch_excp_cause = fe_fetch_excp_cause[s];
            enq_IB_Payload[s].fetch_excp_tval  = fe_fetch_excp_tval[s];
            enq_IB_Payload[s].inst_expanded    = fe_inst_expanded[s];
            enq_IB_Payload[s].rvc_ill          = fe_rvc_ill[s];
            enq_IB_Payload[s].opnd             = fe_opnd[s];
        end
    end

    IB u_IB (
        .clk               (clk),
        .rst_n             (rst_n),
        .enq_IB_Payload    (enq_IB_Payload),
        // **fe_valid is wired directly from FE to IB.** decode is on the dequeue side, not on this path;
        // the admission chain and accepted_slot backpressure are defined by IB (3).
        .fe_valid          (fe_valid),
        .ib_dequeue        (dl_ib_dequeue),
        .global_flush_late (global_flush_late),
        .head_IB_Payload   (head_IB_Payload),
        .inst_valid        (ib_inst_valid),
        .fe_ready          (fe_ready),
        .accepted_slot     (accepted_slot)
    );

    // ---- glue#7: the five head -> decode inputs --------------------------
    // Expansion is in FE; decode takes the IB entry's inst_expanded / rvc_ill directly;
    // compressed sub-code re-encoding in decode uses the **original halfword** (low 16 bits of inst_bits).
    logic [31:0] ibh_inst32          [ISSUE_WIDTH];
    logic [15:0] ibh_inst16          [ISSUE_WIDTH];
    logic        ibh_is_compressed   [ISSUE_WIDTH];
    logic        ibh_rvc_ill         [ISSUE_WIDTH];
    logic        ibh_fetch_excp_vld  [ISSUE_WIDTH];

    always_comb begin
        for (int unsigned s = 0; s < ISSUE_WIDTH; s++) begin
            ibh_inst32        [s] = head_IB_Payload[s].inst_expanded;
            ibh_inst16        [s] = head_IB_Payload[s].inst_bits[15:0];
            ibh_is_compressed [s] = head_IB_Payload[s].is_compressed;
            ibh_rvc_ill       [s] = head_IB_Payload[s].rvc_ill;
            ibh_fetch_excp_vld[s] = head_IB_Payload[s].fetch_excp_vld;
        end
    end

    // **decode is after IB, in parallel with the address branch.**
    //   address branch  IB head opnd -> ARF / tag_mapping read (glue#1)
    //   decode branch   inst_expanded -> decode -> dec_info
    // The two join at dependency_check's qualifier terms and at isq_payload_assembly.
    decode u_decode (
        .ib_inst32         (ibh_inst32),
        .ib_inst16         (ibh_inst16),
        .ib_is_compressed  (ibh_is_compressed),
        .ib_rvc_illegal    (ibh_rvc_ill),
        .ib_fetch_excp_vld (ibh_fetch_excp_vld),
        .dec_info          (dec_info)
    );

    dependency_check u_dependency_check (
        .inst_valid                (ib_inst_valid),
        .rd_idx                    (ib_rd_idx),
        .rd_is_fp                  (ib_rd_is_fp),
        .use_rd                    (ib_use_rd),
        .is_serial                 (ib_is_serial),
        .is_fp_opcode              (ib_is_fp_opcode),
        .use_rs1                   (ib_use_rs1),
        .use_rs2                   (ib_use_rs2),
        .use_rs3                   (ib_use_rs3),
        .rs1_idx                   (ib_rs1_idx),
        .rs2_idx                   (ib_rs2_idx),
        .rs3_idx                   (ib_rs3_idx),
        .rs1_is_fp                 (ib_rs1_is_fp),
        .rs2_is_fp                 (ib_rs2_is_fp),
        .rs3_is_fp                 (ib_rs3_is_fp),
        .Buffer_tail               (scb_Buffer_tail),
        .INT_tag_mapping_tag       (intmap_tag),
        .INT_tag_mapping_busy      (intmap_busy),
        .FP_tag_mapping_tag        (fpmap_tag),
        .FP_tag_mapping_busy       (fpmap_busy),
        .scoreboard_valid_bits     (scb_scoreboard_valid_bits),
        .scoreboard_exec_done_bits (scb_scoreboard_exec_done_bits),
        .commit_valid              (commit_valid),
        .commit_tag                (commit_tag),
        // "lane driver -> dependency_check  bypass_valid[b], bypass_tag[b]
        // (no data)" -- the same group of arrays sent to each ISQ_Group / the assembly.
        .bypass_valid              (lane_bypass_valid),
        .bypass_tag                (lane_bypass_tag),
        .self_tag                  (alloc_tag),
        .rd_write_enable           (dc_rd_write_enable),
        .slot0_present             (dc_slot0_present),
        .slot1_present             (dc_slot1_present),
        .serial0                   (dc_serial0),
        .serial_inst               (dc_serial_inst),
        .fp0                       (dc_fp0),
        .fp1                       (dc_fp1),
        .slot_missed_wakeup        (dc_slot_missed_wakeup),
        .rsX_ready                 (dc_rsX_ready),
        .rsX_wait_tag              (dc_rsX_wait_tag),
        .rs_data_sel_t             (dc_rs_data_sel_t)
    );

    dispatch_logic u_dispatch_logic (
        .slot0_present         (dc_slot0_present),
        .slot1_present         (dc_slot1_present),
        .serial0               (dc_serial0),
        .serial_inst           (dc_serial_inst),
        .fp0                   (dc_fp0),
        .fp1                   (dc_fp1),
        .slot_missed_wakeup    (dc_slot_missed_wakeup),
        .exe_subop             (ib_exe_subop),
        .full_decode           (ib_full_decode),
        .is_fp_instruction     (ib_is_fp_instruction),
        .fs_enabled            (sih_fs_enabled),
        .frm                   (sih_frm),
        .can_alloc_1           (scb_can_alloc_1),
        .can_alloc_2           (scb_can_alloc_2),
        .buffer_empty          (scb_buffer_empty),
        .isq_free_for_dispatch (isq_free_for_dispatch),
        .serial_inflight_valid (sit_serial_inflight_valid),
        // "dependency_check -> dispatch_logic  self_tag[0]
        // (serial_set's forwarded payload)" -- only slot 0's is taken.
        .self_tag              (alloc_tag[0]),
        .global_flush_late     (global_flush_late),
        .accept                (alloc_valid),
        .ib_dequeue            (dl_ib_dequeue),
        .isq_wr_en             (dl_isq_wr_en),
        .slot_FU_Group         (dl_slot_FU_Group),
        .effective_rm          (dl_effective_rm),
        .is_fence_i            (dl_is_fence_i),
        .may_flush             (dl_may_flush),
        .is_atomic             (dl_is_atomic),
        .serial_set            (dl_serial_set),
        .serial_set_tag        (dl_serial_set_tag),
        .select_payload        (dl_select_payload)
    );

    INT_ARF u_INT_ARF (
        .clk             (clk),
        .rst_n           (rst_n),
        .commit_valid    (commit_valid),
        .rd_idx          (commit_rd_idx),
        .rd_is_fp        (commit_rd_is_fp),
        .rd_write_enable (commit_rd_write_enable),
        .commit_data     (commit_data),
        .rs_idx          (ib_int_rs_idx),
        .ARF             (intarf_ARF)
    );

    FP_ARF u_FP_ARF (
        .clk             (clk),
        .rst_n           (rst_n),
        .commit_valid    (commit_valid),
        .rd_write_enable (commit_rd_write_enable),
        .rd_is_fp        (commit_rd_is_fp),
        .rd_idx          (commit_rd_idx),
        .commit_data     (commit_data),
        .fp_read_idx     (fpmux_fp_read_idx),
        .ARF             (fparf_ARF)
    );

    INT_tag_mapping u_INT_tag_mapping (
        .clk                    (clk),
        .rst_n                  (rst_n),
        .accept                 (alloc_valid),
        .self_tag               (alloc_tag),
        .alloc_rd_idx           (ib_rd_idx),
        .alloc_rd_is_fp         (ib_rd_is_fp),
        .alloc_rd_write_enable  (dc_rd_write_enable),
        .commit_valid           (commit_valid),
        .commit_tag             (commit_tag),
        .commit_rd_idx          (commit_rd_idx),
        .commit_rd_is_fp        (commit_rd_is_fp),
        .commit_rd_write_enable (commit_rd_write_enable),
        .global_flush_late      (global_flush_late),
        .rs_idx                 (ib_int_rs_idx),
        .tag                    (intmap_tag),
        .busy                   (intmap_busy)
    );

    FP_tag_mapping u_FP_tag_mapping (
        .clk                    (clk),
        .rst_n                  (rst_n),
        .accept                 (alloc_valid),
        .alloc_rd_write_enable  (dc_rd_write_enable),
        .alloc_rd_is_fp         (ib_rd_is_fp),
        .alloc_rd_idx           (ib_rd_idx),
        .self_tag               (alloc_tag),
        .commit_valid           (commit_valid),
        .commit_tag             (commit_tag),
        .commit_rd_idx          (commit_rd_idx),
        .commit_rd_is_fp        (commit_rd_is_fp),
        .commit_rd_write_enable (commit_rd_write_enable),
        .global_flush_late      (global_flush_late),
        .fp_read_idx            (fpmux_fp_read_idx),
        .tag                    (fpmap_tag),
        .busy                   (fpmap_busy)
    );

    FP_read_address_mux u_FP_read_address_mux (
        .rs1_idx           (ib_rs1_idx),
        .rs2_idx           (ib_rs2_idx),
        .rs3_idx           (ib_rs3_idx),
        // Connected here is the **ungated is_fp_opcode[0]**, not is_fp_instruction[0]
        // (IB head opnd.is_fp_opcode, reason in FP_read_address_mux). The port is scalar and takes only slot 0's bit.
        .is_fp_opcode      (ib_is_fp_opcode[0]),
        .fp_read_idx       (fpmux_fp_read_idx)
    );

    // Payload assembly (the only glue logic in the whole library, split into its own module; the top only wires it)
    isq_payload_assembly u_isq_payload_assembly (
        .head_IB_Payload (head_IB_Payload),
        .dec_info        (dec_info),
        .opnd            (ib_opnd_g),
        .rsX_ready       (dc_rsX_ready),
        .rsX_wait_tag    (dc_rsX_wait_tag),
        .rs_data_sel_t   (dc_rs_data_sel_t),
        .self_tag        (alloc_tag),
        .INT_ARF         (intarf_ARF),
        .FP_ARF          (fparf_ARF),
        .commit_data     (commit_data),
        // "lane driver -> assembly  bypass_data[b]" -- the same b from the same
        // aggregation as the bypass_valid/tag sent to dependency_check.
        .bypass_data     (lane_bypass_data),
        .slot_FU_Group   (dl_slot_FU_Group),
        .effective_rm    (dl_effective_rm),
        .slot_payload    (asm_slot_payload)
    );

    // 4 p1_ISQ_input_mux, one per group; the g-th takes select_payload[g][0/1].
    // Output port name ISQ_payload_in, ISQ_Group-side input name payload_in -- different names at the two ends
    // of the same net are normal.
    p1_ISQ_input_mux u_p1_ISQ_input_mux_G0 (
        .slot_payload   (asm_slot_payload),
        .select_payload (dl_select_payload[LANE_G0]),
        .ISQ_payload_in (mux_ISQ_payload_in[LANE_G0])
    );

    p1_ISQ_input_mux u_p1_ISQ_input_mux_G1 (
        .slot_payload   (asm_slot_payload),
        .select_payload (dl_select_payload[LANE_G1]),
        .ISQ_payload_in (mux_ISQ_payload_in[LANE_G1])
    );

    p1_ISQ_input_mux u_p1_ISQ_input_mux_G2 (
        .slot_payload   (asm_slot_payload),
        .select_payload (dl_select_payload[LANE_G2]),
        .ISQ_payload_in (mux_ISQ_payload_in[LANE_G2])
    );

    p1_ISQ_input_mux u_p1_ISQ_input_mux_G3 (
        .slot_payload   (asm_slot_payload),
        .select_payload (dl_select_payload[LANE_G3]),
        .ISQ_payload_in (mux_ISQ_payload_in[LANE_G3])
    );

    // ==================================================================
    // P2 / P3 issue to completion
    // ==================================================================

    ISQ_Group0 u_ISQ_Group0 (
        .clk                   (clk),
        .rst_n                 (rst_n),
        .wr_en                 (dl_isq_wr_en[LANE_G0]),
        .payload_in            (mux_ISQ_payload_in[LANE_G0]),
        .bypass_valid          (lane_bypass_valid),
        .bypass_tag            (lane_bypass_tag),
        .bypass_data           (lane_bypass_data),
        .global_flush_late     (global_flush_late),
        .FU_ready              (g0_FU_ready),
        .issue_valid           (isq0_issue_valid),
        .rs1_data              (isq0_rs1_data),
        .rs2_data              (isq0_rs2_data),
        .FU_Group              (isq0_FU_Group),
        .imm_valid             (isq0_imm_valid),
        .imm_data              (isq0_imm_data),
        .pc                    (isq0_pc),
        .inst_bits             (isq0_inst_bits),
        .is_compressed         (isq0_is_compressed),
        .pred_taken            (isq0_pred_taken),
        .pred_target_pc        (isq0_pred_target_pc),
        .self_tag              (isq0_self_tag),
        .exe_subop             (isq0_exe_subop),
        .full_decode           (isq0_full_decode),
        .fetch_excp_vld        (isq0_fetch_excp_vld),
        .fetch_excp_cause      (isq0_fetch_excp_cause),
        .fetch_excp_tval       (isq0_fetch_excp_tval),
        .isq_free_for_dispatch (isq0_isq_free_for_dispatch)
    );

    ISQ_Group1 u_ISQ_Group1 (
        .clk                   (clk),
        .rst_n                 (rst_n),
        .wr_en                 (dl_isq_wr_en[LANE_G1]),
        .payload_in            (mux_ISQ_payload_in[LANE_G1]),
        .bypass_valid          (lane_bypass_valid),
        .bypass_tag            (lane_bypass_tag),
        .bypass_data           (lane_bypass_data),
        .global_flush_late     (global_flush_late),
        .FU_ready              (g1_FU_ready),
        .issue_valid           (isq1_issue_valid),
        .rs1_data              (isq1_rs1_data),
        .rs2_data              (isq1_rs2_data),
        .FU_Group              (isq1_FU_Group),
        .imm_valid             (isq1_imm_valid),
        .imm_data              (isq1_imm_data),
        .self_tag              (isq1_self_tag),
        .exe_subop             (isq1_exe_subop),
        .isq_free_for_dispatch (isq1_isq_free_for_dispatch)
    );

    ISQ_Group2 u_ISQ_Group2 (
        .clk                   (clk),
        .rst_n                 (rst_n),
        .payload_in            (mux_ISQ_payload_in[LANE_G2]),
        .wr_en                 (dl_isq_wr_en[LANE_G2]),
        .bypass_valid          (lane_bypass_valid),
        .bypass_tag            (lane_bypass_tag),
        .bypass_data           (lane_bypass_data),
        .global_flush_late     (global_flush_late),
        // G2 single member, FU_ready is scalar (G2_NUM_FU = 1, no arbiter)
        .FU_ready              (g2fu_FU_ready),
        .issue_valid           (isq2_issue_valid),
        .rs1_data              (isq2_rs1_data),
        .rs2_data              (isq2_rs2_data),
        .rs3_data              (isq2_rs3_data),
        .self_tag              (isq2_self_tag),
        .exe_subop             (isq2_exe_subop),
        .full_decode           (isq2_full_decode),
        .isq_free_for_dispatch (isq2_isq_free_for_dispatch)
    );

    ISQ_Group3 u_ISQ_Group3 (
        .clk                   (clk),
        .rst_n                 (rst_n),
        .wr_en                 (dl_isq_wr_en[LANE_G3]),
        .payload_in            (mux_ISQ_payload_in[LANE_G3]),
        .bypass_valid          (lane_bypass_valid),
        .bypass_tag            (lane_bypass_tag),
        .bypass_data           (lane_bypass_data),
        .global_flush_late     (global_flush_late),
        // "g3_lsu_iface -> ISQ_Group3  FU_ready (one bit, qualified by entry class)"
        .FU_ready              (lsuif_FU_ready),
        .issue_valid           (isq3_issue_valid),
        .rs1_data              (isq3_rs1_data),
        .rs2_data              (isq3_rs2_data),
        .imm_valid             (isq3_imm_valid),
        .imm_data              (isq3_imm_data),
        .is_store              (isq3_is_store),
        .mem_funct3            (isq3_mem_funct3),
        .rd_is_fp              (isq3_rd_is_fp),
        .self_tag              (isq3_self_tag),
        .exe_subop             (isq3_exe_subop),
        .isq_free_for_dispatch (isq3_isq_free_for_dispatch),
        // The value of "ISQ_Group3 -> CompletionScoreboard  isq_occupied".
        // Same source and same cycle as self_tag, forming the "address + address valid" halves of the st_br_resolve read port.
        .isq_occupied          (isq3_occupied)
    );

    // ---- G0's three FUs ----------------------------------------------------
    alu_simple #(
        // For assertions only: 1 = this instance is in G0.
        .IS_G0 (1'b1)
    ) u_alu0_bru (
        .clk                            (clk),
        .rst_n                          (rst_n),
        .global_flush_late              (global_flush_late),
        .issue_valid                    (isq0_issue_valid),
        .rs1_data                       (isq0_rs1_data),
        .rs2_data                       (isq0_rs2_data),
        .FU_Group                       (isq0_FU_Group),
        .imm_valid                      (isq0_imm_valid),
        .imm_data                       (isq0_imm_data),
        .pc                             (isq0_pc),
        .inst_bits                      (isq0_inst_bits),
        .is_compressed                  (isq0_is_compressed),
        .pred_taken                     (isq0_pred_taken),
        .pred_target_pc                 (isq0_pred_target_pc),
        .self_tag                       (isq0_self_tag),
        .exe_subop                      (isq0_exe_subop),
        .full_decode                    (isq0_full_decode),
        .fetch_excp_vld                 (isq0_fetch_excp_vld),
        .fetch_excp_cause               (isq0_fetch_excp_cause),
        .fetch_excp_tval                (isq0_fetch_excp_tval),
        .current_priv                   (sih_current_priv),
        .mstatus_tsr                    (sih_mstatus_tsr),
        .mstatus_tw                     (sih_mstatus_tw),
        .mstatus_tvm                    (sih_mstatus_tvm),
        .FU_ready                       (alu0_FU_ready),
        .request_valid                  (alu0_request_valid),
        .req_tag                        (alu0_req_tag),
        .req_result_data                (alu0_req_result_data),
        .req_mispredict_flag            (alu0_req_mispredict_flag),
        .req_mispredict_target_pc       (alu0_req_mispredict_target_pc),
        .req_exception_flag             (alu0_req_exception_flag),
        .req_exception_cause            (alu0_req_exception_cause),
        .req_exception_tval             (alu0_req_exception_tval),
        .req_is_mret                    (alu0_req_is_mret),
        .req_is_sret                    (alu0_req_is_sret),
        .req_fpu_fflags                 (alu0_req_fpu_fflags),
        .req_is_csr                     (alu0_req_is_csr),
        .req_csr_write_enable           (alu0_req_csr_write_enable),
        .req_csr_addr                   (alu0_req_csr_addr),
        .req_csr_wdata                  (alu0_req_csr_wdata),
        // "G0's BRU -> FE  predictor_update", sent directly in the execute cycle, not through the arbiter
        .predictor_update_valid         (predictor_update_valid),
        .predictor_update_branch_pc     (predictor_update_branch_pc),
        .predictor_update_actual_taken  (predictor_update_actual_taken),
        .predictor_update_actual_target (predictor_update_actual_target),
        .predictor_update_cf_class      (predictor_update_cf_class),
        .winner_grant                   (arbG0_winner_grant[G0_FU_ALU]),
        .loser_hold                     (arbG0_loser_hold  [G0_FU_ALU])
    );

    csr_unit u_csr_unit (
        .clk                      (clk),
        .rst_n                    (rst_n),
        .global_flush_late        (global_flush_late),
        .issue_valid              (isq0_issue_valid),
        .rs1_data                 (isq0_rs1_data),
        .rs2_data                 (isq0_rs2_data),
        .FU_Group                 (isq0_FU_Group),
        .imm_valid                (isq0_imm_valid),
        .imm_data                 (isq0_imm_data),
        .pc                       (isq0_pc),
        .inst_bits                (isq0_inst_bits),
        .is_compressed            (isq0_is_compressed),
        .pred_taken               (isq0_pred_taken),
        .pred_target_pc           (isq0_pred_target_pc),
        .self_tag                 (isq0_self_tag),
        .exe_subop                (isq0_exe_subop),
        .full_decode              (isq0_full_decode),
        // "csr_fu -> system_instruction_handler  csr_addr (read address)" and
        // the reverse "CSR[csr_addr] old value, current_priv, fs_enabled" -- the two halves of a combinational read port
        // ("a combinational read port with an external argument is two edges").
        .csr_addr                 (csrfu_csr_addr),
        .csr_rdata                (sih_csr_rdata),
        .current_priv             (sih_current_priv),
        .mstatus_tvm              (sih_mstatus_tvm),
        .fs_enabled               (sih_fs_enabled),
        .winner_grant             (arbG0_winner_grant[G0_FU_CSR]),
        .loser_hold               (arbG0_loser_hold  [G0_FU_CSR]),
        .FU_ready                 (csrfu_FU_ready),
        .request_valid            (csrfu_request_valid),
        .req_tag                  (csrfu_req_tag),
        .req_result_data          (csrfu_req_result_data),
        .req_mispredict_flag      (csrfu_req_mispredict_flag),
        .req_mispredict_target_pc (csrfu_req_mispredict_target_pc),
        .req_exception_flag       (csrfu_req_exception_flag),
        .req_exception_cause      (csrfu_req_exception_cause),
        .req_exception_tval       (csrfu_req_exception_tval),
        .req_is_mret              (csrfu_req_is_mret),
        .req_is_sret              (csrfu_req_is_sret),
        .req_fpu_fflags           (csrfu_req_fpu_fflags),
        .req_is_csr               (csrfu_req_is_csr),
        .req_csr_write_enable     (csrfu_req_csr_write_enable),
        .req_csr_addr             (csrfu_req_csr_addr),
        .req_csr_wdata            (csrfu_req_csr_wdata)
    );

    div_simple u_div_simple (
        .clk                      (clk),
        .rst_n                    (rst_n),
        .global_flush_late        (global_flush_late),
        .issue_valid              (isq0_issue_valid),
        .rs1_data                 (isq0_rs1_data),
        .rs2_data                 (isq0_rs2_data),
        .FU_Group                 (isq0_FU_Group),
        .imm_valid                (isq0_imm_valid),
        .imm_data                 (isq0_imm_data),
        .pc                       (isq0_pc),
        .inst_bits                (isq0_inst_bits),
        .is_compressed            (isq0_is_compressed),
        .pred_taken               (isq0_pred_taken),
        .pred_target_pc           (isq0_pred_target_pc),
        .self_tag                 (isq0_self_tag),
        .exe_subop                (isq0_exe_subop),
        .full_decode              (isq0_full_decode),
        .winner_grant             (arbG0_winner_grant[G0_FU_DIV]),
        .loser_hold               (arbG0_loser_hold  [G0_FU_DIV]),
        .FU_ready                 (div_FU_ready),
        .request_valid            (div_request_valid),
        .req_tag                  (div_req_tag),
        .req_result_data          (div_req_result_data),
        .req_mispredict_flag      (div_req_mispredict_flag),
        .req_mispredict_target_pc (div_req_mispredict_target_pc),
        .req_exception_flag       (div_req_exception_flag),
        .req_exception_cause      (div_req_exception_cause),
        .req_exception_tval       (div_req_exception_tval),
        .req_is_mret              (div_req_is_mret),
        .req_is_sret              (div_req_is_sret),
        .req_fpu_fflags           (div_req_fpu_fflags),
        .req_is_csr               (div_req_is_csr),
        .req_csr_write_enable     (div_req_csr_write_enable),
        .req_csr_addr             (div_req_csr_addr),
        .req_csr_wdata            (div_req_csr_wdata)
    );

    // ---- G1's two FUs:
    // G1 has no pc / inst_bits / is_compressed / pred_taken / pred_target_pc /
    // full_decode -- ISQ_Group1 does not produce these six fields at all. alu_simple is the same RTL,
    // its ports have no source in the G1 position, so they are tied to constant 0: this is exactly the
    // physical reason why "event fields are naturally always zero" (branch / CSR / SYS / illegal are all routed to G0 by dispatch_logic).
    alu_simple #(
        // For assertions only: 0 = this instance is in G1.
        .IS_G0 (1'b0)
    ) u_alu1 (
        .clk                            (clk),
        .rst_n                          (rst_n),
        .global_flush_late              (global_flush_late),
        .issue_valid                    (isq1_issue_valid),
        .rs1_data                       (isq1_rs1_data),
        .rs2_data                       (isq1_rs2_data),
        .FU_Group                       (isq1_FU_Group),
        .imm_valid                      (isq1_imm_valid),
        .imm_data                       (isq1_imm_data),
        .pc                             ('0),
        .inst_bits                      ('0),
        .is_compressed                  ('0),
        .pred_taken                     ('0),
        .pred_target_pc                 ('0),
        .self_tag                       (isq1_self_tag),
        .exe_subop                      (isq1_exe_subop),
        .full_decode                    ('0),
        // Same as above: ISQ_Group1 does not produce fetch-exception fields, and decode never routes
        // an entry with a fetch error to G1 (it is forced onto ILLEGAL's G0 path).
        .fetch_excp_vld                 (1'b0),
        .fetch_excp_cause               ('0),
        .fetch_excp_tval                ('0),
        .current_priv                   (2'b11),   // G1 never receives SYS, tie to M constant
        // Likewise: G1 never receives SRET / WFI / SFENCE.VMA, so these three are tied to 0.
        .mstatus_tsr                    (1'b0),
        .mstatus_tw                     (1'b0),
        .mstatus_tvm                    (1'b0),
        .FU_ready                       (alu1_FU_ready),
        .request_valid                  (alu1_request_valid),
        .req_tag                        (alu1_req_tag),
        .req_result_data                (alu1_req_result_data),
        .req_mispredict_flag            (alu1_req_mispredict_flag),
        .req_mispredict_target_pc       (alu1_req_mispredict_target_pc),
        .req_exception_flag             (alu1_req_exception_flag),
        .req_exception_cause            (alu1_req_exception_cause),
        .req_exception_tval             (alu1_req_exception_tval),
        .req_is_mret                    (alu1_req_is_mret),
        .req_is_sret                    (alu1_req_is_sret),
        .req_fpu_fflags                 (alu1_req_fpu_fflags),
        // No counterpart (p3_arbiter_G1 has no csr_sideband layer): connected to named wires that go nowhere;
        // port lines are not omitted.
        .req_is_csr                     (alu1_req_is_csr),
        .req_csr_write_enable           (alu1_req_csr_write_enable),
        .req_csr_addr                   (alu1_req_csr_addr),
        .req_csr_wdata                  (alu1_req_csr_wdata),
        // Same as above: only G0's BRU has a counterpart for predictor_update.
        .predictor_update_valid         (alu1_predictor_update_valid),
        .predictor_update_branch_pc     (alu1_predictor_update_branch_pc),
        .predictor_update_actual_taken  (alu1_predictor_update_actual_taken),
        .predictor_update_actual_target (alu1_predictor_update_actual_target),
        .predictor_update_cf_class      (alu1_predictor_update_cf_class),
        .winner_grant                   (arbG1_winner_grant[G1_FU_ALU]),
        .loser_hold                     (arbG1_loser_hold  [G1_FU_ALU])
    );

    mul_simple u_mul_simple (
        .clk                      (clk),
        .rst_n                    (rst_n),
        .global_flush_late        (global_flush_late),
        .issue_valid              (isq1_issue_valid),
        .rs1_data                 (isq1_rs1_data),
        .rs2_data                 (isq1_rs2_data),
        .FU_Group                 (isq1_FU_Group),
        .imm_valid                (isq1_imm_valid),
        .imm_data                 (isq1_imm_data),
        .self_tag                 (isq1_self_tag),
        .exe_subop                (isq1_exe_subop),
        .winner_grant             (arbG1_winner_grant[G1_FU_MUL]),
        .loser_hold               (arbG1_loser_hold  [G1_FU_MUL]),
        .request_valid            (mul_request_valid),
        .req_tag                  (mul_req_tag),
        .req_result_data          (mul_req_result_data),
        .req_mispredict_flag      (mul_req_mispredict_flag),
        .req_mispredict_target_pc (mul_req_mispredict_target_pc),
        .req_exception_flag       (mul_req_exception_flag),
        .req_exception_cause      (mul_req_exception_cause),
        .req_exception_tval       (mul_req_exception_tval),
        .req_is_mret              (mul_req_is_mret),
        .req_is_sret              (mul_req_is_sret),
        .req_fpu_fflags           (mul_req_fpu_fflags),
        .FU_ready                 (mul_FU_ready)
    );

    // ---- G2's FPU: no arbiter, completion directly on lane 2, ports use bare names ----
    fpu_simple u_fpu_simple (
        .clk                  (clk),
        .rst_n                (rst_n),
        .global_flush_late    (global_flush_late),
        .issue_valid          (isq2_issue_valid),
        .rs1_data             (isq2_rs1_data),
        .rs2_data             (isq2_rs2_data),
        .rs3_data             (isq2_rs3_data),
        .self_tag             (isq2_self_tag),
        .exe_subop            (isq2_exe_subop),
        // full_decode's three rm bits were already overridden by effective_rm in the assembly cycle; the FPU uses it directly,
        // and the edge system_instruction_handler -> FPU  frm does not exist.
        .full_decode          (isq2_full_decode),
        .FU_ready             (g2fu_FU_ready),
        .Result_valid         (g2fu_Result_valid),
        .tag_out              (g2fu_tag_out),
        .result_data          (g2fu_result_data),
        .mispredict_flag      (g2fu_mispredict_flag),
        .mispredict_target_pc (g2fu_mispredict_target_pc),
        .exception_flag       (g2fu_exception_flag),
        .exception_cause      (g2fu_exception_cause),
        .exception_tval       (g2fu_exception_tval),
        .is_mret              (g2fu_is_mret),
        .is_sret              (g2fu_is_sret),
        .fpu_fflags           (g2fu_fpu_fflags),
        .bypass_valid              (g2fu_bypass_valid),
        .bypass_tag                (g2fu_bypass_tag),
        .bypass_data               (g2fu_bypass_data)
    );

    // ---- the two in-group arbiters ----
    p3_arbiter_G0 u_p3_arbiter_G0 (
        .request_valid            (g0_request_valid),
        .req_tag                  (g0_req_tag),
        .req_result_data          (g0_req_result_data),
        .req_mispredict_flag      (g0_req_mispredict_flag),
        .req_mispredict_target_pc (g0_req_mispredict_target_pc),
        .req_exception_flag       (g0_req_exception_flag),
        .req_exception_cause      (g0_req_exception_cause),
        .req_exception_tval       (g0_req_exception_tval),
        .req_is_mret              (g0_req_is_mret),
        .req_is_sret              (g0_req_is_sret),
        .req_fpu_fflags           (g0_req_fpu_fflags),
        .req_is_csr               (g0_req_is_csr),
        .req_csr_write_enable     (g0_req_csr_write_enable),
        .req_csr_addr             (g0_req_csr_addr),
        .req_csr_wdata            (g0_req_csr_wdata),
        .Result_valid             (arbG0_Result_valid),
        .tag_out                  (arbG0_tag_out),
        .result_data              (arbG0_result_data),
        .mispredict_flag          (arbG0_mispredict_flag),
        .mispredict_target_pc     (arbG0_mispredict_target_pc),
        .exception_flag           (arbG0_exception_flag),
        .exception_cause          (arbG0_exception_cause),
        .exception_tval           (arbG0_exception_tval),
        .is_mret                  (arbG0_is_mret),
        .is_sret                  (arbG0_is_sret),
        .fpu_fflags               (arbG0_fpu_fflags),
        .is_csr                   (arbG0_is_csr),
        .csr_write_enable         (arbG0_csr_write_enable),
        .csr_addr                 (arbG0_csr_addr),
        .csr_wdata                (arbG0_csr_wdata),
        .bypass_valid             (arbG0_bypass_valid),
        .bypass_tag               (arbG0_bypass_tag),
        .bypass_data              (arbG0_bypass_data),
        .winner_grant             (arbG0_winner_grant),
        .loser_hold               (arbG0_loser_hold)
    );

    p3_arbiter_G1 u_p3_arbiter_G1 (
        .req_tag                  (g1_req_tag),
        .req_result_data          (g1_req_result_data),
        .req_exception_flag       (g1_req_exception_flag),
        .req_exception_cause      (g1_req_exception_cause),
        .req_exception_tval       (g1_req_exception_tval),
        .req_mispredict_flag      (g1_req_mispredict_flag),
        .req_mispredict_target_pc (g1_req_mispredict_target_pc),
        .req_is_mret              (g1_req_is_mret),
        .req_is_sret              (g1_req_is_sret),
        .req_fpu_fflags           (g1_req_fpu_fflags),
        .request_valid            (g1_request_valid),
        .Result_valid             (arbG1_Result_valid),
        .tag_out                  (arbG1_tag_out),
        .result_data              (arbG1_result_data),
        .exception_flag           (arbG1_exception_flag),
        .exception_cause          (arbG1_exception_cause),
        .exception_tval           (arbG1_exception_tval),
        .mispredict_flag          (arbG1_mispredict_flag),
        .mispredict_target_pc     (arbG1_mispredict_target_pc),
        .is_mret                  (arbG1_is_mret),
        .is_sret                  (arbG1_is_sret),
        .fpu_fflags               (arbG1_fpu_fflags),
        .bypass_valid             (arbG1_bypass_valid),
        .bypass_tag               (arbG1_bypass_tag),
        .bypass_data              (arbG1_bypass_data),
        .winner_grant             (arbG1_winner_grant),
        .loser_hold               (arbG1_loser_hold)
    );

    // ---- G3's boundary bridge (driver of lane 3) ----
    g3_lsu_iface u_g3_lsu_iface (
        .clk                       (clk),
        .rst_n                     (rst_n),
        .issue_valid               (isq3_issue_valid),
        .self_tag                  (isq3_self_tag),
        .exe_subop                 (isq3_exe_subop),
        .mem_funct3                (isq3_mem_funct3),
        .rd_is_fp                  (isq3_rd_is_fp),
        .rs1_data                  (isq3_rs1_data),
        .rs2_data                  (isq3_rs2_data),
        .imm_valid                 (isq3_imm_valid),
        .imm_data                  (isq3_imm_data),
        .is_store                  (isq3_is_store),
        // The value half of "CompletionScoreboard -> g3_lsu_iface  st_br_resolve_by_tag";
        // for the address half see CompletionScoreboard's st_br_resolve_tag.
        .st_br_resolve             (scb_st_br_resolve),
        .store_wakeup_valid        (scb_store_wakeup_valid),
        .store_wakeup_tag          (scb_store_wakeup_tag),
        .global_flush_late         (global_flush_late),
        .lsu_be_issue_ready        (lsu_be_issue_ready),
        .lsu_be_done_valid         (lsu_be_done_valid),
        .lsu_be_done_pld           (lsu_be_done_pld),
        .lsu_be_exception_valid    (lsu_be_exception_valid),
        .lsu_be_exception_pld      (lsu_be_exception_pld),
        .lsu_be_bypass_valid       (lsu_be_bypass_valid),
        .lsu_be_bypass_pld         (lsu_be_bypass_pld),
        .FU_ready                  (lsuif_FU_ready),
        .Result_valid              (lsuif_Result_valid),
        .tag_out                   (lsuif_tag_out),
        .result_data               (lsuif_result_data),
        .mispredict_flag           (lsuif_mispredict_flag),
        .mispredict_target_pc      (lsuif_mispredict_target_pc),
        .exception_flag            (lsuif_exception_flag),
        .exception_cause           (lsuif_exception_cause),
        .exception_tval            (lsuif_exception_tval),
        .is_mret                   (lsuif_is_mret),
        .is_sret                   (lsuif_is_sret),
        .fpu_fflags                (lsuif_fpu_fflags),
        .bypass_valid              (lsuif_bypass_valid),
        .bypass_tag                (lsuif_bypass_tag),
        .bypass_data               (lsuif_bypass_data),
        .be_lsu_issue_valid        (be_lsu_issue_valid),
        .be_lsu_issue_pld          (be_lsu_issue_pld),
        .be_lsu_entry_ready        (be_lsu_entry_ready),
        .be_lsu_store_wakeup_valid (be_lsu_store_wakeup_valid)
    );

    // ==================================================================
    // P4 commit, flush and recovery
    // ==================================================================

    Buffer u_Buffer (
        .clk          (clk),
        .rst_n        (rst_n),
        .Result_valid (exec_valid),
        .tag_out      (exec_tag),
        .result_data  (lane_result_data),
        .head0_tag    (scb_head0_tag),
        .head1_tag    (scb_head1_tag),
        .commit_data  (commit_data)
    );

    PC_File u_PC_File (
        .clk       (clk),
        .rst_n     (rst_n),
        .accept    (alloc_valid),
        .self_tag  (alloc_tag),
        .pc        (ib_pc),
        // The address of both recovery read ports is the same flush_tag produced by the SCB,
        // fanned out in the same cycle; flush_model does not re-drive it.
        .flush_tag (scb_flush_tag),
        .head0_tag (scb_head0_tag),
        .head1_tag (scb_head1_tag),
        .inst_pc   (pcf_inst_pc),
        .trace_pc  (trace_pc)
    );

    SerialInstructionTracker u_SerialInstructionTracker (
        .clk                   (clk),
        .rst_n                 (rst_n),
        .serial_set            (dl_serial_set),
        // "dispatch_logic -> SerialInstructionTracker  serial_set,
        // self_tag[0]": the forwarded payload is called serial_set_tag on the dispatch_logic side.
        .self_tag              (dl_serial_set_tag),
        .commit_valid          (commit_valid),
        .commit_tag            (commit_tag),
        .global_flush_late     (global_flush_late),
        .serial_inflight_valid (sit_serial_inflight_valid)
    );

    flush_model u_flush_model (
        .recovery_kind              (scb_recovery_kind),
        .flush_valid                (scb_flush_valid),
        .flush_tag                  (scb_flush_tag),
        .mispredict_target_pc       (scb_recovery_mispredict_target_pc),
        .exception_cause            (scb_recovery_exception_cause),
        .exception_tval             (scb_recovery_exception_tval),
        .inst_pc                    (pcf_inst_pc),
        .mepc                       (sih_mepc),
        .sepc                       (sih_sepc),
        .interrupt_cause            (sih_interrupt_cause),
        // The "value" half of the trap_vector(cause, is_interrupt) combinational read port;
        // the "argument" half is the cause / is_interrupt pair below.
        .trap_vector                (sih_trap_vector),
        .global_flush_late          (global_flush_late),
        .redirect_valid             (redirect_valid),
        .redirect_pc                (redirect_pc),
        .redirect_kind              (redirect_kind),
        .frontend_icache_invalidate (frontend_icache_invalidate),
        .trap_state_write           (fm_trap_state_write),
        .cause                      (fm_cause),
        .is_interrupt               (fm_is_interrupt)
    );

    system_instruction_handler u_system_instruction_handler (
        .clk                    (clk),
        .rst_n                  (rst_n),
        // Lane 0's csr_sideband bypasses the SCB and connects directly to this module -- the only one in the whole library.
        .Result_valid           (arbG0_Result_valid),
        .tag_out                (arbG0_tag_out),
        .sb_is_csr              (arbG0_is_csr),
        .sb_csr_write_enable    (arbG0_csr_write_enable),
        .sb_csr_addr            (arbG0_csr_addr),
        .sb_csr_wdata           (arbG0_csr_wdata),
        .commit_valid           (commit_valid),
        .commit_tag             (commit_tag),
        .commit_fflags          (commit_fflags),
        .rd_is_fp               (commit_rd_is_fp),
        .rd_write_enable        (commit_rd_write_enable),
        .commit_count           (commit_count),
        .trap_state_write       (fm_trap_state_write),
        .global_flush_late      (global_flush_late),
        // csr_fu's software read address ("csr_fu -> system_instruction_handler
        // csr_addr (read address)"); it and sb_csr_addr are two different in-events,
        // split into two ports.
        .csr_addr               (csrfu_csr_addr),
        .trap_cause_in          (fm_cause),
        .trap_is_interrupt_in   (fm_is_interrupt),
        .mip_meip               (mip_meip),
        .mip_mtip               (mip_mtip),
        .mip_msip               (mip_msip),
        .csr_rdata              (sih_csr_rdata),
        .current_priv           (sih_current_priv),
        .frm                    (sih_frm),
        .fs_enabled             (sih_fs_enabled),
        .trap_vector            (sih_trap_vector),
        .interrupt_pending      (sih_interrupt_pending),
        .interrupt_cause        (sih_interrupt_cause),
        .mepc                   (sih_mepc),
        .sepc                   (sih_sepc),
        .mstatus_tvm            (sih_mstatus_tvm),
        .mstatus_tw             (sih_mstatus_tw),
        .mstatus_tsr            (sih_mstatus_tsr)
    );

    CompletionScoreboard u_CompletionScoreboard (
        .clk                           (clk),
        .rst_n                         (rst_n),
        .accept                        (alloc_valid),
        .alloc_self_tag                (alloc_tag),
        .rd_idx                        (ib_rd_idx),
        .rd_is_fp                      (ib_rd_is_fp),
        .rd_write_enable               (dc_rd_write_enable),
        .is_store                      (ib_is_store),
        .is_fence_i                    (dl_is_fence_i),
        .may_flush                     (dl_may_flush),
        .is_atomic                     (dl_is_atomic),
        // writeback event batch of the four lanes, aggregated by glue#2
        .Result_valid                  (exec_valid),
        .tag_out                       (exec_tag),
        .mispredict_flag               (lane_mispredict_flag),
        .mispredict_target_pc          (lane_mispredict_target_pc),
        .exception_flag                (lane_exception_flag),
        .exception_cause               (lane_exception_cause),
        .exception_tval                (lane_exception_tval),
        .is_mret                       (lane_is_mret),
        .is_sret                       (lane_is_sret),
        .fpu_fflags                    (lane_fpu_fflags),
        .global_flush_late             (global_flush_late),
        .interrupt_pending             (sih_interrupt_pending),
        // The address half of the st_br_resolve read port: the self_tag at the G3 issue boundary,
        // the same net as the one sent to g3_lsu_iface.
        .st_br_resolve_tag             (isq3_self_tag),
        // Valid bit of the read address: whether ISQ_Group3 actually holds
        // an instruction right now. The SCB uses it to tell "store still in ISQ3" from "already in LSU",
        // and thus choose between resolving in place and sending a wakeup pulse. With an empty queue isq3_self_tag is a stale value.
        //
        // **Connected to isq_occupied, not issue_valid.** issue_valid includes
        // operand_ready and is 0 while a store waits for operands -- which is exactly when in-place authorization
        // is needed. Nor is it !isq_free_for_dispatch: that bit includes same-cycle issue,
        // is 0 in the issue cycle, and would kill hole B's same-cycle forwarding.
        .st_br_resolve_tag_valid       (isq3_occupied),
        .commit_valid                  (commit_valid),
        .commit_tag                    (commit_tag),
        .commit_rd_idx                 (commit_rd_idx),
        .commit_rd_is_fp               (commit_rd_is_fp),
        .commit_rd_write_enable        (commit_rd_write_enable),
        .commit_fflags                 (commit_fflags),
        .commit_count                  (commit_count),
        .store_wakeup_valid            (scb_store_wakeup_valid),
        .store_wakeup_tag              (scb_store_wakeup_tag),
        .flush_valid                   (scb_flush_valid),
        .flush_tag                     (scb_flush_tag),
        .recovery_kind                 (scb_recovery_kind),
        .head0_tag                     (scb_head0_tag),
        .head1_tag                     (scb_head1_tag),
        .recovery_mispredict_target_pc (scb_recovery_mispredict_target_pc),
        .recovery_exception_cause      (scb_recovery_exception_cause),
        .recovery_exception_tval       (scb_recovery_exception_tval),
        .st_br_resolve                 (scb_st_br_resolve),
        .scoreboard_valid_bits         (scb_scoreboard_valid_bits),
        .scoreboard_exec_done_bits     (scb_scoreboard_exec_done_bits),
        .Buffer_tail                   (scb_Buffer_tail),
        .can_alloc_1                   (scb_can_alloc_1),
        .can_alloc_2                   (scb_can_alloc_2),
        .buffer_empty                  (scb_buffer_empty)
    );

endmodule

`endif // BACKEND_TOP_SV
