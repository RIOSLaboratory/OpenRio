# Module `fpu_simple`

`fpu_simple`：单 lane 的 RV64FD 浮点执行单元；组合计算 SP/DP 算术、比较、转换、分类和搬移结果，在接收 issue 的上升沿寄存 completion，并于下一拍同时发布 writeback 与 bypass。

## Submodule

无。

## FSM

### State

1. `IDLE`：可接收一个 issue，无有效 completion。
2. `COMPLETION_VALID`：保存一个有效 completion，并在当前拍发布 writeback 与 bypass。

### State Transition & Condition Name

1. `ANY -> IDLE`：`reset`
2. `ANY -> IDLE`：`global_flush_late`
3. `IDLE -> COMPLETION_VALID`：`issue_valid`
4. `COMPLETION_VALID -> IDLE`：`writeback_valid`、`bypass_publish_valid`

### Detailed Condition Description

1. `reset`：异步清除有效状态和 completion payload。
	- Fire来源：`reset.fire = ¬rst_n`
		- `rst_n`：见 `Interface -> In Static Info` 第 1 条。
	- Constraint：低有效异步复位。
	- Payload：∅。
	- State update：`busy_q <- 0`；`entry.payload.completion <- 0`。
2. `global_flush_late`：在本拍上升沿取消状态和 completion payload。
	- Fire来源：`global_flush_late.fire`
		- `global_flush_late.fire`：见 `Interface -> In-event` 第 1 条。
	- Constraint：优先于 `issue_valid` 的状态更新；`issue_valid.fire=0`；不组合取消已经置位的 `writeback_valid.fire` 或 `bypass_publish_valid.fire`，三者允许同拍为 1。
	- Payload：∅。
	- State update：本拍上升沿 `busy_q <- 0`；`entry.payload.completion <- 0`。
