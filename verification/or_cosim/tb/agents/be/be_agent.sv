// [This file] predictor (the rtl_v1 kind): advances the shared ISA model in program order at allocation; writeback/issue events only gather evidence
// Backend observer and sole BE-side owner of decode/execute/commit/recovery DPI.
class be_agent;
  localparam int unsigned MODEL_CORE_ID = 0;
  localparam int unsigned DPI_ROB_IDX_W = BE_ROB_ADDR_W;

  virtual ob_if ob_vif;
  virtual ob_cosim_if #(BE_ISSUE_NUM, BE_ROB_ADDR_W) ob_cosim_vif;
  virtual orbe_fe_if fe_vif;
  be_config cfg;
  be_getter getter;
  mailbox #(cosim_commit_event_t) cosim_commit_events;
  mailbox #(cosim_arch_state_event_t) cosim_arch_state_events;
  // COSIM event publisher. Publishing depends only on the neutral event stream and is the same
  // implementation for both DUT kinds, so it is no longer inlined here.
  cosim_publisher pub;
  bit stop_requested;
  bit model_ready;

  bit allocated_by_rob[longint unsigned];
  bit lsu_by_rob[longint unsigned];
  bit execute_started_by_rob[longint unsigned];
  bit pending_by_rob[longint unsigned];
  // [R9] Program-order advance queue and its state (see the notes on drain_exec_queue)
  longint unsigned exec_queue[$];
  bit executed_by_rob[longint unsigned];
  int exec_rc_by_rob[longint unsigned];
  bit lsu_issued_by_rob[longint unsigned];
  longint unsigned lsu_issued_cycle_by_rob[longint unsigned];
  bit wb_seen_by_rob[longint unsigned];
  // [R9-b] Exit gating (see run())
  bit exit_pending;
  bit exit_wait_valid;
  longint unsigned exit_wait_rob;
  bit exit_ready;
  int unsigned exit_wait_cycles;
  longint unsigned last_mem_store_rob;
  bit last_mem_store_rob_valid;
  bit store_wait_by_rob[longint unsigned];   // [R9-b'] stores drained but not yet committed from the ROB (kept for observation)
  bit exit_wait_set[longint unsigned];       // [R9-b''] robs in flight when exit appears; exit only after all are committed/flushed
  longint unsigned last_commit_cycle;        // [R9-b'''] cycle number of the most recent ROB commit (for the fallback)
  bit exit_stall_reported;
  logic [BE_ROB_TAG_W-1:0] full_tag_by_rob[longint unsigned];
  longint unsigned pc_by_rob[longint unsigned];
  longint unsigned ref_pc_by_rob[longint unsigned];
  longint unsigned ref_redirect_pc_by_rob[longint unsigned];
  byte unsigned ref_recovery_kind_by_rob[longint unsigned];
  longint unsigned allocation_order_by_rob[longint unsigned];
`ifdef ORBE_EXTERNAL_MNEMONICS
  longint signed inst_type_by_rob[longint unsigned];
`endif
  longint unsigned next_allocation_order;

`ifdef ORBE_DUT_RTL_V1
  // Decode lifecycle snapshot captured at allocation and consumed at termination.
  typedef struct {
    bit valid;
    logic [63:0] pc;
    logic [63:0] ref_pc;
    logic [31:0] inst_bits;
    bit is_compressed;
    bit fetch_excp_vld;
    logic [4:0] rs1_idx;
    logic [4:0] rs2_idx;
    logic [4:0] rs3_idx;
    logic [4:0] rd_idx;
    logic [4:0] ref_rs1_idx;
    logic [4:0] ref_rs2_idx;
    logic [4:0] ref_rs3_idx;
    logic [4:0] ref_rd_idx;
    bit rs1_is_fp;
    bit rs2_is_fp;
    bit rs3_is_fp;
    bit rd_is_fp;
    bit ref_rs1_is_fp;
    bit ref_rs2_is_fp;
    bit ref_rs3_is_fp;
    bit ref_rd_is_fp;
    bit use_rs1;
    bit use_rs2;
    bit use_rs3;
    bit use_rd;
    bit is_store;
    bit ref_is_store;
    logic [2:0] mem_funct3;
    logic [2:0] ref_mem_funct3;
    bit imm_valid;
    bit ref_imm_valid;
    logic [63:0] imm_data;
    logic [63:0] ref_imm_data;
    logic [23:0] exe_subop;
    logic [23:0] ref_exe_subop;
    bit is_serial;
    bit is_fp_instruction;
    bit is_atomic;
    bit dec_is_fp_opcode;
    logic [16:0] full_decode;
  } l2_decode_t;
  l2_decode_t l2_decode_by_rob[longint unsigned];

  typedef struct {
    bit valid;
    logic [63:0] result;
    logic [63:0] target;
    logic [63:0] tval;
    logic [63:0] ref_result;
    logic [63:0] ref_target;
    logic [63:0] ref_tval;
    logic [62:0] cause;
    logic [62:0] ref_cause;
    bit mispredict;
    bit exception;
    bit is_mret;
    bit is_sret;
    logic [4:0] fpu_fflags;
    bit ref_mispredict;
    bit ref_exception;
  } l2_wb_t;
  l2_wb_t l2_wb_by_rob[longint unsigned];

  typedef struct {
    bit valid;
    logic [6:0] req_property;
    logic [6:0] ref_req_property;
    logic [23:0] exe_subop;
    logic [23:0] ref_exe_subop;
    logic [2:0] mem_funct3;
    logic [2:0] ref_mem_funct3;
    bit rd_is_fp;
    bit ref_rd_is_fp;
    bit imm_valid;
    bit ref_imm_valid;
    bit is_store;
    bit ref_is_store;
    logic [63:0] rs1_data;
    logic [63:0] ref_rs1_data;
    logic [63:0] store_data;
    logic [63:0] ref_store_data;
    logic [63:0] imm_data;
    logic [63:0] ref_imm_data;
  } l2_lsu_t;
  l2_lsu_t l2_lsu_by_rob[longint unsigned];

  typedef struct {
    bit g0_valid;
    cosim_isq_g0_issue_pld_t g0;
    bit g1_valid;
    cosim_isq_g1_issue_pld_t g1;
    bit g2_valid;
    cosim_isq_g2_issue_pld_t g2;
    bit g3_valid;
    cosim_isq_g3_issue_pld_t g3;
  } l2_isq_t;
  l2_isq_t l2_isq_by_rob[longint unsigned];

  typedef struct {
    bit done_valid;
    logic [63:0] done_data;
    bit exception_valid;
    logic [62:0] exception_cause;
    logic [63:0] exception_tval;
    bit bypass_valid;
    logic [63:0] bypass_data;
  } l2_lsu_response_t;
  l2_lsu_response_t l2_lsu_response_by_rob[longint unsigned];

  typedef struct {
    bit valid;
    logic [11:0] addr;
    logic [63:0] rdata;
    logic [2:0] current_priv;
    bit fs_enabled;
  } l2_csr_in_t;
  l2_csr_in_t l2_csr_in_by_rob[longint unsigned];
  
  typedef struct {
    bit valid;
    bit write_enable;
    logic [11:0] addr;
    logic [63:0] wdata;
    logic [BE_ROB_ADDR_W-1:0] exec_tag;
  } l2_csr_out_t;
  l2_csr_out_t l2_csr_out_by_rob[longint unsigned];
`endif

`ifdef ORBE_DUT_RTL_V1
  bit l2_lsu_mismatch_by_rob[longint unsigned];
`endif
  string l2_obs_by_rob[longint unsigned][$];
  string l2_cmp_by_rob[longint unsigned][$];
  bit l2_any_mismatch_by_rob[longint unsigned];

  bit last_redirect_valid;
  bit last_recovery_valid;
  bit trap_commit_consumed;
  longint unsigned cycle_count;
  longint unsigned retire_count;
  longint unsigned retire_print_interval;
  // mem store dedup state moved into cosim_publisher together with publishing.

  function new(virtual ob_if ob_vif, virtual orbe_fe_if fe_vif,
               virtual ob_cosim_if #(BE_ISSUE_NUM, BE_ROB_ADDR_W) ob_cosim_vif,
               mailbox #(cosim_commit_event_t) cosim_commit_events,
               mailbox #(cosim_arch_state_event_t) cosim_arch_state_events,
               be_config cfg);
    if (cfg == null)
      be_reporter::fatal_static("[BE] be_agent requires be_config");
    this.ob_vif = ob_vif;
    this.ob_cosim_vif = ob_cosim_vif;
    this.fe_vif = fe_vif;
    this.cosim_commit_events = cosim_commit_events;
    this.cosim_arch_state_events = cosim_arch_state_events;
    this.cfg = cfg;
    if (cosim_commit_events == null)
      be_reporter::fatal_static("[BE] be_agent requires COSIM commit event mailbox");
    if (cosim_arch_state_events == null)
      be_reporter::fatal_static("[BE] be_agent requires COSIM architectural state mailbox");
    pub = new(ob_vif, ob_cosim_vif, cosim_commit_events,
              cosim_arch_state_events, cfg);
    getter = new(cfg);
    stop_requested = 1'b0;
    model_ready = 1'b0;
    last_redirect_valid = 1'b0;
    last_recovery_valid = 1'b0;
    trap_commit_consumed = 1'b0;
    cycle_count = 0;
    retire_count = 0;
    retire_print_interval = 1;
    exit_pending = 1'b0;
    exit_wait_valid = 1'b0;
    exit_wait_rob = 0;
    exit_ready = 1'b0;
    exit_wait_cycles = 0;
    last_mem_store_rob = 0;
    last_mem_store_rob_valid = 1'b0;
    last_commit_cycle = 0;
    exit_stall_reported = 1'b0;
    void'($value$plusargs("RETIRE_PRINT_INTERVAL=%d", retire_print_interval));
    if (retire_print_interval == 0)
      cfg.reporter.fatal("[BE] RETIRE_PRINT_INTERVAL must be non-zero");
    next_allocation_order = 0;
    ob_vif.dpi_be_phase_seq = 0;
    if (BE_ROB_ADDR_W != DPI_ROB_IDX_W)
      cfg.reporter.fatal("[BE] observer/model ROB width mismatch");
  endfunction

  function automatic logic [DPI_ROB_IDX_W-1:0] dpi_rob_idx(
      input longint unsigned rob_idx);
    return rob_idx[DPI_ROB_IDX_W-1:0];
  endfunction

  function automatic bit level2_enabled();
    return cfg.cosim_enable && (cfg.cosim_level >= 2);
  endfunction

  function automatic bit recovery_commits_origin(
      input orbe_recovery_kind_e kind);
    case (kind)
      ORBE_RECOVERY_MISPREDICT,
      ORBE_RECOVERY_MRET,
      ORBE_RECOVERY_FENCE_I,
      ORBE_RECOVERY_SRET:
        return 1'b1;
      default:
        return 1'b0;
    endcase
  endfunction

  function automatic bit recovery_kind_known(
      input orbe_recovery_kind_e kind);
    case (kind)
      ORBE_RECOVERY_MISPREDICT,
      ORBE_RECOVERY_EXCEPTION,
      ORBE_RECOVERY_MRET,
      ORBE_RECOVERY_INTERRUPT,
      ORBE_RECOVERY_FENCE_I,
      ORBE_RECOVERY_SRET:
        return 1'b1;
      default:
        return 1'b0;
    endcase
  endfunction

  function automatic string recovery_kind_name(
      input orbe_recovery_kind_e kind);
    case (kind)
      ORBE_RECOVERY_MISPREDICT: return "mispredict";
      ORBE_RECOVERY_EXCEPTION:  return "exception";
      ORBE_RECOVERY_MRET:       return "mret";
      ORBE_RECOVERY_INTERRUPT:  return "interrupt";
      ORBE_RECOVERY_FENCE_I:    return "fence_i";
      ORBE_RECOVERY_SRET:       return "sret";
      default:                  return "reserved";
    endcase
  endfunction

  task automatic check_rc(input string operation, input int rc);
    if (rc != ISA_API_PASS)
      cfg.reporter.fatal($sformatf("[BE] %s failed rc=%0d", operation, rc));
  endtask

  task automatic publish_cosim_arch_state_observation();
    pub.publish_arch_state();
  endtask

  task automatic wait_for_model();
    while (!stop_requested) begin
      @(negedge ob_vif.clk);
      if (isa_dpi_is_config_ready()) begin
        model_ready = 1'b1;
        cfg.print_be(1, $sformatf("[BE][MODEL_READY] cycle=%0d model_ready=1",
                                  cycle_count));
        return;
      end
    end
  endtask

  task automatic clear_local_anchors();
    allocated_by_rob.delete();
    lsu_by_rob.delete();
    execute_started_by_rob.delete();
    pending_by_rob.delete();
    exec_queue.delete();
    exit_wait_set.delete();          // [R9-b''] after recovery there are no older in-flight instructions
    executed_by_rob.delete();
    exec_rc_by_rob.delete();
    lsu_issued_by_rob.delete();
    lsu_issued_cycle_by_rob.delete();
    wb_seen_by_rob.delete();
    full_tag_by_rob.delete();
    pc_by_rob.delete();
    ref_pc_by_rob.delete();
    ref_redirect_pc_by_rob.delete();
    ref_recovery_kind_by_rob.delete();
    allocation_order_by_rob.delete();
