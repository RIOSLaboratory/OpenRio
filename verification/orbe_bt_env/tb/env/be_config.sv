class be_config;
  localparam int unsigned DEFAULT_ISSUE_WIDTH = 2;
  int unsigned issue_width;
  int unsigned verbosity;
  string test_name;
  int unsigned timeout_cycles;
  int unsigned smoke_wait_cycles;
  int unsigned cache_load_return_delay_cycles;
  int unsigned cache_store_done_delay_cycles;
  int unsigned reporter_error_fatal_threshold;
  bit cosim_enable;
  int unsigned cosim_level;
  string cosim_backend;
  int unsigned cosim_reference_rob_size;
  be_reporter reporter;

  function new();
    issue_width = DEFAULT_ISSUE_WIDTH;
    verbosity = 1;
    test_name = "elf";
    timeout_cycles = 2000000;
    smoke_wait_cycles = 1000;
    cache_load_return_delay_cycles = 0;
    cache_store_done_delay_cycles = 0;
    reporter_error_fatal_threshold = 0;
    cosim_enable = 1'b0;
    cosim_level = 1;
    cosim_backend = "isa_step";
    cosim_reference_rob_size = 16;
    reporter = new("BE_TB", verbosity);
  endfunction

  function void print_fe(int unsigned level, string message);
    reporter.print(level, message);
  endfunction

  function void print_be(int unsigned level, string message);
    reporter.print(level, message);
  endfunction

  function void print_cache(int unsigned level, string message);
    reporter.print(level, message);
  endfunction

  function void print_tb(int unsigned level, string message);
    reporter.print(level, message);
  endfunction

  function void apply_plusargs();
    int value;
    string value_string;

    if ($value$plusargs("VERBOSITY=%d", value)) verbosity = value;
    if ($value$plusargs("TEST=%s", value_string)) test_name = value_string;
    if ($value$plusargs("SIM_TIMEOUT_CYCLES=%d", value)) timeout_cycles = value;
    if ($value$plusargs("SMOKE_WAIT_CYCLES=%d", value))
      smoke_wait_cycles = value;
    if ($value$plusargs("CACHE_LOAD_RETURN_DELAY_CYCLES=%d", value)) begin
      if (value < 0)
        reporter.fatal($sformatf("CACHE_LOAD_RETURN_DELAY_CYCLES must be non-negative; got %0d",
                                 value));
      else
        cache_load_return_delay_cycles = value;
    end
    if ($value$plusargs("CACHE_STORE_DONE_DELAY_CYCLES=%d", value)) begin
      if (value < 0)
        reporter.fatal($sformatf("CACHE_STORE_DONE_DELAY_CYCLES must be non-negative; got %0d",
                                 value));
      else
        cache_store_done_delay_cycles = value;
    end
    if ($value$plusargs("ISSUE_WIDTH=%d", value)) issue_width = value;
    if ($value$plusargs("ERROR_LIMIT=%d", value)) begin
      if (value < 0)
        reporter.fatal($sformatf("ERROR_LIMIT must be non-negative; got %0d",
                                 value));
      else
        reporter_error_fatal_threshold = value;
    end
    if ($value$plusargs("COSIM_ENABLE=%d", value)) cosim_enable = (value != 0);
    if ($value$plusargs("COSIM_LEVEL=%d", value)) cosim_level = value;
    if ($value$plusargs("COSIM_BACKEND=%s", value_string)) cosim_backend = value_string;
    if ($value$plusargs("COSIM_REFERENCE_ROB_SIZE=%d", value)) begin
      if (value < 1)
        reporter.fatal($sformatf(
            "COSIM_REFERENCE_ROB_SIZE must be non-zero; got %0d", value));
      else
        cosim_reference_rob_size = value;
    end

  endfunction

  function void validate_verbosity(string name, int unsigned value);
    if ((value < 1) || (value > 3))
      reporter.fatal($sformatf("%s must be 1, 2, or 3; got %0d", name, value));
  endfunction

  function void validate(int unsigned compiled_issue_width);
    validate_verbosity("verbosity", verbosity);
    if (issue_width != compiled_issue_width)
      reporter.fatal($sformatf("issue_width=%0d does not match compiled issue width=%0d",
                               issue_width, compiled_issue_width));
    if (smoke_wait_cycles == 0)
      reporter.fatal("smoke_wait_cycles must be non-zero");
    if (timeout_cycles == 0)
      reporter.fatal("timeout_cycles must be non-zero");
    if (cosim_reference_rob_size == 0)
      reporter.fatal("cosim_reference_rob_size must be non-zero");
    if ((cosim_level < 1) || (cosim_level > 2))
      reporter.fatal($sformatf("COSIM_LEVEL must be 1 or 2; got %0d", cosim_level));
    if (cosim_enable && (test_name != "elf"))
      reporter.fatal("COSIM_ENABLE requires TEST=elf");
    if (cosim_enable && (cosim_backend != "isa_step"))
      reporter.fatal($sformatf("unsupported COSIM_BACKEND=%s; use isa_step", cosim_backend));
    reporter.configure(verbosity, 1'b1, reporter_error_fatal_threshold);
  endfunction

  function void print();
    print_tb(1, "---------------- BE verification config ----------------");
    print_tb(1, $sformatf("test=%s issue_width=%0d timeout_cycles=%0d smoke_wait_cycles=%0d cache_load_return_delay_cycles=%0d cache_store_done_delay_cycles=%0d reporter_error_fatal_threshold=%0d cosim_enable=%0b cosim_level=%0d cosim_backend=%s cosim_reference_rob_size=%0d",
                          test_name, issue_width, timeout_cycles, smoke_wait_cycles,
                          cache_load_return_delay_cycles, cache_store_done_delay_cycles,
                          reporter_error_fatal_threshold,
                          cosim_enable, cosim_level, cosim_backend,
                          cosim_reference_rob_size));
    print_tb(1, $sformatf("verbosity: global=%0d", verbosity));
    print_tb(1, "----------------------------------------------------------");
  endfunction
endclass
