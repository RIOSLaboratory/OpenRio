# ORBE COSIM ob_cosim_if 信号抓取计划

## 1. 文档目标

本文只回答一个问题：ORBE COSIM 需要从验证环境中抓取哪些信号。

本文不按“第一批、第二批、第三批”实现阶段分类，而是按信号所属部分分类：Commit、INT ARF、FP ARF、CSR、MEM。`cycle` 和 `sequence_id` 是 COSIM 侧生成的 counter 诊断字段，不属于 `ob_cosim_if` 抓取信号。

## 2. 总体边界

`ob_cosim_if` 是 ORBE COSIM 专用观察接口，负责承载从 ORBE RTL、`MOCK_RTL` 或验证环境中抓出来的观察信号。COSIM checker 不应直接访问 RTL 层级路径，也不应依赖 BETA/P600 专用类型。

信号来源分为两类：

| 类别 | 是否进入 `ob_cosim_if` | 示例 |
| --- | --- | --- |
| 环境抓取信号 | 是 | Commit、INT ARF、FP ARF、CSR、MEM |
| COSIM 自生成字段 | 否 | `cycle`、`sequence_id` |

并行观察路径统一称为第 0 组通道和第 1 组通道，不再在 ORBE 文档中把 `lane` 作为主术语。

## 3. Commit 相关信号

Commit 事件是 COSIM 推进 reference 和触发架构状态比较的核心时机信号，必须抓取。

| 信号/信息 | 位宽/形态 | 来源 | 用途 | 当前核心必抓 |
| --- | --- | --- | --- | --- |
| `commit_valid[0]` | 1 bit | 第 0 组提交通道 | 指示第 0 组通道发生有效提交 | 是 |
| `commit_valid[1]` | 1 bit | 第 1 组提交通道 | 指示第 1 组通道发生有效提交 | 是 |
| `commit_pc[0]` | 64 bit | 第 0 组提交通道 | 与 reference commit PC 序列对齐 | 是 |
| `commit_pc[1]` | 64 bit | 第 1 组提交通道 | 与 reference commit PC 序列对齐 | 是 |
| `commit_rob_idx[0]` | ROB index width | 第 0 组提交通道 | 日志定位和提交事件关联 | 是 |
| `commit_rob_idx[1]` | ROB index width | 第 1 组提交通道 | 日志定位和提交事件关联 | 是 |

同周期两组通道都有效时，COSIM 按 ORBE 定义的架构提交顺序消费。若没有额外排序规则，默认顺序为第 0 组通道先于第 1 组通道。

`rd` 和 `rd_valid` 不再作为核心必抓信号。完整 INT ARF/FP ARF 快照已经能够覆盖架构寄存器状态比较；`rd` / `rd_valid` 后续最多作为辅助诊断字段。

## 4. INT ARF 相关信号

INT ARF 采用完整快照直连观察。

| 信号/信息 | 位宽/形态 | 来源 | 用途 | 当前核心必抓 |
| --- | --- | --- | --- | --- |
| `int_arf[0]` | 64 bit | INT ARF x0 | 检查 x0 恒为 0 | 是 |
| `int_arf[1:31]` | 31 x 64 bit | INT ARF x1-x31 | 与 reference INT 架构状态比较 | 是 |

INT ARF 直连规模为 32 x 64 bit。`int_arf[0]` 必须始终为 0。

当前阶段不把 `int_arf_valid` 作为核心抓取信号。INT ARF 是持续可见的架构状态，不是一次性事件 payload；比较时机由 reset 状态、Commit event 和约定的采样时序共同决定。只有未来改成 debug scan、多周期读口或跨时钟快照 FIFO 时，才需要类似 `snapshot_valid` 的观察通道有效位。

## 5. FP ARF 相关信号

FP ARF 同样采用完整快照直连观察。

| 信号/信息 | 位宽/形态 | 来源 | 用途 | 当前核心必抓 |
| --- | --- | --- | --- | --- |
| `fp_arf[0:31]` | 32 x 64 bit | FP ARF f0-f31 | 与 reference FP 架构状态比较 | 是 |

