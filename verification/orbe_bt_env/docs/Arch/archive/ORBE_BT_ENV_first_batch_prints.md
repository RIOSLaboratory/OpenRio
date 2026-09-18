# ORBE BT ENV 第一批打印锚点

## 1. 文档目的

本文记录当前 ORBE 验证环境中已经添加的第一批打印点、源码位置、函数和主要输出内容。

本文作为后续调整打印点的基线和锚点。后续新增、删除、移动或调整打印内容时，应同步更新本文，避免每次重新通读整个 `tb` 目录。

当前实际修改路径如下：

- FE 和 Cache 主要使用 `tb/modified_agents`。
- BE 和 BE getter 主要使用 `tb/agents/be`。
- 统一打印基础设施位于 `tb/env`。

## 2. 统一打印基础设施

### 2.1 `tb/env/be_config.sv:28`

提供统一打印入口：

- `print_fe()`
- `print_be()`
- `print_cache()`
- `print_tb()`

解析的 plusargs 包括：

- `+VERBOSITY`
- `+TEST`
- `+ERROR_LIMIT`
- `+COSIM_ENABLE`
- `+COSIM_BACKEND`
- 仿真超时参数
- Cache delay 参数

`print()` 输出以下配置内容：

- 当前 test
- issue width
- timeout
- smoke wait cycles
- Cache load/store delay
- reporter error limit
- COSIM enable/backend
- verbosity

### 2.2 `tb/env/be_reporter.sv:61`

普通打印统一格式为：

```text
[time] [BE_TB] [L1/L2/L3] message
```

主要行为：

- L1、L2、L3 受 `VERBOSITY` 控制。
- warning、error、fatal 不受普通 verbosity 过滤。
- 统计 L1、L2、L3、warning、error、fatal 数量。
- 仿真结束输出：

```text
[REPORTER_SUMMARY] l1=... l2=... l3=... warning=... error=... fatal=...
```

## 3. FE 打印

文件：`tb/modified_agents/fe/fe_driver.sv:42`

### 3.1 `report_fetch_fault()`

- 等级：L2。
- 打印 instruction-fetch exception。
- 主要内容：
  - 当前 PC
  - 失败访问 PC
  - cause
  - trap type/tval
- 主要格式：

```text
[FE] instruction-fetch exception
```

### 3.2 `initialize_model()`

- 等级：L1。
- 打印：
  - ELF 路径
  - ISA model entry PC
  - 持续取指直到 ISA model exit 的状态

### 3.3 `fetch_instruction()`

- 等级：L3。
- 检测到 zero-filled instruction stream 时，打印 EOF PC。
- 主要格式：

```text
[FE] zero-filled instruction stream ended
```

### 3.4 `apply_redirect()`

- 等级：L3。
- 打印 redirect 后重新开始取指的目标 PC。

### 3.5 `run()`

- 等级：L3。
- 打印捕获到的 redirect request 和 redirect PC。

### 3.6 `finish_model()`

- 等级：L1。
- 打印 ISA model exit 以及 PASS/FAIL。
- 额外无 verbosity 过滤地输出：

```text
[DPI_EXIT_RESULT] PASS
```

或：

```text
[DPI_EXIT_RESULT] FAIL
```

### 3.7 `fe_agent.sv`

没有再增加一套重复的详细打印，避免与 `fe_driver.sv` 重复。

## 4. BE 主流程打印

文件：`tb/agents/be/be_agent.sv:65`

### 4.1 `wait_for_model()`

- 等级：L1。
- 标签：`[BE][MODEL_READY]`。
- 内容：cycle 和 model ready 状态。

### 4.2 `observe_allocations()`

#### `[BE][FETCH_TRAP]`

- 等级：L2。
- 内容：cycle、group、ROB、PC、cause、tval、DPI rc。

#### `[BE][DECODE]`

- 等级：L2。
- 内容：
  - cycle
  - group
  - allocation order
  - tag
  - ROB
  - instruction ID
  - PC
  - instruction bits
  - compressed
  - LSU
  - fetch exception

### 4.3 `finish_execute()`

#### `[BE][EXECUTE_PENDING]`

- 等级：L2。
- 内容：cycle、ROB、tag、operation、rc。

#### `[BE][EXECUTE_TRAP]`

- 等级：L2。
- 内容：cycle、ROB、tag、operation、rc、trap valid。

### 4.4 `observe_execution_writebacks()`

- stale execute event 以 L3 打印对应 ROB index。
- duplicate execute、无效 ROB 等结构性问题通过 reporter fatal 输出。

### 4.5 `observe_commits()`

#### `[BE][COMMIT]`

- 等级：L2。
- 内容：cycle、group、retire count、ROB、tag、PC、rc、precommit trap、final trap。
- 默认每次 commit 输出一次。
- 可通过 `RETIRE_PRINT_INTERVAL` 调整输出频率。

### 4.6 `observe_flushes()`

#### `[BE][FLUSH_ALL]`

- 等级：L2。
- 内容：cycle、flush mask、清理前 anchor 数量、trap commit 是否已消费、是否调用 DPI、rc。

#### `[BE][PFLUSH]`

- 等级：L2。
- 内容：cycle、pflush ROB、first younger、清理前 anchor 数量、rc。

### 4.7 `observe_redirects()`

#### `[BE][REDIRECT]`

