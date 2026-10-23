# 材料修订方案：caselist 与 timing diagram（INT 单操作数依赖）

> **2026-10-22 更新**：内网算子数据 `latency_bench/result.md` 已取代本方案的 DIV/LOAD 值
> （DIV 4→8, LOAD 3→2）。本文件保留为历史记录；当前值以 `latency_table.py` 为准。

**状态**：**已执行**（2026-10-09）。caselist 与 diagram 均已按本方案改完，提交 `fabff86`；
阶段对照表（§3#2）与 golden 锚点（§3#3）已补。
**依据**：`perf_eval/latency_bench/Latency_Report.md`（102 例实测，三个自检点全中）
**决策**（2026-10-09 用户裁定）：

1. **范围** = INT 单操作数依赖；**不含** FP / AMO / LR / SC
2. **JALR 取 `L = 1`**（link 口径）
3. **采纳"组归属"约束**（同组不可能同拍派发 ⇒ 同组无 `delta_0`）

---

## 0. 一句话

把 5 个家族的 producer latency 从 8 月旧值换成**实测值**，由此重算 delta 表与 case 数：
**38 条 → 32 条**；并把一条一直**只写在散文里**的结构约束**显式化**。

**目标状态**：

| 家族 | `L` | P3 | P4 | ARF | 枚举 | case 数 | 8 月 |
|---|---:|---:|---:|---:|---|---:|---:|
| `ALU_to_ALU` | 1 | 2 | 3 | 4 | 0..4 | **5** | 5 |
| `MUL_to_ALU` | 3 | 4 | 5 | 6 | 0..6 | **7** | 7 |
| `DIV_to_ALU` | **4** | 5 | 6 | 7 | 0..7 | **8** | 12 |
| `LOAD_to_ALU` | **3** | 4 | 5 | 6 | 0..6 | **7** | 6 → 7（已定） |
| `JALR_to_ALU` | **1** | 2 | 3 | 4 | 0..4 | **5** | 7 |
| **合计** | | | | | | **32** | 38 |

---

## 1. 实测依据（只列与本方案有关的）

| 家族 | 8 月 caselist | **实测 L** | 证据 | 处置 |
|---|---:|---:|---|---|
| ALU | 1 | **1** | 14 例全为 1（G0 lane0 / G1 lane1 各测） | 不变 |
| MUL | 3 | **3** | 5 例全为 3 | 不变 |
| DIV | 8 | **4** | 8 例全为 4 | **改** |
| LOAD | 2 → **3**（caselist 已改） | **3** | 9 例全为 3 | 已改，**图待改** |
| JALR（link 口径） | 3 | **1** | `[ISQ_FIRE] cycle=19 → [FU_WB] cycle=20  rd=PC+4` | **改** |

**方法可信度**：自检三点（ALU=1 / MUL=3 / LOAD=3）全中才采信；且实测与"读 RTL 逐拍推算"在
**DIV=4** 上互相印证，**LOAD=3** 独立证实了 Cache HAS `V1.0 rev.1`。

> **两个不进本方案的量**
> - JALR 的 **`redirect 就绪 = 2`**（`[ISQ_FIRE] → [BE][REDIRECT]`）：控制流事件，
>   **没有"rd 值到达 consumer"**，套 `P3/P4/ARF` 枚举没有意义 → 仅留档
>   （`latency_results.csv` 的 `redirect_cycle` / `L_redirect`）。
> - FP / AMO / LR / SC（按决策 1 排除；实测值见报告 §0，将来要扩范围时直接取用）。

---

## 2. 参数化公式（**不变**）

```text
P3 delta = L + 1
P4 delta = L + 2
ARF boundary delta = L + 3
枚举范围 = 0 .. L+3                共 L+4 条
机制阶梯 = 0:overlay | 1..L:wait_for_p3 | L+1:p3_capture | L+2:p4_capture | L+3:arf_read
```

`delta` 的定义、命名规则 `<Producer>_to_<Consumer>_delta_<n>` 均**不变**。

---

## 3. ⚠️ 新增规矩：`delta_0` 要求 producer 与 consumer **不同组**

**约束的推导**：

- ISQ **每组只有一格** ⇒ **同一组每拍最多派发一条**。
- ⇒ 若 producer 与 consumer **同组**，两者派发拍至少差 1 ⇒ **`delta_0`（`overlay`）不可达**。
- ⇒ **`delta_0` 行必须写明"producer 在 Gx，consumer 路由到 Gy（x ≠ y）"。**

**好消息：现有 5 条 `delta_0` 全部已满足**（组归属都写在 Behavior 列的散文里）：

