# Module `p3_arbiter_G0`

`p3_arbiter_G0`：G0 的 3 路无状态组合完成仲裁模块，按固定优先级选择一个请求并产生 writeback、CSR sideband、bypass 和请求反馈；`G0_NUM_FU=3`、`XLEN=64`、`TAG_W=4`、`EXCP_CAUSE_W=63`、`FFLAGS_W=5`、`CSR_ADDR_W=12`。

## Submodule

无。

## FSM

### State

无。

### State Transition & Condition Name

无。

### Detailed Condition Description

无。

## Data structure

### State

无。

### Header

无。

### Payload

无。

## Internal Connections

无。

## Interface

### In-event

1. `request_valid[k]`：Transaction，`k∈{0,...,G0_NUM_FU-1}`。
	- Fire来源：`winner_grant[k].fire`。
	- Payload：`p3_arbiter_G0_request_payload[k]`；`winner_grant[k].fire` 成立的当前拍组合采样。
	`p3_arbiter_G0_request_payload[k]`：`req_tag[k]` `TAG_W` bit × 1、`req_result_data[k]` `XLEN` bit × 1、`req_mispredict_flag[k]` 1 bit × 1、`req_mispredict_target_pc[k]` `XLEN` bit × 1、`req_exception_flag[k]` 1 bit × 1、`req_exception_cause[k]` `EXCP_CAUSE_W` bit × 1、`req_exception_tval[k]` `XLEN` bit × 1、`req_is_mret[k]` 1 bit × 1、`req_is_sret[k]` 1 bit × 1、`req_fpu_fflags[k]` `FFLAGS_W` bit × 1、`req_is_csr[k]` 1 bit × 1、`req_csr_write_enable[k]` 1 bit × 1、`req_csr_addr[k]` `CSR_ADDR_W` bit × 1、`req_csr_wdata[k]` `XLEN` bit × 1。

### In Static Info

无。

### Out-event

