`ifndef PC_FILE_SV
`define PC_FILE_SV

/* verilator lint_off IMPORTSTAR */
import or_be_types_pkg::*;
/* verilator lint_on IMPORTSTAR */

// PC_File -- 16 entry x 64 bit instruction-PC store (PC_File微架构文档).
//
// (1) per-entry state          : none
// (2) state transition         : none
// (3) condition                : pc_write[s] = accept[s]
// (4) data path                : 2 dispatch-addressed write ports,
//                                3 independent combinational read ports
//                                (flush_tag, head_tag[0], head_tag[1])
// (5) data structure           : payload only -- inst_pc(64)
//
// pc_write[s] is the same cycle and the same slot as the CompletionScoreboard
// alloc[s]: only an instruction that was accepted and given self_tag[s] writes
// its inst_pc, which keeps PC_File[tag] on the SCB lifetime.  A tag therefore
// needs no clearing -- the next allocation of that tag overwrites the entry
// whole.
module PC_File (
    input  logic             clk,
    input  logic             rst_n,

    // in-event: write (announce x2, per dispatch slot, no back-pressure)
    input  logic             accept    [ISSUE_WIDTH],
    input  logic [TAG_W-1:0] self_tag  [ISSUE_WIDTH],
    input  logic [XLEN-1:0]  pc        [ISSUE_WIDTH],

    // in-event: combinational read addresses
    input  logic [TAG_W-1:0] flush_tag,
    input  logic [TAG_W-1:0]    head_tag [ISSUE_WIDTH],

    // out-event: combinational read data
    output logic [XLEN-1:0]  inst_pc,
    output logic [XLEN-1:0]  trace_pc  [ISSUE_WIDTH]
);

    // ------------------------------------------------------------------
    // (5) payload storage
    // ------------------------------------------------------------------
    logic [XLEN-1:0] entry_inst_pc [ROB_DEPTH];

    // ------------------------------------------------------------------
    // (4)#1 pc_write[s] -> entry[self_tag[s]].inst_pc
    //
    // The two dispatch slots take two distinct tags in the same cycle -- the
    // SCB allocation guarantees the addresses are orthogonal, so the two write
    // ports never collide.
    // ------------------------------------------------------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int unsigned i = 0; i < ROB_DEPTH; i++) begin
                entry_inst_pc[i] <= '0;
            end
        end else begin
            for (int unsigned s = 0; s < ISSUE_WIDTH; s++) begin
                if (accept[s]) begin
                    entry_inst_pc[self_tag[s]] <= pc[s];
                end
            end
        end
    end

    // ------------------------------------------------------------------
    // (4)#1 entry[flush_tag]   -> inst_pc      (recovery read port, trap epc)
    //       entry[head_tag[0]]   -> trace_pc[0]  (commit-point trace read port)
    //       entry[head_tag[1]]   -> trace_pc[1]  (commit-point trace read port)
    //
    // The three read ports are independent and concurrent in the same cycle;
    // each address comes from its own peer and this module does no arbitration.
    // The two trace ports only bypass the storage out -- they change neither
    // the contents nor the write ordering.
    // ------------------------------------------------------------------
    always_comb begin
        inst_pc     = entry_inst_pc[flush_tag];
        trace_pc[0] = entry_inst_pc[head_tag[0]];
        trace_pc[1] = entry_inst_pc[head_tag[1]];
    end

endmodule

`endif // PC_FILE_SV
