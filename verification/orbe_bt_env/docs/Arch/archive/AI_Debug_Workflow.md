# AI Debug Workflow

## 1. 目标

这份 workflow 用来定义 ORBE BT 环境里的“有约束 AI debug 迭代”闭环：AI 读取 `.log`、checker 输出和 Arch 文档，按固定 stage 逐层比对 ISA_model 和 DUT，定位第一个 mismatch，修正后立即回归，直到 RTL 通过全部 216 条 `ISA_Case`。

## 2. 核心原则

| 原则 | 要求 |
| --- | --- |
| 能打印就打印 | 对 FE / BE-LSU 接口里能直接观测或由字段计算得到的信号全部打印，不做第一批/第二批收敛。 |
| 分 stage 比对 | 每个打印节点都要能对应到 ISA_model 的某个 DPI 入口或状态快照。 |
| 先停第一处 mismatch | 一旦某个 stage 不一致，立即停止后续 stage 比对，避免被下游连锁错误干扰。 |

## 3. 定位规则

1. 以**最早出现 mismatch 的 stage** 作为根因定位点。
2. 以上一个**打印节点**作为 bug 可能发生的原点。
3. 锁定“原点”和“根因定位点”之间的所有 Submodule ，将这些submodule 称为“可疑 module ”，缩小 debug 范围。

## 4. 建议的 debug 闭环

1. 跑单个 case，收集 DUT `.log`、checker 输出和 ISA_model 参考结果。
2. 按 stage 顺序对齐，并与 ISA_model 结果比较。
3. 重新跑同一个 case，确认该 stage 收敛后再推进下一 stage / 打印节点。

## 5. 接口级打印清单

有具体的打印信号清单，待补充。

## 6. 输出要求

默认只打印 mismatch 的那条指令，不打印正常路径。

1. 只保留最早出错的那条指令；同一根因导致的后续连锁 mismatch 不重复打印。
2. 错指令打印全量信息，包括 `stage`、`cycle`、`pc`、`tag` 或 `rob_idx`、接口原始 payload、派生字段、`expected_<>`、`actual_<>`。
3. 若 mismatch 由 `redirect`、`flush`、fetch exception、wakeup 或 done/exception 竞争触发，保留触发源的最小上下文，但不展开正常路径。
4. 所有打印都以定位为目的，不输出与错误无关的背景信息。
