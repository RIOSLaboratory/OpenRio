<style>
table { display: block; overflow-x: auto; width: 100%; } th, td { white-space:
nowrap !important; } </style>

# Cache B2 Timing Diagrams — younger STORE (ordering)

Rules: `../RULES.md`. Columns are cycles (**T1 = E1 accept cycle**), rows are
program order (older `O`, younger `Y`). The write side has **no forwarding** — a
younger store is only ever delayed.

- **Blocked by an older store** — `B2-OLD-ST` (uncommitted in the ISB; same cache line,
  write buffer hit variant), `B2-OLD-NOPA` (no PA yet), `B2-UNAUTH` (not
  authorized).
- **Older access is a load** — `B2-OLD-RD`: the store arrives unauthorized; the
  cache-miss variant pushes the wakeup out.
- **Older store's cache line absent** — `B2-OLD-NOTPRESENT` (different cache
  lines),
  `B2-RES` (same cache line, one refill reused).
- **No older state** — not a case of this axis: with nothing in front of the
  store the timing is exactly `A-S-H`.

---

## Case B2-OLD-ST (older store uncommitted, different cache lines)

Assumes the younger store and an older store that targets a different cache
line are the only two accesses in flight, both aligned, not speculative and
resident, with the older one the ISB head and the write buffer head; the
younger store is accepted one cycle later, so its `done` output lands on the
cycle the older store writes the L1D SRAM, and its L1D access has to contend
for the port.

| Instruction | T1 | T2 | T3 | T4 | T5 | T6 | T7 | T8 |
|:---|:--:|:--:|:--:|:--:|:--:|:--:|:--:|:--:|
| `sd x5, 0(x1)` O | [ E1 ]<br/>**AGU** output VA<br/>allocate **ISB**<br/>(speculative=0) | [ E2 ]<br/>access **DTLB**, hit<br/>**DTLB** output PA | [ E3 ]<br/>**ISB** capture PA<br/>**ISB** access **L1D** SRAM | [ ISB ]<br/>**L1D** tag hit<br/>**L1D** output cache line<br/>output store data<br/>allocate **WRITE BUFFER**<br/>drive RoB done output | [ WRITE BUFFER ]<br/>Store commit<br/>merge store data into cache line<br/>write **L1D** SRAM, accepted |  |  |  |
| `sd x6, 0(x2)` Y |  | [ E1 ]<br/>**AGU** output VA<br/>allocate **ISB**<br/>(speculative=0) | [ E2 ]<br/>access **DTLB**, hit<br/>**DTLB** output PA | [ E3 ]<br/>**ISB** capture PA | [ ISB ]<br/>access **L1D** SRAM, blocked<br/>drive RoB done output<br/>(SRAM write has priority) | [ ISB ]<br/>access **L1D** SRAM | [ ISB ]<br/>**L1D** tag hit<br/>**L1D** output cache line<br/>output store data<br/>allocate **WRITE BUFFER** | [ WRITE BUFFER ]<br/>Store commit<br/>merge store data into cache line<br/>write **L1D** SRAM |

- **`T4` cycle (Y):** the address is captured on time, but Y is not the head, so it
  takes no L1D access. This is Y's **only** `E3` cycle: from here the entry is owned
  by `[ ISB ]` until its commit.
- **`T5` cycle (Y):** `[ ISB ]` owns the entry and it holds a physical address, so
  the completion is driven here. Y is the head by now, but O's L1D write owns the
  single L1D port, so the access is `access L1D SRAM, blocked` with
  `(SRAM write has priority)` — no `ISB ` subject, because the ISB is the owner.
- **`T6` cycle (Y):** the read is issued again now that the port is free.
- The head wait plus the lost arbitration cost Y three cycles against a lone
  store.

### Variant: both stores target the same cache line (write buffer hit)

Assumes the younger store and an older store that targets the same cache line
are the only two accesses in flight, both aligned, not speculative and resident,
with the older store's write buffer entry the head when the younger one probes;
the younger store is accepted one cycle later, so its probe hits the entry being
written to L1D and it takes its own write buffer slot instead of contending for
the port.

