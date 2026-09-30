// DIRECT_JUMP: S3 pure combinational, direct control-flow candidate targets
module direct_jump
  import or_fe_pkg::*;
(
  input  logic [SLOT_NUM-1:0]           valid,
  input  bp_type_t [SLOT_NUM-1:0]       btype,
  input  logic [SLOT_NUM-1:0][VA_W-1:0] ipc,
  input  logic [SLOT_NUM-1:0][VA_W-1:0] imm,
  output logic [SLOT_NUM-1:0]           cand_vld,
  output logic [SLOT_NUM-1:0][VA_W-1:0] cand_target
);

  always_comb begin
    for (int s = 0; s < SLOT_NUM; s++) begin
      cand_vld[s]    = valid[s] && ((btype[s] == BP_BR) || (btype[s] == BP_JUMP) || (btype[s] == BP_FCALL));
      cand_target[s] = ipc[s] + (imm[s] << 1);
    end
  end

endmodule
