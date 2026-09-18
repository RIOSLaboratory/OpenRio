# Module `system_instruction_handler`

`system_instruction_handler`：单项 CSR 写暂存、RV64 架构 CSR、当前特权级、trap 状态、计数器和组合 CSR 读端口。

## Submodule

无。

## FSM

### State

1. `IDLE`：没有待提交的 CSR 写。
2. `STAGED`：保存一个等待对应 tag 提交的 CSR 写。

### State Transition & Condition Name

1. `ANY -> IDLE`：`reset`
2. `IDLE -> STAGED`、`STAGED -> STAGED`：`capture`
3. `STAGED -> IDLE`：`apply_fire`
4. `IDLE -> IDLE`、`STAGED -> IDLE`：`flush`
5. `IDLE -> IDLE`、`STAGED -> STAGED`：`counter_tick`
6. `IDLE -> IDLE`、`STAGED -> STAGED`：`fflags_accrue`
7. `IDLE -> IDLE`、`STAGED -> STAGED`：`trap_entry`
8. `IDLE -> IDLE`、`STAGED -> STAGED`：`mret_update`
9. `IDLE -> IDLE`、`STAGED -> STAGED`：`sret_update`

### Detailed Condition Description

1. `reset`：异步复位暂存项和全部架构状态。
	- Fire来源：`reset.fire = ¬rst_n`
		- `rst_n`：见 `Interface -> In Static Info` 第 1 条。
	- Constraint：低有效异步复位，优先于全部上升沿更新。
	- Payload：∅。
	- State update：`entry.valid <- 0`；`entry.header <- 0`；`entry.payload <- 0`；`mstatus.mie <- 0`；`mstatus.mpie <- 0`；`mstatus.fs <- FS_OFF`；`mstatus.mpp <- PRIV_M`；`current_priv <- PRIV_M`；`mstatus.{sie,spie,spp,sum,mxr,tvm,tw,tsr} <- 0`；`mie.{meie,mtie,msie,seie,stie,ssie} <- 0`；`mip.ssip <- 0`；`mtvec <- {0,MTVEC_MODE_DIRECT}`；`stvec <- {0,MTVEC_MODE_DIRECT}`；`mepc/mcause/mtval/mscratch/sepc/scause/stval/sscratch/medeleg/mideleg/satp/mcycle/minstret/fflags <- 0`；`frm <- RM_RNE`。

2. `capture`：捕获一个可写 CSR sideband。
	- Fire来源：`capture.fire = csr_sideband_valid.fire ∧ sb_csr_write_enable ∧ ¬global_flush_late.fire`
		- `csr_sideband_valid.fire`：见 `Interface -> In-event` 第 1 条。
		- `sb_csr_write_enable`：见 `Interface -> In-event` 第 1 条 payload。
		- `global_flush_late.fire`：见 `Interface -> In-event` 第 4 条。
	- Constraint：单项暂存；在 `STAGED` 中 fire 时覆盖原暂存字段；若同拍 `apply_fire.fire` 成立，`entry.valid` 仍由 `apply_fire` 清零，`entry.header` 和 `entry.payload` 仍被本 Event 覆盖。
	- Payload：`system_instruction_handler_csr_sideband_payload`；上升沿采样。
	- State update：`entry.header.tag <- tag_out`；`entry.header.addr <- sb_csr_addr`；`entry.payload.wdata <- sb_csr_wdata`；若同拍 `apply_fire.fire=0`，则 `entry.valid <- 1`。

