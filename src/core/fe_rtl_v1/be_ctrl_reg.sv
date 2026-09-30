// BE_CTRL_REG: Backend / CSR control-plane boundary, registered one cycle then distributed
module be_ctrl_reg
  import or_fe_pkg::*;
(
  input  logic                  clk,
  input  logic                  rst_n,
  // In-event
  input  logic                  be_redirect,
  input  logic [VA_W-1:0]       be_redirect_pc,
  input  logic                  be_commit_br,
  input  logic [VA_W-1:0]       be_commit_br_pc,
  input  logic                  be_commit_br_taken,
  input  logic [VA_W-1:0]       be_commit_br_target,
  input  bp_type_t              be_commit_br_type,
  input  logic [ISSUE_W-1:0]    be_commit,
  input  logic [ISSUE_W-1:0][VA_W-1:0] be_commit_pc,
  input  logic                  be_sfence,
  input  logic                  be_fence_i,
  // In Static Info
  input  logic                  sleep_req,
  input  logic                  csr_vm_en,
  input  priv_t                 csr_priv,
  input  logic [PMP_CFG_W-1:0]  csr_pmp_cfg,
  // Out-event
  output logic                  redirect,
  output logic [VA_W-1:0]       redirect_pc,
  output logic                  flush,
  output logic                  commit_br,
  output logic [VA_W-1:0]       commit_br_pc,
  output logic                  commit_br_taken,
  output logic [VA_W-1:0]       commit_br_target,
  output bp_type_t              commit_br_type,
  output logic [ISSUE_W-1:0]    commit,
  output logic [ISSUE_W-1:0][VA_W-1:0] commit_pc,
  output logic                  tlb_flush,
  output logic                  ic_inv,
  output logic                  sleep_flush,
  // Out Static Info
  output logic                  sleep_stall,
  output logic                  vm_en,
  output priv_t                 priv,
  output logic [PMP_CFG_W-1:0]  pmp_cfg
);

  // valid-type registers
  logic rdrt_vld_q, cbr_vld_q, sfence_q, fencei_q, sleep_q, sleep_d_q;
  logic [ISSUE_W-1:0] cmt_vld_q;
  // payload registers
  logic [VA_W-1:0]      rdrt_pc_q;
  logic [VA_W-1:0]      cbr_pc_q;
  logic                 cbr_taken_q;
  logic [VA_W-1:0]      cbr_target_q;
  bp_type_t             cbr_type_q;
  logic [ISSUE_W-1:0][VA_W-1:0] cmt_pc_q;
  logic                 vm_en_q;
  priv_t                priv_q;
  logic [PMP_CFG_W-1:0] pmp_cfg_q;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      rdrt_vld_q <= 1'b0;
      cbr_vld_q  <= 1'b0;
      cmt_vld_q  <= '0;
      sfence_q   <= 1'b0;
      fencei_q   <= 1'b0;
      sleep_q    <= 1'b0;
      sleep_d_q  <= 1'b0;
      vm_en_q    <= 1'b0;
      priv_q     <= PRV_M;
      pmp_cfg_q  <= '0;
    end else begin
      rdrt_vld_q <= be_redirect;
      cbr_vld_q  <= be_commit_br;
      cmt_vld_q  <= be_commit;
      sfence_q   <= be_sfence;
      fencei_q   <= be_fence_i;
      sleep_q    <= sleep_req;
      sleep_d_q  <= sleep_q;
      vm_en_q    <= csr_vm_en;
      priv_q     <= csr_priv;
      pmp_cfg_q  <= csr_pmp_cfg;
    end
  end

  always_ff @(posedge clk) begin
    if (be_redirect) begin
      rdrt_pc_q       <= be_redirect_pc;
    end
    if (be_commit_br) begin
      cbr_pc_q      <= be_commit_br_pc;
      cbr_taken_q   <= be_commit_br_taken;
      cbr_target_q  <= be_commit_br_target;
      cbr_type_q    <= be_commit_br_type;
    end
    for (int k = 0; k < ISSUE_W; k++) begin
      if (be_commit[k]) cmt_pc_q[k] <= be_commit_pc[k];
    end
  end

  assign redirect          = rdrt_vld_q;
  assign redirect_pc       = rdrt_pc_q;
  assign flush             = rdrt_vld_q;
  assign commit_br         = cbr_vld_q;
  assign commit_br_pc      = cbr_pc_q;
  assign commit_br_taken   = cbr_taken_q;
  assign commit_br_target  = cbr_target_q;
  assign commit_br_type    = cbr_type_q;
  assign commit            = cmt_vld_q;
  assign commit_pc         = cmt_pc_q;
  assign tlb_flush         = sfence_q;
  assign ic_inv            = fencei_q;
  assign sleep_flush       = sleep_q & ~sleep_d_q;
  assign sleep_stall       = sleep_q;
  assign vm_en             = vm_en_q;
  assign priv              = priv_q;
  assign pmp_cfg           = pmp_cfg_q;

endmodule
