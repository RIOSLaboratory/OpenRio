#!/usr/bin/env bash
# Batch-run cases: call verilator_cosim.sh run --no-build once per case, judge PASS/FAIL from sim.log.
# Usage: tools/regress.sh [dut-kind] [tag] [jobs] [case-list]
#   dut-kind: defaults to rtl_full (BE + FE + Cache) when omitted
#   case-list: one path per line; '#' comments and blank lines are ignored.
#              Relative entries resolve against CASE_ROOT, which defaults to
#              $ISA_MODEL_ROOT/isa_case; absolute entries are used as-is.
#              When omitted, cfg/cases/cases_239.list is used (239 ISA cases).
# Environment:
#   CASE_ROOT    directory used to resolve relative entries (default: $ISA_MODEL_ROOT/isa_case)
#   SIM_TIMEOUT  cycle limit forwarded to verilator_cosim.sh (default: 2000000)
#   ISA_LOG      all|commit|none, forwarded to verilator_cosim.sh (default: all)
#   COSIM_OB_LOG 0|1, per-commit [BE][COSIM_OB] lines (default: 1; use 0 for Embench)
# Requires that DUT kind to have been built with the same tag. isa_case/ is taken from the ISA model directory: set via ISA_MODEL_ROOT, or probed upward.
# Exit code is 0 when all PASS, otherwise 1.
set -u

or_cosim=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
DUT=${1:-rtl_full}
TAG=${2:-$(date +%Y%m%d)}
JOBS=${3:-4}
LIST=${4:-$or_cosim/cfg/cases/cases_239.list}
[[ -n "$LIST" ]] || LIST=$or_cosim/cfg/cases/cases_239.list
LIST=$(cd "$(dirname "$LIST")" && pwd)/$(basename "$LIST")
[[ -r "$LIST" ]] || { echo "error: case list not readable: $LIST" >&2; exit 1; }
[[ -n "${SIM_TIMEOUT:-}" ]] && export SIM_TIMEOUT
[[ -n "${ISA_LOG:-}" ]] && export ISA_LOG
[[ -n "${COSIM_OB_LOG:-}" ]] && export COSIM_OB_LOG

if [[ -n "${ISA_MODEL_ROOT:-}" ]]; then
  ISA_MODEL_ROOT=$(cd "$ISA_MODEL_ROOT" && pwd)
else
  for _cand in "$or_cosim/.." "$or_cosim/../isa_model" "$or_cosim/../../isa_model"; do
    if [[ -r "$_cand/src/libs/IsaApi.h" ]]; then
      ISA_MODEL_ROOT=$(cd "$_cand" && pwd)
      break
    fi
  done
fi
[[ -d "${ISA_MODEL_ROOT:-}/isa_case" ]] || { echo "error: isa_case/ not found; put the ISA model under isa_model/ or set ISA_MODEL_ROOT" >&2; exit 1; }
export ISA_MODEL_ROOT

CASE_ROOT_RAW=${CASE_ROOT:-$ISA_MODEL_ROOT/isa_case}
CASE_ROOT=$(cd "$CASE_ROOT_RAW" 2>/dev/null && pwd) || { echo "error: CASE_ROOT not found: $CASE_ROOT_RAW" >&2; exit 1; }
export CASE_ROOT

cd "$or_cosim"
SUITE=$(basename "$LIST" .list)
OUT=sim/verilator_$TAG/regress/$DUT/$SUITE
mkdir -p "$OUT"
grep -vE '^[[:space:]]*(#|$)' "$LIST" > "$OUT/cases.list" || true
actual=$(wc -l < "$OUT/cases.list")
expected=$(sed -n 's/^# *expected *= *\([0-9][0-9]*\).*/\1/p' "$LIST" | head -1)
if [[ -n "$expected" && "$expected" != "$actual" ]]; then
  echo "error: $LIST declares expected=$expected but has $actual entries" >&2
  exit 1
fi
[[ "$actual" -gt 0 ]] || { echo "error: no cases in $LIST" >&2; exit 1; }
list_sha=$(sha256sum "$LIST" | awk '{print $1}')
echo "SUITE: $SUITE entries=$actual case_root=$CASE_ROOT list_sha256=$list_sha"
: > "$OUT/results.txt"

one() {
  local c=$1 tc base log rc bad good
  if [[ "$c" == /* ]]; then tc=$c; else tc=$CASE_ROOT/$c; fi
  tools/verilator_cosim.sh run --no-build --dut-kind "$DUT" --tag "$TAG" \
    --tc "$tc" --verbosity 1 > /dev/null 2>&1
  rc=$?
  base=$(basename "$tc")
  log=sim/verilator_$TAG/log/$DUT/${base%%.*}_1/sim.log
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
xargs -P "$JOBS" -I{} bash -c 'one "$1"' _ {} < "$OUT/cases.list"
sort -o "$OUT/results.txt" "$OUT/results.txt"
awk -v w=$(( $(date +%s) - start )) '$1=="PASS"{p++} $1=="FAIL"{f++} END{printf "SUMMARY: PASS=%d FAIL=%d TOTAL=%d wall=%ds\n",p,f,NR,w}' \
  "$OUT/results.txt" | tee "$OUT/summary.txt"
grep '^FAIL' "$OUT/results.txt"
echo "results: $or_cosim/$OUT/results.txt"
! grep -q '^FAIL' "$OUT/results.txt"
