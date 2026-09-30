// OR_CACHE_L1D (D cache): tag/data/valid/dirty/PLRU arrays; one data read port (E2, write-first view, outputs 8 bytes per way at the VA offset);
// ISB head tag lookup port; one write port (driven by WB); on install selects a victim and issues dirty-line eviction
module dc_l1d
  import or_cache_pkg::*;
(
  input  logic                   clk,
  input  logic                   rst_n,
  // E2 data read port: contents include this cycle's write-port write; each way takes 8 bytes at the in-line offset (bytes past line end are 0)
  input  logic [IDX_W-1:0]       rd_set,
  input  logic [OFF_W-1:0]       rd_off,
  output logic [DC_WAYS-1:0]     rd_valid,
  output logic [DC_TAG_W-1:0]    rd_tag   [DC_WAYS],
  output logic [63:0]            rd_bytes [DC_WAYS],
  // ISB head tag lookup port (two parts; current contents; tag read only)
  input  logic [IDX_W-1:0]       lk_set   [2],
  output logic [DC_WAYS-1:0]     lk_valid [2],
  output logic [DC_TAG_W-1:0]    lk_tag   [2][DC_WAYS],
  // write port (driven by WB)
  input  logic                   wr_en,
  input  logic                   wr_install,     // 1: full-line install (L1D picks victim); 0: byte write to wr_way (sets dirty)
  input  logic [IDX_W-1:0]       wr_set,
  input  logic [WAY_W-1:0]       wr_way,
  input  logic [DC_TAG_W-1:0]    wr_tag,
  input  logic [LINE_W-1:0]      wr_data,
  input  logic [LINE_BYTES-1:0]  wr_be,
  input  logic                   wr_dirty,       // dirty of the installed line (store bytes were merged)
  input  logic [DC_WAYS-1:0]     wr_excl,        // ways that must not be replaced on install (pending writes in WB)
  // dirty-line eviction (when install replaces a dirty victim, single cycle)
  output logic                   evict_vld,
  output logic [LINE_ADDR_W-1:0] evict_line,
  output logic [LINE_W-1:0]      evict_data,
  // PLRU update on pipeline hit (E3)
  input  logic                   touch_en,
  input  logic [IDX_W-1:0]       touch_set,
  input  logic [WAY_W-1:0]       touch_way
);
  logic [DC_TAG_W-1:0] tag_a   [DC_SETS][DC_WAYS];
  logic [LINE_W-1:0]   data_a  [DC_SETS][DC_WAYS];
  logic [DC_WAYS-1:0]  valid_a [DC_SETS];
  logic [DC_WAYS-1:0]  dirty_a [DC_SETS];
  logic [2:0]          plru_a  [DC_SETS];

  // ---------------------------------------------------------------- victim (install): non-excluded invalid way first, else PLRU;
  // if the PLRU pick is excluded, take the lowest-numbered non-excluded way
  logic [WAY_W-1:0] vic_way;
  logic             vic_ok;
  always_comb begin
    logic [WAY_W-1:0] pv;
    logic             inv_found;
    pv        = plru_victim(plru_a[wr_set]);
    vic_way   = pv;
    vic_ok    = !wr_excl[pv];
    inv_found = 1'b0;
    if (!vic_ok)
      for (int w = DC_WAYS-1; w >= 0; w--)
        if (!wr_excl[w]) begin vic_way = WAY_W'(w); vic_ok = 1'b1; end
    for (int w = DC_WAYS-1; w >= 0; w--)
      if (!valid_a[wr_set][w] && !wr_excl[w]) begin vic_way = WAY_W'(w); inv_found = 1'b1; end
    vic_ok = vic_ok || inv_found;
  end

  logic [WAY_W-1:0] w_way;       // way written this cycle
  assign w_way = wr_install ? vic_way : wr_way;

  // line after the write
  logic [LINE_W-1:0] wr_line;
  always_comb begin
    wr_line = data_a[wr_set][w_way];
    for (int b = 0; b < LINE_BYTES; b++)
      if (wr_install || wr_be[b]) wr_line[8*b +: 8] = wr_data[8*b +: 8];
  end

  // ---------------------------------------------------------------- eviction (L1D picks victim and sends out the dirty line)
  assign evict_vld  = wr_en && wr_install && valid_a[wr_set][vic_way] && dirty_a[wr_set][vic_way];
  assign evict_line = {tag_a[wr_set][vic_way], wr_set};
  assign evict_data = data_a[wr_set][vic_way];

  // ---------------------------------------------------------------- E2 data read port (write-first view)
  always_comb begin
    logic [LINE_W-1:0] ln;
    for (int w = 0; w < DC_WAYS; w++) begin
      if (wr_en && (wr_set == rd_set) && (w_way == WAY_W'(w))) begin
        ln          = wr_line;
        rd_tag[w]   = wr_install ? wr_tag : tag_a[rd_set][w];
        rd_valid[w] = 1'b1;
      end else begin
        ln          = data_a[rd_set][w];
        rd_tag[w]   = tag_a[rd_set][w];
        rd_valid[w] = valid_a[rd_set][w];
      end
      rd_bytes[w] = '0;
      for (int j = 0; j < 8; j++)
        if (int'(rd_off) + j < LINE_BYTES) rd_bytes[w][8*j +: 8] = ln[8*(int'(rd_off) + j) +: 8];
    end
  end

  // ---------------------------------------------------------------- ISB lookup port (current contents)
  always_comb begin
    for (int p = 0; p < 2; p++) begin
      lk_valid[p] = valid_a[lk_set[p]];
      for (int w = 0; w < DC_WAYS; w++) lk_tag[p][w] = tag_a[lk_set[p]][w];
    end
  end

  // ---------------------------------------------------------------- arrays
  always_ff @(posedge clk) begin
    if (wr_en) begin
      data_a[wr_set][w_way] <= wr_line;
      if (wr_install) tag_a[wr_set][w_way] <= wr_tag;
    end
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      for (int s = 0; s < DC_SETS; s++) begin
        valid_a[s] <= '0; dirty_a[s] <= '0; plru_a[s] <= '0;
      end
    end else begin
      if (touch_en) plru_a[touch_set] <= plru_touch(plru_a[touch_set], touch_way);
      if (wr_en) begin
        valid_a[wr_set][w_way] <= 1'b1;
        dirty_a[wr_set][w_way] <= wr_install ? wr_dirty : 1'b1;
        // same set, same cycle: pipeline touch first, then write port
        plru_a[wr_set] <= plru_touch((touch_en && (touch_set == wr_set)) ?
                                     plru_touch(plru_a[wr_set], touch_way) : plru_a[wr_set], w_way);
      end
    end
  end

`ifndef SYNTHESIS
  always_ff @(posedge clk) if (rst_n) begin
    if (wr_en && wr_install) assert (vic_ok) else $error("[L1D] install into set %0d with every way excluded", wr_set);
    // installed line must not already be in L1D (precondition for eviction consistency and WB line uniqueness)
    if (wr_en && wr_install)
      for (int w = 0; w < DC_WAYS; w++)
        assert (!(valid_a[wr_set][w] && (tag_a[wr_set][w] == wr_tag)))
          else $error("[L1D] install of line already resident in set %0d way %0d", wr_set, w);
    if (wr_en && !wr_install) assert (valid_a[wr_set][wr_way]) else $error("[L1D] byte write into invalid way");
  end
`endif
endmodule
