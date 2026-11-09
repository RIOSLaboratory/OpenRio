#!/usr/bin/env bash
# Cadence wrapper: daily 239 ISA regression / weekly Embench regression, on
# either engine, with baseline comparison and history pruning.
#
#   tools/regress_cron.sh --suite daily  --engine vcs   -j 16
#   tools/regress_cron.sh --suite weekly --engine vcs   -j 16
#
# Exit codes (this is the part a cron job should act on):
#   0  no new failures (the 4 known rtl_full failures are expected on 239)
#   1  new failure(s) compared with the previous run of the same suite
#   3  infrastructure failure: the batch produced no results at all
#
# Environment (all optional):
#   SIM_ENGINE_ROOT  where <engine>_<tag>/ trees live    (default: or_cosim/sim)
#   CASE_ROOT        ELF dir for the weekly Embench run  (required for weekly)
#   SIM_TIMEOUT      overrides the per-suite default
#   ISA_LOG          overrides the per-suite default
#   COSIM_OB_LOG     overrides the per-suite default
#
# Cron examples (cad21; source env.sh, cron has no profile):
#   0 2 * * *  cd /work/home03/danielle/hardware/hardware-openrio/verification && \
#              source vcs_cosim/env.sh && tools/regress_cron.sh --suite daily  --engine vcs -j 16
#   0 3 * * 0  cd /work/home03/danielle/hardware/hardware-openrio/verification && \
#              source vcs_cosim/env.sh && tools/regress_cron.sh --suite weekly --engine vcs -j 16
set -u

self_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
verif_root=$(cd "$self_dir/.." && pwd)
or_cosim=$verif_root/or_cosim

die() { echo "error: $*" >&2; exit 3; }

SUITE=""
ENGINE=vcs
JOBS=16
KEEP=""
DUT=rtl_full
LIST=""
FORCE=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --suite)   SUITE=${2:?}; shift 2 ;;
    --suite=*) SUITE=${1#*=}; shift ;;
    --engine)  ENGINE=${2:?}; shift 2 ;;
    --engine=*) ENGINE=${1#*=}; shift ;;
    -j|--jobs) JOBS=${2:?}; shift 2 ;;
    --keep)    KEEP=${2:?}; shift 2 ;;
    --dut-kind) DUT=${2:?}; shift 2 ;;
    --list)    LIST=${2:?}; shift 2 ;;
    --force)   FORCE=1; shift ;;
    -h|--help) sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

case "$SUITE" in
  daily)
    LIST=${LIST:-$or_cosim/cfg/cases/cases_239.list}
    TAG="daily-$(date +%Y%m%d)"
    : "${SIM_TIMEOUT:=200000}"
    : "${ISA_LOG:=all}"
    : "${COSIM_OB_LOG:=1}"
    : "${KEEP:=7}"
    ;;
  weekly)
    LIST=${LIST:-$or_cosim/cfg/cases/cases_embench.list}
    TAG="weekly-$(date +%G-W%V)"
    : "${SIM_TIMEOUT:=20000000}"
    : "${ISA_LOG:=none}"
    : "${COSIM_OB_LOG:=0}"
    : "${KEEP:=4}"
    ;;
  *) die "--suite must be daily or weekly" ;;
esac
[[ "$ENGINE" == verilator || "$ENGINE" == vcs ]] || die "--engine must be verilator or vcs"
[[ -r "$LIST" ]] || die "case list not readable: $LIST"
case "$SUITE" in
  weekly) [[ -n "${CASE_ROOT:-}" ]] || die "weekly runs need CASE_ROOT=<dir with the 19 Embench ELFs>" ;;
esac

SIM_ROOT=${SIM_ENGINE_ROOT:-$or_cosim/sim}
export SIM_ENGINE_ROOT=$SIM_ROOT
# The VCS back end honours VCS_WORK_ROOT; point it at the same tree so one knob
# moves both engines.
export VCS_WORK_ROOT=$SIM_ROOT
SUITE_NAME=$(basename "$LIST" .list)
RES_DIR=$SIM_ROOT/${ENGINE}_$TAG/regress/$DUT/$SUITE_NAME
HIST=$SIM_ROOT/regress_history/${ENGINE}_$SUITE
mkdir -p "$HIST"

# One run per suite at a time. A stale lock (dead pid or older than 12 h) is
# taken over rather than blocking the cadence forever.
LOCK=$SIM_ROOT/.regress_cron.$ENGINE.$SUITE.lock
if [[ -d "$LOCK" ]]; then
  if [[ $FORCE == 1 ]] || ! kill -0 "$(cat "$LOCK/pid" 2>/dev/null)" 2>/dev/null \
     || [[ -n "$(find "$LOCK" -maxdepth 0 -mmin +720 2>/dev/null)" ]]; then
    rm -rf "$LOCK"
  else
    die "another $SUITE run is in flight ($LOCK)"
  fi
fi
mkdir -p "$LOCK"; echo $$ > "$LOCK/pid"
trap 'rm -rf "$LOCK"' EXIT

