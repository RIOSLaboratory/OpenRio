# OpenRio 内网 Regression 操作（239 ISA + Embench）

> Steps：取代码 → 取用例 → 构建 → 跑 239 条 ISA → 跑 19 条 Embench。
>
> 适用版本：2026-10-22 的 `regress.sh` / `verilator_cosim.sh`
>
> （支持 `CASE_ROOT`、`ISA_LOG`、`COSIM_OB_LOG`；已修正 `isa_dpi_pkg` 编译顺序）
>
> 注：`isa_dpi_pkg` 的顺序修正目前只在 cad1 工作区和 2026-10-22 之后生成的交付包中。
> 内网 GitLab 分支合并前，`git pull` 不会带来这个改动，请按 1.2 节手动修改或从新包覆盖。

---

## 0. 先看结论

| 回归 | 用例数 | 入口命令（在 `verification/or_cosim` 下执行） | 预期结果 |
| --- | --- | --- | --- |
| ISA | 239 | `SIM_TIMEOUT=200000 tools/regress.sh rtl_full reg1 8` | `PASS=232 FAIL=7`（7 条为已知失败：6 mi + 1 si） |
| Embench | 19 | `SIM_TIMEOUT=20000000 ISA_LOG=none COSIM_OB_LOG=0 tools/regress.sh rtl_full reg1 16 cfg/cases/cases_embench.list` | 19 条全部 `PASS`（首次以实际为准） |

> 上面统一用 `reg1` 作为 tag。tag 的含义、为什么 build 和 regress 必须一致，见 0.1 节。
>
> 首次接入先按 6.1 跑 2 条 smoke；smoke 通过后，日常固定跑 6.2 的 **19 条 / 16 并行**。

### 0.1 `tag` 是什么

`tag` 是**构建产物和日志的命名空间**，只决定文件放在哪个目录，不改变 RTL、DUT 配置
或用例内容。它不是固定数字，也不是要照抄的字样；命令行里要换成你自己起的一个字符串，
例如 `reg1`、`baseline`、`emb1`、`20261021`。

```text
verification/or_cosim/sim/verilator_<tag>/
├── build/
│   ├── obj_<dut-kind>/
│   └── be_tb_top_<dut-kind>          # build 生成的仿真器
├── log/
│   └── <dut-kind>/<case>_1/sim.log   # 单条运行日志
└── regress/
    └── <dut-kind>/<清单名>/          # 批量回归结果
        ├── results.txt
        └── summary.txt
```

例如 `--tag reg1` 对应 `sim/verilator_reg1/`。

**为什么 build 和 regress 必须用同一个 tag**：`regress.sh` 调用的是
`verilator_cosim.sh run --no-build --tag <tag>`，`--no-build` 会直接去找
`sim/verilator_<tag>/build/be_tb_top_<dut-kind>`。tag 不一致就会报：

```text
error: Verilator simulator executable is not readable: .../sim/verilator_<tag>/build/be_tb_top_<dut-kind>
```

所以 tag 和 dut-kind 两个都要一致：

```bash
tools/verilator_cosim.sh build --dut-kind rtl_full --tag reg1
SIM_TIMEOUT=200000 tools/regress.sh rtl_full reg1 8
#                                   ^dut-kind  ^tag
```

**不写 tag 会怎样**：`verilator_cosim.sh` 默认用当天日期：

```bash
TAG=${TAG:-$(date +%Y%m%d)}     # 例如 20261021
```

同一天 build + regress 能对上；跨天就会变成另一个 tag，导致找不到之前 build 的
可执行文件。建议显式写一个固定名字。

**命名建议**：不含 `/`、空格；推荐 `reg1`（日常基线）、`emb1`（Embench）、
`wave1`（`TRACE=1` 的波形构建，必须单独一套，不能和 `reg1` 混用）。

> 文档里用 `<tag>` 表示“这里填你自己的 tag”，**不要把尖括号一起粘贴**：
> `--tag <tag>` 会被 shell 当成重定向。本文其余示例统一用 `reg1`。

### 0.2 路径约定

本文统一使用两个路径变量：

```bash
REPO=/work/home03/danielle/hardware/hardware-openrio   # GitLab clone，日常运行目录
CASE_SHARE=/work/home03/danielle/regression_cases      # 共享用例目录（239 + Embench）
```

