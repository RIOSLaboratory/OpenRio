# Interface type definition for each module

## FP_ARF

1. `rst_n`: In Static Info
2. `commit_valid`: In Event, payload:
    - `rd_write_enable`
    - `rd_is_fp`
    - `rd_idx`
    - `commit_data`
3. `fp_read_idx`: In Static Info
4. `ARF`: Out Static Info

## FP_read_address_mux

1. `rs1_idx`: In Static Info
2. `rs2_idx`: In Static Info
3. `rs3_idx`: In Static Info
4. `is_fp_opcode`: In Static Info
5. `fp_read_idx`: Out Static Info

## FP_tag_mapping

1. `rst_n`: In Static Info
2. `accept`: In Event, payload:
    - `alloc_rd_write_enable`
    - `alloc_rd_is_fp`
    - `alloc_rd_idx`
    - `self_tag`
3. `commit_valid`: In Event, payload:
    - `commit_tag`
    - `commit_rd_idx`
    - `commit_rd_is_fp`
    - `commit_rd_write_enable`
4. `global_flush_late`: In Event, no payload
5. `fp_read_idx`: In Static Info
6. `tag`: Out Static Info
7. `busy`: Out Static Info

## IB

1. `rst_n`: In Static Info
2. `fe_valid`: In Event, payload:
    - `enq_IB_Payload`
3. `accept`: In Event, no payload
4. `global_flush_late`: In Event, no payload
5. `head_IB_Payload`: Out Static Info
6. `inst_valid`: Out Static Info
7. `fe_ready`: Out Static Info
8. `accepted_slot`: Out Static Info

## INT_ARF

1. `rst_n`: In Static Info
2. `commit_valid`: In Event, payload:
    - `rd_idx`
    - `rd_is_fp`
    - `rd_write_enable`
    - `commit_data`
3. `rs_idx`: In Static Info
4. `ARF`: Out Static Info

## INT_tag_mapping

1. `rst_n`: In Static Info
2. `accept`: In Event, payload:
    - `self_tag`
    - `alloc_rd_idx`
    - `alloc_rd_is_fp`
    - `alloc_rd_write_enable`
3. `commit_valid`: In Event, payload:
    - `commit_tag`
    - `commit_rd_idx`
    - `commit_rd_is_fp`
    - `commit_rd_write_enable`
4. `global_flush_late`: In Event, no payload
5. `rs_idx`: In Static Info
6. `tag`: Out Static Info
7. `busy`: Out Static Info

## decode

1. `decode_payload`: In Static Info
2. `dec_info`: Out Static Info
3. `dec_is_fp_opcode`: Out Static Info
4. `rs1_idx`: Out Static Info
5. `rs2_idx`: Out Static Info
6. `rs3_idx`: Out Static Info
7. `rd_idx`: Out Static Info

## dependency_check

1. `inst_valid`: In Static Info
2. `rd_idx`: In Static Info
3. `rd_is_fp`: In Static Info
4. `use_rd`: In Static Info
5. `is_serial`: In Static Info
6. `is_fp_opcode`: In Static Info
7. `use_rs1`: In Static Info
8. `use_rs2`: In Static Info
9. `use_rs3`: In Static Info
10. `rs1_idx`: In Static Info
11. `rs2_idx`: In Static Info
12. `rs3_idx`: In Static Info
13. `rs1_is_fp`: In Static Info
14. `rs2_is_fp`: In Static Info
15. `rs3_is_fp`: In Static Info
16. `Buffer_tail`: In Static Info
17. `int_rename_read_tag`: In Static Info
18. `int_rename_read_busy`: In Static Info
19. `fp_rename_read_tag`: In Static Info
20. `fp_rename_read_busy`: In Static Info
21. `scoreboard_valid_bits`: In Static Info
22. `scoreboard_exec_done_bits`: In Static Info
23. `commit_valid`: In Event, payload:
    - `commit_tag`
24. `bypass_publish_valid`: In Event, payload:
    - `bypass_tag`
