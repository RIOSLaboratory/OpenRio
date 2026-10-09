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
| 1 | `diagrams/INT_single_operand_*.md` | 在每例散文里显式写出 **ISQ 驻留 = P2**。⛔ **只允许改标签**：可补阶段名标注（`RS0` → `RS0 [P2]`）、可补散文说明；**不得改动任何 T 槽位、状态序列、边界拍数** | 现在只写 "waits resident in ISQ"，没给阶段号；`wait_for_p3` 因此没有阶段归属。**改槽位就变成"改预测去迎合 RTL"** |
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

caselist 第 40 行现在把 latency 写死成**公司内部算子**的值（ALU 1 / MUL 3 / **DIV 8** / **LOAD 2** / JALR 3）。
但**我们的 FU 是外网生成的，性能不必与公司内部算子相同** —— 所以这串数字对我们**没有约束力**。

真正有约束力的是**结构**：整张 caselist 由**单个参数 `L`**（FU 的 `issue_valid → result_valid` 延迟）唯一生成：

| 由 L 导出 | 公式 |
|---|---|
| P3 delta（bypass 发布） | **L + 1** |
| P4 delta（commit） | **L + 2** |
| ARF boundary delta | **L + 3** |
| 枚举范围 | **0 .. L+3**（共 L+4 条 case） |
| 机制阶梯 | `0`=overlay；`1..L`=wait_for_p3（L 条）；`L+1`=p3_capture；`L+2`=p4_capture；`L+3`=arf_read |

**对现表逐行验证**：

| 家族 | L | P3=L+1 | P4=L+2 | ARF=L+3 | 枚举 0..L+3 | 应有 case | 8 月 caselist | 一致 |
|---|---:|---:|---:|---:|---|---:|---:|---|
| ALU | 1 | 2 | 3 | 4 | 0..4 | 5 | 5 | ✅ |
| MUL | 3 | 4 | 5 | 6 | 0..6 | 7 | 7 | ✅ |
| DIV | N | N+1 | N+2 | N+3 | 0..N+3 | N+4 | 12（按 N=8） | ⏳ 待实测 N |
| **LOAD** | **3** | **4** | **5** | **6** | **0..6** | **7** | **6** | ❌ **差 1 条，见 §4.6** |
| JALR | 3 | 4 | 5 | 6 | 0..6 | 7 | 7 | ✅ |
| **合计（DIV 暂按 N=8）** | | | | | | **38** | **37** | ❌ |

**⇒ `L` 是唯一的自由参数；`L` 一变，枚举范围与 case 数都跟着变。**

**8 月 caselist 的 LOAD 写的是 `L=2`（6 条 case），与 RTL 不符 —— 应为 `L=3`（7 条）。** 详见 §4.6。

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

| 家族 | L（8 月写死的值，仅供参考） | RTL 源码 nominal | 状态 |
|---|---|---|---|
| ALU | 1 | `alu_simple.sv`：结果寄存一拍 | ✅ 一致 |
| MUL | 3 | `mul_simple.sv`：`issue at T, request_valid at T+3` | ✅ 一致 |
| DIV | 8 | `div_simple.sv`：`N ≥ 1 cycles`，N 可配置 | ⏳ 待查实例化参数 |
| LOAD | 2 | `g3_lsu_iface.sv` → 外部 LSU 握手 | ⏳ **口径有争议，见 §4.6** |
| JALR link | 3 | 走 `alu_simple`（ALU0/BRU） | ⏳ 待确认 |

⚠️ delta 是**动态量**（dispatch→dispatch，含 ISQ 占用、组冲突、bypass 命中），
静态阅读只覆盖 no-blocker 路径，**不能替代仿真实测**。

### 4.6 LOAD 的 `L` = **3**（已定案，附 RTL 证据）

**结论：8 月 caselist 的 LOAD `L=2` 是错的，应为 `L=3`。**

#### RTL 证据链

| 模块 | 看的是什么 | 结论 |
|---|---|---|
| `src/core/cache_rtl_v1/dc_ld_arb.sv` | 全文只有一个 `always_comb`，无寄存器 | LDA **本身**是组合的 |
| **`dc_cdb.sv:59`** | `if (l_vld[0]) begin q[wp[CDB_PTR_W-2:0]] <= l_ent[0]; wp = wp + 1'b1; end` | **LDA 的结果在时钟沿被写进 CDB FIFO 寄存器** |
| **`dc_cdb.sv:33/35/37`** | `h = q[rptr_q[…]]`；`done_valid_q = hv && !h.is_exc`；`byp_valid_q = hv && !h.is_exc && h.bypass` | 给 BE 的 done / bypass **取自 head 寄存器** |
| `or_cache_top.sv:462-467` | LDA 的 fast 路径输入是 `e3_bytes_q`（E3 寄存器） | LDA 确实在 **E3 拍**工作 |

