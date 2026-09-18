class fe_driver;
  localparam int unsigned LANES = orbe_fe_types_pkg::ORBE_FE_LANES;
  localparam int unsigned MODEL_CORE_ID = 0;
  localparam int unsigned MODEL_ROB_SIZE = 16;

  virtual orbe_fe_if.tb vif;
  orbe_fe_config cfg;
  // Entries are kept in program order.  The entry at index zero is always
  // the next one to request on FE channel zero; entries after it map to the
  // subsequent channels in order.
  logic [LANES-1:0] pending_valid;
  orbe_fe_types_pkg::orbe_fe_instr_pld_t pending_info [LANES-1:0];
  logic [LANES-1:0] compact_valid;
  orbe_fe_types_pkg::orbe_fe_instr_pld_t compact_info [LANES-1:0];
  logic [LANES-1:0] sampled_fire;
  longint unsigned next_pc;
  bit fetch_eof;
  bit fetch_stop_after_fault;
  bit model_created;
  bit redirect_pending;
  longint unsigned redirect_pc;

  function new(virtual orbe_fe_if.tb vif, orbe_fe_config cfg);
    if (cfg == null)
      orbe_fe_reporter::fatal_static("[FE] fe_driver requires a non-null orbe_fe_config");
    this.vif = vif;
    this.cfg = cfg;
    model_created = 1'b0;
  endfunction

  task automatic check_rc(input string operation, input int rc);
    if (rc != ISA_API_PASS)
      cfg.reporter.fatal($sformatf("[FE] %s failed: rc=%0d", operation, rc));
  endtask

  function automatic bit is_supported_fetch_cause(input longint unsigned trap_type);
    return (trap_type == 64'h0) ||
           (trap_type == 64'h1) ||
           (trap_type == 64'hc);
  endfunction

  task automatic report_fetch_fault(
    input longint unsigned pc,
    input longint unsigned failed_access_pc,
    input longint unsigned trap_type,
    output logic [4:0] exception_cause,
    output longint unsigned exception_tval
  );
    if (!is_supported_fetch_cause(trap_type))
      cfg.reporter.fatal($sformatf(
        "[FE] unsupported instruction-fetch trap: pc=0x%016h access=0x%016h trap=0x%016h",
        pc, failed_access_pc, trap_type));
    exception_cause = trap_type[4:0];
    exception_tval = failed_access_pc;
    cfg.print_fe(2, $sformatf(
      "[FE] instruction-fetch exception: pc=0x%016h access=0x%016h cause=%0d trap=0x%016h",
      pc, failed_access_pc, exception_cause, trap_type));
  endtask

  task automatic initialize_model();
    string isa_cfg;
    string isa_elf;
    string run_log_path;
    string commit_log_path;

    if (!$value$plusargs("ISA_CFG=%s", isa_cfg))
      cfg.reporter.fatal("[FE] missing +ISA_CFG=<platform.yaml>");
    if (!$value$plusargs("ISA_ELF=%s", isa_elf))
      cfg.reporter.fatal("[FE] missing +ISA_ELF=<test.elf>; use make run TC=<test.elf>");

    check_rc("isa_dpi_create", isa_dpi_create(1, MODEL_ROB_SIZE));
    model_created = 1'b1;
    if ($value$plusargs("ISA_RUN_LOG=%s", run_log_path)) begin
      isa_dpi_set_run_log(run_log_path);
      isa_dpi_enable_run_log(ISA_API_LOG_GLOBAL);
    end
    if ($value$plusargs("ISA_COMMIT_LOG=%s", commit_log_path)) begin
      isa_dpi_set_commit_log(commit_log_path);
      isa_dpi_enable_commit_log(ISA_API_LOG_GLOBAL);
    end
    check_rc($sformatf("isa_dpi_load_config(%s)", isa_cfg), isa_dpi_load_config(isa_cfg));
    check_rc($sformatf("isa_dpi_load_elf(%s)", isa_elf), isa_dpi_load_elf(isa_elf));
    isa_dpi_add_arg(isa_elf);
    check_rc("isa_dpi_finalize_config", isa_dpi_finalize_config());
    next_pc = isa_dpi_get_spec_pc(MODEL_CORE_ID);
    cfg.print_fe(1, $sformatf("[FE] ELF=%s entry_pc=0x%016h; fetching until ISA model exit",
                              isa_elf, next_pc));
  endtask

  task automatic fetch_instruction(
    input longint unsigned pc,
    output bit fetch_ok,
    output bit end_of_stream,
    output bit fetch_exception,
    output bit is_compressed,
    output logic [31:0] instr,
    output int unsigned instr_bytes,
    output logic [4:0] exception_cause,
    output longint unsigned exception_tval
  );
    byte unsigned lo [0:1];
    byte unsigned hi [0:1];
    logic [15:0] compressed;
    longint unsigned trap_type;
    int rc;

    fetch_ok = 1'b0;
    end_of_stream = 1'b0;
    fetch_exception = 1'b0;
    is_compressed = 1'b0;
    instr = '0;
    instr_bytes = 0;
    exception_cause = '0;
    exception_tval = '0;
    trap_type = '0;
    rc = isa_dpi_fetch_mem_bank_virt(MODEL_CORE_ID, pc, 2, lo, trap_type);
    if (rc != ISA_API_PASS) begin
      fetch_exception = 1'b1;
      fetch_ok = 1'b1;
      instr = 32'h0000_0013;
      report_fetch_fault(pc, pc, trap_type, exception_cause, exception_tval);
      return;
    end

    compressed = {lo[1], lo[0]};
    // ELF-backed instruction memory is commonly zero-filled beyond the last
    // executable bytes.  Zero is not a valid RISC-V instruction, so treat it
    // as an end-of-stream marker instead of enqueueing an illegal opcode.
    if (compressed == 16'h0000) begin
      end_of_stream = 1'b1;
      cfg.print_fe(3, $sformatf("[FE] zero-filled instruction stream ended at pc=0x%016h",
                                pc));
      return;
    end
    if (compressed[1:0] != 2'b11) begin
      // ORBE receives the raw instruction.  Keep the RVC halfword in the
      // low 16 bits and clear the upper half; decode is owned by BE.
      instr = {16'b0, compressed};
      fetch_ok = 1'b1;
      is_compressed = 1'b1;
      instr_bytes = 2;
      return;
    end

    rc = isa_dpi_fetch_mem_bank_virt(MODEL_CORE_ID, pc + 2, 2, hi, trap_type);
    if (rc != ISA_API_PASS) begin
      fetch_exception = 1'b1;
      fetch_ok = 1'b1;
      instr = 32'h0000_0013;
      report_fetch_fault(pc, pc + 2, trap_type, exception_cause, exception_tval);
      return;
    end
    instr = {hi[1], hi[0], lo[1], lo[0]};
    fetch_ok = 1'b1;
    is_compressed = 1'b0;
    instr_bytes = 4;
  endtask

  task automatic fetch_pending_entry(
    input int unsigned index,
    output bit fetch_ok
  );
    bit end_of_stream;
    bit fetch_exception;
    bit is_compressed;
    logic [31:0] instr;
    int unsigned instr_bytes;
    logic [4:0] exception_cause;
    longint unsigned exception_tval;

    fetch_ok = 1'b0;
    fetch_instruction(next_pc, fetch_ok, end_of_stream, fetch_exception,
                      is_compressed, instr, instr_bytes,
                      exception_cause, exception_tval);
    if (end_of_stream) begin
      fetch_eof = 1'b1;
      return;
    end
    if (!fetch_ok)
      cfg.reporter.fatal($sformatf("[FE] fetch_pending_entry failed at pc=0x%016h",
                                   next_pc));

    pending_valid[index] = 1'b1;
    pending_info[index] = '0;
    pending_info[index].pc = next_pc;
    pending_info[index].inst_bits = instr;
    pending_info[index].is_compressed = is_compressed;
    pending_info[index].pred_taken = 1'b0;
    if (fetch_exception) begin
      pending_info[index].pred_target_pc = next_pc;
      pending_info[index].fetch_excp_vld = 1'b1;
      pending_info[index].exception_cause = exception_cause;
      pending_info[index].exception_tval = exception_tval;
      fetch_stop_after_fault = 1'b1;
    end else begin
      pending_info[index].pred_target_pc = next_pc + instr_bytes;
      pending_info[index].fetch_excp_vld = 1'b0;
      pending_info[index].exception_cause = '0;
      pending_info[index].exception_tval = '0;
      next_pc += instr_bytes;
    end
  endtask

  // Keep only entries which did not handshake.  This compaction is what
  // moves a stalled entry to channel zero on the following cycle.
  task automatic remove_accepted_entries(input logic [LANES-1:0] edge_fire);
    int unsigned write_index;
    logic [LANES-1:0] fire;

    compact_valid = '0;
    compact_info = '{default:'0};
    fire = '0;
    write_index = 0;

    // ORBE accepts the two lanes in program order.  In particular, a ready
    // indication on lane 1 cannot consume lane 1 if lane 0 did not fire in
    // the same cycle.
    for (int lane = 0; lane < LANES; lane++) begin
      if (lane == 0) begin
        fire[lane] = pending_valid[lane] && edge_fire[lane];
      end else begin
        fire[lane] = pending_valid[lane] && edge_fire[lane] && fire[lane-1];
      end
    end
    for (int lane = 0; lane < LANES; lane++) begin
      if (pending_valid[lane] && !fire[lane]) begin
        compact_valid[write_index] = 1'b1;
        compact_info[write_index] = pending_info[lane];
        write_index++;
      end
    end
    pending_valid = compact_valid;
    pending_info = compact_info;
  endtask

  // Refill the tail while preserving program order.  next_pc advances when
  // an instruction enters this queue, so a stalled entry is never duplicated.
  task automatic refill_pending();
    int unsigned pending_count;
    bit fetch_ok;

    pending_count = 0;
    for (int lane = 0; lane < LANES; lane++) begin
      if (pending_valid[lane])
        pending_count++;
    end
    while ((pending_count < LANES) && !fetch_eof && !fetch_stop_after_fault) begin
      fetch_pending_entry(pending_count, fetch_ok);
      if (!fetch_ok)
        break;
      pending_count++;
    end
    for (int lane = pending_count; lane < LANES; lane++) begin
      pending_valid[lane] = 1'b0;
      pending_info[lane] = '0;
    end
  endtask

  // Apply a redirect captured on the previous rising edge.  The old queue is
  // discarded before fetching from the target.
  task automatic apply_redirect();
    pending_valid = '0;
    pending_info = '{default:'0};
    compact_valid = '0;
    compact_info = '{default:'0};
    next_pc = redirect_pc;
    fetch_eof = 1'b0;
    fetch_stop_after_fault = 1'b0;
    refill_pending();
    cfg.print_fe(3, $sformatf("[FE] redirect: restarting fetch at pc=0x%016h",
                              redirect_pc));
  endtask

  task automatic drive_idle();
    vif.fe_be_instr_valid <= '0;
    vif.fe_be_instr_pld <= '{default:'0};
  endtask

  task automatic drive_pending();
    vif.fe_be_instr_valid <= pending_valid;
    vif.fe_be_instr_pld <= pending_info;
  endtask

  task run();
    // Match the ORBE FE bring-up behavior: keep the FE side quiescent while the
    // environment is in reset.  The wrapper must not observe X as a request.
    drive_idle();
    wait (vif.rst_n === 1'b1);
    initialize_model();
    pending_valid = '0;
    pending_info = '{default:'0};
    compact_valid = '0;
    compact_info = '{default:'0};
    fetch_eof = 1'b0;
    fetch_stop_after_fault = 1'b0;
    redirect_pending = 1'b0;
    redirect_pc = '0;
    refill_pending();
    if (pending_valid == '0)
      cfg.reporter.fatal("[FE] ELF has no fetchable instruction at entry PC");
    drive_pending();

    forever begin
      @(posedge vif.clk);
      if (model_created && isa_dpi_is_to_exit()) begin
        drive_idle();
        return;
      end
      // A redirect/flush observed on this edge has priority over applying a
      // previously queued redirect.  Drop the old group immediately and
      // rebuild from the newest target on the next clock, so that cycle is
      // the first cycle in which redirected instructions may be presented.
      if (vif.be_fe_redirect_valid === 1'b1) begin
        redirect_pc = vif.be_fe_redirect_pld.redirect_pc;
        redirect_pending = 1'b1;
        cfg.print_fe(3, $sformatf("[FE] redirect request captured at pc=0x%016h",
                                  redirect_pc));
        pending_valid = '0;
        pending_info = '{default:'0};
        compact_valid = '0;
        compact_info = '{default:'0};
        fetch_eof = 1'b0;
        fetch_stop_after_fault = 1'b0;
        // The flush boundary is a clock boundary: stop presenting the old
        // group now, then rebuild the queue on the next rising edge.
        drive_idle();
        continue;
      end
      if (redirect_pending) begin
        apply_redirect();
        redirect_pending = 1'b0;
      end

      // Capture this edge's handshake before post-edge state changes.
      sampled_fire = '0;
      for (int lane = 0; lane < LANES; lane++) begin
        sampled_fire[lane] = vif.fe_be_instr_valid[lane] &&
                             (vif.be_fe_instr_ready[lane] === 1'b1);
      end
      remove_accepted_entries(sampled_fire);
      refill_pending();
      drive_pending();
    end
  endtask

  task shutdown();
    if (model_created) begin
      isa_dpi_destroy();
      model_created = 1'b0;
    end
  endtask

  task finish_model();
    bit pass;

    if (!model_created)
      return;
    if (!isa_dpi_is_to_exit())
      cfg.reporter.fatal("[FE] model terminated before isa_dpi_is_to_exit()");
    pass = isa_dpi_is_good();
    cfg.print_fe(1, $sformatf("[FE] ISA model exit: %s",
                              pass ? "PASS" : "FAIL"));
    $display("[DPI_EXIT_RESULT] %s", pass ? "PASS" : "FAIL");
    isa_dpi_destroy();
    model_created = 1'b0;
    if (!pass)
      cfg.reporter.fatal("[FE] ISA model reported FAIL");
  endtask
endclass
