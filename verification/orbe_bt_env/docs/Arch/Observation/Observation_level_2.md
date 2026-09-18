# LEVEL-2 观测点

## 1. 目标与统一规则

Level 2 观测点服务于数据通路还原和首个失配点定位。按照流水线节点，本页
固定为以下五大类：

1. FE-BE interface；
2. decode 之后；
3. 进入 FU 之前（before execute）；
4. 出 FU 之后（after execute）；
5. BE-LSU interface。

### 1.1 实现位置与启用条件

- 观测边界信号定义在 `tb/interfaces/ob_cosim_if.sv`，payload 类型定义在
  `tb/pkg/orbe_cosim_obs_pkg.sv`；rtl_v1 侧采集在 `tb/top/rtl_v1_obs_probe.sv`
  与 `tb/top/rtl_v1_wrapper.sv`；采样、比较与日志在
  `tb/agents/be/be_agent.sv`。
- 仅当 `cfg.cosim_enable && cfg.cosim_level >= 2` 时 `level2_enabled()` 为真；
  默认 `COSIM_LEVEL=1`，合法值为 1 或 2。
- 全部 Level-2 采集/比较代码位于 `` `ifdef ORBE_DUT_RTL_V1 ``，因此当前只有
  rtl_v1 DUT 产生 Level-2 观测，mock 路径不产生。
- 只有 **decode 之后**、**出 FU 之后（WRITEBACK）** 和 **BE-LSU issue** 三处
  存在自动比较字段。其余节点（FE-BE、进入 FU 之前的 ISQ0/1/2/3、
  CSR_IN/CSR_OUT、BE-LSU response）均为
  **只观察（OBSERVATION ONLY, NOT COMPARED）**，不参与 COSIM pass/fail。
- 自动比较字段一旦失配，`be_agent` **不会在自己的比较点立刻 fatal**：它只设置
  该 rob 的 mismatch 标记，在对应 commit/recovery 时打印完整生命周期日志，并把
  `level2_mismatch` 随 commit/recovery event 送入 `cosim_pkg`。真正的中止是
  **cycle-end 统一 fatal**：`cosim_pkg` 在本 sampling cycle 的全部 commit/
  recovery event 收齐、完成架构状态比较和 Level-1 mismatch 处理之后，才在
  `cosim_commit_order_adapter::check_cycle()` 末尾以
  `[COSIM][LEVEL2_MISMATCH]` fatal 终止该用例。若本拍 Level-1 没有 mismatch，
  会先打印 `[COSIM] [<label>] cycle=...; Level-1 fields match; Level-2 mismatch
  pending`，再 fatal。

  传播链路：`consume_*()` 逐字段比较 → `l2_any_mismatch_by_rob[rob_idx]` →
  `publish_cosim_commit_event()` / `publish_cosim_recovery_event()` 置
  `commit_event.level2_mismatch` → `cosim_pkg` 累积 `pending_level2_mismatch`
  → cycle-end 统一 fatal。
- Level-2 日志的触发规则分两类，不能混为一谈：
  - **FE-BE**：`observe_fe_be_interface()` 对每个被接受的握手拍
    （`fe_be_instr_valid[lane] && be_fe_instr_ready[lane]`）直接
    `diagnostic()` 输出，与是否失配无关，也不进入 per-ROB 生命周期；
  - **其余所有 Level-2 行**（`[DECODE]`、`[ISQ0..3]`、`[WRITEBACK]`、
    `[BE-LSU]`、`[CSR_IN]`、`[CSR_OUT]`，含各通道的比较行和只观察行）：
    先暂存在 per-rob 数组，只有该 rob **最终出现 Level-2 mismatch** 时，
    才随 `emit_level2_lifecycle()` 在 commit/recovery 时输出；无失配的 rob
    只做暂存/清理，不打印。
- 以上输出均使用 `reporter.diagnostic()`，不受 `VERBOSITY` 门控。

| 节点 | be_agent 入口 | 生命周期标签 | 是否自动比较 |
| --- | --- | --- | --- |
| FE-BE interface | `observe_fe_be_interface()` | `[FE-BE]` | 否，只观察 |
| decode 之后 | `observe_allocations()` → `consume_decode()` | `[DECODE]` | 是（部分字段） |
| 进入 FU 之前 | `observe_isq_issue()` → `consume_isq_response()` | `[ISQ0]/[ISQ1]/[ISQ2]/[ISQ3]` | 否，只观察 |
| 出 FU 之后 | `observe_execution_writebacks()` → `consume_writeback()` | `[WRITEBACK]` | 是（部分字段） |
| CSR 单元边界 | `observe_csr_events()` → `consume_csr_events()` | `[CSR_IN]/[CSR_OUT]` | 否，只观察 |
| BE-LSU interface | `sample_lsu_issue()` / `consume_lsu_issue()`；`observe_lsu_responses()` / `consume_lsu_response()` | `[BE-LSU]` | issue 是（部分字段），response 只观察 |

CSR 单元边界不是独立的流水线节点，也没有对应的独立章节：`CSR_IN` 是
**CSR FU 的 issue/accept 边界**（≈ 进入 CSR FU 之前），`CSR_OUT` 是
**CSR FU 的 completion sideband**（≈ 出 CSR FU 之后）。二者是 `ob_cosim_if`
上独立于 decode payload 和 `fu_after_*` 的观测通道，按 tag 暂存，统一在
commit/recovery 时以 `[CSR_IN]` / `[CSR_OUT]` 生命周期标签输出，**不要求与
decode payload 或 `fu_after_*` 同拍，也不来自同一接口**。本文因为它们不
属于五大流水线节点，才把 CSR_IN 挂在 §3.3、把 CSR_OUT 挂在 §5.3；这只是
**文档分类**，不是硬件归属。

### 1.2 字段可用性定义

纳入本页 Level 2 观测面的字段分为两类：

- **参与比较的共用字段**：必须满足 `DPI 直接` 或 `DPI 间接` 之一，即
  ISA_model 侧能稳定给出同语义的参考值；
- **只观察的 DUT 诊断字段**：只从 DUT/观测接口取得，不要求 ISA_model 有
  对应 getter，不参与 COSIM pass/fail。

其中 `DPI 直接` / `DPI 间接` 定义如下：

- `DPI 直接`：DPI-C API 或 DPI 调用参数直接给出该字段；
- `DPI 间接`：DPI 可以取得原始指令、模型状态或 per-ROB metadata，并可依据现有的确定性规则（例如 RVA23_IMAFDC_Classification.xlsx 中的指令编码与分类规则）推导或重构出目标字段。

不能稳定地从当前 DPI 取得，或者字段只代表 DUT 的调度实现细节的字段，不进入
ISA_model/DUT 共用 payload；它们只能作为只观察字段出现在 DUT 侧日志中。

`self_tag`、`rob_idx`、`tag` 是事件关联键。它们用于把 DUT entry 与
ISA_model 的 `(model_core_id, rob_idx)` 对齐，不要求 ISA_model 重新产生
同名的物理 tag。

### 1.3 当前 DPI 的实际能力边界

当前 `isa_dpi_pkg.sv` / `isa_dpi_wrapper.cc` 可用于 Level 2 的主要接口为：

| DPI | 可取得的信息 |
| --- | --- |
| `isa_dpi_decode_and_issue()` | `pc`、`inst_bits`、`force_rvc` 的模型输入；建立 `(core, rob_idx)` anchor |
| `isa_dpi_decode_mnemonic()` | 由原始指令编码得到 mnemonic；当前受 `ORBE_EXTERNAL_MNEMONICS` 宏控制 |
| `isa_dpi_get_insn_pc()` | 指定 per-ROB entry 的 `pc` |
| `isa_dpi_get_decode_metadata()` | `is_lsu`、decode 阶段 trap valid/cause/tval |
| `isa_dpi_get_decode_semantic()` | `rs1/rs2/rs3` 的 valid、`is_fp`、index，`is_store`、`imm_valid`、`imm_data`、`exe_subop` |
| `isa_dpi_get_insn_metadata()` | `rd_valid`、`rd_is_fp`、`rd_write_enable`、`rd_idx`、`rd_value`、`recovery_kind` |
| `isa_dpi_get_lsu_issue_metadata()` | LSU issue 的分类、subop、访问属性、操作数和立即数 |
| `isa_dpi_get_execute_metadata()` | execute 阶段 trap valid/cause/tval |
| `isa_dpi_get_commit_auto_trap_info()` | `commit_auto` 之后的 trap 记录 |
| `isa_dpi_get_insn_rd_value()` | 当前 in-flight entry 的 `rd` 结果 |
| `isa_dpi_is_insn_redirect()` / `isa_dpi_get_next_pc_of_insn()` | 指令的 redirect 判定和 next PC |
| `isa_dpi_has_trap()` | 指定 per-ROB entry 的 trap 有效位 |
| `isa_dpi_get_csr()` / `isa_dpi_get_priv()` | CSR 状态和当前特权级 |
| `isa_dpi_has_pending_interrupt()` / `isa_dpi_take_interrupt()` | pending interrupt 及其 redirect PC |
| `isa_dpi_translate_pte()` | 给定 virtual address 的地址转换、PTE trace 和 translation trap |

`isa_dpi_get_decode_semantic()` 与 `isa_dpi_get_insn_metadata()` 是本版
Level 2 新增的直接 getter：decode 的 `rs*/rd/is_store/imm/exe_subop`
因此不再依赖“由原始编码间接重构”。

`isa_dpi_get_execute_metadata()` 只返回 trap 三元组，不是完整的 FU output
payload getter。FU 结果必须结合 `get_insn_rd_value`、redirect getter 和
execute metadata 使用。

ISA_model 的 `IsaApi.h` 中虽然声明了 `funcMultiCore_getInsnType()`，但当前
ORBE DPI wrapper/package 没有对应的 `isa_dpi_get_insn_type()` 导出。因此
本页的 `inst_type` 统一按原始编码、`is_compressed` 和
`isa_dpi_decode_mnemonic()` 间接获得；不能把未导出的函数当作现成 DPI 信号。

## 2. FE-BE interface

### 2.1 节点边界

本节点包含：

- FE -> BE instruction transaction；
- BE -> FE redirect transaction。

采样位于 `observe_fe_be_interface()`，使用 `orbe_fe_if`
（`orbe_fe_types_pkg` 的 `orbe_fe_instr_pld_t` / `orbe_fe_redirect_pld_t`），
每拍检查 2 个 lane。本节点**全部字段只观察，不比较**，而且是 Level-2 中
唯一按事件逐拍输出、不受 per-ROB 失配门控的通道。

### 2.2 FE -> BE payload

只有 `fe_be_instr_valid[lane] == 1 && be_fe_instr_ready[lane] == 1` 时才记录；
lane 0 为较老的指令，lane 1 只有在 lane 0 同拍有效时才可能有效。

| 字段 | DUT 来源 | 说明 | 状态 |
| --- | --- | --- | --- |
| `pc` | `fe_be_instr_pld[lane].pc` | 与 allocation 时送入 ISA_model 的 pc 同源 | 只观察 |
| `inst_bits` | `fe_be_instr_pld[lane].inst_bits` | 原始指令编码 | 只观察 |
| `is_compressed` | `fe_be_instr_pld[lane].is_compressed` | RVC 语义 | 只观察 |
| `pred_taken` | `fe_be_instr_pld[lane].pred_taken` | 模型侧不产生同等方向预测 | 只观察 |
| `pred_target_pc` | `fe_be_instr_pld[lane].pred_target_pc` | 同上 | 只观察 |
| `fetch_excp_vld` | `fe_be_instr_pld[lane].fetch_excp_vld` | 取指异常边界；模型 trap 由 `get_decode_metadata()` 复核 | 只观察 |
| `fetch_excp_cause` / `exception_cause` | `fe_be_instr_pld[lane].exception_cause` | 取指异常 cause | 只观察 |
| `fetch_excp_tval` / `exception_tval` | `fe_be_instr_pld[lane].exception_tval` | 取指异常地址 | 只观察 |

`valid`、`pc`、`inst_bits`、`is_compressed` 会做 X/Z 检查，出现 X/Z 视为
fatal。取指异常 entry 的 pc、inst_bits 和 is_compressed 按上述接口记录；
异常语义仍以 fetch_excp_* 和模型 trap metadata 为准，但本节点不做比较。

### 2.3 BE -> FE redirect payload

最终 `redirect_pc` 和 `recovery_kind` 已由 Level-1 的
`commit_redirect_pc` / `commit_recovery_kind` 统一观测；本节点只保留
BE-FE 边界特有的 redirect 原因分类字段。

| 字段 | DUT 来源 | 说明 | 状态 |
| --- | --- | --- | --- |
| `be_fe_redirect_valid` | `orbe_fe_if.be_fe_redirect_valid` | redirect 事件有效 | 只观察 |
| `redirect_pc` | `be_fe_redirect_pld.redirect_pc` | 与 Level-1 `commit_redirect_pc` 同源 | 只观察 |
| `interrupt_valid` | `be_fe_redirect_pld.interrupt_valid` | 由 redirect kind 为 INTERRUPT 派生 | 只观察 |
| `trap_valid` | `be_fe_redirect_pld.trap_valid` | 由 EXCEPTION/MRET/SRET 派生 | 只观察 |

## 3. decode 之后

### 3.1 节点边界

本节点定义为 `decode` 输出经过 dispatch 前的规范化译码 payload，由
`ob_cosim_if.decode_issue_pld[group]`（`cosim_decode_pld_t`）提供。

rtl_v1 侧该 payload 是 `rtl_v1_obs_probe` 在 allocation 边界寄拍后的快照
（`obs_alloc_pld`）。DUT 的主要来源是 backend 的 decode/allocation 信号：
`ib_payload`、`ib_rs*_idx`、`ib_rd_idx`、`ib_rs*_is_fp`、`ib_rd_is_fp`、
`ib_use_rs*`、`ib_use_rd`、`ib_is_store`、`dec_info[].mem_funct3`、
`dec_info[].imm_*`、`ib_exe_subop`、`ib_is_serial`、`ib_is_fp_instruction`、
`dl_is_atomic`、`ib_is_fp_opcode`、`ib_full_decode`。

在 `observe_allocations()` 中随 allocation 一起采样，在 `consume_decode()`
（commit 或 recovery 时）比较。参考侧使用 `isa_dpi_get_insn_pc()`、
`isa_dpi_get_decode_semantic()`、`isa_dpi_get_insn_metadata()`，以及
`isa_dpi_get_decode_metadata()`（is_lsu/trap）。

### 3.2 规范化 decode payload

| 字段 | DUT 来源 | DPI/ISA_model 来源 | 状态 | 用途 |
| --- | --- | --- | --- | --- |
| `pc` | `decode_issue_pld.pc` | `isa_dpi_get_insn_pc()` | 自动比较（总是） | 指令关联 |
| `rs1_idx` / `rs1_is_fp` | `decode_issue_pld.rs1_*` | `get_decode_semantic().rs1_idx / rs1_is_fp` | 自动比较（`use_rs1` 且 `ref_rs1_idx != 0`） | 源寄存器定位 |
| `rs2_idx` / `rs2_is_fp` | `decode_issue_pld.rs2_*` | `get_decode_semantic().rs2_idx / rs2_is_fp` | 自动比较（`use_rs2` 且 `ref_rs2_idx != 0`） | 源寄存器定位 |
| `rs3_idx` / `rs3_is_fp` | `decode_issue_pld.rs3_*` | `get_decode_semantic().rs3_idx / rs3_is_fp` | 自动比较（`use_rs3` 且 `ref_rs3_idx != 0`） | 源寄存器定位 |
| `rd_idx` / `rd_is_fp` | `decode_issue_pld.rd_*` | `get_insn_metadata().rd_idx / rd_is_fp` | 自动比较（`use_rd` 且 `ref_rd_idx != 0`） | 目的寄存器定位 |
| `is_store` | `decode_issue_pld.is_store` | `get_decode_semantic().is_store` | 自动比较（总是） | store 路径选择 |
| `imm_valid` | `decode_issue_pld.imm_valid` | `get_decode_semantic().imm_valid` | 自动比较（当 `use_rs1/2/3`、`use_rd` 或 `is_store` 之一） | 立即数语义 |
| `imm_data` | `decode_issue_pld.imm_data` | `get_decode_semantic().imm_data` | 自动比较（上式且双方 `imm_valid`） | 立即数语义 |
| `exe_subop` | `decode_issue_pld.exe_subop` | `get_decode_semantic().exe_subop` | 自动比较（总是） | 执行类别 canonical key |
| `inst_bits` | `decode_issue_pld.inst_bits` | 无对应 getter | DUT-only 只观察 | decode 原始输入 |
| `is_compressed` | `decode_issue_pld.is_compressed` | 无对应 getter | DUT-only 只观察 | RVC 规范化 |
| `inst_type` / mnemonic | 原始编码和 DUT decode 结果 | `isa_dpi_decode_mnemonic()`（`ORBE_EXTERNAL_MNEMONICS` 下） | 只观察 | 指令类别和日志标签 |
| `use_rs1` / `use_rs2` / `use_rs3` / `use_rd` | `decode_issue_pld.use_*` | 无对应 getter | DUT-only 只观察（同时作为上面的比较条件） | 依赖检查输入 |
| `mem_funct3` | `decode_issue_pld.mem_funct3` | 无对应 getter | DUT-only 只观察 | 访存宽度和符号属性 |
| `is_serial` | `decode_issue_pld.is_serial` | 无对应 getter | DUT-only 只观察 | serial 入口定位 |
| `is_fp_instruction` / `dec_is_fp_opcode` | `decode_issue_pld.is_fp_instruction / dec_is_fp_opcode` | 无对应 getter | DUT-only 只观察 | FPU 路径定位 |
| `is_atomic` | `decode_issue_pld.is_atomic` | 无对应 getter | DUT-only 只观察 | 原子访问和顺序约束 |
| `full_decode.csr_write_intent` | `decode_issue_pld.full_decode[16]` | 无对应 getter | DUT-only 只观察 | CSR 写意图 |
| `full_decode.illegal` | `decode_issue_pld.full_decode[15]` | 无对应 getter | DUT-only 只观察 | 非法指令定位 |
| `full_decode.rm` | `decode_issue_pld.full_decode[14:12]` | 无对应 getter | DUT-only 只观察 | FP 舍入模式 |
| `full_decode.csr_addr` | `decode_issue_pld.full_decode[11:0]` | 无对应 getter | DUT-only 只观察 | CSR 地址 |
| `is_lsu` | `dl_slot_FU_Group[group] == 3` | `isa_dpi_get_decode_metadata().is_lsu` | DPI 直接，仅用于 LSU 与非 LSU 分流，不在 decode 比较中 | LSU 分流 |
| decode trap (`trap_valid/cause/tval`) | `ib_payload.fetch_excp_*` | `isa_dpi_get_decode_metadata()` | 只观察；取指异常 entry 不参与语义 decode 比较 | decode 阶段异常 |

`self_tag`/`rob_idx` 在本节点作为关联键保留。`rsX_ready`、
`rsX_wait_tag`、`rs_data_sel_t`、`slot_FU_Group` 和 dispatch 的
`select_payload` 属于 DUT 调度实现信息，不作为 ISA/DUT 的规范化 decode
比较字段，也不进入本版 Level-2 payload。

### 3.3 CSR 单元边界观测（CSR_IN）

CSR FU 请求进入边界由 `ob_cosim_if.csr_in_*` 暴露：`csr_in_valid` /
`csr_in_addr` 分别取自 `u_backend.u_csr_unit.accept` 和
`u_backend.csrfu_csr_addr`，因此它是 **CSR FU 的 issue/accept 边界**（本质
更接近“进入 CSR FU 之前”），而不是 decode 边界。`observe_csr_events()` 按
`csr_in_tag` 暂存，`consume_csr_events()` 在对应 rob 的 commit/recovery 时
打印。**本通道只观察，不比较。**它与 §3.2 的 decode payload 不是同一接口、
也不是同拍数据；放在本节只是延续“decode 之后”的文档分组。

| 字段 | DUT 来源 | 说明 |
| --- | --- | --- |
| `csr_in_valid` | `u_backend.u_csr_unit.accept` | CSR FU 接受请求 |
| `csr_in_tag` | `u_backend.isq0_self_tag` | 关联键 |
| `csr_in_addr` | `u_backend.csrfu_csr_addr` | CSR 地址 |
| `csr_in_rdata` | `u_backend.sih_csr_rdata` | CSR read port 旧值 |
| `csr_in_current_priv` | `u_backend.sih_current_priv` | 当前特权级 |
| `csr_in_fs_enabled` | `u_backend.sih_fs_enabled` | FP/CSR legality 上下文 |

旧版列出的 `frm`、`mstatus_tvm/tw/tsr` 等 CSR 上下文当前没有独立采集点；
`isa_dpi_get_csr()` / `isa_dpi_get_priv()` 虽然可用，但本版 Level-2 没有
把它们与 CSR_IN 事件做自动比较。

CSR OUT（completion sideband）见 §5.3。

## 4. 进入 FU 之前

### 4.1 节点边界和策略

本节点是 ISQ Group 0/1/2/3 向具体 FU 或 LSU 交付的 payload，来自 backend
的 `isq{0,1,2,3}_issue_pld`，经 `ob_cosim_if.isq_g*_issue_pld` 暴露。
`observe_isq_issue()` 按 `self_tag` 暂存最近一次 issue payload，
`consume_isq_response()` 在 commit/recovery 时打印。

本节点**只从 DUT 提取**，不调用 ISA_model getter 生成对应 payload，也不
参与 COSIM pass/fail。它是 AI debug 的数据通路参考。AI 使用
`inst_type`/`exe_subop` 和实际操作数重建“FU 正常条件下应该产生的结果”，
再与“出 FU 之后”的 DUT payload 对照。日志只在该 rob 最终出现 Level-2
mismatch 时随 lifecycle 输出（与 FE-BE 的逐拍输出规则不同）。

### 4.2 分组 payload

| Group | payload 类型 | payload 字段 | 日志打印字段 |
| --- | --- | --- | --- |
| G0 ALU/BRU | `cosim_isq_g0_issue_pld_t` | `rs1_data`、`rs2_data`、`fu_group`、`imm_valid`、`imm_data`、`pc`、`inst_bits`、`is_compressed`、`pred_taken`、`pred_target_pc`、`self_tag`、`exe_subop`、`full_decode`、`fetch_excp_vld`、`fetch_excp_cause`、`fetch_excp_tval` | `self_tag`、`pc`、`inst_bits`、`rs1_data`、`rs2_data` |
| G1 ALU/MUL | `cosim_isq_g1_issue_pld_t` | `rs1_data`、`rs2_data`、`imm_data`、`self_tag`、`fu_group`、`exe_subop` | `self_tag`、`rs1_data`、`rs2_data`、`imm_data` |
| G2 FPU | `cosim_isq_g2_issue_pld_t` | `rs1_data`、`rs2_data`、`rs3_data`、`self_tag`、`exe_subop`、`full_decode` | `self_tag`、`rs1_data`、`rs2_data`、`rs3_data` |
| G3 LSU | `cosim_isq_g3_issue_pld_t` | `rs1_data`、`store_data`、`imm_data`、`self_tag`、`imm_valid`、`mem_funct3`、`rd_is_fp`、`exe_subop` | `self_tag`、`rs1_data`、`store_data`、`imm_data` |

每组都携带 `self_tag` 作为关联键，并带 DUT 侧的 `exe_subop` 作为 AI 选择
运算规则的 canonical key。payload 里的字段比日志打印字段更全（例如 G0 的
`pred_taken`、`pred_target_pc`、`fetch_excp_*`，G3 的 `mem_funct3`、
`rd_is_fp`），日志当前只打印上表“日志打印字段”一列。

旧版列出的 `rsX_ready`、`rsX_wait_tag`、`rs_data_sel_t`、`FU_ready`、
`loser_hold`、`global_flush_late`、`bypass_publish_*` 不在当前 ISQ issue
payload 中，未采集。`st_br_resolve` 只存在于 `be_lsu_issue_pld`，同样未采集
（见 §6.4）。

## 5. 出 FU 之后

### 5.1 节点边界

本节点是 FU 或 LSU 产生 completion/writeback，并在 `CompletionScoreboard`
捕获之前的 payload（`ob_cosim_if.fu_after_*`）。`observe_execution_writebacks()`
在推进 ISA_model 之前先保存 DUT completion payload，再执行模型并抓取参考
结果；`consume_writeback()` 在 commit 时比较。

它与 Level-1 commit result 不同：本节点用于确认计算结果在进入
CompletionScoreboard 之前是否已经正确；若本节点正确而 commit 结果错误，
优先检查 CompletionScoreboard、Buffer 或控制 sideband。

### 5.2 FU completion payload

| 字段 | DUT 来源 | DPI/ISA_model 来源 | 状态 | 比较条件/用途 |
| --- | --- | --- | --- | --- |
| `tag_out` / `exec_tag` | `fu_after_tag[lane]` | `(model_core_id, rob_idx)` 关联键 | 自动对齐 | 指令身份 |
| `result_data` | `fu_after_result[lane]` | `isa_dpi_get_insn_rd_value()` | 自动比较 | 仅 `commit_rd_write_enable == 1` 时比较 |
| `exception_flag` | `fu_after_exception[lane]` | `isa_dpi_has_trap()` | 自动比较 | 每条 writeback 都比较 |
| `exception_cause` | `fu_after_cause[lane]` | `isa_dpi_get_execute_metadata().trap_cause` | 自动比较（条件） | 仅 DUT 与参考 exception 均有效时比较 |
| `exception_tval` | `fu_after_tval[lane]` | `isa_dpi_get_execute_metadata().trap_tval` | 自动比较（条件） | 仅 DUT 与参考 exception 均有效时比较 |
| `mispredict_flag` | `fu_after_mispredict[lane]` | 无对应参考 | DUT-only 只观察 | RTL 与 ISA redirect API 语义不同 |
| `mispredict_target_pc` | `fu_after_target[lane]` | 无对应参考 | DUT-only 只观察 | 同上 |
| `is_mret` / `is_sret` | `fu_after_is_mret / fu_after_is_sret[lane]` | 无对应参考 | DUT-only 只观察 | return recovery 分类 |
| `fpu_fflags` | `fu_after_fflags[lane]` | 无 per-ROB getter | DUT-only 只观察 | Level-1 event 携带 `commit_fflags`，本次 Level-2 不比较 |

`bypass_tag` / `bypass_data` 不在本版 Level-2 payload 中；旧版列出的
bypass 协议关系（`bypass_valid -> exec_valid` 等）不再作为本页内容。

### 5.3 CSR 和 FP completion sideband（CSR_OUT）

CSR completion sideband 由 `ob_cosim_if.csr_out_*` 暴露（`csr_out_valid` 取自
`u_backend.arbG0_csr_sideband_valid`），它就是 **CSR FU 的 completion
sideband**，语义上属于“出 FU 之后”。`observe_csr_events()` 按
`csr_out_exec_tag` 暂存，`consume_csr_events()` 在对应 rob 的 commit/
recovery 时打印。**本通道只观察，不比较。**它与 §5.2 的 `fu_after_*` 是不同
接口、不同来源，不需要同拍。

| 字段 | DUT 来源 | 说明 |
| --- | --- | --- |
| `csr_out_valid` | `u_backend.arbG0_csr_sideband_valid` | CSR 结果 sideband 有效 |
| `csr_out_write_enable` | `u_backend.arbG0_csr_write_enable` | CSR 写使能 |
| `csr_out_addr` | `u_backend.arbG0_csr_addr` | CSR 地址 |
| `csr_out_wdata` | `u_backend.arbG0_csr_wdata` | CSR 写数据 |
| `csr_out_exec_tag` | `u_backend.exec_tag[0]` | 关联键 |

旧版把 `csr_wdata` 排除在 Level 2 之外（理由是当前 ORBE DPI 没有 per-ROB
CSR write payload getter）。本版仍没有该 getter，但 DUT 侧的 `csr_wdata`
现在作为 CSR_OUT 观测字段进入日志；它依旧不做自动比较。若后续要在
FU-after 自动比较该字段，需要新增 per-ROB CSR write metadata ABI。
`fpu_fflags` 同理：当前没有 per-ROB execute fflags getter，本次 Level-2 不
比较。Level-1 event 只携带 `commit_fflags`，`cosim_pkg` 的 `compare_ticket()`
未对其做架构值比较。

### 5.4 recovery、trap 和 CSR 状态上下文（当前未启用）

旧版描述的 `trap_state_write.*`、`trap_cause_in`、`trap_is_interrupt_in`、
`trap_vector`、`interrupt_pending`、`interrupt_cause`、`current_priv`、
`mstatus_tvm/tw/tsr` 以及 CSR state snapshot 表，在当前 Level-2 实现中
**没有采集或比较**：

- 中断恢复路径在当前 `be_agent` 中会直接 fatal（interrupt cause 观测尚未接线）；
- `csr_valid` / `csr_state_*` / `csr_event_*` 在 `rtl_v1_obs_probe` 中被固定为 0，
  即 rtl_v1 的架构 CSR snapshot 比较尚未启用；这只是 probe 侧未驱动，
  `ob_cosim_if` 与 `cosim_pkg` 仍保留该通道（含 X/Z 与重复地址检查）；
- 最终 redirect target/kind 仍由 Level-1 统一观测，本节不重复。

下列 CSR state 列表当前只作为未来冻结 CSR 集合的参考，尚未启用采集：

```text
mstatus, sstatus, mie, mip, sie, sip
mtvec, stvec, mepc, sepc, mcause, scause, mtval, stval
mscratch, sscratch, medeleg, mideleg, satp
fflags, frm, fcsr
mcycle, minstret, cycle, instret
```

## 6. BE-LSU interface

### 6.1 节点边界

本节点包含：

- BE -> LSU issue transaction：`be_lsu_issue_valid`、`lsu_be_issue_ready`、
  `be_lsu_issue_pld`（`be_lsu_issue_pld_t`）；
- LSU -> BE normal/exception completion：`lsu_be_done_valid` /
  `lsu_be_exception_valid` 与 `lsu_be_writeback_pld`（`lsu_be_writeback_pld_t`）；
- LSU -> BE read-side bypass：`lsu_be_bypass_valid` 与
  `lsu_be_bypass_pld`（`lsu_be_bypass_pld_t`）。

issue 由 `sample_lsu_issue()` 采样、`consume_lsu_issue()` 比较；response 由
`observe_lsu_responses()` 采样、`consume_lsu_response()` 只打印。

旧版提到的独立 `lsu_be_done_pld` / `lsu_be_exception_pld` 已合并为单个
`lsu_be_writeback_pld`，由 `lsu_be_done_valid` / `lsu_be_exception_valid`
区分终态；两者不得同拍置位（`observe_lsu_responses()` 会做该项断言）。

### 6.2 BE -> LSU issue payload

DUT payload 字段（`be_lsu_issue_pld_t`）：`tag`、`rs1_data`、`imm_valid`、
`imm_data`、`store_data`、`mem_funct3`、`rd_is_fp`、`exe_subop`、
`st_br_resolve`。注意该 payload 本身不含 `req_property` 和 `vaddr`。

| 字段 | DUT 来源 | DPI/ISA_model 来源 | 状态 | 用途 |
| --- | --- | --- | --- | --- |
| `req_property` | `req_property_from_subop(be_lsu_issue_pld.exe_subop)` | `get_lsu_issue_metadata().req_property` | 自动比较（总是） | load/store/AMO/LR/SC/fence 分类 |
| `exe_subop` | `be_lsu_issue_pld.exe_subop` | `get_lsu_issue_metadata().exe_subop` | 自动比较（总是） | LSU canonical subop |
| `mem_funct3` | `be_lsu_issue_pld.mem_funct3` | `get_lsu_issue_metadata().mem_funct3` | 自动比较（总是） | 访问宽度/符号 |
| `rd_is_fp` | `be_lsu_issue_pld.rd_is_fp` | `get_lsu_issue_metadata().rd_is_fp` | 自动比较（总是） | load 结果目标寄存器类型 |
| `imm_valid` | `be_lsu_issue_pld.imm_valid` | `get_lsu_issue_metadata().imm_valid` | 自动比较（总是） | 地址立即数有效性 |
| `imm_data` | `be_lsu_issue_pld.imm_data` | `get_lsu_issue_metadata().imm_data` | 自动比较（双方 `imm_valid`） | 地址 offset |
| `is_store` | `req_property_from_subop(be_lsu_issue_pld.exe_subop).is_store` | `get_lsu_issue_metadata().is_store` | 自动比较（总是） | plain store 分类 |
| `tag` / `self_tag` | `be_lsu_issue_pld.tag` | `rob_idx` 关联键 | 自动对齐 | 请求身份 |
| `rs1_data` | `be_lsu_issue_pld.rs1_data` | `get_lsu_issue_metadata().rs1_data` | 只观察 | base operand |
| `store_data` | `be_lsu_issue_pld.store_data` | `get_lsu_issue_metadata().rs2_data` | 只观察 | store/AMO 数据 |
| `st_br_resolve` | `be_lsu_issue_pld.st_br_resolve` | 无 per-ROB getter | 接口 payload 中存在，但 `be_agent` 不保存/不打印/不比较 | store 顺序快照 |

`req_property` 必须按 BE-LSU v4 的 bit layout 归一化：

```text
{is_load, is_store, is_amo, is_lr, is_sc, is_fence, is_fence_i}
```

由于 `be_lsu_issue_pld` 不含 `req_property`，BE 侧在比较时用
`or_be_lsu_protocol_pkg::req_property_from_subop()` 从 `exe_subop` 推导；
参考侧由 `get_lsu_issue_metadata().req_property` 给出。RVC 与 32-bit format
必须使用同一编码规则：不能因为 `SUBOP_C_*` 和普通指令功能相同，就直接把
两个编码当作相等。

`vaddr` 不在本版 payload 中，当前 Level-2 也未采集 LSU AGU 的地址。
如需 fault 地址定位，可由 `rs1_data + imm_data` 按同一 64-bit wrap 规则
重构并交给 `isa_dpi_translate_pte()`，但该路径尚未实现。

### 6.3 LSU -> BE terminal/bypass payload

| 字段 | DUT 来源 | 说明 | 状态 |
| --- | --- | --- | --- |
| `lsu_be_done_valid` | LSU done valid | 终态为正常完成 | 只观察 |
| `lsu_be_writeback_pld.tag` | writeback payload | done/exception 共用关联键 | 只观察 |
| `lsu_be_writeback_pld.data` | writeback payload | load/LR/SC/AMO 读侧结果 | 只观察 |
| `lsu_be_exception_valid` | LSU exception valid | 终态为异常完成 | 只观察 |
| `lsu_be_writeback_pld.exception_cause` | writeback payload | load/store/AMO fault cause | 只观察 |
| `lsu_be_writeback_pld.exception_tval` | writeback payload | fault virtual address | 只观察 |
| `lsu_be_bypass_valid` | LSU bypass valid | read-side completion 资格信号 | 只观察 |
| `lsu_be_bypass_pld.tag` / `data` | bypass payload | read-side data 副本 | 只观察 |

本表所有字段均**只观察，不比较**。旧版把 done data 与 exception cause/tval
列为自动比较字段，现按实现改为只观察：结果比较发生在 §5 的 WRITEBACK
节点（`fu_after_result` / `isa_dpi_get_insn_rd_value()`）。

### 6.4 LSU control context

LSU bridge 的 store wakeup、flush 和 issue-ready 控制属于调度/握手逻辑，
不是 ISA architectural payload，不进入本 Level 2 observation packet：
`be_lsu_store_wakeup_valid/tag`、`global_flush_late`、`be_lsu_entry_ready`
（wrapper 中为 `rst_n && !rtl_global_flush`）等都不采集。

`st_br_resolve`：接口 payload 中存在，但 `be_agent` 当前不保存、不打印、
不比较。
