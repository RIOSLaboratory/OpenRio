# ORBE_BT_ENV debug and print

## 1. 本轮目标

本轮讨论 `tb` 里已经确定要看的 FE / BE / Cache 验证链路。RTL 还没接入环境时，不展开真实 RTL 接入缺口；print 设计先服务于当前能跑、能定位、能复现的环境段，并为后续 `ob_cosim_if` 观察信号保留同源字段。

## 2. 本轮优先级

| 优先级 | 文件 | 说明 |
| --- | --- | --- |
| P0 | `tb/modified_agents/fe/fe_driver.sv` | FE 侧主打印点，负责模型初始化、取指、redirect、结束和异常定位 |
| P0 | `tb/agents/be/be_agent.sv` | BE 侧主打印点，负责 decode / execute / commit / flush 的 DPI 调用边界和 ROB anchor |
| P0 | `tb/modified_agents/cache/cache_agent.sv` | Cache / LSU 侧主打印点，负责 issue / execute / memory / commit / flush |
| P0 | `tb/modified_agents/cache/lsu_if.sv` | Active interface，放协议断言和失败消息，不放数据洪泛打印 |
| P1 | `tb/agents/be/be_getter.sv` | BE metadata getter 打印点，默认 L3；只有 redirect / trap / overwrite / DPI fail 升级 |
| P1 | `tb/modified_agents/fe/orbe_fe_if.sv` | FE 接口约束，适合放 lane 顺序和 redirect 相关断言 |
| P1 | `tb/modified_agents/fe/fe_agent.sv` | 只保留极少量生命周期行，避免重复 driver 日志 |
| P2 | `tb/env/be_config.sv`、`tb/env/be_reporter.sv` | 统一格式、verbosity 和 summary，不承载业务细节 |

## 3. 通用打印规则

1. 普通事件统一走 `cfg.print_fe()` / `cfg.print_be()` / `cfg.print_cache()` / `cfg.print_tb()`，不要在 class 里到处散落 `$display`。
2. L1 只打生命周期、首个错误、模型退出和 PASS / FAIL。
3. L2 打状态切换、redirect、exception、flush、commit 这类一眼能定位边界的事件。
4. L3 打逐周期 handshake、队列变化、retry、stall、wakeup、pending 这类需要回放时才看的细节。
5. 每条消息都带上能对齐的字段：`cycle` / `time`、`lane` 或 `tag`、`pc` 或 `vaddr`、`subop`、`req_property`、`rc`、`queue size`。
6. `warning` / `error` / `fatal` / `assertion` 不受 verbosity 过滤，必须带稳定前缀，如 `[ASSERT]`、`[ERROR]`、`[FATAL]`。
7. 只在状态变化或第一次发生时打印，别每拍刷同一条。
8. Print 数据应覆盖后续 COSIM 需要的数据，但 COSIM 不应解析文本 `.log` 作为输入。推荐让 print 和 `ob_cosim_if` 同源于同一个结构化事件记录：print 输出全集，`ob_cosim_if` 只承载 COSIM 子集。

### 3.1 如何筛选有价值的打印点

打印点不是按“所有被调用的 task 都打一条入口日志”来决定，而是按事件对 debug 的价值筛选。一个 task 只有在下面至少满足一项时，才值得增加 print：

1. **产生了可观察的验证事件**：例如接口上真正发生了 `valid && ready` 握手、收到 store wakeup、产生 done / exception、发生 redirect 或 flush。只被调用但没有产生新事件的 task 不打印。
2. **产生了事务状态变化**：例如 request 从输入变成 pending entry，事务从 execute 进入 memory service，store 从等待授权变成可 commit，结果从内部状态进入 terminal queue。打印应放在状态真正改变的位置，而不是泛化地放在 task 开头。
3. **解释了等待、retry 或阻塞原因**：例如 `ISA_API_PENDING`、`WAIT_AUTH`、`older_store_pending`、结果尚未到 `ready_cycle`。这类信息只在“进入等待”和“等待解除”时打印，持续等待的周期不重复刷。
4. **记录了错误第一现场**：在最早可以确认 contract / invariant 被违反的位置，记录完整上下文。必须区分预期的 architectural exception 和验证环境错误：前者记录 `cause/tval` 等异常信息；后者用 `[ASSERT]`、`[ERROR]` 或 `[FATAL]` 立即报告，不能等到 timeout 或最终 FAIL 才回推。
5. **位于 interface contract 的检查边界**：接口协议正常时不打印连续数据；只有 property 失败、payload 不一致、非法握手、flush 期间错误输出等情况，才由 assertion action block 输出带现场字段的消息。

