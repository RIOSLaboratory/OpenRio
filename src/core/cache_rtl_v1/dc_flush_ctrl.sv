// OR_CACHE_FLUSH_CTRL: flush fan-out and DTLB invalidation
module dc_flush_ctrl (
  input  logic        clk,
  input  logic        rst_n,
  input  logic        global_flush,
  input  logic [63:0] csr_satp,
  input  logic [1:0]  csr_priv,
  input  logic        csr_sum,
  input  logic        csr_mxr,
  input  logic        sfence_vma,
  output logic        flush,
  output logic        inval_now,
  output logic        vm_en
);
  logic [67:0] ctx, snap_q;
  assign ctx       = {csr_satp, csr_priv, csr_sum, csr_mxr};
  assign flush     = global_flush;
  assign inval_now = sfence_vma || (ctx != snap_q);
  assign vm_en     = (csr_satp[63:60] == 4'd8) && (csr_priv != 2'd3);

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) snap_q <= '0;
    else        snap_q <= ctx;
  end
endmodule
