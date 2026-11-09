# or_cosim_v5 · common filelist (packages every DUT kind needs, compiled first)
#
# Same role as common.f, but the two protocol packages come from the v5 RTL
# tree instead of src/core/be_rtl_v1/:
#   exe_subop_pkg          -- standalone
#   or_be_lsu_protocol_pkg -- imports exe_subop_pkg only
# Everything else in v5/pkg (or_be_types_pkg, fe_be_protocol_pkg,
# or_be_config_pkg, or_be_v5_types_pkg) is listed by rtl_v5.f, because those
# depend on the two above and must come after them.
#
# Evaluation root is or_cosim_v5/; v5 RTL lives at
#   <model>/openrios/work/or-be-draft/rtl_v5/
# which is ../../../openrios/work/or-be-draft/rtl_v5 from here.
+incdir+tb/pkg

../../../openrios/work/or-be-draft/rtl_v5/pkg/exe_subop_pkg.sv
../../../openrios/work/or-be-draft/rtl_v5/pkg/or_be_lsu_protocol_pkg.sv

tb/agents/fe/riscv_rvc_pkg.sv
tb/pkg/orbe_cosim_obs_pkg.sv

# G1 · predictor. The only implementation in the whole environment that changes
# shared ISA model state;
# must be compiled before any file that calls it.
tb/pkg/orbe_predictor_pkg.sv
