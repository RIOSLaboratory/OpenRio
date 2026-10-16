# IsaApi 的 SystemVerilog DPI-C 接口

本目录提供三个文件：

- `isa_dpi_wrapper.cc`：C++ DPI wrapper。它包含 `src/libs/IsaApi.h`，并在内部保存 `FuncMultiCore *`。
- `isa_dpi_pkg.sv`：SystemVerilog `package`，包含常量和全部 `import "DPI-C"` 声明。
- `isa_dpi.md`：接口、参数类型和推荐调用顺序说明。

## 1. 单一句柄和单核约定

SV 不会看到 `FuncMultiCore *`。wrapper 内部只保存一个静态句柄：

```text
static FuncMultiCore* g_sim = nullptr;
```

`isa_dpi_create(core_num, rob_size)` 创建模型，`isa_dpi_destroy()` 释放模型。同一时刻只能存在一个模型；重复 create 返回 `ISA_API_FAIL`。这是面向单核 BE cosim 的 wrapper，推荐创建时传 `core_num=1`，所有仍保留核选择参数的 API 使用 `model_core_id=0`。

句柄不是线程安全的，仿真器应在同一线程调用这些函数。

## 2. DPI 类型对应

| SV 类型 | wrapper C++ 类型 | 说明 |
| --- | --- | --- |
| `int unsigned` | `uint32_t` | `model_core_id` |
| `int` | `int32_t` / `int` | 有符号 32 位值和 API 状态码 |
| `longint unsigned` | `uint64_t` | 地址、PC、ROB index、寄存器值、计数值 |
| `longint signed` | `int64_t` | `step` 步数、`decode_and_issue` 返回的指令 ID |
| `shortint unsigned` | `uint16_t` | GPR/FPR/CSR 索引 |
| `byte unsigned` | `uint8_t` | `uint8_t` 字段和 C `bool` 的 0/1 表示 |
| `string` | `const char *` | 输入字符串，调用期间由 SV 保证有效 |
| `byte unsigned data[]` | `svOpenArrayHandle` | 连续的 byte 开放数组，内存 API 按字节读写 |

`IsaApiMmuTrace` 和 `IsaApiDirReq` 是 C struct，不能直接作为通用 DPI 返回值。因此 wrapper 将它们展开成 `output` 参数：

- `isa_dpi_translate_pte` 的 `pte_paddr0..4`、`pte_value0..4` 对应 C struct 的两个 5 元数组。
- `isa_dpi_take_interrupt` 的 `next_pc`、`redirect` 对应 `IsaApiDirReq`。

## 3. 返回值约定

所有返回 `int` 的函数使用 `IsaApi.h` 的值：`ISA_API_PASS=0`、`ISA_API_SKIP=1`、`ISA_API_PENDING=2`、`ISA_API_FAIL=-1`。`isa_dpi_decode_and_issue` 失败时返回 `ISA_API_INVALID_INSN_ID=-1`。越界查询通常返回 0，并由模型在 stderr 打印诊断；模型尚未 create 时 wrapper 返回 FAIL 或 0，并打印诊断。

## 4. 生命周期和配置 API

### `isa_dpi_create` / `isa_dpi_destroy`

```systemverilog
int rc = isa_dpi_create(1, 64);
isa_dpi_destroy();
```

`core_num` 是模型核数，单核使用 `1`；`rob_size` 是 ROB 初始容量。两者对应 `funcMultiCore_create(size_t, size_t)`。创建失败或参数超出宿主 `size_t` 范围返回 `ISA_API_FAIL`。

### 布局和 PC

| DPI | 作用 |
| --- | --- |
| `isa_dpi_core_count()` | 返回当前核数；未 create 返回 0。 |
| `isa_dpi_set_core_count(core_num)` | 调整模型核数；单核场景保持为 1。 |
| `isa_dpi_set_rob_size(rob_size)` | 调整 ROB 容量。应在配置阶段调用。 |
| `isa_dpi_set_core_pc(model_core_id, pc)` | 覆盖指定核 PC；单核场景 `model_core_id=0`。 |

