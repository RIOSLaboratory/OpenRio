# INT Two-Operands Ready-Source Dependency Timing Diagrams

Source caselist: `../caselists/INT_two_operands_dependency_caselist.md`

Generated under L5 reader-facing rules. P1 cases above show new ISQ payload construction; P2 cases below show resident-entry FU-input MUX forwarding. P1 source-resolution is normalized to T6 in the legacy figures, while P2 resident-entry source-ready is normalized to T8 in the appended figures.

## Case 1: INT2_G1P3_G0P3

**维度:** INT two-operand ready-source composition · **Equiv:** G1 P3 Bypass + G0 P3 Bypass
**描述:** Dependent captures rs1 from G1 Bypass and rs2 from G0 Bypass in the same source-ready cycle.

| 指令 | T1 | T2 | T3 | T4 | T5 | T6 | T7 | T8 | T9 |
|:---|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|
| `mul x6, x3, x4` · P3 source·G1 | IB | RS1 | SL (MUL stg0) | MUL stg1 | MUL stg2 | WB | C |  |  |
| `add x5, x1, x2` · P3 source·G0 |  |  | IB | RS0 | SL (ALU0) | WB | C |  |  |
| `add x20, x6, x5` · Dependent·G0 |  |  |  |  | IB | RS0 | SL (ALU0) | WB | C |

- **T6 (Source composition)**: dependent P1 resolves rs1 as `G1 P3 Bypass` and rs2 as `G0 P3 Bypass` in one source-resolution cycle.
- **T6 (P3 capture)**: every P3 source uses exact-tag Bypass capture into the new `RS0` payload; the dependent issues at T7, not in the capture cycle.

## Case 2: INT2_G3P3_G0P3

**维度:** INT two-operand ready-source composition · **Equiv:** G3 Load P3 Bypass + G0 P3 Bypass
**描述:** Dependent captures rs1 from G3 load Bypass and rs2 from G0 Bypass.

| 指令 | T1 | T2 | T3 | T4 | T5 | T6 | T7 | T8 | T9 |
|:---|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|
| `ld x7, 0(x8)` · P3 source·G3 |  | IB | RS3 | SL (AGU) | L1D | WB | C |  |  |
| `add x5, x1, x2` · P3 source·G0 |  |  | IB | RS0 | SL (ALU0) | WB | C |  |  |
| `add x20, x7, x5` · Dependent·G0 |  |  |  |  | IB | RS0 | SL (ALU0) | WB | C |

- **T6 (Source composition)**: dependent P1 resolves rs1 as `G3 Load P3 Bypass` and rs2 as `G0 P3 Bypass` in one source-resolution cycle.
- **T6 (P3 capture)**: every P3 source uses exact-tag Bypass capture into the new `RS0` payload; the dependent issues at T7, not in the capture cycle.

## Case 3: INT2_P4_G0P3

**维度:** INT two-operand ready-source composition · **Equiv:** P4 Commit + G0 P3 Bypass
**描述:** P1 source resolution uses Commit CDB for rs1 and G0 Bypass for rs2.

| 指令 | T1 | T2 | T3 | T4 | T5 | T6 | T7 | T8 | T9 |
|:---|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|
| `add x6, x3, x4` · P4 source·G0 |  | IB | RS0 | SL (ALU0) | WB | C |  |  |  |
| `add x5, x1, x2` · P3 source·G0 |  |  | IB | RS0 | SL (ALU0) | WB | C |  |  |
| `add x20, x6, x5` · Dependent·G0 |  |  |  |  | IB | RS0 | SL (ALU0) | WB | C |

- **T6 (Source composition)**: dependent P1 resolves rs1 as `P4 Commit` and rs2 as `G0 P3 Bypass` in one source-resolution cycle.
- **T6 (P3 capture)**: every P3 source uses exact-tag Bypass capture into the new `RS0` payload; the dependent issues at T7, not in the capture cycle.
- **T6 (P4 capture)**: every P4 source uses exact-tag Commit CDB capture and suppresses Condition A for that source.

## Case 4: INT2_ARF_G0P3

**维度:** INT two-operand ready-source composition · **Equiv:** Already in ARF + G0 P3 Bypass
**描述:** rs1 reads ARF; rs2 captures G0 Bypass.

| 指令 | T1 | T2 | T3 | T4 | T5 | T6 | T7 | T8 | T9 |
|:---|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|
| `add x10, x1, x2` · ARF source·G0 | IB | RS0 | SL (ALU0) | WB | C |  |  |  |  |
| `add x5, x3, x4` · P3 source·G0 |  |  | IB | RS0 | SL (ALU0) | WB | C |  |  |
| `add x20, x10, x5` · Dependent·G0 |  |  |  |  | IB | RS0 | SL (ALU0) | WB | C |

