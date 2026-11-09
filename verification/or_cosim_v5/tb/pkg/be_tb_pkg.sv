// [This file] Container package: includes 8 classes/pkgs, does not map to a single node
package be_tb_pkg;
  import orbe_be_dim_pkg::*;
  import isa_dpi_pkg::*;
  import or_be_lsu_protocol_pkg::*;
  import isa_cosim_dpi_pkg::*;
  import orbe_cosim_obs_pkg::*;
  // [Advance convergence] The only advance implementation in the BE domain. Shared by both DUT kinds.
  import orbe_predictor_pkg::*;

  `include "../env/be_reporter.sv"
  `include "../env/be_config.sv"
  typedef be_config orbe_fe_config;
  typedef be_reporter orbe_fe_reporter;
  `include "../agents/initial/initial_agent.sv"
  `include "../agents/fe/fe_agent.sv"
  `include "../agents/cache/cache_agent.sv"
  `include "../agents/be/be_getter.sv"
  // COSIM event publisher. Shared by both DUT kinds; must be included before be_agent.
  `include "cosim_publisher.sv"
  `include "../agents/be/be_agent.sv"
  `include "cosim_pkg.sv"
  `include "../agents/cosim/cosim_agent.sv"
endpackage
