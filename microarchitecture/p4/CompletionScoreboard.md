# Module `CompletionScoreboard`

`CompletionScoreboard`：以环形 tag 窗口保存最多 `ROB_DEPTH` 个在途指令，提供完成、提交、回滚和 store 授权。

## Submodule

无。

## FSM

### State

1. `FREE`：entry 不在环形区间 `[head_q, tail_q)` 内。
2. `NON_STORE_EXECUTING`：驻留的非 plain-store entry，`entry.exec_done=0`。
3. `NON_STORE_DONE`：驻留的非 plain-store entry，`entry.exec_done=1`。
4. `STORE_EXECUTING_UNAUTHORIZED`：驻留的 plain-store entry，`entry.exec_done=0`，且 `entry.st_br_resolve=0`、`entry.store_wakeup_issued=0`。
5. `STORE_EXECUTING_AUTHORIZED`：驻留的 plain-store entry，`entry.exec_done=0`，且 `entry.st_br_resolve=1` 或 `entry.store_wakeup_issued=1`。
6. `STORE_DONE_UNAUTHORIZED`：驻留的 plain-store entry，`entry.exec_done=1`，且 `entry.st_br_resolve=0`、`entry.store_wakeup_issued=0`。
7. `STORE_DONE_AUTHORIZED`：驻留的 plain-store entry，`entry.exec_done=1`，且 `entry.st_br_resolve=1` 或 `entry.store_wakeup_issued=1`。

### State Transition & Condition Name

1. `ANY -> FREE`：`reset`
2. `FREE -> NON_STORE_EXECUTING`、`FREE -> STORE_EXECUTING_UNAUTHORIZED`、`FREE -> STORE_EXECUTING_AUTHORIZED`：`alloc`
3. `NON_STORE_EXECUTING -> NON_STORE_DONE`、`STORE_EXECUTING_UNAUTHORIZED -> STORE_DONE_UNAUTHORIZED`、`STORE_EXECUTING_AUTHORIZED -> STORE_DONE_AUTHORIZED`：`writeback`
4. `STORE_EXECUTING_UNAUTHORIZED -> STORE_EXECUTING_AUTHORIZED`、`STORE_DONE_UNAUTHORIZED -> STORE_DONE_AUTHORIZED`：`store_wakeup`
5. `STORE_EXECUTING_UNAUTHORIZED -> STORE_EXECUTING_AUTHORIZED`、`STORE_DONE_UNAUTHORIZED -> STORE_DONE_AUTHORIZED`：`resolve_in_place`
6. `NON_STORE_DONE -> FREE`、`STORE_DONE_UNAUTHORIZED -> FREE`、`STORE_DONE_AUTHORIZED -> FREE`：`commit`
7. `NON_STORE_EXECUTING -> FREE`、`NON_STORE_DONE -> FREE`、`STORE_EXECUTING_UNAUTHORIZED -> FREE`、`STORE_EXECUTING_AUTHORIZED -> FREE`、`STORE_DONE_UNAUTHORIZED -> FREE`、`STORE_DONE_AUTHORIZED -> FREE`：`flush`

### Detailed Condition Description

1. `reset`：异步复位全部存储。
	- Fire来源：`reset.fire = ¬rst_n`
		- `rst_n`：见 `Interface -> In Static Info` 第 1 条。
	- Constraint：异步低有效复位。
	- Payload：∅。
	- State update：`head_q <- 0`；`tail_q <- 0`；对所有 `t∈{0,...,ROB_DEPTH-1}`，`entry.exec_done[t]`、`entry.store_wakeup_issued[t]`、`entry.header[t]`、`entry.event[t]` 和 `entry.payload[t]` 全部清零。
