# perf_eval 方法文档

从 caselist 的预测，到 RTL 实测，再到**人工判定**的方法。

---

## 0. Overview

把 caselist 里**预测**的每一条依赖时序，翻译成一段**汇编**，编成 ELF 喂给
RTL，逐拍抽出这条指令的**派发 / 发射 / 提交 cycle**，算出实测 `delta`，与预测对表，
**最后由人判定 RTL 是否符合预期**。

```text
caselist(.md)  ──gen_cases──▶  .S  ──gcc+link.ld──▶  .elf
                                                      │
                                          verilator_cosim.sh (rtl_full)
                                                      │
                                              sim.log (逐拍事件)
                                                      │
                                                 compare.py
                                                      │
                                              delta 对照表
                                                      │
                                              ★ 人工判定 ★
```

## 1. 适用范围与前提

- 目标是 BE 微架构的**时序符合性**（timing conformance），不是通用跑分（benchmark）。
- **基准本身还是 draft**：两份 caselist 都写着
  `Normative timing sources: pending promotion to spec/or-be/`。
  因此本方法的结论形式是 **"RTL vs draft 预测"**，不是 "RTL vs 已冻结规范"。
- **基准 DUT 用 `rtl_full`**（BE RTL + OR_FE RTL + OR_Cache RTL，不含任何 agent）。理由见 §5。
- **必须人工判定**，不是流程缺陷：caselist 的 `behavior` 标签描述的是微架构机制
  （bypass 捕获 / commit CDB 捕获 / ARF 读取），脚本无法可靠推断；口径差异和
  不符项的归因都需要人来判断。

## 2. 核心概念

### 2.1 delta（唯一的量化指标）

```text
delta = dependent first P1/DSP attempt cycle - producer first P1/DSP attempt cycle
```

`P1/DSP` 指后端派发级：一条指令第一次尝试进入派发的那一拍。
**注意这是"尝试"，不是"被接受"** —— 见 §9.1。

### 2.2 behavior 标签（判定机制）

| 标签 | 含义 |
|---|---|
| `overlay` | `delta_0`：同一 bundle 内 slot0 生产者 → slot1 依赖者在 rename 阶段叠加 |
| `wait_for_p3` | 依赖者早于生产者 P3 派发，携带 `wait_tag`，在 ISQ 里驻留等待 |
| `p3_capture` | 依赖者首次 P1 尝试恰好命中生产者 P3 Bypass，捕获 `bypass_data` |
| `p4_capture` | 依赖者首次 P1 尝试恰好命中生产者 P4 Commit CDB，捕获 `commit_data` |
| `arf_read` | 生产者已提交，依赖者在 P1 直接读 ARF |

### 2.3 各生产者的边界 delta（判定基准）

单操作数 caselist：

数值以 `latency_bench/Latency_Report.md` 的**实测**为准（OpenRio `589ca8f`，`--dut-kind rtl_full`），
程序里的唯一副本是 `timing/latency_table.py`：

| Producer | Producer latency | P3 delta | P4 delta | ARF boundary delta | 枚举 delta |
|---|---:|---:|---:|---:|---|
| ALU | 1 | 2 | 3 | 4 | 0..4 |
| MUL | 3 | 4 | 5 | 6 | 0..6 |
| DIV | **4** | **5** | **6** | **7** | **0..7** |
| LOAD | **3** | **4** | **5** | **6** | **0..6** |
| JALR | — | — | — | — | **不枚举**（不能作 producer，见 caselist 顶部） |

> **JALR 不进入本 caselist 的枚举。** 原因不是排布技巧，而是结构性的：`p4/flush_model.sv`
> 注明 retire 决定属于 CompletionScoreboard，JALR 的控制决定在**退休时**才通过
> `global_flush_late` 生效，而该信号门控了 tag mapping 的 alloc 与各 ISQ group 的
> `issue_valid` / `bypass_capture`。因此落在链路值可见窗口内的消费者必须在 JALR 退休前派发，
> 而那样派发的指令全是投机，会被冲刷**作废**——"落在窗口内"与"能存活"互斥。
> 实测可达 delta ≥ 6，而 JALR 的阶梯是 `0..4`，故一条都不可实现。复现见
> `timing/tools/jalr_producer_commit.py`。JALR 自身的两个口径（`link 值` = 1、
> `redirect 就绪` = 2）不受影响，仍留在报告里。

