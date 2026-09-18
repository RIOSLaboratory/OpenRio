# Cache Agent 功能实现文档

## 1. 接口线的功能职责

### 1.1 输入

| 线 | 功能 |
| ---- | ------ |
| `rst_n` | 清空全部在飞状态；复位期间 `lsu_be_issue_ready` 驱 0 |
| `global_flush` | 一拍脉冲，清空全部在飞条目、暂存授权与待发终态 |
| `be_lsu_issue_valid` + `be_lsu_issue_pld` | 一次握手交付一条访存请求的全部输入（无独立地址/数据通道） |
| `be_lsu_entry_ready` | BE 是否接收终态；除复位与 flush 同拍外恒 1 |
| `be_lsu_store_wakeup_valid` | 一拍脉冲，授权最老的未授权普通 store；不带 tag |
| `lsu_be_issue_ready` | 接口内 `assign` 产生，agent 只读 |

### 1.2 输出

| 线 | 功能 |
| ---- | ------ |
| `lsu_store_buffer_full` | 写侧占用是否达深度；寄存输出，喂给接口的 ready 表达式 |
| `lsu_be_done_valid` / `_pld` | 该 tag 的正常终态；读侧带结果，写侧与 fence 带 0 |
| `lsu_be_exception_valid` / `_pld` | 该 tag 的异常终态；与 done 互斥 |
| `lsu_be_bypass_valid` / `_pld` | 结果广播；与 done 同拍，无 ready，不重发，仅 read_side |

### 1.3 ready 的产生

```systemverilog
// or_be_lsu_if.sv —— 组合，按请求类别限定
assign lsu_be_issue_ready =
    rst_n && !(req_property_is_store_side(be_lsu_issue_pld.req_property) &&
               lsu_store_buffer_full);
```

分工：**占用状态由 agent 寄存（`lsu_store_buffer_full`），接受判断由接口组合。**
agent 另设超容量检查，接到超出容量的请求即报错。

---

## 2. 调用的函数

### 2.1 ISA Model DPI

模型的单步参考序（`isa_dpi.md` §8）：

```text
decode_and_issue                       ← BE agent
execute_insn（PENDING 时重复）          ← 访存指令归 cache agent
  load / LR / AMO / SC -> proc_mem_load；SKIP 时 proc_mem_req
  store                -> store_commit
commit / tick_finish                   ← BE agent
```

| 函数 | 做什么 | 调用时机 | 返回码处理 |
| ------ | -------- | --------- | ----------- |
| `execute_insn(core, rob_idx)` | 模型执行该指令。地址翻译在此完成且只做一次；对 store 是把数据填进已有的 store buffer 条目（条目由 `decode_and_issue` 建） | 记录建立后，每拍重试直到非 PENDING | `PENDING`→下拍重试；`PASS`→继续；其余→转异常 |
| `proc_mem_load(core, rob_idx)` | 读/决定侧：load/LR 取数、AMO 取旧值并算新值、SC 测预约置 rd。load/LR 会叠加在飞 store（youngest-wins per byte）；**AMO 读不转发**。对 AMO/SC 规格化缓冲条目 | 读侧记录 `executed` 之后 | `SKIP`→改调 `proc_mem_req`；`PENDING`→重试；非 PASS→转异常（模型已自记 trap） |
| `proc_mem_req(core, rob_idx)` | 无读侧请求的通用入口 | ① `proc_mem_load` 返回 SKIP ② FENCE / FENCE.I | `PASS`/`SKIP` 均算成功 |
| `get_insn_rd_value(core, rob_idx)` | 取该 tag 的标量 rd 结果，已完成符号/零扩展与 NaN-boxing | `proc_mem_load` 成功后 | 直接作为 `done_pld.data` |
| `store_commit(core)` | 排出模型 store buffer **最老**的一项到内存/设备并弹出。**不带 rob_idx**；是条目生效并离开 buffer 的唯一途径（flush 只弹出） | 写侧记录已授权且为写侧队头时 | 非 PASS → 见 §5.2 |
| `clear_mem_reserve(core)` | 作废 LR/SC 预约 | 每次 `store_commit` 成功后 | 非 PASS → fatal |
| `translate_pte(...)` + `get_priv(core)` | 只读查询：该地址在当前特权级下按此访问类型报什么 cause / tval | 转异常时 | 见 §4.3 |
| `trigger_trap(core, rob_idx, cause, tval)` | 把 LSU 侧判定的异常注入模型 | 发 `lsu_be_exception` 前，且 `has_trap` 为 0 | 非 PASS → fatal |
| `has_trap(core, rob_idx)` | 查该槽位是否已记录 trap | 注入前去重 | — |

**普通 store 不调 `proc_mem_load`**（模型会拒绝）。写侧与读侧从这里分叉。

### 2.2 冻结包 helper