- `$REPO` 是内网 GitLab 仓库 `hardware-openrio` 的 clone，验证代码和 RTL 都在这里；
- `$CASE_SHARE` 是维护人开放读权限的共享目录，只放用例 ELF；
- `hardware-openrio-verif-src-*.tar.gz` 解压出来的 `hardware-openrio-verif-src-<date>-emb/`
  只是**源码快照**，用于首次取 Embench ELF 或离线构建，**不是日常运行目录**。

> 上面的 `REPO` 是按当前维护机（10.101.10.32）写的示例；新用户 clone 到自己的目录后，
> 把 `REPO` 改成自己的路径即可。`CASE_SHARE` 则统一指向维护机上的共享目录。

---

## 1. 代码位置、怎么取

### 1.1 内网仓库结构

`hardware-openrio` 仓库中的验证代码和 DUT RTL：

```text
hardware-openrio/
├── src/core/
│   ├── be_rtl_v1/                     # 后端 RTL
│   ├── fe_rtl_v1/                     # 前端 RTL
│   └── cache_rtl_v1/                  # Cache RTL
└── verification/
    ├── README.md
    ├── REGRESSION_GUIDE.md            # 本文
    └── or_cosim/
        ├── tb/                        # testbench / agents / interfaces
        ├── cfg/
        │   ├── filelist/              # 各 DUT kind 的编译清单
        │   └── cases/
        │       ├── cases_239.list     # 239 条 ISA 清单
        │       └── cases_embench.list # 19 条 Embench 清单
        ├── dpi/                       # ISA model DPI 桥接
        ├── tools/
        │   ├── verilator_cosim.sh     # 构建 + 单条运行
        │   ├── regress.sh             # 批量回归
        │   └── pack_verif_src.sh      # 打包工具
        └── docs/
```

> **239 条 ISA 的 ELF 不在 git 仓库里**，位置在 `$CASE_SHARE/isa_case/`

### 1.2 clone 代码

内网 GitLab 地址以团队实际地址为准，示例：

```bash
git clone <内网 GitLab>/<group>/hardware-openrio.git
cd hardware-openrio

export REPO=$(pwd)                # 例如 /work/home03/danielle/hardware/hardware-openrio
git branch -a                    # 现在分支名：OpenRio_dev
git checkout OpenRio_dev
git pull --ff-only origin OpenRio_dev
```

如果本机已经有工作副本（本文的 `$REPO`），直接更新：

```bash
export REPO=/work/home03/danielle/hardware/hardware-openrio
cd "$REPO"
git branch -a
git fetch origin
git checkout dev
git pull --ff-only origin dev
```

检查验证代码是否就位（以下命令都在 `$REPO` 下执行）：

```bash
cd "$REPO"
ls verification/or_cosim/tools/regress.sh
ls verification/or_cosim/tools/verilator_cosim.sh
ls verification/or_cosim/cfg/cases/cases_239.list
ls verification/or_cosim/cfg/cases/cases_embench.list
```

再确认脚本是新版本（否则不会有 `CASE_ROOT` / `COSIM_OB_LOG`）：

```bash
grep -q 'CASE_ROOT'    verification/or_cosim/tools/regress.sh        && echo "regress.sh OK"
grep -q 'COSIM_OB_LOG' verification/or_cosim/tools/verilator_cosim.sh && echo "verilator_cosim.sh OK"
```

再确认 `isa_dpi_pkg` 的编译顺序（2026-10-22 之后的脚本才包含这个修正）：

```bash
grep -n -A6 'sv_inputs=' verification/or_cosim/tools/verilator_cosim.sh
```

期望 `dpi/isa_dpi_pkg.sv` 出现在 `-f cfg/filelist/common.f` **之前**。

> **`grep` 只检查，不会修改文件。** 如果顺序还是旧的，按下面任一方式处理：
>
> **A. 内网 GitLab 已合并该修正**：
> ```bash
> cd "$REPO"
> git pull --ff-only origin dev
> ```
>
> **B. GitLab 还没合并（当前情况）**：手动改
> `verification/or_cosim/tools/verilator_cosim.sh`，把 `dpi/isa_dpi_pkg.sv`
> 移到 `-f cfg/filelist/common.f` 之前：
> ```bash
> sv_inputs=(
>   dpi/isa_dpi_pkg.sv
>   -f cfg/filelist/common.f
>   -f "$rtl_filelist"
>   -f cfg/filelist/tb.f
> )
> ```
> 或从 2026-10-22 之后生成的交付包覆盖该文件。
>
> 改完再执行上面的 `grep` 确认。

