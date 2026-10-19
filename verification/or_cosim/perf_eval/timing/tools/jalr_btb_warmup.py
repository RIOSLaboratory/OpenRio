"""在 rtl_full 上验证：JALR 作 producer 时，第二次执行能否被 BTB 预测、不再 mispredict/冲刷。

要点：BTB 按 PC 索引，所以预热必须是**同一条 JALR**（同 PC、同目标）执行第二次。
程序让 JALR 在循环里执行两遍，第二遍才是被测的那次（其 rd=x5 供 dependent 使用）。
"""
import re
import subprocess
from pathlib import Path

ENV = Path("/work/home/danielle/workspace/suncheek/model/OpenRio/verification/or_cosim")
W = Path("/work/home/danielle/workspace/suncheek/model/perf_eval_work/filler_exp")
TC = Path("/work/stu/yzhang/workspace/riscv/bin")
LINK = ENV / "perf_eval/templates/link.ld"
TAG, DUT = "timing_full", "rtl_full"

body = """    .option norvc
    .section .text
    .globl _start
_start:
    addi x1, zero, 1
    addi x3, zero, 3
    la   x29, tohost
    addi x28, zero, 1
    la   x11, JT
    li   x12, 2
    addi x13, zero, 0
LOOP:
    mv   x10, x11
    jalr x5, 0(x10)
JT:
    addi x13, x13, 1
    addi x12, x12, -1
    bne  x12, x0, LOOP
    add  x6, x5, x3
pass:
    sd   x28, 0(x29)
1:  j    1b
.section .data
scratch: .quad 0
"""
src = W / "cases" / "JW2.S"
elf = W / "elf" / "JW2.elf"
src.write_text(body, encoding="utf-8")
r = subprocess.run([str(TC / "riscv64-unknown-elf-gcc"), "-march=rv64imafdc", "-mabi=lp64d",
                    "-nostdlib", "-nostartfiles", "-Wl,-T," + str(LINK), "-o", str(elf), str(src)],
                   capture_output=True, text=True)
assert r.returncode == 0, r.stderr[:300]
subprocess.run([str(ENV / "tools/verilator_cosim.sh"), "run", "--no-build", "--dut-kind", DUT,
                "--tag", TAG, "--verbosity", "2", "--timeout", "200000", "--tc", str(elf)],
               capture_output=True, text=True)

log = ENV / "sim" / ("verilator_" + TAG) / "log" / DUT / "JW2_1" / "sim.log"
txt = log.read_text(errors="replace")
od = subprocess.run([str(TC / "riscv64-unknown-elf-objdump"), "-d", str(elf)],
                    capture_output=True, text=True).stdout
jpc = None
for line in od.split("\n"):
    m = re.match(r"^\s+([0-9a-f]+):\s+([0-9a-f]{8})\s+(\w+)", line)
    if m and m.group(3) == "jalr":
        jpc = int(m.group(1), 16)
print("JALR 所在 pc = 0x%x（程序中只出现一次，但被循环执行两遍）" % jpc)
print()

cur, inst, seq = {}, {}, 0
for line in txt.split("\n"):
    m = re.search(r"\[BE\]\[DECODE\] cycle=(\d+) .*tag=(\S+) .*pc=(\S+)", line)
    if m:
        seq += 1
        cur[m.group(2)] = seq
        inst[seq] = dict(pc=int(m.group(3), 16), P1=int(m.group(1)))
        continue
    m = re.search(r"\[ISQ_FIRE\] cycle=(\d+) group=(\d+) tag=(\S+)", line)
    if m and m.group(3) in cur:
        inst[cur[m.group(3)]].setdefault("P2", int(m.group(1))); continue
    m = re.search(r"\[P3_BYPASS\] cycle=(\d+) lane=(\d+) tag=(\S+)", line)
    if m and m.group(3) in cur:
        inst[cur[m.group(3)]].setdefault("P3", int(m.group(1))); continue
    m = re.search(r"\[FU_WB\] cycle=(\d+) .*tag=(\S+) result=(\S+) mispredict=(\d)", line)
    if m and m.group(2) in cur:
        inst[cur[m.group(2)]]["mis"] = int(m.group(4))
        inst[cur[m.group(2)]]["res"] = m.group(3); continue
    m = re.search(r"\[BE\]\[COMMIT\] cycle=(\d+) .*tag=(\S+)", line)
    if m and m.group(2) in cur:
        inst[cur[m.group(2)]].setdefault("P4", int(m.group(1)))

jalrs = [e for e in inst.values() if e["pc"] == jpc]
print("=== 该 JALR 的每一次执行 ===")
for i, e in enumerate(jalrs, 1):
    print("  第%d次: P1=%-4s P2=%-4s P3=%-4s P4=%-4s mispredict=%-4s result=%s"
          % (i, e["P1"], e.get("P2", "-"), e.get("P3", "-"), e.get("P4", "-"),
             e.get("mis", "-"), e.get("res", "-")))
dep_pc = None
for line in od.split("\n"):
    m = re.match(r"^\s+([0-9a-f]+):\s+([0-9a-f]{8})\s+(\w+)", line)
    if m and m.group(3) == "add" and ((int(m.group(2), 16) >> 7) & 31) == 6:
        dep_pc = int(m.group(1), 16)
deps = [e for e in inst.values() if e["pc"] == dep_pc]
print()
print("=== dependent (add x6, x5, x3) ===")
for e in deps:
    print("  P1=%-4s P2=%-4s P3=%-4s P4=%-4s" % (e["P1"], e.get("P2", "-"), e.get("P3", "-"),
                                                 e.get("P4", "-")))
print()
print("重定向次数 = %d" % len(re.findall(r"\[BE\]\[REDIRECT\]", txt)))
print("退出正常 = %s" % ("是" if "is_good=1" in txt else "否"))
