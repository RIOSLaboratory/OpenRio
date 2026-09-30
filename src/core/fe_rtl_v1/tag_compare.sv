// TAG_COMPARE: IC_WAYS-way tag compare
module tag_compare
  import or_fe_pkg::*;
(
  input  logic [IC_WAYS-1:0]               tag_vld,
  input  logic [IC_WAYS-1:0][IC_TAG_W-1:0] tag_rd,
  input  logic [IC_TAG_W-1:0]              pa_tag,
  output logic [IC_WAYS-1:0]               hit_way,
  output logic                             hit,
  output logic [IC_WAY_W-1:0]              hit_idx
);

  always_comb begin
    for (int w = 0; w < IC_WAYS; w++) begin
      hit_way[w] = tag_vld[w] && (tag_rd[w] == pa_tag);
    end
  end

  assign hit = |hit_way;

  always_comb begin
    hit_idx = '0;
    for (int w = IC_WAYS - 1; w >= 0; w--) begin
      if (hit_way[w]) hit_idx = IC_WAY_W'(w);
    end
  end

endmodule
