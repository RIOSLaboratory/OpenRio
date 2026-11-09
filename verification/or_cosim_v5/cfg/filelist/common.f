+incdir+tb/pkg

../../src/core/be_rtl_v1/pkg/exe_subop_pkg.sv
../../src/core/be_rtl_v1/pkg/or_be_lsu_protocol_pkg.sv
tb/agents/fe/riscv_rvc_pkg.sv
tb/pkg/orbe_cosim_obs_pkg.sv

# G1 · predictor. The only implementation in the whole environment that changes shared ISA model state;
# must be compiled before any file that calls it.
tb/pkg/orbe_predictor_pkg.sv
