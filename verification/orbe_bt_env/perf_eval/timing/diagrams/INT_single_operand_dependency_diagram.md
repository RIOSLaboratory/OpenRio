# INT Single-Operand Dependency Timing Diagrams

Source caselist: `../caselists/INT_single_operand_dependency_caselist_v1.md`

Normative timing source: pending promotion to `spec/or-be/`.

This diagram set is the reduced INT single-operand v2 set: one representative INT consumer per producer latency family. LOAD/STORE dependent cases moved to MEM/LSU operand K-maps; non-MEM INT dependent classes are covered by the representative `*_to_ALU` rows.

Scope note: these figures show the nominal no-older-blocker path. Condition A extensions caused by delayed P4 commit are derived from the spec and are not repeated as separate nominal figures.

## Case 1: ALU_to_ALU_delta_0 (overlay)

**Dimension:** INT single-operand dependency | **Equiv:** ALU_to_ALU
**Description:** Same-bundle rename overlay gives the dependent the producer tag; the resident dependent waits for P3 forwarding.

| Instruction | T1 | T2 | T3 | T4 | T5 | T6 | T7 | T8 |
|:---|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|
| `add x5, x1, x2` - Producer-G0 | IB | RS0 | SL (ALU0) | WB | C |  |  |  |
| `add x6, x5, x3` - Dependent-G1 | IB | RS1 | ISQ Wait | SL (ALU1) | WB | C |  |  |

- **T2 (Producer dispatch):** producer enters its group-local ISQ; normal boundaries are P3 at T4, P4 at T5, and ARF-ready at T6.
- **T2 (Rename overlay):** dependent is accepted in the same dispatch bundle and carries the newly allocated producer tag.
- **T4 (Resident wakeup):** current P3 forwarding satisfies the stored `wait_tag`; if the selected FU is free, the dependent issues in that cycle.

## Case 2: ALU_to_ALU_delta_1 (wait_for_p3)

**Dimension:** INT single-operand dependency | **Equiv:** ALU_to_ALU
**Description:** Dependent dispatches before producer P3, stores the `wait_tag` in ISQ, then wakes through resident-entry forwarding.

| Instruction | T1 | T2 | T3 | T4 | T5 | T6 | T7 | T8 |
|:---|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|
| `sub x5, x3, x4` - Producer-G0 | IB | RS0 | SL (ALU0) | WB | C |  |  |  |
| `add x6, x5, x7` - Dependent-G0 |  | IB | RS0 | SL (ALU0) | WB | C |  |  |

- **T2 (Producer dispatch):** producer enters its group-local ISQ; normal boundaries are P3 at T4, P4 at T5, and ARF-ready at T6.
- **T3 (Wait-tag dispatch):** dependent enters RS0 before producer P3 and waits resident in ISQ until the P3 forwarding match.
- **T4 (Resident wakeup):** current P3 forwarding satisfies the stored `wait_tag`; if the selected FU is free, the dependent issues in that cycle.

## Case 3: ALU_to_ALU_delta_2 (p3_capture)

**Dimension:** INT single-operand dependency | **Equiv:** ALU_to_ALU
**Description:** Dependent first P1 attempt exactly matches producer P3 Bypass and writes a ready ISQ payload.

| Instruction | T1 | T2 | T3 | T4 | T5 | T6 | T7 | T8 |
|:---|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|
| `add x5, x1, x2` - Producer-G0 | IB | RS0 | SL (ALU0) | WB | C |  |  |  |
| `add x6, x5, x3` - Dependent-G0 |  |  | IB | RS0 | SL (ALU0) | WB | C |  |

- **T2 (Producer dispatch):** producer enters its group-local ISQ; normal boundaries are P3 at T4, P4 at T5, and ARF-ready at T6.
- **T4 (P3 capture):** P1 exact-tag source resolution captures current Bypass data into a new ready ISQ payload.
- **T5 (Issue):** the dependent issues one cycle after ready payload construction.

## Case 4: ALU_to_ALU_delta_3 (p4_capture)

**Dimension:** INT single-operand dependency | **Equiv:** ALU_to_ALU
**Description:** Dependent first P1 attempt exactly matches producer P4 Commit CDB and writes a ready ISQ payload.

| Instruction | T1 | T2 | T3 | T4 | T5 | T6 | T7 | T8 |
|:---|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|
| `add x5, x1, x2` - Producer-G0 | IB | RS0 | SL (ALU0) | WB | C |  |  |  |
| `add x6, x5, x3` - Dependent-G0 |  |  |  | IB | RS0 | SL (ALU0) | WB | C |

- **T2 (Producer dispatch):** producer enters its group-local ISQ; normal boundaries are P3 at T4, P4 at T5, and ARF-ready at T6.
- **T5 (P4 capture):** P1 exact-tag source resolution captures Commit CDB data and suppresses the completed-in-Buffer stall path.
- **T6 (Issue):** the dependent issues one cycle after ready payload construction.

## Case 5: ALU_to_ALU_delta_4 (arf_read)

**Dimension:** INT single-operand dependency | **Equiv:** ALU_to_ALU
**Description:** Producer has already committed before dependent P1, so the source is read from ARF.

| Instruction | T1 | T2 | T3 | T4 | T5 | T6 | T7 | T8 | T9 |
|:---|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|
| `add x5, x1, x2` - Producer-G0 | IB | RS0 | SL (ALU0) | WB | C |  |  |  |  |
| `add x6, x5, x3` - Dependent-G0 |  |  |  |  | IB | RS0 | SL (ALU0) | WB | C |

