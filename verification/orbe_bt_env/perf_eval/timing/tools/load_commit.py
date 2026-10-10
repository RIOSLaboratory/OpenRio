import re, subprocess
from pathlib import Path

ENV = Path("/work/home/danielle/workspace/suncheek/model/OpenRio/verification/orbe_bt_env")
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

COMMIT = "    ld   x6, 0(x10)"      # 提交侧：LOAD，固定 G3
BYPASS = "    mul  x8, x1, x2"      # 旁路侧：MUL，固定 G1


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
    name = "LG_%s" % tag
    src = WORK / "cases" / (name + ".S")
    elf = WORK / "elf" / (name + ".elf")
    src.write_text(SRC.format(body=body), encoding="utf-8")
    r = subprocess.run([str(GCC), "-march=rv64imafdc", "-mabi=lp64d", "-nostdlib",
                        "-nostartfiles", "-Wl,-T," + str(LINK), "-o", str(elf), str(src)],
                       capture_output=True, text=True)
    if r.returncode:
        print("      编译失败: %s" % r.stderr.strip()[:100])
        return None, None
    p = pcs(elf)
    subprocess.run([str(COSIM), "run", "--no-build", "--dut-kind", DUT, "--tag", TAG,
                    "--verbosity", "2", "--timeout", "20000", "--tc", str(elf)],
                   capture_output=True, text=True)
    out = ev(name)
    return p, out


print("=== 提交侧 LOAD(G3) / 旁路侧 MUL(G1) / dependent ALU，链式填充物")
print("   k    ld: P1 P2 P3 P4  (P4-P1)   mul: P1 P2 P3 grp  同拍?")
ks = []
for k in range(0, 8):
    body = SETUP + COMMIT + "\n" + chain(k, 0) + BYPASS + "\n    add  x20, x6, x8\n"
    p, out = run("k%d" % k, body)
    if not out:
        continue
    bypc, dyn = out
    c, b = bypc.get(p.get("C"), {}), bypc.get(p.get("P"), {})
    dd = (c.get("P4", 0) - c.get("P1", 0)) if (c.get("P4") and c.get("P1")) else None
    same = (c.get("P4") is not None and c.get("P4") == b.get("P3"))
    if same and dd == 5:
        ks.append((k, c["P4"]))
    print("   %-4d %-3s %-3s %-3s %-3s %-7s %-3s %-3s %-3s %-4s %s" %
          (k, c.get("P1"), c.get("P2"), c.get("P3"), c.get("P4"), dd,
           b.get("P1"), b.get("P2"), b.get("P3"), b.get("grp"), "是" if same else ""))
print("   干净且同拍的 k: %s" % (ks if ks else "无"))
if ks:
    k, cyc = ks[0]
    print("   取 k=%d（汇合拍 %d），扫 dependent 前的链节数 m:" % (k, cyc))
    good = []
    for m in range(0, 10):
        body = (SETUP + COMMIT + "\n" + chain(k, 0) + BYPASS + "\n" + chain(m, k)
                + "    add  x20, x6, x8\n")
        p, out = run("k%d_m%d" % (k, m), body)
        if not out:
            continue
        bypc, dyn = out
        c, b, q = bypc.get(p.get("C"), {}), bypc.get(p.get("P"), {}), bypc.get(p.get("DEP"), {})
        ok = (c.get("P4") == b.get("P3") == q.get("P1"))
        if ok:
            good.append(m)
        print("   m=%-3d ld.P4=%-4s mul.P3=%-4s dep.P1=%-4s %s" %
              (m, c.get("P4"), b.get("P3"), q.get("P1"), "三点同拍" if ok else ""))
    print("   三点同拍的 m: %s" % (good if good else "无"))
    if good:
        m = good[0]
        body = (SETUP + COMMIT + "\n" + chain(k, 0) + BYPASS + "\n" + chain(m, k)
                + "    add  x20, x6, x8\n")
        p, out = run("final", body)
        bypc, dyn = out
        print("   最终配方 k=%d m=%d 的完整时序：" % (k, m))
        for e in sorted(dyn.values(), key=lambda x: x["P1"]):
            print("      0x%-8x P1=%-4s grp=%-3s P2=%-4s P3=%-4s P4=%-4s" %
                  (e["pc"], e.get("P1"), e.get("grp", "-"), e.get("P2"),
                   e.get("P3", "-"), e.get("P4", "-")))