两操作数 caselist：

| Producer | P3 delta | P4 delta | ARF boundary delta |
|---|---:|---:|---:|
| ALU/BRU result | 2 | 3 | 4 |
| MUL result | 4 | 5 | 6 |
| DIV/REM result | **5** | **6** | **7** |
| LOAD hit result | **4** | **5** | **6** |

### 2.4 规模

| caselist | 内容 |
|---|---|
| `INT_single_operand_dependency_caselist_v1.md` | **27 条**：ALU 5 + MUL 7 + DIV 8 + LOAD 7 |
| `INT_two_operands_dependency_caselist.md` | **30 条**：P1 MUX 17 + P2 MUX 7 + same-RD fanout 6 |

合计 57 条。其中 25 条是手工标定并按实测配方固化在 `timing/calibrated_cases/`，
由 `timing/install_calibrated.py` 装入跑批目录；`timing/re_audit.py` 会用权威口径把它们
逐条重验。

## 3. 产物与仓库边界

| 内容 | 位置 | 是否提交 |
|---|---|---|
| caselist（预测基准）、K-map、时序图 | `openrios:/work/or-be-draft/timing/` | 是（在其自己仓库） |
| 工具、模板、本方法文档 | `OpenRio:verification/orbe_bt_env/perf_eval/` | 是 |
| 生成的 `.S` / `.elf` / `.dump` / `sim.log` | `/work/.../model/perf_eval_work/`（不在 OpenRio/openrios 内，见 README §2） | **否** |
| 比对结果 `.md` | 同上 `results/` | **否** |

**caselist 一律按路径引用，不做拷贝** —— 它是 draft，拷贝会产生第二份会分叉的"预期"。

## 4. 前置条件

| 依赖 | 实测版本 / 位置 |
|---|---|
| Verilator | 5.050（2026-07-01, rev v5.050） |
| RISC-V GCC | `/opt/riscv/bin/riscv64-unknown-elf-gcc`（GCC 11.1.0） |
| ISA model | `ISA_MODEL_ROOT`，或 `OpenRio/dpi/` 下 vendored 版本 |
| ripgrep | `verilator_cosim.sh` 扫描日志用 |

```bash
export PATH=/opt/riscv/bin:$PATH        # 或显式设 OBJDUMP=
export ISA_MODEL_ROOT=<isa model 目录>
```

## 5. 基准 DUT：`rtl_full`（FE + BE + Cache 完全体）

caselist 的预测量是 **BE 内部量**（P1 派发、P3 bypass、P4 commit CDB、ARF 读取），但被测对象是
**整机时序**：取指节奏、redirect、ICache/BTB、以及 LOAD 的真实 Cache 行为都会影响这些拍号。

**所以基准 DUT 是 `rtl_full`**：`cfg/filelist/rtl_full.f` = `rtl_fe.f` + `cache_rtl.f`，
即 BE RTL + OR_FE RTL + OR_Cache RTL，**不含任何 agent**。一批 case 用完全体一次跑完，
**中途不换 DUT**（§5.1 的历史理由见下）。

`agent` / `rtl_v1` / `rtl_fe` / `rtl_cache` 保留为**隔离与诊断**用途 —— 例如把某个现象单独
归因到 FE 或 Cache —— **不作为符合性判定的依据**。

### 5.1 历史：曾以 `rtl_v1` 为主 DUT

早期把主 DUT 定为 `rtl_v1`（BE RTL + FE agent + cache agent），理由是"隔离噪声、可控、
可复现"；只把 latency 标定划给 `rtl_full`，因为 `cache_agent` 是**行为模型**，
拿它测 LOAD 延迟是**循环论证**。

**该划分已废弃**，统一为 `rtl_full`。原因：

1. 判定的对象是**交付的整机**，不是 BE 的孤立行为 —— 用 agent 顶替 FE 或 Cache，
   等于把被测对象的一部分换成了模型；
2. agent 顶替会**改变结论**，不只是噪声：`fe_agent` 硬编码 `pred_taken = 0`，
   于是**每一个 taken 的控制转移都必然误预测并触发 flush**（JALR 一族因此完全测不到）；
   真 FE 有 `l1btb.sv`（其头注释自称 "the only branch predictor"）会给出 taken/目标预测；
