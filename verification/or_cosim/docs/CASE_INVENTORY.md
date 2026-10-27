# 用例清单与范围（CASE INVENTORY）

> **目的**：给出"我们到底有多少 case、跑了多少、还剩多少"的唯一真相来源，避免再次出现
> "以为 216 就是全部"的错觉。
> **最后更新**：2026-10-20
> **维护规则**：本文是**基线**，不是上限。后续新增 case 一律追加到对应表并注明来源与 scope，
> 不允许只加到回归脚本而不同步本表。

---

## 1. 范围（Scope）定义

以 RTL 实测配置为准（`src/core/be_rtl_v1/pkg/or_be_config_pkg.sv`）：

| 项 | 状态 | 依据 |
| --- | --- | --- |
| I / M | ✅ | 基础 |
| A | ✅ | `ENABLE_A = 1` |
| F / D | ✅ | `ENABLE_FD = 1` |
| C | ✅ | `ENABLE_C = 1` |
| U | ✅ | `ENABLE_U = 1` |
| S | ✅ | `ENABLE_S = 1` |
| Machine-mode CSR / trap | ✅ | `mstatus` / `mtvec` / `mepc` 等已确认 |
| **PMP** | ❌ | `pmpcfg0`/`pmpaddr0` 地址存在但读返回 `0`（桩实现） |
| **MMU / Sv\*** | ❌ | 无地址转换 |
| **Vector** | ❌ | 未实现 |
| Zba / Zbb / Zbs / Zbc / Zbkb / Zbkx / Zacas / Zabha | ❌ | 未实现 |
| Zfa / Zfh / Zfhmin / Zmmul 之外的新 FP 扩展 | ❌ | 未实现（Zmmul 属 M 子集，视为 ✅） |
| Zicbom / Zicboz / Zicbop / Zicond / Zimop / Zcmop | ❌ | 未实现 |
| Svstc / Smstateen / Sscofpmf / Ssnpm / Sscounterenw / Svinval / Svpbmt / Svnapot / Svade | ❌ | 未实现 |

---

## 2. 总览

| 来源 | 总数 | ✅ 在范围内 | ❌ 范围外 | ❓ 待定 | 已跑 | 通过 |
| --- | --- | --- | --- | --- | --- | --- |
| **riscv-tests**（`isa_case/`） | 409 | 239 | 110 | 60 | 239 | 232 |
| **ACT rv64i** | 516 | 365 | 151 | 0 | 516 | 332 |
| **ACT priv** | 361 | 91 | 270 | 0 | 0 | — |
| **合计** | **1286** | **695** | **531** | **60** | **755** | — |

> ACT rv64i 的 332 PASS 是**全 516 条**跑出来的结果（含 151 条范围外用例），
> 所以"范围内 365 条"的真实通过数需要重跑后按范围统计。

> **Embench-IoT 19 条**不在上表统计内：清单见 `cfg/cases/cases_embench.list`，
> ELF 在 `embench_elf/bin/embench/orbe-baremetal/`，判定复用 `is_good=1`
> （ELF 自校验结果经 HTIF exit code 上报）。

---

## 3. riscv-tests（`isa_case/`，409 条）

| 目录 | 数量 | 判定 | 说明 |
| --- | --- | --- | --- |
| `rv64ui` | 104 | ✅ | I，user mode |
| `rv64um` | 26 | ✅ | M |
| `rv64ua` | 38 | ✅ | A |
| `rv64uf` | 22 | ✅ | F |
| `rv64ud` | 24 | ✅ | D |
| `rv64uc` | 2 | ✅ | C |
| `rv64mi` | 16 | ✅ | M 模式：CSR / 异常 / 断点 / 非对齐 / Zicntr |
| `rv64si` | 7 | ✅ | S 模式：CSR / dirty / icache-alias / ma_fetch / sbreak / scall / wfi |
| `rv64model` | 60 | ❓ **待定（本轮不纳入）** | 模型相关用例；57 条向量/Zvfh，3 条依赖 PMP/mcountinhibit |
| `rv64uzba` | 16 | ❌ | Zba 未实现 |
| `rv64uzbb` | 48 | ❌ | Zbb 未实现 |
| `rv64uzbc` | 6 | ❌ | Zbc 未实现 |
| `rv64uzbs` | 16 | ❌ | Zbs 未实现 |
| `rv64uzfh` | 22 | ❌ | Zfh 未实现 |
| `rv64mzicbo` | 1 | ❌ | Zicbo 未实现 |
| `rv64ssvnapot` | 1 | ❌ | Svnapot 未实现 |

