# 手工标定的用例（冻结）

本目录存放**人工标定**出来的用例源文件。**`gen_cases.py` 不得写入这里**，`run_perf.sh`
默认也不再重新生成（需要显式 `--regen`）。

## 为什么需要这个目录

自动配方（每个 delta 用 `2δ−1` 条单周期 ALU 填充物）在下面这种情形下不可用：
生产者是**多周期且固定在 G0 或 G1** 的指令时，每拍两条派发意味着每拍两条写回，
G0 与 G1 两条 lane 恒满，生产者会反复输掉写回仲裁。

实测例子：`MUL_to_ALU_delta_4` 的 MUL 写回从 issue+3 被推迟到 issue+6。
后果是该用例**不再复现它要测的场景**，机制那一半无法判定。

## 构造规则

| 项 | 规则 |
|---|---|
| 生产者 | MUL 固定 G1；DIV 固定 G0；ALU 单周期，两者皆可 |
| 依赖者 | `add x6, x5, x3`（整数 ALU）；JALR 作依赖者时见下节 |
| 填充物 | 必须避开生产者的写回 lane：`ld` 走 G3（lane 3），`fadd.s` 走 G2（lane 2） |
| 填充物条数 | **没有公式**，条数与 delta 的关系必须实测。本目录的配方就是实测结果 |
| 前导寄存器 | `x1`–`x4` 为输入；`ld` 填充物需要有效地址，故 `la x12, scratch` 并在 `.data` 定义 `scratch` |
| 浮点填充物 | 必须先开 FS：`li x11, 0x6000`、`csrs mstatus, x11`（注意不能占用 `x5`） |
| 段边界 | 退出段用 `9:` 作自旋标签，避免与模板的 `1:` 冲突 |

## 配方表（均已实测复核）

| 用例 | 生产者 | 填充物 | 实测 delta | 生产者写回 |
|---|---|---|---|---|
| `MUL_to_ALU_delta_2` | `mul x5,x1,x2` | 1 条 `ld` + 2 条 `fadd.s` | 2 | 3 = L |
| `MUL_to_ALU_delta_3` | 同上 | 3 条 `fadd.s` | 3 | 3 |
| `MUL_to_ALU_delta_4` | 同上 | 1 条 `ld` + 3 条 `fadd.s` | 4 | 3 |
| `MUL_to_ALU_delta_5` | 同上 | 4 条 `fadd.s` | 5 | 3 |
| `MUL_to_ALU_delta_6` | 同上 | 1 条 `ld` + 4 条 `fadd.s` | 6 | 3 |
| `DIV_to_ALU_delta_4` | `div x5,x1,x2` | 1 条 `ld` + 3 条 `fadd.s` | 4 | 4 = L |
| `DIV_to_ALU_delta_5` | 同上 | 4 条 `fadd.s` | 5 | 4 |
| `DIV_to_ALU_delta_6` | 同上 | 1 条 `ld` + 4 条 `fadd.s` | 6 | 4 |
| `DIV_to_ALU_delta_7` | 同上 | 2 条 `ld` + 4 条 `fadd.s` | 7 | 4 |

JALR 作依赖者（生产者 `addi x10, x11, 0`，即 `mv a0, a1`，L=1），填充物为普通 ALU：

| 用例 | 填充物条数 | 实测 delta |
|---|---|---|
| `ALU_to_JALR_delta_2` | 0 | 2 |
| `ALU_to_JALR_delta_3` | 2 | 3 |
| `ALU_to_JALR_delta_4` | 4 | 4 |
| `ALU_to_JALR_delta_5` | 6 | 5 |
| `ALU_to_JALR_delta_6` | 8 | 6 |

关系为 `delta = 2 + floor(k/2)`。此形态下生产者写回始终等于 L=1，没有 lane 争用，
因此不需要 `ld`+`fadd.s` 混合配方。

## JALR 只作依赖者

原设计的 JALR 是生产者，产出链接值（`rd = PC + 4`）。问题在于它同时是跳转指令：
产出链接值与改变控制流挤在同一个窗口里，控制流会把依赖者冲掉。若跳转目标寄存器
未初始化（模板只设 `x1`–`x4`，`x10` 为 0），程序会跳到地址 0 并烧满仿真超时。

改为依赖者后，这件问题在结构上消失：JALR 消费的是 `rs1`，即跳转目标寄存器，
该值由前面的生产者写入，因此目标必然有效。跳转依旧发生，但必须让它落在
**紧邻的下一条**（落空地址），否则重定向会跳过窗口内的填充物，delta 全部失效。

实测证据（`ALU_to_JALR_*`）：九个变体全部正常退出，`is_good=1`，无超时；
提交条数随填充物条数线性增加，说明窗口内没有指令被跳过。

## 尚存的限制

- **最小 delta 是 2**。生产者与 JALR 在程序中紧邻时 delta 仍为 2，这是 JALR
  作为控制指令的固有代价。因此"ALU 生产者 + JALR"只能覆盖 delta 2、3、4，
  即 `p3_capture`、`p4_capture`、`arf_read` 三档。
  若要覆盖五档机制，需改配 MUL 生产者（L=3，阶梯 0 到 6），此时可达的
  delta 2 到 6 正好对应 `wait_for_p3`、`wait_for_p3`、`p3_capture`、
  `p4_capture`、`arf_read`。该选择尚未裁定。
- **用例命名已不匹配**。旧名 `JALR_to_ALU_delta_N` 表达的是"JALR 作生产者"，
  与现在的形态不符，本目录采用 `ALU_to_JALR_delta_N`。caselist 需要相应改写。
- **`DIV_to_ALU_delta_0` 尚无干净配方**。delta=0 意味零填充物，依赖者紧贴 `div`，
  而 `div` 是串行指令，不能与之同拍派发，因此该形态下最小 delta 为 1 而非 0。
  生成版曾测得 delta=0，说明它用了不同的排布，差异尚未查明。
- **两操作数用例尚未标定**。其中 8 条（`INT2_*G1P3*`）同样受写回 lane 争用影响。
