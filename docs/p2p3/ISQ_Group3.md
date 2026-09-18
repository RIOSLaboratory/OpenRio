# Module `ISQ_Group3`

`ISQ_Group3`：`XLEN=64`、`TAG_W=4`、`NUM_LANES=4` 的单 entry LSU issue queue；`MEM_FUNCT3_W=3`、`EXE_SUBOP_W=24`。

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
	- State update：`isq_valid <- 0`；`entry.header` 和 `entry.payload` 全部字段清零。
2. `flush`：取消当前 entry 的有效状态。
	- Fire来源：`flush.fire = global_flush_late.fire`
		- `global_flush_late.fire`：见 `Interface -> In-event` 第 3 条。
	- Constraint：优先于 `dispatch`、`issue` 和 `bypass_capture`。
	- Payload：∅。
	- State update：`isq_valid <- 0`；`entry.header` 和 `entry.payload` 保持。
3. `dispatch`：接收当前拍 `payload_in` 并覆盖写入 entry。
	- Fire来源：`dispatch.fire = dispatch_valid ∧ ¬global_flush_late.fire`
		- `dispatch_valid`：见 `Interface -> In-event` 第 1 条。
		- `global_flush_late.fire`：见 `Interface -> In-event` 第 3 条。
	- Constraint：上游只在 `isq_free_for_dispatch=1` 时提供 `dispatch_valid`；当 `dispatch.fire` 与 `issue.fire` 同拍成立时，`dispatch` 的 entry 更新优先。
	- Payload：`payload_in`；时钟上升沿采样。
	- State update：`isq_valid <- 1`；`entry.header.rs1_ready <- payload_in.rs1_ready`；`entry.header.rs2_ready <- payload_in.rs2_ready`；`entry.header.rs1_wait_tag <- payload_in.rs1_wait_tag`；`entry.header.rs2_wait_tag <- payload_in.rs2_wait_tag`；`entry.payload.rs1_data <- payload_in.rs1_data`；`entry.payload.rs2_data <- payload_in.rs2_data`；`entry.payload.imm_valid <- payload_in.imm_valid`；`entry.payload.imm_data <- payload_in.imm_data`；`entry.payload.mem_funct3 <- payload_in.mem_funct3`；`entry.payload.rd_is_fp <- payload_in.rd_is_fp`；`entry.payload.self_tag <- payload_in.self_tag`；`entry.payload.exe_subop <- payload_in.exe_subop`。
4. `issue`：向 LSU 交付当前 entry。
	- Fire来源：`issue.fire = issue_valid ∧ FU_ready`
		- `issue_valid = issue_req ∧ ¬global_flush_late.fire`
			- `issue_req = isq_valid ∧ operand_ready`
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
		- `FU_ready`：见 `Interface -> In Static Info` 第 2 条。
	- Constraint：`issue_valid` 不含 `FU_ready`；只有 `issue.fire` 释放 entry。
	- Payload：`ISQ_Group3_issue_payload`；`issue.fire` 成立的当拍由 LSU 采样。
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

### Payload

1. `entry.payload`：来源于多个 event payload。
	- `payload_in`：`rs1_data`、`rs2_data`、`imm_valid`、`imm_data`、`mem_funct3`、`rd_is_fp`、`self_tag`、`exe_subop`。
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
	- Payload：`ISQ_Group3_bypass_payload[b]`；`bypass_publish_valid[b].fire` 成立的当前拍组合采样。
	`ISQ_Group3_bypass_payload[b]`：`bypass_tag[b]` `TAG_W` bit × 1、`bypass_data[b]` `XLEN` bit × 1。
3. `global_flush_late`：Notify，单 lane。
	- Fire来源：`global_flush_late.fire`。
	- Payload：∅；当前拍 pulse。

### In Static Info

1. `rst_n`：1 bit；低有效异步复位输入。
2. `FU_ready`：1 bit；LSU 当前拍能否接收当前请求；当前拍组合有效。

### Out-event

