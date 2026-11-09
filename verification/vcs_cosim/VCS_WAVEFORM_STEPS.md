# VCS 原生 FSDB 波形步骤（工作记录，未完成验证）

> **路径已过时（2026-11-04）**：文中 `verification/vcs_cosim/sim/...` 现在位于
> `verification/or_cosim/sim/vcs_<tag>/`，与 Verilator 的 `sim/verilator_<tag>/` 对称。
> 当前可用的命令与目录以 [`README.md`](README.md) 和
> [`../REGRESSION_GUIDE.md`](../REGRESSION_GUIDE.md) 第 8 节为准；本文只作过程记录。

> 状态：2026-11-02，脚本已写完并通过 `make -n` 静态展开检查；
> **尚未在 dev2 上真正执行 `make build`**。
>
> 目标：VCS 直接生成 FSDB，Verdi 中保留 `be_tb_top.u_backend`、`u_fe`、`u_cache`
> 的层次关系；不再走 Verilator VCD → `vcd2fsdb`。
>
> 约束：不修改 `verification/or_cosim/tools/verilator_cosim.sh`、
> `regress.sh`、`tb/`、`cfg/filelist/`；新增独立目录 `verification/vcs_cosim/`。

---

## 0. 当前 dev2 环境（已确认存在）

| 变量 | 当前值 | 检查 |
| --- | --- | --- |
| `REPO_ROOT` | `/work/home03/danielle/hardware/hardware-openrio` | OpenRio 仓库根目录 |
| `VCS_HOME` | `/eda/synopsys/vcs/T-2022.06-SP2` | `include/svdpi.h` 存在 |
| `VCS_INCLUDE_DIR` | `$VCS_HOME/include`（可覆盖） | 实际放 `svdpi.h` 的目录 |
| `VERDI_HOME` | `/eda/synopsys/verdi/T-2022.06-SP2-3` | `share/PLI/VCS/LINUX64/` 存在 |
| `FSDB_PLI_DIR` | `$VERDI_HOME/share/PLI/VCS/LINUX64` | `novas.tab`、`pli.a` 存在 |
| `ISA_MODEL_ROOT` | `/work/home03/danielle/isa_model` | `src/libs/IsaApi.h`、`build/lib_ISA_api.so` 存在 |
| `VCS` | `/eda/synopsys/vcs/T-2022.06-SP2/bin/vcs` | 可执行 |
| `VERDI` | `$VERDI_HOME/bin/verdi`（→ `.wrapper`） | 用 `bash` 调用 |

已确认的文件：

```text
$VCS_HOME/include/svdpi.h
$VERDI_HOME/share/PLI/VCS/LINUX64/novas.tab
$VERDI_HOME/share/PLI/VCS/LINUX64/pli.a
$ISA_MODEL_ROOT/src/libs/IsaApi.h
$ISA_MODEL_ROOT/build/lib_ISA_api.so
```

注意：

- `command -v verdi` 会打印 alias，不是路径：
  ```text
  alias verdi='bash $VERDI_BIN/verdi'
  ```
- `verdi -version` 可能会直接拉起 GUI；不要用这种方式查版本。
- `$VERDI_HOME/bin/verdi` 是 symlink（→ `.wrapper`），启动时用：
  ```bash
  bash "$VERDI_HOME/bin/verdi" -ssf xxx.fsdb &
  ```

---

## 1. 目录与解耦

新增目录：

```text
verification/vcs_cosim/
├── Makefile
├── README.md
├── env.sh.example
├── .gitignore
└── VCS_WAVEFORM_STEPS.md   # 本文件
```

只读复用：

```text
verification/or_cosim/cfg/filelist/*
verification/or_cosim/dpi/isa_dpi_pkg.sv
verification/or_cosim/dpi/isa_dpi_wrapper.cc
verification/or_cosim/tb/*
```

不修改 Verilator/ST 流程。VCS 脚本可以独立删除，不影响 `regress.sh`。

---

## 2. 环境准备

```bash
cd "$REPO_ROOT/verification/vcs_cosim"
cp env.sh.example env.sh
```

`env.sh`：

