# DUT_KIND=rtl_fe: BE RTL (same as rtl_v1.f) + OR_FE RTL + FE downstream interface.
# Evaluation root is orbe_bt_env/; OR_FE RTL is in ../../src/core/fe_rtl_v1/.
-f cfg/filelist/rtl_v1.f

# or_fe_pkg.sv is compiled by rtl_v1.f (the fe_agent kind's glue logic also needs it)
../../src/core/fe_rtl_v1/tag_compare.sv
../../src/core/fe_rtl_v1/mshr.sv
../../src/core/fe_rtl_v1/icache.sv
../../src/core/fe_rtl_v1/itlb.sv
../../src/core/fe_rtl_v1/l1btb.sv
../../src/core/fe_rtl_v1/instr_data_expand.sv
../../src/core/fe_rtl_v1/predecode.sv
../../src/core/fe_rtl_v1/direct_jump.sv
../../src/core/fe_rtl_v1/ras.sv
../../src/core/fe_rtl_v1/slot_arb.sv
../../src/core/fe_rtl_v1/precheck.sv
../../src/core/fe_rtl_v1/ib_enq_window.sv
../../src/core/fe_rtl_v1/bpf.sv
../../src/core/fe_rtl_v1/pc_gen.sv
../../src/core/fe_rtl_v1/be_ctrl_reg.sv
../../src/core/fe_rtl_v1/flush_control.sv
../../src/core/fe_rtl_v1/or_fe_top.sv

tb/interfaces/orbe_fe_mem_if.sv
