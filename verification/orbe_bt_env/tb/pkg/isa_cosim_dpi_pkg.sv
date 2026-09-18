// DPI declarations for the independent, step-driven cosim reference model.
// These functions intentionally use a separate C++ handle from isa_dpi_pkg.
package isa_cosim_dpi_pkg;
  localparam int ISA_COSIM_API_PASS = 0;
  localparam int ISA_COSIM_API_FAIL = -1;

  import "DPI-C" function int isa_cosim_dpi_create(
    input longint unsigned core_num,
    input longint unsigned rob_size
  );
  import "DPI-C" function void isa_cosim_dpi_destroy();

  import "DPI-C" function int isa_cosim_dpi_load_config(
    input string yaml_path
  );
  import "DPI-C" function int isa_cosim_dpi_load_elf(
    input string elf_path
  );
  import "DPI-C" function void isa_cosim_dpi_add_arg(
    input string arg
  );
  import "DPI-C" function int isa_cosim_dpi_finalize_config();
  import "DPI-C" function byte unsigned isa_cosim_dpi_is_config_ready();

  import "DPI-C" function void isa_cosim_dpi_step(
    input longint signed steps
  );
  import "DPI-C" function byte unsigned isa_cosim_dpi_is_to_exit();
  import "DPI-C" function byte unsigned isa_cosim_dpi_is_good();

  import "DPI-C" function longint unsigned isa_cosim_dpi_get_gpr(
    input int unsigned model_core_id,
    input shortint unsigned index
  );

  import "DPI-C" function longint unsigned isa_cosim_dpi_get_fpr(
    input int unsigned model_core_id,
    input shortint unsigned index
  );

  import "DPI-C" function longint unsigned isa_cosim_dpi_get_csr(
    input int unsigned model_core_id,
    input shortint unsigned csr_index
  );

  import "DPI-C" function longint unsigned isa_cosim_dpi_get_committed_pc(
    input int unsigned model_core_id
  );
endpackage
