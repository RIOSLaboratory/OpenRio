#!/usr/bin/env python3
"""judge_stim.py -- 激励表（A 形态）的自动判定器。

两种模式，按用例名自动选择：
  * 标称用例：断言 **目标 δ = dependent − producer 的注入 cycle 差**（即图上的 IB 槽位差），
    并把**实测机制**与 caselist 的机制约定对照（overlay / wait_for_p3 / p3_capture /
    p4_capture / arf_read）。机制由观测得出，不由预测填入。
  * blocked 用例（名含 `p4blocked` / `_blocked`）：按 4 条**机制判据**（δ 是输出，不断言）。

L 取 `latency_table.py`（项目内唯一来源），不在此处复写阈值。
"""
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import cal_stim as C                                    # noqa: E402
from latency_table import L_OF                          # noqa: E402


def mech_of(delta, L):
    if delta == 0:
        return "overlay"
    if delta <= L:
        return "wait_for_p3"
    if delta == L + 1:
        return "p3_capture"
    if delta == L + 2:
        return "p4_capture"
    return "arf_read"


def observed_mech(p, d):
    """由事件观测机制，而不是由预测填入。"""
    if "P1" not in d or "P1" not in p:
        return "?"
    if d["P1"] == p["P1"]:
        return "overlay"
    if "P3" in p and d["P1"] == p["P3"]:
        return "p3_capture"
    if "P4" in p and d["P1"] == p["P4"]:
        return "p4_capture"
    if "P4" in p and d["P1"] > p["P4"]:
        return "arf_read"
    if "P3" in p and d["P1"] < p["P3"]:
        return "wait_for_p3" if (d.get("P2", d["P1"]) - d["P1"]) > 1 else "overlay*"
    return "?"


MN2FAM = {"add": "ALU", "addi": "ALU", "sub": "ALU", "and": "ALU", "or": "ALU", "xor": "ALU",
           "sll": "ALU", "srl": "ALU", "sra": "ALU", "slt": "ALU", "sltu": "ALU", "lui": "ALU",
           "mul": "MUL", "mulh": "MUL", "div": "DIV", "divu": "DIV", "rem": "DIV", "remu": "DIV",
           "ld": "LOAD", "lw": "LOAD", "lh": "LOAD", "lb": "LOAD", "jalr": "JALR", "jal": "JALR"}


def mnemonic_of(cid, pc):
    """从表的原始行里取该 pc 的助记符（表里带注释原文）。"""
    for ln in (C.SRC / (cid + ".tsv")).read_text(encoding="utf-8").split("\n"):
        f = ln.split("#")[0].split()
        if len(f) >= 3 and f[2].startswith("0x"):
            try:
                if int(f[2], 16) == pc:
                    # 助记符在行尾注释里：# div x7, x1, x2  [Blocker G0]
                    tail = ln.split("#", 1)[1].split() if "#" in ln else []
                    return tail[0] if tail else ""
            except ValueError:
                pass
    return ""


def roles(rows):
    prod = [r for r in rows if r["role"].lower().startswith(("producer", "p4 source"))]
    dep = [r for r in rows if r["role"].lower().startswith("dependent")]
    blk = [r for r in rows if r["role"].lower().startswith("blocker")]
    return prod, dep, blk


def judged(cid):
    rows = C.read_table(C.SRC / (cid + ".tsv"))
    prod, dep, blk = roles(rows)
    if len(prod) != 1 or len(dep) != 1:
        return dict(cid=cid, verdict="解析失败", note="producer=%d dep=%d" % (len(prod), len(dep)))
    mn = mnemonic_of(cid, prod[0]["pc"])
    L = L_OF.get(MN2FAM.get(mn, ""), None)
    tmp = C.DST / (cid + ".judge.tsv")
    C.DST.mkdir(parents=True, exist_ok=True)
    txt = C.run(rows, cid, tmp)
    m = C.measure(txt)
    p, d = m.get(prod[0]["pc"], {}), m.get(dep[0]["pc"], {})
    tmp.unlink(missing_ok=True)
    if "P1" not in p or "P1" not in d:
        return dict(cid=cid, verdict="无事件", note="缺 DECODE")
    delta = d["P1"] - p["P1"]
    gap = p["P3"] - p["P2"] if ("P3" in p and "P2" in p) else None
    p4p3 = p["P4"] - p["P3"] if ("P4" in p and "P3" in p) else None
    wait = d["P2"] - d["P1"] if "P2" in d else None
    blocked = ("p4blocked" in cid) or cid.endswith("_blocked")
    if blocked:
        ok = (gap == L and p4p3 is not None and p4p3 > 1 and wait == 1
              and d["P1"] == p.get("P4"))
        return dict(cid=cid, verdict="通过" if ok else "未通过", L=L, delta=delta, gap=gap,
                    p4p3=p4p3, wait=wait, mech=observed_mech(p, d))
    target = dep[0]["cyc"] - prod[0]["cyc"]
    want = mech_of(target, L) if L else "?"
    got = observed_mech(p, d)
    ok = (delta == target and got == want)
    return dict(cid=cid, verdict="通过" if ok else "未通过", L=L, delta=delta, gap=gap,
                p4p3=p4p3, wait=wait, mech="%s/%s" % (got, want), target=target)


if __name__ == "__main__":
    cases = sys.argv[1:]
    if not cases:
        cases = sorted(p.stem for p in C.SRC.glob("*.tsv"))
    print("%-40s %-5s %-8s %-8s %-7s %-6s %-18s %s" %
          ("case", "L", "δ", "P4-P3", "等待", "P3-P2", "机制(实测/期望)", "判定"))
    bad = 0
    for c in cases:
        r = judged(c)
        if r["verdict"] != "通过":
            bad += 1
        print("%-40s %-5s %-8s %-8s %-7s %-6s %-18s %s%s" %
              (r["cid"], r.get("L", "-"), r.get("delta", "-"), r.get("p4p3", "-"),
               r.get("wait", "-"), r.get("gap", "-"), r.get("mech", "-"), r["verdict"],
               ("  " + r["note"]) if r.get("note") else ""))
    print()
    print("共 %d 条，未通过 %d 条" % (len(cases), bad))
    sys.exit(1 if bad else 0)
