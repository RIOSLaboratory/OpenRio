# ORBE FE Agent Mock Test Plan

> 本文定义 ORBE FE Agent 在没有完整 DUT RTL 时的 Verilator mock test 验证方案。
> 目标是验证 FE Agent 对 ORBE FE/BE 外部接口的可见行为，不证明 backend
> decode、ROB、execute、commit、LSU、cache 或 tohost 闭环的正确性。

## 1. 验证目标

mock test 使用一个可控的 mock DUT wrapper，向 FE Agent 返回 `ready` 和
`redirect`，并对 FE Agent 的输出进行观测和检查。

本方案验证以下行为：

- FE Agent 能从 ISA Model 的 instruction memory 读取 raw instruction。
- FE Agent 能形成两条按程序顺序排列的 instruction lane。
- lane 0 保持 older instruction，lane 1 保持 younger instruction。
- ready/valid handshake 遵守 prefix fire 语义。
- ready stall 时未接收 payload 保持稳定。
- lane 0 fire、lane 1 未 fire 时，lane 1 entry 能压缩到 lane 0。
- redirect 到来时，旧路径 pending 被清除，并从 redirect PC 重新取指。
- RVC 保留原始 16-bit encoding，并使用正确的 payload 标记。
- fetch-to-EOF 策略不会把无效的零填充或 partial instruction 作为普通 instruction 发送给 DUT；真实 fetch fault 通过 exception entry 交付。

验证结果以 mock test 的接口观测和 checker 结果为准，不以 ISA Model 的
`isa_dpi_is_to_exit()` 或 `isa_dpi_is_good()` 作为 FE-only smoke 的唯一通过条件。

## 2. 测试边界

### 2.1 本方案包含

- ORBE FE/BE 2-lane instruction interface。
- ISA Model 的初始化、ELF 装载和只读取指 API。
- `ready`、`redirect`、stall、compaction 和 payload stability。
- RVC、32-bit instruction、EOF、fetch exception 和 redirect 后重取指。
- Verilator 下的 clock、reset、DPI、有限周期结束和结果报告。

### 2.2 本方案不包含

- backend decode 或 execution sub-op 生成。
- ROB/tag allocation、execute、commit 或 flush 生命周期。
- LSU、cache、store drain 或 tohost PASS/FAIL 闭环。
- BE 对 FE fetch exception entry 的 `rob_idx` 绑定或 `isa_dpi_trigger_trap()` 调用。
- 对 branch/jump 指令执行结果的验证。
- 完整 DUT wrapper 的内部实现和 backend white-box 观测。

mock wrapper 只提供 FE Agent 可见的外部响应，不调用
`isa_dpi_decode_and_issue`、`isa_dpi_execute_insn`、`isa_dpi_commit_auto`、
`isa_dpi_flush` 或 `isa_dpi_flush_all`。

## 3. 输入 Case 和 ELF 约定

测试输入来自：

```text
beta_be_bt_env/isa_case/
```

目录中的 `.riscv` 文件是已经生成好的 RISC-V ELF executable。`.riscv` 是
文件后缀约定，不代表源文件格式。测试不需要再次使用 GCC 编译这些 case；
只有在新增 C/assembly 测试源时，才需要通过 RISC-V GCC 生成新的 ELF。

运行前可在 Ubuntu 中确认文件类型：

```bash
file /path/to/case.riscv
```

输出应表明它是 RISC-V ELF executable。FE Agent 通过以下信息加载 case：

```text
+ISA_CFG=<platform.yaml>
+ISA_ELF=<case.riscv>
```

测试只使用 ISA Model 的以下能力：

- `isa_dpi_create`
- `isa_dpi_load_config`
- `isa_dpi_load_elf`
- `isa_dpi_add_arg`
- `isa_dpi_finalize_config`
- `isa_dpi_get_spec_pc`
- `isa_dpi_fetch_mem_bank_virt`
- 必要的只读状态查询

