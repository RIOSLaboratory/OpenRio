# BE 各 producer 家族 latency（L）实测报告

**日期**：2026-10-09
**分支**：`fu_latency_bench`（从 `perf_eval_danielle` tip `a976f69` 切）
**DUT**：`--dut-kind rtl_full`（FE RTL + BE RTL + OR_Cache RTL）
**工具**：verilator 5.050（2026-07-01）；`riscv64-unknown-elf-gcc` 15.2.0
（`/work/stu/yzhang/workspace/riscv`；提示词里的 `/opt/riscv` 11.1.0 在本机缺 `libisl.so.15`，不可用）
**ISA model**：`ISA_MODEL_ROOT=/work/home/danielle/workspace/act-cosim/isa-root`，
`ISA_CFG=.../act-cosim/cfg/act_suncheek_0x80000000.yaml`
**数据**：`perf_eval_work/latency/results/raw.tsv`（97 例逐例 issue/wb/L）、
`perf_eval_work/latency/results/by_family.tsv`；日志
`sim/verilator_fu_latency/log/rtl_full/<case>_1/sim.log`

---

## 0. 口径（本任务的 L 定义）

```text
L =（结果/bypass 对 BE 可见的那一拍）−（发射被接受的那一拍）      ← 拍差
```

- 发射被接受 = `isq_g*_issue_valid && FU_ready`（RTL `issue_fire`）；G3 用 BE↔LSU 边界的
  `be_lsu_issue_valid`。
- 结果可见 = 该 lane 的写回：G0/G1/G2 用 `exec_valid[lane]`（观测面 `[FU_WB]`）；
  G3 用 `lsu_be_bypass_valid`（观测面 `[LSU_BYPASS]`）。
- **两种观测的参考系必须一致**：`ISQ_FIRE`/`FU_WB` 都经过同一级 obs 寄存器；G3 的
  `LSU_ISSUE`/`LSU_BYPASS` 都是组合观测。**混用会凭空多/少一拍**（本次踩过）。

> DUT 用 `rtl_full` 而不是提示词写的 `rtl_v1`：仓库在 `a976f69` 已裁定
> 「latency 标定用 rtl_full」（`CHANGE_IMPACT §4.6` / `METHOD §5.1`），理由是
> `rtl_v1` 后面接 `cache_agent`，拿它测 LOAD 是循环论证。已与用户确认。

### 0.1 对 TB 的改动（`be_agent.sv` 缺 P3 打印，按任务预判补上）

| 文件 | 改动 |
|---|---|
| `tb/interfaces/ob_cosim_if.sv` | 新增 `logic [3:0] isq_issue_fire`（每组的 issue 接受，`issue_valid && FU_ready`） |
| `tb/top/rtl_v1_obs.svh` | 由 `u_backend.{g0,g1}_FU_ready[FU_Group] / g2fu / lsuif` 组合产生，与既有 obs 寄存器同拍寄存 |
| `tb/agents/be/be_agent.sv` | 新增 `[ISQ_FIRE]`（G0..G3 接受拍）、`[FU_WB]`（每 lane 写回拍）、`[LSU_ISSUE]`、`[LSU_DONE]`、`[LSU_BYPASS]` 打印，verbosity≥2 |

这些都是**新增观测**，没有改动任何现有功能或判定。

---

## 1. 自检（先过三点才报数）

| 自检点 | 预期 L | 实测 L | 结论 |
|---|---:|---:|---|
| ALU | 1 | **1** | ✅ |
| MUL | 3 | **3** | ✅ |
| LOAD | 3 | **3** | ✅ |

三点全部对上，测量方法可信。

---

## 2. 主表：家族 → 实测 L → 与 8 月值对比

