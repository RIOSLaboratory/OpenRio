# OpenRio 回归操作指南（239 ISA + 19 Embench，双引擎）

> 面向执行者：按顺序做就能跑完。路径一律相对仓库根（`$REPO`），不写死任何账号目录。
> 三条铁律：**build 与 regress 用同一个 `tag`**；**`CASE_ROOT` 只在跑 Embench 时设置**；
> **VCS 只能在内网有 VCS 环境的服务器（如：cad21） 上跑**！！！

## 0. 速查

> 两个引擎共用同一套命令，只差 `--engine`。**`verilator` 是回归判据**；
> `vcs` 目前只用于波形/调试（现状见 6.3）。下面两张表分开列，避免混用。
>
> 下文命令都假定 `$REPO` 已设置；**每开一个新 shell 都要重设**：
> `export REPO=$(git rev-parse --show-toplevel)`。
> 临时文件统一放 `$SCRATCH`（自己的可写目录）：`export SCRATCH=<可写目录>`；
> 不要写 `$HOME`（吃家目录配额），也不要写死 `/tmp`（可能被别人占用）。

### 0.1 Verilator（回归判据）

| 任务 | 命令（在 `$REPO/verification` 下） | 期望 |
| --- | --- | --- |
| 环境自检 | `./tools/or_cosim.sh check --engine verilator` | 打印 verilator 版本与 ISA model 路径 |
| 构建 | `./tools/or_cosim.sh build --engine verilator --tag reg1` | 生成 `sim/verilator_reg1/build/be_tb_top_rtl_full` |
| 239 ISA | `SIM_TIMEOUT=200000 ./tools/or_cosim.sh regress --engine verilator --tag reg1 -j 16` | `PASS=235 FAIL=4 TOTAL=239` |
| 19 Embench | 见第 3 节（参数较多） | 19 条全部 `PASS` |
| 单条 | `./tools/or_cosim.sh run --engine verilator --tag reg1 --tc <elf>` | 日志里 `is_good=1` |
| 波形 | `./tools/or_cosim.sh wave --engine verilator --tag w1 --tc <elf>` | 生成 VCD/FST |

### 0.2 VCS（波形 / 调试；在装了 VCS 的机器上）

| 任务 | 命令 | 期望 |
| --- | --- | --- |
| 环境 | `cd verification/vcs_cosim && source ./env.sh` | 打印 VCS_HOME / VERDI_HOME / ISA_MODEL_ROOT / CXX |
| 自检 | `./tools/or_cosim.sh check --engine vcs` | `layout=build inc=... lib=...` |
| 构建 | `./tools/or_cosim.sh build --engine vcs --tag v1` | 约 10 s 出 `sim/vcs_v1/build/rtl_full/simv` |
| 单条 / 波形 | `run` / `wave --engine vcs --tag w1 --tc <elf>` | `is_good=1` / `*.fsdb` |
| 批量回归 | `SIM_TIMEOUT=200000 ./tools/or_cosim.sh regress --engine vcs --tag r1 -j 16` | 当前 `PASS=102 FAIL=137`（见 6.3，**暂不作判据**） |

`tag` 是产物命名空间，自取（`reg1`、`baseline`、`20261105` 都行）；换 tag 就要重新 build。

## 1. 准备

### 1.1 代码

```bash
git clone <内网仓库地址> openrio && cd openrio
export REPO=$(git rev-parse --show-toplevel)
```

### 1.2 用例（不在仓库里）

共享目录结构（`$CASE_SHARE` 由管理员提供，找 danielle 确认权限）：

```text
$CASE_SHARE/isa_case/                # 239 条 ELF
├── rv64ui/ rv64um/ rv64ua/ rv64uf/ rv64ud/ rv64uc/
└── rv64mi/ rv64si/
$CASE_SHARE/embench/orbe-baremetal/  # 19 个 ELF（无扩展名）
```

校验：

