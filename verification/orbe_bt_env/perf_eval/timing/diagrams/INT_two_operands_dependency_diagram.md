# INT Two-Operands Ready-Source Dependency Timing Diagrams

Source caselist: `../caselists/INT_two_operands_dependency_caselist.md`

Generated under L5 reader-facing rules. P1 cases above show new ISQ payload construction; P2 cases below show resident-entry FU-input MUX forwarding. P1 source-resolution is normalized to T6 in the legacy figures, while P2 resident-entry source-ready is normalized to T8 in the appended figures.

## Stage mapping

The pipeline is the five-stage BE model (see `../../../docs/BE/or_be_has_V1.0.md` §5). Every cell in the figures below is one of these:

| Cell | Stage | Meaning |
|---|---|---|
| `IB` | **P0** | The instruction is enqueued into the instruction buffer. This cell marks the enqueue cycle only. |
| `dispatch` | **P1** | The group's ISQ entry is written here. The group is chosen inside `dispatch_logic`, so the cell does not name one — the row label carries the group. The IB head read that forms the dispatch bundle is also a P1 activity. |
| `ISQ Wait` | **P2** | Resident in the ISQ, waiting for a source. |
| FU name (`ALU0`, `ALU1`, `MUL`, `DIV`, `BRU`, `AGU`, `L1D`, `LDA+CDB`) | **P2** | The FU is executing. The first such cell is the cycle the issue is accepted; a multi-cycle FU repeats its name (`MUL MUL MUL`, `DIV DIV DIV`). LOAD is `AGU` → `L1D` → `LDA+CDB`. |
| `WB` | **P3** | Result writeback / bypass broadcast. |
| `C` | **P4** | Commit. |

For a producer of latency `L` whose dispatch is at T2, the producer issues at T3, occupies its FU across T3…T(2+`L`), `WB` at **T(3+`L`)**, `C` at T(4+`L`), and ARF-ready at T(5+`L`). ARF takes one cycle: a commit at `C` is readable at `C`+1.

## Bypass paths, and where they can be consumed

Each bus carries **only** the value published in that cycle; nothing is held. A dependent whose P1 misses the producer's P3 cycle **cannot go back for it**: the next opportunity is the commit CDB, and after that the ARF.

| Bus (valid only in that cycle) | Consumer stage in that cycle | Use | Issues |
|---|---|---|---|
| P3 bypass, 4 lanes | P1 | captured into the new ISQ payload (the entry becomes ready) | next cycle |
| P3 bypass, 4 lanes | P2 (resident) | resident wakeup; feeds the FU input directly | that cycle |
| P4 commit CDB, 2 lanes | P1 | captured into the new ISQ payload | next cycle |
| P4 commit CDB, 2 lanes | P2 | **not connected** | — |
| ARF | P1, after the producer has committed | read from the ARF read ports | next cycle |

That one-cycle window is what the sources in these cases enumerate: the P1 MUX cases place a source in the dependent's P1 cycle, and the P2 MUX cases keep the dependent resident so its P2 falls in that window.

If a resident entry matches a P3 source in P2 but the selected FU cannot issue in that cycle, the matched data is latched at the clock edge and becomes `Stored Ready` for a later cycle — it is not lost.

## Two constraints these figures obey

