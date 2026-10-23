<style>
table { display: block; overflow-x: auto; width: 100%; } th, td { white-space:
nowrap !important; } </style>

# Cache SH Timing Diagrams — structural hazards

Rules: `../RULES.md`. Columns are cycles (**T1 = E1 accept cycle**); a cell holds
that cycle's stage, units, result and action, one per `<br/>` line. These figures
carry no caselist ID.

Structural hazards are **resources, not scenarios**: they change only *when* an
access can proceed, never *what* it does, and every one of them resumes **in
place** — no `E1` replay; an access that lost the port simply repeats itself in
the next cycle as the same action.

- **One L1D port.** Two ops want it in the same cycle. Both keep their action
  line, and the result on that line says which one got the port: the winner reads
  `access L1D SRAM, accepted` (no misc note), the loser reads
  `access L1D SRAM, blocked` plus a note naming who outranked it —
  `(load's SRAM read has priority)` or `(SRAM write has priority)`. The loser
  re-issues in its next cycle. The winner is decided by the **kind of access**,
  never by age: a write always beats a read; of two reads, the load's beats the
  store's.
  - `SH-READ-READ` — a load's read beats a store's L1D access.
  - `SH-WRITE-READ` — an L1D write beats any read.
- **A queue is full.** The op cannot get a slot, so it states
  `wait for <queue> slot` until `Tvacant`; having a slot is not the same as being
  served, so it then still waits for that queue's head
  (`wait until at head`) until `Thead`.
  - `SH-MSHR-FULL` — `A-L-M`'s load cannot record the miss.
  - `SH-ISB-FULL` — `A-S-H`'s store cannot allocate its ISB entry.
  - `SH-WB-FULL` — `A-L-M`'s install cannot get a write buffer slot, plus an
    `A-S-H` variant.
- **The write buffer takes one entry per cycle.** Two installs can want it in
  the same cycle — one from the DPB (a refilled line), one from the L1D (a store
  whose line is resident). The **source** decides: the L1D line wins, the DPB line
  waits a cycle in the DPB. Same result notation as the SRAM port: the winner
  reads `allocate WRITE BUFFER, accepted`, the loser reads
  `allocate WRITE BUFFER, blocked` + `(L1D cache line has priority)`.
  - `SH-WB-ALLOC-CONFLICT` — an older store's install beats a younger load's refill
    install.
- **One ISB forwarding output.** The ISB hands forwarding data to one load per
  cycle, and it picks that load itself. Both candidates keep their
  `ISB check PA for forwarding` line, because the addresses really do match; only
  the data is contended, so the winner is written with its forward action and
  **no result**, and the loser does not write a forward action at all — its stage
  holds `stall` and the misc note says why.
  - `SH-ISB-FWD-CONFLICT` — a load taking the refill bypass beats a load in
    `E3`.
- **A shared bus is busy.** `SH-CDB-BACKPRESSURE` — `A-L-H`'s completion cannot
  be driven on the CDB yet: `E3` holds in `stall` and the drive reads
  `drive CDB, blocked` + `(CDB backpressure)` until `Tready`.

`Tvacant` = the queue has room again; `Thead` = this entry reaches its head. A
write buffer probe (`access WRITE BUFFER, hit`) and the DTLB lookup are **not**
SRAM accesses and never take part in the port arbitration.

---

## Case SH-READ-READ (older store's L1D access and younger load's read, same cycle)

Assumes an older store and a younger load are the only two accesses in flight,
both aligned and resident, the store not speculative and the ISB head at its
capture cycle, its write buffer entry the head when it commits; the load is
issued on that capture cycle, so the store's read and the load's read want the
single L1D port in the same cycle and the load's read is ranked first.

