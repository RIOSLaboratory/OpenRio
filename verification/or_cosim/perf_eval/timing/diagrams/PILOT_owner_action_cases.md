# OR BE Timing Diagram — Owner/Action Pilot

Pilot for the cell format in `RULES_GENERAL.md` (G2 owner, G3 state, G4 action/result,
G5 submodule marking, G6 OR BE vocabulary). The timing numbers are unchanged from the
existing diagrams; only the cell content is expanded.

`delta` is always `dependent.P1 dispatch − producer.P1 dispatch`, not an IB-to-IB
difference. Every lane still starts at P0 `IB`; the IB cycle is shown for pipeline
context and is one cycle before that instruction's own `dispatch`.

<style>
table { display: block; overflow-x: auto; width: 100%; }
th, td { white-space: nowrap !important; }
</style>

## Case 1: ALU_to_ALU_delta_0 (overlay)

**Dimension:** INT single-operand dependency · **Equiv:** ALU_to_ALU
**Description:** Same-bundle rename overlay gives the dependent the producer tag; the resident dependent waits for P3 forwarding.

| Instruction | T1 | T2 | T3 | T4 | T5 | T6 |
|:---|:---|:---|:---|:---|:---|:---|
| `add x5, x1, x2` · Producer·G0 | `[ IB ]`<br>enqueue instruction | `[ dispatch ]`<br>allocate **scoreboard** entry<br>write **ISQ_Group0**<br>rename x5 | `[ ALU0 ]`<br>execute add | `[ WB ]`<br>drive Bypass[0] tag+data<br>**scoreboard** set exec_done<br>**Buffer** write result | `[ C ]`<br>commit<br>**INT_ARF** write x5<br>**INT_tag_mapping** clear busy |  |
| `add x6, x5, x3` · Dependent·G1 | `[ IB ]`<br>enqueue instruction | `[ dispatch ]`<br>allocate **scoreboard** entry<br>write **ISQ_Group1**<br>overlay tag(x5) | `[ ISQ_Group1 ]`<br>wait for Bypass[0] tag(x5) | `[ ALU1 ]`<br>**ISQ_Group1** capture Bypass[0] tag(x5)<br>execute add | `[ WB ]`<br>drive Bypass[1] tag+data<br>**scoreboard** set exec_done<br>**Buffer** write result | `[ C ]`<br>commit<br>**INT_ARF** write x6<br>**INT_tag_mapping** clear busy |

- **T2 (overlay):** the dependent is in the same dispatch bundle and carries `tag(x5)` instead of reading `x5` from ARF, so it must wait for the producer's P3.
- **T4 (P3 → P2 bypass):** the producer's WB drives `Bypass[0]` with tag+data; the resident **ISQ_Group1** entry matches `tag(x5)`, captures the data, and the dependent issues in the same cycle.

## Case 2: DIV_to_ALU_delta_9 (p3_capture)

**Dimension:** INT single-operand dependency · **Equiv:** DIV_to_ALU
**Description:** Dependent first P1 attempt exactly matches producer P3 Bypass and writes a ready ISQ payload.

| Instruction | T1 | T2 | T3 | T4 | T5 | T6 | T7 | T8 | T9 | T10 | T11 | T12 | T13 | T14 |
|:---|:---|:---|:---|:---|:---|:---|:---|:---|:---|:---|:---|:---|:---|:---|
| `div x5, x1, x2` · Producer·G0 | `[ IB ]`<br>enqueue instruction | `[ dispatch ]`<br>allocate **scoreboard** entry<br>write **ISQ_Group0**<br>rename x5 | `[ DIV ]`<br>divide step 1/8 | `[ DIV ]`<br>divide step 2/8 | `[ DIV ]`<br>divide step 3/8 | `[ DIV ]`<br>divide step 4/8 | `[ DIV ]`<br>divide step 5/8 | `[ DIV ]`<br>divide step 6/8 | `[ DIV ]`<br>divide step 7/8 | `[ DIV ]`<br>divide step 8/8 | `[ WB ]`<br>drive Bypass[0] tag+data<br>**scoreboard** set exec_done<br>**Buffer** write result | `[ C ]`<br>commit<br>**INT_ARF** write x5<br>**INT_tag_mapping** clear busy |  |  |
| `add x6, x5, x3` · Dependent·G0 |  |  |  |  |  |  |  |  |  | `[ IB ]`<br>enqueue instruction | `[ dispatch ]`<br>allocate **scoreboard** entry<br>capture Bypass[0] tag(x5), ready<br>write **ISQ_Group0**<br>rename x6 | `[ ALU0 ]`<br>execute add | `[ WB ]`<br>drive Bypass[0] tag+data<br>**scoreboard** set exec_done<br>**Buffer** write result | `[ C ]`<br>commit<br>**INT_ARF** write x6<br>**INT_tag_mapping** clear busy |