- **T2 (Producer dispatch):** producer enters its group-local ISQ; normal boundaries are P3 at T4, P4 at T5, and ARF-ready at T6.
- **T6 (ARF read):** the producer mapping is no longer busy, so the dependent reads architectural data from ARF at P1.
- **T7 (Issue):** the dependent issues one cycle after ready payload construction.

## Case 6: MUL_to_ALU_delta_0 (overlay)

**Dimension:** INT single-operand dependency | **Equiv:** MUL_to_ALU
**Description:** Same-bundle rename overlay gives the dependent the producer tag; the resident dependent waits for P3 forwarding.

| Instruction | T1 | T2 | T3 | T4 | T5 | T6 | T7 | T8 |
|:---|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|
| `mul x5, x1, x2` - Producer-G1 | IB | RS1 | SL (MUL stg0) | MUL stg1 | MUL stg2 | WB | C |  |
| `add x6, x5, x3` - Dependent-G0 | IB | RS0 | ISQ Wait | ISQ Wait | ISQ Wait | SL (ALU0) | WB | C |

- **T2 (Producer dispatch):** producer enters its group-local ISQ; normal boundaries are P3 at T6, P4 at T7, and ARF-ready at T8.
- **T2 (Rename overlay):** dependent is accepted in the same dispatch bundle and carries the newly allocated producer tag.
- **T6 (Resident wakeup):** current P3 forwarding satisfies the stored `wait_tag`; if the selected FU is free, the dependent issues in that cycle.

## Case 7: MUL_to_ALU_delta_1 (wait_for_p3)

**Dimension:** INT single-operand dependency | **Equiv:** MUL_to_ALU
**Description:** Dependent dispatches before producer P3, stores the `wait_tag` in ISQ, then wakes through resident-entry forwarding.

| Instruction | T1 | T2 | T3 | T4 | T5 | T6 | T7 | T8 |
|:---|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|
| `mul x5, x3, x4` - Producer-G1 | IB | RS1 | SL (MUL stg0) | MUL stg1 | MUL stg2 | WB | C |  |
| `add x7, x5, x8` - Dependent-G0 |  | IB | RS0 | ISQ Wait | ISQ Wait | SL (ALU0) | WB | C |

- **T2 (Producer dispatch):** producer enters its group-local ISQ; normal boundaries are P3 at T6, P4 at T7, and ARF-ready at T8.
- **T3 (Wait-tag dispatch):** dependent enters RS0 before producer P3 and waits resident in ISQ until the P3 forwarding match.
- **T6 (Resident wakeup):** current P3 forwarding satisfies the stored `wait_tag`; if the selected FU is free, the dependent issues in that cycle.

## Case 8: MUL_to_ALU_delta_2 (wait_for_p3)

**Dimension:** INT single-operand dependency | **Equiv:** MUL_to_ALU
**Description:** Dependent dispatches before producer P3, stores the `wait_tag` in ISQ, then wakes through resident-entry forwarding.

| Instruction | T1 | T2 | T3 | T4 | T5 | T6 | T7 | T8 |
|:---|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|
| `mul x5, x1, x2` - Producer-G1 | IB | RS1 | SL (MUL stg0) | MUL stg1 | MUL stg2 | WB | C |  |
| `add x6, x5, x3` - Dependent-G0 |  |  | IB | RS0 | ISQ Wait | SL (ALU0) | WB | C |

- **T2 (Producer dispatch):** producer enters its group-local ISQ; normal boundaries are P3 at T6, P4 at T7, and ARF-ready at T8.
- **T4 (Wait-tag dispatch):** dependent enters RS0 before producer P3 and waits resident in ISQ until the P3 forwarding match.
- **T6 (Resident wakeup):** current P3 forwarding satisfies the stored `wait_tag`; if the selected FU is free, the dependent issues in that cycle.

## Case 9: MUL_to_ALU_delta_3 (wait_for_p3)

**Dimension:** INT single-operand dependency | **Equiv:** MUL_to_ALU
**Description:** Dependent dispatches before producer P3, stores the `wait_tag` in ISQ, then wakes through resident-entry forwarding.

| Instruction | T1 | T2 | T3 | T4 | T5 | T6 | T7 | T8 |
|:---|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|
| `mul x5, x1, x2` - Producer-G1 | IB | RS1 | SL (MUL stg0) | MUL stg1 | MUL stg2 | WB | C |  |
| `add x6, x5, x3` - Dependent-G0 |  |  |  | IB | RS0 | SL (ALU0) | WB | C |

- **T2 (Producer dispatch):** producer enters its group-local ISQ; normal boundaries are P3 at T6, P4 at T7, and ARF-ready at T8.
- **T5 (Wait-tag dispatch):** dependent enters RS0 before producer P3 and waits resident in ISQ until the P3 forwarding match.
- **T6 (Resident wakeup):** current P3 forwarding satisfies the stored `wait_tag`; if the selected FU is free, the dependent issues in that cycle.

## Case 10: MUL_to_ALU_delta_4 (p3_capture)

**Dimension:** INT single-operand dependency | **Equiv:** MUL_to_ALU
**Description:** Dependent first P1 attempt exactly matches producer P3 Bypass and writes a ready ISQ payload.

