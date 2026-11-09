// [This file] Agent on the BE↔LSU interface
// CacheAgent.
//
// LSU behavioral proxy with a single issue lane and a 4-entry Store_Buffer: receives memory requests delivered by BE,
// calls the ISA Model to perform the access, and returns completion or exception to BE.
//
// Mapping between this file and the contract:
//   - `Data structure -> State/Header/Payload`  -> class members
//   - item N of `FSM -> Detailed Condition Description` -> the evaluation segment tagged [FSM-N]
//   - the 6 steps of item 3 of `Interface -> Interface Timing` -> the negedge phase of run()
//   - the presentation rules of item 4 of `Interface -> Interface Timing` -> the posedge phase of run()
//
// Zero-time calls: each instruction class goes through all calls possible in the accept cycle within that cycle; within one
// cycle the same Call with the same arguments is issued only once (contract Interface Timing item 8), so every DPI return
// value is first stored in a local variable before being used in decisions.
//
// Generation-time decisions (three items left open in the contract):
//   [R1] dpi_be_phase_seq width is 64, based on the `longint unsigned` declaration
//        in tb/interfaces/ob_if.sv.
//   [R3a] "does the model side record 7 for AMO" -> no. isa_model's
//        FuncMultiCore::procMemLoad failure path unconditionally records LOAD_ACCESS_FAULT(5),
//        with no special case for AMO. Per the contract we report the spec-correct 7, the model keeps 5; the difference is a
//        model defect, and an L2 log is printed on fire to make it visible in triage.
//   [R3b] "should we read isa_dpi_get_execute_metadata instead to get the model's actual code" -> yes.
//        When execute_insn returns FAIL the model must already have recorded a trap, and that code is spec-correct in both
//        sub-cases (MMU class 13/15/5/7/20/23; FSW/FSD with mstatus.FS==Off records 2 -- 2 is
//        illegal instruction, exactly the spec answer; the fallback code 7 would actually be wrong). When not injecting,
//        the model's code is authoritative, consistent with the contract principle "the model keeps its own code".

// Semantic state of a Store_Buffer entry (contract Data structure -> State item 1).
// 2-bit encoding; only store_side requests occupy an entry.
typedef enum logic [1:0] {
  CACHE_IDLE          = 2'b00,
  CACHE_STORE_PENDING = 2'b01,
  CACHE_STORE_WAKEUP  = 2'b10,
  CACHE_FAULTED       = 2'b11
} cache_entry_state_e;

// One Store_Buffer entry: contract Data structure State item 1 (state),
// Header items 1/2 (tag, req_property), Payload item 1 (vaddr/memop/len).
class cache_sb_entry;
  cache_entry_state_e    state;
  lsu_tag_t              tag;
  lsu_req_property_t     req_property;
  // Payload keeps only the three derived values exception_chain needs, contract Payload item 1.
  logic [LSU_DATA_W-1:0] vaddr;
  int                    memop;
  logic [3:0]            len;
  // store_data / order are used by the COSIM mem_store_commit_* observation surface.
  logic [LSU_DATA_W-1:0] store_data;
  longint unsigned       order;

  function new();
    state        = CACHE_IDLE;
    tag          = '0;
    req_property = '0;
    vaddr        = '0;
    memop        = 0;
    len          = '0;
    store_data   = '0;
    order        = 0;
  endfunction
endclass

// One record in the presentation buffer (contract Interface Timing item 4).
class cache_wb_record;
  // [R7] Writeback payload split by type. is_exception selects which field is valid; the other does not need to be cleared
  // to be correct -- it is never presented on the corresponding set of ports at all.
  bit                    is_exception;
  lsu_be_done_pld_t      done_pld;   // valid when is_exception = 0
  lsu_be_exception_pld_t exc_pld;    // valid when is_exception = 1
  bit                    has_bypass;
  lsu_be_done_pld_t      bypass_pld;
  longint unsigned       ready_cycle;

  function new();
    is_exception = 1'b0;
    done_pld     = '0;
    exc_pld      = '0;
    has_bypass   = 1'b0;
    bypass_pld   = '0;
    ready_cycle  = 0;
  endfunction
endclass

class cache_agent #(int unsigned COSIM_ISSUE_NUM,
                    int unsigned COSIM_ROB_ADDR_W);
  localparam int unsigned MODEL_CORE_ID = 0;

  virtual or_be_lsu_if vif;
  virtual ob_if        phase_vif;
  virtual ob_cosim_if #(COSIM_ISSUE_NUM, COSIM_ROB_ADDR_W) ob_cosim_vif;
  be_config            cfg;

  // ---------------------------------------------------------------------
  // Data structure -> State
  // ---------------------------------------------------------------------
  cache_sb_entry   entry[LSU_STORE_BUFFER_DEPTH];   // item 1
  logic [2:0]      alloc_ptr;                       // item 2 {loopbit, idx[1:0]}
  logic [2:0]      commit_ptr;                      // item 3
  bit              early_wakeup_slot;               // item 4
  bit              model_exit_seen;                 // item 5

  // Presentation buffer: exceptions and completions queue separately; within a class, entry order is kept (Interface Timing item 4).
  cache_wb_record  exc_buf[$];
  cache_wb_record  done_buf[$];

  longint unsigned cycle_count;
  longint unsigned next_order;
  longint unsigned next_be_phase_seq;   // [R1] 64 bit, matches ob_if
  bit              presented_last_cycle;
  lsu_tag_t        presented_last_tag;
  bit              stop_requested;

`ifdef ORBE_CACHE_RTL
  // D-side RTL service (DUT_KIND=rtl_cache / rtl_full): OR_Cache RTL replaces this agent's D side;
  // this agent only does model sync, CACHE_EQUIV and downstream responses. See that file's header comment.
  `include "cache_agent_dside_rtl.svh"
`endif

`ifdef ORBE_FE_RTL
  // ---------------------------------------------------------------------
  // I-side service (DUT_KIND=rtl_fe): OR_FE RTL's L2 line refill (L2 ICache) and PTW (L2TLB)
  // are answered by this agent calling the ISA model: line data = isa_dpi_read_mem_bank, translation =
  // isa_dpi_translate_pte (see if_ptw_query).
  // Shares the negedge model phase with the D side, ordered after service_store_buffer(), so the physical memory
  // read already includes stores landed this cycle; and it answers only when the Store_Buffer is empty, guaranteeing
  // that stores before fence.i / page table updates have all reached memory.
  // ---------------------------------------------------------------------
  localparam int unsigned IF_L2_LAT  = 6;   // fixed line refill latency (cycles)
  localparam int unsigned IF_PTW_LAT = 4;   // fixed page table walk latency (cycles)
  virtual orbe_fe_mem_if  fe_mem_vif;
  int unsigned            if_l2_id  [$];
  longint unsigned        if_l2_pa  [$];
  longint unsigned        if_l2_due [$];
  bit                     if_ptw_pend;
  longint unsigned        if_ptw_vpn;
  longint unsigned        if_ptw_due;
  longint unsigned        if_cycle;
