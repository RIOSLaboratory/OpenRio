# 8 月 timing 材料 → 9 月 golden：改动清单与改造计划

**范围**：`perf_eval/timing/` 下的 8 月材料（2 份 caselist + 2 份 diagram + 3 份 K-map）
**当前架构（9 月）**：`docs/BE/or_be_has_V1.0.md` §5（阶段表）
   　　　　　　　　　　　　+ `docs/modules/`（模块语义）
   　　　　　　　　　　　　+ `src/core/be_rtl_v1/`（模块归属 / 命名 / 
   参数；与前两者冲突时以此为准）
**判定基准**：`timing/diagrams/*.md` —— 基于 9 月架构的**预测**（待审核）。
⛔ **RTL 绝不出现在判定基准里**：我们评估的对象就是 RTL 的行为，它不能既当运动员又当裁判。
---

## 0. 结论摘要

| 材料 | 是否受 9 月改版影响 | 处置 |
|---|---|---|
| caselist ×2 | 阶段词汇**已对齐**；cycle 数值**待实证** | 定义不动，逐条复算后决定是否出 v2 |
| diagrams ×2 | 阶段词汇**已对齐**；单元格是**状态名**不是阶段号 | **局部修订**（§3），不需重画 |
| K-maps ×3 | 未发现受影响项 | **不动**（你的判断成立） |

**核心发现**：8 月材料用的阶段词汇（`P1 MUX` / `P2 MUX` / `P3 Bypass` / `P4 Commit`；diagram 里的 `IB`/`RSx`/`SL`/`WB`/`C`）**其实已经和 9 月划分对齐**。真正不同的是 `OR_BE_0818.drawio` 那张图的编号切法 —— 而它已经作废。

**所以改动范围比预期小**：K-map 不动，diagram 小修，caselist 定义不动、只待数值实证。

---

## 1. 8 月 vs 9 月的阶段切法对照

| 阶段 | 9 月（HAS §5，golden） | 8 月（`OR_BE_0818.drawio`，已作废） |
|---|---|---|
| **P0** | **仅 `IB`**（FE→BE 边界） | `IB` + `Decode` + `Dependency Check` + `Tag Mapping` + `ARF` + `PC File` |
| **P1** | `decode` / `dependency_check` / rename / **dispatch**（写入 ISQ） | `Dispatch` + `ISQ_payload` |
| **P2** | **ISQ 驻留 + 发射 + FU 执行** | FU 执行（`P2-1`）+ mux / 仲裁（`P2-2`） |
| **P3** | **写回 / bypass**（组内仲裁 → lane 写 CS/Buffer → 广播 bypass） | Buffer 写入区 |
| **P4** | **提交 / 恢复** | Commit |
| 其它 | — | `P2-1` / `P2-2`（**已作废**） |

> **证据与不确定性**：上表 8 月一列是据 `OR_BE_0818.drawio` 里 P 标注的坐标
> （P0 x=40、P1 x=1070、P2 x=1630、P3 x=2160、P4 x=2590；`P2-1` x=1773、`P2-2` x=1923）
> 与各模块 x 坐标的聚类推断的。该图的 P 标注是**无边框浮动文字**，列边界无法机械确定，
> 故 **8 月一列需目视确认**；9 月一列有 HAS §5 表格直接支撑。

### 实质差别只有三处

1. `decode` / `dependency_check` / `tag_mapping` / `ARF`：8 月记 **P0** → 9 月记 **P1**
2. **ISQ**：8 月在 **P1**（或省略）→ 9 月 **P2**
3. 写回 / 仲裁：8 月在 **P2-2** → 9 月 **P3**

**而这两点两版一致**：`P3`＝bypass、`P4`＝commit；`IB ∈ P0`。

---

## 2. 逐材料影响分析

### 2.1 caselist（2 份）—— 定义不动，数值待实证

材料用到的阶段词汇与 9 月对照：

| caselist 词汇 | 含义 | 9 月归属 | 是否一致 |
|---|---|---|---|
| `P1 MUX` | 组装 ISQ payload 时的源解析 | P1（dispatch 写 ISQ） | ✅ |
| `P2 MUX` | 常驻 ISQ 条目在 **FU-input 时**收到当拍 forwarding | P2（ISQ + 发射） | ✅ |
| `P3 Bypass` / `P3 delta` | bypass 发布 | P3（写回/bypass） | ✅ |
| `P4 Commit` / `P4 delta` | commit CDB | P4（提交） | ✅ |
| `delta = first P1 attempt − first P1 attempt` | dispatch 那一拍 | P1（dispatch） | ✅ |

**⇒ 定义不需要改。** 原因：§1 的三处差别**都不移动"dispatch 那一拍"**。

