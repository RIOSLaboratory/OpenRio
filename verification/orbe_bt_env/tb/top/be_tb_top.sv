`timescale 1ns/1ps

module be_tb_top;
  import mock_rtl_pkg::*;
  import be_tb_pkg::*;
  import or_be_lsu_protocol_pkg::*;
  import orbe_cosim_obs_pkg::*;

  localparam time CLK_PERIOD = 10ns;

  logic clk;
  logic rstn;
  bit cfg_ready;
  bit sim_done;
  be_config cfg;
  fe_agent fe_agent_h;
  be_agent be_agent_h;
  cache_agent #(MOCK_ISSUE_NUM, MOCK_ROB_ADDR_W) cache_agent_h;
  cosim_agent #(MOCK_ISSUE_NUM, MOCK_ROB_ADDR_W) cosim_agent_h;
  mailbox #(cosim_commit_event_t) cosim_commit_events;
  mailbox #(cosim_arch_state_event_t) cosim_arch_state_events;

  orbe_fe_if fe_vif(clk, rstn);
  or_be_lsu_if lsu_vif(clk);
  ob_if ob_vif(clk);
  getter_if getter_vif(clk);
  ob_cosim_if #(.ISSUE_NUM(MOCK_ISSUE_NUM), .ROB_ADDR_W(MOCK_ROB_ADDR_W))
      ob_cosim_vif(clk);

  assign lsu_vif.rst_n = rstn;
  assign ob_cosim_vif.rst_n = rstn;

  // Keep interface-derived lines in the structural top so the observer sees
  // stable interface values during time-zero settling.
  assign lsu_vif.lsu_be_issue_ready =
      rstn && !(req_property_is_store_side(
                    req_property_from_subop(lsu_vif.be_lsu_issue_pld.exe_subop))
                && lsu_vif.lsu_store_buffer_full);
  assign lsu_vif.lsu_be_done_valid =
      lsu_vif.lsu_be_done_valid_q && !lsu_vif.global_flush_late;
  assign lsu_vif.lsu_be_exception_valid =
      lsu_vif.lsu_be_exception_valid_q && !lsu_vif.global_flush_late;
  assign lsu_vif.lsu_be_bypass_valid =
      lsu_vif.lsu_be_bypass_valid_q && !lsu_vif.global_flush_late;

`ifdef ORBE_DUT_RTL_V1
  rtl_v1_wrapper u_rtl_v1_wrapper (
    .clk     (clk),
    .rst_n   (rstn),
    .fe      (fe_vif),
    .lsu     (lsu_vif),
    .ob      (ob_vif),
    .ob_cosim(ob_cosim_vif)
  );

  // getter_if is a mock-DUT feedback channel.  Real RTL does not consume it,
  // but be_agent still creates transient responses while it drives the shared
  // ISA model, so keep those responses drainable.
  assign getter_vif.decode_rsp_ready = {MOCK_ISSUE_NUM{1'b1}};
  assign getter_vif.lsu_meta_rsp_ready = 1'b1;
  assign getter_vif.execute_rsp_ready = 1'b1;
  assign getter_vif.commit_rsp_ready = 1'b1;
`else
  logic [MOCK_ISSUE_NUM-1:0] mock_obs_alloc_valid;
  rob_alloc_pld_t [MOCK_ISSUE_NUM-1:0] mock_obs_alloc_pld;
  logic [MOCK_ISSUE_NUM-1:0][MOCK_ROB_ADDR_W-1:0] mock_obs_alloc_tag;
  logic [MOCK_ISSUE_NUM-1:0][MOCK_ROB_PTR_W-1:0] mock_obs_alloc_ptr;
  logic [MOCK_ROB_CMT_NUM-1:0] mock_obs_exec_valid;
  logic [MOCK_ROB_CMT_NUM-1:0][MOCK_ROB_ADDR_W-1:0] mock_obs_exec_tag;
  logic [MOCK_ISSUE_NUM-1:0] mock_obs_commit_valid;
  logic [MOCK_ISSUE_NUM-1:0][MOCK_ROB_ADDR_W-1:0] mock_obs_commit_tag;
  logic [MOCK_ISSUE_NUM-1:0][MOCK_ROB_PTR_W-1:0] mock_obs_commit_ptr;
  logic [MOCK_ISSUE_NUM-1:0][63:0] mock_obs_commit_pc;
  logic [$clog2(MOCK_ISSUE_NUM+1)-1:0] mock_obs_commit_count;
  logic mock_obs_global_flush;
  logic mock_obs_redirect_valid;
  logic [MOCK_VPC_W-1:0] mock_obs_redirect_pc;
  orbe_recovery_kind_e mock_obs_redirect_kind;
  logic mock_obs_recovery_valid;
  orbe_recovery_kind_e mock_obs_recovery_kind;
  logic [MOCK_ROB_ADDR_W-1:0] mock_obs_recovery_origin_tag;
  logic [MOCK_ROB_ADDR_W-1:0] mock_obs_recovery_squash_tag;
  logic [63:0] mock_obs_recovery_redirect_pc;
  logic mock_obs_csr_valid;
  logic [COSIM_CSR_STATE_NUM-1:0] mock_obs_csr_state_valid;
  logic [COSIM_CSR_STATE_NUM-1:0][11:0] mock_obs_csr_state_addr;
  logic [COSIM_CSR_STATE_NUM-1:0][63:0] mock_obs_csr_state;
  logic mock_obs_csr_event_valid;
  logic [11:0] mock_obs_csr_event_addr;
  logic [63:0] mock_obs_csr_event_wdata;
  logic [63:0] mock_obs_csr_event_rdata;

  mock_rtl u_mock_rtl (
    .clk   (clk),
    .rst_n (rstn),
    .fe    (fe_vif),
    .lsu   (lsu_vif),
    .getter(getter_vif)
  );

  // Keep combinational mock outputs on ordinary module signals until this
  // structural boundary. This preserves the interface contract used by the
  // current toolchain.
  assign fe_vif.be_fe_instr_ready = u_mock_rtl.fe_instr_ready_int;
  assign getter_vif.decode_rsp_ready = u_mock_rtl.decode_rsp_ready_int;
  assign getter_vif.lsu_meta_rsp_ready = u_mock_rtl.lsu_meta_rsp_ready_int;
  assign getter_vif.execute_rsp_ready = u_mock_rtl.execute_rsp_ready_int;
  assign getter_vif.commit_rsp_ready = u_mock_rtl.commit_rsp_ready_int;
  assign lsu_vif.be_lsu_entry_ready = u_mock_rtl.lsu_entry_ready_int;
  assign lsu_vif.be_lsu_issue_valid = u_mock_rtl.lsu_issue_valid_int;
  assign lsu_vif.be_lsu_issue_pld = u_mock_rtl.lsu_issue_pld_int;

  mock_obs_probe u_mock_obs_probe (
    .clk                    (clk),
    .rst_n                  (rstn),
    .mock_rob_alloc_valid   (u_mock_rtl.rob_alloc_valid),
    .mock_rob_alloc_pld     (u_mock_rtl.rob_alloc_pld),
    .mock_rob_alloc_rob_idx (u_mock_rtl.rob_alloc_rob_idx),
    .mock_rob_alloc_rob_ptr (u_mock_rtl.rob_alloc_rob_ptr),
    .mock_rob_commit_valid  (u_mock_rtl.rob_commit_valid),
    .mock_rob_commit_pld    (u_mock_rtl.rob_commit_pld),
    .mock_rob_commit_rob_idx(u_mock_rtl.rob_commit_rob_idx),
    .mock_exe_rob_wr_vld    (u_mock_rtl.exe_rob_wr_vld),
    .mock_exe_rob_wr_idx    (u_mock_rtl.exe_rob_wr_idx),
    .mock_flush_all         (u_mock_rtl.flush_all),
    .mock_pflush            (u_mock_rtl.pflush),
    .mock_pflush_rob_idx    (u_mock_rtl.pflush_rob_idx),
    .mock_redirect_valid    (u_mock_rtl.redirect_valid),
    .mock_redirect_pc       (u_mock_rtl.redirect_pc),
    .obs_alloc_valid        (mock_obs_alloc_valid),
    .obs_alloc_pld          (mock_obs_alloc_pld),
    .obs_alloc_tag          (mock_obs_alloc_tag),
    .obs_alloc_ptr          (mock_obs_alloc_ptr),
    .obs_exec_valid         (mock_obs_exec_valid),
    .obs_exec_tag           (mock_obs_exec_tag),
    .obs_commit_valid       (mock_obs_commit_valid),
    .obs_commit_tag         (mock_obs_commit_tag),
    .obs_commit_ptr         (mock_obs_commit_ptr),
    .obs_commit_pc          (mock_obs_commit_pc),
    .obs_commit_count       (mock_obs_commit_count),
    .obs_global_flush       (mock_obs_global_flush),
    .obs_redirect_valid     (mock_obs_redirect_valid),
    .obs_redirect_pc        (mock_obs_redirect_pc),
    .obs_redirect_kind      (mock_obs_redirect_kind),
    .obs_recovery_valid     (mock_obs_recovery_valid),
    .obs_recovery_kind      (mock_obs_recovery_kind),
    .obs_recovery_origin_tag(mock_obs_recovery_origin_tag),
    .obs_recovery_squash_tag(mock_obs_recovery_squash_tag),
    .obs_recovery_redirect_pc(mock_obs_recovery_redirect_pc),
    .obs_csr_valid          (mock_obs_csr_valid),
    .obs_csr_state_valid    (mock_obs_csr_state_valid),
    .obs_csr_state_addr     (mock_obs_csr_state_addr),
    .obs_csr_state          (mock_obs_csr_state),
    .obs_csr_event_valid    (mock_obs_csr_event_valid),
    .obs_csr_event_addr     (mock_obs_csr_event_addr),
    .obs_csr_event_wdata    (mock_obs_csr_event_wdata),
    .obs_csr_event_rdata    (mock_obs_csr_event_rdata)
  );

  always_comb begin
    ob_vif.alloc_valid = mock_obs_alloc_valid;
    ob_vif.alloc_pld = mock_obs_alloc_pld;
    ob_vif.alloc_tag = mock_obs_alloc_tag;
    ob_vif.rob_alloc_valid = mock_obs_alloc_valid;
    ob_vif.rob_alloc_pld = mock_obs_alloc_pld;
    ob_vif.rob_alloc_rob_idx = mock_obs_alloc_tag;
    ob_vif.rob_alloc_rob_ptr = mock_obs_alloc_ptr;

    ob_vif.exec_valid = mock_obs_exec_valid;
    ob_vif.exec_tag = mock_obs_exec_tag;
    ob_vif.exe_rob_wr_vld = mock_obs_exec_valid;
    ob_vif.exe_rob_wr_idx = mock_obs_exec_tag;

    ob_vif.commit_valid = mock_obs_commit_valid;
    ob_vif.commit_tag = mock_obs_commit_tag;
    ob_vif.commit_pc = mock_obs_commit_pc;
    ob_vif.commit_count = mock_obs_commit_count;
    ob_vif.rob_commit_valid = mock_obs_commit_valid;
    ob_vif.rob_commit_rob_idx = mock_obs_commit_tag;
    ob_vif.rob_commit_pld = '{default:'0};
    for (int group = 0; group < MOCK_ISSUE_NUM; group++) begin
      ob_vif.rob_commit_pld[group].pc = mock_obs_commit_pc[group];
      ob_vif.rob_commit_pld[group].rob_idx = mock_obs_commit_ptr[group];
    end

    ob_vif.global_flush = mock_obs_global_flush;
    ob_vif.redirect_valid = mock_obs_redirect_valid;
    ob_vif.redirect_pc = mock_obs_redirect_pc;
    ob_vif.redirect_kind = mock_obs_redirect_kind;
    ob_vif.recovery_valid = mock_obs_recovery_valid;
    ob_vif.recovery_kind = mock_obs_recovery_kind;
    ob_vif.recovery_origin_tag = mock_obs_recovery_origin_tag;
    ob_vif.recovery_squash_tag = mock_obs_recovery_squash_tag;
    ob_vif.recovery_redirect_pc = mock_obs_recovery_redirect_pc;

    ob_vif.flush_all = '0;
    if (mock_obs_recovery_valid &&
        (mock_obs_recovery_kind == ORBE_RECOVERY_EXCEPTION))
      ob_vif.flush_all = '1;
    ob_vif.pflush = mock_obs_recovery_valid && (ob_vif.flush_all == '0);
    ob_vif.pflush_rob_idx = mock_obs_recovery_origin_tag;
  end
`endif

`ifndef ORBE_DUT_RTL_V1
  // The top binds non-rtl_v1 DUT observation into the product-neutral COSIM
  // boundary.  rtl_v1_wrapper drives these fields from rtl_v1_obs_probe.
  assign ob_cosim_vif.commit_valid = mock_obs_commit_valid;
  assign ob_cosim_vif.commit_rob_idx = mock_obs_commit_tag;
  assign ob_cosim_vif.commit_pc = mock_obs_commit_pc;

  // CSR comparison remains disabled until the ISA-case CSR set is frozen.
  // The MOCK ARF snapshot is refreshed by be_agent after shared-model commit,
  // immediately before it publishes this cycle's architectural-state event.
  assign ob_cosim_vif.csr_valid = mock_obs_csr_valid;
  assign ob_cosim_vif.csr_state_valid = mock_obs_csr_state_valid;
  assign ob_cosim_vif.csr_state_addr = mock_obs_csr_state_addr;
  assign ob_cosim_vif.csr_state = mock_obs_csr_state;
  assign ob_cosim_vif.csr_event_valid = mock_obs_csr_event_valid;
  assign ob_cosim_vif.csr_event_addr = mock_obs_csr_event_addr;
  assign ob_cosim_vif.csr_event_wdata = mock_obs_csr_event_wdata;
  assign ob_cosim_vif.csr_event_rdata = mock_obs_csr_event_rdata;
`endif

  initial begin : clock_generator
    clk = 1'b0;
    forever #(CLK_PERIOD / 2) clk = ~clk;
  end

  initial begin : configure
    cfg_ready = 1'b0;
    sim_done = 1'b0;
    cfg = new();
    cosim_commit_events = new();
    cosim_arch_state_events = new();
    cfg.apply_plusargs();
    cfg.validate(MOCK_ISSUE_NUM);
    cfg.print();
    cfg_ready = 1'b1;
  end

  initial begin : sim_watchdog
    int unsigned timeout_cycles;
    time timeout_time;

    wait (cfg_ready);
    timeout_cycles = cfg.timeout_cycles;
    timeout_time = timeout_cycles * CLK_PERIOD;
    @(posedge rstn);
    #(timeout_time);
    #1;
    if (!sim_done)
      cfg.reporter.fatal($sformatf(
          "[TB] simulation timeout after %0d clock cycles (%0t)",
          timeout_cycles, timeout_time));
  end

  initial begin : reset_and_run
    string elf_path;

    wait (cfg_ready);
    rstn = 1'b0;
    repeat (5) @(posedge clk);
    rstn = 1'b1;

    fe_agent_h = new(fe_vif, cfg);
    be_agent_h = new(ob_vif, fe_vif, getter_vif, ob_cosim_vif,
                     cosim_commit_events, cosim_arch_state_events, cfg);
    cache_agent_h = new(lsu_vif, ob_vif, ob_cosim_vif, cfg);
    if (cfg.cosim_enable) begin
      if (!$value$plusargs("ISA_ELF=%s", elf_path) || (elf_path.len() == 0))
        cfg.reporter.fatal("[TB] COSIM_ENABLE requires +ISA_ELF=<test.elf>");
      cosim_agent_h = new(ob_cosim_vif, cosim_commit_events,
                          cosim_arch_state_events, cfg);
      cosim_agent_h.initialize_model(elf_path);
    end

    if (cfg.cosim_enable) begin
      fork
        fe_agent_h.run();
        be_agent_h.run();
        cache_agent_h.run();
        cosim_agent_h.run();
      join
    end else begin
      fork
        fe_agent_h.run();
        be_agent_h.run();
        cache_agent_h.run();
      join
    end

    fe_agent_h.finish_model();
    if (cosim_agent_h != null)
      cosim_agent_h.finish_model();
    sim_done = 1'b1;
    $finish;
  end

  final begin
    if (cfg != null)
      cfg.reporter.print_summary();
  end
endmodule
