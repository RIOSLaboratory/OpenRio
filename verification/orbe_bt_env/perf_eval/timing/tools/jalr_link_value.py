"""单条 JALR，imm 非 0、base 也不是目标地址本身：
  x11 = 目标地址 - 8,  jalr x5, 8(x11)
若写进 x5 的仍是 PC+4（而不是 x11+8），则证明 rd 与 rs1/imm 无关。
"""
import re
import subprocess
from pathlib import Path

ENV = Path("/work/home/danielle/workspace/suncheek/model/OpenRio/verification/orbe_bt_env")
W = Path("/work/home/danielle/workspace/suncheek/model/perf_eval_work/filler_exp")
TC = Path("/work/stu/yzhang/workspace/riscv/bin")
LINK = ENV / "perf_eval/templates/link.ld"

body = """    .option norvc
    .section .text
    .globl _start
_start:
    addi x3, zero, 3
    la   x29, tohost
    addi x28, zero, 1
    la   x11, L1
    addi x11, x11, -8
    jalr x5, 8(x11)
    addi x30, x0, 99
L1:
    add  x20, x5, x3
pass:
    sd   x28, 0(x29)
9:  wfi
    j    9b
.section .data
scratch: .quad 0
"""
src = W / "cases" / "JR_one.S"
elf = W / "elf" / "JR_one.elf"
src.write_text(body, encoding="utf-8")
r = subprocess.run([str(TC / "riscv64-unknown-elf-gcc"), "-march=rv64imafdc", "-mabi=lp64d",
                    "-nostdlib", "-nostartfiles", "-Wl,-T," + str(LINK), "-o", str(elf), str(src)],
                   capture_output=True, text=True)
assert r.returncode == 0, r.stderr[:300]
subprocess.run([str(ENV / "tools/verilator_cosim.sh"), "run", "--no-build", "--dut-kind", "rtl_v1",
                "--tag", "timing_delta", "--verbosity", "2", "--timeout", "20000", "--tc", str(elf)],
               capture_output=True, text=True)

od = subprocess.run([str(TC / "riscv64-unknown-elf-objdump"), "-d", str(elf)],
                    capture_output=True, text=True).stdout
for line in od.split("\n"):
    m = re.match(r"^\s+([0-9a-f]+):\s+([0-9a-f]{8})\s+(\w+)(.*)$", line)
    if m and m.group(3) == "jalr":
        pc, inst = int(m.group(1), 16), int(m.group(2), 16)
        print("  JALR pc=0x%x rd=x%d rs1=x%d imm=%d" % (pc, (inst >> 7) & 31, (inst >> 15) & 31,
                                                        (inst >> 20) & 0xFFF))
        print("      目标地址 = rs1+imm，写进 rd 的应为 PC+4 = 0x%x" % (pc + 4))

log = ENV / "sim" / "verilator_timing_delta" / "log" / "rtl_v1" / "JR_one_1" / "sim.log"
txt = log.read_text(errors="replace")
cur = {}
for line in txt.split("\n"):
    m = re.search(r"\[BE\]\[DECODE\] cycle=(\d+) .*tag=(\S+) .*pc=(\S+) .*inst=(\S+)", line)
    if m:
        cur[m.group(2)] = (int(m.group(3), 16), int(m.group(4), 16), int(m.group(1)))
        continue
    m = re.search(r"\[FU_WB\] cycle=(\d+) .*tag=(\S+) result=(\S+)", line)
    if m and m.group(2) in cur:
        pc, inst, cyc = cur[m.group(2)]
        if not (inst & 0x7F) == 0x67:
            continue
        val = int(m.group(3), 16)
        print("  实测 cycle=%d  JALR pc=0x%x  result=0x%x" % (cyc, pc, val))
        print("        PC+4（落空）    = 0x%x" % (pc + 4))
        print("        rs1+imm（目标） = 0x%x" % (int(pc) + 8))
        print("   ⇒ result %s PC+4" % ("等于" if val == pc + 4 else "不等于"))
        break
