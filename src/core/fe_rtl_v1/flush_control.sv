// FLUSH_CONTROL: pure combinational, error events -> per-stage kill and per-module flush
module flush_control
  import or_fe_pkg::*;
(
  // In-event
  input  logic                  l1btb_redirect,
  input  logic                  prechk_redirect,
  input  logic                  be_flush,
  input  logic                  sleep_flush,
  // Out-event
  output logic                  pcgen_ic_kill,
  output logic                  ic_predcd_kill,
  output logic                  predcd_prechk_kill,
  output logic                  ifu_flush,
  output logic                  xline_clear,
  output logic                  ib_enq_flush,
  output logic                  ras_recover
);

  assign predcd_prechk_kill     = be_flush | sleep_flush;
  assign ic_predcd_kill     = prechk_redirect | predcd_prechk_kill;
  assign pcgen_ic_kill     = l1btb_redirect | ic_predcd_kill;
  assign ifu_flush   = pcgen_ic_kill;
  assign xline_clear = pcgen_ic_kill;
  assign ib_enq_flush    = predcd_prechk_kill;
  assign ras_recover = predcd_prechk_kill;

endmodule
