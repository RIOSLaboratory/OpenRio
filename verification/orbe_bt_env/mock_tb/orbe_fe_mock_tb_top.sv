`timescale 1ns/1ps

module orbe_fe_mock_tb_top;
  import orbe_fe_mock_pkg::*;

  localparam time CLOCK_PERIOD = 10ns;

  logic clk = 1'b0;
  logic rst_n = 1'b0;
  int unsigned timeout_cycles;
  int unsigned min_fire_count;
  string scenario;
  logic [31:0] monitor_error_count;
  logic [31:0] monitor_fire_count;
  logic [31:0] monitor_redirect_count;
  logic [31:0] monitor_exception_count;
  int unsigned expected_redirect_count;
  int unsigned expected_exception_count;

  task automatic print_result_summary(input string verdict);
    $display("[ORBE_FE_MOCK_RESULT] %s scenario=%s fires=%0d min_fires=%0d redirects=%0d expected_redirects=%0d exceptions=%0d expected_exceptions=%0d errors=%0d timeout_cycles=%0d",
             verdict,
             scenario,
             monitor_fire_count,
             min_fire_count,
             monitor_redirect_count,
             expected_redirect_count,
             monitor_exception_count,
             expected_exception_count,
             monitor_error_count,
             timeout_cycles);
  endtask

  orbe_fe_mock_if fe_bus(.clk(clk), .rst_n(rst_n));

  orbe_fe_mock_fe_agent fe_agent(
    .fe_bus(fe_bus)
  );

  orbe_fe_mock_wrapper wrapper(
    .fe_bus(fe_bus)
  );

  orbe_fe_mock_monitor monitor(
    .fe_bus(fe_bus),
    .error_count(monitor_error_count),
    .fire_count(monitor_fire_count),
    .redirect_count(monitor_redirect_count),
    .exception_count(monitor_exception_count)
  );

  initial begin
    forever #(CLOCK_PERIOD / 2) clk = ~clk;
  end

  initial begin
    timeout_cycles = 100;
    min_fire_count = 8;
    scenario = "ready_all";
    void'($value$plusargs("MOCK_TIMEOUT_CYCLES=%d", timeout_cycles));
    void'($value$plusargs("MOCK_MIN_FIRE_COUNT=%d", min_fire_count));
    void'($value$plusargs("MOCK_SCENARIO=%s", scenario));
    if (scenario == "redirect_twice")
      expected_redirect_count = 2;
    else if ((scenario == "redirect_normal") ||
             (scenario == "redirect_under_stall") ||
             (scenario == "redirect_same_cycle") ||
             (scenario == "fetch_exception") ||
             (scenario == "fetch_exception_under_stall"))
      expected_redirect_count = 1;
    else
      expected_redirect_count = 0;
    if ((scenario == "fetch_exception") ||
        (scenario == "fetch_exception_under_stall"))
      expected_exception_count = 1;
    else
      expected_exception_count = 0;
    if (timeout_cycles == 0)
      $fatal(1, "[ORBE_FE_MOCK_TOP] MOCK_TIMEOUT_CYCLES must be non-zero");
    if (min_fire_count == 0)
      $fatal(1, "[ORBE_FE_MOCK_TOP] MOCK_MIN_FIRE_COUNT must be non-zero");

    fe_bus.fe_be_instr_valid = '0;
    fe_bus.fe_be_instr_pld = '{default:'0};
    rst_n = 1'b0;

    repeat (4) @(posedge clk);
    rst_n = 1'b1;
    repeat (timeout_cycles) @(posedge clk);
    #3;

    if (monitor_error_count != 0) begin
      print_result_summary("FAIL");
      $fatal(1, "[ORBE_FE_MOCK_TOP] FAIL: monitor_error_count=%0d fire_count=%0d",
             monitor_error_count, monitor_fire_count);
    end
    if (monitor_fire_count < min_fire_count) begin
      print_result_summary("FAIL");
      $fatal(1, "[ORBE_FE_MOCK_TOP] FAIL: fire_count=%0d below required %0d",
             monitor_fire_count, min_fire_count);
    end
    if (monitor_redirect_count != expected_redirect_count) begin
      print_result_summary("FAIL");
      $fatal(1, "[ORBE_FE_MOCK_TOP] FAIL: redirect_count=%0d expected=%0d",
             monitor_redirect_count, expected_redirect_count);
    end
    if (monitor_exception_count != expected_exception_count) begin
      print_result_summary("FAIL");
      $fatal(1, "[ORBE_FE_MOCK_TOP] FAIL: exception_count=%0d expected=%0d",
             monitor_exception_count, expected_exception_count);
    end

    print_result_summary("PASS");
    $finish;
  end

  initial begin
    string wave_file;
    if ($value$plusargs("WAVE_FILE=%s", wave_file)) begin
      $dumpfile(wave_file);
      $dumpvars(0, orbe_fe_mock_tb_top);
    end
  end
endmodule : orbe_fe_mock_tb_top
