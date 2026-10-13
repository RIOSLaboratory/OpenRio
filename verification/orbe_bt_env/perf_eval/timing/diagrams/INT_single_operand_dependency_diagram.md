# INT Single-Operand Dependency Timing Diagrams

Source caselist: `../caselists/INT_single_operand_dependency_caselist_v1.md`

Normative timing source: pending promotion to `spec/or-be/`.

This diagram set is the reduced INT single-operand v2 set: one representative INT consumer per producer latency family. LOAD/STORE dependent cases moved to MEM/LSU operand K-maps; non-MEM INT dependent classes are covered by the representative `*_to_ALU` rows.

Scope note: these figures show the nominal no-older-blocker path. Condition A extensions caused by delayed P4 commit are derived from the spec and are not repeated as separate nominal figures.


> **Landmark precondition (added with the `*_p4blocked` cases).** The rows above place `WB` at `T(3+L)` and
> `C` at `T(4+L)`, and the `p4_capture` rung is defined as "the dependent's P1 lands on the producer's P4".
> Both assume the producer is already at the commit head when it writes back. Retirement is in order while
> writeback is not, so when an older instruction is still in flight the producer's `C` slides, `P4 − P3 > 1`,
> and the nominal `p4_capture` becomes unreachable — the dependent stalls instead. The five `*_p4blocked`
> cases exist to exercise exactly that condition; they are a separate class, not a re-run of the nominal rung.

## Stage mapping

The pipeline is the five-stage BE model (see `../../../docs/BE/or_be_has_V1.0.md` §5). Every cell in the figures below is one of these:

| Cell | Stage | Meaning |
|---|---|---|
| `IB` | **P0** | The instruction is enqueued into the instruction buffer. This cell marks the enqueue cycle only. |
| `dispatch` | **P1** | The group's ISQ entry is written here. The group is chosen inside `dispatch_logic`, so the cell does not name one — the row label carries the group. The IB head read that forms the dispatch bundle is also a P1 activity. `delta` is the difference between two `dispatch` cells. |
| `ISQ Wait` | **P2** | Resident in the ISQ, waiting for a source. |
| FU name (`ALU0`, `ALU1`, `MUL`, `DIV`, `BRU`, `AGU`, `L1D`, `LDA+CDB`) | **P2** | The FU is executing. The first such cell is the cycle the issue is accepted; a multi-cycle FU repeats its name (`MUL MUL MUL`, `DIV DIV DIV`). LOAD is `AGU` → `L1D` → `LDA+CDB`. |
| `WB` | **P3** | Result writeback / bypass broadcast. |
| `C` | **P4** | Commit. |

Landmarks used by every figure. `L` is the producer family's latency and `delta` is the case's delta — the `<n>` in the case name (`<Producer>_to_ALU_delta_<n>`). `L` is a parameter, `delta` is the independent variable.

| Landmark | Column |
|---|---|
| Producer dispatch | T2 |
| Producer issue | T3 |
| Producer internal stages | T3 … T(2+`L`) |
| Producer P3 (`WB`) | **T(3+`L`)** |
| Producer P4 (`C`) | T(4+`L`) |
| Producer ARF-ready | T(5+`L`) |
| **Dependent dispatch** (= its P1 attempt) | **T(2+`delta`)** |
| **Dependent issue** | **`max(T(3+`L`), T(3+`delta`))`** — the producer's P3, or one cycle after the dependent's own dispatch, whichever is later |
| Dependent `WB` / `C` | issue + 1 / issue + 2 |

ARF takes one cycle: a commit at `C` is readable at `C`+1.

The mechanism label is a function of `delta` and `L`, and it is what makes the two dependent columns line up:

| Condition | Label |
|---|---|
| `delta` = 0 | `overlay` |
| 1 ≤ `delta` ≤ `L` | `wait_for_p3` |
| `delta` = `L`+1 | `p3_capture` |
| `delta` = `L`+2 | `p4_capture` |
| `delta` = `L`+3 | `arf_read` |

The enumerated range is `0 … L+3`, i.e. `L+4` cases per family.

## Bypass paths, and where they can be consumed

Each bus carries **only** the value published in that cycle; nothing is held. A dependent whose P1 misses the producer's P3 cycle **cannot go back for it**: the next opportunity is the commit CDB, and after that the ARF.

| Bus (valid only in that cycle) | Consumer stage in that cycle | Use | Issues |
|---|---|---|---|
| P3 bypass, 4 lanes | P1 | captured into the new ISQ payload (the entry becomes ready) | next cycle |
| P3 bypass, 4 lanes | P2 (resident) | resident wakeup; feeds the FU input directly | that cycle |
| P4 commit CDB, 2 lanes | P1 | captured into the new ISQ payload | next cycle |
| P4 commit CDB, 2 lanes | P2 | **not connected** | — |
| ARF | P1, after the producer has committed | read from the ARF read ports | next cycle |

That one-cycle window is what the delta ladder enumerates: `delta` places the dependent's P1 relative to the producer's P3 / P4, and the case label follows from which window it lands in.

If a resident entry matches a P3 source in P2 but the selected FU cannot issue in that cycle, the matched data is latched at the clock edge, so from the next cycle the entry is `Stored Ready` and needs no further forwarding — it is not lost.

## Case 1: ALU_to_ALU_delta_0 (overlay)

**Dimension:** INT single-operand dependency | **Equiv:** ALU_to_ALU
**Description:** Same-bundle rename overlay gives the dependent the producer tag; the resident dependent waits for P3 forwarding.

| Instruction | T1 | T2 | T3 | T4 | T5 | T6 | T7 | T8 |
|:---|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|
| `add x5, x1, x2` - Producer-G0 | IB | dispatch | ALU0 | WB | C |  |  |  |
| `add x6, x5, x3` - Dependent-G1 | IB | dispatch | ISQ Wait | ALU1 | WB | C |  |  |

- **T2 (Producer dispatch):** producer enters its group-local ISQ; normal boundaries are P3 at T4, P4 at T5, and ARF-ready at T6.
- **T2 (Rename overlay):** dependent is accepted in the same dispatch bundle and carries the newly allocated producer tag.
- **T4 (Resident wakeup, P3 → P2 bypass):** the P3 bypass satisfies the stored `wait_tag` and feeds the FU input directly; if the selected FU is free, the dependent issues in that cycle.

## Case 2: ALU_to_ALU_delta_1 (wait_for_p3)