因此，`task` 是定位事件处理位置的手段，不是打印触发条件。筛选结果应遵循：

```text
可观察事件 / 状态变化 / 等待原因 / 错误第一现场 / 协议违反
                         -> 打印或断言消息
仅仅被调用、没有新信息       -> 不打印
```

在当前 Cache 链路中的对应关系如下：

| task | 打印触发条件 | 不应做的事 |
| --- | --- | --- |
| `sample_store_wakeup()` | 收到授权、命中待发 store、暂存授权、非法重复授权 | 每次被 `run()` 调用都打印 |
| `accept_issue()` | 真正 issue 握手，或发现 payload / capacity 错误 | 只打印 task 被调用 |
| `execute_pending()` | 调用 DPI、返回 `PENDING`、完成、产生可解释异常或不可解释失败 | 把所有非 `PASS` 都直接当成 TB error |
| `service_memory_ops()` | `MEM_LOAD` / `MEM_REQ` / `WAIT_AUTH` / store commit 发生状态变化 | 每个未满足条件的周期都重复打印 |
| `service_flush()` / `drive_outputs()` | 检测到 flush，或真正驱动 done / exception / bypass | 在没有 flush 或 terminal output 时打印空状态 |

## 4. FE 相关文件

### 4.1 `tb/modified_agents/fe/fe_driver.sv`

这是 FE 侧最重要的打印点。建议按下面几类插：

| 位置 | 建议等级 | 建议打印内容 |
| --- | --- | --- |
| `initialize_model()` 成功后 | L1 | `ISA_CFG`、`ISA_ELF`、`entry_pc`、`MODEL_ROB_SIZE`、是否启用 run / commit log |
| `report_fetch_fault()` | L2 | `pc`、`access_pc`、`trap_type`、`cause`、`tval` |
| `fetch_instruction()` 遇到 zero-filled stream | L2 | `pc`、`end_of_stream=1` |
| `fetch_pending_entry()` 成功入队 | L3 | `lane`、`pc`、`inst_bits`、`is_compressed`、`instr_bytes`、`pred_target_pc`、`fetch_excp_vld` |
| `remove_accepted_entries()` | L3 | `sampled_fire`、`pending_before`、`pending_after`、lane0 / lane1 是否按 prefix 顺序被接受 |
| `refill_pending()` | L3 | `pending_count`、`fetch_eof`、`fetch_stop_after_fault`、`next_pc` |
| `apply_redirect()` | L2 | `redirect_pc`、旧 pending 数、重建后的首个 `pc` |
| `run()` / `finish_model()` | L1 | reset 释放、模型退出、`DPI_EXIT_RESULT`、PASS / FAIL |

建议字段固定成：
`cycle / time` + `pc` + `lane` + `valid / ready` + `inst_bits` + `pred_target_pc` + `fetch_excp_vld` + `exception_cause / tval`。

### 4.2 `tb/modified_agents/fe/fe_agent.sv`

这个文件应尽量保持薄，不要重复 `fe_driver` 的日志。只建议保留一条很轻的生命周期行，例如：
`[FE][AGENT] run started` / `[FE][AGENT] shutdown`。
如果 driver 已经能完整覆盖定位，这个文件可以完全不加新 print。

### 4.3 `tb/modified_agents/fe/orbe_fe_if.sv`

这个接口更适合放约束消息，不适合放连续打印。建议只在协议错误时给出统一的 assert 消息，前缀例如：
`[ASSERT][FE] ...`

优先覆盖的点：

- lane0 / lane1 的 prefix 顺序约束
- lane1 不能在 lane0 没有 fire 时单独被接收
- redirect 出现时，旧取指组必须在后续周期前被丢弃
- redirect payload 里必须带完整 `redirect_pc`

建议失败消息至少带：
`cycle`、`lane`、`valid`、`ready`、`pc`、`inst_bits`、`redirect_pc`。

