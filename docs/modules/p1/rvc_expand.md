# Module `rvc_expand`

`rvc_expand`：`ISSUE_WIDTH=2`、无状态的 RVC 指令组合展开模块。

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

1. `ib_inst_bits[n]`：32 bit，`n∈{0,1}`；当前拍 lane `n` 的原始指令编码，压缩指令位于低 16 bit。
2. `is_compressed[n]`：1 bit，`n∈{0,1}`；当前拍 lane `n` 的指令是否为压缩编码。

### Out-event

无。

### Out Static Info

1. `inst32[n]`：32 bit，`n∈{0,1}`；当前拍 lane `n` 的规范 32-bit 指令。
	- `inst32[n] = is_compressed[n] ? expanded[n] : ib_inst_bits[n]`
		- `is_compressed[n]`：见 `Interface -> In Static Info` 第 2 条。
		- `expanded[n] = riscv_rvc_pkg::rvc_decompress_rv64(ib_inst_bits[n][15:0], rvc_ok[n])`
			- `ib_inst_bits[n]`：见 `Interface -> In Static Info` 第 1 条。
			- `rvc_ok[n]`：`rvc_decompress_rv64` 返回的 RVC 编码合法标志。
		- `ib_inst_bits[n]`：见 `Interface -> In Static Info` 第 1 条。
2. `rvc_illegal[n]`：1 bit，`n∈{0,1}`；当前拍压缩编码是否非法。
	- `rvc_illegal[n] = is_compressed[n] ∧ ¬rvc_ok[n]`
		- `is_compressed[n]`：见 `Interface -> In Static Info` 第 2 条。
		- `rvc_ok[n]`：见本节第 1 条。

### Interface Timing

1. `clk`：无时钟。
2. `rst_n`：无复位。
3. `Transaction`：无。
4. `Notify`：无。
5. `Static Info`：所有输入和输出均为当前拍组合值；`is_compressed[n]=0` 时 `inst32[n]=ib_inst_bits[n]` 且 `rvc_illegal[n]=0`；压缩输入时 `inst32[n]` 和 `rvc_illegal[n]` 随 `ib_inst_bits[n][15:0]` 的展开结果组合更新；无握手、背压或保持要求。
