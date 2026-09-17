# Module `ISQ_Group2`

`ISQ_Group2`：`XLEN=64`、`TAG_W=4`、`NUM_LANES=4`、`FP_READ_PORTS=3` 的单 entry FPU issue queue。

## Submodule

1. `FU_input_mux`：`temp/new_v4.1/p2p3/FU_input_mux.md`，实例名 `u_fu_input_mux_rs1`。
2. `FU_input_mux`：`temp/new_v4.1/p2p3/FU_input_mux.md`，实例名 `u_fu_input_mux_rs2`。
3. `FU_input_mux`：`temp/new_v4.1/p2p3/FU_input_mux.md`，实例名 `u_fu_input_mux_rs3`。

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
	- State update：`isq_valid <- 0`；entry payload 和 header 保持。
3. `dispatch`：接收当前拍 `payload_in` 并覆盖写入 entry。
	- Fire来源：`dispatch.fire = dispatch_valid ∧ ¬global_flush_late.fire`
		- `dispatch_valid`：见 `Interface -> In-event` 第 1 条。
		- `global_flush_late.fire`：见 `Interface -> In-event` 第 3 条。
	- Constraint：`dispatch.fire` 与 `issue.fire` 同拍成立时，由 `dispatch` 覆盖写入 entry。
	- Payload：`payload_in`；时钟上升沿采样。
	- State update：`isq_valid <- 1`；`entry.header.rs1_ready <- payload_in.rs1_ready`、`entry.header.rs2_ready <- payload_in.rs2_ready`、`entry.header.rs3_ready <- payload_in.rs3_ready`；`entry.header.rs1_wait_tag <- payload_in.rs1_wait_tag`、`entry.header.rs2_wait_tag <- payload_in.rs2_wait_tag`、`entry.header.rs3_wait_tag <- payload_in.rs3_wait_tag`；`entry.payload.rs1_data <- payload_in.rs1_data`、`entry.payload.rs2_data <- payload_in.rs2_data`、`entry.payload.rs3_data <- payload_in.rs3_data`、`entry.payload.self_tag <- payload_in.self_tag`、`entry.payload.exe_subop <- payload_in.exe_subop`、`entry.payload.full_decode <- payload_in.full_decode`。
4. `issue`：向 FPU 交付当前 entry。
	- Fire来源：`issue.fire = issue_valid ∧ FU_ready`
		- `FU_ready`：见 `Interface -> In Static Info` 第 2 条。
		- `issue_valid = issue_req ∧ ¬global_flush_late.fire`
			- `global_flush_late.fire`：见 `Interface -> In-event` 第 3 条。
			- `issue_req = isq_valid ∧ operand_ready`
				- `isq_valid`：见 `Data structure -> State` 第 1 条。
				- `operand_ready = src_ready[1] ∧ src_ready[2] ∧ src_ready[3]`
					- `src_ready[x] = entry.header.rsX_ready ∨ fast_ready[x]`，`x∈{1,2,3}`。
						- `entry.header.rsX_ready`：见 `Data structure -> Header` 第 1 条。
						- `fast_ready[x] = ¬entry.header.rsX_ready ∧ bypass_hit[x]`
							- `bypass_hit[x] = ∨(b∈{0,...,NUM_LANES-1}): bypass_publish_valid[b].fire ∧ (bypass_tag[b] == entry.header.rsX_wait_tag)`
								- `bypass_publish_valid[b].fire`、`bypass_tag[b]`：见 `Interface -> In-event` 第 2 条。
								- `entry.header.rsX_wait_tag`：见 `Data structure -> Header` 第 2 条。
		- Constraint：`issue_valid` 为不含 `FU_ready` 的组合请求；`issue.fire` 才释放 entry；`global_flush_late` 时不 issue。
	- Payload：`ISQ_Group2_issue_payload`；`issue.fire` 当拍由 FPU 采样。
	- State update：同拍 `dispatch.fire=0` 时 `isq_valid <- 0`；同拍 `dispatch.fire=1` 时由 `dispatch` 覆盖写入新 entry。