| Instruction | T1 | T2 | T3 | T4 | T5 | T6 |
|:---|:--:|:--:|:--:|:--:|:--:|:--:|
| `sd x5, 0(x1)` O | [ E1 ]<br/>**AGU** output VA<br/>allocate **ISB**<br/>(speculative=0) | [ E2 ]<br/>access **DTLB**, hit<br/>**DTLB** output PA | [ E3 ]<br/>**ISB** capture PA<br/>**ISB** access **L1D** SRAM | [ ISB ]<br/>**L1D** tag hit<br/>**L1D** output cache line<br/>output store data<br/>allocate **WRITE BUFFER**<br/>drive RoB done output | [ WRITE BUFFER ]<br/>Store commit<br/>merge store data into cache line<br/>write **L1D** SRAM |  |
| `sd x6, 0(x1)` Y |  | [ E1 ]<br/>**AGU** output VA<br/>allocate **ISB**<br/>(speculative=0) | [ E2 ]<br/>access **DTLB**, hit<br/>**DTLB** output PA | [ E3 ]<br/>**ISB** capture PA | [ ISB ]<br/>access **WRITE BUFFER**, hit<br/>output store data<br/>allocate **WRITE BUFFER**<br/>drive RoB done output | [ WRITE BUFFER ]<br/>Store commit<br/>merge store data into cache line copied from older entry<br/>write **L1D** SRAM |

- **`T5` cycle (Y):** the probe hits the entry O is writing out in this very cycle.
  The hit is real, but the bytes cannot be merged into an entry that is leaving,
  so Y takes its **own** slot.
- No L1D access and no MSHR entry: a write buffer hit is enough to commit.

## Case B2-OLD-RD (older load in flight — the younger store waits for its wakeup)

Assumes an older load and the younger store are the only two accesses in
flight, both resident, with the store not authorized yet so it is accepted
speculative; the older load completes at `T3`, and BE wakes the store at
`Twk`, after which the store takes its L1D access and commits on consecutive
cycles.

| Instruction | T1 | T2 | T3 | T4 | T5 | … | Twk | Twk+1 | Twk+2 |
|:---|:--:|:--:|:--:|:--:|:--:|:--:|:--:|:--:|:--:|
| `ld x5, 0(x1)` O | [ E1 ]<br/>**AGU** output VA<br/>access **L1D** SRAM | [ E2 ]<br/>access **DTLB**, hit<br/>**L1D** tag hit<br/>**L1D** output cache line | [ E3 ]<br/>drive RoB done output<br/>drive CDB<br/>drive bypass output |  |  |  |  |  |  |
| `sd x6, 0(x2)` Y |  | [ E1 ]<br/>**AGU** output VA<br/>allocate **ISB**<br/>(speculative=1) | [ E2 ]<br/>access **DTLB**, hit<br/>**DTLB** output PA | [ E3 ]<br/>**ISB** capture PA | [ ISB ]<br/>drive RoB done output<br/>wait for wakeup from BE | [ ISB ]<br/>wait for wakeup from BE | [ ISB ]<br/>receive wakeup from BE<br/>access **L1D** SRAM | [ ISB ]<br/>**L1D** tag hit<br/>**L1D** output cache line<br/>output store data<br/>allocate **WRITE BUFFER** | [ WRITE BUFFER ]<br/>Store commit<br/>merge store data into cache line<br/>write **L1D** SRAM |

- **`T5` cycle (Y):** the entry holds a physical address, so the completion is
  driven here; it cannot access or commit while speculative.
- **`Twk` cycle (Y):** the wakeup arrives and the access is taken in the same
  cycle.
- **`Twk+2` cycle (O):** the commit is two cycles after the wakeup, exactly as in
  `B2-UNAUTH`; BE was already told done for Y at `T5`.

### Variant: older load is a cache miss

Assumes an older load and the younger store are the only two accesses in
flight, both resident, with the older load missing its cache line so its refill
owns the MSHR and the write buffer; BE withholds the store's wakeup until that
result is accepted, so the store's `done` output is already driven at `T5` while
its L1D access waits until `Twk`.

