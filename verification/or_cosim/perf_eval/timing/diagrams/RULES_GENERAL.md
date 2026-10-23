# Timing Diagram — OR BE Rules

Rulebook for the **form** of an OR BE cycle-by-cycle timing diagram. It fixes how
a cell is laid out and what each part of it means.

The vocabulary is the OR BE pipeline: `IB` → `dispatch` → `ISQ_Groupx` → FU
(`ALU0`, `ALU1`, `MUL`, `DIV`, `BRU`, `AGU`, `L1D`) → `WB` → `C`, plus the
`Buffer` hold between WB and C. Architecture semantics stay in the OR BE spec;
this file only fixes the cell layout and the BE owner/action vocabulary.

Status: draft v0.1 (OR BE adaptation).

## G0. Scope

A figure is a table: **columns are cycles**, **rows are instructions in program
order**. Every cell describes exactly **one instruction in one cycle**.

This file answers three questions and nothing else:

1. **who owns** the instruction in that cycle — the owner line (G2);
2. **what state** the owner is in — the state line (G3);
3. **what the instruction produces** in that cycle — the action / result lines
   (G4).

The OR BE stage names are P0 `IB`, P1 `dispatch`, P2 `ISQ`/FU, P3 `WB`,
P4 `C`. The normative vocabulary table is G6.

## G1. Grid

- One row per instruction. The top row is the oldest.
- One column per cycle. `T1` is the first cycle the instruction is visible in
  the pipeline.
- A variable-length wait is **one** `…` column: the length is not fixed by the
  RTL, so the column is nominal, but its cell still describes a real cycle.
- Cycles after a wait are named from an anchor — `X`, `X+1`, `X+2`, … The domain
  rulebook fixes the anchor names.
- A `…` column is an ordinary column: its cell carries an owner like any other
  (G2).
- An **empty cell** means "this instruction is not in the picture in this
  cycle". It never means "present but doing nothing" — such a cycle is written
  out like any other.

**A figure file may open with a style block.** A wide table scrolls sideways in
the viewer instead of wrapping, which keeps one cycle per column readable:

```html
<style>
table { display: block; overflow-x: auto; width: 100%; }
th, td { white-space: nowrap !important; }
</style>
```

It carries no meaning — drop it and the figure still says the same thing, it just
wraps.

## G2. Owner line

**The first line of every non-empty cell is the owner, in square brackets, with
one space inside each bracket:**

```
[ owner ]
```

- The brackets always read `[ ` … ` ]` — never `[owner]`. The spaces are part of
  the form, so the owner line is recognisable at a glance in every figure.
- The owner is **where the instruction is** this cycle:
  - the pipeline stage it occupies;
  - the queue it sits in or waits in — waiting for a response, for its turn, for
    an authorization;
  - the unit that holds or drives it this cycle.
- So an owner is a stage, a queue, or a unit that drives control.
- **Exactly one owner per cell.** When two structures hold the instruction in
  the same cycle, the owner is the one that decides what happens in that cycle;
  the other one is still visible as the **subject** of an action (G4).
- The brackets contain **only who**. A state goes on the next line (G3).

OR BE examples — same rule, different holders:

| what the cycle is | cell lines |
|---|---|
| an ALU in P2 | `[ ALU0 ]` then `execute add` |
| a dependent waiting for one source | `[ ISQ_Group1 ]` then `wait for Bypass[0] tag(x5)` |
| a load computing its address | `[ AGU ]` then `compute address` |
| a load accessing the cache | `[ L1D ]` then `access L1D, hit` |
| a DIV in execution | `[ DIV ]` then `divide step 3/8` |
| a result waiting for commit | `[ Buffer ]` then `hold`, `wait for commit` |
| a committing instruction | `[ C ]` then `commit`, `ARF write x5`, `INT_tag_mapping clear busy` |

## G3. State line

