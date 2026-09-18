# ORBE FE Agent 架构文档

> 层定位：本文是 ORBE FE Agent 的**实现规格**，回答"要做出什么、必须遵守什么、ISA_model 侧怎么调"。
> 需求、接口语义与边界见同目录 `ORBE_FE_AGENT_REQUIREMENT.md`；本文不重述规格。
> 参考实现位于 `tb/modified_agents/fe/`，用于对照定位，不构成实现约束。

## 1. 文档目的与范围

本文规定 ORBE FE Agent 的实现规格：需要产出哪些模块、必须维护哪些状态、遵守哪些时序与错误处理契约、调用哪些 ISA Model DPI。据此应能实现一个行为等价的 FE Agent，而不必先读参考实现。

**范围与视角**：本文只规定 **FE 一侧**的行为与边界。当前顶层 `be_tb_top` 同时运行 `be_agent`，共享的 ISA Model 由 FE 与 BE **共同使用**（见 §4.2）；因此本文不覆盖后端 decode / commit / flush 路径，也不把"完整 tohost 闭环是否正确"作为 FE 的验收内容。

路径以下列两个根为基准：

```text
ORBE_ENV_ROOT = openrios/verification/orbe_bt_env
ISA_MODEL_ROOT = <isa_model checkout>
```

文中引用的 ISA_model 文件与函数，基准 revision 为 `isa_model@54f59d5`；该仓库变动后需重新核对。

接口字段、payload 规格与协议语义不在本文重述，见 `ORBE_FE_AGENT_REQUIREMENT.md`（下称 REQ）§3。文中出现的函数名、成员名与文件名均指参考实现，仅用于对照。

## 2. 交付物与代码结构

### 2.1 需要产出的模块与职责

| 模块 | 职责 | 参考实现 |
| --- | --- | --- |
| 接口定义 | 定义 FE↔BE 的 2 lane 指令通道与 redirect 通道的类型与 modport | `tb/modified_agents/fe/orbe_fe_if.sv` |
| 入口壳 | 接收配置、创建驱动器、统一暴露 `run` / `shutdown` / `finish_model` | `tb/modified_agents/fe/fe_agent.sv` |
| 驱动器 | 取指、队列维护、握手交付、redirect 处理、模型生命周期 | `tb/modified_agents/fe/fe_driver.sv` |
| 配置与报告 | 复用环境的配置与报告类（可经类型别名） | `tb/env/be_config.sv`、`tb/env/be_reporter.sv` |
| DPI 声明与包装 | ISA Model DPI 的 SV 声明、常量与 C++ 包装 | `dpi/isa_dpi_pkg.sv`、`dpi/isa_dpi_wrapper.cc` |
| 源码清单 | 把以上文件编入构建 | `cfg/filelist/tb.f`、`cfg/filelist/common.f` |

接口定义的要点：

- `orbe_fe_types_pkg::ORBE_FE_LANES = 2`
- `orbe_fe_types_pkg::orbe_fe_instr_pld_t`（指令 payload）与 `orbe_fe_redirect_pld_t`（redirect payload）：字段与位宽见 REQ §3.2
- 接口提供 `dut` 与 `tb` 两个 modport，驱动器使用 `tb` 一侧

### 2.2 编译集成（本仓库环境约束）

以下约束来自本仓库的构建布局；实现只要保持等价即可，不必照搬文件名。

- 接口文件需由 filelist 单独编入（参考 `cfg/filelist/tb.f`），并加入 `+incdir+tb/modified_agents/fe`。
- 类文件由 `be_tb_pkg` 打包 include，包内用 typedef 把环境已有的配置/报告类别名成 FE 侧名字：

```systemverilog
// tb/pkg/be_tb_pkg.sv
typedef be_config   orbe_fe_config;
typedef be_reporter orbe_fe_reporter;
`include "../modified_agents/fe/fe_driver.sv"
`include "../modified_agents/fe/fe_agent.sv"
```

- 别名意味着驱动器与 `tb/env/` 共用同一份配置与报告实现，无需另建一套。
- 历史目录 `tb/agents/fe/` 在本仓库中只提供 `riscv_rvc_pkg.sv`，新实现无需沿用它。

### 2.3 顶层的选定与 DUT 选择（本仓库环境约束）

