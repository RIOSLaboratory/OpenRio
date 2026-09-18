interface fe_if (input logic clk);
  import mock_rtl_pkg::*;

  logic [MOCK_ISSUE_NUM-1:0] fe_be_instr_valid;
  logic [MOCK_ISSUE_NUM-1:0] be_fe_instr_ready;
  fe_instr_pld_t [MOCK_ISSUE_NUM-1:0] fe_be_instr_pld;

  logic be_fe_redirect_valid;
  fe_redirect_pld_t be_fe_redirect_pld;

  task automatic init_inputs();
    fe_be_instr_valid = '0;
    fe_be_instr_pld = '{default:'0};
  endtask

  modport dut (
    input clk, fe_be_instr_valid, fe_be_instr_pld,
    output be_fe_instr_ready, be_fe_redirect_valid, be_fe_redirect_pld
  );

  modport tb (
    input clk, be_fe_instr_ready, be_fe_redirect_valid, be_fe_redirect_pld,
    output fe_be_instr_valid, fe_be_instr_pld
  );
endinterface
