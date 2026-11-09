// [This file] Slot occupant: drives the two boundaries fe and lsu
// Reference-side BE agent.
//
// Backend agent with 16 entries, 2-lane ingress, in-order single issue: keeps three
// semantic states FREE / ALLOC / ISSUED per rob_idx, drives the shared ISA model in a
// fixed order, and outputs the ISA model and LSU results through the two boundaries
// BE-FE redirect and BE-LSU issue.
//
// Role: F · BFM (BE) -- DUT stand-in, occupies the slot under DUT_KIND=agent.
// It is *not* tb/agents/be/be_agent.sv -- that one is the COSIM observer: it reads the
// ob_if observation bundle and publishes cosim events; no overlap with this module.
//
// Form: module, not class. The contract's `Out Static Info` (be_fe_instr_ready[s],
// be_lsu_entry_ready) must be combinationally valid in the current cycle; a class cannot
// drive combinational values. DPI calls are issued once in a negedge sequential block,
// and the combinational outputs are driven by the values computed in that phase -- FE
// samples ready at posedge, Cache calls the model at negedge only after the phase
// advances, so both sides see this cycle's stable values.
//
// Generation-time decisions:
//   [R2] dpi_be_phase_seq is advanced once per cycle by this module (64 bit, ob_if.sv).
//        The contract's Interface does not list it, but CacheAgent In Static Info item 3
//        requires waiting for it to advance; producer is BE, consumer is Cache, carrier
//        is ob_if, so it is added as a BE Out Static Info.
//   [R4] be_fe_instr_ready[1] gets an extra `∧ fe_be_instr_valid[0]` conjunct. Contract
//        Out Static Info item 1 missed this term; RTL src/core/be_rtl_v1/p1/IB.sv really is
//        `fe_ready[1] = fe_valid[0] && ...`, and FE contract In Static Info item 1 also
//        states that ready depends combinationally on valid. This BFM must be behaviorally
//        equivalent to rtl_v1, otherwise using it for environment self-check loses its
//        value as a checker.