mock test 不推进 backend model lifecycle。单个 FE-only test 结束时由唯一的
Model owner 销毁 ISA Model，然后结束仿真。

## 4. 测试目录和组件

Verilator mock flow 独立放在：

```text
orbe_bt_env/mock_tb/
```

建议的源文件组织如下：

```text
mock_tb/
  Makefile
  orbe_fe_mock_if.sv
  orbe_fe_mock_fe_agent.sv
  orbe_fe_mock_wrapper.sv
  orbe_fe_mock_monitor.sv
  orbe_fe_mock_tb_top.sv
  run_regression.py
  build/
```

`build/` 只保存 Verilator 生成的 C++、可执行文件、日志、波形和回归结果，
不作为源码输入。

### 4.1 Mock FE interface

`orbe_fe_mock_if.sv` 定义与 ORBE 设计一致的接口：

```text
FE -> BE  fe_be_instr_valid[1:0]
FE -> BE  fe_be_instr_pld[1:0]
BE -> FE  be_fe_instr_ready[1:0]
BE -> FE  be_fe_redirect_valid
BE -> FE  be_fe_redirect_pld
```

payload 类型应保持与 [ORBE_FE_AGENT_INTERFACE_SPEC_brief.md](../interface/ORBE_FE_AGENT_INTERFACE_SPEC_brief.md)
以及 [ORBE_FE_AGENT_DESIGN_PLAN.md](../archive/ORBE_FE_AGENT_DESIGN_PLAN.md) 一致（已归档）。

### 4.2 Verilator FE agent

Verilator mock 使用 module-based FE agent 作为仿真入口。它必须复现当前
`fe_driver.sv` 的设计语义，但不应直接把 VCS flow 中依赖 class、配置对象和
`virtual interface` 的入口当作 Verilator top 的唯一入口。

module-based FE agent 的行为要求：

- 只由一个组件拥有 ISA Model 的 create/destroy 生命周期。
- 只从 ISA Model 取指，不调用 backend lifecycle API。
- 维护最多两个 pending entry。
- 采用 2-lane prefix fire 和 compaction 规则。
- 在 redirect 时丢弃旧 pending，并从 redirect PC refill。
- 在 EOF 时停止新增 entry，但保留已经存在的 pending entry；真实 fetch fault 生成一个 exception entry，并在该 entry 后停止新增 younger entry。

为使 fetch exception 场景在当前 ISA Model memory 行为下可重复，mock agent 支持
test-only plusarg 强制在指定 PC 生成 exception entry。该注入点只用于验证 FE/BE
payload、ready/stall、compaction 和 redirect 语义；正式 class-based `fe_driver.sv`
仍以 `isa_dpi_fetch_mem_bank_virt` 返回非 PASS 作为真实 fetch fault 来源。

这不是对 class-based `fe_driver.sv` 设计语义的改变，而是为了适配
Verilator top 的连接方式。class driver 与 module-based mock agent 的行为必须
共享同一份 protocol contract。

### 4.3 Mock DUT wrapper

`orbe_fe_mock_wrapper.sv` 只提供 FE Agent 可见的 BE 响应：

- `be_fe_instr_ready[1:0]`
- `be_fe_redirect_valid`
- `be_fe_redirect_pld`

wrapper 不解析 instruction，不生成 decode 结果，不调用 ISA Model，不维护
backend ROB。ready 和 redirect 由场景状态机控制。

### 4.4 Monitor/checker

`orbe_fe_mock_monitor.sv` 负责记录和检查：

- 每周期 valid、ready 和 fire。
- 每笔 fire 的 lane、PC 和 payload。
- stall 期间的 payload 稳定性。
- lane prefix fire 和 lane 顺序。
- RVC/32-bit payload 格式。
- redirect 优先级和 redirect 后首条 PC。
- old path entry 是否在 redirect 后再次 fire。

## 5. Protocol Semantics

### 5.1 Lane order

lane 0 是 older instruction，lane 1 是 younger instruction。两个 lane 不能
被视为两个相互独立的无序事务。

