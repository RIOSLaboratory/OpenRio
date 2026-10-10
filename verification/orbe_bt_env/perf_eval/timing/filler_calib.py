#!/usr/bin/env python3
"""filler_calib.py -- find filler recipes that hit a target delta without contaminating
the producer's writeback lane.

The old recipe was "2*delta-1 one-cycle ALU fillers". That is unusable whenever the
producer is a multi-cycle instruction fixed to G0 or G1, because 2 dispatches per cycle
means 2 writebacks per cycle and both of those lanes are always busy. Measured on
MUL_to_ALU_delta_4: the MUL's writeback slid from issue+3 to issue+6.

The fix is a filler mix that keeps every filler off the producer's lane:
  ld     -> G3, lane 3
  fadd.s -> G2, lane 2
Neither is one-instruction-per-cycle, so the count-to-delta relation is no longer the
old formula and has to be measured. This walks a small (n_ld, n_fp) grid, measures
delta and the producer's writeback gap for every cell, and reports which cells hit each
target delta with the gap still equal to the family's clean L.

Grid cells are measured once and reused for every target, so one run calibrates the
whole ladder of a family.
"""
import re
import subprocess
import sys
from pathlib import Path

ENV = Path("/work/home/danielle/workspace/suncheek/model/OpenRio/verification/orbe_bt_env")
WORK = Path("/work/home/danielle/workspace/suncheek/model/perf_eval_work/filler_exp")
GCC = Path("/work/stu/yzhang/workspace/riscv/bin/riscv64-unknown-elf-gcc")
COSIM = ENV / "tools/verilator_cosim.sh"
LINK = ENV / "perf_eval/templates/link.ld"
TAG, DUT = "p3exp", "rtl_v1"

ENC = {"mul": 0x022082b3, "div": 0x0220c2b3, "add": 0x002082b3}
ADD_ENC = 0x00328333                      # the consumer, add x6, x5, x3

FAMILY = {
    "MUL": dict(ins="mul  x5, x1, x2", enc=ENC["mul"], L=3),
    "DIV": dict(ins="div  x5, x1, x2", enc=ENC["div"], L=4),
}

PRE = """    addi x1, zero, 1
    addi x2, zero, 2
    addi x3, zero, 3
    addi x4, zero, 4
    li   x11, 0x6000
    csrs mstatus, x11
    la   x12, scratch
    {producer}
"""
SUF = """    add  x6, x5, x3
pass:
    addi x28, zero, 1
    la   x29, tohost
    sd   x28, 0(x29)
1:  wfi
    j    1b
.section .data
scratch: .quad 0
"""
SRC = ".option norvc\n.section .text\n.globl _start\n_start:\n{pre}{fill}\n{suf}"


def build_runs(fam, j, k):
    """j load fillers then k fadd fillers, then the consumer"""
    name = "%s_ld%d_fp%d" % (fam, j, k)
    fill = "\n".join(["    ld   x%d, 0(x12)" % (13 + i) for i in range(j)] +
                     ["    fadd.s f%d, f1, f2" % (13 + i) for i in range(k)])
    pre = PRE.format(producer=FAMILY[fam]["ins"])
    src, elf = WORK / "cases" / (name + ".S"), WORK / "elf" / (name + ".elf")
    src.write_text(SRC.format(pre=pre, fill=fill, suf=SUF), encoding="utf-8")
    r = subprocess.run([str(GCC), "-march=rv64imafdc", "-mabi=lp64d", "-nostdlib",
                        "-nostartfiles", "-Wl,-T," + str(LINK), "-o", str(elf), str(src)],
                       capture_output=True, text=True)
    if r.returncode:
        raise SystemExit("%s link failed: %s" % (name, r.stderr[:200]))
    subprocess.run([str(COSIM), "run", "--no-build", "--dut-kind", DUT, "--tag", TAG,
                    "--tc", str(elf), "--verbosity", "2"], capture_output=True, text=True)
    return name


def measure(name):
    log = ENV / "sim" / ("verilator_" + TAG) / "log" / DUT / (name + "_1") / "sim.log"
    if not log.exists():
        return None
    txt = log.read_text(errors="replace")
    cur, instr, seq, dec = {}, {}, 0, {}
    for line in txt.split("\n"):
        m = re.search(r"\[BE\]\[DECODE\] cycle=(\d+) .*tag=(\S+) .*pc=(\S+) inst=(\S+)", line)
        if m:
            h = m.group(4).lower().replace("0x", "")
            dec.setdefault(h, int(m.group(1)))
            seq += 1
            cur[m.group(2)] = seq
            instr[seq] = dict(inst=h, dec=int(m.group(1)))
            continue
        m = re.search(r"\[ISQ_FIRE\] cycle=(\d+) group=(\d+) tag=(\S+)", line)
        if m and cur.get(m.group(3)) in instr:
            instr[cur[m.group(3)]]["P2"] = int(m.group(1)); continue
        m = re.search(r"\[P3_BYPASS\] cycle=(\d+) lane=(\d+) tag=(\S+)", line)
        if m and cur.get(m.group(3)) in instr:
            instr[cur[m.group(3)]]["P3"] = int(m.group(1))
    return instr, dec


def main(fams, maxn=4):
    print("grid: n_ld, n_fp = 0..%d each; cell is kept only if delta is well defined" % maxn)
    for fam in fams:
        L = FAMILY[fam]["L"]
        p_enc = "%08x" % FAMILY[fam]["enc"]
        table = {}
        print("\n== %s (producer %s, clean L=%d)" % (fam, FAMILY[fam]["ins"].strip(), L))
        print("  %-4s %-4s %-7s %-8s %s" % ("#ld", "#fp", "delta", "prod wb", "usable"))
        for j in range(maxn + 1):
            for k in range(maxn + 1):
                name = build_runs(fam, j, k)
                r = measure(name)
                if not r:
                    continue
                instr, dec = r
                mul = [e for e in instr.values() if e["inst"] == p_enc]
                add = [e for e in instr.values() if e["inst"] == "%08x" % ADD_ENC]
                if not (mul and add):
                    continue
                d = add[0]["dec"] - mul[0]["dec"]
                p2, p3 = mul[0].get("P2"), mul[0].get("P3")
                wb = (p3 - p2) if (p2 is not None and p3 is not None) else None
                usable = (wb == L)
                table.setdefault(d, []).append((j, k, wb, usable))
                if j + k <= 5 or d in (4,):
                    print("  %-4d %-4d %-7d %-8s %s" % (j, k, d, wb, "✓" if usable else "✗ 被抢 lane"))
        print("\n  == %s 的配方表（只列 wb 干净的 ✓）" % fam)
        for d in sorted(table):
            good = ["(#ld=%d,#fp=%d)" % (j, k) for (j, k, wb, u) in table[d] if u]
            if good:
                print("     delta=%-3d  %s" % (d, " 或 ".join(good[:4])))
            else:
                print("     delta=%-3d  ✗ 无干净配方（该 δ 目前不可用）" % d)


if __name__ == "__main__":
    main(sys.argv[1:] or ["MUL", "DIV"])