- **T6 (Source composition)**: dependent P1 resolves rs1 as `Already in ARF` and rs2 as `G0 P3 Bypass` in one source-resolution cycle.
- **T6 (P3 capture)**: every P3 source uses exact-tag Bypass capture into the new `RS0` payload; the dependent issues at T7, not in the capture cycle.
- **T6 (ARF source)**: the ARF source has already committed before dependent P1, so `DST_REG` is not busy for that operand.

## Case 5: INT2_G0P3_IMM

**维度:** INT two-operand ready-source composition · **Equiv:** G0 P3 Bypass + IMM
**描述:** rs1 captures G0 Bypass; rs2 is immediate and has no dependency tag.

| 指令 | T1 | T2 | T3 | T4 | T5 | T6 | T7 | T8 | T9 |
|:---|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|
| `add x5, x1, x2` · P3 source·G0 |  |  | IB | RS0 | SL (ALU0) | WB | C |  |  |
| `addi x20, x5, 16` · Dependent·G0 |  |  |  |  | IB | RS0 | SL (ALU0) | WB | C |

- **T6 (Source composition)**: dependent P1 resolves rs1 as `G0 P3 Bypass` and rs2 as `IMM` in one source-resolution cycle.
- **T6 (P3 capture)**: every P3 source uses exact-tag Bypass capture into the new `RS0` payload; the dependent issues at T7, not in the capture cycle.
- **T6 (Immediate source)**: the immediate operand is ready by construction and has no dependency tag.

## Case 6: INT2_G3P3_G1P3

**维度:** INT two-operand ready-source composition · **Equiv:** G3 Load P3 Bypass + G1 P3 Bypass
**描述:** Dependent captures rs1 from G3 load Bypass and rs2 from G1 Bypass.

| 指令 | T1 | T2 | T3 | T4 | T5 | T6 | T7 | T8 | T9 |
|:---|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|
| `ld x7, 0(x8)` · P3 source·G3 |  | IB | RS3 | SL (AGU) | L1D | WB | C |  |  |
| `mul x6, x3, x4` · P3 source·G1 | IB | RS1 | SL (MUL stg0) | MUL stg1 | MUL stg2 | WB | C |  |  |
| `add x20, x7, x6` · Dependent·G0 |  |  |  |  | IB | RS0 | SL (ALU0) | WB | C |

- **T6 (Source composition)**: dependent P1 resolves rs1 as `G3 Load P3 Bypass` and rs2 as `G1 P3 Bypass` in one source-resolution cycle.
- **T6 (P3 capture)**: every P3 source uses exact-tag Bypass capture into the new `RS0` payload; the dependent issues at T7, not in the capture cycle.

## Case 7: INT2_P4_G1P3

**维度:** INT two-operand ready-source composition · **Equiv:** P4 Commit + G1 P3 Bypass
**描述:** P1 source resolution uses Commit CDB for rs1 and G1 Bypass for rs2.

| 指令 | T1 | T2 | T3 | T4 | T5 | T6 | T7 | T8 | T9 |
|:---|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|
| `add x7, x8, x9` · P4 source·G0 |  | IB | RS0 | SL (ALU0) | WB | C |  |  |  |
| `mul x6, x3, x4` · P3 source·G1 | IB | RS1 | SL (MUL stg0) | MUL stg1 | MUL stg2 | WB | C |  |  |
| `add x20, x7, x6` · Dependent·G0 |  |  |  |  | IB | RS0 | SL (ALU0) | WB | C |

- **T6 (Source composition)**: dependent P1 resolves rs1 as `P4 Commit` and rs2 as `G1 P3 Bypass` in one source-resolution cycle.
- **T6 (P3 capture)**: every P3 source uses exact-tag Bypass capture into the new `RS0` payload; the dependent issues at T7, not in the capture cycle.
- **T6 (P4 capture)**: every P4 source uses exact-tag Commit CDB capture and suppresses Condition A for that source.

## Case 8: INT2_ARF_G1P3

**维度:** INT two-operand ready-source composition · **Equiv:** Already in ARF + G1 P3 Bypass
**描述:** rs1 reads ARF; rs2 captures G1 Bypass.

