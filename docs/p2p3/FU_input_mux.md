# Module `FU_input_mux`

`FU_input_mux`：无状态的组合操作数选择模块，按 ready 和旁路命中结果产生一个 FU 输入数据；`XLEN=64`、`TAG_W=4`、`NUM_LANES=4`。

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

1. `bypass_publish_valid[b]`：Notify，`b∈{0,...,NUM_LANES-1}`。
	- Fire来源：`bypass_publish_valid[b].fire`。
	- Payload：`FU_input_mux_bypass_payload[b]`；`bypass_publish_valid[b].fire` 成立的当前拍组合采样。
	`FU_input_mux_bypass_payload[b]`：`bypass_tag[b]` `TAG_W` bit × 1、`bypass_data[b]` `XLEN` bit × 1。

### In Static Info

1. `entry_rsX_data`：`XLEN` bit；当前 source 在 entry 中保存的数据；组合选择的默认输出。
2. `rsX_wait_tag`：`TAG_W` bit；当前 source 等待匹配的 tag；用于旁路命中比较。
3. `rsX_ready`：1 bit；当前 source 的 entry 数据是否 ready；为 1 时优先选择 `entry_rsX_data`。

### Out-event

无。

### Out Static Info

1. `fu_rsX_data`：`XLEN` bit；当前拍组合产生的 FU 输入数据。
	- `fu_rsX_data = rsX_ready ? entry_rsX_data : (hit[0] ? bypass_data[0] : (hit[1] ? bypass_data[1] : (hit[2] ? bypass_data[2] : (hit[3] ? bypass_data[3] : entry_rsX_data))))`
		- `rsX_ready`：见 `Interface -> In Static Info` 第 3 条。
		- `entry_rsX_data`：见 `Interface -> In Static Info` 第 1 条。
		- `hit[b]`：`b∈{0,...,NUM_LANES-1}`；当前拍旁路 lane `b` 是否命中。
			- `hit[b] = bypass_publish_valid[b] ∧ (rsX_wait_tag == bypass_tag[b])`
				- `bypass_publish_valid[b]`：见 `Interface -> In-event` 第 1 条 payload。
				- `rsX_wait_tag`：见 `Interface -> In Static Info` 第 2 条。
				- `bypass_tag[b]`：见 `Interface -> In-event` 第 1 条 payload。
		- `bypass_data[b]`：见 `Interface -> In-event` 第 1 条 payload；`b∈{0,...,NUM_LANES-1}`。

### Interface Timing

1. `clk`：无时钟；所有输入和 `fu_rsX_data` 均为当前拍组合信号。
2. `rst_n`：无复位端口；本模块无复位行为。
3. `Transaction`：无。
4. `Notify`：`bypass_publish_valid[b]` 及其 payload 在当前拍组合有效时被本模块使用；无本模块 fire 握手和背压。
5. `Static Info`：`entry_rsX_data`、`rsX_wait_tag`、`rsX_ready` 和 `fu_rsX_data` 在当前拍组合有效；当 `rsX_ready=1` 时旁路命中不改变输出，当 `rsX_ready=0` 时按 lane 0 至 lane 3 的优先级选择首个命中旁路数据，全部未命中时输出 `entry_rsX_data`。