| 家族 | 实测 L | 原始证据（发射拍 → 结果拍） | 8 月 caselist 值 | 是否需要改 case 数 |
|---|---:|---|---:|---|
| ALU（`alu_simple` G0/G1） | **1** | `[ISQ_FIRE] cycle=20 group=0 tag=0x7` → `[FU_WB] cycle=21 lane=0` | 1 | 否 |
| MUL（`mul_simple` G1） | **3** | `[ISQ_FIRE] cycle=20 group=1 tag=0x7` → `[FU_WB] cycle=23 lane=1` | 3 | 否 |
| DIV（`div_simple` G0） | **4** | `[ISQ_FIRE] cycle=20 group=0 tag=0x7` → `[FU_WB] cycle=24 lane=0` | 8 | **是**（见 §4） |
| LOAD（`g3_lsu_iface`→LSU G3） | **3** | `[LSU_ISSUE] cycle=36 tag=0xb` → `[LSU_BYPASS] cycle=39 tag=0xb`(lane3) | 2 | 8 月值 2→3 **已在 `280af77` 入 caselist**；相对当前 caselist 无需再改 |
| JALR link（G0 BRU） | **1** | `[ISQ_FIRE] cycle=19 group=0 tag=0x5 pc=0x…14` → `[FU_WB] cycle=20 lane=0 result=0x…18(=PC+4)` | 3 | **是**（见 §4，含 redirect 口径提醒） |

逐例细分（同一家族内所有指令实测一致）：

| 家族 | 覆盖指令 | 例数 | L |
|---|---|---:|---:|
| ALU | add/sub/and/or/xor/sll/srl/sra/slt/sltu/addi/auipc/lui | 13 | 1 |
| MUL | mul/mulh/mulhsu/mulhu/mulw | 5 | 3 |
| DIV | div/divu/rem/remu/divw/divuw/remw/remuw | 8 | 4 |
| LOAD | ld/lw/lh/lb/lwu/lhu/lbu | 7 | 3 |
| LOAD(FP) | flw/fld | 2 | 3 |
| JALR | jalr/jal（link 值） | 2 | 1 |

### 2.1 为什么 L 全是整数：仲裁只会带来整整 +1 拍

L 是**两个时钟事件之间的拍数**，时钟沿是量子，因此 L 必然是整数。组内仲裁（G0 的 ALU0/CSR/DIV、G1 的 ALU1/MUL 抢同一条 lane 的呈现口）**不会**产生
"1.01"这种小数量，它只有两种结果：没输 → 固有拍数；输了 → 整个 completion 推到**下一拍**
重试 → 固有拍数 **+1**。会出现非整数的是"平均每条指令的周期"（吞吐/争用统计），不是 producer L。

用同一 producer（`mul x5,x1,x2`）、只改 producer 之后那段 exit 代码做的 A/B（`DEMO_*`）：

| case | issue 拍 | 结果拍 | L |
|---|---|---|---|
| `DEMO_MUL_nocontend` | `[ISQ_FIRE] cycle=20 group=1 tag=0x7` | `[FU_WB] cycle=23 lane=1 tag=0x7 result=0x23` | **3** |
| `DEMO_MUL_contention` | `[ISQ_FIRE] cycle=18 group=1 tag=0x4` | `[FU_WB] cycle=22 lane=1 tag=0x4 result=0x23` | **4** |

`DEMO_MUL_contention` 的关键三拍（原始日志）：

```text
cycle=18  [ISQ_FIRE] group=1 tag=0x4 exe_subop=0x598020         # MUL 被接受，固有结果应在 21
cycle=21  [FU_WB] lane=1 tag=0x7 result=0x0000000080001020     # 21 拍 lane1 被独立 G1 addi 占走
cycle=22  [FU_WB] lane=1 tag=0x4 result=0x0000000000000023     # MUL 顺延到 22 → L=3+1=4
```

即：**争用命中同拍时，L 平移整整一拍，而不是加一个小数**。
（本任务的正式 case 都把同组 op 移出写回窗口，所以报的是**无争用固有 L**，全是整数。）

三种自检之外的家族（用户要求全测）：

| 家族 | BE 资源 | 覆盖 | L |
|---|---|---|---:|
| FP 算术（F/D） | G2 `fpu_simple` | fadd/fsub/fmul/fdiv/fmin/fmax/fsgnj(n,x)/fmadd/fnmsub/fsqrt，s/d | **1** |
| FP→INT | G2 `fpu_simple` | fcvt.*/fmv.x.*/fclass/feq/flt/fle | **1** |
| AMO（RMW） | G3 LSU | amoadd/swap/and/or/xor/min/max(.w/.d) | **4** |
| LR | G3 LSU | lr.w/lr.d | **3** |
| SC | G3 LSU | sc.w/sc.d | **4** |

