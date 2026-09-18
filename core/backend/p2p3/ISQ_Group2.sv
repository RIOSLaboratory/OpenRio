`ifndef ISQ_GROUP2_SV
`define ISQ_GROUP2_SV

/* verilator lint_off IMPORTSTAR */
import or_be_types_pkg::*;
/* verilator lint_on IMPORTSTAR */

// ISQ_Group2 -- FPU group, single entry (ISQ_Group2微架构文档).
//
// (1) per-entry state          : FREE / RESIDENT, carried by isq_valid alone;
//                                one entry, no pointers
// (2) state transition         : FREE->RESIDENT dispatch; RESIDENT->RESIDENT
//                                dispatch (same-cycle issue) / bypass_capture;
//                                RESIDENT->FREE issue (no dispatch this cycle)
//                                / flush
// (3) condition                : issue = isq_valid & operand_ready & FU_ready
//                                & !global_flush_late; operand_ready needs all
//                                THREE sources; flush has the top priority
// (4) data path                : dispatch captures payload_in, bypass writes
//                                the hit source's data, issue reads the entry
//                                with a same-cycle bypass forward around it
// (5) data structure           : state isq_valid; header rsX_ready /
//                                rsX_wait_tag; payload rsX_data, self_tag,
//                                exe_subop(24), full_decode(17)
//
// The only group that uses rs3 (FMA needs three sources) and the only group
// that consumes full_decode.rm.  The rm it captures is already the dispatch-
// cycle effective_rm (⑤): the assembly overwrote those three bits, reserved
// values never reach here (dispatch_logic diverted them to G0), and the FPU
// must NOT re-read the live frm -- an entry can sit here for many cycles while
// frm changes underneath it.
//
// FP .S/.D precision is distinguished by the fixed high field of exe_subop, so
// no extra precision bit is stored.
//
// The fields payload_in carries but this group does NOT keep (⑤): FU_Group
// (single member, constant 0), pc / inst_bits / is_compressed / pred_taken /
// pred_target_pc (BRU only), is_store / mem_funct3 / rd_is_fp (LSU only) and
// imm_valid / imm_data (FP arithmetic has no immediate).
module ISQ_Group2 (
    input  logic                        clk,
    input  logic                        rst_n,

    // in-event: dispatch (Transaction, one write port; the upstream absorbed
    // ready = isq_free_for_dispatch, so dispatch_valid never arrives while occupied)
    // payload_in is the complete ISQ_Payload; only the ⑤ fields are captured
    input  isq_payload_t                payload_in,
    input  logic                        dispatch_valid,

    // in-event: bypass_capture (announce, 4 lanes -- bypass is a global
    // broadcast and all four lanes are watched)
    input  logic                        bypass_publish_valid [NUM_LANES],
    input  logic [TAG_W-1:0]            bypass_tag   [NUM_LANES],
    input  logic [XLEN-1:0]             bypass_data  [NUM_LANES],

    // in-event: flush (announce, single-wire pulse, no payload)
    input  logic                        global_flush_late,

    // in-event: combinational read -- the group has a single FU, so FU_ready
    // carries no index; it feeds the issue criterion and is not stored
    input  logic                        FU_ready,

    // out-event: issue -> the out-of-library FPU.  issue_valid is the ③ issue
    // predicate itself (isq_valid & operand_ready & FU_ready &
    // !global_flush_late), per ⑥ "issue 的判据（含 FU_ready 与
    // !global_flush_late）"; the FU latches the payload on it (集成层 §1.5).
    output logic                        issue_valid,
    output logic [XLEN-1:0]             rs1_data,
    output logic [XLEN-1:0]             rs2_data,
    output logic [XLEN-1:0]             rs3_data,
    output logic [TAG_W-1:0]            self_tag,
    output logic [EXE_SUBOP_W-1:0]      exe_subop,
    output logic [FULL_DECODE_W-1:0]    full_decode,

    // Static Info: the free projection, including this cycle's issue
    output logic                        isq_free_for_dispatch
);

    // ------------------------------------------------------------------
    // (5) entry storage
    //
    // The three sources are held as 1-based arrays: 集成层 §2.5(1) freezes the
    // source number as the index itself with base 1 -- there is no rs0.  The
    // ⑥ ports stay three separately named scalars, the array is internal only.
    //
    // entry_full_decode keeps the frozen 集成层 §2.2 packing
    //   [16] csr_write_intent  [15] illegal  [14:12] rm  [11:0] csr_addr
    // verbatim; the FPU takes rm and ignores illegal / csr_addr (⑤).
    // ------------------------------------------------------------------
    logic                       entry_valid;                            // ⑤ state: isq_valid
    logic                       entry_rs_ready    [1:FP_READ_PORTS];    // ⑤ header
    logic [TAG_W-1:0]           entry_rs_wait_tag [1:FP_READ_PORTS];    // ⑤ header
    logic [XLEN-1:0]            entry_rs_data     [1:FP_READ_PORTS];    // ⑤ payload
    logic [TAG_W-1:0]           entry_self_tag;                         // ⑤ payload, never inspected here
    logic [EXE_SUBOP_W-1:0]     entry_exe_subop;                        // ⑤ payload, issued verbatim
    logic [FULL_DECODE_W-1:0]   entry_full_decode;                      // ⑤ payload, rm already effective_rm

    // ------------------------------------------------------------------
    // (3) bypass match, one comparison per source against all four lanes
    //
    //   fast_ready_rsX = !rsX_ready & OR over b (bypass_publish_valid[b]
    //                                            & rsX_wait_tag == bypass_tag[b])
    //
    // Only the OR is needed here: which lane supplies the data is decided by
    // FU_input_mux, and 集成层 §2.5(3) freezes that tie-break (lowest numbered
    // lane) for the multi-lane same-tag case.  Normally a tag appears on one
    // lane only.
    // ------------------------------------------------------------------
    logic                       bypass_hit [1:FP_READ_PORTS];
    logic                       fast_ready [1:FP_READ_PORTS];
    logic                       src_ready  [1:FP_READ_PORTS];
    logic                       operand_ready;
    logic                       any_fast_ready;
    logic                       issue_req;
    logic                       bypass_capture;

    // Only the compare lives here -- the data select belongs to FU_input_mux
    // below.  This side has to evaluate it anyway to raise issue_valid.
    always_comb begin
        for (int unsigned x = 1; x <= FP_READ_PORTS; x++) begin
            bypass_hit[x] = 1'b0;
            for (int unsigned b = 0; b < NUM_LANES; b++) begin
                if (bypass_publish_valid[b] && (bypass_tag[b] == entry_rs_wait_tag[x])) begin
                    bypass_hit[x] = 1'b1;
                end
            end
            fast_ready[x] = !entry_rs_ready[x] && bypass_hit[x];
            src_ready[x]  = entry_rs_ready[x] || fast_ready[x];
        end
    end

    // ------------------------------------------------------------------
    // (3) issue / bypass_capture / the free projection
    //
    //   operand_ready = (rs1_ready | fast_ready_rs1)
    //                 & (rs2_ready | fast_ready_rs2)
    //                 & (rs3_ready | fast_ready_rs3)     -- all three sources
    //   issue_req     = isq_valid & operand_ready        -- ③ issue_valid
    //   issue         = issue_req & FU_ready & !global_flush_late
    //
    // bypass_capture does not fire in an issue cycle: the value is forwarded
    // straight to the FPU instead of being written back into a leaving entry.
    // ------------------------------------------------------------------
    always_comb begin
        operand_ready  = 1'b1;
        any_fast_ready = 1'b0;
        for (int unsigned x = 1; x <= FP_READ_PORTS; x++) begin
            operand_ready  = operand_ready && src_ready[x];
            any_fast_ready = any_fast_ready || fast_ready[x];
        end
    end

    assign issue_req      = entry_valid && operand_ready;
    // ⑥ §issue：`issue_valid` 是**请求线不是 fire 线**——不含 FU_ready。
    // valid 含 ready 即耦合：ready 一掉 valid 就掉，「valid 一经拉高保持稳定
    // 到握手成功」当场被破坏，且 FU_ready 也不得反过来依赖 valid（成环）。
    // entry 的释放是 issue_fire = issue_valid ∧ FU_ready，即 ③ 的 `issue`。
    logic issue_fire;
    assign issue_valid    = issue_req && !global_flush_late;
    assign issue_fire     = issue_valid && FU_ready;

    assign bypass_capture = entry_valid && !global_flush_late &&
                            !issue_fire && any_fast_ready;

    // isq_free_for_dispatch = !isq_valid | issue -- the same-cycle issue is
    // included on purpose, that is what lets dispatch refill an issuing entry.
    assign isq_free_for_dispatch = !entry_valid || issue_fire;

    // ------------------------------------------------------------------
    // (4)#1 entry -> issue output ports
    //
    //   entry -> issue        every payload field other than source data
    //   entry -> issue        rsX_data     -- only while rsX_ready
    //   bypass -> issue       bypass_data  -- only while !rsX_ready & fast_ready_rsX
    //
    // The last two are mutually exclusive for one rsX and the three sources
    // resolve in parallel.  The forwarded value goes around the entry and is
    // never written into it in an issue cycle.  When a source is neither ready
    // nor forwarded the entry value is presented and issue_valid is 0, so
    // nothing samples it.
    //
    // No output is gated by issue_valid: the strobe carries the validity and
    // 集成层 §1.5 has the FU latch on the move.
    //
    // The per-source select is NOT written out here: it is the internal
    // sub-block FU_input_mux, instantiated once per source.  This group is the
    // only one with three copies -- rs1 / rs2 / rs3 -- because it is the only
    // one that uses rs3.  The sub-block is internal to ISQ_Group, so the
    // integration layer does not register it and it has no entry in ⑥.
    // ------------------------------------------------------------------
    logic [XLEN-1:0]            fu_rs_data [1:FP_READ_PORTS];

    FU_input_mux u_fu_input_mux_rs1 (
        .entry_rsX_data (entry_rs_data[1]),
        .bypass_data    (bypass_data),
        .bypass_publish_valid   (bypass_publish_valid),
        .bypass_tag     (bypass_tag),
        .rsX_wait_tag   (entry_rs_wait_tag[1]),
        .rsX_ready      (entry_rs_ready[1]),
        .fu_rsX_data    (fu_rs_data[1])
    );

    FU_input_mux u_fu_input_mux_rs2 (
        .entry_rsX_data (entry_rs_data[2]),
        .bypass_data    (bypass_data),
        .bypass_publish_valid   (bypass_publish_valid),
        .bypass_tag     (bypass_tag),
        .rsX_wait_tag   (entry_rs_wait_tag[2]),
        .rsX_ready      (entry_rs_ready[2]),
        .fu_rsX_data    (fu_rs_data[2])
    );

    FU_input_mux u_fu_input_mux_rs3 (
        .entry_rsX_data (entry_rs_data[3]),
        .bypass_data    (bypass_data),
        .bypass_publish_valid   (bypass_publish_valid),
        .bypass_tag     (bypass_tag),
        .rsX_wait_tag   (entry_rs_wait_tag[3]),
        .rsX_ready      (entry_rs_ready[3]),
        .fu_rsX_data    (fu_rs_data[3])
    );

    assign rs1_data    = fu_rs_data[1];
    assign rs2_data    = fu_rs_data[2];
    assign rs3_data    = fu_rs_data[3];
    assign self_tag    = entry_self_tag;
    assign exe_subop   = entry_exe_subop;
    assign full_decode = entry_full_decode;

    // ------------------------------------------------------------------
    // (2)/(4)#1 the single entry
    //
    // Priority, top down:
    //   flush            ③ "优先级最高：flush 拍不 dispatch、不 issue、不 capture"
    //   dispatch         dispatch_valid captures payload_in and leaves the entry
    //                    RESIDENT; it overwrites whatever was there, which is
    //                    exactly the FREE->RESIDENT and the same-cycle
    //                    RESIDENT->RESIDENT transition of ②.  A dispatch into
    //                    an occupied non-issuing entry cannot occur: ⑥ has the
    //                    upstream absorb ready = isq_free_for_dispatch.
    //   issue            RESIDENT->FREE, only when no dispatch refills it
    //   bypass_capture   RESIDENT->RESIDENT, sets rsX_ready and updates
    //                    rsX_data for every source that hit.  rsX_wait_tag is
    //                    deliberately left alone -- rewriting it would make the
    //                    next cycle re-match against a fresh tag (④).
    // ------------------------------------------------------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            entry_valid       <= 1'b0;
            entry_self_tag    <= '0;
            entry_exe_subop   <= '0;
            entry_full_decode <= '0;
            for (int unsigned x = 1; x <= FP_READ_PORTS; x++) begin
                entry_rs_ready[x]    <= 1'b0;
                entry_rs_wait_tag[x] <= '0;
                entry_rs_data[x]     <= '0;
            end
        end else if (global_flush_late) begin
            // flush: isq_valid <- 0, no payload to clean up
            entry_valid <= 1'b0;
        end else if (dispatch_valid) begin
            // dispatch: capture exactly the ⑤ fields, drop the rest
            entry_valid          <= 1'b1;
            entry_rs_ready[1]    <= payload_in.rs1_ready;
            entry_rs_ready[2]    <= payload_in.rs2_ready;
            entry_rs_ready[3]    <= payload_in.rs3_ready;
            entry_rs_wait_tag[1] <= payload_in.rs1_wait_tag;
            entry_rs_wait_tag[2] <= payload_in.rs2_wait_tag;
            entry_rs_wait_tag[3] <= payload_in.rs3_wait_tag;
            entry_rs_data[1]     <= payload_in.rs1_data;
            entry_rs_data[2]     <= payload_in.rs2_data;
            entry_rs_data[3]     <= payload_in.rs3_data;
            entry_self_tag       <= payload_in.self_tag;
            entry_exe_subop      <= payload_in.exe_subop;
            entry_full_decode    <= payload_in.full_decode;
        end else if (issue_fire) begin
            // issue with no dispatch behind it: RESIDENT -> FREE
            entry_valid <= 1'b0;
        end else if (bypass_capture) begin
            // fast_ready[x] implies !rsX_ready and a lane hit, so fu_rs_data[x]
            // is that lane's bypass_data -- the capture path reuses the same
            // FU_input_mux output instead of a second copy of the select.
            for (int unsigned x = 1; x <= FP_READ_PORTS; x++) begin
                if (fast_ready[x]) begin
                    entry_rs_ready[x] <= 1'b1;
                    entry_rs_data[x]  <= fu_rs_data[x];
                end
            end
        end
    end

endmodule

`endif // ISQ_GROUP2_SV
