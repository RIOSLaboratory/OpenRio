# Module `csr_unit`

`csr_unit`：单 lane、单周期 CSR 执行单元；接收 G0 的 CSR issue，读取外部 CSR 旧值，生成一拍后的 completion request，并在仲裁成功前保持请求。

## Submodule

无。

## FSM

### State

1. `COMPLETION_EMPTY`：无待仲裁 completion request。
2. `COMPLETION_PENDING`：已保存一个 completion request，等待 `winner_grant`。

### State Transition & Condition Name

1. `ANY -> COMPLETION_EMPTY`：`reset`。
2. `ANY -> COMPLETION_EMPTY`：`global_flush_late`。
3. `COMPLETION_EMPTY -> COMPLETION_PENDING`：`issue_valid`。
4. `COMPLETION_PENDING -> COMPLETION_EMPTY`：`request_valid`。

### Detailed Condition Description

1. `reset`：异步清除 completion 状态和全部 payload 寄存器。
	- Fire来源：`reset.fire = ¬rst_n`
		- `rst_n`：见 `Interface -> In Static Info` 第 1 条。
	- Constraint：低有效异步复位。
	- Payload：∅。
	- State update：`busy_q <- 0`；`tag_q`、`result_data_q`、`exception_flag_q`、`exception_cause_q`、`exception_tval_q`、`is_csr_q`、`csr_write_enable_q`、`csr_addr_q`、`csr_wdata_q <- 0`。
2. `global_flush_late`：取消正在执行或等待仲裁的 completion。
	- Fire来源：`global_flush_late.fire`
		- `global_flush_late.fire`：见 `Interface -> In-event` 第 1 条。
	- Constraint：本拍禁止 `issue_valid.fire` 和 `request_valid.fire`。
	- Payload：∅。
	- State update：本拍上升沿 `busy_q <- 0`；所有 completion payload 寄存器清零。
3. `issue_valid`：接收一个目标为 CSR FU 的 issue，并在本拍上升沿采样 CSR completion 内容。
	- Fire来源：`issue_valid.fire = issue_valid.valid ∧ fu_selected ∧ FU_ready ∧ ¬global_flush_late.fire`
		- `issue_valid.valid`：输入 issue 请求有效；见 `Interface -> In-event` 第 2 条。
		- `fu_selected = (FU_Group = FU_GROUP_W'(G0_FU_CSR))`
			- `FU_Group`：见本条 payload。
			- `FU_GROUP_W`、`G0_FU_CSR`：由 `or_be_types_pkg` 定义。
		- `FU_ready`：见 `Interface -> Out Static Info` 第 2 条。
		- `global_flush_late.fire`：见 `Interface -> In-event` 第 1 条。
	- Constraint：`issue_valid` 为 valid/ready Transaction；`FU_ready=0` 或非 CSR `FU_Group` 时不接收。
	- Payload：`csr_unit_issue_payload`；fire 所在上升沿采样。
		- `csr_unit_issue_payload`：`rs1_data[XLEN-1:0]`、`FU_Group[FU_GROUP_W-1:0]`、`imm_valid`、`imm_data[XLEN-1:0]`、`inst_bits[31:0]`、`self_tag[TAG_W-1:0]`、`exe_subop[EXE_SUBOP_W-1:0]`、`full_decode[FULL_DECODE_W-1:0]`。
	- State update：本拍上升沿 `busy_q <- 1`，并写入：
		- `tag_q <- self_tag`。
		- `result_data_q <- csr_rdata`。
		- `exception_flag_q <- ¬legal_csr_addr`。
		- `exception_cause_q <- ¬legal_csr_addr ? CAUSE_ILLEGAL_INSTRUCTION : 0`；`CAUSE_ILLEGAL_INSTRUCTION = EXCP_CAUSE_W'(2)`。
		- `exception_tval_q <- ¬legal_csr_addr ? {{(XLEN-32){1'b0}},inst_bits} : 0`。
		- `is_csr_q <- 1`。
		- `csr_write_enable_q <- csr_write_en ∧ csr_write_intent ∧ legal_csr_addr`。
		- `csr_addr_q <- exe_csr_addr`；`csr_wdata_q <- next_csr_wdata`。
		- `csr_write_intent = full_decode_t'(full_decode).csr_write_intent`；`exe_csr_addr = full_decode_t'(full_decode).csr_addr`。
		- `csr_src = imm_valid ? imm_data : rs1_data`。
		- `next_csr_wdata` 与 `csr_write_en`：`SUBOP_CSRRW/SUBOP_CSRRWI` 时分别为 `csr_src`、`1`；`SUBOP_CSRRS/SUBOP_CSRRSI` 时分别为 `csr_rdata ∨ csr_src`、`1`；`SUBOP_CSRRC/SUBOP_CSRRCI` 时分别为 `csr_rdata ∧ ¬csr_src`、`1`；其余为 `csr_rdata`、`0`。
		- `legal_csr_addr = legal_csr_addr_tbl ∧ priv_ok ∧ ¬tvm_blocked`。
			- `legal_csr_addr_tbl`：`0x001/0x002/0x003` 为 `fs_enabled`；`0x300/0x301/0x302/0x303/0x304/0x305/0x340/0x341/0x342/0x343/0x344/0x3A0/0x3B0/0xB00/0xB02` 为 `1`；`0x100/0x104/0x105/0x140/0x141/0x142/0x143/0x144/0x180` 为 `ENABLE_S`；`0xF11/0xF12/0xF13/0xF14/0xC00/0xC02` 为 `¬csr_write_intent`；其余为 `0`。
			- `priv_ok = (csr_addr[9:8] <= current_priv)`；`csr_addr` 见 `Interface -> Out Static Info` 第 1 条，`current_priv` 见 `Interface -> In Static Info` 第 3 条。
			- `tvm_blocked = mstatus_tvm ∧ (current_priv = 2'b01) ∧ (csr_addr = 12'h180)`；`mstatus_tvm` 见 `Interface -> In Static Info` 第 4 条。
		- `csr_rdata`、`fs_enabled`：见 `Interface -> In Static Info` 第 2、5 条。
