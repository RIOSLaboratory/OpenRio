`ifndef FE_BE_PROTOCOL_PKG_SV
`define FE_BE_PROTOCOL_PKG_SV

// Frozen FE <-> BE boundary schema.
//
// **Why a separate package.** If the payload types lived in a TB-side package while `backend_top`
// had flat ports, a wrapper in between would have to copy field by field in a hand-written always_comb; if one field
// were missed (e.g. a fetch-exception field), FE would drive it as usual, BE would never receive it, and neither compile nor sim would complain.
// With one struct crossing the boundary, a missing field is a compile error. The LSU edge is the same
// (`be_lsu_issue_pld_t` comes from or_be_lsu_protocol_pkg); this package applies the same discipline on the FE edge.
//
// **Dependency direction**: exe_subop_pkg / or_be_lsu_protocol_pkg -> or_be_types_pkg -> this package.
// This package only **assembles**; it creates no new width or encoding: `xlen_t` / `ISSUE_WIDTH` /
// `FETCH_EXCP_CAUSE_W` / `recovery_kind_e` all come from or_be_types_pkg,
// and not a single number is restated.

package fe_be_protocol_pkg;

    import or_be_types_pkg::*;

    // Same as the other two frozen packages: change the encoding -> bump the version number, and all three decoders migrate together.
    localparam int FE_BE_SPEC_VERSION = 1;

    // FE's lane count **is** the dispatch width, not a second 2.
    localparam int FE_BE_LANES = ISSUE_WIDTH;

    // ---------------------------------------------------------------------
    // FE -> BE instruction payload
    // ---------------------------------------------------------------------
    // Frozen semantics (all three parties must agree; any mismatch raises no error, it just computes wrong):
    //
    //   * **`inst_bits` is RAW.** For a compressed instruction `inst_bits[15:0]` holds the original halfword, the upper 16 bits are 0,
    //     `is_compressed = 1`. This determines an illegal instruction's tval: the compressed form writes only the low 16 bits into mtval.
    //
    //   * **RVC expansion and operand extraction are done in FE.**
    //     `inst_expanded` is the expanded 32-bit word (equal to inst_bits when not compressed), `rvc_ill` means the compressed
    //     encoding is illegal, `opnd` is the product of Operand_Extract (not gated). There is no RVC expander inside BE.
    //
    //   * **When `fetch_excp_vld = 1`, `inst_bits` is meaningless.** "No encoding was read" and
    //     "the encoding read is illegal" are two different things; FE may fill any placeholder value, decode forces
    //     this one onto the ILLEGAL route, and the ALU reports the **fetch** cause instead of cause 2.
    //
    //   * **`fetch_excp_tval` is the address of the faulting halfword, not necessarily equal to `pc`.** When only the second
    //     halfword of a 4-byte instruction cannot be fetched, the spec requires pc into mepc and pc+2 into mtval, so this value
    //     must be carried by FE; BE cannot derive it from pc.
    //
    //   * **`fetch_excp_cause` is a RISC-V standard synchronous exception code**; for the legal set see
    //     `fe_be_fetch_cause_legal()`. BE zero-extends it into mcause without rewriting it.
    typedef struct packed {
        xlen_t       pc;
        logic [31:0] inst_bits;
        logic        is_compressed;
        logic [31:0]      inst_expanded;
        logic             rvc_ill;
        ib_operand_info_t opnd;
        logic        pred_taken;
        xlen_t       pred_target_pc;
        logic                          fetch_excp_vld;
        logic [FETCH_EXCP_CAUSE_W-1:0] fetch_excp_cause;
        xlen_t                         fetch_excp_tval;
    } fe_be_instr_pld_t;

    localparam int FE_BE_INSTR_PLD_W = $bits(fe_be_instr_pld_t);

    // The only legal cause set on the fetch side.
    //
    // The frontend can only report "cannot fetch this PC"; these three are the only codes it can name:
    //   0   instruction address misaligned -- under ENABLE_C IALIGN = 2, architecturally unreachable.
    //       It is listed here not for today, but so that "it becomes reachable once C is turned off" is on record.
    //   1   instruction access fault
    //   12  instruction page fault
    //
    // Any other number means **the producer has gone wrong**; it is not a code that may be written into mcause.
    // Without this checker, a direct truncating pass-through like `cause = trap_type[4:0]` checks neither the set
    // nor truncation (trap_type is 64 bits; a value >=32 silently becomes a different code).
    function automatic logic fe_be_fetch_cause_legal(
        input logic [FETCH_EXCP_CAUSE_W-1:0] cause
    );
        return (cause == FETCH_EXCP_CAUSE_W'(0))
            || (cause == FETCH_EXCP_CAUSE_W'(1))
            || (cause == FETCH_EXCP_CAUSE_W'(12));
    endfunction

    // ---------------------------------------------------------------------
    // BE -> FE redirect payload
    // ---------------------------------------------------------------------
    // `kind` **is `recovery_kind_e` directly, not projected to a bool.**
    //
    // If projected to the two bits {interrupt_valid, trap_valid}, MISPREDICT / MRET / SRET /
    // FENCE_I would all land on "neither bit set", and the frontend could not tell a FENCE.I refetch from an ordinary control-flow
    // redirect -- and the two place different requirements on the icache.
    //
    // icache invalidation **does not get a separate field**: it is just `kind == RECOVERY_FENCE_I`
    // (that is exactly how flush_model produces `frontend_icache_invalidate`).
    // The contract keeps only one source for any one thing; with two fields, there will come a day they disagree.
    typedef struct packed {
        xlen_t          redirect_pc;
        recovery_kind_e kind;
    } be_fe_redirect_pld_t;

    localparam int FE_BE_REDIRECT_PLD_W = $bits(be_fe_redirect_pld_t);

    function automatic logic fe_be_redirect_invalidates_icache(
        input be_fe_redirect_pld_t pld
    );
        return (pld.kind == RECOVERY_FENCE_I);
    endfunction

    // ---------------------------------------------------------------------
    // Handshake semantics (this package can only freeze them in comments; the signals live on the fe_if / backend_top ports)
    // ---------------------------------------------------------------------
    //   * **Plain per-lane valid/ready, transferred at posedge.** Whether an offer is
    //     consumed is exactly this cycle's `fe_valid[l] && fe_ready[l]`; IB's `accepted_slot`
    //     is this AND itself (derived from `fe_ready`, not a second checker), so the boundary
    //     has **no** accept wire.
    //
    //   * `fe_ready` is combinational. **FE must sample at posedge**: the stable value before the edge is
    //     the decision the DUT actually uses at that edge. Reading the combinational admission line at negedge gives
    //     the next posedge's decision; retiring offers by it would drop an instruction or repeat one. Sampling at posedge
    //     has no such ambiguity, so the boundary does not need a registered accept either.
    //
    //   * admission is a **prefix**: the only legal `accepted_slot` values are 00 / 01 / 11;
    //     **10 cannot occur**. Both corollaries must be obeyed:
    //       - FE packs valid offers into the low lanes; `valid[1]` implies `valid[0]`;
    //       - `fe_ready[1]` **includes** `fe_valid[0]` (IB), so that
    //         `accepted_slot == fe_valid & fe_ready` is an identity.
    //     fe_if asserts both prefix properties in place.
    //
    //   * In a flush cycle `fe_ready` and `accepted_slot` are both always 00 (the
    //     `!global_flush_late` term of IB), and the whole group of offers is discarded.

endpackage

`endif // FE_BE_PROTOCOL_PKG_SV
