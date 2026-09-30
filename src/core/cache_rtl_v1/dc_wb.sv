// OR_CACHE_L1_WRITE_BUFFER: per-line L1 write path
//   entry = line address + full line data + byte mask; same-line merge, line addresses unique within WB
//   accepts: refill install commanded by MSHR (DPB line, may absorb store bytes committed in the same cycle), store bytes committed by ISB
//   write-out: head writes D cache once per cycle (store entry writes by mask to the known way; install entry has L1D pick the victim, reports inst_wr to MSHR in the write-out cycle)
//   forwarding: match by PA line address, supply data per byte
//   no miss decision, no requests to MSHR
module dc_wb
  import or_cache_pkg::*;
(
  input  logic                    clk,
  input  logic                    rst_n,
  // install (MSHR command + DPB data)
  input  logic                    inst_req,
  input  logic [MSHR_ID_W-1:0]    inst_id,
  input  logic [LINE_ADDR_W-1:0]  inst_line,
  input  logic [LINE_W-1:0]       inst_data,
  output logic                    inst_ack,
  output logic                    inst_wr,        // head install entry written into D cache this cycle
  output logic [MSHR_ID_W-1:0]    inst_wr_id,
  // ISB commit (each part of store / SC / AMO)
  input  logic [1:0]              st_n,
  input  st_part_t                st_p    [2],
  output logic                    st_has  [2],    // WB already has a same-line entry (including the head being written out this cycle)
  output logic                    st_ok,          // can accept this cycle
  input  logic                    st_fire,
  // L1D write port
  output logic                    wr_en,
  output logic                    wr_install,
  output logic [IDX_W-1:0]        wr_set,
  output logic [WAY_W-1:0]        wr_way,
  output logic [DC_TAG_W-1:0]     wr_tag,
  output logic [LINE_W-1:0]       wr_data,
  output logic [LINE_BYTES-1:0]   wr_be,
  output logic                    wr_dirty,
  output logic [DC_WAYS-1:0]      wr_excl,
  // forwarding (sampled in E3)
  input  logic [LINE_ADDR_W-1:0]  fw_line,
  input  logic [OFF_W-1:0]        fw_off,
  input  logic [3:0]              fw_plen,
  output logic [7:0]              fw_mask,
  output logic [63:0]             fw_data,
  output logic [WB_PTR_W-1:0]     cnt
);
  localparam int WB_IDX_W = WB_PTR_W - 1;

  logic [LINE_ADDR_W-1:0] e_line  [WB_N];
  logic [LINE_W-1:0]      e_data  [WB_N];
  logic [LINE_BYTES-1:0]  e_mask  [WB_N];
  logic                   e_inst  [WB_N];
  logic [WAY_W-1:0]       e_way   [WB_N];
  logic                   e_dirty [WB_N];
  logic [MSHR_ID_W-1:0]   e_mid   [WB_N];   // MSHR owning the install entry
  logic [WB_PTR_W-1:0]    rptr_q, wptr_q;

  logic [WB_PTR_W-1:0] free;
  logic                hv;
  logic [WB_IDX_W-1:0] h;
  assign cnt  = wptr_q - rptr_q;
  assign free = WB_PTR_W'(WB_N) - cnt;
  assign hv   = (cnt != '0);
  assign h    = rptr_q[WB_IDX_W-1:0];

  /* verilator lint_off UNUSEDSIGNAL */   // k < WB_N, only low bits used
  function automatic logic [WB_IDX_W-1:0] fidx(input logic [WB_PTR_W-1:0] p, input int k);
    logic [WB_PTR_W-1:0] s;
    s = p + WB_PTR_W'(k);
    return s[WB_IDX_W-1:0];
  endfunction
  /* verilator lint_on UNUSEDSIGNAL */

  // place the part's bytes at their in-line position
  /* verilator lint_off UNUSEDSIGNAL */   // only off / plen / data used
  function automatic void place(input st_part_t sp, inout logic [LINE_W-1:0] d, inout logic [LINE_BYTES-1:0] m);
    for (int j = 0; j < 8; j++)
      if (4'(j) < sp.plen) begin
        d[8*(int'(sp.off) + j) +: 8] = sp.data[8*j +: 8];
        m[int'(sp.off) + j]          = 1'b1;
      end
  endfunction
  /* verilator lint_on UNUSEDSIGNAL */

  // ---------------------------------------------------------------- write-out: head writes once per cycle
  // verification hook (simulation only, absent when integration regression uses -DSYNTHESIS): +WB_STALL=<percent> randomly pauses write-out, building WB backlog to cover same-line merge and full backpressure
  logic dbg_hold_q;
`ifndef SYNTHESIS
  int dbg_stall_pct;
  initial if (!$value$plusargs("WB_STALL=%d", dbg_stall_pct)) dbg_stall_pct = 0;
  always_ff @(posedge clk) dbg_hold_q <= (dbg_stall_pct != 0) && ($urandom_range(0, 99) < dbg_stall_pct);
`else
  assign dbg_hold_q = 1'b0;
`endif

  always_comb begin
    wr_en      = hv && !dbg_hold_q;
    wr_install = e_inst[h];
    wr_set     = e_line[h][IDX_W-1:0];
    wr_tag     = e_line[h][LINE_ADDR_W-1:IDX_W];
    wr_way     = e_way[h];
    wr_data    = e_data[h];
    wr_be      = e_mask[h];
    wr_dirty   = e_dirty[h];
    inst_wr    = wr_en && e_inst[h];
    inst_wr_id = e_mid[h];
    wr_excl    = '0;
    for (int k = 1; k < WB_N; k++) begin     // ways of other store entries in the same set must not be replaced
      logic [WB_IDX_W-1:0] i;
      i = fidx(rptr_q, k);
      if ((WB_PTR_W'(k) < cnt) && !e_inst[i] && (e_line[i][IDX_W-1:0] == wr_set)) wr_excl[e_way[i]] = 1'b1;
    end
  end

  // ---------------------------------------------------------------- accept
  assign inst_ack = inst_req && (free != '0);

  logic                m_inst [2];     // merge into this cycle's install entry
  logic                m_ent  [2];     // merge into an existing entry
  logic [WB_IDX_W-1:0] m_idx  [2];
  logic                m_ret  [2];     // that existing entry is being written out this cycle
  logic                p_new  [2];
  logic                p_ok   [2];
  always_comb begin
    logic [WB_PTR_W-1:0] need;
    logic [WB_IDX_W-1:0] i;
    need = WB_PTR_W'(inst_ack);
    st_ok = 1'b1;
    i = '0;
    for (int p = 0; p < 2; p++) begin
      st_has[p] = 1'b0;
      m_inst[p] = 1'b0; m_ent[p] = 1'b0; m_idx[p] = '0; m_ret[p] = 1'b0; p_new[p] = 1'b0; p_ok[p] = 1'b1;
      if (2'(p) < st_n) begin
        m_inst[p] = inst_ack && (inst_line == st_p[p].line);
        for (int k = 0; k < WB_N; k++) begin
          i = fidx(rptr_q, k);
          if ((WB_PTR_W'(k) < cnt) && (e_line[i] == st_p[p].line)) begin
            m_ent[p] = 1'b1; m_idx[p] = i; m_ret[p] = (k == 0) && wr_en;
          end
        end
        p_new[p] = !m_inst[p] && !m_ent[p] && st_p[p].hit;
        // do not merge into an entry being written out; a new entry with way requires no install write to this set (avoid replacement by this cycle's victim)
        p_ok[p]  = m_inst[p] || (m_ent[p] && !m_ret[p]) ||
                   (p_new[p] && !(wr_en && wr_install && (wr_set == st_p[p].line[IDX_W-1:0])));
        need = need + WB_PTR_W'(p_new[p]);
        st_ok = st_ok && p_ok[p];
      end
      st_has[p] = m_ent[p];
    end
    st_ok = st_ok && (need <= free);
  end

  // ---------------------------------------------------------------- forwarding (line addresses unique, at most one match)
  always_comb begin
    fw_mask = '0; fw_data = '0;
    for (int k = 0; k < WB_N; k++) begin
      logic [WB_IDX_W-1:0] i;
      i = fidx(rptr_q, k);
      if ((WB_PTR_W'(k) < cnt) && (e_line[i] == fw_line))
        for (int b = 0; b < 8; b++)
          if (4'(b) < fw_plen) begin
            fw_mask[b]        = e_mask[i][int'(fw_off) + b];
            fw_data[8*b +: 8] = e_data[i][8*(int'(fw_off) + b) +: 8];
          end
    end
  end

  // ---------------------------------------------------------------- sequential
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      rptr_q <= '0; wptr_q <= '0;
      for (int i = 0; i < WB_N; i++) begin
        e_line[i] <= '0; e_data[i] <= '0; e_mask[i] <= '0; e_inst[i] <= 1'b0; e_way[i] <= '0; e_dirty[i] <= 1'b0;
        e_mid[i] <= '0;
      end
    end else begin
      logic [WB_PTR_W-1:0] wp;
      wp = wptr_q;
      if (inst_ack) begin
        logic [LINE_W-1:0]     d;
        /* verilator lint_off UNUSEDSIGNAL */   // install entry mask is always all 1s
        logic [LINE_BYTES-1:0] m;
        /* verilator lint_on UNUSEDSIGNAL */
        logic                  dirty;
        d = inst_data; m = '1; dirty = 1'b0;
        for (int p = 0; p < 2; p++)
          if (st_fire && m_inst[p]) begin place(st_p[p], d, m); dirty = 1'b1; end
        e_line[wp[WB_IDX_W-1:0]]  <= inst_line;
        e_data[wp[WB_IDX_W-1:0]]  <= d;
        e_mask[wp[WB_IDX_W-1:0]]  <= '1;
        e_inst[wp[WB_IDX_W-1:0]]  <= 1'b1;
        e_way[wp[WB_IDX_W-1:0]]   <= '0;
        e_dirty[wp[WB_IDX_W-1:0]] <= dirty;
        e_mid[wp[WB_IDX_W-1:0]]   <= inst_id;
        wp = wp + 1'b1;
      end
      if (st_fire)
        for (int p = 0; p < 2; p++) begin
          if (m_ent[p]) begin
            logic [LINE_W-1:0]     d;
            logic [LINE_BYTES-1:0] m;
            d = e_data[m_idx[p]]; m = e_mask[m_idx[p]];
            place(st_p[p], d, m);
            e_data[m_idx[p]]  <= d;
            e_mask[m_idx[p]]  <= m;
            e_dirty[m_idx[p]] <= 1'b1;
          end else if (p_new[p]) begin
            logic [LINE_W-1:0]     d;
            logic [LINE_BYTES-1:0] m;
            d = '0; m = '0;
            place(st_p[p], d, m);
            e_line[wp[WB_IDX_W-1:0]]  <= st_p[p].line;
            e_data[wp[WB_IDX_W-1:0]]  <= d;
            e_mask[wp[WB_IDX_W-1:0]]  <= m;
            e_inst[wp[WB_IDX_W-1:0]]  <= 1'b0;
            e_way[wp[WB_IDX_W-1:0]]   <= st_p[p].way;
            e_dirty[wp[WB_IDX_W-1:0]] <= 1'b1;
            wp = wp + 1'b1;
          end
        end
      wptr_q <= wp;
      if (wr_en) rptr_q <= rptr_q + 1'b1;
    end
  end

`ifndef SYNTHESIS
  always_ff @(posedge clk) if (rst_n) begin
    if (st_fire) assert (st_ok) else $error("[WB] store accepted while not ready");
    if (inst_ack)
      for (int k = 0; k < WB_N; k++)
        if (WB_PTR_W'(k) < cnt) assert (e_line[fidx(rptr_q, k)] != inst_line)
          else $error("[WB] install of a line already in WB");
    for (int a = 0; a < WB_N; a++)
      for (int b = a + 1; b < WB_N; b++)
        if ((WB_PTR_W'(a) < cnt) && (WB_PTR_W'(b) < cnt))
          assert (e_line[fidx(rptr_q, a)] != e_line[fidx(rptr_q, b)]) else $error("[WB] duplicate line");
  end
`endif
endmodule
