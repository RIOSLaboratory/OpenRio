# 波形调试规范（WAVEFORM_DEBUG）

> 适用：`verification/or_cosim/` 的 COSIM 失败定位。
> 定位：本文补齐 `RTL_debug_flow_and_rule.md` 中"证据获取"这一环——从"加打印再跑"升级为"开波形回看"。
> 状态：2026-10-20 起草，随实践演进。

---

## 1. 为什么需要本文

`sim.log` 只能给出**点位**（哪条指令、哪个 cycle、哪个字段不对），无法回答：

- 这个错误值**从哪来**（哪一级、哪一拍产生）；
- 失配**之前**发生了什么；
- FE / BE / Cache **同一拍**的状态；
- valid/ready 握手、flush 与 commit 的**相对拍序**。

波形补上这四件事，但代价是磁盘与时间。本文规定**什么时候开、开多大、怎么取证、怎么固化**。

---

## 2. 何时开波形（分诊规则）

**默认不开。** 先跑 `TRACE=0` 的回归，按 `results.txt` 的关键词分类：

| 关键词 | 含义 | 是否开波形 |
| --- | --- | --- |
| `MISMATCH`（`_EQUIV` / `ARF` / `PC` / `MEM`） | DUT 与模型结果不一致 | ✅ **开**，这是波形的主战场 |
| `[COSIM][LEVEL2_MISMATCH]` | Level-2 内部节点失配 | ✅ 开（并同时开 `COSIM_LEVEL=2`） |
| `%Error` / `Assertion failed` | TB 自检失败 | ✅ 开，先看断言附近 |
| `simulation timeout` | 卡死 | ✅ 开，重点看最后 200 拍 |
| `%Error: Command Failed` / 构建错误 | 环境问题 | ❌ 不开，先修环境 |

> 判断标准：**"需要知道为什么"才开波形；"需要知道哪一条"看 log 就够。**

---

## 3. 开多大

| 参数 | 取值 | 说明 |
| --- | --- | --- |
| `TRACE` | `1`（VCD）或 `fst` | VCD 通用；FST 体积更小（需确认 Verdi 版本） |
| `TRACE_DEPTH` | `0`（默认，整个层次） | 层次太深时可用 1–2 减小体积 |
| 范围 | **单 case 单开** | 不要对整个回归开 |

**体积参考**（`rv64ui-p-add`，8950 拍）：VCD **14 MB**。
粗略估算：**每 1000 拍 ≈ 1.6 MB**。374 条全开 ≈ 5 GB，因此**严禁批量开**。

```bash
TRACE=1 tools/verilator_cosim.sh build --dut-kind rtl_full --tag wave_<case>
TRACE=1 tools/verilator_cosim.sh run --no-build --dut-kind rtl_full --tag wave_<case> \
  --verbosity 2 --tc $ISA_MODEL_ROOT/isa_case/<dir>/<case>.riscv
```

> `TRACE` 是**构建期**选项：build 与 run 必须用同一个 `TRACE`。

---

## 4. AI 能"读"的三种波形形态

AI 不能直接解析二进制波形，取证时必须产出下面三种形态之一或全部：

| 形态 | 生成方式 | AI 能得出的结论 |
| --- | --- | --- |
| **① log 行** | `sim.log` / `isa_commit.log` | 失配点位（已有） |
| **② VCD 文本统计** | `awk` / 小脚本（见 §5） | "某值是否出现过""首次异常时刻""取值分布"——**可判定结论** |
| **③ 波形截图** | Verdi 缩放到关键拍、只保留相关信号后截图 | 时序关系、握手、非法编码（多模态读图） |

> ② 的可靠性高于 ③：截图受分辨率与缩放影响，而 ② 是穷举。

### 常用文本查询（可直接复制）

```bash
VCD=sim/verilator_<tag>/log/rtl_full/<case>_1/<case>.vcd

# 某信号出现过哪些值（直方图）
awk '/\$var/ && $5=="rtl_fe_valid"{id=$4} /^b/ && $2==id{print $1}' "$VCD" | sort | uniq -c | sort -rn

# 某信号的全部变化时刻
awk '/\$var/ && $5=="rtl_fe_valid"{id=$4} /^#/{t=$1} /^b/ && $2==id{print t, $1}' "$VCD" | head

# 波形终点（应与 sim.log 的 EXIT 时间戳一致）
grep '^#' "$VCD" | tail -1
grep -a 'model requested exit' sim/verilator_<tag>/log/rtl_full/<case>_1/sim.log
```

---

## 5. 标准取证流程（6 步）