| Instruction | T1 | T2 | T3 | T4 | T5 | T6 | T7 | T8 | T9 |
|:---|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|
| `mul x5, x1, x2` - Producer-G1 | IB | RS1 | SL (MUL stg0) | MUL stg1 | MUL stg2 | WB | C |  |  |
| `add x6, x5, x3` - Dependent-G0 |  |  |  |  | IB | RS0 | SL (ALU0) | WB | C |

- **T2 (Producer dispatch):** producer enters its group-local ISQ; normal boundaries are P3 at T6, P4 at T7, and ARF-ready at T8.
- **T6 (P3 capture):** P1 exact-tag source resolution captures current Bypass data into a new ready ISQ payload.
- **T7 (Issue):** the dependent issues one cycle after ready payload construction.

## Case 11: MUL_to_ALU_delta_5 (p4_capture)

**Dimension:** INT single-operand dependency | **Equiv:** MUL_to_ALU
**Description:** Dependent first P1 attempt exactly matches producer P4 Commit CDB and writes a ready ISQ payload.

| Instruction | T1 | T2 | T3 | T4 | T5 | T6 | T7 | T8 | T9 | T10 |
|:---|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|
| `mul x5, x1, x2` - Producer-G1 | IB | RS1 | SL (MUL stg0) | MUL stg1 | MUL stg2 | WB | C |  |  |  |
| `add x6, x5, x3` - Dependent-G0 |  |  |  |  |  | IB | RS0 | SL (ALU0) | WB | C |

- **T2 (Producer dispatch):** producer enters its group-local ISQ; normal boundaries are P3 at T6, P4 at T7, and ARF-ready at T8.
- **T7 (P4 capture):** P1 exact-tag source resolution captures Commit CDB data and suppresses the completed-in-Buffer stall path.
- **T8 (Issue):** the dependent issues one cycle after ready payload construction.

## Case 12: MUL_to_ALU_delta_6 (arf_read)

**Dimension:** INT single-operand dependency | **Equiv:** MUL_to_ALU
**Description:** Producer has already committed before dependent P1, so the source is read from ARF.

| Instruction | T1 | T2 | T3 | T4 | T5 | T6 | T7 | T8 | T9 | T10 | T11 |
|:---|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|
| `mul x5, x1, x2` - Producer-G1 | IB | RS1 | SL (MUL stg0) | MUL stg1 | MUL stg2 | WB | C |  |  |  |  |
| `add x6, x5, x3` - Dependent-G0 |  |  |  |  |  |  | IB | RS0 | SL (ALU0) | WB | C |

- **T2 (Producer dispatch):** producer enters its group-local ISQ; normal boundaries are P3 at T6, P4 at T7, and ARF-ready at T8.
- **T8 (ARF read):** the producer mapping is no longer busy, so the dependent reads architectural data from ARF at P1.
- **T9 (Issue):** the dependent issues one cycle after ready payload construction.

## Case 13: DIV_to_ALU_delta_0 (overlay)

**Dimension:** INT single-operand dependency | **Equiv:** DIV_to_ALU
**Description:** Same-bundle rename overlay gives the dependent the producer tag; the resident dependent waits for P3 forwarding.

| Instruction | T1 | T2 | T3 | T4 | T5 | T6 | T7 | T8 | T9 | T10 | T11 | T12 | T13 |
|:---|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|
| `div x5, x1, x2` - Producer-G0 | IB | RS0 | SL (DIV stg0) | DIV stg1 | DIV stg2 | DIV stg3 | DIV stg4 | DIV stg5 | DIV stg6 | DIV stg7 | WB | C |  |
| `add x6, x5, x3` - Dependent-G1 | IB | RS1 | ISQ Wait | ISQ Wait | ISQ Wait | ISQ Wait | ISQ Wait | ISQ Wait | ISQ Wait | ISQ Wait | SL (ALU1) | WB | C |

- **T2 (Producer dispatch):** producer enters its group-local ISQ; normal boundaries are P3 at T11, P4 at T12, and ARF-ready at T13.
- **T2 (Rename overlay):** dependent is accepted in the same dispatch bundle and carries the newly allocated producer tag.
- **T11 (Resident wakeup):** current P3 forwarding satisfies the stored `wait_tag`; if the selected FU is free, the dependent issues in that cycle.

## Case 14: DIV_to_ALU_delta_1 (wait_for_p3)

**Dimension:** INT single-operand dependency | **Equiv:** DIV_to_ALU
**Description:** Dependent dispatches before producer P3, stores the `wait_tag` in ISQ, then wakes through resident-entry forwarding.

| Instruction | T1 | T2 | T3 | T4 | T5 | T6 | T7 | T8 | T9 | T10 | T11 | T12 | T13 |
|:---|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|
| `div x5, x3, x4` - Producer-G0 | IB | RS0 | SL (DIV stg0) | DIV stg1 | DIV stg2 | DIV stg3 | DIV stg4 | DIV stg5 | DIV stg6 | DIV stg7 | WB | C |  |
| `add x7, x5, x8` - Dependent-G0 |  | IB | RS0 | ISQ Wait | ISQ Wait | ISQ Wait | ISQ Wait | ISQ Wait | ISQ Wait | ISQ Wait | SL (ALU0) | WB | C |

- **T2 (Producer dispatch):** producer enters its group-local ISQ; normal boundaries are P3 at T11, P4 at T12, and ARF-ready at T13.
- **T3 (Wait-tag dispatch):** dependent enters RS0 before producer P3 and waits resident in ISQ until the P3 forwarding match.
- **T11 (Resident wakeup):** current P3 forwarding satisfies the stored `wait_tag`; if the selected FU is free, the dependent issues in that cycle.

