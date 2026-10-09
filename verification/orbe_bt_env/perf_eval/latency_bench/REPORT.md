# BE producer latency（L）实测报告

**任务**：实测当前 BE 各 producer 算子的 latency（L），为 timing conformance 的 case 生成提供参数。
**日期**：2026-10-09 ｜ **分支**：`fu_latency_bench`（含本报告时 HEAD=`f5c702f`）
**DUT**：`--dut-kind rtl_full`（OR_FE RTL + BE RTL + OR_Cache RTL）
**产物**：本目录 CSV + `perf_eval_work/latency/` 原始数据 + `sim/verilator_fu_latency/` 日志

> 本报告只给**实测值**与**复现信息**，不含 8 月材料里的预测值。

---

## 0. 结论摘要

| 家族 | BE 执行资源（组/lane） | 实测 L |
|---|---|---:|
| ALU | G0 `u_alu0_bru` / G1 `u_alu1`（`alu_simple`），lane 0/1 | **1** |
| MUL | G1 `mul_simple`，lane 1 | **3** |
| DIV/REM | G0 `div_simple`，lane 0 | **4** |
| LOAD（整数） | G3 `g3_lsu_iface` → LSU，lane 3 | **3** |
| LOAD（FP：flw/fld） | G3 LSU，lane 3 | **3** |
| JALR link（jalr/jal，link 值） | G0 `alu_simple`（BRU），lane 0 | **1** |
| FP 算术（F/D） | G2 `fpu_simple`，lane 2 | **1** |
| FP→INT（fcvt/fmv.x/fclass/fcmp） | G2 `fpu_simple`，lane 2 | **1** |
| AMO（RMW：amoadd/swap/and/or/xor/min/max） | G3 LSU，lane 3 | **4** |
| LR（lr.w/lr.d） | G3 LSU，lane 3 | **3** |
| SC（sc.w/sc.d） | G3 LSU，lane 3 | **4** |

要点：

1. **ALU=1、MUL=3、LOAD=3** 三点自检全部对上（先验证测法，再报数）。
2. **DIV=4**：本版 `div_simple` **没有可配的 `N` 参数**，倒计时硬编码 `cnt=2→1→0`
   （源码原话 *"Deliberately not a module parameter"*），再加一级写回寄存器，
   故 `request_valid` 在 issue 后第 4 拍。`backend_top` 实例化无任何参数覆盖。
3. **`fpu_simple` 全家族单周期（`N = 1`）**，连 `fdiv.d`/`fsqrt.d` 也是 1。
   若将来开 FP K-map，其 producer L 一律为 1。
4. **AMO 的 RMW 比普通 LOAD 多一拍**（4 vs 3）；LR 与 LOAD 相同（3）。
   AMO **确实走 cache 的 AMO 路径**（`src/core/cache_rtl_v1/dc_amo_op.sv`）：
   `AMO_amoadd_w_oldval` 先存 `0x1234` 再 `amoadd.w`，`LSU_BYPASS … data=0x1234`，
   返回的旧值正确 → 不是空操作。
5. **L 是整数**：仲裁争用只会让 completion 顺延**整整一拍**（见 §3.3 的 A/B 实测），
   不会出现 1.01 这类小数。
6. **ALU 两个实例都直接测过**：G0（lane0）与 G1（lane1）各一条，均为 1。

---

## 1. 测量口径

```text
L = （结果/bypass 对 BE 可见的那一拍） − （发射被接受的那一拍）     ← 取拍差
```

- **发射被接受** = `isq_g*_issue_valid && FU_ready`（RTL 的 `issue_fire`）。
  `issue_valid` 是 request 线，会一直保持到握手成功；只看它会多算被拒的拍。
- **结果可见** = 该 lane 的写回事件：
  - G0/G1/G2：`exec_valid[lane]`（观测面 `[FU_WB]`）；
  - G3（LOAD/AMO）：`lsu_be_bypass_valid`（观测面 `[LSU_BYPASS]`）。
