# INT Two-Operands Ready-Source Dependency Caselist

Source K-maps:

```text
../k-maps/INT_P1MUX_two_operands_dependency_KMap_v2.drawio
../k-maps/INT_P2MUX_two_operands_dependency_KMap_v2.drawio
```

Normative timing source:

```text
pending promotion to spec/or-be/
```

Golden RTL anchor for the producer latencies in this file: OpenRio **`589ca8f`**
(`--dut-kind rtl_full`). Measurement report: `../../latency_bench/Latency_Report.md`.

This caselist covers the source-ready composition of one dependent instruction with two operands. The P1 MUX cases cover operands captured while constructing a new ISQ payload. The P2 MUX cases cover an already-resident ISQ entry receiving current-cycle forwarding at FU-input time. It does not enumerate producer opcode latency variants inside the same POI; those are covered by `INT_single_operand_dependency_caselist.md`.

## Reading Rules

`Data source 1 ready` maps to the dependent instruction's first register source. `Data source 2 ready` maps to the dependent instruction's second register source. In the P1 MUX map, data source 2 may also be `IMM` for immediate-form instructions.

For P1 MUX cases, `Already in ARF` means the source producer committed before the dependent reaches P1 and the source is read from the integer ARF while the ISQ payload is built.

For P2 MUX cases, `Stored Ready at dispatch` replaces both `Already in ARF` and immediate-ready source shapes; the case names carry it as the token `ISQ_STORED`. The token names **where the value lives** — the resident ISQ entry — while the figure's `dispatch` column gives the cycle by which it is already there: by the dependent's own `dispatch` cycle (its P1) the source is already `rs_ready=1` with valid operand payload data, so the P2 MUX needs no current-cycle forwarding for it. That value may have come from P1 ARF/P3/P4 capture, from an earlier resident-entry P3 forwarding latch, or from immediate decode payload construction. Current-cycle P2 forwarding sources are only `G0 P3 Bypass`, `G1 P3 Bypass`, and `G3 Load P3 Bypass`. P2 MUX never consumes `P4 Commit CDB`. If a P3 forwarding match occurs but the selected FU cannot issue that cycle, the matched data is latched at the clock edge, so from the next cycle the entry is `Stored Ready` for a later issue — a P2 event, not a `dispatch` one.

Current INT result timing boundaries:

| Producer | P3 delta | P4 delta | ARF boundary delta |
|---|---:|---:|---:|
| ALU/BRU result | 2 | 3 | 4 |
| MUL result | 4 | 5 | 6 |
| DIV/REM result | **5** | **6** | **7** |
| LOAD hit result | **4** | **5** | **6** |

> **Revision (2026-10): producer latencies are now the measured values**
> (`../../latency_bench/Latency_Report.md`, OpenRio `589ca8f`, `--dut-kind rtl_full`).
>
> | Producer | was | now | effect |
> |---|---:|---:|---|
> | ALU/BRU result (also the JALR link) | 2/3/4 | **2/3/4** | unchanged |
> | MUL result | 4/5/6 | **4/5/6** | unchanged |
> | DIV/REM result | 9/10/11 | **5/6/7** | `L` 8 → 4 |
> | LOAD hit result | 3/4/5 → 4/5/6 | **4/5/6** | `L` 2 → 3 (previous revision) |
>
> LOAD wording follows Cache HAS `V1.0 rev.1`: E1 AGU, E2 L1 D cache, E3 load-data arbiter
> together with the CDB FIFO, three cycles being the earliest case.

Total case count:

```text
P1 MUX 17 cases + P2 MUX 7 cases + same-RD fanout 6 cases = 30 cases
```

For any mixed-source P3 case, issue the producers at different P1 cycles as needed so their P3 publications align in the same dependent source-resolution cycle. For example, a G1 MUL producer must be issued two cycles earlier than a G0 ALU producer if both results should appear at P3 in the same cycle.

The three same-bypass diagonal cells are excluded because they are gray `don't exist` cells in the K-map. Two different same-group producers cannot both publish on the same group P3 bypass lane in one cycle. A separate instruction shape where one producer feeds both operands, such as `add x20, x5, x5`, is legal, but it is not a two-source composition POI.

**Same-group dispatch.** Separately from the P3-lane rule above, the ISQ holds one entry per group, so **two instructions of the same group cannot be dispatched in the same cycle**. A dependent that would otherwise share its group's dispatch cycle with the producer that supplies the source is routed to the other ALU group, and the figures show it as `Dependent-G1`. This is the same routing choice the single-operand `delta_0` rows make.

