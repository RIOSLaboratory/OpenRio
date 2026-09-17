# Module `dispatch_logic`

`dispatch_logic`：`ISSUE_WIDTH`-slot、`NUM_LANES`-ISQ-group 的纯组合 dispatch 准入、动态非法检查、ISQ 选组和 group 内 FU 编号模块。

## Submodule

无。

## FSM

### State

无。

### State Transition & Condition Name

无。

### Detailed Condition Description

无。

## Data structure

### State

无。

### Header

无。

### Payload

无。

## Internal Connections

无。

## Interface

### In-event

1. `global_flush_late`：Notify，单 lane。
	- Fire来源：`global_flush_late.fire`。
	- Payload：`∅`；当前拍 pulse。

### In Static Info

1. `inst_valid[s]`：1 bit × `ISSUE_WIDTH`，`s∈{0,1}`；当前拍 slot `s` 是否存在有效候选。
2. `serial0`：1 bit；当前拍 slot0 是否为 serial 指令。
3. `serial_inst`：1 bit；当前拍两个候选中是否存在 serial 指令。
4. `fp0`：1 bit；当前拍 slot0 的 FP opcode 属性。
5. `fp1`：1 bit；当前拍 slot1 的 FP opcode 属性。
6. `slot_missed_wakeup[s]`：1 bit × `ISSUE_WIDTH`；当前拍 slot `s` 是否存在 missed-wakeup。
7. `exe_subop[s]`：`EXE_SUBOP_W` bit × `ISSUE_WIDTH`；当前拍 slot `s` 的执行子操作编码。
8. `full_decode[s]`：`full_decode_t` × `ISSUE_WIDTH`；本模块当前拍读取字段为 `illegal` 1 bit、`rm` `rm_e`。
9. `is_fp_instruction[s]`：1 bit × `ISSUE_WIDTH`；当前拍 slot `s` 是否为 FP 指令，包含 FP load/store。
10. `fs_enabled`：1 bit；当前拍 architectural `mstatus.FS != Off`。
11. `frm`：`rm_e`；当前拍 architectural rounding mode。
12. `can_alloc_1`：1 bit；拍初 CompletionScoreboard 是否至少可分配 1 个 entry。
13. `can_alloc_2`：1 bit；拍初 CompletionScoreboard 是否至少可分配 2 个 entry。
14. `buffer_empty`：1 bit；拍初 CompletionScoreboard 是否为空。
15. `isq_free_for_dispatch[g]`：1 bit × `NUM_LANES`，`g∈{0,...,NUM_LANES-1}`；当前拍 group `g` 是否可接收 dispatch，已计入同拍 issue。
16. `serial_inflight_valid`：1 bit；当前拍是否已有 serial 指令在飞。
17. `self_tag`：`TAG_W` bit；当前拍 slot 0 分配的 CompletionScoreboard tag。

### Out-event

