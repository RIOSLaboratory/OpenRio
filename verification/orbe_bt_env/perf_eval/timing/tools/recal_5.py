"""用分支填充物重标定含 G1 MUL 的混合源用例。

每一行的要求都是同一件事：G1 那条 MUL 的 P3 必须落在 dependent 的解析拍上
（P1 MUX 行是 dep.P1，P2 MUX 行是 dep.P2），且 MUL 自己的写回不能被抢。
填充物一律用永不跳转的分支，避免落到 G1。
"""
import re
import subprocess
from pathlib import Path

ENV = Path("/work/home/danielle/workspace/suncheek/model/OpenRio/verification/orbe_bt_env")
FROZEN = ENV / "perf_eval/timing/calibrated_cases"
WORK = Path("/work/home/danielle/workspace/suncheek/model/perf_eval_work/filler_exp")
TC = Path("/work/stu/yzhang/workspace/riscv/bin")
GCC, OD = TC / "riscv64-unknown-elf-gcc", TC / "riscv64-unknown-elf-objdump"
COSIM = ENV / "tools/verilator_cosim.sh"
LINK = ENV / "perf_eval/templates/link.ld"
TAG, DUT = "timing_delta", "rtl_v1"

# 每条用例：程序骨架（"F" 表示该处放填充物）、要定位的指令、MUX 类别
CASES = {
    "INT2_G1P3_G0P3": dict(
        body=["mul x6, x3, x4", "F", "add x5, x1, x2", "F", "add x20, x6, x5"],
        want=dict(MUL=("mul", 6), OTH=("add", 5), DEP=("add", 20)),
        mux="P1", twoP3=True),
    "INT2_G3P3_G1P3": dict(
        body=["mul x6, x3, x4", "F", "ld x7, 0(x8)", "F", "add x20, x7, x6"],
        want=dict(MUL=("mul", 6), OTH=("ld", 7), DEP=("add", 20)),
        mux="P1", twoP3=True),
    "INT2_G1P3_IMM": dict(
        body=["mul x6, x3, x4", "F", "addi x20, x6, 16"],
        want=dict(MUL=("mul", 6), DEP=("addi", 20)),
        mux="P1", twoP3=False),
    "INT2_ARF_G1P3": dict(
        body=["add x10, x1, x2", "F", "mul x6, x3, x4", "F", "add x20, x10, x6"],
        want=dict(MUL=("mul", 6), OTH=("add", 10), DEP=("add", 20)),
        mux="P1", twoP3=False),
    "INT2_P2_ISQ_STORED_G1P3": dict(
        body=["add x10, x1, x2", "F", "mul x6, x3, x4", "F", "add x20, x10, x6"],
        want=dict(MUL=("mul", 6), OTH=("add", 10), DEP=("add", 20)),
        mux="P2", twoP3=False),
}

# 地址寄存器用 x8（G3P3 那行的 load 需要），不与任何用例的寄存器冲突
SETUP = """    addi x1, zero, 1
    addi x2, zero, 2
    addi x3, zero, 3
    addi x4, zero, 4
    la   x8, scratch
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
BR = "    bne  x0, x0, 7f\n7:\n"


def build(body, fills):
    """把骨架里的 F 依次替换成指定条数的分支填充物"""
    it = iter(fills)
    out = []
    for item in body:
        out.append(BR * next(it) if item == "F" else "    " + item)
    return "\n".join(out) + "\n"


def targets(elf, want):
    out = subprocess.run([str(OD), "-d", str(elf)], capture_output=True, text=True).stdout
    got = {}
    for line in out.split("\n"):
        m = re.match(r"^\s+([0-9a-f]+):\s+([0-9a-f]{8})\s+(\w+)", line)
        if not m:
            continue
        rd = (int(m.group(2), 16) >> 7) & 0x1F
        mn = m.group(3)
        for key, (wmn, wrd) in want.items():
            if key not in got and mn == wmn and rd == wrd:
                got[key] = int(m.group(1), 16)
    return got


def run(name, text):
    src = WORK / "cases" / (name + ".S")
    elf = WORK / "elf" / (name + ".elf")
    src.write_text(SRC.format(body=text), encoding="utf-8")
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
        m = re.search(r"\[P3_BYPASS\] cycle=(\d+) lane=\d+ tag=(\S+)", line)
        if m and cur.get(m.group(2)) in dyn:
            dyn[cur[m.group(2)]]["P3"] = int(m.group(1)); continue
        m = re.search(r"\[BE\]\[COMMIT\] cycle=(\d+) .*tag=(\S+)", line)
        if m and cur.get(m.group(2)) in dyn:
            dyn[cur[m.group(2)]]["P4"] = int(m.group(1))
    bypc = {}
    for e in dyn.values():
        bypc.setdefault(e["pc"], e)
    return bypc, txt, elf


def check(bypc, p, spec):
    c = bypc.get(p.get("MUL"), {})
    q = bypc.get(p.get("DEP"), {})
    o = bypc.get(p.get("OTH"), {}) if "OTH" in p else {}
    res = q.get("P1") if spec["mux"] == "P1" else q.get("P2")
    ok = (c.get("P3") is not None and c.get("P3") == res)
    if spec["twoP3"]:
        ok = ok and (o.get("P3") == res)
    if spec["mux"] == "P1":
        ok = ok and (q.get("P1") is not None)
    clean = (c.get("P3", 0) - c.get("P2", 0)) == 3
    return ok, clean, dict(mulP3=c.get("P3"), othP3=o.get("P3"), depP1=q.get("P1"),
                           depP2=q.get("P2"), mulP1=c.get("P1"), mulP2=c.get("P2"))


for cid, spec in CASES.items():
    nf = sum(1 for x in spec["body"] if x == "F")
    print("=== %s（%s MUX，%d 处填充物）" % (cid, spec["mux"], nf))
    found = None
    for a in range(0, 7):
        for b in range(0, 9):
            fills = [a, b] if nf == 2 else [a]
            p, txt, elf = run("RC_%s_%d_%d" % (cid, a, b), build(spec["body"], fills))
            if not p or not txt:
                continue
            tt = targets(elf, spec["want"])
            if len(tt) != len(spec["want"]):
                continue
            ok, clean, m = check(p, tt, spec)
            if ok and clean:
                found = (a, b)
                print("   配方 a=%d b=%d  mul.P1=%s P2=%s P3=%s  %s.P3=%s  dep.P1=%s P2=%s"
                      % (a, b, m["mulP1"], m["mulP2"], m["mulP3"],
                         "搭档" if spec["twoP3"] else "-", m["othP3"], m["depP1"], m["depP2"]))
                break
        if found:
            break
    if not found:
        print("   未找到配方（扫描 a=0..6, b=0..8）")
    print()