| 用途 | 符号 |
| ------ | ------ |
| 请求分类 | `req_property_is_read_side/_store_side/_plain_store()` |
| 分类与指令身份一致性检查 | `req_property_matches_subop()` / `mem_funct3_matches_subop()` |
| 访问字节数 | `mem_funct3_bytes()` |
| 逻辑 memop → 模型 opcode | `lsu_memop_from_subop()` |
| cause 合法号集合 | `is_defined_sync_cause()`（agent 内，见 §4.3） |
| 容量常量 | `LSU_STORE_BUFFER_DEPTH` = 4 / `LSU_LOAD_PIPE_STAGES` = 2 |
| 宽度与类型 | `LSU_TAG_W` / `LSU_DATA_W` / `be_lsu_issue_pld_t` / `lsu_cause_t` |

**agent 内不得出现 `exe_subop[` 形式的手工切片**，字段投影只属于 `exe_subop_pkg`。

### 2.3 本地 helper

| 谓词 | 用途 |
| ------ | ------ |
| `older_store_pending(e)` | 落地顺序闸：本条是否为写侧队头（§5.2） |
| `faulted_store_parked(e)` | 是否有已报异常的 store 记录停在前面（§5.2） |
| `store_buffer_count()` / `read_pipe_count()` | 两侧占用（§5.3） |
| `dpi_rob_idx(tag)` | tag → 模型槽号；当前恒等，tag 宽度与模型 `rob_size` 需显式对齐 |

---

## 4. 请求分类与调用序

### 4.1 分类

```text
read_side  = load | LR | AMO | SC       有结果回写
store_side = store | AMO | SC           写内存（LR 不算）
misc       = FENCE | FENCE.I            两者皆非
```

AMO / SC 两侧都是。

### 4.2 各类调用序

**load / LR**

```text
execute_insn ──► proc_mem_load ──► get_insn_rd_value ──► done + bypass
```

- 不等更老的 store 落地——模型对读侧转发在飞 store。
- LR 不占写侧资源。

**普通 store**

```text
execute_insn ──► [等授权] ──► [等写侧队头] ──► store_commit ──► clear_mem_reserve ──► done(data=0)
```

- 两个"等"分别是 §5.1 与 §5.2 的闸。
- `execute_insn` 之后数据在模型 store buffer，`store_commit` 才落内存。
- 无 rd，无 bypass。

**AMO / SC**

```text
execute_insn ──► [等写侧队头] ──► proc_mem_load ──► get_insn_rd_value
             ──► store_commit ──► clear_mem_reserve ──► done(data) + bypass
```

- **读侧也受写侧队头闸约束**（AMO 读不转发在飞 store）。
- **不需要授权**，issue 时即视为已授权。
- SC 成败在 `proc_mem_load` 决定；失败的 SC 是正常完成、rd = 1，不是异常，
  `store_commit` 照调（弹出、不写内存）。

**FENCE / FENCE.I**

```text
execute_insn ──► proc_mem_req ──► done(data=0)
```

- FENCE.I 提交后的重取由 BE 侧触发，不是 agent 的事。

### 4.3 异常路径

任一步返回非 PASS 转异常。cause 来源两级：

```text
translate_pte(vaddr, priv, memop, length)
  ├─ trap_valid ∧ is_defined_sync_cause(trap_type)  →  采用 trap_type / trap_tval
  └─ 否则                                            →  store_side → 7；其余 → 5
                                                        tval → 虚地址
```

`is_defined_sync_cause` 的合法集 `{0..13, 15, 20..23}`，与参考环境 bt 的
`map_trap()` 表项一致。保留号 `14` / `16`–`19` 与 `> 23` 走回退。

**cause 全集与本环境可达性**

| cause | 含义 | LSU 边界 | 可达 |
| ------: | ------ | --------- | ----- |
| 4 | Load address misaligned | ✅ | 否（模型原生支持非对齐） |
| 5 | Load access fault | ✅ | **是** |
| 6 | Store/AMO address misaligned | ✅ | 否（同 4） |
| 7 | Store/AMO access fault | ✅ | **是** |
| 13 | Load page fault | ✅ | 否（bare 模式） |
| 15 | Store/AMO page fault | ✅ | 否（bare 模式） |
| 21 / 23 | Load / Store guest-page fault | 需 H 扩展 | 否 |
| 0,1,12 | 取指类 | ❌ 走 FE 通道 | — |
| 2,3 / 8–11 / 20,22 | 非访存异常 | ❌ | — |
| 14, 16–19 | RISC-V 保留 | ❌ 走回退 | — |

5 / 7 的激励来源：`dv/cfg/or_be_1core.yaml` 的内存空洞 `0x20001000`–`0x7FFFFFFF`，
定向用例 `dv/isa_case/or_directed/or-p-lsu_access_fault.riscv`。

**三条规则**

| 规则 | 内容 |
| ------ | ------ |
| 回灌模型 | 发 `lsu_be_exception` 前，若 `has_trap` 为 0 则调 `trigger_trap` 注入。读侧由 `proc_mem_load` 自记，实际对写侧生效 |
| 终态唯一 | done 与 exception 互斥且各只发一次；已有异常不再排正常完成，已排异常不再排第二次 |
| 故障记录不退场 | 留在写侧队头直到 trap 驱动的 flush。模型侧那条故障条目同样要等 flush 才被弹出，退场会让后续 drain 排错对象 |

