"""构造 P4-blocked 用例（单操作数 5 条）。

从现有 `*_delta_N (p4_capture)` 块机械派生：
  + 在 producer 行**之前**插入一行阻塞物（⇒ 同拍、lane 0，路由逻辑把灵活的 producer 逼到另一组）
  + 若 producer 是灵活组（ALU），其组/FU 随阻塞物改变
  + 换掉 bullets（写明"预期 P4 捕捉不出现、退化为等待"）
  + 在 landmark 处补一条"P3→P4 = 1 是前提"的说明
目的：不是占拍数，而是**制造一个状态**——更老的指令仍在飞，压住顺序提交。
"""
import re
from pathlib import Path

ROOT = Path("/work/home/danielle/workspace/suncheek/model/OpenRio/verification/or_cosim/perf_eval")
DIAG = ROOT / "timing/diagrams/INT_single_operand_dependency_diagram.md"
CL = ROOT / "timing/caselists/INT_single_operand_dependency_caselist_v1.md"

# (源用例, 新用例, 阻塞物指令, 阻塞物组, 阻塞物 rd, producer 是否灵活组)
CASES = [
    ("ALU_to_ALU_delta_3",  "ALU_to_ALU_delta_3_p4blocked",  "div x7, x1, x2",   "G0", True),
    ("MUL_to_ALU_delta_5",  "MUL_to_ALU_delta_5_p4blocked",  "div x7, x1, x2",   "G0", False),
    ("DIV_to_ALU_delta_6",  "DIV_to_ALU_delta_6_p4blocked",  "mul x7, x1, x2",   "G1", False),
    ("LOAD_to_ALU_delta_5", "LOAD_to_ALU_delta_5_p4blocked", "div x7, x1, x2",   "G0", False),
    ("JALR_to_ALU_delta_3", "JALR_to_ALU_delta_3_p4blocked", "mul x7, x1, x2",   "G1", False),
]

s = DIAG.read_text(encoding="utf-8")
blocks = {}


def get_block(name):
    if name in blocks:
        return blocks[name]
    m = re.search(r"^## Case (\d+): %s \(([^)]+)\)\s*$" % re.escape(name), s, re.M)
    assert m, "找不到用例块: %s" % name
    start = m.start()
    nxt = re.search(r"^## ", s[m.end():], re.M)
    end = m.end() + (nxt.start() if nxt else len(s) - m.end())
    blocks[name] = (int(m.group(1)), m.group(2), s[start:end])
    return blocks[name]


maxnum = max(int(x) for x in re.findall(r"^## Case (\d+):", s, re.M))
new_blocks, new_rows = [], []

