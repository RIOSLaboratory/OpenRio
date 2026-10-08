# INT Single-Operand Dependency Caselist

Source K-map:

```text
../k-maps/INT_single_operand_dependency_KMap_v2.drawio
```

Normative timing sources:

```text
pending promotion to spec/or-be/
```

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
ALU  5 cases  + MUL 7 cases + DIV 12 cases + LOAD 6 cases + JALR 7 cases = 37 cases
```

## Delta Meaning

Normal no-older-blocker path:

| Producer | Producer latency | P3 delta | P4 delta | ARF boundary delta | Enumerated deltas |
|---|---:|---:|---:|---:|---|
| ALU | 1 | 2 | 3 | 4 | 0..4 |
| MUL | 3 | 4 | 5 | 6 | 0..6 |
| DIV | 8 | 9 | 10 | 11 | 0..11 |
| LOAD | 2 | 3 | 4 | 5 | 0..5 |
| JALR link | 3 | 4 | 5 | 6 | 0..6 |

JAL/JALR note:

`JAL` and `JALR` with `rd != x0` produce an INT register-result link value (`rd = PC + 4`). The performance report measures taken `JAL` and `JALR` at about 3 cycles; this caselist uses `JALR` as the representative link-result producer family and enumerates deltas `0..6`.

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

## ALU_to_ALU

Representative:

```asm
add x5, x1, x2
add x6, x5, x3
```

| Case | Instructions | Behavior |
|---|---|---|
| `ALU_to_ALU_delta_0` | `add x5, x1, x2 -> add x6, x5, x3` | `overlay`; slot0 producer ALU claims G0 first and slot1 dependent ALU routes to G1 in the post-slot0 view. |
| `ALU_to_ALU_delta_1` | `sub x5, x3, x4 -> add x6, x5, x7` | `wait_for_p3` |
| `ALU_to_ALU_delta_2` | `add x5, x1, x2 -> add x6, x5, x3` | `p3_capture` |
| `ALU_to_ALU_delta_3` | `add x5, x1, x2 -> add x6, x5, x3` | `p4_capture` |
| `ALU_to_ALU_delta_4` | `add x5, x1, x2 -> add x6, x5, x3` | `arf_read` |

## MUL_to_ALU

Representative:

```asm
mul x5, x1, x2
add x6, x5, x3
```

| Case | Instructions | Behavior |
|---|---|---|
| `MUL_to_ALU_delta_0` | `mul x5, x1, x2 -> add x6, x5, x3` | `overlay`; producer MUL targets G1 and dependent ALU can route to G0. |
| `MUL_to_ALU_delta_1` | `mul x5, x3, x4 -> add x7, x5, x8` | `wait_for_p3` |
| `MUL_to_ALU_delta_2` | `mul x5, x1, x2 -> add x6, x5, x3` | `wait_for_p3` |
| `MUL_to_ALU_delta_3` | `mul x5, x1, x2 -> add x6, x5, x3` | `wait_for_p3` |
| `MUL_to_ALU_delta_4` | `mul x5, x1, x2 -> add x6, x5, x3` | `p3_capture` |
| `MUL_to_ALU_delta_5` | `mul x5, x1, x2 -> add x6, x5, x3` | `p4_capture` |
| `MUL_to_ALU_delta_6` | `mul x5, x1, x2 -> add x6, x5, x3` | `arf_read` |

## DIV_to_ALU

Representative:

```asm
div x5, x1, x2
add x6, x5, x3
```

| Case | Instructions | Behavior |
|---|---|---|
| `DIV_to_ALU_delta_0` | `div x5, x1, x2 -> add x6, x5, x3` | `overlay`; producer DIV targets G0 and dependent ALU can route to G1. |
| `DIV_to_ALU_delta_1` | `div x5, x3, x4 -> add x7, x5, x8` | `wait_for_p3` |
| `DIV_to_ALU_delta_2` | `div x5, x1, x2 -> add x6, x5, x3` | `wait_for_p3` |
| `DIV_to_ALU_delta_3` | `div x5, x1, x2 -> add x6, x5, x3` | `wait_for_p3` |
| `DIV_to_ALU_delta_4` | `div x5, x1, x2 -> add x6, x5, x3` | `wait_for_p3` |
| `DIV_to_ALU_delta_5` | `div x5, x1, x2 -> add x6, x5, x3` | `wait_for_p3` |
| `DIV_to_ALU_delta_6` | `div x5, x1, x2 -> add x6, x5, x3` | `wait_for_p3` |
| `DIV_to_ALU_delta_7` | `div x5, x1, x2 -> add x6, x5, x3` | `wait_for_p3` |
| `DIV_to_ALU_delta_8` | `div x5, x1, x2 -> add x6, x5, x3` | `wait_for_p3` |
| `DIV_to_ALU_delta_9` | `div x5, x1, x2 -> add x6, x5, x3` | `p3_capture` |
| `DIV_to_ALU_delta_10` | `div x5, x1, x2 -> add x6, x5, x3` | `p4_capture` |
| `DIV_to_ALU_delta_11` | `div x5, x1, x2 -> add x6, x5, x3` | `arf_read` |

## LOAD_to_ALU

Representative:

```asm
ld x5, 0(x1)
add x6, x5, x3
```

| Case | Instructions | Behavior |
|---|---|---|
| `LOAD_to_ALU_delta_0` | `ld x5, 0(x1) -> add x6, x5, x3` | `overlay`; producer LOAD targets G3 and dependent ALU can route to G0/G1. |
| `LOAD_to_ALU_delta_1` | `lw x5, 8(x2) -> add x7, x5, x8` | `wait_for_p3` |
| `LOAD_to_ALU_delta_2` | `ld x5, 0(x1) -> add x6, x5, x3` | `wait_for_p3` |
| `LOAD_to_ALU_delta_3` | `ld x5, 0(x1) -> add x6, x5, x3` | `p3_capture` |
| `LOAD_to_ALU_delta_4` | `ld x5, 0(x1) -> add x6, x5, x3` | `p4_capture` |
| `LOAD_to_ALU_delta_5` | `ld x5, 0(x1) -> add x6, x5, x3` | `arf_read` |

## JALR_to_ALU

Representative:

```asm
jalr x5, 0(x10)
add  x6, x5, x3
```

`x10` is assumed to hold a valid jump target. For `delta_0`, arrange the target so the slot1 dependent is on the architecturally correct path, or treat the row as the data-forwarding representative for the JAL/JALR link-result family. Conditional no-link branches remain producer `don't exist`.