> **重要观察**：`fpu_simple` 是**全家族单周期**（注释 `N = 1`），连 `fdiv.d`/`fsqrt.d` 也是 1
> （RTL 用组合算子 + 一级寄存）。所以若将来开 FP K-map，其 producer L 一律为 1。
> AMO 的 RMW 比普通 LOAD 多一拍（4 vs 3）：读结果在 lane3 上的呈现多一级（store 侧）。

### 2.2 CSV 产物（in-tree，`perf_eval/latency_bench/`）

| 文件 | 内容 |
|---|---|
| `latency_results.csv` | 99 例逐例：`case,family,producer_pc,rob,issue_cycle,wb_cycle,lane,L,status` |
| `family_summary.csv` | 按家族：`family,cases,L_min,L_max,L_values` |
| `toolchain.csv` | 工具链与复现信息：verilator / riscv-gcc / ISA model / config / linker / 分支与 commit / 复现命令 |

（`family_summary.csv` 里 `DEMO` 两行是 §2.1 的仲裁 A/B：`3` 与 `4`。）

---

## 3. DIV 的 “N”

**结论：本版 RTL 的 `div_simple` 没有 N 参数，倒计时是写死的。**

- `src/core/be_rtl_v1/fu/div_simple.sv`：`cnt` 为 2 bit，`issue_accept` 时 `cnt <= 2`，
  之后 `2 → 1 → 0`（注释：`Countdown: 2 (Cycle 1), 1 (Cycle 2), 0 (Cycle 3 writeback)`）。
  第 113 行明写 **“Deliberately not a module parameter”**。
- `src/core/be_rtl_v1/top/backend_top.sv` 的 `div_simple u_div_simple (` **没有参数覆盖**（无 `#(…)`）。
- 全文件搜索 `parameter/localparam`：`div_simple.sv` 内没有任何延迟参数。

所以提示词第 7 节 #3「记录 backend_top 实例化时的 N 值」在当前 RTL 上**无法照填**：
应记录的事实是「无 N 参数；固定倒计时 2→1→0；外加一级写回寄存器，
故 `request_valid` 在 issue 后第 4 拍，L=4」。这同时解释了 caselist 的 8 为什么与 RTL 差 4 拍
（8 月值来自公司内部算子的 performance report，对本版外网 FU 无约束力，见 `METHOD §9.7`）。

---

## 4. 与 8 月值不同 → 牵动的数字

阈值规则（`CHANGE_IMPACT §4.2`）：`P3 = L+1`、`P4 = L+2`、`ARF boundary = L+3`，
枚举 delta `0 .. L+3`（即 `L+4` 条 case）。

### 4.1 DIV：L 8 → 4

| 量 | 8 月 | 实测 | 变化 |
|---|---:|---:|---|
| L | 8 | 4 | −4 |
| P3 delta | 9 | **5** | −4 |
| P4 delta | 10 | **6** | −4 |
| ARF boundary | 11 | **7** | −4 |
| 枚举区间 | 0..11 | **0..7** | — |
| DIV case 数 | 12 | **8** | **−4** |

### 4.2 JALR link：L 3 → 1（按本次口径）

| 量 | 8 月 | 实测 | 变化 |
|---|---:|---:|---|
| L | 3 | 1 | −2 |
| P3 delta | 4 | **2** | −2 |
| P4 delta | 5 | **3** | −2 |
| ARF boundary | 6 | **4** | −2 |
| 枚举区间 | 0..6 | **0..4** | — |
| JALR case 数 | 7 | **5** | **−2** |

> ⚠️ **口径提醒**：本次按用户决定取「lane0 ALU 写回的 link 值（rd=PC+4）」，
> redirect 不计入结果拍，故 L=1（与 ALU 同）。8 月的 3 来自 performance report 的
> “taken JAL/JALR ≈ 3 cycles”，那更像**取跳转解析/redirect 生效**的端到端口径。
> 若改取「含 redirect 的可见拍」，JALR 会得到另一个数（本次未采纳）。
> 这条请在裁定时明确，因为它决定 JALR 家族是 5 条还是 7 条。

