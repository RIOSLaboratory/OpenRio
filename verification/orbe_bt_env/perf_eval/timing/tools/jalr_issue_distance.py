"""隔离实验：JALR 的派发→发射那一拍，是它自身的属性，还是前一条指令占着 G0 ISQ 条目所致。

做法：JALR 固定走 G0。若前任在 G0 占用条目，JALR 就要多等；若把前任换成 G3(ld)/G2(fadd)，
G0 应当空出来。比较 JALR 的 P1→P2。
"""
import re
import subprocess
from pathlib import Path

ENV = Path("/work/home/danielle/workspace/suncheek/model/OpenRio/verification/orbe_bt_env")
W = Path("/work/home/danielle/workspace/suncheek/model/perf_eval_work/filler_exp")
TC = Path("/work/stu/yzhang/workspace/riscv/bin")
LINK = ENV / "perf_eval/templates/link.ld"
HEAD = """    addi x1, zero, 1
    addi x2, zero, 2
    addi x3, zero, 3
    la   x12, scratch
    li   x7, 0x6000
    csrs mstatus, x7
    la   x29, tohost
    addi x28, zero, 1
"""
TAIL = """pass:
    sd   x28, 0(x29)
9:  wfi
    j    9b
.section .data
scratch: .quad 0
"""

VARIANTS = {
    "baseline":       "    la   x10, after\n",
    "pred_ld_G3":     "    la   x10, after\n    ld   x21, 0(x12)\n",
    "pred_fadd_G2":   "    la   x10, after\n    fadd.s f21, f1, f2\n",
    "pred_alu_G0":    "    la   x10, after\n    add  x21, x0, x1\n",
    "pred_bne_G0":    "    la   x10, after\n    bne  x0, x0, 30f\n30:\n",
}

for name, pre in VARIANTS.items():
    body = (".option norvc\n.section .text\n.globl _start\n_start:\n" + HEAD + pre
            + "    jalr x5, 0(x10)\nafter:\n    add  x6, x5, x3\n" + TAIL)
    src = W / "cases" / ("JP_%s.S" % name)
    elf = W / "elf" / ("JP_%s.elf" % name)
    src.write_text(body, encoding="utf-8")
    r = subprocess.run([str(TC / "riscv64-unknown-elf-gcc"), "-march=rv64imafdc", "-mabi=lp64d",
                        "-nostdlib", "-nostartfiles", "-Wl,-T," + str(LINK), "-o", str(elf), str(src)],
                       capture_output=True, text=True)
    if r.returncode:
        print("  %-14s 编译失败" % name); continue
    subprocess.run([str(ENV / "tools/verilator_cosim.sh"), "run", "--no-build", "--dut-kind", "rtl_v1",
                    "--tag", "timing_delta", "--verbosity", "2", "--timeout", "20000", "--tc", str(elf)],
                   capture_output=True, text=True)
    log = ENV / "sim/verilator_timing_delta/log/rtl_v1" / ("JP_%s_1" % name) / "sim.log"
    if not log.exists():
        print("  %-14s 无日志" % name); continue
    txt = log.read_text(errors="replace")
    # 找到 JALR（inst 末字节 e7）的 P1/P2/P3
    cur, ev = {}, {}
    for line in txt.split("\n"):
        m = re.search(r"\[BE\]\[DECODE\] cycle=(\d+) .*tag=(\S+) .*pc=(\S+) .*inst=(\S+)", line)
        if m:
            cur[m.group(2)] = m.group(4)
            ev.setdefault(m.group(4), {})["P1"] = int(m.group(1)); continue
        m = re.search(r"\[ISQ_FIRE\] cycle=(\d+) group=(\d+) tag=(\S+)", line)
        if m and m.group(3) in cur:
            ev[cur[m.group(3)]].setdefault("P2", int(m.group(1)))
            ev[cur[m.group(3)]]["grp"] = int(m.group(2)); continue
        m = re.search(r"\[FU_WB\] cycle=(\d+) .*tag=(\S+)", line)
        if m and m.group(2) in cur:
            ev[cur[m.group(2)]].setdefault("P3", int(m.group(1)))
    jalrs = [(i, e) for i, e in ev.items() if i.endswith("e7")]
    nred = len(re.findall(r"\[BE\]\[REDIRECT\]", txt))
    for i, e in jalrs[:1]:
        d = (e.get("P2", 0) - e.get("P1", 0)) if "P2" in e else None
        print("  %-14s JALR P1=%-4s P2=%-4s P3=%-4s 派发→发射=%-3s grp=%-3s 重定向=%d"
              % (name, e.get("P1"), e.get("P2"), e.get("P3"), d, e.get("grp"), nred))
