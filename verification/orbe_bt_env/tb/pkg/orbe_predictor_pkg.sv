// [This file] predictor: the only implementation in the BE domain that changes shared ISA model state (the LSU domain belongs to cache_agent)
//
// R5: *The shared service instance is advanced by the events of the slot occupant and belongs to the agent side;
// there is exactly one implementation of the advance logic in the whole environment, built by G1 and reused by F;
// the only difference is the event source.*
//
// Form: automatic functions inside a package -- **callable units that return synchronously in the same phase**,
// not standalone processes. All six advance APIs are declared in dpi/isa_dpi_pkg.sv as
// `import "DPI-C" function` (no task), so this form holds.
//
// Why not a standalone process: the occupant's queries and this predictor's advance are interlocked within
// the same FSM condition (see each event's "caller convention" below). As a standalone process, every FSM
// event would need three cross-module handshakes and an extra sub-phase protocol; as a callable unit, the
// order holds naturally within the caller's evaluation phase.
//
// Two event sources, with identical entry points and advance sequences; the only difference is who calls:
//   slot = F BFM    : F calls directly at the corresponding FSM condition
//   slot = RTL      : the observation side calls on events from ob_cosim_if / pins
//
// **Apart from this package, no component in the environment may call these 6 APIs**:
//   isa_dpi_decode_and_issue · isa_dpi_trigger_trap · isa_dpi_execute_insn
//   isa_dpi_commit_auto      · isa_dpi_flush        · isa_dpi_tick_finish
// Queries (isa_dpi_get_* / has_* / is_*) are exempt: read-only, no state change, any component may call them.

