# ORBE COSIM 设计计划

## 1. 文档目标

本文定义 ORBE COSIM 的观察边界、信号分类和实施步骤，并以当前 BETA BE BT 环境作为参考。

本文中的“当前 ORBE 环境”特指当前 `tb` 目录和正在接入的 `rtl_v1/backend_top` 正式 RTL 路径。

本文重点解决三个问题：

1. BETA COSIM 的结构，以及是取得哪些待测 RTL 信息。
2. ORBE COSIM 未来采用的结构：如何建立 `rtl_v1_wrapper -> backend_top observation -> ob_if/ob_cosim_if -> be_agent -> COSIM adapter/checker -> cosim_agent` 的观察路径？
3. 为了先定义 COSIM 观察面，需要补充哪些 Commit、INT ARF、FP ARF、CSR 和 MEM 信号。

## 2. 当前 BETA COSIM 结构

### 2.1 实际数据路径

BETA 的 `cosim_agent` 本身只读取 `virtual cosim_if`，不在 agent 代码中直接访问 RTL 层级。但 BETA 的 `cosim_if` 并不是完全由 `BE_observer` 提供数据。

```text
      待测 BETA RTL / DUT
        |            |
        v            |
      ob_if          |
        |            |
        v            v
      BE_agent / BE_observer
           |
           v
       cosim_if                      独立 ISA reference
           |                                  |
           v                                  v
                     cosim_agent
```

更准确的描述是：

- ROB allocation、ROB commit、EXE writeback、flush、redirect 等观察信息先由 `be_tb_top.sv` 通过层级路径送入 `ob_if`，供 BETA 的 BE agent 使用。
- `cosim_if.commit_tick` 和 `cosim_if.commit_pld` 复用了 `ob_if.rob_commit_valid` 和 `ob_if.rob_commit_pld`。
- `cosim_if.commit_int_value`、`cosim_if.commit_fp_value` 由 `be_tb_top.sv` 直接读取 RTL 的整数 PRF/FPRF 层级后赋值。
- `cosim_if.arch_gpr`、`cosim_if.arch_fpr` 由顶层直接通过 backup RAT -> PRF/FPRF 层级重建。
- `cosim_if.trap_*` 由顶层直接读取 IRU/CSR 异常层级信号。
- `cosim_agent` 最终只看到 `cosim_if`，但 `BE_observer` 并没有成为所有 COSIM 数据的唯一中间层。

因此，BETA 满足“COSIM agent 不直接读 RTL”的要求，但没有完全满足“所有 RTL 观察信息必须经过 BE_observer 再进入 COSIM”的要求。

### 2.2 BETA COSIM 的主要组成

| 组成 | 作用 |
| --- | --- |
| `ob_if` | 承载 ROB/执行/flush 等原始观察信号，供 BE agent 使用。 |
| BETA `BE_agent` | 读取 `ob_if`，维护 ROB 到共享 ISA model 的映射，并处理 decode、execute、commit、flush 和 trap。 |
| `cosim_if` | 承载提交事件、提交值、架构寄存器快照和同步异常信息。 |
| `cosim_agent` | 按提交顺序推进独立 reference model，并比较 PC、GPR、FPR 和异常边界。 |
| 独立 ISA reference | 使用独立 DPI handle，避免与 BE agent 的共享 model 状态相互污染。 |

## 3. 当前 BETA 截取的信号

### 3.1 正常提交信息

| 信号/信息 | 定义 | 作用 |
| --- | --- | --- |
| `commit_tick[lane]` | 每个提交 lane 的有效脉冲。 | 触发 reference `step_one()`，确定同周期提交顺序。 |
| `commit_pld[lane].pc` | 提交指令的架构 PC。 | 与 reference step 前 PC 比较。 |
| `commit_pld[lane].rob_idx` | 提交 ROB 条目索引。 | 日志定位和 ROB 关联。 |
| `commit_pld[lane].rd` | 目的架构寄存器编号。 | 决定更新哪一个 GPR/FPR。 |
| `commit_pld[lane].prd` | 目的物理寄存器编号。 | 索引 PRF/FPRF 并辅助诊断。 |
| `commit_pld[lane].rd_is_fp` | 目的寄存器是否属于 FPR。 | 选择 GPR 或 FPR 更新路径。 |
| `commit_pld[lane].rd_is_v` | 目的寄存器是否属于向量寄存器。 | 避免向量写回被误当成 GPR/FPR。 |

### 3.2 提交值和架构状态

| 信号/信息 | 定义 | 作用 |
| --- | --- | --- |
| `commit_int_value[lane]` | 提交 lane 对应的整数 PRF 值。 | 更新该 lane 对应的 GPR shadow state。 |
| `commit_fp_value[lane]` | 提交 lane 对应的 FP PRF/FPRF 值。 | 更新该 lane 对应的 FPR shadow state。 |
| `arch_gpr[0:31]` | 提交后整数架构寄存器视图。 | 延迟一拍比较完整 GPR 状态。 |
| `arch_fpr[0:31]` | 提交后 FP 架构寄存器视图。 | 延迟一拍比较完整 FPR 状态。 |
| `arch_gpr_valid[0:31]` | GPR 架构映射有效标志。 | 诊断 RAT/PRF 有效性。 |
| `arch_fpr_valid[0:31]` | FPR 架构映射有效标志。 | 诊断 FRAT/FPRF 有效性。 |

BETA 顶层的关键取数关系如下：

```text
commit_pld.prd
    -> integer PRF/FPRF
    -> commit_int_value / commit_fp_value

architectural register index
    -> backup RAT / backup FRAT
    -> PRF / FPRF
    -> arch_gpr / arch_fpr
```