```bash
export VCS_HOME=/eda/synopsys/vcs/T-2022.06-SP2
export VERDI_HOME=/eda/synopsys/verdi/T-2022.06-SP2-3
export FSDB_PLI_DIR="$VERDI_HOME/share/PLI/VCS/LINUX64"
export ISA_MODEL_ROOT=/work/home03/danielle/isa_model
export PATH="$VCS_HOME/bin:$VERDI_HOME/bin:$PATH"
```

```bash
source env.sh
```

---

## 3. VCS build

```bash
make build TAG=vcs1 DUT_KIND=rtl_full
```

关键编译参数：

```text
-full64 -sverilog -timescale=1ns/1ps
-debug_access+all -kdb
+define+VCS_FSDB
-P $FSDB_PLI_DIR/novas.tab $FSDB_PLI_DIR/pli.a
+define+SYNTHESIS
+define+ORBE_EXTERNAL_MNEMONICS
+define+ORBE_DUT_RTL_V1 +define+ORBE_FE_RTL +define+ORBE_CACHE_RTL
```

文件顺序：

```text
dpi/isa_dpi_pkg.sv
-f cfg/filelist/common.f
-f cfg/filelist/rtl_full.f
-f cfg/filelist/tb.f
```

`isa_dpi_pkg.sv` 必须在 `common.f` 前面，因为 `orbe_predictor_pkg` 会
`import isa_dpi_pkg::*`。

DPI adapter 单独编共享库：

```bash
g++ -std=c++17 -O2 -fPIC -shared \
  -I"$ISA_API_INC" -I"$VCS_HOME/include" \
  verification/or_cosim/dpi/isa_dpi_wrapper.cc \
  -L"$ISA_API_LIB" -l_ISA_api \
  -Wl,-rpath,"$ISA_API_LIB" \
  -o .../libisa_dpi.so
```

输出：

```text
verification/vcs_cosim/sim/vcs1_rtl_full_fsdb/build/simv
verification/vcs_cosim/sim/vcs1_rtl_full_fsdb/build/dpi/libisa_dpi.so
verification/vcs_cosim/sim/vcs1_rtl_full_fsdb/build/compile.log
```

---

## 4. 跑单条 case 并生成 FSDB

```bash
make fsdb \
  TAG=vcs1 \
  DUT_KIND=rtl_full \
  TC="$ISA_MODEL_ROOT/isa_case/rv64ui/rv64ui-p-add.riscv"
```

运行时关键参数：

```text
-sv_lib .../libisa_dpi
+TEST=elf
+ntb_random_seed=1
+SIM_TIMEOUT_CYCLES=200000
+VERBOSITY=3
+COSIM_ENABLE=1
+COSIM_BACKEND=isa_step
+COSIM_OB_LOG=1
+ISA_CFG=.../rivai_0x80000000_1core_rom.yaml
+ISA_ELF=.../rv64ui-p-add.riscv
+ISA_RUN_LOG=...
+ISA_COMMIT_LOG=...
+FSDB_FILE=.../rv64ui-p-add.fsdb
```

VCS 原生 FSDB 由 TB 里的现有代码产生：

```systemverilog
`ifdef VCS_FSDB
  initial begin : fsdb_dump
    if (!$value$plusargs("FSDB_FILE=%s", fsdb_file)) fsdb_file = "be_tb_top.fsdb";
    $fsdbDumpfile(fsdb_file);
    $fsdbDumpvars(0, be_tb_top);
  end
`endif
```

`$fsdbDumpvars(0, be_tb_top)` 是保留层次的关键；它直接来自 VCS，不经过
`vcd2fsdb`。

输出：

```text
verification/vcs_cosim/sim/vcs1/log/rtl_full/rv64ui-p-add_1/sim.log
verification/vcs_cosim/sim/vcs1/log/rtl_full/rv64ui-p-add_1/rv64ui-p-add.fsdb
```

---

## 5. Verdi 打开

```bash
bash "$VERDI_HOME/bin/verdi" -ssf \
  "$REPO_ROOT/verification/vcs_cosim/sim/vcs1/log/rtl_full/rv64ui-p-add_1/rv64ui-p-add.fsdb" &
```

在 Verdi 中：

- Scope 选 `be_tb_top`；
- 展开 `u_backend`、`u_fe`、`u_cache`、`u_icache`；
- `Signal → Get Signals` 添加信号；
- `View → Go To Time` 的时间单位是 ps。

---

## 6. 与 Verilator VCD → FSDB 的区别