package orbe_predictor_pkg;

  import isa_dpi_pkg::*;

  // =====================================================================
  // Event 1 · alloc -- instruction enters the ROB
  //
  // Caller convention: the caller may query isa_dpi_get_decode_metadata only after this event returns.
  // =====================================================================
  function automatic void predictor_alloc(
      input int unsigned     core_id,
      input longint unsigned rob_idx,
      input longint unsigned pc,
      input int unsigned     inst_bits,
      input logic            is_compressed,
      input logic            fetch_excp_vld,
      input longint unsigned exception_cause,
      input longint unsigned exception_tval);

    longint signed insn_id;
    int            rc;

    // is_compressed is passed as-is, not inverted: the model's 5th argument is the Inst constructor's rvc_expanded,
    // is_rvc = insn_is_rvc(encoding) ∨ rvc_expanded, meaning "is inherently a compressed instruction".
    insn_id = isa_dpi_decode_and_issue(core_id, rob_idx, pc, inst_bits,
                                       byte'(is_compressed));
    if (insn_id == ISA_API_INVALID_INSN_ID)
      $fatal(1, "[G1] decode_and_issue refused rob=%0d pc=0x%0h inst=0x%0h compressed=%0b",
             rob_idx, pc, inst_bits, is_compressed);

    // Fetch exceptions must be injected into the model here: FE only delivers it as a payload field, and the
    // model does not record a trap on its own for the placeholder NOP. Without injection commit sees no has_trap,
    // no trap redirect is produced, and FE stops sending because fault_entry_sent is set -- both sides wait, deadlock.
    // The FE contract states explicitly that fetch-exception handling is not in FE; in this path nobody but this predictor injects.
    if (fetch_excp_vld) begin
      rc = isa_dpi_trigger_trap(core_id, rob_idx, exception_cause, exception_tval);
      if (rc != ISA_API_PASS)
        $fatal(1, "[G1] trigger_trap for fetch exception rob=%0d cause=%0d rc=%0d",
               rob_idx, exception_cause, rc);
    end
  endfunction

  // =====================================================================
  // Event 2 · execute -- execution advance for non-memory entries
  //
  // Memory entries do not send this event: they are only queried in the issue cycle; the model advance happens at commit.
  //
  // The return value is handled by the caller:
  //   ISA_API_PASS    execution done, apply this cycle's updates
  //   ISA_API_PENDING not done this cycle, **do not apply** updates, resend for the same rob_idx next cycle
  //   ISA_API_FAIL    the model recorded a trap while executing this entry (e.g. writing a nonexistent CSR raises
  //                   illegal instruction). **Not a constraint violation**; apply updates as usual;
  //                   the trap is reported via get_execute_metadata().trap_valid and handled in the commit
  //                   trap branch. This one is easy to get wrong; if wrong, it shows up on CSR tests as
  //                   an unrelated-looking deadlock.
  //
  // Caller convention: the caller may query get_execute_metadata /
  // is_insn_redirect / get_next_pc_of_insn only after this event returns.
  // =====================================================================
  function automatic int predictor_execute(
      input int unsigned     core_id,
      input longint unsigned rob_idx);
    return isa_dpi_execute_insn(core_id, rob_idx);
  endfunction

  // =====================================================================
  // Event 3 · commit -- commit the head entry
  //
  // The advance sequences of all three branches complete entirely within this event; the caller only hands over redirect_pending.
  //
  // The outputs has_trap / trap_record_valid / trap_cause / trap_tval / spec_pc
  // **are queried by this predictor on the caller's behalf and returned**, not left to the caller. Reasons:
  //   · has_trap must be read **before** isa_dpi_commit_auto;
  //   · the other three must fall in the window after commit_auto and before tick_finish.
  // If left to the caller, it could only query after this event returns, by which time the tick has advanced and
  // spec_pc is not necessarily that cycle's value.
  //
  // Hence a general rule: **any query that must be sampled between two advance calls is issued by the predictor.**
  // Events 1 and 2 have no such query, so their only output is rc.
  // =====================================================================
  function automatic void predictor_commit(
      input  int unsigned     core_id,
      input  longint unsigned rob_idx,
      input  longint unsigned rob_size,          // for wrapping the flush start index
      input  logic            redirect_pending,
      output logic            has_trap,
      output byte unsigned    trap_record_valid,
      output longint unsigned trap_cause,
      output longint unsigned trap_tval,
      output longint unsigned spec_pc);

    int            rc;
    longint unsigned flush_idx;

    trap_record_valid = 8'd0;
    trap_cause        = '0;
    trap_tval         = '0;
    spec_pc           = '0;

    // Must be before commit_auto -- afterwards the record has been consumed.
    has_trap = (isa_dpi_has_trap(core_id, rob_idx) != 0);

    if (has_trap) begin
      // Branch 1: the model recorded a trap for this entry. This branch **does not call** isa_dpi_flush.
      rc = isa_dpi_commit_auto(core_id, rob_idx);
      if (rc != ISA_API_PASS)
        $fatal(1, "[G1] commit_auto rob=%0d returned rc=%0d", rob_idx, rc);
      rc = isa_dpi_get_commit_auto_trap_info(core_id, rob_idx,
                                             trap_record_valid, trap_cause, trap_tval);
      if (rc != ISA_API_PASS)
        $fatal(1, "[G1] get_commit_auto_trap_info rob=%0d returned rc=%0d", rob_idx, rc);
      spec_pc = isa_dpi_get_spec_pc(core_id);
      isa_dpi_tick_finish(8'd1);

    end else if (redirect_pending) begin
      // Branch 2: no trap but a redirect. flush squashes all entries from rob_idx+1 toward the
      // tail of the model ROB, including the start entry itself.
      flush_idx = (rob_idx + 1) % rob_size;
      rc = isa_dpi_flush(core_id, flush_idx);
      if (rc != ISA_API_PASS)
        $fatal(1, "[G1] flush from rob=%0d returned rc=%0d", flush_idx, rc);
      rc = isa_dpi_commit_auto(core_id, rob_idx);
      if (rc != ISA_API_PASS)
        $fatal(1, "[G1] commit_auto rob=%0d returned rc=%0d", rob_idx, rc);
      isa_dpi_tick_finish(8'd1);

    end else begin
      // Branch 3: all other cases.
      rc = isa_dpi_commit_auto(core_id, rob_idx);
      if (rc != ISA_API_PASS)
        $fatal(1, "[G1] commit_auto rob=%0d returned rc=%0d", rob_idx, rc);
      isa_dpi_tick_finish(8'd1);
    end
  endfunction

endpackage