- 差别 1 只把 decode 等模块从 P0 挪到 P1，**dispatch 仍在 P1**；
- 差别 2 只把 ISQ 的**存储归属**从 P1 挪到 P2，**"写入 ISQ"这个动作仍在 P1**；
- 差别 3 只把写回从 P2 挪到 P3，**bypass 的发布事件位置不变**。

所以 `delta`、`P3 delta`、`P4 delta`、`ARF boundary delta` 的**语义全部不变**。

### 2.2 diagrams（2 份）—— 单元格是状态名，只需局部修订

单元格词汇：

```text
IB              入 IB（P0）
RS0 / RS1 / RS3 在对应组的 ISQ 里常驻（P2）
ISQ Wait        驻留等待（P2）
SL (ALU0…)      发射到 FU（P2）
WB              写回（P3）
C               提交（P4）
另有 MUL stg0..2 / AGU / L1D
```

**这些是状态名，不是阶段号** → 阶段重编号**不影响单元格内容**。

散文里的阶段引用也与 9 月一致，例如：

> "normal boundaries are **P3 at T4, P4 at T5**, and ARF-ready at T6" —— T4=`WB`=P3、T5=`C`=P4 ✅

两份图都**没有出现 `P2-1` / `P2-2`**。

### 2.3 K-maps（3 份）—— **不动**

K-map 内的阶段引用只有这几种：

| K-map | 阶段引用 |
|---|---|
| `INT_P1MUX_two_operands_…` | `G0/G1 P3 Bypass`、`G3 Load P3 Bypass`、`P4 Commit`、`Source 1/2 ready at P1 MUX`、标题 `INT K-Map: P1 MUX` |
| `INT_P2MUX_two_operands_…` | 同上，另有 `… at P2 MUX`、`resident entry at P2/FU-input time` |
| `INT_single_operand_…` | 仅 1 处：`csr_inflight blocks younger dispatch until CSR P4 commit` |

全部与 9 月划分一致（见 §2.1）。**未发现 `P2-1` / `P2-2` 字样。**

**⇒ 你的判断成立：K-map 不用动。**

---

## 3. 计划的改法

| # | 对象 | 改什么 | 理由 |
|---|---|---|---|
| 1 | `diagrams/INT_single_operand_*.md` | 在每例散文里显式写出 **ISQ 驻留 = P2**（补阶段名标注 `RS0` → `RS0 [P2]`）。⛔ **槽位变更分两类**（2026-10 修订，原"只允许改标签"已作废）：**① 参数驱动的机械重算 ✅ 允许** —— `L` 按实测更新后按 `WB@T(3+L)` 重画全表；**② 为对齐某次仿真结果而单独平移槽位 ⛔ 禁止**。判据见 `timing/REVISION_PLAN.md` §5.2 / §9⑤ | 现在只写 "waits resident in ISQ"，没给阶段号；`wait_for_p3` 因此没有阶段归属。**原"不得改 T 槽位"作废的原因**：`L` 恰好编码在 T 列里（`WB@T(3+L)`），按字面执行则任何 `L` 更新都做不了；而"改预测去迎合 RTL"这个目的由**②**继续挡住 |
| 2 | `diagrams/*.md` 头部 | 补一节「阶段对照表」：`IB/RSx/SL/WB/C` ↔ `P0..P4` | 读者不必再猜（我自己就猜错过） |
| 3 | `caselists/*.md` 头部 | 在 `Normative timing sources` 处补上 golden 锚点（OpenRio commit SHA） | 现在写的是 `pending promotion to spec/or-be/`，无法追溯 |
| 4 | `diagrams/*.md` + `caselists/*.md` 的**数值** | 以**仿真实测**比对 diagram 的逐拍时间线（主）与 caselist 阈值表（交叉校验）；不一致时由**材料所有者**判定是否修订，**不得由 RTL 反推** | 唯一真正的实质风险 |
| 5 | `caselists/*.md` 阈值表 + 各家族 case 数 | 改成 **L 参数化**（§4.2）：`P3=L+1` / `P4=L+2` / `ARF=L+3`，枚举 `0..L+3`。**`L` 变则 case 数变，需增删 case** | 8 月写死的是**公司内部算子**的值，对我们的外网 FU 无约束力 |
| 6 | 各 FU 的 `L` | 用同事的 latency ELF **实测**（`issue_valid → result_valid`），逐个 FU 填；**LOAD 见 §4.6** | 取代 §4.2 的幻数；这是唯一能定的方式 |
| 7 | K-maps ×3 | **不动** | §2.3 |

---

## 4. cycle 数值：预期从哪来、实测从哪来

**三个角色必须分开**：

