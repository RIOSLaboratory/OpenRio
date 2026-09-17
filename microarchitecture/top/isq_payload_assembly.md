# Module `isq_payload_assembly`

`isq_payload_assembly`：`ISSUE_WIDTH=2`、`FP_READ_PORTS=3`、`INT_SRC_PER_SLOT=2` 的无状态组合 ISQ payload 装配模块；每拍产生两份完整的 `isq_payload_t`。

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

1. `head_IB_Payload[s]`：`ib_payload_t` × `ISSUE_WIDTH`，`s∈{0,...,ISSUE_WIDTH-1}`；提供当前拍 slot 的 PC、原始指令、预测信息和取指异常字段。
2. `dec_info[s]`：`decoded_info_t` × `ISSUE_WIDTH`；提供当前拍 slot 的译码字段。
3. `rsX_ready[s][x]`：1 bit × `ISSUE_WIDTH` × `FP_READ_PORTS`，`x∈{1,...,FP_READ_PORTS}`；对应 source 的 ready 状态。
4. `rsX_wait_tag[s][x]`：`TAG_W=4` bit × `ISSUE_WIDTH` × `FP_READ_PORTS`；对应 source 等待的 tag。
5. `rs_data_sel_t[s][x]`：`RS_DATA_SEL_W=7` bit × `ISSUE_WIDTH` × `FP_READ_PORTS`；操作数数据 onehot0 选择码；编码为 `{sel_arf, sel_commit[1:0], sel_bypass[3:0]}`。
6. `self_tag[s]`：`TAG_W` bit × `ISSUE_WIDTH`；当前 slot 的 self tag。
7. `INT_ARF[s][x]`：`XLEN=64` bit × `ISSUE_WIDTH` × `INT_SRC_PER_SLOT`，`x∈{1,...,INT_SRC_PER_SLOT}`；整数寄存器文件组合读数据。
8. `FP_ARF[x]`：`XLEN` bit × `FP_READ_PORTS`；浮点寄存器文件组合读数据，无 slot 维。
9. `commit_data[c]`：`XLEN` bit × `ISSUE_WIDTH`，`c∈{0,...,ISSUE_WIDTH-1}`；commit lane 组合读数据。
10. `bypass_data[b]`：`XLEN` bit × `NUM_LANES=4`，`b∈{0,...,NUM_LANES-1}`；bypass lane 组合数据。
11. `slot_FU_Group[s]`：`FU_GROUP_W=2` bit × `ISSUE_WIDTH`；当前 slot 的组内 FU 编码。
12. `effective_rm[s]`：`rm_e` 3 bit × `ISSUE_WIDTH`；当前 slot 已解析的有效浮点舍入模式。

### Out-event

无。

### Out Static Info

