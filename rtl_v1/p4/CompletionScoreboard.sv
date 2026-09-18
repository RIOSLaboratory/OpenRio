`ifndef COMPLETIONSCOREBOARD_SV
`define COMPLETIONSCOREBOARD_SV

/* verilator lint_off IMPORTSTAR */
import or_be_types_pkg::*;
import exe_subop_pkg::*;
/* verilator lint_on IMPORTSTAR */

// CompletionScoreboard -- the single retire authority
// (CompletionScoreboard微架构文档).
//
// (1) per-entry state          : valid is NOT stored.  FREE / non-FREE is
//                                compressed into the 5-bit {loopbit,index}
//                                head / tail pair and per-entry valid is the
//                                decoded projection of the ring interval
//                                [head, tail).  Only two bits are stored per
//                                tag -- exec_done and store_wakeup_issued --
//                                plus the alloc header st_br_resolve.
// (2) state transition         : live 0->1 alloc (writes the alloc batch and
//                                CLEARS the two bits); store_wakeup_issued
//                                0->1 on the self-produced wakeup pulse;
//                                exec_done 0->1 on terminal normal done or
//                                terminal exception; live 1->0 on commit or
//                                flush.  The two bits never clear each other.
// (3) condition                : alloc[s] = accept[s]; writeback =
//                                writeback_valid[g] & !global_flush_late;
//                                store_wakeup = safe-prefix scan hit;
//                                commit = decision chain; flush = decision
//                                chain, ordered head_new = head + commit_count
//                                then tail_new = head_new
// (4) data path                : projections, the queue-head qualifiers, the
//                                five-branch head0 chain + head1 chain + dual
//                                FP block + early store wakeup scan, the
//                                commit bus, the recovery read port and the
//                                st_br_resolve read port
// (5) data structure           : state   exec_done / store_wakeup_issued /
//                                        head / tail
//                                header  alloc batch (rd_idx, rd_is_fp,
//                                        rd_write_enable, is_store,
//                                        is_fence_i, may_flush, is_atomic,
//                                        st_br_resolve) + event batch
//                                        (mispredict_flag, exception_flag,
//                                        is_mret)
//                                payload mispredict_target_pc(64),
//                                        exception_cause(63),
//                                        exception_tval(64), fpu_fflags(5)
//
// This module connects to no LSU signal.  The LSU is projected onto the two
// things this module already had: lane-3 completion (through the writeback
// event batch) and the plain-store store_wakeup pulse this module produces
// itself.
//
// Port naming follows doc ⑥ verbatim, including its 「命名去重」 table: the
// alloc write address is alloc_self_tag, the st_br_resolve read address is
// st_br_resolve_tag, the commit-side destination trio carries the commit_
// prefix and the recovery read port the recovery_ prefix, while the alloc and
// writeback batches keep their bare names.  No name is left ambiguous, so no
// port map file is needed.
module CompletionScoreboard (
    input  logic                            clk,
    input  logic                            rst_n,

    // ------------------------------------------------------------------
    // in-event: alloc (transaction, 2 write ports, per dispatch slot; ready =
    // can_alloc_1 / can_alloc_2 is absorbed upstream).  st_br_resolve is NOT
    // an input -- ⑤ makes the SCB compute it from the safe prefix at the alloc
    // cycle, and the integration list drives no such wire.
    // ------------------------------------------------------------------
    input  logic                            accept          [ISSUE_WIDTH],
    input  logic [TAG_W-1:0]                alloc_self_tag  [ISSUE_WIDTH],
    input  logic [REG_ADDR_W-1:0]           rd_idx          [ISSUE_WIDTH],
    input  logic                            rd_is_fp        [ISSUE_WIDTH],
    input  logic                            rd_write_enable [ISSUE_WIDTH],
    input  logic                            is_store        [ISSUE_WIDTH],
    input  logic                            is_fence_i      [ISSUE_WIDTH],
    input  logic                            may_flush       [ISSUE_WIDTH],
    // is_g3_atomic_subop(exe_subop) as derived by dispatch_logic: LR / SC and
    // the 22 AMOs.  This module never sees exe_subop, so the "irrevocable
    // head0" test depends on this bit being carried in.
    input  logic                            is_atomic       [ISSUE_WIDTH],

    // ------------------------------------------------------------------
    // in-event: writeback (announce x4, 4 write ports, random addressing).
    // This is the four lanes' completion_common layer only; lane 0's
    // csr_sideband is a sideband to the host and does not enter here.
    // ------------------------------------------------------------------
    input  logic                            writeback_valid         [NUM_LANES],
    input  logic [TAG_W-1:0]                tag_out              [NUM_LANES],
    input  logic                            mispredict_flag      [NUM_LANES],
    input  logic [XLEN-1:0]                 mispredict_target_pc [NUM_LANES],
    input  logic                            exception_flag       [NUM_LANES],
    input  logic [EXCP_CAUSE_W-1:0]         exception_cause      [NUM_LANES],
    input  logic [XLEN-1:0]                 exception_tval       [NUM_LANES],
    input  logic                            is_mret              [NUM_LANES],
    input  logic                            is_sret              [NUM_LANES],
    input  logic [FFLAGS_W-1:0]             fpu_fflags           [NUM_LANES],

    // ------------------------------------------------------------------
    // in-event: flush (announce).  Guards writeback capture only -- the
    // pointers are landed by the self-produced flush_valid, never by this.
    // ------------------------------------------------------------------
    input  logic                            global_flush_late,

    // ------------------------------------------------------------------
    // in: combinational reads
    // ------------------------------------------------------------------
    input  logic                            interrupt_pending,
    // st_br_resolve read index, returned by the LSU at the G3 issue boundary.
    // The recovery read port has NO address input: flush_tag is produced by
    // this module's own decision chain and the three recovery reads index it
    // directly; flush_model never sends it back.
    input  logic [TAG_W-1:0]                st_br_resolve_tag,
    // 读地址的**有效位**：ISQ_Group3 此刻确实驻留着一条指令。
    //
    // 没有它，st_br_resolve_tag 在 ISQ3 空的时候是残留值。下面的
    // resolve_in_place 要拿它和 wk_tag 比，残留值万一撞上就会让 SCB
    // 判成「就地解析」而不发唤醒 —— 那条解析就**丢了**，
    // store 会一直等一个永远不来的授权。
    input  logic                            st_br_resolve_tag_valid,

    // ------------------------------------------------------------------
    // out-event: commit (lane 0 is always head0, lane 1 always head1)
    // ------------------------------------------------------------------
    output logic                            commit_valid           [ISSUE_WIDTH],
    output logic [TAG_W-1:0]                commit_tag             [ISSUE_WIDTH],
    // doc ⑥ commit `rd_idx[k]` / `rd_is_fp[k]` / `rd_write_enable[k]`
    output logic [REG_ADDR_W-1:0]           commit_rd_idx          [ISSUE_WIDTH],
    output logic                            commit_rd_is_fp        [ISSUE_WIDTH],
    output logic                            commit_rd_write_enable [ISSUE_WIDTH],
    output logic [FFLAGS_W-1:0]             commit_fflags          [ISSUE_WIDTH],
    output logic [COMMIT_COUNT_W-1:0]       commit_count,

    // ------------------------------------------------------------------
    // out-event: store_wakeup (1-cycle pulse, at most one per cycle)
    // ------------------------------------------------------------------
    output logic                            store_wakeup_valid,
    output logic [TAG_W-1:0]                store_wakeup_tag,

    // ------------------------------------------------------------------
    // out-event: flush
    // ------------------------------------------------------------------
    output logic                            flush_valid,
    output logic [TAG_W-1:0]                flush_tag,
    output logic [RECOVERY_KIND_W-1:0]      recovery_kind,

    // ------------------------------------------------------------------
    // out: combinational reads
    // ------------------------------------------------------------------
    output logic [TAG_W-1:0]                head_tag [ISSUE_WIDTH],
    // the recovery read port, indexed by the self-produced flush_tag
    output logic [XLEN-1:0]                 recovery_mispredict_target_pc,
    output logic [EXCP_CAUSE_W-1:0]         recovery_exception_cause,
    output logic [XLEN-1:0]                 recovery_exception_tval,
    output logic                            st_br_resolve,

    // ------------------------------------------------------------------
    // Static Info
    // ------------------------------------------------------------------
    output logic [ROB_DEPTH-1:0]            scoreboard_valid_bits,
    output logic [ROB_DEPTH-1:0]            scoreboard_exec_done_bits,
    output logic [TAG_W-1:0]                Buffer_tail,
    output logic                            can_alloc_1,
    output logic                            can_alloc_2,
    output logic                            buffer_empty
);

    // ------------------------------------------------------------------
    // Occupancy thresholds, derived from ROB_DEPTH -- never a literal 16.
    // ------------------------------------------------------------------
    localparam logic [ROB_PTR_W-1:0] OCC_MAX_FOR_1 = ROB_PTR_W'(ROB_DEPTH - 1);
    localparam logic [ROB_PTR_W-1:0] OCC_MAX_FOR_2 = ROB_PTR_W'(ROB_DEPTH - 2);

    // ------------------------------------------------------------------
    // (5) state: the two per-tag bits and the pointer pair.
    //
    // head / tail are 5-bit {loopbit, index[3:0]}.  Addressing and every tag
    // leaving this module take index[3:0]; the loopbit exists only so that
    // [head, tail) can tell a full window from an empty one.
    // ------------------------------------------------------------------
    logic [ROB_PTR_W-1:0]    head_q;
    logic [ROB_PTR_W-1:0]    tail_q;

    logic                    entry_exec_done           [ROB_DEPTH];
    logic                    entry_store_wakeup_issued [ROB_DEPTH];

    // (5) header: alloc batch -- written once at alloc, never overwritten
    logic [REG_ADDR_W-1:0]   entry_rd_idx          [ROB_DEPTH];
    logic                    entry_rd_is_fp        [ROB_DEPTH];
    logic                    entry_rd_write_enable [ROB_DEPTH];
    logic                    entry_is_store        [ROB_DEPTH];
    logic                    entry_is_fence_i      [ROB_DEPTH];
    logic                    entry_may_flush       [ROB_DEPTH];
    logic                    entry_is_atomic       [ROB_DEPTH];
    logic                    entry_st_br_resolve   [ROB_DEPTH];

    // (5) header: event batch -- written by writeback, only meaningful while
    // exec_done = 1.  alloc does not clear these; the decision chain's done
    // gate is what keeps a stale value out.
    logic                    entry_mispredict_flag [ROB_DEPTH];
    logic                    entry_exception_flag  [ROB_DEPTH];
    logic                    entry_is_mret         [ROB_DEPTH];
    logic                    entry_is_sret         [ROB_DEPTH];

    // (5) payload: forwarded, never turned into a predicate here
    logic [XLEN-1:0]         entry_mispredict_target_pc [ROB_DEPTH];
    logic [EXCP_CAUSE_W-1:0] entry_exception_cause      [ROB_DEPTH];
    logic [XLEN-1:0]         entry_exception_tval       [ROB_DEPTH];
    logic [FFLAGS_W-1:0]     entry_fpu_fflags           [ROB_DEPTH];

    // ------------------------------------------------------------------
    // (4)#1 occupancy and the admission projections.  Every one of these is
    // the CYCLE-START value: they are functions of head_q / tail_q only.
    // ------------------------------------------------------------------
    logic [ROB_PTR_W-1:0] occupancy;

    always_comb begin
        occupancy    = tail_q - head_q;              // 0..16, mod32 arithmetic
        can_alloc_1  = (occupancy <= OCC_MAX_FOR_1);
        can_alloc_2  = (occupancy <= OCC_MAX_FOR_2);
        buffer_empty = (occupancy == '0);
        Buffer_tail  = tail_q[TAG_W-1:0];
    end

    // ------------------------------------------------------------------
    // (4)#1 the live-window scan.
    //
    // One age-ordered pass from head produces everything that needs the ring
    // interval: the valid projection, the interrupt's authorized-store
    // reduction, the whole-window safe prefix that alloc's st_br_resolve
    // needs, and the early store-wakeup candidate.
    //
    // The interval is walked as offsets from head and cut at `occupancy`,
    // which is the 5-bit pointer difference.  A 4-bit magnitude compare would
    // project both a wrapped window and a full window as empty.
    // ------------------------------------------------------------------
    logic [ROB_DEPTH-1:0] live_mask;
    logic                 any_plain_store_authorized_live;
    logic                 prefix_safe_0;      // AND safe(o) over the whole window
    logic                 wk_found;
    logic [TAG_W-1:0]     wk_tag;
    logic                 wk_prefix_safe;
    logic                 wk_cand_ok;

    logic [TAG_W-1:0]     scan_tag;
    logic                 scan_live;
    logic                 scan_safe;
    logic                 scan_is_cand;

    always_comb begin
        live_mask                       = '0;
        any_plain_store_authorized_live = 1'b0;
        prefix_safe_0                   = 1'b1;
        wk_found                        = 1'b0;
        wk_tag                          = '0;
        wk_prefix_safe                  = 1'b1;
        wk_cand_ok                      = 1'b0;
        scan_tag                        = '0;
        scan_live                       = 1'b0;
        scan_safe                       = 1'b0;
        scan_is_cand                    = 1'b0;

        for (int unsigned i = 0; i < ROB_DEPTH; i++) begin
            scan_tag  = head_q[TAG_W-1:0] + TAG_W'(i);
            scan_live = (ROB_PTR_W'(i) < occupancy);

            // safe(o): either the class can never create an architectural
            // flush, or it has already reached a clean terminal state.
            scan_safe = !entry_may_flush[scan_tag]
                     || (entry_exec_done[scan_tag]
                         && !entry_exception_flag[scan_tag]
                         && !entry_mispredict_flag[scan_tag]
                         && !entry_is_mret[scan_tag]
                         && !entry_is_sret[scan_tag]
                         && !entry_is_fence_i[scan_tag]);

            // A wakeup candidate is a plain store that has neither authority
            // source yet.  st_br_resolve = 1 entries already got the same
            // authorization at alloc and never produce this pulse.
            scan_is_cand = entry_is_store[scan_tag]
                        && !entry_st_br_resolve[scan_tag]
                        && !entry_store_wakeup_issued[scan_tag];

            if (scan_live) begin
                live_mask[scan_tag] = 1'b1;

                // store_authorized[t] = st_br_resolve OR store_wakeup_issued.
                // The two are equivalent sources, not an AND, and exec_done
                // does not remove an entry from this reduction.
                if (entry_is_store[scan_tag]
                    && (entry_st_br_resolve[scan_tag]
                        || entry_store_wakeup_issued[scan_tag])) begin
                    any_plain_store_authorized_live = 1'b1;
                end

                prefix_safe_0 = prefix_safe_0 && scan_safe;

                if (!wk_found) begin
                    if (scan_is_cand) begin
                        wk_found   = 1'b1;
                        wk_tag     = scan_tag;
                        // The candidate's own terminal exception kills the
                        // scan just as an unsafe prefix does.
                        wk_cand_ok = wk_prefix_safe
                                  && !(entry_exec_done[scan_tag]
                                       && entry_exception_flag[scan_tag]);
                    end else begin
                        wk_prefix_safe = wk_prefix_safe && scan_safe;
                    end
                end
            end
        end
    end

    always_comb begin
        scoreboard_valid_bits = live_mask;
        for (int unsigned t = 0; t < ROB_DEPTH; t++) begin
            scoreboard_exec_done_bits[t] = entry_exec_done[t];
        end
    end

    // ------------------------------------------------------------------
    // (4)#2 queue-head qualifiers.  With valid as a projection, headK_valid
    // is exactly headK_present, so v1's double encoding cross-check is gone.
    // ------------------------------------------------------------------
    logic head0_valid;
    logic head1_valid;
    logic head0_done;
    logic head1_done;

    always_comb begin
        head_tag[0]   = head_q[TAG_W-1:0];
        head_tag[1]   = head_q[TAG_W-1:0] + TAG_W'(1);   // 4-bit mod16
        head0_valid = (occupancy >= ROB_PTR_W'(1));
        head1_valid = (occupancy >= ROB_PTR_W'(2));
        head0_done  = head0_valid && entry_exec_done[head_tag[0]];
        head1_done  = head1_valid && entry_exec_done[head_tag[1]];
    end

    // ------------------------------------------------------------------
    // (4)#3 the head0 predicates.
    //
    // "irrevocable head0" is the class that has already produced a
    // non-rollbackable memory side effect.  Both halves are exact, no superset
    // is involved:
    //   normal-done plain store   entry.is_store   (exception already lost to
    //                                               branch 2, so a done head0
    //                                               here is a normal done)
    //   exec_done atomic          entry.is_atomic  (LR / SC / all 22 AMOs,
    //                                               classified at alloc)
    // Revoking such a head0 would re-execute it after the handler returns and
    // write memory twice.  FENCE.I is deliberately NOT in the class: it changes
    // nothing, so re-executing it is equivalent.  Nothing else is folded in --
    // a mispredicting branch, an MRET, a CSR or an illegal instruction stays
    // revocable, so the interrupt is not postponed for them.
    // ------------------------------------------------------------------
    logic h0_exception;
    logic h0_mispredict;
    logic h0_is_mret;
    logic h0_is_sret;
    logic h0_is_fence_i;
    logic h0_fp_write;
    logic h1_exception;
    logic h1_mispredict;
    logic h1_is_fence_i;
    logic h1_fp_write;
    logic head0_irrevocable;
    logic interrupt_take;
    logic interrupt_boundary_ok;

    always_comb begin
        h0_exception  = entry_exception_flag[head_tag[0]];
        h0_mispredict = entry_mispredict_flag[head_tag[0]];
        h0_is_mret    = entry_is_mret[head_tag[0]];
        h0_is_sret    = entry_is_sret[head_tag[0]];
        h0_is_fence_i = entry_is_fence_i[head_tag[0]];
        h0_fp_write   = entry_rd_write_enable[head_tag[0]] && entry_rd_is_fp[head_tag[0]];

        h1_exception  = entry_exception_flag[head_tag[1]];
        h1_mispredict = entry_mispredict_flag[head_tag[1]];
        h1_is_fence_i = entry_is_fence_i[head_tag[1]];
        h1_fp_write   = entry_rd_write_enable[head_tag[1]] && entry_rd_is_fp[head_tag[1]];

        head0_irrevocable = head0_done && !h0_exception
                         && (entry_is_store[head_tag[0]] || entry_is_atomic[head_tag[0]]);

        // interrupt_pending is already a synthesized single wire from the
        // system_instruction_handler; mie / mip / mstatus.MIE are not
        // recombined here.
        interrupt_take = interrupt_pending && !any_plain_store_authorized_live;

        // 可取边界: either head0 itself can be revoked, or it cannot but a
        // head1 exists to become the new flush origin.  With neither, branch 3
        // does not hit at all and the interrupt is postponed a cycle -- an
        // interrupt carries no timing obligation.
        interrupt_boundary_ok = !head0_irrevocable || head1_valid;
    end

    // ------------------------------------------------------------------
    // (4)#3 the decision chain -- one chain settles every retire-side output.
    //
    // Step 1, head0: five branches, first hit from the top wins.
    // Step 2, head1: evaluated only after head0 commits NORMALLY, so head1
    //                can never pass head0.
    // Step 3:        the dual FP commit block may only shorten the commit,
    //                never drop a write and never flush early to dodge it.
    // ------------------------------------------------------------------
    logic head1_eval;
    logic flush_from_head1_commit;
    // The flush verdict as the chain left it, before step 3 could defer it.
    // Only the wakeup gate reads this: a cycle that decided a flush must not
    // hand out a permit even if the FP block pushed that flush to next cycle.
    logic flush_decided;

    always_comb begin
        commit_valid[0]         = 1'b0;
        commit_valid[1]         = 1'b0;
        flush_valid             = 1'b0;
        flush_tag               = head_tag[0];
        recovery_kind           = '0;
        head1_eval              = 1'b0;
        flush_from_head1_commit = 1'b0;
        flush_decided           = 1'b0;

        // -------- step 1 --------
        if (!head0_valid || !head0_done) begin
            // 1: commit nothing, and head1 is NOT evaluated
            head1_eval = 1'b0;
        end else if (h0_exception) begin
            // 2: head0 does not commit; flush from head0.  An exception is the
            // only terminal state of that tag even if the store already had a
            // wakeup, so it outranks ordinary retire.
            flush_valid   = 1'b1;
            flush_tag     = head_tag[0];
            recovery_kind = RECOVERY_EXCEPTION;
        end else if (interrupt_take && interrupt_boundary_ok) begin
            // 3: an external interrupt outranks head0's FENCE.I / mispredict /
            // MRET, but only on a takeable boundary.
            flush_valid   = 1'b1;
            recovery_kind = RECOVERY_INTERRUPT;
            if (!head0_irrevocable) begin
                // revocable head0: simply not retired, flush starts at it
                flush_tag = head_tag[0];
            end else begin
                // irrevocable head0 (the boundary test guarantees head1_valid
                // here): it must retire first and the trap boundary moves to
                // head1.
                commit_valid[0] = 1'b1;
                flush_tag       = head_tag[1];
            end
        end else if (h0_is_mret || h0_is_sret || h0_is_fence_i || h0_mispredict) begin
            // 4: head0 commits, then flushes.  is_fence_i is the one flush
            // trigger that comes from the alloc batch rather than the event
            // batch -- without it FENCE.I would fall into branch 5 and the
            // refetch would simply never happen.
            // Coexisting event bits are taken as MRET > SRET > FENCE_I >
            // mispredict (exception already won in branch 2).  is_mret and
            // is_sret are mutually exclusive -- both listed only for a
            // complete table.  (文档 ③ 决策链)
            commit_valid[0] = 1'b1;
            flush_valid     = 1'b1;
            flush_tag       = head_tag[0];
            if (h0_is_mret) begin
                recovery_kind = RECOVERY_MRET;
            end else if (h0_is_sret) begin
                recovery_kind = RECOVERY_SRET;
            end else if (h0_is_fence_i) begin
                recovery_kind = RECOVERY_FENCE_I;
            end else begin
                recovery_kind = RECOVERY_MISPREDICT;
            end
        end else begin
            // 5: ordinary retire of head0 -- the only path that lets head1 be
            // looked at at all
            commit_valid[0] = 1'b1;
            head1_eval      = 1'b1;
        end

        // -------- step 2 --------
        // head1 can never be a serial instruction: a serial instruction is
        // dispatched only into an empty window and blocks everything younger,
        // so it owns the window alone and head1_valid is 0.  MRET therefore
        // cannot appear here, and neither can FENCE.I -- the FENCE_I arm below
        // exists only because ④#5 gives that row a flush_tag and ④#3 step 3
        // names it, i.e. to leave no undefined behaviour, not to describe a
        // reachable case.
        if (head1_eval && head1_valid && head1_done) begin
            if (h1_exception) begin
                // head1 does not commit; head0 already did => commit_count = 1
                flush_valid   = 1'b1;
                flush_tag     = head_tag[1];
                recovery_kind = RECOVERY_EXCEPTION;
            end else if (h1_is_fence_i || h1_mispredict) begin
                // both retire => commit_count = 2, then flush.  Coexisting
                // bits are taken FENCE_I > mispredict, as in step 1.
                commit_valid[1]         = 1'b1;
                flush_valid             = 1'b1;
                flush_tag               = head_tag[1];
                recovery_kind           = h1_is_fence_i ? RECOVERY_FENCE_I
                                                        : RECOVERY_MISPREDICT;
                flush_from_head1_commit = 1'b1;
            end else begin
                commit_valid[1] = 1'b1;
            end
        end

        // -------- step 3 --------
        // Two rd_write_enable & rd_is_fp writes in one cycle would need a
        // second FP write / clear port, so the commit shrinks to one entry and
        // head1 waits for the next cycle.  If that head1 also carried a
        // commit-then-flush (MISPREDICT / FENCE_I), the flush is deferred with
        // it -- a flush is the action AFTER a commit, so a commit that did not
        // happen cannot flush.  Shortening the commit is allowed; dropping a
        // write or flushing early to dodge the block is not.  The combination
        // is currently unreachable (a mispredicting head1 is a branch, with
        // rd_is_fp = 0); it is written out so the behaviour is defined.
        flush_decided = flush_valid;

        if (commit_valid[0] && commit_valid[1] && h0_fp_write && h1_fp_write) begin
            commit_valid[1] = 1'b0;
            if (flush_from_head1_commit) begin
                flush_valid   = 1'b0;
                flush_tag     = head_tag[0];
                recovery_kind = '0;
            end
        end
    end

    // ------------------------------------------------------------------
    // (4)#3 commit bus assembly.  rd_* comes from the alloc batch and
    // commit_fflags from the writeback batch, both read at headK.  A lane with
    // commit_valid = 0 carries placeholders only.
    // ------------------------------------------------------------------
    always_comb begin
        commit_tag[0]             = commit_valid[0] ? head_tag[0] : '0;
        commit_tag[1]             = commit_valid[1] ? head_tag[1] : '0;
        commit_rd_idx[0]          = entry_rd_idx[head_tag[0]];
        commit_rd_idx[1]          = entry_rd_idx[head_tag[1]];
        commit_rd_is_fp[0]        = entry_rd_is_fp[head_tag[0]];
        commit_rd_is_fp[1]        = entry_rd_is_fp[head_tag[1]];
        commit_rd_write_enable[0] = entry_rd_write_enable[head_tag[0]];
        commit_rd_write_enable[1] = entry_rd_write_enable[head_tag[1]];
        commit_fflags[0]          = entry_fpu_fflags[head_tag[0]];
        commit_fflags[1]          = entry_fpu_fflags[head_tag[1]];
        commit_count              = {1'b0, commit_valid[0]} + {1'b0, commit_valid[1]};
    end

    // ------------------------------------------------------------------
    // (4)#4 the plain-store early wakeup pulse.
    //
    // At most one per cycle.  It does not need head0_done and does not wait
    // for the store's G3 issue; the scan input is the cycle-start registered
    // state, so an entry allocated this cycle cannot become a candidate until
    // the next one.  Any flush verdict this cycle outranks it, so the permit
    // is never handed to a tag that is being killed or reused, and the same
    // tag never takes a terminal event and a fresh wakeup together.
    //
    // global_flush_late is deliberately NOT a guard here: ⑥ scopes it to the
    // writeback / capture path only.
    // ------------------------------------------------------------------
    logic wb_hits_wakeup_tag;
    logic wk_authorize;
    logic resolve_in_place;

    // ------------------------------------------------------------------
    // 授权有两条投递路径，**互斥**，按 store 此刻在哪儿选：
    //
    //   还在 ISQ_Group3 里     → 就地把 entry_st_br_resolve 置 1
    //                            （桥在发射拍组合读这一位，store 出去时就是
    //                             已授权的，根本不需要脉冲）
    //   已经进了 LSU           → 发 store_wakeup 脉冲
    //
    // 这是 2026-08-26 的改造。**改造前 entry_st_br_resolve 只在 alloc 拍写
    // 一次、此后冻结**，于是唤醒扫描无从知道目标在哪儿，脉冲可能在 store
    // 还驻留 ISQ3 时就发出去 —— lsu_bridge 那套 wakeup_held_q 正是为了
    // 兜住这种「发射前唤醒」而存在的。把投递路径按位置分开之后，
    // 发射前唤醒不再产生，那套机制随之退役。
    //
    // 判据里 st_br_resolve_tag_valid 不可省（洞 A）：ISQ3 空时读地址是残留值。
    // ------------------------------------------------------------------
    always_comb begin
        wb_hits_wakeup_tag = 1'b0;
        for (int unsigned g = 0; g < NUM_LANES; g++) begin
            if (writeback_valid[g] && !global_flush_late && (tag_out[g] == wk_tag)) begin
                wb_hits_wakeup_tag = 1'b1;
            end
        end

        // 共同的授权前提。flush_decided / wb_hits_wakeup_tag 两个限定
        // **两条路径都要带** —— 只给脉冲带、不给就地解析带的话，
        // 正在被冲掉的 store 会从新路径拿到授权。
        wk_authorize     = wk_found && wk_cand_ok
                        && !flush_decided && !wb_hits_wakeup_tag;

        resolve_in_place = wk_authorize
                        && st_br_resolve_tag_valid
                        && (st_br_resolve_tag == wk_tag);

        store_wakeup_valid = wk_authorize && !resolve_in_place;
        store_wakeup_tag   = wk_tag;
    end

    // ------------------------------------------------------------------
    // (4)#6 recovery read port (flush_model) and the st_br_resolve read port
    // (G3 issue boundary).
    //
    // The recovery reads index the flush_tag this module's own decision chain
    // produced -- flush_model does not send an address back.  flush_tag is
    // driven on every path of that chain (it defaults to head_tag[0]), so these
    // three reads never float, including on the MRET branch whose flush_tag is
    // head_tag[0] and is not used to pick the recovery address.
    //
    // st_br_resolve 读口带**同拍组合前递**（洞 B）。
    //
    // resolve_in_place 的置位要等时钟沿，而 store 可能**就在这一拍**从
    // ISQ3 发往 LSU。只读寄存器的话桥拿到的是旧值 0，发出去一个未授权的
    // 请求，而寄存器更新晚一拍落到一个已经走掉的表项上 —— 解析丢了。
    //
    // 前递让「授权」这件事只有一条时序路径：本拍决定、本拍可见。
    // 备选方案是识别这一拍改发脉冲，那等于把 wakeup_held_q 又留一半，
    // 不取。
    //
    // 前递条件里的 tag 比较是冗余的（resolve_in_place 已经要求
    // st_br_resolve_tag == wk_tag），显式写出来是为了让这一行自明，
    // 不依赖上面那个 always_comb 的内部条件。
    //
    // **原注释「st_br_resolve is a frozen snapshot」已不再成立** ——
    // 它正是本次改造推翻的前提。
    // ------------------------------------------------------------------
    always_comb begin
        recovery_mispredict_target_pc = entry_mispredict_target_pc[flush_tag];
        recovery_exception_cause      = entry_exception_cause[flush_tag];
        recovery_exception_tval       = entry_exception_tval[flush_tag];
        st_br_resolve                 = entry_st_br_resolve[st_br_resolve_tag]
                                     || (resolve_in_place
                                         && (st_br_resolve_tag == wk_tag));
    end

    // ------------------------------------------------------------------
    // (1) alloc-time st_br_resolve.
    //
    // Combined across the two alloc slots on cycle-start values.  slot 1 must
    // not miss an accepted slot 0, and slot 0's st_br_resolve = 1 is NOT proof
    // that slot 0 will stay exception-free: only a may_flush = 0 slot 0 is
    // safe for slot 1.
    // ------------------------------------------------------------------
    logic prefix_safe_1;
    logic st_br_resolve_alloc [ISSUE_WIDTH];

    always_comb begin
        st_br_resolve_alloc[0] = accept[0] && is_store[0] && prefix_safe_0;
        prefix_safe_1          = prefix_safe_0 && (!accept[0] || !may_flush[0]);
        st_br_resolve_alloc[1] = accept[1] && is_store[1] && prefix_safe_1;
    end

    // ------------------------------------------------------------------
    // (3) pointer landing.
    //
    // head_new = head + commit_count lands this cycle's retire FIRST -- a
    // flush clears, it does not cancel a commit -- and only then does
    // tail_new = head_new roll back.  The rollback looks at commit_count
    // alone: under MISPREDICT / MRET the flush_tag names an entry that has
    // already retired, and landing on it would throw that entry away.
    // ------------------------------------------------------------------
    logic [$clog2(ISSUE_WIDTH+1)-1:0] alloc_count;
    logic [ROB_PTR_W-1:0]             head_next;
    logic [ROB_PTR_W-1:0]             tail_next;

    always_comb begin
        alloc_count = {1'b0, accept[0]} + {1'b0, accept[1]};
        head_next   = head_q + ROB_PTR_W'(commit_count);
        tail_next   = flush_valid ? head_next : (tail_q + ROB_PTR_W'(alloc_count));
    end

    // ------------------------------------------------------------------
    // (2) the sequential state.
    //
    // Write order inside the cycle: writeback, then the wakeup pulse, then
    // alloc.  alloc is last on purpose -- clearing exec_done and
    // store_wakeup_issued at alloc is a correctness obligation, because a
    // flush leaves the per-tag bits untouched and a reused slot has nothing
    // else to clean it.
    // ------------------------------------------------------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            head_q <= '0;
            tail_q <= '0;
            for (int unsigned i = 0; i < ROB_DEPTH; i++) begin
                entry_exec_done[i]            <= 1'b0;
                entry_store_wakeup_issued[i]  <= 1'b0;
                entry_rd_idx[i]               <= '0;
                entry_rd_is_fp[i]             <= 1'b0;
                entry_rd_write_enable[i]      <= 1'b0;
                entry_is_store[i]             <= 1'b0;
                entry_is_fence_i[i]           <= 1'b0;
                entry_may_flush[i]            <= 1'b0;
                entry_is_atomic[i]            <= 1'b0;
                entry_st_br_resolve[i]        <= 1'b0;
                entry_mispredict_flag[i]      <= 1'b0;
                entry_exception_flag[i]       <= 1'b0;
                entry_is_mret[i]              <= 1'b0;
                entry_is_sret[i]              <= 1'b0;
                entry_mispredict_target_pc[i] <= '0;
                entry_exception_cause[i]      <= '0;
                entry_exception_tval[i]       <= '0;
                entry_fpu_fflags[i]           <= '0;
            end
        end else begin
            head_q <= head_next;
            tail_q <= tail_next;

            // (3) writeback: exec_done <- 1 plus the event batch and fflags.
            // Four concurrent, randomly addressed ports; the four tag_out
            // values belong to four different in-flight tags, so the addresses
            // are orthogonal.  !global_flush_late only covers the flush cycle
            // itself -- late completions are held off by the FU flush
            // contract, which is the FU's own behaviour.
            for (int unsigned g = 0; g < NUM_LANES; g++) begin
                if (writeback_valid[g] && !global_flush_late) begin
                    entry_exec_done[tag_out[g]]            <= 1'b1;
                    entry_mispredict_flag[tag_out[g]]      <= mispredict_flag[g];
                    entry_mispredict_target_pc[tag_out[g]] <= mispredict_target_pc[g];
                    entry_exception_flag[tag_out[g]]       <= exception_flag[g];
                    entry_exception_cause[tag_out[g]]      <= exception_cause[g];
                    entry_exception_tval[tag_out[g]]       <= exception_tval[g];
                    entry_is_mret[tag_out[g]]              <= is_mret[g];
                    entry_is_sret[tag_out[g]]              <= is_sret[g];
                    entry_fpu_fflags[tag_out[g]]           <= fpu_fflags[g];
                end
            end

            // (3) store_wakeup: the issued bit is kept until the entry leaves
            // [head, tail); a terminal normal done does not clear it.
            if (store_wakeup_valid) begin
                entry_store_wakeup_issued[store_wakeup_tag] <= 1'b1;
            end

            // (3) 就地解析：store 还在 ISQ3 里等操作数/FU 时，授权直接落进
            // 它的表项。置位之后 scan_is_cand 不再选它（它要求
            // !entry_st_br_resolve），所以这是**一次性**的，不会反复触发。
            //
            // 放在 alloc 之前：同拍不可能撞（resolve_in_place 的目标是已经
            // 驻留 ISQ3 的旧 tag，alloc 的目标是新 tag），但万一将来撞了，
            // alloc 是更新的事实，应该赢。
            if (resolve_in_place) begin
                entry_st_br_resolve[wk_tag] <= 1'b1;
            end
`ifndef SYNTHESIS
            // 授权走了哪条路径 —— **这不是调试残留，是覆盖判据。**
            //
            // 两条路径的架构结果完全一样（store 照样写对地址），所以自检 ELF
            // 判不出差别，**回归全绿本身证明不了就地解析这条路被走到过**。
            // 需要一个直接的覆盖判据，就是这两行日志。
            //
            // 实测 125 例里 8 例走到（ld_st 55 次、st_ld 22 次、ma_data 21 次、
            // ma_addr 10 次、rvc 4 次、fence_i / sb 各 1 次，加定向那例 2 次）。
            // 都是访存密集、store 地址来自刚算出的值、因而卡在 ISQ3 的场合。
            // subop/check_store_resolve.py 跑定向那例并查这里的 in_place 行。
            if (resolve_in_place)
                $display("[SCB][STORE_AUTH] in_place tag=%0d", wk_tag);
            if (store_wakeup_valid)
                $display("[SCB][STORE_AUTH] wakeup   tag=%0d", store_wakeup_tag);
`endif

            // (3) alloc: the whole batch lands in entry[alloc_self_tag[s]] and
            // the two per-tag bits are cleared.
            for (int unsigned s = 0; s < ISSUE_WIDTH; s++) begin
                if (accept[s]) begin
                    entry_rd_idx[alloc_self_tag[s]]              <= rd_idx[s];
                    entry_rd_is_fp[alloc_self_tag[s]]            <= rd_is_fp[s];
                    entry_rd_write_enable[alloc_self_tag[s]]     <= rd_write_enable[s];
                    entry_is_store[alloc_self_tag[s]]            <= is_store[s];
                    entry_is_fence_i[alloc_self_tag[s]]          <= is_fence_i[s];
                    entry_may_flush[alloc_self_tag[s]]           <= may_flush[s];
                    entry_is_atomic[alloc_self_tag[s]]           <= is_atomic[s];
                    entry_st_br_resolve[alloc_self_tag[s]]       <= st_br_resolve_alloc[s];
                    entry_exec_done[alloc_self_tag[s]]           <= 1'b0;
                    entry_store_wakeup_issued[alloc_self_tag[s]] <= 1'b0;
                end
            end
        end
    end

endmodule

`endif // COMPLETIONSCOREBOARD_SV
