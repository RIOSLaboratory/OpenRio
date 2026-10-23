<style>
table { display: block; overflow-x: auto; width: 100%; } th, td { white-space:
nowrap !important; } </style>

# Cache Single-op Timing Diagrams (Table A)

Rules: `../RULES.md`. Columns are cycles (**T1 = E1 accept cycle**); each case is
one table for a **single** access with nothing else in the picture.

- **Load** — `A-L-H` cache line present, `A-L-M` cache line not present (plus
  the MSHR / write buffer head variant), `A-L-T` DTLB miss, `A-L-E` fault.
- **Store** — `A-S-H` cache line present (plus the `st_br_resolve=0`
  late-wakeup variant), `A-S-M` cache line not present, `A-S-T` DTLB miss,
  `A-S-E` fault.
- **AMO** — `A-AMO-STALL` prefix, then `A-AMO-H` / `A-AMO-M` / `A-AMO-T` /
  `A-AMO-E`.
- **Rejected in `E1`** — `A-MISALIGN`, for load / store / AMO alike.
- **Fence** — `A-FNC`; no cache access, but it waits in `E1` while the ISB and the
  write buffer are not empty.

---

## Case A-L-H (load, DTLB hit, cache line present, direct)

Assumes the load is the only access in flight, aligned, with its translation
resident and its cache line present; the read returns and the tag compares in
`E2`, nothing needs merging, and the completion is driven in `E3`.

| Instruction | T1 | T2 | T3 |
|:---|:--:|:--:|:--:|
| `ld x5, 0(x1)` | [ E1 ]<br/>**AGU** output VA<br/>access **L1D** SRAM | [ E2 ]<br/>access **DTLB**, hit<br/>**L1D** tag hit<br/>**L1D** output cache line | [ E3 ]<br/>drive RoB done output<br/>drive CDB<br/>drive bypass output |

- **T1 cycle:** the AGU forms the address (`VA`); the cache read is issued.
- **T2 cycle:** translation hits, the read returns, and the tag compare hits.
  `access DTLB, hit` states its own result on the same line, because the
  translation lookup happens in this cycle; `L1D tag hit` and `L1D output cache line` are
  the results of the read issued in `T1`, so each gets its own line. The data bus is the full L1D width, **64 bytes (512 bits)**; the bytes
  the access actually needs are selected by the data-shape module on the way to
  the completion.
- **T3 cycle:** nothing to merge → the direct path. The result is driven out in
  this one cycle: RoB done, the CDB and the bypass. BE therefore sees the
  completion here, and no separate presentation cycle follows.
- Nothing is written back: a hit read does not touch the cache.

## Case A-L-M (load, DTLB hit, cache line not present)

Assumes the load is the only access in flight, aligned, its translation
resident and its cache line absent; the miss is then the only MSHR entry and
later the only write buffer entry, so that entry is allocated one cycle after
the response and the cache line is written to L1D the cycle after that.

| Instruction | T1 | T2 | T3 | … | Tresp | Tresp+1 | Tresp+2 |
|:---|:--:|:--:|:--:|:--:|:--:|:--:|:--:|
| `ld x5, 0(x1)` | [ E1 ]<br/>**AGU** output VA<br/>access **L1D** SRAM | [ E2 ]<br/>access **DTLB**, hit<br/>**L1D** tag miss<br/>allocate **MSHR** | [ MSHR ]<br/>emit NoC request | [ MSHR ]<br/>wait for NoC response | [ MSHR ]<br/>receive NoC response<br/>write **DPB** | [ MSHR ]<br/>allocate **WRITE BUFFER**<br/>**DPB** output cache line | [ WRITE BUFFER ]<br/>write **L1D** SRAM<br/>drive RoB done output<br/>drive CDB<br/>drive bypass output |

- **T1 cycle:** the AGU forms the address; the cache read is issued.
- **T2 cycle:** translation hits; the cache read and tag compare → **miss**. The
  miss path is taken in `E2` (`E3` is skipped for a miss), so the MSHR entry is
  allocated at the **T2→T3** edge — one entry per access, the only record of the
  miss.
- **T3 cycle:** the request is emitted to NoC. From this cycle the MSHR entry owns
  the instruction, and it keeps owning it until the install.
- **`…` cycle:** the entry waits for the response.
- **`Tresp` cycle:** the response is received and the line is written into the
  DPB at the entry's own index — the DPB is the data copy of the MSHR entry, so
  it is never an owner.
