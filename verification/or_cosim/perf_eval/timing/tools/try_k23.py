import re, subprocess
from pathlib import Path
import runpy

# 复用 diag_m.py 里的工具函数（它定义了 SETUP/chain/run 等），但不执行它的主循环
src = Path("/tmp/diag_m.py").read_text(encoding="utf-8")
head = src.split('print("k=1')[0]
ns = {}
exec(compile(head, "diag_head", "exec"), ns)
SETUP = ns["SETUP"]; COMMIT = ns["COMMIT"]; BYPASS = ns["BYPASS"]
chain = ns["chain"]; run = ns["run"]

for k in (2, 3):
    print("=== k=%d" % k)
    print("  m | ld.P4 | mul.P3 | dep.P1 | 三点同拍")
    for m in range(0, 10):
        body = (SETUP + COMMIT + "\n" + chain(k, 0) + BYPASS + "\n" + chain(m, k)
                + "    add  x20, x6, x8\n")
        p, out = run("k%dm%d" % (k, m), body)
        if not out:
            continue
        bypc, dyn = out
        c = bypc.get(p.get("C"), {})
        b = bypc.get(p.get("P"), {})
        q = bypc.get(p.get("DEP"), {})
        ok = (c.get("P4") == b.get("P3") == q.get("P1"))
        print("  %-3d %-6s %-7s %-7s %s" % (m, c.get("P4"), b.get("P3"), q.get("P1"),
                                            "是" if ok else ""))