```bash
ls "$CASE_SHARE"/isa_case/*/*.riscv | wc -l        # 239
ls "$CASE_SHARE"/embench/orbe-baremetal | wc -l    # 19
```

### 1.3 环境变量

Verilator（必须有 5.050，没安装或者版本不对找 danielle 要压缩包）：

```bash
export VERILATOR=<verilator-5.050>/bin/verilator
export ISA_MODEL_ROOT=<ISA model 目录>      # 需含 src/libs/IsaApi.h 与 build/lib_ISA_api.so
unset ISA_API_INC ISA_API_LIB CASE_ROOT     # 残留会覆盖上面的设置
ulimit -c 0                                 # core dump 会吃光家目录配额
export LANG=C
```

VCS（额外）：

```bash
cd "$REPO/verification/vcs_cosim" && cp env.sh.example env.sh   # 首次，按现场改
source ./env.sh                                                 # 每次新开 shell 都要
```

## 2. 跑 239 条 ISA（预计 5-10 分钟）

```bash
cd "$REPO/verification"
./tools/or_cosim.sh build --engine verilator --tag reg1
SIM_TIMEOUT=200000 ./tools/or_cosim.sh regress --engine verilator --tag reg1 -j 16
```

开局先看这行，`case_root` 必须是 `$ISA_MODEL_ROOT/isa_case`：

```text
SUITE: cases_239 entries=239 case_root=... list_sha256=...
SUMMARY: PASS=235 FAIL=4 TOTAL=239 wall=...s
```

`FAIL=4` 是当前基线的已知失败（`rv64mi-p-access/breakpoint/csr`、`rv64si-p-dirty`），
`results.txt` 仍保留 239 行，不剔除。

结果：

```text
or_cosim/sim/verilator_reg1/regress/rtl_full/cases_239/{cases.list,results.txt,summary.txt}
```

## 3. 跑 19 条 Embench（预计 10 小时）

先跑 2 条 smoke（`ud`、`wikisort`），确认 `is_good` 链路正常：

```bash
export CASE_ROOT=<embench ELF 目录>
printf 'ud\nwikisort\n' > "$SCRATCH/emb_smoke.list"
SIM_TIMEOUT=20000000 ISA_LOG=none COSIM_OB_LOG=0 \
  ./tools/or_cosim.sh regress --engine verilator --tag reg1 -j 2 --list "$SCRATCH/emb_smoke.list"
```

再跑全量：

```bash
SIM_TIMEOUT=20000000 ISA_LOG=none COSIM_OB_LOG=0 \
  ./tools/or_cosim.sh regress --engine verilator --tag reg1 -j 16 \
  --list or_cosim/cfg/cases/cases_embench.list
```

`ISA_LOG=none COSIM_OB_LOG=0` 不能省：否则日志是 TB 级别，磁盘会被吃满。

## 4. 看单条判定

日志位置：`or_cosim/sim/verilator_<tag>/log/<dut>/<elf>_<seed>/sim.log`

```bash
grep -aE 'is_good|FE_EQUIV|CACHE_EQUIV|REPORTER_SUMMARY' sim.log | tail -5
```

判定 = 退出码 0 **且** 没有 `MISMATCH/%Error/%Fatal/Assertion failed/timeout` **且** 有 `is_good=1`。

超时（`simulation timeout`）时 TB 会自动打印 `[TB][STALL]` 快照，**不用再临时加探针**：

- 固定几行：卡死拍号、`global_flush_late`、BE↔LSU 边界、流水线活动
  （最后一次 alloc / commit / FE 交握的拍号）、每个 commit slot 一行
  （`tag` / 指令类型 / `done` / `exec_done` / `may_flush` / 已卡住多少拍）；
- 再按卡住那条指令的类型追加一个细节块：`STORE`/`ATOMIC` → 授权 + ISQ3 + cache→内存；
  `TRAP` → cause/tval；`BRANCH` → 跳转目标/redirect；`MRET`/`SRET`/`FENCE_I` → redirect；
  其余 → 写回信息 + 四个 ISQ 组 `issue_valid`。