4. `request_valid`：待仲裁 completion 与 `winner_grant` 完成握手。
	- Fire来源：`request_valid.fire = request_valid.valid ∧ winner_grant.fire`
		- `request_valid.valid = busy_q ∧ ¬global_flush_late.fire`
			- `busy_q`：见 `Data structure -> State` 第 2 条。
			- `global_flush_late.fire`：见 `Interface -> In-event` 第 1 条。
		- `winner_grant.fire`：见 `Interface -> In-event` 第 3 条。
	- Constraint：valid 及全部 payload 保持至 `request_valid.fire`；`global_flush_late.fire=1` 时取消输出。
	- Payload：`csr_unit_request_payload`；valid 期间持续有效，fire 所在上升沿采样。
	- State update：本拍上升沿 `busy_q <- 0`；completion payload 寄存器清零。

## Data structure

### State

1. `completion_state`：由 `busy_q` 编码；`0` 为 `COMPLETION_EMPTY`，`1` 为 `COMPLETION_PENDING`；由 `reset`、`global_flush_late`、`issue_valid`、`request_valid` 更新。
2. `busy_q`：1 bit；completion 槽有效位；低有效异步复位为 0。

### Header

无。

### Payload

1. `entry.payload.completion`：来源于 `csr_unit_issue_payload` 和 static info。
	- `csr_unit_issue_payload`：`self_tag`、`inst_bits`、`exe_subop`、`full_decode`、`imm_valid`、`imm_data`、`rs1_data`。
	- `csr_rdata`、`current_priv`、`mstatus_tvm`、`fs_enabled`。

## Internal Connections

无。

## Interface

### In-event

1. `global_flush_late`：Notify，单 lane。
	- Fire来源：`global_flush_late.fire`
	- Payload：∅；当前拍 pulse。
2. `issue_valid`：Transaction，单 lane。
	- Fire来源：见 `FSM -> Detailed Condition Description` 第 3 条。
	- Payload：`csr_unit_issue_payload`；fire 所在上升沿采样。
	`csr_unit_issue_payload`：`rs1_data` `XLEN` bit × 1、`FU_Group` `FU_GROUP_W` bit × 1、`imm_valid` 1 bit × 1、`imm_data` `XLEN` bit × 1、`inst_bits` 32 bit × 1、`self_tag` `TAG_W` bit × 1、`exe_subop` `EXE_SUBOP_W` bit × 1、`full_decode` `FULL_DECODE_W` bit × 1。