25. `self_tag`: Out Static Info
26. `rd_write_enable`: Out Static Info
27. `serial0`: Out Static Info
28. `serial_inst`: Out Static Info
29. `fp0`: Out Static Info
30. `fp1`: Out Static Info
31. `slot_missed_wakeup`: Out Static Info
32. `rsX_ready`: Out Static Info
33. `rsX_wait_tag`: Out Static Info
34. `rs_data_sel_t`: Out Static Info

## dispatch_logic

1. `inst_valid`: In Static Info
2. `serial0`: In Static Info
3. `serial_inst`: In Static Info
4. `fp0`: In Static Info
5. `fp1`: In Static Info
6. `slot_missed_wakeup`: In Static Info
7. `exe_subop`: In Static Info
8. `full_decode`: In Static Info
9. `is_fp_instruction`: In Static Info
10. `fs_enabled`: In Static Info
11. `frm`: In Static Info
12. `can_alloc_1`: In Static Info
13. `can_alloc_2`: In Static Info
14. `buffer_empty`: In Static Info
15. `isq_free_for_dispatch`: In Static Info
16. `serial_inflight_valid`: In Static Info
17. `self_tag`: In Static Info
18. `global_flush_late`: In Event, no payload
19. `accept`: Out Event, no payload
20. `isq_wr_en`: Out Event, no payload
21. `slot_FU_Group`: Out Static Info
22. `effective_rm`: Out Static Info
23. `is_fence_i`: Out Static Info
24. `may_flush`: Out Static Info
25. `is_atomic`: Out Static Info
26. `serial_set_valid`: Out Event, payload:
    - `serial_set_tag`
27. `select_payload`: Out Static Info

## p1_ISQ_input_mux

1. `slot_payload`: In Static Info
2. `select_payload`: In Static Info
3. `ISQ_payload_in`: Out Static Info

## rvc_expand

1. `ib_inst_bits`: In Static Info
2. `ib_is_compressed`: In Static Info
3. `inst32`: Out Static Info
4. `rvc_illegal`: Out Static Info

## FU_input_mux

1. `entry_rsX_data`: In Static Info
3. `bypass_publish_valid`: In Event, payload:
    - `bypass_tag`
    - `bypass_data`
4. `rsX_wait_tag`: In Static Info
6. `rsX_ready`: In Static Info
7. `fu_rsX_data`: Out Static Info

## ISQ_Group0

1. `rst_n`: In Static Info
2. `dispatch_valid`: In Event, payload:
    - `payload_in`
3. `bypass_publish_valid`: In Event, payload:
    - `bypass_tag`
    - `bypass_data`
4. `global_flush_late`: In Event, no payload
5. `FU_ready`: In Static Info
6. `issue_valid`: Out Event, payload:
    - `rs1_data`
    - `rs2_data`
    - `FU_Group`
    - `imm_valid`
    - `imm_data`
    - `pc`
    - `inst_bits`
    - `is_compressed`
    - `pred_taken`
    - `pred_target_pc`
    - `self_tag`
    - `exe_subop`
    - `full_decode`
    - `fetch_excp_vld`
    - `fetch_excp_cause`
    - `fetch_excp_tval`
7. `isq_free_for_dispatch`: Out Static Info

## ISQ_Group1

1. `rst_n`: In Static Info
2. `dispatch_valid`: In Event, payload:
    - `payload_in`
3. `bypass_publish_valid`: In Event, payload:
    - `bypass_tag`
    - `bypass_data`
4. `global_flush_late`: In Event, no payload
5. `FU_ready`: In Static Info
6. `issue_valid`: Out Event, payload:
    - `rs1_data`
    - `rs2_data`
    - `FU_Group`
    - `imm_data`
    - `self_tag`
    - `exe_subop`
7. `isq_free_for_dispatch`: Out Static Info

## ISQ_Group2

1. `rst_n`: In Static Info
2. `dispatch_valid`: In Event, payload:
    - `payload_in`
3. `bypass_publish_valid`: In Event, payload:
    - `bypass_tag`
    - `bypass_data`
4. `global_flush_late`: In Event, no payload
5. `FU_ready`: In Static Info
6. `issue_valid`: Out Event, payload:
    - `rs1_data`
    - `rs2_data`
    - `rs3_data`
    - `self_tag`
    - `exe_subop`
    - `full_decode`
