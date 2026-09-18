package orbe_fe_types_pkg;

  localparam int unsigned ORBE_FE_LANES = 2;

  // FE -> BE raw instruction payload.
  typedef struct packed {
    logic [63:0] pc;
    logic [31:0] inst_bits;
    logic        is_compressed;
    logic        pred_taken;
    logic [63:0] pred_target_pc;
    logic        fetch_excp_vld;
    logic [4:0]  exception_cause;
    logic [63:0] exception_tval;
  } orbe_fe_instr_pld_t;

  // BE -> FE redirect payload.
  typedef struct packed {
    logic [63:0] redirect_pc;
    logic        interrupt_valid;
    logic        trap_valid;
  } orbe_fe_redirect_pld_t;

endpackage : orbe_fe_types_pkg


interface orbe_fe_if (
  input logic clk,
  input logic rst_n
);

  import orbe_fe_types_pkg::*;

  // Lane 0 is older; lane 1 is younger.  The interface is prefix-ordered:
  // lane 1 may fire only when lane 0 fires in the same cycle.
  logic [ORBE_FE_LANES-1:0] fe_be_instr_valid;
  orbe_fe_instr_pld_t       fe_be_instr_pld [ORBE_FE_LANES-1:0];
  logic [ORBE_FE_LANES-1:0] be_fe_instr_ready;

  logic                  be_fe_redirect_valid;
  orbe_fe_redirect_pld_t be_fe_redirect_pld;

  modport dut (
    input  clk,
    input  rst_n,
    input  fe_be_instr_valid,
    input  fe_be_instr_pld,
    output be_fe_instr_ready,
    output be_fe_redirect_valid,
    output be_fe_redirect_pld
  );

  modport tb (
    input  clk,
    input  rst_n,
    output fe_be_instr_valid,
    output fe_be_instr_pld,
    input  be_fe_instr_ready,
    input  be_fe_redirect_valid,
    input  be_fe_redirect_pld
  );

endinterface : orbe_fe_if