2. `alloc`：接收本拍分配的 entry 批次。
	- Fire来源：`alloc[s].fire = accept[s]`，`s∈{0,1}`
		- `accept[s]`：见 `Interface -> In-event` 第 1 条。
	- Constraint：外部保证分配不超过 `can_alloc_1/can_alloc_2` 所示容量并为并行分配提供不同的 `alloc_self_tag[s]`。
		- `is_store[s]=0` 时新 entry 为 `NON_STORE_EXECUTING`；`is_store[s]=1 ∧ st_br_resolve_alloc[s]=0` 时为 `STORE_EXECUTING_UNAUTHORIZED`；`is_store[s]=1 ∧ st_br_resolve_alloc[s]=1` 时为 `STORE_EXECUTING_AUTHORIZED`；同拍 `flush.fire` 时该 entry 不进入 live window。
	- Payload：`CompletionScoreboard_alloc_payload[s]`；上升沿采样。
	- State update：对每个 fire 的 `s`，`entry.header[alloc_self_tag[s]].{rd_idx,rd_is_fp,rd_write_enable,is_store,is_fence_i,may_flush,is_atomic} <- CompletionScoreboard_alloc_payload[s]`；`entry.header[alloc_self_tag[s]].st_br_resolve <- st_br_resolve_alloc[s]`；`entry.exec_done[alloc_self_tag[s]] <- 0`；`entry.store_wakeup_issued[alloc_self_tag[s]] <- 0`；无 `flush.fire` 时 `tail_q <- tail_q + alloc_count`。
		- `alloc_count = accept[0] + accept[1]`。
		- `st_br_resolve_alloc[0] = accept[0] ∧ is_store[0] ∧ prefix_safe_0`。
		- `st_br_resolve_alloc[1] = accept[1] ∧ is_store[1] ∧ prefix_safe_1`。
			- `prefix_safe_1 = prefix_safe_0 ∧ (¬accept[0] ∨ ¬may_flush[0])`。
		- `prefix_safe_0 = ∧{scan_safe[scan_tag(i)] | 0≤i<occupancy}`。
			- `scan_safe[t] = ¬entry.header[t].may_flush ∨ (entry.exec_done[t] ∧ ¬entry.event[t].exception_flag ∧ ¬entry.event[t].mispredict_flag ∧ ¬entry.event[t].is_mret ∧ ¬entry.event[t].is_sret ∧ ¬entry.header[t].is_fence_i)`。
				- `entry.header[t]`：见 `Data structure -> Header` 第 1 条。
				- `entry.exec_done[t]`：见 `Data structure -> State` 第 4 条。
				- `entry.event[t]`：见 `Data structure -> Header` 第 2 条。
			- `scan_tag(i) = head_q[TAG_W-1:0] + TAG_W'(i)`。
				- `head_q`：见 `Data structure -> State` 第 2 条。
			- `occupancy = tail_q - head_q`。
				- `tail_q`：见 `Data structure -> State` 第 3 条。
				- `head_q`：见 `Data structure -> State` 第 2 条。
		- `alloc_self_tag[s]` 及其余 payload 字段：见 `Interface -> In-event` 第 1 条。
3. `writeback`：捕获完成事件和执行结果。
	- Fire来源：`writeback[g].fire = writeback_valid[g] ∧ ¬global_flush_late`，`g∈{0,...,NUM_LANES-1}`。
		- `writeback_valid[g]`：见 `Interface -> In-event` 第 2 条。
		- `global_flush_late`：见 `Interface -> In-event` 第 3 条。
	- Constraint：并行 lane 的 `tag_out[g]` 互不相同。
	- Payload：`CompletionScoreboard_writeback_payload[g]`；上升沿采样。
	- State update：对每个 fire 的 `g`，`entry.exec_done[tag_out[g]] <- 1`；`entry.event[tag_out[g]] <- {mispredict_flag[g],exception_flag[g],is_mret[g],is_sret[g]}`；`entry.payload[tag_out[g]] <- {mispredict_target_pc[g],exception_cause[g],exception_tval[g],fpu_fflags[g]}`。