| `delta_0` 行 | producer 组 | consumer 组 | 跨组 |
|---|---|---|---|
| `ALU_to_ALU_delta_0` | G0 | G1（"routes to G1"） | ✅ |
| `MUL_to_ALU_delta_0` | G1 | G0 | ✅ |
| `DIV_to_ALU_delta_0` | G0 | G1 | ✅ |
| `LOAD_to_ALU_delta_0` | G3 | G0/G1 | ✅ |
| `JALR_to_ALU_delta_0` | G0 | G1 | ✅ |

**⇒ 本规矩不删改任何一行，只做两件事**：

1. 在 caselist 里把它**提升为一条显式规矩**（放在 "Delta Meaning" 之后）；
2. 每张 case 表**加一列** `G (producer → consumer)`，把"组"从散文变成字段。

**边界说明**：`ALU_to_BRU`（ALU 在前、JALR 在后）确实没有 `delta_0`，
但 v2 caselist **有意不枚举** `*_to_BRU`（Notes 第 175 行）—— 这不是遗漏，是范围外。

### 3.1 为什么以前没把它当成规矩（方法漏洞）

- 这条约束**只以散文形式存在于每行 Behavior 列**（"dependent ALU can route to G1"），
  从没被提炼成规矩或字段。
- 而 §4.2 阶段的"验证"是**算术自洽**：证明"`L` 参数化能复现 37 条"。
  **算术自洽证明不了结构可达** —— 条数对得上，不排除某一条物理上不可达。
- 且 `delta` 定义在**派发（P1）**，讨论时却常用**发射（issue）**的语言，两个口径混着说，
  掩盖了"同组一格"这条约束的作用点。

> **教训（已记入 METHOD §9.7 体系）**：**材料级校验必须同时做"算术自洽"与"结构可达"两件事。**

---

## 4. caselist 改动（`caselists/INT_single_operand_dependency_caselist_v1.md`）

### 4.1 头部

| 位置 | 现状 | 改为 |
|---|---|---|
| 总数行（L33） | `ALU 5 + MUL 7 + DIV 12 + LOAD 7 + JALR 7 = 38` | `ALU 5 + MUL 7 + DIV 8 + LOAD 7 + JALR 5 = **32**` |
| Delta Meaning 表（L46-52） | DIV `8 / 9 / 10 / 11 / 0..11`；JALR link `3 / 4 / 5 / 6 / 0..6` | DIV `**4** / **5** / **6** / **7** / **0..7**`；JALR `**1** / **2** / **3** / **4** / **0..4**` |
| LOAD 修订注（L36-40） | 用了"**CDB presentation register**"的说法 | 改为 Cache HAS `V1.0 rev.1` 的措辞（**拍 3 = arbiter + CDB FIFO**；3 拍为**下界**，前提是条目成为 CDB head） |
| JAL/JALR note（L54-56） | "performance report measures taken JAL/JALR at about 3 cycles… enumerates 0..6" | 改为：**依赖公式用 link 口径 `L = 1`**；报告给的 3 是 **taken/redirect** 口径（本版实测 = **2**），**不进依赖公式** |
| 新增 | — | §3 的**组归属规矩** + 各表的 `G (producer → consumer)` 列 |

### 4.2 `DIV_to_ALU`：12 → 8 条

| 新 delta | 机制 | 来源 |
|---:|---|---|
| 0 | `overlay` | 保留 |
| 1–4 | `wait_for_p3` | 保留（原 1–4） |
| 5 | `p3_capture` | 原 `delta_9` 改名 |
| 6 | `p4_capture` | 原 `delta_10` 改名 |
| 7 | `arf_read` | 原 `delta_11` 改名 |

**删除** 原 `delta_5` / `delta_6` / `delta_7` / `delta_8`（4 条）。

### 4.3 `LOAD_to_ALU`：6 → 7 条（caselist 已改完，此处仅存对照）

| 新 delta | 机制 | 来源 |
|---:|---|---|
| 0 | `overlay` | 保留 |
| 1–3 | `wait_for_p3` | 1、2 保留；**3 为新增** |
| 4 | `p3_capture` | 原 `delta_3` 改名 |
| 5 | `p4_capture` | 原 `delta_4` 改名 |
| 6 | `arf_read` | 原 `delta_5` 改名 |

### 4.4 `JALR_to_ALU`：7 → 5 条

| 新 delta | 机制 | 来源 |
|---:|---|---|
| 0 | `overlay` | 保留（G0 → G1，跨组 ✅） |
| 1 | `wait_for_p3` | 保留 |
| 2 | `p3_capture` | 原 `delta_4` 改名 |
| 3 | `p4_capture` | 原 `delta_5` 改名 |
| 4 | `arf_read` | 原 `delta_6` 改名 |

**删除** 原 `delta_2` / `delta_3`（2 条）。

### 4.5 `ALU_to_ALU` / `MUL_to_ALU`

