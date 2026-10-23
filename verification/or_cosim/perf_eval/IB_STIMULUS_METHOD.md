# IB 激励注入法（IB Stimulus Injection）

> 用"按拍序直接向 IB 灌入指令"取代"汇编 .S → 编译 .ELF → 经 FE 取指"，
> 作为 timing diagram / caselist 性能符合性验证的**激励投递方式**。
> 本文只讲方法与落地，不改动任何 case 的推导结论。

状态：**timing diagram / caselist 已采用 IB 激励注入**；`.S → .ELF` 路径仅保留为历史回归基线，不再作为 diagram 的主投递形式。

---

## 1. 原理

### 1.1 IB 是 BE 的唯一输入面

BE 看不见"指令是从哪来的"，它只看见 **IB 的入队事件**。而且这个入口是**完备的**——
IB 的 payload（`orbe_fe_instr_pld_t`）里不只有 `pc` / `inst_bits` / `is_compressed`，
连分支预测结果 `pred_taken` / `pred_target_pc` 和取指异常 `fetch_excp_*` 都在里面。

> **谁控制了 IB 的入队事件，谁就控制了 BE 的全部输入空间。**
> 从 BE 的角度，TB 灌进去的和程序取指来的，是同一类东西，它分不出来。

这是整个方法的立足点，其余都是它的推论。

### 1.2 diagram 的时间原点本来就在 IB

不是巧合——你们的 timing diagram 与 caselist 的坐标原点就定义在 IB：

| 证据 | 内容 |
|---|---|
| diagram 的 stage 表 | `IB` = **P0**，*"The instruction is enqueued into the instruction buffer. This cell marks the **enqueue cycle only**."* |
| 方法论 §6.5 归一化时间轴 | *"Producer 的 `IB` 阶段定义为 `T1`；Producer 首次 Dispatch（RS）定义为 `T2`"* |
| 方法论 §8 硬约束 | *"**每条指令必须从 IB 开始**……如果 IB/RS 阶段在 case 关注的时间窗口之前，应向左扩展时间轴"* |
| 方法论 §10 P3 仲裁 | *"**允许不同指令的 `IB` 起点错开**"*，且明确禁止"靠空白硬凑" |

也就是说，**timing case 本质上是"以 IB 入队拍为坐标、直接指定每条指令 T 位置"的一组时序断言**。
既然图的自变量是"拍"，那么让激励直接在"拍"这一侧可控，就是把控制点和被控点对齐。

### 1.3 控制变量换了一组（反问题 → 正问题）

| | 走 FE（`.S → .ELF`） | 走 IB 注入 |
|---|---|---|
| **你能直接设定的** | 程序文本（指令序列） | 逐拍的 `valid` + `payload` |
| **拍序（T / delta）是** | **派生量**：由取指带宽、I\$、BTB、对齐、RVC 共同推出 | **输入量**：表里写几就是几 |
| **要解的问题** | 反问题 `拍序 = f(指令序列)`：不唯一、有约束、**可能无解** | 正问题 `指令序列 = g(拍序)`：**总有解** |

正问题之所以"总有解"，是因为 1.4。

### 1.4 "空拍"是协议内合法状态

IB 的入队条件：

```
enqueue[s].fire = fe_valid[s] ∧ fe_ready[s]
```

`fe_valid = 0` 是**合法且正常**的状态（IB 的 `dequeue` 基于队列有效性，没有新入队就是没东西可发）。
**空拍不产生任何指令，因此没有任何下游足迹**：不占 ISQ（depth=1）、不占 Group、不抢 P3、
不进 ROB、不需要 commit。所以"拖延"在这个投递方式下是**零成本**的。

而指令流里**没有"空拍"这个符号**：写 `nop` 也是一条要进 IB、要 dispatch、要活完整条生命的真指令。

---

## 2. 相比 `.S → .ELF` 的优势

### 2.1 不再需要填充物（filler）

filler 存在的**唯一理由**是：想让某条指令晚 N 拍到 IB，而指令流只能靠"塞别的指令"来占位。
而 filler 是**真指令**，必须走完整生命周期，于是它成了时序的**参与者**而非背景：

- 占 ISQ（**depth = 1**，结构性冲突）；
- 占 Group，受 Group/Dispatch 规则约束；
- 在 **P3 抢写回 lane**；
- 要 commit，受 ROB 顺序约束。

