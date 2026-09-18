# BETA Checker 整理

## 1. 目标和范围

这份整理面向 `beta_be_bt_env` 中的 checker 设计，重点回答三个问题：

1. checker 是怎么布置的，放在 testbench 的哪些位置。
2. checker 是怎么实现的，用到了哪些 SystemVerilog 技术。
3. 这些 checker 的原理是什么，为什么这样布置能验证 FE / BE / Cache / 提交级架构状态。

这里说的 checker 不是单独一个 `checker.sv`，而是一个分布式的 self-checking testbench：

- 共享 ISA Model 路径由 FE / BE / Cache 三个 agent 驱动和检查。
- 可选 cosim 路径由独立参考模型做提交级架构状态比对。
- top / reporter / config / test class 负责把这些 checker 串成完整闭环。

## 2. 总体布置

当前环境的 checker tap 点可以分成四层：

| 层级 | 位置 | 作用 |
| --- | --- | --- |
| DUT 白盒观测层 | `tb/top/be_tb_top.sv` | 把 ROB、flush、redirect、PRF/FPRF、trap 等内部信号导出给 TB |
| 共享模型 checker 层 | `tb/agents/be/be_agent.sv`、`tb/agents/cache/cache_agent.sv` | 用 RTL 事件驱动共享 ISA Model，并检查生命周期、顺序、flush、异常和 memory 语义 |
| 提交级 cosim checker 层 | `tb/interfaces/cosim_if.sv`、`tb/pkg/cosim_pkg.sv`、`tb/agents/cosim/cosim_agent.sv` | 用第二个独立 ISA Model 对提交后的 PC / GPR / FPR 做逐 ticket 比对 |
| 环境守护层 | `tb/env/be_config.sv`、`tb/env/be_reporter.sv`、`tests/elf/be_elf_test.sv` | 负责参数合法性、verbosity、timeout、模型启停和 PASS / FAIL 汇总 |

这个结构的核心思想是：

- 不改 RTL，只在 `be_tb_top` 做层次化观察和连线。
- 不把所有检查塞进一个 scoreboard，而是按职责拆到 FE / BE / Cache / Cosim。
- 共享模型和 cosim 模型分开维护，避免 checker 自己污染被检查对象。

## 3. 共享模型 checker：BE / Cache 路径

### 3.1 BE agent 做什么

`tb/agents/be/be_agent.sv` 是共享模型路径的主 observer。它的任务不是驱动 RTL，而是观察白盒信号后，按 RTL 实际发生的顺序推进共享 ISA Model。

它维护了几类 ROB 级锚点：

- `allocated_by_rob`
- `lsu_by_rob`
- `execute_started_by_rob`
- `pending_by_rob`
- `allocation_order_by_rob`

这些 associative array 的作用是把“一个 RTL ROB entry 是否已经被 checker 接管”记住。这样可以区分：

- 真实分配出来的 entry
- 已经执行过的 entry
- 被 flush 掉的 younger entry
- 因 pending / trap / retry 还没完成的 entry

### 3.2 BE checker 的关键机制

1. `decode_and_issue` 建立模型 anchor

   在 ROB allocation 时，BE agent 调 `isa_dpi_decode_and_issue()`，把 RTL 的 ROB 分配和共享 ISA Model 的 entry 绑定起来。若返回 invalid instruction id，说明 anchor 丢失，直接 fatal。

2. `execute_insn` 按事件触发，不按固定轮询触发

   非 LSU 的执行在 EXE writeback 到来时触发。BE agent 不会无条件每拍调用 execute，而是只在有白盒事件时调用。这样 checker 看的不是“有没有调用 task”，而是“是否真的发生了模型执行边界变化”。

3. `PENDING / SKIP / FAIL` 分开解释

   `ISA_API_PENDING` 表示模型还不能给出结果，需要后续 retry。
   `ISA_API_SKIP` 允许某些已带 trap 的 entry 跳过普通路径。
   `FAIL` 只有在没有模型 trap 的情况下才表示 observer 或 RTL 锚点错误。

4. `commit_auto` 是提交级一致性点

   每个有效 commit lane 触发一次 `isa_dpi_commit_auto()`。如果 commit 对应 entry 还带 trap，BE agent 会先采样 trap 状态，再让 model 自己消费 trap 并 squash younger entries。

