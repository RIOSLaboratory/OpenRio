# 打印分级（verbosity / Level）调查与整改建议

> 状态：**调查完成，实施挂起**（2026-10-20）
> 本文是给后续单独讨论/实施用的交接材料，结论基于当时代码实读。
> 未提交到 git，属工作笔记；确定方案后再落到代码仓库。

---

## 0. 一句话结论

环境里同时存在**三套"level"语义**，彼此**在控制逻辑上正交**，但在**命名和日志内容上重叠** ——
歧义来自用词，不是功能冲突。真正的整改动作是"统一命名 + 明确职责"，
而不是"删掉一套机制"。

---

## 1. 三套 "level" 分别是什么

| # | 名称 | 取值 | 控制什么 | 谁在用 |
| --- | --- | --- | --- | --- |
| A | `VERBOSITY` | 1–3 | **打印**：`level <= verbosity` 的消息才输出 | 人工看日志、`print_tb()` |
| B | `COSIM_LEVEL` | 1–2 | **采集**：是否收集逐指令细粒度观测，并在失配时 dump | COSIM 失配定位 |
| C | debug 流程 Level-1/2 | 1–2 | **调试阶段**：先比 commit 级，不收敛再开 pre-commit 级 | `RTL_debug_flow_and_rule.md` |

C 与 B 是同一个概念（观测深度）的"流程面"，A 与它们完全无关。

---

## 2. 现状 A：`VERBOSITY`

### 实现

- 变量：`tb/env/be_config.sv:13` `int unsigned verbosity;`，默认 `1`（`:31`）
- 解析：`+VERBOSITY=%d`（`be_config.sv:85`）；越界 1–3 直接 `$fatal`（`:113`）
- 过滤：`tb/env/be_reporter.sv` 的 `configure()` / `level_enabled()`
  ```systemverilog
  return enabled && (level <= verbosity);
  ```
- 输出：`reporter.print(level, msg)`；**先计数、再判断是否打印**
  ```systemverilog
  case (level) 1: l1_count++; 2: l2_count++; 3: l3_count++; endcase
  if (level_enabled(level)) $display(...);
  ```
  ⇒ `REPORTER_SUMMARY l1=.. l2=.. l3=..` **永远是全量统计**，与 verbosity 无关。
- 入口封装：`be_config.sv:49` `print_tb(level, message)` → `reporter.print(...)`

### 调用点（全环境只有 12 处）

| 级别 | 位置 | 含义 |
| --- | --- | --- |
| L1 ×6 | `be_config.sv:123/124/130/131`、`cosim_pkg.sv:473`、`cosim_publisher.sv:356` | 配置、里程碑、结论 |
| L2 ×2 | `cosim_agent.sv:54`、`cosim_pkg.sv:119` | 参考模型初始化/退出等"大事件" |
| L3 ×4 | `cosim_pkg.sv:325/417/423/511` | 逐条/逐步细节 |

### 两个额外消费者（易被忽略）

- `tb/agents/be/be_bfm.sv:100-125`：module 拿不到 config class，**自己读 `+VERBOSITY`** 到 `trace_level`（默认 1）
  注释明说：`2 = major events, 3 = per-cycle details`
- `tb/agents/checker/be_checker.sv:46`：同样自己读 `+VERBOSITY`

⇒ verbosity 有 **3 个解析点**（config + bfm + checker），默认值分散。

### 工具侧

- `tools/verilator_cosim.sh`：`VERBOSITY=${VERBOSITY:-3}`，`--verbosity`，转成 `+VERBOSITY=`
- `tools/regress.sh`：批量跑固定 `--verbosity 1`

⚠️ **默认值不一致**：脚本 3，TB config 1。因为脚本总传 plusarg，实际生效的是 3。

---

## 3. 现状 B：`COSIM_LEVEL`

### 实现

- 变量：`be_config.sv:13` 附近 `int unsigned cosim_level;`，默认 `1`
- 解析：`+COSIM_LEVEL=%d`；越界 1–2 `$fatal`
- 门控：`tb/agents/be/be_agent.sv:252`
  ```systemverilog
  function automatic bit level2_enabled();
    return cfg.cosim_enable && (cfg.cosim_level >= 2);
  endfunction
  ```
