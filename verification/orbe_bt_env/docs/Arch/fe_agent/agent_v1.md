# Agent 实现文档骨架

## 目的与总原则

本骨架用于编写可直接驱动 Agent 实现生成和修改的实现契约。文档描述 Agent 的外部行为、控制状态、真实存储和数据流；不描述推导过程、实现理由、内部连接或未被接口暴露的实现细节。

- 文档只有一个建模对象：`Agent`。
- 每个定义只出现一次。后续章节只引用名称，不重复改写公式或 schema。
- 文档不使用 Markdown 表格。字段、条件、接口和连接使用有序列表、无序列表或代码块。
- 顶层章节固定为：`FSM`、`Data structure`、`Interface`。
- `Output` 不设为独立章节；所有对外 `Out-event` 和 `Out Static Info` 均在 `Interface` 中定义。
- 设计文档只写规范：状态、事件、表达式、schema、时序和更新规则。不要写“因为……所以……”的推导说明，也不要把 `mux`、`demux`、`merge` 等实现结构写成 Agent。
- 参数、编码和位宽只在第一次出现的位置定义；后续只使用同一名称。
- 跨 public Agent 的同一语义值使用 producer 定义的 canonical 名称和索引；集成层直接连线，不因消费者的接口端点习惯改名。只有产生了新语义的组合结果才建立新名称，并在产生它的 Agent 中定义。

文档头部的 `# Agent` 只写 Agent 名称、基本 property 和 agent 类型，例如：

```text
# Agent `IB`

`IB`：8-entry、2-lane 的前端指令 FIFO。
```

### 条目格式

同一章节下的并列对象使用有序编号；不使用一级无序列表。普通条目使用：

```text
1. `name`：schema；表达式或连接；时序、保持或取消规则。
```

条目需要展开时，详细字段、语义、公式和约束全部缩进在该编号下：

```text
1. `entry.payload[0:7]`：`IB_payload`
   - `IB_payload`：`pc[63:0]`、`inst_bits[31:0]`、`is_compressed`、`pred_taken`、`pred_target_pc[63:0]`、`fetch_excp_vld`、`fetch_excp_cause[4:0]`、`fetch_excp_tval[63:0]`。
```

规则：

- 一级并列对象统一使用 `1.`、`2.`、`3.` 的连续编号；编号只属于该章节，不跨章节延续。
- 缩进项只解释所属编号对象，不产生新的同级对象；需要继续展开时继续增加缩进层级。
- Event 主项下的 `Fire来源`、`Constraint`、`Payload` 和 `Side effect` 是同级 bullet，统一使用一个 Tab 后接 `-`。
- `Fire来源` 的 fire 表达式直接写在该 bullet 行，不另起“Fire来源”子 bullet；例如（下一行先输入一个 Tab）：`- Fire来源：\`enqueue[s].fire = fe_valid[s] ∧ IB_ready[s]\``。
- fire 表达式中的信号按依赖关系递归展开：先写信号语义，再在下一层写定义式；每增加一层依赖就增加一级缩进。
- `Out Static Info` 也必须使用同一套“公式树”格式：编号对象是根，第一层缩进只能写根公式；根公式中出现的每个派生值，按其在根公式中的直接依赖关系作为下一层缩进；多个直接依赖必须保持同级；每个派生值的公式继续写在该值的下一层。禁止把 `fp_illegal`、`rm_illegal`、`frm_illegal` 等派生项平铺到根对象的同一编号层，也禁止把一个派生项错误地缩进到另一个同级派生项下面。
- 对带索引或多 lane 的 Static Info，编号对象可以是整个向量，第一层分别列出各索引分量的根公式；各分量内部仍按同一公式树递归，分量之间不互相缩进。
- Static Info 公式树示例：

```text
9. `illegal_effective[s]`：1 bit x 2；decode 或当前 FP 状态导致的非法。
	- `illegal_effective[s] = full_decode[s].illegal ∨ fp_illegal[s]`
		- `full_decode[s].illegal`
		- `fp_illegal[s]`
			- `fp_illegal[s] = is_fp_instruction[s] ∧ (¬fs_enabled ∨ rm_illegal[s])`
				- `is_fp_instruction[s]`
				- `fs_enabled`
				- `rm_illegal[s]`
					- `rm_illegal[s] = uses_rm(exe_subop[s]) ∧ (rm_is_reserved(full_decode[s].rm) ∨ (full_decode[s].rm == RM_DYN ∧ frm_illegal))`
						- `uses_rm(exe_subop[s])`
						- `rm_is_reserved(full_decode[s].rm)`
							- `rm_is_reserved(rm) = (rm == RM_RSV5) ∨ (rm == RM_RSV6)`
						- `frm_illegal`
							- `frm_illegal = (frm == RM_RSV5) ∨ (frm == RM_RSV6) ∨ (frm == RM_DYN)`
```

