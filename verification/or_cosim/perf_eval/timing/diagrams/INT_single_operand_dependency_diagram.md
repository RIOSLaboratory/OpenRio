# INT Single-Operand Dependency Timing Diagrams

<style>
table { display: block; overflow-x: auto; width: 100%; }
th, td { white-space: nowrap !important; }
</style>

Source caselist: `../caselists/INT_single_operand_dependency_caselist_v1.md`

Normative timing source: pending promotion to `spec/or-be/`.

This diagram set is the reduced INT single-operand v2 set: one representative INT consumer per producer latency family. LOAD/STORE dependent cases moved to MEM/LSU operand K-maps; non-MEM INT dependent classes are covered by the representative `*_to_ALU` rows.

Scope note: these figures show the nominal no-older-blocker path. Condition A extensions caused by delayed P4 commit are derived from the spec and are not repeated as separate nominal figures.

JALR/JAL with `rd != x0` is retained as the BRU-issued 1-cycle producer representative. The
single-operand K-map records the POI as "JAL/JALR with rd != x0: register-result producer exists,
covered by ALU/BRU 1-cycle producer POI." Its `L = 1` makes the delta ladder numerically identical
to `ALU_to_ALU`, but the rows exercise the BRU result path rather than the ALU result path.

> **Landmark precondition (added with the `*_p4blocked` cases).** The rows above place `WB` at `T(3+L)` and
> `C` at `T(4+L)`, and the `p4_capture` rung is defined as "the dependent's P1 lands on the producer's P4".
> Both assume the producer is already at the commit head when it writes back. Retirement is in order while
> writeback is not, so when an older instruction is still in flight the producer's `C` slides, `P4 − P3 > 1`,
> and the nominal `p4_capture` becomes unreachable — the dependent stalls instead. The five `*_p4blocked`
> cases exist to exercise exactly that condition; they are a separate class, not a re-run of the nominal rung.

## Stage mapping

The pipeline is the five-stage BE model (see `../../../docs/BE/or_be_has_V1.0.md` §5). Each cell is written as `[ owner ]` followed by optional state and action/result lines (see `RULES_GENERAL.md` G2–G6). The owner line is one of these:

| Owner | Stage | Meaning |
|---|---|---|
| `[ IB ]` | **P0** | The instruction is enqueued into the instruction buffer; the action is `enqueue instruction`. |
| `[ dispatch ]` | **P1** | The group's ISQ entry is written; actions are `allocate **scoreboard** entry`, `write **ISQ_Groupx**`, `rename rd`, plus capture when a source is ready. `delta` is the difference between two `dispatch` owners. |
| `[ ISQ_Groupx ]` | **P2** | Resident in the ISQ; the action is `wait for ...` until the source arrives. |
| `[ ALU0 ]` / `[ ALU1 ]` / `[ MUL ]` / `[ DIV ]` / `[ BRU ]` / `[ AGU ]` / `[ L1D ]` | **P2** | The FU is executing; the first such owner is the issue-accepted cycle, and a multi-cycle FU carries a step action (`divide step n/8`). LOAD is `[ AGU ]` → `[ L1D ]`. |
| `[ WB ]` | **P3** | Result writeback / bypass broadcast; actions are `drive Bypass[g] tag+data`, `**scoreboard** set exec_done`, `**Buffer** write result`. |
| `[ Buffer ]` | **P3 hold** | The result is written back but cannot commit; state `hold`, action `wait for commit`. |
| `[ C ]` | **P4** | Commit; **scoreboard** resolves the head, **INT_ARF** writes `rd`, **INT_tag_mapping** clears busy. |

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
| `Bypass[g]`, 4 group lanes | P1 | captured into the new ISQ payload (the entry becomes ready) | next cycle |
| `Bypass[g]`, 4 group lanes | P2 (resident) | resident wakeup; feeds the FU input directly | that cycle |
| `Commit CDB`, 2 lanes | P1 | captured into the new ISQ payload | next cycle |
| `Commit CDB`, 2 lanes | P2 | **not connected** | — |
| ARF | P1, after the producer has committed | read from the ARF read ports | next cycle |

That one-cycle window is what the delta ladder enumerates: `delta` places the dependent's P1 relative to the producer's P3 / P4, and the case label follows from which window it lands in.

If a resident entry matches a P3 source in P2 but the selected FU cannot issue in that cycle, the matched data is latched at the clock edge, so from the next cycle the entry is `Stored Ready` and needs no further forwarding — it is not lost.

## Case 1: ALU_to_ALU_delta_0 (overlay)

**Dimension:** INT single-operand dependency | **Equiv:** ALU_to_ALU
**Description:** Same-bundle rename overlay gives the dependent the producer tag; the resident dependent waits for P3 forwarding.

| Instruction | T1 | T2 | T3 | T4 | T5 | T6 | T7 | T8 |
|:---|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|
| `add x5, x1, x2` - Producer-G0 | `[ IB ]`<br>enqueue instruction | `[ dispatch ]`<br>allocate **scoreboard** entry<br>write **ISQ_Group0**<br>rename x5 | `[ ALU0 ]`<br>execute add | `[ WB ]`<br>drive Bypass[0] tag+data<br>**scoreboard** set exec_done<br>**Buffer** write result | `[ C ]`<br>commit<br>**INT_ARF** write x5<br>**INT_tag_mapping** clear busy |  |  |  |
| `add x6, x5, x3` - Dependent-G1 | `[ IB ]`<br>enqueue instruction | `[ dispatch ]`<br>allocate **scoreboard** entry<br>write **ISQ_Group1**<br>overlay tag(x5)<br>rename x6 | `[ ISQ_Group1 ]`<br>wait for Bypass[0] tag(x5) | `[ ALU1 ]`<br>**ISQ_Group1** capture Bypass[0] tag(x5)<br>execute add | `[ WB ]`<br>drive Bypass[1] tag+data<br>**scoreboard** set exec_done<br>**Buffer** write result | `[ C ]`<br>commit<br>**INT_ARF** write x6<br>**INT_tag_mapping** clear busy |  |  |

- **T2 (Rename overlay):** the dependent is accepted in the same bundle and stores the producer's freshly allocated tag as its `wait_tag`, so its ISQ wait is armed with no dispatch-side capture.
- **T4 (Resident wakeup, P3 → P2 bypass):** the producer's P3 bypass matches the stored `wait_tag` and feeds the FU input directly; the dependent issues in the same cycle if the selected FU is free.

## Case 2: ALU_to_ALU_delta_1 (wait_for_p3)

**Dimension:** INT single-operand dependency | **Equiv:** ALU_to_ALU
**Description:** Dependent dispatches before producer P3, stores the `wait_tag` in ISQ, then wakes through resident-entry forwarding.

| Instruction | T1 | T2 | T3 | T4 | T5 | T6 | T7 | T8 |
|:---|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|
| `sub x5, x3, x4` - Producer-G0 | `[ IB ]`<br>enqueue instruction | `[ dispatch ]`<br>allocate **scoreboard** entry<br>write **ISQ_Group0**<br>rename x5 | `[ ALU0 ]`<br>execute sub | `[ WB ]`<br>drive Bypass[0] tag+data<br>**scoreboard** set exec_done<br>**Buffer** write result | `[ C ]`<br>commit<br>**INT_ARF** write x5<br>**INT_tag_mapping** clear busy |  |  |  |
| `add x6, x5, x7` - Dependent-G0 |  | `[ IB ]`<br>enqueue instruction | `[ dispatch ]`<br>allocate **scoreboard** entry<br>write **ISQ_Group0**<br>rename x6 | `[ ALU0 ]`<br>**ISQ_Group0** capture Bypass[0] tag(x5)<br>execute add | `[ WB ]`<br>drive Bypass[0] tag+data<br>**scoreboard** set exec_done<br>**Buffer** write result | `[ C ]`<br>commit<br>**INT_ARF** write x6<br>**INT_tag_mapping** clear busy |  |  |

- **T3 (Wait-tag dispatch):** the dependent dispatches before the producer's P3, so the value does not exist yet and it can only record `wait_tag` — the wakeup has to come from the resident-entry path, not from dispatch-time capture.
- **T4 (Resident wakeup, P3 → P2 bypass):** the producer's P3 bypass matches the stored `wait_tag` on the very next cycle and feeds the FU input directly; the dependent issues in the same cycle if the selected FU is free.

## Case 3: ALU_to_ALU_delta_2 (p3_capture)

**Dimension:** INT single-operand dependency | **Equiv:** ALU_to_ALU
**Description:** Dependent first P1 attempt exactly matches producer P3 Bypass and writes a ready ISQ payload.

| Instruction | T1 | T2 | T3 | T4 | T5 | T6 | T7 | T8 |
|:---|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|
| `add x5, x1, x2` - Producer-G0 | `[ IB ]`<br>enqueue instruction | `[ dispatch ]`<br>allocate **scoreboard** entry<br>write **ISQ_Group0**<br>rename x5 | `[ ALU0 ]`<br>execute add | `[ WB ]`<br>drive Bypass[0] tag+data<br>**scoreboard** set exec_done<br>**Buffer** write result | `[ C ]`<br>commit<br>**INT_ARF** write x5<br>**INT_tag_mapping** clear busy |  |  |  |
| `add x6, x5, x3` - Dependent-G0 |  |  | `[ IB ]`<br>enqueue instruction | `[ dispatch ]`<br>allocate **scoreboard** entry<br>capture Bypass[0] tag(x5), ready<br>write **ISQ_Group0**<br>rename x6 | `[ ALU0 ]`<br>execute add | `[ WB ]`<br>drive Bypass[0] tag+data<br>**scoreboard** set exec_done<br>**Buffer** write result | `[ C ]`<br>commit<br>**INT_ARF** write x6<br>**INT_tag_mapping** clear busy |  |

- **T4 (P3 capture, P3 → P1 bypass):** the dependent's P1 lands exactly on the producer's P3, so the bypass is written straight into a *ready* ISQ payload — the resident-wait path is skipped entirely, and the dependent issues on the following cycle without ever parking on a tag.

## Case 4: ALU_to_ALU_delta_3 (p4_capture)

**Dimension:** INT single-operand dependency | **Equiv:** ALU_to_ALU
**Description:** Dependent first P1 attempt exactly matches producer P4 Commit CDB and writes a ready ISQ payload.

| Instruction | T1 | T2 | T3 | T4 | T5 | T6 | T7 | T8 |
|:---|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|
| `add x5, x1, x2` - Producer-G0 | `[ IB ]`<br>enqueue instruction | `[ dispatch ]`<br>allocate **scoreboard** entry<br>write **ISQ_Group0**<br>rename x5 | `[ ALU0 ]`<br>execute add | `[ WB ]`<br>drive Bypass[0] tag+data<br>**scoreboard** set exec_done<br>**Buffer** write result | `[ C ]`<br>commit<br>**INT_ARF** write x5<br>**INT_tag_mapping** clear busy |  |  |  |
| `add x6, x5, x3` - Dependent-G0 |  |  |  | `[ IB ]`<br>enqueue instruction | `[ dispatch ]`<br>allocate **scoreboard** entry<br>capture Commit CDB tag(x5), ready<br>write **ISQ_Group0**<br>rename x6 | `[ ALU0 ]`<br>execute add | `[ WB ]`<br>drive Bypass[0] tag+data<br>**scoreboard** set exec_done<br>**Buffer** write result | `[ C ]`<br>commit<br>**INT_ARF** write x6<br>**INT_tag_mapping** clear busy |

- **T5 (P4 capture, P4 → P1 bypass):** the producer's P3 has already passed, so the only remaining value source is the Commit CDB at P4; capturing there is also what keeps the dependent out of the completed-but-uncommitted stall — it leaves P1 with a ready payload instead of a `wait_tag`.

## Case 5: ALU_to_ALU_delta_4 (arf_read)

**Dimension:** INT single-operand dependency | **Equiv:** ALU_to_ALU
**Description:** Producer has already committed before dependent P1, so the source is read from ARF.

| Instruction | T1 | T2 | T3 | T4 | T5 | T6 | T7 | T8 | T9 |
|:---|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|
| `add x5, x1, x2` - Producer-G0 | `[ IB ]`<br>enqueue instruction | `[ dispatch ]`<br>allocate **scoreboard** entry<br>write **ISQ_Group0**<br>rename x5 | `[ ALU0 ]`<br>execute add | `[ WB ]`<br>drive Bypass[0] tag+data<br>**scoreboard** set exec_done<br>**Buffer** write result | `[ C ]`<br>commit<br>**INT_ARF** write x5<br>**INT_tag_mapping** clear busy |  |  |  |  |
| `add x6, x5, x3` - Dependent-G0 |  |  |  |  | `[ IB ]`<br>enqueue instruction | `[ dispatch ]`<br>allocate **scoreboard** entry<br>read **INT_ARF** x5<br>write **ISQ_Group0**<br>rename x6 | `[ ALU0 ]`<br>execute add | `[ WB ]`<br>drive Bypass[0] tag+data<br>**scoreboard** set exec_done<br>**Buffer** write result | `[ C ]`<br>commit<br>**INT_ARF** write x6<br>**INT_tag_mapping** clear busy |

