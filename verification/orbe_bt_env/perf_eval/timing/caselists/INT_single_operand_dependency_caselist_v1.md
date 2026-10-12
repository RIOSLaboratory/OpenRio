# INT Single-Operand Dependency Caselist

Source K-map:

```text
../k-maps/INT_single_operand_dependency_KMap_v2.drawio
```

Normative timing sources:

```text
pending promotion to spec/or-be/
```

Golden RTL anchor for the producer latencies in this file: OpenRio **`589ca8f`**
(`--dut-kind rtl_full`). Measurement report: `../../latency_bench/Latency_Report.md`.

Naming rule:

```text
<Producer>_to_<Representative_INT_Consumer>_delta_<n>
```

`delta` is:

```text
delta = dependent first P1/DSP attempt cycle
      - producer first P1/DSP dispatch cycle
```

This v2 caselist reduces the previous full producer-dependent expansion to one representative INT consumer per producer latency family. Non-MEM INT dependent instruction classes are covered by the representative `*_to_ALU` cases. LOAD/STORE as dependent instructions are MEM/LSU operand cases and are moved to MEM K-maps. LOAD remains here only as an INT-register producer.

Total case count:

```text
ALU  5 cases  + MUL 7 cases + DIV 8 cases + LOAD 7 cases + MUL_to_JALR 7 cases = 34 cases
```

> **Revision (2026-10): producer latencies replaced by measured values.**
> All five families' `L` were measured on the current RTL (`--dut-kind rtl_full`) through the
> observation surface. The method was accepted only after the three known points came out right
> (ALU = 1, MUL = 3, LOAD = 3). Source: `../../latency_bench/Latency_Report.md`.
>
> | Family | was | now | effect |
> |---|---:|---:|---|
> | ALU | 1 | **1** | unchanged |
> | MUL | 3 | **3** | unchanged |
> | DIV | 8 | **4** | 12 → **8** cases |
> | LOAD | 2 → 3 | **3** | 6 → **7** cases (previous revision) |
> | JALR | 3 | **3** | 5 → **7** cases; JALR is now a consumer |
>
> The rule `P3 delta = latency + 1` is unchanged.
>
> **JALR is a consumer, never a producer.** The earlier shape had `JALR` on the producer side
> and consumed its link value (`rd = PC + 4`). That shape is withdrawn: producing the link and
> changing the control flow occupy the same window, and the redirect squashes the dependent, so
> the case cannot measure what it claims. The family is now `MUL_to_JALR`: a MUL produces the
> jump target and the JALR consumes it through `rs1`, which is a dependency the architecture
> really has. The ladder therefore follows the **producer's** latency, `L = 3`, enumerated over
> `0..6`. The producer's type is irrelevant to the dependency; only its latency matters. The
> redirect-ready latency (measured 2) remains a control-flow metric and is not enumerated.
>
> **LOAD timing wording** follows Cache HAS `V1.0 rev.1`: E1 AGU, E2 L1 D cache, E3 load-data
> arbiter together with the CDB FIFO. Three cycles is the **earliest** case; it holds only when
> the new entry becomes the CDB head.

## Delta Meaning

Normal no-older-blocker path:

| Producer | Producer latency (measured) | P3 delta | P4 delta | ARF boundary delta | Enumerated deltas |
|---|---:|---:|---:|---:|---|
| ALU | 1 | 2 | 3 | 4 | 0..4 |
| MUL | 3 | 4 | 5 | 6 | 0..6 |
| DIV | **4** | **5** | **6** | **7** | **0..7** |
| LOAD | 3 | 4 | 5 | 6 | 0..6 |
| JALR (MUL producer) | **3** | **4** | **5** | **6** | **0..6** |

JAL/JALR note:

`JALR` appears in this caselist only as a **dependent**. Its first source, `rs1`, is the jump
target, so the dependency is architectural: the JALR cannot jump until the target register is
ready. The producer passes a valid address through by multiplying by one, `mul x10, x11, x1` with
`x11` pointing at the fall-through label and `x1` equal to 1, which keeps the producer multi-cycle
without making the target invalid. The jump still occurs and still costs a redirect; it lands on
the instruction immediately after the JALR so nothing in the measured window is skipped. The
performance report's "about 3 cycles" for taken `JAL`/`JALR` is the **redirect-ready** metric
(measured 2 here); it is a control-flow event and is not enumerated as a dependency delta.