- **参考系必须一致**：`ISQ_FIRE`/`FU_WB` 都经过同一级 obs 寄存器；G3 的
  `LSU_ISSUE`/`LSU_BYPASS` 都是组合观测。两套混用会凭空差一拍。

> 每个 case 只放**一条被测 producer**；依赖不让 producer 提前发射，也不让同组指令
> 在它的写回窗口抢 lane（否则测到的是"固有 L + 仲裁 +1"）。

---

## 2. 被测范围（IMAFDC+AMO 筛选）

判定准则：只有**写 rd、且依赖者能通过 P1/P2 MUX、P3 bypass、P4 commit、ARF 读到它**的
producer 才需要 L。

| 指令类 | 是否测 | 说明 |
|---|---|---|
| I（ALU/移位/slt/addi/lui/auipc） | ✅ | G0/G1 `alu_simple` |
| I（jal/jalr link） | ✅ | G0 BRU，取 link 值写回 |
| M（mul*） | ✅ | G1 `mul_simple` |
| M（div/rem*） | ✅ | G0 `div_simple` |
| 整数 LOAD | ✅ | G3 LSU，**只测直接命中** |
| flw/fld（FP load） | ✅ | G3 LSU，rd_is_fp |
| AMO / LR / SC | ✅ | G3 LSU（A 扩展） |
| F/D 算术与转换（fadd…fsqrt/fma/fcvt/fmv/fclass/fcmp） | ✅ | G2 `fpu_simple` |
| STORE（sw/sd/sh/sb/fsw/fsd） | ❌ | 无 rd，producer "don't exist" |
| FENCE / FENCE.I / PAUSE | ❌ | 无 rd |
| CSR / SYS（csrr/ecall/mret/sret） | ❌ | 串行化路径，非普通 bypass |
| Zb*（clz 等） | ❌ | 本版 BE RTL 内查不到对应 subop/执行资源 |

---

## 3. 结果

### 3.1 家族结果与代表证据（哪两拍）

| 家族 | 实测 L | lane | 发射被接受拍 | 结果可见拍 |
|---|---:|---:|---|---|
| ALU（`add x5,x1,x2`） | **1** | 0 | `[ISQ_FIRE] cycle=20 group=0 tag=0x7 pc=0x8000001c` | `[FU_WB] cycle=21 lane=0 tag=0x7 result=0xc` |
| MUL（`mul x5,x1,x2`） | **3** | 1 | `[ISQ_FIRE] cycle=20 group=1 tag=0x7 exe_subop=0x598020` | `[FU_WB] cycle=23 lane=1 tag=0x7 result=0x23` |
| DIV（`div x5,x1,x2`） | **4** | 0 | `[ISQ_FIRE] cycle=20 group=0 tag=0x7` | `[FU_WB] cycle=24 lane=0 tag=0x7` |
| LOAD（`ld x5,0(x2)`） | **3** | 3 | `[LSU_ISSUE] cycle=36 tag=0xb` | `[LSU_BYPASS] cycle=39 tag=0xb` |
| LOAD-FP（`flw f5,0(x2)`） | **3** | 3 | `[LSU_ISSUE] cycle=44 tag=0xd` | `[LSU_BYPASS] cycle=47 tag=0xd` |
| JALR link（`jalr x5,0(x10)`） | **1** | 0 | `[ISQ_FIRE] cycle=19 group=0 tag=0x5 pc=0x80000014 inst=0x000502e7` | `[FU_WB] cycle=20 lane=0 tag=0x5 result=0x80000018(=`PC+4`)` |
| FP 算术（`fdiv.d f3,f1,f2`） | **1** | 2 | `[ISQ_FIRE] cycle=30 group=2 tag=0xb` | `[FU_WB] cycle=31 lane=2 tag=0xb result=0x3fe0…(=1.0/2.0)` |
| FP→INT（`fcvt.w.s x6,f1`） | **1** | 2 | `[ISQ_FIRE] cycle=29 group=2 tag=0x9` | `[FU_WB] cycle=30 lane=2 tag=0x9 result=0x1` |
| AMO（`amoadd.w x5,x3,(x2)`） | **4** | 3 | `[LSU_ISSUE] cycle=40 tag=0xb` | `[LSU_BYPASS] cycle=44 tag=0xb` |
| LR（`lr.w x5,(x2)`） | **3** | 3 | `[LSU_ISSUE] cycle=40 tag=0xb` | `[LSU_BYPASS] cycle=43 tag=0xb` |
| SC（`sc.w x5,x3,(x2)`） | **4** | 3 | `[LSU_ISSUE] cycle=50 tag=0xd` | `[LSU_BYPASS] cycle=54 tag=0xd` |