1. `issue_valid`：Transaction，单 lane。
	- Fire来源：见 `FSM -> Detailed Condition Description` 第 4 条。
	- Payload：`ISQ_Group3_issue_payload`；`issue.fire` 成立的当拍由 LSU 采样。
	`ISQ_Group3_issue_payload`：`rs1_data` `XLEN` bit × 1、`store_data` `XLEN` bit × 1、`imm_valid` 1 bit × 1、`imm_data` `XLEN` bit × 1、`mem_funct3` `MEM_FUNCT3_W` bit × 1、`rd_is_fp` 1 bit × 1、`entry_self_tag` `TAG_W` bit × 1、`exe_subop` `EXE_SUBOP_W` bit × 1。
		- `rs1_data = u_fu_input_mux_rs1.fu_rsX_data`
			- `u_fu_input_mux_rs1.fu_rsX_data`：见 `FU_input_mux` 的 `Interface -> Out Static Info` 第 1 条。
		- `store_data = u_fu_input_mux_rs2.fu_rsX_data`
			- `u_fu_input_mux_rs2.fu_rsX_data`：见 `FU_input_mux` 的 `Interface -> Out Static Info` 第 1 条。
		- `imm_valid = entry.payload.imm_valid`
			- `entry.payload.imm_valid`：见 `Data structure -> Payload` 第 1 条。
		- `imm_data = entry.payload.imm_data`
			- `entry.payload.imm_data`：见 `Data structure -> Payload` 第 1 条。
		- `mem_funct3 = entry.payload.mem_funct3`
			- `entry.payload.mem_funct3`：见 `Data structure -> Payload` 第 1 条。
		- `rd_is_fp = entry.payload.rd_is_fp`
			- `entry.payload.rd_is_fp`：见 `Data structure -> Payload` 第 1 条。
		- `entry_self_tag = entry.payload.self_tag`
			- `entry.payload.self_tag`：见 `Data structure -> Payload` 第 1 条。
		- `exe_subop = entry.payload.exe_subop`
			- `entry.payload.exe_subop`：见 `Data structure -> Payload` 第 1 条。

### Out Static Info

1. `isq_free_for_dispatch`：1 bit；当前拍可接受 dispatch 的空闲投影；当前拍组合有效。
	- `isq_free_for_dispatch = ¬isq_valid ∨ issue.fire`
		- `isq_valid`：见 `Data structure -> State` 第 1 条。
		- `issue.fire`：见 `FSM -> Detailed Condition Description` 第 4 条。
2. `isq_occupied`：1 bit；当前拍 entry 的占用状态，包含发生 `issue.fire` 的当前拍；当前拍组合有效。
	- `isq_occupied = isq_valid`
		- `isq_valid`：见 `Data structure -> State` 第 1 条。

### Interface Timing

1. `clk`：状态和 entry 字段在上升沿更新。
2. `rst_n`：低有效异步复位；有效时 `isq_valid`、`entry.header` 和 `entry.payload` 全部字段清零。
3. `Transaction`：`dispatch_valid` 的 ready 已由上游使用 `isq_free_for_dispatch` 完成准入，`dispatch.fire` 时本模块在上升沿采样 `payload_in`；`issue_valid` 是不含 `FU_ready` 的组合请求，issue payload 不以 `FU_ready` 或 `issue_valid` 选通，`issue.fire = issue_valid ∧ FU_ready`，fire 当拍由 LSU 采样 payload。
4. `Notify`：`bypass_publish_valid[b]` 和 `global_flush_late` 仅当前拍有效且无本模块背压；`global_flush_late.fire` 当拍取消 `issue_valid`，并在上升沿清除 `isq_valid`。
5. `Static Info`：`FU_ready`、`isq_free_for_dispatch` 和 `isq_occupied` 当前拍组合有效；`isq_free_for_dispatch` 计入同拍 `issue.fire`，`isq_occupied` 在该拍仍为 1 并在上升沿后变为 0；RESIDENT entry 的 flush 拍中 `isq_free_for_dispatch=0`、`isq_occupied=1`，上升沿后分别变为 1 和 0。