1. `writeback_valid`：Notify，单 lane。
	- Fire来源：`writeback_valid.fire = request_valid[0] ∨ request_valid[1] ∨ request_valid[2]`
		- `request_valid[k]`：见 `Interface -> In-event` 第 1 条；`k∈{0,1,2}`。
	- Constraint：无额外约束。
	- Payload：`p3_arbiter_G0_writeback_payload`；`writeback_valid.fire` 成立的当前拍组合采样。
	`p3_arbiter_G0_writeback_payload`：`tag_out` `TAG_W` bit × 1、`result_data` `XLEN` bit × 1、`mispredict_flag` 1 bit × 1、`mispredict_target_pc` `XLEN` bit × 1、`exception_flag` 1 bit × 1、`exception_cause` `EXCP_CAUSE_W` bit × 1、`exception_tval` `XLEN` bit × 1、`is_mret` 1 bit × 1、`is_sret` 1 bit × 1、`fpu_fflags` `FFLAGS_W` bit × 1。
		- `tag_out = winner_grant[0].fire ? req_tag[0] : winner_grant[1].fire ? req_tag[1] : winner_grant[2].fire ? req_tag[2] : 0`
			- `winner_grant[k].fire`：见本节第 4 条。
			- `req_tag[k]`：见 `Interface -> In-event` 第 1 条 payload。
		- `result_data = winner_grant[0].fire ? req_result_data[0] : winner_grant[1].fire ? req_result_data[1] : winner_grant[2].fire ? req_result_data[2] : 0`
			- `winner_grant[k].fire`：见本节第 4 条。
			- `req_result_data[k]`：见 `Interface -> In-event` 第 1 条 payload。
		- `mispredict_flag = winner_grant[0].fire ? req_mispredict_flag[0] : winner_grant[1].fire ? req_mispredict_flag[1] : winner_grant[2].fire ? req_mispredict_flag[2] : 0`
			- `winner_grant[k].fire`：见本节第 4 条。
			- `req_mispredict_flag[k]`：见 `Interface -> In-event` 第 1 条 payload。
		- `mispredict_target_pc = winner_grant[0].fire ? req_mispredict_target_pc[0] : winner_grant[1].fire ? req_mispredict_target_pc[1] : winner_grant[2].fire ? req_mispredict_target_pc[2] : 0`
			- `winner_grant[k].fire`：见本节第 4 条。
			- `req_mispredict_target_pc[k]`：见 `Interface -> In-event` 第 1 条 payload。
		- `exception_flag = winner_grant[0].fire ? req_exception_flag[0] : winner_grant[1].fire ? req_exception_flag[1] : winner_grant[2].fire ? req_exception_flag[2] : 0`
			- `winner_grant[k].fire`：见本节第 4 条。
			- `req_exception_flag[k]`：见 `Interface -> In-event` 第 1 条 payload。
		- `exception_cause = winner_grant[0].fire ? req_exception_cause[0] : winner_grant[1].fire ? req_exception_cause[1] : winner_grant[2].fire ? req_exception_cause[2] : 0`
			- `winner_grant[k].fire`：见本节第 4 条。
			- `req_exception_cause[k]`：见 `Interface -> In-event` 第 1 条 payload。
		- `exception_tval = winner_grant[0].fire ? req_exception_tval[0] : winner_grant[1].fire ? req_exception_tval[1] : winner_grant[2].fire ? req_exception_tval[2] : 0`
			- `winner_grant[k].fire`：见本节第 4 条。
			- `req_exception_tval[k]`：见 `Interface -> In-event` 第 1 条 payload。
		- `is_mret = winner_grant[0].fire ? req_is_mret[0] : winner_grant[1].fire ? req_is_mret[1] : winner_grant[2].fire ? req_is_mret[2] : 0`
			- `winner_grant[k].fire`：见本节第 4 条。
			- `req_is_mret[k]`：见 `Interface -> In-event` 第 1 条 payload。
		- `is_sret = winner_grant[0].fire ? req_is_sret[0] : winner_grant[1].fire ? req_is_sret[1] : winner_grant[2].fire ? req_is_sret[2] : 0`
			- `winner_grant[k].fire`：见本节第 4 条。
			- `req_is_sret[k]`：见 `Interface -> In-event` 第 1 条 payload。
		- `fpu_fflags = winner_grant[0].fire ? req_fpu_fflags[0] : winner_grant[1].fire ? req_fpu_fflags[1] : winner_grant[2].fire ? req_fpu_fflags[2] : 0`
			- `winner_grant[k].fire`：见本节第 4 条。
			- `req_fpu_fflags[k]`：见 `Interface -> In-event` 第 1 条 payload。
2. `csr_sideband_publish_valid`：Notify，单 lane。
	- Fire来源：`csr_sideband_publish_valid.fire = writeback_valid.fire ∧ is_csr`
		- `writeback_valid.fire`：见本节第 1 条。
		- `is_csr = winner_grant[0].fire ? req_is_csr[0] : winner_grant[1].fire ? req_is_csr[1] : winner_grant[2].fire ? req_is_csr[2] : 0`
			- `winner_grant[k].fire`：见本节第 4 条。
			- `req_is_csr[k]`：见 `Interface -> In-event` 第 1 条 payload。
	- Constraint：`csr_sideband_publish_valid.fire -> writeback_valid.fire`。
	- Payload：`p3_arbiter_G0_csr_sideband_payload`；`csr_sideband_publish_valid.fire` 成立的当前拍组合采样。
	`p3_arbiter_G0_csr_sideband_payload`：`is_csr` 1 bit × 1、`csr_write_enable` 1 bit × 1、`csr_addr` `CSR_ADDR_W` bit × 1、`csr_wdata` `XLEN` bit × 1。
		- `is_csr`：见本条 Fire来源。
		- `csr_write_enable = winner_grant[0].fire ? req_csr_write_enable[0] : winner_grant[1].fire ? req_csr_write_enable[1] : winner_grant[2].fire ? req_csr_write_enable[2] : 0`
			- `winner_grant[k].fire`：见本节第 4 条。
			- `req_csr_write_enable[k]`：见 `Interface -> In-event` 第 1 条 payload。
		- `csr_addr = winner_grant[0].fire ? req_csr_addr[0] : winner_grant[1].fire ? req_csr_addr[1] : winner_grant[2].fire ? req_csr_addr[2] : 0`
			- `winner_grant[k].fire`：见本节第 4 条。
			- `req_csr_addr[k]`：见 `Interface -> In-event` 第 1 条 payload。
		- `csr_wdata = winner_grant[0].fire ? req_csr_wdata[0] : winner_grant[1].fire ? req_csr_wdata[1] : winner_grant[2].fire ? req_csr_wdata[2] : 0`
			- `winner_grant[k].fire`：见本节第 4 条。
			- `req_csr_wdata[k]`：见 `Interface -> In-event` 第 1 条 payload。