### 3.2 逐例 L 清单（101 例；完整字段见 `latency_results.csv`）

| 家族 | 逐例（case=L） |
|---|---|
| ALU | ALU_add=1, ALU_sub=1, ALU_and=1, ALU_or=1, ALU_xor=1, ALU_sll=1, ALU_srl=1, ALU_sra=1, ALU_slt=1, ALU_sltu=1, ALU_addi=1, ALU_auipc=1, ALU_lui=1, ALU_add_G1=1 |
| MUL | MUL_mul=3, MUL_mulh=3, MUL_mulhsu=3, MUL_mulhu=3, MUL_mulw=3 |
| DIV | DIV_div=4, DIV_divu=4, DIV_rem=4, DIV_remu=4, DIV_divw=4, DIV_divuw=4, DIV_remw=4, DIV_remuw=4 |
| LOAD | LOAD_ld=3, LOAD_lw=3, LOAD_lh=3, LOAD_lb=3, LOAD_lwu=3, LOAD_lhu=3, LOAD_lbu=3, LOAD_flw=3, LOAD_fld=3 |
| JALR | JALR_link=1, JAL_link=1 |
| FP_ARITH | FP_fadd_s=1, FP_fsub_s=1, FP_fmul_s=1, FP_fdiv_s=1, FP_fmin_s=1, FP_fmax_s=1, FP_fsgnj_s=1, FP_fsgnjn_s=1, FP_fsgnjx_s=1, FP_fadd_d=1, FP_fsub_d=1, FP_fmul_d=1, FP_fdiv_d=1, FP_fmin_d=1, FP_fmax_d=1, FP_fsgnj_d=1, FP_fsqrt_s=1, FP_fsqrt_d=1, FP_fmadd_s=1, FP_fmadd_d=1, FP_fnmsub_s=1 |
| FP_TO_INT | FPI_fcvt_w_s=1, FPI_fcvt_wu_s=1, FPI_fcvt_l_s=1, FPI_fcvt_lu_s=1, FPI_fcvt_w_d=1, FPI_fcvt_l_d=1, FPI_fcvt_s_w=1, FPI_fcvt_d_w=1, FPI_fcvt_s_d=1, FPI_fcvt_d_s=1, FPI_fmv_x_w=1, FPI_fmv_x_d=1, FPI_fclass_s=1, FPI_fclass_d=1, FPI_feq_s=1, FPI_flt_d=1, FPI_fle_s=1 |
| AMO | AMO_amoadd_w=4, AMO_amoadd_d=4, AMO_amoswap_w=4, AMO_amoswap_d=4, AMO_amoand_w=4, AMO_amoand_d=4, AMO_amoor_w=4, AMO_amoor_d=4, AMO_amoxor_w=4, AMO_amoxor_d=4, AMO_amomin_w=4, AMO_amomin_d=4, AMO_amomax_w=4, AMO_amomax_d=4, AMO_amominu_w=4, AMO_amominu_d=4, AMO_amomaxu_w=4, AMO_amomaxu_d=4, AMO_lr_w=3, AMO_lr_d=3, AMO_sc_w=4, AMO_sc_d=4, AMO_amoadd_w_oldval=4(旧值 0x1234 校验通过) |