### 3.3 同步异常信息

| 信号/信息 | 定义 | 作用 |
| --- | --- | --- |
| `trap_tick` | 同步异常被架构接受的脉冲。 | 处理不产生普通 ROB commit 的异常指令。 |
| `trap_epc` | 异常指令的 EPC/PC。 | 与 reference step 前 PC 对齐。 |
| `trap_cause` | 同步异常原因码。 | 记录和定位异常类型。 |
| `trap_target_pc` | 异常处理入口 PC。 | 与 reference step 后 PC 对齐。 |

### 3.4 BETA COSIM 的 reference 侧信息

这些不是待测 RTL 观察信号，但属于 COSIM 的比较基准：

| 信息/API | 作用 |
| --- | --- |
| `isa_cosim_dpi_step(1)` | 每个 commit lane 或同步 trap 消费一条 reference 指令。 |
| `isa_cosim_dpi_get_committed_pc()` | 取得 reference 当前 PC。 |
| `isa_cosim_dpi_get_gpr()` | 取得 reference GPR 状态。 |
| `isa_cosim_dpi_get_fpr()` | 取得 reference FPR 状态。 |
| `isa_cosim_dpi_is_to_exit()` | 判断 reference 是否到达退出状态。 |
| `isa_cosim_dpi_is_good()` | 判断 reference 最终结果是否 PASS。 |

## 4. ORBE 计划的 COSIM 环境

### 4.1 会议后的目标口径

9/1 会议后，ORBE COSIM 的近期目标调整为：先定义清楚验证环境需要观察、打印和拉取哪些信息，再推进具体 checker 和比较逻辑。本文后续 ORBE 章节中的 COSIM 观察接口统一称为 `ob_cosim_if`。

BETA 参考章节保留 BETA 原始 `ob_if` / `cosim_if` 命名，不代表 ORBE 后续接口命名继续沿用 BETA。

### 4.2 目标数据路径

ORBE 计划采用以下正式 RTL 观察路径，并与独立 ISA reference model 在 COSIM 相关模块中汇合。关键边界是：`backend_top` 不直接认识 COSIM；`rtl_v1_wrapper` 负责功能端口适配和 observation 映射；`be_agent` 只消费统一观察接口，不读取 RTL 私有层级。

```text
                              功能路径

fe_agent -------------------> orbe_fe_if --------------------+
                                                             |
cache_agent ----------------> or_be_lsu_if ------------------+
                                                             |
                                                             v
                                                    +----------------+
                                                    | rtl_v1_wrapper |
                                                    |                |
                                                    |  +----------+  |
                                                    |  |backend_top| |
                                                    |  +----|-----+  |
                                                    |       |        |
                                                    |       | RTL-near
                                                    |       | observation
                                                    |       v        |
                                                    | rtl_v1_obs     |
                                                    | source/probe   |
                                                    |       |        |
                                                    |       v        |
                                                    | observation    |
                                                    | mapper         |
                                                    +-------|--------+
                                                            |
                                                            v
                                                    ob_if / ob_cosim_if
                                                            |
                                                            v
                                                         be_agent
                                                            |
                                                            v
                                                   COSIM adapter/checker
                                                            |
                                                            v
                                                   独立 ISA reference

cache_agent -- MEM store commit observation -----------------^
```

图中的 `rtl_v1_obs source/probe` 就是新增 observation 的位置。它靠近 `backend_top`，负责把正式 RTL 的 alloc payload、commit、recovery、ARF snapshot、CSR snapshot 等信息整理成稳定观察源；它不调用 DPI，不推进 reference，也不直接做 PASS/FAIL 判断。

`ob_if` / `ob_cosim_if` 是验证环境侧的统一观察接口。二者可以暂时保持分离：`ob_if` 继续服务 BE 生命周期和共享模型锚点，`ob_cosim_if` 服务独立 reference 的提交和架构状态比较。后续如果字段稳定，可以再合并成一个 `orbe_obs_if`，但这不是接正式 RTL 的前置条件。

`ob_cosim_if` 只承载从正式 RTL 或验证环境抓出来的观察信号。`cycle`、`sequence_id` 这类 counter 逻辑由 COSIM 侧产生，不从 `ob_cosim_if` 提取。

当前实现里 `be_agent` 还依赖 `ob_if` 推进共享 ISA model 的 decode/execute/commit/recovery 生命周期。因此第一版 `rtl_v1_wrapper` 需要同时驱动两条观察出口：

- `ob_if` v2：服务当前 BE 侧共享模型和 getter 机制，旧字段只作为迁移期 legacy alias 保留。
- `ob_cosim_if`：产品中立的 COSIM 观察边界，供独立 reference 比较使用。

正式 RTL 私有层级路径只允许出现在 `rtl_v1_obs source/probe` 的绑定实现里，不应进入 `be_agent`、COSIM checker 或独立 reference adapter。

### 4.3 各层职责

