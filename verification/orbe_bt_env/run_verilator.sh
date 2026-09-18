#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
cosim_tool="$script_dir/tools/verilator_cosim.sh"

usage() {
  cat <<'USAGE'
Usage:
  ISA_ELF=path/to/test.riscv ./run_verilator.sh [plusargs]
  BUILD_ONLY=1 ./run_verilator.sh

Compatibility wrapper for the historical mock-only entry point.  New flows
should call tools/verilator_cosim.sh directly.

Environment:
  DUT_KIND              mock by default; may also be rtl_v1
  ISA_ELF               ELF to run
  TAG                   output namespace tag
  SEED                  random seed and log suffix
  SIM_TIMEOUT_CYCLES    simulation timeout cycles
  VERBOSITY             1, 2, or 3
  COSIM_ENABLE          1 by default
USAGE
}

if [[ ${1:-} == "--help" || ${1:-} == "-h" ]]; then
  usage
  exit 0
fi

if [[ ${1:-} == "--all" || ${RUN_ALL:-0} == 1 ]]; then
  echo "run_verilator.sh --all is deprecated; use the 216-case loop in README.md." >&2
  exit 2
fi

cmd=run
if [[ ${BUILD_ONLY:-0} == 1 ]]; then
  cmd=build
fi

args=("$cmd" "--dut-kind" "${DUT_KIND:-mock}")

if [[ -n ${TAG:-} ]]; then
  args+=("--tag" "$TAG")
fi
if [[ -n ${SEED:-} ]]; then
  args+=("--seed" "$SEED")
fi
if [[ -n ${SIM_TIMEOUT_CYCLES:-} ]]; then
  args+=("--timeout" "$SIM_TIMEOUT_CYCLES")
fi
if [[ -n ${VERBOSITY:-} ]]; then
  args+=("--verbosity" "$VERBOSITY")
fi
args+=("--cosim-enable" "${COSIM_ENABLE:-1}")

if [[ "$cmd" == "run" ]]; then
  if [[ -z ${ISA_ELF:-} ]]; then
    echo "ISA_ELF=path/to/test.riscv is required for run_verilator.sh runs." >&2
    exit 2
  fi
  args+=("--tc" "$ISA_ELF")
fi

exec "$cosim_tool" "${args[@]}" "$@"
