# INT Two-Operands Ready-Source Dependency Timing Diagrams

<style>
table { display: block; overflow-x: auto; width: 100%; }
th, td { white-space: nowrap !important; }
</style>

Source caselist: `../caselists/INT_two_operands_dependency_caselist.md`

Generated under L5 reader-facing rules. P1 cases above show new ISQ payload construction; P2 cases below show resident-entry FU-input MUX forwarding.

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

Rows are ordered oldest first, and the oldest instruction always enters at T1. A producer of latency `L` that dispatches at `d` issues at `d`+1, occupies its FU across `d`+1…`d`+`L`, `WB` at **`d`+1+`L`**, `C` at `d`+2+`L`, and ARF-ready at `d`+3+`L`. ARF takes one cycle: a commit at `C` is readable at `C`+1.

## Bypass paths, and where they can be consumed

Each bus carries **only** the value published in that cycle; nothing is held. A dependent whose P1 misses the producer's P3 cycle **cannot go back for it**: the next opportunity is the commit CDB, and after that the ARF.

| Bus (valid only in that cycle) | Consumer stage in that cycle | Use | Issues |
|---|---|---|---|
| `Bypass[g]`, 4 group lanes | P1 | captured into the new ISQ payload (the entry becomes ready) | next cycle |
| `Bypass[g]`, 4 group lanes | P2 (resident) | resident wakeup; feeds the FU input directly | that cycle |
| `Commit CDB`, 2 lanes | P1 | captured into the new ISQ payload | next cycle |
| `Commit CDB`, 2 lanes | P2 | **not connected** | — |
| ARF | P1, after the producer has committed | read from the ARF read ports | next cycle |

That one-cycle window is what the sources in these cases enumerate: the P1 MUX cases place a source in the dependent's P1 cycle, and the P2 MUX cases keep the dependent resident so its P2 falls in that window.

If a resident entry matches a P3 source in P2 but the selected FU cannot issue in that cycle, the matched data is latched at the clock edge and becomes `Stored Ready` for a later cycle — it is not lost.

## Two constraints these figures obey