- **`Tresp+1` cycle:** the entry is the MSHR head, so the write buffer takes it
  over (`allocate WRITE BUFFER`); the DPB outputs the line into that new entry.
- **`Tresp+2` cycle:** the entry is the write buffer head and its L1D write mode
  bit marks a **refill**, so the cache evicts a victim and fills the whole cache
  line instead of comparing a tag. The same bytes go straight to the load data
  path as the **refill bypass**. RoB done, CDB and bypass are driven in this
  one cycle, so BE sees the completion here — the access never replays and never
  reads the cache a second time.
- **Younger same-line miss.** A second access that misses the same line gets its
  **own** MSHR entry (entries are never shared by line) and issues no request of
  its own. The same response resolves it, but it must **replay** instead of using
  the refill bypass: the earliest is the cell after the line's `write L1D SRAM`
  (`Tresp+3` here), and only once it is the MSHR head. Only the oldest entry of a
  line can use the refill bypass. An older same-line store usually owns that
  refill itself, because a store that is the ISB head **and** authorized accesses the
  cache line and takes the MSHR entry; but a store that cannot take that access
  — for example one that is not authorized yet, or one that is authorized but not
  the ISB head — leaves the refill to the load, and the refill bypass is then
  merged with that store's bytes instead (`B1-REFILL-FWD`).

### Variant: the entry is not at the head of the MSHR / write buffer

Assumes the load is aligned, its translation resident and its cache line
absent, and that the only other accesses in flight are two older ones on other
cache lines, occupying the MSHR and the write buffer; the NoC request and the
response are the load's own, but the write buffer entry is allocated only at
`Twb` and the cache line is written to L1D only at `Twrite`.

| Instruction | T1 | T2 | T3 | … | Tresp | … | Twb | … | Twrite |
|:---|:--:|:--:|:--:|:--:|:--:|:--:|:--:|:--:|:--:|
| `ld x5, 0(x1)` | [ E1 ]<br/>**AGU** output VA<br/>access **L1D** SRAM | [ E2 ]<br/>access **DTLB**, hit<br/>**L1D** tag miss<br/>allocate **MSHR** | [ MSHR ]<br/>emit NoC request | [ MSHR ]<br/>wait for NoC response | [ MSHR ]<br/>receive NoC response<br/>write **DPB** | [ MSHR ]<br/>wait until at head | [ MSHR ]<br/>allocate **WRITE BUFFER**<br/>**DPB** output cache line | [ WRITE BUFFER ]<br/>wait until at head | [ WRITE BUFFER ]<br/>write **L1D** SRAM<br/>drive RoB done output<br/>drive CDB<br/>drive bypass output |

- **`Tresp` cycle:** the response is received and the line lands in the DPB (it
  is indexed by the MSHR id, so it does not need the head). The entry is **not**
  the MSHR head, so it cannot be installed into the write buffer yet.
- **`Tresp…Twb-1`:** the completed entry waits its turn in the MSHR FIFO —
  `wait until at head`.
- **`Twb` cycle:** the entry reaches the MSHR head → `allocate WRITE BUFFER`; the
  write buffer entry is filled from the DPB.
- **`Twb…Twrite-1`:** the entry waits its turn in the write buffer FIFO —
  `wait until at head`.
- **`Twrite` cycle:** the entry reaches the write buffer head, so the line is
  written into the cache at this cell's edge and the completion is driven in the
  same cycle (RoB done, CDB, bypass).
- If no queue has an older entry, `Twb = Tresp+1` and `Twrite = Twb+1` — that
  degenerate case is exactly the main figure above.
- A younger same-line miss is *not* in this figure: it has its own entry and
  replays at `Twrite+1` at the earliest, once it is the MSHR head.

## Case A-L-T (load, DTLB miss)

Assumes the load is the only access in flight, aligned, its cache line
present, and its translation missing with the TMQ free; the instruction stalls
at `E2` for the whole walk, and the DTLB access and the L1D access both
complete on the cycle the response arrives.

