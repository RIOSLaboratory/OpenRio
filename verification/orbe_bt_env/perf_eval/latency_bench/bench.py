#!/usr/bin/env python3
"""fu_latency_bench -- measure the BE-visible latency L of every register-result
producer family, from the RTL, on rtl_full.

L is defined as a拍差 (cycle difference):
    L = (cycle the result/bypass becomes visible to BE on its lane)
      - (cycle the issue is ACCEPTED: isq issue_valid && FU_ready)

Sources on the observation surface (see tb/interfaces/ob_cosim_if.sv):
  [ISQ_FIRE]   cycle, group, tag  -- G0/G1/G2 accept (issue_valid && FU_ready)
  [LSU_ISSUE]  cycle, tag         -- G3 accept into the LSU
  [FU_WB]      cycle, lane, tag   -- lane writeback / P3 bypass presentation
The producer is identified by the PRODUCER symbol in the ELF (pc), joined to
its ROB tag through the [BE][COSIM_OB] commit line.

Generated .S/.elf and logs live OUTSIDE the repo (WORK), matching METHOD 3.
"""

import argparse
import concurrent.futures as cf
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path

REPO = Path("/work/home/danielle/workspace/suncheek/model/OpenRio")
ENV = REPO / "verification/orbe_bt_env"
WORK = Path("/work/home/danielle/workspace/suncheek/model/perf_eval_work/latency")
LINK = ENV / "perf_eval/templates/link.ld"
COSIM = ENV / "tools/verilator_cosim.sh"
TAG = "fu_latency"
DUT = "rtl_full"
GCC = "/work/stu/yzhang/workspace/riscv/bin/riscv64-unknown-elf-gcc"
OBJDUMP = "/work/stu/yzhang/workspace/riscv/bin/riscv64-unknown-elf-objdump"
NM = "/work/stu/yzhang/workspace/riscv/bin/riscv64-unknown-elf-nm"
ISA_MODEL_ROOT = "/work/home/danielle/workspace/act-cosim/isa-root"
ISA_CFG = "/work/home/danielle/workspace/act-cosim/cfg/act_suncheek_0x80000000.yaml"

SET_INT = """    addi x1, zero, 5
    addi x2, zero, 7
    addi x3, zero, 3
    addi x4, zero, 4"""

# Warm one cache line, then make the MEASURED access's address depend on the
# warm-up result (wdata is all-zero, so `add x2, x2, x6` keeps the base). A real
# dependency is required: an independent measured load would issue before the
# fill completes and merge with the miss (excluded path), inflating L.
SET_MEM = SET_INT + """
    la   x2, wdata
    ld   x6, 0(x2)
    add  x2, x2, x6"""

# Every FP instruction is illegal unless mstatus.FS != Off; the DUT computes
# fp_illegal = is_fp_instruction & (!fs_enabled | rm_illegal), so set FS=Dirty.
SET_FS = """    li   x5, 0x6000
    csrs mstatus, x5"""

SET_F32 = SET_FS + """
    li   x1, 0x3f800000
    li   x2, 0x40000000
    fmv.w.x f1, x1
    fmv.w.x f2, x2"""

SET_F64 = SET_FS + """
    li   x1, 0x3ff0000000000000
    li   x2, 0x4000000000000000
    fmv.d.x f1, x1
    fmv.d.x f2, x2"""


def C(cid, family, march, setup, body, note="", post="", raw=False):
    # verilator_cosim.sh takes the log dir name from ${elf_base%%.*}, i.e. it cuts
    # at the FIRST dot. A case id with a dot (amoadd.w) would collapse to the same
    # log dir as amoadd.d and overwrite it. Keep ids dot-free.
    return dict(id=cid.replace(".", "_"), family=family, march=march,
                setup=setup, body=body, note=note, post=post, raw=raw)


CASES = []

