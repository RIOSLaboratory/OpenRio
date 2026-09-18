class cosim_agent #(int unsigned ISSUE_NUM = 1,
                    int unsigned ROB_ADDR_W = 1);
  virtual ob_cosim_if #(ISSUE_NUM, ROB_ADDR_W) vif;
  be_config cfg;
  cosim_reference_backend reference;
  cosim_commit_order_adapter adapter;
  bit stop_requested;
  bit initialized;

  function new(virtual ob_cosim_if #(ISSUE_NUM, ROB_ADDR_W) vif,
               mailbox #(cosim_commit_event_t) commit_events,
               mailbox #(cosim_arch_state_event_t) arch_state_events,
               be_config cfg);
    isa_step_cosim_backend isa_backend;

    if (cfg == null)
      be_reporter::fatal_static("[COSIM] agent requires be_config");
    this.vif = vif;
    this.cfg = cfg;
    this.adapter = new(commit_events, arch_state_events, cfg);
    this.stop_requested = 1'b0;
    this.initialized = 1'b0;
    case (cfg.cosim_backend)
      "isa_step": begin
        isa_backend = new(cfg);
        reference = isa_backend;
      end
      default: cfg.reporter.fatal($sformatf("[COSIM] unsupported backend %s",
                                            cfg.cosim_backend));
    endcase
  endfunction

  task initialize_model(input string elf_path);
    string cfg_path;

    if (!$value$plusargs("ISA_CFG=%s", cfg_path) || (cfg_path.len() == 0))
      cfg.reporter.fatal("[COSIM] missing +ISA_CFG=<platform.yaml>");
    reference.initialize(cfg_path, elf_path);
    adapter.initialize();
    initialized = 1'b1;
  endtask

  task run();
    if (!initialized)
      cfg.reporter.fatal("[COSIM] run called before initialize_model");
    forever begin
      @(posedge vif.clk);
      #1;
      if (stop_requested)
        return;
      adapter.check_cycle(reference);
      if (adapter.dut_exit_consumed) begin
        cfg.print_tb(2, $sformatf("[COSIM] reference exit after %0d commit tickets",
                                  adapter.sequence_count));
        return;
      end
    end
  endtask

  task finish_model();
    if (!initialized)
      return;
    if (!reference.is_to_exit())
      cfg.reporter.fatal($sformatf(
          "[COSIM] reference model did not reach tohost exit after %0d commit tickets",
          adapter.sequence_count));
    if (!reference.is_good())
      cfg.reporter.fatal("[COSIM] reference model reported FAIL");
    reference.shutdown();
    initialized = 1'b0;
  endtask

  task shutdown();
    stop_requested = 1'b1;
    if (initialized) begin
      reference.shutdown();
      initialized = 1'b0;
    end
  endtask
endclass