3. `issue_valid`：接收一个浮点 issue，组合计算结果并寄存完整 completion。
	- Fire来源：`issue_valid.fire = issue_valid.valid ∧ FU_ready ∧ ¬global_flush_late.fire`
		- `issue_valid.valid`：输入 issue 请求有效；见 `Interface -> In-event` 第 2 条。
		- `FU_ready`：见 `Interface -> Out Static Info` 第 1 条。
		- `global_flush_late.fire`：见 `Interface -> In-event` 第 1 条。
	- Constraint：`issue_valid` 为 valid/ready Transaction；`COMPLETION_VALID` 拍不接收新 issue。
	- Payload：`fpu_simple_issue_payload`；fire 所在上升沿采样。
		- `fpu_simple_issue_payload`：`rs1_data[XLEN-1:0]`、`rs2_data[XLEN-1:0]`、`rs3_data[XLEN-1:0]`、`self_tag[TAG_W-1:0]`、`exe_subop[EXE_SUBOP_W-1:0]`、`full_decode[FULL_DECODE_W-1:0]`；`XLEN=64`，`TAG_W`、`EXE_SUBOP_W`、`FULL_DECODE_W` 由 `or_be_types_pkg` 定义。
	- State update：本拍上升沿 `busy_q <- 1`；`entry.payload.completion.result_valid <- 1`；`entry.payload.completion.tag_out <- self_tag`；`entry.payload.completion.result_data <- fpu_result`；`entry.payload.completion.mispredict_flag <- 0`；`entry.payload.completion.mispredict_target_pc <- 0`；`entry.payload.completion.exception_flag <- 0`；`entry.payload.completion.exception_cause <- 0`；`entry.payload.completion.exception_tval <- 0`；`entry.payload.completion.is_mret <- 0`；`entry.payload.completion.is_sret <- 0`；`entry.payload.completion.fpu_fflags <- fpu_fflags_c`。
		- `self_tag`：见本条 payload。
		- `{fpu_result,fpu_fflags_c} = fpu_execute(exe_subop, full_decode[14:12], rs1_data, rs2_data, rs3_data)`
			- `fpu_execute`：按以下组合规则产生 64 bit 结果和 5 bit flags；`fpu_fflags_c[4:0]={NV,DZ,OF,UF,NX}`，初值为 0；SP 结果初始高 32 bit 为 `32'hffffffff`。
				- `fpu_op`：6 bit enum，按 `FPU_NONE/FPU_FADD/FPU_FSUB/FPU_FMUL/FPU_FDIV/FPU_FSQRT/FPU_FSGNJ/FPU_FSGNJN/FPU_FSGNJX/FPU_FMIN/FPU_FMAX/FPU_FEQ/FPU_FLT/FPU_FLE/FPU_FCLASS/FPU_FMADD/FPU_FMSUB/FPU_FNMSUB/FPU_FNMADD/FPU_FCVT_W_S/FPU_FCVT_WU_S/FPU_FCVT_L_S/FPU_FCVT_LU_S/FPU_FCVT_W_D/FPU_FCVT_WU_D/FPU_FCVT_L_D/FPU_FCVT_LU_D/FPU_FCVT_S_W/FPU_FCVT_S_WU/FPU_FCVT_S_L/FPU_FCVT_S_LU/FPU_FCVT_D_W/FPU_FCVT_D_WU/FPU_FCVT_D_L/FPU_FCVT_D_LU/FPU_FCVT_S_D/FPU_FCVT_D_S/FPU_FMV_X_W/FPU_FMV_W_X/FPU_FMV_X_D/FPU_FMV_D_X` 顺序从 0 递增编码；`fpu_fmt` 为 2 bit，`fmt_dp=(fpu_fmt=1)`。
				- 基本算术解码：`SUBOP_FADD_S -> FPU_FADD,0`、`SUBOP_FSUB_S -> FPU_FSUB,0`、`SUBOP_FMUL_S -> FPU_FMUL,0`、`SUBOP_FDIV_S -> FPU_FDIV,0`、`SUBOP_FSQRT_S -> FPU_FSQRT,0`、`SUBOP_FADD_D -> FPU_FADD,1`、`SUBOP_FSUB_D -> FPU_FSUB,1`、`SUBOP_FMUL_D -> FPU_FMUL,1`、`SUBOP_FDIV_D -> FPU_FDIV,1`、`SUBOP_FSQRT_D -> FPU_FSQRT,1`；映射值依次为 `fpu_op,fpu_fmt`。
				- sign/min/max 解码：`SUBOP_FSGNJ_S -> FPU_FSGNJ,0`、`SUBOP_FSGNJN_S -> FPU_FSGNJN,0`、`SUBOP_FSGNJX_S -> FPU_FSGNJX,0`、`SUBOP_FMIN_S -> FPU_FMIN,0`、`SUBOP_FMAX_S -> FPU_FMAX,0`、`SUBOP_FSGNJ_D -> FPU_FSGNJ,1`、`SUBOP_FSGNJN_D -> FPU_FSGNJN,1`、`SUBOP_FSGNJX_D -> FPU_FSGNJX,1`、`SUBOP_FMIN_D -> FPU_FMIN,1`、`SUBOP_FMAX_D -> FPU_FMAX,1`。
				- 比较/分类解码：`SUBOP_FEQ_S -> FPU_FEQ,0`、`SUBOP_FLT_S -> FPU_FLT,0`、`SUBOP_FLE_S -> FPU_FLE,0`、`SUBOP_FCLASS_S -> FPU_FCLASS,0`、`SUBOP_FEQ_D -> FPU_FEQ,1`、`SUBOP_FLT_D -> FPU_FLT,1`、`SUBOP_FLE_D -> FPU_FLE,1`、`SUBOP_FCLASS_D -> FPU_FCLASS,1`。
				- FMA 解码：`SUBOP_FMADD_S -> FPU_FMADD,0`、`SUBOP_FMSUB_S -> FPU_FMSUB,0`、`SUBOP_FNMSUB_S -> FPU_FNMSUB,0`、`SUBOP_FNMADD_S -> FPU_FNMADD,0`、`SUBOP_FMADD_D -> FPU_FMADD,1`、`SUBOP_FMSUB_D -> FPU_FMSUB,1`、`SUBOP_FNMSUB_D -> FPU_FNMSUB,1`、`SUBOP_FNMADD_D -> FPU_FNMADD,1`。
				- FP-to-INT 解码：`SUBOP_FCVT_W_S -> FPU_FCVT_W_S,0`、`SUBOP_FCVT_WU_S -> FPU_FCVT_WU_S,0`、`SUBOP_FCVT_L_S -> FPU_FCVT_L_S,0`、`SUBOP_FCVT_LU_S -> FPU_FCVT_LU_S,0`、`SUBOP_FCVT_W_D -> FPU_FCVT_W_D,1`、`SUBOP_FCVT_WU_D -> FPU_FCVT_WU_D,1`、`SUBOP_FCVT_L_D -> FPU_FCVT_L_D,1`、`SUBOP_FCVT_LU_D -> FPU_FCVT_LU_D,1`。
				- INT-to-FP 解码：`SUBOP_FCVT_S_W -> FPU_FCVT_S_W,0`、`SUBOP_FCVT_S_WU -> FPU_FCVT_S_WU,0`、`SUBOP_FCVT_S_L -> FPU_FCVT_S_L,0`、`SUBOP_FCVT_S_LU -> FPU_FCVT_S_LU,0`、`SUBOP_FCVT_D_W -> FPU_FCVT_D_W,1`、`SUBOP_FCVT_D_WU -> FPU_FCVT_D_WU,1`、`SUBOP_FCVT_D_L -> FPU_FCVT_D_L,1`、`SUBOP_FCVT_D_LU -> FPU_FCVT_D_LU,1`。
				- 格式转换解码：`SUBOP_FCVT_S_D -> FPU_FCVT_S_D,1`、`SUBOP_FCVT_D_S -> FPU_FCVT_D_S,0`。
				- 搬移解码：`SUBOP_FMV_X_W -> FPU_FMV_X_W,0`、`SUBOP_FMV_W_X -> FPU_FMV_W_X,0`、`SUBOP_FMV_X_D -> FPU_FMV_X_D,1`、`SUBOP_FMV_D_X -> FPU_FMV_D_X,1`；其余 `exe_subop` 解码为 `FPU_NONE,0`。
				- 舍入模式：`fpu_eff_rm = full_decode[14:12]`；`FRM_RNE=3'b000`、`FRM_RTZ=3'b001`、`FRM_RDN=3'b010`、`FRM_RUP=3'b011`、`FRM_RMM=3'b100`。
				- SP 输入：对 `x∈{a,b,c}`，`raw_x` 分别为 `rs1_data/rs2_data/rs3_data`；`sp_x = raw_x[63:32]=32'hffffffff ? raw_x[31:0] : SP_QNAN`，`SP_QNAN=32'h7fc00000`。`sign=sp_x[31]`，`exp=sp_x[30:23]`，`man=sp_x[22:0]`；`zero=(exp=0∧man=0)`，`inf=(exp=8'hff∧man=0)`，`nan=(exp=8'hff∧man≠0)`，`snan=nan∧¬man[22]`。
				- DP 输入：`dp_a=rs1_data`、`dp_b=rs2_data`、`dp_c=rs3_data`，`DP_QNAN=64'h7ff8000000000000`。`sign=dp_x[63]`，`exp=dp_x[62:52]`，`man=dp_x[51:0]`；`zero=(exp=0∧man=0)`，`inf=(exp=11'h7ff∧man=0)`，`nan=(exp=11'h7ff∧man≠0)`，`snan=nan∧¬man[51]`。
				- `lzc64(v)`：`v=0` 时为 64，否则为从 bit 63 起的前导零数；`lzc128(v)`：`v=0` 时为 128，否则为从 bit 127 起的前导零数。
				- `srj64(v,s)`：`s=0` 时为 `v`；`s≥64` 时为 `{63'b0,|v}`；其余为 `(v>>s[5:0]) | {63'b0,|(v&((64'b1<<s[5:0])-1))}`。`srj128` 以 128 bit 和 `s[6:0]` 作同一运算。
				- SP canonical：若 `exp≠0`，`sig={1'b1,man,40'b0}, e={8'b0,exp}`；若为零，`sig=0,e=-400`；其余令 `lz=lzc64({1'b0,man,40'b0})`，`sig={1'b0,man,40'b0}<<lz[5:0]`，`e=1-lz`。
				- DP canonical：若 `exp≠0`，`sig={1'b1,man,11'b0}, e={5'b0,exp}`；若为零，`sig=0,e=-2000`；其余令 `lz=lzc64({1'b0,man,11'b0})`，`sig={1'b0,man,11'b0}<<lz[5:0]`，`e=1-lz`。
				- `round_sp(sign,e,sig,rm)`：若 `e≤0`，令 `sub=1,sig=srj64(sig,1-e),e=0`；令 `m25={1'b0,sig[63:40]}`、`l=sig[40]`、`g=sig[39]`、`st=|sig[38:0]`、`ix=g∨st`；`RTZ/RDN/RUP/RMM/RNE` 的增量条件依次为 `0`、`sign∧ix`、`¬sign∧ix`、`g`、`g∧(st∨l)`。按条件对 `m25` 加 1；若 `m25[24]=1`，令 `m25={1'b0,m25[24:1]},e=e+1`。`tiny=sub∧¬m25[23]`，初始 `expf=sub?{7'b0,m25[23]}:e[7:0]`、`manf=m25[22:0]`；若 `¬sub∧e≥255`，置 `OF=NX=1`，并在 `RTZ∨(RDN∧¬sign)∨(RUP∧sign)` 时输出 `expf=8'hfe,manf=23'h7fffff`，否则输出无穷；最终 `NX=ix,UF=tiny∧ix`，返回 `{flags,sign,expf,manf}`。
				- `round_dp(sign,e,sig,rm)`：若 `e≤0`，令 `sub=1,sig=srj64(sig,1-e),e=0`；令 `m54={1'b0,sig[63:11]}`、`l=sig[11]`、`g=sig[10]`、`st=|sig[9:0]`、`ix=g∨st`，按与 `round_sp` 相同的五种条件舍入；进位时令 `m54={1'b0,m54[53:1]},e=e+1`。`tiny=sub∧¬m54[52]`，初始 `expf=sub?{10'b0,m54[52]}:e[10:0]`、`manf=m54[51:0]`；若 `¬sub∧e≥2047`，置 `OF=NX=1`，并按与 SP 相同的饱和条件输出 `expf=11'h7fe,manf=52'hfffffffffffff` 或无穷；最终 `NX=ix,UF=tiny∧ix`。
				- 有限加减 core：`b_sign=b.sign⊕(fpu_op=FPU_FSUB)`；按 `(a.e>b.e)∨(a.e=b.e∧a.sig≥b.sig)` 选择 large/small 的 exponent、significand 和 large sign；`small_aligned=srj64(small.sig,large.e-small.e)`；两有效符号相同时相加，否则 large-small。若产生 bit 64 carry，则右移一位并将被移出位 jam 入 bit 0，exponent 加 1；否则按低 64 bit 的 `lzc64` 左规并相应减 exponent。精确零的 sign 为：两个输入均为零且 `a.sign=b_sign` 时取 `a.sign`，否则取 `(rm=RDN)`。
				- SP 乘法 core：`sign=a.sign⊕b.sign`，`prod={24'b0,a.sig[63:40]}*{24'b0,b.sig[63:40]}`；`prod[47]=1` 时 `sig={prod,16'b0},e=a.e+b.e-126`，否则 `sig={prod[46:0],17'b0},e=a.e+b.e-127`。
				- DP 乘法 core：`sign=a.sign⊕b.sign`，`prod={53'b0,a.sig[63:11]}*{53'b0,b.sig[63:11]}`；`prod[105]=1` 时 `sig=prod[105:42]|{63'b0,|prod[41:0]},e=a.e+b.e-1022`，否则 `sig=prod[104:41]|{63'b0,|prod[40:0]},e=a.e+b.e-1023`。
				- SP 除法 core：`sign=a.sign⊕b.sign`，`num={a.sig[63:40],40'b0}`、`den={40'b0,b.sig[63:40]}`；`den=0` 时 `q=rem=0`，否则 `q=num/den,rem=num%den`；`lz=lzc64(q)`，`sig=(q<<lz[5:0])|{63'b0,|rem}`，`e=a.e-b.e+150-lz`。
				- DP 除法 core：`sign=a.sign⊕b.sign`，117 bit `num={a.sig[63:11],64'b0}`、`den={64'b0,b.sig[63:11]}`；`den=0` 时 `q=rem=0`，否则作 117 bit 除法和余数；`lz=lzc128({11'b0,q})`，`qw={11'b0,q}<<lz[6:0]`，`sig=qw[127:64]|{63'b0,(|qw[63:0])∨(|rem)}`，`e=a.e-b.e+1086-lz`。
				- SP 平方根 core：`ep=a.e-127`，`rad=ep[0]?{a.sig[63:40],38'b0}:{1'b0,a.sig[63:40],37'b0}`；从 `i=30` 到 0 执行恢复平方根，初始 `res=0,rem=0`，每步 `rem={rem[31:0],rad[2i+1],rad[2i]}`、`test={1'b0,res,2'b01}`，若 `rem≥test` 则 `rem=rem-test,res={res[29:0],1'b1}`，否则 `res={res[29:0],1'b0}`；`sig={res,33'b0}|{63'b0,|rem}`，`e=(ep>>>1)+127`。
				- DP 平方根 core：`ep=a.e-1023`，`rad=ep[0]?{a.sig[63:11],67'b0}:{1'b0,a.sig[63:11],66'b0}`；初始 `res=0,rem=0`，从 `i=59` 到 0，每步令 `rem={rem[60:0],rad[2i+1],rad[2i]}`、`test={1'b0,res,2'b01}`，若 `rem≥test` 则 `rem=rem-test,res={res[58:0],1'b1}`，否则 `res={res[58:0],1'b0}`；`sig={res,4'b0}|{63'b0,|rem}`，`e=(ep>>>1)+1023`。
				- FMA sign：`neg_ab=(fpu_op=FPU_FNMSUB)∨(fpu_op=FPU_FNMADD)`，`neg_c=(fpu_op=FPU_FMSUB)∨(fpu_op=FPU_FNMADD)`；`product_sign=a.sign⊕b.sign⊕neg_ab`，`c_sign=c.sign⊕neg_c`，`product_zero=a.zero∨b.zero`。
				- SP FMA core：先按 SP 乘法形成 48 bit product；product 为零时 `product_sig=0,product_e=-400`，否则按 SP 乘法 core 规格化。按 exponent 后按 significand 比较 product 与 `c`，选择 large/small；用 `srj64` 对齐 small，按 `product_sign=c_sign` 决定相加或 large-small，再按有限加减 core 规格化。精确零 sign 为：product 与 `c` 均为零且二者有效 sign 相等时取 product sign，否则取 `(rm=RDN)`。
				- DP FMA core：形成 106 bit product 和 `c_sig128={c.sig,64'b0}`；product 为零时 `product_sig=0,product_e=-2000`；`prod[105]=1` 时 `product_sig={prod,22'b0},product_e=a.e+b.e-1022`，否则 `product_sig={prod[104:0],23'b0},product_e=a.e+b.e-1023`。按 SP FMA 的比较、`srj128` 对齐、加减和规格化规则产生 128 bit `normalized_sig`，再令 `sig=normalized_sig[127:64]|{63'b0,|normalized_sig[63:0]}`；零 sign 规则同 SP。
				- `FPU_FADD/FPU_FSUB`：若任一输入为 NaN，输出 canonical qNaN，仅任一 sNaN 时置 NV；否则若两个 infinity 的有效 sign 相反，输出 qNaN 并置 NV；否则依次选择 `a` infinity、`b` 有效 sign infinity、有限 core 的精确零或 `round_sp/dp` 结果与 flags。
				- `FPU_FMUL`：若任一输入为 NaN，输出 qNaN，仅 sNaN 置 NV；`infinity*zero` 输出 qNaN 并置 NV；其余依次选择带乘积 sign 的 infinity、带乘积 sign 的 zero 或乘法 core 的舍入结果与 flags。
				- `FPU_FDIV`：若任一输入为 NaN，输出 qNaN，仅 sNaN 置 NV；`infinity/infinity` 或 `zero/zero` 输出 qNaN 并置 NV；有限非零除以 zero 输出带除法 sign 的 infinity 并置 DZ；其余依次选择分子 infinity、分母 infinity 或分子 zero 对应的带 sign zero、除法 core 的舍入结果与 flags。
				- `FPU_FSQRT`：NaN 输出 qNaN，仅 sNaN 置 NV；zero 保留输入 sign；负的非零输入输出 qNaN 并置 NV；正 infinity 输出正 infinity；其余选择平方根 core 的舍入结果与 flags。
				- `FPU_FEQ/FPU_FLT/FPU_FLE`：结果初值 0。任一 NaN 时结果 bit 0 为 0；`FLT/FLE` 对任一 NaN 置 NV，`FEQ` 仅对任一 sNaN 置 NV。无 NaN 时，`FEQ=(a.zero∧b.zero)∨(a=b)`；`FLT` 对双零为 0，否则使用按 sign 和 magnitude 比较的 `a_lesser`；`FLE` 对双零为 1，否则为 `a_lesser∨(a=b)`。
				- magnitude 比较：sign 不同时，`a_lesser=a.sign,a_greater=b.sign`；同为负时分别以 `a.magnitude>b.magnitude`、`a.magnitude<b.magnitude` 判断；同为正时分别以 `<`、`>` 判断。
				- `FPU_FMIN`：任一 sNaN 置 NV；双 NaN 输出 qNaN，单 NaN 输出另一输入，双零在任一 sign 为负时输出负零，否则输出正零，其余由 `a_lesser` 选择。`FPU_FMAX` 相同，但双零仅在两个 sign 均为负时输出负零，其余由 `a_greater` 选择。
				- `FPU_FSGNJ/FPU_FSGNJN/FPU_FSGNJX`：保留 `a` 的非 sign 位，结果 sign 分别为 `b.sign`、`¬b.sign`、`a.sign⊕b.sign`。
				- `FPU_FCLASS`：结果仅 bit 9:0 可非零；负 infinity、负 normal、负 subnormal、负 zero、正 zero、正 subnormal、正 normal、正 infinity、sNaN、qNaN 分别置 bit 0 至 bit 9。
				- `FMV_X_W`：`{{32{rs1_data[31]}},rs1_data[31:0]}`；`FMV_W_X`：`{32'hffffffff,rs1_data[31:0]}`；`FMV_X_D`、`FMV_D_X` 均为 `rs1_data`。
				- `FCVT_D_S`：NaN 输出 `DP_QNAN` 且仅 sNaN 置 NV；infinity 和 zero 保留 sign；其余输出 `{a.sign,(a.e+896)[10:0],a.sig[62:11]}`，不置舍入 flags。
				- `FCVT_S_D`：NaN 输出 NaN-boxed `SP_QNAN` 且仅 sNaN 置 NV；infinity 和 zero 保留 sign 并 NaN-box；其余对 `sign=a.sign,e=a.e-896,sig=a.sig` 使用 `round_sp`。
				- INT-to-FP 源：`*_W` 以 `rs1_data[31]` 为 sign 并对低 32 bit 求补码绝对值；`*_WU` 取无符号低 32 bit；`*_L` 以 bit 63 为 sign 并求 64 bit 补码绝对值；`*_LU` 取无符号 64 bit。令 `lz=lzc64(magnitude),sig=magnitude<<lz[5:0]`；magnitude 为 0 时结果为 0，否则 SP 使用 `round_sp(sign,190-lz,sig,rm)`，DP 使用 `round_dp(sign,1086-lz,sig,rm)`。
				- FP-to-INT 格式：`FCVT_W/WU_*` 选择 32 bit，`FCVT_L/LU_*` 选择 64 bit；`WU/LU` 选择 unsigned；后缀 `_D` 选择 DP 输入，否则选择 SP 输入。选择输入的 `sign/nan/inf/sig`，令 `shift=DP?(e-1022):(e-126)`；`shift≥65` 标记 exponent overflow；`shift≥128` 时 `w=0`，`0≤shift<128` 时 `w={64'b0,sig}<<shift`，`shift≤-128` 时 `w={127'b0,|sig}`，其余 `w=srj128({64'b0,sig},-shift)`。
				- FP-to-INT 舍入：`l=w[64],g=w[63],st=|w[62:0],ix=g∨st`，五种舍入模式的 increment 条件与浮点 rounder 相同；`magnitude_rounded={1'b0,w[127:64]}+increment`。32/64 bit signed 正上限为 `0x7fffffff/0x7fffffffffffffff`、负 magnitude 上限为 `0x80000000/0x8000000000000000`；unsigned 正上限为全 1，负上限为 0。NaN、infinity、exponent overflow 或 magnitude 超限时 invalid；否则按 sign 对 rounded magnitude 求补码。
				- FP-to-INT invalid 结果：NaN 或正值超限时，32 bit unsigned 为 `64'hffffffffffffffff`、32 bit signed 为 `64'h000000007fffffff`、64 bit unsigned 为全 1、64 bit signed 为 `64'h7fffffffffffffff`；负值超限时，unsigned 为 0、32 bit signed 为 `64'hffffffff80000000`、64 bit signed 为 `64'h8000000000000000`。invalid 置 NV，否则 `ix` 置 NX；W/WU 结果最终符号扩展低 32 bit，L/LU 返回完整 64 bit。
				- FMA 特殊值：先判 `zero*infinity` 或 `infinity*zero`，输出 qNaN 并置 NV；否则任一输入 NaN 时输出 qNaN，仅任一 sNaN 置 NV；若非 NaN infinity product 与 infinity `c` 的有效 sign 相反，输出 qNaN 并置 NV；否则依次选择 infinity product、infinity `c`、FMA core 精确零或 FMA core 的舍入结果与 flags。
				- `FPU_NONE`：`fpu_result=0,fpu_fflags_c=0`。
			- `exe_subop`：见本条 payload；编码由 `exe_subop_pkg` 定义。
			- `full_decode`：见本条 payload。
			- `rs1_data`：见本条 payload。
			- `rs2_data`：见本条 payload。
			- `rs3_data`：见本条 payload。
