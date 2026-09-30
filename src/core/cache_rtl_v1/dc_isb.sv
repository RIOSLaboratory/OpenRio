// OR_CACHE_ISB: store-side entries
//   E1 auth slot consume / E2 allocate (data, VA low bits) / E3 write PA and AMO result; two-level forwarding (E2 VA page-offset pre-filter, E3 PA page-number confirm);
//   after head is authorized, the tag lookup port decides D cache hit/miss: hit → hand to WB (commit, release); miss → register in MSHR, data stays in ISB, enters WB together with the DPB line in the refill install cycle;
//   head blocking; AMO result (computed by AMO OP in E3) commits via the normal store path; SC decision; LR/SC reservation
module dc_isb
  import or_be_lsu_protocol_pkg::*;
  import or_cache_pkg::*;
(
  input  logic                    clk,
  input  logic                    rst_n,
  input  logic                    flush,
  // ---------------- E1 (accept cycle)
  input  logic                    e1_st_acc,        // store-side request accepted this cycle (allocated in E2 next cycle, or goes to the AMO stall register)
  input  logic                    e1_is_store,
  input  logic                    e1_st_br_resolve,
  output logic                    e1_auth,          // initial authorization of this request (travels with the op into E2)
  input  logic                    pend_next,        // next cycle has an accepted but not yet allocated store-side request (in E2 or the AMO stall register; counts toward full)
  input  logic                    wakeup,
  // ---------------- E2 allocate
  input  logic                    alloc,
  input  lsu_tag_t                alloc_tag,
  input  isb_kind_e               alloc_kind,
  input  logic [3:0]              alloc_len,
  input  logic [63:0]             alloc_data,
  input  logic [11:0]             alloc_va_lo,
  input  logic                    alloc_is_store,
  input  logic                    alloc_auth,
  input  logic [SEQ_W-1:0]        alloc_seq,
  input  logic [NTAG-1:0]         alloc_ord,        // set of read-side ops in flight at E1 time (O1)
  output logic [ISB_IDX_W-1:0]    alloc_idx,
  output logic                    full_q,
  output logic [ISB_IDX_W:0]      count,
  // ---------------- E2 forwarding pre-filter
  input  logic                    pf_valid,
  input  logic [11:0]             pf_va,            // page offset of this part's start VA
  input  logic [3:0]              pf_plen,
  // ---------------- E3 PA write / exception
  input  logic                    cap,
  input  logic [ISB_IDX_W-1:0]    cap_idx,
  input  logic                    cap_part,
  input  logic                    cap_cross,
  input  logic [LINE_ADDR_W-1:0]  cap_line,
  input  logic [OFF_W-1:0]        cap_off,
  input  logic [3:0]              cap_plen,
  input  logic                    fault_set,
  input  logic [ISB_IDX_W-1:0]    fault_idx,
  // ---------------- E3 AMO: read rs2, write back result
  input  logic [ISB_IDX_W-1:0]    amo_src_idx,
  output logic [63:0]             amo_src,
  input  logic                    amo_wr,
  input  logic [ISB_IDX_W-1:0]    amo_wr_idx,
  input  logic [63:0]             amo_wr_data,      // new value
  input  logic [63:0]             amo_wr_rd,        // shaped old value (done data)
  // ---------------- E3 forwarding confirm
  input  logic                    fq_valid,
  input  logic [SEQ_W-1:0]        fq_seq,
  /* verilator lint_off UNUSEDSIGNAL */   // only page number fq_line[LINE_ADDR_W-1:12-OFF_W] is compared
  input  logic [LINE_ADDR_W-1:0]  fq_line,
  /* verilator lint_on UNUSEDSIGNAL */
  output logic                    fq_cand,          // a pre-filter candidate older than the read exists (no pass-through)
  output logic                    fq_wait,
  output logic [7:0]              fq_mask,
  output logic [63:0]             fq_data,
  // ---------------- head tag lookup port
  output logic [IDX_W-1:0]        lk_set   [2],
  input  logic [DC_WAYS-1:0]      lk_valid [2],
  input  logic [DC_TAG_W-1:0]     lk_tag   [2][DC_WAYS],
  // ---------------- MSHR: port B registration, install notify, completion
  output logic                    mb_req,
  output logic [LINE_ADDR_W-1:0]  mb_line,
  input  logic                    mb_ok,
  input  logic [MSHR_ID_W-1:0]    mb_id,
  input  logic                    ntf_vld,          // MSHR commands install this cycle (WB accepts)
  input  logic [LINE_ADDR_W-1:0]  ntf_line,
  input  logic                    mshr_done,        // install written into D cache
  input  logic [MSHR_ID_W-1:0]    mshr_done_id,
  // ---------------- WB commit
  output logic [1:0]              st_n,
  output st_part_t                st_p   [2],
  input  logic                    st_has [2],
  input  logic                    st_ok,
  output logic                    st_fire,
  // ---------------- commit (= model store_commit)
  output logic                    drain,
  output isb_kind_e               drain_kind,
  output lsu_tag_t                drain_tag,
  output logic [63:0]             drain_wdata,
  output logic                    drain_sc_ok,
  output logic [63:0]             drain_rd,
  output logic                    drain_bypass,
  // ---------------- terminal state accepted by BE: clear O1 bit
  input  logic                    acc,
  input  lsu_tag_t                acc_tag,
  // ---------------- LR reservation
  input  logic                    lr_issue,
  input  logic [SEQ_W-1:0]        lr_issue_seq,
  input  logic                    lr_cap,
  input  logic [SEQ_W-1:0]        lr_cap_seq,
  input  logic [PA_W-1:0]         lr_cap_pa,
  output logic                    isb_change
);
  // ---------------------------------------------------------------- entries (all entries in ISB are uncommitted)
  logic                   e_vld    [ISB_N];
  lsu_tag_t               e_tag    [ISB_N];
  isb_kind_e              e_kind   [ISB_N];
  logic [3:0]             e_len    [ISB_N];
  logic [63:0]            e_data   [ISB_N];   // rs2; AMO overwrites with new value in E3
  logic [11:0]            e_va     [ISB_N];   // VA page offset (E2)
  logic [SEQ_W-1:0]       e_seq    [ISB_N];
  logic                   e_isst   [ISB_N];   // normal store (authorized via wakeup)
  logic                   e_auth   [ISB_N];
  logic                   e_fault  [ISB_N];
  logic                   e_cross  [ISB_N];
  logic [1:0]             e_pav    [ISB_N];
  logic [LINE_ADDR_W-1:0] e_line   [ISB_N][2];
  logic [OFF_W-1:0]       e_off    [ISB_N][2];
  logic [3:0]             e_plen   [ISB_N][2];
  logic [NTAG-1:0]        e_ord    [ISB_N];   // older in-flight read-side tags (O1)
  logic [1:0]             e_mwt    [ISB_N];   // part waiting on MSHR
  logic [1:0]             e_many   [ISB_N];
  logic [MSHR_ID_W-1:0]   e_mid    [ISB_N][2];
  logic                   e_amo_rdy [ISB_N];  // AMO result written back
  logic [63:0]            e_amo_rd  [ISB_N];  // AMO shaped old value (done data)

  logic [ISB_PTR_W-1:0]   rptr_q, wptr_q;
  logic                   early_q;
  logic                   rsv_vld_q;
  logic                   rsv_pa_vld_q;
  logic [SEQ_W-1:0]       rsv_seq_q;
  logic [PA_W-1:0]        rsv_pa_q;
  pf_ent_t                pf_q [ISB_N];      // E2 pre-filter result (registered E2→E3)

  logic [ISB_IDX_W-1:0] h, widx;
  logic                 hv;
  assign h         = rptr_q[ISB_IDX_W-1:0];
  assign widx      = wptr_q[ISB_IDX_W-1:0];
  assign count     = wptr_q - rptr_q;
  assign hv        = (count != '0);
  assign alloc_idx = widx;
  assign amo_src   = e_data[amo_src_idx];

  /* verilator lint_off UNUSEDSIGNAL */   // k < ISB_N, only low bits used
  function automatic logic [ISB_IDX_W-1:0] fidx(input logic [ISB_PTR_W-1:0] p, input int k);
    logic [ISB_PTR_W-1:0] s;
    s = p + ISB_PTR_W'(k);
    return s[ISB_IDX_W-1:0];
  endfunction
  /* verilator lint_on UNUSEDSIGNAL */

  function automatic logic all_pa(input logic [ISB_IDX_W-1:0] i);
    return e_pav[i][0] && (!e_cross[i] || e_pav[i][1]);
  endfunction

  // ---------------------------------------------------------------- authorization (candidates: ISB entry → store pending allocation in E2 → early slot)
  logic                 wk_hit, wk_e2;
  logic [ISB_IDX_W-1:0] wk_idx;
  logic                 eff_early, consume_early;
  always_comb begin
    wk_hit = 1'b0; wk_idx = '0;
    for (int k = ISB_N-1; k >= 0; k--) begin
      logic [ISB_IDX_W-1:0] i;
      i = fidx(rptr_q, k);
      if ((k < int'(count)) && e_isst[i] && !e_auth[i]) begin wk_hit = 1'b1; wk_idx = i; end
    end
  end
  assign wk_e2         = wakeup && !wk_hit && alloc && alloc_is_store && !alloc_auth;
  assign eff_early     = early_q || (wakeup && !wk_hit && !wk_e2);
  assign consume_early = e1_st_acc && e1_is_store && !e1_st_br_resolve && eff_early;
  assign e1_auth       = !e1_is_store || e1_st_br_resolve || eff_early;

  // ---------------------------------------------------------------- forwarding level 1 (E2): per-byte page-offset pre-filter
  pf_ent_t pf_n [ISB_N];
  always_comb begin
    for (int i = 0; i < ISB_N; i++) begin
      pf_n[i] = '0;
      for (int k = 0; k < ISB_N; k++)
        if (fidx(rptr_q, k) == ISB_IDX_W'(i) && (k < int'(count)) && pf_valid)
          for (int b = 0; b < 8; b++)
            for (int j = 0; j < 8; j++)
              if ((4'(b) < pf_plen) && (4'(j) < e_len[i]) &&
                  ((pf_va + 12'(b)) == (e_va[i] + 12'(j)))) begin
                pf_n[i].v[b] = 1'b1;
                pf_n[i].j[b] = 3'(j);
                pf_n[i].p[b] = (({1'b0, e_va[i][OFF_W-1:0]} + (OFF_W+1)'(j)) >= (OFF_W+1)'(LINE_BYTES));
              end
    end
  end

  // ---------------------------------------------------------------- forwarding level 2 (E3): PA page-number confirm, youngest per byte
  always_comb begin
    fq_cand = 1'b0; fq_wait = 1'b0; fq_mask = '0; fq_data = '0;
    for (int k = 0; k < ISB_N; k++) begin
      logic [ISB_IDX_W-1:0] i;
      i = fidx(rptr_q, k);
      if (fq_valid && (k < int'(count)) && seq_older(e_seq[i], fq_seq)) begin
        if (pf_q[i].v != '0) fq_cand = 1'b1;
        for (int b = 0; b < 8; b++)
          if (pf_q[i].v[b]) begin
            if (!e_pav[i][pf_q[i].p[b]]) fq_wait = 1'b1;           // pre-filter hit but PA unknown
            else if (e_line[i][pf_q[i].p[b]][LINE_ADDR_W-1:12-OFF_W] == fq_line[LINE_ADDR_W-1:12-OFF_W]) begin
              if (e_kind[i] == K_STORE) begin
                fq_mask[b]        = 1'b1;
                fq_data[8*b +: 8] = e_data[i][8*int'(pf_q[i].j[b]) +: 8];
              end else fq_wait = 1'b1;                              // uncommitted AMO / SC: write data not yet determined
            end
          end
      end
    end
  end

  // ---------------------------------------------------------------- head: hit/miss, commit
  logic        base, sc_ok, sc_fail;
  logic [1:0]  h_n;
  logic        lk_hit [2];
  logic [WAY_W-1:0] lk_way [2];
  logic        pres [2];
  logic        commit_h;

  assign base    = hv && !e_fault[h] && e_auth[h] && all_pa(h) && (e_ord[h] == '0) && !flush &&
                   ((e_kind[h] != K_AMO) || e_amo_rdy[h]);
  assign sc_ok   = rsv_vld_q && rsv_pa_vld_q && (rsv_pa_q == {e_line[h][0], e_off[h][0]});
  assign sc_fail = (e_kind[h] == K_SC) && !sc_ok;
  assign h_n     = e_cross[h] ? 2'd2 : 2'd1;

  always_comb begin
    for (int p = 0; p < 2; p++) begin
      lk_set[p] = e_line[h][p][IDX_W-1:0];
      lk_hit[p] = 1'b0; lk_way[p] = '0;
      for (int w = 0; w < DC_WAYS; w++)
        if (lk_valid[p][w] && (lk_tag[p][w] == e_line[h][p][LINE_ADDR_W-1:IDX_W])) begin
          lk_hit[p] = 1'b1; lk_way[p] = WAY_W'(w);
        end
    end
  end
  always_comb
    for (int p = 0; p < 2; p++)
      pres[p] = lk_hit[p] || st_has[p] || (ntf_vld && (ntf_line == e_line[h][p]));

  // parts committed to WB (STORE / successful SC / AMO new value)
  always_comb begin
    for (int p = 0; p < 2; p++) begin
      st_p[p].line = e_line[h][p];
      st_p[p].off  = e_off[h][p];
      st_p[p].plen = e_plen[h][p];
      st_p[p].data = (p == 0) ? e_data[h] : (e_data[h] >> (8 * e_plen[h][0]));
      st_p[p].hit  = lk_hit[p];
      st_p[p].way  = lk_way[p];
    end
    st_n = (base && !sc_fail) ? h_n : 2'd0;
  end

  assign commit_h = base && (sc_fail || st_ok);
  assign st_fire  = commit_h && !sc_fail;

  // miss registration (port B): part0 first, then part1
  logic need0, need1, mb_part;
  assign need0   = base && !sc_fail && !pres[0] && !e_mwt[h][0];
  assign need1   = base && !sc_fail && e_cross[h] && !pres[1] && !e_mwt[h][1];
  assign mb_req  = need0 || need1;
  assign mb_part = !need0;
  assign mb_line = e_line[h][mb_part];

  // commit outputs
  assign drain        = commit_h;
  assign drain_kind   = e_kind[h];
  assign drain_tag    = e_tag[h];
  assign drain_wdata  = e_data[h];
  assign drain_sc_ok  = commit_h && (e_kind[h] == K_SC) && sc_ok;
  assign drain_rd     = (e_kind[h] == K_AMO) ? e_amo_rd[h] :
                        (e_kind[h] == K_SC)  ? (sc_ok ? 64'd0 : 64'd1) : 64'd0;
  assign drain_bypass = (e_kind[h] == K_AMO) || (e_kind[h] == K_SC);

  assign isb_change = cap || fault_set || drain || flush;

  // ---------------------------------------------------------------- sequential
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      rptr_q <= '0; wptr_q <= '0;
      early_q <= 1'b0; rsv_vld_q <= 1'b0; rsv_pa_vld_q <= 1'b0; rsv_seq_q <= '0; rsv_pa_q <= '0; full_q <= 1'b0;
      for (int i = 0; i < ISB_N; i++) begin
        e_vld[i] <= 1'b0; e_tag[i] <= '0; e_kind[i] <= K_STORE;
        e_len[i] <= '0; e_data[i] <= '0; e_va[i] <= '0; e_seq[i] <= '0; e_isst[i] <= 1'b0;
        e_auth[i] <= 1'b0; e_fault[i] <= 1'b0; e_cross[i] <= 1'b0; e_pav[i] <= '0; e_ord[i] <= '0;
        e_mwt[i] <= '0; e_many[i] <= '0; e_amo_rdy[i] <= 1'b0; e_amo_rd[i] <= '0;
        pf_q[i] <= '0;
        for (int p = 0; p < 2; p++) begin
          e_line[i][p] <= '0; e_off[i][p] <= '0; e_plen[i][p] <= '0; e_mid[i][p] <= '0;
        end
      end
    end else begin
      logic [ISB_PTR_W-1:0] rptr_n, wptr_n;
      rptr_n = rptr_q; wptr_n = wptr_q;

      for (int i = 0; i < ISB_N; i++) pf_q[i] <= pf_n[i];

      // reservation: set in LR accept cycle, PA filled in E3; cleared on every store-side commit (same-cycle commit wins); not cleared by flush
      if (drain) rsv_vld_q <= 1'b0;
      else if (lr_issue) rsv_vld_q <= 1'b1;
      if (lr_issue) begin
        rsv_seq_q    <= lr_issue_seq;
        rsv_pa_vld_q <= 1'b0;
      end else if (lr_cap && (lr_cap_seq == rsv_seq_q)) begin
        rsv_pa_vld_q <= 1'b1;
        rsv_pa_q     <= lr_cap_pa;
      end

      // terminal state accepted: clear O1 bit
      if (acc) for (int i = 0; i < ISB_N; i++) e_ord[i][acc_tag] <= 1'b0;

      // wakeup of MSHR waits (a completion in the same cycle as this cycle's set also takes effect, see below)
      for (int i = 0; i < ISB_N; i++)
        for (int p = 0; p < 2; p++)
          if (e_mwt[i][p] && mshr_done && (e_many[i][p] || (mshr_done_id == e_mid[i][p]))) e_mwt[i][p] <= 1'b0;

      if (flush) begin
        // all entries in ISB are uncommitted, clear entirely
        for (int i = 0; i < ISB_N; i++) begin e_vld[i] <= 1'b0; e_mwt[i] <= '0; end
        rptr_n  = '0;
        wptr_n  = '0;
        early_q <= 1'b0;
      end else begin
        // authorization
        if (wakeup && wk_hit) e_auth[wk_idx] <= 1'b1;
        early_q <= consume_early ? 1'b0 : eff_early;

        // PA write / exception (E3)
        if (cap) begin
          e_pav[cap_idx][cap_part]  <= 1'b1;
          e_line[cap_idx][cap_part] <= cap_line;
          e_off[cap_idx][cap_part]  <= cap_off;
          e_plen[cap_idx][cap_part] <= cap_plen;
          if (!cap_part) e_cross[cap_idx] <= cap_cross;
        end
        if (fault_set) e_fault[fault_idx] <= 1'b1;

        // AMO result write (E3)
        if (amo_wr) begin
          e_data[amo_wr_idx]    <= amo_wr_data;
          e_amo_rd[amo_wr_idx]  <= amo_wr_rd;
          e_amo_rdy[amo_wr_idx] <= 1'b1;
        end

        // head miss registration
        if (mb_req) begin
          e_mwt[h][mb_part]  <= !(mshr_done && (!mb_ok || (mshr_done_id == mb_id)));
          e_many[h][mb_part] <= !mb_ok;
          e_mid[h][mb_part]  <= mb_id;
        end

        // release on commit (hand to WB)
        if (drain) begin
          e_vld[h] <= 1'b0;
          e_mwt[h] <= '0;
          rptr_n   = rptr_q + 1'b1;
        end

        // E2 allocate
        if (alloc) begin
          e_vld[widx]     <= 1'b1;
          e_tag[widx]     <= alloc_tag;
          e_kind[widx]    <= alloc_kind;
          e_len[widx]     <= alloc_len;
          e_data[widx]    <= alloc_data;
          e_va[widx]      <= alloc_va_lo;
          e_seq[widx]     <= alloc_seq;
          e_isst[widx]    <= alloc_is_store;
          e_auth[widx]    <= alloc_auth || wk_e2;
          e_fault[widx]   <= 1'b0;
          e_cross[widx]   <= 1'b0;
          e_pav[widx]     <= '0;
          e_ord[widx]     <= acc ? (alloc_ord & ~(NTAG'(1) << acc_tag)) : alloc_ord;
          e_mwt[widx]     <= '0;
          e_amo_rdy[widx] <= 1'b0;
          wptr_n = wptr_q + 1'b1;
        end
      end

      rptr_q <= rptr_n; wptr_q <= wptr_n;
      // full: valid entries + accepted but not yet allocated store-side request (in E2 next cycle or still in the AMO stall register)
      full_q <= ((ISB_PTR_W+1)'(ISB_PTR_W'(wptr_n - rptr_n)) + (ISB_PTR_W+1)'(pend_next && !flush))
                >= (ISB_PTR_W+1)'(ISB_N);
    end
  end

`ifndef SYNTHESIS
  always_ff @(posedge clk) if (rst_n && !flush) begin
    if (wakeup && !wk_hit && !wk_e2) assert (!early_q)
      else $error("[ISB] second early store wakeup while one is still unconsumed");
    if (alloc) assert (count != (ISB_IDX_W+1)'(ISB_N)) else $error("[ISB] alloc while full");
    if (cap) assert (e_vld[cap_idx]) else $error("[ISB] PA write into dead entry %0d", cap_idx);
    if (amo_wr) assert (e_vld[amo_wr_idx] && (e_kind[amo_wr_idx] == K_AMO))
      else $error("[ISB] AMO result into non-AMO entry %0d", amo_wr_idx);
  end
`endif
endmodule
