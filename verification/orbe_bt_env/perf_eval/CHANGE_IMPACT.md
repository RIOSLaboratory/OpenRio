# 8 月 timing 材料 → 9 月 golden：改动清单与改造计划

**范围**：`perf_eval/timing/` 下粘贴进来的 8 月材料（2 份 caselist + 2 份 diagram + 3 份 K-map）
**对照基准**：9 月 golden —— `docs/BE/or_be_has_V1.0.md` §5 + `docs/modules/` + `src/core/be_rtl_v1/`

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
| 1 | `diagrams/INT_single_operand_*.md` | 在每例散文里显式写出 **ISQ 驻留 = P2** | 现在只写 "waits resident in ISQ"，没给阶段号；`wait_for_p3` 因此没有阶段归属 |
| 2 | `diagrams/*.md` 头部 | 补一节「阶段对照表」：`IB/RSx/SL/WB/C` ↔ `P0..P4` | 读者不必再猜（我自己就猜错过） |
| 3 | `caselists/*.md` 头部 | 在 `Normative timing sources` 处补上 golden 锚点（OpenRio commit SHA） | 现在写的是 `pending promotion to spec/or-be/`，无法追溯 |
| 4 | `caselists/*.md` 数值 | 与 §4 的复算结果逐条对齐，不一致的出 v2 | 唯一真正的实质风险 |
| 5 | K-maps ×3 | **不动** | §2.3 |

---

## 4. 唯一未决的实质问题：cycle 数值是否随 9 月改动而变

阶段**重编号**不改变 cycle；但如果 9 月的"新架构"同时改了 RTL，**数值就可能变**。这必须实证。

**已从现版代码验到的**：

| Producer | caselist 声明 | 代码证据 | 结论 |
|---|---|---|---|
| ALU | latency 1 | `alu_simple.sv`：结果寄存一拍 | ✅ 一致 |
| MUL | latency 3 | `mul_simple.sv` 注释：**"issue at T, request_valid at T+3"** | ✅ 一致 |
| DIV | latency 8 | `div_simple.sv`：**"N ≥ 1 cycles after issue"**，N 可配置 | ⏳ 待查 `backend_top.sv` 实例化参数 |
| LOAD | latency 2 | `g3_lsu_iface.sv` → 外部 LSU 握手（变长） | ⏳ 口径待定 |
| JALR link | latency 3 | 走 `alu_simple`（ALU0/BRU） | ⏳ 待确认 |

**复算计划**：用 `backend_top.sv` 的 FU 实例化参数 + `mul_simple.sv` / `div_simple.sv` /
`alu_simple.sv` / `g3_lsu_iface.sv`，算出每个家族的 **P3 / P4 / ARF 边界 ladder**，
与 caselist 现表（ALU 2/3/4、MUL 4/5/6、DIV 9/10/11、LOAD 3/4/5）逐行比对。

**产出**：一张「caselist 现表 vs 代码复算」对照表 → 明确哪些家族可原样保留、哪些必须出 v2。

---

## 5. 顺带发现（需要你决策）

### 5.1 `lsu_bridge` 与 `g3_lsu_iface` 的命名漂移

| 位置 | 用的名字 |
|---|---|
| RTL（`src/core/be_rtl_v1/lsu/g3_lsu_iface.sv`，module 名、实例名 `u_g3_lsu_iface`） | `g3_lsu_iface` |
| RTL filelist（`rtl_v1.f:50`） | `g3_lsu_iface` |
| `docs/BE/or_be_has_V1.0.md` §6.5 | `g3_lsu_iface` |
| `docs/modules/`（3 个文件，含 `top/backend_top.md`） | `lsu_bridge` |
| `lsu_bridge` 在 RTL / TB / filelist 中 | **出现 0 次** |

### 5.2 caselist 现在有两份

`openrios:work/or-be-draft/timing/caselists/`（原始，8/26）与
`OpenRio:verification/orbe_bt_env/perf_eval/timing/caselists/`（本次粘贴，将作为工作面）。
两份内容当前相同，但**已构成潜在漂移**：改了一边不会自动同步另一边。