5. `bypass_capture`：在未发射的 RESIDENT entry 中保存当前拍旁路命中的源操作数。
	- Fire来源：`bypass_capture.fire = isq_valid ∧ ¬global_flush_late.fire ∧ ¬issue.fire ∧ any_fast_ready`
		- `isq_valid`：见 `Data structure -> State` 第 1 条。
		- `global_flush_late.fire`：见 `Interface -> In-event` 第 3 条。
		- `issue.fire`：见本节第 4 条。
		- `any_fast_ready = fast_ready[1] ∨ fast_ready[2] ∨ fast_ready[3]`
			- `fast_ready[x]`：见本节第 4 条定义。
	- Constraint：`flush`、`dispatch` 和 `issue` 优先；同一 source 多 lane 命中时由 `FU_input_mux` 按 lane 0 至 lane 3 选择数据；`rsX_wait_tag` 不更新。
	- Payload：`u_fu_input_mux_rs1.fu_rsX_data`、`u_fu_input_mux_rs2.fu_rsX_data`、`u_fu_input_mux_rs3.fu_rsX_data`；`bypass_capture.fire` 当拍组合采样。
	- State update：对每个 `x∈{1,2,3}`，`fast_ready[x]=1` 时 `entry.header.rsX_ready <- 1`、`entry.payload.rsX_data <- u_fu_input_mux_rsX.fu_rsX_data`；其他字段保持。

## Data structure

### State

1. `isq_valid`：1 bit；`0=FREE`、`1=RESIDENT`；由 `reset`、`flush`、`dispatch` 和 `issue` 更新。

### Header

1. `entry.header.rs1_ready`、`entry.header.rs2_ready`、`entry.header.rs3_ready`：1 bit × 3；对应 source 的 entry 数据是否 ready；由 `reset`、`dispatch` 和 `bypass_capture` 更新。
2. `entry.header.rs1_wait_tag`、`entry.header.rs2_wait_tag`、`entry.header.rs3_wait_tag`：`TAG_W` bit × 3；未 ready source 等待匹配的 tag；由 `reset` 和 `dispatch` 更新。

### Payload

1. `entry.payload`：来源于 `payload_in` 和 `bypass_capture`。
	- `payload_in`：`rs1_data`、`rs2_data`、`rs3_data`、`self_tag`、`exe_subop`、`full_decode`。
	- `bypass_capture`：`rs1_data`、`rs2_data`、`rs3_data`。

## Internal Connections

1. `entry.payload.rs1_data` -> `u_fu_input_mux_rs1.entry_rsX_data`：`XLEN` bit；组合传递；当前拍有效。
2. `bypass_publish_valid[b]` -> `u_fu_input_mux_rs1.bypass_publish_valid[b]`：1 bit × `NUM_LANES`；当前拍组合传递。
3. `bypass_tag[b]` -> `u_fu_input_mux_rs1.bypass_tag[b]`：`TAG_W` bit × `NUM_LANES`；当前拍组合传递。
4. `bypass_data[b]` -> `u_fu_input_mux_rs1.bypass_data[b]`：`XLEN` bit × `NUM_LANES`；当前拍组合传递。
5. `entry.header.rs1_wait_tag` -> `u_fu_input_mux_rs1.rsX_wait_tag`：`TAG_W` bit；组合传递；当前拍有效。
6. `entry.header.rs1_ready` -> `u_fu_input_mux_rs1.rsX_ready`：1 bit；组合传递；当前拍有效。
7. `entry.payload.rs2_data` -> `u_fu_input_mux_rs2.entry_rsX_data`：`XLEN` bit；组合传递；当前拍有效。
8. `bypass_publish_valid[b]` -> `u_fu_input_mux_rs2.bypass_publish_valid[b]`：1 bit × `NUM_LANES`；当前拍组合传递。
9. `bypass_tag[b]` -> `u_fu_input_mux_rs2.bypass_tag[b]`：`TAG_W` bit × `NUM_LANES`；当前拍组合传递。
10. `bypass_data[b]` -> `u_fu_input_mux_rs2.bypass_data[b]`：`XLEN` bit × `NUM_LANES`；当前拍组合传递。
11. `entry.header.rs2_wait_tag` -> `u_fu_input_mux_rs2.rsX_wait_tag`：`TAG_W` bit；组合传递；当前拍有效。
12. `entry.header.rs2_ready` -> `u_fu_input_mux_rs2.rsX_ready`：1 bit；组合传递；当前拍有效。
13. `entry.payload.rs3_data` -> `u_fu_input_mux_rs3.entry_rsX_data`：`XLEN` bit；组合传递；当前拍有效。
14. `bypass_publish_valid[b]` -> `u_fu_input_mux_rs3.bypass_publish_valid[b]`：1 bit × `NUM_LANES`；当前拍组合传递。
15. `bypass_tag[b]` -> `u_fu_input_mux_rs3.bypass_tag[b]`：`TAG_W` bit × `NUM_LANES`；当前拍组合传递。
16. `bypass_data[b]` -> `u_fu_input_mux_rs3.bypass_data[b]`：`XLEN` bit × `NUM_LANES`；当前拍组合传递。
17. `entry.header.rs3_wait_tag` -> `u_fu_input_mux_rs3.rsX_wait_tag`：`TAG_W` bit；组合传递；当前拍有效。
18. `entry.header.rs3_ready` -> `u_fu_input_mux_rs3.rsX_ready`：1 bit；组合传递；当前拍有效。