**Dimension:** INT single-operand dependency | **Equiv:** ALU_to_ALU
**Description:** Dependent dispatches before producer P3, stores the `wait_tag` in ISQ, then wakes through resident-entry forwarding.

| Instruction | T1 | T2 | T3 | T4 | T5 | T6 | T7 | T8 |
|:---|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|
| `sub x5, x3, x4` - Producer-G0 | IB | dispatch | ALU0 | WB | C |  |  |  |
| `add x6, x5, x7` - Dependent-G0 |  | IB | dispatch | ALU0 | WB | C |  |  |

- **T2 (Producer dispatch):** producer enters its group-local ISQ; normal boundaries are P3 at T4, P4 at T5, and ARF-ready at T6.
- **T3 (Wait-tag dispatch):** dependent enters dispatch before producer P3 and waits resident in ISQ until the P3 forwarding match.
- **T4 (Resident wakeup, P3 → P2 bypass):** the P3 bypass satisfies the stored `wait_tag` and feeds the FU input directly; if the selected FU is free, the dependent issues in that cycle.

## Case 3: ALU_to_ALU_delta_2 (p3_capture)

**Dimension:** INT single-operand dependency | **Equiv:** ALU_to_ALU
**Description:** Dependent first P1 attempt exactly matches producer P3 Bypass and writes a ready ISQ payload.

| Instruction | T1 | T2 | T3 | T4 | T5 | T6 | T7 | T8 |
|:---|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|
| `add x5, x1, x2` - Producer-G0 | IB | dispatch | ALU0 | WB | C |  |  |  |
| `add x6, x5, x3` - Dependent-G0 |  |  | IB | dispatch | ALU0 | WB | C |  |

- **T2 (Producer dispatch):** producer enters its group-local ISQ; normal boundaries are P3 at T4, P4 at T5, and ARF-ready at T6.
- **T4 (P3 capture, P3 → P1 bypass):** the dependent's P1 sees the producer's P3 bypass and captures the data into a new ready ISQ payload.
- **T5 (Issue):** the dependent issues one cycle after ready payload construction.

## Case 4: ALU_to_ALU_delta_3 (p4_capture)

**Dimension:** INT single-operand dependency | **Equiv:** ALU_to_ALU
**Description:** Dependent first P1 attempt exactly matches producer P4 Commit CDB and writes a ready ISQ payload.

| Instruction | T1 | T2 | T3 | T4 | T5 | T6 | T7 | T8 |
|:---|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|
| `add x5, x1, x2` - Producer-G0 | IB | dispatch | ALU0 | WB | C |  |  |  |
| `add x6, x5, x3` - Dependent-G0 |  |  |  | IB | dispatch | ALU0 | WB | C |

- **T2 (Producer dispatch):** producer enters its group-local ISQ; normal boundaries are P3 at T4, P4 at T5, and ARF-ready at T6.
- **T5 (P4 capture, P4 → P1 bypass):** the dependent's P1 captures the Commit CDB data through the P4 → P1 path; this also suppresses the completed-in-Buffer stall path.
- **T6 (Issue):** the dependent issues one cycle after ready payload construction.

## Case 5: ALU_to_ALU_delta_4 (arf_read)

**Dimension:** INT single-operand dependency | **Equiv:** ALU_to_ALU
**Description:** Producer has already committed before dependent P1, so the source is read from ARF.

| Instruction | T1 | T2 | T3 | T4 | T5 | T6 | T7 | T8 | T9 |
|:---|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|
| `add x5, x1, x2` - Producer-G0 | IB | dispatch | ALU0 | WB | C |  |  |  |  |
| `add x6, x5, x3` - Dependent-G0 |  |  |  |  | IB | dispatch | ALU0 | WB | C |

- **T2 (Producer dispatch):** producer enters its group-local ISQ; normal boundaries are P3 at T4, P4 at T5, and ARF-ready at T6.
- **T6 (ARF read, no bypass):** the producer has committed and its mapping is no longer busy, so the dependent reads architectural data from ARF at P1.
- **T7 (Issue):** the dependent issues one cycle after ready payload construction.

## Case 6: MUL_to_ALU_delta_0 (overlay)

**Dimension:** INT single-operand dependency | **Equiv:** MUL_to_ALU
**Description:** Same-bundle rename overlay gives the dependent the producer tag; the resident dependent waits for P3 forwarding.

| Instruction | T1 | T2 | T3 | T4 | T5 | T6 | T7 | T8 |
|:---|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|
| `mul x5, x1, x2` - Producer-G1 | IB | dispatch | MUL | MUL | MUL | WB | C |  |
| `add x6, x5, x3` - Dependent-G0 | IB | dispatch | ISQ Wait | ISQ Wait | ISQ Wait | ALU0 | WB | C |

- **T2 (Producer dispatch):** producer enters its group-local ISQ; normal boundaries are P3 at T6, P4 at T7, and ARF-ready at T8.
- **T2 (Rename overlay):** dependent is accepted in the same dispatch bundle and carries the newly allocated producer tag.
- **T6 (Resident wakeup, P3 → P2 bypass):** the P3 bypass satisfies the stored `wait_tag` and feeds the FU input directly; if the selected FU is free, the dependent issues in that cycle.

## Case 7: MUL_to_ALU_delta_1 (wait_for_p3)

**Dimension:** INT single-operand dependency | **Equiv:** MUL_to_ALU
**Description:** Dependent dispatches before producer P3, stores the `wait_tag` in ISQ, then wakes through resident-entry forwarding.

| Instruction | T1 | T2 | T3 | T4 | T5 | T6 | T7 | T8 |
|:---|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|
| `mul x5, x3, x4` - Producer-G1 | IB | dispatch | MUL | MUL | MUL | WB | C |  |
| `add x7, x5, x8` - Dependent-G0 |  | IB | dispatch | ISQ Wait | ISQ Wait | ALU0 | WB | C |

- **T2 (Producer dispatch):** producer enters its group-local ISQ; normal boundaries are P3 at T6, P4 at T7, and ARF-ready at T8.
- **T3 (Wait-tag dispatch):** dependent enters dispatch before producer P3 and waits resident in ISQ until the P3 forwarding match.
- **T6 (Resident wakeup, P3 → P2 bypass):** the P3 bypass satisfies the stored `wait_tag` and feeds the FU input directly; if the selected FU is free, the dependent issues in that cycle.

## Case 8: MUL_to_ALU_delta_2 (wait_for_p3)

