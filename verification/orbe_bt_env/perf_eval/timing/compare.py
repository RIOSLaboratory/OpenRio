#!/usr/bin/env python3
"""compare.py -- machine audit of the diagrams' predictions against the RTL logs.

Per METHOD Step 5: identify instructions by pc, take each instruction's first P1
event, and compare the measured delta against the caselist's prediction.

Scope of this version
  * Single-operand cases are judged in full: the measured delta must equal the delta
    in the case name, and the mechanism read off the log must be the one the
    (delta, L) rule predicts.
  * Two-operand cases are reported, not judged yet: their predictions are relations
    between the two producers and the dependent, which need the same treatment for
    the producer side first.

Event sources, all at verbosity 2 (METHOD Step 4):
  P1  [BE][DECODE]            cycle= group= order= tag= rob= pc= inst=
  P2  [BE_TB] [COSIM] [ISQ_FIRE]  cycle= group= tag=            (the ACCEPT, not the request)
  P3  [BE_TB] [COSIM] [P3_BYPASS] cycle= lane= tag=
  P4  [BE][COMMIT]            cycle= group= retire= rob= tag= pc=

The case body is located from the ELF symbols: it is [_start + 4 setup instructions,
pass). Nothing is taken from the generator, so the audit does not share code with the
thing it audits.

Negative control (--selftest) is mandatory before trusting a green run: it perturbs
the prediction and the comparator must then report a mismatch.
"""

import argparse
import re
import subprocess
import sys
from pathlib import Path

ENV = Path("/work/home/danielle/workspace/suncheek/model/OpenRio/verification/orbe_bt_env")
WORK = Path("/work/home/danielle/workspace/suncheek/model/perf_eval_work")
CASELISTS = [ENV / "perf_eval/timing/caselists/INT_single_operand_dependency_caselist_v1.md",
             ENV / "perf_eval/timing/caselists/INT_two_operands_dependency_caselist.md"]
TC = Path("/work/stu/yzhang/workspace/riscv/bin")
OBJDUMP, NM = TC / "riscv64-unknown-elf-objdump", TC / "riscv64-unknown-elf-nm"

L_OF = {"ALU": 1, "MUL": 3, "DIV": 4, "LOAD": 3, "JALR": 1}
SETUP_INSTRS = 4          # templates/case.S.in writes x1..x4 before the case body


def mech_of(delta, L):
    if delta == 0:
        return "overlay"
    if 1 <= delta <= L:
        return "wait_for_p3"
    if delta == L + 1:
        return "p3_capture"
    if delta == L + 2:
        return "p4_capture"
    if delta == L + 3:
        return "arf_read"
    return "?"


def parse_caselists():
    """case id -> dict(family, delta, mechanism_from_name)"""
    out = {}
    for p in CASELISTS:
        for line in p.read_text(encoding="utf-8").split("\n"):
            if not line.startswith("| `"):
                continue
            cid = line.split("`")[1]
            m = re.match(r"([A-Z]+)_to_ALU_delta_(\d+)$", cid)
            if m:
                out[cid] = dict(family=m.group(1), delta=int(m.group(2)), kind="single")
            elif cid.startswith("INT2_"):
                out[cid] = dict(family=None, delta=None, kind="two")
    return out


def elf_body(elf):
    """pcs of the case body, in program order, from the ELF's own symbols and dump."""
    nm = subprocess.run([str(NM), str(elf)], capture_output=True, text=True).stdout
    sym = {}
    for line in nm.split("\n"):
        parts = line.split()
        if len(parts) == 3:
            sym[parts[2]] = int(parts[0], 16)
    if "_start" not in sym or "pass" not in sym:
        return []
    lo, hi = sym["_start"] + 4 * SETUP_INSTRS, sym["pass"]
    dump = subprocess.run([str(OBJDUMP), "-d", str(elf)], capture_output=True, text=True).stdout
    body = []
    for line in dump.split("\n"):
        m = re.match(r"^\s+([0-9a-f]+):\s+[0-9a-f]{8}\s+(.*)$", line)
        if not m:
            continue
        pc = int(m.group(1), 16)
        if lo <= pc < hi:
            body.append((pc, m.group(2).split("#")[0].strip()))
    return body


def parse_log(path):
    """events keyed by pc and by tag"""
    by_pc, by_tag = {}, {}
    for line in path.read_text(errors="replace").split("\n"):
        if "[BE][DECODE]" in line:
            d = dict(re.findall(r"(\w+)=(\S+)", line))
            by_pc.setdefault(int(d["pc"], 16), {})["P1"] = int(d["cycle"])
            by_tag.setdefault(d["tag"], {})["pc"] = int(d["pc"], 16)
            by_tag[d["tag"]]["P1"] = int(d["cycle"])
        elif "[ISQ_FIRE]" in line:
            d = dict(re.findall(r"(\w+)=(\S+)", line))
            by_tag.setdefault(d["tag"], {})["P2"] = int(d["cycle"])
        elif "[P3_BYPASS]" in line:
            d = dict(re.findall(r"(\w+)=(\S+)", line))
            by_tag.setdefault(d["tag"], {})["P3"] = int(d["cycle"])
        elif "[BE][COMMIT]" in line:
            d = dict(re.findall(r"(\w+)=(\S+)", line))
            by_pc.setdefault(int(d["pc"], 16), {})["P4"] = int(d["cycle"])
            by_tag.setdefault(d["tag"], {})["P4"] = int(d["cycle"])
    return by_pc, by_tag