## Case 15: DIV_to_ALU_delta_2 (wait_for_p3)

**Dimension:** INT single-operand dependency | **Equiv:** DIV_to_ALU
**Description:** Dependent dispatches before producer P3, stores the `wait_tag` in ISQ, then wakes through resident-entry forwarding.

| Instruction | T1 | T2 | T3 | T4 | T5 | T6 | T7 | T8 | T9 | T10 | T11 | T12 | T13 |
|:---|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|
| `div x5, x1, x2` - Producer-G0 | IB | RS0 | SL (DIV stg0) | DIV stg1 | DIV stg2 | DIV stg3 | DIV stg4 | DIV stg5 | DIV stg6 | DIV stg7 | WB | C |  |
| `add x6, x5, x3` - Dependent-G0 |  |  | IB | RS0 | ISQ Wait | ISQ Wait | ISQ Wait | ISQ Wait | ISQ Wait | ISQ Wait | SL (ALU0) | WB | C |

- **T2 (Producer dispatch):** producer enters its group-local ISQ; normal boundaries are P3 at T11, P4 at T12, and ARF-ready at T13.
- **T4 (Wait-tag dispatch):** dependent enters RS0 before producer P3 and waits resident in ISQ until the P3 forwarding match.
- **T11 (Resident wakeup):** current P3 forwarding satisfies the stored `wait_tag`; if the selected FU is free, the dependent issues in that cycle.

## Case 16: DIV_to_ALU_delta_3 (wait_for_p3)

**Dimension:** INT single-operand dependency | **Equiv:** DIV_to_ALU
**Description:** Dependent dispatches before producer P3, stores the `wait_tag` in ISQ, then wakes through resident-entry forwarding.

| Instruction | T1 | T2 | T3 | T4 | T5 | T6 | T7 | T8 | T9 | T10 | T11 | T12 | T13 |
|:---|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|
| `div x5, x1, x2` - Producer-G0 | IB | RS0 | SL (DIV stg0) | DIV stg1 | DIV stg2 | DIV stg3 | DIV stg4 | DIV stg5 | DIV stg6 | DIV stg7 | WB | C |  |
| `add x6, x5, x3` - Dependent-G0 |  |  |  | IB | RS0 | ISQ Wait | ISQ Wait | ISQ Wait | ISQ Wait | ISQ Wait | SL (ALU0) | WB | C |

- **T2 (Producer dispatch):** producer enters its group-local ISQ; normal boundaries are P3 at T11, P4 at T12, and ARF-ready at T13.
- **T5 (Wait-tag dispatch):** dependent enters RS0 before producer P3 and waits resident in ISQ until the P3 forwarding match.
- **T11 (Resident wakeup):** current P3 forwarding satisfies the stored `wait_tag`; if the selected FU is free, the dependent issues in that cycle.

## Case 17: DIV_to_ALU_delta_4 (wait_for_p3)

**Dimension:** INT single-operand dependency | **Equiv:** DIV_to_ALU
**Description:** Dependent dispatches before producer P3, stores the `wait_tag` in ISQ, then wakes through resident-entry forwarding.

| Instruction | T1 | T2 | T3 | T4 | T5 | T6 | T7 | T8 | T9 | T10 | T11 | T12 | T13 |
|:---|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|
| `div x5, x1, x2` - Producer-G0 | IB | RS0 | SL (DIV stg0) | DIV stg1 | DIV stg2 | DIV stg3 | DIV stg4 | DIV stg5 | DIV stg6 | DIV stg7 | WB | C |  |
| `add x6, x5, x3` - Dependent-G0 |  |  |  |  | IB | RS0 | ISQ Wait | ISQ Wait | ISQ Wait | ISQ Wait | SL (ALU0) | WB | C |

- **T2 (Producer dispatch):** producer enters its group-local ISQ; normal boundaries are P3 at T11, P4 at T12, and ARF-ready at T13.
- **T6 (Wait-tag dispatch):** dependent enters RS0 before producer P3 and waits resident in ISQ until the P3 forwarding match.
- **T11 (Resident wakeup):** current P3 forwarding satisfies the stored `wait_tag`; if the selected FU is free, the dependent issues in that cycle.

## Case 18: DIV_to_ALU_delta_5 (wait_for_p3)

**Dimension:** INT single-operand dependency | **Equiv:** DIV_to_ALU
**Description:** Dependent dispatches before producer P3, stores the `wait_tag` in ISQ, then wakes through resident-entry forwarding.

| Instruction | T1 | T2 | T3 | T4 | T5 | T6 | T7 | T8 | T9 | T10 | T11 | T12 | T13 |
|:---|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|
| `div x5, x1, x2` - Producer-G0 | IB | RS0 | SL (DIV stg0) | DIV stg1 | DIV stg2 | DIV stg3 | DIV stg4 | DIV stg5 | DIV stg6 | DIV stg7 | WB | C |  |
| `add x6, x5, x3` - Dependent-G0 |  |  |  |  |  | IB | RS0 | ISQ Wait | ISQ Wait | ISQ Wait | SL (ALU0) | WB | C |

- **T2 (Producer dispatch):** producer enters its group-local ISQ; normal boundaries are P3 at T11, P4 at T12, and ARF-ready at T13.
- **T7 (Wait-tag dispatch):** dependent enters RS0 before producer P3 and waits resident in ISQ until the P3 forwarding match.
- **T11 (Resident wakeup):** current P3 forwarding satisfies the stored `wait_tag`; if the selected FU is free, the dependent issues in that cycle.