3. `bypass_publish_valid`：Notify，单 lane。
	- Fire来源：`bypass_publish_valid.fire = writeback_valid.fire ∧ ¬exception_flag`
		- `writeback_valid.fire`：见本节第 1 条。
		- `exception_flag`：见本节第 1 条 payload。
	- Constraint：`bypass_publish_valid.fire -> writeback_valid.fire`。
	- Payload：`p3_arbiter_G0_bypass_payload`；`bypass_publish_valid.fire` 成立的当前拍组合采样。
	`p3_arbiter_G0_bypass_payload`：`bypass_tag` `TAG_W` bit × 1、`bypass_data` `XLEN` bit × 1。
		- `bypass_tag = tag_out`
			- `tag_out`：见本节第 1 条 payload。
		- `bypass_data = result_data`
			- `result_data`：见本节第 1 条 payload。
4. `winner_grant[k]`：Notify，`k∈{0,...,G0_NUM_FU-1}`。
	- Fire来源：`winner_grant[k].fire = request_valid[k] ∧ (∀j∈{0,...,k-1}: ¬request_valid[j])`
		- `request_valid[k]`：见 `Interface -> In-event` 第 1 条。
		- `request_valid[j]`：见 `Interface -> In-event` 第 1 条；`j∈{0,...,k-1}`。
	- Constraint：`winner_grant[2:0]` 为 onehot0；`winner_grant[k].fire -> request_valid[k]`。
	- Payload：`∅`；当前拍组合有效。

### Out Static Info

1. `loser_hold[k]`：1 bit × `G0_NUM_FU`，`k∈{0,...,G0_NUM_FU-1}`；当前拍请求 `k` 有效但未获得 grant。
	- `loser_hold[k] = request_valid[k] ∧ ¬winner_grant[k].fire`
		- `request_valid[k]`：见 `Interface -> In-event` 第 1 条。
		- `winner_grant[k].fire`：见 `Interface -> Out-event` 第 4 条。

### Interface Timing

1. `clk`：无时钟；仲裁、payload 选择及所有输出均为当前拍组合逻辑。
2. `rst_n`：无复位端口；本模块无复位行为。
3. `Transaction`：`request_valid[k]` 与 `winner_grant[k]` 构成逐 requester 的 valid/ready 成交；请求未成交时 `loser_hold[k]=1`，请求方保持 valid 和完整 payload，直到 `winner_grant[k].fire`。
4. `Notify`：`writeback_valid`、`csr_sideband_publish_valid`、`bypass_publish_valid` 和 `winner_grant[k]` 均在 fire 的当前拍组合有效，无本模块背压或跨拍保持。
5. `Static Info`：`loser_hold[k]` 根据当前拍 `request_valid[k]` 和 `winner_grant[k].fire` 组合产生；无 reset 或 flush 取消规则。
