# Module `div_simple`

`div_simple`：单 lane 的 RV64 整数除法与余数执行单元；接收 G0 的 DIV issue，经固定倒计时产生 completion request，并保持至仲裁成功。

## Submodule

无。

## FSM

### State

1. `IDLE`：无执行中的运算且无有效 completion request。
2. `EXECUTE_2`：已保存运算结果，`cnt=2`。
3. `EXECUTE_1`：已保存运算结果，`cnt=1`。
4. `WRITEBACK`：已保存运算结果，`cnt=0`，将在本拍上升沿写入 completion payload。
5. `COMPLETION_PENDING`：completion payload 有效并等待仲裁成功。

### State Transition & Condition Name

1. `ANY -> IDLE`：`reset`
2. `ANY -> IDLE`：`global_flush_late`
3. `IDLE -> EXECUTE_2`：`issue_valid`
4. `EXECUTE_2 -> EXECUTE_1`：`countdown_2_to_1`
5. `EXECUTE_1 -> WRITEBACK`：`countdown_1_to_0`
6. `WRITEBACK -> COMPLETION_PENDING`：`completion_publish`
7. `COMPLETION_PENDING -> IDLE`：`request_valid`

### Detailed Condition Description

1. `reset`：异步清除执行状态、运算 payload 和 completion payload。
	- Fire来源：`reset.fire = ¬rst_n`
		- `rst_n`：见 `Interface -> In Static Info` 第 1 条。
	- Constraint：低有效异步复位。
	- Payload：∅。
	- State update：`cnt <- 0`；`busy_reg <- 0`；`entry.payload.operation.tag <- 0`；`entry.payload.operation.result <- 0`；`entry.payload.completion <- 0`。
2. `global_flush_late`：取消执行中的运算或待仲裁 completion。
	- Fire来源：`global_flush_late.fire`
		- `global_flush_late.fire`：见 `Interface -> In-event` 第 1 条。
	- Constraint：优先于所有其他同步状态更新；本拍禁止 `issue_valid.fire` 和 `request_valid.fire`。
	- Payload：∅。
	- State update：本拍上升沿 `cnt <- 0`；`busy_reg <- 0`；`entry.payload.operation.tag <- 0`；`entry.payload.operation.result <- 0`；`entry.payload.completion <- 0`。