4. `store_wakeup`：向模块边界发出一个 plain-store 授权脉冲。
	- Fire来源：`store_wakeup.fire = wk_authorize ∧ ¬resolve_in_place`
		- `wk_authorize = wk_found ∧ wk_cand_ok ∧ ¬flush_decided ∧ ¬wb_hits_wakeup_tag`
			- `wk_found = ∃i∈{0,...,ROB_DEPTH-1}: scan_live(i) ∧ scan_is_cand[scan_tag(i)]`
				- `scan_live(i) = ROB_PTR_W'(i) < occupancy`
					- `occupancy`：见本节第 2 条 `prefix_safe_0` 公式。
				- `scan_is_cand[t] = entry.header[t].is_store ∧ ¬entry.header[t].st_br_resolve ∧ ¬entry.store_wakeup_issued[t]`
					- `entry.header[t]`：见 `Data structure -> Header` 第 1 条。
					- `entry.store_wakeup_issued[t]`：见 `Data structure -> State` 第 5 条。
				- `scan_tag(i)`：见本节第 2 条 `prefix_safe_0` 公式。
			- `wk_tag = scan_tag(min{i | scan_live(i) ∧ scan_is_cand[scan_tag(i)]})`；无候选时为 0。
				- `scan_live(i)`、`scan_is_cand[t]`、`scan_tag(i)`：见本条 `wk_found` 公式。
			- `wk_cand_ok = wk_prefix_safe ∧ ¬(entry.exec_done[wk_tag] ∧ entry.event[wk_tag].exception_flag)`；无候选时为 0。
				- `wk_prefix_safe = ∧{scan_safe[scan_tag(j)] | 0≤j<i_wk}`，`i_wk` 为 `wk_tag` 的扫描 offset。
					- `scan_safe[t]`：见本节第 2 条 `prefix_safe_0` 公式。
					- `scan_tag(j)`：见本条 `wk_found` 公式。
				- `entry.exec_done[wk_tag]`：见 `Data structure -> State` 第 4 条。
				- `entry.event[wk_tag]`：见 `Data structure -> Header` 第 2 条。
			- `flush_decided = head0_done ∧ (h0_exception ∨ interrupt_at_boundary ∨ (¬interrupt_at_boundary ∧ h0_flush_after_commit) ∨ (head1_eval ∧ head1_done ∧ (h1_exception ∨ h1_is_fence_i ∨ h1_mispredict)))`
				- `head0_done = head0_valid ∧ entry.exec_done[head_tag[0]]`
					- `head0_valid = occupancy ≥ 1`
						- `occupancy`：见本条 `wk_found` 公式。
					- `entry.exec_done`：见 `Data structure -> State` 第 4 条。
					- `head_tag[0]`：见 `Interface -> Out Static Info` 第 1 条。
				- `h0_exception = entry.event[head_tag[0]].exception_flag`
					- `entry.event`：见 `Data structure -> Header` 第 2 条。
					- `head_tag[0]`：见 `Interface -> Out Static Info` 第 1 条。
				- `interrupt_at_boundary = interrupt_take ∧ interrupt_boundary_ok`
					- `interrupt_take = interrupt_pending ∧ ¬any_plain_store_authorized_live`
						- `interrupt_pending`：见 `Interface -> In Static Info` 第 2 条。
						- `any_plain_store_authorized_live = ∨{entry.header[scan_tag(i)].is_store ∧ (entry.header[scan_tag(i)].st_br_resolve ∨ entry.store_wakeup_issued[scan_tag(i)]) | scan_live(i)}`
							- `entry.header`：见 `Data structure -> Header` 第 1 条。
							- `entry.store_wakeup_issued`：见 `Data structure -> State` 第 5 条。
							- `scan_tag(i)`、`scan_live(i)`：见本条 `wk_found` 公式。
					- `interrupt_boundary_ok = ¬head0_irrevocable ∨ head1_valid`
						- `head0_irrevocable = head0_done ∧ ¬h0_exception ∧ (entry.header[head_tag[0]].is_store ∨ entry.header[head_tag[0]].is_atomic)`
							- `head0_done`、`h0_exception`：见本条前述公式。
							- `entry.header`：见 `Data structure -> Header` 第 1 条。
						- `head1_valid = occupancy ≥ 2`
							- `occupancy`：见本条 `wk_found` 公式。
				- `h0_flush_after_commit = h0_is_mret ∨ h0_is_sret ∨ h0_is_fence_i ∨ h0_mispredict`
					- `h0_is_mret/h0_is_sret/h0_mispredict = entry.event[head_tag[0]].{is_mret,is_sret,mispredict_flag}`
						- `entry.event`：见 `Data structure -> Header` 第 2 条。
						- `head_tag[0]`：见 `Interface -> Out Static Info` 第 1 条。
					- `h0_is_fence_i = entry.header[head_tag[0]].is_fence_i`
						- `entry.header`：见 `Data structure -> Header` 第 1 条。
						- `head_tag[0]`：见 `Interface -> Out Static Info` 第 1 条。
				- `head1_eval = head0_done ∧ ¬h0_exception ∧ ¬interrupt_at_boundary ∧ ¬h0_flush_after_commit`
					- `head0_done`、`h0_exception`、`interrupt_at_boundary`、`h0_flush_after_commit`：见本条前述公式。
				- `head1_done = head1_valid ∧ entry.exec_done[head_tag[1]]`
					- `head1_valid`：见本条 `interrupt_boundary_ok` 公式。
					- `entry.exec_done`：见 `Data structure -> State` 第 4 条。
					- `head_tag[1]`：见 `Interface -> Out Static Info` 第 1 条。
				- `h1_exception/h1_mispredict = entry.event[head_tag[1]].{exception_flag,mispredict_flag}`
					- `entry.event`：见 `Data structure -> Header` 第 2 条。
					- `head_tag[1]`：见 `Interface -> Out Static Info` 第 1 条。
				- `h1_is_fence_i = entry.header[head_tag[1]].is_fence_i`
					- `entry.header`：见 `Data structure -> Header` 第 1 条。
					- `head_tag[1]`：见 `Interface -> Out Static Info` 第 1 条。
			- `wb_hits_wakeup_tag = ∃g: writeback_valid[g] ∧ ¬global_flush_late ∧ (tag_out[g]=wk_tag)`
				- `writeback_valid[g]`、`tag_out[g]`：见 `Interface -> In-event` 第 2 条。
				- `global_flush_late`：见 `Interface -> In-event` 第 3 条。
		- `resolve_in_place`：见本节第 5 条。
	- Constraint：每拍至多一个；与 `resolve_in_place` 互斥。
	- Payload：`store_wakeup_tag` `TAG_W` bit × 1；当拍 pulse。
	- State update：`entry.store_wakeup_issued[wk_tag] <- 1`。
