`ifndef LSU_BRIDGE_SV
`define LSU_BRIDGE_SV

/* verilator lint_off IMPORTSTAR */
import or_be_lsu_protocol_pkg::*;
import or_be_types_pkg::*;
/* verilator lint_on IMPORTSTAR */

// lsu_bridge -- backend_top 的私有块（backend_top/lsu_bridge.md）。
//
// **它不是 LSU，也不是 LSU 的接口契约。** 对端 LSU 的契约写在
// modules/lsu/g3_lsu_iface.md，那份文档描述的是边界另一侧。本模块是 BE 这一
// 侧的桥：把 ISQ_Group3 / CompletionScoreboard 的发射与授权送出边界，把 LSU
// 的回送整理成 lane 3 的 writeback 与 bypass，并持有边界上不可见的四组状态
// （在飞跟踪、唤醒挂起、读写侧完成、bypass 数据暂存）。
//
// the boundary bridge between ISQ_Group3 / CompletionScoreboard
// and the LSU proper (lsu微架构文档; the module name is the one 集成层 §2.3 and
// ISQ_Group3微架构文档 ⑥ use, the document is filed under `lsu`).
//
// It does exactly the four things ①..⑥ list and nothing else:
//
//   1 assemble   ISQ_Group3 的发射字段原样装配（不分类、不算地址）+
//                the SCB alloc-header st_br_resolve  ->  be_lsu_issue_pld_t
//   2 fold       the LSU's class-qualified acceptance into one FU_ready (③#1)
//   3 relay      the SCB's tagged store_wakeup as the LSU's untagged pulse (③#2)
//   4 merge      the LSU's done / exception into ONE lane-3 completion_common
//                plus the lane-3 CDB broadcast (③#3, ④#3, ④#4)
//
// It is not a second retirement authority: no flush, no cause decision, no
// architectural state, no second copy of the SCB's bits (⑤「本模块不存」).
//
// The LSU-facing names are the wire-level truth in dv/mock_tb/lsu_if.sv, per
// ⑥.  Two of them are pass-throughs that ⑥ lists on the out-event side --
// `global_flush_late` and `rst_n`.  A module cannot have an input and an output
// of the same name, and ⑥ freezes the name, so they stay single input ports
// here and the top level fans the same net out to lsu_if (that is what ⑥'s
// 「直通」 means).  Likewise the SCB header read address is ⑥'s own
// `entry_self_tag`, i.e. the issue tag: the top level drives
// CompletionScoreboard.st_br_resolve_tag from the same ISQ_Group3 output, and
// only the selected bit comes back on `st_br_resolve`.
module lsu_bridge (
    input  logic                        clk,
    input  logic                        rst_n,

    // ------------------------------------------------------------------
    // in-event: issue (transaction, single strobe, 1 read port).  ⑥'s nine
    // payload fields plus the trigger.  ISQ_Group3 drives the nine
    // unconditionally and holds valid+payload stable until the handshake
    // succeeds; `issue_valid` is its REQUEST line and does not contain
    // FU_ready (ISQ_Group3微架构文档 ⑥, and lsu微架构文档 ⑥「请求线不含
    // FU_ready」), so the transfer is issue_valid ∧ FU_ready.
    // ------------------------------------------------------------------
    input  logic                        issue_valid,
    input  logic [TAG_W-1:0]            entry_self_tag,
    input  logic [EXE_SUBOP_W-1:0]      exe_subop,
    input  logic [MEM_FUNCT3_W-1:0]     mem_funct3,
    input  logic                        rd_is_fp,
    input  logic [XLEN-1:0]             rs1_data,
    input  logic [XLEN-1:0]             store_data,
    input  logic                        imm_valid,
    // ⑥ writes this `signed 64`: decode already sign-extended it and ④#1
    // forbids re-truncating it here.  The producing port on ISQ_Group3 is
    // declared unsigned by its own ⑥; 集成层 §2.5(5b) allows the two ends of
    // one net to differ, the 64 bits are carried unchanged either way.
    input  logic signed [XLEN-1:0]      imm_data,

    // ------------------------------------------------------------------
    // in: combinational read -- the SCB alloc header addressed by the issue's
    // entry_self_tag (⑥ 组合读).  It is the alloc-cycle frozen snapshot; ④#1 forbids
    // overwriting it with the current store_wakeup_issued, which is why this
    // is a plain read of somebody else's header and not local state.
    // ------------------------------------------------------------------
    input  logic                        st_br_resolve,

    // ------------------------------------------------------------------
    // in-event: store_wakeup (announce, 1-cycle pulse, no ready back).  May
    // arrive while the tag is still resident in ISQ_Group3 (⑥).
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
    // the LSU side (⑥: lsu_be_issue_ready = rst_n ∧ !(store_side ∧
    // store_buffer_full)).  This module consumes that one wire only --
    // lsu_store_buffer_full deliberately has no port here -- and must never
    // make it depend on be_lsu_issue_valid.
    //
    // The three result valids arrive ALREADY qualified with !global_flush_late
    // by lsu_if.sv (⑥ 另注).
    // ------------------------------------------------------------------
    input  logic                        lsu_be_issue_ready,
    input  logic                        lsu_be_writeback_valid,
    input  lsu_be_writeback_pld_t       lsu_be_writeback_pld,
    input  logic                        lsu_be_bypass_valid,
    // 独立类型的复制线，必须与 writeback 的 done_valid 同拍；本模块用这条
    // 通道的 VALID 作为读侧限定，数据取自 writeback 的 data。
    input  lsu_be_bypass_pld_t          lsu_be_bypass_pld,

    // ------------------------------------------------------------------
    // out: FU_ready -> ISQ_Group3 (broadcast combinational level, ③#1)
    // ------------------------------------------------------------------
    output logic                        FU_ready,

    // ------------------------------------------------------------------
    // out-event: completion -> lane 3 (completion_common shape, ④#3).
    // mispredict_flag / is_mret / fpu_fflags are constant zero and are driven
    // HERE: lane 3 has no arbiter to fill them in (集成层 §1.2「恒零字段由 FU
    // 驱动、仲裁器不补造」).  mispredict_target_pc is the same kind of constant
    // zero -- ⑥ does not list it, but completion_common carries it and the
    // SCB's lane-3 input needs a driver, so it follows the same rule.
    // ------------------------------------------------------------------
    output logic                        writeback_valid,
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
    // out-event: bypass -> lane 3 of the 4-lane CDB (④#4).  Same cycle as the
    // completion, no ready, never repeated.
    // ------------------------------------------------------------------
    output logic                        bypass_publish_valid,
    output logic [TAG_W-1:0]            bypass_tag,
    output logic [XLEN-1:0]             bypass_data,

    // ------------------------------------------------------------------
    // out: LSU side (out of library)
    // ------------------------------------------------------------------
    output logic                        be_lsu_issue_valid,
    output be_lsu_issue_pld_t           be_lsu_issue_pld,
    output logic                        be_lsu_store_wakeup_valid,
    output logic [TAG_W-1:0]            be_lsu_store_wakeup_tag
);

    // ------------------------------------------------------------------
    // (5) data structure.
    //
    //   state    wakeup_held / read_done / store_done   per tag, 16 (LSU_TAG_W)
    //            wakeup_pending_any                     one global reduction
    //   payload  held_data(64)                          per tag
    //   header   none -- the request fields are combinational pass-through
    //
    // req_in_flight is the one bit ⑤ does not list and this implementation
    // cannot do without: ② conditions the wakeup_held set on「该 tag 尚未
    // issue」and ③#1's bridge_has_room on「某 tag 的 held_data 槽…无处安放」,
    // and neither predicate is answerable from the boundary alone.  It is set
    // by this module's own issue handshake and cleared by that tag's terminal,
    // so it holds exactly「this tag's request is at the LSU right now」.  It is
    // not a copy of an SCB or LSU state bit and it is not a request field.
    //
    // Without it a post-issue wakeup -- the normal case, the SCB wakes a store
    // that has long since been issued -- would be mislabelled as a held
    // pre-issue authorization, latch wakeup_pending_any and block every later
    // wakeup for good.  dv/mock_tb/lsu_if.sv documents the same mislabelling
    // as the reason its p_at_most_one_early_store_wakeup had to be disabled.
    // ------------------------------------------------------------------
    logic [ROB_DEPTH-1:0] wakeup_held_q;
    logic [ROB_DEPTH-1:0] read_done_q;
    logic [ROB_DEPTH-1:0] store_done_q;
    logic [ROB_DEPTH-1:0] req_in_flight_q;
    logic [XLEN-1:0]      held_data_q [ROB_DEPTH];

    logic                 wakeup_pending_any;
    assign wakeup_pending_any = |wakeup_held_q;

    // ------------------------------------------------------------------
    // ④#1 request assembly.  Combinational, nothing latched: ISQ_Group3 holds
    // the entry stable until the handshake, which is what lets ⑤ say「header:
    // 无」.
    //
    // payload 只搬原料，不含任何 BE 侧判断：
    //
    //   请求分类      不在此计算。LSU 自己对 exe_subop 调用
    //                 req_property_from_subop()。
    //   地址          不在此计算。AGU 在 LSU 内，本模块只交出 base 与已符号
    //                 扩展的 offset（rs1_data / imm_valid / imm_data）。
    //   st_br_resolve SCB 的同拍快照，原样送入；是否与本次请求相关由 LSU 判断。
    // ------------------------------------------------------------------

    always_comb begin
        be_lsu_issue_pld               = '0;
        be_lsu_issue_pld.tag           = entry_self_tag;
        be_lsu_issue_pld.exe_subop     = exe_subop;
        be_lsu_issue_pld.mem_funct3    = mem_funct3;
        be_lsu_issue_pld.rd_is_fp      = rd_is_fp;
        be_lsu_issue_pld.rs1_data      = rs1_data;
        be_lsu_issue_pld.store_data    = store_data;
        be_lsu_issue_pld.imm_valid     = imm_valid;
        be_lsu_issue_pld.imm_data      = imm_data;
        // 原样送入：本次请求是不是 store 由 LSU 自己判定，BE 不做分类，
        // 因此也不做按类别的屏蔽。
        be_lsu_issue_pld.st_br_resolve = st_br_resolve;
    end

    // ------------------------------------------------------------------
    // ③#1 issue handshake.  valid and ready are decoupled in both directions:
    //
    //   - the payload above is driven unconditionally, because
    //     lsu_be_issue_ready 是 LSU 对 exe_subop 自行分类后的函数，cannot be
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
    // in a correct machine, and it is the doc's criterion rather than a
    // hard-wired 1.
    //
    // be_lsu_issue_valid carries the same gate so the two ends see ONE
    // handshake: ISQ_Group3 releases on issue_valid ∧ FU_ready, the LSU accepts
    // on be_lsu_issue_valid ∧ lsu_be_issue_ready, and the two expressions are
    // identical (ISQ_Group3's issue_valid already excludes the flush cycle).
    // ------------------------------------------------------------------
    logic bridge_has_room;
    logic issue_accept;

    assign bridge_has_room    = !req_in_flight_q[entry_self_tag];
    assign FU_ready           = bridge_has_room && lsu_be_issue_ready;
    assign be_lsu_issue_valid = issue_valid && bridge_has_room &&
                                !global_flush_late;
    assign issue_accept       = be_lsu_issue_valid && lsu_be_issue_ready;

    // ③#4 / ⑥: constant 1 except under reset and on the flush cycle.  It is an
    // acknowledge for the LSU's registered result channels, never backpressure.

    // ------------------------------------------------------------------
    // ③#2 store_wakeup: tagged -> untagged.
    //
    // The pulse is relayed the cycle it arrives.  wakeup_held[tag] records an
    // authorization the LSU is holding for a store that has not reached it yet;
    // while any such authorization is outstanding a second one must not be
    // relayed, because two untagged authorizations at the LSU cannot be told
    // apart.  ③#2 calls this a double check on top of the SCB's own
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
                                      (entry_self_tag == store_wakeup_tag);

    // **LSU 边界上的 wakeup 是无 tag 的**：LSU 只能把它套到自己最老的未授权
    // store 上。所以只有目标那条 store **已经（或同拍）发射到 LSU** 时才能
    // 转投；否则 LSU 无处可套，cache_agent 会报 unmatched store wakeup。
    assign wakeup_target_present = req_in_flight_q[store_wakeup_tag]
                                || wakeup_consumed_at_issue;
    assign wakeup_relay_now      = wakeup_accept && wakeup_target_present;

    // 之前留存的授权，在它那条 store 真正发射的那一拍补投。
    // 缺这一条就是：留存位被 issue_accept 清掉、授权却从未送到 LSU，
    // 那条 store 永远等不到授权。
    assign wakeup_relay_held     = issue_accept && wakeup_held_q[entry_self_tag];

    assign wakeup_hold_set       = wakeup_accept && !wakeup_target_present;

    assign be_lsu_store_wakeup_valid = wakeup_relay_now || wakeup_relay_held;
    // 就地转发用 SCB 给的 tag；挂起后在发射拍补发的那条，目标就是本拍
    // 发射的 entry。
    assign be_lsu_store_wakeup_tag   = wakeup_relay_held ? entry_self_tag
                                                        : store_wakeup_tag;

