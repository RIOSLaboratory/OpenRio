"""看 div_first 下"边界同拍但写回脏"的那几种配置，逐条打印事件与 group。"""
import re
import subprocess
from pathlib import Path

src = Path("/tmp/g1p3_g0p3.py").read_text(encoding="utf-8")
ns = {}
exec(compile(src.split("def main(order)")[0], "gg_head", "exec"), ns)
SETUP, SRC, TAIL, DIV_I, MUL_I, DEP_I = (ns["SETUP"], ns["SRC"], ns["TAIL"],
                                          ns["DIV_I"], ns["MUL_I"], ns["DEP_I"])
fill, run, pcs, WORK, OD = ns["fill"], ns["run"], ns["pcs"], ns["WORK"], ns["OD"]

CONFIGS = [(0, 1), (1, 1), (2, 0)]
for n_ld, n_fp in CONFIGS:
    body = SETUP + DIV_I + "\n" + fill(n_ld, n_fp) + MUL_I + "\n" + DEP_I + "\n"
    bypc, txt, elf = run("dg_%d_%d" % (n_ld, n_fp), body)
    p = pcs(elf)
    print("=== 间隔 (%d ld, %d fp) ===" % (n_ld, n_fp))

    # 重新解析，保留每条动态指令而非按 pc 去重
    log = ns["ENV"] / "sim" / ("verilator_" + ns["TAG"]) / "log" / ns["DUT"] / ("GG_dg_%d_%d_1" % (n_ld, n_fp)) / "sim.log"
    cur, dyn, seq = {}, {}, 0
    for line in log.read_text(errors="replace").split("\n"):
        m = re.search(r"\[BE\]\[DECODE\] cycle=(\d+) .*tag=(\S+) .*pc=(\S+) .*inst=(\S+)", line)
        if m:
            seq += 1
            cur[m.group(2)] = seq
            dyn[seq] = dict(pc=int(m.group(3), 16), inst=int(m.group(4), 16), P1=int(m.group(1)))
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

    od = subprocess.run([str(OD), "-d", str(elf)], capture_output=True, text=True).stdout
    mn = {}
    for line in od.split("\n"):
        m = re.match(r"^\s+([0-9a-f]+):\s+([0-9a-f]{8})\s+(\w+)", line)
        if m:
            mn[int(m.group(1), 16)] = m.group(3)

    print("   %-8s %-14s %-5s %-5s %-5s %-5s %-5s %s" %
          ("pc", "指令", "P1", "P2", "P3", "P4", "lane", "grp"))
    for e in sorted(dyn.values(), key=lambda x: x["P1"]):
        rd = (e["inst"] >> 7) & 0x1F
        print("   0x%-6x %-14s %-5s %-5s %-5s %-5s %-5s %s" %
              (e["pc"], "%s x%d" % (mn.get(e["pc"], "?"), rd), e["P1"], e.get("P2", "-"),
               e.get("P3", "-"), e.get("P4", "-"), e.get("lane", "-"), e.get("grp", "-")))
    print()
