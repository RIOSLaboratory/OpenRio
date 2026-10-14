#!/usr/bin/env python3
"""cal_stim.py -- 激励表标定闭环（A 形态）。

为什么需要：注入间隔 ≠ 派发间隔。同组 ISQ 条目被 producer 占住直到它发射，
所以 dependent 的入队虽按时，派发却晚 3 拍（实测）。标定就是把这个差补回去。

方法：读表 -> 跑（rtl_v1, cosim 关）-> 量实际 δ -> 按误差调整 dependent 的 cycle -> 重跑，
直到 δ 命中目标（目标 = 图上的 IB 槽位之差，即生成表里的 cycle 之差）。

输出：$WORK/stimulus_cal/<case>.tsv（标定后的表；原表保持"忠实于图"不动）。
"""
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path

ENV = Path("/work/home/danielle/workspace/suncheek/model/OpenRio/verification/orbe_bt_env")
W = Path("/work/home/danielle/workspace/suncheek/model/perf_eval_work")
SRC = W / "stimulus"
DST = W / "stimulus_cal"
# 判定 DUT 可用环境变量切换：rtl_v1（D 侧是 cache agent）/ rtl_cache（D 侧是真 OR_Cache）
TAG = os.environ.get("STIM_TAG", "stim")
DUT = os.environ.get("STIM_DUT", "rtl_v1")
ANY_ELF = sorted((W / "elf").glob("*.elf"))[0]
DRAIN = 60
ROUNDS = 4


def read_table(path):
    rows = []
    for ln in path.read_text(encoding="utf-8").split("\n"):
        if not ln.strip() or ln.lstrip().startswith("#"):
            continue
        f = ln.split("#")[0].split()
        if len(f) < 6:
            continue
        role = ""
        m = re.search(r"\[([^\]]+)\]", ln.split("#", 1)[1]) if "#" in ln else None
        if m:
            role = m.group(1)
        rows.append(dict(cyc=int(f[0]), lane=int(f[1]), pc=int(f[2], 16), hex=f[3],
                         pt=int(f[4]), ptg=f[5], role=role))
    return rows


def write_table(rows, path, note):
    out = ["# %s" % note,
           "# cycle  lane  pc            inst_hex     pred_taken  pred_target_pc  # role"]
    for r in rows:
        out.append("%-8d %-5d 0x%-10x %-12s %-11d %-15s # %s"
                   % (r["cyc"], r["lane"], r["pc"], r["hex"], r["pt"], r["ptg"], r["role"]))
    path.write_text("\n".join(out) + "\n", encoding="utf-8")


def run(rows, cid, tmp_tsv):
    write_table(rows, tmp_tsv, "calibration round for %s" % cid)
    elf = W / "elf" / ("cal_%s.elf" % cid)
    if not elf.exists():
        elf.symlink_to(ANY_ELF)
    subprocess.run([str(ENV / "tools/verilator_cosim.sh"), "run", "--no-build", "--dut-kind", DUT,
                    "--tag", TAG, "--cosim-enable", "0", "--verbosity", "2", "--timeout", "20000",
                    "--tc", str(elf), "--plusargs",
                    "+IB_STIM=%s +IB_STIM_DRAIN=%d" % (tmp_tsv, DRAIN)],
                   capture_output=True, text=True)
    log = ENV / "sim" / ("verilator_" + TAG) / "log" / DUT / ("cal_%s_1" % cid) / "sim.log"
    return log.read_text(errors="replace") if log.exists() else ""


def measure(txt):
    """按 pc 取事件的**第一次**出现；P1 来自 DECODE，P2/P3/P4 按 tag 归并。"""
    pc_of, ev, cur, seq = {}, {}, {}, 0
    for ln in txt.split("\n"):
        m = re.search(r"\[BE\]\[DECODE\] cycle=(\d+) .*tag=(\S+) .*pc=(\S+)", ln)
        if m:
            seq += 1
            cur[m.group(2)] = seq
            ev[seq] = dict(pc=int(m.group(3), 16), P1=int(m.group(1)))
            continue
        m = re.search(r"\[ISQ_FIRE\] cycle=(\d+) group=\d+ tag=(\S+)", ln)
        if m and m.group(2) in cur:
            ev[cur[m.group(2)]].setdefault("P2", int(m.group(1))); continue
        m = re.search(r"\[P3_BYPASS\] cycle=(\d+) lane=\d+ tag=(\S+)", ln)
        if m and m.group(2) in cur:
            ev[cur[m.group(2)]].setdefault("P3", int(m.group(1))); continue
        m = re.search(r"\[BE\]\[COMMIT\] cycle=(\d+) .*tag=(\S+)", ln)
        if m and m.group(2) in cur:
            ev[cur[m.group(2)]].setdefault("P4", int(m.group(1)))
    for e in ev.values():
        pc_of.setdefault(e["pc"], e)
    return pc_of


