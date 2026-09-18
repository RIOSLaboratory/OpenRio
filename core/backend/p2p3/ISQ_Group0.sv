`ifndef ISQ_GROUP0_SV
`define ISQ_GROUP0_SV

/* verilator lint_off IMPORTSTAR */
import or_be_types_pkg::*;
/* verilator lint_on IMPORTSTAR */

// ISQ_Group0 -- ALU0/BRU + CSR + DIV issue queue, one entry
// (ISQ_Group0微架构文档).
//
// (1) per-entry state          : FREE / RESIDENT, carried by `isq_valid`
//                                alone -- one entry, no pointers
// (2) state transition         : dispatch / bypass_capture / issue / flush
// (3) condition                : flush outranks everything; dispatch and
//                                issue may land in the same cycle
// (4) data path                : payload_in -> entry, entry -> issue, plus
//                                the bypass forward that skips the entry
// (5) data structure           : header + payload trimmed to this group's
//                                schema; rs3 and the memory sideband are
//                                dropped at capture
//
// FU_Group is the *in-group* FU index (③): 0 = ALU0/BRU, 1 = CSR, 2 = DIV.
// It is stored verbatim and re-emitted on the issue port so the FU can decode
// itself; this module only uses it to pick FU_ready[FU_Group].
//
// The only group that carries branch prediction: BRU needs pc / pred_taken /
// pred_target_pc to decide mispredict, so those three ride the entry (⑤).
//
// In-group FU multiplicity.  ⑥ writes the ready port as
// `FU_ready[FU_Group]`(1, FU_Group in {0,1,2}), so the count is three.
// or_be_types_pkg has no per-group FU count to reference: FU_GROUP_W is the
// *encoding* width (2) and 1<<FU_GROUP_W would invent a fourth requester, so
// the multiplicity is declared here instead of being added to the frozen
// package.  It has to sit outside the module because the ANSI port header
// uses it as an unpacked dimension.