`ifdef ORBE_DUT_RTL_V1
    l2_decode_by_rob.delete();
    l2_lsu_mismatch_by_rob.delete();
    l2_obs_by_rob.delete();
    l2_cmp_by_rob.delete();
    l2_any_mismatch_by_rob.delete();
    l2_wb_by_rob.delete();
    l2_lsu_by_rob.delete();
    l2_isq_by_rob.delete();
    l2_lsu_response_by_rob.delete();
`endif
`ifdef ORBE_EXTERNAL_MNEMONICS
    inst_type_by_rob.delete();
`endif
  endtask

  // Sample the product-neutral COSIM boundary and hand structured events to
  // the adapter. The adapter owns cycle and sequence counters.
  task automatic publish_cosim_commit_event(input int unsigned group,
                                            input longint unsigned pc,
                                            input longint unsigned rob_idx,
                                            input longint unsigned ref_result,
                                            input int unsigned ref_rd_idx,
                                            input bit ref_rd_is_fp,
                                            input longint signed mnemonic_code,
                                            input int unsigned ref_recovery_kind,
                                            input longint unsigned ref_redirect_pc);
    bit l2_mismatch;

`ifdef ORBE_DUT_RTL_V1
    l2_mismatch = l2_any_mismatch_by_rob.exists(rob_idx) &&
                  l2_any_mismatch_by_rob[rob_idx];
`else
    l2_mismatch = 1'b0;
`endif
    pub.publish_commit(group, pc, rob_idx, ref_result, ref_rd_idx, ref_rd_is_fp,
                       mnemonic_code, ref_recovery_kind, ref_redirect_pc,
                       l2_mismatch);
  endtask

  task automatic publish_cosim_recovery_event(input longint unsigned rob_idx,
                                              input longint unsigned ref_pc,
                                              input int unsigned ref_kind,
                                              input longint unsigned ref_redirect_pc,
                                              input longint unsigned ref_cause,
                                              input longint unsigned ref_tval);
    longint signed mnemonic_code;
    bit l2_mismatch;

    mnemonic_code = '0;
`ifdef ORBE_EXTERNAL_MNEMONICS
    if (inst_type_by_rob.exists(rob_idx))
      mnemonic_code = inst_type_by_rob[rob_idx];
`endif
`ifdef ORBE_DUT_RTL_V1
    l2_mismatch = l2_any_mismatch_by_rob.exists(rob_idx) &&
                  l2_any_mismatch_by_rob[rob_idx];
