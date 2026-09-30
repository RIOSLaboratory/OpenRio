# ORBE Verification Environment

Verilator + ISA model COSIM: every instruction the RTL commits is compared, one by one, against the result from the ISA model.

## Components

| Part | Location | Purpose |
|---|---|---|
| RTL | `../src/core/{be,fe,cache}_rtl_v1/` | Design under test |
| tb | `orbe_bt_env/tb/` | Testbench: agents, interfaces, COSIM comparison |
| cfg | `orbe_bt_env/cfg/filelist/` | Compile lists and ordering for each DUT kind |
| dpi | `orbe_bt_env/dpi/` | Bridge from SV to the ISA model, the platform config yaml, and the vendored `IsaApi.h` and `lib_ISA_api.so` |
| Script | `orbe_bt_env/tools/verilator_cosim.sh` | Build, run and judge in one step |
| Script | `orbe_bt_env/tools/regress.sh` | Run the 216 cases in batch and summarize the verdicts |

By default the build uses the `IsaApi.h` and `lib_ISA_api.so` vendored in `orbe_bt_env/dpi/`. If you have a full ISA model checkout (with `src/libs/` and `build/`), point to it with `export ISA_MODEL_ROOT=<ISA model directory>` and it takes precedence. The script also searches `verification/`, `verification/isa_model/` and `isa_model/` at the repository root automatically.

The `isa_case/` test cases are not checked in. `regress.sh` reads them from the ISA model directory, so `ISA_MODEL_ROOT` must be set before a batch regression.

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
cd verification/orbe_bt_env
tools/verilator_cosim.sh run --tc $ISA_MODEL_ROOT/isa_case/rv64ui/rv64ui-p-add.riscv   # rtl_full by default

# Batch: build once under a tag, then run the 216 cases with the same tag (6 in parallel)
tools/verilator_cosim.sh build --tag <tag>
tools/regress.sh rtl_full <tag> 6
```

Batch results are in `orbe_bt_env/sim/verilator_<tag>/regress/<kind>/`: `results.txt` holds the per-case verdicts and `summary.txt` the totals.

Use `build` to compile without running; use `--no-build` to rerun an existing build.

`rg` (ripgrep) is required: the script uses it to search the log for failure keywords. Without it that step is skipped and the verdict relies on the exit code alone.

## Results

```text
orbe_bt_env/sim/verilator_<TAG>/log/<kind>/<case-name>_<SEED>/
├── sim.log          Simulation log; check the verdict here
├── isa_run.log      ISA model run log
└── isa_commit.log   Per-instruction commit trace
```

`<TAG>` defaults to today's date; `sim/` is not checked in.

## Acceptance scope

216 cases: `rv64ui` 104, `rv64um` 26, `rv64ua` 38, `rv64uf` 22, `rv64ud` 24, `rv64uc` 2.
