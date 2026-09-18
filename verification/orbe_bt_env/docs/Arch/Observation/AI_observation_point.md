# ORBE AI observation point：Level-1 / Level-2

## 1. 目的与分级边界

本文将 OR-BE 的 observation point 改成按重要性分级，而不是按
Commit / ARF / CSR / MEM 等功能分组。

| 等级 | 定义 | 使用目标 |
| --- | --- | --- |
| Level-1 | P4 Commit 端可以直接取得的提交事件、提交 payload，以及解释该提交事件所需的同拍上下文。 | COSIM 的架构提交序列、提交结果和提交顺序校验。 |
| Level-2 | 不能在 Commit 端直接取得，但在该指令到达 Commit 之前已经出现过的有效事件、payload 或状态。 | 依赖、发射、执行、写回、旁路、LSU、CSR 和 recovery 的定位与诊断。 |

本文中的“提取”统一遵循：

1. **能打印就打印**：只要信号在 RTL、wrapper、bind probe 或验证环境边界上有明确来源，就保留为 observation point。
2. Event 必须连同完整 payload 一起打印；payload 的语义只在该 Event 的 valid/fire 有效时成立。
3. Static Info 可以连续打印；如果只在某个 stage 有意义，打印时带上对应 stage 的 valid/occupied 条件。
4. 不把 `valid=0` 时的占位字段当作架构信息。特别是 `commit_rd_idx`、`commit_data` 和 `trace_pc` 未必由 valid 自动门控，消费方必须先看对应的 `commit_valid[k]`。
5. 同周期两个提交组的消费顺序固定为 group 0 先于 group 1。`commit_valid[1]` 只能在 `commit_valid[0]` 有效时有效。

### 1.1 统一命名

本文使用后端 observation 语义命名：

- `group`：提交/分配的两个顺序组，`k∈{0,1}`。
- `lane`：四个完成来源，`g∈{0,1,2,3}`。
- `tag`：ROB/Buffer/PC_File 的 `TAG_W` 位 entry 标识。
- `commit_data[k]`：Buffer 按 Commit head tag 读出的结果数据。
- `trace_pc[k]`：PC_File 按 Commit head tag 读出的指令 PC。
- `exec_*`：P3 或 LSU 向 P4 交付的完成/写回事件；模块内部原名可能是 `writeback_*` 或 `Result_*`。

## 2. Level-1：Commit 端完整提交接口

### 2.1 Level-1 结论

Level-1 的核心接口是一个按 group 编号排列的 architectural commit packet：

```text
commit_valid[k]
commit_tag[k]
commit_rd_idx[k]
commit_rd_is_fp[k]
commit_rd_write_enable[k]
commit_fflags[k]
commit_data[k]
trace_pc[k]
```

`commit_count` 是这个 packet 的批量提交计数。以上字段均应在有效提交拍完整打印。

其中 `commit_data` 不是 CompletionScoreboard 自己产生的字段，而是
`Buffer` 的提交读口；`trace_pc` 不是 CompletionScoreboard entry payload，
而是 `PC_File` 的提交 trace 读口。两者都属于 Level-1，不能因为它们来自
不同模块就丢掉。

### 2.2 Level-1 核心提交 packet

| 观察信号 | 形态 | 直接来源 | 语义 | 打印要求 |
| --- | --- | --- | --- | --- |
| `commit_valid[k]` | 1 bit × 2 | `CompletionScoreboard.commit_valid[k]` | group `k` 本拍是否发生合法 architectural commit | 每拍打印；为 1 时打印完整 group `k` payload |
| `commit_tag[k]` | `TAG_W` × 2 | `CompletionScoreboard.commit_tag[k]` | 本拍提交的 Buffer/ROB entry tag；invalid lane 输出占位 0 | 只有 `commit_valid[k]=1` 时作为有效 tag |
| `commit_rd_idx[k]` | `REG_ADDR_W` × 2 | `CompletionScoreboard.commit_rd_idx[k]` | 提交 entry 的架构目的寄存器编号 | 与 `commit_valid[k]` 同拍打印 |
| `commit_rd_is_fp[k]` | 1 bit × 2 | `CompletionScoreboard.commit_rd_is_fp[k]` | 目的寄存器属于 FP register file 的标志 | 与 `commit_valid[k]` 同拍打印 |
| `commit_rd_write_enable[k]` | 1 bit × 2 | `CompletionScoreboard.commit_rd_write_enable[k]` | 本提交是否产生目的寄存器写入 | 与 `commit_valid[k]` 同拍打印 |
| `commit_fflags[k]` | `FFLAGS_W` × 2 | `CompletionScoreboard.commit_fflags[k]` | 该 entry 在执行阶段保存的 FP flags | 即使值为 0 也打印 |
| `commit_data[k]` | `XLEN` × 2 | `Buffer.commit_data[k]` | 提交 entry 对应的结果数据；用于 INT/FP ARF 写回 | 与 `commit_valid[k]` 同拍打印 |
| `trace_pc[k]` | `XLEN` × 2 | `PC_File.trace_pc[k]` | 提交 entry 对应的指令 PC；旧 `ob_cosim_if` 名称为 `commit_pc[k]` | 与 `commit_valid[k]` 同拍打印 |
| `commit_count` | `COMMIT_COUNT_W` | `CompletionScoreboard.commit_count` | 本拍提交 0、1 或 2 条指令，等于两个 `commit_valid` 之和 | 每拍打印，并用于顺序检查 |

