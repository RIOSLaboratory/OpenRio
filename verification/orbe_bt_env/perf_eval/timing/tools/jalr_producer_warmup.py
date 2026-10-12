"""JALR 作 producer：尝试"预热"以让第二次 JALR 被预测，从而不再冲刷后面的指令。

warm-up 段先跳一次同目标，第二次才是被测生产者。若预测生效，dependent 的首次派发
就应当存活（有 P4），delta 可能落回 0..4。
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
    la   x29, tohost
    addi x28, zero, 1
"""
# 预热：先用 rd=x0 的 JALR 跳一次同目标（不写链接值）
WARM = """    la   x10, w1
    jalr x0, 0(x10)
w1:
"""
PROD = """    la   x10, after
    jalr x5, 0(x10)
after:
"""
TAIL = """pass:
    sd   x28, 0(x29)
9:  wfi
    j    9b
.section .data
scratch: .quad 0
"""


def build(warm):
    return (".option norvc\n.section .text\n.globl _start\n_start:\n" + SETUP
            + (WARM if warm else "") + PROD + "{fill}    add  x6, x5, x3\n" + TAIL)


def run(name, body):
    src = WORK / "cases" / (name + ".S")
    elf = WORK / "elf" / (name + ".elf")
    src.write_text(body, encoding="utf-8")
    if subprocess.run([str(GCC), "-march=rv64imafdc", "-mabi=lp64d", "-nostdlib", "-nostartfiles",
                       "-Wl,-T," + str(LINK), "-o", str(elf), str(src)],
                      capture_output=True, text=True).returncode:
        return None, None
    subprocess.run([str(COSIM), "run", "--no-build", "--dut-kind", DUT, "--tag", TAG,
                    "--verbosity", "2", "--timeout", "20000", "--tc", str(elf)],
                   capture_output=True, text=True)
    log = ENV / "sim" / ("verilator_" + TAG) / "log" / DUT / (name + "_1") / "sim.log"
    return (log.read_text(errors="replace"), elf) if log.exists() else (None, None)


for warm in (False, True):
    print("################ %s" % ("有预热" if warm else "无预热"))
    for n in range(0, 6):
        body = build(warm).format(fill="".join("    addi x%d, x0, 1\n" % (21 + i)
                                               for i in range(n)))
        txt, elf = run("JW_%d_%d" % (warm, n), body)
        if txt is None:
            print("  n=%d 无日志" % n); continue
        od = subprocess.run([str(OD), "-d", str(elf)], capture_output=True, text=True).stdout
        pcs = []
        for line in od.split("\n"):
            m = re.match(r"^\s+([0-9a-f]+):\s+([0-9a-f]{8})\s+(\w+)", line)
            if not m:
                continue
            rd = (int(m.group(2), 16) >> 7) & 0x1F
            if m.group(3) == "jalr" and rd == 5:
                pcs.append(("prod_jalr", int(m.group(1), 16)))
            if m.group(3) == "add" and rd == 6:
                pcs.append(("dep", int(m.group(1), 16)))
        want = dict(pcs)
        inst, cur, seq = {}, {}, 0
        for line in txt.split("\n"):
            m = re.search(r"\[BE\]\[DECODE\] cycle=(\d+) .*tag=(\S+) .*pc=(\S+)", line)
            if m:
                seq += 1
                cur[m.group(2)] = seq
                inst[seq] = dict(pc=int(m.group(3), 16), ev=[("P1", int(m.group(1)))])
                continue
            m = re.search(r"\[ISQ_FIRE\] cycle=(\d+) group=(\d+) tag=(\S+)", line)
            if m and m.group(3) in cur:
                inst[cur[m.group(3)]]["ev"].append(("P2", int(m.group(1)))); continue
            m = re.search(r"\[P3_BYPASS\] cycle=(\d+) lane=(\d+) tag=(\S+)", line)
            if m and m.group(3) in cur:
                inst[cur[m.group(3)]]["ev"].append(("P3", int(m.group(1)))); continue
            m = re.search(r"\[BE\]\[COMMIT\] cycle=(\d+) .*tag=(\S+)", line)
            if m and m.group(2) in cur:
                inst[cur[m.group(2)]]["ev"].append(("P4", int(m.group(1))))
        jl = next((e for e in inst.values() if e["pc"] == want.get("prod_jalr")), None)
        deps = [e for e in inst.values() if e["pc"] == want.get("dep")]
        nred = len(re.findall(r"\[BE\]\[REDIRECT\]", txt))
        if not jl or not deps:
            print("  n=%d 事件缺失（重定向 %d）" % (n, nred)); continue
        jp1 = [c for k, c in jl["ev"] if k == "P1"][0]
        desc = []
        for e in deps:
            p1 = [c for k, c in e["ev"] if k == "P1"][0]
            cm = any(k == "P4" for k, _ in e["ev"])
            desc.append("%d%s" % (p1 - jp1, "✓" if cm else "×"))
        print("  n=%-2d 重定向=%d 派发(delta,提交?): %s" % (n, nred, " ".join(desc)))
    print()
