# Module `lsu_bridge`

`lsu_bridge`：LSU issue、store wakeup、终端 writeback 和 bypass 的桥接模块；按 `TAG_W` tag 维护在飞请求及终端侧状态。

## Submodule

无。

## FSM

### State

1. `REQ_IDLE[t]`：`req_in_flight_q[t]=0`，tag `t` 没有尚未终结的 LSU 请求。
2. `REQ_IN_FLIGHT[t]`：`req_in_flight_q[t]=1`，tag `t` 的请求已被 LSU 接受且尚未收到 terminal。
3. `WAKEUP_EMPTY[t]`：`wakeup_held_q[t]=0`，tag `t` 没有待发射的 store wakeup 授权。
4. `WAKEUP_HELD[t]`：`wakeup_held_q[t]=1`，tag `t` 的 store wakeup 授权等待该 tag 发射时转发。
5. `READ_NOT_DONE[t]`：`read_done_q[t]=0`，tag `t` 尚未记录 read-side 完成。
6. `READ_DONE[t]`：`read_done_q[t]=1`，tag `t` 已记录 read-side 完成。
7. `STORE_NOT_DONE[t]`：`store_done_q[t]=0`，tag `t` 尚未记录 LSU done。
8. `STORE_DONE[t]`：`store_done_q[t]=1`，tag `t` 已记录 LSU done。

### State Transition & Condition Name

1. `ANY -> REQ_IDLE`、`ANY -> WAKEUP_EMPTY`、`ANY -> READ_NOT_DONE`、`ANY -> STORE_NOT_DONE`：`reset`。
2. `ANY -> REQ_IDLE`、`ANY -> WAKEUP_EMPTY`、`ANY -> READ_NOT_DONE`、`ANY -> STORE_NOT_DONE`：`flush`。
3. `REQ_IDLE[t] -> REQ_IN_FLIGHT[t]`、`WAKEUP_HELD[t] -> WAKEUP_EMPTY[t]`：`issue_accept`。
4. `REQ_IN_FLIGHT[t] -> REQ_IDLE[t]`：`terminal`。
5. `WAKEUP_EMPTY[t] -> WAKEUP_HELD[t]`：`wakeup_hold`。
6. `READ_NOT_DONE[t] -> READ_DONE[t]`：`read_mark`。
7. `STORE_NOT_DONE[t] -> STORE_DONE[t]`：`store_mark`。

### Detailed Condition Description

1. `reset`：异步复位全部 tag 状态和读数据暂存。
	- Fire来源：`reset.fire = ¬rst_n`
		- `rst_n`：见 `Interface -> In Static Info` 第 1 条。
	- Constraint：低电平异步有效；优先于 `flush` 和其他状态更新。
	- Payload：∅。
	- State update：`wakeup_held_q <- 0`；`read_done_q <- 0`；`store_done_q <- 0`；`req_in_flight_q <- 0`；`held_data_q[t] <- 0`。
2. `flush`：清除桥接状态并丢弃当前拍终端输入。
	- Fire来源：`flush.fire = global_flush_late`
		- `global_flush_late`：见 `Interface -> In-event` 第 3 条。
	- Constraint：优先于 `issue_accept`、`wakeup_hold`、`read_mark`、`store_mark` 和 `terminal`。
	- Payload：∅。
	- State update：`wakeup_held_q <- 0`；`read_done_q <- 0`；`store_done_q <- 0`；`req_in_flight_q <- 0`；`held_data_q[t] <- 0`。
3. `issue_accept`：当前 issue 请求被 LSU 接受。
	- Fire来源：`issue_accept.fire = issue_valid ∧ bridge_has_room ∧ lsu_be_issue_ready ∧ ¬global_flush_late`
		- `issue_valid`：见 `Interface -> In-event` 第 1 条。
		- `bridge_has_room = ¬req_in_flight_q[entry_self_tag]`
			- `req_in_flight_q[t]`：见 `Data structure -> State` 第 4 条。
		- `lsu_be_issue_ready`：见 `Interface -> In Static Info` 第 2 条。
		- `global_flush_late`：见 `Interface -> In-event` 第 3 条。
	- Constraint：`FU_ready = bridge_has_room ∧ lsu_be_issue_ready`；同 tag 的 `terminal` 与 `issue_accept` 同拍时，时序块后执行的 issue 置位优先。
	- Payload：`be_lsu_issue_pld`；`be_lsu_issue_valid.fire` 成立的当前拍由 LSU 采样。
	- State update：`req_in_flight_q[entry_self_tag] <- 1`；`wakeup_held_q[entry_self_tag] <- 0`。
