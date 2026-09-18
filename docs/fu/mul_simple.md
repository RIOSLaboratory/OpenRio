# Module `mul_simple`

`mul_simple`：G1 乘法功能单元；接收乘法 issue 请求，经过两拍计数后向 G1 仲裁器请求写回。

## Submodule

无。

## FSM

### State

1. `IDLE`：无在途乘法，`busy_reg <- 0`。
2. `EXEC`：已接收 issue，等待计数完成，`busy_reg=1` 且 `cnt=1`。
3. `WB`：完成 payload 保持并请求仲裁，`busy_reg=1` 且 `cnt <- 0`。

### State Transition & Condition Name

1. `ANY -> IDLE`：`reset`
2. `ANY -> IDLE`：`global_flush_late`
3. `IDLE -> EXEC`：`issue_accept`
4. `EXEC -> WB`：`advance_to_wb`
5. `WB -> IDLE`：`request_valid`

### Detailed Condition Description

1. `reset`：异步复位并清除全部在途状态。
	- Fire来源：`reset.fire = ¬rst_n`
		- `rst_n`：见 `Interface -> In Static Info` 第 1 条。
	- Constraint：异步低有效复位。
	- Payload：∅。
	- State update：`cnt <- 0`、`busy_reg <- 0`、`reg_tag <- 0`、`reg_result <- 0`、`hold_valid <- 0`、`hold_tag <- 0`、`hold_result_data <- 0`。
2. `global_flush_late`：清除 flush 时刻全部在途乘法及完成请求。
	- Fire来源：`global_flush_late.fire = global_flush_late`
		- `global_flush_late`：见 `Interface -> In-event` 第 1 条。
	- Constraint：高电平有效；优先于 issue 接收和写回处理。
	- Payload：∅。
	- State update：`cnt <- 0`、`busy_reg <- 0`、`reg_tag <- 0`、`reg_result <- 0`、`hold_valid <- 0`、`hold_tag <- 0`、`hold_result_data <- 0`。
3. `issue_accept`：在空闲且 FU_Group 指向 MUL 时捕获 issue payload。
	- Fire来源：`issue_accept.fire = issue_valid ∧ FU_ready ∧ (FU_Group == FU_GROUP_W'(G1_FU_MUL)) ∧ ¬global_flush_late`
		- `issue_valid`：见 `Interface -> In-event` 第 2 条；其 payload 在成交前保持。
		- `FU_ready`：见 `Interface -> Out Static Info` 第 1 条。
		- `FU_Group`：见 `Interface -> In-event` 第 2 条 payload。
		- `global_flush_late`：见 `Interface -> In-event` 第 1 条。
	- Constraint：仅 `FU_Group == FU_GROUP_W'(G1_FU_MUL)` 时接收；仅在 `IDLE` 状态有效。
	- Payload：`mul_simple_issue_payload`；上升沿采样。
	- State update：`cnt <- 1`、`busy_reg <- 1`、`reg_tag <- self_tag`、`reg_result <- mul_result`。
		- `self_tag`：见 `Interface -> In-event` 第 2 条 payload。
		- `mul_result`：见 `Data structure -> Payload` 第 1 条。
4. `advance_to_wb`：将执行计数推进到写回阶段。
	- Fire来源：`advance_to_wb.fire = busy_reg ∧ (cnt == 1'b1) ∧ ¬global_flush_late`
		- `busy_reg`：见 `Data structure -> State` 第 2 条。
		- `cnt`：见 `Data structure -> State` 第 1 条。
		- `global_flush_late`：见 `Interface -> In-event` 第 1 条。
	- Constraint：仅 `EXEC` 状态有效。
	- Payload：∅。
	- State update：`cnt <- 0`；其余存储保持。
5. `request_valid`：completion request 与仲裁器成交并释放 FU。
	- Fire来源：`request_valid.fire = hold_valid ∧ ¬global_flush_late ∧ winner_grant`
		- `hold_valid`：见 `Data structure -> State` 第 5 条。
		- `global_flush_late`：见 `Interface -> In-event` 第 1 条。
	- Constraint：仅 `WB` 状态有效；flush 周期组合屏蔽。
	- Payload：`mul_simple_request_payload`；当前拍有效。
	- State update：成交时 `busy_reg <- 0`、`hold_valid <- 0`、`hold_tag <- 0`、`hold_result_data <- 0`；未成交时本拍装载 `hold_valid <- 1`、`hold_tag <- reg_tag`、`hold_result_data <- reg_result` 并保持请求。
		- `reg_tag`：见 `Data structure -> State` 第 3 条。
		- `reg_result`：见 `Data structure -> State` 第 4 条。

## Data structure

### State

1. `cnt`：1 bit 倒计数寄存器；`issue_accept` 置 1，`advance_to_wb` 置 0，复位或 `global_flush_late` 置 0。
2. `busy_reg`：1 bit 忙标志；`issue_accept` 置 1，`request_valid`、复位或 `global_flush_late` 置 0；表示 `IDLE`/`EXEC`/`WB` 的非空状态。
3. `reg_tag`：`TAG_W` bit；保存已接收 issue 的 tag；由 `issue_accept` 写入，复位或 flush 清零。
4. `reg_result`：`XLEN` bit；保存乘法结果；由 `issue_accept` 写入，复位或 flush 清零。
5. `hold_valid`：1 bit；`WB` 阶段完成请求保持标志；由写回阶段置 1，`request_valid`、复位或 flush 清零。
6. `hold_tag`：`TAG_W` bit；完成请求保持的 tag；由写回阶段装载 `reg_tag`，复位或 flush 清零。
7. `hold_result_data`：`XLEN` bit；完成请求保持的数据；由写回阶段装载 `reg_result`，复位或 flush 清零。