## 5. BE 相关文件

### 5.1 `tb/agents/be/be_agent.sv`

这是 BE 侧主打印点。目标不是把每个 DPI 每拍刷出来，而是围绕 decode / execute / commit / flush 四条主线，把共享 ISA model 的调用边界和 ROB anchor 关系打清楚。

#### 5.1.1 主线一：model ready / lifecycle

对应源码入口是 `wait_for_model()` 和 `run()`。

| 位置 / DPI | 建议等级 | 建议打印内容 |
| --- | --- | --- |
| `isa_dpi_is_config_ready()` 首次 ready | L1 | `cycle`、`model_ready=1` |
| `run()` 启动 | L1 | `cycle`、BE agent started |
| `isa_dpi_is_to_exit()` 首次为 true | L1 | `cycle`、`retire_count`、model exit |
| `isa_dpi_tick_finish(1'b1)` | L3 | 只在深调试打开；默认不逐拍打印 |

这条线要固定的字段是：`cycle`、`retire_count`、`model_ready`、`stop_requested`。

#### 5.1.2 主线二：decode / issue anchor

对应源码入口是 `observe_allocations()`。

| 位置 / DPI | 建议等级 | 建议打印内容 |
| --- | --- | --- |
| `isa_dpi_decode_and_issue()` 成功建立 anchor | L2 | `cycle`、`group`、`rob_idx`、`tag`、`pc`、`inst_bits`、`is_compressed`、`insn_id`、`is_lsu` |
| `isa_dpi_decode_and_issue()` 返回 invalid id | L1 | `[FATAL][BE][DECODE]`，带 `group`、`rob_idx`、`pc`、`inst_bits`、`is_compressed` |
| `isa_dpi_trigger_trap()` 用于 fetch exception 注入 | L2 | `cycle`、`group`、`rob_idx`、`pc`、`exception_cause`、`exception_tval`、`rc` |

这条线要固定的字段是：`cycle`、`group`、`rob_idx`、`tag`、`pc`、`inst_bits`、`is_compressed`、`insn_id`、`is_lsu`、`exception_cause`、`exception_tval`、`rc`。

打印策略：正常 decode anchor 可以从 L2 少量打开；如果日志过多，可以只保留 commit 对应的 decode 摘要，完整 decode payload 放 L3。

#### 5.1.3 主线三：execute / retry

对应源码入口是 `observe_execution_writebacks()`、`retry_pending_execution()` 和 `finish_execute()`。

| 位置 / DPI | 建议等级 | 建议打印内容 |
| --- | --- | --- |
| `isa_dpi_execute_insn()` 普通执行返回 `PASS/SKIP` | L3 | `cycle`、`source`、`rob_idx`、`tag`、`operation`、`rc` |
| `isa_dpi_execute_insn()` 返回 `PENDING` | L2 | `cycle`、`rob_idx`、`tag`、`operation`、`rc=PENDING` |
| `isa_dpi_execute_insn()` retry 后完成 | L3 | `cycle`、`rob_idx`、`tag`、`operation=retry`、`rc` |
| `isa_dpi_has_trap()` 用于 execute 失败归因 | L2 | `cycle`、`rob_idx`、`tag`、`operation`、`rc`、`trap_valid` |
| stale execute event 被忽略 | L3 | `cycle`、`rob_idx`、`reason=stale` |
| duplicate execute event | L1 | `[FATAL][BE][EXECUTE]`，带 `cycle`、`rob_idx`、`tag` |

这条线要固定的字段是：`cycle`、`source`、`rob_idx`、`tag`、`operation`、`rc`、`trap_valid`、`pending_count`。

打印策略：普通 PASS 不建议默认打开；`PENDING`、trap 归因和非法重复执行更值得保留。

#### 5.1.4 主线四：commit / retire

对应源码入口是 `observe_commits()`。