### 2.3 Level-1 的 Commit 控制与恢复接口

下面这些信号也是 `CompletionScoreboard` 的直接输出。它们不是普通
architectural commit packet 的字段，但仍然属于 Commit 端能直接提取的
Level-1 接口，尤其用于 store ordering、flush 和 recovery。

| 观察信号 | 形态 | 直接来源 | 语义 |
| --- | --- | --- | --- |
| `store_wakeup_valid` | 1 bit | `CompletionScoreboard.store_wakeup_valid` | 本拍是否向 LSU 授权一个 plain store |
| `store_wakeup_tag` | `TAG_W` | `CompletionScoreboard.store_wakeup_tag` | 获得 store 授权的 entry tag |
| `head0_tag` | `TAG_W` | `CompletionScoreboard.head0_tag` | group 0 的 Commit/Buffer/PC_File 读地址 |
| `head1_tag` | `TAG_W` | `CompletionScoreboard.head1_tag` | group 1 的 Commit/Buffer/PC_File 读地址 |
| `flush_valid` | 1 bit | `CompletionScoreboard.flush_valid` | 本拍是否决定回滚未提交 entry |
| `flush_tag` | `TAG_W` | `CompletionScoreboard.flush_tag` | 第一条被 squash 的 entry tag |
| `recovery_kind` | `RECOVERY_KIND_W` | `CompletionScoreboard.recovery_kind` | exception / interrupt / MRET / SRET / FENCE.I / mispredict |
| `recovery_mispredict_target_pc` | `XLEN` | `CompletionScoreboard.recovery_mispredict_target_pc` | mispredict recovery target |
| `recovery_exception_cause` | `EXCP_CAUSE_W` | `CompletionScoreboard.recovery_exception_cause` | recovery exception cause |
| `recovery_exception_tval` | `XLEN` | `CompletionScoreboard.recovery_exception_tval` | recovery exception tval |
| `st_br_resolve` | 1 bit | `CompletionScoreboard.st_br_resolve` | 当前 Group 3 entry 的 store/branch 顺序解析状态 |
| `scoreboard_valid_bits` | `ROB_DEPTH` bit | `CompletionScoreboard.scoreboard_valid_bits` | live window 的 tag 占用投影 |
| `scoreboard_exec_done_bits` | `ROB_DEPTH` bit | `CompletionScoreboard.scoreboard_exec_done_bits` | 每个 tag 是否已收到完成 |
| `Buffer_tail` | `TAG_W` | `CompletionScoreboard.Buffer_tail` | Buffer/ROB 下一分配位置的 tag 投影 |
| `can_alloc_1` | 1 bit | `CompletionScoreboard.can_alloc_1` | 当前至少能接收 1 条 |
| `can_alloc_2` | 1 bit | `CompletionScoreboard.can_alloc_2` | 当前至少能接收 2 条 |
| `buffer_empty` | 1 bit | `CompletionScoreboard.buffer_empty` | 当前 live window 是否为空 |

#### flush_model 的直接派生接口

`flush_model` 直接消费上表的 `flush_valid/flush_tag/recovery_kind`，并把
Commit 端的 recovery 决策变成后端到前端的控制事件。它们不属于普通
commit packet，但仍是同一 Commit recovery 边界的 Level-1 派生接口：

| 观察信号 | 形态 | 直接来源 | 语义 |
| --- | --- | --- | --- |
| `global_flush_late` / `global_flush_valid` | 1 bit | `flush_model.global_flush_late`；`backend_top.global_flush_valid` 是同源别名 | 后端 late flush 广播 |
| `inst_pc` | `XLEN` | `PC_File.inst_pc`，按 `flush_tag` 组合读出 | recovery entry PC；用于 trap EPC 和 FENCE.I next-PC 计算 |
| `redirect_valid` | 1 bit | `flush_model.redirect_valid` | 前端 redirect event |
| `redirect_pc` | `XLEN` | `flush_model.redirect_pc` | redirect target |
| `redirect_kind` | `RECOVERY_KIND_W` | `flush_model.redirect_kind` | redirect 类型 |
| `frontend_icache_invalidate` | 1 bit | `flush_model.frontend_icache_invalidate` | FENCE.I 的 I-cache invalidate |
| `trap_state_write.valid` | 1 bit | `flush_model.trap_state_write.valid` | 是否更新 trap state |
| `trap_state_write.kind` | `RECOVERY_KIND_W` | `flush_model.trap_state_write.kind` | trap/return 类型 |
| `trap_state_write.epc` | `XLEN` | `flush_model.trap_state_write.epc` | trap EPC |
| `trap_state_write.cause` | `EXCP_CAUSE_W` | `flush_model.trap_state_write.cause` | trap cause |
| `trap_state_write.tval` | `XLEN` | `flush_model.trap_state_write.tval` | trap tval |
| `cause` | `EXCP_CAUSE_W` | `flush_model.cause` | flush_model 选择后的 cause |
| `is_interrupt` | 1 bit | `flush_model.is_interrupt` | 当前 recovery 是否为 interrupt |

