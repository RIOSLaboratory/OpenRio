`ifndef IB_SV
`define IB_SV

/* verilator lint_off IMPORTSTAR */
import or_be_types_pkg::*;
import or_be_config_pkg::*;
/* verilator lint_on IMPORTSTAR */

// IB -- 8 slot instruction buffer (IB微架构文档).
//
// (1) per-entry state          : IDLE / RESIDENT.  valid is NOT stored.  The
//                                two states are compressed into the 4-bit
//                                {loopbit, index[2:0]} wptr / rptr pair and
//                                per-entry valid is the decoded projection of
//                                the ring interval [rptr, wptr).
// (2) state transition         : IDLE->RESIDENT on enqueue, RESIDENT->IDLE on
//                                dequeue, ANY->IDLE on flush.
// (3) condition                : fe_ready = the free_slot admission chain,
//                                sampled INCLUDING this cycle's dequeue;
//                                accepted_slot = fe_valid & fe_ready;
//                                dequeue[s] = inst_valid[s] &
//                                ib_dequeue[s]; flush = global_flush_late,
//                                highest priority, resets both pointers
//                                including the loopbit.
// (4) data path                : 2 enqueue write ports at wptr + n, 2
//                                combinational head read ports at rptr + s,
//                                plus the inst_valid / accepted_slot
//                                projections.
// (5) data structure           : state   wptr / rptr
//                                header  none -- this module makes NO
//                                        judgement about entry content
//                                payload the whole IB_Payload, written at
//                                        enqueue, out exactly as it went in
//
// Two deliberate non-features, both of them things ⑤/⑥ removed on purpose:
//
//   * `free_slot` is an internal quantity and is NOT a port.  ⑥ Static Info is
//     empty: FE issues blind and slides its candidate window on the
//     accepted_slot it reads back, so it never needs the remaining capacity.
//
//   * There is no `subop_supported_now` term anywhere in the admission chain.
//     ⑤ puts the disabled-extension decision on decode -- with ENABLE_A = 0 an
//     atomic subop and with ENABLE_C = 0 a SUBOP_C_* arrive here already
//     carrying full_decode.illegal = 1, which retires as cause 2 through the
//     G0 ILLEGAL path.  Refusing to accept them instead would park the slot at
//     the queue head forever: a hang, not a trap.  This module therefore never
//     looks at exe_subop, consistently with ⑤'s "header: 无" and "payload 原样
//     进原样出".
//
// Port naming follows ⑥ verbatim.  The one exception is IB_Payload, which ⑥
// uses for BOTH the enqueue write ports and the queue-head read ports; the two
// are disambiguated with the ④ terms 「enqueue 输入端口」/「队头输出端口」 as
// enq_IB_Payload / head_IB_Payload and recorded in IB.portmap.
module IB (
    input  logic                   clk,
    input  logic                   rst_n,

    // ------------------------------------------------------------------
    // in-event: enqueue (transaction, 2 write ports).  Ready is `fe_ready[n]`
    // below: an ordinary per-lane valid/ready handshake, so the FE knows at the
    // same posedge how many of its offers went in.  There is no separate
    // "accept" event -- accepted_slot IS fe_valid & fe_ready, by construction.
    // ------------------------------------------------------------------
    input  ib_payload_t            enq_IB_Payload [ISSUE_WIDTH],
    // packed 2-bit, same shape as fe_if.sv's fe_be_instr_valid[1:0]
    // (集成层 §2.5(4)) -- not an unpacked array of 1-bit ports.
    input  logic [ISSUE_WIDTH-1:0] fe_valid,

    // ------------------------------------------------------------------
    // in-event: ib_dequeue (transaction, two-bit prefix strobe, per slot;
    // ready has already been absorbed by the far end, no payload)
    // ------------------------------------------------------------------
    input  logic                   ib_dequeue [ISSUE_WIDTH],

    // ------------------------------------------------------------------
    // in-event: flush (announce, single-wire pulse, no payload)
    // ------------------------------------------------------------------
    input  logic                   global_flush_late,

    // ------------------------------------------------------------------
    // out: combinational reads.  The two head payloads are continuous
    // candidate values -- they are NOT gated by ib_dequeue, which only
    // advances rptr.
    // ------------------------------------------------------------------
    output ib_payload_t            head_IB_Payload [ISSUE_WIDTH],
    output logic [ISSUE_WIDTH-1:0] inst_valid,
    // The FE-facing ready.  Combinational, and deliberately NOT gated by this
    // lane's own fe_valid -- that is what makes `fe_valid & fe_ready` a usable
    // handshake on the FE side.
    output logic [ISSUE_WIDTH-1:0] fe_ready,
    // What actually went in this cycle.  Kept as a port for the observation
    // face only; it is `fe_valid & fe_ready` and carries no extra information.
    output logic [ISSUE_WIDTH-1:0] accepted_slot
);

    // ------------------------------------------------------------------
    // Ring geometry, derived from IB_DEPTH / IB_PTR_W -- never a literal 8.
    //
    // The pointers are 4-bit {loopbit, index[2:0]}: addressing takes
    // index[2:0], the loopbit exists only so that [rptr, wptr) can tell a full
    // window from an empty one.
    // ------------------------------------------------------------------
    localparam int IB_IDX_W = IB_PTR_W - 1;                          // 3

    localparam logic [IB_PTR_W-1:0] IB_CAPACITY = IB_PTR_W'(IB_DEPTH);
    localparam logic [IB_PTR_W-1:0] FREE_FOR_1  = IB_PTR_W'(1);
    localparam logic [IB_PTR_W-1:0] FREE_FOR_2  = IB_PTR_W'(ISSUE_WIDTH);

    // ------------------------------------------------------------------
    // (5) state: the pointer pair, and the payload store.
    // ------------------------------------------------------------------
    logic [IB_PTR_W-1:0] wptr_q;
    logic [IB_PTR_W-1:0] rptr_q;

    ib_payload_t         entry_payload [IB_DEPTH];

    // ------------------------------------------------------------------
    // (4)#1 the live-window projection.
    //
    // valid_count is the 4-bit pointer difference, so it spans 0..8 and a full
    // window reads as 8 rather than as 0.  The window is then walked as
    // offsets from rptr and cut at valid_count.  A 3-bit magnitude compare of
    // the index halves would project BOTH a wrapped window and a full window
    // as empty, which is exactly why the loopbit is stored.
    //
    // Both pointers are cycle-start registered values, so valid_count is the
    // cycle-start occupancy.
    // ------------------------------------------------------------------
    logic [IB_IDX_W-1:0] rptr_idx;
    logic [IB_IDX_W-1:0] wptr_idx;
    logic [IB_PTR_W-1:0] valid_count;
    logic [IB_DEPTH-1:0] entry_valid;
    logic [IB_IDX_W-1:0] scan_idx;

    always_comb begin
        rptr_idx    = rptr_q[IB_IDX_W-1:0];
        wptr_idx    = wptr_q[IB_IDX_W-1:0];
        valid_count = wptr_q - rptr_q;               // mod 16, 0..8

        entry_valid = '0;
        scan_idx    = '0;
        for (int unsigned i = 0; i < IB_DEPTH; i++) begin
            scan_idx = rptr_idx + IB_IDX_W'(i);
            if (IB_PTR_W'(i) < valid_count) begin
                entry_valid[scan_idx] = 1'b1;
            end
        end
    end

    // ------------------------------------------------------------------
    // (4)#2 inst_valid -- the head two slots read straight out of the
    // projection at rptr and rptr + 1, which is ③'s
    // inst_valid[s] = (valid_count >= s + 1) and keeps the implication
    // inst_valid[1] => inst_valid[0] structural.  The head slots are the
    // consecutive entries at rptr / rptr + 1: entries never skip a hole and
    // are never reordered.
    // ------------------------------------------------------------------
    always_comb begin
        for (int unsigned s = 0; s < ISSUE_WIDTH; s++) begin
            inst_valid[s] = entry_valid[rptr_idx + IB_IDX_W'(s)];
        end
    end

    // ------------------------------------------------------------------
    // (3) dequeue.  ib_dequeue is a two-bit prefix, so the dequeue set is only
    // 00 / 01 / 11 and slot 0 is never skipped.  deq_count depends on the
    // cycle-start inst_valid alone, never on this cycle's enq_count, so
    // enqueue and dequeue do not form a loop.
    // ------------------------------------------------------------------
    logic                             dequeue_slot [ISSUE_WIDTH];
    logic [$clog2(ISSUE_WIDTH+1)-1:0] deq_count;

    always_comb begin
        for (int unsigned s = 0; s < ISSUE_WIDTH; s++) begin
            dequeue_slot[s] = inst_valid[s] && ib_dequeue[s];
        end
        deq_count = {1'b0, dequeue_slot[0]} + {1'b0, dequeue_slot[1]};
    end

    // ------------------------------------------------------------------
    // (3) enqueue admission.
    //
    // free_slot includes the slots this cycle's dequeue releases: a queue that
    // was full at cycle start and retires 2 this cycle takes 2 this cycle, no
    // bubble.  Throttling on the cycle-start occupancy would throw a cycle
    // away for nothing.
    //
    // The cost of that convention is that FU_ready -> accept -> deq_count ->
    // free_slot -> accepted_slot is one combinational path out to the FE
    // interface; ③ flags it as the path to watch at closure.
    //
    // free_slot is internal.  It is NOT a port -- see the header note.
    //
    // accepted_slot[1] is chained on accepted_slot[0], so the legal values are
    // 00 / 01 / 11 and 10 can never appear.  flush wins over everything and
    // forces 00.
    //
    // The chain now lives in `fe_ready` and `accepted_slot` is derived from it,
    // rather than the two being written out twice side by side.  That is what
    // lets the FE drop a separate "accept" line: it computes the same thing
    // from `fe_valid & fe_ready` at the same posedge, and the two cannot drift
    // because there is only one expression.
    //
    // **fe_ready[1] carries fe_valid[0], and that is not a slip.** Admission is
    // a prefix, so the full condition for "lane 1 goes in" always included
    // "lane 0 is being offered in the same cycle".  Lifting that term out of
    // the ready would break the identity above and let the FE count one more
    // instruction admitted than the queue actually took.
    //
    // Equivalence with the pre-handshake form is exact: that version chained
    // `accepted_slot[0]` (which carries `free_slot >= FREE_FOR_1`) into
    // `accepted_slot[1]`, and FREE_FOR_2 >= FREE_FOR_1 makes that term
    // redundant under `free_slot >= FREE_FOR_2`.
    // ------------------------------------------------------------------
    logic [IB_PTR_W-1:0]              occupancy_after_deq;
    logic [IB_PTR_W-1:0]              free_slot;
    logic [$clog2(ISSUE_WIDTH+1)-1:0] enq_count;

    always_comb begin
        occupancy_after_deq = valid_count - IB_PTR_W'(deq_count);
        free_slot           = IB_CAPACITY - occupancy_after_deq;

        fe_ready[0]         = (free_slot >= FREE_FOR_1)
                           && !global_flush_late;
        fe_ready[1]         = fe_valid[0]
                           && (free_slot >= FREE_FOR_2)
                           && !global_flush_late;

        accepted_slot[0]    = fe_valid[0] && fe_ready[0];
        accepted_slot[1]    = fe_valid[1] && fe_ready[1];

        enq_count           = {1'b0, accepted_slot[0]} + {1'b0, accepted_slot[1]};
    end

    // ------------------------------------------------------------------
    // (4)#1 entry -> queue-head output ports, the whole IB_Payload.
    //
    // Same-slot read/write safety: when a full queue enqueues and dequeues in
    // the same cycle the write target is the very entry being read out here.
    // The head output is a continuous combinational value that the far end has
    // already taken this cycle, so the edge write does not disturb that read.
    // ------------------------------------------------------------------
    always_comb begin
        for (int unsigned s = 0; s < ISSUE_WIDTH; s++) begin
            head_IB_Payload[s] = entry_payload[rptr_idx + IB_IDX_W'(s)];
        end
    end

    // ------------------------------------------------------------------
    // (3) pointer landing.
    //
    // flush has the highest priority: both pointers reset, loopbit included,
    // so the next-state valid_count is 0.  Off the flush cycle the pointers
    // take the net enqueue / dequeue change.
    // ------------------------------------------------------------------
    logic [IB_PTR_W-1:0] wptr_next;
    logic [IB_PTR_W-1:0] rptr_next;

    always_comb begin
        if (global_flush_late) begin
            wptr_next = '0;
            rptr_next = '0;
        end else begin
            wptr_next = wptr_q + IB_PTR_W'(enq_count);
            rptr_next = rptr_q + IB_PTR_W'(deq_count);
        end
    end

    // ------------------------------------------------------------------
    // (2) the sequential state.
    //
    // (4)#1 enqueue input port -> entry[wptr + n].  accepted_slot is a prefix,
    // so slot n lands at wptr + n unconditionally -- no compaction, no hole
    // skipping, program order preserved.  The payload is stored exactly as it
    // arrived; this module never rewrites a field.
    //
    // flush leaves the payload store untouched on purpose: accepted_slot is
    // already 00 on that cycle and the reset pointers make every entry
    // unreachable, so there is nothing to clear.
    // ------------------------------------------------------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wptr_q <= '0;
            rptr_q <= '0;
            for (int unsigned i = 0; i < IB_DEPTH; i++) begin
                entry_payload[i] <= '0;
            end
        end else begin
            wptr_q <= wptr_next;
            rptr_q <= rptr_next;

            for (int unsigned s = 0; s < ISSUE_WIDTH; s++) begin
                if (accepted_slot[s]) begin
                    entry_payload[wptr_idx + IB_IDX_W'(s)] <= enq_IB_Payload[s];
                end
            end
        end
    end

endmodule

`endif // IB_SV
