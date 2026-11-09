#!/usr/bin/env bash
# Pack the COSIM verification environment + RTL **sources** into one tarball.
#
#   tools/pack_verif_src.sh [options]
#
# Options:
#   --out DIR          Where to write the tarball. Default: current directory.
#   --tag NAME         Suffix in the archive name. Default: <YYYYmmdd-HHMM>.
#   --with-perf-eval   Also include verification/or_cosim/perf_eval (default: no).
#   --with-embench DIR Also include the Embench orbe-baremetal ELFs found in DIR
#                      (default: no). They land under testcases/embench/ with a
#                      SHA256SUMS file and a short run README.
#   --no-docs          Skip verification/or_cosim/docs (default: include).
#   --no-sha           Skip writing the .sha256 sidecar.
#   -h, --help         Show this help.
#
# What is packed (relative layout is preserved so cfg/filelist/*.f keeps working):
#   verification/or_cosim/            (minus sim/, build/log junk, editor/Verdi junk)
#   src/core/be_rtl_v1/
#   src/core/fe_rtl_v1/
#   src/core/cache_rtl_v1/
#
# The archive also contains:
#   MANIFEST.txt     file list with sizes
#   README_PACKAGE.md  how to unpack and build
#
# Examples:
#   tools/pack_verif_src.sh
#   tools/pack_verif_src.sh --out ~ --tag v1 --with-perf-eval
set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
or_cosim=$(cd "$script_dir/.." && pwd)
repo_root=$(cd "$or_cosim/../.." && pwd)

OUT_DIR=$PWD
TAG=$(date +%Y%m%d-%H%M)
WITH_PERF_EVAL=0
WITH_DOCS=1
WITH_EMBENCH=0
EMBENCH_DIR=
WRITE_SHA=1

die() { echo "error: $*" >&2; exit 1; }

while (($#)); do
  case "$1" in
    --out)            OUT_DIR=$2; shift 2 ;;
    --out=*)          OUT_DIR=${1#*=}; shift ;;
    --tag)            TAG=$2; shift 2 ;;
    --tag=*)          TAG=${1#*=}; shift ;;
    --with-perf-eval) WITH_PERF_EVAL=1; shift ;;
    --with-embench)   [[ $# -ge 2 ]] || die "--with-embench requires a directory"
                      EMBENCH_DIR=$2; WITH_EMBENCH=1; shift 2 ;;
    --with-embench=*) EMBENCH_DIR=${1#*=}; WITH_EMBENCH=1; shift ;;
    --no-docs)        WITH_DOCS=0; shift ;;
    --no-sha)         WRITE_SHA=0; shift ;;
    -h|--help)        awk 'NR>1 && /^#/ {sub(/^# ?/,""); print; next} NR>1 {exit}' \
                        "${BASH_SOURCE[0]}"; exit 0 ;;
    *) die "unknown option: $1 (try --help)" ;;
  esac
done

[[ -d "$or_cosim" ]] || die "verification environment not found: $or_cosim"
for d in be_rtl_v1 fe_rtl_v1 cache_rtl_v1; do
  [[ -d "$repo_root/src/core/$d" ]] || die "RTL directory not found: $repo_root/src/core/$d"
