# Module `dependency_check`

`dependency_check`：`ISSUE_WIDTH`-slot、每 slot `FP_READ_PORTS` 个源操作数的纯组合依赖检查模块；`INT_SRC_PER_SLOT` 为每 slot 的整数源读口数，`NUM_LANES` 为 bypass lane 数，`TAG_W` 为 tag 位宽，`ROB_DEPTH` 为 CompletionScoreboard entry 数，`REG_ADDR_W` 为寄存器索引位宽，`RS_DATA_SEL_W` 为数据源选择码位宽。

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

1. `commit_valid[k]`：Notify，`k∈{0,...,ISSUE_WIDTH-1}`。
	- Fire来源：`commit_valid[k].fire`
	- Payload：`commit_tag[k]`，`TAG_W` bit × 1；当前拍组合比较。
2. `bypass_publish_valid[b]`：Notify，`b∈{0,...,NUM_LANES-1}`。
	- Fire来源：`bypass_publish_valid[b].fire`
	- Payload：`bypass_tag[b]`，`TAG_W` bit × 1；当前拍组合比较。

### In Static Info

1. `inst_valid[s]`：1 bit × `ISSUE_WIDTH`，`s∈{0,...,ISSUE_WIDTH-1}`；slot `s` 当前拍是否存在有效候选。
2. `rd_idx[s]`：`REG_ADDR_W` bit × `ISSUE_WIDTH`；slot `s` 当前拍的 destination 寄存器索引。
3. `rd_is_fp[s]`：1 bit × `ISSUE_WIDTH`；slot `s` 当前拍的 destination 是否为 FP 寄存器。
4. `use_rd[s]`：1 bit × `ISSUE_WIDTH`；slot `s` 当前拍是否使用 destination 写回。
5. `is_serial[s]`：1 bit × `ISSUE_WIDTH`；slot `s` 当前拍是否为 serial 指令。
6. `is_fp_opcode[s]`：1 bit × `ISSUE_WIDTH`；slot `s` 当前拍的 opcode 是否属于 FP opcode 集合。
7. `use_rs1[s]`：1 bit × `ISSUE_WIDTH`；slot `s` 当前拍是否使用 rs1。
8. `use_rs2[s]`：1 bit × `ISSUE_WIDTH`；slot `s` 当前拍是否使用 rs2。
9. `use_rs3[s]`：1 bit × `ISSUE_WIDTH`；slot `s` 当前拍是否使用 rs3。
10. `rs1_idx[s]`：`REG_ADDR_W` bit × `ISSUE_WIDTH`；slot `s` 当前拍的 rs1 寄存器索引。
11. `rs2_idx[s]`：`REG_ADDR_W` bit × `ISSUE_WIDTH`；slot `s` 当前拍的 rs2 寄存器索引。
12. `rs3_idx[s]`：`REG_ADDR_W` bit × `ISSUE_WIDTH`；slot `s` 当前拍的 rs3 寄存器索引。
13. `rs1_is_fp[s]`：1 bit × `ISSUE_WIDTH`；slot `s` 当前拍的 rs1 是否来自 FP 寄存器堆。
14. `rs2_is_fp[s]`：1 bit × `ISSUE_WIDTH`；slot `s` 当前拍的 rs2 是否来自 FP 寄存器堆。
15. `rs3_is_fp[s]`：1 bit × `ISSUE_WIDTH`；slot `s` 当前拍的 rs3 是否来自 FP 寄存器堆。
16. `Buffer_tail`：`TAG_W` bit；当前拍的 CompletionScoreboard tail，作为 slot tag 分配基址。
17. `int_rename_read_tag[s][x]`：`TAG_W` bit，`s∈{0,...,ISSUE_WIDTH-1}`、`x∈{1,...,INT_SRC_PER_SLOT}`；当前拍整数重命名读口的 producer tag。
18. `int_rename_read_busy[s][x]`：1 bit，索引同第 17 条；当前拍整数重命名读口是否 busy。
19. `fp_rename_read_tag[x]`：`TAG_W` bit，`x∈{1,...,FP_READ_PORTS}`；当前拍 FP 重命名读口的 producer tag。
20. `fp_rename_read_busy[x]`：1 bit，索引同第 19 条；当前拍 FP 重命名读口是否 busy。
21. `scoreboard_valid_bits`：`ROB_DEPTH` bit；当前拍按 tag 索引的 CompletionScoreboard entry valid 位图。
22. `scoreboard_exec_done_bits`：`ROB_DEPTH` bit；当前拍按 tag 索引的 CompletionScoreboard entry 执行完成位图。