4. `writeback_valid`、`bypass_publish_valid`：同拍发布寄存的 completion 与 bypass。
	- Fire来源：`writeback_valid.fire = bypass_publish_valid.fire = entry.payload.completion.result_valid`
		- `entry.payload.completion.result_valid`：见 `Data structure -> State` 第 3 条。
	- Constraint：每次 `issue_valid.fire` 只在下一拍产生一拍 `writeback_valid.fire` 和 `bypass_publish_valid.fire`；无下游 ready；二者允许与 `global_flush_late.fire` 同拍为 1。
	- Payload：`fpu_simple_writeback_payload` 和 `fpu_simple_bypass_payload`；当前拍有效。
		- `fpu_simple_writeback_payload`、`fpu_simple_bypass_payload`：见 `Interface -> Out-event` 第 1、2 条。
	- State update：本拍上升沿 `busy_q <- 0`；`entry.payload.completion <- 0`。

## Data structure

### State

1. `completion_state`：由 `busy_q` 和 `entry.payload.completion.result_valid` 编码；二者在可达状态中相等，0 为 `IDLE`，1 为 `COMPLETION_VALID`。
2. `busy_q`：1 bit；执行单元占用状态；由 `reset`、`global_flush_late`、`issue_valid` 和 `writeback_valid` 更新。
3. `entry.payload.completion.result_valid`：1 bit；completion 有效位；由 `reset`、`global_flush_late`、`issue_valid` 和 `writeback_valid` 更新。