`else
    l2_mismatch = 1'b0;
`endif
    pub.publish_recovery(rob_idx,
                         pc_by_rob.exists(rob_idx) ? pc_by_rob[rob_idx] : 0,
                         ref_pc, ref_kind, ref_redirect_pc, ref_cause, ref_tval,
                         mnemonic_code, l2_mismatch);
  endtask

  task automatic publish_cosim_commit_observation();
    // Commit events are published in observe_commits(), immediately before
    // commitAuto(), while the corresponding RTL-driven model entry is valid.
  endtask

  task automatic publish_cosim_mem_observation();
    bit published;
    bit terminal_store;
    longint unsigned rob_out;

    // Publishing belongs to pub; exit orchestration and ROB bookkeeping are the advancing
    // side's job and stay in this class.
    // terminal_hint: the model's exit is latched only at tick_finish at the end of this cycle,
    // so when this observation is sampled is_to_exit() is most likely still 0 -- which is
    // exactly why [R9-b] below remembers the most recent store.
    pub.publish_mem_store((isa_dpi_is_to_exit() != 0),
                          published, rob_out, terminal_store);
    if (!published)
      return;

    // [R9-b] Remember the rob of the most recent store. The real wait target is taken from
    // here when run() sees exit: the last store before exit is by construction the tohost one.
    last_mem_store_rob = rob_out;
    last_mem_store_rob_valid = 1'b1;
    if (allocated_by_rob.exists(rob_out))
      store_wait_by_rob[rob_out] = 1'b1;   // [R9-b'] wait for its ROB commit
    if (terminal_store && !exit_wait_valid) begin
      exit_wait_valid = 1'b1;              // configurations where the model reports exit in the same cycle go here
      exit_wait_rob = rob_out;
    end
  endtask

  task automatic publish_cosim_dut_exit_observation();
    pub.publish_dut_exit();
  endtask

  task automatic publish_cosim_cycle_end_observation();
    pub.publish_cycle_end();
  endtask

  task automatic observe_allocations();
    longint unsigned rob_idx;
    longint signed insn_id;
    bit getter_is_lsu;
    int trap_rc;

    if (ob_vif.recovery_valid || ob_vif.alloc_valid == '0)
      return;
    for (int group = 0; group < BE_ISSUE_NUM; group++) begin
      if (!ob_vif.alloc_valid[group])
        continue;
      rob_idx = ob_vif.alloc_tag[group];
      // [Advance convergence] Event 1 · alloc is handed to the single advance implementation
      // of the BE domain. The advance sequence (decode_and_issue → trigger_trap on a fetch
      // exception) is owned by the predictor; only diagnostic prints remain here. The contract
      // states explicitly that event 1 has "outputs: none"; failures $fatal inside the predictor.
      predictor_alloc(MODEL_CORE_ID, dpi_rob_idx(rob_idx),
                      ob_vif.alloc_pld[group].pc,
                      ob_vif.alloc_pld[group].inst_bits,
                      ob_vif.alloc_pld[group].is_compressed,
                      ob_vif.alloc_pld[group].fetch_excp_vld,
                      ob_vif.alloc_pld[group].exception_cause,
                      ob_vif.alloc_pld[group].exception_tval);
      if (ob_vif.alloc_pld[group].fetch_excp_vld)
        cfg.print_be(2, $sformatf(
            "[BE][FETCH_TRAP] cycle=%0d group=%0d rob=%0d pc=0x%016h cause=%0d tval=0x%016h",
            cycle_count, group, rob_idx, ob_vif.alloc_pld[group].pc,
            ob_vif.alloc_pld[group].exception_cause,
            ob_vif.alloc_pld[group].exception_tval));
      full_tag_by_rob[rob_idx] = ob_vif.alloc_tag[group][BE_ROB_TAG_W-1:0];
      getter.after_decode(group, full_tag_by_rob[rob_idx], dpi_rob_idx(rob_idx),
                          getter_is_lsu);
`ifdef ORBE_DUT_RTL_V1
      if (level2_enabled()) begin
        byte unsigned ref_decode_is_lsu;
        byte unsigned ref_decode_trap_valid;
        longint unsigned ref_decode_trap_cause;
        longint unsigned ref_decode_trap_tval;
        byte unsigned ref_rs1_valid;
        byte unsigned ref_rs2_valid;
        byte unsigned ref_rs3_valid;
        byte unsigned ref_rs1_is_fp;
        byte unsigned ref_rs2_is_fp;
        byte unsigned ref_rs3_is_fp;
        int unsigned ref_rs1_idx;
        int unsigned ref_rs2_idx;
        int unsigned ref_rs3_idx;
        byte unsigned ref_is_store;
        byte unsigned ref_imm_valid;
        longint signed ref_imm_data;
        int unsigned ref_exe_subop;
        byte unsigned ref_rd_valid;
        byte unsigned ref_rd_is_fp;
        byte unsigned ref_rd_write_enable;
        int unsigned ref_rd_idx;
        longint unsigned ref_rd_value;
        byte unsigned ref_recovery_kind;
        int ref_decode_rc;

        ref_decode_rc = isa_dpi_get_decode_metadata(
            MODEL_CORE_ID,
            dpi_rob_idx(rob_idx),
            ref_decode_is_lsu,
            ref_decode_trap_valid,
            ref_decode_trap_cause,
            ref_decode_trap_tval);
        check_rc($sformatf("getDecodeMetadata rob=%0d", rob_idx),
                 ref_decode_rc);
        ref_decode_rc = isa_dpi_get_decode_semantic(
            MODEL_CORE_ID,
            dpi_rob_idx(rob_idx),
            ref_rs1_valid,
            ref_rs2_valid,
            ref_rs3_valid,
            ref_rs1_is_fp,
            ref_rs2_is_fp,
            ref_rs3_is_fp,
            ref_rs1_idx,
            ref_rs2_idx,
            ref_rs3_idx,
            ref_is_store,
            ref_imm_valid,
            ref_imm_data,
            ref_exe_subop);
        check_rc($sformatf("getDecodeSemantic rob=%0d", rob_idx),
                 ref_decode_rc);
        ref_decode_rc = isa_dpi_get_insn_metadata(
            MODEL_CORE_ID,
            dpi_rob_idx(rob_idx),
            ref_rd_valid,
            ref_rd_is_fp,
            ref_rd_write_enable,
            ref_rd_idx,
            ref_rd_value,
            ref_recovery_kind);
        check_rc($sformatf("getInsnMetadata rob=%0d", rob_idx),
                 ref_decode_rc);
        l2_decode_by_rob[rob_idx].valid = 1'b1;
        l2_decode_by_rob[rob_idx].pc = ob_vif.alloc_pld[group].pc;
        l2_decode_by_rob[rob_idx].ref_pc = isa_dpi_get_insn_pc(
            MODEL_CORE_ID, dpi_rob_idx(rob_idx));
        l2_decode_by_rob[rob_idx].inst_bits =
            ob_vif.alloc_pld[group].inst_bits;
        l2_decode_by_rob[rob_idx].is_compressed =
            ob_vif.alloc_pld[group].is_compressed;
        l2_decode_by_rob[rob_idx].fetch_excp_vld =
            ob_vif.alloc_pld[group].fetch_excp_vld;
        l2_decode_by_rob[rob_idx].rs1_idx =
            ob_cosim_vif.decode_issue_pld[group].rs1_idx;
        l2_decode_by_rob[rob_idx].rs2_idx =
            ob_cosim_vif.decode_issue_pld[group].rs2_idx;
        l2_decode_by_rob[rob_idx].rs3_idx =
            ob_cosim_vif.decode_issue_pld[group].rs3_idx;
        l2_decode_by_rob[rob_idx].rd_idx =
            ob_cosim_vif.decode_issue_pld[group].rd_idx;
        l2_decode_by_rob[rob_idx].rs1_is_fp =
            ob_cosim_vif.decode_issue_pld[group].rs1_is_fp;
        l2_decode_by_rob[rob_idx].rs2_is_fp =
            ob_cosim_vif.decode_issue_pld[group].rs2_is_fp;
        l2_decode_by_rob[rob_idx].rs3_is_fp =
            ob_cosim_vif.decode_issue_pld[group].rs3_is_fp;
        l2_decode_by_rob[rob_idx].rd_is_fp =
            ob_cosim_vif.decode_issue_pld[group].rd_is_fp;
        l2_decode_by_rob[rob_idx].use_rs1 =
            ob_cosim_vif.decode_issue_pld[group].use_rs1;
        l2_decode_by_rob[rob_idx].use_rs2 =
            ob_cosim_vif.decode_issue_pld[group].use_rs2;
        l2_decode_by_rob[rob_idx].use_rs3 =
            ob_cosim_vif.decode_issue_pld[group].use_rs3;
        l2_decode_by_rob[rob_idx].use_rd =
            ob_cosim_vif.decode_issue_pld[group].use_rd;
        l2_decode_by_rob[rob_idx].is_store =
            ob_cosim_vif.decode_issue_pld[group].is_store;
        l2_decode_by_rob[rob_idx].mem_funct3 =
            ob_cosim_vif.decode_issue_pld[group].mem_funct3;
        l2_decode_by_rob[rob_idx].imm_valid =
            ob_cosim_vif.decode_issue_pld[group].imm_valid;
        l2_decode_by_rob[rob_idx].imm_data =
            ob_cosim_vif.decode_issue_pld[group].imm_data;
        l2_decode_by_rob[rob_idx].exe_subop =
            ob_cosim_vif.decode_issue_pld[group].exe_subop;
        l2_decode_by_rob[rob_idx].is_serial =
            ob_cosim_vif.decode_issue_pld[group].is_serial;
        l2_decode_by_rob[rob_idx].is_fp_instruction =
            ob_cosim_vif.decode_issue_pld[group].is_fp_instruction;
        l2_decode_by_rob[rob_idx].is_atomic =
            ob_cosim_vif.decode_issue_pld[group].is_atomic;
        l2_decode_by_rob[rob_idx].dec_is_fp_opcode =
            ob_cosim_vif.decode_issue_pld[group].dec_is_fp_opcode;
        l2_decode_by_rob[rob_idx].full_decode =
            ob_cosim_vif.decode_issue_pld[group].full_decode;
        l2_decode_by_rob[rob_idx].ref_rs1_idx = ref_rs1_idx[4:0];
        l2_decode_by_rob[rob_idx].ref_rs2_idx = ref_rs2_idx[4:0];
        l2_decode_by_rob[rob_idx].ref_rs3_idx = ref_rs3_idx[4:0];
        l2_decode_by_rob[rob_idx].ref_is_store = ref_is_store != 0;
        l2_decode_by_rob[rob_idx].ref_imm_valid = ref_imm_valid != 0;
        l2_decode_by_rob[rob_idx].ref_imm_data = ref_imm_data;
        l2_decode_by_rob[rob_idx].ref_exe_subop = ref_exe_subop[23:0];
        l2_decode_by_rob[rob_idx].ref_rs1_is_fp = ref_rs1_is_fp != 0;
        l2_decode_by_rob[rob_idx].ref_rs2_is_fp = ref_rs2_is_fp != 0;
        l2_decode_by_rob[rob_idx].ref_rs3_is_fp = ref_rs3_is_fp != 0;
        l2_decode_by_rob[rob_idx].ref_rd_idx = ref_rd_idx[4:0];
        l2_decode_by_rob[rob_idx].ref_rd_is_fp = ref_rd_is_fp != 0;
      end
`endif
      allocated_by_rob[rob_idx] = 1'b1;
      lsu_by_rob[rob_idx] = getter_is_lsu;
      execute_started_by_rob.delete(rob_idx);
      pending_by_rob.delete(rob_idx);
      executed_by_rob.delete(rob_idx);
      exec_rc_by_rob.delete(rob_idx);
      lsu_issued_by_rob.delete(rob_idx);
      lsu_issued_cycle_by_rob.delete(rob_idx);
      wb_seen_by_rob.delete(rob_idx);
      exec_queue.push_back(rob_idx);   // [R9] program order = allocation order
      pc_by_rob[rob_idx] = ob_vif.alloc_pld[group].pc;
      allocation_order_by_rob[rob_idx] = next_allocation_order++;
`ifdef ORBE_EXTERNAL_MNEMONICS
      inst_type_by_rob[rob_idx] = isa_dpi_decode_mnemonic(
          ob_vif.alloc_pld[group].inst_bits,
          ob_vif.alloc_pld[group].is_compressed);
      if (inst_type_by_rob[rob_idx] < 0)
        cfg.reporter.fatal($sformatf(
            "[BE] external mnemonic decode failed group=%0d rob=%0d pc=0x%016h inst=0x%08h compressed=%0b",
            group, rob_idx, ob_vif.alloc_pld[group].pc,
            ob_vif.alloc_pld[group].inst_bits,
            ob_vif.alloc_pld[group].is_compressed));
`endif
      cfg.print_be(2, $sformatf(
          "[BE][DECODE] cycle=%0d group=%0d order=%0d tag=0x%0h rob=%0d id=%0d pc=0x%016h inst=0x%08h compressed=%0b lsu=%0b fetch_excp=%0b",
          cycle_count, group, allocation_order_by_rob[rob_idx],
          full_tag_by_rob[rob_idx], rob_idx, insn_id,
          ob_vif.alloc_pld[group].pc, ob_vif.alloc_pld[group].inst_bits,
          ob_vif.alloc_pld[group].is_compressed, getter_is_lsu,
          ob_vif.alloc_pld[group].fetch_excp_vld));
    end
    drain_exec_queue();   // [R9]
  endtask

  task automatic finish_execute(input longint unsigned rob_idx, input int rc,
                                input string operation);
    bit trap_valid;
    if (rc == ISA_API_PENDING) begin
      pending_by_rob[rob_idx] = 1'b1;
      cfg.print_be(2, $sformatf(
          "[BE][EXECUTE_PENDING] cycle=%0d rob=%0d tag=0x%0h operation=%s rc=%0d",
          cycle_count, rob_idx, full_tag_by_rob[rob_idx], operation, rc));
      return;
    end
    trap_valid = isa_dpi_has_trap(MODEL_CORE_ID, dpi_rob_idx(rob_idx)) != 0;
    if (trap_valid)
      cfg.print_be(2, $sformatf(
          "[BE][EXECUTE_TRAP] cycle=%0d rob=%0d tag=0x%0h operation=%s rc=%0d trap_valid=1",
          cycle_count, rob_idx, full_tag_by_rob[rob_idx], operation, rc));
    if ((rc == ISA_API_FAIL) && !trap_valid)
      cfg.reporter.fatal($sformatf("[BE] %s failed without model trap rc=%0d", operation, rc));
    if ((rc != ISA_API_PASS) && (rc != ISA_API_SKIP)
        && !((rc == ISA_API_FAIL) && trap_valid))
      cfg.reporter.fatal($sformatf("[BE] %s invalid rc=%0d", operation, rc));
    pending_by_rob.delete(rob_idx);
    getter.after_execute(full_tag_by_rob[rob_idx], dpi_rob_idx(rob_idx));
  endtask

  // ── [R9] The model advances in program order ──────────────────────────────
  // isa_model's dependency lookup (SpecCore::lookupOlderWriter) only recognizes "executed"
  // writers: it identifies writers by output.rd.valid, which is set only at execute. So
  // execute_insn must be called in program order -- if an older one has not executed, a
  // younger one computes with the stale committed register.
  // RTL is an out-of-order machine and exec/LSU events interleave across cycles
  // (rv64ui-p-simple: the store is issued to LSU at cycle 175, while the exec event of the
  // auipc producing its base address arrives only at cycle 176, and the model computes
  // paddr=-52 with the old x30).
  // Hence: enqueue at allocation; non-memory head → execute_insn immediately; memory head →
  // Cache completes execute_insn + proc_mem_load in the LSU issue cycle (same cycle, and it
  // runs after this agent), released next cycle.
  // Only the head is executed, younger always after older; writeback events no longer
  // advance the model.
  task automatic observe_lsu_issue_handshake();
    longint unsigned rob_idx;
    if (ob_cosim_vif.be_lsu_issue_valid !== 1'b1) return;
    if (ob_cosim_vif.lsu_be_issue_ready !== 1'b1) return;
    rob_idx = ob_cosim_vif.be_lsu_issue_pld.self_tag;
    if (!allocated_by_rob.exists(rob_idx)) return;
    lsu_issued_by_rob[rob_idx] = 1'b1;
    lsu_issued_cycle_by_rob[rob_idx] = cycle_count;
  endtask

  task automatic capture_l2_ref(input longint unsigned rob_idx);
    int rc;
    wb_seen_by_rob.delete(rob_idx);
    if (!exec_rc_by_rob.exists(rob_idx)) return;
    rc = exec_rc_by_rob[rob_idx];
`ifdef ORBE_DUT_RTL_V1
    if (!l2_wb_by_rob.exists(rob_idx) || !l2_wb_by_rob[rob_idx].valid) return;
    if (level2_enabled() && (rc == ISA_API_PASS || rc == ISA_API_SKIP)) begin
        l2_wb_by_rob[rob_idx].ref_result = isa_dpi_get_insn_rd_value(MODEL_CORE_ID, dpi_rob_idx(rob_idx));
        l2_wb_by_rob[rob_idx].ref_mispredict = isa_dpi_is_insn_redirect(MODEL_CORE_ID, dpi_rob_idx(rob_idx));
        l2_wb_by_rob[rob_idx].ref_target = isa_dpi_get_next_pc_of_insn(MODEL_CORE_ID, dpi_rob_idx(rob_idx));
        l2_wb_by_rob[rob_idx].ref_exception = isa_dpi_has_trap(MODEL_CORE_ID, dpi_rob_idx(rob_idx));
        if (l2_wb_by_rob[rob_idx].ref_exception) begin
          byte unsigned cap;
          longint unsigned cc;
          longint unsigned tt;

          cap = 0;
          cc = 0;
          tt = 0;
          void'(isa_dpi_get_execute_metadata(
              MODEL_CORE_ID, dpi_rob_idx(rob_idx), cap, cc, tt));
          l2_wb_by_rob[rob_idx].ref_cause = cc[62:0];
          l2_wb_by_rob[rob_idx].ref_tval = tt;
        end
    end
`endif
  endtask

  task automatic drain_exec_queue();
    longint unsigned rob_idx;
    int rc;
    while (exec_queue.size() != 0) begin
      rob_idx = exec_queue[0];
      if (!allocated_by_rob.exists(rob_idx)) begin
        void'(exec_queue.pop_front());
        continue;
      end
      if (lsu_by_rob[rob_idx]) begin
        // Memory instructions are advanced by Cache. In the issue cycle itself Cache has not
        // run yet (BE runs before Cache), so release next cycle.
        if (lsu_issued_by_rob.exists(rob_idx) &&
            (lsu_issued_cycle_by_rob[rob_idx] < cycle_count)) begin
          executed_by_rob[rob_idx] = 1'b1;
          void'(exec_queue.pop_front());
          continue;
        end
        return;
      end
      // [Advance convergence] Event 2 · execute is handed to the single advance implementation
      // of the BE domain. Memory entries do not go here (they belong to cache_agent's LSU
      // domain; the two domains are complementary, no overlap).
      rc = predictor_execute(MODEL_CORE_ID, dpi_rob_idx(rob_idx));
      finish_execute(rob_idx, rc, $sformatf("executeInsn@alloc rob=%0d", rob_idx));
      if (rc == ISA_API_PENDING)
        return;                       // finish_execute has registered pending; retry from the head next cycle
      executed_by_rob[rob_idx] = 1'b1;
      exec_rc_by_rob[rob_idx] = rc;
      if (wb_seen_by_rob.exists(rob_idx))
        capture_l2_ref(rob_idx);
      void'(exec_queue.pop_front());
    end
  endtask

  task automatic retry_pending_execution();
    drain_exec_queue();   // [R9] the only retry point is the queue head
  endtask

  task automatic observe_execution_writebacks();
    for (int source = 0; source < BE_ROB_CMT_NUM; source++) begin
      longint unsigned rob_idx;
      int rc;
      if (!ob_vif.exec_valid[source])
        continue;
      rob_idx = ob_vif.exec_tag[source];
      if (!allocated_by_rob.exists(rob_idx)) begin
        cfg.print_be(3, $sformatf("[BE] ignore stale execute rob=%0d", rob_idx));
        continue;
      end
      if (lsu_by_rob[rob_idx])
        continue;
      if (execute_started_by_rob.exists(rob_idx))
        continue;
      execute_started_by_rob[rob_idx] = 1'b1;
`ifdef ORBE_DUT_RTL_V1
      // Save the RTL completion payload before advancing the ISA model.
      if (level2_enabled() && (!l2_wb_by_rob.exists(rob_idx) || !l2_wb_by_rob[rob_idx].valid)) begin
        l2_wb_by_rob[rob_idx].valid = 1'b1;
        l2_wb_by_rob[rob_idx].result = ob_cosim_vif.fu_after_result[source];
        l2_wb_by_rob[rob_idx].mispredict = ob_cosim_vif.fu_after_mispredict[source];
        l2_wb_by_rob[rob_idx].target = ob_cosim_vif.fu_after_target[source];
        l2_wb_by_rob[rob_idx].exception = ob_cosim_vif.fu_after_exception[source];
        l2_wb_by_rob[rob_idx].cause = ob_cosim_vif.fu_after_cause[source];
        l2_wb_by_rob[rob_idx].tval = ob_cosim_vif.fu_after_tval[source];
        l2_wb_by_rob[rob_idx].is_mret = ob_cosim_vif.fu_after_is_mret[source];
        l2_wb_by_rob[rob_idx].is_sret = ob_cosim_vif.fu_after_is_sret[source];
        l2_wb_by_rob[rob_idx].fpu_fflags = ob_cosim_vif.fu_after_fflags[source];
      end
`endif
      // [R9] The model was already advanced in program order at the allocation cycle; here we
      // only take the reference-side values for the Level-2 comparison.
      // If the model has not executed it yet (a memory instruction ahead in the queue is
      // waiting for Cache), defer until it executes.
      if (executed_by_rob.exists(rob_idx))
        capture_l2_ref(rob_idx);
      else
        wb_seen_by_rob[rob_idx] = 1'b1;
    end
  endtask

`ifdef ORBE_DUT_RTL_V1
  task automatic observe_fe_be_interface();
    // FE-BE is an event-level observation and never enters per-ROB state.
    if (!level2_enabled())
      return;
    for (int lane = 0; lane < 2; lane++) begin
      if (fe_vif.fe_be_instr_valid[lane] !== 1'b0 && fe_vif.fe_be_instr_valid[lane] !== 1'b1)
        cfg.reporter.fatal($sformatf("[BE][COSIM] FE-BE valid contains X/Z lane=%0d", lane));
      if (fe_vif.fe_be_instr_valid[lane] !== 1'b1)
        continue;
      if (fe_vif.be_fe_instr_ready[lane] !== 1'b1)
        continue;
      if (^fe_vif.fe_be_instr_pld[lane].pc === 1'bx)
        cfg.reporter.fatal($sformatf("[BE][COSIM] FE-BE pc contains X/Z lane=%0d", lane));
      if (^fe_vif.fe_be_instr_pld[lane].inst_bits === 1'bx)
        cfg.reporter.fatal($sformatf("[BE][COSIM] FE-BE inst_bits contains X/Z lane=%0d", lane));
      if (fe_vif.fe_be_instr_pld[lane].is_compressed !== 1'b0 &&
          fe_vif.fe_be_instr_pld[lane].is_compressed !== 1'b1)
        cfg.reporter.fatal($sformatf("[BE][COSIM] FE-BE is_compressed contains X/Z lane=%0d", lane));
      cfg.reporter.diagnostic($sformatf(
          "[BE_TB] [COSIM] [FE-BE] cycle=%0d lane=%0d pc=0x%016h inst=0x%08h is_compressed=%0b pred_taken=%0b pred_target_pc=0x%016h fetch_excp_vld=%0b exception_cause=0x%0h exception_tval=0x%016h (OBSERVATION ONLY, NOT COMPARED)",
          cycle_count, lane, fe_vif.fe_be_instr_pld[lane].pc,
          fe_vif.fe_be_instr_pld[lane].inst_bits,
          fe_vif.fe_be_instr_pld[lane].is_compressed,
          fe_vif.fe_be_instr_pld[lane].pred_taken,
          fe_vif.fe_be_instr_pld[lane].pred_target_pc,
          fe_vif.fe_be_instr_pld[lane].fetch_excp_vld,
          fe_vif.fe_be_instr_pld[lane].exception_cause,
          fe_vif.fe_be_instr_pld[lane].exception_tval));
    end
    if (fe_vif.be_fe_redirect_valid !== 1'b0 && fe_vif.be_fe_redirect_valid !== 1'b1)
      cfg.reporter.fatal("[BE][COSIM] BE-FE redirect valid contains X/Z");
    if (fe_vif.be_fe_redirect_valid === 1'b1) begin
      if (^fe_vif.be_fe_redirect_pld.redirect_pc === 1'bx)
        cfg.reporter.fatal("[BE][COSIM] BE-FE redirect_pc contains X/Z");
      cfg.reporter.diagnostic($sformatf(
          "[BE_TB] [COSIM] [FE-BE] cycle=%0d redirect_pc=0x%016h interrupt_valid=%0b trap_valid=%0b (OBSERVATION ONLY, NOT COMPARED)",
          cycle_count, fe_vif.be_fe_redirect_pld.redirect_pc,
          fe_vif.be_fe_redirect_pld.interrupt_valid,
          fe_vif.be_fe_redirect_pld.trap_valid));
    end
  endtask

  task automatic consume_decode(input longint unsigned rob_idx);
    bit mismatch;

    if (!level2_enabled())
      return;

    if (!l2_decode_by_rob.exists(rob_idx))
      return;

    if (!l2_decode_by_rob[rob_idx].valid)
      return;

    if (l2_decode_by_rob[rob_idx].fetch_excp_vld) begin
      l2_cmp_by_rob[rob_idx].push_back(
          "[BE_TB] [COSIM] [DECODE] fetch exception; semantic decode comparison skipped");
      l2_decode_by_rob.delete(rob_idx);
      l2_isq_by_rob.delete(rob_idx);
      l2_lsu_response_by_rob.delete(rob_idx);
      return;
    end

    l2_obs_by_rob[rob_idx].push_back($sformatf(
        "[BE_TB] [COSIM] [DECODE] inst_bits=0x%08h is_compressed=%0b use_rs1=%0b use_rs2=%0b use_rs3=%0b use_rd=%0b is_serial=%0b is_fp_instruction=%0b is_atomic=%0b dec_is_fp_opcode=%0b full_decode.csr_write_intent=%0b full_decode.illegal=%0b full_decode.rm=%0d full_decode.csr_addr=0x%03h mem_funct3=%0d (OBSERVATION ONLY, NOT COMPARED)",
        l2_decode_by_rob[rob_idx].inst_bits,
        l2_decode_by_rob[rob_idx].is_compressed,
        l2_decode_by_rob[rob_idx].use_rs1,
        l2_decode_by_rob[rob_idx].use_rs2,
        l2_decode_by_rob[rob_idx].use_rs3,
        l2_decode_by_rob[rob_idx].use_rd,
        l2_decode_by_rob[rob_idx].is_serial,
        l2_decode_by_rob[rob_idx].is_fp_instruction,
        l2_decode_by_rob[rob_idx].is_atomic,
        l2_decode_by_rob[rob_idx].dec_is_fp_opcode,
        l2_decode_by_rob[rob_idx].full_decode[16],
        l2_decode_by_rob[rob_idx].full_decode[15],
        l2_decode_by_rob[rob_idx].full_decode[14:12],
        l2_decode_by_rob[rob_idx].full_decode[11:0],
        l2_decode_by_rob[rob_idx].mem_funct3));

    mismatch = 1'b0;
    if (l2_decode_by_rob[rob_idx].pc !== l2_decode_by_rob[rob_idx].ref_pc)
      mismatch = 1'b1;
    if (l2_decode_by_rob[rob_idx].use_rs1 && l2_decode_by_rob[rob_idx].ref_rs1_idx != 0 &&
        ((l2_decode_by_rob[rob_idx].rs1_idx !==
          l2_decode_by_rob[rob_idx].ref_rs1_idx) ||
         (l2_decode_by_rob[rob_idx].rs1_is_fp !==
          l2_decode_by_rob[rob_idx].ref_rs1_is_fp)))
      mismatch = 1'b1;
    if (l2_decode_by_rob[rob_idx].use_rs2 && l2_decode_by_rob[rob_idx].ref_rs2_idx != 0 &&
        ((l2_decode_by_rob[rob_idx].rs2_idx !==
          l2_decode_by_rob[rob_idx].ref_rs2_idx) ||
         (l2_decode_by_rob[rob_idx].rs2_is_fp !==
          l2_decode_by_rob[rob_idx].ref_rs2_is_fp)))
      mismatch = 1'b1;
    if (l2_decode_by_rob[rob_idx].use_rs3 && l2_decode_by_rob[rob_idx].ref_rs3_idx != 0 &&
        ((l2_decode_by_rob[rob_idx].rs3_idx !==
          l2_decode_by_rob[rob_idx].ref_rs3_idx) ||
         (l2_decode_by_rob[rob_idx].rs3_is_fp !==
          l2_decode_by_rob[rob_idx].ref_rs3_is_fp)))
      mismatch = 1'b1;
    if (l2_decode_by_rob[rob_idx].use_rd && l2_decode_by_rob[rob_idx].ref_rd_idx != 0 &&
        ((l2_decode_by_rob[rob_idx].rd_idx !==
          l2_decode_by_rob[rob_idx].ref_rd_idx) ||
         (l2_decode_by_rob[rob_idx].rd_is_fp !==
          l2_decode_by_rob[rob_idx].ref_rd_is_fp)))
      mismatch = 1'b1;
    if (l2_decode_by_rob[rob_idx].is_store !==
        l2_decode_by_rob[rob_idx].ref_is_store)
      mismatch = 1'b1;
    // System/serial entries intentionally expose no operand/immediate path.
    // Do not compare the model's raw encoding slices for those entries.
    if (l2_decode_by_rob[rob_idx].use_rs1 ||
        l2_decode_by_rob[rob_idx].use_rs2 ||
        l2_decode_by_rob[rob_idx].use_rs3 ||
        l2_decode_by_rob[rob_idx].use_rd ||
        l2_decode_by_rob[rob_idx].is_store) begin
      if (l2_decode_by_rob[rob_idx].imm_valid !==
          l2_decode_by_rob[rob_idx].ref_imm_valid)
        mismatch = 1'b1;
      if (l2_decode_by_rob[rob_idx].imm_valid &&
          l2_decode_by_rob[rob_idx].ref_imm_valid &&
          l2_decode_by_rob[rob_idx].imm_data !==
          l2_decode_by_rob[rob_idx].ref_imm_data)
        mismatch = 1'b1;
    end
    if (l2_decode_by_rob[rob_idx].exe_subop !==
        l2_decode_by_rob[rob_idx].ref_exe_subop)
      mismatch = 1'b1;
    if (mismatch) begin
      l2_any_mismatch_by_rob[rob_idx] = 1'b1;
      l2_cmp_by_rob[rob_idx].push_back($sformatf(
          "[BE_TB] [COSIM] [DECODE] pc=0x%016h (dut), 0x%016h (ref); rs1_idx=%0d (dut), %0d (ref); rs2_idx=%0d (dut), %0d (ref); rs3_idx=%0d (dut), %0d (ref); is_store=%0b (dut), %0b (ref); rd_idx=%0d (dut), %0d (ref); rd_is_fp=%0b (dut), %0b (ref); rs1_is_fp=%0b (dut), %0b (ref); rs2_is_fp=%0b (dut), %0b (ref); rs3_is_fp=%0b (dut), %0b (ref); imm_valid=%0b (dut), %0b (ref); imm_data=0x%016h (dut), 0x%016h (ref); exe_subop=0x%06h (dut), 0x%06h (ref)",
          l2_decode_by_rob[rob_idx].pc,
          l2_decode_by_rob[rob_idx].ref_pc,
          l2_decode_by_rob[rob_idx].rs1_idx,
          l2_decode_by_rob[rob_idx].ref_rs1_idx,
          l2_decode_by_rob[rob_idx].rs2_idx,
          l2_decode_by_rob[rob_idx].ref_rs2_idx,
          l2_decode_by_rob[rob_idx].rs3_idx,
          l2_decode_by_rob[rob_idx].ref_rs3_idx,
          l2_decode_by_rob[rob_idx].is_store,
          l2_decode_by_rob[rob_idx].ref_is_store,
          l2_decode_by_rob[rob_idx].rd_idx,
          l2_decode_by_rob[rob_idx].ref_rd_idx,
          l2_decode_by_rob[rob_idx].rd_is_fp,
          l2_decode_by_rob[rob_idx].ref_rd_is_fp,
          l2_decode_by_rob[rob_idx].rs1_is_fp,
          l2_decode_by_rob[rob_idx].ref_rs1_is_fp,
          l2_decode_by_rob[rob_idx].rs2_is_fp,
          l2_decode_by_rob[rob_idx].ref_rs2_is_fp,
          l2_decode_by_rob[rob_idx].rs3_is_fp,
          l2_decode_by_rob[rob_idx].ref_rs3_is_fp,
          l2_decode_by_rob[rob_idx].imm_valid,
          l2_decode_by_rob[rob_idx].ref_imm_valid,
          l2_decode_by_rob[rob_idx].imm_data,
          l2_decode_by_rob[rob_idx].ref_imm_data,
          l2_decode_by_rob[rob_idx].exe_subop,
          l2_decode_by_rob[rob_idx].ref_exe_subop));
    end else begin
      l2_cmp_by_rob[rob_idx].push_back(
          "[BE_TB] [COSIM] [DECODE] all compared fields match");
    end
    l2_decode_by_rob.delete(rob_idx);
  endtask

  task automatic observe_isq_issue();
    longint unsigned rob_idx;
    if (!level2_enabled())
      return;
    if (ob_cosim_vif.isq_g0_issue_valid === 1'b1) begin
      rob_idx = ob_cosim_vif.isq_g0_issue_pld.self_tag;
      l2_isq_by_rob[rob_idx].g0_valid = 1'b1;
      l2_isq_by_rob[rob_idx].g0 = ob_cosim_vif.isq_g0_issue_pld;
    end
    if (ob_cosim_vif.isq_g1_issue_valid === 1'b1) begin
      rob_idx = ob_cosim_vif.isq_g1_issue_pld.self_tag;
      l2_isq_by_rob[rob_idx].g1_valid = 1'b1;
      l2_isq_by_rob[rob_idx].g1 = ob_cosim_vif.isq_g1_issue_pld;
    end
    if (ob_cosim_vif.isq_g2_issue_valid === 1'b1) begin
      rob_idx = ob_cosim_vif.isq_g2_issue_pld.self_tag;
      l2_isq_by_rob[rob_idx].g2_valid = 1'b1;
      l2_isq_by_rob[rob_idx].g2 = ob_cosim_vif.isq_g2_issue_pld;
    end
    if (ob_cosim_vif.isq_g3_issue_valid === 1'b1) begin
      rob_idx = ob_cosim_vif.isq_g3_issue_pld.self_tag;
      l2_isq_by_rob[rob_idx].g3_valid = 1'b1;
      l2_isq_by_rob[rob_idx].g3 = ob_cosim_vif.isq_g3_issue_pld;
    end
  endtask

  task automatic consume_isq_response(input longint unsigned rob_idx);
    if (l2_isq_by_rob.exists(rob_idx)) begin
      if (l2_isq_by_rob[rob_idx].g0_valid)
        l2_obs_by_rob[rob_idx].push_back($sformatf("[BE_TB] [COSIM] [ISQ0] cycle=%0d self_tag=0x%0h pc=0x%016h inst=0x%08h rs1=0x%016h rs2=0x%016h (OBSERVATION ONLY, NOT COMPARED)", cycle_count, l2_isq_by_rob[rob_idx].g0.self_tag, l2_isq_by_rob[rob_idx].g0.pc, l2_isq_by_rob[rob_idx].g0.inst_bits, l2_isq_by_rob[rob_idx].g0.rs1_data, l2_isq_by_rob[rob_idx].g0.rs2_data));
      if (l2_isq_by_rob[rob_idx].g1_valid)
        l2_obs_by_rob[rob_idx].push_back($sformatf("[BE_TB] [COSIM] [ISQ1] cycle=%0d self_tag=0x%0h rs1=0x%016h rs2=0x%016h imm=0x%016h (OBSERVATION ONLY, NOT COMPARED)", cycle_count, l2_isq_by_rob[rob_idx].g1.self_tag, l2_isq_by_rob[rob_idx].g1.rs1_data, l2_isq_by_rob[rob_idx].g1.rs2_data, l2_isq_by_rob[rob_idx].g1.imm_data));
      if (l2_isq_by_rob[rob_idx].g2_valid)
        l2_obs_by_rob[rob_idx].push_back($sformatf("[BE_TB] [COSIM] [ISQ2] cycle=%0d self_tag=0x%0h rs1=0x%016h rs2=0x%016h rs3=0x%016h (OBSERVATION ONLY, NOT COMPARED)", cycle_count, l2_isq_by_rob[rob_idx].g2.self_tag, l2_isq_by_rob[rob_idx].g2.rs1_data, l2_isq_by_rob[rob_idx].g2.rs2_data, l2_isq_by_rob[rob_idx].g2.rs3_data));
      if (l2_isq_by_rob[rob_idx].g3_valid)
        l2_obs_by_rob[rob_idx].push_back($sformatf("[BE_TB] [COSIM] [ISQ3] cycle=%0d self_tag=0x%0h rs1=0x%016h store=0x%016h imm=0x%016h (OBSERVATION ONLY, NOT COMPARED)", cycle_count, l2_isq_by_rob[rob_idx].g3.self_tag, l2_isq_by_rob[rob_idx].g3.rs1_data, l2_isq_by_rob[rob_idx].g3.store_data, l2_isq_by_rob[rob_idx].g3.imm_data));
      l2_isq_by_rob.delete(rob_idx);
    end
  endtask

  task automatic consume_csr_events(input longint unsigned rob_idx);
    if (l2_csr_in_by_rob.exists(rob_idx)) begin
      if (l2_csr_in_by_rob[rob_idx].valid)
        l2_obs_by_rob[rob_idx].push_back($sformatf(
            "[BE_TB] [COSIM] [CSR_IN] csr_addr=0x%03h; csr_rdata=0x%016h; current_priv=%0d; fs_enabled=%0b (OBSERVATION ONLY, NOT COMPARED)",
            l2_csr_in_by_rob[rob_idx].addr,
            l2_csr_in_by_rob[rob_idx].rdata,
            l2_csr_in_by_rob[rob_idx].current_priv,
            l2_csr_in_by_rob[rob_idx].fs_enabled));
      l2_csr_in_by_rob.delete(rob_idx);
    end
    if (l2_csr_out_by_rob.exists(rob_idx)) begin
      if (l2_csr_out_by_rob[rob_idx].valid)
        l2_obs_by_rob[rob_idx].push_back($sformatf(
            "[BE_TB] [COSIM] [CSR_OUT] exec_tag=0x%0h; csr_write_enable=%0b; csr_addr=0x%03h; csr_wdata=0x%016h (OBSERVATION ONLY, NOT COMPARED)",
            l2_csr_out_by_rob[rob_idx].exec_tag,
            l2_csr_out_by_rob[rob_idx].write_enable,
            l2_csr_out_by_rob[rob_idx].addr,
            l2_csr_out_by_rob[rob_idx].wdata));
      l2_csr_out_by_rob.delete(rob_idx);
    end
  endtask

  task automatic observe_csr_events();
    longint unsigned csr_in_rob_idx;
    longint unsigned csr_out_rob_idx;
    if (!level2_enabled())
      return;
    if (ob_cosim_vif.csr_in_valid === 1'b1) begin
      csr_in_rob_idx = ob_cosim_vif.csr_in_tag;
      l2_csr_in_by_rob[csr_in_rob_idx].valid = 1'b1;
      l2_csr_in_by_rob[csr_in_rob_idx].addr = ob_cosim_vif.csr_in_addr;
      l2_csr_in_by_rob[csr_in_rob_idx].rdata = ob_cosim_vif.csr_in_rdata;
      l2_csr_in_by_rob[csr_in_rob_idx].current_priv = ob_cosim_vif.csr_in_current_priv;
      l2_csr_in_by_rob[csr_in_rob_idx].fs_enabled = ob_cosim_vif.csr_in_fs_enabled;
    end
    if (ob_cosim_vif.csr_out_valid === 1'b1) begin
      csr_out_rob_idx = ob_cosim_vif.csr_out_exec_tag;
      l2_csr_out_by_rob[csr_out_rob_idx].valid = 1'b1;
      l2_csr_out_by_rob[csr_out_rob_idx].write_enable = ob_cosim_vif.csr_out_write_enable;
      l2_csr_out_by_rob[csr_out_rob_idx].addr = ob_cosim_vif.csr_out_addr;
      l2_csr_out_by_rob[csr_out_rob_idx].wdata = ob_cosim_vif.csr_out_wdata;
      l2_csr_out_by_rob[csr_out_rob_idx].exec_tag = ob_cosim_vif.csr_out_exec_tag;
    end
  endtask

  task automatic consume_writeback(
      input longint unsigned rob_idx,
      input longint unsigned ref_result,
      input bit use_rd,
      input longint unsigned dut_commit_result);
    byte unsigned ref_exception;
    longint unsigned ref_cause;
    longint unsigned ref_tval;
    bit mismatch;
    string mismatch_details;

    if (!level2_enabled())
      return;

    if (!l2_wb_by_rob.exists(rob_idx) || !l2_wb_by_rob[rob_idx].valid)
      return;

    mismatch = 1'b0;
    mismatch_details = "";
    ref_exception = l2_wb_by_rob[rob_idx].ref_exception;
    ref_cause = l2_wb_by_rob[rob_idx].ref_cause;
    ref_tval = l2_wb_by_rob[rob_idx].ref_tval;

    // Result is compared only when the committed instruction writes rd.
    if (use_rd &&
        l2_wb_by_rob[rob_idx].result !== l2_wb_by_rob[rob_idx].ref_result) begin
      mismatch = 1'b1;
      mismatch_details = $sformatf("result=0x%016h (dut), 0x%016h (ref); ", l2_wb_by_rob[rob_idx].result, l2_wb_by_rob[rob_idx].ref_result);
    end

    // RTL mispredict and target have different semantics from the ISA redirect API.
    // They are therefore observation-only, as required by impl section 6.1.

    // Exception flag itself is compared for every writeback event.
    if (l2_wb_by_rob[rob_idx].exception !== ref_exception) begin
      mismatch = 1'b1;
      mismatch_details = {mismatch_details, $sformatf("exception=%0b (dut), %0b (ref); ", l2_wb_by_rob[rob_idx].exception, ref_exception)};
    end

    // Cause and tval are compared only when both exception flags are asserted.
    if (l2_wb_by_rob[rob_idx].exception && ref_exception &&
        ((l2_wb_by_rob[rob_idx].cause !== ref_cause[62:0]) ||
         (l2_wb_by_rob[rob_idx].tval !== ref_tval))) begin
      mismatch = 1'b1;
      if (l2_wb_by_rob[rob_idx].cause !== ref_cause[62:0])
        mismatch_details = {mismatch_details, $sformatf("cause=0x%0h (dut), 0x%0h (ref); ", l2_wb_by_rob[rob_idx].cause, ref_cause)};
      if (l2_wb_by_rob[rob_idx].tval !== ref_tval)
        mismatch_details = {mismatch_details, $sformatf("tval=0x%016h (dut), 0x%016h (ref); ", l2_wb_by_rob[rob_idx].tval, ref_tval)};
    end

    if (mismatch) begin
      l2_any_mismatch_by_rob[rob_idx] = 1'b1;
      l2_cmp_by_rob[rob_idx].push_back($sformatf("[BE_TB] [COSIM] [WRITEBACK] %s", mismatch_details));
    end else begin
      l2_cmp_by_rob[rob_idx].push_back("[BE_TB] [COSIM] [WRITEBACK] all compared fields match");
    end
    l2_obs_by_rob[rob_idx].push_back($sformatf(
        "[BE_TB] [COSIM] [WRITEBACK] mispredict=%0b; target=0x%016h; is_mret=%0b; is_sret=%0b; fpu_fflags=0x%0h (OBSERVATION ONLY, NOT COMPARED)",
        l2_wb_by_rob[rob_idx].mispredict,
        l2_wb_by_rob[rob_idx].target,
        l2_wb_by_rob[rob_idx].is_mret,
        l2_wb_by_rob[rob_idx].is_sret,
        l2_wb_by_rob[rob_idx].fpu_fflags));

  endtask

  task automatic sample_lsu_issue();
    byte unsigned ref_req_property;
    int unsigned ref_exe_subop;
    byte unsigned ref_mem_funct3;
    byte unsigned ref_rd_is_fp;
    longint unsigned ref_rs1_data;
    longint unsigned ref_rs2_data;
    byte unsigned ref_imm_valid;
    longint signed ref_imm_data;
    byte unsigned ref_is_store;
    longint unsigned rob_idx;
    int rc;

    // Capture only an accepted BE-to-LSU request; no comparison is reported here.
    if (!level2_enabled())
      return;
    if (ob_cosim_vif.be_lsu_issue_valid !== 1'b1)
      return;
    if (ob_cosim_vif.lsu_be_issue_ready !== 1'b1)
      return;

    rob_idx = ob_cosim_vif.be_lsu_issue_pld.self_tag;
    rc = isa_dpi_get_lsu_issue_metadata(
        MODEL_CORE_ID, dpi_rob_idx(rob_idx), ref_req_property,
        ref_exe_subop, ref_mem_funct3, ref_rd_is_fp, ref_rs1_data,
        ref_rs2_data, ref_imm_valid, ref_imm_data, ref_is_store);
    if (rc != ISA_API_PASS)
      cfg.reporter.fatal($sformatf("[BE][COSIM] get_lsu_issue_metadata rob=%0d rc=%0d", rob_idx, rc));

    l2_lsu_by_rob[rob_idx].valid = 1'b1;
    l2_lsu_by_rob[rob_idx].req_property =
        req_property_from_subop(ob_cosim_vif.be_lsu_issue_pld.exe_subop);
    l2_lsu_by_rob[rob_idx].ref_req_property = ref_req_property[6:0];
    l2_lsu_by_rob[rob_idx].exe_subop =
        ob_cosim_vif.be_lsu_issue_pld.exe_subop;
    l2_lsu_by_rob[rob_idx].ref_exe_subop = ref_exe_subop[23:0];
    l2_lsu_by_rob[rob_idx].mem_funct3 =
        ob_cosim_vif.be_lsu_issue_pld.mem_funct3;
    l2_lsu_by_rob[rob_idx].ref_mem_funct3 = ref_mem_funct3[2:0];
    l2_lsu_by_rob[rob_idx].rd_is_fp =
        ob_cosim_vif.be_lsu_issue_pld.rd_is_fp;
    l2_lsu_by_rob[rob_idx].ref_rd_is_fp = ref_rd_is_fp != 0;
    l2_lsu_by_rob[rob_idx].rs1_data =
        ob_cosim_vif.be_lsu_issue_pld.rs1_data;
    l2_lsu_by_rob[rob_idx].ref_rs1_data = ref_rs1_data;
    l2_lsu_by_rob[rob_idx].store_data =
        ob_cosim_vif.be_lsu_issue_pld.rs2_data;
    l2_lsu_by_rob[rob_idx].ref_store_data = ref_rs2_data;
    l2_lsu_by_rob[rob_idx].imm_valid =
        ob_cosim_vif.be_lsu_issue_pld.imm_valid;
    l2_lsu_by_rob[rob_idx].ref_imm_valid = ref_imm_valid != 0;
    l2_lsu_by_rob[rob_idx].imm_data =
        ob_cosim_vif.be_lsu_issue_pld.imm_data;
    l2_lsu_by_rob[rob_idx].ref_imm_data = ref_imm_data;
    l2_lsu_by_rob[rob_idx].is_store =
        req_property_from_subop(ob_cosim_vif.be_lsu_issue_pld.exe_subop).is_store;
    l2_lsu_by_rob[rob_idx].ref_is_store = ref_is_store != 0;
  endtask

  // Consume the BE-to-LSU issue snapshot at commit.
  // Only fields with a unique ISA-model meaning are compared.
  task automatic consume_lsu_issue(input longint unsigned rob_idx);
    bit mismatch;

    // Consume the accepted-request snapshot at commit, as required by Level-2.
    if (!level2_enabled())
      return;
    if (!l2_lsu_by_rob.exists(rob_idx))
      return;
    if (!l2_lsu_by_rob[rob_idx].valid)
      return;

    mismatch = 1'b0;
    if (l2_lsu_by_rob[rob_idx].req_property !== l2_lsu_by_rob[rob_idx].ref_req_property)
      mismatch = 1'b1;
    if (l2_lsu_by_rob[rob_idx].exe_subop !== l2_lsu_by_rob[rob_idx].ref_exe_subop)
      mismatch = 1'b1;
    if (l2_lsu_by_rob[rob_idx].mem_funct3 !== l2_lsu_by_rob[rob_idx].ref_mem_funct3)
      mismatch = 1'b1;
    if (l2_lsu_by_rob[rob_idx].rd_is_fp !== l2_lsu_by_rob[rob_idx].ref_rd_is_fp)
      mismatch = 1'b1;
    if (l2_lsu_by_rob[rob_idx].imm_valid !== l2_lsu_by_rob[rob_idx].ref_imm_valid)
      mismatch = 1'b1;
    if (l2_lsu_by_rob[rob_idx].is_store !== l2_lsu_by_rob[rob_idx].ref_is_store)
      mismatch = 1'b1;
    if (l2_lsu_by_rob[rob_idx].imm_valid && l2_lsu_by_rob[rob_idx].ref_imm_valid &&
        l2_lsu_by_rob[rob_idx].imm_data !== l2_lsu_by_rob[rob_idx].ref_imm_data)
      mismatch = 1'b1;

    if (mismatch) begin
      l2_any_mismatch_by_rob[rob_idx] = 1'b1;
      l2_cmp_by_rob[rob_idx].push_back($sformatf("[BE_TB] [COSIM] [BE-LSU] req_property=0x%0h (dut), 0x%0h (ref); exe_subop=0x%06h (dut), 0x%06h (ref); mem_funct3=0x%0h (dut), 0x%0h (ref); rd_is_fp=%0b (dut), %0b (ref); imm_valid=%0b (dut), %0b (ref); imm_data=0x%016h (dut), 0x%016h (ref); is_store=%0b (dut), %0b (ref)",
          l2_lsu_by_rob[rob_idx].req_property,
          l2_lsu_by_rob[rob_idx].ref_req_property,
          l2_lsu_by_rob[rob_idx].exe_subop,
          l2_lsu_by_rob[rob_idx].ref_exe_subop,
          l2_lsu_by_rob[rob_idx].mem_funct3,
          l2_lsu_by_rob[rob_idx].ref_mem_funct3,
          l2_lsu_by_rob[rob_idx].rd_is_fp,
          l2_lsu_by_rob[rob_idx].ref_rd_is_fp,
          l2_lsu_by_rob[rob_idx].imm_valid,
          l2_lsu_by_rob[rob_idx].ref_imm_valid,
          l2_lsu_by_rob[rob_idx].imm_data,
          l2_lsu_by_rob[rob_idx].ref_imm_data,
          l2_lsu_by_rob[rob_idx].is_store,
          l2_lsu_by_rob[rob_idx].ref_is_store));
    end else begin
      l2_cmp_by_rob[rob_idx].push_back(
          "[BE_TB] [COSIM] [BE-LSU] all compared fields match");
    end
    l2_obs_by_rob[rob_idx].push_back($sformatf("[BE_TB] [COSIM] [BE-LSU] rs1_data=0x%016h store_data=0x%016h tag/self_tag used only for lifecycle association (OBSERVATION ONLY, NOT COMPARED)", l2_lsu_by_rob[rob_idx].rs1_data, l2_lsu_by_rob[rob_idx].store_data));
    l2_lsu_by_rob.delete(rob_idx);
  endtask

  task automatic observe_lsu_responses();
    longint unsigned rob_idx;
    if (!level2_enabled())
      return;
    if (ob_cosim_vif.lsu_be_done_valid === 1'b1) begin
      rob_idx = ob_cosim_vif.lsu_be_done_pld.tag;
      l2_lsu_response_by_rob[rob_idx].done_valid = 1'b1;
      l2_lsu_response_by_rob[rob_idx].done_data = ob_cosim_vif.lsu_be_done_pld.data;
    end
    if (ob_cosim_vif.lsu_be_exception_valid === 1'b1) begin
      rob_idx = ob_cosim_vif.lsu_be_exception_pld.tag;
      l2_lsu_response_by_rob[rob_idx].exception_valid = 1'b1;
      l2_lsu_response_by_rob[rob_idx].exception_cause = ob_cosim_vif.lsu_be_exception_pld.cause;
      l2_lsu_response_by_rob[rob_idx].exception_tval = ob_cosim_vif.lsu_be_exception_pld.tval;
    end
    if (ob_cosim_vif.lsu_be_bypass_valid === 1'b1) begin
      rob_idx = ob_cosim_vif.lsu_be_bypass_pld.tag;
      l2_lsu_response_by_rob[rob_idx].bypass_valid = 1'b1;
      l2_lsu_response_by_rob[rob_idx].bypass_data = ob_cosim_vif.lsu_be_bypass_pld.data;
    end
    if (ob_cosim_vif.lsu_be_done_valid === 1'b1 && ob_cosim_vif.lsu_be_exception_valid === 1'b1)
      cfg.reporter.fatal("[BE][COSIM] LSU done_valid and exception_valid asserted together");
  endtask

  // Consume the LSU response snapshot at commit or exception termination.
  task automatic consume_lsu_response(input longint unsigned rob_idx);
    if (l2_lsu_response_by_rob.exists(rob_idx)) begin
      if (l2_lsu_response_by_rob[rob_idx].done_valid)
        l2_obs_by_rob[rob_idx].push_back($sformatf(
            "[BE_TB] [COSIM] [BE-LSU] done_valid=1 data=0x%016h (OBSERVATION ONLY, NOT COMPARED)",
            l2_lsu_response_by_rob[rob_idx].done_data));
      if (l2_lsu_response_by_rob[rob_idx].exception_valid)
        l2_obs_by_rob[rob_idx].push_back($sformatf(
            "[BE_TB] [COSIM] [BE-LSU] exception_valid=1 cause=0x%0h tval=0x%016h (OBSERVATION ONLY, NOT COMPARED)",
            l2_lsu_response_by_rob[rob_idx].exception_cause,
            l2_lsu_response_by_rob[rob_idx].exception_tval));
      if (l2_lsu_response_by_rob[rob_idx].bypass_valid)
        l2_obs_by_rob[rob_idx].push_back($sformatf(
            "[BE_TB] [COSIM] [BE-LSU] bypass_valid=1 data=0x%016h (OBSERVATION ONLY, NOT COMPARED)",
            l2_lsu_response_by_rob[rob_idx].bypass_data));
      l2_lsu_response_by_rob.delete(rob_idx);
    end

  endtask

  task automatic emit_one_level2_lifecycle(
      input longint unsigned rob_idx,
      input string lifecycle_name);
    bit has_compare;
    bit has_observation;
    string marker;
    string payload;
    int compare_count;
    int observation_count;
    has_compare = 1'b0;
    has_observation = 1'b0;
    marker = $sformatf("[%s]", lifecycle_name);
    compare_count = l2_cmp_by_rob[rob_idx].size();
    for (int i = 0; i < compare_count; i++) begin
      if (l2_cmp_by_rob[rob_idx][i].substr(
              16,
              16 + lifecycle_name.len() + 1) == marker) begin
        payload = l2_cmp_by_rob[rob_idx][i].substr(
            19 + lifecycle_name.len(),
            l2_cmp_by_rob[rob_idx][i].len() - 1);
        cfg.reporter.diagnostic($sformatf(
            "[BE_TB] [COSIM] [%s] rob_idx=%0d %s",
            lifecycle_name,
            rob_idx,
            payload));
        has_compare = 1'b1;
      end
    end
    observation_count = l2_obs_by_rob[rob_idx].size();
    for (int i = 0; i < observation_count; i++) begin
      if (l2_obs_by_rob[rob_idx][i].substr(
              16,
              16 + lifecycle_name.len() + 1) == marker) begin
        has_observation = 1'b1;
      end
    end
    if (has_compare == 1'b0 && has_observation == 1'b0)
      return;
    if (has_compare == 1'b0)
      cfg.reporter.diagnostic($sformatf(
          "[BE_TB] [COSIM] [%s] rob_idx=%0d no compared field",
          lifecycle_name,
          rob_idx));
    for (int i = 0; i < observation_count; i++) begin
      if (l2_obs_by_rob[rob_idx][i].substr(
              16,
              16 + lifecycle_name.len() + 1) == marker) begin
        payload = l2_obs_by_rob[rob_idx][i].substr(
            19 + lifecycle_name.len(),
            l2_obs_by_rob[rob_idx][i].len() - 1);
        cfg.reporter.diagnostic($sformatf(
            "[BE_TB] [COSIM] [%s] rob_idx=%0d %s",
            lifecycle_name,
            rob_idx,
            payload));
      end
    end
    if (has_observation == 1'b0)
      cfg.reporter.diagnostic($sformatf(
          "[BE_TB] [COSIM] [%s] rob_idx=%0d no observe-only field (OBSERVATION ONLY, NOT COMPARED)",
          lifecycle_name,
          rob_idx));
  endtask

  task automatic emit_level2_lifecycle(input longint unsigned rob_idx);
    if (!level2_enabled())
      return;
    if (!l2_any_mismatch_by_rob.exists(rob_idx) ||
        !l2_any_mismatch_by_rob[rob_idx]) begin
      l2_cmp_by_rob.delete(rob_idx);
      l2_obs_by_rob.delete(rob_idx);
      l2_any_mismatch_by_rob.delete(rob_idx);
      l2_wb_by_rob.delete(rob_idx);
      l2_decode_by_rob.delete(rob_idx);
      l2_lsu_by_rob.delete(rob_idx);
      l2_isq_by_rob.delete(rob_idx);
      l2_lsu_response_by_rob.delete(rob_idx);
      l2_csr_in_by_rob.delete(rob_idx);
      l2_csr_out_by_rob.delete(rob_idx);
      l2_lsu_mismatch_by_rob.delete(rob_idx);
      return;
    end
    emit_one_level2_lifecycle(rob_idx, "DECODE");
    emit_one_level2_lifecycle(rob_idx, "ISQ0");
    emit_one_level2_lifecycle(rob_idx, "ISQ1");
    emit_one_level2_lifecycle(rob_idx, "ISQ2");
    emit_one_level2_lifecycle(rob_idx, "ISQ3");
    emit_one_level2_lifecycle(rob_idx, "WRITEBACK");
    emit_one_level2_lifecycle(rob_idx, "BE-LSU");
    emit_one_level2_lifecycle(rob_idx, "CSR_IN");
    emit_one_level2_lifecycle(rob_idx, "CSR_OUT");
    l2_cmp_by_rob.delete(rob_idx);
    l2_obs_by_rob.delete(rob_idx);
    l2_any_mismatch_by_rob.delete(rob_idx);
    l2_wb_by_rob.delete(rob_idx);
    l2_decode_by_rob.delete(rob_idx);
    l2_lsu_by_rob.delete(rob_idx);
    l2_isq_by_rob.delete(rob_idx);
    l2_lsu_response_by_rob.delete(rob_idx);
    l2_csr_in_by_rob.delete(rob_idx);
    l2_csr_out_by_rob.delete(rob_idx);
    l2_lsu_mismatch_by_rob.delete(rob_idx);
  endtask
`endif

  task automatic observe_commits();
    longint unsigned model_rd_value, model_redirect_pc;
    int unsigned model_rd_idx;
    bit model_rd_is_fp;
    byte unsigned model_rd_valid, model_rd_fp, model_rd_we, model_recovery_kind;
    int metadata_rc;
    for (int group = 0; group < BE_ISSUE_NUM; group++) begin
      longint unsigned rob_idx;
`ifdef ORBE_EXTERNAL_MNEMONICS
      longint signed inst_type;
      string inst_mnemonic;
`endif
      bit precommit_trap;
      bit final_trap;
      bit level2_mismatch_detected;
      int rc;
      // [Advance convergence C1] Outputs of predictor_commit. In this DUT kind the three trap
      // items are consumed by the exception path of observe_recoveries, so here they are only
      // received and unused; they are still received because the contract requires the
      // predictor to query them on our behalf between commit_auto and tick_finish.
      byte unsigned    pc_trap_record_valid;
      longint unsigned pc_trap_cause;
      longint unsigned pc_trap_tval;
      longint unsigned pc_spec_pc;
      if (!ob_vif.commit_valid[group])
        continue;
      rob_idx = ob_vif.commit_tag[group];
      if (!allocated_by_rob.exists(rob_idx))
        cfg.reporter.fatal($sformatf("[BE] commit for unallocated rob=%0d", rob_idx));
      if (!executed_by_rob.exists(rob_idx))
        cfg.reporter.fatal($sformatf(
            "[BE][R9] commit rob=%0d before the model executed it (queue head=%0d depth=%0d) -- environment ordering bug, not the DUT",
            rob_idx, exec_queue.size() ? exec_queue[0] : -1, exec_queue.size()));
      if (cfg.cosim_enable) begin
        metadata_rc = isa_dpi_get_insn_metadata(
            MODEL_CORE_ID, dpi_rob_idx(rob_idx), model_rd_valid, model_rd_fp,
            model_rd_we, model_rd_idx, model_rd_value, model_recovery_kind);
        check_rc($sformatf("get_insn_metadata rob=%0d", rob_idx), metadata_rc);
        model_rd_is_fp = model_rd_fp != 0;
        // Execute has completed by the time a commit is observable, so this
        // is the first point where branch next-PC metadata is authoritative.
        // Cache it before commitAuto can consume the model ROB entry.
        model_redirect_pc = isa_dpi_get_next_pc_of_insn(
            MODEL_CORE_ID, dpi_rob_idx(rob_idx));
        ref_pc_by_rob[rob_idx] = isa_dpi_get_insn_pc(
            MODEL_CORE_ID, dpi_rob_idx(rob_idx));
        ref_redirect_pc_by_rob[rob_idx] = model_redirect_pc;
        ref_recovery_kind_by_rob[rob_idx] = model_recovery_kind;
        // cfg.print_be(1, $sformatf(
        //    "[BE][COSIM_REF_CAPTURE] cycle=%0d group=%0d rob=%0d rd_valid=%0d rd_we=%0d rd_fp=%0d rd_idx=%0d result=0x%016h recovery_kind=%0d redirect_pc=0x%016h",
        //    cycle_count, group, rob_idx, model_rd_valid, model_rd_we,
        //    model_rd_fp, model_rd_idx, model_rd_value,
        //    model_recovery_kind, model_redirect_pc));
        cfg.print_be(1, $sformatf(
            "[BE][COSIM_OB] cycle=%0d group=%0d pc=0x%08h rob=%0d rd_we=%0d rd_fp=%0d rd_idx=%0d result=0x%016h recovery_kind=%0d redirect_pc=0x%016h",
            cycle_count, group, ob_vif.commit_pc[group], rob_idx, ob_cosim_vif.commit_rd_write_enable[group],
            ob_cosim_vif.commit_rd_is_fp[group], ob_cosim_vif.commit_rd_idx[group], ob_cosim_vif.commit_result[group],
            ob_cosim_vif.commit_recovery_kind, ob_cosim_vif.commit_redirect_pc));
      end
`ifdef ORBE_EXTERNAL_MNEMONICS
      if (!inst_type_by_rob.exists(rob_idx))
        cfg.reporter.fatal($sformatf("[BE] missing external mnemonic anchor at commit rob=%0d", rob_idx));
      inst_type = inst_type_by_rob[rob_idx];
      inst_mnemonic = isa_dpi_mnemonic_name(inst_type);
`endif
`ifdef ORBE_DUT_RTL_V1
      consume_lsu_issue(rob_idx);
      consume_decode(rob_idx);
      consume_writeback(rob_idx, model_rd_value,
                        ob_cosim_vif.commit_rd_write_enable[group] != 0,
                        ob_cosim_vif.commit_result[group]);
      consume_isq_response(rob_idx);
      consume_lsu_response(rob_idx);
      consume_csr_events(rob_idx);
      level2_mismatch_detected = l2_any_mismatch_by_rob.exists(rob_idx) &&
                                l2_any_mismatch_by_rob[rob_idx];
      emit_level2_lifecycle(rob_idx);
      if (level2_mismatch_detected)
        l2_any_mismatch_by_rob[rob_idx] = 1'b1;
`endif
      if (cfg.cosim_enable) begin
        publish_cosim_commit_event(group, ob_vif.commit_pc[group], rob_idx,
                                   model_rd_value, model_rd_idx,
                                   model_rd_is_fp,
`ifdef ORBE_EXTERNAL_MNEMONICS
                                   inst_type_by_rob.exists(rob_idx)
                                       ? inst_type_by_rob[rob_idx] : 0
`else
                                   0
`endif
                                   , model_recovery_kind, model_redirect_pc);
`ifdef ORBE_DUT_RTL_V1
        l2_any_mismatch_by_rob.delete(rob_idx);
`endif
      end
      // [Advance convergence C1] Event 3 · commit is handed to the single advance
      // implementation of the BE domain. has_trap must be read before commit_auto, and
      // tick_finish must immediately follow commit_auto -- these two timing rules are owned by
      // the predictor; this place no longer orchestrates them itself.
      //
      // [C2] redirect_pending takes ob_cosim.commit_redirect_valid (the source this DUT kind
      // uses per the contract's "two event sources" table). The model squash moves into
      // branch 2 of predictor_commit accordingly, with the start computed per the contract as
      // (rob_idx+1) % ROB_SIZE, no longer the RTL-observed recovery_squash_tag.
      predictor_commit(MODEL_CORE_ID, dpi_rob_idx(rob_idx),
                       longint'(1 << BE_ROB_TAG_W),
                       // commit_redirect_valid is a **per-cycle global** observation, while
                       // the commit event is per lane. The contract says "whether this entry
                       // produced a redirect" -- it must be attributed to the lane that is the
                       // recovery source, otherwise an older lane in the same cycle flushes the
                       // younger lane that is about to commit (observed: cyc495 dual commit
                       // rob14/rob15, after rob14's branch 2 flush(15), rob15's commit_auto
                       // got rc=-1).
                       // The same attribution discipline is in cosim_publisher's publish_commit.
                       (ob_cosim_vif.commit_redirect_valid &&
                        ob_vif.recovery_valid &&
                        (ob_vif.recovery_origin_tag == rob_idx)),
                       precommit_trap, pc_trap_record_valid,
                       pc_trap_cause, pc_trap_tval, pc_spec_pc);
      rc = ISA_API_PASS;   // failures $fatal inside the predictor; reaching here means PASS
      getter.after_commit(full_tag_by_rob[rob_idx], dpi_rob_idx(rob_idx),
                          precommit_trap, final_trap);
      retire_count++;
      last_commit_cycle = cycle_count;
      if (exit_wait_valid && (rob_idx == exit_wait_rob))
        exit_ready = 1'b1;                  // [R9-b] the terminal store has committed from the ROB
      store_wait_by_rob.delete(rob_idx);    // [R9-b']
      exit_wait_set.delete(rob_idx);        // [R9-b'']
      if ((retire_count % retire_print_interval) == 0) begin
`ifdef ORBE_EXTERNAL_MNEMONICS
        cfg.print_be(2, $sformatf(
            "[BE][COMMIT] cycle=%0d group=%0d retire=%0d rob=%0d tag=0x%0h pc=0x%016h inst_type=%0d inst_mnemonic=%s rc=%0d precommit_trap=%0b final_trap=%0b",
            cycle_count, group, retire_count, rob_idx, full_tag_by_rob[rob_idx],
            ob_vif.commit_pc[group], inst_type, inst_mnemonic, rc,
            precommit_trap, final_trap));
`else
        cfg.print_be(2, $sformatf(
            "[BE][COMMIT] cycle=%0d group=%0d retire=%0d rob=%0d tag=0x%0h pc=0x%016h rc=%0d precommit_trap=%0b final_trap=%0b",
            cycle_count, group, retire_count, rob_idx, full_tag_by_rob[rob_idx],
            ob_vif.commit_pc[group], rc, precommit_trap, final_trap));
`endif
      end
      if (final_trap) begin
        trap_commit_consumed = 1'b1;
        clear_local_anchors();
      end else begin
        allocated_by_rob.delete(rob_idx);
        lsu_by_rob.delete(rob_idx);
        execute_started_by_rob.delete(rob_idx);
        pending_by_rob.delete(rob_idx);
        executed_by_rob.delete(rob_idx);
        exec_rc_by_rob.delete(rob_idx);
        lsu_issued_by_rob.delete(rob_idx);
        lsu_issued_cycle_by_rob.delete(rob_idx);
        wb_seen_by_rob.delete(rob_idx);
        full_tag_by_rob.delete(rob_idx);
        pc_by_rob.delete(rob_idx);
        allocation_order_by_rob.delete(rob_idx);
`ifdef ORBE_EXTERNAL_MNEMONICS
        inst_type_by_rob.delete(rob_idx);
`endif
      end
    end
  endtask

  task automatic sample_trap_commit();
    // Kept as an explicit lifecycle hook; commit classification is performed
    // synchronously in observe_commits using the same entry and tag.
  endtask

  task automatic observe_recoveries(output bit recovery_event);
    bit rising_recovery;
    int rc;
    bit precommit_trap;
    bit final_trap;
    longint unsigned origin_rob_idx;
    longint unsigned squash_rob_idx;
    int unsigned anchors_before;
    byte unsigned model_rd_valid, model_rd_fp, model_rd_we, model_rkind;
    int unsigned model_rd_idx;
    longint unsigned model_rd_value;
    longint unsigned model_origin_pc, model_redirect_pc;
    int metadata_rc;
    bit origin_committed;
    byte unsigned ref_trap_valid;
    longint unsigned ref_trap_cause, ref_trap_tval;
    int trap_rc;
    bit level2_mismatch_detected;

    if (ob_vif.recovery_valid !== 1'b0 &&
        ob_vif.recovery_valid !== 1'b1)
      cfg.reporter.fatal("[BE][RECOVERY] recovery_valid is X/Z");
    recovery_event = ob_vif.recovery_valid === 1'b1;
    rising_recovery = recovery_event && !last_recovery_valid;
    anchors_before = allocated_by_rob.num();

    if (rising_recovery) begin
      if (^ob_vif.recovery_kind === 1'bx ||
          ^ob_vif.recovery_origin_tag === 1'bx ||
          ^ob_vif.recovery_squash_tag === 1'bx ||
          ^ob_vif.recovery_redirect_pc === 1'bx)
        cfg.reporter.fatal("[BE][RECOVERY] recovery observation contains X/Z");
      if (!recovery_kind_known(ob_vif.recovery_kind))
        cfg.reporter.fatal($sformatf(
            "[BE][RECOVERY] reserved recovery kind value=%0d",
            ob_vif.recovery_kind));

      origin_rob_idx = ob_vif.recovery_origin_tag;
      squash_rob_idx = ob_vif.recovery_squash_tag;

      if (ob_vif.recovery_kind == ORBE_RECOVERY_INTERRUPT) begin
        cfg.reporter.fatal(
            "[BE][RECOVERY_INTERRUPT] unsupported until interrupt cause observation is wired");
      end else if (ob_vif.recovery_kind == ORBE_RECOVERY_EXCEPTION) begin
        if (trap_commit_consumed) begin
          cfg.print_be(2, $sformatf(
              "[BE][RECOVERY_EXCEPTION] cycle=%0d origin=%0d anchors_before=%0d already_consumed_by_commit=1",
              cycle_count, origin_rob_idx, anchors_before));
        end else begin
          if (!allocated_by_rob.exists(origin_rob_idx))
            cfg.reporter.fatal($sformatf(
                "[BE][RECOVERY_EXCEPTION] exception recovery for unallocated rob=%0d",
                origin_rob_idx));
          precommit_trap =
              isa_dpi_has_trap(MODEL_CORE_ID, dpi_rob_idx(origin_rob_idx)) != 0;
          if (!precommit_trap)
            cfg.reporter.fatal($sformatf(
                "[BE][RECOVERY_EXCEPTION] rob=%0d has no shared-model trap record",
                origin_rob_idx));
          model_origin_pc = isa_dpi_get_insn_pc(MODEL_CORE_ID,
              dpi_rob_idx(origin_rob_idx));
          // [Advance convergence C3] This path is the fallback for when "the commit surface
          // did not see a trap commit"; its sequence matches contract branch 1 step by step:
          // has_trap → commit_auto → get_commit_auto_trap_info.
          // has_trap was already read above and must be true, so the predictor must take
          // branch 1; the window discipline of trap_info and tick_finish is likewise owned by
          // the predictor.
          begin
            bit              rb_has_trap;
            longint unsigned rb_spec_pc;
            predictor_commit(MODEL_CORE_ID, dpi_rob_idx(origin_rob_idx),
                             longint'(1 << BE_ROB_TAG_W), 1'b0,
                             rb_has_trap, ref_trap_valid,
                             ref_trap_cause, ref_trap_tval, rb_spec_pc);
            if (!rb_has_trap)
              cfg.reporter.fatal($sformatf(
                  "[BE][RECOVERY_EXCEPTION] predictor saw no trap rob=%0d",
                  origin_rob_idx));
          end
          rc = ISA_API_PASS;
          trap_rc = ISA_API_PASS;
          if (!ref_trap_valid)
            cfg.reporter.fatal($sformatf(
                "[BE][RECOVERY_EXCEPTION] ISA model did not return trap metadata rob=%0d",
                origin_rob_idx));
          getter.after_commit(full_tag_by_rob[origin_rob_idx],
                              dpi_rob_idx(origin_rob_idx),
                              precommit_trap, final_trap);
          if (!final_trap)
            cfg.reporter.fatal($sformatf(
                "[BE][RECOVERY_EXCEPTION] commitAuto rob=%0d did not consume a trap",
                origin_rob_idx));
          retire_count++;
          last_commit_cycle = cycle_count;
          cfg.print_be(2, $sformatf(
              "[BE][RECOVERY_EXCEPTION] cycle=%0d retire=%0d rob=%0d tag=0x%0h redirect_pc=0x%016h rc=%0d",
              cycle_count, retire_count, origin_rob_idx,
              full_tag_by_rob[origin_rob_idx], ob_vif.recovery_redirect_pc,
              rc));
        end
`ifdef ORBE_DUT_RTL_V1
        // Consume the faulting instruction lifecycle before recovery flush clears snapshots.
        consume_lsu_issue(origin_rob_idx);
        consume_decode(origin_rob_idx);
        consume_isq_response(origin_rob_idx);
        consume_lsu_response(origin_rob_idx);
        consume_csr_events(origin_rob_idx);
        level2_mismatch_detected = l2_any_mismatch_by_rob.exists(origin_rob_idx) &&
                                  l2_any_mismatch_by_rob[origin_rob_idx];
        emit_level2_lifecycle(origin_rob_idx);
        if (level2_mismatch_detected)
          l2_any_mismatch_by_rob[origin_rob_idx] = 1'b1;
`endif
        publish_cosim_recovery_event(origin_rob_idx,
            model_origin_pc,
            ORBE_RECOVERY_EXCEPTION, isa_dpi_get_spec_pc(MODEL_CORE_ID),
            ref_trap_cause, ref_trap_tval);
`ifdef ORBE_DUT_RTL_V1
        l2_any_mismatch_by_rob.delete(origin_rob_idx);
`endif
        trap_commit_consumed = 1'b0;
        clear_local_anchors();
      end else begin
        origin_committed = 1'b0;
        for (int g = 0; g < BE_ISSUE_NUM; g++)
          if (ob_vif.commit_valid[g] &&
              ob_vif.commit_tag[g] == origin_rob_idx[BE_ROB_ADDR_W-1:0])
            origin_committed = 1'b1;
        // A same-cycle commit may already have consumed the model ROB entry.
        // Reuse metadata captured before commitAuto in that case.
        if (origin_committed && ref_pc_by_rob.exists(origin_rob_idx)) begin
          model_origin_pc = ref_pc_by_rob[origin_rob_idx];
          model_rkind = ref_recovery_kind_by_rob.exists(origin_rob_idx)
              ? ref_recovery_kind_by_rob[origin_rob_idx] : 0;
          model_redirect_pc = ref_redirect_pc_by_rob.exists(origin_rob_idx)
              ? ref_redirect_pc_by_rob[origin_rob_idx] : 0;
        end else begin
          metadata_rc = isa_dpi_get_insn_metadata(
              MODEL_CORE_ID, dpi_rob_idx(origin_rob_idx), model_rd_valid,
              model_rd_fp, model_rd_we, model_rd_idx, model_rd_value,
              model_rkind);
          check_rc($sformatf("get_insn_metadata recovery rob=%0d", origin_rob_idx), metadata_rc);
          model_origin_pc = isa_dpi_get_insn_pc(MODEL_CORE_ID, dpi_rob_idx(origin_rob_idx));
          model_redirect_pc = ref_redirect_pc_by_rob.exists(origin_rob_idx)
              ? ref_redirect_pc_by_rob[origin_rob_idx]
              : isa_dpi_get_next_pc_of_insn(MODEL_CORE_ID,
                                            dpi_rob_idx(origin_rob_idx));
        end
        rc = ISA_API_PASS;
        // [Advance convergence C2 diagnostic] Contract branch 2 specifies the squash start as
        // (rob_idx+1) % ROB_SIZE; this DUT kind takes the RTL-observed recovery_squash_tag. If
        // the two are always equal, C2 can safely move the flush into predictor_commit; if not,
        // it is a convention difference that needs a ruling. Only recorded here, behavior unchanged.
        if (squash_rob_idx !=
            ((origin_rob_idx + 1) % longint'(1 << BE_ROB_TAG_W)))
          cfg.print_be(1, $sformatf(
              "[BE][FLUSH_IDX_DIVERGE] cycle=%0d origin=%0d rtl_squash=%0d contract_squash=%0d kind=%s",
              cycle_count, origin_rob_idx, squash_rob_idx,
              (origin_rob_idx + 1) % longint'(1 << BE_ROB_TAG_W),
              recovery_kind_name(ob_vif.recovery_kind)));
        // [Advance convergence C2] The model squash has moved into branch 2 of predictor_commit.
        // Contract section "About flush": isa_dpi_flush is issued only inside the redirect
        // branch of event 3 and is not an event on its own; the slot-occupant-side flush
        // (clearing its own ROB, driving global_flush_late and be_fe_redirect) is internal
        // behavior of the slot occupant, unrelated to advancing the model, and stays here.
        cfg.print_be(2, $sformatf(
            "[BE][RECOVERY_FLUSH] cycle=%0d kind=%s origin=%0d squash=%0d redirect_pc=0x%016h commits_origin=%0b anchors_before=%0d rc=%0d",
            cycle_count, recovery_kind_name(ob_vif.recovery_kind),
            origin_rob_idx, squash_rob_idx, ob_vif.recovery_redirect_pc,
            recovery_commits_origin(ob_vif.recovery_kind), anchors_before, rc));
`ifdef ORBE_DUT_RTL_V1
        // Consume the faulting instruction lifecycle before recovery flush clears snapshots.
        consume_lsu_issue(origin_rob_idx);
        consume_decode(origin_rob_idx);
        consume_isq_response(origin_rob_idx);
        consume_lsu_response(origin_rob_idx);
        consume_csr_events(origin_rob_idx);
        level2_mismatch_detected = l2_any_mismatch_by_rob.exists(origin_rob_idx) &&
                                  l2_any_mismatch_by_rob[origin_rob_idx];
        emit_level2_lifecycle(origin_rob_idx);
        if (level2_mismatch_detected)
          l2_any_mismatch_by_rob[origin_rob_idx] = 1'b1;
`endif
        if (ob_cosim_vif.commit_redirect_valid && !origin_committed) begin
          publish_cosim_recovery_event(origin_rob_idx,
              model_origin_pc, model_rkind, model_redirect_pc, 0, 0);
`ifdef ORBE_DUT_RTL_V1
          l2_any_mismatch_by_rob.delete(origin_rob_idx);
`endif
        end
        trap_commit_consumed = 1'b0;
        clear_local_anchors();
      end
    end
    last_recovery_valid = recovery_event;
  endtask

  task automatic observe_redirects();
    if (ob_vif.recovery_valid && !last_redirect_valid)
      cfg.print_be(2, $sformatf(
          "[BE][REDIRECT] cycle=%0d kind=%s redirect_pc=0x%016h anchors=%0d",
          cycle_count, recovery_kind_name(ob_vif.recovery_kind),
          ob_vif.recovery_redirect_pc, allocated_by_rob.num()));
    last_redirect_valid = ob_vif.recovery_valid;
  endtask

  task run();
    wait_for_model();
    if (!model_ready)
      return;
    cfg.print_be(1, $sformatf("[BE][START] cycle=%0d", cycle_count));
    forever begin
      bit recovery_event;
      bit model_to_exit;
      @(negedge ob_vif.clk);
      if (stop_requested)
        return;
      cycle_count++;
      publish_cosim_mem_observation();
      sample_trap_commit();
      observe_redirects();
`ifdef ORBE_DUT_RTL_V1
      observe_lsu_responses();
      observe_fe_be_interface();
      observe_isq_issue();
      observe_csr_events();
`endif
      retry_pending_execution();       // [R9] = drain_exec_queue
      observe_execution_writebacks();
      observe_commits();
      observe_recoveries(recovery_event);
      if (!recovery_event && !trap_commit_consumed)
        observe_allocations();
`ifdef ORBE_DUT_RTL_V1
      sample_lsu_issue();
`endif
      // [R9] Record this cycle's LSU issues; the queue head is released next cycle. Must come
      // after observe_allocations: RTL can issue a FENCE to LSU in its allocation cycle
      // (0x80000190 in rv64ui-p-simple); if placed before, allocated_by_rob has not registered
      // that rob yet and the handshake would be dropped as an unknown tag.
      observe_lsu_issue_handshake();
      // [Advance convergence C1] The per-cycle tick has been removed. tick_finish is now issued
      // by predictor_commit inside each commit event, at the same rhythm as stage 1 (each of
      // the three branches of contract event 3 ticks once).
      //
      // Note: tickFinish advances CLINT/mtime and polls HTIF tohost, so this is not just
      // bookkeeping -- "following commit events" means model time is proportional to the
      // number of retired instructions, "following the clock" means proportional to cycles.
      // In a dual-issue DUT kind the two differ by 2x. Existing -p- tests do not use timers and
      // cannot tell them apart; this convention difference is logged pending a ruling.
      model_to_exit = isa_dpi_is_to_exit() != 0;
      ob_vif.dpi_be_phase_seq++;
      // [R9-b] The shared model's exit is set the moment the store drains, and the store is
      // authorized to drain early via st_br_resolve, before its own ROB commit and those of
      // older instructions. Returning at that point, the remaining commits would never become
      // tickets and the reference side would stop at the previous one. Instead, wait for RTL
      // to commit the rob holding the terminal store.
      if (model_to_exit && !exit_pending) begin
        exit_pending = 1'b1;
        // The model latches exit only at tick_finish, which is not yet visible when the store
        // observation is sampled, so the wait target is fixed only here: the rob of the last
        // store before exit. If RTL has already committed it, release directly.
        // [R9-b''] Snapshot all robs in flight right now: the tohost store has drained but may
        // not have committed yet, and older ones may not have committed either; their tickets
        // still have to be sent to the reference side.
        exit_wait_set.delete();
        foreach (allocated_by_rob[r]) exit_wait_set[r] = 1'b1;
        exit_wait_valid = 1'b1;
        exit_ready = (exit_wait_set.num() == 0);
        cfg.print_be(1, $sformatf(
            "[BE][R9] model exit seen at cycle=%0d; %0d rob(s) still in flight, waiting for their commits",
            cycle_count, exit_wait_set.num()));
      end
      // [R9-b''] Exit only once the snapshot set is empty.
      if (exit_pending && exit_wait_valid) begin
        exit_ready = (exit_wait_set.num() == 0);
        // Fallback: no RTL commit for 32 consecutive cycles = truly hung (a spin loop also
        // commits every cycle, so no false positive).
        if (!exit_ready && (cycle_count - last_commit_cycle >= 32)) begin
          if (!exit_stall_reported) begin
            exit_stall_reported = 1'b1;
            cfg.print_be(1, $sformatf(
                "[BE][R9] no RTL commit for %0d cycles after model exit; %0d rob(s) left in flight, exiting anyway",
                cycle_count - last_commit_cycle, exit_wait_set.num()));
          end
          exit_ready = 1'b1;
        end
      end
      if (exit_pending && exit_wait_valid && !exit_ready) begin
        exit_wait_cycles++;
        if (exit_wait_cycles > 256)
          cfg.reporter.fatal($sformatf(
              "[BE][R9] model exited %0d cycles ago but %0d rob(s) never committed",
              exit_wait_cycles, exit_wait_set.num()));
        model_to_exit = 1'b0;               // do not exit this cycle yet
      end
      if (model_to_exit) begin
        publish_cosim_dut_exit_observation();
        publish_cosim_cycle_end_observation();
        // The final post-commit architectural state must be published before
        // the BE worker returns, otherwise the COSIM adapter can block forever
        // waiting for the last snapshot.
        publish_cosim_arch_state_observation();
        cfg.print_be(1, $sformatf(
            "[BE][EXIT] cycle=%0d retire_count=%0d", cycle_count, retire_count));
        return;
      end
      publish_cosim_cycle_end_observation();
      // Put the state snapshot after the exit marker, when present. The
      // adapter blocks on this mailbox, so all events for this cycle are
      // visible before it drains the commit mailbox.
      publish_cosim_arch_state_observation();
    end
  endtask

  task shutdown();
    stop_requested = 1'b1;
  endtask
endclass