## Filler and Program Construction

A case is a program snippet, not a cycle diagram: the dispatch gaps the figures show
have to be filled with real instructions. The pipeline dispatches up to two
instructions per cycle, in program order, so if one case instruction must dispatch
`g` cycles after another, `2g - 1` instructions sit between them. A `Fillers` value of
`0` means the two dispatch in the same cycle and must therefore go to different
groups, which is what the figures already require.

- **Filler instruction**: `addi xN, x0, 1`, with the destination taken from
  `x13`-`x19`, `x21`-`x27` and `x30` (15 registers, enough for the largest program).
  Those registers appear in no case and lie outside every set the template reserves:
  `x1`-`x4` are the inputs, `x5`-`x12` are producer temporaries, and `x28`, `x29` and
  `x31` carry the exit code, so a filler must never touch them. Every filler writes a
  different one and no filler reads anything a case writes, so the fillers are
  independent of the case and of each other. No filler touches memory.
- **Why an integer ALU operation**: the dispatcher can send it to either `G0` or `G1`,
  so a filler sharing a cycle with a case instruction that is pinned to one group can
  always be placed in the other, and never displaces the case.
- **Exception: dependency-chained fillers.** When a lane must be kept free, the fillers are
  written as a chain, each `addi` reading the previous filler's result, instead of as
  independent instructions. A chain advances one filler per cycle and, being a single ALU
  op per cycle, is routed to `G0`; independent fillers are not, because the second of the
  two dispatched in a cycle is routed to `G1` and takes that lane's writeback, which pushes
  a `G1`-pinned producer's own `P3` and therefore its `P4`. The count-to-gap relation
  changes too, so it has to be measured rather than computed from `2g - 1`.
  `INT2_P4_G3P3` is the worked example, with `Fillers` `1 / 5 chained`.
- **Three counting conventions in the tables.** A plain number is the independent
  single-cycle `addi` filler and the `2g - 1` count does hold for it. `branch` marks
  never-taken branches (`bne x0, x0, 7f`), used where a producer is pinned to `G1` and must
  keep its lane: a BRU op is in the fixed `G0` group so it cannot be pushed onto `G1`, and it
  is single-cycle so the granularity stays at one cycle. `chained` marks a dependency chain of
  `addi`, which advances one filler per cycle and stays on `G0`.
  `Nld+Mfp` marks `N` load fillers plus `M` `fadd.s` fillers, used where **both** lanes 0 and 1
  are held by producers: the load uses `G3` and the `fadd.s` uses `G2`, so neither can steal a
  producer's writeback. Those two fillers do not advance the stream one cycle each, so the count
  had to be measured; the rows also need the FS enable for the `fadd.s`. Every notation other
  than a plain number is a measured recipe, and such rows are frozen under `../calibrated_cases/`
  because `gen_cases.py` cannot render them.
- **Count**: `Fillers` lists, in program order, how many fillers follow each case
  instruction, so the last entry always follows the last producer.
- **Slot order within a cycle**: a case instruction must be the **first** of the two
  slots in any cycle it shares with a filler. The dispatcher places slot 0 first, and
  slot 1 picks its group so as to avoid whatever slot 0 took; a filler going first
  could take `G0` and leave a case instruction that is pinned to `G0` with no distinct
  group, which drops it out of that cycle and shifts the case by one cycle. The counts
  in the tables make this automatic: fillers follow a case instruction and every gap is
  `2g - 1`, so each case instruction lands at an even index, which is slot 0, as long as
  the first one does. The `0` entries are the deliberate exception: those two case
  instructions occupy slots 0 and 1 of one cycle and must go to different groups, which
  the figures already require.

Worked example: `INT2_G3P3_G1P3` has `Fillers` = `0 / 4 branch`, so the program is `mul`, the
load, 4 never-taken branches, then `add x20`. Rows whose entry is a plain number use the
`2g - 1` independent `addi` filler instead. `INT2_G1P3_G0P3` uses the third notation,
`Nld+Mfp`; see the note under the table.

**Assumption to confirm by simulation**: a straight-line program of this shape
sustains two dispatches per cycle.

## Why IMM Is Kept in the P1 MUX Map

`IMM` is necessary because many real INT/MEM dependent instructions are not two-register consumers. `addi`, `andi`, shift-immediate operations, load address generation, store address generation, and `jalr` all combine one register source with an immediate operand.

