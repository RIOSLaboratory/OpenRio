// [This file] Initialization and reset sequence
// Initial Agent.
//
// One-time environment setup: create the shared ISA Model instance, load the config and ELF,
// fetch the entry PC.
// This Agent must have finished before the other three Agents start.
//
// Why a separate Agent rather than a state of FE:
//   This sequence runs only once in the whole lifetime, takes no part in any steady-state
//   timing, and drives no interface signal.
//   Left in FE, FE would be two things at once: "environment builder" and "fetch protocol
//   adapter". After the split FE's job reduces to one sentence: give me the entry PC, and I
//   deliver instructions with orbe_fe_if timing.
//
// Ownership is **deliberately split**: this Agent creates (isa_dpi_create), FE destroys
// (isa_dpi_destroy, see exit_sequence in fe_agent.sv). The time of destruction is decided by
// "the model requests exit", an event only FE's steady-state loop can observe, so it belongs
// to FE.
//
// Form: class. Drives no interface; no combinational output constraints.

class initial_agent;
  localparam int unsigned MODEL_CORE_ID  = 0;
  localparam int unsigned MODEL_ROB_SIZE = 16;

  be_config    cfg;

  // Data structure -> State
  logic [63:0] initial_pc;   // item 1: return value of isa_dpi_get_spec_pc
  bit          initialized;  // item 2: whether initialize has completed

  function new(be_config cfg_);
    cfg = cfg_;
    if (cfg == null)
      be_reporter::fatal_static("[INIT] initial_agent requires a non-null be_config");
    initial_pc  = '0;
    initialized = 1'b0;
  endfunction

  function void fail(string message);
    cfg.reporter.fatal($sformatf("[INIT] %s", message));
  endfunction

  task automatic check_rc(input string operation, input int rc);
    if (rc != ISA_API_PASS)
      fail($sformatf("%s returned rc=%0d", operation, rc));
  endtask

  // ---------------------------------------------------------------------
  // [FSM-1] initialize: run the prerequisite sequence and obtain the entry PC.
  // Fires only once in the whole lifetime; called by the top level after reset release and
  // before forking the other Agents.
  // ---------------------------------------------------------------------
  task automatic initialize();
    string isa_cfg;
    string isa_elf;
    string run_log_path;
    string commit_log_path;

    if (initialized)
      fail("initialize called twice; the bring-up sequence fires exactly once");

    if (!$value$plusargs("ISA_CFG=%s", isa_cfg))
      fail("+ISA_CFG=<platform.yaml> is required");
    if (!$value$plusargs("ISA_ELF=%s", isa_elf))
      fail("+ISA_ELF=<test.elf> is required");

    // 1. isa_dpi_create: create the shared model instance. core_num=1, rob_size=16.
    check_rc("isa_dpi_create", isa_dpi_create(1, longint'(MODEL_ROB_SIZE)));

    // 2/3. run log and commit log, both optional, enabled by plusarg.
    if ($value$plusargs("ISA_RUN_LOG=%s", run_log_path)) begin
      isa_dpi_set_run_log(run_log_path);
      isa_dpi_enable_run_log(ISA_API_LOG_GLOBAL);
    end
    if ($value$plusargs("ISA_COMMIT_LOG=%s", commit_log_path)) begin
      isa_dpi_set_commit_log(commit_log_path);
      isa_dpi_enable_commit_log(ISA_API_LOG_GLOBAL);
    end

    // 4. load_config -> 5. load_elf -> 6. add_arg -> 7. finalize_config
    check_rc($sformatf("isa_dpi_load_config(%s)", isa_cfg), isa_dpi_load_config(isa_cfg));
    check_rc($sformatf("isa_dpi_load_elf(%s)", isa_elf),    isa_dpi_load_elf(isa_elf));
    isa_dpi_add_arg(isa_elf);
    check_rc("isa_dpi_finalize_config", isa_dpi_finalize_config());

    // 7.5 align the counter origin with the COSIM golden (see orbe_predictor_pkg event 0)
    predictor_init_align();

    // 8. get_spec_pc: fetch the entry PC; called only once in the whole lifetime.
    initial_pc  = isa_dpi_get_spec_pc(MODEL_CORE_ID);
    initialized = 1'b1;

    cfg.print_fe(1, $sformatf("[INIT][START] ELF=%s entry_pc=0x%016h", isa_elf, initial_pc));
  endtask
endclass
