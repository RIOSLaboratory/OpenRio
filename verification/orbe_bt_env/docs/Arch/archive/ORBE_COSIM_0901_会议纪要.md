# ORBE COSIM 9/1 会议纪要

## 1. 会议核心结论

当前目标不是马上修改 COSIM 比较逻辑，而是先重新定义 ORBE COSIM 需要从验证环境中观察、打印和拉取哪些信息。

工作重点从“按未来实现阶段分批做功能”调整为“按信号所属模块和用途定义 COSIM 观察面”。后续需要先明确哪些信息应稳定打印成 `.log`，再把同类信息通过 `ob_cosim_if` 拉出，最后交给 COSIM 相关模块读取和比较。

## 2. 接口命名和职责边界

COSIM 相关观察接口统一命名为 `ob_cosim_if`。此前文档中使用的 `ob_if` 不再适合作为 COSIM 专用观察接口名称。

`ob_cosim_if` 的职责是承载从 ORBE RTL 或验证环境中抓取出来、供 COSIM 使用的观察信号。COSIM 相关代码应依赖 `ob_cosim_if` 这个稳定观察边界，而不是直接依赖 RTL 层级路径、内部实现名称或 BETA/P600 专用类型。

需要明确区分两类信息：

- 从 RTL 或验证环境抓出来的信号，例如 Commit、INT ARF、FP ARF、CSR、MEM。
- COSIM 侧自己生成的辅助诊断信息，例如 `cycle`、`sequence_id`。

其中 `cycle` 和 `sequence_id` 不属于 `ob_cosim_if` 抓取信号。它们是 COSIM 侧的 counter 类逻辑，用于日志定位、事件排序和问题诊断。

## 3. 通道命名修正

原文档中使用 `lane` 描述并行提交通道，这个词不够准确。后续文档中应改为“两组信号”或“两组通道”的说法：

- 第 0 组信号 / 第 0 组通道
- 第 1 组信号 / 第 1 组通道

这表示 ORBE 当前观察面有两组并行 commit/观察通道，而不是强调一个抽象的 `lane` 概念。

## 4. 新信号抓取计划的组织方式

后续需要单独写一份新的信号抓取 plan，回答一个核心问题：

> ORBE COSIM 到底要抓哪些信号？

这份新 plan 不应再按照“第一批、第二批、第三批”的实现阶段分类，而应按照信号所属部分分类，例如：

- Commit 相关信号
- INT ARF 相关信号
- FP ARF 相关信号
- CSR 相关信号
- MEM 相关信号

这种分类方式更适合定义 COSIM 观察面，也更容易和后续 `ob_cosim_if` 的字段组织对应。

## 5. 当前信号缺口判断

现有 COSIM 计划文档中列出的抓取信息仍不完整，主要缺少两类：

1. CSR 相关信号
2. MEM 相关信号

MEM 相关信号也需要进入 `be_agent`，其源头来自 `cache_agent`。因此未来 COSIM 观察面不能只覆盖 Commit 和 INT/FP ARF，还需要包含 memory 行为相关信息。

## 6. Trap 当前阶段处理范围

现阶段 COSIM 先不单独追踪 trap 相关信息。当前判断是：trap PC 可以先按普通 commit PC 处理，`mcause` 也暂时不作为 COSIM 必抓信号。

这一点只限定当前阶段的 COSIM bringup 和观察面定义。未来如果要做异常精确校验、CSR 精确状态比较或 trap handler 路径覆盖，再重新把 trap 相关信息纳入 COSIM 观察信号。

## 7. ARF 观察方式

ARF 仍然坚持从 INT ARF 和 FP ARF 直连观察出来。COSIM 侧通过 `ob_cosim_if` 读取这些架构状态，从而保持 COSIM 逻辑与 RTL 内部实现解耦。

设想的物理实现方式如下：

- INT ARF：32 个寄存器，每个 64 bit。
- FP ARF：32 个寄存器，每个 64 bit。
- 总计：64 个寄存器 x 64 bit = 4096 bit 观察信号。

