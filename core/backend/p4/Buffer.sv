`ifndef BUFFER_SV
`define BUFFER_SV

/* verilator lint_off IMPORTSTAR */
import or_be_types_pkg::*;
/* verilator lint_on IMPORTSTAR */

// Buffer -- 16 entry x 64 bit result store (Buffer微架构文档).
//
// (1) per-entry state          : none
// (2) state transition         : none
// (3) condition                : none
// (4) data path                : 4 random-addressed writeback write ports,
//                                2 combinational head read ports
// (5) data structure           : payload only -- result_data(64)
//
// Deliberately has no flush port: Buffer is not on the global_flush_late
// broadcast list.  Entries are overwritten by the next writeback that owns the
// tag, so stale payloads need no clearing.
module Buffer (
    input  logic                clk,
    input  logic                rst_n,

    // in-event: writeback (announce x4, 4 write ports, random addressing)
    input  logic                writeback_valid [NUM_LANES],
    input  logic [TAG_W-1:0]    tag_out      [NUM_LANES],
    input  logic [XLEN-1:0]     result_data  [NUM_LANES],

    // in-event: combinational read addresses from the SCB queue heads
    input  logic [TAG_W-1:0]    head_tag [ISSUE_WIDTH],

    // out-event: combinational read data, head0/head1 result_data
    output logic [XLEN-1:0]     commit_data  [ISSUE_WIDTH]
);

    // ------------------------------------------------------------------
    // (5) payload storage
    // ------------------------------------------------------------------
    logic [XLEN-1:0] entry_result_data [ROB_DEPTH];

    // ------------------------------------------------------------------
    // (4)#1 writeback -> entry[tag_out[g]].result_data
    //
    // The four completion lanes write four distinct tags in the same cycle;
    // the SCB allocation guarantees the addresses are orthogonal, so the four
    // write ports never collide.
    // ------------------------------------------------------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int unsigned i = 0; i < ROB_DEPTH; i++) begin
                entry_result_data[i] <= '0;
            end
        end else begin
            for (int unsigned g = 0; g < NUM_LANES; g++) begin
                if (writeback_valid[g]) begin
                    entry_result_data[tag_out[g]] <= result_data[g];
                end
            end
        end
    end

    // ------------------------------------------------------------------
    // (4)#1 entry[head0/1_tag] -> commit_data[k]
    //
    // Two read ports only; the read-out values fan out combinationally to the
    // INT ARF write data port, the FP ARF write data port and the §2.1
    // assembly, which does not add a third port.
    // ------------------------------------------------------------------
    always_comb begin
        commit_data[0] = entry_result_data[head_tag[0]];
        commit_data[1] = entry_result_data[head_tag[1]];
    end

endmodule

`endif // BUFFER_SV