- **T6 (ARF read, no bypass):** both bypass windows are shut — the producer committed at T5 and `INT_tag_mapping` cleared the entry — so the source is no longer a producer tag at all; the dependent reads `INT_ARF` at P1 as an ordinary architected operand and issues without any wakeup.

## Case 6: MUL_to_ALU_delta_0 (overlay)

**Dimension:** INT single-operand dependency | **Equiv:** MUL_to_ALU
**Description:** Same-bundle rename overlay gives the dependent the producer tag; the resident dependent waits for P3 forwarding.

| Instruction | T1 | T2 | T3 | T4 | T5 | T6 | T7 | T8 |
|:---|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|
| `mul x5, x1, x2` - Producer-G1 | `[ IB ]`<br>enqueue instruction | `[ dispatch ]`<br>allocate **scoreboard** entry<br>write **ISQ_Group1**<br>rename x5 | `[ MUL ]`<br>execute mul step 1/3 | `[ MUL ]`<br>execute mul step 2/3 | `[ MUL ]`<br>execute mul step 3/3 | `[ WB ]`<br>drive Bypass[1] tag+data<br>**scoreboard** set exec_done<br>**Buffer** write result | `[ C ]`<br>commit<br>**INT_ARF** write x5<br>**INT_tag_mapping** clear busy |  |
| `add x6, x5, x3` - Dependent-G0 | `[ IB ]`<br>enqueue instruction | `[ dispatch ]`<br>allocate **scoreboard** entry<br>write **ISQ_Group0**<br>overlay tag(x5)<br>rename x6 | `[ ISQ_Group0 ]`<br>wait for Bypass[1] tag(x5) | `[ ISQ_Group0 ]`<br>wait for Bypass[1] tag(x5) | `[ ISQ_Group0 ]`<br>wait for Bypass[1] tag(x5) | `[ ALU0 ]`<br>**ISQ_Group0** capture Bypass[1] tag(x5)<br>execute add | `[ WB ]`<br>drive Bypass[0] tag+data<br>**scoreboard** set exec_done<br>**Buffer** write result | `[ C ]`<br>commit<br>**INT_ARF** write x6<br>**INT_tag_mapping** clear busy |

- **T2 (Rename overlay):** the dependent is accepted in the same bundle and stores the producer's freshly allocated tag as its `wait_tag`, so its ISQ wait is armed with no dispatch-side capture.
- **T6 (Resident wakeup, P3 → P2 bypass):** the MUL's P3 bypass matches the stored `wait_tag` and feeds the FU input directly; the three internal MUL steps do not matter to the consumer, only the tag on the last one.

## Case 7: MUL_to_ALU_delta_1 (wait_for_p3)

**Dimension:** INT single-operand dependency | **Equiv:** MUL_to_ALU
**Description:** Dependent dispatches before producer P3, stores the `wait_tag` in ISQ, then wakes through resident-entry forwarding.

| Instruction | T1 | T2 | T3 | T4 | T5 | T6 | T7 | T8 |
|:---|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|
| `mul x5, x3, x4` - Producer-G1 | `[ IB ]`<br>enqueue instruction | `[ dispatch ]`<br>allocate **scoreboard** entry<br>write **ISQ_Group1**<br>rename x5 | `[ MUL ]`<br>execute mul step 1/3 | `[ MUL ]`<br>execute mul step 2/3 | `[ MUL ]`<br>execute mul step 3/3 | `[ WB ]`<br>drive Bypass[1] tag+data<br>**scoreboard** set exec_done<br>**Buffer** write result | `[ C ]`<br>commit<br>**INT_ARF** write x5<br>**INT_tag_mapping** clear busy |  |
| `add x7, x5, x8` - Dependent-G0 |  | `[ IB ]`<br>enqueue instruction | `[ dispatch ]`<br>allocate **scoreboard** entry<br>write **ISQ_Group0**<br>rename x7 | `[ ISQ_Group0 ]`<br>wait for Bypass[1] tag(x5) | `[ ISQ_Group0 ]`<br>wait for Bypass[1] tag(x5) | `[ ALU0 ]`<br>**ISQ_Group0** capture Bypass[1] tag(x5)<br>execute add | `[ WB ]`<br>drive Bypass[0] tag+data<br>**scoreboard** set exec_done<br>**Buffer** write result | `[ C ]`<br>commit<br>**INT_ARF** write x7<br>**INT_tag_mapping** clear busy |

- **T3 (Wait-tag dispatch):** the dependent dispatches three cycles before the producer's P3, so the value cannot exist yet and it only records `wait_tag`; it then parks in the ISQ for T3–T5.
- **T6 (Resident wakeup, P3 → P2 bypass):** the bypass matches the parked tag and wakes the entry in the cycle the MUL result appears; the park length is a consequence of `delta`, not something the wakeup logic counts.

## Case 8: MUL_to_ALU_delta_2 (wait_for_p3)

**Dimension:** INT single-operand dependency | **Equiv:** MUL_to_ALU
**Description:** Dependent dispatches before producer P3, stores the `wait_tag` in ISQ, then wakes through resident-entry forwarding.

| Instruction | T1 | T2 | T3 | T4 | T5 | T6 | T7 | T8 |
|:---|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|
| `mul x5, x1, x2` - Producer-G1 | `[ IB ]`<br>enqueue instruction | `[ dispatch ]`<br>allocate **scoreboard** entry<br>write **ISQ_Group1**<br>rename x5 | `[ MUL ]`<br>execute mul step 1/3 | `[ MUL ]`<br>execute mul step 2/3 | `[ MUL ]`<br>execute mul step 3/3 | `[ WB ]`<br>drive Bypass[1] tag+data<br>**scoreboard** set exec_done<br>**Buffer** write result | `[ C ]`<br>commit<br>**INT_ARF** write x5<br>**INT_tag_mapping** clear busy |  |
| `add x6, x5, x3` - Dependent-G0 |  |  | `[ IB ]`<br>enqueue instruction | `[ dispatch ]`<br>allocate **scoreboard** entry<br>write **ISQ_Group0**<br>rename x6 | `[ ISQ_Group0 ]`<br>wait for Bypass[1] tag(x5) | `[ ALU0 ]`<br>**ISQ_Group0** capture Bypass[1] tag(x5)<br>execute add | `[ WB ]`<br>drive Bypass[0] tag+data<br>**scoreboard** set exec_done<br>**Buffer** write result | `[ C ]`<br>commit<br>**INT_ARF** write x6<br>**INT_tag_mapping** clear busy |

- **T4 (Wait-tag dispatch):** two cycles before the producer's P3 — still a `wait_tag` dispatch, since a dispatch capture needs the value to be on the bypass in that same cycle.
- **T6 (Resident wakeup, P3 → P2 bypass):** identical mechanism to `delta_1`; only the park length (T4–T5 instead of T3–T5) differs, which is exactly why the two cases share one label.

## Case 9: MUL_to_ALU_delta_3 (wait_for_p3)

**Dimension:** INT single-operand dependency | **Equiv:** MUL_to_ALU
**Description:** Dependent dispatches before producer P3, stores the `wait_tag` in ISQ, then wakes through resident-entry forwarding.

| Instruction | T1 | T2 | T3 | T4 | T5 | T6 | T7 | T8 |
|:---|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|
| `mul x5, x1, x2` - Producer-G1 | `[ IB ]`<br>enqueue instruction | `[ dispatch ]`<br>allocate **scoreboard** entry<br>write **ISQ_Group1**<br>rename x5 | `[ MUL ]`<br>execute mul step 1/3 | `[ MUL ]`<br>execute mul step 2/3 | `[ MUL ]`<br>execute mul step 3/3 | `[ WB ]`<br>drive Bypass[1] tag+data<br>**scoreboard** set exec_done<br>**Buffer** write result | `[ C ]`<br>commit<br>**INT_ARF** write x5<br>**INT_tag_mapping** clear busy |  |
| `add x6, x5, x3` - Dependent-G0 |  |  |  | `[ IB ]`<br>enqueue instruction | `[ dispatch ]`<br>allocate **scoreboard** entry<br>write **ISQ_Group0**<br>rename x6 | `[ ALU0 ]`<br>**ISQ_Group0** capture Bypass[1] tag(x5)<br>execute add | `[ WB ]`<br>drive Bypass[0] tag+data<br>**scoreboard** set exec_done<br>**Buffer** write result | `[ C ]`<br>commit<br>**INT_ARF** write x6<br>**INT_tag_mapping** clear busy |

- **T5 (Wait-tag dispatch):** the last `wait_for_p3` case — dispatched one cycle before P3, so the entry parks for a single cycle. One cycle later it would land on the bypass and become `p3_capture`.
- **T6 (Resident wakeup, P3 → P2 bypass):** the parked entry wakes on the tag match and issues in that cycle.

## Case 10: MUL_to_ALU_delta_4 (p3_capture)

**Dimension:** INT single-operand dependency | **Equiv:** MUL_to_ALU
**Description:** Dependent first P1 attempt exactly matches producer P3 Bypass and writes a ready ISQ payload.

| Instruction | T1 | T2 | T3 | T4 | T5 | T6 | T7 | T8 | T9 |
|:---|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|
| `mul x5, x1, x2` - Producer-G1 | `[ IB ]`<br>enqueue instruction | `[ dispatch ]`<br>allocate **scoreboard** entry<br>write **ISQ_Group1**<br>rename x5 | `[ MUL ]`<br>execute mul step 1/3 | `[ MUL ]`<br>execute mul step 2/3 | `[ MUL ]`<br>execute mul step 3/3 | `[ WB ]`<br>drive Bypass[1] tag+data<br>**scoreboard** set exec_done<br>**Buffer** write result | `[ C ]`<br>commit<br>**INT_ARF** write x5<br>**INT_tag_mapping** clear busy |  |  |
| `add x6, x5, x3` - Dependent-G0 |  |  |  |  | `[ IB ]`<br>enqueue instruction | `[ dispatch ]`<br>allocate **scoreboard** entry<br>capture Bypass[1] tag(x5), ready<br>write **ISQ_Group0**<br>rename x6 | `[ ALU0 ]`<br>execute add | `[ WB ]`<br>drive Bypass[0] tag+data<br>**scoreboard** set exec_done<br>**Buffer** write result | `[ C ]`<br>commit<br>**INT_ARF** write x6<br>**INT_tag_mapping** clear busy |

- **T6 (P3 capture, P3 → P1 bypass):** the dependent's P1 lands exactly on the producer's P3, so the bypass is written straight into a *ready* ISQ payload — the resident-wait path is skipped entirely, and the dependent issues on the following cycle without ever parking on a tag.

## Case 11: MUL_to_ALU_delta_5 (p4_capture)

**Dimension:** INT single-operand dependency | **Equiv:** MUL_to_ALU
**Description:** Dependent first P1 attempt exactly matches producer P4 Commit CDB and writes a ready ISQ payload.

| Instruction | T1 | T2 | T3 | T4 | T5 | T6 | T7 | T8 | T9 | T10 |
|:---|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|
| `mul x5, x1, x2` - Producer-G1 | `[ IB ]`<br>enqueue instruction | `[ dispatch ]`<br>allocate **scoreboard** entry<br>write **ISQ_Group1**<br>rename x5 | `[ MUL ]`<br>execute mul step 1/3 | `[ MUL ]`<br>execute mul step 2/3 | `[ MUL ]`<br>execute mul step 3/3 | `[ WB ]`<br>drive Bypass[1] tag+data<br>**scoreboard** set exec_done<br>**Buffer** write result | `[ C ]`<br>commit<br>**INT_ARF** write x5<br>**INT_tag_mapping** clear busy |  |  |  |
| `add x6, x5, x3` - Dependent-G0 |  |  |  |  |  | `[ IB ]`<br>enqueue instruction | `[ dispatch ]`<br>allocate **scoreboard** entry<br>capture Commit CDB tag(x5), ready<br>write **ISQ_Group0**<br>rename x6 | `[ ALU0 ]`<br>execute add | `[ WB ]`<br>drive Bypass[0] tag+data<br>**scoreboard** set exec_done<br>**Buffer** write result | `[ C ]`<br>commit<br>**INT_ARF** write x6<br>**INT_tag_mapping** clear busy |

- **T7 (P4 capture, P4 → P1 bypass):** the producer's P3 has already passed, so the only remaining value source is the Commit CDB at P4; capturing there is also what keeps the dependent out of the completed-but-uncommitted stall — it leaves P1 with a ready payload instead of a `wait_tag`.

## Case 12: MUL_to_ALU_delta_6 (arf_read)

**Dimension:** INT single-operand dependency | **Equiv:** MUL_to_ALU
**Description:** Producer has already committed before dependent P1, so the source is read from ARF.