> 如果 `cfg/cases/cases_239.list` 或 `cases_embench.list` 不存在，说明当前分支还没合并
> 2026-10-21 的回归改动。可以更新分支，或从交付包的
> `verification/or_cosim/cfg/cases/` 下取这两个清单文件。

---

## 2. 用例在哪里、怎么取

用例分两部分：239 条 ISA 和 19 条 Embench ELF。它们不在 GitLab 仓库里，统一放在
维护人开放读权限的共享目录：

```bash
export CASE_SHARE=/work/home03/danielle/regression_cases
```

```text
$CASE_SHARE/
├── isa_case/
│   └── rv64ui/ ... rv64si/        # 239 条
└── embench/
    ├── orbe-baremetal/            # 19 个 ELF
    └── SHA256SUMS
```

> 这些 ELF 不在 GitLab 仓库里，所以是“拷贝”而不是 `git clone`。
> 维护人需确认 `chmod -R a+rX "$CASE_SHARE"`，并用 `namei -l` 检查父目录可进入。

### 2.1 在 10.101.10.32 上：从共享目录复制 （前提是有RIOS服务器权限）

```bash
export ISA_MODEL_ROOT=$HOME/isa_model
mkdir -p "$ISA_MODEL_ROOT/isa_case" "$HOME/embench/orbe-baremetal"

cp -r "$CASE_SHARE/isa_case/." "$ISA_MODEL_ROOT/isa_case/"
cp -r "$CASE_SHARE/embench/orbe-baremetal/." "$HOME/embench/orbe-baremetal/"
cp "$CASE_SHARE/embench/SHA256SUMS" "$HOME/embench/"
```

### 2.2 在其他机器上：从 10.101.10.32 拉取

需要有 10.101.10.32 的 SSH 账号：

```bash
export ISA_MODEL_ROOT=$HOME/isa_model
mkdir -p "$ISA_MODEL_ROOT/isa_case" "$HOME/embench/orbe-baremetal"

scp -r <user>@10.101.10.32:"$CASE_SHARE/isa_case/." "$ISA_MODEL_ROOT/isa_case/"
scp -r <user>@10.101.10.32:"$CASE_SHARE/embench/orbe-baremetal/." "$HOME/embench/orbe-baremetal/"
scp <user>@10.101.10.32:"$CASE_SHARE/embench/SHA256SUMS" "$HOME/embench/"
```

有 `rsync` 更稳：

```bash
rsync -av <user>@10.101.10.32:"$CASE_SHARE/isa_case/" "$ISA_MODEL_ROOT/isa_case/"
rsync -av <user>@10.101.10.32:"$CASE_SHARE/embench/" "$HOME/embench/"
```

### 2.3 校验

```bash
for d in rv64ui rv64um rv64ua rv64uf rv64ud rv64uc rv64mi rv64si; do
  printf "%-8s %3d\n" "$d" \
    "$(find "$ISA_MODEL_ROOT/isa_case/$d" -maxdepth 1 -name '*.riscv' 2>/dev/null | wc -l)"
done

find "$ISA_MODEL_ROOT/isa_case"/{rv64ui,rv64um,rv64ua,rv64uf,rv64ud,rv64uc,rv64mi,rv64si} \
  -maxdepth 1 -name '*.riscv' | wc -l          # 239

ls "$HOME/embench/orbe-baremetal" | wc -l      # 19
(cd "$HOME/embench/orbe-baremetal" && sha256sum -c ../SHA256SUMS | tail -3)
```

### 2.4 共享目录不可用时的 fallback（tarball）

如果 `$CASE_SHARE` 还没准备好，可以用两个 case 包：

| 包 | 大小 | sha256 |
| --- | --- | --- |
| `isa_case_216.tar.gz` | 313 KB | `a5a6617b974769baddaa932ffe90ba7e6ab4f05998a625f7e088c935a2f4aa97` |
| `mi_si_23.tar.gz` | 15 KB | `724533364322e76e548df49afc0d4c1be28bfcdc0cffd409ff53b28f7f4156d0` |