### 3.3 为什么 L 是整数：仲裁只会 +1 整拍（A/B 实测）

L 数的是两个时钟事件之间的拍数，时钟沿是量子，所以 L 必然是整数。组内仲裁
（G0 的 ALU0/CSR/DIV、G1 的 ALU1/MUL 抢同一条 lane 的呈现口）只有两种结果：
没输 → 固有拍数；输了 → completion 推到**下一拍**重试 → **固有拍数 +1**。

同一 producer（`mul x5,x1,x2`），只改 producer 之后那段 exit 代码：

| case | 发射拍 | 结果拍 | L |
|---|---|---|---|
| `DEMO_MUL_nocontend` | `[ISQ_FIRE] cycle=20 group=1 tag=0x7` | `[FU_WB] cycle=23 lane=1 tag=0x7 result=0x23` | **3** |
| `DEMO_MUL_contention` | `[ISQ_FIRE] cycle=18 group=1 tag=0x4` | `[FU_WB] cycle=22 lane=1 tag=0x4 result=0x23` | **4** |

`DEMO_MUL_contention` 的关键三拍：

```text
cycle=18  [ISQ_FIRE] group=1 tag=0x4 exe_subop=0x598020        # MUL 被接受，固有结果应在 21
cycle=21  [FU_WB] lane=1 tag=0x7 result=0x0000000080001020    # 21 拍 lane1 被独立 G1 addi 占走
cycle=22  [FU_WB] lane=1 tag=0x4 result=0x0000000000000023    # MUL 顺延到 22 → L=3+1=4
```

即**争用命中同拍时 L 平移整整一拍**。正式 case 都把同组 op 移出写回窗口，报的是
**无争用固有 L**。

---

## 4. 环境配置（复现用）

| 项 | 值 |
|---|---|
| 主机 | `cad1`，Linux 6.8.0-124-generic #124-Ubuntu SMP PREEMPT_DYNAMIC，x86_64，48 核 |
| 仓库 / 分支 | `OpenRio` / `fu_latency_bench`（从 `perf_eval_danielle` tip `a976f69` 切出） |
| DUT kind / tag | `rtl_full` / `fu_latency` |
| Verilator | **5.050 2026-07-01 rev v5.050**，`/work/home/danielle/.local/bin/verilator` |
| RISC-V GCC | **riscv64-unknown-elf-gcc (g5115c7e44) 15.2.0**，`/work/stu/yzhang/workspace/riscv/bin/` |
| RISC-V objdump | GNU objdump (GNU Binutils) 2.46（同目录） |
| ⚠️ 不可用 | `/opt/riscv` 的 GCC 11.1.0：`cc1: error while loading shared libraries: libisl.so.15` |
| ISA model | `ISA_MODEL_ROOT=/work/home/danielle/workspace/act-cosim/isa-root`；`lib_ISA_api.so` → `/work/home/danielle/workspace/suncheek/model/isa_model/build/lib_ISA_api.so` |
| ISA config | `/work/home/danielle/workspace/act-cosim/cfg/act_suncheek_0x80000000.yaml`（`isa_string: rv64imafdc_zcb_zifencei_zicsr`） |
| 链接脚本 | `perf_eval/templates/link.ld`（代码段 `0x80000000`，`.tohost` 退出） |
| Python | 3.12.3 |
| 编译选项 | `-march=rv64imafdc -mabi=lp64 -nostdlib -nostartfiles`（FP case 需使能 `mstatus.FS`） |

同一份机器可读版本：`toolchain.csv`。

---

## 5. 执行命令