### 5.2 Fire 规则

```text
fire[0] = valid[0] && ready[0]
fire[1] = valid[1] && ready[1] && fire[0]
```

lane 1 不能在 lane 0 没有 fire 时独立 fire。mock wrapper 不替 FE Agent 修正
非法 fire 组合；monitor 必须能够发现：

```text
fire[1] == 1 && fire[0] == 0
```

### 5.3 Payload stability

如果某个 valid entry 没有 fire，则同一条未接收 instruction 的以下字段必须
保持不变，直到该 entry fire 或 redirect 到来：

```text
pc
inst_bits
is_compressed
pred_taken
pred_target_pc
fetch_excp_vld
exception_cause
exception_tval
```

测试中至少覆盖 `ready=2'b00` 和 `ready=2'b01` 两种 stall 情况。

### 5.4 Compaction

当 lane 0 fire 而 lane 1 没有 fire 时，原 lane 1 entry 必须在下一次发送
时出现在 lane 0。该 entry 的所有 payload 字段必须保持一致，不得因为 lane
移动而被新取指 entry 覆盖。

当 lane 0 没有 fire 时，lane 0 的未接收 entry 不能被新 entry 覆盖；如果
lane 1 也有效，lane 1 也不能独立 fire。

### 5.5 Redirect priority

redirect 与 fire 在同一个采样周期发生时，redirect 优先：

- 旧路径 pending 直接丢弃。
- 旧路径 payload 不计为有效交付结果。
- redirect PC 被保存。
- 当前周期停止普通 instruction 输出。
- 下一周期从 redirect PC 重新 refill。

redirect 后第一条有效 entry 的 `pc` 必须等于 redirect PC。

## 6. Fetch 和 payload 规则

### 6.1 RVC

当 low halfword 的 `inst[1:0] != 2'b11` 时，FE Agent 生成：

```text
inst_bits[15:0]  = low_halfword
inst_bits[31:16] = 16'h0000
is_compressed    = 1
pred_taken       = 0
pred_target_pc   = pc + 2
```

FE 不把 RVC 解压成 32-bit instruction 发送给 BE。

### 6.2 32-bit instruction

当 low halfword 的 `inst[1:0] == 2'b11` 时，FE Agent 读取 `pc + 2` 的
high halfword，形成：

```text
inst_bits       = {high_halfword, low_halfword}
is_compressed   = 0
pred_taken      = 0
pred_target_pc  = pc + 4
```

如果 high halfword 取指失败，不发送 partial instruction。

### 6.3 EOF 和 fetch exception

当前采用 fetch-to-EOF 策略：

- low halfword 取指返回非 PASS 且携带支持的同步 fetch cause 时，生成 exception entry；其 `exception_tval=pc`。
- low halfword 等于 `16'h0000` 时，设置 EOF，不把零填充当作非法指令发送。
- 32-bit instruction 的 high halfword 取指返回非 PASS 且携带支持的同步 fetch cause 时，生成 exception entry；不发送 partial instruction，且 `exception_tval=pc+2`。
- EOF 只阻止新 entry 产生，不清除已经存在的 pending entry。
- 只有 redirect 会清空旧 pending，并清除 fetch EOF。
- exception entry 的固定字段为 `inst_bits=32'h0000_0013`、`is_compressed=0`、`pred_taken=0`、`pred_target_pc=pc`；`fetch_excp_vld=1`，`exception_cause` 为支持的 TrapType 低 5 bit。
- 异常 entry fire 后停止产生 younger entry；异常 entry 未 fire 时遵守 payload stability。redirect 清除该停止状态并从 redirect PC 重取。

## 7. Clock、reset 和采样约定

Verilator mock 使用 `--timing`，并显式产生 clock 和 reset。所有 ready、redirect、
valid、payload 在 reset 期间必须初始化，不能依赖 X/Z 传播或未知值行为。

建议的时序约定如下：

