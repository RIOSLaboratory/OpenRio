# LEVEL-1 观测点（commit 边界 + 架构状态）

> **适用范围**：`verification/or_cosim/`（原 `verification/orbe_bt_env/`）。
> **实现位置**：字段在 `tb/interfaces/ob_cosim_if.sv`；事件类型在
> `tb/pkg/orbe_cosim_obs_pkg.sv`（`cosim_commit_event_t` / `cosim_arch_state_event_t`）；
> 采集与发布在 `tb/agents/be/be_agent.sv`；比较在 `tb/pkg/cosim_pkg.sv`。
> **最后核对**：2026-10-19，逐字段对照 `ob_cosim_if.sv`。

Level-1 定义"**哪些信息足以判定一次提交是否正确**"，也是 COSIM 推进参考模型、
对齐提交顺序的核心时机信号。与 Level-2 的区别是：Level-1 覆盖**每个提交事件**，
Level-2 只在采集深度 = 2 时才存在。

## 1. 字段清单

### 1.1 提交组（每个 commit group 一份）

| 字段 | 形态 | 说明 | 参与比较 |
| --- | --- | --- | --- |
| `commit_valid[group]` | ISSUE_NUM bit | 该提交通道本拍有效 | 事件门控 |
| `commit_count` | `clog2(ISSUE_NUM+1)` bit | 本拍提交条数；断言 `commit_count == sum(commit_valid)` | 断言 |
| `commit_pc[group]` | 64 bit | 提交 PC | ✅ 总是 |
| `commit_rob_idx[group]` | ROB_ADDR_W | ROB 索引；与参考模型 `(core, rob_idx)` 对齐的关联键 | 关联键 |
| `commit_result[group]` | 64 bit | 写回数据 | ✅ 当 `commit_rd_write_enable` |
| `commit_rd_idx[group]` | REG_ADDR_W | 目的寄存器号 | ✅ 当 `commit_rd_write_enable` |
| `commit_rd_is_fp[group]` | 1 bit | 目的寄存器是 INT 还是 FP | ✅ 当 `commit_rd_write_enable` |
| `commit_rd_write_enable[group]` | 1 bit | 本条是否写回 | 比较门控 |
| `commit_fflags[group]` | FFLAGS_W bit | 本条 FP 指令对 `fflags` 的影响 | 只观察（尚未实现比较） |

### 1.2 异常组

| 字段 | 形态 | 说明 | 参与比较 |
| --- | --- | --- | --- |
| `commit_exception_valid` | 1 bit | 本拍提交携带异常 | 事件门控 |
| `commit_exception_cause` | EXCP_CAUSE_W | 异常原因 | ✅ 当 `commit_exception_valid` |
| `commit_exception_tval` | 64 bit | 异常附加值 | ✅ 当 `commit_exception_valid` |

### 1.3 恢复组（锚定在提交事件上）

| 字段 | 形态 | 说明 | 参与比较 |
| --- | --- | --- | --- |
| `commit_redirect_valid` | 1 bit | 提交后是否进入恢复流程 | 事件门控 |
| `commit_recovery_kind` | RECOVERY_KIND_W | exception / interrupt / MRET / SRET / FENCE.I / mispredict | ✅ 当 `commit_redirect_valid` |
| `commit_redirect_pc` | 64 bit | 重定向目标 PC | ✅ 当 `commit_redirect_valid` |

### 1.4 恢复值面（独立于提交事件的独立通道）

这一组不在"提交事件"上，而是同一批 `obs_*` 采样得到的**恢复控制值**，
用于在恢复流程本身出问题时定位（此前它们只存在于 `ob_if` 的 identity surface）。

| 字段 | 形态 | 说明 |
| --- | --- | --- |
| `flush_valid` / `flush_tag` | 1 / ROB_ADDR_W | 整机 flush |
| `recovery_valid` | 1 bit | 恢复事件有效 |
| `recovery_kind` | RECOVERY_KIND_W | 恢复类型 |
| `recovery_origin_tag` | ROB_ADDR_W | 引发恢复的 ROB 项 |
| `recovery_squash_tag` | ROB_ADDR_W | 被 squash 的最老 ROB 项 |
| `recovery_redirect_pc` | 64 bit | 恢复目标 PC |

### 1.5 架构状态快照

不是"每提交事件一份"，而是**连续观测**、在该提交点采样的稳定快照。

| 字段 | 形态 | 说明 | 参与比较 |
| --- | --- | --- | --- |
| `int_arf[32]` | 32 × 64 bit | 整数架构寄存器堆 | ✅ 每个提交事件（含 `x0 == 0` 检查） |
| `fp_arf[32]` | 32 × 64 bit | 浮点架构寄存器堆 | ✅ 每个提交事件 |
| `csr_valid` | 1 bit | 整张 CSR 快照有效 | 门控 |
| `csr_state_valid[CSR_STATE_NUM]` | CSR_STATE_NUM bit | 单条目有效 | 门控 |
| `csr_state_addr[CSR_STATE_NUM]` | 12 bit each | CSR 地址（按地址索引，不按固定顺序） | 索引 |
| `csr_state[CSR_STATE_NUM]` | 64 bit each | CSR 值 | ✅ 每个有效条目 |

> 旧文档中的 `int_arf_snapshot` / `fp_arf_snapshot` 已改名为 `int_arf` / `fp_arf`。
> CSR 表是按地址索引的稀疏表，比较集合由每个 ISA case 冻结的 CSR 清单决定，
> 未使用的条目 `csr_state_valid = 0`。

## 2. 比较规则

| 条件 | 比较内容 |
| --- | --- |
| 每个 commit 事件 | `commit_pc`、`int_arf`、`fp_arf` |
| `commit_valid && commit_rd_write_enable` | `commit_rd_is_fp`、`commit_rd_idx`、`commit_result` |
| `commit_exception_valid` | `commit_exception_cause`、`commit_exception_tval` |
| `commit_redirect_valid` | `commit_redirect_pc`、`commit_recovery_kind` |
| `csr_valid` | `csr_state` 中每个 `csr_state_valid == 1` 的条目 |

任何一条不满足，`cosim_pkg` 记录一次 Level-1 mismatch，并计入
`REPORTER_SUMMARY ... error=<n>`。

## 3. 与旧版文档（`orbe_bt_env/docs/Arch/Observation/`）的差异

| 类型 | 内容 |
| --- | --- |
| **改名** | `int_arf_snapshot` → `int_arf`；`fp_arf_snapshot` → `fp_arf` |
| **移除** | `mnemonic`、`commit_is_compressed` 不在 `ob_cosim_if` 上（`mnemonic` 仅由 ISA model 提供并写入日志；RVC 信息在 Level-2 的 `decode_issue_pld.is_compressed`） |
| **新增** | `commit_count`、`commit_rd_write_enable`、`flush_valid/tag`、`recovery_valid/kind/origin_tag/squash_tag/redirect_pc`、`csr_valid` + `csr_state_valid/addr/state` |
| **修正** | `commit_fflags` 为**只观察**，未实现比较（旧文档表述一致，此处明确保留） |
