`ifndef FP_READ_ADDRESS_MUX_SV
`define FP_READ_ADDRESS_MUX_SV

/* verilator lint_off IMPORTSTAR */
import or_be_types_pkg::*;
/* verilator lint_on IMPORTSTAR */

// FP_read_address_mux -- pure combinational 6 candidate addresses -> 3 FP read
// ports.
//
// (1) per-entry state          : none
// (2) state transition         : none
// (3) condition                : none
// (4) data path                : one 2:1 select per source index k in {1,2,3},
//                                all three driven by a single select bit
// (5) data structure           : none -- no per-entry storage
//
// The two candidate slots offer six possible FP source addresses
// (slot0/1.rs1/2/3_idx) while the FP side has only three read ports.  This
// module does that narrowing; its output drives the read address port of
// **both** FP_ARF and FP_tag_mapping.
//
// No clock and no reset on purpose: (1)(2)(3) are all "none", so the module holds no
// state and is not on any flush broadcast list.
module FP_read_address_mux (
    // in-event: broadcast -- the six candidate addresses from IB, i.e.
    // `slot0/1.rs1/2/3_idx`(5x6); the source number is the port
    // name and the slot is the unpacked index (0 = slot0, 1 = slot1), so the
    // width annotation stays per-port and nothing is packed together.
    input  logic [REG_ADDR_W-1:0] rs1_idx     [ISSUE_WIDTH],
    input  logic [REG_ADDR_W-1:0] rs2_idx     [ISSUE_WIDTH],
    input  logic [REG_ADDR_W-1:0] rs3_idx     [ISSUE_WIDTH],

    // in-event: select -- `is_fp_opcode[0]`(1), slot0's bit and nothing else.
    // Slot1's bit does not participate, so slot1's copy is
    // not a port here: there is no second wire to ignore.
    //
    // **The ungated opcode checker, not decode's `is_fp_instruction`.**
    // For the difference between the two and why the former is required, see
    // the proof below.
    input  logic                  is_fp_opcode,

    // out-event: `fp_read_idx[1:3]`(5x3, read addresses).  Numbered 1..3 to
    // match the source number x; or_be_types_pkg
    // has no constant for this multiplicity, so the range is written out,
    // exactly as FP_ARF declares its matching port.
    output logic [REG_ADDR_W-1:0] fp_read_idx [1:3]
);

    // Unpacked slot index of the six candidate addresses.
    localparam int SLOT0 = 0;
    localparam int SLOT1 = 1;

    // ------------------------------------------------------------------
    // fp_read_idx[k] = is_fp_opcode[0] ? slot0.rs{k}_idx
    //                                        : slot1.rs{k}_idx , k in {1,2,3}
    //
    // One select bit for all three ports, and it is slot0's bit alone.  The
    // port the FP side reads always belongs to the slot this bit picks:
    //
    //   let the accepted slot s have rsX_is_fp[s] = 1.  A legal FP instruction
    //   necessarily has an F/D opcode, so is_fp_opcode[s] = 1.
    //     s = 0 => select bit = 1                          => slot0 chosen  OK
    //     s = 1 => a double-FP dispatch is blocked on the SAME predicate, so
    //              is_fp_opcode[0] = 0 => select bit = 0    => slot1 chosen  OK
    //
    // The two remaining cases produce no consumer at all: select bit 1 with
    // slot0 not accepted means neither slot was accepted (accept[1] => accept[0]),
    // and both bits 0 means no FP source needs resolving this cycle.  So the
    // addresses driven out are either the right ones or unread -- there is no
    // case that would need a per-slot select, and none that would need a fourth
    // read port.
    //
    // ------------------------------------------------------------------
    // **Why is_fp_opcode and not decode's is_fp_instruction**
    // ------------------------------------------------------------------
    // Two reasons, one correctness and one timing, pointing to the same
    // conclusion.
    //
    // (a) Correctness: **the select bit and the double-FP block must be the
    //     same predicate.**
    //     `is_fp_instruction` is gated (illegal / fetch fault ⇒ 0).  If the
    //     block used it while the select bit used the ungated opcode version,
    //     the two would diverge in this gap:
    //         slot0 = an instruction whose opcode is FP but is **illegal**,
    //         slot1 = a real FP instruction.
    //     Then fp0 = 0 (gated), and the double-FP block lets it through; both
    //     dispatch in the same cycle (slot0 takes G0's ILLEGAL route, slot1
    //     takes G2, groups_distinct holds, an illegal instruction is not
    //     serial, with illegal_effective=1 the route is ROUTE_BRU rather than
    //     ROUTE_UNSUPPORTED, so subop_supported_now[0] holds too).  But a
    //     select bit using the opcode version would point at slot0, and
    //     **slot1 could not read its own FP sources**.
    //     Only with is_fp_opcode used in both places, coupling the two, does
    //     the proof above hold.
    //
    // (b) Timing: `is_fp_instruction` has to wait for `subop_raw` and
    //     `d_no_encoding` -- that is the whole decoder.  Using it as the
    //     select bit would put the FP read address behind the full decode.
    //     Whereas the INT / FP read addresses (opnd.rs*) and this module's
    //     select bit (opnd.is_fp_opcode) are all taken directly from the IB
    //     queue-head entry (IB's register storage comes straight out through
    //     the rptr read port, values precomputed by FE's Operand_Extract),
    //     so there is no expander and no decode on the path, and the two
    //     sides line up.
    //
    // Cost: the block becomes conservative; the only extra instructions held
    // back are those "whose opcode looks FP but are about to trap" (fetch
    // fault / illegal encoding / ENABLE_FD=0), and the one behind such an
    // instruction would be flushed anyway.
    // **FS == Off is not in this list** -- that is only known at dispatch
    // time, and the two predicates agree there.
    // ------------------------------------------------------------------
    always_comb begin
        fp_read_idx[1] = is_fp_opcode ? rs1_idx[SLOT0] : rs1_idx[SLOT1];
        fp_read_idx[2] = is_fp_opcode ? rs2_idx[SLOT0] : rs2_idx[SLOT1];
        fp_read_idx[3] = is_fp_opcode ? rs3_idx[SLOT0] : rs3_idx[SLOT1];
    end

endmodule

`endif // FP_READ_ADDRESS_MUX_SV