这里的核心观念是直接抓完整架构寄存器快照，而不是只抓某条提交指令写了哪个 `rd`。

## 8. `rd` / `rd_valid` 观念修正

此前的观点是：既要比较 `rd` 对应的写回数据，也要提取完整 `ARF[0:31]` 快照。

现在修正为：如果已经提取完整的 `INT ARF[0:31]` 和 `FP ARF[0:31]`，就不必再把 `rd` 和 `rd_valid` 作为核心比较信号单独抓取。

`rd` / `rd_valid` 最多可以作为辅助诊断信息，而不应作为必须抓取的主路径。真正的架构状态比较可以基于完整 ARF 快照完成。

但 Commit 事件本身仍然必须保留，因为 COSIM 需要知道什么时候推进 reference、什么时候比较架构状态，以及两组通道的提交顺序。也就是说，可以弱化或删除 `rd` / `rd_valid` 的核心地位，但不能删除 Commit event。

## 9. 当前 COSIM 实验定位

现在把 COSIM 接到当前验证环境上做实验没有异议，但需要明确它的价值边界。

当前 `mock_rtl` 内部本身调用 ISA_model，因此这类 COSIM 实验不太可能暴露真实功能错误。它的主要价值是验证基础设施：

- 环境通路是否打通。
- 接口组织是否合理。
- 打印内容和日志格式是否稳定。
- COSIM 数据流是否能正确连接和消费。

因此，当前阶段跑 COSIM 的意义是打通 infrastructure，而不是证明真实 ORBE RTL 的功能正确性。

## 10. 当前最优先工作

当前最优先的工作不是写最终 COSIM checker，而是先确定要 print 哪些信息。

参考文档：`ORBE_BT_ENV_debug_and_print.md`。

这些信息应稳定打印成 `.log`。它们不是错误日志，不应只包含 `[fault]`、`[error]` 这类失败信息，也应包含正常运行过程中的观察信息。

推荐路径如下：

1. 先确定需要 print 的信息集合。
2. 让验证环境把这些信息稳定打印成 `.log`。
3. 再把同类信息通过 `ob_cosim_if` 拉出来。
4. 最后由 COSIM 相关模块读取并比较。

## 11. 后续行动项

1. 在后续 COSIM 文档中，将 `ob_if` 的 COSIM 观察语境统一改为 `ob_cosim_if`。
2. 将 `lane` 相关说法改为第 0 组通道 / 第 1 组通道。
3. 将 COSIM 自生成字段和环境抓取字段分开描述，尤其是 `cycle` 和 `sequence_id`。
4. 新增一份按 Commit / INT ARF / FP ARF / CSR / MEM 分类的 COSIM 抓取信号 plan。
5. 补充 CSR 和 MEM 相关观察信号，其中 MEM 信号源头来自 `cache_agent`，并需要进入 `be_agent`。
6. 当前阶段不单独追踪 trap/mcause，trap PC 先按普通 PC 路径处理。
7. 坚持完整 INT ARF / FP ARF 快照作为核心架构状态比较依据。
8. 将 `rd` / `rd_valid` 从核心必抓信号调整为可选辅助诊断信号。
9. 先完善 debug print 和 `.log` 输出，再推进 `ob_cosim_if` 和 COSIM 读取链路。

## 12. 一句话总结

先重新定义 ORBE COSIM 的观察面，把 `ob_cosim_if` 作为专用 COSIM 观察接口；按 Commit / INT ARF / FP ARF / CSR / MEM 分类列出需要抓取的信号；`cycle` 和 `sequence_id` 留在 COSIM 侧作为 counter 诊断字段；完整 INT ARF / FP ARF 快照是核心比较依据，因此 `rd` / `rd_valid` 不再作为必须抓取的主信号；当前阶段不单独追踪 trap/mcause，先把要打印和记录的信息确定清楚，再把这些信息接入 COSIM。