```bash
export ISA_MODEL_ROOT=$HOME/isa_model
mkdir -p "$ISA_MODEL_ROOT/isa_case"

cd <两个包所在目录>
sha256sum isa_case_216.tar.gz mi_si_23.tar.gz
tar xzf isa_case_216.tar.gz
tar xzf mi_si_23.tar.gz

# 216 条
cp -r isa_case_216/isa_case/* "$ISA_MODEL_ROOT/isa_case/"

# 23 条
cp -r mi_si_23/rv64mi mi_si_23/rv64si "$ISA_MODEL_ROOT/isa_case/"
```

Embench ELF 可以从交付包取（`$UNPACK` 只是源码快照，不是日常运行目录）：

```bash
UNPACK=/work/home03/danielle/hardware-openrio-verif-src-20261022-emb-guard
mkdir -p "$HOME/embench/orbe-baremetal"

cp -r "$UNPACK/testcases/embench/orbe-baremetal/." "$HOME/embench/orbe-baremetal/"
cp "$UNPACK/testcases/embench/SHA256SUMS" "$HOME/embench/"
```

> 不要重复 `cp -r isa_case_216/isa_case "$ISA_MODEL_ROOT/"`，否则可能生成
> `$ISA_MODEL_ROOT/isa_case/isa_case/` 的嵌套目录。

---

## 3. 环境准备

### 3.1 Verilator

脚本默认用 **PATH 里的 `verilator`**，不需要写死路径：

```bash
command -v verilator
verilator --version      # 期望：Verilator 5.050 ...
```

如果 `verilator` 不在 PATH 里，再显式指定（路径以实际安装为准）：

```bash
export VERILATOR=/path/to/verilator-5.050/bin/verilator
"$VERILATOR" --version
```

不知道装在哪时，可以找一下：

```bash
find "$HOME/tools/verilator" -maxdepth 3 -name verilator -type f 2>/dev/null
```

> 不要照抄某个人的 `$HOME/tools/...` 路径；不同机器、不同用户的安装位置可能不同。

> 如果 `verilator --version` 是 **5.014 或更低**，build 会报
> `%Error-PKGNODECL ... isa_dpi_pkg`，后面跟一堆 `unexpected '#' / always / final`。
> 这些是旧解析器的级联错误，必须换 **5.050**；不要逐行去改语法。
> 内网 `.local-deps/or-internal-deps/verilator-5.050-src.tgz` 提供 5.050 源码，
> 可以编到 `$HOME`，不需要 sudo。

### 3.2 ISA model

`ISA_MODEL_ROOT` 指向同时包含 `src/libs/IsaApi.h` 和 `build/lib_ISA_api.so` 的目录：

```bash
export ISA_MODEL_ROOT=/path/to/isa_model

ls "$ISA_MODEL_ROOT/src/libs/IsaApi.h"
ls "$ISA_MODEL_ROOT/build/lib_ISA_api.so"
ls "$ISA_MODEL_ROOT/isa_case/rv64ui/rv64ui-p-add.riscv"
```

不知道路径时，可以找一下：

```bash
find /work -maxdepth 5 -path '*/src/libs/IsaApi.h' 2>/dev/null
```

> 下文命令里的 `$HOME/isa_model` 只是示例；如果你的 ISA model 在别处，改成实际路径。
>
> 如果之前 `export` 过 `ISA_API_INC` / `ISA_API_LIB`，它们优先级高于
> `ISA_MODEL_ROOT`；先 `unset ISA_API_INC ISA_API_LIB`，否则可能仍旧指向 `dpi/`。

`verilator_cosim.sh` 会先找 `$ISA_MODEL_ROOT`，再找仓库内的 `isa_model`；都找不到时
会**回落到 `or_cosim/dpi/` 下预编译的 `lib_ISA_api.so`**。这个回落只适合 cad1 本机
自测；内网部署必须显式指定本机编译的 ISA model，否则可能拿到别的机器编的 `.so`。

#### 确认实际用的是哪个 `.so`

build 日志开头有两行：

```text
[VERILATOR_COSIM] isa_api_inc=.../isa_model/src/libs
[VERILATOR_COSIM] isa_api_lib=.../isa_model/build
```

`isa_api_lib` 应该是 `.../isa_model/build`。如果是
`.../verification/or_cosim/dpi`，说明回落到预编译库了。内网建议统一加：