5. `resolve_in_place`：候选 store 仍驻留于 `st_br_resolve` 读地址时就地授权。
	- Fire来源：`resolve_in_place.fire = wk_authorize ∧ st_br_resolve_tag_valid ∧ (st_br_resolve_tag=wk_tag)`
		- `wk_authorize`：见本节第 4 条。
		- `st_br_resolve_tag_valid`：见 `Interface -> In Static Info` 第 4 条。
		- `st_br_resolve_tag`：见 `Interface -> In Static Info` 第 3 条。
	- Constraint：与 `store_wakeup.fire` 互斥。
	- Payload：∅。
	- State update：`entry.header[wk_tag].st_br_resolve <- 1`。
6. `commit`：按顺序提交零至两个 head entry。
	- Fire来源：`commit[k].fire = commit_valid[k]`，`k∈{0,1}`
		- `commit_valid[0] = head0_done ∧ ¬h0_exception ∧ (¬(interrupt_take ∧ interrupt_boundary_ok) ∨ head0_irrevocable)`
			- `head0_done`、`h0_exception`、`interrupt_take`、`interrupt_boundary_ok`、`head0_irrevocable`：见本节第 4 条 `flush_decided` 公式。
		- `commit_valid[1] = head1_eval ∧ head1_done ∧ ¬h1_exception ∧ ¬(h0_fp_write ∧ h1_fp_write)`
			- `head1_eval`、`head1_done`、`h1_exception`：见本节第 4 条 `flush_decided` 公式。
			- `h0_fp_write = entry.header[head_tag[0]].rd_write_enable ∧ entry.header[head_tag[0]].rd_is_fp`；`h1_fp_write = entry.header[head_tag[1]].rd_write_enable ∧ entry.header[head_tag[1]].rd_is_fp`
				- `entry.header`：见 `Data structure -> Header` 第 1 条。
				- `head_tag[k]`：见 `Interface -> Out Static Info` 第 1 条。
	- Constraint：`commit[1].fire -> commit[0].fire`；双 FP destination write 时仅提交 head0。
	- Payload：`CompletionScoreboard_commit_payload[k]`；当拍 announce。
	- State update：`head_q <- head_q + commit_count`；若同拍没有 `flush.fire`，`tail_q <- tail_q + alloc_count`；entry 数组字段保持，离开 `[head_q,tail_q)` 后语义为 `FREE`。
		- `commit_count = commit_valid[0] + commit_valid[1]`。
		- `alloc_count`：见本节第 2 条。