| Instruction | T1 | T2 | T3 | T4 | T5 | T6 | T7 | T8 | T9 | T10 | T11 |
|:---|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|
| `mul x5, x1, x2` - Producer-G1 | `[ IB ]`<br>enqueue instruction | `[ dispatch ]`<br>allocate **scoreboard** entry<br>write **ISQ_Group1**<br>rename x5 | `[ MUL ]`<br>execute mul step 1/3 | `[ MUL ]`<br>execute mul step 2/3 | `[ MUL ]`<br>execute mul step 3/3 | `[ WB ]`<br>drive Bypass[1] tag+data<br>**scoreboard** set exec_done<br>**Buffer** write result | `[ C ]`<br>commit<br>**INT_ARF** write x5<br>**INT_tag_mapping** clear busy |  |  |  |  |
| `add x6, x5, x3` - Dependent-G0 |  |  |  |  |  |  | `[ IB ]`<br>enqueue instruction | `[ dispatch ]`<br>allocate **scoreboard** entry<br>read **INT_ARF** x5<br>write **ISQ_Group0**<br>rename x6 | `[ ALU0 ]`<br>execute add | `[ WB ]`<br>drive Bypass[0] tag+data<br>**scoreboard** set exec_done<br>**Buffer** write result | `[ C ]`<br>commit<br>**INT_ARF** write x6<br>**INT_tag_mapping** clear busy |

- **T8 (ARF read, no bypass):** both bypass windows are shut — the producer committed at T7 and `INT_tag_mapping` cleared the entry — so the source is no longer a producer tag at all; the dependent reads `INT_ARF` at P1 as an ordinary architected operand and issues without any wakeup.

## Case 13: DIV_to_ALU_delta_0 (overlay)

**Dimension:** INT single-operand dependency | **Equiv:** DIV_to_ALU
**Description:** Same-bundle rename overlay gives the dependent the producer tag; the resident dependent waits for P3 forwarding.

| Instruction | T1 | T2 | T3 | T4 | T5 | T6 | T7 | T8 | T9 | T10 | T11 | T12 | T13 |
|:---|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|
| `div x5, x1, x2` - Producer-G0 | `[ IB ]`<br>enqueue instruction | `[ dispatch ]`<br>allocate **scoreboard** entry<br>write **ISQ_Group0**<br>rename x5 | `[ DIV ]`<br>divide step 1/8 | `[ DIV ]`<br>divide step 2/8 | `[ DIV ]`<br>divide step 3/8 | `[ DIV ]`<br>divide step 4/8 | `[ DIV ]`<br>divide step 5/8 | `[ DIV ]`<br>divide step 6/8 | `[ DIV ]`<br>divide step 7/8 | `[ DIV ]`<br>divide step 8/8 | `[ WB ]`<br>drive Bypass[0] tag+data<br>**scoreboard** set exec_done<br>**Buffer** write result | `[ C ]`<br>commit<br>**INT_ARF** write x5<br>**INT_tag_mapping** clear busy |  |
| `add x6, x5, x3` - Dependent-G1 | `[ IB ]`<br>enqueue instruction | `[ dispatch ]`<br>allocate **scoreboard** entry<br>write **ISQ_Group1**<br>overlay tag(x5)<br>rename x6 | `[ ISQ_Group1 ]`<br>wait for Bypass[0] tag(x5) | `[ ISQ_Group1 ]`<br>wait for Bypass[0] tag(x5) | `[ ISQ_Group1 ]`<br>wait for Bypass[0] tag(x5) | `[ ISQ_Group1 ]`<br>wait for Bypass[0] tag(x5) | `[ ISQ_Group1 ]`<br>wait for Bypass[0] tag(x5) | `[ ISQ_Group1 ]`<br>wait for Bypass[0] tag(x5) | `[ ISQ_Group1 ]`<br>wait for Bypass[0] tag(x5) | `[ ISQ_Group1 ]`<br>wait for Bypass[0] tag(x5) | `[ ALU1 ]`<br>**ISQ_Group1** capture Bypass[0] tag(x5)<br>execute add | `[ WB ]`<br>drive Bypass[1] tag+data<br>**scoreboard** set exec_done<br>**Buffer** write result | `[ C ]`<br>commit<br>**INT_ARF** write x6<br>**INT_tag_mapping** clear busy |

- **T2 (Rename overlay):** the dependent is accepted in the same bundle and stores the producer's freshly allocated tag as its `wait_tag`, so its ISQ wait is armed with no dispatch-side capture.
- **T11 (Resident wakeup, P3 → P2 bypass):** the bypass matches the stored tag and wakes the entry in the cycle the result appears; the internal steps of the producer only decide *when* that cycle is, never *whether* the match happens.
## Case 14: DIV_to_ALU_delta_1 (wait_for_p3)

**Dimension:** INT single-operand dependency | **Equiv:** DIV_to_ALU
**Description:** Dependent dispatches before producer P3, stores the `wait_tag` in ISQ, then wakes through resident-entry forwarding.

| Instruction | T1 | T2 | T3 | T4 | T5 | T6 | T7 | T8 | T9 | T10 | T11 | T12 | T13 |
|:---|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|
| `div x5, x3, x4` - Producer-G0 | `[ IB ]`<br>enqueue instruction | `[ dispatch ]`<br>allocate **scoreboard** entry<br>write **ISQ_Group0**<br>rename x5 | `[ DIV ]`<br>divide step 1/8 | `[ DIV ]`<br>divide step 2/8 | `[ DIV ]`<br>divide step 3/8 | `[ DIV ]`<br>divide step 4/8 | `[ DIV ]`<br>divide step 5/8 | `[ DIV ]`<br>divide step 6/8 | `[ DIV ]`<br>divide step 7/8 | `[ DIV ]`<br>divide step 8/8 | `[ WB ]`<br>drive Bypass[0] tag+data<br>**scoreboard** set exec_done<br>**Buffer** write result | `[ C ]`<br>commit<br>**INT_ARF** write x5<br>**INT_tag_mapping** clear busy |  |
| `add x7, x5, x8` - Dependent-G0 |  | `[ IB ]`<br>enqueue instruction | `[ dispatch ]`<br>allocate **scoreboard** entry<br>write **ISQ_Group0**<br>rename x7 | `[ ISQ_Group0 ]`<br>wait for Bypass[0] tag(x5) | `[ ISQ_Group0 ]`<br>wait for Bypass[0] tag(x5) | `[ ISQ_Group0 ]`<br>wait for Bypass[0] tag(x5) | `[ ISQ_Group0 ]`<br>wait for Bypass[0] tag(x5) | `[ ISQ_Group0 ]`<br>wait for Bypass[0] tag(x5) | `[ ISQ_Group0 ]`<br>wait for Bypass[0] tag(x5) | `[ ISQ_Group0 ]`<br>wait for Bypass[0] tag(x5) | `[ ALU0 ]`<br>**ISQ_Group0** capture Bypass[0] tag(x5)<br>execute add | `[ WB ]`<br>drive Bypass[0] tag+data<br>**scoreboard** set exec_done<br>**Buffer** write result | `[ C ]`<br>commit<br>**INT_ARF** write x7<br>**INT_tag_mapping** clear busy |

- **T3 (Wait-tag dispatch):** the dependent dispatches 8 cycles before the producer's P3, so the value cannot exist yet and it only records `wait_tag`; it then parks from T3 to T10.
- **T11 (Resident wakeup, P3 → P2 bypass):** the bypass matches the stored tag and wakes the entry in the cycle the result appears; the park length is a consequence of `delta`, not something the wakeup logic counts. This is the deepest park in the family; nothing scales with its length — only the tag on the last cycle matters.
## Case 15: DIV_to_ALU_delta_2 (wait_for_p3)

**Dimension:** INT single-operand dependency | **Equiv:** DIV_to_ALU
**Description:** Dependent dispatches before producer P3, stores the `wait_tag` in ISQ, then wakes through resident-entry forwarding.

| Instruction | T1 | T2 | T3 | T4 | T5 | T6 | T7 | T8 | T9 | T10 | T11 | T12 | T13 |
|:---|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|
| `div x5, x1, x2` - Producer-G0 | `[ IB ]`<br>enqueue instruction | `[ dispatch ]`<br>allocate **scoreboard** entry<br>write **ISQ_Group0**<br>rename x5 | `[ DIV ]`<br>divide step 1/8 | `[ DIV ]`<br>divide step 2/8 | `[ DIV ]`<br>divide step 3/8 | `[ DIV ]`<br>divide step 4/8 | `[ DIV ]`<br>divide step 5/8 | `[ DIV ]`<br>divide step 6/8 | `[ DIV ]`<br>divide step 7/8 | `[ DIV ]`<br>divide step 8/8 | `[ WB ]`<br>drive Bypass[0] tag+data<br>**scoreboard** set exec_done<br>**Buffer** write result | `[ C ]`<br>commit<br>**INT_ARF** write x5<br>**INT_tag_mapping** clear busy |  |
| `add x6, x5, x3` - Dependent-G0 |  |  | `[ IB ]`<br>enqueue instruction | `[ dispatch ]`<br>allocate **scoreboard** entry<br>write **ISQ_Group0**<br>rename x6 | `[ ISQ_Group0 ]`<br>wait for Bypass[0] tag(x5) | `[ ISQ_Group0 ]`<br>wait for Bypass[0] tag(x5) | `[ ISQ_Group0 ]`<br>wait for Bypass[0] tag(x5) | `[ ISQ_Group0 ]`<br>wait for Bypass[0] tag(x5) | `[ ISQ_Group0 ]`<br>wait for Bypass[0] tag(x5) | `[ ISQ_Group0 ]`<br>wait for Bypass[0] tag(x5) | `[ ALU0 ]`<br>**ISQ_Group0** capture Bypass[0] tag(x5)<br>execute add | `[ WB ]`<br>drive Bypass[0] tag+data<br>**scoreboard** set exec_done<br>**Buffer** write result | `[ C ]`<br>commit<br>**INT_ARF** write x6<br>**INT_tag_mapping** clear busy |

- **T4 (Wait-tag dispatch):** the dependent dispatches 7 cycles before the producer's P3, so the value cannot exist yet and it only records `wait_tag`; it then parks from T4 to T10.
- **T11 (Resident wakeup, P3 → P2 bypass):** the bypass matches the stored tag and wakes the entry in the cycle the result appears; the park length is a consequence of `delta`, not something the wakeup logic counts.
## Case 16: DIV_to_ALU_delta_3 (wait_for_p3)

**Dimension:** INT single-operand dependency | **Equiv:** DIV_to_ALU
**Description:** Dependent dispatches before producer P3, stores the `wait_tag` in ISQ, then wakes through resident-entry forwarding.

| Instruction | T1 | T2 | T3 | T4 | T5 | T6 | T7 | T8 | T9 | T10 | T11 | T12 | T13 |
|:---|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|
| `div x5, x1, x2` - Producer-G0 | `[ IB ]`<br>enqueue instruction | `[ dispatch ]`<br>allocate **scoreboard** entry<br>write **ISQ_Group0**<br>rename x5 | `[ DIV ]`<br>divide step 1/8 | `[ DIV ]`<br>divide step 2/8 | `[ DIV ]`<br>divide step 3/8 | `[ DIV ]`<br>divide step 4/8 | `[ DIV ]`<br>divide step 5/8 | `[ DIV ]`<br>divide step 6/8 | `[ DIV ]`<br>divide step 7/8 | `[ DIV ]`<br>divide step 8/8 | `[ WB ]`<br>drive Bypass[0] tag+data<br>**scoreboard** set exec_done<br>**Buffer** write result | `[ C ]`<br>commit<br>**INT_ARF** write x5<br>**INT_tag_mapping** clear busy |  |
| `add x6, x5, x3` - Dependent-G0 |  |  |  | `[ IB ]`<br>enqueue instruction | `[ dispatch ]`<br>allocate **scoreboard** entry<br>write **ISQ_Group0**<br>rename x6 | `[ ISQ_Group0 ]`<br>wait for Bypass[0] tag(x5) | `[ ISQ_Group0 ]`<br>wait for Bypass[0] tag(x5) | `[ ISQ_Group0 ]`<br>wait for Bypass[0] tag(x5) | `[ ISQ_Group0 ]`<br>wait for Bypass[0] tag(x5) | `[ ISQ_Group0 ]`<br>wait for Bypass[0] tag(x5) | `[ ALU0 ]`<br>**ISQ_Group0** capture Bypass[0] tag(x5)<br>execute add | `[ WB ]`<br>drive Bypass[0] tag+data<br>**scoreboard** set exec_done<br>**Buffer** write result | `[ C ]`<br>commit<br>**INT_ARF** write x6<br>**INT_tag_mapping** clear busy |

- **T5 (Wait-tag dispatch):** the dependent dispatches 6 cycles before the producer's P3, so the value cannot exist yet and it only records `wait_tag`; it then parks from T5 to T10.
- **T11 (Resident wakeup, P3 → P2 bypass):** the bypass matches the stored tag and wakes the entry in the cycle the result appears; the park length is a consequence of `delta`, not something the wakeup logic counts.
## Case 17: DIV_to_ALU_delta_4 (wait_for_p3)

