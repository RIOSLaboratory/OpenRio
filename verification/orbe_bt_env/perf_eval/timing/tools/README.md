# 标定用的临时脚本

这些不是交付物，是标定混合源用例时用的探针。留在这里是为了避免机器重启后 `/tmp`
被清空、线索断掉。各自的作用：

| 脚本 | 作用 |
|---|---|
| `div_g1p3.py` | 提交侧 DIV、旁路侧 MUL 的间距扫描。用来说明为什么 DIV 作提交侧凑不出 `INT2_P4_G1P3` |
| `load_commit.py` | 提交侧换成 LOAD（固定 G3）之后的间距扫描。这是让两个生产者边界落到同一拍的可行方向 |
| `diag_m.py` | 逐条打印指令的 group、P1、P2、P3、P4。定位"是哪条指令在抢哪条 lane"用这个 |
| `try_k23.py` | 在 `diag_m.py` 基础上扫 k=2、k=3，用来找能错开冲突的间距 |
| `groups.py` | 单独导出一次运行里每条指令占用的 group，验证路由落在哪一组 |

## 当前进度（`INT2_P4_G1P3`）

这一行要求 dependent 的两路源同拍就绪：一路来自 Commit CDB，一路来自 G1 的 P3 旁路。
也就是要求"提交侧生产者的 P4 = 旁路侧 MUL 的 P3 = dependent 的 P1"。

已经确定的事：

1. **提交侧用 DIV 不行。** DIV 固定 G0，与它同拍派发的填充物会被挤到 G1（`groups.py`
   实测：该填充物的 group = 1）。此后它占住 G1 条目，把固定 G1 的 MUL 的派发卡成 2 拍
   量子，MUL 的 P3 序列变成 10、11、11、13、13、15，正好跨过 DIV 干净的 P4 = 12。
2. **提交侧换成 LOAD（固定 G3）可以解决上一条。** LOAD 不占 G0，链式填充物留在 G0，
   G1 留给 MUL。实测 LOAD 全程完全稳定（P1=7、P3=11、P4=12，任何配置都不动），
   且 `mul.P3 = 12` 在 k=1、k=2 都能取到。
3. **只差一拍。** 只要 dependent 前的填充物长到能把 `dep.P1` 推到 12，其中就有一条落到
   G1，把 MUL 的写回从 12 推到 13（它的派发不受影响，P1=8、P2=9 始终不变）。
   k=1 需要 m=5、k=2 需要 m=4、k=3 需要 m=3，三种情况都被推走一拍。

## 结论：这一行已经构造出来了，不是硬伤

**用永不跳转的分支作填充物即可**：`bne x0, x0, 7f`（x0 恒等于 x0，永不跳转），
BRU 属于 **G0 固定**组，不会被挤到 G1；单周期；不写寄存器。

实测（提交侧 LOAD、1 条分支、旁路侧 MUL、5 条分支、dependent）：

| 指令 | P1 | group | P2 | P3 | P4 | lane |
|---|---|---|---|---|---|---|
| `ld x6`（提交侧）| 7 | 3 | 8 | 11 | **12** | 3 |
| `mul x8`（旁路侧）| 8 | 1 | 9 | **12** | 13 | 1 |
| `add x20`（dependent）| **12** | 1 | 13 | 14 | 16 | 1 |

三点同拍，两个生产者写回都干净，模型正常退出。配方已固化为
`../calibrated_cases/INT2_P4_G1P3.S`，`branch_fill.py` 是扫描用的脚本。

注意 k=3 会让 MUL 的 P3 变成 13，可用的是 k=1（m=5）和 k=2（m=4）。

## 说明

链式填充物的做法与原理见 `../calibrated_cases/README.md`；那里也记着已固化的
`INT2_P4_G3P3` 配方，以及它带来的 caselist Instructions 列的同步修改（尚未执行）。

## 分支填充物：其余含 G1 生产者的行

同一个手法适用于所有"生产者固定在 G1、且要保住它的写回"的行。已标定并固化：