INT ARF 和 FP ARF 合计为 64 个 64-bit 架构寄存器，物理直连规模为 4096 bit。该路径不引入 BETA 的 `prd`、PRF/RAT 或 ORBE 不存在的 `rd_is_v`。

当前阶段不把 `fp_arf_valid` 作为核心抓取信号。FP ARF 与 INT ARF 一样按持续架构状态处理；如果未来传输方式不再是直连快照，再单独定义观察通道级的 `snapshot_valid`。

## 6. CSR 相关信号

CSR 观察面是独立信号类，主要服务于 CSR 指令和架构状态校验，不等同于 trap 事件。

| 信号/信息 | 位宽/形态 | 来源 | 用途 | 当前核心必抓 |
| --- | --- | --- | --- | --- |
| `csr_valid` | 1 bit | CSR 采样边界 | 指示 CSR 状态或事件有效 | 待定 |
| `csr_state[...]` | 按 CSR 列表展开 | CSR 文件 | 与 reference CSR 状态比较 | 待定 |
| `csr_event_valid` | 1 bit | CSR 指令执行/提交事件 | 辅助定位 CSR 指令行为 | 否 |
| `csr_event_addr` | CSR addr width | CSR 指令事件 | 记录被访问的 CSR 编号 | 否 |
| `csr_event_wdata` | 64 bit | CSR 指令事件 | 记录 CSR 写入值 | 否 |
| `csr_event_rdata` | 64 bit | CSR 指令事件 | 记录 CSR 读出值 | 否 |

具体 `csr_state[...]` 列表需要根据 ISA case 覆盖范围冻结。当前阶段不把 `mepc` / `mcause` 作为 trap 必抓信号；如果后续要做 CSR 精确状态比较，再把相关 CSR 纳入 `csr_state[...]`。

## 7. MEM 相关信号

MEM 观察面源头来自 `cache_agent`，需要进入 `be_agent` 和 COSIM 观察链路。但 `ob_cosim_if` 不应镜像 `cache_agent` 的全部内部状态；核心抓取面只保留架构 memory 状态真正变化所需的信息，其余信息优先进入 `.log`。

### 7.1 核心必抓：Store Commit 事件

Store 不写回 INT ARF/FP ARF。如果 store 地址、数据或宽度错误，而后续测试没有 load 读回该地址，PC 和 ARF 快照可能都无法发现。因此，若 COSIM 要覆盖 memory 架构状态，store commit 是 MEM 侧最重要的核心观察事件。

| 信号/信息 | 位宽/形态 | 来源 | 用途 | 当前核心必抓 |
| --- | --- | --- | --- | --- |
| `mem_store_commit_valid` | 1 bit | `cache_agent` store commit | 指示 store-side 请求真正改变 memory 架构状态 | 是 |
| `mem_store_commit_order` | order 或等价顺序字段 | `cache_agent` / store record | 确定多个 store 的架构生效顺序 | 是 |
| `mem_store_commit_vaddr` | 64 bit | store-side record | 记录 store/AMO/SC 写地址 | 是 |
| `mem_store_commit_data` | 64 bit | store-side record | 记录写入 memory 的数据 | 是 |
| `mem_store_commit_mask` | byte mask | store-side record | 记录实际写入字节，支持非 64-bit store | 是 |
| `mem_store_commit_pc` | 64 bit | store-side record / ROB 关联 | 将 store commit 事件关联回提交 PC | 是 |
| `mem_store_commit_rob_idx` | ROB index width 或 zero-extended tag | store-side record / ROB 关联 | 将 store commit 事件关联回提交条目 | 是 |
| `mem_store_commit_terminal` | 1 bit | `cache_agent` / memory monitor | 标记 tohost 等会结束测试的 terminal store | 是 |

`mem_store_commit_valid` 不能用普通 `commit_valid` 代替。`commit_valid` 表示指令提交，`mem_store_commit_valid` 表示 memory 状态真正被写入；在 store buffer、flush/redirect、AMO/SC 等场景下，这两个时机不一定等价。

