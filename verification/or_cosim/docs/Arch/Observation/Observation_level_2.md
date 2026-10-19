# LEVEL-2 观测点（流水线内部节点）

> **适用范围**：`verification/or_cosim/`（原 `verification/orbe_bt_env/`）。
> **实现位置**：
> - 接口与字段：`tb/interfaces/ob_cosim_if.sv`
> - payload 类型：`tb/pkg/orbe_cosim_obs_pkg.sv`（`cosim_decode_pld_t`、`cosim_isq_g{0,1,2,3}_issue_pld_t` 等）
> - RTL 侧采集：`tb/top/rtl_v1_obs.svh`（在 `be_tb_top.sv` 的 `ifdef ORBE_DUT_RTL_V1` 作用域内展开）
> - 采样 / 比较 / 日志：`tb/agents/be/be_agent.sv`
> **最后核对**：2026-10-19，对照 `ob_cosim_if.sv` 与 `orbe_cosim_obs_pkg.sv`。

## 1. 目标与统一规则

Level-2 服务于**数据通路还原**和**首个失配点定位**。按流水线节点固定为五类，
另有一组独立的 CSR 单元边界通道：

| 节点 | be_agent 入口 | 生命周期标签 | 是否自动比较 |
| --- | --- | --- | --- |
| FE-BE interface | `observe_fe_be_interface()` | `[FE-BE]` | ❌ 只观察 |
| decode 之后 | `observe_allocations()` → `consume_decode()` | `[DECODE]` | ✅ 部分字段 |
| 进入 FU 之前 | `observe_isq_issue()` → `consume_isq_response()` | `[ISQ0]`~`[ISQ3]` | ❌ 只观察 |
| 出 FU 之后 | `observe_execution_writebacks()` → `consume_writeback()` | `[WRITEBACK]` | ✅ 部分字段 |
| BE-LSU interface | `sample_lsu_issue()` / `consume_lsu_issue()`；`observe_lsu_responses()` / `consume_lsu_response()` | `[BE-LSU]` | issue ✅ 部分 / response ❌ |
| CSR 单元边界 | `observe_csr_events()` → `consume_csr_events()` | `[CSR_IN]` / `[CSR_OUT]` | ❌ 只观察 |

### 1.1 启用条件

- 仅当 `cfg.cosim_enable && cfg.cosim_level >= 2` 时 `level2_enabled()` 为真
  （`be_agent.sv`，默认 `COSIM_LEVEL=1`，合法值 1 或 2）。
- 采集/比较代码位于 `` `ifdef ORBE_DUT_RTL_V1 ``。**所有 RTL DUT kind 都满足这个宏**：
  `rtl_v1`、`rtl_fe`、`rtl_cache`、`rtl_full` 的 `dut_define` 都包含
  `-DORBE_DUT_RTL_V1`，因此**它们都会产生 Level-2 观测**；只有 `agent`
  （无 DUT、纯 agent 闭环）不产生。
- 只有 **decode 之后**、**出 FU 之后（WRITEBACK）** 和 **BE-LSU issue** 存在自动比较字段；
  其余节点均为 **OBSERVATION ONLY, NOT COMPARED**，不参与 COSIM pass/fail。

### 1.2 日志门控（与 Level-1 的重要区别）

- **FE-BE**：每拍被接受的握手（`fe_be_instr_valid[lane] && be_fe_instr_ready[lane]`）
  直接 `diagnostic()` 输出，**与是否失配无关**，也不进入 per-ROB 生命周期。
- **其余所有 Level-2 行**：先暂存在 per-ROB 数组，只有该 rob **最终出现 Level-2 mismatch**
  时才随 `emit_level2_lifecycle()` 在 commit/recovery 时输出；无失配的 rob 只暂存后清理。
- 以上输出全部走 `reporter.diagnostic()`，**不受 `VERBOSITY` 门控**。

### 1.3 失配的传播与终止

Level-2 失配**不会在比较点立刻 fatal**：

```
consume_decode / consume_writeback / consume_lsu_issue  逐字段比较
        ↓
l2_any_mismatch_by_rob[rob_idx]
        ↓
publish_cosim_commit_event() / publish_cosim_recovery_event()  置 level2_mismatch
        ↓
cosim_pkg 累积 pending_level2_mismatch
        ↓
cycle-end：cosim_commit_order_adapter::check_cycle() 末尾
          以 [COSIM][LEVEL2_MISMATCH] fatal 终止