| 角色 | 来源 | 能否含 RTL |
|---|---|---|
| **预期** expected | `timing/diagrams/*.md`（**主**）+ `timing/caselists/*.md` 的 delta 阈值表（**交叉校验**） | ❌ 绝不能 |
| **实测** observed | **仿真轨迹**：`verilator_cosim.sh` → `sim.log` 的逐拍事件 | 它本身就是被测对象 |
| **归因** why | 读 RTL 源码 | ✅ 仅在出现差异时解释 |

### 4.1 预期为什么以 diagram 为主

| 材料 | 提供什么 | 粒度 |
|---|---|---|
| **diagram** | 每例的 `T1..T8` 逐拍表（单元格 = `IB` / `RSx` / `ISQ Wait` / `SL` / `WB` / `C`）+ 边界散文（"P3 at T4, P4 at T5, ARF-ready at T6"） | **逐拍**，可直接对照 |
| **caselist** | ① 第 40 行的 `Producer latency / P3 delta / P4 delta / ARF boundary delta` 表 ② 每例的 delta→机制标签 ③ 每例的指令（决定跑哪些测试） | 阈值 / 枚举 |
| **K-map** | ready-source 组合的完备性 | 不涉拍数 |

**拍数预测确实主要在 diagram 里** —— 它是唯一给出"每拍每条指令在哪"的材料。

### 4.2 阈值表写成 **L 参数化**，不是幻数清单

8 月 caselist 把 latency 写死成**公司内部算子**的值（ALU 1 / MUL 3 / **DIV 8** / **LOAD 2** / JALR 3）。
但**我们的 FU 是外网生成的，性能不必与公司内部算子相同** —— 所以这串数字对我们**没有约束力**；
它们后来都被 `latency_bench/Latency_Report.md` 的**实测**取代（见下表，程序里的唯一副本是
`timing/latency_table.py`）。

真正有约束力的是**结构**：整张 caselist 由**单个参数 `L`**（FU 的 `issue_valid → result_valid` 延迟）唯一生成：

| 由 L 导出 | 公式 |
|---|---|
| P3 delta（bypass 发布） | **L + 1** |
| P4 delta（commit） | **L + 2** |
| ARF boundary delta | **L + 3** |
| 枚举范围 | **0 .. L+3**（共 L+4 条 case） |
| 机制阶梯 | `0`=overlay；`1..L`=wait_for_p3（L 条）；`L+1`=p3_capture；`L+2`=p4_capture；`L+3`=arf_read |

**对现表逐行验证**：

下表用**实测值**（`L` 列即 `Latency Report` 的测量结果）：

| 家族 | L | P3=L+1 | P4=L+2 | ARF=L+3 | 枚举 0..L+3 | 应有 case | 8 月 caselist | 一致 |
|---|---:|---:|---:|---:|---|---:|---:|---|
| ALU | 1 | 2 | 3 | 4 | 0..4 | 5 | 5 | ✅ |
| MUL | 3 | 4 | 5 | 6 | 0..6 | 7 | 7 | ✅ |
| DIV | **4** | **5** | **6** | **7** | **0..7** | **8** | 12（旧值 8） | ❌ **实测推翻旧值，见 §4.6** |
| **LOAD** | **3** | **4** | **5** | **6** | **0..6** | **7** | **6** | ❌ **差 1 条，见 §4.6** |
| JALR（只作 consumer）| 取生产者的 L（MUL ⇒ 3）| 4 | 5 | 6 | 0..6 | **7** | 7 | ✅ |
| **合计** | | | | | | **34** | **37** | ❌ = DIV 与 LOAD 两处差异 |

**⇒ `L` 是唯一的自由参数；`L` 一变，枚举范围与 case 数都跟着变。**

**8 月 caselist 的 LOAD 写的是 `L=2`（6 条 case），与 RTL 不符 —— 应为 `L=3`（7 条）。** 详见 §4.6。
**同一份 8 月 caselist 的 DIV 写的是 `L=8`（12 条），实测为 `L=4`（8 条）。** 两处差异合计使单操作数
从 37 条变为 **34 条**（JALR 家族同时由"JALR 作生产者"改为"只作 consumer、取生产者 L"，条数 5 → 7）。

**两条规矩**：

1. **`L` = 指令在 FU / Cache 里占用的拍数**，等价于 FU 边界的 `issue_valid → result_valid`。
   ⛔ **不得从"dispatch → bypass 的距离"反推** —— 因为 `P3 delta = L+1` 里的 "+1"
   正是 dispatch→issue 那一段；反推会让公式退化成**恒真式**，什么都测不出来。
2. **`L` 一变，枚举范围跟着变、case 数量跟着变** —— 不只是改数字，要**增删 case**。

### 4.3 判定怎么做