如果实现上暂时没有 byte mask，也至少需要提供 `mem_store_commit_size` 或 `mem_store_commit_funct3`，否则 COSIM 无法判断非 64-bit store 改写了哪些字节。

### 7.2 诊断建议保留：Load Done 和 MEM Exception

Load 的返回值最终会进入 INT ARF 或 FP ARF，完整 ARF 快照可以发现 load 值错误。因此 load done 不作为 memory 核心比较必需信号，但建议保留为诊断信息，方便从 ARF mismatch 反推到具体 memory 事务。

| 信号/信息 | 位宽/形态 | 来源 | 用途 | 当前核心必抓 |
| --- | --- | --- | --- | --- |
| `mem_load_done_valid` | 1 bit | `cache_agent` / LSU done | 指示 load/read-side 请求完成 | 否，诊断建议保留 |
| `mem_load_done_vaddr` | 64 bit | load-side record | 定位 load 地址 | 否，诊断建议保留 |
| `mem_load_done_data` | 64 bit | LSU done payload | 定位 load 返回值 | 否，诊断建议保留 |
| `mem_load_done_mask` 或 `mem_load_done_size` | byte mask 或 size | load-side record | 定位访问宽度 | 否，诊断建议保留 |
| `mem_exception_valid` | 1 bit | `cache_agent` exception queue | 记录 memory exception 发生 | 否，诊断建议保留 |
| `mem_exception_cause` | cause width | exception payload | 记录 memory 访问异常类型 | 否，诊断建议保留 |
| `mem_exception_tval` | 64 bit | exception payload | 记录异常地址或附加信息 | 否，诊断建议保留 |

### 7.3 只进 log：Cache 内部管理状态

下面这些字段更适合留在 debug `.log`，不应作为 `ob_cosim_if` 核心信号：

- `mem_issue_*` 的完整 payload，例如 `subop`、`req_property`、`mem_funct3`、`rs1_data`、`rs2_data`。
- `done_q`、`excp_q`、`store_fifo`、`store_buffer_count`。
- `older_store_pending`、`store_authorized`、`ready_cycle`、`rc`。
- flush 时 cache 内部队列被清空、保留或延后输出的详细状态。

这些信息对 debug 有价值，但它们描述的是 `cache_agent` 内部事务管理状态，不是 COSIM 核心架构观察面。把它们全部拉进 `ob_cosim_if` 会让 COSIM 过度依赖 cache_agent 实现细节。

## 8. Trap 当前阶段处理范围

当前阶段 COSIM 不单独抓取 `trap_valid/trap_epc/trap_cause/trap_target_pc`，也不把 `mepc` / `mcause` 作为 trap 必抓信号。

trap 指令 PC 先按普通 commit PC 路径进入 PC 序列比较。若 trap 处理错误导致 handler PC、`mret` 返回 PC 或 INT/FP ARF 状态不一致，后续普通 PC/ARF 比较会暴露问题。

这条结论只限定当前阶段。未来如果要做异常精确校验、trap handler 诊断增强或 CSR 精确状态比较，可以重新加入独立 trap 事件和相关 CSR。

## 9. 接入 rtl_v1 时的信号来源

真实 `rtl/rtl_v1` 接入时，`ob_cosim_if` 仍保持产品中立，所有真实 RTL 层级路径、RTL 私有类型和临时适配逻辑都收敛在 `rtl_v1_wrapper` 或 wrapper 侧 bind monitor 中。层级上，`mock_rtl` 和 `rtl_v1/backend_top` 同属 DUT 实现层；`rtl_v1_wrapper` 是包在真实 RTL 上方的适配/观察绑定层。`be_agent`、COSIM adapter 和 `cosim_agent` 不直接访问 `backend_top` 层级。

推荐结构如下：

