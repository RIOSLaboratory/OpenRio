# FE ISA Model Drive Flow

本文整理维持 ORBE FE Agent 运行所需的 ISA Model DPI，以及让 ISA Model
真正向前推进所需的最小 driver 接口集合。

这里的“最小生效集合”按运行模式区分：

- **FE-only**：FE 只把 ISA Model 当作指令内存和退出状态来源。该模式可以产生并交付 raw instruction，但 ISA Model 不会因为 FE 取指而执行程序。
- **FE + BE/Cache 集成**：FE 负责取指，BE/Cache 通过 driver DPI 解码、执行、处理内存、提交和推进模型；这些接口才会改变 ISA Model 的流水线状态。

## 1. 运行链路

```text
配置/ELF
   |
   v
create -> load_config/load_elf -> add_arg -> finalize_config
   |
   v
get_spec_pc -> fetch_mem_bank_virt (FE lookup)
   |
   v
FE valid/ready -> BE decode/execute/memory/commit (driver)
   |
   v
tick_finish -> is_to_exit/is_good -> destroy
```

FE 的 `fetch_mem_bank_virt` 是 lookup，不会提交指令，也不会推动模型执行。没有后端 driver 时，模型通常不会因 FE 取指而到达 `is_to_exit()`。

## 2. FE Agent 直接使用的 DPI

| 类别 | DPI | 必要性 | 作用 | 调用阶段 |
| --- | --- | --- | --- | --- |
| 生命周期 | `isa_dpi_create(core_num, rob_size)` | 必选 | 创建共享 `FuncMultiCore` 模型；当前单核使用 `(1, 16)` | 初始化 |
| 配置 | `isa_dpi_load_config(yaml)` | 必选 | 加载平台、内存和设备配置 | 初始化 |
| 程序装载 | `isa_dpi_load_elf(elf)` | 必选 | 装载 ELF 指令/数据并建立入口信息 | 初始化 |
| 程序参数 | `isa_dpi_add_arg(arg)` | 当前环境必选 | 增加目标程序 argv；当前实现传入 ELF 路径 | 初始化 |
| 配置完成 | `isa_dpi_finalize_config()` | 必选 | 完成配置，使后续取指和运行 API 可用 | 初始化末尾 |
| 入口查询 | `isa_dpi_get_spec_pc(core_id)` | FE 必选 | 获取入口或当前 speculative PC；FE 初始使用 core 0 | 初始化、redirect/状态查询 |
| 指令内存 lookup | `isa_dpi_fetch_mem_bank_virt(core_id, pc, length, buf, trap)` | FE 必选 | 按虚拟地址读取取指字节并返回 fetch trap；FE 按 2 字节读取 | 每条指令 |
| 退出查询 | `isa_dpi_is_to_exit()` | 集成收尾必选 | 查询模型是否请求结束 | 主循环、收尾 |
| 结果查询 | `isa_dpi_is_good()` | 集成收尾必选 | 查询退出结果是否 PASS | 收尾 |
| 生命周期 | `isa_dpi_destroy()` | 必选 | 释放共享模型句柄 | 收尾/异常清理 |

可选日志控制接口：

| DPI | 作用 |
| --- | --- |
| `isa_dpi_set_run_log(path)` + `isa_dpi_enable_run_log(ISA_API_LOG_GLOBAL)` | 设置并打开 run log |
| `isa_dpi_set_commit_log(path)` + `isa_dpi_enable_commit_log(ISA_API_LOG_GLOBAL)` | 设置并打开 commit log；内容由后端 driver 产生 |

## 3. 使模型前进的最小 driver 集合

以下接口不是 FE 取指 lookup，而是 RTL/BE 驱动 ISA Model 状态的关键集合。完整集成时应由统一的 Model owner/BE 协调调用。

| 阶段 | DPI | 必要性 | 作用 | 结果/后续动作 |
| --- | --- | --- | --- | --- |
| Issue | `isa_dpi_decode_and_issue(core_id, rob_idx, pc, encoding, force_rvc)` | 必选 | 在模型 ROB 中分配并解码一条 FE 交付的 raw instruction | 返回 instruction/ROB ID；失败则终止该 entry |
| Execute | `isa_dpi_execute_insn(core_id, rob_idx)` | 必选 | 执行已 issue 指令 | 返回 `PENDING` 时重复调用，直到 `PASS` 或 `FAIL` |
| Memory | `isa_dpi_proc_mem_load(core_id, rob_idx)` | 条件必选 | 处理 load、LR、AMO、SC 的内存请求/结果 | `SKIP` 时按指令类型转到 `proc_mem_req` |
| Memory | `isa_dpi_proc_mem_req(core_id, rob_idx)` | 条件必选 | 处理无读侧的写请求、CBO 等组合内存操作 | 由内存类型决定是否调用 |
| Store commit | `isa_dpi_store_commit(core_id)` | 条件必选 | 排出并提交 store buffer 中最老的 store | 向量/多项 store 需循环，直到不再可提交 |
| Trap | `isa_dpi_trigger_trap(core_id, rob_idx, trap_type, tvalue)` | 条件必选 | 将 FE/Cache 发现的异常注入模型 entry | 成功后进入 trap/flush 处理 |
| Commit | `isa_dpi_commit_auto(core_id, rob_idx)` 或 `isa_dpi_commit(...)` | 必选（二选一） | 提交指令并更新架构状态；`commit_auto` 包含模型自动 trap 路径 | 失败时读取 trap 信息并执行恢复 |
| Flush | `isa_dpi_flush(core_id, rob_idx)` / `isa_dpi_flush_all(core_id)` | 条件必选 | 丢弃 redirect 或异常后的年轻 entry | 与 BE redirect/恢复事件配对 |
| 周期推进 | `isa_dpi_tick_finish(force_htif_poll)` | 集成必选 | 完成一次外部 tick，轮询 HTIF/tohost 等终止状态 | 通常每个后端时钟周期调用一次 |