`timescale 1ns / 1ps

module be_bfm (
  input  logic  clk,
  input  logic  rst_n,
  orbe_fe_if    fe,
  or_be_lsu_if  lsu,
  ob_if         ob,
  // [Split-1] Observable event stream (contract Interface -> Out-event item 5).
  // Slot contract item (2): the sole information source for predictor and checker after
  // the DUT is swapped; on the RTL side tb/top/rtl_v1_obs.svh, `include'd in be_tb_top,
  // produces the same shape.
  // Parameters must match the top-level instantiation.
  ob_cosim_if #(
    .ISSUE_NUM (orbe_be_dim_pkg::BE_ISSUE_NUM),
    .ROB_ADDR_W(orbe_be_dim_pkg::BE_ROB_ADDR_W)
  )             ob_cosim
);

  import isa_dpi_pkg::*;
  // [Split-3] All model-advancing DPI goes through the G1 predictor; this BFM keeps only queries.
  import orbe_predictor_pkg::*;
  import or_be_lsu_protocol_pkg::*;
  import orbe_fe_types_pkg::*;

  // FSM preamble: BE_ROB_SIZE = 2^BE_TAG_W, BE_TAG_W aligned with LSU_TAG_W.
  localparam int unsigned BE_TAG_W       = LSU_TAG_W;
  localparam int unsigned BE_ROB_SIZE    = 1 << BE_TAG_W;
  localparam int unsigned MODEL_CORE_ID  = 0;
  localparam int unsigned FE_LANES       = ORBE_FE_LANES;
  // [Split-1] The observation-surface tag carrier is wider than BE's real tag (6 vs 4,
  // see the history note in orbe_be_dim_pkg); zero-extended on publish.
  localparam int unsigned OBS_TAG_W      = orbe_be_dim_pkg::BE_ROB_ADDR_W;

  // Pointer width is BE_TAG_W and BE_ROB_SIZE is a power of 2, so addition wraps
  // naturally; no modulo needed.
  // Data structure -> State item 1
  localparam logic [1:0] BE_FREE   = 2'b00;
  localparam logic [1:0] BE_ALLOC  = 2'b01;
  localparam logic [1:0] BE_ISSUED = 2'b10;

  // ---------------------------------------------------------------------
  // Data structure
  // ---------------------------------------------------------------------
  logic [1:0]            ent_state            [BE_ROB_SIZE];  // State item 1
  logic [BE_TAG_W-1:0]   alloc_ptr;                           // State item 2
  logic [BE_TAG_W-1:0]   commit_ptr;                          // State item 3

  logic                  ent_is_lsu           [BE_ROB_SIZE];  // Header item 1
  logic                  ent_st_br_resolve    [BE_ROB_SIZE];  // Header item 2
  logic                  ent_read_side        [BE_ROB_SIZE];  // Header item 3
  logic                  ent_safe             [BE_ROB_SIZE];  // Header item 4
  logic                  ent_redirect_pending [BE_ROB_SIZE];  // Header item 5
  logic                  ent_is_csr           [BE_ROB_SIZE];  // CSR-class serialization flag
  logic [63:0]           ent_redirect_pc      [BE_ROB_SIZE];  // Payload item 1

  // Values computed this cycle by the negedge phase, used by combinational outputs and driving.
  logic                  flush_fire_c;
  logic                  commit_fire_c;
  logic [FE_LANES-1:0]   instr_ready_c;
  logic                  issue_valid_c;
  be_lsu_issue_pld_t     issue_pld_c;
  logic                  store_wakeup_c;
  logic                  redirect_valid_c;
  orbe_fe_redirect_pld_t redirect_pld_c;

  longint unsigned       phase_seq_q;

  // Trace output. This is a module and cannot get be_config, so it reads +VERBOSITY directly.
  // Convention matches be_reporter: 2 = major events, 3 = per-cycle details.
  int unsigned           trace_level = 1;
  longint unsigned       cyc_q;

  // Contract Interface -> In-event item 1: fe_be_instr_pld is sampled on the rising edge.
  // FE drives the next offer immediately after completing the handshake at posedge; reading
  // the interface directly at negedge would get the one after the handshake, off by a whole
  // delivery. So latch the handshake-cycle values at posedge, and the negedge model phase
  // uses only the latched values.
  logic [FE_LANES-1:0]                      fe_valid_q;
  orbe_fe_types_pkg::orbe_fe_instr_pld_t    fe_pld_q [FE_LANES];
  logic [FE_LANES-1:0]                      fe_ready_q;

  always @(posedge clk) begin : fe_capture
    if (!rst_n) begin
      fe_valid_q <= '0;
      fe_ready_q <= '0;
      foreach (fe_pld_q[i]) fe_pld_q[i] <= '0;
    end else begin
      fe_valid_q <= fe.fe_be_instr_valid;
      fe_ready_q <= instr_ready_c;
      foreach (fe_pld_q[i]) fe_pld_q[i] <= fe.fe_be_instr_pld[i];
    end
  end
  initial if (!$value$plusargs("VERBOSITY=%d", trace_level)) trace_level = 1;
  // ---------------------------------------------------------------------
  // Derived views (Data structure -> State item 1: not listed as separate state)
  // ---------------------------------------------------------------------
  function automatic int unsigned free_count();
    int unsigned n = 0;
    for (int unsigned k = 0; k < BE_ROB_SIZE; k++)
      if (ent_state[k] == BE_FREE) n++;
    return n;
  endfunction

  // prefix_safe[rob_idx] = walk(commit_ptr, rob_idx): whether all in-flight entries before
  // this entry in program order are resolved and exception-free. safe of a FREE entry is always 0.
  function automatic logic prefix_safe(input logic [BE_TAG_W-1:0] rob_idx);
    logic [BE_TAG_W-1:0] j = commit_ptr;
    for (int unsigned n = 0; n < BE_ROB_SIZE; n++) begin
      if (j == rob_idx) return 1'b1;
      if (!ent_safe[j])  return 1'b0;
      j = j + 1'b1;
    end
    return 1'b0;
  endfunction

  // CSR-class instructions (the set of model SpecCore::isCsrInsn: CSRRW/CSRRWI/CSRRS/CSRRSI/
  // CSRRC/CSRRCI/MRET/SRET/DRET). All are SYSTEM opcode 0x73: CSRR* have funct3≠0,
  // MRET/SRET/DRET have funct3=0 and funct12 of 0x302/0x102/0x7B2.
  // ECALL/EBREAK/WFI also have funct3=0 but are not in the set. A compressed instruction
  // can never be CSR-class.
  function automatic logic is_csr_class(input logic [31:0] bits);
    logic [11:0] funct12 = bits[31:20];
    if (bits[6:0] != 7'h73) return 1'b0;
    if (bits[14:12] != 3'b000) return 1'b1;
    return (funct12 == 12'h302) || (funct12 == 12'h102) || (funct12 == 12'h7B2);
  endfunction

  // Model SpecCore::issue rejects subsequent non-CSR allocation while "a CSR-class is already
  // in flight", noting this is so the RTL admission policy cannot deviate from the model's
  // architectural serialization boundary. Accordingly this Agent stops all allocation while a
  // CSR-class is in flight -- stricter than the model rule (the model only rejects non-CSR),
  // but never violating it, and consistent with rtl_v1's SerialInstructionTracker "single
  // in-flight serial instruction".
  function automatic logic csr_inflight();
    for (int unsigned k = 0; k < BE_ROB_SIZE; k++)
      if ((ent_state[k] != BE_FREE) && ent_is_csr[k]) return 1'b1;
    return 1'b0;
  endfunction

  // The ISA model and OR-BE encode RVC exe_subop differently; must normalize before delivery:
  //   model lib_FuncMultiCore.cpp  opcode_or_op = {funct3[2:0], op[1:0]}
  //   frozen package exe_subop_pkg.sv enc_c()  opcode_or_op = {5'b0,      op[1:0]}
  // They agree only when funct3 == 0, and RVC memory instructions all have nonzero funct3,
  // so every one mismatches; without normalization CacheAgent's req_property_from_subop
  // gets all-zero, not one-hot, and terminates.
  // Also clear high_fixed: RVC fixed bits do not go into the key. Same convention as the
  // existing be_getter.sv.
  function automatic logic [23:0] canonical_exe_subop(input logic [23:0] raw);
    logic [23:0] canonical = raw;
    if (raw[23:22] == 2'b10) begin
      canonical[21:17] = 5'b0;
      canonical[11:0]  = 12'b0;
    end
    return canonical;
  endfunction
  // read_side_from_property(p): read-side request classification (load / LR / AMO / SC).
  function automatic logic read_side_from_property(input lsu_req_property_t p);
    return p.is_load || p.is_lr || p.is_amo || p.is_sc;
  endfunction

  // [Split-1] Publish counters. Two uses: first, prove the events really were emitted
  // (otherwise "published" and "not published" look the same); second, the raw data needed
  // by the stage E "probe liveness check" -- every observable event fires at least once
  // under known stimulus.
  longint unsigned obs_fu_cnt     = 0;
  longint unsigned obs_commit_cnt = 0;

  final begin : obs_report
    $display("[BE_AGENT] [L1] [OBS] published fu_after=%0d commit=%0d",
             obs_fu_cnt, obs_commit_cnt);
  end

  // [Split-1] The observable event stream is cleared every cycle first, then set by each FSM
  // condition -- same convention as combinational outputs like be_lsu_issue (current-cycle
  // pulse). Only clear the three groups this Agent owns; mem_store_commit_* belongs to
  // CacheAgent and rst_n to the top level, not included here, otherwise multiple drivers.
  task automatic obs_clear();
    ob_cosim.decode_issue_valid       = '0;
    foreach (ob_cosim.decode_issue_pld[i]) ob_cosim.decode_issue_pld[i] = '0;
    ob_cosim.fu_after_valid           = '0;
    foreach (ob_cosim.fu_after_tag[i])     ob_cosim.fu_after_tag[i]     = '0;
    ob_cosim.fu_after_result          = '0;
    ob_cosim.fu_after_mispredict      = '0;
    ob_cosim.fu_after_exception       = '0;
    ob_cosim.fu_after_target          = '0;
    ob_cosim.fu_after_tval            = '0;
    ob_cosim.fu_after_cause           = '0;
    ob_cosim.fu_after_is_mret         = '0;
    ob_cosim.fu_after_is_sret         = '0;
    ob_cosim.fu_after_fflags          = '0;
    ob_cosim.commit_valid             = '0;
    ob_cosim.commit_count             = '0;   // [E-02]
    ob_cosim.commit_pc                = '0;
    ob_cosim.commit_rob_idx           = '0;
    ob_cosim.commit_result            = '0;
    ob_cosim.commit_rd_idx            = '0;
    ob_cosim.commit_rd_is_fp          = '0;
    ob_cosim.commit_rd_write_enable   = '0;
    ob_cosim.commit_fflags            = '0;
    ob_cosim.commit_exception_valid   = 1'b0;
    ob_cosim.commit_exception_cause   = '0;
    ob_cosim.commit_exception_tval    = '0;
    ob_cosim.commit_redirect_valid    = 1'b0;
    ob_cosim.commit_recovery_kind     = '0;
    ob_cosim.commit_redirect_pc       = '0;
    // [E-02] flush / recovery control plane. This BFM has the matching concepts, so both DUT
    // kinds drive the same shape.
    ob_cosim.flush_valid              = 1'b0;
    ob_cosim.flush_tag                = '0;
    ob_cosim.recovery_valid           = 1'b0;
    ob_cosim.recovery_kind            = '0;
    ob_cosim.recovery_origin_tag      = '0;
    ob_cosim.recovery_squash_tag      = '0;
    ob_cosim.recovery_redirect_pc     = '0;
  endtask

  task automatic clear_all();
    for (int unsigned k = 0; k < BE_ROB_SIZE; k++) begin
      ent_state[k]            <= BE_FREE;
      ent_is_lsu[k]           <= 1'b0;
      ent_st_br_resolve[k]    <= 1'b0;
      ent_read_side[k]        <= 1'b0;
      ent_safe[k]             <= 1'b0;
      ent_redirect_pending[k] <= 1'b0;
      ent_is_csr[k]           <= 1'b0;
      ent_redirect_pc[k]      <= '0;
    end
    alloc_ptr  <= '0;
    commit_ptr <= '0;
  endtask

  // ---------------------------------------------------------------------
  // negedge model phase: evaluate in the order commit -> flush -> issue -> alloc.
  // The order is mandated by the contract: issue_ptr depends on commit.fire, flush.fire
  // depends on commit.fire, issue.fire depends on ¬flush.fire, and alloc does not fire in a
  // cycle where flush.fire is 1.
  // All fire conditions and payload values read the start-of-cycle Data structure values.
  // ---------------------------------------------------------------------
  always @(negedge clk) begin : model_phase
    automatic logic [BE_TAG_W-1:0] rob_idx;
    automatic logic [BE_TAG_W-1:0] issue_ptr;
    automatic logic                has_trap;
    automatic logic                flush_pending;
    automatic logic                lsu_wb_ok;
    automatic logic                done_ok;
    automatic logic                exc_ok;
    automatic int                  rc;
    automatic byte unsigned        md_is_lsu, md_trap_valid;
    automatic longint unsigned     md_trap_cause, md_trap_tval;
    automatic byte unsigned        tr_valid;
    automatic longint unsigned     tr_cause, tr_tval;
    automatic longint unsigned     spec_pc;
    automatic byte unsigned        p_req_property, p_mem_funct3, p_rd_is_fp;
    automatic byte unsigned        p_imm_valid, p_is_store;
    automatic int unsigned         p_exe_subop;
    automatic longint unsigned     p_rs1_data, p_rs2_data;
    automatic longint signed       p_imm_data;
    automatic lsu_req_property_t   prop;
    automatic int unsigned         alloc_count;
    automatic logic                alloc0_fire, alloc1_fire;
    automatic logic                csr_alloc_now;
    automatic int unsigned         next_free;
    automatic longint unsigned     chk_dut_pc;

    obs_clear();

    if (!rst_n) begin
      // ---- [FSM-1] reset ------------------------------------------------
      clear_all();
      flush_fire_c     <= 1'b0;
      commit_fire_c    <= 1'b0;
      instr_ready_c    <= '0;
      issue_valid_c    <= 1'b0;
      issue_pld_c      <= '0;
      store_wakeup_c   <= 1'b0;
      redirect_valid_c <= 1'b0;
      redirect_pld_c   <= '0;
      phase_seq_q      <= 0;
      cyc_q            <= 0;
    end else begin
      commit_fire_c    = 1'b0;
      flush_fire_c     = 1'b0;
      issue_valid_c    = 1'b0;
      issue_pld_c      = '0;
      store_wakeup_c   = 1'b0;
      redirect_valid_c = 1'b0;
      redirect_pld_c   = '0;
      has_trap         = 1'b0;
      csr_alloc_now    = 1'b0;
      flush_pending    = 1'b0;

      // ---- [FSM-4] commit ----------------------------------------------
      rob_idx = commit_ptr;
      if (ent_state[rob_idx] == BE_ISSUED) begin
        // [R7] Once writeback was split into the done / exception channels, each is judged
        // on its own and they no longer share one condition. bypass is only an ancillary
        // requirement of done (bypass is driven only in the same cycle as a read-side
        // request's done), and it is now confined to the done branch.
        //
        // The R8 fix is absorbed by this refactor. Previously done and exception came from
        // one merged bus and looked like the same event here, so the bypass requirement was
        // attached to all read-side writebacks -- read-side memory exceptions therefore
        // never met the condition, the head entry stayed in ISSUED forever, whole-machine deadlock.
        // After the split that condition cannot be written: the exception branch cannot even reach bypass.
        done_ok = lsu.lsu_be_done_valid && lsu.be_lsu_entry_ready &&
                  (lsu.lsu_be_done_pld.tag == rob_idx) &&
                  (!ent_read_side[rob_idx] || lsu.lsu_be_bypass_valid);
        exc_ok  = lsu.lsu_be_exception_valid && lsu.be_lsu_entry_ready &&
                  (lsu.lsu_be_exception_pld.tag == rob_idx);
        lsu_wb_ok = done_ok || exc_ok;

        if (!ent_is_lsu[rob_idx] || lsu_wb_ok) begin
          commit_fire_c = 1'b1;

          // [Split-1] commit observation event (Out-event item 5, third group).
          // isa_dpi_get_insn_pc must be read before isa_dpi_commit_auto -- after commit
          // the ROB entry is released and cannot be read.
          // [Split-2] This read is timing-sensitive, so it stays in F; the PC goes to G2 with
          // the event, and the checker no longer calls get_insn_pc itself -- so no
          // cross-module ordering protocol is needed.
          chk_dut_pc                 = isa_dpi_get_insn_pc(MODEL_CORE_ID, longint'(rob_idx));
          ob_cosim.commit_valid[0]   = 1'b1;
          // [E-02] This BFM commits at most one per cycle (group 0 only), so this always equals
          // the bitwise sum of commit_valid. Both DUT kinds have the same shape, and stage 1
          // must also drive this field, otherwise the commit_count assertion reads X in the
          // agent kind.
          ob_cosim.commit_count      = 1;
          ob_cosim.commit_pc[0]      = chk_dut_pc;
          ob_cosim.commit_rob_idx[0] = OBS_TAG_W'(rob_idx);
          obs_commit_cnt             = obs_commit_cnt + 1;

          // Write the commit record to isa_commit.log (nothing in the environment had ever
          // called this facility).
          if (trace_level >= 2)
            isa_dpi_log_commit(MODEL_CORE_ID, longint'(rob_idx));

          // [Split-3] The commit event is handed to the G1 predictor. The advance sequences of
          // all three branches moved there as a whole, and it checks has_trap itself to pick
          // the branch; this BFM only hands over redirect_pending.
          // trap_record_valid / trap_cause / spec_pc are queried by the predictor on our behalf
          // and returned -- they must fall in the window after commit_auto and before
          // tick_finish; left to this BFM they could only be queried after the event returns,
          // when the tick has already advanced.
          predictor_commit(MODEL_CORE_ID, longint'(rob_idx), longint'(BE_ROB_SIZE),
                           ent_redirect_pending[rob_idx],
                           has_trap, tr_valid, tr_cause, tr_tval, spec_pc);
          flush_pending = has_trap || ent_redirect_pending[rob_idx];

          if (has_trap) begin
            // be_fe_redirect_pld values (Out-event item 3)
            redirect_pld_c.redirect_pc     = spec_pc;
            redirect_pld_c.trap_valid      = (tr_valid != 0) && !tr_cause[63];
            redirect_pld_c.interrupt_valid = (tr_valid != 0) &&  tr_cause[63];

            // [Split-1] Observation: trap branch. EXCP_CAUSE_W takes the interface default 63;
            // tr_cause[63] is the interrupt flag bit, [62:0] is the actual cause encoding.
            ob_cosim.commit_exception_valid = (tr_valid != 0);
            ob_cosim.commit_exception_cause = tr_cause[62:0];
            ob_cosim.commit_exception_tval  = tr_tval;
            ob_cosim.commit_redirect_valid  = 1'b1;
            ob_cosim.commit_redirect_pc     = spec_pc;

            // [E-02] flush / recovery control plane of the trap branch.
            // kind tells interrupt from exception by tr_cause[63], same convention as the
            // rtl_v1_obs side.
            ob_cosim.flush_valid          = 1'b1;
            ob_cosim.flush_tag            = rob_idx;
            ob_cosim.recovery_valid       = 1'b1;
            ob_cosim.recovery_kind        = tr_cause[63]
                ? orbe_cosim_obs_pkg::ORBE_RECOVERY_INTERRUPT
                : orbe_cosim_obs_pkg::ORBE_RECOVERY_EXCEPTION;
            ob_cosim.recovery_origin_tag  = rob_idx;
            ob_cosim.recovery_squash_tag  = rob_idx;
            ob_cosim.recovery_redirect_pc = spec_pc;
          end else if (ent_redirect_pending[rob_idx]) begin
            redirect_pld_c.redirect_pc     = ent_redirect_pc[rob_idx];
            redirect_pld_c.trap_valid      = 1'b0;
            redirect_pld_c.interrupt_valid = 1'b0;

            // [Split-1] Observation: redirect branch (no trap).
            ob_cosim.commit_redirect_valid = 1'b1;
            ob_cosim.commit_redirect_pc    = ent_redirect_pc[rob_idx];

            // [E-02] The redirect branch without trap is branch-misprediction recovery.
            ob_cosim.flush_valid          = 1'b1;
            ob_cosim.flush_tag            = rob_idx;
            ob_cosim.recovery_valid       = 1'b1;
            ob_cosim.recovery_kind        = orbe_cosim_obs_pkg::ORBE_RECOVERY_MISPREDICT;
            ob_cosim.recovery_origin_tag  = rob_idx;
            ob_cosim.recovery_squash_tag  = rob_idx;
            ob_cosim.recovery_redirect_pc = ent_redirect_pc[rob_idx];
          end

          ent_state[rob_idx] <= BE_FREE;
          ent_safe[rob_idx]  <= 1'b0;
          if (trace_level >= 2)
            $display("[%0t] [BE_AGENT] [L2] [COMMIT] cyc=%0d rob=%0d is_lsu=%0b has_trap=%0b flush=%0b",
                     $time, cyc_q, rob_idx, ent_is_lsu[rob_idx], has_trap, flush_pending);
          commit_ptr         <= rob_idx + 4'd1;
        end
      end

      // ---- [FSM-5] flush -------------------------------------------------
      if (commit_fire_c && flush_pending) begin
        flush_fire_c     = 1'b1;
        redirect_valid_c = 1'b1;              // be_fe_redirect.fire = flush.fire
        for (int unsigned k = 0; k < BE_ROB_SIZE; k++)
          if (k != int'(commit_ptr)) begin
            ent_state[k] <= BE_FREE;
            ent_safe[k]  <= 1'b0;
          end
        alloc_ptr <= commit_ptr + 4'd1;
      end

      // ---- [FSM-3] issue -------------------------------------------------
      issue_ptr = commit_fire_c ? (commit_ptr + 4'd1) : commit_ptr;
      if ((ent_state[issue_ptr] == BE_ALLOC) && !flush_fire_c) begin
        if (!ent_is_lsu[issue_ptr]) begin
          // Non-memory: advance model execution.
          // [Split-3] The execute event is handed to the G1 predictor.
          rc = predictor_execute(MODEL_CORE_ID, longint'(issue_ptr));
          // ISA_API_FAIL is not a violation: the model recorded a trap while executing the
          // instruction (e.g. accessing a nonexistent CSR raises illegal instruction). Advance
          // as usual; the trap is reported by get_execute_metadata and handled in commit's
          // has_trap branch.
          // ISA_API_PENDING: apply no further updates this cycle; retry the same issue_ptr
          // next cycle.
          if (rc != ISA_API_PENDING) begin
            rc = isa_dpi_get_execute_metadata(MODEL_CORE_ID, longint'(issue_ptr),
                                              md_trap_valid, md_trap_cause, md_trap_tval);
            if (rc != ISA_API_PASS)
              $fatal(1, "[BE] get_execute_metadata rob=%0d returned rc=%0d", issue_ptr, rc);

            ent_state[issue_ptr]            <= BE_ISSUED;
            ent_safe[issue_ptr]             <= (md_trap_valid == 0) &&
                (isa_dpi_is_insn_redirect(MODEL_CORE_ID, longint'(issue_ptr)) == 0);
            ent_redirect_pending[issue_ptr] <=
                (isa_dpi_is_insn_redirect(MODEL_CORE_ID, longint'(issue_ptr)) != 0);
            ent_redirect_pc[issue_ptr]      <=
                isa_dpi_get_next_pc_of_insn(MODEL_CORE_ID, longint'(issue_ptr));

            // [Split-1] fu_after observation event (Out-event item 5, second group).
            // The "execution" of a non-memory instruction leaves no trace at all on the BE
            // pins -- once the predictor switches to the observed event source,
            // isa_dpi_execute_insn can only be located by this group. The other three advance
            // points (alloc / commit / flush) are all visible on the pins. This is the core
            // reason it must be published here.
            ob_cosim.fu_after_valid[0]      = 1'b1;
            ob_cosim.fu_after_tag[0]        = OBS_TAG_W'(issue_ptr);
            ob_cosim.fu_after_exception[0]  = (md_trap_valid != 0);
            ob_cosim.fu_after_mispredict[0] =
                (isa_dpi_is_insn_redirect(MODEL_CORE_ID, longint'(issue_ptr)) != 0);
            ob_cosim.fu_after_target[0]     =
                isa_dpi_get_next_pc_of_insn(MODEL_CORE_ID, longint'(issue_ptr));
            obs_fu_cnt                      = obs_fu_cnt + 1;

            if (trace_level >= 3)
              $display("[%0t] [BE_AGENT] [L3] [ISSUE_EXE] cyc=%0d rob=%0d trap=%0b",
                       $time, cyc_q, issue_ptr, (md_trap_valid != 0));
          end
        end else begin
          // Memory: metadata is called in every cycle with state==ALLOC ∧ is_lsu,
          // regardless of the value of lsu_be_issue_ready.
          rc = isa_dpi_get_lsu_issue_metadata(MODEL_CORE_ID, longint'(issue_ptr),
                                              p_req_property, p_exe_subop,
                                              p_mem_funct3, p_rd_is_fp,
                                              p_rs1_data, p_rs2_data,
                                              p_imm_valid, p_imm_data, p_is_store);
          if (rc != ISA_API_PASS)
            $fatal(1, "[BE] get_lsu_issue_metadata rob=%0d returned rc=%0d", issue_ptr, rc);

          if (lsu.lsu_be_issue_ready) begin
            prop = lsu_req_property_t'(p_req_property);

            // be_lsu_issue_pld values (Out-event item 1)
            issue_valid_c              = 1'b1;
            issue_pld_c.self_tag       = issue_ptr;
            issue_pld_c.rs1_data       = p_rs1_data;
            issue_pld_c.imm_valid      = (p_imm_valid != 0);
            issue_pld_c.imm_data       = p_imm_data;
            issue_pld_c.rs2_data       = p_rs2_data;
            issue_pld_c.mem_funct3     = p_mem_funct3[LSU_MEM_F3_W-1:0];
            issue_pld_c.rd_is_fp       = (p_rd_is_fp != 0);
            issue_pld_c.exe_subop      = canonical_exe_subop(p_exe_subop[LSU_EXE_SUBOP_W-1:0]);
            // [R8] Two fields of the upstream shape. req_property is derived from exe_subop;
            // is_store takes the LSU metadata from the model -- two independent sources.
            issue_pld_c.req_property   = req_property_from_subop(issue_pld_c.exe_subop);
            issue_pld_c.is_store       = (p_is_store != 0);
            // Only a plain store carries st_br_resolve: the LSU side terminates outright on a
            // payload that is "not a plain store yet has it set", and rtl_v1 likewise forces
            // it to zero for non-plain stores.
            issue_pld_c.st_br_resolve  = ent_st_br_resolve[issue_ptr] && (p_is_store != 0);

            // be_lsu_store_wakeup.fire = issue.fire ∧ store_wakeup_pending
            store_wakeup_c = (p_is_store != 0) &&
                             !ent_st_br_resolve[issue_ptr] &&
                             (isa_dpi_has_pending_interrupt(MODEL_CORE_ID) == 0);

            ent_state[issue_ptr]            <= BE_ISSUED;
            ent_read_side[issue_ptr]        <= read_side_from_property(prop);
            if (trace_level >= 2)
              $display("[%0t] [BE_AGENT] [L2] [ISSUE_LSU] cyc=%0d rob=%0d subop=0x%0h f3=%0h rs1=0x%0h rs2=0x%0h imm_v=%0b imm=0x%0h is_store=%0b st_br=%0b",
                       $time, cyc_q, issue_ptr, p_exe_subop, p_mem_funct3,
                       p_rs1_data, p_rs2_data, (p_imm_valid != 0), p_imm_data,
                       (p_is_store != 0), ent_st_br_resolve[issue_ptr]);
            ent_redirect_pending[issue_ptr] <= 1'b0;
          end
        end
      end

      // ---- [FSM-2] alloc[s] ----------------------------------------------
      // alloc does not fire in a cycle where flush.fire is 1.
      // Use the handshake values latched at posedge: ready also takes the latched value,
      // otherwise the ready newly computed this cycle would judge a handshake that already
      // completed in the previous cycle.
      alloc0_fire = !flush_fire_c && fe_valid_q[0] && fe_ready_q[0];
      alloc1_fire = alloc0_fire   && fe_valid_q[1] && fe_ready_q[1];
      alloc_count = int'(alloc0_fire) + int'(alloc1_fire);

      for (int unsigned s = 0; s < FE_LANES; s++) begin
        automatic logic fired = (s == 0) ? alloc0_fire : alloc1_fire;
        if (fired) begin
          rob_idx = alloc_ptr + BE_TAG_W'(s);
          // A slot being released by commit this cycle is visible to alloc: state is updated
          // non-blocking, so what is read here is still the start-of-cycle value.
          if ((ent_state[rob_idx] != BE_FREE) &&
              !(commit_fire_c && (rob_idx == commit_ptr)))
            $fatal(1, "[BE] alloc lane %0d targets rob=%0d which is not FREE", s, rob_idx);

          // [Split-3] The alloc event is handed to the G1 predictor. decode_and_issue and
          // fetch-exception injection are both model-advancing, so this BFM no longer calls
          // them directly; the reason is_compressed is not inverted, and the reason "fetch
          // exceptions must be injected here or it deadlocks", moved into the predictor with
          // the code.
          predictor_alloc(MODEL_CORE_ID, longint'(rob_idx),
                          fe_pld_q[s].pc,
                          fe_pld_q[s].inst_bits,
                          fe_pld_q[s].is_compressed,
                          fe_pld_q[s].fetch_excp_vld,
                          longint'(fe_pld_q[s].exception_cause),
                          fe_pld_q[s].exception_tval);
          if (fe_pld_q[s].fetch_excp_vld && (trace_level >= 2))
            $display("[%0t] [BE_AGENT] [L2] [FETCH_TRAP] cyc=%0d rob=%0d pc=0x%0h cause=%0d tval=0x%0h",
                     $time, cyc_q, rob_idx, fe_pld_q[s].pc,
                     fe_pld_q[s].exception_cause, fe_pld_q[s].exception_tval);
          rc = isa_dpi_get_decode_metadata(MODEL_CORE_ID, longint'(rob_idx),
                                           md_is_lsu, md_trap_valid,
                                           md_trap_cause, md_trap_tval);
          if (rc != ISA_API_PASS)
            $fatal(1, "[BE] get_decode_metadata rob=%0d returned rc=%0d", rob_idx, rc);

          ent_state[rob_idx]            <= BE_ALLOC;
          ent_is_lsu[rob_idx]           <= (md_is_lsu != 0);
          ent_st_br_resolve[rob_idx]    <= prefix_safe(rob_idx) &&
              (isa_dpi_has_pending_interrupt(MODEL_CORE_ID) == 0);
          ent_read_side[rob_idx]        <= 1'b0;
          ent_safe[rob_idx]             <= 1'b0;
          ent_redirect_pending[rob_idx] <= 1'b0;
          ent_is_csr[rob_idx]           <= is_csr_class(fe_pld_q[s].inst_bits);
          if (is_csr_class(fe_pld_q[s].inst_bits)) csr_alloc_now = 1'b1;
          if (trace_level >= 2)
            $display("[%0t] [BE_AGENT] [L2] [ALLOC] cyc=%0d lane=%0d rob=%0d pc=0x%0h inst=0x%08h cmp=%0b is_lsu=%0b st_br=%0b",
                     $time, cyc_q, s, rob_idx, fe_pld_q[s].pc,
                     fe_pld_q[s].inst_bits, fe_pld_q[s].is_compressed,
                     (md_is_lsu != 0),
                     prefix_safe(rob_idx) && (isa_dpi_has_pending_interrupt(MODEL_CORE_ID) == 0));
        end
      end
      if (alloc_count != 0)
        alloc_ptr <= alloc_ptr + BE_TAG_W'(alloc_count);

      // ---- Out Static Info item 1 (with the [R4] fix) ---------------------
      // No allocation while a CSR-class is in flight (see the csr_inflight comment).
      // csr_inflight() reads the state before the non-blocking updates and cannot see the one
      // just allocated this cycle, so judge together with this cycle's flag, otherwise the
      // instruction right after the CSR would still be rejected by the model.
      // free_count() reads the start-of-cycle state and cannot see this cycle's alloc and
      // commit (both non-blocking). The ready computed this cycle governs next cycle's alloc,
      // so convert to the start of next cycle: subtract what was allocated this cycle, add back
      // what commit released this cycle. In a flush cycle ready is 0 anyway; no need to be exact.
      next_free = free_count() - alloc_count + (commit_fire_c ? 1 : 0);
      instr_ready_c[0] = rst_n && !flush_fire_c && !csr_inflight() && !csr_alloc_now &&
                         (next_free >= 1);
      // lane 1 additionally requires that what lane 0 offers this cycle is not CSR-class: once
      // a CSR is in flight the model rejects subsequent non-CSR allocation, and both lanes'
      // handshakes complete in the same cycle and cannot be taken back afterwards.
      // The fe_be_instr_pld[0] read here is exactly the one to be handshaken at this cycle's posedge.
      instr_ready_c[1] = rst_n && !flush_fire_c && !csr_inflight() && !csr_alloc_now &&
                         (next_free >= 2) && fe.fe_be_instr_valid[0] &&
                         !is_csr_class(fe.fe_be_instr_pld[0].inst_bits);

      // [R2] Phase sequence advance: Cache issues model calls at negedge only after it becomes
      // larger than in the previous cycle.
      phase_seq_q <= phase_seq_q + 1;
      cyc_q <= cyc_q + 1;
    end
  end

  // ---------------------------------------------------------------------
  // Boundary driving. Notify and Transaction are both current-cycle values, computed by the
  // model phase above.
  // ---------------------------------------------------------------------
  assign fe.be_fe_instr_ready     = rst_n ? instr_ready_c : '0;
  assign fe.be_fe_redirect_valid  = rst_n ? redirect_valid_c : 1'b0;
  assign fe.be_fe_redirect_pld    = redirect_pld_c;

  // lsu.rst_n is distributed centrally by the top-level be_tb_top.sv; this module does not
  // drive it (otherwise a multiple-driver conflict).
  assign lsu.be_lsu_issue_valid        = rst_n ? issue_valid_c : 1'b0;
  assign lsu.be_lsu_issue_pld          = issue_pld_c;
  assign lsu.be_lsu_store_wakeup_valid = rst_n ? store_wakeup_c : 1'b0;
  assign lsu.global_flush_late         = rst_n ? flush_fire_c : 1'b0;

  // Out Static Info item 2: be_lsu_entry_ready = rst_n ∧ ¬flush.fire
  assign lsu.be_lsu_entry_ready        = rst_n && !flush_fire_c;

  // [R2] The phase sequence carrier is ob_if.
  assign ob.dpi_be_phase_seq           = phase_seq_q;

endmodule
