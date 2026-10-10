#!/usr/bin/env python3
"""Batch-construct the .S for every INT dependency case.

The caselists are the source of truth: the case set, the instruction skeletons and
the filler counts are all read from the markdown tables. Nothing is duplicated here,
so a caselist edit is the only edit needed.

Generated .S and .elf go OUTSIDE the repo (WORK), matching METHOD section 3 and the
layout perf_eval_work/README.md documents.

Usage:
    python3 gen_cases.py            # write WORK/cases/<id>.S
    python3 gen_cases.py --elf      # also assemble and link WORK/elf/<id>.elf
    python3 gen_cases.py --list     # just print what would be generated
"""

import hashlib
import re
import subprocess
import sys
from pathlib import Path

ENV = Path("/work/home/danielle/workspace/suncheek/model/OpenRio/verification/orbe_bt_env")
# Flat build tree, as perf_eval_work/README.md documents: cases/ elf/ results/ at the
# top level. The name "timing" belongs to the materials (k-maps, diagrams, caselists)
# and must not appear here.
WORK = Path("/work/home/danielle/workspace/suncheek/model/perf_eval_work")
TEMPLATE = ENV / "perf_eval/templates/case.S.in"
LINK = ENV / "perf_eval/templates/link.ld"
CASELISTS = [ENV / "perf_eval/timing/caselists/INT_single_operand_dependency_caselist_v1.md",
             ENV / "perf_eval/timing/caselists/INT_two_operands_dependency_caselist.md"]

GCC = "/work/stu/yzhang/workspace/riscv/bin/riscv64-unknown-elf-gcc"
MARCH, MABI = "rv64imafdc", "lp64d"

# Filler pool, kept in step with the caselists' Filler and Program Construction section.
POOL = [13, 14, 15, 16, 17, 18, 19, 21, 22, 23, 24, 25, 26, 27, 30]

# Sets the template declares as off limits to a case, plus the inputs.
INPUTS = {1, 2, 3, 4}
EXIT_REGS = {28, 29, 31}

def rd_of(ins):
    """destination register of an instruction, or None"""
    parts = ins.replace(",", " ").split()
    if len(parts) < 2:
        return None
    m = re.match(r"^x(\d+)$", parts[1])
    return int(m.group(1)) if m else None


def regs_of(ins):
    return [int(n) for n in re.findall(r"\bx(\d+)\b", ins)]


def parse_caselist(path):
    """-> [(case_id, [instruction, ...], [fillers_after_each, ...])]"""
    out, cols = [], None
    for line in path.read_text(encoding="utf-8").split("\n"):
        if line.startswith("| Case |") and "Instructions" in line and "Fillers" in line:
            cells = [c.strip() for c in line.strip().strip("|").split("|")]
            cols = (cells.index("Instructions"), cells.index("Fillers after each"))
            continue
        if cols is None or not line.startswith("| `"):
            continue
        cells = [c.strip() for c in line.strip().strip("|").split("|")]
        if len(cells) < max(cols) + 1:
            continue
        cid = cells[0].strip("`")
        skeleton = cells[cols[0]].strip("`")
        instrs = [p.strip() for p in re.split(r";|->", skeleton) if p.strip()]
        fill_txt = cells[cols[1]].strip()
        fillers = [int(x) for x in re.split(r"/", fill_txt)] if fill_txt != "?" else []
        out.append((cid, instrs, fillers))
    return out


def expand(cid, instrs, fillers):
    """Interleave the case instructions with the fillers the table asks for."""
    if len(fillers) != len(instrs) - 1:
        raise SystemExit("%s: %d filler counts for %d instructions" % (cid, len(fillers), len(instrs)))
    if sum(fillers) > len(POOL):
        raise SystemExit("%s: needs %d fillers, pool has %d" % (cid, sum(fillers), len(POOL)))
    lines, n = [], 0
    for i, ins in enumerate(instrs):
        tag = "dependent" if i == len(instrs) - 1 else "producer %d" % (i + 1)
        lines.append("    %-22s # %s: %s" % (ins, tag, cid))
        for _ in range(fillers[i] if i < len(fillers) else 0):
            lines.append("    %-22s # filler" % ("addi x%d, x0, 1" % POOL[n]))
            n += 1
    return lines, n