- 等级：L2。
- 内容：cycle、redirect PC、当前 anchor 数量。

### 4.8 `run()`

#### `[BE][START]`

- 等级：L1。
- 内容：BE agent 开始工作的 cycle。

#### `[BE][EXIT]`

- 等级：L1。
- 内容：cycle 和最终 retire count。

## 5. BE getter 打印

文件：`tb/agents/be/be_getter.sv:80`

### 5.1 `after_decode()`

#### `[GETTER][DECODE_TRAP]`

- 等级：L2。
- 内容：group、tag、ROB、cause、tval、rc。

#### `[GETTER][DECODE]`

- 等级：L3。
- 内容：group、tag、ROB、是否 LSU、是否 trap、rc。

### 5.2 `service_lsu_metadata()`

#### `[GETTER][LSU_META]`

- 等级：L3。
- 内容：
  - tag
  - request property
  - execute subop
  - funct3
  - FP 标记
  - `rs1/rs2`
  - immediate
  - store 标记
  - rc

### 5.3 `after_execute()`

#### `[GETTER][REDIRECT]`

- 等级：L2。
- 内容：tag、ROB、next PC。

#### `[GETTER][EXECUTE_TRAP]`

- 等级：L2。
- 内容：tag、ROB、cause、tval、rc。

#### `[GETTER][EXECUTE]`

- 等级：L3。
- 内容：tag、ROB、redirect、next PC、trap、rc。

### 5.4 `after_commit()`

#### `[GETTER][COMMIT_TRAP]`

- 等级：L2。
- 内容：tag、ROB、precommit trap、trap record valid、late trap、cause、tval、redirect PC、rc。

#### `[GETTER][COMMIT]`

- 等级：L3。
- 内容：tag、ROB、precommit trap、trap record valid、final trap、rc。

## 6. Cache/LSU 打印

文件：`tb/modified_agents/cache/cache_agent.sv:114`

### 6.1 构造函数

- 等级：L1。
- 打印 Cache agent ready。
- 同时标明 shared ISA model 的 flush owner 为 BE。

### 6.2 `enqueue_exception()`

- 等级：L1。
- 打印 exception tag、cause、tval。

### 6.3 `enqueue_completion()`

#### `[CACHE][QUEUE]`

- 等级：L3。
- 内容：tag、read/store、返回 data、ready cycle。

### 6.4 `sample_store_wakeup()`

#### `[CACHE][WAKEUP]`

- 等级：L3。
- 打印 store authorization 命中哪个 tag。
- 如果 authorization 提前到达，打印 held authorization。
- 后续被 request 消费时，打印对应 tag。

### 6.5 `accept_issue()`

#### `[CACHE][ISSUE]`

- 等级：L3。
- 内容：cycle、tag、order、subop、virtual address、访问长度、read/store、FP 标记、authorization 状态。

### 6.6 `execute_pending()`

#### `[CACHE][EXEC]`

- 等级：L3。
- 内容：tag、DPI rc。

#### `[CACHE][EXEC_FAIL]`

- 等级：L1。
- 内容：tag、rc、subop、virtual address。

### 6.7 `commit_store()`

#### `[CACHE][STORE_COMMIT]`

- 等级：L3。
- 内容：cycle、tag、virtual address、store data。

### 6.8 `log_authorization_wait()`

#### `[CACHE][WAIT_AUTH]`

- 等级：L3。
- 打印等待 store authorization 的 tag。

### 6.9 `service_memory_ops()`

#### `[CACHE][MEM_LOAD]`

- 等级：L3。
- 打印 tag、rc，以及 load 返回值。

#### `[CACHE][MEM_REQ]`

- 等级：L3。
- 打印 tag、rc。

### 6.10 `service_flush()`

#### `[CACHE][FLUSH]`

- 等级：L2。
- 内容：cycle、live request 数量、done queue、exception queue、flush owner。

### 6.11 `drive_outputs()`

#### `[CACHE][EXCP_OUT]`

- 等级：L2。
- 内容：cycle、tag、cause、tval。

#### `[CACHE][DONE_OUT]`

- 等级：L2。
- 内容：cycle、tag、read/store、data。

### 6.12 结构性错误

以下问题不作为普通 verbosity 打印，而是通过 reporter fatal 报告：

- 重复 tag
- 错误 payload
- 非法 handshake
- 错误队列状态

## 7. 与后续 COSIM 的关系

上述打印是后续 COSIM 观察字段的日志来源，但 COSIM 不应通过解析这些文本日志工作。

后续应从相同的结构化事件中分别生成：

1. 完整 debug log。
2. 精简的 `ob_cosim_if` COSIM 观察信号子集。

后续调整打印点时应保持以下原则：

- 打印和 COSIM 观察尽量使用同源字段。
- `cycle`、`retire_count`、`ready_cycle` 等诊断或内部管理字段可以进入日志，但不应自动变成 `ob_cosim_if` 核心信号。
- COSIM mismatch 报告应能通过 `group`、`ROB`、`PC`、`tag` 等字段回查本文件列出的原始打印。
- 修改打印等级或字段后，应同步检查 [`ORBE_BT_ENV_debug_and_print.md`](C:/Users/rsy13/OneDrive/Desktop/RIVAI/Model/orbe_bt_env/docs/Arch/ORBE_BT_ENV_debug_and_print.md) 中的设计约定。
