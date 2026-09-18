# Module `alu_simple`

`alu_simple`：单 lane、单周期执行的整数 ALU/BRU；`XLEN=64`。completion 请求寄存后保持至仲裁成功，分支预测器更新寄存一拍后独立发出。

## Submodule

无。

## FSM

### State

1. `COMPLETION_EMPTY`：completion 槽无有效请求。
2. `COMPLETION_PENDING`：completion 槽保存一个有效请求并等待仲裁成功。
3. `PREDICTOR_IDLE`：predictor update 管线无有效更新。
4. `PREDICTOR_VALID`：predictor update 管线保存一个有效更新。

`completion_state` 与 `predictor_state` 为正交状态域。

### State Transition & Condition Name

1. `ANY -> COMPLETION_EMPTY`，`ANY -> PREDICTOR_IDLE`：`reset`
2. `ANY -> COMPLETION_EMPTY`，`ANY -> PREDICTOR_IDLE`：`global_flush_late`
3. `COMPLETION_EMPTY -> COMPLETION_PENDING`，`COMPLETION_PENDING -> COMPLETION_PENDING`；BRU 时 `PREDICTOR_IDLE -> PREDICTOR_VALID`、`PREDICTOR_VALID -> PREDICTOR_VALID`，非 BRU 时 `PREDICTOR_IDLE -> PREDICTOR_IDLE`、`PREDICTOR_VALID -> PREDICTOR_IDLE`：`issue_valid`
4. 无同拍 `issue_valid` 时 `COMPLETION_PENDING -> COMPLETION_EMPTY`；同拍 `issue_valid` 时 `COMPLETION_PENDING -> COMPLETION_PENDING`：`request_valid`
5. 无同拍 BRU `issue_valid` 时 `PREDICTOR_VALID -> PREDICTOR_IDLE`；同拍 BRU `issue_valid` 时 `PREDICTOR_VALID -> PREDICTOR_VALID`：`predictor_update_valid`

### Detailed Condition Description

1. `reset`：异步清除全部有效状态和 payload。
	- Fire来源：`reset.fire = ¬rst_n`
		- `rst_n`：见 `Interface -> In Static Info` 第 1 条。
	- Constraint：低有效异步复位。
	- Payload：∅。
	- State update：`comp_q <- 0`；`pu_valid_q <- 0`；`pu_branch_pc_q <- 0`；`pu_actual_taken_q <- 0`；`pu_actual_target_q <- 0`；`pu_cf_class_q <- cf_class_e'(0)`。
2. `global_flush_late`：取消 completion 请求和 predictor update。
	- Fire来源：`global_flush_late.fire`
		- `global_flush_late.fire`：见 `Interface -> In-event` 第 1 条。
	- Constraint：本拍禁止 `issue_valid.fire`、`request_valid.fire` 和 `predictor_update_valid.fire`。
	- Payload：∅。
	- State update：本拍上升沿 `comp_q <- 0`；`pu_valid_q <- 0`；predictor payload 寄存器按第 3 条中的当前输入组合值更新，但保持无效。
