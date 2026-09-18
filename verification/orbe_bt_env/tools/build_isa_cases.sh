#!/usr/bin/env bash
#
# Build the riscv-tests ISA cases used by the ORBE regression set.
#
# riscv-tests ships assembly sources only, so the .riscv ELF images that the
# DPI-driven verification environment consumes have to be cross compiled. This
# script pins the build to the revision recorded by the third_party/riscv-tests
# submodule and renames the build products to the <name>.riscv convention the
# environment expects.
#
# The submodule is pinned to the revision whose test composition matches the
# historical 216 case regression set (rv64ui 104, rv64um 26, rv64ua 38,
# rv64uf 22, rv64ud 24, rv64uc 2). Its nested env submodule supplies the linker
# script and the machine/supervisor mode runtime.
#
set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
orbe_bt_env=$(cd "$script_dir/.." && pwd)
repo_root=$(cd "$orbe_bt_env/../.." && pwd)

RISCV_TESTS_DIR=${RISCV_TESTS_DIR:-$repo_root/third_party/riscv-tests}
ISA_CASE_OUT=${ISA_CASE_OUT:-$repo_root/isa_case}
RISCV_PREFIX=${RISCV_PREFIX:-riscv64-unknown-elf-}
RISCV_GCC=${RISCV_GCC:-${RISCV_PREFIX}gcc}
JOBS=${JOBS:-$(nproc 2>/dev/null || echo 4)}

# The 216 case regression set and its expected per-category ELF counts.
# Each test is built twice, in machine mode (-p-) and supervisor mode (-v-).
default_categories="rv64ui rv64um rv64ua rv64uf rv64ud rv64uc"
declare -A expected=(
  [rv64ui]=104 [rv64um]=26 [rv64ua]=38
  [rv64uf]=22 [rv64ud]=24 [rv64uc]=2
)

categories=$default_categories
list_only=0

usage() {
  cat <<USAGE
Usage:
  tools/build_isa_cases.sh [options]

Options:
  --out DIR              Where to write <category>/<name>.riscv. Default: $ISA_CASE_OUT
  --categories "a b c"   Test categories to build. Default: $default_categories
  --jobs N               Parallel make jobs. Default: $JOBS
  --list                 Print the build plan and exit without building.
  -h, --help             Show this help.

Environment overrides:
  RISCV_TESTS_DIR   riscv-tests checkout or submodule. Default: $RISCV_TESTS_DIR
  ISA_CASE_OUT      Same as --out.
  RISCV_GCC         Cross compiler. Default: ${RISCV_PREFIX}gcc
  RISCV_PREFIX      Toolchain prefix used when RISCV_GCC is unset.
  JOBS              Parallel make jobs.

Requirements:
  A bare metal RISC-V toolchain providing \${RISCV_PREFIX}gcc. Build riscv-tests
  with a GCC close to the one the baseline was produced with: the -p- tests are
  pure assembly and reproduce byte for byte, while the -v- tests compile the
  env/v runtime from C and are sensitive to the compiler version.
USAGE
}

die() {
  echo "error: $*" >&2
  exit 1
}

