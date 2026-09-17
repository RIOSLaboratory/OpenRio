`ifndef P3_ARBITER_G0_SV
`define P3_ARBITER_G0_SV

/* verilator lint_off IMPORTSTAR */
import or_be_types_pkg::*;
/* verilator lint_on IMPORTSTAR */

// p3_arbiter_G0 -- G0 in-group completion arbitration and bypass broadcast,
// 3 requesters (p3_arbiter_G0微架构文档).
//
// (1) per-entry state          : none (doc ①)
// (2) state transition         : none (doc ②)
// (3) condition                : none (doc ③)
// (4) data path                : one static-priority winner select, the
//                                two-layer writeback forward
//                                (completion_common + lane-0 csr_sideband),
//                                the bypass publish gate and the
//                                winner_grant / loser_hold feedback
// (5) data structure           : none -- no per-entry storage (doc ⑤)
//
// No clock and no reset on purpose: the module is purely combinational, holds
// no state, and is NOT on the global_flush_late fan-out list (doc ④#1) -- the
// flush-cycle gating belongs to each consumer, not here.
//
// The arbiter forwards exactly one requester's fields verbatim; it never
// fabricates a constant-zero field for the group (集成层 §1.2「恒零字段由 FU
// 驱动、仲裁器不补造」).  The single exception is `fpu_fflags`, which doc ⑥
// gives no request-side input at all and doc ④#2 fixes at 0 for this group
// (lane 0 is never FP) -- there is nothing to forward, so it is tied off.
//
// Port names follow doc ⑥ verbatim, under 集成层 §2.5(5)'s de-duplication
// rule: the request side (candidates) carries the `req_` prefix, the winner
// side (outputs) keeps the bare names so they line up word for word with the
// already-frozen writeback inputs of CompletionScoreboard ⑥ / Buffer ⑥ and
// with system_instruction_handler's lane-0 capture port.  No name is left
// ambiguous, so no port map file is needed.
//
// G0_NUM_FU is declared here as a non-overridable localparam because
// or_be_types_pkg has no constant for it: the package freezes the cross-stage
// schema, and the per-group FU count appears only in 集成层 §1.2 prose
// (「G0 三位、G1 两位、G2 一位」).  It is NOT a `parameter`: a per-instance
// override would silently change the priority chain's length.
module p3_arbiter_G0 (
    // ------------------------------------------------------------------
    // in-event: completion request (transaction, 3-to-1 mux; ready =
    // winner_grant[k], a loser must hold and retry).  k = 0 ALU0/BRU (one
    // shared requester interface), k = 1 CSR, k = 2 DIV.
    //
    // trigger -- does this requester compete this cycle
    // ------------------------------------------------------------------
    input  logic                     request_valid            [G0_NUM_FU],

    // broadcast -- the candidate fields, doc ⑥ in-event.  completion_common
    // first, then the lane-0-only csr_sideband layer.
    input  logic [TAG_W-1:0]         req_tag                  [G0_NUM_FU],
    input  logic [XLEN-1:0]          req_result_data          [G0_NUM_FU],
    input  logic                     req_mispredict_flag      [G0_NUM_FU],
    input  logic [XLEN-1:0]          req_mispredict_target_pc [G0_NUM_FU],
    input  logic                     req_exception_flag       [G0_NUM_FU],
    input  logic [EXCP_CAUSE_W-1:0]  req_exception_cause      [G0_NUM_FU],
    input  logic [XLEN-1:0]          req_exception_tval       [G0_NUM_FU],
    input  logic                     req_is_mret              [G0_NUM_FU],
    input  logic                     req_is_sret              [G0_NUM_FU],
    input  logic [FFLAGS_W-1:0]      req_fpu_fflags           [G0_NUM_FU],
    input  logic                     req_is_csr               [G0_NUM_FU],
    input  logic                     req_csr_write_enable     [G0_NUM_FU],
    input  logic [CSR_ADDR_W-1:0]   req_csr_addr             [G0_NUM_FU],
    input  logic [XLEN-1:0]          req_csr_wdata            [G0_NUM_FU],

    // ------------------------------------------------------------------
    // out-event: writeback -- both layers driven together (doc ④#2).
    // Layer 1, completion_common: the shape all four lanes drive.
    // ------------------------------------------------------------------
    output logic                     Result_valid,
    output logic [TAG_W-1:0]         tag_out,
    output logic [XLEN-1:0]          result_data,
    output logic                     mispredict_flag,
    output logic [XLEN-1:0]          mispredict_target_pc,
    output logic                     exception_flag,
    // 63 bit: the cause number without the interrupt flag bit.  That bit is
    // set only when the architectural mcause is written, never on this path.
    output logic [EXCP_CAUSE_W-1:0]  exception_cause,
    output logic [XLEN-1:0]          exception_tval,
    output logic                     is_mret,
    output logic                     is_sret,
    output logic [FFLAGS_W-1:0]      fpu_fflags,

    // Layer 2, csr_sideband -- lane 0 only.  Bypasses the SCB entirely and
    // goes straight to system_instruction_handler (集成层 §1.2).
    output logic                     is_csr,
    output logic                     csr_write_enable,
    // 12 bit -- the same field as full_decode_t.csr_addr, whose width is
    // FULL_DECODE_W(17) - csr_write_intent(1) - illegal(1) - rm(3).
    output logic [CSR_ADDR_W-1:0]   csr_addr,
    output logic [XLEN-1:0]          csr_wdata,

    // ------------------------------------------------------------------
    // out-event: bypass_publish -- combinational broadcast, not a registered
    // bus and not a CAM.  The tag compare lives in the consumers.
    // ------------------------------------------------------------------
    output logic                     bypass_valid,
    output logic [TAG_W-1:0]         bypass_tag,
    output logic [XLEN-1:0]          bypass_data,

    // ------------------------------------------------------------------
    // out-event: winner_select -- the per-requester ready
    // ------------------------------------------------------------------
    output logic                     winner_grant             [G0_NUM_FU],

    // ------------------------------------------------------------------
    // out: combinational read -- a level, not a one-cycle pulse; it can stay
    // high for many cycles while the request keeps losing (doc ④#1)
    // ------------------------------------------------------------------
    output logic                     loser_hold               [G0_NUM_FU]
);

    // Index of the winning requester.  Internal only -- doc ⑥ exports the
    // decoded winner_grant, not the encoded index.
    localparam int REQ_IDX_W = $clog2(G0_NUM_FU);

    logic                  winner_valid;
    logic [REQ_IDX_W-1:0]  winner_idx;

    // ------------------------------------------------------------------
    // (4)#1 winner_select -- static in-group priority (doc ④#1)
    //
    //     ALU0/BRU (requester 0)  >  CSR (1)  >  DIV (2)
    //
    //     winner_valid = |request_valid[k]
    //     winner_idx   = winner_valid ? highest-priority valid requester : 0
    //
    // Lowest index wins, so the loop stops at the first valid requester.
    // There is deliberately no anti-starvation: a stuck loser blocks in-order
    // retirement until the retire window fills, at which point the
    // higher-priority FUs run dry and the loser necessarily wins.
    // ------------------------------------------------------------------
    always_comb begin
        winner_valid = 1'b0;
        winner_idx   = '0;
        for (int unsigned k = 0; k < G0_NUM_FU; k++) begin
            if (!winner_valid && request_valid[k]) begin
                winner_valid = 1'b1;
                winner_idx   = REQ_IDX_W'(k);
            end
        end
    end

    // winner_grant[k] = winner_valid & (winner_idx == k)
    always_comb begin
        for (int unsigned k = 0; k < G0_NUM_FU; k++) begin
            winner_grant[k] = winner_valid && (winner_idx == REQ_IDX_W'(k));
        end
    end

    // loser_hold[k] = request_valid[k] & !winner_grant[k].  The loser must
    // freeze its whole completion request and retry next cycle; that hold is
    // the FU's own behaviour and is specified in the FU docs, not here.
    always_comb begin
        for (int unsigned k = 0; k < G0_NUM_FU; k++) begin
            loser_hold[k] = request_valid[k] && !winner_grant[k];
        end
    end

    // ------------------------------------------------------------------
    // (4)#2 writeback -- forward the winner's fields, all zero otherwise
    // (doc ④#2)
    //
    //     Result_valid = winner_valid
    //     tag_out      = winner_valid ? request[winner_idx].tag : 0
    //     其余 writeback 字段 = winner_valid ? 对应字段 : 0
    //
    // winner_grant is onehot0, so it is the select: no requester granted means
    // every field falls through to the zero default.  A loser never enters the
    // winner data path -- its result stays in FU-local hold state.
    // ------------------------------------------------------------------
    always_comb begin
        Result_valid         = winner_valid;

        tag_out              = '0;
        result_data          = '0;
        mispredict_flag      = '0;
        mispredict_target_pc = '0;
        exception_flag       = '0;
        exception_cause      = '0;
        exception_tval       = '0;
        is_mret              = '0;
        is_sret              = '0;
        fpu_fflags           = '0;

        is_csr               = '0;
        csr_write_enable     = '0;
        csr_addr             = '0;
        csr_wdata            = '0;

        for (int unsigned k = 0; k < G0_NUM_FU; k++) begin
            if (winner_grant[k]) begin
                tag_out              = req_tag[k];
                result_data          = req_result_data[k];
                mispredict_flag      = req_mispredict_flag[k];
                mispredict_target_pc = req_mispredict_target_pc[k];
                exception_flag       = req_exception_flag[k];
                exception_cause      = req_exception_cause[k];
                exception_tval       = req_exception_tval[k];
                is_mret              = req_is_mret[k];
                is_sret              = req_is_sret[k];
                fpu_fflags           = req_fpu_fflags[k];

                is_csr               = req_is_csr[k];
                csr_write_enable     = req_csr_write_enable[k];
                csr_addr             = req_csr_addr[k];
                csr_wdata            = req_csr_wdata[k];
            end
        end
    end


    // ------------------------------------------------------------------
    // (4)#1/#2 bypass_publish (doc ④#1, ④#2)
    //
    //     bypass_valid = winner_valid & !request[winner_idx].exception_flag
    //     bypass_tag   = winner_valid ? request[winner_idx].tag         : 0
    //     bypass_data  = winner_valid ? request[winner_idx].result_data : 0
    //
    // tag_out / result_data are already exactly those two selects, so the
    // broadcast is literally the same wire -- and because exception_flag is
    // itself zero when winner_valid is low, Result_valid & !exception_flag is
    // the documented gate term for term.
    //
    // The !exception_flag gate is not optional: a faulting instruction's
    // result_data is garbage while its tag is real, and faulting load / LR /
    // SC / AMO all have use_rd = 1, so an ISQ entry really is waiting on that
    // tag.  There is deliberately no rd_write_enable qualifier and no
    // !global_flush_late qualifier (doc ④#1 states why for both).
    // ------------------------------------------------------------------
    assign bypass_valid = Result_valid && !exception_flag;
    assign bypass_tag   = tag_out;
    assign bypass_data  = result_data;

endmodule

`endif // P3_ARBITER_G0_SV