| 层 | 职责 |
| --- | --- |
| 正式 RTL：`rtl_v1/backend_top` | 产生提交事件、INT ARF/FP ARF 状态、CSR 状态和控制流行为；不直接依赖 COSIM 接口或 DPI。 |
| `rtl_v1_obs source/probe` | 靠近 `backend_top` 的仿真观察源，收集 alloc payload、commit、recovery、ARF/CSR snapshot 等信息，并隔离 RTL 私有层级路径。 |
| `rtl_v1_wrapper` | 位于 `backend_top` 上方，完成 FE/LSU 端口适配、observation 映射、`ob_if` v2 生命周期观察、`ob_cosim_if` 绑定和 wrapper 侧断言。 |
| `cache_agent` | 提供 MEM 相关观察信息，后续通过 `ob_cosim_if` 或 `be_agent` 汇入 COSIM 观察面。 |
| `ob_cosim_if` | 承载 COSIM 需要抓取的 Commit、INT ARF、FP ARF、CSR、MEM 观察信号。 |
| `be_agent` | 从 `ob_cosim_if` 采样并整理观察信息，保持 COSIM 逻辑不直接依赖 RTL 层级路径。 |
| COSIM adapter / checker | 生成 `cycle`、`sequence_id` 等诊断字段，按提交事件推进 reference，并比较 PC 与架构状态。 |
| `cosim_agent` | 消费整理后的 COSIM 信息，管理独立 reference model 的生命周期和最终 PASS/FAIL。 |

### 4.4 通道命名修正

ORBE 相关章节不再使用 `lane` 作为主要术语。并行提交/观察路径统一描述为两组通道：

- 第 0 组通道
- 第 1 组通道

同周期两组通道都有效时，COSIM 按 ORBE 定义的架构提交顺序消费。若没有额外排序规则，默认先消费第 0 组通道，再消费第 1 组通道。

### 4.5 COSIM 自生成字段

`cycle` 和 `sequence_id` 是 COSIM 侧生成的辅助诊断字段，不属于 `ob_cosim_if` 的抓取信号。

- `cycle`：COSIM adapter/checker 本地观察周期计数，用于定位某个事件在哪个 testbench/checker 周期被消费；它不是 RISC-V CSR `cycle`，也不是某条指令在 RTL 中执行了多少拍。
- `sequence_id`：COSIM adapter/checker 对每个有效 commit event 分配的全局递增编号。它表示第几个被 COSIM 消费的提交事件，不表示 RTL 已执行过的指令数量。

示例：

```text
cycle=100 group=0 sequence_id=57 pc=...
cycle=100 group=1 sequence_id=58 pc=...
cycle=101 group=0 sequence_id=59 pc=...
```

## 5. ORBE COSIM 观察面分类

### 5.1 分类原则

后续信号不再按“第一批、第二批、第三批”实现阶段分类，而是按所属功能面分类。新的信号抓取 plan 应单独回答：ORBE COSIM 到底要抓哪些信号。

本文先给出分类原则，详细字段清单由新文档维护：

- Commit 相关信号
- INT ARF 相关信号
- FP ARF 相关信号
- CSR 相关信号
- MEM 相关信号

其中，从 RTL/环境抓取的信号与 COSIM 自生成诊断字段必须分开描述。`cycle` 和 `sequence_id` 只属于后者。

### 5.2 Commit 相关信号

Commit 事件仍然必须抓取，因为 COSIM 需要知道何时推进 reference、何时比较架构状态，以及两组通道的提交顺序。

建议 Commit 观察面至少包含：

| 信号/信息 | 定义 | 用途 |
| --- | --- | --- |
| `commit_valid[0]` / `commit_valid[1]` | 第 0/1 组通道是否发生有效提交。 | 触发 reference step 和架构状态比较。 |
| `commit_pc[0]` / `commit_pc[1]` | 第 0/1 组通道提交指令的 PC。 | 与 reference commit PC 序列对齐。 |
| `commit_rob_idx[0]` / `commit_rob_idx[1]` | 第 0/1 组通道提交对应的 ROB index。 | 日志定位和提交事件关联。 |

`rd` 和 `rd_valid` 不再作为核心必抓信号。如果完整 INT ARF/FP ARF 快照已经被抓取，架构寄存器状态比较可以直接基于 ARF 完成。`rd` / `rd_valid` 后续最多作为辅助诊断字段保留。

### 5.3 INT ARF 相关信号

INT ARF 采用完整快照观察，而不是只观察某条提交指令写回了哪个目的寄存器。

建议观察面包含：

| 信号/信息 | 定义 | 用途 |
| --- | --- | --- |
| `int_arf[0:31]` | 32 个 INT ARF 架构寄存器，每个 64 bit。 | 与 reference INT 架构状态比较。 |

`int_arf[0]` 对应 x0，必须始终为 0。若采用物理直连方式，INT ARF 需要 32 x 64 bit 观察线。

当前阶段不把 `int_arf_valid` 作为核心抓取信号。INT ARF 是持续可见的架构状态，不是一次性事件 payload；比较时机由 reset 状态、Commit event 和约定的采样时序共同决定。

### 5.4 FP ARF 相关信号

FP ARF 同样采用完整快照观察。

建议观察面包含：

| 信号/信息 | 定义 | 用途 |
| --- | --- | --- |
| `fp_arf[0:31]` | 32 个 FP ARF 架构寄存器，每个 64 bit。 | 与 reference FP 架构状态比较。 |

INT ARF 和 FP ARF 合计为 64 个 64-bit 架构寄存器，物理直连规模为 4096 bit。该路径不引入 `prd`、PRF/RAT 或 `rd_is_v`。

当前阶段不把 `fp_arf_valid` 作为核心抓取信号。只有未来 ARF 不是直连快照，而是通过 debug scan、多周期读口或跨时钟快照 FIFO 输出时，才需要单独定义观察通道级 `snapshot_valid`。

### 5.5 CSR 相关信号

CSR 观察面作为独立缺口保留。CSR 不是 trap 本身，CSR 相关信号的引入主要服务于 CSR 指令和架构状态校验，而不是为了当前阶段单独追踪 trap。

建议后续冻结一组 CSR 观察信号，例如：

