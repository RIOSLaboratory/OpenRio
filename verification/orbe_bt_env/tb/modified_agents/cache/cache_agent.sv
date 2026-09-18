// OR-BE LSU agent.
//
// It is the test double behind the G3 <-> LSU logical interface and the
// memory service front end of the shared ISA model.  One issue handshake
// carries the whole request, so there is no separate address/data pairing:
// the record is created, executed, serviced and retired under a single
// 4-bit tag.
//
// Ownership boundaries (unchanged from the reference environment):
//   - the shared model is created and destroyed elsewhere;
//   - model flush is driven by the BE agent alone;
//   - decode/issue and commit of non-memory work is not this agent's job.
//
// Deliberate departures from the reference environment, all forced by the
// OR-BE shape rather than by preference:
//   - no lane/dup mirrors, so no mirror consistency reconciliation;
//   - no separate store-data channel, so no "data for unknown record" case;
//   - a 4-bit tag with no epoch bit, so no modular age comparison;
//   - one terminal event per tag instead of a completion channel matrix;
//   - full flush only, so no younger/older partial cleanup.
class cache_pending;
  be_lsu_issue_pld_t pld;
  // Arrival order.  With a depth-1 issue queue upstream this is program
  // order, which is what lets the store FIFO head be the oldest store.
  longint unsigned order;

  logic [LSU_DATA_W-1:0] vaddr;

  bit executed;
  bit mem_load_done;
  bit mem_req_done;
  bit result_ready;
  logic [LSU_DATA_W-1:0] result;

  bit store_authorized;
  bit store_commit_done;
  bit authorization_wait_logged;

  bit operation_done;
  bit completion_queued;
  longint unsigned done_ready_cycle;

  bit exception_valid;
  lsu_cause_t exception_cause;
  logic [LSU_DATA_W-1:0] exception_tval;
  bit exception_sent;

  function new(be_lsu_issue_pld_t p, longint unsigned seq);
    pld = p;
    order = seq;
    vaddr = '0;
    executed = 1'b0;
    mem_load_done = 1'b0;
    mem_req_done = 1'b0;
    result_ready = 1'b0;
    result = '0;
    store_authorized = 1'b0;
    store_commit_done = 1'b0;
    authorization_wait_logged = 1'b0;
    operation_done = 1'b0;
    completion_queued = 1'b0;
    done_ready_cycle = 0;
    exception_valid = 1'b0;
    exception_cause = '0;
    exception_tval = '0;
    exception_sent = 1'b0;
  endfunction
endclass