1. `accept[0]`：Notify，slot0。
	- Fire来源：`accept[0].fire = inst_valid[0] ∧ slot0_guard_ok`。
		- `inst_valid[0]`：见 `Interface -> In Static Info` 第 1 条。
		- `slot0_guard_ok = subop_supported_now[0] ∧ can_alloc_1 ∧ isq_free_for_dispatch[slot_ISQGroup[0]] ∧ ¬serial_inflight_valid ∧ serial0_ok ∧ ¬slot_missed_wakeup[0] ∧ ¬global_flush_late.fire`。
			- `subop_supported_now[0] = (dispatch_route_class[0] != ROUTE_UNSUPPORTED)`。
				- `dispatch_route_class[s]`：`dispatch_route_class_e`，4 bit，`s∈{0,1}`；`ROUTE_ALU=4'd0`、`ROUTE_BRU=4'd1`、`ROUTE_CSR=4'd2`、`ROUTE_DIV=4'd3`、`ROUTE_MUL=4'd4`、`ROUTE_FPU=4'd5`、`ROUTE_LSU=4'd6`、`ROUTE_ATOMIC=4'd7`、`ROUTE_FENCE=4'd8`、`ROUTE_SYS=4'd9`、`ROUTE_UNSUPPORTED=4'd10`；`dispatch_route_class[s] = case(illegal_effective[s]: ROUTE_BRU; exe_subop[s] == SUBOP_INVALID: ROUTE_UNSUPPORTED; is_g3_atomic_subop(exe_subop[s]): ROUTE_ATOMIC; is_g3_fence_subop(exe_subop[s]): ROUTE_FENCE; is_g3_lsu_subop(exe_subop[s]): ROUTE_LSU; is_g0_sys_subop(exe_subop[s]): ROUTE_SYS; is_g0_csr_subop(exe_subop[s]): ROUTE_CSR; is_g0_div_subop(exe_subop[s]): ROUTE_DIV; is_g1_mul_subop(exe_subop[s]): ROUTE_MUL; is_g2_fpu_subop(exe_subop[s]): ROUTE_FPU; is_g0_bru_subop(exe_subop[s]): ROUTE_BRU; is_g0_alu0_subop(exe_subop[s]): ROUTE_ALU; default: ROUTE_UNSUPPORTED)`，按列出顺序 first-hit。
					- `illegal_effective[s] = full_decode[s].illegal ∨ fp_illegal[s]`。
						- `full_decode[s].illegal`：见 `Interface -> In Static Info` 第 8 条。
						- `fp_illegal[s] = is_fp_instruction[s] ∧ (¬fs_enabled ∨ rm_illegal[s])`。
							- `is_fp_instruction[s]`：见 `Interface -> In Static Info` 第 9 条。
							- `fs_enabled`：见 `Interface -> In Static Info` 第 10 条。
							- `rm_illegal[s] = uses_rm(exe_subop[s]) ∧ (rm_is_reserved(full_decode[s].rm) ∨ ((full_decode[s].rm == RM_DYN) ∧ frm_illegal))`。
								- `uses_rm(exe_subop[s])`：当 `exe_subop[s]` 属于 `{SUBOP_FADD_S, SUBOP_FSUB_S, SUBOP_FMUL_S, SUBOP_FDIV_S, SUBOP_FSQRT_S, SUBOP_FADD_D, SUBOP_FSUB_D, SUBOP_FMUL_D, SUBOP_FDIV_D, SUBOP_FSQRT_D, SUBOP_FMADD_S, SUBOP_FMSUB_S, SUBOP_FNMSUB_S, SUBOP_FNMADD_S, SUBOP_FMADD_D, SUBOP_FMSUB_D, SUBOP_FNMSUB_D, SUBOP_FNMADD_D, SUBOP_FCVT_W_S, SUBOP_FCVT_WU_S, SUBOP_FCVT_L_S, SUBOP_FCVT_LU_S, SUBOP_FCVT_W_D, SUBOP_FCVT_WU_D, SUBOP_FCVT_L_D, SUBOP_FCVT_LU_D, SUBOP_FCVT_S_W, SUBOP_FCVT_S_WU, SUBOP_FCVT_S_L, SUBOP_FCVT_S_LU, SUBOP_FCVT_D_W, SUBOP_FCVT_D_WU, SUBOP_FCVT_D_L, SUBOP_FCVT_D_LU, SUBOP_FCVT_S_D, SUBOP_FCVT_D_S}` 时为 1，否则为 0。
									- `exe_subop[s]`：见 `Interface -> In Static Info` 第 7 条。
								- `rm_is_reserved(full_decode[s].rm) = (full_decode[s].rm == RM_RSV5) ∨ (full_decode[s].rm == RM_RSV6)`。
									- `full_decode[s].rm`：见 `Interface -> In Static Info` 第 8 条。
								- `full_decode[s].rm == RM_DYN`。
									- `full_decode[s].rm`：见 `Interface -> In Static Info` 第 8 条。
								- `frm_illegal = (frm == RM_RSV5) ∨ (frm == RM_RSV6) ∨ (frm == RM_DYN)`。
									- `frm`：见 `Interface -> In Static Info` 第 11 条。
					- `exe_subop[s]`：见 `Interface -> In Static Info` 第 7 条。
					- `is_g3_atomic_subop(exe_subop[s])`：按冻结 atomic 子操作集合分类。
						- `exe_subop[s]`：见 `Interface -> In Static Info` 第 7 条。
					- `is_g3_fence_subop(exe_subop[s])`：按冻结 fence 子操作集合分类。
						- `exe_subop[s]`：见 `Interface -> In Static Info` 第 7 条。
					- `is_g3_lsu_subop(exe_subop[s])`：按冻结 LSU 子操作集合分类。
						- `exe_subop[s]`：见 `Interface -> In Static Info` 第 7 条。
					- `is_g0_sys_subop(exe_subop[s])`：按冻结 system 子操作集合分类。
						- `exe_subop[s]`：见 `Interface -> In Static Info` 第 7 条。
					- `is_g0_csr_subop(exe_subop[s])`：按冻结 CSR 子操作集合分类。
						- `exe_subop[s]`：见 `Interface -> In Static Info` 第 7 条。
					- `is_g0_div_subop(exe_subop[s])`：按冻结 divide 子操作集合分类。
						- `exe_subop[s]`：见 `Interface -> In Static Info` 第 7 条。
					- `is_g1_mul_subop(exe_subop[s])`：按冻结 multiply 子操作集合分类。
						- `exe_subop[s]`：见 `Interface -> In Static Info` 第 7 条。
					- `is_g2_fpu_subop(exe_subop[s])`：按冻结 FPU 子操作集合分类。
						- `exe_subop[s]`：见 `Interface -> In Static Info` 第 7 条。
					- `is_g0_bru_subop(exe_subop[s])`：按冻结 branch 子操作集合分类。
						- `exe_subop[s]`：见 `Interface -> In Static Info` 第 7 条。
					- `is_g0_alu0_subop(exe_subop[s])`：按冻结 G0 ALU 子操作集合分类。
						- `exe_subop[s]`：见 `Interface -> In Static Info` 第 7 条。
			- `can_alloc_1`：见 `Interface -> In Static Info` 第 12 条。
			- `isq_free_for_dispatch[slot_ISQGroup[0]]`：见 `Interface -> In Static Info` 第 15 条。
				- `slot_ISQGroup[0] = ((dispatch_route_class[0] == ROUTE_ALU) ∧ alu_g1_capable[0]) ? (isq_free_for_dispatch[GRP_G0] ? GRP_G0 : GRP_G1) : fixed_group[0]`；`ISQ_GROUP_W=$clog2(NUM_LANES)` bit，`GRP_G0=ISQ_GROUP_W'(0)`、`GRP_G1=ISQ_GROUP_W'(1)`、`GRP_G2=ISQ_GROUP_W'(2)`、`GRP_G3=ISQ_GROUP_W'(3)`。
					- `dispatch_route_class[0]`：见本条 `subop_supported_now[0]`。
					- `alu_g1_capable[0] = is_g1_alu1_subop(exe_subop[0])`。
						- `exe_subop[0]`：见 `Interface -> In Static Info` 第 7 条。
					- `isq_free_for_dispatch[GRP_G0]`：见 `Interface -> In Static Info` 第 15 条。
					- `fixed_group[s] = case(dispatch_route_class[s] == ROUTE_MUL: GRP_G1; dispatch_route_class[s] == ROUTE_FPU: GRP_G2; dispatch_route_class[s] inside {ROUTE_LSU, ROUTE_ATOMIC, ROUTE_FENCE}: GRP_G3; default: GRP_G0)`。
						- `dispatch_route_class[s]`：见本条 `subop_supported_now[0]`。
			- `serial_inflight_valid`：见 `Interface -> In Static Info` 第 16 条。
			- `serial0_ok = ¬serial0 ∨ buffer_empty`。
				- `serial0`：见 `Interface -> In Static Info` 第 2 条。
				- `buffer_empty`：见 `Interface -> In Static Info` 第 14 条。
			- `slot_missed_wakeup[0]`：见 `Interface -> In Static Info` 第 6 条。
			- `global_flush_late.fire`：见 `Interface -> In-event` 第 1 条。
	- Constraint：`global_flush_late.fire` 时不 fire。
	- Payload：`∅`；当前拍 pulse。

