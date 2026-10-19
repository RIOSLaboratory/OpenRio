# ORBE Verification Environment

> **Renamed:** this directory used to be `verification/orbe_bt_env/`. The old name
> came from its BE block-test origin and misrepresents the current scope: this is
> the single COSIM environment for the core, and the DUT level is selected with
> `--dut-kind` (`rtl_full` = BE + FE + Cache, the default; `rtl_v1` = BE only;
> `rtl_fe` / `rtl_cache` = one subsystem replaced by agents). Update any local
> script that still uses the old path.

Verilator + ISA model COSIM: every instruction the RTL commits is compared, one by one, against the result from the ISA model.

## Requirements

| Component | Minimum | Needed by | Notes |
|---|---|---|---|
| Verilator | **5.0** (tested: 5.050) | build | the flow passes `--timing`; the 4.038 shipped by Ubuntu 22.04's apt is too old |
| glibc | **2.38** (e.g. Ubuntu 24.04 LTS) | environment **B** only | the vendored `dpi/lib_ISA_api.so` was built against this ABI |
| C++ compiler | C++20 capable (gcc >= 11) | environment **A** only | builds the ISA model |
| CMake | 3.22 | environment **A** only | builds the ISA model |
| zlib | system default | both | `lib_ISA_api.so` links `-lz` |
| ripgrep (`rg`) | optional | run | without it the log judging degrades to the exit code |
| `riscv64-unknown-elf-objdump` | optional | run | only used to write `<case>.dump` |

Tested: Ubuntu 24.04 LTS + Verilator 5.050 (environment B), and Ubuntu 22.04 + Verilator 5.050 with a locally built ISA model (environment A).

## Components

| Part | Location | Purpose |
|---|---|---|
| RTL | `../src/core/{be,fe,cache}_rtl_v1/` | Design under test |
| tb | `or_cosim/tb/` | Testbench: agents, interfaces, COSIM comparison |
| cfg | `or_cosim/cfg/filelist/` | Compile lists and ordering for each DUT kind |
| dpi | `or_cosim/dpi/` | Bridge from SV to the ISA model, the platform config yaml, and the vendored `IsaApi.h` and `lib_ISA_api.so` |
| Script | `or_cosim/tools/verilator_cosim.sh` | Build, run and judge in one step |
| Script | `or_cosim/tools/regress.sh` | Run the 216 cases in batch and summarize the verdicts |

## Build environments

The ISA model itself is not part of this repository — only its API (`dpi/IsaApi.h`) and a prebuilt library. There are two ways to provide that library; pick one.

| | **A. Full ISA model checkout** | **B. Vendored prebuilt library** (default) |
|---|---|---|
| Setup | `export ISA_MODEL_ROOT=<model dir>` with `src/libs/` and `build/` | nothing |
| Library used | `$ISA_MODEL_ROOT/build/lib_ISA_api.so`, built on your machine | `or_cosim/dpi/lib_ISA_api.so` |
| Extra requirement | CMake >= 3.22 and a C++20 compiler | glibc >= 2.38 |
| `isa_case/` for `regress.sh` | comes with the model checkout | not included |
| Typical use | you have the model source, or your system predates glibc 2.38 | you only want to run the environment |

`ISA_MODEL_ROOT` always takes precedence over the vendored pair. The script also probes `verification/`, `verification/isa_model/` and `isa_model/` at the repository root. `ISA_API_INC` / `ISA_API_LIB` override the result for unusual layouts — they must point at the build that produced the matching `IsaApi.h`.

`isa_case/` is not checked in, and `regress.sh` reads the cases from `$ISA_MODEL_ROOT/isa_case`, so a batch regression needs `ISA_MODEL_ROOT` even in environment B.

## Flow

```text
verilator_cosim.sh run --dut-kind <kind> --tc <case.riscv>
  ├─ Select lists: common.f + <kind>.f + dpi/isa_dpi_pkg.sv + tb.f
  ├─ Verilator build: link dpi/isa_dpi_wrapper.cc with the ISA model library
  ├─ Run: for every instruction the RTL commits, the ISA model computes the expected result and the two are compared
  └─ Verdict: any MISMATCH / %Error / Assertion failed / DPI_EXIT_RESULT FAIL / error≠0 in the log is a failure, with a non-zero exit code
```

## DUT kinds

| Kind | RTL | Defines |
|---|---|---|
| `agent` | None; agents stand in for it (environment self-check) | `ORBE_DUT_AGENT` |
| `rtl_full` (default) | BE + FE + Cache | `ORBE_DUT_RTL_V1` + `ORBE_FE_RTL` + `ORBE_CACHE_RTL` |
| `rtl_v1` | BE (FE and Cache replaced by agents), for subsystem verification | `ORBE_DUT_RTL_V1` |
| `rtl_fe` | BE + FE, for subsystem verification | adds `ORBE_FE_RTL` |
| `rtl_cache` | BE + Cache, for subsystem verification | adds `ORBE_CACHE_RTL` |

## Running (WSL)

```bash
cd verification/or_cosim
tools/verilator_cosim.sh run --tc $ISA_MODEL_ROOT/isa_case/rv64ui/rv64ui-p-add.riscv   # rtl_full by default

# Batch: build once under a tag, then run the 216 cases with the same tag (6 in parallel)
tools/verilator_cosim.sh build --tag <tag>
tools/regress.sh rtl_full <tag> 6
```

Batch results are in `or_cosim/sim/verilator_<tag>/regress/<kind>/`: `results.txt` holds the per-case verdicts and `summary.txt` the totals.

Use `build` to compile without running; use `--no-build` to rerun an existing build.

`rg` (ripgrep) is optional but recommended: the script uses it to search the log for failure keywords. Without it that step is skipped and the verdict relies on the exit code alone.

## Results

```text
or_cosim/sim/verilator_<TAG>/log/<kind>/<case-name>_<SEED>/
├── sim.log          Simulation log; check the verdict here
├── isa_run.log      ISA model run log
└── isa_commit.log   Per-instruction commit trace
```

`<TAG>` defaults to today's date; `sim/` is not checked in.

## Values the ISA model cannot predict

Two sources differ between the RTL and the ISA model by nature, not by bug; the testbench makes the DUT follow the reference for them. Both are on by default and only change the `rtl_*` kinds.

| Source | Handling | Log tag | Disable |
|---|---|---|---|
| `mcycle` / `cycle` reads | The CSR read result is replaced by the value the COSIM reference reads for that instruction; `minstret` / `instret` are still compared | `[COSIM][CNT_SYNC]` | `+COSIM_CNT_SYNC=0` |
| HTIF system calls (e.g. `printf` through `tohost` / `fromhost`) | The testbench acts as the host on the DUT side: loads of host-written words (`fromhost`, the syscall's return slot) wait until they are the oldest instruction and return the reference value | `[HTIF_SYNC]` | `+COSIM_HTIF_SYNC=0` |

Benchmarks that time themselves or print results (for example Embench) need both; the 216 ISA cases touch neither.

## Acceptance scope

216 cases: `rv64ui` 104, `rv64um` 26, `rv64ua` 38, `rv64uf` 22, `rv64ud` 24, `rv64uc` 2.