这些信号与普通 Commit event 处在同一个 recovery 决策边界，打印时要保留
`commit_valid/commit_count` 和 `flush_valid` 的同拍关系：先消费合法提交，
再处理被 squash 的后继 entry。

### 2.4 Level-1 的同拍解释上下文

`head0_tag/head1_tag`、`scoreboard_valid_bits`、
`scoreboard_exec_done_bits`、`Buffer_tail`、`buffer_empty`、
`can_alloc_1` 和 `can_alloc_2` 都属于 Commit 侧同一组 P4 状态。
它们已在 2.3 的 Level-1 控制与恢复接口中完整列出；本节只明确消费
边界，不重复定义第二套接口：

- `head0_tag/head1_tag` 是 Buffer、PC_File 两个 Commit 读口的地址；
- `scoreboard_valid_bits`、`scoreboard_exec_done_bits` 是 Commit 前
  live window 的状态投影；
- `Buffer_tail`、`buffer_empty`、`can_alloc_1`、`can_alloc_2` 用于
  解释分配边界、serial 准入和双发能力；
- 它们可以连续打印，但不能替代 `commit_valid[k]` 和对应 packet。

这些上下文只在实际能从 `backend_top` 内部 probe 到时接出；无法作为稳定
产品端口时，可以先进入 debug log，不应伪造为新的 architectural commit
payload。

### 2.5 Buffer 和 PC_File 对 Level-1 的硬约束

#### Buffer

`Buffer` 是 `ROB_DEPTH` 个 `XLEN` 结果 entry 的存储：

```text
writeback/exec event:
    tag_out[g] + result_data[g]
        -> entry_result_data[tag_out[g]]

Commit read:
    head0_tag -> commit_data[0]
    head1_tag -> commit_data[1]
```

因此 Level-1 必须保留：

- `commit_data[0]`、`commit_data[1]`；
- 产生该数据的 `commit_tag[0]`、`commit_tag[1]`；
- 不能只打印 `commit_valid` 和 PC；
- 不能用当前 FU 的 `result_data` 代替 `commit_data`，因为 FU 写回与
  architectural commit 之间可能隔着多个周期。

#### PC_File

`PC_File` 在 alloc 时按 `self_tag` 保存 `pc`，在 Commit 按 head tag 组合读出
`trace_pc[k]`，同时还提供 recovery 使用的 `inst_pc`。因此：

- `trace_pc[k]` 是 Level-1；
- `inst_pc` 是 Level-1 recovery 上下文；
- alloc 侧必须至少保留 `alloc_tag/self_tag` 和 `alloc_pc`，才能追溯
  `trace_pc` 的来源。

参考文档：

- `openrios/work/or-be-draft/modules/modules_v4/p4/Buffer.md`
- `openrios/work/or-be-draft/modules/modules_v4/p4/PC_File.md`
- `openrios/work/or-be-draft/modules/modules_v4/p4/CompletionScoreboard.md`

### 2.6 Level-1 扩展：Commit 后可采样的架构状态

下面这些不是 Commit packet 字段，但它们可以在 Commit active edge 之后作为
架构状态采样。为了不丢失已有 COSIM 观察能力，仍归入 Level-1 扩展。

| 观察信号 | 形态 | 采样语义 | 备注 |
| --- | --- | --- | --- |
| `int_arf[0:31]` | 32 × `XLEN` | 本拍提交写入完成后的 INT 架构寄存器状态 | `x0` 必须为 0 |
| `fp_arf[0:31]` | 32 × `XLEN` | 本拍提交写入完成后的 FP 架构寄存器状态 | 在提交后的稳定采样点读取 |
| `csr_valid` | 1 bit | CSR snapshot 是否完整有效 | 不能用单条 CSR event 代替 |
| `csr_state_valid[i]` | 1 bit | CSR snapshot 表项 `i` 是否有效 | 与 `csr_state_addr/state` 成对使用 |
| `csr_state_addr[i]` | 12 bit | CSR snapshot 表项地址 | address-keyed snapshot |
| `csr_state[i]` | `XLEN` | CSR snapshot 表项值 | 只比较 `csr_state_valid[i]=1` 的项 |