7. `flush`：按提交结果落地 head 后回滚全部剩余 entry。
	- Fire来源：`flush.fire = flush_valid`
		- `flush_valid = flush_decided ∧ ¬(flush_from_head1_commit ∧ h0_fp_write ∧ h1_fp_write)`
			- `flush_decided`：见本节第 4 条。
			- `flush_from_head1_commit = head1_eval ∧ head1_done ∧ ¬h1_exception ∧ (h1_is_fence_i ∨ h1_mispredict)`
				- `head1_eval`、`head1_done`、`h1_exception`、`h1_is_fence_i`、`h1_mispredict`：见本节第 4 条 `flush_decided` 公式。
			- `h0_fp_write`、`h1_fp_write`：见本节第 6 条。
	- Constraint：exception 优先于 interrupt；interrupt 优先于 head0 的 MRET、SRET、FENCE.I 和 mispredict；head1 只在 head0 普通提交后评估；双 FP block 可推迟 head1 的 commit-then-flush。
	- Payload：`CompletionScoreboard_flush_payload`；当拍 announce。
	- State update：`head_q <- head_q + commit_count`；`tail_q <- head_q + commit_count`；entry 数组字段保持，回滚 entry 离开 live window 后语义为 `FREE`。

## Data structure

### State

1. `FREE / NON_STORE_EXECUTING / NON_STORE_DONE / STORE_EXECUTING_UNAUTHORIZED / STORE_EXECUTING_AUTHORIZED / STORE_DONE_UNAUTHORIZED / STORE_DONE_AUTHORIZED`：entry 语义状态压缩进 `head_q`、`tail_q`、`entry.exec_done[t]`、`entry.store_wakeup_issued[t]`、`entry.header[t].is_store` 和 `entry.header[t].st_br_resolve`；live 区间为 `[head_q,tail_q)`。
2. `head_q`：`ROB_PTR_W` bit，编码为 `{loopbit,index[TAG_W-1:0]}`；`ROB_DEPTH=16`、`TAG_W=4`、`ROB_PTR_W=5`；由 `commit` 和 `flush` 更新。
3. `tail_q`：`ROB_PTR_W` bit，编码为 `{loopbit,index[TAG_W-1:0]}`；由 `alloc` 和 `flush` 更新。
4. `entry.exec_done[t]`：1 bit × `ROB_DEPTH`；由 `writeback` 置 1，由 `alloc` 清 0。
5. `entry.store_wakeup_issued[t]`：1 bit × `ROB_DEPTH`；由 `store_wakeup` 置 1，由 `alloc` 清 0。

### Header

1. `entry.header[t]`：`rd_idx` `REG_ADDR_W` bit、`rd_is_fp` 1 bit、`rd_write_enable` 1 bit、`is_store` 1 bit、`is_fence_i` 1 bit、`may_flush` 1 bit、`is_atomic` 1 bit、`st_br_resolve` 1 bit；由 `alloc` 写入，`st_br_resolve` 还可由 `resolve_in_place` 置 1。
2. `entry.event[t]`：`mispredict_flag` 1 bit、`exception_flag` 1 bit、`is_mret` 1 bit、`is_sret` 1 bit；由 `writeback` 写入，仅在 `entry.exec_done[t]=1` 时参与 retire 决策。

### Payload

