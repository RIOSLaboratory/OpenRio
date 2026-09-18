# LEVEL-1 观测点

Commit 事件是 COSIM 推进 reference、对齐提交顺序、触发架构状态比较的核心时机信号，必须成组抓取。

| 信号/信息                   | 位宽/形态             | 来源                                             | 用途                                                               | 当前核心必抓                          |
| --------------------------- | --------------------- | ------------------------------------------------ | ------------------------------------------------------------------ | ------------------------------------- |
| `commit_valid[0]`         | 1 bit                 | 第 0 组提交通道                                  | 指示第 0 组通道发生有效提交                                        | 是                                    |
| `commit_valid[1]`         | 1 bit                 | 第 1 组提交通道                                  | 指示第 1 组通道发生有效提交                                        | 是                                    |
| `commit_pc[0]`            | 64 bit                | 第 0 组提交通道；RTL 对应`trace_pc[0]`         | 与 reference commit PC 序列对齐                                    | 是                                    |
| `commit_pc[1]`            | 64 bit                | 第 1 组提交通道；RTL 对应`trace_pc[1]`         | 与 reference commit PC 序列对齐                                    | 是                                    |
| `commit_rob_idx[0]`       | ROB index width       | 第 0 组提交通道；RTL 对应`commit_tag[0]`       | 日志定位和提交事件关联                                             | 是                                    |
| `commit_rob_idx[1]`       | ROB index width       | 第 1 组提交通道；RTL 对应`commit_tag[1]`       | 日志定位和提交事件关联                                             | 是                                    |
| `commit_result[0]`        | 64 bit                | 第 0 组提交结果；RTL 对应`commit_data[0]`      | 比较目的寄存器写回值；由`commit_rd_write_enable[0]` 决定是否消费 | 是                                    |
| `commit_result[1]`        | 64 bit                | 第 1 组提交结果；RTL 对应`commit_data[1]`      | 比较目的寄存器写回值；由`commit_rd_write_enable[1]` 决定是否消费 | 是                                    |
| `commit_rd_idx[0]`        | register index width  | 第 0 组提交目的寄存器编号                        | 定位写回目标寄存器                                                 | 是                                    |
| `commit_rd_idx[1]`        | register index width  | 第 1 组提交目的寄存器编号                        | 定位写回目标寄存器                                                 | 是                                    |
| `commit_rd_is_fp[0]`      | 1 bit                 | 第 0 组提交目的寄存器类型                        | 区分 INT/FP 架构寄存器比较                                         | 是                                    |
| `commit_rd_is_fp[1]`      | 1 bit                 | 第 1 组提交目的寄存器类型                        | 区分 INT/FP 架构寄存器比较                                         | 是                                    |
| `commit_fflags[0]`        | fflags width          | 第 0 组提交 FP flags                             | 观察本条 FP 指令对`fflags` 的影响                               | 是，只观察，未实现比较                |
| `commit_fflags[1]`        | fflags width          | 第 1 组提交 FP flags                             | 观察本条 FP 指令对`fflags` 的影响                               | 是，只观察，未实现比较                |
| `mnemonic[0]`             | enum/string           | ISA model 在提交同一`commit_rob_idx[0]` 时给出 | 记录第 0 组提交指令类型，便于分类定位                              | 只从 ISA model 取，只观察，未实现比较 |
| `mnemonic[1]`             | enum/string           | ISA model 在提交同一`commit_rob_idx[1]` 时给出 | 记录第 1 组提交指令类型，便于分类定位                              | 只从 ISA model 取，只观察，未实现比较 |
| `commit_is_compressed[0]` | 1 bit                 | ISA model 或验证侧 ROB shadow entry              | 判断第 0 组指令长度和 next PC                                      | 否                                    |
| `commit_is_compressed[1]` | 1 bit                 | ISA model 或验证侧 ROB shadow entry              | 判断第 1 组指令长度和 next PC                                      | 否                                    |
| `commit_exception_valid`  | 1 bit                 | Commit/recovery 同拍可取得的异常标记             | 区分正常提交和异常提交边界                                         | 是，异常时比较                        |
| `commit_exception_cause`  | exception cause width | Commit/recovery 同拍可取得的异常原因             | 对齐 reference trap cause                                          | 是，异常时比较                        |
| `commit_exception_tval`   | 64 bit                | Commit/recovery 同拍可取得的异常附加值           | 对齐 reference trap tval                                           | 是，异常时比较                        |
| `commit_redirect_valid`   | 1 bit                 | Commit/recovery 同拍 flush 或 redirect 标记      | 记录本拍提交后是否进入恢复流程                                     | 是                                    |
| `commit_recovery_kind`    | enum                  | Commit/recovery 同拍恢复类型                     | 区分 exception、interrupt、MRET、SRET、FENCE.I、mispredict         | 是                                    |
| `commit_redirect_pc`      | 64 bit                | Commit/recovery 同拍 redirect 目标               | 对齐 reference next PC 或前端重定向目标                            | 是                                    |
| `int_arf_snapshot`        | 32 x 64 bit           | Commit 写回后的 INT ARF 稳定快照                 | 架构整数寄存器状态比较                                             | 是                                    |
| `fp_arf_snapshot`         | 32 x 64 bit           | Commit 写回后的 FP ARF 稳定快照                  | 架构浮点寄存器状态比较                                             | 是                                    |

## Commit 或异常事件的比较字段：

- 一定会比较 commit_pc[group]、INT ARF、FP ARF
- commit_valid[group] == 1 && commit_rd_write_enable[group] == 1:

  - 比较 commit_rd_is_fp、commit_rd_idx、commit_result
- commit_exception_valid == 1:

  - 比较 commit_exception_cause、commit_exception_tval
- commit_redirect_valid == 1:

  - 比较 commit_redirect_pc、commit_recovery_kind

