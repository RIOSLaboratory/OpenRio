`ifndef G3_LSU_IFACE_SV
`define G3_LSU_IFACE_SV

/* verilator lint_off IMPORTSTAR */
import or_be_lsu_protocol_pkg::*;
import or_be_types_pkg::*;
/* verilator lint_on IMPORTSTAR */

// g3_lsu_iface -- the boundary bridge between ISQ_Group3 / CompletionScoreboard
// and the LSU proper.
//
// It does exactly these four things and nothing else:
//
//   1 assemble   ISQ_Group3's nine issue fields + req_property_from_subop() +
//                the SCB alloc-header st_br_resolve  ->  be_lsu_issue_pld_t
//   2 fold       the LSU's class-qualified acceptance into one FU_ready
//   3 relay      the SCB's tagged store_wakeup as the LSU's untagged pulse
//   4 merge      the LSU's done / exception into ONE lane-3 completion_common
//                plus the lane-3 CDB broadcast
//
// It is not a second retirement authority: no flush, no cause decision, no
// architectural state, no second copy of the SCB's bits.
//
// The LSU-facing names are the wire-level truth.
// Two of them are pass-throughs on the out-event side --
// `global_flush_late` and `rst_n`.  A module cannot have an input and an output
// of the same name, and the name is frozen, so they stay single input ports
// here and the top level fans the same net out to lsu_if (that is what
// "pass-through" means).  Likewise the SCB header read address is
// `self_tag`, i.e. the issue tag: the top level drives
// CompletionScoreboard.st_br_resolve_tag from the same ISQ_Group3 output, and
// only the selected bit comes back on `st_br_resolve`.
module g3_lsu_iface (
    input  logic                        clk,
    input  logic                        rst_n,

    // ------------------------------------------------------------------
    // in-event: issue (transaction, single strobe, 1 read port).  Nine
    // payload fields plus the trigger.  ISQ_Group3 drives the nine
    // unconditionally and holds valid+payload stable until the handshake
    // succeeds; `issue_valid` is its REQUEST line and does not contain
    // FU_ready, so the transfer is issue_valid ∧ FU_ready.
    // ------------------------------------------------------------------
    input  logic                        issue_valid,
    input  logic [TAG_W-1:0]            self_tag,
    input  logic [EXE_SUBOP_W-1:0]      exe_subop,
    input  logic [MEM_FUNCT3_W-1:0]     mem_funct3,
    input  logic                        rd_is_fp,
    input  logic [XLEN-1:0]             rs1_data,
    input  logic [XLEN-1:0]             rs2_data,
    input  logic                        imm_valid,
    // This is `signed 64`: decode already sign-extended it and it must not be
    // re-truncated here.  The producing port on ISQ_Group3 is
    // declared unsigned; the two ends of one net may differ in
    // signedness, the 64 bits are carried unchanged either way.
    input  logic signed [XLEN-1:0]      imm_data,
    // plain-store compatibility bit as ISQ_Group3 carries it (decode's
    // classification).  The assembled be_lsu_issue_pld.is_store is taken
    // straight from THIS port, not from req_property; the rule that it must equal
    // req_property.is_store is checked by lsu_if.sv's property, see the
    // assembly below.
    input  logic                        is_store,

    // ------------------------------------------------------------------
    // in: combinational read -- the SCB alloc header addressed by the issue's
    // self_tag (combinational read).  It is the alloc-cycle frozen
    // snapshot; it must not be overwritten with the current store_wakeup_issued, which is why this
    // is a plain read of somebody else's header and not local state.
    // ------------------------------------------------------------------
    input  logic                        st_br_resolve,

    // ------------------------------------------------------------------
    // in-event: store_wakeup (announce, 1-cycle pulse, no ready back).  May
    // arrive while the tag is still resident in ISQ_Group3.
    // ------------------------------------------------------------------
    input  logic                        store_wakeup_valid,
    input  logic [TAG_W-1:0]            store_wakeup_tag,

    // ------------------------------------------------------------------
    // in-event: flush (announce, single-wire pulse)
    // ------------------------------------------------------------------
    input  logic                        global_flush_late,

    // ------------------------------------------------------------------
    // in: LSU side (out of library; lsu_if.sv is the wire-level truth).
    //
    // lsu_be_issue_ready is a combinational level already qualified BY CLASS on
    // the LSU side (lsu_be_issue_ready = rst_n ∧ !(store_side ∧
    // store_buffer_full)).  This module consumes that one wire only --
    // lsu_store_buffer_full deliberately has no port here -- and must never
    // make it depend on be_lsu_issue_valid.
    //
    // The three result valids arrive ALREADY qualified with !global_flush_late
    // by lsu_if.sv.
    // ------------------------------------------------------------------
    input  logic                        lsu_be_issue_ready,
    input  logic                        lsu_be_done_valid,
    input  lsu_be_done_pld_t            lsu_be_done_pld,
    input  logic                        lsu_be_exception_valid,
    input  lsu_be_exception_pld_t       lsu_be_exception_pld,
    input  logic                        lsu_be_bypass_valid,
    // Same type as done (the frozen package has no separate bypass
    // payload); lsu_if.sv's p_bypass_payload_matches_done makes it equal to
    // lsu_be_done_pld, so the merge below reads the done payload and uses this
    // channel's VALID as the read-side qualifier.
    input  lsu_be_done_pld_t            lsu_be_bypass_pld,

    // ------------------------------------------------------------------
    // out: FU_ready -> ISQ_Group3 (broadcast combinational level)
    // ------------------------------------------------------------------
    output logic                        FU_ready,

    // ------------------------------------------------------------------
    // out-event: completion -> lane 3 (completion_common shape).
    // mispredict_flag / is_mret / is_sret / fpu_fflags are constant zero and are driven
    // HERE: lane 3 has no arbiter to fill them in ("constant-zero fields are
    // driven by the FU, the arbiter does not fabricate them").  mispredict_target_pc is the same kind of constant
    // zero -- completion_common carries it and the
    // SCB's lane-3 input needs a driver, so it follows the same rule.
    // ------------------------------------------------------------------
    output logic                        Result_valid,
    output logic [TAG_W-1:0]            tag_out,
    output logic [XLEN-1:0]             result_data,
    output logic                        mispredict_flag,
    output logic [XLEN-1:0]             mispredict_target_pc,
    output logic                        exception_flag,
    output logic [EXCP_CAUSE_W-1:0]     exception_cause,
    output logic [XLEN-1:0]             exception_tval,
    output logic                        is_mret,
    output logic                        is_sret,
    output logic [FFLAGS_W-1:0]         fpu_fflags,

    // ------------------------------------------------------------------
    // out-event: bypass -> lane 3 of the 4-lane CDB.  Same cycle as the
    // completion, no ready, never repeated.
    // ------------------------------------------------------------------
    output logic                        bypass_valid,
    output logic [TAG_W-1:0]            bypass_tag,
    output logic [XLEN-1:0]             bypass_data,

    // ------------------------------------------------------------------
    // out: LSU side (out of library)
    // ------------------------------------------------------------------
    output logic                        be_lsu_issue_valid,
    output be_lsu_issue_pld_t           be_lsu_issue_pld,
    output logic                        be_lsu_entry_ready,
    output logic                        be_lsu_store_wakeup_valid
);

    // ------------------------------------------------------------------
    // Data structure.
    //
    //   state    wakeup_held / read_done / store_done   per tag, 16 (LSU_TAG_W)
    //            wakeup_pending_any                     one global reduction
    //   payload  held_data(64)                          per tag
    //   header   none -- the request fields are combinational pass-through
    //
    // req_in_flight is the one bit the list above does not have and this implementation
    // cannot do without: the wakeup_held set is conditioned on "this tag has
    // not issued yet" and bridge_has_room on "a tag's held_data
    // slot ... has nowhere to go", and neither predicate is answerable from
    // the boundary alone.  It is set by this module's own issue handshake and
    // cleared by that tag's terminal, so it holds exactly "this tag's request
    // is at the LSU right now".  It is
    // not a copy of an SCB or LSU state bit and it is not a request field.
    //
    // Without it a post-issue wakeup -- the normal case, the SCB wakes a store
    // that has long since been issued -- would be mislabelled as a held
    // pre-issue authorization, latch wakeup_pending_any and block every later
    // wakeup for good.
    // ------------------------------------------------------------------
    logic [ROB_DEPTH-1:0] wakeup_held_q;
    logic [ROB_DEPTH-1:0] read_done_q;
    logic [ROB_DEPTH-1:0] store_done_q;
    logic [ROB_DEPTH-1:0] req_in_flight_q;
    logic [XLEN-1:0]      held_data_q [ROB_DEPTH];

    logic                 wakeup_pending_any;
    assign wakeup_pending_any = |wakeup_held_q;

    // ------------------------------------------------------------------
    // Request assembly.  Combinational, nothing latched: ISQ_Group3 holds
    // the entry stable until the handshake, which is what makes the header
    // "none".
    //
    //   req_property   = req_property_from_subop(exe_subop)   frozen package,
    //                    never a local decode, and one-hot by construction
    //   is_store       = ISQ port pass-through (req_property.is_store is not
    //                    used); the compatibility bit must equal
    //                    req_property.is_store
    //   st_br_resolve  = the SCB header bit, forced to 0 for everything that is
    //                    not a plain store (st_br_resolve of AMO / SC /
    //                    LR / FENCE is constant 0, checked by lsu_if.sv's
    //                    p_st_br_resolve_zero_for_non_plain_store)
    //
    // Address arithmetic is deliberately absent: the AGU is left in the LSU
    // and base + already-sign-extended offset is handed over.
    // ------------------------------------------------------------------
    lsu_req_property_t req_property;
    assign req_property = req_property_from_subop(lsu_exe_subop_t'(exe_subop));

    always_comb begin
        be_lsu_issue_pld               = '0;
        be_lsu_issue_pld.self_tag      = self_tag;
        be_lsu_issue_pld.req_property  = req_property;
        be_lsu_issue_pld.exe_subop     = exe_subop;
        be_lsu_issue_pld.mem_funct3    = mem_funct3;
        be_lsu_issue_pld.rd_is_fp      = rd_is_fp;
        be_lsu_issue_pld.rs1_data      = rs1_data;
        be_lsu_issue_pld.rs2_data      = rs2_data;
        be_lsu_issue_pld.imm_valid     = imm_valid;
        be_lsu_issue_pld.imm_data      = imm_data;
        // **Take the ISQ port's is_store, not req_property.is_store.**
        // The two are independent sources by design: is_store comes from
        // decode's classification, req_property from
        // req_property_from_subop(exe_subop).
        be_lsu_issue_pld.is_store      = is_store;
        be_lsu_issue_pld.st_br_resolve = st_br_resolve && req_property.is_store;
    end

    // ------------------------------------------------------------------
    // Issue handshake.  valid and ready are decoupled in both directions:
    //
    //   - the payload above is driven unconditionally, because
    //     lsu_be_issue_ready is a FUNCTION of req_property and cannot be
    //     computed before the request is presented;
    //   - FU_ready never looks at issue_valid, so no loop closes through
    //     ISQ_Group3.
    //
    // bridge_has_room is this module's own resource gate.  held_data and the
    // per-tag bits are indexed by tag and the terminal path below is
    // combinational, so the only way a slot can be unavailable is a request
    // arriving for a tag whose previous request is still at the LSU -- which
    // the SCB's allocation makes impossible, and which would otherwise
    // overwrite that tag's held_data.  It can therefore never lower FU_ready
    // in a correct machine, and it is a criterion rather than a
    // hard-wired 1.
    //
    // be_lsu_issue_valid carries the same gate so the two ends see ONE
    // handshake: ISQ_Group3 releases on issue_valid ∧ FU_ready, the LSU accepts
    // on be_lsu_issue_valid ∧ lsu_be_issue_ready, and the two expressions are
    // identical (ISQ_Group3's issue_valid already excludes the flush cycle).
    // ------------------------------------------------------------------
    logic bridge_has_room;
    logic issue_accept;

    assign bridge_has_room    = !req_in_flight_q[self_tag];
    assign FU_ready           = bridge_has_room && lsu_be_issue_ready;
    assign be_lsu_issue_valid = issue_valid && bridge_has_room &&
                                !global_flush_late;
    assign issue_accept       = be_lsu_issue_valid && lsu_be_issue_ready;

    // Constant 1 except under reset and on the flush cycle.  It is an
    // acknowledge for the LSU's registered result channels, never backpressure.
    assign be_lsu_entry_ready = rst_n && !global_flush_late;

    // ------------------------------------------------------------------
    // store_wakeup: tagged -> untagged.
    //
    // The pulse is relayed the cycle it arrives.  wakeup_held[tag] records an
    // authorization the LSU is holding for a store that has not reached it yet;
    // while any such authorization is outstanding a second one must not be
    // relayed, because two untagged authorizations at the LSU cannot be told
    // apart.  This is a double check on top of the SCB's own
    // at-most-one-per-cycle guarantee.
    //
    // A wakeup that coincides with its own tag's acceptance is consumed on the
    // spot and holds nothing (the same 2'b11 case lsu_if.sv's tracker clears).
    // ------------------------------------------------------------------
    logic wakeup_in;
    logic wakeup_accept;
    logic wakeup_consumed_at_issue;
    logic wakeup_target_present;
    logic wakeup_relay_now;
    logic wakeup_relay_held;
    logic wakeup_hold_set;

    assign wakeup_in                = store_wakeup_valid && rst_n &&
                                      !global_flush_late;
    assign wakeup_accept            = wakeup_in && !wakeup_pending_any;
    assign wakeup_consumed_at_issue = issue_accept &&
                                      (self_tag == store_wakeup_tag);

    // **The wakeup at the LSU boundary is untagged**: the LSU can only apply
    // it to its own oldest unauthorized store. So it can be relayed only when
    // the target store **has already been (or is this cycle) issued to the
    // LSU**; otherwise the LSU has nothing to apply it to, and cache_agent
    // reports an unmatched store wakeup.
    assign wakeup_target_present = req_in_flight_q[store_wakeup_tag]
                                || wakeup_consumed_at_issue;
    assign wakeup_relay_now      = wakeup_accept && wakeup_target_present;

    // A previously held authorization is delivered late, in the cycle its
    // store actually issues. Without this: the held bit is cleared by
    // issue_accept, the authorization never reaches the LSU, and that store
    // waits forever for authorization.
    assign wakeup_relay_held     = issue_accept && wakeup_held_q[self_tag];

    assign wakeup_hold_set       = wakeup_accept && !wakeup_target_present;

    assign be_lsu_store_wakeup_valid = wakeup_relay_now || wakeup_relay_held;

`ifndef SYNTHESIS
    // ------------------------------------------------------------------
    // **A wakeup before issue should never happen.**
    //
    // CompletionScoreboard delivers the authorization by where the store is:
    // still in ISQ_Group3 -> set entry_st_br_resolve to 1 in place (the bridge
    // reads it combinationally in the issue cycle); already in the LSU -> send
    // the pulse. The two paths are mutually exclusive, so the pulse's target
    // is necessarily already in flight.
    //
    // **wakeup_held_q is kept as a fallback.** Regression cases cannot produce
    // a wakeup before issue, so a silent assertion proves nothing; the
    // directed case or-p-store_resolve_in_isq covers the in-place resolve
    // path, and the assertion does not fire.
    //
    // The assertion exists only in simulation and is compiled out in
    // synthesis. Should a wakeup before issue ever occur, the wakeup_held_q
    // fallback only costs one extra cycle; without it the authorization is
    // silently lost and that store hangs forever. **The cost of redundant
    // logic is far smaller than a silent hang.**
    // ------------------------------------------------------------------
    // The reset sensitivity list matches the whole design (async). Writing
    // @(posedge clk) and then reading rst_n synchronously triggers
    // SYNCASYNCNET -- the same rst_n used both async and sync.
    // always rather than always_ff: this block has no non-blocking assignment.
    always @(posedge clk or negedge rst_n) begin
        if (rst_n && wakeup_hold_set) begin
            $error("[g3_lsu_iface] pre-issue store wakeup for tag %0d: SCB pulsed a tag that is neither in flight nor issuing this cycle. After the 2026-08-26 SCB change this should be unreachable.",
                   store_wakeup_tag);
            $stop;
        end
    end
`endif

    // ------------------------------------------------------------------
    // Terminal merge.
    //
    // The done channel carries {tag, data} only and no per-tag copy of the
    // request is kept, so the class information available at terminal time
    // is exactly what the LSU rides with the done: lsu_be_bypass_valid is
    // raised with, and only with, a done that carries a read-side result
    // (lsu_if.sv p_bypass_rides_normal_completion).  That is `read_side`
    // at this boundary.
    //
    // The frozen LSU reports one done per request and only once every side it
    // has has landed, so the two bits are set together by that done and every
    // case -- read-only, store-only, read ∧ store (AMO/SC), and
    // the misc fence case -- becomes true on that same cycle.  read_done takes
    // the read-side qualifier; store_done takes the done itself, meaning "the
    // write side, if any, has landed".
    //
    // done and exception are mutually exclusive on the wire (lsu_if.sv
    // p_terminal_channels_mutually_exclusive) and both are already qualified
    // with !global_flush_late there; this module additionally must
    // send no lane-3 completion on a flush cycle, so the qualification is
    // repeated here instead of being borrowed.
    // ------------------------------------------------------------------
    logic             done_in;
    logic             exc_in;
    logic             read_side_result;
    logic [TAG_W-1:0] done_tag;
    logic [TAG_W-1:0] exc_tag;
    logic             terminal_in;
    logic [TAG_W-1:0] terminal_tag;

    assign done_in          = lsu_be_done_valid      && !global_flush_late;
    assign exc_in           = lsu_be_exception_valid && !global_flush_late;
    assign read_side_result = lsu_be_bypass_valid    && !global_flush_late;
    assign done_tag         = lsu_be_done_pld.tag;
    assign exc_tag          = lsu_be_exception_pld.tag;
    assign terminal_in      = done_in || exc_in;
    assign terminal_tag     = exc_in ? exc_tag : done_tag;

    // Next-state bits for the tag this done names, i.e. the values the
    // terminal merge is evaluated on.
    logic read_done_next;
    logic store_done_next;
    logic req_sides_complete;

    assign read_done_next     = read_done_q[done_tag]  ||
                                (done_in && read_side_result);
    assign store_done_next    = store_done_q[done_tag] || done_in;
    assign req_sides_complete = read_done_next || store_done_next;

    // result_data ← read_side ? held_data : 0.  held_data[tag] is written
    // by this same done, so the read is the
    // write-through of
    // that write; the stored path is what carries the result if a read side
    // ever returns ahead of its write side.
    logic [XLEN-1:0] held_data_rd;
    assign held_data_rd = (done_in && read_side_result) ? lsu_be_done_pld.data
                                                        : held_data_q[done_tag];

    // ------------------------------------------------------------------
    // Lane-3 completion_common.
    // ------------------------------------------------------------------
    assign Result_valid         = (done_in && req_sides_complete) || exc_in;
    assign tag_out              = terminal_tag;
    assign result_data          = read_side_result ? held_data_rd : {XLEN{1'b0}};
    assign exception_flag       = exc_in;
    assign exception_cause      = exc_in ?
        {{(EXCP_CAUSE_W-LSU_CAUSE_W){1'b0}}, lsu_be_exception_pld.cause} :
        {EXCP_CAUSE_W{1'b0}};
    assign exception_tval       = exc_in ? lsu_be_exception_pld.tval
                                         : {XLEN{1'b0}};
    assign mispredict_flag      = 1'b0;
    assign mispredict_target_pc = {XLEN{1'b0}};
    assign is_mret              = 1'b0;
    assign is_sret              = 1'b0;   // G3 zero
    assign fpu_fflags           = {FFLAGS_W{1'b0}};

    // ------------------------------------------------------------------
    // Lane-3 CDB broadcast.  Same cycle as the completion, never on an
    // exception, never repeated.
    // ------------------------------------------------------------------
    assign bypass_valid = Result_valid && read_side_result && !exception_flag;
    assign bypass_tag   = done_tag;
    assign bypass_data  = held_data_rd;

    // ------------------------------------------------------------------
    // State transitions.  A flush clears every per-tag bit and
    // held_data, exactly like reset, and the terminals arriving on that cycle
    // are dropped without any recovery cycles -- the LSU does not re-drive them
    // and the tags are immediately reusable.
    // ------------------------------------------------------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wakeup_held_q   <= {ROB_DEPTH{1'b0}};
            read_done_q     <= {ROB_DEPTH{1'b0}};
            store_done_q    <= {ROB_DEPTH{1'b0}};
            req_in_flight_q <= {ROB_DEPTH{1'b0}};
            for (int unsigned i = 0; i < ROB_DEPTH; i++) begin
                held_data_q[i] <= {XLEN{1'b0}};
            end
        end else if (global_flush_late) begin
            wakeup_held_q   <= {ROB_DEPTH{1'b0}};
            read_done_q     <= {ROB_DEPTH{1'b0}};
            store_done_q    <= {ROB_DEPTH{1'b0}};
            req_in_flight_q <= {ROB_DEPTH{1'b0}};
            for (int unsigned i = 0; i < ROB_DEPTH; i++) begin
                held_data_q[i] <= {XLEN{1'b0}};
            end
        end else begin
            // wakeup_held: set by a held (not relayed) pre-issue authorization, cleared
            // when that tag's request reaches the LSU (the authorization is
            // consumed there).  The issue clear is written second so a
            // same-cycle set and clear resolves to "consumed".
            if (wakeup_hold_set) begin
                wakeup_held_q[store_wakeup_tag] <= 1'b1;
            end
            if (issue_accept) begin
                wakeup_held_q[self_tag] <= 1'b0;
            end

            // read_done / store_done / held_data: written by lsu_done_in.
            if (done_in) begin
                store_done_q[done_tag] <= 1'b1;
                if (read_side_result) begin
                    read_done_q[done_tag] <= 1'b1;
                    held_data_q[done_tag] <= lsu_be_done_pld.data;
                end
            end

            // req_in_flight: the "not yet issued" / "slot in use" predicate.
            // The terminal clear is written first so that an (impossible)
            // same-tag coincidence resolves to "in flight" rather than losing
            // the issue.
            if (terminal_in) begin
                req_in_flight_q[terminal_tag] <= 1'b0;
            end
            if (issue_accept) begin
                req_in_flight_q[self_tag] <= 1'b1;
            end
        end
    end

endmodule

`endif // G3_LSU_IFACE_SV