```text
预期 = diagram 逐拍时间线（主）  ⊕  caselist 阈值表（交叉校验）
实测 = sim.log 逐拍事件（P1 派发 / P3 发射 / P4 提交）
判定 = 人（METHOD.md §7 Step 6）
```

每条 case 比对三项：

1. `delta_measured` ↔ diagram 该例两行的 **T 槽位差**
2. `behavior_observed` ↔ diagram 的**单元格状态序列**（并与 caselist 的机制标签对照）
3. 生产者 P3 / P4 落点 ↔ diagram 散文给出的边界（如 "P3 at T4, P4 at T5"）

### 4.4 ⛔ RTL 源码只能"预筛"和"归因"

**不允许**用 RTL 复算出的数值生成预期，更不允许拿它**反推修改** diagram / caselist 的数值 ——
那等于让运动员自己报成绩，评估就失去意义。

预筛与预期不一致时，正确动作是：

```text
记录差异 → 跑仿真确认真实行为 → 由材料所有者判断是否修订规格
                                    （不得由 RTL 反推）
```

### 4.5 已做的预筛（仅记录，**不作判据**）

| 家族 | 8 月写死的值 | RTL 源码 nominal | 实测（`Latency Report`）| 状态 |
|---|---|---|---|---|
| ALU | 1 | `alu_simple.sv`：结果寄存一拍 | 1 | ✅ 一致 |
| MUL | 3 | `mul_simple.sv`：`issue at T, request_valid at T+3` | 3 | ✅ 一致 |
| DIV | 8 | `div_simple.sv`：倒数硬编码 `cnt <= 2`，无 module parameter | **4** | ❌ **旧值被推翻** |
| LOAD | 2 | `g3_lsu_iface.sv` → 外部 LSU 握手 | **3** | ❌ **旧值被推翻，见 §4.6** |
| JALR | 3（当作 producer）| 走 `alu_simple`（ALU0/BRU） | 只作 consumer，取生产者 L；自身 link=1、redirect=2 | ✅ **口径已改** |

⚠️ delta 是**动态量**（dispatch→dispatch，含 ISQ 占用、组冲突、bypass 命中），
静态阅读只覆盖 no-blocker 路径，**不能替代仿真实测**。

### 4.6 LOAD 的 `L` = **3**（已定案，附 RTL 证据）

**结论：8 月 caselist 的 LOAD `L=2` 是错的，应为 `L=3`。**

#### 依据（按 Cache HAS 作者的更正口径）

> ⚠️ **我最初的推导被作者更正了。** 我曾说"CDB 有一个呈现寄存器、多占一拍"，
> 作者指出：**第三拍是 load-data arbiter 与 CDB FIFO 这两块组合逻辑本身占有的**，
> **没有额外的流水寄存器**。
> **结论（3 拍）双方一致**，机制叙述以作者为准 → Cache HAS 已按此更新为 `V1.0 rev.1`。

**逐拍**（Cache HAS `V1.0 rev.1` §3.1 的表述）：

```text
拍 1      AGU                          ← BE issue fire
拍 2      L1 D cache
拍 3      load-data arbiter + CDB FIFO  （两块组合逻辑共同占用这一拍，无额外流水寄存器）
拍 4 起   BE 即拿到 load data
```

**⇒ 从发射到 BE 可见 = `3` 拍，`L = 3`**（不是 2）。

**`LSU_LOAD_PIPE_STAGES = 2`** 只覆盖拍 1–2（AGU + D cache），**不含拍 3**，
所以它不是 BE 可见延迟。

#### 为什么"占用 = L"在这里同样成立

| 家族 | 占用（拍） | `issue→result`（拍） | 一致 |
|---|---|---|---|
| ALU | 1 | 1 | ✅ |
| MUL | 3 | 3 | ✅ |
| **LOAD** | **3**（AGU / D cache / arbiter + FIFO） | **3** | ✅ |

**⇒ 「`L` = 指令在 FU / Cache 里占用的拍数」是普适定义。**
8 月 caselist 的 LOAD=2，是把 LDA 当成透明通道、**漏算了 CDB 那一级寄存器**。

#### 受影响的面

| 项 | 8 月 caselist | 修正后 |
|---|---|---|
| LOAD `L` | 2 | **3** |
| P3 / P4 / ARF delta | 3 / 4 / 5 | **4 / 5 / 6** |
| 枚举 | `0..5` | **`0..6`** |
| LOAD case 数 | 6 | **7** |
| 总 case 数 | 37 | **38** |

#### 📌 Cache HAS 已按作者口径修正