**Dimension:** INT single-operand dependency | **Equiv:** MUL_to_ALU
**Description:** Dependent dispatches before producer P3, stores the `wait_tag` in ISQ, then wakes through resident-entry forwarding.

| Instruction | T1 | T2 | T3 | T4 | T5 | T6 | T7 | T8 |
|:---|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|
| `mul x5, x1, x2` - Producer-G1 | IB | dispatch | MUL | MUL | MUL | WB | C |  |
| `add x6, x5, x3` - Dependent-G0 |  |  | IB | dispatch | ISQ Wait | ALU0 | WB | C |

- **T2 (Producer dispatch):** producer enters its group-local ISQ; normal boundaries are P3 at T6, P4 at T7, and ARF-ready at T8.
- **T4 (Wait-tag dispatch):** dependent enters dispatch before producer P3 and waits resident in ISQ until the P3 forwarding match.
- **T6 (Resident wakeup, P3 → P2 bypass):** the P3 bypass satisfies the stored `wait_tag` and feeds the FU input directly; if the selected FU is free, the dependent issues in that cycle.

## Case 9: MUL_to_ALU_delta_3 (wait_for_p3)

**Dimension:** INT single-operand dependency | **Equiv:** MUL_to_ALU
**Description:** Dependent dispatches before producer P3, stores the `wait_tag` in ISQ, then wakes through resident-entry forwarding.

| Instruction | T1 | T2 | T3 | T4 | T5 | T6 | T7 | T8 |
|:---|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|
| `mul x5, x1, x2` - Producer-G1 | IB | dispatch | MUL | MUL | MUL | WB | C |  |
| `add x6, x5, x3` - Dependent-G0 |  |  |  | IB | dispatch | ALU0 | WB | C |

- **T2 (Producer dispatch):** producer enters its group-local ISQ; normal boundaries are P3 at T6, P4 at T7, and ARF-ready at T8.
- **T5 (Wait-tag dispatch):** dependent enters dispatch before producer P3 and waits resident in ISQ until the P3 forwarding match.
- **T6 (Resident wakeup, P3 → P2 bypass):** the P3 bypass satisfies the stored `wait_tag` and feeds the FU input directly; if the selected FU is free, the dependent issues in that cycle.

## Case 10: MUL_to_ALU_delta_4 (p3_capture)

**Dimension:** INT single-operand dependency | **Equiv:** MUL_to_ALU
**Description:** Dependent first P1 attempt exactly matches producer P3 Bypass and writes a ready ISQ payload.

| Instruction | T1 | T2 | T3 | T4 | T5 | T6 | T7 | T8 | T9 |
|:---|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|
| `mul x5, x1, x2` - Producer-G1 | IB | dispatch | MUL | MUL | MUL | WB | C |  |  |
| `add x6, x5, x3` - Dependent-G0 |  |  |  |  | IB | dispatch | ALU0 | WB | C |

- **T2 (Producer dispatch):** producer enters its group-local ISQ; normal boundaries are P3 at T6, P4 at T7, and ARF-ready at T8.
- **T6 (P3 capture, P3 → P1 bypass):** the dependent's P1 sees the producer's P3 bypass and captures the data into a new ready ISQ payload.
- **T7 (Issue):** the dependent issues one cycle after ready payload construction.

## Case 11: MUL_to_ALU_delta_5 (p4_capture)

**Dimension:** INT single-operand dependency | **Equiv:** MUL_to_ALU
**Description:** Dependent first P1 attempt exactly matches producer P4 Commit CDB and writes a ready ISQ payload.

| Instruction | T1 | T2 | T3 | T4 | T5 | T6 | T7 | T8 | T9 | T10 |
|:---|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|
| `mul x5, x1, x2` - Producer-G1 | IB | dispatch | MUL | MUL | MUL | WB | C |  |  |  |
| `add x6, x5, x3` - Dependent-G0 |  |  |  |  |  | IB | dispatch | ALU0 | WB | C |

- **T2 (Producer dispatch):** producer enters its group-local ISQ; normal boundaries are P3 at T6, P4 at T7, and ARF-ready at T8.
- **T7 (P4 capture, P4 → P1 bypass):** the dependent's P1 captures the Commit CDB data through the P4 → P1 path; this also suppresses the completed-in-Buffer stall path.
- **T8 (Issue):** the dependent issues one cycle after ready payload construction.

## Case 12: MUL_to_ALU_delta_6 (arf_read)

**Dimension:** INT single-operand dependency | **Equiv:** MUL_to_ALU
**Description:** Producer has already committed before dependent P1, so the source is read from ARF.

| Instruction | T1 | T2 | T3 | T4 | T5 | T6 | T7 | T8 | T9 | T10 | T11 |
|:---|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|
| `mul x5, x1, x2` - Producer-G1 | IB | dispatch | MUL | MUL | MUL | WB | C |  |  |  |  |
| `add x6, x5, x3` - Dependent-G0 |  |  |  |  |  |  | IB | dispatch | ALU0 | WB | C |

- **T2 (Producer dispatch):** producer enters its group-local ISQ; normal boundaries are P3 at T6, P4 at T7, and ARF-ready at T8.
- **T8 (ARF read, no bypass):** the producer has committed and its mapping is no longer busy, so the dependent reads architectural data from ARF at P1.
- **T9 (Issue):** the dependent issues one cycle after ready payload construction.

## Case 13: DIV_to_ALU_delta_0 (overlay)

**Dimension:** INT single-operand dependency | **Equiv:** DIV_to_ALU
**Description:** Same-bundle rename overlay gives the dependent the producer tag; the resident dependent waits for P3 forwarding.

| Instruction | T1 | T2 | T3 | T4 | T5 | T6 | T7 | T8 | T9 |
|:---|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|
| `div x5, x1, x2` - Producer-G0 | IB | dispatch | DIV | DIV | DIV | DIV | WB | C |  |
| `add x6, x5, x3` - Dependent-G1 | IB | dispatch | ISQ Wait | ISQ Wait | ISQ Wait | ISQ Wait | ALU1 | WB | C |

- **T2 (Producer dispatch):** producer enters its group-local ISQ; normal boundaries are P3 at T7, P4 at T8, and ARF-ready at T9.
- **T2 (Rename overlay):** dependent is accepted in the same dispatch bundle and carries the newly allocated producer tag.
- **T7 (Resident wakeup, P3 → P2 bypass):** the P3 bypass satisfies the stored `wait_tag` and feeds the FU input directly; if the selected FU is free, the dependent issues in that cycle.

