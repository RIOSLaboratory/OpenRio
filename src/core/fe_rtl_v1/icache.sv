// ICACHE: VIPT instruction cache, S0 read, S1 compare, S1/S2 register the hit line; miss leaves S1 and replays
module icache
  import or_fe_pkg::*;
(
  input  logic                   clk,
  input  logic                   rst_n,
  // In-event
  input  logic                   req_hsk,
  input  logic [VA_W-1:0]        req_pc,
  input  logic                   rsp_hsk,
  input  logic                   ifu_flush,
  input  logic                   inv_all,
  input  logic                   tlb_refill_done,
  input  logic                   l2_resp,
  input  logic [MSHR_ID_W-1:0]   l2_resp_id,
  input  logic [LINE_W-1:0]      l2_resp_data,
  // In Static Info
  input  logic                   lookup_vld,
  input  logic [VA_W-1:0]        lookup_pc,
  input  logic                   tlb_hit,
  input  logic [IC_TAG_W-1:0]    tlb_pa_tag,
  input  logic                   tlb_excp_vld,
  input  logic [CAUSE_W-1:0]     tlb_excp_cause,
  input  logic                   tlb_ptw_idle,
  input  logic                   l2_req_ready,
  // Out-event
  output logic                   miss_drop,
  output logic                   replay,
  output logic [VA_W-1:0]        replay_pc,
  output logic                   l2_req_vld,
  output logic [MSHR_ID_W-1:0]   l2_req_id,
  output logic [PA_W-OFF_W-1:0]  l2_req_pa_line,
  output logic                   l2_cancel,
  output logic [MSHR_ID_W-1:0]   l2_cancel_id,
  // Out Static Info
  output logic                   req_rdy,
  output logic                   rsp_vld,
  output logic [SLOT_NUM-1:0][15:0] rsp_half,
  output logic                   rsp_excp_vld,
  output logic [CAUSE_W-1:0]     rsp_excp_cause
);

  typedef enum logic [1:0] {
    P_IDLE     = 2'd0,
    P_WAIT_TLB = 2'd1,
    P_WAIT_L2  = 2'd2
  } pend_e;

  // ---------------- storage ----------------
  logic [IC_SETS-1:0][IC_WAYS-1:0]               tag_vld_q;
  logic [IC_TAG_W-1:0]                           tag_arr [IC_SETS][IC_WAYS];
  logic [LINE_W-1:0]                             data_arr[IC_SETS][IC_WAYS];
  logic [IC_WAYS-1:0]                            rd_tag_vld_q;
  logic [IC_WAYS-1:0][IC_TAG_W-1:0]              rd_tag_q;
  logic [IC_WAYS-1:0][LINE_W-1:0]                rd_data_q;
  logic [SLOT_NUM-1:0][15:0]                     rsp_half_q;
  logic                                          rsp_excp_vld_q;
  logic [CAUSE_W-1:0]                            rsp_excp_cause_q;
  logic [IC_WAY_W-1:0]                           victim_q;
  pend_e                                         pend_q;
  logic [VA_W-1:0]                               pend_pc_q;
  logic [MSHR_ID_W-1:0]                          pend_id_q;

  // ---------------- submodules ----------------
  logic [IC_WAYS-1:0]  tc_hit_way;
  logic                tc_hit;
  logic [IC_WAY_W-1:0] tc_hit_idx;

  tag_compare u_tag_compare (
    .tag_vld (rd_tag_vld_q),
    .tag_rd  (rd_tag_q),
    .pa_tag  (tlb_pa_tag),
    .hit_way (tc_hit_way),
    .hit     (tc_hit),
    .hit_idx (tc_hit_idx)
  );

  logic                  cache_miss_drop;
  logic                  mshr_alloc_ready;
  logic [MSHR_ID_W-1:0]  mshr_alloc_id;
  logic                  mshr_refill_done;
  logic [MSHR_ID_W-1:0]  mshr_refill_id;
  logic [IC_IDX_W-1:0]   mshr_refill_set;
  logic [IC_WAY_W-1:0]   mshr_refill_way;
  logic [IC_TAG_W-1:0]   mshr_refill_tag;
  logic [LINE_W-1:0]     mshr_refill_data;

  mshr u_mshr (
    .clk              (clk),
    .rst_n            (rst_n),
    .alloc            (cache_miss_drop),
    .alloc_pa_line    ({tlb_pa_tag, ic_idx(lookup_pc)}),
    .alloc_set        (ic_idx(lookup_pc)),
    .alloc_way        (victim_q),
    .cancel           (ifu_flush),
    .l2_resp          (l2_resp),
    .l2_resp_id       (l2_resp_id),
    .l2_resp_data     (l2_resp_data),
    .l2_req_ready     (l2_req_ready),
    .l2_req_vld       (l2_req_vld),
    .l2_req_id        (l2_req_id),
    .l2_req_pa_line   (l2_req_pa_line),
    .l2_cancel        (l2_cancel),
    .l2_cancel_id     (l2_cancel_id),
    .refill_done      (mshr_refill_done),
    .refill_done_id   (mshr_refill_id),
    .refill_done_set  (mshr_refill_set),
    .refill_done_way  (mshr_refill_way),
    .refill_done_tag  (mshr_refill_tag),
    .refill_done_data (mshr_refill_data),
    .alloc_ready      (mshr_alloc_ready),
    .alloc_id         (mshr_alloc_id)
  );

  // ---------------- events ----------------
  logic tlb_miss_drop;
  logic replay_tlb;
  logic replay_l2;
  logic refill_wr;

  assign tlb_miss_drop   = lookup_vld & ~tlb_hit & tlb_ptw_idle & (pend_q == P_IDLE);
  assign cache_miss_drop = lookup_vld & tlb_hit & ~tlb_excp_vld & ~tc_hit & (pend_q == P_IDLE) & mshr_alloc_ready;
  assign replay_tlb      = (pend_q == P_WAIT_TLB) & tlb_refill_done & ~ifu_flush;
  assign replay_l2       = (pend_q == P_WAIT_L2) & mshr_refill_done & (mshr_refill_id == pend_id_q) & ~ifu_flush;
  assign refill_wr       = mshr_refill_done & ~inv_all;

  assign miss_drop  = tlb_miss_drop | cache_miss_drop;
  assign replay     = replay_tlb | replay_l2;
  assign replay_pc  = pend_pc_q;

  assign req_rdy     = ~mshr_refill_done & ~inv_all;
  assign rsp_vld       = tlb_hit & (tlb_excp_vld | tc_hit);
  assign rsp_half       = rsp_half_q;
  assign rsp_excp_vld   = rsp_excp_vld_q;
  assign rsp_excp_cause = rsp_excp_cause_q;

  // ---------------- state ----------------
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      pend_q    <= P_IDLE;
      tag_vld_q <= '0;
      victim_q  <= '0;
    end else begin
      if (tlb_miss_drop) begin
        pend_q <= P_WAIT_TLB;
      end else if (cache_miss_drop) begin
        pend_q <= P_WAIT_L2;
      end else if (replay_tlb || replay_l2 || ifu_flush) begin
        pend_q <= P_IDLE;
      end
      if (cache_miss_drop) begin
        victim_q <= (victim_q == IC_WAY_W'(IC_WAYS - 1)) ? '0 : victim_q + 1'b1;
      end
      if (inv_all) begin
        tag_vld_q <= '0;
      end else if (refill_wr) begin
        tag_vld_q[mshr_refill_set][mshr_refill_way] <= 1'b1;
      end
    end
  end

  // ---------------- arrays and pipeline registers ----------------
  always_ff @(posedge clk) begin
    if (tlb_miss_drop || cache_miss_drop) begin
      pend_pc_q <= lookup_pc;
    end
    if (cache_miss_drop) begin
      pend_id_q <= mshr_alloc_id;
    end
    if (refill_wr) begin
      tag_arr[mshr_refill_set][mshr_refill_way]  <= mshr_refill_tag;
      data_arr[mshr_refill_set][mshr_refill_way] <= mshr_refill_data;
    end
    if (req_hsk) begin
      for (int w = 0; w < IC_WAYS; w++) begin
        rd_tag_vld_q[w] <= tag_vld_q[ic_idx(req_pc)][w];
        rd_tag_q[w]     <= tag_arr[ic_idx(req_pc)][w];
        rd_data_q[w]    <= data_arr[ic_idx(req_pc)][w];
      end
    end
    if (rsp_hsk) begin
      for (int s = 0; s < SLOT_NUM; s++) begin
        rsp_half_q[s] <= rd_data_q[tc_hit_idx][16*s +: 16];
      end
      rsp_excp_vld_q   <= tlb_excp_vld;
      rsp_excp_cause_q <= tlb_excp_cause;
    end
  end

  logic unused_hit_way;
  assign unused_hit_way = ^tc_hit_way;

endmodule
