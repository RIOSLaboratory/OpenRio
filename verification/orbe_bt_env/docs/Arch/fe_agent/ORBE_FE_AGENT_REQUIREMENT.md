# ORBE FE Agent 需求文档（初步实现）

> 层定位：本文是 ORBE FE Agent 的**需求层文档**，回答"要什么、为什么、边界在哪"。
> 实现细节、代码位置、ISA_model 调用路径见同目录 `ORBE_FE_AGENT_ARCHITECTURE.md`。
> 权威实现以 `tb/modified_agents/fe/` 为准。

## 1. 定位与范围

本文定义 ORBE FE Agent 在 ORBE BT 验证环境中的职责、对外接口、所使用的 ISA Model DPI，以及设计需求与设计思路。本文只覆盖 **FE Agent 初步实现** 阶段，即 FE Agent 独立驱动、尚未与真实 BE/DUT 后端联调时的形态。

### 1.1 与架构文档的分工

| 问题 | 本文（需求层） | 架构文档 |
| --- | --- | --- |
| 要不要做、做到什么程度 | ✅ | — |
| 接口字段与语义 | ✅ | 引用 |
| 用哪些 DPI、为什么 | ✅ | 定位到函数与文件 |
| 怎么实现、代码在哪 | — | ✅ |
| 关键逻辑伪代码 | —— | ✅ |
| ISA_model 内部调用路径 | — | ✅ |

## 2. 初步实现

### 2.1 FE Agent 在环境中的位置

ORBE BT 验证环境由 `be_tb_top` 顶层装配，其中与 FE 相关的部分为：

```text
be_tb_top
  ├─ orbe_fe_if  fe_vif          # FE Agent <-> DUT/Wrapper 的接口实例
  ├─ fe_agent    fe_agent_h      # 本文对象
  └─ DUT / mock_rtl（二选一，由编译宏决定）
```

FE Agent 位于 ISA Model 与 ORBE DUT 之间：向上从 ISA Model 取指令，向下按 ORBE FE/BE 外部接口把原始指令流交给 DUT。

```text
ISA Model (指令内存 + 生命周期)
        ▲  DPI
        │
   fe_driver ── orbe_fe_if ──▶ ORBE BE
        ▲
        │ new/run/finish_model
     fe_agent ◀── be_tb_top
```

## 3. 用到的接口

FE Agent 与 DUT 之间的**唯一事务接口**是 `orbe_fe_if`，定义于 `tb/modified_agents/fe/orbe_fe_if.sv`。接口时钟与复位为 `clk` / `rst_n`，2 条 lane（`ORBE_FE_LANES = 2`）。配置、报告、日志与 ISA Model 属于测试环境服务接口，见 §5。

### 3.1 信号清单

| 方向 | 信号 | 位宽 | 含义 |
| --- | --- | ---: | --- |
| FE → BE | `fe_be_instr_valid[lane]` | 2 | 本拍该 lane 是否提供一条原始指令 |
| FE → BE | `fe_be_instr_pld[lane]` | 2 × 232 | 该 lane 的原始指令 payload |
| BE → FE | `be_fe_instr_ready[lane]` | 2 | 本拍 DUT 是否接收该 lane |
| BE → FE | `be_fe_redirect_valid` | 1 | 本拍发生 redirect |
| BE → FE | `be_fe_redirect_pld` | 66 | redirect 目标，含 `redirect_pc` / `interrupt_valid` / `trap_valid` |

### 3.2 指令 payload 规格

指令 payload 只承载**原始指令和前端已有信息**，不得携带后端 decode 语义（FU 路由、源/目的寄存器元数据、immediate、execution sub-op 等）。

| 字段 | 位宽 | 需求 |
| --- | ---: | --- |
| `pc` | 64 | 本条指令地址 |
| `inst_bits` | 32 | 原始指令编码；RVC 仅低 16 bit 有效、高位清零 |
| `is_compressed` | 1 | 是否为 16-bit compressed instruction |
| `pred_taken` | 1 | 分支预测方向；本阶段为静态占位值 0 |
| `pred_target_pc` | 64 | 顺序预测目标：RVC 为 `pc + 2`，其余为 `pc + 4` |
| `fetch_excp_vld` | 1 | 真实取指 fault entry 为 1，正常 entry 为 0 |
| `exception_cause` | 5 | 同步 instruction-fetch cause 编号 |
| `exception_tval` | 64 | 实际失败的取指虚拟地址 |