| Instruction | T1 | T2 | T3 | … | Tpte | Tpte+1 |
|:---|:--:|:--:|:--:|:--:|:--:|:--:|
| `ld x5, 0(x1)` | [ E1 ]<br/>**AGU** output VA<br/>access **L1D** SRAM | [ E2 ]<br/>stall<br/>access **DTLB**, miss<br/>allocate **TMQ** | [ E2 ]<br/>stall<br/>**TMQ** emit MMU request | [ E2 ]<br/>stall<br/>**TMQ** wait for MMU response | [ E2 ]<br/>**TMQ** receive MMU response<br/>**TMQ** write **DTLB**<br/>**L1D** tag hit<br/>**L1D** output cache line | [ E3 ]<br/>drive RoB done output<br/>drive CDB<br/>drive bypass output |

- **T2 cycle:** translation misses and the TMQ entry is allocated. The
  instruction **stays in `E2`**: the TMQ records only the MMU request, while the
  access's own state — its address, plus the bytes the read returned in `T1` —
  stays in the `E2` registers. Hence the owner of `T2` through `Tpte-1` is the
  stage, in the `stall` state, and not the TMQ.
- **T3 cycle:** the TMQ emits the request. `E2` is still stalled; the action
  belongs to the TMQ, so it carries the TMQ as its subject.
- **`…` cycle:** the TMQ waits for the response; `E2` remains stalled.
- **`Tpte` cycle:** the response is received and the TMQ writes the translation
  into the DTLB. With the response in hand, `E2` completes in this cycle, so the
  stall state is gone — the cell is a plain `[ E2 ]` — and it also yields the
  results the held registers now give: `L1D tag hit` and `L1D output cache line`
  from the read issued in `T1`.
- **`Tpte+1` cycle:** the access goes **straight into `E3`** — it never left
  `E2`, so there is no `E1` replay and no second `E2`. The result is driven out
  in this one cycle (RoB done, CDB, bypass), so BE sees the completion here.
- The MMU actions use the same three verbs as the L2 path — `emit`, `wait for`,
  `receive` — with the TMQ as their subject, because the stage, not the queue,
  owns the instruction.

## Case A-L-E (load, fault)

Assumes the load is the only access in flight, aligned, and its translation
hits but the access is not permitted — the virtual page has no physical
mapping, or the page forbids this access; the fault is therefore known in `E2`
and replaces the completion.

| Instruction | T1 | T2 | T3 |
|:---|:--:|:--:|:--:|
| `ld x5, 0(x1)` | [ E1 ]<br/>**AGU** output VA<br/>access **L1D** SRAM | [ E2 ]<br/>access **DTLB**, page/access fault detected | [ E3 ]<br/>drive exception output |

- **T1 cycle:** the AGU forms the address (`VA`); the cache read is issued.
- **T2 cycle:** the translation hits but the memory attributes reject the access,
  so the read's outcome is discarded: **no `L1D tag hit` and no
  `L1D output cache line`** are drawn, even though the read did happen in `T1`. The
  fault is detected by the translation lookup itself, so its result sits on that
  action's own line — `access DTLB, page/access fault detected`.
- **T3 cycle:** the access faults and the exception is driven straight out. RoB
  done is **not** driven: an exception replaces it, the two are mutually
  exclusive. No CDB, no bypass either — the completion carries no data.

## Case A-MISALIGN (misaligned load / store / AMO)

Assumes the load, store or AMO is the only access in flight and its address is
misaligned; the alignment checker rejects it in `E1`, before any address is
formed.

| Instruction | T1 | T2 | T3 |
|:---|:--:|:--:|:--:|
| `ld x5, 0(x1)` / `sd x5, 0(x1)` / `amo x5, x6, (x1)` | [ E1 ]<br/>**MISALIGN CTRL** detect misalignment | [ E2 ] | [ E3 ]<br/>drive exception output |

- **T1 cycle:** the alignment check rejects the access **before the address is
  even formed** — the AGU is not used, so no `AGU output VA` appears. There is
  **no SRAM access**, no store entry, no TMQ / MSHR entry and no refill.
- **T2 cycle:** the rejection travels through `E2`; the stage is the owner but it
  produces nothing, so the cell is the owner line alone.
- **T3 cycle:** the exception is driven straight out. RoB done is **not** driven
  — an exception replaces it — and neither the CDB nor the bypass is used.
- Same figure for all three classes; only the reported cause differs —
  `CAUSE_LD_MISALIGN` for a load, `CAUSE_ST_MISALIGN` for a store or an AMO.
- Because nothing was allocated, there is no entry to free: the access leaves no
  state behind.

## Case A-S-H (store, DTLB hit, cache line present)