4. `wakeup_hold`：对尚未发射到 LSU 的 store wakeup 授权进行挂起。
	- Fire来源：`wakeup_hold.fire = wakeup_accept ∧ ¬wakeup_target_present`
		- `wakeup_accept = store_wakeup_valid ∧ rst_n ∧ ¬global_flush_late ∧ ¬wakeup_pending_any`
			- `store_wakeup_valid`：见 `Interface -> In-event` 第 2 条。
			- `rst_n`：见 `Interface -> In Static Info` 第 1 条。
			- `global_flush_late`：见 `Interface -> In-event` 第 3 条。
			- `wakeup_pending_any = |wakeup_held_q`
				- `wakeup_held_q[t]`：见 `Data structure -> State` 第 1 条。
		- `wakeup_target_present = req_in_flight_q[store_wakeup_tag] ∨ (issue_accept ∧ (entry_self_tag == store_wakeup_tag))`
			- `req_in_flight_q[store_wakeup_tag]`：见 `Data structure -> State` 第 4 条。
			- `issue_accept`：见本节第 3 条。
			- `entry_self_tag`、`store_wakeup_tag`：见 `Interface -> In-event` 第 1、2 条 payload。
	- Constraint：同一时刻最多保留一个 `wakeup_held_q`；目标已在 LSU 中或同拍发射时不挂起。
	- Payload：`store_wakeup_tag`；当前拍组合有效。
	- State update：`wakeup_held_q[store_wakeup_tag] <- 1`。
5. `read_mark`：记录当前 terminal 的 read-side 结果。
	- Fire来源：`read_mark.fire = done_in ∧ read_side_result`
		- `done_in = lsu_be_writeback_valid ∧ lsu_be_writeback_pld.done_valid ∧ ¬global_flush_late`
			- `lsu_be_writeback_valid`、`lsu_be_writeback_pld`：见 `Interface -> In-event` 第 4 条。
			- `global_flush_late`：见 `Interface -> In-event` 第 3 条。
		- `read_side_result = lsu_be_bypass_valid ∧ ¬global_flush_late`
			- `lsu_be_bypass_valid`、`lsu_be_bypass_pld`：见 `Interface -> In-event` 第 5 条。
			- `global_flush_late`：见 `Interface -> In-event` 第 3 条。
	- Constraint：仅 `done_in` 且同时存在 read-side bypass 时成立。
	- Payload：`lsu_be_writeback_pld.data`。
	- State update：`read_done_q[wb_tag] <- 1`；`held_data_q[wb_tag] <- lsu_be_writeback_pld.data`。
6. `store_mark`：记录当前 tag 的 LSU done。
	- Fire来源：`store_mark.fire = done_in`
		- `done_in`：见本节第 5 条。
	- Constraint：异常 terminal 不设置 `store_done_q`。
	- Payload：`lsu_be_writeback_pld.tag`。
	- State update：`store_done_q[wb_tag] <- 1`。
7. `terminal`：结束当前 tag 的 LSU 请求。
	- Fire来源：`terminal.fire = done_in ∨ exc_in`
		- `done_in`：见本节第 5 条。
		- `exc_in = lsu_be_writeback_valid ∧ lsu_be_writeback_pld.exception_valid ∧ ¬global_flush_late`
			- `lsu_be_writeback_valid`、`lsu_be_writeback_pld`：见 `Interface -> In-event` 第 4 条。
			- `global_flush_late`：见 `Interface -> In-event` 第 3 条。
	- Constraint：`done_in` 与 `exc_in` 使用同一 `wb_tag`；flush 当拍二者均无效。
	- Payload：`wb_tag = lsu_be_writeback_pld.tag`。
	- State update：`req_in_flight_q[wb_tag] <- 0`。

## Data structure

### State