# ---- core INT families -----------------------------------------------------
for op in ["add", "sub", "and", "or", "xor", "sll", "srl", "sra", "slt", "sltu"]:
    CASES.append(C(f"ALU_{op}", "ALU", "rv64imafdc", SET_INT, f"    {op} x5, x1, x2"))
CASES.append(C("ALU_addi", "ALU", "rv64imafdc", SET_INT, "    addi x5, x1, 3"))
CASES.append(C("ALU_auipc", "ALU", "rv64imafdc", SET_INT, "    auipc x5, 0", "AUIPC is G0-only"))
CASES.append(C("ALU_lui", "ALU", "rv64imafdc", SET_INT, "    lui x5, 1"))
# Force the ALU op into G1 (u_alu1) instead of G0: put a G0-only AUIPC immediately
# before it, so slot0 takes G0 and the producer is dispatched to G1 (lane 1).
CASES.append(C("ALU_add_G1", "ALU", "rv64imafdc",
               SET_INT + "\n    la   x29, tohost\n    addi x28, zero, 1\n    addi x7, zero, 0\n    auipc x6, 0",
               "    add x5, x1, x2",
               note="G1-forced ALU op (lane 1): AUIPC shares an 8B-aligned bundle with the add",
               post="    sd   x28, 0(x29)\n1:  j    1b", raw=True))

for op in ["mul", "mulh", "mulhsu", "mulhu", "mulw"]:
    CASES.append(C(f"MUL_{op}", "MUL", "rv64imafdc", SET_INT, f"    {op} x5, x1, x2"))

for op in ["div", "divu", "rem", "remu", "divw", "divuw", "remw", "remuw"]:
    CASES.append(C(f"DIV_{op}", "DIV", "rv64imafdc", SET_INT, f"    {op} x5, x1, x2"))

for op in ["ld", "lw", "lh", "lb", "lwu", "lhu", "lbu"]:
    CASES.append(C(f"LOAD_{op}", "LOAD", "rv64imafdc", SET_MEM, f"    {op} x5, 0(x2)"))
CASES.append(C("LOAD_flw", "LOAD", "rv64imafdc", SET_FS + "\n" + SET_MEM, "    flw f5, 0(x2)", "FP load, rd_is_fp"))
CASES.append(C("LOAD_fld", "LOAD", "rv64imafdc", SET_FS + "\n" + SET_MEM, "    fld f5, 0(x2)", "FP load, rd_is_fp"))

CASES.append(C("JALR_link", "JALR", "rv64imafdc",
               "    la   x10, jalr_target",
               "    jalr x5, 0(x10)\njalr_target:\n    addi x0, x0, 0",
               "link-value writeback only. NOTE: this still redirects (mispredict=1), "
               "so it is NOT a redirect-free case -- it measures the rd writeback"))
CASES.append(C("JAL_link", "JALR", "rv64imafdc",
               "",
               "    jal  x5, jal_target\njal_target:\n    addi x0, x0, 0",
               "fallthrough target, link value only"))
# Real taken JALR: target != fallthrough. Measures the link-value writeback (L)
# AND, separately, the redirect-inclusive effect (issue -> redirect target issued).
CASES.append(C("JALR_taken", "JALR", "rv64imafdc",
               SET_INT + "\n    la   x29, tohost\n    addi x28, zero, 1\n    la   x10, jalr_target",
               "    jalr x5, 0(x10)\n    addi x11, zero, 1\n    addi x12, zero, 2\n"
               "jalr_target:\n    sd   x28, 0(x29)\n1:  j    1b",
               note="real taken JALR (target != fallthrough)",
               raw=True))

# ---- FP arithmetic: G2, FP destination -------------------------------------
for op, su in [("fadd.s", SET_F32), ("fsub.s", SET_F32), ("fmul.s", SET_F32),
               ("fdiv.s", SET_F32), ("fmin.s", SET_F32), ("fmax.s", SET_F32),
               ("fsgnj.s", SET_F32), ("fsgnjn.s", SET_F32), ("fsgnjx.s", SET_F32)]:
    CASES.append(C(f"FP_{op}", "FP_ARITH", "rv64imafdc", su, f"    {op} f3, f1, f2"))