- 上例中每一层只列出该公式的直接依赖；`fp_illegal` 与 `full_decode.illegal` 是 `illegal_effective` 的同级依赖，`rm_is_reserved` 与 `frm_illegal` 是 `rm_illegal` 的同级依赖。终端输入只引用本 Agent 的 `Interface` 或 `Data structure`；派生项必须位于产生它们的上一级公式下。
- 公式树验收条件：
  1. 根对象只有一个编号，且编号行包含 schema 和语义。
  2. 根对象的第一层缩进必须是根公式；不得先列派生项再列根公式。
  3. 公式中的每个直接依赖各占一个同级缩进项；依赖 A 只有在 B 的公式中出现时才能缩进到 B 下。
  4. 依赖项的定义式紧跟在该依赖项的下一层；没有本地定义式的终端输入只写名称，以及本 Agent `Interface` 或 `Data structure` 的章节引用。
  5. 同一派生项在同一对象下只定义一次；后续出现只写名称或引用。
  6. 下列写法不合规：

```text
9. `illegal_effective[s]`：...
	- `illegal_effective[s] = full_decode[s].illegal ∨ fp_illegal[s]`
	- `fp_illegal[s] = ...`
	- `rm_illegal[s] = ...`
	- `frm_illegal = ...`
```

  `rm_illegal` 和 `frm_illegal` 不是 `illegal_effective` 的直接依赖，不能与 `fp_illegal` 平铺；它们必须沿 `fp_illegal -> rm_illegal` 的依赖路径继续缩进。
- 同一信号在本 Event 或本 Agent 前文已经定义时，只引用名称或“见第 N 条”，不重复展开。
- 缩进项使用 `-`，并采用“`name`：一句话语义；定义式或字段列表”的格式。
- `fire` 的递归展开、payload 字段和接口约束都遵循此规则。
- 无对象时只写“无”，不写空编号或占位条目。
- 同一对象只定义一次；后续位置只引用名称，不重新编号、改名或重复展开。
- 跨 Agent Static Info 只保留一个由 producer 定义的 canonical 端点。例如 `inst_valid[s]` 被多个消费者读取时，不得再建立 `slot0_present`、`slot1_present` 等同义公共信号；消费者若需要 slot 语义，使用相同的 `inst_valid[s]` 索引。
- 不使用“谓词”“leaf”“event”等标签。

## FSM

FSM 描述控制通路：哪些真实状态存在、哪些 `Event` 驱动状态变化，以及每个 Event 的完整 fire 条件。`Condition Name` 就是实际 Event 名称，不为状态结果另造名称。

### State

描述本 Agent 的语义状态。状态的每个取值必须对应不同的对外行为；不能把可由指针、计数器或已有字段计算出的视图另列为状态。

无状态 Agent 写：

```text
无。
```

有状态 Agent 使用简洁编号：

```text
1. `IDLE`：无可处理 entry。
2. `RESIDENT`：存在可处理 entry。
```

每个 entry 的状态都应能在本节找到。FIFO、计数器或指针压缩的状态表示在 `Data structure -> State` 中说明，本节只列语义状态。

### State Transition & Condition Name

逐条列出所有可达的 `Current State -> Next State`，并在行末写驱动 Event：

```text
1. `ANY -> IDLE`：`reset`
2. `RESIDENT -> IDLE`：`flush`
3. `IDLE -> RESIDENT`：`enqueue`
4. `RESIDENT -> IDLE`：`dequeue`
```

规则：

- 必须穷举实际存在的状态对；不能使用 `A/B -> A/B`、`normal_*`、`hold_or_update` 等合并或临时名称。
- 同一状态对由多个 Event 驱动时，在同一行逐个列出 Event；语义不同的转移另起一行。
- 只写真实 Event，不为“无动作保持”创建 Event。没有 Event fire 时状态保持。
- 编号连续且稳定。本节第 `N` 条必须对应 `Detailed Condition Description` 第 `N` 条。
- 转移行只写 `Current -> Next：Event`，不在此解释判据或实现原因。