## Case 14: DIV_to_ALU_delta_1 (wait_for_p3)

**Dimension:** INT single-operand dependency | **Equiv:** DIV_to_ALU
**Description:** Dependent dispatches before producer P3, stores the `wait_tag` in ISQ, then wakes through resident-entry forwarding.

| Instruction | T1 | T2 | T3 | T4 | T5 | T6 | T7 | T8 | T9 |
|:---|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|
| `div x5, x3, x4` - Producer-G0 | IB | dispatch | DIV | DIV | DIV | DIV | WB | C |  |
| `add x7, x5, x8` - Dependent-G0 |  | IB | dispatch | ISQ Wait | ISQ Wait | ISQ Wait | ALU0 | WB | C |

- **T2 (Producer dispatch):** producer enters its group-local ISQ; normal boundaries are P3 at T7, P4 at T8, and ARF-ready at T9.
- **T3 (Wait-tag dispatch):** dependent enters dispatch before producer P3 and waits resident in ISQ until the P3 forwarding match.
- **T7 (Resident wakeup, P3 → P2 bypass):** the P3 bypass satisfies the stored `wait_tag` and feeds the FU input directly; if the selected FU is free, the dependent issues in that cycle.

## Case 15: DIV_to_ALU_delta_2 (wait_for_p3)

**Dimension:** INT single-operand dependency | **Equiv:** DIV_to_ALU
**Description:** Dependent dispatches before producer P3, stores the `wait_tag` in ISQ, then wakes through resident-entry forwarding.

| Instruction | T1 | T2 | T3 | T4 | T5 | T6 | T7 | T8 | T9 |
|:---|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|
| `div x5, x1, x2` - Producer-G0 | IB | dispatch | DIV | DIV | DIV | DIV | WB | C |  |
| `add x6, x5, x3` - Dependent-G0 |  |  | IB | dispatch | ISQ Wait | ISQ Wait | ALU0 | WB | C |

- **T2 (Producer dispatch):** producer enters its group-local ISQ; normal boundaries are P3 at T7, P4 at T8, and ARF-ready at T9.
- **T4 (Wait-tag dispatch):** dependent enters dispatch before producer P3 and waits resident in ISQ until the P3 forwarding match.
- **T7 (Resident wakeup, P3 → P2 bypass):** the P3 bypass satisfies the stored `wait_tag` and feeds the FU input directly; if the selected FU is free, the dependent issues in that cycle.

## Case 16: DIV_to_ALU_delta_3 (wait_for_p3)

**Dimension:** INT single-operand dependency | **Equiv:** DIV_to_ALU
**Description:** Dependent dispatches before producer P3, stores the `wait_tag` in ISQ, then wakes through resident-entry forwarding.

| Instruction | T1 | T2 | T3 | T4 | T5 | T6 | T7 | T8 | T9 |
|:---|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|
| `div x5, x1, x2` - Producer-G0 | IB | dispatch | DIV | DIV | DIV | DIV | WB | C |  |
| `add x6, x5, x3` - Dependent-G0 |  |  |  | IB | dispatch | ISQ Wait | ALU0 | WB | C |

- **T2 (Producer dispatch):** producer enters its group-local ISQ; normal boundaries are P3 at T7, P4 at T8, and ARF-ready at T9.
- **T5 (Wait-tag dispatch):** dependent enters dispatch before producer P3 and waits resident in ISQ until the P3 forwarding match.
- **T7 (Resident wakeup, P3 → P2 bypass):** the P3 bypass satisfies the stored `wait_tag` and feeds the FU input directly; if the selected FU is free, the dependent issues in that cycle.

## Case 17: DIV_to_ALU_delta_4 (wait_for_p3)

**Dimension:** INT single-operand dependency | **Equiv:** DIV_to_ALU
**Description:** Dependent dispatches before producer P3, stores the `wait_tag` in ISQ, then wakes through resident-entry forwarding.

| Instruction | T1 | T2 | T3 | T4 | T5 | T6 | T7 | T8 | T9 |
|:---|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|
| `div x5, x1, x2` - Producer-G0 | IB | dispatch | DIV | DIV | DIV | DIV | WB | C |  |
| `add x6, x5, x3` - Dependent-G0 |  |  |  |  | IB | dispatch | ALU0 | WB | C |

- **T2 (Producer dispatch):** producer enters its group-local ISQ; normal boundaries are P3 at T7, P4 at T8, and ARF-ready at T9.
- **T6 (Wait-tag dispatch):** dependent enters dispatch before producer P3 and waits resident in ISQ until the P3 forwarding match.
- **T7 (Resident wakeup, P3 → P2 bypass):** the P3 bypass satisfies the stored `wait_tag` and feeds the FU input directly; if the selected FU is free, the dependent issues in that cycle.

## Case 18: DIV_to_ALU_delta_5 (p3_capture)

**Dimension:** INT single-operand dependency | **Equiv:** DIV_to_ALU
**Description:** Dependent first P1 attempt exactly matches producer P3 Bypass and writes a ready ISQ payload.

| Instruction | T1 | T2 | T3 | T4 | T5 | T6 | T7 | T8 | T9 | T10 |
|:---|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|
| `div x5, x1, x2` - Producer-G0 | IB | dispatch | DIV | DIV | DIV | DIV | WB | C |  |  |
| `add x6, x5, x3` - Dependent-G0 |  |  |  |  |  | IB | dispatch | ALU0 | WB | C |

- **T2 (Producer dispatch):** producer enters its group-local ISQ; normal boundaries are P3 at T7, P4 at T8, and ARF-ready at T9.
- **T7 (P3 capture, P3 → P1 bypass):** the dependent's P1 sees the producer's P3 bypass and captures the data into a new ready ISQ payload.
- **T8 (Issue):** the dependent issues one cycle after ready payload construction.

## Case 19: DIV_to_ALU_delta_6 (p4_capture)

**Dimension:** INT single-operand dependency | **Equiv:** DIV_to_ALU
**Description:** Dependent first P1 attempt exactly matches producer P4 Commit CDB and captures `commit_data`.

| Instruction | T1 | T2 | T3 | T4 | T5 | T6 | T7 | T8 | T9 | T10 | T11 |
|:---|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|
| `div x5, x1, x2` - Producer-G0 | IB | dispatch | DIV | DIV | DIV | DIV | WB | C |  |  |  |
| `add x6, x5, x3` - Dependent-G0 |  |  |  |  |  |  | IB | dispatch | ALU0 | WB | C |

