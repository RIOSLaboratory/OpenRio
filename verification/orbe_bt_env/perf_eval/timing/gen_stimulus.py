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
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]          # .../verification/orbe_bt_env
WORK = Path("/work/home/danielle/workspace/suncheek/model/perf_eval_work")
DIAGRAMS = ROOT / "perf_eval/timing/diagrams"

# 标题有两种形态：`## Case N: <id> (<mech>)` 与 `## Case N: <id>`
CASE_RE = re.compile(r"^## Case (\d+): (\S+?)(?:\s+\(([^)]+)\))?\s*$", re.M)
# 两种后缀格式都要认：`- Producer-G0` 与 `· P3 source·G1` => 组名统一取出现的 G<d>
# 标签写法 -> 规范角色
ROLE_MAP = [
    (r"p3 bypass", "P3 source"),
    (r"p4 commit", "P4 source"),
    (r"p4 source", "P4 source"),
    (r"p3 source", "P3 source"),
    (r"arf source", "ARF source"),
    (r"^\s*imm\b|·\s*imm", "IMM"),
    (r"stored ready", "ISQ_STORED"),
    (r"producer", "Producer"),
    (r"dependent", "Dependent"),
    (r"blocker", "Blocker"),
]

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
    # 图上有多种标签写法，统一映射成规范角色（顺序即优先级）
    role = ""
    low = rest.lower()
    for pat, canon in ROLE_MAP:
        if re.search(pat, low):
            role = canon
            break
    g = GROUP_RE.search(rest)
    grp = ("G" + g.group(1)) if g else ""
    return text, role, grp


TOOL = Path("/work/stu/yzhang/workspace/riscv/bin/riscv64-unknown-elf-")
BASE_PC = 0x80000000


def _norm(text):
    """归一化助记符文本，便于源/反汇编比对。"""
    t = text.lower().replace(",", " ")
    t = re.sub(r"\s+", " ", t).strip()
    # the disassembler drops a zero offset: `0(x10)` and `x10` are the same
    t = re.sub(r"0\((\w+)\)", r"\1", t)
    return t


def assemble(instrs):
    """把指令列表汇编成 (hex 列表, 反汇编文本列表)；失败返回 (None, 错误信息)。"""
    body = "    .option norvc\n    .section .text\n    .globl _start\n_start:\n"
    body += "".join("    %s\n" % i for i in instrs)
    with tempfile.TemporaryDirectory() as td:
        src = Path(td) / "a.S"
        obj = Path(td) / "a.o"
        src.write_text(body, encoding="utf-8")
        r = subprocess.run([str(TOOL) + "gcc", "-march=rv64imafdc", "-mabi=lp64d",
                            "-nostdlib", "-nostartfiles", "-c", "-o", str(obj), str(src)],
                           capture_output=True, text=True)
        if r.returncode:
            return None, r.stderr.strip().split("\n")[-1][:120]
        od = subprocess.run([str(TOOL) + "objdump", "-d", "-M", "numeric", str(obj)],
                            capture_output=True, text=True).stdout
    hexes, texts = [], []
    for ln in od.split("\n"):
        m = re.match(r"^\s+([0-9a-f]+):\s+([0-9a-f]{8})\s+(.+)$", ln)
        if m:
            hexes.append(m.group(2))
            texts.append(m.group(3).split("#")[0].strip())
    if len(hexes) != len(instrs):
        return None, "指令数不符：汇编 %d 条，反汇编 %d 条" % (len(instrs), len(hexes))
    return (hexes, texts), None


def jalr_pred(instr):
    """JALR 作 producer 时的预测字段（§3.6）：强制命中。"""
    m = re.match(r"jalr\s+\w+,\s*(-?\d+|0x[0-9a-f]+)\(", instr.strip(), re.I)
    if not m:
        return None
    imm = int(m.group(1), 0) if not m.group(1).startswith("0x") else int(m.group(1), 16)
    return 1, imm & ~1


def main():
    files = sorted(DIAGRAMS.glob("*.md"))
    if len(sys.argv) > 1:
        files = [DIAGRAMS / a for a in sys.argv[1:]]
    outdir = WORK / "stimulus"
    outdir.mkdir(parents=True, exist_ok=True)
    total = bad = asm_bad = 0
    want_ids = set()
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

            # 输出激励表（含汇编后的编码）
            res, err = assemble([e["instr"] for e in entries])
            if err:
                print("  %-40s 汇编失败: %s" % (cid, err))
                asm_bad += 1
            lines = ["# case %s  (%s)  -- 从 diagram 生成；pc 为本文激励自排" % (cid, mech),
                     "# cycle  lane  pc            inst_hex     pred_taken  pred_target_pc  # instr"]
            for i, e in enumerate(entries):
                hexs = res[0][i] if res else "??"
                pt, ptg = 0, 0
                jp = jalr_pred(e["instr"])
                if jp:
                    pt, ptg = jp
                if res:
                    # 反汇编回读核对
                    if _norm(e["instr"]) != _norm(res[1][i]):
                        print("  %-40s 反汇编不一致: %r vs %r" % (cid, e["instr"], res[1][i]))
                        asm_bad += 1
                lines.append("%-8d %-5d 0x%-10x 0x%-10s %-11d 0x%-13x # %s%s"
                             % (e["cyc"], e["lane"], BASE_PC + 4 * i, hexs, pt, ptg, e["instr"],
                                "" if not e["role"] else "  [%s %s]" % (e["role"], e["grp"])))
            (outdir / (cid + ".tsv")).write_text("\n".join(lines) + "\n", encoding="utf-8")
            want_ids.add(cid)
    # 陈旧产物清理：用例改名后，旧名字的表会留在运行集里，导致"多跑一条"
    # （实测踩过：改名后跑出 69 条，其中一条是改名前的旧内容）。移到 stimulus_stale/ 备查。
    stale_dir = outdir.parent / "stimulus_stale"
    stale_dir.mkdir(parents=True, exist_ok=True)
    extras = sorted({q.stem for q in outdir.glob("*.tsv")} - want_ids)
    for cid in extras:
        (outdir / (cid + ".tsv")).replace(stale_dir / (cid + ".tsv"))
    if extras:
        print("已移出陈旧产物 %d 个（改名前的旧表）：%s" % (len(extras), ", ".join(extras)))
    missing = sorted(want_ids - {q.stem for q in outdir.glob("*.tsv")})
    if missing:
        print("警告：图纸里有但运行集里没有：%s" % ", ".join(missing))
    print()
    print("生成 %d 个激励表到 %s（时序自检未通过 %d 个；汇编问题 %d 个）"
          % (total, outdir, bad, asm_bad))
    return 1 if (bad or asm_bad) else 0


if __name__ == "__main__":
    sys.exit(main())
