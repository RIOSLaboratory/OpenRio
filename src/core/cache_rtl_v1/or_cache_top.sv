// OR_Cache top: instantiates all submodules; E1 arbitration + AGU + AMO stall, E2/E3/E4 pipeline registers and E3 result routing live in this layer
module or_cache_top
  import or_be_lsu_protocol_pkg::*;
  import or_cache_pkg::*;
(
  input  logic                    clk,
  input  logic                    rst_n,
  // ---------------- BE ↔ LSU (frozen interface)
  input  logic                    global_flush_late,
  input  logic                    be_lsu_issue_valid,
  /* verilator lint_off UNUSEDSIGNAL */   // req_property / is_store are redundant with exe_subop; this RTL derives them from exe_subop
  input  be_lsu_issue_pld_t       be_lsu_issue_pld,
  /* verilator lint_on UNUSEDSIGNAL */
  input  logic                    lsu_be_issue_ready,     // computed combinationally at the interface (rst_n ∧ ¬(store_side ∧ full))
  input  logic                    be_lsu_entry_ready,
  input  logic                    be_lsu_store_wakeup_valid,
  output logic                    lsu_store_buffer_full,
  output logic                    lsu_be_done_valid_q,
  output lsu_be_done_pld_t        lsu_be_done_pld,
  output logic                    lsu_be_exception_valid_q,
  output lsu_be_exception_pld_t   lsu_be_exception_pld,
  output logic                    lsu_be_bypass_valid_q,
  output lsu_be_done_pld_t        lsu_be_bypass_pld,
  // ---------------- refill / eviction
  output logic                    dc_l2_req_vld,
  output logic [MSHR_ID_W-1:0]    dc_l2_req_id,
  output logic [LINE_ADDR_W-1:0]  dc_l2_req_pa_line,
  input  logic                    dc_l2_req_ready,
  input  logic                    dc_l2_resp,
  input  logic [MSHR_ID_W-1:0]    dc_l2_resp_id,
  input  logic [LINE_W-1:0]       dc_l2_resp_data,
  input  logic                    dc_l2_resp_err,
  output logic                    dc_evict_vld,
  output logic [LINE_ADDR_W-1:0]  dc_evict_pa_line,
  output logic [LINE_W-1:0]       dc_evict_data,
  // ---------------- PTW
  output logic                    dc_ptw_req_vld,
  output logic [VPN_W-1:0]        dc_ptw_req_vpn,
  output logic [TMQ_ID_W-1:0]     dc_ptw_req_id,
  input  logic                    dc_ptw_req_ready,
  input  logic                    dc_ptw_resp,
  input  logic [TMQ_ID_W-1:0]     dc_ptw_resp_id,
  input  logic [PPN_W-1:0]        dc_ptw_resp_ppn,
  input  pg_lvl_t                 dc_ptw_resp_lvl,
  input  logic [4:0]              dc_ptw_resp_rcause,
  input  logic [4:0]              dc_ptw_resp_wcause,
  // ---------------- CSR / sfence
  input  logic [63:0]             csr_satp,
  input  logic [1:0]              csr_priv,
  input  logic                    csr_sum,
  input  logic                    csr_mxr,
  input  logic                    sfence_vma,
  // ---------------- model sync observation port (TB only)
  output logic                    ms_drain_vld,
  output lsu_tag_t                ms_drain_tag,
  output isb_kind_e               ms_drain_kind,
  output logic [63:0]             ms_drain_data,
  output logic                    ms_drain_sc_ok
);
  // ================================================================ FLUSH_CTRL
  logic flush, inval_now, vm_en;
  dc_flush_ctrl u_flush (
    .clk, .rst_n, .global_flush(global_flush_late),
    .csr_satp, .csr_priv, .csr_sum, .csr_mxr, .sfence_vma,
    .flush, .inval_now, .vm_en
  );


  // ================================================================ E1: accept, arbitration, AGU, AMO stall
  lsu_req_property_t in_prop;
  logic              issue_fire;
  logic              in_st;
  logic [SEQ_W-1:0]  seq_q;
  logic [NTAG-1:0]   inflight_rd_q;

  assign in_prop    = req_property_from_subop(be_lsu_issue_pld.exe_subop);
  assign in_st      = is_store_class(in_prop);
  assign issue_fire = be_lsu_issue_valid && lsu_be_issue_ready && !flush;

  logic                   isb_full;
  logic [ISB_IDX_W-1:0]   isb_alloc_idx;
  logic [ISB_IDX_W:0]     isb_count;
  logic [WB_PTR_W-1:0]    wb_cnt;
  logic                   e1_auth;
  logic                   mq_sel_valid;
  dc_op_t                 mq_sel_op;
  logic                   mq_take;
  logic                   cdb_acc;
  /* verilator lint_off UNUSEDSIGNAL */   // only tag used on accept
  cdb_ent_t               cdb_acc_ent;
  /* verilator lint_on UNUSEDSIGNAL */

  dc_op_t issue_op;
  always_comb begin
    issue_op          = '0;
    issue_op.tag      = be_lsu_issue_pld.self_tag;
    issue_op.prop     = in_prop;
    issue_op.memop    = lsu_memop_from_subop(be_lsu_issue_pld.exe_subop);
    issue_op.funct3   = be_lsu_issue_pld.mem_funct3;
    issue_op.rd_is_fp = be_lsu_issue_pld.rd_is_fp;
    issue_op.seq      = seq_q;
    issue_op.len      = is_misc(in_prop) ? 4'd1 : mem_funct3_bytes(be_lsu_issue_pld.mem_funct3);
  end

  // AMO stall: an accepted AMO waits in the stall register while ISB or WB is non-empty, released once both are empty
  logic            e2_st_first;         // E2 holds a store-side new issue pass (not yet allocated)
  logic            lsq_empty;
  logic            hold_v_q;
  dc_op_t          hold_op_q;
  logic [63:0]     hold_rs2_q;
  logic            hold_auth_q;
  logic [NTAG-1:0] hold_ord_q;
  logic            hold_cap, hold_rel, issue_go;

  assign lsq_empty = (isb_count == '0) && (wb_cnt == '0) && !e2_st_first;
  assign hold_cap  = issue_fire && in_prop.is_amo && !lsq_empty;
  assign issue_go  = issue_fire && !hold_cap;
  assign hold_rel  = hold_v_q && !issue_fire && lsq_empty && !flush;
  assign mq_take   = !flush && !issue_fire && !hold_rel && mq_sel_valid;

  dc_op_t e1_op;
  assign e1_op = issue_fire ? issue_op : hold_rel ? hold_op_q : mq_sel_op;

  // AGU (E1): new issue computes rs1+imm on the fly; stalled AMO and replay take the payload VA
  logic [63:0] e1_va, e1_pva;
  logic [3:0]  e1_plen;
  logic        e1_cross;
  dc_agu u_agu (
    .from_issue(issue_fire), .rs1_data(be_lsu_issue_pld.rs1_data), .imm_data(be_lsu_issue_pld.imm_data),
    .imm_valid(be_lsu_issue_pld.imm_valid),
    .op_va(e1_op.va), .len(e1_op.len), .part(e1_op.part),
    .va(e1_va), .pva(e1_pva), .plen(e1_plen), .xline(e1_cross)
  );

  logic [NTAG-1:0] ord_now;   // O1 snapshot: this cycle's in-flight read-side set (minus the one accepted this cycle)
  assign ord_now = cdb_acc ? (inflight_rd_q & ~(NTAG'(1) << cdb_acc_ent.tag)) : inflight_rd_q;

  // ================================================================ E1 → E2
  logic            e2_v_q, e2_issue_q;
  dc_op_t          e2_op_q;
  logic [63:0]     e2_pva_q, e2_rs2_q;
  logic [3:0]      e2_plen_q;
  logic            e2_cross_q, e2_auth_q;
  logic [NTAG-1:0] e2_ord_q;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      e2_v_q <= 1'b0; e2_issue_q <= 1'b0; e2_op_q <= '0; e2_pva_q <= '0; e2_rs2_q <= '0;
      e2_plen_q <= '0; e2_cross_q <= 1'b0; e2_auth_q <= 1'b0; e2_ord_q <= '0;
      hold_v_q <= 1'b0; hold_op_q <= '0; hold_rs2_q <= '0; hold_auth_q <= 1'b0; hold_ord_q <= '0;
      seq_q <= '0; inflight_rd_q <= '0;
    end else begin
      e2_v_q     <= !flush && (issue_go || hold_rel || mq_take);
      e2_issue_q <= issue_go || hold_rel;
      e2_op_q    <= e1_op;
      e2_op_q.va <= e1_va;
      e2_pva_q   <= e1_pva;
      e2_plen_q  <= e1_plen;
      e2_cross_q <= e1_cross;
      e2_rs2_q   <= hold_rel ? hold_rs2_q : be_lsu_issue_pld.rs2_data;
      e2_auth_q  <= hold_rel ? hold_auth_q : e1_auth;
      e2_ord_q   <= hold_rel ? (cdb_acc ? (hold_ord_q & ~(NTAG'(1) << cdb_acc_ent.tag)) : hold_ord_q) : ord_now;

      // AMO stall register
      if (flush || hold_rel) hold_v_q <= 1'b0;
      else if (hold_cap) begin
        hold_v_q       <= 1'b1;
        hold_op_q      <= issue_op;
        hold_op_q.va   <= e1_va;
        hold_rs2_q     <= be_lsu_issue_pld.rs2_data;
        hold_auth_q    <= e1_auth;
        hold_ord_q     <= ord_now;
      end else if (hold_v_q && cdb_acc) hold_ord_q[cdb_acc_ent.tag] <= 1'b0;

      if (issue_fire) seq_q <= seq_q + 1'b1;
      if (flush) inflight_rd_q <= '0;
      else begin
        logic [NTAG-1:0] m;
        m = inflight_rd_q;
        if (cdb_acc) m[cdb_acc_ent.tag] = 1'b0;
        if (issue_fire && is_read_only(in_prop)) m[be_lsu_issue_pld.self_tag] = 1'b1;
        inflight_rd_q <= m;
      end
    end
  end

  // ================================================================ E2: D cache read + tag compare, DTLB, ISB allocate and pre-filter
  logic                 tlb_hit, tlb_pma_fault;
  logic [PA_W-1:0]      tlb_pa;
  logic                 tmq_alloc, tmq_alloc_ok;
  logic [TMQ_ID_W-1:0]  tmq_alloc_id;
  logic                 ptw_done;
  logic [TMQ_ID_W-1:0]  ptw_done_id;
  logic [4:0]           ptw_done_rcause, ptw_done_wcause;
  logic [VPN_W-1:0]     e3_vpn;

  dc_dtlb u_dtlb (
    .clk, .rst_n, .vm_en, .inval_now,
    .lk_va(e2_pva_q), .lk_store_class(is_store_class(e2_op_q.prop)),
    .lk_hit(tlb_hit), .lk_pa(tlb_pa), .lk_pma_fault(tlb_pma_fault),
    .tmq_alloc, .tmq_alloc_vpn(e3_vpn), .tmq_alloc_ok, .tmq_alloc_id,
    .ptw_req_vld(dc_ptw_req_vld), .ptw_req_vpn(dc_ptw_req_vpn), .ptw_req_id(dc_ptw_req_id),
    .ptw_req_ready(dc_ptw_req_ready),
    .ptw_resp(dc_ptw_resp), .ptw_resp_id(dc_ptw_resp_id), .ptw_resp_ppn(dc_ptw_resp_ppn),
    .ptw_resp_lvl(dc_ptw_resp_lvl), .ptw_resp_rcause(dc_ptw_resp_rcause), .ptw_resp_wcause(dc_ptw_resp_wcause),
    .ptw_done, .ptw_done_id, .ptw_done_rcause, .ptw_done_wcause
  );

  // D cache
  logic [DC_WAYS-1:0]    rd_valid;
  logic [DC_TAG_W-1:0]   rd_tag   [DC_WAYS];
  logic [63:0]           rd_bytes [DC_WAYS];
  logic [IDX_W-1:0]      isb_lk_set   [2];
  logic [DC_WAYS-1:0]    isb_lk_valid [2];
  logic [DC_TAG_W-1:0]   isb_lk_tag   [2][DC_WAYS];
  logic                  wb_wr_en, wb_wr_install, wb_wr_dirty;
  logic [IDX_W-1:0]      wb_wr_set;
  logic [WAY_W-1:0]      wb_wr_way;
  logic [DC_TAG_W-1:0]   wb_wr_tag;
  logic [LINE_W-1:0]     wb_wr_data;
  logic [LINE_BYTES-1:0] wb_wr_be;
  logic [DC_WAYS-1:0]    wb_wr_excl;
  logic                  touch_en;
  logic [IDX_W-1:0]      touch_set;
  logic [WAY_W-1:0]      touch_way;

  dc_l1d u_l1d (
    .clk, .rst_n,
    .rd_set(e2_pva_q[OFF_W +: IDX_W]), .rd_off(e2_pva_q[OFF_W-1:0]), .rd_valid, .rd_tag, .rd_bytes,
    .lk_set(isb_lk_set), .lk_valid(isb_lk_valid), .lk_tag(isb_lk_tag),
    .wr_en(wb_wr_en), .wr_install(wb_wr_install), .wr_set(wb_wr_set), .wr_way(wb_wr_way),
    .wr_tag(wb_wr_tag), .wr_data(wb_wr_data), .wr_be(wb_wr_be), .wr_dirty(wb_wr_dirty), .wr_excl(wb_wr_excl),
    .evict_vld(dc_evict_vld), .evict_line(dc_evict_pa_line), .evict_data(dc_evict_data),
    .touch_en, .touch_set, .touch_way
  );

  // Tag compare (E2, same stage as D cache read)
  logic             e2_hit;
  logic [WAY_W-1:0] e2_hit_idx;
  dc_tag_compare u_tagcmp (
    .way_valid(rd_valid), .way_tag(rd_tag), .pa_tag(tlb_pa[PA_W-1:OFF_W+IDX_W]),
    /* verilator lint_off PINCONNECTEMPTY */   // hit_way onehot only for assertions and docs; this layer uses hit_idx
    .hit_way(), .hit(e2_hit), .hit_idx(e2_hit_idx)
    /* verilator lint_on PINCONNECTEMPTY */
  );

  // ISB allocate (store-side new issue pass, including released AMO)
  logic e2_alloc;
  assign e2_st_first = e2_v_q && e2_issue_q && is_store_class(e2_op_q.prop);
  assign e2_alloc    = e2_st_first && !flush;

  // ================================================================ E2 → E3
  logic             e3_v_q;
  dc_op_t           e3_op_q;
  logic [3:0]       e3_plen_q;
  logic             e3_cross_q;
  logic [VPN_W-1:0] e3_vpn_q;
  logic             e3_tlb_hit_q, e3_pma_fault_q;
  logic [PA_W-1:0]  e3_pa_q;
  logic             e3_hit_q;
  logic [WAY_W-1:0] e3_hit_idx_q;
  logic [63:0]      e3_bytes_q;
  logic [7:0]       e2_byte_mask;

  assign e2_byte_mask = byte_mask(e2_plen_q);

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      e3_v_q <= 1'b0; e3_op_q <= '0; e3_plen_q <= '0; e3_cross_q <= 1'b0; e3_vpn_q <= '0;
      e3_tlb_hit_q <= 1'b0; e3_pma_fault_q <= 1'b0; e3_pa_q <= '0;
      e3_hit_q <= 1'b0; e3_hit_idx_q <= '0; e3_bytes_q <= '0;
    end else begin
      e3_v_q          <= e2_v_q && !flush;
      e3_op_q         <= e2_op_q;
      if (e2_alloc) e3_op_q.isb_idx <= isb_alloc_idx;
      e3_plen_q       <= e2_plen_q;
      e3_cross_q      <= e2_cross_q;
      e3_vpn_q        <= e2_pva_q[63:12];
      e3_tlb_hit_q    <= tlb_hit;
      e3_pma_fault_q  <= tlb_pma_fault;
      e3_pa_q         <= tlb_pa;
      e3_hit_q        <= e2_hit;
      e3_hit_idx_q    <= e2_hit_idx;
      e3_bytes_q      <= rd_bytes[e2_hit_idx] & {{8{e2_byte_mask[7]}}, {8{e2_byte_mask[6]}},
                                                 {8{e2_byte_mask[5]}}, {8{e2_byte_mask[4]}},
                                                 {8{e2_byte_mask[3]}}, {8{e2_byte_mask[2]}},
                                                 {8{e2_byte_mask[1]}}, {8{e2_byte_mask[0]}}};
    end
  end

  // ================================================================ E3
  dc_op_t          op;
  logic            e3_misc, e3_st, e3_rd, e3_amo, e3_mis, e3_exc, e3_tlb_miss;
  logic [4:0]      e3_cause;
  logic [PA_W-1:0] e3_pa;
  logic            hit;
  assign op          = e3_op_q;
  assign e3_misc     = is_misc(op.prop);
  assign e3_st       = is_store_class(op.prop);
  assign e3_rd       = is_read_only(op.prop);
  assign e3_amo      = op.prop.is_amo;
  assign e3_mis      = (op.prop.is_amo || op.prop.is_lr || op.prop.is_sc) && !atomic_aligned(op.va, op.len);
  assign e3_pa       = e3_pa_q;
  assign e3_vpn      = e3_vpn_q;
  assign hit         = e3_hit_q;

  always_comb begin
    e3_exc   = 1'b0;
    e3_cause = '0;
    if (!e3_misc) begin
      if (e3_mis) begin
        e3_exc = 1'b1; e3_cause = op.prop.is_lr ? CAUSE_LD_MISALIGN : CAUSE_ST_MISALIGN;
      end else if (op.pre_fault) begin
        e3_exc = 1'b1; e3_cause = op.pre_cause;
      end else if (e3_tlb_hit_q && e3_pma_fault_q) begin
        e3_exc = 1'b1; e3_cause = e3_st ? CAUSE_ST_ACCESS : CAUSE_LD_ACCESS;
      end
    end
  end
  assign e3_tlb_miss = !e3_misc && !e3_exc && !e3_tlb_hit_q;

  // forwarding: ISB level-2 confirm + WB match (sampled in this stage, merged in E4)
  logic        fq_valid, fq_wait, fq_cand;
  logic [7:0]  fq_mask, wb_fw_mask, wb_mask3;
  logic [63:0] fq_data, wb_fw_data;
  logic        all_fwd, need_merge;
  assign fq_valid   = e3_v_q && e3_rd && !e3_exc && !e3_tlb_miss;
  assign wb_mask3   = fq_valid ? wb_fw_mask : 8'd0;
  assign all_fwd    = ((fq_mask | wb_mask3 | ~byte_mask(e3_plen_q)) == 8'hFF);
  assign need_merge = fq_cand || (wb_mask3 != 8'd0);

  // AMO OP (E3)
  logic [63:0] amo_src, amo_new, amo_rd;
  dc_amo_op u_amo (
    .memop(op.memop), .funct3(op.funct3), .len(op.len), .old_bytes(e3_bytes_q), .src(amo_src),
    .new_val(amo_new), .rd_val(amo_rd)
  );

  // ---------------------------------------------------------------- E3 routing (exactly one destination, and only in non-flush cycles)
  logic       go;
  assign go = e3_v_q && !flush;

  logic       r_fence, r_exc, r_tlbmiss, r_stcap, r_amo_hit, r_amo_miss;
  logic       r_ld_wait, r_ld_fast, r_ld_slow, r_ld_miss, rd_ok;
  assign rd_ok      = go && e3_rd && !e3_exc && !e3_tlb_miss && !fq_wait;
  assign r_fence    = go && e3_misc;
  assign r_exc      = go && e3_exc;
  assign r_tlbmiss  = go && e3_tlb_miss;
  assign r_stcap    = go && e3_st && !e3_amo && !e3_exc && !e3_tlb_miss;
  assign r_amo_hit  = go && e3_amo && !e3_exc && !e3_tlb_miss && hit;
  assign r_amo_miss = go && e3_amo && !e3_exc && !e3_tlb_miss && !hit;
  assign r_ld_wait  = go && e3_rd && !e3_exc && !e3_tlb_miss && fq_wait;
  assign r_ld_fast  = rd_ok && hit && !need_merge;                     // Load Data Arbiter pass-through
  assign r_ld_slow  = rd_ok && need_merge && (hit || all_fwd);        // to E4 merge
  assign r_ld_miss  = rd_ok && !hit && !all_fwd;

  logic fast_split;   // pass-through cross-line part0: create part1
  assign fast_split = r_ld_fast && e3_cross_q && !op.part;

  // MSHR port A
  logic                 ma_req, ma_ok;
  logic [MSHR_ID_W-1:0] ma_id;
  assign ma_req    = r_ld_miss || r_amo_miss;
  assign tmq_alloc = r_tlbmiss;

  // MissQ allocation port 0 (E3)
  logic                 mq_alloc;
  dc_op_t               mq_alloc_op;
  mq_wait_e             mq_alloc_wait;
  logic [MSHR_ID_W-1:0] mq_alloc_wait_id;
  always_comb begin
    mq_alloc         = 1'b0;
    mq_alloc_op      = op;
    mq_alloc_wait    = W_NONE;
    mq_alloc_wait_id = '0;
    if (r_tlbmiss) begin
      mq_alloc = 1'b1;
      mq_alloc_wait    = tmq_alloc_ok ? W_TLB : W_TLB_ANY;
      mq_alloc_wait_id = MSHR_ID_W'(tmq_alloc_id);
    end else if (r_ld_wait) begin
      mq_alloc = 1'b1; mq_alloc_wait = W_ISB;
    end else if (r_ld_miss || r_amo_miss) begin
      mq_alloc = 1'b1;
      mq_alloc_wait    = ma_ok ? W_MSHR : W_MSHR_ANY;
      mq_alloc_wait_id = ma_id;
    end else if (fast_split || (r_stcap && e3_cross_q && !op.part)) begin
      mq_alloc = 1'b1;
      mq_alloc_op.part   = 1'b1;
      mq_alloc_op.p0data = e3_bytes_q;
    end
  end

  // CDB port A: E3 exception / FENCE terminal state
  logic     cdb_a_vld;
  cdb_ent_t cdb_a_ent;
  always_comb begin
    cdb_a_ent        = '0;
    cdb_a_ent.tag    = op.tag;
    cdb_a_vld        = r_fence || r_exc;
    if (r_exc) begin
      cdb_a_ent.is_exc = 1'b1;
      cdb_a_ent.data   = op.va;
      cdb_a_ent.cause  = e3_cause;
    end
  end

  assign touch_en  = r_ld_fast || (r_ld_slow && hit && !all_fwd) || r_amo_hit;
  assign touch_set = e3_pa[OFF_W +: IDX_W];
  assign touch_way = e3_hit_idx_q;

  // ================================================================ E3 → E4 (merge path)
  logic        e4_v_q;
  dc_op_t      e4_op_q;
  logic [3:0]  e4_plen_q;
  logic        e4_cross_q;
  logic [63:0] e4_bytes_q, e4_isb_data_q, e4_wb_data_q;
  logic [7:0]  e4_isb_mask_q, e4_wb_mask_q;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      e4_v_q <= 1'b0; e4_op_q <= '0; e4_plen_q <= '0; e4_cross_q <= 1'b0;
      e4_bytes_q <= '0; e4_isb_data_q <= '0; e4_wb_data_q <= '0; e4_isb_mask_q <= '0; e4_wb_mask_q <= '0;
    end else begin
      e4_v_q        <= r_ld_slow;
      e4_op_q       <= op;
      e4_plen_q     <= e3_plen_q;
      e4_cross_q    <= e3_cross_q;
      e4_bytes_q    <= e3_bytes_q;
      e4_isb_mask_q <= fq_mask;
      e4_isb_data_q <= fq_data;
      e4_wb_mask_q  <= wb_mask3;
      e4_wb_data_q  <= wb_fw_data;
    end
  end

  // ================================================================ E4: Data merge
  logic        e4_go, e4_split;
  logic [63:0] e4_part_bytes, e4_result;
  assign e4_go    = e4_v_q && !flush;
  assign e4_split = e4_go && e4_cross_q && !e4_op_q.part;

  dc_data_merge u_merge (
    .l1d_bytes(e4_bytes_q), .plen(e4_plen_q),
    .isb_mask(e4_isb_mask_q), .isb_data(e4_isb_data_q),
    .wb_mask(e4_wb_mask_q), .wb_data(e4_wb_data_q),
    .part(e4_op_q.part), .p0data(e4_op_q.p0data), .len(e4_op_q.len),
    .funct3(e4_op_q.funct3), .rd_is_fp(e4_op_q.rd_is_fp),
    .part_bytes(e4_part_bytes), .result(e4_result)
  );

  // MissQ allocation port 1 (E4: merge path cross-line part0 → part1)
  dc_op_t mq_alloc1_op;
  always_comb begin
    mq_alloc1_op        = e4_op_q;
    mq_alloc1_op.part   = 1'b1;
    mq_alloc1_op.p0data = e4_part_bytes;
  end

  // ================================================================ Load Data Arbiter
  logic     lda_vld [2];
  cdb_ent_t lda_ent [2];
  dc_ld_arb u_ldarb (
    .f_vld(r_ld_fast && !fast_split), .f_tag(op.tag), .f_bytes(e3_bytes_q), .f_part(op.part),
    .f_p0data(op.p0data), .f_len(op.len), .f_plen(e3_plen_q), .f_funct3(op.funct3), .f_rd_is_fp(op.rd_is_fp),
    .m_vld(e4_go && !e4_split), .m_tag(e4_op_q.tag), .m_result(e4_result),
    .o_vld(lda_vld), .o_ent(lda_ent)
  );

  // ================================================================ ISB
  logic                   isb_drain;
  isb_kind_e              isb_drain_kind;
  lsu_tag_t               isb_drain_tag;
  logic [63:0]            isb_drain_wdata, isb_drain_rd;
  logic                   isb_drain_sc_ok, isb_drain_bypass;
  logic                   isb_change;
  logic                   mshr_done;
  logic [MSHR_ID_W-1:0]   mshr_done_id;
  logic                   mb_req, mb_ok;
  logic [LINE_ADDR_W-1:0] mb_line;
  logic [MSHR_ID_W-1:0]   mb_id;
  logic                   inst_req, inst_ack;
  logic [LINE_ADDR_W-1:0] inst_line;
  logic [1:0]             st_n;
  st_part_t               st_p [2];
  logic                   st_has [2];
  logic                   st_ok, st_fire;
  logic                   pend_next;

  // next cycle has an accepted but not yet allocated store-side request (in E2 or the AMO stall register)
  assign pend_next = ((issue_go && in_st) || hold_rel) || (hold_v_q && !hold_rel) || hold_cap;

  dc_isb u_isb (
    .clk, .rst_n, .flush,
    .e1_st_acc(issue_fire && in_st), .e1_is_store(in_prop.is_store),
    .e1_st_br_resolve(be_lsu_issue_pld.st_br_resolve), .e1_auth, .pend_next,
    .wakeup(be_lsu_store_wakeup_valid && !flush),
    .alloc(e2_alloc), .alloc_tag(e2_op_q.tag),
    .alloc_kind(e2_op_q.prop.is_amo ? K_AMO : e2_op_q.prop.is_sc ? K_SC : K_STORE),
    .alloc_len(e2_op_q.len),
    .alloc_data(e2_rs2_q), .alloc_va_lo(e2_op_q.va[11:0]), .alloc_is_store(e2_op_q.prop.is_store),
    .alloc_auth(e2_auth_q), .alloc_seq(e2_op_q.seq), .alloc_ord(e2_ord_q),
    .alloc_idx(isb_alloc_idx), .full_q(isb_full), .count(isb_count),
    .pf_valid(e2_v_q && is_read_only(e2_op_q.prop)), .pf_va(e2_pva_q[11:0]), .pf_plen(e2_plen_q),
    .cap(r_stcap || r_amo_hit || r_amo_miss), .cap_idx(op.isb_idx), .cap_part(op.part), .cap_cross(e3_cross_q),
    .cap_line(e3_pa[PA_W-1:OFF_W]), .cap_off(e3_pa[OFF_W-1:0]), .cap_plen(e3_plen_q),
    .fault_set(r_exc && e3_st), .fault_idx(op.isb_idx),
    .amo_src_idx(op.isb_idx), .amo_src,
    .amo_wr(r_amo_hit), .amo_wr_idx(op.isb_idx), .amo_wr_data(amo_new), .amo_wr_rd(amo_rd),
    .fq_valid, .fq_seq(op.seq), .fq_line(e3_pa[PA_W-1:OFF_W]), .fq_cand, .fq_wait, .fq_mask, .fq_data,
    .lk_set(isb_lk_set), .lk_valid(isb_lk_valid), .lk_tag(isb_lk_tag),
    .mb_req, .mb_line, .mb_ok, .mb_id,
    .ntf_vld(inst_req && inst_ack), .ntf_line(inst_line), .mshr_done, .mshr_done_id,
    .st_n, .st_p, .st_has, .st_ok, .st_fire,
    .drain(isb_drain), .drain_kind(isb_drain_kind), .drain_tag(isb_drain_tag),
    .drain_wdata(isb_drain_wdata), .drain_sc_ok(isb_drain_sc_ok), .drain_rd(isb_drain_rd),
    .drain_bypass(isb_drain_bypass),
    .acc(cdb_acc), .acc_tag(cdb_acc_ent.tag),
    .lr_issue(issue_fire && in_prop.is_lr), .lr_issue_seq(seq_q),
    .lr_cap(go && op.prop.is_lr && !e3_exc && !e3_tlb_miss), .lr_cap_seq(op.seq), .lr_cap_pa(e3_pa),
    .isb_change
  );
  assign lsu_store_buffer_full = isb_full;

  // ================================================================ MissQ
  logic [MQ_IDX_W:0] mq_count;
  dc_missq u_missq (
    .clk, .rst_n, .flush,
    .alloc(mq_alloc), .alloc_op(mq_alloc_op), .alloc_wait(mq_alloc_wait), .alloc_wait_id(mq_alloc_wait_id),
    .alloc1(e4_split), .alloc1_op(mq_alloc1_op),
    .ptw_done, .ptw_done_id, .ptw_done_rcause, .ptw_done_wcause, .tlb_inval(inval_now),
    .mshr_done, .mshr_done_id, .isb_change,
    .cur_seq(seq_q), .sel_valid(mq_sel_valid), .sel_op(mq_sel_op), .sel_take(mq_take), .count(mq_count)
  );

  // ================================================================ MSHR / DPB
  logic                   dpb_we;
  logic [MSHR_ID_W-1:0]   dpb_widx;
  logic [MSHR_ID_W-1:0]   inst_id;
  logic [LINE_W-1:0]      inst_data;
  logic                   inst_wr;
  logic [MSHR_ID_W-1:0]   inst_wr_id;

  dc_mshr u_mshr (
    .clk, .rst_n,
    .a_req(ma_req), .a_line(e3_pa[PA_W-1:OFF_W]), .a_ok(ma_ok), .a_id(ma_id),
    .b_req(mb_req), .b_line(mb_line), .b_ok(mb_ok), .b_id(mb_id),
    .l2_req_vld(dc_l2_req_vld), .l2_req_id(dc_l2_req_id), .l2_req_line(dc_l2_req_pa_line),
    .l2_req_ready(dc_l2_req_ready), .l2_resp(dc_l2_resp), .l2_resp_id(dc_l2_resp_id),
    .dpb_we, .dpb_widx,
    .inst_req, .inst_id, .inst_line, .inst_ack, .inst_wr, .inst_wr_id,
    .done(mshr_done), .done_id(mshr_done_id)
  );

  dc_dpb u_dpb (
    .clk, .we(dpb_we), .widx(dpb_widx), .wdata(dc_l2_resp_data), .ridx(inst_id), .rdata(inst_data)
  );

  // ================================================================ WB
  dc_wb u_wb (
    .clk, .rst_n,
    .inst_req, .inst_id, .inst_line, .inst_data, .inst_ack, .inst_wr, .inst_wr_id,
    .st_n, .st_p, .st_has, .st_ok, .st_fire,
    .wr_en(wb_wr_en), .wr_install(wb_wr_install), .wr_set(wb_wr_set), .wr_way(wb_wr_way),
    .wr_tag(wb_wr_tag), .wr_data(wb_wr_data), .wr_be(wb_wr_be), .wr_dirty(wb_wr_dirty), .wr_excl(wb_wr_excl),
    .fw_line(e3_pa[PA_W-1:OFF_W]), .fw_off(e3_pa[OFF_W-1:0]), .fw_plen(e3_plen_q),
    .fw_mask(wb_fw_mask), .fw_data(wb_fw_data), .cnt(wb_cnt)
  );

  // ================================================================ CDB
  cdb_ent_t cdb_b_ent;
  always_comb begin
    cdb_b_ent        = '0;
    cdb_b_ent.tag    = isb_drain_tag;
    cdb_b_ent.data   = isb_drain_rd;
    cdb_b_ent.bypass = isb_drain_bypass;
  end

  dc_cdb u_cdb (
    .clk, .rst_n, .flush,
    .a_vld(cdb_a_vld), .a_ent(cdb_a_ent), .l_vld(lda_vld), .l_ent(lda_ent),
    .b_vld(isb_drain), .b_ent(cdb_b_ent),
    .entry_ready(be_lsu_entry_ready),
    .done_valid_q(lsu_be_done_valid_q), .done_pld(lsu_be_done_pld),
    .exc_valid_q(lsu_be_exception_valid_q), .exc_pld(lsu_be_exception_pld),
    .byp_valid_q(lsu_be_bypass_valid_q), .byp_pld(lsu_be_bypass_pld),
    .acc(cdb_acc), .acc_ent(cdb_acc_ent)
  );

  // ================================================================ observation port
  assign ms_drain_vld   = isb_drain;
  assign ms_drain_tag   = isb_drain_tag;
  assign ms_drain_kind  = isb_drain_kind;
  assign ms_drain_data  = isb_drain_wdata;
  assign ms_drain_sc_ok = isb_drain_sc_ok;

  // ================================================================ assertions
`ifndef SYNTHESIS
  always_ff @(posedge clk) if (rst_n) begin
    assert ($onehot0({r_fence, r_exc, r_tlbmiss, r_stcap, r_amo_hit, r_amo_miss, r_ld_wait, r_ld_fast, r_ld_slow, r_ld_miss}))
      else $error("[TOP] E3 op routed to more than one destination");
    if (go) assert (r_fence || r_exc || r_tlbmiss || r_stcap || r_amo_hit || r_amo_miss || r_ld_wait ||
                    r_ld_fast || r_ld_slow || r_ld_miss)
      else $error("[TOP] E3 op tag=%0d has no destination", op.tag);
    // when AMO reads D cache, WB must hold no pending bytes of that line (guaranteed by the AGU stall)
    if (r_amo_hit) assert (wb_fw_mask == 8'd0) else $error("[TOP] AMO tag=%0d read while WB holds bytes of its line", op.tag);
    assert (!dc_l2_resp || !dc_l2_resp_err) else $error("[TOP] L2 response error for id=%0d", dc_l2_resp_id);
    if (mq_alloc) assert (mq_count < (MQ_IDX_W+1)'(MISSQ_N)) else $error("[TOP] MissQ full");
    if (e4_split) assert (32'(mq_count) + 32'(mq_alloc) < MISSQ_N) else $error("[TOP] MissQ full (port 1)");
    if (hold_cap) assert (!hold_v_q) else $error("[TOP] second AMO while one is held");
  end
`endif
endmodule
