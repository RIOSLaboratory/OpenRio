"""核对：caselist 的"配方"列 与 图纸的指令行 是否是同一个程序。

背景：这个不一致已经骗过两次（Case 7/10 的配方写的是 `ld;mul`，而图纸是 `mul;add`），
人工看很难发现，所以固化成检查。
"""
import re
import sys
from pathlib import Path

ROOT = Path("/work/home/danielle/workspace/suncheek/model/OpenRio/verification/orbe_bt_env/perf_eval")
PAIRS = [("timing/diagrams/INT_two_operands_dependency_diagram.md",
          "timing/caselists/INT_two_operands_dependency_caselist.md"),
         ("timing/diagrams/INT_single_operand_dependency_diagram.md",
          "timing/caselists/INT_single_operand_dependency_caselist_v1.md")]


def norm(s):
    s = s.strip().strip("`").strip()
    # 剥掉配方里的角色标注：(blocker) / (producer) / (dependent)
    s = re.sub(r"\((?:blocker|producer|dependent)[^)]*\)", " ", s)
    s = re.sub(r"\s+", " ", s).strip()
    s = re.sub(r"\s+", " ", s)
    s = s.replace(",", " ")
    s = re.sub(r"\s+", " ", s)
    return s.lower()


def pieces(text):
    """把 `a; b -> c` 拆成指令序列"""
    out = []
    for part in re.split(r"->|;", text):
        p = norm(part)
        if p:
            out.append(p)
    return out


bad = 0
total = 0
for dg, cl in PAIRS:
    ds = (ROOT / dg).read_text(encoding="utf-8")
    cs = (ROOT / cl).read_text(encoding="utf-8")
    # 图纸：每个 case 的指令行（去掉角色后缀）
    blocks = re.split(r"^## Case ", ds, flags=re.M)[1:]
    for b in blocks:
        m = re.match(r"\d+: (\S+)", b)
        if not m:
            continue
        cid = m.group(1)
        rows = re.findall(r"^\| `([^`]+)`", b, re.M)
        if not rows:
            continue
        # caselist：该行的配方列（第 4 列）
        r = re.search(r"^\| `%s` \|(.*)$" % re.escape(cid), cs, re.M)
        if not r:
            continue
        cells = [c.strip() for c in r.group(1).split("|")]
        recipe = next((c for c in cells if c.startswith("`") and len(c) > 2), None)
        if not recipe:
            continue
        total += 1
        a = [norm(x) for x in rows]
        bx = pieces(recipe)
        # 允许图纸多出 blocker 行（caselist 也写了 blocker 时顺序一致）
        if a != bx:
            bad += 1
            print("不一致：%s\n  图纸 ：%s\n  配方 ：%s" % (cid, a, bx))
print()
print("核对 %d 条，不一致 %d 条" % (total, bad))
sys.exit(1 if bad else 0)
