# ORBE BT Validation Environment Generation Flow

本文是草稿，说明我们如何基于 beta 现有验证环境，构造新的 ORBE BT 验证环境，并逐步联调到确认通过。重点是总结从 beta `driver / agent` 迁移到 `new interface` 的方法，以及 FE / BE / Cache 三个部分共享的规律。

## 1. 总体思路

新的验证环境不是把 beta 代码整体搬过来，而是先保留 beta 已经验证过的行为节奏，再按照新的 interface 重新切分职责。做法可以概括成三步：

1. 先从 beta 的 `driver / agent` 中找出稳定的外部行为。
2. 再对照新 interface，拆出 `raw payload`、`ready / valid`、`redirect`、`done / exception` 这些边界。
3. 最后把原来依赖 beta 内部结构的逻辑，逐步移动到新的 FE / BE / Cache Agent 中，让每个 Agent 只负责自己在接口上能看见、能控制的部分。

## 2. FE：从 beta driver / agent 到新的 FE Agent

FE 是最典型的一段迁移路径。beta 环境里，`driver / agent` 已经验证过很多行为：从 ELF 取指、维护 `pc` 和 `pending queue`、处理 compressed instruction、根据 ready 做保持、遇到 redirect 后重启。

在新环境里，我们没有直接照搬 beta 的接口，而是借鉴它的行为模式，重新落成新的 FE Agent：

- 仍然保留按顺序取指、按顺序发送、按顺序保持的主线。
- 仍然保留 compressed instruction、redirect、EOF / fetch fault 这些分支。
- 但是 FE 只发送 raw instruction payload，不再夹带 backend decode 结果或内部执行语义。
- lane 顺序、payload 稳定性、redirect 优先级，全部由 FE Agent 自己维护，而不是交给外部 wrapper 临时修补。

所以，beta 的价值不是接口名字本身，而是它证明了 FE 需要哪些稳定状态机；新 interface 的作用，是把这些状态机重新包裹成更清晰的边界。

## 3. BE：同样的迁移规律

BE 部分也遵循同样的逻辑。beta 里已经有了和执行、提交、flush、异常相关的 `driver / agent` 行为，但这些行为往往和内部结构耦得更紧。迁移到新的 ORBE BT 环境时，应该先把外部可见行为抽出来，再把内部细节留给 BE 侧或 wrapper 侧处理。

可以把 BE 的规律概括成三点：

- 接口只暴露 `issue / ready / done / exception / redirect / flush` 这类外部事件。
- RTL 负责维持时序、顺序和状态保持，不负责替 backend 做内部语义决策。
- 如果涉及 ROB、tag、commit 等内部资源，应该由 BE 侧统一收口，而不是让 driver 继续沿用 beta 里那种混合式写法。

也就是说，beta BE 的经验可以复用，但复用的是执行节奏和异常处理方式，不是旧接口的名字和旧对象的边界。

## 4. Cache：同样可以照这个模式迁移

Cache 部分也一样。beta 里已经沉淀了 `load / store`、`wakeup`、`bypass`、`store buffer`、`flush` 这类行为规律。新的 Cache Agent 不是推翻这些规律，而是用新的 interface 把它们重新组织起来。

这里最重要的是两件事：

- 先分清楚请求、返回、旁路、异常、flush 这些不同语义。
- 再明确哪些是 Agent 应该维护的节奏，哪些是 cache / LSU 内部自己完成的状态机。

只要这两点对齐，Cache 的迁移就和 FE / BE 一样：先复用 beta 的行为经验，再让新 interface 把职责边界切清楚。

## 5. 我们总结出来的规律

这次从 beta 迁移到新 ORBE BT 验证环境，最核心的规律可以总结成下面几条：

1. 先复用行为，再复用代码。beta 的真正价值是行为模型，不是旧接口形式。
2. 先定义边界，再实现 Agent。新的 interface 不是装饰层，而是职责分界线。
3. Agent 只管外部可见协议，不管内部实现细节。越靠近内部结构的东西，越应该留给对应模块自己处理。
4. 控制类事件优先级最高。`redirect`、`flush`、`exception` 这类事件必须先于普通数据流处理。
5. 保持 `raw payload` 和稳定时序。接口里尽量只传必要字段，不把内部 `decode / issue` 结果提前灌进去。
6. FE / BE / Cache 其实是同一套方法论的三个实例：抽取 beta 行为，重组接口边界，最后用独立验证把每一层确认通过。

## 6. 最终确认通过的方式

最终确认不是看某一个函数改对了，而是看整条验证链路是否闭合。通常可以按三步确认：

- `FE-only smoke`：确认 raw instruction、lane 顺序、保持、redirect、`EOF / fetch fault` 都符合新 interface。
- `FE + BE` 联调：确认 `issue`、`done`、`exception`、`redirect`、`flush` 这些控制事件在时序上没有冲突。
- `FE + BE + Cache` 回归：确认 `load / store`、`store buffer`、`bypass`、异常和收尾逻辑都能稳定跑通。

如果波形和日志里看到的状态转换，和我们定义的外部协议一致，就可以认为这条 generation flow 已经从 beta 迁移到新环境并完成确认通过。

这版先作为第一份草稿。后面如果需要，我可以继续把它改成更像项目复盘的正式版本，再补上具体文件名、验证 case 和日志证据。
