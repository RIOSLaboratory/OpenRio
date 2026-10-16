// [This file] Agent on the FE↔BE interface
// FE Agent.
//
// Plays the protocol adapter for the RTL FE in the ORBE BT verification environment:
// fetches from the ISA Model and hands raw instructions to the DUT using the orbe_fe_if
// handshake.
//
// Basic properties (contract preamble):
//   1. Does only two things: calls the ISA Model DPI in a fixed order; maintains the event
//      timing on orbe_fe_if.
//   2. Holds no architectural state; the sole owner of architectural state is the ISA Model.
//   3. Takes no part in decode, execute, commit; does not judge branch direction.
//   4. Events and payload must match the real FE; what is aligned is the event vocabulary
//      and the payload schema.
//   5. This stage does not aim for timing accuracy.
//
// The shared model instance is created by initial_agent (isa_dpi_create), and this Agent is
// responsible for destroying it (isa_dpi_destroy, see exit_sequence). Ownership is split on
// purpose: the time of destruction depends on "the model requests exit", an event only this
// Agent's steady-state loop can observe.
// The entry PC is computed by initial_agent and passed in via the constructor.
//
// Form: class. The contract's Out Static Info is empty; the only combinational constraint is
// `fe_be_instr_valid[lane] must not depend combinationally on be_fe_instr_ready[lane]`
// (Interface Timing item 3) -- naturally satisfied by cursor freezing + posedge driving, so
// no module is needed.

