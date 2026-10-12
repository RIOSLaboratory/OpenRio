"""JALR 作 producer 的可行性扫描。

关键修法：跳转目标寄存器 must be initialized，且 target = JALR 的下一条指令，
这样重定向落到落空路径，dependent 在架构正确路径上，程序不会跑到地址 0。

对每个 filler 条数，记录：
  jalr 的 P1/P2/P3 与写回间隔（干净应为 1，报告 §3.1 的 JALR link 口径）
  dependent 的首次 P1 尝试、P2
  delta = dep.P1 - jalr.P1
  delta 是否落在 JALR 的阶梯 0..4 内
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


def fillers(kind, n):
    if kind == "addi":
        return "".join("    addi x%d, x0, 1\n" % (21 + i) for i in range(n))
    if kind == "ld":
        return "".join("    ld   x%d, 0(x12)\n" % (21 + i) for i in range(n))
    if kind == "fadd":
        return "".join("    fadd.s f%d, f1, f2\n" % (21 + i) for i in range(n))
    if kind == "bne":
        return "".join("    bne  x0, x0, %df\n%d:\n" % (20 + i, 20 + i) for i in range(n))
    raise ValueError(kind)


def run(tag, body):
    name = "JC_%s" % tag
    src = WORK / "cases" / (name + ".S")
    elf = WORK / "elf" / (name + ".elf")
    src.write_text(body, encoding="utf-8")
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
    od = subprocess.run([str(OD), "-d", str(elf)], capture_output=True, text=True).stdout
    pj = pd = None
    for line in od.split("\n"):
        m = re.match(r"^\s+([0-9a-f]+):\s+([0-9a-f]{8})\s+(\w+)", line)
        if not m:
            continue
        rd = (int(m.group(2), 16) >> 7) & 0x1F
        if m.group(3) == "jalr" and rd == 5 and pj is None:
            pj = int(m.group(1), 16)
        if m.group(3) in ("add", "mul") and rd == 6 and pd is None:
            pd = int(m.group(1), 16)
    cur, dyn, seq = {}, {}, 0
    for line in txt.split("\n"):
        m = re.search(r"\[BE\]\[DECODE\] cycle=(\d+) .*tag=(\S+) .*pc=(\S+)", line)
        if m:
            seq += 1
            cur[m.group(2)] = seq
            dyn[seq] = dict(pc=int(m.group(3), 16), P1=int(m.group(1)), fst=True)
            continue
        m = re.search(r"\[ISQ_FIRE\] cycle=(\d+) group=(\d+) tag=(\S+)", line)
        if m and cur.get(m.group(3)) in dyn:
            dyn[cur[m.group(3)]].setdefault("P2", int(m.group(1)))
            dyn[cur[m.group(3)]]["grp"] = int(m.group(2)); continue
        m = re.search(r"\[P3_BYPASS\] cycle=(\d+) lane=(\d+) tag=(\S+)", line)
        if m and cur.get(m.group(3)) in dyn:
            dyn[cur[m.group(3)]].setdefault("P3", int(m.group(1)))
            dyn[cur[m.group(3)]]["lane"] = int(m.group(2)); continue
        m = re.search(r"\[BE\]\[COMMIT\] cycle=(\d+) .*tag=(\S+)", line)
        if m and cur.get(m.group(2)) in dyn:
            dyn[cur[m.group(2)]].setdefault("P4", int(m.group(1)))
    first = {}
    for e in sorted(dyn.values(), key=lambda x: x["P1"]):
        first.setdefault(e["pc"], e)          # 每个 pc 的首次派发即"首次 P1 尝试"
    return first.get(pj, {}), first.get(pd, {}), txt


for consumer, dep_ins in (("JALR->ALU", "    add  x6, x5, x3\n"),
                          ("JALR->MUL", "    mul  x6, x5, x3\n")):
    print("################ %s（消费者任意，先试 ALU 再试 MUL）" % consumer)
    for kind in ("addi", "bne", "ld", "fadd"):
        print("  --- 填充物 %s ---" % kind)
        for n in range(0, 11):
            body = HEAD + fillers(kind, n) + dep_ins + TAIL
            if kind in ("ld",):
                body = body.replace("    la   x29, tohost\n",
                                    "    la   x12, scratch\n    la   x29, tohost\n")
            j, d, txt = run("%s_%s_%d" % (consumer.split("->")[1], kind, n), body)
            if j is None or d is None or "P1" not in d:
                print("    %2d: dependent 未派发" % n); continue
            gap = (j.get("P3", 0) - j.get("P2", 0)) if "P3" in j else None
            delta = d["P1"] - j["P1"]
            rd_ok = ("REDIRECT" in txt)
            print("    %2d: delta=%-3d jalr P1=%-3s P2=%-3s P3=%-3s gap=%-3s dep P1=%-3s P2=%-3s %s"
                  % (n, delta, j.get("P1"), j.get("P2"), j.get("P3"), gap, d.get("P1"),
                     d.get("P2"), "有重定向" if rd_ok else "无重定向"))
    print()
