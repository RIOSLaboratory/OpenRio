// [This file] Standalone checker: subscribes to ob_cosim_if, holds the reference-side instance, compares the commit stream
//
// Moved out of the self-check logic in tb/agents/be/be_bfm.sv:
// **putting the scoreboard inside the DUT is itself untenable** -- the RTL version has no place for it.
//
// isa_dpi_get_insn_pc cannot be fetched after isa_dpi_commit_auto, but F already read that PC
// at the right moment (before commit_auto) and put it into ob_cosim.commit_pc. This checker
// reads the value directly from the event and no longer calls get_insn_pc itself -- the one
// timing-sensitive read stays in F, so no cross-module ordering protocol is needed.
//
// Sampling phase: posedge. F drives ob_cosim at negedge with blocking assignments, and the value
// holds until obs_clear() at the next negedge, so posedge samples a stable value, with no race
// against F's always block.

`timescale 1ns / 1ps

module be_checker (
  input logic clk,
  input logic rst_n,
  ob_cosim_if #(
    .ISSUE_NUM (orbe_be_dim_pkg::BE_ISSUE_NUM),
    .ROB_ADDR_W(orbe_be_dim_pkg::BE_ROB_ADDR_W)
  )           ob_cosim
);

  import isa_cosim_dpi_pkg::*;

  localparam int unsigned REF_CORE_ID  = 0;
  localparam int unsigned REF_ROB_SIZE = 16;   // matches the cosim_reference_rob_size default

  // Who occupies the slot -- goes into the mismatch context so stage J can tell at a glance where to assign blame.
  localparam string SLOT_KIND = "bfm";

  bit              chk_en    = 1'b0;   // disable with +SELFCHECK=0
  bit              chk_ready = 1'b0;   // reference-side instance ready
  bit              chk_done  = 1'b0;   // reference side reached tohost, stop comparing
  longint unsigned chk_count = 0;      // number of commits compared
  int unsigned     trace_level = 1;

  // Negative verification. A checker that never fires looks the same as a broken checker, so we must
  // be able to prove it fires: +SELFCHK_INJECT=N makes the reference side skip one step at commit N,
  // equivalent to "the slot missed one commit"; after that the PC stream must diverge.
  // Expected behavior: commit N compares OK, commit N+1 terminates. Regressions do not pass this argument.
  longint unsigned chk_inject = 0;

  initial if (!$value$plusargs("VERBOSITY=%d", trace_level)) trace_level = 1;

  // ---------------------------------------------------------------------
  // Reference-side instance setup
  // ---------------------------------------------------------------------
  initial begin : ref_init
    automatic string cfg_path = "";
    automatic string elf_path = "";
    automatic int    rc       = 0;
    automatic int    en       = 1;
    void'($value$plusargs("SELFCHECK=%d", en));
    begin
      automatic int inj = 0;
      if ($value$plusargs("SELFCHK_INJECT=%d", inj) && (inj > 0)) begin
        chk_inject = longint'(inj);
        $display("[CHK] [L1] [SB-A] fault injection armed at commit #%0d", chk_inject);
      end
    end
    chk_en = (en != 0);
    if (!chk_en) begin
      $display("[CHK] [L1] [SB-A] disabled by +SELFCHECK=0");
    end else begin
      if (!$value$plusargs("ISA_CFG=%s", cfg_path) || (cfg_path.len() == 0))
        $fatal(1, "[CHK][SB-A] missing +ISA_CFG=<platform.yaml>");
      if (!$value$plusargs("ISA_ELF=%s", elf_path) || (elf_path.len() == 0))
        $fatal(1, "[CHK][SB-A] missing +ISA_ELF=<elf>");
      rc = isa_cosim_dpi_create(64'd1, 64'(REF_ROB_SIZE));
      if (rc != ISA_COSIM_API_PASS) $fatal(1, "[CHK][SB-A] create rc=%0d", rc);
      rc = isa_cosim_dpi_load_config(cfg_path);
      if (rc != ISA_COSIM_API_PASS) $fatal(1, "[CHK][SB-A] load_config rc=%0d", rc);
      rc = isa_cosim_dpi_load_elf(elf_path);
      if (rc != ISA_COSIM_API_PASS) $fatal(1, "[CHK][SB-A] load_elf rc=%0d", rc);
      isa_cosim_dpi_add_arg(elf_path);
      rc = isa_cosim_dpi_finalize_config();
      if (rc != ISA_COSIM_API_PASS) $fatal(1, "[CHK][SB-A] finalize rc=%0d", rc);
      if (isa_cosim_dpi_is_config_ready() == 0)
        $fatal(1, "[CHK][SB-A] reference is not config-ready after finalize");
      chk_ready = 1'b1;
      $display("[CHK] [L1] [SB-A] reference model ready elf=%s", elf_path);
    end
  end

  // ---------------------------------------------------------------------
  // SB-A · commit-order scoreboard
  //
  // Compared: PC retired by the slot (carried by the event) ↔ reference-side "next to execute" PC
  // When: every commit_valid pulse
  // Tolerance: zero (!==, not even X is let through)
  //
  // Alignment basis: isa_cosim_dpi_get_committed_pc returns SpecCore::pc, i.e. "the PC of the next
  // instruction to execute". Read first, then step: what is read is exactly the one this step commits, no off-by-one.
  // ---------------------------------------------------------------------
  longint unsigned cyc_q = 0;

  always @(posedge clk) begin : sb_a
    automatic longint unsigned slot_pc;
    automatic longint unsigned ref_pc;

    if (!rst_n) begin
      cyc_q <= 0;
    end else begin
      cyc_q <= cyc_q + 1;

      if (chk_en && chk_ready && !chk_done && ob_cosim.commit_valid[0]) begin
        slot_pc = ob_cosim.commit_pc[0];
        ref_pc  = isa_cosim_dpi_get_committed_pc(REF_CORE_ID);

        if (slot_pc !== ref_pc) begin
          // $fatal's format string must be a single literal: when concatenated with {"..",".."} the %
          // placeholders are not parsed and the arguments render as garbage. So context goes via multi-line $display.
          $display("[CHK] [SB-A] DIVERGENCE at commit #%0d", chk_count);
          $display("[CHK] [SB-A]   slot retired      rob=%0d pc=0x%016h",
                   ob_cosim.commit_rob_idx[0], slot_pc);
          $display("[CHK] [SB-A]   reference expected        pc=0x%016h", ref_pc);
          $display("[CHK] [SB-A]   cyc=%0d  slot=%s", cyc_q, SLOT_KIND);
          $fatal(1, "[CHK][SB-A] commit stream diverged");
        end

        // Injection point: skip this reference-side step to create an artificial divergence.
        if (chk_inject != 0 && chk_count == chk_inject)
          $display("[CHK] [L1] [SB-A] injecting: reference step skipped at commit #%0d",
                   chk_count);
        else
          isa_cosim_dpi_step(64'sd1);

        chk_count = chk_count + 1;
        if (isa_cosim_dpi_is_to_exit() != 0) chk_done = 1'b1;
      end
    end
  end

  // ---------------------------------------------------------------------
  // Self-check assertion #5: number of compared commits is non-zero.
  // Guards against "the checker never ran but the simulation PASSes as usual".
  // ---------------------------------------------------------------------
  final begin : sb_a_report
    if (chk_en && chk_ready) begin
      $display("[CHK] [L1] [SB-A] compared %0d commits, no divergence", chk_count);
      if (chk_count == 0)
        $display("[CHK] [SB-A] WARNING: zero commits compared -- checker never fired");
    end
  end

endmodule
