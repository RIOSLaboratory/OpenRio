# perf_eval 方法文档

从 caselist 的预测，到 RTL 的**逐拍证据**，再由**人**做判定的完整方法。

**核心原则：工具只呈现证据，不做判定。** 所有结论由人给出。

---

## 0. 一句话概括

把 caselist 里**预测**的每一条依赖时序，翻译成一段**受控的汇编**，编成 ELF 喂给
RTL，**逐拍抽出相关指令在 BE 各阶段的位置**（全阶段轨迹），把这份原始证据摆出来，
由**人**对照 caselist 的预测判断 RTL 是否符合预期。

```text
caselist(.md)  ──gen_cases──▶  .S  ──gcc+link.ld──▶  .elf
                                                      │
                                          verilator_cosim.sh (rtl_v1)
                                                      │
                                                  sim.log
                                                      │
                                       逐拍 · 全阶段 · 逐指令位置
                                         （原始证据，可复核）
                                                      │
                                              ★ 人工判定 ★
```

**为什么不做自动判定**：判定依赖"阶段映射"这一层假设，而该假设本身尚未核实
（见 §9.1）。假设一旦有误，工具会输出**看起来很有说服力的错误数字**，比不给
数字更危险。逐拍位置是原始证据，人能直接看出真实发生了什么。

## 1. 适用范围与前提

- 目标是 BE 微架构的**时序符合性**（timing conformance），不是通用跑分（benchmark）。
- **基准本身还是 draft**：两份 caselist 都写着
  `Normative timing sources: pending promotion to spec/or-be/`。
  因此结论形式是 **"RTL vs draft 预测"**，不是 "RTL vs 已冻结规范"。
- **主 DUT 用 `rtl_v1`**（BE RTL + FE agent + cache agent），理由见 §5。

### 1.1 Golden 基准与依据来源（2026-10 裁决）

**Golden = OpenRio 仓库当前提交的 `docs/` + `src/core/*_rtl_v1/`。**
阶段划分、模块语义、时序行为，一律以 OpenRio 现有文档与代码为准。

| 来源 | 位置 | 状态 |
|---|---|---|
| HAS V1.0（**阶段定义唯一出处**） | `OpenRio:docs/BE/or_be_has_V1.0.md` §5 | ✅ golden（提交于 2026-09-30） |
| 模块文档 | `OpenRio:docs/modules/`（自 openrios `modules_v4/` 同步） | ✅ golden |
| RTL | `OpenRio:src/core/{be,fe,cache}_rtl_v1/` | ✅ golden；**与文档冲突时以 RTL 为准** |
| 对外边界 | `docs/modules/interface_definitions.md`、`openrios:.../interfaces/*.pdf` | ✅ |

**每次测量必须把当时的 OpenRio commit SHA 记进 `perf_eval_work/manifest.yaml`** ——
"以最后一次提交为准"意味着基准会随提交前移；不记 SHA 的结果无法追溯。

> ⛔ **已作废，不得作为依据**：
> - `control_flow/` —— 2026-09-20 评审确认过时
> - `OpenRio:docs/BE/OR_BE_0818.drawio` —— 8 月旧划分（ISQ 不在 P2、含 `P2-1`/`P2-2`）；
>   保留在分支里**仅作记录**，不是参考材料
> - `P2-1` / `P2-2` —— 随 0818 一起作废

### 1.2 9 月裁决的四条结论（阶段语义）

| 结论 | 内容 |
|---|---|
| **IB ∈ P0** | `BE_SUBSYSTEM.drawio.png` 把 IB 画在 P1 区，属图画歧义；以 HAS §5 为准 |
| **ISQ ∈ P2** | 9 月新架构。P1 只负责组装并**写入** ISQ，ISQ 本体是 P2 的存储 |
| **bypass 走向** | P4 → P1；P3 → P1（`dependency_check`、`isq_payload_assembly`）**和** → P2（四个 ISQ 的 snoop） |
| **分段数 = 5** | P0/P1/P2/P3/P4，见 §2.4。目录里的 `p2p3/` 只是打包方式，不代表 P2 与 P3 合并 |

> **命名已统一为 `g3_lsu_iface`**（2026-10 裁决：跟随 RTL，改文档不改代码）。
> `docs/modules/lsu/g3_lsu_iface.md` 已改名，`docs/modules/` 其余引用与
> `docs/Cache/or_cache_has_V1.0.md` 已改齐；`openrios:modules_v4/` 同步改齐，
> 两侧 `diff -rq` 一致。