- 13 个门控点（`be_agent.sv:475/696/775/802/845/969/1033/1064/1133/1184/1235/1343` + 定义）

### 采集与输出策略

- 逐 ROB 暂存：`l2_obs_by_rob` / `l2_cmp_by_rob` / `l2_isq_by_rob` / `l2_wb_by_rob` /
  `l2_decode_by_rob` / `l2_lsu_by_rob` / `l2_csr_in_by_rob` / `l2_lsu_response_by_rob` /
  `l2_any_mismatch_by_rob`
- **只有该 rob 最终失配**，才在 commit/recovery 时由 `emit_level2_lifecycle()` 输出
- 输出走 `reporter.diagnostic()`（`$display`，**不受 verbosity 门控**）
- 例外：`[FE-BE]` 通道**每拍直出**，不进入 per-ROB 生命周期
- 失配传播：`consume_*()` → `l2_any_mismatch_by_rob` → commit/recovery event 的
  `level2_mismatch` → `cosim_pkg` 累积 → cycle-end `[COSIM][LEVEL2_MISMATCH]` fatal

### 规模

- `be_agent.sv` 中 `OBSERVATION ONLY` 载荷共 **15 处**
- 观测面定义见 `docs/Arch/Observation/Observation_level_1.md` / `Observation_level_2.md`

---

## 4. 重叠分析

**功能上不重叠（正交）**：

| | A `VERBOSITY` | B `COSIM_LEVEL` |
| --- | --- | --- |
| 作用对象 | 常规打印 | 观测采集与失配 dump |
| 作用时机 | 常态 | 仅 Level-2 且失配时 |
| 输出通道 | `print()` → 受过滤 | `diagnostic()` → **不受过滤** |

**三处真实交叠**：

1. **命名冲突（最严重）**：三套机制都叫 "Level 1/2(/3)"。日志里 `[L2] [COMMIT]` 是 A，
   `+COSIM_LEVEL=2` 是 B，debug 文档的 "Level 2" 是 C。
2. **日志体积被两个旋钮同时影响，方向相反**：`--verbosity 1` 压不住 Level-2 的 dump；
   `COSIM_LEVEL=1` 也管不了 A 的打印。想"安静地跑"必须同时设两个。
3. **内容部分重复**：A 的 L2 打印（`[COSIM] [COMMIT] cyc= rob= ...`）与 B 的 Level-2
   compare 行（`[COSIM] [COMMIT] rob_idx=...`）描述同一件事，只是通道不同。

---

## 5. 方案与工作量

### 方案一：只改名（推荐作为第一步）

| 改动 | 内容 |
| --- | --- |
| `VERBOSITY` → `PRINT_LEVEL`（或 `LOG_LEVEL`） | 脚本参数、plusarg、help、README |
| `COSIM_LEVEL` → `OBS_DEPTH` | 同上 + TB 字段 |
| 日志前缀 `[L1]/[L2]/[L3]` | 可保留，但文档里明确它属于 `PRINT_LEVEL` |

- **工作量 ≈ 1 小时**，**零行为变化**，风险极低
- 立刻消除"两个 level 是一回事"的误解

### 方案二：合并为单一开关（`COSIM_LEVEL=1|2`，删除 `VERBOSITY`）

语义：

| 值 | 行为 |
| --- | --- |
| 1 | 只打印里程碑/配置/结论 + 失配报告 |
| 2 | 额外采集逐指令观测（失配时 dump），并放开原 L2/L3 常规打印 |

| # | 工作 | 文件 | 估时 |
| --- | --- | --- | --- |
| 1 | 12 处 `print_tb` 重新映射（L3 并入 L2，L1 常开） | `be_config` / `cosim_pkg` / `cosim_agent` / `cosim_publisher` | 30 min |
| 2 | `be_reporter` 去掉 `verbosity`，`level_enabled` 由 config 注入 | `be_reporter.sv` | 30 min |
| 3 | `be_config` 删字段与 `+VERBOSITY` 解析 | `be_config.sv` | 30 min |
| 4 | `be_bfm` / `be_checker` 的 `trace_level` 改读 `+COSIM_LEVEL` | 2 文件 | 20 min |
| 5 | 脚本：`--verbosity` → 新参数（保留旧名别名） | `verilator_cosim.sh` | 20 min |
| 6 | `regress.sh` 更新 | `regress.sh` | 5 min |
| 7 | 文档 | README + `docs/Arch/` | 15 min |
| 8 | 验证：216 回归 + 一次失配注入 | — | 30–60 min |
| | **合计** | | **3–4 小时** |