3. `issue_valid`：接收一个寻址到本实例的 ALU/BRU 请求，并产生下一拍 completion 内容及 predictor update 内容。
	- Fire来源：`issue_valid.fire = issue_valid.valid ∧ FU_ready ∧ (FU_Group = FU_GROUP_W'(G0_FU_ALU)) ∧ ¬global_flush_late.fire`
		- `issue_valid.valid`：输入请求有效；见 `Interface -> In-event` 第 2 条。
		- `FU_ready`：见 `Interface -> Out Static Info` 第 1 条。
		- `FU_Group`：目标组内 FU 编号；见 `Interface -> In-event` 第 2 条 payload。
		- `FU_GROUP_W`：`FU_Group` 位宽；由 `or_be_types_pkg` 定义。
		- `G0_FU_ALU`：ALU 在 G0 与 G1 中共同使用的组内编号；由 `or_be_types_pkg` 定义。
		- `global_flush_late.fire`：见 `Interface -> In-event` 第 1 条。
	- Constraint：当 `completion_state=COMPLETION_PENDING` 时，`winner_grant.fire` 与 `loser_hold` 表示当前请求仲裁成功或失败；`loser_hold=1` 时 `FU_ready=0`，不接收新请求。
	- Payload：`alu_simple_issue_payload`；本拍上升沿采样。
		- `alu_simple_issue_payload`：`rs1_data[XLEN-1:0]`、`rs2_data[XLEN-1:0]`、`FU_Group[FU_GROUP_W-1:0]`、`imm_data[XLEN-1:0]`、`pc[XLEN-1:0]`、`inst_bits[31:0]`、`is_compressed`、`pred_taken`、`pred_target_pc[XLEN-1:0]`、`self_tag[TAG_W-1:0]`、`exe_subop[EXE_SUBOP_W-1:0]`、`full_decode[FULL_DECODE_W-1:0]`、`fetch_excp_vld`、`fetch_excp_cause[FETCH_EXCP_CAUSE_W-1:0]`、`fetch_excp_tval[XLEN-1:0]`；`TAG_W`、`EXE_SUBOP_W`、`FULL_DECODE_W`、`FETCH_EXCP_CAUSE_W` 由 package 定义。
	- State update：若 `hold_request=0`，先令 `comp_q <- 0`；若同时 `issue_valid.fire=1`，本拍上升沿令 `completion_state <- COMPLETION_PENDING`，并按以下公式更新 `entry.payload.completion`；若 `hold_request=1`，`comp_q` 全部字段保持。predictor 管线每个非复位上升沿均按以下公式更新。
		- `hold_request = comp_q.result_valid ∧ ¬winner_ack`
			- `comp_q.result_valid`：见 `Data structure -> State` 第 2 条。
			- `winner_ack = winner_grant.fire ∧ ¬global_flush_late.fire`
				- `winner_grant.fire`：见 `Interface -> In-event` 第 3 条。
				- `global_flush_late.fire`：见 `Interface -> In-event` 第 1 条。
		- `entry.payload.completion.tag_out <- self_tag`。
		- `entry.payload.completion.result_data <- is_bru_op ? branch_link_data : alu_result`
			- `is_bru_op = is_g0_bru_subop(exe_subop)`
				- `exe_subop`：见本条 payload。
			- `branch_link_data = ((exe_subop=SUBOP_JAL) ∨ (exe_subop=SUBOP_JALR) ∨ (exe_subop=SUBOP_C_J) ∨ (exe_subop=SUBOP_C_JR) ∨ (exe_subop=SUBOP_C_JALR)) ? fallthrough_pc : 0`
				- `exe_subop`：见本条 payload。
				- `fallthrough_pc = is_compressed ? (pc + 64'd2) : (pc + 64'd4)`
					- `is_compressed`：见本条 payload。
					- `pc`：见本条 payload。
			- `alu_result = alu(exe_subop, rs1_data, rs2_data, imm_data, pc)`
				- `alu`：
					- `SUBOP_ADD: rs1_data + rs2_data`；`SUBOP_ADDI: rs1_data + imm_data`；`SUBOP_SUB: rs1_data - rs2_data`。
					- `SUBOP_AND: rs1_data ∧ rs2_data`；`SUBOP_ANDI: rs1_data ∧ imm_data`；`SUBOP_OR: rs1_data ∨ rs2_data`；`SUBOP_ORI: rs1_data ∨ imm_data`；`SUBOP_XOR: rs1_data ⊕ rs2_data`；`SUBOP_XORI: rs1_data ⊕ imm_data`。
					- `SUBOP_SLL: rs1_data << rs2_data[5:0]`；`SUBOP_SLLI: rs1_data << imm_data[5:0]`；`SUBOP_SRL: rs1_data >> rs2_data[5:0]`；`SUBOP_SRLI: rs1_data >> imm_data[5:0]`；`SUBOP_SRA: signed(rs1_data) >>> rs2_data[5:0]`；`SUBOP_SRAI: signed(rs1_data) >>> imm_data[5:0]`。
					- `SUBOP_SLT: signed(rs1_data) < signed(rs2_data) ? 64'd1 : 64'd0`；`SUBOP_SLTI: signed(rs1_data) < signed(imm_data) ? 64'd1 : 64'd0`；`SUBOP_SLTU: rs1_data < rs2_data ? 64'd1 : 64'd0`；`SUBOP_SLTIU: rs1_data < imm_data ? 64'd1 : 64'd0`。
					- `SUBOP_LUI: imm_data`；`SUBOP_AUIPC: pc + imm_data`。
					- `SUBOP_ADDIW: sext32(rs1_data[31:0] + imm_data[31:0])`；`SUBOP_ADDW: sext32(rs1_data[31:0] + rs2_data[31:0])`；`SUBOP_SUBW: sext32(rs1_data[31:0] - rs2_data[31:0])`。
					- `SUBOP_SLLIW: sext32(rs1_data[31:0] << imm_data[4:0])`；`SUBOP_SLLW: sext32(rs1_data[31:0] << rs2_data[4:0])`；`SUBOP_SRLIW: sext32(rs1_data[31:0] >> imm_data[4:0])`；`SUBOP_SRLW: sext32(rs1_data[31:0] >> rs2_data[4:0])`；`SUBOP_SRAIW: sext32(signed(rs1_data[31:0]) >>> imm_data[4:0])`；`SUBOP_SRAW: sext32(signed(rs1_data[31:0]) >>> rs2_data[4:0])`。
					- `SUBOP_C_ADDI4SPN`、`SUBOP_C_ADDI16SP`、`SUBOP_C_ADDI`、`SUBOP_C_LI: rs1_data + imm_data`；`SUBOP_C_NOP: 0`；`SUBOP_C_LUI: imm_data`；`SUBOP_C_ADDIW: sext32(rs1_data[31:0] + imm_data[31:0])`。
					- `SUBOP_C_SLLI: rs1_data << imm_data[5:0]`；`SUBOP_C_SRLI: rs1_data >> imm_data[5:0]`；`SUBOP_C_SRAI: signed(rs1_data) >>> imm_data[5:0]`；`SUBOP_C_ANDI: rs1_data ∧ imm_data`。
					- `SUBOP_C_MV`、`SUBOP_C_ADD: rs1_data + rs2_data`；`SUBOP_C_SUB: rs1_data - rs2_data`；`SUBOP_C_AND: rs1_data ∧ rs2_data`；`SUBOP_C_OR: rs1_data ∨ rs2_data`；`SUBOP_C_XOR: rs1_data ⊕ rs2_data`；`SUBOP_C_ADDW: sext32(rs1_data[31:0] + rs2_data[31:0])`；`SUBOP_C_SUBW: sext32(rs1_data[31:0] - rs2_data[31:0])`。
					- `SUBOP_ECALL` 及其余 `exe_subop: 0`。
				- `sext32(value) = {{32{value[31]}}, value[31:0]}`。
				- `rs1_data`、`rs2_data`、`imm_data`、`pc`：见本条 payload。
		- `entry.payload.completion.mispredict_flag <- is_bru_op ∧ ((branch_taken ≠ pred_taken) ∨ (branch_taken ∧ (pred_target_pc ≠ branch_target)))`
			- `is_bru_op`：见本条 `result_data` 公式。
			- `branch_taken`、`branch_target`：由 `branch(exe_subop, rs1_data, rs2_data, imm_data, pc, fallthrough_pc)` 产生。
				- `SUBOP_JAL`、`SUBOP_C_J: branch_taken=1, branch_target=pc+imm_data`。
				- `SUBOP_JALR`、`SUBOP_C_JR`、`SUBOP_C_JALR: branch_taken=1, branch_target=(rs1_data+imm_data) ∧ ~64'd1`。
				- `SUBOP_BEQ`、`SUBOP_C_BEQZ: branch_taken=(rs1_data=rs2_data), branch_target=pc+imm_data`。
				- `SUBOP_BNE`、`SUBOP_C_BNEZ: branch_taken=(rs1_data≠rs2_data), branch_target=pc+imm_data`。
				- `SUBOP_BLT: branch_taken=(signed(rs1_data)<signed(rs2_data)), branch_target=pc+imm_data`；`SUBOP_BGE: branch_taken=(signed(rs1_data)≥signed(rs2_data)), branch_target=pc+imm_data`。
				- `SUBOP_BLTU: branch_taken=(rs1_data<rs2_data), branch_target=pc+imm_data`；`SUBOP_BGEU: branch_taken=(rs1_data≥rs2_data), branch_target=pc+imm_data`。
				- 其余 `exe_subop: branch_taken=0, branch_target=fallthrough_pc`。
				- `exe_subop`、`rs1_data`、`rs2_data`、`imm_data`、`pc`：见本条 payload；`fallthrough_pc`：见本条 `result_data` 公式。
			- `pred_taken`、`pred_target_pc`：见本条 payload。
		- `entry.payload.completion.mispredict_target_pc <- correct_pc`
			- `correct_pc = branch_taken ? branch_target : fallthrough_pc`
				- `branch_taken`、`branch_target`：见本条 `mispredict_flag` 公式。
				- `fallthrough_pc`：见本条 `result_data` 公式。
		- `entry.payload.completion.exception_flag <- fetch_excp_vld ∨ is_illegal_op ∨ is_ecall_op ∨ is_ebreak_op`
			- `fetch_excp_vld`：见本条 payload。
			- `is_illegal_op = issue_valid.fire ∧ (fd.illegal ∨ xret_priv_bad ∨ wfi_blocked ∨ sfence_blocked)`
				- `fd = full_decode_t'(full_decode)`；`full_decode` 见本条 payload。
				- `xret_priv_bad = ((exe_subop=SUBOP_MRET) ∧ (current_priv≠2'b11)) ∨ ((exe_subop=SUBOP_SRET) ∧ (current_priv=2'b00)) ∨ ((exe_subop=SUBOP_SRET) ∧ (current_priv=2'b01) ∧ mstatus_tsr)`
					- `exe_subop`：见本条 payload。
					- `current_priv`、`mstatus_tsr`：见 `Interface -> In Static Info` 第 2、3 条。
				- `wfi_blocked = (exe_subop=SUBOP_WFI) ∧ (current_priv≠2'b11) ∧ mstatus_tw`
					- `exe_subop`：见本条 payload。
					- `current_priv`、`mstatus_tw`：见 `Interface -> In Static Info` 第 2、4 条。
				- `sfence_blocked = (exe_subop=SUBOP_SFENCE_VMA) ∧ ((current_priv=2'b00) ∨ ((current_priv=2'b01) ∧ mstatus_tvm))`
					- `exe_subop`：见本条 payload。
					- `current_priv`、`mstatus_tvm`：见 `Interface -> In Static Info` 第 2、5 条。
			- `is_ecall_op = issue_valid.fire ∧ (exe_subop=SUBOP_ECALL)`；`exe_subop` 见本条 payload。
			- `is_ebreak_op = issue_valid.fire ∧ ((exe_subop=SUBOP_EBREAK) ∨ (exe_subop=SUBOP_C_EBREAK))`；`exe_subop` 见本条 payload。
		- `entry.payload.completion.exception_cause <- fetch_excp_vld ? EXCP_CAUSE_W'(fetch_excp_cause) : is_illegal_op ? EXCP_CAUSE_W'(2) : is_ecall_op ? ecall_cause : is_ebreak_op ? EXCP_CAUSE_W'(3) : EXCP_CAUSE_W'(0)`
			- `fetch_excp_vld`、`fetch_excp_cause`：见本条 payload。
			- `is_illegal_op`、`is_ecall_op`、`is_ebreak_op`：见本条 `exception_flag` 公式。
			- `ecall_cause = (current_priv=2'b00) ? EXCP_CAUSE_W'(8) : (current_priv=2'b01) ? EXCP_CAUSE_W'(9) : EXCP_CAUSE_W'(11)`
				- `current_priv`：见 `Interface -> In Static Info` 第 2 条。
		- `entry.payload.completion.exception_tval <- fetch_excp_vld ? fetch_excp_tval : is_illegal_op ? (is_compressed ? {48'b0,inst_bits[15:0]} : {32'b0,inst_bits}) : is_ebreak_op ? pc : 0`
			- `fetch_excp_vld`、`fetch_excp_tval`、`is_compressed`、`inst_bits`、`pc`：见本条 payload。
			- `is_illegal_op`、`is_ebreak_op`：见本条 `exception_flag` 公式。
		- `entry.payload.completion.is_mret <- issue_valid.fire ∧ (exe_subop=SUBOP_MRET) ∧ ¬xret_priv_bad`
			- `exe_subop`：见本条 payload。
			- `xret_priv_bad`：见本条 `exception_flag` 公式。
		- `entry.payload.completion.is_sret <- issue_valid.fire ∧ (exe_subop=SUBOP_SRET) ∧ ¬xret_priv_bad`
			- `exe_subop`：见本条 payload。
			- `xret_priv_bad`：见本条 `exception_flag` 公式。
		- `entry.payload.completion.fpu_fflags <- 0`；`entry.payload.completion.is_csr <- 0`；`entry.payload.completion.csr_write_enable <- 0`；`entry.payload.completion.csr_addr <- 0`；`entry.payload.completion.csr_wdata <- 0`。
		- `pu_valid_q <- issue_valid.fire ∧ is_bru_op`；`pu_branch_pc_q <- pc`；`pu_actual_taken_q <- branch_taken`；`pu_actual_target_q <- correct_pc`；`pu_cf_class_q <- cf_class`。
			- `is_bru_op`：见本条 `result_data` 公式；`pc` 见本条 payload；`branch_taken` 见本条 `mispredict_flag` 公式；`correct_pc` 见本条 `mispredict_target_pc` 公式。
			- `cf_class = classify(exe_subop)`
				- `SUBOP_BEQ`、`SUBOP_BNE`、`SUBOP_BLT`、`SUBOP_BGE`、`SUBOP_BLTU`、`SUBOP_BGEU`、`SUBOP_C_BEQZ`、`SUBOP_C_BNEZ: CF_COND_BRANCH`。
				- `SUBOP_JAL`、`SUBOP_C_J: CF_JUMP_DIRECT`。
				- `SUBOP_JALR`、`SUBOP_C_JR`、`SUBOP_C_JALR: CF_JUMP_INDIRECT`。
				- 其余 `exe_subop: CF_RESERVED`。
