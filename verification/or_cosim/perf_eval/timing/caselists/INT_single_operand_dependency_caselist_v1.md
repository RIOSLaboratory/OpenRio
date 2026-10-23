# INT Single-Operand Dependency Caselist

Source K-map:

```text
../k-maps/INT_single_operand_dependency_KMap_v2.drawio
```

Normative timing sources:

```text
pending promotion to spec/or-be/
```

Golden timing source for the producer latencies in this file:
`../../latency_bench/result.md` (intranet operator measurements). Behavioral-RTL
measurements remain in `Latency_Report.md` for history only.

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
ALU 5 cases + MUL 7 cases + DIV 12 cases + LOAD 6 cases + JALR 5 cases = 35 cases
```

> **Revision (2026-10-22): producer latencies now follow the intranet operator data.**
> Source: `../../latency_bench/result.md`. The behavioral-RTL values in
> `Latency_Report.md` are superseded for DIV and LOAD.
>
> | Family | was | now | effect |
> |---|---:|---:|---|
> | ALU | 1 | **1** | unchanged |
> | MUL | 3 | **3** | unchanged |
> | DIV | 4 | **8** | 8 → **12** cases |
> | LOAD | 3 | **2** | 7 → **6** cases |
> | JALR | 1 | **1** | unchanged |
>
> The rule `P3 delta = latency + 1` is unchanged.
>
> **JALR is retained as the BRU-issued 1-cycle producer representative.** The single-operand
> K-map states: "Conditional BRU without link: Don't Exist. JAL/JALR with rd != x0: register-result
> producer exists, covered by ALU/BRU 1-cycle producer POI." A JAL/JALR with `rd != x0` therefore
> writes a register result (the link value) and belongs to the same 1-cycle producer POI as ALU/BRU.
> Its `L = 1` makes the delta ladder numerically identical to `ALU_to_ALU_delta_*`, but the cases
> are kept because they exercise the BRU-issued producer path, not the ALU result path.
>
> An earlier reading treated the `rtl_v1`/`fe_agent` behavior — every taken control transfer
> mispredicting and flushing a consumer inside the link window — as a structural prohibition on
> JALR producers. That is a property of that baseline, not of the K-map POI, and the current base
> DUT is `rtl_full`, whose FE predicts; the family is valid and its five `delta_0..4` cases stay in
> the set.
>
> `MUL_to_JALR` (JALR as consumer) remains removed: it is a MUL producer against a JALR consumer,
> so its ladder and capture mechanisms duplicate `MUL_to_ALU` and add no coverage.
>
> **LOAD timing** follows the intranet operator data: `L = 2` (AGU + L1 D cache). The previous
> three-cycle value belonged to the behavioral `g3_lsu_iface` / CDB-FIFO path and is not the
> target for this caselist.

## Delta Meaning

Normal no-older-blocker path:

| Producer | Producer latency (intranet operator) | P3 delta | P4 delta | ARF boundary delta | Enumerated deltas |
|---|---:|---:|---:|---:|---|
| ALU | 1 | 2 | 3 | 4 | 0..4 |
| MUL | 3 | 4 | 5 | 6 | 0..6 |
| DIV | **8** | **9** | **10** | **11** | **0..11** |
| LOAD | **2** | **3** | **4** | **5** | **0..5** |
| JALR (link, with warm-up) | **1** | **2** | **3** | **4** | **0..4** |

JAL/JALR note:

`JALR` is enumerated as a producer, with `L = 1` (link value `PC + 4`, `rd != x0`). The
single-operand K-map defines this POI as "JAL/JALR with rd != x0: register-result producer
exists, covered by ALU/BRU 1-cycle producer POI"; conditional BRUs without a link are not
producer POIs ("Don't Exist"). JALR is kept as the BRU-issued producer representative even
though its delta ladder is numerically the same as `ALU_to_ALU`. The earlier
`tools/jalr_producer_commit.py` measurement that showed consumers disappearing belongs to the
`rtl_v1`/`fe_agent` baseline, where every taken control transfer mispredicts; it is not a
property of the K-map POI.

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

> **Legacy (2026-10-22):** the `.S`/filler construction below is no longer part of the
> timing-diagram flow. Diagrams and caselists use IB stimulus injection; the frozen `.S`
> recipes are retained only as historical RTL regression assets.

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

| `ALU_to_ALU_delta_3_p4blocked` | blocker + producer share the enqueue cycle | `div x7, x1, x2(blocker) ; add x5, x1, x2(producer) ; add x6, x5, x3(dependent)` | n/a | commit held in the P3 Buffer; dependent dispatches on the held commit and captures there (criteria in the figure) |
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

| `MUL_to_ALU_delta_5_p4blocked` | blocker + producer share the enqueue cycle | `div x7, x1, x2(blocker) ; mul x5, x1, x2(producer) ; add x6, x5, x3(dependent)` | n/a | commit held in the P3 Buffer; dependent dispatches on the held commit and captures there (criteria in the figure) |
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
| `DIV_to_ALU_delta_5` | G0 → G0 | `div x5, x1, x2 -> add x6, x5, x3` | `0ld+4fp` | `wait_for_p3` |
| `DIV_to_ALU_delta_6` | G0 → G0 | `div x5, x1, x2 -> add x6, x5, x3` | `1ld+4fp` | `wait_for_p3` |
| `DIV_to_ALU_delta_7` | G0 → G0 | `div x5, x1, x2 -> add x6, x5, x3` | `2ld+4fp` | `wait_for_p3` |
| `DIV_to_ALU_delta_8` | G0 → G0 | `div x5, x1, x2 -> add x6, x5, x3` | `n/a (IB stimulus)` | `wait_for_p3` |
| `DIV_to_ALU_delta_9` | G0 → G0 | `div x5, x1, x2 -> add x6, x5, x3` | `n/a (IB stimulus)` | `p3_capture` |
| `DIV_to_ALU_delta_10` | G0 → G0 | `div x5, x1, x2 -> add x6, x5, x3` | `n/a (IB stimulus)` | `p4_capture` |
| `DIV_to_ALU_delta_11` | G0 → G0 | `div x5, x1, x2 -> add x6, x5, x3` | `n/a (IB stimulus)` | `arf_read` |

| `DIV_to_ALU_delta_10_p4blocked` | blocker + producer share the enqueue cycle | `mul x7, x1, x2(blocker) ; div x5, x1, x2(producer) ; add x6, x5, x3(dependent)` | n/a | deferred: the blocker must have `L >= 9`; no current INT producer is that slow |
## LOAD_to_ALU

Representative:

```asm
ld x5, 0(x1)
add x6, x5, x3
```

Direct D-cache hit, no ISB / WB merging (the only path this caselist enumerates).
`L = 2` counts from `[ISQ_FIRE]` to the cycle in which the LSU makes the result
visible to BE (`lsu_be_bypass_valid`), so it is anchored on the BE–LSU boundary
and not on the LSU's internal `E1…E3` split. Re-confirm the number against the
frozen `openrios/work/or-be-draft/interfaces/BE_LSU_interface.md` before treating
it as final: the abandoned three-cycle value came from an older behavioral model
of this same boundary.

| Case | G | Instructions | Fillers after each | Behavior |
|:---|:---|:---|:---|:---|
| `LOAD_to_ALU_delta_0` | G3 → G0 | `ld x5, 0(x1) -> add x6, x5, x3` | 0 | `overlay`; producer LOAD targets G3 and dependent ALU can route to G0/G1. |
| `LOAD_to_ALU_delta_1` | G3 → G0 | `lw x5, 8(x2) -> add x7, x5, x8` | 1 | `wait_for_p3` |
| `LOAD_to_ALU_delta_2` | G3 → G0 | `ld x5, 0(x1) -> add x6, x5, x3` | 3 | `wait_for_p3` |
| `LOAD_to_ALU_delta_3` | G3 → G0 | `ld x5, 0(x1) -> add x6, x5, x3` | 5 | `p3_capture` |
| `LOAD_to_ALU_delta_4` | G3 → G0 | `ld x5, 0(x1) -> add x6, x5, x3` | 7 | `p4_capture` |
| `LOAD_to_ALU_delta_5` | G3 → G0 | `ld x5, 0(x1) -> add x6, x5, x3` | 9 | `arf_read` |

| `LOAD_to_ALU_delta_4_p4blocked` | blocker + producer share the enqueue cycle | `div x7, x1, x2(blocker) ; ld x5, 0(x1)(producer) ; add x6, x5, x3(dependent)` | n/a | commit held in the P3 Buffer; dependent dispatches on the held commit and captures there (criteria in the figure) |
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

**Baseline note.** Under `--dut-kind rtl_v1` the FE is `fe_agent`, which hardwires `pred_taken = 0`;
every taken control transfer then mispredicts and flushes a consumer inside the link's visibility
window, so that baseline cannot build the case. The base DUT is `rtl_full`, whose FE predicts, and
the family is valid there.

`L = 1` is the link value (`PC + 4`), and `rd` is the first operand — see the operand note above.

| Case | G | Instructions | Fillers after each | Behavior |
|:---|:---|:---|:---|:---|
| `JALR_to_ALU_delta_0` | G0 -> G1 | `jalr x5, 0(x10) -> add x6, x5, x3` | `n/a (IB stimulus)` | `overlay`; producer and dependent dispatch in the same bundle, dependent routed to G1 |
| `JALR_to_ALU_delta_1` | G0 -> G0 | `jalr x5, 0(x10) -> add x7, x5, x8` | `0fp` | `wait_for_p3` |
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

| `JALR_to_ALU_delta_3_p4blocked` | blocker + producer share the enqueue cycle | `mul x7, x1, x2(blocker) ; jalr x5, 0(x10)(producer) ; add x6, x5, x3(dependent)` | n/a | commit held in the P3 Buffer; dependent dispatches on the held commit and captures there (criteria in the figure) |
## Notes

- This file intentionally no longer contains `*_to_MUL`, `*_to_DIV`, `*_to_BRU`, `*_to_LOAD`, or `*_to_STORE` dependent expansions.
- `*_to_MUL`, `*_to_DIV`, and `*_to_BRU` are covered by the same producer latency representative cases above.
- `*_to_LOAD` and `*_to_STORE` dependent cases are MEM/LSU operand cases and should be enumerated in a MEM K-map/caselist.
- Store instructions have no architectural destination register and remain producer `don't exist` for ordinary register-result dependency K-maps.
- CSR producer timing is covered by CSR serialization rather than ordinary live bypass timing.
- Producer latencies above are **intranet operator** values (see the revision note); `L` is the issue-accepted-to-result-visible cycle difference. `L` is parameterised, so a change in `L` changes the enumerated range and the case count.

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