**已在回归中**：`rv64u*` 216 + `rv64mi`/`rv64si` 23 = **239**
**回归清单**：`or_cosim/cfg/cases/cases_239.list`（首行 `# expected=239`；
`tools/regress.sh` 省略第 4 个参数时默认使用）
**当前结果**：216/216 PASS；MI+SI **16 PASS / 7 FAIL**（详见 §7）

> 本轮回归口径固定为 **239**（不含 `rv64model`）。`rv64model` 60 条中 57 条为
> 向量/Zvfh，3 条依赖 PMP/mcountinhibit，暂不纳入。

---

## 4. ACT `rv64i`（516 条）

### 4.1 ✅ 在范围内（365）

| 组 | 数量 | 理由 |
| --- | --- | --- |
| `I` | 51 | 基础 |
| `M` | 13 | 基础 |
| `F` | 84 | `ENABLE_FD` |
| `D` | 116 | `ENABLE_FD` |
| `Zaamo` | 18 | A |
| `Zalrsc` | 4 | A |
| `Zca` | 32 | C |
| `Zcd` | 4 | C |
| `Zicsr` | 6 | CSR |
| `Zifencei` | 1 | `fence.i` |
| `Zicntr` | 2 | 计数器 |
| `Zmmul` | 5 | M 子集 |
| `Misalign` | 8 | 非对齐访问（`rv64mi` 非对齐用例已通过，佐证支持） |
| `MisalignD` / `MisalignF` / `MisalignZca` | 12 | 同上 |
| `Zihintntl` / `ZihintntlZca` / `Zihintpause` | 9 | 提示类指令，应为 NOP |

### 4.2 ❌ 范围外（151）

| 组 | 数量 | 原因 |
| --- | --- | --- |
| `Zimop` | 40 | 未实现 |
| `Zbb` | 24 | 未实现 |
| `ZfaD` / `ZfaF` | 26 | 未实现 |
| `Zfhmin` | 14 | 未实现 |
| `Zba` / `Zbs` | 16 | 未实现 |
| `Zcmop` | 8 | 未实现 |
| `Zcb` / `ZcbZbb` / `ZcbZba` / `ZcbM` | 12 | 依赖 Zb* |
| `Zicbom` / `Zicboz` / `Zicbop` | 7 | 未实现 |
| `Zicond` | 2 | 未实现 |
| `Zihpm` | 2 | HPM 未实现 |

### 4.3 未进入构建的源码用例（约 44 + 2181 vector）

`tests/rv64i` 源码里还有但**没有被构建进 877**的组：

| 组 | 数量 | 判定 |
| --- | --- | --- |
| `Vf16/Vf32/Vf64/Vls*/Vx*`（Vector） | **2181** | ❌ 未实现 |
| `Zbc` | 3 | ❌ 未实现 |
| `Zbkb` / `Zbkc` / `Zbkx` | 18 | ❌ 未实现 |
| `Zacas` / `ZacasZabha` | 5 | ❌ 未实现 |
| `Zabha` | 18 | ❌ 未实现 |

> 结论：**排除是有依据的**，不是漏选。但这 44 条应写进"范围外清单"以便追溯。

---

## 5. ACT `priv`（361 条）

### 5.1 ✅ 在范围内（91）