3. LOAD 的 P3 发布时刻由 Cache 决定，agent 与真 Cache 不同，故 LOAD 的 delta 也必须在
   完全体上判定。

| 活动 | DUT |
|---|---|
| delta / 机制**符合性判定** | **`rtl_full`** |
| latency **标定** | **`rtl_full`** |
| 隔离诊断（把现象归因到 FE / Cache / BE） | `rtl_v1` / `rtl_fe` / `rtl_cache` / `agent` |

> `cache_agent` 只保证 load data 功能正确返回，**不是性能依据**；`fe_agent` 不做任何预测。
> 两者都不得作为判定依据。

## 6. 流程总览

| 步骤 | 动作 | 产物 | 工具 |
|---|---|---|---|
| 0 | 钉住溯源 | `manifest.yaml` | 手工 |
| 1 | caselist `.md` → `.S` | `cases/<case_id>_k<k>.S` | `gen_cases.py` |
| 2 | `.S` → `.elf` | `elf/<case_id>_k<k>.elf` | `run_perf.sh compile` |
| 3 | 跑 RTL | `sim/verilator_<TAG>/log/rtl_full/<name>_<seed>/sim.log` | `verilator_cosim.sh` |
| 4 | 逐拍抽取事件 | `results/<case_id>.events.tsv` | `compare.py extract` |
| 5 | 算 delta、对表 | `results/<case_id>.md` | `compare.py report` |
| 6 | **人工判定** | 结论与归因 | 人 |

## 7. 步骤详解

### Step 0 — 钉住溯源

测量前更新 `perf_eval_work/manifest.yaml`：

- OpenRio（design）的 branch + commit
- openrios（caselist）的 branch + commit
- 工具链版本

**不更新 SHA 的测量结果无法追溯**，等同于无效数据。

### Step 1 — caselist `.md` → `.S`

#### 7.1.1 关键认识：delta 不能"直接写"，只能"扫描着走"

caselist 把 `delta` 写成 case 的属性（如 `ALU_to_ALU_delta_2`），但 **`delta` 是
涌现量，不是可控旋钮**。你无法在汇编里写 "让依赖者在第 2 拍派发"。

可控的旋钮只有一个：**生产者与依赖者之间插入多少条独立指令**。

而派发是**按序、每拍最多 2 条**的，所以插 `k` 条独立 filler，依赖者的 P1 大约前进
`ceil(k/2)` 拍 —— 具体映射还受 G0/G1 路由和 ISQ 占用影响。

因此正确做法不是"强行构造 delta_n"，而是：

> **对每个 producer 家族，扫一遍 filler 条数 k，把每条 case 实测到的
> (真实 delta, 观测到的 behavior) 记录下来，形成 `delta → behavior` 映射，
> 再与 caselist 预测的 `delta → behavior` 表对照。**

这样既绕开了"无法直接控制 delta"，也自动拿到了 caselist 枚举的整个 delta 区间。

#### 7.1.2 生成物形态

```text
cases/
├── ALU_to_ALU_k0.S        # producer; consumer            -> 期望测得 delta_0 overlay
├── ALU_to_ALU_k2.S        # producer; 2 条 filler; consumer
├── ALU_to_ALU_k4.S
└── ...
```

每个家族一条 `k` 扫描链；`k` 的步长和上限由该家族的枚举 delta 上限决定
（如 ALU 家族 0..4，DIV 家族 0..11）。

#### 7.1.3 两操作数族的特殊约定

两操作数 caselist 直接给了 **Timing Setup** 列，例如：

> `INT2_G1P3_G0P3`：**Issue `mul` two cycles before `add`** so G1 and G0 results
> publish at P3 together.

这类 case 需要**同时控制两个生产者的相对 P1 偏移**，生成器必须支持对 producer A
和 producer B 分别设置 filler 数，而不是单一 `k`。

#### 7.1.4 寄存器与退出约定

见 `templates/case.S.in` 的头部注释：

| 用途 | 寄存器 |
|---|---|
| 输入（此处设定，case 不得改写） | `x1..x4` |
| producer / 临时 | `x5..x12` |
| **退出码保留，case 不得触碰** | `x28`, `x29`, `x31` |

