# Module `IB`

`IB`：8-entry、2-lane 的有序前端指令 FIFO（`IB_DEPTH=8`、`ISSUE_WIDTH=2`、`IB_PTR_W=4`、`IB_IDX_W=IB_PTR_W-1=3`）。

## Submodule

无。

## FSM

### State

1. `IDLE`：物理 entry 不在 FIFO 有效区间内，其 payload 不表示有效指令。
2. `RESIDENT`：物理 entry 在 FIFO 有效区间内，保存一条尚未出队的 `ib_payload_t`。

### State Transition & Condition Name

1. `ANY -> IDLE`：`reset`
2. `RESIDENT -> IDLE`：`flush`
3. `IDLE -> RESIDENT`：`enqueue[s]`
4. `RESIDENT -> IDLE`：`dequeue[s]`

### Detailed Condition Description

1. `reset`：复位 FIFO 指针和 payload 存储。
	- Fire来源：`reset.fire = ¬rst_n`
		- `rst_n`：低有效复位输入，见 `Interface -> In Static Info` 第 1 条。
	- Constraint：异步复位；复位优先于其他动作。
	- Payload：`∅`；复位有效时立即生效。
	- State update：`wptr_q <- 0`、`rptr_q <- 0`；对所有 `i∈{0,...,IB_DEPTH-1}`，`entry.payload[i] <- 0`。
2. `flush`：清空 FIFO 的逻辑有效区间。
	- Fire来源：`flush.fire = global_flush_late.fire`
		- `global_flush_late.fire`：见 `Interface -> In-event` 第 3 条。
	- Constraint：复位释放后，在时钟上升沿执行；优先于 enqueue 和 dequeue 的指针更新；flush 不修改 `entry.payload`。
	- Payload：`∅`；当拍 pulse。
	- State update：`wptr_q <- 0`、`rptr_q <- 0`；`entry.payload` 保持。
3. `enqueue[s]`：接收 slot `s` 的前端指令 payload。
	- Fire来源：`enqueue[s].fire = fe_valid[s] ∧ fe_ready[s]`
		- `fe_valid[s]`：见 `Interface -> In-event` 第 1 条。
		- `fe_ready[s]`：见 `Interface -> Out Static Info` 第 3 条。
	- Constraint：`s∈{0,1}`；`enqueue[1].fire -> enqueue[0].fire`，fire 向量只能为 `00`、`01`、`11`；`flush.fire` 时无 enqueue fire。
	- Payload：`enq_IB_Payload[s]`；时钟上升沿采样。
	- State update：对每个 fire 的 `s`，`entry.payload[(wptr_idx+s) mod IB_DEPTH] <- enq_IB_Payload[s]`；非 flush 拍 `wptr_q <- wptr_q + enq_count`；`wptr_idx = wptr_q[IB_IDX_W-1:0]`；`enq_count` 为 2 bit、取值 `0..ISSUE_WIDTH`，`enq_count = enqueue[0].fire + enqueue[1].fire`。
4. `dequeue[s]`：消费当前队头 slot `s`。
	- Fire来源：`dequeue[s].fire = inst_valid[s] ∧ accept[s].fire`
		- `inst_valid[s]`：当前队头 slot `s` 的有效标志，见 `Interface -> Out Static Info` 第 2 条。
		- `accept[s].fire`：见 `Interface -> In-event` 第 2 条。
	- Constraint：`s∈{0,1}`；`accept[1].fire -> accept[0].fire`，因此 dequeue fire 向量只能为 `00`、`01`、`11`；`flush.fire` 与 `dequeue[s].fire` 同拍时由 flush 的指针更新覆盖 dequeue 的指针更新。
	- Payload：`∅`；时钟上升沿采样。
	- State update：非 flush 拍 `rptr_q <- rptr_q + deq_count`；`deq_count` 为 2 bit、取值 `0..ISSUE_WIDTH`，`deq_count = dequeue[0].fire + dequeue[1].fire`；`entry.payload` 不修改。

## Data structure

### State

1. `IDLE / RESIDENT`：每个物理 entry 的语义状态；压缩进 `wptr_q`、`rptr_q`，有效 entry 是环形区间 `[rptr_q,wptr_q)`；entry 不跳洞、不重排。
2. `wptr_q`：`IB_PTR_W` bit 环形写指针 `{loopbit,index[IB_IDX_W-1:0]}`，容量为 `IB_DEPTH` 个 entry；低 `IB_IDX_W` bit 指向下一可写 entry；由 `enqueue[s]` 更新，由 `reset` 和 `flush` 清零。
3. `rptr_q`：`IB_PTR_W` bit 环形读指针 `{loopbit,index[IB_IDX_W-1:0]}`；低 `IB_IDX_W` bit 指向当前队头 entry；由 `dequeue[s]` 更新，由 `reset` 和 `flush` 清零。

### Header

无。

### Payload

1. `entry.payload[i]`：来源于 `enq_IB_Payload[s]`，`i∈{0,...,IB_DEPTH-1}`。
	- `enq_IB_Payload[s]`：`pc`、`inst_bits`、`is_compressed`、`pred_taken`、`pred_target_pc`、`fetch_excp_vld`、`fetch_excp_cause`、`fetch_excp_tval`。

