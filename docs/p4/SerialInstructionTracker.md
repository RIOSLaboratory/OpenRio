# Module `SerialInstructionTracker`

`SerialInstructionTracker`：单个串行指令在途跟踪器，以一个有效位和一个 `TAG_W` 位 tag 记录当前串行指令（`TAG_W=4`）。

## Submodule

无。

## FSM

### State

1. `IDLE`：`serial_inflight_valid=0`，没有串行指令在途。
2. `INFLIGHT`：`serial_inflight_valid=1`，`serial_inflight_tag` 记录在途串行指令的 tag。

### State Transition & Condition Name

1. `ANY -> IDLE`：`reset`
2. `IDLE -> INFLIGHT`：`serial_set`
3. `INFLIGHT -> IDLE`：`commit_clear`
4. `INFLIGHT -> IDLE`：`flush`

### Detailed Condition Description

1. `reset`：异步复位跟踪状态。
	- Fire来源：`reset.fire = ¬rst_n`
		- `rst_n`：见 `Interface -> In Static Info` 第 1 条。
	- Constraint：低有效异步复位。
	- Payload：∅；复位边沿触发。
	- State update：`serial_inflight_valid <- 0`；`serial_inflight_tag <- 0`。

2. `serial_set`：建立串行指令在途记录。
	- Fire来源：`serial_set.fire = serial_set_valid.fire`
		- `serial_set_valid.fire`：见 `Interface -> In-event` 第 1 条。
	- Constraint：单 lane；`serial_set.fire -> serial_inflight_valid=0`；`reset.fire` 或 `flush.fire` 时状态更新被取消。
	- Payload：`serial_set_tag` `TAG_W` bit × 1；在 `clk` 上升沿采样。
	- State update：`serial_inflight_valid <- 1`；`serial_inflight_tag <- serial_set_tag`。

3. `commit_clear`：匹配在途 tag 的提交事件清除跟踪状态。
	- Fire来源：`commit_clear.fire = serial_inflight_valid ∧ commit_hit`
		- `serial_inflight_valid`：见 `Data structure -> State` 第 1 条。
		- `commit_hit = ∨k∈{0,...,ISSUE_WIDTH-1}: commit_valid[k].fire ∧ (commit_tag[k] == serial_inflight_tag)`
			- `commit_valid[k].fire`：见 `Interface -> In-event` 第 2 条。
			- `commit_tag[k]`：见 `Interface -> In-event` 第 2 条 Payload。
			- `serial_inflight_tag`：见 `Data structure -> Header` 第 1 条。
	- Constraint：`k∈{0,...,ISSUE_WIDTH-1}`；仅 tag 匹配的提交 lane 触发清除；`reset.fire`、`flush.fire` 或 `serial_set.fire` 时状态更新被取消。
	- Payload：∅；当前拍内部事件。
	- State update：`serial_inflight_valid <- 0`；`serial_inflight_tag` 保持。

4. `flush`：在 `INFLIGHT` 状态接收全局 flush，取消串行指令在途记录。
	- Fire来源：`flush.fire = global_flush_late.fire`
		- `global_flush_late.fire`：见 `Interface -> In-event` 第 3 条。
	- Constraint：单 lane、无 payload；`reset.fire` 时状态更新被取消；优先于 `serial_set` 和 `commit_clear`。
	- Payload：∅；当前拍 pulse。
	- State update：`serial_inflight_valid <- 0`；`serial_inflight_tag` 保持。

## Data structure

### State

1. `serial_inflight_valid`：1 bit；`0` 表示 `IDLE`，`1` 表示 `INFLIGHT`；由 `reset` 清零、`serial_set` 置 1、`commit_clear` 或 `flush` 清 0。

### Header

1. `serial_inflight_tag`：`TAG_W` bit；与 `commit_tag[k]` 比较以识别在途串行指令；由 `reset` 清零、`serial_set` 写入 `serial_set_tag`，`commit_clear` 和 `flush` 时保持。

### Payload

无。

## Internal Connections

无。

## Interface

### In-event

1. `serial_set_valid`：Notify，单 lane。
	- Fire来源：`serial_set_valid.fire`
	- Payload：`serial_set_tag` `TAG_W` bit × 1；在 `clk` 上升沿采样。
2. `commit_valid[k]`：Notify，`k∈{0,...,ISSUE_WIDTH-1}`。
	- Fire来源：`commit_valid[k].fire`
	- Payload：`commit_tag[k]` `TAG_W` bit × 1；在 `clk` 上升沿采样。
3. `global_flush_late`：Notify，单 lane。
	- Fire来源：`global_flush_late.fire`
	- Payload：∅；当前拍 pulse。

### In Static Info

1. `rst_n`：1 bit；低有效异步复位；控制 `serial_inflight_valid` 和 `serial_inflight_tag` 的复位值。

### Out-event

无。

### Out Static Info

1. `serial_inflight_valid`：1 bit；当前拍串行指令在途状态。
	- 见 `Data structure -> State` 第 1 条。

### Interface Timing

1. `clk`：同步状态更新在上升沿采样。
2. `rst_n`：低有效异步复位；下降沿立即清零 `serial_inflight_valid` 和 `serial_inflight_tag`，复位优先级最高。
3. `Notify`：`serial_set_valid`、`commit_valid[k]` 和 `global_flush_late` 为当前拍事件；payload 在对应事件有效时于 `clk` 上升沿采样；不提供 ready 或背压；同步更新优先级为 `flush` 高于 `serial_set`、`serial_set` 高于 `commit_clear`。
4. `Static Info`：`serial_inflight_valid` 在整拍内持续反映寄存器状态；`rst_n=0` 时其值为 0。