| 位置 / DPI | 建议等级 | 建议打印内容 |
| --- | --- | --- |
| `isa_dpi_has_trap()` commit 前检查 | L3 | `cycle`、`group`、`rob_idx`、`tag`、`pc`、`precommit_trap` |
| `isa_dpi_commit_auto()` 成功 | L2 | `cycle`、`group`、`rob_idx`、`tag`、`pc`、`rc`、`precommit_trap`、`final_trap`、`retire_count` |
| commit 未找到 allocation anchor | L1 | `[FATAL][BE][COMMIT]`，带 `cycle`、`group`、`rob_idx`、`pc` |
| `commit_auto` 返回非 PASS | L1 | `[FATAL][BE][COMMIT]`，带 `cycle`、`group`、`rob_idx`、`tag`、`pc`、`rc` |
| commit 后触发 anchor 清理 | L3 | `cycle`、`rob_idx`、`tag`、`final_trap`、剩余 anchor 数 |

这条线要固定的字段是：`cycle`、`group`、`rob_idx`、`tag`、`pc`、`rc`、`precommit_trap`、`final_trap`、`retire_count`。

这条线和 COSIM 关联最紧：`group`、`pc`、`rob_idx` 属于后续 `ob_cosim_if` 的 Commit 子集；`cycle` / `retire_count` 只服务日志定位，不应作为 `ob_cosim_if` 抓取字段。

#### 5.1.5 主线五：flush / redirect

对应源码入口是 `observe_flushes()`。

| 位置 / DPI | 建议等级 | 建议打印内容 |
| --- | --- | --- |
| `isa_dpi_flush_all()` 被调用 | L2 | `cycle`、`flush_all`、`trap_commit_consumed`、anchor 数、`rc` |
| `isa_dpi_flush()` 被调用 | L2 | `cycle`、`pflush_rob_idx`、`first_younger`、anchor 数、`rc` |
| flush 后本地 anchor 清理 | L3 | `cycle`、`reason=flush`、清理前后 anchor 数 |
| flush DPI 返回非 PASS | L1 | `[FATAL][BE][FLUSH]`，带 `cycle`、flush 类型、`pflush_rob_idx`、`first_younger`、`rc` |

这条线要固定的字段是：`cycle`、`flush_all`、`pflush`、`pflush_rob_idx`、`first_younger`、`trap_commit_consumed`、`anchor_count`、`rc`。

### 5.2 `tb/agents/be/be_getter.sv`

`be_getter` 负责从 ISA model 取 decode / LSU / execute / commit metadata，并写入 `getter_if`。默认只在 L3 打 metadata；如果出现 overwrite、DPI fail、redirect 或 trap，再升级到 L1/L2。

| 位置 / DPI | 建议等级 | 建议打印内容 |
| --- | --- | --- |
| `isa_dpi_get_decode_metadata()` | L3 | `group`、`tag`、`model_rob_idx`、`is_lsu`、`trap_valid`、`trap_cause`、`trap_tval`、`rc` |
| decode response overwrite | L1 | `[FATAL][GETTER][DECODE]`，带 `group`、`tag`、`model_rob_idx` |
| `isa_dpi_get_lsu_issue_metadata()` | L3 | `tag`、`req_property`、`exe_subop`、`mem_funct3`、`rd_is_fp`、`rs1_data`、`rs2_data`、`imm_valid`、`imm_data`、`is_store`、`rc` |
| LSU metadata response overwrite / DPI fail | L1 | `[FATAL][GETTER][LSU_META]`，带 `tag`、`rc` |
| `isa_dpi_get_execute_metadata()` | L3 | `tag`、`model_rob_idx`、`trap_valid`、`trap_cause`、`trap_tval`、`rc` |
| `isa_dpi_is_insn_redirect()` | L2 | 仅 redirect 为 1 时打印：`tag`、`model_rob_idx`、`redirect=1` |
| `isa_dpi_get_next_pc_of_insn()` | L2 | 与 redirect 同行打印：`next_pc` |
| execute response overwrite / DPI fail | L1 | `[FATAL][GETTER][EXECUTE]`，带 `tag`、`model_rob_idx`、`rc` |
| `isa_dpi_get_commit_auto_trap_info()` | L3 | `tag`、`model_rob_idx`、`precommit_trap`、`trap_record_valid`、`trap_cause`、`trap_tval`、`final_trap`、`rc` |
| `isa_dpi_get_spec_pc()` | L2 | 仅 `final_trap=1` 时打印：`tag`、`model_rob_idx`、`redirect_pc` |
| commit response overwrite / DPI fail | L1 | `[FATAL][GETTER][COMMIT]`，带 `tag`、`model_rob_idx`、`rc` |