```text
negedge clk: mock wrapper 驱动 ready/redirect
posedge clk: FE agent 采样 redirect，更新当前输出组
稳定采样点: monitor 观察 valid/payload/ready 并计算 fire
```

具体实现可以选择固定的半周期延迟，但 wrapper、FE agent 和 monitor 必须使用
同一套采样约定。测试不得在 redirect 采样周期把旧路径 payload 记录为有效 fire。

reset 期间：

- `fe_be_instr_valid = 0`。
- instruction payload 清零。
- `be_fe_instr_ready` 和 redirect 信号显式初始化。
- reset 释放前不进行取指和 payload 检查。

## 8. 测试场景矩阵

### 8.1 基础场景

| 场景 | ready 模式 | redirect | 主要检查 |
| --- | --- | --- | --- |
| `ready_all` | `2'b11` | 无 | 连续取指、顺序、基础 payload。 |
| `stall_all` | `2'b00` | 无 | 两条 valid entry 的 payload stability。 |
| `stall_lane0` | `2'b01` | 无 | lane 0 stall，lane 1 不能独立 fire。 |
| `lane0_only` | `2'b10` | 无 | lane 0 fire、lane 1 保留并压缩到 lane 0。 |
| `lane1_ready_only` | `2'b01` | 无 | ready lane 1 不得绕过 lane 0。 |

### 8.2 Redirect 场景

| 场景 | ready 模式 | redirect 时机 | 主要检查 |
| --- | --- | --- | --- |
| `redirect_normal` | `2'b11` | 有 pending 后 | 旧路径清除、从新 PC 开始。 |
| `redirect_under_stall` | `2'b00` | stall 期间 | stall 中的旧 pending 也被清除。 |
| `redirect_after_lane0_fire` | `2'b10` | compaction 前后 | redirect 优先于普通压缩。 |
| `redirect_same_cycle` | `2'b11` | ready/fire 同拍 | 旧路径不计为有效交付。 |
| `redirect_twice` | 可变 | 连续 redirect | 最后一次有效 redirect target 生效。 |
| `fetch_exception` | `2'b11` | redirect 到 fault PC | mock 注入 fetch fault 后生成一个异常 entry，检查 cause、tval、占位 NOP 和 fault 后停止。 |
| `fetch_exception_under_stall` | fault 前后可变 | redirect 后保持 stall | mock 注入的异常 entry 在 ready stall 时保持稳定，之后按 prefix fire 交付。 |

普通 redirect 场景的 redirect target 必须来自对应 ELF 的有效 executable 区域。
`fetch_exception` 场景默认 redirect 到 `FETCH_EXCEPTION_PC`，并打开
`MOCK_FORCE_FETCH_EXCP`，确保 mock 中稳定出现一个 fetch exception entry；该场景不把
fault 视为 EOF。

### 8.3 当前已执行结果

截至当前 mock bring-up，以下 smoke 已在 WSL2 `Ubuntu-24.04` + Verilator 下执行通过。
这些结果只说明 FE-only mock checker 覆盖到的接口行为通过，不外推为 backend correctness。