`int_arf/fp_arf` 的采样点必须晚于 Commit 写回 active edge；否则会读到
pre-Commit 状态。它们是 Level-1 的架构状态扩展，不替代
`commit_data[k]`，也不替代逐条 `commit_valid[k]` 事件。

## 3. Level-2：Commit 之前的有效接口

Level-2 不按功能模块作为最终组织方式，而按流水生命周期排列。每一组
都应保留“事件 valid + 事件 payload + 必要的静态解释信号”。

### 3.1 P1 alloc / dispatch 结果

这是指令进入 Buffer/CompletionScoreboard 生命周期时的第一组有效信息。

#### Alloc event

| 观察信号 | 形态 | 语义 |
| --- | --- | --- |
| `alloc_valid[s]` | 1 bit × 2 | slot `s` 是否被后端正式接收 |
| `alloc_tag[s]` | `TAG_W` × 2 | 分配给 slot `s` 的 self tag |
| `alloc_pc[s]` | `XLEN` × 2 | 分配指令 PC，写入 PC_File |
| `alloc_inst_bits[s]` | 32 bit × 2 | 原始指令 bits |
| `alloc_is_compressed[s]` | 1 bit × 2 | 是否为 RVC 指令 |
| `alloc_pred_taken[s]` | 1 bit × 2 | FE 提供的预测 taken |
| `alloc_pred_target_pc[s]` | `XLEN` × 2 | FE 提供的预测目标 PC |
| `alloc_fetch_excp_vld[s]` | 1 bit × 2 | fetch exception 是否存在 |
| `alloc_fetch_excp_cause[s]` | `FETCH_EXCP_CAUSE_W` × 2 | fetch exception cause |
| `alloc_fetch_excp_tval[s]` | `XLEN` × 2 | fetch exception tval |

`alloc_valid[s]` 应与 `CompletionScoreboard.accept[s]`、`PC_File.accept[s]`
和对应的 IB/ISQ 接收保持同一生命周期。`alloc_tag` 与上述 payload 必须
成对打印。

#### Decode / CompletionScoreboard alloc header

这些字段在 Commit 时已经只剩下 `commit_rd_*` 的投影；为了定位
“为什么这条指令最终以某种方式提交或 flush”，Level-2 必须在 alloc/
dispatch 时打印：

| 观察信号 | 形态 | 语义 |
| --- | --- | --- |
| `alloc_rd_idx[s]` | `REG_ADDR_W` × 2 | decode 得出的目的寄存器 |
| `alloc_rd_is_fp[s]` | 1 bit × 2 | 目的寄存器类型 |
| `alloc_rd_write_enable[s]` | 1 bit × 2 | 目的寄存器写使能 |
| `alloc_is_store[s]` | 1 bit × 2 | 是否为 plain store |
| `alloc_is_fence_i[s]` | 1 bit × 2 | 是否为 FENCE.I |
| `alloc_may_flush[s]` | 1 bit × 2 | 是否可能在执行完成时产生 recovery |
| `alloc_is_atomic[s]` | 1 bit × 2 | 是否为 LR/SC/AMO |
| `is_serial[s]` | 1 bit × 2 | 是否为 serial/system instruction |
| `is_fp_instruction[s]` | 1 bit × 2 | 是否为 FP instruction，包含 FP load/store |
| `exe_subop[s]` | `EXE_SUBOP_W` × 2 | 执行子操作编码 |
| `full_decode[s]` | `full_decode_t` × 2 | illegal、rounding mode 等完整 decode 结果 |
| `rs1_idx[s]` / `rs2_idx[s]` / `rs3_idx[s]` | `REG_ADDR_W` | 三个源寄存器编号 |
| `rs1_is_fp[s]` / `rs2_is_fp[s]` / `rs3_is_fp[s]` | 1 bit | 三个源寄存器类型 |
| `use_rs1[s]` / `use_rs2[s]` / `use_rs3[s]` | 1 bit | 三个源操作数是否被使用 |

#### Dispatch decision

| 观察信号 | 形态 | 语义 |
| --- | --- | --- |
| `ib_dequeue[s]` | 1 bit × 2 | IB slot 是否出队 |
| `isq_wr_en[g]` | 1 bit × 4 | group `g` 是否写入 ISQ |
| `slot_FU_Group[s]` | `FU_GROUP_W` × 2 | slot 选择的 ISQ/FU group |
| `effective_rm[s]` | `rm_e` × 2 | 该指令实际采用的 rounding mode |
| `is_fence_i[s]` | 1 bit × 2 | dispatch 侧 FENCE.I 判定 |
| `may_flush[s]` | 1 bit × 2 | dispatch 侧 recovery 属性 |
| `is_atomic[s]` | 1 bit × 2 | dispatch 侧 atomic 属性 |
| `serial_set_valid` | 1 bit | 是否建立 serial tracker |
| `serial_set_tag` | `TAG_W` | serial tracker 记录的 tag |
| `select_payload[g][s]` | 1 bit × 4 × 2 | group `g` 选择 slot `s` 的 payload |