### 5.3 BE 打印与 COSIM 数据的联动

BE print 和 COSIM 观察应同源，但 COSIM 不应解析文本 `.log`。推荐结构如下：

```text
BE/cache 观察到事件
        |
        v
统一事件记录 event_record
        |                      |
        v                      v
print/log 输出全集          ob_cosim_if 输出 COSIM 子集
```

具体规则：

1. Print 数据必须覆盖后续 COSIM 所需字段，COSIM 数据是 print 数据的子集。
2. `ob_cosim_if` 只承载架构观察面：Commit、INT ARF、FP ARF、CSR、MEM store commit 等核心字段。
3. `cycle`、`sequence_id`、`retire_count` 这类 counter 可以打印，但不应作为从 `ob_cosim_if` 抓取的信号。
4. Cache / BE 内部队列、等待、retry、metadata payload 可以打印到 `.log`，但不应全部进入 `ob_cosim_if`。
5. 当 COSIM mismatch 发生时，错误报告应带 `sequence_id`、`cycle`、`group`、`rob_idx`、`pc`，使其能回查 BE / Cache print 中的同源事件。

第一轮建议先打开 BE 的 L1 和少量 L2：model ready / exit、decode anchor、commit_auto、flush、redirect、trap。普通 execute PASS、LSU metadata 全 payload 和逐拍 tick 放在 L3，后续按定位需要再打开。

## 6. Cache 相关文件

### 6.1 `tb/modified_agents/cache/cache_agent.sv`

这是 Cache / LSU 侧的主打印点。上一版只列了事件名，这一版把四条主线补成可执行的打印链路：`issue`、`execute`、`memory / commit`、`flush`。

#### 6.1.1 主线一：issue / wakeup

对应源码入口是 `sample_store_wakeup()` 和 `accept_issue()`。

这条线的目标不是“多打印”，而是把一次事务从进入、授权、接受到入队的边界打清楚。

建议打印点如下：

| 位置 | 建议等级 | 建议打印内容 |
| --- | --- | --- |
| `sample_store_wakeup()` 接收到授权并真正命中某个待发 store | L3 | `cycle`、`tag`、`authorized=1`、是否来自 held authorization |
| `sample_store_wakeup()` 没有命中现有 store，只能暂存授权 | L3 | `cycle`、`held=1`、`early_store_wakeup_pending=1` |
| `accept_issue()` 真正接收一个 request | L3 | `cycle`、`tag`、`order`、`subop`、`req_property`、`mem_funct3`、`vaddr`、`len`、`read/store/fp/auth` |
| `accept_issue()` 触发结构性错误 | L1 | 只走 `fail()`，带 `tag`、`subop`、`req_property`、`vaddr`、`queue occupancy` |

这条线要固定的字段是：

`cycle`、`tag`、`order`、`subop`、`req_property`、`mem_funct3`、`vaddr`、`len`、`read`、`store`、`fp`、`auth`、`store_buffer_count`、`read_pipe_count`。

要明确的成功/失败分支是：

1. 成功时，只打印一次 `[CACHE][ISSUE]`，不要在后续循环重复刷同一个 `tag`。
2. `req_property` 和 `exe_subop` 不一致时直接 `fail()`。
3. `mem_funct3` 和 `exe_subop` 不一致时直接 `fail()`。
4. `is_store` 与 `req_property.is_store` 不一致时直接 `fail()`。
5. 非 plain store 却带 `st_br_resolve` 时直接 `fail()`。
6. store buffer 已满但仍接受 store issue 时直接 `fail()`，这不是 architectural fault，而是 testbench 接受线错误。
7. read-side issue 不应该被拒绝，若发生应直接 `fail()`。

#### 6.1.2 主线二：execute / fault

对应源码入口是 `execute_pending()`，异常归因通过 `translate_exception()` 和 `enqueue_exception()` 落地。

这条线的核心是：每个已入队的事务都要有明确的 execute 结果，且第一次失败必须保住，不要被后面的 flush 吃掉。

建议打印点如下：

