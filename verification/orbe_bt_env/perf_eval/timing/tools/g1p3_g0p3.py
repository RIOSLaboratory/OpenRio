"""重标定 INT2_G1P3_G0P3：把 G0 P3 一侧从 ALU 换成 DIV，填充物用 lane 2/3 的 ld 与 fadd.s。

要求三个量落在同一拍：div.P3（G0 lane 0）、mul.P3（G1 lane 1）、dep.P1。
两段扫描：先扫两个生产者之间的 (n_ld, n_fp) 使两边界相等，再扫 dependent 前的使 dep.P1 落在该拍。
"""
import re
import subprocess
from pathlib import Path

ENV = Path("/work/home/danielle/workspace/suncheek/model/OpenRio/verification/orbe_bt_env")
WORK = Path("/work/home/danielle/workspace/suncheek/model/perf_eval_work/filler_exp")
TC = Path("/work/stu/yzhang/workspace/riscv/bin")
GCC, OD = TC / "riscv64-unknown-elf-gcc", TC / "riscv64-unknown-elf-objdump"
COSIM = ENV / "tools/verilator_cosim.sh"
LINK = ENV / "perf_eval/templates/link.ld"
TAG, DUT = "timing_delta", "rtl_v1"

SETUP = """    addi x1, zero, 1
    addi x2, zero, 2
    addi x3, zero, 3
    addi x4, zero, 4
    li   x7, 0x6000
    csrs mstatus, x7
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

DIV_I = "    div  x6, x3, x4"
MUL_I = "    mul  x8, x1, x2"
DEP_I = "    add  x20, x6, x8"


def fill(n_ld, n_fp):
    rows = ["    ld   x%d, 0(x10)" % (21 + i) for i in range(n_ld)] + \
           ["    fadd.s f%d, f1, f2" % (21 + i) for i in range(n_fp)]
    return "\n".join(rows) + ("\n" if rows else "")


def pcs(elf):
    out = subprocess.run([str(OD), "-d", str(elf)], capture_output=True, text=True).stdout
    got = {}
    for line in out.split("\n"):
        m = re.match(r"^\s+([0-9a-f]+):\s+([0-9a-f]{8})\s+(\w+)", line)
        if not m:
            continue
        rd = (int(m.group(2), 16) >> 7) & 0x1F
        pc = int(m.group(1), 16)
        if m.group(3) == "div" and rd == 6:
            got["DIV"] = pc
        if m.group(3) == "mul" and rd == 8:
            got["MUL"] = pc
        if m.group(3) == "add" and rd == 20 and "DEP" not in got:
            got["DEP"] = pc
    return got


def run(tag, body):
    name = "GG_%s" % tag
    src = WORK / "cases" / (name + ".S")
    elf = WORK / "elf" / (name + ".elf")
    src.write_text(SRC.format(body=body), encoding="utf-8")
    r = subprocess.run([str(GCC), "-march=rv64imafdc", "-mabi=lp64d", "-nostdlib",
                        "-nostartfiles", "-Wl,-T," + str(LINK), "-o", str(elf), str(src)],
                       capture_output=True, text=True)
    if r.returncode:
        return None, None, None
    subprocess.run([str(COSIM), "run", "--no-build", "--dut-kind", DUT, "--tag", TAG,
                    "--verbosity", "2", "--timeout", "20000", "--tc", str(elf)],
                   capture_output=True, text=True)
    log = ENV / "sim" / ("verilator_" + TAG) / "log" / DUT / (name + "_1") / "sim.log"
    if not log.exists():
        return None, None, None
    txt = log.read_text(errors="replace")
    cur, dyn, seq = {}, {}, 0
    for line in txt.split("\n"):
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
        m = re.search(r"\[P3_BYPASS\] cycle=(\d+) lane=(\d+) tag=(\S+)", line)
        if m and cur.get(m.group(3)) in dyn:
            dyn[cur[m.group(3)]]["P3"] = int(m.group(1))
            dyn[cur[m.group(3)]]["lane"] = int(m.group(2)); continue
        m = re.search(r"\[BE\]\[COMMIT\] cycle=(\d+) .*tag=(\S+)", line)
        if m and cur.get(m.group(2)) in dyn:
            dyn[cur[m.group(2)]]["P4"] = int(m.group(1))
    bypc = {}
    for e in dyn.values():
        bypc.setdefault(e["pc"], e)
    return bypc, txt, elf


def main(order):
    """order: 'div_first' 或 'mul_first'"""
    print("=== 生产者顺序：%s（G0 侧 DIV，G1 侧 MUL）" % order)
    first, second = (DIV_I, MUL_I) if order == "div_first" else (MUL_I, DIV_I)

    # --- 第一段：扫两生产者之间，找两边界同拍 ---
    hits = []
    for n_ld in range(0, 5):
        for n_fp in range(0, 5):
            body = SETUP + first + "\n" + fill(n_ld, n_fp) + second + "\n" + DEP_I + "\n"
            bypc, txt, elf = run("s1_%s_%d_%d" % (order, n_ld, n_fp), body)
            if not bypc:
                continue
            p = pcs(elf)
            d, m = bypc.get(p.get("DIV"), {}), bypc.get(p.get("MUL"), {})
            if d.get("P3") is not None and d.get("P3") == m.get("P3"):
                clean = (d.get("P3", 0) - d.get("P2", 0)) == 4 and (m.get("P3", 0) - m.get("P2", 0)) == 3
                hits.append((n_ld, n_fp, d["P3"], clean))
    print("   两边界同拍的间隔: %s" % (hits if hits else "无"))
    good = [h for h in hits if h[3]]
    if not good:
        print("   （同拍者中没有一个让两个生产者写回都干净）")
        return
    n_ld, n_fp, cycle, _ = good[0]
    print("   取间隔 (%d ld, %d fp)，汇合拍 %d，扫 dependent 前:" % (n_ld, n_fp, cycle))

    # --- 第二段：扫 dependent 前，找 dep.P1 落在该拍 ---
    found = []
    for m_ld in range(0, 5):
        for m_fp in range(0, 5):
            body = (SETUP + first + "\n" + fill(n_ld, n_fp) + second + "\n"
                    + fill(m_ld, m_fp) + DEP_I + "\n")
            bypc, txt, elf = run("s2_%s_%d_%d_%d_%d" % (order, n_ld, n_fp, m_ld, m_fp), body)
            if not bypc:
                continue
            p = pcs(elf)
            d, m, q = (bypc.get(p.get("DIV"), {}), bypc.get(p.get("MUL"), {}),
                       bypc.get(p.get("DEP"), {}))
            ok = (d.get("P3") == m.get("P3") == q.get("P1"))
            if ok and "is_good=1" in txt:
                found.append((m_ld, m_fp, d.get("P3")))
    print("   三点同拍的 dependent 前间隔: %s" % (found if found else "无"))


for order in ("div_first", "mul_first"):
    main(order)
    print()