```bash
export REQUIRE_ISA_MODEL=1   # 拒绝 dpi/ 下的预编译 .so
export CHECK_ISA_GLIBC=1     # 默认 1：.so 的 GLIBC 需求高于上限时提前报错
export ISA_GLIBC_MAX=2.35    # 可选：按内网目标 glibc 卡上限（构建机更新时必加）
```

对应命令行参数是 `--require-isa-model 1` / `--check-isa-glibc 1`。

#### 检查 `.so` 的 glibc 需求

```bash
LIB="$ISA_MODEL_ROOT/build/lib_ISA_api.so"
objdump -T "$LIB" | grep -oE 'GLIBC_[0-9]+(\.[0-9]+)+' | sort -Vu | tail -1
ldd --version | head -1
```

内网（glibc 2.35）上第一条应 **≤ `GLIBC_2.35`**（常见 `GLIBC_2.34` / `GLIBC_2.35`）；
如果是 `GLIBC_2.38` / `GLIBC_2.39`，说明这个 `.so` 不是在内网编的。`verilator_cosim.sh`
在 build 前会打印：

```text
[VERILATOR_COSIM] isa_api_glibc_max=2.35 host_glibc=2.35 limit_glibc=2.35
```

默认上限是**构建机**的 glibc。如果构建机比内网新（例如 cad1 是 2.39），
只比较 host 仍可能产出 2.38 的 `.so`；这时额外加目标上限：

```bash
export ISA_GLIBC_MAX=2.35
```

这样即使 `.so` 是在 2.39 机器上编的，只要最高只要求 `GLIBC_2.35` 就通过；
一旦 `isa_api_glibc_max > limit_glibc` 就直接报错退出，不会等到仿真加载时才失败。
确实要跳过时用 `CHECK_ISA_GLIBC=0`（不推荐）。

#### 在内网重编 ISA model

```bash
cd "$ISA_MODEL_ROOT"
# 如果 build/ 是从别的机器整体拷来的，先删掉，避免 CMakeCache 里的绝对路径失效
rm -rf build
cmake -S . -B build
cmake --build build -j"$(nproc)"
```

`lib_ISA_api.so` 必须在**运行仿真的那台机器**上编；跨机器直接拷 `.so` 会带来
glibc 符号版本不匹配。

### 3.3 其他依赖

| 项 | 要求 |
| --- | --- |
| Verilator | **5.050**（流程使用 `--timing`，版本过低不行） |
| g++ | 支持 C++17 |
| glibc | ISA model 的 `.so` 必须在**内网本机**编译；cad1 上编的 2.38/2.39 版本在内网（2.35）会因缺符号加载失败。`verilator_cosim.sh` 默认按 host 检查，构建机更新时用 `ISA_GLIBC_MAX=2.35` 卡目标上限 |
| `rg`（可选） | `regress.sh` 用它搜索日志关键词；没有 `rg` 时判定会退化为只看退出码 |
| `riscv64-unknown-elf-objdump`（可选） | 只用于生成 `<case>.dump`；没有也不影响判定 |

> `PYTHON3` / `PERL5LIB` 只在**编译 ISA model** 时需要；Verilator 回归本身不需要。

---

## 4. 构建 DUT

> 以下命令假设 `$REPO` / `$CASE_SHARE` 已按 0.2 节设置。

```bash
cd "$REPO/verification/or_cosim"

tools/verilator_cosim.sh build --dut-kind rtl_full --tag reg1
```

> 如果 build 报 `%Error-PKGNODECL ... isa_dpi_pkg`，先回 1.2 节确认脚本顺序，
> 再确认 Verilator 是 5.050。

成功标志：

```text
[VERILATOR_COSIM] build OK: .../sim/verilator_reg1/build/be_tb_top_rtl_full
```

`rtl_full` = BE + FE + Cache，是本文所有回归使用的 DUT kind。

---

## 5. 跑 239 条 ISA 回归（约 5 到 10 分钟）

```bash
cd "$REPO/verification/or_cosim"

# 重要：CASE_ROOT 只给 Embench 用，跑 239 前必须清掉
unset CASE_ROOT
export ISA_MODEL_ROOT=$HOME/isa_model

SIM_TIMEOUT=200000 tools/regress.sh rtl_full reg1 8
```

