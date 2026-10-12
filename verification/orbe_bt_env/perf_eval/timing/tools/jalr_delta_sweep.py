"""JALR 作 producer 的 delta 可达性扫描（rtl_full + 同 PC 预热）。

程序形态（JALR 与 dependent 都在循环内，第二次迭代才是被测的那遍）：

    la   x11, JT
    li   x12, 2
LOOP:
    mv   x10, x11          # 目标 = JT（JALR 的落空路径）
    jalr x5, 0(x10)        # producer
JT:
    <fillers>
    add  x6, x5, x3        # dependent
    addi x12, x12, -1
    bne  x12, x0, LOOP

JALR 固定在 G0/lane 0，所以填充物只能用 lane 2 的 fadd.s 或 lane 3 的 ld（bne/ALU 会抢 lane 0）。
判定：第二次执行的 JALR 必须 mispredict=0 且写回间隔=1；dependent 的**第二遍**实例必须提交，
且 delta = dep.P1 - jalr.P1 落在 0..4。
"""
import re
import subprocess
from pathlib import Path

ENV = Path("/work/home/danielle/workspace/suncheek/model/OpenRio/verification/orbe_bt_env")
W = Path("/work/home/danielle/workspace/suncheek/model/perf_eval_work/filler_exp")
TC = Path("/work/stu/yzhang/workspace/riscv/bin")
LINK = ENV / "perf_eval/templates/link.ld"
TAG, DUT = "timing_full", "rtl_full"

HEAD = """    .option norvc
    .section .text
    .globl _start
_start:
    addi x1, zero, 1
    addi x3, zero, 3
    la   x12, scratch
    li   x7, 0x6000
    csrs mstatus, x7
    la   x29, tohost
    addi x28, zero, 1
    la   x11, JT
    li   x12, 2
LOOP:
    mv   x10, x11
    jalr x5, 0(x10)
JT:
"""
TAIL = """    addi x12, x12, -1
    bne  x12, x0, LOOP
pass:
    sd   x28, 0(x29)
1:  j    1b
.section .data
scratch: .quad 0
"""


def fill(kind, n):
    if kind == "fp":
        return "".join("    fadd.s f%d, f1, f2\n" % (21 + i) for i in range(n))
    if kind == "ld":
        return "".join("    ld   x%d, 0(x12)\n" % (21 + i) for i in range(n))
    return ""


def run(tag, body):
    name = "JL_%s" % tag
    src = W / "cases" / (name + ".S")
    elf = W / "elf" / (name + ".elf")
    src.write_text(body, encoding="utf-8")
    if subprocess.run([str(TC / "riscv64-unknown-elf-gcc"), "-march=rv64imafdc", "-mabi=lp64d",
                       "-nostdlib", "-nostartfiles", "-Wl,-T," + str(LINK), "-o", str(elf),
                       str(src)], capture_output=True, text=True).returncode:
        return None
    subprocess.run([str(ENV / "tools/verilator_cosim.sh"), "run", "--no-build", "--dut-kind", DUT,
                    "--tag", TAG, "--verbosity", "2", "--timeout", "200000", "--tc", str(elf)],
                   capture_output=True, text=True)
    log = ENV / "sim" / ("verilator_" + TAG) / "log" / DUT / (name + "_1") / "sim.log"
    return log.read_text(errors="replace") if log.exists() else None


def parse(txt, elf):
    od = subprocess.run([str(TC / "riscv64-unknown-elf-objdump"), "-d", str(elf)],
                        capture_output=True, text=True).stdout
    jpc = dpc = None
    for line in od.split("\n"):
        m = re.match(r"^\s+([0-9a-f]+):\s+([0-9a-f]{8})\s+(\w+)", line)
        if not m:
            continue
        rd = (int(m.group(2), 16) >> 7) & 31
        if m.group(3) == "jalr" and rd == 5:
            jpc = int(m.group(1), 16)
        if m.group(3) == "add" and rd == 6 and dpc is None:
            dpc = int(m.group(1), 16)
    cur, inst, seq = {}, {}, 0
    for line in txt.split("\n"):
        m = re.search(r"\[BE\]\[DECODE\] cycle=(\d+) .*tag=(\S+) .*pc=(\S+)", line)
        if m:
            seq += 1
            cur[m.group(2)] = seq
            inst[seq] = dict(pc=int(m.group(3), 16), P1=int(m.group(1)))
            continue
        m = re.search(r"\[ISQ_FIRE\] cycle=(\d+) group=\d+ tag=(\S+)", line)
        if m and m.group(2) in cur:
            inst[cur[m.group(2)]].setdefault("P2", int(m.group(1))); continue
        m = re.search(r"\[P3_BYPASS\] cycle=(\d+) lane=\d+ tag=(\S+)", line)
        if m and m.group(2) in cur:
            inst[cur[m.group(2)]].setdefault("P3", int(m.group(1))); continue
        m = re.search(r"\[FU_WB\] cycle=(\d+) .*tag=(\S+) result=\S+ mispredict=(\d)", line)
        if m and m.group(2) in cur:
            inst[cur[m.group(2)]]["mis"] = int(m.group(3)); continue
        m = re.search(r"\[BE\]\[COMMIT\] cycle=(\d+) .*tag=(\S+)", line)
        if m and m.group(2) in cur:
            inst[cur[m.group(2)]].setdefault("P4", int(m.group(1)))
    js = sorted([e for e in inst.values() if e["pc"] == jpc], key=lambda e: e["P1"])
    ds = sorted([e for e in inst.values() if e["pc"] == dpc], key=lambda e: e["P1"])
    return js, ds


for kind in ("fp", "ld"):
    print("################ 填充物 %s（JALR 之前 + dependent 之前）" % kind)
    for n in range(0, 11):
        body = HEAD + fill(kind, n) + "    add  x6, x5, x3\n" + TAIL
        name = "JL_%s_%d" % (kind, n)
        txt = run("%s_%d" % (kind, n), body)
        if txt is None:
            print("  n=%-2d 无日志" % n); continue
        elf = W / "elf" / (name + ".elf")
        js, ds = parse(txt, elf)
        if len(js) < 2 or len(ds) < 2:
            print("  n=%-2d JALR 执行 %d 次, dependent %d 次（不足两次）" % (n, len(js), len(ds)))
            continue
        # JALR：取 mispredict=0 的那次（预测命中的那次，即第二次迭代）
        pred = [e for e in js if e.get("mis") == 0]
        if not pred:
            print("  n=%-2d 没有任何一次 JALR 是 mispredict=0（共 %d 次）" % (n, len(js))); continue
        j2 = pred[-1]
        # dependent：取在该 JALR 之后派发、且**提交**的实例
        cand = [e for e in ds if e["P1"] >= j2["P1"] and "P4" in e]
        if not cand:
            print("  n=%-2d 该 JALR 之后没有提交的 dependent 实例" % n); continue
        d2 = cand[0]
        delta = d2["P1"] - j2["P1"]
        gap = (j2.get("P3", 0) - j2.get("P2", 0)) if "P3" in j2 and "P2" in j2 else None
        ok = (j2.get("mis") == 0 and gap == 1 and 0 <= delta <= 4 and "P4" in d2)
        print("  n=%-2d 第2次: jalr P1=%-3s mis=%-2s gap=%-3s | dep P1=%-3s δ=%-3s 提交=%-3s %s"
              % (n, j2["P1"], j2.get("mis", "-"), gap, d2["P1"], delta,
                 "是" if "P4" in d2 else "否", "← 命中" if ok else ""))
    print()
