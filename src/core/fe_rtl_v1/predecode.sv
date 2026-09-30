// PREDECODE: S2 early decode and instruction boundaries (the only one in FE), holds the only cross-line state register
module predecode
  import or_fe_pkg::*;
(
  input  logic                       clk,
  input  logic                       rst_n,
  // In-event
  input  logic                       line_hsk,
  input  logic                       xline_clear,
  // In Static Info
  input  logic [SLOT_NUM-1:0][15:0]  line_half,
  input  logic [VA_W-1:0]            line_pc,
  input  logic                       line_excp_vld,
  input  logic [CAUSE_W-1:0]         line_excp_cause,
  input  logic [VA_W-1:0]            dec_pc,
  // Out Static Info
  output logic                       xline_vld,
  output logic [15:0]                xline_half,
  output logic [SLOT_NUM-1:0]        dec_vld,
  output logic [SLOT_NUM-1:0]        dec_start,
  output bp_type_t [SLOT_NUM-1:0]    dec_type,
  output logic [SLOT_NUM-1:0][VA_W-1:0] dec_imm,
  output logic [SLOT_NUM-1:0][VA_W-1:0] dec_ipc,
  output logic [SLOT_NUM-1:0][VA_W-1:0] dec_ret_pc,
  output logic                       dec_excp_vld,
  output logic [CAUSE_W-1:0]         dec_excp_cause
);

  // ---------------- storage ----------------
  logic                          x_state_q;
  logic [15:0]                   xline_half_q;
  logic [SLOT_NUM-1:0]           dec_start_q;
  logic [SLOT_NUM-1:0]           dec_ivld_q;
  logic [SLOT_NUM-1:0]           dec_rvc_q;
  bp_type_t [SLOT_NUM-1:0]       dec_type_q;
  logic [SLOT_NUM-1:0][VA_W-1:0] dec_imm_q;
  logic                          dec_xused_q;
  logic                          dec_excp_vld_q;
  logic [CAUSE_W-1:0]            dec_excp_cause_q;

  assign xline_vld  = x_state_q;
  assign xline_half = xline_half_q;

  // ---------------- S2 early decode ----------------
  logic [SLOT_W-1:0]             first;
  logic [SLOT_NUM-1:0]           rvc;
  logic [SLOT_NUM-1:0]           len1;
  logic [SLOT_NUM-1:0]           start;
  logic [SLOT_NUM-1:0]           incomplete;
  logic [SLOT_NUM-1:0]           ivld;
  logic [SLOT_NUM-1:0][31:0]     win;
  logic [SLOT_NUM-1:0][31:0]     i32;
  bp_type_t [SLOT_NUM-1:0]       ptype;
  logic [SLOT_NUM-1:0][VA_W-1:0] pimm;
  logic                          cross_line;

  assign first = xline_vld ? '0 : slot_of(line_pc);

  always_comb begin
    for (int s = 0; s < SLOT_NUM; s++) begin
      rvc[s]  = ((s == 0) && xline_vld) ? 1'b0 : or_fe_pkg::is_rvc(line_half[s]);
      len1[s] = rvc[s] || ((s == 0) && xline_vld);
      if ((s == 0) && xline_vld) begin
        win[s] = {line_half[0], xline_half_q};
      end else if (s == SLOT_NUM - 1) begin
        win[s] = {16'h0, line_half[s]};
      end else begin
        win[s] = {line_half[(s+1)%SLOT_NUM], line_half[s]};
      end
      i32[s]   = rvc[s] ? rvc_expand(line_half[s]) : win[s];
      ptype[s] = bp_classify(i32[s]);
      pimm[s]  = bp_imm(i32[s]);
    end
  end

  // length chain: start[s]
  always_comb begin
    for (int s = 0; s < SLOT_NUM; s++) begin
      if (SLOT_W'(s) < first) begin
        start[s] = 1'b0;
      end else if (SLOT_W'(s) == first) begin
        start[s] = 1'b1;
      end else begin
        start[s] = ((s >= 1) && start[(s+SLOT_NUM-1)%SLOT_NUM] && len1[(s+SLOT_NUM-1)%SLOT_NUM]) ||
                   ((s >= 2) && start[(s+SLOT_NUM-2)%SLOT_NUM] && !len1[(s+SLOT_NUM-2)%SLOT_NUM]);
      end
      incomplete[s] = (s == SLOT_NUM - 1) && !len1[s];
      ivld[s]       = start[s] && !incomplete[s] && !line_excp_vld;
    end
  end

  assign cross_line = start[SLOT_NUM-1] & incomplete[SLOT_NUM-1] & ~line_excp_vld;

  // ---------------- events and storage update ----------------
  logic xline_set;
  logic xline_use;
  assign xline_set = line_hsk & cross_line & ~xline_clear;
  assign xline_use = line_hsk & ~cross_line & ~xline_clear;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      x_state_q <= 1'b0;
    end else if (xline_clear || xline_use) begin
      x_state_q <= 1'b0;
    end else if (xline_set) begin
      x_state_q <= 1'b1;
    end
  end

  always_ff @(posedge clk) begin
    if (xline_set) begin
      xline_half_q <= line_half[SLOT_NUM-1];
    end
    if (line_hsk) begin
      dec_start_q      <= start;
      dec_ivld_q       <= ivld;
      dec_rvc_q        <= rvc;
      dec_type_q       <= ptype;
      dec_imm_q        <= pimm;
      dec_xused_q      <= xline_vld;
      dec_excp_vld_q   <= line_excp_vld;
      dec_excp_cause_q <= line_excp_cause;
    end
  end

  // ---------------- S3 output ----------------
  always_comb begin
    for (int s = 0; s < SLOT_NUM; s++) begin
      dec_ipc[s]    = ((s == 0) && dec_xused_q) ? (line_base(dec_pc) - VA_W'(2)) : (line_base(dec_pc) + VA_W'(2 * s));
      dec_ret_pc[s] = dec_ipc[s] + (dec_rvc_q[s] ? VA_W'(2) : VA_W'(4));
    end
  end

  assign dec_vld      = dec_ivld_q;
  assign dec_start      = dec_start_q;
  assign dec_type       = dec_type_q;
  assign dec_imm        = dec_imm_q;
  assign dec_excp_vld   = dec_excp_vld_q;
  assign dec_excp_cause = dec_excp_cause_q;

endmodule
