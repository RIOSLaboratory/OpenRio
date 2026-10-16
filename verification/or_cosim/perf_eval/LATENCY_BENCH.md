# 任务简报：实测当前 BE 各算子的 latency（L）

> 这份文件是给子分支执行者的任务简报（子分支建议从 `perf_eval_danielle` 切出，命名如 `fu_latency_bench`）。
> 目的：为 timing conformance 的 case 生成提供**当前 BE 真实**的 producer latency `L`。

---

## 1. 一句话

测出 ALU / MUL / DIV / LOAD / JALR-link 五个家族在当前 RTL 上的 `L`，
与 8 月 caselist 沿用的旧值（1 / 3 / 8 / 2 / 3）对比，给出是否需要改动的结论。

## 2. 为什么必须实测（四条理由）

**① BE HAS 里根本没有算子拍数的规格。**
`docs/BE/or_be_has_V1.0.md` §3.2 参数表（第 51–65 行）共 11 项，**没有一项涉及延迟**；
全文件搜索 `latency` / `pipe_stages` / `lat_` → **0 命中**。
§6.5 只有定性描述：`alu_simple` "single-cycle"（第 184 行）、
`mul_simple`/`div_simple` "multi-cycle … fixed countdown"（第 202 行，**倒数长度未给**）、
`fpu_simple` "registers for one cycle"（第 208 行）、
`g3_lsu_iface`（第 217 行，**连定性周期描述都没有**）。

**② caselist 里的旧值是"上一版设计的实测值"，不是规格。**
caselist 自己写着（`timing/caselists/INT_single_operand_dependency_caselist_v1.md` 第 50 行）：
> "The **performance report** measures taken `JAL` and `JALR` at about 3 cycles"

即那串数字来自**他人的 performance report**，针对**不是我们这一版**的算子。
**我们的 FU 是外网生成的，性能不必与之相同。**

**③ `L` 一变，整个 case 家族都变。** 整套 case 由 `L` 唯一生成：

```
P3 delta = L + 1
P4 delta = L + 2
ARF boundary delta = L + 3
枚举范围 = 0 .. L+3            （共 L+4 条 case）
机制阶梯 = 0:overlay | 1..L:wait_for_p3 | L+1:p3_capture | L+2:p4_capture | L+3:arf_read
```

已有实例：LOAD 的 `L` 从 2 修正为 3 后，delta 从 3/4/5 变成 4/5/6，枚举从 `0..5` 扩到 `0..6`，
case 数 6 → 7，总数 37 → 38。

**④ 唯一一处书面的延迟恰恰是错的。**
Cache HAS 曾写"无 merge 的命中 **2 拍**"并且 `LSU_LOAD_PIPE_STAGES = 2`，但真实值（作者确认）是 **3 拍**
——拍 1 AGU / 拍 2 L1 D cache / 拍 3 **arbiter + CDB FIFO 共占**，原文漏掉了第 3 拍。
该 HAS 已修正（`V1.0 rev.1`）。**这说明"照文档抄"不可靠。**

> 结论：**`L` 是当前 BE 的待标定参数，只能实测。** 依据是 `perf_eval/METHOD.md` §9.7：
> **拍数类事实以 RTL / 实测为准，文档措辞不算数。**

## 3. DUT：用 `rtl_full`，一个 DUT 跑到底

```bash
verification/or_cosim/tools/verilator_cosim.sh --dut-kind rtl_full ...
```

**理由**：一批 case 里 LOAD 与其它指令**混在一起测**。用完全体（FE + BE + Cache）
**一次跑完就能拿到所有相关指令的 latency，中途不换 DUT**。

**为什么不接 `rtl_v1`**：`rtl_v1` 后面是 `cache_agent`，它的返回时刻由 agent 自己的参数算出来，
拿它"测"LOAD 延迟是**循环论证**。

> `cache_agent` 是**行为模型**：只负责保证 load data 正确返回（功能正确），
> **不是性能依据**。它的固定延迟参数与 latency 标定无关。
>
> 相关裁定见 `METHOD.md` §5.1 与 §10。