单 lane payload 合计 232 bit。

### 3.3 握手语义与采样时点

指令交付通道存在双向 valid/ready，必须满足前缀顺序：

```text
fire[0] = valid[0] && ready[0]
fire[1] = valid[1] && ready[1] && fire[0]
```

- lane 0 为较老指令，lane 1 为较新指令。
- 禁止"lane 0 未 fire 而 lane 1 单独 fire"。
- 该前缀约束由 FE Agent 自己计算与保证，不依赖 DUT/Wrapper 修正。
- ready 拉低时，未接收 entry 的 payload 必须保持稳定，直到该 entry fire 或被 redirect 丢弃。

采样时点如下表。它是 FE 与 DUT 之间的协议约定，不属于实现自由度：

| 事项 | 约定 |
| --- | --- |
| 采样边沿 | `valid` / `payload` / `ready` 在**同一个 `posedge clk`** 上配对采样 |
| payload 稳定窗口 | 一组 payload 在 `posedge` 之后的整拍内保持不变，到下一个 `posedge` 才更新 |
| `ready` 的依赖 | 允许同拍组合依赖 `valid` / `payload`，但必须在采样边沿前稳定；FE 不做"先读 ready 再改本拍 valid"的两段式协商 |
| fire 判定时刻 | 用本拍对外呈现的 `valid` 与采样到的 `ready` 计算上式的 `fire[0]` / `fire[1]` |
| **redirect 与 fire 同拍** | **该拍不产生任何 fire**：redirect 采样分支不进入握手路径，原本可能发生的接收全部作废 |
| 未 fire 的 entry | 保持到下一次采样；被 redirect 丢弃的 entry 不再交付 |

### 3.4 Redirect 语义

- `be_fe_redirect_valid` 为单周期事件语义；`be_fe_redirect_pld` 与 valid 同拍有效。
- redirect 优先级高于普通指令交付；同拍冲突时 redirect 优先。
- redirect 结束当前取指路径并开启新的取指路径；两条路径之间的指令地址与顺序不连续。
- 收到 redirect 后，必须丢弃所有未 fire 的旧 pending entry。
- 在第 N 拍采样到 redirect 后，该拍暂停普通指令输出；第 N+1 拍从 `redirect_pc` 重新取指，且重新输出的首条指令必须满足 `pc == redirect_pc`。
- 连续 redirect 时，以最新一次采样的目标为准。
- `interrupt_valid` / `trap_valid` 对 FE 是**信息性的**：FE 不得依赖它们，redirect 语义只由 `redirect_pc` 决定；两者的互斥关系属于 BE/接口规格的定义范畴。

### 3.5 时钟与复位

- `rst_n = 0` 期间，FE Agent 必须保持 `fe_be_instr_valid = 0` 并清零 payload，不得让 Wrapper 把复位期间的取值当请求。
- 复位释放后才开始取指与驱动。
- **前提**：本条要求 FE 侧在复位期间就**已经存在并驱动 idle**，因此 agent 的创建与 `run()` 的启动必须早于复位释放。参考实现当前在复位释放后才创建 agent、且接口无初值，故本条尚未满足；收敛方式见架构文档 §5.2。

## 4. Agent 设计需求

接口契约与字段规格见 §3；本节只列 FE 侧需要满足的编号需求。

### 4.1 功能需求

| 编号 | 需求 |
| --- | --- |
| FE-F1 | 从入口 PC 或最近一次 redirect 目标开始，按指令长度连续产生程序顺序指令；程序顺序只在同一条取指路径内成立 |
| FE-F2 | 未 fire 的 entry 必须保持，且在下一次展示时压缩到 lane 0 |
| FE-F3 | 零填充（`16'h0000`）按结束处理，不产生非法指令 entry |
| FE-F4 | 真实取指 fault 产生异常 entry，并在其后停止产生更年轻的 entry |
| FE-F5 | redirect 丢弃旧路径 pending 并从 `redirect_pc` 重启 |

### 4.2 异常 entry 需求

异常 entry 的字段：