| 位置 | 原文 | 处置 |
|---|---|---|
| 第 38 行 | "A D-cache hit that needs no merge returns in **two cycles**" | ❌ 只数到拍 2（AGU + D cache），**漏掉拍 3** → 已改为 **3 拍**（无 merge）/ **4 拍**（需 merge） |
| 第 56 行 | `LSU_LOAD_PIPE_STAGES` = **2** | ❌ 同上 → 值**保留 2**（与 RTL 常量一致），**描述改为"只覆盖拍 1–2"** |
| 第 212 行 | `dc_ld_arb` "**combinational** output" | ⚠️ 只描述 `dc_ld_arb` 内部，未说明它还与 CDB FIFO 共占第三拍 → 已补 Timing 条 |
| 第 217 行 | `dc_cdb` "presents the **head entry** to BE" | ⚠️ 未说明时序 → 已补 Timing 条 |

> **作者更正了我的机制推导**（见上方）：第三拍是 arbiter 与 CDB FIFO **两块组合逻辑共同占用**，
> 不是"多了一级呈现寄存器"。**"3 拍"这个结论双方一致**，HAS 按作者的措辞写。

**口径提醒**：第 38 行原有的 2 / 3 数的是**拍 1–2 / 拍 1–3**；我们的 `L` 是
**从发射到 BE 可见的拍差** = 3。两者口径不同，见 §4.2 规矩 1。

#### 待办

| # | 事项 | 状态 |
|---|---|---|
| 1 | 用**观测面**测 G3 的 `isq_g3_issue_valid` → lane-3 写回事件的拍差，应得 **3**；同法测 ALU（应得 1）、MUL（应得 3）作方法自检 | ⏳ |
| 2 | ⛔ **不要用 latency ELF 报的"latency"数字来定 `L`** —— 该数字**自带口径**，而 ALU / MUL 恰好"占用 = 拍差"，**根本标定不出它用的是哪一种** | 规矩 |
| 3 | latency ELF 的真正用途：确认「不考虑 cache miss 时 `L` 是**常量**而非变量」 | ⏳ |
| 4 | 修正 Cache HAS 的 3.1 / 3.2 / 6.7 | ✅ **已做**（作者复核后定稿：`3 拍` 为**下界**，前提是条目成为 CDB head） |
| 5 | ~~修正 cache agent 的 load done 时刻~~ → **作者确认不需要改**（agent 只保证行为正确性，不承担性能） | ✅ **已回退** |
| 6 | 测量时**规避 G0 / G1 的 lane 仲裁** —— 否则 `L` 会被量成"真值 + 仲裁等待" | 规矩（见下） |
| 7 | ~~静态推算 DIV 的 `L = 4`，待实测确认~~ → **实测确认为 4**，caselist 已改为 8 条 | ✅ **已闭环** |
| 8 | 测 LOAD 时**规避 CDB FIFO 的呈现排队** —— 否则 `L` 会被量成"3 + 排队等待" | 规矩（见下） |

#### DIV 的 `L = 4`：静态推算 → **实测确认**（已改参数）

**原 caselist 写 `DIV L = 8`（12 条 case）。RTL 静态推算给出 `L = 4`，随后由
`latency_bench/Latency_Report.md` 实测确认为 4，caselist 已改为 8 条。**

**RTL 事实**：

- `fu/div_simple.sv` **没有任何 module parameter**；第 113 行注释写着
  "Deliberately not a module parameter"。倒数是**硬编码**的：`cnt <= 2'd2`（第 299 行），
  `logic [1:0] cnt`（2 bit，第 138 行）。
- `top/backend_top.sv:1312` 的 `div_simple u_div_simple (…)` **没有任何 parameter 覆盖**
  （也没得覆盖）。

**逐拍推算（用 MUL 校准）**：

| | 计数器 | accept 时置 | `cnt==0` 分支执行于 | `request_valid` 可见于 | 与注释一致？ |
|---|---|---|---|---|---|
| MUL | `logic cnt`（1 bit） | `cnt <= 1` | T+2 | **T+3** | ✅ header："issue at T, `request_valid` at **T+3**" |
| **DIV** | `logic [1:0] cnt` | `cnt <= 2` | **T+3**（代码自称 "Cycle 3"） | **T+4** | ✅ 自身注释："`wb_q` is a register, so `request_valid` rises **the cycle after** `cnt` reaches 0" |

**⇒ 规则：`cnt==0` 分支执行后一拍出 `request_valid`。⇒ DIV 的 `L = 4`。**

**已落实**：P3 / P4 / ARF = **5 / 6 / 7**，枚举 `0..7`，DIV **8 条 case**（原 12），
单操作数总数 **34**（原 37）。

**⛔ 暂不改的理由**：`div_simple` 看起来是**行为占位模型** —— 组合算出 `div_result`、
倒数只有 2 bit、自身注释用 "**N ≥ 1** cycles" 而不给具体值。
若它将来被**外网生成的真实除法器**替换，`L = 4` 就作废。
（`mul_simple` 的 3、`fpu_simple` 的 1 有同样的性质。）

