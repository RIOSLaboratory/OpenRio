# Module `ISQ_Group0`

`ISQ_Group0`：`XLEN=64`、`TAG_W=4`、`NUM_LANES=4`、`G0_NUM_FU=3` 的单 entry issue queue；组内 FU 编码宽度 `FU_GROUP_W=2`，`0=ALU0/BRU`、`1=CSR`、`2=DIV`。

## Submodule

1. `FU_input_mux`：`temp/new_v4.1/p2p3/FU_input_mux.md`，实例名 `u_fu_input_mux_rs1`。
2. `FU_input_mux`：`temp/new_v4.1/p2p3/FU_input_mux.md`，实例名 `u_fu_input_mux_rs2`。

## FSM

### State

1. `FREE`：entry 无有效指令。
2. `RESIDENT`：entry 保存一条有效指令。

### State Transition & Condition Name

1. `ANY -> FREE`：`reset`
2. `RESIDENT -> FREE`：`flush`
3. `ANY -> RESIDENT`：`dispatch`
4. `RESIDENT -> FREE`：`issue`
5. `RESIDENT -> RESIDENT`：`bypass_capture`

### Detailed Condition Description

1. `reset`：异步复位 entry。
	- Fire来源：`reset.fire = ¬rst_n`
		- `rst_n`：见 `Interface -> In Static Info` 第 1 条。
	- Constraint：低电平异步有效；优先于 `flush`、`dispatch`、`issue` 和 `bypass_capture`。
	- Payload：∅。
	- State update：`isq_valid <- 0`；`entry.payload` 及全部 header 字段清零。
2. `flush`：取消当前 entry 的有效状态。
	- Fire来源：`flush.fire = global_flush_late.fire`
		- `global_flush_late.fire`：见 `Interface -> In-event` 第 3 条。
	- Constraint：优先于 `dispatch`、`issue` 和 `bypass_capture`。
	- Payload：∅。
	- State update：`isq_valid <- 0`；`entry.payload` 及全部 header 字段保持。
3. `dispatch`：接收当前拍 `payload_in` 并覆盖写入 entry。
	- Fire来源：`dispatch.fire = dispatch_valid ∧ ¬global_flush_late.fire`
		- `dispatch_valid`：见 `Interface -> In-event` 第 1 条。
		- `global_flush_late.fire`：见 `Interface -> In-event` 第 3 条。
	- Constraint：上游只在 `isq_free_for_dispatch=1` 时提供 `dispatch_valid`；当 `dispatch.fire` 与 `issue.fire` 同拍成立时，`dispatch` 的 entry 更新优先。
	- Payload：`payload_in`；时钟上升沿采样。
	- State update：`isq_valid <- 1`；`entry.header.rs1_ready <- payload_in.rs1_ready`；`entry.header.rs2_ready <- payload_in.rs2_ready`；`entry.header.rs1_wait_tag <- payload_in.rs1_wait_tag`；`entry.header.rs2_wait_tag <- payload_in.rs2_wait_tag`；`entry.header.fu_group <- payload_in.fu_group`；`entry.payload.rs1_data <- payload_in.rs1_data`；`entry.payload.rs2_data <- payload_in.rs2_data`；`entry.payload.imm_valid <- payload_in.imm_valid`；`entry.payload.imm_data <- payload_in.imm_data`；`entry.payload.pc <- payload_in.pc`；`entry.payload.inst_bits <- payload_in.inst_bits`；`entry.payload.is_compressed <- payload_in.is_compressed`；`entry.payload.pred_taken <- payload_in.pred_taken`；`entry.payload.pred_target_pc <- payload_in.pred_target_pc`；`entry.payload.self_tag <- payload_in.self_tag`；`entry.payload.exe_subop <- payload_in.exe_subop`；`entry.payload.full_decode <- payload_in.full_decode`；`entry.payload.fetch_excp_vld <- payload_in.fetch_excp_vld`；`entry.payload.fetch_excp_cause <- payload_in.fetch_excp_cause`；`entry.payload.fetch_excp_tval <- payload_in.fetch_excp_tval`。