| 组 | 数量 | 理由 |
| --- | --- | --- |
| `S` / `U` / `UF` | 17 | `ENABLE_S` / `ENABLE_U` |
| `Sm` / `SmF` | 28 | M 模式基础 + M 模式 FP |
| `ExceptionsSm` / `ExceptionsS` / `ExceptionsU` / `ExceptionsF` / `ExceptionsZc` / `ExceptionsZaamo` / `ExceptionsZalrsc` | 10 | 异常处理属 MCU 核心 |
| `InterruptsSm` / `InterruptsS` | 32 | 中断属 MCU 核心 |
| `ZicsrF` / `ZicntrU` / `ZicntrSm` / `ZicntrS` | 4 | CSR / 计数器 |

### 5.2 ❌ 范围外（270）

| 组 | 数量 | 原因 |
| --- | --- | --- |
| `Sv` / `SvSm` / `SvPMP` / `SvPMPZicbo` / `SvZicbo` / `Svpbmt` / `Svnapot` / `Svade` / `Svbare` / `SvbareSm` / `Svinval` / `SvinvalSm` | 143 | 无 MMU |
| `PMPSm` / `PMPS` / `PMPU` / `PMPZca` / `PMPZicbo` / `PMPZalrsc` / `PMPZaamo` / `PMPF` | 83 | PMP 桩实现（读 0） |
| `Ssnpm` / `SsnpmSm` / `Ssstateen` / `Sscounterenw` / `Smstateen` / `Sstc` / `SstcSm` | 34 | 未实现 |
| `ZawrsS` / `ZawrsSm` / `ZawrsU` | 3 | 未实现 |
| `ExceptionsSvSm` / `ExceptionsSvZaamoSm` / `ExceptionsSvZalrscSm` / `ExceptionsZicboS` / `ExceptionsZicboSm` / `ExceptionsZicboU` | 7 | 依赖 Sv / Zicbo |

> ⚠️ **这 270 条目前连构建都过不了**（依赖未实现的 CSR）。即使想跑，也需要先解决
> `rvtest_config.h` 的 CSR 门控与链接脚本。

---

## 6. 两种推进策略

| | **策略 A：清单制** | **策略 B：减法制** |
| --- | --- | --- |
| 做法 | 先按 scope 判定出"应跑集"（本文 §2 的 695 条），只跑这些 | 从总量出发，踢掉明显不可能的（Vector 2181 等），**能跑尽跑**，再逐步减法 |
| 优点 | 目标清晰，分母固定，进度可量化 | 不用先做完整判定，能更早暴露真实 bug |
| 缺点 | 判定可能出错（比如 Zicbo 是否该支持） | 分母不确定，"还剩多少"说不清 |
| 适用 | 验收/汇报 | 早期摸底 |

**推荐：以 A 为底、用 B 推进。**

1. 用本文的 695 条作为**分母**（可随 scope 变更调整）；
2. 对 695 条里**当前跑不了的**（如 91 条 priv 编译不过）先挂起，不阻塞；
3. 每跑通一批就把它们从"待跑"移到"已跑"，分母不动；
4. 范围外 531 条**保留在表里**，随时可因 scope 变化重新纳入。

---

## 7. 当前状态与缺口

| 项 | 状态 |
| --- | --- |
| riscv-tests 216 | ✅ 216/216 PASS |
| riscv-tests MI/SI 23 | ⚠️ **19 PASS / 4 FAIL**：`rv64mi-p-{access,breakpoint,csr}` + `rv64si-p-dirty` |
| **riscv-tests 239（合计）** | ⚠️ **235 PASS / 4 FAIL**；清单 `cfg/cases/cases_239.list` |
| Embench 19 | ❓ 脚本与清单 `cfg/cases/cases_embench.list` 已就绪，待内网首跑 |
| ACT rv64i 516 | ✅ 已跑：332 PASS / 184 FAIL（142 未实现 + 18 FP fflags + 24 伪失败） |
| ACT priv 91（范围内） | ❌ **0 条跑过**（构建不过） |
| riscv-tests `rv64model` 60 | ❓ 未判定 |
| 内网 BETA 压力测试 | ❓ 清单未取得 |

### 已知的真实缺口（应支持但未通过）