- **T2 (Producer dispatch):** producer enters its group-local ISQ; normal boundaries are P3 at T7, P4 at T8, and ARF-ready at T9.
- **T8 (P4 capture, P4 → P1 bypass):** the dependent's P1 captures the Commit CDB data through the P4 → P1 path; this also suppresses the completed-in-Buffer stall path.
- **T9 (Issue):** the dependent issues one cycle after ready payload construction.

## Case 20: DIV_to_ALU_delta_7 (arf_read)

**Dimension:** INT single-operand dependency | **Equiv:** DIV_to_ALU
**Description:** Producer has already committed before dependent P1, so the source is read from ARF.

| Instruction | T1 | T2 | T3 | T4 | T5 | T6 | T7 | T8 | T9 | T10 | T11 | T12 |
|:---|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|
| `div x5, x1, x2` - Producer-G0 | IB | dispatch | DIV | DIV | DIV | DIV | WB | C |  |  |  |  |
| `add x6, x5, x3` - Dependent-G0 |  |  |  |  |  |  |  | IB | dispatch | ALU0 | WB | C |

- **T2 (Producer dispatch):** producer enters its group-local ISQ; normal boundaries are P3 at T7, P4 at T8, and ARF-ready at T9.
- **T9 (ARF read, no bypass):** the producer has committed and its mapping is no longer busy, so the dependent reads architectural data from ARF at P1.
- **T10 (Issue):** the dependent issues one cycle after ready payload construction.

## Case 21: LOAD_to_ALU_delta_0 (overlay)

**Dimension:** INT single-operand dependency | **Equiv:** LOAD_to_ALU
**Description:** Same-bundle rename overlay gives the dependent the producer tag; the resident dependent waits for P3 forwarding.

| Instruction | T1 | T2 | T3 | T4 | T5 | T6 | T7 | T8 |
|:---|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|
| `ld x5, 0(x1)` - Producer-G3 | IB | dispatch | AGU | L1D | LDA+CDB | WB | C |  |
| `add x6, x5, x3` - Dependent-G0 | IB | dispatch | ISQ Wait | ISQ Wait | ISQ Wait | ALU0 | WB | C |

- **T2 (Producer dispatch):** producer enters its group-local ISQ; normal boundaries are P3 at T6, P4 at T7, and ARF-ready at T8.
- **T2 (Rename overlay):** dependent is accepted in the same dispatch bundle and carries the newly allocated producer tag.
- **T6 (Resident wakeup, P3 → P2 bypass):** the P3 bypass satisfies the stored `wait_tag` and feeds the FU input directly; if the selected FU is free, the dependent issues in that cycle.

## Case 22: LOAD_to_ALU_delta_1 (wait_for_p3)

**Dimension:** INT single-operand dependency | **Equiv:** LOAD_to_ALU
**Description:** Dependent dispatches before producer P3, stores the `wait_tag` in ISQ, then wakes through resident-entry forwarding.

| Instruction | T1 | T2 | T3 | T4 | T5 | T6 | T7 | T8 |
|:---|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|
| `lw x5, 8(x2)` - Producer-G3 | IB | dispatch | AGU | L1D | LDA+CDB | WB | C |  |
| `add x7, x5, x8` - Dependent-G0 |  | IB | dispatch | ISQ Wait | ISQ Wait | ALU0 | WB | C |

- **T2 (Producer dispatch):** producer enters its group-local ISQ; normal boundaries are P3 at T6, P4 at T7, and ARF-ready at T8.
- **T3 (Wait-tag dispatch):** dependent enters dispatch before producer P3 and waits resident in ISQ until the P3 forwarding match.
- **T6 (Resident wakeup, P3 → P2 bypass):** the P3 bypass satisfies the stored `wait_tag` and feeds the FU input directly; if the selected FU is free, the dependent issues in that cycle.

## Case 23: LOAD_to_ALU_delta_2 (wait_for_p3)

**Dimension:** INT single-operand dependency | **Equiv:** LOAD_to_ALU
**Description:** Dependent dispatches before producer P3, stores the `wait_tag` in ISQ, then wakes through resident-entry forwarding.

| Instruction | T1 | T2 | T3 | T4 | T5 | T6 | T7 | T8 |
|:---|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|
| `ld x5, 0(x1)` - Producer-G3 | IB | dispatch | AGU | L1D | LDA+CDB | WB | C |  |
| `add x6, x5, x3` - Dependent-G0 |  |  | IB | dispatch | ISQ Wait | ALU0 | WB | C |

- **T2 (Producer dispatch):** producer enters its group-local ISQ; normal boundaries are P3 at T6, P4 at T7, and ARF-ready at T8.
- **T4 (Wait-tag dispatch):** dependent enters dispatch before producer P3 and waits resident in ISQ until the P3 forwarding match.
- **T6 (Resident wakeup, P3 → P2 bypass):** the P3 bypass satisfies the stored `wait_tag` and feeds the FU input directly; if the selected FU is free, the dependent issues in that cycle.

## Case 24: LOAD_to_ALU_delta_3 (wait_for_p3)

**Dimension:** INT single-operand dependency | **Equiv:** LOAD_to_ALU
**Description:** Dependent dispatches before producer P3, stores the `wait_tag` in ISQ, then wakes through resident-entry forwarding.

| Instruction | T1 | T2 | T3 | T4 | T5 | T6 | T7 | T8 |
|:---|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|
| `ld x5, 0(x1)` - Producer-G3 | IB | dispatch | AGU | L1D | LDA+CDB | WB | C |  |
| `add x6, x5, x3` - Dependent-G0 |  |  |  | IB | dispatch | ALU0 | WB | C |

- **T2 (Producer dispatch):** producer enters its group-local ISQ; normal boundaries are P3 at T6, P4 at T7, and ARF-ready at T8.
- **T5 (Wait-tag dispatch):** dependent enters dispatch before producer P3 and waits resident in ISQ until the P3 forwarding match.
- **T6 (Resident wakeup, P3 → P2 bypass):** the P3 bypass satisfies the stored `wait_tag` and feeds the FU input directly; if the selected FU is free, the dependent issues in that cycle.

## Case 25: LOAD_to_ALU_delta_4 (p3_capture)