| 指令 | T1 | T2 | T3 | T4 | T5 | T6 | T7 | T8 | T9 |
|:---|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|
| `add x10, x1, x2` · ARF source·G0 | IB | RS0 | SL (ALU0) | WB | C |  |  |  |  |
| `mul x6, x3, x4` · P3 source·G1 | IB | RS1 | SL (MUL stg0) | MUL stg1 | MUL stg2 | WB | C |  |  |
| `add x20, x10, x6` · Dependent·G0 |  |  |  |  | IB | RS0 | SL (ALU0) | WB | C |

- **T6 (Source composition)**: dependent P1 resolves rs1 as `Already in ARF` and rs2 as `G1 P3 Bypass` in one source-resolution cycle.
- **T6 (P3 capture)**: every P3 source uses exact-tag Bypass capture into the new `RS0` payload; the dependent issues at T7, not in the capture cycle.
- **T6 (ARF source)**: the ARF source has already committed before dependent P1, so `DST_REG` is not busy for that operand.

## Case 9: INT2_G1P3_IMM

**维度:** INT two-operand ready-source composition · **Equiv:** G1 P3 Bypass + IMM
**描述:** rs1 captures G1 Bypass; rs2 is immediate and has no dependency tag.

| 指令 | T1 | T2 | T3 | T4 | T5 | T6 | T7 | T8 | T9 |
|:---|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|
| `mul x6, x3, x4` · P3 source·G1 | IB | RS1 | SL (MUL stg0) | MUL stg1 | MUL stg2 | WB | C |  |  |
| `addi x20, x6, 16` · Dependent·G0 |  |  |  |  | IB | RS0 | SL (ALU0) | WB | C |

- **T6 (Source composition)**: dependent P1 resolves rs1 as `G1 P3 Bypass` and rs2 as `IMM` in one source-resolution cycle.
- **T6 (P3 capture)**: every P3 source uses exact-tag Bypass capture into the new `RS0` payload; the dependent issues at T7, not in the capture cycle.
- **T6 (Immediate source)**: the immediate operand is ready by construction and has no dependency tag.

## Case 10: INT2_P4_G3P3

**维度:** INT two-operand ready-source composition · **Equiv:** P4 Commit + G3 Load P3 Bypass
**描述:** P1 source resolution uses Commit CDB for rs1 and G3 load Bypass for rs2.

| 指令 | T1 | T2 | T3 | T4 | T5 | T6 | T7 | T8 | T9 |
|:---|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|
| `add x7, x8, x9` · P4 source·G0 |  | IB | RS0 | SL (ALU0) | WB | C |  |  |  |
| `ld x6, 0(x10)` · P3 source·G3 |  | IB | RS3 | SL (AGU) | L1D | WB | C |  |  |
| `add x20, x7, x6` · Dependent·G0 |  |  |  |  | IB | RS0 | SL (ALU0) | WB | C |

- **T6 (Source composition)**: dependent P1 resolves rs1 as `P4 Commit` and rs2 as `G3 Load P3 Bypass` in one source-resolution cycle.
- **T6 (P3 capture)**: every P3 source uses exact-tag Bypass capture into the new `RS0` payload; the dependent issues at T7, not in the capture cycle.
- **T6 (P4 capture)**: every P4 source uses exact-tag Commit CDB capture and suppresses Condition A for that source.

## Case 11: INT2_ARF_G3P3

**维度:** INT two-operand ready-source composition · **Equiv:** Already in ARF + G3 Load P3 Bypass
**描述:** rs1 reads ARF; rs2 captures G3 load Bypass.

| 指令 | T1 | T2 | T3 | T4 | T5 | T6 | T7 | T8 | T9 |
|:---|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|
| `add x11, x1, x2` · ARF source·G0 | IB | RS0 | SL (ALU0) | WB | C |  |  |  |  |
| `ld x6, 0(x10)` · P3 source·G3 |  | IB | RS3 | SL (AGU) | L1D | WB | C |  |  |
| `add x20, x11, x6` · Dependent·G0 |  |  |  |  | IB | RS0 | SL (ALU0) | WB | C |

- **T6 (Source composition)**: dependent P1 resolves rs1 as `Already in ARF` and rs2 as `G3 Load P3 Bypass` in one source-resolution cycle.
- **T6 (P3 capture)**: every P3 source uses exact-tag Bypass capture into the new `RS0` payload; the dependent issues at T7, not in the capture cycle.
- **T6 (ARF source)**: the ARF source has already committed before dependent P1, so `DST_REG` is not busy for that operand.

## Case 12: INT2_G3P3_IMM

