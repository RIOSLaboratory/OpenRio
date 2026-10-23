<style>
table { display: block; overflow-x: auto; width: 100%; } th, td { white-space:
nowrap !important; } </style>

# Cache B1 Timing Diagrams — younger LOAD

Rules: `../RULES.md`. Columns are cycles (**T1 = E1 accept cycle**), rows are
program order (older `O`, younger `Y`). An older access in front of a younger
load — usually a store, once an older load.

- **Feeding the load** — `B1-FWD` (from the store entry; late-wakeup variant),
  `B1-WB` (from the write buffer), `B1-WB-HOLD` (the buffer holds its head entry
  one extra cycle), `B1-REFILL-FWD` (the refill bypass merges the store's bytes
  in).
- **Slow path with nothing to forward** — `B1-PGNE`: the offset matches, the
  pages differ.
- **Held behind the older op's `E2`** — `B1-PA-UNK` (the older store's page walk
  owns `E2`), `B1-PA-UNK-XPG` (same, but the load's pages differ).
- **Sharing the older one's refill** — `B1-MSHR-SAMELINE`: own MSHR entry, one
  response.
- **No older state** — not a case of this axis: with nothing in front of the
  load the timing is exactly `A-L-H`.
- **Two loads back to back** — `B1-LD-LD-ORDER`: completion order only.

---

## Case B1-FWD (older store forwarding, same cache line, pages equal)

Assumes the younger load and an older store that targets the load's cache line
are the only two accesses in flight, both with their translation and their
cache line resident and no write buffer entry built for that store yet; the
load is issued one cycle after the store, so its `E3` lands while the store's
ISB entry is still live, and the store's own write buffer entry is the head
when it commits.

| Instruction | T1 | T2 | T3 | T4 | T5 |
|:---|:--:|:--:|:--:|:--:|:--:|
| `sw x5, 0(x1)` O | [ E1 ]<br/>**AGU** output VA<br/>allocate **ISB**<br/>(speculative=0) | [ E2 ]<br/>access **DTLB**, hit<br/>**DTLB** output PA | [ E3 ]<br/>**ISB** capture PA<br/>**ISB** access **L1D** SRAM | [ ISB ]<br/>**L1D** tag hit<br/>**L1D** output cache line<br/>output store data<br/>allocate **WRITE BUFFER**<br/>drive RoB done output | [ WRITE BUFFER ]<br/>Store commit<br/>merge store data into cache line<br/>write **L1D** SRAM |
| `ld x6, 0(x2)` Y |  | [ E1 ]<br/>**AGU** output VA<br/>access **L1D** SRAM | [ E2 ]<br/>access **DTLB**, hit<br/>**L1D** tag hit<br/>**L1D** output cache line | [ E3 ]<br/>**ISB** check PA for forwarding, hit<br/>**ISB** forward store data | [ E4 ]<br/>**LD DATA MERGE** merge **ISB** data into **L1D** data<br/>drive RoB done output<br/>drive CDB<br/>drive bypass output |

- **`T4` cycle (O):** the entry holds a physical address, so the completion is
  driven here while the read result comes back; the bytes the store contributes
  go into the new write buffer entry.
- **`T4` cycle (Y):** the younger load checks the ISB for an older same-line
  store. The offset matches and the pages are equal, so the check hits and the
  store forwards its bytes.
- **`T5` cycle (Y):** the load-data merge combines the forwarded bytes with the
  cache line read in `T2`, and the result is driven out — RoB done, the CDB and
  the bypass — in this one cycle.
- **`T5` cycle (O):** the write buffer merges the store's bytes into the line and
  writes it back.

### Variant: speculative at accept (late wakeup)

Assumes the younger load and an older store that targets the load's cache line
are the only two accesses in flight, both with their translation and their
cache line resident, but BE has not authorized the store yet, so it is accepted
speculative and takes its L1D access only at `Twk`; the load is still issued one
cycle after the store, so its `E3` lands while the store's ISB entry is live.

| Instruction | T1 | T2 | T3 | T4 | T5 | T6 | T7 | T8 |
|:---|:--:|:--:|:--:|:--:|:--:|:--:|:--:|:--:|
| `sw x5, 0(x1)` O | [ E1 ]<br/>**AGU** output VA<br/>allocate **ISB**<br/>(speculative=1) | [ E2 ]<br/>access **DTLB**, hit<br/>**DTLB** output PA | [ E3 ]<br/>**ISB** capture PA | [ ISB ]<br/>drive RoB done output | [ ISB ]<br/>wait for wakeup from BE | [ ISB ]<br/>receive wakeup from BE<br/>access **L1D** SRAM | [ ISB ]<br/>**L1D** tag hit<br/>**L1D** output cache line<br/>output store data<br/>allocate **WRITE BUFFER** | [ WRITE BUFFER ]<br/>Store commit<br/>merge store data into cache line<br/>write **L1D** SRAM |
| `ld x6, 0(x2)` Y |  | [ E1 ]<br/>**AGU** output VA<br/>access **L1D** SRAM | [ E2 ]<br/>access **DTLB**, hit<br/>**L1D** tag hit<br/>**L1D** output cache line | [ E3 ]<br/>**ISB** check PA for forwarding, hit<br/>**ISB** forward store data | [ E4 ]<br/>**LD DATA MERGE** merge **ISB** data into **L1D** data<br/>drive RoB done output<br/>drive CDB<br/>drive bypass output |  |  |  |

- **`T4` cycle (O):** the completion is reported even though the entry may not
  access the cache line yet — `done` is decoupled from the access and the
  commit.
- **`T6` cycle (O):** the wakeup arrives and the access is taken in the same
  cycle. BE is told done for O at `T4`, so O's commit lands after Y's completion.

## Case B1-WB (older store already drained to the write buffer)

Assumes three accesses in flight: an even older store whose write buffer entry
for the same cache line is the head, then this store, then the load two cycles
behind it; all translations and the cache line are resident, so this store's
probe hits that entry instead of taking an L1D access, and the load's `E3` lands
on this store's commit cycle and takes the whole cache line from the entry it
built.

| Instruction | T1 | T2 | T3 | T4 | T5 | T6 |
|:---|:--:|:--:|:--:|:--:|:--:|:--:|
| `sw x5, 0(x1)` O | [ E1 ]<br/>**AGU** output VA<br/>allocate **ISB**<br/>(speculative=0) | [ E2 ]<br/>access **DTLB**, hit<br/>**DTLB** output PA | [ E3 ]<br/>**ISB** capture PA | [ ISB ]<br/>access **WRITE BUFFER**, hit<br/>output store data<br/>allocate **WRITE BUFFER**<br/>drive RoB done output | [ WRITE BUFFER ]<br/>Store commit<br/>merge store data into cache line copied from older entry<br/>write **L1D** SRAM |  |
| `ld x6, 0(x2)` Y |  |  | [ E1 ]<br/>**AGU** output VA<br/>access **L1D** SRAM | [ E2 ]<br/>access **DTLB**, hit<br/>**L1D** tag hit<br/>**L1D** output cache line | [ E3 ]<br/>**WRITE BUFFER** check PA for forwarding, hit<br/>**WRITE BUFFER** forward cache line | [ E4 ]<br/>**LD DATA MERGE** output **WRITE BUFFER** data<br/>drive RoB done output<br/>drive CDB<br/>drive bypass output |

- **`T4` cycle (O):** the write buffer probe hits, so no tag read is issued at
  all. The completion is driven here and the entry's own bytes move into its new
  write buffer slot.
- **`T5` cycle (Y):** the load checks the write buffer instead of the ISB: the
  entry is there, so it forwards the whole line.
- The merge needs no combination work: the write buffer entry holds 64 bytes and
  is always younger than the line the load read, so its data wins outright. The
  commit therefore runs on a line **copied from the older entry** — hence
  `merge store data into cache line copied from older entry` on its commit cell.

## Case B1-WB-HOLD (the load's read precedes the older store's L1D write)

Assumes the younger load and an older store that targets the same cache line
are the only two accesses in flight, both resident, with the store's own write
buffer entry the head when it commits; the load is issued three cycles after
the store, so its read at `T4` returns the pre-write cache line, and that head
entry is held one extra cycle so the load can take the whole cache line from
it.

| Instruction | T1 | T2 | T3 | T4 | T5 | T6 | T7 |
|:---|:--:|:--:|:--:|:--:|:--:|:--:|:--:|
| `sw x5, 0(x1)` O | [ E1 ]<br/>**AGU** output VA<br/>allocate **ISB**<br/>(speculative=0) | [ E2 ]<br/>access **DTLB**, hit<br/>**DTLB** output PA | [ E3 ]<br/>**ISB** capture PA<br/>**ISB** access **L1D** SRAM | [ ISB ]<br/>**L1D** tag hit<br/>**L1D** output cache line<br/>output store data<br/>allocate **WRITE BUFFER**<br/>drive RoB done output | [ WRITE BUFFER ]<br/>Store commit<br/>merge store data into cache line<br/>check **E2** PA for forwarding, hit<br/>hold **WRITE BUFFER** entry<br/>write **L1D** SRAM | [ WRITE BUFFER ]<br/>release **WRITE BUFFER** entry |  |
| `ld x6, 0(x2)` Y |  |  |  | [ E1 ]<br/>**AGU** output VA<br/>access **L1D** SRAM | [ E2 ]<br/>access **DTLB**, hit<br/>**L1D** tag hit<br/>**L1D** output cache line | [ E3 ]<br/>**WRITE BUFFER** check PA for forwarding, hit<br/>**WRITE BUFFER** forward cache line | [ E4 ]<br/>**LD DATA MERGE** output **WRITE BUFFER** data<br/>drive RoB done output<br/>drive CDB<br/>drive bypass output |

- **`T5` cycle (O):** the entry is the write buffer head and writes its line, but
  a load in `E2` matches the same line by PA, so the entry is **held** instead of
  being freed — the load's read has already returned the old line.
- **`T6` cycle (O):** the load has taken the bytes from the write buffer, so the
  entry is released.
- The hold is what makes forwarding possible: without it the load would have read
  a stale line and had nothing to forward from.

## Case B1-PGNE (older store, younger load, VA pre-filter hit, pages differ)

Assumes the younger load and an older store that targets the same cache line
are the only two accesses in flight, both resident, with the store's ISB entry
still live at the load's `E3`; the load is issued one cycle after the store
and its page differs, so the pre-filter hits and the merge path is taken while
the store supplies no byte.

| Instruction | T1 | T2 | T3 | T4 | T5 |
|:---|:--:|:--:|:--:|:--:|:--:|
| `sw x5, 0(x1)` O | [ E1 ]<br/>**AGU** output VA<br/>allocate **ISB**<br/>(speculative=0) | [ E2 ]<br/>access **DTLB**, hit<br/>**DTLB** output PA | [ E3 ]<br/>**ISB** capture PA<br/>**ISB** access **L1D** SRAM | [ ISB ]<br/>**L1D** tag hit<br/>**L1D** output cache line<br/>output store data<br/>allocate **WRITE BUFFER**<br/>drive RoB done output | [ WRITE BUFFER ]<br/>Store commit<br/>merge store data into cache line<br/>write **L1D** SRAM |
| `ld x6, 0(x2)` Y |  | [ E1 ]<br/>**AGU** output VA<br/>access **L1D** SRAM | [ E2 ]<br/>access **DTLB**, hit<br/>**L1D** tag hit<br/>**L1D** output cache line | [ E3 ]<br/>(no forwarding) | [ E4 ]<br/>**LD DATA MERGE** output **L1D** data<br/>drive RoB done output<br/>drive CDB<br/>drive bypass output |

- **`T4` cycle (Y):** the pre-filter hits, so the load goes to the merge path and
  `E3` only decides the forwarding verdict. The offset matches but the physical
  page does not, so nothing is supplied — a `miss` is not drawn, the cell says
  `(no forwarding)` and nothing else. `E3` does not stall: the result is simply
  not ready until the merge runs.
- **`T5` cycle (Y):** the merge outputs the cache line unchanged
  (`LD DATA MERGE output L1D data`) and the three completion drives go out in that
  same cycle. The older store reported its RoB done at `T4`, a cycle earlier, so
  nothing is contended here and none of the three lines carries a result.

## Case B1-PA-UNK (older store PA unknown — younger load held in `E1`)

Assumes the younger load and an older store that targets the same cache line
are the only two accesses in flight, both resident, but the store's
translation is missing with the TMQ free; the store stalls at `E2` through
`Tpte-1`, which holds the load in `E1`, so the load's `E1` completes at `Tpte`
and its `E3` still finds the store's ISB entry live.

| Instruction | T1 | T2 | T3 | T4 | … | Tpte | Tpte+1 | Tpte+2 | Tpte+3 | Tpte+4 |
|:---|:--:|:--:|:--:|:--:|:--:|:--:|:--:|:--:|:--:|:--:|
| `sw x5, 0(x1)` O | [ E1 ]<br/>**AGU** output VA<br/>allocate **ISB**<br/>(speculative=0) | [ E2 ]<br/>stall<br/>access **DTLB**, miss<br/>allocate **TMQ** | [ E2 ]<br/>stall<br/>**TMQ** emit MMU request | [ E2 ]<br/>stall<br/>**TMQ** wait for MMU response | [ E2 ]<br/>stall<br/>**TMQ** wait for MMU response | [ E2 ]<br/>**TMQ** receive MMU response<br/>**TMQ** write **DTLB**<br/>**DTLB** output PA | [ E3 ]<br/>**ISB** capture PA<br/>**ISB** access **L1D** SRAM | [ ISB ]<br/>**L1D** tag hit<br/>**L1D** output cache line<br/>output store data<br/>allocate **WRITE BUFFER**<br/>drive RoB done output | [ WRITE BUFFER ]<br/>Store commit<br/>merge store data into cache line<br/>write **L1D** SRAM |  |
| `ld x6, 0(x2)` Y |  | [ E1 ]<br/>stall<br/>(backpressure from **E2**) | [ E1 ]<br/>stall<br/>(backpressure from **E2**) | [ E1 ]<br/>stall<br/>(backpressure from **E2**) | [ E1 ]<br/>stall<br/>(backpressure from **E2**) | [ E1 ]<br/>**AGU** output VA<br/>access **L1D** SRAM | [ E2 ]<br/>access **DTLB**, hit<br/>**L1D** tag hit<br/>**L1D** output cache line | [ E3 ]<br/>**ISB** check PA for forwarding, hit<br/>**ISB** forward store data | [ E4 ]<br/>**LD DATA MERGE** merge **ISB** data into **L1D** data<br/>drive RoB done output<br/>drive CDB<br/>drive bypass output |  |

- **`T2 … Tpte-1` (O):** `E2` is occupied by the walk, so the store cannot
  complete its `E2` and the load cannot rise into it.
- **`Tpte` cycle:** the response carries the PPN, so the store is injected
  straight into `E3` — no `E1` replay and no second `E2`.
- **`Tpte` cycle (Y):** `E2` frees at that edge, so the load takes its whole `E1`
  here, holding the address it needs for the read.
- From `Tpte+1` the two rows are `B1-FWD` shifted.

## Case B1-PA-UNK-XPG (older store PA unknown — younger load's pages differ)

Assumes the younger load and an older store that targets the load's cache line
are the only two accesses in flight, both with their cache line resident, the
store's translation missing with the TMQ free and the load's page differing from
the store's; the store stalls at `E2` through `Tpte-1`, the load completes `E1`
at `Tpte`, and its pre-filter still hits, so the merge path is taken while no
byte is supplied.

| Instruction | T1 | T2 | T3 | T4 | … | Tpte | Tpte+1 | Tpte+2 | Tpte+3 | Tpte+4 |
|:---|:--:|:--:|:--:|:--:|:--:|:--:|:--:|:--:|:--:|:--:|
| `sw x5, 0(x1)` O | [ E1 ]<br/>**AGU** output VA<br/>allocate **ISB**<br/>(speculative=0) | [ E2 ]<br/>stall<br/>access **DTLB**, miss<br/>allocate **TMQ** | [ E2 ]<br/>stall<br/>**TMQ** emit MMU request | [ E2 ]<br/>stall<br/>**TMQ** wait for MMU response | [ E2 ]<br/>stall<br/>**TMQ** wait for MMU response | [ E2 ]<br/>**TMQ** receive MMU response<br/>**TMQ** write **DTLB**<br/>**DTLB** output PA | [ E3 ]<br/>**ISB** capture PA<br/>**ISB** access **L1D** SRAM | [ ISB ]<br/>**L1D** tag hit<br/>**L1D** output cache line<br/>output store data<br/>allocate **WRITE BUFFER**<br/>drive RoB done output | [ WRITE BUFFER ]<br/>Store commit<br/>merge store data into cache line<br/>write **L1D** SRAM |  |
| `ld x6, 0(x2)` Y |  | [ E1 ]<br/>stall<br/>(backpressure from **E2**) | [ E1 ]<br/>stall<br/>(backpressure from **E2**) | [ E1 ]<br/>stall<br/>(backpressure from **E2**) | [ E1 ]<br/>stall<br/>(backpressure from **E2**) | [ E1 ]<br/>**AGU** output VA<br/>access **L1D** SRAM | [ E2 ]<br/>access **DTLB**, hit<br/>**L1D** tag hit<br/>**L1D** output cache line | [ E3 ]<br/>(no forwarding) | [ E4 ]<br/>**LD DATA MERGE** output **L1D** data<br/>drive RoB done output<br/>drive CDB<br/>drive bypass output |  |

- **`Tpte+2` cycle (Y):** the pre-filter hits, so the load takes the merge path;
  `E3` only decides the verdict. The offset matches but the page does not, so
  nothing is supplied — `(no forwarding)` alone, and no stall.
- **`Tpte+3` cycle (Y):** `LD DATA MERGE output L1D data` and the three drives go
  out together. The store reported its RoB done at `Tpte+2`, so nothing is
  contended and no line carries a result.

## Case B1-MSHR-SAMELINE (older store's cache line miss, younger load has its own entry)

Assumes the younger load and an older store that targets the same cache line
are the only two accesses in flight, both resident, and that the cache line is
absent so each miss is recorded in its own MSHR entry; the load is issued
three cycles after the store, so it sits behind it in the MSHR FIFO, issues no
request of its own, and replays once the head has written the cache line out.

| Instruction | T1 | T2 | T3 | T4 | T5 | T6 | … | Tresp | Tresp+1 | Tresp+2 | Tresp+3 | Tresp+4 | Tresp+5 | Tresp+6 |
|:---|:--:|:--:|:--:|:--:|:--:|:--:|:--:|:--:|:--:|:--:|:--:|:--:|:--:|:--:|
| `sw x5, 0(x1)` O | [ E1 ]<br/>**AGU** output VA<br/>allocate **ISB**<br/>(speculative=0) | [ E2 ]<br/>access **DTLB**, hit<br/>**DTLB** output PA | [ E3 ]<br/>**ISB** capture PA<br/>**ISB** access **L1D** SRAM | [ ISB ]<br/>**L1D** tag miss<br/>allocate **MSHR**<br/>drive RoB done output | [ MSHR ]<br/>emit NoC request | [ MSHR ]<br/>wait for NoC response | [ MSHR ]<br/>wait for NoC response | [ MSHR ]<br/>receive NoC response<br/>write **DPB** | [ MSHR ]<br/>allocate **WRITE BUFFER**<br/>**DPB** output cache line<br/>**ISB** output store data | [ WRITE BUFFER ]<br/>Store commit<br/>merge store data into cache line<br/>write **L1D** SRAM |  |  |  |  |
| `ld x6, 0(x2)` Y |  |  |  | [ E1 ]<br/>**AGU** output VA<br/>access **L1D** SRAM | [ E2 ]<br/>access **DTLB**, hit<br/>**L1D** tag miss<br/>allocate **MSHR** | [ MSHR ]<br/>wait for same NoC response | [ MSHR ]<br/>wait for same NoC response | [ MSHR ]<br/>wait for same NoC response | [ MSHR ]<br/>wait until at head | [ MSHR ]<br/>wait until at head | [ E1 ]<br/>replay<br/>**AGU** output VA<br/>access **L1D** SRAM | [ E2 ]<br/>access **DTLB**, hit<br/>**L1D** tag hit<br/>**L1D** output cache line | [ E3 ]<br/>drive RoB done output<br/>drive CDB<br/>drive bypass output |  |

- **`T4` cycle (O):** the read misses, so the MSHR entry is allocated. The entry
  holds a physical address, so the completion is also driven here.
- **`T6` cycle (Y):** the load's read misses too and gets its **own** entry. It is
  not the oldest entry of the line, so it issues no request.
- **`Tresp` cycle:** the response resolves both entries at once, but only the head
  installs.
- **`Tresp+1` / `Tresp+2`:** the head installs — and the store's bytes go into the
  same install — then the line is written back. The refill line is clean, so
  nothing is merged at the write-back.
- **`Tresp+3` cycle (Y):** the entry is the head and the line is resident, so it
  replays from `E1` with the saved address and the line is now a hit.

## Case B1-REFILL-FWD (older store not woken — the refill is forwarded)

Assumes the younger load and an older store that targets the same cache line
are the only two accesses in flight, both resident, with the cache line absent
and the store not authorized yet so it can take no L1D access; the load is
issued two cycles after the store and takes the refill itself, so the store's
ISB entry is still live on the load's L1D write cycle.

| Instruction | T1 | T2 | T3 | T4 | T5 | … | Tresp | Tresp+1 | Tresp+2 | Tresp+3 |
|:---|:--:|:--:|:--:|:--:|:--:|:--:|:--:|:--:|:--:|:--:|
| `sw x5, 0(x1)` O | [ E1 ]<br/>**AGU** output VA<br/>allocate **ISB**<br/>(speculative=1) | [ E2 ]<br/>access **DTLB**, hit<br/>**DTLB** output PA | [ E3 ]<br/>**ISB** capture PA | [ ISB ]<br/>drive RoB done output | [ ISB ]<br/>wait for wakeup from BE | [ ISB ]<br/>wait for wakeup from BE | [ ISB ]<br/>wait for wakeup from BE | [ ISB ]<br/>wait for wakeup from BE | [ ISB ]<br/>wait for wakeup from BE | [ ISB ]<br/>wait for wakeup from BE |
| `ld x6, 0(x2)` Y |  |  | [ E1 ]<br/>**AGU** output VA<br/>access **L1D** SRAM | [ E2 ]<br/>access **DTLB**, hit<br/>**L1D** tag miss<br/>allocate **MSHR** | [ MSHR ]<br/>emit NoC request | [ MSHR ]<br/>wait for NoC response | [ MSHR ]<br/>receive NoC response<br/>write **DPB** | [ MSHR ]<br/>allocate **WRITE BUFFER**<br/>**DPB** output cache line | [ WRITE BUFFER ]<br/>write **L1D** SRAM<br/>output cache line to **E4**<br/>**ISB** check PA for forwarding, hit<br/>**ISB** forward store data to **E4** | [ E4 ]<br/>**LD DATA MERGE** merge **ISB** data into **WRITE BUFFER** data<br/>drive RoB done output<br/>drive CDB<br/>drive bypass output |

- **`T4` cycle (O):** the entry holds a physical address, so the completion is
  reported even though it can neither access nor commit.
- **`Tresp+2` cycle (Y):** the refill bypass writes the fetched line, hands it
  straight to `E4` and in the same cycle checks the ISB for an older same-line
  store. The offset matches and the pages are equal, so the store forwards its
  bytes toward `E4` as well.
- **`Tresp+3` cycle (Y):** with the line in hand from the bypass and the store's
  bytes in hand from the ISB, the merge runs
  (`LD DATA MERGE merge ISB data into WRITE BUFFER data`) and the three
  completion drives go out in that same cycle.
- **Forwarding priority.** If a load already in the pipeline needs forwarding in
  its `E3` in the same cycle, forwarding to a load that is refilling L1D after an
  L1D miss has priority over forwarding to a load currently in the pipeline `E3`
  stage: the pipeline load stalls one cycle. That collision is
  `SH-ISB-FWD-CONFLICT`; here no other load wants the output.
- The store's bytes are **not** written into the cache: it is still speculative,
  so its bytes reach the cache only through its own commit.

## Case B1-LD-LD-ORDER (older merge-path load, younger direct-path load, delta = 1)

Assumes an older load and a younger load are the only two accesses in flight,
both resident and both with their result ready in the same cycle, the older
one on the merge path and the younger one on the direct path; their three
completion drives therefore collide and the older one wins all of them.

| Instruction | T1 | T2 | T3 | T4 | T5 |
|:---|:--:|:--:|:--:|:--:|:--:|
| `ld x5, 0(x1)` O (merge) | [ E1 ]<br/>**AGU** output VA<br/>access **L1D** SRAM | [ E2 ]<br/>access **DTLB**, hit<br/>**L1D** tag hit<br/>**L1D** output cache line | [ E3 ]<br/>**ISB** check PA for forwarding, hit<br/>**ISB** forward store data | [ E4 ]<br/>**LD DATA MERGE** merge **ISB** data into **L1D** data<br/>drive RoB done output, accepted<br/>drive CDB, accepted<br/>drive bypass output, accepted |  |
| `ld x6, 0(x2)` Y (direct) |  | [ E1 ]<br/>**AGU** output VA<br/>access **L1D** SRAM | [ E2 ]<br/>access **DTLB**, hit<br/>**L1D** tag hit<br/>**L1D** output cache line | [ E3 ]<br/>stall<br/>drive RoB done output, blocked<br/>drive CDB, blocked<br/>drive bypass output, blocked<br/>(older BE drive has priority) | [ E3 ]<br/>drive RoB done output<br/>drive CDB<br/>drive bypass output |

- **`T4` cycle:** both loads want the BE interface. The older one wins all three
  signals, so each of its drives carries `, accepted`; the younger one's three
  carry `, blocked` with `(older BE drive has priority)` and it stalls.
- **`T5` cycle:** the interface is free, so the younger load drives all three
  outputs again — with no competitor there is no result on their lines. It has
  nothing to merge, so it does not need a merge stage at all.
- **`T3` / `T4` cycle (O):** the older load checks the ISB in `E3`
  (`ISB check PA for forwarding, hit` + `ISB forward store data`) and merges the
  forwarded bytes in `E4`.
- Program order is kept even though the younger's data was ready in the same
  cycle.