2. `accept[1]`：Notify，slot1。
	- Fire来源：`accept[1].fire = accept[0].fire ∧ inst_valid[1] ∧ slot1_guard_ok`。
		- `accept[0].fire`：见本节第 1 条。
		- `inst_valid[1]`：见 `Interface -> In Static Info` 第 1 条。
		- `slot1_guard_ok = subop_supported_now[1] ∧ can_alloc_2 ∧ isq_free_for_dispatch[slot_ISQGroup[1]] ∧ groups_distinct ∧ ¬(fp0 ∧ fp1) ∧ ¬serial_inst ∧ ¬slot_missed_wakeup[1] ∧ ¬global_flush_late.fire`。
			- `subop_supported_now[1]`：见本节第 1 条 `subop_supported_now[0]`，slot 索引取 1。
			- `can_alloc_2`：见 `Interface -> In Static Info` 第 13 条。
			- `isq_free_for_dispatch[slot_ISQGroup[1]]`：见 `Interface -> In Static Info` 第 15 条。
				- `slot_ISQGroup[1] = ((dispatch_route_class[1] == ROUTE_ALU) ∧ alu_g1_capable[1]) ? ((isq_free_for_dispatch[GRP_G0] ∧ ¬slot0_takes_G0) ? GRP_G0 : GRP_G1) : fixed_group[1]`。
					- `dispatch_route_class[1]`：见本节第 1 条 `dispatch_route_class[s]`。
					- `alu_g1_capable[1]`：见本节第 1 条 `alu_g1_capable[0]` 的定义，slot 索引取 1。
					- `isq_free_for_dispatch[GRP_G0]`：见 `Interface -> In Static Info` 第 15 条。
					- `slot0_takes_G0 = accept[0].fire ∧ (slot_ISQGroup[0] == GRP_G0)`。
						- `accept[0].fire`：见本节第 1 条。
						- `slot_ISQGroup[0]`：见本节第 1 条。
					- `fixed_group[1]`：见本节第 1 条 `fixed_group[s]`。
			- `groups_distinct = (slot_ISQGroup[1] != slot_ISQGroup[0])`。
				- `slot_ISQGroup[1]`：见本条定义。
				- `slot_ISQGroup[0]`：见本节第 1 条。
			- `fp0`：见 `Interface -> In Static Info` 第 4 条。
			- `fp1`：见 `Interface -> In Static Info` 第 5 条。
			- `serial_inst`：见 `Interface -> In Static Info` 第 3 条。
			- `slot_missed_wakeup[1]`：见 `Interface -> In Static Info` 第 6 条。
			- `global_flush_late.fire`：见 `Interface -> In-event` 第 1 条。
	- Constraint：`accept[1].fire -> accept[0].fire`；`accept[1:0]` 只可为 `00`、`01`、`11`；`global_flush_late.fire` 时不 fire。
	- Payload：`∅`；当前拍 pulse。