- **T3–T10 (DIV busy):** the producer holds **DIV** for eight divide steps; its writeback is not visible until T11.
- **T11 (P3 capture):** the dependent's dispatch matches `Bypass[0] tag(x5)` and writes a ready ISQ payload; it issues at T12, not in the capture cycle.

## Case 3: LOAD_to_ALU_delta_3 (p3_capture)

**Dimension:** INT single-operand dependency · **Equiv:** LOAD_to_ALU
**Description:** Dependent first P1 attempt exactly matches producer P3 Bypass and writes a ready ISQ payload.

| Instruction | T1 | T2 | T3 | T4 | T5 | T6 | T7 | T8 |
|:---|:---|:---|:---|:---|:---|:---|:---|:---|
| `ld x5, 0(x1)` · Producer·G3 | `[ IB ]`<br>enqueue instruction | `[ dispatch ]`<br>allocate **scoreboard** entry<br>write **ISQ_Group3**<br>rename x5 | `[ AGU ]`<br>compute address | `[ L1D ]`<br>access **L1D**, hit | `[ WB ]`<br>drive Bypass[3] tag+data<br>**scoreboard** set exec_done<br>**Buffer** write result | `[ C ]`<br>commit<br>**INT_ARF** write x5<br>**INT_tag_mapping** clear busy |  |  |
| `add x6, x5, x3` · Dependent·G0 |  |  |  | `[ IB ]`<br>enqueue instruction | `[ dispatch ]`<br>allocate **scoreboard** entry<br>capture Bypass[3] tag(x5), ready<br>write **ISQ_Group0**<br>rename x6 | `[ ALU0 ]`<br>execute add | `[ WB ]`<br>drive Bypass[0] tag+data<br>**scoreboard** set exec_done<br>**Buffer** write result | `[ C ]`<br>commit<br>**INT_ARF** write x6<br>**INT_tag_mapping** clear busy |

- **T3 (AGU):** the load computes its address; the cache access is a separate L1D cycle at T4.
- **T4 (L1D hit):** the load data is returned in the same cycle; **L1D** is the acting block.
- **T4 (dependent IB) / T5 (dependent dispatch):** the dependent is enqueued at T4 and dispatches at T5. `delta = 5 − 2 = 3` (dispatch-to-dispatch), not `5 − 1`.
- **T5 (P3 capture):** the dependent captures `Bypass[3] tag(x5)` into its dispatch payload and issues at T6.

## Case 4: ALU_to_ALU_delta_3_p4blocked (p4_capture, commit held)

**Dimension:** INT single-operand dependency · **Equiv:** ALU_to_ALU
**Description:** The producer writes back on the nominal cycle but cannot commit because the older DIV is still in flight; the result stays in the Buffer and the dependent captures the held Commit CDB.

| Instruction | T1 | T2 | T3 | T4 | T5 | T6 | T7 | T8 | T9 | T10 | T11 | T12 | T13 | T14 | T15 |
|:---|:---|:---|:---|:---|:---|:---|:---|:---|:---|:---|:---|:---|:---|:---|:---|
| `div x7, x1, x2` · Blocker·G0 | `[ IB ]`<br>enqueue instruction | `[ dispatch ]`<br>allocate **scoreboard** entry<br>write **ISQ_Group0**<br>rename x7 | `[ DIV ]`<br>divide step 1/8 | `[ DIV ]`<br>divide step 2/8 | `[ DIV ]`<br>divide step 3/8 | `[ DIV ]`<br>divide step 4/8 | `[ DIV ]`<br>divide step 5/8 | `[ DIV ]`<br>divide step 6/8 | `[ DIV ]`<br>divide step 7/8 | `[ DIV ]`<br>divide step 8/8 | `[ WB ]`<br>drive Bypass[0] tag+data<br>**scoreboard** set exec_done<br>**Buffer** write result | `[ C ]`<br>commit<br>**INT_ARF** write x7<br>**INT_tag_mapping** clear busy |  |  |  |
| `add x5, x1, x2` · Producer·G1 |  | `[ IB ]`<br>enqueue instruction | `[ dispatch ]`<br>allocate **scoreboard** entry<br>write **ISQ_Group1**<br>rename x5 | `[ ALU1 ]`<br>execute add | `[ WB ]`<br>drive Bypass[1] tag+data<br>**scoreboard** set exec_done<br>**Buffer** write result | `[ Buffer ]`<br>hold<br>wait for commit | `[ Buffer ]`<br>hold<br>wait for commit | `[ Buffer ]`<br>hold<br>wait for commit | `[ Buffer ]`<br>hold<br>wait for commit | `[ Buffer ]`<br>hold<br>wait for commit | `[ Buffer ]`<br>hold<br>wait for commit | `[ C ]`<br>commit<br>**INT_ARF** write x5<br>**INT_tag_mapping** clear busy |  |  |  |
| `add x6, x5, x3` · Dependent·G1 |  |  |  |  |  |  |  |  |  |  | `[ IB ]`<br>enqueue instruction | `[ dispatch ]`<br>allocate **scoreboard** entry<br>capture Commit CDB tag(x5), ready<br>write **ISQ_Group1**<br>rename x6 | `[ ALU1 ]`<br>execute add | `[ WB ]`<br>drive Bypass[1] tag+data<br>**scoreboard** set exec_done<br>**Buffer** write result | `[ C ]`<br>commit<br>**INT_ARF** write x6<br>**INT_tag_mapping** clear busy |