Without the `IMM` column, the K-map would only cover R-type two-register consumers and would miss the important timing shape where one source waits for bypass/commit/ARF while the other operand is ready by construction and has no DST_REG tag. Keeping `IMM` prevents us from faking an unnecessary second register dependency just to fit a two-register table.

`IMM` is modeled only as data source 2 in the P1 MUX map. The `IMM` row is not used. In the P2 MUX map, immediate operands are already resident payload data and are covered by `Stored Ready at dispatch`.

## P1 MUX Case List

| Case | Source 1 Ready | Source 2 Ready | Instructions | Fillers after each | Timing Setup | Expected Behavior |
|:---|:---|:---|:---|:---|:---|:---|
| `INT2_G1P3_G0P3` | G1 P3 Bypass | G0 P3 Bypass | `div x6, x3, x4; mul x8, x1, x2 -> add x20, x8, x6` | `0ld+1fp / 0ld+3fp` | The G0 side is a **DIV**, not an ALU, and it dispatches one cycle **before** the MUL so the two P3 publications coincide. Fillers must stay off lanes 0 and 1. See the note below; measured `div.P3 = mul.P3 = dep.P1`. | Dependent captures rs1 from G1 Bypass and rs2 from G0 Bypass in the same source-ready cycle. |
| `INT2_G3P3_G0P3` | G3 Load P3 Bypass | G0 P3 Bypass | `ld x7, 0(x8); add x5, x1, x2 -> add x20, x7, x5` | 3 / 3 | Issue load one cycle before G0 ALU producer so both P3 publications align. | Dependent captures rs1 from G3 load Bypass and rs2 from G0 Bypass. |
| `INT2_P4_G0P3` | P4 Commit | G0 P3 Bypass | `add x6, x3, x4; add x5, x1, x2 -> add x20, x6, x5` | 1 / 3 | Arrange older `x6` producer to commit in the same cycle that `x5` producer publishes at G0 P3. | P1 source resolution uses Commit CDB for rs1 and G0 Bypass for rs2. |
| `INT2_ARF_G0P3` | Already in ARF | G0 P3 Bypass | `add x10, x1, x2; add x5, x3, x4 -> add x20, x10, x5` | 3 / 3 | Producer for `x10` is issued early enough to commit before the dependent reaches P1; G0 producer for `x5` reaches P3 in the dependent source-ready cycle. | rs1 reads ARF; rs2 captures G0 Bypass. |
| `INT2_G0P3_IMM` | G0 P3 Bypass | IMM | `add x5, x1, x2 -> addi x20, x5, 16` | 3 | G0 producer reaches P3 when dependent immediate-form instruction resolves sources. | rs1 captures G0 Bypass; rs2 is immediate and has no dependency tag. |
| `INT2_G3P3_G1P3` | G3 Load P3 Bypass | G1 P3 Bypass | `mul x6, x3, x4; ld x7, 0(x8) -> add x20, x7, x6` | 0 / 4 branch | Issue `mul` one cycle before load so G1 and G3 P3 publications align. | Dependent captures rs1 from G3 load Bypass and rs2 from G1 Bypass. |
| `INT2_P4_G1P3` | P4 Commit | G1 P3 Bypass | `ld x6, 0(x10); mul x8, x1, x2 -> add x20, x6, x8` | 1 / 5 branch | The commit-side producer is placed before the MUL and the fillers are never-taken branches; see the note below. Measured `ld.P4 = mul.P3 = dep.P1`. | P1 source resolution uses Commit CDB for rs1 and G1 Bypass for rs2. |
| `INT2_ARF_G1P3` | Already in ARF | G1 P3 Bypass | `add x10, x1, x2; mul x6, x3, x4 -> add x20, x10, x6` | 0 / 4 branch | Producer for `x10` is issued early enough to commit before the dependent reaches P1; G1 producer for `x6` reaches P3 in the dependent source-ready cycle. | rs1 reads ARF; rs2 captures G1 Bypass. |
| `INT2_G1P3_IMM` | G1 P3 Bypass | IMM | `mul x6, x3, x4 -> addi x20, x6, 16` | 5 branch | G1 producer reaches P3 when dependent immediate-form instruction resolves sources. | rs1 captures G1 Bypass; rs2 is immediate and has no dependency tag. |
| `INT2_P4_G3P3` | P4 Commit | G3 Load P3 Bypass | `mul x6, x3, x4; ld x8, 0(x10) -> add x20, x6, x8` | 1 / 5 chained | The commit-side producer is placed **before** the load, and the fillers form a dependency chain. Both are forced; see the note below the table. Measured `mul.P4 = ld.P3 = dep.P1`. | P1 source resolution uses Commit CDB for rs1 and G3 load Bypass for rs2. |
| `INT2_ARF_G3P3` | Already in ARF | G3 Load P3 Bypass | `add x11, x1, x2; ld x6, 0(x10) -> add x20, x11, x6` | 0 / 7 | Producer for `x11` is issued early enough to commit before the dependent reaches P1; load producer for `x6` reaches P3 in the dependent source-ready cycle. | rs1 reads ARF; rs2 captures G3 load Bypass. |
| `INT2_G3P3_IMM` | G3 Load P3 Bypass | IMM | `ld x6, 0(x10) -> addi x20, x6, 16` | 7 | Load producer reaches P3 when dependent immediate-form instruction resolves sources. | rs1 captures G3 load Bypass; rs2 is immediate and has no dependency tag. |
| `INT2_P4_P4` | P4 Commit | P4 Commit | `add x5, x1, x2; add x6, x3, x4 -> add x20, x5, x6` | 0 / 5 | Arrange the two older producers as P4 head0/head1 commits in the dependent source-resolution cycle. | P1 source resolution captures both operands from the two Commit CDB lanes. |
| `INT2_ARF_P4` | Already in ARF | P4 Commit | `add x10, x1, x2; add x6, x3, x4 -> add x20, x10, x6` | 1 / 5 | Producer for `x10` is issued early enough to commit before the dependent reaches P1; the `x6` producer commits in the dependent source-resolution cycle. | rs1 reads ARF; rs2 captures Commit CDB. |
| `INT2_P4_IMM` | P4 Commit | IMM | `add x5, x1, x2 -> addi x20, x5, 16` | 5 | Older `x5` producer commits in the dependent immediate-form instruction's source-resolution cycle. | rs1 captures Commit CDB; rs2 is immediate and has no dependency tag. |
| `INT2_ARF_ARF` | Already in ARF | Already in ARF | `add x10, x1, x2; add x11, x3, x4 -> add x20, x10, x11` | 0 / 7 | Both producers are issued early enough to commit before the dependent reaches P1, so neither source has a live DST_REG mapping. | Both operands read ARF at P1; no bypass or commit overlay is needed. |
| `INT2_ARF_IMM` | Already in ARF | IMM | `add x10, x1, x2 -> addi x20, x10, 16` | 7 | Producer for `x10` is issued early enough to commit before the dependent reaches P1; the second operand is immediate. | rs1 reads ARF; rs2 is immediate and has no dependency tag. |