3. `issue_valid`：接收一个目标为本 DIV FU 的 issue，并保存 tag 和组合运算结果。
	- Fire来源：`issue_valid.fire = issue_valid.valid ∧ fu_selected ∧ FU_ready ∧ ¬global_flush_late.fire`
		- `issue_valid.valid`：输入 issue 请求有效；见 `Interface -> In-event` 第 2 条。
		- `fu_selected = (FU_Group = FU_GROUP_W'(G0_FU_DIV))`
			- `FU_Group`：见本条 payload。
			- `FU_GROUP_W`：`FU_Group` 位宽；由 `or_be_types_pkg` 定义。
			- `G0_FU_DIV`：DIV 的 G0 组内编号；由 `or_be_types_pkg` 定义。
		- `FU_ready`：见 `Interface -> Out Static Info` 第 1 条。
		- `global_flush_late.fire`：见 `Interface -> In-event` 第 1 条。
	- Constraint：`issue_valid` 为 valid/ready Transaction；非 DIV `FU_Group` 不被接收。
	- Payload：`div_simple_issue_payload`；fire 所在上升沿采样。
		- `div_simple_issue_payload`：`rs1_data[XLEN-1:0]`、`rs2_data[XLEN-1:0]`、`FU_Group[FU_GROUP_W-1:0]`、`self_tag[TAG_W-1:0]`、`exe_subop[EXE_SUBOP_W-1:0]`；`XLEN`、`TAG_W`、`EXE_SUBOP_W` 由 `or_be_types_pkg` 定义。
	- State update：本拍上升沿 `cnt <- 2`；`busy_reg <- 1`；`entry.payload.operation.tag <- self_tag`；`entry.payload.operation.result <- div_result`；`entry.payload.completion <- 0`。
		- `self_tag`：见本条 payload。
		- `div_result = divide(exe_subop, rs1_data, rs2_data)`
			- `divide`：按 `exe_subop` 选择运算；`SUBOP_*` 编码由 `exe_subop_pkg` 定义。
				- `SUBOP_DIV`：`rs2_data=0` 时为全 1；`rs1_data=64'h8000000000000000 ∧ signed(rs2_data)=-1` 时为 `rs1_data`；其余为 `signed(rs1_data) / signed(rs2_data)`。
				- `SUBOP_DIVU`：`rs2_data=0` 时为全 1；其余为 `unsigned(rs1_data) / unsigned(rs2_data)`。
				- `SUBOP_REM`：`rs2_data=0` 时为 `rs1_data`；`rs1_data=64'h8000000000000000 ∧ signed(rs2_data)=-1` 时为 0；其余为 `signed(rs1_data) % signed(rs2_data)`。
				- `SUBOP_REMU`：`rs2_data=0` 时为 `rs1_data`；其余为 `unsigned(rs1_data) % unsigned(rs2_data)`。
				- `SUBOP_DIVW`：令 `w_res = 32'hffffffff`，若 `rs2_data[31:0]=0`；令 `w_res = 32'h80000000`，若 `rs1_data[31:0]=32'h80000000 ∧ signed(rs2_data[31:0])=-1`；其余令 `w_res = signed(rs1_data[31:0]) / signed(rs2_data[31:0])`；结果为 `{{32{w_res[31]}},w_res}`。
				- `SUBOP_DIVUW`：令 `w_res = 32'hffffffff`，若 `rs2_data[31:0]=0`；其余令 `w_res = unsigned(rs1_data[31:0]) / unsigned(rs2_data[31:0])`；结果为 `{{32{w_res[31]}},w_res}`。
				- `SUBOP_REMW`：令 `w_res = rs1_data[31:0]`，若 `rs2_data[31:0]=0`；令 `w_res = 0`，若 `rs1_data[31:0]=32'h80000000 ∧ signed(rs2_data[31:0])=-1`；其余令 `w_res = signed(rs1_data[31:0]) % signed(rs2_data[31:0])`；结果为 `{{32{w_res[31]}},w_res}`。
				- `SUBOP_REMUW`：令 `w_res = rs1_data[31:0]`，若 `rs2_data[31:0]=0`；其余令 `w_res = unsigned(rs1_data[31:0]) % unsigned(rs2_data[31:0])`；结果为 `{{32{w_res[31]}},w_res}`。
				- 其余 `exe_subop`：0。
			- `exe_subop`：见本条 payload。
			- `rs1_data`：见本条 payload。
			- `rs2_data`：见本条 payload。
4. `countdown_2_to_1`：将执行倒计时从 2 减至 1。
	- Fire来源：`countdown_2_to_1.fire = busy_reg ∧ (cnt = 2)`
		- `busy_reg`：见 `Data structure -> State` 第 2 条。
		- `cnt`：见 `Data structure -> State` 第 3 条。
	- Constraint：无额外约束。
	- Payload：∅。
	- State update：本拍上升沿 `cnt <- 1`；`entry.payload.completion <- 0`；其余状态和 `entry.payload.operation` 保持。
5. `countdown_1_to_0`：将执行倒计时从 1 减至 0。
	- Fire来源：`countdown_1_to_0.fire = busy_reg ∧ (cnt = 1)`
		- `busy_reg`：见 `Data structure -> State` 第 2 条。
		- `cnt`：见 `Data structure -> State` 第 3 条。
	- Constraint：无额外约束。
	- Payload：∅。
	- State update：本拍上升沿 `cnt <- 0`；`entry.payload.completion <- 0`；其余状态和 `entry.payload.operation` 保持。
6. `completion_publish`：把已保存的运算结果写入 completion payload。
	- Fire来源：`completion_publish.fire = busy_reg ∧ (cnt = 0) ∧ ¬entry.payload.completion.result_valid`
		- `busy_reg`：见 `Data structure -> State` 第 2 条。
		- `cnt`：见 `Data structure -> State` 第 3 条。
		- `entry.payload.completion.result_valid`：见 `Data structure -> State` 第 4 条。
	- Constraint：无额外约束。
	- Payload：`div_simple_request_payload`；本拍上升沿写入。
		- `div_simple_request_payload`：见 `Interface -> Out-event` 第 1 条。
	- State update：本拍上升沿 `entry.payload.completion.result_valid <- 1`；`entry.payload.completion.tag_out <- entry.payload.operation.tag`；`entry.payload.completion.result_data <- entry.payload.operation.result`；`entry.payload.completion.mispredict_flag <- 0`；`entry.payload.completion.mispredict_target_pc <- 0`；`entry.payload.completion.exception_flag <- 0`；`entry.payload.completion.exception_cause <- 0`；`entry.payload.completion.exception_tval <- 0`；`entry.payload.completion.is_mret <- 0`；`entry.payload.completion.is_sret <- 0`；`entry.payload.completion.fpu_fflags <- 0`；`busy_reg`、`cnt` 和 `entry.payload.operation` 保持。