Assumes the store is the only access in flight, aligned, not speculative, with
its translation resident and its cache line present; it is therefore the ISB
head at its capture cycle and takes its L1D access there, and its own write
buffer entry is the head when it commits.

| Instruction | T1 | T2 | T3 | T4 | T5 |
|:---|:--:|:--:|:--:|:--:|:--:|
| `sd x5, 0(x1)` | [ E1 ]<br/>**AGU** output VA<br/>allocate **ISB**<br/>(speculative=0) | [ E2 ]<br/>access **DTLB**, hit<br/>**DTLB** output PA | [ E3 ]<br/>**ISB** capture PA<br/>**ISB** access **L1D** SRAM | [ ISB ]<br/>**L1D** tag hit<br/>**L1D** output cache line<br/>output store data<br/>allocate **WRITE BUFFER**<br/>drive RoB done output | [ WRITE BUFFER ]<br/>Store commit<br/>merge store data into cache line<br/>write **L1D** SRAM |

- **T1 cycle:** the AGU forms the address (`VA`) and the store entry is allocated.
  The entry is not speculative, so the last line of the cell says
  `(speculative=0)`.
- **T2 cycle:** translation hits and the physical address comes out of the DTLB.
- **T3 cycle:** the entry keeps its ISB slot and captures the address, and — being
  the head and not speculative — it takes its L1D access in the same cycle. The write
  buffer is probed first (a miss is not drawn); on a miss the tag read is issued
  on the same cycle. Both actions belong to the ISB, so both carry it as their
  subject.
- **T4 cycle:** the ISB owns the instruction. The read returns `L1D tag hit` and
  `L1D output cache line` — the whole line, because the cache is written a full line at
  a time and never by byte masking. The entry then outputs the bytes the store
  itself contributes (`output store data`), allocates its write buffer entry, and
  reports the completion: RoB done only — a store drives no CDB and no bypass,
  because it has no data to return.
- **T5 cycle:** the write buffer owns the instruction, and its L1D write mode
  bit marks a **hit write**, so the cache compares the tag it takes from the PA
  in the addressed set. It merges the store's bytes into the cache line it holds
  and performs the L1D write of the completed cache line, all in this one cycle;
  `Store commit` is its state.

### Variant: `st_br_resolve=0` (speculative at accept, resolved by a store wakeup)

Assumes the store is the only access in flight, aligned, its cache line
present, but BE has not authorized it yet, so it is accepted speculative; it
captures its address, reports its completion, and takes its L1D access only
once the wakeup arrives at `Twk`.

| Instruction | T1 | T2 | T3 | T4 | … | Twk | Twk+1 | Twk+2 |
|:---|:--:|:--:|:--:|:--:|:--:|:--:|:--:|:--:|
| `sd x5, 0(x1)` | [ E1 ]<br/>**AGU** output VA<br/>allocate **ISB**<br/>(speculative=1) | [ E2 ]<br/>access **DTLB**, hit<br/>**DTLB** output PA | [ E3 ]<br/>**ISB** capture PA | [ ISB ]<br/>drive RoB done output | [ ISB ]<br/>wait for wakeup from BE | [ ISB ]<br/>receive wakeup from BE<br/>access **L1D** SRAM | [ ISB ]<br/>**L1D** tag hit<br/>**L1D** output cache line<br/>output store data<br/>allocate **WRITE BUFFER** | [ WRITE BUFFER ]<br/>Store commit<br/>merge store data into cache line<br/>write **L1D** SRAM |

- **T1 cycle:** the entry is accepted as speculative (`(speculative=1)`).
- **T2 cycle:** translation hits; the address is known.
- **T3 cycle:** the address is captured. The L1D access cannot be taken: the entry is
  the head, but a speculative store is not allowed to read the cache yet.
- **T4 cycle:** the entry holds a physical address, so the completion is reported
  here — `drive RoB done output` — decoupled from both the access and the commit.
- **`…` cycle:** the entry waits in the ISB for its wakeup.
- **`Twk` cycle:** the wakeup arrives and the access is taken in the same cycle.
  The ISB owns the instruction here, so the access line carries no subject.
- **`Twk+1` cycle:** the read returns the line, the entry outputs its own bytes
  and allocates its write buffer entry.
- **`Twk+2` cycle:** the write buffer merges and writes the line. The commit is
  therefore two cycles after the wakeup, while the completion was already
  reported at `T4`.

## Case A-S-M (store, DTLB hit, cache line not present)