> **Note on `INT2_P4_G3P3`: the composer and the fillers are both forced.**
>
> The row needs three cycles to be the same one: the commit-side producer's `P4`, the
> load's `P3`, and the dependent's `P1`. Two things block the obvious construction.
>
> **The commit-side producer cannot be an ALU.** Its commit would have to land on the
> load's `P3`, which needs it to dispatch one cycle *after* the load. Dispatch follows
> program order, so it would then sit behind the load, and in-order commit holds its
> commit at or after the load's own commit, which is the load's `P3` plus one. The
> measured gap is `+1` with the load first and `-1` with the ALU first, so zero is
> unreachable for an ALU composer. This row therefore uses a MUL, whose `P4` delta of
> five is large enough, and the ALU/MUL choice does not change what the dependent sees:
> rs1 arrives on the Commit CDB either way.
>
> **The fillers must be a dependency chain, not `2g - 1` independent ones.** With
> independent fillers, one of the two dispatched per cycle is routed to G1, takes that
> lane's writeback and pushes the commit-side producer's own `P3`, and therefore its
> `P4`. A chain advances one filler per cycle and, being a single ALU op per cycle, stays
> on G0, which leaves the G1 producer alone. The measured values are `mul.P1=7 P4=12`,
> `ld.P1=8 P3=12`, `dep.P1=12`.
>
> **`INT2_P4_G1P3` needs one more step beyond that, and its fillers are branches.** Its
> bypass side must be a MUL because the token is `G1P3`, so the MUL is pinned to G1. A
> chain cannot be used here: a chain element dispatched while the previous one still holds
> `G0`'s entry is routed to G1, and one such element landing in the MUL's writeback cycle
> pushes `mul.P3` from 12 to 13 exactly when the dependent's fillers become long enough to
> be useful. Never-taken branches avoid this because a BRU op is in the fixed `G0` group
> and cannot be pushed to G1; `bne x0, x0, 7f` never redirects, is single-cycle and writes
> no register. The measured values are `ld.P1=7 P4=12` on lane 3, `mul.P1=8 P3=12` on
> lane 1, `dep.P1=12`, both producers' writebacks clean.