| 信号/信息 | 定义 | 用途 |
| --- | --- | --- |
| `csr_valid` | CSR 快照或 CSR 事件有效。 | 指示 CSR 观察信息可被 COSIM 消费。 |
| `csr_state[...]` | 需要比较的 CSR 状态集合。 | 与 reference CSR 状态比较。 |
| `csr_event_*` | CSR 指令读写事件，可选。 | 辅助定位 CSR 指令相关错误。 |

具体 CSR 列表需要根据 ISA case 覆盖范围冻结。当前阶段不把 `mepc` / `mcause` 作为 trap 必抓信号；如果后续要做 CSR 精确状态比较，再把相关 CSR 纳入 `csr_state[...]`。

### 5.6 MEM 相关信号

MEM 观察面是当前计划缺口之一，源头来自 `cache_agent`，后续需要接入 `be_agent`，再进入 COSIM 观察/比较链路。但 `ob_cosim_if` 不应镜像 `cache_agent` 的全部内部状态。

MEM 核心抓取面建议只保留 store commit 事件：

| 信号/信息 | 来源 | 用途 |
| --- | --- | --- |
| `mem_store_commit_valid` | `cache_agent` store commit 路径 | 指示 store-side 请求真正改变 memory 架构状态。 |
| `mem_store_commit_order` | `cache_agent` / store record | 确定多个 store 的架构生效顺序。 |
| `mem_store_commit_vaddr` | store-side record | 记录 store/AMO/SC 写地址。 |
| `mem_store_commit_data` | store-side record | 记录写入 memory 的数据。 |
| `mem_store_commit_mask` | store-side record | 记录实际写入字节，支持非 64-bit store。 |

保留 `mem_store_commit_valid` 的原因是：store 不写回 INT ARF/FP ARF。如果 store 地址、数据或宽度错误，而后续测试没有 load 读回该地址，PC 和 ARF 快照可能都无法发现。`commit_valid` 只表示指令提交，`mem_store_commit_valid` 才表示 memory 架构状态真正被写入。

Load done 和 MEM exception 建议作为诊断信息保留，例如 `mem_load_done_valid/vaddr/data/size` 和 `mem_exception_valid/cause/tval`。Cache 内部管理状态，例如完整 `mem_issue_*` payload、`done_q`、`excp_q`、`store_fifo`、`store_buffer_count`、`older_store_pending`、`store_authorized`、`ready_cycle`、`rc`，优先只打印到 `.log`，不作为 `ob_cosim_if` 核心信号。

### 5.7 Trap 当前阶段处理范围

当前阶段 COSIM 不单独追踪 `trap_valid/trap_epc/trap_cause/trap_target_pc`，也不把 `mepc` / `mcause` 作为 trap 必抓信号。

理由是当前比较主路径为 commit PC 序列和完整 INT ARF/FP ARF 快照。trap 指令 PC 可以先按普通 commit PC 处理；如果 trap 处理错误导致 handler PC、`mret` 返回 PC 或 ARF 状态不一致，后续普通 PC/ARF 比较会暴露问题。

这条结论只限定当前阶段。未来如果要做异常精确校验或 trap handler 诊断增强，再重新引入独立 trap 事件和相关 CSR。

## 6. 正式 RTL 接入与 observation 解耦方案

### 6.1 当前缺口

当前 `tb` 环境已经具备 Commit PC/order、INT ARF/FP ARF snapshot、MEM store commit 和基础 COSIM 日志能力。后续需要继续收敛的是结构边界：让 `rtl_v1_wrapper` 只承担功能适配和 observation 映射，不让 `be_agent`、COSIM checker 或 DPI adapter 持有任何正式 RTL 私有层级路径。

需要补齐和稳定的内容如下：

- 把分散在 wrapper 里的 RTL 私有层级读取集中成 `rtl_v1_obs source/probe`。
- `rtl_v1_obs source/probe` 输出一组稳定的 observation bundle，再由 wrapper 映射到 `ob_if` 和 `ob_cosim_if`。
- 从 INT ARF/FP ARF 直连完整架构寄存器快照，并明确采样点是本周期提交写入后的状态。
- 定义 CSR 观察面，具体 CSR 列表后续按 ISA case 覆盖范围冻结。
- 将精简后的 MEM 观察信息从 `cache_agent` 汇入 `be_agent` / COSIM 观察链路，其中 store commit 是核心抓取面，load done 和 MEM exception 主要作为诊断信息。
- 将 `cycle` 和 `sequence_id` 保持在 COSIM 侧生成，不写入 `ob_cosim_if` 抓取信号清单。

### 6.2 observation 层的位置

新增 observation 的位置在 `backend_top` 附近，而不是在 `be_agent` 或 COSIM checker 内部。它的任务是把正式 RTL 的实现细节收束成稳定观察源：

```text
rtl_v1_wrapper
  |
  +-- backend_top u_backend
  |     |
  |     +-- 顶层观察端口：alloc_valid/alloc_tag/exec_valid/commit_valid/...
  |     |
  |     +-- 内部观察源：instruction payload、ARF snapshot、CSR snapshot、
  |                     recovery origin tag 等
  |
  +-- rtl_v1_obs source/probe
  |     |
  |     +-- 输出稳定 observation bundle
  |
  +-- observation mapper
        |
        +-- ob_if
        +-- ob_cosim_if
```

`rtl_v1_obs source/probe` 可以有两种实现形态：

1. **短期 probe 形态**：代码归验证环境所有，通过 wrapper 层级路径或 bind 读取 `backend_top` 内部信号，并集中维护这些路径。
2. **长期 observation port 形态**：如果 RTL owner 接受，在 `backend_top` 或子模块上增加仿真专用 observation port；wrapper 只负责把这些端口接到 `ob_if/ob_cosim_if`。