### Out-event

无。

### Out Static Info

1. `self_tag[s]`：`TAG_W` bit × `ISSUE_WIDTH`，`s∈{0,...,ISSUE_WIDTH-1}`；slot `s` 当前拍的 CompletionScoreboard tag。
	- `self_tag[s] = (Buffer_tail + TAG_W'(s)) mod 2^TAG_W`。
		- `Buffer_tail`：见 `Interface -> In Static Info` 第 16 条。
2. `rd_write_enable[s]`：1 bit × `ISSUE_WIDTH`；slot `s` 当前拍的 destination 写使能，仅抑制整数 x0，不抑制 FP f0。
	- `rd_write_enable[s] = use_rd[s] ∧ ¬((rd_idx[s] == '0) ∧ ¬rd_is_fp[s])`。
		- `use_rd[s]`：见 `Interface -> In Static Info` 第 4 条。
		- `rd_idx[s]`：见 `Interface -> In Static Info` 第 2 条。
		- `rd_is_fp[s]`：见 `Interface -> In Static Info` 第 3 条。
3. `serial0`：1 bit；当前拍 slot 0 的 serial 属性，不由 `inst_valid[0]` 门控。
	- `serial0 = is_serial[0]`。
		- `is_serial[0]`：见 `Interface -> In Static Info` 第 5 条。
4. `serial_inst`：1 bit；当前拍 slot 0 或 slot 1 的 serial 属性为 1，不由 `inst_valid[s]` 门控。
	- `serial_inst = is_serial[0] ∨ is_serial[1]`。
		- `is_serial[0]`：见 `Interface -> In Static Info` 第 5 条。
		- `is_serial[1]`：见 `Interface -> In Static Info` 第 5 条。
5. `fp0`：1 bit；当前拍 slot 0 的 FP opcode 属性，不由 `inst_valid[0]` 门控。
	- `fp0 = is_fp_opcode[0]`。
		- `is_fp_opcode[0]`：见 `Interface -> In Static Info` 第 6 条。
6. `fp1`：1 bit；当前拍 slot 1 的 FP opcode 属性，不由 `inst_valid[1]` 门控。
	- `fp1 = is_fp_opcode[1]`。
		- `is_fp_opcode[1]`：见 `Interface -> In Static Info` 第 6 条。