这直接把 case 推导变成了"和 filler 抢仲裁"的工程。**真实教训（10/10 的提交记录）**：

```
5d03f8c  Calibrate a filler recipe that keeps off the producer's writeback lane
475e1ef  Quantify the filler-versus-producer writeback-lane contamination
9c54293  Calibrate INT2_P4_G3P3 with a chained-filler recipe
ed82b91  Correct the P4_G3P3 filler chain and record the technique
a08210c  Fix delta 0, move JALR to a MUL producer, and follow the consumer-only ruling
```

注意 `a08210c`：连"JALR 只能作 consumer"这条 ruling，也是在这个投递方式下被逼出来的（见 §3.6）。

IB 注入后，"隔 N 拍"= 那 N 拍 `valid = 0`，**filler 直接消失**。

### 2.2 坐标系天然对齐

T1 = 你拉 `fe_valid` 的那一拍。因此：

- 不需要从波形反推"第一条指令什么时候进 IB"；
- 不需要在 case 里写"归一化"语言（历史上确实为此返工过：`d706d7e`、`e24d32a`、`08b9ab0`）；
- 顺带消掉 pipeview 方案里的坑——`plot_pipeview.py` 画绝对 cycle，而 caselist 用相对 T，两者不能直接叠。

### 2.3 与 FE 解耦

不受 I\$ miss、BTB、取指带宽、压缩指令对齐影响。BE 的时序验证不再被 FE（他人负责）拖住，
也不需要为了"让真实 FE 能预测"而被迫使用整机 `rtl_full`（见 §3.3、§3.6）。

### 2.4 预测字段可控

`pred_taken` / `pred_target_pc` 是激励给的**字面值**，于是：

- **"预测命中"从撞运气变成构造出来的前置条件**——可复现、可扫参；
- 反过来，**故意填错 target**即可稳定构造 Recovery 维度（mispredict）case，
  正好符合方法论 §8"mispredict / exception 属于 Recovery 维度，不要混进普通 timing case"。

### 2.5 可回归、可扫参

`delta` / `slot` / `group` 变成激励表里的行号与列，天然是**参数化扫描 + 覆盖率**，
而不是 32 个（ALU 5 + MUL 7 + DIV 8 + LOAD 7 + JALR 5）手写的 `.S`。

### 2.6 更贴合 diagram 自己的前提

diagram 明确声明只画 *"nominal **no-older-blocker** path"*。而 filler 恰恰就是 older blocker：
它制造的"输掉 P3 仲裁"这类噪声与 case 主题无关，还破坏了图的前提。
注入模式下"就这几条、其余全空"，**整机资源状态是干净的**，比塞满 filler 的流更忠实。

### 2.7 成本对比

| 维度 | `.S → .ELF` | IB 注入 |
|---|---|---|
| 表达"隔 N 拍" | 需 filler（有副作用） | `valid = 0`（零成本） |
| 拍序可复现 | 依赖 FE 行为，弱 | 构造即确定，强 |
| 预测可控 | 依赖真实 BPU，不可控 | 字面指定 |
| 与 FE 耦合 | 强 | 无 |
| 单 case 成本 | 汇编 + 链接 + 整机仿真取指 | 一张激励表 |
| 值级 golden（ISA model） | **自带** | **会丢**（见 §4） |
| 覆盖 FE 行为 | 是 | **否**（见 §4） |

---

## 3. 在本架构中的实战

### 3.1 注入面：`orbe_fe_if`（FE↔BE 总线）

`verification/or_cosim/tb/interfaces/orbe_fe_if.sv`：

```systemverilog
typedef struct packed {
  logic [63:0] pc;
  logic [31:0] inst_bits;
  logic        is_compressed;
  logic        pred_taken;
  logic [63:0] pred_target_pc;
  logic        fetch_excp_vld;
  logic [4:0]  exception_cause;
  logic [63:0] exception_tval;
} orbe_fe_instr_pld_t;
```

接口上还有 `fe_be_instr_valid[2]` / `be_fe_instr_ready[2]` / `be_fe_redirect_valid` + payload。
**这就是 IB 的入队面**（IB spec 里叫 `fe_valid[s]` / `enq_IB_Payload[s]`），不需要新建接口。

### 3.2 现成的驱动器：`fe_agent`

