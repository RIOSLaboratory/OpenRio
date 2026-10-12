#!/usr/bin/env bash
# =============================================================================
# run_perf.sh -- run the INT dependency conformance cases and collect their logs.
#
# DUT defaults to rtl_full: the base DUT is the complete FE + BE + Cache build
# (cfg/filelist/rtl_full.f), per METHOD section 5. The agent-backed kinds are for
# isolation and diagnosis only -- fe_agent hardwires pred_taken to zero, so every
# taken control transfer mispredicts and flushes there, which changes results rather
# than merely adding noise.
#
# Verbosity must stay at 2 or above. The [BE] event trace that compare.py reads
# (DECODE / ISSUE / WB / COMMIT per instruction) is only emitted at that level.
#
# Usage:
#   run_perf.sh                          # regenerate, build, run all cases
#   run_perf.sh --cases 'INT2_P4_P4'     # only cases whose id contains the pattern
#   run_perf.sh --no-regen --no-build    # reuse what is already there
#   TAG=my_run run_perf.sh               # separate log namespace
# =============================================================================

set -uo pipefail

ENV=/work/home/danielle/workspace/suncheek/model/OpenRio/verification/orbe_bt_env
WORK=/work/home/danielle/workspace/suncheek/model/perf_eval_work
COSIM="$ENV/tools/verilator_cosim.sh"
GEN="$ENV/perf_eval/timing/gen_cases.py"

TAG=${TAG:-timing_delta}
SKIP_DONE=0
DUT=${DUT:-rtl_full}
VERBOSITY=${VERBOSITY:-2}
TIMEOUT=${TIMEOUT:-2000000}
SEED=${SEED:-1}
JOBS=${JOBS:-8}
REGEN=0        # regeneration is opt-in: the case files may be hand-calibrated
BUILD=1
CASES=""

usage() {
    sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
    exit "${1:-0}"
}

while [ $# -gt 0 ]; do
    case "$1" in
        --cases)     CASES="$2"; shift 2 ;;
        --tag)       TAG="$2"; shift 2 ;;
        --dut)       DUT="$2"; shift 2 ;;
        --timeout)   TIMEOUT="$2"; shift 2 ;;
        --seed)      SEED="$2"; shift 2 ;;
        --regen)     REGEN=1; shift ;;
        --no-regen)  REGEN=0; shift ;;
        --skip-done) SKIP_DONE=1; shift ;;
        --no-build)  BUILD=0; shift ;;
        -h|--help)   usage 0 ;;
        *)           echo "unknown argument: $1" >&2; usage 1 ;;
    esac
done

RESULTS="$WORK/results"
SUMMARY="$RESULTS/run_${TAG}.tsv"
mkdir -p "$RESULTS"

if [ "$REGEN" = 1 ]; then
    echo "== regenerate .S/.elf from the caselists"
    python3 "$GEN" --elf || exit 1
else
    echo "== using the existing .S/.elf (pass --regen to rebuild them from the caselists)"
fi

if [ "$BUILD" = 1 ]; then
    echo "== build $DUT (tag $TAG)"
    JOBS="$JOBS" "$COSIM" build --dut-kind "$DUT" --tag "$TAG" || exit 1
fi

# The header is written once; a rerun appends instead of clobbering earlier rows.
if [ ! -f "$SUMMARY" ]; then
    printf 'case\tstatus\tis_good\tretire\tcycle\terr\tfatal\tequiv_mismatch\tlog\n' > "$SUMMARY"
fi

# --skip-done: cases that already have an OK row are not run again, so a batch that
# was interrupted can be resumed without redoing the expensive prefix.
DONE=""
if [ "$SKIP_DONE" = 1 ] && [ -f "$SUMMARY" ]; then
    DONE=$(awk -F'\t' '$2=="OK"{print $1}' "$SUMMARY" | tr '\n' ' ')
    echo "== skipping cases already marked OK ($(echo $DONE | wc -w))"
fi

total=0 ok=0 bad=0
for elf in "$WORK"/elf/*.elf; do
    cid=$(basename "$elf" .elf)
    if [ -n "$CASES" ] && [[ "$cid" != *"$CASES"* ]]; then continue; fi
    if [ -n "$DONE" ] && [[ " $DONE " == *" $cid "* ]]; then continue; fi
    total=$((total + 1))

    "$COSIM" run --no-build --dut-kind "$DUT" --tag "$TAG" \
        --tc "$elf" --verbosity "$VERBOSITY" --seed "$SEED" --timeout "$TIMEOUT" \
        >/dev/null 2>&1
    rc=$?

    log="$ENV/sim/verilator_${TAG}/log/${DUT}/${cid}_${SEED}/sim.log"
    if [ ! -f "$log" ]; then
        printf '%s\tNO_LOG\t-\t-\t-\t-\t-\t-\t%s\n' "$cid" "$log" >> "$SUMMARY"
        echo "  [NO LOG] $cid"; bad=$((bad + 1)); continue
    fi

    is_good=$(rg -o 'is_good=[0-9]+' -r '$0' "$log" | tail -1 | cut -d= -f2)
    retire=$(rg -o 'retire_count=[0-9]+' "$log" | tail -1 | cut -d= -f2)
    cycle=$(rg -o '\[BE\]\[EXIT\] cycle=[0-9]+' "$log" | tail -1 | cut -d= -f2)
    errf=$(rg -o '\[REPORTER_SUMMARY\][^|]*' "$log" | tail -1)
    err=$(echo "$errf" | rg -o 'error=[0-9]+' | cut -d= -f2)
    fatal=$(echo "$errf" | rg -o 'fatal=[0-9]+' | cut -d= -f2)
    mism=$(rg -o 'mismatch=[0-9]+' "$log" | cut -d= -f2 | paste -sd, -)

    status=OK
    { [ "$rc" != 0 ] || [ "$is_good" != 1 ] || [ "${err:-0}" != 0 ] || [ "${fatal:-0}" != 0 ]; } \
        && status=FAIL

    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$cid" "$status" "$is_good" "$retire" "$cycle" "${err:-?}" "${fatal:-?}" "${mism:-?}" "$log" \
        >> "$SUMMARY"

    if [ "$status" = OK ]; then ok=$((ok + 1)); echo "  [ok]   $cid  retire=$retire cycle=$cycle"
    else bad=$((bad + 1)); echo "  [FAIL] $cid  rc=$rc is_good=$is_good error=$err fatal=$fatal"; fi
done

echo
echo "== $total cases: $ok ok, $bad failed"
echo "   summary: $SUMMARY"
echo "   logs   : $ENV/sim/verilator_${TAG}/log/${DUT}/"
[ "$bad" = 0 ]