7. `slot_missed_wakeup[s]`：1 bit × `ISSUE_WIDTH`；slot `s` 当前拍是否存在 producer 仍有效且已执行完成、但源仍处于等待 producer 分支的依赖。
	- `slot_missed_wakeup[s] = ∨_{x=1..FP_READ_PORTS}((source_kind[s][x] == SRC_WAIT_PRODUCER) ∧ scoreboard_valid_bits[rsX_wait_tag[s][x]] ∧ scoreboard_exec_done_bits[rsX_wait_tag[s][x]])`。
		- `source_kind[s][x]`：`src_kind_e`，3 bit；`SRC_WAIT_OVERLAY=3'd0`、`SRC_NONE=3'd1`、`SRC_ARF=3'd2`、`SRC_COMMIT=3'd3`、`SRC_BYPASS=3'd4`、`SRC_WAIT_PRODUCER=3'd5`；`source_kind[s][x] = case(overlay_hit[s][x]: SRC_WAIT_OVERLAY; ¬use_rs[s][x]: SRC_NONE; arf_ready[s][x]: SRC_ARF; commit_match[s][x]: SRC_COMMIT; bypass_match[s][x]: SRC_BYPASS; default: SRC_WAIT_PRODUCER)`，按列出顺序 first-hit。
			- `overlay_hit[s][x] = (s == 1) ∧ slot1_dep_hit[x]`。
				- `slot1_dep_hit[x] = inst_valid[0] ∧ rd_write_enable[0] ∧ use_rs[1][x] ∧ (rs_idx[1][x] == rd_idx[0]) ∧ (rs_is_fp[1][x] == rd_is_fp[0])`。
					- `inst_valid[0]`：见 `Interface -> In Static Info` 第 1 条。
					- `rd_write_enable[0]`：见本节第 2 条。
					- `use_rs[1][x]`：见本条 `use_rs[s][x]` 的定义。
					- `rs_idx[1][x] = (x == 1) ? rs1_idx[1] : ((x == 2) ? rs2_idx[1] : rs3_idx[1])`。
						- `rs1_idx[1]`：见 `Interface -> In Static Info` 第 10 条。
						- `rs2_idx[1]`：见 `Interface -> In Static Info` 第 11 条。
						- `rs3_idx[1]`：见 `Interface -> In Static Info` 第 12 条。
					- `rd_idx[0]`：见 `Interface -> In Static Info` 第 2 条。
					- `rs_is_fp[1][x]`：见本条 `rs_is_fp[s][x]` 的定义。
					- `rd_is_fp[0]`：见 `Interface -> In Static Info` 第 3 条。
			- `use_rs[s][x] = (x == 1) ? use_rs1[s] : ((x == 2) ? use_rs2[s] : use_rs3[s])`。
				- `use_rs1[s]`：见 `Interface -> In Static Info` 第 7 条。
				- `use_rs2[s]`：见 `Interface -> In Static Info` 第 8 条。
				- `use_rs3[s]`：见 `Interface -> In Static Info` 第 9 条。
			- `arf_ready[s][x] = take_fp[s][x] ? ¬fp_rename_read_busy[x] : ¬int_busy[s][x]`。
				- `take_fp[s][x] = rs_is_fp[s][x] ∨ (x > INT_SRC_PER_SLOT)`。
					- `rs_is_fp[s][x] = (x == 1) ? rs1_is_fp[s] : ((x == 2) ? rs2_is_fp[s] : rs3_is_fp[s])`。
						- `rs1_is_fp[s]`：见 `Interface -> In Static Info` 第 13 条。
						- `rs2_is_fp[s]`：见 `Interface -> In Static Info` 第 14 条。
						- `rs3_is_fp[s]`：见 `Interface -> In Static Info` 第 15 条。
				- `fp_rename_read_busy[x]`：见 `Interface -> In Static Info` 第 20 条。
				- `int_busy[s][x] = (x <= INT_SRC_PER_SLOT) ? int_rename_read_busy[s][x] : 1'b1`。
					- `int_rename_read_busy[s][x]`：见 `Interface -> In Static Info` 第 18 条；仅在 `x<=INT_SRC_PER_SLOT` 时读取。
			- `commit_match[s][x] = ∨_{k=0..ISSUE_WIDTH-1} commit_hit[s][x][k]`。
				- `commit_hit[s][x][k] = commit_valid[k].fire ∧ (commit_tag[k] == producer_tag[s][x])`。
					- `commit_valid[k].fire`：见 `Interface -> In-event` 第 1 条。
					- `commit_tag[k]`：见 `Interface -> In-event` 第 1 条 Payload。
					- `producer_tag[s][x] = take_fp[s][x] ? fp_rename_read_tag[x] : int_tag[s][x]`。
						- `take_fp[s][x]`：见本条 `arf_ready[s][x]` 的定义。
						- `fp_rename_read_tag[x]`：见 `Interface -> In Static Info` 第 19 条。
						- `int_tag[s][x] = (x <= INT_SRC_PER_SLOT) ? int_rename_read_tag[s][x] : '0`。
							- `int_rename_read_tag[s][x]`：见 `Interface -> In Static Info` 第 17 条；仅在 `x<=INT_SRC_PER_SLOT` 时读取。
			- `bypass_match[s][x] = ∨_{b=0..NUM_LANES-1} bypass_hit[s][x][b]`。
				- `bypass_hit[s][x][b] = bypass_publish_valid[b].fire ∧ (bypass_tag[b] == producer_tag[s][x])`。
					- `bypass_publish_valid[b].fire`：见 `Interface -> In-event` 第 2 条。
					- `bypass_tag[b]`：见 `Interface -> In-event` 第 2 条 Payload。
					- `producer_tag[s][x]`：见本条 `commit_hit[s][x][k]` 的定义。
		- `scoreboard_valid_bits`：见 `Interface -> In Static Info` 第 21 条。
		- `rsX_wait_tag[s][x]`：见本节第 9 条。
		- `scoreboard_exec_done_bits`：见 `Interface -> In Static Info` 第 22 条。