---

## 6. 推荐路径

1. **先做方案一（改名）**，约 1 小时，零风险；
2. 观察一段时间，确认"level"歧义消失后，再评估是否值得做方案二；
3. 若做方案二，安排在 ST 首轮跑通之后，避免在 debug 关键期动日志基建。

---

## 7. 代码位置速查

```
tb/env/be_config.sv              13/31  verbosity 字段与默认
                                 49     print_tb()
                                 85     +VERBOSITY
                                 113    范围校验
                                 123-131 配置打印（L1）
tb/env/be_reporter.sv            configure() / level_enabled() / print() / diagnostic()
tb/agents/be/be_agent.sv         252    level2_enabled()
                                 189    l2_obs_by_rob 声明
                                 ~1300  emit_level2_lifecycle()
tb/agents/be/be_bfm.sv           100-125 独立读 +VERBOSITY
tb/agents/checker/be_checker.sv  46     独立读 +VERBOSITY
tb/agents/cosim/cosim_agent.sv   54     L2 打印
tb/pkg/cosim_pkg.sv              119    L2；325/417/423/511 L3；473 L1
tb/pkg/cosim_publisher.sv        356    L1
tools/verilator_cosim.sh         VERBOSITY 默认 3 / --verbosity / +VERBOSITY
tools/regress.sh                 固定 --verbosity 1
docs/Arch/workflow/RTL_debug_flow_and_rule.md  §3 Level 1/2 定义（观测深度）
docs/Arch/Observation/Observation_level_{1,2}.md 观测面字段表
```

---

## 8. 验证方法

```bash
# 基线
tools/regress.sh rtl_full base 8                 # 期望 PASS=216 FAIL=0

# 打印行为抽样（改前后对比日志行数）
tools/verilator_cosim.sh run --no-build --dut-kind rtl_full --tag base \
  --verbosity 1 --tc $ISA_MODEL_ROOT/isa_case/rv64ui/rv64ui-p-add.riscv
wc -l sim/verilator_base/log/rtl_full/rv64ui-p-add_1/sim.log

# 失配路径必须仍然能打印（Level-2 dump）
# 用 +SELFCHK_INJECT / +FE_INJECT / +CACHE_INJECT 注入一次错误，确认：
#   1) 仍能看到 [COSIM][LEVEL2_MISMATCH]
#   2) 该 rob 的生命周期日志仍然完整
```

**判定 PASS/FAIL 的脚本只依赖 `REPORTER_SUMMARY` 的 `error=` / `fatal=`**，
不依赖 `l1/l2/l3` 计数 ⇒ 改造对回归判定安全。

---

## 9. 风险清单

| 风险 | 说明 | 处置 |
| --- | --- | --- |
| **`diagnostic()` 被误加过滤** | 失配报告会消失，最难发现 | 加注释锁死；验证时必跑失配注入 |
| Level-2 细节丢失 | 若把 L3 直接删掉 | **并入 L2**，不删 |
| `REPORTER_SUMMARY` 计数语义变化 | 有人可能用 l1/l2/l3 做判据 | 全库确认无人使用（目前判定脚本不用） |
| 默认值不一致（脚本 3 / TB 1） | 改参数时容易漏 | 统一到一处定义 |
| `be_bfm` / `be_checker` 漏改 | 它们独立解析 plusarg | 用 `grep +VERBOSITY` 收尾核对 |

---

## 10. 遗留问题（待新对话确认）

1. 新名字最终定成什么？`PRINT_LEVEL` / `LOG_LEVEL` / `VERBOSE`？
2. 是否保留 `--verbosity` 作为别名（向后兼容内网脚本）？
3. L3 是否真的需要保留独立级别，还是并入 L2 即可？
4. 是否顺手把 `[FE-BE]` 的"每拍直出"也纳入失配门控？（会影响调试习惯）
5. ACT 374 条跑起来后，日志量是否会成为新的痛点（决定要不要提前做方案二）？
