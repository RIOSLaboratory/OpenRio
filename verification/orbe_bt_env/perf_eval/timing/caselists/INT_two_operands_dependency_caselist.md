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

This caselist covers the source-ready composition of one dependent instruction with two operands. The P1 MUX cases cover operands captured while constructing a new ISQ payload. The P2 MUX cases cover an already-resident ISQ entry receiving current-cycle forwarding at FU-input time. It does not enumerate producer opcode latency variants inside the same POI; those are covered by `INT_single_operand_dependency_caselist.md`.

## Reading Rules

`Data source 1 ready` maps to the dependent instruction's first register source. `Data source 2 ready` maps to the dependent instruction's second register source. In the P1 MUX map, data source 2 may also be `IMM` for immediate-form instructions.

For P1 MUX cases, `Already in ARF` means the source producer committed before the dependent reaches P1 and the source is read from the integer ARF while the ISQ payload is built.

For P2 MUX cases, `Stored Ready in ISQ` replaces both `Already in ARF` and immediate-ready source shapes. It means the resident ISQ entry already has `rs_ready=1` and valid operand payload data; that value may have come from P1 ARF/P3/P4 capture, from an earlier resident-entry P3 forwarding latch, or from immediate decode payload construction. Current-cycle P2 forwarding sources are only `G0 P3 Bypass`, `G1 P3 Bypass`, and `G3 Load P3 Bypass`. P2 MUX never consumes `P4 Commit CDB`. If a P3 forwarding match occurs but the selected FU cannot issue that cycle, the matched data is latched at the clock edge and becomes `Stored Ready in ISQ` for a later cycle.

Current INT result timing boundaries:

| Producer | P3 delta | P4 delta | ARF boundary delta |
|---|---:|---:|---:|
| ALU/BRU result | 2 | 3 | 4 |
| MUL result | 4 | 5 | 6 |
| DIV/REM result | 9 | 10 | 11 |
| LOAD hit result | 3 | 4 | 5 |

For any mixed-source P3 case, issue the producers at different P1 cycles as needed so their P3 publications align in the same dependent source-resolution cycle. For example, a G1 MUL producer must be issued two cycles earlier than a G0 ALU producer if both results should appear at P3 in the same cycle.

The three same-bypass diagonal cells are excluded because they are gray `don't exist` cells in the K-map. Two different same-group producers cannot both publish on the same group P3 bypass lane in one cycle. A separate instruction shape where one producer feeds both operands, such as `add x20, x5, x5`, is legal, but it is not a two-source composition POI.

## Why IMM Is Kept in the P1 MUX Map

`IMM` is necessary because many real INT/MEM dependent instructions are not two-register consumers. `addi`, `andi`, shift-immediate operations, load address generation, store address generation, and `jalr` all combine one register source with an immediate operand.

Without the `IMM` column, the K-map would only cover R-type two-register consumers and would miss the important timing shape where one source waits for bypass/commit/ARF while the other operand is ready by construction and has no DST_REG tag. Keeping `IMM` prevents us from faking an unnecessary second register dependency just to fit a two-register table.

`IMM` is modeled only as data source 2 in the P1 MUX map. The `IMM` row is not used. In the P2 MUX map, immediate operands are already resident payload data and are covered by `Stored Ready in ISQ`.

## P1 MUX Case List