`ifndef SYNTHESIS
    // ------------------------------------------------------------------
    // 2026-08-26：**发射前唤醒不该再发生。**
    //
    // CompletionScoreboard 现在按 store 的位置分投授权：还在 ISQ_Group3 里
    // 就地把 entry_st_br_resolve 置 1（桥在发射拍组合读到），已进 LSU 才发
    // 脉冲。两条路径互斥，所以脉冲的目标必然已经在飞。
    //
    // **wakeup_held_q 保留，不删。** 证据是这样取的：
    //
    //   124 例回归            改造前后断言都不响 —— 这套用例根本产生不了
    //                         发射前唤醒，沉默证明不了任何事
    //   or-p-store_resolve    改造后：就地解析触发，断言不响
    //   _in_isq（定向）        改造前：**断言响，tag 2** —— 它确实承重过
    //
    // 所以这套机制不是死代码，只是被新路径绕开了。留着的理由：
    // 断言只在仿真里存在，综合后编译掉。万一将来真出现发射前唤醒，
    // 有它兜底只是多绕一拍；没它则授权静默丢失、那条 store 永远挂住。
    // **死代码的代价远小于静默挂死。**
    // ------------------------------------------------------------------
    // 复位敏感列表跟全设计一致（异步）。写成 @(posedge clk) 再同步读 rst_n
    // 会触发 SYNCASYNCNET —— 同一根 rst_n 一边异步一边同步。
    // 用 always 而非 always_ff：本块不含非阻塞赋值。
    always @(posedge clk or negedge rst_n) begin
        if (rst_n && wakeup_hold_set) begin
            $error("[lsu_bridge] pre-issue store wakeup for tag %0d: SCB pulsed a tag that is neither in flight nor issuing this cycle. After the 2026-08-26 SCB change this should be unreachable.",
                   store_wakeup_tag);
            $stop;
        end
    end
`endif

    // ------------------------------------------------------------------
    // ③#3 terminal merge.
    //
    // The done channel carries {tag, data} only and ⑤ forbids keeping a per-tag
    // copy of the request, so the class information available at terminal time
    // is exactly what the LSU rides with the done: lsu_be_bypass_valid is
    // raised with, and only with, a done that carries a read-side result
    // (lsu_if.sv p_bypass_rides_normal_completion).  That is ④'s `read_side`
    // at this boundary.
    //
    // The frozen LSU reports one done per request and only once every side it
    // has has landed, so ②'s two bits are set together by that done and every
    // row of ③#3's table -- read-only, store-only, read ∧ store (AMO/SC), and
    // the misc fence row -- becomes true on that same cycle.  read_done takes
    // the read-side qualifier; store_done takes the done itself, meaning「the
    // write side, if any, has landed」.
    //
    // done and exception are mutually exclusive on the wire (lsu_if.sv
    // p_terminal_channels_mutually_exclusive) and both are already qualified
    // with !global_flush_late there; ③#4 additionally requires this module to
    // send no lane-3 completion on a flush cycle, so the qualification is
    // repeated here instead of being borrowed.
    // ------------------------------------------------------------------
    logic             done_in;
    logic             exc_in;
    logic             read_side_result;
    logic [TAG_W-1:0] wb_tag;
    logic             terminal_in;
    logic [TAG_W-1:0] terminal_tag;

    // 一次访存只回一条 writeback；done 与 exception 是 payload 内互斥的两个
    // 子 valid，tag 两种情况下都有效，所以终态 tag 只有一个来源。
    assign wb_tag           = lsu_be_writeback_pld.tag;
    assign done_in          = lsu_be_writeback_valid &&
                              lsu_be_writeback_pld.done_valid      && !global_flush_late;
    assign exc_in           = lsu_be_writeback_valid &&
                              lsu_be_writeback_pld.exception_valid && !global_flush_late;
    assign read_side_result = lsu_be_bypass_valid                  && !global_flush_late;
    assign terminal_in      = done_in || exc_in;
    assign terminal_tag     = wb_tag;

    // ②'s next-state bits for the tag this done names, i.e. the values ③#3's
    // table is evaluated on.
    logic read_done_next;
    logic store_done_next;
    logic req_sides_complete;

    assign read_done_next     = read_done_q[wb_tag]  ||
                                (done_in && read_side_result);
    assign store_done_next    = store_done_q[wb_tag] || done_in;
    assign req_sides_complete = read_done_next || store_done_next;

    // ④#3 result_data ← read_side ? held_data : 0.  held_data[tag] is written
    // by this same done (①「读侧结果暂存」), so the read is the write-through of
    // that write; the stored path is what carries the result if a read side
    // ever returns ahead of its write side.
    logic [XLEN-1:0] held_data_rd;
    assign held_data_rd = (done_in && read_side_result) ? lsu_be_writeback_pld.data
                                                        : held_data_q[wb_tag];

    // ------------------------------------------------------------------
    // ④#3 lane-3 completion_common.
    // ------------------------------------------------------------------
    assign writeback_valid         = (done_in && req_sides_complete) || exc_in;
    assign tag_out              = terminal_tag;
    assign result_data          = read_side_result ? held_data_rd : {XLEN{1'b0}};
    assign exception_flag       = exc_in;
    assign exception_cause      = exc_in ?
        lsu_be_writeback_pld.exception_cause :
        {EXCP_CAUSE_W{1'b0}};
    assign exception_tval       = exc_in ? lsu_be_writeback_pld.exception_tval
                                         : {XLEN{1'b0}};
    assign mispredict_flag      = 1'b0;
    assign mispredict_target_pc = {XLEN{1'b0}};
    assign is_mret              = 1'b0;
    assign is_sret              = 1'b0;   // §4.1 G3 zero
    assign fpu_fflags           = {FFLAGS_W{1'b0}};

    // ------------------------------------------------------------------
    // ④#4 lane-3 CDB broadcast.  Same cycle as the completion, never on an
    // exception, never repeated.
    // ------------------------------------------------------------------
    assign bypass_publish_valid = writeback_valid && read_side_result && !exception_flag;
    assign bypass_tag   = wb_tag;
    assign bypass_data  = held_data_rd;

    // ------------------------------------------------------------------
    // ② state transitions.  ③#4: a flush clears every per-tag bit and
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
            // wakeup_held: set by a relayed pre-issue authorization, cleared
            // when that tag's request reaches the LSU (the authorization is
            // consumed there).  The issue clear is written second so a
            // same-cycle set and clear resolves to「consumed」.
            if (wakeup_hold_set) begin
                wakeup_held_q[store_wakeup_tag] <= 1'b1;
            end
            if (issue_accept) begin
                wakeup_held_q[entry_self_tag] <= 1'b0;
            end

            // read_done / store_done / held_data: written by lsu_done_in.
            if (done_in) begin
                store_done_q[wb_tag] <= 1'b1;
                if (read_side_result) begin
                    read_done_q[wb_tag] <= 1'b1;
                    held_data_q[wb_tag] <= lsu_be_writeback_pld.data;
                end
            end

            // req_in_flight: the「尚未 issue」/「slot in use」predicate.  The
            // terminal clear is written first so that an (impossible) same-tag
            // coincidence resolves to「in flight」rather than losing the issue.
            if (terminal_in) begin
                req_in_flight_q[terminal_tag] <= 1'b0;
            end
            if (issue_accept) begin
                req_in_flight_q[entry_self_tag] <= 1'b1;
            end
        end
    end

endmodule

`endif // LSU_BRIDGE_SV
