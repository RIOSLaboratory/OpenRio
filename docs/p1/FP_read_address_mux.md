# Module `FP_read_address_mux`

`FP_read_address_mux`：2-slot、3-source 的浮点寄存器组合读地址选择模块（`ISSUE_WIDTH=2`、`REG_ADDR_W=5`）。

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

无。

### In Static Info

1. `rs1_idx[s]`：`REG_ADDR_W` bit × `ISSUE_WIDTH`，`s∈{0,1}`；当前拍两个 slot 的 `rs1` 浮点寄存器候选读地址。
2. `rs2_idx[s]`：`REG_ADDR_W` bit × `ISSUE_WIDTH`，`s∈{0,1}`；当前拍两个 slot 的 `rs2` 浮点寄存器候选读地址。
3. `rs3_idx[s]`：`REG_ADDR_W` bit × `ISSUE_WIDTH`，`s∈{0,1}`；当前拍两个 slot 的 `rs3` 浮点寄存器候选读地址。
4. `is_fp_opcode`：1 bit；当前拍三路读地址的共同选择值；`1` 选择 `s=0`，`0` 选择 `s=1`。

### Out-event

无。

### Out Static Info

1. `fp_read_idx[x]`：`REG_ADDR_W` bit × 3，`x∈{1,2,3}`；当前拍浮点寄存器组合读地址。
	- `fp_read_idx[1] = is_fp_opcode ? rs1_idx[0] : rs1_idx[1]`
		- `is_fp_opcode`：见 `Interface -> In Static Info` 第 4 条。
		- `rs1_idx[0]`：见 `Interface -> In Static Info` 第 1 条。
		- `rs1_idx[1]`：见 `Interface -> In Static Info` 第 1 条。
	- `fp_read_idx[2] = is_fp_opcode ? rs2_idx[0] : rs2_idx[1]`
		- `is_fp_opcode`：见 `Interface -> In Static Info` 第 4 条。
		- `rs2_idx[0]`：见 `Interface -> In Static Info` 第 2 条。
		- `rs2_idx[1]`：见 `Interface -> In Static Info` 第 2 条。
	- `fp_read_idx[3] = is_fp_opcode ? rs3_idx[0] : rs3_idx[1]`
		- `is_fp_opcode`：见 `Interface -> In Static Info` 第 4 条。
		- `rs3_idx[0]`：见 `Interface -> In Static Info` 第 3 条。
		- `rs3_idx[1]`：见 `Interface -> In Static Info` 第 3 条。

### Interface Timing

1. `clk`：无时钟输入；全部逻辑均为组合逻辑。
2. `rst_n`：无复位输入。
3. `Transaction`：无。
4. `Notify`：无。
5. `Static Info`：所有输入和输出均为当前拍组合值；`fp_read_idx[1:3]` 随 `rs1_idx[0:1]`、`rs2_idx[0:1]`、`rs3_idx[0:1]` 或 `is_fp_opcode` 的变化重新计算；无握手、背压或保持要求。
