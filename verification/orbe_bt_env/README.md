# ORBE Backend Verification Environment

This directory contains the ORBE backend verification environment used for
mock-DUT self-checks and rtl_v1 COSIM debug.

## Layout

- `tb/` contains the SystemVerilog testbench, interfaces, agents, packages, and
  DUT wrappers.
- `dpi/` contains the project-owned ISA Model DPI package, C++ wrapper, API
  notes, and platform YAML.
- `cfg/filelist/` contains source lists for mock and rtl_v1 builds.
- `mk/` and `sim/` contain the VCS build and run flow.
- `tools/verilator_cosim.sh` builds and runs the same testbench with Verilator.
- `tools/check_isa_api_release.py` verifies the ISA model binary release pair
  against `dpi/isa_dpi_wrapper.cc`.
- `docs/` contains architecture and bring-up notes.
- `mock_tb/` contains the older standalone FE mock flow.

Generated simulation output should stay out of git:

```text
sim/verilator_*
sim/*/build
sim/*/log
sim/*/regress
*.log
*.fsdb
simv
obj_dir
```

## External Dependencies

This open-source package does not vendor the ISA model, the ISA case ELFs, or
the rtl_v1 source tree. Point the environment at a local ISA model before
building.

### ISA model: binary release pair or full checkout

`IsaApi.h` and `lib_ISA_api.so` carry the private ISA model interface. Two
layouts are supported, and the build files pick between them automatically:

| Layout | Header | Library |
| --- | --- | --- |
| Binary release pair | `<install>/include/IsaApi.h` | `<install>/lib/lib_ISA_api.so` |
| Full source checkout | `<checkout>/src/libs/IsaApi.h` | `<checkout>/build/lib_ISA_api.so` |

Set `ISA_MODEL_INSTALL` to the directory that holds them. A release pair under
`include/` and `lib/` wins over the checkout layout:

```bash
# Released header plus shared library, the normal way to consume the model
export ISA_MODEL_INSTALL=<path-to-isa-model-release>

# Or a full checkout, for internal development
export ISA_MODEL_ROOT=<path-to-isa_model-checkout>

export ISA_CFG=$PWD/dpi/rivai_0x80000000_1core_rom.yaml
```

`ISA_API_INC` and `ISA_API_LIB` override the resolved directories directly:

```bash
export ISA_API_INC=$ISA_MODEL_INSTALL/include
export ISA_API_LIB=$ISA_MODEL_INSTALL/lib
```