```

若本拍 Level-1 无 mismatch，会先打印
`[COSIM] [<label>] cycle=...; Level-1 fields match; Level-2 mismatch pending`，再 fatal。

### 1.4 字段可用性

- **参与比较的共用字段**：必须满足 `DPI 直接` 或 `DPI 间接`（ISA model 侧能稳定给出同语义参考值）。
- **只观察的 DUT 诊断字段**：只来自 DUT/观测接口，不要求模型有对应 getter，不参与 pass/fail。
- `self_tag` / `rob_idx` / `tag` 是**事件关联键**，用于把 DUT 项与模型 `(core, rob_idx)` 对齐，
  不要求模型产生同名物理 tag。

## 2. FE-BE interface

采样位于 `observe_fe_be_interface()`，使用 `orbe_fe_if`（`orbe_fe_types_pkg`），
每拍检查 2 个 lane。**全部字段只观察**，但**逐拍直出**。

### 2.1 FE → BE payload

只有 `fe_be_instr_valid[lane] && be_fe_instr_ready[lane]` 时记录；
lane 0 为较老指令，lane 1 仅在 lane 0 同拍有效时才可能有效。

| 字段 | 说明 | 状态 |
| --- | --- | --- |
| `pc` | 与 allocation 时送入模型的 pc 同源 | 只观察 |
| `inst_bits` | 原始指令编码 | 只观察 |
| `is_compressed` | RVC 语义 | 只观察 |
| `pred_taken` / `pred_target_pc` | 模型侧不产生同等方向预测 | 只观察 |
| `fetch_excp_vld` | 取指异常边界 | 只观察 |
| `exception_cause` / `exception_tval` | 取指异常 cause / tval | 只观察 |

`valid` / `pc` / `inst_bits` / `is_compressed` 会做 X/Z 检查，出现 X/Z 视为 fatal。

### 2.2 BE → FE redirect payload

| 字段 | 说明 | 状态 |
| --- | --- | --- |
| `be_fe_redirect_valid` | redirect 事件有效 | 只观察 |
| `redirect_pc` | 与 Level-1 `commit_redirect_pc` 同源 | 只观察 |
| `interrupt_valid` | 由 redirect kind 为 INTERRUPT 派生 | 只观察 |
| `trap_valid` | 由 EXCEPTION/MRET/SRET 派生 | 只观察 |

## 3. decode 之后

payload 为 `ob_cosim_if.decode_issue_pld[group]`（`cosim_decode_pld_t`），
在 `observe_allocations()` 随 allocation 采样，在 `consume_decode()` 时比较。

| 字段 | 形态 | DPI 来源 | 状态 |
| --- | --- | --- | --- |
| `pc` | 64 | `isa_dpi_get_insn_pc()` | ✅ 总是 |
| `rs1_idx` / `rs1_is_fp` | 5 / 1 | `get_decode_semantic()` | ✅ `use_rs1` 且 `ref_rs1_idx != 0` |
| `rs2_idx` / `rs2_is_fp` | 5 / 1 | `get_decode_semantic()` | ✅ `use_rs2` 且 `ref_rs2_idx != 0` |
| `rs3_idx` / `rs3_is_fp` | 5 / 1 | `get_decode_semantic()` | ✅ `use_rs3` 且 `ref_rs3_idx != 0` |
| `rd_idx` / `rd_is_fp` | 5 / 1 | `get_insn_metadata()` | ✅ `use_rd` 且 `ref_rd_idx != 0` |
| `is_store` | 1 | `get_decode_semantic().is_store` | ✅ 总是 |
| `imm_valid` | 1 | `get_decode_semantic().imm_valid` | ✅ 当 `use_rs1/2/3`、`use_rd` 或 `is_store` 之一 |
| `imm_data` | 64 | `get_decode_semantic().imm_data` | ✅ 上式且双方 `imm_valid` |
| `exe_subop` | 24 | `get_decode_semantic().exe_subop` | ✅ 总是 |
| `inst_bits` | 32 | 无对应 getter | 只观察 |
| `is_compressed` | 1 | 无对应 getter | 只观察 |
| `use_rs1/2/3` / `use_rd` | 1 each | 无对应 getter | 只观察（同时作为上述比较条件） |
| `mem_funct3` | 3 | 无对应 getter | 只观察 |
| `is_serial` | 1 | 无对应 getter | 只观察 |
| `is_fp_instruction` / `dec_is_fp_opcode` | 1 / 1 | 无对应 getter | 只观察 |
| `is_atomic` | 1 | 无对应 getter | 只观察 |
| `full_decode[16]` `csr_write_intent` | 1 | 无对应 getter | 只观察 |
| `full_decode[15]` `illegal` | 1 | 无对应 getter | 只观察 |
| `full_decode[14:12]` `rm` | 3 | 无对应 getter | 只观察 |
| `full_decode[11:0]` `csr_addr` | 12 | 无对应 getter | 只观察 |

> decode 阶段的 trap（`ib_payload.fetch_excp_*`）只观察，取指异常项不参与语义 decode 比较。
> `inst_type` / mnemonic 由原始编码 + `isa_dpi_decode_mnemonic()`（`ORBE_EXTERNAL_MNEMONICS` 下）
> 间接获得，**不在 `cosim_decode_pld_t` 上**。

## 4. 进入 FU 之前（ISQ issue，只观察）

payload 为 `cosim_isq_g0/g1/g2/g3_issue_pld_t`，随 `observe_isq_issue()` 采样，
按 tag 暂存，**全部只观察**。

| 通道 | 字段 |
| --- | --- |
| `[ISQ0]`（G0） | `rs1_data`、`rs2_data`、`fu_group`、`imm_valid`、`imm_data`、`pc`、`inst_bits`、`is_compressed`、`pred_taken`、`pred_target_pc`、`self_tag`、`exe_subop`、`full_decode`、`fetch_excp_vld`、`fetch_excp_cause`、`fetch_excp_tval` |
| `[ISQ1]`（G1） | `rs1_data`、`rs2_data`、`imm_data`、`self_tag`、`fu_group`、`exe_subop` |
| `[ISQ2]`（G2） | `rs1_data`、`rs2_data`、`rs3_data`、`self_tag`、`exe_subop`、`full_decode` |
| `[ISQ3]`（G3） | `rs1_data`、`store_data`、`imm_data`、`self_tag`、`imm_valid`、`mem_funct3`、`rd_is_fp`、`exe_subop` |

## 5. 出 FU 之后（WRITEBACK）

通道字段（`ob_cosim_if`，按 `LANE_NUM` 声明）：

| 字段 | 形态 | 状态 |
| --- | --- | --- |
| `fu_after_valid[LANE_NUM]` | 1 each | 事件门控 |
| `fu_after_tag[LANE_NUM]` | ROB_ADDR_W each | 关联键 |
| `fu_after_result[LANE_NUM]` | 64 each | ✅ 比较 |
| `fu_after_mispredict[LANE_NUM]` | 1 each | ✅ 比较 |
| `fu_after_target[LANE_NUM]` | 64 each | ✅ 比较 |
| `fu_after_exception[LANE_NUM]` | 1 each | ✅ 比较 |
| `fu_after_cause[LANE_NUM]` | EXCP_CAUSE_W each | ✅ 比较 |
| `fu_after_tval[LANE_NUM]` | 64 each | ✅ 比较 |
| `fu_after_is_mret[LANE_NUM]` | 1 each | 只观察 |
| `fu_after_is_sret[LANE_NUM]` | 1 each | 只观察 |
| `fu_after_fflags[LANE_NUM]` | FFLAGS_W each | 只观察 |

> `LANE_NUM` 是**完成通道数**（G0 ALU/BRU、G1 ALU/MUL、G2 FPU、G3 LSU，共 4），
> 与提交组数 `ISSUE_NUM`（2）是两个维度。

## 6. BE-LSU interface

| 通道 | 字段 | 状态 |
| --- | --- | --- |
| issue | `lsu_be_issue_ready`、`be_lsu_issue_valid`、`be_lsu_issue_pld`（来自 `or_be_lsu_protocol_pkg`） | ✅ 部分字段比较 |
| done | `lsu_be_done_valid`、`lsu_be_done_pld` | 只观察 |
| exception | `lsu_be_exception_valid`、`lsu_be_exception_pld` | 只观察 |
| bypass | `lsu_be_bypass_valid`、`lsu_be_bypass_pld` | 只观察 |

## 7. CSR 单元边界（独立通道，只观察）

`CSR_IN` 是 CSR FU 的 issue/accept 边界，`CSR_OUT` 是 CSR FU 的 completion sideband。
二者是 `ob_cosim_if` 上独立于 decode payload 和 `fu_after_*` 的观测通道，
按 tag 暂存，统一在 commit/recovery 时以 `[CSR_IN]` / `[CSR_OUT]` 输出，
**不要求与 decode payload 或 `fu_after_*` 同拍**。

| 通道 | 字段 |
| --- | --- |
| `[CSR_IN]` | `csr_in_valid`、`csr_in_tag`、`csr_in_addr`、`csr_in_rdata`、`csr_in_current_priv`、`csr_in_fs_enabled` |
| `[CSR_OUT]` | `csr_out_valid`、`csr_out_write_enable`、`csr_out_addr`、`csr_out_wdata`、`csr_out_exec_tag` |

## 8. 与旧版文档（`orbe_bt_env/docs/Arch/Observation/`）的差异

| 类型 | 内容 |
| --- | --- |
| **修正** | 旧文档称"只有 rtl_v1 产生 Level-2 观测" —— 实际 `rtl_full`/`rtl_fe`/`rtl_cache` 的 `dut_define` 都含 `-DORBE_DUT_RTL_V1`，**都产生**；仅 `agent` 不产生 |
| **修正** | 文件路径：`rtl_v1_obs_probe.sv` / `rtl_v1_wrapper.sv` 已不存在，现为 `tb/top/rtl_v1_obs.svh` |
| **补充** | `fu_after_*` 按 `LANE_NUM`（完成通道数）声明，不是 `ISSUE_NUM`（提交组数） |
| **补充** | 明确 `reporter.diagnostic()` 不受 `VERBOSITY` 门控；`VERBOSITY` 只影响 `print_tb` 的常规打印 |
| **保留** | 三大自动比较点（decode / writeback / LSU issue）与其余节点的"只观察"划分 |
