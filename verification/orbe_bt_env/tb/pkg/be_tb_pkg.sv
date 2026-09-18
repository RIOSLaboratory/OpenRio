package be_tb_pkg;
  import mock_rtl_pkg::*;
  import isa_dpi_pkg::*;
  import or_be_lsu_protocol_pkg::*;
  import isa_cosim_dpi_pkg::*;
  import orbe_cosim_obs_pkg::*;

  `include "../env/be_reporter.sv"
  `include "../env/be_config.sv"
  typedef be_config orbe_fe_config;
  typedef be_reporter orbe_fe_reporter;
  `include "../modified_agents/fe/fe_driver.sv"
  `include "../modified_agents/fe/fe_agent.sv"
  `include "../modified_agents/cache/cache_agent.sv"
  `include "../agents/be/be_getter.sv"
  `include "../agents/be/be_agent.sv"
  `include "cosim_pkg.sv"
  `include "../agents/cosim/cosim_agent.sv"
endpackage