4. `issue`：向 `entry.header.fu_group` 选择的组内 FU 交付当前 entry。
	- Fire来源：`issue.fire = issue_valid ∧ fu_ready_sel`
		- `issue_valid = issue_request ∧ ¬global_flush_late.fire`
			- `issue_request = isq_valid ∧ operand_ready`
				- `isq_valid`：见 `Data structure -> State` 第 1 条。
				- `operand_ready = (entry.header.rs1_ready ∨ fast_ready_rs1) ∧ (entry.header.rs2_ready ∨ fast_ready_rs2)`
					- `entry.header.rs1_ready`、`entry.header.rs2_ready`：见 `Data structure -> Header` 第 1 条。
					- `fast_ready_rs1 = ¬entry.header.rs1_ready ∧ rs1_bypass_hit`
						- `entry.header.rs1_ready`：见 `Data structure -> Header` 第 1 条。
						- `rs1_bypass_hit = ∨(b∈{0,...,NUM_LANES-1}): bypass_publish_valid[b].fire ∧ (bypass_tag[b] == entry.header.rs1_wait_tag)`
							- `bypass_publish_valid[b].fire`、`bypass_tag[b]`：见 `Interface -> In-event` 第 2 条。
							- `entry.header.rs1_wait_tag`：见 `Data structure -> Header` 第 2 条。
					- `fast_ready_rs2 = ¬entry.header.rs2_ready ∧ rs2_bypass_hit`
						- `entry.header.rs2_ready`：见 `Data structure -> Header` 第 1 条。
						- `rs2_bypass_hit = ∨(b∈{0,...,NUM_LANES-1}): bypass_publish_valid[b].fire ∧ (bypass_tag[b] == entry.header.rs2_wait_tag)`
							- `bypass_publish_valid[b].fire`、`bypass_tag[b]`：见 `Interface -> In-event` 第 2 条。
							- `entry.header.rs2_wait_tag`：见 `Data structure -> Header` 第 2 条。
			- `global_flush_late.fire`：见 `Interface -> In-event` 第 3 条。
		- `fu_ready_sel = ((entry.header.fu_group == 0) ∧ FU_ready[0]) ∨ ((entry.header.fu_group == 1) ∧ FU_ready[1]) ∨ ((entry.header.fu_group == 2) ∧ FU_ready[2])`
			- `entry.header.fu_group`：见 `Data structure -> Header` 第 3 条。
			- `FU_ready[k]`：见 `Interface -> In Static Info` 第 2 条。
	- Constraint：`entry.header.fu_group=3` 时 `fu_ready_sel=0`；`issue_valid` 是不含 `FU_ready` 的请求，`issue.fire` 才表示交付成交。
	- Payload：`ISQ_Group0_issue_payload`；`issue.fire` 当拍由所选 FU 采样。
	- State update：同拍 `dispatch.fire=0` 时 `isq_valid <- 0`；同拍 `dispatch.fire=1` 时由 `dispatch` 覆盖写入新 entry。
5. `bypass_capture`：在未发射的 RESIDENT entry 中保存当前拍新就绪的源操作数。
	- Fire来源：`bypass_capture.fire = isq_valid ∧ ¬global_flush_late.fire ∧ ¬issue.fire ∧ (fast_ready_rs1 ∨ fast_ready_rs2)`
		- `isq_valid`：见 `Data structure -> State` 第 1 条。
		- `global_flush_late.fire`：见 `Interface -> In-event` 第 3 条。
		- `issue.fire`：见本节第 4 条。
		- `fast_ready_rs1`、`fast_ready_rs2`：见本节第 4 条 fire。
	- Constraint：上游准入约束保证 `dispatch.fire` 与 `bypass_capture.fire` 不同时成立；同一 source 多 lane 命中时，`FU_input_mux` 按 lane 0 至 lane 3 的优先级选择数据。
	- Payload：`u_fu_input_mux_rs1.fu_rsX_data`、`u_fu_input_mux_rs2.fu_rsX_data`；当前拍组合有效。
	- State update：`fast_ready_rs1=1` 时 `entry.header.rs1_ready <- 1`、`entry.payload.rs1_data <- u_fu_input_mux_rs1.fu_rsX_data`；`fast_ready_rs2=1` 时 `entry.header.rs2_ready <- 1`、`entry.payload.rs2_data <- u_fu_input_mux_rs2.fu_rsX_data`；其他 entry 字段保持。

## Data structure

### State

1. `isq_valid`：1 bit；`0=FREE`、`1=RESIDENT`；由 `reset`、`flush`、`dispatch` 和 `issue` 更新。

### Header

1. `entry.header.rs1_ready`、`entry.header.rs2_ready`：1 bit × 2；对应 source 的 entry 数据是否 ready；由 `reset`、`dispatch` 和 `bypass_capture` 更新。
2. `entry.header.rs1_wait_tag`、`entry.header.rs2_wait_tag`：`TAG_W` bit × 2；未 ready source 等待匹配的 tag；由 `reset` 和 `dispatch` 更新。
3. `entry.header.fu_group`：`FU_GROUP_W` bit；用于选择组内 `FU_ready`；由 `reset` 和 `dispatch` 更新。

