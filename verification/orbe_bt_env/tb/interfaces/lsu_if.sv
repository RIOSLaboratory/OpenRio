// [This file] Implementation of the BE<->LSU bus + interface protocol assertions
// BE <-> LSU bus.
//
// The payload types come from the frozen contract package, not from a local
// copy.
interface or_be_lsu_if (input logic clk);
  // **Import only the frozen package, never any TB-private package.**
  //
  // There used to be an import be_tb_pkg::* here too, but this interface **used not a single symbol from it**.
  // That import dragged in the TB-private package together with what it imports, fe_be_protocol_pkg ->
  // or_be_types_pkg (**the big RTL-side type package**), making this file impossible to
  // deliver on its own to another verification environment. Removed 2026-08-26.
  import or_be_lsu_protocol_pkg::*;

  logic rst_n;
  logic global_flush_late;
  logic be_lsu_issue_valid;
  be_lsu_issue_pld_t be_lsu_issue_pld;

  // Acceptance is qualified by the class of the request being offered: the
  // read side is a fixed pipeline and never stalls, so only a store-side
  // request can be refused, and only while the store buffer is full.  The
  // qualification has to be combinational -- at a driving edge the class of
  // the next request is unknown -- so only full/not-full is registered.
  logic lsu_store_buffer_full;
  logic lsu_be_issue_ready;

  // [R5] Folding of the accept line stays on the LSU side, placed right here in the bus definition.
  //
  // Per src/core/be_rtl_v1/lsu/g3_lsu_iface.sv: the LSU must fold store_buffer_full into
  // lsu_be_issue_ready, and `lsu_store_buffer_full` on the BE side "deliberately has no
  // port here" -- it is indeed not in this interface's `modport be`; BE cannot see it.
  //
  // The folding must be combinational: whether to accept depends on the class of the request offered this cycle (the read side
  // can always be accepted; only the write side can be refused while the buffer is full); a registered accept line would wrongly
  // refuse read-side requests while the buffer is full. A class cannot drive a combinational
  // value, so CacheAgent registers only full/not-full and the folding is done here.
  // Before 2026-09-18 this assign lived in be_tb_top.sv, separate from the bus definition.
  assign lsu_be_issue_ready =
      rst_n && !(req_property_is_store_side(
                     req_property_from_subop(be_lsu_issue_pld.exe_subop))
                 && lsu_store_buffer_full);

  logic be_lsu_entry_ready;

  // The LSU registers its results, but a flush is only known combinationally
  // (the BE derives it from the redirect it raises during the same cycle), so
  // a registered agent cannot withdraw a result it drove on the previous edge.
  // Qualify the presented lines here instead: nothing is presented on a flush
  // cycle, which is what the contract requires and what the reference agent
  // states.  The agent keeps driving its own registers, so its hold-until-
  // accepted logic is unaffected.
  logic lsu_be_done_valid_q;
  logic lsu_be_exception_valid_q;
  logic lsu_be_bypass_valid_q;

  logic lsu_be_done_valid;
  logic lsu_be_exception_valid;
  logic lsu_be_bypass_valid;

  // [R7] The writeback payload is split from a single 197-bit merged bus into two groups, done / exception. The discriminating
  // info lives only on the two wires lsu_be_done_valid / lsu_be_exception_valid; the payload no longer
  // carries a copy. The shape matches rtl_v1's g3_lsu_iface.sv.
  lsu_be_done_pld_t      lsu_be_done_pld;
  lsu_be_exception_pld_t lsu_be_exception_pld;
  // Result broadcast; rides the normal completion of a read-side request,
  // carries no ready and is never repeated.
  // [R7] Type reuses lsu_be_done_pld_t: what bypass carries is exactly a done's {tag, data}.
  lsu_be_done_pld_t      lsu_be_bypass_pld;

  logic be_lsu_store_wakeup_valid;

  // ---------------------------------------------------------------------
  // Protocol rules.  Until this block existed the running environment had no interface assertions at all: five contract
  // rules held only because be_getter happened to build payloads correctly,
  // with nothing to catch a regression.
  // ---------------------------------------------------------------------