1. `wakeup_held_q[t]`：1 bit × `ROB_DEPTH`；tag `t` 的待发射 wakeup 授权；由 `reset`、`flush`、`wakeup_hold` 和 `issue_accept` 更新。
2. `read_done_q[t]`：1 bit × `ROB_DEPTH`；tag `t` 是否已记录 read-side 完成；由 `reset`、`flush` 和 `read_mark` 更新。
3. `store_done_q[t]`：1 bit × `ROB_DEPTH`；tag `t` 是否已记录 LSU done；由 `reset`、`flush` 和 `store_mark` 更新。
4. `req_in_flight_q[t]`：1 bit × `ROB_DEPTH`；tag `t` 是否存在尚未 terminal 的 LSU 请求；由 `reset`、`flush`、`issue_accept` 和 `terminal` 更新。

### Header

无。

### Payload

1. `held_data_q[t]`：来源于 `read_mark`。
	- `read_mark`：`lsu_be_writeback_pld.data`。

## Internal Connections

无。

## Interface

### In-event

1. `issue_valid`：Transaction，单 lane。
	- Fire来源：`issue_valid.fire`；当前拍请求有效。
	- Payload：`entry_self_tag`、`exe_subop`、`mem_funct3`、`rd_is_fp`、`rs1_data`、`store_data`、`imm_valid`、`imm_data`、`st_br_resolve`；当前拍组合有效。
2. `store_wakeup_valid`：Notify，单 lane。
	- Fire来源：`store_wakeup_valid.fire = store_wakeup_valid`。
	- Payload：`store_wakeup_tag`；当前拍组合有效。
3. `global_flush_late`：Notify，单 lane。
	- Fire来源：`global_flush_late.fire = global_flush_late`。
	- Payload：∅；当前拍 pulse。
4. `lsu_be_writeback_valid`：Notify，单 lane。
	- Fire来源：`lsu_be_writeback_valid.fire = lsu_be_writeback_valid`。
	- Payload：`lsu_be_writeback_pld`；当前拍组合有效。
5. `lsu_be_bypass_valid`：Notify，单 lane。
	- Fire来源：`lsu_be_bypass_valid.fire = lsu_be_bypass_valid`。
	- Payload：`lsu_be_bypass_pld`；当前拍组合有效；本模块使用其 fire 作为 read-side qualifier。

### In Static Info

1. `rst_n`：1 bit；低有效异步复位输入。
2. `lsu_be_issue_ready`：1 bit；LSU 当前拍能否接受 issue payload。

### Out-event

1. `writeback_valid`：Notify，单 lane。
	- Fire来源：`writeback_valid.fire = (done_in ∧ req_sides_complete) ∨ exc_in`
		- `done_in`、`exc_in`：见 `FSM -> Detailed Condition Description` 第 5、7 条。
		- `req_sides_complete = read_done_next ∨ store_done_next`
			- `read_done_next = read_done_q[wb_tag] ∨ (done_in ∧ read_side_result)`
				- `read_done_q[wb_tag]`：见 `Data structure -> State` 第 2 条。
				- `done_in`、`read_side_result`：见 `FSM -> Detailed Condition Description` 第 5 条。
			- `store_done_next = store_done_q[wb_tag] ∨ done_in`
				- `store_done_q[wb_tag]`：见 `Data structure -> State` 第 3 条。
				- `done_in`：见 `FSM -> Detailed Condition Description` 第 5 条。
	- Payload：`tag_out`、`result_data`、`mispredict_flag`、`mispredict_target_pc`、`exception_flag`、`exception_cause`、`exception_tval`、`is_mret`、`is_sret`、`fpu_fflags`；`writeback_valid.fire` 成立的当前拍组合有效。
		- `tag_out = wb_tag`。
			- `wb_tag = lsu_be_writeback_pld.tag`。
		- `result_data = read_side_result ? held_data_rd : 0`。
			- `read_side_result`：见 `FSM -> Detailed Condition Description` 第 5 条。
			- `held_data_rd = (done_in ∧ read_side_result) ? lsu_be_writeback_pld.data : held_data_q[wb_tag]`。
				- `held_data_q[wb_tag]`：见 `Data structure -> Payload` 第 1 条。
		- `mispredict_flag = 0`。
		- `mispredict_target_pc = 0`。
		- `exception_flag = exc_in`。
		- `exception_cause = exc_in ? lsu_be_writeback_pld.exception_cause : 0`。
		- `exception_tval = exc_in ? lsu_be_writeback_pld.exception_tval : 0`。
		- `is_mret = 0`。
		- `is_sret = 0`。
		- `fpu_fflags = 0`。