两种形态对 `be_agent` 和 COSIM checker 应完全等价。差别只在 observation source 如何从正式 RTL 取数。

### 6.3 收敛后的目标图

目标不是删除 wrapper，而是让 wrapper 变薄。收敛后的结构如下：

```text
                              功能路径

fe_agent -------------------> orbe_fe_if --------------------+
                                                             |
cache_agent ----------------> or_be_lsu_if ------------------+
                                                             |
                                                             v
                                                    +----------------+
                                                    | rtl_v1_wrapper |
                                                    |                |
                                                    |  +----------+  |
                                                    |  |backend_top| |
                                                    |  +----|-----+  |
                                                    |       |        |
                                                    |       v        |
                                                    | rtl_v1_obs     |
                                                    | source/probe   |
                                                    |       |        |
                                                    |       v        |
                                                    | map_to_ob_*    |
                                                    +-------|--------+
                                                            |
                                                            v
                                                    ob_if / ob_cosim_if
                                                            |
                                                            v
                                                         be_agent
                                                            |
                                                            v
                                                   COSIM adapter/checker
                                                            |
                                                            v
                                                   独立 ISA reference

cache_agent -- MEM store commit observation -----------------^
```

这张图里只有一个正式 DUT：`rtl_v1/backend_top`。`rtl_v1_wrapper` 是 DUT 和验证环境之间的隔离层；`rtl_v1_obs source/probe` 是 RTL-near observation source；`ob_if/ob_cosim_if` 是环境统一观察接口；`be_agent` 是统一观察接口的消费者。

### 6.4 rtl_v1_wrapper 的目标边界

接入正式 RTL 时保留 `tb/top/rtl_v1_wrapper.sv`，不要把 `backend_top` 直接散接在 `be_tb_top.sv` 里。wrapper 是正式 RTL 和验证环境之间唯一允许持有 RTL 私有类型、临时 observation 绑定和采样时序适配的模块。

建议 wrapper 边界保持下面形态：

```text
module rtl_v1_wrapper (
  input  logic clk,
  input  logic rst_n,
  orbe_fe_if       fe,
  or_be_lsu_if     lsu,
  ob_if            ob,
  ob_cosim_if      ob_cosim
);
```

职责拆分如下：

1. 实例化 `rtl/rtl_v1/top/backend_top.sv`。
2. 把环境 `orbe_fe_if` 转成 `backend_top` 的离散 FE 端口。
3. 把 `backend_top` 的 LSU 端口接到当前 `or_be_lsu_if` / `cache_agent`。
4. 实例化或绑定 `rtl_v1_obs source/probe`。
5. 把 observation bundle 映射到 `ob_if` v2 生命周期观察面和 `ob_cosim_if` COSIM 观察面。
6. 放置 wrapper 侧断言，检查通道前缀、X/Z、ARF x0、commit count、recovery 边界等绑定错误。

第一阶段中断输入 `mip_meip/mip_mtip/mip_msip` 可以全部 tie 0，只跑不依赖外部中断投递的 ISA case。后续要覆盖中断时，再增加 interrupt agent 或平台 interrupt source，不应由 COSIM checker 伪造。

### 6.5 FE/LSU 端口适配

`backend_top` 的 FE 端口使用 `fe_be_protocol_pkg::fe_be_instr_pld_t`，当前环境 `orbe_fe_if` 使用 `orbe_fe_types_pkg::orbe_fe_instr_pld_t`。字段语义一致但类型不同，wrapper 应逐字段搬运，避免包类型直接泄漏到 agent：

| wrapper 方向 | 连接 |
| --- | --- |
| FE valid | `backend_top.fe_valid = fe.fe_be_instr_valid` |
| FE payload | `pc/inst_bits/is_compressed/pred_taken/pred_target_pc/fetch_excp_*` 逐字段从 `orbe_fe_if` 转到 `fe_be_instr_pld_t` |
| FE ready | `fe.be_fe_instr_ready = backend_top.fe_ready` |
| Redirect valid/pc | `fe.be_fe_redirect_valid = backend_top.redirect_valid`，`fe.be_fe_redirect_pld.redirect_pc = backend_top.redirect_pc` |
| Redirect kind | `RECOVERY_INTERRUPT` 映射到 `interrupt_valid`；`RECOVERY_EXCEPTION/MRET/SRET` 映射到 `trap_valid`。`RECOVERY_MISPREDICT/FENCE_I` 第一阶段可仅通过 `redirect_pc` 被 FE 使用，后续若 FE 需要区分 kind，应扩展 `orbe_fe_if`。 |

`backend_top` 的 LSU 端口和当前 `or_be_lsu_if` payload 包基本同源，wrapper 只做离散端口到 interface 字段的搬运：

| wrapper 方向 | 连接 |
| --- | --- |
| BE issue | `lsu.be_lsu_issue_valid/pld = backend_top.be_lsu_issue_valid/pld` |
| Store wakeup | `lsu.be_lsu_store_wakeup_valid = backend_top.be_lsu_store_wakeup_valid`，若环境接口后续增加 tag，也应接 `backend_top.be_lsu_store_wakeup_tag` |
| Flush to cache | `lsu.global_flush_late = backend_top.global_flush` |
| LSU ready/result | `backend_top.lsu_be_issue_ready/writeback/bypass = lsu.lsu_be_*` |
| Response accept compatibility | 当前 `cache_agent` 需要 `lsu.be_lsu_entry_ready`；正式 `backend_top` 对 writeback 没有 ready 反压，wrapper 可在第一版驱动为 `rst_n && !backend_top.global_flush`，并用断言确认 terminal response 不在 flush 周期被消费。 |

