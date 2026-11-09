# DUT_KIND=rtl_v5 / rtl_fe_v5 / rtl_full_v5: BE RTL taken from the v5 tree.
#
# Evaluation root is or_cosim_v5/; the v5 BE RTL is at
#   <model>/openrios/work/or-be-draft/rtl_v5/
#
# Protocol packages are NOT listed here: exe_subop_pkg and
# or_be_lsu_protocol_pkg come from common_v5.f for every DUT kind.
+incdir+../../../openrios/work/or-be-draft/rtl_v5/pkg
+incdir+../../../openrios/work/or-be-draft/rtl_v5/p1
+incdir+../../../openrios/work/or-be-draft/rtl_v5/p2p3
+incdir+../../../openrios/work/or-be-draft/rtl_v5/p4
+incdir+../../../openrios/work/or-be-draft/rtl_v5/fu
+incdir+../../../openrios/work/or-be-draft/rtl_v5/lsu
+incdir+../../../openrios/work/or-be-draft/rtl_v5/top

# or_fe_pkg: RVC expansion and Operand_Extract live in FE. The fe_agent kinds
# have no FE RTL; be_tb_top's glue logic calls or_fe_pkg's rvc_expand /
# rvc_illegal / operand_extract to produce the expanded word and opnd that BE IB
# needs, from the same source as the FE RTL. Compiled once here for all BE kinds.
../../src/core/fe_rtl_v1/or_fe_pkg.sv

# ---- v5 packages not covered by common_v5.f (dependency order) ----
../../../openrios/work/or-be-draft/rtl_v5/pkg/or_be_types_pkg.sv
../../../openrios/work/or-be-draft/rtl_v5/pkg/fe_be_protocol_pkg.sv
../../../openrios/work/or-be-draft/rtl_v5/pkg/or_be_config_pkg.sv
../../../openrios/work/or-be-draft/rtl_v5/pkg/or_be_v5_types_pkg.sv

# ---- v5 modules ----
../../../openrios/work/or-be-draft/rtl_v5/p1/IB_ctrl.sv
../../../openrios/work/or-be-draft/rtl_v5/p2p3/p2_p3_reg.sv
../../../openrios/work/or-be-draft/rtl_v5/p2p3/p2_p3_reg_csr.sv
../../../openrios/work/or-be-draft/rtl_v5/p1/dispatch_logic.sv
../../../openrios/work/or-be-draft/rtl_v5/p1/p1_ISQ_input_mux.sv
../../../openrios/work/or-be-draft/rtl_v5/p1/FP_read_address_mux.sv
../../../openrios/work/or-be-draft/rtl_v5/p2p3/FU_input_mux.sv
../../../openrios/work/or-be-draft/rtl_v5/p1/INT_ARF.sv
../../../openrios/work/or-be-draft/rtl_v5/p1/FP_ARF.sv
../../../openrios/work/or-be-draft/rtl_v5/p1/INT_tag_mapping.sv
../../../openrios/work/or-be-draft/rtl_v5/p1/FP_tag_mapping.sv
../../../openrios/work/or-be-draft/rtl_v5/p4/SerialInstructionTracker.sv
../../../openrios/work/or-be-draft/rtl_v5/p4/PC_File.sv
../../../openrios/work/or-be-draft/rtl_v5/p4/Buffer.sv
../../../openrios/work/or-be-draft/rtl_v5/p1/IB.sv
../../../openrios/work/or-be-draft/rtl_v5/p1/decode.sv
../../../openrios/work/or-be-draft/rtl_v5/p2p3/ISQ_Group0.sv
../../../openrios/work/or-be-draft/rtl_v5/p2p3/ISQ_Group1.sv
../../../openrios/work/or-be-draft/rtl_v5/p2p3/ISQ_Group2.sv
../../../openrios/work/or-be-draft/rtl_v5/p2p3/ISQ_Group3.sv
../../../openrios/work/or-be-draft/rtl_v5/p2p3/p3_arbiter_G0.sv
../../../openrios/work/or-be-draft/rtl_v5/p2p3/p3_arbiter_G1.sv
../../../openrios/work/or-be-draft/rtl_v5/fu/alu_simple.sv
../../../openrios/work/or-be-draft/rtl_v5/fu/mul_simple.sv
../../../openrios/work/or-be-draft/rtl_v5/fu/div_simple.sv
../../../openrios/work/or-be-draft/rtl_v5/fu/csr_unit.sv
../../../openrios/work/or-be-draft/rtl_v5/fu/fpu_simple.sv
../../../openrios/work/or-be-draft/rtl_v5/p1/dependency_check.sv
../../../openrios/work/or-be-draft/rtl_v5/p1/isq_payload_assembly.sv
../../../openrios/work/or-be-draft/rtl_v5/p4/scoreboard.sv
../../../openrios/work/or-be-draft/rtl_v5/p4/system_instruction_handler.sv
../../../openrios/work/or-be-draft/rtl_v5/p4/flush_model.sv
../../../openrios/work/or-be-draft/rtl_v5/lsu/g3_lsu_iface.sv
../../../openrios/work/or-be-draft/rtl_v5/top/backend_top.sv
