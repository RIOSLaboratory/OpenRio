// [This file] OR_FE RTL downstream boundary: L2 line refill + PTW, served/answered by cache_agent's I side
// Compiled only under DUT_KIND=rtl_fe (cfg/filelist/rtl_fe.f); widths come from or_fe_pkg.
interface orbe_fe_mem_if (
  input logic clk
);
  import or_fe_pkg::*;

  logic                   rst_n;

  // ---------------- L2 line refill (FE -> cache_agent -> FE) ----------------
  logic                   l2_req_vld;
  logic [MSHR_ID_W-1:0]   l2_req_id;
  logic [PA_W-OFF_W-1:0]  l2_req_pa_line;
  logic                   l2_req_ready;
  logic                   l2_cancel;
  logic [MSHR_ID_W-1:0]   l2_cancel_id;
  logic                   l2_resp;
  logic [MSHR_ID_W-1:0]   l2_resp_id;
  logic [LINE_W-1:0]      l2_resp_data;

  // ---------------- PTW (FE -> cache_agent -> FE) ----------------
  logic                   ptw_req_vld;
  logic [VPN_W-1:0]       ptw_req_vpn;
  logic                   ptw_req_ready;
  logic                   ptw_resp;
  logic [PPN_W-1:0]       ptw_resp_ppn;
  pg_lvl_t                ptw_resp_lvl;
  logic                   ptw_resp_x;
  logic                   ptw_resp_u;
  logic [1:0]             ptw_resp_pbmt;
  logic                   ptw_resp_fault;
  logic [CAUSE_W-1:0]     ptw_resp_cause;

  // Backend satp (top level derives FE's csr_vm_en from it; the page-table walk itself is done by the ISA model)
  logic [63:0]            satp;

endinterface : orbe_fe_mem_if
