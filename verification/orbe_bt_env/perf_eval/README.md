# perf_eval — RTL 性能评估

把 `or-be-draft/timing/caselists/` 里**预测**的时序行为，与 RTL 逐拍**观测**到的
P1/P3/P4 事件做比对，回答一个问题：**RTL 的 performance 是否符合预期。**

> 状态：目前只有骨架（目录、链接脚本、case 模板）+ 方法文档。
> 生成器 / 跑批 / 比对脚本尚未落地，见 §6。
>
> **完整方法（caselist → .S → .elf → 跑 RTL → 抽取 → 人工判定）见
> [`METHOD.md`](METHOD.md)。**

## 1. 仓库边界

| 内容 | 归属 |
|---|---|
| caselist（预测基准）、K-map、时序图 | **openrios**：`work/or-be-draft/timing/` |
| 评估工具、链接脚本、case 模板 | **本目录**（OpenRio） |
| 生成的 `.S` / `.elf` / 日志 / 结果 | **仓库外**构建树 `perf_eval_work/` |

caselist 自身标注 `Normative timing sources: pending promotion to spec/or-be/`，
即它仍是 draft 且会持续变动。因此**一律按路径引用，不做拷贝** —— 拷贝会产生两份
会分叉的"预期"，最后拿过期基准去比 RTL。

## 2. 目录

```text
perf_eval/
├── README.md           本文件
├── METHOD.md           方法文档（caselist -> .S -> .elf -> 跑 -> 判定）
├── .gitignore          生成物安全网
├── templates/
│   ├── link.ld         链接脚本（0x80000000 起 + tohost）
│   └── case.S.in       case 模板（占位符由 gen_cases.py 渲染）
├── gen_cases.py        [待建] caselist(.md) -> .S
├── run_perf.sh         [待建] 包装 ../tools/verilator_cosim.sh
└── compare.py          [待建] sim.log -> cycle -> delta 表
```

仓库外的构建树：

```text
/work/home/danielle/workspace/suncheek/model/perf_eval_work/
├── README.md
├── manifest.yaml       记录 SHAs / 工具链版本（可复现性）
├── cases/              生成的 .S
├── elf/                编译产物 .elf
└── results/            抽取与比对结果
```

## 3. 依赖（实测版本）

| 依赖 | 版本 / 位置 |
|---|---|
| Verilator | 5.050（2026-07-01, rev v5.050） |
| RISC-V GCC | `/opt/riscv/bin/riscv64-unknown-elf-gcc`（GCC 11.1.0） |
| ISA model | `ISA_MODEL_ROOT`，或仓库 `dpi/` 下 vendored 版本 |
| ripgrep | `verilator_cosim.sh` 扫日志用 |

`verilator_cosim.sh` 默认会用 `riscv64-unknown-elf-objdump` 生成 `.dump`，
所以要么把 `/opt/riscv/bin` 加进 `PATH`，要么显式设 `OBJDUMP=`。

## 4. 观测口径

`tb/top/rtl_v1_obs.svh` 已把下列事件逐拍打拍到 `ob_cosim_if`，
`tb/agents/be/be_agent.sv` 在带 `cycle_count` 的日志里输出：

| caselist 术语 | 观测信号 | 日志行 |
|---|---|---|
| P1 / DSP 派发 | `obs_alloc_valid` + `alloc_tag` | `[BE][DECODE] cycle=… pc=…`（verbosity ≥ 2） |
| P3 bypass / ISQ issue | `isq_g0..g3_issue_*` | **待补打印** |
| P4 commit CDB | `obs_commit_valid` | `[BE][COMMIT] cycle=…`（verbosity ≥ 2） |
| P4 commit（含 cycle） | `commit_pc` | `[BE][COSIM_OB] cycle=… pc=…`（verbosity ≥ 1） |
| flush / recovery | `recovery_*` | `[BE][RECOVERY_FLUSH] cycle=…` |

caselist 的 delta 定义：

```text
delta = dependent first P1/DSP attempt cycle - producer first P1/DSP attempt cycle
```

**口径差异（重要）**：caselist 说的是 P1 **attempt**；观测面记录的是派发**被接受**
（`alloc_valid`）的那一拍 —— 被 dispatch 拒绝的拍不产生事件。case 设计需避开这一
歧义，或补打印 attempt。

## 5. DUT 选择

| 阶段 | DUT kind | 用途 |
|---|---|---|
| 1 | `rtl_v1` | **主力**：timing 符合性。caselist 预测量全是 BE 内部量，FE/Cache 用 agent 占位可隔离噪声 |
| 2 | `rtl_full` | 端到端：量 IPC / 总 cycle，看 FE 取指、redirect、Cache miss 的贡献 |

不要用 `rtl_full` 做主 timing 验证：delta_0 那类"同拍双发"的 case 依赖取指能否
同拍交付，在真实 FE 上很脆弱。

## 6. 待建

- [ ] `gen_cases.py` — caselist(.md) → `.S`（参数化 filler 扫 delta），输出到 `perf_eval_work/cases/`
- [ ] `run_perf.sh` — 包装 `../tools/verilator_cosim.sh run --dut-kind rtl_v1`
- [ ] `compare.py` — `sim.log` → P1/P3/P4 cycle → delta 表，与预测对表
- [ ] `be_agent.sv` 补 P3 / ISQ issue 的 per-cycle 打印
- [ ] templates/case.S.in 定稿（退出码寄存器约定等）

## 7. 运行形态（计划）

```bash
export PATH=/opt/riscv/bin:$PATH
OPENRIO=/work/home/danielle/workspace/suncheek/model/OpenRio
WORK=/work/home/danielle/workspace/suncheek/model/perf_eval_work

# 1. caselist -> .S
python3 $OPENRIO/verification/orbe_bt_env/perf_eval/gen_cases.py --out $WORK/cases/

# 2. .S -> .elf
$OPENRIO/verification/orbe_bt_env/perf_eval/run_perf.sh compile \
  --in $WORK/cases/ALU_to_ALU_delta_2.S --out $WORK/elf/ALU_to_ALU_delta_2.elf

# 3. 跑 rtl_v1
$OPENRIO/verification/orbe_bt_env/tools/verilator_cosim.sh run --no-build \
  --dut-kind rtl_v1 --tag perf_eval --verbosity 2 \
  --tc $WORK/elf/ALU_to_ALU_delta_2.elf
```

> ELF 必须按 case id 命名。日志目录名取自 ELF 的 basename
> （`sim/verilator_<TAG>/log/<kind>/<elf-name>_<SEED>/`），
> 若都叫 `case.elf` 会互相覆盖。