`accept[1] -> accept[0]`、`alloc_valid[1] -> alloc_valid[0]` 是必须打印并
检查的前缀约束；双发时两个 slot 还必须落到不同 ISQ group。

### 3.2 P1 dependency / source resolution

这是“源操作数从哪里来”的中间信息。它在 Commit 端无法重建，且对
missed wakeup、错误等待 tag 和错误旁路选择非常关键。

| 观察信号 | 形态 | 语义 |
| --- | --- | --- |
| `rsX_ready[s][x]` | 1 bit | slot `s` 的 source `x` 当前是否 ready |
| `rsX_wait_tag[s][x]` | `TAG_W` | source 未 ready 时等待的 producer tag |
| `rs_data_sel_t[s][x]` | enum/bitfield | source 数据选择：ARF、P3 bypass、Commit data 或 wait tag |
| `slot_missed_wakeup[s]` | 1 bit × 2 | 本拍是否出现错过旁路的风险 |
| `int_rename_tag[s][x]` | `TAG_W` | INT tag mapping 当前读出的 producer tag |
| `int_rename_busy[s][x]` | 1 bit | INT tag mapping 当前是否 busy |
| `fp_rename_tag[x]` | `TAG_W` | FP tag mapping 当前读出的 producer tag |
| `fp_rename_busy[x]` | 1 bit | FP tag mapping 当前是否 busy |
| `int_arf_read_data[s][x]` | `XLEN` | 直接来自 INT ARF 的源值 |
| `fp_arf_read_data[x]` | `XLEN` | 直接来自 FP ARF 的源值 |

`rs_data_sel_t` 必须保留 Commit data 命中这一类选择。P4 Commit 在 active
edge 才写入 ARF，同拍 dispatch 的消费者不能只读 pre-edge ARF；如果不在
这里打印选择结果，无法定位该类边界问题。

### 3.3 P2 ISQ issue

ISQ 的 `issue_valid` 是带 payload 的 Transaction。打印时必须打印
`issue_valid.fire` 成交的完整 issue payload；只打印 `issue_valid` 不足以
定位“指令发到了哪个 FU、源值是什么”。

| ISQ | issue payload |
| --- | --- |
| `ISQ_Group0.issue_valid` | `rs1_data`、`rs2_data`、`FU_Group`、`imm_valid`、`imm_data`、`pc`、`inst_bits`、`is_compressed`、`pred_taken`、`pred_target_pc`、`self_tag`、`exe_subop`、`full_decode`、`fetch_excp_vld`、`fetch_excp_cause`、`fetch_excp_tval` |
| `ISQ_Group1.issue_valid` | `rs1_data`、`rs2_data`、`FU_Group`、`imm_data`、`self_tag`、`exe_subop` |
| `ISQ_Group2.issue_valid` | `rs1_data`、`rs2_data`、`rs3_data`、`self_tag`、`exe_subop`、`full_decode` |
| `ISQ_Group3.issue_valid` | `rs1_data`、`store_data`、`imm_valid`、`imm_data`、`mem_funct3`、`rd_is_fp`、`entry_self_tag`、`exe_subop` |

同组还应打印：

- `isq_free_for_dispatch[g]`；
- `isq_occupied`，特别是 Group 3；
- `FU_ready`；
- `bypass_publish_valid[b]`、`bypass_tag[b]`、`bypass_data[b]`；
- `global_flush_late` 对本拍 issue 的取消关系。

Group 3 还必须保留 `st_br_resolve_tag`、`st_br_resolve_tag_valid` 和
`st_br_resolve`，因为 plain store 的授权可能发生在指令仍驻留 ISQ3 时。

### 3.4 P3/P4 交界：completion / writeback

这是 Level-2 最重要的中间事件。它是 Buffer 写入和 CompletionScoreboard
完成标记的直接来源，但还不是 architectural Commit。

对每个完成 lane `g∈{0,1,2,3}`，打印：

| 观察信号 | 形态 | 语义 |
| --- | --- | --- |
| `exec_valid[g]` / `writeback_valid[g]` | 1 bit | lane `g` 是否向 P4 交付完成 |
| `exec_tag[g]` / `tag_out[g]` | `TAG_W` | 完成 entry tag |
| `result_data[g]` | `XLEN` | 完成结果；同时写入 Buffer |
| `mispredict_flag[g]` | 1 bit | 是否产生 branch mispredict recovery |
| `mispredict_target_pc[g]` | `XLEN` | mispredict recovery target |
| `exception_flag[g]` | 1 bit | 是否产生同步 exception |
| `exception_cause[g]` | `EXCP_CAUSE_W` | exception cause |
| `exception_tval[g]` | `XLEN` | exception tval |
| `is_mret[g]` | 1 bit | 是否为 MRET |
| `is_sret[g]` | 1 bit | 是否为 SRET |
| `fpu_fflags[g]` | `FFLAGS_W` | 执行产生的 FP flags |

