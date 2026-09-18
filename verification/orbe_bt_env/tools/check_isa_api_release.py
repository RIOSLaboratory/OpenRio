#!/usr/bin/env python3
"""Check that an ISA model release pair matches this repository's DPI wrapper.

The DPI adapter (``dpi/isa_dpi_wrapper.cc``) is open source; the ISA model is
delivered as a binary release pair:

    <install>/include/IsaApi.h
    <install>/lib/lib_ISA_api.so

``IsaApi.h`` is hand maintained next to the model sources, so it drifts from
the library that is actually shipped.  A drifted pair fails to compile or, worse,
fails to link only at simulation start.

This tool parses the wrapper, derives the ``IsaApi.h`` declarations and
``lib_ISA_api.so`` symbols the wrapper really depends on, and verifies both
against the release pair.  Because the required set is derived from the wrapper,
the check stays correct when the wrapper grows.

Usage:
    tools/check_isa_api_release.py --inc <dir> --lib <dir>
    tools/check_isa_api_release.py --install <isa-model-install>
    tools/check_isa_api_release.py --install <isa-model-install> --smoke

Options default to the ``ISA_API_INC``/``ISA_API_LIB``/``ISA_MODEL_INSTALL``
environment variables, then to the same ``include/``-or-``src/libs`` fallback
the build files use.

With ``--smoke`` the tool also builds the DPI shared object against the release
pair and drives the model through its lifecycle DPI calls, which catches ABI
mismatches that a symbol check cannot see.  The smoke test is skipped, not
failed, when a C compiler or ``svdpi.h`` is unavailable.

Exit status: 0 when the release pair matches, 1 otherwise.
"""

from __future__ import annotations

import argparse
import ctypes
import os
import re
import shutil
import subprocess
import sys
import tempfile

ENV_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DEFAULT_MODEL_DIR = os.path.join(ENV_DIR, "dpi")
DEFAULT_WRAPPER = os.path.join(DEFAULT_MODEL_DIR, "isa_dpi_wrapper.cc")
DEFAULT_ISA_CFG = os.path.join(DEFAULT_MODEL_DIR, "rivai_0x80000000_1core_rom.yaml")

# Tokens the wrapper takes from IsaApi.h: types, struct fields, macros, plus
# the externally visible model entry points.
HEADER_TOKEN_PATTERNS = (r"IsaApi\w+", r"ISA_API_\w+")
SYMBOL_TOKEN_PATTERNS = (
    r"funcMultiCore_\w+",
    r"decoder_\w+",
    r"(?:enable|disable|set)_(?:run|commit)_log",
    r"(?:run|commit)_log_enabled",
)

# DPI utility functions a simulator provides at load time.  They are not part
# of the ISA model release pair, so the smoke test stubs them out.
SVD_PI_STUB = """\
#include <stddef.h>

int svLow(const void *handle, int dimension) { (void)handle; (void)dimension; return 0; }
int svHigh(const void *handle, int dimension) { (void)handle; (void)dimension; return 0; }
void *svGetArrayPtr(const void *handle) { (void)handle; return NULL; }
"""

PASS = 0
FAILURES: list[str] = []
SKIPS: list[str] = []


def ok(message: str) -> None:
    print(f"[OK]   {message}")


def fail(message: str) -> None:
    FAILURES.append(message)
    print(f"[FAIL] {message}")


def skip(message: str) -> None:
    SKIPS.append(message)
    print(f"[SKIP] {message}")


def info(message: str) -> None:
    print(f"[INFO] {message}")


# Printed whenever the release pair cannot be located, so that a bare
# "file not found" still says which two files the build wants and how to point
# it somewhere else.
ISA_MODEL_NOTE = """\
The ISA model release pair ships with this repository, in dpi/:

  dpi/IsaApi.h
  dpi/lib_ISA_api.so

Restore those two files, or build against a different model instead:

  export ISA_MODEL_INSTALL=<release-or-checkout>   # include/ and lib/, or
                                                   # src/libs and build/
  export ISA_API_INC=<dir> ISA_API_LIB=<dir>       # set the two directories
                                                   # independently"""


