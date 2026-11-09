#!/usr/bin/env bash
# One entry point for both simulation engines of the ORBE cosim testbench.
#
#   tools/or_cosim.sh <command> --engine <verilator|vcs> [options]
#
# The two engines keep their own back ends -- verilator_cosim.sh / regress.sh
# for Verilator, vcs_cosim/Makefile / vcs_cosim/regress.sh for VCS -- and this
# script only maps one flag set onto them. Nothing here compiles anything of
# its own, so the existing flows stay exactly as they were.
#
# Commands:
#   check    validate tool paths, ISA model and case list for the engine
#   build    compile the DUT for one tag
#   run      run one ELF
#   wave     run one ELF with waveform dumping (Verilator: VCD via TRACE=1;
#            VCS: FSDB via the runtime +WAVE=fsdb switch, no rebuild)
#   regress  batch-run a case list (default cfg/cases/cases_239.list)
#   compare  diff the two engines' results.txt for one tag
#   clean    remove one tag's artefacts of that engine
#
# Options:
#   --engine <verilator|vcs>   default: verilator
#   --dut-kind <agent|rtl_v1|rtl_fe|rtl_cache|rtl_full>   default: rtl_full
#   --tag <name>               default: today's date (YYYYMMDD)
#   --tc <path>                ELF for run/wave
#   --seed <n>                 default: 1
#   --timeout <cycles>         forwarded as SIM_TIMEOUT, default: engine's own
#   --verbosity <1|2|3>        default: 3 (regress forces 1)
#   -j, --jobs <n>             regress parallelism, default: 8
#   --list <case list>         regress input, default: cfg/cases/cases_239.list
#   --no-build                 run: reuse the existing executable
#   --plusargs '<args>'        extra simulator plusargs
#   -h, --help
#
# Artifacts (identical shape for both engines, so `compare` is a plain diff):
#   or_cosim/sim/verilator_<tag>/{log,regress}/<dut>/...
#   or_cosim/sim/vcs_<tag>/{build,log,regress}/<dut>/...
#
# Examples:
#   tools/or_cosim.sh check  --engine vcs
#   tools/or_cosim.sh build  --engine vcs  --tag reg1
#   tools/or_cosim.sh regress --engine verilator --tag reg1 -j 16
#   tools/or_cosim.sh regress --engine vcs       --tag reg1 -j 16
#   tools/or_cosim.sh compare --tag reg1
set -u

self_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
verif_root=$(cd "$self_dir/.." && pwd)
or_cosim=$verif_root/or_cosim
vcs_dir=$verif_root/vcs_cosim

die() { echo "error: $*" >&2; exit 1; }

usage() { sed -n '2,/^set -u$/p' "${BASH_SOURCE[0]}" | sed '$d' | sed 's/^# \{0,1\}//'; }

CMD=""
ENGINE=verilator
DUT=rtl_full
TAG=$(date +%Y%m%d)
TC=""
SEED=1
TIMEOUT=""
VERBOSITY=3
JOBS=8
LIST=""
NO_BUILD=0
PLUSARGS=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    check|build|run|wave|regress|compare|clean) CMD=$1; shift ;;
    --engine)     ENGINE=${2:?}; shift 2 ;;
    --engine=*)   ENGINE=${1#*=}; shift ;;
    --dut-kind)   DUT=${2:?}; shift 2 ;;
    --dut-kind=*) DUT=${1#*=}; shift ;;
    --tag)        TAG=${2:?}; shift 2 ;;
    --tag=*)      TAG=${1#*=}; shift ;;
    --tc)         TC=${2:?}; shift 2 ;;
    --tc=*)       TC=${1#*=}; shift ;;
    --seed)       SEED=${2:?}; shift 2 ;;
    --seed=*)     SEED=${1#*=}; shift ;;
    --timeout)    TIMEOUT=${2:?}; shift 2 ;;
    --timeout=*)  TIMEOUT=${1#*=}; shift ;;
    --verbosity)  VERBOSITY=${2:?}; shift 2 ;;
    --verbosity=*) VERBOSITY=${1#*=}; shift ;;
    -j|--jobs)    JOBS=${2:?}; shift 2 ;;
    -j*)          JOBS=${1#-j}; shift ;;
    --jobs=*)     JOBS=${1#*=}; shift ;;
    --list)       LIST=${2:?}; shift 2 ;;
    --list=*)     LIST=${1#*=}; shift ;;
    --no-build)   NO_BUILD=1; shift ;;
    --plusargs)   PLUSARGS=${2:?}; shift 2 ;;
    --plusargs=*) PLUSARGS=${1#*=}; shift ;;
    -h|--help)    usage; exit 0 ;;
    *) die "unknown argument: $1 (try --help)" ;;
  esac
