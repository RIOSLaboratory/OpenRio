#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  orbe_bt_env/tools/verilator_cosim.sh lint [options]
  orbe_bt_env/tools/verilator_cosim.sh build [options]
  orbe_bt_env/tools/verilator_cosim.sh run --tc /path/to/test.elf [options]
  orbe_bt_env/tools/verilator_cosim.sh run /path/to/test.elf [options]

Options:
  --dut-kind <agent|rtl_v1|rtl_fe|rtl_cache|rtl_full>  DUT implementation to compile. Default: rtl_full
  --tc <path>                   ELF to run. Also accepted as first positional run arg.
  --tag <name>                  Output namespace tag. Default: current YYYYMMDD
  --seed <n>                    ntb_random_seed and case suffix. Default: 1
  --timeout <cycles>            +SIM_TIMEOUT_CYCLES. Default: 2000000
  --verbosity <1|2|3>           Testbench print level. Default: 3
  --cosim-enable <0|1>          +COSIM_ENABLE. Default: 1
  --cosim-backend <name>        +COSIM_BACKEND. Default: isa_step
  --plusargs '<args>'           Extra simulator plusargs, split on shell whitespace.
  --no-build                    For run, use the existing executable.
  -h, --help                    Show this help.

Environment overrides:
  VERILATOR, JOBS, ISA_MODEL_ROOT, ISA_API_INC, ISA_API_LIB, ISA_CFG,
  VERILATOR_BUILD_ROOT, VERILATOR_LOG_ROOT, OBJ_DIR, SIM_EXE, OBJDUMP.

ISA model lookup:
  A full ISA model checkout (src/libs and build) under ISA_MODEL_ROOT, or found
  by searching upward, takes precedence.  Otherwise the IsaApi.h and
  lib_ISA_api.so pair vendored in dpi/ is used.  ISA_API_INC and ISA_API_LIB
  override the result.

Default logs:
  orbe_bt_env/sim/verilator_<TAG>/log/<DUT_KIND>/<elf-name>_<SEED>/sim.log
  orbe_bt_env/sim/verilator_<TAG>/log/<DUT_KIND>/<elf-name>_<SEED>/isa_run.log
  orbe_bt_env/sim/verilator_<TAG>/log/<DUT_KIND>/<elf-name>_<SEED>/isa_commit.log
USAGE
}

die() {
  echo "error: $*" >&2
  exit 1
}

