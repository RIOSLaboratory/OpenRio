#!/usr/bin/env python3
"""check_materials.py -- 材料结构自检：caselist 与 diagram 必须完整且互相一致。

写它的直接原因：一次批量替换用 `s.index(第一个表头)` 定位，命中了 ALU 那张表，
把 MUL/DIV/LOAD 三节整段删掉，而当时没有任何检查发现——提交后靠人工数行才发现。
形如 "检查器比材料窄" 的问题在本项目已出现多次，故把结构约束固化成可执行检查。

检查项：
  1. 每个 caselist 的小节标题集合；
  2. 每个家族的 case 行数与总数；
  3. 对应的 diagram 与 caselist **逐条 Case 名一致**（不只是条数）。
退出码非 0 表示不一致。
"""
import re
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
CL_SINGLE = HERE / "caselists/INT_single_operand_dependency_caselist_v1.md"
CL_TWO = HERE / "caselists/INT_two_operands_dependency_caselist.md"
DG_SINGLE = HERE / "diagrams/INT_single_operand_dependency_diagram.md"
DG_TWO = HERE / "diagrams/INT_two_operands_dependency_diagram.md"

# 期望值（随材料变更一起更新）
EXPECT_SECTIONS = ["ALU_to_ALU", "MUL_to_ALU", "DIV_to_ALU", "LOAD_to_ALU", "JALR_to_ALU"]
EXPECT_FAMILY = {"ALU_to_ALU": 6, "MUL_to_ALU": 8, "DIV_to_ALU": 9, "LOAD_to_ALU": 8,
                 "JALR_to_ALU": 6}
EXPECT_SINGLE_TOTAL = 37
EXPECT_TWO_TOTAL = 30

fails = []


def check(cond, msg):
    print("  %s %s" % ("ok  " if cond else "FAIL", msg))
    if not cond:
        fails.append(msg)


print("== 单操作数 caselist ==")
s = CL_SINGLE.read_text(encoding="utf-8")
sections = [h for h in re.findall(r"^## (.+)$", s, re.M) if not h.startswith("Delta")
            and not h.startswith("Group") and not h.startswith("Filler")]
for sec in EXPECT_SECTIONS:
    check(sec in sections, "小节存在: %s" % sec)

# 必须捕获**完整** Case 名（含 _delta_N），否则会把家族名当 Case 名去和图比较
rows = re.findall(r"^\| `([A-Za-z0-9_]+_delta_\d+[A-Za-z0-9_]*)`", s, re.M)
counts = {}
for cid in rows:
    fam = re.sub(r"_delta_\d+.*$", "", cid)
    counts[fam] = counts.get(fam, 0) + 1
check(counts == EXPECT_FAMILY, "家族行数 %s" % counts)
check(len(rows) == EXPECT_SINGLE_TOTAL, "总数 %d == %d" % (len(rows), EXPECT_SINGLE_TOTAL))

print("== 单操作数 diagram 与 caselist 逐条一致 ==")
d = DG_SINGLE.read_text(encoding="utf-8")
d_cases = sorted(re.findall(r"^## Case \d+: ([A-Za-z0-9_]+)", d, re.M))
c_cases = sorted(rows)
check(len(d_cases) == len(c_cases), "条数 %d vs %d" % (len(d_cases), len(c_cases)))
check(d_cases == c_cases, "Case 名逐条一致" if d_cases == c_cases
      else "差异: %s" % sorted(set(d_cases) ^ set(c_cases))[:6])

print("== 两操作数 caselist / diagram ==")
t = CL_TWO.read_text(encoding="utf-8")
t2 = sorted(re.findall(r"^\| `(INT2_[A-Za-z0-9_]+)`", t, re.M))
d2 = sorted(re.findall(r"^## Case \d+: ([A-Za-z0-9_]+)", DG_TWO.read_text(encoding="utf-8"), re.M))
check(len(t2) == EXPECT_TWO_TOTAL, "caselist 条数 %d == %d" % (len(t2), EXPECT_TWO_TOTAL))
check(t2 == d2, "Case 名逐条一致" if t2 == d2
      else "差异: %s" % sorted(set(t2) ^ set(d2))[:6])



# ---- IB 激励法文档：小节完整性（曾被一次错误的字符串区间整节删除）----
IB_DOC = HERE.parent / "IB_STIMULUS_METHOD.md"
REQUIRED = ["## 7. 核实记录", "## 8. 派发侧契约", "## 9. 实施规格",
            "### 9.1 激励表格式", "### 9.2 终止条件", "### 9.3 非侵入性验收试验",
            "### 9.4 对现有材料的改动清单", "### 9.5 JALR / BRU", "### 9.6 形态决定",
            "### 9.7 从 diagram 直接生成激励表"]
print("== IB_STIMULUS_METHOD.md 小节完整性 ==")
doc = IB_DOC.read_text(encoding="utf-8")
missing = [h for h in REQUIRED if h not in doc]
check(not missing, "必需小节齐全" if not missing else "缺失: %s" % missing)
check(len(doc.split("\n")) > 400, "文档行数 %d > 400" % len(doc.split("\n")))

print()
if fails:
    print("材料自检未通过：%d 项" % len(fails))
    sys.exit(1)
print("材料自检通过")