`be_tb_top` 没有被任何上层模块例化——它是**仿真的顶层**，由构建变量指定：

```make
# sim/Makefile
TOP      ?= be_tb_top
```

```make
# mk/common.mk：传给 VCS
VCS_FLAGS := ... -top $(TOP) -o $(SIM) ...
```

Verilator 流程则在 `tools/verilator_cosim.sh` 中写死 `--top-module be_tb_top`。因此改写 `TOP` 只对 VCS 流程生效，两条流程会分叉。

顶层内部例化哪个 DUT，由 `DUT_KIND` 在**编译期**决定：

```make
# mk/common.mk
DUT_KIND ?= mock

ifeq ($(DUT_KIND),mock)
SYS_DEFINES  += +define+ORBE_DUT_MOCK
RTL_FILELIST ?= $(ROOT_DIR)/cfg/filelist/rtl_mock.f
else ifeq ($(DUT_KIND),rtl_v1)
SYS_DEFINES  += +define+ORBE_DUT_RTL_V1
RTL_FILELIST ?= $(ROOT_DIR)/cfg/filelist/rtl_v1.f
else
$(error Unsupported DUT_KIND='$(DUT_KIND)'; expected mock or rtl_v1)
endif
```

对应到 `be_tb_top` 的条件编译：

```systemverilog
`ifdef ORBE_DUT_RTL_V1
  rtl_v1_wrapper u_rtl_v1_wrapper ( ... );
`else
  mock_rtl       u_mock_rtl       ( ... );
`endif
```

也就是说，`DUT_KIND` 同时决定了三件事：定义哪个宏、编哪份 RTL filelist、顶层里例化哪个 wrapper。

### 2.4 顶层装配与调用

顶层需要按下面的顺序装配 FE 侧对象：**接口实例先于 agent 对象存在**，agent 与其它 agent 并行运行，最后在收尾阶段销毁模型。

**注意**：参考实现目前是在**复位释放之后**才创建 agent 并启动 `run()`，这会让 §5.2「复位期间保持 idle」落空（复位期间接口无驱动，`fe_be_instr_valid` 为 X）。要满足 §5.2，必须把 agent 创建与 `run()` 启动提前到复位释放之前。

```systemverilog
// tb/top/be_tb_top.sv（参考实现）
orbe_fe_if fe_vif(clk, rstn);
fe_agent   fe_agent_h;

fe_agent_h = new(fe_vif, cfg);
fork
  fe_agent_h.run();
  be_agent_h.run();
  cache_agent_h.run();
  ...
join

fe_agent_h.finish_model();
```

模型销毁只发生在 `finish_model()`；`shutdown()` 不作为顶层的收尾路径（见 §6.3）。

## 3. 状态与状态机

### 3.1 入口壳：只做委托

入口壳不持有行为状态，只负责：接收配置（为空则报错）、创建驱动器、把 `run` / `shutdown` / `finish_model` 逐一直通给驱动器。

### 3.2 驱动器需要维护的状态

按驱动状态机的角色分组：

| 角色 | 成员 | 说明 |
| --- | --- | --- |
| 配置与接口 | `cfg` / `vif` | 配置引用与 `virtual orbe_fe_if.tb` 句柄 |
| 常量 | `LANES` / `MODEL_CORE_ID` / `MODEL_ROB_SIZE` | 2 lane、单核、模型 ROB 容量 16 |
| 待发队列 | `pending_valid` / `pending_info` `[LANES]` | 按程序顺序保存待交付 entry |
| 压缩暂存 | `compact_valid` / `compact_info` | 未 fire entry 前移时的中转 |
| 握手回采 | `sampled_fire[LANES]` | 本拍驱动出的 valid，用于与 ready 对齐 |
| 取指游标 | `next_pc` / `fetch_eof` / `fetch_stop_after_fault` | 下一条待取 PC；两种"停止产生新 entry"的状态 |
| 控制状态 | `redirect_pending` / `redirect_pc` | 已采样、待下一拍生效的 redirect |
| 生命周期 | `model_created` | 保护 `create` / `destroy` 配对 |

队列约定：下标 0 恒为最老 entry，映射到 lane 0；其余按下标映射到后续 lane。成员的具体声明位置以符号名为准。

### 3.3 驱动状态与转移

驱动器需要区分 6 个状态，其中 **EOF 与 FAULT_STOP 是两条独立的"停止产生新 entry"路径**：

| 状态 | 进入条件 | 期间行为 | 退出条件 |
| --- | --- | --- | --- |
| RESET | `rst_n = 0` | 输出静止（`valid=0`、payload 清零） | `rst_n = 1` |
| RUN | 复位释放 | 正常取指、交付、压缩 | 见下方转移 |
| EOF | 取到 `16'h0000` | 停止 refill；**已有 pending 继续交付** | redirect |
| FAULT_STOP | 取指 fault 产生了异常 entry | 停止 refill；**已有 pending 继续交付** | redirect |
| REDIRECT_PENDING | 采样到 `be_fe_redirect_valid` | 该拍丢弃旧 pending 并停止输出 | 下一拍回到 RUN |
| EXIT | 模型请求退出 | 停止输出并结束主循环 | — |