Assumes the store is the only access in flight, aligned, not speculative, with
its translation resident and its cache line absent; its miss is the only MSHR
entry, so nothing is ahead of it when the write buffer entry is allocated or
when the cache line is written to L1D.

| Instruction | T1 | T2 | T3 | T4 | T5 | … | Tresp | Tresp+1 | Tresp+2 |
|:---|:--:|:--:|:--:|:--:|:--:|:--:|:--:|:--:|:--:|
| `sd x5, 0(x1)` | [ E1 ]<br/>**AGU** output VA<br/>allocate **ISB**<br/>(speculative=0) | [ E2 ]<br/>access **DTLB**, hit<br/>**DTLB** output PA | [ E3 ]<br/>**ISB** capture PA<br/>**ISB** access **L1D** SRAM | [ ISB ]<br/>**L1D** tag miss<br/>allocate **MSHR**<br/>drive RoB done output | [ MSHR ]<br/>emit NoC request | [ MSHR ]<br/>wait for NoC response | [ MSHR ]<br/>receive NoC response<br/>write **DPB** | [ MSHR ]<br/>allocate **WRITE BUFFER**<br/>**DPB** output cache line<br/>**ISB** output store data | [ WRITE BUFFER ]<br/>Store commit<br/>merge store data into cache line<br/>write **L1D** SRAM |

- **T3 cycle:** the entry captures the address and takes its L1D access in the same
  cycle — write buffer probe first, then the tag read. Neither action belongs to
  the stage, so both carry the ISB as their subject.
- **T4 cycle:** the read **misses**, so an MSHR entry is allocated. The entry
  already holds a physical address, so the completion is reported here as well:
  `drive RoB done output`.
- **T5 / `…` cycles:** the MSHR owns the instruction from the request on; the
  refill latency is covered by `…`.
- **`Tresp` cycle:** the response is received and written into the DPB.
- **`Tresp+1` cycle:** the MSHR head installs, so the write buffer entry is
  allocated and filled from the DPB. In the same cycle the ISB outputs the bytes
  the store contributes — the action belongs to the ISB while the MSHR owns the
  instruction, hence the subject.
- **`Tresp+2` cycle:** the write buffer merges those bytes into the line and
  writes the whole line back. The commit is one cycle after the allocation, as in
  `A-S-H`.
- The completion (`T4`) precedes the commit: nothing after the physical address
  can fault, so BE is told early while the refill proceeds inside the cache.

## Case A-S-T (store, DTLB miss)

Assumes the store is the only access in flight, aligned, not speculative, its
cache line present, and its translation missing with the TMQ free; the
instruction stalls at `E2` for the whole walk, and the response carries the
PPN, so `E2` completes on it and the entry is injected into `E3` without a
replay.

| Instruction | T1 | T2 | T3 | … | Tpte | Tpte+1 | Tpte+2 | Tpte+3 |
|:---|:--:|:--:|:--:|:--:|:--:|:--:|:--:|:--:|
| `sd x5, 0(x1)` | [ E1 ]<br/>**AGU** output VA<br/>allocate **ISB**<br/>(speculative=0) | [ E2 ]<br/>stall<br/>access **DTLB**, miss<br/>allocate **TMQ** | [ E2 ]<br/>stall<br/>**TMQ** emit MMU request | [ E2 ]<br/>stall<br/>**TMQ** wait for MMU response | [ E2 ]<br/>**TMQ** receive MMU response<br/>**TMQ** write **DTLB**<br/>**DTLB** output PA | [ E3 ]<br/>**ISB** capture PA<br/>**ISB** access **L1D** SRAM | [ ISB ]<br/>**L1D** tag hit<br/>**L1D** output cache line<br/>output store data<br/>allocate **WRITE BUFFER**<br/>drive RoB done output | [ WRITE BUFFER ]<br/>Store commit<br/>merge store data into cache line<br/>write **L1D** SRAM |

- **T2 cycle:** translation misses and the TMQ entry is allocated; the store
  **stays in `E2`** in the `stall` state while the walk runs, exactly as in
  `A-L-T`. The TMQ holds only the request.
- **`Tpte` cycle:** the response is received, the DTLB is written, and the
  physical address comes out. `E2` completes here — no `stall` on this cell.
- **`Tpte+1` cycle:** the entry is injected straight into `E3` — the response
  already carries the PPN, so there is no `E1` replay and no second `E2`. It
  captures the address and takes its L1D access.