| Instruction | T1 | T2 | T3 | T4 | T5 | T6 |
|:---|:--:|:--:|:--:|:--:|:--:|:--:|
| `sw x5, 0(x1)` O | [ E1 ]<br/>**AGU** output VA<br/>allocate **ISB**<br/>(speculative=0) | [ E2 ]<br/>access **DTLB**, hit<br/>**DTLB** output PA | [ E3 ]<br/>**ISB** capture PA<br/>**ISB** access **L1D** SRAM, blocked<br/>(load's SRAM read has priority) | [ ISB ]<br/>access **L1D** SRAM<br/>drive RoB done output | [ ISB ]<br/>**L1D** tag hit<br/>**L1D** output cache line<br/>output store data<br/>allocate **WRITE BUFFER** | [ WRITE BUFFER ]<br/>Store commit<br/>merge store data into cache line<br/>write **L1D** SRAM |
| `ld x6, 0(x2)` Y |  |  | [ E1 ]<br/>**AGU** output VA<br/>access **L1D** SRAM, accepted | [ E2 ]<br/>access **DTLB**, hit<br/>**L1D** tag hit<br/>**L1D** output cache line | [ E3 ]<br/>**ISB** check PA for forwarding, hit<br/>**ISB** forward store data | [ E4 ]<br/>**LD DATA MERGE** merge **ISB** data into **L1D** data<br/>drive RoB done output<br/>drive CDB<br/>drive bypass output |

- **`T3` cycle:** one port, two reads, and the load's read is ranked first. The
  load does not stall; it is accepted and takes the line as it was **before**
  the store's L1D write. The store keeps its access line and is blocked.
- **`T4` cycle (O):** the L1D access is issued again, now alone, and the completion
  is driven here.
- **`T5` cycle (O):** the read returns; the tag result and the line are available
  and the bytes the store contributes go into the new write buffer entry.
- **`T5` cycle (Y):** the entry is still live in the ISB, so the store's bytes
  come from there — the write buffer entry is only being allocated in this cycle.
- **`T6` cycle (Y):** the merge combines those bytes with the line read at `T3`
  and drives the three outputs; the store commits in the same cycle.

## Case SH-WRITE-READ (the load's read collides with the older store's L1D write)

Assumes an older store and a younger load are the only two accesses in flight,
both aligned and resident, with the store's write buffer entry the head when
it commits; the load is issued four cycles after the store, so its read lands
on the store's `write L1D SRAM` cycle and the write wins the single port.

| Instruction | T1 | T2 | T3 | T4 | T5 | T6 | T7 | T8 |
|:---|:--:|:--:|:--:|:--:|:--:|:--:|:--:|:--:|
| `sw x5, 0(x1)` O | [ E1 ]<br/>**AGU** output VA<br/>allocate **ISB**<br/>(speculative=0) | [ E2 ]<br/>access **DTLB**, hit<br/>**DTLB** output PA | [ E3 ]<br/>**ISB** capture PA<br/>**ISB** access **L1D** SRAM | [ ISB ]<br/>**L1D** tag hit<br/>**L1D** output cache line<br/>output store data<br/>allocate **WRITE BUFFER**<br/>drive RoB done output | [ WRITE BUFFER ]<br/>Store commit<br/>merge store data into cache line<br/>write **L1D** SRAM, accepted |  |  |  |
| `ld x6, 0(x2)` Y |  |  |  |  | [ E1 ]<br/>stall<br/>**AGU** output VA<br/>access **L1D** SRAM, blocked<br/>(SRAM write has priority) | [ E1 ]<br/>**AGU** output VA<br/>access **L1D** SRAM | [ E2 ]<br/>access **DTLB**, hit<br/>**L1D** tag hit<br/>**L1D** output cache line | [ E3 ]<br/>drive RoB done output<br/>drive CDB<br/>drive bypass output |

- **`T5` cycle:** the write and the read arrive together and the write wins. The
  load's read is blocked, so the line it eventually reads is the **new** one.
- **`T6` cycle:** the read is issued again, alone.
- From there the load is the plain direct path: it never forwards, because the
  store's bytes are already in the line it read.

## Case SH-MSHR-FULL (the miss cannot be recorded — `A-L-M` waits in `E2`)

Assumes the only other accesses in flight are older ones on other cache lines
that hold every MSHR entry, while this load is aligned, its translation
resident and its cache line absent; the miss is detected but cannot be
recorded, so the instruction stalls at `E2` with `wait for MSHR slot` until
`Tvacant`, and from there the timing is `A-L-M`'s, shifted.

| Instruction | T1 | T2 | … | Tvacant | Tvacant+1 | … | Tresp | … | Twb | … | Twrite |
|:---|:--:|:--:|:--:|:--:|:--:|:--:|:--:|:--:|:--:|:--:|:--:|
| `ld x5, 0(x1)` | [ E1 ]<br/>**AGU** output VA<br/>access **L1D** SRAM | [ E2 ]<br/>stall<br/>access **DTLB**, hit<br/>**L1D** tag miss<br/>wait for **MSHR** slot | [ E2 ]<br/>stall<br/>access **DTLB**, hit<br/>**L1D** tag miss<br/>wait for **MSHR** slot | [ E2 ]<br/>access **DTLB**, hit<br/>**L1D** tag miss<br/>allocate **MSHR** | [ MSHR ]<br/>emit NoC request | [ MSHR ]<br/>wait for NoC response | [ MSHR ]<br/>receive NoC response<br/>write **DPB** | [ MSHR ]<br/>wait until at head | [ MSHR ]<br/>allocate **WRITE BUFFER**<br/>**DPB** output cache line | [ WRITE BUFFER ]<br/>wait until at head | [ WRITE BUFFER ]<br/>write **L1D** SRAM<br/>drive RoB done output<br/>drive CDB<br/>drive bypass output |

- **`T2` / `…` cycles:** the miss cannot be recorded, so nothing is `allocate`d
  and the op never reaches `E3`. It keeps the lines that state why.
- **`Tvacant` cycle:** a slot exists → `allocate MSHR`. Everything after it is
  `A-L-M` shifted by `Tvacant - T2`.
- **`Tresp` / `Tvacant+…`:** having a slot is not being served — the entry still
  waits for the MSHR head, then for the write buffer head.

## Case SH-ISB-FULL (the store entry cannot be allocated — `A-S-H` waits in `E1`)

Assumes the only other accesses in flight are older ones that hold every ISB
entry, while this store is aligned, not speculative, its translation resident
and its cache line present; `E1` cannot complete until a slot frees at
`Tvacant`, and the entry must then still reach the head at `Thead` before it
takes its L1D access.

| Instruction | T1 | … | Tvacant | Tvacant+1 | Tvacant+2 | Tvacant+3 | … | Thead | Thead+1 | Thead+2 |
|:---|:--:|:--:|:--:|:--:|:--:|:--:|:--:|:--:|:--:|:--:|
| `sd x5, 0(x1)` | [ E1 ]<br/>stall<br/>wait for **ISB** slot<br/>(speculative=0) | [ E1 ]<br/>stall<br/>wait for **ISB** slot<br/>(speculative=0) | [ E1 ]<br/>**AGU** output VA<br/>allocate **ISB**<br/>(speculative=0) | [ E2 ]<br/>access **DTLB**, hit<br/>**DTLB** output PA | [ E3 ]<br/>**ISB** capture PA | [ ISB ]<br/>drive RoB done output<br/>wait until at head | [ ISB ]<br/>wait until at head | [ ISB ]<br/>access **L1D** SRAM | [ ISB ]<br/>**L1D** tag hit<br/>**L1D** output cache line<br/>output store data<br/>allocate **WRITE BUFFER** | [ WRITE BUFFER ]<br/>Store commit<br/>merge store data into cache line<br/>write **L1D** SRAM |

- **`T1` / `…` cycles:** the address is ready at the AGU output, but without an
  ISB slot the entry cannot exist, so `E1` never completes.
- **`Tvacant` cycle:** a slot exists → `E1` completes and the entry is allocated.
- **`Tvacant+2` cycle:** the address is captured — with **no** SRAM access,
  because the entry is not the ISB head yet and a store only accesses the cache line at the head.
- **`Tvacant+3` cycle:** the entry holds a physical address, so the completion is
  driven here; it still has to wait for the head.
- **`Thead` cycle:** the entry becomes the head and takes its L1D access.

## Case SH-WB-FULL (the install cannot get a write buffer slot — `A-L-M` waits)

Assumes the only other accesses in flight are older ones that hold every write
buffer entry, while this load is aligned, its translation resident, its cache
line absent, and the MSHR head when the response arrives; the install cannot
happen, so the entry waits with `wait for WRITE BUFFER slot` until `Tvacant`
and then still needs the head at `Thead`.

| Instruction | T1 | T2 | T3 | … | Tresp | Tresp+1 | … | Tvacant | … | Thead |
|:---|:--:|:--:|:--:|:--:|:--:|:--:|:--:|:--:|:--:|:--:|
| `ld x5, 0(x1)` | [ E1 ]<br/>**AGU** output VA<br/>access **L1D** SRAM | [ E2 ]<br/>access **DTLB**, hit<br/>**L1D** tag miss<br/>allocate **MSHR** | [ MSHR ]<br/>emit NoC request | [ MSHR ]<br/>wait for NoC response | [ MSHR ]<br/>receive NoC response<br/>write **DPB** | [ MSHR ]<br/>wait for **WRITE BUFFER** slot | [ MSHR ]<br/>wait for **WRITE BUFFER** slot | [ MSHR ]<br/>allocate **WRITE BUFFER**<br/>**DPB** output cache line | [ WRITE BUFFER ]<br/>wait until at head | [ WRITE BUFFER ]<br/>write **L1D** SRAM<br/>drive RoB done output<br/>drive CDB<br/>drive bypass output |

- **`Tresp+1` / `…` cycles:** the line is in the DPB but there is no write buffer
  slot, so the install cannot happen and the entry repeats its wait.
- **`Tvacant` cycle:** a slot exists → `allocate WRITE BUFFER`, the line moving
  from the DPB into the new entry.
- **`Thead` cycle:** the entry reaches the write buffer head, writes the line and
  drives the completion.

### Variant: the same full write buffer for a store (`A-S-H` commits late)

Assumes the only other accesses in flight are older ones that hold every write
buffer entry, while this store is aligned, not speculative and resident, and
already the ISB head; it captures its address, reports its completion, and
defers its L1D access until a slot frees at `Tvacant`.

| Instruction | T1 | T2 | T3 | T4 | … | Tvacant | Tvacant+1 | Tvacant+2 |
|:---|:--:|:--:|:--:|:--:|:--:|:--:|:--:|:--:|
| `sd x5, 0(x1)` | [ E1 ]<br/>**AGU** output VA<br/>allocate **ISB**<br/>(speculative=0) | [ E2 ]<br/>access **DTLB**, hit<br/>**DTLB** output PA | [ E3 ]<br/>**ISB** capture PA | [ ISB ]<br/>drive RoB done output | [ ISB ]<br/>wait for **WRITE BUFFER** slot | [ ISB ]<br/>access **L1D** SRAM | [ ISB ]<br/>**L1D** tag hit<br/>**L1D** output cache line<br/>output store data<br/>allocate **WRITE BUFFER** | [ WRITE BUFFER ]<br/>Store commit<br/>merge store data into cache line<br/>write **L1D** SRAM |

- **`T3` cycle:** the address is captured but no L1D access is taken — without a
  write buffer slot the entry has nowhere to go.
- **`T4` cycle:** the completion is driven; it does not depend on the slot.
- **`Tvacant` cycle:** a slot exists, so the L1D access is finally issued.
- **`Tvacant+1` cycle:** the read returns, the bytes the store contributes are
  output, and the write buffer entry is allocated in the same cycle.

## Case SH-WB-ALLOC-CONFLICT (the write buffer can take one entry per cycle — the store wins)

Assumes an older store and a younger load are the only two accesses in flight,
both aligned and resident, the store not speculative on a present cache line
whose write buffer entry it builds, the load on an absent cache line and the
MSHR head when the response arrives; the store takes its L1D access on the
cycle that response arrives, so both ask for a write buffer entry in the next
cycle, at `Talloc`.

| Instruction | T1 | T2 | T3 | T4 | … | Talloc-1 | Talloc | Talloc+1 | Talloc+2 |
|:---|:--:|:--:|:--:|:--:|:--:|:--:|:--:|:--:|:--:|
| `sd x5, 0(x1)` O | [ E1 ]<br/>**AGU** output VA<br/>allocate **ISB**<br/>(speculative=0) | [ E2 ]<br/>access **DTLB**, hit<br/>**DTLB** output PA | [ E3 ]<br/>**ISB** capture PA | [ ISB ]<br/>drive RoB done output | [ ISB ]<br/>wait until at head | [ ISB ]<br/>access **L1D** SRAM | [ ISB ]<br/>**L1D** tag hit<br/>**L1D** output cache line<br/>output store data<br/>allocate **WRITE BUFFER**, accepted | [ WRITE BUFFER ]<br/>Store commit<br/>merge store data into cache line<br/>write **L1D** SRAM |  |
| `ld x6, 0(x2)` Y |  | [ E1 ]<br/>**AGU** output VA<br/>access **L1D** SRAM | [ E2 ]<br/>access **DTLB**, hit<br/>**L1D** tag miss<br/>allocate **MSHR** | [ MSHR ]<br/>emit NoC request | [ MSHR ]<br/>wait for NoC response | [ MSHR ]<br/>receive NoC response<br/>write **DPB** | [ MSHR ]<br/>allocate **WRITE BUFFER**, blocked<br/>(**L1D** cache line has priority) | [ MSHR ]<br/>allocate **WRITE BUFFER**<br/>**DPB** output cache line | [ WRITE BUFFER ]<br/>write **L1D** SRAM<br/>drive RoB done output<br/>drive CDB<br/>drive bypass output |

- **`Talloc-1` cycle:** the store becomes the ISB head, so it takes its L1D access
  here; the load receives its response and parks the line in the DPB. Only the
  store can install, so nothing has collided yet.
- **`Talloc` cycle:** both want a write buffer entry. The store wins —
  `allocate WRITE BUFFER, accepted`, no misc note — and the load's request is
  `allocate WRITE BUFFER, blocked` with
  `(L1D cache line has priority)`. The load's line stays in the DPB; the data
  itself needs no retry action, because the entry is what is missing.
- **`Talloc+1` cycle:** the load gets its entry; nobody else asks for one, so
  `allocate WRITE BUFFER` carries **no** result, and the line moves out of the
  DPB. The store meanwhile commits.
- **`Talloc+2` cycle:** the load writes its line and drives the three outputs.
  The two L1D writes do not collide — they are a cycle apart.
- The precedence is a property of the **source**, not of age: the L1D line
  always wins over the DPB line, because the store's bytes are ready while the
  refilled line can be held.

## Case SH-ISB-FWD-CONFLICT (two loads want the ISB's forwarding data, same cycle)

Assumes four accesses in flight: two older stores not authorized yet, one on
each load's cache line, and the two loads behind them; the older load's cache
line is absent and its refill owns the MSHR and the write buffer, the younger
load's cache line is present, and the younger load is issued on the cycle the
older one receives its response, so both want the ISB's forwarding data on the
older load's L1D write cycle.

| Instruction | T1 | T2 | T3 | T4 | … | Tresp | Tresp+1 | Tresp+2 | Tresp+3 | Tresp+4 |
|:---|:--:|:--:|:--:|:--:|:--:|:--:|:--:|:--:|:--:|:--:|
| `ld x7, 0(x1)` O | [ E1 ]<br/>**AGU** output VA<br/>access **L1D** SRAM | [ E2 ]<br/>access **DTLB**, hit<br/>**L1D** tag miss<br/>allocate **MSHR** | [ MSHR ]<br/>emit NoC request | [ MSHR ]<br/>wait for NoC response | [ MSHR ]<br/>wait for NoC response | [ MSHR ]<br/>receive NoC response<br/>write **DPB** | [ MSHR ]<br/>allocate **WRITE BUFFER**<br/>**DPB** output cache line | [ WRITE BUFFER ]<br/>write **L1D** SRAM<br/>output cache line to **E4**<br/>**ISB** check PA for forwarding, hit<br/>**ISB** forward store data to **E4** | [ E4 ]<br/>**LD DATA MERGE** merge **ISB** data into **WRITE BUFFER** data<br/>drive RoB done output<br/>drive CDB<br/>drive bypass output |  |
| `ld x8, 0(x2)` Y |  |  |  |  |  | [ E1 ]<br/>**AGU** output VA<br/>access **L1D** SRAM | [ E2 ]<br/>access **DTLB**, hit<br/>**L1D** tag hit<br/>**L1D** output cache line | [ E3 ]<br/>stall<br/>**ISB** check PA for forwarding, hit<br/>(**ISB** forwarding to refill bypass load has priority) | [ E3 ]<br/>**ISB** check PA for forwarding, hit<br/>**ISB** forward store data | [ E4 ]<br/>**LD DATA MERGE** merge **ISB** data into **L1D** data<br/>drive RoB done output<br/>drive CDB<br/>drive bypass output |

- **`Tresp` cycle (O):** the response arrives and the line parks in the DPB. The
  younger load is accepted in the same cycle, so its read follows one cycle
  later.
- **`Tresp+1` cycle:** the older load's entry takes a write buffer slot and the
  line moves out of the DPB; the younger load's read returns its line, which is
  already resident.
- **`Tresp+2` cycle:** the older load's L1D write also hands its line to `E4`
  (`output cache line to E4`), so both loads want to merge in the same cycle and
  both check the ISB. Each one matches the store on its own line, so both readings
  are genuine hits — the collision is not an address question. The ISB can only
  hand out one forwarding word, and the refill bypass load gets it: O writes
  `ISB forward store data to E4` with no result. Y keeps its check line but
  writes no forward action; `E3` holds in `stall`, with
  `(ISB forwarding to refill bypass load has priority)` saying what it is waiting
  for. Losing the data does not cost it the check, and it is `E3` that decides it
  cannot proceed, not the ISB.
- **`Tresp+3` cycle (Y):** the check is repeated and this time the data comes, so
  `ISB forward store data` carries no result. Nothing else wants the output.
- **`Tresp+3` cycle (O):** the merge combines the forwarded bytes with the line
  handed over at `Tresp+2` and drives the three outputs.
- **`Tresp+4` cycle (Y):** the merge combines its forwarded bytes with the line
  read at `Tresp+1` and drives the three outputs. The two loads drive one cycle
  apart, so neither drive set is contended.

## Case SH-CDB-BACKPRESSURE (the completion cannot be driven — `A-L-H` holds `E3`)

Assumes the load is the only access in flight that still needs service,
aligned, its translation resident and its cache line present, but another
load's result occupies the CDB on the cycle this one is ready; `E3` holds with
`drive CDB, blocked` until the CDB frees at `Tready`, and RoB done is withheld
with it.

| Instruction | T1 | T2 | T3 | … | Tready |
|:---|:--:|:--:|:--:|:--:|:--:|
| `ld x5, 0(x1)` | [ E1 ]<br/>**AGU** output VA<br/>access **L1D** SRAM | [ E2 ]<br/>access **DTLB**, hit<br/>**L1D** tag hit<br/>**L1D** output cache line | [ E3 ]<br/>stall<br/>drive CDB, blocked<br/>drive bypass output<br/>(CDB backpressure) | [ E3 ]<br/>stall<br/>drive CDB, blocked<br/>(CDB backpressure) | [ E3 ]<br/>drive RoB done output<br/>drive CDB |

- **`T3` cycle:** the result is ready, so `E3` holds in the `stall` state and the
  drive reads `drive CDB, blocked`: the CDB is busy and that is exactly the
  back-pressure, hence the misc note `(CDB backpressure)`. The completion is
  therefore not visible to BE and **RoB done is not driven** — RoB done goes out
  only together with the CDB. The bypass is not back-pressured, so it is driven
  here.
- **`…` cycle:** the attempt repeats, again as `stall` + `drive CDB,
  blocked`; the bypass is no longer needed, because the data is already on that
  path.
- **`Tready` cycle:** the CDB is free, so the result and RoB done are driven
  together and BE accepts the completion.