- 用 `.option norvc`：每条指令 4 字节，PC 与指令序号 1:1，相邻两条可同 bundle。
- 退出：向 `tohost` 写 1（HTIF pass 约定），`tohost` 由 `templates/link.ld` 定义。
- **每条 case 必须能跑到 pass 并 `wfi` 自旋**，否则 ISA model 不请求退出，仿真跑到
  timeout。

#### 7.1.5 filler 的选择（需要 case 设计）

filler 必须与生产者/依赖者**无寄存器依赖**，且应**参数化其目标执行组**
（G0/G1/G2/G3）—— 因为 filler 落在哪个组会占用那个组的单入口 ISQ，
直接影响依赖者能否按时派发。这是 case 设计的一部分，不是随便塞 `nop` 就行。

### Step 2 — `.S` → `.elf`

```bash
riscv64-unknown-elf-gcc -march=rv64ima -mabi=lp64 -nostdlib -nostartfiles \
  -Wl,-T,<OpenRio>/verification/orbe_bt_env/perf_eval/templates/link.ld \
  -o <WORK>/elf/ALU_to_ALU_k2.elf <WORK>/cases/ALU_to_ALU_k2.S
```

- 链接脚本把代码放到 `0x80000000`，与 ISA model 的 ROM 配置一致。
- **ELF 必须按 case id 命名**：cosim 的日志目录名取自 ELF 的 basename
  （`log/rtl_v1/<elf-name>_<seed>/`），都叫 `case.elf` 会互相覆盖。

### Step 3 — 跑 RTL

```bash
<OpenRio>/verification/orbe_bt_env/tools/verilator_cosim.sh run \
  --no-build \
  --dut-kind rtl_v1 \
  --tag perf_eval \
  --verbosity 2 \
  --tc <WORK>/elf/ALU_to_ALU_k2.elf
```

| 参数 | 说明 |
|---|---|
| `--dut-kind rtl_v1` | BE RTL + FE/Cache agent（§5） |
| `--no-build` | 复用已有 build；首次需先 `build --tag perf_eval` |
| `--verbosity 2` | **必须 ≥2**，否则 `[BE][DECODE]`（P1）和 `[BE][COMMIT]` 不打印 |
| `--tag` | 同一次评估的所有 case 共用一个 tag |

### Step 4 — 逐拍抽取事件

日志里已带 `cycle=` 的事件（`sim.log`）：

| caselist 术语 | 日志行 | 需要的 verbosity |
|---|---|---|
| **P1 / DSP 派发** | `[BE][DECODE] cycle=… group=… pc=… inst=… rob=…` | ≥ 2 |
| **P4 commit** | `[BE][COMMIT] cycle=… group=… pc=…` | ≥ 2 |
| P4 commit（备选） | `[BE][COSIM_OB] cycle=… pc=… result=…` | ≥ 1 |
| flush / recovery | `[BE][RECOVERY_FLUSH] cycle=… kind=… origin=…` | ≥ 2 |
| **P2 ISQ issue（火）** | `[BE_TB] [COSIM] [ISQ_FIRE] cycle=… group=… tag=…` | ≥ 2 |
| **P3 bypass 广播** | `[BE_TB] [COSIM] [P3_BYPASS] cycle=… lane=… tag=…` | ≥ 2 |

**抽取口径**：按 `pc` 认指令（`objdump` 的 `.dump` 与日志中的 `pc` 对照）。

> **2026-10-10 补齐。** P2 的打印由 latency bench 先加（`[ISQ_FIRE]`，取 `isq_issue_fire`
> = 请求 ∧ 该组 FU 的 ready，即**火**）；P3 的打印本轮补上（`[P3_BYPASS]`，4 lane 的
> `lane_bypass_valid/tag`）。四级现已齐备：P1 `[BE][DECODE]` / P2 `[ISQ_FIRE]` /
> P3 `[P3_BYPASS]` / P4 `[BE][COMMIT]`，全部在 verbosity ≥ 2。
>
> ⚠️ **但 P2/P3 没有外部参照。** ISA model 没有流水级，这两级的"实际位置"无法被 cosim
> 交叉验证（P1/P4 有）。因此 P2/P3 只能靠三件事自证：① 探针取**火**而非**请求**
> （`issue_valid` 是请求行，会提前若干拍）；② 同一 `tag` 的事件链自洽
> （`dispatch ≤ issue ≤ bypass ≤ commit`）；③ 比对器带**负控制**（喂错的预期必须报错）。

