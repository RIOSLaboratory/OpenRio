`ifndef INT_ARF_SV
`define INT_ARF_SV

/* verilator lint_off IMPORTSTAR */
import or_be_types_pkg::*;
/* verilator lint_on IMPORTSTAR */

// INT_ARF -- 32 entry x 64 bit integer architectural register file
// (INT_ARF微架构文档).
//
// (1) per-entry state          : none
// (2) state transition         : none
// (3) condition                : none
// (4) data path                : 2 commit-addressed write ports,
//                                4 combinational read ports
// (5) data structure           : payload only -- ARF(64), entry 0 hardwired 0
//
// Only commit writes here.  Execution writeback lands somewhere else (the
// Buffer); letting it into this file would put a speculative result on
// architectural state.  For the same reason there is no flush port --
// architectural state has no speculative component, so there is nothing to
// roll back, and ④ says flush does not touch this table.
//
// Reads have no fire criterion: the four addresses are driven straight from
// upstream and the file answers combinationally every cycle.  There are only
// four read ports because rs3 never reads INT (upstream contract
// use_rs3[s] => rs3_is_fp[s]), so only rs1/rs2 of the two dispatch slots
// address this file.
module INT_ARF (
    input  logic                  clk,
    input  logic                  rst_n,

    // in-event: commit (announce, 2 write ports)
    input  logic                  commit_valid    [ISSUE_WIDTH],
    input  logic [REG_ADDR_W-1:0] rd_idx          [ISSUE_WIDTH],
    input  logic                  rd_is_fp        [ISSUE_WIDTH],
    input  logic                  rd_write_enable [ISSUE_WIDTH],
    input  logic [XLEN-1:0]       commit_data     [ISSUE_WIDTH],

    // in-event: combinational read addresses -- ⑥ `rs_idx[s][x]`(5x4).
    // Shape frozen by 集成层 §2.5(1): (s,x) with s in {0,1}, x in {1,2}.  The
    // source number *is* the index and its base is 1 -- there is no rs0 -- so
    // this is [1:INT_SRC_PER_SLOT], not [0:1].  Not flattened to [4]: that
    // would make slot-major vs source-major a second unowned choice.
    input  logic [REG_ADDR_W-1:0] rs_idx          [ISSUE_WIDTH][1:INT_SRC_PER_SLOT],

    // out-event: combinational read data -- ⑥ `ARF[s][x]`(64x4), same shape and
    // order as rs_idx above, cell for cell.
    output logic [XLEN-1:0]       ARF             [ISSUE_WIDTH][1:INT_SRC_PER_SLOT]
);

    // ------------------------------------------------------------------
    // (5) payload storage -- ARF[idx](64).
    //
    // Entry 0 is nobody's target (the write enable below masks rd_idx == 0)
    // and reads back as a hard zero (the read mux below).  That hardwire is
    // one of the three independent x0 defence lines ④ keeps; the other two
    // are upstream `rd_write_enable` and the rename table's own entry 0.
    // ------------------------------------------------------------------
    logic [XLEN-1:0] entry_arf [NUM_GPR];

    // ------------------------------------------------------------------
    // (4)#2 write[k] = commit_valid[k] & rd_write_enable[k] & !rd_is_fp[k]
    //                  & rd_idx[k] != 0
    //
    // `rd_idx[k] != 0` is the redundant insurance of ④: upstream already
    // suppressed the INT x0 write at rename time, and this term is kept
    // anyway.
    // ------------------------------------------------------------------
    logic arf_write [ISSUE_WIDTH];

    always_comb begin
        for (int unsigned k = 0; k < ISSUE_WIDTH; k++) begin
            arf_write[k] = commit_valid[k] && rd_write_enable[k] &&
                           !rd_is_fp[k] && (rd_idx[k] != '0);
        end
    end

    // ------------------------------------------------------------------
    // (4)#1 commit write ports -> entry[rd_idx[k]].ARF
    //
    // Two commit lanes may target the same entry in the same cycle (WAW).
    // The loop runs k ascending and the last assignment wins, so lane 1
    // (head1, the younger instruction) survives into the next state, which is
    // what ④ requires.
    // ------------------------------------------------------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int unsigned i = 0; i < NUM_GPR; i++) begin
                entry_arf[i] <= '0;
            end
        end else begin
            for (int unsigned k = 0; k < ISSUE_WIDTH; k++) begin
                if (arf_write[k]) begin
                    entry_arf[rd_idx[k]] <= commit_data[k];
                end
            end
        end
    end

    // ------------------------------------------------------------------
    // (4)#1 entry[rs_idx[s][x]] -> ARF read ports
    //
    // Four independent concurrent read ports, no arbitration and no fire
    // criterion.  Address 0 returns zero from the mux itself rather than from
    // the stored entry, so the x0 hardwire holds even if a write ever reached
    // entry 0.  No read-during-write bypass: a commit landing this cycle is
    // visible on the next one.
    // ------------------------------------------------------------------
    always_comb begin
        for (int unsigned s = 0; s < ISSUE_WIDTH; s++) begin
            for (int unsigned x = 1; x <= INT_SRC_PER_SLOT; x++) begin
                ARF[s][x] = (rs_idx[s][x] == '0) ? '0 : entry_arf[rs_idx[s][x]];
            end
        end
    end

endmodule

`endif // INT_ARF_SV
