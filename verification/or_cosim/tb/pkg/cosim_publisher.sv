// [This file] COSIM event publisher: packs DUT observations on the neutral event stream (ob_cosim_if / ob_if)
//             into structured events and delivers them to the G2 checker's mailbox.
//
// ── Why a separate file ───────────────────────────────────────────────────
// These publish actions used to be welded into be_agent.sv (the advance implementation of the rtl_v1 kind).
// Stage 1 does not start be_agent -- starting it would double-drive the same ISA model with be_bfm --
// so the publisher could not come along into stage 1 either, and the checker had to be written again as be_checker.sv.
// The result: the 609 lines of compare logic in cosim_pkg never executed once before the DUT arrived.
//
// The publish actions themselves only read ob_cosim_vif / ob_vif / cfg, regardless of whether the slot holds
// the stand-in or RTL (ob_cosim_if has the same shape in both DUT kinds). Pulling it out of the advance
// implementation lets both DUT kinds share the same checker.
//
// ── Boundary ──────────────────────────────────────────────────────────────
// This class is **only responsible for**: reading the neutral event stream · filling event structs · X/Z health check · mem store dedup · put.
// This class is **not responsible for**: exit orchestration, ROB bookkeeping, any query or advance of the model under test.
//   Those belong to each DUT kind's advancing party (stage 2 be_agent, stage 1 be_bfm), handed back to them via outputs.
//   Hence publish_mem_store's terminal is passed in by the caller as terminal_hint;
//   this class does not call isa_dpi_is_to_exit() itself.
class cosim_publisher;
  virtual ob_if ob_vif;
  virtual ob_cosim_if #(BE_ISSUE_NUM, BE_ROB_ADDR_W) ob_cosim_vif;
  be_config cfg;
  mailbox #(cosim_commit_event_t) commit_events;
  mailbox #(cosim_arch_state_event_t) arch_state_events;

  // mem store dedup state. Belongs to "publishing" itself, so it lives with this class.
  bit mem_store_observation_seen;
  longint unsigned last_mem_store_order;
  longint unsigned last_mem_store_pc;
  longint unsigned last_mem_store_vaddr;
  longint unsigned last_mem_store_data;

  function new(virtual ob_if ob_vif,
               virtual ob_cosim_if #(BE_ISSUE_NUM, BE_ROB_ADDR_W) ob_cosim_vif,
               mailbox #(cosim_commit_event_t) commit_events,
               mailbox #(cosim_arch_state_event_t) arch_state_events,
               be_config cfg);
    if (cfg == null)
      be_reporter::fatal_static("[COSIM_PUB] requires be_config");
    if (commit_events == null)
      be_reporter::fatal_static("[COSIM_PUB] requires COSIM commit event mailbox");
    if (arch_state_events == null)
      be_reporter::fatal_static("[COSIM_PUB] requires COSIM architectural state mailbox");
    this.ob_vif = ob_vif;
    this.ob_cosim_vif = ob_cosim_vif;
    this.commit_events = commit_events;
    this.arch_state_events = arch_state_events;
    this.cfg = cfg;
    mem_store_observation_seen = 1'b0;
    last_mem_store_order = 0;
    last_mem_store_pc    = 0;
    last_mem_store_vaddr = 0;
    last_mem_store_data  = 0;
  endfunction

  // ── Architectural state snapshot ────────────────────────────────────────
  task automatic publish_arch_state();
    cosim_arch_state_event_t state_event;

    if (!cfg.cosim_enable)
      return;
    if (ob_cosim_vif.rst_n !== 1'b1)
      return;
    if (ob_cosim_vif.csr_valid !== 1'b0 &&
        ob_cosim_vif.csr_valid !== 1'b1)
      cfg.reporter.fatal("[BE][COSIM] csr_valid is X/Z");

    for (int index = 0; index < COSIM_ARF_REG_NUM; index++) begin
      if (^ob_cosim_vif.int_arf[index] === 1'bx ||
          ^ob_cosim_vif.fp_arf[index] === 1'bx)
        cfg.reporter.fatal($sformatf(
            "[BE][COSIM] ARF observation contains X/Z index=%0d", index));
      state_event.int_arf[index] = ob_cosim_vif.int_arf[index];
      state_event.fp_arf[index] = ob_cosim_vif.fp_arf[index];
    end

    state_event.csr_valid = ob_cosim_vif.csr_valid;
    state_event.csr_state_valid = ob_cosim_vif.csr_state_valid;
    state_event.csr_state_addr = ob_cosim_vif.csr_state_addr;
    state_event.csr_state = ob_cosim_vif.csr_state;
    state_event.csr_event_valid = ob_cosim_vif.csr_event_valid;
    state_event.csr_event_addr = ob_cosim_vif.csr_event_addr;
    state_event.csr_event_wdata = ob_cosim_vif.csr_event_wdata;
    state_event.csr_event_rdata = ob_cosim_vif.csr_event_rdata;

    if (state_event.csr_valid === 1'b1) begin
      for (int index = 0; index < COSIM_CSR_STATE_NUM; index++) begin
        if (state_event.csr_state_valid[index] !== 1'b0 &&
            state_event.csr_state_valid[index] !== 1'b1)
          cfg.reporter.fatal($sformatf(
              "[BE][COSIM] csr_state_valid[%0d] is X/Z", index));
        if (state_event.csr_state_valid[index] === 1'b1 &&
            (^state_event.csr_state_addr[index] === 1'bx ||
             ^state_event.csr_state[index] === 1'bx))
          cfg.reporter.fatal($sformatf(
              "[BE][COSIM] valid CSR entry contains X/Z index=%0d", index));
      end
    end

    if (state_event.csr_event_valid !== 1'b0 &&
        state_event.csr_event_valid !== 1'b1)
      cfg.reporter.fatal("[BE][COSIM] csr_event_valid is X/Z");
    if (state_event.csr_event_valid === 1'b1 &&
        (^state_event.csr_event_addr === 1'bx ||
         ^state_event.csr_event_wdata === 1'bx ||
         ^state_event.csr_event_rdata === 1'bx))
      cfg.reporter.fatal("[BE][COSIM] valid CSR event contains X/Z");

    arch_state_events.put(state_event);
  endtask

  // ── Commit event ────────────────────────────────────────────────────────
  // pc / mnemonic / level2_mismatch are passed in by the caller: they come from the per-rob
  // bookkeeping table kept by the advancing party, are not on the neutral event stream, and this class does not hold them.
  task automatic publish_commit(input int unsigned group,
                                input longint unsigned pc,
                                input longint unsigned rob_idx,
                                input longint unsigned ref_result,
                                input int unsigned ref_rd_idx,
                                input bit ref_rd_is_fp,
                                input longint signed mnemonic_code,
                                input int unsigned ref_recovery_kind,
                                input longint unsigned ref_redirect_pc,
                                input bit level2_mismatch);
    cosim_commit_event_t commit_event;

    if (!cfg.cosim_enable)
      return;
    commit_event = '0;
    commit_event.group = group;
    commit_event.kind = COSIM_EVENT_COMMIT;
    commit_event.pc = pc;
    commit_event.rob_idx = rob_idx;
    commit_event.ref_pc = '0;
    commit_event.order = '0;
    commit_event.vaddr = '0;
    commit_event.data = '0;
    commit_event.mask = '0;
    commit_event.terminal = 1'b0;
    commit_event.result = ob_cosim_vif.commit_result[group];
    commit_event.rd_idx = ob_cosim_vif.commit_rd_idx[group];
    commit_event.rd_is_fp = ob_cosim_vif.commit_rd_is_fp[group];
    commit_event.rd_write_enable = ob_cosim_vif.commit_rd_write_enable[group];
    commit_event.fflags = ob_cosim_vif.commit_fflags[group];
    commit_event.exception_valid = ob_cosim_vif.commit_exception_valid;
    commit_event.exception_cause = ob_cosim_vif.commit_exception_cause;
    commit_event.exception_tval = ob_cosim_vif.commit_exception_tval;
    // Redirect is a cycle-global RTL observation, but a commit event is
    // lane-specific.  Attach it only to the commit whose ROB tag is the
    // recovery origin; otherwise a same-cycle younger/older lane can compare
    // the redirect target against its own reference next PC.
    commit_event.redirect_valid =
        ob_cosim_vif.commit_redirect_valid &&
        ob_vif.recovery_valid &&
        (ob_vif.recovery_origin_tag == rob_idx);
    commit_event.recovery_kind = commit_event.redirect_valid
        ? ob_cosim_vif.commit_recovery_kind : '0;
    commit_event.redirect_pc = commit_event.redirect_valid
        ? ob_cosim_vif.commit_redirect_pc : '0;
    commit_event.mnemonic = mnemonic_code;
    commit_event.ref_result = ref_result;
    commit_event.ref_rd_idx = ref_rd_idx[4:0];
    commit_event.ref_rd_is_fp = ref_rd_is_fp;
    commit_event.ref_recovery_kind = ref_recovery_kind[2:0];
    commit_event.ref_redirect_pc = ref_redirect_pc;
    commit_event.level2_mismatch = level2_mismatch;
    commit_events.put(commit_event);
  endtask

  // ── Recovery event ──────────────────────────────────────────────────────
  task automatic publish_recovery(input longint unsigned rob_idx,
                                  input longint unsigned pc,
                                  input longint unsigned ref_pc,
                                  input int unsigned ref_kind,
                                  input longint unsigned ref_redirect_pc,
                                  input longint unsigned ref_cause,
                                  input longint unsigned ref_tval,
                                  input longint signed mnemonic_code,
                                  input bit level2_mismatch);
    cosim_commit_event_t recovery_event;

    recovery_event = '0;
    if (!cfg.cosim_enable)
      return;
    recovery_event.kind = COSIM_EVENT_RECOVERY;
    recovery_event.rob_idx = rob_idx;
    recovery_event.pc = pc;
    recovery_event.redirect_valid = ob_cosim_vif.commit_redirect_valid;
    recovery_event.recovery_kind = ob_cosim_vif.commit_recovery_kind;
    recovery_event.redirect_pc = ob_cosim_vif.commit_redirect_pc;
    recovery_event.exception_valid = ob_cosim_vif.commit_exception_valid;
    // commit_valid means "the recovery-source entry itself committed this cycle" (the checker uses it to decide
    // whether to make up a step for the excepting entry). Cannot use |commit_valid: when an older lane commits
    // and a younger entry raises an exception in the same cycle (rv64ui-v-sb: rob8 ADDI commits + rob9 SB page fault),
    // it would be misjudged as already stepped and the reference model falls one behind from then on. Attribute by rob, same discipline as fflags below.
    recovery_event.commit_valid = 1'b0;
    recovery_event.exception_cause = ob_cosim_vif.commit_exception_cause;
    recovery_event.exception_tval = ob_cosim_vif.commit_exception_tval;
    recovery_event.fflags = '0;
    for (int g = 0; g < BE_ISSUE_NUM; g++) begin
      if (ob_cosim_vif.commit_valid[g] &&
          ob_cosim_vif.commit_rob_idx[g] == rob_idx[BE_ROB_ADDR_W-1:0]) begin
        recovery_event.commit_valid = 1'b1;
        recovery_event.fflags = ob_cosim_vif.commit_fflags[g];
      end
    end
    recovery_event.ref_pc = ref_pc;
    recovery_event.ref_recovery_kind = ref_kind[2:0];
    recovery_event.ref_redirect_pc = ref_redirect_pc;
    recovery_event.ref_exception_cause = ref_cause[62:0];
    recovery_event.ref_exception_tval = ref_tval;
    recovery_event.level2_mismatch = level2_mismatch;
    recovery_event.mnemonic = mnemonic_code;
    commit_events.put(recovery_event);
  endtask

  // ── Store commit observation ────────────────────────────────────────────
  // terminal_hint: the caller's judgment of "is this the terminating store". This class does not query the model.
  // Outputs published / rob_out / terminal_out are for the caller's exit orchestration and ROB bookkeeping.
  task automatic publish_mem_store(input bit terminal_hint,
                                   output bit published,
                                   output longint unsigned rob_out,
                                   output bit terminal_out);
    cosim_commit_event_t mem_event;
    bit terminal_store;

    published = 1'b0;
    rob_out = 0;
    terminal_out = 1'b0;

    if (ob_cosim_vif.rst_n !== 1'b1 ||
        ob_cosim_vif.mem_store_commit_valid !== 1'b1)
      return;
    if (^ob_cosim_vif.mem_store_commit_order === 1'bx ||
        ^ob_cosim_vif.mem_store_commit_vaddr === 1'bx ||
        ^ob_cosim_vif.mem_store_commit_data === 1'bx ||
        ^ob_cosim_vif.mem_store_commit_mask === 1'bx ||
        ^ob_cosim_vif.mem_store_commit_pc === 1'bx ||
        ^ob_cosim_vif.mem_store_commit_rob_idx === 1'bx)
      cfg.reporter.fatal(
          "[BE][COSIM] memory store observation contains X/Z");

    // [R9-f] Dedup used to look only at order -- but the cache's order resets to zero after flush, so of two consecutive
    // order=0 observations the second was dropped as a duplicate (rv64ua-v-amoadd_d: the sd at pc=0x800029a0 really drained,
    // [CACHE][STORE_COMMIT] has a record, but the MEM_STORE observation was gone). Now compares (order, pc, vaddr, data).
    if (mem_store_observation_seen &&
        (ob_cosim_vif.mem_store_commit_order == last_mem_store_order) &&
        (ob_cosim_vif.mem_store_commit_pc    == last_mem_store_pc) &&
        (ob_cosim_vif.mem_store_commit_vaddr == last_mem_store_vaddr) &&
        (ob_cosim_vif.mem_store_commit_data  == last_mem_store_data))
      return;
    mem_store_observation_seen = 1'b1;
    last_mem_store_order = ob_cosim_vif.mem_store_commit_order;
    last_mem_store_pc    = ob_cosim_vif.mem_store_commit_pc;
    last_mem_store_vaddr = ob_cosim_vif.mem_store_commit_vaddr;
    last_mem_store_data  = ob_cosim_vif.mem_store_commit_data;

    terminal_store = ob_cosim_vif.mem_store_commit_terminal || terminal_hint;
    mem_event.kind = COSIM_EVENT_MEM_STORE;
    mem_event.group = '0;
    mem_event.pc = ob_cosim_vif.mem_store_commit_pc;
    mem_event.rob_idx = ob_cosim_vif.mem_store_commit_rob_idx;
    mem_event.order = ob_cosim_vif.mem_store_commit_order;
    mem_event.vaddr = ob_cosim_vif.mem_store_commit_vaddr;
    mem_event.data = ob_cosim_vif.mem_store_commit_data;
    mem_event.mask = ob_cosim_vif.mem_store_commit_mask;
    mem_event.terminal = terminal_store;
    commit_events.put(mem_event);

    published = 1'b1;
    rob_out = mem_event.rob_idx;
    terminal_out = terminal_store;

    // Cache owns production of the record. Once this sampler has copied it
    // into the structured event mailbox, clear the boundary so the next
    // cache phase can publish a new store event.
    ob_cosim_vif.mem_store_commit_valid = 1'b0;
    ob_cosim_vif.mem_store_commit_terminal = 1'b0;
  endtask

  // ── Termination and end of cycle ────────────────────────────────────────
  task automatic publish_dut_exit();
    cosim_commit_event_t exit_event;

    exit_event.kind = COSIM_EVENT_DUT_EXIT;
    exit_event.group = '0;
    exit_event.pc = '0;
    exit_event.rob_idx = '0;
    exit_event.order = '0;
    exit_event.vaddr = '0;
    exit_event.data = '0;
    exit_event.mask = '0;
    exit_event.terminal = 1'b1;
    commit_events.put(exit_event);
  endtask

  task automatic publish_cycle_end();
    cosim_commit_event_t end_event;

    if (!cfg.cosim_enable)
      return;
    end_event.kind = COSIM_EVENT_CYCLE_END;
    end_event.group = '0;
    end_event.pc = '0;
    end_event.rob_idx = '0;
    end_event.order = '0;
    end_event.vaddr = '0;
    end_event.data = '0;
    end_event.mask = '0;
    end_event.terminal = 1'b0;
    commit_events.put(end_event);
  endtask
endclass

// ── Stage 1 adapter ───────────────────────────────────────────────────────
// Feeds the observations the stand-in publishes on ob_cosim_if to **the same** checker as stage 2
// (cosim_agent / cosim_pkg). This class only handles phase and delivery; it contains no compare logic.
//
// Phase: posedge. The stand-in drives ob_cosim at negedge with blocking assignments, and the value holds until
// obs_clear() at the next negedge (Checker_AgentContract, "sampling phase" section). Stage 2's be_agent samples at
// negedge because in that DUT kind it is continuously driven by rtl_v1_obs registers, with no such race.
// The checker implementation is the same for both DUT kinds; the sampling phase follows each slot occupant's drive discipline.
//
// Architectural state: per the contract the stand-in **does not drive** int_arf / fp_arf. This class reads them from the
// driven model instance and fills the observation surface -- Checker_AgentContract assigns this mirroring to the checker side.
// So stage 1 compares "driven instance ↔ independent reference instance"; running the same program they should match
// entry by entry; a mismatch is an environment bug, which is exactly the self path to verify in the degraded period
// (sampling time, field alignment, compare logic).
class cosim_stage1_feeder;
  localparam int unsigned MODEL_CORE_ID = 0;

  virtual ob_if ob_vif;
  virtual ob_cosim_if #(BE_ISSUE_NUM, BE_ROB_ADDR_W) ob_cosim_vif;
  be_config cfg;
  cosim_publisher pub;
  bit stop_requested;
  // Negative verification: +COSIM_ARF_INJECT=<n> flips one bit of the mirrored x<n> to create an artificial divergence.
  // Inherited from the retired be_checker's chk_inject (Checker_AgentContract, "negative verification of the checker").
  // Without it there is no way to tell "checker passed" from "checker never ran".
  int arf_inject_reg;

  function new(virtual ob_if ob_vif,
               virtual ob_cosim_if #(BE_ISSUE_NUM, BE_ROB_ADDR_W) ob_cosim_vif,
               mailbox #(cosim_commit_event_t) commit_events,
               mailbox #(cosim_arch_state_event_t) arch_state_events,
               be_config cfg);
    this.ob_vif = ob_vif;
    this.ob_cosim_vif = ob_cosim_vif;
    this.cfg = cfg;
    pub = new(ob_vif, ob_cosim_vif, commit_events, arch_state_events, cfg);
    stop_requested = 1'b0;
    if (!$value$plusargs("COSIM_ARF_INJECT=%d", arf_inject_reg))
      arf_inject_reg = -1;
    else
      cfg.print_tb(1, $sformatf(
          "[COSIM][INJECT] ARF mirror of x%0d will be corrupted", arf_inject_reg));
  endfunction

  // Architectural state of the driven instance → observation surface. See class comment.
  task automatic mirror_arch_state();
    for (int i = 0; i < COSIM_ARF_REG_NUM; i++) begin
      ob_cosim_vif.int_arf[i] = isa_dpi_get_gpr(MODEL_CORE_ID, i);
      ob_cosim_vif.fp_arf[i]  = isa_dpi_get_fpr(MODEL_CORE_ID, i);
    end
    // Stage 1 takes no CSR snapshot: the stand-in does not model the CSR architectural surface; leaving it empty is more honest than leaving X.
    ob_cosim_vif.csr_valid       = 1'b0;
    ob_cosim_vif.csr_state_valid = '0;
    ob_cosim_vif.csr_event_valid = 1'b0;

    if (arf_inject_reg >= 0 && arf_inject_reg < COSIM_ARF_REG_NUM)
      ob_cosim_vif.int_arf[arf_inject_reg] =
          ob_cosim_vif.int_arf[arf_inject_reg] ^ 64'd1;
  endtask

  task automatic stop();
    stop_requested = 1'b1;
  endtask

  task run();
    bit published;
    bit terminal_store;
    longint unsigned rob_out;
    bit exit_published;

    exit_published = 1'b0;
    forever begin
      @(posedge ob_vif.clk);
      if (stop_requested)
        return;
      if (ob_cosim_vif.rst_n !== 1'b1)
        continue;

      pub.publish_mem_store(1'b0, published, rob_out, terminal_store);

      // The stand-in commits at most one per cycle, so only group 0 is used.
      // ref_* passed as zero: cosim_pkg drives its own independent reference instance and uses its own stepped values for PC;
      // the rd group is gated by rd_write_enable, which the stand-in does not set, so this DUT kind degrades naturally (as the contract states).
      if (ob_cosim_vif.commit_valid[0])
        pub.publish_commit(0,
                           ob_cosim_vif.commit_pc[0],
                           ob_cosim_vif.commit_rob_idx[0],
                           '0, '0, 1'b0, '0, '0, '0, 1'b0);

      if (!exit_published && (isa_dpi_is_to_exit() != 0) &&
          !ob_cosim_vif.commit_valid[0]) begin
        exit_published = 1'b1;
        pub.publish_dut_exit();
        pub.publish_cycle_end();
        mirror_arch_state();
        pub.publish_arch_state();
        return;
      end

      pub.publish_cycle_end();
      mirror_arch_state();
      pub.publish_arch_state();
    end
  endtask
endclass