### 4.3 单操作数 caselist 总数

| 家族 | 8 月 case 数 | 实测 L | 新 case 数 |
|---|---:|---:|---:|
| ALU | 5 | 1 | 5 |
| MUL | 7 | 3 | 7 |
| DIV | 12 | 4 | **8** |
| LOAD | 7（已被 `280af77` 从 6 改成 7） | 3 | 7 |
| JALR | 7 | 1 | **5** |
| **合计** | **38** | | **32** |

→ 需要**删 6 条 case**（DIV −4、JALR −2），总量 38 → 32。
（若 JALR 沿用“含 redirect”口径 =3，则只减 DIV 的 4 条，总量 38 → 34。）

### 4.4 两操作数 caselist 的边界行

`INT_two_operands_dependency_caselist.md` 第 26–33 行的边界表：

| Producer | P3 (现状) | P4 | ARF | 实测 L | 修正后 P3/P4/ARF |
|---|---:|---:|---:|---:|---|
| ALU/BRU | 2 | 3 | 4 | 1 | 不变 2/3/4 |
| MUL | 4 | 5 | 6 | 3 | 不变 4/5/6 |
| DIV/REM | 9 | 10 | 11 | 4 | **5/6/7** |
| LOAD hit | 4 | 5 | 6 | 3 | 不变 4/5/6 |

---

## 5. 复现

```bash
cd .../OpenRio/verification/orbe_bt_env
# 1) 编译（含本次 TB 观测改动）
ISA_MODEL_ROOT=/work/home/danielle/workspace/act-cosim/isa-root \
ISA_CFG=/work/home/danielle/workspace/act-cosim/cfg/act_suncheek_0x80000000.yaml \
JOBS=8 tools/verilator_cosim.sh build --dut-kind rtl_full --tag fu_latency
# 2) 生成 + 编译 ELF + 跑 + 取数（97 例）
python3 perf_eval/latency_bench/bench.py --jobs 8
# 3) 结果
column -t /work/home/danielle/workspace/suncheek/model/perf_eval_work/latency/results/{raw,by_family}.tsv
```

每例的原始日志在 `sim/verilator_fu_latency/log/rtl_full/<case>_1/sim.log`，
`[ISQ_FIRE]`/`[LSU_ISSUE]` 是发射接受拍，`[FU_WB]`/`[LSU_BYPASS]` 是结果可见拍。
所有 97 例 `is_good=1`、`REPORTER_SUMMARY error=0`。

---

## 6. 测量方法记录（踩坑与修正）

1. **LOAD 必须串行化到 fill 之后**：最初把依赖加在 `add` 上、被测 load 独立，
   结果被测 load 与 miss fill 合并 → 测成 11。改成让**被测 load 的地址依赖 warm-up 结果**
   （`ld x6,(x2); add x2,x2,x6; ld x5,(x2)`，wdata 全 0）后稳定为 3。
2. **MUL 曾被 exit 的 G1 op 抢仲裁**：`la x29` 的 addi 在 MUL 写回同拍赢了 lane1，测成 4。
   把 exit 的 `tohost` 地址/常量**预计算到 producer 之前**，消除同组争用后为 3。
3. **G3 的观测参考系**：`be_lsu_issue_valid`/`lsu_be_bypass_valid` 是组合观测，
   而 `FU_WB` 经一级 obs 寄存器；G3 若用「组合 issue + 寄存器 wb」会多 1。
   G3 一律用 `LSU_ISSUE` + `LSU_BYPASS`。
4. **`/opt/riscv` GCC 不可用**（缺 `libisl.so.15`），改用 `/work/stu/yzhang/.../riscv`（15.2.0）。
5. **ELF 命名不能含点**：`verilator_cosim.sh` 用 `${elf_base%%.*}` 取日志目录名，
   `amoadd.w`/`amoadd.d` 会落到同一目录互相覆盖（正是 METHOD §7.1.4 警告的坑）；
   case id 已全部改为下划线。
6. **FP case 必须先使能 `mstatus.FS`**：否则 `fp_illegal=1`，`flw` 等被判 illegal
   （`cause=2`）。setup 里加 `li x5,0x6000; csrs mstatus,x5`。
