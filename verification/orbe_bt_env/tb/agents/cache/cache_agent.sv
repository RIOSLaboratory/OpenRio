class cache_pending;
  be_lsu_issue_pld_t pld;
  longint unsigned enqueue_order;
  bit executed;
  bit wakeup_seen;
  bit terminal_ready;
  bit terminal_exception;
  lsu_cause_t cause;
  logic [63:0] tval;
  logic [63:0] data;
  longint unsigned response_cycle;

  function new(be_lsu_issue_pld_t pld, longint unsigned enqueue_order);
    this.pld = pld;
    this.enqueue_order = enqueue_order;
    executed = 1'b0;
    wakeup_seen = 1'b0;
    terminal_ready = 1'b0;
    terminal_exception = 1'b0;
    cause = '0;
    tval = '0;
    data = '0;
    response_cycle = 0;
  endfunction
endclass

// LSU owner of executeInsn, memory APIs, store ordering, and terminal response.
class cache_agent;
  localparam int unsigned MODEL_CORE_ID = 0;

  virtual lsu_if vif;
  virtual ob_if phase_vif;
  be_config cfg;
  cache_pending pending[int unsigned];
  longint unsigned next_enqueue_order;
  longint unsigned next_be_phase_seq;
  longint unsigned cycle_count;
  bit stop_requested;
  bit model_exit_seen;
  bit early_store_wakeup;

  function new(virtual lsu_if vif, virtual ob_if phase_vif, be_config cfg);
    if (cfg == null)
      be_reporter::fatal_static("[CACHE] cache_agent requires be_config");
    this.vif = vif;
    this.phase_vif = phase_vif;
    this.cfg = cfg;
    next_enqueue_order = 0;
    cycle_count = 0;
    stop_requested = 1'b0;
    model_exit_seen = 1'b0;
    early_store_wakeup = 1'b0;
    vif.lsu_be_issue_ready = 1'b0;
    vif.lsu_be_done_valid = 1'b0;
    vif.lsu_be_exception_valid = 1'b0;
    vif.lsu_be_writeback_pld = '0;
    vif.lsu_be_bypass_valid = 1'b0;
    vif.lsu_be_bypass_pld = '0;
  endfunction

  function automatic lsu_req_property_t issue_property(
      input be_lsu_issue_pld_t pld);
    return req_property_from_subop(pld.exe_subop);
  endfunction

  function automatic bit read_side(be_lsu_issue_pld_t pld);
    lsu_req_property_t prop;
    prop = issue_property(pld);
    return prop.is_load || prop.is_lr || prop.is_amo || prop.is_sc;
  endfunction

  function automatic bit store_side(be_lsu_issue_pld_t pld);
    lsu_req_property_t prop;
    prop = issue_property(pld);
    return prop.is_store || prop.is_amo || prop.is_sc;
  endfunction

  function automatic bit plain_store(be_lsu_issue_pld_t pld);
    lsu_req_property_t prop;
    prop = issue_property(pld);
    return prop.is_store && !prop.is_amo && !prop.is_sc;
  endfunction

  function automatic bit older_store_pending(cache_pending target);
    int unsigned tag;
    foreach (pending[tag]) begin
      if (pending[tag].enqueue_order < target.enqueue_order
          && store_side(pending[tag].pld)
          && !pending[tag].terminal_ready)
        return 1'b1;
    end
    return 1'b0;
  endfunction

  task automatic clear_local_state();
    pending.delete();
    early_store_wakeup = 1'b0;
    vif.lsu_be_done_valid = 1'b0;
    vif.lsu_be_exception_valid = 1'b0;
    vif.lsu_be_writeback_pld = '0;
    vif.lsu_be_bypass_valid = 1'b0;
    vif.lsu_be_bypass_pld = '0;
  endtask

  task automatic capture_model_trap(cache_pending e, output bit trap_valid);
    byte unsigned valid;
    longint unsigned cause;
    longint unsigned tval;
    int rc;
    rc = isa_dpi_get_execute_metadata(
        MODEL_CORE_ID, {{(64-MOCK_ROB_SLOT_W){1'b0}},
                        e.pld.tag[MOCK_ROB_SLOT_W-1:0]},
        valid, cause, tval);
    if (rc != ISA_API_PASS)
      cfg.reporter.fatal($sformatf("[CACHE] get_execute_metadata tag=0x%0h rc=%0d",
                                   e.pld.tag, rc));
    trap_valid = valid != 0;
    e.cause = lsu_cause_t'(cause);
    e.tval = tval;
  endtask

  task automatic finish_exception(cache_pending e);
    e.terminal_exception = 1'b1;
    e.terminal_ready = 1'b1;
    e.response_cycle = cycle_count;
    cfg.print_cache(1, $sformatf(
        "[CACHE][LSU_EXCEPTION] tag=0x%0h cause=%0d tval=0x%016h",
        e.pld.tag, e.cause, e.tval));
  endtask

  task automatic finish_done(cache_pending e);
    e.terminal_exception = 1'b0;
    e.terminal_ready = 1'b1;
    e.response_cycle = cycle_count
        + (store_side(e.pld) ? cfg.cache_store_done_delay_cycles
                             : cfg.cache_load_return_delay_cycles);
    cfg.print_cache(3, $sformatf(
        "[CACHE][LSU_DONE_QUEUED] tag=0x%0h data=0x%016h ready_cycle=%0d",
        e.pld.tag, e.data, e.response_cycle));
  endtask

  task automatic execute_entry(cache_pending e);
    logic [5:0] model_rob_idx;
    bit trap_valid;
    int rc;

    model_rob_idx = '0;
    model_rob_idx[MOCK_ROB_SLOT_W-1:0] = e.pld.tag[MOCK_ROB_SLOT_W-1:0];
    if (!e.executed) begin
      rc = isa_dpi_execute_insn(MODEL_CORE_ID, model_rob_idx);
      if (rc == ISA_API_PENDING)
        return;
      capture_model_trap(e, trap_valid);
      if ((rc == ISA_API_FAIL) && !trap_valid)
        cfg.reporter.fatal($sformatf("[CACHE] executeInsn tag=0x%0h failed without trap",
                                     e.pld.tag));
      if ((rc != ISA_API_PASS) && (rc != ISA_API_SKIP)
          && !((rc == ISA_API_FAIL) && trap_valid))
        cfg.reporter.fatal($sformatf("[CACHE] executeInsn tag=0x%0h rc=%0d",
                                     e.pld.tag, rc));
      e.executed = 1'b1;
      if (trap_valid) begin
        finish_exception(e);
        return;
      end
    end

    if (read_side(e.pld)) begin
      if ((issue_property(e.pld).is_amo || issue_property(e.pld).is_sc)
          && older_store_pending(e))
        return;
      rc = isa_dpi_proc_mem_load(MODEL_CORE_ID, model_rob_idx);
      if (rc == ISA_API_PENDING)
        return;
      if (rc == ISA_API_SKIP)
        rc = isa_dpi_proc_mem_req(MODEL_CORE_ID, model_rob_idx);
      if (rc != ISA_API_PASS) begin
        capture_model_trap(e, trap_valid);
        if (trap_valid) begin
          finish_exception(e);
          return;
        end
        cfg.reporter.fatal($sformatf("[CACHE] memory read tag=0x%0h rc=%0d",
                                     e.pld.tag, rc));
      end
      e.data = isa_dpi_get_insn_rd_value(MODEL_CORE_ID, model_rob_idx);
    end

    if (store_side(e.pld)) begin
      if (plain_store(e.pld)
          && !(e.pld.st_br_resolve || e.wakeup_seen))
        return;
      if (older_store_pending(e))
        return;
      rc = isa_dpi_store_commit(MODEL_CORE_ID);
      if (rc != ISA_API_PASS)
        cfg.reporter.fatal($sformatf("[CACHE] storeCommit tag=0x%0h rc=%0d",
                                     e.pld.tag, rc));
      rc = isa_dpi_clear_mem_reserve(MODEL_CORE_ID);
      if (rc != ISA_API_PASS)
        cfg.reporter.fatal("[CACHE] clearMemReserve failed");
    end

    finish_done(e);
  endtask

  task automatic service_oldest();
    cache_pending oldest;
    int unsigned tag;
    oldest = null;
    foreach (pending[tag])
      if (!pending[tag].terminal_ready
          && (oldest == null || pending[tag].enqueue_order < oldest.enqueue_order))
        oldest = pending[tag];
    if (oldest != null)
      execute_entry(oldest);
  endtask

  task automatic drive_terminal_response();
    cache_pending oldest;
    int unsigned tag;
    if (vif.lsu_be_done_valid || vif.lsu_be_exception_valid)
      return;
    oldest = null;
    foreach (pending[tag])
      if (pending[tag].terminal_ready
          && pending[tag].response_cycle <= cycle_count
          && (oldest == null || pending[tag].enqueue_order < oldest.enqueue_order))
        oldest = pending[tag];
    if (oldest == null)
      return;
    if (oldest.terminal_exception) begin
      vif.lsu_be_writeback_pld.tag = oldest.pld.tag;
      vif.lsu_be_writeback_pld.done_valid = 1'b0;
      vif.lsu_be_writeback_pld.data = '0;
      vif.lsu_be_writeback_pld.exception_valid = 1'b1;
      vif.lsu_be_writeback_pld.exception_cause = oldest.cause;
      vif.lsu_be_writeback_pld.exception_tval = oldest.tval;
      vif.lsu_be_exception_valid = 1'b1;
    end else begin
      vif.lsu_be_writeback_pld.tag = oldest.pld.tag;
      vif.lsu_be_writeback_pld.done_valid = 1'b1;
      vif.lsu_be_writeback_pld.data = oldest.data;
      vif.lsu_be_writeback_pld.exception_valid = 1'b0;
      vif.lsu_be_writeback_pld.exception_cause = '0;
      vif.lsu_be_writeback_pld.exception_tval = '0;
      vif.lsu_be_done_valid = 1'b1;
      vif.lsu_be_bypass_pld.tag = oldest.pld.tag;
      vif.lsu_be_bypass_pld.data = oldest.data;
      vif.lsu_be_bypass_valid = read_side(oldest.pld);
    end
  endtask

  task automatic accept_issue(input bit issue_fire,
                              input be_lsu_issue_pld_t sampled_pld,
                              input bit wakeup_pulse);
    int unsigned tag;
    cache_pending e;
    if (!issue_fire) begin
      if (wakeup_pulse) begin
        cache_pending oldest_unauthorized;
        int unsigned scan_tag;
        oldest_unauthorized = null;
        foreach (pending[scan_tag])
          if (plain_store(pending[scan_tag].pld)
              && !pending[scan_tag].pld.st_br_resolve
              && !pending[scan_tag].wakeup_seen
              && (oldest_unauthorized == null
                  || pending[scan_tag].enqueue_order < oldest_unauthorized.enqueue_order))
            oldest_unauthorized = pending[scan_tag];
        if (oldest_unauthorized == null) begin
          if (early_store_wakeup)
            cfg.reporter.fatal("[CACHE] multiple unconsumed early store wakeups");
          early_store_wakeup = 1'b1;
        end else begin
          oldest_unauthorized.wakeup_seen = 1'b1;
        end
      end
      return;
    end
    tag = sampled_pld.tag;
    if (pending.exists(tag))
      cfg.reporter.fatal($sformatf("[CACHE] duplicate live tag=0x%0h", tag));
    e = new(sampled_pld, next_enqueue_order++);
    if (plain_store(sampled_pld) && !sampled_pld.st_br_resolve
        && (wakeup_pulse || early_store_wakeup)) begin
      e.wakeup_seen = 1'b1;
      early_store_wakeup = 1'b0;
    end
    pending[tag] = e;
    cfg.print_cache(1, $sformatf(
        "[CACHE][LSU_ISSUE] tag=0x%0h prop=0x%0h rs1=0x%016h rs2=0x%016h imm=0x%016h auth=%0b",
        sampled_pld.tag, issue_property(sampled_pld),
        sampled_pld.rs1_data, sampled_pld.store_data, sampled_pld.imm_data,
        sampled_pld.st_br_resolve));
  endtask

  task run();
    next_be_phase_seq = phase_vif.dpi_be_phase_seq + 1;
    forever begin
      bit issue_fire;
      bit response_fire;
      bit wakeup_pulse;
      be_lsu_issue_pld_t sampled_pld;
      logic [MOCK_ROB_TAG_W-1:0] response_tag;

      @(posedge vif.clk);
      if (stop_requested)
        return;
      issue_fire = vif.rst_n && !vif.global_flush_late
          && vif.be_lsu_issue_valid && vif.lsu_be_issue_ready;
      sampled_pld = vif.be_lsu_issue_pld;
      wakeup_pulse = vif.rst_n && !vif.global_flush_late
          && vif.be_lsu_store_wakeup_valid;
      response_fire = vif.be_lsu_entry_ready
          && (vif.lsu_be_done_valid || vif.lsu_be_exception_valid);
      response_tag = vif.lsu_be_exception_valid
          ? vif.lsu_be_writeback_pld.tag
          : vif.lsu_be_writeback_pld.tag;
      #1;
      if (!vif.rst_n || vif.global_flush_late) begin
        clear_local_state();
        vif.lsu_be_issue_ready = 1'b0;
      end else begin
        if (response_fire) begin
          pending.delete(response_tag);
          vif.lsu_be_done_valid = 1'b0;
          vif.lsu_be_exception_valid = 1'b0;
          vif.lsu_be_bypass_valid = 1'b0;
        end
        accept_issue(issue_fire, sampled_pld, wakeup_pulse);
        vif.lsu_be_issue_ready = 1'b1;
      end

      if (model_exit_seen && pending.num() == 0
          && !vif.lsu_be_done_valid && !vif.lsu_be_exception_valid)
        return;

      @(negedge vif.clk);
      while (!stop_requested && phase_vif.dpi_be_phase_seq < next_be_phase_seq)
        @(phase_vif.dpi_be_phase_seq);
      if (stop_requested)
        return;
      next_be_phase_seq++;
      if (!vif.rst_n || vif.global_flush_late) begin
        clear_local_state();
      end else begin
        cycle_count++;
        service_oldest();
        drive_terminal_response();
        model_exit_seen = isa_dpi_is_to_exit() != 0;
      end
    end
  endtask

  task shutdown();
    stop_requested = 1'b1;
  endtask
endclass