| 类型 | 场景 | ELF case | 结果 | 观测摘要 |
| --- | --- | --- | --- | --- |
| Build | `make lint` | N/A | PASS | Verilator lint 通过。 |
| Build | `make build` | N/A | PASS | Verilator binary 构建通过。 |
| Base | `ready_all` | `rv64ui/rv64ui-p-add.riscv` | PASS | `fire_count=200`。 |
| Base | `stall_all` | `rv64ui/rv64ui-p-add.riscv` | PASS | `fire_count=192`，stall payload stability 通过。 |
| Base | `stall_lane0` | `rv64ui/rv64ui-p-add.riscv` | PASS | `fire_count=192`，lane 1 未越过 lane 0。 |
| Base | `lane0_only` | `rv64ui/rv64ui-p-add.riscv` | PASS | `fire_count=196`，lane 1 compaction 通过。 |
| RVC | `ready_all` | `rv64uc/rv64uc-p-rvc.riscv` | PASS | `fire_count=200`，RVC payload 格式通过。 |
| RVC | `ready_all` | `rv64uc/rv64uc-v-rvc.riscv` | PASS | `fire_count=128`，RVC payload 格式通过。 |
| Redirect | `redirect_normal` | `rv64ui/rv64ui-p-add.riscv` | PASS | `fire_count=198`，`redirect_count=1`。 |
| Redirect | `redirect_under_stall` | `rv64ui/rv64ui-p-add.riscv` | PASS | `fire_count=182`，`redirect_count=1`，stall 中 old pending 被清除。 |
| Redirect | `redirect_same_cycle` | `rv64ui/rv64ui-p-add.riscv` | PASS | `fire_count=198`，`redirect_count=1`，redirect 与 ready/fire 同拍时 redirect 优先。 |
| Redirect | `redirect_twice` | `rv64ui/rv64ui-p-add.riscv` | PASS | `fire_count=196`，`redirect_count=2`，第二次 redirect target 生效。 |
| Fetch exception | `fetch_exception` | `rv64ui/rv64ui-p-add.riscv` | PASS | `fire_count=17`，`redirect_count=1`，`exception_count=1`，异常 entry 字段检查通过。 |
| Fetch exception | `fetch_exception_under_stall` | `rv64ui/rv64ui-p-add.riscv` | PASS | `fire_count=1`，`redirect_count=1`，`exception_count=1`，异常 entry stall stability 通过。 |

默认运行结束时输出一行 `[ORBE_FE_MOCK_RESULT]` summary，包含 scenario、fire 数、
redirect 数、exception 数、checker error 数和 timeout 周期。逐条 fire trace 默认关闭；需要定位 payload 细节时可使用：

```bash
make run ELF=/absolute/path/to/case.riscv VERBOSE_FIRE=1
```

## 9. Checker 通过标准

### 9.1 每周期协议检查

每个稳定采样点检查：

```text
valid[1] -> valid[0]
fire[0] = valid[0] && ready[0]
fire[1] = valid[1] && ready[1] && fire[0]
```

### 9.2 每笔 payload 检查

所有被记录的 instruction entry 检查：

- `pc` 按取指长度递增，或等于 redirect target 的新流首 PC。
- `pred_taken == 0`。
- 普通 entry 满足 `fetch_excp_vld == 0`、`exception_cause == 0`、`exception_tval == 0`。
- 异常 entry 满足 `fetch_excp_vld == 1`、支持的 cause、固定 NOP 占位字段和对应的 `exception_tval`。
- 异常 entry fire 后，redirect 前不得继续 fire 新 entry。
- compressed entry 满足 RVC 规则。
- non-compressed entry 满足 32-bit raw instruction 规则。

### 9.3 Redirect 检查

每次 redirect 检查：

- redirect payload 与 `be_fe_redirect_valid` 同拍有效。
- redirect target 被保存，没有被后续旧路径操作覆盖。
- redirect 采样后旧 pending 不再 fire。
- 下一周期重新输出的第一条 entry 满足 `pc == redirect_pc`。
- redirect 后的新 entry 也遵守 stall stability 和 prefix fire。

### 9.4 有限周期结束

FE-only smoke 使用固定的 `MOCK_TIMEOUT_CYCLES` 或场景完成条件结束，不能
无限等待 ISA Model exit。结束时：

1. 停止继续产生 ready/redirect 场景。
2. 停止 FE Agent 的运行过程。
3. 由 Model owner 调用 `isa_dpi_destroy()`。
4. 输出 monitor/checker summary。
5. 有错误时以非零状态退出。

## 10. 通过与失败定义

### 10.1 通过

满足以下条件时，当前 FE-only mock test 通过：

- Verilator lint 和 build 成功。
- ISA Model、platform YAML 和 `.riscv` ELF 加载成功。
- 所有场景在有限周期内完成。
- 没有 prefix fire、lane 顺序、payload stability 或 redirect 错误。
- RVC、32-bit、EOF 和异常字段检查通过。
- Model lifecycle 没有重复 create 或重复 destroy。