```text
RESET ──rst_n=1──▶ RUN
RUN ──零填充──▶ EOF
RUN ──取指 fault──▶ FAULT_STOP
RUN / EOF / FAULT_STOP ──redirect──▶ REDIRECT_PENDING ──下一拍──▶ RUN
REDIRECT_PENDING ──再次 redirect──▶ REDIRECT_PENDING
RUN / EOF / FAULT_STOP / REDIRECT_PENDING ──模型请求退出──▶ EXIT
```

三条要点：

- **只有 RUN 能进入 EOF 或 FAULT_STOP**：这两个状态都停止补队，因此不会再取指，也就不可能再产生 fault。
- **EOF 与 FAULT_STOP 都不清空已有 pending**，只有 redirect 会清空；**redirect 同时清除 EOF 与 FAULT_STOP**，从 `redirect_pc` 重新开始取指。
- **模型退出可从任意活动状态进入**：退出判定在主循环中先于 redirect 处理，见 §6.2。

## 4. 与 ISA_model 的关系与所有权

### 4.1 三层调用关系

FE 侧的 DPI 调用要穿过三层才落到 ISA_model 的实现：

```text
fe_driver.sv
   │  import "DPI-C" 声明
   ▼
dpi/isa_dpi_pkg.sv        (SV 侧声明与常量)
   ▼
dpi/isa_dpi_wrapper.cc    (DPI-C 包装，持有 static FuncMultiCore* g_sim；本仓库自有)
   ▼
src/libs/IsaApi.h         (ISA_model 对外 C++ API)
   ▼
src/libs/lib_FuncMultiCore.cpp   (API → FuncMultiCore/SpecCore 方法)
   ▼
src/arch/processors/FuncMultiCore.cpp / src/isa_riscv/SpecCore.cpp  (真正实现)
```

各 DPI 的逐条调用路径与语义见 §9。

### 4.2 模型所有权与使用边界

- 包装层内只有一个 static 句柄 `g_sim`，**同一时刻只允许存在一个模型**；重复 `isa_dpi_create` 返回 `ISA_API_FAIL`。
- **`create` / `destroy` 由 FE 独占**：本环境中只有 FE 调用 `isa_dpi_create` / `isa_dpi_destroy`（见 §6.1、§6.3）。COSIM 使用独立的另一句柄（`isa_cosim_dpi_create`），与共享模型互不冲突。
- **但模型不是 FE 独占使用的**：`be_agent` 在同一个模型上驱动后端流程，会调用
  `isa_dpi_decode_and_issue`、`isa_dpi_execute_insn`、`isa_dpi_commit_auto`、`isa_dpi_flush`、`isa_dpi_trigger_trap`、`isa_dpi_tick_finish`，并读取 `isa_dpi_get_spec_pc`。
- 因此 FE 的边界是"**不破坏、也不依赖** BE 对模型的用法"：FE 只做取指与退出状态查询，不调用上述后端 DPI，也不得假定模型只被自己使用（例如不得假定 `is_to_exit` 只会因自己的行为而改变）。
- 集成模式（由统一 owner 负责 `create/load/finalize/destroy`）下，FE 应只保留 `isa_dpi_get_spec_pc`、`isa_dpi_fetch_mem_bank_virt` 与只读退出查询。

### 4.3 日志开关

