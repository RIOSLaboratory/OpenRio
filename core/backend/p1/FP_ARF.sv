`ifndef FP_ARF_SV
`define FP_ARF_SV

/* verilator lint_off IMPORTSTAR */
import or_be_types_pkg::*;
/* verilator lint_on IMPORTSTAR */

// FP_ARF -- 32 entry x 64 bit architectural FP register file (FP_ARF微架构文档).
//
// (1) per-entry state          : none
// (2) state transition         : none
// (3) condition                : none
// (4) data path                : 1 commit write port (address rd_idx[k]),
//                                3 combinational read ports (fp_read_idx[1:3])
// (5) data structure           : payload only -- ARF[idx](64)
//
// Three properties of the FP file that the integer file does not share:
//
//   * **No x0 special case.**  f0 is an ordinary architectural register, so the
//     write enable is exactly ④#2 -- there is no `rd_idx != 0` term and no
//     read-side zero forcing.
//   * **One write port, not two.**  ⑥ registers the commit bus as 1 write port
//     over two commit lanes; the commit side blocks a double-FP retire
//     (CompletionScoreboard ④ third step), so at most one of write_req[k] can
//     be asserted in a cycle and the single port never has to arbitrate.  The
//     lane-0-first priority below is therefore a don't-care tie-break kept only
//     so the port is fully specified.
//   * **Three read ports, not four.**  A double-FP dispatch is blocked
//     (dispatch_logic ④), so the three ports serve whichever slot owns the FP
//     read this cycle; FP_read_address_mux does that selection upstream.
//
// Deliberately has no flush port: ④ says flush does not touch this table -- the
// architectural FP state is by definition what survives a flush.
//
// Deliberately has no read-during-write forwarding either: 集成层 §2.1 selects
// between sel_arf and sel_commit with a code that dependency_check generates, so
// a same-cycle commit is consumed from commit_data, never from this file.
module FP_ARF (
    input  logic                  clk,
    input  logic                  rst_n,

    // in-event: commit (announce, 1 write port over ISSUE_WIDTH commit lanes)
    input  logic                  commit_valid    [ISSUE_WIDTH],
    input  logic                  rd_write_enable [ISSUE_WIDTH],
    input  logic                  rd_is_fp        [ISSUE_WIDTH],
    input  logic [REG_ADDR_W-1:0] rd_idx          [ISSUE_WIDTH],
    input  logic [XLEN-1:0]       commit_data     [ISSUE_WIDTH],

    // in-event: combinational read addresses, 3 ports numbered 1..3 to match
    // `fp_read_idx[x]`, x in {1,2,3} (⑥; 集成层 §1.1 / §2.1).  or_be_types_pkg
    // has no constant for this multiplicity, so the range is the documented one.
    input  logic [REG_ADDR_W-1:0] fp_read_idx     [1:3],

    // out-event: combinational read data, ARF[fp_read_idx[x]]
    output logic [XLEN-1:0]       ARF             [1:3]
);

    // ------------------------------------------------------------------
    // (5) payload storage -- ARF[idx](64), 32 entries (NUM_FPR)
    // ------------------------------------------------------------------
    logic [XLEN-1:0] entry_arf [NUM_FPR];

    // ------------------------------------------------------------------
    // (4)#2 write[k] = commit_valid[k] & rd_write_enable[k] & rd_is_fp[k]
    //
    // Only commit writes.  rd_is_fp[k] is what keeps an integer retire out of
    // this file; no x0 term, f0 is writable.
    // ------------------------------------------------------------------
    logic [ISSUE_WIDTH-1:0] write_req;

    always_comb begin
        for (int unsigned k = 0; k < ISSUE_WIDTH; k++) begin
            write_req[k] = commit_valid[k] & rd_write_enable[k] & rd_is_fp[k];
        end
    end

    // ------------------------------------------------------------------
    // (4)#1 write port: commit_data -> entry[rd_idx[k]]
    //
    // Collapse the two commit lanes onto the single documented write port.
    // The loop counts down so lane 0 (the older retire) is assigned last and
    // therefore wins; with the double-FP commit block in place the two requests
    // are never simultaneous, so the tie-break is unobservable.
    // ------------------------------------------------------------------
    logic                  dispatch_valid;
    logic [REG_ADDR_W-1:0] wr_idx;
    logic [XLEN-1:0]       wr_data;

    always_comb begin
        dispatch_valid   = 1'b0;
        wr_idx  = '0;
        wr_data = '0;
        for (int unsigned k = ISSUE_WIDTH; k > 0; k--) begin
            if (write_req[k-1]) begin
                dispatch_valid   = 1'b1;
                wr_idx  = rd_idx[k-1];
                wr_data = commit_data[k-1];
            end
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int unsigned i = 0; i < NUM_FPR; i++) begin
                entry_arf[i] <= '0;
            end
        end else if (dispatch_valid) begin
            entry_arf[wr_idx] <= wr_data;
        end
    end

    // ------------------------------------------------------------------
    // (4)#1 read ports: entry[fp_read_idx[1:3]] -> ARF[1:3]
    //
    // No fire condition on the read side (④): the addresses are always driven
    // and the data is always presented; the consumer decides whether to sample.
    // ------------------------------------------------------------------
    always_comb begin
        for (int unsigned x = 1; x <= 3; x++) begin
            ARF[x] = entry_arf[fp_read_idx[x]];
        end
    end

endmodule

`endif // FP_ARF_SV
