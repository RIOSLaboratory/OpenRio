+incdir+../../core/backend/pkg
+incdir+../../core/backend/p1
+incdir+../../core/backend/p2p3
+incdir+../../core/backend/p4
+incdir+../../core/backend/fu
+incdir+../../core/backend/lsu
+incdir+../../core/backend/top

../../core/backend/pkg/or_be_config_pkg.sv
../../core/backend/pkg/or_be_types_pkg.sv
../../core/backend/pkg/fe_be_protocol_pkg.sv
../../core/backend/pkg/or_be_types_check.sv

../../core/backend/p1/rvc_expand.sv
../../core/backend/p1/decode.sv
../../core/backend/p1/IB.sv
../../core/backend/p1/dependency_check.sv
../../core/backend/p1/dispatch_logic.sv
../../core/backend/p1/INT_ARF.sv
../../core/backend/p1/FP_ARF.sv
../../core/backend/p1/INT_tag_mapping.sv
../../core/backend/p1/FP_tag_mapping.sv
../../core/backend/p1/FP_read_address_mux.sv
../../core/backend/p1/p1_ISQ_input_mux.sv

../../core/backend/top/isq_payload_assembly.sv

../../core/backend/p2p3/FU_input_mux.sv
../../core/backend/p2p3/ISQ_Group0.sv
../../core/backend/p2p3/ISQ_Group1.sv
../../core/backend/p2p3/ISQ_Group2.sv
../../core/backend/p2p3/ISQ_Group3.sv
../../core/backend/p2p3/p3_arbiter_G0.sv
../../core/backend/p2p3/p3_arbiter_G1.sv

../../core/backend/fu/alu_simple.sv
../../core/backend/fu/csr_unit.sv
../../core/backend/fu/div_simple.sv
../../core/backend/fu/fpu_simple.sv
../../core/backend/fu/mul_simple.sv

../../core/backend/lsu/lsu_bridge.sv

../../core/backend/p4/Buffer.sv
../../core/backend/p4/PC_File.sv
../../core/backend/p4/SerialInstructionTracker.sv
../../core/backend/p4/flush_model.sv
../../core/backend/p4/system_instruction_handler.sv
../../core/backend/p4/CompletionScoreboard.sv

../../core/backend/top/backend_top.sv