### Payload

1. `entry.payload`：来源于 `payload_in` 和 `bypass_capture`。
	- `payload_in`：`rs1_data`、`rs2_data`、`imm_valid`、`imm_data`、`pc`、`inst_bits`、`is_compressed`、`pred_taken`、`pred_target_pc`、`self_tag`、`exe_subop`、`full_decode`、`fetch_excp_vld`、`fetch_excp_cause`、`fetch_excp_tval`。
	- `bypass_capture`：`rs1_data`、`rs2_data`。

## Internal Connections

1. `entry.payload.rs1_data` -> `u_fu_input_mux_rs1.entry_rsX_data`：`XLEN` bit；组合传递；当前拍有效。
2. `bypass_publish_valid[b]` -> `u_fu_input_mux_rs1.bypass_publish_valid[b]`：1 bit × `NUM_LANES`；Notify 组合传递；当前拍有效。
3. `bypass_tag[b]` -> `u_fu_input_mux_rs1.bypass_tag[b]`：`TAG_W` bit × `NUM_LANES`；组合传递；当前拍有效。
4. `bypass_data[b]` -> `u_fu_input_mux_rs1.bypass_data[b]`：`XLEN` bit × `NUM_LANES`；组合传递；当前拍有效。
5. `entry.header.rs1_wait_tag` -> `u_fu_input_mux_rs1.rsX_wait_tag`：`TAG_W` bit；组合传递；当前拍有效。
6. `entry.header.rs1_ready` -> `u_fu_input_mux_rs1.rsX_ready`：1 bit；组合传递；当前拍有效。
7. `entry.payload.rs2_data` -> `u_fu_input_mux_rs2.entry_rsX_data`：`XLEN` bit；组合传递；当前拍有效。
8. `bypass_publish_valid[b]` -> `u_fu_input_mux_rs2.bypass_publish_valid[b]`：1 bit × `NUM_LANES`；Notify 组合传递；当前拍有效。
9. `bypass_tag[b]` -> `u_fu_input_mux_rs2.bypass_tag[b]`：`TAG_W` bit × `NUM_LANES`；组合传递；当前拍有效。
10. `bypass_data[b]` -> `u_fu_input_mux_rs2.bypass_data[b]`：`XLEN` bit × `NUM_LANES`；组合传递；当前拍有效。
11. `entry.header.rs2_wait_tag` -> `u_fu_input_mux_rs2.rsX_wait_tag`：`TAG_W` bit；组合传递；当前拍有效。
12. `entry.header.rs2_ready` -> `u_fu_input_mux_rs2.rsX_ready`：1 bit；组合传递；当前拍有效。

## Interface

### In-event

1. `dispatch_valid`：Transaction，单 lane。
	- Fire来源：见 `FSM -> Detailed Condition Description` 第 3 条。
	- Payload：`payload_in` `isq_payload_t` × 1；时钟上升沿采样。
2. `bypass_publish_valid[b]`：Notify，`b∈{0,...,NUM_LANES-1}`。
	- Fire来源：`bypass_publish_valid[b].fire`。
	- Payload：`ISQ_Group0_bypass_payload[b]`；`bypass_publish_valid[b].fire` 成立的当前拍组合采样。
	`ISQ_Group0_bypass_payload[b]`：`bypass_tag[b]` `TAG_W` bit × 1、`bypass_data[b]` `XLEN` bit × 1。
3. `global_flush_late`：Notify，单 lane。
	- Fire来源：`global_flush_late.fire`。
	- Payload：∅；当前拍 pulse。

### In Static Info

1. `rst_n`：1 bit；低有效异步复位输入。
2. `FU_ready[k]`：1 bit × `G0_NUM_FU`，`k∈{0,...,G0_NUM_FU-1}`；组内 FU 当前拍能否接收 issue；当前拍组合有效。

### Out-event