| Case | Source 1 Ready | Source 2 Ready | Instructions | Timing Setup | Expected Behavior |
|---|---|---|---|---|---|
| `INT2_G1P3_G0P3` | G1 P3 Bypass | G0 P3 Bypass | `mul x6, x3, x4; add x5, x1, x2 -> add x20, x6, x5` | Issue `mul` two cycles before `add` so G1 and G0 results publish at P3 together. | Dependent captures rs1 from G1 Bypass and rs2 from G0 Bypass in the same source-ready cycle. |
| `INT2_G3P3_G0P3` | G3 Load P3 Bypass | G0 P3 Bypass | `ld x7, 0(x8); add x5, x1, x2 -> add x20, x7, x5` | Issue load one cycle before G0 ALU producer so both P3 publications align. | Dependent captures rs1 from G3 load Bypass and rs2 from G0 Bypass. |
| `INT2_P4_G0P3` | P4 Commit | G0 P3 Bypass | `add x6, x3, x4; add x5, x1, x2 -> add x20, x6, x5` | Arrange older `x6` producer to commit in the same cycle that `x5` producer publishes at G0 P3. | P1 source resolution uses Commit CDB for rs1 and G0 Bypass for rs2. |
| `INT2_ARF_G0P3` | Already in ARF | G0 P3 Bypass | `add x10, x1, x2; add x5, x3, x4 -> add x20, x10, x5` | Producer for `x10` is issued early enough to commit before the dependent reaches P1; G0 producer for `x5` reaches P3 in the dependent source-ready cycle. | rs1 reads ARF; rs2 captures G0 Bypass. |
| `INT2_G0P3_IMM` | G0 P3 Bypass | IMM | `add x5, x1, x2 -> addi x20, x5, 16` | G0 producer reaches P3 when dependent immediate-form instruction resolves sources. | rs1 captures G0 Bypass; rs2 is immediate and has no dependency tag. |
| `INT2_G3P3_G1P3` | G3 Load P3 Bypass | G1 P3 Bypass | `mul x6, x3, x4; ld x7, 0(x8) -> add x20, x7, x6` | Issue `mul` one cycle before load so G1 and G3 P3 publications align. | Dependent captures rs1 from G3 load Bypass and rs2 from G1 Bypass. |
| `INT2_P4_G1P3` | P4 Commit | G1 P3 Bypass | `add x7, x8, x9; mul x6, x3, x4 -> add x20, x7, x6` | Arrange older `x7` producer to commit in the same cycle that `mul` publishes at G1 P3. | P1 source resolution uses Commit CDB for rs1 and G1 Bypass for rs2. |
| `INT2_ARF_G1P3` | Already in ARF | G1 P3 Bypass | `add x10, x1, x2; mul x6, x3, x4 -> add x20, x10, x6` | Producer for `x10` is issued early enough to commit before the dependent reaches P1; G1 producer for `x6` reaches P3 in the dependent source-ready cycle. | rs1 reads ARF; rs2 captures G1 Bypass. |
| `INT2_G1P3_IMM` | G1 P3 Bypass | IMM | `mul x6, x3, x4 -> addi x20, x6, 16` | G1 producer reaches P3 when dependent immediate-form instruction resolves sources. | rs1 captures G1 Bypass; rs2 is immediate and has no dependency tag. |
| `INT2_P4_G3P3` | P4 Commit | G3 Load P3 Bypass | `add x7, x8, x9; ld x6, 0(x10) -> add x20, x7, x6` | Arrange older `x7` producer to commit in the same cycle that load publishes at G3 P3. | P1 source resolution uses Commit CDB for rs1 and G3 load Bypass for rs2. |
| `INT2_ARF_G3P3` | Already in ARF | G3 Load P3 Bypass | `add x11, x1, x2; ld x6, 0(x10) -> add x20, x11, x6` | Producer for `x11` is issued early enough to commit before the dependent reaches P1; load producer for `x6` reaches P3 in the dependent source-ready cycle. | rs1 reads ARF; rs2 captures G3 load Bypass. |
| `INT2_G3P3_IMM` | G3 Load P3 Bypass | IMM | `ld x6, 0(x10) -> addi x20, x6, 16` | Load producer reaches P3 when dependent immediate-form instruction resolves sources. | rs1 captures G3 load Bypass; rs2 is immediate and has no dependency tag. |
| `INT2_P4_P4` | P4 Commit | P4 Commit | `add x5, x1, x2; add x6, x3, x4 -> add x20, x5, x6` | Arrange the two older producers as P4 head0/head1 commits in the dependent source-resolution cycle. | P1 source resolution captures both operands from the two Commit CDB lanes. |
| `INT2_ARF_P4` | Already in ARF | P4 Commit | `add x10, x1, x2; add x6, x3, x4 -> add x20, x10, x6` | Producer for `x10` is issued early enough to commit before the dependent reaches P1; older `x6` producer commits in the dependent source-resolution cycle. | rs1 reads ARF; rs2 captures Commit CDB. |
| `INT2_P4_IMM` | P4 Commit | IMM | `add x5, x1, x2 -> addi x20, x5, 16` | Older `x5` producer commits in the dependent immediate-form instruction's source-resolution cycle. | rs1 captures Commit CDB; rs2 is immediate and has no dependency tag. |
| `INT2_ARF_ARF` | Already in ARF | Already in ARF | `add x10, x1, x2; add x11, x3, x4 -> add x20, x10, x11` | Both producers are issued early enough to commit before the dependent reaches P1, so neither source has a live DST_REG mapping. | Both operands read ARF at P1; no bypass or commit overlay is needed. |
| `INT2_ARF_IMM` | Already in ARF | IMM | `add x10, x1, x2 -> addi x20, x10, 16` | Producer for `x10` is issued early enough to commit before the dependent reaches P1; the second operand is immediate. | rs1 reads ARF; rs2 is immediate and has no dependency tag. |