**条数与机制不变**（5 / 7 条），只加 §3 的 `G` 列。

---

## 5. diagram 改动（`diagrams/INT_single_operand_dependency_diagram.md`）

现状 **37 个 `## Case N`**（ALU 1-5 / MUL 6-12 / DIV 13-24 / LOAD 25-30 / JALR 31-37），
目标 **32 个**（ALU 1-5 / MUL 6-12 / **DIV 13-20** / **LOAD 21-27** / **JALR 28-32**）。

### 5.1 先说清"T 槽位"是什么，以及它为什么必然要改

**"T 槽位" = 逐拍表里"哪条指令 × 第几个 T 列 × 写的是什么状态"那一格。**
例：`Case 13` 的 `div` 行，`T3` 格 = `SL (DIV stg0)`、`T11` 格 = `WB`。

**核对现有四张表可得到一条规律**：producer 的内部阶段占 `T3 … T(2+L)`，**`WB` 落在 `T(3+L)`**。

| case | 现图 | 隐含 `L` | 本次 `L` | `WB` 从 | 挪到 |
|---|---|---|---:|---:|---|---|
| `Case 1` ALU | `SL (ALU0)`@T3、`WB`@T4 | 4−3 = **1** ✓ | 1（不变） | — | — |
| `Case 13` DIV | `stg0…stg7` 占 T3–T10、`WB`@T11 | 11−3 = **8** ✓ | **4** | **T11** | **T7** |
| `Case 25` LOAD | `SL (AGU)`@T3、`L1D`@T4、`WB`@T5 | 5−3 = **2** ✓ | **3** | **T5** | **T6** |
| `Case 31` JALR | `stg0…stg2` 占 T3–T5、`WB`@T6 | 6−3 = **3** ✓ | **1** | **T6** | **T4** |

**⇒ `L` 恰好编码在 T 列里。`L` 一改，被保留的 case 也必须整表重画**：
producer 行左移（`L` 变小）或右移（`L` 变大）、**dependent 行每一格跟着走**、
散文里的边界拍（`P3 at Tn / P4 at Tn+1 / ARF-ready at Tn+2`）随之改写。

**所以本次不是"删几条 + 补个标注"，而是 5 族里 3 族（DIV / LOAD / JALR）全表重画。**

### 5.2 约束怎么改（已获批准）

`CHANGE_IMPACT.md` §3#1 原写"⛔ **只允许改标签**（可补阶段名标注，**不得改动任何 T 槽位、
状态序列、边界拍数**）"。按字面执行，本次修订做不了 —— 因为它把 `L` 的更新也算作"改槽位"。

**该约束的原始目的是"不许把槽位挪到仿真能通过的位置"（即改预测迎合 RTL），这个目的必须保住。**
所以把"禁止"换成**两种槽位变更的区分**：

| 变更种类 | 判定 | 允许？ |
|---|---|---|
| **① 参数驱动的机械重算** —— `L` 按实测更新后，按 `WB@T(3+L)` 规则重画全表 | **规格更新** | ✅ **允许** |
| **② 为对齐某次仿真结果而单独平移某个 case 的槽位** | **改预测迎合 RTL** | ⛔ **仍然禁止** |

**关键差别**：规则是**先由 `L` 算槽位、再看仿真**，不是反过来。核查判据见 §9⑤。

### 5.3 逐族动作

| 家族 | 动作 |
|---|---|
| `ALU_to_ALU`、`MUL_to_ALU` | **不动**（`L` 未变，Case 1–12 原样） |
| **`DIV_to_ALU`** | **全表重画**：内部阶段 `stg0..stg7` → `stg0..stg3`；`WB` T11→**T7**、`C` T12→T8；dependent 行整体左移；边界拍散文改为 `P3 at T7 / P4 at T8 / ARF at T9`。**删** 4 条（原 `delta_5..8`）；原 `delta_9/10/11` 改为 `delta_5/6/7`；Case 序号重排 **13–20** |
| **`LOAD_to_ALU`** | **全表重画**：producer 行在 `L1D` 之后**补一格**（拍 3 = arbiter + CDB FIFO，措辞用 Cache HAS `V1.0 rev.1`）；`WB` T5→**T6**、`C` T6→T7；dependent 行随之右移；边界拍改为 `P3 at T6 / P4 at T7 / ARF at T8`。**新增** 1 条（`delta_3`，`wait_for_p3`）；原 `delta_3/4/5` 改为 `delta_4/5/6`；重排 **21–27** |
| **`JALR_to_ALU`** | **全表重画**：内部阶段 `stg0..stg2` → `stg0`；`WB` T6→**T4**、`C` T7→T5；dependent 行整体左移；边界拍改为 `P3 at T4 / P4 at T5 / ARF at T6`。**删** `delta_2`/`delta_3`；原 `delta_4/5/6` 改为 `delta_2/3/4`；重排 **28–32** |