## Case 19: DIV_to_ALU_delta_6 (wait_for_p3)

**Dimension:** INT single-operand dependency | **Equiv:** DIV_to_ALU
**Description:** Dependent dispatches before producer P3, stores the `wait_tag` in ISQ, then wakes through resident-entry forwarding.

| Instruction | T1 | T2 | T3 | T4 | T5 | T6 | T7 | T8 | T9 | T10 | T11 | T12 | T13 |
|:---|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|
| `div x5, x1, x2` - Producer-G0 | IB | RS0 | SL (DIV stg0) | DIV stg1 | DIV stg2 | DIV stg3 | DIV stg4 | DIV stg5 | DIV stg6 | DIV stg7 | WB | C |  |
| `add x6, x5, x3` - Dependent-G0 |  |  |  |  |  |  | IB | RS0 | ISQ Wait | ISQ Wait | SL (ALU0) | WB | C |

- **T2 (Producer dispatch):** producer enters its group-local ISQ; normal boundaries are P3 at T11, P4 at T12, and ARF-ready at T13.
- **T8 (Wait-tag dispatch):** dependent enters RS0 before producer P3 and waits resident in ISQ until the P3 forwarding match.
- **T11 (Resident wakeup):** current P3 forwarding satisfies the stored `wait_tag`; if the selected FU is free, the dependent issues in that cycle.

## Case 20: DIV_to_ALU_delta_7 (wait_for_p3)

**Dimension:** INT single-operand dependency | **Equiv:** DIV_to_ALU
**Description:** Dependent dispatches before producer P3, stores the `wait_tag` in ISQ, then wakes through resident-entry forwarding.

| Instruction | T1 | T2 | T3 | T4 | T5 | T6 | T7 | T8 | T9 | T10 | T11 | T12 | T13 |
|:---|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|
| `div x5, x1, x2` - Producer-G0 | IB | RS0 | SL (DIV stg0) | DIV stg1 | DIV stg2 | DIV stg3 | DIV stg4 | DIV stg5 | DIV stg6 | DIV stg7 | WB | C |  |
| `add x6, x5, x3` - Dependent-G0 |  |  |  |  |  |  |  | IB | RS0 | ISQ Wait | SL (ALU0) | WB | C |

- **T2 (Producer dispatch):** producer enters its group-local ISQ; normal boundaries are P3 at T11, P4 at T12, and ARF-ready at T13.
- **T9 (Wait-tag dispatch):** dependent enters RS0 before producer P3 and waits resident in ISQ until the P3 forwarding match.
- **T11 (Resident wakeup):** current P3 forwarding satisfies the stored `wait_tag`; if the selected FU is free, the dependent issues in that cycle.

## Case 21: DIV_to_ALU_delta_8 (wait_for_p3)

**Dimension:** INT single-operand dependency | **Equiv:** DIV_to_ALU
**Description:** Dependent dispatches before producer P3, stores the `wait_tag` in ISQ, then wakes through resident-entry forwarding.

| Instruction | T1 | T2 | T3 | T4 | T5 | T6 | T7 | T8 | T9 | T10 | T11 | T12 | T13 |
|:---|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|
| `div x5, x1, x2` - Producer-G0 | IB | RS0 | SL (DIV stg0) | DIV stg1 | DIV stg2 | DIV stg3 | DIV stg4 | DIV stg5 | DIV stg6 | DIV stg7 | WB | C |  |
| `add x6, x5, x3` - Dependent-G0 |  |  |  |  |  |  |  |  | IB | RS0 | SL (ALU0) | WB | C |

- **T2 (Producer dispatch):** producer enters its group-local ISQ; normal boundaries are P3 at T11, P4 at T12, and ARF-ready at T13.
- **T10 (Wait-tag dispatch):** dependent enters RS0 before producer P3 and waits resident in ISQ until the P3 forwarding match.
- **T11 (Resident wakeup):** current P3 forwarding satisfies the stored `wait_tag`; if the selected FU is free, the dependent issues in that cycle.

## Case 22: DIV_to_ALU_delta_9 (p3_capture)

**Dimension:** INT single-operand dependency | **Equiv:** DIV_to_ALU
**Description:** Dependent first P1 attempt exactly matches producer P3 Bypass and writes a ready ISQ payload.

| Instruction | T1 | T2 | T3 | T4 | T5 | T6 | T7 | T8 | T9 | T10 | T11 | T12 | T13 | T14 |
|:---|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|
| `div x5, x1, x2` - Producer-G0 | IB | RS0 | SL (DIV stg0) | DIV stg1 | DIV stg2 | DIV stg3 | DIV stg4 | DIV stg5 | DIV stg6 | DIV stg7 | WB | C |  |  |
| `add x6, x5, x3` - Dependent-G0 |  |  |  |  |  |  |  |  |  | IB | RS0 | SL (ALU0) | WB | C |

- **T2 (Producer dispatch):** producer enters its group-local ISQ; normal boundaries are P3 at T11, P4 at T12, and ARF-ready at T13.
- **T11 (P3 capture):** P1 exact-tag source resolution captures current Bypass data into a new ready ISQ payload.
- **T12 (Issue):** the dependent issues one cycle after ready payload construction.

## Case 23: DIV_to_ALU_delta_10 (p4_capture)

**Dimension:** INT single-operand dependency | **Equiv:** DIV_to_ALU
**Description:** Dependent first P1 attempt exactly matches producer P4 Commit CDB and writes a ready ISQ payload.

