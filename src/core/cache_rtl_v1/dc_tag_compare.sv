// OR_CACHE_TAG_COMPARE: compare each way's tag against the PA tag
module dc_tag_compare
  import or_cache_pkg::*;
(
  input  logic [DC_WAYS-1:0]  way_valid,
  input  logic [DC_TAG_W-1:0] way_tag [DC_WAYS],
  input  logic [DC_TAG_W-1:0] pa_tag,
  output logic [DC_WAYS-1:0]  hit_way,
  output logic                hit,
  output logic [WAY_W-1:0]    hit_idx
);
  always_comb begin
    hit_idx = '0;
    for (int w = 0; w < DC_WAYS; w++) begin
      hit_way[w] = way_valid[w] && (way_tag[w] == pa_tag);
      if (hit_way[w]) hit_idx = WAY_W'(w);
    end
  end
  assign hit = |hit_way;
endmodule
