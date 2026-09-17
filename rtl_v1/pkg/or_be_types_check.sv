`ifndef OR_BE_TYPES_CHECK_SV
`define OR_BE_TYPES_CHECK_SV

// Elaboration-time checks that or_be_types_pkg still agrees with the frozen
// schema.  A package cannot host a generate block, so the checks live here.
//
// These are the numbers 集成层.md §2.2 froze.  If a field is added, removed or
// resized, one of these fires at elaboration rather than producing a payload
// that silently no longer matches the document.
module or_be_types_check;

    import or_be_types_pkg::*;
    import or_be_lsu_protocol_pkg::*;
    import exe_subop_pkg::*;
    import fe_be_protocol_pkg::*;

    // 集成层.md §2.2: IB_Payload 总逻辑宽度 232 bit
    // （2026-08-26 由 372 改为 232：IB 改存 RAW，140 位译码产物挪到出队侧
    //   —— 120 位进 decoded_info_t，20 位的寄存器索引不再存。）
    if (IB_PAYLOAD_W != 232) begin : gen_chk_1
        $error("IB_Payload width is %0d, 集成层.md §2.2 freezes 232", IB_PAYLOAD_W);
    end

    // **IB 存的就是 FE 送的。** 取指拍是纯连线，两边字段集必须一致。
    // or_be_types_pkg 不能 import fe_be_protocol_pkg（依赖方向是反的），所以
    // 这条只能在这里钉。宽度不等就是有人往入队路径上加了东西。
    if (IB_PAYLOAD_W != FE_BE_INSTR_PLD_W) begin : gen_chk_1c
        $error("IB_Payload(%0d) != fe_be_instr_pld_t(%0d): FE -> IB 应为纯连线",
               IB_PAYLOAD_W, FE_BE_INSTR_PLD_W);
    end

    // 集成层.md §2.2: decoded_info 总逻辑宽度 120 bit
    if (DECODED_INFO_W != 120) begin : gen_chk_1b
        $error("decoded_info width is %0d, 集成层.md §2.2 freezes 120", DECODED_INFO_W);
    end

    // 集成层.md §2.2: ISQ_Payload 总逻辑宽度 556 bit
    if (ISQ_PAYLOAD_W != 556) begin : gen_chk_2
        $error("ISQ_Payload width is %0d, 集成层.md §2.2 freezes 556", ISQ_PAYLOAD_W);
    end

    if ($bits(full_decode_t) != FULL_DECODE_W) begin : gen_chk_3
        $error("full_decode width is %0d, 集成层.md §2.2 freezes 17",
               $bits(full_decode_t));
    end

    // exe_subop identity comes from the frozen package, not from here.
    if (EXE_SUBOP_W != 24) begin : gen_chk_4
        $error("exe_subop width is %0d, exe_subop_pkg freezes 24", EXE_SUBOP_W);
    end

    // A tag is a ROB slot number; the LSU contract froze it at 4.
    if (TAG_W != 4) begin : gen_chk_5
        $error("TAG_W is %0d, or_be_lsu_protocol_pkg freezes LSU_TAG_W = 4", TAG_W);
    end

    if (ROB_DEPTH != 16) begin : gen_chk_6
        $error("ROB_DEPTH is %0d, architecture baseline is 16", ROB_DEPTH);
    end

    // The payload assembly assumes an architectural register fits an LSU data
    // word.  If these ever diverge, rs1_data/rs2_data plumbing is wrong.
    if (!XLEN_MATCHES_LSU_DATA_W) begin : gen_chk_7
        $error("XLEN (%0d) != LSU_DATA_W (%0d)", XLEN, LSU_DATA_W);
    end

    // SCB pointers are 5-bit {loopbit, index[3:0]} and must not degrade to a
    // 4-bit compare (CompletionScoreboard ④#1).
    if (ROB_PTR_W != 5) begin : gen_chk_8
        $error("ROB_PTR_W is %0d, CompletionScoreboard ⑤ freezes 5", ROB_PTR_W);
    end

    // IB pointers are {loopbit, index[2:0]} over 8 entries (IB微架构文档 ⑤).
    if (IB_PTR_W != 4) begin : gen_chk_9
        $error("IB_PTR_W is %0d, IB微架构文档 ⑤ freezes 4", IB_PTR_W);
    end

endmodule

`endif // OR_BE_TYPES_CHECK_SV