**Dimension:** INT single-operand dependency | **Equiv:** DIV_to_ALU
**Description:** Dependent dispatches before producer P3, stores the `wait_tag` in ISQ, then wakes through resident-entry forwarding.

| Instruction | T1 | T2 | T3 | T4 | T5 | T6 | T7 | T8 | T9 | T10 | T11 | T12 | T13 |
|:---|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|
| `div x5, x1, x2` - Producer-G0 | `[ IB ]`<br>enqueue instruction | `[ dispatch ]`<br>allocate **scoreboard** entry<br>write **ISQ_Group0**<br>rename x5 | `[ DIV ]`<br>divide step 1/8 | `[ DIV ]`<br>divide step 2/8 | `[ DIV ]`<br>divide step 3/8 | `[ DIV ]`<br>divide step 4/8 | `[ DIV ]`<br>divide step 5/8 | `[ DIV ]`<br>divide step 6/8 | `[ DIV ]`<br>divide step 7/8 | `[ DIV ]`<br>divide step 8/8 | `[ WB ]`<br>drive Bypass[0] tag+data<br>**scoreboard** set exec_done<br>**Buffer** write result | `[ C ]`<br>commit<br>**INT_ARF** write x5<br>**INT_tag_mapping** clear busy |  |
| `add x6, x5, x3` - Dependent-G0 |  |  |  |  | `[ IB ]`<br>enqueue instruction | `[ dispatch ]`<br>allocate **scoreboard** entry<br>write **ISQ_Group0**<br>rename x6 | `[ ISQ_Group0 ]`<br>wait for Bypass[0] tag(x5) | `[ ISQ_Group0 ]`<br>wait for Bypass[0] tag(x5) | `[ ISQ_Group0 ]`<br>wait for Bypass[0] tag(x5) | `[ ISQ_Group0 ]`<br>wait for Bypass[0] tag(x5) | `[ ALU0 ]`<br>**ISQ_Group0** capture Bypass[0] tag(x5)<br>execute add | `[ WB ]`<br>drive Bypass[0] tag+data<br>**scoreboard** set exec_done<br>**Buffer** write result | `[ C ]`<br>commit<br>**INT_ARF** write x6<br>**INT_tag_mapping** clear busy |

- **T6 (Wait-tag dispatch):** the dependent dispatches 5 cycles before the producer's P3, so the value cannot exist yet and it only records `wait_tag`; it then parks from T6 to T10.
- **T11 (Resident wakeup, P3 → P2 bypass):** the bypass matches the stored tag and wakes the entry in the cycle the result appears; the park length is a consequence of `delta`, not something the wakeup logic counts.
## Case 18: DIV_to_ALU_delta_5 (wait_for_p3)

**Dimension:** INT single-operand dependency | **Equiv:** DIV_to_ALU
**Description:** Dependent dispatches before producer P3, stores the `wait_tag` in ISQ, then wakes through resident-entry forwarding.

| Instruction | T1 | T2 | T3 | T4 | T5 | T6 | T7 | T8 | T9 | T10 | T11 | T12 | T13 |
|:---|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|
| `div x5, x1, x2` - Producer-G0 | `[ IB ]`<br>enqueue instruction | `[ dispatch ]`<br>allocate **scoreboard** entry<br>write **ISQ_Group0**<br>rename x5 | `[ DIV ]`<br>divide step 1/8 | `[ DIV ]`<br>divide step 2/8 | `[ DIV ]`<br>divide step 3/8 | `[ DIV ]`<br>divide step 4/8 | `[ DIV ]`<br>divide step 5/8 | `[ DIV ]`<br>divide step 6/8 | `[ DIV ]`<br>divide step 7/8 | `[ DIV ]`<br>divide step 8/8 | `[ WB ]`<br>drive Bypass[0] tag+data<br>**scoreboard** set exec_done<br>**Buffer** write result | `[ C ]`<br>commit<br>**INT_ARF** write x5<br>**INT_tag_mapping** clear busy |  |
| `add x6, x5, x3` - Dependent-G0 |  |  |  |  |  | `[ IB ]`<br>enqueue instruction | `[ dispatch ]`<br>allocate **scoreboard** entry<br>write **ISQ_Group0**<br>rename x6 | `[ ISQ_Group0 ]`<br>wait for Bypass[0] tag(x5) | `[ ISQ_Group0 ]`<br>wait for Bypass[0] tag(x5) | `[ ISQ_Group0 ]`<br>wait for Bypass[0] tag(x5) | `[ ALU0 ]`<br>**ISQ_Group0** capture Bypass[0] tag(x5)<br>execute add | `[ WB ]`<br>drive Bypass[0] tag+data<br>**scoreboard** set exec_done<br>**Buffer** write result | `[ C ]`<br>commit<br>**INT_ARF** write x6<br>**INT_tag_mapping** clear busy |

- **T7 (Wait-tag dispatch):** the dependent dispatches 4 cycles before the producer's P3, so the value cannot exist yet and it only records `wait_tag`; it then parks from T7 to T10.
- **T11 (Resident wakeup, P3 → P2 bypass):** the bypass matches the stored tag and wakes the entry in the cycle the result appears; the park length is a consequence of `delta`, not something the wakeup logic counts.
## Case 19: DIV_to_ALU_delta_6 (wait_for_p3)

**Dimension:** INT single-operand dependency | **Equiv:** DIV_to_ALU
**Description:** Dependent dispatches before producer P3, stores the `wait_tag` in ISQ, then wakes through resident-entry forwarding.

| Instruction | T1 | T2 | T3 | T4 | T5 | T6 | T7 | T8 | T9 | T10 | T11 | T12 | T13 |
|:---|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|
| `div x5, x1, x2` - Producer-G0 | `[ IB ]`<br>enqueue instruction | `[ dispatch ]`<br>allocate **scoreboard** entry<br>write **ISQ_Group0**<br>rename x5 | `[ DIV ]`<br>divide step 1/8 | `[ DIV ]`<br>divide step 2/8 | `[ DIV ]`<br>divide step 3/8 | `[ DIV ]`<br>divide step 4/8 | `[ DIV ]`<br>divide step 5/8 | `[ DIV ]`<br>divide step 6/8 | `[ DIV ]`<br>divide step 7/8 | `[ DIV ]`<br>divide step 8/8 | `[ WB ]`<br>drive Bypass[0] tag+data<br>**scoreboard** set exec_done<br>**Buffer** write result | `[ C ]`<br>commit<br>**INT_ARF** write x5<br>**INT_tag_mapping** clear busy |  |
| `add x6, x5, x3` - Dependent-G0 |  |  |  |  |  |  | `[ IB ]`<br>enqueue instruction | `[ dispatch ]`<br>allocate **scoreboard** entry<br>write **ISQ_Group0**<br>rename x6 | `[ ISQ_Group0 ]`<br>wait for Bypass[0] tag(x5) | `[ ISQ_Group0 ]`<br>wait for Bypass[0] tag(x5) | `[ ALU0 ]`<br>**ISQ_Group0** capture Bypass[0] tag(x5)<br>execute add | `[ WB ]`<br>drive Bypass[0] tag+data<br>**scoreboard** set exec_done<br>**Buffer** write result | `[ C ]`<br>commit<br>**INT_ARF** write x6<br>**INT_tag_mapping** clear busy |

- **T8 (Wait-tag dispatch):** the dependent dispatches 3 cycles before the producer's P3, so the value cannot exist yet and it only records `wait_tag`; it then parks from T8 to T10.
- **T11 (Resident wakeup, P3 → P2 bypass):** the bypass matches the stored tag and wakes the entry in the cycle the result appears; the park length is a consequence of `delta`, not something the wakeup logic counts.
## Case 20: DIV_to_ALU_delta_7 (wait_for_p3)

**Dimension:** INT single-operand dependency | **Equiv:** DIV_to_ALU
**Description:** Dependent dispatches before producer P3, stores the `wait_tag` in ISQ, then wakes through resident-entry forwarding.

| Instruction | T1 | T2 | T3 | T4 | T5 | T6 | T7 | T8 | T9 | T10 | T11 | T12 | T13 |
|:---|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|
| `div x5, x1, x2` - Producer-G0 | `[ IB ]`<br>enqueue instruction | `[ dispatch ]`<br>allocate **scoreboard** entry<br>write **ISQ_Group0**<br>rename x5 | `[ DIV ]`<br>divide step 1/8 | `[ DIV ]`<br>divide step 2/8 | `[ DIV ]`<br>divide step 3/8 | `[ DIV ]`<br>divide step 4/8 | `[ DIV ]`<br>divide step 5/8 | `[ DIV ]`<br>divide step 6/8 | `[ DIV ]`<br>divide step 7/8 | `[ DIV ]`<br>divide step 8/8 | `[ WB ]`<br>drive Bypass[0] tag+data<br>**scoreboard** set exec_done<br>**Buffer** write result | `[ C ]`<br>commit<br>**INT_ARF** write x5<br>**INT_tag_mapping** clear busy |  |
| `add x6, x5, x3` - Dependent-G0 |  |  |  |  |  |  |  | `[ IB ]`<br>enqueue instruction | `[ dispatch ]`<br>allocate **scoreboard** entry<br>write **ISQ_Group0**<br>rename x6 | `[ ISQ_Group0 ]`<br>wait for Bypass[0] tag(x5) | `[ ALU0 ]`<br>**ISQ_Group0** capture Bypass[0] tag(x5)<br>execute add | `[ WB ]`<br>drive Bypass[0] tag+data<br>**scoreboard** set exec_done<br>**Buffer** write result | `[ C ]`<br>commit<br>**INT_ARF** write x6<br>**INT_tag_mapping** clear busy |

- **T9 (Wait-tag dispatch):** the dependent dispatches 2 cycles before the producer's P3, so the value cannot exist yet and it only records `wait_tag`; it then parks from T9 to T10.
- **T11 (Resident wakeup, P3 → P2 bypass):** the bypass matches the stored tag and wakes the entry in the cycle the result appears; the park length is a consequence of `delta`, not something the wakeup logic counts.
## Case 21: DIV_to_ALU_delta_8 (wait_for_p3)

**Dimension:** INT single-operand dependency | **Equiv:** DIV_to_ALU
**Description:** Dependent dispatches before producer P3, stores the `wait_tag` in ISQ, then wakes through resident-entry forwarding.

| Instruction | T1 | T2 | T3 | T4 | T5 | T6 | T7 | T8 | T9 | T10 | T11 | T12 | T13 |
|:---|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|
| `div x5, x1, x2` - Producer-G0 | `[ IB ]`<br>enqueue instruction | `[ dispatch ]`<br>allocate **scoreboard** entry<br>write **ISQ_Group0**<br>rename x5 | `[ DIV ]`<br>divide step 1/8 | `[ DIV ]`<br>divide step 2/8 | `[ DIV ]`<br>divide step 3/8 | `[ DIV ]`<br>divide step 4/8 | `[ DIV ]`<br>divide step 5/8 | `[ DIV ]`<br>divide step 6/8 | `[ DIV ]`<br>divide step 7/8 | `[ DIV ]`<br>divide step 8/8 | `[ WB ]`<br>drive Bypass[0] tag+data<br>**scoreboard** set exec_done<br>**Buffer** write result | `[ C ]`<br>commit<br>**INT_ARF** write x5<br>**INT_tag_mapping** clear busy |  |
| `add x6, x5, x3` - Dependent-G0 |  |  |  |  |  |  |  |  | `[ IB ]`<br>enqueue instruction | `[ dispatch ]`<br>allocate **scoreboard** entry<br>write **ISQ_Group0**<br>rename x6 | `[ ALU0 ]`<br>**ISQ_Group0** capture Bypass[0] tag(x5)<br>execute add | `[ WB ]`<br>drive Bypass[0] tag+data<br>**scoreboard** set exec_done<br>**Buffer** write result | `[ C ]`<br>commit<br>**INT_ARF** write x6<br>**INT_tag_mapping** clear busy |

- **T10 (Wait-tag dispatch):** the dependent dispatches 1 cycle before the producer's P3, so the value cannot exist yet and it only records `wait_tag`; it then parks for that single cycle (T10).
- **T11 (Resident wakeup, P3 → P2 bypass):** the bypass matches the stored tag and wakes the entry in the cycle the result appears; the park length is a consequence of `delta`, not something the wakeup logic counts. The shortest park on this path: one cycle later the dispatch would land on the bypass and the case would be `p3_capture`.
## Case 22: DIV_to_ALU_delta_9 (p3_capture)

**Dimension:** INT single-operand dependency | **Equiv:** DIV_to_ALU
**Description:** Dependent first P1 attempt exactly matches producer P3 Bypass and writes a ready ISQ payload.

