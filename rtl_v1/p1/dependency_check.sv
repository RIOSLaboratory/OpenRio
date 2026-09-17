`ifndef DEPENDENCY_CHECK_SV
`define DEPENDENCY_CHECK_SV

/* verilator lint_off IMPORTSTAR */
import or_be_types_pkg::*;
/* verilator lint_on IMPORTSTAR */

// dependency_check -- the only place P1 compares tags
// (dependency_check微架构文档).
//
// (1) per-entry state          : 无 -- this module stores nothing.
// (2) state transition         : 无
// (3) condition                : 无
//                                ①②③ are all 「无」, so the module is purely
//                                combinational: no clk, no rst_n, no
//                                always_ff.  Every output is a function of
//                                this cycle's inputs only.
// (4) data path                : #1 self_tag / rd_write_enable
//                                #2 the six presence / class projections
//                                #3 the same-cycle slot0->slot1 RAW overlay,
//                                   the per-source query (INT / FP tag_mapping
//                                   read ports, 2 commit lanes, 4 bypass
//                                   lanes) and the 6-row first-hit-wins chain
//                                   that settles rsX_ready / rsX_wait_tag /
//                                   rs_data_sel_t, then slot_missed_wakeup
// (5) data structure           : 无 per-entry 存储
//
// 集成层.md §2.1 makes this module the *sole* producer of the operand select
// code: the assembly layer does no busy / tag compare of its own, and the
// sel_commit-over-sel_bypass priority is decided here, not there.
// `rs_data_sel_t` is 7-bit onehot0 -- all-zero only means "do not sample a
// source this cycle" and never substitutes for `rsX_ready`.
//
// Port naming follows doc ⑥ verbatim wherever ⑥ gives a legal identifier.
// The two tag_mapping read ports are the one exception: ⑥ writes them as the
// field paths `INT_tag_mapping[rsX_idx[s]].tag` / `.busy` and
// `FP_tag_mapping[fp_read_idx[x]].tag` / `.busy`, which both reduce to the
// bare names `tag` / `busy` -- two different ports, one name, and ⑥ offers no
// 「命名去重」 table.  The INT / FP prefixes below are this file's choice and
// are registered in dependency_check.portmap.
module dependency_check (
    // ------------------------------------------------------------------
    // in: 组合读 -- 队头 2 slot, broadcast from IB (集成层 §1.1)
    // ------------------------------------------------------------------
    // packed 2-bit（集成层 §2.5(4)）——与 IB 的输出同形。
    // 做成 unpacked 数组会与生产端类型不符，顶层接线是硬错。
    input  logic [ISSUE_WIDTH-1:0]  inst_valid,
    input  logic [REG_ADDR_W-1:0]   rd_idx                    [ISSUE_WIDTH],
    input  logic                    rd_is_fp                  [ISSUE_WIDTH],
    input  logic                    use_rd                    [ISSUE_WIDTH],
    input  logic                    is_serial                 [ISSUE_WIDTH],
    // **不门控的 FP opcode 判据**（decode 的 `dec_is_fp_opcode`），不是
    // `dec_info.is_fp_instruction`。它只用来产 fp0 / fp1 —— 即 dispatch 的双 FP
    // 阻塞判据，而那个判据必须与 FP_read_address_mux 的选择位同源，
    // 理由见该模块 ④#1。
    input  logic                    is_fp_opcode              [ISSUE_WIDTH],
    input  logic                    use_rs1                   [ISSUE_WIDTH],
    input  logic                    use_rs2                   [ISSUE_WIDTH],
    input  logic                    use_rs3                   [ISSUE_WIDTH],
    input  logic [REG_ADDR_W-1:0]   rs1_idx                   [ISSUE_WIDTH],
    input  logic [REG_ADDR_W-1:0]   rs2_idx                   [ISSUE_WIDTH],
    input  logic [REG_ADDR_W-1:0]   rs3_idx                   [ISSUE_WIDTH],
    input  logic                    rs1_is_fp                 [ISSUE_WIDTH],
    input  logic                    rs2_is_fp                 [ISSUE_WIDTH],
    input  logic                    rs3_is_fp                 [ISSUE_WIDTH],

    // in: 组合读 -- the alloc base, exported by CompletionScoreboard.  Name
    // kept as ⑥ asks (「信号名沿用」).
    input  logic [TAG_W-1:0]        Buffer_tail,

    // in: 组合读 -- INT_tag_mapping, 4 read ports, (s,x) ∈ {0,1}×{1,2}.
    // Shape frozen by 集成层 §2.5(1): (s,x) with x in {1,2}, base 1 not 0.
    input  logic [TAG_W-1:0]        INT_tag_mapping_tag       [ISSUE_WIDTH][1:INT_SRC_PER_SLOT],
    input  logic                    INT_tag_mapping_busy      [ISSUE_WIDTH][1:INT_SRC_PER_SLOT],

    // in: 组合读 -- FP_tag_mapping, 3 read ports, x ∈ {1,2,3}, no slot
    // dimension: the 3 FP read addresses already belong to the one slot that
    // FP_read_address_mux selected, so the port indexed x-1 IS slot s's value
    // whenever rsX_is_fp[s] holds (④#3 step 2).
    input  logic [TAG_W-1:0]        FP_tag_mapping_tag        [1:FP_READ_PORTS],
    input  logic                    FP_tag_mapping_busy       [1:FP_READ_PORTS],

    // in: 组合读 -- Static Info from CompletionScoreboard, 16 bit each
    input  logic [ROB_DEPTH-1:0]    scoreboard_valid_bits,
    input  logic [ROB_DEPTH-1:0]    scoreboard_exec_done_bits,

    // ------------------------------------------------------------------
    // in-event: commit (announce, 2 lane).  Tag only -- `data` is not taken.
    // ------------------------------------------------------------------
    input  logic                    commit_valid              [ISSUE_WIDTH],
    input  logic [TAG_W-1:0]        commit_tag                [ISSUE_WIDTH],

    // ------------------------------------------------------------------
    // in-event: bypass_publish (announce, 4 lane).  Tag only.
    // ------------------------------------------------------------------
    input  logic                    bypass_valid              [NUM_LANES],
    input  logic [TAG_W-1:0]        bypass_tag                [NUM_LANES],

    // ------------------------------------------------------------------
    // out-event: alloc / write / serial_set payload.  One port serves all
    // three -- ⑥ names the same `self_tag[s]` in each.  This module produces
    // the serial_set *payload* only; the trigger is dispatch_logic's.
    // ------------------------------------------------------------------
    output logic [TAG_W-1:0]        self_tag                  [ISSUE_WIDTH],
    output logic                    rd_write_enable           [ISSUE_WIDTH],

    // ------------------------------------------------------------------
    // out: 组合读 -> dispatch_logic
    // ------------------------------------------------------------------
    output logic                    slot0_present,
    output logic                    slot1_present,
    output logic                    serial0,
    output logic                    serial_inst,
    output logic                    fp0,
    output logic                    fp1,
    output logic                    slot_missed_wakeup        [ISSUE_WIDTH],

    // ------------------------------------------------------------------
    // out: 组合读 -> §2.1 装配.  Two unpacked dimensions in ⑥'s subscript
    // order [s][x]; x itself is the source number, x in {1,2,3} (§2.5(1)).
    // ------------------------------------------------------------------
    output logic                    rsX_ready                 [ISSUE_WIDTH][1:FP_READ_PORTS],
    output logic [TAG_W-1:0]        rsX_wait_tag              [ISSUE_WIDTH][1:FP_READ_PORTS],
    output logic [RS_DATA_SEL_W-1:0] rs_data_sel_t            [ISSUE_WIDTH][1:FP_READ_PORTS]
);

    // ------------------------------------------------------------------
    // Local shape aliases -- taken from the package so the cardinality has a
    // single source (集成层 §2.5(1)).  x is the source number itself and its
    // base is 1: there is no rs0.
    // ------------------------------------------------------------------
    localparam int NUM_SRC     = FP_READ_PORTS;      // x ∈ {1,2,3}
    localparam int NUM_INT_SRC = INT_SRC_PER_SLOT;   // x ∈ {1,2} -- rs3 never reads INT

    localparam int RS1   = 1;
    localparam int RS2   = 2;
    localparam int RS3   = 3;
    localparam int SLOT0 = 0;
    localparam int SLOT1 = 1;

    // rs_data_sel_t = {sel_arf, sel_commit[2], sel_bypass[4]} -- 7 bit,
    // onehot0 (④#3).  Widths come from the lane counts, never from a literal.
    localparam int SEL_BYPASS_LSB = 0;
    localparam int SEL_BYPASS_MSB = NUM_LANES - 1;                 // [3:0]
    localparam int SEL_COMMIT_LSB = NUM_LANES;
    localparam int SEL_COMMIT_MSB = NUM_LANES + ISSUE_WIDTH - 1;   // [5:4]
    localparam int SEL_ARF_BIT    = NUM_LANES + ISSUE_WIDTH;       // [6]

    // ④#3 step 3 row names, kept as an enum so the missed-wakeup gate can say
    // "row 6" instead of re-deriving the chain.
    typedef enum logic [2:0] {
        SRC_WAIT_OVERLAY  = 3'd0,   // row 1
        SRC_NONE          = 3'd1,   // row 2
        SRC_ARF           = 3'd2,   // row 3
        SRC_COMMIT        = 3'd3,   // row 4
        SRC_BYPASS        = 3'd4,   // row 5
        SRC_WAIT_PRODUCER = 3'd5    // row 6
    } src_kind_e;

    // ------------------------------------------------------------------
    // The three per-slot source triples, gathered once so that ④#3 can be
    // written as one (s,x) loop.  rs1/rs2/rs3 -> index 1/2/3.
    // ------------------------------------------------------------------
    logic                  use_rs   [ISSUE_WIDTH][1:NUM_SRC];
    logic [REG_ADDR_W-1:0] rs_idx   [ISSUE_WIDTH][1:NUM_SRC];
    logic                  rs_is_fp [ISSUE_WIDTH][1:NUM_SRC];

    always_comb begin
        for (int unsigned s = 0; s < ISSUE_WIDTH; s++) begin
            use_rs  [s][RS1] = use_rs1  [s];
            use_rs  [s][RS2] = use_rs2  [s];
            use_rs  [s][RS3] = use_rs3  [s];
            rs_idx  [s][RS1] = rs1_idx  [s];
            rs_idx  [s][RS2] = rs2_idx  [s];
            rs_idx  [s][RS3] = rs3_idx  [s];
            rs_is_fp[s][RS1] = rs1_is_fp[s];
            rs_is_fp[s][RS2] = rs2_is_fp[s];
            rs_is_fp[s][RS3] = rs3_is_fp[s];
        end
    end

    // ------------------------------------------------------------------
    // ④#1 self_tag / rd_write_enable.
    //
    // self_tag[s] = Buffer_tail + s, 4-bit mod16 -- the base is the SCB's
    // exported tail, and slot1 simply takes the next ring slot.  No admission
    // test happens here: whether the tag is really consumed is dispatch_logic's
    // accept[s], and the SCB latches on that.
    //
    // rd_write_enable suppresses INT x0 only.  FP f0 is an ordinary register
    // and is NOT suppressed.
    // ------------------------------------------------------------------
    always_comb begin
        for (int unsigned s = 0; s < ISSUE_WIDTH; s++) begin
            self_tag[s]        = Buffer_tail + TAG_W'(s);
            rd_write_enable[s] = use_rd[s]
                              && !((rd_idx[s] == '0) && !rd_is_fp[s]);
        end
    end

    // ------------------------------------------------------------------
    // ④#2 the six projections.  Straight copies -- ⑥ does not qualify
    // serial / fp by inst_valid, so neither does this.  fp0 / fp1 feed the
    // downstream dual-FP block test (dispatch_logic ④).
    // ------------------------------------------------------------------
    always_comb begin
        slot0_present = inst_valid[SLOT0];
        slot1_present = inst_valid[SLOT1];
        serial0       = is_serial[SLOT0];
        serial_inst   = is_serial[SLOT0] || is_serial[SLOT1];
        fp0           = is_fp_opcode[SLOT0];
        fp1           = is_fp_opcode[SLOT1];
    end

    // ------------------------------------------------------------------
    // ④#3 step 1: the same-cycle RAW overlay, evaluated for slot1 only.
    //
    // slot0's destination is allocated this very cycle, so no tag_mapping /
    // commit / bypass query can see it.  RAW only: a WAR or WAW pair keeps the
    // ordinary write-port rules and does not enter here.
    // ------------------------------------------------------------------
    logic slot1_dep_hit [1:NUM_SRC];

    always_comb begin
        for (int unsigned x = 1; x <= NUM_SRC; x++) begin
            slot1_dep_hit[x] = slot0_present
                            && rd_write_enable[SLOT0]
                            && use_rs[SLOT1][x]
                            && (rs_idx  [SLOT1][x] == rd_idx  [SLOT0])
                            && (rs_is_fp[SLOT1][x] == rd_is_fp[SLOT0]);
        end
    end

    // ------------------------------------------------------------------
    // ④#3 step 2: the source query.
    //
    // The INT side has read ports for x ∈ {1,2} only.  rs3 never reads INT
    // (上游契约 use_rs3[s] ⇒ rs3_is_fp[s]), so x = 3 is forced onto the FP
    // side and the absent INT port is pinned busy -- a contract violation then
    // degrades into WAIT_PRODUCER instead of reading a port that is not there.
    // ------------------------------------------------------------------
    logic [TAG_W-1:0] int_tag  [ISSUE_WIDTH][1:NUM_SRC];
    logic             int_busy [ISSUE_WIDTH][1:NUM_SRC];
    logic             take_fp  [ISSUE_WIDTH][1:NUM_SRC];

    logic [TAG_W-1:0] producer_tag [ISSUE_WIDTH][1:NUM_SRC];
    logic             arf_ready    [ISSUE_WIDTH][1:NUM_SRC];

    always_comb begin
        for (int unsigned s = 0; s < ISSUE_WIDTH; s++) begin
            for (int unsigned x = 1; x <= NUM_SRC; x++) begin
                if (x <= NUM_INT_SRC) begin
                    int_tag [s][x] = INT_tag_mapping_tag [s][x];
                    int_busy[s][x] = INT_tag_mapping_busy[s][x];
                end else begin
                    int_tag [s][x] = '0;
                    int_busy[s][x] = 1'b1;
                end

                take_fp[s][x] = rs_is_fp[s][x] || (x > NUM_INT_SRC);

                producer_tag[s][x] = take_fp[s][x] ? FP_tag_mapping_tag[x]
                                                   : int_tag[s][x];
                arf_ready[s][x]    = take_fp[s][x] ? !FP_tag_mapping_busy[x]
                                                   : !int_busy[s][x];
            end
        end
    end

    // commit_match / commit_lane and bypass_match / bypass_lane, produced as
    // onehot0 lane selects directly.  A tag completes once, so at most one
    // lane can carry it; the lowest lane index is taken first so that the code
    // stays onehot0 even if a duplicate ever appears.
    logic                   commit_match  [ISSUE_WIDTH][1:NUM_SRC];
    logic [ISSUE_WIDTH-1:0] commit_lane   [ISSUE_WIDTH][1:NUM_SRC];
    logic                   bypass_match  [ISSUE_WIDTH][1:NUM_SRC];
    logic [NUM_LANES-1:0]   bypass_lane   [ISSUE_WIDTH][1:NUM_SRC];

    always_comb begin
        for (int unsigned s = 0; s < ISSUE_WIDTH; s++) begin
            for (int unsigned x = 1; x <= NUM_SRC; x++) begin
                commit_match[s][x] = 1'b0;
                commit_lane [s][x] = '0;
                bypass_match[s][x] = 1'b0;
                bypass_lane [s][x] = '0;

                for (int unsigned c = 0; c < ISSUE_WIDTH; c++) begin
                    if (!commit_match[s][x]
                        && commit_valid[c]
                        && (commit_tag[c] == producer_tag[s][x])) begin
                        commit_match[s][x]    = 1'b1;
                        commit_lane [s][x][c] = 1'b1;
                    end
                end

                for (int unsigned b = 0; b < NUM_LANES; b++) begin
                    if (!bypass_match[s][x]
                        && bypass_valid[b]
                        && (bypass_tag[b] == producer_tag[s][x])) begin
                        bypass_match[s][x]    = 1'b1;
                        bypass_lane [s][x][b] = 1'b1;
                    end
                end
            end
        end
    end

    // ------------------------------------------------------------------
    // ④#3 step 3: one chain per (s,x), first hit from the top wins.
    //
    //   1 WAIT_OVERLAY   s==1 ∧ slot1_dep_hit[x]   0  self_tag[0]   全零
    //   2 NONE           !use_rsX[s]               1  0             全零
    //   3 ARF            arf_ready[s][x]           1  producer_tag  sel_arf
    //   4 COMMIT         commit_match              1  producer_tag  sel_commit
    //   5 BYPASS         bypass_match              1  producer_tag  sel_bypass
    //   6 WAIT_PRODUCER  其余                      0  producer_tag  全零
    //
    // Row 6 is the default the chain falls through to, so it is written as the
    // pre-assignment.  Rows 4 and 5 are ordered here and only here: 集成层
    // §2.1 forbids the assembly layer from re-deciding commit-vs-bypass.
    // ------------------------------------------------------------------
    src_kind_e source_kind [ISSUE_WIDTH][1:NUM_SRC];

    always_comb begin
        for (int unsigned s = 0; s < ISSUE_WIDTH; s++) begin
            for (int unsigned x = 1; x <= NUM_SRC; x++) begin
                // row 6
                source_kind  [s][x] = SRC_WAIT_PRODUCER;
                rsX_ready    [s][x] = 1'b0;
                rsX_wait_tag [s][x] = producer_tag[s][x];
                rs_data_sel_t[s][x] = '0;

                if ((s == SLOT1) && slot1_dep_hit[x]) begin
                    // row 1 -- wait on the tag slot0 is being handed this
                    // cycle; it is not in the Scoreboard yet.
                    source_kind [s][x] = SRC_WAIT_OVERLAY;
                    rsX_ready   [s][x] = 1'b0;
                    rsX_wait_tag[s][x] = self_tag[SLOT0];
                end else if (!use_rs[s][x]) begin
                    // row 2
                    source_kind [s][x] = SRC_NONE;
                    rsX_ready   [s][x] = 1'b1;
                    rsX_wait_tag[s][x] = '0;
                end else if (arf_ready[s][x]) begin
                    // row 3
                    source_kind [s][x] = SRC_ARF;
                    rsX_ready   [s][x] = 1'b1;
                    rs_data_sel_t[s][x][SEL_ARF_BIT] = 1'b1;
                end else if (commit_match[s][x]) begin
                    // row 4
                    source_kind [s][x] = SRC_COMMIT;
                    rsX_ready   [s][x] = 1'b1;
                    rs_data_sel_t[s][x][SEL_COMMIT_MSB:SEL_COMMIT_LSB] =
                        commit_lane[s][x];
                end else if (bypass_match[s][x]) begin
                    // row 5
                    source_kind [s][x] = SRC_BYPASS;
                    rsX_ready   [s][x] = 1'b1;
                    rs_data_sel_t[s][x][SEL_BYPASS_MSB:SEL_BYPASS_LSB] =
                        bypass_lane[s][x];
                end
            end
        end
    end

    // ------------------------------------------------------------------
    // ④#3 slot_missed_wakeup.
    //
    // Only row 6 is inspected: row 1 waits on a tag the Scoreboard has not
    // been given yet, and rows 3-5 are already READY.  A producer that is both
    // live and exec_done can no longer republish its bypass, so a consumer
    // parked on it would never wake -- that is what dispatch_logic must not
    // let into an ISQ.
    // ------------------------------------------------------------------
    always_comb begin
        for (int unsigned s = 0; s < ISSUE_WIDTH; s++) begin
            slot_missed_wakeup[s] = 1'b0;
            for (int unsigned x = 1; x <= NUM_SRC; x++) begin
                if ((source_kind[s][x] == SRC_WAIT_PRODUCER)
                    && scoreboard_valid_bits    [rsX_wait_tag[s][x]]
                    && scoreboard_exec_done_bits[rsX_wait_tag[s][x]]) begin
                    slot_missed_wakeup[s] = 1'b1;
                end
            end
        end
    end

endmodule

`endif // DEPENDENCY_CHECK_SV
