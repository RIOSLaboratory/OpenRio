# 手工标定的用例（冻结）

> **2026-10-22 范围变更**：汇编 `.S` 用例已退出 timing diagram 流程。当前
> diagram/caselist 采用 IB stimulus 注入，不再以 `.S` 的标定结果作为 diagram 依据。
> 本目录仅保留为历史 RTL 回归资产，不随 `latency_table.py` 的内网 latency 变更而重标定。

本目录存放**人工标定**出来的用例源文件。`gen_cases.py` 不会写入这里，`run_perf.sh`
默认也不再重新生成（需要显式 `--regen`）。

每个文件都经过复核：实测 delta 与文件名一致，生产者写回等于该家族的干净延迟 L，
无仿真超时，模型正常退出。当前 18 个文件全部通过。

## 为什么需要这个目录

自动配方（每个 delta 用 `2δ−1` 条单周期 ALU 填充物）在两种情形下不可用。

**其一，生产者是多周期且固定在 G0 或 G1 的指令。** 每拍两条派发意味着每拍两条写回，
G0 与 G1 两条 lane 恒满，生产者会反复输掉写回仲裁。实测：`MUL_to_ALU_delta_4` 的
MUL 写回从 issue+3 被推迟到 issue+6，该用例便不再复现它要测的场景。

**其二，delta 等于 0（零填充物）。** 此时窗口内没有任何填充物来吸收流量，抢 lane 的
变成**退出段**：`addi x28`、`la x29`、`sd` 都是独立指令，会在生产者的写回窗口内派发。
实测：`DIV_to_ALU_delta_0` 在退出记账位于生产者之后时写回为 7（干净值 4），
把退出记账提前到生产者之前，写回立刻回到 4，delta 仍为 0。`bench.py` 处理同一问题时
用的也是这个做法。

## 构造规则

| 项 | 规则 |
|---|---|
| 生产者 | MUL 固定 G1；DIV 固定 G0；ALU 单周期 |
| 依赖者 | `add x6, x5, x3`（整数 ALU）；JALR 作依赖者时见下节 |
| 填充物 | 必须避开生产者的写回 lane：`ld` 走 G3（lane 3），`fadd.s` 走 G2（lane 2） |
| 填充物条数 | 没有公式，条数与 delta 的关系必须实测。本目录的配方即实测结果 |
| 退出记账 | **生产者之前**。这是通用做法，delta=0 时尤其是必要条件 |
| 地址寄存器 | `ld` 填充物需要有效地址：`la x12, scratch`，并在 `.data` 定义 `scratch` |
| 浮点填充物 | 必须先开 FS：`li x7, 0x6000`、`csrs mstatus, x7`（不要占用 `x5`） |
| 自旋标签 | 退出段用 `9:`，避免与模板的 `1:` 冲突 |

## 配方表（均已实测复核）

生产者 `mul x5,x1,x2`，依赖者 `add x6,x5,x3`，L=3：

| 用例 | 填充物 | 实测 delta | 生产者写回 |
|---|---|---|---|
| `MUL_to_ALU_delta_0` | 无（退出记账已提前）| 0 | 3 |
| `MUL_to_ALU_delta_2` | 1 条 `ld` + 2 条 `fadd.s` | 2 | 3 |
| `MUL_to_ALU_delta_3` | 3 条 `fadd.s` | 3 | 3 |
| `MUL_to_ALU_delta_4` | 1 条 `ld` + 3 条 `fadd.s` | 4 | 3 |
| `MUL_to_ALU_delta_5` | 4 条 `fadd.s` | 5 | 3 |
| `MUL_to_ALU_delta_6` | 1 条 `ld` + 4 条 `fadd.s` | 6 | 3 |

生产者 `div x5,x1,x2`，L=4：

| 用例 | 填充物 | 实测 delta | 生产者写回 |
|---|---|---|---|
| `DIV_to_ALU_delta_0` | 无（退出记账已提前）| 0 | 4 |
| `DIV_to_ALU_delta_4` | 1 条 `ld` + 3 条 `fadd.s` | 4 | 4 |
| `DIV_to_ALU_delta_5` | 4 条 `fadd.s` | 5 | 4 |
| `DIV_to_ALU_delta_6` | 1 条 `ld` + 4 条 `fadd.s` | 6 | 4 |
| `DIV_to_ALU_delta_7` | 2 条 `ld` + 4 条 `fadd.s` | 7 | 4 |

DIV 的 delta 1 到 3 尚未标定。

## 链式填充物（用于混合源用例）

混合源用例要求两个生产者各自的边界与 dependent 的解析拍落在同一周期，例如
`INT2_P4_G3P3` 要求"提交侧的 P4 = LOAD 的 P3 = dependent 的 P1"。

