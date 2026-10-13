#!/usr/bin/env python3
"""gen_stimulus.py -- 从 timing diagram 机械生成 IB 激励表（A 形态：纯注入）。

映射规则（IB_STIMULUS_METHOD.md §9.7）：
  图上每条指令行中，单元格为 `IB` 的那一列，就是该指令的**注入 cycle**；
  同一 cycle 内的多条按行序分配 lane 0 / 1。

自带自检：
  1. 两指令用例的 cycle 之差必须等于用例名里的 `_delta_N`；
  2. 同 cycle 的多条必须落在**不同组**（METHOD §8：`groups_distinct`）。
输出到 $WORK/stimulus/<case>.tsv（生成物不入库）。
"""
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]          # .../verification/orbe_bt_env
WORK = Path("/work/home/danielle/workspace/suncheek/model/perf_eval_work")
DIAGRAMS = ROOT / "perf_eval/timing/diagrams"

# 标题有两种形态：`## Case N: <id> (<mech>)` 与 `## Case N: <id>`
CASE_RE = re.compile(r"^## Case (\d+): (\S+?)(?:\s+\(([^)]+)\))?\s*$", re.M)
# 两种后缀格式都要认：`- Producer-G0` 与 `· P3 source·G1` => 组名统一取出现的 G<d>
ROLE_RE = re.compile(r"(Producer|Dependent|Blocker|P3 source|P4 source|ARF source|IMM|"
                     r"ISQ_STORED)", re.I)
GROUP_RE = re.compile(r"\bG([0-3])\b")


def parse_diagram(path):
    text = path.read_text(encoding="utf-8")
    out = []
    for m in CASE_RE.finditer(text):
        num, cid, mech = int(m.group(1)), m.group(2), (m.group(3) or "?")
        body = text[m.end():]
        nxt = re.search(r"^## ", body, re.M)
        if nxt:
            body = body[:nxt.start()]
        rows, header = [], None
        for line in body.split("\n"):
            if not line.startswith("|"):
                continue
            cells = [c.strip() for c in line.strip().strip("|").split("|")]
            if header is None and cells and cells[0] == "Instruction":
                header = cells[1:]
                continue
            if set(line.replace("|", "").strip()) <= set(":- "):
                continue
            if header and len(cells) >= 2:
                rows.append(cells)
        out.append((num, cid, mech, header or [], rows))
    return out


def instr_of(cell):
    m = re.match(r"`([^`]+)`\s*(.*)", cell)
    if not m:
        return cell, "", ""
    text, rest = m.group(1).strip(), m.group(2)
    role = ""
    r = ROLE_RE.search(rest)
    if r:
        role = r.group(1)
    g = GROUP_RE.search(rest)
    grp = ("G" + g.group(1)) if g else ""
    return text, role, grp


def main():
    files = sorted(DIAGRAMS.glob("*.md"))
    if len(sys.argv) > 1:
        files = [DIAGRAMS / a for a in sys.argv[1:]]
    outdir = WORK / "stimulus"
    outdir.mkdir(parents=True, exist_ok=True)
    total = bad = 0
    for f in files:
        print("=== %s ===" % f.name)
        for num, cid, mech, header, rows in parse_diagram(f):
            entries = []
            for r in rows:
                text, role, grp = instr_of(r[0])
                cyc = None
                for i, c in enumerate(r[1:]):
                    if c.upper() == "IB":
                        cyc = int(re.sub(r"\D", "", header[i])) if i < len(header) else None
                        break
                if cyc is None:
                    continue
                entries.append(dict(cyc=cyc, instr=text, role=role, grp=grp,
                                    mech_label=""))
            # lane 分配（同 cycle 按行序）
            seen = {}
            for e in entries:
                e["lane"] = seen.get(e["cyc"], 0)
                seen[e["cyc"]] = e["lane"] + 1
            # 自检 1：delta
            dm = re.search(r"_delta_(\d+)", cid)
            checks = []
            prod = [e for e in entries if e["role"].lower() == "producer"]
            dep = [e for e in entries if e["role"].lower() == "dependent"]
            if dm and len(prod) == 1 and len(dep) == 1:
                want, got = int(dm.group(1)), dep[0]["cyc"] - prod[0]["cyc"]
                checks.append(("delta %d" % want, want == got,
                               "实测映射 %d" % got if want != got else ""))
            # 自检 2：同 cycle 必须不同组
            bycyc = {}
            for e in entries:
                bycyc.setdefault(e["cyc"], []).append(e)
            for c, es in bycyc.items():
                if len(es) > 1:
                    grps = [e["grp"] for e in es]
                    checks.append(("同拍不同组 @T%d" % c, len(set(grps)) == len(grps),
                                   str(grps)))
            ok = all(c[1] for c in checks)
            total += 1
            if not ok:
                bad += 1
            note = "; ".join("%s %s %s" % (c[0], "ok" if c[1] else "FAIL", c[2]) for c in checks)
            print("  Case %-3d %-38s %s" % (num, cid, note if checks else "(无条件)"))

            # 输出激励表
            lines = ["# case %s  (%s)  -- 从 diagram 生成" % (cid, mech),
                     "# cycle  lane  pc            inst_hex     pred_taken  pred_target_pc  # instr"]
            for e in entries:
                lines.append("%-8d %-5d %-13s %-12s %-11d %-15s # %s%s"
                             % (e["cyc"], e["lane"], "0x80000000+", "TODO",
                                0, "0x0", e["instr"],
                                "" if not e["role"] else "  [%s %s]" % (e["role"], e["grp"])))
            (outdir / (cid + ".tsv")).write_text("\n".join(lines) + "\n", encoding="utf-8")
    print()
    print("生成 %d 个激励表到 %s（其中自检未通过 %d 个）" % (total, outdir, bad))
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