| 用例 | 配方 | 复核值 |
|---|---|---|
| `INT2_G3P3_G1P3` | 0 / 4 分支 | `mul.P3 = ld.P3 = dep.P1 = 11`，LOAD 在 group 3 |
| `INT2_G1P3_IMM` | 5 分支 | `mul.P3 = dep.P1 = 11` |
| `INT2_ARF_G1P3` | 0 / 4 分支 | `mul.P3 = dep.P1 = 11`，ARF 源在 10 提交 |
| `INT2_P2_ISQ_STORED_G1P3` | 0 / 2 分支 | `mul.P3 = dep.P2 = 11`，存储源在 9 就绪 |

`recal_5.py` 与 `freeze_5.py` 是这一轮的扫描与固化脚本。

## 尚未解决：`INT2_G1P3_G0P3`

它的两个生产者各占一条写回 lane：MUL 在 G1、ALU 在 G0。分支填充物固定在 G0，会像
链式填充物抢 MUL 那样去抢 ALU 搭档的写回；链式则在 G0/G1 之间交替，两边都碰。
可行的方向是只用 lane 2 或 lane 3 的填充物（`fadd.s` / `ld`），代价是粒度变成 2 拍一条，
需要用 `(ld, fadd)` 网格来凑，也就是单操作数标定时用的那套办法。

## 两条教训（都是"检查太松"造成的）

1. **接受条件必须包含"模型正常退出"。** 我第一次扫描时漏了整个 setup 段，生成的程序
   没有退出记账，往地址 0 写而触发错误上限终止；因为当时的接受条件只看拍号，仍然
   "找到"了配方。加上 `is_good=1` 之后立刻暴露。
2. **正则的捕获组序号要数清楚。** `[P3_BYPASS] cycle=(\d+) lane=(\d+) tag=(\S+)` 里
   `group(2)` 是 lane 不是 tag，写错会把事件挂到别的指令上，让整个标定结论失真。
   我在这一轮里犯过一次，另一次犯在 `[ISQ_FIRE]` 上。

## 接线：把固化用例装进跑批目录

`calibrated_cases/*.S` 是标定过的版本，跑批读的却是 `perf_eval_work/elf/*.elf`，那是
`gen_cases.py` 从 caselist 生成的版本。**不做这一步，跑批用到的仍是未标定的程序**，
标定结果对最终比对没有贡献。这一步由 `../install_calibrated.py` 完成：

```
python3 perf_eval/timing/install_calibrated.py           # 复制并编译全部固化用例
python3 perf_eval/timing/install_calibrated.py --dry-run # 只列出会做什么
```

它把 `.S` 复制到 `$WORK/cases/` 并逐个编译成 `$WORK/elf/`。复制之后 `gen_cases.py`
会拒绝覆盖这些文件，所以重新生成不会把手写版本冲掉。

配套的一处修改：caselist 的 `Fillers` 列现在允许在数字后带填充物类型标记（`0 / 4 branch`、
`1 / 5 chained`）。`gen_cases.py` 遇到这种行会跳过并提示改用固化文件，而不是按整数解析
（它原本会因为这一列而直接崩掉）。它只认独立 `addi` 填充物，渲染带标记的行必然出错，
因此跳过比渲染更安全。

## `INT2_G1P3_G0P3`：两侧都占 lane，靠换 G0 侧的生产者解决

这一行要求三件事同拍：G1 的 P3 发布、G0 的 P3 发布、dependent 的源解析。难点在于
**两个生产者各占一条写回 lane**（MUL 固定 G1、G0 侧固定 G0），而所有单周期填充物都是
ALU 操作，会被路由到 G0/G1 中空闲的那条——两条都被占着，所以独立填充物、链式、分支
三种都会抢走某个生产者的写回。分支尤其直接：BRU 属于固定 G0 组，与 G0 侧的生产者正面冲突。