def calibrate(cid):
    src = SRC / (cid + ".tsv")
    rows = read_table(src)
    prod = [r for r in rows if r["role"].lower() == "producer"]
    dep = [r for r in rows if r["role"].lower() == "dependent"]
    if len(prod) != 1 or len(dep) != 1:
        print("  %-40s 无法标定：producer=%d dependent=%d" % (cid, len(prod), len(dep)))
        return None
    target = dep[0]["cyc"] - prod[0]["cyc"]
    tmp = DST / (cid + ".round.tsv")
    lo, hi = 1, max(12, target + 8)          # 在 dep 的注入 cycle 上二分
    best, hist = None, {}
    while lo <= hi:
        mid = (lo + hi) // 2
        dep[0]["cyc"] = max(mid, prod[0]["cyc"] + 1)
        txt = run(rows, cid, tmp)
        m = measure(txt)
        p_, d_ = m.get(prod[0]["pc"], {}), m.get(dep[0]["pc"], {})
        if "P1" not in p_ or "P1" not in d_:
            hi = mid - 1
            continue
        got = d_["P1"] - p_["P1"]
        hist[dep[0]["cyc"]] = got
        if best is None or abs(got - target) < abs(best[0] - target):
            best = (got, dep[0]["cyc"], p_, d_)
        # Judgement discipline: only an EXACT hit counts. Taking the nearest achievable delta would
        # report success for a case that never instantiated its target mechanism, which is the failure
        # mode this project keeps hitting.
        if got == target:
            break
        if got < target:
            lo = mid + 1      # 注入越晚 -> δ 越大
        else:
            hi = mid - 1
    got, chosen, p_, d_ = best
    dep[0]["cyc"] = chosen
    gap = p_.get("P3", 0) - p_.get("P2", 0) if ("P3" in p_ and "P2" in p_) else None
    p4p3 = p_.get("P4", 0) - p_.get("P3", 0) if ("P4" in p_ and "P3" in p_) else None
    wait = d_.get("P2", 0) - d_["P1"] if "P2" in d_ else None
    DST.mkdir(parents=True, exist_ok=True)
    final = DST / (cid + ".tsv")
    write_table(rows, final, "calibrated %s: target delta %d" % (cid, target))
    if tmp.exists():
        tmp.unlink()
    return dict(cid=cid, target=target, got=got, prod_gap=gap, p4p3=p4p3, wait=wait,
                dep_cyc=dep[0]["cyc"], rounds=len(hist), iters=hist)


if __name__ == "__main__":
    cases = sys.argv[1:] or [
        "ALU_to_ALU_delta_3_p4blocked", "MUL_to_ALU_delta_5_p4blocked",
        "DIV_to_ALU_delta_6_p4blocked", "LOAD_to_ALU_delta_5_p4blocked",
        "JALR_to_ALU_delta_3_p4blocked", "INT2_P4_G1P3_blocked"]
    DST.mkdir(parents=True, exist_ok=True)
    print("%-40s %-8s %-8s %-8s %-9s %-8s %s" %
          ("case", "目标δ", "实测δ", "P3-P2", "P4-P3", "dep等待", "轮数"))
    for c in cases:
        r = calibrate(c)
        if r:
            print("%-40s %-8d %-8d %-8s %-9s %-8s %d  %-14s 探针=%s" %
                  (r["cid"], r["target"], r["got"], r["prod_gap"], r["p4p3"], r["wait"], r["rounds"],
                   "通过" if r["got"] == r["target"] else "目标delta不可达",
                   sorted(r["iters"].items())))