7. `isq_free_for_dispatch`: Out Static Info

## ISQ_Group3

1. `rst_n`: In Static Info
2. `dispatch_valid`: In Event, payload:
    - `payload_in`
3. `bypass_publish_valid`: In Event, payload:
    - `bypass_tag`
    - `bypass_data`
4. `global_flush_late`: In Event, no payload
5. `FU_ready`: In Static Info
6. `issue_valid`: Out Event, payload:
    - `rs1_data`
    - `store_data`
    - `imm_valid`
    - `imm_data`
    - `mem_funct3`
    - `rd_is_fp`
    - `entry_self_tag`
    - `exe_subop`
7. `isq_free_for_dispatch`: Out Static Info
8. `isq_occupied`: Out Static Info

## p3_arbiter_G0

1. `request_valid`: In Event, payload:
    - `req_tag`
    - `req_result_data`
    - `req_mispredict_flag`
    - `req_mispredict_target_pc`
    - `req_exception_flag`
    - `req_exception_cause`
    - `req_exception_tval`
    - `req_is_mret`
    - `req_is_sret`
    - `req_fpu_fflags`
    - `req_is_csr`
    - `req_csr_write_enable`
    - `req_csr_addr`
    - `req_csr_wdata`
2. `writeback_valid`: Out Event, payload:
    - `tag_out`
    - `result_data`
    - `mispredict_flag`
    - `mispredict_target_pc`
    - `exception_flag`
    - `exception_cause`
    - `exception_tval`
    - `is_mret`
    - `is_sret`
    - `fpu_fflags`
3. `csr_sideband_publish_valid`: Out Event, payload:
    - `is_csr`
    - `csr_write_enable`
    - `csr_addr`
    - `csr_wdata`
4. `bypass_publish_valid`: Out Event, payload:
    - `bypass_tag`
    - `bypass_data`
5. `winner_grant`: Out Event, no payload
6. `loser_hold`: Out Static Info

## p3_arbiter_G1

1. `request_valid`: In Event, payload:
    - `req_tag`
    - `req_result_data`
    - `req_exception_flag`
    - `req_exception_cause`
    - `req_exception_tval`
    - `req_mispredict_flag`
    - `req_mispredict_target_pc`
    - `req_is_mret`
    - `req_is_sret`
    - `req_fpu_fflags`
2. `writeback_valid`: Out Event, payload:
    - `tag_out`
    - `result_data`
    - `exception_flag`
    - `exception_cause`
    - `exception_tval`
    - `mispredict_flag`
    - `mispredict_target_pc`
    - `is_mret`
    - `is_sret`
    - `fpu_fflags`
3. `bypass_publish_valid`: Out Event, payload:
    - `bypass_tag`
    - `bypass_data`
4. `winner_grant`: Out Event, no payload
5. `loser_hold`: Out Static Info

## Buffer

1. `rst_n`: In Static Info
2. `writeback_valid`: In Event, payload:
    - `tag_out`
    - `result_data`
3. `head_tag`: In Static Info
4. `commit_data`: Out Static Info

## CompletionScoreboard

1. `rst_n`: In Static Info
2. `accept`: In Event, payload:
    - `alloc_self_tag`
    - `rd_idx`
    - `rd_is_fp`
    - `rd_write_enable`
    - `is_store`
    - `is_fence_i`
    - `may_flush`
    - `is_atomic`
3. `writeback_valid`: In Event, payload:
    - `tag_out`
    - `mispredict_flag`
    - `mispredict_target_pc`
    - `exception_flag`
    - `exception_cause`
    - `exception_tval`
    - `is_mret`
    - `is_sret`
    - `fpu_fflags`
4. `global_flush_late`: In Event, no payload
5. `interrupt_pending`: In Static Info
6. `st_br_resolve_tag`: In Static Info
7. `st_br_resolve_tag_valid`: In Static Info
8. `commit_valid`: Out Event, payload:
    - `commit_tag`
    - `commit_rd_idx`
    - `commit_rd_is_fp`
    - `commit_rd_write_enable`
    - `commit_fflags`
