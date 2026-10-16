#!/usr/bin/env python3
"""run_all.py -- 一条命令跑完：从图纸生成激励表 → 跑仿真 → 判定 → 出报告。

用法：
  python3 run_all.py                      # 默认 DUT=rtl_v1, tag=stim, 6 路并行
  python3 run_all.py --dut rtl_cache --tag stimcache
  python3 run_all.py --cases LOAD_        # 只跑匹配的子集
  python3 run_all.py --skip-gen           # 不重新生成表（表已定稿时）
  python3 run_all.py --no-report          # 只判定，不写报告

产物（在 perf_eval_work 下）：
  results/judge_<tag>_<dut>.tsv           逐条结果
  results/CONFORMANCE_<tag>_<dut>.md      一致性报告
"""
import os
import subprocess
import sys
from concurrent.futures import ProcessPoolExecutor
from datetime import datetime
from pathlib import Path

HERE = Path(__file__).resolve().parent
W = Path("/work/home/danielle/workspace/suncheek/model/perf_eval_work")

# 已按用户口径标注为"推迟"的用例（原因写在图纸与 caselist 里）：
#   DIV 产生者 L=4，需要 L≥5 的阻塞物；当前整数 FU 最高 4，等未来替换内网算子后再构造。
DEFERRED = {"DIV_to_ALU_delta_6_p4blocked"}

# DUT / TAG 必须在 import cal_stim 之前设好（它们在导入时读环境变量）
argv = sys.argv[1:]
for i, a in enumerate(argv):
    if a == "--dut" and i + 1 < len(argv):
        os.environ["STIM_DUT"] = argv[i + 1]
    elif a.startswith("--dut="):
        os.environ["STIM_DUT"] = a.split("=", 1)[1]
    elif a == "--tag" and i + 1 < len(argv):
        os.environ["STIM_TAG"] = argv[i + 1]
    elif a.startswith("--tag="):
        os.environ["STIM_TAG"] = a.split("=", 1)[1]

sys.path.insert(0, str(HERE))
import cal_stim as C        # noqa: E402
import judge_stim as J      # noqa: E402

FINDINGS = """## 结构性发现（本阶段改动过的图纸级结论）

| # | 结论 | 依据 |
|---|---|---|
| 1 | **LOAD 对 BE 可见的延迟是 3 拍（命中），不是 2 拍** | Cache HAS 修正 + `rtl_full` latency bench 实测；`rtl_v1` 上亦为 3 |
| 2 | **JALR 在单操作数集合里只能作 consumer** | 它在 retire 时的 redirect 会 flush 掉旁路可见窗口内的消费者；实测 δ=1,2,3 从不提交，首个存活为 6 |
| 3 | **ISQ 属 P2**（五段划分 P0..P4） | HAS §5 + 各 FU 的 `ISQ Wait` 列 |
| 4 | **`P4 + P3` 同拍捕获要求 P4 源更老** | 顺序提交：更老者的旁路只在其写回拍有效，必然早于年轻者的提交（实测恒定差 1 拍）|
| 5 | **标称形态要求年轻源不快于提交源**（`L_P3 ≤ L_C`），否则必须用「提交被压」形态 | 判定条件 `d = L_C − L_P3 + 1 ≥ 1`；G1 版改用 ALU 后成立，G3 版只能走被压形态 |
| 6 | **「提交被压」是独立形态**，其判据为 `P4源.P4−P3 > 1`、两源与派发拍重合、`dep.P2−P1 == 1` | 6 条 blocked 用例实测 |
| 7 | **被压形态下 `dep.P1 == prod.P4` 的机制已定性**：不是「派发等提交」，而是 **missed-wakeup 防护**——生产者「已写回未提交」时旁路已过、且没有提交到发射的通路，挂上去的消费者永远不会被唤醒，故前端拒绝其进入 ISQ，只能改从 Commit CDB 取值 | `p1/dependency_check.sv` 的 `source_kind` 阶梯与 `slot_missed_wakeup`；`p1/dispatch_logic.sv:394/417` 把该信号与进派发守卫 |
| 8 | **阶段 1 判定 DUT 用 `rtl_v1`**；`rtl_cache` 抽查显示 BE 侧逐条一致，仅 LOAD 延迟不同（3 命中 / 15 冷）| METHOD §5 |
"""


def parse_args():
    o = dict(dut=os.environ.get("STIM_DUT", "rtl_v1"), tag=os.environ.get("STIM_TAG", "stim"),
             jobs=6, skip_gen=False, report=True, cases=None)
    rest = list(argv)
    while rest:
        a = rest.pop(0)
        if a in ("--dut", "--tag") and rest:
            rest.pop(0)
        elif a.startswith(("--dut=", "--tag=")):
            pass
        elif a == "--jobs" and rest:
            o["jobs"] = int(rest.pop(0))
        elif a == "--cases" and rest:
            o["cases"] = rest.pop(0)
        elif a == "--skip-gen":
            o["skip_gen"] = True
        elif a == "--no-report":
            o["report"] = False
    return o


def family_of(cid):
    return "INT2" if cid.startswith("INT2_") else cid.split("_to_")[0]


def kind_of(cid):
    if cid.startswith("INT2_"):
        return "blocked" if cid.endswith("_blocked") else "two-operand"
    return "blocked" if "p4blocked" in cid else "nominal"