| Instruction | T1 | T2 | T3 | T4 | T5 | T6 | T7 | T8 | T9 | T10 | T11 | T12 | T13 | T14 | T15 |
|:---|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|
| `div x5, x1, x2` - Producer-G0 | IB | RS0 | SL (DIV stg0) | DIV stg1 | DIV stg2 | DIV stg3 | DIV stg4 | DIV stg5 | DIV stg6 | DIV stg7 | WB | C |  |  |  |
| `add x6, x5, x3` - Dependent-G0 |  |  |  |  |  |  |  |  |  |  | IB | RS0 | SL (ALU0) | WB | C |

- **T2 (Producer dispatch):** producer enters its group-local ISQ; normal boundaries are P3 at T11, P4 at T12, and ARF-ready at T13.
- **T12 (P4 capture):** P1 exact-tag source resolution captures Commit CDB data and suppresses the completed-in-Buffer stall path.
- **T13 (Issue):** the dependent issues one cycle after ready payload construction.

## Case 24: DIV_to_ALU_delta_11 (arf_read)

**Dimension:** INT single-operand dependency | **Equiv:** DIV_to_ALU
**Description:** Producer has already committed before dependent P1, so the source is read from ARF.

| Instruction | T1 | T2 | T3 | T4 | T5 | T6 | T7 | T8 | T9 | T10 | T11 | T12 | T13 | T14 | T15 | T16 |
|:---|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|
| `div x5, x1, x2` - Producer-G0 | IB | RS0 | SL (DIV stg0) | DIV stg1 | DIV stg2 | DIV stg3 | DIV stg4 | DIV stg5 | DIV stg6 | DIV stg7 | WB | C |  |  |  |  |
| `add x6, x5, x3` - Dependent-G0 |  |  |  |  |  |  |  |  |  |  |  | IB | RS0 | SL (ALU0) | WB | C |

- **T2 (Producer dispatch):** producer enters its group-local ISQ; normal boundaries are P3 at T11, P4 at T12, and ARF-ready at T13.
- **T13 (ARF read):** the producer mapping is no longer busy, so the dependent reads architectural data from ARF at P1.
- **T14 (Issue):** the dependent issues one cycle after ready payload construction.

## Case 25: LOAD_to_ALU_delta_0 (overlay)

**Dimension:** INT single-operand dependency | **Equiv:** LOAD_to_ALU
**Description:** Same-bundle rename overlay gives the dependent the producer tag; the resident dependent waits for P3 forwarding.

| Instruction | T1 | T2 | T3 | T4 | T5 | T6 | T7 | T8 |
|:---|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|
| `ld x5, 0(x1)` - Producer-G3 | IB | RS3 | SL (AGU) | L1D | WB | C |  |  |
| `add x6, x5, x3` - Dependent-G0 | IB | RS0 | ISQ Wait | ISQ Wait | SL (ALU0) | WB | C |  |

- **T2 (Producer dispatch):** producer enters its group-local ISQ; normal boundaries are P3 at T5, P4 at T6, and ARF-ready at T7.
- **T2 (Rename overlay):** dependent is accepted in the same dispatch bundle and carries the newly allocated producer tag.
- **T5 (Resident wakeup):** current P3 forwarding satisfies the stored `wait_tag`; if the selected FU is free, the dependent issues in that cycle.

## Case 26: LOAD_to_ALU_delta_1 (wait_for_p3)

**Dimension:** INT single-operand dependency | **Equiv:** LOAD_to_ALU
**Description:** Dependent dispatches before producer P3, stores the `wait_tag` in ISQ, then wakes through resident-entry forwarding.

| Instruction | T1 | T2 | T3 | T4 | T5 | T6 | T7 | T8 |
|:---|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|
| `lw x5, 8(x2)` - Producer-G3 | IB | RS3 | SL (AGU) | L1D | WB | C |  |  |
| `add x7, x5, x8` - Dependent-G0 |  | IB | RS0 | ISQ Wait | SL (ALU0) | WB | C |  |

- **T2 (Producer dispatch):** producer enters its group-local ISQ; normal boundaries are P3 at T5, P4 at T6, and ARF-ready at T7.
- **T3 (Wait-tag dispatch):** dependent enters RS0 before producer P3 and waits resident in ISQ until the P3 forwarding match.
- **T5 (Resident wakeup):** current P3 forwarding satisfies the stored `wait_tag`; if the selected FU is free, the dependent issues in that cycle.

## Case 27: LOAD_to_ALU_delta_2 (wait_for_p3)

**Dimension:** INT single-operand dependency | **Equiv:** LOAD_to_ALU
**Description:** Dependent dispatches before producer P3, stores the `wait_tag` in ISQ, then wakes through resident-entry forwarding.

| Instruction | T1 | T2 | T3 | T4 | T5 | T6 | T7 | T8 |
|:---|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|
| `ld x5, 0(x1)` - Producer-G3 | IB | RS3 | SL (AGU) | L1D | WB | C |  |  |
| `add x6, x5, x3` - Dependent-G0 |  |  | IB | RS0 | SL (ALU0) | WB | C |  |

- **T2 (Producer dispatch):** producer enters its group-local ISQ; normal boundaries are P3 at T5, P4 at T6, and ARF-ready at T7.
- **T4 (Wait-tag dispatch):** dependent enters RS0 before producer P3 and waits resident in ISQ until the P3 forwarding match.
- **T5 (Resident wakeup):** current P3 forwarding satisfies the stored `wait_tag`; if the selected FU is free, the dependent issues in that cycle.