```bash
cd /work/home/danielle/workspace/suncheek/model/OpenRio/verification/orbe_bt_env
export ISA_MODEL_ROOT=/work/home/danielle/workspace/act-cosim/isa-root
export ISA_CFG=/work/home/danielle/workspace/act-cosim/cfg/act_suncheek_0x80000000.yaml

# (1) 编译 rtl_full（含本任务的 TB 观测改动）
JOBS=8 tools/verilator_cosim.sh build --dut-kind rtl_full --tag fu_latency

# (2) 生成 .S → 编 ELF → 跑仿真 → 抽 issue/wb → 落 CSV（101 例）
python3 perf_eval/latency_bench/bench.py --jobs 8

#    只跑某几个家族（示例）
python3 perf_eval/latency_bench/bench.py --filter '^(ALU_|MUL_|DIV_|LOAD_|JAL)' --jobs 8

# (3) 查看结果
column -t /work/home/danielle/workspace/suncheek/model/perf_eval_work/latency/results/raw.tsv
```

`bench.py` 内部对每例执行的两条命令（等价手动版）：

```bash
# 编译（每例一个唯一命名的 ELF）
riscv64-unknown-elf-gcc -march=rv64imafdc -mabi=lp64 -nostdlib -nostartfiles \
  -Wl,-T,<OpenRio>/verification/orbe_bt_env/perf_eval/templates/link.ld \
  -o <WORK>/elf/<case>.elf <WORK>/cases/<case>.S

# 跑 RTL（verbosity≥2 才会打印 ISQ_FIRE / FU_WB / LSU_*）
tools/verilator_cosim.sh run --no-build --dut-kind rtl_full --tag fu_latency \
  --tc <WORK>/elf/<case>.elf --verbosity 2 --timeout 200000
```

---

## 6. 产物清单

| 文件 | 内容 |
|---|---|
| `latency_results.csv` | 101 例逐例：`case,family,producer_pc,rob,issue_cycle,wb_cycle,lane,L,status` |
| `family_summary.csv` | 按家族：`family,cases,L_min,L_max,L_values` |
| `toolchain.csv` | 工具链/配置/commit/复现命令（机器可读） |
| `bench.py` | case 生成 + 编译 + 运行 + 解析 + CSV 导出的全部逻辑 |
| `<WORK>/results/raw.tsv`、`by_family.tsv` | 同一批数据的 TSV（`WORK=…/model/perf_eval_work/latency`） |
| `sim/verilator_fu_latency/log/rtl_full/<case>_1/sim.log` | 每例原始日志（含 `[ISQ_FIRE]/[FU_WB]/[LSU_ISSUE]/[LSU_DONE]/[LSU_BYPASS]`） |

> 观测面改动（本任务为补 P3 观测所加，均为**新增**、不改现有判定）：
> `tb/interfaces/ob_cosim_if.sv`（`isq_issue_fire[3:0]`）、
> `tb/top/rtl_v1_obs.svh`（由 `u_backend.*FU_ready` 组合产生并寄存）、
> `tb/agents/be/be_agent.sv`（打印上述事件）。

---

## 7. 复现注意事项 / 已知偏差

1. **必须用 `rtl_full`，不能用 `rtl_v1` 测 LOAD**：`rtl_v1` 后面接 `cache_agent`，
   用它测 LOAD 是循环论证（`cache_agent` 是行为模型，其固定延迟不是性能依据）。
   本报告一律用 `rtl_full`（真实 FE+BE+Cache）。
2. **LOAD 只测直接命中**：被测 load 的地址必须**依赖 warm-up 结果**，否则会提前发射并与
   miss fill 合并，L 会虚高（初版踩过，测成 11）。
3. **FP case 必须先 `csrs mstatus, 0x6000`**（FS=Dirty），否则 FP 指令被判 illegal。
4. **退出用"写一次 tohost + 纯跳转自旋"**，不要 `wfi`（会与参考模型分叉）。
5. **ELF 命名不能含点**：`verilator_cosim.sh` 用 `${elf_base%%.*}` 取日志目录名，
   `amoadd.w` 与 `amoadd.d` 会落到同一目录互相覆盖（case id 已改下划线）。