## 4. `L` 的定义（本任务最易错处）

```
L = （结果 / bypass 对 BE 可见的那一拍） − （发射被接受的那一拍）      ← 取【拍差】
```

⛔ **不是"经过了几级流水"**。两者会差 1。

**信号**（都在现成观测面上：`tb/interfaces/ob_cosim_if.sv`、`tb/top/rtl_v1_obs.svh`）：

- **发射拍** = `isq_g0..g3_issue_valid` **且** 对应 `FU_ready`
  —— FU 的接受条件是 `issue_valid && FU_ready`；只看 `issue_valid` 会多算被拒的拍。
- **结果拍** = 该 lane 的写回事件。
- **G3 特例**：`g3_lsu_iface` 的 issue 侧**纯组合**
  （`FU_ready = bridge_has_room && lsu_be_issue_ready`，同拍 `be_lsu_issue_valid = issue_valid && …`），
  所以 BE↔LSU 边界的 issue fire **与 ISQ 发射同拍**。
- **量 LOAD 时必须排除**：cache miss、store-to-load forwarding、ISB / WB merge 路径
  —— 只测**直接命中、无 merge** 的那条路。

## 5. ⛔ 测量陷阱（两条）

### 5.1 G0 / G1 的 lane 仲裁会污染 `L`

量 `isq_gX_issue_valid → exec_valid[X]` 时，**G0 / G1 会把仲裁等待算进去**：

- G0 三个 FU（`alu_simple` ALU0/BRU、`csr_unit`、`div_simple`）共享 `p3_arbiter_G0`；
  G1 两个（`alu_simple` ALU1、`mul_simple`）共享 `p3_arbiter_G1`。
- 仲裁每拍只让一个赢；**输家置 `loser_hold`**，而它的 `FU_ready = !loser_hold`
  （`src/core/be_rtl_v1/fu/alu_simple.sv:29-31` 注释），
  所以输家接不了新指令、完成请求要**保持到仲裁成功**。
- ⇒ 量到的是 "FU 自身延迟" **加上** "仲裁等待"。
- **G2（`fpu_simple`）/ G3（`g3_lsu_iface`）没有仲裁**（BE HAS 第 226 行），不受影响。

**规避办法（二选一或都做）**：

1. **用无竞争的 case** —— 同一组、同一时刻只有一条在飞
   （8 月 diagram 的标称值 ALU T4 / MUL T6 就是无竞争情形）；
2. **终点量到 FU 自己的输出** —— G0 / G1 量 `request_valid`，G2 / G3 量 `writeback_valid`。

**否则 ALU / MUL / DIV 的 `L` 可能被量成"大于真值"** —— 自检（ALU=1、MUL=3）能抓到。

### 5.2 CDB FIFO 的呈现顺序会推迟 LOAD 的 `L`

Cache HAS `V1.0 rev.1` 把 load 延迟写成**下界**：

> "visible to BE **at the earliest** three cycles … **provided the new entry is the CDB head**"
> "otherwise **FIFO ordering delays presentation**"（§3.1 / §6.7）

即 `L(LOAD) = 3` 成立的前提是：**这条 load 的条目一进 CDB FIFO 就成为 head**
（FIFO 里没有更早的未呈现条目）。

- CDB 是**终端状态 FIFO**（`dc_cdb.sv`，`CDB_N = 16`），每拍**只呈现 head 一条**；
  条目在 E3 之后的时钟沿被捕获，**head 读出是组合的**。
- 若同期还有别的完成排在前面（另一条 load 的 done、ISB store-commit done、E3 exception…），
  **这条 load 会被推迟呈现** ⇒ 量到的 `issue → lane-3 写回` **> 3**。
- 与 §5.1 是同一类问题：**完成事件排在别人后面**。

**规避办法**：

1. **用"单条 load 在飞"的 case** —— 同期不要有其它完成事件（别的 load、store commit 等）；
2. 或把终点量到 **CDB 条目形成那一拍**（E3 结束）—— 但这要求观测面能看到 CDB 内部，
   **很可能看不到**，所以优先用办法 1。