### Header

无。

### Payload

1. `entry.payload.completion`：来源于 `fpu_simple_issue_payload`。
	- `fpu_simple_issue_payload`：`rs1_data`、`rs2_data`、`rs3_data`、`self_tag`、`exe_subop`、`full_decode`；见 `FSM -> Detailed Condition Description` 第 3 条。

## Internal Connections

无。

## Interface

### In-event

1. `global_flush_late`：Notify，单 lane。
	- Fire来源：`global_flush_late.fire`
	- Payload：∅；当前拍 pulse。
2. `issue_valid`：Transaction，单 lane。
	- Fire来源：见 `FSM -> Detailed Condition Description` 第 3 条。
	- Payload：`fpu_simple_issue_payload`；fire 所在上升沿采样。
	`fpu_simple_issue_payload`：`rs1_data` `XLEN` bit × 1、`rs2_data` `XLEN` bit × 1、`rs3_data` `XLEN` bit × 1、`self_tag` `TAG_W` bit × 1、`exe_subop` `EXE_SUBOP_W` bit × 1、`full_decode` `FULL_DECODE_W` bit × 1。

### In Static Info

1. `rst_n`：1 bit；低有效异步复位；由全部状态和 payload 寄存器读取。

### Out-event

1. `writeback_valid`：Notify，单 lane。
	- Fire来源：见 `FSM -> Detailed Condition Description` 第 4 条。
	- Payload：`fpu_simple_writeback_payload`；当前拍 pulse。
	`fpu_simple_writeback_payload`：`tag_out` `TAG_W` bit × 1、`result_data` `XLEN` bit × 1、`mispredict_flag` 1 bit × 1、`mispredict_target_pc` `XLEN` bit × 1、`exception_flag` 1 bit × 1、`exception_cause` `EXCP_CAUSE_W` bit × 1、`exception_tval` `XLEN` bit × 1、`is_mret` 1 bit × 1、`is_sret` 1 bit × 1、`fpu_fflags` `FFLAGS_W` bit × 1；`EXCP_CAUSE_W`、`FFLAGS_W` 由 `or_be_types_pkg` 定义。
		- `tag_out = entry.payload.completion.tag_out`
			- `entry.payload.completion.tag_out`：见 `Data structure -> Payload` 第 1 条。
		- `result_data = entry.payload.completion.result_data`
			- `entry.payload.completion.result_data`：见 `Data structure -> Payload` 第 1 条。
		- `mispredict_flag = entry.payload.completion.mispredict_flag`
			- `entry.payload.completion.mispredict_flag`：见 `Data structure -> Payload` 第 1 条；值为 0。
		- `mispredict_target_pc = entry.payload.completion.mispredict_target_pc`
			- `entry.payload.completion.mispredict_target_pc`：见 `Data structure -> Payload` 第 1 条；值为 0。
		- `exception_flag = entry.payload.completion.exception_flag`
			- `entry.payload.completion.exception_flag`：见 `Data structure -> Payload` 第 1 条；值为 0。
		- `exception_cause = entry.payload.completion.exception_cause`
			- `entry.payload.completion.exception_cause`：见 `Data structure -> Payload` 第 1 条；值为 0。
		- `exception_tval = entry.payload.completion.exception_tval`
			- `entry.payload.completion.exception_tval`：见 `Data structure -> Payload` 第 1 条；值为 0。
		- `is_mret = entry.payload.completion.is_mret`
			- `entry.payload.completion.is_mret`：见 `Data structure -> Payload` 第 1 条；值为 0。
		- `is_sret = entry.payload.completion.is_sret`
			- `entry.payload.completion.is_sret`：见 `Data structure -> Payload` 第 1 条；值为 0。
		- `fpu_fflags = entry.payload.completion.fpu_fflags`
			- `entry.payload.completion.fpu_fflags`：见 `Data structure -> Payload` 第 1 条。