可用的填充物只剩 lane 2/3 的 `fadd.s` 与 `ld`，代价是 2 拍粒度，条数必须实测。

真正让这一行成立的**不是填充物，而是 G0 侧生产者的选择**：DIV 的 P3 delta 是 5，
比 ALU 的 2 大，所以它必须比 MUL **早一拍**派发；按这个间距摆放，两个发布自然落在同拍，
而两个写回都保持干净。顺序不能换——MUL 在前时没有任何间距能凑出干净的同拍。

实测（`0ld+1fp / 0ld+3fp`）：

| 指令 | P1 | group | P2 | P3 | lane |
|---|---|---|---|---|---|
| `div x6`（G0 P3 源）| 15 | 0 | 16 | **20** | 0 |
| `mul x8`（G1 P3 源）| 16 | 1 | 17 | **20** | 1 |
| `add x20, x8, x6`（dependent）| **20** | 0 | 21 | 22 | 0 |

探针脚本：`g1p3_g0p3.py`（两段扫描）、`freeze_g0p3.py`（固化与逐项复核）、
`diag_gg.py`（逐条打印事件与 group）。

**一处教训**：这一轮我曾在接受条件里把 DIV 的干净写回间隔写成 5，而它是 **4**
（L=4），于是把已经成立的配置全部误杀，第二段扫描根本没执行。DIV 的 `P3 - P2` 是 4，
MUL 是 3，别混。

## 复查（re_audit.py）：用权威口径重验固化用例

起因：标定 `INT2_G1P3_G0P3` 时，我在一次性脚本里把 **DIV 的干净写回间隔写成 5**，
而权威值是 **4**（`Latency_Report.md` §3.1）。后果不只是搜索失败：我据此**向人报告过
"没有任何配置能让两个写回都干净"**，那是错的。改正后立刻出解。

结构性的原因是"同一张 L 表在仓库里有多份拷贝，脚本里又各抄一遍"。因此
`re_audit.py` 的做法是：

  * L 值**只**从 `lane_check.L_CLEAN` 取（该表与报告一致）；
  * 用例指令与依赖关系**只**从 caselist 的 Instructions 列取；
  * 每个固化 `.S` 现编现跑，逐条判：生产者 `P3 - P2` 是否等于其家族的 L、该行声称的
    边界关系是否成立、δ 是否与文件名一致、模型是否正常退出。

结果：25 个固化用例全部通过。

**验收条件里的数字不要手抄**——这是本轮反复出错的来源。若要加新的判据，从
`lane_check.L_CLEAN` 取值，不要重新键入。

### 本轮核对过的其它阈值位置

| 位置 | 用途 | 是否与报告一致 |
|---|---|---|
| `lane_check.py: L_CLEAN` | 写回 surplus 的基准 | 一致 |
| `compare.py: L_OF` | 机制判定（δ 与 L 比） | 一致 |
| `filler_calib.py: FAMILY` | 标定用的干净 L | 一致 |
| `tools/*.py` 中被调用的阈值 | 各轮标定 | 一致（唯一一次错值在 `g1p3_g0p3.py`，已改）|

### 两处已知的隐患（当前无害，但别踩）

1. `lane_check.MNEM` 把 `SD/SW/SH/SB` 映射成 **LOAD**。store 没有寄存器结果，不该用它
   判写回间隔。目前无害，因为 store 不产生 `[P3_BYPASS]` 事件、会被跳过；一旦某天产生，
   就会被当成 LOAD 并误报 surplus。
2. `family()` 期望**大写**助记符（它解析日志里的 `inst_mnemonic=`）。传小写会静默落进
   默认的 `ALU`、L=1，把 MUL/DIV 判成脏。本轮我就在 `re_audit.py` 里踩过一次。

## JALR 作 producer：结论是**凑不出来**（附证据与复现脚本）