Case behavior labels:

| Label | Meaning |
|---|---|
| `overlay` | `delta_0` same-bundle slot0 -> slot1 rename overlay. |
| `wait_for_p3` | Dependent dispatches before producer P3, carries `wait_tag`, and waits resident in ISQ. |
| `p3_capture` | Dependent first P1 attempt exactly matches producer P3 Bypass and captures `bypass_data`. |
| `p4_capture` | Dependent first P1 attempt exactly matches producer P4 Commit CDB and captures `commit_data`. |
| `arf_read` | Producer committed earlier; dependent reads ARF at P1. |

Condition A extension:

If an older head blocker delays the producer's P4 commit after producer P3 has already passed, then additional `delta_n` attempts between P3 and delayed P4 are Condition A stalls. For example, if an ALU producer's P4 is delayed from `delta_3` to `delta_6`, then `delta_3`, `delta_4`, and `delta_5` are Condition A stalls, `delta_6` is P4 capture, and `delta_7` is ARF read. This extension is derived from the spec and is not repeated as separate nominal cases below.

## Group rule for `delta_0`

The ISQ holds **one entry per group**, so a group can dispatch at most one instruction per cycle.
Two instructions in the **same group** therefore differ by at least one dispatch cycle:
**`delta_0` (`overlay`) is reachable only when the producer and the consumer are in different groups.**

Every `delta_0` row states its groups in the `G` column, and for that case the consumer is routed to
the group other than the producer's. Rows with `delta >= 1` may be same-group.

Every case table below carries a `G` column: **`producer group → consumer group`**.

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

Worked example: `ALU_to_ALU_delta_3` has `Fillers` = `5`, so the program is
`add x5, x1, x2`, 5 fillers, `add x6, x5, x3`. The producer dispatches at cycle 0 and
the dependent at cycle 3, which is the `delta` its name states.

**Assumption to confirm by simulation**: a straight-line program of this shape
sustains two dispatches per cycle.

## ALU_to_ALU

Representative:

```asm
add x5, x1, x2
add x6, x5, x3
```

| Case | G | Instructions | Fillers after each | Behavior |
|:---|:---|:---|:---|:---|
| `ALU_to_ALU_delta_0` | G0 → G1 | `add x5, x1, x2 -> add x6, x5, x3` | 0 | `overlay`; slot0 producer ALU claims G0 first and slot1 dependent ALU routes to G1 in the post-slot0 view. |
| `ALU_to_ALU_delta_1` | G0 → G0 | `sub x5, x3, x4 -> add x6, x5, x7` | 1 | `wait_for_p3` |
| `ALU_to_ALU_delta_2` | G0 → G0 | `add x5, x1, x2 -> add x6, x5, x3` | 3 | `p3_capture` |
| `ALU_to_ALU_delta_3` | G0 → G0 | `add x5, x1, x2 -> add x6, x5, x3` | 5 | `p4_capture` |
| `ALU_to_ALU_delta_4` | G0 → G0 | `add x5, x1, x2 -> add x6, x5, x3` | 7 | `arf_read` |

## MUL_to_ALU

Representative:

```asm
mul x5, x1, x2
add x6, x5, x3
```