| Instruction | T1 | T2 | T3 | T4 | T5 | T6 | T7 | T8 | T9 | T10 | T11 | T12 | T13 | T14 |
|:---|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|
| `div x5, x1, x2` - Producer-G0 | `[ IB ]`<br>enqueue instruction | `[ dispatch ]`<br>allocate **scoreboard** entry<br>write **ISQ_Group0**<br>rename x5 | `[ DIV ]`<br>divide step 1/8 | `[ DIV ]`<br>divide step 2/8 | `[ DIV ]`<br>divide step 3/8 | `[ DIV ]`<br>divide step 4/8 | `[ DIV ]`<br>divide step 5/8 | `[ DIV ]`<br>divide step 6/8 | `[ DIV ]`<br>divide step 7/8 | `[ DIV ]`<br>divide step 8/8 | `[ WB ]`<br>drive Bypass[0] tag+data<br>**scoreboard** set exec_done<br>**Buffer** write result | `[ C ]`<br>commit<br>**INT_ARF** write x5<br>**INT_tag_mapping** clear busy |  |  |
| `add x6, x5, x3` - Dependent-G0 |  |  |  |  |  |  |  |  |  | `[ IB ]`<br>enqueue instruction | `[ dispatch ]`<br>allocate **scoreboard** entry<br>capture Bypass[0] tag(x5), ready<br>write **ISQ_Group0**<br>rename x6 | `[ ALU0 ]`<br>execute add | `[ WB ]`<br>drive Bypass[0] tag+data<br>**scoreboard** set exec_done<br>**Buffer** write result | `[ C ]`<br>commit<br>**INT_ARF** write x6<br>**INT_tag_mapping** clear busy |

- **T11 (P3 capture, P3 → P1 bypass):** the dependent's P1 lands exactly on the producer's P3, so the bypass is written straight into a *ready* ISQ payload — the resident-wait path is skipped entirely, and the dependent issues on the following cycle without ever parking on a tag.
## Case 23: DIV_to_ALU_delta_10 (p4_capture)

**Dimension:** INT single-operand dependency | **Equiv:** DIV_to_ALU
**Description:** Dependent first P1 attempt exactly matches producer P4 Commit CDB and captures `commit_data`.

| Instruction | T1 | T2 | T3 | T4 | T5 | T6 | T7 | T8 | T9 | T10 | T11 | T12 | T13 | T14 | T15 |
|:---|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|
| `div x5, x1, x2` - Producer-G0 | `[ IB ]`<br>enqueue instruction | `[ dispatch ]`<br>allocate **scoreboard** entry<br>write **ISQ_Group0**<br>rename x5 | `[ DIV ]`<br>divide step 1/8 | `[ DIV ]`<br>divide step 2/8 | `[ DIV ]`<br>divide step 3/8 | `[ DIV ]`<br>divide step 4/8 | `[ DIV ]`<br>divide step 5/8 | `[ DIV ]`<br>divide step 6/8 | `[ DIV ]`<br>divide step 7/8 | `[ DIV ]`<br>divide step 8/8 | `[ WB ]`<br>drive Bypass[0] tag+data<br>**scoreboard** set exec_done<br>**Buffer** write result | `[ C ]`<br>commit<br>**INT_ARF** write x5<br>**INT_tag_mapping** clear busy |  |  |  |
| `add x6, x5, x3` - Dependent-G0 |  |  |  |  |  |  |  |  |  |  | `[ IB ]`<br>enqueue instruction | `[ dispatch ]`<br>allocate **scoreboard** entry<br>capture Commit CDB tag(x5), ready<br>write **ISQ_Group0**<br>rename x6 | `[ ALU0 ]`<br>execute add | `[ WB ]`<br>drive Bypass[0] tag+data<br>**scoreboard** set exec_done<br>**Buffer** write result | `[ C ]`<br>commit<br>**INT_ARF** write x6<br>**INT_tag_mapping** clear busy |

- **T12 (P4 capture, P4 → P1 bypass):** the producer's P3 has already passed, so the only remaining value source is the Commit CDB at P4; capturing there is also what keeps the dependent out of the completed-but-uncommitted stall — it leaves P1 with a ready payload instead of a `wait_tag`.
## Case 24: DIV_to_ALU_delta_11 (arf_read)

**Dimension:** INT single-operand dependency | **Equiv:** DIV_to_ALU
**Description:** Producer has already committed before dependent P1, so the source is read from ARF.

| Instruction | T1 | T2 | T3 | T4 | T5 | T6 | T7 | T8 | T9 | T10 | T11 | T12 | T13 | T14 | T15 | T16 |
|:---|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|
| `div x5, x1, x2` - Producer-G0 | `[ IB ]`<br>enqueue instruction | `[ dispatch ]`<br>allocate **scoreboard** entry<br>write **ISQ_Group0**<br>rename x5 | `[ DIV ]`<br>divide step 1/8 | `[ DIV ]`<br>divide step 2/8 | `[ DIV ]`<br>divide step 3/8 | `[ DIV ]`<br>divide step 4/8 | `[ DIV ]`<br>divide step 5/8 | `[ DIV ]`<br>divide step 6/8 | `[ DIV ]`<br>divide step 7/8 | `[ DIV ]`<br>divide step 8/8 | `[ WB ]`<br>drive Bypass[0] tag+data<br>**scoreboard** set exec_done<br>**Buffer** write result | `[ C ]`<br>commit<br>**INT_ARF** write x5<br>**INT_tag_mapping** clear busy |  |  |  |  |
| `add x6, x5, x3` - Dependent-G0 |  |  |  |  |  |  |  |  |  |  |  | `[ IB ]`<br>enqueue instruction | `[ dispatch ]`<br>allocate **scoreboard** entry<br>read **INT_ARF** x5<br>write **ISQ_Group0**<br>rename x6 | `[ ALU0 ]`<br>execute add | `[ WB ]`<br>drive Bypass[0] tag+data<br>**scoreboard** set exec_done<br>**Buffer** write result | `[ C ]`<br>commit<br>**INT_ARF** write x6<br>**INT_tag_mapping** clear busy |

- **T13 (ARF read, no bypass):** both bypass windows are shut — the producer committed at T12 and `INT_tag_mapping` cleared the entry — so the source is no longer a producer tag at all; the dependent reads `INT_ARF` at P1 as an ordinary architected operand and issues without any wakeup.
## Case 25: LOAD_to_ALU_delta_0 (overlay)

**Dimension:** INT single-operand dependency | **Equiv:** LOAD_to_ALU
**Description:** Same-bundle rename overlay gives the dependent the producer tag; the resident dependent waits for P3 forwarding.

| Instruction | T1 | T2 | T3 | T4 | T5 | T6 | T7 |
|:---|:---:|:---:|:---:|:---:|:---:|:---:|:---:|
| `ld x5, 0(x1)` - Producer-G3 | `[ IB ]`<br>enqueue instruction | `[ dispatch ]`<br>allocate **scoreboard** entry<br>write **ISQ_Group3**<br>rename x5 | `[ AGU ]`<br>compute address | `[ L1D ]`<br>access **L1D**, hit | `[ WB ]`<br>drive Bypass[3] tag+data<br>**scoreboard** set exec_done<br>**Buffer** write result | `[ C ]`<br>commit<br>**INT_ARF** write x5<br>**INT_tag_mapping** clear busy |  |
| `add x6, x5, x3` - Dependent-G0 | `[ IB ]`<br>enqueue instruction | `[ dispatch ]`<br>allocate **scoreboard** entry<br>write **ISQ_Group0**<br>overlay tag(x5)<br>rename x6 | `[ ISQ_Group0 ]`<br>wait for Bypass[3] tag(x5) | `[ ISQ_Group0 ]`<br>wait for Bypass[3] tag(x5) | `[ ALU0 ]`<br>**ISQ_Group0** capture Bypass[3] tag(x5)<br>execute add | `[ WB ]`<br>drive Bypass[0] tag+data<br>**scoreboard** set exec_done<br>**Buffer** write result | `[ C ]`<br>commit<br>**INT_ARF** write x6<br>**INT_tag_mapping** clear busy |

- **T2 (Rename overlay):** the dependent is accepted in the same bundle and stores the producer's freshly allocated tag as its `wait_tag`, so its ISQ wait is armed with no dispatch-side capture.
- **T5 (Resident wakeup, P3 → P2 bypass):** the bypass matches the stored tag and wakes the entry in the cycle the result appears; the internal steps of the producer only decide *when* that cycle is, never *whether* the match happens.
## Case 26: LOAD_to_ALU_delta_1 (wait_for_p3)

**Dimension:** INT single-operand dependency | **Equiv:** LOAD_to_ALU
**Description:** Dependent dispatches before producer P3, stores the `wait_tag` in ISQ, then wakes through resident-entry forwarding.

| Instruction | T1 | T2 | T3 | T4 | T5 | T6 | T7 |
|:---|:---:|:---:|:---:|:---:|:---:|:---:|:---:|
| `lw x5, 8(x2)` - Producer-G3 | `[ IB ]`<br>enqueue instruction | `[ dispatch ]`<br>allocate **scoreboard** entry<br>write **ISQ_Group3**<br>rename x5 | `[ AGU ]`<br>compute address | `[ L1D ]`<br>access **L1D**, hit | `[ WB ]`<br>drive Bypass[3] tag+data<br>**scoreboard** set exec_done<br>**Buffer** write result | `[ C ]`<br>commit<br>**INT_ARF** write x5<br>**INT_tag_mapping** clear busy |  |
| `add x7, x5, x8` - Dependent-G0 |  | `[ IB ]`<br>enqueue instruction | `[ dispatch ]`<br>allocate **scoreboard** entry<br>write **ISQ_Group0**<br>rename x7 | `[ ISQ_Group0 ]`<br>wait for Bypass[3] tag(x5) | `[ ALU0 ]`<br>**ISQ_Group0** capture Bypass[3] tag(x5)<br>execute add | `[ WB ]`<br>drive Bypass[0] tag+data<br>**scoreboard** set exec_done<br>**Buffer** write result | `[ C ]`<br>commit<br>**INT_ARF** write x7<br>**INT_tag_mapping** clear busy |

- **T3 (Wait-tag dispatch):** the dependent dispatches 2 cycles before the producer's P3, so the value cannot exist yet and it only records `wait_tag`; it then parks from T3 to T4.
- **T5 (Resident wakeup, P3 → P2 bypass):** the bypass matches the stored tag and wakes the entry in the cycle the result appears; the park length is a consequence of `delta`, not something the wakeup logic counts.
## Case 27: LOAD_to_ALU_delta_2 (wait_for_p3)

**Dimension:** INT single-operand dependency | **Equiv:** LOAD_to_ALU
**Description:** Dependent dispatches before producer P3, stores the `wait_tag` in ISQ, then wakes through resident-entry forwarding.

| Instruction | T1 | T2 | T3 | T4 | T5 | T6 | T7 |
|:---|:---:|:---:|:---:|:---:|:---:|:---:|:---:|
| `ld x5, 0(x1)` - Producer-G3 | `[ IB ]`<br>enqueue instruction | `[ dispatch ]`<br>allocate **scoreboard** entry<br>write **ISQ_Group3**<br>rename x5 | `[ AGU ]`<br>compute address | `[ L1D ]`<br>access **L1D**, hit | `[ WB ]`<br>drive Bypass[3] tag+data<br>**scoreboard** set exec_done<br>**Buffer** write result | `[ C ]`<br>commit<br>**INT_ARF** write x5<br>**INT_tag_mapping** clear busy |  |
| `add x6, x5, x3` - Dependent-G0 |  |  | `[ IB ]`<br>enqueue instruction | `[ dispatch ]`<br>allocate **scoreboard** entry<br>write **ISQ_Group0**<br>rename x6 | `[ ALU0 ]`<br>**ISQ_Group0** capture Bypass[3] tag(x5)<br>execute add | `[ WB ]`<br>drive Bypass[0] tag+data<br>**scoreboard** set exec_done<br>**Buffer** write result | `[ C ]`<br>commit<br>**INT_ARF** write x6<br>**INT_tag_mapping** clear busy |

- **T4 (Wait-tag dispatch):** the dependent dispatches 1 cycle before the producer's P3, so the value cannot exist yet and it only records `wait_tag`; it then parks for that single cycle (T4).
- **T5 (Resident wakeup, P3 → P2 bypass):** the bypass matches the stored tag and wakes the entry in the cycle the result appears; the park length is a consequence of `delta`, not something the wakeup logic counts.
## Case 28: LOAD_to_ALU_delta_3 (p3_capture)

**Dimension:** INT single-operand dependency | **Equiv:** LOAD_to_ALU
**Description:** Dependent first P1 attempt exactly matches producer P3 Bypass and writes a ready ISQ payload.

