# Module `p1_ISQ_input_mux`

`p1_ISQ_input_mux`：`ISSUE_WIDTH=2`、无状态的两路 `isq_payload_t` 组合选择模块。

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

1. `slot_payload[s]`：`isq_payload_t`，556 bit，`s∈{0,1}`；当前拍候选 slot `s` 的完整 ISQ payload。
2. `select_payload[s]`：1 bit，`s∈{0,1}`；当前拍是否选择候选 slot `s`；取值约束为 `¬(select_payload[0] ∧ select_payload[1])`，且 `select_payload[0]` 的选择优先级高于 `select_payload[1]`。

### Out-event

无。

### Out Static Info

1. `ISQ_payload_in`：`isq_payload_t`，556 bit；当前拍组合选择结果。
	- `ISQ_payload_in = select_payload[0] ? slot_payload[0] : select_payload[1] ? slot_payload[1] : '0`
		- `select_payload[0]`：见 `Interface -> In Static Info` 第 2 条。
		- `slot_payload[0]`：见 `Interface -> In Static Info` 第 1 条。
		- `select_payload[1]`：见 `Interface -> In Static Info` 第 2 条。
		- `slot_payload[1]`：见 `Interface -> In Static Info` 第 1 条。

### Interface Timing

1. `clk`：无时钟。
2. `rst_n`：无复位。
3. `Transaction`：无。
4. `Notify`：无。
5. `Static Info`：`slot_payload[s]`、`select_payload[s]` 与 `ISQ_payload_in` 均为当前拍组合值；选择约束见 `Interface -> In Static Info` 第 2 条，输出行为见 `Interface -> Out Static Info` 第 1 条；无 reset/flush 取消规则及存储保持语义。
