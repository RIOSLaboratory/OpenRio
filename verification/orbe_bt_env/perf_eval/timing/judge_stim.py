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
    """机制按**关系**观测（与 caselist 的阶梯定义一致），不看 P2 是否等待：
       dep.P1 == prod.P1 -> overlay; == prod.P3 -> p3_capture; == prod.P4 -> p4_capture;
       > prod.P4 -> arf_read; 其余（落在 prod.P1 与 prod.P3 之间）-> wait_for_p3。
    注：wait_for_p3 既可能是 ISQ 驻留等待，也可能是 P2 处的 P3 唤醒，二者由 P2-P1 区分，
    但都属于 wait_for_p3 这一档。"""
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
    return "wait_for_p3"


MN2FAM = {"add": "ALU", "addi": "ALU", "sub": "ALU", "and": "ALU", "or": "ALU", "xor": "ALU",
           "sll": "ALU", "srl": "ALU", "sra": "ALU", "slt": "ALU", "sltu": "ALU", "lui": "ALU",
           "mul": "MUL", "mulh": "MUL", "div": "DIV", "divu": "DIV", "rem": "DIV", "remu": "DIV",
           "ld": "LOAD", "lw": "LOAD", "lh": "LOAD", "lb": "LOAD", "jalr": "JALR", "jal": "JALR"}


def mnemonic_of(cid, pc):
    """助记符在表的行尾注释里：`# add x5, x1, x2  [Producer G1]`。"""
    for ln in (C.SRC / (cid + ".tsv")).read_text(encoding="utf-8").split("\n"):
        f = ln.split("#")[0].split()
        if len(f) >= 3 and f[2].startswith("0x"):
            try:
                if int(f[2], 16) == pc:
                    tail = ln.split("#", 1)[1].split() if "#" in ln else []
                    return tail[0] if tail else ""
            except ValueError:
                pass
    return ""


def roles(rows):
    """通用解析：producer/源（有写回）、dependent、blocker。"""
    src = [r for r in rows if r["role"].lower().startswith(
        ("producer", "p3 source", "p4 source"))]
    dep = [r for r in rows if r["role"].lower().startswith("dependent")]
    blk = [r for r in rows if r["role"].lower().startswith("blocker")]
    return src, dep, blk


def fam_of(cid, pc):
    return MN2FAM.get(mnemonic_of(cid, pc), "")


def is_p2_mode(cid):
    """P2 MUX 用例：源在依赖者已驻留之后到达（含 SAME_RD 的 P2 变体）。"""
    return cid.startswith("INT2_P2_") or "_P2_" in cid


def two_operand(cid, rows, ev):
    """两操作数用例：按用例名 token 检查关系。返回 (ok, note)。"""
    src, dep, blk = roles(rows)
    if len(dep) != 1:
        return False, "dependent 行数=%d" % len(dep)
    d = ev.get(dep[0]["pc"], {})
    if "P1" not in d:
        return False, "dependent 无 P1"
    notes, ok = [], True
    # 1) 每个有写回的源：写回间隔 == 它自己的 L
    for r in src + blk:
        e = ev.get(r["pc"], {})
        L = L_OF.get(fam_of(cid, r["pc"]))
        if "P2" not in e or "P3" not in e:
            notes.append("%s 无 P2/P3" % mnemonic_of(cid, r["pc"]))
            ok = False
            continue
        if L is not None and e["P3"] - e["P2"] != L:
            notes.append("%s 写回间隔 %d != L=%d" % (mnemonic_of(cid, r["pc"]), e["P3"] - e["P2"], L))
            ok = False
    # 2) GxP3 token：该组源的 P3 == dep.P1
    for tok in ("G0P3", "G1P3", "G3P3", "P2G0P3", "P2G1P3", "P2G3P3"):
        if tok in cid:
            grp = "G" + tok.split("G")[1][0]
            hit = [r for r in src if ("P3" in r["role"] or r["role"].startswith("Producer"))
                   and (grp in r["role"])]
            if not hit:
                notes.append("找不到 %s 源" % tok)
                ok = False
            else:
                ref = d["P2"] if is_p2_mode(cid) else d["P1"]
                gotv = ev.get(hit[0]["pc"], {}).get("P3")
                if gotv != ref:
                    notes.append("%s 源 P3=%s != dep.%s=%s"
                                 % (tok, gotv, "P2" if is_p2_mode(cid) else "P1", ref))
                    ok = False
    # 3) P4 token：某个源的 P4 == dep.P1
    if "P4" in cid and not is_p2_mode(cid):
        hit = [r for r in src if "P4 source" in r["role"]]
        if not hit:
            notes.append("找不到 P4 源")
            ok = False
        else:
            for r in hit:
                if ev.get(r["pc"], {}).get("P4") != d["P1"]:
                    notes.append("P4 源 P4=%s != dep.P1=%s"
                                 % (ev.get(r["pc"], {}).get("P4"), d["P1"]))
                    ok = False
    # 4) P2_ 前缀：依赖者先在 ISQ 中，应当等
    if is_p2_mode(cid):
        if d.get("P2", d["P1"]) - d["P1"] < 1:
            notes.append("P2 用例但 dep 未等待（P2-P1=%d）" % (d.get("P2", 0) - d["P1"]))
            ok = False
    else:
        if d.get("P2", 0) - d["P1"] != 1:
            notes.append("dep 未在派发拍就绪（P2-P1=%d）" % (d.get("P2", 0) - d["P1"]))
            ok = False
    # 5) blocked
    if cid.endswith("_blocked"):
        p4s = [r for r in src if "P4 source" in r["role"]]
        p3s = [r for r in src if "P3 source" in r["role"]]
        for r in p4s:                       # 只有 P4 源应当被压住
            e = ev.get(r["pc"], {})
            if "P4" in e and "P3" in e and e["P4"] - e["P3"] <= 1:
                notes.append("P4 源未被压住（P4-P3=%d）" % (e["P4"] - e["P3"]))
                ok = False
        # 本类最关键的一条：被压住的提交 == P3 源的写回 == 依赖者的派发
        for r in p4s + p3s:
            e = ev.get(r["pc"], {})
            if e.get("P4" if "P4 source" in r["role"] else "P3") != d["P1"]:
                notes.append("%s 与 dep.P1=%s 不重合" % (r["role"], d["P1"]))
                ok = False
    return ok, "; ".join(notes)


def judged(cid):
    rows = C.read_table(C.SRC / (cid + ".tsv"))
    src, dep, blk = roles(rows)
    if cid.startswith("INT2_"):
        if len(dep) != 1:
            return dict(cid=cid, verdict="解析失败", note="dep=%d" % len(dep))
        tmp0 = C.DST / (cid + ".judge.tsv")
        C.DST.mkdir(parents=True, exist_ok=True)
        ev0 = C.measure(C.run(rows, cid, tmp0))
        tmp0.unlink(missing_ok=True)
        ok, note = two_operand(cid, rows, ev0)
        dd = ev0.get(dep[0]["pc"], {})
        return dict(cid=cid, verdict="通过" if ok else "未通过", L="-",
                    delta=dd.get("P2", 0) - dd.get("P1", 0) if "P1" in dd else "-",
                    gap="-", p4p3="-", wait="-", mech="-", note=note)
    if len(src) != 1 or len(dep) != 1:
        return dict(cid=cid, verdict="解析失败", note="producer=%d dep=%d" % (len(src), len(dep)))
    prod = src
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