> 快照的细节层读取 RTL 层次（`u_scoreboard` / `u_ISQ_GroupN`），RTL 重构
> （例如 CSR 迁往 IRU）时需要同步更新这一层。

## 5. 波形

### 5.1 Verilator → VCD → FSDB → Verdi

`TRACE` 是**构建期**开关，build 与 run 必须一致，且单独用一个 tag：

```bash
cd "$REPO/verification"
TRACE=1 ./tools/or_cosim.sh build --engine verilator --tag wave1
TRACE=1 ./tools/or_cosim.sh run   --engine verilator --tag wave1 --no-build --tc <elf>

VCD=or_cosim/sim/verilator_wave1/log/rtl_full/<elf>_1/<elf>.vcd
vcd2fsdb "$VCD" -o "${VCD%.vcd}.fsdb"
verdi -ssf "${VCD%.vcd}.fsdb" &
```

### 5.2 VCS → FSDB（原生，不用重编）

见下一节 `wave` 目标。

## 6. VCS Engine（VCS + Verdi）

> 只能在装了 VCS/Verdi 的机器上跑（如 `cad21`）。在只有 Verilator 的机器上编 VCS 会报
> `cannot find crti.o` —— 那是机器不对，不是文件缺失。

### 6.1 环境与自检

```bash
cd "$REPO/verification"
cd vcs_cosim && cp env.sh.example env.sh && cd ..   # 仅首次：按现场改 VCS_HOME/VERDI_HOME/CXX
source vcs_cosim/env.sh                              # 每次新开 shell 都要
./tools/or_cosim.sh check --engine vcs
```

`env.sh` 会打印 `VCS_HOME / VERDI_HOME / ISA_MODEL_ROOT / CXX / LD_LIBRARY_PATH`；
`check` 期望最后一行：

```text
layout=build inc=<...>/src/libs lib=<...>/build wave=fsdb
```

### 6.2 构建 / 单条 / 波形

```bash
./tools/or_cosim.sh build --engine vcs --tag v1     # 约 10 s
./tools/or_cosim.sh run   --engine vcs --tag v1 \
  --tc "$ISA_MODEL_ROOT/isa_case/rv64ui/rv64ui-p-add.riscv"
./tools/or_cosim.sh wave  --engine vcs --tag w1 \
  --tc "$ISA_MODEL_ROOT/isa_case/rv64ui/rv64ui-p-add.riscv"
verdi -ssf or_cosim/sim/vcs_w1/log/rtl_full/rv64ui-p-add_1/rv64ui-p-add.fsdb &
```

`wave` 与 `run` 共用同一个 `simv`（波形是**运行期**开关 `+WAVE=fsdb`），不需要重新 build。
产物与日志：

```text
or_cosim/sim/vcs_<tag>/build/<dut>/{simv,compile.log,dpi/libisa_dpi.so}
or_cosim/sim/vcs_<tag>/log/<dut>/<elf>_<seed>/{sim.log,<elf>.fsdb}
```

### 6.3 批量回归与现状

```bash
SIM_TIMEOUT=200000 ./tools/or_cosim.sh regress --engine vcs --tag r1 -j 16
```

参数与 Verilator 完全一致，结果在 `or_cosim/sim/vcs_r1/regress/rtl_full/cases_239/`。

> **现状（2026-11）**：VCS 侧 239 为 `PASS=102 FAIL=137`，原因是 BE 的 store 在 ISQ3→LSU
> 之间丢失（`entry_st_br_resolve` 与 `isq_valid_q` 不一致），已定位待 RTL 修复。
> **因此 VCS 结果暂不作 RTL 判据**，只用于波形/调试；回归口径仍以 Verilator 为准。

## 7. 双引擎回归与对差