3. `apply_fire`：提交 tag 命中时将暂存 CSR 写入对应架构存储。
	- Fire来源：`apply_fire.fire = entry.valid ∧ stage_tag_hit`
		- `entry.valid`：见 `Data structure -> State` 第 2 条。
		- `stage_tag_hit = ∨{commit_valid[k].fire ∧ (commit_tag[k]=entry.header.tag) | k∈{0,...,ISSUE_WIDTH-1}}`
			- `commit_valid[k].fire`、`commit_tag[k]`：见 `Interface -> In-event` 第 2 条。
			- `entry.header.tag`：见 `Data structure -> Header` 第 1 条。
	- Constraint：不重新判断 CSR 合法性；`global_flush_late` 不屏蔽本 Event；每个地址分支只更新明确列出的字段，其余架构存储保持；地址未命中时仅清除暂存项；`ENABLE_S=0` 时 S-mode 写分支保持；写入优先于同拍 `counter_tick` 和 `fflags_accrue`，低于同拍 trap/return Event。
	- Payload：`entry.header.addr`、`entry.payload.wdata`；上升沿采样。
	- State update：`entry.valid <- 0`；令 `addr=entry.header.addr`、`wdata=entry.payload.wdata`，按下列互斥地址分支更新：
		- `addr=ADDR_FFLAGS(12'h001)`：`fflags <- wdata[FFLAGS_W-1:0]`；`mstatus.fs <- FS_DIRTY`。
		- `addr=ADDR_FRM(12'h002)`：`frm <- wdata[FRM_W-1:0]`；`mstatus.fs <- FS_DIRTY`。
		- `addr=ADDR_FCSR(12'h003)`：`fflags <- wdata[FFLAGS_W-1:0]`；`frm <- wdata[FFLAGS_W +: FRM_W]`；`mstatus.fs <- FS_DIRTY`。
		- `addr=ADDR_MSTATUS(12'h300)`：`mstatus.mie <- wdata[3]`；`mstatus.mpie <- wdata[7]`；`mstatus.fs <- wdata[14:13]`；`mstatus.mpp <- (wdata[12:11]=PRIV_M) ? PRIV_M : (ENABLE_S ∧ wdata[12:11]=PRIV_S) ? PRIV_S : PRIV_U`；若 `ENABLE_S=1`，`mstatus.{sie,spie,spp,sum,mxr,tvm,tw,tsr} <- wdata[{1,5,8,18,19,20,21,22}]`。
		- `addr=ADDR_SSTATUS(12'h100) ∧ ENABLE_S`：`mstatus.fs <- wdata[14:13]`；`mstatus.{spp,spie,sie,sum,mxr} <- wdata[{8,5,1,18,19}]`。
		- `addr=ADDR_MIE(12'h304)`：`mie.{meie,mtie,msie} <- wdata[{11,7,3}]`；若 `ENABLE_S=1`，`mie.{seie,stie,ssie} <- wdata[{9,5,1}]`。
		- `addr=ADDR_SIE(12'h104) ∧ ENABLE_S`：对 `b∈{9,5,1}`，仅当 `mideleg[b]=1` 时写入对应 `mie.{seie,stie,ssie} <- wdata[b]`。
		- `addr=ADDR_MIP(12'h344) ∧ ENABLE_S`：`mip.ssip <- wdata[1]`。
		- `addr=ADDR_SIP(12'h144) ∧ ENABLE_S ∧ mideleg[1]`：`mip.ssip <- wdata[1]`。
		- `addr=ADDR_MTVEC(12'h305)`：`mtvec.base <- wdata[XLEN-1:2]`；仅当 `wdata[1:0]∈{MTVEC_MODE_DIRECT,MTVEC_MODE_VECTORED}` 时 `mtvec.mode <- wdata[1:0]`。
		- `addr=ADDR_STVEC(12'h105) ∧ ENABLE_S`：`stvec.base <- wdata[XLEN-1:2]`；仅当 `wdata[1:0]∈{MTVEC_MODE_DIRECT,MTVEC_MODE_VECTORED}` 时 `stvec.mode <- wdata[1:0]`。
		- `addr=ADDR_MEDELEG(12'h302) ∧ ENABLE_S`：`medeleg <- wdata ∧ MEDELEG_MASK`；`MEDELEG_MASK=64'h0000_0000_0000_F7FF`。
		- `addr=ADDR_MIDELEG(12'h303) ∧ ENABLE_S`：`mideleg <- wdata ∧ MIDELEG_MASK`；`MIDELEG_MASK=(1<<9) ∨ (1<<5) ∨ (1<<1)`。
		- `addr=ADDR_SATP(12'h180) ∧ ENABLE_S ∧ wdata[63:60]∈{0,8,9}`：`satp <- wdata`。
		- `addr=ADDR_SEPC(12'h141) ∧ ENABLE_S`：`sepc <- ENABLE_C ? {wdata[XLEN-1:1],1'b0} : {wdata[XLEN-1:2],2'b00}`。
		- `addr=ADDR_SCAUSE(12'h142) ∧ ENABLE_S`：`scause <- wdata`。
		- `addr=ADDR_STVAL(12'h143) ∧ ENABLE_S`：`stval <- wdata`。
		- `addr=ADDR_SSCRATCH(12'h140) ∧ ENABLE_S`：`sscratch <- wdata`。
		- `addr=ADDR_MEPC(12'h341)`：`mepc <- ENABLE_C ? {wdata[XLEN-1:1],1'b0} : {wdata[XLEN-1:2],2'b00}`。
		- `addr=ADDR_MCAUSE(12'h342)`：`mcause <- wdata`。
		- `addr=ADDR_MTVAL(12'h343)`：`mtval <- wdata`。
		- `addr=ADDR_MSCRATCH(12'h340)`：`mscratch <- wdata`。
		- `addr=ADDR_MCYCLE(12'hB00)`：`mcycle <- wdata`。
		- `addr=ADDR_MINSTRET(12'hB02)`：`minstret <- wdata`。

