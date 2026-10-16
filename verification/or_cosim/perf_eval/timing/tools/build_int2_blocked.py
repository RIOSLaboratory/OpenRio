"""构造 INT2_P4_G1P3_blocked（两操作数，P4 源被压住）。

从 Case 7 机械派生：
  + 阻塞物 = DIV（G0 固定），放在 T1：此时 G0 空（T1 只有 G1 的 MUL）⇒ 可同拍
  + 它比 P4 源（T3 dispatch）更老 ⇒ 压住 P4 源的提交
  + 消费者从 G0 挪到 G1：避开阻塞物占用的 G0 FU（否则它因 FU 忙而等 = 混淆），
    同时仍能接收 MUL 的 G1 P3 旁路
预期：rs2（G1 P3 旁路，T6）正常拿到，rs1（P4 Commit）拿不到 ⇒ 组合解析失败 ⇒ 停顿。
"""
import re
from pathlib import Path

ROOT = Path("/work/home/danielle/workspace/suncheek/model/OpenRio/verification/or_cosim/perf_eval")
DIAG = ROOT / "timing/diagrams/INT_two_operands_dependency_diagram.md"
CL = ROOT / "timing/caselists/INT_two_operands_dependency_caselist.md"

SRC, NEW, BLOCKER, BGRP = "INT2_P4_G1P3", "INT2_P4_G1P3_blocked", "div x11, x12, x13", "G0"

s = DIAG.read_text(encoding="utf-8")
m = re.search(r"^## Case (\d+): %s\s*$" % re.escape(SRC), s, re.M)
assert m, "找不到 %s" % SRC
nxt = re.search(r"^## ", s[m.end():], re.M)
blk = s[m.start():m.end() + nxt.start()]
maxnum = max(int(x) for x in re.findall(r"^## Case (\d+):", s, re.M))

# 1) 标题 + 描述
blk = re.sub(r"^## Case \d+: %s\s*$" % re.escape(SRC),
             "## Case %d: %s\n" % (maxnum + 1, NEW), blk, count=1, flags=re.M)
blk = re.sub(r"\*\*Description:\*\*.*\n",
             "**Description:** The P4 source writes back on the nominal cycle but cannot commit, because an "
             "older instruction is still in flight and retirement is in order, so the value stays in the P3 "
             "Buffer with no Commit CDB presented. rs2 still arrives from the MUL's G1 P3 bypass, so this "
             "case also exercises a *partially* resolvable entry.\n", blk, count=1)

# 2) 插阻塞物行（放最前 ⇒ lane 0），并把消费者挪到 G1
lines, done = [], False
for ln in blk.split("\n"):
    if not done and ln.startswith("| `") and "P3 source·G1" in ln:
        cells = [c.strip() for c in ln.strip().strip("|").split("|")]
        ncol = len(cells) - 1
        ib = [i for i, c in enumerate(cells) if c.upper() == "IB"]
        assert ib, ln
        b = ["`%s` - Blocker·%s" % (BLOCKER, BGRP)] + [""] * ncol
        b[ib[0]] = "IB"
        b[ib[0] + 1] = "dispatch"
        for k in range(4):
            b[ib[0] + 2 + k] = "DIV"
        b[ib[0] + 6] = "WB"
        b[ib[0] + 7] = "C"
        lines.append("| " + " | ".join(b) + " |")
        done = True
    if ln.startswith("| `") and "Dependent" in ln:
        ln = re.sub(r"Dependent·G\d", "Dependent·G1", ln)
        ln = re.sub(r"\bALU[01]\b", "ALU1", ln)
    lines.append(ln)
blk = "\n".join(lines)
assert done and "Dependent·G1" in blk

# 3) bullets
head = blk[:blk.index("\n- **")].rstrip()
blk = head + """

- **T1 (Blocker enqueued alongside the MUL):** the older `%s` takes G0 and the MUL takes G1, so the two land
  in different ISQ entries. G0 is free at T1 because only the MUL is being enqueued there otherwise.
- **T5 (P4 source WB, on schedule):** the P4 source writes back on the nominal cycle; its result enters the
  P3 Buffer. The writeback is not delayed — only the commit is.
- **T6 (Nominal composition, does not happen):** retirement is in order and the older `div` is still in
  flight, so no Commit CDB is presented for rs1. rs2 is still delivered by the MUL's G1 P3 bypass at T6,
  which is why the entry becomes *partially* resolvable rather than simply unmatched.
- **Expected deviation (this is what the case measures):** the dependent cannot complete its source
  composition; it stalls (Condition A) until the older instruction retires. Its resolution cycle and the
  path the missing operand finally takes are the measured quantities.
- **Check on the run:** the P4 source's `P3 − P2` must still equal its `L` while its `P4 − P3` must exceed 1.
  If `P4 − P3` is 1 the blocker retired in time and the case did not reproduce the target state.
""" % BLOCKER

s = s.rstrip() + "\n\n" + blk.rstrip() + "\n"   # 追加，保留源用例
DIAG.write_text(s, encoding="utf-8")
print("diagram: 新增 Case %d %s" % (maxnum + 1, NEW))

# 4) caselist 行
t = CL.read_text(encoding="utf-8")
row = ("| `%s` | blocker in G0, P4 source in G0 at a later cycle | `%s (blocker) ; mul x6,x3,x4 ; "
       "add x7,x8,x9 ; add x20,x7,x6` | n/a | rs1 (P4 Commit) held in the Buffer while rs2 arrives "
       "from G1 P3 Bypass; dependent stalls with a partially resolvable entry |" % (NEW, BLOCKER))
src_line = [l for l in t.split("\n") if l.startswith("| `%s` |" % SRC)]
assert len(src_line) == 1, src_line
t = t.replace(src_line[0], src_line[0] + "\n" + row, 1)
CL.write_text(t, encoding="utf-8")
print("caselist: 新增 1 行")