```text
be_tb_top
  |
  +-- DUT 接入层 / observation binding
        |
        +-- mock 路径
        |     |
        |     +-- 当前无额外 wrapper
        |           直接接环境接口
        |           |
        |           +-- mock_rtl
        |               DUT 实现替身层
        |
        +-- 真实 RTL 路径
              |
              +-- rtl_v1_wrapper
                    适配/观察绑定层
                    |
                    +-- rtl_v1/backend_top
                        真实 DUT 实现层

观察出口：
  ob_if v2     ：be_agent 共享模型生命周期观察面
  ob_cosim_if  ：COSIM 专用观察面
```

短期为了复用当前 `be_agent`，真实 RTL 路径中的 `rtl_v1_wrapper` 需要同时驱动 `ob_if` 和 `ob_cosim_if`。其中 `ob_if` v2 服务共享 ISA model 的 decode/execute/commit/recovery 生命周期，`ob_cosim_if` 只服务独立 COSIM reference 的比较输入。旧 `ob_if` 字段只作为迁移期 alias 保留，后续可以逐步删除 mock 命名和兼容 payload。

### 9.1 Commit 绑定

`backend_top` 已经有第 0/1 组提交观察端口，wrapper 可直接绑定到 `ob_cosim_if`：

| `ob_cosim_if` 字段 | `rtl_v1` 推荐来源 | 说明 |
| --- | --- | --- |
| `commit_valid[group]` | `backend_top.commit_valid[group]` | 组号与 `ISSUE_WIDTH=2` 的提交口一一对应。 |
| `commit_pc[group]` | `backend_top.trace_pc[group]` | `trace_pc` 是 commit-point PC_File 读口，只有 `commit_valid[group]` 有效时消费。 |
| `commit_rob_idx[group]` | zero-extend `backend_top.commit_tag[group]` | `rtl_v1` 的 tag 是 4-bit ROB slot/tag；当前环境 `ROB_ADDR_W` 为 6，可高位补 0。 |

同周期双提交时仍按 group 递增顺序消费。`backend_top.commit_count` 可用于 wrapper 内断言，例如检查 `commit_count == commit_valid[0] + commit_valid[1]`，但不需要进入 `ob_cosim_if`。

### 9.2 INT/FP ARF 绑定

`rtl_v1` 的 `INT_ARF` 和 `FP_ARF` 当前公开端口是读口，不是完整 32 项 snapshot。真实 RTL COSIM 需要完整架构寄存器快照，推荐两种实现路径：

| 路径 | 做法 | 使用阶段 |
| --- | --- | --- |
| wrapper 层级绑定 | `rtl_v1_wrapper` 或 bind monitor 读取 `u_backend.u_INT_ARF.entry_arf[index]` 和 `u_backend.u_FP_ARF.entry_arf[index]`，驱动 `ob_cosim_if.int_arf/fp_arf`。`int_arf[0]` 强制检查为 0。 | bring-up 快速打通。 |
| 仿真专用 snapshot 端口 | 给 `INT_ARF/FP_ARF` 增加 `ifndef SYNTHESIS` 保护的 32 项 observation 输出，wrapper 只连端口，不读内部层级。 | 长期稳定方案。 |

采样时序要求是：COSIM 看到的 ARF snapshot 必须是本采样周期所有有效 commit 已经写入后的架构状态。当前 `be_agent` 在 negedge 采样并发布 arch state，因此 wrapper 侧应提供 posedge commit 写入后的稳定值；不要用同拍 read-port 数据拼完整快照。

### 9.3 CSR 绑定

CSR 当前仍按“列表冻结后再比较”的策略推进。接入 `rtl_v1` 的第一阶段可沿用 mock 做法：

- `csr_valid = 1'b0`
- `csr_state_valid = '0`
- `csr_state_addr/state = '0`
- `csr_event_valid = 1'b0`

后续冻结 CSR 列表后，`rtl_v1_wrapper` 再从 `backend_top.u_system_instruction_handler` 绑定 CSR 寄存器，或由 `system_instruction_handler` 增加仿真专用 snapshot 端口。只有完整 CSR snapshot 稳定时才拉高 `csr_valid`；单条 CSR 指令事件只能作为诊断，不替代架构 CSR state 比较。