5. flush 是共享模型的边界操作

   full flush 和 partial flush 都由 BE agent 统一调用共享 DPI API。这样 cache agent 不会和 BE agent 抢同一个 `g_sim` handle。

### 3.3 Cache agent 做什么

`tb/agents/cache/cache_agent.sv` 是 LSU / memory 路径的 checker。它不是单纯打印器，而是一个有本地状态机的 LSU scoreboard。

它维护的是事务级对象 `cache_pending`，一个 entry 里会保存：

- 地址 payload
- order
- executed / operation_done
- store data / wakeup 状态
- completion / exception 状态
- writeback 和 done 的输出状态

这意味着 cache checker 不是只看某个信号有没有跳，而是按 LSU 事务生命周期去恢复模型状态。

### 3.4 Cache checker 的关键机制

1. 地址、数据、wakeup 分离采样

   地址通道、store data 通道、ROB wakeup 通道不是一个事件。cache agent 分别采样，然后把它们合并到同一个 pending entry 里。

2. `execute_insn` 只在数据就绪时触发

   store / AMO / SC 必须先拿到 store data，再调用共享 ISA Model 的执行接口。否则会破坏模型的 buffered store 语义。

3. memory / commit / flush 分层处理

   cache agent 把 `execute`、`memory load/req`、`store commit`、`ROB done`、`exception` 分开处理，不把它们揉成一条泛化日志。

4. store 顺序由 FIFO 约束

   `older_store_pending()` 会阻止 younger store / AMO / SC 越过 older store 去做 `storeCommit`。

5. flush 只清本地队列

   cache agent 在 full flush / partial flush 时只清本地 pending、done_queue、exception_queue 和 wakeup latch；共享模型 flush 仍然由 BE agent 负责。

### 3.5 共享模型 checker 的本质

这条路径的本质是“事件驱动的 reference model 复原”：

- RTL 发出什么事件，checker 就让共享 ISA Model 走对应的 API。
- 事件顺序错了，或者 payload 错了，模型的状态、返回码、trap 状态就会和预期不一致。
- checker 不是在事后比对一张大表，而是在事务发生边界上直接阻断错误。

## 4. 提交级 Cosim checker

### 4.1 它放在哪里

Cosim checker 由四部分组成：

- `tb/interfaces/cosim_if.sv`
- `tb/pkg/isa_cosim_dpi_pkg.sv`
- `tb/pkg/cosim_pkg.sv`
- `tb/agents/cosim/cosim_agent.sv`

`be_tb_top.sv` 负责把 DUT 的提交级信息接到 `cosim_if` 上。

### 4.2 它怎么工作的

cosim 不是共享模型的别名，而是第二个独立模型句柄。C++ wrapper 里有两个全局 handle：

- `g_sim`：共享模型路径使用
- `g_cosim_sim`：cosim 路径使用

这点很关键。它保证 cosim checker 的 step 不会消费共享模型的 ROB、memory 或 exit 状态。

cosim 的工作流程是：

1. `be_elf_test` 在启动其他 agent 前先初始化独立 reference model。
2. `cosim_agent` 每个周期看 `commit_tick[lane]`。
3. 每个有效 commit lane 调 reference `step(1)` 一次。
4. step 前读取 `committed_pc()`，step 后读取 GPR/FPR，组出一个 `cosim_commit_ticket`。
5. 下一拍比较 RTL 重建状态和 reference 状态。

### 4.3 为什么要延后一拍比较

提交后的 backup RAT / PRF / FPRF 视图不是在 commit 脉冲当拍就完全稳定。当前实现把比较拆成两步：

- 当拍先收集 ticket，并重建提交后的架构状态。
- 下一拍再比较 pending tickets。

这样做的原因是把“提交脉冲”与“提交后稳定的架构视图”分离开，避免因时序还没稳定而误报 mismatch。

### 4.4 cosim 比什么

当前 cosim 比对的是：

- `pc`
- 32 个 GPR
- 32 个 FPR

比较用 `!==`，因此 X / Z 不会被吞掉。提交 payload 里如果 `pc`、`rd`、`prd`、`rd_is_fp`、`rd_is_v` 出现 unknown，checker 会直接 fatal。

### 4.5 同步异常怎么处理

同步异常不是普通 ROB commit。它通过 `trap_tick`、`trap_epc`、`trap_cause`、`trap_target_pc` 单独进入 cosim 流程。