def die_usage(message: str) -> None:
    print(f"error: {message}", file=sys.stderr)
    raise SystemExit(2)


def strip_comments(text: str) -> str:
    text = re.sub(r"/\*.*?\*/", " ", text, flags=re.S)
    return re.sub(r"//[^\n]*", " ", text)


def collect_tokens(source: str, patterns) -> set[str]:
    found: set[str] = set()
    for pattern in patterns:
        found.update(re.findall(r"\b" + pattern + r"\b", source))
    return found


def exported_symbols(library: str) -> set[str]:
    result = subprocess.run(
        ["nm", "-D", "--defined-only", library],
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        raise RuntimeError(result.stderr.strip() or "nm failed")
    symbols: set[str] = set()
    for line in result.stdout.splitlines():
        fields = line.split()
        if len(fields) >= 3 and len(fields[-2]) == 1 and fields[-2].isupper():
            symbols.add(fields[-1])
    return symbols


def soname(library: str) -> str:
    for tool in (["readelf", "-d"], ["objdump", "-p"]):
        if shutil.which(tool[0]) is None:
            continue
        result = subprocess.run(tool + [library], capture_output=True, text=True)
        if result.returncode != 0:
            continue
        match = re.search(r"SONAME.*?\[([^\]]+)\]", result.stdout)
        if match:
            return match.group(1)
    return ""


def resolve_paths(args) -> tuple[str, str, str]:
    install = args.install or os.environ.get("ISA_MODEL_INSTALL") or os.environ.get("ISA_MODEL_ROOT") or ""
    include = args.inc or os.environ.get("ISA_API_INC") or ""
    library = args.lib or os.environ.get("ISA_API_LIB") or ""

    if install and not include:
        candidate = os.path.join(install, "include")
        include = candidate if os.path.isfile(os.path.join(candidate, "IsaApi.h")) else os.path.join(install, "src", "libs")
    if install and not library:
        candidate = os.path.join(install, "lib")
        library = candidate if os.path.isfile(os.path.join(candidate, "lib_ISA_api.so")) else os.path.join(install, "build")

    # Nothing configured: check the release pair that ships in dpi/ next to the
    # wrapper, so a bare run validates the copy in this checkout.
    if not include:
        include = DEFAULT_MODEL_DIR
    if not library:
        library = DEFAULT_MODEL_DIR

    return install, include, library


def locate_svdpi_include() -> str | None:
    vcs_home = os.environ.get("VCS_HOME")
    if vcs_home and os.path.isfile(os.path.join(vcs_home, "include", "svdpi.h")):
        return os.path.join(vcs_home, "include")

    verilator = shutil.which("verilator")
    if verilator:
        result = subprocess.run([verilator, "--getenv", "VERILATOR_ROOT"], capture_output=True, text=True)
        root = result.stdout.strip()
        for candidate in (os.path.join(root, "include", "vltstd"), os.path.join(root, "include")):
            if os.path.isfile(os.path.join(candidate, "svdpi.h")):
                return candidate
    return None


def check_header(header: str, source: str) -> set[str]:
    if not os.path.isfile(header):
        fail(f"IsaApi.h is not readable: {header}")
        return set()
    ok(f"IsaApi.h present ({os.path.getsize(header)} bytes): {header}")

    with open(header, encoding="utf-8", errors="replace") as handle:
        header_text = strip_comments(handle.read())

    required = collect_tokens(source, HEADER_TOKEN_PATTERNS)
    missing = sorted(token for token in required if not re.search(r"\b" + re.escape(token) + r"\b", header_text))
    if missing:
        fail(f"IsaApi.h is missing {len(missing)} declaration(s) used by the wrapper: {', '.join(missing)}")
    else:
        ok(f"wrapper declarations satisfied by IsaApi.h: {len(required)}/{len(required)}")
    return required


def check_library(library: str, source: str) -> None:
    if not os.path.isfile(library):
        fail(f"lib_ISA_api.so is not readable: {library}")
        return
    ok(f"lib_ISA_api.so present ({os.path.getsize(library)} bytes): {library}")

    actual_soname = soname(library)
    if actual_soname == "lib_ISA_api.so":
        ok("library soname is lib_ISA_api.so")
    elif actual_soname:
        fail(f"library soname is '{actual_soname}', expected 'lib_ISA_api.so'")
    else:
        skip("could not read the library soname (readelf/objdump unavailable)")

    try:
        exported = exported_symbols(library)
    except RuntimeError as error:
        skip(f"symbol check unavailable: {error}")
        return

    required = collect_tokens(source, SYMBOL_TOKEN_PATTERNS)
    missing = sorted(token for token in required if token not in exported)
    if missing:
        fail(f"lib_ISA_api.so does not export {len(missing)} symbol(s) used by the wrapper: {', '.join(missing)}")
    else:
        ok(f"wrapper symbols exported by lib_ISA_api.so: {len(required)}/{len(required)}")


def build_dpi_library(workspace: str, wrapper: str, include: str, library_dir: str) -> str | None:
    compiler = os.environ.get("CXX") or shutil.which("c++") or shutil.which("g++")
    if compiler is None:
        skip("smoke test needs a C++ compiler (CXX, c++, or g++ not found)")
        return None

    svdpi = locate_svdpi_include()
    if svdpi is None:
        skip("smoke test needs svdpi.h; set VCS_HOME or install Verilator")
        return None

    output = os.path.join(workspace, "libisa_dpi.so")
    command = [
        compiler, "-std=c++17", "-O2", "-fPIC", "-shared",
        "-I", include, "-I", svdpi,
        wrapper, "-L", library_dir, "-l_ISA_api",
        "-o", output,
    ]
    result = subprocess.run(command, capture_output=True, text=True)
    if result.returncode != 0:
        fail("smoke test could not build the DPI wrapper against the release pair")
        print(result.stderr.strip(), file=sys.stderr)
        return None
    ok("smoke test built libisa_dpi.so against the release pair")
    return output


def check_smoke(args, workspace: str, include: str, library_dir: str) -> None:
    dpi_library = build_dpi_library(workspace, args.wrapper, include, library_dir)
    if dpi_library is None:
        return

    model_library = os.path.join(library_dir, "lib_ISA_api.so")
    config = args.isa_cfg
    if not os.path.isfile(config):
        skip(f"smoke test needs an ISA platform config to load: {config}")
        return

    # The simulator would provide svLow/svHigh/svGetArrayPtr.  Load a local
    # stub globally first, then the model, so the DPI object resolves both.
    stub_source = os.path.join(workspace, "svdpi_stub.c")
    stub_library = os.path.join(workspace, "svdpi_stub.so")
    compiler = os.environ.get("CC") or shutil.which("cc") or shutil.which("gcc")
    with open(stub_source, "w", encoding="utf-8") as handle:
        handle.write(SVD_PI_STUB)
    result = subprocess.run(
        [compiler, "-shared", "-fPIC", "-o", stub_library, stub_source],
        capture_output=True, text=True,
    )
    if result.returncode != 0:
        skip(f"smoke test could not build the DPI stub: {result.stderr.strip()}")
        return

    try:
        ctypes.CDLL(stub_library, mode=ctypes.RTLD_GLOBAL)
        ctypes.CDLL(model_library, mode=ctypes.RTLD_GLOBAL)
        dpi = ctypes.CDLL(dpi_library, mode=os.RTLD_NOW | os.RTLD_LOCAL)
    except OSError as error:
        fail(f"smoke test could not load libisa_dpi.so: {error}")
        return
    ok("smoke test loaded libisa_dpi.so with every symbol resolved")

    dpi.isa_dpi_create.argtypes = [ctypes.c_uint64, ctypes.c_uint64]
    dpi.isa_dpi_create.restype = ctypes.c_int
    dpi.isa_dpi_load_config.argtypes = [ctypes.c_char_p]
    dpi.isa_dpi_load_config.restype = ctypes.c_int
    dpi.isa_dpi_finalize_config.restype = ctypes.c_int
    dpi.isa_dpi_core_count.restype = ctypes.c_uint64
    dpi.isa_dpi_is_config_ready.restype = ctypes.c_ubyte
    dpi.isa_dpi_get_spec_pc.argtypes = [ctypes.c_uint32]
    dpi.isa_dpi_get_spec_pc.restype = ctypes.c_uint64
    dpi.isa_dpi_destroy.restype = None

    steps = [
        ("isa_dpi_create(1, 64)", lambda: dpi.isa_dpi_create(1, 64)),
        ("isa_dpi_load_config()", lambda: dpi.isa_dpi_load_config(config.encode())),
        ("isa_dpi_finalize_config()", lambda: dpi.isa_dpi_finalize_config()),
    ]
    failed = False
    for label, call in steps:
        code = call()
        if code == PASS:
            info(f"smoke test {label} -> PASS")
        else:
            fail(f"smoke test {label} -> {code}")
            failed = True
    if failed:
        dpi.isa_dpi_destroy()
        return

    info(f"smoke test isa_dpi_core_count() -> {dpi.isa_dpi_core_count()}")
    info(f"smoke test isa_dpi_is_config_ready() -> {dpi.isa_dpi_is_config_ready()}")
    info(f"smoke test isa_dpi_get_spec_pc(0) -> {hex(dpi.isa_dpi_get_spec_pc(0))}")
    dpi.isa_dpi_destroy()
    ok("smoke test drove the model through its lifecycle")


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Check that an ISA model release pair matches the DPI wrapper.",
    )
    parser.add_argument("--install", help="ISA model install root (ISA_MODEL_INSTALL)")
    parser.add_argument("--inc", help="directory holding IsaApi.h (ISA_API_INC)")
    parser.add_argument("--lib", help="directory holding lib_ISA_api.so (ISA_API_LIB)")
    parser.add_argument("--wrapper", default=DEFAULT_WRAPPER, help="DPI C++ wrapper to derive the requirement from")
    parser.add_argument("--isa-cfg", default=DEFAULT_ISA_CFG, help="platform YAML used by --smoke")
    parser.add_argument("--smoke", action="store_true", help="also build the DPI object and drive the model")
    args = parser.parse_args()

    install, include, library_dir = resolve_paths(args)
    header = os.path.join(include, "IsaApi.h")
    library = os.path.join(library_dir, "lib_ISA_api.so")

    print(f"[INFO] install root = {install or '<unset, using --inc/--lib>'}")
    print(f"[INFO] header       = {header}")
    print(f"[INFO] library      = {library}")
    print(f"[INFO] wrapper      = {args.wrapper}")

    if not os.path.isfile(args.wrapper):
        die_usage(f"DPI wrapper is not readable: {args.wrapper}")
    with open(args.wrapper, encoding="utf-8", errors="replace") as handle:
        source = strip_comments(handle.read())

    check_header(header, source)
    check_library(library, source)

    if args.smoke and not FAILURES:
        with tempfile.TemporaryDirectory(prefix="isa_api_smoke_") as workspace:
            check_smoke(args, workspace, include, library_dir)
    elif args.smoke:
        skip("smoke test not attempted because the static checks failed")

    print()
    for message in SKIPS:
        print(f"[SKIP] {message}")
    if FAILURES:
        print(f"FAIL: {len(FAILURES)} problem(s) between the ISA model release pair and the DPI wrapper")
        for message in FAILURES:
            print(f"  - {message}")
        if any("is not readable" in message for message in FAILURES):
            print()
            print(ISA_MODEL_NOTE)
        return 1

    print("PASS: the ISA model release pair matches the DPI wrapper")
    return 0


if __name__ == "__main__":
    sys.exit(main())
