# ORBE FE Agent Bring-up 基线

> 状态：当前仅用于 FE Agent 的 bring-up 基线。
> 范围：ORBE FE/BE 外部指令接口、基于 ISA Model 的取指，以及 redirect 后重新取指。
> 非目标：完整的 ORBE block-test 验证方案。完整的 FE Agent、DUT Wrapper 和 Cache Agent 验证方案，待这些部分集成后再最终确定。
> 当前阶段的重要边界：本文同时记录 FE Agent 的当前实现状态和接入完整 DUT Wrapper 后的目标职责。两者不能混为同一套 Model 生命周期方案。

## 1. 文档目的

本文记录当前 ORBE FE Agent 的 bring-up 目标和验收边界。眼下的目标，是以 beta BE block-test 环境中的 FE Agent 为实现参考，使其能够通过 ORBE FE/BE 外部接口，向 BE 发送由 ISA Model 提供原始指令形成的 instruction packet。

本文不是最终的 ORBE BT 架构文档。后续完整验证方案预计会复用已有 BT 环境中验证过的组织方式，但只有在 FE Agent、DUT Wrapper 和 Cache Agent 合并，并且各自的职责边界确定之后，才编写该方案。

## 2. 权威输入

当前阶段的 FE Agent 实现只使用以下资料作为输入：

1. `orbe_bt_env/docs/interface/ORBE_FE_AGENT_INTERFACE_SPEC_brief.md`
   - 当前 bring-up 阶段 FE Agent 到 DUT 的最终外部接口规格。
   - 定义 instruction valid/ready/payload、redirect valid/payload，以及各 payload 字段。
2. `openrios/` 中的架构资料
   - 用于参考 ORBE 模块行为以及 redirect/flush 相关概念。
   - 只有在需要澄清 FE 可见行为时才使用。
3. `mock_tb/README.md` 及其相关 FE/Wrapper 代码
   - 仅用于参考 mock_tb 与 FE Agent 的连接方式，以及 ready/redirect 的接口交互。
   - mock_tb 不直接调用 `isa_dpi_*` API；它与 FE Agent 的连接面是返回 ready 和 redirect。
   - 仅作实现参考；ORBE FE/BE 端口定义和 FE 行为仍以本目录下的 ORBE FE interface brief 及本文约定为准。
4. `beta_be_bt_env/`
   - 仅作为实现机制参考。
   - 提供 ISA Model 生命周期、ELF 取指、RVC 处理、pending queue 管理、ready 压缩和 redirect 重启等 FE driver 的工作模式。

历史 ORBE 尝试、golden 草稿或更早的 interface 草案，都不作为当前阶段的实现依据。

## 3. 阶段边界

### 3.1 当前范围

当前 FE Agent bring-up 包括：

- 在当前独立 FE bring-up 代码中，完成 ISA Model 的初始化和取指所需配置。
- 通过 DPI plusargs 加载 platform config 和 ELF。
- 从 ISA Model 的 virtual memory 中读取指令字节。
- 根据 `inst[1:0] != 2'b11` 判断 16-bit compressed instruction。
- 形成两条按程序顺序排列的 FE instruction lane；ORBE 为 2 发射。
- 驱动 ORBE 的 raw instruction payload。
- 实现按程序顺序约束的 ready/valid fire 语义。
- 按程序顺序保留并压缩尚未被接收的 lane。
- 处理 BE redirect：丢弃旧路径的 pending entry，并从 `redirect_pc` 重新取指。
- 记录足够的信息，以便调试 PC、instruction bits、lane fire 和 redirect 行为。

### 3.2 当前不做

当前 FE Agent bring-up 不包括：

- 观测 BE 内部的 ROB/tag allocation。
- 负责 ISA Model 的 `decode_and_issue`、`execute_insn`、`commit_auto`、`flush` 或 `flush_all` 调用。
- Cache Agent 或 LSU 的内存行为。
- Cosim 或独立 reference model 对比。
- 通过 backend commit 完成完整的 `tohost` PASS/FAIL 闭环。
- 负责 BE 的 `rob_idx` 分配或调用 `isa_dpi_trigger_trap()`；FE 只传递 fetch exception payload。
- 精确验证 pflush。

这些内容属于后续集成后的 ORBE BT 验证环境。尤其是完整集成模式下，FE Agent 不应自行创建第二个 ISA Model，也不应在 Wrapper/其他 agent 仍使用 Model 时提前销毁共享 Model。

## 4. FE/BE 外部接口

当前 bring-up 使用的最终接口由 `ORBE_FE_AGENT_INTERFACE_SPEC_brief.md` 定义。

