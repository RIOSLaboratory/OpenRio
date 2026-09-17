# Module `FP_ARF`

`FP_ARF`：32-entry、64-bit 浮点架构寄存器文件（`NUM_FPR=32`、`XLEN=64`、`REG_ADDR_W=5`、`ISSUE_WIDTH=2`、3 个组合读端口）。

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

1. `entry.payload[i]`：来源于 `FP_ARF_payload[k]`，`i∈{0,...,NUM_FPR-1}`。
	- `FP_ARF_payload[k]`：`commit_data[k]`。
	- 更新时机：`¬rst_n` 时异步更新；`rst_n ∧ dispatch_valid` 成立时在 `clk` 上升沿更新。
		- `rst_n`：见 `Interface -> In Static Info` 第 1 条。
		- `dispatch_valid = ∃k∈{0,...,ISSUE_WIDTH-1}: write_req[k]`
			- `write_req[k] = commit_valid[k].fire ∧ rd_write_enable[k] ∧ rd_is_fp[k]`
				- `commit_valid[k].fire`：见 `Interface -> In-event` 第 1 条。
				- `rd_write_enable[k]`：见 `Interface -> In-event` 第 1 条。
				- `rd_is_fp[k]`：见 `Interface -> In-event` 第 1 条。
	- Update：`entry.payload[i] <- ¬rst_n ? 0 : (dispatch_valid ∧ i=rd_idx[k_sel]) ? commit_data[k_sel] : entry.payload[i]`。
		- `rst_n`：见本条“更新时机”。
		- `dispatch_valid`：见本条“更新时机”。
		- `k_sel = min {k∈{0,...,ISSUE_WIDTH-1} | write_req[k]}`；仅在 `dispatch_valid=1` 时使用。
			- `write_req[k]`：见本条“更新时机”。
		- `rd_idx[k]`：见 `Interface -> In-event` 第 1 条。
		- `commit_data[k]`：见本条来源 payload 字段。
		- `entry.payload[i]`：更新前的存储值；无更新条件成立时保持。

## Internal Connections

无。

## Interface

### In-event

1. `commit_valid[k]`：Notify，`k∈{0,...,ISSUE_WIDTH-1}`。
	- Fire来源：`commit_valid[k].fire`。
	- Payload：`FP_ARF_payload[k]`；`clk` 上升沿采样。
	`FP_ARF_payload[k]`：`rd_write_enable[k]` 1 bit × 1、`rd_is_fp[k]` 1 bit × 1、`rd_idx[k]` `REG_ADDR_W` bit × 1、`commit_data[k]` `XLEN` bit × 1

### In Static Info

1. `rst_n`：1 bit；低有效异步复位；控制 `entry.payload[0:NUM_FPR-1]` 清零。
2. `fp_read_idx[x]`：`REG_ADDR_W` bit × 3，`x∈{1,2,3}`；当前拍组合读地址；每个地址独立选择一个 `entry.payload`。

### Out-event

无。

### Out Static Info

1. `ARF[x]`：`XLEN` bit × 3，`x∈{1,2,3}`；当前拍组合读数据。
	- `ARF[x] = entry.payload[fp_read_idx[x]]`。
		- `entry.payload[i]`：见 `Data structure -> Payload` 第 1 条。
		- `fp_read_idx[x]`：见 `Interface -> In Static Info` 第 2 条。

### Interface Timing

1. `clk`：`entry.payload` 在上升沿按 `Data structure -> Payload` 第 1 条更新。
2. `rst_n`：低有效异步复位；`rst_n=0` 时 `entry.payload[0:NUM_FPR-1]` 全部清零，复位优先于写入。
3. `Transaction`：无。
4. `Notify`：`commit_valid[k]` 在当前拍 fire；payload 在同一 `clk` 上升沿采样，不提供 ready 或背压。
5. `Static Info`：`fp_read_idx[x]` 与 `ARF[x]` 当前拍组合有效；`ARF[x]` 持续反映对应 `entry.payload`，无读写旁路；异步复位清零生效后 `ARF[x]=0`。
