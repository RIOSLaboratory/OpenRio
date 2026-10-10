import re, subprocess
from pathlib import Path

ENV = Path("/work/home/danielle/workspace/suncheek/model/OpenRio/verification/orbe_bt_env")
WORK = Path("/work/home/danielle/workspace/suncheek/model/perf_eval_work/filler_exp")
TC = Path("/work/stu/yzhang/workspace/riscv/bin")
TAG, DUT = "timing_delta", "rtl_v1"

# 用上一步 k=2 的程序（DIV 干净、MUL 尚未同拍），看每条指令占哪个 group
name = "DG_k2"
elf = WORK / "elf" / (name + ".elf")
src = WORK / "cases" / (name + ".S")

od = subprocess.run([str(TC / "riscv64-unknown-elf-objdump"), "-d", str(elf)],
                    capture_output=True, text=True).stdout
layout = {}
for line in od.split("\n"):
    m = re.match(r"^\s+([0-9a-f]+):\s+([0-9a-f]{8})\s+(\S+)(.*)", line)
    if m:
        layout[int(m.group(1), 16)] = (m.group(3), (m.group(4) or "").split("#")[0].strip())

log = ENV / "sim" / ("verilator_" + TAG) / "log" / DUT / (name + "_1") / "sim.log"
cur, dyn, seq = {}, {}, 0
for line in log.read_text(errors="replace").split("\n"):
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

print("%-8s %-14s %-6s %-6s %-6s %s" % ("pc", "指令", "group", "P1", "P2", "P3"))
for e in sorted(dyn.values(), key=lambda x: x["P1"]):
    mn, ops = layout.get(e["pc"], ("?", ""))
    txt = ("%s %s" % (mn, ops))[:13]
    print("0x%-6x %-14s %-6s %-6s %-6s %s" %
          (e["pc"], txt, e.get("grp", "-"), e.get("P1"), e.get("P2"), e.get("P3", "-")))