`tb/agents/fe/fe_agent.sv`（426 行）头注释：*"Agent on the FE↔BE interface …… hands **raw
instructions** to the DUT using the `orbe_fe_if` handshake"*。它已经在做"往 IB 灌指令"这件事：

```systemverilog
vif.fe_be_instr_valid <= offer_valid;          // :332
foreach (offer_pld[i]) vif.fe_be_instr_pld[i] <= offer_pld[i];
// drive_idle(): :283
vif.fe_be_instr_valid <= '0;
foreach (vif.fe_be_instr_pld[i]) vif.fe_be_instr_pld[i] <= '0;
```

但它**现在不是按拍编排的**，它跟着 ISA model 走，并自我声明了两条边界：

- *"This stage does not aim for **timing accuracy**."*
- `be_tb_top.sv:390`：*"fe_agent **never predicts** (pred_taken = 0)"*

所以要做 IB 注入，**不是从零造**，而是给它加一个"按拍表驱动"的定向模式
（或写一个平行 agent 复用同一个 `orbe_fe_if`）。

同时注意它兼着两个不能丢的职责：

1. **ISA model 的生命周期管理**——实例由 `initial_agent` 创建，但销毁由它负责
   （*"only this Agent's steady-state loop can observe 'the model requests exit'"*）；
2. **响应 BE 的 redirect**（`be_fe_redirect_valid` → `next_pc = redirect_pc`）。

> 结论：**"取代 FE" = 换掉它的"取指决策"，保留它的"协议驱动"。**
> 你可以把它改名成 `ib_stimulus_agent`，但物理上省不掉——总得有人驱动那几根线，
> 唯一的区别是这段逻辑写在 class 里、UVM driver 里，还是 `force` 里。

### 3.3 FE 槽是可替换的（`dut_kind`）

`tb/top/be_tb_top.sv`：

- `:27` `orbe_fe_if fe_vif(clk, rstn);`
- `:85` `rtl_v1` / `rtl_cache`：**真实 FE 不在**，由 `fe_agent` 供指；
- `:265` `rtl_fe`：**真实 OR_FE RTL 顶掉 `fe_agent`**。

因此"注入"与"整机 `rtl_full`"目前是**互斥**的：FE 槽要么是 agent，要么是真实 FE RTL。
选 kind 的判据是**case 是否需要 Cache**（LOAD/STORE 类需要），而不是"是否要预测"（见 §3.6）。

### 3.4 驱动骨架（真的写法）

`inject()` 之类**不是 SV 内建**，那只是伪代码代称。真实写法就是信号赋值：

```systemverilog
class ib_stimulus_agent;
  virtual orbe_fe_if.tb vif;

  // 表里的一行：第 cyc 拍从 lane 放入一条指令（pc + 原始指令位）
  task automatic inject_at(int unsigned lane, logic [63:0] pc, logic [31:0] bits,
                           logic pred_taken, logic [63:0] pred_target);
    vif.fe_be_instr_valid[lane]      <= 1'b1;      // lane1 必须与 lane0 同拍
    vif.fe_be_instr_pld[lane].pc            <= pc;
    vif.fe_be_instr_pld[lane].inst_bits     <= bits;
    vif.fe_be_instr_pld[lane].is_compressed <= 1'b0;
    vif.fe_be_instr_pld[lane].pred_taken    <= pred_taken;
    vif.fe_be_instr_pld[lane].pred_target_pc<= pred_target;
    do @(posedge vif.clk); while (vif.be_fe_instr_ready[lane] !== 1'b1);  // 重试直到被接受
    vif.fe_be_instr_valid[lane] <= 1'b0;
  endtask
endclass
```

SV 里真正内建的相关机制只有：`force` / `release`（过程连续赋值）、`interface` / `modport`、
`clocking block`、`@(posedge clk)` / `#delay`。`$deposit` **不是标准**，是 VCS 的 PLI 扩展。

### 3.5 必须遵守的三条契约

1. **`fe_be_instr_valid` 不能组合依赖 `be_fe_instr_ready`**
   （`fe_agent` 头注释引的 *Interface Timing item 3*，也写在 FE_AGENT 契约里）。
   所以要在 posedge 驱动 / 寄存器化——上面的"重试"写法天然满足。
2. **必须尊重 `be_fe_instr_ready`**。IB 只有 8 entry，下游 stall（如 Condition A 卡住队头）时会满，
   那一拍的注入**没被接受**。不重试就会静默错一拍，比失败更难查。