module ISQ_Group0 (
    input  logic                     clk,
    input  logic                     rst_n,

    // ------------------------------------------------------------------
    // in-event: dispatch (Transaction, one write port).
    // ready = isq_free_for_dispatch, already absorbed upstream, so dispatch_valid is
    // taken as unconditional here.  payload_in carries the whole 486-bit
    // ISQ_Payload; only the ⑤ fields are captured, the rest is dropped.
    // ------------------------------------------------------------------
    input  logic                     dispatch_valid,
    input  isq_payload_t             payload_in,

    // ------------------------------------------------------------------
    // in-event: bypass_capture (announce, 4 lanes).
    // All four lanes are listened to -- bypass is a global broadcast (③).
    // ------------------------------------------------------------------
    input  logic                     bypass_publish_valid   [NUM_LANES],
    input  logic [TAG_W-1:0]         bypass_tag     [NUM_LANES],
    input  logic [XLEN-1:0]          bypass_data    [NUM_LANES],

    // in-event: flush (announce) -- single-wire pulse, no payload
    input  logic                     global_flush_late,

    // in-event: combinational read -- one ready bit per in-group FU
    input  logic                     FU_ready       [G0_NUM_FU],

    // ------------------------------------------------------------------
    // out-event: issue.  Goes out of the library to the selected in-group FU;
    // the delivery semantics and its ready are registered by 集成层 §1.2.
    // ------------------------------------------------------------------
    output logic                     issue_valid,
    output logic [XLEN-1:0]          rs1_data,
    output logic [XLEN-1:0]          rs2_data,
    output logic [FU_GROUP_W-1:0]    FU_Group,
    output logic                     imm_valid,
    output logic [XLEN-1:0]          imm_data,
    output logic [XLEN-1:0]          pc,
    output logic [31:0]              inst_bits,
    output logic                     is_compressed,
    output logic                     pred_taken,
    output logic [XLEN-1:0]          pred_target_pc,
    output logic [TAG_W-1:0]         self_tag,
    output logic [EXE_SUBOP_W-1:0]   exe_subop,
    output logic [FULL_DECODE_W-1:0] full_decode,
    // 取指异常 —— 只有 G0 需要：decode 把取指出错的条目强制路由到 ALU0，
    // 由它在完成拍报异常（FU接入契约 §3）。G1/G2 不可能收到这种条目。
    output logic                     fetch_excp_vld,
    output logic [FETCH_EXCP_CAUSE_W-1:0] fetch_excp_cause,
    output logic [XLEN-1:0]          fetch_excp_tval,

    // Static Info: the free projection, including this cycle's issue
    output logic                     isq_free_for_dispatch
);

    // ------------------------------------------------------------------
    // (5) the entry.
    //
    // state   : isq_valid            0 = FREE, 1 = RESIDENT
    // header  : rsX_ready / rsX_wait_tag / fu_group
    // payload : everything else
    //
    // Deliberately absent, and dropped at capture (⑤ "本组不存的字段"):
    //     rs3_ready / rs3_wait_tag / rs3_data   no three-source instruction
    //     is_store / mem_funct3 / rd_is_fp      LSU-only sideband
    // ------------------------------------------------------------------
    logic                  isq_valid;

    logic                  entry_rs1_ready;
    logic                  entry_rs2_ready;
    logic [TAG_W-1:0]      entry_rs1_wait_tag;
    logic [TAG_W-1:0]      entry_rs2_wait_tag;
    logic [FU_GROUP_W-1:0] entry_fu_group;

    logic [XLEN-1:0]       entry_rs1_data;
    logic [XLEN-1:0]       entry_rs2_data;
    logic                  entry_imm_valid;
    logic [XLEN-1:0]       entry_imm_data;
    logic [XLEN-1:0]       entry_pc;
    logic [31:0]           entry_inst_bits;
    logic                  entry_is_compressed;
    logic                  entry_pred_taken;
    logic [XLEN-1:0]       entry_pred_target_pc;
    logic [TAG_W-1:0]      entry_self_tag;
    // exe_subop is kept as a plain EXE_SUBOP_W vector: this module never
    // decodes it, it only stores and re-emits it, and backend_exe_subop_t
    // lives in the frozen exe_subop_pkg which or_be_types_pkg imports without
    // re-exporting.
    logic [EXE_SUBOP_W-1:0] entry_exe_subop;
    logic                   entry_fetch_excp_vld;
    logic [FETCH_EXCP_CAUSE_W-1:0] entry_fetch_excp_cause;
    logic [XLEN-1:0]        entry_fetch_excp_tval;
    full_decode_t           entry_full_decode;

    // ------------------------------------------------------------------
    // (3) fast_ready_rsX
    //
    //     fast_ready_rsX = !rsX_ready
    //                    & OR over b in {0..3} ( bypass_publish_valid[b]
    //                                          & rsX_wait_tag == bypass_tag[b] )
    //
    // Only the *hit* is computed here.  Which lane's data wins when more than
    // one lane matches is 集成层 §2.5(3)'s lowest-lane rule, and it lives in
    // FU_input_mux with the data mux it belongs to -- an OR has no priority to
    // get wrong, so there is no second copy of that decision here.
    //
    // rsX_wait_tag is only meaningful while the source is still waiting, hence
    // the !rsX_ready guard in front of the compare rather than inside it.
    // ------------------------------------------------------------------
    logic rs1_bypass_hit;
    logic rs2_bypass_hit;
    logic fast_ready_rs1;
    logic fast_ready_rs2;
    logic operand_ready;
    logic issue_request;
    logic fu_ready_sel;
    logic bypass_capture;

    always_comb begin
        rs1_bypass_hit = 1'b0;
        rs2_bypass_hit = 1'b0;
        for (int unsigned b = 0; b < NUM_LANES; b++) begin
            if (bypass_publish_valid[b] && (bypass_tag[b] == entry_rs1_wait_tag)) begin
                rs1_bypass_hit = 1'b1;
            end
            if (bypass_publish_valid[b] && (bypass_tag[b] == entry_rs2_wait_tag)) begin
                rs2_bypass_hit = 1'b1;
            end
        end

        fast_ready_rs1 = !entry_rs1_ready && rs1_bypass_hit;
        fast_ready_rs2 = !entry_rs2_ready && rs2_bypass_hit;

        // rs3 is not part of the AND -- this group has no three-source
        // instruction and never waits on one (③).
        operand_ready  = (entry_rs1_ready || fast_ready_rs1)
                      && (entry_rs2_ready || fast_ready_rs2);

        // ③'s `issue_valid` = isq_valid & operand_ready.  Named
        // issue_request here because the *port* issue_valid is ④#1's
        // registration -- "issue_valid <- ③ 的 issue 判据" -- which is the
        // wider `issue` term, FU_ready and !global_flush_late included.
        issue_request  = isq_valid && operand_ready;
    end

    // ------------------------------------------------------------------
    // (3) FU_ready[FU_Group]
    //
    // A scan rather than a variable index: fu_group is FU_GROUP_W = 2 bit and
    // therefore spans 0..3, while the group only has G0_NUM_FU = 3 FUs.  An
    // out-of-range code selects nothing and issue stalls, which is the safe
    // direction -- indexing the array with it would be out of bounds.
    // ------------------------------------------------------------------
    always_comb begin
        fu_ready_sel = 1'b0;
        for (int unsigned k = 0; k < G0_NUM_FU; k++) begin
            if (entry_fu_group == FU_GROUP_W'(k)) begin
                fu_ready_sel = FU_ready[k];
            end
        end
    end

    // ------------------------------------------------------------------
    // (3) issue / bypass_capture / the free projection
    //
    //     issue          = issue_valid & FU_ready[FU_Group] & !global_flush_late
    //     bypass_capture = isq_valid & !global_flush_late & !issue
    //                    & (fast_ready_rs1 | fast_ready_rs2)
    //     isq_free_for_dispatch = !isq_valid | issue      // same-cycle issue
    //
    // A cycle that issues does not capture: the bypassed value is forwarded to
    // the FU and the entry is leaving anyway (③).
    // ------------------------------------------------------------------
    // ⑥ §issue：`issue_valid` 是**请求线不是 fire 线**——不含 FU_ready。
    // valid 含 ready 即耦合：ready 一掉 valid 就掉，「valid 一经拉高保持稳定
    // 到握手成功」当场被破坏，且 FU_ready 也不得反过来依赖 valid（成环）。
    // entry 的释放是 issue_fire = issue_valid ∧ FU_ready，即 ③ 的 `issue`。
    logic issue_fire;
    assign issue_valid           = issue_request && !global_flush_late;
    assign issue_fire            = issue_valid && fu_ready_sel;
    assign bypass_capture        = isq_valid && !global_flush_late
                                             && !issue_fire
                                             && (fast_ready_rs1 || fast_ready_rs2);
    assign isq_free_for_dispatch = !isq_valid || issue_fire;

    // ------------------------------------------------------------------
    // (4)#1 the two source-data paths.
    //
    //     entry -> issue        rsX_data, only while rsX_ready
    //     bypass -> issue       bypass_data[b], only while
    //                           !rsX_ready & fast_ready_rsX
    //
    // The two rows are mutually exclusive for one rsX and the selection is
    // FU_input_mux's, one instance per source (rs1, rs2 -- this group has no
    // rs3).  The forwarded value bypasses the entry: it reaches the FU on the
    // same cycle without being stored, unless bypass_capture also fires below.
    // ------------------------------------------------------------------
    FU_input_mux u_fu_input_mux_rs1 (
        .entry_rsX_data (entry_rs1_data),
        .bypass_data    (bypass_data),
        .bypass_publish_valid   (bypass_publish_valid),
        .bypass_tag     (bypass_tag),
        .rsX_wait_tag   (entry_rs1_wait_tag),
        .rsX_ready      (entry_rs1_ready),
        .fu_rsX_data    (rs1_data)
    );

    FU_input_mux u_fu_input_mux_rs2 (
        .entry_rsX_data (entry_rs2_data),
        .bypass_data    (bypass_data),
        .bypass_publish_valid   (bypass_publish_valid),
        .bypass_tag     (bypass_tag),
        .rsX_wait_tag   (entry_rs2_wait_tag),
        .rsX_ready      (entry_rs2_ready),
        .fu_rsX_data    (rs2_data)
    );

    // ------------------------------------------------------------------
    // (4)#1 entry -> issue, everything except the source data.
    //
    // Driven unconditionally from the entry; issue_valid is the only
    // qualifier, and the FU samples the bundle under it.
    // ------------------------------------------------------------------
    assign FU_Group       = entry_fu_group;
    assign imm_valid      = entry_imm_valid;
    assign imm_data       = entry_imm_data;
    assign pc             = entry_pc;
    assign inst_bits      = entry_inst_bits;
    assign is_compressed  = entry_is_compressed;
    assign pred_taken     = entry_pred_taken;
    assign pred_target_pc = entry_pred_target_pc;
    assign self_tag       = entry_self_tag;
    assign exe_subop      = entry_exe_subop;
    assign full_decode    = entry_full_decode;
    assign fetch_excp_vld   = entry_fetch_excp_vld;
    assign fetch_excp_cause = entry_fetch_excp_cause;
    assign fetch_excp_tval  = entry_fetch_excp_tval;

    // ------------------------------------------------------------------
    // (2)/(4)#1 the entry itself.
    //
    // Priority, straight off ③:
    //   flush           highest -- no dispatch, no issue, no capture, valid<-0
    //   dispatch        dispatch_valid captures payload_in and leaves RESIDENT, whether
    //                   or not this cycle also issued (② RESIDENT->RESIDENT)
    //   issue           without a same-cycle dispatch the entry goes FREE
    //   bypass_capture  otherwise, take the woken source(s)
    //
    // dispatch and bypass_capture cannot both be true under the ready contract
    // -- capture needs isq_valid & !issue, which is exactly
    // isq_free_for_dispatch = 0 -- so the order between them is unobservable.
    // dispatch is placed first anyway: if it ever did happen, letting a stale
    // ready bit win over the freshly written payload would corrupt the new
    // entry, while the other way round only loses a wakeup that the tag
    // compare will find again next cycle.
    //
    // A flush leaves the payload registers alone: isq_valid = 0 makes the
    // entry dead, and nothing reads a FREE entry.
    // ------------------------------------------------------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            isq_valid            <= 1'b0;
            entry_rs1_ready      <= 1'b0;
            entry_rs2_ready      <= 1'b0;
            entry_rs1_wait_tag   <= '0;
            entry_rs2_wait_tag   <= '0;
            entry_fu_group       <= '0;
            entry_rs1_data       <= '0;
            entry_rs2_data       <= '0;
            entry_imm_valid      <= 1'b0;
            entry_imm_data       <= '0;
            entry_pc             <= '0;
            entry_inst_bits      <= '0;
            entry_is_compressed  <= 1'b0;
            entry_pred_taken     <= 1'b0;
            entry_pred_target_pc <= '0;
            entry_self_tag       <= '0;
            entry_exe_subop      <= '0;
            entry_full_decode    <= '0;
            entry_fetch_excp_vld   <= 1'b0;
            entry_fetch_excp_cause <= '0;
            entry_fetch_excp_tval  <= '0;
        end else if (global_flush_late) begin
            isq_valid            <= 1'b0;
        end else if (dispatch_valid) begin
            // ⑤'s fields, and only those: rs3_* and the memory sideband on
            // payload_in are dropped here.
            isq_valid            <= 1'b1;
            entry_rs1_ready      <= payload_in.rs1_ready;
            entry_rs2_ready      <= payload_in.rs2_ready;
            entry_rs1_wait_tag   <= payload_in.rs1_wait_tag;
            entry_rs2_wait_tag   <= payload_in.rs2_wait_tag;
            entry_fu_group       <= payload_in.fu_group;
            entry_rs1_data       <= payload_in.rs1_data;
            entry_rs2_data       <= payload_in.rs2_data;
            entry_imm_valid      <= payload_in.imm_valid;
            entry_imm_data       <= payload_in.imm_data;
            entry_pc             <= payload_in.pc;
            entry_inst_bits      <= payload_in.inst_bits;
            entry_is_compressed  <= payload_in.is_compressed;
            entry_pred_taken     <= payload_in.pred_taken;
            entry_pred_target_pc <= payload_in.pred_target_pc;
            entry_self_tag       <= payload_in.self_tag;
            entry_exe_subop      <= payload_in.exe_subop;
            entry_full_decode    <= payload_in.full_decode;
            entry_fetch_excp_vld   <= payload_in.fetch_excp_vld;
            entry_fetch_excp_cause <= payload_in.fetch_excp_cause;
            entry_fetch_excp_tval  <= payload_in.fetch_excp_tval;
        end else if (issue_fire) begin
            isq_valid            <= 1'b0;
        end else if (bypass_capture) begin
            // Only rsX_ready and rsX_data move.  rsX_wait_tag is left as it
            // is (④): rewriting it would make the source match a fresh tag
            // again next cycle.  rsX_data comes off the FU_input_mux output,
            // which under !rsX_ready & hit is exactly the winning
            // bypass_data[b] -- no second lane select is built here.
            if (fast_ready_rs1) begin
                entry_rs1_ready  <= 1'b1;
                entry_rs1_data   <= rs1_data;
            end
            if (fast_ready_rs2) begin
                entry_rs2_ready  <= 1'b1;
                entry_rs2_data   <= rs2_data;
            end
        end
    end

endmodule

`endif // ISQ_GROUP0_SV
