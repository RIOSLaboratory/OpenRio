# tools/ 使用说明

> 面向两类人：**要出包的人**（手上有仓库）和**收到包的人**（只拿到一个 `tar.gz`）。
> 打包工具 = `pack_verif_src.sh`，只打**源码**，不含构建产物、波形、日志、二进制。

---

## 一、我要打一个包

```bash
cd <repo>/verification/or_cosim
tools/pack_verif_src.sh --out ~ --tag $(date +%Y%m%d)
```

要连 Embench ELF 一起传内网时加 `--with-embench`：

```bash
tools/pack_verif_src.sh --out ~ --tag $(date +%Y%m%d) \
  --with-embench <repo>/embench_elf/bin/embench/orbe-baremetal
```

包里会多出 `testcases/embench/orbe-baremetal/`（19 个 ELF，约 344 KB）、
`testcases/embench/SHA256SUMS` 和一份 `README_EMBENCH.md`。

产出两个文件：

```text
~/hardware-openrio-verif-src-20261020.tar.gz         约 2.4 MB
~/hardware-openrio-verif-src-20261020.tar.gz.sha256
```

### 参数

| 参数 | 说明 | 默认 |
| --- | --- | --- |
| `--out DIR` | 输出目录 | 当前目录 |
| `--tag NAME` | 文件名后缀 | `<YYYYmmdd-HHMM>` |
| `--with-perf-eval` | 一并打包 `or_cosim/perf_eval/` | 不含 |
| `--with-embench DIR` | 一并打包 `DIR` 下的 Embench `orbe-baremetal` ELF | 不含 |
| `--no-docs` | 不打 `or_cosim/docs/` | 含 |
| `--no-sha` | 不生成 `.sha256` | 生成 |
| `-h`, `--help` | 打印帮助 | |

### 打进去的是什么

| 内容 | 说明 |
| --- | --- |
| `verification/or_cosim/` | `tb/ cfg/ dpi/ tools/ docs/ .gitignore` |
| `src/core/be_rtl_v1/` | 后端 RTL |
| `src/core/fe_rtl_v1/` | 前端 RTL |
| `src/core/cache_rtl_v1/` | Cache RTL |
| `testcases/embench/` | 仅 `--with-embench` 时：19 个 ELF + `SHA256SUMS` + 说明 |
| `MANIFEST.txt` | 逐文件大小清单（自动生成） |
| `README_PACKAGE.md` | 给收包人的解包 + 构建说明（自动生成） |

**目录层级与仓库完全一致**，所以 `cfg/filelist/*.f` 里的 `../../src/core/...`
解包后依然成立，不需要改任何路径。

### 不打进去的是什么（有意为之）

- `or_cosim/sim/` —— 全部构建产物、`sim.log`、回归结果
- `verdiLog/`、`vcd2fsdbLog/`、`novas.rc`、`novas.conf`
- `*.vcd` / `*.fst` / `*.fsdb` / `*.log`
- `__pycache__/`、`*.pyc`
- `perf_eval/`（默认排除，需要时加 `--with-perf-eval`）
- ISA 模型、测试用例（`isa_case`）、预编译 `lib_ISA_api.so`
- Embench ELF（默认排除，需要时加 `--with-embench DIR`）

> 结论：**这个包不能离线直接跑**。要真正跑起来还需要 ISA 模型与用例集，
> 见 `../docs/Arch/README.md`。

### 出包后自查

```bash
T=~/hardware-openrio-verif-src-20261020.tar.gz
sha256sum -c "$T.sha256"
tar tzf "$T" | grep -vc '/$'                              # 文件数，正常 132
tar tzf "$T" | grep -cE 'or_cosim/sim/|\.vcd$|perf_eval/'  # 应为 0
```

---

## 一之二、回归清单与用法

两份清单都在 `or_cosim/cfg/cases/`，首行 `# expected=N` 由 `regress.sh` 校验：

| 清单 | 条目 | 用途 |
| --- | --- | --- |
| `cases_239.list` | 239 | I/M/A/F/D/C user mode 216 + M mode 16 + S mode 7 |
| `cases_embench.list` | 19 | Embench `orbe-baremetal` |

`regress.sh` 的第 4 个参数是清单文件，省略时用 `cases_239.list`。相对条目默认
相对 `$ISA_MODEL_ROOT/isa_case`；跑 Embench 时用 `CASE_ROOT` 指到 ELF 目录：

```bash
# 239 条 ISA（最长用例约 41k cycles，200k 足够；失败用例不会拖到默认 2M）
SIM_TIMEOUT=200000 tools/regress.sh rtl_full <tag> 8

# 19 条 Embench（内网，ELF 从 --with-embench 包里解出）
export CASE_ROOT=<unpacked>/testcases/embench/orbe-baremetal
SIM_TIMEOUT=20000000 ISA_LOG=none COSIM_OB_LOG=0 tools/regress.sh rtl_full <tag> 8 \
  cfg/cases/cases_embench.list
```

