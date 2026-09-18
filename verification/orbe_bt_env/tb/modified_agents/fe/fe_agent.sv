class fe_agent;
  orbe_fe_config cfg;
  fe_driver driver;

  function new(virtual orbe_fe_if.tb vif, orbe_fe_config cfg);
    if (cfg == null)
      orbe_fe_reporter::fatal_static("[FE] fe_agent requires a non-null orbe_fe_config");
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
