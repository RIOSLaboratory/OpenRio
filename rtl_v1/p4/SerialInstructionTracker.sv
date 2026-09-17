`ifndef SERIALINSTRUCTIONTRACKER_SV
`define SERIALINSTRUCTIONTRACKER_SV

/* verilator lint_off IMPORTSTAR */
import or_be_types_pkg::*;
/* verilator lint_on IMPORTSTAR */

// SerialInstructionTracker -- the backend's single {valid, tag} serial
// interlock (SerialInstructionTracker微架构文档).
//
// (1) per-entry state          : IDLE / INFLIGHT -- exactly one bit for the
//                                whole backend, not a per-tag array, and there
//                                is no pending buffer: the CSR write intent
//                                lives in system_instruction_handler's csr_stage
// (2) state transition         : IDLE -> INFLIGHT on serial_set;
//                                INFLIGHT -> IDLE on clear/commit (the tag
//                                comparison is its own proof) or on flush
// (3) condition                : set   = serial_set, which dispatch_logic
//                                        already folded accept[0] & serial0 and
//                                        the ready = !serial_inflight_valid
//                                        guard into (slot0 only)
//                                clear = serial_inflight_valid & commit_valid[k]
//                                        & commit_tag[k] == serial_inflight_tag
//                                flush = global_flush_late
// (4) data path                : the serial_set port drives serial_inflight_tag
//                                from self_tag[0]; clear and flush write only
//                                valid <= 0 and carry a zero-width payload, so
//                                they are not value-carrying edges
// (5) data structure           : state  serial_inflight_valid
//                                header serial_inflight_tag
//                                payload none
//
// No set/clear race exists and none is arbitrated here.  A set requires the
// dispatch-side buffer_empty sampled at the beginning of the cycle, so nothing
// can commit in the set cycle, and a fresh set is held off by the cycle-start
// value of serial_inflight_valid.  clear and flush may land together (MRET
// commits and then flushes); both write valid <= 0, so the next state agrees.
//
// ECALL / EBREAK never reach this module: they carry is_serial = 0 and so never
// set it.  Every non-committing path -- illegal CSR exception, an interrupt
// pre-empting the queue head, any flush while an atomic or FENCE is in flight --
// is released through the flush port instead.
module SerialInstructionTracker (
    input  logic             clk,
    input  logic             rst_n,

    // in-event: serial_set (transaction x1; ready = !serial_inflight_valid is
    // absorbed upstream by the dispatch_logic slot0 guard)
    input  logic             serial_set,
    input  logic [TAG_W-1:0] self_tag,

    // in-event: commit (announce, 2 lanes).  No separate trigger line -- a lane
    // being valid and matching the tracked tag is itself the clear.
    input  logic             commit_valid [ISSUE_WIDTH],
    input  logic [TAG_W-1:0] commit_tag   [ISSUE_WIDTH],

    // in-event: flush (announce, single-wire pulse, no payload)
    input  logic             global_flush_late,

    // Static Info: the state itself, read by dispatch_logic as a dispatch guard
    output logic             serial_inflight_valid
);

    // ------------------------------------------------------------------
    // (5) header -- written the moment serial_set fires and compared against
    // commit_tag[k] at clear time.  Nothing else ever writes it.
    // ------------------------------------------------------------------
    logic [TAG_W-1:0] serial_inflight_tag;

    // ------------------------------------------------------------------
    // (3) clear/commit comparison
    //
    // The tracked tag belongs to that one serial instruction from the moment it
    // is set until it retires or is flushed, and while it is in flight it is the
    // only instruction in the machine -- so a commit lane carrying a matching
    // tag can only be it.  serial_inflight_valid enters the comparison as its
    // cycle-start register value.
    // ------------------------------------------------------------------
    logic commit_hit;

    always_comb begin
        commit_hit = 1'b0;
        for (int unsigned k = 0; k < ISSUE_WIDTH; k++) begin
            if (commit_valid[k] && (commit_tag[k] == serial_inflight_tag)) begin
                commit_hit = 1'b1;
            end
        end
    end

    // ------------------------------------------------------------------
    // (2) IDLE <-> INFLIGHT, plus (4)#1 self_tag[0] -> serial_inflight_tag
    // ------------------------------------------------------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            serial_inflight_valid <= 1'b0;
            serial_inflight_tag   <= '0;
        end else if (global_flush_late) begin
            serial_inflight_valid <= 1'b0;
        end else if (serial_set) begin
            serial_inflight_valid <= 1'b1;
            serial_inflight_tag   <= self_tag;
        end else if (serial_inflight_valid && commit_hit) begin
            serial_inflight_valid <= 1'b0;
        end
    end

endmodule

`endif // SERIALINSTRUCTIONTRACKER_SV