### Header

无。

### Payload

1. `entry.payload`：来源于 issue event 和乘法组合结果。
	- `mul_simple_issue_payload`：`self_tag`、`rs1_data`、`rs2_data`、`FU_Group`、`exe_subop`，字段位宽见 `Interface -> In-event` 第 2 条。
	- `mul_result`：乘法结果组合值。
		- `mul_result = (exe_subop == SUBOP_MUL) ? full_res_ss[XLEN-1:0] : (exe_subop == SUBOP_MULH) ? full_res_ss[XLEN*2-1:XLEN] : (exe_subop == SUBOP_MULHU) ? full_res_uu[XLEN*2-1:XLEN] : (exe_subop == SUBOP_MULHSU) ? full_res_su[XLEN*2-1:XLEN] : (exe_subop == SUBOP_MULW) ? {{32{(rs1_w * rs2_w)[31]}}, (rs1_w * rs2_w)} : 0`
			- `full_res_ss = $signed(rs1_data) * $signed(rs2_data)`
			- `full_res_uu = rs1_data * rs2_data`
			- `full_res_su = $signed(rs1_data) * $signed({1'b0, rs2_data})`
			- `rs1_w = rs1_data[31:0]`、`rs2_w = rs2_data[31:0]`

## Internal Connections

无。

## Interface

### In-event

1. `global_flush_late`：Notify，单 lane。
	- Fire来源：`global_flush_late.fire = global_flush_late`
	- Payload：∅；当拍 announce。
2. `issue_valid`：Transaction，单 lane。
	- Fire来源：见 `FSM -> Detailed Condition Description` 第 3 条。
	- Payload：`mul_simple_issue_payload`；上升沿采样。
	- `mul_simple_issue_payload`：`rs1_data` `XLEN` bit、`rs2_data` `XLEN` bit、`FU_Group` `FU_GROUP_W` bit、`self_tag` `TAG_W` bit、`exe_subop` `EXE_SUBOP_W` bit。
3. `winner_grant`：Notify，单 lane。
	- Fire来源：`winner_grant.fire = winner_grant`
	- Payload：∅；当拍 announce。

### In Static Info

1. `rst_n`：1 bit；低有效异步复位输入；复位逻辑读取。
2. `loser_hold`：1 bit；仲裁失败保持电平；用于抑制 `FU_ready`。

### Out-event

1. `request_valid`：Transaction，单 lane。
	- Fire来源：见 `FSM -> Detailed Condition Description` 第 5 条。
	- Payload：`mul_simple_request_payload`；当前拍有效，仲裁获胜前保持。
	- `mul_simple_request_payload`：`req_tag` `TAG_W` bit、`req_result_data` `XLEN` bit、`req_mispredict_flag` 1 bit、`req_mispredict_target_pc` `XLEN` bit、`req_exception_flag` 1 bit、`req_exception_cause` `EXCP_CAUSE_W` bit、`req_exception_tval` `XLEN` bit、`req_is_mret` 1 bit、`req_is_sret` 1 bit、`req_fpu_fflags` `FFLAGS_W` bit。
		- `req_tag = hold_tag`
			- `hold_tag`：见 `Data structure -> State` 第 6 条。
		- `req_result_data = hold_result_data`
			- `hold_result_data`：见 `Data structure -> State` 第 7 条。
		- `req_mispredict_flag = 0`、`req_mispredict_target_pc = 0`、`req_exception_flag = 0`、`req_exception_cause = 0`、`req_exception_tval = 0`、`req_is_mret = 0`、`req_is_sret = 0`、`req_fpu_fflags = 0`
			- G1 事件字段恒为零。

### Out Static Info

1. `FU_ready`：1 bit，单 lane；当前拍组合有效。
	- `FU_ready = ¬busy_reg ∧ ¬loser_hold`
		- `busy_reg`：见 `Data structure -> State` 第 2 条。
		- `loser_hold`：见 `Interface -> In Static Info` 第 2 条。

### Interface Timing

1. `clk`：所有同步状态在上升沿采样和更新。
2. `rst_n`：低有效异步复位；断言时立即清零计数、忙标志、结果和保持 payload。
3. `issue_valid` Transaction：`issue_valid ∧ FU_ready ∧ (FU_Group == FU_GROUP_W'(G1_FU_MUL)) ∧ ¬global_flush_late` 在上升沿成立时捕获；未 fire 时生产端保持 payload。
4. `winner_grant` Notify：在上升沿采样；仅 `WB` 状态且未 flush 时释放保持请求。
5. `global_flush_late` Notify：当拍立即取消 issue 接收和 `request_valid`，并在上升沿清除全部在途状态。
6. `request_valid` Transaction：`hold_valid` 且未 flush 时组合有效；请求 payload 在仲裁获胜前保持稳定，`loser_hold` 时 `FU_ready=0` 并继续保持。
7. `FU_ready` Static Info：由 `busy_reg` 与 `loser_hold` 组合产生；复位或 flush 清除 busy 后下一拍可重新接收。