1. **Same-group dispatch is impossible.** The ISQ holds one entry per group, so two instructions of the same group cannot be dispatched in the same cycle. Where a producer would otherwise have to share its group's dispatch cycle with the dependent, the dependent is routed to the other ALU group and is drawn as `Dependent-G1` / `ALU1`. This is the same routing choice the single-operand `delta_0` rows make.
2. **Same-group P3 lanes.** Two different producers of the same group cannot both publish on that group's P3 bypass lane in one cycle; those K-map cells are the gray `don't exist` cells. Constraints 1 and 2 are distinct: the first is about the dispatch entry in P1, the second about the bypass lane in P3.

## Case 1: INT2_G1P3_G0P3

**Dimension:** INT two-operand ready-source composition · **Equiv:** G1 P3 Bypass + G0 P3 Bypass
**Description:** Dependent captures rs1 from G1 Bypass and rs2 from G0 Bypass in the same source-ready cycle.

| Instruction | T1 | T2 | T3 | T4 | T5 | T6 | T7 | T8 | T9 |
|:---|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|
| `mul x6, x3, x4` · P3 source·G1 | IB | dispatch | MUL | MUL | MUL | WB | C |  |  |
| `add x5, x1, x2` · P3 source·G0 |  |  | IB | dispatch | ALU0 | WB | C |  |  |
| `add x20, x6, x5` · Dependent·G0 |  |  |  |  | IB | dispatch | ALU0 | WB | C |

- **T6 (Source composition)**: dependent P1 resolves rs1 as `G1 P3 Bypass` and rs2 as `G0 P3 Bypass` in one source-resolution cycle.
- **T6 (P3 capture, P3 → P1 bypass)**: every P3 source uses exact-tag Bypass capture into the new `dispatch` payload; the dependent issues at T7, not in the capture cycle.

## Case 2: INT2_G3P3_G0P3

**Dimension:** INT two-operand ready-source composition · **Equiv:** G3 Load P3 Bypass + G0 P3 Bypass
**Description:** Dependent captures rs1 from G3 load Bypass and rs2 from G0 Bypass.

| Instruction | T1 | T2 | T3 | T4 | T5 | T6 | T7 | T8 | T9 |
|:---|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|
| `ld x7, 0(x8)` · P3 source·G3 | IB | dispatch | AGU | L1D | LDA+CDB | WB | C |  |  |
| `add x5, x1, x2` · P3 source·G0 |  |  | IB | dispatch | ALU0 | WB | C |  |  |
| `add x20, x7, x5` · Dependent·G0 |  |  |  |  | IB | dispatch | ALU0 | WB | C |

- **T6 (Source composition)**: dependent P1 resolves rs1 as `G3 Load P3 Bypass` and rs2 as `G0 P3 Bypass` in one source-resolution cycle.
- **T6 (P3 capture, P3 → P1 bypass)**: every P3 source uses exact-tag Bypass capture into the new `dispatch` payload; the dependent issues at T7, not in the capture cycle.

## Case 3: INT2_P4_G0P3

**Dimension:** INT two-operand ready-source composition · **Equiv:** P4 Commit + G0 P3 Bypass
**Description:** P1 source resolution uses Commit CDB for rs1 and G0 Bypass for rs2.

| Instruction | T1 | T2 | T3 | T4 | T5 | T6 | T7 | T8 | T9 |
|:---|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|
| `add x6, x3, x4` · P4 source·G0 |  | IB | dispatch | ALU0 | WB | C |  |  |  |
| `add x5, x1, x2` · P3 source·G0 |  |  | IB | dispatch | ALU0 | WB | C |  |  |
| `add x20, x6, x5` · Dependent·G0 |  |  |  |  | IB | dispatch | ALU0 | WB | C |

- **T6 (Source composition)**: dependent P1 resolves rs1 as `P4 Commit` and rs2 as `G0 P3 Bypass` in one source-resolution cycle.
- **T6 (P3 capture, P3 → P1 bypass)**: every P3 source uses exact-tag Bypass capture into the new `dispatch` payload; the dependent issues at T7, not in the capture cycle.
- **T6 (P4 capture, P4 → P1 bypass)**: every P4 source uses exact-tag Commit CDB capture and suppresses Condition A for that source.

## Case 4: INT2_ARF_G0P3

**Dimension:** INT two-operand ready-source composition · **Equiv:** Already in ARF + G0 P3 Bypass
**Description:** rs1 reads ARF; rs2 captures G0 Bypass.

| Instruction | T1 | T2 | T3 | T4 | T5 | T6 | T7 | T8 | T9 |
|:---|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|
| `add x10, x1, x2` · ARF source·G0 | IB | dispatch | ALU0 | WB | C |  |  |  |  |
| `add x5, x3, x4` · P3 source·G0 |  |  | IB | dispatch | ALU0 | WB | C |  |  |
| `add x20, x10, x5` · Dependent·G0 |  |  |  |  | IB | dispatch | ALU0 | WB | C |

- **T6 (Source composition)**: dependent P1 resolves rs1 as `Already in ARF` and rs2 as `G0 P3 Bypass` in one source-resolution cycle.
- **T6 (P3 capture, P3 → P1 bypass)**: every P3 source uses exact-tag Bypass capture into the new `dispatch` payload; the dependent issues at T7, not in the capture cycle.
- **T6 (ARF source, no bypass)**: the ARF source has already committed before dependent P1, so `DST_REG` is not busy for that operand.

## Case 5: INT2_G0P3_IMM

**Dimension:** INT two-operand ready-source composition · **Equiv:** G0 P3 Bypass + IMM
**Description:** rs1 captures G0 Bypass; rs2 is immediate and has no dependency tag.

| Instruction | T1 | T2 | T3 | T4 | T5 | T6 | T7 | T8 | T9 |
|:---|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|
| `add x5, x1, x2` · P3 source·G0 |  |  | IB | dispatch | ALU0 | WB | C |  |  |
| `addi x20, x5, 16` · Dependent·G0 |  |  |  |  | IB | dispatch | ALU0 | WB | C |

- **T6 (Source composition)**: dependent P1 resolves rs1 as `G0 P3 Bypass` and rs2 as `IMM` in one source-resolution cycle.
- **T6 (P3 capture, P3 → P1 bypass)**: every P3 source uses exact-tag Bypass capture into the new `dispatch` payload; the dependent issues at T7, not in the capture cycle.
- **T6 (Immediate source)**: the immediate operand is ready by construction and has no dependency tag.

## Case 6: INT2_G3P3_G1P3

**Dimension:** INT two-operand ready-source composition · **Equiv:** G3 Load P3 Bypass + G1 P3 Bypass
**Description:** Dependent captures rs1 from G3 load Bypass and rs2 from G1 Bypass.

| Instruction | T1 | T2 | T3 | T4 | T5 | T6 | T7 | T8 | T9 |
|:---|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|
| `ld x7, 0(x8)` · P3 source·G3 | IB | dispatch | AGU | L1D | LDA+CDB | WB | C |  |  |
| `mul x6, x3, x4` · P3 source·G1 | IB | dispatch | MUL | MUL | MUL | WB | C |  |  |
| `add x20, x7, x6` · Dependent·G0 |  |  |  |  | IB | dispatch | ALU0 | WB | C |

- **T6 (Source composition)**: dependent P1 resolves rs1 as `G3 Load P3 Bypass` and rs2 as `G1 P3 Bypass` in one source-resolution cycle.
- **T6 (P3 capture, P3 → P1 bypass)**: every P3 source uses exact-tag Bypass capture into the new `dispatch` payload; the dependent issues at T7, not in the capture cycle.

## Case 7: INT2_P4_G1P3

**Dimension:** INT two-operand ready-source composition · **Equiv:** P4 Commit + G1 P3 Bypass
**Description:** P1 source resolution uses Commit CDB for rs1 and G1 Bypass for rs2.

| Instruction | T1 | T2 | T3 | T4 | T5 | T6 | T7 | T8 | T9 |
|:---|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|
| `add x7, x8, x9` · P4 source·G0 |  | IB | dispatch | ALU0 | WB | C |  |  |  |
| `mul x6, x3, x4` · P3 source·G1 | IB | dispatch | MUL | MUL | MUL | WB | C |  |  |
| `add x20, x7, x6` · Dependent·G0 |  |  |  |  | IB | dispatch | ALU0 | WB | C |

- **T6 (Source composition)**: dependent P1 resolves rs1 as `P4 Commit` and rs2 as `G1 P3 Bypass` in one source-resolution cycle.
- **T6 (P3 capture, P3 → P1 bypass)**: every P3 source uses exact-tag Bypass capture into the new `dispatch` payload; the dependent issues at T7, not in the capture cycle.
- **T6 (P4 capture, P4 → P1 bypass)**: every P4 source uses exact-tag Commit CDB capture and suppresses Condition A for that source.

## Case 8: INT2_ARF_G1P3

**Dimension:** INT two-operand ready-source composition · **Equiv:** Already in ARF + G1 P3 Bypass
**Description:** rs1 reads ARF; rs2 captures G1 Bypass.

| Instruction | T1 | T2 | T3 | T4 | T5 | T6 | T7 | T8 | T9 |
|:---|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|
| `add x10, x1, x2` · ARF source·G0 | IB | dispatch | ALU0 | WB | C |  |  |  |  |
| `mul x6, x3, x4` · P3 source·G1 | IB | dispatch | MUL | MUL | MUL | WB | C |  |  |
| `add x20, x10, x6` · Dependent·G0 |  |  |  |  | IB | dispatch | ALU0 | WB | C |

- **T6 (Source composition)**: dependent P1 resolves rs1 as `Already in ARF` and rs2 as `G1 P3 Bypass` in one source-resolution cycle.
- **T6 (P3 capture, P3 → P1 bypass)**: every P3 source uses exact-tag Bypass capture into the new `dispatch` payload; the dependent issues at T7, not in the capture cycle.
- **T6 (ARF source, no bypass)**: the ARF source has already committed before dependent P1, so `DST_REG` is not busy for that operand.

## Case 9: INT2_G1P3_IMM

**Dimension:** INT two-operand ready-source composition · **Equiv:** G1 P3 Bypass + IMM
**Description:** rs1 captures G1 Bypass; rs2 is immediate and has no dependency tag.

| Instruction | T1 | T2 | T3 | T4 | T5 | T6 | T7 | T8 | T9 |
|:---|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|
| `mul x6, x3, x4` · P3 source·G1 | IB | dispatch | MUL | MUL | MUL | WB | C |  |  |
| `addi x20, x6, 16` · Dependent·G0 |  |  |  |  | IB | dispatch | ALU0 | WB | C |

- **T6 (Source composition)**: dependent P1 resolves rs1 as `G1 P3 Bypass` and rs2 as `IMM` in one source-resolution cycle.
- **T6 (P3 capture, P3 → P1 bypass)**: every P3 source uses exact-tag Bypass capture into the new `dispatch` payload; the dependent issues at T7, not in the capture cycle.
- **T6 (Immediate source)**: the immediate operand is ready by construction and has no dependency tag.

## Case 10: INT2_P4_G3P3

**Dimension:** INT two-operand ready-source composition · **Equiv:** P4 Commit + G3 Load P3 Bypass
**Description:** P1 source resolution uses Commit CDB for rs1 and G3 load Bypass for rs2.

| Instruction | T1 | T2 | T3 | T4 | T5 | T6 | T7 | T8 | T9 |
|:---|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|
| `add x7, x8, x9` · P4 source·G0 |  | IB | dispatch | ALU0 | WB | C |  |  |  |
| `ld x6, 0(x10)` · P3 source·G3 | IB | dispatch | AGU | L1D | LDA+CDB | WB | C |  |  |
| `add x20, x7, x6` · Dependent·G0 |  |  |  |  | IB | dispatch | ALU0 | WB | C |

- **T6 (Source composition)**: dependent P1 resolves rs1 as `P4 Commit` and rs2 as `G3 Load P3 Bypass` in one source-resolution cycle.
- **T6 (P3 capture, P3 → P1 bypass)**: every P3 source uses exact-tag Bypass capture into the new `dispatch` payload; the dependent issues at T7, not in the capture cycle.
- **T6 (P4 capture, P4 → P1 bypass)**: every P4 source uses exact-tag Commit CDB capture and suppresses Condition A for that source.

## Case 11: INT2_ARF_G3P3

**Dimension:** INT two-operand ready-source composition · **Equiv:** Already in ARF + G3 Load P3 Bypass
**Description:** rs1 reads ARF; rs2 captures G3 load Bypass.

| Instruction | T1 | T2 | T3 | T4 | T5 | T6 | T7 | T8 | T9 |
|:---|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|
| `add x11, x1, x2` · ARF source·G0 | IB | dispatch | ALU0 | WB | C |  |  |  |  |
| `ld x6, 0(x10)` · P3 source·G3 | IB | dispatch | AGU | L1D | LDA+CDB | WB | C |  |  |
| `add x20, x11, x6` · Dependent·G0 |  |  |  |  | IB | dispatch | ALU0 | WB | C |

- **T6 (Source composition)**: dependent P1 resolves rs1 as `Already in ARF` and rs2 as `G3 Load P3 Bypass` in one source-resolution cycle.
- **T6 (P3 capture, P3 → P1 bypass)**: every P3 source uses exact-tag Bypass capture into the new `dispatch` payload; the dependent issues at T7, not in the capture cycle.
- **T6 (ARF source, no bypass)**: the ARF source has already committed before dependent P1, so `DST_REG` is not busy for that operand.

## Case 12: INT2_G3P3_IMM

**Dimension:** INT two-operand ready-source composition · **Equiv:** G3 Load P3 Bypass + IMM
**Description:** rs1 captures G3 load Bypass; rs2 is immediate and has no dependency tag.

| Instruction | T1 | T2 | T3 | T4 | T5 | T6 | T7 | T8 | T9 |
|:---|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|
| `ld x6, 0(x10)` · P3 source·G3 | IB | dispatch | AGU | L1D | LDA+CDB | WB | C |  |  |
| `addi x20, x6, 16` · Dependent·G0 |  |  |  |  | IB | dispatch | ALU0 | WB | C |

- **T6 (Source composition)**: dependent P1 resolves rs1 as `G3 Load P3 Bypass` and rs2 as `IMM` in one source-resolution cycle.
- **T6 (P3 capture, P3 → P1 bypass)**: every P3 source uses exact-tag Bypass capture into the new `dispatch` payload; the dependent issues at T7, not in the capture cycle.
- **T6 (Immediate source)**: the immediate operand is ready by construction and has no dependency tag.

## Case 13: INT2_P4_P4

**Dimension:** INT two-operand ready-source composition · **Equiv:** P4 Commit + P4 Commit
**Description:** P1 source resolution captures both operands from the two Commit CDB lanes.

| Instruction | T1 | T2 | T3 | T4 | T5 | T6 | T7 | T8 | T9 |
|:---|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|
| `add x5, x1, x2` · P4 source·G0 |  | IB | dispatch | ALU0 | WB | C |  |  |  |
| `add x6, x3, x4` · P4 source·G1 |  | IB | dispatch | ALU1 | WB | C |  |  |  |
| `add x20, x5, x6` · Dependent·G0 |  |  |  |  | IB | dispatch | ALU0 | WB | C |

- **T6 (Source composition)**: dependent P1 resolves rs1 as `P4 Commit` and rs2 as `P4 Commit` in one source-resolution cycle.
- **T6 (P4 capture, P4 → P1 bypass)**: every P4 source uses exact-tag Commit CDB capture and suppresses Condition A for that source.

## Case 14: INT2_ARF_P4

**Dimension:** INT two-operand ready-source composition · **Equiv:** Already in ARF + P4 Commit
**Description:** rs1 reads ARF; rs2 captures Commit CDB.

| Instruction | T1 | T2 | T3 | T4 | T5 | T6 | T7 | T8 | T9 |
|:---|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|
| `add x10, x1, x2` · ARF source·G0 | IB | dispatch | ALU0 | WB | C |  |  |  |  |
| `add x6, x3, x4` · P4 source·G0 |  | IB | dispatch | ALU0 | WB | C |  |  |  |
| `add x20, x10, x6` · Dependent·G0 |  |  |  |  | IB | dispatch | ALU0 | WB | C |

- **T6 (Source composition)**: dependent P1 resolves rs1 as `Already in ARF` and rs2 as `P4 Commit` in one source-resolution cycle.
- **T6 (P4 capture, P4 → P1 bypass)**: every P4 source uses exact-tag Commit CDB capture and suppresses Condition A for that source.
- **T6 (ARF source, no bypass)**: the ARF source has already committed before dependent P1, so `DST_REG` is not busy for that operand.

## Case 15: INT2_P4_IMM

**Dimension:** INT two-operand ready-source composition · **Equiv:** P4 Commit + IMM
**Description:** rs1 captures Commit CDB; rs2 is immediate and has no dependency tag.

| Instruction | T1 | T2 | T3 | T4 | T5 | T6 | T7 | T8 | T9 |
|:---|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|
| `add x5, x1, x2` · P4 source·G0 |  | IB | dispatch | ALU0 | WB | C |  |  |  |
| `addi x20, x5, 16` · Dependent·G0 |  |  |  |  | IB | dispatch | ALU0 | WB | C |

- **T6 (Source composition)**: dependent P1 resolves rs1 as `P4 Commit` and rs2 as `IMM` in one source-resolution cycle.
- **T6 (P4 capture, P4 → P1 bypass)**: every P4 source uses exact-tag Commit CDB capture and suppresses Condition A for that source.
- **T6 (Immediate source)**: the immediate operand is ready by construction and has no dependency tag.

## Case 16: INT2_ARF_ARF

**Dimension:** INT two-operand ready-source composition · **Equiv:** Already in ARF + Already in ARF
**Description:** Both operands read ARF at P1; no bypass or commit overlay is needed.

| Instruction | T1 | T2 | T3 | T4 | T5 | T6 | T7 | T8 | T9 |
|:---|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|
| `add x10, x1, x2` · ARF source·G0 | IB | dispatch | ALU0 | WB | C |  |  |  |  |
| `add x11, x3, x4` · ARF source·G1 | IB | dispatch | ALU1 | WB | C |  |  |  |  |
| `add x20, x10, x11` · Dependent·G0 |  |  |  |  | IB | dispatch | ALU0 | WB | C |

- **T6 (Source composition)**: dependent P1 resolves rs1 as `Already in ARF` and rs2 as `Already in ARF` in one source-resolution cycle.
- **T6 (ARF source, no bypass)**: the ARF source has already committed before dependent P1, so `DST_REG` is not busy for that operand.

## Case 17: INT2_ARF_IMM

**Dimension:** INT two-operand ready-source composition · **Equiv:** Already in ARF + IMM
**Description:** rs1 reads ARF; rs2 is immediate and has no dependency tag.

| Instruction | T1 | T2 | T3 | T4 | T5 | T6 | T7 | T8 | T9 |
|:---|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|
| `add x10, x1, x2` · ARF source·G0 | IB | dispatch | ALU0 | WB | C |  |  |  |  |
| `addi x20, x10, 16` · Dependent·G0 |  |  |  |  | IB | dispatch | ALU0 | WB | C |

- **T6 (Source composition)**: dependent P1 resolves rs1 as `Already in ARF` and rs2 as `IMM` in one source-resolution cycle.
- **T6 (ARF source, no bypass)**: the ARF source has already committed before dependent P1, so `DST_REG` is not busy for that operand.
- **T6 (Immediate source)**: the immediate operand is ready by construction and has no dependency tag.

## P2 MUX Resident-Entry Cases

These cases complement the P1 MUX figures above. The dependent instruction is already resident in ISQ; T8 is the observed P2 FU-input MUX cycle where current P3 forwarding and/or stored `entry.rs_data` make the operands usable. `P4 Commit CDB` is not a P2 MUX source. Immediate operands are already carried in the resident payload and are covered by `Stored Ready at dispatch`.

## Case 18: INT2_P2_G1P3_G0P3

**Dimension:** INT two-operand ready-source composition | **Equiv:** P2 MUX: G1 P3 Bypass + G0 P3 Bypass
**Description:** P2 FU-input mux selects rs1 from G1 Bypass and rs2 from G0 Bypass; the resident entry can issue in that cycle if the selected FU is free.

| Instruction | T1 | T2 | T3 | T4 | T5 | T6 | T7 | T8 | T9 | T10 |
|:---|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|
| `mul x6, x3, x4` - G1 P3 Bypass |  |  | IB | dispatch | MUL | MUL | MUL | WB | C |  |
| `add x5, x1, x2` - G0 P3 Bypass |  |  |  |  | IB | dispatch | ALU0 | WB | C |  |
| `add x20, x6, x5` - Dependent-G1 |  |  |  |  | IB | dispatch | ISQ Wait | ALU1 | WB | C |

- **T6 (Resident entry):** the dependent has already dispatched into its group-local ISQ and carries stored ready data and/or `wait_tag`s.
- **T8 (P2 MUX source-ready):** current P3 forwarding sources use exact-tag resident-entry matching; stored sources come from already valid `entry.rs_data`.
- **T8 (Issue rule):** if the selected FU is free, the resident entry issues through the P2 FU-input MUX in this cycle; otherwise matched forwarding data is latched and becomes `Stored Ready` for retry.

## Case 19: INT2_P2_G3P3_G0P3

**Dimension:** INT two-operand ready-source composition | **Equiv:** P2 MUX: G3 Load P3 Bypass + G0 P3 Bypass
**Description:** P2 mux selects rs1 from G3 load Bypass and rs2 from G0 Bypass.

| Instruction | T1 | T2 | T3 | T4 | T5 | T6 | T7 | T8 | T9 | T10 |
|:---|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|
| `ld x7, 0(x8)` - G3 Load P3 Bypass |  |  | IB | dispatch | AGU | L1D | LDA+CDB | WB | C |  |
| `add x5, x1, x2` - G0 P3 Bypass |  |  |  |  | IB | dispatch | ALU0 | WB | C |  |
| `add x20, x7, x5` - Dependent-G1 |  |  |  |  | IB | dispatch | ISQ Wait | ALU1 | WB | C |

- **T6 (Resident entry):** the dependent has already dispatched into its group-local ISQ and carries stored ready data and/or `wait_tag`s.
- **T8 (P2 MUX source-ready):** current P3 forwarding sources use exact-tag resident-entry matching; stored sources come from already valid `entry.rs_data`.
- **T8 (Issue rule):** if the selected FU is free, the resident entry issues through the P2 FU-input MUX in this cycle; otherwise matched forwarding data is latched and becomes `Stored Ready` for retry.

## Case 20: INT2_P2_STORED_G0P3

**Dimension:** INT two-operand ready-source composition | **Equiv:** P2 MUX: Stored Ready at dispatch + G0 P3 Bypass
**Description:** P2 mux uses stored `entry.rs1_data` and current G0 Bypass data.

| Instruction | T1 | T2 | T3 | T4 | T5 | T6 | T7 | T8 | T9 | T10 |
|:---|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|
| `add x10, x1, x2` - Stored Ready at dispatch | IB | dispatch | ALU0 | WB | C |  |  |  |  |  |
| `add x5, x3, x4` - G0 P3 Bypass |  |  |  |  | IB | dispatch | ALU0 | WB | C |  |
| `add x20, x10, x5` - Dependent-G1 |  |  |  |  | IB | dispatch | ISQ Wait | ALU1 | WB | C |

- **T6 (Resident entry):** the dependent has already dispatched into its group-local ISQ and carries stored ready data and/or `wait_tag`s.
- **T8 (P2 MUX source-ready):** current P3 forwarding sources use exact-tag resident-entry matching; stored sources come from already valid `entry.rs_data`.
- **T8 (Issue rule):** if the selected FU is free, the resident entry issues through the P2 FU-input MUX in this cycle; otherwise matched forwarding data is latched and becomes `Stored Ready` for retry.

## Case 21: INT2_P2_G3P3_G1P3

**Dimension:** INT two-operand ready-source composition | **Equiv:** P2 MUX: G3 Load P3 Bypass + G1 P3 Bypass
**Description:** P2 mux selects rs1 from G3 load Bypass and rs2 from G1 Bypass.

| Instruction | T1 | T2 | T3 | T4 | T5 | T6 | T7 | T8 | T9 | T10 |
|:---|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|
| `ld x7, 0(x8)` - G3 Load P3 Bypass |  |  | IB | dispatch | AGU | L1D | LDA+CDB | WB | C |  |
| `mul x6, x3, x4` - G1 P3 Bypass |  |  | IB | dispatch | MUL | MUL | MUL | WB | C |  |
| `add x20, x7, x6` - Dependent-G0 |  |  |  |  | IB | dispatch | ISQ Wait | ALU0 | WB | C |

- **T6 (Resident entry):** the dependent has already dispatched into its group-local ISQ and carries stored ready data and/or `wait_tag`s.
- **T8 (P2 MUX source-ready):** current P3 forwarding sources use exact-tag resident-entry matching; stored sources come from already valid `entry.rs_data`.
- **T8 (Issue rule):** if the selected FU is free, the resident entry issues through the P2 FU-input MUX in this cycle; otherwise matched forwarding data is latched and becomes `Stored Ready` for retry.

## Case 22: INT2_P2_STORED_G1P3

**Dimension:** INT two-operand ready-source composition | **Equiv:** P2 MUX: Stored Ready at dispatch + G1 P3 Bypass
**Description:** P2 mux uses stored `entry.rs1_data` and current G1 Bypass data.

| Instruction | T1 | T2 | T3 | T4 | T5 | T6 | T7 | T8 | T9 | T10 |
|:---|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|
| `add x10, x1, x2` - Stored Ready at dispatch | IB | dispatch | ALU0 | WB | C |  |  |  |  |  |
| `mul x6, x3, x4` - G1 P3 Bypass |  |  | IB | dispatch | MUL | MUL | MUL | WB | C |  |
| `add x20, x10, x6` - Dependent-G0 |  |  |  |  | IB | dispatch | ISQ Wait | ALU0 | WB | C |

- **T6 (Resident entry):** the dependent has already dispatched into its group-local ISQ and carries stored ready data and/or `wait_tag`s.
- **T8 (P2 MUX source-ready):** current P3 forwarding sources use exact-tag resident-entry matching; stored sources come from already valid `entry.rs_data`.
- **T8 (Issue rule):** if the selected FU is free, the resident entry issues through the P2 FU-input MUX in this cycle; otherwise matched forwarding data is latched and becomes `Stored Ready` for retry.

## Case 23: INT2_P2_STORED_G3P3

**Dimension:** INT two-operand ready-source composition | **Equiv:** P2 MUX: Stored Ready at dispatch + G3 Load P3 Bypass
**Description:** P2 mux uses stored `entry.rs1_data` and current G3 load Bypass data.

| Instruction | T1 | T2 | T3 | T4 | T5 | T6 | T7 | T8 | T9 | T10 |
|:---|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|
| `add x11, x1, x2` - Stored Ready at dispatch | IB | dispatch | ALU0 | WB | C |  |  |  |  |  |
| `ld x6, 0(x10)` - G3 Load P3 Bypass |  |  | IB | dispatch | AGU | L1D | LDA+CDB | WB | C |  |
| `add x20, x11, x6` - Dependent-G0 |  |  |  |  | IB | dispatch | ISQ Wait | ALU0 | WB | C |

- **T6 (Resident entry):** the dependent has already dispatched into its group-local ISQ and carries stored ready data and/or `wait_tag`s.
- **T8 (P2 MUX source-ready):** current P3 forwarding sources use exact-tag resident-entry matching; stored sources come from already valid `entry.rs_data`.
- **T8 (Issue rule):** if the selected FU is free, the resident entry issues through the P2 FU-input MUX in this cycle; otherwise matched forwarding data is latched and becomes `Stored Ready` for retry.

## Case 24: INT2_P2_STORED_STORED

**Dimension:** INT two-operand ready-source composition | **Equiv:** P2 MUX: Stored Ready at dispatch + Stored Ready at dispatch
**Description:** P2 mux selects both operands from stored `entry.rs_data`; no current-cycle forwarding is needed.

| Instruction | T1 | T2 | T3 | T4 | T5 | T6 | T7 | T8 | T9 | T10 |
|:---|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|
| `add x10, x1, x2` - Stored Ready at dispatch | IB | dispatch | ALU0 | WB | C |  |  |  |  |  |
| `add x11, x3, x4` - Stored Ready at dispatch | IB | dispatch | ALU0 | WB | C |  |  |  |  |  |
| `add x20, x10, x11` - Dependent-G0 |  |  |  |  | IB | dispatch | ISQ Wait | ALU0 | WB | C |

- **T6 (Resident entry):** the dependent has already dispatched into its group-local ISQ and carries stored ready data and/or `wait_tag`s.
- **T8 (P2 MUX source-ready):** both operands come from already valid `entry.rs_data`; no current-cycle forwarding source is required.
- **T8 (Issue rule):** if the selected FU is free, the resident entry issues through the P2 FU-input MUX in this cycle; otherwise matched forwarding data is latched and becomes `Stored Ready` for retry.

## Supplemental Same-RD Fanout Cases

These cases cover the legal shape behind the gray same-P3-source diagonal cells. The gray cells exclude two different producers on one P3 bypass lane; they do not exclude one producer payload feeding both rs1 and rs2.

## Case 25: INT2_SAME_RD_P1_G0P3_dispatch_dispatch

**Dimension:** INT same-RD fanout | **Equiv:** P1 MUX: G0 P3 Bypass feeds rs1 and rs2
**Description:** A single G0 producer tag matches both register sources during dependent P1 source resolution.

| Instruction | T1 | T2 | T3 | T4 | T5 | T6 | T7 | T8 | T9 |
|:---|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|
| `add x5, x1, x2` - Producer-G0 |  |  | IB | dispatch | ALU0 | WB | C |  |  |
| `add x20, x5, x5` - Dependent-G0 |  |  |  |  | IB | dispatch | ALU0 | WB | C |

- **T6 (P1 same-tag match):** rs1 and rs2 both match the same producer tag on G0 P3 Bypass.
- **T6 (Payload construction):** one forwarded payload is written into both operand data fields of the new ISQ entry.
- **T7 (Issue):** dependent issues after the ready payload is constructed.

## Case 26: INT2_SAME_RD_P1_G1P3_dispatch_dispatch

**Dimension:** INT same-RD fanout | **Equiv:** P1 MUX: G1 P3 Bypass feeds rs1 and rs2
**Description:** A single G1 producer tag matches both register sources during dependent P1 source resolution.

| Instruction | T1 | T2 | T3 | T4 | T5 | T6 | T7 | T8 | T9 |
|:---|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|
| `mul x5, x1, x2` - Producer-G1 | IB | dispatch | MUL | MUL | MUL | WB | C |  |  |
| `add x20, x5, x5` - Dependent-G0 |  |  |  |  | IB | dispatch | ALU0 | WB | C |

- **T6 (P1 same-tag match):** rs1 and rs2 both match the same producer tag on G1 P3 Bypass.
- **T6 (Payload construction):** one forwarded payload is written into both operand data fields of the new ISQ entry.
- **T7 (Issue):** dependent issues after the ready payload is constructed.

## Case 27: INT2_SAME_RD_P1_G3P3_dispatch_dispatch

**Dimension:** INT same-RD fanout | **Equiv:** P1 MUX: G3 Load P3 Bypass feeds rs1 and rs2
**Description:** A single load producer tag matches both register sources during dependent P1 source resolution.

| Instruction | T1 | T2 | T3 | T4 | T5 | T6 | T7 | T8 | T9 |
|:---|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|
| `ld x5, 0(x1)` - Producer-G3 | IB | dispatch | AGU | L1D | LDA+CDB | WB | C |  |  |
| `add x20, x5, x5` - Dependent-G0 |  |  |  |  | IB | dispatch | ALU0 | WB | C |

- **T6 (P1 same-tag match):** rs1 and rs2 both match the same producer tag on G3 load P3 Bypass.
- **T6 (Payload construction):** one forwarded payload is written into both operand data fields of the new ISQ entry.
- **T7 (Issue):** dependent issues after the ready payload is constructed.

## Case 28: INT2_SAME_RD_P2_G0P3_dispatch_dispatch

**Dimension:** INT same-RD fanout | **Equiv:** P2 MUX: G0 P3 Bypass feeds rs1 and rs2
**Description:** A resident dependent entry has both wait tags pointing to the same G0 producer.

| Instruction | T1 | T2 | T3 | T4 | T5 | T6 | T7 | T8 | T9 | T10 |
|:---|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|
| `add x5, x1, x2` - Producer-G0 |  |  |  |  | IB | dispatch | ALU0 | WB | C |  |
| `add x20, x5, x5` - Dependent-G1 |  |  |  |  | IB | dispatch | ISQ Wait | ALU1 | WB | C |

- **T6 (Resident entry):** dependent is already in ISQ with rs1 and rs2 waiting on the same producer tag.
- **T8 (P2 same-tag match):** one G0 Bypass payload satisfies both operand inputs.
- **T8 (Issue):** dependent issues through the FU-input MUX when the selected FU is free.

## Case 29: INT2_SAME_RD_P2_G1P3_dispatch_dispatch

**Dimension:** INT same-RD fanout | **Equiv:** P2 MUX: G1 P3 Bypass feeds rs1 and rs2
**Description:** A resident dependent entry has both wait tags pointing to the same G1 producer.

| Instruction | T1 | T2 | T3 | T4 | T5 | T6 | T7 | T8 | T9 | T10 |
|:---|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|
| `mul x5, x1, x2` - Producer-G1 |  |  | IB | dispatch | MUL | MUL | MUL | WB | C |  |
| `add x20, x5, x5` - Dependent-G0 |  |  |  |  | IB | dispatch | ISQ Wait | ALU0 | WB | C |

- **T6 (Resident entry):** dependent is already in ISQ with rs1 and rs2 waiting on the same producer tag.
- **T8 (P2 same-tag match):** one G1 Bypass payload satisfies both operand inputs.
- **T8 (Issue):** dependent issues through the FU-input MUX when the selected FU is free.

## Case 30: INT2_SAME_RD_P2_G3P3_dispatch_dispatch

**Dimension:** INT same-RD fanout | **Equiv:** P2 MUX: G3 Load P3 Bypass feeds rs1 and rs2
**Description:** A resident dependent entry has both wait tags pointing to the same load producer.

| Instruction | T1 | T2 | T3 | T4 | T5 | T6 | T7 | T8 | T9 | T10 |
|:---|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|
| `ld x5, 0(x1)` - Producer-G3 |  |  | IB | dispatch | AGU | L1D | LDA+CDB | WB | C |  |
| `add x20, x5, x5` - Dependent-G0 |  |  |  |  | IB | dispatch | ISQ Wait | ALU0 | WB | C |

- **T6 (Resident entry):** dependent is already in ISQ with rs1 and rs2 waiting on the same producer tag.
- **T8 (P2 same-tag match):** one G3 load Bypass payload satisfies both operand inputs.
- **T8 (Issue):** dependent issues through the FU-input MUX when the selected FU is free.