### Detailed Condition Description

按转移编号定义每个 Event 的 fire 和状态更新。这里是 fire 的唯一逻辑定义点；`Interface` 只归档接口方向和 schema，并引用本节定义。

每条 Event 使用以下格式（缩进符号按实际文档输入 Tab）：

```text
1. `event_name`：一句话说明动作。
\t- Fire来源：`event_name.fire = expression`
\t\t- `signal_name`：该信号在本拍表达的语义。
\t\t\t- `signal_name = expression`
\t- Constraint：约束或取值集合。
\t- Payload：`schema`；slot 数；采样拍数。
\t- Side effect：状态、指针或存储的更新式；无更新写 `无`。
```

完整示例（以 FIFO 的 `enqueue` 为例）：

```text
3. `enqueue`：接收 FE 当前拍提交的 payload。
	- Fire来源：`enqueue[s].fire = fe_valid[s] ∧ IB_ready[s]`
		- `fe_valid[s]`：FE 当前拍是否提供 slot `s` 的 `IB_payload`。
		- `IB_ready[s]`：IB 当前拍是否能接收 slot `s`。
			- `IB_ready[0] = (free_slot >= 1) ∧ ¬flush.fire`
			- `IB_ready[1] = fe_valid[0] ∧ (free_slot >= 2) ∧ ¬flush.fire`
			- `free_slot`：计入同拍 dequeue 后的可用空位数量。
				- `free_slot = IB_DEPTH - occupancy_after_dequeue`
				- `occupancy_after_dequeue = valid_count - deq_count`
					- `deq_count`：当前拍实际 dequeue 的 entry 数量。
						- `deq_count = dequeue[0].fire + dequeue[1].fire`
					- `IB_DEPTH=8`：FIFO entry 数量。
				- `valid_count`：拍初 FIFO 中已占用的 entry 数量。
					- `valid_count = (wptr_q - rptr_q) mod 16`
						- `wptr_q`：拍初写指针，指向下一个可写位置。
						- `rptr_q`：拍初读指针，指向当前 head payload。
	- Constraint：`fe_valid[1] -> fe_valid[0]`；`enqueue` 只能为 `00`、`01`、`11`。
	- Payload：`IB_payload[s]`。
	- Side effect：`entry.payload[(wptr_idx+s) mod IB_DEPTH] <- IB_payload[s]`；`wptr_q_next = wptr_q + enq_count`；`wptr_idx = wptr_q[IB_PTR_W-2:0]`；`enq_count = enqueue[0].fire + enqueue[1].fire`。
```

该示例的阅读方式是固定的：`3.` 是 Event 主项；其下四个 Tab 一级 bullet 是该 Event 的平级组成部分；只有 `Fire来源` 下的信号依赖继续缩进。`Constraint`、`Payload` 和 `Side effect` 不属于 fire 依赖树。

Interface 的编号和缩进同样遵循此格式。

具体要求：

- fire 是仅当拍有效的可求值布尔表达式；下一拍重新判断。
- `Detailed Condition Description` 中的 `Fire来源` 行直接写完整 fire 表达式，不另建 `fire` 子项。
- fire 表达式中的每个直接输入信号都作为 `Fire来源` 的下一级 bullet，先写语义，再按依赖关系继续缩进其定义式。
- 中间信号按表达式依赖树逐级缩进，直到每个信号都能在 `Data structure` 或本 Agent 的 `Interface` 找到。
- `Constraint`、`Payload`、`Side effect` 与 `Fire来源` 平级；它们内部需要展开的字段继续在所属 bullet 下缩进。
- Detailed Condition 中每个非本 Agent 的直接输入 Event 必须在 `Interface -> In-event` 出现；直接读取的外部持续值必须在 `Interface -> In Static Info` 出现；本 Agent 自己计算出的状态投影、ready 或其他 Static Info 必须能在 `Data structure` 或 `Out Static Info` 找到。
- 组合条件必须互斥且完备；不可达组合写出约束，但不为约束另造 Event。
- Event 的 payload、slot 数和拍数在本处写出 schema；对外输出的同一项在 `Interface` 再归档一次，名称和定义必须一致。
- 不在本节说明外部来源；外部输入统一在 `Interface -> In-event` 或 `In Static Info` 归档。
- reset、flush、enqueue、dequeue 等名称只在真实拥有该动作的 Agent 中定义。准入、ready、select、route、candidate 本身没有状态更新时，属于 Static Info，不属于 Event。
- 跨 Agent 动作按事件链记录：生产者在 `Interface -> Out-event` 定义输出事件；消费者在 `Interface -> In-event` 定义本地输入信号；Agent 文档不写输入信号的生产者。集成层明确记录输出事件到输入信号的连接。消费者在自己的 `Detailed Condition Description` 中用本地 In-event 信号触发状态更新；生产者不能直接写消费者的 Side effect。