### 1.3 必须人工判定

caselist 的 `behavior` 标签描述的是微架构机制（bypass 捕获 / commit CDB 捕获 /
ARF 读取），脚本无法可靠推断；口径差异与不符项的归因也需要人判断。

## 2. 核心概念

### 2.1 delta

```text
delta = dependent first P1/DSP attempt cycle - producer first P1/DSP attempt cycle
```

`P1/DSP` 指后端派发级：一条指令**第一次尝试**进入派发的那一拍。

⚠️ 注意"**尝试**"不是"**被接受**"，两者口径不同 —— 见 §9.2。

**delta 的双重身份**（重要）：

| 身份 | 含义 | 谁负责 |
|---|---|---|
| **构造目标** | 构造 `.S` 时的设计意图（case 名 `_delta_2` 即"要求依赖者首次 P1 比生产者晚 2 拍"）。两操作数 caselist 的 **Timing Setup** 列就是这个构造指令 | 人（case 设计） |
| **实测结果** | 排布 + 流水线行为的结果。没有指令编码能表达"晚 2 拍派发"，所以 delta 是涌现量 | 从轨迹读出 |

**构造给目标，实测给实际值，两者对不上正是要查的东西。**

### 2.2 behavior 标签（判定机制）

| 标签 | 含义 | 判定需要看哪个阶段 |
|---|---|---|
| `overlay` | `delta_0`：同一 bundle 内 slot0 生产者 → slot1 依赖者在 rename 阶段叠加 | P1（两 slot 同拍） |
| `wait_for_p3` | 依赖者早于生产者 P3 派发，携带 `wait_tag`，在 ISQ 里驻留等待 | P1 + **P2 驻留** + 生产者 P3 |
| `p3_capture` | 依赖者首次 P1 尝试恰好命中生产者 P3 Bypass，捕获 `bypass_data` | P1 首次尝试 × 生产者 P3 |
| `p4_capture` | 依赖者首次 P1 尝试恰好命中生产者 P4 Commit CDB，捕获 `commit_data` | P1 首次尝试 × 生产者 P4b |
| `arf_read` | 生产者已提交，依赖者在 P1 直接读 ARF | P1 首次尝试 × 生产者 P4b |

注意 `wait_for_p3` 与 `p3_capture` 的区分**必须**看 P2 驻留 —— 只看 P1/P3/P4
事件无法区分（见 §2.4）。

### 2.3 各生产者的边界 delta（判定基准）

单操作数 caselist：

| Producer | Producer latency | P3 delta | P4 delta | ARF boundary delta | 枚举 delta |
|---|---:|---:|---:|---:|---|
| ALU | 1 | 2 | 3 | 4 | 0..4 |
| MUL | 3 | 4 | 5 | 6 | 0..6 |
| DIV | 8 | 9 | 10 | 11 | 0..11 |
| LOAD | 2 | 3 | 4 | 5 | 0..5 |
| JALR link | 3 | 4 | 5 | 6 | 0..6 |

两操作数 caselist：

| Producer | P3 delta | P4 delta | ARF boundary delta |
|---|---:|---:|---:|
| ALU/BRU result | 2 | 3 | 4 |
| MUL result | 4 | 5 | 6 |
| DIV/REM result | 9 | 10 | 11 |
| LOAD hit result | 3 | 4 | 5 |

### 2.4 BE 阶段与可观测性（全阶段表）

**这不是三种阶段。** BE 有 6 个可观测里程碑，且各阶段的可观测程度差别很大：