| # | 用例组 | 现象 | 归属 |
| --- | --- | --- | --- |
| 1 | ACT F/D `fmadd/fmsub/fnmsub/fdiv`（18 条） | `CSRRS` 读 fflags 时标志位不对（结果对） | RTL（FPU fflags） |
| 2 | MI/SI 4 条 | 逐条根因见下表 | RTL / 范围外 |

### MI/SI 4 条失败根因（2026-10-26 定位，2026-10-27 更新）

| 用例 | 首个失配点 | 根因 | 归属 |
| --- | --- | --- | --- |
| `rv64mi-p-csr` | 0x80000350 `fsw`（`mstatus.FS=Off`）commit 后 | 模型也判 ILLEGAL（双方一致），但 DUT 此后**不产生任何 recovery/redirect**；20 cycle 后出现 `commit for unallocated rob=0`，判为异常恢复路径挂死 | RTL（需波形） |
| `rv64mi-p-access` | jalr → 0x8000_0000_8000_01f0 | `or_fe_pkg::VA_W=39`，tb 也按 `VA_W-1:0` 截 `redirect_pc`，目标被截成 0x8000_01f0 并取到 `fail` 的 FENCE；模型正确报 cause=1。注：**数据侧的通路是有的**——`or_cache_pkg::pma_ok()` 对 6 个 PMA 区域做区间判断，越界 → `lk_pma_fault` → `or_cache_top.sv:315` 抛 `CAUSE_LD_ACCESS(5)`，所以 test 3（`lb` 非法地址）本应能过；缺的是 FE 侧：PC 只有 39 bit，且 `fe_mem_vif` 没有 `l2_resp_err` 输入（D 侧 `dc_mem_vif` 有），所以取指侧无法产生 access fault | RTL（FE PC 宽度 + 取指错误通路） |
| `rv64mi-p-breakpoint` | 0x800001b4 `csrs tcontrol,8` | 测试的 `mtvec_handler` 要求 `mcause==3`（断点），即必须有 Sdtrig 触发器；RTL 无 0x7a0-0x7a5，模型只有 `CsrModule.cpp:725` 的「pseudo trigger slot」 | 范围外（无 Sdtrig） |
| `rv64si-p-dirty` | 0x800001d8 `sw` → 0x2008 | **RTL 未实现 `mstatus.MPRV`**（`system_instruction_handler` 无 `BIT_MPRV`/`mstatus_mprv_q`，读回恒 0）。测试在 M 态置 MPRV=1/MPP=S 后做 store，DUT 仍按 M 判 → `dc_flush_ctrl.sv:19` 的 `vm_en=0` → DTLB 旁路（`pa64=lk_va`）→ 物理 0x2008 直接落地、不 fault；模型按 spec 报 cause=0xf。日志实证：整个运行 `[DC_RTL][PTW]` 出现 0 次 | RTL（MPRV）+ TB（PTW 的 priv 参数） |

### `rv64si-p-dirty` 修复清单（MPRV，2026-10-26 定位）

D 侧 MMU 前端是齐全的：`cache_rtl_v1/dc_dtlb.sv`（DTLB + TMQ + PTW 口）、`or_cache_top.sv:37-46`
把 PTW 口引出、`be_tb_top.sv:595-598` 把 `satp/priv/sum/mxr` 从 BE 真接进来、tb 的
`cache_agent_dside_rtl.svh:dside_ptw_query()` 用 `isa_dpi_translate_pte()` 让**模型**走表，
失败经 `dc_missq.sv:apply_fault()` → `op.pre_cause` → `or_cache_top.sv:315` 抛异常。缺的只有 MPRV：

1. `be_rtl_v1/p4/system_instruction_handler.sv`：新增 `BIT_MPRV=17` + `mstatus_mprv_q`（写解码 `ADDR_MSTATUS` 段、读视图 `mstatus_view`、reset 三处），派生
   `data_eff_priv = (mprv_q && priv==M) ? mstatus_mpp_q : current_priv_q`
2. `tb/top/be_tb_top.sv:596`：`dc_priv` 改接 `data_eff_priv`（`dc_flush_ctrl` 的 `ctx` 含 priv，
   顺带覆盖 MPRV/MPP 变化的 TLB 失效）