| 项 | Verilator 路径 | VCS 路径 |
| --- | --- | --- |
| 波形格式 | VCD/FST | FSDB |
| 生成方式 | `TRACE=1` + `$dumpvars` | `+define+VCS_FSDB` + `$fsdbDumpvars` |
| 是否需要 `vcd2fsdb` | 需要 | **不需要** |
| 层次 | 取决于 VCD/dump 设置 | FSDB 原生保留 |
| 入口 | `or_cosim/tools/verilator_cosim.sh` | `verification/vcs_cosim/Makefile` |
| 回归 | 已支持 239/19 | 尚未接 regression，仅单条 |

---

## 7. 当前状态与待确认

已完成：

- 新增 `verification/vcs_cosim/`，未改 Verilator/ST；
- Makefile 通过 `make -n` 静态展开检查；
- VCS/Verdi/PLI/ISA model 路径已确认。

未完成：

- **尚未在 dev2 上真正 `make build`**；
- 尚未确认站点是否需要额外 VCS 参数（`-lca`、`-vc` 等）；
- 尚未确认 `isa_dpi_wrapper.cc` 与 `-sv_lib` 的链接是否一次通过；
- 尚未接 239/19 全量 regression。

首次 build 后需要记录：

```text
compile.log 的第一处错误（如果有）
vcs -ID 输出
g++ --version
实际使用的 VCS_EXTRA_FLAGS
```

---

## 8. 踩过的坑

| 现象 | 原因 / 处理 |
| --- | --- |
| `verdi -version` 拉起 GUI | `verdi` 是 alias；不要用 `-version` 查版本，直接看 `$VERDI_HOME/bin/verdi` 和 PLI 文件 |
| `command -v verdi` 输出 alias | alias 不是路径；Makefile 只用 `VERDI_HOME`，启动用 `$VERDI_HOME/bin/verdi` |
| `/bin/sh: 0: Illegal option -h` | Verdi wrapper 的启动噪声；确认没有真实仿真在跑后关掉 GUI 即可 |
| 误开 Verdi/VCS | `Ctrl+C` 先回 shell；`pgrep -u "$USER" -af 'verdi\|vcs\|simv'` 找自己的 PID，再 `kill`；不要 `killall` |
| 找不到 FSDB | 确认 `WAVE=fsdb`、`+define+VCS_FSDB`、`+FSDB_FILE` 都生效；VCS 不会生成 Verilator 的 `.vcd` |
| `PKGNODECL isa_dpi_pkg` | 文件顺序错误；`isa_dpi_pkg.sv` 必须在 `common.f` 前 |
| `missing .../include/svdpi.h` | `VCS_HOME` 和实际包含 `svdpi.h` 的 install 可能分离；用 `find /eda/synopsys/vcs -maxdepth 4 -name svdpi.h` 找到后设 `VCS_INCLUDE_DIR` |

---

## 9. 未来并入 REGRESSION_GUIDE 的章节草案

建议在现有 “7.1 波形：Verilator VCD → FSDB → Verdi” 之后新增：

```text
7.2 波形：VCS 原生 FSDB（独立 Makefile）
  7.2.1 适用范围
  7.2.2 环境变量：VCS_HOME / VERDI_HOME / FSDB_PLI_DIR / ISA_MODEL_ROOT
  7.2.3 make build
  7.2.4 make fsdb
  7.2.5 Verdi 打开与层次导航
  7.2.6 与 Verilator VCD 路径的区别
  7.2.7 常见问题
```

等 dev2 首次 build/FSDB 验证通过后，再把本文压缩成正式章节，避免把未验证步骤写进主指南。

---

## 10. cad21 环境结论（2026-11-03）

dev2 上的 VCS 走不通，结论是**二进制/glibc ABI 不兼容**，不是配置问题：

- `vcs` 是 ksh 脚本（`#!/bin/sh -h`），`/bin/sh` 在 Ubuntu 上是 dash，直接
  `Illegal option -h`；换成 bash / mksh / ksh93 之后又分别在脚本语法处失败。
- 真正绕不过去的是 `vcs1`：ELF 依赖旧版 glibc，在 glibc 2.35 上报
  `GLIBC_PRIVATE not found`（系统 `/lib/x86_64-linux-gnu/libpthread.so.0`）。
  VCS 安装目录里没有随包的 `libpthread`，无法补。