**维度:** INT two-operand ready-source composition · **Equiv:** G3 Load P3 Bypass + IMM
**描述:** rs1 captures G3 load Bypass; rs2 is immediate and has no dependency tag.

| 指令 | T1 | T2 | T3 | T4 | T5 | T6 | T7 | T8 | T9 |
|:---|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|
| `ld x6, 0(x10)` · P3 source·G3 |  | IB | RS3 | SL (AGU) | L1D | WB | C |  |  |
| `addi x20, x6, 16` · Dependent·G0 |  |  |  |  | IB | RS0 | SL (ALU0) | WB | C |

- **T6 (Source composition)**: dependent P1 resolves rs1 as `G3 Load P3 Bypass` and rs2 as `IMM` in one source-resolution cycle.
- **T6 (P3 capture)**: every P3 source uses exact-tag Bypass capture into the new `RS0` payload; the dependent issues at T7, not in the capture cycle.
- **T6 (Immediate source)**: the immediate operand is ready by construction and has no dependency tag.

## Case 13: INT2_P4_P4

**维度:** INT two-operand ready-source composition · **Equiv:** P4 Commit + P4 Commit
**描述:** P1 source resolution captures both operands from the two Commit CDB lanes.

| 指令 | T1 | T2 | T3 | T4 | T5 | T6 | T7 | T8 | T9 |
|:---|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|
| `add x5, x1, x2` · P4 source·G0 |  | IB | RS0 | SL (ALU0) | WB | C |  |  |  |
| `add x6, x3, x4` · P4 source·G1 |  | IB | RS1 | SL (ALU1) | WB | C |  |  |  |
| `add x20, x5, x6` · Dependent·G0 |  |  |  |  | IB | RS0 | SL (ALU0) | WB | C |

- **T6 (Source composition)**: dependent P1 resolves rs1 as `P4 Commit` and rs2 as `P4 Commit` in one source-resolution cycle.
- **T6 (P4 capture)**: every P4 source uses exact-tag Commit CDB capture and suppresses Condition A for that source.

## Case 14: INT2_ARF_P4

**维度:** INT two-operand ready-source composition · **Equiv:** Already in ARF + P4 Commit
**描述:** rs1 reads ARF; rs2 captures Commit CDB.

| 指令 | T1 | T2 | T3 | T4 | T5 | T6 | T7 | T8 | T9 |
|:---|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|
| `add x10, x1, x2` · ARF source·G0 | IB | RS0 | SL (ALU0) | WB | C |  |  |  |  |
| `add x6, x3, x4` · P4 source·G0 |  | IB | RS0 | SL (ALU0) | WB | C |  |  |  |
| `add x20, x10, x6` · Dependent·G0 |  |  |  |  | IB | RS0 | SL (ALU0) | WB | C |

- **T6 (Source composition)**: dependent P1 resolves rs1 as `Already in ARF` and rs2 as `P4 Commit` in one source-resolution cycle.
- **T6 (P4 capture)**: every P4 source uses exact-tag Commit CDB capture and suppresses Condition A for that source.
- **T6 (ARF source)**: the ARF source has already committed before dependent P1, so `DST_REG` is not busy for that operand.

## Case 15: INT2_P4_IMM

**维度:** INT two-operand ready-source composition · **Equiv:** P4 Commit + IMM
**描述:** rs1 captures Commit CDB; rs2 is immediate and has no dependency tag.

| 指令 | T1 | T2 | T3 | T4 | T5 | T6 | T7 | T8 | T9 |
|:---|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|
| `add x5, x1, x2` · P4 source·G0 |  | IB | RS0 | SL (ALU0) | WB | C |  |  |  |
| `addi x20, x5, 16` · Dependent·G0 |  |  |  |  | IB | RS0 | SL (ALU0) | WB | C |

- **T6 (Source composition)**: dependent P1 resolves rs1 as `P4 Commit` and rs2 as `IMM` in one source-resolution cycle.
- **T6 (P4 capture)**: every P4 source uses exact-tag Commit CDB capture and suppresses Condition A for that source.
- **T6 (Immediate source)**: the immediate operand is ready by construction and has no dependency tag.

## Case 16: INT2_ARF_ARF

**维度:** INT two-operand ready-source composition · **Equiv:** Already in ARF + Already in ARF
**描述:** Both operands read ARF at P1; no bypass or commit overlay is needed.

