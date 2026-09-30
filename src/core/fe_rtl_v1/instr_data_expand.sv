// INSTR_DATA_EXPAND: S2 pure combinational, expands each slot ahead of time, data wired directly to IB
// the only RVC expansion point in the whole pipeline (RVC expansion is done only in FE, BE does not expand), contains Operand_Extract
/* verilator lint_off VARHIDDEN */
module instr_data_expand
  import or_fe_pkg::*;
(
  input  logic [SLOT_NUM-1:0][15:0] half,
  input  logic                      xline_vld,
  input  logic [15:0]               xline_half,
  output logic [SLOT_NUM-1:0][31:0] inst,
  output logic [SLOT_NUM-1:0][31:0] raw,
  output logic [SLOT_NUM-1:0]       is_rvc,
  output logic [SLOT_NUM-1:0]       rvc_ill,
  output operand_info_t [SLOT_NUM-1:0] opnd
);

  logic [SLOT_NUM-1:0]       rvc;
  logic [SLOT_NUM-1:0][31:0] win;

  always_comb begin
    for (int s = 0; s < SLOT_NUM; s++) begin
      rvc[s] = ((s == 0) && xline_vld) ? 1'b0 : or_fe_pkg::is_rvc(half[s]);
      if ((s == 0) && xline_vld) begin
        win[s] = {half[0], xline_half};
      end else if (s == SLOT_NUM - 1) begin
        win[s] = {16'h0, half[s]};
      end else begin
        win[s] = {half[(s+1)%SLOT_NUM], half[s]};
      end
      inst[s]    = rvc[s] ? rvc_expand(half[s]) : win[s];
      raw[s]     = rvc[s] ? {16'h0, half[s]} : win[s];
      is_rvc[s]  = rvc[s];
      rvc_ill[s] = rvc[s] && rvc_illegal(half[s]);
      opnd[s]    = operand_extract(inst[s]);
    end
  end

endmodule
/* verilator lint_on VARHIDDEN */
