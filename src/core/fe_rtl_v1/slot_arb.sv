// SLOT_ARB: pick the earliest redirect in slot order
module slot_arb
  import or_fe_pkg::*;
(
  input  logic [SLOT_NUM-1:0]           need,
  input  logic [SLOT_NUM-1:0][VA_W-1:0] target,
  output logic                          win_vld,
  output logic [SLOT_W-1:0]             win_slot,
  output logic [VA_W-1:0]               win_target
);

  assign win_vld = |need;

  always_comb begin
    win_slot = '0;
    for (int s = SLOT_NUM - 1; s >= 0; s--) begin
      if (need[s]) win_slot = SLOT_W'(s);
    end
  end

  assign win_target = target[win_slot];

endmodule