### 6.6 observation bundle 到 ob_cosim_if

`ob_cosim_if` 的正式 RTL 来源如下：

| `ob_cosim_if` 字段 | observation 来源 |
| --- | --- |
| `commit_valid[group]` | `backend_top.commit_valid[group]` 的 observation 副本 |
| `commit_pc[group]` | `backend_top.trace_pc[group]` 的 observation 副本 |
| `commit_rob_idx[group]` | zero-extend `backend_top.commit_tag[group]` |
| `int_arf[index]` | `rtl_v1_obs source/probe` 导出的 INT ARF snapshot |
| `fp_arf[index]` | `rtl_v1_obs source/probe` 导出的 FP ARF snapshot |
| `csr_*` | 第一阶段置无效；CSR 列表冻结后由 `rtl_v1_obs source/probe` 导出 |
| `mem_store_commit_*` | `cache_agent` 的 store commit observation |

ARF snapshot 必须是所有本周期提交写入后的架构状态。当前 BE/COSIM 采样在 negedge，因此 wrapper 侧应提供 posedge commit 之后稳定的 snapshot；不能用 INT/FP ARF 当前读口根据临时 read address 拼快照。

### 6.7 observation bundle 到 ob_if v2

当前 `be_agent` 不只是 COSIM sampler，它还负责共享 ISA model 的 BE 生命周期。因此 `ob_if` 应作为 BE lifecycle observation interface 保留一段时间；它和 `ob_cosim_if` 暂时不必须合并。

命名原则如下：

1. `backend_top` 已经公开、且语义正好就是观察事件的信号，在 `ob_if` 中尽量同名，例如 `alloc_valid`、`alloc_tag`、`exec_valid`、`exec_tag`、`commit_valid`、`commit_tag`、`commit_count`、`redirect_valid`、`redirect_pc`、`redirect_kind`、`global_flush`。
2. RTL 内部层级名不直接进入 `ob_if`。例如 `head_IB_Payload`、`scb_flush_tag`、`entry_arf` 这类名字只允许出现在 `rtl_v1_obs source/probe` 的绑定实现或绑定表里。
3. `trace_pc` 在 `backend_top` 顶层是公开端口，但进入 `ob_if` 后建议命名为 `commit_pc`。原因是 `be_agent` 消费的是提交 PC 语义，不应该把 PC_File 的实现命名扩散到 agent。
4. `recovery_kind` / `redirect_kind` 的编码应与 `rtl_v1` 的 `RECOVERY_*` 保持一致。验证环境可以在自己的 observation package 中定义同值 enum，由 `rtl_v1_wrapper` 做显式 cast/断言。

推荐 `ob_if` v2 字段如下：

| `ob_if` v2 字段 | observation 来源 | 说明 |
| --- | --- | --- |
| `alloc_valid[group]` | `backend_top.alloc_valid[group]` | 进入共享模型的 decode/issue 锚点。 |
| `alloc_tag[group]` | zero-extend `backend_top.alloc_tag[group]` | 正式 RTL tag 是 4-bit ROB slot/tag，环境可扩成统一 ROB index width。 |
| `alloc_pld[group].pc` | alloc 同拍 instruction payload | `backend_top` 当前未公开，短期由 observation source 读取同源内部网。 |
| `alloc_pld[group].inst_bits` | alloc 同拍 raw instruction | 必须是 FE 送入的 raw 编码，压缩指令高 16 bit 补 0。 |
| `alloc_pld[group].is_compressed` | alloc 同拍 instruction payload | 与 `inst_bits` 同源。 |
| `alloc_pld[group].fetch_excp_*` | alloc 同拍 instruction payload | fetch exception 需要随 alloc 进入共享模型。 |
| `exec_valid[source]` | `backend_top.exec_valid[source]` | 4 条 completion source。 |
| `exec_tag[source]` | zero-extend `backend_top.exec_tag[source]` | 共享模型执行完成锚点。 |
| `commit_valid[group]` | `backend_top.commit_valid[group]` | 与 `ob_cosim_if.commit_valid` 同源。 |
| `commit_tag[group]` | zero-extend `backend_top.commit_tag[group]` | 与 `ob_cosim_if.commit_rob_idx` 同源。 |
| `commit_pc[group]` | `backend_top.trace_pc[group]` | 提交 PC 语义，字段名不沿用 PC_File 的 `trace_pc`。 |
| `commit_count` | `backend_top.commit_count` | 表达本周期真实 retired 数量，供 recovery 后的 squash 边界计算和断言。 |
| `recovery_valid` | `backend_top.global_flush` 或 `redirect_valid` | 表达本周期发生恢复/flush 决策。 |
| `recovery_kind` | `backend_top.redirect_kind` | 编码与 `rtl_v1` 的 `RECOVERY_*` 保持一致。 |
| `recovery_origin_tag` | `scb_flush_tag` 或等价源 | RTL 恢复来源 tag，用于日志和恢复类型诊断。 |
| `recovery_squash_tag` | wrapper 根据 `commit_count` / `recovery_kind` / `recovery_origin_tag` 计算 | 共享 ISA model `flush(core, rob_idx)` 应使用的第一条被 squash 的 ROB tag。 |
| `recovery_redirect_pc` | `backend_top.redirect_pc` | 与 FE 看到的 redirect PC 同源。 |

这里最关键的是 alloc payload 和 recovery 边界。正式 `backend_top` 目前公开 `alloc_valid/alloc_tag`，但没有公开 `alloc_pc/alloc_inst_bits/is_compressed/fetch_excp_*`；这部分短期由 observation source 读取同源内部网。recovery 侧不能只保留 `flush_all/pflush/pflush_rob_idx`，因为 `rtl_v1` 的 `CompletionScoreboard` 明确定义了 commit-then-flush 语义。

