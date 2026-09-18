`timescale 1ns/1ps

module orbe_fe_mock_fe_agent (
  orbe_fe_mock_if.fe fe_bus
);
  import isa_dpi_pkg::*;
  import orbe_fe_mock_pkg::*;

  logic [ORBE_FE_LANES-1:0] pending_valid;
  orbe_fe_instr_pld_t pending_info [ORBE_FE_LANES-1:0];
  logic [ORBE_FE_LANES-1:0] compact_valid;
  orbe_fe_instr_pld_t compact_info [ORBE_FE_LANES-1:0];
  logic [63:0] next_pc;
  logic [63:0] redirect_pc;
  bit fetch_eof;
  bit fetch_stop_after_fault;
  bit model_created;
  bit redirect_pending;
  bit force_fetch_excp;
  logic [63:0] force_fetch_excp_pc;
  longint unsigned force_fetch_excp_trap_type;
  int unsigned force_fetch_excp_tval_offset;

  task automatic check_rc(input string operation, input int rc);
    if (rc != ISA_API_PASS)
      $fatal(1, "[ORBE_FE_MOCK_FE] %s failed: rc=%0d", operation, rc);
  endtask

  function automatic bit is_supported_fetch_cause(input longint unsigned trap_type);
    return (trap_type == 64'h0) ||
           (trap_type == 64'h1) ||
           (trap_type == 64'hc);
  endfunction

  task automatic report_fetch_fault(
    input logic [63:0] pc,
    input logic [63:0] failed_access_pc,
    input longint unsigned trap_type,
    output logic [4:0] exception_cause,
    output logic [63:0] exception_tval
  );
    if (!is_supported_fetch_cause(trap_type))
      $fatal(1,
             "[ORBE_FE_MOCK_FE] unsupported instruction-fetch trap: pc=0x%016h access=0x%016h trap=0x%016h",
             pc, failed_access_pc, trap_type);
    exception_cause = trap_type[4:0];
    exception_tval = failed_access_pc;
    $display("[ORBE_FE_MOCK_FE] instruction-fetch exception pc=0x%016h access=0x%016h cause=%0d trap=0x%016h",
             pc, failed_access_pc, exception_cause, trap_type);
  endtask

  task automatic initialize_model();
    string isa_cfg;
    string isa_elf;
    string run_log_path;
    string commit_log_path;
    int unsigned force_fetch_excp_arg;

    if (!$value$plusargs("ISA_CFG=%s", isa_cfg))
      $fatal(1, "[ORBE_FE_MOCK_FE] missing +ISA_CFG=<platform.yaml>");
    if (!$value$plusargs("ISA_ELF=%s", isa_elf))
      $fatal(1, "[ORBE_FE_MOCK_FE] missing +ISA_ELF=<case.riscv>");

    check_rc("isa_dpi_create", isa_dpi_create(64'd1, 64'(MODEL_ROB_SIZE)));
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
    force_fetch_excp_arg = 0;
    void'($value$plusargs("MOCK_FORCE_FETCH_EXCP=%d", force_fetch_excp_arg));
    force_fetch_excp = force_fetch_excp_arg != 0;
    void'($value$plusargs("MOCK_FORCE_FETCH_EXCP_PC=%h", force_fetch_excp_pc));
    void'($value$plusargs("MOCK_FORCE_FETCH_EXCP_CAUSE=%h", force_fetch_excp_trap_type));
    void'($value$plusargs("MOCK_FORCE_FETCH_EXCP_TVAL_OFFSET=%d", force_fetch_excp_tval_offset));
    $display("[ORBE_FE_MOCK_FE] ELF=%s entry_pc=0x%016h", isa_elf, next_pc);
  endtask

  task automatic fetch_instruction(
    input logic [63:0] pc,
    output bit fetch_ok,
    output bit end_of_stream,
    output bit fetch_exception,
    output bit is_compressed,
    output logic [31:0] instr,
    output int unsigned instr_bytes,
    output logic [4:0] exception_cause,
    output logic [63:0] exception_tval
  );
    byte unsigned lo [0:1];
    byte unsigned hi [0:1];
    logic [15:0] low_halfword;
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

    if (force_fetch_excp && (pc == force_fetch_excp_pc)) begin
      fetch_exception = 1'b1;
      fetch_ok = 1'b1;
      instr = 32'h0000_0013;
      report_fetch_fault(pc,
                         pc + 64'(force_fetch_excp_tval_offset),
                         force_fetch_excp_trap_type,
                         exception_cause,
                         exception_tval);
      return;
    end

    rc = isa_dpi_fetch_mem_bank_virt(MODEL_CORE_ID, pc, 2, lo, trap_type);
    if (rc != ISA_API_PASS) begin
      fetch_exception = 1'b1;
      fetch_ok = 1'b1;
      instr = 32'h0000_0013;
      report_fetch_fault(pc, pc, trap_type, exception_cause, exception_tval);
      return;
    end

    low_halfword = {lo[1], lo[0]};
    if (low_halfword == 16'h0000) begin
      end_of_stream = 1'b1;
      $display("[ORBE_FE_MOCK_FE] zero-filled EOF at pc=0x%016h", pc);
      return;
    end

    if (low_halfword[1:0] != 2'b11) begin
      instr = {16'h0000, low_halfword};
      fetch_ok = 1'b1;
      is_compressed = 1'b1;
      instr_bytes = 2;
      return;
    end

    rc = isa_dpi_fetch_mem_bank_virt(MODEL_CORE_ID, pc + 64'd2, 2, hi, trap_type);
    if (rc != ISA_API_PASS) begin
      fetch_exception = 1'b1;
      fetch_ok = 1'b1;
      instr = 32'h0000_0013;
      report_fetch_fault(pc, pc + 64'd2, trap_type, exception_cause, exception_tval);
      return;
    end

    instr = {hi[1], hi[0], lo[1], lo[0]};
    fetch_ok = 1'b1;
    is_compressed = 1'b0;
    instr_bytes = 4;
  endtask

  task automatic fetch_pending_entry(input int unsigned index, output bit fetch_ok);
    bit end_of_stream;
    bit fetch_exception;
    bit is_compressed;
    logic [31:0] instr;
    int unsigned instr_bytes;
    logic [4:0] exception_cause;
    logic [63:0] exception_tval;

    fetch_ok = 1'b0;
    fetch_instruction(next_pc, fetch_ok, end_of_stream, fetch_exception,
                      is_compressed, instr, instr_bytes,
                      exception_cause, exception_tval);
    if (end_of_stream) begin
      fetch_eof = 1'b1;
      return;
    end
    if (!fetch_ok)
      $fatal(1, "[ORBE_FE_MOCK_FE] fetch failed at pc=0x%016h", next_pc);

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
      pending_info[index].pred_target_pc = next_pc + 64'(instr_bytes);
      pending_info[index].fetch_excp_vld = 1'b0;
      pending_info[index].exception_cause = '0;
      pending_info[index].exception_tval = '0;
      next_pc = next_pc + 64'(instr_bytes);
    end
  endtask

  task automatic refill_pending();
    int unsigned pending_count;
    bit fetch_ok;

    pending_count = 0;
    for (int lane = 0; lane < ORBE_FE_LANES; lane++) begin
      if (pending_valid[lane])
        pending_count++;
    end

    while ((pending_count < ORBE_FE_LANES) && !fetch_eof && !fetch_stop_after_fault) begin
      fetch_pending_entry(pending_count, fetch_ok);
      if (!fetch_ok)
        break;
      pending_count++;
    end

    for (int lane = pending_count; lane < ORBE_FE_LANES; lane++) begin
      pending_valid[lane] = 1'b0;
      pending_info[lane] = '0;
    end
  endtask

  task automatic remove_accepted_entries();
    int unsigned write_index;
    logic [ORBE_FE_LANES-1:0] fire;

    compact_valid = '0;
    compact_info = '{default:'0};
    fire = '0;
    write_index = 0;

    fire[0] = pending_valid[0] && (fe_bus.be_fe_instr_ready[0] === 1'b1);
    fire[1] = pending_valid[1] && (fe_bus.be_fe_instr_ready[1] === 1'b1) && fire[0];

    for (int lane = 0; lane < ORBE_FE_LANES; lane++) begin
      if (pending_valid[lane] && !fire[lane]) begin
        compact_valid[write_index] = 1'b1;
        compact_info[write_index] = pending_info[lane];
        write_index++;
      end
    end

    pending_valid = compact_valid;
    pending_info = compact_info;
  endtask

  task automatic apply_redirect();
    pending_valid = '0;
    pending_info = '{default:'0};
    compact_valid = '0;
    compact_info = '{default:'0};
    next_pc = redirect_pc;
    fetch_eof = 1'b0;
    fetch_stop_after_fault = 1'b0;
    refill_pending();
    $display("[ORBE_FE_MOCK_FE] redirect refill at pc=0x%016h", redirect_pc);
  endtask

  task automatic drive_idle();
    fe_bus.fe_be_instr_valid = '0;
    fe_bus.fe_be_instr_pld = '{default:'0};
  endtask

  task automatic drive_pending();
    fe_bus.fe_be_instr_valid = pending_valid;
    fe_bus.fe_be_instr_pld = pending_info;
  endtask

  initial begin
    model_created = 1'b0;
    redirect_pending = 1'b0;
    redirect_pc = '0;
    pending_valid = '0;
    pending_info = '{default:'0};
    compact_valid = '0;
    compact_info = '{default:'0};
    fetch_eof = 1'b0;
    fetch_stop_after_fault = 1'b0;
    force_fetch_excp = 1'b0;
    force_fetch_excp_pc = '0;
    force_fetch_excp_trap_type = '0;
    force_fetch_excp_tval_offset = 0;
    drive_idle();

    wait (fe_bus.rst_n === 1'b1);
    initialize_model();
    refill_pending();
    if (pending_valid == '0)
      $fatal(1, "[ORBE_FE_MOCK_FE] ELF has no fetchable instruction at entry PC");
    drive_idle();

    forever begin
      @(posedge fe_bus.clk);
      if (fe_bus.be_fe_redirect_valid === 1'b1) begin
        redirect_pc = fe_bus.be_fe_redirect_pld.redirect_pc;
        redirect_pending = 1'b1;
        pending_valid = '0;
        pending_info = '{default:'0};
        compact_valid = '0;
        compact_info = '{default:'0};
        fetch_eof = 1'b0;
        fetch_stop_after_fault = 1'b0;
        drive_idle();
        #1;
        continue;
      end

      if (redirect_pending) begin
        apply_redirect();
        redirect_pending = 1'b0;
      end

      drive_pending();
      #1;
      remove_accepted_entries();
      refill_pending();
    end
  end

  final begin
    if (model_created) begin
      isa_dpi_destroy();
      model_created = 1'b0;
    end
  end
endmodule : orbe_fe_mock_fe_agent