> **Note on `INT2_G1P3_G0P3`: both producers hold a lane, so the G0 side was changed.**
>
> This row needs one cycle to carry three things: the G1 P3 publication, the G0 P3
> publication, and the dependent's source resolution. Every filler type that is single-cycle
> is an ALU op, and such an op is routed to whichever of `G0` and `G1` is free; with a
> producer pinned to each lane, one of them is always taken, so an independent filler, a
> chain or a branch all end up stealing a producer's writeback. Branches are worst here
> because a BRU op is in the fixed `G0` group and collides with the `G0` producer directly.
>
> The only lane-safe fillers are `ld` on `G3` and `fadd.s` on `G2`, and those advance the
> stream roughly two cycles per filler, so the counts had to be measured. What makes the row
> work is the **choice of the G0 producer**: a DIV has a `P3` delta of five against an ALU's
> two, so it must dispatch one cycle *before* the MUL, and with that spacing the two
> publications land together while both writebacks stay clean. Order matters: with the MUL
> first, no spacing produced a clean coincidence. Measured `div.P1=15 P3=20` on lane 0,
> `mul.P1=16 P3=20` on lane 1, `dep.P1=20`.

## P2 MUX Case List

In every P2 case below, the dependent instruction is already resident in its group-local ISQ before the source-ready cycle. At least one not-yet-ready register source observes a same-cycle P3 tag match at P2, unless the case is the pure `Stored Ready at dispatch` resident-data case. `P4 Commit CDB` is intentionally absent because it terminates at P1 MUX and never drives resident-entry P2 MUX forwarding.

| Case | Source 1 at P2 MUX | Source 2 at P2 MUX | Instructions | Fillers after each | Timing Setup | Expected Behavior |
|:---|:---|:---|:---|:---|:---|:---|
| `INT2_P2_G1P3_G0P3` | G1 P3 Bypass | G0 P3 Bypass | `mul x6, x3, x4; add x5, x1, x2 -> add x20, x6, x5` | 3 / 0 | Dispatch dependent early with wait tags for both operands. Issue `mul` two cycles before `add` so G1 and G0 results publish at P3 together while the dependent is resident. | P2 FU-input mux selects rs1 from G1 Bypass and rs2 from G0 Bypass; the resident entry can issue in that cycle if the selected FU is free. |
| `INT2_P2_G3P3_G0P3` | G3 Load P3 Bypass | G0 P3 Bypass | `ld x7, 0(x8); add x5, x1, x2 -> add x20, x7, x5` | 3 / 0 | Dispatch dependent early with wait tags; issue the load one cycle before the G0 ALU producer so both P3 publications align. | P2 mux selects rs1 from G3 load Bypass and rs2 from G0 Bypass. |
| `INT2_P2_ISQ_STORED_G0P3` | Stored Ready at dispatch | G0 P3 Bypass | `add x10, x1, x2; add x5, x3, x4 -> add x20, x10, x5` | 7 / 0 | Resolve and store `x10` in the dependent ISQ entry earlier; keep rs2 waiting until `x5` reaches G0 P3. | P2 mux uses stored `entry.rs1_data` and current G0 Bypass data. |
| `INT2_P2_G3P3_G1P3` | G3 Load P3 Bypass | G1 P3 Bypass | `mul x6, x3, x4; ld x7, 0(x8) -> add x20, x7, x6` | 0 / 3 | Dispatch dependent early; issue `mul` one cycle before load so G1 and G3 P3 publications align. | P2 mux selects rs1 from G3 load Bypass and rs2 from G1 Bypass. |
| `INT2_P2_ISQ_STORED_G1P3` | Stored Ready at dispatch | G1 P3 Bypass | `add x10, x1, x2; mul x6, x3, x4 -> add x20, x10, x6` | 0 / 2 branch | Resolve and store `x10` in the dependent entry earlier; keep rs2 waiting for the G1 producer. | P2 mux uses stored `entry.rs1_data` and current G1 Bypass data. |
| `INT2_P2_ISQ_STORED_G3P3` | Stored Ready at dispatch | G3 Load P3 Bypass | `add x11, x1, x2; ld x6, 0(x10) -> add x20, x11, x6` | 3 / 3 | Resolve and store `x11` in the dependent entry earlier; keep rs2 waiting for the load producer. | P2 mux uses stored `entry.rs1_data` and current G3 load Bypass data. |
| `INT2_P2_ISQ_STORED_ISQ_STORED` | Stored Ready at dispatch | Stored Ready at dispatch | `add x10, x1, x2; add x11, x3, x4 -> add x20, x10, x11` | 0 / 7 | Resolve both sources before the observed P2 issue cycle; the dependent entry is resident with both `rs_ready` bits set. | P2 mux selects both operands from stored `entry.rs_data`; no current-cycle forwarding is needed. |

