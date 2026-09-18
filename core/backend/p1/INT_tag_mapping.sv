`ifndef INT_TAG_MAPPING_SV
`define INT_TAG_MAPPING_SV

/* verilator lint_off IMPORTSTAR */
import or_be_types_pkg::*;
/* verilator lint_on IMPORTSTAR */

// INT_tag_mapping -- 32 entry x {busy, latest_tag} (INT_tag_mapping微架构文档).
//
// (1) per-entry state          : IDLE / BUSY carried by busy(1); entry 0 is
//                                hardwired {busy:0, tag:0} and is never written
//                                by alloc / commit / flush, so integer x0 falls
//                                out of the ordinary resolve path (busy = 0 ->
//                                read ARF -> 0) with no x0 special case
// (2) state transition         : IDLE->BUSY alloc, BUSY->IDLE commit,
//                                BUSY->BUSY alloc (rename only, not a phase
//                                change), ANY->IDLE flush
// (3) condition                : see the alloc / commit_clear terms below; the
//                                write port order is commit -> alloc(slot0) ->
//                                alloc(slot1) -> flush
// (4) data path                : 2 alloc write ports (random addressed by
//                                rd_idx), 2 commit clear ports (busy only, zero
//                                payload width), 4 combinational read ports
// (5) data structure           : state busy(1); header tag(4) -- written by
//                                alloc, compared against commit_tag by commit;
//                                payload none
//
// 文档 ⑥ 用同一组名字 (`rd_idx` / `rd_is_fp` / `rd_write_enable`) 登记了 alloc
// 与 commit 两个来源不同的事件，端口名在此按事件加前缀区分，映射见
// INT_tag_mapping.portmap。
module INT_tag_mapping (
    input  logic                    clk,
    input  logic                    rst_n,

    // in-event: alloc (announce x2, 2 write ports, per dispatch slot)
    input  logic                    accept                [ISSUE_WIDTH],
    input  logic [TAG_W-1:0]        self_tag              [ISSUE_WIDTH],
    input  logic [REG_ADDR_W-1:0]   alloc_rd_idx          [ISSUE_WIDTH],
    input  logic                    alloc_rd_is_fp        [ISSUE_WIDTH],
    input  logic                    alloc_rd_write_enable [ISSUE_WIDTH],

    // in-event: commit (announce x2, 2 clear ports, per retire lane)
    input  logic                    commit_valid           [ISSUE_WIDTH],
    input  logic [TAG_W-1:0]        commit_tag             [ISSUE_WIDTH],
    input  logic [REG_ADDR_W-1:0]   commit_rd_idx          [ISSUE_WIDTH],
    input  logic                    commit_rd_is_fp        [ISSUE_WIDTH],
    input  logic                    commit_rd_write_enable [ISSUE_WIDTH],

    // in-event: flush (announce, single-wire pulse)
    input  logic                    global_flush_late,

    // in-event: combinational read addresses -- ⑥ `rs_idx[s][x]`(5x4).
    // Shape frozen by 集成层 §2.5(1): (s,x), s in {0,1}, x in {1,2}.  The source
    // number *is* the index and its base is 1 -- there is no rs0.  rs3 is
    // FP-only (集成层 §2.1), so the INT side stops at x = 2.
    input  logic [REG_ADDR_W-1:0]   rs_idx [ISSUE_WIDTH][1:INT_SRC_PER_SLOT],

    // out-event: combinational read data, same shape and order as the address
    // ports above, cell for cell
    output logic [TAG_W-1:0]        tag  [ISSUE_WIDTH][1:INT_SRC_PER_SLOT],
    output logic                    busy [ISSUE_WIDTH][1:INT_SRC_PER_SLOT]
);

    // ------------------------------------------------------------------
    // (5) storage -- state + header, no payload
    // ------------------------------------------------------------------
    logic             entry_busy [NUM_GPR];
    logic [TAG_W-1:0] entry_tag  [NUM_GPR];

    // ------------------------------------------------------------------
    // (3) alloc / commit conditions
    //
    // alloc[s]  = accept[s] & rd_write_enable[s] & !rd_is_fp[s]
    // commit[k] = commit_valid[k] & rd_write_enable[k] & !rd_is_fp[k]
    //             & rd_idx[k] != 0 & entry[rd_idx[k]].tag == commit_tag[k]
    //
    // The tag equality term is not optional: the entry may already have been
    // renamed by a younger instruction, and clearing busy here would release a
    // dependent while its real producer is still in flight.
    //
    // The `rd_idx != 0` guard is on the alloc side as well -- ① hardwires entry
    // 0 and states that alloc / commit / flush never write it.
    // ------------------------------------------------------------------
    logic alloc        [ISSUE_WIDTH];
    logic commit_clear [ISSUE_WIDTH];

    always_comb begin
        for (int unsigned s = 0; s < ISSUE_WIDTH; s++) begin
            alloc[s] = accept[s]
                       && alloc_rd_write_enable[s]
                       && !alloc_rd_is_fp[s]
                       && (alloc_rd_idx[s] != '0);
        end
        for (int unsigned k = 0; k < ISSUE_WIDTH; k++) begin
            commit_clear[k] = commit_valid[k]
                              && commit_rd_write_enable[k]
                              && !commit_rd_is_fp[k]
                              && (commit_rd_idx[k] != '0)
                              && (entry_tag[commit_rd_idx[k]] == commit_tag[k]);
        end
    end

    // ------------------------------------------------------------------
    // (4)#1 alloc / commit / flush -> entry[*].{busy, tag}
    //
    // ③ 写口次序: commit first -> a younger alloc on the same entry overrides
    // it -> flush squashes alloc and puts the whole table back to IDLE.  The
    // statement order below is exactly that priority: within the alloc loop
    // slot1 comes after slot0, so a same-cycle WAW on one entry keeps the
    // younger slot1 tag.  A younger alloc therefore beats a tag-matching commit
    // in the same cycle, while that commit still takes architectural effect
    // elsewhere.
    //
    // commit only writes busy <- 0; tag is left alone (zero payload width, so
    // this is not a value-carrying edge).  flush likewise clears busy only --
    // ③ says `busy ← 0` for every entry and says nothing about tag, and a
    // stale tag is harmless once busy is 0 because the next alloc rewrites it.
    // ------------------------------------------------------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int unsigned i = 0; i < NUM_GPR; i++) begin
                entry_busy[i] <= 1'b0;
                entry_tag[i]  <= '0;
            end
        end else begin
            // 1. commit clear ports
            for (int unsigned k = 0; k < ISSUE_WIDTH; k++) begin
                if (commit_clear[k]) begin
                    entry_busy[commit_rd_idx[k]] <= 1'b0;
                end
            end

            // 2. alloc write ports, oldest slot first so slot1 wins a same
            //    cycle WAW on one entry
            for (int unsigned s = 0; s < ISSUE_WIDTH; s++) begin
                if (alloc[s]) begin
                    entry_busy[alloc_rd_idx[s]] <= 1'b1;
                    entry_tag[alloc_rd_idx[s]]  <= self_tag[s];
                end
            end

            // 3. flush -- last, so it squashes the alloc above.  Entry 0 is
            //    skipped: it is hardwired and no event writes it.
            if (global_flush_late) begin
                for (int unsigned i = 1; i < NUM_GPR; i++) begin
                    entry_busy[i] <= 1'b0;
                end
            end
        end
    end

    // ------------------------------------------------------------------
    // (4)#1 entry[slot0/1.rs1/2_idx] -> tag / busy (4 read ports)
    //
    // Pure combinational reads of the registered state; there is no same-cycle
    // alloc forwarding here.  The slot0 -> slot1 in-flight dependency is
    // dependency_check's job (集成层 §1.1), not this table's.
    //
    // Address 0 reads the hardwired entry 0 as {busy:0, tag:0} rather than the
    // storage element, so the constant is driven, not left to propagate an X.
    // ------------------------------------------------------------------
    always_comb begin
        for (int unsigned s = 0; s < ISSUE_WIDTH; s++) begin
            for (int unsigned x = 1; x <= INT_SRC_PER_SLOT; x++) begin
                if (rs_idx[s][x] == '0) begin
                    tag[s][x]  = '0;
                    busy[s][x] = 1'b0;
                end else begin
                    tag[s][x]  = entry_tag[rs_idx[s][x]];
                    busy[s][x] = entry_busy[rs_idx[s][x]];
                end
            end
        end
    end

endmodule

`endif // INT_TAG_MAPPING_SV
