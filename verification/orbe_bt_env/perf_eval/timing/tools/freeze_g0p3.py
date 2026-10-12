"""固化 INT2_G1P3_G0P3：G0 侧用 DIV，G1 侧 MUL，填充物全为 fadd.s。"""
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

# 第一段 1 条 fadd，第二段 3 条 fadd；填充物目的寄存器互不相同
body = """    addi x1, zero, 1
    addi x2, zero, 2
    addi x3, zero, 3
    addi x4, zero, 4
    li   x7, 0x6000
    csrs mstatus, x7
    la   x10, scratch
    la   x29, tohost
    addi x28, zero, 1
    div  x6, x3, x4
    fadd.s f21, f1, f2
    mul  x8, x1, x2
    fadd.s f22, f1, f2
    fadd.s f23, f1, f2
    fadd.s f24, f1, f2
    add  x20, x8, x6
"""
tail = """
pass:
    sd   x28, 0(x29)
9:  wfi
    j    9b
.section .data
scratch: .quad 0
"""
src = FROZEN / "INT2_G1P3_G0P3.S"
src.write_text(".option norvc\n.section .text\n.globl _start\n_start:\n" + body + tail,
               encoding="utf-8")
elf = WORK / "elf" / "INT2_G1P3_G0P3.elf"
r = subprocess.run([str(GCC), "-march=rv64imafdc", "-mabi=lp64d", "-nostdlib", "-nostartfiles",
                    "-Wl,-T," + str(LINK), "-o", str(elf), str(src)],
                   capture_output=True, text=True)
assert r.returncode == 0, r.stderr[:300]
subprocess.run([str(COSIM), "run", "--no-build", "--dut-kind", DUT, "--tag", TAG,
                "--verbosity", "2", "--timeout", "20000", "--tc", str(elf)],
               capture_output=True, text=True)

od = subprocess.run([str(OD), "-d", str(elf)], capture_output=True, text=True).stdout
want = {}
for line in od.split("\n"):
    m = re.match(r"^\s+([0-9a-f]+):\s+([0-9a-f]{8})\s+(\w+)", line)
    if not m:
        continue
    rd = (int(m.group(2), 16) >> 7) & 0x1F
    pc = int(m.group(1), 16)
    if m.group(3) == "div" and rd == 6:
        want["DIV"] = pc
    if m.group(3) == "mul" and rd == 8:
        want["MUL"] = pc
    if m.group(3) == "add" and rd == 20 and "DEP" not in want:
        want["DEP"] = pc
        inst = int(m.group(2), 16)
        want["rs1"] = (inst >> 15) & 0x1F
        want["rs2"] = (inst >> 20) & 0x1F

log = ENV / "sim" / ("verilator_" + TAG) / "log" / DUT / "INT2_G1P3_G0P3_1" / "sim.log"
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
d, m, q = bypc.get(want["DIV"], {}), bypc.get(want["MUL"], {}), bypc.get(want["DEP"], {})

print("INT2_G1P3_G0P3 固化复核")
print("  指令              P1  grp P2  P3  P4   lane")
for label, e in (("div (G0 P3 源)", d), ("mul (G1 P3 源)", m), ("add (dependent)", q)):
    print("  %-18s %-4s %-4s %-4s %-4s %-4s %s" % (label, e.get("P1"), e.get("grp"),
          e.get("P2"), e.get("P3", "-"), e.get("P4", "-"), e.get("lane", "-")))
print()
checks = [
    ("div.P3 = mul.P3", d.get("P3") == m.get("P3")),
    ("mul.P3 = dep.P1", m.get("P3") == q.get("P1")),
    ("div 写回干净 (P3-P2=4)", (d.get("P3", 0) - d.get("P2", 0)) == 4),
    ("mul 写回干净 (P3-P2=3)", (m.get("P3", 0) - m.get("P2", 0)) == 3),
    ("div 在 group 0 / lane 0", d.get("grp") == 0 and d.get("lane") == 0),
    ("mul 在 group 1 / lane 1", m.get("grp") == 1 and m.get("lane") == 1),
    ("dependent rs1 = x8（G1 源）", want.get("rs1") == 8),
    ("dependent rs2 = x6（G0 源）", want.get("rs2") == 6),
    ("dependent 在解析拍才派发", q.get("P1") == m.get("P3") and q.get("P2", 0) > q.get("P1", 0)),
    ("模型正常退出", "is_good=1" in txt),
]
for name, ok in checks:
    print("  %-28s %s" % (name, "通过" if ok else "未通过"))
print()
print("全部通过" if all(ok for _, ok in checks) else "有未通过项，需调整")