for src, new, blocker, bgrp, flex in CASES:
    num, mech, block = get_block(src)
    maxnum += 1
    assert mech == "p4_capture", (src, mech)
    dm = re.search(r"_delta_(\d+)$", new)
    body = block

    # 1) 标题
    body = re.sub(r"^## Case \d+: %s \(p4_capture\)" % re.escape(src),
                  "## Case %d: %s (p4_capture, commit held)" % (maxnum, new), body, count=1, flags=re.M)

    # 2) 取出 producer 行，插入阻塞物行；必要时改 producer 的组/FU
    lines = body.split("\n")
    out = []
    for ln in lines:
        if ln.startswith("| `") and "Producer" in ln:
            cells = [c.strip() for c in ln.strip().strip("|").split("|")]
            nm = re.search(r"`([^`]+)`", cells[0])
            instr = nm.group(1) if nm else ""
            # producer 若为灵活组，被阻塞物挤到另一组
            if flex:
                other = "G1" if bgrp == "G0" else "G0"
                instr = instr.replace("ALU0", "ALU0")
                ln = ln.replace("Producer-G0", "Producer·%s" % other)
                ln = ln.replace("ALU0", "ALU1" if other == "G1" else "ALU0")
            # 阻塞物行：同拍入队（IB 对齐 producer 的 IB），FU 名按 L 重复
            ib_idx = [i for i, c in enumerate(cells[1:]) if c.upper() == "IB"]
            assert ib_idx, ln
            ncol = len(cells) - 1
            cells_b = ["`%s` - Blocker·%s" % (blocker, bgrp)] + [""] * ncol
            ib = ib_idx[0]
            cells_b[1 + ib] = "IB"
            cells_b[2 + ib] = "dispatch"
            fu = blocker.split()[0].upper()
            nrep = {"DIV": 4, "MUL": 3}[fu]
            for k in range(nrep):
                cells_b[3 + ib + k] = fu
            cells_b[3 + ib + nrep] = "WB"
            cells_b[4 + ib + nrep] = "C"
            out.append("| " + " | ".join(cells_b) + " |")
        out.append(ln)
    body = "\n".join(out)

    # 3) 换 bullets：保留 T1 之外的旧 bullet 全部替换
    tail_start = body.index("\n- **")
    head = body[:tail_start].rstrip()
    wb_T = re.search(r"Producer P3", body)
    bullets = """
- **T1 (Blocker and producer enqueued together):** the older `%s` is routed to %s and the producer to the
  other ALU group, so the two take separate ISQ entries. The blocker is listed first so it lands in slot 0,
  which is what forces the flexible producer off %s.
- **Producer WB (on schedule):** the producer's result enters the P3 Buffer in the same cycle as the nominal
  figure. This is the point of the construction — the writeback is *not* delayed, only the commit is.
- **Nominal P4 (Commit CDB expected, does not appear):** the older `%s` has not retired, and retirement is
  in order while writeback is not, so the producer stays in the Buffer. No Commit CDB is presented and a
  P4 → P1 capture is impossible in that cycle.
- **Expected deviation (this is what the case measures):** the dependent cannot capture. It stalls
  (Condition A) and resolves only after the producer retires; its resolution cycle and the path it finally
  uses are the measured quantities, not predictions.
- **Check on the run:** the producer's `P3 − P2` must still equal `L` (writeback untroubled) while its
  `P4 − P3` must be greater than 1 (commit held). If `P4 − P3` is 1 the blocker retired in time and the
  case did not reproduce the target state — report it rather than pass it.
""" % (blocker, bgrp, bgrp, blocker)
    body = head + "\n" + bullets
    new_blocks.append(body)

    new_rows.append("| `%s` | %s | `%s; <producer>; <dependent>` | n/a | %s |"
                    % (new, ("G0 blocker + other" if flex else bgrp + " blocker, fixed producer"),
                       blocker.split()[0], "P4 capture expected but commit held in the Buffer"))

# 4) 追加新块 + landmark 说明
note = """
> **Landmark precondition (added with the `*_p4blocked` cases).** The rows above place `WB` at `T(3+L)` and
> `C` at `T(4+L)`, and the `p4_capture` rung is defined as "the dependent's P1 lands on the producer's P4".
> Both assume the producer is already at the commit head when it writes back. Retirement is in order while
> writeback is not, so when an older instruction is still in flight the producer's `C` slides, `P4 − P3 > 1`,
> and the nominal `p4_capture` becomes unreachable — the dependent stalls instead. The five `*_p4blocked`
> cases exist to exercise exactly that condition; they are a separate class, not a re-run of the nominal rung.
"""
anchor = "## Stage mapping"
assert s.count(anchor) == 1
s = s.replace(anchor, anchor, 1)
if "Landmark precondition" not in s:
    lm = s.index("\n## ")
    s = s[:lm] + "\n" + note + s[lm:]
s = s.rstrip() + "\n\n" + "\n\n".join(new_blocks).rstrip() + "\n"
DIAG.write_text(s, encoding="utf-8")
print("diagram: 新增 %d 个块，Case 编号 %d..%d" % (len(new_blocks), maxnum - len(CASES) + 1, maxnum))

# 5) caselist：把新行插到各族末尾
t = CL.read_text(encoding="utf-8")
for row in new_rows:
    fam = re.search(r"`([A-Za-z0-9]+)_to_ALU_delta", row).group(1) + "_to_ALU"
    sec = t.index("## %s" % fam)
    nxt = t.index("\n## ", sec + 1) if "\n## " in t[sec + 1:] else len(t)
    t = t[:nxt] + "\n" + row + t[nxt:]
CL.write_text(t, encoding="utf-8")
print("caselist: 新增 %d 行" % len(new_rows))
