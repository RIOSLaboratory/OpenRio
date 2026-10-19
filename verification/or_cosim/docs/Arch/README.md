# or_cosim 架构与调试文档索引

本目录随验证环境代码一起维护（2026-10-19 从 `openrios/verification/orbe_bt_env/docs/Arch/`
迁入并校正路径）。凡与当前代码不一致之处，以代码和本目录下的观测面文档为准。

## 目录结构

```text
docs/Arch/
├── Observation/
│   ├── Observation_level_1.md      LEVEL-1 观测点（commit 边界 + 架构状态）
│   ├── Observation_level_2.md      LEVEL-2 观测点（流水线内部节点）
│   └── AI_observation_point.md     RTL 侧观测点命名（Level-1/2 的 RTL 名字集）
├── workflow/
│   ├── orbe_ai_cowork_flow.md      AI 协作总流程（6 个阶段）
│   └── RTL_debug_flow_and_rule.md  RTL debug 子流程与规则（草稿）
├── interface/
│   ├── ORBE_FE_AGENT_INTERFACE_SPEC_brief.md  FE↔BE 接口规范（简版）
│   └── BE_LSU接口规范_v4.md                   BE↔LSU 接口规范
├── spec/
│   └── module_v4.md                微架构文档 golden 骨架与规则
├── archive/
│   └── AI_Debug_Workflow.md        早期 AI debug 闭环（归档）
└── RVA23_IMAFDC_Classification.xlsx 指令分类表（debug 时用于定位 ISU Group）
```

## 文档状态

| 文档 | 用途 | 状态 |
| --- | --- | --- |
| `Observation/Observation_level_1.md` | 定义 Level-1 观测面：commit 组、异常、恢复、ARF/CSR 快照 | ✅ 已对照 `ob_cosim_if.sv` 核对（2026-10-19） |
| `Observation/Observation_level_2.md` | 定义 Level-2 观测面：FE-BE / DECODE / ISQ / WRITEBACK / BE-LSU / CSR | ✅ 已对照代码核对（2026-10-19） |
| `Observation/AI_observation_point.md` | RTL 侧命名与抓取清单；§5 的"迁移差距"已过期 | ⚠️ 部分过期（现状以 Level-1/2 两篇为准） |
| `workflow/orbe_ai_cowork_flow.md` | 从 ISA/微架构文档到 RTL、COSIM、debug、交付的总流程 | ✅ 现行 |
| `workflow/RTL_debug_flow_and_rule.md` | Level-1 → Level-2 升级、终止条件、记录与审查规则 | 📝 草稿 |
| `archive/AI_Debug_Workflow.md` | 早期闭环：能打印就打印 / 分 stage 比对 / 先停第一处 mismatch | 🗄 归档 |

## 关键约定

1. **"Level-1 / Level-2" 指观测深度**（`COSIM_LEVEL=1|2`），
   与 `VERBOSITY` 的打印级别 `[L1]/[L2]/[L3]` **不是同一个概念**。
2. Level-2 的日志走 `reporter.diagnostic()`，**不受 `VERBOSITY` 门控**；
   只有 per-ROB 失配时才会 dump。
3. 所有 RTL DUT kind（`rtl_v1` / `rtl_fe` / `rtl_cache` / `rtl_full`）都定义
   `ORBE_DUT_RTL_V1`，因此都产生 Level-2 观测；仅 `agent` 模式不产生。
4. 指向本目录之外（微架构文档树、RTL 生成管线规范）的引用，一律用纯文本标注，
   不写成失效的相对链接。

## 尚未迁入 / 待补

- BE agent 设计与实现文档（原索引标记为"暂无"）
- Cache agent 完整设计文档（原 `docs/Arch/cache_agent/CACHE_AGENT_功能实现.md`，状态 in progress）
- FE agent 系列文档（`fe_agent/ORBE_FE_AGENT_*.md`）
- 接口规范 PDF 原版（`BE_FE接口规范.pdf`、`BE_LSU接口规范.pdf`，体积较大，暂留 `openrios/` 文档树）