1. `entry.payload[t]`：来源于多个 event payload。
	- `CompletionScoreboard_alloc_payload[s]`：`rd_idx`、`rd_is_fp`、`rd_write_enable`、`is_store`、`is_fence_i`、`may_flush`、`is_atomic`。
	- `CompletionScoreboard_writeback_payload[g]`：`mispredict_target_pc`、`exception_cause`、`exception_tval`、`fpu_fflags`。

## Internal Connections

无。

## Interface

### In-event

1. `accept[s]`：Notify，`s∈{0,...,ISSUE_WIDTH-1}`。
	- Fire来源：`accept[s].fire`。
	- Payload：`CompletionScoreboard_alloc_payload[s]`；上升沿采样。
	`CompletionScoreboard_alloc_payload[s]`：`alloc_self_tag` `TAG_W` bit、`rd_idx` `REG_ADDR_W` bit、`rd_is_fp` 1 bit、`rd_write_enable` 1 bit、`is_store` 1 bit、`is_fence_i` 1 bit、`may_flush` 1 bit、`is_atomic` 1 bit。
2. `writeback_valid[g]`：Notify，`g∈{0,...,NUM_LANES-1}`。
	- Fire来源：`writeback_valid[g].fire`。
	- Payload：`CompletionScoreboard_writeback_payload[g]`；上升沿采样。
	`CompletionScoreboard_writeback_payload[g]`：`tag_out` `TAG_W` bit、`mispredict_flag` 1 bit、`mispredict_target_pc` `XLEN` bit、`exception_flag` 1 bit、`exception_cause` `EXCP_CAUSE_W` bit、`exception_tval` `XLEN` bit、`is_mret` 1 bit、`is_sret` 1 bit、`fpu_fflags` `FFLAGS_W` bit。
3. `global_flush_late`：Notify，单 bit；当拍抑制 writeback 捕获。
	- Fire来源：`global_flush_late.fire`。
	- Payload：∅。

### In Static Info

1. `rst_n`：1 bit；低有效异步复位输入。
2. `interrupt_pending`：1 bit；当前拍待处理外部中断条件。
3. `st_br_resolve_tag`：`TAG_W` bit；ISQ3 当前驻留 entry 的 resolve 读地址。
4. `st_br_resolve_tag_valid`：1 bit；`st_br_resolve_tag` 当前拍有效。

### Out-event

1. `commit_valid[k]`：Notify，`k∈{0,...,ISSUE_WIDTH-1}`。
	- Fire来源：见 `FSM -> Detailed Condition Description` 第 6 条。
	- Payload：`CompletionScoreboard_commit_payload[k]`；当拍 announce。
	`CompletionScoreboard_commit_payload[k]`：`commit_tag` `TAG_W` bit、`commit_rd_idx` `REG_ADDR_W` bit、`commit_rd_is_fp` 1 bit、`commit_rd_write_enable` 1 bit、`commit_fflags` `FFLAGS_W` bit。
		- `commit_tag[k] = commit_valid[k] ? head_tag[k] : 0`
			- `commit_valid[k]`：见 `FSM -> Detailed Condition Description` 第 6 条。
			- `head_tag[k]`：见 `Interface -> Out Static Info` 第 1 条。
		- `commit_rd_idx[k] = entry.header[head_tag[k]].rd_idx`
			- `entry.header`：见 `Data structure -> Header` 第 1 条。
			- `head_tag[k]`：见 `Interface -> Out Static Info` 第 1 条。
		- `commit_rd_is_fp[k] = entry.header[head_tag[k]].rd_is_fp`
			- `entry.header`：见 `Data structure -> Header` 第 1 条。
			- `head_tag[k]`：见 `Interface -> Out Static Info` 第 1 条。
		- `commit_rd_write_enable[k] = entry.header[head_tag[k]].rd_write_enable`
			- `entry.header`：见 `Data structure -> Header` 第 1 条。
			- `head_tag[k]`：见 `Interface -> Out Static Info` 第 1 条。
		- `commit_fflags[k] = entry.payload[head_tag[k]].fpu_fflags`
			- `entry.payload`：见 `Data structure -> Payload` 第 1 条。
			- `head_tag[k]`：见 `Interface -> Out Static Info` 第 1 条。