约束：

- `global_flush_late=1` 的拍不应把普通 completion 写入
  `CompletionScoreboard`；
- `exec_valid` 与 `commit_valid` 不是同一个事件；
- `result_data` 是写回完成值，`commit_data` 是 Commit head 读出的值；
- 同一 tag 的 completion 必须能与后续 `commit_tag` 关联。

#### FU request / arbitration 诊断

如果能从 P3 内部 probe 到，继续打印：

| 观察信号 | 语义 |
| --- | --- |
| `request_valid[fu]` | FU 是否有待仲裁 completion request |
| `req_tag[fu]` | 待仲裁 completion 的 tag |
| `req_result_data[fu]` | 待仲裁 completion 的结果 |
| `req_mispredict_flag[fu]` / `req_mispredict_target_pc[fu]` | 待仲裁 recovery 信息 |
| `req_exception_flag[fu]` / `req_exception_cause[fu]` / `req_exception_tval[fu]` | 待仲裁 exception 信息 |
| `req_is_mret[fu]` / `req_is_sret[fu]` | return 类型 |
| `req_fpu_fflags[fu]` | FP flags |
| `winner_grant[fu]` | 本拍获得 P3 仲裁的 requester |
| `loser_hold[fu]` | 请求有效但本拍未获得仲裁，必须保持 |

G0 的 CSR requester 还应打印：

```text
csr_sideband_publish_valid
tag_out
is_csr
csr_write_enable
csr_addr
csr_wdata
```

这些字段用于 system instruction handler 的“先暂存、后按 Commit tag
落地”流程，不能用 Commit packet 反推完整 CSR 写入信息。

### 3.5 Bypass / CDB

旁路在 completion 同拍出现，但其消费者是尚未 Commit 的 ISQ entry，因此
归入 Level-2：

| 观察信号 | 形态 | 语义 |
| --- | --- | --- |
| `bypass_publish_valid[b]` | 1 bit × 4 | lane `b` 是否发布旁路 |
| `bypass_tag[b]` | `TAG_W` × 4 | 旁路结果对应的 producer tag |
| `bypass_data[b]` | `XLEN` × 4 | 旁路结果数据 |

`bypass_publish_valid` 必须与 `exec_valid/writeback_valid` 的异常规则一同
打印：普通 exception completion 不应向依赖者发布错误的正常结果。

### 3.6 LSU / memory pre-Commit interface

#### BE -> LSU issue

| 观察信号 | 形态 | 语义 |
| --- | --- | --- |
| `be_lsu_issue_valid` | 1 bit | BE 是否向 LSU 发送访存请求 |
| `be_lsu_issue_pld.tag` / `.self_tag` | `TAG_W` | 访存指令 tag；不同 protocol 版本的字段名别名 |
| `be_lsu_issue_pld.exe_subop` | `EXE_SUBOP_W` | 访存/原子/fence 子操作 |
| `be_lsu_issue_pld.mem_funct3` | `MEM_FUNCT3_W` | 访问宽度和符号属性 |
| `be_lsu_issue_pld.rd_is_fp` | 1 bit | load 目的是否为 FP |
| `be_lsu_issue_pld.rs1_data` | `XLEN` | base operand |
| `be_lsu_issue_pld.store_data` / `.rs2_data` | `XLEN` | store/AMO 写数据；不同 RTL/protocol 版本的字段名别名 |
| `be_lsu_issue_pld.imm_valid` | 1 bit | immediate 是否有效 |
| `be_lsu_issue_pld.imm_data` | `XLEN` | 已符号扩展 immediate |
| `be_lsu_issue_pld.st_br_resolve` | 1 bit | plain store 是否已经获得顺序授权 |
| `be_lsu_issue_pld.is_store` | 1 bit | G3 plain-store 兼容分类位；若当前 protocol 未放入 payload，则打印其组装前来源 |
| `be_lsu_issue_pld.req_property` | packed property | LSU 请求分类；若当前 protocol 由 `exe_subop` 派生，则打印派生值而非伪造独立输入 |
| `lsu_be_issue_ready` | 1 bit | LSU 是否能接收当前请求 |
| `be_lsu_entry_ready` | 1 bit | BE/LSU bridge 对当前 G3 entry 的接收能力 |

当前代码同时存在两种字段命名约定：验证侧 schema 使用
`tag/store_data`，`g3_lsu_iface` 组装侧使用
`self_tag/rs2_data`，并可能携带 `is_store/req_property`。observation 层应
统一使用消费者语义，同时保留实际字段名作为 debug alias；如果某版本的
payload 不携带 `req_property`，则由 `exe_subop` 的派生结果补充打印。

#### LSU -> BE completion / bypass

