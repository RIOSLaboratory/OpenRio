`ifndef FP_TAG_MAPPING_SV
`define FP_TAG_MAPPING_SV

/* verilator lint_off IMPORTSTAR */
import or_be_types_pkg::*;
/* verilator lint_on IMPORTSTAR */

// FP_tag_mapping -- 32 entry x {busy, latest_tag} FP rename map
// (FP_tag_mapping微架构文档).
//
// (1) per-entry state          : IDLE / BUSY -- busy(1); 1 = a producer exists.
//                                entry 0 is an ordinary entry: RISC-V F/D gives
//                                f0 no zero semantics, so it renames, goes busy
//                                and is written like any other.  The hardwired
//                                rule is integer-only and is deliberately absent
// (2) state transition         : IDLE -> BUSY on alloc; BUSY -> IDLE on commit;
//                                BUSY -> BUSY on alloc (a younger instruction
//                                renames the same entry -- the tag is swapped,
//                                which is not a phase change); ANY -> IDLE on
//                                flush
// (3) condition                : alloc[s]  = accept[s] & alloc_rd_write_enable[s]
//                                            & alloc_rd_is_fp[s]
//                                commit[k] = commit_valid[k]
//                                            & commit_rd_write_enable[k]
//                                            & commit_rd_is_fp[k]
//                                            & entry[commit_rd_idx[k]].tag
//                                              == commit_tag[k]
//                                flush     = global_flush_late
// (4) data path                : 1 alloc write port (self_tag[s] -> the tag of
//                                entry[alloc_rd_idx[s]]), 3 combinational read ports
//                                (entry[fp_read_idx[1:3]] -> tag, busy).
//                                commit writes only busy <= 0 -- its payload is
//                                zero width, so it is not a value-carrying edge
// (5) data structure           : state  busy
//                                header tag -- written by alloc, compared
//                                       against commit_tag by commit
//                                payload none
//
// Unlike the integer map this has exactly **one** write port and **one** clear
// port.  A cycle's accepted set holds at most one instruction that touches the
// FP register file (dispatch_logic ④ blocks a second FP candidate, so slot1
// produces no consumer when both are FP), and the double-FP-commit block keeps
// the retire pair down to one FP writer per cycle (CompletionScoreboard ④ step
// 3).  The per-slot / per-lane inputs below are therefore *candidates* that fold
// into a single port, not two independent ports.
//
// Write order (③): commit first -> a younger alloc on the same entry overrides
// it -> flush suppresses the alloc and returns the whole table to IDLE.
//
// Port naming: 文档 ⑥ names the alloc and the commit group's address and
// qualifiers identically -- `alloc_rd_idx` / `alloc_rd_is_fp` / `alloc_rd_write_enable` appear
// once as [s] and once as [k] -- and gives no distinguishing spelling.  The
// commit copies carry a commit_ prefix here, matching the `commit_valid` /
// `commit_tag` the doc already prefixes; see FP_tag_mapping.portmap.
module FP_tag_mapping (
    input  logic                  clk,
    input  logic                  rst_n,

    // in-event: alloc (announce, 1 write port; candidates presented per slot)
    input  logic                  accept                 [ISSUE_WIDTH],
    input  logic                  alloc_rd_write_enable        [ISSUE_WIDTH],
    input  logic                  alloc_rd_is_fp               [ISSUE_WIDTH],
    input  logic [REG_ADDR_W-1:0] alloc_rd_idx                 [ISSUE_WIDTH],
    input  logic [TAG_W-1:0]      self_tag               [ISSUE_WIDTH],

    // in-event: commit (announce, 1 clear port; candidates presented per lane)
    input  logic                  commit_valid           [ISSUE_WIDTH],
    input  logic [TAG_W-1:0]      commit_tag             [ISSUE_WIDTH],
    input  logic [REG_ADDR_W-1:0] commit_rd_idx          [ISSUE_WIDTH],
    input  logic                  commit_rd_is_fp        [ISSUE_WIDTH],
    input  logic                  commit_rd_write_enable [ISSUE_WIDTH],

    // in-event: flush (announce, single-wire pulse, no payload)
    input  logic                  global_flush_late,

    // in-event: combinational read addresses, one per FP source x = 1/2/3
    input  logic [REG_ADDR_W-1:0] fp_read_idx            [1:3],

    // out-event: combinational read data, one {tag, busy} pair per read port
    output logic [TAG_W-1:0]      tag                    [1:3],
    output logic                  busy                   [1:3]
);

    // ------------------------------------------------------------------
    // (5) state + header storage.  32 entries, f0 included.
    // ------------------------------------------------------------------
    logic             entry_busy [NUM_FPR];
    logic [TAG_W-1:0] entry_tag  [NUM_FPR];

    // ------------------------------------------------------------------
    // (3) alloc[s] -> the single write port
    //
    // At most one slot qualifies in a cycle, so the scan below is a plain
    // OR-select of that one candidate, not arbitration: if both candidates were
    // FP, dispatch_logic would not have accepted slot1.  Taking slot0 first is
    // the same order the upstream block uses.
    // ------------------------------------------------------------------
    logic                  alloc_en;
    logic [REG_ADDR_W-1:0] alloc_idx;
    logic [TAG_W-1:0]      alloc_tag;

    always_comb begin
        alloc_en  = 1'b0;
        alloc_idx = '0;
        alloc_tag = '0;
        for (int unsigned s = 0; s < ISSUE_WIDTH; s++) begin
            if (!alloc_en && accept[s] && alloc_rd_write_enable[s] && alloc_rd_is_fp[s]) begin
                alloc_en  = 1'b1;
                alloc_idx = alloc_rd_idx[s];
                alloc_tag = self_tag[s];
            end
        end
    end

    // ------------------------------------------------------------------
    // (3) commit[k] -> the single clear port
    //
    // The tag comparison is not optional: by the time an instruction retires,
    // its architectural entry may already have been renamed by a younger one,
    // and clearing busy then would drop a live producer.  entry_tag enters the
    // comparison as its cycle-start register value, which is exactly the
    // "commit before alloc" order ③ asks for.
    //
    // The double-FP-commit block keeps at most one lane qualifying per cycle,
    // so this scan is again an OR-select rather than arbitration.
    // ------------------------------------------------------------------
    logic                  clear_en;
    logic [REG_ADDR_W-1:0] clear_idx;

    always_comb begin
        clear_en  = 1'b0;
        clear_idx = '0;
        for (int unsigned k = 0; k < ISSUE_WIDTH; k++) begin
            if (!clear_en && commit_valid[k] && commit_rd_write_enable[k]
                && commit_rd_is_fp[k]
                && (entry_tag[commit_rd_idx[k]] == commit_tag[k])) begin
                clear_en  = 1'b1;
                clear_idx = commit_rd_idx[k];
            end
        end
    end

    // ------------------------------------------------------------------
    // (2) IDLE <-> BUSY, plus (4)#1 self_tag[s] -> entry[alloc_rd_idx[s]].tag
    //
    // Ordering inside the cycle, top to bottom of ③'s write order:
    //   flush wins over everything and returns the whole table to IDLE;
    //   otherwise the clear lands first and a same-entry alloc overwrites it,
    //   which is what the trailing alloc assignment expresses.
    // commit never touches tag -- only alloc writes the header.
    // ------------------------------------------------------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int unsigned i = 0; i < NUM_FPR; i++) begin
                entry_busy[i] <= 1'b0;
                entry_tag[i]  <= '0;
            end
        end else if (global_flush_late) begin
            for (int unsigned i = 0; i < NUM_FPR; i++) begin
                entry_busy[i] <= 1'b0;
            end
        end else begin
            if (clear_en) begin
                entry_busy[clear_idx] <= 1'b0;
            end
            if (alloc_en) begin
                entry_busy[alloc_idx] <= 1'b1;
                entry_tag[alloc_idx]  <= alloc_tag;
            end
        end
    end

    // ------------------------------------------------------------------
    // (4)#1 entry[fp_read_idx[x]] -> tag[x], busy[x]  (3 read ports)
    //
    // The three ports are independent and concurrent; the addresses arrive
    // already muxed by FP_read_address_mux and this module does no arbitration.
    // Reads see the registered state, so a rename allocated this cycle is only
    // visible from the next one.
    // ------------------------------------------------------------------
    always_comb begin
        tag[1]  = entry_tag[fp_read_idx[1]];
        busy[1] = entry_busy[fp_read_idx[1]];
        tag[2]  = entry_tag[fp_read_idx[2]];
        busy[2] = entry_busy[fp_read_idx[2]];
        tag[3]  = entry_tag[fp_read_idx[3]];
        busy[3] = entry_busy[fp_read_idx[3]];
    end

endmodule

`endif // FP_TAG_MAPPING_SV
