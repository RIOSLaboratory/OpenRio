`ifndef DECODE_SV
`define DECODE_SV

/* verilator lint_off IMPORTSTAR */
import or_be_types_pkg::*;
import or_be_config_pkg::*;
import exe_subop_pkg::*;
/* verilator lint_on IMPORTSTAR */

// decode -- pure combinational IB queue head -> decoded_info, 2 lanes.
//
// (1) per-entry state          : none
// (2) state transition         : none
// (3) condition                : none -- this module produces no fire
//                                judgement.  It sits **after** IB; whether
//                                the head dequeues is decided by
//                                dispatch_logic's ib_dequeue.
// (4) data path                : two steps -- field slice, classify --
//                                then per field.
//                                (RVC expansion is not here, see below.)
// (5) data structure           : none -- no storage of its own.
//
// **This module sits after IB (dequeue side).**
//
//       FE(rvc_expand + operand_extract) --(pure wiring)--> IB(294: RAW + inst_expanded + rvc_ill + opnd)
//         ─┬─> inst_expanded / rvc_ill --> decode --dec_info(112)--> dispatch stage
//          └─> opnd (register numbers + source/dest qualifier bits) --> register read (backend_top glue logic #1)
//
// Reason: **the fetch cycle cannot even fit one RVC expander** (measured), so
// any decode-related logic in the BE must sit after IB; the expander is in
// FE's own pipeline stage, FE -> IB is pure wiring, and each IB entry is 294 bits.
//
// No coupling between the two lanes: lane n only reads lane n's inputs.
// **This module does not touch `fe_valid`** -- it goes directly from FE to
// IB, and IB's admission chain and accepted_slot back-pressure contract have
// nothing to do with this module.
//
// **This module does no RVC expansion.** Expansion and Operand_Extract are
// both in FE (or_fe_pkg::rvc_expand / operand_extract), and the results are
// enqueued with the IB entry: this module's `ib_inst32` is the head's
// `inst_expanded`, and `ib_rvc_illegal` is the head's `rvc_ill`.
// Register numbers and use_* / *_is_fp / is_fp_opcode are in the head's
// `opnd`, wired directly by backend_top glue logic #1 to register read and
// dependency_check, not through this module; the BE has no expander, and no
// "20-bit slice of inst32" address branch.
// `inst16` (for compressed sub-code recoding) is the low half-word of
// the head's `inst_bits`, sliced directly.
//
// The rule "an illegal instruction's mtval must be the encoding actually
// present in the program" takes its simplest form: **IB stores RAW itself**,
// isq_payload_assembly reads `inst_bits` directly with no rebuild; ISQ_Payload and
// the tval logic of the four FUs pass it straight through.
//
// Fetch exceptions are judged here.  FE's `fetch_excp_vld` reaches this
// module through IB; the other two wires (cause / tval) are not needed by this
// module, consumers read them directly from the head.  The only decision this
// module makes about it: a fetch fault is forced onto ILLEGAL's routing, because "no encoding was
// read" and "the encoding read is not a legal instruction" need the same
// downstream shape -- G0/ALU0, no sources, no destination, no store -- and differ
// only in the cause the ALU reports.  Without that, the garbage in `ib_inst32`
// would be decoded on its face and could route a nonexistent instruction to the
// LSU or the FPU.
//
// -------------------------------------------------------------------------
// Where the encoding rules come from
// -------------------------------------------------------------------------
// The authority for the *value* of every SUBOP_* is the frozen exe_subop_pkg,
// and the frozen package is finer-grained than a plain opcode -> high_fixed
// table in five places.  Each is
// implemented below the way the frozen constants require, because a subop that
// does not compare equal to its SUBOP_* constant is invisible to every
// is_g0_* / is_g1_* / is_g2_* / is_g3_* classifier downstream:
//
//   a. funct3 is 3'b000 for LUI / AUIPC / JAL (inst[14:12] there is immediate
//      payload, not a funct3) and for every rm-variable FP form -- the package
//      header says "inst[14:12] when fixed, 3'b000 for variable rm".
//   b. OP-IMM shifts keep funct6 (RV64 shamt is 6 bit) and OP-IMM32 shifts keep
//      funct7; the remaining OP-IMM / OP-IMM32 forms have no fixed high field.
//      SUBOP_SRAI vs SUBOP_SRLI differ only in this.
//   c. SYSTEM takes funct12 only when funct3 == 000 (ECALL / EBREAK / MRET).
//      The CSR forms carry a *variable* csr address in inst[31:20] and their
//      constants use hi_none().
//   d. OP-FP splits: unary forms (inst[24:20] is an opcode extension) keep
//      {funct7, rs2} = inst[31:20]; two-source forms keep {funct7, 5'b0}.
//      SUBOP_FCVT_WU_S and SUBOP_FCVT_W_S differ only in that rs2 field.
//   e. FMA keeps only fmt = inst[26:25] ({5'b0, fmt, 5'b0}); rs3 = inst[31:27]
//      is a register operand and is zeroed.  SUBOP_FMADD_D vs SUBOP_FMADD_S
//      differ only in fmt.
//
// The same applies to the RVC alias tags: many SUBOP_C_* rows share {op, funct3} and are told
// apart *only* by hi_c() -- SUBOP_C_ADDI is tag 1 against SUBOP_C_NOP's tag 0,
// the op=01/funct3=100 forms run 0..15 (nine base ALU forms 0..8, the Zcb
// forms 9..15), the five op=10/funct3=100 forms run 0..4, and the five Zcb
// op=00/funct3=100 loads / stores run 0..4.  Emitting a constant zero there would encode C.ADD as
// SUBOP_C_JR and route an add to the branch unit.  The tags below are read off
// the frozen package.
module decode (
    // ---------------------------------------------------------------------
    // in-event: broadcast -- the raw FE bus payload, per lane n in {0,1}
    // ---------------------------------------------------------------------
    input  logic [31:0]            ib_inst32          [ISSUE_WIDTH],
    input  logic [15:0]            ib_inst16          [ISSUE_WIDTH],
    input  logic                   ib_is_compressed   [ISSUE_WIDTH],
    // The FE expander's verdict "this compressed encoding itself is illegal" (the IB entry's rvc_ill).  This module does not expand,
    // so ill_rvc can only be read back from the head.  ib_inst32 is the IB entry's inst_expanded (FE's expanded word).
    input  logic                   ib_rvc_illegal     [ISSUE_WIDTH],

    // The front end could not fetch this PC.  `ib_inst32` / `ib_inst16`
    // are then meaningless -- there is no encoding, so nothing downstream may
    // decode it, route it or read a source from it.
    input  logic                   ib_fetch_excp_vld  [ISSUE_WIDTH],

    // ---------------------------------------------------------------------
    // out: combinational reads
    // ---------------------------------------------------------------------
    // **Decode products only; no pc / pred / fetch_excp / register indices / source/dest qualifier bits.**
    // RVC expansion and Operand_Extract are both in FE;
    // register numbers, use_* / *_is_fp, is_fp_opcode dequeue with the IB entry's opnd, not through this module;
    // this module has no is_fp_opcode output (dependency_check's double-FP block and
    // FP_read_address_mux's select bit take the IB head's opnd.is_fp_opcode).
    // The full_decode.illegal this module produces is also what backend_top glue logic #1 gates opnd on.
    output decoded_info_t          dec_info           [ISSUE_WIDTH]
);

    // ---------------------------------------------------------------------
    // Local encoding constants that the frozen package does not name.
    // ---------------------------------------------------------------------
    // A compressed encoding that has no SUBOP_C_* constant (the Zcmop no-op
    // and the reserved Zcb rows; the 12 Zcb instructions have tags).  Every real alias tag is
    // in 0..15 (exe_subop_pkg), so this value cannot collide with one; it lands outside every
    // is_g*_* set and therefore becomes illegal (ill_unsupported).
    localparam logic [11:0] RVC_TAG_UNMAPPED = 12'hFFF;

    // ---------------------------------------------------------------------
    // OP-FP shape helpers, keyed on funct7 = inst[31:25].
    // ---------------------------------------------------------------------
    // Unary: inst[24:20] is an opcode extension, not a second source.  Exactly
    // the funct7 values the frozen package encodes with hi_f7_rs2().
    function automatic logic opfp_unary(input logic [6:0] f7);
        return f7 inside {
            7'b0100000, 7'b0100001,   // FCVT.S.D            / FCVT.D.S
            7'b0101100, 7'b0101101,   // FSQRT.S             / FSQRT.D
            7'b1100000, 7'b1100001,   // FCVT.W|WU|L|LU.S    / .D
            7'b1101000, 7'b1101001,   // FCVT.S.W|WU|L|LU    / FCVT.D.*
            7'b1110000, 7'b1110001,   // FMV.X.W , FCLASS.S  / FMV.X.D, FCLASS.D
            7'b1111000, 7'b1111001    // FMV.W.X             / FMV.D.X
        };
    endfunction

    // inst[14:12] is a rounding mode rather than a fixed funct3.  The frozen
    // constants for these forms carry F3_RMVAR (3'b000).
    function automatic logic opfp_rm_variable(input logic [6:0] f7);
        return f7 inside {
            7'b0000000, 7'b0000001,   // FADD.S  / FADD.D
            7'b0000100, 7'b0000101,   // FSUB.S  / FSUB.D
            7'b0001000, 7'b0001001,   // FMUL.S  / FMUL.D
            7'b0001100, 7'b0001101,   // FDIV.S  / FDIV.D
            7'b0101100, 7'b0101101,   // FSQRT.S / FSQRT.D
            7'b0100000, 7'b0100001,   // FCVT.S.D / FCVT.D.S
            7'b1100000, 7'b1100001,   // FCVT int <- fp
            7'b1101000, 7'b1101001    // FCVT fp  <- int
        };
    endfunction

    // rs1 is an integer register only on the int -> fp moves and conversions.
    function automatic logic opfp_rs1_is_int(input logic [6:0] f7);
        return f7 inside {7'b1101000, 7'b1101001, 7'b1111000, 7'b1111001};
    endfunction

    // rd is an integer register on fp -> int conversions, FMV.X.*, FCLASS and
    // the three comparisons.
    function automatic logic opfp_rd_is_int(input logic [6:0] f7);
        return f7 inside {
            7'b1100000, 7'b1100001,   // FCVT.W|WU|L|LU.S / .D
            7'b1110000, 7'b1110001,   // FMV.X.W , FCLASS.S / FMV.X.D, FCLASS.D
            7'b1010000, 7'b1010001    // FEQ / FLT / FLE  .S / .D
        };
    endfunction

    // ---------------------------------------------------------------------
    // "FP arithmetic instruction" for the reserved-rounding-mode check.
    // ---------------------------------------------------------------------
    // The arithmetic class and the whole conversion class.  Out: FSGNJ* /
    // FMIN / FMAX / FEQ / FLT / FLE / FCLASS / FMV.* whose inst[14:12] means
    // something other than a rounding mode, and FP load / store whose funct3
    // is an access width -- checking those would turn legal instructions
    // illegal.  exe_subop_pkg has no uses_rm helper, so the set is spelled out
    // here; it is the same set dispatch_logic uses for its dynamic
    // rm == DYN check, and the two checks are the two halves of one rule
    // (static reserved value here, architectural state there).
    function automatic logic subop_uses_rm(input backend_exe_subop_t s);
        return s inside {
            SUBOP_FADD_S, SUBOP_FSUB_S, SUBOP_FMUL_S, SUBOP_FDIV_S, SUBOP_FSQRT_S,
            SUBOP_FADD_D, SUBOP_FSUB_D, SUBOP_FMUL_D, SUBOP_FDIV_D, SUBOP_FSQRT_D,
            SUBOP_FMADD_S, SUBOP_FMSUB_S, SUBOP_FNMSUB_S, SUBOP_FNMADD_S,
            SUBOP_FMADD_D, SUBOP_FMSUB_D, SUBOP_FNMSUB_D, SUBOP_FNMADD_D,
            SUBOP_FCVT_W_S, SUBOP_FCVT_WU_S, SUBOP_FCVT_L_S, SUBOP_FCVT_LU_S,
            SUBOP_FCVT_W_D, SUBOP_FCVT_WU_D, SUBOP_FCVT_L_D, SUBOP_FCVT_LU_D,
            SUBOP_FCVT_S_W, SUBOP_FCVT_S_WU, SUBOP_FCVT_S_L, SUBOP_FCVT_S_LU,
            SUBOP_FCVT_D_W, SUBOP_FCVT_D_WU, SUBOP_FCVT_D_L, SUBOP_FCVT_D_LU,
            SUBOP_FCVT_S_D, SUBOP_FCVT_D_S
        };
    endfunction

    // ---------------------------------------------------------------------
    // Does the recoded subop belong to any supported class?
    // ---------------------------------------------------------------------
    // is_g3_subop() is the union of the LSU, atomic and fence sets, so the
    // eight names below cover every is_g0_* / is_g1_* / is_g2_* / is_g3_*
    // classifier in the frozen package.  SUBOP_INVALID is in none of them.
    function automatic logic subop_supported(input backend_exe_subop_t s);
        return is_g0_alu0_subop(s) || is_g1_alu1_subop(s)
            || is_g0_bru_subop(s)  || is_g0_div_subop(s)
            || is_g0_csr_subop(s)  || is_g0_sys_subop(s)
            || is_g1_mul_subop(s)  || is_g2_fpu_subop(s)
            || is_g3_subop(s);
    endfunction

    // ---------------------------------------------------------------------
    // The compressed alias tag, read off the frozen SUBOP_C_* table.
    // ---------------------------------------------------------------------
    // Taken from the *original* 16 bits: the tag exists precisely because the
    // expansion is not enough to tell two compressed rows apart from
    // {op, funct3} alone.
    function automatic logic [11:0] rvc_alias_tag(input logic [15:0] c);
        logic [4:0] c_rd;    // inst[11:7] field of the compressed word
        logic [4:0] c_rs2;   // inst[6:2]
        c_rd  = c[11:7];
        c_rs2 = c[6:2];

        unique case (c[1:0])
            // ---- quadrant 0: every row is alone under its funct3 -----------
            2'b00: begin
                // funct3 == 100 is Zcb (exe_subop_pkg): C.LBU 0, C.LHU 1,
                // C.LH 2, C.SB 3, C.SH 4; c[6] == 1 on C.SH is reserved.
                if (c[15:13] != 3'b100) return 12'h000;
                unique case (c[12:10])
                    3'b000:  return 12'h000;                          // C.LBU
                    3'b001:  return c[6] ? 12'h002 : 12'h001;         // C.LH / C.LHU
                    3'b010:  return 12'h003;                          // C.SB
                    3'b011:  return c[6] ? RVC_TAG_UNMAPPED : 12'h004; // C.SH
                    default: return RVC_TAG_UNMAPPED;
                endcase
            end

            // ---- quadrant 1 ------------------------------------------------
            2'b01: begin
                unique case (c[15:13])
                    // C.NOP (rd == 0) vs C.ADDI
                    3'b000: return (c_rd == 5'd0) ? 12'h000 : 12'h001;
                    // C.ADDI16SP (rd == 2) vs C.LUI.  The Zcmop rows
                    // (c[12] == 0, c[6:2] == 0, c[7] == 1) expand to a no-op
                    // but have no SUBOP_C_*, and they are not C.LUI.
                    3'b011: begin
                        if ((c[12] == 1'b0) && (c[6:2] == 5'd0) && (c[7] == 1'b1))
                            return RVC_TAG_UNMAPPED;
                        else
                            return (c_rd == 5'd2) ? 12'h000 : 12'h001;
                    end
                    // nine ALU rows share funct3 == 100
                    3'b100: begin
                        unique case (c[11:10])
                            2'b00:   return 12'h000;                  // C.SRLI
                            2'b01:   return 12'h001;                  // C.SRAI
                            2'b10:   return 12'h002;                  // C.ANDI
                            default: begin
                                unique case ({c[12], c[6:5]})
                                    3'b000:  return 12'h003;          // C.SUB
                                    3'b001:  return 12'h004;          // C.XOR
                                    3'b010:  return 12'h005;          // C.OR
                                    3'b011:  return 12'h006;          // C.AND
                                    3'b100:  return 12'h007;          // C.SUBW
                                    3'b101:  return 12'h008;          // C.ADDW
                                    // Zcb (exe_subop_pkg)
                                    3'b110:  return 12'h00f;          // C.MUL
                                    default: begin
                                        unique case (c[4:2])
                                            3'b000:  return 12'h009;  // C.ZEXT.B
                                            3'b001:  return 12'h00a;  // C.SEXT.B
                                            3'b010:  return 12'h00b;  // C.ZEXT.H
                                            3'b011:  return 12'h00c;  // C.SEXT.H
                                            3'b100:  return 12'h00d;  // C.ZEXT.W
                                            3'b101:  return 12'h00e;  // C.NOT
                                            default: return RVC_TAG_UNMAPPED;
                                        endcase
                                    end
                                endcase
                            end
                        endcase
                    end
                    // C.ADDIW / C.LI / C.J / C.BEQZ / C.BNEZ
                    default: return 12'h000;
                endcase
            end

            // ---- quadrant 2 ------------------------------------------------
            2'b10: begin
                if (c[15:13] == 3'b100) begin
                    if (c[12] == 1'b0)
                        return (c_rs2 == 5'd0) ? 12'h000              // C.JR
                                               : 12'h001;             // C.MV
                    else if (c_rs2 == 5'd0)
                        return (c_rd == 5'd0) ? 12'h002               // C.EBREAK
                                              : 12'h003;              // C.JALR
                    else
                        return 12'h004;                               // C.ADD
                end else begin
                    return 12'h000;
                end
            end

            // c[1:0] == 11 is not a compressed encoding at all.
            default: return RVC_TAG_UNMAPPED;
        endcase
    endfunction

    // =====================================================================
    // Per lane.  No coupling of any kind between the two lanes -- nothing below crosses n.
    // =====================================================================
    genvar n;
    generate
        for (n = 0; n < ISSUE_WIDTH; n++) begin : g_lane

            // -------------------------------------------------------------
            // Step 1 -- RVC expansion (**done in FE**).
            // -------------------------------------------------------------
            // Expansion is in FE (or_fe_pkg::rvc_expand); the result is enqueued
            // with the IB entry as inst_expanded, the original half-word is in inst_bits.
            // This module therefore only has to take the head's two forms:
            // `inst32` (= inst_expanded) for field slicing, `inst16`
            // (= inst_bits[15:0]) for compressed sub-code recoding.
            //
            // Reason: the decode branch in the dequeue cycle does not chain an
            // expander, so that cycle is shorter.
            logic [31:0] inst32;
            logic [15:0] inst16;

            assign inst32 = ib_inst32[n];
            assign inst16 = ib_inst16[n];

            // -------------------------------------------------------------
            // Step 2 -- fixed slices of inst32.
            // -------------------------------------------------------------
            logic [6:0]  opcode;
            logic [2:0]  funct3;
            logic [6:0]  funct7;
            logic [4:0]  funct5;
            logic [11:0] funct12;
            logic [4:0]  f_rs1;
            logic [4:0]  f_rs2;

            assign opcode  = inst32[6:0];
            assign funct3  = inst32[14:12];
            assign funct7  = inst32[31:25];
            assign funct5  = inst32[31:27];
            assign funct12 = inst32[31:20];
            assign f_rs1   = inst32[19:15];
            assign f_rs2   = inst32[24:20];

            // The five sign-extended formats plus the two unsigned
            // fields.  Everything is extended to the full 64 bit here;
            // ISQ_Payload and every FU consume imm_data as "already extended".
            logic signed [XLEN-1:0] imm_i;
            logic signed [XLEN-1:0] imm_s;
            logic signed [XLEN-1:0] imm_b;
            logic signed [XLEN-1:0] imm_u;
            logic signed [XLEN-1:0] imm_j;
            logic signed [XLEN-1:0] imm_shamt;
            logic signed [XLEN-1:0] imm_csr_uimm;

            assign imm_i = {{52{inst32[31]}}, inst32[31:20]};
            assign imm_s = {{52{inst32[31]}}, inst32[31:25], inst32[11:7]};
            assign imm_b = {{51{inst32[31]}}, inst32[31], inst32[7],
                            inst32[30:25], inst32[11:8], 1'b0};
            assign imm_u = {{32{inst32[31]}}, inst32[31:12], 12'b0};
            assign imm_j = {{43{inst32[31]}}, inst32[31], inst32[19:12],
                            inst32[20], inst32[30:21], 1'b0};
            // Shift amount: low 6 bits of the I-type.  A shift amount is an unsigned
            // count, so it is zero-extended, not sign-extended -- sign
            // extension would turn every shamt >= 32 into a huge negative.
            // The same slice serves the W shifts: their inst[25] is 0 in every
            // legal encoding, so the low 6 bits equal {1'b0, shamt[4:0]}.
            assign imm_shamt    = {{(XLEN-6){1'b0}}, inst32[25:20]};
            // The CSR immediate forms put a 5-bit *unsigned* uimm in the rs1
            // field and it rides the imm channel.
            assign imm_csr_uimm = {{(XLEN-5){1'b0}}, inst32[19:15]};

            // -------------------------------------------------------------
            // exe_subop, a mechanical recode, not a table lookup.
            // -------------------------------------------------------------
            logic [2:0]         subop_funct3;
            logic [11:0]        high_fixed;
            backend_exe_subop_t subop_raw;

            always_comb begin
                // (a) LUI / AUIPC / JAL have no funct3 field, and the
                //     rm-variable FP forms carry F3_RMVAR.
                case (opcode)
                    OPCODE_LUI,
                    OPCODE_AUIPC,
                    OPCODE_JAL:      subop_funct3 = F3_000;
                    OPCODE_MADD,
                    OPCODE_MSUB,
                    OPCODE_NMSUB,
                    OPCODE_NMADD:    subop_funct3 = F3_RMVAR;
                    OPCODE_OP_FP:    subop_funct3 = opfp_rm_variable(funct7)
                                                  ? F3_RMVAR : funct3;
                    default:         subop_funct3 = funct3;
                endcase

                // (b) high_fixed, aligned to inst[31:20] with every variable
                //     operand / immediate bit zeroed.
                case (opcode)
                    // R-type: funct7, rs2 is an operand.        hi_funct7()
                    OPCODE_OP,
                    OPCODE_OP32:     high_fixed = {funct7, 5'b0};

                    // RV64 shifts keep funct6 (shamt is 6 bit); the other
                    // OP-IMM forms have a variable 12-bit immediate. hi_funct6()
                    OPCODE_OP_IMM:   high_fixed = (funct3 inside {F3_001, F3_101})
                                                ? {inst32[31:26], 6'b0} : 12'h000;

                    // W shifts keep funct7 (shamt is 5 bit).     hi_funct7()
                    OPCODE_OP_IMM32: high_fixed = (funct3 inside {F3_001, F3_101})
                                                ? {funct7, 5'b0} : 12'h000;

                    // funct5, aq/rl forced to 00 and rs2 zeroed. hi_amo()
                    OPCODE_AMO:      high_fixed = {funct5, 7'b0};

                    // funct12 only for ECALL / EBREAK / MRET; the CSR forms
                    // hold a variable csr address there.        hi_funct12()
                    // SFENCE.VMA is the **only** one in SYSTEM/f3=000 keyed
                    // on funct7: its rs1(VA) / rs2(ASID) are real register
                    // fields, and going through funct12 would give every rs2
                    // a different sub-code.  The rest (ECALL / EBREAK /
                    // MRET / SRET / WFI) still use funct12.     hi_funct7()
                    OPCODE_SYSTEM:   high_fixed =
                        (funct3 != F3_000)         ? 12'h000        :
                        (funct7 == 7'b0001001)     ? {funct7, 5'b0} :
                                                     funct12;

                    // Unary OP-FP keeps {funct7, rs2};          hi_f7_rs2()
                    // two-source OP-FP zeroes rs2.              hi_funct7()
                    OPCODE_OP_FP:    high_fixed = opfp_unary(funct7)
                                                ? {funct7, f_rs2} : {funct7, 5'b0};

                    // R4: only fmt survives, rs3 and rs2 are operands.
                    //                                           hi_r4_fmt()
                    OPCODE_MADD,
                    OPCODE_MSUB,
                    OPCODE_NMSUB,
                    OPCODE_NMADD:    high_fixed = {5'b0, inst32[26:25], 5'b0};

                    // LOAD / LOAD-FP / STORE / STORE-FP / BRANCH / JALR / JAL
                    // / LUI / AUIPC / MISC-MEM: nothing fixed above bit 19.
                    default:         high_fixed = 12'h000;       // hi_none()
                endcase

                // (c) assemble.  RVC keeps the *original* op / funct3.
                if (ib_is_compressed[n]) begin
                    subop_raw = {SUBOP_FMT_RVC, 5'b0, inst16[1:0], inst16[15:13],
                                 rvc_alias_tag(inst16)};
                end else begin
                    subop_raw = {SUBOP_FMT_INST32, opcode, subop_funct3, high_fixed};
                end
            end

            // -------------------------------------------------------------
            // Immediates.  The source / dest qualifier bits (use_* /
            // *_is_fp / has_rd) are produced by FE's Operand_Extract
            // (or_fe_pkg::operand_extract) and dequeue with the IB entry's
            // opnd; the illegal gating is in backend_top glue logic #1.
            logic d_imm_valid;
            logic signed [XLEN-1:0] d_imm_data;
            logic is_csr_form;

            // SYSTEM funct3 000 is ECALL / EBREAK / MRET, 100 is unassigned.
            assign is_csr_form = (opcode == OPCODE_SYSTEM)
                              && (funct3 != F3_000) && (funct3 != F3_100);

            always_comb begin
                d_imm_valid = 1'b0;
                d_imm_data  = '0;
                case (opcode)
                    OPCODE_LOAD,
                    OPCODE_LOAD_FP,
                    OPCODE_JALR: begin
                        d_imm_valid = 1'b1;
                        d_imm_data  = imm_i;
                    end
                    OPCODE_OP_IMM,
                    OPCODE_OP_IMM32: begin
                        d_imm_valid = 1'b1;
                        d_imm_data  = (funct3 inside {F3_001, F3_101})
                                    ? imm_shamt : imm_i;
                    end
                    OPCODE_AUIPC,
                    OPCODE_LUI: begin
                        d_imm_valid = 1'b1;
                        d_imm_data  = imm_u;
                    end
                    OPCODE_JAL: begin
                        d_imm_valid = 1'b1;
                        d_imm_data  = imm_j;
                    end
                    OPCODE_STORE,
                    OPCODE_STORE_FP: begin
                        d_imm_valid = 1'b1;
                        d_imm_data  = imm_s;
                    end
                    OPCODE_BRANCH: begin
                        d_imm_valid = 1'b1;
                        d_imm_data  = imm_b;
                    end
                    // CSR immediate forms put the 5-bit uimm in the rs1 field (register forms have no immediate)
                    OPCODE_SYSTEM: begin
                        if (is_csr_form && !(funct3 inside {F3_001, F3_010, F3_011})) begin
                            d_imm_valid = 1'b1;
                            d_imm_data  = imm_csr_uimm;
                        end
                    end
                    default: begin
                        // no immediate
                    end
                endcase
            end

            // -------------------------------------------------------------
            // Classification bits that come from exe_subop.
            // -------------------------------------------------------------
            logic d_is_store;
            logic d_is_serial;
            logic d_is_fp_instruction;

            // "plain store only" -- AMO and SC have a store side in the LSU
            // protocol but are not plain stores.
            assign d_is_store = is_g3_store_subop(subop_raw);

            // Serial: CSR (register and immediate forms), MRET / SRET,
            // FENCE / FENCE.I / SFENCE.VMA, and all 22 atomics.
            // ECALL / EBREAK / WFI are not in it.
            //
            // **SRET must be here, listed with MRET.**  The reference model's
            // `SpecCore::isCsrInsn` counts CSRRW…CSRRCI / MRET / **SRET** / DRET
            // together as CSR instructions, and enforces "a CSR requires an
            // empty ROB, and nothing else issues while a CSR is in flight".
            // SRET must mirror MRET everywhere, **including this one**; if it
            // is missed, the model reports
            // `issue: in-flight CSR insn blocks non-CSR issue` on the first
            // instruction after SRET and then decode_and_issue fails.
            //
            // SFENCE.VMA belongs to the fence class: FENCE / FENCE.I are
            // already serial, it is the same class of memory-ordering
            // instruction, and there is no basis for not serializing it.
            assign d_is_serial = is_g0_csr_subop(subop_raw)
                              || (subop_raw == SUBOP_MRET)
                              || (subop_raw == SUBOP_SRET)
                              || (subop_raw == SUBOP_SFENCE_VMA)
                              || is_g3_fence_subop(subop_raw)
                              || is_g3_atomic_subop(subop_raw);

            // Used by dispatch_logic: this must cover FLW / FLD / FSW / FSD as
            // well, because FS == Off makes the FP loads and stores illegal
            // too and rd_is_fp would miss the stores.
            assign d_is_fp_instruction = is_g2_fpu_subop(subop_raw)
                                      || is_g3_fp_load_subop(subop_raw)
                                      || is_g3_fp_store_subop(subop_raw);

            // -------------------------------------------------------------
            // full_decode, and the one illegal decision in the design.
            // -------------------------------------------------------------
            logic       d_uses_rm;
            rm_e        d_rm;
            logic       d_csr_write_intent;
            logic       is_fp_opcode;
            logic       ill_rvc;
            logic       ill_ext_a;
            logic       ill_ext_c;
            logic       ill_ext_fd;
            logic       ill_unsupported;
            logic       ill_rm;
            logic       d_illegal;
            // Illegal (bad encoding) and fetch fault (no encoding at
            // all) need the *same* downstream shape -- G0/ALU0, no sources,
            // no destination -- and differ only in the cause the ALU reports.
            logic       d_no_encoding;

            assign d_uses_rm = subop_uses_rm(subop_raw);
            // rm is meaningful only on the FP arithmetic / conversion forms;
            // everything else reports RM_RNE.  dispatch overwrites it with
            // effective_rm when it is DYN.
            assign d_rm = d_uses_rm ? rm_e'(funct3) : RM_RNE;

            // csr_write_intent: CSRRW / CSRRWI always write;
            // CSRRS / CSRRC write when rs1 is not x0 -- a *register number*
            // test, which is why the backend cannot derive this bit -- and
            // CSRRSI / CSRRCI when uimm is not 0.  Both tests read the same
            // inst[19:15] field, so one expression serves both forms.
            assign d_csr_write_intent = is_csr_form
                                     && ((funct3 inside {F3_001, F3_101})
                                         || (f_rs1 != 5'd0));

            // Any opcode the F/D extension owns, taken after expansion so that
            // C.FLD / C.FSD / C.FLDSP / C.FSDSP are covered by their LOAD-FP /
            // STORE-FP expansions.
            assign is_fp_opcode = opcode inside {OPCODE_OP_FP, OPCODE_MADD,
                                                 OPCODE_MSUB, OPCODE_NMSUB,
                                                 OPCODE_NMADD, OPCODE_LOAD_FP,
                                                 OPCODE_STORE_FP};

            // The ungated is_fp_opcode is provided by the IB head's opnd;
            // here it is only used for illegal check 2 below.

            // 1. RVC expansion failed
            assign ill_rvc         = ib_rvc_illegal[n];
            // 2. extension not built (or_be_config_pkg -- never a
            //    module parameter).  OPCODE_AMO covers LR / SC / AMO alike.
            assign ill_ext_a       = !ENABLE_A  && (opcode == OPCODE_AMO);
            assign ill_ext_c       = !ENABLE_C  && ib_is_compressed[n];
            assign ill_ext_fd      = !ENABLE_FD && is_fp_opcode;
            // 3. the recode landed outside every supported class
            assign ill_unsupported = !subop_supported(subop_raw);
            // 4. statically reserved rounding mode on an FP arithmetic form.
            //    The FS == Off / DYN half of this check is architectural state
            //    and belongs to dispatch_logic; both feed the same G0 ILLEGAL
            //    path.
            assign ill_rm          = d_uses_rm && rm_is_reserved(rm_e'(funct3));

            assign d_no_encoding = d_illegal || ib_fetch_excp_vld[n];

            assign d_illegal = ill_rvc || ill_ext_a || ill_ext_c || ill_ext_fd
                            || ill_unsupported || ill_rm;

            // -------------------------------------------------------------
            // decoded_info assembly.
            // -------------------------------------------------------------
            // On illegal every decode **decision** is forced to a determinate
            // zero: exe_subop = SUBOP_INVALID, the fallback value.
            // use_rs* / use_rd are not in dec_info:
            // backend_top glue logic #1 clears the IB head opnd's
            // use_* / *_is_fp with this module's full_decode.illegal, so
            // use_rs* = 0 still makes the ILLEGAL sub-op immediately issuable in
            // ISQ_G0 and use_rd = 0 still keeps it out of every tag_mapping.
            //
            // **Register indices are not here, and are not gated by this
            // zero.**  They are fields of the IB entry's `opnd` (FE
            // Operand_Extract), taken by backend_top glue logic #1 directly
            // from the IB head and sent to register read.  If they were also
            // chained behind d_no_encoding, the address path would have to
            // wait for `subop_supported()` -- that is the whole decoder, and
            // "register read starts early" would no longer hold.  Safety is
            // guaranteed on the consumer side, checked one by one, see the
            // comment on `decoded_info_t` in or_be_types_pkg.
            always_comb begin
                dec_info[n] = '0;

                // A fetch fault reuses ILLEGAL's routing verbatim.
                // dispatch_logic sends illegal_effective to ROUTE_BRU,
                // i.e. GRP_G0 with FU index 0 = ALU0, the gate below leaves
                // the store bit at zero and backend_top glue logic #1 (keyed on this
                // illegal bit) zeroes every source / destination bit --
                // which is exactly right for an instruction whose encoding
                // was never read.  alu_simple reports the *fetch* cause
                // rather than cause 2 because fetch_excp_vld outranks
                // illegal there.
                dec_info[n].full_decode.illegal = d_no_encoding;

                if (!d_no_encoding) begin
                    dec_info[n].is_serial         = d_is_serial;
                    dec_info[n].is_fp_instruction = d_is_fp_instruction;

                    dec_info[n].is_store   = d_is_store;
                    dec_info[n].mem_funct3 = funct3;

                    dec_info[n].imm_valid = d_imm_valid;
                    // No residue when the instruction has no immediate.
                    dec_info[n].imm_data  = d_imm_valid ? d_imm_data : '0;

                    dec_info[n].exe_subop = subop_raw;

                    dec_info[n].full_decode.csr_write_intent = d_csr_write_intent;
                    dec_info[n].full_decode.rm               = d_rm;
                    dec_info[n].full_decode.csr_addr         = is_csr_form
                                                             ? funct12 : 12'h000;
                end
            end
        end
    endgenerate

endmodule

`endif // DECODE_SV
