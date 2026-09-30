`ifndef OR_BE_TYPES_CHECK_SV
`define OR_BE_TYPES_CHECK_SV

// Elaboration-time checks that or_be_types_pkg still agrees with the frozen
// schema.  A package cannot host a generate block, so the checks live here.
//
// These are the frozen cross-stage widths.  If a field is added, removed or
// resized, one of these fires at elaboration rather than producing a payload
// that silently no longer matches the frozen schema.
module or_be_types_check;

    import or_be_types_pkg::*;
    import or_be_lsu_protocol_pkg::*;
    import exe_subop_pkg::*;
    import fe_be_protocol_pkg::*;

    // IB_Payload total logical width 294 bit (IB stores RAW; decoded products are generated on the dequeue side, see decoded_info_t)
    if (IB_PAYLOAD_W != 294) begin : gen_chk_1
        // 232 + inst_expanded 32 + rvc_ill 1 + opnd 29 (4x5-bit register numbers + 9 flag bits; RVC expansion and Operand_Extract are in FE).
        // Note: this module is not instantiated by any top; Verilator only elaborates be_tb_top, so these checks do not actually run.
        $error("IB_Payload width is %0d, expected 294", IB_PAYLOAD_W);
    end

    // **What IB stores is exactly what FE sends.** The fetch cycle is pure wiring; the field sets on both sides must match.
    // or_be_types_pkg cannot import fe_be_protocol_pkg (the dependency runs the other way), so
    // this can only be pinned here. A width mismatch means someone added something on the enqueue path.
    if (IB_PAYLOAD_W != FE_BE_INSTR_PLD_W) begin : gen_chk_1c
        $error("IB_Payload(%0d) != fe_be_instr_pld_t(%0d): FE -> IB should be pure wiring",
               IB_PAYLOAD_W, FE_BE_INSTR_PLD_W);
    end

    // decoded_info total logical width 112 bit
    if (DECODED_INFO_W != 112) begin : gen_chk_1b
        // The 8 use_* / *_is_fp bits are in the IB entry's opnd, not in decoded_info
        $error("decoded_info width is %0d, expected 112", DECODED_INFO_W);
    end

    // ISQ_Payload total logical width 556 bit
    if (ISQ_PAYLOAD_W != 556) begin : gen_chk_2
        $error("ISQ_Payload width is %0d, frozen at 556", ISQ_PAYLOAD_W);
    end

    if ($bits(full_decode_t) != FULL_DECODE_W) begin : gen_chk_3
        $error("full_decode width is %0d, frozen at 17",
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
    // 4-bit compare.
    if (ROB_PTR_W != 5) begin : gen_chk_8
        $error("ROB_PTR_W is %0d, frozen at 5", ROB_PTR_W);
    end

    // IB pointers are {loopbit, index[2:0]} over 8 entries.
    if (IB_PTR_W != 4) begin : gen_chk_9
        $error("IB_PTR_W is %0d, frozen at 4", IB_PTR_W);
    end

endmodule

`endif // OR_BE_TYPES_CHECK_SV