## Data structure

描述本 Agent 真正保存或持续组合产生的数据结构，并写明更新时机。有 FSM 时这里只写结构和字段，不重复完整 fire 推导和 Side effect；没有 FSM、但包含真实存储时，按本章 `Payload` 的无 FSM 规则定义更新时机和具体更新。

### State

列出真实存储的状态寄存器、指针、计数器或状态阵列，并说明它们如何表示 `FSM -> State` 中的语义状态：

```text
1. `IDLE / RESIDENT`：语义状态；压缩进 `wptr`、`rptr`；有效区间为 `[rptr, wptr)`。
2. `wptr`：4 bit，`{loopbit,index[2:0]}`；由 `enqueue` 更新。
3. `rptr`：4 bit，`{loopbit,index[2:0]}`；由 `dequeue` 更新。
```

首次出现的参数、常量和编码必须在同一条目中注明位宽、范围或取值。由这些存储解码出的 `valid`、`occupancy`、`idle` 等是 Static Info，不再列为额外 state。

如果没有状态，只写：

```text
无。
```

不得在“无。”后追加 Agent 名称、原因、排除项、实现说明、总结或其他描述。

### Header

列出真实存储中会被本 Agent 控制逻辑读取、比较或匹配的字段。每项写清位宽和更新规则：

```text
1. `header_name`：width；用于 condition 的比较或资格判断；由 `event_name` 更新。
```

如果没有被控制逻辑消费的独立字段，只写：

```text
无。
```

不得在“无。”后追加 Agent 名称、原因、排除项、实现说明、总结或其他描述。

### Payload

列出真实存储的 payload 端点及其来源。payload 是本 Agent 的数据传递载体，并且与 header 是正交视角，不是互斥分类。若 payload 来源于多处，在第一行注明“多个 event payload”或“event payload 和 static info”。第二行开始每个源头一行，写源 payload 名及字段，或直接写 static info 信号名；不在本节重复位宽信息。

```text
1. `entry.payload[index]`：来源于 `Agent_payload`。
	- `Agent_payload`：`field_a`、`field_b`、`field_c`。
```

多来源 payload 使用以下格式：

```text
1. `entry.payload[index]`：来源于多个 event payload 和 static info。
	- `event_payload_a`：`field_a`、`field_b`。
	- `event_payload_b`：`field_c`。
	- `static_info_name_1`、`static_info_name_2`。
```

示例：

```text
1. `entry.payload[t]`：来源于多个 event payload。
	- `CompletionScoreboard_alloc_payload`：`rd_idx`、`rd_is_fp`、`rd_write_enable`、`is_store`、`is_fence_i`、`may_flush`、`is_atomic`。
	- `CompletionScoreboard_completion_payload`：`mispredict_target_pc`、`exception_cause`、`exception_tval`、`fpu_fflags`。
	- `CompletionScoreboard_commit_payload`：`fpu_fflags`。
```

有 FSM 且存储更新时机和具体更新已经在 `FSM -> Detailed Condition Description` 中定义的 Agent 采用上述写法，不得增加其他信息或重复已有的定义和逻辑推导。对于没有 FSM、但包含真实存储的 Agent，存储的更新时机和具体更新无法在 `FSM -> Detailed Condition Description` 中定义，必须在对应的 `Data structure -> Payload` 条目中定义。在现有的来源 payload 和字段之后，依次增加与来源同级的 `更新时机` 和 `Update` bullet：