### 配置文件、ELF 和手工配置

| DPI | 对应 IsaApi | 参数和语义 |
| --- | --- | --- |
| `isa_dpi_load_config` | `loadConfigFile` | 读取窄 YAML 平台配置；不包含 ELF 和 `finalize`。 |
| `isa_dpi_load_elf` | `loadElf` | 加载 ELF payload，更新模型内存和入口信息。 |
| `isa_dpi_load_bin` | `loadBin` | 从 `bin_path` 把二进制加载到 `address`。 |
| `isa_dpi_add_arg` | `addArg` | 增加传给目标程序的 argv 参数；通常至少加入 ELF 路径。 |
| `isa_dpi_parse_isa` | `parseIsaString` | 设置模型默认 ISA 字符串。 |
| `isa_dpi_set_core_isa` | `setCoreIsaString` | 覆盖一个 `model_core_id` 的 ISA；应在默认 ISA 解析后调用。 |
| `isa_dpi_set_term_file` | `setTermFile` | 设置终端/HTIF 输出文件。 |
| `isa_dpi_set_clint` | `setClint` | 参数依次为 base、mtime、mtimecmp、time-step、software interrupt offset。 |
| `isa_dpi_set_plic` | `setPlic` | 设置 PLIC base address。 |
| `isa_dpi_set_uart` | `setUart` | 设置 UART base address。 |
| `isa_dpi_register_memory_segment` | `registerMemorySegment` | 注册 `[start, start+length)` DDR 段；`readonly != 0` 表示 ROM。 |
| `isa_dpi_finalize_config` | `finalizeConfig` | 完成设备、内存和核配置；运行或 RTL 驱动前必须调用。 |
| `isa_dpi_is_run_started` | `isRunStarted` | 查询模型是否已进入运行状态。 |
| `isa_dpi_is_config_ready` | `isConfigReady` | 查询配置是否完成。 |

与 `besim_main.c` 一致的最小配置顺序是：

```text
create
loadConfigFile (或 parseIsaString/registerMemorySegment 等手工配置)
loadElf / loadBin
addArg
setCorePc（可选）
finalizeConfig
```

## 5. 自驱动运行 API

| DPI | 语义 |
| --- | --- |
| `isa_dpi_step(steps)` | 按模型内部完整流水线执行 `steps` 步；负数表示由模型决定的持续运行语义。 |
| `isa_dpi_step_spec(steps)` | 使用 speculative/self-driven 路径执行。 |
| `isa_dpi_tick_finish(force_htif_poll)` | 完成一次外部 tick；`force_htif_poll != 0` 强制轮询 HTIF。 |
| `isa_dpi_is_to_exit()` | 目标通过 HTIF 请求退出时为 1。 |
| `isa_dpi_is_good()` | HTIF 报告成功时为 1。 |
| `isa_dpi_reset()` | 重置模型运行状态。 |

## 6. 内存和 MMU 查询 API

### 直接/虚拟地址读

```systemverilog
byte unsigned bytes[0:15];
longint unsigned trap;
int rc = isa_dpi_read_mem_bank(addr, 16, bytes, trap);
```

`target` 必须至少有 `length` 个 byte 元素。wrapper 检查开放数组容量并取得其连续地址，再调用 C API；长度不足或数组不可用返回 FAIL。`trap_type` 是 `ISA_RISCV::TrapType` 转成的无符号 64 位值。

| DPI | 语义 |
| --- | --- |
| `isa_dpi_read_mem` | 从物理地址读取一个 8-byte 值。 |
| `isa_dpi_read_mem_bank` | 物理地址批量读，可跨设备/内存；失败时填写 `trap_type`。 |
| `isa_dpi_read_mem_bank_virt` | 指定模型核的虚拟地址批量读，按 4 KiB 页边界分别翻译。 |
| `isa_dpi_fetch_mem_bank_virt` | 指定模型核的取指读；按 2-byte chunk 读取，并检查取指对齐。`besim_main.c` 对 32-bit 指令先读 `pc` 的 2 bytes，再读 `pc+2` 的 2 bytes。 |