1. `slot_payload[s]`：`isq_payload_t`、`ISQ_PAYLOAD_W=556` bit × `ISSUE_WIDTH`；当前拍为每个 slot 组合装配的完整 ISQ payload。
	- `slot_payload[s] = {rs1_data:rsX_data[s][1], rs2_data:rsX_data[s][2], rs3_data:rsX_data[s][3], rs1_ready:rsX_ready[s][1], rs2_ready:rsX_ready[s][2], rs3_ready:rsX_ready[s][3], rs1_wait_tag:rsX_wait_tag[s][1], rs2_wait_tag:rsX_wait_tag[s][2], rs3_wait_tag:rsX_wait_tag[s][3], self_tag:self_tag[s], fu_group:slot_FU_Group[s], imm_valid:dec_info[s].imm_valid, imm_data:dec_info[s].imm_data, pc:head_IB_Payload[s].pc, inst_bits:head_IB_Payload[s].inst_bits, is_compressed:head_IB_Payload[s].is_compressed, pred_taken:head_IB_Payload[s].pred_taken, pred_target_pc:head_IB_Payload[s].pred_target_pc, is_store:dec_info[s].is_store, mem_funct3:dec_info[s].mem_funct3, rd_is_fp:dec_info[s].rd_is_fp, exe_subop:dec_info[s].exe_subop, full_decode:payload_full_decode[s], fetch_excp_vld:head_IB_Payload[s].fetch_excp_vld, fetch_excp_cause:head_IB_Payload[s].fetch_excp_cause, fetch_excp_tval:head_IB_Payload[s].fetch_excp_tval}`
		- `rsX_data[s][x]`：`XLEN` bit，`x∈{1,2,3}`；按 onehot0 选择码选出的 source 数据。
			- `rsX_data[s][x] = (sel_arf[s][x] ? arf_data[s][x] : '0) ∨ (∨(c∈{0,...,ISSUE_WIDTH-1}): sel_commit[s][x][c] ? commit_data[c] : '0) ∨ (∨(b∈{0,...,NUM_LANES-1}): sel_bypass[s][x][b] ? bypass_data[b] : '0)`
				- `sel_arf[s][x] = rs_data_sel_t[s][x][NUM_LANES+ISSUE_WIDTH]`
					- `rs_data_sel_t[s][x]`：见 `Interface -> In Static Info` 第 5 条。
				- `arf_data[s][x] = (x≤INT_SRC_PER_SLOT) ? (rs_is_fp[s][x] ? FP_ARF[x] : INT_ARF[s][x]) : FP_ARF[x]`
					- `rs_is_fp[s][x] = (x == 1) ? dec_info[s].rs1_is_fp : dec_info[s].rs2_is_fp`，`x∈{1,2}`。
						- `dec_info[s].rs1_is_fp`：见 `Interface -> In Static Info` 第 2 条。
						- `dec_info[s].rs2_is_fp`：见 `Interface -> In Static Info` 第 2 条。
					- `FP_ARF[x]`：见 `Interface -> In Static Info` 第 8 条。
					- `INT_ARF[s][x]`：见 `Interface -> In Static Info` 第 7 条；仅在 `x∈{1,2}` 时使用。
				- `sel_commit[s][x][c] = rs_data_sel_t[s][x][NUM_LANES+c]`
					- `rs_data_sel_t[s][x]`：见 `Interface -> In Static Info` 第 5 条。
				- `commit_data[c]`：见 `Interface -> In Static Info` 第 9 条。
				- `sel_bypass[s][x][b] = rs_data_sel_t[s][x][b]`
					- `rs_data_sel_t[s][x]`：见 `Interface -> In Static Info` 第 5 条。
				- `bypass_data[b]`：见 `Interface -> In Static Info` 第 10 条。
		- `rsX_ready[s][x]`：见 `Interface -> In Static Info` 第 3 条；`x∈{1,2,3}`。
		- `rsX_wait_tag[s][x]`：见 `Interface -> In Static Info` 第 4 条；`x∈{1,2,3}`。
		- `self_tag[s]`：见 `Interface -> In Static Info` 第 6 条。
		- `slot_FU_Group[s]`：见 `Interface -> In Static Info` 第 11 条。
		- `dec_info[s].imm_valid`：见 `Interface -> In Static Info` 第 2 条。
		- `dec_info[s].imm_data`：见 `Interface -> In Static Info` 第 2 条。
		- `head_IB_Payload[s].pc`：见 `Interface -> In Static Info` 第 1 条。
		- `head_IB_Payload[s].inst_bits`：见 `Interface -> In Static Info` 第 1 条。
		- `head_IB_Payload[s].is_compressed`：见 `Interface -> In Static Info` 第 1 条。
		- `head_IB_Payload[s].pred_taken`：见 `Interface -> In Static Info` 第 1 条。
		- `head_IB_Payload[s].pred_target_pc`：见 `Interface -> In Static Info` 第 1 条。
		- `dec_info[s].is_store`：见 `Interface -> In Static Info` 第 2 条。
		- `dec_info[s].mem_funct3`：见 `Interface -> In Static Info` 第 2 条。
		- `dec_info[s].rd_is_fp`：见 `Interface -> In Static Info` 第 2 条。
		- `dec_info[s].exe_subop`：见 `Interface -> In Static Info` 第 2 条。
		- `payload_full_decode[s]`：`full_decode_t`、`FULL_DECODE_W=17` bit；仅以 `effective_rm[s]` 覆写 `rm` 字段。
			- `payload_full_decode[s] = {csr_write_intent:dec_info[s].full_decode.csr_write_intent, illegal:dec_info[s].full_decode.illegal, rm:effective_rm[s], csr_addr:dec_info[s].full_decode.csr_addr}`
				- `dec_info[s].full_decode.csr_write_intent`：见 `Interface -> In Static Info` 第 2 条。
				- `dec_info[s].full_decode.illegal`：见 `Interface -> In Static Info` 第 2 条。
				- `dec_info[s].full_decode.csr_addr`：见 `Interface -> In Static Info` 第 2 条。
				- `effective_rm[s]`：见 `Interface -> In Static Info` 第 12 条。
		- `head_IB_Payload[s].fetch_excp_vld`：见 `Interface -> In Static Info` 第 1 条。
		- `head_IB_Payload[s].fetch_excp_cause`：见 `Interface -> In Static Info` 第 1 条。
		- `head_IB_Payload[s].fetch_excp_tval`：见 `Interface -> In Static Info` 第 1 条。

### Interface Timing

1. `clk`：无时钟端口；本模块无寄存更新。
2. `rst_n`：无复位端口；本模块无复位行为。
3. `Transaction`：无。
4. `Notify`：无。
5. `Static Info`：全部输入和 `slot_payload[s]` 当前拍组合有效；每个 slot 始终完整装配；`rs_data_sel_t[s][x]` 按 onehot0 使用，全零时 `rsX_data[s][x]=0`。