| 指令 | T1 | T2 | T3 | T4 | T5 | T6 | T7 | T8 | T9 |
|:---|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|
| `add x10, x1, x2` · ARF source·G0 | IB | RS0 | SL (ALU0) | WB | C |  |  |  |  |
| `add x11, x3, x4` · ARF source·G1 | IB | RS1 | SL (ALU1) | WB | C |  |  |  |  |
| `add x20, x10, x11` · Dependent·G0 |  |  |  |  | IB | RS0 | SL (ALU0) | WB | C |

- **T6 (Source composition)**: dependent P1 resolves rs1 as `Already in ARF` and rs2 as `Already in ARF` in one source-resolution cycle.
- **T6 (ARF source)**: the ARF source has already committed before dependent P1, so `DST_REG` is not busy for that operand.

## Case 17: INT2_ARF_IMM

**维度:** INT two-operand ready-source composition · **Equiv:** Already in ARF + IMM
**描述:** rs1 reads ARF; rs2 is immediate and has no dependency tag.

| 指令 | T1 | T2 | T3 | T4 | T5 | T6 | T7 | T8 | T9 |
|:---|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|
| `add x10, x1, x2` · ARF source·G0 | IB | RS0 | SL (ALU0) | WB | C |  |  |  |  |
| `addi x20, x10, 16` · Dependent·G0 |  |  |  |  | IB | RS0 | SL (ALU0) | WB | C |

- **T6 (Source composition)**: dependent P1 resolves rs1 as `Already in ARF` and rs2 as `IMM` in one source-resolution cycle.
- **T6 (ARF source)**: the ARF source has already committed before dependent P1, so `DST_REG` is not busy for that operand.
- **T6 (Immediate source)**: the immediate operand is ready by construction and has no dependency tag.

## P2 MUX Resident-Entry Cases

These cases complement the P1 MUX figures above. The dependent instruction is already resident in ISQ; T8 is the observed P2 FU-input MUX cycle where current P3 forwarding and/or stored `entry.rs_data` make the operands usable. `P4 Commit CDB` is not a P2 MUX source. Immediate operands are already carried in the resident payload and are covered by `Stored Ready in ISQ`.

## Case 18: INT2_P2_G1P3_G0P3

**Dimension:** INT two-operand ready-source composition | **Equiv:** P2 MUX: G1 P3 Bypass + G0 P3 Bypass
**Description:** P2 FU-input mux selects rs1 from G1 Bypass and rs2 from G0 Bypass; the resident entry can issue in that cycle if the selected FU is free.

| Instruction | T1 | T2 | T3 | T4 | T5 | T6 | T7 | T8 | T9 | T10 |
|:---|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|
| `mul x6, x3, x4` - G1 P3 Bypass |  |  | IB | RS1 | SL (MUL stg0) | MUL stg1 | MUL stg2 | WB | C |  |
| `add x5, x1, x2` - G0 P3 Bypass |  |  |  |  | IB | RS0 | SL (ALU0) | WB | C |  |
| `add x20, x6, x5` - Dependent-G0 |  |  |  |  | IB | RS0 | ISQ Wait | SL (ALU0) | WB | C |

- **T6 (Resident entry):** the dependent has already dispatched into its group-local ISQ and carries stored ready data and/or `wait_tag`s.
- **T8 (P2 MUX source-ready):** current P3 forwarding sources use exact-tag resident-entry matching; stored sources come from already valid `entry.rs_data`.
- **T8 (Issue rule):** if the selected FU is free, the resident entry issues through the P2 FU-input MUX in this cycle; otherwise matched forwarding data is latched and becomes `Stored Ready in ISQ` for retry.

## Case 19: INT2_P2_G3P3_G0P3

**Dimension:** INT two-operand ready-source composition | **Equiv:** P2 MUX: G3 Load P3 Bypass + G0 P3 Bypass
**Description:** P2 mux selects rs1 from G3 load Bypass and rs2 from G0 Bypass.

| Instruction | T1 | T2 | T3 | T4 | T5 | T6 | T7 | T8 | T9 | T10 |
|:---|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|
| `ld x7, 0(x8)` - G3 Load P3 Bypass |  |  |  | IB | RS3 | SL (AGU) | L1D | WB | C |  |
| `add x5, x1, x2` - G0 P3 Bypass |  |  |  |  | IB | RS0 | SL (ALU0) | WB | C |  |
| `add x20, x7, x5` - Dependent-G0 |  |  |  |  | IB | RS0 | ISQ Wait | SL (ALU0) | WB | C |