| Instruction | T1 | T2 | T3 | T4 | T5 | … | Tresp | Tresp+1 | Tresp+2 | Tresp+3 | Tresp+4 | … | Twk | Twk+1 | Twk+2 |
|:---|:--:|:--:|:--:|:--:|:--:|:--:|:--:|:--:|:--:|:--:|:--:|:--:|:--:|:--:|:--:|
| `ld x5, 0(x1)` O | [ E1 ]<br/>**AGU** output VA<br/>access **L1D** SRAM | [ E2 ]<br/>access **DTLB**, hit<br/>**L1D** tag miss<br/>allocate **MSHR** | [ MSHR ]<br/>emit NoC request | [ MSHR ]<br/>wait for NoC response | [ MSHR ]<br/>wait for NoC response | [ MSHR ]<br/>wait for NoC response | [ MSHR ]<br/>receive NoC response<br/>write **DPB** | [ MSHR ]<br/>allocate **WRITE BUFFER**<br/>**DPB** output cache line | [ WRITE BUFFER ]<br/>write **L1D** SRAM<br/>drive RoB done output<br/>drive CDB<br/>drive bypass output |  |  |  |  |  |  |
| `sd x6, 0(x2)` Y |  | [ E1 ]<br/>**AGU** output VA<br/>allocate **ISB**<br/>(speculative=1) | [ E2 ]<br/>access **DTLB**, hit<br/>**DTLB** output PA | [ E3 ]<br/>**ISB** capture PA | [ ISB ]<br/>drive RoB done output<br/>wait for wakeup from BE | [ ISB ]<br/>wait for wakeup from BE | [ ISB ]<br/>wait for wakeup from BE | [ ISB ]<br/>wait for wakeup from BE | [ ISB ]<br/>wait for wakeup from BE | [ ISB ]<br/>wait for wakeup from BE | [ ISB ]<br/>wait for wakeup from BE | [ ISB ]<br/>wait for wakeup from BE | [ ISB ]<br/>receive wakeup from BE<br/>access **L1D** SRAM | [ ISB ]<br/>**L1D** tag hit<br/>**L1D** output cache line<br/>output store data<br/>allocate **WRITE BUFFER** | [ WRITE BUFFER ]<br/>Store commit<br/>merge store data into cache line<br/>write **L1D** SRAM |

- **`T5` cycle (Y):** the completion is driven early and independently of the
  wakeup; only the access and the commit move.
- Y is **not** blocked by the refill itself: BE simply withholds the wakeup while
  an older load is outstanding.

## Case B2-OLD-NOPA (older store PA unknown)

Assumes the younger store and an older store that targets a different cache
line are the only two accesses in flight, both aligned, not speculative and
resident, with the older store's translation missing and the TMQ free; the
older store stalls at `E2` through `Tpte-1` so the younger one is held in
`E1`, and its L1D access then lands on the older store's `write L1D SRAM`
cycle and loses the port.

| Instruction | T1 | T2 | T3 | … | Tpte | Tpte+1 | Tpte+2 | Tpte+3 | Tpte+4 | Tpte+5 | Tpte+6 |
|:---|:--:|:--:|:--:|:--:|:--:|:--:|:--:|:--:|:--:|:--:|:--:|
| `sd x5, 0(x1)` O | [ E1 ]<br/>**AGU** output VA<br/>allocate **ISB**<br/>(speculative=0) | [ E2 ]<br/>stall<br/>access **DTLB**, miss<br/>allocate **TMQ** | [ E2 ]<br/>stall<br/>**TMQ** emit MMU request | [ E2 ]<br/>stall<br/>**TMQ** wait for MMU response | [ E2 ]<br/>**TMQ** receive MMU response<br/>**TMQ** write **DTLB**<br/>**DTLB** output PA | [ E3 ]<br/>**ISB** capture PA<br/>**ISB** access **L1D** SRAM | [ ISB ]<br/>**L1D** tag hit<br/>**L1D** output cache line<br/>output store data<br/>allocate **WRITE BUFFER**<br/>drive RoB done output | [ WRITE BUFFER ]<br/>Store commit<br/>merge store data into cache line<br/>write **L1D** SRAM, accepted |  |  |  |
| `sd x6, 0(x2)` Y |  | [ E1 ]<br/>stall<br/>(backpressure from **E2**) | [ E1 ]<br/>stall<br/>(backpressure from **E2**) | [ E1 ]<br/>stall<br/>(backpressure from **E2**) | [ E1 ]<br/>**AGU** output VA<br/>allocate **ISB**<br/>(speculative=0) | [ E2 ]<br/>access **DTLB**, hit<br/>**DTLB** output PA | [ E3 ]<br/>**ISB** capture PA | [ ISB ]<br/>access **L1D** SRAM, blocked<br/>drive RoB done output<br/>(SRAM write has priority) | [ ISB ]<br/>access **L1D** SRAM | [ ISB ]<br/>**L1D** tag hit<br/>**L1D** output cache line<br/>output store data<br/>allocate **WRITE BUFFER** | [ WRITE BUFFER ]<br/>Store commit<br/>merge store data into cache line<br/>write **L1D** SRAM |

- **`Tpte` cycle (O):** `E2` completes and the store is injected straight into
  `E3`; the same edge frees `E2`, so Y completes its `E1` here.
- **`Tpte+2` cycle (Y):** it captures the address — the last cycle owned by
  `[ E3 ]` — but it was not the head when it arrived, so it takes no L1D access.