3. **lane 是前缀序**：`lane 1` 不能单独 fire（接口注释与 IB FSM 都规定
   `enqueue[1].fire → enqueue[0].fire`，fire 向量只能是 `00 / 01 / 11`）。
   按方法论 §9，stall 恢复后单独 dispatch 本来就必须是 **slot0**，所以这条基本不构成限制。

### 3.6 JALR：从"必然 flush"到"可强制命中"

**现状问题**：`fe_agent` 恒定 `pred_taken = 0`，于是每个 JALR 必然 mispredict → P4 Late Flush → redirect，
无法作为稳定的 producer 为后续 consumer 供数。这是"JALR 只能作 consumer"那条 ruling 的直接成因。

**RTL 判据**（`fu/alu_simple.sv:440`）：

```systemverilog
assign mispredict_flag = is_bru_op &&
                         ((branch_taken != pred_taken) ||
                          (branch_taken && (pred_target_pc != branch_target)));
```

JALR 的解析（`:378-382`，`is_g0_bru_subop` 列表在 `:428-429`）：

```systemverilog
SUBOP_JALR, SUBOP_C_JR, SUBOP_C_JALR: begin
    branch_taken  = 1'b1;
    branch_target = (rs1_data + imm_data) & ~64'd1;
end
```

**flush 原因集合是封闭的**（`p4/CompletionScoreboard.sv:415-524`，`head0`/`head1` 各一份）：

```
{ exception, interrupt, MRET, SRET, FENCE.I, mispredict }
```

**没有任何 JALR 专属路径**；`p4/flush_model.sv` 里 `flush_apply = flush_valid`，
`global_flush_late` 只有一个生成者。

**结论**：

| 激励取值 | 结果 |
|---|---|
| `pred_taken = 0`（现状） | 第一项为真 → **mispredict → Late Flush → redirect** |
| `pred_taken = 1` 且 `pred_target_pc = (rs1+imm) & ~1` | 两项皆假 → `mispredict_flag = 0` → **不 flush，普通退休** |

即：**"强制命中"就是把这两个字段填对**，而它们本来就是 FE 侧供给的输入。

三个必须注意的点：

1. **`pred_target_pc` 要逐位相等**，注意 `& ~64'd1`——bit0 必须为 0，差一位就是 mispredict；
   且 `rs1_data` 是 BRU 在 P2 实际看到的操作数（可能来自 bypass），激励必须保证它的值。
2. **真实性待确认**：真实 FE 的 BPU 能否预测 JALR？
   能 → 这是架构可达场景；不能 → 该 case 只是"BE 接口上的合法输入"，图上必须写明前提。
3. **是否真构成新等价类**：若 JALR 不 flush，它就退化成"G0/ALU0 上一条延迟 1 拍的普通 producer
   + link 写回"（`alu_simple.sv:530-532`：link = `fallthrough_pc`）。按方法论 §5 的判断标准，
   **若不产生新的 stall / bypass 路径，就不该单独成图**。
   **此点已由 case set owner 裁定为"保留"，判据改为执行资源覆盖（BRU 与 ALU0 同 FU），见 §9.5。**
   另："same-PC warm-up prerequisite" 只在 `.S` 路径下需要；注入法直接给足预测字段，
   该前提**不再需要**。

### 3.7 激励文件的形态

方法**没有**规定格式，可自定。推荐"表驱动"（可读、可回归、可扫参）：

```
# cycle  lane  pc            inst_hex     pred_taken  pred_target
1        0     0x8000000c    0x002081b3   0           0x0
3        0     0x80000010    0x403182b3   0           0x0
```

`cycle` 就是 diagram 里的 T 号，**delta 在文件里字面可读**。

**最省力的落地方式（混合）**：`inst_bits` 不必手算——照样写 `.S`，用 `as`/`objdump`
把每条指令的 32 bit 编码抽出来，只是**不再把 ELF 交给 FE 跑**，而由 TB 按表推入。
原有工具链一行不废，只换掉"谁决定什么时候进"。

### 3.8 激励通常不止"核心那两条指令"