2. `store_wakeup_valid`：Notify，单 lane。
	- Fire来源：见 `FSM -> Detailed Condition Description` 第 4 条。
	- Payload：`store_wakeup_tag` `TAG_W` bit × 1；当拍 pulse。
		- `store_wakeup_tag = wk_tag`
			- `wk_tag`：见 `FSM -> Detailed Condition Description` 第 4 条。
3. `flush_valid`：Notify，单 lane。
	- Fire来源：见 `FSM -> Detailed Condition Description` 第 7 条。
	- Payload：`CompletionScoreboard_flush_payload`；当拍 announce。
	`CompletionScoreboard_flush_payload`：`flush_tag` `TAG_W` bit、`recovery_kind` `RECOVERY_KIND_W` bit。
		- `flush_tag = h0_exception ? head_tag[0] : (interrupt_take ∧ interrupt_boundary_ok) ? (head0_irrevocable ? head_tag[1] : head_tag[0]) : (h0_is_mret ∨ h0_is_sret ∨ h0_is_fence_i ∨ h0_mispredict) ? head_tag[0] : head_tag[1]`
			- `h0_exception`、`interrupt_take`、`interrupt_boundary_ok`、`head0_irrevocable`、`h0_is_mret`、`h0_is_sret`、`h0_is_fence_i`、`h0_mispredict`：见 `FSM -> Detailed Condition Description` 第 4 条 `flush_decided` 公式。
			- `head_tag[k]`：见 `Interface -> Out Static Info` 第 1 条。
		- `recovery_kind = h0_exception ? RECOVERY_EXCEPTION : (interrupt_take ∧ interrupt_boundary_ok) ? RECOVERY_INTERRUPT : h0_is_mret ? RECOVERY_MRET : h0_is_sret ? RECOVERY_SRET : h0_is_fence_i ? RECOVERY_FENCE_I : h0_mispredict ? RECOVERY_MISPREDICT : h1_exception ? RECOVERY_EXCEPTION : h1_is_fence_i ? RECOVERY_FENCE_I : RECOVERY_MISPREDICT`
			- `h0_exception`、`interrupt_take`、`interrupt_boundary_ok`、`h0_is_mret`、`h0_is_sret`、`h0_is_fence_i`、`h0_mispredict`、`h1_exception`、`h1_is_fence_i`：见 `FSM -> Detailed Condition Description` 第 4 条 `flush_decided` 公式。
			- `RECOVERY_EXCEPTION`、`RECOVERY_INTERRUPT`、`RECOVERY_MRET`、`RECOVERY_SRET`、`RECOVERY_FENCE_I`、`RECOVERY_MISPREDICT`：`RECOVERY_KIND_W` bit 编码常量。

### Out Static Info

1. `head_tag[k]`：`TAG_W` bit × `ISSUE_WIDTH`，`k∈{0,1}`；当前拍有效。
	- `head_tag[0] = head_q[TAG_W-1:0]`；`head_tag[1] = head_q[TAG_W-1:0] + TAG_W'(1)`
		- `head_q`：见 `Data structure -> State` 第 2 条。
2. `recovery_mispredict_target_pc`：`XLEN` bit；持续组合驱动，`flush_valid.fire` 时作为 recovery payload 有效。
	- `recovery_mispredict_target_pc = entry.payload[flush_tag].mispredict_target_pc`
		- `entry.payload`：见 `Data structure -> Payload` 第 1 条。
		- `flush_tag`：见 `Interface -> Out-event` 第 3 条。
3. `recovery_exception_cause`：`EXCP_CAUSE_W` bit；持续组合驱动，`flush_valid.fire` 时作为 recovery payload 有效。
	- `recovery_exception_cause = entry.payload[flush_tag].exception_cause`
		- `entry.payload`：见 `Data structure -> Payload` 第 1 条。
		- `flush_tag`：见 `Interface -> Out-event` 第 3 条。
