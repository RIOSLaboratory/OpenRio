import re, subprocess
from pathlib import Path

ENV = Path("/work/home/danielle/workspace/suncheek/model/OpenRio/verification/or_cosim")
WORK = Path("/work/home/danielle/workspace/suncheek/model/perf_eval_work/filler_exp")
TC = Path("/work/stu/yzhang/workspace/riscv/bin")
GCC, OD = TC / "riscv64-unknown-elf-gcc", TC / "riscv64-unknown-elf-objdump"
COSIM = ENV / "tools/verilator_cosim.sh"
LINK = ENV / "perf_eval/templates/link.ld"
TAG, DUT = "timing_delta", "rtl_v1"

POOL = [21, 22, 23, 24, 25, 26, 27, 30, 31, 5, 7, 9, 11, 12]
SETUP = """    addi x1, zero, 1
    addi x2, zero, 2
    addi x3, zero, 3
    addi x4, zero, 4
    la   x10, scratch
    la   x29, tohost
    addi x28, zero, 1
"""
TAIL = """pass:
    sd   x28, 0(x29)
9:  wfi
    j    9b
.section .data
scratch: .quad 0
"""
SRC = ".option norvc\n.section .text\n.globl _start\n_start:\n{body}\n" + TAIL
COMMIT = "    ld   x6, 0(x10)"
BYPASS = "    mul  x8, x1, x2"


def chain(k, start):
    out = []
    for i in range(k):
        rd = POOL[start + i]
        rs = "x0" if i == 0 else "x%d" % POOL[start + i - 1]
        out.append("    addi x%d, %s, 1" % (rd, rs))
    return "\n".join(out) + ("\n" if k else "")


def pcs(elf):
    out = subprocess.run([str(OD), "-d", str(elf)], capture_output=True, text=True).stdout
    got = {}
    for line in out.split("\n"):
        m = re.match(r"^\s+([0-9a-f]+):\s+([0-9a-f]{8})\s+(\w+)", line)
        if not m:
            continue
        rd = (int(m.group(2), 16) >> 7) & 0x1F
        pc = int(m.group(1), 16)
        if m.group(3) == "ld" and rd == 6 and "C" not in got:
            got["C"] = pc
        if m.group(3) == "mul" and rd == 8 and "P" not in got:
            got["P"] = pc
        if m.group(3) == "add" and rd == 20 and "DEP" not in got:
            got["DEP"] = pc
    return got


def ev(name):
    log = ENV / "sim" / ("verilator_" + TAG) / "log" / DUT / (name + "_1") / "sim.log"
    if not log.exists():
        return None
    cur, dyn, seq = {}, {}, 0
    for line in log.read_text(errors="replace").split("\n"):
        m = re.search(r"\[BE\]\[DECODE\] cycle=(\d+) .*tag=(\S+) .*pc=(\S+)", line)
        if m:
            seq += 1
            cur[m.group(2)] = seq
            dyn[seq] = dict(pc=int(m.group(3), 16), P1=int(m.group(1)))
            continue
        m = re.search(r"\[ISQ_FIRE\] cycle=(\d+) group=(\d+) tag=(\S+)", line)
        if m and cur.get(m.group(3)) in dyn:
            dyn[cur[m.group(3)]]["grp"] = int(m.group(2))
            dyn[cur[m.group(3)]]["P2"] = int(m.group(1)); continue
        m = re.search(r"\[P3_BYPASS\] cycle=(\d+) lane=\d+ tag=(\S+)", line)
        if m and cur.get(m.group(2)) in dyn:
            dyn[cur[m.group(2)]]["P3"] = int(m.group(1)); continue
        m = re.search(r"\[BE\]\[COMMIT\] cycle=(\d+) .*tag=(\S+)", line)
        if m and cur.get(m.group(2)) in dyn:
            dyn[cur[m.group(2)]]["P4"] = int(m.group(1))
    bypc = {}
    for e in dyn.values():
        bypc.setdefault(e["pc"], e)
    return bypc, dyn


def run(tag, body):
    name = "DX_%s" % tag
    src = WORK / "cases" / (name + ".S")
    elf = WORK / "elf" / (name + ".elf")
    src.write_text(SRC.format(body=body), encoding="utf-8")
    r = subprocess.run([str(GCC), "-march=rv64imafdc", "-mabi=lp64d", "-nostdlib",
                        "-nostartfiles", "-Wl,-T," + str(LINK), "-o", str(elf), str(src)],
                       capture_output=True, text=True)
    if r.returncode:
        return None, None
    p = pcs(elf)
    subprocess.run([str(COSIM), "run", "--no-build", "--dut-kind", DUT, "--tag", TAG,
                    "--verbosity", "2", "--timeout", "20000", "--tc", str(elf)],
                   capture_output=True, text=True)
    return p, ev(name)


print("k=1，扫 m。同时看三条关键指令（含 group 与 issue 拍）")
print("  m | ld:    P1 grp P2 P3 P4 | mul:   P1 grp P2 P3 | dep:   P1 grp P2")
for m in range(0, 8):
    body = (SETUP + COMMIT + "\n" + chain(1, 0) + BYPASS + "\n" + chain(m, 1)
            + "    add  x20, x6, x8\n")
    p, out = run("d%d" % m, body)
    if not out:
        continue
    bypc, dyn = out
    c, b, q = bypc.get(p.get("C"), {}), bypc.get(p.get("P"), {}), bypc.get(p.get("DEP"), {})
    print("  %-2d | %-4s %-4s %-3s %-3s %-3s | %-4s %-4s %-3s %-3s | %-4s %-4s %-3s" %
          (m, c.get("P1"), c.get("grp"), c.get("P2"), c.get("P3"), c.get("P4"),
           b.get("P1"), b.get("grp"), b.get("P2"), b.get("P3"),
           q.get("P1"), q.get("grp"), q.get("P2")))