class cache_agent #(int unsigned COSIM_ISSUE_NUM,
                    int unsigned COSIM_ROB_ADDR_W);
  localparam int unsigned MODEL_CORE_ID = 0;
  localparam int LSU_TAG_SPACE = 1 << LSU_TAG_W;
  virtual or_be_lsu_if vif;
  virtual ob_if phase_vif;
  virtual ob_cosim_if #(COSIM_ISSUE_NUM, COSIM_ROB_ADDR_W) ob_cosim_vif;
  be_config            cfg;

  // Whitelist of RISC-V synchronous exception numbers the model may name.
  //
  // An upper bound alone is not the same test: 14 and 16..19 are reserved and
  // are not causes, so passing one through would put a number on the wire that
  // no consumer can interpret.  The contract says anything outside the defined
  // set falls back to a write/read access fault, and the reference
  // environment's map_trap() implements exactly this set.
  function automatic bit is_defined_sync_cause(longint unsigned trap);
    case (trap)
      64'd0,  64'd1,  64'd2,  64'd3,  64'd4,  64'd5,  64'd6,  64'd7,
      64'd8,  64'd9,  64'd10, 64'd11, 64'd12, 64'd13, 64'd15,
      64'd20, 64'd21, 64'd22, 64'd23: return 1'b1;
      default:                        return 1'b0;
    endcase
  endfunction

  // A tag is a slot index, so the record table is indexed directly and a
  // non-null entry is exactly "this tag is live".
  cache_pending pending[LSU_TAG_SPACE];
  int order_fifo[$];   // every live tag, arrival order
  int store_fifo[$];   // store-side tags only, arrival order
  int done_queue[$];
  int exception_queue[$];

  bit early_store_wakeup_pending;

  longint unsigned next_order;
  longint unsigned cycle_count;
  longint unsigned next_be_phase_seq;

  bit flush_this_cycle;
  bit terminal_driven;
  int terminal_tag;

  bit model_exit_seen;
  bit stop_requested;

  function new(virtual or_be_lsu_if vif_, virtual ob_if phase_vif_,
               virtual ob_cosim_if #(COSIM_ISSUE_NUM, COSIM_ROB_ADDR_W)
                   ob_cosim_vif_, be_config cfg_);
    vif = vif_;
    phase_vif = phase_vif_;
    ob_cosim_vif = ob_cosim_vif_;
    cfg = cfg_;
    if (cfg == null)
      be_reporter::fatal_static("[CACHE] cache_agent requires a non-null be_config");
    // Tag uniqueness among live records is only guaranteed while the tag
    // space and the retire-ordering resource have the same size.  Catch a
    // parameter change here rather than as a corrupted record later.
    if (LSU_TAG_W != 4)
      cfg.reporter.fatal($sformatf("cache_agent assumes a 4-bit tag; got %0d", LSU_TAG_W));
    next_order = 0;
    cycle_count = 0;
    early_store_wakeup_pending = 1'b0;
    flush_this_cycle = 1'b0;
    terminal_driven = 1'b0;
    terminal_tag = 0;
    model_exit_seen = 1'b0;
    stop_requested = 1'b0;
    ob_cosim_vif.mem_store_commit_valid = 1'b0;
    ob_cosim_vif.mem_store_commit_order = '0;
    ob_cosim_vif.mem_store_commit_vaddr = '0;
    ob_cosim_vif.mem_store_commit_data = '0;
    ob_cosim_vif.mem_store_commit_mask = '0;
    ob_cosim_vif.mem_store_commit_pc = '0;
    ob_cosim_vif.mem_store_commit_rob_idx = '0;
    ob_cosim_vif.mem_store_commit_terminal = 1'b0;
    cfg.print_cache(1, "[CACHE] OR-BE LSU agent ready; shared model flush owner=BE");
  endfunction

  function automatic void fail(string message);
    cfg.reporter.fatal($sformatf("[CACHE] %s", message));
  endfunction

  // ------------------------------------------------------------------
  // Small helpers
  // ------------------------------------------------------------------

  // The model indexes an instruction by its own slot number.  OR-BE hands
  // out that same slot as tag, so no narrowing is involved; the wrapper
  // exists so a future width change has one place to change.
  function automatic longint unsigned dpi_rob_idx(input int tag);
    return longint'(tag);
  endfunction

  function automatic lsu_req_property_t issue_property(
      input be_lsu_issue_pld_t pld);
    return req_property_from_subop(pld.exe_subop);
  endfunction

  function automatic bit read_side(cache_pending e);
    return req_property_is_read_side(issue_property(e.pld));
  endfunction

  function automatic bit store_side(cache_pending e);
    return req_property_is_store_side(issue_property(e.pld));
  endfunction

  function automatic bit plain_store(cache_pending e);
    return req_property_is_plain_store(issue_property(e.pld));
  endfunction

  function automatic bit misc_side(cache_pending e);
    lsu_req_property_t p;
    p = issue_property(e.pld);
    return p.is_fence || p.is_fence_i;
  endfunction

  function automatic longint unsigned access_length(cache_pending e);
    return longint'(mem_funct3_bytes(e.pld.mem_funct3));
  endfunction

  function automatic logic [7:0] store_byte_mask(cache_pending e);
    logic [7:0] mask;
    int unsigned bytes;
    int unsigned offset;

    mask = '0;
    bytes = mem_funct3_bytes(e.pld.mem_funct3);
    offset = e.vaddr[2:0];
    for (int unsigned byte_idx = 0; byte_idx < bytes; byte_idx++) begin
      if ((offset + byte_idx) < 8)
        mask[offset + byte_idx] = 1'b1;
    end
    return mask;
  endfunction

  function automatic int model_memop(cache_pending e);
    case (lsu_memop_from_subop(e.pld.exe_subop))
      LSU_MEMOP_LOAD:                     return ISA_API_MEMOP_LOAD;
      LSU_MEMOP_STORE:                    return ISA_API_MEMOP_STORE;
      LSU_MEMOP_LR:                       return ISA_API_MEMOP_LOAD_RSV;
      LSU_MEMOP_SC:                       return ISA_API_MEMOP_STORE_CND;
      LSU_MEMOP_AMOSWAP:                  return ISA_API_MEMOP_AMOSWAP;
      LSU_MEMOP_AMOADD:                   return ISA_API_MEMOP_AMOADD;
      LSU_MEMOP_AMOXOR:                   return ISA_API_MEMOP_AMOXOR;
      LSU_MEMOP_AMOAND:                   return ISA_API_MEMOP_AMOAND;
      LSU_MEMOP_AMOOR:                    return ISA_API_MEMOP_AMOOR;
      LSU_MEMOP_AMOMIN:                   return ISA_API_MEMOP_AMOMIN;
      LSU_MEMOP_AMOMAX:                   return ISA_API_MEMOP_AMOMAX;
      LSU_MEMOP_AMOMINU:                  return ISA_API_MEMOP_AMOMINU;
      LSU_MEMOP_AMOMAXU:                  return ISA_API_MEMOP_AMOMAXU;
      // The model has no separate fence.i memory opcode; both fences use the
      // fence opcode for the translation query, which is all it feeds.
      LSU_MEMOP_FENCE, LSU_MEMOP_FENCE_I: return ISA_API_MEMOP_FENCE;
      default: return store_side(e) ? ISA_API_MEMOP_STORE : ISA_API_MEMOP_LOAD;
    endcase
  endfunction

  function automatic logic [23:0] canonical_exe_subop(input logic [23:0] raw);
    logic [23:0] canonical;
    canonical = raw;
    if (raw[23:22] == 2'b10) begin
      // The ISA model encodes RVC {funct3, op}; OR-BE stores only the
      // compressed quadrant op in this field.
      canonical[21:17] = 5'b0;
      canonical[11:0] = 12'b0;
    end
    return canonical;
  endfunction

  function automatic bit shared_model_lsu_payload_ready(cache_pending e);
    byte unsigned req_property;
    int unsigned exe_subop;
    byte unsigned mem_funct3;
    byte unsigned rd_is_fp;
    longint unsigned rs1_data;
    longint unsigned rs2_data;
    byte unsigned imm_valid;
    longint signed imm_data;
    byte unsigned is_store;
    logic [6:0] rtl_req_property;
    logic [23:0] rtl_exe_subop;
    logic [23:0] model_exe_subop;
    longint signed rtl_imm_data;
    int rc;

    rc = isa_dpi_get_lsu_issue_metadata(
        MODEL_CORE_ID, dpi_rob_idx(int'(e.pld.tag)), req_property, exe_subop,
        mem_funct3, rd_is_fp, rs1_data, rs2_data, imm_valid, imm_data,
        is_store);
    if (rc != ISA_API_PASS)
      fail($sformatf("get_lsu_issue_metadata tag=%0d rc=%0d", e.pld.tag, rc));

    rtl_req_property = issue_property(e.pld);
    rtl_exe_subop = canonical_exe_subop(e.pld.exe_subop);
    model_exe_subop = canonical_exe_subop(exe_subop[23:0]);
    rtl_imm_data = $signed(e.pld.imm_data);

    if ((req_property[6:0] !== rtl_req_property) ||
        (model_exe_subop !== rtl_exe_subop) ||
        (mem_funct3[2:0] !== e.pld.mem_funct3) ||
        ((rd_is_fp != 0) !== e.pld.rd_is_fp) ||
        (rs1_data !== e.pld.rs1_data) ||
        (store_side(e) && (rs2_data !== e.pld.store_data)) ||
        ((imm_valid != 0) !== e.pld.imm_valid) ||
        ((imm_valid != 0) && (imm_data != rtl_imm_data)) ||
        ((is_store != 0) !== plain_store(e))) begin
      cfg.print_cache(3, $sformatf(
          "[CACHE][WAIT_MODEL_LSU_META] cycle=%0d tag=%0d model={prop=0x%0h subop=0x%06h f3=0x%0h fp=%0b rs1=0x%016h rs2=0x%016h imm_v=%0b imm=0x%016h store=%0b} rtl={prop=0x%0h subop=0x%06h f3=0x%0h fp=%0b rs1=0x%016h rs2=0x%016h imm_v=%0b imm=0x%016h store=%0b}",
          cycle_count, e.pld.tag, req_property[6:0], model_exe_subop,
          mem_funct3[2:0], rd_is_fp != 0, rs1_data, rs2_data, imm_valid != 0,
          imm_data, is_store != 0, rtl_req_property, rtl_exe_subop,
          e.pld.mem_funct3, e.pld.rd_is_fp, e.pld.rs1_data, e.pld.store_data,
          e.pld.imm_valid, rtl_imm_data, plain_store(e)));
      return 1'b0;
    end

    return 1'b1;
  endfunction

  // Only the head of the store FIFO may touch memory.  The model store
  // buffer pops from its front without an index, so the caller must be the
  // oldest store-side record or the wrong entry would be drained.
  function automatic bit older_store_pending(cache_pending e);
    if (store_fifo.size() == 0) return 1'b0;
    return (store_fifo[0] != int'(e.pld.tag));
  endfunction

  // Occupancy of the write-side buffer: a store-side record holds a slot from
  // the moment it is accepted until it has actually landed in memory, not
  // until its completion is reported.
  function automatic int store_buffer_count();
    cache_pending e;
    int n;
    n = 0;
    foreach (store_fifo[i]) begin
      e = pending[store_fifo[i]];
      if ((e != null) && !e.store_commit_done) n++;
    end
    return n;
  endfunction

  // Occupancy of the read-side pipeline: one stage per record that has been
  // accepted but whose result has not been reported yet.
  function automatic int read_pipe_count();
    cache_pending e;
    int n;
    n = 0;
    foreach (order_fifo[i]) begin
      e = pending[order_fifo[i]];
      if ((e != null) && read_side(e)) n++;
    end
    return n;
  endfunction

  function automatic void queue_remove(ref int q[$], input int tag);
    for (int i = q.size() - 1; i >= 0; i--)
      if (q[i] == tag) q.delete(i);
  endfunction

  task automatic clear_all_state();
    for (int i = 0; i < LSU_TAG_SPACE; i++) pending[i] = null;
    order_fifo.delete();
    store_fifo.delete();
    done_queue.delete();
    exception_queue.delete();
    early_store_wakeup_pending = 1'b0;
    terminal_driven = 1'b0;
  endtask

  task automatic retire(cache_pending e);
    int tag = int'(e.pld.tag);
    queue_remove(order_fifo, tag);
    queue_remove(store_fifo, tag);
    queue_remove(done_queue, tag);
    pending[tag] = null;
  endtask

  // ------------------------------------------------------------------
  // Exception path
  // ------------------------------------------------------------------

  task automatic enqueue_exception(cache_pending e, longint unsigned trap,
                                   longint unsigned tval);
    int tag;
    if (e.exception_valid) return;
    tag = int'(e.pld.tag);
    e.exception_valid = 1'b1;
    e.exception_cause = lsu_cause_t'(trap);
    e.exception_tval = tval;
    exception_queue.push_back(tag);
    // Tell the model, unless it already found the fault itself.  An exception
    // this agent reports to the BE but the model never records leaves the two
    // out of step: the architectural state never takes the trap, and a
    // faulting store stays at the head of the model's store buffer, so every
    // later drain returns that same stuck entry and every later store looks
    // like it faulted too.  The BE agent injects fetch exceptions the same
    // way.  The read side is closed already -- proc_mem_load records its own
    // trap -- so in practice this fires for the write side.
    if (isa_dpi_has_trap(MODEL_CORE_ID, dpi_rob_idx(tag)) == 0) begin
      int trap_rc;
      trap_rc = isa_dpi_trigger_trap(MODEL_CORE_ID, dpi_rob_idx(tag), trap, tval);
      if (trap_rc != ISA_API_PASS)
        fail($sformatf("trap injection failed tag=%0d cause=%0d rc=%0d",
                       tag, trap, trap_rc));
    end
    cfg.print_cache(1, $sformatf("[CACHE] exception tag=%0d cause=%0d tval=0x%016h",
                                 e.pld.tag, trap, tval));
  endtask

  // Turn a model refusal into exactly one architectural exception.  The
  // translation query is read-only; when it cannot name a cause the write
  // side falls back to a store fault and everything else to a load fault, so
  // this path can never return without producing an exception.
  task automatic translate_exception(cache_pending e);
    longint unsigned paddr;
    longint unsigned pte_paddr0, pte_paddr1, pte_paddr2, pte_paddr3, pte_paddr4;
    longint unsigned pte_value0, pte_value1, pte_value2, pte_value3, pte_value4;
    longint unsigned trap_type, trap_tval;
    byte unsigned pte_update, levels, trap_valid, fault_src, mem_type;
    int rc;

    paddr = '0; pte_paddr0 = '0; pte_paddr1 = '0; pte_paddr2 = '0;
    pte_paddr3 = '0; pte_paddr4 = '0; pte_value0 = '0; pte_value1 = '0;
    pte_value2 = '0; pte_value3 = '0; pte_value4 = '0; pte_update = '0;
    levels = '0; trap_type = '0; trap_valid = '0; fault_src = '0; mem_type = '0;
    trap_tval = e.vaddr;

    rc = isa_dpi_translate_pte(MODEL_CORE_ID, e.vaddr,
          isa_dpi_get_priv(MODEL_CORE_ID), model_memop(e), access_length(e),
          paddr, pte_paddr0, pte_paddr1, pte_paddr2, pte_paddr3, pte_paddr4,
          pte_value0, pte_value1, pte_value2, pte_value3, pte_value4,
          pte_update, levels, trap_type, trap_tval, trap_valid, fault_src,
          mem_type);

    if ((rc != ISA_API_PASS) || (trap_valid == 1'b0) ||
        !is_defined_sync_cause(trap_type)) begin
      trap_type = store_side(e) ? 64'd7 : 64'd5;
      trap_tval = e.vaddr;
    end
    enqueue_exception(e, trap_type, trap_tval);
  endtask

  task automatic enqueue_completion(cache_pending e);
    int unsigned delay_cycles;
    if (e.completion_queued || e.exception_valid) return;
    e.completion_queued = 1'b1;
    delay_cycles = store_side(e) ? cfg.cache_store_done_delay_cycles
                                 : cfg.cache_load_return_delay_cycles;
    e.done_ready_cycle = cycle_count + delay_cycles;
    done_queue.push_back(int'(e.pld.tag));
    cfg.print_cache(3, $sformatf("[CACHE][QUEUE] tag=%0d read=%0b store=%0b data=0x%016h ready_cycle=%0d",
                                 e.pld.tag, read_side(e), store_side(e),
                                 e.result, e.done_ready_cycle));
  endtask

  // ------------------------------------------------------------------
  // Input sampling
  // ------------------------------------------------------------------

  // The untagged authorization names the oldest plain store still waiting
  // for one.  When that store has not been issued yet the permit is held in
  // the single pre-issue slot and consumed on arrival.
  task automatic sample_store_wakeup();
    cache_pending e;
    bit consumed;
    if (vif.be_lsu_store_wakeup_valid !== 1'b1) return;
    consumed = 1'b0;
    foreach (store_fifo[i]) begin
      e = pending[store_fifo[i]];
      if (e == null) continue;
      if (!plain_store(e)) continue;
      if (e.pld.st_br_resolve === 1'b1) continue;
      if (e.store_authorized) continue;
      e.store_authorized = 1'b1;
      consumed = 1'b1;
      cfg.print_cache(3, $sformatf("[CACHE][WAKEUP] cycle=%0d tag=%0d authorized",
                                   cycle_count, e.pld.tag));
      break;
    end
    if (consumed) return;
    if (early_store_wakeup_pending)
      fail($sformatf("second store wakeup at cycle %0d while one pre-issue authorization is still unconsumed",
                     cycle_count));
    early_store_wakeup_pending = 1'b1;
    cfg.print_cache(3, $sformatf("[CACHE][WAKEUP] cycle=%0d held for the next unresolved plain store",
                                 cycle_count));
  endtask

  task automatic accept_issue();
    be_lsu_issue_pld_t pld;
    lsu_req_property_t prop;
    cache_pending e;
    int tag;

    if (vif.be_lsu_issue_valid !== 1'b1) return;
    if (vif.lsu_be_issue_ready !== 1'b1) return;

    pld = vif.be_lsu_issue_pld;
    prop = issue_property(pld);
    tag = int'(pld.tag);

    if (pending[tag] != null)
      fail($sformatf("tag %0d issued again while its record is still live", tag));
    if (!req_property_is_onehot(prop))
      fail($sformatf("tag=%0d exe_subop 0x%06h does not map to one request property",
                     tag, pld.exe_subop));
    if (!mem_funct3_matches_subop(pld.mem_funct3, pld.exe_subop))
      fail($sformatf("tag=%0d mem_funct3 %03b does not match exe_subop 0x%06h",
                     tag, pld.mem_funct3, pld.exe_subop));
    if (!prop.is_store && (pld.st_br_resolve === 1'b1))
      fail($sformatf("tag=%0d carries st_br_resolve but is not a plain store", tag));

    e = new(pld, next_order++);
    // The address generator lives on this side of the interface: the BE
    // hands over the base and the final byte offset, never the address.
    e.vaddr = (pld.imm_valid === 1'b1) ? (pld.rs1_data + $unsigned(pld.imm_data))
                                       : pld.rs1_data;

    if (store_side(e)) begin
      if (!plain_store(e)) begin
        // Atomics are serialized upstream, so their write side needs no
        // separate permit; requiring one here would deadlock them.
        e.store_authorized = 1'b1;
      end else if (pld.st_br_resolve === 1'b1) begin
        e.store_authorized = 1'b1;
      end else if (early_store_wakeup_pending) begin
        e.store_authorized = 1'b1;
        early_store_wakeup_pending = 1'b0;
        cfg.print_cache(3, $sformatf("[CACHE][WAKEUP] tag=%0d consumed the held authorization", tag));
      end
    end

    // Capacity is advertised through the acceptance line, so exceeding it
    // means the BE issued into a refusal.
    if (store_side(e) && (store_buffer_count() >= LSU_STORE_BUFFER_DEPTH))
      fail($sformatf("tag=%0d accepted while the store buffer already holds %0d entries; the BE issued into a lowered acceptance line",
                     tag, LSU_STORE_BUFFER_DEPTH));
    if (read_side(e) && (read_pipe_count() >= LSU_LOAD_PIPE_STAGES))
      fail($sformatf("tag=%0d accepted while %0d read-side records are already in the pipeline",
                     tag, LSU_LOAD_PIPE_STAGES));

    pending[tag] = e;
    order_fifo.push_back(tag);
    if (store_side(e)) store_fifo.push_back(tag);

    cfg.print_cache(3, $sformatf("[CACHE][ISSUE] cycle=%0d tag=%0d order=%0d subop=0x%06h vaddr=0x%016h len=%0d read=%0b store=%0b fp=%0b auth=%0b",
                                 cycle_count, tag, e.order, pld.exe_subop, e.vaddr,
                                 access_length(e), read_side(e), store_side(e),
                                 pld.rd_is_fp, e.store_authorized));
  endtask

  // ------------------------------------------------------------------
  // Model execution and memory service
  // ------------------------------------------------------------------

  // Every operand arrives with the request, so a record can execute as soon
  // as it exists.  This is the single point where an architectural fault is
  // detected; nothing downstream invents one.
  task automatic execute_pending();
    cache_pending e;
    int rc;
    foreach (order_fifo[i]) begin
      e = pending[order_fifo[i]];
      if (e == null) continue;
      if (e.executed || e.exception_valid) continue;
      if (!shared_model_lsu_payload_ready(e)) continue;
      rc = isa_dpi_execute_insn(MODEL_CORE_ID, dpi_rob_idx(int'(e.pld.tag)));
      cfg.print_cache(3, $sformatf("[CACHE][EXEC] tag=%0d rc=%0d", e.pld.tag, rc));
      if (rc == ISA_API_PENDING) continue;
      if (rc != ISA_API_PASS) begin
        cfg.print_cache(1, $sformatf("[CACHE][EXEC_FAIL] tag=%0d rc=%0d subop=0x%06h vaddr=0x%016h",
                                     e.pld.tag, rc, e.pld.exe_subop, e.vaddr));
        translate_exception(e);
        continue;
      end
      e.executed = 1'b1;
    end
  endtask

  // Is another store-side record sitting on a reported fault?  Its model
  // store-buffer entry survives until the trap-driven flush pops it, so any
  // drain attempted while one is parked would hit that entry instead of the
  // caller's.  Used to refuse translating a drain refusal into a cause.
  function automatic bit faulted_store_parked(cache_pending self);
    cache_pending o;
    for (int i = 0; i < LSU_TAG_SPACE; i++) begin
      o = pending[i];
      if ((o != null) && (o != self) && o.exception_valid && store_side(o))
        return 1'b1;
    end
    return 1'b0;
  endfunction

  task automatic commit_store(cache_pending e);
    int rc;
    logic [63:0] store_pc;
    logic [7:0] store_mask;
    if (e.store_commit_done) return;
    if (older_store_pending(e)) return;
    store_pc = isa_dpi_get_insn_pc(MODEL_CORE_ID, dpi_rob_idx(int'(e.pld.tag)));
    store_mask = store_byte_mask(e);
    cfg.print_cache(3, $sformatf("[CACHE][STORE_COMMIT] cycle=%0d tag=%0d vaddr=0x%016h data=0x%016h",
                                 cycle_count, e.pld.tag, e.vaddr, e.pld.store_data));
    rc = isa_dpi_store_commit(MODEL_CORE_ID);
    if (rc != ISA_API_PASS) begin
      // One return code, three different failures: an empty buffer, a head
      // entry whose executeInsn has not run, or the drain itself being
      // rejected.  Only the last is an architectural fault, and for a plain
      // store in bare mode it is the only place that fault can surface.
      // Turning a refusal into a cause without first ruling the other two out
      // is how a healthy store acquires a fabricated fault, so prove them
      // impossible before translating -- and report a testbench error when the
      // proof does not hold, rather than inventing an exception.
      //
      //   - this record is the write-side head and has executed, so the
      //     model's head entry is this request and it is data-ready;
      //   - no faulting store-side record is parked ahead of it (a faulted
      //     record is deliberately never retired so this stays true).
      //
      // Both already hold on this path.  Re-checking them means a later change
      // to the gates above fails loudly instead of silently forging a cause.
      // The model prints which of the three failures it was.
      if (older_store_pending(e) || !e.executed || faulted_store_parked(e))
        fail($sformatf("store_commit refused tag=%0d rc=%0d while this request was not the drainable write-side head; this is a testbench ordering fault, not an architectural one -- see the model's storeCommit diagnostic for which failure it was",
                       e.pld.tag, rc));
      translate_exception(e);
      return;
    end
    // Any successful write-side commit drops an outstanding reservation.
    if (isa_dpi_clear_mem_reserve(MODEL_CORE_ID) != ISA_API_PASS)
      fail($sformatf("clear_mem_reserve after store_commit tag=%0d failed", e.pld.tag));
    e.store_commit_done = 1'b1;
    if (ob_cosim_vif.mem_store_commit_valid === 1'b1)
      fail("more than one store commit was produced in one cache observation phase");
    ob_cosim_vif.mem_store_commit_valid = 1'b1;
    ob_cosim_vif.mem_store_commit_order = e.order;
    ob_cosim_vif.mem_store_commit_vaddr = e.vaddr;
    ob_cosim_vif.mem_store_commit_data = e.pld.store_data;
    ob_cosim_vif.mem_store_commit_mask = store_mask;
    ob_cosim_vif.mem_store_commit_pc = store_pc;
    ob_cosim_vif.mem_store_commit_rob_idx = e.pld.tag;
    ob_cosim_vif.mem_store_commit_terminal = isa_dpi_is_to_exit() != 0;
  endtask

  task automatic log_authorization_wait(cache_pending e);
    if (e.authorization_wait_logged) return;
    e.authorization_wait_logged = 1'b1;
    cfg.print_cache(3, $sformatf("[CACHE][WAIT_AUTH] tag=%0d waiting for the store authorization",
                                 e.pld.tag));
  endtask

  task automatic service_memory_ops();
    cache_pending e;
    int rc;
    int tag;
    foreach (order_fifo[i]) begin
      tag = order_fifo[i];
      e = pending[tag];
      if (e == null) continue;
      if (!e.executed || e.operation_done || e.exception_valid) continue;

      if (read_side(e)) begin
        // An atomic reads and writes the same location.  Letting it read
        // before an older store has drained would show it stale memory, so
        // its read waits for the store FIFO head.  A plain load and an LR do
        // not wait: the model forwards from its own store buffer.
        if (store_side(e) && older_store_pending(e)) continue;

        if (!e.mem_load_done) begin
          rc = isa_dpi_proc_mem_load(MODEL_CORE_ID, dpi_rob_idx(tag));
          if (rc == ISA_API_SKIP)
            rc = isa_dpi_proc_mem_req(MODEL_CORE_ID, dpi_rob_idx(tag));
          cfg.print_cache(3, $sformatf("[CACHE][MEM_LOAD] tag=%0d rc=%0d", tag, rc));
          if (rc == ISA_API_PENDING) continue;
          if (rc != ISA_API_PASS) begin
            translate_exception(e);
            continue;
          end
          e.mem_load_done = 1'b1;
          e.result = isa_dpi_get_insn_rd_value(MODEL_CORE_ID, dpi_rob_idx(tag));
          e.result_ready = 1'b1;
          cfg.print_cache(3, $sformatf("[CACHE][MEM_LOAD] tag=%0d rd=0x%016h", tag, e.result));
        end

        if (store_side(e) && !e.store_commit_done) begin
          if (!e.store_authorized) begin
            log_authorization_wait(e);
            continue;
          end
          if (older_store_pending(e)) continue;
          commit_store(e);
        end

        if (!store_side(e) || e.store_commit_done) begin
          e.operation_done = 1'b1;
          enqueue_completion(e);
        end

      end else if (store_side(e)) begin
        if (!e.store_authorized) begin
          log_authorization_wait(e);
          continue;
        end
        if (older_store_pending(e)) continue;
        commit_store(e);
        e.operation_done = 1'b1;
        enqueue_completion(e);

      end else if (misc_side(e)) begin
        if (!e.mem_req_done) begin
          rc = isa_dpi_proc_mem_req(MODEL_CORE_ID, dpi_rob_idx(tag));
          cfg.print_cache(3, $sformatf("[CACHE][MEM_REQ] tag=%0d rc=%0d", tag, rc));
          if (rc == ISA_API_PENDING) continue;
          if ((rc != ISA_API_PASS) && (rc != ISA_API_SKIP)) begin
            translate_exception(e);
            continue;
          end
          e.mem_req_done = 1'b1;
        end
        e.operation_done = 1'b1;
        enqueue_completion(e);

      end else begin
        fail($sformatf("tag=%0d has no serviceable class; req_property=0x%0h subop=0x%06h",
                       tag, issue_property(e.pld), e.pld.exe_subop));
      end
    end
  endtask

  // ------------------------------------------------------------------
  // Flush
  // ------------------------------------------------------------------

  task automatic service_flush(output bit flush_event);
    flush_event = (vif.global_flush_late === 1'b1);
    if (!flush_event) return;
    cfg.print_cache(2, $sformatf("[CACHE][FLUSH] cycle=%0d local_only live=%0d done_q=%0d excp_q=%0d owner=BE",
                                 cycle_count, order_fifo.size(), done_queue.size(),
                                 exception_queue.size()));
    clear_all_state();
  endtask

  // ------------------------------------------------------------------
  // Output driving
  // ------------------------------------------------------------------

  task automatic drive_outputs();
    cache_pending e;
    int tag;
    int idx;

    vif.lsu_be_done_valid_q <= 1'b0;
    vif.lsu_be_exception_valid_q <= 1'b0;
    vif.lsu_be_writeback_pld <= '0;
    vif.lsu_be_bypass_valid_q <= 1'b0;
    vif.lsu_be_bypass_pld <= '0;

    terminal_driven = 1'b0;

    // Nothing is presented on a flush cycle; the BE is not accepting and the
    // records that would have completed are already gone.
    if (!vif.rst_n || flush_this_cycle) return;

    // At most one terminal event per cycle, faults first so a trap reaches
    // the BE without queueing behind ordinary completions.
    while (exception_queue.size() != 0) begin
      tag = exception_queue.pop_front();
      e = pending[tag];
      if (e == null) continue;                 // already flushed away
      if (!e.exception_valid || e.exception_sent) continue;
      e.exception_sent = 1'b1;
      vif.lsu_be_exception_valid_q <= 1'b1;
      vif.lsu_be_writeback_pld.tag <= e.pld.tag;
      vif.lsu_be_writeback_pld.done_valid <= 1'b0;
      vif.lsu_be_writeback_pld.data <= '0;
      vif.lsu_be_writeback_pld.exception_valid <= 1'b1;
      vif.lsu_be_writeback_pld.exception_cause <= e.exception_cause;
      vif.lsu_be_writeback_pld.exception_tval <= e.exception_tval;
      terminal_driven = 1'b1;
      terminal_tag = tag;
      cfg.print_cache(2, $sformatf("[CACHE][EXCP_OUT] cycle=%0d tag=%0d cause=%0d tval=0x%016h",
                                   cycle_count, tag, e.exception_cause, e.exception_tval));
      // The faulting record keeps its place. A store-side one therefore
      // holds the store FIFO head and stalls every younger write until the
      // trap-driven flush arrives, which is what keeps memory consistent.
      return;
    end

    for (idx = 0; idx < done_queue.size(); idx++) begin
      tag = done_queue[idx];
      e = pending[tag];
      if (e == null) continue;
      if (e.done_ready_cycle > cycle_count) continue;

      vif.lsu_be_done_valid_q <= 1'b1;
      vif.lsu_be_writeback_pld.tag <= e.pld.tag;
      vif.lsu_be_writeback_pld.done_valid <= 1'b1;
      vif.lsu_be_writeback_pld.data <= read_side(e) ? e.result : '0;
      vif.lsu_be_writeback_pld.exception_valid <= 1'b0;
      vif.lsu_be_writeback_pld.exception_cause <= '0;
      vif.lsu_be_writeback_pld.exception_tval <= '0;
      // The broadcast rides this one cycle and is never repeated, so it is
      // only meaningful for a request that produced a register result.
      if (read_side(e)) begin
        vif.lsu_be_bypass_valid_q <= 1'b1;
        vif.lsu_be_bypass_pld.tag <= e.pld.tag;        vif.lsu_be_bypass_pld.data <= e.result;
      end
      terminal_driven = 1'b1;
      terminal_tag = tag;
      cfg.print_cache(2, $sformatf("[CACHE][DONE_OUT] cycle=%0d tag=%0d read=%0b data=0x%016h",
                                   cycle_count, tag, read_side(e),
                                   read_side(e) ? e.result : 64'd0));
      retire(e);
      return;
    end
  endtask

  // ------------------------------------------------------------------
  // Main loop
  // ------------------------------------------------------------------

  task run();
    vif.lsu_store_buffer_full <= 1'b0;
    vif.lsu_be_done_valid_q <= 1'b0;
    vif.lsu_be_exception_valid_q <= 1'b0;
    vif.lsu_be_writeback_pld <= '0;
    vif.lsu_be_bypass_valid_q <= 1'b0;
    vif.lsu_be_bypass_pld <= '0;
    clear_all_state();
    cycle_count = 0;
    next_be_phase_seq = phase_vif.dpi_be_phase_seq + 1;

    forever begin
      bit flush_event;
      bit entry_ready;

      // The BE and this agent share one model, so every model call has to sit
      // inside a phase the BE has already finished.
      @(negedge vif.clk);
      while (!stop_requested &&
             (phase_vif.dpi_be_phase_seq < next_be_phase_seq))
        @(phase_vif.dpi_be_phase_seq);
      if (stop_requested) return;
      next_be_phase_seq++;

      if (!vif.rst_n) begin
        clear_all_state();
        cycle_count = 0;
        flush_this_cycle = 1'b0;
        model_exit_seen = 1'b0;
      end else begin
        cycle_count++;
        entry_ready = (vif.be_lsu_entry_ready === 1'b1);
        flush_event = 1'b0;
        service_flush(flush_event);

        // A terminal event is presented once and never repeated, so the BE
        // must have been accepting on the cycle it appeared.  The only
        // sanctioned refusal is a flush, and that discards the record too.
        if (terminal_driven && !entry_ready && !flush_event)
          fail($sformatf("terminal event for tag=%0d was presented at cycle %0d but be_lsu_entry_ready was low without a flush",
                         terminal_tag, cycle_count - 1));
        terminal_driven = 1'b0;
        flush_this_cycle = flush_event;

        if (!flush_event) begin
          sample_store_wakeup();
          accept_issue();
          execute_pending();
          service_memory_ops();
        end

        // Queried inside the model phase on purpose; the driving edge below
        // only presents what this phase computed.
        model_exit_seen = (isa_dpi_is_to_exit() != 0);
      end

      @(posedge vif.clk);
      if (stop_requested) return;
      // Acceptance itself is combinational in the offered request's class
      // (see or_be_lsu_if.sv); only the full/not-full state is registered
      // here.  The read side has no stalling resource, so it never appears.
      vif.lsu_store_buffer_full <=
          vif.rst_n && (store_buffer_count() >= LSU_STORE_BUFFER_DEPTH);
      drive_outputs();

      // A tohost write can end the model in the same phase that queued the
      // response for it, so stay alive until everything queued has been
      // presented.
      if (vif.rst_n && model_exit_seen && (done_queue.size() == 0) &&
          (exception_queue.size() == 0))
        return;
    end
  endtask

  task shutdown();
    stop_requested = 1'b1;
  endtask
endclass