**Dimension:** INT single-operand dependency | **Equiv:** LOAD_to_ALU
**Description:** Dependent first P1 attempt exactly matches producer P3 Bypass and writes a ready ISQ payload.

| Instruction | T1 | T2 | T3 | T4 | T5 | T6 | T7 | T8 | T9 |
|:---|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|
| `ld x5, 0(x1)` - Producer-G3 | IB | dispatch | AGU | L1D | LDA+CDB | WB | C |  |  |
| `add x6, x5, x3` - Dependent-G0 |  |  |  |  | IB | dispatch | ALU0 | WB | C |

- **T2 (Producer dispatch):** producer enters its group-local ISQ; normal boundaries are P3 at T6, P4 at T7, and ARF-ready at T8.
- **T6 (P3 capture, P3 → P1 bypass):** the dependent's P1 sees the producer's P3 bypass and captures the data into a new ready ISQ payload.
- **T7 (Issue):** the dependent issues one cycle after ready payload construction.

## Case 26: LOAD_to_ALU_delta_5 (p4_capture)

**Dimension:** INT single-operand dependency | **Equiv:** LOAD_to_ALU
**Description:** Dependent first P1 attempt exactly matches producer P4 Commit CDB and captures `commit_data`.

| Instruction | T1 | T2 | T3 | T4 | T5 | T6 | T7 | T8 | T9 | T10 |
|:---|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|
| `ld x5, 0(x1)` - Producer-G3 | IB | dispatch | AGU | L1D | LDA+CDB | WB | C |  |  |  |
| `add x6, x5, x3` - Dependent-G0 |  |  |  |  |  | IB | dispatch | ALU0 | WB | C |

- **T2 (Producer dispatch):** producer enters its group-local ISQ; normal boundaries are P3 at T6, P4 at T7, and ARF-ready at T8.
- **T7 (P4 capture, P4 → P1 bypass):** the dependent's P1 captures the Commit CDB data through the P4 → P1 path; this also suppresses the completed-in-Buffer stall path.
- **T8 (Issue):** the dependent issues one cycle after ready payload construction.

## Case 27: LOAD_to_ALU_delta_6 (arf_read)

**Dimension:** INT single-operand dependency | **Equiv:** LOAD_to_ALU
**Description:** Producer has already committed before dependent P1, so the source is read from ARF.

| Instruction | T1 | T2 | T3 | T4 | T5 | T6 | T7 | T8 | T9 | T10 | T11 |
|:---|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|
| `ld x5, 0(x1)` - Producer-G3 | IB | dispatch | AGU | L1D | LDA+CDB | WB | C |  |  |  |  |
| `add x6, x5, x3` - Dependent-G0 |  |  |  |  |  |  | IB | dispatch | ALU0 | WB | C |

- **T2 (Producer dispatch):** producer enters its group-local ISQ; normal boundaries are P3 at T6, P4 at T7, and ARF-ready at T8.
- **T8 (ARF read, no bypass):** the producer has committed and its mapping is no longer busy, so the dependent reads architectural data from ARF at P1.
- **T9 (Issue):** the dependent issues one cycle after ready payload construction.

## Case 28: JALR_to_ALU_delta_0 (overlay)

**Dimension:** INT single-operand dependency | **Equiv:** JALR_to_ALU
**Description:** Same-bundle rename overlay gives the dependent the producer tag; the resident dependent waits for P3 forwarding.

| Instruction | T1 | T2 | T3 | T4 | T5 | T6 |
|:---|:---:|:---:|:---:|:---:|:---:|:---:|
| `jalr x5, 0(x10)` - Producer-G0 | IB | dispatch | BRU | WB | C |  |
| `add x6, x5, x3` - Dependent-G1 | IB | dispatch | ISQ Wait | ALU1 | WB | C |

- **T2 (Producer dispatch):** producer enters its group-local ISQ; normal boundaries are P3 at T4, P4 at T5, and ARF-ready at T6.
- **T2 (Rename overlay):** dependent is accepted in the same dispatch bundle and carries the newly allocated producer tag.
- **T4 (Resident wakeup, P3 → P2 bypass):** the P3 bypass satisfies the stored `wait_tag` and feeds the FU input directly; if the selected FU is free, the dependent issues in that cycle.

## Case 29: JALR_to_ALU_delta_1 (wait_for_p3)

**Dimension:** INT single-operand dependency | **Equiv:** JALR_to_ALU
**Description:** Dependent dispatches before producer P3, stores the `wait_tag` in ISQ, then wakes through resident-entry forwarding.

| Instruction | T1 | T2 | T3 | T4 | T5 | T6 |
|:---|:---:|:---:|:---:|:---:|:---:|:---:|
| `jalr x5, 0(x10)` - Producer-G0 | IB | dispatch | BRU | WB | C |  |
| `add x7, x5, x8` - Dependent-G0 |  | IB | dispatch | ALU0 | WB | C |

- **T2 (Producer dispatch):** producer enters its group-local ISQ; normal boundaries are P3 at T4, P4 at T5, and ARF-ready at T6.
- **T3 (Wait-tag dispatch):** dependent enters dispatch before producer P3 and waits resident in ISQ until the P3 forwarding match.
- **T4 (Resident wakeup, P3 → P2 bypass):** the P3 bypass satisfies the stored `wait_tag` and feeds the FU input directly; if the selected FU is free, the dependent issues in that cycle.

## Case 30: JALR_to_ALU_delta_2 (p3_capture)

**Dimension:** INT single-operand dependency | **Equiv:** JALR_to_ALU
**Description:** Dependent first P1 attempt exactly matches producer P3 Bypass and writes a ready ISQ payload.

| Instruction | T1 | T2 | T3 | T4 | T5 | T6 | T7 |
|:---|:---:|:---:|:---:|:---:|:---:|:---:|:---:|
| `jalr x5, 0(x10)` - Producer-G0 | IB | dispatch | BRU | WB | C |  |  |
| `add x6, x5, x3` - Dependent-G0 |  |  | IB | dispatch | ALU0 | WB | C |

- **T2 (Producer dispatch):** producer enters its group-local ISQ; normal boundaries are P3 at T4, P4 at T5, and ARF-ready at T6.
- **T4 (P3 capture, P3 → P1 bypass):** the dependent's P1 sees the producer's P3 bypass and captures the data into a new ready ISQ payload.
- **T5 (Issue):** the dependent issues one cycle after ready payload construction.

