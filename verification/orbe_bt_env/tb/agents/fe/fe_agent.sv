class fe_agent;
  be_config cfg;
  fe_driver driver;

  function new(virtual fe_if vif, be_config cfg);
    if (cfg == null)
      be_reporter::fatal_static("[FE] fe_agent requires a non-null be_config");
    this.cfg = cfg;
    driver = new(vif, cfg);
  endfunction

  task run();
    driver.run();
  endtask

  task shutdown();
    driver.shutdown();
  endtask

  task finish_model();
    driver.finish_model();
  endtask
endclass
