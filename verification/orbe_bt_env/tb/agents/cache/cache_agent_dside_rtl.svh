// [This file] cache_agent's D-side RTL service (DUT_KIND=rtl_cache / rtl_full), `included inside class cache_agent.
//
// OR_Cache RTL replaces this agent's D side (accept_issue / service_wakeup / service_store_buffer / drive_outputs no longer run;
// the LSU outputs of lsu_vif are driven by RTL instead). This section does three things, all in the negedge model phase, after be_agent advances dpi_be_phase_seq:
//   1. Model sync: on RTL events, issue the same set of calls as the original D side; the model remains the sole owner of architectural state
//        accept                     -> execute_insn; for load/LR also proc_mem_load + get_insn_rd_value (reference value saved first); for FENCE also proc_mem_req
//        ms_drain                   -> [AMO/SC: proc_mem_load] -> get_insn_pc -> store_commit -> clear_mem_reserve -> COSIM write observation
//        terminal state taken by BE -> compare; on exception compute the reference via the original agent's exception_chain and inject a trap if needed
//      [Integration revision I1] The read-side proc_mem_load is done in the accept cycle (same as the original agent): be_agent's model phase precedes this agent,
//      so an instruction depending on the load may execute in the model in the same cycle the load's terminal state is accepted; if the load has not fetched by then,
//      the model reads 0 (rv64ui-p-ld's ld→addi bypass). The value fetched in the accept cycle = memory + overlay of older in-flight stores, which under in-order
//      accept is the architectural value; on the RTL side O1 guarantees a younger store is not seen first.
//   2. CACHE_EQUIV: computes reference values in the original agent's call order and compares each transaction the RTL makes effective (done data / bypass /
//      exception cause+tval / drain order and write data / SC success / evicted lines). +CACHE_EQUIV=0 disables comparison (model sync continues).
//   3. Downstream: L2 line refill = read_mem_bank (read at response time, already including stores drained this cycle); PTW = get_priv -> translate_pte
//      (queried once each for LOAD and STORE); dirty line eviction = compared against read_mem_bank.
  localparam int unsigned DC_L2_LAT  = 6;   // fixed line refill latency (cycles)
  localparam int unsigned DC_PTW_LAT = 4;   // fixed page table walk latency (cycles)

  bit                    dside_rtl;
  virtual orbe_dc_mem_if dc_vif;

  typedef struct {
    bit                valid;
    lsu_req_property_t prop;
    logic [63:0]       vaddr;
    int                memop;
    logic [3:0]        len;
    logic [63:0]       rs2;
    longint unsigned   order;
    bit                exec_fail;
    bit                load_fail;     // read-side proc_mem_load failed (model already recorded the trap itself)
    bit                drained;
    bit                term;
    bit                rd_ref_valid;
    logic [63:0]       rd_ref;
  } dc_rec_t;
  dc_rec_t           dc_rec [1 << LSU_TAG_W];

  int unsigned       dc_l2_id  [$];
  longint unsigned   dc_l2_pa  [$];
  longint unsigned   dc_l2_due [$];
  int unsigned       dc_ptw_id  [$];
  longint unsigned   dc_ptw_vpn [$];
  longint unsigned   dc_ptw_due [$];
  longint unsigned   dc_cycle;

  bit                dq_enable;
  longint unsigned   dq_checked, dq_excp, dq_drain, dq_evict, dq_mismatch;

  function void attach_dside(virtual orbe_dc_mem_if v);
    int off;
    dc_vif    = v;
    dside_rtl = 1'b1;
    dc_cycle  = 0;
    dq_enable = 1'b1;
    if ($value$plusargs("CACHE_EQUIV=%d", off) && (off == 0)) begin
      dq_enable = 1'b0;
      $display("[CACHE_EQUIV] disabled by +CACHE_EQUIV=0");
    end
    dq_checked = 0; dq_excp = 0; dq_drain = 0; dq_evict = 0; dq_mismatch = 0;
    foreach (dc_rec[t]) dc_rec[t].valid = 1'b0;
    dc_l2_id.delete(); dc_l2_pa.delete(); dc_l2_due.delete();
    dc_ptw_id.delete(); dc_ptw_vpn.delete(); dc_ptw_due.delete();
    dc_vif.l2_req_ready    = 1'b1;
    dc_vif.ptw_req_ready   = 1'b1;
    dc_vif.l2_resp         = 1'b0;
    dc_vif.l2_resp_id      = '0;
    dc_vif.l2_resp_data    = '0;
    dc_vif.l2_resp_err     = 1'b0;
    dc_vif.ptw_resp        = 1'b0;
    dc_vif.ptw_resp_id     = '0;
    dc_vif.ptw_resp_ppn    = '0;
    dc_vif.ptw_resp_lvl    = or_cache_pkg::PG_4K;
    dc_vif.ptw_resp_rcause = '0;
    dc_vif.ptw_resp_wcause = '0;
  endfunction

  function void dq_error(string message);
    dq_mismatch++;
    if (dq_enable) cfg.reporter.error($sformatf("[CACHE_EQUIV] %s", message));
  endfunction

  function void dside_report();
    $display("[CACHE_EQUIV] checked=%0d (excp=%0d) drain=%0d evict=%0d mismatch=%0d%s",
             dq_checked, dq_excp, dq_drain, dq_evict, dq_enable ? dq_mismatch : 0,
             dq_enable ? "" : " (disabled)");
  endfunction

  // Glue logic records: all terminated and drained (or flushed)
  function automatic bit dside_idle();
    foreach (dc_rec[t]) if (dc_rec[t].valid) return 1'b0;
    return 1'b1;
  endfunction

  // Number of accepted, undrained store-side requests (same measure as the original D-side Store_Buffer occupancy, for I-side gating)
  function automatic int unsigned dside_store_pending();
    int unsigned n = 0;
    foreach (dc_rec[t])
      if (dc_rec[t].valid && req_property_is_store_side(dc_rec[t].prop) && !dc_rec[t].drained) n++;
    return n;
  endfunction

  function void dside_flush(bit is_reset);
    foreach (dc_rec[t]) dc_rec[t].valid = 1'b0;
    if (is_reset) begin
      dc_l2_id.delete(); dc_l2_pa.delete(); dc_l2_due.delete();
      dc_ptw_id.delete(); dc_ptw_vpn.delete(); dc_ptw_due.delete();
    end
  endfunction

  // ---------------------------------------------------------------------
  // Accept: execute_insn (address translation is done only once in the model; FAIL = model has recorded a trap)
  // ---------------------------------------------------------------------
  task automatic dside_accept();
    lsu_req_property_t p;
    lsu_tag_t          t;
    int                rc;
    p = issue_property();
    check_payload_self_consistent(p);
    t = vif.be_lsu_issue_pld.self_tag;
    if (dc_rec[t].valid)
      fail($sformatf("[DC_RTL] issue tag=%0d while an earlier request with this tag is still live", t));
    rc = isa_dpi_execute_insn(MODEL_CORE_ID, longint'(t));
    if (rc == ISA_API_SKIP)
      fail($sformatf("execute_insn tag=%0d returned SKIP; the RTL sent the LSU an instruction the model judged illegal or already faulted on fetch -- decode disagreement", t));
    if ((rc != ISA_API_PASS) && (rc != ISA_API_FAIL))
      fail($sformatf("execute_insn tag=%0d returned rc=%0d", t, rc));
    dc_rec[t].valid        = 1'b1;
    dc_rec[t].prop         = p;
    dc_rec[t].vaddr        = vaddr_in();
    dc_rec[t].memop        = memop_in();
    dc_rec[t].len          = len_in();
    dc_rec[t].rs2          = vif.be_lsu_issue_pld.rs2_data;
    dc_rec[t].order        = 0;
    if (req_property_is_store_side(p)) begin
      dc_rec[t].order = next_order;
      next_order++;
    end
    dc_rec[t].exec_fail    = (rc == ISA_API_FAIL);
    dc_rec[t].load_fail    = 1'b0;
    dc_rec[t].drained      = 1'b0;
    dc_rec[t].term         = 1'b0;
    dc_rec[t].rd_ref_valid = 1'b0;
    dc_rec[t].rd_ref       = '0;
    if (rc == ISA_API_PASS) begin
      if (p.is_load || p.is_lr) begin
        // Original agent [FSM-1]/[FSM-2]: fetch data in the accept cycle
        rc = isa_dpi_proc_mem_load(MODEL_CORE_ID, longint'(t));
        if (rc == ISA_API_SKIP)
          fail($sformatf("proc_mem_load tag=%0d returned SKIP on the read side", t));
        dc_rec[t].load_fail = (rc == ISA_API_FAIL);
        if (rc == ISA_API_PASS) begin
          dc_rec[t].rd_ref       = isa_dpi_get_insn_rd_value(MODEL_CORE_ID, longint'(t));
          dc_rec[t].rd_ref_valid = 1'b1;
        end
      end else if (p.is_fence || p.is_fence_i) begin
        // Original agent [FSM-3]
        rc = isa_dpi_proc_mem_req(MODEL_CORE_ID, longint'(t));
        if ((rc != ISA_API_PASS) && (rc != ISA_API_SKIP))
          fail($sformatf("proc_mem_req tag=%0d returned rc=%0d on a FENCE/FENCE.I", t, rc));
      end
    end
    cfg.print_cache(3, $sformatf("[DC_RTL][ACCEPT] tag=%0d vaddr=0x%0h exec_rc=%0d", t, dc_rec[t].vaddr, rc));
  endtask

  // ---------------------------------------------------------------------
  // Drain = model store_commit moment (same order as the original agent's [FSM-9] / [FSM-10])
  // ---------------------------------------------------------------------
  task automatic dside_drain();
    lsu_tag_t        t;
    int              rc;
    logic [63:0]     store_pc;
    logic [7:0]      mask;
    bit              model_sc_ok;
    t = dc_vif.ms_drain_tag;
    if (!dc_rec[t].valid || !req_property_is_store_side(dc_rec[t].prop) || dc_rec[t].drained) begin
      dq_error($sformatf("drain tag=%0d has no live, undrained store-side request", t));
      return;
    end
    // Landing order = program order: there must be no older undrained store-side request (including one that already reported an exception and is stuck at the head)
    foreach (dc_rec[u])
      if ((u != t) && dc_rec[u].valid && req_property_is_store_side(dc_rec[u].prop) &&
          !dc_rec[u].drained && (dc_rec[u].order < dc_rec[t].order))
        dq_error($sformatf("drain tag=%0d passes older store-side tag=%0d", t, u));
    if (dc_rec[t].exec_fail)
      dq_error($sformatf("drain tag=%0d whose execute_insn failed in the model", t));
    if ((dc_vif.ms_drain_kind == or_cache_pkg::K_STORE) != dc_rec[t].prop.is_store ||
        (dc_vif.ms_drain_kind == or_cache_pkg::K_AMO)   != dc_rec[t].prop.is_amo   ||
        (dc_vif.ms_drain_kind == or_cache_pkg::K_SC)    != dc_rec[t].prop.is_sc)
      dq_error($sformatf("drain tag=%0d kind=%0d disagrees with the request class", t, dc_vif.ms_drain_kind));

    if (!dc_rec[t].prop.is_store) begin
      rc = isa_dpi_proc_mem_load(MODEL_CORE_ID, longint'(t));
      if (rc != ISA_API_PASS)
        dq_error($sformatf("AMO/SC tag=%0d drained by RTL but proc_mem_load rc=%0d", t, rc));
      dc_rec[t].rd_ref       = isa_dpi_get_insn_rd_value(MODEL_CORE_ID, longint'(t));
      dc_rec[t].rd_ref_valid = 1'b1;
      if (dc_rec[t].prop.is_sc) begin
        model_sc_ok = (dc_rec[t].rd_ref == 64'd0);
        if (model_sc_ok != dc_vif.ms_drain_sc_ok)
          dq_error($sformatf("SC tag=%0d RTL success=%0b model success=%0b", t, dc_vif.ms_drain_sc_ok, model_sc_ok));
      end
    end
    mask = 8'hFF >> (8 - dc_rec[t].len);
    if ((dc_rec[t].prop.is_store || (dc_rec[t].prop.is_sc && dc_vif.ms_drain_sc_ok)) &&
        ((dc_vif.ms_drain_data ^ dc_rec[t].rs2) & {{8{mask[7]}}, {8{mask[6]}}, {8{mask[5]}}, {8{mask[4]}},
                                                    {8{mask[3]}}, {8{mask[2]}}, {8{mask[1]}}, {8{mask[0]}}}) != '0)
      dq_error($sformatf("drain tag=%0d write data 0x%016h, issued 0x%016h", t, dc_vif.ms_drain_data, dc_rec[t].rs2));

    store_pc = isa_dpi_get_insn_pc(MODEL_CORE_ID, longint'(t));
    rc = isa_dpi_store_commit(MODEL_CORE_ID);
    if (rc != ISA_API_PASS)
      dq_error($sformatf("drain tag=%0d: store_commit rc=%0d (model refused the store the RTL landed)", t, rc));
    if (isa_dpi_clear_mem_reserve(MODEL_CORE_ID) != ISA_API_PASS)
      fail($sformatf("clear_mem_reserve after store_commit tag=%0d failed", t));

    // COSIM write observation: fields identical to the original agent's publish_store_commit
    if (ob_cosim_vif.mem_store_commit_valid === 1'b1)
      fail("more than one store commit was produced in one cache observation phase");
    ob_cosim_vif.mem_store_commit_valid    = 1'b1;
    ob_cosim_vif.mem_store_commit_order    = dc_rec[t].order;
    ob_cosim_vif.mem_store_commit_vaddr    = dc_rec[t].vaddr;
    ob_cosim_vif.mem_store_commit_data     = dc_rec[t].rs2;
    ob_cosim_vif.mem_store_commit_mask     = mask;
    ob_cosim_vif.mem_store_commit_pc       = store_pc;
    ob_cosim_vif.mem_store_commit_rob_idx  = 64'(t);
    ob_cosim_vif.mem_store_commit_terminal = (isa_dpi_is_to_exit() != 0);

    dc_rec[t].drained = 1'b1;
    dq_drain++;
    cfg.print_cache(3, $sformatf("[DC_RTL][DRAIN] tag=%0d kind=%0d", t, dc_vif.ms_drain_kind));
  endtask

  // ---------------------------------------------------------------------
  // Terminal state accepted by BE: complete the original agent's read-side calls, compute the reference value and compare
  // ---------------------------------------------------------------------
  task automatic dside_terminal();
    bit              is_exc;
    lsu_tag_t        t;
    int              rc;
    bit              st_side, rd_side;
    logic [63:0]     ref_data;
    lsu_cause_t      ref_cause;
    logic [63:0]     ref_tval;
    byte unsigned    md_trap_valid;
    longint unsigned md_trap_cause, md_trap_tval;

    is_exc = (vif.lsu_be_exception_valid === 1'b1);
    t      = is_exc ? vif.lsu_be_exception_pld.tag : vif.lsu_be_done_pld.tag;
    if (!dc_rec[t].valid || dc_rec[t].term) begin
      dq_error($sformatf("terminal for tag=%0d that has no live request", t));
      return;
    end
    st_side = req_property_is_store_side(dc_rec[t].prop);
    rd_side = req_property_is_read_side(dc_rec[t].prop);
    dq_checked++;

    if (!is_exc) begin
      ref_data = '0;
      if (dc_rec[t].prop.is_fence || dc_rec[t].prop.is_fence_i) begin
        ref_data = '0;
      end else if (!st_side) begin
        if (dc_rec[t].exec_fail || dc_rec[t].load_fail)
          dq_error($sformatf("tag=%0d vaddr=0x%0h: RTL done but the model faulted (execute_fail=%0b load_fail=%0b)",
                             t, dc_rec[t].vaddr, dc_rec[t].exec_fail, dc_rec[t].load_fail));
        else
          ref_data = dc_rec[t].rd_ref;
      end else begin
        if (!dc_rec[t].drained)
          dq_error($sformatf("store-side tag=%0d done before it drained", t));
        ref_data = dc_rec[t].prop.is_store ? 64'd0 : dc_rec[t].rd_ref;
      end
      if (vif.lsu_be_done_pld.data !== ref_data)
        dq_error($sformatf("tag=%0d vaddr=0x%0h done data 0x%016h, reference 0x%016h",
                           t, dc_rec[t].vaddr, vif.lsu_be_done_pld.data, ref_data));
      if ((vif.lsu_be_bypass_valid === 1'b1) != rd_side)
        dq_error($sformatf("tag=%0d bypass_valid=%0b but read_side=%0b", t, vif.lsu_be_bypass_valid, rd_side));
      else if (rd_side && ((vif.lsu_be_bypass_pld.tag !== t) || (vif.lsu_be_bypass_pld.data !== vif.lsu_be_done_pld.data)))
        dq_error($sformatf("tag=%0d bypass payload differs from done", t));
      cfg.print_cache(3, $sformatf("[DC_RTL][DONE] tag=%0d data=0x%0h", t, vif.lsu_be_done_pld.data));
    end else begin
      dq_excp++;
      if (st_side && dc_rec[t].exec_fail &&
          (isa_dpi_get_execute_metadata(MODEL_CORE_ID, longint'(t), md_trap_valid, md_trap_cause, md_trap_tval) == ISA_API_PASS) &&
          (md_trap_valid != 0)) begin
        // Original agent [FSM-7]: the model already recorded a trap when execute failed; take the model's actual code
        ref_cause = lsu_cause_t'(md_trap_cause);
        ref_tval  = md_trap_tval;
      end else begin
        if (!st_side && !dc_rec[t].exec_fail && !dc_rec[t].load_fail)
          dq_error($sformatf("tag=%0d vaddr=0x%0h: RTL raised an exception but the model access passed", t, dc_rec[t].vaddr));
        // Original agent [FSM-2] / store-side failure branch: exception_chain computes cause/tval, injecting a trap if the model has not recorded one
        exception_chain(longint'(t), dc_rec[t].vaddr, dc_rec[t].memop, dc_rec[t].len, st_side, ref_cause, ref_tval);
      end
      if ((vif.lsu_be_exception_pld.cause !== ref_cause) || (vif.lsu_be_exception_pld.tval !== ref_tval))
        dq_error($sformatf("tag=%0d vaddr=0x%0h exception cause=%0d tval=0x%0h, reference cause=%0d tval=0x%0h",
                           t, dc_rec[t].vaddr, vif.lsu_be_exception_pld.cause, vif.lsu_be_exception_pld.tval,
                           ref_cause, ref_tval));
      if (vif.lsu_be_bypass_valid === 1'b1)
        dq_error($sformatf("tag=%0d bypass with an exception", t));
      cfg.print_cache(2, $sformatf("[DC_RTL][EXCEPTION] tag=%0d cause=%0d tval=0x%0h",
                                   t, vif.lsu_be_exception_pld.cause, vif.lsu_be_exception_pld.tval));
    end
    dc_rec[t].term = 1'b1;
    // Store-side requests that reported an exception are kept until flush (original agent: fault records do not retire), for the landing-order check
    if (!st_side || dc_rec[t].drained) dc_rec[t].valid = 1'b0;
  endtask

  // Model phase of a non-flush cycle: accept → drain → terminal state
  task automatic dside_phase();
    if ((vif.be_lsu_issue_valid === 1'b1) && (vif.lsu_be_issue_ready === 1'b1)) dside_accept();
    if (dc_vif.ms_drain_vld === 1'b1) dside_drain();
    if ((vif.lsu_be_done_valid === 1'b1) || (vif.lsu_be_exception_valid === 1'b1)) dside_terminal();
  endtask

  // ---------------------------------------------------------------------
  // Downstream: refill / PTW / eviction check (every cycle, including flush cycles; cleared during reset)
  // ---------------------------------------------------------------------
  function automatic void dside_ptw_query(input longint unsigned vpn,
                                          output logic [or_cache_pkg::PPN_W-1:0] ppn,
                                          output or_cache_pkg::pg_lvl_t lvl,
                                          output logic [4:0] rcause, output logic [4:0] wcause);
    int              rc;
    longint unsigned vaddr, paddr, paddr_w;
    longint unsigned pp0, pp1, pp2, pp3, pp4;
    longint unsigned pv0, pv1, pv2, pv3, pv4;
    byte unsigned    pte_update, levels, levels_w, trap_valid, fault_src, mem_type;
    longint unsigned trap_type, trap_tval, satp;
    byte unsigned    priv;
    int              root_lvl, leaf_lvl;
    vaddr = vpn << 12;
    priv  = isa_dpi_get_priv(MODEL_CORE_ID);
    rcause = '0; wcause = '0; lvl = or_cache_pkg::PG_4K;
    rc = isa_dpi_translate_pte(MODEL_CORE_ID, vaddr, longint'(priv), ISA_API_MEMOP_LOAD, 64'd1,
                               paddr, pp0, pp1, pp2, pp3, pp4, pv0, pv1, pv2, pv3, pv4,
                               pte_update, levels, trap_type, trap_tval, trap_valid, fault_src, mem_type);
    if (rc != ISA_API_PASS) fail($sformatf("[DC_RTL][PTW] translate_pte(LOAD) vaddr=0x%016h rc=%0d", vaddr, rc));
    if (trap_valid != 0) rcause = 5'(trap_type);
    rc = isa_dpi_translate_pte(MODEL_CORE_ID, vaddr, longint'(priv), ISA_API_MEMOP_STORE, 64'd1,
                               paddr_w, pp0, pp1, pp2, pp3, pp4, pv0, pv1, pv2, pv3, pv4,
                               pte_update, levels_w, trap_type, trap_tval, trap_valid, fault_src, mem_type);
    if (rc != ISA_API_PASS) fail($sformatf("[DC_RTL][PTW] translate_pte(STORE) vaddr=0x%016h rc=%0d", vaddr, rc));
    if (trap_valid != 0) wcause = 5'(trap_type);
    if (rcause != 0) begin paddr = paddr_w; levels = levels_w; end
    ppn = or_cache_pkg::PPN_W'(paddr >> 12);
    if (levels != 0) begin
      satp     = isa_dpi_get_csr(MODEL_CORE_ID, 16'h180);
      root_lvl = (satp[63:60] == 4'd9) ? 3 : 2;
      leaf_lvl = root_lvl + 1 - int'(levels);
      lvl = (leaf_lvl == 2) ? or_cache_pkg::PG_1G :
            (leaf_lvl == 1) ? or_cache_pkg::PG_2M : or_cache_pkg::PG_4K;
    end
    cfg.print_cache(2, $sformatf("[DC_RTL][PTW] vaddr=0x%016h priv=%0d -> ppn=0x%0h lvl=%0d rcause=%0d wcause=%0d",
                                 vaddr, priv, ppn, lvl, rcause, wcause));
  endfunction

  function void dside_mem_service();
    byte unsigned    line [0:or_cache_pkg::LINE_BYTES-1];
    longint unsigned trap;
    int              rc;
    logic [or_cache_pkg::LINE_W-1:0] data;
    logic [or_cache_pkg::PPN_W-1:0]  ppn;
    or_cache_pkg::pg_lvl_t           lvl;
    logic [4:0]                      rcause, wcause;
    longint unsigned                 epa;

    dc_cycle++;
    dc_vif.l2_resp  = 1'b0;
    dc_vif.ptw_resp = 1'b0;
    if (dc_vif.rst_n !== 1'b1) begin
      dside_flush(1'b1);
      return;
    end

    if (dc_vif.l2_req_vld === 1'b1) begin
      dc_l2_id.push_back(dc_vif.l2_req_id);
      dc_l2_pa.push_back(longint'(dc_vif.l2_req_pa_line) << or_cache_pkg::OFF_W);
      dc_l2_due.push_back(dc_cycle + DC_L2_LAT);
    end
    if (dc_vif.ptw_req_vld === 1'b1) begin
      dc_ptw_id.push_back(dc_vif.ptw_req_id);
      dc_ptw_vpn.push_back(longint'(dc_vif.ptw_req_vpn));
      dc_ptw_due.push_back(dc_cycle + DC_PTW_LAT);
    end

    // Eviction: the next level has already been updated by store_commit, so the evicted line must match model memory
    if (dc_vif.evict_vld === 1'b1) begin
      epa = longint'(dc_vif.evict_pa_line) << or_cache_pkg::OFF_W;
      rc  = isa_dpi_read_mem_bank(epa, or_cache_pkg::LINE_BYTES, line, trap);
      dq_evict++;
      if (rc != ISA_API_PASS) dq_error($sformatf("evicted line pa=0x%016h is not readable in the model", epa));
      else
        for (int i = 0; i < or_cache_pkg::LINE_BYTES; i++)
          if (dc_vif.evict_data[8*i +: 8] !== line[i]) begin
            dq_error($sformatf("evicted line pa=0x%016h byte %0d = 0x%02h, model memory 0x%02h",
                               epa, i, dc_vif.evict_data[8*i +: 8], line[i]));
            break;
          end
    end

    if ((dc_l2_id.size() != 0) && (dc_l2_due[0] <= dc_cycle)) begin
      rc   = isa_dpi_read_mem_bank(dc_l2_pa[0], or_cache_pkg::LINE_BYTES, line, trap);
      data = '0;
      if (rc == ISA_API_PASS)
        for (int i = 0; i < or_cache_pkg::LINE_BYTES; i++) data[8*i +: 8] = line[i];
      else
        cfg.reporter.error($sformatf("[DC_RTL][L2] read_mem_bank pa=0x%016h failed rc=%0d trap=%0d (PMA should have stopped this refill)",
                                     dc_l2_pa[0], rc, trap));
      dc_vif.l2_resp      = 1'b1;
      dc_vif.l2_resp_id   = or_cache_pkg::MSHR_ID_W'(dc_l2_id[0]);
      dc_vif.l2_resp_data = data;
      dc_vif.l2_resp_err  = (rc != ISA_API_PASS);
      cfg.print_cache(3, $sformatf("[DC_RTL][L2] resp id=%0d pa=0x%016h", dc_l2_id[0], dc_l2_pa[0]));
      void'(dc_l2_id.pop_front()); void'(dc_l2_pa.pop_front()); void'(dc_l2_due.pop_front());
    end

    if ((dc_ptw_id.size() != 0) && (dc_ptw_due[0] <= dc_cycle)) begin
      dside_ptw_query(dc_ptw_vpn[0], ppn, lvl, rcause, wcause);
      dc_vif.ptw_resp        = 1'b1;
      dc_vif.ptw_resp_id     = or_cache_pkg::TMQ_ID_W'(dc_ptw_id[0]);
      dc_vif.ptw_resp_ppn    = ppn;
      dc_vif.ptw_resp_lvl    = lvl;
      dc_vif.ptw_resp_rcause = rcause;
      dc_vif.ptw_resp_wcause = wcause;
      void'(dc_ptw_id.pop_front()); void'(dc_ptw_vpn.pop_front()); void'(dc_ptw_due.pop_front());
    end
  endfunction
