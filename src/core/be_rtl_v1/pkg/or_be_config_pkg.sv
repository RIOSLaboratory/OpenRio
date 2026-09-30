`ifndef OR_BE_CONFIG_PKG_SV
`define OR_BE_CONFIG_PKG_SV

// OR-BE build configuration.
//
// Separate from or_be_types_pkg on purpose: that package holds the frozen
// *schema* (widths, encodings, payload layouts) which is the same for every
// build.  This one holds the knobs that select *which ISA subset* a given
// build implements, and those must be visible to several modules at once.
//
// The rule these encode:
//
//     One extension's switch drives misa, decode, FE and LSU at once; all four must share one source.
//     While an extension's out-of-library contract is not closed, the corresponding bit must be 0 -- misa reports the ISA
//     the build configuration has **already implemented**, not a switch, and not a roadmap.
//
// Consumers:
//   system_instruction_handler   misa extension bits; IALIGN for mepc
//   decode                       illegal-instruction decode for disabled
//                                extensions (A / C / FD)
//   dispatch_logic / IB          imported for the record only -- gating is
//                                decode's, neither module gates a second time
//
// **Do not** re-declare these as module parameters.  A per-module parameter
// can be overridden at one instantiation and not another, which is exactly the
// "all four must share one source" failure the rule above exists to prevent.
package or_be_config_pkg;

    // A extension -- LR / SC / 22 AMO.  Gates misa.A.
    localparam bit ENABLE_A  = 1'b1;

    // C extension -- compressed instructions.  Gates misa.C **and** IALIGN:
    // with C the architectural instruction alignment is 2 bytes, so mepc keeps
    // bit 0 clear only; without C it is 4 bytes.
    localparam bit ENABLE_C  = 1'b1;

    // F and D are enabled together -- the FP register file, fcsr/frm/fflags and
    // the G2 lane are shared, and there is no build that wants one without the
    // other.  Gates misa.F and misa.D.
    localparam bit ENABLE_FD = 1'b1;

    // Privilege modes.  The backend is **M + S + U** (ENABLE_U = 1 and
    // ENABLE_S = 1).  `current_priv` is a real register, and mstatus.MPP is
    // WARL-clamped to the implemented levels: {M, S, U} with ENABLE_S = 1
    // (reserved 2'b10 clamps to U), {M, U} with ENABLE_S = 0 (writing S clamps
    // to U).  With ENABLE_S = 1 satp / medeleg / mideleg exist and SXL reads 2;
    // see system_instruction_handler.
    // The U-mode *counter shadows* (rdcycle / rdinstret, 0xC00 / 0xC02) are
    // read-only aliases -- riscv-tests read them, no privilege state involved.
    //
    // Why U-mode is needed: riscv-tests' RVTEST_CODE_BEGIN uses `csrwi mstatus,0` + `mret`
    // to run the test body in **U-mode**; the reference ISA model follows, and the model's U-mode **cannot be turned off**
    // (removing u from isa_string has no effect, and isa_dpi.md has no other privilege configuration).
    // With M-mode only, mret stays in M-mode and ecall gives cause 11 while the model gives 8 -- every test
    // is guaranteed to diverge at the end.
    //
    // "Removing u from isa_string has no effect" **holds for `s` as well**:
    // running rv64mi-p-illegal with rv64gcsu and with rv64gc, mstatus reads back bit-identical,
    // SXL is always 2, and MPP=S is still writable.
    // That is, the model's privilege behavior ignores isa_string as a whole, not just the letter u.
    // Even so, `dv/cfg/*.yaml` **must** still list u -- see that config's header comment.
    localparam bit ENABLE_U  = 1'b1;

    // S-mode is bundled with **interrupt delivery**: riscv-tests' S-mode section is driven by
    // "software interrupts delegated to S"; S-mode without interrupts would make rv64mi-p-illegal hang after entering S-mode,
    // instead of exiting at a clean point.
    //
    // When it is turned off, the formulas in each section of system_instruction_handler **degrade one by one to the M+U form**
    // (mideleg always 0 => delegated always 0 => the interrupt checker degrades to mstatus.MIE ∧ |(mie & mip)),
    // the degraded paths are written in place in system_instruction_handler.
    //
    // **BE does not do address translation**: this backend's LSU is outside the library, and virtual-to-physical translation is done on the memory-access side.
    // satp.MODE is WARL; system_instruction_handler accepts {Bare(0), Sv39(8), Sv48(9)},
    // and writing any other MODE leaves the whole satp word unchanged. Whether Sv39/Sv48 are in the intended scope <to be confirmed>
    // (the code accepts these two MODEs; translation is done outside BE).
    localparam bit ENABLE_S  = 1'b1;

endpackage

`endif // OR_BE_CONFIG_PKG_SV