9. `commit_count`: Out Static Info
10. `store_wakeup_valid`: Out Event, payload:
    - `store_wakeup_tag`
11. `flush_valid`: Out Event, payload:
    - `flush_tag`
    - `recovery_kind`
12. `head_tag`: Out Static Info
13. `recovery_mispredict_target_pc`: Out Static Info
14. `recovery_exception_cause`: Out Static Info
15. `recovery_exception_tval`: Out Static Info
16. `st_br_resolve`: Out Static Info
17. `scoreboard_valid_bits`: Out Static Info
18. `scoreboard_exec_done_bits`: Out Static Info
19. `Buffer_tail`: Out Static Info
20. `can_alloc_1`: Out Static Info
21. `can_alloc_2`: Out Static Info
22. `buffer_empty`: Out Static Info

## PC_File

1. `rst_n`: In Static Info
2. `accept`: In Event, payload:
    - `self_tag`
    - `pc`
3. `flush_tag`: In Static Info
4. `head_tag`: In Static Info
5. `inst_pc`: Out Static Info
6. `trace_pc`: Out Static Info

## SerialInstructionTracker

1. `rst_n`: In Static Info
2. `serial_set_valid`: In Event, payload:
    - `serial_set_tag`
3. `commit_valid`: In Event, payload:
    - `commit_tag`
4. `global_flush_late`: In Event, no payload
5. `serial_inflight_valid`: Out Static Info

## flush_model

1. `flush_valid`: In Event, payload:
    - `recovery_kind`
    - `flush_tag`
2. `mispredict_target_pc`: In Static Info
3. `exception_cause`: In Static Info
4. `exception_tval`: In Static Info
5. `inst_pc`: In Static Info
6. `mepc`: In Static Info
7. `sepc`: In Static Info
8. `interrupt_cause`: In Static Info
9. `trap_vector`: In Static Info
10. `global_flush_late`: Out Event, no payload
11. `redirect_valid`: Out Event, payload:
    - `redirect_pc`
    - `redirect_kind`
    - `frontend_icache_invalidate`
12. `trap_state_write.valid`: Out Event, payload
    - `trap_state_write.kind`
    - `trap_state_write.epc`
    - `trap_state_write.cause`
    - `trap_state_write.tval`
13. `cause`: Out Static Info
14. `is_interrupt`: Out Static Info

## system_instruction_handler

1. `rst_n`: In Static Info
2. `csr_sideband_valid`: In Event, payload:
    - `tag_out`
    - `sb_is_csr`
    - `sb_csr_write_enable`
    - `sb_csr_addr`
    - `sb_csr_wdata`
3. `commit_valid`: In Event, payload:
    - `commit_tag`
    - `commit_fflags`
    - `rd_is_fp`
    - `rd_write_enable`
4. `commit_count`: In Static Info
5. `trap_state_write`: In Event
6. `global_flush_late`: In Event, no payload
7. `csr_addr`: In Static Info
8. `trap_cause_in`: In Static Info
9. `trap_is_interrupt_in`: In Static Info
10. `mip_meip`: In Static Info
11. `mip_mtip`: In Static Info
12. `mip_msip`: In Static Info
13. `csr_rdata`: Out Static Info
14. `current_priv`: Out Static Info
15. `frm`: Out Static Info
16. `fs_enabled`: Out Static Info
17. `trap_vector`: Out Static Info
18. `interrupt_pending`: Out Static Info
19. `interrupt_cause`: Out Static Info
20. `mepc`: Out Static Info
21. `sepc`: Out Static Info
22. `mstatus_tvm`: Out Static Info
23. `mstatus_tw`: Out Static Info
24. `mstatus_tsr`: Out Static Info

## backend_top

1. `rst_n`: In Static Info
2. `fe_valid`: In Event, payload:
    - `fe_instr_pld`
3. `fe_ready`: Out Static Info
4. `accepted_slot`: Out Static Info
5. `redirect_valid`: Out Event, payload:
    - `redirect_pc`
    - `redirect_kind`
    - `frontend_icache_invalidate`
6. `predictor_update_valid`: Out Event, payload:
    - `predictor_update_branch_pc`
    - `predictor_update_actual_taken`
    - `predictor_update_actual_target`
    - `predictor_update_cf_class`
