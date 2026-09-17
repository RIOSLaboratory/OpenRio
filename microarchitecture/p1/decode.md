# Module `decode`

`decode`：`ISSUE_WIDTH`-lane、纯组合的指令全译码模块；`ISSUE_WIDTH` 为 lane 数量，`XLEN` 为立即数宽度，`REG_ADDR_W` 为寄存器索引宽度，`ENABLE_A`、`ENABLE_C`、`ENABLE_FD` 为扩展开关；接收 `ib_payload_t`，经 `rvc_expand` 生成规范指令，输出 `decoded_info_t`、FP opcode 判据及四个寄存器索引。

## Submodule

1. `rvc_expand`：`temp/new_v4.1/p1/rvc_expand.md`

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

1. `decode_payload[s].inst_bits -> rvc_expand.ib_inst_bits[s]`：32 bit；组合传递；当前拍有效。
2. `decode_payload[s].is_compressed -> rvc_expand.ib_is_compressed[s]`：1 bit；组合传递；当前拍有效。

## Interface

### In-event

无。

### In Static Info

1. `decode_payload[s]`：`ib_payload_t`，232 bit × `ISSUE_WIDTH`，`s∈{0,...,ISSUE_WIDTH-1}`；当前拍输入 payload；本模块读取 `inst_bits`、`is_compressed` 和 `fetch_excp_vld`。
	- `ib_payload_t`：`pc` 64 bit、`inst_bits` 32 bit、`is_compressed` 1 bit、`pred_taken` 1 bit、`pred_target_pc` 64 bit、`fetch_excp_vld` 1 bit、`fetch_excp_cause` 5 bit、`fetch_excp_tval` 64 bit。

### Out-event

无。

### Out Static Info