for op, su in [("fadd.d", SET_F64), ("fsub.d", SET_F64), ("fmul.d", SET_F64),
               ("fdiv.d", SET_F64), ("fmin.d", SET_F64), ("fmax.d", SET_F64),
               ("fsgnj.d", SET_F64)]:
    CASES.append(C(f"FP_{op}", "FP_ARITH", "rv64imafdc", su, f"    {op} f3, f1, f2"))
CASES.append(C("FP_fsqrt.s", "FP_ARITH", "rv64imafdc", SET_F32, "    fsqrt.s f3, f1"))
CASES.append(C("FP_fsqrt.d", "FP_ARITH", "rv64imafdc", SET_F64, "    fsqrt.d f3, f1"))
CASES.append(C("FP_fmadd.s", "FP_ARITH", "rv64imafdc", SET_F32, "    fmadd.s f3, f1, f2, f1"))
CASES.append(C("FP_fmadd.d", "FP_ARITH", "rv64imafdc", SET_F64, "    fmadd.d f3, f1, f2, f1"))
CASES.append(C("FP_fnmsub.s", "FP_ARITH", "rv64imafdc", SET_F32, "    fnmsub.s f3, f1, f2, f1"))

# ---- FP -> INT: G2 writes an integer destination ---------------------------
CASES.append(C("FPI_fcvt.w.s", "FP_TO_INT", "rv64imafdc", SET_F32, "    fcvt.w.s x6, f1"))
CASES.append(C("FPI_fcvt.wu.s", "FP_TO_INT", "rv64imafdc", SET_F32, "    fcvt.wu.s x6, f1"))
CASES.append(C("FPI_fcvt.l.s", "FP_TO_INT", "rv64imafdc", SET_F32, "    fcvt.l.s x6, f1"))
CASES.append(C("FPI_fcvt.lu.s", "FP_TO_INT", "rv64imafdc", SET_F32, "    fcvt.lu.s x6, f1"))
CASES.append(C("FPI_fcvt.w.d", "FP_TO_INT", "rv64imafdc", SET_F64, "    fcvt.w.d x6, f1"))
CASES.append(C("FPI_fcvt.l.d", "FP_TO_INT", "rv64imafdc", SET_F64, "    fcvt.l.d x6, f1"))
CASES.append(C("FPI_fcvt.s.w", "FP_TO_INT", "rv64imafdc", SET_FS + "\n" + SET_INT, "    fcvt.s.w f3, x1"))
CASES.append(C("FPI_fcvt.d.w", "FP_TO_INT", "rv64imafdc", SET_FS + "\n" + SET_INT, "    fcvt.d.w f3, x1"))
CASES.append(C("FPI_fcvt.s.d", "FP_TO_INT", "rv64imafdc", SET_F64, "    fcvt.s.d f3, f1"))
CASES.append(C("FPI_fcvt.d.s", "FP_TO_INT", "rv64imafdc", SET_F32, "    fcvt.d.s f3, f1"))
CASES.append(C("FPI_fmv.x.w", "FP_TO_INT", "rv64imafdc", SET_F32, "    fmv.x.w x6, f1"))
CASES.append(C("FPI_fmv.x.d", "FP_TO_INT", "rv64imafdc", SET_F64, "    fmv.x.d x6, f1"))
CASES.append(C("FPI_fclass.s", "FP_TO_INT", "rv64imafdc", SET_F32, "    fclass.s x6, f1"))
CASES.append(C("FPI_fclass.d", "FP_TO_INT", "rv64imafdc", SET_F64, "    fclass.d x6, f1"))
CASES.append(C("FPI_feq.s", "FP_TO_INT", "rv64imafdc", SET_F32, "    feq.s x6, f1, f2"))
CASES.append(C("FPI_flt.d", "FP_TO_INT", "rv64imafdc", SET_F64, "    flt.d x6, f1, f2"))
CASES.append(C("FPI_fle.s", "FP_TO_INT", "rv64imafdc", SET_F32, "    fle.s x6, f1, f2"))