- 日志 DPI 是**模型级全局 API**，不接收模型句柄：`enable_run_log(core_id)` / `disable_run_log(core_id)` / `set_run_log(path)`，以及对应的 commit log 版本。
- 日志开关与"FE 是否做 commit"无关：日志内容由 BE 驱动模型（`isa_dpi_decode_and_issue` / `execute_insn` / `commit_auto`）时在模型内部产生。
- 因此 FE 打开日志，只是**在作为模型 owner 配置模型**（见 §6.1），不是 FE 需要 commit 语义。

## 5. 时序与错误处理契约

### 5.1 时钟与采样契约

接口侧的协议约定（采样边沿、`ready` 的依赖、redirect 同拍行为）以 REQ §3.3 为准，本节不重述。实现侧必须满足的推论是：

- 每拍对外呈现的 `valid` / `payload` 在**整拍内保持稳定**；驱动用非阻塞赋值，使新的一组在下一个 `posedge` 之后才对采样可见。
- 在 `posedge` 采样 `ready` 时，与之配对的必须是**上一拍就已经呈现的那一组** `valid` / `payload`——不能在采样前改写它，也不能"先读 ready 再决定本拍 valid"。
- 采样边沿之后更新的队列状态只影响下一个周期。
- **握手回采必须采驱动出去的值**（`fe_be_instr_valid`），而不是内部队列有效位，否则会与 ready 的采样点错位。
- redirect 在 `posedge` 采样；采样拍强制输出 idle，该拍不产生 fire。
- 若集成层调整采样边沿，必须同时调整 fire 判定，不得由外部单方面改变。

### 5.2 复位行为

- `rst_n = 0` 期间：`fe_be_instr_valid = 0`，payload 清零；不得让接收侧把复位期间的取值当请求。
- 复位释放后才开始取指与驱动。
- **实现前提**：驱动器必须在复位期间就**已经存在并驱动 idle**，即 agent 的创建与 `run()` 启动要早于复位释放。参考实现当前由 `be_tb_top` 在复位释放后才创建 agent，且接口无初值，因此复位期间 `fe_be_instr_valid` 为 X —— 本条尚未满足。收敛方式二选一：把 agent 创建与 `run()` 启动移到复位释放之前（`run()` 在等待复位前已先驱动 idle）；或为接口提供初值/初始化。

### 5.3 逐阶段行为

| 阶段 | 行为 |
| --- | --- |
| 复位 | 输出静止；等待 `rst_n` |
| 首拍 | 进入主循环前先摆好第一组 |
| 普通拍 | `posedge` 采样退出 / redirect / ready → 压缩 → refill → 驱动下一组 |
| redirect 采样拍 N | 保存目标、清队列、停止输出、不参与握手 |
| redirect 生效拍 N+1 | 从 `redirect_pc` 预取并展示 |
| 退出 | 模型请求退出 → 停止输出 → 结束 |

### 5.4 fatal 条件清单

以下情况必须报错终止：

| 条件 | 出现位置 |
| --- | --- |
| 缺少 `+ISA_CFG` / `+ISA_ELF` plusarg | 初始化 |
| `isa_dpi_create` / `load_config` / `load_elf` / `finalize_config` 返回非 `ISA_API_PASS` | 初始化 |
| 入口 PC 处取不到任何可取指内容（队列为空） | 初始化 |
| 取指失败且返回的 `trap_type` 不在支持集合 `{0x0, 0x1, 0xc}` 内 | 取指 |
| 取指失败但调用方拿到 `fetch_ok = 0` | 取指 |
| `finish_model()` 时模型尚未进入退出状态 | 收尾 |
| `isa_dpi_is_good()` 为假 | 收尾 |

## 6. 运行流程

### 6.1 模型初始化

（参考实现：`initialize_model()`）

```text
+ISA_CFG 缺失 -> fatal
+ISA_ELF 缺失 -> fatal
isa_dpi_create(1, 16)                     -> check_rc
model_created = 1
[可选] +ISA_RUN_LOG    -> isa_dpi_set_run_log + isa_dpi_enable_run_log(ISA_API_LOG_GLOBAL)
[可选] +ISA_COMMIT_LOG -> isa_dpi_set_commit_log + isa_dpi_enable_commit_log(ISA_API_LOG_GLOBAL)
isa_dpi_load_config(isa_cfg)              -> check_rc
isa_dpi_load_elf(isa_elf)                 -> check_rc
isa_dpi_add_arg(isa_elf)
isa_dpi_finalize_config()                 -> check_rc
next_pc = isa_dpi_get_spec_pc(0)          -> 深层路径见 §9.3
print_fe(1, entry_pc)
```

