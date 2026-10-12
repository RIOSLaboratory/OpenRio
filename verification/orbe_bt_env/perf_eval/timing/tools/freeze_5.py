"""把 4 条已找到配方的用例按 token 级完整条件复核后固化。"""
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

# 每条：骨架、要定位的指令、MUX、以及 token 级附加条件
CASES = {
    "INT2_G3P3_G1P3": dict(
        body=["mul x6, x3, x4", "F", "ld x7, 0(x8)", "F", "add x20, x7, x6"],
        want=dict(MUL=("mul", 6), OTH=("ld", 7), DEP=("add", 20)),
        mux="P1", oth_group=3, oth_p3_is_res=True),
    "INT2_G1P3_IMM": dict(
        body=["mul x6, x3, x4", "F", "addi x20, x6, 16"],
        want=dict(MUL=("mul", 6), DEP=("addi", 20)),
        mux="P1"),
    "INT2_ARF_G1P3": dict(
        body=["add x10, x1, x2", "F", "mul x6, x3, x4", "F", "add x20, x10, x6"],
        want=dict(MUL=("mul", 6), OTH=("add", 10), DEP=("add", 20)),
        mux="P1", arf_before=True),
    "INT2_P2_ISQ_STORED_G1P3": dict(
        body=["add x10, x1, x2", "F", "mul x6, x3, x4", "F", "add x20, x10, x6"],
        want=dict(MUL=("mul", 6), OTH=("add", 10), DEP=("add", 20)),
        mux="P2", stored_by_dispatch=True),
}

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
        for key, (wmn, wrd) in want.items():
            if key not in got and m.group(3) == wmn and rd == wrd:
                got[key] = int(m.group(1), 16)
    return got


def run(name, text, outdir):
    src = outdir / (name + ".S")
    elf = WORK / "elf" / (name + ".elf")
    src.write_text(SRC.format(body=SETUP + text), encoding="utf-8")
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


def evaluate(p, tt, spec, txt):
    c = bypc = p.get(tt.get("MUL"), {})
    q = p.get(tt.get("DEP"), {})
    o = p.get(tt.get("OTH"), {}) if "OTH" in tt else {}
    res = q.get("P1") if spec["mux"] == "P1" else q.get("P2")
    reasons = []
    if c.get("P3") is None or c.get("P3") != res:
        reasons.append("mul.P3=%s != 解析拍(%s)=%s" % (c.get("P3"), spec["mux"], res))
    if (c.get("P3", 0) - c.get("P2", 0)) != 3:
        reasons.append("mul 写回不干净")
    if spec.get("oth_p3_is_res") and o.get("P3") != res:
        reasons.append("搭档.P3=%s != %s" % (o.get("P3"), res))
    if "oth_group" in spec and o.get("grp") != spec["oth_group"]:
        reasons.append("搭档落在 group %s，应为 %s" % (o.get("grp"), spec["oth_group"]))
    if spec.get("arf_before") and not (o.get("P4", 10 ** 9) < (res or 0)):
        reasons.append("ARF 源未在解析拍前提交 (P4=%s)" % o.get("P4"))
    if spec.get("stored_by_dispatch") and not (o.get("P3", 10 ** 9) <= (q.get("P1") or -1)):
        reasons.append("存储源在其派发前未就绪 (P3=%s, dep.P1=%s)" % (o.get("P3"), q.get("P1")))
    if "is_good=1" not in txt:
        reasons.append("模型未正常退出")
    return reasons


for cid, spec in CASES.items():
    nf = sum(1 for x in spec["body"] if x == "F")
    print("=== %s" % cid)
    frozen = None
    for a in range(0, 7):
        for b in range(0, 9):
            fills = [a, b] if nf == 2 else [a]
            p, txt, elf = run("FV_%s_%d_%d" % (cid, a, b), build(spec["body"], fills), WORK / "cases")
            if not p or not txt:
                continue
            tt = targets(elf, spec["want"])
            if len(tt) != len(spec["want"]):
                continue
            reasons = evaluate(p, tt, spec, txt)
            if not reasons:
                frozen = (a, b)
                print("   全部条件通过：a=%d b=%d" % (a, b))
                print("   mul.P1=%s P2=%s P3=%s | 搭档.P1=%s grp=%s P3=%s P4=%s | dep.P1=%s P2=%s"
                      % (p[tt["MUL"]].get("P1"), p[tt["MUL"]].get("P2"), p[tt["MUL"]].get("P3"),
                         p[tt["OTH"]].get("P1") if "OTH" in tt else "-",
                         p[tt["OTH"]].get("grp") if "OTH" in tt else "-",
                         p[tt["OTH"]].get("P3") if "OTH" in tt else "-",
                         p[tt["OTH"]].get("P4") if "OTH" in tt else "-",
                         p[tt["DEP"]].get("P1"), p[tt["DEP"]].get("P2")))
                break
        if frozen:
            break
    if not frozen:
        print("   未找到满足全部条件的配方")
        continue
    a, b = frozen
    fills = [a, b] if nf == 2 else [a]
    p, txt, _ = run(cid, build(spec["body"], fills), FROZEN)
    tt = targets(WORK / "elf" / (cid + ".elf"), spec["want"])
    reasons = evaluate(p, tt, spec, txt)
    print("   固化到 calibrated_cases/%s.S  复核: %s" % (cid, "通过" if not reasons else reasons))
    print()