**已完成**：`latency_bench/Latency_Report.md` 用 ALU(1) / MUL(3) / LOAD(3) 三个已知点先标定口径，
再读 DIV，实测确认 **`L = 4`**。测试口径与三个已知点一致，未重蹈 LOAD 的覆辙。

#### ⚠️ 由第 5 项引出的两件事

**① LOAD 不能在 `rtl_v1` 上标定。**
`rtl_v1` 后面接的是 `cache_agent`，它的返回时刻由 **agent 自己的延迟参数**算出来
—— 拿它"测"LOAD 延迟是**循环论证**。

**② 裁定：latency 标定用 `rtl_full`（FE + BE + Cache 完全体），一次跑完、中途不换 DUT。**
理由：一批 case 里 LOAD 与其它指令**混在一起测**，用完全体就能一次拿到**所有**相关指令的
latency，中途不必切 DUT。
（我先前建议的 `rtl_cache` 虽然也接真实 cache，但会让"latency 测试"与"delta 判定"分属两个 DUT，
反而不如 `rtl_full` 干净。**以 `rtl_full` 为准。**）

**③ `cache_agent` 的定位：只负责"行为正确性"，不承担性能标定。**
**Cache 作者已确认：agent 不需要改。** 唯一要保证的是**能正确返回 load 的 data**（功能正确）。
（我此前给 agent 加过 `CDB_PRESENT_CYCLES`，**已回退**。）

**④ 一条仍然成立的提醒**：`rtl_v1` 的 LOAD 返回时刻由 `cache_agent` 决定，所以
**「跑在 `rtl_v1` 上的 LOAD delta」不能当作真 cache 的行为来判定**
（`delta` = P1 派发 → P3 发布，而 P3 发布时刻正由 agent 决定）。
这一点与 agent 改不改无关 —— 若要判定 LOAD 家族，就该用真实 cache（`rtl_cache` / `rtl_full`）。

#### ⚠️ 测量陷阱（两条）

**陷阱 1 —— G0 / G1 的 lane 仲裁会污染量到的 `L`**

量 `isq_gX_issue_valid → exec_valid[X]` 时，**G0 / G1 会把仲裁等待算进去**：

- G0 的三个 FU（`alu_simple` ALU0/BRU、`csr_unit`、`div_simple`）共享 `p3_arbiter_G0`；
  G1 的两个（`alu_simple` ALU1、`mul_simple`）共享 `p3_arbiter_G1`。
- 仲裁每拍只让一个赢；**输家置 `loser_hold`**，而它的 `FU_ready = !loser_hold`
  （见 `src/core/be_rtl_v1/fu/alu_simple.sv:29-31` 的注释），
  所以输家接不了新指令、自己的完成请求要**保持到仲裁成功**。
- ⇒ 量到的是 "FU 自身延迟" **加上** "仲裁等待"。
- **G2（`fpu_simple`）/ G3（`g3_lsu_iface`）没有仲裁**（BE HAS 第 226 行：G2、G3 直接驱动各自的
  lane），所以这两条不受影响。

**规避办法（二选一或都做）**：

1. **用无竞争的 case** —— 同一组、同一时刻只有一条在飞
   （8 月 diagram 的标称值 ALU T4 / MUL T6 就是无竞争情形）；
2. **终点量到 FU 自己的输出** —— G0 / G1 量 `request_valid`，G2 / G3 量 `writeback_valid`，
   绕开 lane 仲裁。

**否则 ALU / MUL / DIV 的 `L` 可能被量成"大于真值"** —— 而自检（ALU=1、MUL=3）正好能抓到这个错误。

**陷阱 2 —— CDB FIFO 的呈现顺序会推迟 LOAD 的 `L`**

Cache HAS `V1.0 rev.1` 把 load 延迟写成**下界**：

> "visible to BE **at the earliest** three cycles … **provided the new entry is the CDB head**"；
> "otherwise **FIFO ordering delays presentation**"（§3.1 / §6.7）

即 `L(LOAD) = 3` 成立的前提是：**这条 load 的条目一进 CDB FIFO 就成为 head**。

- CDB 是终端状态 FIFO（`dc_cdb.sv`，`CDB_N = 16`），每拍**只呈现 head 一条**；
  条目在 E3 之后的时钟沿被捕获，head 读出是组合的。
- 若同期还有别的完成排在前面（另一条 load 的 done、ISB store-commit done、E3 exception…），
  这条 load 会被**推迟呈现** ⇒ 量到的 `issue → lane-3 写回` **> 3**。
- 与陷阱 1 同类：**完成事件排在别人后面**。