### Step 5 — 算 delta 并对表

对每条 case：

1. 找到生产者的首次 P1 事件 cycle → `t_prod`
2. 找到依赖者的首次 P1 事件 cycle → `t_dep`
3. `delta_measured = t_dep - t_prod`
4. 在 caselist 中该家族、该 `delta` 对应行取 `behavior_predicted`
5. 汇总成表

`compare.py` 应产出如下形态：

```text
case                     k   delta  t_prod  t_dep  behavior_obs   behavior_pred   verdict
ALU_to_ALU_delta_0       0     0       14     14    overlay        overlay         CONFORM
ALU_to_ALU_delta_1       1     1       14     15    wait_for_p3    wait_for_p3     CONFORM
...
```

### Step 6 — 人工判定

这是本方法的终点，也是**必须由人做的事**。

#### 7.6.1 判定词汇

| 判定 | 含义 | 处理 |
|---|---|---|
| `CONFORM` | 该 delta 下机制与预测一致 | 记录通过 |
| `TIMING_OFF` | 机制对，但 delta 整体平移 | 查口径差异（§9.1）、前端差异 |
| `MECHANISM_MISMATCH` | delta 一致但机制不符（如预测 `p3_capture` 实测 `arf_read`） | **重点嫌疑，需定位** |
| `DELTA_NOT_COVERED` | 这一族扫不出该 delta | 需要更细的调度控制（改 filler 的组/条数） |
| `ENV_ERROR` | 仿真失败 / 超时 / 事件漏抽 | **先排除环境问题，不作 RTL 结论** |
| `INCONCLUSIVE` | 无法判定 | 需加探针或看波形 |

#### 7.6.2 归因顺序（不符时按此排查）

1. **先排除环境**：case 是否跑到 HTIF 退出？`delta` 是否根本没被覆盖？
2. **查口径**：`attempt` vs `accept`（§9.1）—— 差一拍常常来自这里。
3. **查分辨率**：2 拍派发宽度导致 delta 跳跃（§9.2）—— 是"测不到"而非"不符"。
4. **查结构冲突**：filler 占了依赖者要用的组的 ISQ，制造了额外停留。
5. **查前端**：若在 `rtl_full` 上跑，取指节奏会污染（§10）。
6. 以上都排除后，才可判为**微架构行为与 draft 预测不符**。

#### 7.6.3 结果记录

- 原始事件：`results/<case_id>.events.tsv`
- 对照表与结论：`results/<family>.md`
- 汇总：`results/summary.md`（哪些家族 CONFORM、哪些不符、各自归因）

## 8. 汇总与结论形式

最终产出是一张**按家族聚合**的判定表：

下表只是**格式示例**，数字不是结论（真实结论要等 `compare.py` 在接线后的跑批上产出）：

| Producer 家族 | 覆盖 delta | CONFORM | MISMATCH | 结论 |
|---|---|---|---|---|
| ALU_to_ALU | 0..4 | — | — | 待跑批 |
| MUL_to_ALU | 0..6 | — | — | 待跑批 |
| ... | | | | |

**注意措辞**：结论是"RTL 符合/偏离 **draft** caselist"，在 caselist 晋升为
`spec/or-be/` 之前，不能表述为"符合规范"。

## 9. 已知陷阱

### 9.1 `attempt` vs `accept`（最重要）

caselist 定义的是 P1 **attempt** cycle；而观测面的 `alloc_valid`（`[BE][DECODE]`）
记录的是派发**被接受**的那一拍。若某拍被 dispatch 拒绝（目标 ISQ 占用、
`missed_wakeup`、flush 拍），该拍不产生任何事件。

→ 观测到的 `delta` 实际是 "first **accepted** P1 − first **accepted** P1"。
在 filler 少的 case 上两者通常一致；被拒的 case 会出现系统性偏移。
**归因前先确认这一点。**

### 9.2 2 拍派发宽度 → delta 分辨率

派发每拍最多 2 条，所以插入 1 条 filler 不一定让 P1 前进 1 拍。
结果是某些 delta 值可能扫不到（`DELTA_NOT_COVERED`），或同一 delta 被多次命中。
需要靠 filler 的执行组选择来细化。

### 9.3 `delta_0` 的 `overlay` 依赖 FE 同拍交付

