// ITLB: fully associative instruction TLB, S1 combinational lookup, single outstanding PTW request
module itlb
  import or_fe_pkg::*;
(
  input  logic                  clk,
  input  logic                  rst_n,
  // In-event
  input  logic                  ptw_resp,
  input  logic [PPN_W-1:0]      resp_ppn,
  input  pg_lvl_t               resp_lvl,
  input  logic                  resp_x,
  input  logic                  resp_u,
  input  logic [1:0]            resp_pbmt,
  input  logic                  resp_fault,
  input  logic [CAUSE_W-1:0]    resp_cause,
  input  logic                  tlb_flush,
  // In Static Info
  input  logic                  lookup_vld,
  input  logic [VA_W-1:0]       lookup_pc,
  input  logic                  vm_en,
  input  priv_t                 priv,
  input  logic [PMP_CFG_W-1:0]  pmp_cfg,
  input  logic                  ptw_req_ready,
  // Out-event
  output logic                  ptw_req_vld,
  output logic [VPN_W-1:0]      ptw_req_vpn,
  output logic                  refill_done,
  // Out Static Info
  output logic                  hit,
  output logic [IC_TAG_W-1:0]   pa_tag,
  output logic                  excp_vld,
  output logic [CAUSE_W-1:0]    excp_cause,
  output logic                  ptw_idle
);

  typedef enum logic [1:0] {
    IDLE = 2'd0,
    REQ  = 2'd1,
    RESP = 2'd2
  } state_e;

  state_e state_q;

  logic [ITLB_NUM-1:0]             ent_vld;
  logic [ITLB_NUM-1:0][VPN_W-1:0]  ent_vpn;
  pg_lvl_t [ITLB_NUM-1:0]          ent_lvl;
  logic [ITLB_NUM-1:0][PPN_W-1:0]  ent_ppn;
  logic [ITLB_NUM-1:0]             ent_x;
  logic [ITLB_NUM-1:0]             ent_u;
  logic [ITLB_NUM-1:0][1:0]        ent_pbmt;
  logic [ITLB_IDX_W-1:0]           repl_ptr_q;
  logic                            stale_q;
  logic [VPN_W-1:0]                req_vpn_q;
  logic                            flt_vld_q;
  logic [VPN_W-1:0]                flt_vpn_q;
  logic [CAUSE_W-1:0]              flt_cause_q;

  // ---------------- lookup ----------------
  logic [VPN_W-1:0]     lookup_vpn;
  logic [ITLB_NUM-1:0]  match;
  logic                 hit_e;
  logic [ITLB_IDX_W-1:0] sel;
  logic                 flt_hit;
  logic [PA_W-1:0]      pa;
  logic                 perm_fault;
  logic                 pf, af;

  function automatic logic vpn_match(input logic [VPN_W-1:0] a, input logic [VPN_W-1:0] b, input pg_lvl_t l);
    if (l == PG_4K)      return a == b;
    else if (l == PG_2M) return a[VPN_W-1:9] == b[VPN_W-1:9];
    else                 return a[VPN_W-1:18] == b[VPN_W-1:18];
  endfunction

  /* verilator lint_off UNUSEDSIGNAL */
  function automatic logic [PA_W-1:0] pa_of(input logic [PPN_W-1:0] p, input pg_lvl_t l, input logic [VA_W-1:0] va);
    if (l == PG_4K)      return {p, va[11:0]};
    else if (l == PG_2M) return {p[PPN_W-1:9], va[20:0]};
    else                 return {p[PPN_W-1:18], va[29:0]};
  endfunction
  /* verilator lint_on UNUSEDSIGNAL */

  assign lookup_vpn = vpn_of(lookup_pc);

  always_comb begin
    for (int e = 0; e < ITLB_NUM; e++) begin
      match[e] = ent_vld[e] && vpn_match(ent_vpn[e], lookup_vpn, ent_lvl[e]);
    end
  end

  always_comb begin
    sel = '0;
    for (int e = ITLB_NUM - 1; e >= 0; e--) begin
      if (match[e]) sel = ITLB_IDX_W'(e);
    end
  end

  assign hit_e      = |match;
  assign flt_hit    = flt_vld_q && (flt_vpn_q == lookup_vpn);
  assign hit        = ~vm_en | hit_e | flt_hit;
  assign pa         = ~vm_en ? PA_W'(lookup_pc) : pa_of(ent_ppn[sel], ent_lvl[sel], lookup_pc);
  assign pa_tag     = ic_tag(pa);
  assign perm_fault = ~ent_x[sel] | ((priv == PRV_U) & ~ent_u[sel]) | ((priv == PRV_S) & ent_u[sel]);
  assign pf         = vm_en & ((flt_hit & (flt_cause_q == CAUSE_IPF)) | (hit_e & perm_fault));
  assign af         = (vm_en & flt_hit & (flt_cause_q == CAUSE_IAF)) | (~pf & pmp_af(pa, priv, pmp_cfg));
  assign excp_vld   = hit & (pf | af);
  assign excp_cause = pf ? CAUSE_IPF : CAUSE_IAF;
  assign ptw_idle   = (state_q == IDLE);

  // ---------------- events ----------------
  logic ptw_start;
  logic ptw_req_fire;
  logic fill_fire;
  logic fault_rec;

  assign ptw_start    = lookup_vld & vm_en & ~hit & (state_q == IDLE);
  assign ptw_req_vld  = (state_q == REQ);
  assign ptw_req_vpn  = req_vpn_q;
  assign ptw_req_fire = ptw_req_vld & ptw_req_ready;
  assign fill_fire    = ptw_resp & ~resp_fault & ~stale_q & ~tlb_flush;
  assign fault_rec    = ptw_resp & resp_fault & ~stale_q & ~tlb_flush;
  assign refill_done  = ptw_resp;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state_q    <= IDLE;
      ent_vld    <= '0;
      flt_vld_q  <= 1'b0;
      stale_q    <= 1'b0;
      repl_ptr_q <= '0;
    end else begin
      // translation request state
      if (ptw_start) begin
        state_q <= REQ;
      end else if (ptw_req_fire) begin
        state_q <= RESP;
      end else if (ptw_resp) begin
        state_q <= IDLE;
      end
      // entry valid
      if (tlb_flush) begin
        ent_vld <= '0;
      end else if (fill_fire) begin
        ent_vld[repl_ptr_q] <= 1'b1;
      end
      if (fill_fire) begin
        repl_ptr_q <= (repl_ptr_q == ITLB_IDX_W'(ITLB_NUM - 1)) ? '0 : repl_ptr_q + 1'b1;
      end
      // buffered exception
      if (tlb_flush || ptw_start) begin
        flt_vld_q <= 1'b0;
      end else if (fault_rec) begin
        flt_vld_q <= 1'b1;
      end
      // stale
      if (ptw_start) begin
        stale_q <= 1'b0;
      end else if (tlb_flush) begin
        stale_q <= (state_q != IDLE) & ~ptw_resp;
      end
    end
  end

  always_ff @(posedge clk) begin
    if (ptw_start) begin
      req_vpn_q <= lookup_vpn;
    end
    if (fill_fire) begin
      ent_vpn[repl_ptr_q]  <= req_vpn_q;
      ent_lvl[repl_ptr_q]  <= resp_lvl;
      ent_ppn[repl_ptr_q]  <= resp_ppn;
      ent_x[repl_ptr_q]    <= resp_x;
      ent_u[repl_ptr_q]    <= resp_u;
      ent_pbmt[repl_ptr_q] <= resp_pbmt;
    end
    if (fault_rec) begin
      flt_vpn_q   <= req_vpn_q;
      flt_cause_q <= resp_cause;
    end
  end

  // ent_pbmt stored only, ⟨to confirm⟩ NC/IO fetch behavior
  logic unused_pbmt;
  assign unused_pbmt = ^ent_pbmt;

endmodule