4. `request_valid`：completion 请求与仲裁器完成握手；若同拍接收新 issue，则以新 completion 替换旧 completion。
	- Fire来源：`request_valid.fire = request_valid.valid ∧ winner_grant.fire`
		- `request_valid.valid = comp_q.result_valid ∧ ¬global_flush_late.fire`
			- `comp_q.result_valid`：见 `Data structure -> State` 第 2 条。
			- `global_flush_late.fire`：见 `Interface -> In-event` 第 1 条。
		- `winner_grant.fire`：见 `Interface -> In-event` 第 3 条。
	- Constraint：`request_valid.valid` 保持至 `request_valid.fire` 或 `global_flush_late.fire`；保持期间全部 payload 不变。
	- Payload：`alu_simple_request_payload`；`request_valid.valid=1` 时持续有效，`request_valid.fire` 所在上升沿采样。
		- `alu_simple_request_payload`：见 `Interface -> Out-event` 第 1 条。
	- State update：若同拍无 `issue_valid.fire`，本拍上升沿 `comp_q <- 0`，`completion_state <- COMPLETION_EMPTY`；若同拍有 `issue_valid.fire`，按第 3 条写入新 completion，`completion_state <- COMPLETION_PENDING`。
5. `predictor_update_valid`：广播前一拍已接收 BRU 的预测器更新，不等待 completion 仲裁。
	- Fire来源：`predictor_update_valid.fire = pu_valid_q ∧ ¬global_flush_late.fire`
		- `pu_valid_q`：见 `Data structure -> State` 第 3 条。
		- `global_flush_late.fire`：见 `Interface -> In-event` 第 1 条。
	- Constraint：不受 `winner_grant.fire`、`loser_hold` 或 completion 保持影响；每个已接收 BRU 只产生一拍 fire。
	- Payload：`alu_simple_predictor_update_payload`；当前拍有效。
		- `alu_simple_predictor_update_payload`：见 `Interface -> Out-event` 第 2 条。
	- State update：本拍上升沿按第 3 条覆盖 predictor 管线；无同拍 `issue_valid.fire` 或同拍 issue 非 BRU 时 `pu_valid_q <- 0`，同拍 issue 为 BRU 时装入新 payload 并保持 `PREDICTOR_VALID`。