```text
① 复现      单 case + TRACE=1 跑一次（不进回归门禁）
② 定位拍号  从 sim.log 取首个失配的 cycle / seq / rob
③ 圈时间窗  Verdi 跳到该 cycle，前后各留 20~50 拍
④ 选信号    按"数据通路 + 控制信号"两组各取 5~10 个（见 §6）
⑤ 提假设    写成可证伪的一句话，例如：
             "cycle=417 时 x10 的写回数据由 G0 在 cycle=415 产生，值为 A；应为 B"
⑥ 验证      用 ② 的文本统计或 ③ 的截图证实/否证；否证则回 ④
```

**规则**：先验证假设，再改 RTL。禁止"看到失配就改代码试"。

---

## 6. 信号速查

| 用途 | 信号（`ob_cosim_if` / TB 顶层） |
| --- | --- |
| 提交事件 | `commit_valid`、`commit_pc`、`commit_rob_idx`、`commit_result`、`commit_rd_idx`、`commit_rd_write_enable` |
| 异常 / 恢复 | `commit_exception_valid/cause/tval`、`commit_redirect_valid/kind/pc`、`recovery_*`、`flush_*` |
| 架构状态 | `int_arf`、`fp_arf`、`csr_state_*` |
| 前端 | `rtl_fe_valid`、`rtl_fe_instr_pld[0]`、`fe2be_inst_exp[0]`、`rtl_redirect_*` |
| 执行 / 写回 | `fu_after_valid`、`fu_after_tag`、`fu_after_result`、`fu_after_mispredict`、`fu_after_exception` |
| LSU | `be_lsu_issue_valid/pld`、`lsu_be_done_valid/pld`、`lsu_be_exception_valid/pld` |
| CSR | `csr_in_*`、`csr_out_*`、`csr_state_*` |

> 完整字段表见 `../Observation/Observation_level_1.md` 与 `Observation_level_2.md`。
> 注意：Verilator 导出的层次名可能是 `be_tb_pkg::xxx__Vclpkg`，建议用**信号名搜索**而不是逐层展开。

---

## 7. 证据包格式

每次定位到根因，必须留下最小证据包（放 `work/wave_evidence/<case>_<cycle>/`）：

```text
<case>_<cycle>/
├── window.vcd        失配窗口的波形片段（Verdi 截取，务必 < 50 MB）
├── signals.rc        Verdi 信号列表（下次 File → Restore Signal File 复用）
├── screenshot.png    关键拍截图（标注拍照号与关键信号）
├── analysis.md       AI 的假设 → 证据 → 结论 → 修改点
└── before_after.md   修复前后同 cycle 的取值对比
```

`analysis.md` 最少包含：**失配点位、第一个可疑模块、假设、证实/否证的证据、结论**。

---

## 8. Verdi 使用要点（内网）

| 事项 | 做法 |
| --- | --- |
| 启动（脚本 shebang 是 `/bin/sh`=dash） | **必须 `bash` 显式调用**：`bash $VERDI_BIN/verdi -ssf x.fsdb &` |
| VCD → FSDB | `bash $VERDI_BIN/vcd2fsdb x.vcd -o x.fsdb`（14 MB → 约 1 MB） |
| 加信号 | `Signal → Get Signals`；**Scope 要选 `be_tb_top`**，Signal 过滤要用通配符（如 `*fe_valid*`） |
| 跳时间 | 波形窗口 `View → Go To Time`（单位 ps，`8950000` = 8950 ns） |
| 保存信号列表 | `File → Save Signal File`，下次 `Restore` |
| 忽略的告警 | `novas.rc` 打不开、`Import Design` 弹窗可 **Cancel**（我们只有波形，没有设计库） |

---

## 9. 反模式（不要做）

| 反模式 | 后果 |
| --- | --- |
| 对整个回归开 `TRACE=1` | 几十 GB，磁盘打满，且绝大多数波形没人看 |
| 不改 `TRACE` 只改 run | 波形不会生成（`--trace` 是构建期选项） |
| 用肉眼看"某值没出现过" | 不可靠；用 §4 的文本统计穷举 |
| 不加 `WAVE_DEPTH` 分析就 dump 全层次 | 文件过大；层次深时先限深度 |
| 截图不带拍号与信号名 | 下次无法复现 |
| 先改 RTL 再看波形 | 无法区分"修好了"和"改巧了" |

---

## 10. 与"打印"的分工

| 需求 | 用打印 | 用波形 |
| --- | --- | --- |
| 批量判定 PASS/FAIL | ✅ `REPORTER_SUMMARY` / `_EQUIV mismatch` | ❌ |
| 每拍/每指令的常规追踪 | ✅ `VERBOSITY=2/3` | 可选 |
| 失配细节（Level-2） | ✅ `COSIM_LEVEL=2` 自动 dump | 可选 |
| 失配**前**的状态、跨模块同拍对齐、时序关系 | ❌ | ✅ **只能用波形** |

> 三者是互补关系：`VERBOSITY` 管"打多少"，`COSIM_LEVEL` 管"采多深"，波形管"看得多细"。
> 命名区分见 `../workflow/print_leveling_investigation.md`。