只用两个旋钮（谁在前、间距多少）调不出来。用互相独立的单周期 ALU 填充物时，
每拍派发的两条里有一条会落到 G1；若提交侧生产者是 MUL（固定 G1），就会被抢走
写回，它的 P3 与 P4 一路后移。实测：提交侧的 P4 随 dependent 前的填充物条数
走出 20、21、22、23，而 LOAD 的 P3 停在 20。

改用**依赖链填充物**可以同时满足两个要求：每条 `addi` 依赖前一条，因此逐拍就位；
每拍只有一条 ALU 操作，路由必然落在 G0，于是 G1 上的提交侧生产者独占自己的 lane。
实测：提交侧的 P4 恒等于 P1+5 不再漂移，dependent 的 P1 以一拍为步长推进。

`INT2_P4_G3P3` 的配方：提交侧 `mul`，其后 1 条链节，然后 `ld`，再 5 条链节，
最后 dependent。复核值：`mul.P4 = ld.P3 = dep.P1 = 12`。

注意这一行的**组合者**与 caselist 的 Instructions 列不同：caselist 写的是提交侧为
ALU，但 ALU 作提交侧时 `P1+3` 与 LOAD 的 P3 根本对不齐（已实测），故固化文件改用
MUL。dependent 看到的两路源形状不变（一路 Commit CDB、一路 G3 P3 旁路），
被测的组合因此没有改变，但 caselist 的 Instructions 列需要同步修改。

## JALR 只作依赖者

原设计的 JALR 是生产者，产出链接值（`rd = PC + 4`）。问题在于它同时是跳转指令，
产出链接值与改变控制流挤在同一窗口，控制流会把依赖者冲掉。若跳转目标寄存器
未初始化（模板只设 `x1`–`x4`，`x10` 为 0），程序跳到地址 0 并烧满仿真超时。

改为依赖者后问题在结构上消失：JALR 消费 `rs1`，即跳转目标寄存器，该值由生产者写入，
目标必然有效。跳转仍会发生，但必须落在**紧邻的下一条**，否则重定向会跳过窗口内的
填充物，delta 全部失效。

生产者需要产出**有效地址**。用乘 1 通过地址即可：`x11` 指向 `pass`，`x1` 等于 1，
生产者写 `mul x10, x11, x1`，结果仍是 `pass`。这样既保留多周期生产者，又保证目标有效。

生产者 `mul x10,x11,x1`（L=3），依赖者 `jalr x5,0(x10)`：

| 用例 | 填充物 | 实测 delta | 生产者写回 |
|---|---|---|---|
| `MUL_to_JALR_delta_0` | 无 | 0 | 3 |
| `MUL_to_JALR_delta_1` | 1 条 `fadd.s` | 1 | 3 |
| `MUL_to_JALR_delta_2` | 1 条 `ld` + 2 条 `fadd.s` | 2 | 3 |
| `MUL_to_JALR_delta_3` | 3 条 `fadd.s` | 3 | 3 |
| `MUL_to_JALR_delta_4` | 1 条 `ld` + 3 条 `fadd.s` | 4 | 3 |
| `MUL_to_JALR_delta_5` | 4 条 `fadd.s` | 5 | 3 |
| `MUL_to_JALR_delta_6` | 1 条 `ld` + 4 条 `fadd.s` | 6 | 3 |

## 需要裁定的两件事

**其一，JALR 家族的条数从 5 变成 7。** 原 caselist 对该家族取 L=1，阶梯是 delta 0 到 4。
JALR 改为依赖者后，阶梯由生产者的 L 决定。选 MUL 生产者（L=3）可得完整七行，
覆盖 `overlay`、三档 `wait_for_p3`、`p3_capture`、`p4_capture`、`arf_read`；
若选 ALU 生产者（L=1），实测最小 delta 是 2 而非 0，只能覆盖 delta 2、3、4 三档。
本目录取前者（七行）。单操作数总数会由 32 变成 34。

**其二，用例命名。** 旧名 `JALR_to_ALU_delta_N` 表达的是 JALR 作生产者，与现在的形态
相反。本目录采用 `MUL_to_JALR_delta_N`，caselist 需要相应改写。

## 尚存的限制

- **两操作数用例尚未标定。** 其中 8 条（`INT2_*G1P3*`）同样受写回 lane 争用影响。
  它们的填充物分布在三个间隔里，且要同时满足两个 producer 相对 dependent 的 delta，
  属于联合求解，比单间隔情形复杂。
- **DIV 的 delta 1 到 3 尚未标定**，上面已注明。