| Instruction | T1 | T2 | T3 | T4 | T5 | T6 | T7 | T8 |
|:---|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|
| `ld x5, 0(x1)` - Producer-G3 | `[ IB ]`<br>enqueue instruction | `[ dispatch ]`<br>allocate **scoreboard** entry<br>write **ISQ_Group3**<br>rename x5 | `[ AGU ]`<br>compute address | `[ L1D ]`<br>access **L1D**, hit | `[ WB ]`<br>drive Bypass[3] tag+data<br>**scoreboard** set exec_done<br>**Buffer** write result | `[ C ]`<br>commit<br>**INT_ARF** write x5<br>**INT_tag_mapping** clear busy |  |  |
| `add x6, x5, x3` - Dependent-G0 |  |  |  | `[ IB ]`<br>enqueue instruction | `[ dispatch ]`<br>allocate **scoreboard** entry<br>capture Bypass[3] tag(x5), ready<br>write **ISQ_Group0**<br>rename x6 | `[ ALU0 ]`<br>execute add | `[ WB ]`<br>drive Bypass[0] tag+data<br>**scoreboard** set exec_done<br>**Buffer** write result | `[ C ]`<br>commit<br>**INT_ARF** write x6<br>**INT_tag_mapping** clear busy |

- **T5 (P3 capture, P3 → P1 bypass):** the dependent's P1 lands exactly on the producer's P3, so the bypass is written straight into a *ready* ISQ payload — the resident-wait path is skipped entirely, and the dependent issues on the following cycle without ever parking on a tag.
## Case 29: LOAD_to_ALU_delta_4 (p4_capture)

**Dimension:** INT single-operand dependency | **Equiv:** LOAD_to_ALU
**Description:** Dependent first P1 attempt exactly matches producer P4 Commit CDB and captures `commit_data`.

| Instruction | T1 | T2 | T3 | T4 | T5 | T6 | T7 | T8 | T9 |
|:---|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|
| `ld x5, 0(x1)` - Producer-G3 | `[ IB ]`<br>enqueue instruction | `[ dispatch ]`<br>allocate **scoreboard** entry<br>write **ISQ_Group3**<br>rename x5 | `[ AGU ]`<br>compute address | `[ L1D ]`<br>access **L1D**, hit | `[ WB ]`<br>drive Bypass[3] tag+data<br>**scoreboard** set exec_done<br>**Buffer** write result | `[ C ]`<br>commit<br>**INT_ARF** write x5<br>**INT_tag_mapping** clear busy |  |  |  |
| `add x6, x5, x3` - Dependent-G0 |  |  |  |  | `[ IB ]`<br>enqueue instruction | `[ dispatch ]`<br>allocate **scoreboard** entry<br>capture Commit CDB tag(x5), ready<br>write **ISQ_Group0**<br>rename x6 | `[ ALU0 ]`<br>execute add | `[ WB ]`<br>drive Bypass[0] tag+data<br>**scoreboard** set exec_done<br>**Buffer** write result | `[ C ]`<br>commit<br>**INT_ARF** write x6<br>**INT_tag_mapping** clear busy |

- **T6 (P4 capture, P4 → P1 bypass):** the producer's P3 has already passed, so the only remaining value source is the Commit CDB at P4; capturing there is also what keeps the dependent out of the completed-but-uncommitted stall — it leaves P1 with a ready payload instead of a `wait_tag`.
## Case 30: LOAD_to_ALU_delta_5 (arf_read)

**Dimension:** INT single-operand dependency | **Equiv:** LOAD_to_ALU
**Description:** Producer has already committed before dependent P1, so the source is read from ARF.

| Instruction | T1 | T2 | T3 | T4 | T5 | T6 | T7 | T8 | T9 | T10 |
|:---|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|
| `ld x5, 0(x1)` - Producer-G3 | `[ IB ]`<br>enqueue instruction | `[ dispatch ]`<br>allocate **scoreboard** entry<br>write **ISQ_Group3**<br>rename x5 | `[ AGU ]`<br>compute address | `[ L1D ]`<br>access **L1D**, hit | `[ WB ]`<br>drive Bypass[3] tag+data<br>**scoreboard** set exec_done<br>**Buffer** write result | `[ C ]`<br>commit<br>**INT_ARF** write x5<br>**INT_tag_mapping** clear busy |  |  |  |  |
| `add x6, x5, x3` - Dependent-G0 |  |  |  |  |  | `[ IB ]`<br>enqueue instruction | `[ dispatch ]`<br>allocate **scoreboard** entry<br>read **INT_ARF** x5<br>write **ISQ_Group0**<br>rename x6 | `[ ALU0 ]`<br>execute add | `[ WB ]`<br>drive Bypass[0] tag+data<br>**scoreboard** set exec_done<br>**Buffer** write result | `[ C ]`<br>commit<br>**INT_ARF** write x6<br>**INT_tag_mapping** clear busy |

- **T7 (ARF read, no bypass):** both bypass windows are shut — the producer committed at T6 and `INT_tag_mapping` cleared the entry — so the source is no longer a producer tag at all; the dependent reads `INT_ARF` at P1 as an ordinary architected operand and issues without any wakeup.
## Case 31: JALR_to_ALU_delta_0 (overlay)

**Dimension:** INT single-operand dependency | **Equiv:** JALR_to_ALU
**Description:** Same-bundle rename overlay gives the dependent the producer tag; the resident dependent waits for P3 forwarding.

| Instruction | T1 | T2 | T3 | T4 | T5 | T6 |
|:---|:---:|:---:|:---:|:---:|:---:|:---:|
| `jalr x5, 0(x10)` - Producer-G0 | `[ IB ]`<br>enqueue instruction | `[ dispatch ]`<br>allocate **scoreboard** entry<br>write **ISQ_Group0**<br>rename x5 | `[ BRU ]`<br>compute link | `[ WB ]`<br>drive Bypass[0] tag+data<br>**scoreboard** set exec_done<br>**Buffer** write result | `[ C ]`<br>commit<br>**INT_ARF** write x5<br>**INT_tag_mapping** clear busy |  |
| `add x6, x5, x3` - Dependent-G1 | `[ IB ]`<br>enqueue instruction | `[ dispatch ]`<br>allocate **scoreboard** entry<br>write **ISQ_Group1**<br>overlay tag(x5)<br>rename x6 | `[ ISQ_Group1 ]`<br>wait for Bypass[0] tag(x5) | `[ ALU1 ]`<br>**ISQ_Group1** capture Bypass[0] tag(x5)<br>execute add | `[ WB ]`<br>drive Bypass[1] tag+data<br>**scoreboard** set exec_done<br>**Buffer** write result | `[ C ]`<br>commit<br>**INT_ARF** write x6<br>**INT_tag_mapping** clear busy |

- **T2 (Rename overlay):** the dependent is accepted in the same bundle and stores the producer's freshly allocated tag as its `wait_tag`, so its ISQ wait is armed with no dispatch-side capture.
- **T4 (Resident wakeup, P3 → P2 bypass):** the bypass matches the stored tag and wakes the entry in the cycle the result appears; the internal steps of the producer only decide *when* that cycle is, never *whether* the match happens.
## Case 32: JALR_to_ALU_delta_1 (wait_for_p3)

**Dimension:** INT single-operand dependency | **Equiv:** JALR_to_ALU
**Description:** Dependent dispatches before producer P3, stores the `wait_tag` in ISQ, then wakes through resident-entry forwarding.

| Instruction | T1 | T2 | T3 | T4 | T5 | T6 |
|:---|:---:|:---:|:---:|:---:|:---:|:---:|
| `jalr x5, 0(x10)` - Producer-G0 | `[ IB ]`<br>enqueue instruction | `[ dispatch ]`<br>allocate **scoreboard** entry<br>write **ISQ_Group0**<br>rename x5 | `[ BRU ]`<br>compute link | `[ WB ]`<br>drive Bypass[0] tag+data<br>**scoreboard** set exec_done<br>**Buffer** write result | `[ C ]`<br>commit<br>**INT_ARF** write x5<br>**INT_tag_mapping** clear busy |  |
| `add x7, x5, x8` - Dependent-G0 |  | `[ IB ]`<br>enqueue instruction | `[ dispatch ]`<br>allocate **scoreboard** entry<br>write **ISQ_Group0**<br>rename x7 | `[ ALU0 ]`<br>**ISQ_Group0** capture Bypass[0] tag(x5)<br>execute add | `[ WB ]`<br>drive Bypass[0] tag+data<br>**scoreboard** set exec_done<br>**Buffer** write result | `[ C ]`<br>commit<br>**INT_ARF** write x7<br>**INT_tag_mapping** clear busy |

- **T3 (Wait-tag dispatch):** the dependent dispatches 1 cycle before the producer's P3, so the value cannot exist yet and it only records `wait_tag`; it then parks for that single cycle (T3).
- **T4 (Resident wakeup, P3 → P2 bypass):** the bypass matches the stored tag and wakes the entry in the cycle the result appears; the park length is a consequence of `delta`, not something the wakeup logic counts.
## Case 33: JALR_to_ALU_delta_2 (p3_capture)

**Dimension:** INT single-operand dependency | **Equiv:** JALR_to_ALU
**Description:** Dependent first P1 attempt exactly matches producer P3 Bypass and writes a ready ISQ payload.

| Instruction | T1 | T2 | T3 | T4 | T5 | T6 | T7 |
|:---|:---:|:---:|:---:|:---:|:---:|:---:|:---:|
| `jalr x5, 0(x10)` - Producer-G0 | `[ IB ]`<br>enqueue instruction | `[ dispatch ]`<br>allocate **scoreboard** entry<br>write **ISQ_Group0**<br>rename x5 | `[ BRU ]`<br>compute link | `[ WB ]`<br>drive Bypass[0] tag+data<br>**scoreboard** set exec_done<br>**Buffer** write result | `[ C ]`<br>commit<br>**INT_ARF** write x5<br>**INT_tag_mapping** clear busy |  |  |
| `add x6, x5, x3` - Dependent-G0 |  |  | `[ IB ]`<br>enqueue instruction | `[ dispatch ]`<br>allocate **scoreboard** entry<br>capture Bypass[0] tag(x5), ready<br>write **ISQ_Group0**<br>rename x6 | `[ ALU0 ]`<br>execute add | `[ WB ]`<br>drive Bypass[0] tag+data<br>**scoreboard** set exec_done<br>**Buffer** write result | `[ C ]`<br>commit<br>**INT_ARF** write x6<br>**INT_tag_mapping** clear busy |

- **T4 (P3 capture, P3 → P1 bypass):** the dependent's P1 lands exactly on the producer's P3, so the bypass is written straight into a *ready* ISQ payload — the resident-wait path is skipped entirely, and the dependent issues on the following cycle without ever parking on a tag.
## Case 34: JALR_to_ALU_delta_3 (p4_capture)

**Dimension:** INT single-operand dependency | **Equiv:** JALR_to_ALU
**Description:** Dependent first P1 attempt exactly matches producer P4 Commit CDB and captures `commit_data`.

| Instruction | T1 | T2 | T3 | T4 | T5 | T6 | T7 | T8 |
|:---|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|
| `jalr x5, 0(x10)` - Producer-G0 | `[ IB ]`<br>enqueue instruction | `[ dispatch ]`<br>allocate **scoreboard** entry<br>write **ISQ_Group0**<br>rename x5 | `[ BRU ]`<br>compute link | `[ WB ]`<br>drive Bypass[0] tag+data<br>**scoreboard** set exec_done<br>**Buffer** write result | `[ C ]`<br>commit<br>**INT_ARF** write x5<br>**INT_tag_mapping** clear busy |  |  |  |
| `add x6, x5, x3` - Dependent-G0 |  |  |  | `[ IB ]`<br>enqueue instruction | `[ dispatch ]`<br>allocate **scoreboard** entry<br>capture Commit CDB tag(x5), ready<br>write **ISQ_Group0**<br>rename x6 | `[ ALU0 ]`<br>execute add | `[ WB ]`<br>drive Bypass[0] tag+data<br>**scoreboard** set exec_done<br>**Buffer** write result | `[ C ]`<br>commit<br>**INT_ARF** write x6<br>**INT_tag_mapping** clear busy |

- **T5 (P4 capture, P4 → P1 bypass):** the producer's P3 has already passed, so the only remaining value source is the Commit CDB at P4; capturing there is also what keeps the dependent out of the completed-but-uncommitted stall — it leaves P1 with a ready payload instead of a `wait_tag`.
## Case 35: JALR_to_ALU_delta_4 (arf_read)

**Dimension:** INT single-operand dependency | **Equiv:** JALR_to_ALU
**Description:** Producer has already committed before dependent P1, so the source is read from ARF.

| Instruction | T1 | T2 | T3 | T4 | T5 | T6 | T7 | T8 | T9 |
|:---|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|
| `jalr x5, 0(x10)` - Producer-G0 | `[ IB ]`<br>enqueue instruction | `[ dispatch ]`<br>allocate **scoreboard** entry<br>write **ISQ_Group0**<br>rename x5 | `[ BRU ]`<br>compute link | `[ WB ]`<br>drive Bypass[0] tag+data<br>**scoreboard** set exec_done<br>**Buffer** write result | `[ C ]`<br>commit<br>**INT_ARF** write x5<br>**INT_tag_mapping** clear busy |  |  |  |  |
| `add x6, x5, x3` - Dependent-G0 |  |  |  |  | `[ IB ]`<br>enqueue instruction | `[ dispatch ]`<br>allocate **scoreboard** entry<br>read **INT_ARF** x5<br>write **ISQ_Group0**<br>rename x6 | `[ ALU0 ]`<br>execute add | `[ WB ]`<br>drive Bypass[0] tag+data<br>**scoreboard** set exec_done<br>**Buffer** write result | `[ C ]`<br>commit<br>**INT_ARF** write x6<br>**INT_tag_mapping** clear busy |