| 阶段 | 名称 | 代表模块（v4） | 观测信号（`ob_cosim_if`） | 打印状态 |
|---|---|---|---|---|
| **P0** | FE→BE 边界：接收 FE 指令入 IB、回 `fe_ready` | `p1/IB.md`（目录名遗留，内容属 P0） | `fe_vif` 握手 `fe_be_instr_valid/ready` + payload | `[BE][COSIM] [FE-BE]`（observation only） |
| **P1** | decode → dependency check → rename → **dispatch(accept)**，写入 ISQ 与 in-flight window；**P1 不持有指令状态** | `p1/decode.md`、`p1/dependency_check.md`、`p1/dispatch_logic.md`、`p1/*tag_mapping.md`、`p1/*ARF.md`、`top/isq_payload_assembly.md` | `decode_issue_valid` + `decode_issue_pld` | `[BE][DECODE]`（verbosity ≥ 2） |
| **P2** | **ISQ 驻留 + 操作数就绪（bypass snoop）+ 发射 + FU 执行**；G3 发往外部 LSU。执行周期按 FU 不等（ALU 1 拍、MUL 3 拍、DIV N 拍、LSU 握手） | `p2p3/ISQ_Group0..3.md`、`p2p3/FU_input_mux.md`、`fu/*.md`、`lsu/g3_lsu_iface.md` | `isq_g0..g3_issue_valid` + `_pld.self_tag` | **待补**（数据已在 `l2_isq_by_rob`） |
| **P3** | **写回 / bypass**：组内仲裁 → 各 lane 写 `CompletionScoreboard` / `Buffer`，并**同拍广播 bypass** | `p2p3/p3_arbiter_G0/G1.md`（G2/G3 直连，无仲裁） | `fu_after_valid/tag/result/mispredict/...` | **待补**（数据已在 `l2_wb_by_rob`） |
| **P4** | **提交 / 恢复**：按序提交更新架构态（`Buffer` → ARF），或在提交边界选一个 recovery 事件广播 flush | `p4/CompletionScoreboard.md`、`p4/Buffer.md`、`p4/PC_File.md`、`p4/flush_model.md`、`p4/SerialInstructionTracker.md`、`p4/system_instruction_handler.md` | `commit_valid/tag/pc/result/rd_*`、`flush_valid/flush_tag`、`recovery_*` | `[BE][COMMIT]`(≥2)、`[BE][COSIM_OB]`(≥1)、`[BE][RECOVERY_FLUSH]`(≥2) |

> **分段数是 5，依据**：HAS §5 是唯一写成表格、带 owning modules 的阶段定义，
> 明确列 P0–P4 五行。代码侧 `p1/`、`p2p3/`、`p4/` 三个目录把 **P2 与 P3 打进同一个目录**
> （`ISQ`+`FU` 属 P2，`p3_arbiter_*` 属 P3），`backend_top.sv` 的注释也写
> `P2 / P3 issue to completion` —— 那是**代码分节**，不是"P2 与 P3 是一段"。
> `modules_v4/` 同理（P 目录只有 `p1/ p2p3/ p4/`，且没有 `p0/`，因为 IB 的文档被放在 `p1/`）。

⚠️ **仍然存在的两处观测空洞**（不是待核实，是确认缺失）：

1. **P1 的"尝试"不可观测**。HAS §5：`P1 holds no instruction state` —— 所以"首次 P1 尝试"
   是**逐拍组合决策**（IB 队头是否获准派发），不是占用。而观测面只记 **accept**
   （`alloc_valid`），被拒的拍不产生事件。见 §9.2。
2. **P2 完全不可观测**。观测面上没有对应信号。要判定 `wait_for_p3` 与 `p3_capture`
   的差别，必须新增探针（见 §11）。

### 2.5 规模

| caselist | 内容 |
|---|---|
| `INT_single_operand_dependency_caselist_v1.md` | 37 条：ALU 5 + MUL 7 + DIV 12 + LOAD 6 + JALR 7 |
| `INT_two_operands_dependency_caselist.md` | P1 MUX（已列 17 条）+ P2 MUX，见原文 |

## 3. 产物与仓库边界

| 内容 | 位置 | 是否提交 |
|---|---|---|
| caselist（预测基准）、K-map、时序图 | `openrios:work/or-be-draft/timing/` | 是（在其自己仓库） |
| 工具、模板、本方法文档 | `OpenRio:verification/orbe_bt_env/perf_eval/` | 是 |
| 生成的 `.S` / `.elf` / `.dump` / `sim.log` | `/work/.../model/perf_eval_work/`（不在 OpenRio/openrios 内，见 README §2） | **否** |
| 逐拍轨迹与结果 | 同上 `results/` | **否** |

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

## 5. 为什么主 DUT 用 `rtl_v1`

caselist 的预测量**全部是 BE 内部量**（P1 派发、P3 bypass、P4 commit CDB、ARF 读取），
FE 和 Cache 不进入这些定义。用 `rtl_v1` 的好处：

1. **可隔离噪声**：FE 由 agent 占位，不引入取指节奏、redirect、ICache miss 的干扰。
2. **可控**：`fe_agent` 每拍最多交付 2 槽且冻结 cursor，所以 "同拍双发"（`delta_0`
   `overlay`）这类 case 在 `rtl_v1` 上能稳定复现。