1. `dec_info[s]`：`decoded_info_t`，120 bit × `ISSUE_WIDTH`，`s∈{0,...,ISSUE_WIDTH-1}`；当前拍合法性门控后的译码结果。
	- `dec_info[s] = '0`；`dec_info[s].full_decode.illegal = d_no_encoding[s]`；当 `¬d_no_encoding[s]` 时，`dec_info[s].is_serial = d_is_serial[s]`，`dec_info[s].is_fp_instruction = d_is_fp_instruction[s]`，`dec_info[s].use_rs1 = d_use_rs1[s]`，`dec_info[s].use_rs2 = d_use_rs2[s]`，`dec_info[s].use_rs3 = d_use_rs3[s]`，`dec_info[s].rs1_is_fp = d_rs1_is_fp[s]`，`dec_info[s].rs2_is_fp = d_rs2_is_fp[s]`，`dec_info[s].rs3_is_fp = 1'b1`，`dec_info[s].use_rd = d_has_rd[s] ∧ ¬((f_rd[s] = 0) ∧ ¬d_rd_is_fp[s])`，`dec_info[s].rd_is_fp = d_rd_is_fp[s]`，`dec_info[s].is_store = d_is_store[s]`，`dec_info[s].mem_funct3 = funct3[s]`，`dec_info[s].imm_valid = d_imm_valid[s]`，`dec_info[s].imm_data = d_imm_valid[s] ? d_imm_data[s] : '0`，`dec_info[s].exe_subop = subop_raw[s]`，`dec_info[s].full_decode.csr_write_intent = d_csr_write_intent[s]`，`dec_info[s].full_decode.rm = d_rm[s]`，`dec_info[s].full_decode.csr_addr = is_csr_form[s] ? funct12[s] : 12'h000`。
		- `d_is_serial[s] = is_g0_csr_subop(subop_raw[s]) ∨ (subop_raw[s] = SUBOP_MRET) ∨ (subop_raw[s] = SUBOP_SRET) ∨ (subop_raw[s] = SUBOP_SFENCE_VMA) ∨ is_g3_fence_subop(subop_raw[s]) ∨ is_g3_atomic_subop(subop_raw[s])`。
			- `subop_raw[s] = decode_payload[s].is_compressed ? {SUBOP_FMT_RVC,5'b0,inst16[s][1:0],inst16[s][15:13],rvc_alias_tag(inst16[s])} : {SUBOP_FMT_INST32,opcode[s],subop_funct3[s],high_fixed[s]}`。
				- `decode_payload[s].is_compressed`：见 `Interface -> In Static Info` 第 1 条。
				- `inst16[s] = decode_payload[s].inst_bits[15:0]`
					- `decode_payload[s].inst_bits`：见 `Interface -> In Static Info` 第 1 条。
				- `opcode[s] = rvc_expand.inst32[s][6:0]`。
					- `rvc_expand.inst32[s]`：见子模块公开 `Interface -> Out Static Info` 第 1 条。
				- `subop_funct3[s] = case(opcode[s])`：`OPCODE_LUI/OPCODE_AUIPC/OPCODE_JAL` 为 `F3_000`；`OPCODE_MADD/OPCODE_MSUB/OPCODE_NMSUB/OPCODE_NMADD` 为 `F3_RMVAR`；`OPCODE_OP_FP` 为 `opfp_rm_variable(funct7[s]) ? F3_RMVAR : funct3[s]`；其他情况为 `funct3[s]`。
					- `opcode[s]`：见本条 `subop_raw[s]`。
					- `funct3[s] = rvc_expand.inst32[s][14:12]`
						- `rvc_expand.inst32[s]`：见子模块公开 `Interface -> Out Static Info` 第 1 条。
					- `funct7[s] = rvc_expand.inst32[s][31:25]`
						- `rvc_expand.inst32[s]`：见子模块公开 `Interface -> Out Static Info` 第 1 条。
					- `opfp_rm_variable(f7) = f7 inside {7'b0000000,7'b0000001,7'b0000100,7'b0000101,7'b0001000,7'b0001001,7'b0001100,7'b0001101,7'b0101100,7'b0101101,7'b0100000,7'b0100001,7'b1100000,7'b1100001,7'b1101000,7'b1101001}`。
				- `high_fixed[s] = case(opcode[s])`：`OPCODE_OP/OPCODE_OP32` 为 `{funct7[s],5'b0}`；`OPCODE_OP_IMM` 的移位形式为 `{rvc_expand.inst32[s][31:26],6'b0}`、非移位形式为 0；`OPCODE_OP_IMM32` 的移位形式为 `{funct7[s],5'b0}`、非移位形式为 0；`OPCODE_AMO` 为 `{funct5[s],7'b0}`；`OPCODE_SYSTEM` 为 `(funct3[s] != F3_000) ? 0 : (funct7[s] = 7'b0001001) ? {funct7[s],5'b0} : funct12[s]`；`OPCODE_OP_FP` 为 `opfp_unary(funct7[s]) ? {funct7[s],f_rs2[s]} : {funct7[s],5'b0}`；`OPCODE_MADD/OPCODE_MSUB/OPCODE_NMSUB/OPCODE_NMADD` 为 `{5'b0,rvc_expand.inst32[s][26:25],5'b0}`；其他 opcode 为 0。
					- `opcode[s]`：见本条 `subop_raw[s]`。
					- `funct3[s]`：见本条 `subop_funct3[s]`；两种 OP-IMM 的移位形式均为 `funct3[s] inside {F3_001,F3_101}`。
					- `funct7[s]`：见本条 `subop_funct3[s]`。
					- `funct5[s] = rvc_expand.inst32[s][31:27]`
						- `rvc_expand.inst32[s]`：见子模块公开 `Interface -> Out Static Info` 第 1 条。
					- `funct12[s] = rvc_expand.inst32[s][31:20]`
						- `rvc_expand.inst32[s]`：见子模块公开 `Interface -> Out Static Info` 第 1 条。
					- `f_rs2[s] = rvc_expand.inst32[s][24:20]`
						- `rvc_expand.inst32[s]`：见子模块公开 `Interface -> Out Static Info` 第 1 条。
					- `rvc_expand.inst32[s]`：见子模块公开 `Interface -> Out Static Info` 第 1 条。
					- `opfp_unary(f7) = f7 inside {7'b0100000,7'b0100001,7'b0101100,7'b0101101,7'b1100000,7'b1100001,7'b1101000,7'b1101001,7'b1110000,7'b1110001,7'b1111000,7'b1111001}`。
				- `rvc_alias_tag(c) = case(c[1:0])`：`2'b00` 时，`c[15:13]=3'b100` 返回 `12'hFFF`，否则返回 0；`2'b01` 时，`c[15:13]=3'b000` 按 `c[11:7]=0` 返回 `0/1`，`c[15:13]=3'b011` 对 `(c[12]=0) ∧ (c[6:2]=0) ∧ (c[7]=1)` 返回 `12'hFFF`、否则按 `c[11:7]=2` 返回 `0/1`，`c[15:13]=3'b100` 按 `c[11:10]` 的 `00/01/10` 返回 `0/1/2`、其余按 `{c[12],c[6:5]}` 的 `000/001/010/011/100/101` 返回 `3/4/5/6/7/8`、其他返回 `12'hFFF`，其余 `c[15:13]` 返回 0；`2'b10 ∧ c[15:13]=3'b100` 时，`c[12]=0` 按 `c[6:2]=0` 返回 `0/1`，`c[12]=1 ∧ c[6:2]=0` 时按 `c[11:7]=0` 返回 `2/3`，其余返回 4；`2'b10` 的其他情况返回 0；`2'b11` 返回 `12'hFFF`。
					- `c = inst16[s]`：见本条 `subop_raw[s]`。
		- `d_is_fp_instruction[s] = is_g2_fpu_subop(subop_raw[s]) ∨ is_g3_fp_load_subop(subop_raw[s]) ∨ is_g3_fp_store_subop(subop_raw[s])`。
			- `subop_raw[s]`：见本条 `d_is_serial[s]`。
		- `d_use_rs1[s] = (opcode[s] inside {OPCODE_LOAD,OPCODE_LOAD_FP,OPCODE_OP_IMM,OPCODE_OP_IMM32,OPCODE_JALR,OPCODE_STORE,OPCODE_STORE_FP,OPCODE_BRANCH,OPCODE_AMO,OPCODE_OP,OPCODE_OP32,OPCODE_MADD,OPCODE_MSUB,OPCODE_NMSUB,OPCODE_NMADD,OPCODE_OP_FP}) ∨ (is_csr_form[s] ∧ (funct3[s] inside {F3_001,F3_010,F3_011}))`
			- `opcode[s]`：见本条 `d_is_serial[s]`。
			- `is_csr_form[s] = (opcode[s] = OPCODE_SYSTEM) ∧ (funct3[s] != F3_000) ∧ (funct3[s] != F3_100)`
				- `opcode[s]`：见本条 `d_is_serial[s]`。
				- `funct3[s]`：见本条 `d_is_serial[s]`。
			- `funct3[s]`：见本条 `d_is_serial[s]`。
		- `d_use_rs2[s] = (opcode[s] inside {OPCODE_STORE,OPCODE_STORE_FP,OPCODE_BRANCH,OPCODE_OP,OPCODE_OP32,OPCODE_MADD,OPCODE_MSUB,OPCODE_NMSUB,OPCODE_NMADD}) ∨ ((opcode[s] = OPCODE_AMO) ∧ ¬is_g3_lr_subop(subop_raw[s])) ∨ ((opcode[s] = OPCODE_OP_FP) ∧ ¬opfp_unary(funct7[s]))`
			- `opcode[s]`：见本条 `d_is_serial[s]`。
			- `subop_raw[s]`：见本条 `d_is_serial[s]`。
			- `funct7[s]`：见本条 `d_is_serial[s]`。
			- `opfp_unary`：见本条 `d_is_serial[s]`。
		- `d_use_rs3[s] = opcode[s] inside {OPCODE_MADD,OPCODE_MSUB,OPCODE_NMSUB,OPCODE_NMADD}`
			- `opcode[s]`：见本条 `d_is_serial[s]`。
		- `d_rs1_is_fp[s] = (opcode[s] inside {OPCODE_MADD,OPCODE_MSUB,OPCODE_NMSUB,OPCODE_NMADD}) ∨ ((opcode[s] = OPCODE_OP_FP) ∧ ¬opfp_rs1_is_int(funct7[s]))`
			- `opcode[s]`：见本条 `d_is_serial[s]`。
			- `funct7[s]`：见本条 `d_is_serial[s]`。
			- `opfp_rs1_is_int(f7) = f7 inside {7'b1101000,7'b1101001,7'b1111000,7'b1111001}`
		- `d_rs2_is_fp[s] = (opcode[s] = OPCODE_STORE_FP) ∨ (opcode[s] inside {OPCODE_MADD,OPCODE_MSUB,OPCODE_NMSUB,OPCODE_NMADD}) ∨ ((opcode[s] = OPCODE_OP_FP) ∧ ¬opfp_unary(funct7[s]))`
			- `opcode[s]`：见本条 `d_is_serial[s]`。
			- `funct7[s]`：见本条 `d_is_serial[s]`。
			- `opfp_unary`：见本条 `d_is_serial[s]`。
		- `d_rd_is_fp[s] = (opcode[s] = OPCODE_LOAD_FP) ∨ (opcode[s] inside {OPCODE_MADD,OPCODE_MSUB,OPCODE_NMSUB,OPCODE_NMADD}) ∨ ((opcode[s] = OPCODE_OP_FP) ∧ ¬opfp_rd_is_int(funct7[s]))`
			- `opcode[s]`：见本条 `d_is_serial[s]`。
			- `funct7[s]`：见本条 `d_is_serial[s]`。
			- `opfp_rd_is_int(f7) = f7 inside {7'b1100000,7'b1100001,7'b1110000,7'b1110001,7'b1010000,7'b1010001}`
		- `d_has_rd[s] = (opcode[s] inside {OPCODE_LOAD,OPCODE_LOAD_FP,OPCODE_OP_IMM,OPCODE_OP_IMM32,OPCODE_AUIPC,OPCODE_LUI,OPCODE_JAL,OPCODE_JALR,OPCODE_AMO,OPCODE_OP,OPCODE_OP32,OPCODE_MADD,OPCODE_MSUB,OPCODE_NMSUB,OPCODE_NMADD,OPCODE_OP_FP}) ∨ is_csr_form[s]`
			- `opcode[s]`：见本条 `d_is_serial[s]`。
			- `is_csr_form[s]`：见本条 `d_use_rs1[s]`。
		- `f_rd[s] = rvc_expand.inst32[s][11:7]`
			- `rvc_expand.inst32[s]`：见子模块公开 `Interface -> Out Static Info` 第 1 条。
		- `d_is_store[s] = is_g3_store_subop(subop_raw[s])`
			- `subop_raw[s]`：见本条 `d_is_serial[s]`。
		- `funct3[s]`：见本条 `d_is_serial[s]`。
		- `d_imm_valid[s] = (opcode[s] inside {OPCODE_LOAD,OPCODE_LOAD_FP,OPCODE_OP_IMM,OPCODE_OP_IMM32,OPCODE_AUIPC,OPCODE_LUI,OPCODE_JAL,OPCODE_JALR,OPCODE_STORE,OPCODE_STORE_FP,OPCODE_BRANCH}) ∨ (is_csr_form[s] ∧ ¬(funct3[s] inside {F3_001,F3_010,F3_011}))`
			- `opcode[s]`：见本条 `d_is_serial[s]`。
			- `is_csr_form[s]`：见本条 `d_use_rs1[s]`。
			- `funct3[s]`：见本条 `d_is_serial[s]`。
		- `d_imm_data[s] = case(opcode[s])`：`OPCODE_LOAD/OPCODE_LOAD_FP/OPCODE_JALR` 为 `imm_i[s]`；`OPCODE_OP_IMM/OPCODE_OP_IMM32` 的移位形式为 `imm_shamt[s]`、非移位形式为 `imm_i[s]`；`OPCODE_AUIPC/OPCODE_LUI` 为 `imm_u[s]`；`OPCODE_JAL` 为 `imm_j[s]`；`OPCODE_STORE/OPCODE_STORE_FP` 为 `imm_s[s]`；`OPCODE_BRANCH` 为 `imm_b[s]`；CSR immediate form 为 `imm_csr_uimm[s]`；其他情况为 0。
			- `opcode[s]`：见本条 `d_is_serial[s]`。
			- `funct3[s]`：见本条 `d_is_serial[s]`；移位形式为 `funct3[s] inside {F3_001,F3_101}`。
			- `is_csr_form[s]`：见本条 `d_use_rs1[s]`；CSR immediate form 为 `is_csr_form[s] ∧ ¬(funct3[s] inside {F3_001,F3_010,F3_011})`。
			- `imm_i[s] = {{52{rvc_expand.inst32[s][31]}},rvc_expand.inst32[s][31:20]}`
				- `rvc_expand.inst32[s]`：见子模块公开 `Interface -> Out Static Info` 第 1 条。
			- `imm_s[s] = {{52{rvc_expand.inst32[s][31]}},rvc_expand.inst32[s][31:25],rvc_expand.inst32[s][11:7]}`
				- `rvc_expand.inst32[s]`：见子模块公开 `Interface -> Out Static Info` 第 1 条。
			- `imm_b[s] = {{51{rvc_expand.inst32[s][31]}},rvc_expand.inst32[s][31],rvc_expand.inst32[s][7],rvc_expand.inst32[s][30:25],rvc_expand.inst32[s][11:8],1'b0}`
				- `rvc_expand.inst32[s]`：见子模块公开 `Interface -> Out Static Info` 第 1 条。
			- `imm_u[s] = {{32{rvc_expand.inst32[s][31]}},rvc_expand.inst32[s][31:12],12'b0}`
				- `rvc_expand.inst32[s]`：见子模块公开 `Interface -> Out Static Info` 第 1 条。
			- `imm_j[s] = {{43{rvc_expand.inst32[s][31]}},rvc_expand.inst32[s][31],rvc_expand.inst32[s][19:12],rvc_expand.inst32[s][20],rvc_expand.inst32[s][30:21],1'b0}`
				- `rvc_expand.inst32[s]`：见子模块公开 `Interface -> Out Static Info` 第 1 条。
			- `imm_shamt[s] = {{(XLEN-6){1'b0}},rvc_expand.inst32[s][25:20]}`
				- `XLEN`：见本模块基本 property。
				- `rvc_expand.inst32[s]`：见子模块公开 `Interface -> Out Static Info` 第 1 条。
			- `imm_csr_uimm[s] = {{(XLEN-5){1'b0}},rvc_expand.inst32[s][19:15]}`
				- `XLEN`：见本模块基本 property。
				- `rvc_expand.inst32[s]`：见子模块公开 `Interface -> Out Static Info` 第 1 条。
		- `subop_raw[s]`：见本条 `d_is_serial[s]`。
		- `d_csr_write_intent[s] = is_csr_form[s] ∧ ((funct3[s] inside {F3_001,F3_101}) ∨ (f_rs1[s] != 0))`
			- `is_csr_form[s]`：见本条 `d_use_rs1[s]`。
			- `funct3[s]`：见本条 `d_is_serial[s]`。
			- `f_rs1[s] = rvc_expand.inst32[s][19:15]`
				- `rvc_expand.inst32[s]`：见子模块公开 `Interface -> Out Static Info` 第 1 条。
		- `d_rm[s] = d_uses_rm[s] ? rm_e'(funct3[s]) : RM_RNE`
			- `d_uses_rm[s] = subop_raw[s] inside {SUBOP_FADD_S,SUBOP_FSUB_S,SUBOP_FMUL_S,SUBOP_FDIV_S,SUBOP_FSQRT_S,SUBOP_FADD_D,SUBOP_FSUB_D,SUBOP_FMUL_D,SUBOP_FDIV_D,SUBOP_FSQRT_D,SUBOP_FMADD_S,SUBOP_FMSUB_S,SUBOP_FNMSUB_S,SUBOP_FNMADD_S,SUBOP_FMADD_D,SUBOP_FMSUB_D,SUBOP_FNMSUB_D,SUBOP_FNMADD_D,SUBOP_FCVT_W_S,SUBOP_FCVT_WU_S,SUBOP_FCVT_L_S,SUBOP_FCVT_LU_S,SUBOP_FCVT_W_D,SUBOP_FCVT_WU_D,SUBOP_FCVT_L_D,SUBOP_FCVT_LU_D,SUBOP_FCVT_S_W,SUBOP_FCVT_S_WU,SUBOP_FCVT_S_L,SUBOP_FCVT_S_LU,SUBOP_FCVT_D_W,SUBOP_FCVT_D_WU,SUBOP_FCVT_D_L,SUBOP_FCVT_D_LU,SUBOP_FCVT_S_D,SUBOP_FCVT_D_S}`
				- `subop_raw[s]`：见本条 `d_is_serial[s]`。
			- `funct3[s]`：见本条 `d_is_serial[s]`。
		- `is_csr_form[s]`：见本条 `d_use_rs1[s]`。
		- `funct12[s]`：见本条 `d_is_serial[s]`。
		- `d_no_encoding[s] = d_illegal[s] ∨ decode_payload[s].fetch_excp_vld`
			- `d_illegal[s] = ill_rvc[s] ∨ ill_ext_a[s] ∨ ill_ext_c[s] ∨ ill_ext_fd[s] ∨ ill_unsupported[s] ∨ ill_rm[s]`
				- `ill_rvc[s] = rvc_expand.rvc_illegal[s]`
					- `rvc_expand.rvc_illegal[s]`：见子模块公开 `Interface -> Out Static Info` 第 2 条。
				- `ill_ext_a[s] = ¬ENABLE_A ∧ (opcode[s] = OPCODE_AMO)`
					- `ENABLE_A`：见本模块基本 property。
					- `opcode[s]`：见本条 `d_is_serial[s]`。
				- `ill_ext_c[s] = ¬ENABLE_C ∧ decode_payload[s].is_compressed`
					- `ENABLE_C`：见本模块基本 property。
					- `decode_payload[s].is_compressed`：见 `Interface -> In Static Info` 第 1 条。
				- `ill_ext_fd[s] = ¬ENABLE_FD ∧ is_fp_opcode[s]`
					- `ENABLE_FD`：见本模块基本 property。
					- `is_fp_opcode[s] = opcode[s] inside {OPCODE_OP_FP,OPCODE_MADD,OPCODE_MSUB,OPCODE_NMSUB,OPCODE_NMADD,OPCODE_LOAD_FP,OPCODE_STORE_FP}`
						- `opcode[s]`：见本条 `d_is_serial[s]`。
				- `ill_unsupported[s] = ¬subop_supported(subop_raw[s])`
					- `subop_supported(x) = is_g0_alu0_subop(x) ∨ is_g1_alu1_subop(x) ∨ is_g0_bru_subop(x) ∨ is_g0_div_subop(x) ∨ is_g0_csr_subop(x) ∨ is_g0_sys_subop(x) ∨ is_g1_mul_subop(x) ∨ is_g2_fpu_subop(x) ∨ is_g3_subop(x)`
					- `subop_raw[s]`：见本条 `d_is_serial[s]`。
				- `ill_rm[s] = d_uses_rm[s] ∧ rm_is_reserved(rm_e'(funct3[s]))`
					- `d_uses_rm[s]`：见本条 `d_rm[s]`。
					- `funct3[s]`：见本条 `d_is_serial[s]`。
					- `rm_is_reserved(rm) = (rm = RM_RSV5) ∨ (rm = RM_RSV6)`
			- `decode_payload[s].fetch_excp_vld`：见 `Interface -> In Static Info` 第 1 条。