## Data structure

### State

1. `completion_state`：由 `comp_q.result_valid` 编码；`0` 为 `COMPLETION_EMPTY`，`1` 为 `COMPLETION_PENDING`；由 `reset`、`global_flush_late`、`issue_valid` 和 `request_valid` 更新。
2. `comp_q.result_valid`：1 bit；completion 槽有效位；异步复位为 0。
3. `predictor_state`：由 `pu_valid_q` 编码；`0` 为 `PREDICTOR_IDLE`，`1` 为 `PREDICTOR_VALID`；由 `reset`、`global_flush_late`、`issue_valid` 和 `predictor_update_valid` 更新。
4. `pu_valid_q`：1 bit；predictor update 管线有效位；异步复位为 0。

### Header

无。

### Payload

1. `entry.payload.completion`：来源于 `alu_simple_issue_payload`。
	- `alu_simple_issue_payload`：见 `FSM -> Detailed Condition Description` 第 3 条。
2. `entry.payload.predictor_update`：来源于 `alu_simple_issue_payload`。
	- `alu_simple_issue_payload`：见 `FSM -> Detailed Condition Description` 第 3 条。

## Internal Connections

无。

## Interface

### In-event

1. `global_flush_late`：Notify，单 lane。
	- Fire来源：`global_flush_late.fire`
	- Payload：∅；当前拍 pulse。
