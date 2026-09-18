// Generic ORBE backend sideband interface.
//
// The active ORBE staging top currently uses ob_if for ROB observations and
// does not instantiate this interface. It is kept as a small, generic
// compatibility boundary for future backend integration; it deliberately has
// no product-specific RTL package or type dependency.
interface be_if (input logic clk);
  import mock_rtl_pkg::*;

  logic [MOCK_FLUSH_ALL_DUP-1:0] flush_all;
  logic pflush;
  logic [MOCK_ROB_ADDR_W-1:0] pflush_rob_idx;
  logic redirect_valid;
  logic [MOCK_VPC_W-1:0] redirect_pc;

  task automatic init_inputs();
    flush_all = '0;
    pflush = 1'b0;
    pflush_rob_idx = '0;
    redirect_valid = 1'b0;
    redirect_pc = '0;
  endtask
endinterface