6. **G3 的观测参考系**：`be_lsu_issue_valid`/`lsu_be_bypass_valid` 是组合观测，
   而 `FU_WB` 经一级 obs 寄存器；G3 若与 `FU_WB` 混用会差一拍。
7. **L 是"无争用固有值"**：若 producer 写回窗口内有同组指令抢 lane，会 +1 整拍（见 §3.3）。
   case 生成用的 L 取固有值。
8. **JALR 只计 link 值写回**（lane0 `rd=PC+4`），**不含** redirect/取指重定向；若需要
   "含 redirect 的可见拍"是另一个口径，需另行测量。

---

## 8. 覆盖范围与不覆盖范围

每个 case 只有 **setup + 恰好 1 条被测 producer + exit**（约 10–15 条）。这是**为测 L 刻意**
设计的最小形态：L 是"一条指令从发射接受到结果可见"的拍差，指令多了只会引入
争用/换序/cache 状态等噪声，不会改变被测算子的 L。
而且本版 RTL 的 FU 都是**固定延迟**模型（`alu_simple` 一级寄存、`mul_simple` 固定倒数、
`div_simple` 硬编码 `cnt`、`fpu_simple` 组合 + 一级寄存），L 与数据无关，
所以每类算子取代表指令即可。

对"提供 case 生成参数"这个目的，L 是**完整**的；但作为**整机性能评估**它显然**不完整**。
明确列出**不覆盖**的部分（如需可另测）：

| 维度 | 本报告 | 说明 / 缺口 |
|---|---|---|
| 单条 producer 的固有 L | ✅ 覆盖 | 每类算子 + 宽度/格式变体；ALU 的 G0/G1 两个实例都测过 |
| **吞吐 / 发射间隔（II）** | ❌ | 单条 producer 不给"背靠背能否连发"。`FU_ready=!busy`，MUL/DIV 会 busy 若干拍，FPU `N=1` → 连续发射间隔 ≠ L |
| **争用下的有效可见拍** | ⚠️ 仅 A/B | §3.3 证明会 +1 整拍，但没有系统统计"平均每条指令周期"（那才是会出现小数的量） |
| cache 命中路径 | ⚠️ 仅直接命中 | miss / merge / store-to-load forwarding / uncached-MMIO 未覆盖（任务明确排除） |
| JALR taken/redirect | ❌ | 只测 link 值写回；含 redirect 的可见拍另算 |
| 数据相关延迟 | ❌（本 RTL 无） | 本 RTL 固定延迟，故未扫 div-by-zero/overflow、NaN/Inf/subnormal 等 |
| 压缩指令（C） | ❌ | 用 `.option norvc`；C 展开为相同 op，不改变 L，但未专门验证 |
| AMO/LR/SC 的 **reservation 失败**、多核竞争、miss 行上的 AMO | ❌ | **AMO/LR/SC 本身已测**（含旧值正确性）；没测的是失败路径 / 多核 / 缺行 |
| STORE / FENCE / CSR | ❌（设计如此） | 无 rd 或串行化，不属于 register-result producer |

**如要让覆盖更全面，可增补**（本目录已有可复用的 `bench.py`，加 case 即可）：

1. **II/吞吐**：连续 N 条同 FU producer，测两次 `issue_fire` 的间隔；
2. **争用统计**：刻意制造同 lane 冲突，报"平均可见拍"（会出现小数，适合整机评估）；
3. **cache 路径**：用指定的 miss/forward/merge 序列；
4. **redirect-inclusive JALR**：把 taken 跳转的可见拍一并测；
5. **旁证**：用同事提供的 latency ELF（其内部循环很多次）做"平均值"视角的交叉验证。
