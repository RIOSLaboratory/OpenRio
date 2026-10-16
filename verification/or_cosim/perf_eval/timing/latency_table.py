#!/usr/bin/env python3
"""latency_table.py -- FU 延迟的唯一权威副本。

这些值是**实测**得到的，出处：`latency_bench/Latency_Report.md` 第 16-23 行与 §3.4，
测量条件为 OpenRio `589ca8f`、`--dut-kind rtl_full`。

含义是"生产者自身的延迟"，即从 `[ISQ_FIRE]`（发射拍）到 `[P3_BYPASS]`（结果对 BE 可见）
之间的拍差。因此对任何生产者，干净写回间隔 `P3 - P2` 恰好等于该值。

为什么要有这个文件：这张表原先在 `lane_check.py`、`compare.py`、`filler_calib.py` 里各有
一份拷贝，而标定脚本里又反复手抄。2026-10 标定 `INT2_G1P3_G0P3` 时，DIV 的间隔被手抄成 5
（实际 4），不仅让搜索失败，还导致一个**错误的中间结论被报告出去**。数字只在一处定义、
其余一律导入，是这条教训的直接对策。

关于 JALR：它在本 case 集里**只作 consumer**，依赖公式取的是**上游生产者的 L**，不是这个表
里的 1。表里 JALR=1 是它自己作为生产者时的 link 值延迟，仅在它作生产者时才用；本 case 集
不用这个口径。同理，加载的 3 是整数 LOAD 的延迟，`flw/fld` 也是 3。
"""

# producer latency: issue -> result visible to BE (P3).  P3 delta = L + 1.
L_OF = {
    "ALU": 1,
    "MUL": 3,
    "DIV": 4,
    "LOAD": 3,
    "JALR": 1,      # 仅当 JALR 作生产者（link 值）；本 case 集不用
    "BRU": 1,
}

# JALR 另有一个不进依赖公式的控制流口径，留档用
JALR_REDIRECT_READY = 2
