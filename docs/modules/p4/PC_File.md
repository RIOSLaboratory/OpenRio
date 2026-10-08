# Module `PC_File`

`PC_File`：16-entry、64-bit 指令 PC 存储，使用 2 个按 `self_tag` 寻址的写入 lane，以及 1 个恢复读口和 2 个提交 trace 组合读口（`ROB_DEPTH=16`、`TAG_W=4`、`XLEN=64`、`ISSUE_WIDTH=2`）。

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

1. `entry.payload[t]`：来源于 `PC_File_accept_payload[s]`；`t∈{0,...,ROB_DEPTH-1}`。
	- `PC_File_accept_payload[s]`：`pc[s]`。
	- 更新时机：`rst_n` 下降沿异步清零；`rst_n ∧ accept[s].fire` 时在 `clk` 上升沿更新 `self_tag[s]` 指定的 entry。
		- `rst_n`：见 `Interface -> In Static Info` 第 1 条。
		- `accept[s].fire`：见 `Interface -> In-event` 第 1 条的 fire 来源。
		- `s`：`s∈{0,...,ISSUE_WIDTH-1}`。
	- Update：`entry.payload[t] <- ¬rst_n ? 0 : (accept[1].fire ∧ t=self_tag[1]) ? pc[1] : (accept[0].fire ∧ t=self_tag[0]) ? pc[0] : entry.payload[t]`。
		- `rst_n`：见本条“更新时机”。
		- `accept[1].fire`、`accept[0].fire`：见本条“更新时机”。
		- `self_tag[1]`、`self_tag[0]`：见 `Interface -> In-event` 第 1 条 Payload。
		- `pc[1]`、`pc[0]`：见本条来源 payload 字段。
		- `entry.payload[t]`：更新前的存储值；无复位或写入条件成立时保持。

## Internal Connections

无。

## Interface

### In-event

1. `accept[s]`：Notify，`s∈{0,...,ISSUE_WIDTH-1}`。
	- Fire来源：`accept[s].fire`
	- Payload：`PC_File_accept_payload[s]`；在 `clk` 上升沿采样。
	`PC_File_accept_payload[s]`：`self_tag[s]` `TAG_W` bit × 1、`pc[s]` `XLEN` bit × 1。

### In Static Info

1. `rst_n`：1 bit；低有效异步复位；控制 `entry.payload[0:ROB_DEPTH-1]` 的清零。
2. `flush_tag`：`TAG_W` bit；当前拍恢复读口的 entry 地址。
3. `head_tag[k]`：`TAG_W` bit × `ISSUE_WIDTH`，`k∈{0,...,ISSUE_WIDTH-1}`；当前拍提交 trace 读口的 entry 地址。

### Out-event

无。

### Out Static Info

1. `inst_pc`：`XLEN` bit；当前拍按 `flush_tag` 组合读出的指令 PC。
	- `inst_pc = entry.payload[flush_tag].pc`
		- `flush_tag`：见 `Interface -> In Static Info` 第 2 条。
		- `entry.payload[flush_tag].pc`：见 `Data structure -> Payload` 第 1 条。
2. `trace_pc[k]`：`XLEN` bit × `ISSUE_WIDTH`，`k∈{0,...,ISSUE_WIDTH-1}`；当前拍按 `head_tag[k]` 组合读出的提交 trace PC。
	- `trace_pc[k] = entry.payload[head_tag[k]].pc`
		- `head_tag[k]`：见 `Interface -> In Static Info` 第 3 条。
		- `entry.payload[head_tag[k]].pc`：见 `Data structure -> Payload` 第 1 条。

### Interface Timing

1. `clk`：`entry.payload` 在上升沿按 `Data structure -> Payload` 第 1 条更新。
2. `rst_n`：低有效异步复位；`rst_n=0` 时立即将全部 `entry.payload[0:ROB_DEPTH-1]` 清零，复位优先于写入。
3. `Notify`：`accept[s].fire` 为当前拍通知；payload 仅在对应 fire 为真时于上升沿采样；本模块不提供 ready 或背压。
4. `Static Info`：`flush_tag`、`head_tag[k]`、`inst_pc` 和 `trace_pc[k]` 为当前拍组合有效；读出不由事件 valid 门控，地址变化后同拍反映对应 entry 的值。
