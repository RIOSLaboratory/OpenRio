class fe_driver;
  localparam int unsigned LANES = MOCK_ISSUE_NUM;
  localparam int unsigned MODEL_CORE_ID = 0;
  localparam int unsigned MODEL_ROB_SIZE = 8;

  virtual fe_if vif;
  be_config cfg;
  // Entries are kept in program order.  The entry at index zero is always
  // the next one to request on FE channel zero; entries after it map to the
  // subsequent channels in order.
  logic [LANES-1:0] pending_valid;
  fe_instr_pld_t [LANES-1:0] pending_info;
  logic [LANES-1:0] compact_valid;
  fe_instr_pld_t [LANES-1:0] compact_info;
  longint unsigned next_pc;
  bit fetch_eof;
  bit model_created;
  bit redirect_pending;
  longint unsigned redirect_pc;

  function new(virtual fe_if vif, be_config cfg);
    if (cfg == null)
      be_reporter::fatal_static("[FE] fe_driver requires a non-null be_config");
    this.vif = vif;
    this.cfg = cfg;
    model_created = 1'b0;
  endfunction

  task automatic check_rc(input string operation, input int rc);
    if (rc != ISA_API_PASS)
      cfg.reporter.fatal($sformatf("[FE] %s failed: rc=%0d", operation, rc));
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
    output bit is_rvc,
    output logic [31:0] instr,
    output int unsigned instr_bytes,
    output bit fetch_exception,
    output exception_cause_t exception_cause,
    output logic [63:0] exception_tval
  );
    byte unsigned lo [0:1];
    byte unsigned hi [0:1];
    logic [15:0] compressed;
    longint unsigned trap_type;
    int rc;

    fetch_ok = 1'b0;
    end_of_stream = 1'b0;
    is_rvc = 1'b0;
    instr = '0;
    instr_bytes = 0;
    fetch_exception = 1'b0;
    exception_cause = '0;
    exception_tval = '0;
    trap_type = '0;
    rc = isa_dpi_fetch_mem_bank_virt(MODEL_CORE_ID, pc, 2, lo, trap_type);
    if (rc != ISA_API_PASS) begin
      fetch_ok = 1'b1;
      fetch_exception = 1'b1;
      exception_cause = exception_cause_t'(trap_type[4:0]);
      exception_tval = pc;
      instr_bytes = 4;
      cfg.print_fe(2, $sformatf(
          "[FE] fetch exception pc=0x%016h cause=%0d tval=0x%016h",
          pc, exception_cause, exception_tval));
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
      instr = {16'b0, compressed};
      fetch_ok = 1'b1;
      is_rvc = 1'b1;
      instr_bytes = 2;
      return;
    end

    rc = isa_dpi_fetch_mem_bank_virt(MODEL_CORE_ID, pc + 2, 2, hi, trap_type);
    if (rc != ISA_API_PASS) begin
      fetch_ok = 1'b1;
      fetch_exception = 1'b1;
      exception_cause = exception_cause_t'(trap_type[4:0]);
      exception_tval = pc + 2;
      instr_bytes = 4;
      cfg.print_fe(2, $sformatf(
          "[FE] fetch exception pc=0x%016h cause=%0d tval=0x%016h",
          pc, exception_cause, exception_tval));
      return;
    end
    instr = {hi[1], hi[0], lo[1], lo[0]};
    fetch_ok = 1'b1;
    instr_bytes = 4;
  endtask

  task automatic fetch_pending_entry(
    input int unsigned index,
    output bit fetch_ok
  );
    bit end_of_stream;
    bit is_rvc;
    logic [31:0] instr;
    int unsigned instr_bytes;
    bit fetch_exception;
    exception_cause_t exception_cause;
    logic [63:0] exception_tval;

    fetch_ok = 1'b0;
    fetch_instruction(next_pc, fetch_ok, end_of_stream, is_rvc, instr, instr_bytes,
                      fetch_exception, exception_cause, exception_tval);
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
    pending_info[index].is_compressed = is_rvc;
    pending_info[index].pred_target_pc = next_pc + instr_bytes;
    pending_info[index].pred_taken = 1'b0;
    pending_info[index].fetch_excp_vld = fetch_exception;
    pending_info[index].exception_cause = exception_cause;
    pending_info[index].exception_tval = exception_tval;
    if (fetch_exception)
      fetch_eof = 1'b1;
    next_pc += instr_bytes;
  endtask

  // Keep only entries which did not handshake.  This compaction is what
  // moves a stalled entry to channel zero on the following cycle.
  task automatic remove_accepted_entries();
    int unsigned write_index;

    compact_valid = '0;
    compact_info = '{default:'0};
    write_index = 0;
    for (int lane = 0; lane < LANES; lane++) begin
      if (pending_valid[lane] && (vif.be_fe_instr_ready[lane] !== 1'b1)) begin
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
    while ((pending_count < LANES) && !fetch_eof) begin
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
    refill_pending();
    cfg.print_fe(3, $sformatf("[FE] redirect: restarting fetch at pc=0x%016h",
                              redirect_pc));
  endtask

  task automatic drive_idle();
    vif.fe_be_instr_valid <= '0;
    vif.fe_be_instr_pld <= '0;
  endtask

  task automatic drive_pending();
    vif.fe_be_instr_valid <= pending_valid;
    vif.fe_be_instr_pld <= pending_info;
  endtask

  task run();
    initialize_model();
    pending_valid = '0;
    pending_info = '{default:'0};
    compact_valid = '0;
    compact_info = '{default:'0};
    fetch_eof = 1'b0;
    redirect_pending = 1'b0;
    redirect_pc = '0;
    refill_pending();
    if (pending_valid == '0)
      cfg.reporter.fatal("[FE] ELF has no fetchable instruction at entry PC");

    // Present the first group before its sampling edge. Every subsequent
    // update is likewise driven after the preceding edge and held for a full
    // cycle.
    drive_pending();
    forever begin
      @(posedge vif.clk);
      if (model_created && (isa_dpi_is_to_exit() != 0)) begin
        drive_idle();
        return;
      end

      if (vif.be_fe_redirect_valid === 1'b1) begin
        redirect_pc = vif.be_fe_redirect_pld.redirect_pc;
        redirect_pending = 1'b1;
        cfg.print_fe(3, $sformatf(
            "[FE] redirect request captured at pc=0x%016h", redirect_pc));
        pending_valid = '0;
        pending_info = '{default:'0};
        compact_valid = '0;
        compact_info = '{default:'0};
        apply_redirect();
        redirect_pending = 1'b0;
        @(negedge vif.clk);
        #1;
        drive_pending();
        continue;
      end

      // Sample the handshake in the active region, before the Mock's NBA
      // count update can change ready for the following cycle.
      remove_accepted_entries();
      refill_pending();
      @(negedge vif.clk);
      #1;
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
