`timescale 1ns/1ps

module orbe_fe_mock_wrapper (
  orbe_fe_mock_if.dut fe_bus
);
  import orbe_fe_mock_pkg::*;

  string scenario;
  int unsigned scenario_cycle;
  int unsigned stall_cycles;
  int unsigned redirect_cycle;
  int unsigned second_redirect_cycle;
  logic [63:0] redirect_pc;
  logic [63:0] second_redirect_pc;
  logic [63:0] fetch_exception_pc;

  task automatic drive_ready(input logic lane0_ready, input logic lane1_ready);
    fe_bus.be_fe_instr_ready[0] = lane0_ready;
    fe_bus.be_fe_instr_ready[1] = lane1_ready;
  endtask

  task automatic drive_scenario_ready();
    if (scenario == "ready_all") begin
      drive_ready(1'b1, 1'b1);
    end else if (scenario == "stall_all") begin
      if (scenario_cycle < stall_cycles)
        drive_ready(1'b0, 1'b0);
      else
        drive_ready(1'b1, 1'b1);
    end else if (scenario == "stall_lane0") begin
      if (scenario_cycle < stall_cycles)
        drive_ready(1'b0, 1'b1);
      else
        drive_ready(1'b1, 1'b1);
    end else if (scenario == "lane0_only") begin
      if (scenario_cycle < stall_cycles)
        drive_ready(1'b1, 1'b0);
      else
        drive_ready(1'b1, 1'b1);
    end else if (scenario == "redirect_normal") begin
      drive_ready(1'b1, 1'b1);
    end else if (scenario == "redirect_under_stall") begin
      if (scenario_cycle <= redirect_cycle)
        drive_ready(1'b0, 1'b0);
      else
        drive_ready(1'b1, 1'b1);
    end else if (scenario == "redirect_same_cycle") begin
      drive_ready(1'b1, 1'b1);
    end else if (scenario == "redirect_twice") begin
      drive_ready(1'b1, 1'b1);
    end else if (scenario == "fetch_exception") begin
      drive_ready(1'b1, 1'b1);
    end else if (scenario == "fetch_exception_under_stall") begin
      if (scenario_cycle < (redirect_cycle + stall_cycles))
        drive_ready(1'b0, 1'b0);
      else
        drive_ready(1'b1, 1'b1);
    end else begin
      $fatal(1, "[ORBE_FE_MOCK_WRAPPER] unsupported MOCK_SCENARIO=%s", scenario);
    end
  endtask

  function automatic bit redirect_due();
    if ((scenario == "redirect_normal") ||
        (scenario == "redirect_under_stall") ||
        (scenario == "redirect_same_cycle") ||
        (scenario == "fetch_exception") ||
        (scenario == "fetch_exception_under_stall"))
      return scenario_cycle == redirect_cycle;
    if (scenario == "redirect_twice")
      return (scenario_cycle == redirect_cycle) || (scenario_cycle == second_redirect_cycle);
    return 1'b0;
  endfunction

  function automatic logic [63:0] redirect_pc_for_cycle();
    if ((scenario == "redirect_twice") && (scenario_cycle == second_redirect_cycle))
      return second_redirect_pc;
    return redirect_pc;
  endfunction

  initial begin
    scenario = "ready_all";
    stall_cycles = 4;
    redirect_cycle = 8;
    redirect_pc = 64'h0000_0000_8000_0050;
    second_redirect_cycle = 9;
    second_redirect_pc = 64'h0000_0000_8000_0070;
    fetch_exception_pc = 64'h0000_0000_8000_0001;
    scenario_cycle = 0;
    void'($value$plusargs("MOCK_SCENARIO=%s", scenario));
    void'($value$plusargs("MOCK_STALL_CYCLES=%d", stall_cycles));
    void'($value$plusargs("MOCK_REDIRECT_CYCLE=%d", redirect_cycle));
    void'($value$plusargs("MOCK_REDIRECT_PC=%h", redirect_pc));
    void'($value$plusargs("MOCK_FETCH_EXCEPTION_PC=%h", fetch_exception_pc));
    if ((scenario == "fetch_exception") ||
        (scenario == "fetch_exception_under_stall")) begin
      redirect_pc = fetch_exception_pc;
    end
    if (!$value$plusargs("MOCK_SECOND_REDIRECT_CYCLE=%d", second_redirect_cycle))
      second_redirect_cycle = redirect_cycle + 1;
    if (!$value$plusargs("MOCK_SECOND_REDIRECT_PC=%h", second_redirect_pc))
      second_redirect_pc = redirect_pc + 64'h20;
    if (stall_cycles == 0)
      $fatal(1, "[ORBE_FE_MOCK_WRAPPER] MOCK_STALL_CYCLES must be non-zero");
    if ((scenario == "redirect_twice") && (second_redirect_cycle <= redirect_cycle))
      $fatal(1, "[ORBE_FE_MOCK_WRAPPER] MOCK_SECOND_REDIRECT_CYCLE must be after MOCK_REDIRECT_CYCLE");

    fe_bus.be_fe_instr_ready = '0;
    fe_bus.be_fe_redirect_valid = 1'b0;
    fe_bus.be_fe_redirect_pld = '0;

    forever begin
      @(negedge fe_bus.clk);
      if (!fe_bus.rst_n) begin
        fe_bus.be_fe_instr_ready = '0;
        fe_bus.be_fe_redirect_valid = 1'b0;
        fe_bus.be_fe_redirect_pld = '0;
        scenario_cycle = 0;
      end else begin
        drive_scenario_ready();
        if (redirect_due()) begin
          fe_bus.be_fe_redirect_valid = 1'b1;
          fe_bus.be_fe_redirect_pld.redirect_pc = redirect_pc_for_cycle();
          fe_bus.be_fe_redirect_pld.interrupt_valid = 1'b0;
          fe_bus.be_fe_redirect_pld.trap_valid = 1'b0;
          $display("[ORBE_FE_MOCK_WRAPPER] %s cycle=%0d pc=0x%016h",
                   scenario, scenario_cycle, redirect_pc_for_cycle());
        end else begin
          fe_bus.be_fe_redirect_valid = 1'b0;
          fe_bus.be_fe_redirect_pld = '0;
        end
        scenario_cycle++;
      end
    end
  end
endmodule : orbe_fe_mock_wrapper