## Case 28: LOAD_to_ALU_delta_3 (p3_capture)

**Dimension:** INT single-operand dependency | **Equiv:** LOAD_to_ALU
**Description:** Dependent first P1 attempt exactly matches producer P3 Bypass and writes a ready ISQ payload.

| Instruction | T1 | T2 | T3 | T4 | T5 | T6 | T7 | T8 |
|:---|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|
| `ld x5, 0(x1)` - Producer-G3 | IB | RS3 | SL (AGU) | L1D | WB | C |  |  |
| `add x6, x5, x3` - Dependent-G0 |  |  |  | IB | RS0 | SL (ALU0) | WB | C |

- **T2 (Producer dispatch):** producer enters its group-local ISQ; normal boundaries are P3 at T5, P4 at T6, and ARF-ready at T7.
- **T5 (P3 capture):** P1 exact-tag source resolution captures current Bypass data into a new ready ISQ payload.
- **T6 (Issue):** the dependent issues one cycle after ready payload construction.

## Case 29: LOAD_to_ALU_delta_4 (p4_capture)

**Dimension:** INT single-operand dependency | **Equiv:** LOAD_to_ALU
**Description:** Dependent first P1 attempt exactly matches producer P4 Commit CDB and writes a ready ISQ payload.

| Instruction | T1 | T2 | T3 | T4 | T5 | T6 | T7 | T8 | T9 |
|:---|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|
| `ld x5, 0(x1)` - Producer-G3 | IB | RS3 | SL (AGU) | L1D | WB | C |  |  |  |
| `add x6, x5, x3` - Dependent-G0 |  |  |  |  | IB | RS0 | SL (ALU0) | WB | C |

- **T2 (Producer dispatch):** producer enters its group-local ISQ; normal boundaries are P3 at T5, P4 at T6, and ARF-ready at T7.
- **T6 (P4 capture):** P1 exact-tag source resolution captures Commit CDB data and suppresses the completed-in-Buffer stall path.
- **T7 (Issue):** the dependent issues one cycle after ready payload construction.

## Case 30: LOAD_to_ALU_delta_5 (arf_read)

**Dimension:** INT single-operand dependency | **Equiv:** LOAD_to_ALU
**Description:** Producer has already committed before dependent P1, so the source is read from ARF.

| Instruction | T1 | T2 | T3 | T4 | T5 | T6 | T7 | T8 | T9 | T10 |
|:---|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|
| `ld x5, 0(x1)` - Producer-G3 | IB | RS3 | SL (AGU) | L1D | WB | C |  |  |  |  |
| `add x6, x5, x3` - Dependent-G0 |  |  |  |  |  | IB | RS0 | SL (ALU0) | WB | C |

- **T2 (Producer dispatch):** producer enters its group-local ISQ; normal boundaries are P3 at T5, P4 at T6, and ARF-ready at T7.
- **T7 (ARF read):** the producer mapping is no longer busy, so the dependent reads architectural data from ARF at P1.
- **T8 (Issue):** the dependent issues one cycle after ready payload construction.

## Case 31: JALR_to_ALU_delta_0 (overlay)

**Dimension:** INT single-operand dependency | **Equiv:** JALR_to_ALU
**Description:** Same-bundle rename overlay gives the dependent the producer tag; the resident dependent waits for P3 forwarding.

| Instruction | T1 | T2 | T3 | T4 | T5 | T6 | T7 | T8 |
|:---|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|
| `jalr x5, 0(x10)` - Producer-G0 | IB | RS0 | SL (BRU stg0) | BRU stg1 | BRU stg2 | WB | C |  |
| `add x6, x5, x3` - Dependent-G1 | IB | RS1 | ISQ Wait | ISQ Wait | ISQ Wait | SL (ALU1) | WB | C |

- **T2 (Producer dispatch):** producer enters its group-local ISQ; normal boundaries are P3 at T6, P4 at T7, and ARF-ready at T8.
- **T2 (Rename overlay):** dependent is accepted in the same dispatch bundle and carries the newly allocated producer tag.
- **T6 (Resident wakeup):** current P3 forwarding satisfies the stored `wait_tag`; if the selected FU is free, the dependent issues in that cycle.

## Case 32: JALR_to_ALU_delta_1 (wait_for_p3)

**Dimension:** INT single-operand dependency | **Equiv:** JALR_to_ALU
**Description:** Dependent dispatches before producer P3, stores the `wait_tag` in ISQ, then wakes through resident-entry forwarding.

| Instruction | T1 | T2 | T3 | T4 | T5 | T6 | T7 | T8 |
|:---|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|
| `jalr x5, 0(x10)` - Producer-G0 | IB | RS0 | SL (BRU stg0) | BRU stg1 | BRU stg2 | WB | C |  |
| `add x7, x5, x8` - Dependent-G0 |  | IB | RS0 | ISQ Wait | ISQ Wait | SL (ALU0) | WB | C |

- **T2 (Producer dispatch):** producer enters its group-local ISQ; normal boundaries are P3 at T6, P4 at T7, and ARF-ready at T8.
- **T3 (Wait-tag dispatch):** dependent enters RS0 before producer P3 and waits resident in ISQ until the P3 forwarding match.
- **T6 (Resident wakeup):** current P3 forwarding satisfies the stored `wait_tag`; if the selected FU is free, the dependent issues in that cycle.