`check_rc` 把任何非 `ISA_API_PASS` 转为 fatal。

### 6.2 主循环

（参考实现：`run()`）

进入 `forever` 之前依次：先把 `valid`/`pld` 驱干净（避免复位期间出现未知值）→ 等待复位释放 → 模型初始化 → 清空队列与状态、预取（若队列仍为空则 fatal）→ 摆好第一组。

注意：握手回采取的是驱动出去的 `fe_be_instr_valid`（非阻塞赋值后的当前值），不是内部队列有效位。

**优先级**：退出判定先于 redirect 判定。同一拍同时出现"模型请求退出"与 redirect 时，**退出优先**——该拍调用 `drive_idle()` 后直接结束主循环，既不接收也不产生新的 instruction entry。

```text
run():
    drive_idle()
    wait(rst_n == 1)
    initialize_model()
    clear queue / fetch_eof / fetch_stop_after_fault
    refill_pending()
    assert queue not empty
    drive_pending()

    forever:
        @(posedge clk)
        if is_to_exit(): drive_idle(); return

        if be_fe_redirect_valid:
            redirect_pc      = be_fe_redirect_pld.redirect_pc
            redirect_pending = 1
            clear queue and compact
            fetch_eof = 0; fetch_stop_after_fault = 0
            drive_idle()
            continue

        if redirect_pending:
            apply_redirect(); redirect_pending = 0

        for lane in 0..LANES-1:
            sampled_fire[lane] = fe_be_instr_valid[lane] && (be_fe_instr_ready[lane] === 1)

        remove_accepted_entries(sampled_fire)
        refill_pending()
        drive_pending()
```

### 6.3 收尾

- 常规收尾（参考实现：`finish_model()`）：
  1. 未创建模型则直接返回；
  2. 模型未进入退出状态 → fatal；
  3. 读取结果并打印 `[DPI_EXIT_RESULT] PASS|FAIL`；
  4. 销毁模型；
  5. 结果为假 → fatal。
- `shutdown()` 提供"只销毁、不判定"的路径，供非正常终止时释放模型；它不是顶层的常规收尾路径。
- **退出不由 FE 决定**：`is_to_exit` / `is_good` 反映的是模型对 tohost 的观察结果，而 tohost 写入由 BE 的提交路径产生。因此 FE 只能查询退出状态，不能自行触发退出；在 BE 未接入的场景下，模型可能永远不会退出。

## 7. 关键逻辑规格

### 7.1 取指

每次取指读一条指令，产出三种结果之一：**正常 entry**、**EOF**、**异常 entry**。

```text
fetch_instruction(pc):
    rc = fetch_mem_bank_virt(core=0, pc, 2) -> lo
    if rc != PASS:
        return EXCEPTION_ENTRY(pc, tval = pc)

    low = {lo[1], lo[0]}
    if low == 0x0000:  return EOF
    if low[1:0] != 2'b11:
        return ENTRY(pc, inst = {16'h0, low}, compressed = 1, bytes = 2)

    rc = fetch_mem_bank_virt(core=0, pc+2, 2) -> hi
    if rc != PASS:
        return EXCEPTION_ENTRY(pc, tval = pc+2)

    return ENTRY(pc, inst = {hi[1],hi[0],lo[1],lo[0]}, compressed = 0, bytes = 4)

EXCEPTION_ENTRY(pc, tval):
    require trap_type in {0x0, 0x1, 0xc} else fatal
    inst_bits = 32'h0000_0013; is_compressed = 0; pred_taken = 0
    pred_target_pc = pc; fetch_excp_vld = 1
    exception_cause = trap_type[4:0]; exception_tval = tval
```

异常 cause 由 `report_fetch_fault()` 校验：`trap_type` 必须属于支持集合，否则 fatal；随后取低 5 bit 作为 `exception_cause`，失败访问地址作为 `exception_tval`。

### 7.2 队列装配

（参考实现：`fetch_pending_entry()`、`refill_pending()`）