| Case | Instructions | Behavior |
|---|---|---|
| `JALR_to_ALU_delta_0` | `jalr x5, 0(x10) -> add x6, x5, x3` | `overlay`; producer JALR targets G0 and dependent ALU can route to G1. |
| `JALR_to_ALU_delta_1` | `jalr x5, 0(x10) -> add x7, x5, x8` | `wait_for_p3` |
| `JALR_to_ALU_delta_2` | `jalr x5, 0(x10) -> add x6, x5, x3` | `wait_for_p3` |
| `JALR_to_ALU_delta_3` | `jalr x5, 0(x10) -> add x6, x5, x3` | `wait_for_p3` |
| `JALR_to_ALU_delta_4` | `jalr x5, 0(x10) -> add x6, x5, x3` | `p3_capture` |
| `JALR_to_ALU_delta_5` | `jalr x5, 0(x10) -> add x6, x5, x3` | `p4_capture` |
| `JALR_to_ALU_delta_6` | `jalr x5, 0(x10) -> add x6, x5, x3` | `arf_read` |

## Notes

- This file intentionally no longer contains `*_to_MUL`, `*_to_DIV`, `*_to_BRU`, `*_to_LOAD`, or `*_to_STORE` dependent expansions.
- `*_to_MUL`, `*_to_DIV`, and `*_to_BRU` are covered by the same producer latency representative cases above.
- `*_to_LOAD` and `*_to_STORE` dependent cases are MEM/LSU operand cases and should be enumerated in a MEM K-map/caselist.
- Store instructions have no architectural destination register and remain producer `don't exist` for ordinary register-result dependency K-maps.
- CSR producer timing is covered by CSR serialization rather than ordinary live bypass timing.