2. `dec_is_fp_opcode[s]`：1 bit × `ISSUE_WIDTH`，`s∈{0,...,ISSUE_WIDTH-1}`；当前拍由规范指令 opcode 直接产生，不受非法或 fetch exception 门控。
	- `dec_is_fp_opcode[s] = opcode[s] inside {OPCODE_OP_FP, OPCODE_MADD, OPCODE_MSUB, OPCODE_NMSUB, OPCODE_NMADD, OPCODE_LOAD_FP, OPCODE_STORE_FP}`。
		- `opcode[s]`：见本节第 1 条 `d_is_serial[s]`。
3. `rs1_idx[s]`：`REG_ADDR_W` bit × `ISSUE_WIDTH`，`s∈{0,...,ISSUE_WIDTH-1}`；当前拍 `rs1` 寄存器索引。
	- `rs1_idx[s] = rvc_expand.inst32[s][19:15]`。
		- `rvc_expand.inst32[s]`：见子模块公开 `Interface -> Out Static Info` 第 1 条。
4. `rs2_idx[s]`：`REG_ADDR_W` bit × `ISSUE_WIDTH`，`s∈{0,...,ISSUE_WIDTH-1}`；当前拍 `rs2` 寄存器索引。
	- `rs2_idx[s] = rvc_expand.inst32[s][24:20]`。
		- `rvc_expand.inst32[s]`：见子模块公开 `Interface -> Out Static Info` 第 1 条。
5. `rs3_idx[s]`：`REG_ADDR_W` bit × `ISSUE_WIDTH`，`s∈{0,...,ISSUE_WIDTH-1}`；当前拍 `rs3` 寄存器索引。
	- `rs3_idx[s] = rvc_expand.inst32[s][31:27]`。
		- `rvc_expand.inst32[s]`：见子模块公开 `Interface -> Out Static Info` 第 1 条。
6. `rd_idx[s]`：`REG_ADDR_W` bit × `ISSUE_WIDTH`，`s∈{0,...,ISSUE_WIDTH-1}`；当前拍 destination 寄存器索引。
	- `rd_idx[s] = rvc_expand.inst32[s][11:7]`。
		- `rvc_expand.inst32[s]`：见子模块公开 `Interface -> Out Static Info` 第 1 条。

### Interface Timing

1. `clk`：无时钟。
2. `rst_n`：无复位。
3. `Transaction`：无。
4. `Notify`：无。
5. `Static Info`：每个 lane 独立组合计算；输入与输出均在当前拍组合有效；`dec_info` 的译码决策受 `d_no_encoding` 门控，`dec_is_fp_opcode` 和四个寄存器索引不受该门控；无握手、背压、保持或取消规则。