- **`Tpte+2` / `Tpte+3` cycles:** the same hit tail as `A-S-H`, shifted by
  `Tpte+1 - T1`.
- If the entry is speculative at accept, the access waits for the wakeup as in the
  `A-S-H` variant.

## Case A-S-E (store, fault)

Assumes the store is the only access in flight, aligned, not speculative, and
its translation hits but the access is not permitted — the virtual page has no
physical mapping, or the page forbids this access; the fault is known in `E2`
and replaces the completion.

| Instruction | T1 | T2 | T3 |
|:---|:--:|:--:|:--:|
| `sd x5, 0(x1)` | [ E1 ]<br/>**AGU** output VA<br/>allocate **ISB**<br/>(speculative=0) | [ E2 ]<br/>access **DTLB**, page/access fault detected | [ E3 ]<br/>drive exception output |

- **T1 cycle:** the entry is allocated. Whether it is speculative is still stated
  — the fault is a separate matter.
- **T2 cycle:** the translation hits but the memory attributes reject the access,
  so nothing is captured: no `DTLB output PA`. The fault is detected by the
  translation lookup itself, so its result shares that action's line.
- **T3 cycle:** the exception is driven straight out. RoB done is **not** driven —
  an exception replaces it — and neither the CDB nor the bypass is used.
- **Fault-entry lifetime (not a cycle-level effect):** the faulted entry is **not**
  freed by the store itself. A faulted head can never commit, and the only ways a
  store entry is freed are commit and flush. The faulted entry therefore
  **remains until a flush** — it is the exception it raised that makes BE flush,
  which clears the whole store buffer.


---

## AMO (read-modify-write, single op)

Source: Table A `A.3 AMO`. AMO is **serializing** in BE, so these are all
self-routing cases — there is no younger op in the pipeline. An AMO is never
speculative and reads its old value **directly from the cache in `E2`**.

## Case A-AMO-STALL (accepted while the ISB and the write buffer are not empty)

Assumes the AMO is aligned, and that the only other things in flight are older
store entries draining through the ISB and the write buffer; the AMO is
accepted but cannot leave `E1` until those are gone at `Trel`, after which it
runs the `A-AMO-H` timing.

| Instruction | T1 | … | Trel | Trel+1 | Trel+2 | Trel+3 | Trel+4 |
|:---|:--:|:--:|:--:|:--:|:--:|:--:|:--:|
| `amo x5, x6, (x1)` | [ E1 ]<br/>stall<br/>(**ISB** and **WRITE BUFFER** not empty) | [ E1 ]<br/>stall<br/>(**ISB** and **WRITE BUFFER** not empty) | [ E1 ]<br/>**AGU** output VA<br/>access **L1D** SRAM<br/>allocate **ISB**<br/>(speculative=0) | [ E2 ]<br/>access **DTLB**, hit<br/>**DTLB** output PA<br/>**L1D** tag hit<br/>**L1D** output cache line | [ E3 ]<br/>**ISB** capture PA<br/>**AMO-OP** output new value | [ ISB ]<br/>output store data<br/>allocate **WRITE BUFFER**<br/>drive RoB done output<br/>drive CDB<br/>drive bypass output | [ WRITE BUFFER ]<br/>Store commit<br/>merge store data into cache line<br/>write **L1D** SRAM |

- **`T1` cycle:** the request is accepted and the AGU forms the address, but the
  ISB and the write buffer are not empty, so the AMO cannot advance — the stage
  is in the `stall` state and the cell notes why.
- **`…` / `Trel-1`:** the same stall. The held address is not recomputed and
  nothing is re-issued.
- **`Trel` cycle:** both structures are empty, so `E1` completes: the address is
  at the AGU output, the read is issued and the ISB entry is allocated.
- **`Trel+1…`:** the normal single-op run (`A-AMO-H`).
- Why the stall exists: the AMO reads its old value straight out of the cache, so
  it must not race the write port.

## Case A-AMO-H (AMO, DTLB hit, cache line present)

Assumes the AMO is the only access in flight, aligned, with its translation
resident and its cache line present, and the ISB and the write buffer empty;
it reads the cache line in `E2`, so its completion and its commit land on
consecutive cycles.