- **前置状态**：寄存器/内存初值。例如 `ld x7,0(x8); add x9,x7,x10`，`x8` 得有值、内存得有数据，
  否则 LSU 取不到数。方法论 §6.4 要求"清零初始化指令**不得出现在分析表格中**"，
  但**激励里它们必须存在**——两者不矛盾。
  两种做法：① 用前置指令注入（要放得足够早，且会占 ROB/带宽）；
  ② reset 后后门直接预置 ARF / 内存（更干净，但要再建一个 backdoor 面）。
- **重试语义**：见 §3.5 第 2 条。

---

## 4. 边界：这套方法**不**覆盖什么

1. **不是 ST**。绕开 FE 后，FE→BE 接口行为（redirect 后能否及时供指、握手是否正确、
   flush 与 enqueue 同拍）测不到——这些必须走 FE 路径。所以两条路**互补**：
   IB 注入验 BE 时序（diagram 覆盖的一切），FE 路径验 FE/BE 边界与整机。
2. **丢掉 ISA model 这个值级 golden —— 但不必真的丢掉**。ELF 路径顺带给了 cosim 参考与
   `tohost` 退出。推荐做法是**同一张激励表也推进 ISA model**（§9.2 第 2 案）：既保留值级对照与
   退出机制，又不放弃拍序控制权。若最终选择"只查时序"，必须同时显式设计终止条件，
   否则仿真会跑到 timeout（§9.2 第 1 案）。
3. **FP / MEM 的图缺口不会被这套方法填上**——它只是投递方式，不产生期望。

---

## 5. 与既有方法论的关系

| 方法论条目 | 与本法的一致性 |
|---|---|
| §6.5 T1 = IB、T2 = 首次 dispatch | 注入把 T1 变成**可设定的量**，与该定义天然一致 |
| §8 每条指令必须从 IB 开始 | 注入天然满足（所有指令都从 IB 进） |
| §10 允许 IB 起点错开、禁止"靠空白硬凑" | 注入让"错开"成为**一阶变量**，正是该条想要的 |
| §6.6 `*_deltaN` 需"真实填充指令**或显式 precondition**" | 注入把 precondition 变成**可执行**的，不再依赖 filler |
| §8 Recovery 与普通 timing case 分离 | 预测字段可控后，mispredict case 与"预测命中"case 可**刻意分开**构造 |
| §14 对抗性审查（逐拍信号自洽性） | 仍适用；且因拍序是构造出来的，`Slot/Group` 与 `IB 起点` 的自洽性更易校验 |

---

## 6. 待办与待确认

| # | 事项 | 性质 |
|---|---|---|
| 1 | 定向注入模式：在 `fe_agent` 上加分支，还是另起 `ib_stimulus_agent`（复用 `orbe_fe_if`） | 实现选型 |
| 2 | 注入能力必须证明"**不改变被测时序**" | 新增验证项 |
| 3 | 真实 FE 的 BPU 能否预测 JALR（决定 §3.6 的 case 是架构可达还是 BE 合法输入） | 待确认 |
| 4 | JALR 在"预测命中"下是否构成新等价类（方法论 §5）；same-PC warm-up 的前提是否仍需要 | 待确认 |
| 5 | 是否保留 ISA model 作为值级 golden（§4 第 2 条） | **需求方拍板** |
| 6 | `dut_kind` 选择：纯 INT case 用 `rtl_v1`；含 LOAD/STORE 需要 Cache → 确认 `rtl_cache` 是否同样让 agent 占 FE 槽 | **已确认**：`cfg/filelist/rtl_cache.f` = BE RTL + OR_Cache RTL，**FE 仍是 fe_agent** ⇒ 注入法与真 Cache 可兼得 |
| 7 | "JALR 只能作 consumer" ruling 需按方法论 §5 的流程重开 | **已裁定**：保留 JALR producer 一族，依据见 §9.5 |

**上表各项的落点**：第 2 条的可判定化见 §9.3；第 4 条已由 §9.5 裁定；第 5 条的建议见 §9.2；
第 6 条已确认；本文档的关键断言已外部核实，见 §7。

---

## 7. 核实记录（外部复核）

关键断言不引用本文档自身，逐条对 RTL 与实测核实，避免"文档引用文档"。