- `pc` 为逻辑指令起始地址；`inst_bits = 32'h0000_0013`（占位 NOP）；`is_compressed=0`；`pred_taken=0`；`pred_target_pc=pc`。
- `fetch_excp_vld=1` 是异常语义的唯一来源，BE 不得依赖占位编码判断异常。
- `exception_cause` 取同步 instruction-fetch cause 的低 5 bit（编码范围 0–31）。本阶段只支持 `INSN_ADDR_MISSALIGN=0x0`、`INSN_ACCESS_FAULT=0x1`、`INSN_PAGE_FAULT=0xc`，其余值不得传出。
- `exception_tval` 为实际失败的取指虚拟地址：低 halfword fault 为 `pc`，32-bit 指令 high halfword fault 为 `pc+2`。
- 不支持的 cause 必须报错，不得静默转成 EOF 或 cause 0。
- 异常 entry 必须遵守与普通 entry 相同的 ready/valid、lane 顺序与稳定性规则。

"fault 之后停止"的范围与恢复（完整状态机见架构文档 §3.3）：

- 异常 entry 是**更年轻**的 entry：它允许与它之前的 older entry 分别占用两个 lane，并按 §3.3 的前缀顺序一起交付。
- 异常 entry **尚未 fire** 时可被 redirect 丢弃。
- 异常 entry fire 之后：**若无 redirect，则永久停止产生新的 entry**；此前已入队但未 fire 的 older entry 仍继续交付。
- redirect 会清除该停止状态，并从 `redirect_pc` 重新开始取指。

### 4.3 职责边界需求

- FE Agent 只保证"外部可见的取指与交付协议"，不解释后端语义。
- 例外地，本阶段 FE 是共享 ISA Model 的创建者与销毁者；集成模式下的所有权约定见架构文档。
- FE 不调用 `isa_dpi_trigger_trap()`，cause/tval 到 trap 的转换由 BE/Wrapper 完成。

## 5. 用到的 DPI

FE Agent 把 ISA Model 当作**指令内存**与**阶段收尾状态来源**。它使用的 DPI 覆盖四类：

- **模型生命周期**：`isa_dpi_create` / `isa_dpi_destroy`
- **配置与装载**：`isa_dpi_load_config` / `isa_dpi_load_elf` / `isa_dpi_add_arg` / `isa_dpi_finalize_config`
- **取指**：`isa_dpi_fetch_mem_bank_virt`
- **退出状态查询**：`isa_dpi_is_to_exit` / `isa_dpi_is_good`

后端执行、提交、trap 与内存提交类 DPI 一律不用（见 §5.3）。

### 5.1 功能 DPI

| DPI | 用途 |
| --- | --- |
| `isa_dpi_create(core_num, rob_size)` | 创建单核共享模型（本阶段 `1, 16`） |
| `isa_dpi_load_config(yaml)` | 加载平台 YAML 配置 |
| `isa_dpi_load_elf(elf)` | 装载测试 ELF（提供指令字节与入口信息） |
| `isa_dpi_add_arg(elf)` | 向目标程序传 argv；本阶段传入的是 ELF 路径本身，即 argv[0] 的约定 |
| `isa_dpi_finalize_config()` | 完成配置，允许后续取指 |
| `isa_dpi_get_spec_pc(core_id)` | 取得入口 PC |
| `isa_dpi_fetch_mem_bank_virt(core_id, pc, 2, buf, trap)` | 按虚拟地址取 2 字节指令块 |
| `isa_dpi_is_to_exit()` | 判断模型是否进入退出状态 |
| `isa_dpi_is_good()` | 退出后判断结果是否 PASS |
| `isa_dpi_destroy()` | 释放共享模型 |

### 5.2 可选日志 DPI

由 plusarg 触发，用于生成参考侧日志：

| DPI | 用途 |
| --- | --- |
| `isa_dpi_set_run_log(path)` / `isa_dpi_enable_run_log(ISA_API_LOG_GLOBAL)` | run log 路径与开关 |
| `isa_dpi_set_commit_log(path)` / `isa_dpi_enable_commit_log(ISA_API_LOG_GLOBAL)` | commit log 路径与开关 |

这两个开关是**模型级全局**的、不绑定具体 agent：日志内容由 BE 驱动模型时产生，FE 只是作为当前模型 owner 打开它。