## Supplemental Same-RD Fanout Case List

These cases cover the legal shape hidden behind the gray same-P3-source diagonal cells. The gray cells mean two different producers cannot publish on the same group P3 bypass lane in the same cycle. They do not forbid one producer payload from feeding both rs1 and rs2 of the same dependent instruction.

| Case | MUX Point | Source Ready | Instructions | Fillers after each | Timing Setup | Expected Behavior |
|:---|:---|:---|:---|:---|:---|:---|
| `INT2_SAME_RD_P1_G0P3_dispatch_dispatch` | P1 MUX | G0 P3 Bypass fanout | `add x5, x1, x2 -> add x20, x5, x5` | 3 | Producer reaches G0 P3 when dependent constructs its ISQ payload. | P1 source resolution matches the same producer tag for both rs1 and rs2 and captures one G0 Bypass payload into both operands. |
| `INT2_SAME_RD_P1_G1P3_dispatch_dispatch` | P1 MUX | G1 P3 Bypass fanout | `mul x5, x1, x2 -> add x20, x5, x5` | `5 branch` | MUL producer reaches G1 P3 when dependent constructs its ISQ payload. | P1 source resolution matches the same producer tag for both rs1 and rs2 and captures one G1 Bypass payload into both operands. |
| `INT2_SAME_RD_P1_G3P3_dispatch_dispatch` | P1 MUX | G3 Load P3 Bypass fanout | `ld x5, 0(x1) -> add x20, x5, x5` | 7 | Load producer reaches G3 P3 when dependent constructs its ISQ payload. | P1 source resolution matches the same producer tag for both rs1 and rs2 and captures one G3 load Bypass payload into both operands. |
| `INT2_SAME_RD_P2_G0P3_dispatch_dispatch` | P2 MUX | G0 P3 Bypass fanout | `add x5, x1, x2 -> add x20, x5, x5` | 0 | Dependent is already resident with both rs wait tags matching the same G0 producer. | P2 resident-entry matching fans out one G0 Bypass payload to both operand inputs in the FU-input MUX cycle. |
| `INT2_SAME_RD_P2_G1P3_dispatch_dispatch` | P2 MUX | G1 P3 Bypass fanout | `mul x5, x1, x2 -> add x20, x5, x5` | `3 branch` | Dependent is already resident with both rs wait tags matching the same G1 producer. | P2 resident-entry matching fans out one G1 Bypass payload to both operand inputs in the FU-input MUX cycle. |
| `INT2_SAME_RD_P2_G3P3_dispatch_dispatch` | P2 MUX | G3 Load P3 Bypass fanout | `ld x5, 0(x1) -> add x20, x5, x5` | 3 | Dependent is already resident with both rs wait tags matching the same G3 load producer. | P2 resident-entry matching fans out one G3 load Bypass payload to both operand inputs in the FU-input MUX cycle. |

## Notes

- These cases are ready-source composition cases. They intentionally do not enumerate whether a P3 source was produced by ALU, MUL, DIV, or load latency variants beyond the lane/source required by the case.
- If a case needs a longer-latency producer to align with a shorter-latency producer, adjust producer dispatch deltas. That scheduling detail does not create a new POI.
- White mirrored cells in the K-map are covered by rs1/rs2 symmetry. The chosen source order above follows the filled-triangle orientation where possible.
- The same-producer shape `add x20, x5, x5` is legal and covered by the supplemental same-RD fanout cases above. It is still not counted as a normal two-source composition POI.
- P2 cases do not imply that P2 reads ARF. A source shown as `Stored Ready at dispatch` is already present in the resident entry's `entry.rs_data`.