# ---- AMO / LR-SC: G3 --------------------------------------------------------
for w in ["amoadd", "amoswap", "amoand", "amoor", "amoxor", "amomin", "amomax", "amominu", "amomaxu"]:
    for suf in [".w", ".d"]:
        CASES.append(C(f"AMO_{w}{suf}", "AMO", "rv64imafdc", SET_MEM, f"    {w}{suf} x5, x3, (x2)"))
CASES.append(C("AMO_lr.w", "AMO", "rv64imafdc", SET_MEM, "    lr.w x5, (x2)"))
CASES.append(C("AMO_lr.d", "AMO", "rv64imafdc", SET_MEM, "    lr.d x5, (x2)"))
CASES.append(C("AMO_sc.w", "AMO", "rv64imafdc",
               SET_MEM + "\n    lr.w x6, (x2)\n    add  x7, x6, x0",
               "    sc.w x5, x3, (x2)"))
CASES.append(C("AMO_sc.d", "AMO", "rv64imafdc",
               SET_MEM + "\n    lr.d x6, (x2)\n    add  x7, x6, x0",
               "    sc.d x5, x3, (x2)"))
# Value check: prove the AMO really runs through the cache AMO path (dc_amo_op):
# store old=0x1234 first, then amoadd 3; the returned (old) value must be 0x1234.
CASES.append(C("AMO_amoadd_w_oldval", "AMO", "rv64imafdc",
               """    addi x3, zero, 3
    la   x2, wdata
    li   x7, 0x1234
    sd   x7, 0(x2)
    ld   x8, 0(x2)
    add  x9, x8, x0""",
               "    amoadd.w x5, x3, (x2)",
               note="old=0x1234 -> returned value must be 0x1234"))

# ---- arbitration demo (A/B): same producer, only the exit layout differs -----
# Arbitration is a whole-cycle event: a loser re-drives on the NEXT cycle, so L
# moves by exactly +1, never by a fraction. Both use `mul x5,x1,x2`:
#   DEMO_MUL_nocontend : x28/x29 precomputed before the producer, then `sd`+spin
#   DEMO_MUL_contention: the exit does `addi x28` + `la x29` right after the
#       producer; that independent G1 addi reaches its lane-1 writeback in the
#       producer's own writeback cycle, wins the G1 arbiter, and pushes the MUL
#       completion out by one whole cycle.
_RAW_EXIT = "    la   x29, tohost\n    addi x28, zero, 1"
CASES.append(C("DEMO_MUL_nocontend", "DEMO", "rv64imafdc", SET_INT + "\n" + _RAW_EXIT,
               "    mul x5, x1, x2", note="contention-free reference (expect 3)",
               post="    sd   x28, 0(x29)\n1:  j    1b", raw=True))
CASES.append(C("DEMO_MUL_contention", "DEMO", "rv64imafdc", SET_INT,
               "    mul x5, x1, x2", note="post-producer G1 op wins lane1 (expect 3+1=4)",
               post="    addi x28, zero, 1\n    la   x29, tohost\n    sd   x28, 0(x29)\n1:  j    1b", raw=True))

SRC_TMPL = """.option norvc
.section .text
.globl _start
_start:
{setup}
    # Exit bookkeeping is precomputed BEFORE the producer so the only instructions
    # after it are `sd` (G3) and the spin `j` (G0): an independent same-group op
    # issued after the producer can win the group arbiter in the producer's
    # writeback cycle and inflate L by one (observed on MUL via `la x29`).
    la   x29, tohost
    addi x28, zero, 1
PRODUCER:
{body}
{post}
_exit:
    sd   x28, 0(x29)
1:  j    1b

.section .data
.align 4
wdata:
    .dword 0
    .dword 0
    .dword 0
    .dword 0
"""

