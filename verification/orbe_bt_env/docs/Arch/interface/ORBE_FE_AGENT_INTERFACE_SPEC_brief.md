# FE Agent To DUT (ORBE) Interface Spec

本文描述 FE Agent 与 DUT（ORBE/BE）之间的外部接口，按以下顺序组织：

1. 信号通道；
2. 各通道的 payload；
3. 双向握手时序。

当前边界约定为：FE Agent 只交付 raw instruction、PC、预测信息和前端异常/元数据；Decode 在 ORBE/BE 内部、IB 之后完成。ORBE 当前为 2 发射，因此指令交付通道包含 2 条 lane。本文规范文字统一使用 `VALID`；若 RTL 中实际拼写为 `VAILD`，应保留 RTL 原名。

## 1. 信号通道

### 1.1 指令交付通道

| 方向 | 信号 | 位宽 | 说明 |
| --- | --- | ---: | --- |
| FE -> BE | `fe_be_instr_valid[lane]` | 2 | 本拍对应 lane 是否提供一条 raw instruction；`lane` 取值为 0 或 1。 |
| BE -> FE | `be_fe_instr_ready[lane]` | 2 | 本拍 DUT 是否接受对应 lane；与 `fe_be_instr_valid[lane]` 构成握手；`lane` 取值为 0 或 1。 |
| FE -> BE | `fe_be_instr_pld[lane]` | 2 x payload | 对应 lane 的完整 raw instruction payload，字段定义见 §2.1。 |

### 1.2 Redirect 通道

Redirect 为 BE -> FE 的单向恢复取指通道。

| 方向 | 信号 | 位宽 | 说明 |
| --- | --- | ---: | --- |
| BE -> FE | `be_fe_redirect_valid` | 1 | 本拍发生恢复取指。 |
| BE -> FE | `be_fe_redirect_pld` | payload | redirect payload，字段定义见 §2.2。 |

## 2. Payload 定义

### 2.1 `fe_be_instr_pld[lane]`

该 payload 只传 raw instruction 和前端已有信息，不传 Decode 结果。

| 字段 | 是否属于 payload | 位宽 | 说明 |
| --- | --- | ---: | --- |
| `pc` | 是 | 64 | 本条指令地址；被 DUT 接收并分配 tag 后，写入 `PC_File` 对应 entry 的 `inst_pc`。 |
| `inst_bits` | 是 | 32 | 原始指令编码。RVC 指令仅低 16 bit 有效，高位清零；非法指令的原始编码由此保留。fetch exception entry 使用 `32'h0000_0013` 作为字段占位值，异常语义由 `fetch_excp_vld` 标记。 |
| `is_compressed` | 是 | 1 | 是否为 16-bit compressed instruction，用于顺序 PC 的 `pc + 2` / `pc + 4` 语义。 |
| `pred_taken` | 是 | 1 | FE 的分支预测方向信息。 |
| `pred_target_pc` | 是 | 64 | FE 的预测目标 PC。 |
| `fetch_excp_vld` | 是 | 1 | 本拍 FE 是否提供前端取指异常信息；正常 instruction entry 为 0，真实 fetch fault entry 为 1。 |
| `exception_cause` | 是 | 5 | 前端同步 instruction-fetch cause 编号；当前阶段支持 `INSN_ADDR_MISSALIGN=0`、`INSN_ACCESS_FAULT=1`、`INSN_PAGE_FAULT=12`，不含 interrupt 标志位。正常 entry 为 0。 |
| `exception_tval` | 是 | 64 | 实际失败的 instruction-fetch 虚拟地址；低 halfword fault 为该 entry 的 `pc`，32-bit instruction 的 high halfword fault 为 `pc+2`。正常 entry 为 0。 |

fetch exception entry 的固定字段为：`pc` 为逻辑指令起始地址，`inst_bits=32'h0000_0013`，`is_compressed=0`，`pred_taken=0`，`pred_target_pc=pc`。该 entry 由 FE 按照普通 instruction channel 的 ready/valid、lane 顺序和 stall stability 规则交付；BE/Wrapper 在完成自身 entry/`rob_idx` 管理后负责把 cause/tval 转换为 `isa_dpi_trigger_trap()` 调用，FE 不调用该 DPI。

### 2.2 `be_fe_redirect_pld`

| 字段 | 属性 | 位宽 | 说明 |
| --- | --- | ---: | --- |
| `redirect_pc` | 必选 | 64 | FE Agent 下一次取指的目标 PC。 |
| `interrupt_valid` | 必选 | 1 | 当前 redirect 是否由 INTERRUPT 触发；仅在 `be_fe_redirect_valid = 1` 时有效。 |
| `trap_valid` | 必选 | 1 | 当前 redirect 是否由同步 EXCEPTION/trap 触发；仅在 `be_fe_redirect_valid = 1` 时有效。 |

## 3. 双向握手时序

当前明确存在双向 `VALID/READY` 握手的只有指令交付通道。定义：

```text
fire[0] = fe_be_instr_valid[0] && be_fe_instr_ready[0]
fire[1] = fe_be_instr_valid[1] && be_fe_instr_ready[1] && fire[0]
```

指令必须按程序顺序接收。lane 0 是较老指令，lane 1 是较新指令；lane 1 只有在 lane 0 同拍接收时才能 fire。禁止只接收 lane 1 而不接收 lane 0。正常情况下，DUT 应将 ready 体现为前缀接收语义；FE Agent 也按上述规则计算有效 fire。

### 3.1 指令交付

![Instruction Fetch 时序图](<Instruction Fetch.svg>)

### 3.2 Redirect（以 Misprection 为例）

![Misprediction 时序图](Misprediction.svg)
