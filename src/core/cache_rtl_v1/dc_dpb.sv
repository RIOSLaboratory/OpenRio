// OR_CACHE_DPB: refill data path, DPB[i] belongs to MSHR[i]
module dc_dpb
  import or_cache_pkg::*;
(
  input  logic                  clk,
  input  logic                  we,
  input  logic [MSHR_ID_W-1:0]  widx,
  input  logic [LINE_W-1:0]     wdata,
  input  logic [MSHR_ID_W-1:0]  ridx,
  output logic [LINE_W-1:0]     rdata
);
  logic [LINE_W-1:0] mem [MSHR_N];
  always_ff @(posedge clk) if (we) mem[widx] <= wdata;
  assign rdata = mem[ridx];
endmodule