`overlay` 要求两条指令落在**同一个 bundle**（slot0 + slot1）。
- `rtl_v1`：`fe_agent` 每拍可交付 2 槽，稳定可复现。
- `rtl_full`：取决于两条指令是否在同一条 32B line、有无 miss/redirect，**脆弱**。

→ 这也是 `delta_0` 必须在 `rtl_v1` 上验证的原因。

### 9.4 启动噪声

复位后流水线需要若干拍填满（实测首条 commit 在第 5 拍左右）。
**用相对 delta，不要用绝对 cycle 数** —— caselist 的定义本身就是相对量。

### 9.5 日志相关

- `--verbosity` 必须 ≥ 2，否则 P1 / P4 事件不打印。
- ELF 命名必须唯一，否则日志目录互相覆盖。
- `sim/` 已被 `.gitignore`（`/sim/*`）忽略，产物不会污染仓库。

### 9.6 ISA model 必须走到退出

case 若没有 `tohost` 写入 + `wfi`，ISA model 不会请求退出 → 仿真跑到
`--timeout`。这类 case 一律判 `ENV_ERROR`。

### 9.7 ⛔ 拍数类事实以 RTL / 实测为准，**文档措辞不算数**

**这是本项目实际栽过的坑（LOAD latency）**：HAS 写的是"2 拍"，
但真实值是 **3 拍**——拍 1 AGU / 拍 2 L1 D cache / 拍 3 **arbiter + CDB FIFO 共占**
（由 Cache HAS 作者确认；原文漏掉了第 3 拍）。
按文档措辞推演会得出错误结论，而且**多轮讨论都无法收敛**。

**规矩**：

- 凡涉及"几拍"的实现事实（FU latency、占用几级、发布延迟），**必须读 RTL 或实测**，
  **不得以 HAS / spec 的文字表述为依据**。
- **文档是规格，是"主张"；RTL 是"行为"。** 两者冲突时，**冲突本身就是发现** ——
  记录下来反馈给文档所有者，而不是自己挑一句当结论。
- 这不违反"RTL 不能当判定基准"（§1.1）：RTL 在这里的用途是**确定被测参数**和
  **推翻文档主张**，不是用来**生成预期**。

**连带教训**：引用任何"几拍"的说法，**必须同时确认它的参考系** ——
从哪一拍起算？数的**级数**还是**拍差**？没有参考系的"N 拍"是没有意义的。

## 10. 阶段 2：端到端（`rtl_full`）

阶段 1 回答"**BE 的时序机制是否符合预测**"；阶段 2 回答
"**整机的 performance 是多少**"（IPC / 总 cycle）。

| 项 | 阶段 1 | 阶段 2 |
|---|---|---|
| DUT | `rtl_v1` | `rtl_full` |
| 关注 | delta 与机制 | IPC、总 cycle、flush 次数 |
| 输入 | 定向 case 家族 | 同一批 ELF，另加负载程序 |
| FE/Cache | agent 占位 | 真实 RTL |

同一批 ELF 直接换 `--dut-kind rtl_full` 即可（FE 通过 `fe_mem_vif` 向
`cache_agent` 的 I 侧取 L2/PTW，无需额外适配）。

**不要用 `rtl_full` 做阶段 1 的 delta 判定**：micro-case 依赖受控的派发 cycle，
而真实 FE 的取指节奏会把它搅乱（§9.3）。

> ⚠️ **这条只管 delta 判定。latency 标定反而必须用 `rtl_full`**（见 §5.1）：
> `rtl_v1` 后面接的是 `cache_agent`，LOAD 的返回时刻由 agent 自己的参数决定，
> 拿它标定 LOAD 延迟是循环论证。

## 11. 当前状态

| 组件 | 状态 |
|---|---|
| 目录骨架 | ✅ 已建 |
| `templates/link.ld` | ✅ 已建（沿用已验证约定） |
| `templates/case.S.in` | ⚠️ 初版，待定稿（退出码寄存器、JALR 目标准备等） |
| `gen_cases.py` | ❌ 待建 |
| `run_perf.sh` | ❌ 待建 |
| `compare.py` | ❌ 待建 |
| `be_agent.sv` 的 P3 打印 | ❌ 待补（信号已在观测面上） |
| 端到端脚本 | ❌ 阶段 2 再做 |