7. `request_valid`：待仲裁 completion 与 `winner_grant` 完成握手并释放执行单元。
	- Fire来源：`request_valid.fire = request_valid.valid ∧ winner_grant.fire`
		- `request_valid.valid = entry.payload.completion.result_valid ∧ ¬global_flush_late.fire`
			- `entry.payload.completion.result_valid`：见 `Data structure -> State` 第 4 条。
			- `global_flush_late.fire`：见 `Interface -> In-event` 第 1 条。
		- `winner_grant.fire`：见 `Interface -> In-event` 第 3 条。
	- Constraint：`winner_grant.fire -> request_valid.valid`；未获 grant 时 request payload 保持不变。
	- Payload：`div_simple_request_payload`；fire 所在上升沿采样。
		- `div_simple_request_payload`：见 `Interface -> Out-event` 第 1 条。
	- State update：本拍上升沿 `busy_reg <- 0`；`entry.payload.completion <- 0`；`cnt` 和 `entry.payload.operation` 保持。

## Data structure

### State

1. `execution_state`：由 `busy_reg`、`cnt` 和 `entry.payload.completion.result_valid` 编码；`busy_reg=0` 为 `IDLE`；`busy_reg=1 ∧ cnt=2` 为 `EXECUTE_2`；`busy_reg=1 ∧ cnt=1` 为 `EXECUTE_1`；`busy_reg=1 ∧ cnt=0 ∧ entry.payload.completion.result_valid=0` 为 `WRITEBACK`；`busy_reg=1 ∧ cnt=0 ∧ entry.payload.completion.result_valid=1` 为 `COMPLETION_PENDING`。
2. `busy_reg`：1 bit；为 1 表示已接收的运算仍占用执行单元，包括执行和等待仲裁阶段；由 `reset`、`global_flush_late`、`issue_valid` 和 `request_valid` 更新。
3. `cnt`：2 bit；执行倒计时，取值 2、1、0；由 `reset`、`global_flush_late`、`issue_valid`、`countdown_2_to_1` 和 `countdown_1_to_0` 更新。
4. `entry.payload.completion.result_valid`：1 bit；completion payload 有效位；由 `reset`、`global_flush_late`、`issue_valid`、`countdown_2_to_1`、`countdown_1_to_0`、`completion_publish` 和 `request_valid` 更新。

### Header

无。

### Payload

1. `entry.payload.operation`：来源于 `div_simple_issue_payload`。
	- `div_simple_issue_payload`：`rs1_data`、`rs2_data`、`self_tag`、`exe_subop`；见 `FSM -> Detailed Condition Description` 第 3 条。
2. `entry.payload.completion`：来源于 `entry.payload.operation`。
	- `entry.payload.operation`：`tag`、`result`；见本节第 1 条。

## Internal Connections

无。

## Interface

### In-event

1. `global_flush_late`：Notify，单 lane。
	- Fire来源：`global_flush_late.fire`
	- Payload：∅；当前拍 pulse。
2. `issue_valid`：Transaction，单 lane。
	- Fire来源：见 `FSM -> Detailed Condition Description` 第 3 条。
	- Payload：`div_simple_issue_payload`；fire 所在上升沿采样。
	`div_simple_issue_payload`：`rs1_data` `XLEN` bit × 1、`rs2_data` `XLEN` bit × 1、`FU_Group` `FU_GROUP_W` bit × 1、`self_tag` `TAG_W` bit × 1、`exe_subop` `EXE_SUBOP_W` bit × 1。
3. `winner_grant`：Notify，单 lane。
	- Fire来源：`winner_grant.fire`
	- Payload：∅；当前拍 pulse。

### In Static Info

1. `rst_n`：1 bit；低有效异步复位；由全部状态和 payload 寄存器读取。
2. `loser_hold`：1 bit × 1；仲裁失败保持指示；用于 `FU_ready`。

