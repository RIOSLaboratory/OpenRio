# Module `FP_tag_mapping`

`FP_tag_mapping`：32-entry 浮点寄存器重命名映射表（`NUM_FPR=32`、`REG_ADDR_W=5`、`TAG_W=4`、`ISSUE_WIDTH=2`），提供 3 个组合读口。

## Submodule

无。

## FSM

### State

1. `IDLE`：对应 entry 的 `entry_busy=0`，不存在有效的浮点 producer。
2. `BUSY`：对应 entry 的 `entry_busy=1`，存在有效的浮点 producer，producer tag 保存在 `entry_tag`。

### State Transition & Condition Name

1. `ANY -> IDLE`：`reset`
2. `ANY -> IDLE`：`flush`
3. `IDLE -> BUSY`：`alloc[s]`
4. `BUSY -> IDLE`：`commit_clear[k]`

### Detailed Condition Description

1. `reset`：复位全部浮点寄存器映射 entry。
	- Fire来源：`reset.fire = ¬rst_n`
		- `rst_n`：见 `Interface -> In Static Info` 第 1 条。
	- Constraint：低有效异步复位；优先于 `flush`、`commit_clear[k]` 和 `alloc[s]`。
	- Payload：`∅`；复位有效时立即生效。
	- State update：对所有 `i∈{0,...,NUM_FPR-1}`，`entry_busy[i] <- 0`，`entry_tag[i] <- 0`。
2. `flush`：清除全部浮点 producer 的 busy 状态。
	- Fire来源：`flush.fire = global_flush_late.fire`
		- `global_flush_late.fire`：见 `Interface -> In-event` 第 3 条。
	- Constraint：`rst_n=1` 时在 `clk` 上升沿执行；优先于 `commit_clear[k]` 和 `alloc[s]`；不修改 `entry_tag[i]`。
	- Payload：`∅`；当前拍 pulse。
	- State update：对所有 `i∈{0,...,NUM_FPR-1}`，`entry_busy[i] <- 0`；`entry_tag[i]` 保持。
3. `alloc[s]`：选择最低编号的合格 slot，将 FP destination 标记为 busy 并写入 producer tag。
	- Fire来源：`alloc[s].fire = alloc_candidate[s] ∧ (∀j∈{0,...,s-1}: ¬alloc_candidate[j])`
		- `alloc_candidate[s] = accept[s].fire ∧ alloc_rd_write_enable[s] ∧ alloc_rd_is_fp[s]`
			- `accept[s].fire`：见 `Interface -> In-event` 第 1 条。
			- `alloc_rd_write_enable[s]`：见 `Interface -> In-event` 第 1 条 payload。
			- `alloc_rd_is_fp[s]`：见 `Interface -> In-event` 第 1 条 payload。
		- `alloc_candidate[j]`：见本条 `alloc_candidate[s]`，索引取 `j`；`s=0` 时前序候选集合为空。
	- Constraint：`s∈{0,...,ISSUE_WIDTH-1}`；每拍最多一个 `alloc[s]` fire；若多个 `alloc_candidate[s]` 同时成立，最低编号 slot fire；目标 entry 已为 `BUSY` 时仍可 fire，仅替换 producer tag，状态保持 `BUSY`；`reset.fire` 或 `flush.fire` 时状态更新被取消。
	- Payload：`FP_tag_mapping_alloc_payload[s]`；`clk` 上升沿采样。
		- `FP_tag_mapping_alloc_payload[s]`：`alloc_rd_write_enable[s]` 1 bit × 1、`alloc_rd_is_fp[s]` 1 bit × 1、`alloc_rd_idx[s]` `REG_ADDR_W` bit × 1、`self_tag[s]` `TAG_W` bit × 1。
	- State update：对 fire 的 `s`，`entry_busy[alloc_rd_idx[s]] <- 1`，`entry_tag[alloc_rd_idx[s]] <- self_tag[s]`；同拍 `commit_clear[k]` 命中不同 entry 时两项更新均执行，命中同一 entry 时本更新覆盖 clear；未被任一更新命中的 entry 保持。
4. `commit_clear[k]`：选择最低编号的合格 commit lane，在提交 tag 匹配当前 producer tag 时清除 busy。
	- Fire来源：`commit_clear[k].fire = commit_clear_candidate[k] ∧ (∀j∈{0,...,k-1}: ¬commit_clear_candidate[j])`
		- `commit_clear_candidate[k] = commit_valid[k].fire ∧ commit_rd_write_enable[k] ∧ commit_rd_is_fp[k] ∧ (entry_tag[commit_rd_idx[k]] == commit_tag[k])`
			- `commit_valid[k].fire`：见 `Interface -> In-event` 第 2 条。
			- `commit_rd_write_enable[k]`：见 `Interface -> In-event` 第 2 条 payload。
			- `commit_rd_is_fp[k]`：见 `Interface -> In-event` 第 2 条 payload。
			- `entry_tag[commit_rd_idx[k]]`：见 `Data structure -> Header` 第 1 条。
				- `commit_rd_idx[k]`：见 `Interface -> In-event` 第 2 条 payload。
			- `commit_tag[k]`：见 `Interface -> In-event` 第 2 条 payload。
		- `commit_clear_candidate[j]`：见本条 `commit_clear_candidate[k]`，索引取 `j`；`k=0` 时前序候选集合为空。
	- Constraint：`k∈{0,...,ISSUE_WIDTH-1}`；每拍最多一个 `commit_clear[k]` fire；若多个 `commit_clear_candidate[k]` 同时成立，最低编号 lane fire；tag 不匹配时不清除；目标 entry 为 `IDLE` 且 tag 匹配时仍可 fire，状态保持 `IDLE`；`reset.fire` 或 `flush.fire` 时状态更新被取消；同拍 `alloc[s]` 命中同一 entry 时由 `alloc[s]` 覆盖本更新。
	- Payload：`∅`；`clk` 上升沿采样。
	- State update：对 fire 的 `k`，`entry_busy[commit_rd_idx[k]] <- 0`；本更新不修改 `entry_tag[i]`；同拍 `alloc[s]` 命中不同 entry 时两项更新均执行，命中同一 entry 时由 `alloc[s]` 覆盖本更新；未被任一更新命中的 entry 保持。