- A **state** says what the owner is doing to the instruction. If a cell has a
  state, it is the line **immediately after** the owner line.
- It is written alone: no brackets, no subject.
- No state means the line is simply omitted.

OR BE examples: `stall` on `[ IB ]` when dispatch is blocked; `hold` on
`[ Buffer ]` while waiting for commit; `hold` on `[ WB ]` when the P3
arbiter loses.

```
[ IB ]          [ Buffer ]
stall           hold
                wait for commit
```

- A state is not an action: it produces nothing and takes effect at no edge.
- When a state needs a reason or an annotation, that annotation is a further
  line of its own, after the state (see G4, Miscellaneous description).

## G4. Action and result lines

Everything after the owner line (and the state line, if any) says what the
instruction **produces** this cycle. A cell may carry one line, several lines,
or none.

### Subject rule

| who performs the action | how it is written | OR BE example |
|---|---|---|
| the cell's **owner** | no subject — the action alone | `execute add`, `divide step 3/8`, `commit` |
| **another** unit | subject + action | `ISQ_Group1 capture Bypass[0] tag(x5)`, `scoreboard set exec_done` |

A dependent issuing in `[ ALU1 ]` therefore reads:

```
[ ALU1 ]
ISQ_Group1 capture Bypass[0] tag(x5)
execute add
```

— the owner is the FU stage, the capture belongs to the ISQ entry, and the
execute belongs to the ALU.

### Result rule

A result is what an action *returned*. Its position depends on **when** it
appears, not on what it is:

| produced by | written | example |
|---|---|---|
| an action of the **previous** cycle | on its **own** line | `Bypass match` |
| an action of the **same** cycle | on **that action's** line | `access L1D, hit` |

- A result never carries a subject: the action that produced it already names
  the source.
- A result is not an owner statement — it does not change who is at the top of
  the cell.

### Arbitration

When two instructions want the same output in the same cycle, the outcome is a
**result**, not a misc note:

| outcome | written |
|---|---|
| won the contention | the action as usual, with the result `accepted` on its own line |
| lost the contention | `<action>`, with the result `blocked` on that line, plus a misc note naming who outranked it |

- The **winner carries no misc note** — `accepted` already says it won.
- The **loser keeps its action line** — the same action, only the result
  differs — and says who beat it:
  `(older ALU0 has priority)`, `(older scoreboard head has priority)`,
  `(same-group P3 bypass lane has priority)`.
- An output that **no one else wants** in that cycle carries **neither a result
  nor a misc note**.
- A subject still applies: `ISQ_Group1 issue ALU1, blocked`.
- The loser comes back the next cycle and drives the same outputs again, this time
  with no result and no note.

### Only what is produced is written

If a structure neither acts nor yields a result in that cycle, it gets **no
line** — even when it physically holds the instruction's data. The owner line
already says where the instruction is.

### Waiting

Two kinds of wait are written as **actions**, not as states, because the owner is
doing something in that cycle:

| wait | written |
|---|---|
| the ISQ entry is not selected yet | `wait until at ISQ head` |
| the ISQ has no free slot | `wait for ISQ slot` |
| a producer result has not arrived | `wait for Bypass[0] tag(x5)` |
| the result is waiting for commit | `wait for commit` |

The owner line already names the queue, so the action does not repeat it.

### Miscellaneous description

A note that describes the instruction or the cycle rather than an event — a mode,
a flag, a reason — goes on the **last line** of the cell, in parentheses, on its
own line:

```
[ IB ]
stall
wait for dispatch slot
(dispatch slot taken by older ALU0)
```

- It is not an owner, not a state and not an action: it produces nothing and takes
  effect at no edge.
- Several may follow one another; they stay at the **end** of the cell, after
  every action line.
- It always states **which rule decided**, never a bare verdict:
  `(older ALU0 has priority)`, not `(blocked)`.
- Brackets never appear on this line; the brackets are reserved for the owner.

### Verb form

