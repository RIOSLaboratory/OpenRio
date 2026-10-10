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
ALU  5 cases  + MUL 7 cases + DIV 8 cases + LOAD 7 cases + JALR 5 cases = 32 cases
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
> | JALR link | 3 | **1** | 7 → **5** cases |
>
> The rule `P3 delta = latency + 1` is unchanged.
>
> **JALR now uses the link-value latency.** `JALR` with `rd != x0` writes `rd = PC + 4`; that
> register result is visible 1 cycle after issue, so the dependency formula uses `L = 1`. The
> figure of "about 3 cycles" in the performance report is the **taken / redirect** metric
> (measured 2 on this RTL). It is a control-flow event with no "rd value reaching the consumer",
> so it is **not** part of this dependency enumeration.
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
| JALR link | **1** | **2** | **3** | **4** | **0..4** |

JAL/JALR note:

`JAL` and `JALR` with `rd != x0` produce an INT register-result link value (`rd = PC + 4`). This
caselist uses `JALR` as the representative **link-result producer** family, so it takes the
**link-value** latency: measured **1** cycle, enumerated deltas `0..4`. The performance report's
"about 3 cycles" for taken `JAL`/`JALR` is the **redirect-ready** metric (measured 2 here); it is a
control-flow event and is not enumerated as a dependency delta.

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
  `x12`-`x19` and `x21`-`x31`. Those registers appear in no case, every filler writes
  a different one, and no filler reads anything a case writes, so the fillers are
  independent of the case and of each other. No filler touches memory.
- **Why an integer ALU operation**: the dispatcher can send it to either `G0` or `G1`,
  so a filler sharing a cycle with a case instruction that is pinned to one group can
  always be placed in the other, and never displaces the case.
- **Count**: `Fillers` lists, in program order, how many fillers follow each case
  instruction, so the last entry always follows the last producer.

Worked example: `ALU_to_ALU_delta_3` has `Fillers` = `5`, so the program is
`add x5, x1, x2`, 5 fillers, `add x6, x5, x3`. The producer dispatches at cycle 0 and
the dependent at cycle 3, which is the `delta` its name states.

**Assumption to confirm by simulation**: a straight-line program of this shape
sustains two dispatches per cycle. Where a filler and a case instruction would land in
one cycle, the case instruction is earlier in program order and the dispatcher places
the filler in the other group.

## ALU_to_ALU

Representative:

```asm
add x5, x1, x2
add x6, x5, x3
```

| Case | G | Instructions | Fillers | Behavior |
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

| Case | G | Instructions | Fillers | Behavior |
|:---|:---|:---|:---|:---|
| `MUL_to_ALU_delta_0` | G1 → G0 | `mul x5, x1, x2 -> add x6, x5, x3` | 0 | `overlay`; producer MUL targets G1 and dependent ALU can route to G0. |
| `MUL_to_ALU_delta_1` | G1 → G0 | `mul x5, x3, x4 -> add x7, x5, x8` | 1 | `wait_for_p3` |
| `MUL_to_ALU_delta_2` | G1 → G0 | `mul x5, x1, x2 -> add x6, x5, x3` | 3 | `wait_for_p3` |
| `MUL_to_ALU_delta_3` | G1 → G0 | `mul x5, x1, x2 -> add x6, x5, x3` | 5 | `wait_for_p3` |
| `MUL_to_ALU_delta_4` | G1 → G0 | `mul x5, x1, x2 -> add x6, x5, x3` | 7 | `p3_capture` |
| `MUL_to_ALU_delta_5` | G1 → G0 | `mul x5, x1, x2 -> add x6, x5, x3` | 9 | `p4_capture` |
| `MUL_to_ALU_delta_6` | G1 → G0 | `mul x5, x1, x2 -> add x6, x5, x3` | 11 | `arf_read` |

## DIV_to_ALU

Representative:

```asm
div x5, x1, x2
add x6, x5, x3
```