`be_agent` 的处理顺序应保持为：

1. 采样并发布 `ob_cosim_if` 的 commit/mem 观察。
2. 处理本周期 `commit_valid`，按第 0 组、第 1 组顺序调用共享模型 commit。
3. 再处理 `recovery_valid`。对已在本周期 retired 的指令，不再被 recovery 取消；共享模型 flush 使用 `recovery_squash_tag`。
4. 对 `RECOVERY_EXCEPTION/RECOVERY_INTERRUPT` 这类没有普通 commit 的恢复，需要由 recovery handler 负责调用对应 trap/interrupt 模型 API，再清理 speculative window。

这样正式 FE/LSU 看到的 `redirect_valid/global_flush` 保持 RTL 原始时序。wrapper 只延迟 observation 副本来匹配 BE/COSIM 采样点，不改变功能路径时序。

### 6.8 构建、仿真和日志入口

正式 RTL 路径的构建入口应显式选择 `rtl_v1`，并保证 filelist、宏和缓存 key 都与该路径一致：

```text
DUT_KIND=rtl_v1
  编译 rtl/rtl_v1/*
  编译 tb/top/rtl_v1_wrapper.sv
  编译 rtl_v1 observation source/probe
  在 be_tb_top 中实例化 rtl_v1_wrapper
```

filelist 需要处理好包的编译顺序和去重：

1. `exe_subop_pkg.sv` 和 `or_be_lsu_protocol_pkg.sv` 是 RTL/TB 共享协议包，应放在 RTL 包之前编译。
2. `rtl/rtl_v1/pkg/or_be_config_pkg.sv`、`or_be_types_pkg.sv`、`fe_be_protocol_pkg.sv`、`or_be_types_check.sv` 应早于 `backend_top.sv` 和各子模块。
3. `rtl_v1_wrapper.sv` 和 observation source/probe 应在正式 RTL package 和 interface package 都可见之后编译。
4. `VCS_CACHE_KEY` 应包含 `DUT_KIND`，避免不同 RTL 编译配置复用不兼容的仿真缓存。

VCS 推荐命令形态：

```bash
make -C verification/orbe_bt_env/sim \
  build DUT_KIND=rtl_v1 TOP=be_tb_top

make -C verification/orbe_bt_env/sim \
  run DUT_KIND=rtl_v1 TOP=be_tb_top COSIM_ENABLE=1 \
  TC=$ISA_MODEL_ROOT/isa_case/rv64ui/rv64ui-p-add.riscv \
  SIM_TIMEOUT=2000000
```

无 VCS 环境下使用 Verilator debug 入口：

```bash
cd verification

orbe_bt_env/tools/verilator_cosim.sh build --dut-kind rtl_v1

orbe_bt_env/tools/verilator_cosim.sh run --dut-kind rtl_v1 --no-build \
  --tc "$ISA_MODEL_ROOT/isa_case/rv64ui/rv64ui-p-add.riscv" \
  --timeout 200000 \
  --verbosity 3
```

Verilator 默认日志目录：

```text
orbe_bt_env/sim/verilator_<TAG>/log/rtl_v1/<elf-name>_<SEED>/
```

### 6.9 rtl_v1 bring-up 顺序

建议按以下阶段推进，不要第一步就跑完整 ISA regression：

1. **编译和 reset smoke**：`DUT_KIND=rtl_v1` 编译通过，reset 后 FE ready、LSU ready、redirect、global_flush 无 X/Z。
2. **FE/LSU 基础流**：`COSIM_ENABLE=0` 跑最小 rv64ui case，确认 FE 输入能进入 `backend_top`，LSU 请求能被 `cache_agent` 接收并返回。
3. **共享模型生命周期**：确认 `ob_if` 的 alloc、exec、commit、flush 能让 `be_agent` 正确调用 decode/execute/commit/flush DPI，不出现 unallocated commit、duplicate execute、stale tag 等错误。
4. **COSIM commit PC**：打开 `COSIM_ENABLE=1`，先看 commit PC/order 是否和独立 reference 对齐。
5. **INT/FP ARF snapshot**：接通正式 `INT_ARF/FP_ARF` snapshot，运行 rv64ui/rv64um/rv64uf/rv64ud 单例，定位首个架构寄存器 mismatch。
6. **MEM store commit**：确认 `cache_agent` 的 `mem_store_commit_*` 与 commit PC/tag 能匹配，tohost terminal store 不导致独立 reference 少 step 或多 step。
7. **CSR 和 trap 扩展**：CSR 列表冻结后打开 `csr_valid`；异常精确比较仍按后续需求决定是否增加独立 trap event。
8. **ISA regression**：最后运行完整 ISA case 集合，并把失败按 PC mismatch、ARF mismatch、CSR mismatch、MEM ordering、timeout 分类。

## 7. ORBE 需要补充的 be_agent / COSIM 连接

### 7.1 be_agent 的角色

`be_agent` 应从 `ob_cosim_if` 读取 COSIM 观察信息，并负责把 Commit、ARF、CSR、MEM 观察面整理成 COSIM 可消费的数据。COSIM checker 不应直接读取正式 RTL 层级路径。

`be_agent` 不应把 `cycle` / `sequence_id` 当成从环境抓出来的信号。这两个字段应由 COSIM adapter/checker 在消费 commit event 时生成。

### 7.2 MEM 信息接入