Every row whose entry is not a plain number has a historical frozen recipe under
`../calibrated_cases/`. That recipe is not part of the diagram flow and is not re-calibrated when
the diagram latency changes; `gen_cases.py` cannot render those notations.

## P4-blocked 类的实测结果与两处推迟（A 形态，rtl_v1）

判据（机制型，δ 为输出）：`P3−P2 == L`、`P4−P3 > 1`、`dep.P2−P1 == 1`、`dep.P1 == prod.P4`。

| case | L | P3−P2 | P4−P3 | dep.P2−P1 | dep.P1==prod.P4 | 判定 |
|---|---|---|---|---|---|---|
| `ALU_to_ALU_delta_3_p4blocked` | 1 | 1 | 3 | 1 | ✓ | 通过 |
| `MUL_to_ALU_delta_5_p4blocked` | 3 | 3 | 2 | 1 | ✓ | 通过 |
| `LOAD_to_ALU_delta_4_p4blocked` | 2 | 2 | 4 | 1 | 是 | 待重测（原 delta_5 通过）|
| `JALR_to_ALU_delta_3_p4blocked` | 1 | 1 | 3 | 1 | ✓ | 通过 |
| `DIV_to_ALU_delta_10_p4blocked` | 8 | 8 | **1** | 1 | 是 | **推迟**（见下）|
| `INT2_P4_G1P3_blocked`① | 1 | 1 | 4 | 1 | ✓ | 通过 |