| Case | G | Instructions | Fillers after each | Behavior |
|:---|:---|:---|:---|:---|
| `MUL_to_ALU_delta_0` | G1 → G0 | `mul x5, x1, x2 -> add x6, x5, x3` | `0 exit-first` | `overlay`; producer MUL targets G1 and dependent ALU can route to G0. |
| `MUL_to_ALU_delta_1` | G1 → G0 | `mul x5, x3, x4 -> add x7, x5, x8` | 1 | `wait_for_p3` |
| `MUL_to_ALU_delta_2` | G1 → G0 | `mul x5, x1, x2 -> add x6, x5, x3` | `1ld+2fp` | `wait_for_p3` |
| `MUL_to_ALU_delta_3` | G1 → G0 | `mul x5, x1, x2 -> add x6, x5, x3` | `0ld+3fp` | `wait_for_p3` |
| `MUL_to_ALU_delta_4` | G1 → G0 | `mul x5, x1, x2 -> add x6, x5, x3` | `1ld+3fp` | `p3_capture` |
| `MUL_to_ALU_delta_5` | G1 → G0 | `mul x5, x1, x2 -> add x6, x5, x3` | `0ld+4fp` | `p4_capture` |
| `MUL_to_ALU_delta_6` | G1 → G0 | `mul x5, x1, x2 -> add x6, x5, x3` | `1ld+4fp` | `arf_read` |

## DIV_to_ALU

Representative:

```asm
div x5, x1, x2
add x6, x5, x3
```

| Case | G | Instructions | Fillers after each | Behavior |
|:---|:---|:---|:---|:---|
| `DIV_to_ALU_delta_0` | G0 → G1 | `div x5, x1, x2 -> add x6, x5, x3` | `0 exit-first` | `overlay`; producer DIV targets G0 and dependent ALU can route to G1. |
| `DIV_to_ALU_delta_1` | G0 → G0 | `div x5, x3, x4 -> add x7, x5, x8` | 1 | `wait_for_p3` |
| `DIV_to_ALU_delta_2` | G0 → G0 | `div x5, x1, x2 -> add x6, x5, x3` | 3 | `wait_for_p3` |
| `DIV_to_ALU_delta_3` | G0 → G0 | `div x5, x1, x2 -> add x6, x5, x3` | 5 | `wait_for_p3` |
| `DIV_to_ALU_delta_4` | G0 → G0 | `div x5, x1, x2 -> add x6, x5, x3` | `1ld+3fp` | `wait_for_p3` |
| `DIV_to_ALU_delta_5` | G0 → G0 | `div x5, x1, x2 -> add x6, x5, x3` | `0ld+4fp` | `p3_capture` |
| `DIV_to_ALU_delta_6` | G0 → G0 | `div x5, x1, x2 -> add x6, x5, x3` | `1ld+4fp` | `p4_capture` |
| `DIV_to_ALU_delta_7` | G0 → G0 | `div x5, x1, x2 -> add x6, x5, x3` | `2ld+4fp` | `arf_read` |

## LOAD_to_ALU

Representative:

```asm
ld x5, 0(x1)
add x6, x5, x3
```

Direct D-cache hit, no ISB / WB merging (the only path this caselist enumerates).

| Case | G | Instructions | Fillers after each | Behavior |
|:---|:---|:---|:---|:---|
| `LOAD_to_ALU_delta_0` | G3 → G0 | `ld x5, 0(x1) -> add x6, x5, x3` | 0 | `overlay`; producer LOAD targets G3 and dependent ALU can route to G0/G1. |
| `LOAD_to_ALU_delta_1` | G3 → G0 | `lw x5, 8(x2) -> add x7, x5, x8` | 1 | `wait_for_p3` |
| `LOAD_to_ALU_delta_2` | G3 → G0 | `ld x5, 0(x1) -> add x6, x5, x3` | 3 | `wait_for_p3` |
| `LOAD_to_ALU_delta_3` | G3 → G0 | `ld x5, 0(x1) -> add x6, x5, x3` | 5 | `wait_for_p3` |
| `LOAD_to_ALU_delta_4` | G3 → G0 | `ld x5, 0(x1) -> add x6, x5, x3` | 7 | `p3_capture` |
| `LOAD_to_ALU_delta_5` | G3 → G0 | `ld x5, 0(x1) -> add x6, x5, x3` | 9 | `p4_capture` |
| `LOAD_to_ALU_delta_6` | G3 → G0 | `ld x5, 0(x1) -> add x6, x5, x3` | 11 | `arf_read` |

## MUL_to_JALR

Representative:

```asm
mul  x10, x11, x1
jalr x5, 0(x10)
```