# raw mode: the case supplies its own exit sequence after the producer, so an A/B
# pair can differ ONLY in the post-producer code (nothing precomputed).
RAW_TMPL = """.option norvc
.section .text
.globl _start
_start:
{setup}
PRODUCER:
{body}
{post}

.section .data
.align 4
wdata:
    .dword 0
    .dword 0
    .dword 0
    .dword 0
"""


def sh(cmd, **kw):
    return subprocess.run(cmd, capture_output=True, text=True, **kw)


def _cap(cmd):
    r = sh(cmd)
    out = (r.stdout or r.stderr).strip().splitlines()
    return out[0] if out else "?"


def _git(*args):
    r = sh(["git", "-C", str(REPO)] + list(args))
    return r.stdout.strip() or "?"


def toolchain_rows():
    """Everything needed to reproduce/attribute a latency run."""
    isa_so = Path(ISA_MODEL_ROOT) / "build/lib_ISA_api.so"
    return [
        ("L_definition", "L = (lane result/bypass visible cycle) - (issue accepted cycle); unit = clock cycle"),
        ("latency_unit", "integer clock cycles; arbitration moves it by whole cycles only"),
        ("dut_kind", DUT),
        ("tag", TAG),
        ("verilator_version", _cap(["verilator", "--version"])),
        ("verilator_path", shutil.which("verilator") or "?"),
        ("riscv_gcc_version", _cap([GCC, "--version"])),
        ("riscv_gcc_path", GCC),
        ("riscv_objdump_version", _cap([OBJDUMP, "--version"])),
        ("isa_model_root", ISA_MODEL_ROOT),
        ("isa_api_so", str(isa_so.resolve()) if isa_so.exists() else ISA_MODEL_ROOT + "/build/lib_ISA_api.so"),
        ("isa_cfg", ISA_CFG),
        ("linker_script", str(LINK)),
        ("python_version", sys.version.split()[0]),
        ("openrio_branch", _git("branch", "--show-current")),
        ("openrio_base_commit_perf_eval_danielle", _git("rev-parse", "--short", "perf_eval_danielle")),
        ("openrio_head_commit", _git("rev-parse", "--short", "HEAD")),
        ("known_issue_opt_riscv", "/opt/riscv GCC 11.1.0 unusable: cc1 cannot load libisl.so.15"),
        ("repro_cmd_build", "JOBS=8 tools/verilator_cosim.sh build --dut-kind rtl_full --tag fu_latency"),
        ("repro_cmd_run", "python3 perf_eval/latency_bench/bench.py --jobs 8"),
    ]


def gen_and_build(case):
    cid = case["id"]
    src = WORK / "cases" / f"{cid}.S"
    elf = WORK / "elf" / f"{cid}.elf"
    src.parent.mkdir(parents=True, exist_ok=True)
    elf.parent.mkdir(parents=True, exist_ok=True)
    tmpl = RAW_TMPL if case.get("raw") else SRC_TMPL
    src.write_text(tmpl.format(setup=case["setup"], body=case["body"],
                               post=case.get("post", "")))
    r = sh([GCC, f"-march={case['march']}", "-mabi=lp64", "-nostdlib", "-nostartfiles",
            f"-Wl,-T,{LINK}", "-o", str(elf), str(src)])
    if r.returncode != 0:
        return cid, f"COMPILE_FAIL\n{r.stderr}"
    return cid, ""


def producer_pc(elf):
    r = sh([NM, str(elf)])
    for line in r.stdout.splitlines():
        parts = line.split()
        if len(parts) == 3 and parts[2] == "PRODUCER":
            return int(parts[0], 16)
    return None