Every verb is written in the **base form**, whoever the subject is: `execute`,
`capture`, `drive`, `commit`, `write`, `access`, `allocate`, `rename`,
`wait for`. Never the third-person `-s` form — a subject is a unit name, not a
grammatical person, so `scoreboard set exec_done`, not `scoreboard sets exec_done`. A complete cell stays
a list of short statements, not a sentence.

A **result** is a state, not an action, so it may read as a past participle:
`access L1D, hit`. That phrase is one action and its result on one line, never
two actions sharing a line.

## G5. Submodule marking

**A submodule's name is bold wherever it appears in a cell.** That is the only
formatting a cell carries: it answers "which block is doing this" at a glance,
without adding words.

| marked | not marked |
|---|---|
| a block that acts, or that an action belongs to: `**scoreboard** allocate entry`, `**ISQ_Group0** write entry`, `**INT_ARF** write x5`, `access **L1D**, hit` | the **owner** — it is already delimited by `[ ]`, and bolding it too would compete with the block names |
| a **pipeline stage** named inside a cell — `check **P2** operand for forwarding, hit`, `(backpressure from **P3**)` | a verb, a state, a result: `commit`, `execute`, `hit`, `accepted` |
| the same name inside a misc note: `(older **ALU0** has priority)` | an **interface / bus** that is only driven: `drive Bypass[0] tag+data`, `drive P3 bypass tag+data`, `emit Commit CDB request` |

- Bold **every** occurrence, not just the first one in a cell: the same block can
  appear more than once (`**ISQ_Group1** capture Bypass[0] tag(x5), **ALU1** execute add`).
- Bold the **name only**, never the phrase around it: `**scoreboard** allocate entry`,
  not `**scoreboard allocate entry**`.
- No other emphasis exists. No italic, no underline, no braces, no colour — a
  cell with two competing emphasis styles reads as two competing meanings.
- A stage is marked exactly like a block: every `P0` / `P1` / `P2` / `P3` / `P4`
  that appears **inside** a cell is bold, because it names a pipeline stage.
  Only the owner is exempt — `[ ALU0 ]` stays plain.
- Bold blocks, not buses: `**scoreboard**`, `**Buffer**`, `**ISQ_Group0**`, `**INT_ARF**`,
  `**INT_tag_mapping**`, `**L1D**`, `**AGU**`, `**ALU0**`, `**DIV**` are bold; `Bypass[0]`,
  `P3 bypass`, `Commit CDB` are not.
- Which names count as submodules is fixed by the OR BE vocabulary table (G6).

## G6. OR BE vocabulary

The owner line names where the instruction is; the action lines name what it
does in that cycle. This table is normative for the OR BE figures.

| Stage | Owner | State (optional) | Action / result lines |
|---|---|---|---|
| P0 | `[ IB ]` | `stall` when dispatch is blocked | `enqueue instruction`; on stall `wait for dispatch slot` |
| P1 | `[ dispatch ]` | — | `allocate **scoreboard** entry`, `write **ISQ_Groupx**`, `rename rd`; when a source is captured: `capture Bypass[g] tag(rd)` |
| P2 wait | `[ ISQ_Groupx ]` | — | `wait for <source> tag`; `wait until at ISQ head`; `wait for ISQ slot` |
| P2 ALU | `[ ALU0 ]` / `[ ALU1 ]` | — | `execute <op>` |
| P2 MUL | `[ MUL ]` | — | `execute mul step n/3` |
| P2 DIV | `[ DIV ]` | — | `divide step n/8` |
| P2 BRU | `[ BRU ]` | — | `resolve control`, `compute link` |
| P2 AGU † | `[ AGU ]` | — | `compute address` |
| P2 L1D † | `[ L1D ]` | — | `access **L1D**, hit` / `miss` |
| P3 | `[ WB ]` | `hold` when the P3 arbiter loses | `drive Bypass[g] tag+data`, `**scoreboard** set exec_done`, `**Buffer** write result`; loser: state `hold`, `drive Bypass[g] tag+data, blocked`, `(older ... has priority)` |
| P3 hold | `[ Buffer ]` | `hold` | `wait for commit` |
| P4 | `[ C ]` | — | `commit`, `**INT_ARF** write rd`, `**INT_tag_mapping** clear busy`; commit loser: state `hold`, `wait for commit slot, blocked` |