| 断言 | 出处 | 核实结果 |
|---|---|---|
| lane 是前缀序，`lane1` 不能单独 fire | §3.5 第 3 条 | ✅ `p1/IB.sv:70/165/205/272`：*"two-bit **prefix** strobe, per slot"*、*"`accepted_slot` is a prefix"* |
| flush 原因集合封闭、无 JALR 专属路径 | §3.6 | ✅ `p4/CompletionScoreboard.sv` 的输入即 `is_fence_i` / `is_mret` / `is_sret` / `mispredict` / `exception` / `interrupt`；`p4/flush_model.sv` 只有一个 `global_flush_late` 生成者 |
| `mispredict_flag` 表达式 | §3.6 | ✅ `fu/alu_simple.sv:440`，与本文引用逐字一致 |
| 预测字段经 IB 进入 BE | §1.1 / §3.1 | ✅ `backend_top.sv:827/853`：`fe_instr_pld[s].pred_taken → enq_IB_payload[s].pred_taken`，再经 ISQ 到 FU（`isq0_pred_taken` → `alu_simple.pred_taken`）|
| `fe_agent` 恒 `pred_taken = 0` | §3.2 | ✅ `tb/agents/fe/fe_agent.sv:224/239/274` 硬编码；`be_tb_top.sv:390` 注释同述 |
| **预测命中 ⇒ 不 flush** | §3.6 结论表 | ✅ **实测**：同一条 JALR（pc `0x80000028`）在 `rtl_full` 上执行两遍，第 1 遍 `mispredict=1` 且发 redirect，第 2 遍 `mispredict=0` 且无 redirect（`timing/tools/jalr_btb_warmup.py`）|

最后一行是本文档最有价值的推论之一：它把"JALR 作 producer"从"必然被 flush"变成
"预测字段填对即可"。而 `.S` 路径下要让真 FE 命中，必须先预热**同 PC** 的 BTB 条目
（实测：换成不同 PC 的 JALR 预热无效）——注入法把这一步整个省掉。

---

## 8. 派发侧契约（§3.5 之外必须自己保证的部分）

§3.5 管的是**入队**（FE↔BE 面）。注入法把控制点前移到"谁在什么时候进 IB"，
于是**派发侧**的合法性要由激励表自己保证，否则会构造出架构不可达的状态——
那种 case 量到的不是"违例"，而是"不存在"。

| 约束 | 出处 | 对激励表的要求 |
|---|---|---|
| 同拍两个 slot 不能进同一个 group | `p1/dispatch_logic.sv` 的 `groups_distinct` | 同拍注入的两条必须落在不同组（ALU 可 G0/G1，MUL 固定 G1，DIV/CSR/BRU 固定 G0，LSU 固定 G3）|
| 每组 ISQ 只有 1 个条目 | `p2p3/ISQ_Group*.sv`：`isq_free_for_dispatch = !isq_valid \|\| issue_fire` | 同组两条至少错开一拍，除非前一条当拍发射 |
| `accept[1] ⇒ accept[0]`（`10` 结构上不可能）| `dispatch_logic.sv:116-117 / :420` | 单条指令必须放 **slot 0** |
| 同组 P3 写回 lane 每拍只有一个赢家 | `p2p3/p3_arbiter_G*.sv` | **注入法下不再需要照顾**：没有 filler 去抢 lane（§2.1）|

最后一行是本法最大的实际收益：`.S` 路径下我们花了数轮去"标定填充物以避开 producer 的写回 lane"
（`5d03f8c` / `475e1ef` / `9c54293` / `ed82b91`），注入法把它**从源头消掉**。

---

## 9. 实施规格

### 9.1 激励表格式（补全 §3.7 的语义）

```
# cycle  lane  pc            inst_hex     pred_taken  pred_target_pc   note
1        0     0x8000000c    0x002081b3   0           0x0              producer
3        0     0x80000010    0x403182b3   0           0x0              consumer, delta 2
```

- `cycle` 就是 diagram 的 `T` 号，**delta 在文件里字面可读**（§2.2）。
- `inst_hex` 由 `.S` 经 `as`/`objdump` 抽取（§3.7），**原工具链一行不废**。
- `pred_*` 是**逐指令**字段：普通算术指令填 `0/0`；JALR 要"强制命中"就填
  `pred_taken=1`、`pred_target_pc=(rs1+imm)&~1`（§3.6，注意 bit0 必须为 0）。
- 表中**未出现的 cycle 就是不注入**（`fe_valid=0`，§1.4），零成本。

### 9.2 终止条件（**强制**）

本方法**只保留 A（纯注入）**：不接 ISA model，因而**没有 `tohost` 退出路径**。
终止必须由激励侧定义，否则仿真会一直跑到 timeout。