4. `recovery_exception_tval`：`XLEN` bit；持续组合驱动，`flush_valid.fire` 时作为 recovery payload 有效。
	- `recovery_exception_tval = entry.payload[flush_tag].exception_tval`
		- `entry.payload`：见 `Data structure -> Payload` 第 1 条。
		- `flush_tag`：见 `Interface -> Out-event` 第 3 条。
5. `st_br_resolve`：1 bit；当前拍有效。
	- `st_br_resolve = entry.header[st_br_resolve_tag].st_br_resolve ∨ (resolve_in_place ∧ (st_br_resolve_tag=wk_tag))`
		- `entry.header`：见 `Data structure -> Header` 第 1 条。
		- `st_br_resolve_tag`：见 `Interface -> In Static Info` 第 3 条。
		- `resolve_in_place`：见 `FSM -> Detailed Condition Description` 第 5 条。
		- `wk_tag`：见 `FSM -> Detailed Condition Description` 第 4 条。
6. `scoreboard_valid_bits`：`ROB_DEPTH` bit；当前拍有效。
	- `scoreboard_valid_bits[head_q[TAG_W-1:0]+TAG_W'(i)] = (ROB_PTR_W'(i) < occupancy)`，`i∈{0,...,ROB_DEPTH-1}`
		- `head_q`：见 `Data structure -> State` 第 2 条。
		- `occupancy`：见 `FSM -> Detailed Condition Description` 第 2 条 `prefix_safe_0` 公式。
7. `scoreboard_exec_done_bits`：`ROB_DEPTH` bit；当前拍有效。
	- `scoreboard_exec_done_bits[t] = entry.exec_done[t]`，`t∈{0,...,ROB_DEPTH-1}`
		- `entry.exec_done`：见 `Data structure -> State` 第 4 条。
8. `Buffer_tail`：`TAG_W` bit；当前拍有效。
	- `Buffer_tail = tail_q[TAG_W-1:0]`
		- `tail_q`：见 `Data structure -> State` 第 3 条。
9. `can_alloc_1`：1 bit；当前拍有效。
	- `can_alloc_1 = (occupancy ≤ ROB_DEPTH-1)`
		- `occupancy`：见 `FSM -> Detailed Condition Description` 第 2 条 `prefix_safe_0` 公式。
		- `ROB_DEPTH`：见 `Data structure -> State` 第 2 条。
10. `can_alloc_2`：1 bit；当前拍有效。
	- `can_alloc_2 = (occupancy ≤ ROB_DEPTH-2)`
		- `occupancy`：见 `FSM -> Detailed Condition Description` 第 2 条 `prefix_safe_0` 公式。
		- `ROB_DEPTH`：见 `Data structure -> State` 第 2 条。
11. `buffer_empty`：1 bit；当前拍有效。
	- `buffer_empty = (occupancy=0)`
		- `occupancy`：见 `FSM -> Detailed Condition Description` 第 2 条 `prefix_safe_0` 公式。
12. `commit_count`：`COMMIT_COUNT_W` bit，取值 `0..ISSUE_WIDTH`；当前拍有效。
	- `commit_count = {1'b0,commit_valid[0]} + {1'b0,commit_valid[1]}`
		- `commit_valid[k]`：见 `Interface -> Out-event` 第 1 条。

### Interface Timing

1. `clk`：所有非复位状态在上升沿更新。
2. `rst_n`：低有效异步复位；`rst_n=0` 时异步清零指针和全部 entry 存储。
3. `Transaction`：无。
4. `Notify`：`accept[s]`、`writeback_valid[g]` 和 `global_flush_late` 在 fire 所在拍采样；输出 Notify 为当前拍组合 pulse，消费者必须在该拍接收；本模块不提供背压，分配方必须遵守 `can_alloc_1` 和 `can_alloc_2`；双 FP block 推迟 head1 commit-then-flush 时，`flush_decided` 为真，仍取消同拍 store 授权输出；上升沿内同一 entry 字段的更新优先级依次为 writeback、store_wakeup、resolve_in_place、alloc，后者覆盖前者。
5. `Static Info`：由拍初寄存状态和当前拍输入组合产生；复位期间寄存状态为 0，`global_flush_late` 只取消同拍 writeback 捕获，不取消其他组合输出。