3. `tb/agents/cache/cache_agent_dside_rtl.svh:504`：PTW 的 `priv` 参数改用 `dc_priv`，
   不要用 `isa_dpi_get_priv()`（`MMU::translate` 原样使用传入 priv，传 M 会让 U 页面一律通过）
4. 验收：`[DC_RTL][PTW] vaddr=0x2008 ... rcause=0 wcause=15` 出现；`csrr mstatus` 读回 bit17=1

### 已修复（2026-10-27）：`rv64mi-p-illegal`（纯验证侧，三处递进）

三处阻塞是**依次暴露**的，不是三个独立 bug。修掉一处，下一处才浮现：

| # | 阻塞点 | 症状 | 修复 |
| --- | --- | --- | --- |
| 1 | `fe_agent.sv` 把 `half0 == 0x0000` 判成 `FE_MODE_EOF` | `[FE_EQUIV] ... fe_agent: pc=0xffffffff7ffffe5b`（= `~pc` 哨兵） | 删除 EOF 状态：`0x0000` 是合法的 16 位非法指令编码；真正的结束由模型 exit 表示（`run()` 已先判） |
| 2 | `be_agent.sv` 对 `ORBE_RECOVERY_INTERRUPT` 直接 fatal | `[BE][RECOVERY_INTERRUPT] unsupported until ... wired` | 调**既有**的 `isa_dpi_take_interrupt()` 让共享模型取同一中断并核对向量；再 `isa_dpi_flush_all()` 清投机 ROB（模型的 `takeInterrupt` 只改 CSR/PC，不动 ROB） |
| 3 | cosim 黄金实例（`isa_cosim_dpi_*`，独立 C++ handle）无中断入口 | `[COSIM][PC_MISMATCH] rtl_pc=0x80000404 ref_pc=0x800001f4` | 新增 `isa_cosim_dpi_take_interrupt()` + `cosim_reference_backend::take_interrupt()`；中断**不消耗 step**；`be_agent` 补发 `publish_cosim_recovery_event()` |

- `isa_model/` **零改动**：转发的就是既有的 `FuncMultiCore::takeInterrupt()`。
- 顺带确认的契约：RVC 的 `inst_bits` 仍为 `{16'h0000, half}`（`or_fe_pkg.sv:117` 明文写 "upper bits zeroed"），RTL 与 fe_agent 两侧一致。
- 验证：单例 `is_good=1`、`FE_EQUIV 374/0`、`CACHE_EQUIV 12/0`、`error=fatal=0`；239 条 **235 PASS / 4 FAIL**。

### 已修复（2026-10-26）

- `dpi/rivai_0x80000000_1core_rom.yaml`：`isa_string` 补 `s`/`u`（`rv64imafdcsu_zcb_zifencei_zicsr`）。
  模型 `genMisaValue()` 由 isa_string 组 misa，缺 su 时参考 misa 少 S/U 位（0x8000_0000_0000_112D），
  与 RTL 的 0x8000_0000_0014_112D 不符 → `rv64mi-p-csr/-mcsr/-ma_fetch` 的 `csrr rd, misa` 全部失配。
  修复后 `-mcsr`、`-ma_fetch` 全绿；239 条回归 **234 PASS / 5 FAIL**（当时的时点），216 条 rv64u* 无回归。

---

## 8. 后续动作

1. **把本文作为口径**：以后任何"跑全了吗"的问题，先查这张表。
2. **ACT rv64i 365 条**：按范围重跑一次，得到"范围内通过数"（当前 332 是含范围外的）。
3. **ACT priv 91 条**：评估构建可行性（CSR 门控 + 链接），这是下一个大缺口。
4. **MI/SI 7 条 + ACT 18 条 fflags**：并成一张缺陷跟踪表，用波形定位。
5. **`rv64model` 60 条**：本轮口径固定 239，不纳入；后续如纳入，需先明确向量/Zvfh 与 PMP/mcountinhibit 的支持范围。