- **T6 (Resident entry):** the dependent has already dispatched into its group-local ISQ and carries stored ready data and/or `wait_tag`s.
- **T8 (P2 MUX source-ready):** current P3 forwarding sources use exact-tag resident-entry matching; stored sources come from already valid `entry.rs_data`.
- **T8 (Issue rule):** if the selected FU is free, the resident entry issues through the P2 FU-input MUX in this cycle; otherwise matched forwarding data is latched and becomes `Stored Ready in ISQ` for retry.

## Case 20: INT2_P2_STORED_G0P3

**Dimension:** INT two-operand ready-source composition | **Equiv:** P2 MUX: Stored Ready in ISQ + G0 P3 Bypass
**Description:** P2 mux uses stored `entry.rs1_data` and current G0 Bypass data.

| Instruction | T1 | T2 | T3 | T4 | T5 | T6 | T7 | T8 | T9 | T10 |
|:---|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|
| `add x10, x1, x2` - Stored Ready in ISQ | IB | RS0 | SL (ALU0) | WB | C |  |  |  |  |  |
| `add x5, x3, x4` - G0 P3 Bypass |  |  |  |  | IB | RS0 | SL (ALU0) | WB | C |  |
| `add x20, x10, x5` - Dependent-G0 |  |  |  |  | IB | RS0 | ISQ Wait | SL (ALU0) | WB | C |

- **T6 (Resident entry):** the dependent has already dispatched into its group-local ISQ and carries stored ready data and/or `wait_tag`s.
- **T8 (P2 MUX source-ready):** current P3 forwarding sources use exact-tag resident-entry matching; stored sources come from already valid `entry.rs_data`.
- **T8 (Issue rule):** if the selected FU is free, the resident entry issues through the P2 FU-input MUX in this cycle; otherwise matched forwarding data is latched and becomes `Stored Ready in ISQ` for retry.

## Case 21: INT2_P2_G3P3_G1P3

**Dimension:** INT two-operand ready-source composition | **Equiv:** P2 MUX: G3 Load P3 Bypass + G1 P3 Bypass
**Description:** P2 mux selects rs1 from G3 load Bypass and rs2 from G1 Bypass.

| Instruction | T1 | T2 | T3 | T4 | T5 | T6 | T7 | T8 | T9 | T10 |
|:---|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|
| `ld x7, 0(x8)` - G3 Load P3 Bypass |  |  |  | IB | RS3 | SL (AGU) | L1D | WB | C |  |
| `mul x6, x3, x4` - G1 P3 Bypass |  |  | IB | RS1 | SL (MUL stg0) | MUL stg1 | MUL stg2 | WB | C |  |
| `add x20, x7, x6` - Dependent-G0 |  |  |  |  | IB | RS0 | ISQ Wait | SL (ALU0) | WB | C |

- **T6 (Resident entry):** the dependent has already dispatched into its group-local ISQ and carries stored ready data and/or `wait_tag`s.
- **T8 (P2 MUX source-ready):** current P3 forwarding sources use exact-tag resident-entry matching; stored sources come from already valid `entry.rs_data`.
- **T8 (Issue rule):** if the selected FU is free, the resident entry issues through the P2 FU-input MUX in this cycle; otherwise matched forwarding data is latched and becomes `Stored Ready in ISQ` for retry.

## Case 22: INT2_P2_STORED_G1P3

**Dimension:** INT two-operand ready-source composition | **Equiv:** P2 MUX: Stored Ready in ISQ + G1 P3 Bypass
**Description:** P2 mux uses stored `entry.rs1_data` and current G1 Bypass data.

| Instruction | T1 | T2 | T3 | T4 | T5 | T6 | T7 | T8 | T9 | T10 |
|:---|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|
| `add x10, x1, x2` - Stored Ready in ISQ | IB | RS0 | SL (ALU0) | WB | C |  |  |  |  |  |
| `mul x6, x3, x4` - G1 P3 Bypass |  |  | IB | RS1 | SL (MUL stg0) | MUL stg1 | MUL stg2 | WB | C |  |
| `add x20, x10, x6` - Dependent-G0 |  |  |  |  | IB | RS0 | ISQ Wait | SL (ALU0) | WB | C |

- **T6 (Resident entry):** the dependent has already dispatched into its group-local ISQ and carries stored ready data and/or `wait_tag`s.
- **T8 (P2 MUX source-ready):** current P3 forwarding sources use exact-tag resident-entry matching; stored sources come from already valid `entry.rs_data`.
- **T8 (Issue rule):** if the selected FU is free, the resident entry issues through the P2 FU-input MUX in this cycle; otherwise matched forwarding data is latched and becomes `Stored Ready in ISQ` for retry.