**规则**：激励表跑完 → 继续驱动 `fe_valid = 0` 一个**排空窗口**（让已在流水线内的指令
走完并产出 P1/P2/P3/P4 事件）→ 结束仿真。

- 排空窗口长度取一个安全上界（例如覆盖最长 FU 延迟 + ROB 排空）；
- 排空窗口内**不得注入新指令**，否则测到的事件会混入未预期的指令；
- 建议在结束时打印一条汇总（注入了多少条 / 观察到多少条 / 是否排空干净），
  便于把"表没跑完"与"测到异常"区分开。

### 9.3 非侵入性验收试验（把 §6 第 2 条变成可判定）

"注入不改变被测时序"不能靠声明。建议验收条件：

> > 取一条**已冻结**的 INT 用例（例如 `calibrated_cases/MUL_to_ALU_delta_4.S`），
> 把它的**相关指令序列**用 A 重放，要求 **P1 / P2 / P3 逐拍与 `.S` 路径相同**；
> （该用例的 `.S` 输出是已知基线，`.S` 的初值/前导不必在 A 里复现——只比对被观测指令的相对拍序）
> 否则不接受该注入实现。此后任何注入驱动的改动都要重跑这条基线。

判据用 P1/P2/P3 而非 P4，是因为机制判定（`mech_of`）只依赖这三者；
若第 2 案（同喂 ISA model）落地，P4 与值级对照也应一并要求一致。

### 9.4 对现有材料的改动清单

| 现有材料 | 注入法下的变化 |
|---|---|
| caselist 的 `Fillers after each` 列 | 换成 **`Inject at cycle`**（或直接 `delta`）列；`gen_cases.py` 的解析随之改 |
| caselist / diagram 的 `Tn` 槽位与 landmark | **不变**（§5）|
| `run_perf.sh` / `compare.py` / `re_audit.py` | 仍可跑 `rtl_full`；判据不变 |
| `lane_check.py` 的 surplus | 注入法下应**恒为 0**——可作为"注入是否自洽"的旁证 |
| `calibrated_cases/*.S` | 保留为回归基线（§9.3），不再作为主投放形式 |
| `tools/` 里的填充物标定脚本 | 归档；其结论（哪种填充物抢哪条 lane）转为**校验注入合法性**的知识 |

### 9.5 JALR / BRU：裁定已下

§3.6 第 3 点提出的"若不产生新 stall/bypass 路径就不该单独成图"，**已被 case set owner 的裁定覆盖**：

- **裁定**：保留 `JALR_to_ALU` 一族（5 条）；
- **依据**：`top/backend_top.sv:1215` 的 FU 例化名是 `u_alu0_bru`，同文件 `:699` 注释写明
  "G0 : ALU0/BRU, CSR, DIV" ⇒ **BRU 与 ALU0 共用同一执行单元**，是需要被观测的**执行资源**；
- **性质**：这是**资源覆盖**判据，**不是**"依赖机制不同"的主张——两者 L 都是 1，
  阶梯与四种捕获机制确实相同；这一点已写进 caselist 的 JALR 小节，不再重新推导。

⇒ 注入法下 JALR 一族的成本从"要构造同 PC 的 BTB 预热"降为"表里多两列"，
且 `delta_0`（前缀序允许同拍 lane0+lane1）**一并可得**。

### 9.6 形态决定：**只做 A（纯注入）**

曾评估过另一种形态 B（指令字节取自内存镜像、pc 由 agent 游标推进、并保留 ISA model 做值级对照）。
**已决定弃用 B，只保留 A**，理由：

1. **性能验证不应以功能 golden 通过为前提**——否则时序结论会挂在 golden 之上；
2. A 的输入面完全自给：指令字节、pc、预测字段、时序**全部来自激励表**，
   与 model、与 ELF、与取指路径**全无关系**；
3. 结构因此大幅简化：没有游标、没有内存镜像（INT 类）、没有退出序列（§9.2 由排空窗口终止）。

**A 形态下各元素的来源（唯一一张表）**

