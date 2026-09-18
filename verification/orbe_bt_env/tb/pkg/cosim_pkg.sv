class cosim_commit_ticket;
  longint unsigned sequence_id;
  longint unsigned cycle;
  longint unsigned pc;
  longint unsigned rob_idx;
  int unsigned lane;
  longint unsigned ref_pc;
  longint unsigned result;
  longint unsigned ref_result;
  longint unsigned redirect_pc;
  longint unsigned ref_redirect_pc;
  bit redirect_valid;
  bit ref_redirect_valid;
  int unsigned recovery_kind;
  int unsigned ref_recovery_kind;
  int unsigned rd_idx;
  int unsigned ref_rd_idx;
  bit rd_is_fp;
  bit ref_rd_is_fp;
  bit rd_write_enable;
  longint unsigned fflags;
  longint signed mnemonic;

  function new();
    sequence_id = 0;
    cycle = 0;
    lane = 0;
    pc = 0;
    rob_idx = 0;
    ref_pc = 0;
    result = 0;
    ref_result = 0;
    redirect_pc = 0;
    ref_redirect_pc = 0;
    redirect_valid = 0;
    ref_redirect_valid = 0;
    recovery_kind = 0;
    ref_recovery_kind = 0;
    rd_idx = 0;
    ref_rd_idx = 0;
    rd_is_fp = 0;
    ref_rd_is_fp = 0;
    rd_write_enable = 0;
    fflags = 0;
    mnemonic = 0;
  endfunction
endclass

// Reference backend abstraction. A future Spike backend can implement this
// contract without changing the commit-order adapter.
virtual class cosim_reference_backend;
  virtual task initialize(input string cfg_path, input string elf_path);
  endtask

  virtual task step_one(output longint unsigned pc_before);
  endtask

  virtual function bit is_to_exit();
    return 1'b0;
  endfunction

  virtual function bit is_good();
    return 1'b0;
  endfunction

  virtual function longint unsigned get_gpr(input int unsigned index);
    return 0;
  endfunction

  virtual function longint unsigned get_fpr(input int unsigned index);
    return 0;
  endfunction

  virtual function longint unsigned get_csr(input int unsigned csr_addr);
    return 0;
  endfunction

  virtual task shutdown();
  endtask
endclass

class isa_step_cosim_backend extends cosim_reference_backend;
  localparam int unsigned MODEL_CORE_ID = 0;

  be_config cfg;
  bit model_created;

  function new(be_config cfg);
    if (cfg == null)
      be_reporter::fatal_static("[COSIM] isa_step backend requires be_config");
    this.cfg = cfg;
    model_created = 1'b0;
  endfunction

  task automatic check_rc(input string operation, input int rc);
    if (rc != ISA_COSIM_API_PASS)
      cfg.reporter.fatal($sformatf("[COSIM] %s failed rc=%0d", operation, rc));
  endtask

  task initialize(input string cfg_path, input string elf_path);
    int rc;

    if (model_created)
      cfg.reporter.fatal("[COSIM] duplicate reference model initialization");
    rc = isa_cosim_dpi_create(1, cfg.cosim_reference_rob_size);
    check_rc("create", rc);
    model_created = 1'b1;

    rc = isa_cosim_dpi_load_config(cfg_path);
    check_rc("load_config", rc);
    rc = isa_cosim_dpi_load_elf(elf_path);
    check_rc("load_elf", rc);
    isa_cosim_dpi_add_arg(elf_path);
    rc = isa_cosim_dpi_finalize_config();
    check_rc("finalize_config", rc);
    if (isa_cosim_dpi_is_config_ready() == 0)
      cfg.reporter.fatal("[COSIM] reference model is not config-ready after finalize");
    cfg.print_tb(2, $sformatf("[COSIM] isa_step reference initialized elf=%s", elf_path));
  endtask

  task step_one(output longint unsigned pc_before);
    if (!model_created)
      cfg.reporter.fatal("[COSIM] step requested before reference model creation");
    pc_before = isa_cosim_dpi_get_committed_pc(MODEL_CORE_ID);
    isa_cosim_dpi_step(1);
  endtask

  function bit is_to_exit();
    return isa_cosim_dpi_is_to_exit() != 0;
  endfunction

  function bit is_good();
    return isa_cosim_dpi_is_good() != 0;
  endfunction

  function longint unsigned get_gpr(input int unsigned index);
    shortint unsigned api_index;
    api_index = index[15:0];
    return isa_cosim_dpi_get_gpr(MODEL_CORE_ID, api_index);
  endfunction

  function longint unsigned get_fpr(input int unsigned index);
    shortint unsigned api_index;
    api_index = index[15:0];
    return isa_cosim_dpi_get_fpr(MODEL_CORE_ID, api_index);
  endfunction

  function longint unsigned get_csr(input int unsigned csr_addr);
    shortint unsigned api_addr;
    api_addr = csr_addr[15:0];
    return isa_cosim_dpi_get_csr(MODEL_CORE_ID, api_addr);
  endfunction

  task shutdown();
    if (model_created) begin
      isa_cosim_dpi_destroy();
      model_created = 1'b0;
    end
  endtask