---

## 5. 授权、顺序、容量与延迟

### 5.1 授权 —— 能不能写入

```text
store_authorized(t) = st_br_resolve(t) || wakeup_received(t)
```

- 两条**等价**路径，不是 AND。
- 只有普通 store 需要授权；AMO / SC / LR / FENCE 在 issue 时即视为已授权。
- 唤醒不带 tag，指向最老的未授权普通 store。
- 允许早于 issue 到达，暂存**至多一份**；未消费时再来一个是协议违规。
- 授权不改变落地顺序。

### 5.2 顺序 —— 什么时候落

`store_commit` 排模型 buffer 的头、不认 tag，所以：

```text
agent 的写侧调用顺序  必须等于  模型 store buffer 里的顺序
模型 store buffer 顺序 = decode_and_issue 顺序 = 分配序 = 程序序
```

条目在 `decode_and_issue`（模型内 `StoreBuffer::pushIssue`）建立，`execute_insn`
只是填数据。**agent 的 `execute_insn` 调用顺序不影响 buffer 顺序**，只需守住排出顺序。

两条前提：

| 前提 | 由谁保证 |
|------|---------|
| 排出按到达序 | 写侧队头闸（agent） |
| 到达序 = 程序序 | **A1：ISQ 深度 1、按序交付**（架构前提，非 agent 可保证） |

**`store_commit` 非 PASS 的三种成因**，返回码上不可分，只有模型的诊断行能区分：

| 模型诊断 | 含义 | 性质 |
| --------- | ------ | ------ |
| `empty storeBuffer` | 要排但 buffer 空 | TB 侧 |
| `head entry not data-ready` | 队头那条的 `execute_insn` 没跑过或跑失败 | TB 侧 |
| `write rejected` | drain 时内存派发失败 | **真故障** |

**处理规则：先证明，再翻译。** 普通 store 的访问错误只在这里暴露，
所以不一律 fatal；但要先把另外两种证否：

```text
本条是写侧队头 ∧ 已 executed ∧ 无已报异常的 store 停在前面
  成立 → 只可能是 write rejected → 翻译成 cause（写侧 7）并注入模型
  不成立 → 报 TB 错误，指向模型的 storeCommit 诊断行
```

前两条在代码中重新检查一遍，作为门被改动时的护栏。

### 5.3 容量与延迟

延迟 = 走几拍；容量 = 还能不能再收。只有容量产生背压。

**分段延迟**

| 侧 | 段 | 拍数 | 模型调用 |
| ---- | ---- | -----: | --------- |
| 读 | AGU（含地址翻译） | 1 | `execute_insn` |
| 读 | Cache 读 | 1 | `proc_mem_load` |
| 写 | AGU → STB | 1 | `execute_insn` |
| 写 | STB 驻留 | 不定（等授权 §5.1、等写侧队头 §5.2） | — |
| 写 | STB → 内存 | **暂定** | `store_commit` |

**容量**

| 资源 | 常量 | 深度 | 背压 |
|------|------|-----:|------|
| 写侧 STB | `LSU_STORE_BUFFER_DEPTH` | 4 | 满 → 该拍对 store 侧请求 `ready = 0`；**接口上唯一的背压源** |
| 读侧流水 | `LSU_LOAD_PIPE_STAGES` | 2 | 无——`read_side` 永不被拒 |

STB 占用区间：接受起，到**落内存**为止（含 AGU→STB 那 1 拍）。超容量即报错。

**冻结状态**

| 量 | 值 | 状态 |
|----|-----|------|
| 读侧流水级数 | 2 | 已冻结 `LSU_LOAD_PIPE_STAGES` |
| STB 深度 | 4 | 已冻结 `LSU_STORE_BUFFER_DEPTH` |
| AGU → STB 拍数 | 1 | 架构给定，未进冻结包 |
| STB → 内存 拍数 | — | **暂定** |

agent 不复现上表延迟：读侧两步同相位完成，`store_commit` 立即返回。
可调的只有终态回送时刻：`CACHE_LOAD_RETURN_DELAY_CYCLES` /
`CACHE_STORE_DONE_DELAY_CYCLES`（后者只推迟 `done`，不推迟 `store_commit`）。

---

## 6. flush 与复位

flush 一拍脉冲，清空全部在飞条目、暂存授权与待发终态。
flush 只在提交点触发，在飞的一切按构造都更年轻，因此不区分类型、无 partial flush。

同拍规则——**flush 拍上的事务视为从未发生**：

| 事务 | flush 同拍 |
|------|-----------|
| issue | 不接收；BE 不重发 |
| store wakeup | 不接收 |
| done / exception | 不接收，直接丢弃，不得下一拍重驱 |
| bypass | 不发出 |

被丢弃的 tag 立即可复用，无恢复拍数。