3. `isq_wr_en[g]`：Notify，`g∈{0,...,NUM_LANES-1}`。
	- Fire来源：`isq_wr_en[g].fire = select_payload[g][0] ∨ select_payload[g][1]`。
		- `select_payload[g][0]`：见 `Interface -> Out Static Info` 第 6 条。
		- `select_payload[g][1]`：见 `Interface -> Out Static Info` 第 6 条。
	- Constraint：每个 `g` 的 `select_payload[g][1:0]` 为 onehot0；`global_flush_late.fire` 时不 fire。
	- Payload：`∅`；当前拍 pulse。

4. `serial_set_valid`：Notify，单 lane。
	- Fire来源：`serial_set_valid.fire = accept[0].fire ∧ serial0`。
		- `accept[0].fire`：见本节第 1 条。
		- `serial0`：见 `Interface -> In Static Info` 第 2 条。
	- Constraint：仅 slot0 可产生；无背压；`global_flush_late.fire` 时不 fire。
	- Payload：`serial_set_tag`，`TAG_W` bit × 1；当前拍 pulse。
		- `serial_set_tag = self_tag`。
			- `self_tag`：见 `Interface -> In Static Info` 第 17 条。

### Out Static Info

1. `slot_FU_Group[s]`：`FU_GROUP_W` bit × `ISSUE_WIDTH`，`s∈{0,1}`；当前拍 group 内 FU 编号。
	- `slot_FU_Group[s] = (dispatch_route_class[s] inside {ROUTE_CSR, ROUTE_MUL}) ? FU_GROUP_W'(1) : (dispatch_route_class[s] == ROUTE_DIV) ? FU_GROUP_W'(2) : FU_GROUP_W'(0)`。
		- `dispatch_route_class[s]`：见 `Interface -> Out-event` 第 1 条。