取指结果写入队列时：

- EOF → 置"结束"标志并返回，调用方据此停止补队。
- 正常/异常 entry 统一写入 `pc` / `inst_bits` / `is_compressed` / `pred_taken = 0`。
- 异常 entry：`pred_target_pc = pc`，填异常字段，并置"fault 后停止"标志；**不推进取指游标**。
- 正常 entry：`pred_target_pc = pc + 本条字节数`，异常字段清零，**推进取指游标**。

补队：在未进入 EOF / fault-stop 状态时把队列补满到 lane 数。因为取指游标是在 entry 入队时推进的，被 stall 的 entry 不会被重复取指。

**两个停止标志的语义**：`fetch_eof` 与 `fetch_stop_after_fault` 都**只阻止补队**，都不清空已有 pending；两者都只由 redirect 清除。异常 entry 不推进取指游标，因此它可以与更老的 entry 同时占据两个 lane，并按 §7.3 的前缀顺序一起交付。（异常 entry 的字段与生命周期要求见 REQ §4.2。）

```text
refill_pending():
    n = count(pending_valid)
    while n < LANES and !fetch_eof and !fetch_stop_after_fault:
        ok = fetch_pending_entry(n)
        if !ok: break
        n++
    clear pending[n .. LANES-1]
```

### 7.3 握手压缩

（参考实现：`remove_accepted_entries()`）

每拍按前缀顺序判定哪些 entry 被接收，未接收的压缩前移——这就是"lane 1 未 fire 时下一拍前移到 lane 0"的实现。

```text
remove_accepted_entries(edge_fire):
    fire[0] = pending_valid[0] && edge_fire[0]
    for lane in 1..LANES-1:
        fire[lane] = pending_valid[lane] && edge_fire[lane] && fire[lane-1]
    w = 0
    for lane in 0..LANES-1:
        if pending_valid[lane] && !fire[lane]:
            compact[w] = pending[lane]; w++
    pending = compact
```

### 7.4 redirect 处理

（参考实现：`apply_redirect()`）

优先级由主循环顺序保证（见 §6.2）：

- **退出 > redirect > 普通交付**。退出在同拍最先判定；该拍不发生退出时，redirect 采样分支才起作用。
- redirect 采样分支当拍**不进入握手/压缩路径**，因此**该拍不产生任何 fire**，原本可能发生的接收全部作废；redirect 生效落在下一拍。

```text
// cycle N: sample
if be_fe_redirect_valid:
    redirect_pc = pld.redirect_pc
    drop old queue; drive_idle(); continue

// cycle N+1: rebuild
if redirect_pending:
    clear queue; next_pc = redirect_pc
    fetch_eof = 0; fetch_stop_after_fault = 0
    refill_pending()
    redirect_pending = 0
```

## 8. 参数化与实现自由度

| 项 | 约束 | 说明 |
| --- | --- | --- |
| lane 数 | **固定为 2** | 对应 ORBE 2 发射 |
| 模型核数 | 固定为 1 | 单核共享模型，`model_core_id = 0` |
| 模型 ROB 容量 | 固定为 16 | 传给 `isa_dpi_create`；与 DUT 内部 ROB 无关 |
| 配置与 ELF | 由 plusarg 给出 | `+ISA_CFG` / `+ISA_ELF` |
| 内部函数与类的分解 | **自由** | 文档中的函数名仅用于对照参考实现 |
| 队列与压缩的实现方式 | **自由** | 只要满足 §7.2 / §7.3 的语义 |
| 日志的输出级别与格式 | **自由** | 需能区分：入口 PC、每条 entry 的 PC/编码/压缩标记、取指异常、redirect 捕获与重启、阶段结束 |

## 9. ISA_model 调用路径

### 9.1 逐 DPI 路径表