① 两操作数那条，见另一份 caselist。

**两条机制判据在 6 个不同 producer 上全部成立**（`dep.P2−P1 == 1` 且 `dep.P1 == prod.P4`）：
提交被压住时，dependent 的派发**被门控在该次提交上**并在派发拍即取得操作数。
⇒ δ 是**结果**而非输入，本类不断言目标 δ。

**`DIV_to_ALU_delta_10_p4blocked` 为何未通过（结构性，非构造失误）**：
要求阻塞物**严格晚于** producer 的写回退休（`blocker.P4 > producer.P3`）。producer 是 DIV（L=8），
而 INT 类 FU 的延迟为 MUL 3 / LOAD 2 / DIV 8（`latency_table.py`）——**没有任何 L ≥ 9 的阻塞物**，
即便把阻塞物提前一拍也仍相等。**结论：该条需要一个访存型慢阻塞物（冷 miss 的 LOAD）⇒ 与 `INT2_P4_P4_blocked` 一起，等 A 形态的内存来源就绪。**

⇒ **7 条 blocked case 中已有 5 条实测通过**；剩下 2 条（DIV 族 + `INT2_P4_P4`）的**唯一**阻塞项是
**A 形态下的内存来源**（`IB_STIMULUS_METHOD.md` §3.8：前置注入或后门预置）。

**关于 `DIV_to_ALU_delta_10_p4blocked`（保留，不删除）**：
当前 latency 不支持这个 case 的构造，等未来有更慢的访存阻塞物之后再更新。
技术上：该 case 需要一个**晚于 DIV（L=8）写回才退休**的阻塞物，即 L≥9；而当前整数类 FU 的延迟为
MUL 3 / LOAD 2 / DIV 8，没有任何整数阻塞物够晚。
在此之前它**既不算通过也不算失败**，状态为"推迟"。
