# Module `Buffer`

`Buffer`：16-entry、64-bit 结果数据存储，使用 4 个完成写入 lane 和 2 个按 tag 寻址的组合读口（`ROB_DEPTH=16`、`TAG_W=4`、`XLEN=64`、`NUM_LANES=4`、`ISSUE_WIDTH=2`）。

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

1. `entry.payload[t]`：来源于 `Buffer_writeback_payload[g]`；`t∈{0,...,ROB_DEPTH-1}`。
	- `Buffer_writeback_payload[g]`：`result_data[g]`。
	- 更新时机：`rst_n` 下降沿异步清零；`rst_n ∧ writeback_valid[g].fire` 时在 `clk` 上升沿更新对应 entry。
		- `rst_n`：见 `Interface -> In Static Info` 第 1 条。
		- `writeback_valid[g].fire`：见 `Interface -> In-event` 第 1 条的 fire 来源。
		- `g`：`g∈{0,...,NUM_LANES-1}`。
	- Update：`entry.payload[t] <- ¬rst_n ? 0 : (writeback_valid[3].fire ∧ t=tag_out[3]) ? result_data[3] : (writeback_valid[2].fire ∧ t=tag_out[2]) ? result_data[2] : (writeback_valid[1].fire ∧ t=tag_out[1]) ? result_data[1] : (writeback_valid[0].fire ∧ t=tag_out[0]) ? result_data[0] : entry.payload[t]`。
		- `rst_n`：见本条“更新时机”。
		- `writeback_valid[g].fire`：见本条“更新时机”。
		- `tag_out[g]`：见 `Interface -> In-event` 第 1 条 Payload。
		- `result_data[g]`：见本条来源 payload 字段。
		- `entry.payload[t]`：更新前的存储值；无复位或写入条件成立时保持。

## Internal Connections

无。

## Interface

### In-event

1. `writeback_valid[g]`：Notify，`g∈{0,...,NUM_LANES-1}`。
	- Fire来源：`writeback_valid[g].fire`
	- Payload：`Buffer_writeback_payload[g]`；在 `clk` 上升沿采样。
	`Buffer_writeback_payload[g]`：`tag_out[g]` `TAG_W` bit × 1、`result_data[g]` `XLEN` bit × 1。

### In Static Info

1. `rst_n`：1 bit；低有效异步复位；控制 `entry.payload[0:ROB_DEPTH-1]` 的清零。
2. `head_tag[k]`：`TAG_W` bit × `ISSUE_WIDTH`，`k∈{0,...,ISSUE_WIDTH-1}`；当前拍两个组合读口的 entry 地址。

### Out-event

无。

### Out Static Info

1. `commit_data[k]`：`XLEN` bit × `ISSUE_WIDTH`，`k∈{0,...,ISSUE_WIDTH-1}`；当前拍按 `head_tag[k]` 组合读出的结果数据。
	- `commit_data[k] = entry.payload[head_tag[k]].result_data`
		- `head_tag[k]`：见 `Interface -> In Static Info` 第 2 条。
		- `entry.payload[head_tag[k]].result_data`：见 `Data structure -> Payload` 第 1 条。

### Interface Timing

1. `clk`：写入在上升沿采样；`entry.payload` 按 `Data structure -> Payload` 第 1 条更新。
2. `rst_n`：低有效异步复位；`rst_n=0` 时立即将全部 `entry.payload[0:ROB_DEPTH-1]` 清零，复位优先于写入。
3. `Notify`：`writeback_valid[g].fire` 为当前拍通知；payload 仅在对应 fire 为真时于上升沿采样；本模块不提供 ready 或背压。
4. `Static Info`：`head_tag[k]` 和 `commit_data[k]` 为当前拍组合有效；`commit_data[k]` 不由提交有效信号门控，地址变化后同拍反映对应 entry 的值。