7. `be_lsu_issue_valid`: Out Event, payload:
    - `be_lsu_issue_pld`
8. `be_lsu_store_wakeup_valid`: Out Event, payload:
    - `be_lsu_store_wakeup_tag`
9. `global_flush`: Out Event, no payload
10. `lsu_be_issue_ready`: In Static Info
11. `lsu_be_writeback_valid`: In Event, payload:
    - `lsu_be_writeback_pld`
12. `lsu_be_bypass_valid`: In Event, payload:
    - `lsu_be_bypass_pld`
13. `mip_meip`: In Static Info
14. `mip_mtip`: In Static Info
15. `mip_msip`: In Static Info
16. `alloc_valid`: Out Event, payload:
    - `alloc_tag`
17. `exec_valid`: Out Event, payload:
    - `exec_tag`
18. `commit_valid`: Out Event, payload:
    - `commit_tag`
    - `commit_rd_idx`
    - `commit_rd_is_fp`
    - `commit_rd_write_enable`
    - `commit_fflags`
    - `commit_data`
    - `trace_pc`
19. `commit_count`: Out Static Info

## isq_payload_assembly

1. `head_IB_Payload`: In Static Info
2. `dec_info`: In Static Info
3. `rsX_ready`: In Static Info
4. `rsX_wait_tag`: In Static Info
5. `rs_data_sel_t`: In Static Info
6. `self_tag`: In Static Info
7. `INT_ARF`: In Static Info
8. `FP_ARF`: In Static Info
9. `commit_data`: In Static Info
10. `bypass_data`: In Static Info
11. `slot_FU_Group`: In Static Info
12. `effective_rm`: In Static Info
13. `slot_payload`: Out Static Info

## alu_simple

1. `rst_n`: In Static Info
2. `global_flush_late`: In Event, no payload
3. `issue_valid`: In Event, payload:
    - `rs1_data`
    - `rs2_data`
    - `FU_Group`
    - `imm_data`
    - `pc`
    - `inst_bits`
    - `is_compressed`
    - `pred_taken`
    - `pred_target_pc`
    - `self_tag`
    - `exe_subop`
    - `full_decode`
    - `fetch_excp_vld`
    - `fetch_excp_cause`
    - `fetch_excp_tval`
4. `current_priv`: In Static Info
5. `mstatus_tsr`: In Static Info
6. `mstatus_tw`: In Static Info
7. `mstatus_tvm`: In Static Info
8. `FU_ready`: Out Static Info
9. `request_valid`: Out Event, payload:
    - `req_tag`
    - `req_result_data`
    - `req_mispredict_flag`
    - `req_mispredict_target_pc`
    - `req_exception_flag`
    - `req_exception_cause`
    - `req_exception_tval`
    - `req_is_mret`
    - `req_is_sret`
    - `req_fpu_fflags`
    - `req_is_csr`
    - `req_csr_write_enable`
    - `req_csr_addr`
    - `req_csr_wdata`
10. `predictor_update_valid`: Out Event, payload:
    - `predictor_update_branch_pc`
    - `predictor_update_actual_taken`
    - `predictor_update_actual_target`
    - `predictor_update_cf_class`
11. `winner_grant`: In Event, no payload
12. `loser_hold`: In Static Info

## csr_unit

1. `rst_n`: In Static Info
2. `global_flush_late`: In Event, no payload
3. `issue_valid`: In Event, payload:
    - `rs1_data`
    - `FU_Group`
    - `imm_valid`
    - `imm_data`
    - `inst_bits`
    - `self_tag`
    - `exe_subop`
    - `full_decode`
4. `csr_addr`: Out Static Info
5. `csr_rdata`: In Static Info
6. `current_priv`: In Static Info
7. `mstatus_tvm`: In Static Info
8. `fs_enabled`: In Static Info
9. `winner_grant`: In Event, no payload
10. `loser_hold`: In Static Info
11. `FU_ready`: Out Static Info
12. `request_valid`: Out Event, payload:
    - `req_tag`
    - `req_result_data`
    - `req_mispredict_flag`
    - `req_mispredict_target_pc`
    - `req_exception_flag`
    - `req_exception_cause`
    - `req_exception_tval`
    - `req_is_mret`
    - `req_is_sret`
    - `req_fpu_fflags`
    - `req_is_csr`
    - `req_csr_write_enable`
    - `req_csr_addr`
    - `req_csr_wdata`

