`timescale 1ns/1ps

package orbe_fe_mock_pkg;
  localparam int unsigned ORBE_FE_LANES = 2;
  localparam int unsigned MODEL_CORE_ID = 0;
  localparam int unsigned MODEL_ROB_SIZE = 16;

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

  typedef struct packed {
    logic [63:0] redirect_pc;
    logic        interrupt_valid;
    logic        trap_valid;
  } orbe_fe_redirect_pld_t;
endpackage : orbe_fe_mock_pkg

interface orbe_fe_mock_if (
  input logic clk,
  input logic rst_n
);
  import orbe_fe_mock_pkg::*;

  logic [ORBE_FE_LANES-1:0] fe_be_instr_valid;
  orbe_fe_instr_pld_t       fe_be_instr_pld [ORBE_FE_LANES-1:0];
  logic [ORBE_FE_LANES-1:0] be_fe_instr_ready;

  logic                  be_fe_redirect_valid;
  orbe_fe_redirect_pld_t be_fe_redirect_pld;

  modport fe (
    input  clk,
    input  rst_n,
    input  be_fe_instr_ready,
    input  be_fe_redirect_valid,
    input  be_fe_redirect_pld,
    output fe_be_instr_valid,
    output fe_be_instr_pld
  );

  modport dut (
    input  clk,
    input  rst_n,
    input  fe_be_instr_valid,
    input  fe_be_instr_pld,
    output be_fe_instr_ready,
    output be_fe_redirect_valid,
    output be_fe_redirect_pld
  );

  modport mon (
    input clk,
    input rst_n,
    input fe_be_instr_valid,
    input fe_be_instr_pld,
    input be_fe_instr_ready,
    input be_fe_redirect_valid,
    input be_fe_redirect_pld
  );
endinterface : orbe_fe_mock_if