| 观察信号 | 形态 | 语义 |
| --- | --- | --- |
| `lsu_be_done_valid` | 1 bit | LSU terminal/done event |
| `lsu_be_done_pld.tag` | `TAG_W` | LSU 请求 tag |
| `lsu_be_done_pld.done_valid` | 1 bit | 正常终结标志 |
| `lsu_be_done_pld.data` | `XLEN` | read-side 返回数据 |
| `lsu_be_done_pld.exception_valid` | 1 bit | LSU exception 标志 |
| `lsu_be_done_pld.exception_cause` | LSU cause width | LSU exception cause |
| `lsu_be_done_pld.exception_tval` | `XLEN` | LSU exception tval |
| `lsu_be_exception_valid` | 1 bit | 独立 exception 输入事件 |
| `lsu_be_exception_pld.*` | 完整 exception payload | exception 通道原始信息 |
| `lsu_be_bypass_valid` | 1 bit | read-side 数据是否在本拍旁路 |
| `lsu_be_bypass_pld.tag` / `.data` | tag + `XLEN` | read-side bypass 数据 |
| `be_lsu_store_wakeup_valid` | 1 bit | store 授权是否被送到 LSU |
| `be_lsu_store_wakeup_tag` | `TAG_W` | 被授权的 store tag |

LSU 的 done/bypass 经过 `g3_lsu_iface` 合并后才形成 lane 3 的
`exec_valid/result_data/exception_*`。因此该组 raw LSU 信号是 Level-2，
不能被 Level-1 的 `commit_data` 替代。

#### Store ordering

来自 CompletionScoreboard 和 LSU bridge 的 store 顺序信息也要打印：

```text
store_wakeup_valid
store_wakeup_tag
st_br_resolve_tag
st_br_resolve_tag_valid
st_br_resolve
wakeup_held[tag]
store_done[tag]
req_in_flight[tag]
```

其中 `wakeup_held/store_done/req_in_flight` 如果只能通过白盒 probe 取得，
先进入 log；它们是有效中间状态，但不是稳定的 architectural interface。

### 3.7 CSR pre-Commit sideband

CSR 指令的写入不是在执行完成时直接更新架构 CSR，而是先通过 sideband
按 tag 暂存，等对应 Commit tag 命中后再 apply。因此以下信息全部属于
Level-2：

| 观察信号 | 语义 |
| --- | --- |
| `csr_sideband_valid` | CSR sideband 是否有效 |
| `tag_out` | CSR 写对应的 producer tag |
| `sb_is_csr` | 是否为 CSR 指令 |
| `sb_csr_write_enable` | 是否产生 CSR 写 |
| `sb_csr_addr` | CSR 地址 |
| `sb_csr_wdata` | CSR 写数据 |
| `csr_rdata` | issue 时读到的 CSR 旧值 |
| `current_priv` | 当前特权级 |
| `mstatus_tvm` / `mstatus_tw` / `mstatus_tsr` | CSR/system 合法性控制 |
| `fs_enabled` / `frm` | FP/rounding 相关 CSR 执行上下文 |

CSR 的完整架构 snapshot、`mepc/mcause/...` 等持续状态不是本分级中
“Commit 前中间变量”的同义物。如果后续要做架构状态比较，应另设
`architectural_state` 接口，不要把 snapshot 字段伪装成 Level-2 event。

### 3.8 Memory monitor sideband

memory monitor 的 store 状态变化不一定与 BE 的普通 `commit_valid` 同拍；
例如 terminal/tohost store 可能先改变 memory model 的结束状态。因此它不
属于 Level-1 的逐条提交 packet，但作为在途指令的有效 sideband 归入
Level-2：

| 观察信号 | 形态 | 语义 |
| --- | --- | --- |
| `mem_store_commit_valid` | 1 bit | memory monitor 是否确认一次 store 状态变化 |
| `mem_store_commit_order` | 64 bit | store 在 memory monitor 中的顺序号 |
| `mem_store_commit_vaddr` | `XLEN` | 实际写地址 |
| `mem_store_commit_data` | `XLEN` | 写入数据 |
| `mem_store_commit_mask` | 8 bit | 实际写入 byte mask |
| `mem_store_commit_pc` | `XLEN` | store 对应 PC |
| `mem_store_commit_rob_idx` | 64 bit 或 zero-extended tag | store 与 ROB entry 的关联 |
| `mem_store_commit_terminal` | 1 bit | 是否为 terminal/tohost 类 store |

该组字段的命名来自当前 `ob_cosim_if`，实际来源可以是 cache agent、
LSU monitor 或后续真实 memory monitor。它不能由普通 `commit_valid` 伪造，
因为 store buffer、flush、AMO/SC 和 memory 生效时机可能与普通 ROB
Commit 不相同。

## 4. Level-1 / Level-2 关联规则

以下关联规则需要作为 observation interface 的断言或 checker 输入：

1. `commit_count == commit_valid[0] + commit_valid[1]`。
2. `commit_valid[1] -> commit_valid[0]`。
3. `commit_valid[k] -> commit_tag[k]`、`trace_pc[k]` 和 `commit_data[k]`
   在该拍共同构成一条提交记录。