### 10.2 失败

出现以下任意情况时失败：

- DPI/ELF/config 加载失败。
- reset 期间产生 valid instruction。
- lane 1 在 lane 0 未 fire 时独立 fire。
- ready stall 时 payload 被覆盖或改变。
- compaction 后 payload 与原 lane 1 不一致。
- redirect 后旧路径 entry 再次 fire。
- redirect 后首条 entry 的 PC 不等于 redirect PC。
- 真实 fetch failure 被错误转换成 EOF，或异常 entry 字段/停止行为不符合协议。
- 运行超时或出现 Verilator fatal/error。

通过 mock test 不代表 backend correctness，也不代表真实 DUT 的 redirect 产生
逻辑、ROB allocation、LSU、cache 或 commit 行为正确。

## 11. Verilator 和 Ubuntu 运行环境

本方案使用 WSL2 中的 `Ubuntu-24.04` 运行 Verilator mock。当前已确认的工具
包括：

- Verilator 5.020。
- g++ 13.3。
- `riscv64-unknown-elf-gcc`。
- GNU make。

已有 ISA Model 动态库是 Linux x86-64 ELF shared library：

```text
$ISA_API_LIB/lib_ISA_api.so
```

因此推荐在 Ubuntu/WSL 中编译和运行，而不是使用 Windows 原生进程加载该
`.so`。Windows 文件路径在 WSL 中通过 `/mnt/c/...` 访问。

建议源码和构建输出在 WSL Linux 文件系统中时，使用本地 Linux 路径以改善
Verilator 增量编译速度；功能验证阶段也可以直接从 `/mnt/c/...` 读取源码、
ISA Model 和 `.riscv` case。

独立 mock Makefile 需要覆盖：

- `--timing`。
- `--top-module orbe_fe_mock_tb_top`。
- `isa_dpi_pkg.sv`。
- `isa_dpi_wrapper.cc`。
- ISA Model include directory。
- ISA Model library directory 和运行时 library path。
- `mock_tb` 下的所有 SystemVerilog source。

当前 VCS flow 的 `sim/Makefile` 不作为 Verilator flow 的构建入口。

## 12. 第一阶段实施顺序

按以下顺序逐步扩大测试范围：

1. 建立 `orbe_fe_mock_if.sv` 和 `orbe_fe_mock_tb_top.sv`，确认 clock/reset。
2. 实现 module-based FE agent，完成 DPI create/config/load/fetch。
3. 使用固定 `ready=2'b11` 的 wrapper，输出第一组 raw instruction。
4. 加入 monitor，先检查第一条或前若干条 instruction 的 payload。
5. 运行 `make lint` 和 `make build`。
6. 使用一个简单的 `.riscv` case 运行有限周期 smoke。
7. 加入 `stall_all`、`stall_lane0` 和 `lane0_only`。
8. 加入 payload stability 和 compaction checker。
9. 加入 normal redirect、stall redirect 和 same-cycle redirect。
10. 最后增加多个 `.riscv` case 的 regression runner。

每一步都应保留清晰的 scenario 名称和日志。第一阶段不引入 backend observer、
LSU、cache 或完整 tohost 生命周期。

## 13. 后续接入真实 DUT Wrapper

真实 DUT Wrapper 接入后，保留以下稳定边界：

- FE Agent 继续发送 raw instruction payload。
- DUT/Wrapper 继续负责返回 ready 和 redirect。
- FE Agent 继续维护 prefix fire、stall stability、compaction 和 redirect 清空。
- mock wrapper 替换为真实 DUT 可见响应，不把 mock-only checker 逻辑塞入 FE Agent。

接入真实 backend 后，需要另行定义 ISA Model 的唯一 lifecycle owner，并重新
规划 decode、execute、commit、flush、LSU、cache 和 tohost 验证。本文档的
FE-only 通过结果不能直接外推为完整 ORBE BT 通过结果。
