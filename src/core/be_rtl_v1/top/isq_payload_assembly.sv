`ifndef ISQ_PAYLOAD_ASSEMBLY_SV
`define ISQ_PAYLOAD_ASSEMBLY_SV

/* verilator lint_off IMPORTSTAR */
import or_be_types_pkg::*;
/* verilator lint_on IMPORTSTAR */

// isq_payload_assembly -- implementation of the `ISQ_Payload` assembly.
//
// (1) per-entry state          : none
// (2) state transition         : none
// (3) condition                : none
// (4) data path                : for each (slot s, source x), select one source
//                                datum by the onehot0 rs_data_sel_t; each of the two
//                                candidate slots assembles one complete ISQ_Payload
// (5) data structure           : none -- holds no state
//
// This module is the only piece of "glue logic" in the whole library (its output is not any module's out-event,
// and it holds no state). Hierarchically it belongs to the top: it is the only combinational glue logic allowed at the top.
// It is split into its own file only to keep backend_top pure wiring (coverable by the "no dangling ports" check)
// and to let the assembly logic be linted on its own.
//
// Boundary discipline:
//   * This layer does **no busy / tag compare at all**. The select code is generated solely by dependency_check,
//     and the priority between sel_commit and sel_bypass is implemented there too.
//     Here we only decode; no recomputing, no reordering.
//   * ARF address indexing is **already done by the ARF modules themselves**: INT_ARF's output is ARF[s][x],
//     FP_ARF's is ARF[x] (frozen shape). This layer only picks one of the two,
//     and does not index with rsX_idx / fp_read_idx.
//   * **The only assembly-side override** is full_decode.rm <- dispatch_logic.effective_rm;
//     the other 14 bits (csr_write_intent / illegal / csr_addr) are taken as-is from dec_info
//     (decode's full_decode).
//   * Both payloads are **fully assembled**, regardless of which slot is finally accepted --
//     accept semantics are expressed on p1_ISQ_input_mux's select_payload, not here.
//
// No clk / rst_n: purely combinational, stateless, and not on any flush broadcast list.
module isq_payload_assembly (
    // ------------------------------------------------------------------
    // in: combinational read -- IB head two slots.
    // The fields are imm_valid/imm_data/pc/inst_bits/is_compressed/
    // pred_taken/pred_target_pc/is_store/mem_funct3/rd_is_fp/rs1/2/3_is_fp/
    // exe_subop/full_decode. They come from three places: pc / inst_bits / is_compressed /
    // pred_taken / pred_target_pc / fetch_excp_* are read directly from this ib_payload_t;
    // imm_* / is_store / mem_funct3 / exe_subop / full_decode come from dec_info below;
    // rs1/2_is_fp / rd_is_fp come from the gated opnd below. The port is the whole struct,
    // and the port name follows IB's head_IB_Payload.
    // ------------------------------------------------------------------
    input  ib_payload_t              head_IB_Payload [ISSUE_WIDTH],
    // IB stores only RAW; decoded products come in directly from decode on the dequeue side.
    // Both are same-cycle and same-source: dec_info[s] is the decode result of head_IB_Payload[s].
    input  decoded_info_t            dec_info        [ISSUE_WIDTH],
    // rs*_is_fp / rd_is_fp are not in dec_info; take the **gated** version of the IB head opnd
    // (backend_top glue logic #1, cleared on illegal / fetch exception).
    input  ib_operand_info_t         opnd            [ISSUE_WIDTH],

    // ------------------------------------------------------------------
    // in: combinational read -- dependency_check.
    // The two unpacked dims follow the index order [s][x]; x itself is the source number, x ∈ {1,2,3},
    // base 1, no rs0.
    // ------------------------------------------------------------------
    input  logic                     rsX_ready       [ISSUE_WIDTH][1:FP_READ_PORTS],
    input  logic [TAG_W-1:0]         rsX_wait_tag    [ISSUE_WIDTH][1:FP_READ_PORTS],
    input  logic [RS_DATA_SEL_W-1:0] rs_data_sel_t   [ISSUE_WIDTH][1:FP_READ_PORTS],
    input  logic [TAG_W-1:0]         self_tag        [ISSUE_WIDTH],

    // ------------------------------------------------------------------
    // in: combinational read -- two synonymous ARF read-outs. The same-named signal `ARF` comes from two different modules,
    // both can be valid in the same cycle and cannot be physically merged, so they get INT_ / FP_ prefixes.
    // Shapes match their respective sources cell by cell: INT is (s,x) four ports, FP is three ports with no slot dim.
    // ------------------------------------------------------------------
    input  logic [XLEN-1:0]          INT_ARF         [ISSUE_WIDTH][1:INT_SRC_PER_SLOT],
    input  logic [XLEN-1:0]          FP_ARF          [1:FP_READ_PORTS],

    // ------------------------------------------------------------------
    // in: combinational read -- Buffer's two head read-outs (commit lane 0/1, no compaction,
    // lane c is always head c). Data only: the hit decision is already in dependency_check.
    // ------------------------------------------------------------------
    input  logic [XLEN-1:0]          commit_data     [ISSUE_WIDTH],

    // ------------------------------------------------------------------
    // in-event: bypass_publish (announce, 4 lane). The four lanes are aggregated by the top from
    // the completions of p3_arbiter_G0/G1 and G2/G3. Likewise data only;
    // bypass_valid / bypass_tag do not enter this layer.
    // ------------------------------------------------------------------
    input  logic [XLEN-1:0]          bypass_data     [NUM_LANES],

    // ------------------------------------------------------------------
    // in: combinational read -- dispatch_logic.
    // slot_FU_Group is the FU index within the group, not the group number; effective_rm overrides the payload's
    // three rm bits, consumed only by G2.
    // ------------------------------------------------------------------
    input  logic [FU_GROUP_W-1:0]    slot_FU_Group   [ISSUE_WIDTH],
    input  rm_e                      effective_rm    [ISSUE_WIDTH],

    // ------------------------------------------------------------------
    // out: combinational read -> 4 p1_ISQ_input_mux (port name follows its slot_payload)
    // ------------------------------------------------------------------
    output isq_payload_t             slot_payload    [ISSUE_WIDTH]
);

    // ------------------------------------------------------------------
    // Source number: the index itself, base 1. x ∈ {1,2} have INT read ports,
    // x ∈ {1,2,3} have FP read ports.
    // ------------------------------------------------------------------
    localparam int RS1 = 1;
    localparam int RS2 = 2;
    localparam int RS3 = 3;

    // ------------------------------------------------------------------
    // Bit order of rs_data_sel_t (frozen):
    //
    //     [6]    sel_arf
    //     [5:4]  sel_commit[1:0]      bit4 = commit lane 0
    //     [3:0]  sel_bypass[3:0]      bit0 = bypass lane 0
    //
    // i.e. {sel_arf, sel_commit[1:0], sel_bypass[3:0]} read directly MSB→LSB;
    // within both sub-fields, low bits map to low-numbered lanes. Positions are derived from lane counts, not literals:
    // ISSUE_WIDTH on the commit side, NUM_LANES on the bypass side, identical word for word to the
    // derivation on the dependency_check generating side.
    // ------------------------------------------------------------------
    localparam int SEL_BYPASS_LSB = 0;
    localparam int SEL_BYPASS_MSB = NUM_LANES - 1;                  // [3:0]
    localparam int SEL_COMMIT_LSB = NUM_LANES;
    localparam int SEL_COMMIT_MSB = NUM_LANES + ISSUE_WIDTH - 1;    // [5:4]
    localparam int SEL_ARF_BIT    = NUM_LANES + ISSUE_WIDTH;        // [6]

    // sel_arf must land on the MSB, otherwise this layer and the generating side disagree and silently pick the wrong lane.
    if (SEL_ARF_BIT != RS_DATA_SEL_W - 1) begin : gen_chk_sel_layout
        $error("rs_data_sel_t layout: sel_arf at bit %0d but RS_DATA_SEL_W is %0d",
               SEL_ARF_BIT, RS_DATA_SEL_W);
    end

    // ------------------------------------------------------------------
    // The three decoded sub-fields, one per (s,x).
    // ------------------------------------------------------------------
    logic                       sel_arf    [ISSUE_WIDTH][1:FP_READ_PORTS];
    logic [ISSUE_WIDTH-1:0]     sel_commit [ISSUE_WIDTH][1:FP_READ_PORTS];
    logic [NUM_LANES-1:0]       sel_bypass [ISSUE_WIDTH][1:FP_READ_PORTS];

    always_comb begin
        for (int unsigned s = 0; s < ISSUE_WIDTH; s++) begin
            for (int unsigned x = 1; x <= FP_READ_PORTS; x++) begin
                sel_arf   [s][x] = rs_data_sel_t[s][x][SEL_ARF_BIT];
                sel_commit[s][x] = rs_data_sel_t[s][x][SEL_COMMIT_MSB:SEL_COMMIT_LSB];
                sel_bypass[s][x] = rs_data_sel_t[s][x][SEL_BYPASS_MSB:SEL_BYPASS_LSB];
            end
        end
    end

    // ------------------------------------------------------------------
    // The sel_arf path: rsX_is_fp[s] ? FP_ARF[x] : INT_ARF[s][x]
    //
    // The address side is already done -- what the two ARFs deliver are their read ports' values; this layer only picks
    // between "the INT read-out for this source number" and "the FP read-out for this source number".
    // The FP side has no slot dim (frozen shape): the three FP read addresses already belong to
    // the one slot selected by FP_read_address_mux, so when rsX_is_fp[s] holds
    // the port at index x is slot s's value.
    //
    // x = 3 goes FP only: rs3 never selects INT_ARF (upstream contract use_rs3[s] => rs3_is_fp[s]),
    // and INT_ARF only has the two ports x ∈ {1,2}, so there is no second path to pick at all. If the contract is ever broken,
    // what is given here is still the FP read-out, not an out-of-bounds index -- this layer does not check twice.
    // ------------------------------------------------------------------
    logic rs_is_fp [ISSUE_WIDTH][1:INT_SRC_PER_SLOT];

    always_comb begin
        for (int unsigned s = 0; s < ISSUE_WIDTH; s++) begin
            rs_is_fp[s][RS1] = opnd[s].rs1_is_fp;
            rs_is_fp[s][RS2] = opnd[s].rs2_is_fp;
        end
    end

    logic [XLEN-1:0] arf_data [ISSUE_WIDTH][1:FP_READ_PORTS];

    always_comb begin
        for (int unsigned s = 0; s < ISSUE_WIDTH; s++) begin
            for (int unsigned x = 1; x <= INT_SRC_PER_SLOT; x++) begin
                arf_data[s][x] = rs_is_fp[s][x] ? FP_ARF[x] : INT_ARF[s][x];
            end
            for (int unsigned x = INT_SRC_PER_SLOT + 1; x <= FP_READ_PORTS; x++) begin
                arf_data[s][x] = FP_ARF[x];
            end
        end
    end

    // ------------------------------------------------------------------
    // rsX_data[s][x] -- onehot0 select
    //
    //     sel_arf       -> arf_data[s][x]
    //     sel_commit[c] -> commit_data[c]
    //     sel_bypass[b] -> bypass_data[b]
    //     all zero      -> 0 (this source is not sampled this cycle)
    //
    // Written as an order-independent AND-OR select, not an if/else priority chain: priority has already been
    // decided by dependency_check (this layer does no busy / tag compare at all);
    // writing another chain here would implement the same checker twice. The select code being strictly onehot0 is
    // guaranteed by the rule that the same tag hit on multiple lanes takes the lowest number.
    // ------------------------------------------------------------------
    logic [XLEN-1:0] rsX_data [ISSUE_WIDTH][1:FP_READ_PORTS];

    always_comb begin
        for (int unsigned s = 0; s < ISSUE_WIDTH; s++) begin
            for (int unsigned x = 1; x <= FP_READ_PORTS; x++) begin
                rsX_data[s][x] = sel_arf[s][x] ? arf_data[s][x] : '0;
                for (int unsigned c = 0; c < ISSUE_WIDTH; c++) begin
                    rsX_data[s][x] |= sel_commit[s][x][c] ? commit_data[c] : '0;
                end
                for (int unsigned b = 0; b < NUM_LANES; b++) begin
                    rsX_data[s][x] |= sel_bypass[s][x][b] ? bypass_data[b] : '0;
                end
            end
        end
    end

    // ------------------------------------------------------------------
    // The only assembly-side override: full_decode.rm <- effective_rm[s]
    //
    // The other 14 bits ([16] csr_write_intent / [15] illegal / [11:0] csr_addr)
    // are taken as-is from dec_info[s].full_decode. Written field by field rather than a whole copy then patch, so that "only these three bits are overridden"
    // can be counted at a glance in the code; the named assignment pattern also forces, at elaboration,
    // coverage of every member of full_decode_t.
    // effective_rm = (rm == DYN) ? frm : rm is fixed in the dispatch cycle and consumed only by G2.
    // ------------------------------------------------------------------
    full_decode_t payload_full_decode [ISSUE_WIDTH];

    always_comb begin
        for (int unsigned s = 0; s < ISSUE_WIDTH; s++) begin
            payload_full_decode[s] = '{
                csr_write_intent : dec_info[s].full_decode.csr_write_intent,
                illegal          : dec_info[s].full_decode.illegal,
                rm               : effective_rm[s],
                csr_addr         : dec_info[s].full_decode.csr_addr
            };
        end
    end

    // ------------------------------------------------------------------
    // Two complete payloads
    //
    // The payload schema lands below row by row, not a field missed. Named assignment
    // pattern rather than per-field assignment: SV requires a named pattern to cover every member of the struct,
    // so missing one is an elaboration error, not a silent 0.
    //
    // Both are filled unconditionally, regardless of accept / select_payload -- this layer has no "which
    // slot is accepted" information, and does not need it.
    //
    // Not in the payload: slot_ISQGroup (already decoded into select_payload;
    // the mux instance itself represents the target group), rd_idx / use_rd / rd_write_enable
    // (writeback is addressed by tag_out; destination register info already entered the SCB in the alloc cycle).
    // req_property is not in either; it is generated combinationally from exe_subop at the G3 issue boundary.
    // ------------------------------------------------------------------
    always_comb begin
        for (int unsigned s = 0; s < ISSUE_WIDTH; s++) begin
            slot_payload[s] = '{
                // operands -- data selected in this section, ready / wait_tag from dependency_check
                rs1_data       : rsX_data    [s][RS1],
                rs2_data       : rsX_data    [s][RS2],
                rs3_data       : rsX_data    [s][RS3],
                rs1_ready      : rsX_ready   [s][RS1],
                rs2_ready      : rsX_ready   [s][RS2],
                rs3_ready      : rsX_ready   [s][RS3],
                rs1_wait_tag   : rsX_wait_tag[s][RS1],
                rs2_wait_tag   : rsX_wait_tag[s][RS2],
                rs3_wait_tag   : rsX_wait_tag[s][RS3],
                // routing
                self_tag       : self_tag[s],
                fu_group       : slot_FU_Group[s],
                // immediate -- imm_data already sign-extended by decode
                imm_valid      : dec_info[s].imm_valid,
                imm_data       : dec_info[s].imm_data,
                // instruction identity + prediction
                pc             : head_IB_Payload[s].pc,
                // IB stores RAW, so read directly. An illegal instruction's mtval must be
                // **the encoding that actually exists in the program**; the expanded result is not something in the program.
                inst_bits      : head_IB_Payload[s].inst_bits,
                is_compressed  : head_IB_Payload[s].is_compressed,
                pred_taken     : head_IB_Payload[s].pred_taken,
                pred_target_pc : head_IB_Payload[s].pred_target_pc,
                // memory sideband -- rd_is_fp only lets G3 tell integer from FP loads of the same width
                is_store       : dec_info[s].is_store,
                mem_funct3     : dec_info[s].mem_funct3,
                rd_is_fp       : opnd[s].rd_is_fp,
                // decode results -- full_decode's three rm bits have been overridden
                exe_subop      : dec_info[s].exe_subop,
                full_decode    : payload_full_decode[s],
                // fetch exception -- passed through as-is. decode (illegal set to 1) and backend_top
                // glue logic #1 (which clears opnd's use_* / *_is_fp accordingly) have already forced this into
                // the ILLEGAL shape (G0/ALU0, no source, no destination); this layer need not check again.
                fetch_excp_vld   : head_IB_Payload[s].fetch_excp_vld,
                fetch_excp_cause : head_IB_Payload[s].fetch_excp_cause,
                fetch_excp_tval  : head_IB_Payload[s].fetch_excp_tval
            };
        end
    end

endmodule

`endif // ISQ_PAYLOAD_ASSEMBLY_SV