```text
1. `entry.payload[index]`：来源于 `Agent_payload`。
	- `Agent_payload`：`field_a`、`field_b`、`field_c`。
	- 更新时机：`update_condition = expression`；采样或更新时序。
		- `direct_dependency_a`：语义或 Interface 引用
		- `direct_dependency_b`：语义或 Interface 引用（如为派生值，继续在下一层写定义式）
	- Update：`entry.payload[index] <- expression`。
		- `update_condition`：引用本条“更新时机”中的定义。
		- `payload_field`：见本条来源 payload 字段。
		- `entry.payload[index]`：更新前的存储值；无更新条件成立时保持。
```

`更新时机` 定义存储何时采样或改变，必须写清组合条件、时钟边沿以及同步或异步属性。`Update` 定义该时机对应的完整存储更新式，必须覆盖写入地址、写入数据、多来源优先级、保持和复位行为。二者出现的派生条件和值按本规则的公式树逐级展开，直到每个终端名称都能在本条来源字段、`Data structure` 或本 Agent 的 `Interface` 中找到；已经在本条前文定义的名称只引用，不重复展开。不得增加其他信息或重复已有的定义和逻辑推导。

`FP_ARF` 示例：

```text
1. `entry.payload[i]`：来源于 `FP_ARF_payload[k]`，`i∈{0,...,NUM_FPR-1}`。
	- `FP_ARF_payload[k]`：`commit_data[k]`。
	- 更新时机：`¬rst_n` 时异步更新；`rst_n ∧ write_enable` 成立时在上升沿更新。
		- `rst_n`：见 `Interface -> In Static Info`。
		- `write_enable = ∃k∈{0,...,ISSUE_WIDTH-1}: write_req[k]`
			- `write_req[k] = commit_valid[k].fire ∧ rd_write_enable[k] ∧ rd_is_fp[k]`
				- `commit_valid[k].fire`：见 `Interface -> In-event`。
				- `rd_write_enable[k]`：见 `Interface -> In-event`。
				- `rd_is_fp[k]`：见 `Interface -> In-event`。
	- Update：`entry.payload[i] <- ¬rst_n ? 0 : (write_req[0] ∧ i=rd_idx[0]) ? commit_data[0] : (write_req[1] ∧ i=rd_idx[1]) ? commit_data[1] : entry.payload[i]`。
		- `rst_n`：见本条“更新时机”。
		- `write_req[k]`：见本条“更新时机”。
		- `rd_idx[k]`：见 `Interface -> In-event`。
		- `commit_data[k]`：见本条来源 payload 字段。
		- `entry.payload[i]`：更新前的存储值。
```

命名规则：进入本 Agent 的 payload 为 `` `<Agent>_payload` ``；传给下游 Agent 的 payload 为 `` `<DownstreamAgent>_payload` ``；存储端点统一为 `entry.payload`。不得另造 `*_storage`、`head_*`、`entry_payload` 或 `*_transfer` 等同义名称。

FIFO 或寄存器阵列的组合读是持续的 Static Info。若 `dequeue`/`read` 的 payload 为 `∅`，它只更新指针或状态，不触发 payload 读取。写入和组合读必须在本节的 `更新时机`/`Update` 或 `Interface` 的公式树中完整确定；本骨架不设独立连接章节。

注意：`Data structure -> Payload` 的字段使用统一的存储路径：凡在 `FSM`、`Interface` 或其他章节引用 entry payload 字段，必须写成 `entry.payload.<field>` 形式；不得使用内部寄存器名（如 `entry_<field>`）作为该字段的文档端点。

## Interface

Interface 是 Agent 的唯一对外契约归档点。它从 FSM 和 Data structure 的实际读取与输出推导：输入由内部逻辑决定，输出由本 Agent 对外提供的行为决定。

### In-event

列出本 Agent 从 Agent 边界收到、且被 `Detailed Condition Description` 或本地状态动作使用的输入信号。In-event 按本 Agent 的局部语义命名，只写类型、payload、数量和本 Agent 的使用方式，不写生产者或上游 Agent 名称。一个 Transaction 可以由一个 valid 信号和本 Agent 的 ready 共同形成 fire；此时 valid/payload 仍作为一个本地 In-event 条目记录。