4. `flush`：取消暂存的 CSR 写。
	- Fire来源：`flush.fire = global_flush_late.fire`
		- `global_flush_late.fire`：见 `Interface -> In-event` 第 4 条。
	- Constraint：优先于 `capture` 对 `entry.valid` 的置位；不回滚架构存储。
	- Payload：∅。
	- State update：`entry.valid <- 0`；`entry.header` 和 `entry.payload` 保持。

5. `counter_tick`：更新自由运行计数器。
	- Fire来源：`counter_tick.fire = rst_n`
		- `rst_n`：见 `Interface -> In Static Info` 第 1 条。
	- Constraint：每个非复位上升沿 fire；同拍 `apply_fire` 对 `mcycle` 或 `minstret` 的写覆盖本 Event；本 Event 不改变 `entry.valid`，同拍 `capture`、`apply_fire` 或 `flush` fire 时由对应 Event 决定暂存状态，否则为本节所列自转移。
	- Payload：`commit_count` `COMMIT_COUNT_W` bit × 1；上升沿采样。
	- State update：`mcycle <- mcycle + XLEN'(1)`；`minstret <- minstret + XLEN'(commit_count)`。

6. `fflags_accrue`：累计本拍退休指令的 FP flags，并按实际 FP 副作用置脏 FS。
	- Fire来源：`fflags_accrue.fire = ∨{commit_valid[k].fire | k∈{0,...,ISSUE_WIDTH-1}}`
		- `commit_valid[k].fire`：见 `Interface -> In-event` 第 2 条。
	- Constraint：各 lane 的 `commit_fflags` 按位 OR；`apply_fire` 对 `fflags`、`frm` 或 `mstatus.fs` 的写覆盖本 Event；本 Event 不改变 `entry.valid`，同拍 `capture`、`apply_fire` 或 `flush` fire 时由对应 Event 决定暂存状态，否则为本节所列自转移。
	- Payload：`system_instruction_handler_commit_payload[k]`；上升沿采样。
	- State update：`fflags <- fflags ∨ fflags_accrued`；若 `fp_dirty=1`，`mstatus.fs <- FS_DIRTY`。
		- `fflags_accrued = ∨{commit_fflags[k] | commit_valid[k].fire}`。
		- `fp_dirty = ∨{commit_valid[k].fire ∧ ((rd_write_enable[k] ∧ rd_is_fp[k]) ∨ (commit_fflags[k]≠0))}`。

7. `trap_entry`：将 exception 或 interrupt trap 写入委托目标特权级。
	- Fire来源：`trap_entry.fire = trap_state_write.fire ∧ ((trap_state_write.kind=RECOVERY_EXCEPTION) ∨ (trap_state_write.kind=RECOVERY_INTERRUPT))`
		- `trap_state_write.fire`、`trap_state_write.kind`：见 `Interface -> In-event` 第 3 条。
	- Constraint：`trap_delegated=1` 时进入 S，否则进入 M；M 态发生的 trap 不委托；本 Event 对重叠架构字段的写优先于 `apply_fire`；本 Event 不改变 `entry.valid`，同拍 `capture`、`apply_fire` 或 `flush` fire 时由对应 Event 决定暂存状态，否则为本节所列自转移。
	- Payload：`trap_state_write_t`；上升沿采样。
	- State update：
		- `trap_delegated = ENABLE_S ∧ (current_priv≠PRIV_M) ∧ trap_state_write.fire ∧ (((trap_state_write.kind=RECOVERY_INTERRUPT) ∧ mideleg[trap_state_write.cause[5:0]]) ∨ ((trap_state_write.kind=RECOVERY_EXCEPTION) ∧ medeleg[trap_state_write.cause[5:0]]))`。
		- `mcause_trap_value = {(trap_state_write.kind=RECOVERY_INTERRUPT),trap_state_write.cause}`。
		- 若 `trap_delegated=0`：`mepc <- trap_state_write.epc`；`mcause <- mcause_trap_value`；`mtval <- trap_state_write.tval`；`mstatus.mpie <- mstatus.mie`；`mstatus.mie <- 0`；`mstatus.mpp <- current_priv`；`current_priv <- PRIV_M`。
		- 若 `trap_delegated=1`：`sepc <- trap_state_write.epc`；`scause <- mcause_trap_value`；`stval <- trap_state_write.tval`；`mstatus.spie <- mstatus.sie`；`mstatus.sie <- 0`；`mstatus.spp <- (current_priv=PRIV_S)`；`current_priv <- PRIV_S`。