前提：两个引擎各自跑出**同一个 tag** 的 `results.txt`。
两台机共享同一个挂载点、看到同一份 `or_cosim/sim/` 时，`compare` 不需要拷文件。

**第 1 步：Verilator 侧（跑回归的那台机）**

```bash
cd "$REPO/verification"
export ISA_MODEL_ROOT=<ISA model 目录>
unset ISA_API_INC ISA_API_LIB CASE_ROOT
./tools/or_cosim.sh build   --engine verilator --tag reg1
SIM_TIMEOUT=200000 ./tools/or_cosim.sh regress --engine verilator --tag reg1 -j 16
# 期望 SUMMARY: PASS=235 FAIL=4 TOTAL=239
```

**第 2 步：VCS 侧（装了 VCS 的机器，如 cad21）**

```bash
cd "$REPO/verification"
source vcs_cosim/env.sh
./tools/or_cosim.sh build   --engine vcs --tag reg1        # 与第 1 步同一个 tag
SIM_TIMEOUT=200000 ./tools/or_cosim.sh regress --engine vcs --tag reg1 -j 16
# 当前期望 SUMMARY: PASS=102 FAIL=137 TOTAL=239（原因见 6.3）
```

**第 3 步：对差**

```bash
cd "$REPO/verification"
./tools/or_cosim.sh compare --tag reg1
```

- 两边一致 → 打印 `IDENTICAL`，退出码 0；
- 有差异 → 打印逐行 diff（`<` Verilator，`>` VCS），退出码 1。

**两台机不共享盘时**：只需搬一份 `results.txt`，放到相同的相对路径。

```bash
# VCS 机器上打包
tar czf "$SCRATCH/vcs_reg1.tgz" -C or_cosim/sim/vcs_reg1/regress/rtl_full cases_239
# Verilator 机器上解回去（路径与打包时相同）
mkdir -p or_cosim/sim/vcs_reg1/regress/rtl_full
tar xzf "$SCRATCH/vcs_reg1.tgz" -C or_cosim/sim/vcs_reg1/regress/rtl_full
```

对差前先核一件事：两边 `SUITE:` 行的 `list_sha256` 必须相同，否则跑的不是同一批用例。

## 8. 日回归 / 周回归

```bash
cd "$REPO/verification"
tools/regress_cron.sh --suite daily  --engine verilator -j 16                          # 239
CASE_ROOT=<ELF 目录> tools/regress_cron.sh --suite weekly --engine verilator -j 16     # 19 Embench
```

- tag 自动命名：`daily-YYYYMMDD` / `weekly-YYYYWww`；
- 只报**新增失败**（`NEW_FAIL`/`FIXED`），退出码 `0` 无新增 / `1` 有新增 / `3` 基础设施失败；
- 历史 `or_cosim/sim/regress_history/<engine>_<suite>/`，结果树按套件保留最近 N 份（`--keep`）。

cron（**没有 profile，必须自己 source**）：

```cron
0 2 * * *  cd $REPO/verification && source vcs_cosim/env.sh && tools/regress_cron.sh --suite daily --engine verilator -j 16 >> "$SCRATCH/reg_daily.log" 2>&1
```

## 9. 常见问题

| 现象 | 处理 |
| --- | --- |
| `%Error-PKGNODECL ... isa_dpi_pkg` 后跟着一堆语法错 | Verilator 版本过旧，必须 5.050 |
| `error: ... simulator executable is not readable` | 没 build 或 tag 不一致；先 build 同 tag |
| 239 条秒 FAIL、`no is_good=1` | 大多没跑起来：查 build 产物、`ISA_MODEL_ROOT`、`CASE_ROOT` 是否误设 |
| `SUMMARY: PASS=0 FAIL=0` | 结果写不进去，多数是**家目录配额满**；`ulimit -c 0` 并清理旧 `sim/*` |
| `cannot find crti.o` | 在**没有 VCS 工具链**的机器上编 VCS；换到装了 VCS 的机器 |
| 链接报 `__isoc23_strtoull@GLIBC_2.38` | `ISA_API_LIB` 指向了别的机器编的 `.so`；`unset ISA_API_INC ISA_API_LIB` |
| Embench 全部超时 | `SIM_TIMEOUT` 太小 |
| Embench 跑完磁盘暴涨 | 没加 `ISA_LOG=none COSIM_OB_LOG=0` |
| 删目录报 `Directory not empty` | NFS 上还有进程持有文件（`.nfsXXXX`），先关掉对应进程（如 Verdi） |

