"""固化 JALR_to_ALU 的 δ=1..4 四条（rtl_full 上标定，含同 PC 预热循环）。

δ=0（overlay，需同拍双发）在所有家族的 rtl_full 扫描里都取不到，属全局待决项，不固化。
"""
import re
import subprocess
from pathlib import Path

ENV = Path("/work/home/danielle/workspace/suncheek/model/OpenRio/verification/or_cosim")
FROZEN = ENV / "perf_eval/timing/calibrated_cases"
WORK = Path("/work/home/danielle/workspace/suncheek/model/perf_eval_work")
TC = Path("/work/stu/yzhang/workspace/riscv/bin")
LINK = ENV / "perf_eval/templates/link.ld"
TAG, DUT = "timing_full", "rtl_full"

HEAD = """    .option norvc
    .section .text
    .globl _start
_start:
    addi x1, zero, 1
    addi x3, zero, 3
    la   x12, scratch
    li   x7, 0x6000
    csrs mstatus, x7
    la   x29, tohost
    addi x28, zero, 1
    la   x11, JT
    li   x12, 2
LOOP:
    mv   x10, x11
    jalr x5, 0(x10)
JT:
"""
TAIL = """    add  x6, x5, x3
    addi x12, x12, -1
    bne  x12, x0, LOOP
pass:
    sd   x28, 0(x29)
1:  j    1b
.section .data
scratch: .quad 0
"""

# δ -> (kind, n)
RECIPES = {1: ("fp", 0), 2: ("fp", 2), 3: ("ld", 3), 4: ("fp", 3)}


def fill(kind, n):
    if kind == "fp":
        return "".join("    fadd.s f%d, f1, f2\n" % (21 + i) for i in range(n))
    return "".join("    ld   x%d, 0(x12)\n" % (21 + i) for i in range(n))


for delta, (kind, n) in RECIPES.items():
    cid = "JALR_to_ALU_delta_%d" % delta
    text = HEAD + fill(kind, n) + TAIL
    src = FROZEN / (cid + ".S")
    src.write_text(text, encoding="utf-8")
    elf = WORK / "elf" / (cid + ".elf")
    r = subprocess.run([str(TC / "riscv64-unknown-elf-gcc"), "-march=rv64imafdc", "-mabi=lp64d",
                        "-nostdlib", "-nostartfiles", "-Wl,-T," + str(LINK), "-o", str(elf), str(src)],
                       capture_output=True, text=True)
    assert r.returncode == 0, r.stderr[:200]
    subprocess.run([str(ENV / "tools/verilator_cosim.sh"), "run", "--no-build", "--dut-kind", DUT,
                    "--tag", TAG, "--verbosity", "2", "--timeout", "200000", "--tc", str(elf)],
                   capture_output=True, text=True)
    log = ENV / "sim" / ("verilator_" + TAG) / "log" / DUT / (cid + "_1") / "sim.log"
    txt = log.read_text(errors="replace") if log.exists() else ""
    cur, inst, seq = {}, {}, 0
    for line in txt.split("\n"):
        m = re.search(r"\[BE\]\[DECODE\] cycle=(\d+) .*tag=(\S+) .*pc=(\S+)", line)
        if m:
            seq += 1
            cur[m.group(2)] = seq
            inst[seq] = dict(pc=int(m.group(3), 16), P1=int(m.group(1)))
            continue
        m = re.search(r"\[ISQ_FIRE\] cycle=(\d+) group=\d+ tag=(\S+)", line)
        if m and m.group(2) in cur:
            inst[cur[m.group(2)]].setdefault("P2", int(m.group(1))); continue
        m = re.search(r"\[P3_BYPASS\] cycle=(\d+) lane=\d+ tag=(\S+)", line)
        if m and m.group(2) in cur:
            inst[cur[m.group(2)]].setdefault("P3", int(m.group(1))); continue
        m = re.search(r"\[FU_WB\] cycle=(\d+) .*tag=(\S+) result=\S+ mispredict=(\d)", line)
        if m and m.group(2) in cur:
            inst[cur[m.group(2)]]["mis"] = int(m.group(3)); continue
        m = re.search(r"\[BE\]\[COMMIT\] cycle=(\d+) .*tag=(\S+)", line)
        if m and m.group(2) in cur:
            inst[cur[m.group(2)]].setdefault("P4", int(m.group(1)))
    od = subprocess.run([str(TC / "riscv64-unknown-elf-objdump"), "-d", str(elf)],
                        capture_output=True, text=True).stdout
    jpc = dpc = None
    for line in od.split("\n"):
        m = re.match(r"^\s+([0-9a-f]+):\s+([0-9a-f]{8})\s+(\w+)", line)
        if not m:
            continue
        rd = (int(m.group(2), 16) >> 7) & 31
        if m.group(3) == "jalr" and rd == 5:
            jpc = int(m.group(1), 16)
        if m.group(3) == "add" and rd == 6 and dpc is None:
            dpc = int(m.group(1), 16)
    js = sorted([e for e in inst.values() if e["pc"] == jpc], key=lambda e: e["P1"])
    ds = sorted([e for e in inst.values() if e["pc"] == dpc], key=lambda e: e["P1"])
    pred = [e for e in js if e.get("mis") == 0]
    j2 = pred[-1] if pred else {}
    cand = [e for e in ds if j2 and e["P1"] >= j2["P1"] and "P4" in e]
    d2 = cand[0] if cand else {}
    got = (d2.get("P1", 0) - j2.get("P1", 0)) if (d2 and j2) else None
    gap = (j2.get("P3", 0) - j2.get("P2", 0)) if ("P3" in j2 and "P2" in j2) else None
    print("  %-24s 填充物 %s×%-2d  实测 δ=%-3s (期望 %d)  jalr mis=%s gap=%s  dep 提交=%s  %s"
          % (cid, kind, n, got, delta, j2.get("mis", "-"), gap, "是" if "P4" in (d2 or {}) else "否",
             "通过" if (got == delta and j2.get("mis") == 0 and gap == 1 and "P4" in (d2 or {}))
             else "未通过"))
