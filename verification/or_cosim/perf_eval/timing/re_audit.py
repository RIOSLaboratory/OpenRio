#!/usr/bin/env python3
"""re_audit.py -- 用权威口径重验所有固化用例。

为什么要单独做这件事：标定过程中出现过"干净写回间隔"被手抄错的情况（DIV 写成 5，实际 4），
而当时据此下过结论。所以这里不信任任何历史脚本，而是

  * L 值只从 lane_check.L_CLEAN 取（该表与 latency_bench/Latency_Report.md §3.1 一致）；
  * 用例指令与依赖关系只从 caselist 的 Instructions 列取；
  * 每个固化 .S 现编现跑，按日志逐项判。

判据：每个生产者 P3 - P2 等于其家族的 L；该行声称的边界关系成立；模型正常退出。
"""
import re
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
from lane_check import L_CLEAN                      # noqa: E402  单一口径来源
from lane_check import family                       # noqa: E402

ENV = HERE.parents[1]                               # verification/or_cosim
FROZEN = HERE / "calibrated_cases"
CASELISTS = [HERE / "caselists/INT_single_operand_dependency_caselist_v1.md",
             HERE / "caselists/INT_two_operands_dependency_caselist.md"]
WORK = Path("/work/home/danielle/workspace/suncheek/model/perf_eval_work")
TC = Path("/work/stu/yzhang/workspace/riscv/bin")
GCC, OD, NM = (TC / "riscv64-unknown-elf-gcc", TC / "riscv64-unknown-elf-objdump",
               TC / "riscv64-unknown-elf-nm")
COSIM = ENV / "tools/verilator_cosim.sh"
LINK = ENV / "perf_eval/templates/link.ld"
TAG, DUT = "timing_full", "rtl_full"   # 必须用已有 build 的 tag，否则 --no-build 会失败


def parse_caselists():
    """case id -> (producers [(rd, mnem)], dependent (mnem, rd, rs1, rs2), mux)"""
    out = {}
    for path in CASELISTS:
        mux, ins_col = "P1", None
        for line in path.read_text(encoding="utf-8").split("\n"):
            if line.startswith("## P2 MUX"):
                mux = "P2"
            if line.startswith("## Supplemental"):
                mux = "P1"
            if line.startswith("| Case |") and "Instructions" in line:
                hdr = [c.strip() for c in line.strip().strip("|").split("|")]
                ins_col = hdr.index("Instructions")
                continue
            if not line.startswith("| `") or ins_col is None:
                continue
            cells = [c.strip() for c in line.strip().strip("|").split("|")]
            if len(cells) <= ins_col:
                continue
            cid = cells[0].strip("`")
            skel = cells[ins_col].strip("`")
            # 有箭头时右侧是 dependent；没有箭头（例如 `mul ..; jalr ..`）时最后一条是 dependent
            if "->" in skel or "-->" in skel:
                left, right = re.split(r"->|-->", skel, maxsplit=1)
                seq = [x.strip() for x in left.split(";") if x.strip()] + \
                      [x.strip() for x in right.split(";") if x.strip()]
            else:
                seq = [x.strip() for x in skel.split(";") if x.strip()]
            if len(seq) < 2:
                continue
            prods = []
            for p in seq[:-1]:
                parts = p.replace(",", " ").split()
                if len(parts) >= 2:
                    prods.append((parts[1], parts[0]))
            d = seq[-1].replace(",", " ").split()
            if len(d) < 2:
                continue
            # `jalr rd, offset(rs1)` 的第三个字段不是寄存器，要取出括号里的 rs1
            if len(d) > 2 and "(" in d[2]:
                rs1 = d[2].split("(")[-1].strip(")")
                rs2 = "IMM"
            else:
                rs1 = d[2] if len(d) > 2 else "x0"
                rs2 = d[3] if len(d) > 3 else "IMM"
            out[cid] = (prods, (d[0], d[1], rs1, rs2), mux)
    return out