K-Map 要求的是"JALR 作 producer，consumer 任意"。为此先修掉了当初挂死的根因：
**跳转目标寄存器未初始化**导致跳到地址 0。修法是让 target = JALR 的下一条指令
（落空路径），这样 dependent 在架构正确路径上。修好之后程序能正常跑，
JALR 的写回间隔为 **1**，与 `Latency_Report.md` 的 `link 值 = 1` 一致。

但是 delta 阶梯凑不出来。原因是 **JALR 自己的重定向会冲刷它后面派发的一切**：
凡是落在链路值可见窗口内派发的 dependent 都是投机派发，**从未提交**。

`jalr_producer_commit.py` 的输出（每条打印"该次派发的 delta 是否提交"）：

| 填充物 | 各次派发 delta（✓=提交，×=被冲刷） | 提交实例的最小 delta |
|---|---|---|
| 0 | 1×  6✓ | 6 |
| 1 | 2×  6✓ | 6 |
| 2 | 2×  7✓ | 7 |
| 3 | 3×  7✓ | 7 |
| 4 | 3×  8✓ | 8 |
| 5 | 8✓ | 8 |
| 6 | 9✓ | 9 |

**消费者换成 MUL 结果完全相同**（`jalr_producer_commit.py` 会同时跑 ALU 与 MUL）——
成因在前端重定向，与消费者落在哪个 group 无关。

**预热也无法绕过**（`jalr_producer_warmup.py`）：先执行一次同目标的 JALR，重定向次数
从 2 增到 3，提交实例的最小 delta 从 6 **升到 10**。这个配置里 JALR 不被预测。

**⇒ 对 JALR（L=1，阶梯 0..4）**：没有一条 delta 可实现。实际可达的只有 delta ≥ 6，
按 `mech_of` 全部落在 **`arf_read`**（delta ≥ L+3）——即依赖者派发时链路值早已提交，
旁路捕获机制一个都测不到。

**复现**：`python3 tools/jalr_producer_commit.py`（约 20 次仿真）。

### 为什么"把 JALR 的 L 改成 3"也救不了（L 无关性）

一个自然的想法是：既然 JALR 的 L 太小（1），导致阶梯太短够不着，那把 L 做大是不是就行了？
**不行，而且缺口与 L 完全无关。**

**基准**：用 caselist 的 `Tn`（`IB` 在 T1 ⇒ 派发 P1 在 T2 ⇒ 发射 P2 在 T3 ⇒ `WB` 在 T(3+L) ⇒
提交在 T(4+L)）。caselist 的 landmark 就是这么记的，JALR 也不例外——见下面的更正。

| 事件 | 时刻 |
|---|---|
| 派发（P1）| T2 |
| 发射（P2）| T3 |
| 链接值上旁路（P3 = WB）| T(3+L) |
| 提交 = redirect = 冲刷（P4）| T(4+L) |
| 首个能存活的派发（重取指 `r` 拍后）| T(4+L+r) |
| 消费者派发（delta 定义）| T(2+delta) |
| **存活条件** | `delta ≥ L+2+r` |
| 阶梯上界（`arf_read`）| `L+3` |
| **缺口** | **`r − 1`**（实测 r=2 ⇒ 缺口 1）|

**缺口与 L 无关**：原因是"结果可见"（P3）与"提交"（P4）之间**永远只隔一拍**，加大 L 只把
阶梯顶与存活下界同步外移。L=1 实测：`WB` 在 T4、提交/冲刷在 T5；阶梯上界 4，存活下界 5 + r−1。

**更正（曾误记为"JALR 有一拍例外"）**：曾观察到 JALR 的派发→发射是 2 拍，并据此以为 JALR 的
`WB` 落在 T(4+L)。隔离实验（`jalr_issue`）表明那是**派发槽位假象**，不是 JALR 的属性：
把 JALR 前任依次换成 `la` / `ld`(G3) / `fadd.s`(G2) / `add`(G0) / `bne`(G0)，JALR 的**发射拍恒为
同一拍**，只有派发拍在变；当前任是 G0 类指令时派发晚一拍，读出来就是 +1。JALR 的 latency 仍是
**1**（`ISQ_FIRE` → `FU_WB`，与报告 §3.1 一致）。所以上表对 JALR 直接适用。