8. `mret_update`：执行 MRET 特权返回更新。
	- Fire来源：`mret_update.fire = trap_state_write.fire ∧ (trap_state_write.kind=RECOVERY_MRET)`
		- `trap_state_write.fire`、`trap_state_write.kind`：见 `Interface -> In-event` 第 3 条。
	- Constraint：与 `trap_entry`、`sret_update` 互斥；对重叠架构字段的写优先于 `apply_fire`；本 Event 不改变 `entry.valid`，同拍 `capture`、`apply_fire` 或 `flush` fire 时由对应 Event 决定暂存状态，否则为本节所列自转移。
	- Payload：∅。
	- State update：`mstatus.mie <- mstatus.mpie`；`mstatus.mpie <- 1`；`current_priv <- mstatus.mpp`；`mstatus.mpp <- PRIV_U`。

9. `sret_update`：执行 SRET 特权返回更新。
	- Fire来源：`sret_update.fire = trap_state_write.fire ∧ (trap_state_write.kind=RECOVERY_SRET)`
		- `trap_state_write.fire`、`trap_state_write.kind`：见 `Interface -> In-event` 第 3 条。
	- Constraint：与 `trap_entry`、`mret_update` 互斥；对重叠架构字段的写优先于 `apply_fire`；本 Event 不改变 `entry.valid`，同拍 `capture`、`apply_fire` 或 `flush` fire 时由对应 Event 决定暂存状态，否则为本节所列自转移。
	- Payload：∅。
	- State update：`mstatus.sie <- mstatus.spie`；`mstatus.spie <- 1`；`current_priv <- mstatus.spp ? PRIV_S : PRIV_U`；`mstatus.spp <- 0`。

## Data structure

### State

1. `IDLE / STAGED`：语义状态压缩进 `entry.valid`；`0` 表示 `IDLE`，`1` 表示 `STAGED`。
2. `entry.valid`：1 bit；由 `reset`、`capture`、`apply_fire` 和 `flush` 更新。
3. `mstatus`：`mie` 1 bit、`mpie` 1 bit、`fs` `FS_W=2` bit、`mpp` `PRIV_W` bit、`sie` 1 bit、`spie` 1 bit、`spp` 1 bit、`sum` 1 bit、`mxr` 1 bit、`tvm` 1 bit、`tw` 1 bit、`tsr` 1 bit；`FS_OFF=2'b00`、`FS_DIRTY=2'b11`；由 `reset`、`apply_fire`、`fflags_accrue`、`trap_entry`、`mret_update` 和 `sret_update` 更新。
4. `current_priv`：`PRIV_W` bit；取值 `PRIV_M`、`PRIV_S` 或 `PRIV_U`；由 `reset`、`trap_entry`、`mret_update` 和 `sret_update` 更新。
5. `mie`：`meie`、`mtie`、`msie`、`seie`、`stie`、`ssie`，各 1 bit；由 `reset` 和 `apply_fire` 更新。
6. `mip.ssip`：1 bit；由 `reset` 和 `apply_fire` 更新。
7. `mtvec`、`stvec`：各由 `base[XLEN-1:2]` 和 `mode[1:0]` 构成；`mode∈{MTVEC_MODE_DIRECT=2'b00,MTVEC_MODE_VECTORED=2'b01}`，其他写入值保持原 mode；由 `reset` 和 `apply_fire` 更新。
8. `mepc`、`mcause`、`mtval`、`mscratch`：各 `XLEN=64` bit；由 `reset`、`apply_fire` 或 `trap_entry` 更新。
9. `sepc`、`scause`、`stval`、`sscratch`：各 `XLEN` bit；由 `reset`、`apply_fire` 或 `trap_entry` 更新。
10. `medeleg`、`mideleg`：各 `XLEN` bit；由 `reset` 和 `apply_fire` 更新。
11. `satp`：`XLEN` bit；支持 MODE `0`、`8`、`9`，其他 MODE 写入保持；由 `reset` 和 `apply_fire` 更新。
12. `mcycle`、`minstret`：各 `XLEN` bit；由 `reset`、`counter_tick` 和 `apply_fire` 更新。
13. `fflags`：`FFLAGS_W=5` bit；由 `reset`、`fflags_accrue` 和 `apply_fire` 更新。
14. `frm`：`FRM_W=$bits(rm_e)=3` bit；由 `reset` 和 `apply_fire` 更新。