| 元素 | 来源 |
|---|---|
| `pc` | **表格**（我们自己排布，例如 `0x80000000 + 4n`）|
| `inst_bits` | **表格**（由 `.S` 片段经 `as`/`objdump` 抽取，工具链不废）|
| `is_compressed` | **表格**（本 case 集统一 4 字节，填 0）|
| `pred_taken` / `pred_target_pc` | **表格**（普通指令 0/0；JALR 按期需填）|
| 注入 cycle / lane | **表格** |
| 终止 | 表跑完 + 排空窗口（§9.2）|
| 值级 golden | **不存在**（放弃）|

**A 的两处代价，均已明确**

1. **没有值级对照**：只判定时序与机制（P1/P2/P3 的关系），不判定算出的值对不对；
2. **LOAD/STORE 仍需一个内存来源**：D 侧数据要能取到。选项见 §3.8——
   前置指令注入（占用拍序预算）或 reset 后后门预置内存。
   **INT 类 case 不受影响**，故 `A 打通` 从 INT 类开始。

### 9.7 从 diagram 直接生成激励表

**图的 `IB` 格就是该指令的注入 cycle**，因此"图 → 激励表"是机械映射，不需要重新推导 δ。

以 `diagrams/INT_single_operand_dependency_diagram.md` 的 Case 3 为例：

```
| Instruction                | T1 | T2       | T3   | T4 | T5 | T6 | T7 |
| `add x5, x1, x2` Producer-G0  | IB | dispatch | ALU0 | WB | C  |    |    |
| `add x6, x5, x3` Dependent-G0 |    |          | IB   | dispatch | ALU0 | WB | C |
```

⇒ 激励表两行：

```
# cycle  lane  inst                              pred_taken  pred_target_pc
1        0     add x5, x1, x2                     0           0x0
3        0     add x6, x5, x3                     0           0x0
```

`3 - 1 = 2 = delta_2`。**表里的 `cycle` 与图的 `T` 号完全一致**——这正是 §2.2 说的
"坐标系天然对齐"，也是"判定基准是 diagram"（§5 表）在生成链上的直接落地。

### 9.7.1 "两条激励"要精确理解

"两条"指的是**表里被钉住时序的指令有两条**，不是"整个激励只有两条"：

| 还需要什么 | A 形态 |
|---|---|---|
| 寄存器初值（值级检出能力，LOAD/STORE 还需合法地址）| 程序自带 | 必须自己给 |
| 退出序列 / 终止 | `tohost` 自动 | 必须自己定（§9.2）|
| 前导（不要从 reset 后第一拍就钉）| 程序自带 | 自己给 |

**建议**：表的 `cycle` 直接按图的 `T` 号书写（`T1` = 被测序列第一条的注入拍），
驱动器把它映射到实际注入周期；若需要准备指令（例如给 LOAD 准备地址），把它们作为**表里的行**
排在被测序列之前，`T` 号相应后移。这样表保持"字面可读"这一好性质。

### 9.7.2 值对结果的影响（分两种）

| 情形 | 时序是否受影响 | 说明 |
|---|---|---|
| ALU / MUL / DIV / JALR | **不受影响** | BE 只按**寄存器号**做 tag 匹配与唤醒，不看值 |
| 但**全零初值会削弱 golden 的检出能力** | — | 读错值可能与正确值同为 0 而不被发现 |
| LOAD / STORE | **受影响** | 地址必须指向合法且（对命中用例）已缓存的区域 |

⇒ 因此**仍应保留有区分度的初值**（本 case 集模板给 `x1..x4 = 1,2,3,4` 就是这个原因），
不能因为"时序与值无关"就全省。

### 9.7.3 两条够不够观测五种机制

够。机制由 `dep.P1` 与 `prod.P3` / `prod.P4` 的关系决定（`overlay` / `wait_for_p3` /
`p3_capture` / `p4_capture` / `arf_read`），这四个拍都在这两条指令上可观测。
而**没有第三条指令**恰好是我们想要的：没有 lane 竞争（§2.1、§8 最后一行）。

**一条实施不变量**：要得到 `dep.P1 − prod.P1 = δ`，表中两条的注入 cycle 之差也应为 δ——
因为两者都是"入队后下一拍派发"，同增 +1。该等式成立的前提是**入队当拍即被接受**
（`.S` 路径下由取指节奏保证；注入路径下由 §9.3 的验收试验钉住）。

**⇒ 可直接做一个小工具：读 diagram 的表格 → 生成激励表（§9.1 格式）。**
这样 diagram 成为唯一来源，也顺带消掉 `Fillers` 列的推导与标定。