2. `issue_valid`：Transaction，单 lane。
	- Fire来源：见 `FSM -> Detailed Condition Description` 第 3 条。
	- Payload：`alu_simple_issue_payload`；fire 所在上升沿采样。
	`alu_simple_issue_payload`：`rs1_data` 64 bit × 1、`rs2_data` 64 bit × 1、`FU_Group` `FU_GROUP_W` bit × 1、`imm_data` 64 bit × 1、`pc` 64 bit × 1、`inst_bits` 32 bit × 1、`is_compressed` 1 bit × 1、`pred_taken` 1 bit × 1、`pred_target_pc` 64 bit × 1、`self_tag` `TAG_W` bit × 1、`exe_subop` `EXE_SUBOP_W` bit × 1、`full_decode` `FULL_DECODE_W` bit × 1、`fetch_excp_vld` 1 bit × 1、`fetch_excp_cause` `FETCH_EXCP_CAUSE_W` bit × 1、`fetch_excp_tval` 64 bit × 1。
3. `winner_grant`：Notify，单 lane。
	- Fire来源：`winner_grant.fire`
	- Payload：∅；当前拍 pulse。

### In Static Info

1. `rst_n`：1 bit；低有效异步复位；由 `clk` 上升沿工作的状态寄存器读取。
2. `current_priv`：`PRIV_W` bit × 1；当前特权级，RTL 比较编码 `2'b00`、`2'b01`、`2'b11`；用于 ECALL cause、xRET、WFI 和 SFENCE.VMA 合法性判断。
3. `mstatus_tsr`：1 bit × 1；S 态执行 SRET 的禁止控制。
4. `mstatus_tw`：1 bit × 1；低于 M 态执行 WFI 的禁止控制。
5. `mstatus_tvm`：1 bit × 1；S 态执行 SFENCE.VMA 的禁止控制。
6. `loser_hold`：1 bit × 1；当前 completion 请求仲裁失败并需保持时为 1；用于 `FU_ready`。

