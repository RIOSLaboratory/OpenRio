// OR_CACHE_DTLB: VA→PA, per-class cached "permitted" bits, PMA, translation miss queue TMQ and PTW port
module dc_dtlb
  import or_cache_pkg::*;
(
  input  logic                    clk,
  input  logic                    rst_n,
  // context (FLUSH_CTRL)
  input  logic                    vm_en,
  input  logic                    inval_now,
  // E2 lookup
  input  logic [63:0]             lk_va,
  input  logic                    lk_store_class,
  output logic                    lk_hit,        // translation available (always 1 when vm_en=0)
  output logic [PA_W-1:0]         lk_pa,
  output logic                    lk_pma_fault,  // lk_hit ∧ PA not within PMA
  // E3 TMQ allocate / merge
  input  logic                    tmq_alloc,
  input  logic [VPN_W-1:0]        tmq_alloc_vpn,
  output logic                    tmq_alloc_ok,
  output logic [TMQ_ID_W-1:0]     tmq_alloc_id,
  // PTW
  output logic                    ptw_req_vld,
  output logic [VPN_W-1:0]        ptw_req_vpn,
  output logic [TMQ_ID_W-1:0]     ptw_req_id,
  input  logic                    ptw_req_ready,
  input  logic                    ptw_resp,
  input  logic [TMQ_ID_W-1:0]     ptw_resp_id,
  input  logic [PPN_W-1:0]        ptw_resp_ppn,
  input  pg_lvl_t                 ptw_resp_lvl,
  input  logic [4:0]              ptw_resp_rcause,
  input  logic [4:0]              ptw_resp_wcause,
  // wakeup broadcast (MissQ)
  output logic                    ptw_done,
  output logic [TMQ_ID_W-1:0]     ptw_done_id,
  output logic [4:0]              ptw_done_rcause,
  output logic [4:0]              ptw_done_wcause
);
  // ---------------------------------------------------------------- entries
  logic                  e_vld  [DTLB_N];
  logic [VPN_W-1:0]      e_vpn  [DTLB_N];
  pg_lvl_t               e_lvl  [DTLB_N];
  logic [PPN_W-1:0]      e_ppn  [DTLB_N];
  logic                  e_r    [DTLB_N];
  logic                  e_w    [DTLB_N];
  logic [DTLB_IDX_W-1:0] rr_q;
  logic [TLB_EPOCH_W-1:0] epoch_q;

  logic                  t_vld  [TMQ_N];
  logic [VPN_W-1:0]      t_vpn  [TMQ_N];
  logic                  t_sent [TMQ_N];
  logic [TLB_EPOCH_W-1:0] t_ep  [TMQ_N];

  function automatic logic [VPN_W-1:0] lvl_mask(input pg_lvl_t l);
    case (l)
      PG_1G:   return {{(VPN_W-18){1'b1}}, 18'd0};
      PG_2M:   return {{(VPN_W-9){1'b1}},  9'd0};
      default: return {VPN_W{1'b1}};
    endcase
  endfunction

  // ---------------------------------------------------------------- lookup (combinational)
  logic [VPN_W-1:0] lk_vpn;
  logic             m_hit;
  logic [PPN_W-1:0] m_ppn;
  pg_lvl_t          m_lvl;
  logic             m_perm;
  logic [63:0]      pa64;

  assign lk_vpn = lk_va[63:12];

  always_comb begin
    m_hit  = 1'b0;
    m_ppn  = '0;
    m_lvl  = PG_4K;
    m_perm = 1'b0;
    for (int i = 0; i < DTLB_N; i++)
      if (e_vld[i] && (((e_vpn[i] ^ lk_vpn) & lvl_mask(e_lvl[i])) == '0)) begin
        m_hit  = 1'b1;
        m_ppn  = e_ppn[i];
        m_lvl  = e_lvl[i];
        m_perm = lk_store_class ? e_w[i] : e_r[i];
      end
  end

  always_comb begin
    logic [PPN_W-1:0] msk;
    msk = lvl_mask(m_lvl);
    if (!vm_en) pa64 = lk_va;
    else        pa64 = {8'd0, ((m_ppn & msk) | (lk_vpn[PPN_W-1:0] & ~msk)), lk_va[11:0]};
  end

  assign lk_hit       = !vm_en || (m_hit && m_perm && !inval_now);
  assign lk_pa        = pa64[PA_W-1:0];
  assign lk_pma_fault = lk_hit && !pma_ok(pa64);

  // ---------------------------------------------------------------- TMQ allocate (E3)
  logic                  mrg_hit;
  logic [TMQ_ID_W-1:0]   mrg_id;
  logic                  free_hit;
  logic [TMQ_ID_W-1:0]   free_id;
  always_comb begin
    mrg_hit = 1'b0; mrg_id = '0; free_hit = 1'b0; free_id = '0;
    for (int i = TMQ_N-1; i >= 0; i--) begin
      if (t_vld[i] && (t_vpn[i] == tmq_alloc_vpn) && (t_ep[i] == epoch_q) && !inval_now) begin
        mrg_hit = 1'b1; mrg_id = TMQ_ID_W'(i);
      end
      if (!t_vld[i]) begin free_hit = 1'b1; free_id = TMQ_ID_W'(i); end
    end
  end
  assign tmq_alloc_ok = mrg_hit || free_hit;
  assign tmq_alloc_id = mrg_hit ? mrg_id : free_id;

  // ---------------------------------------------------------------- PTW request
  always_comb begin
    ptw_req_vld = 1'b0; ptw_req_id = '0;
    for (int i = TMQ_N-1; i >= 0; i--)
      if (t_vld[i] && !t_sent[i]) begin ptw_req_vld = 1'b1; ptw_req_id = TMQ_ID_W'(i); end
  end
  assign ptw_req_vpn = t_vpn[ptw_req_id];

  // ---------------------------------------------------------------- response
  logic resp_live;
  assign resp_live       = ptw_resp && (t_ep[ptw_resp_id] == epoch_q) && !inval_now;
  assign ptw_done        = ptw_resp;
  assign ptw_done_id     = ptw_resp_id;
  assign ptw_done_rcause = resp_live ? ptw_resp_rcause : 5'd0;   // stale response = make waiters re-look-up
  assign ptw_done_wcause = resp_live ? ptw_resp_wcause : 5'd0;

  logic                  inst_en;
  logic [DTLB_IDX_W-1:0] inst_idx;
  always_comb begin
    inst_en  = resp_live && ((ptw_resp_rcause == 5'd0) || (ptw_resp_wcause == 5'd0));
    inst_idx = rr_q;
    for (int i = 0; i < DTLB_N; i++)      // existing entry for same page → overwrite, avoid duplicate hits
      if (e_vld[i] && (((e_vpn[i] ^ t_vpn[ptw_resp_id]) & lvl_mask(e_lvl[i])) == '0))
        inst_idx = DTLB_IDX_W'(i);
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      for (int i = 0; i < DTLB_N; i++) begin
        e_vld[i] <= 1'b0; e_vpn[i] <= '0; e_lvl[i] <= PG_4K; e_ppn[i] <= '0; e_r[i] <= 1'b0; e_w[i] <= 1'b0;
      end
      for (int i = 0; i < TMQ_N; i++) begin
        t_vld[i] <= 1'b0; t_vpn[i] <= '0; t_sent[i] <= 1'b0; t_ep[i] <= '0;
      end
      rr_q    <= '0;
      epoch_q <= '0;
    end else begin
      if (inval_now) begin
        for (int i = 0; i < DTLB_N; i++) e_vld[i] <= 1'b0;
        epoch_q <= epoch_q + 1'b1;
      end else if (inst_en) begin
        e_vld[inst_idx] <= 1'b1;
        e_vpn[inst_idx] <= t_vpn[ptw_resp_id];
        e_lvl[inst_idx] <= ptw_resp_lvl;
        e_ppn[inst_idx] <= ptw_resp_ppn;
        e_r[inst_idx]   <= (ptw_resp_rcause == 5'd0);
        e_w[inst_idx]   <= (ptw_resp_wcause == 5'd0);
        rr_q            <= rr_q + 1'b1;
      end
      if (ptw_req_vld && ptw_req_ready) t_sent[ptw_req_id] <= 1'b1;
      if (ptw_resp) t_vld[ptw_resp_id] <= 1'b0;
      if (tmq_alloc && !mrg_hit && free_hit) begin
        t_vld[free_id]  <= 1'b1;
        t_vpn[free_id]  <= tmq_alloc_vpn;
        t_sent[free_id] <= 1'b0;
        t_ep[free_id]   <= inval_now ? epoch_q + 1'b1 : epoch_q;
      end
    end
  end

`ifndef SYNTHESIS
  always_ff @(posedge clk) if (rst_n) begin
    if (ptw_resp) assert (t_vld[ptw_resp_id] && t_sent[ptw_resp_id])
      else $error("[DTLB] PTW response id=%0d not outstanding", ptw_resp_id);
  end
`endif
endmodule