| SV DPI | 语义 | 返回码 | 包装层调用的 C++ API | 深层实现 |
| --- | --- | --- | --- | --- |
| `isa_dpi_create(core_num, rob_size)` | 创建共享模型 | `PASS` / `FAIL`（已有模型或参数非法） | `funcMultiCore_create` | `FuncMultiCore` 构造 |
| `isa_dpi_destroy()` | 释放模型 | — | `funcMultiCore_destroy` | `FuncMultiCore` 析构 |
| `isa_dpi_load_config(yaml)` | 加载平台 YAML 配置 | `PASS` / `FAIL` | `funcMultiCore_loadConfigFile` | `FuncMultiCore::loadConfigFile` |
| `isa_dpi_load_elf(elf)` | 装载测试 ELF | `PASS` / `FAIL` | `funcMultiCore_loadElf` | `FuncMultiCore::loadElf` |
| `isa_dpi_add_arg(arg)` | 向目标程序传 argv；本阶段传入的是 ELF 路径本身（argv[0] 约定） | — | `funcMultiCore_addArg` | `FuncMultiCore::addArg` |
| `isa_dpi_finalize_config()` | 完成配置，允许取指 | `PASS` / `FAIL` | `funcMultiCore_finalizeConfig` | `FuncMultiCore::finalizeConfig` |
| `isa_dpi_get_spec_pc(core_id)` | 取入口 PC | 64-bit PC | `funcMultiCore_getCoreSpecPc` | `SpecCore::specNextPc`，展开见 §9.3 |
| `isa_dpi_fetch_mem_bank_virt(core, pc, 2, buf, trap)` | 按虚拟地址取 2 字节指令块 | `PASS` / `FAIL`；失败时 `trap` 有效 | `funcMultiCore_fetchMemBankVirt` | `FuncMultiCore::fetchMemBankVirt` → `fetchMemBankVirtImpl`，展开见 §9.2 |
| `isa_dpi_is_to_exit()` | 模型是否请求退出 | 0 / 1 | `funcMultiCore_isToExit` | `htif_device.to_exit` |
| `isa_dpi_is_good()` | 退出结果是否成功 | 0 / 1 | `funcMultiCore_isGood` | `htif_device.is_good` |
| 日志类 4 个：`isa_dpi_set_run_log` / `isa_dpi_enable_run_log` / `isa_dpi_set_commit_log` / `isa_dpi_enable_commit_log` | 设置日志路径与开关 | — | `set_run_log` / `enable_run_log` / `set_commit_log` / `enable_commit_log` | 全局日志对象，不经模型句柄 |

除日志类外，其余都落到 `src/libs/IsaApi.h` 声明的 `funcMultiCore_*` API，再由 `src/libs/lib_FuncMultiCore.cpp` 转发给 `FuncMultiCore` / `SpecCore` 的方法。

常量：`ISA_API_PASS = 0`、`ISA_API_FAIL = -1`、`ISA_API_LOG_GLOBAL = -1`。

### 9.2 取指调用链（排查参考）

本节只在需要排查 ISA 侧行为时使用；实现 FE Agent 不必了解这些内部步骤。`isa_dpi_fetch_mem_bank_virt` 是唯一的热路径调用：

```text
fe_driver 取指逻辑
  -> isa_dpi_fetch_mem_bank_virt(...)        dpi/isa_dpi_pkg.sv            （SV 侧声明）
  -> isa_dpi_fetch_mem_bank_virt(...)        dpi/isa_dpi_wrapper.cc
       校验 g_sim 非空、开放数组容量足够，取连续地址
  -> funcMultiCore_fetchMemBankVirt(...)     src/libs/IsaApi.h
  -> funcMultiCore_fetchMemBankVirt(...)     src/libs/lib_FuncMultiCore.cpp
       把返回码与 ISA_RISCV::TrapType 转成 uint64 trap_type
  -> FuncMultiCore::fetchMemBankVirt(...)    src/arch/processors/FuncMultiCore.cpp
       取 mmus[core_id]、memory、cores[core_id].priv_state
  -> fetchMemBankVirtImpl(...)               src/arch/processors/FuncMultiCore.cpp
       1) 若开启 ISA_MODEL_MISALIGN_CHECK_ENABLED 且 vaddr 为奇数
          -> trap = INSN_ADDR_MISSALIGN, FAIL
       2) 按 4 KiB 页边界切块，逐块构造 MemReq{mem_op = FETCH}
       3) mmu.translate(req, priv, virt)；trap.valid -> 返回 trap
       4) 逐 2 字节 memory.accessValid(pa, READ) 检查
          失败 -> trap = INSN_ACCESS_FAULT, FAIL
       5) memory.read(pa, step, dst)
       6) 全部成功 -> trap = NO_TRAP, PASS
```