### 4.1 指令通道

```text
FE -> BE  fe_be_instr_valid[lane]
FE -> BE  fe_be_instr_pld[lane]
BE -> FE  be_fe_instr_ready[lane]
```

当前定义的双向 ready/valid 事务只有 instruction channel。ORBE 是有序双 lane 接收，不能把两个 lane 当成互相独立的事务：

```text
fire[0] = fe_be_instr_valid[0] && be_fe_instr_ready[0]
fire[1] = fe_be_instr_valid[1] && be_fe_instr_ready[1] && fire[0]
```

lane 按程序顺序排列：

```text
lane 0 = 较老的指令
lane 1 = 较新的指令
```

FE Agent 不能在 lane 0 无效时，仅把 lane 1 置为 valid；lane 1 只有在 lane 0 同拍 fire 时才能 fire。该前缀 fire 约束由 FE Agent 自己负责计算和执行。本阶段不要求 mock_tb 额外审查或修正 `fire[1]=1、fire[0]=0` 的非法组合；需要检查时由 FE Agent 或 monitor 检查。

### 4.2 指令 payload

`fe_be_instr_pld[lane]` 只携带原始指令和前端元数据：

| 字段 | 位宽 | FE Agent 来源 |
| --- | ---: | --- |
| `pc` | 64 | 当前取指 PC。 |
| `inst_bits` | 32 | 原始指令 bits。对于 RVC，只有低 16 bit 有效，高位必须为 0。 |
| `is_compressed` | 1 | 表示该原始指令是否为 16-bit compressed instruction。 |
| `pred_taken` | 1 | bring-up 阶段的静态预测；除非后续策略改变，默认值为 0。 |
| `pred_target_pc` | 64 | 静态顺序执行目标：RVC 使用 `pc + 2`，其他指令使用 `pc + 4`。 |
| `fetch_excp_vld` | 1 | 真实 instruction-fetch fault entry 置 1；正常 entry 置 0。 |
| `exception_cause` | 5 | 同步 instruction-fetch cause 的低 5 bit；当前支持 `0`、`1`、`12`。正常 entry 置 0。 |
| `exception_tval` | 64 | 实际失败的 instruction-fetch 虚拟地址；低 halfword fault 为 `pc`，high halfword fault 为 `pc+2`。正常 entry 置 0。 |

因此，当前 FE instruction payload 的总位宽为 **232 bit**；两条 lane 的 payload 总量为 **2 x 232 bit**。

ORBE FE 接收的是 raw instruction packet。FE Agent 不能把 backend decode 结果、FU 路由信息、源/目的寄存器元数据、immediate 或 execution sub-op 字段放入该 payload。

当前取指异常策略区分零填充 EOF 和真实 fetch fault：`16'h0000` 零填充按 EOF 处理；`isa_dpi_fetch_mem_bank_virt` 返回非 PASS 且携带当前支持的同步 instruction-fetch trap 时，FE 发送一个 `fetch_excp_vld=1` 的异常 entry。异常 entry 使用 `inst_bits=32'h0000_0013`、`is_compressed=0`、`pred_taken=0`、`pred_target_pc=pc`，其中 `pc` 是逻辑指令起始地址；该 NOP 只是字段占位，BE 必须以 `fetch_excp_vld` 为异常语义来源。异常 entry 交付后 FE 停止产生 younger entry，等待 BE redirect。FE 不负责 `rob_idx` 分配，也不调用 `isa_dpi_trigger_trap()`；BE/Wrapper 在完成自身 entry 管理后负责调用该 DPI。正常 entry 的异常字段仍为 0。

### 4.3 Redirect 通道

```text
BE -> FE  be_fe_redirect_valid
BE -> FE  be_fe_redirect_pld
```

`be_fe_redirect_pld` 包含：

| 字段 | 位宽 | FE Agent 的使用方式 |
| --- | ---: | --- |
| `redirect_pc` | 64 | 必需。FE 从该 PC 重新开始取指。 |
| `interrupt_valid` | 1 | 对 FE 行为不是必需；可用于日志记录。 |
| `trap_valid` | 1 | 对 FE 行为不是必需；可用于日志记录。 |

因此，redirect payload 的总位宽为 **66 bit**。

Redirect 的优先级高于普通指令发送。当观察到 `be_fe_redirect_valid` 时，FE Agent 丢弃所有尚未 fire 的旧 pending entry，清除旧路径状态，并从 `redirect_pc` 重新开始取指。

当前 bring-up 对 Wrapper 的配合要求如下：