参数含义：

```text
tools/regress.sh [dut-kind] [tag] [jobs] [case-list]
```

- 第 4 个参数省略时，默认使用 `cfg/cases/cases_239.list`；
- `SIM_TIMEOUT=200000`：239 条最长约 41k cycles，200k 足够，且失败用例不会拖到默认的 2M；
- `8`：并行数，可按机器调整（8/16 均可）。

预期输出：

```text
SUITE: cases_239 entries=239 case_root=... list_sha256=...
SUMMARY: PASS=232 FAIL=7 TOTAL=239 wall=284s
FAIL ...
...
results: .../sim/verilator_reg1/regress/rtl_full/cases_239/results.txt
```

<!-- 截图位 1：239 回归的 summary 输出。图片保存为 verification/images/regress_239_summary.png -->
![239 回归 summary](images/regress_239_summary.png)

### 5.1 已知的 7 条失败

`PASS=232 FAIL=7` 是当前基线，7 条为已知失败（根因定位另行排期）：

| # | 用例 | 日志第一现场 |
| --- | --- | --- |
| 1 | `rv64mi-p-access` | `[COSIM][PC_MISMATCH]` |
| 2 | `rv64mi-p-breakpoint` | `[BE][RECOVERY_EXCEPTION] rob=... has no shared-model trap record` |
| 3 | `rv64mi-p-csr` | `[COSIM][INT_ARF_MISMATCH]` |
| 4 | `rv64mi-p-illegal` | `[FE_EQUIV] exception` 不一致 |
| 5 | `rv64mi-p-ma_fetch` | `[COSIM][INT_ARF_MISMATCH]` |
| 6 | `rv64mi-p-mcsr` | `[COSIM][INT_ARF_MISMATCH]` |
| 7 | `rv64si-p-dirty` | `[CACHE_EQUIV] drain ... whose execute_insn failed in the model` |

> 其中 `rv64si-p-dirty` 依赖 MMU 的 PTE/A-D 路径，MMU 模块就绪前预计会持续失败；
> 其余 6 条属 M/S 特权路径的已知缺陷，根因定位另行排期。

<!-- 截图位 2：7 条 FAIL 的终端明细。图片保存为 verification/images/regress_239_fail_list.png -->
![239 FAIL 明细](images/regress_239_fail_list.png)

> `regress.sh` 在 `SUMMARY` 之后会再用 `grep '^FAIL'` 把失败项列一遍，这只是方便查看，
> **不是把失败用例从回归里剔除了**。`results.txt` 里仍然是完整 239 行。

结果文件：

```text
sim/verilator_reg1/regress/rtl_full/cases_239/cases.list     # 本次实际执行的清单
sim/verilator_reg1/regress/rtl_full/cases_239/results.txt    # 239 行，PASS/FAIL 混排
sim/verilator_reg1/regress/rtl_full/cases_239/summary.txt    # 只有 SUMMARY 一行
```

---

## 6. 跑 Embench 回归

### 6.1 先跑 2 条 smoke（约 2 小时）

建议先跑 `ud` 和 `wikisort` 两条，确认 `is_good` 链路正常：

```bash
cd "$REPO/verification/or_cosim"

export ISA_MODEL_ROOT=$HOME/isa_model
export CASE_ROOT=$HOME/embench/orbe-baremetal    # 必须是绝对路径

printf 'ud\nwikisort\n' > /tmp/emb_smoke.list

SIM_TIMEOUT=20000000 ISA_LOG=none COSIM_OB_LOG=0 \
  tools/regress.sh rtl_full reg1 2 /tmp/emb_smoke.list
```

预期：

```text
SUMMARY: PASS=2 FAIL=0 TOTAL=2 wall=...
```

<!-- 截图位 3：Embench 2 条 smoke 的 summary。图片保存为 verification/images/embench_smoke_summary.png -->
![Embench smoke](images/embench_smoke_summary.png)

### 6.2 跑全部 19 条

```bash
cd "$REPO/verification/or_cosim"

export ISA_MODEL_ROOT=$HOME/isa_model
export CASE_ROOT=$HOME/embench/orbe-baremetal

SIM_TIMEOUT=20000000 ISA_LOG=none COSIM_OB_LOG=0 \
  tools/regress.sh rtl_full reg1 16 cfg/cases/cases_embench.list
```

