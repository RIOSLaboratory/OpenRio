`ifndef DECODE_SV
`define DECODE_SV

/* verilator lint_off IMPORTSTAR */
import or_be_types_pkg::*;
import or_be_config_pkg::*;
import exe_subop_pkg::*;
/* verilator lint_on IMPORTSTAR */

// decode -- pure combinational IB 队头 -> decoded_info, 2 lanes
// (decode微架构文档).
//
// (1) per-entry state          : none
// (2) state transition         : none
// (3) condition                : none -- this module produces no fire
//                                judgement.  它现在在 IB **之后**，队头出不出
//                                队是 dispatch_logic 的 ib_dequeue 说了算。
// (4) data path                : ④#1 两步 -- field slice、classify --
//                                然后 ④#2..#6 per field。
//                                （RVC 展开已经不在这里，见下。）
// (5) data structure           : none -- no storage of its own.
//
// **2026-08-26：本模块从 IB 之前挪到了 IB 之后。**
//
//     旧：FE --raw--> decode --IB_Payload(372)--> IB --全译码字段--> 派遣级
//     新：FE --raw(纯连线)--> IB(232, RAW) --> rvc_expand ─┬─> decode --dec_info(120)--> 派遣级
//                                                         └─> inst32 的 20 位切片 --> 寄存器读
//
// 理由与形态选择见 spec/微架构文档/P1译码位置重构分析.md（**形态 A**）。两条：
//   1. 旧顺序不是设计选择，是 `IB_Payload` 先被冻结成 372 位全译码的后果。
//   2. **取指拍连一块 RVC 展开都放不下**（2026-08-26 实测），所以任何与译码相关的
//      逻辑都必须在 IB 之后——包括展开器本身。IB 每条从 372 位瘦到 232 位。
//
// 两条 lane 之间无耦合：lane n 只读 lane n 的输入。**本模块不碰 `fe_valid`**——
// 它现在由 FE 直连 IB，IB 的准入链与 accepted_slot 回压契约完全不变
// （这一条在挪之前就成立：decode 那时也只是把 fe_valid 直通）。
//
// **本模块不再自己做 RVC 展开。** 展开住在 `rvc_expand`，与本模块同在出队侧、
// 排在本模块前面。它的输出 `inst32` 同时喂两条并行分支：本模块读整条，
// 而地址支只读它的 20 位固定切片（backend_top 胶水#1）——那 20 位的逻辑锥就是
// 展开器里的寄存器选择 mux 树，浅；立即数与 opcode 那些深锥不在地址路径上。
// `inst16`（压缩子码重编码用，④#5）是队头 `inst_bits` 的低半字，直接切。
//
// 「非法指令的 mtval 必须是程序里真实存在的那个编码」这条规矩不仅没变，
// 而且回到了最简的形式：**IB 存的就是 RAW**，§2.1 装配直读 `inst_bits`，
// 不需要重建。ISQ_Payload 与四个 FU 的 tval 逻辑一行都没动。
//
// ④#7 fetch exceptions 仍然在这里判。FE 的 `fetch_excp_vld` 经 IB 递到本模块，
// 另外两根（cause / tval）本模块不需要，消费者直接从队头读。本模块对它做的唯一
// 决定：a fetch fault is forced onto ILLEGAL's routing, because "no encoding was
// read" and "the encoding read is not a legal instruction" need the same
// downstream shape -- G0/ALU0, no sources, no destination, no store -- and differ
// only in the cause the ALU reports.  Without that, the garbage in `ib_inst32`
// would be decoded on its face and could route a nonexistent instruction to the
// LSU or the FPU.
//
// -------------------------------------------------------------------------
// Where the encoding rules come from
// -------------------------------------------------------------------------
// ④#5 gives the exe_subop shape and an opcode -> high_fixed table, but the
// authority for the *value* of every SUBOP_* is the frozen exe_subop_pkg, and
// the frozen package is finer-grained than that table in five places.  Each is
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
// The same applies to the RVC alias tags: ④#5 says the compressed high_fixed
// is always zero, but nine SUBOP_C_* pairs share {op, funct3} and are told
// apart *only* by hi_c() -- SUBOP_C_ADDI is tag 1 against SUBOP_C_NOP's tag 0,
// the nine op=01/funct3=100 ALU forms run 0..8, and the five op=10/funct3=100
// forms run 0..4.  Emitting a constant zero there would encode C.ADD as
// SUBOP_C_JR and route an add to the branch unit.  The tags below are read off
// the frozen package.
module decode (
    // ---------------------------------------------------------------------
    // in-event: broadcast -- the raw FE bus payload, per lane n in {0,1}
    // ---------------------------------------------------------------------
    input  logic [31:0]            ib_inst32          [ISSUE_WIDTH],
    input  logic [15:0]            ib_inst16          [ISSUE_WIDTH],
    input  logic                   ib_is_compressed   [ISSUE_WIDTH],
    // rvc_expand 判出的「这条压缩编码本身非法」。本模块不再自己展开，
    // 所以 ④#6 的 ill_rvc 只能从队头读回来。
    input  logic                   ib_rvc_illegal     [ISSUE_WIDTH],

    // ④#7: the front end could not fetch this PC.  `ib_inst32` / `ib_inst16`
    // are then meaningless -- there is no encoding, so nothing downstream may
    // decode it, route it or read a source from it.
    input  logic                   ib_fetch_excp_vld  [ISSUE_WIDTH],

    // ---------------------------------------------------------------------
    // out: combinational reads
    // ---------------------------------------------------------------------
    // **只有译码产物，没有 pc / pred / fetch_excp / 寄存器索引。**
    // 前三类是 RAW 字段，消费者直接从 IB 队头读；索引是 `inst32` 的固定切片，
    // 由 backend_top 的胶水#1 直接切出来送寄存器读——不经过本模块，这正是
    // 「寄存器读提前起跑」的全部内容。
    output decoded_info_t          dec_info           [ISSUE_WIDTH],

    // **不门控的 FP opcode 判据，刻意不放进 dec_info。**
    //
    // `dec_info.is_fp_instruction` 是**门控后**的（非法 / 取指故障 ⇒ 0），它回答
    // 「这条指令合法且是 FP」；本口回答的是「这条编码的 opcode 属于 F/D」，
    // 只吃 `ib_inst32[6:0]`，**与 subop_raw 和 d_no_encoding 都无关**。
    //
    // 为什么要单独引出来：FP 侧只有 3 个读口要覆盖 2 slot × 3 源，所以地址级有一次
    // 仲裁（FP_read_address_mux）。那个选择位若用门控版，FP 的读地址就要等整个
    // 译码器——「寄存器读提前起跑」在 FP 侧就落空了。改用本口之后：
    //
    //   * 逻辑锥 = `inst32[6:0]` 上的 7 位比对，与寄存器号切片一样浅；
    //   * **双 FP 阻塞与 mux 选择位必须用同一个谓词**，否则会在「opcode 像 FP
    //     但不合法」那条缝里分岔（slot0 非法 FP + slot1 真 FP 可同拍派遣，
    //     阻塞用门控版放行、选择位用原始版却指向 slot0，slot1 就读不到）。
    //     所以这一根同时喂 dependency_check 的 fp0/fp1 与 mux 的选择位。
    //
    // 多挡掉的只有「opcode 像 FP 但马上要 trap」的指令（取指故障 / 非法编码 /
    // ENABLE_FD=0），它后面那条本来就会被 flush，代价为零。
    // **注意 `FS == Off` 不在此列**：那是派遣期才知道的，两个谓词在那里一致。
    output logic                   dec_is_fp_opcode   [ISSUE_WIDTH]
);

    // ---------------------------------------------------------------------
    // Local encoding constants that the frozen package does not name.
    // ---------------------------------------------------------------------
    // A compressed encoding that has no SUBOP_C_* constant (the Zcb rows the
    // FE decompressor expands, and the Zcmop no-op).  Every real alias tag is
    // in 0..8, so this value cannot collide with one; it lands outside every
    // is_g*_* set and therefore becomes illegal by ④#6 criterion 3.
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
    // ④#6 criterion 4 -- "FP 运算指令" for the reserved-rounding-mode check.
    // ---------------------------------------------------------------------
    // The arithmetic class and the whole conversion class.  Out: FSGNJ* /
    // FMIN / FMAX / FEQ / FLT / FLE / FCLASS / FMV.* whose inst[14:12] means
    // something other than a rounding mode, and FP load / store whose funct3
    // is an access width -- checking those would turn legal instructions
    // illegal.  exe_subop_pkg has no uses_rm helper, so the set is spelled out
    // here; it is the same set dispatch_logic ④#1 uses for its dynamic
    // rm == DYN check, and the two checks are the two halves ④#6 describes
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
    // ④#6 criterion 3 -- does the recoded subop belong to any supported class?
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
    // ④#5 -- the compressed alias tag, read off the frozen SUBOP_C_* table.
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
                // funct3 == 100 is Zcb (C.LBU / C.LHU / C.LH / C.SB / C.SH):
                // expandable by the FE decompressor, but no SUBOP_C_* exists.
                return (c[15:13] == 3'b100) ? RVC_TAG_UNMAPPED : 12'h000;
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
                                    // c[12] == 1 with c[6:5] == 1x is Zcb
                                    default: return RVC_TAG_UNMAPPED;
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
    // Per lane.  ④: "两条 lane 之间无任何耦合" -- nothing below crosses n.
    // =====================================================================
    genvar n;
    generate
        for (n = 0; n < ISSUE_WIDTH; n++) begin : g_lane

            // -------------------------------------------------------------
            // ④#1 step 1 -- RVC expansion（**已经在入队侧做完**）。
            // -------------------------------------------------------------
            // 2026-08-26 之前展开在这里。现在它住 `rvc_expand`，在 FE 与 IB
            // 之间跑一次，结果连同原始半字一起进 IB_Payload。本模块因此只需
            // 把队头的两个形态接过来：`inst32` 供字段切片，`inst16` 供压缩子码
            // 重编码（④#5）。两者的下游用法与展开在本模块时逐字相同。
            //
            // 这么挪的理由：出队那一拍的译码分支不该再串一块展开器——缩短那一拍
            // 正是重构的目的。见 rvc_expand.sv 的头注释。
            logic [31:0] inst32;
            logic [15:0] inst16;

            assign inst32 = ib_inst32[n];
            assign inst16 = ib_inst16[n];

            // -------------------------------------------------------------
            // ④#1 step 2 -- fixed slices of inst32.
            // -------------------------------------------------------------
            logic [6:0]  opcode;
            logic [2:0]  funct3;
            logic [6:0]  funct7;
            logic [4:0]  funct5;
            logic [11:0] funct12;
            logic [4:0]  f_rs1;
            logic [4:0]  f_rs2;
            logic [4:0]  f_rs3;
            logic [4:0]  f_rd;

            assign opcode  = inst32[6:0];
            assign funct3  = inst32[14:12];
            assign funct7  = inst32[31:25];
            assign funct5  = inst32[31:27];
            assign funct12 = inst32[31:20];
            assign f_rs1   = inst32[19:15];
            assign f_rs2   = inst32[24:20];
            assign f_rs3   = inst32[31:27];
            assign f_rd    = inst32[11:7];

            // ④#4 -- the five sign-extended formats plus the two unsigned
            // fields.  Everything is extended to the full 64 bit here; ⑤ of
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
            // ④#4 "移位量 I 型的低 6 位".  A shift amount is an unsigned
            // count, so it is zero-extended, not sign-extended -- sign
            // extension would turn every shamt >= 32 into a huge negative.
            // The same slice serves the W shifts: their inst[25] is 0 in every
            // legal encoding, so the low 6 bits equal {1'b0, shamt[4:0]}.
            assign imm_shamt    = {{(XLEN-6){1'b0}}, inst32[25:20]};
            // The CSR immediate forms put a 5-bit *unsigned* uimm in the rs1
            // field and it rides the imm channel (IB微架构文档 ⑤).
            assign imm_csr_uimm = {{(XLEN-5){1'b0}}, inst32[19:15]};

            // -------------------------------------------------------------
            // ④#5 -- exe_subop, a mechanical recode, not a table lookup.
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
                    // SFENCE.VMA 是 SYSTEM/f3=000 里**唯一**用 funct7 当键的：
                    // 它的 rs1(VA) / rs2(ASID) 是真的寄存器字段，走 funct12
                    // 会让每个 rs2 得到不同的子码。其余（ECALL / EBREAK /
                    // MRET / SRET / WFI）仍用 funct12。          hi_funct7()
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
            // ④#3 -- source / destination use bits and FP membership.
            // -------------------------------------------------------------
            // has_rd is "this format writes a destination"; the x0 suppression
            // that turns it into use_rd is applied once, below.
            logic d_use_rs1;
            logic d_use_rs2;
            logic d_use_rs3;
            logic d_rs1_is_fp;
            logic d_rs2_is_fp;
            logic d_has_rd;
            logic d_rd_is_fp;
            logic d_imm_valid;
            logic signed [XLEN-1:0] d_imm_data;
            logic is_csr_form;

            // SYSTEM funct3 000 is ECALL / EBREAK / MRET, 100 is unassigned.
            assign is_csr_form = (opcode == OPCODE_SYSTEM)
                              && (funct3 != F3_000) && (funct3 != F3_100);

            always_comb begin
                // Defaults: no source, no destination, no immediate.  Every
                // opcode that is not listed falls through to these and then
                // fails ④#6 criterion 3 on its subop.
                d_use_rs1   = 1'b0;
                d_use_rs2   = 1'b0;
                d_use_rs3   = 1'b0;
                d_rs1_is_fp = 1'b0;
                d_rs2_is_fp = 1'b0;
                d_has_rd    = 1'b0;
                d_rd_is_fp  = 1'b0;
                d_imm_valid = 1'b0;
                d_imm_data  = '0;

                case (opcode)
                    // ---- integer load: rs1 = address, rd = integer ---------
                    OPCODE_LOAD: begin
                        d_use_rs1   = 1'b1;
                        d_has_rd    = 1'b1;
                        d_imm_valid = 1'b1;
                        d_imm_data  = imm_i;
                    end

                    // ---- FP load: address source is still integer ---------
                    OPCODE_LOAD_FP: begin
                        d_use_rs1   = 1'b1;
                        d_has_rd    = 1'b1;
                        d_rd_is_fp  = 1'b1;
                        d_imm_valid = 1'b1;
                        d_imm_data  = imm_i;
                    end

                    // ---- FENCE / FENCE.I: no operands (IB ⑤) --------------
                    OPCODE_MISC_MEM: begin
                        // defaults
                    end

                    OPCODE_OP_IMM: begin
                        d_use_rs1   = 1'b1;
                        d_has_rd    = 1'b1;
                        d_imm_valid = 1'b1;
                        d_imm_data  = (funct3 inside {F3_001, F3_101})
                                    ? imm_shamt : imm_i;
                    end

                    OPCODE_OP_IMM32: begin
                        d_use_rs1   = 1'b1;
                        d_has_rd    = 1'b1;
                        d_imm_valid = 1'b1;
                        d_imm_data  = (funct3 inside {F3_001, F3_101})
                                    ? imm_shamt : imm_i;
                    end

                    // ---- U / J: no source register ------------------------
                    OPCODE_AUIPC: begin
                        d_has_rd    = 1'b1;
                        d_imm_valid = 1'b1;
                        d_imm_data  = imm_u;
                    end

                    OPCODE_LUI: begin
                        d_has_rd    = 1'b1;
                        d_imm_valid = 1'b1;
                        d_imm_data  = imm_u;
                    end

                    OPCODE_JAL: begin
                        d_has_rd    = 1'b1;
                        d_imm_valid = 1'b1;
                        d_imm_data  = imm_j;
                    end

                    OPCODE_JALR: begin
                        d_use_rs1   = 1'b1;
                        d_has_rd    = 1'b1;
                        d_imm_valid = 1'b1;
                        d_imm_data  = imm_i;
                    end

                    // ---- stores: no destination ---------------------------
                    OPCODE_STORE: begin
                        d_use_rs1   = 1'b1;
                        d_use_rs2   = 1'b1;
                        d_imm_valid = 1'b1;
                        d_imm_data  = imm_s;
                    end

                    // FSD / FSW: address in rs1 is integer, stored data in
                    // rs2 is FP (④#3).
                    OPCODE_STORE_FP: begin
                        d_use_rs1   = 1'b1;
                        d_use_rs2   = 1'b1;
                        d_rs2_is_fp = 1'b1;
                        d_imm_valid = 1'b1;
                        d_imm_data  = imm_s;
                    end

                    OPCODE_BRANCH: begin
                        d_use_rs1   = 1'b1;
                        d_use_rs2   = 1'b1;
                        d_imm_valid = 1'b1;
                        d_imm_data  = imm_b;
                    end

                    // ---- atomics: rs1 = address, rs2 only for AMO / SC ----
                    // ④#3 "use_rs2 = ... 以及 AMO / SC" -- LR has no second
                    // operand.  imm is fixed 0: atomics have no offset (IB ⑤).
                    OPCODE_AMO: begin
                        d_use_rs1 = 1'b1;
                        d_use_rs2 = !is_g3_lr_subop(subop_raw);
                        d_has_rd  = 1'b1;
                    end

                    OPCODE_OP,
                    OPCODE_OP32: begin
                        d_use_rs1 = 1'b1;
                        d_use_rs2 = 1'b1;
                        d_has_rd  = 1'b1;
                    end

                    // ---- FMA: the only three-source family ----------------
                    OPCODE_MADD,
                    OPCODE_MSUB,
                    OPCODE_NMSUB,
                    OPCODE_NMADD: begin
                        d_use_rs1   = 1'b1;
                        d_use_rs2   = 1'b1;
                        d_use_rs3   = 1'b1;
                        d_rs1_is_fp = 1'b1;
                        d_rs2_is_fp = 1'b1;
                        d_has_rd    = 1'b1;
                        d_rd_is_fp  = 1'b1;
                    end

                    OPCODE_OP_FP: begin
                        d_use_rs1   = 1'b1;
                        d_rs1_is_fp = !opfp_rs1_is_int(funct7);
                        d_use_rs2   = !opfp_unary(funct7);
                        d_rs2_is_fp = !opfp_unary(funct7);
                        d_has_rd    = 1'b1;
                        d_rd_is_fp  = !opfp_rd_is_int(funct7);
                    end

                    // ---- SYSTEM -------------------------------------------
                    // ECALL / EBREAK / MRET have no operands (IB ⑤).  The CSR
                    // register forms read rs1; the immediate forms put a uimm
                    // in the rs1 field, so use_rs1 must be 0 there.
                    OPCODE_SYSTEM: begin
                        if (is_csr_form) begin
                            d_has_rd = 1'b1;
                            if (funct3 inside {F3_001, F3_010, F3_011}) begin
                                d_use_rs1 = 1'b1;
                            end else begin
                                d_imm_valid = 1'b1;
                                d_imm_data  = imm_csr_uimm;
                            end
                        end
                    end

                    default: begin
                        // no sources, no destination, no immediate
                    end
                endcase
            end

            // -------------------------------------------------------------
            // ④#2 -- classification bits that come from exe_subop.
            // -------------------------------------------------------------
            logic d_is_store;
            logic d_is_serial;
            logic d_is_fp_instruction;

            // "plain store only" -- AMO and SC have a store side in the LSU
            // protocol but are not plain stores (IB ⑤).
            assign d_is_store = is_g3_store_subop(subop_raw);

            // IB ⑤: CSR (register and immediate forms), MRET / SRET,
            // FENCE / FENCE.I / SFENCE.VMA, and all 22 atomics.
            // ECALL / EBREAK / WFI are not in it.
            //
            // **SRET 必须在这里,和 MRET 同列。** 参考模型的
            // `SpecCore::isCsrInsn` 把 CSRRW…CSRRCI / MRET / **SRET** / DRET
            // 一并算作 CSR 指令，并强制「CSR 要求 ROB 为空、CSR 在飞时不发别的」。
            // S9 加 SRET 时我把 MRET 的每一处都镜像了，**唯独漏了这一条**，
            // 现象是模型在 SRET 之后的第一条指令上报
            // `issue: in-flight CSR insn blocks non-CSR issue` 然后 decode_and_issue 失败。
            //
            // SFENCE.VMA 归 fence 类：IB ⑤ 已经把 FENCE / FENCE.I 列为串行，
            // 它是同一类内存序指令，不串行没有依据。
            assign d_is_serial = is_g0_csr_subop(subop_raw)
                              || (subop_raw == SUBOP_MRET)
                              || (subop_raw == SUBOP_SRET)
                              || (subop_raw == SUBOP_SFENCE_VMA)
                              || is_g3_fence_subop(subop_raw)
                              || is_g3_atomic_subop(subop_raw);

            // dispatch_logic ④#1: this must cover FLW / FLD / FSW / FSD as
            // well, because FS == Off makes the FP loads and stores illegal
            // too and rd_is_fp would miss the stores.
            assign d_is_fp_instruction = is_g2_fpu_subop(subop_raw)
                                      || is_g3_fp_load_subop(subop_raw)
                                      || is_g3_fp_store_subop(subop_raw);

            // -------------------------------------------------------------
            // ④#6 -- full_decode, and the one illegal decision in the design.
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
            // ④#7: illegal (bad encoding) and fetch fault (no encoding at
            // all) need the *same* downstream shape -- G0/ALU0, no sources,
            // no destination -- and differ only in the cause the ALU reports.
            logic       d_no_encoding;

            assign d_uses_rm = subop_uses_rm(subop_raw);
            // rm is meaningful only on the FP arithmetic / conversion forms;
            // everything else reports RM_RNE.  dispatch overwrites it with
            // effective_rm when it is DYN.
            assign d_rm = d_uses_rm ? rm_e'(funct3) : RM_RNE;

            // csr_write_intent (集成层 §2.2): CSRRW / CSRRWI always write;
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

            // ⑥ 的不门控出口。**这里不能加任何门控**——它的用处是当双 FP 阻塞
            // 与 FP 读地址 mux 的共同谓词，加了门控就退化回「等全译码」。
            assign dec_is_fp_opcode[n] = is_fp_opcode;

            // 1. RVC expansion failed
            assign ill_rvc         = ib_rvc_illegal[n];
            // 2. extension not built (or_be_config_pkg, 集成层 §2.4 -- never a
            //    module parameter).  OPCODE_AMO covers LR / SC / AMO alike.
            assign ill_ext_a       = !ENABLE_A  && (opcode == OPCODE_AMO);
            assign ill_ext_c       = !ENABLE_C  && ib_is_compressed[n];
            assign ill_ext_fd      = !ENABLE_FD && is_fp_opcode;
            // 3. the recode landed outside every supported class
            assign ill_unsupported = !subop_supported(subop_raw);
            // 4. statically reserved rounding mode on an FP arithmetic form.
            //    The FS == Off / DYN half of this check is architectural state
            //    and belongs to dispatch_logic; both feed the same G0 ILLEGAL
            //    path (④#6).
            assign ill_rm          = d_uses_rm && rm_is_reserved(rm_e'(funct3));

            assign d_no_encoding = d_illegal || ib_fetch_excp_vld[n];

            assign d_illegal = ill_rvc || ill_ext_a || ill_ext_c || ill_ext_fd
                            || ill_unsupported || ill_rm;

            // -------------------------------------------------------------
            // ④#2 -- decoded_info assembly.
            // -------------------------------------------------------------
            // On illegal every decode **decision** is forced to a determinate
            // zero (④#6): use_rs* = 0 so the ILLEGAL sub-op is immediately
            // issuable in ISQ_G0, use_rd = 0 so it never enters a tag_mapping,
            // and exe_subop = SUBOP_INVALID, the fallback 集成层 §2.2 and IB ⑤
            // name.
            //
            // **寄存器索引不在这里，也不被这个零门控住。** 它们是 `inst32`
            // 的固定切片，由 backend_top 胶水#5 直接从 IB 队头取去送寄存器读。
            // 假如把它们也串在 d_no_encoding 后面，地址路径就要等
            // `subop_supported()`——那是整个译码器，「寄存器读提前起跑」也就不成立了。
            // 安全性由消费者侧保证，逐条核过，见 or_be_types_pkg 里
            // `decoded_info_t` 的注释。
            always_comb begin
                dec_info[n] = '0;

                // ④#7: a fetch fault reuses ILLEGAL's routing verbatim.
                // dispatch_logic ④ sends illegal_effective to ROUTE_BRU,
                // i.e. GRP_G0 with FU index 0 = ALU0, and the gate below
                // leaves every source, destination and store bit at zero --
                // which is exactly right for an instruction whose encoding
                // was never read.  alu_simple reports the *fetch* cause
                // rather than cause 2 because fetch_excp_vld outranks
                // illegal there (FU接入契约 §3).
                dec_info[n].full_decode.illegal = d_no_encoding;

                if (!d_no_encoding) begin
                    dec_info[n].is_serial         = d_is_serial;
                    dec_info[n].is_fp_instruction = d_is_fp_instruction;

                    dec_info[n].use_rs1   = d_use_rs1;
                    dec_info[n].use_rs2   = d_use_rs2;
                    dec_info[n].use_rs3   = d_use_rs3;
                    dec_info[n].rs1_is_fp = d_rs1_is_fp;
                    dec_info[n].rs2_is_fp = d_rs2_is_fp;
                    // ④#3: constant 1.  rs3 appears only in the FMA family,
                    // and the upstream contract use_rs3[s] => rs3_is_fp[s]
                    // that dependency_check ④ relies on is produced here --
                    // the INT side has no third read port to fall back on.
                    dec_info[n].rs3_is_fp = 1'b1;

                    dec_info[n].rd_is_fp  = d_rd_is_fp;
                    // ④#3: x0 suppression applies to integer destinations
                    // only -- f0 is an ordinary FP register.
                    dec_info[n].use_rd    = d_has_rd
                                         && !((f_rd == 5'd0) && !d_rd_is_fp);

                    dec_info[n].is_store   = d_is_store;
                    dec_info[n].mem_funct3 = funct3;

                    dec_info[n].imm_valid = d_imm_valid;
                    // ④#4: no residue when the instruction has no immediate.
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