## Internal Connections

无。

## Interface

### In-event

1. `fe_valid[s]`：Transaction，`s∈{0,1}`
	- Fire来源：见 `FSM -> Detailed Condition Description` 第 3 条。
	- Payload：`enq_IB_Payload`；时钟上升沿采样。
	`enq_IB_Payload`：`pc` 64 bit × 2、`inst_bits` 32 bit × 2、`is_compressed` 1 bit × 2、`pred_taken` 1 bit × 2、`pred_target_pc` 64 bit × 2、`fetch_excp_vld` 1 bit × 2、`fetch_excp_cause` 5 bit × 2、`fetch_excp_tval` 64 bit × 2。
2. `accept[s]`：Notify，`s∈{0,1}`
	- Fire来源：`accept[s].fire`。
	- Payload：`∅`；当拍 pulse。
3. `global_flush_late`：Notify，单 lane
	- Fire来源：`global_flush_late.fire`。
	- Payload：`∅`；当拍 pulse。

### In Static Info

1. `rst_n`：1 bit；低有效异步复位输入；被 `reset.fire` 读取。

### Out-event

无。

### Out Static Info

1. `head_IB_Payload[s]`：`ib_payload_t`，232 bit × 2，`s∈{0,1}`；当前拍队头连续两个 entry 的组合读值，仅在对应 `inst_valid[s]=1` 时表示有效指令。
	- `head_IB_Payload[s] = entry.payload[(rptr_idx+s) mod IB_DEPTH]`
		- `entry.payload[(rptr_idx+s) mod IB_DEPTH]`：见 `Data structure -> Payload` 第 1 条。
		- `rptr_idx = rptr_q[IB_IDX_W-1:0]`
			- `rptr_q`：见 `Data structure -> State` 第 3 条。
			- `IB_IDX_W`：见文档头部定义。
		- `IB_DEPTH`：见文档头部定义。
2. `inst_valid[s]`：1 bit × 2，`s∈{0,1}`；当前拍队头 slot `s` 是否位于 FIFO 有效区间。
	- `inst_valid[s] = (s < valid_count)`
		- `valid_count`：`IB_PTR_W` bit、取值 `0..IB_DEPTH` 的拍初 occupancy；`valid_count = (wptr_q - rptr_q) mod 2^IB_PTR_W`
			- `wptr_q`：见 `Data structure -> State` 第 2 条。
			- `rptr_q`：见 `Data structure -> State` 第 3 条。
			- `IB_PTR_W`：见文档头部定义。
3. `fe_ready[s]`：1 bit × 2，`s∈{0,1}`；当前拍 slot `s` 的接收资格。
	- `fe_ready[0] = (free_slot >= 1) ∧ ¬global_flush_late.fire`
		- `free_slot = IB_DEPTH - occupancy_after_deq`
			- `IB_DEPTH`：见文档头部定义。
			- `occupancy_after_deq = valid_count - deq_count`
				- `valid_count`：见本节第 2 条。
				- `deq_count`：见 `FSM -> Detailed Condition Description` 第 4 条。
		- `global_flush_late.fire`：见 `Interface -> In-event` 第 3 条。
	- `fe_ready[1] = fe_valid[0] ∧ (free_slot >= ISSUE_WIDTH) ∧ ¬global_flush_late.fire`
		- `fe_valid[0]`：见 `Interface -> In-event` 第 1 条。
		- `free_slot`：见本条 `fe_ready[0]` 公式。
		- `ISSUE_WIDTH`：见文档头部定义。
		- `global_flush_late.fire`：见 `Interface -> In-event` 第 3 条。
4. `accepted_slot[s]`：1 bit × 2，`s∈{0,1}`；当前拍实际完成的前端入队 Transaction；合法向量为 `00`、`01`、`11`。
	- `accepted_slot[s] = enqueue[s].fire`
		- `enqueue[s].fire`：见 `FSM -> Detailed Condition Description` 第 3 条。

### Interface Timing

1. `clk`：所有同步状态和 enqueue payload 均在上升沿采样和更新。
2. `rst_n`：低有效异步复位；有效时立即清零 `wptr_q`、`rptr_q` 和全部 `entry.payload`。
3. `Transaction`：`fe_valid[s]` 与 `fe_ready[s]` 在同一拍完成握手；仅 `enqueue[s].fire` 的 payload 在上升沿写入；未完成握手的 valid 和 payload 由生产者保持；同拍 dequeue 释放的容量计入 `fe_ready`。
4. `Notify`：`accept[s]` 和 `global_flush_late` 在当前拍形成事件并于上升沿影响状态；Notify 无 ready、背压或保持要求；flush 的指针更新优先于 dequeue。
5. `Static Info`：`head_IB_Payload[s]`、`inst_valid[s]`、`fe_ready[s]` 和 `accepted_slot[s]` 均为当前拍组合值；`head_IB_Payload[s]` 不受 `accept[s].fire` 门控；`global_flush_late.fire` 时 `fe_ready=00`、`accepted_slot=00`，时钟沿后 `inst_valid=00`；`rst_n=0` 时 reset 覆盖同步状态更新，组合输出仍按各自产生式计算。