endclass

class cosim_commit_order_adapter;
  mailbox #(cosim_commit_event_t) commit_events;
  mailbox #(cosim_arch_state_event_t) arch_state_events;
  be_config cfg;
  longint unsigned cycle_count;
  longint unsigned sequence_count;
  bit initialized;
  bit dut_exit_consumed;
  cosim_commit_event_t pending_mem_store_events[$];
  cosim_commit_event_t committed_events[$];
  string pending_mismatch_diff;
  string pending_mismatch_label;
  cosim_commit_event_t pending_mismatch_context;
  bit pending_mismatch_valid;
  bit pending_level2_mismatch;
  string pending_level2_label;

  function new(mailbox #(cosim_commit_event_t) commit_events,
               mailbox #(cosim_arch_state_event_t) arch_state_events,
               be_config cfg);
    if (commit_events == null)
      be_reporter::fatal_static("[COSIM] commit adapter requires event mailbox");
    if (arch_state_events == null)
      be_reporter::fatal_static("[COSIM] commit adapter requires architectural state mailbox");
    if (cfg == null)
      be_reporter::fatal_static("[COSIM] commit adapter requires be_config");
    this.commit_events = commit_events;
    this.arch_state_events = arch_state_events;
    this.cfg = cfg;
    cycle_count = 0;
    sequence_count = 0;
    dut_exit_consumed = 1'b0;
    pending_mismatch_diff = "";
    pending_mismatch_label = "AT COMMIT";
    pending_mismatch_context = '0;
    pending_mismatch_valid = 1'b0;
    pending_level2_mismatch = 1'b0;
    pending_level2_label = "AT COMMIT";
    initialized = 1'b0;
  endfunction

  task initialize();
    cycle_count = 0;
    sequence_count = 0;
    dut_exit_consumed = 1'b0;
    pending_mem_store_events.delete();
    committed_events.delete();
    pending_mismatch_diff = "";
    pending_mismatch_label = "AT COMMIT";
    pending_mismatch_context = '0;
    pending_mismatch_valid = 1'b0;
    pending_level2_mismatch = 1'b0;
    pending_level2_label = "AT COMMIT";
    initialized = 1'b1;
  endtask

  task automatic queue_mismatch(string label, string diff,
                                cosim_commit_event_t ctx);
    if (!pending_mismatch_valid) begin
      pending_mismatch_label = label;
      pending_mismatch_context = ctx;
      pending_mismatch_valid = 1'b1;
    end
    pending_mismatch_diff = {pending_mismatch_diff, diff};
  endtask

  task automatic emit_pending_mismatch();
    string mnemonic;
    if (!pending_mismatch_valid)
      return;
`ifdef ORBE_EXTERNAL_MNEMONICS
    mnemonic = isa_dpi_mnemonic_name(pending_mismatch_context.mnemonic);
`else
    mnemonic = "unknown";