MEM 相关信号也需要进入 `be_agent`，源头来自 `cache_agent`。这部分应先和 `ORBE_BT_ENV_debug_and_print.md` 中定义的 cache log 字段对齐，再决定哪些字段进入 `ob_cosim_if`。进入 `ob_cosim_if` 的核心 MEM 字段应以 store commit 为主，cache 内部队列、等待和授权状态优先保留在 `.log`。

建议优先按下面路径推进：

1. 先让 `cache_agent` 把 issue / execute / memory / commit / flush 四条主线稳定打印成 `.log`。
2. 再把同类字段接入 `ob_cosim_if`。
3. 最后由 `be_agent` 和 COSIM 相关模块读取、排序和比较。

## 8. ORBE COSIM 的边界和判断标准

### 8.1 当前阶段成功标准

当前阶段的目标是定义观察面并打通基础设施，而不是证明真实 ORBE RTL 功能正确性。

成功标准如下：

- `ob_cosim_if` 的职责边界清晰，字段分为 Commit、INT ARF、FP ARF、CSR、MEM 五类。
- 第 0/1 组通道命名清晰，不再在 ORBE 语境中使用 `lane` 作为主术语。
- `cycle` 和 `sequence_id` 明确由 COSIM 侧生成，不属于 `ob_cosim_if` 抓取信号。
- debug print 和 `.log` 信息集合先被冻结，正常运行事件和错误事件都能稳定记录。
- 正式 RTL 路径可以通过 `rtl_v1_wrapper` 接入 `ob_if/ob_cosim_if`，并在 `COSIM_ENABLE=1` 时产出可定位的 PASS/FAIL 日志。

### 8.2 后续完整环境成功标准

后续完整 COSIM 环境应满足：

- `rtl_v1_wrapper` 是真实 RTL 层级路径和 RTL 私有类型的唯一持有者；`be_agent`、COSIM adapter、`cosim_agent` 不直接访问 `backend_top` 层级。
- `DUT_KIND=rtl_v1` 的 VCS/Verilator 入口稳定，filelist、compile define 和仿真缓存 key 与正式 RTL 路径一致。
- `rtl_v1_wrapper` 能同时驱动 `ob_if` v2 生命周期观察面和 `ob_cosim_if` COSIM 观察面，两者的 commit PC/tag 同源。
- Commit PC 序列按第 0/1 组通道顺序与独立 reference 对齐。
- 完整 INT ARF / FP ARF 快照与独立 reference 的架构寄存器状态一致。
- CSR 观察面按 ISA case 覆盖范围冻结，并能支持 CSR 指令相关状态比较或诊断。
- MEM 观察面核心覆盖 store commit，并能与 `cache_agent` 日志对齐；load done 和 MEM exception 作为诊断信息保留，cache 内部管理状态只进 `.log`。
- 当前阶段不要求独立 trap/mcause 比较；trap PC 先走普通 commit PC 路径。
- 完整 COSIM 环境运行 216 条 ISA_case 应全部通过。
- COSIM 代码不包含正式 RTL、BETA/P600 层级路径或 BETA 专用类型；正式 RTL 私有层级路径只允许集中在 `rtl_v1_obs source/probe`。

## 9. 总结：后续实现计划

1. **统一接口命名**：ORBE COSIM 观察接口统一为 `ob_cosim_if`，BETA 参考章节保留原始命名。
2. **统一通道命名**：ORBE 语境中将 `lane` 改为第 0 组通道 / 第 1 组通道。
3. **区分信号来源**：从 RTL/环境抓取的信号放在 `ob_cosim_if`；`cycle`、`sequence_id` 由 COSIM 侧生成。
4. **先冻结 debug print**：参考 `ORBE_BT_ENV_debug_and_print.md`，先确定普通运行事件和错误事件需要打印哪些字段。
5. **新增信号抓取 plan**：按 Commit / INT ARF / FP ARF / CSR / MEM 分类列出需要抓取的信号。
6. **补充 INT ARF/FP ARF 直连观察**：以 64 x 64 bit 的完整快照作为核心架构状态比较依据，当前不抓 `int_arf_valid/fp_arf_valid`。
7. **弱化 `rd/rd_valid`**：不再作为核心必抓信号，只作为后续可选诊断字段。
8. **补充 CSR 观察面**：具体 CSR 列表按 ISA case 覆盖范围冻结，当前不把 `mepc/mcause` 作为 trap 必抓信号。
9. **补充 MEM 观察面**：MEM 信号源头来自 `cache_agent`，核心抓取 store commit 事件，load done/MEM exception 作为诊断信息，cache 内部状态只进 `.log`。
10. **当前阶段不单独追踪 trap**：trap PC 先按普通 commit PC 处理，独立 trap 事件后续按异常诊断需求再加。
11. **新增 `rtl_v1_wrapper`**：真实 RTL 路径先经过 wrapper，wrapper 内部实例化 `rtl_v1/backend_top`，并统一连接 FE/LSU、`ob_if` 和 `ob_cosim_if`。
12. **冻结真实 RTL 观察来源**：commit 使用 `backend_top.commit_valid/trace_pc/commit_tag`；ARF 使用 `INT_ARF/FP_ARF` snapshot；CSR 第一阶段置无效；MEM store commit 继续来自 `cache_agent`。
13. **处理 commit+recovery 顺序**：实现前固定同周期 commit+flush 的处理策略，`be_agent` 先消费 commit，再按 `recovery_squash_tag` 处理 recovery，避免丢失分支、fence 或第二通道前序提交。
14. **稳定正式 RTL 构建入口**：通过 `DUT_KIND=rtl_v1`、`cfg/filelist/rtl_v1.f` 和独立 filelist/cache key 固定正式 RTL 的 VCS/Verilator 入口。