## Data structure

### State

1. `entry_busy[i]`：1 bit，`i∈{0,...,NUM_FPR-1}`；entry `i` 的 `IDLE/BUSY` 状态；由 `reset`、`flush`、`alloc[s]` 和 `commit_clear[k]` 按 FSM 更新；FP entry 0 与其他 entry 使用相同规则。

### Header

1. `entry_tag[i]`：`TAG_W` bit，`i∈{0,...,NUM_FPR-1}`；entry `i` 当前 producer tag；由 `reset` 和 `alloc[s]` 更新，供 `commit_clear[k]` 与 `commit_tag[k]` 比较；`flush` 和 `commit_clear[k]` 不修改。

### Payload

无。

## Internal Connections

无。

## Interface

### In-event

1. `accept[s]`：Notify，`s∈{0,...,ISSUE_WIDTH-1}`。
	- Fire来源：`accept[s].fire`。
	- Payload：`FP_tag_mapping_alloc_payload[s]`；`clk` 上升沿采样。
	`FP_tag_mapping_alloc_payload[s]`：`alloc_rd_write_enable[s]` 1 bit × 1、`alloc_rd_is_fp[s]` 1 bit × 1、`alloc_rd_idx[s]` `REG_ADDR_W` bit × 1、`self_tag[s]` `TAG_W` bit × 1。
2. `commit_valid[k]`：Notify，`k∈{0,...,ISSUE_WIDTH-1}`。
	- Fire来源：`commit_valid[k].fire`。
	- Payload：`FP_tag_mapping_commit_payload[k]`；`clk` 上升沿采样。
	`FP_tag_mapping_commit_payload[k]`：`commit_tag[k]` `TAG_W` bit × 1、`commit_rd_idx[k]` `REG_ADDR_W` bit × 1、`commit_rd_is_fp[k]` 1 bit × 1、`commit_rd_write_enable[k]` 1 bit × 1。
3. `global_flush_late`：Notify，单 lane。
	- Fire来源：`global_flush_late.fire`。
	- Payload：`∅`；当前拍 pulse。

### In Static Info

1. `rst_n`：1 bit；低有效异步复位；控制全部 `entry_busy[i]` 和 `entry_tag[i]` 清零。
2. `fp_read_idx[x]`：`REG_ADDR_W` bit × 3，`x∈{1,2,3}`；当前拍组合读地址。

### Out-event

无。

### Out Static Info

1. `tag[x]`：`TAG_W` bit × 3，`x∈{1,2,3}`；当前拍组合读出的 producer tag。
	- `tag[x] = entry_tag[fp_read_idx[x]]`
		- `entry_tag[i]`：见 `Data structure -> Header` 第 1 条。
		- `fp_read_idx[x]`：见 `Interface -> In Static Info` 第 2 条。
2. `busy[x]`：1 bit × 3，`x∈{1,2,3}`；当前拍组合读出的 entry busy 状态。
	- `busy[x] = entry_busy[fp_read_idx[x]]`
		- `entry_busy[i]`：见 `Data structure -> State` 第 1 条。
		- `fp_read_idx[x]`：见 `Interface -> In Static Info` 第 2 条。

### Interface Timing

1. `clk`：`entry_busy[i]` 和 `entry_tag[i]` 在上升沿按 FSM 更新；正常更新中先执行 `commit_clear[k]`，再执行 `alloc[s]`，同一 entry 由 `alloc[s]` 覆盖。
2. `rst_n`：低有效异步复位；`rst_n=0` 时立即清零全部 `entry_busy[i]` 和 `entry_tag[i]`，优先于所有同步更新。
3. `Transaction`：无。
4. `Notify`：`accept[s]`、`commit_valid[k]` 和 `global_flush_late` 在当前拍 fire；相关 payload 在 `clk` 上升沿采样；不提供 ready、背压或保持。同步更新优先级为 `flush` 高于 `commit_clear[k]` 和 `alloc[s]`。
5. `Static Info`：`fp_read_idx[x]`、`tag[x]` 和 `busy[x]` 均为当前拍组合值；读口持续反映对应 entry 的寄存状态；状态更新在时钟沿后对组合读可见；无读写旁路。