def check(cid, instrs):
    """Refuse anything that would break the template's register contract.

    Reading the inputs is what they are for; only *rewriting* them is forbidden.
    The exit registers may not be touched at all, and the filler pool may not be
    named by a case instruction or it would collide with the fillers.
    """
    bad = []
    for ins in instrs:
        rd = rd_of(ins)
        if rd in INPUTS:
            bad.append("%s rewrites input register x%d" % (cid, rd))
        for n in regs_of(ins):
            if n in EXIT_REGS:
                bad.append("%s touches exit register x%d" % (cid, n))
            if n in POOL:
                bad.append("%s names filler-pool register x%d" % (cid, n))
    return bad


MANIFEST = WORK / ".gen_cases_manifest.tsv"


def read_manifest():
    """case id -> sha256 of the content this tool last wrote"""
    if not MANIFEST.exists():
        return {}
    out = {}
    for line in MANIFEST.read_text(encoding="utf-8").split("\n"):
        parts = line.split("\t")
        if len(parts) == 2:
            out[parts[0]] = parts[1]
    return out


def write_manifest(entries):
    MANIFEST.write_text("".join("%s\t%s\n" % (k, v) for k, v in sorted(entries.items())),
                        encoding="utf-8")


def sha(text):
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


def main(argv):
    want_elf = "--elf" in argv
    want_list = "--list" in argv
    force = "--force" in argv
    manifest = read_manifest()
    blocked = []
    tpl = TEMPLATE.read_text(encoding="utf-8")
    for ph in ("{CASE_ID}", "{CASE_BODY}"):
        if tpl.count(ph) != 1:
            raise SystemExit("template %s: %s occurs %d times, expected exactly 1"
                             % (TEMPLATE.name, ph, tpl.count(ph)))
    (WORK / "cases").mkdir(parents=True, exist_ok=True)
    if want_elf:
        (WORK / "elf").mkdir(parents=True, exist_ok=True)

    problems, rows, total_filler = [], [], 0
    for cl in CASELISTS:
        for cid, instrs, fillers in parse_caselist(cl):
            problems += check(cid, instrs)
            body, nf = expand(cid, instrs, fillers)
            total_filler += nf
            rows.append((cid, len(instrs), fillers, nf))
            if want_list:
                print("%-50s instrs=%d fillers=%s" % (cid, len(instrs), fillers))
                continue
            src = WORK / "cases" / (cid + ".S")
            text = tpl.replace("{CASE_ID}", cid).replace("{CASE_BODY}", "\n".join(body))
            # Never clobber a file this tool did not write, or one that has been edited
            # since. The calibrated recipes are hand-built and must survive a rerun.
            if src.exists() and not force:
                on_disk = src.read_text(encoding="utf-8")
                ours_and_unmodified = (on_disk == text) or (manifest.get(cid) == sha(on_disk))
                if not ours_and_unmodified:
                    blocked.append(cid)
                    continue
            src.write_text(text, encoding="utf-8")
            manifest[cid] = sha(text)
            if want_elf:
                elf = WORK / "elf" / (cid + ".elf")
                r = subprocess.run([GCC, "-march=" + MARCH, "-mabi=" + MABI,
                                    "-nostdlib", "-nostartfiles",
                                    "-Wl,-T," + str(LINK), "-o", str(elf), str(src)],
                                   capture_output=True, text=True)
                if r.returncode:
                    problems.append("%s: link failed: %s" % (cid, r.stderr.strip()[:120]))

    if not want_list:
        write_manifest(manifest)
        if blocked:
            print("REFUSED to overwrite %d case file(s), they are not ours or were edited:" % len(blocked))
            for c in blocked:
                print("    %s" % c)
            print("    pass --force only if you intend to discard those edits")
        print("cases: %d   fillers emitted: %d" % (len(rows), total_filler))
        print("output: %s" % (WORK / ("elf" if want_elf else "cases")))
    if problems:
        print("\nPROBLEMS:")
        for p in problems:
            print("  " + p)
        return 1
    print("register contract: clean")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
