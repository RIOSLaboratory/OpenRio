"""JALR 作 producer：区分投机派发与真正提交的派发。

只有当"最终提交的那个实例"的 delta 落在阶梯 0..4 内，该行才算可构造。
同时对比 ALU 消费者与 MUL 消费者（消费者的组不同，可能改变可达性）。
"""
import re
import subprocess
from pathlib import Path

ENV = Path("/work/home/danielle/workspace/suncheek/model/OpenRio/verification/or_cosim")
WORK = Path("/work/home/danielle/workspace/suncheek/model/perf_eval_work/filler_exp")
TC = Path("/work/stu/yzhang/workspace/riscv/bin")
GCC, OD = TC / "riscv64-unknown-elf-gcc", TC / "riscv64-unknown-elf-objdump"
COSIM = ENV / "tools/verilator_cosim.sh"
LINK = ENV / "perf_eval/templates/link.ld"
TAG, DUT = "timing_delta", "rtl_v1"

HEAD = """    addi x1, zero, 1
    addi x2, zero, 2
    addi x3, zero, 3
    addi x4, zero, 4
    la   x29, tohost
    addi x28, zero, 1
    la   x10, after
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
    if not log.exists():
        return None, None
    return log.read_text(errors="replace"), elf


for dep_mn, label in (("add", "JALR->ALU"), ("mul", "JALR->MUL")):
    print("################ %s" % label)
    for n in range(0, 10):
        body = HEAD + "".join("    addi x%d, x0, 1\n" % (21 + i) for i in range(n)) \
            + "    %s  x6, x5, x3\n" % dep_mn + TAIL
        txt, elf = run("JK_%s_%d" % (dep_mn, n), body)
        if txt is None:
            print("  n=%-2d 无日志" % n); continue
        od = subprocess.run([str(OD), "-d", str(elf)], capture_output=True, text=True).stdout
        pj = pd = None
        for line in od.split("\n"):
            m = re.match(r"^\s+([0-9a-f]+):\s+([0-9a-f]{8})\s+(\w+)", line)
            if not m:
                continue
            rd = (int(m.group(2), 16) >> 7) & 0x1F
            if m.group(3) == "jalr" and rd == 5 and pj is None:
                pj = int(m.group(1), 16)
            if m.group(3) == dep_mn and rd == 6 and pd is None:
                pd = int(m.group(1), 16)
        inst, cur, seq = {}, {}, 0
        for line in txt.split("\n"):
            m = re.search(r"\[BE\]\[DECODE\] cycle=(\d+) .*tag=(\S+) .*pc=(\S+)", line)
            if m:
                seq += 1
                cur[m.group(2)] = seq
                inst[seq] = dict(pc=int(m.group(3), 16), events=[("P1", int(m.group(1))),
                                                                 ("tag", m.group(2))])
                continue
            m = re.search(r"\[ISQ_FIRE\] cycle=(\d+) group=(\d+) tag=(\S+)", line)
            if m and m.group(3) in cur:
                inst[cur[m.group(3)]]["events"].append(("P2", int(m.group(1)))); continue
            m = re.search(r"\[P3_BYPASS\] cycle=(\d+) lane=(\d+) tag=(\S+)", line)
            if m and m.group(3) in cur:
                inst[cur[m.group(3)]]["events"].append(("P3", int(m.group(1)))); continue
            m = re.search(r"\[BE\]\[COMMIT\] cycle=(\d+) .*tag=(\S+)", line)
            if m and m.group(2) in cur:
                inst[cur[m.group(2)]]["events"].append(("P4", int(m.group(1))))
        jalr = next((e for e in inst.values() if e["pc"] == pj), None)
        deps = [e for e in inst.values() if e["pc"] == pd]
        if not jalr or not deps:
            print("  n=%-2d 事件缺失" % n); continue
        jp1 = [c for k, c in jalr["events"] if k == "P1"][0]
        desc, best = [], None
        for e in deps:
            p1 = [c for k, c in e["events"] if k == "P1"][0]
            committed = any(k == "P4" for k, _ in e["events"])
            d = p1 - jp1
            desc.append("%d%s" % (d, "✓" if committed else "×"))
            if committed and (best is None or d < best):
                best = d
        ok = best is not None and 0 <= best <= 4
        print("  n=%-2d 各次派发(delta, 提交?): %-24s 提交实例最小 delta=%-4s %s"
              % (n, " ".join(desc), best, "← 落在 0..4 内" if ok else ""))
    print()