3. **快且确定**：无 cache 行为差异，可复现。

`rtl_full`（FE+BE+Cache）只用于阶段 2 的端到端评估，见 §10。

## 6. 流程总览

| 步骤 | 动作 | 产物 | 工具 |
|---|---|---|---|
| 0 | 钉住溯源 | `manifest.yaml` | 手工 |
| 1 | caselist `.md` → `.S` | `cases/<case_id>_k<k>.S` | `gen_cases.py` |
| 2 | `.S` → `.elf` | `elf/<case_id>_k<k>.elf` | `run_perf.sh compile` |
| 3 | 跑 RTL | `sim/verilator_<TAG>/log/rtl_v1/<name>_<seed>/sim.log` | `verilator_cosim.sh` |
| 4 | 抽逐拍全阶段轨迹 | `results/<case_id>.trace.tsv` | `compare.py trace` |
| 5 | 附 delta 算术（辅助） | `results/<case_id>.md` | `compare.py` |
| 6 | **人工判定** | 结论与归因 | 人 |

## 7. 步骤详解

### Step 0 — 钉住溯源

测量前更新 `perf_eval_work/manifest.yaml`：

- OpenRio（design）的 branch + commit
- openrios（caselist + v4 规范）的 branch + commit
- 工具链版本

**不更新 SHA 的测量结果无法追溯**，等同于无效数据。

### Step 1 — caselist `.md` → `.S`

#### 7.1.1 delta 是构造目标，但要靠排布实现

case 名 `ALU_to_ALU_delta_2` 就是构造意图：**要求依赖者的首次 P1 尝试恰好比生产者
晚 2 拍**。两操作数 caselist 的 Timing Setup 列进一步给出了构造方法，例如：

> `INT2_G1P3_G0P3`：**Issue `mul` two cycles before `add`** so G1 and G0 results
> publish at P3 together.

但**没有任何指令编码能表达"晚 2 拍派发"**。可控的旋钮只有一个：**生产者与依赖者
之间插入多少条独立指令、落在哪个执行组**。

而派发是**按序、每拍最多 2 条**的，所以插 `k` 条 filler，P1 大约前进 `ceil(k/2)`
拍，具体还受 G0/G1 路由与 ISQ 占用影响。因此构造策略是：

> **按目标 delta 设计排布（filler 条数 + 组别），生成一族的候选；跑到哪一拍由轨迹
> 读出，再由人判断该 case 是否真的落到了目标 delta，以及机制是否符合预测。**

`delta` 的算术是机械减法，但**"这个 case 是否实现了目标 delta"是设计问题**，由人判断。

#### 7.1.2 生成物形态

```text
cases/
├── ALU_to_ALU_k0.S        # producer; consumer        -> 目标 delta_0 (overlay)
├── ALU_to_ALU_k2.S        # producer; 2 条 filler; consumer
├── ALU_to_ALU_k4.S
└── ...
```

每个家族一条 `k` 扫描链；`k` 的步长与上限由该家族的枚举 delta 上限决定
（如 ALU 家族 0..4，DIV 家族 0..11）。行末注释记录**意图 delta**，
便于生成者对表。

#### 7.1.3 两操作数族的特殊约定

两操作数 case 需要**同时控制两个生产者的相对 P1 偏移**，生成器必须支持对
producer A / producer B 分别设置 filler 数，而不是单一 `k`。

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

#### 7.1.5 filler 的选择（case 设计的一部分）

filler 必须与生产者/依赖者**无寄存器依赖**，且应**参数化其目标执行组**
（G0/G1/G2/G3）—— filler 落在哪个组会占用那个组的单入口 ISQ，直接影响依赖者
能否按时派发。不是随便塞 `nop` 就行。

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
| `--verbosity 2` | **必须 ≥2**，否则 `[BE][DECODE]`、`[BE][COMMIT]` 不打印 |
| `--tag` | 同一次评估的所有 case 共用一个 tag |

### Step 4 — 抽取逐拍全阶段轨迹（本步是核心产物）

**不是"抽三个 cycle"，而是把两条指令在 6 个阶段上的状态逐拍排出来。**

按 `pc` 认指令（`objdump` 的 `.dump` 与日志 `pc` 对照），对每条指令的每一拍输出
一行，覆盖 §2.4 的全部阶段。目标形态：