- **T6 (ARF read, no bypass):** both bypass windows are shut — the producer committed at T5 and `INT_tag_mapping` cleared the entry — so the source is no longer a producer tag at all; the dependent reads `INT_ARF` at P1 as an ordinary architected operand and issues without any wakeup.
## Case 36: ALU_to_ALU_delta_3_p4blocked (p4_capture, commit held)

**Dimension:** INT single-operand dependency | **Equiv:** ALU_to_ALU
**Description:** The producer writes back on the nominal cycle but cannot commit, because an older instruction is still in flight and retirement is in order, so its result stays in the Buffer. The dependent therefore finds no Commit CDB at its nominal P1 and must stall instead of capturing from P4.

| Instruction | T1 | T2 | T3 | T4 | T5 | T6 | T7 | T8 | T9 | T10 | T11 | T12 | T13 | T14 | T15 |
|:---|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|
| `div x7, x1, x2` - Blocker·G0 | `[ IB ]`<br>enqueue instruction | `[ dispatch ]`<br>allocate **scoreboard** entry<br>write **ISQ_Group0**<br>rename x7 | `[ DIV ]`<br>divide step 1/8 | `[ DIV ]`<br>divide step 2/8 | `[ DIV ]`<br>divide step 3/8 | `[ DIV ]`<br>divide step 4/8 | `[ DIV ]`<br>divide step 5/8 | `[ DIV ]`<br>divide step 6/8 | `[ DIV ]`<br>divide step 7/8 | `[ DIV ]`<br>divide step 8/8 | `[ WB ]`<br>drive Bypass[0] tag+data<br>**scoreboard** set exec_done<br>**Buffer** write result | `[ C ]`<br>commit<br>**INT_ARF** write x7<br>**INT_tag_mapping** clear busy |  |  |  |
| `add x5, x1, x2` - Producer·G1 |  | `[ IB ]`<br>enqueue instruction | `[ dispatch ]`<br>allocate **scoreboard** entry<br>write **ISQ_Group1**<br>rename x5 | `[ ALU1 ]`<br>execute add | `[ WB ]`<br>drive Bypass[1] tag+data<br>**scoreboard** set exec_done<br>**Buffer** write result | `[ Buffer ]`<br>hold<br>wait for commit | `[ Buffer ]`<br>hold<br>wait for commit | `[ Buffer ]`<br>hold<br>wait for commit | `[ Buffer ]`<br>hold<br>wait for commit | `[ Buffer ]`<br>hold<br>wait for commit | `[ Buffer ]`<br>hold<br>wait for commit | `[ C ]`<br>commit<br>**INT_ARF** write x5<br>**INT_tag_mapping** clear busy |  |  |  |
| `add x6, x5, x3` - Dependent·G1 |  |  |  |  |  |  |  |  |  |  | `[ IB ]`<br>enqueue instruction | `[ dispatch ]`<br>allocate **scoreboard** entry<br>capture Commit CDB tag(x5), ready<br>write **ISQ_Group1**<br>rename x6 | `[ ALU1 ]`<br>execute add | `[ WB ]`<br>drive Bypass[1] tag+data<br>**scoreboard** set exec_done<br>**Buffer** write result | `[ C ]`<br>commit<br>**INT_ARF** write x6<br>**INT_tag_mapping** clear busy |

- **T1 (Blocker, one cycle ahead of the producer):** the older `div x7, x1, x2` is enqueued alone and routed
  to G0. Putting it one cycle earlier rather than beside the producer is not cosmetic: when both G0 and G1
  are taken in the producer's own enqueue cycle, the dependent's dispatch can only land on the cycles where
  its group's ISQ entry frees, and the delta quantises to 2 or 6 — 3 is unreachable. With the blocker ahead
  of it the producer and dependent share G1 and the dependent's dispatch is free to land on 3.
- **Producer WB at T5, on schedule:** the result enters the Buffer in the nominal cycle. The writeback is
  not delayed; only the commit is.
- **T6 (Nominal P4 — no Commit CDB):** the older `div`, issued at T3 with L=8, retires no earlier than T12,
  and retirement is in order while writeback is not. The producer therefore sits in the Buffer, `P4 − P3`
  is greater than 1, and the dependent's P1 finds nothing to capture.
- **Expected deviation (the measured quantity):** the dependent stalls (Condition A) instead of capturing
  from P4, and resolves only after the producer retires.
- **Acceptance (mechanism-based — delta is an output here, not an input):**
  1. `producer.P3 − P2 == L`: the writeback was not disturbed, which is what separates "commit held"
     from "execution delayed";
  2. `producer.P4 − P3 > 1`: the commit really was held. If it is 1 the blocker retired in time and the
     case missed its target state — report that rather than passing it;
  3. `dependent.P2 − P1 == 1`: the dependent had its operands in its dispatch cycle, i.e. it captured
     rather than waited;
  4. `dependent.P1 == producer.P4`: dispatch followed the held commit — as a *consequence* of the rule
     below, not as a rule of its own.

  **Do not assert a target delta for this class.** The dependent cannot be dispatched while the producer is
  *completed but not yet committed*: its writeback bypass is a single-cycle broadcast that has already
  passed, and there is no commit-to-issue path, so a consumer parked on it could never be woken. The front
  end therefore refuses to let such a consumer into an ISQ — `p1/dependency_check.sv` raises
  `slot_missed_wakeup` and `p1/dispatch_logic.sv` (lines 394 and 417) folds it into the dispatch guard.
  The consumer starts once its value can be taken from the Commit CDB instead, so its delta is whatever the
  hold makes it, not a number the case chooses. The boundary this predicts — blocked for a dispatch that
  lands after the producer's writeback and up to its commit, allowed on the writeback cycle itself and
  before it — is what the injection sweep reproduces.
## Case 37: MUL_to_ALU_delta_5_p4blocked (p4_capture, commit held)

**Dimension:** INT single-operand dependency | **Equiv:** MUL_to_ALU
**Description:** The producer writes back on the nominal cycle but cannot commit, because an older instruction is still in flight and retirement is in order, so its result stays in the Buffer. The dependent therefore finds no Commit CDB at its nominal P1 and must stall instead of capturing from P4.

| Instruction | T1 | T2 | T3 | T4 | T5 | T6 | T7 | T8 | T9 | T10 | T11 | T12 | T13 | T14 | T15 |
|:---|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|
| `div x7, x1, x2` - Blocker·G0 | `[ IB ]`<br>enqueue instruction | `[ dispatch ]`<br>allocate **scoreboard** entry<br>write **ISQ_Group0**<br>rename x7 | `[ DIV ]`<br>divide step 1/8 | `[ DIV ]`<br>divide step 2/8 | `[ DIV ]`<br>divide step 3/8 | `[ DIV ]`<br>divide step 4/8 | `[ DIV ]`<br>divide step 5/8 | `[ DIV ]`<br>divide step 6/8 | `[ DIV ]`<br>divide step 7/8 | `[ DIV ]`<br>divide step 8/8 | `[ WB ]`<br>drive Bypass[0] tag+data<br>**scoreboard** set exec_done<br>**Buffer** write result | `[ C ]`<br>commit<br>**INT_ARF** write x7<br>**INT_tag_mapping** clear busy |  |  |  |
| `mul x5, x1, x2` - Producer-G1 | `[ IB ]`<br>enqueue instruction | `[ dispatch ]`<br>allocate **scoreboard** entry<br>write **ISQ_Group1**<br>rename x5 | `[ MUL ]`<br>execute mul step 1/3 | `[ MUL ]`<br>execute mul step 2/3 | `[ MUL ]`<br>execute mul step 3/3 | `[ WB ]`<br>drive Bypass[1] tag+data<br>**scoreboard** set exec_done<br>**Buffer** write result | `[ Buffer ]`<br>hold<br>wait for commit | `[ Buffer ]`<br>hold<br>wait for commit | `[ Buffer ]`<br>hold<br>wait for commit | `[ Buffer ]`<br>hold<br>wait for commit | `[ Buffer ]`<br>hold<br>wait for commit | `[ C ]`<br>commit<br>**INT_ARF** write x5<br>**INT_tag_mapping** clear busy |  |  |  |
| `add x6, x5, x3` - Dependent-G1 |  |  |  |  |  |  |  |  |  |  | `[ IB ]`<br>enqueue instruction | `[ dispatch ]`<br>allocate **scoreboard** entry<br>capture Commit CDB tag(x5), ready<br>write **ISQ_Group1**<br>rename x6 | `[ ALU1 ]`<br>execute add | `[ WB ]`<br>drive Bypass[1] tag+data<br>**scoreboard** set exec_done<br>**Buffer** write result | `[ C ]`<br>commit<br>**INT_ARF** write x6<br>**INT_tag_mapping** clear busy |

- **T1 (Blocker and producer enqueued together):** the older `div x7, x1, x2` is routed to G0 and the producer to the
  other ALU group, so the two take separate ISQ entries. The blocker is listed first so it lands in slot 0,
  which is what forces the flexible producer off G0.
- **Producer WB (on schedule):** the producer's result enters the Buffer in the same cycle as the nominal
  figure. This is the point of the construction — the writeback is *not* delayed, only the commit is.
- **Nominal P4 (Commit CDB expected, does not appear):** the older `div x7, x1, x2` has not retired, and retirement is
  in order while writeback is not, so the producer stays in the Buffer. No Commit CDB is presented and a
  P4 → P1 capture is impossible in that cycle.
- **Expected deviation (this is what the case measures):** the dependent cannot capture. It stalls
  (Condition A) and resolves only after the producer retires; its resolution cycle and the path it finally
  uses are the measured quantities, not predictions.
- **Acceptance (mechanism-based — delta is an output here, not an input):**
  1. `producer.P3 − P2 == L`: the writeback was not disturbed, which is what separates "commit held"
     from "execution delayed";
  2. `producer.P4 − P3 > 1`: the commit really was held. If it is 1 the blocker retired in time and the
     case missed its target state — report that rather than passing it;
  3. `dependent.P2 − P1 == 1`: the dependent had its operands in its dispatch cycle, i.e. it captured
     rather than waited;
  4. `dependent.P1 == producer.P4`: dispatch followed the held commit — as a *consequence* of the rule
     below, not as a rule of its own.

  **Do not assert a target delta for this class.** The dependent cannot be dispatched while the producer is
  *completed but not yet committed*: its writeback bypass is a single-cycle broadcast that has already
  passed, and there is no commit-to-issue path, so a consumer parked on it could never be woken. The front
  end therefore refuses to let such a consumer into an ISQ — `p1/dependency_check.sv` raises
  `slot_missed_wakeup` and `p1/dispatch_logic.sv` (lines 394 and 417) folds it into the dispatch guard.
  The consumer starts once its value can be taken from the Commit CDB instead, so its delta is whatever the
  hold makes it, not a number the case chooses. The boundary this predicts — blocked for a dispatch that
  lands after the producer's writeback and up to its commit, allowed on the writeback cycle itself and
  before it — is what the injection sweep reproduces.
## Case 38: DIV_to_ALU_delta_10_p4blocked (p4_capture, commit held; deferred)

**Dimension:** INT single-operand dependency | **Equiv:** DIV_to_ALU
**Description:** The producer writes back on the nominal cycle but cannot commit, because an older instruction is still in flight and retirement is in order, so its result stays in the Buffer. The dependent therefore finds no Commit CDB at its nominal P1 and must stall instead of capturing from P4.

> **Deferred table:** the schedule below is the nominal P4-capture timing. With `mul` as the blocker,
> `mul.C = T7 < div.P3 = T11`, so the commit is not held and the `p4blocked` condition is not realized.
> See the deferred note at the end of this case.

