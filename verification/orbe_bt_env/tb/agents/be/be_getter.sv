// [This file] Value-fetch helper for the predictor: fetches metadata from the shared model at
// three points: decode / execute / commit
//
// This class only queries: it does not change model state and does not drive any interface.
// Results go back to be_agent via output arguments, with a one-line diagnostic per verbosity.
class be_getter;
  localparam int unsigned MODEL_CORE_ID = 0;

  be_config cfg;

  function new(be_config cfg);
    if (cfg == null)
      be_reporter::fatal_static("[GETTER] be_getter requires be_config");
    this.cfg = cfg;
  endfunction

  // ---------------------------------------------------------------------
  // After decode: fetch is_lsu and the decode-time trap. is_lsu is what be_agent uses to
  // route memory instructions.
  // ---------------------------------------------------------------------
  task automatic after_decode(
      input int unsigned lane,
      input logic [BE_ROB_TAG_W-1:0] full_tag,
      input logic [BE_ROB_ADDR_W-1:0] model_rob_idx,
      output bit getter_is_lsu);
    byte unsigned is_lsu;
    byte unsigned trap_valid;
    longint unsigned trap_cause;
    longint unsigned trap_tval;
    int rc;

    if (lane >= BE_ISSUE_NUM)
      cfg.reporter.fatal("[GETTER] decode lane out of range");
    rc = isa_dpi_get_decode_metadata(MODEL_CORE_ID, model_rob_idx,
                                     is_lsu, trap_valid, trap_cause, trap_tval);
    if (rc != ISA_API_PASS)
      cfg.reporter.fatal($sformatf("[GETTER] get_decode_metadata rob=%0d rc=%0d",
                                   model_rob_idx, rc));
    getter_is_lsu = is_lsu != 0;
    if (trap_valid != 0)
      cfg.print_be(2, $sformatf(
          "[GETTER][DECODE_TRAP] group=%0d tag=0x%0h rob=%0d cause=%0d tval=0x%016h rc=%0d",
          lane, full_tag, model_rob_idx, exception_cause_t'(trap_cause[4:0]),
          trap_tval, rc));
    cfg.print_be(3, $sformatf(
        "[GETTER][DECODE] group=%0d tag=0x%0h rob=%0d lsu=%0b trap=%0b rc=%0d",
        lane, full_tag, model_rob_idx, getter_is_lsu, trap_valid != 0, rc));
  endtask

  // ---------------------------------------------------------------------
  // After execute: fetch the execute-time trap and the redirect target. Diagnostic only.
  // ---------------------------------------------------------------------
  task automatic after_execute(
      input logic [BE_ROB_TAG_W-1:0] full_tag,
      input logic [BE_ROB_ADDR_W-1:0] model_rob_idx);
    byte unsigned trap_valid;
    longint unsigned trap_cause;
    longint unsigned trap_tval;
    bit redirect;
    logic [63:0] next_pc;
    int rc;

    rc = isa_dpi_get_execute_metadata(MODEL_CORE_ID, model_rob_idx,
                                      trap_valid, trap_cause, trap_tval);
    if (rc != ISA_API_PASS)
      cfg.reporter.fatal($sformatf("[GETTER] get_execute_metadata rob=%0d rc=%0d",
                                   model_rob_idx, rc));
    redirect = isa_dpi_is_insn_redirect(MODEL_CORE_ID, model_rob_idx) != 0;
    next_pc  = isa_dpi_get_next_pc_of_insn(MODEL_CORE_ID, model_rob_idx);
    if (redirect)
      cfg.print_be(2, $sformatf(
          "[GETTER][REDIRECT] tag=0x%0h rob=%0d next_pc=0x%016h",
          full_tag, model_rob_idx, next_pc));
    if (trap_valid != 0)
      cfg.print_be(2, $sformatf(
          "[GETTER][EXECUTE_TRAP] tag=0x%0h rob=%0d cause=%0d tval=0x%016h rc=%0d",
          full_tag, model_rob_idx, exception_cause_t'(trap_cause[4:0]), trap_tval, rc));
    cfg.print_be(3, $sformatf(
        "[GETTER][EXECUTE] tag=0x%0h rob=%0d redirect=%0b next_pc=0x%016h trap=%0b rc=%0d",
        full_tag, model_rob_idx, redirect, next_pc, trap_valid != 0, rc));
  endtask

  // ---------------------------------------------------------------------
  // After commit_auto: determine whether this instruction finally took a trap. be_agent uses
  // final_trap as a safeguard.
  // ---------------------------------------------------------------------
  task automatic after_commit(
      input logic [BE_ROB_TAG_W-1:0] full_tag,
      input logic [BE_ROB_ADDR_W-1:0] model_rob_idx,
      input bit precommit_trap,
      output bit final_trap);
    byte unsigned trap_record_valid;
    longint unsigned trap_cause;
    longint unsigned trap_tval;
    bit late_trap;
    int rc;

    rc = isa_dpi_get_commit_auto_trap_info(MODEL_CORE_ID, model_rob_idx,
                                           trap_record_valid, trap_cause, trap_tval);
    if (rc != ISA_API_PASS)
      cfg.reporter.fatal($sformatf("[GETTER] get_commit_auto_trap_info rob=%0d rc=%0d",
                                   model_rob_idx, rc));
    final_trap = precommit_trap || (trap_record_valid != 0);
    late_trap  = !precommit_trap && (trap_record_valid != 0);
    if (final_trap)
      cfg.print_be(2, $sformatf(
          "[GETTER][COMMIT_TRAP] tag=0x%0h rob=%0d precommit_trap=%0b trap_record_valid=%0b late_trap=%0b cause=%0d tval=0x%016h redirect_pc=0x%016h rc=%0d",
          full_tag, model_rob_idx, precommit_trap, trap_record_valid != 0, late_trap,
          exception_cause_t'(trap_cause[4:0]), trap_tval,
          isa_dpi_get_spec_pc(MODEL_CORE_ID), rc));
    cfg.print_be(3, $sformatf(
        "[GETTER][COMMIT] tag=0x%0h rob=%0d precommit_trap=%0b trap_record_valid=%0b final_trap=%0b rc=%0d",
        full_tag, model_rob_idx, precommit_trap, trap_record_valid != 0, final_trap, rc));
  endtask
endclass