8. `rsX_ready[s][x]`：1 bit，`s∈{0,...,ISSUE_WIDTH-1}`、`x∈{1,...,FP_READ_PORTS}`；源 `x` 当前拍是否无需等待后续 producer wakeup，未使用源置 1。
	- `rsX_ready[s][x] = ¬overlay_hit[s][x] ∧ (¬use_rs[s][x] ∨ arf_ready[s][x] ∨ commit_match[s][x] ∨ bypass_match[s][x])`。
		- `overlay_hit[s][x]`：见本节第 7 条。
		- `use_rs[s][x]`：见本节第 7 条。
		- `arf_ready[s][x]`：见本节第 7 条。
		- `commit_match[s][x]`：见本节第 7 条。
		- `bypass_match[s][x]`：见本节第 7 条。
9. `rsX_wait_tag[s][x]`：`TAG_W` bit，索引同第 8 条；源 `x` 当前拍对应的 producer tag，未使用源为 0，同拍 slot 0 到 slot 1 RAW 覆盖时为 `self_tag[0]`。
	- `rsX_wait_tag[s][x] = overlay_hit[s][x] ? self_tag[0] : (¬use_rs[s][x] ? '0 : producer_tag[s][x])`。
		- `overlay_hit[s][x]`：见本节第 7 条。
		- `self_tag[0]`：见本节第 1 条。
		- `use_rs[s][x]`：见本节第 7 条。
		- `producer_tag[s][x]`：见本节第 7 条。
10. `rs_data_sel_t[s][x]`：`RS_DATA_SEL_W` bit，索引同第 8 条；当前拍 onehot0 数据源选择码；`SEL_BYPASS_LSB=0`、`SEL_BYPASS_MSB=NUM_LANES-1`、`SEL_COMMIT_LSB=NUM_LANES`、`SEL_COMMIT_MSB=NUM_LANES+ISSUE_WIDTH-1`、`SEL_ARF_BIT=NUM_LANES+ISSUE_WIDTH`。
	- `rs_data_sel_t[s][x] = overlay_hit[s][x] ? '0 : (¬use_rs[s][x] ? '0 : (arf_ready[s][x] ? (RS_DATA_SEL_W'(1) << SEL_ARF_BIT) : (commit_match[s][x] ? (RS_DATA_SEL_W'(commit_lane[s][x]) << SEL_COMMIT_LSB) : (bypass_match[s][x] ? RS_DATA_SEL_W'(bypass_lane[s][x]) : '0))))`。
		- `overlay_hit[s][x]`：见本节第 7 条。
		- `use_rs[s][x]`：见本节第 7 条。
		- `arf_ready[s][x]`：见本节第 7 条。
		- `commit_match[s][x]`：见本节第 7 条。
		- `commit_lane[s][x][k] = commit_hit[s][x][k] ∧ ∧_{j=0..k-1}¬commit_hit[s][x][j]`。
			- `commit_hit[s][x][k]`：见本节第 7 条。
			- `commit_hit[s][x][j]`：见本节第 7 条。
		- `bypass_match[s][x]`：见本节第 7 条。
		- `bypass_lane[s][x][b] = bypass_hit[s][x][b] ∧ ∧_{j=0..b-1}¬bypass_hit[s][x][j]`。
			- `bypass_hit[s][x][b]`：见本节第 7 条。
			- `bypass_hit[s][x][j]`：见本节第 7 条。

### Interface Timing

1. `clk`：无时钟。
2. `rst_n`：无复位。
3. `Transaction`：无。
4. `Notify`：`commit_valid[k]` 和 `bypass_publish_valid[b]` 的 fire 在当前拍参与组合 tag 匹配；无 ready、背压或保持要求。
5. `Static Info`：所有输入和输出均为当前拍组合值；下一拍随输入重新计算。`rs_data_sel_t` 为 onehot0；未使用源的 `rsX_ready=1` 且等待 tag 为 0；无状态更新、握手或取消规则。