`endif

  function new(virtual or_be_lsu_if vif_, virtual ob_if phase_vif_,
               virtual ob_cosim_if #(COSIM_ISSUE_NUM, COSIM_ROB_ADDR_W)
                   ob_cosim_vif_, be_config cfg_);
    vif          = vif_;
    phase_vif    = phase_vif_;
    ob_cosim_vif = ob_cosim_vif_;
    cfg          = cfg_;
    if (cfg == null)
      be_reporter::fatal_static("[CACHE] cache_agent requires a non-null be_config");
    // Contract Data structure -> State item 1: terminate when LSU_TAG_W ≠ 4.
    if (LSU_TAG_W != 4)
      cfg.reporter.fatal($sformatf("[CACHE] cache_agent assumes a 4-bit tag; got %0d",
                                   LSU_TAG_W));
    foreach (entry[k]) entry[k] = new();
    stop_requested = 1'b0;
    clear_all_state();
  endfunction

  function void fail(string message);
    cfg.reporter.fatal($sformatf("[CACHE] %s", message));
  endfunction

  // ---------------------------------------------------------------------
  // Pointers and capacity (Data structure -> State items 2, 3)
  // ---------------------------------------------------------------------
  function automatic int unsigned alloc_k();
    return int'(alloc_ptr[1:0]);
  endfunction

  function automatic int unsigned head_k();
    return int'(commit_ptr[1:0]);
  endfunction

  function automatic int unsigned store_buffer_count();
    return (int'(alloc_ptr) - int'(commit_ptr)) & 32'h7;
  endfunction

  function automatic bit store_buffer_full();
    return (store_buffer_count() == LSU_STORE_BUFFER_DEPTH);
  endfunction

  // [FSM-4] Side Effect of flush (state part). The fire condition is evaluated in run().
  function void clear_all_state();
    // Contract FSM item 4 Side Effect: all entries set to IDLE, both pointers cleared,
    // early_wakeup_slot cleared, presentation buffer emptied.
    foreach (entry[k]) begin
      entry[k].state = CACHE_IDLE;
    end
    alloc_ptr            = '0;
    commit_ptr           = '0;
    early_wakeup_slot    = 1'b0;
    exc_buf.delete();
    done_buf.delete();
    presented_last_cycle = 1'b0;
    next_order           = 0;
  endfunction

  // ---------------------------------------------------------------------
  // Contract FSM item 2: is_defined_sync_cause
  // ---------------------------------------------------------------------
  function automatic bit is_defined_sync_cause(longint unsigned c);
    return (c <= 64'd13) || (c == 64'd15) || ((c >= 64'd20) && (c <= 64'd23));
  endfunction

  // lsu_memop_t -> ISA model memop encoding. Contract FSM item 2 memop_in:
  // FENCE / FENCE.I map to LOAD.
  function automatic int model_memop(lsu_memop_t m);
    case (m)
      LSU_MEMOP_LOAD:    return ISA_API_MEMOP_LOAD;
      LSU_MEMOP_STORE:   return ISA_API_MEMOP_STORE;
      LSU_MEMOP_LR:      return ISA_API_MEMOP_LOAD_RSV;
      LSU_MEMOP_SC:      return ISA_API_MEMOP_STORE_CND;
      LSU_MEMOP_AMOSWAP: return ISA_API_MEMOP_AMOSWAP;
      LSU_MEMOP_AMOADD:  return ISA_API_MEMOP_AMOADD;
      LSU_MEMOP_AMOXOR:  return ISA_API_MEMOP_AMOXOR;
      LSU_MEMOP_AMOAND:  return ISA_API_MEMOP_AMOAND;
      LSU_MEMOP_AMOOR:   return ISA_API_MEMOP_AMOOR;
      LSU_MEMOP_AMOMIN:  return ISA_API_MEMOP_AMOMIN;
      LSU_MEMOP_AMOMAX:  return ISA_API_MEMOP_AMOMAX;
      LSU_MEMOP_AMOMINU: return ISA_API_MEMOP_AMOMINU;
      LSU_MEMOP_AMOMAXU: return ISA_API_MEMOP_AMOMAXU;
      LSU_MEMOP_FENCE,
      LSU_MEMOP_FENCE_I: return ISA_API_MEMOP_LOAD;
      default:           return ISA_API_MEMOP_LOAD;
    endcase
  endfunction

  // ---------------------------------------------------------------------
  // Contract FSM item 2: exception_chain(rob, vaddr, memop, len, store_side)
  // Determines cause, injects into the model as needed, returns {cause, tval}. Executed only once per cycle for the same arguments --
  // call sites guarantee each condition calls this function at most once.
  // ---------------------------------------------------------------------
  function automatic void exception_chain(input  longint unsigned      rob,
                                          input  logic [LSU_DATA_W-1:0] vaddr,
                                          input  int                   memop,
                                          input  logic [3:0]           len,
                                          input  bit                   store_side,
                                          output lsu_cause_t           cause,
                                          output logic [LSU_DATA_W-1:0] tval);
    int              rc;
    byte unsigned    priv;
    longint unsigned paddr;
    longint unsigned pp0, pp1, pp2, pp3, pp4;
    longint unsigned pv0, pv1, pv2, pv3, pv4;
    byte unsigned    pte_update, levels, trap_valid, fault_src, mem_type;
    longint unsigned trap_type, trap_tval;
    bit              pte_hit;
    longint unsigned chosen_cause;

    priv = isa_dpi_get_priv(MODEL_CORE_ID);

    rc = isa_dpi_translate_pte(MODEL_CORE_ID, vaddr, longint'(priv), memop,
                               longint'(len),
                               paddr, pp0, pp1, pp2, pp3, pp4,
                               pv0, pv1, pv2, pv3, pv4,
                               pte_update, levels, trap_type, trap_tval,
                               trap_valid, fault_src, mem_type);

    // rc == ISA_API_FAIL is unreachable (memop and len are always in legal range); if it occurs, pte_hit = 0.
    pte_hit = (rc == ISA_API_PASS) && (trap_valid != 0) &&
              is_defined_sync_cause(trap_type);

    chosen_cause = pte_hit ? trap_type : (store_side ? 64'd7 : 64'd5);
    cause = lsu_cause_t'(chosen_cause);
    tval  = pte_hit ? trap_tval : vaddr;

    // Inject: only when the model has no trap recorded for this slot; otherwise the model keeps its own code.
    if (isa_dpi_has_trap(MODEL_CORE_ID, rob) == 0) begin
      if (isa_dpi_trigger_trap(MODEL_CORE_ID, rob, chosen_cause,
                               longint'(tval)) != ISA_API_PASS)
        fail($sformatf("trigger_trap rob=%0d cause=%0d rejected; the model ROB slot is out of range",
                       rob, chosen_cause));
    end
  endfunction

  // ---------------------------------------------------------------------
  // Presentation buffer enqueue (Interface Timing item 4)
  //   load_side : fire cycle + LSU_LOAD_PIPE_STAGES + cache_load_return_delay_cycles
  //   store_side: fire cycle + cache_store_done_delay_cycles
  // ---------------------------------------------------------------------
  function automatic void enqueue_done(lsu_tag_t t,
                                       logic [LSU_DATA_W-1:0] data,
                                       bit with_bypass,
                                       bit load_side);
    cache_wb_record r = new();
    r.is_exception            = 1'b0;
    // [R7] Only fill the done payload. The discriminating info is on the lsu_be_done_valid wire; the payload no longer has
    // done_valid / exception_valid, so the "clear the other side's fields" discipline is no longer needed.
    r.done_pld.tag            = t;
    r.done_pld.data           = data;
    r.has_bypass              = with_bypass;
    r.bypass_pld.tag          = t;
    r.bypass_pld.data         = data;
    r.ready_cycle             = cycle_count +
        (load_side ? (longint'(LSU_LOAD_PIPE_STAGES) + longint'(cfg.cache_load_return_delay_cycles))
                   : longint'(cfg.cache_store_done_delay_cycles));
    done_buf.push_back(r);
  endfunction

  function automatic void enqueue_exception(lsu_tag_t t,
                                            lsu_cause_t cause,
                                            logic [LSU_DATA_W-1:0] tval,
                                            bit load_side);
    cache_wb_record r = new();
    r.is_exception            = 1'b1;
    // [R7] Only fill the exception payload.
    r.exc_pld.tag             = t;
    r.exc_pld.cause           = cause;
    r.exc_pld.tval            = tval;
    r.has_bypass              = 1'b0;
    r.ready_cycle             = cycle_count +
        (load_side ? (longint'(LSU_LOAD_PIPE_STAGES) + longint'(cfg.cache_load_return_delay_cycles))
                   : longint'(cfg.cache_store_done_delay_cycles));
    exc_buf.push_back(r);
  endfunction

  // ---------------------------------------------------------------------
  // Classification of this cycle's issue payload (Out Static Info item 1)
  // ---------------------------------------------------------------------
  function automatic lsu_req_property_t issue_property();
    return req_property_from_subop(vif.be_lsu_issue_pld.exe_subop);
  endfunction

  // Contract FSM item 1 Constraint: terminate when the payload is not self-consistent.
  function automatic void check_payload_self_consistent(lsu_req_property_t p);
    if (!req_property_is_onehot(p))
      fail($sformatf("issue payload tag=%0d exe_subop=%h decodes to a req_property that is not one-hot",
                     vif.be_lsu_issue_pld.self_tag, vif.be_lsu_issue_pld.exe_subop));
    if (mem_funct3_bytes(vif.be_lsu_issue_pld.mem_funct3) == 0)
      fail($sformatf("issue payload tag=%0d has an illegal mem_funct3=%b",
                     vif.be_lsu_issue_pld.self_tag, vif.be_lsu_issue_pld.mem_funct3));
    if (!mem_funct3_matches_subop(vif.be_lsu_issue_pld.mem_funct3,
                                  vif.be_lsu_issue_pld.exe_subop))
      fail($sformatf("issue payload tag=%0d mem_funct3=%b disagrees with the frozen table value for exe_subop=%h",
                     vif.be_lsu_issue_pld.self_tag, vif.be_lsu_issue_pld.mem_funct3,
                     vif.be_lsu_issue_pld.exe_subop));
    if (vif.be_lsu_issue_pld.st_br_resolve && !p.is_store)
      fail($sformatf("issue payload tag=%0d asserts st_br_resolve on a request that is not a plain store",
                     vif.be_lsu_issue_pld.self_tag));
  endfunction

  // The three derived values of this cycle's issue (contract FSM item 2).
  function automatic logic [LSU_DATA_W-1:0] vaddr_in();
    return vif.be_lsu_issue_pld.imm_valid
         ? (vif.be_lsu_issue_pld.rs1_data +
            logic'(0) + $unsigned(vif.be_lsu_issue_pld.imm_data))
         : vif.be_lsu_issue_pld.rs1_data;
  endfunction

  function automatic int memop_in();
    return model_memop(lsu_memop_from_subop(vif.be_lsu_issue_pld.exe_subop));
  endfunction

  function automatic logic [3:0] len_in();
    return mem_funct3_bytes(vif.be_lsu_issue_pld.mem_funct3);
  endfunction

  // alloc_fields(k): contract FSM item 5.
  function automatic void alloc_fields(int unsigned k);
    entry[k].tag          = vif.be_lsu_issue_pld.self_tag;
    entry[k].req_property = issue_property();
    entry[k].vaddr        = vaddr_in();
    entry[k].memop        = memop_in();
    entry[k].len          = len_in();
    entry[k].store_data   = vif.be_lsu_issue_pld.rs2_data;
    entry[k].order        = next_order;
    next_order++;
  endfunction

  // Contract FSM item 5 Constraint: terminate when a store-side tag is duplicated in the Store_Buffer.
  function automatic void check_tag_unique(lsu_tag_t t);
    for (int unsigned u = 0; u < LSU_STORE_BUFFER_DEPTH; u++)
      if ((entry[u].state != CACHE_IDLE) && (entry[u].tag == t))
        fail($sformatf("issue tag=%0d is already live in Store_Buffer entry %0d", t, u));
  endfunction

  // ---------------------------------------------------------------------
  // [FSM-8] authorize + Data structure -> State item 4 early_wakeup_slot
  // Evaluation order step 3. wakeup_consume depends on issue_accept, so it is applied after step 4.
  // ---------------------------------------------------------------------
  function automatic void service_wakeup();
    int target = -1;
    if (vif.be_lsu_store_wakeup_valid !== 1'b1) return;

    // wakeup_target: the oldest STORE_PENDING entry in age order starting from commit_ptr.
    for (int unsigned i = 0; i < LSU_STORE_BUFFER_DEPTH; i++) begin
      int unsigned u = (int'(commit_ptr[1:0]) + int'(i)) & 32'h3;
      if (i >= store_buffer_count()) break;
      if (entry[u].state == CACHE_STORE_PENDING) begin
        target = int'(u);
        break;
      end
    end

    if (target >= 0) begin
      entry[target].state = CACHE_STORE_WAKEUP;
      cfg.print_cache(3, $sformatf("[CACHE][AUTHORIZE] entry=%0d tag=%0d",
                                   target, entry[target].tag));
    end else begin
      // wakeup_target == ∅ -> set the early authorization slot; if already set, receiving another one terminates.
      if (early_wakeup_slot)
        fail("a second store wakeup arrived while the previous early authorization was still unconsumed");
      early_wakeup_slot = 1'b1;
      cfg.print_cache(3, "[CACHE][AUTHORIZE] early wakeup slot set (no STORE_PENDING entry)");
    end
  endfunction

  // ---------------------------------------------------------------------
  // The parts of evaluation order steps 4 and 5 related to this cycle's accept:
  //   [FSM-5] store_alloc_without_resolve
  //   [FSM-6] store_alloc_with_resolve
  //   [FSM-7] store_alloc_fault&exception
  //   [FSM-1] load_alloc&commit   [FSM-2] load_fault&exception
  //   [FSM-3] fence_alloc&commit
  // ---------------------------------------------------------------------
  task automatic accept_issue();
    lsu_req_property_t p;
    bit                issue_store_side;
    bit                read_in, misc_in;
    bit                issue_accept;
    lsu_tag_t          t;
    longint unsigned   issue_rob;
    int                exec_rc;
    int                load_rc;
    int                req_rc;
    lsu_cause_t        cause;
    logic [LSU_DATA_W-1:0] tval;
    logic [LSU_DATA_W-1:0] rd_value;
    byte unsigned      md_trap_valid;
    longint unsigned   md_trap_cause, md_trap_tval;
    int                md_rc;

    if (vif.be_lsu_issue_valid !== 1'b1) return;

    p                = issue_property();
    issue_store_side = p.is_store || p.is_amo || p.is_sc;
    read_in          = p.is_load  || p.is_lr;
    misc_in          = p.is_fence || p.is_fence_i;

    // [R9-i] With the buffer full, BE **may** present a store-side request -- the handshake is standard
    // valid/ready (holds only when both are 1 in the same cycle); the spec only says when ready is 0, and BE should
    // "hold and resend". The RTL's be_lsu_issue_valid ignores ready, issue_accept = valid∧ready,
    // fully compliant. The former direct fatal here was an over-reading from the BFM era (the BFM only sent when ready
    // was 1). The invariant that really needs guarding is that the ready given by this module must agree with full; below,
    // just handle non-acceptance via issue_accept, and BE will hold the request and come back next cycle.
    if (issue_store_side && store_buffer_full() && (vif.rst_n === 1'b1)) begin
      if (vif.lsu_be_issue_ready === 1'b1)
        fail($sformatf("store-side request (tag=%0d) presented with the buffer full, yet lsu_be_issue_ready is high — the ready derivation in or_be_lsu_if is inconsistent with store_buffer_full()",
                       vif.be_lsu_issue_pld.self_tag));
      cfg.print_cache(3, $sformatf("[CACHE][STORE_HELD] tag=%0d buffer full, request not accepted this cycle",
                                   vif.be_lsu_issue_pld.self_tag));
    end

    issue_accept = (vif.lsu_be_issue_ready === 1'b1);
    if (!issue_accept) return;

    check_payload_self_consistent(p);

    t         = vif.be_lsu_issue_pld.self_tag;
    issue_rob = longint'(t);

    if (issue_store_side) check_tag_unique(t);

    // Accept stage: issue execute_insn for this cycle's be_lsu_issue_valid (step 4).
    exec_rc = isa_dpi_execute_insn(MODEL_CORE_ID, issue_rob);
    if (exec_rc == ISA_API_SKIP)
      fail($sformatf("execute_insn tag=%0d returned SKIP; the RTL sent the LSU an instruction the model judged illegal or already faulted on fetch -- decode disagreement",
                     t));

    // ---- store_side: items 5, 6, 7 --------------------------------------
    if (issue_store_side) begin
      if (exec_rc == ISA_API_FAIL) begin
        // [FSM-7] store_alloc_fault&exception
        // [R3b] On FAIL the model must already have recorded a trap; read the model's actual code rather than the fallback code.
        md_rc = isa_dpi_get_execute_metadata(MODEL_CORE_ID, issue_rob,
                                             md_trap_valid, md_trap_cause,
                                             md_trap_tval);
        if ((md_rc == ISA_API_PASS) && (md_trap_valid != 0)) begin
          cause = lsu_cause_t'(md_trap_cause);
          tval  = md_trap_tval;
        end else begin
          // Unreachable fallback: if the model recorded no code, fall back to the contract's original formula.
          exception_chain(issue_rob, vaddr_in(), memop_in(), len_in(), 1'b1,
                          cause, tval);
        end
        alloc_fields(alloc_k());
        entry[alloc_k()].state = CACHE_FAULTED;
        alloc_ptr              = alloc_ptr + 3'd1;
        enqueue_exception(t, cause, tval, 1'b0);
        cfg.print_cache(2, $sformatf("[CACHE][STORE_ALLOC_FAULT] tag=%0d cause=%0d tval=0x%0h",
                                     t, cause, tval));
        return;
      end

      if (exec_rc != ISA_API_PASS)
        fail($sformatf("execute_insn tag=%0d returned rc=%0d", t, exec_rc));

      // One of three authorization sources: non-plain store (AMO/SC), st_br_resolve, early authorization slot.
      if (!p.is_store || vif.be_lsu_issue_pld.st_br_resolve || early_wakeup_slot) begin
        // [FSM-6] store_alloc_with_resolve
        alloc_fields(alloc_k());
        entry[alloc_k()].state = CACHE_STORE_WAKEUP;
        alloc_ptr              = alloc_ptr + 3'd1;
        // Data structure -> State item 4 wakeup_consume
        if (p.is_store && !vif.be_lsu_issue_pld.st_br_resolve && early_wakeup_slot)
          early_wakeup_slot = 1'b0;
        cfg.print_cache(3, $sformatf("[CACHE][STORE_ALLOC_RESOLVED] tag=%0d", t));
      end else begin
        // [FSM-5] store_alloc_without_resolve
        alloc_fields(alloc_k());
        entry[alloc_k()].state = CACHE_STORE_PENDING;
        alloc_ptr              = alloc_ptr + 3'd1;
        cfg.print_cache(3, $sformatf("[CACHE][STORE_ALLOC_PENDING] tag=%0d", t));
      end
      return;
    end

    // ---- load_side: items 1, 2 ------------------------------------------
    if (read_in) begin
      if (exec_rc == ISA_API_FAIL) begin
        // [FSM-2] load_fault&exception
        exception_chain(issue_rob, vaddr_in(), memop_in(), len_in(), 1'b0,
                        cause, tval);
        enqueue_exception(t, cause, tval, 1'b1);
        cfg.print_cache(2, $sformatf("[CACHE][LOAD_FAULT] tag=%0d cause=%0d tval=0x%0h",
                                     t, cause, tval));
        return;
      end
      if (exec_rc != ISA_API_PASS)
        fail($sformatf("execute_insn tag=%0d returned rc=%0d", t, exec_rc));

      load_rc = isa_dpi_proc_mem_load(MODEL_CORE_ID, issue_rob);
      if (load_rc == ISA_API_SKIP)
        fail($sformatf("proc_mem_load tag=%0d returned SKIP on the read side; this return code is unreachable here, so the model's behaviour has changed",
                       t));
      if (load_rc == ISA_API_FAIL) begin
        // [FSM-2] load_fault&exception, read-side failure branch
        exception_chain(issue_rob, vaddr_in(), memop_in(), len_in(), 1'b0,
                        cause, tval);
        enqueue_exception(t, cause, tval, 1'b1);
        cfg.print_cache(2, $sformatf("[CACHE][LOAD_FAULT] tag=%0d cause=%0d tval=0x%0h",
                                     t, cause, tval));
        return;
      end

      // [FSM-1] load_alloc&commit
      rd_value = isa_dpi_get_insn_rd_value(MODEL_CORE_ID, issue_rob);
      enqueue_done(t, rd_value, 1'b1, 1'b1);
      cfg.print_cache(3, $sformatf("[CACHE][LOAD_DONE] tag=%0d data=0x%0h", t, rd_value));
      return;
    end

    // ---- FENCE / FENCE.I: item 3 ---------------------------------------
    if (misc_in) begin
      if (exec_rc != ISA_API_PASS)
        fail($sformatf("execute_insn tag=%0d returned rc=%0d on a FENCE/FENCE.I; both FAIL and SKIP are unreachable here",
                       t, exec_rc));
      req_rc = isa_dpi_proc_mem_req(MODEL_CORE_ID, issue_rob);
      if ((req_rc != ISA_API_PASS) && (req_rc != ISA_API_SKIP))
        fail($sformatf("proc_mem_req tag=%0d returned rc=%0d on a FENCE/FENCE.I", t, req_rc));
      // [FSM-3] fence_alloc&commit
      enqueue_done(t, '0, 1'b0, 1'b1);
      cfg.print_cache(3, $sformatf("[CACHE][FENCE_DONE] tag=%0d", t));
      return;
    end

    fail($sformatf("issue tag=%0d has a req_property that matches no request class", t));
  endtask

  // ---------------------------------------------------------------------
  // Service stage of evaluation order step 5: evaluate each entry in age order
  //   [FSM-9]  store_commit   [FSM-10] amo_commit   [FSM-11] store_fault&exception
  // After an older entry commits and advances commit_ptr, a younger entry may become the head in the same cycle.
  // ---------------------------------------------------------------------
  task automatic service_store_buffer();
    bit progressed;
    int unsigned k;
    lsu_tag_t    t;
    longint unsigned head_rob;
    int          load_rc;
    int          commit_rc;
    bit          store_commit_called;
    bit          faulted_store_parked;
    lsu_cause_t  cause;
    logic [LSU_DATA_W-1:0] tval;
    logic [LSU_DATA_W-1:0] rd_value;
    logic [63:0] store_pc;

    progressed = 1'b1;
    while (progressed) begin
      progressed = 1'b0;
      if (store_buffer_count() == 0) break;

      k = head_k();
      if (entry[k].state != CACHE_STORE_WAKEUP) break;

      t        = entry[k].tag;
      head_rob = longint'(t);

      faulted_store_parked = 1'b0;
      for (int unsigned u = 0; u < LSU_STORE_BUFFER_DEPTH; u++)
        if ((u != k) && (entry[u].state == CACHE_FAULTED))
          faulted_store_parked = 1'b1;

      load_rc             = ISA_API_PASS;
      store_commit_called = 1'b0;

      // AMO / SC first make the read-modify-write decision at the head.
      if (!entry[k].req_property.is_store) begin
        load_rc = isa_dpi_proc_mem_load(MODEL_CORE_ID, head_rob);
        if (load_rc == ISA_API_SKIP)
          fail($sformatf("proc_mem_load tag=%0d returned SKIP for an AMO/SC; this return code is unreachable here, so the model's behaviour has changed",
                         t));
        if (load_rc == ISA_API_FAIL) begin
          // [FSM-11] store_fault&exception, AMO/SC read-side failure branch.
          // [R3a] The model already recorded LOAD_ACCESS_FAULT(5) itself, so no injection; this entry reports the spec-correct 7.
          cause = lsu_cause_t'(64'd7);
          tval  = entry[k].vaddr;
          entry[k].state = CACHE_FAULTED;     // commit_ptr does not advance
          enqueue_exception(t, cause, tval, 1'b0);
          cfg.print_cache(2, $sformatf("[CACHE][AMO_FAULT] tag=%0d reported cause=7 (store/AMO access fault) while the model recorded 5 (load access fault); the model does not special-case AMO -- known isa_model defect, see FuncMultiCore::procMemLoad",
                                       t));
          break;
        end
      end

      store_commit_called = entry[k].req_property.is_store || (load_rc == ISA_API_PASS);

      // The PC must be fetched before draining: after store_commit pops the head of the model's store buffer,
      // the source information of this entry is no longer reliable.
      store_pc  = isa_dpi_get_insn_pc(MODEL_CORE_ID, head_rob);
      commit_rc = isa_dpi_store_commit(MODEL_CORE_ID);
      if (commit_rc == ISA_API_FAIL) begin
        if (faulted_store_parked)
          fail($sformatf("store_commit for tag=%0d was refused while another faulted store is parked in the Store_Buffer; this is a testbench ordering fault, not an architectural one",
                         t));
        // [FSM-11] store_fault&exception, write failure branch: the model has no trap recorded, so it is injected.
        exception_chain(head_rob, entry[k].vaddr, entry[k].memop, entry[k].len,
                        1'b1, cause, tval);
        entry[k].state = CACHE_FAULTED;       // commit_ptr does not advance
        enqueue_exception(t, cause, tval, 1'b0);
        cfg.print_cache(2, $sformatf("[CACHE][STORE_FAULT] tag=%0d cause=%0d tval=0x%0h",
                                     t, cause, tval));
        break;
      end
      if (commit_rc != ISA_API_PASS)
        fail($sformatf("store_commit tag=%0d returned rc=%0d", t, commit_rc));

      if (isa_dpi_clear_mem_reserve(MODEL_CORE_ID) != ISA_API_PASS)
        fail($sformatf("clear_mem_reserve after store_commit tag=%0d failed; the core id is out of range",
                       t));

      publish_store_commit(k, store_pc);

      if (entry[k].req_property.is_store) begin
        // [FSM-9] store_commit
        enqueue_done(t, '0, 1'b0, 1'b0);
        cfg.print_cache(3, $sformatf("[CACHE][STORE_COMMIT] tag=%0d", t));
      end else begin
        // [FSM-10] amo_commit
        rd_value = isa_dpi_get_insn_rd_value(MODEL_CORE_ID, head_rob);
        enqueue_done(t, rd_value, 1'b1, 1'b0);
        cfg.print_cache(3, $sformatf("[CACHE][AMO_COMMIT] tag=%0d data=0x%0h", t, rd_value));
      end

      entry[k].state = CACHE_IDLE;
      commit_ptr     = commit_ptr + 3'd1;
      progressed     = 1'b1;
    end
  endtask

  // COSIM observation surface: store-side commit. Not covered by the contract, but be_agent's
  // publish_cosim_mem_observation X-checks each of these fields (be_agent.sv),
  // so every field must have a defined value -- including pc.
  function automatic void publish_store_commit(int unsigned k,
                                               logic [63:0] store_pc);
    logic [7:0] mask;
    mask = 8'hFF >> (8 - entry[k].len);
    if (ob_cosim_vif.mem_store_commit_valid === 1'b1)
      fail("more than one store commit was produced in one cache observation phase");
    ob_cosim_vif.mem_store_commit_valid    = 1'b1;
    ob_cosim_vif.mem_store_commit_order    = entry[k].order;
    ob_cosim_vif.mem_store_commit_vaddr    = entry[k].vaddr;
    ob_cosim_vif.mem_store_commit_data     = entry[k].store_data;
    ob_cosim_vif.mem_store_commit_mask     = mask;
    ob_cosim_vif.mem_store_commit_pc       = store_pc;
    ob_cosim_vif.mem_store_commit_rob_idx  = 64'(entry[k].tag);
    ob_cosim_vif.mem_store_commit_terminal = (isa_dpi_is_to_exit() != 0);
  endfunction

  function automatic void clear_store_commit_observation();
    ob_cosim_vif.mem_store_commit_valid    = 1'b0;
    ob_cosim_vif.mem_store_commit_order    = '0;
    ob_cosim_vif.mem_store_commit_vaddr    = '0;
    ob_cosim_vif.mem_store_commit_data     = '0;
    ob_cosim_vif.mem_store_commit_mask     = '0;
    ob_cosim_vif.mem_store_commit_pc       = '0;
    ob_cosim_vif.mem_store_commit_rob_idx  = '0;
    ob_cosim_vif.mem_store_commit_terminal = 1'b0;
  endfunction

  // ---------------------------------------------------------------------
  // Presentation (Interface Timing item 4): at most one per posedge, exceptions before completions,
  // within a class in order of entry into the buffer.
  // ---------------------------------------------------------------------
  task automatic drive_outputs();
    cache_wb_record r = null;
    int             idx = -1;
    bit             from_exc = 1'b0;

    foreach (exc_buf[i])
      if (exc_buf[i].ready_cycle <= cycle_count) begin
        idx = i; from_exc = 1'b1; break;
      end
    if (idx < 0)
      foreach (done_buf[i])
        if (done_buf[i].ready_cycle <= cycle_count) begin
          idx = i; from_exc = 1'b0; break;
        end

    if (idx < 0) begin
      vif.lsu_be_done_valid_q      <= 1'b0;
      vif.lsu_be_exception_valid_q <= 1'b0;
      vif.lsu_be_bypass_valid_q    <= 1'b0;
      vif.lsu_be_done_pld          <= '0;
      vif.lsu_be_exception_pld     <= '0;
      vif.lsu_be_bypass_pld        <= '0;
      presented_last_cycle          = 1'b0;
      return;
    end

    if (from_exc) begin
      r = exc_buf[idx];
      exc_buf.delete(idx);
    end else begin
      r = done_buf[idx];
      done_buf.delete(idx);
    end

    // [R7] Split onto the two port groups. Driving 0 on the unselected payload is an anti-X hygiene measure,
    // not a correctness requirement -- consumers only read it when the corresponding valid is 1.
    vif.lsu_be_done_valid_q      <= r.is_exception ? 1'b0 : 1'b1;
    vif.lsu_be_exception_valid_q <= r.is_exception ? 1'b1 : 1'b0;
    vif.lsu_be_done_pld          <= r.is_exception ? '0 : r.done_pld;
    vif.lsu_be_exception_pld     <= r.is_exception ? r.exc_pld : '0;
    vif.lsu_be_bypass_valid_q    <= r.has_bypass;
    vif.lsu_be_bypass_pld        <= r.has_bypass ? r.bypass_pld : '0;

    presented_last_cycle = 1'b1;
    presented_last_tag   = r.is_exception ? r.exc_pld.tag : r.done_pld.tag;
  endtask

  // ---------------------------------------------------------------------
  // run: negedge model phase + posedge drive phase (Interface Timing items 1, 3, 4)
  // ---------------------------------------------------------------------
  task run();
    bit flush_fire;
    bit entry_ready;

    if (!dside_is_rtl()) begin
      vif.lsu_be_done_valid_q      <= 1'b0;
      vif.lsu_be_exception_valid_q <= 1'b0;
      vif.lsu_be_bypass_valid_q    <= 1'b0;
      vif.lsu_be_done_pld          <= '0;
      vif.lsu_be_exception_pld     <= '0;
      vif.lsu_be_bypass_pld        <= '0;
      vif.lsu_store_buffer_full    <= 1'b0;
    end
    clear_store_commit_observation();

    clear_all_state();
    cycle_count       = 0;
    model_exit_seen   = 1'b0;
    next_be_phase_seq = phase_vif.dpi_be_phase_seq + 1;

    forever begin
      @(negedge vif.clk);

      // Step 1: wait for dpi_be_phase_seq to advance from the previous cycle. BE and this module share one model,
      // so every model call must fall in a phase BE has already finished.
      while (!stop_requested &&
             (phase_vif.dpi_be_phase_seq < next_be_phase_seq))
        @(phase_vif.dpi_be_phase_seq);
      if (stop_requested) return;
      next_be_phase_seq++;

      entry_ready = (vif.be_lsu_entry_ready === 1'b1);

      // Step 2: [FSM-4] flush. Holds every cycle while rst_n is 0.
      flush_fire = (vif.rst_n !== 1'b1) || (vif.global_flush_late === 1'b1);

      // Interface Timing item 4: terminate if one was presented last cycle and BE did not accept it this cycle without a flush.
      if (presented_last_cycle && !entry_ready &&
          (vif.global_flush_late !== 1'b1) && (vif.rst_n === 1'b1))
        fail($sformatf("the terminal event for tag=%0d was presented but be_lsu_entry_ready was low without a flush; BE may only lower that line on a reset or flush cycle",
                       presented_last_tag));

      if (flush_fire) begin
        clear_all_state();
`ifdef ORBE_CACHE_RTL
        if (dside_rtl) dside_flush(vif.rst_n !== 1'b1);
`endif
        if (vif.rst_n !== 1'b1) begin
          cycle_count     = 0;
          model_exit_seen = 1'b0;
        end
      end else begin
        cycle_count++;
        clear_store_commit_observation();

`ifdef ORBE_CACHE_RTL
        if (dside_rtl) dside_phase();   // D side executed by RTL: only model sync on RTL events
        else begin
`endif
        service_wakeup();        // step 3
        accept_issue();          // step 4 + the accept-side terminal events of step 5
        service_store_buffer();  // service stage of step 5
`ifdef ORBE_CACHE_RTL
        end
`endif

        // [R9-h] full/not-full is updated **immediately after this cycle's negedge finishes accept and drain** (blocking assignment),
        // rather than waiting for an NBA at the next posedge. Real RTL samples lsu_be_issue_ready at posedge:
        // in the NBA version, after the 4th store is accepted full only flips at the next posedge, so what the RTL reads at that
        // posedge is still the old value → it sends the 5th → this module asserts "issued while ready was low"
        // (triggered when the rv64ua-v-* trap handler sends back-to-back sd). The BFM only looks at ready at negedge,
        // so both styles are equivalent for it, and the 216 tests are unaffected.
        if (!dside_is_rtl())
          vif.lsu_store_buffer_full = (vif.rst_n === 1'b1) && store_buffer_full();

        // Step 6
        model_exit_seen = model_exit_seen || (isa_dpi_is_to_exit() != 0);
      end

`ifdef ORBE_CACHE_RTL
      if (dside_rtl) dside_mem_service();   // refill / PTW / eviction check: ordered after this cycle's drain
`endif
`ifdef ORBE_FE_RTL
      if (fe_mem_vif != null) service_ifetch();
`endif

      @(posedge vif.clk);
      if (stop_requested) return;

      // The accept line of Out Static Info item 1 is derived combinationally by or_be_lsu_if: this module only provides
      // full/not-full. Accept must be combinational in the class of this cycle's request (the read side can always be accepted), and a class cannot drive
      // combinational values, so the derivation stays in the interface.
      // [R9-h] full/not-full is already updated right after the negedge processing (see above), so no NBA here --
      // driving the same signal from two places is legal, but the posedge NBA would make the RTL sample one cycle late.

      if (dside_is_rtl()) begin
        // LSU outputs are driven by RTL; this agent does not present, it only drives the HTIF mirror's
        // hold bits and replay (NBA)
`ifdef ORBE_CACHE_RTL
        dside_htif_drive();
`endif
      end else if (flush_fire) begin
        vif.lsu_be_done_valid_q      <= 1'b0;
        vif.lsu_be_exception_valid_q <= 1'b0;
        vif.lsu_be_bypass_valid_q    <= 1'b0;
        vif.lsu_be_done_pld          <= '0;
        vif.lsu_be_exception_pld     <= '0;
        vif.lsu_be_bypass_pld        <= '0;
        presented_last_cycle          = 1'b0;
      end else begin
        drive_outputs();
      end

      // This module stops running when model_exit_seen ∧ buffers empty (Interface Timing item 4).
      //
      // Additionally requires "nothing presented this cycle": presentation is a posedge NBA, and the consumer only samples
      // it next cycle. If we exit in the same cycle as a presentation, nobody consumes the last one -- the tohost store's
      // WriteBack is exactly this case: the model writes tohost, setting model_exit_seen that cycle,
      // and the buffer happens to be emptied by that very entry, so the terminal event is lost and the reference model never sees tohost.
      // [R9-d] Also requires the Store_Buffer to be empty. Real RTL still sends a
      // fromhost store after the tohost store (observed in rv64ui-p-sd/-p-sw: this module returned right after
      // STORE_ALLOC_PENDING tag=10); its wakeup authorization has no taker and it never drains, the RTL's ROB head hangs,
      // and be_agent never gets further commits. In the BFM era "requests after exit" did not exist, so the original condition ignored it.
      if ((vif.rst_n === 1'b1) && model_exit_seen && !presented_last_cycle &&
          (exc_buf.size() == 0) && (done_buf.size() == 0) &&
          (store_buffer_count() == 0) && dside_quiet())
        return;
    end
  endtask

  task shutdown();
    stop_requested = 1'b1;
  endtask

  // Whether the D side is executed by RTL (DUT_KIND=rtl_cache / rtl_full)
  function automatic bit dside_is_rtl();
`ifdef ORBE_CACHE_RTL
    return dside_rtl;
`else
    return 1'b0;
`endif
  endfunction

  // D-side part of the exit condition: the RTL kind requires all glue logic records to be settled
  function automatic bit dside_quiet();
`ifdef ORBE_CACHE_RTL
    return !dside_rtl || dside_idle();
`else
    return 1'b1;
`endif
  endfunction

`ifdef ORBE_FE_RTL
  function void attach_ifetch(virtual orbe_fe_mem_if v);
    fe_mem_vif    = v;
    if_ptw_pend   = 1'b0;
    if_cycle      = 0;
    if_l2_id.delete();
    if_l2_pa.delete();
    if_l2_due.delete();
    fe_mem_vif.l2_req_ready  = 1'b1;
    fe_mem_vif.ptw_req_ready = 1'b1;
    fe_mem_vif.l2_resp       = 1'b0;
    fe_mem_vif.l2_resp_id    = '0;
    fe_mem_vif.l2_resp_data  = '0;
    fe_mem_vif.ptw_resp      = 1'b0;
    fe_mem_vif.ptw_resp_ppn  = '0;
    fe_mem_vif.ptw_resp_lvl  = or_fe_pkg::PG_4K;
    fe_mem_vif.ptw_resp_x    = 1'b0;
    fe_mem_vif.ptw_resp_u    = 1'b0;
    fe_mem_vif.ptw_resp_pbmt = 2'b00;
    fe_mem_vif.ptw_resp_fault = 1'b0;
    fe_mem_vif.ptw_resp_cause = '0;
  endfunction

  // ---------------------------------------------------------------------
  // L2TLB: the ISA model's translation is the sole ground truth (same query order as exception_chain:
  // get_priv -> translate_pte). translate_pte is read-only and does not write A/D; the model itself decides
  // page table walk, U/S/X permissions, A/D (Svade) and PMP; this function only converts the result into FE's
  // PTW response format:
  //   trap_valid          -> fault, cause taken from the model's trap_type (12 / 1)
  //   otherwise           -> ppn = paddr >> 12; when levels>0 compute the leaf level from the satp mode
  //                          to get the page size; levels=0 (model soft-TLB hit / bare) uses 4K
  //   x/u                 -> filled as "already permitted at the query privilege level": x=1, u=(priv==U).
  //                          Privilege only changes on trap/xRET, and FE flushes the ITLB on all those redirects,
  //                          so cached results are never used across privilege levels.
  // ---------------------------------------------------------------------
  function automatic void if_ptw_query(input  longint unsigned vpn,
                                       output logic [or_fe_pkg::PPN_W-1:0] ppn,
                                       output or_fe_pkg::pg_lvl_t lvl,
                                       output bit x, output bit u,
                                       output bit fault, output logic [or_fe_pkg::CAUSE_W-1:0] cause,
                                       output longint unsigned vaddr,
                                       output byte unsigned priv);
    int              rc;
    longint unsigned paddr;
    longint unsigned pp0, pp1, pp2, pp3, pp4;
    longint unsigned pv0, pv1, pv2, pv3, pv4;
    byte unsigned    pte_update, levels, trap_valid, fault_src, mem_type;
    longint unsigned trap_type, trap_tval;
    longint unsigned satp;
    int              root_lvl, leaf_lvl;

    // VPN is the upper bits of a VA_W-bit virtual address; sign-extend from VA_W to a 64-bit virtual address
    vaddr = longint'(vpn) << 12;
    if (vaddr[or_fe_pkg::VA_W-1])
      vaddr = vaddr | ~((64'd1 << or_fe_pkg::VA_W) - 1);
    priv  = isa_dpi_get_priv(MODEL_CORE_ID);

    rc = isa_dpi_translate_pte(MODEL_CORE_ID, vaddr, longint'(priv), ISA_API_MEMOP_FETCH, 64'd2,
                               paddr, pp0, pp1, pp2, pp3, pp4,
                               pv0, pv1, pv2, pv3, pv4,
                               pte_update, levels, trap_type, trap_tval,
                               trap_valid, fault_src, mem_type);
    if (rc != ISA_API_PASS)
      fail($sformatf("[FE_RTL][PTW] translate_pte vaddr=0x%016h priv=%0d returned rc=%0d",
                     vaddr, priv, rc));

    ppn = '0; lvl = or_fe_pkg::PG_4K; x = 1'b0; u = 1'b0; fault = 1'b0; cause = '0;
    if (trap_valid != 0) begin
      fault = 1'b1;
      if (trap_type == 64'd12)     cause = or_fe_pkg::CAUSE_IPF;
      else if (trap_type == 64'd1) cause = or_fe_pkg::CAUSE_IAF;
      else fail($sformatf("[FE_RTL][PTW] translate_pte vaddr=0x%016h reported trap_type=%0d, outside the fetch set {1,12}",
                          vaddr, trap_type));
      return;
    end

    ppn = or_fe_pkg::PPN_W'(paddr >> 12);
    x   = 1'b1;
    u   = (priv == 8'd0);
    if (levels != 0) begin
      satp     = isa_dpi_get_csr(MODEL_CORE_ID, 16'h180);
      root_lvl = (satp[63:60] == 4'd9) ? 3 : 2;           // Sv48 : Sv39
      leaf_lvl = root_lvl + 1 - int'(levels);
      lvl = (leaf_lvl == 2) ? or_fe_pkg::PG_1G :
            (leaf_lvl == 1) ? or_fe_pkg::PG_2M : or_fe_pkg::PG_4K;
    end
  endfunction

  // negedge phase: sample this cycle's requests (handshake at next posedge), give this cycle's responses (sampled at next posedge)
  function void service_ifetch();
    byte unsigned line [0:or_fe_pkg::FETCH_BYTES-1];
    longint unsigned trap;
    logic [or_fe_pkg::LINE_W-1:0] data;
    logic [or_fe_pkg::PPN_W-1:0] ppn;
    or_fe_pkg::pg_lvl_t lvl;
    bit x, u, fault;
    logic [or_fe_pkg::CAUSE_W-1:0] cause;
    longint unsigned q_vaddr;
    byte unsigned q_priv;
    int rc;

    if_cycle++;
    fe_mem_vif.l2_resp  = 1'b0;
    fe_mem_vif.ptw_resp = 1'b0;
    if (fe_mem_vif.rst_n !== 1'b1) begin
      if_l2_id.delete();
      if_l2_pa.delete();
      if_l2_due.delete();
      if_ptw_pend = 1'b0;
      return;
    end

    // Accept
    if (fe_mem_vif.l2_req_vld === 1'b1) begin
      if_l2_id.push_back(fe_mem_vif.l2_req_id);
      if_l2_pa.push_back(longint'(fe_mem_vif.l2_req_pa_line) << or_fe_pkg::OFF_W);
      if_l2_due.push_back(if_cycle + IF_L2_LAT);
      cfg.print_fe(3, $sformatf("[FE_RTL][L2] req id=%0d pa=0x%016h",
                                fe_mem_vif.l2_req_id, longint'(fe_mem_vif.l2_req_pa_line) << or_fe_pkg::OFF_W));
    end
    if ((fe_mem_vif.ptw_req_vld === 1'b1) && !if_ptw_pend) begin
      if_ptw_pend = 1'b1;
      if_ptw_vpn  = fe_mem_vif.ptw_req_vpn;
      if_ptw_due  = if_cycle + IF_PTW_LAT;
    end

    // Respond: read memory only when the Store_Buffer is empty (when the D side is RTL, count the undrained store-side requests in the glue logic records, same measure)
    if (store_buffer_count() != 0) return;
`ifdef ORBE_CACHE_RTL
    if (dside_rtl && (dside_store_pending() != 0)) return;
`endif

    if ((if_l2_id.size() != 0) && (if_l2_due[0] <= if_cycle)) begin
      // L2 ICache: model physical memory read (the fetch line has already been translated to a physical address by the ITLB).
      // A read failure (memory hole, etc.) can only come from wrong-path prefetch; return all zeros and print a diagnostic.
      rc = isa_dpi_read_mem_bank(if_l2_pa[0], or_fe_pkg::FETCH_BYTES, line, trap);
      data = '0;
      if (rc == ISA_API_PASS)
        for (int i = 0; i < or_fe_pkg::FETCH_BYTES; i++) data[8*i +: 8] = line[i];
      else
        cfg.print_fe(2, $sformatf("[FE_RTL][L2] read_mem_bank pa=0x%016h failed rc=%0d trap=%0d; returning zeros",
                                  if_l2_pa[0], rc, trap));
      fe_mem_vif.l2_resp      = 1'b1;
      fe_mem_vif.l2_resp_id   = if_l2_id[0];
      fe_mem_vif.l2_resp_data = data;
      cfg.print_fe(3, $sformatf("[FE_RTL][L2] resp id=%0d pa=0x%016h rc=%0d", if_l2_id[0], if_l2_pa[0], rc));
      void'(if_l2_id.pop_front());
      void'(if_l2_pa.pop_front());
      void'(if_l2_due.pop_front());
    end

    if (if_ptw_pend && (if_ptw_due <= if_cycle)) begin
      if_ptw_query(if_ptw_vpn, ppn, lvl, x, u, fault, cause, q_vaddr, q_priv);
      fe_mem_vif.ptw_resp       = 1'b1;
      fe_mem_vif.ptw_resp_ppn   = ppn;
      fe_mem_vif.ptw_resp_lvl   = lvl;
      fe_mem_vif.ptw_resp_x     = x;
      fe_mem_vif.ptw_resp_u     = u;
      fe_mem_vif.ptw_resp_pbmt  = 2'b00;
      fe_mem_vif.ptw_resp_fault = fault;
      fe_mem_vif.ptw_resp_cause = cause;
      cfg.print_fe(2, $sformatf("[FE_RTL][PTW] vaddr=0x%016h priv=%0d -> fault=%0d cause=%0d ppn=0x%0h lvl=%0d",
                                q_vaddr, q_priv, fault, cause, ppn, lvl));
      if_ptw_pend = 1'b0;
    end
  endfunction
`endif
endclass