### Out-event

1. `request_valid`：Transaction，单 lane。
	- Fire来源：见 `FSM -> Detailed Condition Description` 第 4 条。
	- Payload：`alu_simple_request_payload`；valid 期间持续有效，fire 所在上升沿采样。
	`alu_simple_request_payload`：`req_tag` `TAG_W` bit × 1、`req_result_data` 64 bit × 1、`req_mispredict_flag` 1 bit × 1、`req_mispredict_target_pc` 64 bit × 1、`req_exception_flag` 1 bit × 1、`req_exception_cause` `EXCP_CAUSE_W` bit × 1、`req_exception_tval` 64 bit × 1、`req_is_mret` 1 bit × 1、`req_is_sret` 1 bit × 1、`req_fpu_fflags` `FFLAGS_W` bit × 1、`req_is_csr` 1 bit × 1、`req_csr_write_enable` 1 bit × 1、`req_csr_addr` `CSR_ADDR_W` bit × 1、`req_csr_wdata` 64 bit × 1。
		- `req_tag = entry.payload.completion.tag_out`
			- `entry.payload.completion.tag_out`：见 `Data structure -> Payload` 第 1 条。
		- `req_result_data = entry.payload.completion.result_data`
			- `entry.payload.completion.result_data`：见 `Data structure -> Payload` 第 1 条。
		- `req_mispredict_flag = entry.payload.completion.mispredict_flag`
			- `entry.payload.completion.mispredict_flag`：见 `Data structure -> Payload` 第 1 条。
		- `req_mispredict_target_pc = entry.payload.completion.mispredict_target_pc`
			- `entry.payload.completion.mispredict_target_pc`：见 `Data structure -> Payload` 第 1 条。
		- `req_exception_flag = entry.payload.completion.exception_flag`
			- `entry.payload.completion.exception_flag`：见 `Data structure -> Payload` 第 1 条。
		- `req_exception_cause = entry.payload.completion.exception_cause`
			- `entry.payload.completion.exception_cause`：见 `Data structure -> Payload` 第 1 条。
		- `req_exception_tval = entry.payload.completion.exception_tval`
			- `entry.payload.completion.exception_tval`：见 `Data structure -> Payload` 第 1 条。
		- `req_is_mret = entry.payload.completion.is_mret`
			- `entry.payload.completion.is_mret`：见 `Data structure -> Payload` 第 1 条。
		- `req_is_sret = entry.payload.completion.is_sret`
			- `entry.payload.completion.is_sret`：见 `Data structure -> Payload` 第 1 条。
		- `req_fpu_fflags = entry.payload.completion.fpu_fflags`
			- `entry.payload.completion.fpu_fflags`：见 `Data structure -> Payload` 第 1 条。
		- `req_is_csr = 1'b0`。
		- `req_csr_write_enable = 1'b0`。
		- `req_csr_addr = 0`。
		- `req_csr_wdata = 0`。
