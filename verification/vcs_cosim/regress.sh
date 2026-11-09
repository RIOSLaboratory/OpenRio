#!/usr/bin/env bash
# Batch-run cases on the VCS engine: one `make run` per case, judge PASS/FAIL from sim.log.
#
# This is the VCS twin of or_cosim/tools/regress.sh: same arguments, same stdout
# lines, same results.txt/summary.txt format, so the two engines can be compared
# with a plain diff:
#   or_cosim/sim/verilator_<tag>/regress/<dut>/<suite>/results.txt
#   or_cosim/sim/vcs_<tag>/regress/<dut>/<suite>/results.txt
#
# Usage: vcs_cosim/regress.sh [dut-kind] [tag] [jobs] [case-list]
#   dut-kind: defaults to rtl_full (BE + FE + Cache) when omitted
#   case-list: one path per line; '#' comments and blank lines are ignored.
#              Relative entries resolve against CASE_ROOT, which defaults to
#              $ISA_MODEL_ROOT/isa_case; absolute entries are used as-is.
#              When omitted, cfg/cases/cases_239.list is used (239 ISA cases).
# Environment:
#   CASE_ROOT    directory used to resolve relative entries (default: $ISA_MODEL_ROOT/isa_case)
#   SIM_TIMEOUT  cycle limit forwarded to the Makefile (default: 2000000)
#   ISA_LOG      all|commit|none forwarded to the Makefile (default: all)
#   COSIM_OB_LOG 0|1 per-commit [BE][COSIM_OB] lines (default: 1; use 0 for Embench)
#   VCS_WORK_ROOT where build/log/regress live (default: <or_cosim>/sim)
# Requires `source env.sh` first (VCS_HOME / VERDI_HOME / ISA_MODEL_ROOT / gcc14).
# Exit code is 0 when all PASS, otherwise 1.
set -u

vcs_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
or_cosim=$(cd "$vcs_dir/../or_cosim" && pwd)
DUT=${1:-rtl_full}
TAG=${2:-$(date +%Y%m%d)}
JOBS=${3:-4}
LIST=${4:-$or_cosim/cfg/cases/cases_239.list}
[[ -n "$LIST" ]] || LIST=$or_cosim/cfg/cases/cases_239.list
LIST=$(cd "$(dirname "$LIST")" && pwd)/$(basename "$LIST")
[[ -r "$LIST" ]] || { echo "error: case list not readable: $LIST" >&2; exit 1; }

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

SIM_ROOT=${VCS_WORK_ROOT:-$or_cosim/sim}
SUITE=$(basename "$LIST" .list)
OUT=$SIM_ROOT/vcs_$TAG/regress/$DUT/$SUITE
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
echo "TIMEOUT: ${SIM_TIMEOUT:-<make default: 2000000>} cycles"

# One build for the whole batch. An up-to-date simv costs a fraction of a second;
# a missing one would otherwise fail all 239 cases with the same make error.
make -s --no-print-directory -C "$vcs_dir" build \
  TAG="$TAG" DUT_KIND="$DUT" VCS_WORK_ROOT="$SIM_ROOT" \
  || { echo "error: VCS build failed; run 'make -C $vcs_dir build TAG=$TAG DUT_KIND=$DUT' and read the tail" >&2; exit 1; }

: > "$OUT/results.txt"

one() {
  local c=$1 tc base log rc bad good simv
  if [[ "$c" == /* ]]; then tc=$c; else tc=$CASE_ROOT/$c; fi
  simv=$SIM_ROOT/vcs_$TAG/build/$DUT/simv
  # -o $(simv): the batch already built once; without it sixteen racers could
  # each decide the simv is stale and start a rebuild of the same -Mdir.
  # shellcheck disable=SC2086
  make -s --no-print-directory -C "$vcs_dir" -o "$simv" run \
    TAG="$TAG" DUT_KIND="$DUT" VCS_WORK_ROOT="$SIM_ROOT" WAVE=none \
    VERBOSITY=1 TC="$tc" $TO_ARG > /dev/null 2>&1
  rc=$?
  base=$(basename "$tc")
  log=$SIM_ROOT/vcs_$TAG/log/$DUT/${base%%.*}_1/sim.log
  # Same judgement as or_cosim/tools/regress.sh: the [FE_EQUIV]/[CACHE_EQUIV]
  # summary lines themselves carry "mismatch=<n>", so exclude them before the
  # keyword search and check a nonzero count separately.
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
export vcs_dir DUT TAG SIM_ROOT CASE_ROOT OUT
# Pass the cycle limit on the command line as well as through the environment:
# a cron/ssh wrapper that forgets to export it must not silently fall back to
# the Makefile default (2000000) -- that mistake already cost one 239 run.
TO_ARG=""
[[ -n "${SIM_TIMEOUT:-}" ]] && TO_ARG="SIM_TIMEOUT=$SIM_TIMEOUT"
export TO_ARG
[[ -n "${SIM_TIMEOUT:-}" ]] && export SIM_TIMEOUT
[[ -n "${ISA_LOG:-}" ]] && export ISA_LOG
[[ -n "${COSIM_OB_LOG:-}" ]] && export COSIM_OB_LOG

start=$(date +%s)
xargs -P "$JOBS" -I{} bash -c 'one "$1"' _ {} < "$OUT/cases.list"
[[ -s "$OUT/results.txt" ]] || { echo "error: results.txt is empty after the batch (disk quota? see REGRESSION_GUIDE 9.1)" >&2; exit 3; }
sort -o "$OUT/results.txt" "$OUT/results.txt"
awk -v w=$(( $(date +%s) - start )) '$1=="PASS"{p++} $1=="FAIL"{f++} END{printf "SUMMARY: PASS=%d FAIL=%d TOTAL=%d wall=%ds\n",p,f,NR,w}' \
  "$OUT/results.txt" | tee "$OUT/summary.txt"
grep '^FAIL' "$OUT/results.txt"
echo "results: $OUT/results.txt"
! grep -q '^FAIL' "$OUT/results.txt"