`endif
    cfg.reporter.mismatch_pair($sformatf("[COSIM] [%s] cycle=%0d; %s",
        pending_mismatch_label, cycle_count, pending_mismatch_diff),
      $sformatf("[COSIM] [%s] mnemonic=%s; commit_fflags=0x%0h (RTL OBSERVATION ONLY, NOT COMPARED WITH REF)",
        pending_mismatch_label, mnemonic, pending_mismatch_context.fflags));
    pending_mismatch_diff = "";
    pending_mismatch_valid = 1'b0;
  endtask

  function automatic bit events_match(cosim_commit_event_t left,
                                       cosim_commit_event_t right);
    return (left.pc == right.pc) && (left.rob_idx == right.rob_idx);
  endfunction

  task automatic consume_pending_mem_store(cosim_commit_event_t commit_event);
    for (int index = pending_mem_store_events.size() - 1;
         index >= 0; index--) begin
      if (events_match(pending_mem_store_events[index], commit_event)) begin
        pending_mem_store_events.delete(index);
        return;
      end
    end
  endtask

  function automatic bit commit_was_seen(cosim_commit_event_t mem_event);
    for (int index = 0; index < committed_events.size(); index++)
      if (events_match(committed_events[index], mem_event))
        return 1'b1;
    return 1'b0;
  endfunction

  task automatic step_terminal_mem_store(cosim_reference_backend reference,
                                         cosim_commit_event_t mem_event);
    cosim_commit_ticket ticket;
    longint unsigned ref_pc;

    reference.step_one(ref_pc);
    ticket = new();
    ticket.sequence_id = sequence_count++;
    ticket.cycle = cycle_count;
    ticket.lane = 0;
    ticket.pc = mem_event.pc;
    ticket.rob_idx = mem_event.rob_idx;
    ticket.ref_pc = ref_pc;
    compare_ticket(ticket);
  endtask

  task automatic compare_ticket(cosim_commit_ticket ticket);
    string diff;
    string mnemonic;
    diff = "";
    if (ticket.pc !== ticket.ref_pc)
      cfg.reporter.diagnostic($sformatf(
          "[COSIM][PC_MISMATCH] seq=%0d cycle=%0d lane=%0d rob=%0d rtl_pc=0x%016h ref_pc=0x%016h",
          ticket.sequence_id, ticket.cycle, ticket.lane, ticket.rob_idx,
          ticket.pc, ticket.ref_pc));
    if (ticket.pc !== ticket.ref_pc)
      diff = {diff, $sformatf("pc=0x%016h (dut), 0x%016h (ref); ",
                              ticket.pc, ticket.ref_pc)};
    if (ticket.rd_write_enable && ticket.rd_is_fp != ticket.ref_rd_is_fp)
      diff = {diff, $sformatf("rd_is_fp=%0b (dut), %0b (ref); ",
                              ticket.rd_is_fp, ticket.ref_rd_is_fp)};
    if (ticket.rd_write_enable && ticket.rd_idx != ticket.ref_rd_idx)
      diff = {diff, $sformatf("rd_idx=%0d (dut), %0d (ref); ",
                              ticket.rd_idx, ticket.ref_rd_idx)};
    if (ticket.rd_write_enable && ticket.result !== ticket.ref_result)
      diff = {diff, $sformatf("commit_result=0x%016h (dut), 0x%016h (ref); ",
                              ticket.result, ticket.ref_result)};
    if (ticket.redirect_valid && ticket.redirect_pc !== ticket.ref_redirect_pc)
      diff = {diff, $sformatf("redirect_pc=0x%016h (dut), 0x%016h (ref); ",
                              ticket.redirect_pc, ticket.ref_redirect_pc)};
    if (ticket.redirect_valid && ticket.recovery_kind !== ticket.ref_recovery_kind)
      diff = {diff, $sformatf("recovery_kind=%0d (dut), %0d (ref); ",
                              ticket.recovery_kind, ticket.ref_recovery_kind)};
    if (diff != "") begin
`ifdef ORBE_EXTERNAL_MNEMONICS
      mnemonic = isa_dpi_mnemonic_name(ticket.mnemonic);
