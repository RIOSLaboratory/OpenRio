// [This file] OR_Cache RTL downstream boundary and model-sync observation port: L2 line refill, eviction, PTW; served/answered by cache_agent's D-side RTL service
// Compiled only under DUT_KIND=rtl_cache / rtl_full (cfg/filelist/rtl_cache.f, rtl_full.f); widths come from or_cache_pkg.
interface orbe_dc_mem_if (
  input logic clk
);
  import or_be_lsu_protocol_pkg::*;
  import or_cache_pkg::*;

  logic                   rst_n;

  // ---------------- L2 line refill (Cache -> cache_agent -> Cache) ----------------
  logic                   l2_req_vld;
  logic [MSHR_ID_W-1:0]   l2_req_id;
  logic [LINE_ADDR_W-1:0] l2_req_pa_line;
  logic                   l2_req_ready;
  logic                   l2_resp;
  logic [MSHR_ID_W-1:0]   l2_resp_id;
  logic [LINE_W-1:0]      l2_resp_data;
  logic                   l2_resp_err;

  // ---------------- Dirty line eviction (Cache -> cache_agent: consistency check) ----------------
  logic                   evict_vld;
  logic [LINE_ADDR_W-1:0] evict_pa_line;
  logic [LINE_W-1:0]      evict_data;

  // ---------------- PTW (Cache -> cache_agent -> Cache) ----------------
  logic                   ptw_req_vld;
  logic [VPN_W-1:0]       ptw_req_vpn;
  logic [TMQ_ID_W-1:0]    ptw_req_id;
  logic                   ptw_req_ready;
  logic                   ptw_resp;
  logic [TMQ_ID_W-1:0]    ptw_resp_id;
  logic [PPN_W-1:0]       ptw_resp_ppn;
  pg_lvl_t                ptw_resp_lvl;
  logic [4:0]             ptw_resp_rcause;
  logic [4:0]             ptw_resp_wcause;

  // ---------------- Model-sync observation port (Cache -> cache_agent) ----------------
  logic                   ms_drain_vld;
  lsu_tag_t               ms_drain_tag;
  isb_kind_e              ms_drain_kind;
  logic [63:0]            ms_drain_data;
  logic                   ms_drain_sc_ok;
endinterface : orbe_dc_mem_if
