`ifndef P1_ISQ_INPUT_MUX_SV
`define P1_ISQ_INPUT_MUX_SV

/* verilator lint_off IMPORTSTAR */
import or_be_types_pkg::*;
/* verilator lint_on IMPORTSTAR */

// p1_ISQ_input_mux -- pure combinational ISQ_Payload two-way select
// (p1_ISQ_input_mux微架构文档).
//
// (1) per-entry state          : none
// (2) state transition         : none
// (3) condition                : none
// (4) data path                : one onehot0 select over two whole payloads,
//                                all-zero when neither slot is selected
// (5) data structure           : none -- no per-entry storage
//
// Instantiated four times, one per ISQ_Group; the four copies are structurally
// identical and the module carries no group number.  Copy g takes dispatch's
// select_payload[g][0/1] and drives ISQ_Group_g.
//
// The two candidate payloads arrive already assembled by 集成层 §2.1 -- this
// module forwards one of them verbatim.  No field is edited and none is
// trimmed: trimming happens on the downstream entry side (each ISQ_Group ⑤).
// The whole 486-bit ISQ_Payload therefore travels as the named isq_payload_t,
// not as loose per-field wires; 集成层 §2.1 owns its schema.
//
// No clock and no reset on purpose: the module is combinational, holds no
// state and is not on any flush broadcast list.
module p1_ISQ_input_mux (
    // in-event: broadcast -- the two fully assembled candidate payloads
    input  isq_payload_t        slot_payload   [ISSUE_WIDTH],

    // in-event: onehot0 select, one bit per candidate slot
    input  logic                select_payload [ISSUE_WIDTH],

    // out-event: the selected ISQ_Payload, all zero when nothing is selected
    output isq_payload_t        ISQ_payload_in
);

    // ------------------------------------------------------------------
    // (4)#1 select_payload -> ISQ_payload_in
    //
    //     ISQ_payload_in = select_payload[0] ? slot_payload[0]
    //                    : select_payload[1] ? slot_payload[1]
    //                    : '0
    //
    // select_payload is onehot0 for this instance: both bits zero means no
    // candidate was accepted for this group this cycle, and the output is all
    // zero.  Both bits set cannot happen -- when the two candidates map to the
    // same group, groups_distinct = 0 keeps slot1 from being accepted and
    // dispatch gates slot1's select bit to 0 -- and the priority order above
    // resolves it to slot0 regardless, so no arbitration state is needed.
    // ------------------------------------------------------------------
    always_comb begin
        if (select_payload[0]) begin
            ISQ_payload_in = slot_payload[0];
        end else if (select_payload[1]) begin
            ISQ_payload_in = slot_payload[1];
        end else begin
            ISQ_payload_in = '0;
        end
    end

endmodule

`endif // P1_ISQ_INPUT_MUX_SV