- `vcd2fsdb` 在 dev2 能跑，因为它属于 Verdi，不是 `vcs1`。

所以 VCS 原生 FSDB 只能在 cad21（CentOS 7 / glibc 2.17）上做。

### 10.1 工具链

cad21 系统 `g++` 是 7.5.0，编不了 C++20 的 ISA model。内网函数模型仓库的
`env.sh` 提供了唯一正确的编译器：

```bash
cat <function-model>/env.sh
# export CC=/work/home/proj_common/gcc_14_x86/bin/gcc
# export CXX=/work/home/proj_common/gcc_14_x86/bin/g++
# export LD_LIBRARY_PATH=/work/home/proj_common/gcc_14_x86/lib64:$LD_LIBRARY_PATH

cd <function-model> && source env.sh
echo "$CXX"; "$CXX" --version | head -1     # 期望 14.2.1
```

注意 `which g++` 永远返回 `/usr/bin/g++`，因为 `env.sh` 只导出 `CC`/`CXX`，
没有改 `PATH`。**判断工具链要看 `$CXX`，不要看 `which g++`。**

### 10.2 ISA model 必须在本机重编

`lib_ISA_api.so` 依赖构建主机的 glibc 符号版本，跨主机直接用会报
`GLIBC_2.3x not found`。cad21 上重编流程：

```bash
source <function-model>/env.sh          # 只要工具链

cd /work/home03/danielle/isa_model_cad21
rm -rf build                            # 旧 CMakeCache 会把编译器钉在 /usr/bin/c++ (7.5.0)

cmake -S . -B build -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_C_COMPILER="$CC" -DCMAKE_CXX_COMPILER="$CXX"
cmake --build build --parallel

objdump -T build/lib_ISA_api.so \
  | grep -oE 'GLIBC_[0-9]+(\.[0-9]+)+' | sort -Vu | tail -1   # 必须是 GLIBC_2.17
```

关键点：

- `rm -rf build` 不能省。`CMAKE_CXX_COMPILER` 是缓存变量，写进去之后不会
  被环境变量 `CXX` 覆盖，表现为一直报 `cxx_std_20 is not known to GNU 7.5.0`。
- 不要用内网 `function-model` 的 `lib_ISA_api.so`：它把 BE 元数据搬到了
  `include/ext/IsaApiExt_BE.h`，和本目录的 `isa_dpi_wrapper.cc`（依赖
  `IsaApi.h` 内联的 `IsaApiDecodeMetadata` / `IsaApiLsuIssueMetadata` /
  `IsaApiCommitTrapInfo`）不兼容。`env.sh` 只借工具链，库要用自己这条线编。
- 编译前可用头文件大小做快速判别：`IsaApi.h` 22387 B / 445 行且
  `grep -c IsaApiLsuIssueMetadata src/libs/IsaApi.h` 为正，才是对的版本。

### 10.3 从 beta_be_bt_new 借鉴的改动

`openrios/verification/beta_be_bt_new` 是已在内网跑通的 VCS 环境，其中与
VCS 相关的做法已并入本目录：

| 借鉴点 | 本目录的落地 |
| --- | --- |
| FSDB 编译期常开、运行期 `+WAVE=fsdb` 选择 | `FSDB_FLAGS` 不再依赖 `$(WAVE)`；`VCS_BUILD_NS` 去掉 `WAVE`；`fsdb: WAVE := fsdb` |
| `$fsdbDumpvars(0, top, "+all")` + `$fsdbDumpMDA()` | `tb/top/be_tb_top.sv` 的 `VCS_FSDB` 段，存储器/数组在 Verdi 里不再为空 |
| `-Mdir` + `-Mupdate` 增量编译 | `VCS_FLAGS` 增加 `-Mupdate` |
| `LD_LIBRARY_PATH` 同时覆盖编译期和运行期 | `$(SIMV)` 和 `run` 两条规则都注入 `$(ISA_API_LIB):$(dir $(DPI_LIB))` |
| gcc14 `lib64` 进 `LD_LIBRARY_PATH` | `env.sh.example` 中显式导出 |
| 仿真日志用 `tee`（`-l` 收不到 DPI printf） | `run` 改为 `bash -o pipefail` + `tee` |
| ISA model 双布局（build tree / install tree） | `ISA_MODEL_LAYOUT` 自动探测 |
