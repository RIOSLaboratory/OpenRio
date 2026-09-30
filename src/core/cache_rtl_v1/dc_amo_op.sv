// OR_CACHE_AMO_OP (E3): compute the AMO new value from the D cache old value and rs2 (written back to ISB) and shape the old value (done data)
//   old value taken directly from D cache (the E1 AMO stall in or_cache_top guarantees ISB / WB are empty)
module dc_amo_op
  import or_be_lsu_protocol_pkg::*;
  import or_cache_pkg::*;
(
  input  lsu_memop_t   memop,
  input  logic [2:0]   funct3,
  input  logic [3:0]   len,        // 4 (.W) or 8 (.D)
  input  logic [63:0]  old_bytes,  // D cache old value (len bytes, LSB-aligned, remaining bytes 0)
  input  logic [63:0]  src,        // rs2 (store data in the ISB entry)
  output logic [63:0]  new_val,    // new value written back to ISB (low len bytes valid)
  output logic [63:0]  rd_val      // old value shaped by funct3, used as done data at commit
);
  assign new_val = amo_calc(memop, (len == 4'd4), old_bytes, src);
  assign rd_val  = shape_load(funct3, 1'b0, old_bytes);
endmodule