done

[[ -n "$CMD" ]] || { usage; exit 1; }
case "$ENGINE" in
  verilator|vcs) ;;
  *) die "unsupported --engine '$ENGINE'; expected verilator or vcs" ;;
esac

SUITE=cases_239
if [[ -n "$LIST" ]]; then SUITE=$(basename "$LIST" .list); fi
SIM_ROOT=${SIM_ENGINE_ROOT:-$or_cosim/sim}
RES_DIR=regress/$DUT/$SUITE

# Forward an optional cycle limit identically to both back ends.
timeout_args_vcs() { [[ -n "$TIMEOUT" ]] && printf 'SIM_TIMEOUT=%s' "$TIMEOUT"; }

need_tc() { [[ -n "$TC" ]] || die "$CMD needs --tc <path/to/*.riscv>"; }

# Mirror the Makefile's ELF_NAME: basename first, then strip the extension.
elf_base() { local b; b=$(basename "$1"); printf '%s' "${b%%.*}"; }

case "$CMD" in
  check)
    if [[ "$ENGINE" == vcs ]]; then
      command -v vcs >/dev/null 2>&1 || die "vcs not in PATH; source vcs_cosim/env.sh first"
      make -s --no-print-directory -C "$vcs_dir" check
    else
      command -v verilator >/dev/null 2>&1 || die "verilator not in PATH; set VERILATOR or source env.sh"
      echo "verilator = $(command -v verilator)"
      verilator --version
      [[ -r ${ISA_MODEL_ROOT:-}/src/libs/IsaApi.h ]] || [[ -r ${ISA_MODEL_ROOT:-}/include/IsaApi.h ]] \
        || die "IsaApi.h not found under ISA_MODEL_ROOT=${ISA_MODEL_ROOT:-<unset>}"
      echo "ISA_MODEL_ROOT = ${ISA_MODEL_ROOT}"
      [[ -r $or_cosim/dpi/rivai_0x80000000_1core_rom.yaml ]] || die "missing ISA cfg yaml"
      echo "engine = verilator, dut-kind = $DUT, tag = $TAG"
    fi
    ;;

  build)
    if [[ "$ENGINE" == vcs ]]; then
      make -C "$vcs_dir" build TAG="$TAG" DUT_KIND="$DUT" $(timeout_args_vcs)
    else
      "$or_cosim/tools/verilator_cosim.sh" build --dut-kind "$DUT" --tag "$TAG" \
        --seed "$SEED" --verbosity "$VERBOSITY" \
        ${TIMEOUT:+--timeout "$TIMEOUT"} ${PLUSARGS:+--plusargs "$PLUSARGS"}
    fi
    ;;

  run)
    need_tc
    if [[ "$ENGINE" == vcs ]]; then
      make -C "$vcs_dir" run TAG="$TAG" DUT_KIND="$DUT" WAVE=none \
        TC="$TC" SEED="$SEED" VERBOSITY="$VERBOSITY" $(timeout_args_vcs) \
        ${PLUSARGS:+PLUSARGS="$PLUSARGS"}
    else
      local_args=(--dut-kind "$DUT" --tag "$TAG" --tc "$TC" --seed "$SEED" --verbosity "$VERBOSITY")
      [[ "$NO_BUILD" == 1 ]] && local_args+=(--no-build)
      [[ -n "$TIMEOUT" ]] && local_args+=(--timeout "$TIMEOUT")
      [[ -n "$PLUSARGS" ]] && local_args+=(--plusargs "$PLUSARGS")
      "$or_cosim/tools/verilator_cosim.sh" run "${local_args[@]}"
    fi
    ;;

  wave)
    need_tc
    if [[ "$ENGINE" == vcs ]]; then
      # Same simv, runtime +WAVE=fsdb: no rebuild needed.
      make -C "$vcs_dir" fsdb TAG="$TAG" DUT_KIND="$DUT" \
        TC="$TC" SEED="$SEED" VERBOSITY="$VERBOSITY" $(timeout_args_vcs)
      echo "fsdb: $SIM_ROOT/vcs_$TAG/log/$DUT/$(elf_base "$TC")_$SEED/$(elf_base "$TC").fsdb"
    else
      # TRACE is a Verilator build option: build and run must both see it.
      local_args=(--dut-kind "$DUT" --tag "$TAG" --seed "$SEED" --verbosity "$VERBOSITY")
      TRACE=${TRACE:-1} "$or_cosim/tools/verilator_cosim.sh" build "${local_args[@]}"
      TRACE=${TRACE:-1} "$or_cosim/tools/verilator_cosim.sh" run --no-build "${local_args[@]}" --tc "$TC"
      ext=vcd; [[ "${TRACE:-1}" == fst ]] && ext=fst
      echo "wave: $SIM_ROOT/verilator_$TAG/log/$DUT/$(elf_base "$TC")_$SEED/$(elf_base "$TC").$ext"
    fi
    ;;

  regress)
    # Preflight: a full per-user NFS quota makes every case fail silently
    # ("Disk quota exceeded" on each echo, SUMMARY: PASS=0 FAIL=0 TOTAL=0).
    # Catching it here costs one file and saves a 10-minute batch.
    mkdir -p "$SIM_ROOT" 2>/dev/null || true
    probe=$SIM_ROOT/.write_probe.$$
    if ! ( : > "$probe" ) 2>/dev/null; then
      die "cannot write to $SIM_ROOT (disk quota exhausted? see REGRESSION_GUIDE 9.1)"
    fi
    rm -f "$probe"
    if [[ "$ENGINE" == vcs ]]; then
      exec "$vcs_dir/regress.sh" "$DUT" "$TAG" "$JOBS" ${LIST:+"$LIST"}
    fi
    # The Verilator batch runs with --no-build, so a missing executable would
    # fail all 239 cases in seconds with "no is_good=1". Build first, once.
    exe=$SIM_ROOT/verilator_$TAG/build/be_tb_top_$DUT
    if [[ ! -x "$exe" ]]; then
      echo "[or_cosim] no Verilator build for tag $TAG (dut $DUT) -> building first"
      "$or_cosim/tools/verilator_cosim.sh" build --dut-kind "$DUT" --tag "$TAG" \
        --seed "$SEED" --verbosity "$VERBOSITY" \
        ${TIMEOUT:+--timeout "$TIMEOUT"} ${PLUSARGS:+--plusargs "$PLUSARGS"} \
        || die "Verilator build failed for tag $TAG"
    fi
    exec "$or_cosim/tools/regress.sh" "$DUT" "$TAG" "$JOBS" ${LIST:+"$LIST"}
    ;;

  compare)
    a=$SIM_ROOT/verilator_$TAG/$RES_DIR/results.txt
    b=$SIM_ROOT/vcs_$TAG/$RES_DIR/results.txt
    [[ -r "$a" ]] || die "missing $a (run: regress --engine verilator --tag $TAG)"
    [[ -r "$b" ]] || die "missing $b (run: regress --engine vcs --tag $TAG)"
    echo "verilator: $(awk '{p+=$1=="PASS"; f+=$1=="FAIL"} END{printf "PASS=%d FAIL=%d",p,f}' "$a")"
    echo "vcs      : $(awk '{p+=$1=="PASS"; f+=$1=="FAIL"} END{printf "PASS=%d FAIL=%d",p,f}' "$b")"
    if diff -u "$a" "$b" >/dev/null; then
      echo "IDENTICAL: the two engines agree on all $(wc -l < "$a") cases"
      exit 0
    fi
    echo "---- diff (< verilator, > vcs) ----"
    diff -u "$a" "$b" || true
    exit 1
    ;;

  clean)
    if [[ "$ENGINE" == vcs ]]; then
      make -s --no-print-directory -C "$vcs_dir" clean TAG="$TAG" DUT_KIND="$DUT"
    else
      rm -rf "$SIM_ROOT/verilator_$TAG"
    fi
    ;;
esac
