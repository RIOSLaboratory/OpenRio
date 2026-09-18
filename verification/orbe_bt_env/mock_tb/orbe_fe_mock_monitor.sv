`timescale 1ns/1ps

module orbe_fe_mock_monitor (
  orbe_fe_mock_if.mon fe_bus,
  output logic [31:0] error_count,
  output logic [31:0] fire_count,
  output logic [31:0] redirect_count,
  output logic [31:0] exception_count
);
  import orbe_fe_mock_pkg::*;

  bit expected_pc_valid;
  logic [63:0] expected_pc;
  bit have_prev;
  bit redirect_waiting_for_first_valid;
  bit fault_stop_active;
  bit verbose_fire_log;
  logic [ORBE_FE_LANES-1:0] prev_valid;
  logic [ORBE_FE_LANES-1:0] prev_fire;
  orbe_fe_instr_pld_t prev_pld [ORBE_FE_LANES-1:0];
  logic [63:0] redirect_expected_pc;

  task automatic report_error(input string message);
    error_count++;
    $error("[ORBE_FE_MOCK_MON] %s", message);
  endtask

  function automatic bit payload_equal(
    input orbe_fe_instr_pld_t lhs,
    input orbe_fe_instr_pld_t rhs
  );
    return lhs.pc == rhs.pc &&
           lhs.inst_bits == rhs.inst_bits &&
           lhs.is_compressed == rhs.is_compressed &&
           lhs.pred_taken == rhs.pred_taken &&
           lhs.pred_target_pc == rhs.pred_target_pc &&
           lhs.fetch_excp_vld == rhs.fetch_excp_vld &&
           lhs.exception_cause == rhs.exception_cause &&
           lhs.exception_tval == rhs.exception_tval;
  endfunction

  task automatic check_payload(input int lane, input orbe_fe_instr_pld_t pld);
    if (pld.pred_taken !== 1'b0)
      report_error($sformatf("lane %0d pred_taken is not zero pc=0x%016h", lane, pld.pc));

    if (pld.fetch_excp_vld) begin
      if (pld.inst_bits !== 32'h0000_0013)
        report_error($sformatf("lane %0d exception placeholder mismatch pc=0x%016h inst=0x%08h",
                              lane, pld.pc, pld.inst_bits));
      if (pld.is_compressed !== 1'b0)
        report_error($sformatf("lane %0d exception marked compressed pc=0x%016h", lane, pld.pc));
      if (pld.pred_target_pc !== pld.pc)
        report_error($sformatf("lane %0d exception pred_target_pc mismatch pc=0x%016h target=0x%016h",
                              lane, pld.pc, pld.pred_target_pc));
      if ((pld.exception_cause !== 5'd0) &&
          (pld.exception_cause !== 5'd1) &&
          (pld.exception_cause !== 5'd12))
        report_error($sformatf("lane %0d unsupported fetch exception cause=%0d pc=0x%016h",
                              lane, pld.exception_cause, pld.pc));
      if ((pld.exception_tval !== pld.pc) &&
          (pld.exception_tval !== (pld.pc + 64'd2)))
        report_error($sformatf("lane %0d fetch exception tval mismatch pc=0x%016h tval=0x%016h",
                              lane, pld.pc, pld.exception_tval));
    end else begin
      if (pld.exception_cause !== 5'b0)
        report_error($sformatf("lane %0d normal entry exception_cause is not zero pc=0x%016h",
                              lane, pld.pc));
      if (pld.exception_tval !== 64'b0)
        report_error($sformatf("lane %0d normal entry exception_tval is not zero pc=0x%016h",
                              lane, pld.pc));

      if (pld.is_compressed) begin
      if (pld.inst_bits[31:16] !== 16'h0000)
        report_error($sformatf("lane %0d compressed upper bits not zero pc=0x%016h inst=0x%08h", lane, pld.pc, pld.inst_bits));
      if (pld.inst_bits[1:0] === 2'b11)
        report_error($sformatf("lane %0d marked compressed but low bits are 2'b11 pc=0x%016h inst=0x%08h", lane, pld.pc, pld.inst_bits));
      if (pld.pred_target_pc !== (pld.pc + 64'd2))
        report_error($sformatf("lane %0d compressed pred_target_pc mismatch pc=0x%016h target=0x%016h", lane, pld.pc, pld.pred_target_pc));
    end else begin
      if (pld.inst_bits[1:0] !== 2'b11)
        report_error($sformatf("lane %0d 32-bit instruction low bits not 2'b11 pc=0x%016h inst=0x%08h", lane, pld.pc, pld.inst_bits));
      if (pld.pred_target_pc !== (pld.pc + 64'd4))
        report_error($sformatf("lane %0d 32-bit pred_target_pc mismatch pc=0x%016h target=0x%016h", lane, pld.pc, pld.pred_target_pc));
      end
    end
  endtask

  task automatic record_fire(input int lane, input orbe_fe_instr_pld_t pld);
    if (fault_stop_active)
      report_error($sformatf("entry fired after fetch exception without redirect lane=%0d pc=0x%016h",
                            lane, pld.pc));
    check_payload(lane, pld);
    if (expected_pc_valid && (pld.pc !== expected_pc))
      report_error($sformatf("lane %0d pc mismatch expected=0x%016h actual=0x%016h", lane, expected_pc, pld.pc));
    expected_pc = pld.pred_target_pc;
    expected_pc_valid = 1'b1;
    fire_count++;
    if (pld.fetch_excp_vld) begin
      exception_count++;
      fault_stop_active = 1'b1;
    end
    if (verbose_fire_log) begin
      $display("[ORBE_FE_MOCK_MON] fire[%0d] pc=0x%016h inst=0x%08h compressed=%0d target=0x%016h excp=%0d cause=%0d tval=0x%016h",
               lane, pld.pc, pld.inst_bits, pld.is_compressed, pld.pred_target_pc,
               pld.fetch_excp_vld, pld.exception_cause, pld.exception_tval);
    end
  endtask

  task automatic check_stability_and_compaction();
    if (!have_prev)
      return;

    if (prev_valid[0] && !prev_fire[0]) begin
      if (!fe_bus.fe_be_instr_valid[0]) begin
        report_error("lane 0 stalled entry disappeared");
      end else if (!payload_equal(prev_pld[0], fe_bus.fe_be_instr_pld[0])) begin
        report_error($sformatf("lane 0 stalled payload changed prev_pc=0x%016h current_pc=0x%016h",
                               prev_pld[0].pc, fe_bus.fe_be_instr_pld[0].pc));
      end

      if (prev_valid[1]) begin
        if (!fe_bus.fe_be_instr_valid[1]) begin
          report_error("lane 1 entry disappeared while lane 0 was stalled");
        end else if (!payload_equal(prev_pld[1], fe_bus.fe_be_instr_pld[1])) begin
          report_error($sformatf("lane 1 payload changed while lane 0 was stalled prev_pc=0x%016h current_pc=0x%016h",
                                 prev_pld[1].pc, fe_bus.fe_be_instr_pld[1].pc));
        end
      end
    end

    if (prev_valid[1] && prev_fire[0] && !prev_fire[1]) begin
      if (!fe_bus.fe_be_instr_valid[0]) begin
        report_error("lane 1 unfired entry did not compact to lane 0");
      end else if (!payload_equal(prev_pld[1], fe_bus.fe_be_instr_pld[0])) begin
        report_error($sformatf("compacted lane 1 payload mismatch prev_lane1_pc=0x%016h current_lane0_pc=0x%016h",
                               prev_pld[1].pc, fe_bus.fe_be_instr_pld[0].pc));
      end
    end
  endtask

  task automatic update_previous(input logic [ORBE_FE_LANES-1:0] fire);
    have_prev = 1'b1;
    prev_valid = fe_bus.fe_be_instr_valid;
    prev_fire = fire;
    for (int lane = 0; lane < ORBE_FE_LANES; lane++)
      prev_pld[lane] = fe_bus.fe_be_instr_pld[lane];
  endtask

  task automatic check_cycle();
    logic [ORBE_FE_LANES-1:0] fire;

    if (!fe_bus.rst_n) begin
      if (fe_bus.fe_be_instr_valid !== '0)
        report_error("reset asserted while fe_be_instr_valid is non-zero");
      expected_pc_valid = 1'b0;
      have_prev = 1'b0;
      redirect_waiting_for_first_valid = 1'b0;
      fault_stop_active = 1'b0;
      redirect_count = '0;
      return;
    end

    if (fe_bus.be_fe_redirect_valid) begin
      redirect_count++;
      redirect_waiting_for_first_valid = 1'b1;
      redirect_expected_pc = fe_bus.be_fe_redirect_pld.redirect_pc;
      $display("[ORBE_FE_MOCK_MON] redirect pc=0x%016h", redirect_expected_pc);
      expected_pc_valid = 1'b0;
      fault_stop_active = 1'b0;
      have_prev = 1'b0;
      return;
    end

    if (redirect_waiting_for_first_valid && fe_bus.fe_be_instr_valid[0]) begin
      if (fe_bus.fe_be_instr_pld[0].pc !== redirect_expected_pc)
        report_error($sformatf("redirect first lane0 pc mismatch expected=0x%016h actual=0x%016h",
                               redirect_expected_pc, fe_bus.fe_be_instr_pld[0].pc));
      expected_pc = fe_bus.fe_be_instr_pld[0].pc;
      expected_pc_valid = 1'b1;
      redirect_waiting_for_first_valid = 1'b0;
    end

    if (fe_bus.fe_be_instr_valid[1] && !fe_bus.fe_be_instr_valid[0])
      report_error("lane 1 valid while lane 0 is invalid");

    fire[0] = fe_bus.fe_be_instr_valid[0] && fe_bus.be_fe_instr_ready[0];
    fire[1] = fe_bus.fe_be_instr_valid[1] && fe_bus.be_fe_instr_ready[1] && fire[0];

    check_stability_and_compaction();

    if (fire[0])
      record_fire(0, fe_bus.fe_be_instr_pld[0]);
    if (fire[1])
      record_fire(1, fe_bus.fe_be_instr_pld[1]);

    update_previous(fire);
  endtask

  initial begin
    int unsigned verbose_fire_arg;

    verbose_fire_arg = 0;
    void'($value$plusargs("MOCK_VERBOSE_FIRE=%d", verbose_fire_arg));
    verbose_fire_log = verbose_fire_arg != 0;
    error_count = '0;
    fire_count = '0;
    redirect_count = '0;
    exception_count = '0;
    expected_pc_valid = 1'b0;
    expected_pc = '0;
    have_prev = 1'b0;
    redirect_waiting_for_first_valid = 1'b0;
    fault_stop_active = 1'b0;
    redirect_expected_pc = '0;
    prev_valid = '0;
    prev_fire = '0;
    prev_pld = '{default:'0};

    forever begin
      @(posedge fe_bus.clk);
      #2;
      check_cycle();
    end
  end
endmodule : orbe_fe_mock_monitor
