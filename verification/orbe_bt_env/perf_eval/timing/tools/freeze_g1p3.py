import re, subprocess
from pathlib import Path

ENV = Path("/work/home/danielle/workspace/suncheek/model/OpenRio/verification/orbe_bt_env")
FROZEN = ENV / "perf_eval/timing/calibrated_cases"
WORK = Path("/work/home/danielle/workspace/suncheek/model/perf_eval_work/filler_exp")
TC = Path("/work/stu/yzhang/workspace/riscv/bin")
GCC, OD = TC / "riscv64-unknown-elf-gcc", TC / "riscv64-unknown-elf-objdump"
COSIM = ENV / "tools/verilator_cosim.sh"
LINK = ENV / "perf_eval/templates/link.ld"
TAG, DUT = "timing_delta", "rtl_v1"

K, M = 1, 5          # 间距与 dependent 前的分支填充物条数

body = """    addi x1, zero, 1
    addi x2, zero, 2
    addi x3, zero, 3
    addi x4, zero, 4
    la   x10, scratch
    la   x29, tohost
    addi x28, zero, 1
    ld   x6, 0(x10)
""" + "    bne  x0, x0, 7f\n7:\n" * K + """    mul  x8, x1, x2
""" + "    bne  x0, x0, 7f\n7:\n" * M + """    add  x20, x6, x8
"""
tail = """
pass:
    sd   x28, 0(x29)
9:  wfi
    j    9b
.section .data
scratch: .quad 0
"""
src = FROZEN / "INT2_P4_G1P3.S"
src.write_text(".option norvc\n.section .text\n.globl _start\n_start:\n" + body + tail,
               encoding="utf-8")
elf = WORK / "elf" / "INT2_P4_G1P3.elf"
r = subprocess.run([str(GCC), "-march=rv64imafdc", "-mabi=lp64d", "-nostdlib", "-nostartfiles",
                    "-Wl,-T," + str(LINK), "-o", str(elf), str(src)],
                   capture_output=True, text=True)
assert r.returncode == 0, r.stderr[:300]

subprocess.run([str(COSIM), "run", "--no-build", "--dut-kind", DUT, "--tag", TAG,
                "--verbosity", "2", "--timeout", "20000", "--tc", str(elf)],
               capture_output=True, text=True)

od = subprocess.run([str(OD), "-d", str(elf)], capture_output=True, text=True).stdout
targets = {}
for line in od.split("\n"):
    m = re.match(r"^\s+([0-9a-f]+):\s+([0-9a-f]{8})\s+(\w+)", line)
    if not m:
        continue
    rd = (int(m.group(2), 16) >> 7) & 0x1F
    pc = int(m.group(1), 16)
    if m.group(3) == "ld" and rd == 6 and "C" not in targets:
        targets["C"] = pc
    if m.group(3) == "mul" and rd == 8 and "P" not in targets:
        targets["P"] = pc
    if m.group(3) == "add" and rd == 20 and "DEP" not in targets:
        targets["DEP"] = pc

log = ENV / "sim" / ("verilator_" + TAG) / "log" / DUT / "INT2_P4_G1P3_1" / "sim.log"
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
c, b, q = bypc.get(targets["C"], {}), bypc.get(targets["P"], {}), bypc.get(targets["DEP"], {})

print("配方：提交侧 LOAD，%d 条分支填充物，旁路侧 MUL，%d 条分支填充物，dependent" % (K, M))
print()
print("指令              P1  grp P2  P3  P4   lane")
for label, e in (("ld (提交侧)", c), ("mul (旁路侧)", b), ("add (dependent)", q)):
    print("%-16s %-4s %-4s %-4s %-4s %-4s %s" %
          (label, e.get("P1"), e.get("grp"), e.get("P2"), e.get("P3", "-"), e.get("P4", "-"),
           e.get("lane", "-")))
print()
aligned = (c.get("P4") == b.get("P3") == q.get("P1"))
print("ld.P4 = %s，mul.P3 = %s，dep.P1 = %s  ->  三点同拍: %s" %
      (c.get("P4"), b.get("P3"), q.get("P1"), "是" if aligned else "否"))
print("mul 写回是否干净（P3 - P2 == 3）: %s" %
      ("是" if (b.get("P3", 0) - b.get("P2", 0)) == 3 else "否"))
print("ld 写回是否干净（P3 - P2 == 3）: %s" %
      ("是" if (c.get("P3", 0) - c.get("P2", 0)) == 3 else "否"))
print("模型正常退出: %s" % ("是" if "is_good=1" in txt else "否"))
early = [l for l in txt.split(chr(10)) if "[BE][REDIRECT]" in l]
print("REDIRECT 次数: %d（末尾自旋跳转会有 1 次，属预期）" % len(early))
