// OR_CACHE_DATA_MERGE (E4): per byte ISB > WB > D cache, concatenate cross-line collected bytes, shape → Load Data Arbiter
//   all inputs sampled in E3 and registered into E4
module dc_data_merge
  import or_cache_pkg::*;
(
  input  logic [63:0]       l1d_bytes,   // D cache bytes of this part (LSB-aligned)
  input  logic [3:0]        plen,        // byte count of this part
  input  logic [7:0]        isb_mask,    // ISB forwarding (uncommitted stores, newest)
  input  logic [63:0]       isb_data,
  input  logic [7:0]        wb_mask,     // WB forwarding (committed, not yet written to D cache)
  input  logic [63:0]       wb_data,
  input  logic              part,
  input  logic [63:0]       p0data,      // part0 collected bytes
  input  logic [3:0]        len,         // total access byte count
  input  logic [2:0]        funct3,
  input  logic              rd_is_fp,
  output logic [63:0]       part_bytes,  // merged bytes of this part (LSB-aligned)
  output logic [63:0]       result       // shaped result (valid on the last part)
);
  always_comb begin
    part_bytes = '0;
    for (int j = 0; j < 8; j++)
      if (4'(j) < plen)
        part_bytes[8*j +: 8] = isb_mask[j] ? isb_data[8*j +: 8] :
                               wb_mask[j]  ? wb_data[8*j +: 8]  : l1d_bytes[8*j +: 8];
  end
  assign result = ld_assemble(part_bytes, part, p0data, len, plen, funct3, rd_is_fp);
endmodule