## P2 MUX Case List

In every P2 case below, the dependent instruction is already resident in its group-local ISQ before the source-ready cycle. At least one not-yet-ready register source observes a same-cycle P3 tag match at P2, unless the case is the pure `Stored Ready in ISQ` resident-data case. `P4 Commit CDB` is intentionally absent because it terminates at P1 MUX and never drives resident-entry P2 MUX forwarding.

| Case | Source 1 at P2 MUX | Source 2 at P2 MUX | Instructions | Timing Setup | Expected Behavior |
|---|---|---|---|---|---|
| `INT2_P2_G1P3_G0P3` | G1 P3 Bypass | G0 P3 Bypass | `mul x6, x3, x4; add x5, x1, x2 -> add x20, x6, x5` | Dispatch dependent early with wait tags for both operands. Issue `mul` two cycles before `add` so G1 and G0 results publish at P3 together while the dependent is resident. | P2 FU-input mux selects rs1 from G1 Bypass and rs2 from G0 Bypass; the resident entry can issue in that cycle if the selected FU is free. |
| `INT2_P2_G3P3_G0P3` | G3 Load P3 Bypass | G0 P3 Bypass | `ld x7, 0(x8); add x5, x1, x2 -> add x20, x7, x5` | Dispatch dependent early with wait tags; issue the load one cycle before the G0 ALU producer so both P3 publications align. | P2 mux selects rs1 from G3 load Bypass and rs2 from G0 Bypass. |
| `INT2_P2_STORED_G0P3` | Stored Ready in ISQ | G0 P3 Bypass | `add x10, x1, x2; add x5, x3, x4 -> add x20, x10, x5` | Resolve and store `x10` in the dependent ISQ entry earlier; keep rs2 waiting until `x5` reaches G0 P3. | P2 mux uses stored `entry.rs1_data` and current G0 Bypass data. |
| `INT2_P2_G3P3_G1P3` | G3 Load P3 Bypass | G1 P3 Bypass | `mul x6, x3, x4; ld x7, 0(x8) -> add x20, x7, x6` | Dispatch dependent early; issue `mul` one cycle before load so G1 and G3 P3 publications align. | P2 mux selects rs1 from G3 load Bypass and rs2 from G1 Bypass. |
| `INT2_P2_STORED_G1P3` | Stored Ready in ISQ | G1 P3 Bypass | `add x10, x1, x2; mul x6, x3, x4 -> add x20, x10, x6` | Resolve and store `x10` in the dependent entry earlier; keep rs2 waiting for the G1 producer. | P2 mux uses stored `entry.rs1_data` and current G1 Bypass data. |
| `INT2_P2_STORED_G3P3` | Stored Ready in ISQ | G3 Load P3 Bypass | `add x11, x1, x2; ld x6, 0(x10) -> add x20, x11, x6` | Resolve and store `x11` in the dependent entry earlier; keep rs2 waiting for the load producer. | P2 mux uses stored `entry.rs1_data` and current G3 load Bypass data. |
| `INT2_P2_STORED_STORED` | Stored Ready in ISQ | Stored Ready in ISQ | `add x10, x1, x2; add x11, x3, x4 -> add x20, x10, x11` | Resolve both sources before the observed P2 issue cycle; the dependent entry is resident with both `rs_ready` bits set. | P2 mux selects both operands from stored `entry.rs_data`; no current-cycle forwarding is needed. |

