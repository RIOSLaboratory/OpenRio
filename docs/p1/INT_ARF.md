# Module `INT_ARF`

`INT_ARF`：32-entry、64-bit 整数架构寄存器文件（`NUM_GPR=32`、`XLEN=64`、`REG_ADDR_W=5`、`ISSUE_WIDTH=2`、`INT_SRC_PER_SLOT=2`，为两个 slot 的 `rs1/rs2` 提供 4 个组合读口）。

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

1. `entry.payload[i]`：来源于 `INT_ARF_payload[k]`，`i∈{0,...,NUM_GPR-1}`。
	- `INT_ARF_payload[k]`：`commit_data[k]`。
	- 更新时机：`¬rst_n` 时异步更新；`rst_n ∧ write_enable` 成立时在 `clk` 上升沿更新。
		- `rst_n`：见 `Interface -> In Static Info`。
		- `write_enable = ∃k∈{0,...,ISSUE_WIDTH-1}: write_req[k]`。
			- `write_req[k] = commit_valid[k].fire ∧ rd_write_enable[k] ∧ ¬rd_is_fp[k] ∧ (rd_idx[k] != 0)`。
				- `commit_valid[k].fire`：见 `Interface -> In-event` 第 1 条。
				- `rd_write_enable[k]`：见 `Interface -> In-event` 第 1 条 Payload。
				- `rd_is_fp[k]`：见 `Interface -> In-event` 第 1 条 Payload。
				- `rd_idx[k]`：见 `Interface -> In-event` 第 1 条 Payload。
	- Update：`entry.payload[i] <- ¬rst_n ? 0 : (write_req[1] ∧ i=rd_idx[1]) ? commit_data[1] : (write_req[0] ∧ i=rd_idx[0]) ? commit_data[0] : entry.payload[i]`。
		- `rst_n`：见本条“更新时机”。
		- `write_req[1]`：见本条“更新时机”。
		- `rd_idx[1]`：见 `Interface -> In-event` 第 1 条 Payload。
		- `commit_data[1]`：见本条来源 payload 字段。
		- `write_req[0]`：见本条“更新时机”。
		- `rd_idx[0]`：见 `Interface -> In-event` 第 1 条 Payload。
		- `commit_data[0]`：见本条来源 payload 字段。
		- `entry.payload[i]`：更新前的存储值；无写入条件成立时保持。

## Internal Connections

无。

## Interface

### In-event

1. `commit_valid[k]`：Notify，`k∈{0,...,ISSUE_WIDTH-1}`。
	- Fire来源：`commit_valid[k].fire`
	- Payload：`INT_ARF_payload[k]`；`clk` 上升沿采样。
	`INT_ARF_payload[k]`：`rd_idx[k]` `REG_ADDR_W` bit × 1、`rd_is_fp[k]` 1 bit × 1、`rd_write_enable[k]` 1 bit × 1、`commit_data[k]` `XLEN` bit × 1。

### In Static Info

1. `rst_n`：1 bit；低有效异步复位；控制 `entry.payload[0:NUM_GPR-1]` 清零。
2. `rs_idx[s][x]`：`REG_ADDR_W` bit × `ISSUE_WIDTH` × `INT_SRC_PER_SLOT`，`s∈{0,...,ISSUE_WIDTH-1}`、`x∈{1,...,INT_SRC_PER_SLOT}`；当前拍组合读地址。

### Out-event

无。

### Out Static Info

1. `ARF[s][x]`：`XLEN` bit × `ISSUE_WIDTH` × `INT_SRC_PER_SLOT`，`s∈{0,...,ISSUE_WIDTH-1}`、`x∈{1,...,INT_SRC_PER_SLOT}`；当前拍组合读数据。
	- `ARF[s][x] = (rs_idx[s][x] == 0) ? 0 : entry.payload[rs_idx[s][x]]`。
		- `rs_idx[s][x]`：见 `Interface -> In Static Info` 第 2 条。
		- `entry.payload[rs_idx[s][x]]`：见 `Data structure -> Payload` 第 1 条。

### Interface Timing

1. `clk`：`entry.payload` 在上升沿按 `Data structure -> Payload` 第 1 条更新。
2. `rst_n`：低有效异步复位；`rst_n=0` 时 `entry.payload[0:NUM_GPR-1]` 全部清零，复位优先于写入。
3. `Transaction`：无。
4. `Notify`：`commit_valid[k].fire` 在当前拍有效；payload 在同一 `clk` 上升沿采样，不提供 ready 或背压。
5. `Static Info`：`rs_idx[s][x]` 与 `ARF[s][x]` 当前拍组合有效；地址为 0 时输出 0；当前拍 `commit_data[k]` 不旁路至 `ARF[s][x]`，写入在 `clk` 上升沿更新 `entry.payload` 后由组合读口反映；`rst_n=0` 时 `ARF[s][x]=0`；无 flush 接口。