### Header

1. `entry.header.tag`：`TAG_W=4` bit；用于 `apply_fire` 的 commit tag 匹配；由 `capture` 更新。
2. `entry.header.addr`：`CSR_ADDR_W=12` bit；用于 `apply_fire` 的 CSR 写地址选择；由 `capture` 更新。

### Payload

1. `entry.payload`：来源于 `system_instruction_handler_csr_sideband_payload`。
	- `system_instruction_handler_csr_sideband_payload`：`tag_out`、`sb_csr_addr`、`sb_csr_wdata`。

## Internal Connections

无。

## Interface

### In-event

1. `csr_sideband_valid`：Notify，单 lane。
	- Fire来源：`csr_sideband_valid.fire`。
	- Payload：`system_instruction_handler_csr_sideband_payload`；上升沿采样。
	`system_instruction_handler_csr_sideband_payload`：`tag_out` `TAG_W` bit、`sb_is_csr` 1 bit、`sb_csr_write_enable` 1 bit、`sb_csr_addr` `CSR_ADDR_W` bit、`sb_csr_wdata` `XLEN` bit。
2. `commit_valid[k]`：Notify，`k∈{0,...,ISSUE_WIDTH-1}`。
	- Fire来源：`commit_valid[k].fire`。
	- Payload：`system_instruction_handler_commit_payload[k]`；上升沿采样。
	`system_instruction_handler_commit_payload[k]`：`commit_tag` `TAG_W` bit、`commit_fflags` `FFLAGS_W` bit、`rd_is_fp` 1 bit、`rd_write_enable` 1 bit。
3. `trap_state_write`：Notify，单 lane。
	- Fire来源：`trap_state_write.fire`。
	- Payload：`trap_state_write_t`；上升沿采样。
	`trap_state_write_t`：`kind` `RECOVERY_KIND_W` bit、`epc` `XLEN` bit、`cause` `EXCP_CAUSE_W` bit、`tval` `XLEN` bit。
4. `global_flush_late`：Notify，单 lane。
	- Fire来源：`global_flush_late.fire`。
	- Payload：∅；当前拍 pulse。

### In Static Info

1. `rst_n`：1 bit；低有效异步复位。
2. `commit_count`：`COMMIT_COUNT_W` bit；当前拍退休 entry 数量，取值 `0..ISSUE_WIDTH`。
3. `csr_addr`：`CSR_ADDR_W` bit；当前拍软件 CSR 读地址。
4. `trap_cause_in`：`EXCP_CAUSE_W` bit；当前拍 trap vector cause。
5. `trap_is_interrupt_in`：1 bit；当前拍 trap vector 请求是否为 interrupt。
6. `mip_meip`：1 bit；当前拍 MEIP 电平。
7. `mip_mtip`：1 bit；当前拍 MTIP 电平。
8. `mip_msip`：1 bit；当前拍 MSIP 电平。

### Out-event

无。

### Out Static Info