class fe_agent;
  localparam int unsigned MODEL_CORE_ID  = 0;
  localparam int unsigned LANES          = orbe_fe_types_pkg::ORBE_FE_LANES;

  // TRAP_SET: contract FSM item 4. Any other value is an error and terminates.
  localparam longint unsigned TRAP_INSN_ADDR_MISSALIGN = 64'd0;
  localparam longint unsigned TRAP_INSN_ACCESS_FAULT   = 64'd1;
  localparam longint unsigned TRAP_INSN_PAGE_FAULT     = 64'd12;

  // Fetch classification (contract FSM item 4, mode)
  typedef enum int {
    FE_MODE_INSN,
    FE_MODE_EOF,
    FE_MODE_FAULT_PENDING,
    FE_MODE_FAULT_DONE
  } fe_mode_e;

  virtual orbe_fe_if.tb vif;
  be_config             cfg;

  // ---------------------------------------------------------------------
  // Data structure -> State. The outgoing payload is not stored; it is derived
  // combinationally from next_pc every cycle.
  // ---------------------------------------------------------------------
  logic [63:0] next_pc;            // item 1: fetch cursor
  bit          fault_entry_sent;   // item 2

  bit          model_created;
  bit          stop_requested;
  bit          exit_seen;        // [R9-c] the steady-state loop has already printed [FE][EXIT]
  int unsigned ptw_diag_budget;  // [R9-e] print the page-table walk on fetch failure, limited count
  bit          ptw_diag_seen[longint unsigned];   // failing addresses already printed
  bit          exited;

  // initial_pc_ comes from initial_agent's isa_dpi_get_spec_pc. Construction happens after
  // initial_agent.initialize(), so the model instance must already exist at this point.
  function new(virtual orbe_fe_if.tb vif_, be_config cfg_, logic [63:0] initial_pc_);
    vif = vif_;
    cfg = cfg_;
    if (cfg == null)
      be_reporter::fatal_static("[FE] fe_agent requires a non-null be_config");
    next_pc          = initial_pc_;
    fault_entry_sent = 1'b0;
    model_created    = 1'b1;
    stop_requested   = 1'b0;
    exit_seen        = 1'b0;
    ptw_diag_budget  = 8;
    exited           = 1'b0;
  endfunction

  function void fail(string message);
    cfg.reporter.fatal($sformatf("[FE] %s", message));
  endfunction

  task automatic check_rc(input string operation, input int rc);
    if (rc != ISA_API_PASS)
      fail($sformatf("%s returned rc=%0d", operation, rc));
  endtask

  function automatic bit is_supported_fetch_cause(longint unsigned trap);
    return (trap == TRAP_INSN_ADDR_MISSALIGN) ||
           (trap == TRAP_INSN_ACCESS_FAULT)   ||
           (trap == TRAP_INSN_PAGE_FAULT);
  endfunction

  // ---------------------------------------------------------------------
  // fetch: contract FSM item 4. Purely combinational read, no side effects, may be called
  // repeatedly.
  // half(a) = fetch(a).low_half
  // ---------------------------------------------------------------------
  task automatic fetch_half(input  logic [63:0]    addr,
                            output int             rc,
                            output logic [15:0]    half,
                            output longint unsigned trap);
    byte unsigned buf_bytes [0:1];
    trap = '0;
    rc   = isa_dpi_fetch_mem_bank_virt(MODEL_CORE_ID, addr, 2, buf_bytes, trap);
    half = {buf_bytes[1], buf_bytes[0]};
    // Print each distinct failing address only once (repeated retries of the same address
    // would just flood the log), at most 8 addresses in total.
    if ((rc != ISA_API_PASS) && (ptw_diag_budget != 0) && !ptw_diag_seen.exists(addr)) begin
      ptw_diag_budget--;
      ptw_diag_seen[addr] = 1'b1;
      ptw_diag(addr, trap);
    end
  endtask

  // [R9-e] Read-only page-table walk query, once each for U/S; the PTE addresses and values
  // show directly what the page table in shared memory looks like.
  task automatic ptw_diag(input logic [63:0] vaddr, input longint unsigned fetch_trap);
    longint unsigned paddr, pa0, pa1, pa2, pa3, pa4, pv0, pv1, pv2, pv3, pv4, tt, tv;
    byte unsigned upd, lv, tvld, fsrc, mt;
    int rc;
    for (int priv = 0; priv <= 1; priv++) begin
      rc = isa_dpi_translate_pte(MODEL_CORE_ID, vaddr, longint'(priv), ISA_API_MEMOP_FETCH, 64'd2,
                                 paddr, pa0, pa1, pa2, pa3, pa4, pv0, pv1, pv2, pv3, pv4,
                                 upd, lv, tt, tv, tvld, fsrc, mt);
      cfg.print_fe(1, $sformatf(
          "[FE][PTW] fetch fault vaddr=0x%016h fetch_trap=%0d | query priv=%0d rc=%0d paddr=0x%016h levels=%0d trap_valid=%0d trap_type=%0d tval=0x%016h fault_src=%0d",
          vaddr, fetch_trap, priv, rc, paddr, lv, tvld, tt, tv, fsrc));
      cfg.print_fe(1, $sformatf(
          "[FE][PTW]   pte0 @0x%016h=0x%016h  pte1 @0x%016h=0x%016h  pte2 @0x%016h=0x%016h  pte3 @0x%016h=0x%016h  pte4 @0x%016h=0x%016h",
          pa0, pv0, pa1, pv1, pa2, pv2, pa3, pv3, pa4, pv4));
    end
    cfg.print_fe(1, $sformatf("[FE][PTW]   satp=0x%016h", isa_dpi_get_csr(MODEL_CORE_ID, 16'h180)));
  endtask


  // ---------------------------------------------------------------------
  // [FSM-2] exit: stop output and run the wrap-up sequence.
  // ---------------------------------------------------------------------
  task automatic exit_sequence();
    byte unsigned good;
    if (exited) return;
    exited = 1'b1;
    // [R9-c] Entered only from finish_model() -- after the top level joins all agents. The
    // steady-state loop has already printed [FE][EXIT] when it saw exit; only if it has not
    // (e.g. a stop_requested wrap-up) is one added here.
    if (!exit_seen) begin
      good = isa_dpi_is_good();
      cfg.print_fe(1, $sformatf("[FE][EXIT] model requested exit; is_good=%0d", good));
      exit_seen = 1'b1;
    end
    if (model_created) begin
      isa_dpi_destroy();
      model_created = 1'b0;
    end
  endtask

  // ---------------------------------------------------------------------
  // This cycle's fetch classification and combinational payload derivation (contract FSM
  // item 4 + Out-event item 1).
  // ---------------------------------------------------------------------
  task automatic build_offer(output logic [LANES-1:0]              instr_valid,
                             output orbe_fe_types_pkg::orbe_fe_instr_pld_t pld [LANES],
                             output logic [63:0]                   advance,
                             output bit                            fault_pending_now);
    int              rc0, rc1, rch;
    logic [15:0]     half0, half1, halfh;
    longint unsigned trap0, trap1, traph;
    fe_mode_e        mode;
    logic [63:0]     pc0, pc1;
    bit              cmp0, cmp1;
    logic [63:0]     len0, len1;
    bit              lane1_ok;
    // Upper-half fetch failure: the "fault at low_half ? pc : pc+2" branch of excp_tval in
    // contract Out-event item 1.
    bit              hi_fault;
    longint unsigned hi_trap;
    longint unsigned eff_trap;

    instr_valid       = '0;
    advance           = 0;
    fault_pending_now = 1'b0;
    foreach (pld[i]) pld[i] = '0;

    pc0 = next_pc;
    fetch_half(pc0, rc0, half0, trap0);

    // mode classification
    if (rc0 == ISA_API_PASS) begin
      mode = (half0 == 16'h0000) ? FE_MODE_EOF : FE_MODE_INSN;
    end else begin
      if (!is_supported_fetch_cause(trap0))
        fail($sformatf("fetch at pc=0x%016h failed with trap=%0d, which is outside TRAP_SET {0,1,12}",
                       pc0, trap0));
      mode = fault_entry_sent ? FE_MODE_FAULT_DONE : FE_MODE_FAULT_PENDING;
    end

    if (mode == FE_MODE_EOF || mode == FE_MODE_FAULT_DONE) return;

    // ---- lane 0 -------------------------------------------------------
    hi_fault = 1'b0;
    hi_trap  = '0;
    cmp0     = (mode == FE_MODE_FAULT_PENDING) ? 1'b0 : (half0[1:0] != 2'b11);

    if (mode == FE_MODE_INSN && !cmp0) begin
      fetch_half(pc0 + 64'd2, rch, halfh, traph);
      if (rch != ISA_API_PASS) begin
        if (!is_supported_fetch_cause(traph))
          fail($sformatf("fetch of the upper half at pc=0x%016h failed with trap=%0d, which is outside TRAP_SET {0,1,12}",
                         pc0 + 64'd2, traph));
        // Lower half fetched, upper half failed: still a fetch-exception entry, tval = pc+2.
        hi_fault = 1'b1;
        hi_trap  = traph;
        if (fault_entry_sent) return;   // this entry was already delivered; do not repeat
        mode     = FE_MODE_FAULT_PENDING;
        cmp0     = 1'b0;
      end
    end

    pld[0].pc              = pc0;
    if (mode == FE_MODE_FAULT_PENDING) begin
      // is_excp_entry[0] = 1
      pld[0].inst_bits       = 32'h0000_0013;   // NOP placeholder
      pld[0].is_compressed   = 1'b0;
      pld[0].pred_taken      = 1'b0;
      pld[0].pred_target_pc  = pc0;             // is_excp_entry ? pc : pc+len
      pld[0].fetch_excp_vld  = 1'b1;
      eff_trap               = hi_fault ? hi_trap : trap0;
      pld[0].exception_cause = eff_trap[4:0];
      pld[0].exception_tval  = hi_fault ? (pc0 + 64'd2) : pc0;
      instr_valid[0]         = 1'b1;
      fault_pending_now      = 1'b1;
      advance                = 0;               // mode ≠ INSN -> advance = 0
      return;
    end

    len0                   = cmp0 ? 64'd2 : 64'd4;
    pld[0].inst_bits       = cmp0 ? {16'h0000, half0} : {halfh, half0};
    pld[0].is_compressed   = cmp0;
    pld[0].pred_taken      = 1'b0;
    pld[0].pred_target_pc  = pc0 + len0;
    pld[0].fetch_excp_vld  = 1'b0;
    pld[0].exception_cause = '0;
    pld[0].exception_tval  = '0;
    instr_valid[0]         = 1'b1;

    // ---- lane 1 -------------------------------------------------------
    // pc[1] = next_pc + inst_len_0. The contract gives lane 1 no separate mode
    // classification; if lane 1's fetch fails, that lane is not offered this cycle, and once
    // the cursor reaches that address in a later cycle it is classified normally as
    // FAULT_PENDING and delivered -- otherwise a half-word that could not be fetched would be
    // sent out as an instruction.
    pc1      = pc0 + len0;
    lane1_ok = 1'b0;
    fetch_half(pc1, rc1, half1, trap1);
    if (rc1 == ISA_API_PASS && half1 != 16'h0000) begin
      cmp1 = (half1[1:0] != 2'b11);
      if (cmp1) begin
        lane1_ok = 1'b1;
        len1     = 64'd2;
        pld[1].inst_bits = {16'h0000, half1};
      end else begin
        fetch_half(pc1 + 64'd2, rch, halfh, traph);
        if (rch == ISA_API_PASS) begin
          lane1_ok = 1'b1;
          len1     = 64'd4;
          pld[1].inst_bits = {halfh, half1};
        end
      end
    end

    if (lane1_ok) begin
      pld[1].pc              = pc1;
      pld[1].is_compressed   = (len1 == 64'd2);
      pld[1].pred_taken      = 1'b0;
      pld[1].pred_target_pc  = pc1 + len1;
      pld[1].fetch_excp_vld  = 1'b0;
      pld[1].exception_cause = '0;
      pld[1].exception_tval  = '0;
      instr_valid[1]         = 1'b1;
    end
  endtask

  task automatic drive_idle();
    vif.fe_be_instr_valid <= '0;
    foreach (vif.fe_be_instr_pld[i]) vif.fe_be_instr_pld[i] <= '0;
  endtask

  // ---------------------------------------------------------------------
  // run: Interface Timing item 1 -- synchronous state updates on the rising edge,
  // combinational outputs are valid in the current cycle.
  // A payload that has not fired is kept stable by cursor freezing.
  // ---------------------------------------------------------------------
  task run();
    logic [LANES-1:0]   offer_valid;
    orbe_fe_types_pkg::orbe_fe_instr_pld_t offer_pld [LANES];
    logic [63:0]        advance;
    bit                 fault_pending_now;
    logic [LANES-1:0]   fired;
    bit                 redirect_fire;
    logic [63:0]        step;

    drive_idle();

    // [FSM-1] reset. The prerequisite sequence was completed by initial_agent before this
    // Agent was constructed, and the entry PC was passed in via the constructor; here we only
    // wait for reset release.
    wait (vif.rst_n === 1'b1);

    forever begin
      // [FSM-2] exit takes priority over redirect and deliver; deliver = 00 this cycle.
      // [R9-c] Here we only stop fetching and return, and **no longer destroy the model**.
      // Destruction moved to finish_model() -- called only after the top level joins all
      // agents. With real RTL, after the model reports exit be_agent still has to commit the
      // older instructions and the terminal store from the ROB (the store drains early via
      // st_br_resolve, and the model's exit precedes the ROB commit by two cycles);
      // destroying at this point would make each of its DPI calls get rc=-1. The premise of
      // the original comment "the time of destruction depends on the model requesting exit,
      // which only this Agent can observe" no longer holds: be_agent and cache_agent also
      // observe is_to_exit.
      if (isa_dpi_is_to_exit() != 0) begin
        drive_idle();
        if (!exit_seen) begin
          exit_seen = 1'b1;
          cfg.print_fe(1, $sformatf("[FE][EXIT] model requested exit; is_good=%0d",
                                    isa_dpi_is_good()));
        end
        return;
      end

      build_offer(offer_valid, offer_pld, advance, fault_pending_now);

      vif.fe_be_instr_valid <= offer_valid;
      foreach (offer_pld[i]) vif.fe_be_instr_pld[i] <= offer_pld[i];

      @(posedge vif.clk);
      if (stop_requested) begin
        drive_idle();
        return;
      end

      if (vif.rst_n !== 1'b1) begin
        drive_idle();
        wait (vif.rst_n === 1'b1);
        continue;
      end

      // [FSM-3] redirect: mutually exclusive with deliver; the exclusion term is written into
      // deliver's fire.
      redirect_fire = (vif.be_fe_redirect_valid === 1'b1);
      if (redirect_fire) begin
        next_pc          = vif.be_fe_redirect_pld.redirect_pc;
        fault_entry_sent = 1'b0;
        cfg.print_fe(2, $sformatf("[FE][REDIRECT] next_pc=0x%016h trap=%0b int=%0b",
                                  next_pc, vif.be_fe_redirect_pld.trap_valid,
                                  vif.be_fe_redirect_pld.interrupt_valid));
        drive_idle();
        // [R9-g] Trap/interrupt redirect: first wait until the shared model has really taken
        // the trap, then fetch from the target address.
        // Real RTL both redirects FE and reports exception recovery to BE in the same cycle;
        // this Agent fetches immediately at posedge, while be_agent does commit_auto only at
        // negedge to put the model into the trap (switching privilege level). So when stvec
        // is fetched the model is still in U mode, and kernel page translation reports a page
        // fault (rv64ua-v-*: the PTW query for 0xffffffffffe00154 passes in S mode, page
        // faults in U mode).
        // Use the model's spec_pc catching up with the redirect target as the criterion:
        // self-synchronizing, not betting on pipeline timing; bounded.
        if ((vif.be_fe_redirect_pld.trap_valid === 1'b1) ||
            (vif.be_fe_redirect_pld.interrupt_valid === 1'b1)) begin
          int guard;
          // [R9-h] xRET (the top level also maps MRET/SRET to trap_valid): the model's spec_pc
          // is already the redirect target at execute, so the check below holds immediately;
          // but the privilege switch has to wait for be_agent to do commit_auto at negedge. If
          // we fetched this cycle, the model would still be in S mode when fetching a U page,
          // reporting a false page fault (rv64u*-v-*: the third SRET to 0x2a34). Cross one
          // negedge first.
          @(posedge vif.clk);
          guard = 0;
          while ((isa_dpi_get_spec_pc(MODEL_CORE_ID) != next_pc) && (guard < 8)) begin
            @(posedge vif.clk);
            guard++;
          end
          if (guard != 0)
            cfg.print_fe(2, $sformatf(
                "[FE][REDIRECT] waited %0d cycle(s) for the model to take the trap (spec_pc=0x%016h)",
                guard, isa_dpi_get_spec_pc(MODEL_CORE_ID)));
          if (isa_dpi_get_spec_pc(MODEL_CORE_ID) != next_pc)
            cfg.print_fe(1, $sformatf(
                "[FE][REDIRECT] model spec_pc=0x%016h never reached redirect 0x%016h within %0d cycles; fetching anyway",
                isa_dpi_get_spec_pc(MODEL_CORE_ID), next_pc, guard));
        end
        continue;
      end

      // [FSM-4] deliver[lane]
      fired = '0;
      for (int unsigned lane = 0; lane < LANES; lane++)
        fired[lane] = offer_valid[lane] && (vif.be_fe_instr_ready[lane] === 1'b1);

      // Constraint: instr_valid[1] -> instr_valid[0], deliver can only be 00/01/11.
      if (fired[1] && !fired[0])
        fail("deliver vector 10 is illegal; lane 1 may only fire together with lane 0");

      if (fired != '0) begin
        // advance = (mode == INSN) ? Σ fired[lane] * inst_len_lane : 0
        step = 0;
        if (!fault_pending_now) begin
          if (fired[0]) step += offer_pld[0].is_compressed ? 64'd2 : 64'd4;
          if (fired[1]) step += offer_pld[1].is_compressed ? 64'd2 : 64'd4;
        end
        next_pc          = next_pc + step;
        fault_entry_sent = fault_entry_sent || (fault_pending_now && fired[0]);

        cfg.print_fe(3, $sformatf("[FE][DELIVER] fired=%b advance=%0d next_pc=0x%016h",
                                  fired, step, next_pc));
      end
    end
  endtask

  task shutdown();
    stop_requested = 1'b1;
  endtask

  task finish_model();
    exit_sequence();
  endtask
endclass