**结论对任何 L 成立**：即便重取指只花 1 拍（`r=1`），缺口为 0，也仅是"恰好够到顶格"，仍然要靠
前端预测才谈得上余量。

### rd 与 rs 的对接方式（为什么失败不在"对接"）

连接是**广播 + tag 比较**，不是点对点连线：

1. `p1/INT_tag_mapping.sv` 在派发时为生产者 `rd` 分配 tag；
2. 消费者的 ISQ 条目存 `rs_wait_tag`（`p2p3/ISQ_Group0..3.sv`），`sel` 码由
   `p1/dependency_check.sv` 生成；
3. 两条消费通路：
   - **P1**：`top/isq_payload_assembly.sv` **不做 tag 比较**（源注释即如此），只按
     `sel_bypass` 选 `bypass_data`，条目出生即 ready —— 这就是 `p3_capture`；
   - **P2**：`p2p3/FU_input_mux.sv` 的 `hit[b] = bypass_valid[b] && (rs_wait_tag == bypass_tag[b])`，
     命中即取旁路数据；
4. 提交后走 `INT_ARF`（P1 直接读）。

所以在 L=3 的假设下，delta=4 时消费者派发恰好落在 P3，**P1 通路会正常捕获链接值**——
失败发生在下一拍：提交拍即冲刷拍，`global_flush_late` 把刚建立的条目复位。
**失败不在对接，在存活。**

唯一能让它可测的路径在前端：FE 正确预测 JALR 目标 ⇒ 不发生冲刷 ⇒ 两条旁路通路立刻可测。

### JALR 写进 rd 的是 PC+4，与 rs1 / imm 无关（决定性实验）

`jalr rd, imm(rs1)` 的两条效果是分开的：

| 目标 | 值 | 受 rs1/imm 影响？ |
|---|---|---|
| `rd` | **`PC + 4`**（本 JALR 自己地址的下一条）| **否** |
| `PC` | `(rs1 + imm) & ~1`（跳转目标）| 是 |

`tools/jalr_link_value.py` 让一条 JALR **跳过一条指令**（目标 ≠ 落空路径），于是两个候选值分开：

```
JALR pc=0x8000001c  rd=x5  rs1=x11  imm=8
  result（实测写进 rd）  = 0x80000020
  PC+4（落空，被跳过的）  = 0x80000020   ← 相等
  rs1+imm（真正的目标）   = 0x80000024   ← 不相等
```

**⇒ 写进 rd 的是 PC+4，不是跳转目标。** 所以 consumer 拿到的是"JALR 的下一条指令地址"，
是一个与 rs1、imm 无关的常量；后续 ALU 把它当普通整数运算即可，期望值可静态算出。

**这也说明 K-Map 那一行的本意**：让 JALR 充当一个普通的 rd 生产者，为 consumer 提供 rs；
一旦它触发 flush，窗口内的消费者全被作废，任何 delta 都凑不出来——**该行的意义正建立在
"它不 flush"之上**，而这需要 FE 预测正确（见上文 `pred_taken` / `pred_target_pc` 条件）。

## 基准 DUT：`rtl_full` 是完整体，但当前一切 delta 测量跑的是 `rtl_v1`

**事实（已核实 filelist）**：

| DUT_KIND | BE | FE | Cache |
|---|---|---|---|
| `agent` | BFM | agent | agent |
| `rtl_v1` | RTL | **FE agent** | **cache agent** |
| `rtl_fe` | RTL | OR_FE RTL | cache agent |
| `rtl_cache` | RTL | FE agent | OR_Cache RTL |
| **`rtl_full`** | **RTL** | **OR_FE RTL** | **OR_Cache RTL** |

`rtl_full.f` = `rtl_fe.f` + `cache_rtl.f`，不含任何 agent；`tools/verilator_cosim.sh:92`
的默认值就是 `rtl_full`。

