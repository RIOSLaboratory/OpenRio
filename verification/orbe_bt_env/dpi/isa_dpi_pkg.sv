// SystemVerilog declarations for isa_dpi_wrapper.cc.
package isa_dpi_pkg;

  // Values shared with IsaApi.h.
  localparam int ISA_API_PASS = 0;
  localparam int ISA_API_SKIP = 1;
  localparam int ISA_API_PENDING = 2;
  localparam int ISA_API_FAIL = -1;
  localparam longint signed ISA_API_INVALID_INSN_ID = -1;
  localparam int ISA_API_LOG_GLOBAL = -1;
  localparam int ISA_API_NXPR = 32;
  localparam int ISA_API_NFPR = 32;

  localparam int ISA_API_MEMOP_FETCH = 0;
  localparam int ISA_API_MEMOP_LOAD = 1;
  localparam int ISA_API_MEMOP_STORE = 2;
  localparam int ISA_API_MEMOP_AMOSWAP = 3;
  localparam int ISA_API_MEMOP_AMOADD = 4;
  localparam int ISA_API_MEMOP_AMOAND = 5;
  localparam int ISA_API_MEMOP_AMOOR = 6;
  localparam int ISA_API_MEMOP_AMOXOR = 7;
  localparam int ISA_API_MEMOP_AMOMAX = 8;
  localparam int ISA_API_MEMOP_AMOMIN = 9;
  localparam int ISA_API_MEMOP_AMOMAXU = 10;
  localparam int ISA_API_MEMOP_AMOMINU = 11;
  localparam int ISA_API_MEMOP_LOAD_RSV = 12;
  localparam int ISA_API_MEMOP_STORE_CND = 13;
  localparam int ISA_API_MEMOP_FENCE = 14;
  localparam int ISA_API_MEMOP_CBO_ZERO = 15;
  localparam int ISA_API_MEMOP_NOOP = 16;

  // The C++ wrapper owns one private FuncMultiCore pointer.  model_core_id
  // selects a core inside that model; use 0 for the single-core setup.
  import "DPI-C" function int isa_dpi_create(
    input longint unsigned core_num,
    input longint unsigned rob_size
  );
  import "DPI-C" function void isa_dpi_destroy();

  import "DPI-C" function longint unsigned isa_dpi_core_count();
  import "DPI-C" function void isa_dpi_set_core_count(
    input longint unsigned core_num
  );
  import "DPI-C" function void isa_dpi_set_rob_size(
    input longint unsigned rob_size
  );
  import "DPI-C" function void isa_dpi_set_core_pc(
    input int unsigned model_core_id,
    input longint unsigned pc
  );

  import "DPI-C" function longint unsigned isa_dpi_read_mem(
    input longint unsigned addr
  );
  import "DPI-C" function int isa_dpi_read_mem_bank(
    input longint unsigned addr,
    input longint unsigned length,
    output byte unsigned target[],
    output longint unsigned trap_type
  );
  import "DPI-C" function int isa_dpi_read_mem_bank_virt(
    input int unsigned model_core_id,
    input longint unsigned addr,
    input longint unsigned length,
    output byte unsigned target[],
    output longint unsigned trap_type
  );
  import "DPI-C" function int isa_dpi_fetch_mem_bank_virt(
    input int unsigned model_core_id,
    input longint unsigned addr,
    input longint unsigned length,
    output byte unsigned target[],
    output longint unsigned trap_type
  );

  // Struct-returning IsaApi functions are flattened to output arguments for
  // portable DPI-C ABI.  pte_paddr0..4 and pte_value0..4 correspond to the
  // five entries in IsaApiMmuTrace.
  import "DPI-C" function int isa_dpi_translate_pte(
    input int unsigned model_core_id,
    input longint unsigned vaddr,
    input longint unsigned priv,
    input int mem_op_type,
    input longint unsigned length,
    output longint unsigned paddr,
    output longint unsigned pte_paddr0,
    output longint unsigned pte_paddr1,
    output longint unsigned pte_paddr2,
    output longint unsigned pte_paddr3,
    output longint unsigned pte_paddr4,
    output longint unsigned pte_value0,
    output longint unsigned pte_value1,
    output longint unsigned pte_value2,
    output longint unsigned pte_value3,
    output longint unsigned pte_value4,
    output byte unsigned pte_update,
    output byte unsigned levels,
    output longint unsigned trap_type,
    output longint unsigned trap_tval,
    output byte unsigned trap_valid,
    output byte unsigned fault_src,
    output byte unsigned mem_type
  );

  import "DPI-C" function longint unsigned isa_dpi_get_gpr(
    input int unsigned model_core_id,
    input shortint unsigned index
  );
  import "DPI-C" function longint unsigned isa_dpi_get_fpr(
    input int unsigned model_core_id,
    input shortint unsigned index
  );
  import "DPI-C" function longint unsigned isa_dpi_get_spec_gpr(
    input int unsigned model_core_id,
    input shortint unsigned index
  );
  import "DPI-C" function longint unsigned isa_dpi_get_spec_fpr(
    input int unsigned model_core_id,
    input shortint unsigned index
  );
  import "DPI-C" function longint unsigned isa_dpi_get_spec_pc(
    input int unsigned model_core_id
  );
  import "DPI-C" function longint unsigned isa_dpi_get_committed_pc(
    input int unsigned model_core_id
  );
  import "DPI-C" function longint unsigned isa_dpi_get_csr(
    input int unsigned model_core_id,
    input shortint unsigned csr_index
  );
  import "DPI-C" function byte unsigned isa_dpi_get_priv(
    input int unsigned model_core_id
  );

  import "DPI-C" function int isa_dpi_parse_isa(
    input string isa_string
  );
  import "DPI-C" function int isa_dpi_load_elf(
    input string elf_path
  );
  import "DPI-C" function int isa_dpi_load_bin(
    input string bin_path,
    input longint unsigned address
  );
  import "DPI-C" function void isa_dpi_set_term_file(
    input string file_path
  );
  import "DPI-C" function void isa_dpi_add_arg(
    input string arg
  );
  import "DPI-C" function int isa_dpi_set_clint(
    input longint unsigned base_addr,
    input longint unsigned mtime_offset,
    input longint unsigned mtimecmp_offset,
    input longint unsigned time_step_offset,
    input longint unsigned soft_offset
  );
  import "DPI-C" function int isa_dpi_set_plic(
    input longint unsigned base_addr
  );
  import "DPI-C" function int isa_dpi_set_uart(
    input longint unsigned base_addr
  );
  import "DPI-C" function void isa_dpi_register_memory_segment(
    input longint unsigned start,
    input longint unsigned length,
    input byte unsigned readonly
  );
  import "DPI-C" function int isa_dpi_set_core_isa(
    input int unsigned model_core_id,
    input string isa_string
  );
  import "DPI-C" function int isa_dpi_load_config(
    input string yaml_path
  );
  import "DPI-C" function int isa_dpi_finalize_config();
  import "DPI-C" function byte unsigned isa_dpi_is_run_started();
  import "DPI-C" function byte unsigned isa_dpi_is_config_ready();

  import "DPI-C" function void isa_dpi_step(
    input longint signed steps
  );
  import "DPI-C" function void isa_dpi_step_spec(
    input longint signed steps
  );
  import "DPI-C" function void isa_dpi_tick_finish(
    input byte unsigned force_htif_poll
  );
  import "DPI-C" function byte unsigned isa_dpi_is_to_exit();
  import "DPI-C" function byte unsigned isa_dpi_is_good();
  import "DPI-C" function void isa_dpi_reset();

  import "DPI-C" function longint signed isa_dpi_decode_and_issue(
    input int unsigned model_core_id,
    input longint unsigned rob_idx,
    input longint unsigned pc,
    input int unsigned encoding,
    input byte unsigned force_rvc
  );
  import "DPI-C" function int isa_dpi_execute_insn(
    input int unsigned model_core_id,
    input longint unsigned rob_idx
  );
  import "DPI-C" function int isa_dpi_proc_mem_req(
    input int unsigned model_core_id,
    input longint unsigned rob_idx
  );
  import "DPI-C" function int isa_dpi_proc_mem_load(
    input int unsigned model_core_id,
    input longint unsigned rob_idx
  );
  import "DPI-C" function int isa_dpi_store_commit(
    input int unsigned model_core_id
  );
  import "DPI-C" function int isa_dpi_flush(
    input int unsigned model_core_id,
    input longint unsigned rob_idx
  );
  import "DPI-C" function int isa_dpi_flush_all(
    input int unsigned model_core_id
  );
  import "DPI-C" function int isa_dpi_clear_mem_reserve(
    input int unsigned model_core_id
  );
  import "DPI-C" function void isa_dpi_check_interrupt();
  import "DPI-C" function byte unsigned isa_dpi_has_pending_interrupt(
    input int unsigned model_core_id
  );
  import "DPI-C" function int isa_dpi_take_interrupt(
    input int unsigned model_core_id,
    output longint unsigned next_pc,
    output byte unsigned redirect
  );
  import "DPI-C" function int isa_dpi_commit(
    input int unsigned model_core_id,
    input longint unsigned rob_idx
  );
  import "DPI-C" function int isa_dpi_commit_auto(
    input int unsigned model_core_id,
    input longint unsigned rob_idx
  );
  import "DPI-C" function void isa_dpi_take_trap(
    input int unsigned model_core_id,
    input longint unsigned rob_idx
  );
  import "DPI-C" function int isa_dpi_take_interrupt_now(
    input int unsigned model_core_id,
    input longint unsigned value,
    input longint unsigned mask
  );

  import "DPI-C" function int isa_dpi_get_decode_metadata(
    input int unsigned model_core_id,
    input longint unsigned rob_idx,
    output byte unsigned is_lsu,
    output byte unsigned trap_valid,
    output longint unsigned trap_cause,
    output longint unsigned trap_tval
  );
  import "DPI-C" function int isa_dpi_get_lsu_issue_metadata(
    input int unsigned model_core_id,
    input longint unsigned rob_idx,
    output byte unsigned req_property,
    output int unsigned exe_subop,
    output byte unsigned mem_funct3,
    output byte unsigned rd_is_fp,
    output longint unsigned rs1_data,
    output longint unsigned rs2_data,
    output byte unsigned imm_valid,
    output longint signed imm_data,
    output byte unsigned is_store
  );
  import "DPI-C" function int isa_dpi_get_execute_metadata(
    input int unsigned model_core_id,
    input longint unsigned rob_idx,
    output byte unsigned trap_valid,
    output longint unsigned trap_cause,
    output longint unsigned trap_tval
  );
  import "DPI-C" function int isa_dpi_get_commit_auto_trap_info(
    input int unsigned model_core_id,
    input longint unsigned rob_idx,
    output byte unsigned trap_record_valid,
    output longint unsigned trap_cause,
    output longint unsigned trap_tval
  );
  import "DPI-C" function int isa_dpi_get_insn_metadata(
    input int unsigned model_core_id,
    input longint unsigned rob_idx,
    output byte unsigned rd_valid,
    output byte unsigned rd_is_fp,
    output byte unsigned rd_write_enable,
    output int unsigned rd_idx,
    output longint unsigned rd_value,
    output byte unsigned recovery_kind
  );
  import "DPI-C" function int isa_dpi_get_decode_semantic(
    input int unsigned model_core_id,
    input longint unsigned rob_idx,
    output byte unsigned rs1_valid,
    output byte unsigned rs2_valid,
    output byte unsigned rs3_valid,
    output byte unsigned rs1_is_fp,
    output byte unsigned rs2_is_fp,
    output byte unsigned rs3_is_fp,
    output int unsigned rs1_idx,
    output int unsigned rs2_idx,
    output int unsigned rs3_idx,
    output byte unsigned is_store,
    output byte unsigned imm_valid,
    output longint signed imm_data,
    output int unsigned exe_subop
  );

  import "DPI-C" function longint unsigned isa_dpi_get_insn_pc(
    input int unsigned model_core_id,
    input longint unsigned rob_idx
  );

  `ifdef ORBE_EXTERNAL_MNEMONICS
    import "DPI-C" function longint signed isa_dpi_decode_mnemonic(
      input int unsigned encoding,
      input byte unsigned force_rvc
    );
  `endif

  `ifdef ORBE_EXTERNAL_MNEMONICS
  import "DPI-C" function string isa_dpi_mnemonic_name(
    input longint signed mnemonic
  );
  `endif

  import "DPI-C" function longint unsigned isa_dpi_get_insn_rd_value(
    input int unsigned model_core_id,
    input longint unsigned rob_idx
  );
  import "DPI-C" function longint unsigned isa_dpi_get_next_pc_of_insn(
    input int unsigned model_core_id,
    input longint unsigned rob_idx
  );
  import "DPI-C" function byte unsigned isa_dpi_is_insn_redirect(
    input int unsigned model_core_id,
    input longint unsigned rob_idx
  );
  import "DPI-C" function int isa_dpi_trigger_trap(
    input int unsigned model_core_id,
    input longint unsigned rob_idx,
    input longint unsigned trap_type,
    input longint unsigned tvalue
  );
  import "DPI-C" function int isa_dpi_has_trap(
    input int unsigned model_core_id,
    input longint unsigned rob_idx
  );
  import "DPI-C" function void isa_dpi_log_run(
    input int unsigned model_core_id,
    input longint unsigned rob_idx
  );
  import "DPI-C" function void isa_dpi_log_commit(
    input int unsigned model_core_id,
    input longint unsigned rob_idx
  );

  // Log control is global in IsaApi.h, so these functions do not take
  // model_core_id.  ISA_API_LOG_GLOBAL (-1) enables/disables all cores.
  import "DPI-C" function void isa_dpi_enable_run_log(input int core_id);
  import "DPI-C" function void isa_dpi_disable_run_log(input int core_id);
  import "DPI-C" function byte unsigned isa_dpi_run_log_enabled(input int core_id);
  import "DPI-C" function void isa_dpi_set_run_log(input string log_path);
  import "DPI-C" function void isa_dpi_enable_commit_log(input int core_id);
  import "DPI-C" function void isa_dpi_disable_commit_log(input int core_id);
  import "DPI-C" function byte unsigned isa_dpi_commit_log_enabled(input int core_id);
  import "DPI-C" function void isa_dpi_set_commit_log(input string log_path);

endpackage : isa_dpi_pkg