**每族 `delta_0` 的组归属**必须在图里也写出来（与 caselist 的 `G` 列一致）。

---

## 6. 总数对照

| | 8 月 | LOAD 修正后 | **本方案后** |
|---|---:|---:|---:|
| ALU | 5 | 5 | 5 |
| MUL | 7 | 7 | 7 |
| DIV | 12 | 12 | **8** |
| LOAD | 6 | 7 | 7 |
| JALR | 7 | 7 | **5** |
| **合计** | **37** | **38** | **32** |
| diagram 的 `## Case` 数 | 37 | 37 | **32** |

---

## 7. 不改的东西

- **K-map ×3**：不动（本轮没有 K-map 层面的新事实）。
- **命名规则** `<Producer>_to_<Consumer>_delta_<n>`、**`delta` 的定义**、**机制阶梯**、**参数化公式**。
- `ALU` / `MUL` 两族的**条数与机制**。
- `INT_two_operands_dependency_*`：本轮范围外（见 §8.1）。

---

## 8. 待决项

1. **两操作数材料是否同步**：`INT_two_operands_dependency_caselist.md` 里也嵌了一张 producer 表
   （现有 `MUL result 4/5/6`、`LOAD hit result 4/5/6`，LOAD 已随上次修好）。
   **若它将来补 DIV / JALR 行，须按本方案的 `L` 取值**；本轮是否要一并补？
2. ~~**diagram 的"只允许改标签"约束**要不要按 §5 的建议放宽~~ → **已批准（2026-10-09）**：
   改用 §5.2 的"**① 机械重算 ✅ / ② 迎合仿真 ⛔**"两分法，并加 §9⑤ 的判据。
3. **case ID 改名的影响**：`delta_n` 写在 case ID 里，改名会连带改日志目录名 /
   脚本里的过滤模式 —— 确认无外部依赖后再执行。
4. ~~**JALR 的 taken/redirect 口径（=2）是否另立材料**~~ → **已决定不做**（2026-10-09）：
   它是控制流指标，需要另一套 case 结构，本项目不再讨论。实测值只作留档
   （`latency_bench/Latency_Report.md`；CSV 的 `L_redirect` 列）。

---

## 9. 验收方式

```bash
cd verification/or_cosim/perf_eval/timing

# ① caselist 条数必须 = 32
rg -c '^\| `[A-Z]+_to_ALU_delta_[0-9]+`' caselists/INT_single_operand_dependency_caselist_v1.md

# ② diagram 的 Case 序号必须是连续的 1..32
rg -c '^## Case [0-9]+' diagrams/INT_single_operand_dependency_diagram.md
rg -o '^## Case [0-9]+' diagrams/INT_single_operand_dependency_diagram.md | awk '{print $3}' | sort -n | tail -1

# ③ 每族的枚举范围必须等于 0..L+3
#    逐族核对：ALU 0..4 / MUL 0..6 / DIV 0..7 / LOAD 0..6 / JALR 0..4

# ④ caselist 与 diagram 的 case 必须一一对应（同一组 `家族 + delta` 集合）
```

### ⑤ 槽位必须能由 `L` 机械推出（§5.2 的判据）

**逐个 producer 行核对** `WB` 所在的 T 列号：

```bash
# 打出每个 case 的 producer 行，人工核对 `WB` 列号 = 3 + L
rg -n '^\| `(add|sub|mul|div|ld|lw|jalr)' diagrams/INT_single_operand_dependency_diagram.md
```

| 家族 | 期望 `WB` 列 | 期望边界拍散文 |
|---|---|---|
| ALU（`L=1`） | **T4** | `P3 at T4 / P4 at T5 / ARF-ready at T6` |
| MUL（`L=3`） | **T6** | `P3 at T6 / P4 at T7 / ARF-ready at T8` |
| DIV（`L=4`） | **T7** | `P3 at T7 / P4 at T8 / ARF-ready at T9` |
| LOAD（`L=3`） | **T6** | `P3 at T6 / P4 at T7 / ARF-ready at T8` |
| JALR（`L=1`） | **T4** | `P3 at T4 / P4 at T5 / ARF-ready at T6` |

**凡解释不通的槽位移动，一律视为 §5.2 的 ②，退回。**

外加人工核对：

- **每条 `delta_0` 行的 `G (producer → consumer)` 两列必须不同组**（§3）；
- **每个 `delta_n` 的 dependent 行**：其 `SL` 拍应落在 `P3` 拍（`p3_capture`）/ `P4` 拍
  （`p4_capture`）/ 更晚（`arf_read`），与 caselist 的机制标签一致。