## 10. 双引擎差异定位（实验方法）

VCS 与 Verilator 结果不一致时，先分清是**初始化**问题还是 **X 传播**问题。

> **两个引擎都定义 `SYNTHESIS`**：Verilator 在 `or_cosim/tools/verilator_cosim.sh` 里加
> `-DSYNTHESIS`，VCS 在 `vcs_cosim/Makefile` 里加 `+define+SYNTHESIS`。所以两边
> `` `ifndef SYNTHESIS `` 里的断言都被编译掉，**这个宏不是两引擎差异的来源**；
> 剩下的差异只有 2 态 vs 4 态。

Verilator 没有 X，只能用「确定值代理未知初值」：

```bash
cd "$REPO/verification"
export ISA_MODEL_ROOT=<ISA model 目录>
unset ISA_API_INC ISA_API_LIB CASE_ROOT

# 对照（与基线完全相同）
./tools/or_cosim.sh build --engine verilator --tag xbase
# 未初始化信号取互不相同的伪随机值
VERILATOR_EXTRA_FLAGS="--x-initial unique --x-assign unique" \
  ./tools/or_cosim.sh build --engine verilator --tag xuniq
# 同上，且初值在 t=0 产生跳变
VERILATOR_EXTRA_FLAGS="--x-initial unique --x-assign unique --x-initial-edge" \
  ./tools/or_cosim.sh build --engine verilator --tag xedge
```

每条用例在三个 tag 下各跑一次（`--no-build`），记录 `is_good` / `FE_EQUIV` / 是否 timeout：

```bash
for t in xbase xuniq xedge; do
  for tc in rv64um/rv64um-v-div rv64ua/rv64ua-p-amoadd rv64ui/rv64ui-p-sb rv64ui/rv64ui-p-add; do
    SIM_TIMEOUT=200000 ./tools/or_cosim.sh run --engine verilator --tag "$t" --no-build \
      --tc "$ISA_MODEL_ROOT/isa_case/$tc.riscv"
    echo "$t $tc: $(grep -aE 'is_good=1|simulation timeout' \
      or_cosim/sim/verilator_$t/log/rtl_full/$(basename $tc)_1/sim.log | tail -1)"
  done
done
```

| `xbase` | `xuniq`/`xedge` | 结论 |
| --- | --- | --- |
| 通过 | 挂死 | **初始化问题**：RTL 依赖未初始化状态（复位缺口），按快照的 head `tag`/`kind` 继续定位 |
| 通过 | 通过 | **X 传播问题**：在 VCS 侧用 `$isunknown()` 扫描被 X 污染的比较/使能信号 |
| 挂死 | 任意 | 实验无效（tag/构建/用例错），先修实验 |

对照用例 `rv64ui-p-add` 在所有变体下都必须通过；它若也挂，说明变体把设计整体搞崩，结论作废。
实验后清理：`rm -rf or_cosim/sim/verilator_x{base,uniq,edge}`。

## 附：目录结构

```text
verification/
├── tools/or_cosim.sh          # 双引擎唯一入口
├── tools/regress_cron.sh      # 日/周回归
├── or_cosim/                  # TB、cfg、dpi、Verilator 脚本、sim 产物
│   └── sim/{verilator,vcs}_<tag>/{build,log,regress}
└── vcs_cosim/                 # VCS/Verdi 引擎（Makefile、regress.sh、env.sh）
```
