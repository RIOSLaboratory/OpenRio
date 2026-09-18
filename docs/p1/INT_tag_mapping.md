# Module `INT_tag_mapping`

`INT_tag_mapping`：32-entry 整数寄存器重命名映射表（`NUM_GPR=32`、`REG_ADDR_W=5`、`TAG_W=4`、`ISSUE_WIDTH=2`、`INT_SRC_PER_SLOT=2`），为两个 slot 的 `rs1/rs2` 提供 4 个组合读口。

## Submodule

无。

## FSM

### State

1. `IDLE`：对应 entry 的 `entry_busy=0`，不存在有效的整数 producer。
2. `BUSY`：对应 entry 的 `entry_busy=1`，存在有效的整数 producer，producer tag 保存在 `entry_tag`。

### State Transition & Condition Name

1. `ANY -> IDLE`：`reset`。
2. `ANY -> IDLE`：`flush`。
3. `IDLE -> BUSY`：`alloc[s]`。
4. `BUSY -> IDLE`：`commit_clear[k]`。

### Detailed Condition Description

1. `reset`：复位全部整数寄存器映射 entry。
	- Fire来源：`reset.fire = ¬rst_n`
		- `rst_n`：低有效复位输入，见 `Interface -> In Static Info` 第 1 条。
	- Constraint：异步复位；复位优先于其他动作。
	- Payload：`∅`；复位有效时立即生效。
	- State update：对所有 `i∈{0,...,NUM_GPR-1}`，`entry_busy[i] <- 0`，`entry_tag[i] <- 0`。
2. `flush`：清除所有整数 producer 的 busy 状态。
	- Fire来源：`flush.fire = global_flush_late.fire`
		- `global_flush_late.fire`：见 `Interface -> In-event` 第 3 条。
	- Constraint：复位释放后在时钟上升沿执行；状态更新在 `commit_clear[k]` 和 `alloc[s]` 之后执行并覆盖其对 `entry_busy` 的更新；entry 0 保持硬连值。
	- Payload：`∅`；当拍 pulse。
	- State update：对所有 `i∈{1,...,NUM_GPR-1}`，`entry_busy[i] <- 0`；flush 不更新 `entry_tag[i]`，同拍 `alloc[s]` 仍可更新非零 entry 的 `entry_tag`；flush 不更新 entry 0，其 `entry_busy[0]=0`、`entry_tag[0]=0`。
3. `alloc[s]`：接收 slot `s` 的整数 destination 重命名请求。
	- Fire来源：`alloc[s].fire = accept[s].fire ∧ alloc_rd_write_enable[s] ∧ ¬alloc_rd_is_fp[s] ∧ (alloc_rd_idx[s] != 0)`
		- `accept[s].fire`：见 `Interface -> In-event` 第 1 条。
		- `alloc_rd_write_enable[s]`：见 `Interface -> In-event` 第 1 条 Payload。
		- `alloc_rd_is_fp[s]`：见 `Interface -> In-event` 第 1 条 Payload。
		- `alloc_rd_idx[s]`：见 `Interface -> In-event` 第 1 条 Payload。
	- Constraint：`s∈{0,...,ISSUE_WIDTH-1}`；`alloc[s]` 在目标 entry 为 `IDLE` 或 `BUSY` 时均可 fire；不同 entry 的 alloc 与 commit clear 可同时生效；状态更新在 `commit_clear[k]` 之后执行，同一 entry 的 alloc 覆盖 clear；`alloc` 按 `s` 从 0 到 1 写入，同一 entry 的 slot1 写入覆盖 slot0；同拍 flush 覆盖 alloc 对 `entry_busy` 的更新，但不覆盖 alloc 对 `entry_tag` 的更新；entry 0 不被写入。
	- Payload：`INT_tag_mapping_alloc_payload[s]`；时钟上升沿采样。
		- `INT_tag_mapping_alloc_payload[s]`：`self_tag[s]` `TAG_W` bit × 1、`alloc_rd_idx[s]` `REG_ADDR_W` bit × 1、`alloc_rd_is_fp[s]` 1 bit × 1、`alloc_rd_write_enable[s]` 1 bit × 1。
	- State update：对每个 fire 的 `s`，`entry_busy[alloc_rd_idx[s]] <- 1`，`entry_tag[alloc_rd_idx[s]] <- self_tag[s]`；目标 entry 原为 `BUSY` 时状态保持 `BUSY` 并替换 tag；未命中的 entry 不由 `alloc[s]` 更新。
4. `commit_clear[k]`：提交 tag 与当前 entry tag 匹配时清除整数 producer busy 状态。
	- Fire来源：`commit_clear[k].fire = commit_valid[k].fire ∧ commit_rd_write_enable[k] ∧ ¬commit_rd_is_fp[k] ∧ (commit_rd_idx[k] != 0) ∧ (entry_tag[commit_rd_idx[k]] == commit_tag[k])`
		- `commit_valid[k].fire`：见 `Interface -> In-event` 第 2 条。
		- `commit_rd_write_enable[k]`：见 `Interface -> In-event` 第 2 条 Payload。
		- `commit_rd_is_fp[k]`：见 `Interface -> In-event` 第 2 条 Payload。
		- `commit_rd_idx[k]`：见 `Interface -> In-event` 第 2 条 Payload。
		- `entry_tag[commit_rd_idx[k]]`：当前 entry 的 producer tag，见 `Data structure -> Header` 第 1 条。
		- `commit_tag[k]`：见 `Interface -> In-event` 第 2 条 Payload。
	- Constraint：`k∈{0,...,ISSUE_WIDTH-1}`；fire 条件不检查 `entry_busy`，目标 entry 为 `IDLE` 且 tag 匹配时仍可 fire；tag 不匹配时不清除；entry 0 不被写入；同拍 `alloc[s]` 在本事件之后执行并可覆盖同一 entry 的 clear，同拍 `flush` 覆盖 clear。
	- Payload：`∅`；时钟上升沿采样。
	- State update：对每个 fire 的 `k`，`entry_busy[commit_rd_idx[k]] <- 0`；`commit_clear[k]` 不更新 `entry_tag`；目标 entry 原为 `IDLE` 时状态保持 `IDLE`；未命中的 entry 不由 `commit_clear[k]` 更新。

