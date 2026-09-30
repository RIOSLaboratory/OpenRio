# Evaluation root is orbe_bt_env/; BE RTL is in src/core/be_rtl_v1/ at the repo root, i.e. ../../src/core/be_rtl_v1/.
#
# Protocol packages are not listed in this file: exe_subop_pkg and or_be_lsu_protocol_pkg both live in
# src/core/be_rtl_v1/pkg/ and are compiled by common.f for all configurations (the agent kind compiles no RTL but still needs them).
+incdir+../../src/core/be_rtl_v1/pkg
+incdir+../../src/core/be_rtl_v1/p1
+incdir+../../src/core/be_rtl_v1/p2p3
+incdir+../../src/core/be_rtl_v1/p4
+incdir+../../src/core/be_rtl_v1/fu
+incdir+../../src/core/be_rtl_v1/lsu
+incdir+../../src/core/be_rtl_v1/top

# or_fe_pkg: RVC expansion and Operand_Extract live in FE. The fe_agent kinds (rtl_v1 / rtl_cache) have no FE RTL;
# be_tb_top's glue logic calls or_fe_pkg's rvc_expand / rvc_illegal / operand_extract to produce the expanded word and opnd
# that BE IB needs, from the same source as the FE RTL, so or_fe_pkg is compiled once here for all BE kinds.
../../src/core/fe_rtl_v1/or_fe_pkg.sv

../../src/core/be_rtl_v1/pkg/or_be_config_pkg.sv
../../src/core/be_rtl_v1/pkg/or_be_types_pkg.sv
../../src/core/be_rtl_v1/pkg/fe_be_protocol_pkg.sv
../../src/core/be_rtl_v1/pkg/or_be_types_check.sv

../../src/core/be_rtl_v1/p1/decode.sv
../../src/core/be_rtl_v1/p1/IB.sv
../../src/core/be_rtl_v1/p1/dependency_check.sv
../../src/core/be_rtl_v1/p1/dispatch_logic.sv
../../src/core/be_rtl_v1/p1/INT_ARF.sv
../../src/core/be_rtl_v1/p1/FP_ARF.sv
../../src/core/be_rtl_v1/p1/INT_tag_mapping.sv
../../src/core/be_rtl_v1/p1/FP_tag_mapping.sv
../../src/core/be_rtl_v1/p1/FP_read_address_mux.sv
../../src/core/be_rtl_v1/p1/p1_ISQ_input_mux.sv

../../src/core/be_rtl_v1/top/isq_payload_assembly.sv

../../src/core/be_rtl_v1/p2p3/FU_input_mux.sv
../../src/core/be_rtl_v1/p2p3/ISQ_Group0.sv
../../src/core/be_rtl_v1/p2p3/ISQ_Group1.sv
../../src/core/be_rtl_v1/p2p3/ISQ_Group2.sv
../../src/core/be_rtl_v1/p2p3/ISQ_Group3.sv
../../src/core/be_rtl_v1/p2p3/p3_arbiter_G0.sv
../../src/core/be_rtl_v1/p2p3/p3_arbiter_G1.sv

../../src/core/be_rtl_v1/fu/alu_simple.sv
../../src/core/be_rtl_v1/fu/csr_unit.sv
../../src/core/be_rtl_v1/fu/div_simple.sv
../../src/core/be_rtl_v1/fu/fpu_simple.sv
../../src/core/be_rtl_v1/fu/mul_simple.sv

../../src/core/be_rtl_v1/lsu/g3_lsu_iface.sv

../../src/core/be_rtl_v1/p4/Buffer.sv
../../src/core/be_rtl_v1/p4/PC_File.sv
../../src/core/be_rtl_v1/p4/SerialInstructionTracker.sv
../../src/core/be_rtl_v1/p4/flush_model.sv
../../src/core/be_rtl_v1/p4/system_instruction_handler.sv
../../src/core/be_rtl_v1/p4/CompletionScoreboard.sv

../../src/core/be_rtl_v1/top/backend_top.sv