## div_simple

1. `rst_n`: In Static Info
2. `global_flush_late`: In Event, no payload
3. `issue_valid`: In Event, payload:
    - `rs1_data`
    - `rs2_data`
    - `FU_Group`
    - `self_tag`
    - `exe_subop`
4. `winner_grant`: In Event, no payload
5. `loser_hold`: In Static Info
6. `FU_ready`: Out Static Info
7. `request_valid`: Out Event, payload:
    - `req_tag`
    - `req_result_data`
    - `req_mispredict_flag`
    - `req_mispredict_target_pc`
    - `req_exception_flag`
    - `req_exception_cause`
    - `req_exception_tval`
    - `req_is_mret`
    - `req_is_sret`
    - `req_fpu_fflags`
    - `req_is_csr`
    - `req_csr_write_enable`
    - `req_csr_addr`
    - `req_csr_wdata`

## fpu_simple

1. `rst_n`: In Static Info
2. `global_flush_late`: In Event, no payload
3. `issue_valid`: In Event, payload:
    - `rs1_data`
    - `rs2_data`
    - `rs3_data`
    - `self_tag`
    - `exe_subop`
    - `full_decode`
4. `FU_ready`: Out Static Info
5. `writeback_valid`: Out Event, payload:
    - `tag_out`
    - `result_data`
    - `mispredict_flag`
    - `mispredict_target_pc`
    - `exception_flag`
    - `exception_cause`
    - `exception_tval`
    - `is_mret`
    - `is_sret`
    - `fpu_fflags`
6. `bypass_publish_valid`: Out Event, payload:
    - `bypass_tag`
    - `bypass_data`

## mul_simple

1. `rst_n`: In Static Info
2. `global_flush_late`: In Event, no payload
3. `issue_valid`: In Event, payload:
    - `rs1_data`
    - `rs2_data`
    - `FU_Group`
    - `self_tag`
    - `exe_subop`
4. `winner_grant`: In Event, no payload
5. `loser_hold`: In Static Info
6. `request_valid`: Out Event, payload:
    - `req_tag`
    - `req_result_data`
    - `req_mispredict_flag`
    - `req_mispredict_target_pc`
    - `req_exception_flag`
    - `req_exception_cause`
    - `req_exception_tval`
    - `req_is_mret`
    - `req_is_sret`
    - `req_fpu_fflags`
7. `FU_ready`: Out Static Info

## lsu_bridge

1. `rst_n`: In Static Info
2. `issue_valid`: In Event, payload:
    - `entry_self_tag`
    - `exe_subop`
    - `mem_funct3`
    - `rd_is_fp`
    - `rs1_data`
    - `store_data`
    - `imm_valid`
    - `imm_data`
    - `st_br_resolve`
3. `store_wakeup_valid`: In Event, payload:
    - `store_wakeup_tag`
4. `global_flush_late`: In Event, no payload
5. `lsu_be_issue_ready`: In Static Info
6. `lsu_be_writeback_valid`: In Event, payload:
    - `lsu_be_writeback_pld`
7. `lsu_be_bypass_valid`: In Event, payload:
    - `lsu_be_bypass_pld`
8. `FU_ready`: Out Static Info
9. `writeback_valid`: Out Event, payload:
    - `tag_out`
    - `result_data`
    - `mispredict_flag`
    - `mispredict_target_pc`
    - `exception_flag`
    - `exception_cause`
    - `exception_tval`
    - `is_mret`
    - `is_sret`
    - `fpu_fflags`
10. `bypass_publish_valid`: Out Event, payload:
    - `bypass_tag`
    - `bypass_data`
11. `be_lsu_issue_valid`: Out Event, payload:
    - `be_lsu_issue_pld`
12. `be_lsu_store_wakeup_valid`: Out Event, payload:
    - `be_lsu_store_wakeup_tag`