## Case 31: JALR_to_ALU_delta_3 (p4_capture)

**Dimension:** INT single-operand dependency | **Equiv:** JALR_to_ALU
**Description:** Dependent first P1 attempt exactly matches producer P4 Commit CDB and captures `commit_data`.

| Instruction | T1 | T2 | T3 | T4 | T5 | T6 | T7 | T8 |
|:---|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|
| `jalr x5, 0(x10)` - Producer-G0 | IB | dispatch | BRU | WB | C |  |  |  |
| `add x6, x5, x3` - Dependent-G0 |  |  |  | IB | dispatch | ALU0 | WB | C |

- **T2 (Producer dispatch):** producer enters its group-local ISQ; normal boundaries are P3 at T4, P4 at T5, and ARF-ready at T6.
- **T5 (P4 capture, P4 → P1 bypass):** the dependent's P1 captures the Commit CDB data through the P4 → P1 path; this also suppresses the completed-in-Buffer stall path.
- **T6 (Issue):** the dependent issues one cycle after ready payload construction.

## Case 32: JALR_to_ALU_delta_4 (arf_read)

**Dimension:** INT single-operand dependency | **Equiv:** JALR_to_ALU
**Description:** Producer has already committed before dependent P1, so the source is read from ARF.

| Instruction | T1 | T2 | T3 | T4 | T5 | T6 | T7 | T8 | T9 |
|:---|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|
| `jalr x5, 0(x10)` - Producer-G0 | IB | dispatch | BRU | WB | C |  |  |  |  |
| `add x6, x5, x3` - Dependent-G0 |  |  |  |  | IB | dispatch | ALU0 | WB | C |

- **T2 (Producer dispatch):** producer enters its group-local ISQ; normal boundaries are P3 at T4, P4 at T5, and ARF-ready at T6.
- **T6 (ARF read, no bypass):** the producer has committed and its mapping is no longer busy, so the dependent reads architectural data from ARF at P1.
- **T7 (Issue):** the dependent issues one cycle after ready payload construction.

## Case 33: ALU_to_ALU_delta_3_p4blocked (p4_capture, commit held)

**Dimension:** INT single-operand dependency | **Equiv:** ALU_to_ALU
**Description:** The producer writes back on the nominal cycle but cannot commit, because an older instruction is still in flight and retirement is in order, so its result stays in the P3 Buffer. The dependent therefore finds no Commit CDB at its nominal P1 and must stall instead of capturing from P4.

| Instruction | T1 | T2 | T3 | T4 | T5 | T6 | T7 | T8 | T9 |
|:---|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|
| `div x7, x1, x2` - Blocker·G0 | IB | dispatch | DIV | DIV | DIV | DIV | WB | C |  |
| `add x5, x1, x2` - Producer·G1 |  | IB | dispatch | ALU1 | WB | C |  |  |  |
| `add x6, x5, x3` - Dependent·G1 |  |  |  |  | IB | dispatch | ALU1 | WB | C |

- **T1 (Blocker, one cycle ahead of the producer):** the older `div x7, x1, x2` is enqueued alone and routed
  to G0. Putting it one cycle earlier rather than beside the producer is not cosmetic: when both G0 and G1
  are taken in the producer's own enqueue cycle, the dependent's dispatch can only land on the cycles where
  its group's ISQ entry frees, and the delta quantises to 2 or 6 — 3 is unreachable. With the blocker ahead
  of it the producer and dependent share G1 and the dependent's dispatch is free to land on 3.
- **Producer WB at T4, on schedule:** the result enters the P3 Buffer in the nominal cycle. The writeback is
  not delayed; only the commit is.
- **T5 (Nominal P4 — no Commit CDB):** the older `div`, issued at T3 with L=4, retires no earlier than T8,
  and retirement is in order while writeback is not. The producer therefore sits in the Buffer, `P4 − P3`
  is greater than 1, and the dependent's P1 finds nothing to capture.
- **Expected deviation (the measured quantity):** the dependent stalls (Condition A) instead of capturing
  from P4, and resolves only after the producer retires.
- **Check on the run:** the producer's `P3 − P2` must equal `L` (writeback untroubled) while its `P4 − P3`
  exceeds 1 (commit held). If `P4 − P3` is 1 the blocker retired in time and the case missed its target
  state — report that rather than passing it.
## Case 34: MUL_to_ALU_delta_5_p4blocked (p4_capture, commit held)

**Dimension:** INT single-operand dependency | **Equiv:** MUL_to_ALU
**Description:** The producer writes back on the nominal cycle but cannot commit, because an older instruction is still in flight and retirement is in order, so its result stays in the P3 Buffer. The dependent therefore finds no Commit CDB at its nominal P1 and must stall instead of capturing from P4.

| Instruction | T1 | T2 | T3 | T4 | T5 | T6 | T7 | T8 | T9 | T10 |
|:---|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|
| `div x7, x1, x2` - Blocker·G0 | IB | dispatch | DIV | DIV | DIV | DIV | WB | C |  |  |
| `mul x5, x1, x2` - Producer-G1 | IB | dispatch | MUL | MUL | MUL | WB | C |  |  |  |
| `add x6, x5, x3` - Dependent-G1 |  |  |  |  |  | IB | dispatch | ALU1 | WB | C |

- **T1 (Blocker and producer enqueued together):** the older `div x7, x1, x2` is routed to G0 and the producer to the
  other ALU group, so the two take separate ISQ entries. The blocker is listed first so it lands in slot 0,
  which is what forces the flexible producer off G0.
- **Producer WB (on schedule):** the producer's result enters the P3 Buffer in the same cycle as the nominal
  figure. This is the point of the construction — the writeback is *not* delayed, only the commit is.
- **Nominal P4 (Commit CDB expected, does not appear):** the older `div x7, x1, x2` has not retired, and retirement is
  in order while writeback is not, so the producer stays in the Buffer. No Commit CDB is presented and a
  P4 → P1 capture is impossible in that cycle.
- **Expected deviation (this is what the case measures):** the dependent cannot capture. It stalls
  (Condition A) and resolves only after the producer retires; its resolution cycle and the path it finally
  uses are the measured quantities, not predictions.
- **Check on the run:** the producer's `P3 − P2` must still equal `L` (writeback untroubled) while its
  `P4 − P3` must be greater than 1 (commit held). If `P4 − P3` is 1 the blocker retired in time and the
  case did not reproduce the target state — report it rather than pass it.