2. `bypass_publish_valid`：Notify，单 lane。
	- Fire来源：`bypass_publish_valid.fire = writeback_valid ∧ read_side_result ∧ ¬exception_flag`
		- `writeback_valid`：见本节第 1 条。
		- `read_side_result`：见 `FSM -> Detailed Condition Description` 第 5 条。
		- `exception_flag`：见本节第 1 条 payload。
	- Payload：`bypass_tag`、`bypass_data`；当前拍组合有效。
		- `bypass_tag = wb_tag`。
		- `bypass_data = held_data_rd`。
3. `be_lsu_issue_valid`：Transaction，单 lane。
	- Fire来源：`be_lsu_issue_valid.fire = issue_valid ∧ bridge_has_room ∧ ¬global_flush_late`
		- `issue_valid`：见 `Interface -> In-event` 第 1 条。
		- `bridge_has_room = ¬req_in_flight_q[entry_self_tag]`
			- `req_in_flight_q[t]`：见 `Data structure -> State` 第 4 条。
		- `global_flush_late`：见 `Interface -> In-event` 第 3 条。
	- Constraint：payload 无条件组合驱动；LSU 通过 `lsu_be_issue_ready` 完成接收判定。
	- Payload：`be_lsu_issue_pld`；字段为 `tag=entry_self_tag`、`exe_subop`、`mem_funct3`、`rd_is_fp`、`rs1_data`、`store_data`、`imm_valid`、`imm_data`、`st_br_resolve`。
4. `be_lsu_store_wakeup_valid`：Notify，单 lane。
	- Fire来源：`be_lsu_store_wakeup_valid.fire = wakeup_relay_now ∨ wakeup_relay_held`
		- `wakeup_relay_now = wakeup_accept ∧ wakeup_target_present`
			- `wakeup_accept`、`wakeup_target_present`：见 `FSM -> Detailed Condition Description` 第 4 条。
		- `wakeup_relay_held = issue_accept ∧ wakeup_held_q[entry_self_tag]`
			- `issue_accept`：见 `FSM -> Detailed Condition Description` 第 3 条。
			- `wakeup_held_q[entry_self_tag]`：见 `Data structure -> State` 第 1 条。
	- Payload：`be_lsu_store_wakeup_tag = wakeup_relay_held ? entry_self_tag : store_wakeup_tag`。

### Out Static Info

1. `FU_ready`：1 bit；当前拍 LSU bridge 可接受 issue 的 ready 投影；当前拍组合有效。
	- `FU_ready = bridge_has_room ∧ lsu_be_issue_ready`
		- `bridge_has_room = ¬req_in_flight_q[entry_self_tag]`
			- `req_in_flight_q[t]`：见 `Data structure -> State` 第 4 条。
		- `lsu_be_issue_ready`：见 `Interface -> In Static Info` 第 2 条。

### Interface Timing

1. `clk`：`wakeup_held_q`、`read_done_q`、`store_done_q`、`req_in_flight_q` 和 `held_data_q` 在上升沿更新。
2. `rst_n`：低有效异步复位；有效时全部 tag 状态和 `held_data_q` 清零。
3. `Transaction`：`issue_valid` 与 `FU_ready` 完成 issue 交付；`be_lsu_issue_valid ∧ lsu_be_issue_ready` 为 LSU 接收条件，payload 在接收前保持组合有效。
4. `Notify`：`store_wakeup_valid`、`global_flush_late`、`lsu_be_writeback_valid`、`lsu_be_bypass_valid` 及全部输出事件仅当前拍有效；flush 当拍清除状态且不产生终端输出。
5. `Static Info`：`rst_n`、`lsu_be_issue_ready` 和 `FU_ready` 当前拍有效；`FU_ready` 不依赖 `issue_valid`。
