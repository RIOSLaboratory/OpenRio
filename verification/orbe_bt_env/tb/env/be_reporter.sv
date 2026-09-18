class be_reporter;
  localparam int unsigned TIME_FIELD_WIDTH = 12;
  string name;
  int unsigned verbosity;
  int unsigned error_fatal_threshold;
  bit enabled;

  // One aggregate counter set is shared by the whole testbench.
  static longint unsigned l1_count;
  static longint unsigned l2_count;
  static longint unsigned l3_count;
  static longint unsigned warning_count;
  static longint unsigned error_count;
  static longint unsigned fatal_count;

  function new(string name = "BE", int unsigned verbosity = 1);
    reset_counts();
    this.name = name;
    this.verbosity = verbosity;
    error_fatal_threshold = 0;
    enabled = 1'b1;
  endfunction

  static function void reset_counts();
    l1_count = 0;
    l2_count = 0;
    l3_count = 0;
    warning_count = 0;
    error_count = 0;
    fatal_count = 0;
  endfunction

  function void configure(int unsigned verbosity, bit enabled = 1'b1,
                          int unsigned error_fatal_threshold = 0);
    if ((verbosity < 1) || (verbosity > 3)) begin
      fatal_count++;
      $fatal(1, "Reporter verbosity must be 1, 2, or 3; got %0d", verbosity);
    end
    this.verbosity = verbosity;
    this.enabled = enabled;
    this.error_fatal_threshold = error_fatal_threshold;
  endfunction

  function bit level_enabled(int unsigned level);
    if ((level < 1) || (level > 3)) begin
      error($sformatf("Reporter level must be 1, 2, or 3; got %0d", level));
      return 1'b0;
    end
    return enabled && (level <= verbosity);
  endfunction

  static function string formatted_time();
    string time_text;

    time_text = $sformatf("%0t", $time);
    while (time_text.len() < TIME_FIELD_WIDTH)
      time_text = {"0", time_text};
    return time_text;
  endfunction

  function void print(int unsigned level, string message);
    if ((message.len() >= 8) && (message.substr(0, 7) == "[BE_TB] "))
      message = message.substr(8, message.len() - 1);
    case (level)
      1: l1_count++;
      2: l2_count++;
      3: l3_count++;
      default: ;
    endcase
    if (level_enabled(level))
      $display("[%s] [%s] [L%0d] %s", formatted_time(), name, level, message);
  endfunction

  function void warning(string message);
    warning_count++;
    $warning("[%s] [%s] %s", formatted_time(), name, message);
  endfunction

  // Non-terminating diagnostic output.  This is used when a mismatch report
  // must emit more than one line before the simulator handles the error.
  function void diagnostic(string message);
    if ((message.len() >= 8) && (message.substr(0, 7) == "[BE_TB] "))
      message = message.substr(8, message.len() - 1);
    $display("[%s] [%s] %s", formatted_time(), name, message);
  endfunction

  // Emit the first line without triggering Verilator's immediate $error stop,
  // then make the second line the terminal assertion/error line.
  function void mismatch_pair(string first_line, string second_line);
    if ((first_line.len() >= 8) && (first_line.substr(0, 7) == "[BE_TB] "))
      first_line = first_line.substr(8, first_line.len() - 1);
    if ((second_line.len() >= 8) && (second_line.substr(0, 7) == "[BE_TB] "))
      second_line = second_line.substr(8, second_line.len() - 1);
    error_count++;
    diagnostic(first_line);
    $display("[%s] [%s] %s", formatted_time(), name, second_line);
    if ((error_fatal_threshold != 0) && (error_count >= error_fatal_threshold))
      fatal($sformatf("[ERROR_LIMIT] error_count=%0d reached limit=%0d",
                      error_count, error_fatal_threshold));
  endfunction

  function void error(string message);
    error_count++;
    $error("[%s] [%s] %s", formatted_time(), name, message);
    if ((error_fatal_threshold != 0) && (error_count >= error_fatal_threshold))
      fatal($sformatf("[ERROR_LIMIT] error_count=%0d reached limit=%0d",
                      error_count, error_fatal_threshold));
  endfunction

  function void fatal(string message);
    fatal_count++;
    $fatal(1, "[%s] [%s] %s", formatted_time(), name, message);
  endfunction

  static function void fatal_static(string message);
    fatal_count++;
    $fatal(1, "[%s] %s", formatted_time(), message);
  endfunction

  function void print_summary();
    $display("[REPORTER_SUMMARY] l1=%0d l2=%0d l3=%0d warning=%0d error=%0d fatal=%0d",
             l1_count, l2_count, l3_count, warning_count, error_count,
             fatal_count);
  endfunction
endclass