- `be_fe_redirect_valid` 应表示一个明确的 redirect 事件；当前接口没有 redirect ready/ack，建议由 DUT/Wrapper 产生单周期脉冲。
- `be_fe_redirect_pld` 必须与 `be_fe_redirect_valid` 同拍有效，其中 `redirect_pc` 必须有效。
- redirect 与普通 instruction dispatch 同拍发生时，redirect 优先；该拍不得继续把旧路径的 pending instruction 当作新的 allocation。
- 在第 N 个 `posedge clk` 采样到 `be_fe_redirect_valid=1` 后，FE 立即清空旧 pending，并暂停该周期的普通指令输出。
- 第 N+1 个周期，FE 根据采样到的 `redirect_pc` 重新取指；该周期重新输出的第一条指令必须满足 `pc == redirect_pc`。
- 当前 ORBE FE Agent 的上述 N/N+1 行为是本阶段采用的正确 redirect 语义；mock_tb 当前不同的 redirect 处理方式不作为 ORBE FE 参考。
- 如果存在连续 redirect，FE 以最新一次在上升沿采样到的 redirect target 重建 pending group；Wrapper 应保证 redirect payload 与对应 valid 同拍稳定。

### 4.4 时钟与复位

当前接口时钟和复位名称固定为：

```text
clk
rst_n
```

`rst_n=0` 期间，FE Agent 必须保持 `fe_be_instr_valid='0`，并将 instruction payload 清零；Wrapper 不应把复位期间的 payload 视为有效请求。当前 FE driver 的阶段性采样约定是：在 `posedge clk` 更新待发送 group，等待接口信号稳定后再读取 `be_fe_instr_ready`；redirect 在 `posedge clk` 采样，并优先于普通指令 group。后续如果集成层统一调整采样边沿，应同步修改 FE driver 和本文档，不得由 Wrapper 单方面改变 fire 的判定时刻。

## 5. 本阶段 ISA Model 的使用方式

在 FE-only bring-up 阶段，ISA Model 被用作由 ELF 支持的 instruction memory 和生命周期对象。ORBE 的 ISA Model 配置为单核、16-entry ROB：

```text
isa_dpi_create(1, 16)
MODEL_CORE_ID = 0
```

这里的 `16` 是 ISA Model 的 ROB 容量，不代表 FE Agent 可以观测或管理 DUT 内部的 ROB/tag。

当前独立 FE bring-up 代码负责调用：

```text
isa_dpi_create
isa_dpi_load_config
isa_dpi_load_elf
isa_dpi_add_arg
isa_dpi_finalize_config
isa_dpi_get_spec_pc
isa_dpi_fetch_mem_bank_virt
isa_dpi_is_to_exit
isa_dpi_is_good
isa_dpi_destroy
```

FE Agent 不负责调用：

```text
isa_dpi_decode_and_issue
isa_dpi_execute_insn
isa_dpi_commit_auto
isa_dpi_flush
isa_dpi_flush_all
isa_dpi_tick_finish
```

这些 API 依赖 backend 的生命周期事件，例如 ROB/tag allocation、执行完成、commit 和 flush 边界。它们应由后续的 DUT Wrapper 或 BE observer 逻辑处理，而不是由 FE Agent 处理。

**集成模式的生命周期约束：**完整 DUT Wrapper 接入后，ISA Model 必须只有一个生命周期所有者。推荐由 top-level 或 DUT Wrapper 统一负责 `create/load/finalize/destroy`，FE Agent 只保留 `isa_dpi_get_spec_pc`、`isa_dpi_fetch_mem_bank_virt` 以及必要的只读退出查询；FE Agent 不得再次调用 `isa_dpi_create` 或 `isa_dpi_destroy`。在该模式下，当前 `fe_driver.sv` 中的初始化/收尾代码需要由集成层开关或后续适配移除。

## 6. 从 Beta FE Driver 复用什么

beta FE driver 只作为实现机制参考，不是 ORBE 接口的权威来源。

可以复用的机制：

- ISA Model 生命周期管理的组织方式，但集成时必须由唯一 owner 统一管理。
- ELF plusarg 处理。
- 两字节指令长度判断。
- 指令字节的端序处理。
- `next_pc` 管理。
- pending queue refill。
- 基于 ready 的压缩，并增加 lane 1 不能越过 lane 0 的前缀 fire 约束。
- redirect 重启状态机。
- 最后的 `is_to_exit` 和 `is_good` 检查，但要结合当前阶段的限制理解其结果。

适配 ORBE 时必须修改：