对 Notify 类型的 in-event，fire 来源于本 Agent 外部的 event 生产者，因此写 Fire 来源： `signal.fire`。对 valid/ready Transaction 类型的 in-event，握手 fire 由本 Agent 的 FSM 定义，因此写 Fire 来源：见 `FSM -> Detailed Condition Description` 第 N 条。In-event 的 Fire来源 是引用，不是新的 fire 定义点，不重新展开。

```text
1. `event_name`：Event 类型，索引变量定义
	- Fire来源：`signal.fire` 或 见 `FSM -> Detailed Condition Description` 第 N 条
	- Payload：`PayloadName`；时序
	`PayloadName`：每个 payload 字段及其位宽 schema (只有一个字段时，直接在 `payload` 行写字段名、位宽、数量和时序，不另起 schema 行)
```

例子：

```text
1. `alloc[s]`：Notify，`s∈{0,1}`
	- Fire来源：`accept[s].fire`
	- Payload：`CompletionScoreboard_alloc_payload`；上升沿采样
	`CompletionScoreboard_alloc_payload`：`alloc_self_tag` 16 bit × 2、`rd_idx` 5 bit × 2、`rd_is_fp` 1 bit × 2、`rd_write_enable` 1 bit × 2、`is_store` 1 bit × 2、`is_fence_i` 1 bit × 2、`may_flush` 1 bit × 2、`is_atomic` 1 bit × 2
```

无 payload 时保留 `Payload：∅` 行；payload 只有一个字段时，直接在 `Payload` 行写成“字段名 位宽 × 数量”形式，不另起 schema 行；payload 有多个字段时，`Payload` 行写 `PayloadName`，再以同一缩进且不加 bullet 的行列出其字段 schema。Event 条目只包含上述事件名、类型、索引变量、fire、payload、时序和 schema 信息。

`Transaction` 需要 valid/ready 或 credit 握手；`Notify` 为生产者 fire-and-forget，消费者保证可接收。对于 valid/ready Transaction，握手 fire 是双方共同的 `valid ∧ ready`：拥有 `ready`、捕获动作和相关状态更新的接收方，必须在自己的 `FSM / Detailed Condition Description` 定义该 fire；生产者保持 valid 和 payload，直到 fire。接收方可以额外输出 `accept` Event 给生产者，且 `accept.fire` 必须等于同一次 Transaction fire。In-event 与 Out-event 可以使用相同字面名称，方向、payload 和所在分组共同定义其语义；它们不是同一个接口对象。

Notify 的 payload 可以为 `∅`。当消费者需要在该 Notify fire 的同一拍捕获额外字段时，这些字段必须单独列在消费者的 `In Static Info`，并在消费者的 `Data structure -> Payload` 的 `更新时机`/`Update` 中写出该字段的采样与更新；不得把消费者所需字段反向追加到 producer 的 Notify schema。该规则适用于 `accept`、`isq_wr_en` 等只承担触发作用的事件。

Agent 内部只使用自己的 In-event 名称，不能在 Detailed Condition 中引用上游 Agent 名称。以 IB 为例，IB 的 In-event 为 `fe_valid[s]`、`accept[s]` 和 `global_flush`；本地条件为 `enqueue[s].fire = fe_valid[s] ∧ IB_ready[s]`、`dequeue[s].fire = inst_valid[s] ∧ accept[s]`。集成层才记录 `dispatch_logic.accept[s] -> IB.accept[s]`；实现可以使用不同接口端点名承载该连接，但端点名不是新的 Event。

### In Static Info

列出由外部 Agent 提供的持续数据或视图。它们没有独立的 `fire`，但可以作为 Event fire 表达式的输入；它们本身不代表一次动作。

一个信号归入 `In Static Info` 必须满足：

1. 由其他 Agent 或顶层集成提供；
2. 被本 Agent 的数据通路、输出逻辑、组合读逻辑或 Event fire 表达式读取；
3. 数值可以每拍重新计算或变化，不表示一次发生的动作。

外部输入是否属于 `In-event`，取决于它是否是一个具有独立 `fire` 的动作端点；仅仅出现在状态转换或输出公式中，不会把持续值变成 Event。In Static Info 的产生者和跨 Agent 连接同样只在集成层记录。

典型对象包括组合数据视图、地址、配置、`valid`、`ready`、operand 状态、route 输入和只供 `Out Static Info` 使用的状态投影。`ready`、`select`、`route` 和未成交的 guard 即使参与 Event fire，仍是 Static Info；`accept` 表示接收或调度已经成立时，才定义为 Event。condition 内部由本 Agent 计算出的中间项不列为 Interface 信号。