```text
cycle  pc          inst          P0(IB)  P1(dispatch)      P2(ISQ)  P3(issue)  P4a(wb)  P4b(commit)
14     0x80000020  mul x5,x1,x2  -       ACCEPT            n/a      -          -        -
15     0x80000024  add x6,x5,x3  -       REFUSED           n/a      -          -        -    ← 需 P2/拒绝证据
16     0x80000020  mul x5,x1,x2  -       (resident)        n/a      ISSUE      -        -
...
```

**可观测性如实标注**（当前状态下能填的格子）：

| 列 | 当前能否填 | 依据 |
|---|---|---|
| P0 | 能（`[BE][COSIM] [FE-BE]`） | `be_agent.sv` |
| P1 ACCEPT | 能（`[BE][DECODE]`） | 同上 |
| P1 **REFUSED / 多次尝试** | **不能** —— `alloc_valid` 只记接受 | 见 §9.2 |
| P2 | **不能** —— 观测面无信号 | 见 §2.4 |
| P3 | **不能**（待补打印；数据已在 `l2_isq_by_rob`） | 见 §11 |
| P4a | **不能**（待补打印；数据已在 `l2_wb_by_rob`） | 见 §11 |
| P4b | 能（`[BE][COMMIT]` / `[BE][COSIM_OB]`） | `be_agent.sv` |

> ⚠️ 因此**现阶段这份轨迹有空洞**。空洞由人判断其影响：如果某个 behavior 的判定
> 恰好依赖空洞列，该 case 就应力 `INCONCLUSIVE`，而不是猜。

### Step 5 — 附上 delta 算术（辅助，不是结论）

对每条 case，工具**可以**附上：

1. 生产者的首次 P1 事件 cycle → `t_prod`
2. 依赖者的首次 P1 事件 cycle → `t_dep`
3. `delta_measured = t_dep - t_prod`

但**必须同时打印原始 cycle 和所用事件名**，否则无法复核：

```text
case                 k   t_prod  t_dep  delta  事件来源              目标delta  判定(人填)
ALU_to_ALU_k0        0     14     14      0    [BE][DECODE] first    0         ____
ALU_to_ALU_k2        2     14     16      2    [BE][DECODE] first    2         ____
```

**最后一列留空，由人填写。** 工具不输出 `CONFORM` / `MISMATCH` 之类的结论。

### Step 6 — 人工判定

这是本方法的终点，也是**必须由人做的事**。

#### 7.6.1 人填写的判定词汇

| 判定 | 含义 | 处理 |
|---|---|---|
| `CONFORM` | 该 delta 下机制与预测一致 | 记录通过 |
| `TIMING_OFF` | 机制对，但 delta 整体平移 | 查口径（§9.2）、前端差异 |
| `MECHANISM_MISMATCH` | delta 一致但机制不符（如预测 `p3_capture` 实测 `arf_read`） | **重点嫌疑，需定位** |
| `DELTA_NOT_REALIZED` | 这一族排布得不到目标 delta | 调 filler 条数/组别，或记录实际落点 |
| `INCONCLUSIVE` | 判定所需证据落在不可观测阶段 | 先加探针（§11），不要猜 |
| `ENV_ERROR` | 仿真失败 / 超时 / 事件漏抽 | **先排除环境问题，不作 RTL 结论** |

#### 7.6.2 归因顺序（不符时按此排查）

1. **先排除环境**：case 是否跑到 HTIF 退出？轨迹是否完整？
2. **查依据**：阶段语义是否查了 v4 + RTL？（§1.1；**不要用 `control_flow/`**）
3. **查口径**：`attempt` vs `accept`（§9.2）—— 差一拍常常来自这里。
4. **查分辨率**：2 拍派发宽度导致 delta 跳跃（§9.3）—— 是"测不到"而非"不符"。
5. **查结构冲突**：filler 占了依赖者要用的组的 ISQ，制造了额外停留。
6. **查前端**：若在 `rtl_full` 上跑，取指节奏会污染（§10）。
7. 以上都排除后，才可判为**微架构行为与 draft 预测不符**。

#### 7.6.3 结果记录

- 逐拍轨迹：`results/<case_id>.trace.tsv`
- 对照表（含人填判定）：`results/<family>.md`
- 汇总：`results/summary.md`

## 8. 汇总与结论形式