- 使用两条 lane，而不是四条。
- 驱动 `fe_be_instr_valid` 和 `fe_be_instr_pld`，而不是 beta 的 `fe_be_instr_vld_d/info_d`。
- 消费 `be_fe_instr_ready`，而不是 beta 的 `fe_be_ready`。
- 驱动原始 `inst_bits`；不能在 FE 对 RVC 做外部解压并发送 32-bit encoding。
- 使用 `is_compressed`，而不是 beta 中的 `is_rvc` 命名。
- 使用 `be_fe_redirect_pld.redirect_pc`，而不是 beta 中单独的 redirect PC 信号。
- 保留 raw RVC halfword；不要在 FE 侧解压后再发送给 BE。

### 6.1 与 mock_tb 的已知差异

当前已确认，mock_tb 与 ORBE FE Agent 在以下行为上不能直接互相替换：

1. **接口职责**：mock_tb 不直接调用 `isa_dpi_*`；在本 bring-up 的 FE 连接面上，它只向 FE Agent 返回 `be_fe_instr_ready`、`be_fe_redirect_valid` 和 `be_fe_redirect_pld`。FE Agent 自己负责取指、pending 管理和 fire 约束。
2. **lane 顺序约束**：`fire[1]` 必须包含 `fire[0]` 是 FE Agent 的约束。mock_tb 不负责发现或修正 `fire[1]=1、fire[0]=0`，因此该条件应在 FE Agent 或 monitor 侧检查。
3. **redirect 时序**：ORBE 采用“第 N 个上升沿采样 redirect，清空 pending 并暂停输出，第 N+1 个周期根据新的 `redirect_pc` 重建并输出”的方式。mock_tb 当前不同的 redirect 实现存在已知问题，不作为 ORBE redirect 参考。
4. **取指异常**：ORBE FE Agent 区分 zero-fill EOF 与真实 fetch fault。零填充不产生 entry；真实 fetch fault 通过 `fetch_excp_vld`、5-bit `exception_cause` 和 64-bit `exception_tval` 形成异常 entry，并在该 entry 后停止产生 younger entry。BE/Wrapper 负责根据异常 entry 和自身 `rob_idx` 调用 `isa_dpi_trigger_trap()`；FE 不调用该 DPI。
5. **命名**：mock_tb 与当前 ORBE FE Agent 之间存在文件/模块命名冲突。该问题属于后续联调时的工程适配事项，本阶段不改变 ORBE FE Agent 的接口行为和验证结论。

## 7. 没有 ORBE RTL 时的 Smoke 验收方案草案

如果完整的 ORBE RTL 尚不可用，仍可以通过一个最小 test harness 或 DUT Wrapper 来验证 FE 行为，由它产生 ready 和 redirect 响应。这里的目标是验证 FE/BE 外部接口行为，不是证明 ORBE RTL 已经完成，也不是证明 ISA Model 已经完成 backend 执行和提交。该 harness/mock sink 不需要调用 FE Agent 的取指 DPI，只需要对 FE 输入提供可控的 ready/redirect。

这个 harness 不是 BE observer。它只提供 FE 可见的外部接口信号：

```text
be_fe_instr_ready[lane]
be_fe_redirect_valid
be_fe_redirect_pld
```

### 7.1 需要记录的 Monitor 事件

记录每一笔 instruction fire：

```text
cycle
lane
pc
inst_bits
is_compressed
pred_taken
pred_target_pc
```

记录每一次 redirect：

```text
cycle
redirect_pc
interrupt_valid
trap_valid
```

### 7.2 最小通过标准

观察到以下行为时，FE Agent bring-up 通过：

1. 当两个 lane 都可接收时，FE 从 ELF entry PC 开始，连续发送按程序顺序排列的指令流。
2. RVC 指令发送原始的 16-bit `inst_bits[15:0]`，将 `inst_bits[31:16]` 置 0，`is_compressed=1`，并且 `pred_target_pc=pc+2`。
3. 32-bit 指令发送原始的 32-bit `inst_bits`，`is_compressed=0`，并且 `pred_target_pc=pc+4`。
4. 如果某条 lane 有效但没有 fire，它对应的指令必须保持，直到 fire 或被 redirect 丢弃。
5. 如果 lane 0 fire 而 lane 1 没有 fire，原 lane 1 指令必须在下一次发送时压缩到 lane 0。
6. Redirect 必须丢弃所有尚未 fire 的旧路径 pending entry。
7. 在第 N 个上升沿采样 redirect 后，FE 在该周期清空旧 pending 并暂停普通指令输出；第 N+1 个周期重新输出的第一条指令必须满足 `pc == be_fe_redirect_pld.redirect_pc`。
8. 任何周期都不能出现 lane 1 valid 而 lane 0 invalid；同时，FE Agent 计算出的 fire 不能出现 `fire[1]=1、fire[0]=0`。