| Instruction | T1 | T2 | T3 | T4 | T5 |
|:---|:--:|:--:|:--:|:--:|:--:|
| `amo x5, x6, (x1)` | [ E1 ]<br/>**AGU** output VA<br/>access **L1D** SRAM<br/>allocate **ISB**<br/>(speculative=0) | [ E2 ]<br/>access **DTLB**, hit<br/>**DTLB** output PA<br/>**L1D** tag hit<br/>**L1D** output cache line | [ E3 ]<br/>**ISB** capture PA<br/>**AMO-OP** output new value | [ ISB ]<br/>output store data<br/>allocate **WRITE BUFFER**<br/>drive RoB done output<br/>drive CDB<br/>drive bypass output | [ WRITE BUFFER ]<br/>Store commit<br/>merge store data into cache line<br/>write **L1D** SRAM |

- **`T2` cycle:** translation hits, the cache outputs the line, and the tag
  compare hits.
- **`T3` cycle:** the new value is computed from the read old value and the source
  operand, and the address is captured.
- **`T4` cycle:** the entry holds the address, the old and the new value, so the
  completion is driven here — RoB done, the CDB and the bypass, the **old** value
  on both data paths. In the same cycle the ISB outputs the new bytes and the
  write buffer takes them.
- **`T5` cycle:** the write buffer merges the new value into the line and writes
  it back.

## Case A-AMO-M (AMO, DTLB hit, cache line not present)

Assumes the AMO is the only access in flight, aligned, its translation
resident and its cache line absent; its refill is the only MSHR entry, the
cache line is written back clean, and the AMO then replays into a hit because
only the hit path produces its old value.

| Instruction | T1 | T2 | T3 | … | Tresp | Tresp+1 | Tresp+2 | Tresp+3 | Tresp+4 | Tresp+5 | Tresp+6 | Tresp+7 |
|:---|:--:|:--:|:--:|:--:|:--:|:--:|:--:|:--:|:--:|:--:|:--:|:--:|
| `amo x5, x6, (x1)` | [ E1 ]<br/>**AGU** output VA<br/>access **L1D** SRAM<br/>allocate **ISB**<br/>(speculative=0) | [ E2 ]<br/>access **DTLB**, hit<br/>**DTLB** output PA<br/>**L1D** tag miss<br/>allocate **MSHR** | [ MSHR ]<br/>emit NoC request | [ MSHR ]<br/>wait for NoC response | [ MSHR ]<br/>receive NoC response<br/>write **DPB** | [ MSHR ]<br/>allocate **WRITE BUFFER**<br/>**DPB** output cache line | [ WRITE BUFFER ]<br/>write **L1D** SRAM | [ E1 ]<br/>replay<br/>**AGU** output VA<br/>access **L1D** SRAM | [ E2 ]<br/>access **DTLB**, hit<br/>**DTLB** output PA<br/>**L1D** tag hit<br/>**L1D** output cache line | [ E3 ]<br/>**ISB** capture PA<br/>**AMO-OP** output new value | [ ISB ]<br/>output store data<br/>allocate **WRITE BUFFER**<br/>drive RoB done output<br/>drive CDB<br/>drive bypass output | [ WRITE BUFFER ]<br/>Store commit<br/>merge store data into cache line<br/>write **L1D** SRAM |

- **`T2` cycle:** the AMO-miss path is taken in `E2` (no `E3`) and the MSHR entry
  is allocated. The address is captured, but the read result is not, so the head
  cannot commit.
- **`T3…Tresp-1`:** the refill (`…` covers the latency) — `emit NoC request`,
  then `wait for NoC response`.
- **`Tresp` / `Tresp+1` / `Tresp+2`:** response to the DPB, install into the
  write buffer, then the line is written back. The refill line is clean, so
  there is nothing to merge at the write-back.
- **Why the AMO cannot use the refill bypass.** Its old value and its
  result-ready flag are produced only by the hit path, so even as the oldest entry
  of its line it must replay.
- **`Tresp+3…Tresp+5`:** replay (no re-allocation) → `E2` (hit now) → `E3` AMO
  hit path.
- **`Tresp+6` / `Tresp+7`:** the same done / commit tail as `A-AMO-H`.

## Case A-AMO-T (AMO, DTLB miss)

Assumes the AMO is the only access in flight, aligned, its cache line present,
and its translation missing with the TMQ free; the instruction stalls at `E2`
for the whole walk, then runs `E3` straight off the read held from `T1`.