1. `csr_rdata`：`XLEN` bit；当前拍有效。
	- `csr_rdata = CSR[csr_addr]`
		- `csr_addr`：见 `Interface -> In Static Info` 第 3 条。
		- `CSR[ADDR_FFLAGS] = zero_extend(fflags)`；`CSR[ADDR_FRM] = zero_extend(frm)`；`CSR[ADDR_FCSR] = zero_extend({frm,fflags})`。
			- `fflags`、`frm`：见 `Data structure -> State` 第 13、14 条。
		- `CSR[ADDR_MSTATUS] = mstatus_view`；`CSR[ADDR_SSTATUS] = mstatus_view ∧ SSTATUS_MASK`。
			- `mstatus_view[63]=(mstatus.fs=FS_DIRTY)`；`mstatus_view[35:34]=ENABLE_S ? 2'b10 : 0`；`mstatus_view[33:32]=ENABLE_U ? 2'b10 : 0`；`mstatus_view[22,21,20,19,18,14:13,12:11,8,7,5,3,1]=mstatus.{tsr,tw,tvm,mxr,sum,fs,mpp,spp,mpie,spie,mie,sie}`；其余位为 0。
				- `mstatus`：见 `Data structure -> State` 第 3 条。
			- `SSTATUS_MASK=(1<<63)∨(1<<19)∨(1<<18)∨(3<<32)∨(3<<13)∨(1<<8)∨(1<<5)∨(1<<1)`。
		- `CSR[ADDR_MIE] = mie_view`；`CSR[ADDR_SIE] = mie_view ∧ mideleg`。
			- `mie_view[11,9,7,5,3,1]=mie.{meie,seie,mtie,stie,msie,ssie}`；其余位为 0。
				- `mie`：见 `Data structure -> State` 第 5 条。
			- `mideleg`：见 `Data structure -> State` 第 10 条。
		- `CSR[ADDR_MIP] = mip_view`；`CSR[ADDR_SIP] = mip_view ∧ mideleg`。
			- `mip_view[11]=mip_meip`；`mip_view[7]=mip_mtip`；`mip_view[3]=mip_msip`；`mip_view[1]=mip.ssip`；其余位为 0。
				- `mip_meip`、`mip_mtip`、`mip_msip`：见 `Interface -> In Static Info` 第 6、7、8 条。
				- `mip.ssip`：见 `Data structure -> State` 第 6 条。
			- `mideleg`：见 `Data structure -> State` 第 10 条。
		- `CSR[ADDR_MTVEC]=mtvec`；`CSR[ADDR_STVEC]=stvec`；`CSR[ADDR_MSCRATCH]=mscratch`；`CSR[ADDR_MEPC]=mepc`；`CSR[ADDR_MCAUSE]=mcause`；`CSR[ADDR_MTVAL]=mtval`；`CSR[ADDR_SSCRATCH]=sscratch`；`CSR[ADDR_SEPC]=sepc`；`CSR[ADDR_SCAUSE]=scause`；`CSR[ADDR_STVAL]=stval`；`CSR[ADDR_MEDELEG]=medeleg`；`CSR[ADDR_MIDELEG]=mideleg`；`CSR[ADDR_SATP]=satp`；`CSR[ADDR_MCYCLE]=CSR[ADDR_CYCLE(12'hC00)]=mcycle`；`CSR[ADDR_MINSTRET]=CSR[ADDR_INSTRET(12'hC02)]=minstret`。
			- 对应存储：见 `Data structure -> State` 第 7–12 条。
		- `CSR[ADDR_MISA(12'h301)] = {2'b10,zero,MISA_EXT}`；`MISA_EXT[A,C,D,F,I,M,S,U]={ENABLE_A,ENABLE_C,ENABLE_FD,ENABLE_FD,1,1,ENABLE_S,ENABLE_U}`。
		- `CSR[ADDR_MVENDORID(12'hF11)]`、`CSR[ADDR_MARCHID(12'hF12)]`、`CSR[ADDR_MIMPID(12'hF13)]`、`CSR[ADDR_MHARTID(12'hF14)]`、`CSR[ADDR_PMPCFG0(12'h3A0)]`、`CSR[ADDR_PMPADDR0(12'h3B0)]` 和未匹配地址均为 0。
2. `current_priv`：`PRIV_W` bit；当前拍有效。
	- `current_priv = Data structure.current_priv`
		- `Data structure.current_priv`：见 `Data structure -> State` 第 4 条。
3. `frm`：`rm_e`，`FRM_W` bit；当前拍有效。
	- `frm = rm_e'(Data structure.frm)`
		- `Data structure.frm`：见 `Data structure -> State` 第 14 条。
4. `fs_enabled`：1 bit；当前拍有效。
	- `fs_enabled = (mstatus.fs ≠ FS_OFF)`
		- `mstatus.fs`、`FS_OFF`：见 `Data structure -> State` 第 3 条。
