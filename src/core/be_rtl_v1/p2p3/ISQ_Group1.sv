`ifndef ISQ_GROUP1_SV
`define ISQ_GROUP1_SV

/* verilator lint_off IMPORTSTAR */
import or_be_types_pkg::*;
/* verilator lint_on IMPORTSTAR */

// ISQ_Group1 -- ALU1 + MUL issue queue, one entry.
//
// (1) per-entry state          : FREE / RESIDENT, carried by `isq_valid` alone;
//                                one entry, therefore no pointers
// (2) state transition         : dispatch / bypass_capture / issue / flush
// (3) condition                : flush > dispatch > issue > bypass_capture
// (4) data path                : payload capture at dispatch, per-source
//                                bypass capture, whole-payload issue
// (5) data structure           : state + header (ready / wait_tag / FU_Group)
//                                + payload (rsX_data, imm, self_tag, exe_subop)
//
// In-group FU index: FU_Group = 0 is ALU1, = 1 is MUL.  The
// index is issued as-is and decoded by the FU itself; this module only uses it
// to select `FU_ready`.
//
// This group has only two sources.  `rs3_*` and the instruction identity /
// branch prediction / memory / full_decode fields exist on `payload_in` but
// are **not captured by this group** -- leaving them dangling is intentional, not a missed connection.
//
// Each source's two-way select on the issue port, "data stored in the entry
// vs this cycle's bypass forward", is not inlined here; instead the internal
// sub-block `FU_input_mux` is instantiated (one each for rs1 / rs2).  This
// module still computes `fast_ready_rsX` itself -- the issue checker needs
// it -- and the sub-block only takes the data to do the select.
module ISQ_Group1 (
    input  logic                    clk,
    input  logic                    rst_n,

    // in-event: dispatch (Transaction, single strobe, 1 write port)
    // The ready side is the `isq_free_for_dispatch` below, already absorbed upstream.
    input  logic                    wr_en,
    input  isq_payload_t            payload_in,

    // in-event: bypass_capture (announce, all 4 lanes listened to -- bypass is a global broadcast)
    input  logic                    bypass_valid [NUM_LANES],
    input  logic [TAG_W-1:0]        bypass_tag   [NUM_LANES],
    input  logic [XLEN-1:0]         bypass_data  [NUM_LANES],

    // in-event: flush (announce, single-wire pulse, no payload)
    input  logic                    global_flush_late,

    // in-event: combinational read -- one bit per in-group requester, FU_Group ∈ {0,1}
    input  logic                    FU_ready [G1_NUM_FU],

    // out-event: issue -- to the FU outside the library
    output logic                    issue_valid,
    output logic [XLEN-1:0]         rs1_data,
    output logic [XLEN-1:0]         rs2_data,
    output logic [FU_GROUP_W-1:0]   FU_Group,
    output logic                    imm_valid,
    output logic [XLEN-1:0]         imm_data,
    output logic [TAG_W-1:0]        self_tag,
    output logic [EXE_SUBOP_W-1:0]  exe_subop,

    // Static Info
    output logic                    isq_free_for_dispatch
);

    // ------------------------------------------------------------------
    // In-group FU index.  There are only two requesters, so `FU_ready` is
    // a 2:1 select, not a full decode of FU_GROUP_W bits.
    // ------------------------------------------------------------------
    localparam logic [FU_GROUP_W-1:0] FU_GROUP_ALU1 = FU_GROUP_W'(0);
    localparam logic [FU_GROUP_W-1:0] FU_GROUP_MUL  = FU_GROUP_W'(1);

    // ------------------------------------------------------------------
    // (5) entry -- state + header + payload
    //
    // The ports already use the entry's field names (sent out as-is on the issue
    // side), so the storage side uniformly gets an `ent_` prefix; `isq_valid`
    // has no prefix, that is the state's own name, and there is no port of the
    // same name.
    // ------------------------------------------------------------------
    logic                    isq_valid;          // state: 0 = FREE, 1 = RESIDENT

    logic                    ent_rs1_ready;      // header
    logic                    ent_rs2_ready;
    logic [TAG_W-1:0]        ent_rs1_wait_tag;
    logic [TAG_W-1:0]        ent_rs2_wait_tag;
    logic [FU_GROUP_W-1:0]   ent_fu_group;

    logic [XLEN-1:0]         ent_rs1_data;       // payload
    logic [XLEN-1:0]         ent_rs2_data;
    logic                    ent_imm_valid;
    logic [XLEN-1:0]         ent_imm_data;
    logic [TAG_W-1:0]        ent_self_tag;
    logic [EXE_SUBOP_W-1:0]  ent_exe_subop;

    // ------------------------------------------------------------------
    // (3) fast_ready_rsX
    //
    //     fast_ready_rsX = !rsX_ready ∧ OR over b∈{0..3}
    //                      (bypass_valid[b] ∧ rsX_wait_tag == bypass_tag[b])
    //
    // All four lanes are compared.  Which lane wins when several lanes hit
    // the same tag in one cycle is irrelevant to this checker -- it only needs
    // "is there a hit"; whose data is taken is decided by `FU_input_mux`
    // per "take the lowest-numbered one".
    // ------------------------------------------------------------------
    logic bypass_hit_rs1;
    logic bypass_hit_rs2;
    logic fast_ready_rs1;
    logic fast_ready_rs2;

    always_comb begin
        bypass_hit_rs1 = 1'b0;
        bypass_hit_rs2 = 1'b0;
        for (int unsigned b = 0; b < NUM_LANES; b++) begin
            if (bypass_valid[b] && (ent_rs1_wait_tag == bypass_tag[b])) begin
                bypass_hit_rs1 = 1'b1;
            end
            if (bypass_valid[b] && (ent_rs2_wait_tag == bypass_tag[b])) begin
                bypass_hit_rs2 = 1'b1;
            end
        end
    end

    assign fast_ready_rs1 = !ent_rs1_ready && bypass_hit_rs1;
    assign fast_ready_rs2 = !ent_rs2_ready && bypass_hit_rs2;

    // ------------------------------------------------------------------
    // (3) issue
    //
    //     operand_ready = (rs1_ready ∨ fast_ready_rs1)
    //                   ∧ (rs2_ready ∨ fast_ready_rs2)      // this group does not use rs3
    //     issue_req     = isq_valid ∧ operand_ready
    //     issue         = issue_req ∧ FU_ready[FU_Group] ∧ !global_flush_late
    //
    // Name note: `isq_valid ∧ operand_ready` is not `issue_valid`;
    // in this file it is called `issue_req`.  The external port `issue_valid`
    // = issue_req ∧ !global_flush_late, **without FU_ready** (request line,
    // see below); the full `issue` including FU_ready is called
    // `issue_fire` in this file, used only to release the entry, not sent out.
    //
    // `FU_ready` enters issue_fire combinationally, so the FU-side ready must
    // not in turn depend on this module's `issue_valid` (FU_ready definition:
    // ALU1 = !loser_hold, MUL = !busy ∧ !loser_hold, both only look at their
    // own state and the P3 in-group arbitration result).
    // ------------------------------------------------------------------
    logic operand_ready;
    logic fu_ready_sel;
    logic issue_req;
    logic issue_fire;
    logic bypass_capture;

    assign operand_ready = (ent_rs1_ready || fast_ready_rs1)
                        && (ent_rs2_ready || fast_ready_rs2);

    assign issue_req = isq_valid && operand_ready;

    always_comb begin
        // `FU_ready[FU_Group]` is taken by in-group index.  FU_Group's
        // values are {0,1}, and the group has only two requesters,
        // hence 2:1.
        if (ent_fu_group == FU_GROUP_MUL) begin
            fu_ready_sel = FU_ready[1];
        end else begin
            fu_ready_sel = FU_ready[0];
        end
    end

    // `issue_valid` is a **request line, not a fire line** -- it
    // does not include FU_ready.  valid containing ready means coupling: when
    // ready drops, valid drops, which immediately breaks "once raised, valid
    // stays stable until the handshake succeeds", and FU_ready must not in turn
    // depend on valid either (a loop).  The entry is released by
    // issue_fire = issue_valid ∧ FU_ready, i.e. `issue` above.
    assign issue_valid = issue_req && !global_flush_late;
    assign issue_fire  = issue_valid && fu_ready_sel;

    // ------------------------------------------------------------------
    // (3) bypass_capture
    //
    //     bypass_capture = isq_valid ∧ !global_flush_late ∧ !issue
    //                    ∧ (fast_ready_rs1 ∨ fast_ready_rs2)
    //
    // On a same-cycle issue there is no capture, only a forward to the FU (the
    // forward path is the FU_input_mux below).
    // ------------------------------------------------------------------
    assign bypass_capture = isq_valid && !global_flush_late && !issue_fire
                         && (fast_ready_rs1 || fast_ready_rs2);

    // ------------------------------------------------------------------
    // (3) sampling convention: the external free projection, including the
    // same-cycle issue
    //
    //     isq_free_for_dispatch = !isq_valid ∨ issue
    //
    // No separate projection for the flush cycle: upstream
    // does not dispatch in a flush cycle anyway.
    // ------------------------------------------------------------------
    assign isq_free_for_dispatch = !isq_valid || issue_fire;

    // ------------------------------------------------------------------
    // Per-source two-way select on the issue side -- internal sub-block,
    // one per source
    //
    //   rsX_ready              → the rsX_data stored in the entry
    //   !rsX_ready ∧ lane hit  → bypass_data[b], bypassing the entry and
    //                            forwarding directly
    //
    // This forwarded value is also bypass_capture's write data source: what a
    // capture hit writes into the entry is the same bypass_data[b], so no
    // second copy of the select logic is written.
    // ------------------------------------------------------------------
    logic [XLEN-1:0] fu_rs1_data;
    logic [XLEN-1:0] fu_rs2_data;

    FU_input_mux u_fu_input_mux_rs1 (
        .entry_rsX_data (ent_rs1_data),
        .bypass_data    (bypass_data),
        .bypass_valid   (bypass_valid),
        .bypass_tag     (bypass_tag),
        .rsX_wait_tag   (ent_rs1_wait_tag),
        .rsX_ready      (ent_rs1_ready),
        .fu_rsX_data    (fu_rs1_data)
    );

    FU_input_mux u_fu_input_mux_rs2 (
        .entry_rsX_data (ent_rs2_data),
        .bypass_data    (bypass_data),
        .bypass_valid   (bypass_valid),
        .bypass_tag     (bypass_tag),
        .rsX_wait_tag   (ent_rs2_wait_tag),
        .rsX_ready      (ent_rs2_ready),
        .fu_rsX_data    (fu_rs2_data)
    );

    // ------------------------------------------------------------------
    // Entry -> issue output port
    //
    // All payload fields other than source data are sent out as-is, not
    // gated by issue_valid: there is no clearing; delivery is delimited by issue_valid.
    // `exe_subop` is issued as-is and not decoded in this module.
    // ------------------------------------------------------------------
    assign rs1_data  = fu_rs1_data;
    assign rs2_data  = fu_rs2_data;
    assign FU_Group  = ent_fu_group;
    assign imm_valid = ent_imm_valid;
    assign imm_data  = ent_imm_data;
    assign self_tag  = ent_self_tag;
    assign exe_subop = ent_exe_subop;

    // ------------------------------------------------------------------
    // (2) state and entry update
    //
    //   flush           isq_valid ← 0; no dispatch, no issue, no capture this cycle
    //   dispatch        isq_valid ← 1, all entry fields ← payload_in
    //                   (dispatch still wins on a same-cycle issue: RESIDENT → RESIDENT)
    //   issue           isq_valid ← 0 when there is no dispatch this cycle
    //   bypass_capture  only sets rsX_ready and rsX_data, rsX_wait_tag unchanged --
    //                   changing it would re-match against a new tag next cycle
    //
    // dispatch is ordered before bypass_capture: dispatch overwrites the whole
    // entry, so this cycle's capture into the old entry is meaningless; the
    // new payload's same-cycle bypass is already merged into payload_in at the
    // entrance by the top-level payload assembly (sel_bypass of rs_data_sel_t).
    // ------------------------------------------------------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            isq_valid        <= 1'b0;
            ent_rs1_ready    <= 1'b0;
            ent_rs2_ready    <= 1'b0;
            ent_rs1_wait_tag <= '0;
            ent_rs2_wait_tag <= '0;
            ent_fu_group     <= FU_GROUP_ALU1;
            ent_rs1_data     <= '0;
            ent_rs2_data     <= '0;
            ent_imm_valid    <= 1'b0;
            ent_imm_data     <= '0;
            ent_self_tag     <= '0;
            ent_exe_subop    <= '0;
        end else if (global_flush_late) begin
            // (3) flush has the highest priority, no payload: only state is
            // cleared, the payload is left in place and ignored.
            isq_valid        <= 1'b0;
        end else if (wr_en) begin
            // dispatch input port → entry: only the entry's fields
            // are captured, the rest are dropped.
            isq_valid        <= 1'b1;
            ent_rs1_ready    <= payload_in.rs1_ready;
            ent_rs2_ready    <= payload_in.rs2_ready;
            ent_rs1_wait_tag <= payload_in.rs1_wait_tag;
            ent_rs2_wait_tag <= payload_in.rs2_wait_tag;
            ent_fu_group     <= payload_in.fu_group;
            ent_rs1_data     <= payload_in.rs1_data;
            ent_rs2_data     <= payload_in.rs2_data;
            ent_imm_valid    <= payload_in.imm_valid;
            ent_imm_data     <= payload_in.imm_data;
            ent_self_tag     <= payload_in.self_tag;
            ent_exe_subop    <= payload_in.exe_subop;
        end else if (issue_fire) begin
            isq_valid        <= 1'b0;
        end else if (bypass_capture) begin
            if (fast_ready_rs1) begin
                ent_rs1_ready <= 1'b1;
                ent_rs1_data  <= fu_rs1_data;
            end
            if (fast_ready_rs2) begin
                ent_rs2_ready <= 1'b1;
                ent_rs2_data  <= fu_rs2_data;
            end
        end
    end

endmodule

`endif // ISQ_GROUP1_SV