### 5.3 输入来源

- `+ISA_CFG=<platform.yaml>`：平台配置路径，缺失即 fatal。
- `+ISA_ELF=<test.elf>`：测试 ELF 路径，缺失即 fatal。
- `+ISA_RUN_LOG=<path>` / `+ISA_COMMIT_LOG=<path>`：可选日志路径。

## 6. 设计约束与推荐方案

本节给出一个已验证可行的内部落地方式。**它不是外部可观察的需求**：在满足 §3–§5 的前提下，实现可以替换这里的组件划分、队列组织与推进时机；保留本节只是提供一条已经跑通的路径。

### 6.1 组件划分

采用"壳 + 驱动"两级：

- `fe_agent`：入口壳，持有配置并创建 `fe_driver`，对外暴露 `run()` / `shutdown()` / `finish_model()`。
- `fe_driver`：全部取指、队列、握手、redirect、生命周期逻辑的载体。
- `orbe_fe_if`：只承载 FE 与 DUT 之间的事务，FE 不感知 Wrapper 内部结构。

### 6.2 取指思路

按 2 字节粒度取指：先读 `pc` 处 2 字节；若低 halfword 指示 32-bit 指令，再读 `pc+2` 的 2 字节并拼接。读取统一走 `isa_dpi_fetch_mem_bank_virt`，由 ISA Model 负责地址翻译与访问检查，FE 不自己做 MMU。

### 6.3 队列与保持思路

维护一个按程序顺序排列、容量等于 lane 数的 pending 队列：

- `next_pc` 在"指令进入队列"时推进，保证被 stall 的 entry 不会被重复取指。
- 每拍按 ready 计算哪些 entry 被接收；未接收的 entry 压缩前移（这天然实现了"lane 1 → lane 0"）。
- 压缩后再补满队尾，形成下一拍展示的 group。

### 6.4 生命周期思路

- 初始化：复位释放后创建/配置/装载 ISA Model，取入口 PC。
- 运行：主循环每拍检查退出状态、redirect、握手与 refill。
- 收尾：模型请求退出后停止输出并返回；结束阶段检查 `is_to_exit` / `is_good` 并销毁模型。

## 7. 验收要点（初步）

在 FE-only 环境中，以下行为同时成立即视为初步实现通过：

1. 从入口 PC 起连续送出符合程序顺序的指令流；顺序只在同一取指路径内比较，redirect 前后的 entry 不跨路径比较。
2. RVC 与 32-bit 指令的 `inst_bits` / `is_compressed` / `pred_target_pc` 符合 §3.2。
3. ready 拉低时 entry 保持；lane 0 fire、lane 1 未 fire 时，原 lane 1 在下一拍压缩到 lane 0。
4. 任意拍不出现非法 lane 组合与前缀 fire 违规。
5. redirect 后旧路径 entry 不再输出，且重启首条 `pc == redirect_pc`。
6. 连续 redirect 时以最新一次采样的目标为准，旧路径 entry 全部丢弃。
7. 零填充 `16'h0000` 之后不再产生新的 entry；此前已入队未 fire 的 entry 仍继续交付。
8. 取指 fault 生成格式正确的异常 entry（字段见 §4.2），并在其后停止产生更年轻的 entry。
9. 异常 entry 未 fire 时可被 redirect 丢弃；收到 redirect 后能从 `redirect_pc` 恢复取指。
10. `exception_tval` 在低 halfword fault 时为 `pc`，在 32-bit 指令 high halfword fault 时为 `pc+2`。
11. 异常 entry 的固定字段：`inst_bits=32'h0000_0013`、`is_compressed=0`、`pred_taken=0`、`pred_target_pc=pc`、`fetch_excp_vld=1`。
12. 出现不支持的 fetch cause 时必须报错终止，不得静默转成 EOF 或 cause 0。
13. 收尾：模型退出后可正确判定 PASS/FAIL，且模型被销毁——本阶段由 FE 作为唯一 owner 完成。
14. 复位期间 `fe_be_instr_valid=0` 且 payload 为 0（前提：§3.5 的复位前提已收敛）。

> 完整集成后，`is_to_exit` / `is_good` / `destroy` 的所有权将移交给统一的 Model owner，本文相关条目需同步修订。