## Data structure

### State

1. `entry_busy[i]`：1 bit，`i∈{0,...,NUM_GPR-1}`；entry `i` 的 `IDLE/BUSY` 状态；由 `commit_clear` 清零、由 `alloc` 置一，flush 清零，复位清零；entry 0 恒为 0。

### Header

1. `entry_tag[i]`：`TAG_W` bit，`i∈{0,...,NUM_GPR-1}`；entry `i` 当前 producer tag，用于与 `commit_tag[k]` 比较；由 `alloc` 更新，复位清零，`commit_clear` 和 flush 不更新；entry 0 恒为 0。

### Payload

无。

## Internal Connections

无。

## Interface

### In-event

1. `accept[s]`：Notify，`s∈{0,...,ISSUE_WIDTH-1}`。
	- Fire来源：`accept[s].fire`
	- Payload：`INT_tag_mapping_alloc_payload[s]`；`clk` 上升沿采样。
	`INT_tag_mapping_alloc_payload[s]`：`self_tag[s]` `TAG_W` bit × 1、`alloc_rd_idx[s]` `REG_ADDR_W` bit × 1、`alloc_rd_is_fp[s]` 1 bit × 1、`alloc_rd_write_enable[s]` 1 bit × 1。
2. `commit_valid[k]`：Notify，`k∈{0,...,ISSUE_WIDTH-1}`。
	- Fire来源：`commit_valid[k].fire`
	- Payload：`INT_tag_mapping_commit_payload[k]`；`clk` 上升沿采样。
	`INT_tag_mapping_commit_payload[k]`：`commit_tag[k]` `TAG_W` bit × 1、`commit_rd_idx[k]` `REG_ADDR_W` bit × 1、`commit_rd_is_fp[k]` 1 bit × 1、`commit_rd_write_enable[k]` 1 bit × 1。
3. `global_flush_late`：Notify，单 lane。
	- Fire来源：`global_flush_late.fire`
	- Payload：`∅`；当拍 pulse。

### In Static Info

1. `rst_n`：1 bit；低有效异步复位；控制全部 `entry_busy` 和 `entry_tag` 清零。
2. `rs_idx[s][x]`：`REG_ADDR_W` bit × `ISSUE_WIDTH` × `INT_SRC_PER_SLOT`，`s∈{0,...,ISSUE_WIDTH-1}`、`x∈{1,...,INT_SRC_PER_SLOT}`；当前拍组合读地址。

### Out-event

无。

### Out Static Info

1. `tag[s][x]`：`TAG_W` bit × `ISSUE_WIDTH` × `INT_SRC_PER_SLOT`，`s∈{0,...,ISSUE_WIDTH-1}`、`x∈{1,...,INT_SRC_PER_SLOT}`；当前拍组合读出的 producer tag。
	- `tag[s][x] = (rs_idx[s][x] == 0) ? 0 : entry_tag[rs_idx[s][x]]`。
		- `rs_idx[s][x]`：见 `Interface -> In Static Info` 第 2 条。
		- `entry_tag[rs_idx[s][x]]`：见 `Data structure -> Header` 第 1 条。
2. `busy[s][x]`：1 bit × `ISSUE_WIDTH` × `INT_SRC_PER_SLOT`，`s∈{0,...,ISSUE_WIDTH-1}`、`x∈{1,...,INT_SRC_PER_SLOT}`；当前拍组合读出的 entry busy 状态。
	- `busy[s][x] = (rs_idx[s][x] == 0) ? 0 : entry_busy[rs_idx[s][x]]`。
		- `rs_idx[s][x]`：见 `Interface -> In Static Info` 第 2 条。
		- `entry_busy[rs_idx[s][x]]`：见 `Data structure -> State` 第 1 条。

### Interface Timing

1. `clk`：`entry_busy` 和 `entry_tag` 在上升沿按 FSM 更新；不同 entry 的并发更新和同一 entry 的更新优先级见 `FSM -> Detailed Condition Description` 第 2～4 条。
2. `rst_n`：低有效异步复位；`rst_n=0` 时立即将全部 entry 的 `entry_busy` 与 `entry_tag` 清零，复位优先于写入。
3. `Transaction`：无。
4. `Notify`：`accept[s].fire`、`commit_valid[k].fire` 和 `global_flush_late.fire` 在当前拍有效；相关 payload 在 `clk` 上升沿采样，不提供 ready 或背压。
5. `Static Info`：`rs_idx[s][x]`、`tag[s][x]` 和 `busy[s][x]` 均为当前拍组合值；地址为 0 时输出 `{busy=0, tag=0}`；写入在时钟沿后对组合读可见，无读旁路；`rst_n=0` 时所有读口输出 `{busy=0, tag=0}`；flush 所在上升沿后，非零 entry 的 `busy` 输出为 0，`tag` 不由 flush 修改并可反映同拍 alloc 写入。