**否则 LOAD 的 `L` 会被量成"大于 3"** —— 自检（LOAD=3）能抓到。

## 6. 自检（必做，不可跳过）

报出任何数字之前，先用三个**已知答案**验证测量方法：

| 自检点 | 预期 `L` | 依据 |
|---|---|---|
| ALU | **1** | `alu_simple.sv`："result registered for one cycle" |
| MUL | **3** | `mul_simple.sv` 注释："issue at T, `request_valid` at T+3" |
| LOAD | **3** | 已从 RTL 定案（见 §2 理由④） |

**三个自检点对不上，先怀疑测量方法，不要怀疑被测对象。**
最可能的错法就是把"级数"当成"拍差"，或忘了 §5 的仲裁。

## 7. ⛔ 不要用 latency ELF 报表的数字作为 `L`

同事提供的 latency ELF 可以**用作旁证**（确认"不考虑 cache miss 时 `L` 是**常量**而非变量"），
但**不能用来定 `L` 的值**：

> 报表输出的 "latency" **自带口径**（拍差？级数？端到端？），
> 而 **ALU 与 MUL 恰好"占用 = 拍差"**（1=1、3=3），**根本标定不出它用的是哪一种口径**。
> 拿它填 `L`，等于把口径问题再引入一次 —— 这个坑刚在 LOAD 上栽过。

要拍差，就用观测面直接数拍。

## 8. 环境

```bash
# 仿真驱动（注意 --dut-kind rtl_full）
verification/or_cosim/tools/verilator_cosim.sh --dut-kind rtl_full ...

# 工具链
verilator 5.050 2026-07-01
/opt/riscv/bin/riscv64-unknown-elf-gcc (GCC) 11.1.0
```

- `perf_eval/templates/` 下已有 `link.ld` 与 `case.S.in`（初版，可改）
- `be_agent.sv` 目前**缺少 P3 写回打印**（`METHOD.md` §11 记为待补，信号已在观测面上）—— 本任务很可能要先补上
- ELF 必须**按 case id 唯一命名**，否则日志目录互相覆盖；`--verbosity` 必须 ≥ 2

## 9. 交付物

1. **一张表**：

| 家族 | 实测 `L` | 原始证据（哪两拍） | 8 月 caselist 值 | 是否需要改 case 数 |
|---|---|---|---|---|
| ALU | | | 1 | |
| MUL | | | 3 | |
| DIV | | | 8 | |
| LOAD | | | 2 | |
| JALR link | | | 3 | |

2. **原始日志 / 波形片段** —— 能从中**指出**发射拍与结果拍分别是第几拍（不接受只给结论）。
3. **DIV 的 `N`**：`div_simple.sv` 的倒数是可配的，请记录 `backend_top.sv` 实例化时的**实际值**。
4. 某家族与 8 月值不同时，**另列一节**说明差多少、牵动哪些数字（`L+1` / `L+2` / `L+3` / case 数）。

## 10. ⛔ 本任务**不要**做的事

- **不要改** `perf_eval/timing/caselists/**` 与 `timing/diagrams/**` —— 那是另一条线，测完由人裁决。
- **不要**为了让结果"好看"而调整测量点。**自检不过就报告测量方法有问题**，这也是有效产出。
- **不要**顺手改 `docs/**`。
- 有疑问先问，不要自行推断口径。

## 11. 相关文档

| 文档 | 看什么 |
|---|---|
| `perf_eval/METHOD.md` | §5.1（latency 用 `rtl_full`）、§9.7（拍数类事实以 RTL / 实测为准）、§11（当前状态） |
| `perf_eval/CHANGE_IMPACT.md` | §4.2（`L` 参数化）、§4.6（LOAD 定案过程、待办、测量陷阱） |
| `docs/BE/or_be_has_V1.0.md` | §5（五段划分）、§6.5（各 FU 的定性描述） |
| `docs/Cache/or_cache_has_V1.0.md` | §3.1 / §3.2 / §6.7（load 完成时刻，`V1.0 rev.1` 已澄清） |