| Instruction | T1 | T2 | T3 | T4 | T5 | T6 | T7 | T8 | T9 | T10 | T11 | T12 | T13 | T14 | T15 |
|:---|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|
| `mul x7, x1, x2` - Blocker·G1 | `[ IB ]`<br>enqueue instruction | `[ dispatch ]`<br>allocate **scoreboard** entry<br>write **ISQ_Group1**<br>rename x7 | `[ MUL ]`<br>execute mul step 1/3 | `[ MUL ]`<br>execute mul step 2/3 | `[ MUL ]`<br>execute mul step 3/3 | `[ WB ]`<br>drive Bypass[1] tag+data<br>**scoreboard** set exec_done<br>**Buffer** write result | `[ C ]`<br>commit<br>**INT_ARF** write x7<br>**INT_tag_mapping** clear busy |  |  |  |  |  |  |  |  |
| `div x5, x1, x2` - Producer-G0 | `[ IB ]`<br>enqueue instruction | `[ dispatch ]`<br>allocate **scoreboard** entry<br>write **ISQ_Group0**<br>rename x5 | `[ DIV ]`<br>divide step 1/8 | `[ DIV ]`<br>divide step 2/8 | `[ DIV ]`<br>divide step 3/8 | `[ DIV ]`<br>divide step 4/8 | `[ DIV ]`<br>divide step 5/8 | `[ DIV ]`<br>divide step 6/8 | `[ DIV ]`<br>divide step 7/8 | `[ DIV ]`<br>divide step 8/8 | `[ WB ]`<br>drive Bypass[0] tag+data<br>**scoreboard** set exec_done<br>**Buffer** write result | `[ C ]`<br>commit<br>**INT_ARF** write x5<br>**INT_tag_mapping** clear busy |  |  |  |
| `add x6, x5, x3` - Dependent-G0 |  |  |  |  |  |  |  |  |  |  | `[ IB ]`<br>enqueue instruction | `[ dispatch ]`<br>allocate **scoreboard** entry<br>capture Commit CDB tag(x5), ready<br>write **ISQ_Group0**<br>rename x6 | `[ ALU0 ]`<br>execute add | `[ WB ]`<br>drive Bypass[0] tag+data<br>**scoreboard** set exec_done<br>**Buffer** write result | `[ C ]`<br>commit<br>**INT_ARF** write x6<br>**INT_tag_mapping** clear busy |

- **T1 (Blocker and producer enqueued together):** the older `mul x7, x1, x2` is routed to G1 and the producer to the
  other ALU group, so the two take separate ISQ entries. The blocker is listed first so it lands in slot 0,
  which is what forces the flexible producer off G1.
- **Producer WB (on schedule):** the producer's result enters the Buffer in the same cycle as the nominal
  figure. This is the point of the construction — the writeback is *not* delayed, only the commit is.
- **Nominal P4 (Commit CDB expected, does not appear):** the older `mul x7, x1, x2` has not retired, and retirement is
  in order while writeback is not, so the producer stays in the Buffer. No Commit CDB is presented and a
  P4 → P1 capture is impossible in that cycle.
- **Expected deviation (this is what the case measures):** the dependent cannot capture. It stalls
  (Condition A) and resolves only after the producer retires; its resolution cycle and the path it finally
  uses are the measured quantities, not predictions.
- **Deferred — the case is kept, not dropped.** Constructing it needs a blocker that retires *after* the
  producer's writeback, i.e. one slower than the producer. The producer is a DIV with latency eight, and
  every integer functional unit currently sits at eight or below (MUL 3, LOAD 2, DIV 8), so no blocker is
  late enough and the commit is never held: measurement gives `P4 − P3 = 1`.
  **Current latencies do not support constructing this case; revisit it once a cold-miss load or another
  memory-side slow blocker is available.** Until then this case is neither passing nor failing — it is
  deferred.
## Case 39: LOAD_to_ALU_delta_4_p4blocked (p4_capture, commit held)

**Dimension:** INT single-operand dependency | **Equiv:** LOAD_to_ALU
**Description:** The producer writes back on the nominal cycle but cannot commit, because an older instruction is still in flight and retirement is in order, so its result stays in the Buffer. The dependent therefore finds no Commit CDB at its nominal P1 and must stall instead of capturing from P4.

> **Status: retest pending.** The schedule below is the nominal P4-capture timing. The earlier `delta_5`
> form of this case passed; the `delta_4` form has not reproduced the target state yet, so it must be
> re-measured before it counts as passing. See `INT_single_operand_dependency_caselist_v1.md` §P4-blocked.

| Instruction | T1 | T2 | T3 | T4 | T5 | T6 | T7 | T8 | T9 | T10 | T11 | T12 | T13 | T14 | T15 |
|:---|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|
| `div x7, x1, x2` - Blocker·G0 | `[ IB ]`<br>enqueue instruction | `[ dispatch ]`<br>allocate **scoreboard** entry<br>write **ISQ_Group0**<br>rename x7 | `[ DIV ]`<br>divide step 1/8 | `[ DIV ]`<br>divide step 2/8 | `[ DIV ]`<br>divide step 3/8 | `[ DIV ]`<br>divide step 4/8 | `[ DIV ]`<br>divide step 5/8 | `[ DIV ]`<br>divide step 6/8 | `[ DIV ]`<br>divide step 7/8 | `[ DIV ]`<br>divide step 8/8 | `[ WB ]`<br>drive Bypass[0] tag+data<br>**scoreboard** set exec_done<br>**Buffer** write result | `[ C ]`<br>commit<br>**INT_ARF** write x7<br>**INT_tag_mapping** clear busy |  |  |  |
| `ld x5, 0(x1)` - Producer-G3 | `[ IB ]`<br>enqueue instruction | `[ dispatch ]`<br>allocate **scoreboard** entry<br>write **ISQ_Group3**<br>rename x5 | `[ AGU ]`<br>compute address | `[ L1D ]`<br>access **L1D**, hit | `[ WB ]`<br>drive Bypass[3] tag+data<br>**scoreboard** set exec_done<br>**Buffer** write result | `[ Buffer ]`<br>hold<br>wait for commit | `[ Buffer ]`<br>hold<br>wait for commit | `[ Buffer ]`<br>hold<br>wait for commit | `[ Buffer ]`<br>hold<br>wait for commit | `[ Buffer ]`<br>hold<br>wait for commit | `[ Buffer ]`<br>hold<br>wait for commit | `[ C ]`<br>commit<br>**INT_ARF** write x5<br>**INT_tag_mapping** clear busy |  |  |  |
| `add x6, x5, x3` - Dependent-G1 |  |  |  |  |  |  |  |  |  |  | `[ IB ]`<br>enqueue instruction | `[ dispatch ]`<br>allocate **scoreboard** entry<br>capture Commit CDB tag(x5), ready<br>write **ISQ_Group1**<br>rename x6 | `[ ALU1 ]`<br>execute add | `[ WB ]`<br>drive Bypass[1] tag+data<br>**scoreboard** set exec_done<br>**Buffer** write result | `[ C ]`<br>commit<br>**INT_ARF** write x6<br>**INT_tag_mapping** clear busy |

- **T1 (Blocker and producer enqueued together):** the older `div x7, x1, x2` is routed to G0 and the producer to the
  other ALU group, so the two take separate ISQ entries. The blocker is listed first so it lands in slot 0,
  which is what forces the flexible producer off G0.
- **Producer WB (on schedule):** the producer's result enters the Buffer in the same cycle as the nominal
  figure. This is the point of the construction — the writeback is *not* delayed, only the commit is.
- **Nominal P4 (Commit CDB expected, does not appear):** the older `div x7, x1, x2` has not retired, and retirement is
  in order while writeback is not, so the producer stays in the Buffer. No Commit CDB is presented and a
  P4 → P1 capture is impossible in that cycle.
- **Expected deviation (this is what the case measures):** the dependent cannot capture. It stalls
  (Condition A) and resolves only after the producer retires; its resolution cycle and the path it finally
  uses are the measured quantities, not predictions.
- **Acceptance (mechanism-based — delta is an output here, not an input):**
  1. `producer.P3 − P2 == L`: the writeback was not disturbed, which is what separates "commit held"
     from "execution delayed";
  2. `producer.P4 − P3 > 1`: the commit really was held. If it is 1 the blocker retired in time and the
     case missed its target state — report that rather than passing it;
  3. `dependent.P2 − P1 == 1`: the dependent had its operands in its dispatch cycle, i.e. it captured
     rather than waited;
  4. `dependent.P1 == producer.P4`: dispatch followed the held commit — as a *consequence* of the rule
     below, not as a rule of its own.

  **Do not assert a target delta for this class.** The dependent cannot be dispatched while the producer is
  *completed but not yet committed*: its writeback bypass is a single-cycle broadcast that has already
  passed, and there is no commit-to-issue path, so a consumer parked on it could never be woken. The front
  end therefore refuses to let such a consumer into an ISQ — `p1/dependency_check.sv` raises
  `slot_missed_wakeup` and `p1/dispatch_logic.sv` (lines 394 and 417) folds it into the dispatch guard.
  The consumer starts once its value can be taken from the Commit CDB instead, so its delta is whatever the
  hold makes it, not a number the case chooses. The boundary this predicts — blocked for a dispatch that
  lands after the producer's writeback and up to its commit, allowed on the writeback cycle itself and
  before it — is what the injection sweep reproduces.
## Case 40: JALR_to_ALU_delta_3_p4blocked (p4_capture, commit held)

**Dimension:** INT single-operand dependency | **Equiv:** JALR_to_ALU
**Description:** The producer writes back on the nominal cycle but cannot commit, because an older instruction is still in flight and retirement is in order, so its result stays in the Buffer. The dependent therefore finds no Commit CDB at its nominal P1 and must stall instead of capturing from P4.

| Instruction | T1 | T2 | T3 | T4 | T5 | T6 | T7 | T8 | T9 | T10 |
|:---|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|
| `mul x7, x1, x2` - Blocker·G1 | `[ IB ]`<br>enqueue instruction | `[ dispatch ]`<br>allocate **scoreboard** entry<br>write **ISQ_Group1**<br>rename x7 | `[ MUL ]`<br>execute mul step 1/3 | `[ MUL ]`<br>execute mul step 2/3 | `[ MUL ]`<br>execute mul step 3/3 | `[ WB ]`<br>drive Bypass[1] tag+data<br>**scoreboard** set exec_done<br>**Buffer** write result | `[ C ]`<br>commit<br>**INT_ARF** write x7<br>**INT_tag_mapping** clear busy |  |  |  |
| `jalr x5, 0(x10)` - Producer-G0 | `[ IB ]`<br>enqueue instruction | `[ dispatch ]`<br>allocate **scoreboard** entry<br>write **ISQ_Group0**<br>rename x5 | `[ BRU ]`<br>compute link | `[ WB ]`<br>drive Bypass[0] tag+data<br>**scoreboard** set exec_done<br>**Buffer** write result | `[ Buffer ]`<br>hold<br>wait for commit | `[ Buffer ]`<br>hold<br>wait for commit | `[ C ]`<br>commit<br>**INT_ARF** write x5<br>**INT_tag_mapping** clear busy |  |  |  |
| `add x6, x5, x3` - Dependent-G0 |  |  |  |  |  | `[ IB ]`<br>enqueue instruction | `[ dispatch ]`<br>allocate **scoreboard** entry<br>capture Commit CDB tag(x5), ready<br>write **ISQ_Group0**<br>rename x6 | `[ ALU0 ]`<br>execute add | `[ WB ]`<br>drive Bypass[0] tag+data<br>**scoreboard** set exec_done<br>**Buffer** write result | `[ C ]`<br>commit<br>**INT_ARF** write x6<br>**INT_tag_mapping** clear busy |

- **T1 (Blocker and producer enqueued together):** the older `mul x7, x1, x2` is routed to G1 and the producer to the
  other ALU group, so the two take separate ISQ entries. The blocker is listed first so it lands in slot 0,
  which is what forces the flexible producer off G1.
- **Producer WB (on schedule):** the producer's result enters the Buffer in the same cycle as the nominal
  figure. This is the point of the construction — the writeback is *not* delayed, only the commit is.
- **Nominal P4 (Commit CDB expected, does not appear):** the older `mul x7, x1, x2` has not retired, and retirement is
  in order while writeback is not, so the producer stays in the Buffer. No Commit CDB is presented and a
  P4 → P1 capture is impossible in that cycle.
- **Expected deviation (this is what the case measures):** the dependent cannot capture. It stalls
  (Condition A) and resolves only after the producer retires; its resolution cycle and the path it finally
  uses are the measured quantities, not predictions.
- **Acceptance (mechanism-based — delta is an output here, not an input):**
  1. `producer.P3 − P2 == L`: the writeback was not disturbed, which is what separates "commit held"
     from "execution delayed";
  2. `producer.P4 − P3 > 1`: the commit really was held. If it is 1 the blocker retired in time and the
     case missed its target state — report that rather than passing it;
  3. `dependent.P2 − P1 == 1`: the dependent had its operands in its dispatch cycle, i.e. it captured
     rather than waited;
  4. `dependent.P1 == producer.P4`: dispatch followed the held commit — as a *consequence* of the rule
     below, not as a rule of its own.

  **Do not assert a target delta for this class.** The dependent cannot be dispatched while the producer is
  *completed but not yet committed*: its writeback bypass is a single-cycle broadcast that has already
  passed, and there is no commit-to-issue path, so a consumer parked on it could never be woken. The front
  end therefore refuses to let such a consumer into an ISQ — `p1/dependency_check.sv` raises
  `slot_missed_wakeup` and `p1/dispatch_logic.sv` (lines 394 and 417) folds it into the dispatch guard.
  The consumer starts once its value can be taken from the Commit CDB instead, so its delta is whatever the
  hold makes it, not a number the case chooses. The boundary this predicts — blocked for a dispatch that
  lands after the producer's writeback and up to its commit, allowed on the writeback cycle itself and
  before it — is what the injection sweep reproduces.
