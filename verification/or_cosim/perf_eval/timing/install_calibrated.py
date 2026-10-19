#!/usr/bin/env python3
"""install_calibrated.py -- 把固化用例装进跑批目录。

`calibrated_cases/` 下的 .S 是人工标定、逐条复核过的版本。跑批读的是
`perf_eval_work/elf/*.elf`，那是 gen_cases.py 从 caselist 生成的版本，两者不是一回事：
没有这一步，跑批用到的仍是未标定的程序，标定结果对最终比对没有贡献。

本步骤做两件事：
  1. 把 calibrated_cases/*.S 复制到 $WORK/cases/
  2. 逐个编译成 $WORK/elf/

复制之后 gen_cases.py 会拒绝覆盖这些文件（它的守卫要求磁盘内容与本次渲染一致，
或与它自己记录的哈希一致），这正是想要的效果：手工标定的版本不会被重新生成冲掉。
"""
import shutil
import subprocess
import sys
from pathlib import Path

ENV = Path(__file__).resolve().parents[2]          # verification/or_cosim
SRC = ENV / "perf_eval/timing/calibrated_cases"
WORK = Path("/work/home/danielle/workspace/suncheek/model/perf_eval_work")
GCC = Path("/work/stu/yzhang/workspace/riscv/bin/riscv64-unknown-elf-gcc")
LINK = ENV / "perf_eval/templates/link.ld"
MARCH, MABI = "rv64imafdc", "lp64d"


def main() -> int:
    dry = "--dry-run" in sys.argv
    (WORK / "cases").mkdir(parents=True, exist_ok=True)
    (WORK / "elf").mkdir(parents=True, exist_ok=True)

    sources = sorted(SRC.glob("*.S"))
    if not sources:
        print("calibrated_cases 下没有 .S，什么都没做")
        return 1

    copied, built, failed = [], [], []
    for s in sources:
        dst = WORK / "cases" / s.name
        if not dry:
            shutil.copyfile(s, dst)
        copied.append(s.name)

        elf = WORK / "elf" / (s.stem + ".elf")
        if dry:
            built.append(s.stem)
            continue
        r = subprocess.run([str(GCC), "-march=" + MARCH, "-mabi=" + MABI, "-nostdlib",
                            "-nostartfiles", "-Wl,-T," + str(LINK), "-o", str(elf), str(dst)],
                           capture_output=True, text=True)
        if r.returncode:
            failed.append((s.stem, r.stderr.strip().splitlines()[0][:100]))
        else:
            built.append(s.stem)

    print("已安装固化用例: %d 个（%s）" % (len(copied), "试运行，未落盘" if dry else "已复制并编译"))
    print("  写入 %s" % (WORK / "cases"))
    print("  编译输出 %s" % (WORK / "elf"))
    single = [c for c in copied if "_to_" in c]
    two = [c for c in copied if c.startswith("INT2_")]
    print("  其中单操作数 %d 个，两操作数 %d 个" % (len(single), len(two)))
    if failed:
        print("编译失败的 %d 个:" % len(failed))
        for cid, err in failed:
            print("  %-28s %s" % (cid, err))
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