5. `trap_vector`：`XLEN` bit；当前拍有效。
	- `trap_vector = ((tvec_mode_sel=MTVEC_MODE_VECTORED) ∧ trap_is_interrupt_in) ? (tvec_base + (zero_extend(trap_cause_in)<<2)) : tvec_base`
		- `tvec_mode_sel = trap_delegated ? stvec.mode : mtvec.mode`
			- `trap_delegated`：见 `FSM -> Detailed Condition Description` 第 7 条。
			- `stvec.mode`、`mtvec.mode`、`MTVEC_MODE_VECTORED`：见 `Data structure -> State` 第 7 条。
		- `trap_is_interrupt_in`：见 `Interface -> In Static Info` 第 5 条。
		- `tvec_base = trap_delegated ? {stvec.base,2'b00} : {mtvec.base,2'b00}`
			- `trap_delegated`：见 `FSM -> Detailed Condition Description` 第 7 条。
			- `stvec.base`、`mtvec.base`：见 `Data structure -> State` 第 7 条。
		- `trap_cause_in`：见 `Interface -> In Static Info` 第 4 条。
6. `interrupt_pending`：1 bit；当前拍有效。
	- `interrupt_pending = |takeable`
		- `takeable = (m_enabled ? m_targeted : 0) ∨ (s_enabled ? s_targeted : 0)`
			- `m_enabled = (current_priv=PRIV_M) ? mstatus.mie : 1`
				- `current_priv`：见 `Data structure -> State` 第 4 条。
				- `mstatus.mie`：见 `Data structure -> State` 第 3 条。
			- `m_targeted = pending_bits ∧ ¬mideleg`
				- `pending_bits = mie_view ∧ mip_view`
					- `mie_view`、`mip_view`：见本节第 1 条。
				- `mideleg`：见 `Data structure -> State` 第 10 条。
			- `s_enabled = (current_priv=PRIV_M) ? 0 : (current_priv=PRIV_S) ? mstatus.sie : 1`
				- `current_priv`：见 `Data structure -> State` 第 4 条。
				- `mstatus.sie`：见 `Data structure -> State` 第 3 条。
			- `s_targeted = pending_bits ∧ mideleg`
				- `pending_bits`：见本条 `m_targeted` 公式。
				- `mideleg`：见 `Data structure -> State` 第 10 条。
7. `interrupt_cause`：`EXCP_CAUSE_W` bit；`interrupt_pending=1` 时有效，无可取中断时为 0。
	- `interrupt_cause = takeable[11] ? 11 : takeable[3] ? 3 : takeable[7] ? 7 : takeable[9] ? 9 : takeable[1] ? 1 : takeable[5] ? 5 : 0`
		- `takeable`：见本节第 6 条。
8. `mepc`：`XLEN` bit；当前拍有效。
	- `mepc = Data structure.mepc`
		- `Data structure.mepc`：见 `Data structure -> State` 第 8 条。
9. `sepc`：`XLEN` bit；当前拍有效。
	- `sepc = Data structure.sepc`
		- `Data structure.sepc`：见 `Data structure -> State` 第 9 条。
10. `mstatus_tvm`：1 bit；当前拍有效。
	- `mstatus_tvm = mstatus.tvm`
		- `mstatus.tvm`：见 `Data structure -> State` 第 3 条。
11. `mstatus_tw`：1 bit；当前拍有效。
	- `mstatus_tw = mstatus.tw`
		- `mstatus.tw`：见 `Data structure -> State` 第 3 条。
12. `mstatus_tsr`：1 bit；当前拍有效。
	- `mstatus_tsr = mstatus.tsr`
		- `mstatus.tsr`：见 `Data structure -> State` 第 3 条。

### Interface Timing

1. `clk`：非复位存储在上升沿更新。
2. `rst_n`：低有效异步复位；复位清除暂存项和架构状态，并将 `current_priv`、`mstatus.mpp`、`frm` 分别置为 `PRIV_M`、`PRIV_M`、`RM_RNE`。
3. `Transaction`：无。
4. `Notify`：输入 Event 在 fire 所在上升沿采样；本模块不提供背压；`global_flush_late` 仅清除 CSR 暂存，不回滚架构状态。
5. `Static Info`：组合输出在当前拍持续有效；`csr_rdata` 随 `csr_addr` 变化，`trap_vector` 随 trap vector 参数变化，interrupt 输出随外部中断电平和架构使能状态变化。