RE_COMMIT = re.compile(r"\[BE\]\[COSIM_OB\] cycle=(\d+) group=\d+ pc=0x([0-9a-fA-F]+) rob=(\d+)")
RE_FIRE = re.compile(r"\[ISQ_FIRE\] cycle=(\d+) group=(\d+) tag=0x([0-9a-fA-F]+)")
RE_LSUISSUE = re.compile(r"\[LSU_ISSUE\] cycle=(\d+) tag=0x([0-9a-fA-F]+)")
RE_WB = re.compile(r"\[FU_WB\] cycle=(\d+) lane=(\d+) tag=0x([0-9a-fA-F]+)")
RE_LSUBYP = re.compile(r"\[LSU_BYPASS\] cycle=(\d+) tag=0x([0-9a-fA-F]+)")
RE_LSUDONE = re.compile(r"\[LSU_DONE\] cycle=(\d+) tag=0x([0-9a-fA-F]+)")


def analyze(cid, pc, family):
    log = ENV / f"sim/verilator_{TAG}/log/{DUT}/{cid}_1/sim.log"
    if not log.exists():
        return dict(id=cid, status="NO_LOG")
    txt = log.read_text(errors="replace")
    pc_to_rob = {}
    for m in RE_COMMIT.finditer(txt):
        pc_to_rob[int(m.group(2), 16)] = int(m.group(3))
    rob = pc_to_rob.get(pc)
    fires = [(int(m.group(1)), int(m.group(3), 16)) for m in RE_FIRE.finditer(txt)]
    lsu = [(int(m.group(1)), int(m.group(2), 16)) for m in RE_LSUISSUE.finditer(txt)]
    wbs = [(int(m.group(1)), int(m.group(2)), int(m.group(3), 16)) for m in RE_WB.finditer(txt)]
    lbyp = [(int(m.group(1)), int(m.group(2), 16)) for m in RE_LSUBYP.finditer(txt)]
    ldone = [(int(m.group(1)), int(m.group(2), 16)) for m in RE_LSUDONE.finditer(txt)]
    if rob is None:
        return dict(id=cid, status="NO_COMMIT", producer_pc=hex(pc) if pc else None)

    # G3 (LOAD/AMO) is observed at the BE<->LSU boundary, where the issue and the
    # response are BOTH combinational. Do not mix them with the registered FU_WB
    # path: that path lags by one obs register and would add a phantom cycle.
    # G0/G1/G2 use the registered ISQ_FIRE + FU_WB pair, which is拍-consistent.
    if family in ("LOAD", "AMO"):
        issue = [c for c, t in lsu if t == rob]
        wb = [(c, 3) for c, t in lbyp if t == rob]
        if not wb:
            wb = [(c, 3) for c, t in ldone if t == rob]
    else:
        issue = [c for c, t in fires if t == rob]
        wb = [(c, lane) for (c, lane, t) in wbs if t == rob]
    if not issue or not wb:
        return dict(id=cid, status="NO_EVENT", producer_pc=hex(pc), rob=rob,
                    n_fire=len(issue), n_wb=len(wb))
    ic = min(issue)
    wc, lane = min(wb)
    return dict(id=cid, status="OK", producer_pc=hex(pc), rob=rob, issue=ic,
                wb=wc, lane=lane, L=wc - ic)


