// Mock-side BE <-> LSU bus.
//
// Signal names, payload types and semantics follow
// spec/接口文档/BE_LSU接口规范.md（现为 v5；原注释指向已改名的 _v4.md）。
// The payload types come from the frozen contract package, not from a local
// copy, so this interface and tb/interfaces/or_be_lsu_if.sv cannot drift apart.
interface or_be_lsu_if (input logic clk);
  // **只 import 冻结包，不 import 任何 TB 私有包。**
  //
  // 原先这里还有一条 import be_tb_pkg::*，但本接口**一个符号都没用到它**。
  // 那条 import 会把 TB 私有包连同它 import 的 fe_be_protocol_pkg →
  // or_be_types_pkg（**RTL 侧的大类型包**）一起拖进来，让本文件无法
  // 单独交付给别的验证环境。2026-08-26 切除。
  //
  // 交付面见 spec/接口文档/共享ISA模型使用契约.md。
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

  lsu_be_writeback_pld_t lsu_be_writeback_pld;
  // Result broadcast; rides the normal completion of a read-side request,
  // carries no ready and is never repeated.
  lsu_be_bypass_pld_t lsu_be_bypass_pld;

  logic be_lsu_store_wakeup_valid;

  // ---------------------------------------------------------------------
  // Protocol rules.  Ported verbatim from tb/interfaces/or_be_lsu_if.sv so
  // the two interfaces enforce the same contract.  Until this block existed
  // the running environment had no interface assertions at all: five contract
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
  // **这段注释被订正过两次，都记下来。**
  //
  //   原文        「This BE never wakes a store before issuing it
  //                (be_getter requires issued[head])」
  //   2026-08-25   我把整句判为错。理由是 g3_lsu_iface 的 wakeup_held_q
  //                机制存在即证明发射前唤醒可能发生。
  //   2026-08-26   **那次订正过头了。** 原句的结论描述的是**设计意图**，
  //                而当时的 RTL 还没兑现它 —— 我拿实现的现状去否定意图。
  //                真正过时的只有括号里那句引证：be_getter 是验证环境的
  //                旧模块，S6 已摘除，拿它当理由站不住。
  //
  // **结论现在重新成立，而且是被实现兑现的**（2026-08-26 的 SCB 改造）：
  // CompletionScoreboard 按 store 的位置分投授权 —— 还在 ISQ_Group3 里就
  // 就地把 entry_st_br_resolve 置 1（桥在发射拍组合读到），已进 LSU 才发
  // 脉冲。两条路径互斥，发射前唤醒不再产生。
  // g3_lsu_iface 里有一条 $error 断言守着这一点。
  //
  // 那为什么这条 property 仍然不查？**因为接口层看不到判断所需的信息。**
  // 要区分「发射前唤醒」与「发射后唤醒」，必须知道该 tag 的请求此刻在不在
  // LSU 手里 —— 那是 g3_lsu_iface 内部的 req_in_flight，边界上不可见。
  // 该模块自己的注释说得准确：「neither predicate is answerable from the
  // boundary alone」。
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
  //
  // tb/interfaces/or_be_lsu_if.sv still carries the property as written and
  // will hit the same false failure once its window opens.
  property p_bypass_rides_normal_completion;
    @(posedge clk) disable iff (!rst_n)
      lsu_be_bypass_valid |-> lsu_be_done_valid;
  endproperty
  assert property (p_bypass_rides_normal_completion);

  property p_bypass_payload_matches_done;
    @(posedge clk) disable iff (!rst_n)
      lsu_be_bypass_valid |->
        ((lsu_be_bypass_pld.tag == lsu_be_writeback_pld.tag) &&
         (lsu_be_bypass_pld.data == lsu_be_writeback_pld.data));
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
    input clk, lsu_be_issue_ready, lsu_be_done_valid, lsu_be_writeback_pld,
          lsu_be_exception_valid,
          lsu_be_bypass_valid, lsu_be_bypass_pld,
    output rst_n, be_lsu_issue_valid, be_lsu_issue_pld,
           be_lsu_entry_ready, be_lsu_store_wakeup_valid, global_flush_late
  );

  modport lsu (
    input clk, rst_n, be_lsu_issue_valid, be_lsu_issue_pld,
          be_lsu_entry_ready, be_lsu_store_wakeup_valid, global_flush_late,
          lsu_be_issue_ready,
    input lsu_be_done_valid, lsu_be_exception_valid, lsu_be_bypass_valid,
    output lsu_store_buffer_full, lsu_be_done_valid_q,
           lsu_be_exception_valid_q, lsu_be_writeback_pld,
           lsu_be_bypass_valid_q, lsu_be_bypass_pld
  );
endinterface : or_be_lsu_if