| 位置 | 建议等级 | 建议打印内容 |
| --- | --- | --- |
| `execute_pending()` 调用模型执行 | L3 | `tag`、`rc`、`subop`、`vaddr`、`order` |
| `execute_pending()` 进入 `ISA_API_PENDING` | L3 | `tag`、`rc=PENDING`、保持 pending |
| `execute_pending()` 失败且可归因 | L1 | `[CACHE][EXEC_FAIL]`，带 `tag`、`rc`、`subop`、`vaddr` |
| `translate_exception()` 成功翻译异常 | L2 | `trap_type`、`trap_tval`、`memop`、`vaddr`、`read/store` |
| `enqueue_exception()` 对外记录异常 | L2 | `tag`、`cause`、`tval`、是否需要 trigger_trap |

这条线要固定的字段是：

`tag`、`rc`、`subop`、`vaddr`、`order`、`trap_type`、`trap_tval`、`cause`、`tval`、`memop`。

要明确的成功/失败分支是：

1. `rc == ISA_API_PENDING` 只表示模型暂未给出结果，不应该升级成错误。
2. `rc == ISA_API_PASS` 后，`executed` 变为 1，后续不应重复走同一条执行路径。
3. `rc != ISA_API_PASS` 时，先打印 `[CACHE][EXEC_FAIL]`，再进入异常翻译，不要等 flush 后补原因。
4. 异常翻译失败或返回的 cause 不合法时，要回退为 store fault / load fault 的保底路径，并把这件事打印出来。

#### 6.1.3 主线三：memory / store commit

对应源码入口是 `service_memory_ops()` 和 `commit_store()`，其中 `enqueue_completion()` 负责把结果放进终端队列。

这条线要把“读完成”“写提交”“等待授权”“结果排队”分开看，不要把它们揉成一条泛化日志。

建议打印点如下：

| 位置 | 建议等级 | 建议打印内容 |
| --- | --- | --- |
| `service_memory_ops()` 读侧完成 `proc_mem_load` / `proc_mem_req` | L3 | `tag`、`rc`、`rd`、`mem_load_done` |
| `service_memory_ops()` 读侧被暂缓 | L3 | `tag`、`older_store_pending`、`read_pipe_count` |
| `service_memory_ops()` store 侧等待授权 | L3 | `tag`、`WAIT_AUTH`、`store_authorized=0` |
| `commit_store()` 真正提交 store | L3 | `cycle`、`tag`、`vaddr`、`data`、`rc`、`older_store_pending`、`executed` |
| `commit_store()` 被拒绝但不是 architectural fault | L1 | `tag`、`rc`、`older_store_pending`、`executed`、`faulted_store_parked` |
| `enqueue_completion()` 进入完成队列 | L3 | `tag`、`read/store`、`data`、`ready_cycle`、`done_queue size` |
| `service_memory_ops()` misc side | L3 | `tag`、`MEM_REQ`、`rc` |

这条线要固定的字段是：

`tag`、`cycle`、`vaddr`、`data`、`rc`、`older_store_pending`、`executed`、`store_authorized`、`done_ready_cycle`、`done_queue`、`exception_queue`、`store_buffer_count`。

要明确的成功/失败分支是：

1. 读侧完成后，如果有结果，应该把 `rd` / `data` 打出来，便于和后续 `DONE_OUT` 对齐。
2. store 侧如果没拿到授权，应该先打印一次 `WAIT_AUTH`，而不是每拍重复刷。
3. `commit_store()` 只有在 oldest store 且已执行时才应进入真正提交路径。
4. 如果 `store_commit` 被拒绝，但前置条件已经证明这不是队列顺序问题，就应该直接 `fail()`，不要硬转成 architectural fault。
5. `enqueue_completion()` 要打印 `ready_cycle`，否则很难区分“已经完成但还没到输出拍”和“根本没进入完成队列”。

#### 6.1.4 主线四：flush / terminal output

对应源码入口是 `service_flush()` 和 `drive_outputs()`，它们控制对外终端事件的唯一出口。

这条线的重点不是多打状态，而是把“flush 到底清了什么”“本拍为什么只出一个 terminal event”“done / exception / bypass 的先后关系”打清楚。

建议打印点如下：