def events_for_pc(pc, by_pc, by_tag):
    """merge the by-pc (P1/P4) and by-tag (P2/P3) views for one instruction"""
    ev = dict(by_pc.get(pc, {}))
    for tag, t in by_tag.items():
        if t.get("pc") == pc:
            for k in ("P2", "P3", "P4"):
                if k in t and k not in ev:
                    ev[k] = t[k]
            break
    return ev


def audit(tag, dut, case_filter, selftest):
    cases = parse_caselists()
    logdir = ENV / "sim" / ("verilator_" + tag) / "log" / dut
    rows, bad = [], 0
    for elf in sorted((WORK / "elf").glob("*.elf")):
        cid = elf.stem
        if case_filter and case_filter not in cid:
            continue
        meta = cases.get(cid)
        if meta is None:
            continue
        log = logdir / ("%s_1" % cid) / "sim.log"
        if not log.exists():
            rows.append((cid, "NOT_RUN", "", "", "", "")); continue
        body = elf_body(elf)
        if len(body) < 2:
            rows.append((cid, "NO_BODY", "", "", "", "")); bad += 1; continue
        by_pc, by_tag = parse_log(log)
        prod = events_for_pc(body[0][0], by_pc, by_tag)
        dep = events_for_pc(body[-1][0], by_pc, by_tag)
        if "P1" not in prod or "P1" not in dep:
            rows.append((cid, "NO_P1", "", "", "", "")); bad += 1; continue

        if meta["kind"] == "single":
            L = L_OF[meta["family"]]
            want_delta = meta["delta"]
            if selftest:
                want_delta += 1                      # negative control
            got_delta = dep["P1"] - prod["P1"]
            want_mech = mech_of(meta["delta"], L)
            # Read the mechanism off the log. If no pattern matches, say so: silently
            # falling back to the prediction would make the audit vacuous.
            got_mech = "UNKNOWN"
            # mechanism read off the log, not off the delta
            # Order matters: most specific first. In a same-bundle case (delta 0) the
            # dependent's P2 also equals the producer's P3, so testing overlay last
            # would mislabel every delta_0 row.
            if dep.get("P1") == prod.get("P1"):
                got_mech = "overlay"
            elif "P3" in prod and dep.get("P1") == prod["P3"]:
                got_mech = "p3_capture"
            elif "P3" in prod and dep.get("P2") == prod["P3"]:
                got_mech = "wait_for_p3"
            elif dep.get("P1") == prod.get("P4", -1):
                got_mech = "p4_capture"
            elif "P4" in prod and dep.get("P1") > prod["P4"]:
                got_mech = "arf_read"
            # A dependent that is dispatched but then sits in the ISQ until the source
            # arrives is wait_for_p3 with a stall; report the stall explicitly.
            if got_mech == "UNKNOWN" and "P3" in prod and dep.get("P2") is not None                and dep["P2"] >= prod["P3"] and dep.get("P1") is not None                and dep["P1"] < prod["P3"]:
                got_mech = "stalled(%d)" % (dep["P2"] - prod["P3"])
            if got_mech == "UNKNOWN":
                verdict = "UNVERIFIED"          # never a pass
                bad += 1
            elif got_delta == want_delta and got_mech == want_mech:
                verdict = "OK"
            else:
                verdict = "MISMATCH"
                bad += 1
            rows.append((cid, verdict, want_delta, got_delta, want_mech, got_mech))
        else:
            rows.append((cid, "REPORTED", "", dep["P1"] - prod["P1"], "", ""))
    return rows, bad


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--tag", default="timing_delta")
    ap.add_argument("--dut", default="rtl_v1")
    ap.add_argument("--case", default="")
    ap.add_argument("--selftest", action="store_true",
                    help="negative control: perturb the prediction, expect MISMATCH")
    a = ap.parse_args()

    rows, bad = audit(a.tag, a.dut, a.case, a.selftest)
    judged = [r for r in rows if r[1] in ("OK", "MISMATCH", "UNVERIFIED")]
    print("%-46s %-9s %-6s %-6s %-12s %s" % ("case", "verdict", "want", "got", "want-mech", "got-mech"))
    for r in rows:
        print("%-46s %-9s %-6s %-6s %-12s %s" % r)
    print()
    print("cases: %d, judged: %d, problems: %d" % (len(rows), len(judged), bad))
    out = WORK / "results" / ("compare_%s%s.tsv" % (a.tag, "_selftest" if a.selftest else ""))
    out.parent.mkdir(parents=True, exist_ok=True)
    with out.open("w") as fh:
        fh.write("case\tverdict\twant_delta\tgot_delta\twant_mech\tgot_mech\n")
        for r in rows:
            fh.write("\t".join(str(x) for x in r) + "\n")
    print("written: %s" % out)

    if a.selftest:
        # The control is inverted on purpose: a green audit must go red here.
        if bad == 0:
            print("\nSELFTEST FAILED: the comparator passed a deliberately wrong prediction")
            return 1
        print("\nSELFTEST PASSED: %d mismatches reported under a wrong prediction" % bad)
        return 0
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
