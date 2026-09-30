+incdir+tb/env
+incdir+tb/interfaces
+incdir+tb/pkg
+incdir+tb/agents/initial
+incdir+tb/agents/fe
+incdir+tb/agents/be
+incdir+tb/agents/cosim
+incdir+tb/agents/cache
+incdir+tb/top

tb/pkg/orbe_be_dim_pkg.sv
tb/interfaces/ob_if.sv
tb/interfaces/ob_cosim_if.sv
tb/interfaces/lsu_if.sv
tb/interfaces/orbe_fe_if.sv
tb/pkg/isa_cosim_dpi_pkg.sv
tb/pkg/be_tb_pkg.sv

# F · BFM (BE). Under DUT_KIND=agent it occupies the slot and directly drives both the fe and lsu boundaries.
tb/agents/be/be_bfm.sv

# G2 · checker. be_checker is retired; stage 1 now runs the same checker (cosim_agent/cosim_pkg).
# tb/agents/checker/be_checker.sv

tb/top/be_tb_top.sv
