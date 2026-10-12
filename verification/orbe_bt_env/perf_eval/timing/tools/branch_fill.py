import re, subprocess
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
COMMIT = "    ld   x6, 0(x10)"      # 提交侧 LOAD（G3）
BYPASS = "    mul  x8, x1, x2"      # 旁路侧 MUL（G1）


def branches(k):
    """永不跳转的分支作填充物：x0 == x0 恒成立，bne 从不发生"""
    return ("    bne  x0, x0, 7f\n7:\n" * k)


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
    txt = log.read_text(errors="replace")
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
        m = re.search(r"\[P3_BYPASS\] cycle=(\d+) lane=\d+ tag=(\S+)", line)
        if m and cur.get(m.group(2)) in dyn:
            dyn[cur[m.group(2)]]["P3"] = int(m.group(1)); continue
        m = re.search(r"\[BE\]\[COMMIT\] cycle=(\d+) .*tag=(\S+)", line)
        if m and cur.get(m.group(2)) in dyn:
            dyn[cur[m.group(2)]]["P4"] = int(m.group(1))
    bypc = {}
    for e in dyn.values():
        bypc.setdefault(e["pc"], e)
    return bypc, dyn, txt


def run(tag, body):
    name = "BR_%s" % tag
    src = WORK / "cases" / (name + ".S")
    elf = WORK / "elf" / (name + ".elf")
    src.write_text(SRC.format(body=body), encoding="utf-8")
    r = subprocess.run([str(GCC), "-march=rv64imafdc", "-mabi=lp64d", "-nostdlib",
                        "-nostartfiles", "-Wl,-T," + str(LINK), "-o", str(elf), str(src)],
                       capture_output=True, text=True)
    if r.returncode:
        print("      编译失败: %s" % r.stderr.strip()[:90])
        return None, None
    p = pcs(elf)
    subprocess.run([str(COSIM), "run", "--no-build", "--dut-kind", DUT, "--tag", TAG,
                    "--verbosity", "2", "--timeout", "20000", "--tc", str(elf)],
                   capture_output=True, text=True)
    out = ev(name)
    return p, out


print("=== 提交侧 LOAD / 旁路侧 MUL / 填充物 = 永不跳转的分支（G0 固定，lane 0）")
for k in (1, 2, 3):
    print("   k=%d" % k)
    print("     m | ld.P4 | mul.P3 | dep.P1 | 三点同拍 | 正常退出")
    for m in range(0, 10):
        body = (SETUP + COMMIT + "\n" + branches(k) + BYPASS + "\n" + branches(m)
                + "    add  x20, x6, x8\n")
        p, out = run("k%dm%d" % (k, m), body)
        if not out:
            continue
        bypc, dyn, txt = out
        c = bypc.get(p.get("C"), {})
        b = bypc.get(p.get("P"), {})
        q = bypc.get(p.get("DEP"), {})
        ok = (c.get("P4") == b.get("P3") == q.get("P1"))
        print("     %-3d %-6s %-7s %-7s %-8s %s" %
              (m, c.get("P4"), b.get("P3"), q.get("P1"),
               "是" if ok else "", "是" if "is_good=1" in txt else "否"))