- **`Tpte+3` cycle (Y):** `[ ISB ]` owns it now, and it is the head, so the
  completion is driven — but O's L1D write owns the port, so the access is
  `access L1D SRAM, blocked` with `(SRAM write has priority)` and is
  re-issued a cycle later.
- **If the two stores hit the same line**, the `Tpte+3` probe is a write buffer
  probe, not an SRAM access, so no arbitration is lost and Y commits one cycle
  earlier.

## Case B2-UNAUTH (older store not woken)

Assumes the younger store and an older store that targets a different cache
line are the only two accesses in flight, both aligned and resident, with the
older store not authorized yet and its write buffer entry the head when it
commits; the younger store is accepted one cycle later, so after the wakeup it
becomes the head exactly on the older store's `write L1D SRAM` cycle and loses
the port.

| Instruction | T1 | T2 | T3 | T4 | T5 | … | Twk | Twk+1 | Twk+2 | Twk+3 | Twk+4 | Twk+5 |
|:---|:--:|:--:|:--:|:--:|:--:|:--:|:--:|:--:|:--:|:--:|:--:|:--:|
| `sd x5, 0(x1)` O | [ E1 ]<br/>**AGU** output VA<br/>allocate **ISB**<br/>(speculative=1) | [ E2 ]<br/>access **DTLB**, hit<br/>**DTLB** output PA | [ E3 ]<br/>**ISB** capture PA | [ ISB ]<br/>drive RoB done output | [ ISB ]<br/>wait for wakeup from BE | [ ISB ]<br/>wait for wakeup from BE | [ ISB ]<br/>receive wakeup from BE<br/>access **L1D** SRAM | [ ISB ]<br/>**L1D** tag hit<br/>**L1D** output cache line<br/>output store data<br/>allocate **WRITE BUFFER** | [ WRITE BUFFER ]<br/>Store commit<br/>merge store data into cache line<br/>write **L1D** SRAM, accepted |  |  |  |
| `sd x6, 0(x2)` Y |  | [ E1 ]<br/>**AGU** output VA<br/>allocate **ISB**<br/>(speculative=0) | [ E2 ]<br/>access **DTLB**, hit<br/>**DTLB** output PA | [ E3 ]<br/>**ISB** capture PA | [ ISB ]<br/>drive RoB done output<br/>wait until at head | [ ISB ]<br/>wait until at head | [ ISB ]<br/>wait until at head | [ ISB ]<br/>wait until at head | [ ISB ]<br/>access **L1D** SRAM, blocked<br/>(SRAM write has priority) | [ ISB ]<br/>access **L1D** SRAM | [ ISB ]<br/>**L1D** tag hit<br/>**L1D** output cache line<br/>output store data<br/>allocate **WRITE BUFFER** | [ WRITE BUFFER ]<br/>Store commit<br/>merge store data into cache line<br/>write **L1D** SRAM |

- **`T4` cycle (O):** the entry holds a physical address, so the completion is
  driven even though O cannot access or commit.
- **`T5` cycle (Y):** the completion is driven here as well; from then on the
  entry only waits for its turn at the ISB head.
- **`Twk+2` cycle (Y):** O commits at the `Twk+1` edge, so Y is the head — but
  O's L1D write owns the port and the read is blocked.
- This is the **only** case where the speculative flag matters: it gates both the
  access and the commit, never the completion or forwarding.

## Case B2-OLD-NOTPRESENT (older store's cache line not present)

Assumes the younger store and an older store that targets a different cache
line are the only two accesses in flight, both aligned, not speculative and
resident, with the older store's cache line absent so its refill owns the MSHR
and the write buffer; the younger store's `done` output is driven at capture +
1, and its L1D access lands on the older store's `write L1D SRAM` cycle and
loses the port.