| Case | G | Instructions | Fillers | Behavior |
|:---|:---|:---|:---|:---|
| `DIV_to_ALU_delta_0` | G0 → G1 | `div x5, x1, x2 -> add x6, x5, x3` | 0 | `overlay`; producer DIV targets G0 and dependent ALU can route to G1. |
| `DIV_to_ALU_delta_1` | G0 → G0 | `div x5, x3, x4 -> add x7, x5, x8` | 1 | `wait_for_p3` |
| `DIV_to_ALU_delta_2` | G0 → G0 | `div x5, x1, x2 -> add x6, x5, x3` | 3 | `wait_for_p3` |
| `DIV_to_ALU_delta_3` | G0 → G0 | `div x5, x1, x2 -> add x6, x5, x3` | 5 | `wait_for_p3` |
| `DIV_to_ALU_delta_4` | G0 → G0 | `div x5, x1, x2 -> add x6, x5, x3` | 7 | `wait_for_p3` |
| `DIV_to_ALU_delta_5` | G0 → G0 | `div x5, x1, x2 -> add x6, x5, x3` | 9 | `p3_capture` |
| `DIV_to_ALU_delta_6` | G0 → G0 | `div x5, x1, x2 -> add x6, x5, x3` | 11 | `p4_capture` |
| `DIV_to_ALU_delta_7` | G0 → G0 | `div x5, x1, x2 -> add x6, x5, x3` | 13 | `arf_read` |

## LOAD_to_ALU

Representative:

```asm
ld x5, 0(x1)
add x6, x5, x3
```

Direct D-cache hit, no ISB / WB merging (the only path this caselist enumerates).

| Case | G | Instructions | Fillers | Behavior |
|:---|:---|:---|:---|:---|
| `LOAD_to_ALU_delta_0` | G3 → G0 | `ld x5, 0(x1) -> add x6, x5, x3` | 0 | `overlay`; producer LOAD targets G3 and dependent ALU can route to G0/G1. |
| `LOAD_to_ALU_delta_1` | G3 → G0 | `lw x5, 8(x2) -> add x7, x5, x8` | 1 | `wait_for_p3` |
| `LOAD_to_ALU_delta_2` | G3 → G0 | `ld x5, 0(x1) -> add x6, x5, x3` | 3 | `wait_for_p3` |
| `LOAD_to_ALU_delta_3` | G3 → G0 | `ld x5, 0(x1) -> add x6, x5, x3` | 5 | `wait_for_p3` |
| `LOAD_to_ALU_delta_4` | G3 → G0 | `ld x5, 0(x1) -> add x6, x5, x3` | 7 | `p3_capture` |
| `LOAD_to_ALU_delta_5` | G3 → G0 | `ld x5, 0(x1) -> add x6, x5, x3` | 9 | `p4_capture` |
| `LOAD_to_ALU_delta_6` | G3 → G0 | `ld x5, 0(x1) -> add x6, x5, x3` | 11 | `arf_read` |

## JALR_to_ALU

Representative:

```asm
jalr x5, 0(x10)
add  x6, x5, x3
```

`x10` is assumed to hold a valid jump target. For `delta_0`, arrange the target so the slot1 dependent is on the architecturally correct path, or treat the row as the data-forwarding representative for the JAL/JALR link-result family. Conditional no-link branches remain producer `don't exist`.

`L = 1` here is the **link-value** latency. JALR also has a redirect-ready latency (measured 2), which is a control-flow metric and is not enumerated in this caselist.

| Case | G | Instructions | Fillers | Behavior |
|:---|:---|:---|:---|:---|
| `JALR_to_ALU_delta_0` | G0 → G1 | `jalr x5, 0(x10) -> add x6, x5, x3` | 0 | `overlay`; producer JALR targets G0 and dependent ALU can route to G1. |
| `JALR_to_ALU_delta_1` | G0 → G0 | `jalr x5, 0(x10) -> add x7, x5, x8` | 1 | `wait_for_p3` |
| `JALR_to_ALU_delta_2` | G0 → G0 | `jalr x5, 0(x10) -> add x6, x5, x3` | 3 | `p3_capture` |
| `JALR_to_ALU_delta_3` | G0 → G0 | `jalr x5, 0(x10) -> add x6, x5, x3` | 5 | `p4_capture` |
| `JALR_to_ALU_delta_4` | G0 → G0 | `jalr x5, 0(x10) -> add x6, x5, x3` | 7 | `arf_read` |

## Notes

- This file intentionally no longer contains `*_to_MUL`, `*_to_DIV`, `*_to_BRU`, `*_to_LOAD`, or `*_to_STORE` dependent expansions.
- `*_to_MUL`, `*_to_DIV`, and `*_to_BRU` are covered by the same producer latency representative cases above.
- `*_to_LOAD` and `*_to_STORE` dependent cases are MEM/LSU operand cases and should be enumerated in a MEM K-map/caselist.
- Store instructions have no architectural destination register and remain producer `don't exist` for ordinary register-result dependency K-maps.
- CSR producer timing is covered by CSR serialization rather than ordinary live bypass timing.
- Producer latencies above are **measured** values for the current RTL (see the revision note); `L` is the issue-accepted-to-result-visible cycle difference. `L` is parameterised, so a change in `L` changes the enumerated range and the case count.