判定例子：IB 的 `fe_valid[s]` 是携带 `IB_payload[s]` 的 In-event，`IB_ready[s]` 是 IB 自己产生的 Out Static Info，`enqueue[s].fire = fe_valid[s] ∧ IB_ready[s]`；IB 的 `accept[s]` 是下游发来的 In-event，`dequeue[s].fire = inst_valid[s] ∧ accept[s]`；IB 返回 FE 的 `accept[s]` 是独立的 Out-event，`accept[s].fire = enqueue[s].fire`。`dispatch_logic` 直接读取 `inst_valid[s]`，不把它改名为 `slot0_present`。组合读出的 `decode_payload[s]` 是 Out Static Info，不因 `dequeue` 而产生独立 fire。

条目格式：

```text
1. `info_name`：schema、位宽、数量；当前拍语义；读取位置或用途；有效性约束。
```

### Out-event

列出本 Agent 实际产生并驱动 Agent 边界外动作的 Event。Out-event 使用与 In-event 相同的条目格式；其 `fire`、payload schema 和时序在此归档。由 In-event 触发的本地状态更新只写在 FSM。有 FSM 时，Out-event 的 fire 必须引用对应的 State Transition/Detailed Condition；端点名可以不同，例如 `IB.accept.fire = IB.enqueue.fire`。（注意：`fire` 的“归档”不包含 fire 逻辑定义：有 FSM 时，Out-event 的 Fire来源 只能写“见 FSM -> Detailed Condition Description 第 N 条”，不得在本节写 fire 表达式或展开其依赖树。）

Out-event 的 payload 在 fire 时有效，payload 每个字段必须且只能在此定义一次取值，不得遗漏，也不得增加 schema 外字段。无论 Agent 是否有 FSM，每个 payload 字段的取值都必须按公式树逐级递归展开，直到每个终端名称都能在 `Data structure` 或本 Agent 的 `Interface` 中找到；已经在本 Agent 前文定义的名称只引用，不重复展开。每个 payload 字段公式下的所有直接来源都必须补充显式章节引用，格式为“见 `章节` 第 N 条”；该引用只标明来源位置，不重复展开已定义公式。

```text
1. `event_name`：Event 类型，索引变量定义
	- Fire来源：见 `FSM -> Detailed Condition Description` 第 N 条
	- Payload：`PayloadName`；时序。
	`PayloadName`：每个 payload 字段及其位宽 schema (只有一个字段时，直接在 `payload` 行写字段名、位宽、数量和时序，不另起 schema 行)
		- `field_1 = value_1`
			- `value_1`：引用来源。
		- `field_2 = expression_2`
			- （展开公式树直到能在 `Data structure` 或本 Agent 的 `Interface` 中找到）
```

例子（有 FSM）：

```text
1. `store_wakeup`：Notify，单 lane
	- Fire来源：见 `FSM -> Detailed Condition Description` 第 4 条
	- Payload：`store_wakeup_tag` 4 bit × 1；当拍 pulse
		- `store_wakeup_tag = ...`
			- ...
				- `some_leaf_signal_1`：见 `章节` 第 N 条。
2. `flush`：Notify，单 lane
	- Fire来源：见 `FSM -> Detailed Condition Description` 第 6 条
	- Payload：`CompletionScoreboard_flush_payload`；当拍 announce。
	`CompletionScoreboard_flush_payload`：`flush_tag` 4 bit × 1、`recovery_kind` 3 bit × 1
		- `flush_tag = ...`
			- ...
				- `some_leaf_signal_2`：见 `章节` 第 N 条。
		- `recovery_kind = ...`
			- ...
				- `some_leaf_signal_3`：见 `章节` 第 N 条。
```

无 FSM 时，有 fire 的组合事件（fire 条件组和逻辑、对应 payload 逐字段组合逻辑）必须在此定义并完整推导，此时 Out-event 条目 fire 条件下的直接依赖按公式树递归展开，直到已定义的 `Interface` 或 `Data structure`。`- Fire来源：...` 之后说明 Constraint。若存在 payload，在 `- Payload：...` 行下一级以 bullet 逐字段写出 `payload_field = signal`，并按公式树递归展开。带索引的 Event 若所有索引可由同一 fire 表达式和索引变量描述则不拆分，否则按索引拆分为多个 Out-event 条目。零 state Agent 没有 transition 时，Out-event 只在本节定义。