- **T5 (producer WB):** the producer writes back on schedule; the result is in the Buffer, not yet at commit.
- **T6–T11 (Buffer hold):** the older DIV has not retired, so the producer stays live in the buffer; these cycles are `[ Buffer ]`, not empty.
- **T12 (held P4):** the older DIV and the producer commit together; the dependent's dispatch captures `Commit CDB tag(x5)` and issues at T13.

## Case 5: INT2_G1P3_G0P3 (two P3 sources)

**Dimension:** INT two-operand ready-source composition · **Equiv:** G1 P3 Bypass + G0 P3 Bypass
**Description:** Dependent captures rs1 from G1 Bypass (MUL) and rs2 from G0 Bypass (DIV) in the same source-ready cycle.

| Instruction | T1 | T2 | T3 | T4 | T5 | T6 | T7 | T8 | T9 | T10 | T11 | T12 | T13 | T14 |
|:---|:---|:---|:---|:---|:---|:---|:---|:---|:---|:---|:---|:---|:---|:---|
| `div x6, x3, x4` · P3 source·G0 | `[ IB ]`<br>enqueue instruction | `[ dispatch ]`<br>allocate **scoreboard** entry<br>write **ISQ_Group0**<br>rename x6 | `[ DIV ]`<br>divide step 1/8 | `[ DIV ]`<br>divide step 2/8 | `[ DIV ]`<br>divide step 3/8 | `[ DIV ]`<br>divide step 4/8 | `[ DIV ]`<br>divide step 5/8 | `[ DIV ]`<br>divide step 6/8 | `[ DIV ]`<br>divide step 7/8 | `[ DIV ]`<br>divide step 8/8 | `[ WB ]`<br>drive Bypass[0] tag+data<br>**scoreboard** set exec_done<br>**Buffer** write result | `[ C ]`<br>commit<br>**INT_ARF** write x6<br>**INT_tag_mapping** clear busy |  |  |
| `mul x8, x1, x2` · P3 source·G1 |  |  |  |  |  | `[ IB ]`<br>enqueue instruction | `[ dispatch ]`<br>allocate **scoreboard** entry<br>write **ISQ_Group1**<br>rename x8 | `[ MUL ]`<br>execute mul step 1/3 | `[ MUL ]`<br>execute mul step 2/3 | `[ MUL ]`<br>execute mul step 3/3 | `[ WB ]`<br>drive Bypass[1] tag+data<br>**scoreboard** set exec_done<br>**Buffer** write result | `[ C ]`<br>commit<br>**INT_ARF** write x8<br>**INT_tag_mapping** clear busy |  |  |
| `add x20, x8, x6` · Dependent·G0 |  |  |  |  |  |  |  |  |  | `[ IB ]`<br>enqueue instruction | `[ dispatch ]`<br>allocate **scoreboard** entry<br>capture Bypass[0] tag(x6), ready<br>capture Bypass[1] tag(x8), ready<br>write **ISQ_Group0**<br>rename x20 | `[ ALU0 ]`<br>execute add | `[ WB ]`<br>drive Bypass[0] tag+data<br>**scoreboard** set exec_done<br>**Buffer** write result | `[ C ]`<br>commit<br>**INT_ARF** write x20<br>**INT_tag_mapping** clear busy |

- **T11 (two-source capture):** the dependent's dispatch matches `Bypass[0] tag(x6)` and `Bypass[1] tag(x8)` in the same cycle and writes a ready ISQ payload.
- **T12 (issue):** the dependent issues one cycle after the capture; both producers commit in the same cycle.