## Interface

### In-event

1. `dispatch_valid`：Transaction，单 lane。
	- Fire来源：见 `FSM -> Detailed Condition Description` 第 3 条。
	- Payload：`payload_in` `isq_payload_t` × 1；时钟上升沿采样。
2. `bypass_publish_valid[b]`：Notify，`b∈{0,...,NUM_LANES-1}`。
	- Fire来源：`bypass_publish_valid[b].fire`。
	- Payload：`ISQ_Group2_bypass_payload[b]`；`bypass_publish_valid[b].fire` 当拍组合采样。
	`ISQ_Group2_bypass_payload[b]`：`bypass_tag[b]` `TAG_W` bit × 1、`bypass_data[b]` `XLEN` bit × 1。
3. `global_flush_late`：Notify，单 lane。
	- Fire来源：`global_flush_late.fire`。
	- Payload：∅；`global_flush_late.fire` 仅当前拍有效。

### In Static Info

1. `rst_n`：1 bit；低有效异步复位输入。
2. `FU_ready`：1 bit；FPU 当前拍能否接收 issue；当前拍组合有效。

### Out-event

1. `issue_valid`：Transaction，单 lane。
	- Fire来源：见 `FSM -> Detailed Condition Description` 第 4 条。
	- Payload：`ISQ_Group2_issue_payload`；`issue.fire` 当拍由 FPU 采样。
	`ISQ_Group2_issue_payload`：`rs1_data` `XLEN` bit × 1、`rs2_data` `XLEN` bit × 1、`rs3_data` `XLEN` bit × 1、`self_tag` `TAG_W` bit × 1、`exe_subop` `EXE_SUBOP_W` bit × 1、`full_decode` `FULL_DECODE_W` bit × 1。
		- `rs1_data = u_fu_input_mux_rs1.fu_rsX_data`
			- `u_fu_input_mux_rs1.fu_rsX_data`：见 `FU_input_mux` 的 `Interface -> Out Static Info` 第 1 条。
		- `rs2_data = u_fu_input_mux_rs2.fu_rsX_data`
			- `u_fu_input_mux_rs2.fu_rsX_data`：见 `FU_input_mux` 的 `Interface -> Out Static Info` 第 1 条。
		- `rs3_data = u_fu_input_mux_rs3.fu_rsX_data`
			- `u_fu_input_mux_rs3.fu_rsX_data`：见 `FU_input_mux` 的 `Interface -> Out Static Info` 第 1 条。
		- `self_tag = entry.payload.self_tag`
			- `entry.payload.self_tag`：见 `Data structure -> Payload` 第 1 条。
		- `exe_subop = entry.payload.exe_subop`
			- `entry.payload.exe_subop`：见 `Data structure -> Payload` 第 1 条。
		- `full_decode = entry.payload.full_decode`
			- `entry.payload.full_decode`：见 `Data structure -> Payload` 第 1 条。

### Out Static Info

1. `isq_free_for_dispatch`：1 bit；当前拍可接受 dispatch 的空闲投影；当前拍组合有效。
	- `isq_free_for_dispatch = ¬isq_valid ∨ issue.fire`
		- `isq_valid`：见 `Data structure -> State` 第 1 条。
		- `issue.fire`：见 `FSM -> Detailed Condition Description` 第 4 条。

### Interface Timing

1. `clk`：状态和 entry 字段在上升沿更新。
2. `rst_n`：低有效异步复位；有效时 `isq_valid`、`entry.payload` 及全部 header 字段清零。
3. `Transaction`：`dispatch.fire` 时本模块在上升沿采样 `payload_in`；`issue_valid` 为不含 `FU_ready` 的组合请求，`issue.fire = issue_valid ∧ FU_ready`，fire 当拍由 FPU 采样 payload。
4. `Notify`：`bypass_publish_valid[b]` 和 `global_flush_late` 仅当前拍有效且无本模块背压；`global_flush_late.fire` 当拍取消 `issue_valid`，并在上升沿清除 `isq_valid`。
5. `Static Info`：`FU_ready` 和 `isq_free_for_dispatch` 当前拍组合有效；`isq_free_for_dispatch` 计入同拍 `issue.fire`，允许同拍发射旧 entry 并在上升沿接收新 entry。