预期：

```text
SUITE: cases_embench entries=19 case_root=...
SUMMARY: PASS=19 FAIL=0 TOTAL=19 wall=...
```

<!-- 截图位 4：Embench 全量 19 条的 summary。首次全量跑完后补图。
     图片保存为 verification/images/embench_full_summary.png -->
![Embench 全量](images/embench_full_summary.png)

> 如果当前机器能直接访问 `$CASE_SHARE`，可以把 `CASE_ROOT` 直接设为
> `$CASE_SHARE/embench/orbe-baremetal`，不必先复制到 `$HOME/embench`。
>
> **smoke 通过后，每次全量就固定用上面这条命令：19 条、16 并行，不需要再跑 smoke。**
> `16` 是经验值，按 `nproc` 调整，不要超过机器核数。

### 6.3 为什么必须加这些环境变量

| 变量 | 作用 |
| --- | --- |
| `SIM_TIMEOUT=20000000` | Embench 单条 per-iteration 0.8M–4.0M 指令；ELF 还会跑 warm loop（约 2×），默认 2M 会超时（Timeout 不够再加） |
| `ISA_LOG=none` | 不写 `isa_run.log` / `isa_commit.log`，否则单条日志可达数百 MB |
| `COSIM_OB_LOG=0` | 不打印逐 commit 的 `[BE][COSIM_OB]` 行，否则 `sim.log` 可达 GB 级 |
| `CASE_ROOT` | 把清单里的裸文件名（`ud`、`wikisort`…）解析成 ELF 绝对路径 |

### 6.4 Embench 判定标准

不需要额外的 golden 结果比对：

- 每个 benchmark 的 `main()` 会调用 `verify_benchmark()`；
- 返回值经 `exit()` 写入 HTIF `tohost`；
- payload 为 0 时 ISA model 报 `is_good=1`，非 0 时报 `is_good=0`。

`regress.sh` 的 PASS 条件与 ISA 用例完全一致：

```text
rc==0  &&  无 MISMATCH/%Error/Assertion failed/simulation timeout  &&  is_good=1
```

### 6.5 耗时与速度

`sim.log` 末尾的 Verilator 统计长这样：

```text
- Verilator: $finish at 30ms; walltime 6801.156 s; speed 4.415 us/s
```

- `speed` 是 **仿真时间 / 墙钟时间**，不是 Verilator 对指令数的估计；
- TB 的 `CLK_PERIOD = 10ns`（100 MHz），所以 1 us 仿真时间 = 100 个 cycle；
- `4.415 us/s` ≈ **441 cycles/s**；
- 单条 `wikisort` 约 3.0M cycles，3.0M / 441 ≈ 6800 s ≈ 1.9 小时；
- `regress.sh` 的 `jobs` 只决定同时跑几条用例，不会让单条用例变快；
  单条仿真本身是单线程的。

---

## 7. 怎么看单条用例的判定

单条运行的日志目录：

```text
sim/verilator_reg1/log/rtl_full/<elf-name>_1/sim.log
```

检查关键行：

```bash
D=sim/verilator_reg1/log/rtl_full/rv64ui-p-add_1
grep -aE '_EQUIV\] checked=|REPORTER_SUMMARY|is_good=' "$D/sim.log"
```

期望至少出现：

```text
[FE_EQUIV] checked=<N> (fetch_excp=0) mismatch=0 no_ref=0
[CACHE_EQUIV] checked=<M> (excp=0) drain=<K> evict=0 mismatch=0
[REPORTER_SUMMARY] l1=... l2=... l3=... warning=0 error=0 fatal=0
... [FE][EXIT] model requested exit; is_good=1
```

<!-- 截图位 5：单条 sim.log 的判定行。图片保存为 verification/images/single_case_verdict.png -->
![单条判定](images/single_case_verdict.png)

---

## 8. 常见问题