4. `exec_valid[g] -> exec_tag[g]`、`result_data[g]` 和 completion sideband
   同拍有效。
5. 同一 tag 的 `exec` 必须先于对应的 `commit`；若该 tag 被 flush，则
   不应出现后续正常 Commit。
6. `bypass_publish_valid[b] -> exec_valid[b]`，且 exception completion
   不得发布正常 bypass。
7. `commit_data[k]` 必须等于 Buffer 中 `head_tag[k]` 对应 entry 的最后一次
   有效写回数据，而不是任意 lane 当前拍的 `result_data`。
8. `trace_pc[k]` 必须等于 PC_File 中 `head_tag[k]` 对应 entry 的 alloc PC。
9. `flush_valid` 有效时，`global_flush_late` 和 `redirect_valid` 应按
   `flush_model` 的恢复语义关联；被 flush 的 ISQ/FU/LSU/rename 状态不得
   产生新的正常 Level-1 Commit。
10. `store_wakeup_tag`、LSU issue tag、completion tag 和最终 commit tag
   应能形成同一条 store 生命周期链。

## 5. 当前 `ob_cosim_if` 的迁移差距

当前 `ob_cosim_if` 已有：

```text
commit_valid
commit_pc
commit_rob_idx
```

但按本分级，Level-1 核心提交 packet 还必须补齐：

```text
commit_rd_idx
commit_rd_is_fp
commit_rd_write_enable
commit_fflags
commit_count
commit_data
```

`rtl_v1_wrapper` 当前通过 `rtl_v1_obs_probe` 只把
`commit_valid/tag/trace_pc/count` 的部分信息映射到旧 observation 面；
Level-1 的完整提交 packet 需要从 `backend_top` 的
`rtl_commit_*`、`rtl_commit_data` 和 `rtl_trace_pc` 一起接出。

Level-1 的 Commit 控制/恢复接口还包括：

```text
store_wakeup_valid
store_wakeup_tag
flush_valid
flush_tag
recovery_kind
recovery_mispredict_target_pc
recovery_exception_cause
recovery_exception_tval
head0_tag
head1_tag
scoreboard_valid_bits
scoreboard_exec_done_bits
Buffer_tail
can_alloc_1
can_alloc_2
buffer_empty
```

其中一部分已经作为 `backend_top` 内部网络存在，但还没有进入当前
`ob_cosim_if`；应先由 RTL-near probe 或 `ob_if` v2 输出，不能让 checker
直接跨层级读取。

Level-2 推荐首先进入 `ob_if` v2 或 RTL-near probe，再由 BE agent/COSIM
消费。不要让 COSIM checker 直接读取：

- `backend_top` 层级路径；
- `u_CompletionScoreboard`、`u_Buffer`、`u_PC_File` 的私有数组；
- BETA/P600 专用 payload 类型；
- FU 或 LSU 的实现私有计数器。

稳定接口应输出本文列出的事件和 payload；只能白盒取得的 entry array、
`wakeup_held`、FU pending state 等先打印到 debug log，并标记为
implementation diagnostic。

## 6. 不属于两级接口 payload 的 COSIM 自生成字段

以下字段不是 DUT/BE 的 observation signal，不纳入 Level-1 或 Level-2：

- COSIM 自己生成的 `cycle`；
- COSIM 自己生成的 `sequence_id`；
- checker 内部的 pending queue、reference step counter 和比较结果码。

它们可以出现在日志中，但不应反向定义为 `ob_cosim_if` 的 RTL 抓取信号。

## 7. 参考文档

- `openrios/work/or-be-draft/modules/modules_v4/p4/Buffer.md`
- `openrios/work/or-be-draft/modules/modules_v4/p4/PC_File.md`
- `openrios/work/or-be-draft/modules/modules_v4/p4/CompletionScoreboard.md`
- `openrios/work/or-be-draft/modules/modules_v4/p4/flush_model.md`
- `openrios/work/or-be-draft/modules/modules_v4/p4/system_instruction_handler.md`
- `openrios/work/or-be-draft/modules/modules_v4/p2p3/p3_arbiter_G0.md`
- `openrios/work/or-be-draft/modules/modules_v4/p2p3/p3_arbiter_G1.md`
- `openrios/work/or-be-draft/modules/modules_v4/p2p3/ISQ_Group0.md`
- `openrios/work/or-be-draft/modules/modules_v4/p2p3/ISQ_Group1.md`
- `openrios/work/or-be-draft/modules/modules_v4/p2p3/ISQ_Group2.md`
- `openrios/work/or-be-draft/modules/modules_v4/p2p3/ISQ_Group3.md`
- `openrios/work/or-be-draft/modules/modules_v4/lsu/lsu_bridge.md`
- `openrios/rtl/rtl_v1/top/backend_top.sv`
- `openrios/verification/orbe_bt_env/tb/interfaces/ob_cosim_if.sv`