done
embench_files=()
if [[ $WITH_EMBENCH -eq 1 ]]; then
  [[ -d "$EMBENCH_DIR" ]] || die "embench directory not found: $EMBENCH_DIR"
  mapfile -t embench_files < <(find "$EMBENCH_DIR" -maxdepth 1 -type f -printf '%f\n' | sort)
  [[ ${#embench_files[@]} -gt 0 ]] || die "no regular files in embench directory: $EMBENCH_DIR"
fi
mkdir -p "$OUT_DIR" || die "cannot create output dir: $OUT_DIR"

TOP="hardware-openrio-verif-src-$TAG"
OUT="$OUT_DIR/$TOP.tar.gz"
STAGE=$(mktemp -d "$HOME/.pack_verif.XXXXXX") || die "cannot create staging dir under \$HOME"
trap 'rm -rf "$STAGE"' EXIT
mkdir -p "$STAGE/$TOP"

# Common excludes: build products, logs, waveforms, caches, Verdi/vcd2fsdb droppings.
EXCLUDES=(
  --exclude='verification/or_cosim/sim'
  --exclude='verification/or_cosim/verdiLog'
  --exclude='verification/or_cosim/vcd2fsdbLog'
  --exclude='verification/or_cosim/novas.rc'
  --exclude='verification/or_cosim/novas.conf'
  --exclude='*.pyc'
  --exclude='__pycache__'
  --exclude='*.vcd'
  --exclude='*.fst'
  --exclude='*.fsdb'
  --exclude='*.log'
  --exclude='*.swp'
  --exclude='*~'
)
[[ $WITH_PERF_EVAL -eq 1 ]] || EXCLUDES+=(--exclude='verification/or_cosim/perf_eval')
[[ $WITH_DOCS      -eq 1 ]] || EXCLUDES+=(--exclude='verification/or_cosim/docs')

echo "[pack] repo root : $repo_root"
echo "[pack] include   : verification/or_cosim + verification/REGRESSION_GUIDE.md + src/core/{be,fe,cache}_rtl_v1"
echo "[pack] perf_eval : $([[ $WITH_PERF_EVAL -eq 1 ]] && echo included || echo excluded)"
echo "[pack] docs      : $([[ $WITH_DOCS      -eq 1 ]] && echo included || echo excluded)"
echo "[pack] embench   : $([[ $WITH_EMBENCH   -eq 1 ]] && echo "$EMBENCH_DIR (${#embench_files[@]} files)" || echo excluded)"

tar -C "$repo_root" -cf - "${EXCLUDES[@]}" \
    verification/or_cosim \
    verification/REGRESSION_GUIDE.md \
    verification/README.md \
    verification/images \
    src/core/be_rtl_v1 \
    src/core/fe_rtl_v1 \
    src/core/cache_rtl_v1 \
  | tar -C "$STAGE/$TOP" -xf -

if [[ $WITH_EMBENCH -eq 1 ]]; then
  embench_dst="$STAGE/$TOP/testcases/embench/orbe-baremetal"
  mkdir -p "$embench_dst"
  find "$EMBENCH_DIR" -maxdepth 1 -type f -exec cp -p {} "$embench_dst/" \;
  ( cd "$embench_dst" && sha256sum * > ../SHA256SUMS )
  cat > "$STAGE/$TOP/testcases/embench/README_EMBENCH.md" <<'EOF'
# Embench-IoT binaries (orbe-baremetal)

Built for the ORBE bare-metal runtime (rv64imafdc, entry 0x80000000,
`.tohost` at 0x80001000). Each benchmark calls `verify_benchmark()`; the
process exit code carries the result and the HTIF device maps a nonzero
payload to `is_good=0`, so no external golden result is needed.

## Run

```bash
cd verification/or_cosim
export CASE_ROOT=<unpacked>/testcases/embench/orbe-baremetal
export SIM_TIMEOUT=20000000      # per-iteration 0.8M-4.0M; the ELF runs a warm loop (~2x)
export ISA_LOG=none              # keep the per-instruction logs off (GBs otherwise)
export COSIM_OB_LOG=0            # keep the per-commit sim.log lines off
tools/regress.sh rtl_full <tag> 8 cfg/cases/cases_embench.list
```

`CASE_ROOT` turns the bare names in `cfg/cases/cases_embench.list` into ELF
paths. Each ELF runs the benchmark twice (warm loop), so expect roughly 2x the
published instruction count. On `rtl_full` the full 19-benchmark set takes hours;
start with a single case (`ud`, `wikisort`) for a smoke run.
EOF
fi

# Manifest: relative path + size, sorted.
( cd "$STAGE/$TOP" && find . -type f -printf '%10s  %p\n' | sort -k2 > MANIFEST.txt )

cat > "$STAGE/$TOP/README_PACKAGE.md" <<EOF
# OpenRio verification sources ($TAG)

Packed by \`tools/pack_verif_src.sh\` on $(date '+%Y-%m-%d %H:%M:%S %Z').

## Contents

\`\`\`text
verification/or_cosim/          COSIM environment (tb, cfg, dpi, tools, docs)
verification/REGRESSION_GUIDE.md  end-to-end regression runbook
verification/images/            screenshots referenced by the guide
src/core/be_rtl_v1/             backend RTL
src/core/fe_rtl_v1/             frontend RTL
src/core/cache_rtl_v1/          cache RTL
$( [[ $WITH_EMBENCH -eq 1 ]] && printf '%s\n' 'testcases/embench/              Embench orbe-baremetal ELFs + SHA256SUMS' )
\`\`\`

Excluded: \`sim/\` (build products and logs), Verdi/vcd2fsdb output, \`*.vcd/fst/fsdb\`,
\`*.log\`, \`__pycache__\`$( [[ $WITH_PERF_EVAL -eq 1 ]] || echo ', `perf_eval/`' ).

## Unpack

\`\`\`bash
tar xzf ${TOP}.tar.gz
cd ${TOP}
\`\`\`

The relative layout is preserved, so \`verification/or_cosim/cfg/filelist/*.f\`
resolves \`../../src/core/...\` without changes.

## Regression guide

Start with \`verification/REGRESSION_GUIDE.md\`; it covers case staging, Verilator
5.050 requirements, the 239 ISA baseline, Embench, failure triage, and the
\`REQUIRE_ISA_MODEL\` / \`CHECK_ISA_GLIBC\` guards.

## Build (one DUT kind)

\`\`\`bash
cd verification/or_cosim
export ISA_MODEL_ROOT=<ISA model checkout with src/libs + build + isa_case>
tools/verilator_cosim.sh build --dut-kind rtl_full --tag first
tools/verilator_cosim.sh run --no-build --dut-kind rtl_full --tag first \\
  --tc \$ISA_MODEL_ROOT/isa_case/rv64ui/rv64ui-p-add.riscv
\`\`\`

Requires Verilator >= 5.0 (the flow uses \`--timing\`).

## Not included

- ISA model (separate confidential repository)
- Test cases (\`isa_case\`) and any prebuilt \`.so\`
- Embench ELFs unless \`--with-embench\` was used (then see \`testcases/embench/\`)
- Build products under \`verification/or_cosim/sim/\`
EOF

echo "[pack] staging done, $(find "$STAGE/$TOP" -type f | wc -l) files"

( cd "$STAGE" && tar -czf "$OUT" "$TOP" )
size=$(ls -lh "$OUT" | awk '{print $5}')
echo "[pack] wrote: $OUT  ($size)"

if [[ $WRITE_SHA -eq 1 ]]; then
  ( cd "$OUT_DIR" && sha256sum "$(basename "$OUT")" > "$(basename "$OUT").sha256" )
  echo "[pack] sha256: $(cat "$OUT.sha256")"
fi

echo "[pack] top-level dirs inside:"
tar tzf "$OUT" | awk -F/ 'NF>=4 && !seen[$2"/"$3"/"$4]++ {print "       "$2"/"$3"/"$4}'
