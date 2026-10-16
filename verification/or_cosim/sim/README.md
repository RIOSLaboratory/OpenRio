# sim/

All simulation output lands in this directory: the build products of `tools/verilator_cosim.sh`, the per-case logs, and the batch regression results of `tools/regress.sh`. The directory is covered by `.gitignore`; apart from this README nothing here is checked in, and it can be deleted and regenerated at any time.

## Layout

```text
sim/verilator_<TAG>/
├── build/
│   ├── obj_<kind>/               Verilator intermediate build files
│   └── be_tb_top_<kind>          Simulator executable
├── log/<kind>/<case-name>_<SEED>/
│   ├── sim.log                   Simulation log; check the verdict here
│   ├── isa_run.log               ISA model run log
│   └── isa_commit.log            Per-instruction commit trace
└── regress/<kind>/
    ├── cases.list                Case list for this regression
    ├── results.txt               Per-case verdicts (PASS / FAIL)
    └── summary.txt               Totals (PASS / FAIL / TOTAL / wall time)
```

- `<TAG>`: set with `--tag`, defaults to today's date (YYYYMMDD). `build`, `run` and `regress.sh` under the same tag share one build.
- `<kind>`: `rtl_full` (default), `rtl_v1`, `rtl_fe`, `rtl_cache`, `agent`.
- `<SEED>`: set with `--seed`, defaults to 1.