while (($#)); do
  case "$1" in
    --out)
      [[ $# -ge 2 ]] || die "--out requires a directory"
      ISA_CASE_OUT=$2
      shift 2
      ;;
    --out=*)
      ISA_CASE_OUT=${1#*=}
      shift
      ;;
    --categories)
      [[ $# -ge 2 ]] || die "--categories requires a list"
      categories=$2
      shift 2
      ;;
    --categories=*)
      categories=${1#*=}
      shift
      ;;
    --jobs)
      [[ $# -ge 2 ]] || die "--jobs requires a count"
      JOBS=$2
      shift 2
      ;;
    --jobs=*)
      JOBS=${1#*=}
      shift
      ;;
    --list)
      list_only=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "unknown argument: $1 (try --help)"
      ;;
  esac
done

check_riscv_tests() {
  [[ -d "$RISCV_TESTS_DIR/isa" ]] || die "riscv-tests is missing at $RISCV_TESTS_DIR
clone it with: git submodule update --init --recursive"
  [[ -n "$(ls -A "$RISCV_TESTS_DIR/env" 2>/dev/null)" ]] || die "the riscv-tests env submodule is not initialized at $RISCV_TESTS_DIR/env
run: git submodule update --init --recursive"
  [[ -r "$RISCV_TESTS_DIR/env/p/link.ld" ]] || die "missing $RISCV_TESTS_DIR/env/p/link.ld"
}

check_toolchain() {
  command -v "$RISCV_GCC" >/dev/null 2>&1 || die "cross compiler not found: $RISCV_GCC
install a bare metal RISC-V toolchain, or set RISCV_GCC/RISCV_PREFIX"

  # riscv-tests also runs $(RISCV_PREFIX)objdump and $(RISCV_PREFIX)objcopy by
  # bare name, so the toolchain directory has to be on PATH even when
  # RISCV_GCC is given as an absolute path.
  local gcc_path toolchain_bin
  gcc_path=$(command -v "$RISCV_GCC")
  toolchain_bin=$(cd "$(dirname "$gcc_path")" && pwd)
  case ":$PATH:" in
    *":$toolchain_bin:"*) ;;
    *) PATH="$toolchain_bin:$PATH"; export PATH ;;
  esac

  command -v "${RISCV_PREFIX}objdump" >/dev/null 2>&1 || \
    die "${RISCV_PREFIX}objdump is not available; the toolchain must provide objdump and objcopy"
}

report_revision() {
  if git -C "$RISCV_TESTS_DIR" rev-parse --git-dir >/dev/null 2>&1; then
    echo "[ISA_CASES] riscv-tests revision: $(git -C "$RISCV_TESTS_DIR" rev-parse HEAD)"
    if git -C "$RISCV_TESTS_DIR/env" rev-parse --git-dir >/dev/null 2>&1; then
      echo "[ISA_CASES] riscv-test-env revision: $(git -C "$RISCV_TESTS_DIR/env" rev-parse HEAD)"
    fi
  fi
  echo "[ISA_CASES] compiler: $RISCV_GCC ($("$RISCV_GCC" -dumpversion 2>/dev/null || echo unknown))"
}

print_plan() {
  echo "[ISA_CASES] riscv-tests: $RISCV_TESTS_DIR"
  echo "[ISA_CASES] output:      $ISA_CASE_OUT"
  echo "[ISA_CASES] categories:  $categories"
  echo "[ISA_CASES] jobs:        $JOBS"
  report_revision
}

build_categories() {
  # riscv-tests builds one shared directory, so every category target has to be
  # requested in a single make invocation.
  ( cd "$RISCV_TESTS_DIR/isa" && \
    make -j "$JOBS" $categories XLEN=64 RISCV_GCC="$RISCV_GCC" )
}

collect_elfs() {
  local category built=0
  for category in $categories; do
    local src_dir="$RISCV_TESTS_DIR/isa"
    local dst_dir="$ISA_CASE_OUT/$category"
    mkdir -p "$dst_dir"
    # Drop previously generated cases so the reported counts are deterministic.
    rm -f "$dst_dir"/*.riscv
    # make also emits .bin and .dump next to each ELF; only the ELF is a case.
    while IFS= read -r elf; do
      cp -f "$elf" "$dst_dir/$(basename "$elf").riscv"
      built=$((built + 1))
    done < <(find "$src_dir" -maxdepth 1 -type f -name "$category-[pv]-*" \
               ! -name '*.bin' ! -name '*.dump' ! -name '*.out' | sort)
  done
  echo "$built"
}

verify_counts() {
  local category actual expected_count status=0
  echo
  echo "[ISA_CASES] generated case counts"
  for category in $categories; do
    actual=$(find "$ISA_CASE_OUT/$category" -maxdepth 1 -name '*.riscv' 2>/dev/null | wc -l)
    expected_count=${expected[$category]:-}
    if [[ -z "$expected_count" ]]; then
      printf '  %-10s %4d\n' "$category" "$actual"
      continue
    fi
    if [[ "$actual" == "$expected_count" ]]; then
      printf '  %-10s %4d  (expected %s)\n' "$category" "$actual" "$expected_count"
    else
      printf '  %-10s %4d  (expected %s)  <- mismatch\n' "$category" "$actual" "$expected_count"
      status=1
    fi
  done
  return "$status"
}

main() {
  check_riscv_tests
  print_plan

  if ((list_only)); then
    return 0
  fi

  check_toolchain
  echo
  build_categories

  echo
  local built
  built=$(collect_elfs)
  echo "[ISA_CASES] copied $built ELF images to $ISA_CASE_OUT"

  verify_counts || {
    echo
    echo "error: generated case counts do not match the regression set" >&2
    exit 1
  }

  cat <<EOF

[ISA_CASES] done.
Point the environment at this directory. The regression flow reads $ISA_CASE_OUT;
if the ISA model layout still expects the cases under its own tree, symlink them:

  ln -s "$ISA_CASE_OUT" <isa_model_root>/isa_case

Note: the open source riscv-tests set covers rv64ui/um/ua/uf/ud/uc, rv64mi,
rv64si, rv64uzba/uzbb/uzbc/uzbs/uzfh, rv64mzicbo and rv64ssvnapot. The rv64model
cases are project-private and are not produced by this script.
EOF
}

main "$@"