## Case 33: JALR_to_ALU_delta_2 (wait_for_p3)

**Dimension:** INT single-operand dependency | **Equiv:** JALR_to_ALU
**Description:** Dependent dispatches before producer P3, stores the `wait_tag` in ISQ, then wakes through resident-entry forwarding.

| Instruction | T1 | T2 | T3 | T4 | T5 | T6 | T7 | T8 |
|:---|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|
| `jalr x5, 0(x10)` - Producer-G0 | IB | RS0 | SL (BRU stg0) | BRU stg1 | BRU stg2 | WB | C |  |
| `add x6, x5, x3` - Dependent-G0 |  |  | IB | RS0 | ISQ Wait | SL (ALU0) | WB | C |

- **T2 (Producer dispatch):** producer enters its group-local ISQ; normal boundaries are P3 at T6, P4 at T7, and ARF-ready at T8.
- **T4 (Wait-tag dispatch):** dependent enters RS0 before producer P3 and waits resident in ISQ until the P3 forwarding match.
- **T6 (Resident wakeup):** current P3 forwarding satisfies the stored `wait_tag`; if the selected FU is free, the dependent issues in that cycle.

## Case 34: JALR_to_ALU_delta_3 (wait_for_p3)

**Dimension:** INT single-operand dependency | **Equiv:** JALR_to_ALU
**Description:** Dependent dispatches before producer P3, stores the `wait_tag` in ISQ, then wakes through resident-entry forwarding.

| Instruction | T1 | T2 | T3 | T4 | T5 | T6 | T7 | T8 |
|:---|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|
| `jalr x5, 0(x10)` - Producer-G0 | IB | RS0 | SL (BRU stg0) | BRU stg1 | BRU stg2 | WB | C |  |
| `add x6, x5, x3` - Dependent-G0 |  |  |  | IB | RS0 | SL (ALU0) | WB | C |

- **T2 (Producer dispatch):** producer enters its group-local ISQ; normal boundaries are P3 at T6, P4 at T7, and ARF-ready at T8.
- **T5 (Wait-tag dispatch):** dependent enters RS0 before producer P3 and waits resident in ISQ until the P3 forwarding match.
- **T6 (Resident wakeup):** current P3 forwarding satisfies the stored `wait_tag`; if the selected FU is free, the dependent issues in that cycle.

## Case 35: JALR_to_ALU_delta_4 (p3_capture)

**Dimension:** INT single-operand dependency | **Equiv:** JALR_to_ALU
**Description:** Dependent first P1 attempt exactly matches producer P3 Bypass and writes a ready ISQ payload.

| Instruction | T1 | T2 | T3 | T4 | T5 | T6 | T7 | T8 | T9 |
|:---|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|
| `jalr x5, 0(x10)` - Producer-G0 | IB | RS0 | SL (BRU stg0) | BRU stg1 | BRU stg2 | WB | C |  |  |
| `add x6, x5, x3` - Dependent-G0 |  |  |  |  | IB | RS0 | SL (ALU0) | WB | C |

- **T2 (Producer dispatch):** producer enters its group-local ISQ; normal boundaries are P3 at T6, P4 at T7, and ARF-ready at T8.
- **T6 (P3 capture):** P1 exact-tag source resolution captures current Bypass data into a new ready ISQ payload.
- **T7 (Issue):** the dependent issues one cycle after ready payload construction.

## Case 36: JALR_to_ALU_delta_5 (p4_capture)

**Dimension:** INT single-operand dependency | **Equiv:** JALR_to_ALU
**Description:** Dependent first P1 attempt exactly matches producer P4 Commit CDB and writes a ready ISQ payload.

| Instruction | T1 | T2 | T3 | T4 | T5 | T6 | T7 | T8 | T9 | T10 |
|:---|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|
| `jalr x5, 0(x10)` - Producer-G0 | IB | RS0 | SL (BRU stg0) | BRU stg1 | BRU stg2 | WB | C |  |  |  |
| `add x6, x5, x3` - Dependent-G0 |  |  |  |  |  | IB | RS0 | SL (ALU0) | WB | C |

- **T2 (Producer dispatch):** producer enters its group-local ISQ; normal boundaries are P3 at T6, P4 at T7, and ARF-ready at T8.
- **T7 (P4 capture):** P1 exact-tag source resolution captures Commit CDB data and suppresses the completed-in-Buffer stall path.
- **T8 (Issue):** the dependent issues one cycle after ready payload construction.

## Case 37: JALR_to_ALU_delta_6 (arf_read)

**Dimension:** INT single-operand dependency | **Equiv:** JALR_to_ALU
**Description:** Producer has already committed before dependent P1, so the source is read from ARF.

| Instruction | T1 | T2 | T3 | T4 | T5 | T6 | T7 | T8 | T9 | T10 | T11 |
|:---|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|
| `jalr x5, 0(x10)` - Producer-G0 | IB | RS0 | SL (BRU stg0) | BRU stg1 | BRU stg2 | WB | C |  |  |  |  |
| `add x6, x5, x3` - Dependent-G0 |  |  |  |  |  |  | IB | RS0 | SL (ALU0) | WB | C |

- **T2 (Producer dispatch):** producer enters its group-local ISQ; normal boundaries are P3 at T6, P4 at T7, and ARF-ready at T8.
- **T8 (ARF read):** the producer mapping is no longer busy, so the dependent reads architectural data from ARF at P1.
- **T9 (Issue):** the dependent issues one cycle after ready payload construction.