## Case 23: INT2_P2_STORED_G3P3

**Dimension:** INT two-operand ready-source composition | **Equiv:** P2 MUX: Stored Ready in ISQ + G3 Load P3 Bypass
**Description:** P2 mux uses stored `entry.rs1_data` and current G3 load Bypass data.

| Instruction | T1 | T2 | T3 | T4 | T5 | T6 | T7 | T8 | T9 | T10 |
|:---|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|
| `add x11, x1, x2` - Stored Ready in ISQ | IB | RS0 | SL (ALU0) | WB | C |  |  |  |  |  |
| `ld x6, 0(x10)` - G3 Load P3 Bypass |  |  |  | IB | RS3 | SL (AGU) | L1D | WB | C |  |
| `add x20, x11, x6` - Dependent-G0 |  |  |  |  | IB | RS0 | ISQ Wait | SL (ALU0) | WB | C |

- **T6 (Resident entry):** the dependent has already dispatched into its group-local ISQ and carries stored ready data and/or `wait_tag`s.
- **T8 (P2 MUX source-ready):** current P3 forwarding sources use exact-tag resident-entry matching; stored sources come from already valid `entry.rs_data`.
- **T8 (Issue rule):** if the selected FU is free, the resident entry issues through the P2 FU-input MUX in this cycle; otherwise matched forwarding data is latched and becomes `Stored Ready in ISQ` for retry.

## Case 24: INT2_P2_STORED_STORED

**Dimension:** INT two-operand ready-source composition | **Equiv:** P2 MUX: Stored Ready in ISQ + Stored Ready in ISQ
**Description:** P2 mux selects both operands from stored `entry.rs_data`; no current-cycle forwarding is needed.

| Instruction | T1 | T2 | T3 | T4 | T5 | T6 | T7 | T8 | T9 | T10 |
|:---|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|
| `add x10, x1, x2` - Stored Ready in ISQ | IB | RS0 | SL (ALU0) | WB | C |  |  |  |  |  |
| `add x11, x3, x4` - Stored Ready in ISQ | IB | RS0 | SL (ALU0) | WB | C |  |  |  |  |  |
| `add x20, x10, x11` - Dependent-G0 |  |  |  |  | IB | RS0 | ISQ Wait | SL (ALU0) | WB | C |

- **T6 (Resident entry):** the dependent has already dispatched into its group-local ISQ and carries stored ready data and/or `wait_tag`s.
- **T8 (P2 MUX source-ready):** both operands come from already valid `entry.rs_data`; no current-cycle forwarding source is required.
- **T8 (Issue rule):** if the selected FU is free, the resident entry issues through the P2 FU-input MUX in this cycle; otherwise matched forwarding data is latched and becomes `Stored Ready in ISQ` for retry.

## Supplemental Same-RD Fanout Cases

These cases cover the legal shape behind the gray same-P3-source diagonal cells. The gray cells exclude two different producers on one P3 bypass lane; they do not exclude one producer payload feeding both rs1 and rs2.

## Case 25: INT2_SAME_RD_P1_G0P3_RS1_RS2

**Dimension:** INT same-RD fanout | **Equiv:** P1 MUX: G0 P3 Bypass feeds rs1 and rs2
**Description:** A single G0 producer tag matches both register sources during dependent P1 source resolution.

| Instruction | T1 | T2 | T3 | T4 | T5 | T6 | T7 | T8 | T9 |
|:---|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|
| `add x5, x1, x2` - Producer-G0 |  |  | IB | RS0 | SL (ALU0) | WB | C |  |  |
| `add x20, x5, x5` - Dependent-G0 |  |  |  |  | IB | RS0 | SL (ALU0) | WB | C |

- **T6 (P1 same-tag match):** rs1 and rs2 both match the same producer tag on G0 P3 Bypass.
- **T6 (Payload construction):** one forwarded payload is written into both operand data fields of the new ISQ entry.
- **T7 (Issue):** dependent issues after the ready payload is constructed.

## Case 26: INT2_SAME_RD_P1_G1P3_RS1_RS2

**Dimension:** INT same-RD fanout | **Equiv:** P1 MUX: G1 P3 Bypass feeds rs1 and rs2
**Description:** A single G1 producer tag matches both register sources during dependent P1 source resolution.

| Instruction | T1 | T2 | T3 | T4 | T5 | T6 | T7 | T8 | T9 |
|:---|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|
| `mul x5, x1, x2` - Producer-G1 | IB | RS1 | SL (MUL stg0) | MUL stg1 | MUL stg2 | WB | C |  |  |
| `add x20, x5, x5` - Dependent-G0 |  |  |  |  | IB | RS0 | SL (ALU0) | WB | C |

