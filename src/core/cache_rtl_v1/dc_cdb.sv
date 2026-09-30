// OR_CACHE_CDB: terminal-state FIFO, presentation to BE, bypass
//   enqueue sources (same cycle, in this order): E3 exception / FENCE terminal state, Load Data Arbiter two paths, ISB commit
module dc_cdb
  import or_be_lsu_protocol_pkg::*;
  import or_cache_pkg::*;
(
  input  logic                  clk,
  input  logic                  rst_n,
  input  logic                  flush,
  input  logic                  a_vld,          // E3 exception / FENCE
  input  cdb_ent_t              a_ent,
  input  logic                  l_vld [2],      // Load Data Arbiter
  input  cdb_ent_t              l_ent [2],
  input  logic                  b_vld,          // ISB commit
  input  cdb_ent_t              b_ent,
  input  logic                  entry_ready,
  output logic                  done_valid_q,
  output lsu_be_done_pld_t      done_pld,
  output logic                  exc_valid_q,
  output lsu_be_exception_pld_t exc_pld,
  output logic                  byp_valid_q,
  output lsu_be_done_pld_t      byp_pld,
  // presentation accepted
  output logic                  acc,
  output cdb_ent_t              acc_ent
);
  cdb_ent_t             q [CDB_N];
  logic [CDB_PTR_W-1:0] rptr_q, wptr_q;
  logic                 hv;
  cdb_ent_t             h;

  assign hv = (rptr_q != wptr_q);
  assign h  = q[rptr_q[CDB_PTR_W-2:0]];

  assign done_valid_q  = hv && !h.is_exc;
  assign exc_valid_q   = hv &&  h.is_exc;
  assign byp_valid_q   = hv && !h.is_exc && h.bypass;
  assign done_pld.tag  = h.tag;
  assign done_pld.data = h.is_exc ? '0 : h.data;
  assign exc_pld.tag   = h.tag;
  assign exc_pld.cause = h.cause;
  assign exc_pld.tval  = h.is_exc ? h.data : '0;
  assign byp_pld.tag   = h.tag;
  assign byp_pld.data  = h.data;

  assign acc     = hv && entry_ready && !flush;
  assign acc_ent = h;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      rptr_q <= '0; wptr_q <= '0;
      for (int i = 0; i < CDB_N; i++) q[i] <= '0;
    end else if (flush) begin
      rptr_q <= '0; wptr_q <= '0;
    end else begin
      logic [CDB_PTR_W-1:0] wp;
      wp = wptr_q;
      if (a_vld)    begin q[wp[CDB_PTR_W-2:0]] <= a_ent;    wp = wp + 1'b1; end
      if (l_vld[0]) begin q[wp[CDB_PTR_W-2:0]] <= l_ent[0]; wp = wp + 1'b1; end
      if (l_vld[1]) begin q[wp[CDB_PTR_W-2:0]] <= l_ent[1]; wp = wp + 1'b1; end
      if (b_vld)    begin q[wp[CDB_PTR_W-2:0]] <= b_ent;    wp = wp + 1'b1; end
      wptr_q <= wp;
      if (acc) rptr_q <= rptr_q + 1'b1;
    end
  end

`ifndef SYNTHESIS
  always_ff @(posedge clk) if (rst_n && !flush) begin
    assert (32'(CDB_PTR_W'(wptr_q - rptr_q)) + 32'(a_vld) + 32'(l_vld[0]) + 32'(l_vld[1]) + 32'(b_vld) <= CDB_N + 32'(acc))
      else $error("[CDB] overflow");
  end
`endif
endmodule