最终产出是一张**按家族聚合**的判定表（判定列由人填写）：

| Producer 家族 | 覆盖 delta | CONFORM | MISMATCH | INCONCLUSIVE | 结论 |
|---|---|---|---|---|---|
| ALU_to_ALU | 0..4 | 5/5 | 0 | 0 | 符合 |
| MUL_to_ALU | 0..6 | 6/7 | 0 | 1 | delta_3 缺 P2 证据 |
| ... | | | | | |

**注意措辞**：结论是"RTL 符合/偏离 **draft** caselist"，在 caselist 晋升为
`spec/or-be/` 之前，不能表述为"符合规范"。

## 9. 已知陷阱

### 9.1 阶段映射本身是假设（最重要）

本文档 §2.4 的阶段表来自 README + v4 + 观测面，**尚未逐条对照 v4 原文与 RTL 核实**
（其中 P0/P1 归属已有文档冲突，见 §2.4）。

一旦映射写错，任何基于它算出的"delta"或"机制"都会**错得很自信**。这正是
"工具只出证据、判定归人"的原因。

### 9.2 `attempt` vs `accept`

caselist 定义的是 P1 **attempt** cycle；而观测面的 `alloc_valid`（`[BE][DECODE]`）
记录的是派发**被接受**的那一拍。若某拍被 dispatch 拒绝（目标 ISQ 占用、
`missed_wakeup`、flush 拍），该拍不产生任何事件。

→ 观测到的实际是 "first **accepted** P1 − first **accepted** P1"。
在 filler 少的 case 上两者通常一致；被拒的 case 会出现系统性偏移。
**归因前先确认这一点。**

### 9.3 2 拍派发宽度 → delta 分辨率

派发每拍最多 2 条，所以插入 1 条 filler 不一定让 P1 前进 1 拍。
结果是某些 delta 值可能得不到（`DELTA_NOT_REALIZED`），或同一 delta 被多次命中。
需要靠 filler 的执行组选择来细化。

### 9.4 `delta_0` 的 `overlay` 依赖 FE 同拍交付

`overlay` 要求两条指令落在**同一个 bundle**（slot0 + slot1）。
- `rtl_v1`：`fe_agent` 每拍可交付 2 槽，稳定可复现。
- `rtl_full`：取决于两条指令是否在同一条 32B line、有无 miss/redirect，**脆弱**。

→ 这也是 `delta_0` 必须在 `rtl_v1` 上验证的原因。

### 9.5 启动噪声

复位后流水线需要若干拍填满（实测首条 commit 在第 5 拍左右）。
**用相对 delta，不要用绝对 cycle 数** —— caselist 的定义本身就是相对量。

### 9.6 日志相关

- `--verbosity` 必须 ≥ 2，否则 P1 / P4 事件不打印。
- ELF 命名必须唯一，否则日志目录互相覆盖。
- `sim/` 已被 `.gitignore`（`/sim/*`）忽略，产物不会污染仓库。

### 9.7 ISA model 必须走到退出

case 若没有 `tohost` 写入 + `wfi`，ISA model 不会请求退出 → 仿真跑到
`--timeout`。这类 case 一律判 `ENV_ERROR`。

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

**不要用 `rtl_full` 做阶段 1 的判定**：micro-case 依赖受控的派发 cycle，
而真实 FE 的取指节奏会把它搅乱（§9.4）。

## 11. 当前状态与待办

| 组件 | 状态 |
|---|---|
| 目录骨架 | ✅ 已建 |
| `templates/link.ld` | ✅ 已建（沿用已验证约定） |
| `templates/case.S.in` | ⚠️ 初版，待定稿 |
| `gen_cases.py` | ❌ 待建 |
| `run_perf.sh` | ❌ 待建 |
| `compare.py` | ❌ 待建（**只输出逐拍轨迹 + delta 算术，不输出结论**） |
| 阶段表核实（对照 v4 原文 + RTL） | ❌ **待做**（§2.4 的两条待核实项） |
| P3 打印（ISQ issue） | ❌ 待补（数据已在 `l2_isq_by_rob`，差一行 `$display`） |
| P4a 打印（写回 / 完成） | ❌ 待补（数据已在 `l2_wb_by_rob`） |
| P1 拒绝 / 多次尝试的观测 | ❌ 待做（当前只有 accept 事件） |
| P2 驻留的观测 | ❌ **需要新增探针**（观测面上无信号） |
