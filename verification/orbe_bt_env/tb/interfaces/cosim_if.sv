// Legacy commit-order observation interface.
//
// ORBE COSIM code uses ob_cosim_if.sv as its observation boundary. This file
// remains only for compatibility with older local experiments and is not in
// the active ORBE filelist.
interface cosim_if #(
    parameter int unsigned ISSUE_NUM = 1,
    parameter int unsigned ROB_ADDR_W = 1
) (input logic clk);
  logic rst_n;

  // Valid lanes are consumed in increasing lane order. One valid lane causes
  // exactly one step in the independent reference model.
  logic [ISSUE_NUM-1:0] commit_valid;
  logic [ISSUE_NUM-1:0][63:0] commit_pc;
  logic [ISSUE_NUM-1:0][ROB_ADDR_W-1:0] commit_rob_idx;
endinterface