- **T6 (P1 same-tag match):** rs1 and rs2 both match the same producer tag on G1 P3 Bypass.
- **T6 (Payload construction):** one forwarded payload is written into both operand data fields of the new ISQ entry.
- **T7 (Issue):** dependent issues after the ready payload is constructed.

## Case 27: INT2_SAME_RD_P1_G3P3_RS1_RS2

**Dimension:** INT same-RD fanout | **Equiv:** P1 MUX: G3 Load P3 Bypass feeds rs1 and rs2
**Description:** A single load producer tag matches both register sources during dependent P1 source resolution.

| Instruction | T1 | T2 | T3 | T4 | T5 | T6 | T7 | T8 | T9 |
|:---|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|
| `ld x5, 0(x1)` - Producer-G3 |  | IB | RS3 | SL (AGU) | L1D | WB | C |  |  |
| `add x20, x5, x5` - Dependent-G0 |  |  |  |  | IB | RS0 | SL (ALU0) | WB | C |

- **T6 (P1 same-tag match):** rs1 and rs2 both match the same producer tag on G3 load P3 Bypass.
- **T6 (Payload construction):** one forwarded payload is written into both operand data fields of the new ISQ entry.
- **T7 (Issue):** dependent issues after the ready payload is constructed.

## Case 28: INT2_SAME_RD_P2_G0P3_RS1_RS2

**Dimension:** INT same-RD fanout | **Equiv:** P2 MUX: G0 P3 Bypass feeds rs1 and rs2
**Description:** A resident dependent entry has both wait tags pointing to the same G0 producer.

| Instruction | T1 | T2 | T3 | T4 | T5 | T6 | T7 | T8 | T9 | T10 |
|:---|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|
| `add x5, x1, x2` - Producer-G0 |  |  |  |  | IB | RS0 | SL (ALU0) | WB | C |  |
| `add x20, x5, x5` - Dependent-G0 |  |  |  |  | IB | RS0 | ISQ Wait | SL (ALU0) | WB | C |

- **T6 (Resident entry):** dependent is already in ISQ with rs1 and rs2 waiting on the same producer tag.
- **T8 (P2 same-tag match):** one G0 Bypass payload satisfies both operand inputs.
- **T8 (Issue):** dependent issues through the FU-input MUX when the selected FU is free.

## Case 29: INT2_SAME_RD_P2_G1P3_RS1_RS2

**Dimension:** INT same-RD fanout | **Equiv:** P2 MUX: G1 P3 Bypass feeds rs1 and rs2
**Description:** A resident dependent entry has both wait tags pointing to the same G1 producer.

| Instruction | T1 | T2 | T3 | T4 | T5 | T6 | T7 | T8 | T9 | T10 |
|:---|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|
| `mul x5, x1, x2` - Producer-G1 |  |  | IB | RS1 | SL (MUL stg0) | MUL stg1 | MUL stg2 | WB | C |  |
| `add x20, x5, x5` - Dependent-G0 |  |  |  |  | IB | RS0 | ISQ Wait | SL (ALU0) | WB | C |

- **T6 (Resident entry):** dependent is already in ISQ with rs1 and rs2 waiting on the same producer tag.
- **T8 (P2 same-tag match):** one G1 Bypass payload satisfies both operand inputs.
- **T8 (Issue):** dependent issues through the FU-input MUX when the selected FU is free.

## Case 30: INT2_SAME_RD_P2_G3P3_RS1_RS2

**Dimension:** INT same-RD fanout | **Equiv:** P2 MUX: G3 Load P3 Bypass feeds rs1 and rs2
**Description:** A resident dependent entry has both wait tags pointing to the same load producer.

| Instruction | T1 | T2 | T3 | T4 | T5 | T6 | T7 | T8 | T9 | T10 |
|:---|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|
| `ld x5, 0(x1)` - Producer-G3 |  |  |  | IB | RS3 | SL (AGU) | L1D | WB | C |  |
| `add x20, x5, x5` - Dependent-G0 |  |  |  |  | IB | RS0 | ISQ Wait | SL (ALU0) | WB | C |

- **T6 (Resident entry):** dependent is already in ISQ with rs1 and rs2 waiting on the same producer tag.
- **T8 (P2 same-tag match):** one G3 load Bypass payload satisfies both operand inputs.
- **T8 (Issue):** dependent issues through the FU-input MUX when the selected FU is free.