处理方式是：

- 先检查 reference 当前 PC 是否等于 `trap_epc`。
- 再让 reference `step(1)` 一次，消费这条异常指令。
- 再检查 step 后 PC 是否等于 `trap_target_pc`。

这保证了普通提交和异常进入 handler 的顺序和 RTL 一致。

## 5. SystemVerilog 技术点

这一套 checker 主要用到的是过程式 SystemVerilog，而不是大面积 `property` 断言。

### 5.1 `interface` 和 `virtual interface`

所有 checker 都通过 `virtual interface` 访问 DUT 或 TB 暴露的信号：

- `fe_if`
- `ob_if`
- `lsu_if`
- `cosim_if`

这种写法把 checker class 和真实信号解耦，方便在 top 里集中接线，也方便复用和分层。

### 5.2 `class` + `task` + `function`

当前 checker 的主体都是 class：

- `be_agent`
- `cache_agent`
- `cosim_agent`
- `cosim_arch_state_adapter`
- `cosim_reference_backend`

其中：

- `task` 用来做时序相关的动作，例如 `run()`、`initialize()`、`check_cycle()`、`commitAuto()`。
- `function` 用来做纯计算，例如 ROB index 截断、地址类型判断、reg name 映射。

### 5.3 `virtual class`

`cosim_reference_backend` 是抽象参考后端接口。当前实现是 `isa_step_cosim_backend`，但框架已经留出后续替换 backend 的位置。

### 5.4 associative array 和 queue

这是 checker 状态建模的核心：

- associative array 适合表示“按 ROB index 查找的 in-flight entry”。
- queue 适合表示“按时间顺序延迟比较或输出”的 ticket / completion / exception。

这比固定深度 scoreboard 更灵活，也更贴近乱序 ROB / LSU 的实际生命周期。

### 5.5 DPI-C

SystemVerilog 通过 DPI 调 C++ ISA Model：

- 共享路径用 `isa_dpi_*`
- cosim 路径用 `isa_cosim_dpi_*`

这让 checker 能借助 golden model 完成执行、memory、commit、trap 和退出判定。

### 5.6 4-state 检查

checker 使用 `===`、`!==` 以及 reduction XOR 去发现 unknown。原因很直接：硬件仿真里 X 不能被软件式二值比较掩盖。

### 5.7 时序调度

共享模型路径和 cache 路径都把“采样”和“驱动”分到不同边沿：

- BE 在 negedge 做观察和 DPI mutate。
- cache 等 BE 的 phase barrier 后再进入同一拍的 LSU DPI。
- 输出在 posedge 驱动，保持稳定一个完整周期。

这是一种典型的 event-scheduling checker 写法，核心是避免同一拍内多个 agent 同时改同一个 model handle。

### 5.8 并发运行

`be_elf_test` 用 `fork...join` 同时启动 FE、BE、Cache 和可选 Cosim。这样 checker 才能和 DUT 并行推进，而不是串行跑完一个再跑下一个。

## 6. 关键原理总结

可以把这套 checker 的原理压缩成几条不变量：

1. 一个 RTL ROB allocation 对应一个模型 anchor。
2. 一个有效 commit lane 对应一个 cosim ticket 和一次 reference step。
3. 一个 LSU 事务必须先经过地址、数据、wakeup，再到 execute / memory / store commit。
4. full flush 和 partial flush 必须先清理 checker 状态，再继续后续事务。
5. 共享模型和 cosim 模型永远不能共享同一个 DPI handle。
6. 比较必须保留 4-state 语义，不能用二值比较吞掉 X。
7. 把错误放在最早能确认 invariant 被破坏的位置，而不是拖到 timeout。

## 7. 给 ORBE BT 环境报告的可复用结论

如果后面要写 ORBE BT 的 checker 布置报告，建议直接沿用这条主线：

- `be_tb_top` 做观测 tap。
- FE / BE / Cache 做共享模型 checker。
- `cosim_agent` 做独立提交级 checker。
- `be_reporter` 做统一失败出口。
- `be_config` 做参数边界和运行模式约束。

这样的组织方式有两个好处：

1. 报告结构清楚，能按“布置位置 / 实现方法 / 检查边界”展开。
2. 后续即使 RTL 层次变化，也只需要更新 top 里的白盒接线和 agent 的检查假设，不需要推翻整个 checker 模型。