### Out-event

1. `request_valid`：Transaction，单 lane。
	- Fire来源：见 `FSM -> Detailed Condition Description` 第 7 条。
	- Payload：`div_simple_request_payload`；valid 期间持续有效，fire 所在上升沿采样。
	`div_simple_request_payload`：`req_tag` `TAG_W` bit × 1、`req_result_data` `XLEN` bit × 1、`req_mispredict_flag` 1 bit × 1、`req_mispredict_target_pc` `XLEN` bit × 1、`req_exception_flag` 1 bit × 1、`req_exception_cause` `EXCP_CAUSE_W` bit × 1、`req_exception_tval` `XLEN` bit × 1、`req_is_mret` 1 bit × 1、`req_is_sret` 1 bit × 1、`req_fpu_fflags` `FFLAGS_W` bit × 1、`req_is_csr` 1 bit × 1、`req_csr_write_enable` 1 bit × 1、`req_csr_addr` `CSR_ADDR_W` bit × 1、`req_csr_wdata` `XLEN` bit × 1；`EXCP_CAUSE_W`、`FFLAGS_W`、`CSR_ADDR_W` 由 `or_be_types_pkg` 定义。
		- `req_tag = entry.payload.completion.tag_out`
			- `entry.payload.completion.tag_out`：见 `Data structure -> Payload` 第 2 条。
		- `req_result_data = entry.payload.completion.result_data`
			- `entry.payload.completion.result_data`：见 `Data structure -> Payload` 第 2 条。
		- `req_mispredict_flag = entry.payload.completion.mispredict_flag`
			- `entry.payload.completion.mispredict_flag`：见 `Data structure -> Payload` 第 2 条；值为 0。
		- `req_mispredict_target_pc = entry.payload.completion.mispredict_target_pc`
			- `entry.payload.completion.mispredict_target_pc`：见 `Data structure -> Payload` 第 2 条；值为 0。
		- `req_exception_flag = entry.payload.completion.exception_flag`
			- `entry.payload.completion.exception_flag`：见 `Data structure -> Payload` 第 2 条；值为 0。
		- `req_exception_cause = entry.payload.completion.exception_cause`
			- `entry.payload.completion.exception_cause`：见 `Data structure -> Payload` 第 2 条；值为 0。
		- `req_exception_tval = entry.payload.completion.exception_tval`
			- `entry.payload.completion.exception_tval`：见 `Data structure -> Payload` 第 2 条；值为 0。
		- `req_is_mret = entry.payload.completion.is_mret`
			- `entry.payload.completion.is_mret`：见 `Data structure -> Payload` 第 2 条；值为 0。
		- `req_is_sret = entry.payload.completion.is_sret`
			- `entry.payload.completion.is_sret`：见 `Data structure -> Payload` 第 2 条；值为 0。
		- `req_fpu_fflags = entry.payload.completion.fpu_fflags`
			- `entry.payload.completion.fpu_fflags`：见 `Data structure -> Payload` 第 2 条；值为 0。
		- `req_is_csr = 0`。
		- `req_csr_write_enable = 0`。
		- `req_csr_addr = 0`。
		- `req_csr_wdata = 0`。

### Out Static Info

1. `FU_ready`：1 bit × 1；当前拍组合有效。
	- `FU_ready = ¬busy_reg ∧ ¬loser_hold`
		- `busy_reg`：见 `Data structure -> State` 第 2 条。
		- `loser_hold`：见 `Interface -> In Static Info` 第 2 条。

### Interface Timing

1. `clk`：所有非异步复位状态和 payload 在上升沿采样或更新。
2. `rst_n`：低有效异步复位；为 0 时清除 `cnt`、`busy_reg`、运算 payload 和 completion payload。
3. `Transaction`：`issue_valid` 的 valid 与 payload 由输入方保持至 `issue_valid.fire`；`request_valid.valid` 与全部 payload 由本模块保持至 `request_valid.fire`，`winner_grant.fire` 为其 ready/accept 动作。
4. `Notify`：`global_flush_late.fire` 和 `winner_grant.fire` 为当前拍 pulse，在该拍上升沿采样。
5. `Static Info`：当前拍组合有效；flush 拍 `request_valid.valid=0`，`FU_ready` 仍按 `¬busy_reg ∧ ¬loser_hold` 计算。
