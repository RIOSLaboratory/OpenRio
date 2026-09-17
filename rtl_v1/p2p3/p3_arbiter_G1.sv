`ifndef P3_ARBITER_G1_SV
`define P3_ARBITER_G1_SV

/* verilator lint_off IMPORTSTAR */
import or_be_types_pkg::*;
/* verilator lint_on IMPORTSTAR */

// p3_arbiter_G1 -- G1 in-group completion arbitration and bypass broadcast,
// 2 requesters (p3_arbiter_G1微架构文档).
//
// (1) per-entry state          : none (doc ①)
// (2) state transition         : none (doc ②)
// (3) condition                : none (doc ③)
// (4) data path                : winner_select by static in-group priority
//                                ALU1(0) > MUL(1); the winner's whole
//                                completion_common forwarded to lane 1;
//                                bypass_publish gated by the winner's
//                                exception_flag; winner_grant / loser_hold
//                                returned to the two FUs
// (5) data structure           : none -- no per-entry storage
//
// Purely combinational, so no clk and no rst_n: the module holds nothing
// between cycles and is on no flush broadcast list.  Doc ④ is explicit that
// neither Result_valid nor bypass_valid carries a flush guard -- each consumer
// hangs its own -- and that `winner_ack[k] = winner_grant[k] & !global_flush_late`
// is formed *inside each FU* from the FU's direct flush pulse.  ⑥ therefore
// registers no flush input here and none is declared; adding one would move an
// obligation that doc ④ places on the FUs into this module.
//
// Zero fields are NOT synthesised here.  集成层 §1.2 「恒零字段由 FU 驱动、
// 仲裁器不补造」: G1's ALU1 / MUL drive exception / mispredict / is_mret /
// fpu_fflags to zero themselves, and this module only selects one requester and
// forwards it verbatim -- it neither stores nor manufactures those fields.  The
// same reason keeps csr_sideband out: CSR is statically routed to G0, so this
// group does not carry is_csr / csr_write_enable / csr_addr / csr_wdata and must
// not fake them (doc ④#2).
//
// Naming follows 集成层 §2.5(5) as ⑥ already spells it out: the candidate side
// carries the `req_` prefix and the winner side keeps the bare names, which are
// the verbatim writeback input names of CompletionScoreboard ⑥ (Result_valid,
// tag_out, mispredict_flag, mispredict_target_pc, exception_flag,
// exception_cause, exception_tval, is_mret, fpu_fflags) and of Buffer
// (Result_valid, tag_out, result_data).  The exec_done out-event of ⑥ is
// `tag_out` + `Result_valid` -- the same two wires as writeback, not a second
// pair of ports.
module p3_arbiter_G1 (
    // ------------------------------------------------------------------
    // in-event: completion request (Transaction, many-to-one mux;
    // ready = winner_grant[k], the loser must hold and retry).
    // broadcast -- request[k]'s complete completion_common input fields.
    // ------------------------------------------------------------------
    input  logic [TAG_W-1:0]        req_tag                  [G1_NUM_FU],
    input  logic [XLEN-1:0]         req_result_data          [G1_NUM_FU],
    input  logic                    req_exception_flag       [G1_NUM_FU],
    input  logic [EXCP_CAUSE_W-1:0] req_exception_cause      [G1_NUM_FU],
    input  logic [XLEN-1:0]         req_exception_tval       [G1_NUM_FU],
    input  logic                    req_mispredict_flag      [G1_NUM_FU],
    input  logic [XLEN-1:0]         req_mispredict_target_pc [G1_NUM_FU],
    input  logic                    req_is_mret              [G1_NUM_FU],
    input  logic                    req_is_sret              [G1_NUM_FU],
    input  logic [FFLAGS_W-1:0]     req_fpu_fflags           [G1_NUM_FU],

    // trigger -- does this requester compete this cycle
    input  logic                    request_valid            [G1_NUM_FU],

    // ------------------------------------------------------------------
    // out-event: writeback -- completion_common (no csr_sideband, doc ④).
    // These same two wires are also the exec_done out-event.
    // ------------------------------------------------------------------
    output logic                    Result_valid,
    output logic [TAG_W-1:0]        tag_out,
    output logic [XLEN-1:0]         result_data,
    output logic                    exception_flag,
    output logic [EXCP_CAUSE_W-1:0] exception_cause,
    output logic [XLEN-1:0]         exception_tval,
    output logic                    mispredict_flag,
    output logic [XLEN-1:0]         mispredict_target_pc,
    output logic                    is_mret,
    output logic                    is_sret,
    output logic [FFLAGS_W-1:0]     fpu_fflags,

    // ------------------------------------------------------------------
    // out-event: bypass_publish
    // ------------------------------------------------------------------
    output logic                    bypass_valid,
    output logic [TAG_W-1:0]        bypass_tag,
    output logic [XLEN-1:0]         bypass_data,

    // ------------------------------------------------------------------
    // out-event: winner_select
    // ------------------------------------------------------------------
    output logic                    winner_grant             [G1_NUM_FU],

    // ------------------------------------------------------------------
    // out: combinational read -- loser_hold
    // ------------------------------------------------------------------
    output logic                    loser_hold               [G1_NUM_FU]
);

    logic                    winner_valid;
    // Width of the internal winner index.  Kept in the module body rather
    // than the parameter port: it is derived, not configurable.
    localparam int WINNER_IDX_W = $clog2(G1_NUM_FU);
    logic [WINNER_IDX_W-1:0] winner_idx;

    // ------------------------------------------------------------------
    // (4)#1 winner_select -- static in-group priority ALU1 (0) > MUL (1)
    //
    //     winner_valid = OR over k (request_valid[k])
    //     winner_idx   = winner_valid ? highest-priority valid requester : 0
    //
    // Lowest index is highest priority, so the scan runs from the last
    // requester down to requester 0 and every later (higher-priority) hit
    // overwrites the earlier one; requester 0 therefore has the final say.
    // There is no anti-starvation term and none is invented here: doc ④ states
    // that in-order retirement alone is what eventually frees the loser (the
    // loser blocks in-order retire -> the retire window fills -> the
    // high-priority FU runs out of new valid instructions -> the loser wins).
    // ------------------------------------------------------------------
    always_comb begin
        winner_valid = 1'b0;
        winner_idx   = '0;
        for (int k = G1_NUM_FU - 1; k >= 0; k--) begin
            if (request_valid[k]) begin
                winner_valid = 1'b1;
                winner_idx   = WINNER_IDX_W'(k);
            end
        end
    end

    // ------------------------------------------------------------------
    // (4)#1 winner_grant / loser_hold
    //
    //     winner_grant[k] = winner_valid & (winner_idx == k)
    //     loser_hold[k]   = request_valid[k] & !winner_grant[k]
    //
    // loser_hold is a combinational level, not a one-cycle pulse: it stays
    // high for as many cycles as the request keeps losing.  Freezing the whole
    // completion request and retrying next cycle -- and, for the pipelined MUL,
    // letting that back-pressure reach its input accept so no result is
    // overwritten or dropped -- is the FU's obligation; this module only
    // signals it (doc ④#1).
    // ------------------------------------------------------------------
    always_comb begin
        for (int k = 0; k < G1_NUM_FU; k++) begin
            winner_grant[k] = winner_valid && (winner_idx == WINNER_IDX_W'(k));
            loser_hold[k]   = request_valid[k] && !winner_grant[k];
        end
    end

    // ------------------------------------------------------------------
    // (4)#2 completion_common forward + bypass_publish
    //
    // Every field is the winner's own, gated by winner_valid; when
    // winner_valid = 0 the outputs are invalid placeholders and doc ④ lets the
    // implementation drive them to 0.  The loser never enters this data path:
    // its result stays in FU-local hold state.
    //
    //     bypass_valid = winner_valid & !request[winner_idx].exception_flag
    //
    // The !exception_flag term is not optional even though G1 cannot raise an
    // exception and drives the bit to 0: a faulting instruction's result_data
    // is garbage while its tag is real, so an ISQ entry waiting on that tag
    // would latch the garbage and mark itself ready.  The contract is one and
    // the same for all four lanes and is written here so the directly-connected
    // G2 / G3 lanes drive it identically (doc ④#1).  Note bypass_tag /
    // bypass_data are qualified by winner_valid, not by bypass_valid -- doc
    // ④#2 verbatim.
    // ------------------------------------------------------------------
    always_comb begin
        Result_valid         = winner_valid;
        tag_out              = winner_valid ? req_tag[winner_idx]                  : '0;
        result_data          = winner_valid ? req_result_data[winner_idx]          : '0;

        exception_flag       = winner_valid ? req_exception_flag[winner_idx]       : '0;
        exception_cause      = winner_valid ? req_exception_cause[winner_idx]      : '0;
        exception_tval       = winner_valid ? req_exception_tval[winner_idx]       : '0;
        mispredict_flag      = winner_valid ? req_mispredict_flag[winner_idx]      : '0;
        mispredict_target_pc = winner_valid ? req_mispredict_target_pc[winner_idx] : '0;
        is_mret              = winner_valid ? req_is_mret[winner_idx]              : '0;
        is_sret              = winner_valid ? req_is_sret[winner_idx]              : '0;
        fpu_fflags           = winner_valid ? req_fpu_fflags[winner_idx]           : '0;

        bypass_valid         = winner_valid && !req_exception_flag[winner_idx];
        bypass_tag           = winner_valid ? req_tag[winner_idx]                  : '0;
        bypass_data          = winner_valid ? req_result_data[winner_idx]          : '0;
    end

endmodule

`endif // P3_ARBITER_G1_SV