### `isa_dpi_translate_pte`

```systemverilog
int rc = isa_dpi_translate_pte(
  model_core_id, vaddr, priv, mem_op_type, length,
  paddr, pte_paddr0, pte_paddr1, pte_paddr2, pte_paddr3, pte_paddr4,
  pte_value0, pte_value1, pte_value2, pte_value3, pte_value4,
  pte_update, levels, trap_type, trap_tval, trap_valid, fault_src, mem_type);
```

这是只读的 VA translation/PTW trace 查询，不会把 A/D 更新写回内存。`priv` 使用模型的 privilege level 编码；`mem_op_type` 使用 package 中 `ISA_API_MEMOP_*` 常量；`length` 必须是 1..65535。非法核、操作类型或长度返回空 trace，并返回 FAIL。合法查询返回 PASS，`trap_valid`、`trap_type`、`trap_tval` 描述翻译异常，`pte_update` 和各级 PTE 字段描述模型发现的更新。

## 7. 寄存器和 PC 查询

| DPI | 返回值 |
| --- | --- |
| `isa_dpi_get_gpr` | 已提交 GPR `index`。 |
| `isa_dpi_get_fpr` | 已提交 FPR `index` 的低 64 位。 |
| `isa_dpi_get_spec_gpr` | 叠加所有在途写回后的 speculative GPR。 |
| `isa_dpi_get_spec_fpr` | 叠加所有在途写回后的 speculative FPR。 |
| `isa_dpi_get_spec_pc` | 考虑已解析 redirect 的 speculative next PC。 |
| `isa_dpi_get_committed_pc` | `CoreState::pc` 原始值。 |
| `isa_dpi_get_csr` | 读取 `csr_index`。例如 `0xb02` 是 `minstret`。 |
| `isa_dpi_get_priv` | 当前 privilege 编码（`byte unsigned`）。 |

GPR/FPR index 应分别限制在 `0..ISA_API_NXPR-1` / `0..ISA_API_NFPR-1`。越界时底层 API 返回 0 并打印诊断。

## 8. RTL-driven 指令流程

这些 DPI 函数对应 `besim_main.c` 的手工驱动 API，每个步骤都显式传 `model_core_id` 和 `rob_idx`。

| DPI | 作用 |
| --- | --- |
| `isa_dpi_decode_and_issue` | 在 `(model_core_id, rob_idx)` 分配/解码一条指令，输入 PC、32-bit encoding 和 `force_rvc`。返回指令 ID，失败为 `-1`。 |
| `isa_dpi_execute_insn` | 执行已 issue 的指令；可能返回 PENDING，RTL 应重复调用直到 PASS 或 FAIL。 |
| `isa_dpi_proc_mem_req` | 处理组合内存请求，适用于 CBO.ZERO、无读侧的写请求等。 |
| `isa_dpi_proc_mem_load` | 处理 load/LR/AMO/SC 的读或决定侧；普通 store 不应调用。SKIP 时按需要调用 `proc_mem_req`。 |
| `isa_dpi_store_commit` | 排出指定核 store buffer 最老的一项并提交到内存/设备。向量 store 需要循环调用，直到返回 FAIL。 |
| `isa_dpi_commit` | 提交指定 ROB entry。异常时可先 `take_trap` 再 `flush`。 |
| `isa_dpi_commit_auto` | 使用模型自动 trap 处理的提交路径。 |
| `isa_dpi_take_trap` | 对指定 ROB entry 执行 trap 写回/处理。 |
| `isa_dpi_flush` | flush 一个 `(core, rob_idx)`。 |
| `isa_dpi_flush_all` | 清空指定核所有在途 entry；空 ROB 上幂等。 |
| `isa_dpi_clear_mem_reserve` | 清除指定核 LR/SC reservation。 |
| `isa_dpi_check_interrupt` | 采样设备中断并记录到目标核，不立即 take。 |
| `isa_dpi_has_pending_interrupt` | 查询指定核是否有有效 pending interrupt。 |
| `isa_dpi_take_interrupt` | 取指定核 pending interrupt；以 `next_pc`、`redirect` 输出 `IsaApiDirReq`。 |
| `isa_dpi_take_interrupt_now` | 以 `(value, mask)` 立即作用于已提交状态。 |