**规避**：用**"单条 load 在飞"**的 case（同期不要有其它完成事件）。
**否则 LOAD 的 `L` 会被量成"大于 3"** —— 自检（LOAD=3）能抓到。

> **教训**：这一处我和用户来回争了多轮，**根因是一直在拿 HAS 的散文推数字**。
> 上述结论只有一条依据 —— **读 RTL**。已把这条写进 `METHOD.md` §9.7。

**产出**：一张「**diagram 预期 vs 仿真实测**」对照表 → 明确哪些家族可原样保留、哪些需要由材料所有者修订。

### 4.7 旁路路径：预期**有 RTL 依据**（不写进 diagram）

两张 diagram 头部新增的 `## Bypass paths, and where they can be consumed` 一节声明了三件事。
**声明本身是"预期"，必须在 diagram 里；它的依据属于"归因"侧，所以记在这里**（§4 规定预期里不得含 RTL）。

| 声明 | RTL 依据 | 结论 |
|---|---|---|
| **P3 bypass 只在发布那一拍有效**，P1 可在**同拍**把它捕进新 payload | `top/isq_payload_assembly.sv`：**纯组合、无 clk/rst**；输入含 `bypass_data [NUM_LANES]`（L85）与 `commit_data [ISSUE_WIDTH]`（L78）；源选择用 `sel_arf` / `sel_commit` / `sel_bypass`（L143–145），**由 `dependency_check` 用同拍的 `bypass_valid`/`bypass_tag` 生成**（头注释：本层"does no busy / tag compare at all"） | ✅ 同拍捕获**是 RTL 实现的** |
| 同一拍里**驻留**的条目可走 **P3→P2** 直接喂 FU | `p2p3/FU_input_mux.sv`：`bypass_data`/`bypass_valid`/`bypass_tag`（L42–47），`hit[b] = bypass_valid[b] && (rsX_wait_tag == bypass_tag[b])`（L71），`fu_rsX_data = bypass_data[b]`（L107）；注释写明是 "**this cycle's** p3 bypass lanes" | ✅ 同拍 |
| **P2 MUX 从不吃 P4 commit CDB** | 同上，`FU_input_mux` **输入里没有 `commit_data`** | ✅ 证实 |
| 4 条 bypass lane = 四个组的 P3 发布 | `top/backend_top.sv` L499–501 `lane_bypass_valid/tag/data [NUM_LANES]`，由 `arbG0_*`/`arbG1_*`（两个 P3 arbiter）+ `g2fu_*` + `lsuif_*` 汇聚；`commit_data` 由 `p4/Buffer` 驱动 | ✅ |
| **P3 命中但当拍发射不了 → 数据 latch 成 `Stored Ready`**（这是"`P4→P2` 没连接也不出洞"的支点） | `p2p3/ISQ_Group0..3.sv`，**四组各一份**：`assign bypass_capture = isq_valid && !global_flush_late && !issue_fire && (fast_ready_rs1 \|\| fast_ready_rs2)`（L217–219）；其中 `fast_ready_rsX = !entry_rsX_ready && rsX_bypass_hit`、`rsX_bypass_hit = OR_b(bypass_valid[b] && bypass_tag[b] == entry_rsX_wait_tag)`（L153–166）；动作为 `entry_rsX_ready <= 1'b1` / `entry_rsX_data <= rsX_data`（L348–362，数据取自 `FU_input_mux` 的输出）。注释："A cycle that issues does not capture" | ✅ RTL 实现 |

**推论：`P4 → P2` 未连接不是漏洞，是冗余路径的省略。** 按 dependent 的 P1 落在哪一拍穷举：

| dependent 的 P1 落在 | 用的路径 | 到 P4 拍时还缺源吗 |
|---|---|---|
| P3 拍（`delta` = L+1） | `P3→P1` 捕获 | 不缺 |
| 早于 P3 拍（`delta` ≤ L） | P3 拍走 `P3→P2`：能发则当拍发射；不能发则 **`bypass_capture` latch** | 不缺 |
| P4 拍（`delta` = L+2） | `P4→P1` 捕获 | 不缺 |
| 晚于 P4（`delta` = L+3） | ARF | 不缺 |

P3 与 P4 **相邻** ⇒ 不存在"介于"的落拍 ⇒ 四种情况**穷尽** ⇒ **没有一种需要 commit CDB 去喂 P2**。

**⚠️ 支点是 `bypass_capture`，不是 `P3→P1` 单独**：若没有那个 latch，"P3 拍匹配到但 FU 忙"就会顺延到
P4 拍 —— 那时才形成"resident 且缺源、而源只在 commit CDB 上"，**正需要一条并不存在的 `P4→P2`，就会 stall**。