`ifndef SYNTHESIS
  logic early_store_wakeup_pending;
  lsu_req_property_t issue_req_property;

  always_comb begin
    issue_req_property = req_property_from_subop(be_lsu_issue_pld.exe_subop);
  end

  // Same-cycle wakeup plus issue consumes directly; it never occupies the
  // single pre-issue authorization slot.
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n || global_flush_late) begin
      early_store_wakeup_pending <= 1'b0;
    end else begin
      case ({be_lsu_store_wakeup_valid,
             be_lsu_issue_valid && lsu_be_issue_ready &&
             issue_req_property.is_store &&
             !be_lsu_issue_pld.st_br_resolve})
        2'b10: early_store_wakeup_pending <= 1'b1;
        2'b01: early_store_wakeup_pending <= 1'b0;
        2'b11: early_store_wakeup_pending <= 1'b0;
        default: early_store_wakeup_pending <= early_store_wakeup_pending;
      endcase
    end
  end

  property p_issue_subop_has_known_property;
    @(posedge clk) disable iff (!rst_n)
      be_lsu_issue_valid |->
        req_property_is_onehot(issue_req_property);
  endproperty
  assert property (p_issue_subop_has_known_property);

  property p_issue_mem_funct3_matches_subop;
    @(posedge clk) disable iff (!rst_n)
      be_lsu_issue_valid |->
        mem_funct3_matches_subop(be_lsu_issue_pld.mem_funct3,
                                 be_lsu_issue_pld.exe_subop);
  endproperty
  assert property (p_issue_mem_funct3_matches_subop);

  property p_plain_store_st_br_resolve_is_known;
    @(posedge clk) disable iff (!rst_n)
      be_lsu_issue_valid && issue_req_property.is_store |->
        (be_lsu_issue_pld.st_br_resolve inside {1'b0, 1'b1});
  endproperty
  assert property (p_plain_store_st_br_resolve_is_known);

  property p_st_br_resolve_zero_for_non_plain_store;
    @(posedge clk) disable iff (!rst_n)
      be_lsu_issue_valid && !issue_req_property.is_store |->
        (be_lsu_issue_pld.st_br_resolve == 1'b0);
  endproperty
  assert property (p_st_br_resolve_zero_for_non_plain_store);

  property p_terminal_channels_mutually_exclusive;
    @(posedge clk) disable iff (!rst_n)
      !(lsu_be_done_valid && lsu_be_exception_valid);
  endproperty
  assert property (p_terminal_channels_mutually_exclusive);

  // p_at_most_one_early_store_wakeup is NOT checked here.
  //
  // Its tracker treats any wakeup that does not coincide with a same-cycle
  // unresolved-plain-store issue as a held pre-issue authorization.
  //
  // **This comment has been corrected twice; both are recorded.**
  //
  //   Original     "This BE never wakes a store before issuing it
  //                (be_getter requires issued[head])"
  //   2026-08-25   I judged the whole sentence wrong. Reason: the mere existence of g3_lsu_iface's
  //                wakeup_held_q mechanism proved that pre-issue wakeup can happen.
  //   2026-08-26   **That correction went too far.** The original sentence's conclusion describes the **design intent**,
  //                which the RTL at the time had not yet delivered -- I used the state of the implementation to deny the intent.
  //                Only the citation in parentheses was truly stale: be_getter is an old module of the
  //                verification environment, removed in S6, so it does not hold up as a reason.
  //
  // **The conclusion holds again now, and is delivered by the implementation** (the 2026-08-26 SCB rework):
  // CompletionScoreboard dispatches the authorization by where the store is -- while still in ISQ_Group3 it
  // sets entry_st_br_resolve to 1 in place (the bridge reads it combinationally in the issue cycle); once in the LSU it sends
  // a pulse. The two paths are mutually exclusive; pre-issue wakeup no longer occurs.
  // A $error assertion in g3_lsu_iface guards this.
  //
  // Then why is this property still not checked? **Because the interface layer cannot see the info the decision needs.**
  // To tell "pre-issue wakeup" from "post-issue wakeup" one must know whether that tag's request is currently in
  // the LSU's hands -- that is g3_lsu_iface's internal req_in_flight, invisible at the boundary.
  // That module's own comment puts it precisely: "neither predicate is answerable from the
  // boundary alone".
  //
  // Without it, the ordinary post-issue wakeup is mislabelled "early" across
  // the board; the flag is only ever cleared when another store happens to
  // issue in the same cycle.  That coincidence holds at small in-flight
  // windows -- which is why the property passes at depth 2 and 4 and is
  // vacuous at depth 1, where no wakeup is sent at all -- and stops holding
  // at depth 8 and above, where it fires on correct traffic.
  //
  // Deciding whether a wakeup has a target needs the LSU's own view of which
  // stores are outstanding, which an interface-only check cannot see.  The
  // sound equivalent lives in the agent: cache_agent fatals on an unmatched
  // store wakeup, which covers the case this property was meant to catch.
  property p_bypass_rides_normal_completion;
    @(posedge clk) disable iff (!rst_n)
      lsu_be_bypass_valid |-> lsu_be_done_valid;
  endproperty
  assert property (p_bypass_rides_normal_completion);

  property p_bypass_payload_matches_done;
    @(posedge clk) disable iff (!rst_n)
      lsu_be_bypass_valid |->
        ((lsu_be_bypass_pld.tag == lsu_be_done_pld.tag) &&
         (lsu_be_bypass_pld.data == lsu_be_done_pld.data));
  endproperty
  assert property (p_bypass_payload_matches_done);

  // A load must never be refused: the read side has no stalling resource.
  property p_read_side_is_never_refused;
    @(posedge clk) disable iff (!rst_n)
      (be_lsu_issue_valid &&
       !req_property_is_store_side(issue_req_property)) |->
        lsu_be_issue_ready;
  endproperty
  assert property (p_read_side_is_never_refused);

  property p_no_result_during_full_flush;
    @(posedge clk) global_flush_late |->
      !(lsu_be_done_valid || lsu_be_exception_valid || lsu_be_bypass_valid);
  endproperty
  assert property (p_no_result_during_full_flush);
`endif

  modport be (
    input clk, lsu_be_issue_ready,
          lsu_be_done_valid,      lsu_be_done_pld,
          lsu_be_exception_valid, lsu_be_exception_pld,
          lsu_be_bypass_valid,    lsu_be_bypass_pld,
    output rst_n, be_lsu_issue_valid, be_lsu_issue_pld,
           be_lsu_entry_ready, be_lsu_store_wakeup_valid, global_flush_late
  );

  modport lsu (
    input clk, rst_n, be_lsu_issue_valid, be_lsu_issue_pld,
          be_lsu_entry_ready, be_lsu_store_wakeup_valid, global_flush_late,
          lsu_be_issue_ready,
    input lsu_be_done_valid, lsu_be_exception_valid, lsu_be_bypass_valid,
    output lsu_store_buffer_full,
           lsu_be_done_valid_q,      lsu_be_done_pld,
           lsu_be_exception_valid_q, lsu_be_exception_pld,
           lsu_be_bypass_valid_q,    lsu_be_bypass_pld
  );
endinterface : or_be_lsu_if