| Instruction | T1 | T2 | T3 | T4 | T5 | … | Tresp | Tresp+1 | Tresp+2 | Tresp+3 | Tresp+4 | Tresp+5 |
|:---|:--:|:--:|:--:|:--:|:--:|:--:|:--:|:--:|:--:|:--:|:--:|:--:|
| `sd x5, 0(x1)` O | [ E1 ]<br/>**AGU** output VA<br/>allocate **ISB**<br/>(speculative=0) | [ E2 ]<br/>access **DTLB**, hit<br/>**DTLB** output PA | [ E3 ]<br/>**ISB** capture PA<br/>**ISB** access **L1D** SRAM | [ ISB ]<br/>**L1D** tag miss<br/>allocate **MSHR**<br/>drive RoB done output | [ MSHR ]<br/>emit NoC request | [ MSHR ]<br/>wait for NoC response | [ MSHR ]<br/>receive NoC response<br/>write **DPB** | [ MSHR ]<br/>allocate **WRITE BUFFER**<br/>**DPB** output cache line<br/>**ISB** output store data | [ WRITE BUFFER ]<br/>Store commit<br/>merge store data into cache line<br/>write **L1D** SRAM, accepted |  |  |  |
| `sd x6, 0(x2)` Y |  | [ E1 ]<br/>**AGU** output VA<br/>allocate **ISB**<br/>(speculative=0) | [ E2 ]<br/>access **DTLB**, hit<br/>**DTLB** output PA | [ E3 ]<br/>**ISB** capture PA | [ ISB ]<br/>drive RoB done output<br/>wait until at head | [ ISB ]<br/>wait until at head | [ ISB ]<br/>wait until at head | [ ISB ]<br/>wait until at head | [ ISB ]<br/>access **L1D** SRAM, blocked<br/>(SRAM write has priority) | [ ISB ]<br/>access **L1D** SRAM | [ ISB ]<br/>**L1D** tag hit<br/>**L1D** output cache line<br/>output store data<br/>allocate **WRITE BUFFER** | [ WRITE BUFFER ]<br/>Store commit<br/>merge store data into cache line<br/>write **L1D** SRAM |

- **`T5` cycle (Y):** the completion is driven at capture + 1, long before the
  commit; the access and the commit are deferred by the head wait, not by the
  refill.
- **`Tresp+2` cycle (Y):** Y becomes the head at the `Tresp+1` edge and wants its
  L1D access, but O's L1D write owns the port.

## Case B2-RES (younger store behind an older store's cache line miss — same cache line)

Assumes the younger store and an older store that target the same cache line
are the only two accesses in flight, both aligned, not speculative and
resident, with the cache line absent so the older store's refill owns the MSHR
and the write buffer; the younger store is therefore never the head while that
refill is outstanding, so it takes no L1D access and records no miss of its own,
and when it does become the head its write buffer probe hits the entry being
written to L1D.

| Instruction | T1 | T2 | T3 | T4 | T5 | … | Tresp | Tresp+1 | Tresp+2 | Tresp+3 |
|:---|:--:|:--:|:--:|:--:|:--:|:--:|:--:|:--:|:--:|:--:|
| `sd x5, 0(x1)` O | [ E1 ]<br/>**AGU** output VA<br/>allocate **ISB**<br/>(speculative=0) | [ E2 ]<br/>access **DTLB**, hit<br/>**DTLB** output PA | [ E3 ]<br/>**ISB** capture PA<br/>**ISB** access **L1D** SRAM | [ ISB ]<br/>**L1D** tag miss<br/>allocate **MSHR**<br/>drive RoB done output | [ MSHR ]<br/>emit NoC request | [ MSHR ]<br/>wait for NoC response | [ MSHR ]<br/>receive NoC response<br/>write **DPB** | [ MSHR ]<br/>allocate **WRITE BUFFER**<br/>**DPB** output cache line<br/>**ISB** output store data | [ WRITE BUFFER ]<br/>Store commit<br/>merge store data into cache line<br/>write **L1D** SRAM |  |
| `sd x6, 0(x1)` Y |  | [ E1 ]<br/>**AGU** output VA<br/>allocate **ISB**<br/>(speculative=0) | [ E2 ]<br/>access **DTLB**, hit<br/>**DTLB** output PA | [ E3 ]<br/>**ISB** capture PA | [ ISB ]<br/>drive RoB done output<br/>wait until at head | [ ISB ]<br/>wait until at head | [ ISB ]<br/>wait until at head | [ ISB ]<br/>wait until at head | [ ISB ]<br/>access **WRITE BUFFER**, hit<br/>output store data<br/>allocate **WRITE BUFFER** | [ WRITE BUFFER ]<br/>Store commit<br/>merge store data into cache line copied from older entry<br/>write **L1D** SRAM |

- **`T4` cycle (Y):** Y is allocated behind O, so it is not the head: no probe, no
  L1D access, no MSHR entry. It waits in the ISB.
- **`Tresp+2` cycle (Y):** Y is the head and its write buffer probe hits the entry
  O is writing out in this very cycle. That entry is leaving, so Y cannot merge
  into it — it takes its own slot and outputs its own bytes there.
- In-order commit plus head-of-line blocking means a younger store can never
  become head while an older store's refill is outstanding: this is single-refill
  reuse, not a second request.