| 现象 | 原因 / 处理 |
| --- | --- |
| `error: isa_case/ not found` | `ISA_MODEL_ROOT` 没指向包含 `isa_case/` 的 ISA model 目录 |
| `%Error-PKGNODECL ... isa_dpi_pkg not found`，后面跟着大量 `unexpected '#' / always / final` | Verilator 版本过旧（例如 5.014）；必须用 **5.050**。这些后续语法错误多半是包解析失败后的级联报错，不要逐行去改。另确认 `dpi/isa_dpi_pkg.sv` 在 `common.f` 之前编译（用 1.2 节的 `grep -n -A6 'sv_inputs='` 检查；旧脚本从 2026-10-22 之后的交付包覆盖 `tools/verilator_cosim.sh`，或按该顺序手工调整） |
| `error: Verilator simulator executable is not readable: ...` | build 和 regress 的 tag 或 dut-kind 不一致；先 `build --dut-kind rtl_full --tag reg1`，再 `regress.sh rtl_full reg1 ...` |
| 239 条全部秒 FAIL、`no is_good=1` | `CASE_ROOT` 还指在 Embench 目录；跑 239 前 `unset CASE_ROOT` |
| 239 条退出码为 1 | 正常，7 条已知失败；看 `summary.txt` 的 `PASS=232 FAIL=7` |
| Embench 全部超时 | `SIM_TIMEOUT` 太小 |
| Embench 跑完磁盘暴涨 | 没加 `ISA_LOG=none COSIM_OB_LOG=0` |
| `lib_ISA_api.so` 报 `GLIBC_2.38` / `GLIBC_2.36` not found | 该 `.so` 是在高版本（>2.35） glibc 上编的；按 3.2 节在内网重新编译 ISA model。脚本已默认提前检查，报错时看 `isa_api_lib` 实际指向 |
| `REQUIRE_ISA_MODEL=1 but ISA_API_LIB resolves to the vendored ...` | 没设 `ISA_MODEL_ROOT`，或它没指向有效 ISA model；按 3.2 节设置后重跑 |
| 没有 `rg` | 判定退化为只看退出码；建议安装 ripgrep |
| 想看完整 PASS 列表 | `cat sim/verilator_reg1/regress/rtl_full/cases_239/results.txt` |

---

## 9. 截图清单（陆续补充）

| 编号 | 内容 | 建议文件名 |
| --- | --- | --- |
| 1 | 239 回归 `SUMMARY` | `images/regress_239_summary.png` |
| 2 | 239 的 7 条 `FAIL` 明细 | `images/regress_239_fail_list.png` |
| 3 | Embench 2 条 smoke `SUMMARY` | `images/embench_smoke_summary.png` |
| 4 | Embench 全量 19 条 `SUMMARY` | `images/embench_full_summary.png` |
| 5 | 单条 `sim.log` 判定行 | `images/single_case_verdict.png` |

图片放在 `verification/images/` 下，文件名与上表一致即可，本文的 Markdown 引用不用改。

---

## 10. 一页速查

```bash
# 路径（按实际 clone / 共享目录修改）
export REPO=/work/home03/danielle/hardware/hardware-openrio
export CASE_SHARE=/work/home03/danielle/regression_cases

# 环境（ISA model 按实际路径；verilator 在 PATH 里就不用设置 VERILATOR）
unset ISA_API_INC ISA_API_LIB   # 防止旧的 export 覆盖 ISA_MODEL_ROOT
export ISA_MODEL_ROOT=/path/to/isa_model
export REQUIRE_ISA_MODEL=1   # 拒绝 dpi/ 下的预编译 .so
export CHECK_ISA_GLIBC=1     # 默认 1；.so 的 GLIBC 需求高于本机时提前报错
export ISA_GLIBC_MAX=2.35    # 内网目标上限（构建机 glibc > 2.35 时必加）
# export VERILATOR=/path/to/verilator-5.050/bin/verilator

# 构建
cd "$REPO/verification/or_cosim"
tools/verilator_cosim.sh build --dut-kind rtl_full --tag reg1

# 239
unset CASE_ROOT
SIM_TIMEOUT=200000 tools/regress.sh rtl_full reg1 8

# Embench smoke
export CASE_ROOT=$HOME/embench/orbe-baremetal
printf 'ud\nwikisort\n' > /tmp/emb_smoke.list
SIM_TIMEOUT=20000000 ISA_LOG=none COSIM_OB_LOG=0 \
  tools/regress.sh rtl_full reg1 2 /tmp/emb_smoke.list

# Embench 全量
SIM_TIMEOUT=20000000 ISA_LOG=none COSIM_OB_LOG=0 \
  tools/regress.sh rtl_full reg1 16 cfg/cases/cases_embench.list
```
