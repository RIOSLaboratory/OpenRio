#!/usr/bin/env python3
"""lane_check.py -- quantify same-group writeback-lane arbitration per case.

A collision is invisible in the P3 log: the loser simply does not appear that cycle.
The detectable signal is an instruction's writeback gap, P3 - P2, against the family's
contention-free L. Any surplus is that many lost arbitration attempts, and
latency_bench/bench.py L184-208 states each loss costs exactly one whole cycle.

Tag is NOT an instruction id here: the log reuses it, so a per-tag dictionary silently
fuses two different instructions and produces impossible (negative) gaps. This walks
the log in time order and keeps the tag -> instruction mapping that is current at each
event instead.
"""
import re
import sys
from pathlib import Path

ENV = Path("/work/home/danielle/workspace/suncheek/model/OpenRio/verification/orbe_bt_env")
# 唯一权威来源：latency_table.L_OF（出处见该文件）。不要在此重新键入数字。
from latency_table import L_OF as L_CLEAN
MNEM = [("MUL", "MUL"), ("DIV", "DIV"), ("REM", "DIV"), ("JALR", "JALR"), ("JAL", "JALR"),
        ("LD", "LOAD"), ("LW", "LOAD"), ("LH", "LOAD"), ("LB", "LOAD"), ("SD", "LOAD"),
        ("SW", "LOAD"), ("SH", "LOAD"), ("SB", "LOAD")]

RE_DEC = re.compile(r"\[BE\]\[DECODE\] cycle=(\d+) .*tag=(\S+) rob=(\d+) .*pc=(\S+)")
RE_FIR = re.compile(r"\[ISQ_FIRE\] cycle=(\d+) group=(\d+) tag=(\S+)")
RE_BYP = re.compile(r"\[P3_BYPASS\] cycle=(\d+) lane=(\d+) tag=(\S+)")
RE_CMT = re.compile(r"\[BE\]\[COMMIT\] .*tag=(\S+) .*inst_mnemonic=(\w+)")


def family(mnem):
    for pre, fam in MNEM:
        if mnem.startswith(pre):
            return fam
    return "ALU" if mnem else None


def walk(path):
    """time-ordered pass -> list of instructions with their event cycles"""
    cur, instr, seq = {}, {}, 0
    for line in path.read_text(errors="replace").split("\n"):
        m = RE_DEC.search(line)
        if m:
            seq += 1
            cur[m.group(2)] = seq
            instr[seq] = dict(pc=int(m.group(4), 16), tag=m.group(2), dec=int(m.group(1)))
            continue
        m = RE_FIR.search(line)
        if m:
            s = cur.get(m.group(3))
            if s:
                instr[s]["P2"] = int(m.group(1)); instr[s]["grp"] = int(m.group(2))
            continue
        m = RE_BYP.search(line)
        if m:
            s = cur.get(m.group(3))
            if s:
                instr[s]["P3"] = int(m.group(1)); instr[s]["lane"] = int(m.group(2))
            continue
        m = RE_CMT.search(line)
        if m:
            s = cur.get(m.group(1))
            if s:
                instr[s]["mnem"] = m.group(2)
    return [instr[k] for k in sorted(instr)]


def main(tag, dut):
    logdir = ENV / "sim" / ("verilator_" + tag) / "log" / dut
    print("%-42s %-6s %-4s %-5s %-5s %-6s %s" % ("case / instruction", "fam", "L", "gap", "extra", "lane", "pc"))
    surplus_total, cases_hit = 0, 0
    for d in sorted(logdir.glob("*_1")):
        cid = d.name[:-2]
        log = d / "sim.log"
        if not log.exists():
            continue
        rows = []
        for e in walk(log):
            if "P2" not in e or "P3" not in e or "mnem" not in e:
                continue
            fam = family(e["mnem"])
            L = L_CLEAN.get(fam)
            if L is None:
                continue
            gap = e["P3"] - e["P2"]
            if gap != L:
                rows.append((fam, L, gap, gap - L, e.get("lane"), e["pc"], e["mnem"]))
        if rows:
            cases_hit += 1
            print("%-42s" % cid)
            for fam, L, gap, extra, lane, pc, mnem in rows:
                surplus_total += extra
                print("   %-39s %-6s %-4d %-5d %+d     %-6s 0x%x  %s"
                      % ("", fam, L, gap, extra, lane, pc, mnem))
    print()
    print("cases with a surplus: %d     total surplus cycles: %d" % (cases_hit, surplus_total))


def surplus_by_case(tag, dut):
    """case id -> total writeback surplus cycles, for use as a contamination filter"""
    logdir = ENV / "sim" / ("verilator_" + tag) / "log" / dut
    out = {}
    for d in sorted(logdir.glob("*_1")):
        log = d / "sim.log"
        if not log.exists():
            continue
        tot = 0
        for e in walk(log):
            if "P2" not in e or "P3" not in e or "mnem" not in e:
                continue
            L = L_CLEAN.get(family(e["mnem"]))
            if L is None:
                continue
            gap = e["P3"] - e["P2"]
            if gap != L:
                tot += gap - L
        out[d.name[:-2]] = tot
    return out


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else "timing_delta",
         sys.argv[2] if len(sys.argv) > 2 else "rtl_full")