例子 （无FSM）：

```text
1. `accept[0]`：Notify，单 lane。
	- Fire来源：`accept[0].fire = inst_valid[0] ∧ slot0_guard_ok`
		- `inst_valid[0]`：见 `Interface -> In Static Info` 第 1 条。
		- `slot0_guard_ok = ...
			- ...
				- ...
					- ...（完整公式树）
			- ...（完整公式树）
	- Constraint：无额外约束。
	- Payload：∅；当前拍 pulse。
2. `accept[1]`：Notify，单 lane。
	- Fire来源：`accept[1].fire = accept[0] ∧ inst_valid[1] ∧ slot1_guard_ok`
		- `accept[0]`：见本节第 1 条 fire。
		- `inst_valid[1]`：见 `Interface -> In Static Info` 第 1 条。
		- `slot1_guard_ok = ...
			- ...
				- ...（完整公式树）
			- ...（完整公式树）
	- Constraint：`accept[1] -> accept[0]`。
	- Payload：∅；当前拍 pulse。
3. `serial_set_valid`：Notify，单 lane。
	- Fire来源：`serial_set_valid.fire = accept[0] ∧ serial0`
		- `accept[0]`：见本节第 1 条 fire。
		- `serial0`：见 `Interface -> In Static Info` 第 2 条。
	- Payload：`serial_set_tag`，`TAG_W` bit × 1；当前拍 pulse。
		- `serial_set_tag = self_tag`
			- `self_tag`：见 `Interface -> In Static Info` 第 17 条。
```

Out-event 必须由本 Agent 向外驱动。消费者的 In-event 即使会更新本地 state，也不在 Out-event 重复登记；例如 dispatch_logic 的 Out-event `accept[s]` 连到 IB 的 In-event `accept[s]`，IB 的 `dequeue[s]` 只写在 FSM。

### Out Static Info

列出本 Agent 对外持续提供、没有 `fire` 的值、资格、ready、选择、路由或数据视图。每项第一行写出 schema、位宽、索引变量定义和当前拍有效性；第二行开始用缩进 bullet 说明其产生式或引用关系：

```text
1. `info_name`：schema、位宽、索引变量定义；当前拍有效。
	- `info_name = expression`（组合逻辑必须显式写出推导式，若已在其他章节定义则引用）
		- `signal_name`：该信号的语义或来源；继续按依赖关系缩进展开
```

若产生式或依赖关系已在其他章节定义，直接写“见 `FSM` 第 N 条”“见 `Data structure` 第 N 条”或“见 `Interface` 第 N 条”，不重复展开；若尚未定义，则必须显式写出赋值或组合逻辑。组合逻辑的推导方法遵循本规则文档已有的公式树示例。

每个派生信号都必须继续缩进，直到其名称能够在 `Data structure` 或本 Agent 的 `Interface` 中找到。组合展开只能作为该条目的缩进内容，不能为 `slot0_guard_ok`、`read_data[0]` 等内部项另起标题。`IB_ready[s]`、`inst_valid[s]` 等只要没有独立 fire，都按此类归档；`accept[s]` 表示接收已发生时必须归入 `Out-event`。

示例：

1. `IB_ready[s]`：1 bit，`s∈{0,1}`；当前拍 IB 是否能接收 slot `s`。
	- `IB_ready[s] = free_slot >= (s + 1) ∧ ¬flush.fire`
		- `free_slot`：见 `Data structure` 第 1 条。
		- `flush.fire`：见 `FSM -> Detailed Condition Description` 第 2 条。

### Interface Timing

统一写时钟、复位、采样边沿、握手、背压、保持和取消规则：

```text
1. `clk`：时钟和采样边沿。
2. `rst_n`：复位极性、同步/异步属性及复位影响。
3. `Transaction`：valid/ready 或 credit 的采样规则。
4. `Notify`：fire 的采样规则及消费者接收约定。
5. `Static Info`：当前拍组合有效范围，以及 reset/flush 时的值或取消规则。
```

Interface 必须覆盖全文档所有外部读取信号和所有对外输出；名称、位宽、slot 数、payload schema 和时序在全文档中保持唯一且一致。