**逐拍**：

```text
E1  accept/AGU   ← BE issue fire            （Cache HAS 第 95 行）
E2  DCache                                  （第 96 行）
E3  LDA          ──组合──→ 写进 CDB FIFO     （第 97 行；dc_cdb.sv:59）
E4               ←BE 看到 done_valid / byp_valid（dc_cdb.sv:35/37）
```

**⇒ `issue→result` = 3 拍，`L = 3`**（不是 2）。

#### 为什么"占用 = L"在这里同样成立

| 家族 | 占用（级） | `issue→result`（拍） | 一致 |
|---|---|---|---|
| ALU | 1 | 1 | ✅ |
| MUL | 3 | 3 | ✅ |
| **LOAD** | **3**（E1/E2/E3） | **3**（E1→E4，含 CDB 寄存器） | ✅ |

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

#### 📌 发现：Cache HAS 第 38 / 56 行需要修

| 位置 | 原文 | 与 RTL |
|---|---|---|
| 第 38 行 | "A D-cache hit that needs no merge returns in **two cycles**" | ❌ 只数到 LDA，**漏算 CDB 呈现寄存器** |
| 第 56 行 | `LSU_LOAD_PIPE_STAGES` = **2** | ❌ 同上 |
| **第 217 行** | "a terminal-state **FIFO**… presents the **head entry** to BE" | ✅ FIFO head 即寄存器 → 至少 +1 拍，**与 RTL 一致** |
| 第 212 行 | `dc_ld_arb` "**combinational** output" | ⚠️ 只描述 `dc_ld_arb` **内部**，未说明输出还要进 CDB FIFO —— **就是这句把人带偏的** |

**建议**：向 Cache 侧反馈，第 38 / 56 行改为 **3 拍**（无 merge）/ **4 拍**（需 merge），
并注明"含 CDB 呈现寄存器"。

**口径提醒**：第 38 行的 2 / 3 数的是**级数**（E1→E3 / E1→E4），
我们的 `L` 用的是**拍差**（E1→E4 = 3）。两者差 1，见 §4.2 规矩 1。

#### 待办

| # | 事项 | 状态 |
|---|---|---|
| 1 | 用**观测面**测 G3 的 `isq_g3_issue_valid` → lane-3 写回事件的拍差，应得 **3**；同法测 ALU（应得 1）、MUL（应得 3）作方法自检 | ⏳ |
| 2 | ⛔ **不要用 latency ELF 报的"latency"数字来定 `L`** —— 该数字**自带口径**，而 ALU / MUL 恰好"占用 = 拍差"，**根本标定不出它用的是哪一种** | 规矩 |
| 3 | latency ELF 的真正用途：确认「不考虑 cache miss 时 `L` 是**常量**而非变量」 | ⏳ |
| 4 | 修正 Cache HAS 的 3.1 / 3.2 / 6.7（原第 38 / 56 / 212 / 217 行） | ✅ **已做**（`62c4700`，含修订表 `V1.0 rev.1`） |
| 5 | 修正 cache agent 的 load done 时刻（原比真实 cache **早 1 拍**） | ✅ **已做**（`CDB_PRESENT_CYCLES`，见下） |

#### ⚠️ 由第 5 项引出的两件事

**① LOAD 不能用 cache agent 来"测"。**
拿 agent 测，测到的只是 agent 自己的配置值（`LSU_LOAD_PIPE_STAGES + CDB_PRESENT_CYCLES + cfg`），
**是循环论证**。要拿真实延迟，必须接**真实 Cache RTL**。

**② 工具已经支持 `--dut-kind rtl_cache`** —— `BE RTL + OR_Cache RTL + FE agent`
（`cfg/filelist/rtl_cache.f`；`--dut-kind <agent|rtl_v1|rtl_fe|rtl_cache|rtl_full>`）。
这正是 LOAD latency 测试该用的组合：**真实 cache 提供延迟，FE 仍是 agent**（不受真实取指节奏干扰），
**避开了 `METHOD.md` §10 反对用 `rtl_full` 的那条理由**。

**⇒ 待决**：阶段 1 的 DUT 是否从 `rtl_v1` 改为 `rtl_cache`？
若改，`rtl_v1` 可留作快速回归；但 **LOAD 家族的判定必须以 `rtl_cache` 为准**。

> **教训**：这一处我和用户来回争了多轮，**根因是一直在拿 HAS 的散文推数字**。
> 上述结论只有一条依据 —— **读 RTL**。已把这条写进 `METHOD.md` §9.7。

**产出**：一张「**diagram 预期 vs 仿真实测**」对照表 → 明确哪些家族可原样保留、哪些需要由材料所有者修订。

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
