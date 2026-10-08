# Module `flush_model`

`flush_model`：无状态组合 flush 边界模块；按 `recovery_kind` 产生前端 redirect、全局 flush 广播和异常状态写包。

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

1. `flush_valid`：Notify，单 lane。
	- Fire来源：`flush_valid.fire = flush_valid`。
	- Payload：`flush_model_flush_payload`；`flush_valid.fire` 成立的当前拍组合采样。
	- `flush_model_flush_payload`：`recovery_kind` `RECOVERY_KIND_W=3` bit × 1、`flush_tag` `TAG_W=4` bit × 1。

### In Static Info

1. `mispredict_target_pc`：`XLEN=64` bit；`RECOVERY_MISPREDICT` 的恢复 PC。
2. `exception_cause`：`EXCP_CAUSE_W=63` bit；`RECOVERY_EXCEPTION` 的异常 cause。
3. `exception_tval`：`XLEN=64` bit；`RECOVERY_EXCEPTION` 的异常 tval。
4. `inst_pc`：`XLEN=64` bit；flush entry 的指令 PC，用作 trap EPC 或 `FENCE_I` 的 PC 基值。
5. `mepc`：`XLEN=64` bit；`RECOVERY_MRET` 的恢复 PC。
6. `sepc`：`XLEN=64` bit；`RECOVERY_SRET` 的恢复 PC。
7. `interrupt_cause`：`EXCP_CAUSE_W=63` bit；`RECOVERY_INTERRUPT` 的 interrupt cause。
8. `trap_vector`：`XLEN=64` bit；异常或中断的 trap vector 恢复 PC。

### Out-event

1. `global_flush_late`：Notify，单 lane。
	- Fire来源：`global_flush_late.fire = flush_valid.fire`
		- `flush_valid.fire`：见 `Interface -> In-event` 第 1 条。
	- Payload：∅；`global_flush_late.fire` 成立的当前拍组合采样。
2. `redirect_valid`：Notify，单 lane。
	- Fire来源：`redirect_valid.fire = flush_valid.fire`
		- `flush_valid.fire`：见 `Interface -> In-event` 第 1 条。
	- Payload：`flush_model_redirect_payload`；`redirect_valid.fire` 成立的当前拍组合采样。
	- `flush_model_redirect_payload`：`redirect_pc` `XLEN` bit × 1、`redirect_kind` `RECOVERY_KIND_W` bit × 1、`frontend_icache_invalidate` 1 bit × 1。
		- `redirect_pc = (recovery_kind_e'(recovery_kind) == RECOVERY_MISPREDICT) ? mispredict_target_pc : (recovery_kind_e'(recovery_kind) == RECOVERY_MRET) ? mepc : (recovery_kind_e'(recovery_kind) == RECOVERY_SRET) ? sepc : (recovery_kind_e'(recovery_kind) == RECOVERY_FENCE_I) ? (inst_pc + xlen_t'(4)) : trap_vector`
			- `recovery_kind`：见 `Interface -> In-event` 第 1 条 payload。
			- `mispredict_target_pc`：见 `Interface -> In Static Info` 第 1 条。
			- `mepc`：见 `Interface -> In Static Info` 第 5 条。
			- `sepc`：见 `Interface -> In Static Info` 第 6 条。
			- `inst_pc`：见 `Interface -> In Static Info` 第 4 条。
			- `trap_vector`：见 `Interface -> In Static Info` 第 8 条。
		- `redirect_kind = recovery_kind`
			- `recovery_kind`：见 `Interface -> In-event` 第 1 条 payload。
		- `frontend_icache_invalidate = (recovery_kind_e'(recovery_kind) == RECOVERY_FENCE_I)`
			- `recovery_kind`：见 `Interface -> In-event` 第 1 条 payload。
3. `trap_state_write.valid`：Notify，单 lane。
	- Fire来源：`trap_state_write.valid.fire = flush_valid.fire ∧ trap_state_valid`
		- `flush_valid.fire`：见 `Interface -> In-event` 第 1 条。
		- `trap_state_valid = (recovery_kind_e'(recovery_kind) == RECOVERY_EXCEPTION) ∨ (recovery_kind_e'(recovery_kind) == RECOVERY_MRET) ∨ (recovery_kind_e'(recovery_kind) == RECOVERY_SRET) ∨ (recovery_kind_e'(recovery_kind) == RECOVERY_INTERRUPT)`
			- `recovery_kind`：见 `Interface -> In-event` 第 1 条 payload。
	- Payload：`flush_model_trap_state_write_payload`；`trap_state_write.valid.fire` 成立的当前拍组合采样。
	- `flush_model_trap_state_write_payload`：`trap_state_write.kind` `RECOVERY_KIND_W` bit × 1、`trap_state_write.epc` `XLEN` bit × 1、`trap_state_write.cause` `EXCP_CAUSE_W` bit × 1、`trap_state_write.tval` `XLEN` bit × 1。
		- `trap_state_write.kind = recovery_kind_e'(recovery_kind)`
			- `recovery_kind`：见 `Interface -> In-event` 第 1 条 payload。
		- `trap_state_write.epc = inst_pc`
			- `inst_pc`：见 `Interface -> In Static Info` 第 4 条。
		- `trap_state_write.cause = cause`
			- `cause`：见 `Out Static Info` 第 1 条。
		- `trap_state_write.tval = (recovery_kind_e'(recovery_kind) == RECOVERY_EXCEPTION) ? exception_tval : '0`
			- `recovery_kind`：见 `Interface -> In-event` 第 1 条 payload。
			- `exception_tval`：见 `Interface -> In Static Info` 第 3 条。

### Out Static Info

1. `cause`：`EXCP_CAUSE_W=63` bit；有效 flush 时按恢复类型选择异常或中断 cause，其他情况为 0。
	- `cause = flush_valid.fire ? ((recovery_kind_e'(recovery_kind) == RECOVERY_EXCEPTION) ? exception_cause : (recovery_kind_e'(recovery_kind) == RECOVERY_INTERRUPT) ? interrupt_cause : '0) : '0`
		- `flush_valid.fire`：见 `Interface -> In-event` 第 1 条。
		- `recovery_kind`：见 `Interface -> In-event` 第 1 条 payload。
		- `exception_cause`：见 `Interface -> In Static Info` 第 2 条。
		- `interrupt_cause`：见 `Interface -> In Static Info` 第 7 条。
2. `is_interrupt`：1 bit；有效 flush 的恢复类型是否为 `RECOVERY_INTERRUPT`。
	- `is_interrupt = flush_valid.fire ∧ (recovery_kind_e'(recovery_kind) == RECOVERY_INTERRUPT)`
		- `flush_valid.fire`：见 `Interface -> In-event` 第 1 条。
		- `recovery_kind`：见 `Interface -> In-event` 第 1 条 payload。

### Interface Timing

1. `clk`：无时钟；本模块所有输出均为当前拍组合结果。
2. `rst_n`：无复位端口；本模块无复位行为。
3. `Transaction`：无。
4. `Notify`：`flush_valid.fire` 为当前拍 flush 通知；成立时 `global_flush_late` 和 `redirect_valid` 同拍有效，`redirect` payload 同拍组合有效；`trap_state_write.valid` 仅对异常、MRET、SRET 和中断类型有效。
5. `Static Info`：所有输入 Static Info 和 `cause`、`is_interrupt` 当前拍组合有效；`flush_valid=0` 时各输出事件信号及其 payload 清零。