When none of these is set, `ISA_MODEL_INSTALL` defaults to the parent directory
of `orbe_bt_env`. The ISA regression ELF set is read from
`$ISA_CASE_DIR/`; see [ISA Regression Scope](#isa-regression-scope).

### Verify the release pair before building

`IsaApi.h` is hand maintained next to the model sources, so it drifts from the
library that is actually shipped. A drifted pair either fails to compile or
fails to link only when the simulator starts, so this package checks the pair
against the DPI wrapper, which is open source:

```bash
cd verification/orbe_bt_env
python3 tools/check_isa_api_release.py --install "$ISA_MODEL_INSTALL"
python3 tools/check_isa_api_release.py --install "$ISA_MODEL_INSTALL" --smoke
```

The tool reads `dpi/isa_dpi_wrapper.cc`, derives the `IsaApi.h` declarations
and `lib_ISA_api.so` symbols the wrapper really uses, and reports every missing
item. `--smoke` additionally builds the DPI shared object against the pair,
loads it, and drives the model through its lifecycle. The VCS flow exposes the
same check as `make check_isa_abi`, and the VCS, Verilator, and `mock_tb` builds
all run it before compiling.

### Rebuilding the model from a checkout

```bash
cmake -S "$ISA_MODEL_ROOT" -B "$ISA_MODEL_ROOT/build" -G Ninja
cmake --build "$ISA_MODEL_ROOT/build"                    # builds _ISA_api and _ISA_api_ext
cmake --install "$ISA_MODEL_ROOT/build"                  # refreshes include/ and lib/
```

`cmake --build --target _ISA_api` builds only the main library, while
`cmake --install` also installs `lib_ISA_api_ext.so`. Build the default target,
or add `_ISA_api_ext`, before installing so the release pair stays complete.

### RTL tree

`cfg/filelist/rtl_v1.f` names the backend RTL sources, relative to
`orbe_bt_env`, so it is the single place that records where the RTL tree lives.
Both flows read it: Verilator compiles it directly, and `mk/common.mk` derives
the VCS dependency list from the same entries. Nothing else repeats the path, so
a checkout only edits the filelist to point at its own tree.

If your RTL lives outside the repository, either edit `cfg/filelist/rtl_v1.f` or
place a symlink where it already points. Extra source trees that the filelist
does not cover can be added through `RTL_SOURCE_ROOTS`.

### ISA test cases

The ISA regression cases come from
[riscv-tests](https://github.com/riscv-software-src/riscv-tests), vendored as a
submodule together with its nested `env` submodule (`riscv/riscv-test-env`).
Clone with submodules:

```bash
git clone --recurse-submodules <this-repo>
# or, in an existing clone
git submodule update --init --recursive
```

riscv-tests ships assembly sources only, so the `.riscv` ELF images the
environment consumes have to be cross compiled. Build them with:

```bash
cd verification/orbe_bt_env
export ISA_CASE_DIR=$(cd ../.. && pwd)/isa_case

tools/build_isa_cases.sh --out "$ISA_CASE_DIR"
```

This needs a bare metal RISC-V toolchain providing `riscv64-unknown-elf-gcc`
together with `objdump` and `objcopy`. Override it with `RISCV_GCC` or
`RISCV_PREFIX`. The script builds the 216 case regression set and checks each
category against its expected count.

The submodule is pinned to the revision whose test composition matches the
historical regression set (rv64ui 104, rv64um 26, rv64ua 38, rv64uf 22,
rv64ud 24, rv64uc 2). The `-p-` machine mode cases are pure assembly and
reproduce that baseline byte for byte. The `-v-` supervisor mode cases compile
the `env/v` runtime from C, so their code depends on the compiler version; use
a GCC close to the one the baseline was produced with when byte level
comparison matters.

The submodule also carries `rv64mi`, `rv64si`, `rv64uzba`, `rv64uzbb`,
`rv64uzbc`, `rv64uzbs`, `rv64uzfh`, `rv64mzicbo` and `rv64ssvnapot`; pass
`--categories` to build them. The `rv64model` cases are project private and are
not produced by this script.

## Entry Points

Use VCS through the Makefile:

```bash
cd verification/orbe_bt_env/sim

make build DUT_KIND=rtl_v1 COSIM_ENABLE=1

make run \
  DUT_KIND=rtl_v1 \
  TC=$ISA_CASE_DIR/rv64ui/rv64ui-p-add.riscv \
  COSIM_ENABLE=1 \
  PLUSARGS='+VERBOSITY=2'
```

Use Verilator through the COSIM helper:

```bash
cd verification

orbe_bt_env/tools/verilator_cosim.sh build \
  --dut-kind rtl_v1 \
  --tag local

orbe_bt_env/tools/verilator_cosim.sh run \
  --no-build \
  --dut-kind rtl_v1 \
  --tag local \
  --tc "$ISA_CASE_DIR/rv64ui/rv64ui-p-add.riscv" \
  --timeout 200000 \
  --verbosity 2
```

The legacy top-level `run_verilator.sh` is kept only for old mock-flow users.
New COSIM work should use `tools/verilator_cosim.sh`.

### COSIM logging level

Select the COSIM checking and logging level with the `+COSIM_LEVEL` plusarg:

```text
+COSIM_LEVEL=1
  Enable Level 1 COSIM checking and logging only.

+COSIM_LEVEL=2
  Enable Level 1 and Level 2 observation, comparison, and logging.

No +COSIM_LEVEL argument
  Use the testbench default, which is Level 1.
```

For reproducible runs, specify the level explicitly. With Verilator, pass the
plusarg through `--plusargs`:

```bash
# Level 1
orbe_bt_env/tools/verilator_cosim.sh run \
  --dut-kind rtl_v1 \
  --tc "$ISA_CASE_DIR/rv64ui/rv64ui-p-add.riscv" \
  --verbosity 2 \
  --plusargs '+COSIM_LEVEL=1'

# Level 2
orbe_bt_env/tools/verilator_cosim.sh run \
  --dut-kind rtl_v1 \
  --tc "$ISA_CASE_DIR/rv64ui/rv64ui-p-add.riscv" \
  --verbosity 2 \
  --plusargs '+COSIM_LEVEL=2'
```

With the VCS Makefile flow, include the same plusarg in `PLUSARGS`:

```bash
make -C verification/orbe_bt_env/sim run \
  DUT_KIND=rtl_v1 \
  TC=$ISA_CASE_DIR/rv64ui/rv64ui-p-add.riscv \
  COSIM_ENABLE=1 \
  PLUSARGS='+COSIM_LEVEL=2 +VERBOSITY=2'
```

## ISA Regression Scope

The current ORBE BE/COSIM regression target is the historical 216 ELF set from
these six `isa_case` directories:

```text
rv64ui: 104  rv64um: 26  rv64ua: 38
rv64uf:  22  rv64ud: 24  rv64uc:  2
```

This is intentionally not every `.riscv` file under `isa_case/`. Privileged,
vector, bitmanip, cache-block, and model-specific ELFs are outside this
acceptance set unless they are explicitly added later.

Check the canonical count:

```bash
find "$ISA_CASE_DIR/rv64ui" \
     "$ISA_CASE_DIR/rv64um" \
     "$ISA_CASE_DIR/rv64ua" \
     "$ISA_CASE_DIR/rv64uf" \
     "$ISA_CASE_DIR/rv64ud" \
     "$ISA_CASE_DIR/rv64uc" \
  -maxdepth 1 -type f -name '*.riscv' -print | sort | wc -l
```

The expected result is `216`.

## Runtime Logs

Verilator logs are written under:

```text
orbe_bt_env/sim/verilator_<TAG>/log/<DUT_KIND>/<elf-name>_<SEED>/
```

VCS logs are written under:

```text
orbe_bt_env/sim/<SYS>_<TAG>/log/<elf-name>_<SEED>/
```

Important files:

```text
sim.log          # testbench transcript and COSIM mismatch/fatal lines
isa_run.log      # shared BE-side ISA model run log
isa_commit.log   # shared BE-side ISA model commit log
```

Useful grep:

```bash
rg -i "\\[COSIM\\]|\\[BE\\]\\[COSIM\\]|MISMATCH|FATAL|%Error|Assertion failed|REPORTER_SUMMARY" \
  orbe_bt_env/sim/verilator_<TAG>/log/rtl_v1/<case>_<SEED>/sim.log
```

Find the newest log for one failed rtl_v1 case:

```bash
case_name=rv64ua-v-amoadd_d
log=$(find orbe_bt_env/sim -path "*/log/rtl_v1/${case_name}_*/sim.log" -print | sort | tail -1)
printf '%s\n' "$log"

rg -n -m 1 "\\[COSIM\\]|MISMATCH|%Error|Assertion failed|Fatal" "$log"
```

After the first failure line is found, inspect local context and correlate it
with the reference commit log:

```bash
line=$(rg -n -m 1 "\\[COSIM\\]|MISMATCH|%Error|Assertion failed|Fatal" "$log" | cut -d: -f1)
start=$((line > 20 ? line - 20 : 1))
end=$((line + 20))
sed -n "${start},${end}p" "$log"

commit_log=$(dirname "$log")/isa_commit.log
rg -n "<pc>|<inst>|<rd>" "$commit_log"
```

## Runtime Print Verbosity

The testbench reporter supports three print levels through the `VERBOSITY`
plusarg. Warnings, errors, fatals, and assertion failures are always printed;
`VERBOSITY` only controls normal diagnostic prints tagged as `[L1]`, `[L2]`, or
`[L3]`.

With the Verilator COSIM script, use `--verbosity <1|2|3>`:

```bash
orbe_bt_env/tools/verilator_cosim.sh run \
  --no-build \
  --dut-kind rtl_v1 \
  --tc "$ISA_CASE_DIR/rv64ua/rv64ua-v-amoadd_d.riscv" \
  --timeout 2500000 \
  --verbosity 2
```

With the VCS Makefile flow, pass the raw plusarg through `PLUSARGS`:

```bash
make -C verification/orbe_bt_env/sim run \
  DUT_KIND=rtl_v1 \
  TC=$ISA_CASE_DIR/rv64ua/rv64ua-v-amoadd_d.riscv \
  COSIM_ENABLE=1 \
  PLUSARGS='+VERBOSITY=2'
```

Level meaning:

```text
VERBOSITY=1
  Base progress only. Use it for quiet pass/fail regression logs.

VERBOSITY=2
  Normal debug: level 1 plus reference init/exit, BE decode/issue/commit,
  recovery, getter responses, cache done/flush, and COSIM progress prints.
  This is the recommended first setting for a failed rtl_v1 case.

VERBOSITY=3
  Verbose trace: level 1 and 2 plus detailed FE redirect/fetch notices,
  stale-event filtering, cache queue/wakeup/memory traffic, and COSIM
  architectural-state detail. Use it on one narrowed case because logs grow
  quickly.
```

## Failure Classification

COSIM uses the ISA model as the reference side and rtl_v1, or another DUT, as
the implementation side. Do not classify a mismatch as an RTL bug only from the
final mismatch line. Classify by the first divergence:

```text
rtl_v1 internal signal is correct, but rtl_v1_obs_probe/wrapper output is wrong
  => observation/probe/wrapper issue

observation output is correct, but be_agent/COSIM consumes a different event
  => ob_if/ob_cosim_if/be_agent sampling or ordering issue

COSIM event is correct, reference input/config is correct, and architectural
state still diverges at the first failing commit
  => rtl_v1 behavior issue
```

The mock DUT is used as the environment self-check. If `mock_rtl` runs the same
216-case COSIM regression through the mock observation path and all cases pass,
the common COSIM path is considered clean enough for rtl_v1 triage. A remaining
rtl_v1-only failure should then be debugged on the rtl_v1-private side first:
RTL behavior, `rtl_v1_obs_probe`, or `rtl_v1_wrapper`.

## Verilator rtl_v1 216-Case Regression

Build once, then run the canonical 216-case set with COSIM enabled:

```bash
cd verification

export REG_TAG=rtl_v1_216_$(date +%Y%m%d_%H%M%S)
export REG_ROOT=$PWD/orbe_bt_env/sim/verilator_$REG_TAG/regress/rtl_v1_216
mkdir -p "$REG_ROOT"

find "$ISA_CASE_DIR/rv64ui" \
     "$ISA_CASE_DIR/rv64um" \
     "$ISA_CASE_DIR/rv64ua" \
     "$ISA_CASE_DIR/rv64uf" \
     "$ISA_CASE_DIR/rv64ud" \
     "$ISA_CASE_DIR/rv64uc" \
  -maxdepth 1 -type f -name '*.riscv' -print | sort > "$REG_ROOT/all_216.list"

orbe_bt_env/tools/verilator_cosim.sh build \
  --dut-kind rtl_v1 \
  --tag "$REG_TAG"

while IFS= read -r elf; do
  rel="${elf#$ISA_MODEL_ROOT/}"
  if orbe_bt_env/tools/verilator_cosim.sh run \
      --no-build \
      --dut-kind rtl_v1 \
      --tag "$REG_TAG" \
      --tc "$elf" \
      --timeout 2000000 \
      --verbosity 2; then
    printf 'PASS %s\n' "$rel"
  else
    rc=$?
    printf 'FAIL rc=%d %s\n' "$rc" "$rel"
  fi
done < "$REG_ROOT/all_216.list" | tee "$REG_ROOT/results.txt"

awk '
  $1 == "PASS" { pass++ }
  $1 == "FAIL" { fail++ }
  END { printf "SUMMARY: PASS=%d FAIL=%d TOTAL=%d\n", pass + 0, fail + 0, NR }
' "$REG_ROOT/results.txt" | tee "$REG_ROOT/final_summary.txt"
```

If `rv64ui-p-add.riscv` has already passed as a smoke case and only the
remaining 215 cases should be run, create a reduced list before the loop:

```bash
grep -vxF "$ISA_CASE_DIR/rv64ui/rv64ui-p-add.riscv" \
  "$REG_ROOT/all_216.list" > "$REG_ROOT/remaining_215.list"

# Then replace the loop input with:
# done < "$REG_ROOT/remaining_215.list" | tee "$REG_ROOT/results.txt"
```

## Verilator Mock COSIM Self-Check

Use the mock flow to validate the common COSIM environment before classifying
rtl_v1 failures. The mock path drives the same `ob_if/ob_cosim_if`, BE agent,
DPI adapter, and reference model path as rtl_v1, but takes its observation
bundle from `mock_obs_probe`.

Build and run one smoke case:

```bash
cd verification

export MOCK_TAG=mock_cosim_$(date +%Y%m%d_%H%M%S)

orbe_bt_env/tools/verilator_cosim.sh build \
  --dut-kind mock \
  --tag "$MOCK_TAG"

orbe_bt_env/tools/verilator_cosim.sh run \
  --no-build \
  --dut-kind mock \
  --tag "$MOCK_TAG" \
  --tc "$ISA_CASE_DIR/rv64ui/rv64ui-p-add.riscv" \
  --timeout 200000 \
  --verbosity 2
```

Run the 216-case mock COSIM self-check by using the same loop above with
`--dut-kind mock` and a separate tag:

```bash
export MOCK_TAG=mock_cosim_216_$(date +%Y%m%d_%H%M%S)
```

Expected result for a clean common environment:

```text
SUMMARY: PASS=216 FAIL=0 TOTAL=216
```