`else
      mnemonic = "unknown";
`endif
      begin
        cosim_commit_event_t ctx;
        ctx = '0;
        ctx.mnemonic = ticket.mnemonic;
        ctx.fflags = ticket.fflags;
        queue_mismatch("AT COMMIT", diff, ctx);
      end
    end else begin
      cfg.print_tb(3, $sformatf(
          "[COSIM][COMMIT] seq=%0d cycle=%0d lane=%0d rob=%0d pc=0x%016h",
          ticket.sequence_id, ticket.cycle, ticket.lane, ticket.rob_idx,
          ticket.pc));
    end
  endtask

  task automatic compare_arch_state(
      cosim_reference_backend reference,
      cosim_arch_state_event_t state_event);
    logic [63:0] ref_value;
    int unsigned csr_addr;
    int unsigned csr_count;
    string diff;
    string mnemonic;
    cosim_commit_event_t context_event;
    diff = "";

    if (state_event.int_arf[0] !== 64'd0)
      cfg.reporter.diagnostic($sformatf(
          "[COSIM][INT_ARF_X0_MISMATCH] cycle=%0d dut=0x%016h expected=0x0000000000000000",
          cycle_count, state_event.int_arf[0]));
    if (state_event.int_arf[0] !== 64'd0)
      diff = {diff, $sformatf("arf_x0=0x%016h (dut), 0x0000000000000000 (ref); ", state_event.int_arf[0])};

    for (int index = 1; index < COSIM_ARF_REG_NUM; index++) begin
      ref_value = reference.get_gpr(index);
      if (state_event.int_arf[index] !== ref_value)
        cfg.reporter.diagnostic($sformatf(
            "[COSIM][INT_ARF_MISMATCH] cycle=%0d reg=x%0d dut=0x%016h ref=0x%016h",
            cycle_count, index, state_event.int_arf[index], ref_value));
      if (state_event.int_arf[index] !== ref_value)
        diff = {diff, $sformatf("arf_x%0d=0x%016h (dut), 0x%016h (ref); ", index, state_event.int_arf[index], ref_value)};
    end

    for (int index = 0; index < COSIM_ARF_REG_NUM; index++) begin
      ref_value = reference.get_fpr(index);
      if (state_event.fp_arf[index] !== ref_value)
        cfg.reporter.diagnostic($sformatf(
            "[COSIM][FP_ARF_MISMATCH] cycle=%0d reg=f%0d dut=0x%016h ref=0x%016h",
            cycle_count, index, state_event.fp_arf[index], ref_value));
      if (state_event.fp_arf[index] !== ref_value)
        diff = {diff, $sformatf("arf_f%0d=0x%016h (dut), 0x%016h (ref); ", index, state_event.fp_arf[index], ref_value)};
    end

    if (state_event.csr_valid !== 1'b0 &&
        state_event.csr_valid !== 1'b1)
      cfg.reporter.fatal("[COSIM] csr_valid is X/Z in architectural state event");

    csr_count = 0;
    if (state_event.csr_valid === 1'b1) begin
      for (int index = 0; index < COSIM_CSR_STATE_NUM; index++) begin
        if (state_event.csr_state_valid[index] !== 1'b0 &&
            state_event.csr_state_valid[index] !== 1'b1)
          cfg.reporter.fatal($sformatf(
              "[COSIM] csr_state_valid[%0d] is X/Z", index));
        if (state_event.csr_state_valid[index] !== 1'b1)
          continue;

        if (^state_event.csr_state_addr[index] === 1'bx ||
            ^state_event.csr_state[index] === 1'bx)
          cfg.reporter.fatal($sformatf(
              "[COSIM] valid CSR entry contains X/Z index=%0d", index));

        for (int previous = 0; previous < index; previous++) begin
          if (state_event.csr_state_valid[previous] === 1'b1 &&
              state_event.csr_state_addr[previous] ==
                  state_event.csr_state_addr[index])
            cfg.reporter.fatal($sformatf(
                "[COSIM] duplicate CSR address addr=0x%03h entries=%0d,%0d",
                state_event.csr_state_addr[index], previous, index));
        end

        csr_addr = state_event.csr_state_addr[index];
        ref_value = reference.get_csr(csr_addr);
        if (state_event.csr_state[index] !== ref_value)
          cfg.reporter.diagnostic($sformatf(
              "[COSIM][CSR_MISMATCH] cycle=%0d addr=0x%03h dut=0x%016h ref=0x%016h",
              cycle_count, state_event.csr_state_addr[index],
              state_event.csr_state[index], ref_value));
        csr_count++;
      end
    end

    if (state_event.csr_event_valid !== 1'b0 &&
        state_event.csr_event_valid !== 1'b1)
      cfg.reporter.fatal("[COSIM] csr_event_valid is X/Z in architectural state event");
    if (state_event.csr_event_valid === 1'b1) begin
      if (^state_event.csr_event_addr === 1'bx ||
          ^state_event.csr_event_wdata === 1'bx ||
          ^state_event.csr_event_rdata === 1'bx)
        cfg.reporter.fatal("[COSIM] valid CSR event contains X/Z");
      cfg.print_tb(3, $sformatf(
          "[COSIM][CSR_EVENT] cycle=%0d addr=0x%03h wdata=0x%016h rdata=0x%016h",
          cycle_count, state_event.csr_event_addr,
          state_event.csr_event_wdata, state_event.csr_event_rdata));
    end

    cfg.print_tb(3, $sformatf(
        "[COSIM][ARCH_STATE] cycle=%0d int_arf=%0d fp_arf=%0d csr_valid=%0b csr_entries=%0d",
        cycle_count, COSIM_ARF_REG_NUM, COSIM_ARF_REG_NUM,
        state_event.csr_valid, csr_count));
    if (diff != "") begin
      context_event = '0;
      if (committed_events.size() != 0)
        context_event = committed_events[committed_events.size()-1];
`ifdef ORBE_EXTERNAL_MNEMONICS
      mnemonic = isa_dpi_mnemonic_name(context_event.mnemonic);
`else
      mnemonic = "unknown";
`endif
      queue_mismatch("AT COMMIT", diff, context_event);
    end
  endtask

  task check_cycle(cosim_reference_backend reference);
    cosim_commit_ticket ticket;
    cosim_commit_event_t commit_event;
    cosim_arch_state_event_t state_event;
    longint unsigned ref_pc;
    bit cycle_end_seen;
    bit had_level1_mismatch;

    if (!initialized)
      cfg.reporter.fatal("[COSIM] check_cycle called before adapter initialization");
    if (reference == null)
      cfg.reporter.fatal("[COSIM] check_cycle requires a reference backend");
    dut_exit_consumed = 1'b0;

    // The architectural-state mailbox is the synchronization point for one
    // BE sampling cycle. Blocking here avoids sampling before BE has started
    // its first cycle, and also prevents a commit event from being paired
    // with the previous cycle's state snapshot.
    arch_state_events.get(state_event);

    cycle_end_seen = 1'b0;
    while (!cycle_end_seen) begin
      // BE places the cycle delimiter before publishing the corresponding
      // state snapshot. Blocking get therefore cannot race the producer, and
      // future-cycle events remain in the mailbox for the next snapshot.
      commit_events.get(commit_event);
      if (commit_event.level2_mismatch) begin
        pending_level2_mismatch = 1'b1;
        pending_level2_label = (commit_event.exception_valid &&
                                !commit_event.commit_valid)
            ? "NO COMMIT" : "AT COMMIT";
      end
      if (commit_event.kind == COSIM_EVENT_COMMIT) begin
        //cfg.print_tb(1, $sformatf(
        //    "[COSIM][EVENT_RX] cycle=%0d group=%0d rob=%0d ref_result=0x%016h ref_rd_idx=%0d ref_rd_fp=%0d ref_recovery_kind=%0d ref_redirect_pc=0x%016h",
        //    cycle_count, commit_event.group, commit_event.rob_idx,
        //    commit_event.ref_result, commit_event.ref_rd_idx,
        //    commit_event.ref_rd_is_fp, commit_event.ref_recovery_kind,
        //    commit_event.ref_redirect_pc));
        // BE publishes events in architectural group order. The independent
        // model advances exactly once for each valid commit event.
        ticket = new();
        ticket.sequence_id = sequence_count++;
        ticket.cycle = cycle_count;
        ticket.lane = commit_event.group;
        ticket.pc = commit_event.pc;
        ticket.rob_idx = commit_event.rob_idx;
        ticket.result = commit_event.result;
        ticket.rd_idx = commit_event.rd_idx;
        ticket.rd_is_fp = commit_event.rd_is_fp;
        ticket.rd_write_enable = commit_event.rd_write_enable;
        ticket.fflags = commit_event.fflags;
        ticket.mnemonic = commit_event.mnemonic;
        ticket.ref_result = commit_event.ref_result;
        ticket.ref_rd_idx = commit_event.ref_rd_idx;
        ticket.ref_rd_is_fp = commit_event.ref_rd_is_fp;
        ticket.redirect_valid = commit_event.redirect_valid;
        ticket.redirect_pc = commit_event.redirect_pc;
        ticket.recovery_kind = commit_event.recovery_kind;
        ticket.ref_redirect_pc = commit_event.ref_redirect_pc;
        ticket.ref_recovery_kind = commit_event.ref_recovery_kind;
        reference.step_one(ref_pc);
        ticket.ref_pc = ref_pc;
        compare_ticket(ticket);
        committed_events.push_back(commit_event);
        consume_pending_mem_store(commit_event);
      end else if (commit_event.kind == COSIM_EVENT_MEM_STORE) begin
        // A memory store is normally an observation attached to an ordinary
        // ROB commit and must not advance the reference twice. A terminal
        // tohost store can set model exit before its ROB commit is observable,
        // so that event consumes the missing reference step.
        cfg.print_tb(3, $sformatf(
            "[COSIM][MEM_STORE] order=%0d vaddr=0x%016h data=0x%016h mask=0x%02h pc=0x%016h rob=%0d terminal=%0b",
            commit_event.order, commit_event.vaddr, commit_event.data,
            commit_event.mask, commit_event.pc, commit_event.rob_idx,
            commit_event.terminal));
        if (!commit_was_seen(commit_event))
          pending_mem_store_events.push_back(commit_event);
      end else if (commit_event.kind == COSIM_EVENT_DUT_EXIT) begin
        // The shared model can report exit immediately after storeCommit and
        // before the corresponding ROB commit pulse is observable. Any
        // memory store still unmatched here is therefore the terminal store
        // that must advance the independent reference exactly once.
        while (pending_mem_store_events.size() != 0) begin
          cosim_commit_event_t terminal_store;
          terminal_store = pending_mem_store_events.pop_front();
          step_terminal_mem_store(reference, terminal_store);
        end
        if (!reference.is_to_exit())
          cfg.reporter.fatal($sformatf(
              "[COSIM] DUT exited but reference did not reach tohost after %0d commit tickets",
              sequence_count));
        dut_exit_consumed = 1'b1;
      end else if (commit_event.kind == COSIM_EVENT_RECOVERY) begin
        string diff;
        string mnemonic;
        string event_label;
        diff = "";
        // An exception with no RTL commit pulse still consumes one
        // architectural instruction in the independent reference.  Advance
        // it here so the faulting PC is compared and the following commit
        // remains aligned.  A same-cycle commit+redirect was already stepped
        // by its COSIM_EVENT_COMMIT and must not step again.
        if (commit_event.exception_valid && !commit_event.commit_valid) begin
          reference.step_one(ref_pc);
          commit_event.ref_pc = ref_pc;
        end
        if (commit_event.pc !== commit_event.ref_pc)
          diff = {diff, $sformatf("pc=0x%016h (dut), 0x%016h (ref); ",
                                  commit_event.pc, commit_event.ref_pc)};
        if (commit_event.exception_valid &&
            commit_event.exception_cause !== commit_event.ref_exception_cause)
          diff = {diff, $sformatf("exception_cause=0x%016h (dut), 0x%016h (ref); ",
                                  commit_event.exception_cause,
                                  commit_event.ref_exception_cause)};
        if (commit_event.exception_valid &&
            commit_event.exception_tval !== commit_event.ref_exception_tval)
          diff = {diff, $sformatf("exception_tval=0x%016h (dut), 0x%016h (ref); ",
                                  commit_event.exception_tval,
                                  commit_event.ref_exception_tval)};
        if (commit_event.redirect_valid &&
            commit_event.redirect_pc !== commit_event.ref_redirect_pc)
          diff = {diff, $sformatf("redirect_pc=0x%016h (dut), 0x%016h (ref); ",
                                  commit_event.redirect_pc,
                                  commit_event.ref_redirect_pc)};
        if (commit_event.redirect_valid &&
            commit_event.recovery_kind !== commit_event.ref_recovery_kind)
          diff = {diff, $sformatf("recovery_kind=%0d (dut), %0d (ref); ",
                                  commit_event.recovery_kind,
                                  commit_event.ref_recovery_kind)};
        if (diff != "") begin
          event_label = (commit_event.exception_valid && !commit_event.commit_valid)
              ? "NO COMMIT" : "AT COMMIT";
`ifdef ORBE_EXTERNAL_MNEMONICS
          mnemonic = isa_dpi_mnemonic_name(commit_event.mnemonic);
`else
          mnemonic = "unknown";
`endif
          queue_mismatch(event_label, diff, commit_event);
        end
      end else if (commit_event.kind == COSIM_EVENT_CYCLE_END) begin
        cycle_end_seen = 1'b1;
      end else begin
        cfg.reporter.fatal($sformatf(
            "[COSIM] unsupported observation event kind=%0d",
            commit_event.kind));
      end
    end

    // All commit events are now from the same sampled cycle, so compare the
    // DUT snapshot against the reference after advancing it for those commits.
    compare_arch_state(reference, state_event);
    had_level1_mismatch = pending_mismatch_valid;
    emit_pending_mismatch();
    if (pending_level2_mismatch) begin
      if (!had_level1_mismatch)
        cfg.reporter.diagnostic($sformatf(
            "[COSIM] [%s] cycle=%0d; Level-1 fields match; Level-2 mismatch pending",
            pending_level2_label, cycle_count));
      cfg.reporter.fatal($sformatf(
          "[COSIM][LEVEL2_MISMATCH] cycle=%0d; Level-1 and Level-2 logs emitted",
          cycle_count));
    end
    pending_level2_mismatch = 1'b0;
    pending_level2_label = "AT COMMIT";
    cycle_count++;
  endtask
endclass