3. `winner_grant`：Notify，单 lane。
	- Fire来源：`winner_grant.fire`
	- Payload：∅；当前拍 pulse。

### In Static Info

1. `rst_n`：1 bit；低有效异步复位；由状态寄存器读取。
2. `csr_rdata`：`XLEN` bit × 1；`csr_addr` 对应 CSR 的当前旧值；用于读结果和读改写计算。
3. `current_priv`：`PRIV_W` bit × 1；当前特权级；用于 CSR 最低特权级和 TVM 检查。
4. `mstatus_tvm`：1 bit × 1；M 态 TVM 控制；用于阻止 S 态访问 `satp`。
5. `fs_enabled`：1 bit × 1；浮点状态是否启用；用于 `fflags/frm/fcsr` 地址合法性。
6. `loser_hold`：1 bit × 1；仲裁失败保持指示；用于 `FU_ready`。

### Out-event

1. `request_valid`：Transaction，单 lane。
	- Fire来源：见 `FSM -> Detailed Condition Description` 第 4 条。
	- Payload：`csr_unit_request_payload`；valid 期间持续有效，fire 所在上升沿采样。
	`csr_unit_request_payload`：`req_tag` `TAG_W` bit × 1、`req_result_data` `XLEN` bit × 1、`req_mispredict_flag` 1 bit × 1、`req_mispredict_target_pc` `XLEN` bit × 1、`req_exception_flag` 1 bit × 1、`req_exception_cause` `EXCP_CAUSE_W` bit × 1、`req_exception_tval` `XLEN` bit × 1、`req_is_mret` 1 bit × 1、`req_is_sret` 1 bit × 1、`req_fpu_fflags` `FFLAGS_W` bit × 1、`req_is_csr` 1 bit × 1、`req_csr_write_enable` 1 bit × 1、`req_csr_addr` `CSR_ADDR_W` bit × 1、`req_csr_wdata` `XLEN` bit × 1。
		- `req_tag = entry.payload.completion.tag`；`req_result_data = entry.payload.completion.result_data`；`req_exception_flag = entry.payload.completion.exception_flag`；`req_exception_cause = entry.payload.completion.exception_cause`；`req_exception_tval = entry.payload.completion.exception_tval`；`req_is_csr = entry.payload.completion.is_csr`；`req_csr_write_enable = entry.payload.completion.csr_write_enable`；`req_csr_addr = entry.payload.completion.csr_addr`；`req_csr_wdata = entry.payload.completion.csr_wdata`。
			- `entry.payload.completion`：见 `Data structure -> Payload` 第 1 条。
		- `req_mispredict_flag = 0`；`req_mispredict_target_pc = 0`；`req_is_mret = 0`；`req_is_sret = 0`；`req_fpu_fflags = 0`。

### Out Static Info

1. `csr_addr`：`CSR_ADDR_W` bit × 1；当前拍组合有效。
	- `csr_addr = exe_csr_addr`
		- `exe_csr_addr = full_decode_t'(full_decode).csr_addr`
			- `full_decode`：见 `Interface -> In-event` 第 2 条 payload。
2. `FU_ready`：1 bit × 1；当前拍组合有效。
	- `FU_ready = ¬busy_q ∧ ¬loser_hold`
		- `busy_q`：见 `Data structure -> State` 第 2 条。
		- `loser_hold`：见 `Interface -> In Static Info` 第 6 条。

### Interface Timing

1. `clk`：所有非复位状态和 completion payload 在上升沿采样或更新。
2. `rst_n`：低有效异步复位；为 0 时清除 `busy_q` 及 completion payload 寄存器。
3. `Transaction`：`issue_valid` 的 valid 与 payload 由输入方保持至本模块定义的 fire；`request_valid.valid` 与全部 payload 由本模块保持至 `winner_grant.fire`。
4. `Notify`：`global_flush_late.fire`、`winner_grant.fire` 为当前拍 pulse，在该拍上升沿采样。
5. `Static Info`：当前拍组合有效；flush 拍 `request_valid.valid=0`，`FU_ready` 仍按 `¬busy_q ∧ ¬loser_hold` 计算。