### 9.4 MEM 绑定

当前完整环境里，memory 行为源头仍是 `cache_agent`。接真实 `backend_top` 时，wrapper 只负责连接 BE-LSU 边界，`mem_store_commit_*` 继续由 `cache_agent` 在 store 真正写入共享 ISA model memory 时驱动。

如果后续 `cache_agent` 被真实 LSU/cache monitor 替换，新的 monitor 仍必须输出同一组 `mem_store_commit_*` 字段，不能把 cache 内部队列和授权状态直接搬进 `ob_cosim_if`。

### 9.5 与 ob_if v2 的生命周期观察关系

虽然 `ob_cosim_if` 是 COSIM 边界，当前 `be_agent` 还依赖 `ob_if` 维护共享 ISA model 的 decode/execute/commit/recovery 生命周期。因此 `ob_if` 应升级成统一的 BE lifecycle observation interface。新增字段需要和 `rtl_v1` 的公开顶层观察语义联动，但不应无条件照搬所有 RTL 名字：

1. `backend_top` 已公开且语义就是观察事件的信号，`ob_if` 尽量同名，例如 `alloc_valid`、`alloc_tag`、`exec_valid`、`exec_tag`、`commit_valid`、`commit_tag`、`commit_count`、`redirect_valid`、`redirect_pc`、`redirect_kind`、`global_flush`。
2. RTL 内部层级名只留在 `rtl_v1_wrapper` 或 bind monitor 中，例如 `head_IB_Payload`、`scb_flush_tag`、`entry_arf`，不进入 `ob_if` 字段命名。
3. 顶层公开信号如果名字携带实现细节，`ob_if` 使用消费者语义命名。例如 `backend_top.trace_pc[group]` 进入 `ob_if` 后命名为 `commit_pc[group]`。
4. recovery 类型编码应与 `rtl_v1` 的 `RECOVERY_*` 保持同值。为了避免 mock flow 强依赖真实 RTL package，可在验证环境 observation package 中定义同值 enum，由 `rtl_v1_wrapper` 做 cast/断言。

推荐 `ob_if` v2 字段如下：

| `ob_if` v2 字段 | `rtl_v1` 推荐来源 | 与 `ob_cosim_if` 的关系 |
| --- | --- | --- |
| `alloc_valid[group]` | `backend_top.alloc_valid[group]` | 只服务共享模型生命周期，不进入 COSIM 核心提交比较面。 |
| `alloc_tag[group]` | zero-extend `backend_top.alloc_tag[group]` | 只服务共享模型 ROB 映射，宽度由环境统一。 |
| `alloc_pld[group].pc` | alloc 同拍 instruction payload | 当前不是 `backend_top` 公开端口，wrapper/bind 从同源内部网抓取。 |
| `alloc_pld[group].inst_bits` | alloc 同拍 raw instruction | 当前不是 `ob_cosim_if` 核心字段；压缩指令高 16 bit 补 0。 |
| `alloc_pld[group].is_compressed` | alloc 同拍 instruction payload | 只服务 decode/共享模型生命周期。 |
| `alloc_pld[group].fetch_excp_*` | alloc 同拍 instruction payload | fetch exception 需要随 alloc 进入共享模型。 |
| `exec_valid[source]` | `backend_top.exec_valid[source]` | 只服务共享模型 execute completion。 |
| `exec_tag[source]` | zero-extend `backend_top.exec_tag[source]` | 只服务共享模型 execute completion。 |
| `commit_valid[group]` | `backend_top.commit_valid[group]` | 与 `ob_cosim_if.commit_valid[group]` 同源。 |
| `commit_tag[group]` | zero-extend `backend_top.commit_tag[group]` | 与 `ob_cosim_if.commit_rob_idx[group]` 同源。 |
| `commit_pc[group]` | `backend_top.trace_pc[group]` | 与 `ob_cosim_if.commit_pc[group]` 同源，但字段名采用提交语义。 |
| `commit_count` | `backend_top.commit_count` | 用于断言和 recovery squash 边界计算。 |
| `recovery_valid` | `backend_top.global_flush` 或 `redirect_valid` | 不替代 commit 事件；同周期 commit 必须先被消费。 |
| `recovery_kind` | `backend_top.redirect_kind` | 编码与 `rtl_v1` `RECOVERY_*` 同值。 |
| `recovery_origin_tag` | `scb_flush_tag` 或等价源 | RTL 恢复来源 tag，只在 wrapper/bind 中持有内部层级路径。 |
| `recovery_squash_tag` | wrapper 根据 `commit_count` / `recovery_kind` / `recovery_origin_tag` 计算 | 共享 ISA model flush 应使用的第一条被 squash 的 ROB tag。 |
| `recovery_redirect_pc` | `backend_top.redirect_pc` | 与 FE 看到的 redirect PC 同源。 |

