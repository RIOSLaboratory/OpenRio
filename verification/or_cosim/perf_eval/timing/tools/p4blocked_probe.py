"""P4-blocked 探针：验证"更老的 DIV 压住提交"是否真的成立。

程序（div 与 producer 必须相邻，才能同拍派发、且 div 在 slot 0）：
    div x7, x1, x2      # blocker, G0 固定, L=4, 更老
    add x5, x1, x2      # producer, 被挤到 G1, L=1
    <k 条 fadd.s>       # lane 2 填充物，不碰 G0/G1
    add x6, x5, x3      # dependent

观察量：
  producer.P3-P2 应 == 1（写回未受扰）
  producer.P4-P3 应 >  1（提交被压）  ← 本探针要证的核心
  dependent 的机制：不再是 P4 捕捉，而是等待
"""
import re
import subprocess
import sys
from pathlib import Path

ENV = Path("/work/home/danielle/workspace/suncheek/model/OpenRio/verification/or_cosim")
W = Path("/work/home/danielle/workspace/suncheek/model/perf_eval_work/filler_exp")
TC = Path("/work/stu/yzhang/workspace/riscv/bin")
LINK = ENV / "perf_eval/templates/link.ld"
TAG, DUT = "timing_full", "rtl_full"

HEAD = """    .option norvc
    .section .text
    .globl _start
_start:
    addi x1, zero, 1
    addi x2, zero, 2
    addi x3, zero, 3
    li   x7, 0x6000
    csrs mstatus, x7
    la   x29, tohost
    addi x28, zero, 1
    div  x9, x1, x2
    add  x5, x1, x2
"""
TAIL = """    add  x6, x5, x3
pass:
    sd   x28, 0(x29)
1:  j    1b
"""


def build_and_run(k):
    name = "PB_%d" % k
    src, elf = W / "cases" / (name + ".S"), W / "elf" / (name + ".elf")
    src.write_text(HEAD + "".join("    fadd.s f%d, f1, f2\n" % (21 + i) for i in range(k)) + TAIL,
                   encoding="utf-8")
    if subprocess.run([str(TC / "riscv64-unknown-elf-gcc"), "-march=rv64imafdc", "-mabi=lp64d",
                       "-nostdlib", "-nostartfiles", "-Wl,-T," + str(LINK), "-o", str(elf),
                       str(src)], capture_output=True, text=True).returncode:
        return None, None
    subprocess.run([str(ENV / "tools/verilator_cosim.sh"), "run", "--no-build", "--dut-kind", DUT,
                    "--tag", TAG, "--verbosity", "2", "--timeout", "200000", "--tc", str(elf)],
                   capture_output=True, text=True)
    log = ENV / "sim" / ("verilator_" + TAG) / "log" / DUT / (name + "_1") / "sim.log"
    return (log.read_text(errors="replace") if log.exists() else None), elf


def pcs(elf):
    od = subprocess.run([str(TC / "riscv64-unknown-elf-objdump"), "-d", str(elf)],
                        capture_output=True, text=True).stdout
    out = {}
    for ln in od.split("\n"):
        m = re.match(r"^\s+([0-9a-f]+):\s+([0-9a-f]{8})\s+(\w+)", ln)
        if not m:
            continue
        mn, rd = m.group(3), (int(m.group(2), 16) >> 7) & 31
        if mn == "div" and rd == 9:
            out["div"] = int(m.group(1), 16)
        elif mn == "add" and rd == 5:
            out["prod"] = int(m.group(1), 16)
        elif mn == "add" and rd == 6:
            out["dep"] = int(m.group(1), 16)
    return out


def parse(txt, want):
    cur, inst, seq = {}, {}, 0
    for ln in txt.split("\n"):
        m = re.search(r"\[BE\]\[DECODE\] cycle=(\d+) .*tag=(\S+) .*pc=(\S+)", ln)
        if m:
            seq += 1
            cur[m.group(2)] = seq
            inst[seq] = dict(pc=int(m.group(3), 16), P1=int(m.group(1)))
            continue
        m = re.search(r"\[ISQ_FIRE\] cycle=(\d+) group=(\d+) tag=(\S+)", ln)
        if m and m.group(3) in cur:
            inst[cur[m.group(3)]].setdefault("P2", int(m.group(1)))
            inst[cur[m.group(3)]]["g"] = int(m.group(2)); continue
        m = re.search(r"\[P3_BYPASS\] cycle=(\d+) lane=(\d+) tag=(\S+)", ln)
        if m and m.group(3) in cur:
            inst[cur[m.group(3)]].setdefault("P3", int(m.group(1)))
            inst[cur[m.group(3)]]["lane"] = int(m.group(2)); continue
        m = re.search(r"\[BE\]\[COMMIT\] cycle=(\d+) .*tag=(\S+)", ln)
        if m and m.group(2) in cur:
            inst[cur[m.group(2)]].setdefault("P4", int(m.group(1)))
    res = {}
    for k, pc in want.items():
        got = sorted([e for e in inst.values() if e["pc"] == pc], key=lambda e: e["P1"])
        res[k] = got[0] if got else {}
    return res


for k in range(0, 6):
    txt, elf = build_and_run(k)
    if not txt:
        print("k=%d 无日志" % k, flush=True); continue
    r = parse(txt, pcs(elf))
    d, p, q = r.get("div", {}), r.get("prod", {}), r.get("dep", {})
    gap = (p.get("P3", 0) - p.get("P2", 0)) if ("P3" in p and "P2" in p) else None
    p4p3 = (p.get("P4", 0) - p.get("P3", 0)) if ("P4" in p and "P3" in p) else None
    delta = (q.get("P1", 0) - p.get("P1", 0)) if ("P1" in q and "P1" in p) else None
    print("k=%d | div  g%-2s P1=%-3s P2=%-3s P3=%-3s P4=%-3s | prod g%-2s P1=%-3s P2=%-3s P3=%-3s P4=%-3s "
          "| gap=%s P4-P3=%s | dep P1=%-3s P2=%-3s P3=%-3s P4=%-3s δ=%s"
          % (k, d.get("g", "-"), d.get("P1", "-"), d.get("P2", "-"), d.get("P3", "-"), d.get("P4", "-"),
             p.get("g", "-"), p.get("P1", "-"), p.get("P2", "-"), p.get("P3", "-"), p.get("P4", "-"),
             gap, p4p3, q.get("P1", "-"), q.get("P2", "-"), q.get("P3", "-"), q.get("P4", "-"), delta),
          flush=True)
print("完成", flush=True)