2. `predictor_update_valid`：Notify，单 lane。
	- Fire来源：见 `FSM -> Detailed Condition Description` 第 5 条。
	- Payload：`alu_simple_predictor_update_payload`；当前拍 pulse。
	`alu_simple_predictor_update_payload`：`predictor_update_branch_pc` 64 bit × 1、`predictor_update_actual_taken` 1 bit × 1、`predictor_update_actual_target` 64 bit × 1、`predictor_update_cf_class` `cf_class_e` × 1。
		- `predictor_update_branch_pc = entry.payload.predictor_update.branch_pc`
			- `entry.payload.predictor_update.branch_pc`：见 `Data structure -> Payload` 第 2 条。
		- `predictor_update_actual_taken = entry.payload.predictor_update.actual_taken`
			- `entry.payload.predictor_update.actual_taken`：见 `Data structure -> Payload` 第 2 条。
		- `predictor_update_actual_target = entry.payload.predictor_update.actual_target`
			- `entry.payload.predictor_update.actual_target`：见 `Data structure -> Payload` 第 2 条。
		- `predictor_update_cf_class = entry.payload.predictor_update.cf_class`
			- `entry.payload.predictor_update.cf_class`：见 `Data structure -> Payload` 第 2 条。

### Out Static Info

1. `FU_ready`：1 bit × 1；当前拍组合有效。
	- `FU_ready = ¬loser_hold`
		- `loser_hold`：见 `Interface -> In Static Info` 第 6 条。

### Interface Timing

1. `clk`：所有非异步复位状态在上升沿采样或更新。
2. `rst_n`：低有效异步复位；为 0 时清除 `comp_q` 与 predictor update 管线的全部寄存器。
3. `Transaction`：`issue_valid` 的 valid 与 payload 由输入方保持至 `issue_valid.fire`；`request_valid.valid` 与全部 payload 由本模块保持至 `request_valid.fire`，`winner_grant.fire` 为该 Transaction 的 ready/accept 动作。
4. `Notify`：`global_flush_late.fire`、`winner_grant.fire` 和 `predictor_update_valid.fire` 均为当前拍 pulse；消费者在该拍上升沿采样。
5. `Static Info`：当前拍组合有效；`global_flush_late.fire=1` 时 `FU_ready` 仍仅由 `loser_hold` 决定，但 `issue_valid.fire` 被取消；复位不另行规定组合值。