> 包里的 `orbe-baremetal` ELF 会跑一轮 warm loop：ELF 自己报的 `minstret` 约
> 1.4M，实际退休指令约 2.9M（约 2×）。单条按 1.5M–8M 指令估，全量 19 条在
> 16 并行下约 3–4 小时。

| 环境变量 | 作用 | 默认 |
| --- | --- | --- |
| `CASE_ROOT` | 相对清单条目的根目录 | `$ISA_MODEL_ROOT/isa_case` |
| `SIM_TIMEOUT` | 单条 cycle 上限 | `2000000`（ISA 够用，Embench 必须调大） |
| `ISA_LOG` | `all` / `commit` / `none` | `all`（Embench 建议 `none`） |
| `COSIM_OB_LOG` | 逐 commit 的 `[BE][COSIM_OB]` 行 | `1`（Embench 建议 `0`） |

结果目录：`sim/verilator_<tag>/regress/<dut>/<清单名>/`，含 `cases.list`、
`results.txt`、`summary.txt`；清单 sha256 打印在开头。

**Embench 判定**：`verify_benchmark()` 的结果经 `main()` 返回值写进 HTIF
`tohost`，payload 非 0 时 ISA 模型报 `is_good=0`。所以 PASS 条件与 ISA 用例
完全一致：`rc==0` + 无 `MISMATCH` + `is_good=1`，不需要额外的 golden 比对。

---

## 二、我收到了一个包

```bash
tar xzf hardware-openrio-verif-src-YYYYMMDD.tar.gz
cd hardware-openrio-verif-src-YYYYMMDD
cat README_PACKAGE.md      # 解包 + 构建步骤
head -20 MANIFEST.txt      # 文件清单
```

最小构建流程：

```bash
cd verification/or_cosim
export ISA_MODEL_ROOT=<ISA 模型目录，含 src/libs 与 build>
tools/verilator_cosim.sh build --dut-kind rtl_full --tag first
```

依赖：Verilator **5.050**（5.014 及更旧版本会在 `isa_dpi_pkg` 上报 `PKGNODECL`）、CMake ≥ 3.22、g++ ≥ 11（C++20）。
若使用自带的 `dpi/lib_ISA_api.so` 预编译库，还需要 glibc ≥ 2.38；内网（glibc 2.35）必须在本机编 ISA model，并建议：

```bash
export REQUIRE_ISA_MODEL=1   # 拒绝 dpi/ 下的预编译 .so
export CHECK_ISA_GLIBC=1     # 默认 1：.so 的 GLIBC 需求高于上限时提前报错
export ISA_GLIBC_MAX=2.35    # 构建机比内网新时，按目标 glibc 卡上限
```

build 日志里的 `isa_api_lib=` / `isa_api_glibc_max=` 可以确认实际使用的库和 ABI 上限。

---

## 三、常见问题

| 现象 | 原因 / 处理 |
| --- | --- |
| `error: RTL directory not found: .../src/core/be_rtl_v1` | 不在仓库内运行，或分支过旧。脚本要求 `src/core/*_rtl_v1` 三个目录都存在 |
| `error: cannot create output dir` | `--out` 指向的路径不存在且无法创建 |
| 打出来比预期大很多 | 检查是否加了 `--with-perf-eval`，或 `docs/` 里混进了大文件 |
| 收包方 build 报 filelist 找不到 | 解包时不要加 `--strip-components`，层级必须保留 |
| Embench 全部超时 | 默认 `SIM_TIMEOUT=2000000` 不够；单条 per-iteration 0.8M–4.0M，ELF 还会跑 warm loop（约 2×），设 `SIM_TIMEOUT=20000000` |
| Embench 跑完磁盘暴涨 | `sim.log` 里的 `[BE][COSIM_OB]` 与 ISA 的 `isa_run/commit.log` 都会随指令数线性增长；用 `COSIM_OB_LOG=0` + `ISA_LOG=none` |
| Embench 判定与 ISA 不同？ | 不需要另立标准，`is_good=1` 已含 `verify_benchmark()` 结果 |
| `lib_ISA_api.so` 报 `GLIBC_2.38 not found` | 用了高版本 glibc 编的 `.so`；在本机重编 ISA model，并设 `REQUIRE_ISA_MODEL=1 CHECK_ISA_GLIBC=1 ISA_GLIBC_MAX=2.35` |
| 想连 ISA 模型和用例一起给 | 脚本不负责，单独传 `isa_model-src-*.tgz` 与用例包，并附 `SHA256SUMS` |
| 只想把脚本本身给别人 | 纯文本，单独打一个几 KB 的包即可，不必带整个仓库 |