def pcs_of(elf):
    dump = subprocess.run([str(OD), "-d", str(elf)], capture_output=True, text=True).stdout
    got = {}
    for line in dump.split("\n"):
        m = re.match(r"^\s+([0-9a-f]+):\s+([0-9a-f]{8})\s+(\w+)", line)
        if not m:
            continue
        got[int(m.group(1), 16)] = (int(m.group(2), 16), m.group(3))
    sym = {}
    for line in subprocess.run([str(NM), str(elf)], capture_output=True, text=True).stdout.split("\n"):
        p = line.split()
        if len(p) == 3:
            sym[p[2]] = int(p[0], 16)
    return got, sym


def events(log):
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
    return bypc


def rnum(x):
    m = re.match(r"x(\d+)$", x)
    return int(m.group(1)) if m else None


def main():
    cases = parse_caselists()
    print("L 表（取自 lane_check.L_CLEAN，与 Latency Report §3.1 一致）：%s" % L_CLEAN)
    print()
    print("%-40s %-22s %-24s %s" % ("用例", "生产者写回 实测/L", "声称关系", "判定"))
    bad = []
    for s in sorted(FROZEN.glob("*.S")):
        cid = s.stem
        if cid not in cases:
            print("%-40s %s" % (cid, "caselist 里找不到该 id"))
            bad.append(cid)
            continue
        prods, dep, mux = cases[cid]
        (WORK / "audit").mkdir(parents=True, exist_ok=True)
        elf = WORK / "audit" / (cid + ".elf")
        r = subprocess.run([str(GCC), "-march=rv64imafdc", "-mabi=lp64d", "-nostdlib",
                            "-nostartfiles", "-Wl,-T," + str(LINK), "-o", str(elf), str(s)],
                           capture_output=True, text=True)
        if r.returncode:
            print("%-40s 编译失败" % cid); bad.append(cid); continue
        subprocess.run([str(COSIM), "run", "--no-build", "--dut-kind", DUT, "--tag", TAG,
                        "--verbosity", "2", "--timeout", "20000", "--tc", str(elf)],
                       capture_output=True, text=True)
        log = ENV / "sim" / ("verilator_" + TAG) / "log" / DUT / (cid + "_1") / "sim.log"
        if not log.exists():
            print("%-40s 无日志" % cid); bad.append(cid); continue
        txt = log.read_text(errors="replace")
        bypc = events(log)
        info, sym = pcs_of(elf)

        gaps, reasons = [], []
        for rd, mnem in prods:
            n = rnum(rd)
            pc = next((p for p, (inst, mn) in info.items()
                       if mn == mnem and ((inst >> 7) & 0x1F) == n), None)
            e = bypc.get(pc, {})
            # family() 的期望输入是大写助记符（它解析日志里的 inst_mnemonic 字段），
            # caselist 里是小写，必须转换
            fam = family(mnem.upper())
            if fam is None:
                fam = "ALU"
            L = L_CLEAN.get(fam)
            if "P2" not in e or "P3" not in e:
                gaps.append("%s x%d: 无写回" % (mnem, n))
                reasons.append("%s x%d 没有 P3 事件" % (mnem, n))
                continue
            gap = e["P3"] - e["P2"]
            gaps.append("%s x%d: %d/%d" % (mnem, n, gap, L))
            if gap != L:
                reasons.append("%s x%d 写回间隔 %d，应为 %d" % (mnem, n, gap, L))

        d = dep
        dpc = next((p for p, (inst, mn) in info.items()
                    if mn == d[0] and ((inst >> 7) & 0x1F) == (rnum(d[1]) or -1)), None)
        de = bypc.get(dpc, {})
        res = de.get("P1") if mux == "P1" else de.get("P2")

        claims = []
        # 补充组的 same-RD fanout：一个生产者的同一份 payload 同时喂 rs1 与 rs2。
        # P1 MUX 行要求解析拍恰好命中 P3；P2 MUX 行要求已在 ISQ 驻留且 bypass 到达同拍发射。
        if cid.startswith("INT2_SAME_RD_"):
            prd_pc = next((q for q, (inst, mn) in info.items()
                           if mn in [pm for _, pm in prods]
                           and ((inst >> 7) & 0x1F) == (rnum(d[2]) or -1)), None)
            pe = bypc.get(prd_pc, {})
            if cid.startswith("INT2_SAME_RD_P1_"):
                claims.append("dep.P1 == mul.P3")
                if de.get("P1") != pe.get("P3"):
                    reasons.append("P1 MUX 未命中：dep.P1=%s mul.P3=%s" % (de.get("P1"), pe.get("P3")))
            else:
                claims.append("dep.P1 < mul.P3 <= dep.P2")
                if not (de.get("P1", 99) < pe.get("P3", 0) <= de.get("P2", -1)):
                    reasons.append("P2 MUX 未驻留唤醒：dep.P1=%s dep.P2=%s mul.P3=%s"
                                   % (de.get("P1"), de.get("P2"), pe.get("P3")))
            if "is_good=1" not in txt:
                reasons.append("模型未正常退出")
            print("%-40s %-22s %-24s %s" % (cid, " ".join(gaps), " ".join(claims),
                                            "通过" if not reasons else "未通过: " + "; ".join(reasons)))
            if reasons:
                bad.append(cid)
            continue
        toks = cid.replace("INT2_", "").replace("P2_", "").rsplit("_", 2)
        if cid.startswith("INT2_"):
            pairs = [(toks[0], d[2]), (toks[1], d[3])]
        else:
            pairs = [(cid.split("_to_")[0], None)]
        for rk in ([d[2], d[3]] if cid.startswith("INT2_") else [d[2]]):
            n = rnum(rk)
            if n is None or not prods:
                continue
            prd = next((p for p, (inst, mn) in info.items()
                        if ((inst >> 7) & 0x1F) == n and mn in [pm for _, pm in prods]), None)
            e = bypc.get(prd, {})
            if cid.startswith("INT2_"):
                idx = 0 if rk == d[2] else 1
                tok = toks[idx] if idx < len(toks) else ""
                if tok.startswith("G") and tok.endswith("P3"):
                    claims.append("%s.P3=%s" % (rk, res)); reasons += [] if e.get("P3") == res else ["%s.P3=%s != %s" % (rk, e.get("P3"), res)]
                elif tok == "P4":
                    claims.append("%s.P4=%s" % (rk, res)); reasons += [] if e.get("P4") == res else ["%s.P4=%s != %s" % (rk, e.get("P4"), res)]
                elif tok == "ARF":
                    claims.append("%s.P4<%s" % (rk, res)); reasons += [] if e.get("P4", 10**9) < (res or 0) else ["ARF 源未提前提交"]
                elif tok == "ISQ_STORED":
                    claims.append("%s.P3<=%s" % (rk, de.get("P1"))); reasons += [] if e.get("P3", 10**9) <= (de.get("P1") or -1) else ["存储源未在派发前就绪"]
            else:
                want = int(cid.rsplit("_", 1)[1])
                got = (de.get("P1", 0) - e.get("P1", 0)) if ("P1" in de and "P1" in e) else None
                claims.append("δ=%d" % want)
                if got != want:
                    reasons.append("δ 实测 %s，应为 %d" % (got, want))

        if "is_good=1" not in txt:
            reasons.append("模型未正常退出")

        print("%-40s %-22s %-24s %s" % (cid, " ".join(gaps), " ".join(claims) or "-",
                                        "通过" if not reasons else "未通过: " + "; ".join(reasons)))
        if reasons:
            bad.append(cid)
    print()
    print("未通过的用例数: %d %s" % (len(bad), bad if bad else ""))


if __name__ == "__main__":
    main()