## Case 35: DIV_to_ALU_delta_6_p4blocked (p4_capture, commit held)

**Dimension:** INT single-operand dependency | **Equiv:** DIV_to_ALU
**Description:** The producer writes back on the nominal cycle but cannot commit, because an older instruction is still in flight and retirement is in order, so its result stays in the P3 Buffer. The dependent therefore finds no Commit CDB at its nominal P1 and must stall instead of capturing from P4.

| Instruction | T1 | T2 | T3 | T4 | T5 | T6 | T7 | T8 | T9 | T10 | T11 |
|:---|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|
| `mul x7, x1, x2` - Blocker·G1 | IB | dispatch | MUL | MUL | MUL | WB | C |  |  |  |  |
| `div x5, x1, x2` - Producer-G0 | IB | dispatch | DIV | DIV | DIV | DIV | WB | C |  |  |  |
| `add x6, x5, x3` - Dependent-G0 |  |  |  |  |  |  | IB | dispatch | ALU0 | WB | C |

- **T1 (Blocker and producer enqueued together):** the older `mul x7, x1, x2` is routed to G1 and the producer to the
  other ALU group, so the two take separate ISQ entries. The blocker is listed first so it lands in slot 0,
  which is what forces the flexible producer off G1.
- **Producer WB (on schedule):** the producer's result enters the P3 Buffer in the same cycle as the nominal
  figure. This is the point of the construction — the writeback is *not* delayed, only the commit is.
- **Nominal P4 (Commit CDB expected, does not appear):** the older `mul x7, x1, x2` has not retired, and retirement is
  in order while writeback is not, so the producer stays in the Buffer. No Commit CDB is presented and a
  P4 → P1 capture is impossible in that cycle.
- **Expected deviation (this is what the case measures):** the dependent cannot capture. It stalls
  (Condition A) and resolves only after the producer retires; its resolution cycle and the path it finally
  uses are the measured quantities, not predictions.
- **Check on the run:** the producer's `P3 − P2` must still equal `L` (writeback untroubled) while its
  `P4 − P3` must be greater than 1 (commit held). If `P4 − P3` is 1 the blocker retired in time and the
  case did not reproduce the target state — report it rather than pass it.


## Case 36: LOAD_to_ALU_delta_5_p4blocked (p4_capture, commit held)

**Dimension:** INT single-operand dependency | **Equiv:** LOAD_to_ALU
**Description:** The producer writes back on the nominal cycle but cannot commit, because an older instruction is still in flight and retirement is in order, so its result stays in the P3 Buffer. The dependent therefore finds no Commit CDB at its nominal P1 and must stall instead of capturing from P4.

| Instruction | T1 | T2 | T3 | T4 | T5 | T6 | T7 | T8 | T9 | T10 |
|:---|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|
| `div x7, x1, x2` - Blocker·G0 | IB | dispatch | DIV | DIV | DIV | DIV | WB | C |  |  |
| `ld x5, 0(x1)` - Producer-G3 | IB | dispatch | AGU | L1D | LDA+CDB | WB | C |  |  |  |
| `add x6, x5, x3` - Dependent-G1 |  |  |  |  |  | IB | dispatch | ALU1 | WB | C |

- **T1 (Blocker and producer enqueued together):** the older `div x7, x1, x2` is routed to G0 and the producer to the
  other ALU group, so the two take separate ISQ entries. The blocker is listed first so it lands in slot 0,
  which is what forces the flexible producer off G0.
- **Producer WB (on schedule):** the producer's result enters the P3 Buffer in the same cycle as the nominal
  figure. This is the point of the construction — the writeback is *not* delayed, only the commit is.
- **Nominal P4 (Commit CDB expected, does not appear):** the older `div x7, x1, x2` has not retired, and retirement is
  in order while writeback is not, so the producer stays in the Buffer. No Commit CDB is presented and a
  P4 → P1 capture is impossible in that cycle.
- **Expected deviation (this is what the case measures):** the dependent cannot capture. It stalls
  (Condition A) and resolves only after the producer retires; its resolution cycle and the path it finally
  uses are the measured quantities, not predictions.
- **Check on the run:** the producer's `P3 − P2` must still equal `L` (writeback untroubled) while its
  `P4 − P3` must be greater than 1 (commit held). If `P4 − P3` is 1 the blocker retired in time and the
  case did not reproduce the target state — report it rather than pass it.


## Case 37: JALR_to_ALU_delta_3_p4blocked (p4_capture, commit held)

**Dimension:** INT single-operand dependency | **Equiv:** JALR_to_ALU
**Description:** The producer writes back on the nominal cycle but cannot commit, because an older instruction is still in flight and retirement is in order, so its result stays in the P3 Buffer. The dependent therefore finds no Commit CDB at its nominal P1 and must stall instead of capturing from P4.

| Instruction | T1 | T2 | T3 | T4 | T5 | T6 | T7 | T8 |
|:---|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|
| `mul x7, x1, x2` - Blocker·G1 | IB | dispatch | MUL | MUL | MUL | WB | C |  |
| `jalr x5, 0(x10)` - Producer-G0 | IB | dispatch | BRU | WB | C |  |  |  |
| `add x6, x5, x3` - Dependent-G0 |  |  |  | IB | dispatch | ALU0 | WB | C |

- **T1 (Blocker and producer enqueued together):** the older `mul x7, x1, x2` is routed to G1 and the producer to the
  other ALU group, so the two take separate ISQ entries. The blocker is listed first so it lands in slot 0,
  which is what forces the flexible producer off G1.
- **Producer WB (on schedule):** the producer's result enters the P3 Buffer in the same cycle as the nominal
  figure. This is the point of the construction — the writeback is *not* delayed, only the commit is.
- **Nominal P4 (Commit CDB expected, does not appear):** the older `mul x7, x1, x2` has not retired, and retirement is
  in order while writeback is not, so the producer stays in the Buffer. No Commit CDB is presented and a
  P4 → P1 capture is impossible in that cycle.
- **Expected deviation (this is what the case measures):** the dependent cannot capture. It stalls
  (Condition A) and resolves only after the producer retires; its resolution cycle and the path it finally
  uses are the measured quantities, not predictions.
- **Check on the run:** the producer's `P3 − P2` must still equal `L` (writeback untroubled) while its
  `P4 − P3` must be greater than 1 (commit held). If `P4 − P3` is 1 the blocker retired in time and the
  case did not reproduce the target state — report it rather than pass it.
