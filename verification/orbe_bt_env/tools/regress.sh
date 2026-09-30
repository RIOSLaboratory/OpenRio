#!/usr/bin/env bash
# Batch-run cases: call verilator_cosim.sh run --no-build once per case, judge PASS/FAIL from sim.log.
# Usage: tools/regress.sh [dut-kind] [tag] [jobs] [case-list]
#   dut-kind: defaults to rtl_full (BE + FE + Cache) when omitted
#   case-list: one path per line relative to isa_case/, e.g. rv64ui/rv64ui-p-add.riscv;
#              when omitted, runs the six groups rv64ui/um/ua/uf/ud/uc (216 cases).
# Requires that DUT kind to have been built with the same tag. isa_case/ is taken from the ISA model directory: set via ISA_MODEL_ROOT, or probed upward.
# Exit code is 0 when all PASS, otherwise 1.
set -u

orbe_bt_env=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
DUT=${1:-rtl_full}
TAG=${2:-$(date +%Y%m%d)}
JOBS=${3:-4}
LIST=${4:-}
[[ -z "$LIST" ]] || LIST=$(cd "$(dirname "$LIST")" && pwd)/$(basename "$LIST")

if [[ -n "${ISA_MODEL_ROOT:-}" ]]; then
  ISA_MODEL_ROOT=$(cd "$ISA_MODEL_ROOT" && pwd)
else
  for _cand in "$orbe_bt_env/.." "$orbe_bt_env/../isa_model" "$orbe_bt_env/../../isa_model"; do
    if [[ -r "$_cand/src/libs/IsaApi.h" ]]; then
      ISA_MODEL_ROOT=$(cd "$_cand" && pwd)
      break
    fi
  done
fi
[[ -d "${ISA_MODEL_ROOT:-}/isa_case" ]] || { echo "error: isa_case/ not found; put the ISA model under isa_model/ or set ISA_MODEL_ROOT" >&2; exit 1; }
export ISA_MODEL_ROOT

cd "$orbe_bt_env"
OUT=sim/verilator_$TAG/regress/$DUT
mkdir -p "$OUT"
if [[ -n "$LIST" ]]; then
  cp "$LIST" "$OUT/cases.list"
else
  (cd "$ISA_MODEL_ROOT/isa_case" && find rv64ui rv64um rv64ua rv64uf rv64ud rv64uc -maxdepth 1 -name '*.riscv' | sort) > "$OUT/cases.list"
fi
: > "$OUT/results.txt"

one() {
  local c=$1 log rc bad good
  tools/verilator_cosim.sh run --no-build --dut-kind "$DUT" --tag "$TAG" \
    --tc "$ISA_MODEL_ROOT/isa_case/$c" --verbosity 1 > /dev/null 2>&1
  rc=$?
  log=sim/verilator_$TAG/log/$DUT/$(basename "$c" .riscv)_1/sim.log
  # [FE_EQUIV]/[CACHE_EQUIV] summary lines themselves carry "mismatch=<n>": exclude summary lines first, then search for failure keywords;
  # a nonzero mismatch on a summary line is judged a failure separately (per-item mismatches are counted into REPORTER_SUMMARY via reporter.error).
  bad=$(grep -av '_EQUIV\] checked=' "$log" 2>/dev/null | grep -m1 -aiE 'MISMATCH|%Error|%Fatal|Assertion failed|simulation timeout|REPORTER_SUMMARY.*(error=[1-9]|fatal=[1-9])')
  [[ -n "$bad" ]] || bad=$(grep -m1 -aE '_EQUIV\] checked=.* mismatch=[1-9]' "$log" 2>/dev/null)
  good=$(grep -m1 -a 'is_good=1' "$log" 2>/dev/null)
  if [[ $rc -eq 0 && -z "$bad" && -n "$good" ]]; then
    echo "PASS $c"
  else
    echo "FAIL rc=$rc $c :: ${bad:-no is_good=1}"
  fi >> "$OUT/results.txt"
}
export -f one
export DUT TAG OUT

start=$(date +%s)
grep -v '^\s*$' "$OUT/cases.list" | xargs -P "$JOBS" -I{} bash -c 'one "$1"' _ {}
sort -o "$OUT/results.txt" "$OUT/results.txt"
awk -v w=$(( $(date +%s) - start )) '$1=="PASS"{p++} $1=="FAIL"{f++} END{printf "SUMMARY: PASS=%d FAIL=%d TOTAL=%d wall=%ds\n",p,f,NR,w}' \
  "$OUT/results.txt" | tee "$OUT/summary.txt"
grep '^FAIL' "$OUT/results.txt"
echo "results: $orbe_bt_env/$OUT/results.txt"
! grep -q '^FAIL' "$OUT/results.txt"