**⚠️ 表述教训（同 §9.7）**：我最初把"P3→P1 同拍有效"当成已知事实说出来，**依据其实只是材料自己的措辞** ——
而材料正是被审计的**预测**。**用预测去证明预测是循环论证。**
凡"能不能"类的事实，**要么读 RTL、要么实测**，不能引材料的散文。

**推导出的结构（也是 delta 阶梯存在的原因）**：每条总线只有「**一拍窗口**」，错过不等 → 所以
dependent 的 P1 落在哪一拍，决定了它用哪条窗口：P3 拍 → `p3_capture`；P4 拍 → `p4_capture`；再晚 → `arf_read`。

---

### 4.8 填充物与派发组绑定：预期**有 RTL 依据**（不写进 caselist）

caselist 新增的 `## Filler and Program Construction` 一节声明了"填充物不会挤走 case"。
按 §4 的分工，**声明留在 caselist（预期侧），依据记在这里（归因侧）**：

| 声明 | RTL 依据（`src/core/be_rtl_v1/p1/dispatch_logic.sv`） | 结论 |
|---|---|---|
| 整数 ALU 填充可被放到 `G0` 或 `G1`，冲突时**让位** | 灵活槽：`slot_ISQGroup[0] = <flex> ? (isq_free_for_dispatch[GRP_G0] ? GRP_G0 : GRP_G1) : fixed_group[0]`（L384）；slot1 追加 `&& !slot0_takes_G0`（L402–406） | ✅ |
| case 指令拿到**它自己该拿的组** | 固定路由表（L338–343）：`ROUTE_MUL → G1`、`ROUTE_FPU → G2`、`ROUTE_LSU / ATOMIC / FENCE → G3`、`default → G0` | ✅ |
| 组忙 ⇒ **该槽本拍不被接收**（所以挤不走 case） | `accept[0]` 含 `isq_free_for_dispatch[slot_ISQGroup[0]]`（L391）；`accept[1]` 含同一项 **且** `groups_distinct`（L409–414） | ✅ |
| 同拍两条**不能同组** | `groups_distinct = (slot_ISQGroup[1] != slot_ISQGroup[0])`（L409） | ✅ |
| **case 指令必须落在 slot 0** | slot1 的灵活选择**显式依赖 `slot0_takes_G0`**（L402–406）⇒ 若灵活槽先占了 slot0 的 `G0`，slot1 的 `G0` 固定指令 `groups_distinct = 0` ⇒ 本拍不收 ⇒ **顺延一拍** | ✅ 这就是 caselist 那条 bullet 的由来 |
| **每拍稳定派发 2 条** | —— | ⚠️ **无 RTL 依据，只能实测**（已写为该节的 assumption） |

**⇒ 前五行有 RTL 依据；最后一行是假设。** 两者都不写进 caselist（§4：预期侧不含 RTL）。

---

## 5. 顺带发现（需要你决策）

### 5.1 `lsu_bridge` → `g3_lsu_iface`（✅ 已执行）

统一方向：**跟随 RTL 用 `g3_lsu_iface`**（改文档，不改代码）。

| 已改 | 规模 |
|---|---|
| `OpenRio:docs/modules/lsu/lsu_bridge.md` → `g3_lsu_iface.md` | 改名 + 2 处 |
| `OpenRio:docs/modules/top/backend_top.md` | 38 处 |
| `OpenRio:docs/modules/interface_definitions.md` | 1 处 |
| `OpenRio:docs/Cache/or_cache_has_V1.0.md` | 1 处 ← **超出 module_v4 范围**，为一致性一并改 |
| `openrios:work/or-be-draft/modules/modules_v4/` 同 3 个文件 | 41 处 + 改名 |
| RTL / filelist / HAS | **未动**（本来就是 `g3_lsu_iface`） |

两侧 `diff -rq` 已验证一致。

> ⚠️ **仍有 `lsu_bridge` 残留（不在本次范围，待决策）**：
> `openrios:work/or-be-draft/rtl/rtl_v1/` —— 这是 openrios 里一份**独立的 RTL 草稿副本**，
> 6 个文件用 `lsu_bridge`（含文件名 `lsu/lsu_bridge.sv`，另 `top/backend_top.sv` 10 处、
> `p2p3/ISQ_Group3.sv` 4 处、`fu/fpu_simple.sv` 1 处、`p4/CompletionScoreboard.sv` 1 处）；
> 以及 `module_Human_Readable/00_改写规范与CVA6风格参考.md` 4 处。

### 5.2 caselist 现在有两份

`openrios:work/or-be-draft/timing/caselists/`（原始，8/26）与
`OpenRio:verification/orbe_bt_env/perf_eval/timing/caselists/`（本次粘贴，将作为工作面）。
两份内容当前相同，但**已构成潜在漂移**：改了一边不会自动同步另一边。