Notes:

- `scoreboard` records the P3 completion (`exec_done`); `Buffer` stores
  the 64-bit result data. There is no `ROB` submodule in the BE: use these two
  names, not `ROB`, in owner/action cells.
- `scoreboard` is the approved short name for the `CompletionScoreboard`
  submodule (leadership naming exception to the HAS-name rule). Do not expand it
  back to the full module name inside a cell.
- `INT_tag_mapping` is the `{busy, tag}` map for integer destinations; commit
  clears `busy` only when the committing tag matches. There is no `DST_REG`
  submodule. The FP counterpart is `FP_tag_mapping`.
- The INT diagrams use `INT_tag_mapping` for the destination busy/tag state.
  `ARF` in prose means the architectural register file; the RTL block is
  `INT_ARF` (FP: `FP_ARF`).
- A fixed multi-cycle FU repeats its owner name and carries the step number
  (`divide step 1/8` … `8/8`). Do not leave the intermediate cycles as a bare
  `DIV` / `MUL`.
- `[ Buffer ]` is used only for a live instruction between WB and C. An empty
  cell still means "not in the picture".
- FPU rows use the same pattern with their own FU name and stage count; they are
  not part of the INT diagrams yet.
- `Bypass[g]` is the **P3 result bypass lane for group g**. It is driven in the
  producer's WB cycle and can be consumed two ways: `P3 → P1` at dispatch
  (capture into a new ISQ payload) or `P3 → P2` at a resident ISQ entry
  (wakeup / FU-input MUX). The `P4 → P1` path is the **Commit CDB**, not
  `Bypass[g]`; the Commit CDB has no `P4 → P2` path.
- `Bypass[g] tag(xN)` means “the Bypass[g] payload whose tag belongs to the
  in-flight producer that writes `xN`”. Matching is by **tag**, not by `xN`;
  `xN` is only the reader-facing alias. The same architectural register can be
  written by several in-flight instructions, so `xN` alone cannot select a
  bypass payload.
- `Bypass[g]`, `P3 bypass` and `Commit CDB` are buses, not blocks: keep them
  plain, not bold.
- † `[ AGU ]` and `[ L1D ]` name cycles **inside the external LSU**, not
  BE-owned P2 stages: `BE_LSU_interface.md` §2 states that the address is
  computed by the AGU inside the LSU. They are borrowed so that a LOAD producer
  row stays readable. The BE-side boundary for G3 is the `g3_lsu_iface` issue
  handshake plus the LSU result return, and neither owns a cell of its own. Do
  **not** treat `AGU` / `L1D` as BE submodules when the owner names are checked
  against the HAS.
- A G3 producer's `[ WB ]` assumes that the three result events land in the
  **same cycle** on the direct-hit path: the bypass copy
  (`lsu_be_bypass_valid`), the result data (`lsu_be_writeback_pld`) and the
  completion (`lsu_be_rob_done_valid`). The interface explicitly allows
  `rob_done` to arrive later than the data, and `latency_table.py` anchors `L`
  on the bypass only — so a late `rob_done` would move `C` and invalidate every
  P4 column of the figure. That situation is **out of scope** for this case set:
  state the assumption when it matters, do not model the late case.

## G7. Open items

Not decided yet; do not treat as rules.

- The order of the production lines inside a cell — results before actions,
  actions before results, or free.
- Where an annotation attached to a state goes (line after the state, or the
  state's own line).
- Whether a cell may ever carry a second state line.