旧 `rob_alloc_*`、`exe_rob_wr_*`、`rob_commit_*`、`flush_all/pflush/pflush_rob_idx` 可以在迁移期保留为 legacy alias，保证当前 mock 回归不断。新增 `be_agent` 逻辑应优先消费 `ob_if` v2 字段，再逐步删除 legacy alias。

这里的 alloc payload 和 recovery 边界是真实 RTL 接入的两个关键点。`backend_top` 目前公开 `alloc_valid/alloc_tag`，但没有公开 `alloc_pc/alloc_inst_bits/is_compressed/fetch_excp_*`；第一阶段推荐由 wrapper/bind 读取同源内部网，不默认要求 DUT 增加仿真宏或 observation 端口。recovery 侧不能只保留旧 `flush_all/pflush/pflush_rob_idx`，因为 `rtl_v1` 的 `CompletionScoreboard` 定义了 commit-then-flush 语义。

### 9.6 wrapper 侧基本断言

`rtl_v1_wrapper` 应放置最小断言，尽早暴露绑定错误：

1. `commit_valid[1]` 不能在 `commit_valid[0]` 无效时单独有效，除非 RTL 明确定义非前缀提交并给出排序字段。
2. `commit_valid[group]` 有效时，`commit_pc[group]` 和 `commit_rob_idx[group]` 不能为 X/Z。
3. `ob_cosim_if.int_arf[0]` 必须恒为 0。
4. ARF snapshot 任何被比较的 entry 不能为 X/Z。
5. `mem_store_commit_valid` 与 `commit_valid` 不是同一事件，wrapper 不应用 ROB commit 脉冲伪造 store commit。
6. 真实 DUT 对 FE/LSU 的 `redirect_valid/global_flush` 必须保持原始时序；`be_agent` 应按 `commit_valid` 先于 `recovery_valid` 的顺序消费 `ob_if` v2 观察。

## 10. Print 到 ob_cosim_if 的推进关系

当前最优先的工作是先冻结 `.log` 里要打印的信息，再把同类信息接入 `ob_cosim_if`。

推荐推进顺序：

1. 参考 `ORBE_BT_ENV_debug_and_print.md`，确定普通运行事件和错误事件需要打印哪些字段。
2. 在 FE / Cache / BE 相关 agent 中稳定输出 `.log`。
3. 将同类字段整理为 `ob_cosim_if` 观察信号。
4. 由 `be_agent` 和 COSIM 相关模块读取、排序和比较。

## 11. 总结

ORBE COSIM 的抓取信号应按 Commit / INT ARF / FP ARF / CSR / MEM 分类定义。Commit 事件用于推进 reference 和确定比较时机；INT ARF/FP ARF 完整快照是架构寄存器比较主路径；CSR 作为独立架构状态类后续冻结；MEM 信号来自 `cache_agent` 或后续真实 memory monitor 并进入 `be_agent`；`cycle` 和 `sequence_id` 由 COSIM 侧生成，不属于 `ob_cosim_if` 抓取信号。接入 `rtl_v1` 时，真实 RTL 层级绑定只允许存在于 `rtl_v1_wrapper` 或 wrapper 侧 bind monitor，不能扩散进 COSIM checker。