FE 侧只需知道下面三点，**不要按 `trap_type` 的数值判断有没有异常**：

- **`rc` 是唯一判据**：`rc != ISA_API_PASS` 表示读取失败，只有此时才去读 `trap_type`。
- 失败时 `trap_type` 是真实异常；成功时 `trap_type` 为哨兵值 `NO_TRAP = 0x3f`。
- 支持集合按**枚举名**判定：`INSN_ADDR_MISSALIGN = 0x0`、`INSN_ACCESS_FAULT = 0x1`、`INSN_PAGE_FAULT = 0xc`；不在集合内即 fatal。注意 `NO_TRAP = 0x3f` 与 `INSN_ADDR_MISSALIGN = 0x0` 是两个不同的值，不要混用。

### 9.3 入口 PC 路径（排查参考）

```text
fe_driver 初始化逻辑
  -> isa_dpi_get_spec_pc(0)                  dpi/isa_dpi_pkg.sv / dpi/isa_dpi_wrapper.cc
  -> funcMultiCore_getCoreSpecPc             src/libs/IsaApi.h / src/libs/lib_FuncMultiCore.cpp
  -> SpecCore::specNextPc()                  src/isa_riscv/SpecCore.cpp
       若 ROB 非空，自 tail→head 找第一个 output.dir.redirect 为真的 entry，
       返回其 next_pc；否则返回 CoreState::pc
```

## 10. 实现注意与自检点

### 10.1 必须遵守的边界

1. **异常 cause 边界**：`NO_TRAP` 与带 interrupt 标志的 cause 不得作为 fetch exception 传出；不支持的 cause 必须 fatal（支持集合见 §7.1）。
2. **零填充是工程约定**：`16'h0000` 一律按 EOF 处理，这是环境约定，不是体系结构语义。
3. **采样依赖仿真调度**：握手回采必须在 `posedge` 采驱动出去的值；若集成层调整采样边沿，需同步调整 fire 判定。
4. **共享模型**：FE 独占 `create` / `destroy`，但**不得假定模型只被自己使用**（见 §4.2）。

### 10.2 与 REQ §7 的分工

- **REQ §7** 是**外部可观察**的验收条目，按"现象"描述，是判定通过与不通过的依据。
- **§10.3** 是**实现侧自检点**，按信号与日志描述，粒度更细；它的用途是**定位 REQ §7 中哪一条不满足**，不重复其内容。

### 10.3 实现侧自检点

| # | 自检点（信号 / 日志层面） | 对应 REQ §7 |
| --- | --- | --- |
| 1 | 队列容量等于 lane 数；任意拍不出现 "lane 1 valid 而 lane 0 invalid" | 4 |
| 2 | 同一组 payload 在整拍内无变化；采样只发生在 `posedge` | 3 |
| 3 | 任意拍的 fire 不出现 `fire[1]=1 且 fire[0]=0` | 4 |
| 4 | 未 fire 的 entry 在下一次展示时位于 lane 0 | 3 |
| 5 | 复位期间 `fe_be_instr_valid=0` 且 payload 为 0 | 14 |
| 6 | 出现零填充后不再调用取指 DPI，也不再产生新 entry | 7 |
| 7 | 取指先判 `rc`，再按枚举白名单判 `trap_type`；非白名单立即 fatal | 12 |
| 8 | 异常 entry 的 `inst_bits` / `is_compressed` / `pred_taken` / `pred_target_pc` / `fetch_excp_vld` 符合 §7.1 | 11 |
| 9 | `exception_tval`：low halfword fault 为 `pc`，high halfword fault 为 `pc+2` | 10 |
| 10 | 置位停止标志后不再补队；redirect 清除该标志并恢复取指 | 9 |
| 11 | redirect 采样拍输出 idle 且不产生 fire | 5 |
| 12 | 连续 redirect 时只保留最新目标 | 6 |
| 13 | 退出拍输出保持 idle 并结束主循环；退出优先于同拍 redirect | 13 |
| 14 | `finish_model()` 在未退出时报错，退出后按 `is_good()` 判定并销毁模型 | 13 |
| 15 | 日志能区分入口 PC、每条 entry、取指异常、redirect 捕获与重启、结束判定 | REQ §4.4 |