abs_path() {
  local path="$1"
  local dir
  local base

  [[ "$path" == /* ]] || path="$PWD/$path"
  dir=$(dirname "$path")
  base=$(basename "$path")
  if [[ -d "$dir" ]]; then
    (cd "$dir" && printf '%s/%s\n' "$PWD" "$base")
  else
    printf '%s/%s\n' "$dir" "$base"
  fi
}

need_file() {
  local path="$1"
  local name="$2"

  [[ -r "$path" ]] || die "$name is not readable: $path"
}

command=${1:-run}
case "$command" in
  lint|build|run|clean|help|-h|--help)
    shift || true
    ;;
  *)
    command=run
    ;;
esac

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
orbe_bt_env=$(cd "$script_dir/.." && pwd)
# A full ISA model checkout (src/libs + build) is set via ISA_MODEL_ROOT, or probed upward level by level;
# if none is found, the IsaApi.h and lib_ISA_api.so shipped with the repo under dpi/ are used.
default_isa_model_root=$(cd "$orbe_bt_env/.." && pwd)
for _cand in "$orbe_bt_env/.." "$orbe_bt_env/../isa_model" "$orbe_bt_env/../../isa_model"; do
  if [ -r "$_cand/src/libs/IsaApi.h" ]; then
    default_isa_model_root=$(cd "$_cand" && pwd)
    break
  fi
done
unset _cand

DUT_KIND=${DUT_KIND:-rtl_full}
TC=${TC:-}
TAG=${TAG:-$(date +%Y%m%d)}
SEED=${SEED:-1}
SIM_TIMEOUT=${SIM_TIMEOUT:-2000000}
VERBOSITY=${VERBOSITY:-3}
COSIM_ENABLE=${COSIM_ENABLE:-1}
COSIM_BACKEND=${COSIM_BACKEND:-isa_step}
PLUSARGS=${PLUSARGS:-}
NO_BUILD=${NO_BUILD:-0}
JOBS=${JOBS:-$(nproc 2>/dev/null || echo 4)}
VERILATOR=${VERILATOR:-verilator}
OBJDUMP=${OBJDUMP:-riscv64-unknown-elf-objdump}

# Relative paths are resolved against the caller's current directory and made absolute: at build time make runs inside the obj directory, so relative -I/-L/rpath would break.
ISA_MODEL_ROOT=$(abs_path "${ISA_MODEL_ROOT:-$default_isa_model_root}")
if [[ -r "$ISA_MODEL_ROOT/src/libs/IsaApi.h" ]]; then
  default_isa_api_inc=$ISA_MODEL_ROOT/src/libs
  default_isa_api_lib=$ISA_MODEL_ROOT/build
else
  default_isa_api_inc=$orbe_bt_env/dpi
  default_isa_api_lib=$orbe_bt_env/dpi
fi
ISA_API_INC=$(abs_path "${ISA_API_INC:-$default_isa_api_inc}")
ISA_API_LIB=$(abs_path "${ISA_API_LIB:-$default_isa_api_lib}")
ISA_CFG=${ISA_CFG:-$orbe_bt_env/dpi/rivai_0x80000000_1core_rom.yaml}

VERILATOR_BUILD_ROOT_OVERRIDE=${VERILATOR_BUILD_ROOT:-}
VERILATOR_LOG_ROOT_OVERRIDE=${VERILATOR_LOG_ROOT:-}
OBJ_DIR_OVERRIDE=${OBJ_DIR:-}
SIM_EXE_OVERRIDE=${SIM_EXE:-}

while (($#)); do
  case "$1" in
    --dut-kind)
      [[ $# -ge 2 ]] || die "--dut-kind requires a value"
      DUT_KIND="$2"
      shift 2
      ;;
    --dut-kind=*)
      DUT_KIND="${1#*=}"
      shift
      ;;
    --tc)
      [[ $# -ge 2 ]] || die "--tc requires a path"
      TC="$2"
      shift 2
      ;;
    --tc=*)
      TC="${1#*=}"
      shift
      ;;
    --tag)
      [[ $# -ge 2 ]] || die "--tag requires a value"
      TAG="$2"
      shift 2
      ;;
    --tag=*)
      TAG="${1#*=}"
      shift
      ;;
    --seed)
      [[ $# -ge 2 ]] || die "--seed requires a value"
      SEED="$2"
      shift 2
      ;;
    --seed=*)
      SEED="${1#*=}"
      shift
      ;;
    --timeout)
      [[ $# -ge 2 ]] || die "--timeout requires a value"
      SIM_TIMEOUT="$2"
      shift 2
      ;;
    --timeout=*)
      SIM_TIMEOUT="${1#*=}"
      shift
      ;;
    --verbosity)
      [[ $# -ge 2 ]] || die "--verbosity requires a value"
      VERBOSITY="$2"
      shift 2
      ;;
    --verbosity=*)
      VERBOSITY="${1#*=}"
      shift
      ;;
    --cosim-enable)
      [[ $# -ge 2 ]] || die "--cosim-enable requires a value"
      COSIM_ENABLE="$2"
      shift 2
      ;;
    --cosim-enable=*)
      COSIM_ENABLE="${1#*=}"
      shift
      ;;
    --cosim-backend)
      [[ $# -ge 2 ]] || die "--cosim-backend requires a value"
      COSIM_BACKEND="$2"
      shift 2
      ;;
    --cosim-backend=*)
      COSIM_BACKEND="${1#*=}"
      shift
      ;;
    --plusargs)
      [[ $# -ge 2 ]] || die "--plusargs requires a value"
      PLUSARGS="$2"
      shift 2
      ;;
    --plusargs=*)
      PLUSARGS="${1#*=}"
      shift
      ;;
    --no-build)
      NO_BUILD=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      if [[ "$command" == "run" && -z "$TC" ]]; then
        TC="$1"
      else
        PLUSARGS="${PLUSARGS:+$PLUSARGS }$1"
      fi
      shift
      ;;
  esac
done

VERILATOR_BUILD_ROOT=${VERILATOR_BUILD_ROOT_OVERRIDE:-$orbe_bt_env/sim/verilator_${TAG}/build}
VERILATOR_LOG_ROOT=${VERILATOR_LOG_ROOT_OVERRIDE:-$orbe_bt_env/sim/verilator_${TAG}/log}
OBJ_DIR=${OBJ_DIR_OVERRIDE:-$VERILATOR_BUILD_ROOT/obj_${DUT_KIND}}
SIM_EXE=${SIM_EXE_OVERRIDE:-$VERILATOR_BUILD_ROOT/be_tb_top_${DUT_KIND}}

case "$DUT_KIND" in
  agent)
    # FE agent -> be_bfm -> CacheAgent closed loop of the three; no DUT, no COSIM observer.
    rtl_filelist=cfg/filelist/rtl_agent.f
    dut_define=-DORBE_DUT_AGENT
    ;;
  rtl_v1)
    rtl_filelist=cfg/filelist/rtl_v1.f
    dut_define=-DORBE_DUT_RTL_V1
    ;;
  rtl_fe)
    # OR_FE RTL + BE RTL: the FE slot is filled by or_fe_top; cache_agent doubles as FE's L2/PTW
    rtl_filelist=cfg/filelist/rtl_fe.f
    dut_define="-DORBE_DUT_RTL_V1 -DORBE_FE_RTL"
    ;;
  rtl_cache)
    # OR_Cache RTL + BE RTL: the LSU slot is filled by or_cache_top; cache_agent only does D-side model sync / downstream responses
    rtl_filelist=cfg/filelist/rtl_cache.f
    dut_define="-DORBE_DUT_RTL_V1 -DORBE_CACHE_RTL"
    ;;
  rtl_full)
    # OR_FE RTL + OR_Cache RTL + BE RTL: cache_agent doubles as FE's L2/PTW and D-side model sync / downstream responses
    rtl_filelist=cfg/filelist/rtl_full.f
    dut_define="-DORBE_DUT_RTL_V1 -DORBE_FE_RTL -DORBE_CACHE_RTL"
    ;;
  *)
    die "unsupported DUT_KIND=$DUT_KIND; expected agent, rtl_v1, rtl_fe, rtl_cache or rtl_full"
    ;;
esac

# Keep only defines that are actually referenced:
#
#   SYNTHESIS               -- RTL wraps its built-in assertions in `ifndef SYNTHESIS (alu_simple /
#                              csr_unit / div_simple / mul_simple / g3_lsu_iface /
#                              CompletionScoreboard, six places). Passing it = these assertions are not compiled.
#   ORBE_EXTERNAL_MNEMONICS -- be_agent / cosim_pkg look up mnemonic names via an external table.
#   $dut_define             -- ORBE_DUT_RTL_V1 or ORBE_DUT_AGENT, dispatching between the two DUT kinds.
base_defines=(
  -DSYNTHESIS
  -DORBE_EXTERNAL_MNEMONICS
  $dut_define
)

warning_flags=(
  -Wno-fatal
  -Wno-DECLFILENAME
  -Wno-UNUSEDSIGNAL
  -Wno-UNUSEDPARAM
  -Wno-TIMESCALEMOD
  -Wno-WIDTHEXPAND
  -Wno-WIDTHTRUNC
  -Wno-SYMRSVDWORD
  -Wno-ZERODLY
)

sv_inputs=(
  -f cfg/filelist/common.f
  -f "$rtl_filelist"
  dpi/isa_dpi_pkg.sv
  -f cfg/filelist/tb.f
)

check_common_inputs() {
  command -v "$VERILATOR" >/dev/null 2>&1 || die "verilator not found: $VERILATOR"
  need_file "$orbe_bt_env/cfg/filelist/common.f" "common filelist"
  need_file "$orbe_bt_env/$rtl_filelist" "RTL filelist"
  need_file "$orbe_bt_env/cfg/filelist/tb.f" "TB filelist"
  need_file "$orbe_bt_env/dpi/isa_dpi_pkg.sv" "DPI SV package"
}

check_dpi_inputs() {
  need_file "$ISA_API_INC/IsaApi.h" "IsaApi.h"
  need_file "$ISA_API_LIB/lib_ISA_api.so" "lib_ISA_api.so"
  need_file "$orbe_bt_env/dpi/isa_dpi_wrapper.cc" "DPI C++ wrapper"
  if ! grep -q "IsaApiDecodeMetadata" "$ISA_API_INC/IsaApi.h"; then
    die "IsaApi.h at $ISA_API_INC lacks IsaApiDecodeMetadata; set ISA_API_INC/ISA_API_LIB to the matching parent ISA model build"
  fi
}

print_config() {
  echo "[VERILATOR_COSIM] command=$command dut=$DUT_KIND tag=$TAG seed=$SEED cosim=$COSIM_ENABLE backend=$COSIM_BACKEND"
  echo "[VERILATOR_COSIM] jobs=$JOBS"
  echo "[VERILATOR_COSIM] obj_dir=$OBJ_DIR"
  echo "[VERILATOR_COSIM] sim_exe=$SIM_EXE"
  echo "[VERILATOR_COSIM] isa_api_inc=$ISA_API_INC"
  echo "[VERILATOR_COSIM] isa_api_lib=$ISA_API_LIB"
}

run_lint() {
  check_common_inputs
  print_config
  cd "$orbe_bt_env"
  "$VERILATOR" --lint-only --timing -sv --top-module be_tb_top \
    --timescale 1ns/1ps \
    "${warning_flags[@]}" \
    "${base_defines[@]}" \
    "${sv_inputs[@]}"
}

run_build() {
  check_common_inputs
  check_dpi_inputs
  mkdir -p "$VERILATOR_BUILD_ROOT" "$OBJ_DIR"
  print_config
  cd "$orbe_bt_env"
  "$VERILATOR" --binary --timing -sv --top-module be_tb_top \
    --timescale 1ns/1ps \
    --Mdir "$OBJ_DIR" \
    -o "$SIM_EXE" \
    -j "$JOBS" \
    "${warning_flags[@]}" \
    "${base_defines[@]}" \
    -CFLAGS "-std=c++17 -I$ISA_API_INC" \
    -LDFLAGS "-L$ISA_API_LIB -l_ISA_api -Wl,-rpath,$ISA_API_LIB" \
    "${sv_inputs[@]}" \
    dpi/isa_dpi_wrapper.cc
}

run_case() {
  local tc_abs
  local isa_cfg_abs
  local elf_base
  local elf_name
  local case_dir
  local sim_log
  local run_log
  local commit_log
  local status
  local extra_args=()
  local sim_args=()

  [[ -n "$TC" ]] || die "run requires --tc /path/to/test.elf"
  tc_abs=$(abs_path "$TC")
  isa_cfg_abs=$(abs_path "$ISA_CFG")
  need_file "$tc_abs" "ELF"
  need_file "$isa_cfg_abs" "ISA config"
  need_file "$SIM_EXE" "Verilator simulator executable"

  elf_base=$(basename "$tc_abs")
  elf_name=${elf_base%%.*}
  [[ -n "$elf_name" ]] || elf_name=no_elf
  case_dir="$VERILATOR_LOG_ROOT/$DUT_KIND/${elf_name}_${SEED}"
  sim_log="$case_dir/sim.log"
  run_log="$case_dir/isa_run.log"
  commit_log="$case_dir/isa_commit.log"
  mkdir -p "$case_dir"

  if command -v "$OBJDUMP" >/dev/null 2>&1; then
    "$OBJDUMP" -d "$tc_abs" > "$case_dir/${elf_name}.dump" 2>/dev/null || true
  fi

  if [[ -n "$PLUSARGS" ]]; then
    # Intentionally split on whitespace, matching the existing Make PLUSARGS style.
    # shellcheck disable=SC2206
    extra_args=($PLUSARGS)
  fi

  sim_args=(
    +TEST=elf
    +ntb_random_seed="$SEED"
    +SIM_TIMEOUT_CYCLES="$SIM_TIMEOUT"
    +VERBOSITY="$VERBOSITY"
    +COSIM_ENABLE="$COSIM_ENABLE"
    +COSIM_BACKEND="$COSIM_BACKEND"
    +ISA_CFG="$isa_cfg_abs"
    +ISA_ELF="$tc_abs"
    +ISA_RUN_LOG="$run_log"
    +ISA_COMMIT_LOG="$commit_log"
    "${extra_args[@]}"
  )

  echo "[VERILATOR_COSIM] log_dir=$case_dir"
  set +e
  LD_LIBRARY_PATH="$ISA_API_LIB${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" \
    "$SIM_EXE" "${sim_args[@]}" > "$sim_log" 2>&1
  status=$?
  set -e

  echo "[VERILATOR_COSIM] sim_log=$sim_log"
  echo "[VERILATOR_COSIM] isa_run_log=$run_log"
  echo "[VERILATOR_COSIM] isa_commit_log=$commit_log"
  if command -v rg >/dev/null 2>&1; then
    rg -i "\[COSIM\]|\[BE\]\[COSIM\]|MISMATCH|%Error|Assertion failed|DPI_EXIT_RESULT|REPORTER_SUMMARY" "$sim_log" || true
    # [FE_EQUIV]/[CACHE_EQUIV] summary lines themselves carry "mismatch=<n>": exclude summary lines first, then search for failure keywords;
    # a nonzero mismatch on a summary line is judged a failure separately (per-item mismatches are counted into REPORTER_SUMMARY via reporter.error).
    if rg -v '_EQUIV\] checked=' "$sim_log" | rg -qi "MISMATCH|%Error|Assertion failed|\[DPI_EXIT_RESULT\][[:space:]]+FAIL|REPORTER_SUMMARY.*(error=[1-9][0-9]*|fatal=[1-9][0-9]*)" \
       || rg -q '_EQUIV\] checked=.* mismatch=[1-9]' "$sim_log"; then
      [[ "$status" -ne 0 ]] || status=1
    fi
  fi
  return "$status"
}

case "$command" in
  lint)
    run_lint
    ;;
  build)
    run_build
    ;;
  run)
    if [[ "$NO_BUILD" != 1 ]]; then
      run_build
    fi
    run_case
    ;;
  clean)
    print_config
    rm -rf "$VERILATOR_BUILD_ROOT" "$VERILATOR_LOG_ROOT"
    ;;
  help|-h|--help)
    usage
    ;;
esac