2. `effective_rm[s]`：`rm_e` × `ISSUE_WIDTH`；当前拍 slot `s` 的有效 rounding mode。
	- `effective_rm[s] = (full_decode[s].rm == RM_DYN) ? frm : full_decode[s].rm`。
		- `full_decode[s].rm`：见 `Interface -> In Static Info` 第 8 条。
		- `frm`：见 `Interface -> In Static Info` 第 11 条。
3. `is_fence_i[s]`：1 bit × `ISSUE_WIDTH`；当前拍 slot `s` 是否为 `FENCE.I`。
	- `is_fence_i[s] = (exe_subop[s] == SUBOP_FENCEI)`。
		- `exe_subop[s]`：见 `Interface -> In Static Info` 第 7 条。
4. `may_flush[s]`：1 bit × `ISSUE_WIDTH`；当前拍 slot `s` 是否可能在 resolution 前触发恢复。
	- `may_flush[s] = may_flush_before_resolution(exe_subop[s], illegal_effective[s])`。
		- `exe_subop[s]`：见 `Interface -> In Static Info` 第 7 条。
		- `illegal_effective[s]`：见 `Interface -> Out-event` 第 1 条。
5. `is_atomic[s]`：1 bit × `ISSUE_WIDTH`；当前拍 slot `s` 是否为 LR、SC 或 AMO 子操作。
	- `is_atomic[s] = is_g3_atomic_subop(exe_subop[s])`。
		- `exe_subop[s]`：见 `Interface -> In Static Info` 第 7 条。
6. `select_payload[g][s]`：1 bit × `NUM_LANES` × `ISSUE_WIDTH`，`g∈{0,...,NUM_LANES-1}`、`s∈{0,1}`；当前拍 group `g` 对已准入 slot 的 payload 选择。
	- `select_payload[g][s] = accept[s].fire ∧ (slot_ISQGroup[s] == ISQ_GROUP_W'(g))`。
		- `accept[s].fire`：见 `Interface -> Out-event` 第 1、2 条。
		- `slot_ISQGroup[s]`：`s=0` 时见 `Interface -> Out-event` 第 1 条，`s=1` 时见第 2 条。

### Interface Timing

1. `clk`：无时钟；本模块全部逻辑为当前拍组合逻辑。
2. `rst_n`：无复位；本模块无状态或存储。
3. `Transaction`：无。
4. `Notify`：`global_flush_late`、`accept[s]`、`isq_wr_en[g]` 和 `serial_set_valid` 均为当前拍 pulse，无 valid/ready、背压或保持；消费者在当前拍采样。`global_flush_late.fire` 取消当前拍全部 `accept[s]`，并通过组合依赖取消 `isq_wr_en[g]` 和 `serial_set_valid`。
5. `Static Info`：所有输入与输出均在当前拍组合有效，下一拍随输入重新计算；`slot_FU_Group[s]`、`effective_rm[s]`、`is_fence_i[s]`、`may_flush[s]` 和 `is_atomic[s]` 不由 `accept[s].fire` 门控；`select_payload[g][s]` 只对已准入 slot 置位，每个 group 的选择为 onehot0。
