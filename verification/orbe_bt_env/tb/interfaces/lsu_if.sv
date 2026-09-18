interface lsu_if (input logic clk);
  import or_be_lsu_protocol_pkg::*;

  logic rst_n;
  logic be_lsu_issue_valid;
  logic lsu_be_issue_ready;
  be_lsu_issue_pld_t be_lsu_issue_pld;

  logic lsu_be_done_valid;
  logic lsu_be_exception_valid;
  logic be_lsu_entry_ready;
  lsu_be_writeback_pld_t lsu_be_writeback_pld;

  logic lsu_be_bypass_valid;
  lsu_be_bypass_pld_t lsu_be_bypass_pld;
  logic be_lsu_store_wakeup_valid;
  logic global_flush_late;

  task automatic init_inputs();
    rst_n = 1'b0;
    be_lsu_issue_valid = 1'b0;
    be_lsu_issue_pld = '0;
    be_lsu_entry_ready = 1'b0;
    be_lsu_store_wakeup_valid = 1'b0;
    global_flush_late = 1'b0;
  endtask
endinterface