def run_case(case):
    cid = case["id"]
    cmd = [str(COSIM), "run", "--no-build", "--dut-kind", DUT, "--tag", TAG,
           "--tc", str(WORK / "elf" / f"{cid}.elf"), "--verbosity", "2",
           "--timeout", "200000"]
    env = dict(os.environ)
    env["ISA_MODEL_ROOT"] = ISA_MODEL_ROOT
    env["ISA_CFG"] = ISA_CFG
    r = sh(cmd, cwd=str(ENV), env=env)
    return cid, r.returncode


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--filter", default=".*")
    ap.add_argument("--jobs", type=int, default=8)
    ap.add_argument("--stage", default="all", choices=["all", "gen", "run", "report"])
    args = ap.parse_args()

    rx = re.compile(args.filter)
    cases = [c for c in CASES if rx.search(c["id"])]
    print(f"[bench] {len(cases)} cases selected")

    if args.stage in ("all", "gen"):
        with cf.ThreadPoolExecutor(max_workers=args.jobs) as ex:
            for cid, err in ex.map(gen_and_build, cases):
                if err:
                    print(f"[gen] {cid}: {err}")
        print(f"[bench] built ELFs")

    if args.stage in ("all", "run"):
        with cf.ThreadPoolExecutor(max_workers=args.jobs) as ex:
            for cid, rc in ex.map(run_case, cases):
                if rc != 0:
                    print(f"[run] {cid}: rc={rc} (may still have usable log)")
        print(f"[bench] ran cases")

    # ---- report ----
    rows = []
    for c in cases:
        elf = WORK / "elf" / f"{c['id']}.elf"
        pc = producer_pc(elf) if elf.exists() else None
        res = analyze(c["id"], pc, c["family"]) if pc is not None else dict(id=c["id"], status="NO_ELF")
        res.update(family=c["family"], note=c["note"])
        rows.append(res)
        if res["status"] != "OK":
            print(f"[report] {c['id']}: {res['status']} {res.get('rob','')} fire={res.get('n_fire','')} wb={res.get('n_wb','')}")

    out = WORK / "results"
    out.mkdir(parents=True, exist_ok=True)
    with (out / "raw.tsv").open("w") as f:
        f.write("case\tfamily\tproducer_pc\trob\tissue_cycle\twb_cycle\tlane\tL\tstatus\n")
        for r in rows:
            f.write("\t".join(str(r.get(k, "")) for k in
                    ["id", "family", "producer_pc", "rob", "issue", "wb", "lane", "L", "status"]) + "\n")

    # per-family summary
    fam = {}
    for r in rows:
        if r["status"] != "OK":
            continue
        fam.setdefault(r["family"], []).append(r["L"])
    with (out / "by_family.tsv").open("w") as f:
        f.write("family\tcases\tL_values\tL_min\tL_max\n")
        for k in sorted(fam):
            v = sorted(fam[k])
            f.write(f"{k}\t{len(v)}\t{v}\t{v[0]}\t{v[-1]}\n")

    # ---- CSV deliverables, kept in-tree under perf_eval/latency_bench/ ----
    csvdir = ENV / "perf_eval/latency_bench"
    csvdir.mkdir(parents=True, exist_ok=True)
    with (csvdir / "latency_results.csv").open("w") as f:
        f.write("case,family,producer_pc,rob,issue_cycle,wb_cycle,lane,L,status\n")
        for r in rows:
            f.write(",".join(str(r.get(k, "")) for k in
                    ["id", "family", "producer_pc", "rob", "issue", "wb", "lane", "L", "status"]) + "\n")
    with (csvdir / "family_summary.csv").open("w") as f:
        f.write("family,cases,L_min,L_max,L_values\n")
        for k in sorted(fam):
            v = sorted(fam[k])
            f.write(f'{k},{len(v)},{v[0]},{v[-1]},"{";".join(str(x) for x in v)}"\n')
    with (csvdir / "toolchain.csv").open("w") as f:
        f.write("item,value\n")
        for k, v in toolchain_rows():
            f.write(f'"{k}","{str(v).replace(chr(34), chr(39))}"\n')

    print(f"[bench] wrote {out/'raw.tsv'}, {out/'by_family.tsv'}, "
          f"{csvdir/'latency_results.csv'}, {csvdir/'family_summary.csv'}, {csvdir/'toolchain.csv'}")


if __name__ == "__main__":
    main()
