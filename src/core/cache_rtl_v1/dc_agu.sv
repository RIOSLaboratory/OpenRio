// OR_CACHE_AGU (E1): address source select (new issue computes rs1+imm on the fly / stalled AMO and replay take the payload VA) and cross-line split
module dc_agu
  import or_cache_pkg::*;
(
  input  logic        from_issue,   // this pass comes from a new issue (VA computed on the fly, taken from this cycle's issue payload)
  input  logic [63:0] rs1_data,
  input  logic [63:0] imm_data,
  input  logic        imm_valid,
  input  logic [63:0] op_va,        // replay pass / AMO released after stall: original VA in the payload
  input  logic [3:0]  len,
  input  logic        part,
  output logic [63:0] va,           // original access VA
  output logic [63:0] pva,          // start VA of this part
  output logic [3:0]  plen,         // byte count of this part
  output logic        xline         // access crosses a line
);
  logic [OFF_W:0] off_end;
  /* verilator lint_off UNUSEDSIGNAL */   // p0len ≤ 8, upper bits always 0
  logic [OFF_W:0] p0len;
  /* verilator lint_on UNUSEDSIGNAL */

  assign va      = from_issue ? (imm_valid ? rs1_data + imm_data : rs1_data) : op_va;
  assign off_end = {1'b0, va[OFF_W-1:0]} + {3'd0, len};
  assign xline   = off_end > (OFF_W+1)'(LINE_BYTES);
  assign p0len   = xline ? (OFF_W+1)'(LINE_BYTES) - {1'b0, va[OFF_W-1:0]} : {3'd0, len};

  always_comb begin
    if (!part) begin
      pva  = va;
      plen = p0len[3:0];   // cross-line: p0len ≤ 7; otherwise = len ≤ 8
    end else begin
      pva  = {va[63:OFF_W] + 58'd1, {OFF_W{1'b0}}};
      plen = len - p0len[3:0];
    end
  end
endmodule