1. **Same-group dispatch is impossible.** The ISQ holds one entry per group, so two instructions of the same group cannot be dispatched in the same cycle. Where a producer would otherwise have to share its group's dispatch cycle with the dependent, the dependent is routed to the other ALU group and is drawn as `Dependent-G1` / `ALU1`. This is the same routing choice the single-operand `delta_0` rows make.
2. **Same-group P3 lanes.** Two different producers of the same group cannot both publish on that group's P3 bypass lane in one cycle; those K-map cells are the gray `don't exist` cells. Constraints 1 and 2 are distinct: the first is about the dispatch entry in P1, the second about the bypass lane in P3.

## Case 1: INT2_G1P3_G0P3

**Dimension:** INT two-operand ready-source composition · **Equiv:** G1 P3 Bypass + G0 P3 Bypass
**Description:** Dependent captures rs1 from G1 Bypass (MUL) and rs2 from G0 Bypass (DIV) in the same source-ready cycle. DIV \(L=8\) dispatches five cycles before MUL \(L=3\) so both P3 publications land at T11.

| Instruction | T1 | T2 | T3 | T4 | T5 | T6 | T7 | T8 | T9 | T10 | T11 | T12 | T13 | T14 |
|:---|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|
| `div x6, x3, x4` · P3 source·G0 | `[ IB ]`<br>enqueue instruction | `[ dispatch ]`<br>allocate **scoreboard** entry<br>write **ISQ_Group0**<br>rename x6 | `[ DIV ]`<br>divide step 1/8 | `[ DIV ]`<br>divide step 2/8 | `[ DIV ]`<br>divide step 3/8 | `[ DIV ]`<br>divide step 4/8 | `[ DIV ]`<br>divide step 5/8 | `[ DIV ]`<br>divide step 6/8 | `[ DIV ]`<br>divide step 7/8 | `[ DIV ]`<br>divide step 8/8 | `[ WB ]`<br>drive Bypass[0] tag+data<br>**scoreboard** set exec_done<br>**Buffer** write result | `[ C ]`<br>commit<br>**INT_ARF** write x6<br>**INT_tag_mapping** clear busy |  |  |
| `mul x8, x1, x2` · P3 source·G1 |  |  |  |  |  | `[ IB ]`<br>enqueue instruction | `[ dispatch ]`<br>allocate **scoreboard** entry<br>write **ISQ_Group1**<br>rename x8 | `[ MUL ]`<br>execute mul step 1/3 | `[ MUL ]`<br>execute mul step 2/3 | `[ MUL ]`<br>execute mul step 3/3 | `[ WB ]`<br>drive Bypass[1] tag+data<br>**scoreboard** set exec_done<br>**Buffer** write result | `[ C ]`<br>commit<br>**INT_ARF** write x8<br>**INT_tag_mapping** clear busy |  |  |
| `add x20, x8, x6` · Dependent·G0 |  |  |  |  |  |  |  |  |  | `[ IB ]`<br>enqueue instruction | `[ dispatch ]`<br>allocate **scoreboard** entry<br>capture Bypass[0] tag(x6), ready<br>capture Bypass[1] tag(x8), ready<br>write **ISQ_Group0**<br>rename x20 | `[ ALU0 ]`<br>execute add | `[ WB ]`<br>drive Bypass[0] tag+data<br>**scoreboard** set exec_done<br>**Buffer** write result | `[ C ]`<br>commit<br>**INT_ARF** write x20<br>**INT_tag_mapping** clear busy |

- **T11 (Source composition):** dependent P1 resolves rs1 as `G1 P3 Bypass` and rs2 as `G0 P3 Bypass` in one source-resolution cycle.
- **T11 (P3 capture, P3 → P1 bypass):** every P3 source uses exact-tag Bypass capture into the new `dispatch` payload; the dependent issues at T12, not in the capture cycle.

## Case 2: INT2_G3P3_G0P3

**Dimension:** INT two-operand ready-source composition · **Equiv:** G3 Load P3 Bypass + G0 P3 Bypass
**Description:** Dependent captures rs1 from G3 load Bypass and rs2 from G0 Bypass.

| Instruction | T1 | T2 | T3 | T4 | T5 | T6 | T7 | T8 |
|:---|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|
| `ld x7, 0(x8)` · P3 source·G3 | `[ IB ]`<br>enqueue instruction | `[ dispatch ]`<br>allocate **scoreboard** entry<br>write **ISQ_Group3**<br>rename x7 | `[ AGU ]`<br>compute address | `[ L1D ]`<br>access **L1D**, hit | `[ WB ]`<br>drive Bypass[3] tag+data<br>**scoreboard** set exec_done<br>**Buffer** write result | `[ C ]`<br>commit<br>**INT_ARF** write x7<br>**INT_tag_mapping** clear busy |  |  |
| `add x5, x1, x2` · P3 source·G0 |  | `[ IB ]`<br>enqueue instruction | `[ dispatch ]`<br>allocate **scoreboard** entry<br>write **ISQ_Group0**<br>rename x5 | `[ ALU0 ]`<br>execute add | `[ WB ]`<br>drive Bypass[0] tag+data<br>**scoreboard** set exec_done<br>**Buffer** write result | `[ C ]`<br>commit<br>**INT_ARF** write x5<br>**INT_tag_mapping** clear busy |  |  |
| `add x20, x7, x5` · Dependent·G0 |  |  |  | `[ IB ]`<br>enqueue instruction | `[ dispatch ]`<br>allocate **scoreboard** entry<br>capture Bypass[3] tag(x7), ready<br>capture Bypass[0] tag(x5), ready<br>write **ISQ_Group0**<br>rename x20 | `[ ALU0 ]`<br>execute add | `[ WB ]`<br>drive Bypass[0] tag+data<br>**scoreboard** set exec_done<br>**Buffer** write result | `[ C ]`<br>commit<br>**INT_ARF** write x20<br>**INT_tag_mapping** clear busy |

- **T5 (Source composition):** dependent P1 resolves rs1 as `G3 Load P3 Bypass` and rs2 as `G0 P3 Bypass` in one source-resolution cycle.
- **T5 (P3 capture, P3 → P1 bypass):** every P3 source uses exact-tag Bypass capture into the new `dispatch` payload; the dependent issues at T6, not in the capture cycle.

## Case 3: INT2_P4_G0P3

**Dimension:** INT two-operand ready-source composition · **Equiv:** P4 Commit + G0 P3 Bypass
**Description:** P1 source resolution uses Commit CDB for rs1 and G0 Bypass for rs2.

| Instruction | T1 | T2 | T3 | T4 | T5 | T6 | T7 | T8 | T9 |
|:---|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|
| `add x6, x3, x4` · P4 source·G0 | `[ IB ]`<br>enqueue instruction | `[ dispatch ]`<br>allocate **scoreboard** entry<br>write **ISQ_Group0**<br>rename x6 | `[ ALU0 ]`<br>execute add | `[ WB ]`<br>drive Bypass[0] tag+data<br>**scoreboard** set exec_done<br>**Buffer** write result | `[ C ]`<br>commit<br>**INT_ARF** write x6<br>**INT_tag_mapping** clear busy |  |  |  |  |
| `add x5, x1, x2` · P3 source·G0 |  | `[ IB ]`<br>enqueue instruction | `[ dispatch ]`<br>allocate **scoreboard** entry<br>write **ISQ_Group0**<br>rename x5 | `[ ALU0 ]`<br>execute add | `[ WB ]`<br>drive Bypass[0] tag+data<br>**scoreboard** set exec_done<br>**Buffer** write result | `[ C ]`<br>commit<br>**INT_ARF** write x5<br>**INT_tag_mapping** clear busy |  |  |  |
| `add x20, x6, x5` · Dependent·G0 |  |  |  | `[ IB ]`<br>enqueue instruction | `[ dispatch ]`<br>allocate **scoreboard** entry<br>capture Commit CDB tag(x6), ready<br>capture Bypass[0] tag(x5), ready<br>write **ISQ_Group0**<br>rename x20 | `[ ALU0 ]`<br>execute add | `[ WB ]`<br>drive Bypass[0] tag+data<br>**scoreboard** set exec_done<br>**Buffer** write result | `[ C ]`<br>commit<br>**INT_ARF** write x20<br>**INT_tag_mapping** clear busy |  |

- **T5 (Source composition):** dependent P1 resolves rs1 as `P4 Commit` and rs2 as `G0 P3 Bypass` in one source-resolution cycle.
- **T5 (P3 capture, P3 → P1 bypass):** every P3 source uses exact-tag Bypass capture into the new `dispatch` payload; the dependent issues at T6, not in the capture cycle.
- **T5 (P4 capture, P4 → P1 bypass):** every P4 source uses exact-tag Commit CDB capture and suppresses Condition A for that source.

## Case 4: INT2_ARF_G0P3

**Dimension:** INT two-operand ready-source composition · **Equiv:** Already in ARF + G0 P3 Bypass
**Description:** rs1 reads ARF; rs2 captures G0 Bypass.

| Instruction | T1 | T2 | T3 | T4 | T5 | T6 | T7 | T8 | T9 |
|:---|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|
| `add x10, x1, x2` · ARF source·G0 | `[ IB ]`<br>enqueue instruction | `[ dispatch ]`<br>allocate **scoreboard** entry<br>write **ISQ_Group0**<br>rename x10 | `[ ALU0 ]`<br>execute add | `[ WB ]`<br>drive Bypass[0] tag+data<br>**scoreboard** set exec_done<br>**Buffer** write result | `[ C ]`<br>commit<br>**INT_ARF** write x10<br>**INT_tag_mapping** clear busy |  |  |  |  |
| `add x5, x3, x4` · P3 source·G0 |  |  | `[ IB ]`<br>enqueue instruction | `[ dispatch ]`<br>allocate **scoreboard** entry<br>write **ISQ_Group0**<br>rename x5 | `[ ALU0 ]`<br>execute add | `[ WB ]`<br>drive Bypass[0] tag+data<br>**scoreboard** set exec_done<br>**Buffer** write result | `[ C ]`<br>commit<br>**INT_ARF** write x5<br>**INT_tag_mapping** clear busy |  |  |
| `add x20, x10, x5` · Dependent·G0 |  |  |  |  | `[ IB ]`<br>enqueue instruction | `[ dispatch ]`<br>allocate **scoreboard** entry<br>read **INT_ARF** x10<br>capture Bypass[0] tag(x5), ready<br>write **ISQ_Group0**<br>rename x20 | `[ ALU0 ]`<br>execute add | `[ WB ]`<br>drive Bypass[0] tag+data<br>**scoreboard** set exec_done<br>**Buffer** write result | `[ C ]`<br>commit<br>**INT_ARF** write x20<br>**INT_tag_mapping** clear busy |

- **T6 (Source composition):** dependent P1 resolves rs1 as `Already in ARF` and rs2 as `G0 P3 Bypass` in one source-resolution cycle.
- **T6 (P3 capture, P3 → P1 bypass):** every P3 source uses exact-tag Bypass capture into the new `dispatch` payload; the dependent issues at T7, not in the capture cycle.
- **T6 (ARF source, no bypass):** the ARF source has already committed before dependent P1, so `INT_tag_mapping` is not busy for that operand.

## Case 5: INT2_G0P3_IMM

**Dimension:** INT two-operand ready-source composition · **Equiv:** G0 P3 Bypass + IMM
**Description:** rs1 captures G0 Bypass; rs2 is immediate and has no dependency tag.

| Instruction | T1 | T2 | T3 | T4 | T5 | T6 | T7 | T8 | T9 |
|:---|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|
| `add x5, x1, x2` · P3 source·G0 | `[ IB ]`<br>enqueue instruction | `[ dispatch ]`<br>allocate **scoreboard** entry<br>write **ISQ_Group0**<br>rename x5 | `[ ALU0 ]`<br>execute add | `[ WB ]`<br>drive Bypass[0] tag+data<br>**scoreboard** set exec_done<br>**Buffer** write result | `[ C ]`<br>commit<br>**INT_ARF** write x5<br>**INT_tag_mapping** clear busy |  |  |  |  |
| `addi x20, x5, 16` · Dependent·G0 |  |  | `[ IB ]`<br>enqueue instruction | `[ dispatch ]`<br>allocate **scoreboard** entry<br>capture Bypass[0] tag(x5), ready<br>use IMM<br>write **ISQ_Group0**<br>rename x20 | `[ ALU0 ]`<br>execute addi | `[ WB ]`<br>drive Bypass[0] tag+data<br>**scoreboard** set exec_done<br>**Buffer** write result | `[ C ]`<br>commit<br>**INT_ARF** write x20<br>**INT_tag_mapping** clear busy |  |  |

- **T4 (Source composition):** dependent P1 resolves rs1 as `G0 P3 Bypass` and rs2 as `IMM` in one source-resolution cycle.
- **T4 (P3 capture, P3 → P1 bypass):** every P3 source uses exact-tag Bypass capture into the new `dispatch` payload; the dependent issues at T5, not in the capture cycle.
- **T4 (Immediate source):** the immediate operand is ready by construction and has no dependency tag.

## Case 6: INT2_G3P3_G1P3

**Dimension:** INT two-operand ready-source composition · **Equiv:** G3 Load P3 Bypass + G1 P3 Bypass
**Description:** Dependent captures rs1 from G3 load Bypass and rs2 from G1 Bypass.

| Instruction | T1 | T2 | T3 | T4 | T5 | T6 | T7 | T8 | T9 |
|:---|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|
| `mul x6, x3, x4` · P3 source·G1 | `[ IB ]`<br>enqueue instruction | `[ dispatch ]`<br>allocate **scoreboard** entry<br>write **ISQ_Group1**<br>rename x6 | `[ MUL ]`<br>execute mul step 1/3 | `[ MUL ]`<br>execute mul step 2/3 | `[ MUL ]`<br>execute mul step 3/3 | `[ WB ]`<br>drive Bypass[1] tag+data<br>**scoreboard** set exec_done<br>**Buffer** write result | `[ C ]`<br>commit<br>**INT_ARF** write x6<br>**INT_tag_mapping** clear busy |  |  |
| `ld x7, 0(x8)` · P3 source·G3 |  | `[ IB ]`<br>enqueue instruction | `[ dispatch ]`<br>allocate **scoreboard** entry<br>write **ISQ_Group3**<br>rename x7 | `[ AGU ]`<br>compute address | `[ L1D ]`<br>access **L1D**, hit | `[ WB ]`<br>drive Bypass[3] tag+data<br>**scoreboard** set exec_done<br>**Buffer** write result | `[ C ]`<br>commit<br>**INT_ARF** write x7<br>**INT_tag_mapping** clear busy |  |  |
| `add x20, x7, x6` · Dependent·G0 |  |  |  |  | `[ IB ]`<br>enqueue instruction | `[ dispatch ]`<br>allocate **scoreboard** entry<br>capture Bypass[1] tag(x6), ready<br>capture Bypass[3] tag(x7), ready<br>write **ISQ_Group0**<br>rename x20 | `[ ALU0 ]`<br>execute add | `[ WB ]`<br>drive Bypass[0] tag+data<br>**scoreboard** set exec_done<br>**Buffer** write result | `[ C ]`<br>commit<br>**INT_ARF** write x20<br>**INT_tag_mapping** clear busy |

- **T6 (Source composition):** dependent P1 resolves rs1 as `G3 Load P3 Bypass` and rs2 as `G1 P3 Bypass` in one source-resolution cycle.
- **T6 (P3 capture, P3 → P1 bypass):** every P3 source uses exact-tag Bypass capture into the new `dispatch` payload; the dependent issues at T7, not in the capture cycle.

## Case 7: INT2_P4_G1P3

**Dimension:** INT two-operand ready-source composition · **Equiv:** P4 Commit + G1 P3 Bypass
**Description:** P1 source resolution uses Commit CDB for rs1 and G1 Bypass for rs2 in one cycle. The P3
source is an ALU in G1, not a MUL: for a same-cycle Commit plus P3 capture the younger source must not be
slower than the committing one, and G1's ALU is what makes that hold.

| Instruction | T1 | T2 | T3 | T4 | T5 | T6 | T7 | T8 | T9 |
|:---|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|
| `add x6, x3, x4` · P4 source·G0 | `[ IB ]`<br>enqueue instruction | `[ dispatch ]`<br>allocate **scoreboard** entry<br>write **ISQ_Group0**<br>rename x6 | `[ ALU0 ]`<br>execute add | `[ WB ]`<br>drive Bypass[0] tag+data<br>**scoreboard** set exec_done<br>**Buffer** write result | `[ C ]`<br>commit<br>**INT_ARF** write x6<br>**INT_tag_mapping** clear busy |  |  |  |  |
| `add x5, x1, x2` · P3 source·G1 |  | `[ IB ]`<br>enqueue instruction | `[ dispatch ]`<br>allocate **scoreboard** entry<br>write **ISQ_Group1**<br>rename x5 | `[ ALU1 ]`<br>execute add | `[ WB ]`<br>drive Bypass[1] tag+data<br>**scoreboard** set exec_done<br>**Buffer** write result | `[ C ]`<br>commit<br>**INT_ARF** write x5<br>**INT_tag_mapping** clear busy |  |  |  |
| `add x20, x6, x5` · Dependent·G0 |  |  |  | `[ IB ]`<br>enqueue instruction | `[ dispatch ]`<br>allocate **scoreboard** entry<br>capture Commit CDB tag(x6), ready<br>capture Bypass[1] tag(x5), ready<br>write **ISQ_Group0**<br>rename x20 | `[ ALU0 ]`<br>execute add | `[ WB ]`<br>drive Bypass[0] tag+data<br>**scoreboard** set exec_done<br>**Buffer** write result | `[ C ]`<br>commit<br>**INT_ARF** write x20<br>**INT_tag_mapping** clear busy |  |
- **T1 (P4 source, the older source):** it must be the older of the two. Only then can it commit on
  schedule, and only then can the younger source's writeback be made to land on that commit.
- **T5 (Source composition):** dependent P1 resolves rs1 as `P4 Commit` and rs2 as `G1 P3 Bypass` in one
  source-resolution cycle.
- **T5 (P3 capture, P3 → P1 bypass):** the G1 source uses exact-tag Bypass capture into the new `dispatch`
  payload; the dependent issues at T6, not in the capture cycle.
- **T5 (P4 capture, P4 → P1 bypass):** the P4 source uses exact-tag Commit CDB capture and suppresses
  Condition A for that source.
- **Why not a MUL:** with a MUL in G1 the younger source writes back later than the older one can be
  delayed, so the two events never coincide; measurement shows the commit arriving exactly one cycle after
  the MUL's bypass. The cell this case covers is the *source shape* (G1 P3 Bypass), not the FU, so an ALU
  in G1 covers it while making the composition realizable.
## Case 8: INT2_ARF_G1P3

**Dimension:** INT two-operand ready-source composition · **Equiv:** Already in ARF + G1 P3 Bypass
**Description:** rs1 reads ARF; rs2 captures G1 Bypass.

| Instruction | T1 | T2 | T3 | T4 | T5 | T6 | T7 | T8 | T9 |
|:---|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|
| `add x10, x1, x2` · ARF source·G0 | `[ IB ]`<br>enqueue instruction | `[ dispatch ]`<br>allocate **scoreboard** entry<br>write **ISQ_Group0**<br>rename x10 | `[ ALU0 ]`<br>execute add | `[ WB ]`<br>drive Bypass[0] tag+data<br>**scoreboard** set exec_done<br>**Buffer** write result | `[ C ]`<br>commit<br>**INT_ARF** write x10<br>**INT_tag_mapping** clear busy |  |  |  |  |
| `mul x6, x3, x4` · P3 source·G1 | `[ IB ]`<br>enqueue instruction | `[ dispatch ]`<br>allocate **scoreboard** entry<br>write **ISQ_Group1**<br>rename x6 | `[ MUL ]`<br>execute mul step 1/3 | `[ MUL ]`<br>execute mul step 2/3 | `[ MUL ]`<br>execute mul step 3/3 | `[ WB ]`<br>drive Bypass[1] tag+data<br>**scoreboard** set exec_done<br>**Buffer** write result | `[ C ]`<br>commit<br>**INT_ARF** write x6<br>**INT_tag_mapping** clear busy |  |  |
| `add x20, x10, x6` · Dependent·G0 |  |  |  |  | `[ IB ]`<br>enqueue instruction | `[ dispatch ]`<br>allocate **scoreboard** entry<br>read **INT_ARF** x10<br>capture Bypass[1] tag(x6), ready<br>write **ISQ_Group0**<br>rename x20 | `[ ALU0 ]`<br>execute add | `[ WB ]`<br>drive Bypass[0] tag+data<br>**scoreboard** set exec_done<br>**Buffer** write result | `[ C ]`<br>commit<br>**INT_ARF** write x20<br>**INT_tag_mapping** clear busy |

- **T6 (Source composition):** dependent P1 resolves rs1 as `Already in ARF` and rs2 as `G1 P3 Bypass` in one source-resolution cycle.
- **T6 (P3 capture, P3 → P1 bypass):** every P3 source uses exact-tag Bypass capture into the new `dispatch` payload; the dependent issues at T7, not in the capture cycle.
- **T6 (ARF source, no bypass):** the ARF source has already committed before dependent P1, so `INT_tag_mapping` is not busy for that operand.

## Case 9: INT2_G1P3_IMM

**Dimension:** INT two-operand ready-source composition · **Equiv:** G1 P3 Bypass + IMM
**Description:** rs1 captures G1 Bypass; rs2 is immediate and has no dependency tag.

| Instruction | T1 | T2 | T3 | T4 | T5 | T6 | T7 | T8 | T9 |
|:---|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|
| `mul x6, x3, x4` · P3 source·G1 | `[ IB ]`<br>enqueue instruction | `[ dispatch ]`<br>allocate **scoreboard** entry<br>write **ISQ_Group1**<br>rename x6 | `[ MUL ]`<br>execute mul step 1/3 | `[ MUL ]`<br>execute mul step 2/3 | `[ MUL ]`<br>execute mul step 3/3 | `[ WB ]`<br>drive Bypass[1] tag+data<br>**scoreboard** set exec_done<br>**Buffer** write result | `[ C ]`<br>commit<br>**INT_ARF** write x6<br>**INT_tag_mapping** clear busy |  |  |
| `addi x20, x6, 16` · Dependent·G0 |  |  |  |  | `[ IB ]`<br>enqueue instruction | `[ dispatch ]`<br>allocate **scoreboard** entry<br>capture Bypass[1] tag(x6), ready<br>use IMM<br>write **ISQ_Group0**<br>rename x20 | `[ ALU0 ]`<br>execute addi | `[ WB ]`<br>drive Bypass[0] tag+data<br>**scoreboard** set exec_done<br>**Buffer** write result | `[ C ]`<br>commit<br>**INT_ARF** write x20<br>**INT_tag_mapping** clear busy |

- **T6 (Source composition):** dependent P1 resolves rs1 as `G1 P3 Bypass` and rs2 as `IMM` in one source-resolution cycle.
- **T6 (P3 capture, P3 → P1 bypass):** every P3 source uses exact-tag Bypass capture into the new `dispatch` payload; the dependent issues at T7, not in the capture cycle.
- **T6 (Immediate source):** the immediate operand is ready by construction and has no dependency tag.

## Case 10: INT2_P4_G3P3_blocked

**Dimension:** INT two-operand ready-source composition, commit held · **Equiv:** P4 Commit + G3 Load P3 Bypass
**Description:** The older `div` (L=8) holds the commit, so the `add` cannot retire on schedule; it retires
in the same cycle the younger `ld` writes back, and the dependent captures the Commit CDB and the G3 bypass
together. Keeping the LOAD is only possible in this held form: with an unheld commit the two events can never
meet. The LOAD is injected late enough that its P3 lands on the held commit (T12).

| Instruction | T1 | T2 | T3 | T4 | T5 | T6 | T7 | T8 | T9 | T10 | T11 | T12 | T13 | T14 | T15 |
|:---|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|
| `div x11, x12, x5` · Blocker·G0 | `[ IB ]`<br>enqueue instruction | `[ dispatch ]`<br>allocate **scoreboard** entry<br>write **ISQ_Group0**<br>rename x11 | `[ DIV ]`<br>divide step 1/8 | `[ DIV ]`<br>divide step 2/8 | `[ DIV ]`<br>divide step 3/8 | `[ DIV ]`<br>divide step 4/8 | `[ DIV ]`<br>divide step 5/8 | `[ DIV ]`<br>divide step 6/8 | `[ DIV ]`<br>divide step 7/8 | `[ DIV ]`<br>divide step 8/8 | `[ WB ]`<br>drive Bypass[0] tag+data<br>**scoreboard** set exec_done<br>**Buffer** write result | `[ C ]`<br>commit<br>**INT_ARF** write x11<br>**INT_tag_mapping** clear busy |  |  |  |
| `add x7, x8, x9` · P4 source·G0 |  | `[ IB ]`<br>enqueue instruction | `[ dispatch ]`<br>allocate **scoreboard** entry<br>write **ISQ_Group0**<br>rename x7 | `[ ALU0 ]`<br>execute add | `[ WB ]`<br>drive Bypass[0] tag+data<br>**scoreboard** set exec_done<br>**Buffer** write result | `[ Buffer ]`<br>hold<br>wait for commit | `[ Buffer ]`<br>hold<br>wait for commit | `[ Buffer ]`<br>hold<br>wait for commit | `[ Buffer ]`<br>hold<br>wait for commit | `[ Buffer ]`<br>hold<br>wait for commit | `[ Buffer ]`<br>hold<br>wait for commit | `[ C ]`<br>commit<br>**INT_ARF** write x7<br>**INT_tag_mapping** clear busy |  |  |  |
| `ld x6, 0(x10)` · P3 source·G3 |  |  |  |  |  |  |  | `[ IB ]`<br>enqueue instruction | `[ dispatch ]`<br>allocate **scoreboard** entry<br>write **ISQ_Group3**<br>rename x6 | `[ AGU ]`<br>compute address | `[ L1D ]`<br>access **L1D**, hit | `[ WB ]`<br>drive Bypass[3] tag+data<br>**scoreboard** set exec_done<br>**Buffer** write result | `[ C ]`<br>commit<br>**INT_ARF** write x6<br>**INT_tag_mapping** clear busy |  |  |
| `add x20, x7, x6` · Dependent·G0 |  |  |  |  |  |  |  |  |  |  | `[ IB ]`<br>enqueue instruction | `[ dispatch ]`<br>allocate **scoreboard** entry<br>capture Commit CDB tag(x7), ready<br>capture Bypass[3] tag(x6), ready<br>write **ISQ_Group0**<br>rename x20 | `[ ALU0 ]`<br>execute add | `[ WB ]`<br>drive Bypass[0] tag+data<br>**scoreboard** set exec_done<br>**Buffer** write result | `[ C ]`<br>commit<br>**INT_ARF** write x20<br>**INT_tag_mapping** clear busy |
- **Acceptance (mechanism-based — delta is an output here, not an input):**
  1. `Blocker.P4 − P3 > 1` on the *P4 source* is the point: its commit is held until the blocker retires.
  2. `P4 source.P4 == P3 source.P3 == dependent.P1`: the held commit and the P3 writeback land in the same
     cycle, which is the only way this composition can occur — an older P3 source can never coincide with a
     commit, because in-order retirement forces the commit past the older source's own writeback.
  3. `P4 source.P3 − P2 == L` and `P3 source.P3 − P2 == L`: neither writeback was disturbed.
  4. `dependent.P2 − P1 == 1`: the dependent had both operands in its dispatch cycle.
  5. The dependent could not have been dispatched earlier: while its source is completed but uncommitted the
     writeback bypass is already gone and there is no commit-to-issue path, so a consumer parked on it would
     never wake. `p1/dependency_check.sv` raises `slot_missed_wakeup` and `p1/dispatch_logic.sv` (lines 394
     and 417) keeps it out of an ISQ; it dispatches once the value can come from the Commit CDB, which is why
     its P1 lands on the commit cycle rather than wherever it was injected.
## Case 11: INT2_ARF_G3P3

**Dimension:** INT two-operand ready-source composition · **Equiv:** Already in ARF + G3 Load P3 Bypass
**Description:** rs1 reads ARF; rs2 captures G3 load Bypass.

| Instruction | T1 | T2 | T3 | T4 | T5 | T6 | T7 | T8 | T9 |
|:---|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|
| `add x11, x1, x2` · ARF source·G0 | `[ IB ]`<br>enqueue instruction | `[ dispatch ]`<br>allocate **scoreboard** entry<br>write **ISQ_Group0**<br>rename x11 | `[ ALU0 ]`<br>execute add | `[ WB ]`<br>drive Bypass[0] tag+data<br>**scoreboard** set exec_done<br>**Buffer** write result | `[ C ]`<br>commit<br>**INT_ARF** write x11<br>**INT_tag_mapping** clear busy |  |  |  |  |
| `ld x6, 0(x10)` · P3 source·G3 |  | `[ IB ]`<br>enqueue instruction | `[ dispatch ]`<br>allocate **scoreboard** entry<br>write **ISQ_Group3**<br>rename x6 | `[ AGU ]`<br>compute address | `[ L1D ]`<br>access **L1D**, hit | `[ WB ]`<br>drive Bypass[3] tag+data<br>**scoreboard** set exec_done<br>**Buffer** write result | `[ C ]`<br>commit<br>**INT_ARF** write x6<br>**INT_tag_mapping** clear busy |  |  |
| `add x20, x11, x6` · Dependent·G0 |  |  |  |  | `[ IB ]`<br>enqueue instruction | `[ dispatch ]`<br>allocate **scoreboard** entry<br>read **INT_ARF** x11<br>capture Bypass[3] tag(x6), ready<br>write **ISQ_Group0**<br>rename x20 | `[ ALU0 ]`<br>execute add | `[ WB ]`<br>drive Bypass[0] tag+data<br>**scoreboard** set exec_done<br>**Buffer** write result | `[ C ]`<br>commit<br>**INT_ARF** write x20<br>**INT_tag_mapping** clear busy |

- **T6 (Source composition):** dependent P1 resolves rs1 as `Already in ARF` and rs2 as `G3 Load P3 Bypass` in one source-resolution cycle.
- **T6 (P3 capture, P3 → P1 bypass):** every P3 source uses exact-tag Bypass capture into the new `dispatch` payload; the dependent issues at T7, not in the capture cycle.
- **T6 (ARF source, no bypass):** the ARF source committed at T5, so it is readable from ARF at T6; `INT_tag_mapping` is not busy for that operand.

## Case 12: INT2_G3P3_IMM

**Dimension:** INT two-operand ready-source composition · **Equiv:** G3 Load P3 Bypass + IMM
**Description:** rs1 captures G3 load Bypass; rs2 is immediate and has no dependency tag.

| Instruction | T1 | T2 | T3 | T4 | T5 | T6 | T7 | T8 |
|:---|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|
| `ld x6, 0(x10)` · P3 source·G3 | `[ IB ]`<br>enqueue instruction | `[ dispatch ]`<br>allocate **scoreboard** entry<br>write **ISQ_Group3**<br>rename x6 | `[ AGU ]`<br>compute address | `[ L1D ]`<br>access **L1D**, hit | `[ WB ]`<br>drive Bypass[3] tag+data<br>**scoreboard** set exec_done<br>**Buffer** write result | `[ C ]`<br>commit<br>**INT_ARF** write x6<br>**INT_tag_mapping** clear busy |  |  |
| `addi x20, x6, 16` · Dependent·G0 |  |  |  | `[ IB ]`<br>enqueue instruction | `[ dispatch ]`<br>allocate **scoreboard** entry<br>capture Bypass[3] tag(x6), ready<br>use IMM<br>write **ISQ_Group0**<br>rename x20 | `[ ALU0 ]`<br>execute addi | `[ WB ]`<br>drive Bypass[0] tag+data<br>**scoreboard** set exec_done<br>**Buffer** write result | `[ C ]`<br>commit<br>**INT_ARF** write x20<br>**INT_tag_mapping** clear busy |

- **T5 (Source composition):** dependent P1 resolves rs1 as `G3 Load P3 Bypass` and rs2 as `IMM` in one source-resolution cycle.
- **T5 (P3 capture, P3 → P1 bypass):** every P3 source uses exact-tag Bypass capture into the new `dispatch` payload; the dependent issues at T6, not in the capture cycle.
- **T5 (Immediate source):** the immediate operand is ready by construction and has no dependency tag.

## Case 13: INT2_P4_P4

**Dimension:** INT two-operand ready-source composition · **Equiv:** P4 Commit + P4 Commit
**Description:** P1 source resolution captures both operands from the two Commit CDB lanes.

| Instruction | T1 | T2 | T3 | T4 | T5 | T6 | T7 | T8 | T9 |
|:---|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|
| `add x5, x1, x2` · P4 source·G0 | `[ IB ]`<br>enqueue instruction | `[ dispatch ]`<br>allocate **scoreboard** entry<br>write **ISQ_Group0**<br>rename x5 | `[ ALU0 ]`<br>execute add | `[ WB ]`<br>drive Bypass[0] tag+data<br>**scoreboard** set exec_done<br>**Buffer** write result | `[ C ]`<br>commit<br>**INT_ARF** write x5<br>**INT_tag_mapping** clear busy |  |  |  |  |
| `add x6, x3, x4` · P4 source·G1 | `[ IB ]`<br>enqueue instruction | `[ dispatch ]`<br>allocate **scoreboard** entry<br>write **ISQ_Group1**<br>rename x6 | `[ ALU1 ]`<br>execute add | `[ WB ]`<br>drive Bypass[1] tag+data<br>**scoreboard** set exec_done<br>**Buffer** write result | `[ C ]`<br>commit<br>**INT_ARF** write x6<br>**INT_tag_mapping** clear busy |  |  |  |  |
| `add x20, x5, x6` · Dependent·G0 |  |  |  | `[ IB ]`<br>enqueue instruction | `[ dispatch ]`<br>allocate **scoreboard** entry<br>capture Commit CDB tag(x5), ready<br>capture Commit CDB tag(x6), ready<br>write **ISQ_Group0**<br>rename x20 | `[ ALU0 ]`<br>execute add | `[ WB ]`<br>drive Bypass[0] tag+data<br>**scoreboard** set exec_done<br>**Buffer** write result | `[ C ]`<br>commit<br>**INT_ARF** write x20<br>**INT_tag_mapping** clear busy |  |

- **T5 (Source composition):** dependent P1 resolves rs1 as `P4 Commit` and rs2 as `P4 Commit` in one source-resolution cycle.
- **T5 (P4 capture, P4 → P1 bypass):** every P4 source uses exact-tag Commit CDB capture and suppresses Condition A for that source.

## Case 14: INT2_ARF_P4

**Dimension:** INT two-operand ready-source composition · **Equiv:** Already in ARF + P4 Commit
**Description:** rs1 reads ARF; rs2 captures Commit CDB.

| Instruction | T1 | T2 | T3 | T4 | T5 | T6 | T7 | T8 | T9 |
|:---|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|
| `add x10, x1, x2` · ARF source·G0 | `[ IB ]`<br>enqueue instruction | `[ dispatch ]`<br>allocate **scoreboard** entry<br>write **ISQ_Group0**<br>rename x10 | `[ ALU0 ]`<br>execute add | `[ WB ]`<br>drive Bypass[0] tag+data<br>**scoreboard** set exec_done<br>**Buffer** write result | `[ C ]`<br>commit<br>**INT_ARF** write x10<br>**INT_tag_mapping** clear busy |  |  |  |  |
| `add x6, x3, x4` · P4 source·G0 |  | `[ IB ]`<br>enqueue instruction | `[ dispatch ]`<br>allocate **scoreboard** entry<br>write **ISQ_Group0**<br>rename x6 | `[ ALU0 ]`<br>execute add | `[ WB ]`<br>drive Bypass[0] tag+data<br>**scoreboard** set exec_done<br>**Buffer** write result | `[ C ]`<br>commit<br>**INT_ARF** write x6<br>**INT_tag_mapping** clear busy |  |  |  |
| `add x20, x10, x6` · Dependent·G0 |  |  |  |  | `[ IB ]`<br>enqueue instruction | `[ dispatch ]`<br>allocate **scoreboard** entry<br>read **INT_ARF** x10<br>capture Commit CDB tag(x6), ready<br>write **ISQ_Group0**<br>rename x20 | `[ ALU0 ]`<br>execute add | `[ WB ]`<br>drive Bypass[0] tag+data<br>**scoreboard** set exec_done<br>**Buffer** write result | `[ C ]`<br>commit<br>**INT_ARF** write x20<br>**INT_tag_mapping** clear busy |

- **T6 (Source composition):** dependent P1 resolves rs1 as `Already in ARF` and rs2 as `P4 Commit` in one source-resolution cycle.
- **T6 (P4 capture, P4 → P1 bypass):** every P4 source uses exact-tag Commit CDB capture and suppresses Condition A for that source.
- **T6 (ARF source, no bypass):** the ARF source has already committed before dependent P1, so `INT_tag_mapping` is not busy for that operand.

## Case 15: INT2_P4_IMM

**Dimension:** INT two-operand ready-source composition · **Equiv:** P4 Commit + IMM
**Description:** rs1 captures Commit CDB; rs2 is immediate and has no dependency tag.

| Instruction | T1 | T2 | T3 | T4 | T5 | T6 | T7 | T8 | T9 |
|:---|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|
| `add x5, x1, x2` · P4 source·G0 | `[ IB ]`<br>enqueue instruction | `[ dispatch ]`<br>allocate **scoreboard** entry<br>write **ISQ_Group0**<br>rename x5 | `[ ALU0 ]`<br>execute add | `[ WB ]`<br>drive Bypass[0] tag+data<br>**scoreboard** set exec_done<br>**Buffer** write result | `[ C ]`<br>commit<br>**INT_ARF** write x5<br>**INT_tag_mapping** clear busy |  |  |  |  |
| `addi x20, x5, 16` · Dependent·G0 |  |  |  | `[ IB ]`<br>enqueue instruction | `[ dispatch ]`<br>allocate **scoreboard** entry<br>capture Commit CDB tag(x5), ready<br>use IMM<br>write **ISQ_Group0**<br>rename x20 | `[ ALU0 ]`<br>execute addi | `[ WB ]`<br>drive Bypass[0] tag+data<br>**scoreboard** set exec_done<br>**Buffer** write result | `[ C ]`<br>commit<br>**INT_ARF** write x20<br>**INT_tag_mapping** clear busy |  |

- **T5 (Source composition):** dependent P1 resolves rs1 as `P4 Commit` and rs2 as `IMM` in one source-resolution cycle.
- **T5 (P4 capture, P4 → P1 bypass):** every P4 source uses exact-tag Commit CDB capture and suppresses Condition A for that source.
- **T5 (Immediate source):** the immediate operand is ready by construction and has no dependency tag.

## Case 16: INT2_ARF_ARF

**Dimension:** INT two-operand ready-source composition · **Equiv:** Already in ARF + Already in ARF
**Description:** Both operands read ARF at P1; no bypass or commit overlay is needed.

| Instruction | T1 | T2 | T3 | T4 | T5 | T6 | T7 | T8 | T9 |
|:---|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|
| `add x10, x1, x2` · ARF source·G0 | `[ IB ]`<br>enqueue instruction | `[ dispatch ]`<br>allocate **scoreboard** entry<br>write **ISQ_Group0**<br>rename x10 | `[ ALU0 ]`<br>execute add | `[ WB ]`<br>drive Bypass[0] tag+data<br>**scoreboard** set exec_done<br>**Buffer** write result | `[ C ]`<br>commit<br>**INT_ARF** write x10<br>**INT_tag_mapping** clear busy |  |  |  |  |
| `add x11, x3, x4` · ARF source·G1 | `[ IB ]`<br>enqueue instruction | `[ dispatch ]`<br>allocate **scoreboard** entry<br>write **ISQ_Group1**<br>rename x11 | `[ ALU1 ]`<br>execute add | `[ WB ]`<br>drive Bypass[1] tag+data<br>**scoreboard** set exec_done<br>**Buffer** write result | `[ C ]`<br>commit<br>**INT_ARF** write x11<br>**INT_tag_mapping** clear busy |  |  |  |  |
| `add x20, x10, x11` · Dependent·G0 |  |  |  |  | `[ IB ]`<br>enqueue instruction | `[ dispatch ]`<br>allocate **scoreboard** entry<br>read **INT_ARF** x10<br>read **INT_ARF** x11<br>write **ISQ_Group0**<br>rename x20 | `[ ALU0 ]`<br>execute add | `[ WB ]`<br>drive Bypass[0] tag+data<br>**scoreboard** set exec_done<br>**Buffer** write result | `[ C ]`<br>commit<br>**INT_ARF** write x20<br>**INT_tag_mapping** clear busy |

- **T6 (Source composition):** dependent P1 resolves rs1 as `Already in ARF` and rs2 as `Already in ARF` in one source-resolution cycle.
- **T6 (ARF source, no bypass):** the ARF source has already committed before dependent P1, so `INT_tag_mapping` is not busy for that operand.

## Case 17: INT2_ARF_IMM

**Dimension:** INT two-operand ready-source composition · **Equiv:** Already in ARF + IMM
**Description:** rs1 reads ARF; rs2 is immediate and has no dependency tag.

| Instruction | T1 | T2 | T3 | T4 | T5 | T6 | T7 | T8 | T9 |
|:---|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|
| `add x10, x1, x2` · ARF source·G0 | `[ IB ]`<br>enqueue instruction | `[ dispatch ]`<br>allocate **scoreboard** entry<br>write **ISQ_Group0**<br>rename x10 | `[ ALU0 ]`<br>execute add | `[ WB ]`<br>drive Bypass[0] tag+data<br>**scoreboard** set exec_done<br>**Buffer** write result | `[ C ]`<br>commit<br>**INT_ARF** write x10<br>**INT_tag_mapping** clear busy |  |  |  |  |
| `addi x20, x10, 16` · Dependent·G0 |  |  |  |  | `[ IB ]`<br>enqueue instruction | `[ dispatch ]`<br>allocate **scoreboard** entry<br>read **INT_ARF** x10<br>use IMM<br>write **ISQ_Group0**<br>rename x20 | `[ ALU0 ]`<br>execute addi | `[ WB ]`<br>drive Bypass[0] tag+data<br>**scoreboard** set exec_done<br>**Buffer** write result | `[ C ]`<br>commit<br>**INT_ARF** write x20<br>**INT_tag_mapping** clear busy |

- **T6 (Source composition):** dependent P1 resolves rs1 as `Already in ARF` and rs2 as `IMM` in one source-resolution cycle.
- **T6 (ARF source, no bypass):** the ARF source has already committed before dependent P1, so `INT_tag_mapping` is not busy for that operand.
- **T6 (Immediate source):** the immediate operand is ready by construction and has no dependency tag.

## P2 MUX Resident-Entry Cases

These cases complement the P1 MUX figures above. The dependent instruction is already resident in ISQ; the case's P2 FU-input MUX cycle is where current P3 forwarding and/or stored `entry.rs_data` make the operands usable. `P4 Commit CDB` is not a P2 MUX source. Immediate operands are already carried in the resident payload and are covered by `Stored Ready at dispatch`.

## Case 18: INT2_P2_G1P3_G0P3

**Dimension:** INT two-operand ready-source composition | **Equiv:** P2 MUX: G1 P3 Bypass + G0 P3 Bypass
**Description:** P2 FU-input mux selects rs1 from G1 Bypass and rs2 from G0 Bypass; the resident entry can issue in that cycle if the selected FU is free.

| Instruction | T1 | T2 | T3 | T4 | T5 | T6 | T7 | T8 | T9 | T10 |
|:---|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|
| `mul x6, x3, x4` - G1 P3 Bypass | `[ IB ]`<br>enqueue instruction | `[ dispatch ]`<br>allocate **scoreboard** entry<br>write **ISQ_Group1**<br>rename x6 | `[ MUL ]`<br>execute mul step 1/3 | `[ MUL ]`<br>execute mul step 2/3 | `[ MUL ]`<br>execute mul step 3/3 | `[ WB ]`<br>drive Bypass[1] tag+data<br>**scoreboard** set exec_done<br>**Buffer** write result | `[ C ]`<br>commit<br>**INT_ARF** write x6<br>**INT_tag_mapping** clear busy |  |  |  |
| `add x5, x1, x2` - G0 P3 Bypass |  |  | `[ IB ]`<br>enqueue instruction | `[ dispatch ]`<br>allocate **scoreboard** entry<br>write **ISQ_Group0**<br>rename x5 | `[ ALU0 ]`<br>execute add | `[ WB ]`<br>drive Bypass[0] tag+data<br>**scoreboard** set exec_done<br>**Buffer** write result | `[ C ]`<br>commit<br>**INT_ARF** write x5<br>**INT_tag_mapping** clear busy |  |  |  |
| `add x20, x6, x5` - Dependent-G1 |  |  | `[ IB ]`<br>enqueue instruction | `[ dispatch ]`<br>allocate **scoreboard** entry<br>write **ISQ_Group1**<br>overlay tag(x5)<br>rename x20 | `[ ISQ_Group1 ]`<br>wait for Bypass[1] tag(x6)<br>wait for Bypass[0] tag(x5) | `[ ALU1 ]`<br>**ISQ_Group1** capture Bypass[1] tag(x6)<br>**ISQ_Group1** capture Bypass[0] tag(x5)<br>execute add | `[ WB ]`<br>drive Bypass[1] tag+data<br>**scoreboard** set exec_done<br>**Buffer** write result | `[ C ]`<br>commit<br>**INT_ARF** write x20<br>**INT_tag_mapping** clear busy |  |  |

- **T4 (Resident entry):** the dependent has already dispatched into its group-local ISQ and carries stored ready data and/or `wait_tag`s.
- **T6 (P2 MUX source-ready):** current P3 forwarding sources use exact-tag resident-entry matching; stored sources come from already valid `entry.rs_data`.
- **T6 (Issue rule):** if the selected FU is free, the resident entry issues through the P2 FU-input MUX in this cycle; otherwise matched forwarding data is latched and becomes `Stored Ready` for retry.

## Case 19: INT2_P2_G3P3_G0P3

**Dimension:** INT two-operand ready-source composition | **Equiv:** P2 MUX: G3 Load P3 Bypass + G0 P3 Bypass
**Description:** P2 mux selects rs1 from G3 load Bypass and rs2 from G0 Bypass.

| Instruction | T1 | T2 | T3 | T4 | T5 | T6 | T7 |
|:---|:---:|:---:|:---:|:---:|:---:|:---:|:---:|
| `ld x7, 0(x8)` - G3 Load P3 Bypass | `[ IB ]`<br>enqueue instruction | `[ dispatch ]`<br>allocate **scoreboard** entry<br>write **ISQ_Group3**<br>rename x7 | `[ AGU ]`<br>compute address | `[ L1D ]`<br>access **L1D**, hit | `[ WB ]`<br>drive Bypass[3] tag+data<br>**scoreboard** set exec_done<br>**Buffer** write result | `[ C ]`<br>commit<br>**INT_ARF** write x7<br>**INT_tag_mapping** clear busy |  |
| `add x5, x1, x2` - G0 P3 Bypass |  | `[ IB ]`<br>enqueue instruction | `[ dispatch ]`<br>allocate **scoreboard** entry<br>write **ISQ_Group0**<br>rename x5 | `[ ALU0 ]`<br>execute add | `[ WB ]`<br>drive Bypass[0] tag+data<br>**scoreboard** set exec_done<br>**Buffer** write result | `[ C ]`<br>commit<br>**INT_ARF** write x5<br>**INT_tag_mapping** clear busy |  |
| `add x20, x7, x5` - Dependent-G1 | `[ IB ]`<br>enqueue instruction | `[ dispatch ]`<br>allocate **scoreboard** entry<br>write **ISQ_Group1**<br>overlay tag(x7)<br>rename x20 | `[ ISQ_Group1 ]`<br>wait for Bypass[3] tag(x7)<br>wait for Bypass[0] tag(x5) | `[ ISQ_Group1 ]`<br>wait for Bypass[3] tag(x7)<br>wait for Bypass[0] tag(x5) | `[ ALU1 ]`<br>**ISQ_Group1** capture Bypass[3] tag(x7)<br>**ISQ_Group1** capture Bypass[0] tag(x5)<br>execute add | `[ WB ]`<br>drive Bypass[1] tag+data<br>**scoreboard** set exec_done<br>**Buffer** write result | `[ C ]`<br>commit<br>**INT_ARF** write x20<br>**INT_tag_mapping** clear busy |

- **T2 (Resident entry):** the dependent has already dispatched into its group-local ISQ and carries stored ready data and/or `wait_tag`s.
- **T5 (P2 MUX source-ready):** current P3 forwarding sources use exact-tag resident-entry matching; stored sources come from already valid `entry.rs_data`.
- **T5 (Issue rule):** if the selected FU is free, the resident entry issues through the P2 FU-input MUX in this cycle; otherwise matched forwarding data is latched and becomes `Stored Ready` for retry.

## Case 20: INT2_P2_ISQ_STORED_G0P3

**Dimension:** INT two-operand ready-source composition | **Equiv:** P2 MUX: Stored Ready at dispatch + G0 P3 Bypass
**Description:** P2 mux uses stored `entry.rs1_data` and current G0 Bypass data.

| Instruction | T1 | T2 | T3 | T4 | T5 | T6 | T7 | T8 | T9 | T10 |
|:---|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|
| `add x10, x1, x2` - Stored Ready at dispatch | `[ IB ]`<br>enqueue instruction | `[ dispatch ]`<br>allocate **scoreboard** entry<br>write **ISQ_Group0**<br>rename x10 | `[ ALU0 ]`<br>execute add | `[ WB ]`<br>drive Bypass[0] tag+data<br>**scoreboard** set exec_done<br>**Buffer** write result | `[ C ]`<br>commit<br>**INT_ARF** write x10<br>**INT_tag_mapping** clear busy |  |  |  |  |  |
| `add x5, x3, x4` - G0 P3 Bypass |  |  |  |  | `[ IB ]`<br>enqueue instruction | `[ dispatch ]`<br>allocate **scoreboard** entry<br>write **ISQ_Group0**<br>rename x5 | `[ ALU0 ]`<br>execute add | `[ WB ]`<br>drive Bypass[0] tag+data<br>**scoreboard** set exec_done<br>**Buffer** write result | `[ C ]`<br>commit<br>**INT_ARF** write x5<br>**INT_tag_mapping** clear busy |  |
| `add x20, x10, x5` - Dependent-G1 |  |  |  |  | `[ IB ]`<br>enqueue instruction | `[ dispatch ]`<br>allocate **scoreboard** entry<br>use stored operand x10<br>write **ISQ_Group1**<br>overlay tag(x5)<br>rename x20 | `[ ISQ_Group1 ]`<br>wait for Bypass[0] tag(x5) | `[ ALU1 ]`<br>**ISQ_Group1** capture Bypass[0] tag(x5)<br>execute add | `[ WB ]`<br>drive Bypass[1] tag+data<br>**scoreboard** set exec_done<br>**Buffer** write result | `[ C ]`<br>commit<br>**INT_ARF** write x20<br>**INT_tag_mapping** clear busy |

- **T6 (Resident entry):** the dependent has already dispatched into its group-local ISQ and carries stored ready data and/or `wait_tag`s.
- **T8 (P2 MUX source-ready):** current P3 forwarding sources use exact-tag resident-entry matching; stored sources come from already valid `entry.rs_data`.
- **T8 (Issue rule):** if the selected FU is free, the resident entry issues through the P2 FU-input MUX in this cycle; otherwise matched forwarding data is latched and becomes `Stored Ready` for retry.

## Case 21: INT2_P2_G3P3_G1P3

**Dimension:** INT two-operand ready-source composition | **Equiv:** P2 MUX: G3 Load P3 Bypass + G1 P3 Bypass
**Description:** P2 mux selects rs1 from G3 load Bypass and rs2 from G1 Bypass.

| Instruction | T1 | T2 | T3 | T4 | T5 | T6 | T7 | T8 |
|:---|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|
| `mul x6, x3, x4` - G1 P3 Bypass | `[ IB ]`<br>enqueue instruction | `[ dispatch ]`<br>allocate **scoreboard** entry<br>write **ISQ_Group1**<br>rename x6 | `[ MUL ]`<br>execute mul step 1/3 | `[ MUL ]`<br>execute mul step 2/3 | `[ MUL ]`<br>execute mul step 3/3 | `[ WB ]`<br>drive Bypass[1] tag+data<br>**scoreboard** set exec_done<br>**Buffer** write result | `[ C ]`<br>commit<br>**INT_ARF** write x6<br>**INT_tag_mapping** clear busy |  |
| `ld x7, 0(x8)` - G3 Load P3 Bypass |  | `[ IB ]`<br>enqueue instruction | `[ dispatch ]`<br>allocate **scoreboard** entry<br>write **ISQ_Group3**<br>rename x7 | `[ AGU ]`<br>compute address | `[ L1D ]`<br>access **L1D**, hit | `[ WB ]`<br>drive Bypass[3] tag+data<br>**scoreboard** set exec_done<br>**Buffer** write result | `[ C ]`<br>commit<br>**INT_ARF** write x7<br>**INT_tag_mapping** clear busy |  |
| `add x20, x7, x6` - Dependent-G0 | `[ IB ]`<br>enqueue instruction | `[ dispatch ]`<br>allocate **scoreboard** entry<br>write **ISQ_Group0**<br>overlay tag(x6)<br>rename x20 | `[ ISQ_Group0 ]`<br>wait for Bypass[1] tag(x6)<br>wait for Bypass[3] tag(x7) | `[ ISQ_Group0 ]`<br>wait for Bypass[1] tag(x6)<br>wait for Bypass[3] tag(x7) | `[ ISQ_Group0 ]`<br>wait for Bypass[1] tag(x6)<br>wait for Bypass[3] tag(x7) | `[ ALU0 ]`<br>**ISQ_Group0** capture Bypass[1] tag(x6)<br>**ISQ_Group0** capture Bypass[3] tag(x7)<br>execute add | `[ WB ]`<br>drive Bypass[0] tag+data<br>**scoreboard** set exec_done<br>**Buffer** write result | `[ C ]`<br>commit<br>**INT_ARF** write x20<br>**INT_tag_mapping** clear busy |

- **T2 (Resident entry):** the dependent has already dispatched into its group-local ISQ and carries stored ready data and/or `wait_tag`s.
- **T6 (P2 MUX source-ready):** current P3 forwarding sources use exact-tag resident-entry matching; stored sources come from already valid `entry.rs_data`.
- **T6 (Issue rule):** if the selected FU is free, the resident entry issues through the P2 FU-input MUX in this cycle; otherwise matched forwarding data is latched and becomes `Stored Ready` for retry.

## Case 22: INT2_P2_ISQ_STORED_G1P3

**Dimension:** INT two-operand ready-source composition | **Equiv:** P2 MUX: Stored Ready at dispatch + G1 P3 Bypass
**Description:** P2 mux uses stored `entry.rs1_data` and current G1 Bypass data.

| Instruction | T1 | T2 | T3 | T4 | T5 | T6 | T7 | T8 | T9 | T10 |
|:---|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|
| `add x10, x1, x2` - Stored Ready at dispatch | `[ IB ]`<br>enqueue instruction | `[ dispatch ]`<br>allocate **scoreboard** entry<br>write **ISQ_Group0**<br>rename x10 | `[ ALU0 ]`<br>execute add | `[ WB ]`<br>drive Bypass[0] tag+data<br>**scoreboard** set exec_done<br>**Buffer** write result | `[ C ]`<br>commit<br>**INT_ARF** write x10<br>**INT_tag_mapping** clear busy |  |  |  |  |  |
| `mul x6, x3, x4` - G1 P3 Bypass |  |  | `[ IB ]`<br>enqueue instruction | `[ dispatch ]`<br>allocate **scoreboard** entry<br>write **ISQ_Group1**<br>rename x6 | `[ MUL ]`<br>execute mul step 1/3 | `[ MUL ]`<br>execute mul step 2/3 | `[ MUL ]`<br>execute mul step 3/3 | `[ WB ]`<br>drive Bypass[1] tag+data<br>**scoreboard** set exec_done<br>**Buffer** write result | `[ C ]`<br>commit<br>**INT_ARF** write x6<br>**INT_tag_mapping** clear busy |  |
| `add x20, x10, x6` - Dependent-G0 |  |  |  |  | `[ IB ]`<br>enqueue instruction | `[ dispatch ]`<br>allocate **scoreboard** entry<br>use stored operand x10<br>write **ISQ_Group0**<br>rename x20 | `[ ISQ_Group0 ]`<br>wait for Bypass[1] tag(x6) | `[ ALU0 ]`<br>**ISQ_Group0** capture Bypass[1] tag(x6)<br>execute add | `[ WB ]`<br>drive Bypass[0] tag+data<br>**scoreboard** set exec_done<br>**Buffer** write result | `[ C ]`<br>commit<br>**INT_ARF** write x20<br>**INT_tag_mapping** clear busy |

- **T6 (Resident entry):** the dependent has already dispatched into its group-local ISQ and carries stored ready data and/or `wait_tag`s.
- **T8 (P2 MUX source-ready):** current P3 forwarding sources use exact-tag resident-entry matching; stored sources come from already valid `entry.rs_data`.
- **T8 (Issue rule):** if the selected FU is free, the resident entry issues through the P2 FU-input MUX in this cycle; otherwise matched forwarding data is latched and becomes `Stored Ready` for retry.

## Case 23: INT2_P2_ISQ_STORED_G3P3

**Dimension:** INT two-operand ready-source composition | **Equiv:** P2 MUX: Stored Ready at dispatch + G3 Load P3 Bypass
**Description:** P2 mux uses stored `entry.rs1_data` and current G3 load Bypass data.

| Instruction | T1 | T2 | T3 | T4 | T5 | T6 | T7 | T8 | T9 |
|:---|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|
| `add x11, x1, x2` - Stored Ready at dispatch | `[ IB ]`<br>enqueue instruction | `[ dispatch ]`<br>allocate **scoreboard** entry<br>write **ISQ_Group0**<br>rename x11 | `[ ALU0 ]`<br>execute add | `[ WB ]`<br>drive Bypass[0] tag+data<br>**scoreboard** set exec_done<br>**Buffer** write result | `[ C ]`<br>commit<br>**INT_ARF** write x11<br>**INT_tag_mapping** clear busy |  |  |  |  |
| `ld x6, 0(x10)` - G3 Load P3 Bypass |  |  | `[ IB ]`<br>enqueue instruction | `[ dispatch ]`<br>allocate **scoreboard** entry<br>write **ISQ_Group3**<br>rename x6 | `[ AGU ]`<br>compute address | `[ L1D ]`<br>access **L1D**, hit | `[ WB ]`<br>drive Bypass[3] tag+data<br>**scoreboard** set exec_done<br>**Buffer** write result | `[ C ]`<br>commit<br>**INT_ARF** write x6<br>**INT_tag_mapping** clear busy |  |
| `add x20, x11, x6` - Dependent-G0 |  |  |  | `[ IB ]`<br>enqueue instruction | `[ dispatch ]`<br>allocate **scoreboard** entry<br>use stored operand x11<br>write **ISQ_Group0**<br>rename x20 | `[ ISQ_Group0 ]`<br>wait for Bypass[3] tag(x6) | `[ ALU0 ]`<br>**ISQ_Group0** capture Bypass[3] tag(x6)<br>execute add | `[ WB ]`<br>drive Bypass[0] tag+data<br>**scoreboard** set exec_done<br>**Buffer** write result | `[ C ]`<br>commit<br>**INT_ARF** write x20<br>**INT_tag_mapping** clear busy |

- **T5 (Resident entry):** the dependent has already dispatched into its group-local ISQ and carries stored ready data and/or `wait_tag`s.
- **T7 (P2 MUX source-ready):** current P3 forwarding sources use exact-tag resident-entry matching; stored sources come from already valid `entry.rs_data`.
- **T7 (Issue rule):** if the selected FU is free, the resident entry issues through the P2 FU-input MUX in this cycle; otherwise matched forwarding data is latched and becomes `Stored Ready` for retry.

## Case 24: INT2_P2_ISQ_STORED_ISQ_STORED

**Dimension:** INT two-operand ready-source composition | **Equiv:** P2 MUX: Stored Ready at dispatch + Stored Ready at dispatch
**Description:** P2 mux selects both operands from stored `entry.rs_data`; no current-cycle forwarding is needed.

| Instruction | T1 | T2 | T3 | T4 | T5 | T6 | T7 | T8 | T9 | T10 |
|:---|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|
| `add x10, x1, x2` · Stored Ready at dispatch·G0 | `[ IB ]`<br>enqueue instruction | `[ dispatch ]`<br>allocate **scoreboard** entry<br>write **ISQ_Group0**<br>rename x10 | `[ ALU0 ]`<br>execute add | `[ WB ]`<br>drive Bypass[0] tag+data<br>**scoreboard** set exec_done<br>**Buffer** write result | `[ C ]`<br>commit<br>**INT_ARF** write x10<br>**INT_tag_mapping** clear busy |  |  |  |  |  |
| `add x11, x3, x4` · Stored Ready at dispatch·G1 | `[ IB ]`<br>enqueue instruction | `[ dispatch ]`<br>allocate **scoreboard** entry<br>write **ISQ_Group1**<br>rename x11 | `[ ALU1 ]`<br>execute add | `[ WB ]`<br>drive Bypass[1] tag+data<br>**scoreboard** set exec_done<br>**Buffer** write result | `[ C ]`<br>commit<br>**INT_ARF** write x11<br>**INT_tag_mapping** clear busy |  |  |  |  |  |
| `add x20, x10, x11` - Dependent-G0 |  |  |  |  | `[ IB ]`<br>enqueue instruction | `[ dispatch ]`<br>allocate **scoreboard** entry<br>use stored operand x10<br>use stored operand x11<br>write **ISQ_Group0**<br>rename x20 | `[ ISQ_Group0 ]`<br>wait until at ISQ head | `[ ALU0 ]`<br>execute add | `[ WB ]`<br>drive Bypass[0] tag+data<br>**scoreboard** set exec_done<br>**Buffer** write result | `[ C ]`<br>commit<br>**INT_ARF** write x20<br>**INT_tag_mapping** clear busy |

- **T1 (Two producers, different groups, required):** the two `add`s share the T1 enqueue cycle, so they must be routed to different groups — the ISQ holds one entry per group and `dispatch_logic` cannot accept two same-group dispatches in one cycle. They are therefore drawn as `·G0` on `ALU0` and `·G1` on `ALU1`.
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
| `add x5, x1, x2` - Producer-G0 | `[ IB ]`<br>enqueue instruction | `[ dispatch ]`<br>allocate **scoreboard** entry<br>write **ISQ_Group0**<br>rename x5 | `[ ALU0 ]`<br>execute add | `[ WB ]`<br>drive Bypass[0] tag+data<br>**scoreboard** set exec_done<br>**Buffer** write result | `[ C ]`<br>commit<br>**INT_ARF** write x5<br>**INT_tag_mapping** clear busy |  |  |  |  |
| `add x20, x5, x5` - Dependent-G0 |  |  | `[ IB ]`<br>enqueue instruction | `[ dispatch ]`<br>allocate **scoreboard** entry<br>capture Bypass[0] tag(x5), both operands ready<br>write **ISQ_Group0**<br>rename x20 | `[ ALU0 ]`<br>execute add | `[ WB ]`<br>drive Bypass[0] tag+data<br>**scoreboard** set exec_done<br>**Buffer** write result | `[ C ]`<br>commit<br>**INT_ARF** write x20<br>**INT_tag_mapping** clear busy |  |  |

- **T4 (P1 same-tag match):** rs1 and rs2 both match the same producer tag on G0 P3 Bypass.
- **T4 (Payload construction):** one forwarded payload is written into both operand data fields of the new ISQ entry.
- **T5 (Issue):** dependent issues after the ready payload is constructed.

## Case 26: INT2_SAME_RD_P1_G1P3_dispatch_dispatch

**Dimension:** INT same-RD fanout | **Equiv:** P1 MUX: G1 P3 Bypass feeds rs1 and rs2
**Description:** A single G1 producer tag matches both register sources during dependent P1 source resolution.

| Instruction | T1 | T2 | T3 | T4 | T5 | T6 | T7 | T8 | T9 |
|:---|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|
| `mul x5, x1, x2` - Producer-G1 | `[ IB ]`<br>enqueue instruction | `[ dispatch ]`<br>allocate **scoreboard** entry<br>write **ISQ_Group1**<br>rename x5 | `[ MUL ]`<br>execute mul step 1/3 | `[ MUL ]`<br>execute mul step 2/3 | `[ MUL ]`<br>execute mul step 3/3 | `[ WB ]`<br>drive Bypass[1] tag+data<br>**scoreboard** set exec_done<br>**Buffer** write result | `[ C ]`<br>commit<br>**INT_ARF** write x5<br>**INT_tag_mapping** clear busy |  |  |
| `add x20, x5, x5` - Dependent-G0 |  |  |  |  | `[ IB ]`<br>enqueue instruction | `[ dispatch ]`<br>allocate **scoreboard** entry<br>capture Bypass[1] tag(x5), both operands ready<br>write **ISQ_Group0**<br>rename x20 | `[ ALU0 ]`<br>execute add | `[ WB ]`<br>drive Bypass[0] tag+data<br>**scoreboard** set exec_done<br>**Buffer** write result | `[ C ]`<br>commit<br>**INT_ARF** write x20<br>**INT_tag_mapping** clear busy |

- **T6 (P1 same-tag match):** rs1 and rs2 both match the same producer tag on G1 P3 Bypass.
- **T6 (Payload construction):** one forwarded payload is written into both operand data fields of the new ISQ entry.
- **T7 (Issue):** dependent issues after the ready payload is constructed.

## Case 27: INT2_SAME_RD_P1_G3P3_dispatch_dispatch

**Dimension:** INT same-RD fanout | **Equiv:** P1 MUX: G3 Load P3 Bypass feeds rs1 and rs2
**Description:** A single load producer tag matches both register sources during dependent P1 source resolution.

| Instruction | T1 | T2 | T3 | T4 | T5 | T6 | T7 | T8 | T9 |
|:---|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|
| `ld x5, 0(x1)` - Producer-G3 | `[ IB ]`<br>enqueue instruction | `[ dispatch ]`<br>allocate **scoreboard** entry<br>write **ISQ_Group3**<br>rename x5 | `[ AGU ]`<br>compute address | `[ L1D ]`<br>access **L1D**, hit | `[ WB ]`<br>drive Bypass[3] tag+data<br>**scoreboard** set exec_done<br>**Buffer** write result | `[ C ]`<br>commit<br>**INT_ARF** write x5<br>**INT_tag_mapping** clear busy |  |  |  |
| `add x20, x5, x5` - Dependent-G0 |  |  |  | `[ IB ]`<br>enqueue instruction | `[ dispatch ]`<br>allocate **scoreboard** entry<br>capture Bypass[3] tag(x5), both operands ready<br>write **ISQ_Group0**<br>rename x20 | `[ ALU0 ]`<br>execute add | `[ WB ]`<br>drive Bypass[0] tag+data<br>**scoreboard** set exec_done<br>**Buffer** write result | `[ C ]`<br>commit<br>**INT_ARF** write x20<br>**INT_tag_mapping** clear busy |  |

- **T5 (P1 same-tag match):** rs1 and rs2 both match the same producer tag on G3 load P3 Bypass.
- **T5 (Payload construction):** one forwarded payload is written into both operand data fields of the new ISQ entry.
- **T6 (Issue):** dependent issues after the ready payload is constructed.

## Case 28: INT2_SAME_RD_P2_G0P3_dispatch_dispatch

**Dimension:** INT same-RD fanout | **Equiv:** P2 MUX: G0 P3 Bypass feeds rs1 and rs2
**Description:** A resident dependent entry has both wait tags pointing to the same G0 producer.

| Instruction | T1 | T2 | T3 | T4 | T5 | T6 | T7 | T8 | T9 | T10 |
|:---|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|
| `add x5, x1, x2` - Producer-G0 | `[ IB ]`<br>enqueue instruction | `[ dispatch ]`<br>allocate **scoreboard** entry<br>write **ISQ_Group0**<br>rename x5 | `[ ALU0 ]`<br>execute add | `[ WB ]`<br>drive Bypass[0] tag+data<br>**scoreboard** set exec_done<br>**Buffer** write result | `[ C ]`<br>commit<br>**INT_ARF** write x5<br>**INT_tag_mapping** clear busy |  |  |  |  |  |
| `add x20, x5, x5` - Dependent-G1 | `[ IB ]`<br>enqueue instruction | `[ dispatch ]`<br>allocate **scoreboard** entry<br>write **ISQ_Group1**<br>overlay tag(x5)<br>rename x20 | `[ ISQ_Group1 ]`<br>wait for Bypass[0] tag(x5) | `[ ALU1 ]`<br>**ISQ_Group1** capture Bypass[0] tag(x5), both operands ready<br>execute add | `[ WB ]`<br>drive Bypass[1] tag+data<br>**scoreboard** set exec_done<br>**Buffer** write result | `[ C ]`<br>commit<br>**INT_ARF** write x20<br>**INT_tag_mapping** clear busy |  |  |  |  |

- **T2 (Resident entry):** dependent is already in ISQ with rs1 and rs2 waiting on the same producer tag.
- **T4 (P2 same-tag match):** one G0 Bypass payload satisfies both operand inputs.
- **T4 (Issue):** dependent issues through the FU-input MUX when the selected FU is free.

## Case 29: INT2_SAME_RD_P2_G1P3_dispatch_dispatch

**Dimension:** INT same-RD fanout | **Equiv:** P2 MUX: G1 P3 Bypass feeds rs1 and rs2
**Description:** A resident dependent entry has both wait tags pointing to the same G1 producer.

| Instruction | T1 | T2 | T3 | T4 | T5 | T6 | T7 | T8 | T9 | T10 |
|:---|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|
| `mul x5, x1, x2` - Producer-G1 | `[ IB ]`<br>enqueue instruction | `[ dispatch ]`<br>allocate **scoreboard** entry<br>write **ISQ_Group1**<br>rename x5 | `[ MUL ]`<br>execute mul step 1/3 | `[ MUL ]`<br>execute mul step 2/3 | `[ MUL ]`<br>execute mul step 3/3 | `[ WB ]`<br>drive Bypass[1] tag+data<br>**scoreboard** set exec_done<br>**Buffer** write result | `[ C ]`<br>commit<br>**INT_ARF** write x5<br>**INT_tag_mapping** clear busy |  |  |  |
| `add x20, x5, x5` - Dependent-G0 |  |  | `[ IB ]`<br>enqueue instruction | `[ dispatch ]`<br>allocate **scoreboard** entry<br>write **ISQ_Group0**<br>rename x20 | `[ ISQ_Group0 ]`<br>wait for Bypass[1] tag(x5) | `[ ALU0 ]`<br>**ISQ_Group0** capture Bypass[1] tag(x5), both operands ready<br>execute add | `[ WB ]`<br>drive Bypass[0] tag+data<br>**scoreboard** set exec_done<br>**Buffer** write result | `[ C ]`<br>commit<br>**INT_ARF** write x20<br>**INT_tag_mapping** clear busy |  |  |

- **T4 (Resident entry):** dependent is already in ISQ with rs1 and rs2 waiting on the same producer tag.
- **T6 (P2 same-tag match):** one G1 Bypass payload satisfies both operand inputs.
- **T6 (Issue):** dependent issues through the FU-input MUX when the selected FU is free.

## Case 30: INT2_SAME_RD_P2_G3P3_dispatch_dispatch

**Dimension:** INT same-RD fanout | **Equiv:** P2 MUX: G3 Load P3 Bypass feeds rs1 and rs2
**Description:** A resident dependent entry has both wait tags pointing to the same load producer.

| Instruction | T1 | T2 | T3 | T4 | T5 | T6 | T7 |
|:---|:---:|:---:|:---:|:---:|:---:|:---:|:---:|
| `ld x5, 0(x1)` - Producer-G3 | `[ IB ]`<br>enqueue instruction | `[ dispatch ]`<br>allocate **scoreboard** entry<br>write **ISQ_Group3**<br>rename x5 | `[ AGU ]`<br>compute address | `[ L1D ]`<br>access **L1D**, hit | `[ WB ]`<br>drive Bypass[3] tag+data<br>**scoreboard** set exec_done<br>**Buffer** write result | `[ C ]`<br>commit<br>**INT_ARF** write x5<br>**INT_tag_mapping** clear busy |  |
| `add x20, x5, x5` - Dependent-G0 | `[ IB ]`<br>enqueue instruction | `[ dispatch ]`<br>allocate **scoreboard** entry<br>write **ISQ_Group0**<br>overlay tag(x5)<br>rename x20 | `[ ISQ_Group0 ]`<br>wait for Bypass[3] tag(x5) | `[ ISQ_Group0 ]`<br>wait for Bypass[3] tag(x5) | `[ ALU0 ]`<br>**ISQ_Group0** capture Bypass[3] tag(x5), both operands ready<br>execute add | `[ WB ]`<br>drive Bypass[0] tag+data<br>**scoreboard** set exec_done<br>**Buffer** write result | `[ C ]`<br>commit<br>**INT_ARF** write x20<br>**INT_tag_mapping** clear busy |

- **T2 (Resident entry):** dependent is already in ISQ with rs1 and rs2 waiting on the same producer tag.
- **T5 (P2 same-tag match):** one G3 load Bypass payload satisfies both operand inputs.
- **T5 (Issue):** dependent issues through the FU-input MUX when the selected FU is free.

## Case 31: INT2_P4_G1P3_blocked

**Dimension:** INT two-operand ready-source composition, commit held · **Equiv:** P4 Commit + G1 P3 Bypass
**Description:** Same held form as the G3 case, with the P3 source in G1 as a MUL. The older `div` (L=8)
holds the commit until the MUL's writeback cycle, and the dependent captures both sources there in one cycle.
The MUL is injected so its P3 lands on the held commit (T12).

| Instruction | T1 | T2 | T3 | T4 | T5 | T6 | T7 | T8 | T9 | T10 | T11 | T12 | T13 | T14 | T15 |
|:---|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|
| `div x11, x12, x5` · Blocker·G0 | `[ IB ]`<br>enqueue instruction | `[ dispatch ]`<br>allocate **scoreboard** entry<br>write **ISQ_Group0**<br>rename x11 | `[ DIV ]`<br>divide step 1/8 | `[ DIV ]`<br>divide step 2/8 | `[ DIV ]`<br>divide step 3/8 | `[ DIV ]`<br>divide step 4/8 | `[ DIV ]`<br>divide step 5/8 | `[ DIV ]`<br>divide step 6/8 | `[ DIV ]`<br>divide step 7/8 | `[ DIV ]`<br>divide step 8/8 | `[ WB ]`<br>drive Bypass[0] tag+data<br>**scoreboard** set exec_done<br>**Buffer** write result | `[ C ]`<br>commit<br>**INT_ARF** write x11<br>**INT_tag_mapping** clear busy |  |  |  |
| `add x7, x8, x9` · P4 source·G0 |  | `[ IB ]`<br>enqueue instruction | `[ dispatch ]`<br>allocate **scoreboard** entry<br>write **ISQ_Group0**<br>rename x7 | `[ ALU0 ]`<br>execute add | `[ WB ]`<br>drive Bypass[0] tag+data<br>**scoreboard** set exec_done<br>**Buffer** write result | `[ Buffer ]`<br>hold<br>wait for commit | `[ Buffer ]`<br>hold<br>wait for commit | `[ Buffer ]`<br>hold<br>wait for commit | `[ Buffer ]`<br>hold<br>wait for commit | `[ Buffer ]`<br>hold<br>wait for commit | `[ Buffer ]`<br>hold<br>wait for commit | `[ C ]`<br>commit<br>**INT_ARF** write x7<br>**INT_tag_mapping** clear busy |  |  |  |
| `mul x6, x3, x4` · P3 source·G1 |  |  |  |  |  |  | `[ IB ]`<br>enqueue instruction | `[ dispatch ]`<br>allocate **scoreboard** entry<br>write **ISQ_Group1**<br>rename x6 | `[ MUL ]`<br>execute mul step 1/3 | `[ MUL ]`<br>execute mul step 2/3 | `[ MUL ]`<br>execute mul step 3/3 | `[ WB ]`<br>drive Bypass[1] tag+data<br>**scoreboard** set exec_done<br>**Buffer** write result | `[ C ]`<br>commit<br>**INT_ARF** write x6<br>**INT_tag_mapping** clear busy |  |  |
| `add x20, x7, x6` · Dependent·G0 |  |  |  |  |  |  |  |  |  |  | `[ IB ]`<br>enqueue instruction | `[ dispatch ]`<br>allocate **scoreboard** entry<br>capture Commit CDB tag(x7), ready<br>capture Bypass[1] tag(x6), ready<br>write **ISQ_Group0**<br>rename x20 | `[ ALU0 ]`<br>execute add | `[ WB ]`<br>drive Bypass[0] tag+data<br>**scoreboard** set exec_done<br>**Buffer** write result | `[ C ]`<br>commit<br>**INT_ARF** write x20<br>**INT_tag_mapping** clear busy |
- **Acceptance (mechanism-based — delta is an output here, not an input):**
  1. `P4 source.P4 − P3 > 1` is the point: its commit is held until the blocker retires.
  2. `P4 source.P4 == P3 source.P3 == dependent.P1`: the held commit and the P3 writeback land in the same
     cycle, which is the only way this composition can occur — an older P3 source can never coincide with a
     commit, because in-order retirement forces the commit past the older source's own writeback.
  3. `P4 source.P3 − P2 == L` and `P3 source.P3 − P2 == L`: neither writeback was disturbed.
  4. `dependent.P2 − P1 == 1`: the dependent had both operands in its dispatch cycle.
  5. The dependent could not have been dispatched earlier: while its source is completed but uncommitted the
     writeback bypass is already gone and there is no commit-to-issue path, so a consumer parked on it would
     never wake. `p1/dependency_check.sv` raises `slot_missed_wakeup` and `p1/dispatch_logic.sv` (lines 394
     and 417) keeps it out of an ISQ; it dispatches once the value can come from the Commit CDB, which is why
     its P1 lands on the commit cycle rather than wherever it was injected.