1. `issue_valid`：Transaction，单 lane。
	- Fire来源：见 `FSM -> Detailed Condition Description` 第 4 条。
	- Payload：`ISQ_Group0_issue_payload`；`issue.fire` 成立的当拍由所选 FU 采样。
	`ISQ_Group0_issue_payload`：`rs1_data` `XLEN` bit × 1、`rs2_data` `XLEN` bit × 1、`FU_Group` `FU_GROUP_W` bit × 1、`imm_valid` 1 bit × 1、`imm_data` `XLEN` bit × 1、`pc` `XLEN` bit × 1、`inst_bits` 32 bit × 1、`is_compressed` 1 bit × 1、`pred_taken` 1 bit × 1、`pred_target_pc` `XLEN` bit × 1、`self_tag` `TAG_W` bit × 1、`exe_subop` `EXE_SUBOP_W` bit × 1、`full_decode` `FULL_DECODE_W` bit × 1、`fetch_excp_vld` 1 bit × 1、`fetch_excp_cause` `FETCH_EXCP_CAUSE_W` bit × 1、`fetch_excp_tval` `XLEN` bit × 1。
		- `rs1_data = u_fu_input_mux_rs1.fu_rsX_data`
			- `u_fu_input_mux_rs1.fu_rsX_data`：见 `FU_input_mux` 的 `Interface -> Out Static Info` 第 1 条。
		- `rs2_data = u_fu_input_mux_rs2.fu_rsX_data`
			- `u_fu_input_mux_rs2.fu_rsX_data`：见 `FU_input_mux` 的 `Interface -> Out Static Info` 第 1 条。
		- `FU_Group = entry.header.fu_group`
			- `entry.header.fu_group`：见 `Data structure -> Header` 第 3 条。
		- `imm_valid = entry.payload.imm_valid`
			- `entry.payload.imm_valid`：见 `Data structure -> Payload` 第 1 条。
		- `imm_data = entry.payload.imm_data`
			- `entry.payload.imm_data`：见 `Data structure -> Payload` 第 1 条。
		- `pc = entry.payload.pc`
			- `entry.payload.pc`：见 `Data structure -> Payload` 第 1 条。
		- `inst_bits = entry.payload.inst_bits`
			- `entry.payload.inst_bits`：见 `Data structure -> Payload` 第 1 条。
		- `is_compressed = entry.payload.is_compressed`
			- `entry.payload.is_compressed`：见 `Data structure -> Payload` 第 1 条。
		- `pred_taken = entry.payload.pred_taken`
			- `entry.payload.pred_taken`：见 `Data structure -> Payload` 第 1 条。
		- `pred_target_pc = entry.payload.pred_target_pc`
			- `entry.payload.pred_target_pc`：见 `Data structure -> Payload` 第 1 条。
		- `self_tag = entry.payload.self_tag`
			- `entry.payload.self_tag`：见 `Data structure -> Payload` 第 1 条。
		- `exe_subop = entry.payload.exe_subop`
			- `entry.payload.exe_subop`：见 `Data structure -> Payload` 第 1 条。
		- `full_decode = entry.payload.full_decode`
			- `entry.payload.full_decode`：见 `Data structure -> Payload` 第 1 条。
		- `fetch_excp_vld = entry.payload.fetch_excp_vld`
			- `entry.payload.fetch_excp_vld`：见 `Data structure -> Payload` 第 1 条。
		- `fetch_excp_cause = entry.payload.fetch_excp_cause`
			- `entry.payload.fetch_excp_cause`：见 `Data structure -> Payload` 第 1 条。
		- `fetch_excp_tval = entry.payload.fetch_excp_tval`
			- `entry.payload.fetch_excp_tval`：见 `Data structure -> Payload` 第 1 条。

### Out Static Info

1. `isq_free_for_dispatch`：1 bit；当前拍可接受 dispatch 的空闲投影；当前拍组合有效。
	- `isq_free_for_dispatch = ¬isq_valid ∨ issue.fire`
		- `isq_valid`：见 `Data structure -> State` 第 1 条。
		- `issue.fire`：见 `FSM -> Detailed Condition Description` 第 4 条。

### Interface Timing

1. `clk`：状态和 entry 字段在上升沿更新。
2. `rst_n`：低有效异步复位；有效时 `isq_valid`、`entry.payload` 及全部 header 字段清零。
3. `Transaction`：`dispatch_valid` 的 ready 已由上游使用 `isq_free_for_dispatch` 完成准入，`dispatch.fire` 时本模块在上升沿采样 `payload_in`；`issue_valid` 保持为不含 `FU_ready` 的组合请求，`issue.fire = issue_valid ∧ fu_ready_sel`，fire 当拍由所选 FU 采样 payload。
4. `Notify`：`bypass_publish_valid[b]` 和 `global_flush_late` 仅当前拍有效且无本模块背压；`global_flush_late.fire` 当拍取消 `issue_valid`，并在上升沿清除 `isq_valid`。
5. `Static Info`：`FU_ready[k]` 和 `isq_free_for_dispatch` 当前拍组合有效；`isq_free_for_dispatch` 计入同拍 `issue.fire`，允许同拍发射旧 entry 并在上升沿接收新 entry。