echo "=== $SUITE regression: engine=$ENGINE dut=$DUT tag=$TAG jobs=$JOBS ==="
echo "list=$LIST"
echo "results=$RES_DIR"
echo "env: SIM_TIMEOUT=$SIM_TIMEOUT ISA_LOG=$ISA_LOG COSIM_OB_LOG=$COSIM_OB_LOG"

# Snapshot today's fail list before the batch overwrites it: a same-day rerun
# then still has a baseline to compare against.
rm -f "$HIST/.prev_sameday.fail"
[[ -r "$HIST/$TAG.fail" ]] && cp -f "$HIST/$TAG.fail" "$HIST/.prev_sameday.fail"

start=$(date +%s)
"$self_dir/or_cosim.sh" regress --engine "$ENGINE" --dut-kind "$DUT" --tag "$TAG" \
  -j "$JOBS" --list "$LIST" > "$HIST/$TAG.log" 2>&1
batch_rc=$?
wall=$(( $(date +%s) - start ))

RESULTS=$RES_DIR/results.txt
[[ -r "$RESULTS" ]] || die "no results.txt after the batch (rc=$batch_rc); see $HIST/$TAG.log"

p=$(awk '$1=="PASS"' "$RESULTS" | wc -l)
f=$(awk '$1=="FAIL"' "$RESULTS" | wc -l)
total=$(wc -l < "$RESULTS")

# Baseline = previous run of the same suite: the newest earlier tag directory,
# or -- for a same-day rerun whose tag tree was just overwritten -- the newest
# stored fail list that is not today's.
prev=""
while IFS= read -r d; do
  [[ "$d" == "${ENGINE}_$TAG" ]] && continue
  prev=$d
done < <(find "$SIM_ROOT" -maxdepth 1 -type d -name "${ENGINE}_${SUITE}-*" -printf '%f\n' 2>/dev/null | sort)
prev_results=""
if [[ -n "$prev" && -r "$SIM_ROOT/$prev/regress/$DUT/$SUITE_NAME/results.txt" ]]; then
  prev_results=$SIM_ROOT/$prev/regress/$DUT/$SUITE_NAME/results.txt
fi

awk '$1=="FAIL"{print $3}' "$RESULTS" > "$HIST/$TAG.fail"
prev_fail_file=""
if [[ -n "$prev_results" ]]; then
  awk '$1=="FAIL"{print $3}' "$prev_results" > "$HIST/.prev.fail"
  prev_fail_file=$HIST/.prev.fail
else
  if [[ -r "$HIST/.prev_sameday.fail" ]]; then
    prev_fail_file=$HIST/.prev_sameday.fail; prev="sameday"
  else
    for c in $(ls -1t "$HIST"/*.fail 2>/dev/null); do
      [[ "$(basename "$c")" == "$TAG.fail" ]] && continue
      prev_fail_file=$c; prev="history:$(basename "$c" .fail)"; break
    done
  fi
fi

if [[ -n "$prev_fail_file" ]]; then
  new_fails=$(comm -13 <(sort "$prev_fail_file") <(sort "$HIST/$TAG.fail"))
  fixed=$(comm -23 <(sort "$prev_fail_file") <(sort "$HIST/$TAG.fail"))
  case "$prev_fail_file" in "$HIST/.prev.fail"|"$HIST/.prev_sameday.fail") rm -f "$prev_fail_file" ;; esac
else
  new_fails=""
  fixed=""
fi

{
  echo "suite=$SUITE engine=$ENGINE dut=$DUT tag=$TAG"
  echo "SUMMARY: PASS=$p FAIL=$f TOTAL=$total wall=${wall}s batch_rc=$batch_rc"
  echo "baseline=${prev:-<none: this run establishes it>}"
  echo "new_failures=$(printf '%s' "$new_fails" | wc -w)"
  printf '%s\n' "$new_fails" | sed '/^$/d;s/^/NEW_FAIL /'
  printf '%s\n' "$fixed" | sed '/^$/d;s/^/FIXED /'
} > "$HIST/$TAG.txt"
cp -f "$HIST/$TAG.txt" "$HIST/latest.txt"

# Keep the newest $KEEP result trees of this suite; the quota on the internal
# home is ~100 GB and each tree carries a simv plus per-case logs.
mapfile -t trees < <(find "$SIM_ROOT" -maxdepth 1 -type d -name "${ENGINE}_${SUITE}-*" -printf '%f\n' | sort)
if (( ${#trees[@]} > KEEP )); then
  for d in "${trees[@]:0:${#trees[@]}-KEEP}"; do
    echo "prune: $d"
    rm -rf "$SIM_ROOT/$d"
    rm -f "$HIST/${d#${ENGINE}_}.log" "$HIST/${d#${ENGINE}_}.txt" "$HIST/${d#${ENGINE}_}.fail"
  done
fi

sed -n '1,40p' "$HIST/$TAG.txt"
if [[ -n "$new_fails" ]]; then
  echo "RESULT: REGRESSION (new failures above)"
  exit 1
fi
echo "RESULT: OK (no new failure${prev:+, baseline $prev})"
exit 0