| 位置 | 建议等级 | 建议打印内容 |
| --- | --- | --- |
| `service_flush()` 检测到 `global_flush_late` | L2 | `cycle`、`live`、`done_q`、`excp_q`、`store_fifo` |
| `drive_outputs()` 输出 exception | L2 | `cycle`、`tag`、`cause`、`tval` |
| `drive_outputs()` 输出 done | L2 | `cycle`、`tag`、`read`、`data` |
| `drive_outputs()` 输出 bypass | L2 | `tag`、`data`、与 done payload 一致 |
| `run()` 检查 terminal event 在非 ready 拍出现 | L1 | `tag`、`cycle`、`entry_ready`、`flush_event` |

这条线要固定的字段是：

`cycle`、`live`、`done_q`、`excp_q`、`store_fifo`、`tag`、`cause`、`tval`、`data`、`read`、`ready_cycle`、`entry_ready`、`flush_event`。

要明确的成功/失败分支是：

1. flush 拍不应该对外驱动 terminal output。
2. exception 必须先于 ordinary done 输出。
3. read-side done 的 bypass payload 必须和 done payload 一致。
4. 如果 terminal event 出现在 `be_lsu_entry_ready` 低且没有 flush 的拍上，应直接 `fail()`。

建议 `cache_agent` 里最有价值的字段保持一致：
`cycle`、`tag`、`order`、`vaddr`、`subop`、`req_property`、`rc`、`cause`、`tval`、`data`、`done_q`、`excp_q`、`store_fifo`、`store_buffer_count`。

几个原则要写死：

1. `ISSUE` 只打印一次，不要在同一个 tag 的后续循环重复刷。
2. `WAIT_AUTH` / `WAKEUP` 只在授权状态变化时打印。
3. `DONE_OUT` 和 `EXCP_OUT` 只打印真正对外驱动的那一拍。
4. `EXEC_FAIL` 要保留第一失败现场，不要等到后面的 flush 再回推原因。
5. `FLUSH` 要把局部队列状态打印出来，否则很难区分是正常清空还是异常丢失。

### 6.2 `tb/modified_agents/cache/lsu_if.sv`

这是当前 active 的 cache-side interface，接口名是 `or_be_lsu_if`。
这里不建议做普通 `$display` 洪泛，重点是把协议断言的失败消息统一掉。

建议统一成：
`[ASSERT][CACHE_IF] ...`
或
`[ASSERT][LSU] ...`

优先要补齐的消息点：

- `req_property` 与 `exe_subop` 必须一致
- `is_store` 必须和 `req_property.is_store` 一致
- 非 plain store 不能带 `st_br_resolve`
- `done` 和 `exception` 必须互斥
- `bypass` 必须伴随 `done`，且 payload 一致
- read-side issue 不能被拒绝
- full flush 期间不能出现任何 terminal output

每条失败消息建议带：
`cycle`、`tag`、`req_property`、`subop`、`cause`、`tval`、`done_valid`、`exception_valid`、`bypass_valid`、`global_flush_late`。

如果要在接口里加 action block，优先顺序建议是：

1. `error` 用于协议不一致但还能继续观察的情况。
2. `fatal` 用于不可能继续跑的结构性错误，例如终端通道互斥被破坏、flush 期间仍然对外驱动结果。

### 6.3 `tb/interfaces/lsu_if.sv`

这个 legacy 文件本轮不作为主打印面。如果后面确实还有人沿用它，再把同一套 assert message 风格同步过去即可。这一次不要在它上面再加一批独立格式。

## 7. 建议的首批落点顺序

1. 先把 `fe_driver.sv` 的 L1 / L2 / L3 层次定下来。
2. 再把 `be_agent.sv` 的 decode / execute / commit / flush 四条主线补齐，先打开 L1 和少量 L2。
3. 然后把 `cache_agent.sv` 的 issue / exec / commit / flush 四条主线补齐。
4. 再统一 `tb/modified_agents/cache/lsu_if.sv` 的 assert message。
5. 最后再补 `fe/orbe_fe_if.sv` 的协议断言和少量 `fe_agent.sv` 生命周期行。

这样做的好处是，当前即使没有 RTL 接入，也能把 FE 取指、BE commit/flush 和 Cache 事务的日志链路先固定下来，后面补 `ob_cosim_if` 时只需要沿用同一套事件字段。