2. `bypass_publish_valid`：Notify，单 lane。
	- Fire来源：见 `FSM -> Detailed Condition Description` 第 4 条。
	- Payload：`fpu_simple_bypass_payload`；当前拍 pulse。
	`fpu_simple_bypass_payload`：`bypass_tag` `TAG_W` bit × 1、`bypass_data` `XLEN` bit × 1。
		- `bypass_tag = entry.payload.completion.tag_out`
			- `entry.payload.completion.tag_out`：见 `Data structure -> Payload` 第 1 条。
		- `bypass_data = entry.payload.completion.result_data`
			- `entry.payload.completion.result_data`：见 `Data structure -> Payload` 第 1 条。

### Out Static Info

1. `FU_ready`：1 bit × 1；当前拍组合有效。
	- `FU_ready = ¬busy_q`
		- `busy_q`：见 `Data structure -> State` 第 2 条。

### Interface Timing

1. `clk`：所有非异步复位状态和 completion payload 在上升沿采样或更新。
2. `rst_n`：低有效异步复位；为 0 时清除 `busy_q` 和全部 completion payload。
3. `Transaction`：`issue_valid` 的 valid 与 payload 由输入方保持至 `issue_valid.fire`；本模块没有输出 Transaction。
4. `Notify`：`global_flush_late.fire` 为输入 pulse；`writeback_valid.fire` 和 `bypass_publish_valid.fire` 是同拍的一周期输出 pulse，payload 在该拍有效，且不被同拍 `global_flush_late.fire` 组合取消。
5. `Static Info`：`FU_ready` 当前拍组合有效；复位或 flush 清除状态的上升沿之后为 1。
