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
ALU 5 cases + MUL 7 cases + DIV 8 cases + LOAD 7 cases + JALR 5 cases = 32 cases
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
> | JALR | 3 | **1** | 7 → **5** cases; enumerated with a same-PC warm-up prerequisite |
>
> The rule `P3 delta = latency + 1` is unchanged.
>
> **A JALR cannot act as a producer, and the reason is structural.** `p4/flush_model.sv` states
> that the retire decision belongs to the CompletionScoreboard, and that this module only
> translates an already-decided flush into a recovery target and broadcasts it: the JALR's control
> decision takes effect **at retire**, via `global_flush_late`. That net gates the dispatch and
> execution paths — `p1/FP_tag_mapping.sv` documents that a flush suppresses the alloc and returns
> the tag table to IDLE, and every ISQ group computes `issue_valid = issue_req &&
> !global_flush_late` and `bypass_capture = isq_valid && !global_flush_late && !issue_fire`, with
> `g3_lsu_iface` gated the same way. So a consumer dispatched inside the link's visibility window
> must be dispatched **before the JALR retires**, and everything fetched that early is speculation:
> the flush **cancels** that dispatch rather than delaying it. Being inside the window and
> surviving it are mutually exclusive by construction.
>
> Measured consequence: attempts at `delta` 1, 2 and 3 do appear in the log but never commit, and
> the first dispatch that survives is **six cycles** after the JALR's dispatch (`tools/jalr_producer_commit.py`).
> The JALR's ladder is `0..4`, so no row is reachable, and every attainable delta is at least six,
> which is `arf_read` for all of them.
>
> **The link value does reach the bypass bus; it is the consumers that disappear.** The JALR's own
> events show `[P3_BYPASS] lane=0` and an `[FU_WB]` carrying `PC+4` at issue+1, one cycle **before**
> the `[BE][REDIRECT]` that fires in the same cycle as its `[BE][COMMIT]`. There is therefore exactly
> one cycle in which the link is on the bus and the flush has not yet happened, and a consumer
> dispatched in that cycle (delta 3 for this family) does resolve against the bypass — after which
> the flush resets the entry that captured it. The dependency is not absent, it is unobservable
> through the bypass: a consumer that survives the flush dispatches at delta 6 or later, by which
> time the link has retired and is read from the ARF. That is why the family duplicates the
> `arf_read` rung that every other family already covers.
>
> A MUL consumer behaves identically, because the flush sits
> upstream of group assignment. `MUL_to_JALR` was enumerated for a while under an earlier
> reading; it is a MUL producer against a JALR consumer, so its ladder and its four capture
> mechanisms are those of `MUL_to_ALU` and it added no coverage. It is removed.
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
| JALR (link, with warm-up) | **1** | **2** | **3** | **4** | **0..4** |

JAL/JALR note:

`JALR` is **not enumerated** as a producer, and the reason is structural rather than a matter
of scheduling. `p4/flush_model.sv` states that the retire decision belongs to the
CompletionScoreboard, so the JALR's control decision takes effect at retire through
`global_flush_late`, which gates the tag-mapping alloc and every ISQ group's `issue_valid`
and `bypass_capture`, and the LSU interface with them. A consumer dispatched inside the link
value's visibility window therefore has to be dispatched **before the JALR retires**, and
everything fetched that early is speculation that the flush **cancels**. Being inside the
window and surviving it are mutually exclusive. Measured, attempts at `delta` 1, 2 and 3 never
commit and the first dispatch that survives is six cycles out, against a ladder of `0..4`; the
JALR's own two metrics (`link` value 1, `redirect` ready 2) are unaffected and remain in the
latency report. Reproduce with `tools/jalr_producer_commit.py`.

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

## JALR_to_ALU

Representative (the warm-up is part of the case):

```asm
    la   x11, JT
    li   x12, 2
LOOP:
    mv   x10, x11
    jalr x5, 0(x10)
JT:
    addi x12, x12, -1
    bne  x12, x0, LOOP
    add  x6, x5, x3
```

**Precondition: the same-PC JALR must already have executed once.** A JALR is always taken, so
`fu/alu_simple.sv`'s mispredict expression reduces to "the FE must have predicted taken to the
exact target", and the FE's `l1btb.sv`, the only branch predictor, is indexed by PC — so only a
previous execution of the *same* JALR populates the entry. Measured on `rtl_full`: the first
execution reports `mispredict=1` and redirects, the second reports `mispredict=0` with no redirect,
and the link value then travels the bypass normally. The case therefore loops the JALR once and
measures the second execution.

**Why an earlier baseline could not build this.** Under `--dut-kind rtl_v1` the FE is `fe_agent`,
which hardwires `pred_taken = 0`; every taken control transfer then mispredicts, flushes, and
cancels any consumer inside the link's visibility window, which is why the family was withdrawn.
The base DUT is now `rtl_full`, whose FE does predict, so the family is restored.

`L = 1` is the link value (`PC + 4`), and `rd` is the first operand — see the operand note above.

| Case | G | Instructions | Fillers after each | Behavior |
|:---|:---|:---|:---|:---|
| `JALR_to_ALU_delta_0` | — | — | — | **not yet constructed**; delta 0 needs same-cycle dual dispatch, which the injection method makes first-class |
| `JALR_to_ALU_delta_1` | G0 -> G0 | `jalr x5, 0(x10); add x6, x5, x3` | `0fp` | `wait_for_p3` |
| `JALR_to_ALU_delta_2` | G0 -> G0 | `jalr x5, 0(x10); add x6, x5, x3` | `2fp` | `p3_capture` |
| `JALR_to_ALU_delta_3` | G0 -> G0 | `jalr x5, 0(x10); add x6, x5, x3` | `3ld` | `p4_capture` |
| `JALR_to_ALU_delta_4` | G0 -> G0 | `jalr x5, 0(x10); add x6, x5, x3` | `3fp` | `arf_read` |

Counts are measured recipes, not the `2g - 1` value: `Nfp` is `N` `fadd.s` on lane 2 and `Nld` is
`N` loads on lane 3, both of which keep off the JALR's own lane 0. Neither reaches every delta on
its own, so the recipes mix them: `fp` covers 1, 2 and 4, `ld` covers 1, 3 and 4.

**Why this family is kept although its producer latency equals the ALU's.** The JALR is not here to
add a new dependency mechanism — with a correct prediction it is an ordinary one-cycle producer on
G0/lane 0, and its ladder and capture mechanisms are the ALU's. It is kept for **execution-resource
coverage**: `top/backend_top.sv:1215` instantiates `u_alu0_bru`, i.e. the BRU shares ALU0's FU
("G0 : ALU0/BRU, CSR, DIV"), so the BRU is a resource whose timing must be observed with a BRU
instruction. Ruling from the case-set owner, recorded rather than re-derived.

**Prerequisite for the producer to be usable at all**: `fu/alu_simple.sv` makes a JALR mispredict
unless `pred_taken = 1` **and** `pred_target_pc` equals `(rs1 + imm) & ~1` bit for bit. Under
`fe_agent` predictions are hardwired to zero, so every JALR flushed; the injection method supplies
the two fields as stimulus, which makes the precondition constructible instead of something to be
lucky with.

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