### 3.1 最小 driver 顺序

对一条普通指令，最小有效路径是：

```text
FE fetch
  -> decode_and_issue
  -> execute_insn (PENDING 时重复)
  -> proc_mem_load / proc_mem_req（按指令类型）
  -> store_commit（store 时，必要时循环）
  -> commit_auto 或 commit
  -> tick_finish
```

异常、redirect 和中断会在该路径上增加控制调用：

```text
异常：trigger_trap -> commit/commit_auto -> flush
redirect：查询 next_pc/is_insn_redirect -> flush 或 flush_all -> FE 重启
中断：check_interrupt -> take_interrupt -> flush/redirect
```

## 4. 配套 lookup 接口

lookup 接口读取模型状态或已产生的 entry 信息，本身不应被视为推动模型前进的替代品。

| 用途 | DPI |
| --- | --- |
| Decode/执行元数据 | `isa_dpi_get_decode_metadata`、`isa_dpi_get_decode_semantic`、`isa_dpi_get_execute_metadata`、`isa_dpi_get_lsu_issue_metadata` |
| Entry 状态 | `isa_dpi_get_insn_pc`、`isa_dpi_get_insn_rd_value`、`isa_dpi_get_next_pc_of_insn`、`isa_dpi_is_insn_redirect`、`isa_dpi_has_trap` |
| 架构/投机状态 | `isa_dpi_get_gpr`、`isa_dpi_get_fpr`、`isa_dpi_get_spec_gpr`、`isa_dpi_get_spec_fpr`、`isa_dpi_get_committed_pc`、`isa_dpi_get_csr`、`isa_dpi_get_priv` |
| 内存/MMU 查询 | `isa_dpi_read_mem_bank`、`isa_dpi_read_mem_bank_virt`、`isa_dpi_translate_pte` |
| 配置/结果查询 | `isa_dpi_is_config_ready`、`isa_dpi_is_run_started`、`isa_dpi_is_to_exit`、`isa_dpi_is_good` |

这些接口可用于 checker、观察点和 BE 决策，但不能替代 `decode_and_issue`、`execute_insn`、`commit` 或 `tick_finish`。

## 5. 不属于 FE 最小集合的接口

以下接口属于完整后端或特定设备功能，不应加入 FE-only driver：

- `isa_dpi_decode_and_issue`、`isa_dpi_execute_insn`、`isa_dpi_commit*`、`isa_dpi_flush*`：属于 BE 生命周期；集成时由 BE/统一 owner 调用。
- `isa_dpi_proc_mem_*`、`isa_dpi_store_commit`、`isa_dpi_clear_mem_reserve`：属于 Cache/LSU 和原子内存语义，只有对应指令需要时才调用。
- `isa_dpi_trigger_trap`、`isa_dpi_take_trap`、`isa_dpi_check_interrupt`、`isa_dpi_take_interrupt*`：属于异常/中断控制路径。
- `isa_dpi_step`、`isa_dpi_step_spec`：是模型自驱动路径；与 RTL-driven driver 并用会造成双重推进。

## 6. 所有权和约束

1. `isa_dpi_wrapper.cc` 当前持有单一全局模型句柄；同一时刻只能有一个 `g_sim`。
2. `create/load/finalize/destroy` 必须由一个明确 owner 配对调用，不能由 FE、BE 各自创建或销毁。
3. `fetch_mem_bank_virt` 是 lookup；不会自动执行、提交或推进 PC。
4. RTL-driven 模式中，`decode_and_issue`、`execute_insn`、内存处理、commit 和 `tick_finish` 的调用顺序必须由 BE/Cache 协调。
5. `is_to_exit` 只有在模型被后端推进并观察到 HTIF/tohost 状态后才有实际终止意义。
6. DPI wrapper 句柄不是线程安全对象；调用应在仿真器同一执行上下文中串行化。

## 7. 最小验收检查

| 检查项 | 通过标准 |
| --- | --- |
| FE-only 初始化 | create、load、finalize 成功，`get_spec_pc` 可取得入口，fetch 可读取首条指令 |
| FE 取指 | RVC/32-bit 均按 2-byte lookup 正确拼接；fetch fault 返回 cause/tval |
| 集成推进 | 每条可提交指令经过 issue、execute、必要的 memory、commit；PENDING 被重复处理 |
| 周期终止 | 后端持续调用 `tick_finish`，最终 `is_to_exit=1`，再检查 `is_good` |
| 资源释放 | 无论正常或异常退出，创建成功的模型最终恰好 destroy 一次 |