The producer multiplies the target address by one, so the jump target is always the label the
program intends and the producer is still multi-cycle. The jump lands on the instruction
immediately after the `jalr`, so the fillers in the window are not skipped. `L = 3` is the
producer's latency; the JALR's own redirect is a control-flow event and is not enumerated.

| Case | G | Instructions | Fillers after each | Behavior |
|:---|:---|:---|:---|:---|
| `MUL_to_JALR_delta_0` | G1 -> G0 | `mul x10, x11, x1; jalr x5, 0(x10)` | `0ld+0fp` | `overlay` |
| `MUL_to_JALR_delta_1` | G1 -> G0 | `mul x10, x11, x1; jalr x5, 0(x10)` | `0ld+1fp` | `wait_for_p3` |
| `MUL_to_JALR_delta_2` | G1 -> G0 | `mul x10, x11, x1; jalr x5, 0(x10)` | `1ld+2fp` | `wait_for_p3` |
| `MUL_to_JALR_delta_3` | G1 -> G0 | `mul x10, x11, x1; jalr x5, 0(x10)` | `0ld+3fp` | `wait_for_p3` |
| `MUL_to_JALR_delta_4` | G1 -> G0 | `mul x10, x11, x1; jalr x5, 0(x10)` | `1ld+3fp` | `p3_capture` |
| `MUL_to_JALR_delta_5` | G1 -> G0 | `mul x10, x11, x1; jalr x5, 0(x10)` | `0ld+4fp` | `p4_capture` |
| `MUL_to_JALR_delta_6` | G1 -> G0 | `mul x10, x11, x1; jalr x5, 0(x10)` | `1ld+4fp` | `arf_read` |

## Notes

- This file intentionally no longer contains `*_to_MUL`, `*_to_DIV`, `*_to_BRU`, `*_to_LOAD`, or `*_to_STORE` dependent expansions.
- `*_to_MUL`, `*_to_DIV`, and `*_to_BRU` are covered by the same producer latency representative cases above.
- `*_to_LOAD` and `*_to_STORE` dependent cases are MEM/LSU operand cases and should be enumerated in a MEM K-map/caselist.
- Store instructions have no architectural destination register and remain producer `don't exist` for ordinary register-result dependency K-maps.
- CSR producer timing is covered by CSR serialization rather than ordinary live bypass timing.
- Producer latencies above are **measured** values for the current RTL (see the revision note); `L` is the issue-accepted-to-result-visible cycle difference. `L` is parameterised, so a change in `L` changes the enumerated range and the case count.

## Filler notation and the two conventions

`Fillers after each` counts the fillers in each gap, in program order, and the entry is a
**measured recipe**, not a value computed from `2g - 1`. Two notations appear:

- A plain number means the independent single-cycle ALU filler, `addi xN, x0, 1`, and for those
  rows the `2g - 1` count does hold. ALU, LOAD, `MUL_to_ALU_delta_1` and `DIV_to_ALU_delta_1..3`
  are in this group; they were measured clean.
- `Nld+Mfp` means `N` load fillers plus `M` `fadd.s` fillers. It is used where the producer is
  pinned to `G0` or `G1`: the load uses `G3` and the `fadd.s` uses `G2`, so neither can steal the
  producer's writeback lane. The count had to be measured because those two fillers do not advance
  the stream one cycle each. These rows also need `la x12, scratch` for the load address and the FS
  enable (`li x7, 0x6000`, `csrs mstatus, x7`) for the `fadd.s`.
- `0 exit-first` means no filler, plus the exit bookkeeping moved ahead of the producer. At
  `delta = 0` the exit sequence would otherwise dispatch inside the producer's writeback window
  and steal its lane.
- The two-operand caselist additionally uses `branch` (never-taken branches) and `chained`
  (dependent `addi` chain) notations; see its own note.

Every row whose entry is not a plain number is frozen under `../calibrated_cases/` and installed
into the run set by `../install_calibrated.py`. `gen_cases.py` cannot render those notations, so it
skips such rows and points at the frozen file instead of emitting a wrong program.