`besim_main.c` 的等价单步顺序为：

```text
check_interrupt
take_interrupt
get_spec_pc
fetch_mem_bank_virt(pc, 2)
  如果低 halfword 的 bits[1:0] == 3，再 fetch_mem_bank_virt(pc+2, 2)
decode_and_issue
execute_insn（PENDING 时重复）
  CBO.ZERO       -> proc_mem_req
  load/LR/AMO/SC -> proc_mem_load；SKIP 时 proc_mem_req
  store          -> store_commit（向量 store 循环排空）
commit
  commit 失败 -> take_trap + flush
tick_finish(true)
```

## 9. 指令调试、trap 和日志

| DPI | 作用 |
| --- | --- |
| `isa_dpi_get_insn_pc` | 读取在途 entry 的原始 instruction PC。 |
| `isa_dpi_get_insn_rd_value` | 读取在途标量 rd 结果。 |
| `isa_dpi_get_next_pc_of_insn` | redirect 时返回目标，否则返回 `inst_pc + 2/4`。 |
| `isa_dpi_is_insn_redirect` | 查询在途 entry 是否产生 redirect。 |
| `isa_dpi_trigger_trap` | 对 fetch-stage 等外部发现的异常注入 `(trap_type, tvalue)`。 |
| `isa_dpi_has_trap` | `commit_auto` 后查询物理 ROB slot 是否记录了 trap。 |
| `isa_dpi_log_run` | 按当前 entry 已达到的 pipeline stage 输出一行 run log；需先打开 run log。 |
| `isa_dpi_log_commit` | 输出一行 commit log；需先打开 commit log。 |

日志控制函数对应 `IsaApi.h` 的全局 API，不需要模型句柄：

| DPI | 作用 |
| --- | --- |
| `isa_dpi_enable_run_log(core_id)` / `isa_dpi_disable_run_log(core_id)` | 打开/关闭 run log；`core_id == ISA_API_LOG_GLOBAL` 表示全部核。 |
| `isa_dpi_run_log_enabled(core_id)` | 查询 run log 开关。 |
| `isa_dpi_set_run_log(log_path)` | 设置 run log 文件路径。 |
| `isa_dpi_enable_commit_log(core_id)` / `isa_dpi_disable_commit_log(core_id)` | 打开/关闭 commit log。 |
| `isa_dpi_commit_log_enabled(core_id)` | 查询 commit log 开关。 |
| `isa_dpi_set_commit_log(log_path)` | 设置 commit log 文件路径。 |

## 10. 编译和加载

wrapper 需要 simulator 提供的 `svdpi.h`。以支持 DPI-C 的仿真器为例，命令行的核心部分是：

```bash
c++ -std=c++17 -fPIC -shared \
  -I$ISA_MODEL_ROOT/src/libs \
  -I<simulator-dpi-include> \
  dpi/isa_dpi_wrapper.cc \
  -L$ISA_MODEL_ROOT/build -l_ISA_api \
  -Wl,-rpath,$ISA_MODEL_ROOT/build \
  -o build/libisa_dpi.so
```

SV 编译时把 `dpi/isa_dpi_pkg.sv` 加入 file list，并在 testbench 中：

```systemverilog
import isa_dpi_pkg::*;
```

仿真启动时加载 `libisa_dpi.so`。`IsaApi.h` 和 `lib_ISA_api.so` 必须来自同一版本；如果 API 头文件增加了声明，需要同步增加 wrapper 和 package 的 DPI 声明。