def main():
    o = parse_args()
    print("DUT=%s  TAG=%s  并行=%d" % (o["dut"], o["tag"], o["jobs"]))

    if not o["skip_gen"]:
        r = subprocess.run([sys.executable, str(HERE / "gen_stimulus.py")],
                           capture_output=True, text=True)
        tail = [l for l in r.stdout.strip().split("\n") if l.strip()][-2:]
        print("生成：" + " | ".join(tail))
        if r.returncode != 0:
            print("生成失败，中止")
            return 2
        for chk in ("check_materials.py", "check_recipes.py"):
            r = subprocess.run([sys.executable, str(HERE / chk)], capture_output=True, text=True)
            if r.returncode != 0:
                print("  [%s] 未通过：" % chk)
                print("\n".join("    " + l for l in r.stdout.strip().split("\n")[-6:]))

    cases = sorted(p.stem for p in C.SRC.glob("*.tsv"))
    if o["cases"]:
        cases = [c for c in cases if o["cases"] in c]
    print("用例数：%d" % len(cases))

    with ProcessPoolExecutor(max_workers=o["jobs"]) as ex:
        results = list(ex.map(J.judged, cases))

    out = W / "results"
    out.mkdir(parents=True, exist_ok=True)
    tsv = out / ("judge_%s_%s.tsv" % (o["tag"], o["dut"]))
    rows = []
    for r in sorted(results, key=lambda r: r["cid"]):
        cid = r["cid"]
        v = "推迟" if cid in DEFERRED else r["verdict"]
        rows.append(dict(cid=cid, fam=family_of(cid), kind=kind_of(cid), L=r.get("L", "-"),
                         target=r.get("target", "-"), delta=r.get("delta", "-"),
                         gap=r.get("gap", "-"), p4p3=r.get("p4p3", "-"), wait=r.get("wait", "-"),
                         mech=r.get("mech", "-"), verdict=v, note=r.get("note", "")))
    with tsv.open("w", encoding="utf-8") as f:
        f.write("case\tfamily\tkind\tL\ttarget\tdelta\tP3-P2\tP4-P3\twait\tmech\tverdict\tnote\n")
        for r in rows:
            f.write("\t".join(str(r[k]) for k in ("cid", "fam", "kind", "L", "target", "delta",
                                                  "gap", "p4p3", "wait", "mech", "verdict", "note"))
                    + "\n")

    n_pass = sum(1 for r in rows if r["verdict"] == "通过")
    n_defer = sum(1 for r in rows if r["verdict"] == "推迟")
    n_fail = len(rows) - n_pass - n_defer
    print("通过 %d / 推迟 %d / 未通过 %d（共 %d）" % (n_pass, n_defer, n_fail, len(rows)))
    for r in rows:
        if r["verdict"] == "未通过":
            print("  未通过：%s  %s" % (r["cid"], r["note"]))

    if o["report"]:
        fam = {}
        for r in rows:
            d = fam.setdefault(r["fam"], dict(t=0, p=0, f=0, d=0))
            d["t"] += 1
            d["p" if r["verdict"] == "通过" else "d" if r["verdict"] == "推迟" else "f"] += 1
        md = ["# 一致性报告（阶段 1：BE bypass / 时序机制）", "",
              "- DUT：`%s`　tag：`%s`　生成时间：%s" % (o["dut"], o["tag"],
                                                     datetime.now().strftime("%Y-%m-%d %H:%M")),
              "- 用例数：%d　通过：%d　推迟：%d　未通过：%d" % (len(rows), n_pass, n_defer, n_fail),
              "- 预期来源：`timing/diagrams/*.md`（图上槽位与机制）",
              "- 实测来源：仿真日志事件（DECODE / ISQ_FIRE / P3_BYPASS / COMMIT）", "",
              "## 按家族汇总", "", "| 家族 | 用例 | 通过 | 推迟 | 未通过 |", "|---|---|---|---|---|"]
        for k in sorted(fam):
            d = fam[k]
            md.append("| %s | %d | %d | %d | %d |" % (k, d["t"], d["p"], d["d"], d["f"]))
        md += ["", "## 逐条结果", "",
               "| 用例 | 类别 | L | 目标δ | 实测δ | P3−P2 | P4−P3 | 等待 | 机制(实测/期望) | 判定 |",
               "|---|---|---|---|---|---|---|---|---|---|"]
        for r in rows:
            md.append("| `%s` | %s | %s | %s | %s | %s | %s | %s | %s | %s |"
                      % (r["cid"], r["kind"], r["L"], r["target"], r["delta"], r["gap"],
                         r["p4p3"], r["wait"], r["mech"], r["verdict"]))
        md += ["", "说明：δ 为目标量时按「注入间隔 = 派发间隔」判定；`blocked` 类的 δ 是**输出量**，",
               "按机制判据判定（见 §结构性发现 6）。`推迟` 的条目见下。", ""]
        md += [FINDINGS, "", "## 推迟条目（保留，不删除）", "",
               "| 用例 | 原因 |", "|---|---|",
               "| `DIV_to_ALU_delta_6_p4blocked` | 需要一个晚于 DIV（L=4）写回才退休的阻塞物（L≥5）；"
               "当前整数 FU 为 FPU 1 / MUL 3 / LOAD 3 / DIV 4，没有够晚的阻塞物（实测 `P4−P3 = 1`）。"
               "**当前 latency 不支持这个 case 的构造，等未来替换内网算子之后再更新。** |", ""]
        rp = out / ("CONFORMANCE_%s_%s.md" % (o["tag"], o["dut"]))
        rp.write_text("\n".join(md) + "\n", encoding="utf-8")
        print("报告：%s" % rp)
        print("逐条结果：%s" % tsv)
    return 0 if n_fail == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