**但仓库当前策略相反**：`run_perf.sh:5-7,29` 明确把默认 DUT 定为 `rtl_v1`（注释写
"rtl_full is reserved for latency calibration"），`METHOD.md:33/138-149` 同样把主 DUT 定为
`rtl_v1`、只把 latency 标定划给 `rtl_full`。⇒ **目前 20 条固化用例、surplus 分析、以及全部
JALR 实验都是在 `rtl_v1` 下做的**，只有 latency 标定用了完整体。

### 换到 `rtl_full` 时发现的两个阻碍（实测）

1. **P3 观测面在 `rtl_full` 下不存在。** P3 探针写在 `tb/agents/be/be_agent.sv`，而
   `rtl_v1_obs.svh` 是在 `be_tb_top.sv:503` 里以 `ifdef ORBE_DUT_RTL_V1` 包进来的。
   完整体日志里 `P3_BYPASS` 出现 **0 次**，而 delta / 机制判定必须依赖 P3
   （`mech_of` 用的是 `dep.P1` 与 `prod.P3` / `prod.P4` 的关系）⇒ **观测层要先扩展到 rtl_full**。
2. **抽样 6 条固化用例在 `rtl_full` 下全部功能失败**：
   `PC_MISMATCH` → `ERROR_LIMIT` → `is_good=0`。退出序列与 `templates/case.S.in` 逐字一致，
   所以不是收尾写法问题；分歧是退出前的 PC 推进（`rtl_pc=0x48` vs `ref_pc=0x4c`）。
   需要单独查因，暂不能假设是同一原因。

### 好消息：JALR 那一行的前提在完整体下存在

`rtl_fe.f:10` 含 `src/core/fe_rtl_v1/l1btb.sv`，头注释为
"L1BTB: **the only branch predictor**, S0 read, S1 read-out, S1/S2 register, S2 compare and
redirect"，端口带 `upd_target` / `bp_type_t` / `upd_ctr` ⇒ **真 FE 会预测 taken/not-taken 和目标**。
这正是 `alu_simple.sv:440` 的 `mispredict_flag` 需要的东西：只要 BTB 命中，
`pred_taken=1` 且 `pred_target_pc == branch_target` ⇒ 不置 flush ⇒ JALR 才能当普通 rd 生产者。
`rtl_v1` 下不可能，因为 FE agent 硬编码 `pred_taken=0`。

### 更正：JALR 作 producer 在 `rtl_full` 下**可以**构造（BTB 命中）

此前把 `JALR_to_ALU` 一族撤掉，理由是"构造不出来"——**该结论只在 `rtl_v1` 下成立**，
因为那里的 FE 是 `fe_agent`，硬编码 `pred_taken = 0`，任何 taken 的控制转移都必然误预测并冲刷。
基准 DUT 换成 `rtl_full` 后，真 FE 带 `l1btb.sv`，条件就满足了：

**前置条件：同一条 JALR（同 PC、同目标）必须先执行过一次**（BTB 按 PC 索引）。
`tools/jalr_btb_warmup.py` 用循环让 JALR 执行两遍，实测：

```
JALR pc=0x80000028
  第1次: P1=26 P2=27 P3=28 P4=29   mispredict=1     ← 建 BTB 条目
  第2次: P1=46 P2=47 P3=48 P4=49   mispredict=0     ← 命中，不冲刷
```

第二次不置 `flush_valid` ⇒ 不发 redirect ⇒ 链路值经旁路正常传递，消费者可落在任意 delta。
**⇒ 该族恢复枚举：`JALR_to_ALU_delta_0..4`（L=1，阶梯 0..4，5 条）**，
用例程序需包含一次预热执行（循环），测量的是第二次。

**连带更正**：K-Map 里原先那条注记
"JAL/JALR with rd != x0: register-result producer exists, covered by ALU/BRU 1-cycle producer POI"
**现在是正确的**，不需要改；此前我把它列为"需修改"是基于已作废的结论。