| Instruction | T1 | T2 | T3 | … | Tpte | Tpte+1 | Tpte+2 | Tpte+3 |
|:---|:--:|:--:|:--:|:--:|:--:|:--:|:--:|:--:|
| `amo x5, x6, (x1)` | [ E1 ]<br/>**AGU** output VA<br/>access **L1D** SRAM<br/>allocate **ISB**<br/>(speculative=0) | [ E2 ]<br/>stall<br/>access **DTLB**, miss<br/>allocate **TMQ** | [ E2 ]<br/>stall<br/>**TMQ** emit MMU request | [ E2 ]<br/>stall<br/>**TMQ** wait for MMU response | [ E2 ]<br/>**TMQ** receive MMU response<br/>**TMQ** write **DTLB**<br/>**DTLB** output PA<br/>**L1D** tag hit<br/>**L1D** output cache line | [ E3 ]<br/>**ISB** capture PA<br/>**AMO-OP** output new value | [ ISB ]<br/>output store data<br/>allocate **WRITE BUFFER**<br/>drive RoB done output<br/>drive CDB<br/>drive bypass output | [ WRITE BUFFER ]<br/>Store commit<br/>merge store data into cache line<br/>write **L1D** SRAM |

- **`T2` cycle:** translation misses; the TMQ entry is allocated and the AMO
  **stays in `E2`** in the `stall` state for the whole walk. The TMQ records only
  the MMU request.
- **`Tpte` cycle:** the response is received and the DTLB is written; `E2`
  completes here and also yields the held results from the read issued in `T1`.
- **`Tpte+1` cycle:** `E3` — the new value is computed and the address captured.
  No replay: the op never left `E2`.
- **`Tpte+2` / `Tpte+3`:** the `A-AMO-H` tail.

## Case A-AMO-E (AMO, fault)

Assumes the AMO is the only access in flight, aligned, and its translation
hits but the access is not permitted — the virtual page has no physical
mapping, or the page forbids this access; the fault is known in `E2`, and the
faulted entry stays in the ISB until a flush.

| Instruction | T1 | T2 | T3 |
|:---|:--:|:--:|:--:|
| `amo x5, x6, (x1)` | [ E1 ]<br/>**AGU** output VA<br/>access **L1D** SRAM<br/>allocate **ISB**<br/>(speculative=0) | [ E2 ]<br/>access **DTLB**, page/access fault detected | [ E3 ]<br/>drive exception output |

- **`T2` cycle:** the translation hits but the memory attributes reject the
  access, so the read's outcome is discarded: no `L1D tag hit`, no cache-line
  output, no `DTLB output PA`.
- **`T3` cycle:** the exception is driven straight out. RoB done is not driven —
  an exception replaces it — and neither the CDB nor the bypass is used.
- Same shape as `A-S-E`. A **misaligned** AMO never gets here: that is caught in
  `E1` (`A-MISALIGN`).

---

## Misc (FENCE / FENCE.I)

Source: Table A `A.4 Misc`. No address access: no translation, no fault, no store
entry, no refill. A fence still waits in `E1` until the ISB and the write buffer
are empty, is recognized in `E3`, and terminates with a plain done — no data and
no exception.

## Case A-FNC (fence / fence.i)

Assumes nothing is in flight except older stores still occupying the ISB and
the write buffer; the fence holds `E1` until those are gone at `Trel`, then
passes through `E2` and retires in `E3` with a plain done.

| Instruction | T1 | … | Trel | Trel+1 | Trel+2 |
|:---|:--:|:--:|:--:|:--:|:--:|
| `fence` / `fence.i` | [ E1 ]<br/>stall<br/>(**ISB** and **WRITE BUFFER** not empty) | [ E1 ]<br/>stall<br/>(**ISB** and **WRITE BUFFER** not empty) | [ E1 ] | [ E2 ] | [ E3 ]<br/>drive RoB done output |

- **`T1` / `…` cycles:** the fence cannot leave `E1` while an ISB entry or a
  write buffer entry is still live — the stage is in the `stall` state and the
  cell notes `(ISB and WRITE BUFFER not empty)`. Nothing is issued and no unit is
  used.
- **`Trel` cycle:** both structures are empty, so `E1` completes. There is no AGU
  and no SRAM access on this cell: a fence has no address.
- **`Trel+1` cycle:** the fence passes through `E2`.
- **`Trel+2` cycle:** the fence is recognized and retires — RoB done only. It is
  not an exception, and no data path is driven.