### 7.3 建议的 Smoke 场景

至少运行以下模式：

| 场景 | 目的 |
| --- | --- |
| Ready 始终为 `11` | 验证基本的连续取指和 fire。 |
| 按 lane 分别指定 ready 的模式：lane0/lane1 为 `0/1`、`1/1`、`0/0`、`1/0` | 压力测试压缩和保持行为；其中 `1/0` 只能 fire lane 0，不能 fire lane 1。 |
| 发送若干条指令后触发 redirect | 验证从 `redirect_pc` 重新开始。 |
| ready 为 0 时触发 redirect | 验证旧 pending entry 被丢弃。 |
| lane 0 fire、lane 1 未 fire 时触发 redirect | 验证 redirect 优先于普通压缩。 |
| 连续触发 redirect | 验证最新 redirect 生效，旧路径不会被重新发送。 |

日志中应使用 lane 顺序记法，避免产生 bit order 歧义。

## 8. 已知限制

当前 bring-up 阶段有意不证明 ORBE 是否能正确 commit 指令，只证明 FE Agent 的外部驱动行为。

已知限制包括：

  - ELF 末尾常见的 `16'h0000` 零填充按 EOF 处理；它不作为非法指令或 fetch exception entry 发送。EOF 只阻止新 entry 产生，不清除已经存在的 pending entry。
  - `isa_dpi_fetch_mem_bank_virt` 返回非 PASS 且携带当前支持的同步 instruction-fetch trap 时，FE 发送 exception entry，而不是一律转换成 EOF。第一阶段支持 `INSN_ADDR_MISSALIGN=0x0`、`INSN_ACCESS_FAULT=0x1` 和 `INSN_PAGE_FAULT=0xc`；`NO_TRAP=0x3f` 及带 interrupt 标志的 cause 不得作为 fetch exception cause 发送。
  - 异常 entry 的 `pc` 是逻辑指令起始地址，`inst_bits=32'h0000_0013`，`is_compressed=0`，`pred_taken=0`，`pred_target_pc=pc`；低 halfword fault 的 `exception_tval=pc`，32-bit 指令 high halfword fault 的 `exception_tval=pc+2`。异常 entry 交付后 FE 停止产生 younger entry；未 fire 时仍遵守 payload stability。
  - FE 不负责 `rob_idx` 分配，不调用 `isa_dpi_trigger_trap()`；BE/Wrapper 在接收异常 entry 并完成自身 entry 管理后负责调用该 DPI。redirect 会清除异常停止状态，从 `redirect_pc` 重新开始取指。
- 如果没有 backend 执行、提交和内存侧 `tohost` 行为，`isa_dpi_is_to_exit` 可能不会变为 true；FE-only smoke 不应以它作为唯一通过条件。
- 当前只在 FE 接口层面验收 redirect：FE 会跟随 `redirect_pc`；该 PC 的产生原因和正确性属于 ORBE/DUT 验证范围。
- 当前没有 ROB/tag allocation，因此本阶段无法完成 ISA Model 的精确 decode、commit 或 flush 对齐。

FE-only smoke 的通过条件应以有限周期内的接口观测和断言为主：指令顺序、payload 内容、稳定性、前缀 fire、redirect 后首条 PC，以及旧路径指令不再 fire。完整集成后再由统一的 Model owner 负责 `is_to_exit`、`is_good` 和 `destroy`。

## 9. 通向完整 ORBE BT 的后续路径

FE Agent、DUT Wrapper 和 Cache Agent 合并后，应使用完整的 ORBE BT 验证架构文档替代本文档。

后续文档应定义：

- FE、DUT Wrapper、BE observer 和 Cache Agent 之间的共享 ISA Model 唯一所有权，以及 create/load/finalize/destroy 的确切位置。
- 根据真实 ORBE tag allocation，确定何处调用 `decode_and_issue`。
- 明确 redirect 和 pflush 如何映射到 ISA Model 的 flush API。
- 明确如何观测 commit 和 trap。
- 完成内存、store drain 以及 `tohost` exit 的处理。
- 明确 FE Agent 在 standalone 和 integrated 两种模式下的初始化/收尾 API 差异。
- 明确哪些内容由共享 model path 验证，哪些内容可由独立 cosim 进行补充验证。

在此之前，本文档就是 ORBE FE Agent bring-up 的范围边界。