## Supplemental Same-RD Fanout Case List

These cases cover the legal shape hidden behind the gray same-P3-source diagonal cells. The gray cells mean two different producers cannot publish on the same group P3 bypass lane in the same cycle. They do not forbid one producer payload from feeding both rs1 and rs2 of the same dependent instruction.

| Case | MUX Point | Source Ready | Instructions | Timing Setup | Expected Behavior |
|---|---|---|---|---|---|
| `INT2_SAME_RD_P1_G0P3_RS1_RS2` | P1 MUX | G0 P3 Bypass fanout | `add x5, x1, x2 -> add x20, x5, x5` | Producer reaches G0 P3 when dependent constructs its ISQ payload. | P1 source resolution matches the same producer tag for both rs1 and rs2 and captures one G0 Bypass payload into both operands. |
| `INT2_SAME_RD_P1_G1P3_RS1_RS2` | P1 MUX | G1 P3 Bypass fanout | `mul x5, x1, x2 -> add x20, x5, x5` | MUL producer reaches G1 P3 when dependent constructs its ISQ payload. | P1 source resolution matches the same producer tag for both rs1 and rs2 and captures one G1 Bypass payload into both operands. |
| `INT2_SAME_RD_P1_G3P3_RS1_RS2` | P1 MUX | G3 Load P3 Bypass fanout | `ld x5, 0(x1) -> add x20, x5, x5` | Load producer reaches G3 P3 when dependent constructs its ISQ payload. | P1 source resolution matches the same producer tag for both rs1 and rs2 and captures one G3 load Bypass payload into both operands. |
| `INT2_SAME_RD_P2_G0P3_RS1_RS2` | P2 MUX | G0 P3 Bypass fanout | `add x5, x1, x2 -> add x20, x5, x5` | Dependent is already resident with both rs wait tags matching the same G0 producer. | P2 resident-entry matching fans out one G0 Bypass payload to both operand inputs in the FU-input MUX cycle. |
| `INT2_SAME_RD_P2_G1P3_RS1_RS2` | P2 MUX | G1 P3 Bypass fanout | `mul x5, x1, x2 -> add x20, x5, x5` | Dependent is already resident with both rs wait tags matching the same G1 producer. | P2 resident-entry matching fans out one G1 Bypass payload to both operand inputs in the FU-input MUX cycle. |
| `INT2_SAME_RD_P2_G3P3_RS1_RS2` | P2 MUX | G3 Load P3 Bypass fanout | `ld x5, 0(x1) -> add x20, x5, x5` | Dependent is already resident with both rs wait tags matching the same G3 load producer. | P2 resident-entry matching fans out one G3 load Bypass payload to both operand inputs in the FU-input MUX cycle. |

## Notes

- These cases are ready-source composition cases. They intentionally do not enumerate whether a P3 source was produced by ALU, MUL, DIV, or load latency variants beyond the lane/source required by the case.
- If a case needs a longer-latency producer to align with a shorter-latency producer, adjust producer dispatch deltas. That scheduling detail does not create a new POI.
- White mirrored cells in the K-map are covered by rs1/rs2 symmetry. The chosen source order above follows the filled-triangle orientation where possible.
- The same-producer shape `add x20, x5, x5` is legal and covered by the supplemental same-RD fanout cases above. It is still not counted as a normal two-source composition POI.
- P2 cases do not imply that P2 reads ARF. A source shown as `Stored Ready in ISQ` is already present in the resident entry's `entry.rs_data`.
