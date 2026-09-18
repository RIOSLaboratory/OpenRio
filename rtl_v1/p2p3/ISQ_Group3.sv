`ifndef ISQ_GROUP3_SV
`define ISQ_GROUP3_SV

/* verilator lint_off IMPORTSTAR */
import or_be_types_pkg::*;
/* verilator lint_on IMPORTSTAR */

// ISQ_Group3 -- the LSU issue queue group, one entry (ISQ_Group3微架构文档).
//
// (1) per-entry state          : FREE / RESIDENT, which *is* the single bit
//                                isq_valid.  One entry, therefore no pointer,
//                                no age matrix and no intra-group select.
// (2) state transition         : FREE->RESIDENT on dispatch; RESIDENT->
//                                RESIDENT on dispatch (same-cycle issue) and
//                                on bypass_capture; RESIDENT->FREE on issue
//                                without a same-cycle dispatch, and on flush.
// (3) condition                : issue = issue_req & FU_ready &
//                                !global_flush_late, with issue_req =
//                                isq_valid & operand_ready and operand_ready
//                                over rs1/rs2 only -- this group has no rs3.
//                                flush outranks everything.
// (4) data path                : dispatch captures the ⑤ subset of
//                                payload_in; each source's issue-side datum is
//                                the entry copy or this cycle's bypass lane,
//                                selected by one FU_input_mux per source.
// (5) data structure           : state   isq_valid
//                                header  rs1/rs2 _ready and _wait_tag
//                                payload rs1/rs2 _data, imm_valid+imm_data,
//                                        is_store, mem_funct3, rd_is_fp,
//                                        self_tag, exe_subop
//
// Three things this module deliberately does NOT do, each of them a ⑤/⑥
// removal rather than an omission:
//
//   * It never inspects is_store / mem_funct3 / rd_is_fp / exe_subop as
//     control.  They are carried, not decoded.
//
//   * It does not assemble be_lsu_issue_pld_t, and it produces neither
//     req_property nor st_br_resolve (⑥ issue: 「就这 9 个字段」).  The former
//     is req_property_from_subop(exe_subop), the latter an SCB alloc-header
//     read addressed by self_tag; both are built in lsu_bridge, which is the
//     "issue wrapper" of ⑤ and the "bridge" of 集成层 §2.3.  This module has
//     no SCB header read port and must not grow one.
//
//   * rs3, fu_group, pc, inst_bits, is_compressed, pred_taken,
//     pred_target_pc and full_decode (the G0/G2 control sideband) are present
//     on payload_in and are dropped here.  集成层 §2.3 forbids them from
//     reaching be_lsu_issue_pld_t.
//
// Handshake obligation (③「握手义务」 / 集成层 §2.3): valid and ready are
// decoupled.  The nine payload wires are driven unconditionally and never
// withdrawn because FU_ready is 0 -- FU_ready is a *function* of the offered
// request class, so the request has to be presented before the far end can
// answer it.  What FU_ready gates is the release of the entry, and that is
// exactly what the issue_valid port reports.
//
// Port naming follows ⑥ verbatim, so there is no ISQ_Group3.portmap.  Note
// the one name ⑥ calls out explicitly: the *port* issue_valid is the **request**
// line -- isq_valid & operand_ready & !global_flush_late, **without FU_ready** --
// while ③'s intermediate quantity of the same name is called issue_req here to
// keep one name to one meaning.  Entry release is issue_fire = issue_valid &
// FU_ready.  valid must not contain ready: 集成层 §2.3 requires valid and the
// payload to stay stable until the handshake succeeds.
module ISQ_Group3 (
    input  logic                    clk,
    input  logic                    rst_n,

    // ------------------------------------------------------------------
    // in-event: dispatch (transaction, single strobe, 1 write port; the ready
    // side is this module's own isq_free_for_dispatch and has already been
    // absorbed upstream, so there is no second handshake here)
    // ------------------------------------------------------------------
    input  logic                    dispatch_valid,
    // The full ISQ_Payload arrives; only the ⑤ subset is captured.
    input  isq_payload_t            payload_in,

    // ------------------------------------------------------------------
    // in-event: bypass_capture (announce, 4 lanes, b in {0..3}).  All four p3
    // lanes are listened to -- bypass is a global broadcast, not a per-group
    // one.  tag and valid are compared and dropped; only data can enter.
    // ------------------------------------------------------------------
    input  logic                    bypass_publish_valid [NUM_LANES],
    input  logic [TAG_W-1:0]        bypass_tag   [NUM_LANES],
    input  logic [XLEN-1:0]         bypass_data  [NUM_LANES],

    // ------------------------------------------------------------------
    // in-event: flush (announce, single-wire pulse, no payload)
    // ------------------------------------------------------------------
    input  logic                    global_flush_late,

    // ------------------------------------------------------------------
    // in: combinational read -- FU_ready.  One wire, and it is *class
    // qualified*: lsu_bridge computes it from this cycle's offered request
    // class (集成层 §2.3), so a full store buffer lowers it for a
    // store/AMO/SC and leaves it high for a load/LR/fence.  It must never be
    // treated as a group-wide "LSU busy" bit, and it must not depend on
    // anything this module drives as a valid.  The group has a single member,
    // so there is no index -- G0_NUM_FU / G1_NUM_FU / G2_NUM_FU have no G3
    // counterpart for that reason.
    // ------------------------------------------------------------------
    input  logic                    FU_ready,

    // ------------------------------------------------------------------
    // out-event: issue.  issue_valid is the **request** line, not the fire line
    // (see the file header).  The nine payload wires below are the whole of this
    // module's issue contribution -- lsu_bridge adds req_property and
    // st_br_resolve and assembles be_lsu_issue_pld_t.  G3 has no separate
    // address/data issue channel.
    // ------------------------------------------------------------------
    output logic                    issue_valid,
    output logic [XLEN-1:0]         rs1_data,
    output logic [XLEN-1:0]         store_data,
    output logic                    imm_valid,
    // Full 64-bit, already completely sign-extended by decode (⑤ writes it
    // `signed 64`).  It must never be re-truncated to 12 bit at this boundary;
    // the receiving be_lsu_issue_pld_t.imm_data field carries the `signed`
    // attribute and takes these 64 bits unchanged.
    output logic [XLEN-1:0]         imm_data,
    // plain-store only: AMO / SC / FENCE all carry 0 here.
    output logic [MEM_FUNCT3_W-1:0] mem_funct3,
    output logic                    rd_is_fp,
    output logic [TAG_W-1:0]        entry_self_tag,
    output logic [EXE_SUBOP_W-1:0]  exe_subop,

    // ------------------------------------------------------------------
    // Static Info: the free projection, including this cycle's issue.
    // ------------------------------------------------------------------
    output logic                    isq_free_for_dispatch,

    // out：**本队列此刻占用中**（2026-08-26 新增）。
    //
    // 它不是 isq_free_for_dispatch 的取反 —— 那一位含同拍 issue
    // （`!isq_valid ∨ issue`），在发射拍是 1，而本位在发射拍仍是 1，
    // 边沿才清。CompletionScoreboard 要的正是**含发射拍**的语义：
    // 它靠这一位区分「store 还在本队列」与「已进 LSU」，
    // 发射拍必须仍算「在本队列」，否则那一拍的授权会两边都落空。
    //
    // 也不是 issue_valid：那一位含 operand_ready，操作数没就绪时是 0，
    // 而 store 在等操作数期间恰恰是 SCB 最需要就地授权它的时候。
    output logic                    isq_occupied
);

    // ------------------------------------------------------------------
    // (5) data structure -- the single entry.
    //
    // state / header / payload are kept as separate registers rather than one
    // struct: ⑤ gives the three roles different write conditions (header is
    // written by dispatch *and* by bypass_capture, payload data by dispatch
    // and by bypass_capture, the wait tags by dispatch only), and a struct
    // would hide that split behind one name.
    // ------------------------------------------------------------------
    logic                    isq_valid_q;

    logic                    rs1_ready_q;
    logic                    rs2_ready_q;
    logic [TAG_W-1:0]        rs1_wait_tag_q;
    logic [TAG_W-1:0]        rs2_wait_tag_q;

    logic [XLEN-1:0]         rs1_data_q;
    logic [XLEN-1:0]         rs2_data_q;
    logic                    imm_valid_q;
    logic [XLEN-1:0]         imm_data_q;
    logic [MEM_FUNCT3_W-1:0] mem_funct3_q;
    logic                    rd_is_fp_q;
    logic [TAG_W-1:0]        self_tag_q;
    logic [EXE_SUBOP_W-1:0]  exe_subop_q;

    // ------------------------------------------------------------------
    // (3) fast_ready_rsX
    //
    //     fast_ready_rsX = !rsX_ready & OR over b in {0..3}
    //                      (bypass_publish_valid[b] & rsX_wait_tag == bypass_tag[b])
    //
    // This is the criterion, not the data select.  The data select lives in
    // FU_input_mux below; the two agree because they compare the same tags,
    // and 集成层 §2.5(3) fixes the lowest-numbered lane as the winner if a
    // tag were ever to hit on more than one lane.
    //
    // No isq_valid term here on purpose: every consumer of fast_ready_rsX
    // (issue_req, bypass_capture) already carries one.
    // ------------------------------------------------------------------
    logic rs1_bypass_hit;
    logic rs2_bypass_hit;

    always_comb begin
        rs1_bypass_hit = 1'b0;
        rs2_bypass_hit = 1'b0;
        for (int b = 0; b < NUM_LANES; b++) begin
            if (bypass_publish_valid[b] && (bypass_tag[b] == rs1_wait_tag_q)) begin
                rs1_bypass_hit = 1'b1;
            end
            if (bypass_publish_valid[b] && (bypass_tag[b] == rs2_wait_tag_q)) begin
                rs2_bypass_hit = 1'b1;
            end
        end
    end

    logic fast_ready_rs1;
    logic fast_ready_rs2;
    logic operand_ready;

    assign fast_ready_rs1 = !rs1_ready_q && rs1_bypass_hit;
    assign fast_ready_rs2 = !rs2_ready_q && rs2_bypass_hit;

    // rs3 is not part of the AND: this group has no three-source instruction.
    // rs1 is the base address, rs2 the store data.  LR does not use rs2 and
    // arrives with rs2_ready = 1 from upstream (use_rs2 = 0), so no special
    // case is needed here either.
    assign operand_ready = (rs1_ready_q || fast_ready_rs1) &&
                           (rs2_ready_q || fast_ready_rs2);

    // ------------------------------------------------------------------
    // (4)#1 the issue-side source data.
    //
    //   rsX_ready              -> the entry copy
    //   !rsX_ready & hit       -> this cycle's bypass lane, forwarded *past*
    //                             the entry (④: 「绕过 entry 直接前递」)
    //
    // One FU_input_mux per source; the same output is also what a
    // bypass_capture writes back into the entry, so the selection exists
    // exactly once in this module.
    // ------------------------------------------------------------------
    logic [XLEN-1:0] fu_rs1_data;
    logic [XLEN-1:0] fu_rs2_data;

    FU_input_mux u_fu_input_mux_rs1 (
        .entry_rsX_data (rs1_data_q),
        .bypass_data    (bypass_data),
        .bypass_publish_valid   (bypass_publish_valid),
        .bypass_tag     (bypass_tag),
        .rsX_wait_tag   (rs1_wait_tag_q),
        .rsX_ready      (rs1_ready_q),
        .fu_rsX_data    (fu_rs1_data)
    );

    FU_input_mux u_fu_input_mux_rs2 (
        .entry_rsX_data (rs2_data_q),
        .bypass_data    (bypass_data),
        .bypass_publish_valid   (bypass_publish_valid),
        .bypass_tag     (bypass_tag),
        .rsX_wait_tag   (rs2_wait_tag_q),
        .rsX_ready      (rs2_ready_q),
        .fu_rsX_data    (fu_rs2_data)
    );

    // ------------------------------------------------------------------
    // (3) issue / bypass_capture / flush, and the free projection.
    //
    // issue_req is ③'s intermediate quantity `isq_valid ∧ operand_ready`,
    // renamed per ⑥ so that the *port* issue_valid can carry ③'s `issue`
    // without one name meaning two things.
    //
    // Only the release decision looks at FU_ready.  The nine payload wires
    // below do not, which is the valid/ready decoupling ③ demands: FU_ready
    // is a function of the offered request class, and that class is derivable
    // only because exe_subop is presented unconditionally.
    // ------------------------------------------------------------------
    logic issue_req;
    logic bypass_capture;

    assign issue_req   = isq_valid_q && operand_ready;
    // ⑥ §issue：`issue_valid` 是**请求线不是 fire 线**——不含 FU_ready。
    // valid 含 ready 即耦合：ready 一掉 valid 就掉，「valid 一经拉高保持稳定
    // 到握手成功」当场被破坏，且 FU_ready 也不得反过来依赖 valid（成环）。
    // entry 的释放是 issue_fire = issue_valid ∧ FU_ready，即 ③ 的 `issue`。
    logic issue_fire;
    assign issue_valid = issue_req && !global_flush_late;
    assign issue_fire  = issue_valid && FU_ready;

    // Same-cycle issue does not capture: the entry is leaving, and the
    // forwarded value has already reached the far end through FU_input_mux.
    assign bypass_capture = isq_valid_q && !global_flush_late && !issue_fire &&
                            (fast_ready_rs1 || fast_ready_rs2);

    // ⑥/③ verbatim.  Note there is no flush term: on a flush cycle a resident
    // entry still reads "not free", which is the conservative answer -- the
    // same cycle refuses dispatch anyway.
    assign isq_free_for_dispatch = !isq_valid_q || issue_fire;
    // 含发射拍：isq_valid_q 在 issue_fire 的**边沿**才清，本拍仍为 1。
    assign isq_occupied          = isq_valid_q;

    // ------------------------------------------------------------------
    // (2) the state machine, one entry.
    //
    // Priority, top down, is ③'s: flush > dispatch > (issue | capture).
    //   flush     : isq_valid <- 0, nothing else happens this cycle.
    //   dispatch  : captures payload_in; isq_valid <- 1 whether the entry was
    //               FREE or is issuing this same cycle.
    //   issue     : isq_valid <- 0 -- reached only when there is no dispatch,
    //               which is exactly ②'s "RESIDENT -> FREE：issue（本拍无
    //               dispatch 时）".
    //   capture   : sets the hit source's ready bit and refreshes its data.
    //               The wait tag is deliberately left alone; overwriting it
    //               would make the next cycle re-match against a new tag.
    //
    // issue_valid and bypass_capture are mutually exclusive by construction,
    // so the order of the two clauses below is not a third choice.
    // ------------------------------------------------------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            isq_valid_q    <= 1'b0;
            rs1_ready_q    <= 1'b0;
            rs2_ready_q    <= 1'b0;
            rs1_wait_tag_q <= '0;
            rs2_wait_tag_q <= '0;
            rs1_data_q     <= '0;
            rs2_data_q     <= '0;
            imm_valid_q    <= 1'b0;
            imm_data_q     <= '0;
            mem_funct3_q   <= '0;
            rd_is_fp_q     <= 1'b0;
            self_tag_q     <= '0;
            exe_subop_q    <= '0;
        end else if (global_flush_late) begin
            isq_valid_q    <= 1'b0;
        end else if (dispatch_valid) begin
            isq_valid_q    <= 1'b1;
            rs1_ready_q    <= payload_in.rs1_ready;
            rs2_ready_q    <= payload_in.rs2_ready;
            rs1_wait_tag_q <= payload_in.rs1_wait_tag;
            rs2_wait_tag_q <= payload_in.rs2_wait_tag;
            rs1_data_q     <= payload_in.rs1_data;
            rs2_data_q     <= payload_in.rs2_data;
            imm_valid_q    <= payload_in.imm_valid;
            imm_data_q     <= payload_in.imm_data;
            mem_funct3_q   <= payload_in.mem_funct3;
            rd_is_fp_q     <= payload_in.rd_is_fp;
            self_tag_q     <= payload_in.self_tag;
            exe_subop_q    <= payload_in.exe_subop;
        end else begin
            if (issue_fire) begin
                isq_valid_q <= 1'b0;
            end
            if (bypass_capture) begin
                if (fast_ready_rs1) begin
                    rs1_ready_q <= 1'b1;
                    rs1_data_q  <= fu_rs1_data;
                end
                if (fast_ready_rs2) begin
                    rs2_ready_q <= 1'b1;
                    rs2_data_q  <= fu_rs2_data;
                end
            end
        end
    end

    // ------------------------------------------------------------------
    // (4)#1 the nine issue payload wires.
    //
    // Driven unconditionally -- ③: 「payload 必须无条件驱动给对端：FU_ready
    // 是它的函数，不先呈现就求不出来」.  exe_subop in particular has to stand
    // on the port before lsu_bridge can run req_property_from_subop on it
    // and answer with FU_ready, so gating any of these on issue_valid would
    // close a loop that ③ opens on purpose.
    //
    // is_store stays the stored plain-store bit and is not re-derived from
    // exe_subop: ⑤ makes upstream own the equality with req_property.is_store,
    // and re-deriving it here would silently paper over an upstream
    // disagreement instead of letting it show.
    // ------------------------------------------------------------------
    assign rs1_data   = fu_rs1_data;
    assign store_data = fu_rs2_data;
    assign imm_valid  = imm_valid_q;
    assign imm_data   = imm_data_q;
    assign mem_funct3 = mem_funct3_q;
    assign rd_is_fp   = rd_is_fp_q;
    assign entry_self_tag = self_tag_q;
    assign exe_subop  = exe_subop_q;

endmodule

`endif // ISQ_GROUP3_SV
