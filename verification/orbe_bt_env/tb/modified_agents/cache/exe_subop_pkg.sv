`ifndef EXE_SUBOP_PKG_SV
`define EXE_SUBOP_PKG_SV

package exe_subop_pkg;

    // OR-BE frozen executable sub-operation contract.
    //
    // This package is the only architectural source of truth for exe_subop.
    // An LSU model may use a narrower group-local sub_op; an adapter may map from
    // these constants, but must never replace this 24-bit encoding.  Encoding
    // is intentionally derived from instruction fields so a decoder and a
    // trace checker can reconstruct the same identity without a table index.
    // v5 (2026-08-25)：新增 SUBOP_SFENCE_VMA。键取 funct7 而非 funct12，
    // 理由见其定义处。同样并入 is_g0_sys_subop，既有常量的值仍未变。
    //
    // **授权方式与 v4 不同，记下来**：
    //   v4  改动**之前**按 RTL实施计划 §9.4 停下来问过，人明确授权后才动。
    //   v5  **先改了，事后才追认**（2026-08-25）。
    // §9.4 要求的是前者。v5 之所以被接受，是因为它与 v4 是同一模式、
    // 且当时的任务指令本身就要求实现 SFENCE.VMA —— **这是特例，不是新惯例**。
    // 下一次要改这个包，仍然先停下来问。
    //
    // v4 (2026-08-25)：新增 SUBOP_SRET / SUBOP_WFI 两个 SYSTEM 子码，
    // 并把它们并入 is_g0_sys_subop。**既有常量的值一个都没有变**，
    // v3 的消费者按值比对不受影响；改的只是「集合里多了两个成员」。
    // 授权见 RTL实施计划 §3 S9（§9.4 要求改冻结包必须停下来问，已问过）。
    localparam int EXE_SUBOP_SPEC_VERSION = 5;

    // Frozen package for OR-BE decoded instruction IDs.
    // Source of truth for opcode/funct fields is this package and the v3
    // BE_LSU interface specification.
    //
    // Current policy:
    //   exe_subop = one decoded instruction ID per supported instruction.
    //
    // Encoding policy for v3:
    //   exe_subop is derived from the instruction encoding fields, not from the
    //   table row number. The packed key is:
    //
    //     {format[1:0], opcode_or_op[6:0], funct3[2:0], high_fixed[11:0]}
    //
    //   format:
    //     2'b01 = ordinary 32-bit RISC-V instruction encoding.
    //             This means instruction length, not RV32 ISA/XLEN.
    //     2'b10 = 16-bit compressed instruction encoding
    //
    //   opcode_or_op:
    //     ordinary instruction: inst[6:0]
    //     compressed instruction: zero-extended compressed op[1:0]
    //
    //   funct3:
    //     ordinary instruction: inst[14:12] when fixed, 3'b000 for variable rm
    //     compressed instruction: compressed bits [15:13]
    //
    //   high_fixed:
    //     ordinary instruction: fixed high encoding information aligned to
    //       inst[31:20], with variable operand/immediate bits set to zero.
    //       Examples: R-type {funct7, 5'b0}; ECALL/EBREAK/MRET funct12;
    //       A-extension {funct5, aq/rl=00, 5'b0}; F convert {funct7, rs2}.
    //     compressed instruction: fixed compressed high-field constraints or a
    //       small disambiguation tag for aliases sharing op/funct3.
    //
    // This preserves the opcode/funct-derived identity requested for subop while
    // avoiding row-number IDs. Any encoding change requires an explicit
    // EXE_SUBOP_SPEC_VERSION increment and a compatible decoder migration.

    parameter int BACKEND_EXE_SUBOP_W = 24;
    typedef logic [BACKEND_EXE_SUBOP_W-1:0] backend_exe_subop_t;

    localparam logic [1:0] SUBOP_FMT_INST32 = 2'b01;
    localparam logic [1:0] SUBOP_FMT_RVC    = 2'b10;

    localparam logic [6:0] OPCODE_LOAD     = 7'b0000011;
    localparam logic [6:0] OPCODE_LOAD_FP  = 7'b0000111;
    localparam logic [6:0] OPCODE_MISC_MEM = 7'b0001111;
    localparam logic [6:0] OPCODE_OP_IMM   = 7'b0010011;
    localparam logic [6:0] OPCODE_AUIPC    = 7'b0010111;
    localparam logic [6:0] OPCODE_OP_IMM32 = 7'b0011011;
    localparam logic [6:0] OPCODE_STORE    = 7'b0100011;
    localparam logic [6:0] OPCODE_STORE_FP = 7'b0100111;
    localparam logic [6:0] OPCODE_AMO      = 7'b0101111;
    localparam logic [6:0] OPCODE_OP       = 7'b0110011;
    localparam logic [6:0] OPCODE_LUI      = 7'b0110111;
    localparam logic [6:0] OPCODE_OP32     = 7'b0111011;
    localparam logic [6:0] OPCODE_MADD     = 7'b1000011;
    localparam logic [6:0] OPCODE_MSUB     = 7'b1000111;
    localparam logic [6:0] OPCODE_NMSUB    = 7'b1001011;
    localparam logic [6:0] OPCODE_NMADD    = 7'b1001111;
    localparam logic [6:0] OPCODE_OP_FP    = 7'b1010011;
    localparam logic [6:0] OPCODE_BRANCH   = 7'b1100011;
    localparam logic [6:0] OPCODE_JALR     = 7'b1100111;
    localparam logic [6:0] OPCODE_JAL      = 7'b1101111;
    localparam logic [6:0] OPCODE_SYSTEM   = 7'b1110011;

    localparam logic [2:0] F3_000 = 3'b000;
    localparam logic [2:0] F3_001 = 3'b001;
    localparam logic [2:0] F3_010 = 3'b010;
    localparam logic [2:0] F3_011 = 3'b011;
    localparam logic [2:0] F3_100 = 3'b100;
    localparam logic [2:0] F3_101 = 3'b101;
    localparam logic [2:0] F3_110 = 3'b110;
    localparam logic [2:0] F3_111 = 3'b111;
    localparam logic [2:0] F3_RMVAR = 3'b000;

    function automatic backend_exe_subop_t enc_inst32(
        input logic [6:0] opcode,
        input logic [2:0] funct3,
        input logic [11:0] high_fixed
    );
        return {SUBOP_FMT_INST32, opcode, funct3, high_fixed};
    endfunction

    function automatic backend_exe_subop_t enc_c(
        input logic [1:0] op,
        input logic [2:0] funct3,
        input logic [11:0] high_fixed
    );
        return {SUBOP_FMT_RVC, 5'b0, op, funct3, high_fixed};
    endfunction

    function automatic logic [11:0] hi_none();
        return 12'h000;
    endfunction

    function automatic logic [11:0] hi_funct7(input logic [6:0] funct7);
        return {funct7, 5'b0};
    endfunction

    function automatic logic [11:0] hi_funct6(input logic [5:0] funct6);
        return {funct6, 6'b0};
    endfunction

    function automatic logic [11:0] hi_funct12(input logic [11:0] funct12);
        return funct12;
    endfunction

    function automatic logic [11:0] hi_amo(input logic [4:0] funct5);
        return {funct5, 2'b00, 5'b0};
    endfunction

    function automatic logic [11:0] hi_f7_rs2(input logic [6:0] funct7, input logic [4:0] rs2);
        return {funct7, rs2};
    endfunction

    function automatic logic [11:0] hi_r4_fmt(input logic [1:0] fmt);
        return {5'b0, fmt, 5'b0};
    endfunction

    function automatic logic [11:0] hi_c(input logic [11:0] tag);
        return tag;
    endfunction

    localparam backend_exe_subop_t SUBOP_INVALID = '0;

    // RV64I base integer, Zifencei, Zicsr, privileged subset.
    localparam backend_exe_subop_t SUBOP_ADDI   = enc_inst32(OPCODE_OP_IMM,   F3_000, hi_none());
    localparam backend_exe_subop_t SUBOP_SLTI   = enc_inst32(OPCODE_OP_IMM,   F3_010, hi_none());
    localparam backend_exe_subop_t SUBOP_SLTIU  = enc_inst32(OPCODE_OP_IMM,   F3_011, hi_none());
    localparam backend_exe_subop_t SUBOP_XORI   = enc_inst32(OPCODE_OP_IMM,   F3_100, hi_none());
    localparam backend_exe_subop_t SUBOP_ORI    = enc_inst32(OPCODE_OP_IMM,   F3_110, hi_none());
    localparam backend_exe_subop_t SUBOP_ANDI   = enc_inst32(OPCODE_OP_IMM,   F3_111, hi_none());
    localparam backend_exe_subop_t SUBOP_SLLI   = enc_inst32(OPCODE_OP_IMM,   F3_001, hi_funct6(6'b000000));
    localparam backend_exe_subop_t SUBOP_SRLI   = enc_inst32(OPCODE_OP_IMM,   F3_101, hi_funct6(6'b000000));
    localparam backend_exe_subop_t SUBOP_SRAI   = enc_inst32(OPCODE_OP_IMM,   F3_101, hi_funct6(6'b010000));
    localparam backend_exe_subop_t SUBOP_ADD    = enc_inst32(OPCODE_OP,       F3_000, hi_funct7(7'b0000000));
    localparam backend_exe_subop_t SUBOP_SUB    = enc_inst32(OPCODE_OP,       F3_000, hi_funct7(7'b0100000));
    localparam backend_exe_subop_t SUBOP_SLL    = enc_inst32(OPCODE_OP,       F3_001, hi_funct7(7'b0000000));
    localparam backend_exe_subop_t SUBOP_SLT    = enc_inst32(OPCODE_OP,       F3_010, hi_funct7(7'b0000000));
    localparam backend_exe_subop_t SUBOP_SLTU   = enc_inst32(OPCODE_OP,       F3_011, hi_funct7(7'b0000000));
    localparam backend_exe_subop_t SUBOP_XOR    = enc_inst32(OPCODE_OP,       F3_100, hi_funct7(7'b0000000));
    localparam backend_exe_subop_t SUBOP_SRL    = enc_inst32(OPCODE_OP,       F3_101, hi_funct7(7'b0000000));
    localparam backend_exe_subop_t SUBOP_SRA    = enc_inst32(OPCODE_OP,       F3_101, hi_funct7(7'b0100000));
    localparam backend_exe_subop_t SUBOP_OR     = enc_inst32(OPCODE_OP,       F3_110, hi_funct7(7'b0000000));
    localparam backend_exe_subop_t SUBOP_AND    = enc_inst32(OPCODE_OP,       F3_111, hi_funct7(7'b0000000));
    localparam backend_exe_subop_t SUBOP_ADDIW  = enc_inst32(OPCODE_OP_IMM32, F3_000, hi_none());
    localparam backend_exe_subop_t SUBOP_SLLIW  = enc_inst32(OPCODE_OP_IMM32, F3_001, hi_funct7(7'b0000000));
    localparam backend_exe_subop_t SUBOP_SRLIW  = enc_inst32(OPCODE_OP_IMM32, F3_101, hi_funct7(7'b0000000));
    localparam backend_exe_subop_t SUBOP_SRAIW  = enc_inst32(OPCODE_OP_IMM32, F3_101, hi_funct7(7'b0100000));
    localparam backend_exe_subop_t SUBOP_ADDW   = enc_inst32(OPCODE_OP32,     F3_000, hi_funct7(7'b0000000));
    localparam backend_exe_subop_t SUBOP_SUBW   = enc_inst32(OPCODE_OP32,     F3_000, hi_funct7(7'b0100000));
    localparam backend_exe_subop_t SUBOP_SLLW   = enc_inst32(OPCODE_OP32,     F3_001, hi_funct7(7'b0000000));
    localparam backend_exe_subop_t SUBOP_SRLW   = enc_inst32(OPCODE_OP32,     F3_101, hi_funct7(7'b0000000));
    localparam backend_exe_subop_t SUBOP_SRAW   = enc_inst32(OPCODE_OP32,     F3_101, hi_funct7(7'b0100000));
    localparam backend_exe_subop_t SUBOP_LUI    = enc_inst32(OPCODE_LUI,      F3_000, hi_none());
    localparam backend_exe_subop_t SUBOP_AUIPC  = enc_inst32(OPCODE_AUIPC,    F3_000, hi_none());
    localparam backend_exe_subop_t SUBOP_JAL    = enc_inst32(OPCODE_JAL,      F3_000, hi_none());
    localparam backend_exe_subop_t SUBOP_JALR   = enc_inst32(OPCODE_JALR,     F3_000, hi_none());
    localparam backend_exe_subop_t SUBOP_BEQ    = enc_inst32(OPCODE_BRANCH,   F3_000, hi_none());
    localparam backend_exe_subop_t SUBOP_BNE    = enc_inst32(OPCODE_BRANCH,   F3_001, hi_none());
    localparam backend_exe_subop_t SUBOP_BLT    = enc_inst32(OPCODE_BRANCH,   F3_100, hi_none());
    localparam backend_exe_subop_t SUBOP_BGE    = enc_inst32(OPCODE_BRANCH,   F3_101, hi_none());
    localparam backend_exe_subop_t SUBOP_BLTU   = enc_inst32(OPCODE_BRANCH,   F3_110, hi_none());
    localparam backend_exe_subop_t SUBOP_BGEU   = enc_inst32(OPCODE_BRANCH,   F3_111, hi_none());
    localparam backend_exe_subop_t SUBOP_LB     = enc_inst32(OPCODE_LOAD,     F3_000, hi_none());
    localparam backend_exe_subop_t SUBOP_LH     = enc_inst32(OPCODE_LOAD,     F3_001, hi_none());
    localparam backend_exe_subop_t SUBOP_LW     = enc_inst32(OPCODE_LOAD,     F3_010, hi_none());
    localparam backend_exe_subop_t SUBOP_LD     = enc_inst32(OPCODE_LOAD,     F3_011, hi_none());
    localparam backend_exe_subop_t SUBOP_LBU    = enc_inst32(OPCODE_LOAD,     F3_100, hi_none());
    localparam backend_exe_subop_t SUBOP_LHU    = enc_inst32(OPCODE_LOAD,     F3_101, hi_none());
    localparam backend_exe_subop_t SUBOP_LWU    = enc_inst32(OPCODE_LOAD,     F3_110, hi_none());
    localparam backend_exe_subop_t SUBOP_SB     = enc_inst32(OPCODE_STORE,    F3_000, hi_none());
    localparam backend_exe_subop_t SUBOP_SH     = enc_inst32(OPCODE_STORE,    F3_001, hi_none());
    localparam backend_exe_subop_t SUBOP_SW     = enc_inst32(OPCODE_STORE,    F3_010, hi_none());
    localparam backend_exe_subop_t SUBOP_SD     = enc_inst32(OPCODE_STORE,    F3_011, hi_none());
    localparam backend_exe_subop_t SUBOP_FENCE  = enc_inst32(OPCODE_MISC_MEM, F3_000, hi_none());
    localparam backend_exe_subop_t SUBOP_ECALL  = enc_inst32(OPCODE_SYSTEM,   F3_000, hi_funct12(12'b000000000000));
    localparam backend_exe_subop_t SUBOP_EBREAK = enc_inst32(OPCODE_SYSTEM,   F3_000, hi_funct12(12'b000000000001));
    localparam backend_exe_subop_t SUBOP_FENCEI = enc_inst32(OPCODE_MISC_MEM, F3_001, hi_funct12(12'b000000000000));
    localparam backend_exe_subop_t SUBOP_CSRRW  = enc_inst32(OPCODE_SYSTEM,   F3_001, hi_none());
    localparam backend_exe_subop_t SUBOP_CSRRS  = enc_inst32(OPCODE_SYSTEM,   F3_010, hi_none());
    localparam backend_exe_subop_t SUBOP_CSRRC  = enc_inst32(OPCODE_SYSTEM,   F3_011, hi_none());
    localparam backend_exe_subop_t SUBOP_CSRRWI = enc_inst32(OPCODE_SYSTEM,   F3_101, hi_none());
    localparam backend_exe_subop_t SUBOP_CSRRSI = enc_inst32(OPCODE_SYSTEM,   F3_110, hi_none());
    localparam backend_exe_subop_t SUBOP_CSRRCI = enc_inst32(OPCODE_SYSTEM,   F3_111, hi_none());
    localparam backend_exe_subop_t SUBOP_MRET   = enc_inst32(OPCODE_SYSTEM,   F3_000, hi_funct12(12'b001100000010));
    // v4：S 态。编码规则与上面同源（SYSTEM / f3=000 / funct12 进 high_fixed），
    // 不是查表得来的，decode 按 ④#5 的机械规则自然产出同一个值。
    localparam backend_exe_subop_t SUBOP_SRET   = enc_inst32(OPCODE_SYSTEM,   F3_000, hi_funct12(12'b000100000010));  // funct12 = 0x102
    localparam backend_exe_subop_t SUBOP_WFI    = enc_inst32(OPCODE_SYSTEM,   F3_000, hi_funct12(12'b000100000101));  // funct12 = 0x105
    // v5：SFENCE.VMA。**键是 funct7，不是 funct12。**
    // 编码 0001001_rs2_rs1_000_00000_1110011 —— rs1(VA) / rs2(ASID) 是**真的
    // 寄存器字段**，走 hi_funct12 会让每个 rs2 得到一个不同的子码。
    // hi_funct7 = {funct7, 5'b0} = 12'h120，与 rs1/rs2 无关，且不与
    // ECALL(0x000)/EBREAK(0x001)/SRET(0x102)/WFI(0x105)/MRET(0x302) 冲突。
    localparam backend_exe_subop_t SUBOP_SFENCE_VMA =
        enc_inst32(OPCODE_SYSTEM, F3_000, hi_funct7(7'b0001001));

    // RV64M.
    localparam backend_exe_subop_t SUBOP_MUL    = enc_inst32(OPCODE_OP,   F3_000, hi_funct7(7'b0000001));
    localparam backend_exe_subop_t SUBOP_MULH   = enc_inst32(OPCODE_OP,   F3_001, hi_funct7(7'b0000001));
    localparam backend_exe_subop_t SUBOP_MULHSU = enc_inst32(OPCODE_OP,   F3_010, hi_funct7(7'b0000001));
    localparam backend_exe_subop_t SUBOP_MULHU  = enc_inst32(OPCODE_OP,   F3_011, hi_funct7(7'b0000001));
    localparam backend_exe_subop_t SUBOP_DIV    = enc_inst32(OPCODE_OP,   F3_100, hi_funct7(7'b0000001));
    localparam backend_exe_subop_t SUBOP_DIVU   = enc_inst32(OPCODE_OP,   F3_101, hi_funct7(7'b0000001));
    localparam backend_exe_subop_t SUBOP_REM    = enc_inst32(OPCODE_OP,   F3_110, hi_funct7(7'b0000001));
    localparam backend_exe_subop_t SUBOP_REMU   = enc_inst32(OPCODE_OP,   F3_111, hi_funct7(7'b0000001));
    localparam backend_exe_subop_t SUBOP_MULW   = enc_inst32(OPCODE_OP32, F3_000, hi_funct7(7'b0000001));
    localparam backend_exe_subop_t SUBOP_DIVW   = enc_inst32(OPCODE_OP32, F3_100, hi_funct7(7'b0000001));
    localparam backend_exe_subop_t SUBOP_DIVUW  = enc_inst32(OPCODE_OP32, F3_101, hi_funct7(7'b0000001));
    localparam backend_exe_subop_t SUBOP_REMW   = enc_inst32(OPCODE_OP32, F3_110, hi_funct7(7'b0000001));
    localparam backend_exe_subop_t SUBOP_REMUW  = enc_inst32(OPCODE_OP32, F3_111, hi_funct7(7'b0000001));

    // RV64A. aq/rl suffix variants are not expanded in this proposal.
    localparam backend_exe_subop_t SUBOP_LR_W       = enc_inst32(OPCODE_AMO, F3_010, hi_amo(5'b00010));
    localparam backend_exe_subop_t SUBOP_SC_W       = enc_inst32(OPCODE_AMO, F3_010, hi_amo(5'b00011));
    localparam backend_exe_subop_t SUBOP_AMOSWAP_W  = enc_inst32(OPCODE_AMO, F3_010, hi_amo(5'b00001));
    localparam backend_exe_subop_t SUBOP_AMOADD_W   = enc_inst32(OPCODE_AMO, F3_010, hi_amo(5'b00000));
    localparam backend_exe_subop_t SUBOP_AMOXOR_W   = enc_inst32(OPCODE_AMO, F3_010, hi_amo(5'b00100));
    localparam backend_exe_subop_t SUBOP_AMOAND_W   = enc_inst32(OPCODE_AMO, F3_010, hi_amo(5'b01100));
    localparam backend_exe_subop_t SUBOP_AMOOR_W    = enc_inst32(OPCODE_AMO, F3_010, hi_amo(5'b01000));
    localparam backend_exe_subop_t SUBOP_AMOMIN_W   = enc_inst32(OPCODE_AMO, F3_010, hi_amo(5'b10000));
    localparam backend_exe_subop_t SUBOP_AMOMAX_W   = enc_inst32(OPCODE_AMO, F3_010, hi_amo(5'b10100));
    localparam backend_exe_subop_t SUBOP_AMOMINU_W  = enc_inst32(OPCODE_AMO, F3_010, hi_amo(5'b11000));
    localparam backend_exe_subop_t SUBOP_AMOMAXU_W  = enc_inst32(OPCODE_AMO, F3_010, hi_amo(5'b11100));
    localparam backend_exe_subop_t SUBOP_LR_D       = enc_inst32(OPCODE_AMO, F3_011, hi_amo(5'b00010));
    localparam backend_exe_subop_t SUBOP_SC_D       = enc_inst32(OPCODE_AMO, F3_011, hi_amo(5'b00011));
    localparam backend_exe_subop_t SUBOP_AMOSWAP_D  = enc_inst32(OPCODE_AMO, F3_011, hi_amo(5'b00001));
    localparam backend_exe_subop_t SUBOP_AMOADD_D   = enc_inst32(OPCODE_AMO, F3_011, hi_amo(5'b00000));
    localparam backend_exe_subop_t SUBOP_AMOXOR_D   = enc_inst32(OPCODE_AMO, F3_011, hi_amo(5'b00100));
    localparam backend_exe_subop_t SUBOP_AMOAND_D   = enc_inst32(OPCODE_AMO, F3_011, hi_amo(5'b01100));
    localparam backend_exe_subop_t SUBOP_AMOOR_D    = enc_inst32(OPCODE_AMO, F3_011, hi_amo(5'b01000));
    localparam backend_exe_subop_t SUBOP_AMOMIN_D   = enc_inst32(OPCODE_AMO, F3_011, hi_amo(5'b10000));
    localparam backend_exe_subop_t SUBOP_AMOMAX_D   = enc_inst32(OPCODE_AMO, F3_011, hi_amo(5'b10100));
    localparam backend_exe_subop_t SUBOP_AMOMINU_D  = enc_inst32(OPCODE_AMO, F3_011, hi_amo(5'b11000));
    localparam backend_exe_subop_t SUBOP_AMOMAXU_D  = enc_inst32(OPCODE_AMO, F3_011, hi_amo(5'b11100));

    // RV64F/RV64D floating-point. rm is variable and not expanded here.
    localparam backend_exe_subop_t SUBOP_FLW       = enc_inst32(OPCODE_LOAD_FP,  F3_010, hi_none());
    localparam backend_exe_subop_t SUBOP_FSW       = enc_inst32(OPCODE_STORE_FP, F3_010, hi_none());
    localparam backend_exe_subop_t SUBOP_FLD       = enc_inst32(OPCODE_LOAD_FP,  F3_011, hi_none());
    localparam backend_exe_subop_t SUBOP_FSD       = enc_inst32(OPCODE_STORE_FP, F3_011, hi_none());
    localparam backend_exe_subop_t SUBOP_FMADD_S   = enc_inst32(OPCODE_MADD,     F3_RMVAR, hi_r4_fmt(2'b00));
    localparam backend_exe_subop_t SUBOP_FMSUB_S   = enc_inst32(OPCODE_MSUB,     F3_RMVAR, hi_r4_fmt(2'b00));
    localparam backend_exe_subop_t SUBOP_FNMSUB_S  = enc_inst32(OPCODE_NMSUB,    F3_RMVAR, hi_r4_fmt(2'b00));
    localparam backend_exe_subop_t SUBOP_FNMADD_S  = enc_inst32(OPCODE_NMADD,    F3_RMVAR, hi_r4_fmt(2'b00));
    localparam backend_exe_subop_t SUBOP_FMADD_D   = enc_inst32(OPCODE_MADD,     F3_RMVAR, hi_r4_fmt(2'b01));
    localparam backend_exe_subop_t SUBOP_FMSUB_D   = enc_inst32(OPCODE_MSUB,     F3_RMVAR, hi_r4_fmt(2'b01));
    localparam backend_exe_subop_t SUBOP_FNMSUB_D  = enc_inst32(OPCODE_NMSUB,    F3_RMVAR, hi_r4_fmt(2'b01));
    localparam backend_exe_subop_t SUBOP_FNMADD_D  = enc_inst32(OPCODE_NMADD,    F3_RMVAR, hi_r4_fmt(2'b01));
    localparam backend_exe_subop_t SUBOP_FADD_S    = enc_inst32(OPCODE_OP_FP,    F3_RMVAR, hi_funct7(7'b0000000));
    localparam backend_exe_subop_t SUBOP_FSUB_S    = enc_inst32(OPCODE_OP_FP,    F3_RMVAR, hi_funct7(7'b0000100));
    localparam backend_exe_subop_t SUBOP_FMUL_S    = enc_inst32(OPCODE_OP_FP,    F3_RMVAR, hi_funct7(7'b0001000));
    localparam backend_exe_subop_t SUBOP_FDIV_S    = enc_inst32(OPCODE_OP_FP,    F3_RMVAR, hi_funct7(7'b0001100));
    localparam backend_exe_subop_t SUBOP_FSQRT_S   = enc_inst32(OPCODE_OP_FP,    F3_RMVAR, hi_f7_rs2(7'b0101100, 5'b00000));
    localparam backend_exe_subop_t SUBOP_FADD_D    = enc_inst32(OPCODE_OP_FP,    F3_RMVAR, hi_funct7(7'b0000001));
    localparam backend_exe_subop_t SUBOP_FSUB_D    = enc_inst32(OPCODE_OP_FP,    F3_RMVAR, hi_funct7(7'b0000101));
    localparam backend_exe_subop_t SUBOP_FMUL_D    = enc_inst32(OPCODE_OP_FP,    F3_RMVAR, hi_funct7(7'b0001001));
    localparam backend_exe_subop_t SUBOP_FDIV_D    = enc_inst32(OPCODE_OP_FP,    F3_RMVAR, hi_funct7(7'b0001101));
    localparam backend_exe_subop_t SUBOP_FSQRT_D   = enc_inst32(OPCODE_OP_FP,    F3_RMVAR, hi_f7_rs2(7'b0101101, 5'b00000));
    localparam backend_exe_subop_t SUBOP_FSGNJ_S   = enc_inst32(OPCODE_OP_FP,    F3_000,   hi_funct7(7'b0010000));
    localparam backend_exe_subop_t SUBOP_FSGNJN_S  = enc_inst32(OPCODE_OP_FP,    F3_001,   hi_funct7(7'b0010000));
    localparam backend_exe_subop_t SUBOP_FSGNJX_S  = enc_inst32(OPCODE_OP_FP,    F3_010,   hi_funct7(7'b0010000));
    localparam backend_exe_subop_t SUBOP_FMIN_S    = enc_inst32(OPCODE_OP_FP,    F3_000,   hi_funct7(7'b0010100));
    localparam backend_exe_subop_t SUBOP_FMAX_S    = enc_inst32(OPCODE_OP_FP,    F3_001,   hi_funct7(7'b0010100));
    localparam backend_exe_subop_t SUBOP_FSGNJ_D   = enc_inst32(OPCODE_OP_FP,    F3_000,   hi_funct7(7'b0010001));
    localparam backend_exe_subop_t SUBOP_FSGNJN_D  = enc_inst32(OPCODE_OP_FP,    F3_001,   hi_funct7(7'b0010001));
    localparam backend_exe_subop_t SUBOP_FSGNJX_D  = enc_inst32(OPCODE_OP_FP,    F3_010,   hi_funct7(7'b0010001));
    localparam backend_exe_subop_t SUBOP_FMIN_D    = enc_inst32(OPCODE_OP_FP,    F3_000,   hi_funct7(7'b0010101));
    localparam backend_exe_subop_t SUBOP_FMAX_D    = enc_inst32(OPCODE_OP_FP,    F3_001,   hi_funct7(7'b0010101));
    localparam backend_exe_subop_t SUBOP_FCVT_W_S  = enc_inst32(OPCODE_OP_FP,    F3_RMVAR, hi_f7_rs2(7'b1100000, 5'b00000));
    localparam backend_exe_subop_t SUBOP_FCVT_WU_S = enc_inst32(OPCODE_OP_FP,    F3_RMVAR, hi_f7_rs2(7'b1100000, 5'b00001));
    localparam backend_exe_subop_t SUBOP_FCVT_L_S  = enc_inst32(OPCODE_OP_FP,    F3_RMVAR, hi_f7_rs2(7'b1100000, 5'b00010));
    localparam backend_exe_subop_t SUBOP_FCVT_LU_S = enc_inst32(OPCODE_OP_FP,    F3_RMVAR, hi_f7_rs2(7'b1100000, 5'b00011));
    localparam backend_exe_subop_t SUBOP_FCVT_W_D  = enc_inst32(OPCODE_OP_FP,    F3_RMVAR, hi_f7_rs2(7'b1100001, 5'b00000));
    localparam backend_exe_subop_t SUBOP_FCVT_WU_D = enc_inst32(OPCODE_OP_FP,    F3_RMVAR, hi_f7_rs2(7'b1100001, 5'b00001));
    localparam backend_exe_subop_t SUBOP_FCVT_L_D  = enc_inst32(OPCODE_OP_FP,    F3_RMVAR, hi_f7_rs2(7'b1100001, 5'b00010));
    localparam backend_exe_subop_t SUBOP_FCVT_LU_D = enc_inst32(OPCODE_OP_FP,    F3_RMVAR, hi_f7_rs2(7'b1100001, 5'b00011));
    localparam backend_exe_subop_t SUBOP_FCVT_S_W  = enc_inst32(OPCODE_OP_FP,    F3_RMVAR, hi_f7_rs2(7'b1101000, 5'b00000));
    localparam backend_exe_subop_t SUBOP_FCVT_S_WU = enc_inst32(OPCODE_OP_FP,    F3_RMVAR, hi_f7_rs2(7'b1101000, 5'b00001));
    localparam backend_exe_subop_t SUBOP_FCVT_S_L  = enc_inst32(OPCODE_OP_FP,    F3_RMVAR, hi_f7_rs2(7'b1101000, 5'b00010));
    localparam backend_exe_subop_t SUBOP_FCVT_S_LU = enc_inst32(OPCODE_OP_FP,    F3_RMVAR, hi_f7_rs2(7'b1101000, 5'b00011));
    localparam backend_exe_subop_t SUBOP_FCVT_D_W  = enc_inst32(OPCODE_OP_FP,    F3_RMVAR, hi_f7_rs2(7'b1101001, 5'b00000));
    localparam backend_exe_subop_t SUBOP_FCVT_D_WU = enc_inst32(OPCODE_OP_FP,    F3_RMVAR, hi_f7_rs2(7'b1101001, 5'b00001));
    localparam backend_exe_subop_t SUBOP_FCVT_D_L  = enc_inst32(OPCODE_OP_FP,    F3_RMVAR, hi_f7_rs2(7'b1101001, 5'b00010));
    localparam backend_exe_subop_t SUBOP_FCVT_D_LU = enc_inst32(OPCODE_OP_FP,    F3_RMVAR, hi_f7_rs2(7'b1101001, 5'b00011));
    localparam backend_exe_subop_t SUBOP_FCVT_S_D  = enc_inst32(OPCODE_OP_FP,    F3_RMVAR, hi_f7_rs2(7'b0100000, 5'b00001));
    localparam backend_exe_subop_t SUBOP_FCVT_D_S  = enc_inst32(OPCODE_OP_FP,    F3_RMVAR, hi_f7_rs2(7'b0100001, 5'b00000));
    localparam backend_exe_subop_t SUBOP_FMV_X_W   = enc_inst32(OPCODE_OP_FP,    F3_000,   hi_f7_rs2(7'b1110000, 5'b00000));
    localparam backend_exe_subop_t SUBOP_FMV_W_X   = enc_inst32(OPCODE_OP_FP,    F3_000,   hi_f7_rs2(7'b1111000, 5'b00000));
    localparam backend_exe_subop_t SUBOP_FMV_X_D   = enc_inst32(OPCODE_OP_FP,    F3_000,   hi_f7_rs2(7'b1110001, 5'b00000));
    localparam backend_exe_subop_t SUBOP_FMV_D_X   = enc_inst32(OPCODE_OP_FP,    F3_000,   hi_f7_rs2(7'b1111001, 5'b00000));
    localparam backend_exe_subop_t SUBOP_FEQ_S     = enc_inst32(OPCODE_OP_FP,    F3_010,   hi_funct7(7'b1010000));
    localparam backend_exe_subop_t SUBOP_FLT_S     = enc_inst32(OPCODE_OP_FP,    F3_001,   hi_funct7(7'b1010000));
    localparam backend_exe_subop_t SUBOP_FLE_S     = enc_inst32(OPCODE_OP_FP,    F3_000,   hi_funct7(7'b1010000));
    localparam backend_exe_subop_t SUBOP_FCLASS_S  = enc_inst32(OPCODE_OP_FP,    F3_001,   hi_f7_rs2(7'b1110000, 5'b00000));
    localparam backend_exe_subop_t SUBOP_FEQ_D     = enc_inst32(OPCODE_OP_FP,    F3_010,   hi_funct7(7'b1010001));
    localparam backend_exe_subop_t SUBOP_FLT_D     = enc_inst32(OPCODE_OP_FP,    F3_001,   hi_funct7(7'b1010001));
    localparam backend_exe_subop_t SUBOP_FLE_D     = enc_inst32(OPCODE_OP_FP,    F3_000,   hi_funct7(7'b1010001));
    localparam backend_exe_subop_t SUBOP_FCLASS_D  = enc_inst32(OPCODE_OP_FP,    F3_001,   hi_f7_rs2(7'b1110001, 5'b00000));

    // RV64C compressed inputs. The high field follows fixed compressed bits
    // from RISCV_SUPPORTED_OPCODE_FUNCT_TABLE.md where available; otherwise it
    // is a small alias-disambiguation tag for rows sharing op/funct3.
    localparam backend_exe_subop_t SUBOP_C_ADDI4SPN = enc_c(2'b00, F3_000, hi_c(12'h000));
    localparam backend_exe_subop_t SUBOP_C_NOP      = enc_c(2'b01, F3_000, hi_c(12'h000));
    localparam backend_exe_subop_t SUBOP_C_ADDI     = enc_c(2'b01, F3_000, hi_c(12'h001));
    localparam backend_exe_subop_t SUBOP_C_ADDIW    = enc_c(2'b01, F3_001, hi_c(12'h000));
    localparam backend_exe_subop_t SUBOP_C_LI       = enc_c(2'b01, F3_010, hi_c(12'h000));
    localparam backend_exe_subop_t SUBOP_C_ADDI16SP = enc_c(2'b01, F3_011, hi_c(12'h000));
    localparam backend_exe_subop_t SUBOP_C_LUI      = enc_c(2'b01, F3_011, hi_c(12'h001));
    localparam backend_exe_subop_t SUBOP_C_FLD      = enc_c(2'b00, F3_001, hi_c(12'h000));
    localparam backend_exe_subop_t SUBOP_C_LW       = enc_c(2'b00, F3_010, hi_c(12'h000));
    localparam backend_exe_subop_t SUBOP_C_LD       = enc_c(2'b00, F3_011, hi_c(12'h000));
    localparam backend_exe_subop_t SUBOP_C_FSD      = enc_c(2'b00, F3_101, hi_c(12'h000));
    localparam backend_exe_subop_t SUBOP_C_SW       = enc_c(2'b00, F3_110, hi_c(12'h000));
    localparam backend_exe_subop_t SUBOP_C_SD       = enc_c(2'b00, F3_111, hi_c(12'h000));
    localparam backend_exe_subop_t SUBOP_C_FLDSP    = enc_c(2'b10, F3_001, hi_c(12'h000));
    localparam backend_exe_subop_t SUBOP_C_LWSP     = enc_c(2'b10, F3_010, hi_c(12'h000));
    localparam backend_exe_subop_t SUBOP_C_LDSP     = enc_c(2'b10, F3_011, hi_c(12'h000));
    localparam backend_exe_subop_t SUBOP_C_FSDSP    = enc_c(2'b10, F3_101, hi_c(12'h000));
    localparam backend_exe_subop_t SUBOP_C_SWSP     = enc_c(2'b10, F3_110, hi_c(12'h000));
    localparam backend_exe_subop_t SUBOP_C_SDSP     = enc_c(2'b10, F3_111, hi_c(12'h000));
    localparam backend_exe_subop_t SUBOP_C_SLLI     = enc_c(2'b10, F3_000, hi_c(12'h000));
    localparam backend_exe_subop_t SUBOP_C_SRLI     = enc_c(2'b01, F3_100, hi_c(12'h000));
    localparam backend_exe_subop_t SUBOP_C_SRAI     = enc_c(2'b01, F3_100, hi_c(12'h001));
    localparam backend_exe_subop_t SUBOP_C_ANDI     = enc_c(2'b01, F3_100, hi_c(12'h002));
    localparam backend_exe_subop_t SUBOP_C_SUB      = enc_c(2'b01, F3_100, hi_c(12'h003));
    localparam backend_exe_subop_t SUBOP_C_XOR      = enc_c(2'b01, F3_100, hi_c(12'h004));
    localparam backend_exe_subop_t SUBOP_C_OR       = enc_c(2'b01, F3_100, hi_c(12'h005));
    localparam backend_exe_subop_t SUBOP_C_AND      = enc_c(2'b01, F3_100, hi_c(12'h006));
    localparam backend_exe_subop_t SUBOP_C_SUBW     = enc_c(2'b01, F3_100, hi_c(12'h007));
    localparam backend_exe_subop_t SUBOP_C_ADDW     = enc_c(2'b01, F3_100, hi_c(12'h008));
    localparam backend_exe_subop_t SUBOP_C_MV       = enc_c(2'b10, F3_100, hi_c(12'h001));
    localparam backend_exe_subop_t SUBOP_C_ADD      = enc_c(2'b10, F3_100, hi_c(12'h004));
    localparam backend_exe_subop_t SUBOP_C_J        = enc_c(2'b01, F3_101, hi_c(12'h000));
    localparam backend_exe_subop_t SUBOP_C_JR       = enc_c(2'b10, F3_100, hi_c(12'h000));
    localparam backend_exe_subop_t SUBOP_C_JALR     = enc_c(2'b10, F3_100, hi_c(12'h003));
    localparam backend_exe_subop_t SUBOP_C_BEQZ     = enc_c(2'b01, F3_110, hi_c(12'h000));
    localparam backend_exe_subop_t SUBOP_C_BNEZ     = enc_c(2'b01, F3_111, hi_c(12'h000));
    localparam backend_exe_subop_t SUBOP_C_EBREAK   = enc_c(2'b10, F3_100, hi_c(12'h002));

    // ------------------------------------------------------------------
    // Classification helper functions. These functions do not derive exe_type;
    // they classify a decoded instruction ID after dispatch has selected a
    // group.  The G3 categories are mutually exclusive at the instruction
    // category level; an AMO/SC is not a plain store even though it has a
    // store side in the LSU execution protocol.
    // ------------------------------------------------------------------

    function automatic logic is_g0_alu0_subop(backend_exe_subop_t s);
        return s inside {
            SUBOP_ADDI, SUBOP_SLTI, SUBOP_SLTIU, SUBOP_XORI, SUBOP_ORI, SUBOP_ANDI,
            SUBOP_SLLI, SUBOP_SRLI, SUBOP_SRAI, SUBOP_ADD, SUBOP_SUB, SUBOP_SLL,
            SUBOP_SLT, SUBOP_SLTU, SUBOP_XOR, SUBOP_SRL, SUBOP_SRA, SUBOP_OR,
            SUBOP_AND, SUBOP_ADDIW, SUBOP_SLLIW, SUBOP_SRLIW, SUBOP_SRAIW,
            SUBOP_ADDW, SUBOP_SUBW, SUBOP_SLLW, SUBOP_SRLW, SUBOP_SRAW,
            SUBOP_LUI, SUBOP_AUIPC,
            SUBOP_C_ADDI4SPN, SUBOP_C_NOP, SUBOP_C_ADDI, SUBOP_C_ADDIW,
            SUBOP_C_LI, SUBOP_C_ADDI16SP, SUBOP_C_LUI, SUBOP_C_SLLI,
            SUBOP_C_SRLI, SUBOP_C_SRAI, SUBOP_C_ANDI, SUBOP_C_SUB,
            SUBOP_C_XOR, SUBOP_C_OR, SUBOP_C_AND, SUBOP_C_SUBW,
            SUBOP_C_ADDW, SUBOP_C_MV, SUBOP_C_ADD
        };
    endfunction

    function automatic logic is_g1_alu1_subop(backend_exe_subop_t s);
        return s inside {
            SUBOP_ADDI, SUBOP_SLTI, SUBOP_SLTIU, SUBOP_XORI, SUBOP_ORI, SUBOP_ANDI,
            SUBOP_SLLI, SUBOP_SRLI, SUBOP_SRAI, SUBOP_ADD, SUBOP_SUB, SUBOP_SLL,
            SUBOP_SLT, SUBOP_SLTU, SUBOP_XOR, SUBOP_SRL, SUBOP_SRA, SUBOP_OR,
            SUBOP_AND, SUBOP_ADDIW, SUBOP_SLLIW, SUBOP_SRLIW, SUBOP_SRAIW,
            SUBOP_ADDW, SUBOP_SUBW, SUBOP_SLLW, SUBOP_SRLW, SUBOP_SRAW,
            SUBOP_LUI,
            SUBOP_C_ADDI4SPN, SUBOP_C_NOP, SUBOP_C_ADDI, SUBOP_C_ADDIW,
            SUBOP_C_LI, SUBOP_C_ADDI16SP, SUBOP_C_LUI, SUBOP_C_SLLI,
            SUBOP_C_SRLI, SUBOP_C_SRAI, SUBOP_C_ANDI, SUBOP_C_SUB,
            SUBOP_C_XOR, SUBOP_C_OR, SUBOP_C_AND, SUBOP_C_SUBW,
            SUBOP_C_ADDW, SUBOP_C_MV, SUBOP_C_ADD
        };
    endfunction

    function automatic logic is_g0_bru_subop(backend_exe_subop_t s);
        return s inside {
            SUBOP_JAL, SUBOP_JALR, SUBOP_BEQ, SUBOP_BNE, SUBOP_BLT, SUBOP_BGE,
            SUBOP_BLTU, SUBOP_BGEU, SUBOP_C_J, SUBOP_C_JR, SUBOP_C_JALR,
            SUBOP_C_BEQZ, SUBOP_C_BNEZ
        };
    endfunction

    function automatic logic is_g0_div_subop(backend_exe_subop_t s);
        return s inside {SUBOP_DIV, SUBOP_DIVU, SUBOP_REM, SUBOP_REMU, SUBOP_DIVW, SUBOP_DIVUW, SUBOP_REMW, SUBOP_REMUW};
    endfunction

    function automatic logic is_g0_csr_subop(backend_exe_subop_t s);
        return s inside {SUBOP_CSRRW, SUBOP_CSRRS, SUBOP_CSRRC, SUBOP_CSRRWI, SUBOP_CSRRSI, SUBOP_CSRRCI};
    endfunction

    function automatic logic is_g0_sys_subop(backend_exe_subop_t s);
        // v4 起含 SRET / WFI。它们必须在这个集合里，否则 dispatch_logic 的
        // subop_supported_now 判它们 ROUTE_UNSUPPORTED —— 后果不是 trap，
        // 是**挂死**（slot0_guard_ok 永远不成立，IB 头排不空）。
        return s inside {SUBOP_ECALL, SUBOP_EBREAK, SUBOP_C_EBREAK, SUBOP_MRET,
                         SUBOP_SRET, SUBOP_WFI, SUBOP_SFENCE_VMA};
    endfunction

    function automatic logic is_g1_mul_subop(backend_exe_subop_t s);
        return s inside {SUBOP_MUL, SUBOP_MULH, SUBOP_MULHSU, SUBOP_MULHU, SUBOP_MULW};
    endfunction

    function automatic logic is_g2_fpu_subop(backend_exe_subop_t s);
        return s inside {
            SUBOP_FMADD_S, SUBOP_FMSUB_S, SUBOP_FNMSUB_S, SUBOP_FNMADD_S,
            SUBOP_FMADD_D, SUBOP_FMSUB_D, SUBOP_FNMSUB_D, SUBOP_FNMADD_D,
            SUBOP_FADD_S, SUBOP_FSUB_S, SUBOP_FMUL_S, SUBOP_FDIV_S, SUBOP_FSQRT_S,
            SUBOP_FADD_D, SUBOP_FSUB_D, SUBOP_FMUL_D, SUBOP_FDIV_D, SUBOP_FSQRT_D,
            SUBOP_FSGNJ_S, SUBOP_FSGNJN_S, SUBOP_FSGNJX_S, SUBOP_FMIN_S, SUBOP_FMAX_S,
            SUBOP_FSGNJ_D, SUBOP_FSGNJN_D, SUBOP_FSGNJX_D, SUBOP_FMIN_D, SUBOP_FMAX_D,
            SUBOP_FCVT_W_S, SUBOP_FCVT_WU_S, SUBOP_FCVT_L_S, SUBOP_FCVT_LU_S,
            SUBOP_FCVT_W_D, SUBOP_FCVT_WU_D, SUBOP_FCVT_L_D, SUBOP_FCVT_LU_D,
            SUBOP_FCVT_S_W, SUBOP_FCVT_S_WU, SUBOP_FCVT_S_L, SUBOP_FCVT_S_LU,
            SUBOP_FCVT_D_W, SUBOP_FCVT_D_WU, SUBOP_FCVT_D_L, SUBOP_FCVT_D_LU,
            SUBOP_FCVT_S_D, SUBOP_FCVT_D_S,
            SUBOP_FMV_X_W, SUBOP_FMV_W_X, SUBOP_FMV_X_D, SUBOP_FMV_D_X,
            SUBOP_FEQ_S, SUBOP_FLT_S, SUBOP_FLE_S, SUBOP_FCLASS_S,
            SUBOP_FEQ_D, SUBOP_FLT_D, SUBOP_FLE_D, SUBOP_FCLASS_D
        };
    endfunction

    function automatic logic is_g3_lsu_subop(backend_exe_subop_t s);
        return s inside {
            SUBOP_LB, SUBOP_LH, SUBOP_LW, SUBOP_LD, SUBOP_LBU, SUBOP_LHU, SUBOP_LWU,
            SUBOP_SB, SUBOP_SH, SUBOP_SW, SUBOP_SD, SUBOP_FLW, SUBOP_FSW, SUBOP_FLD, SUBOP_FSD,
            SUBOP_C_LW, SUBOP_C_LD, SUBOP_C_FLD, SUBOP_C_LWSP, SUBOP_C_LDSP, SUBOP_C_FLDSP,
            SUBOP_C_SW, SUBOP_C_SD, SUBOP_C_FSD, SUBOP_C_SWSP, SUBOP_C_SDSP, SUBOP_C_FSDSP
        };
    endfunction

    function automatic logic is_g3_load_subop(backend_exe_subop_t s);
        return s inside {
            SUBOP_LB, SUBOP_LH, SUBOP_LW, SUBOP_LD, SUBOP_LBU, SUBOP_LHU, SUBOP_LWU,
            SUBOP_FLW, SUBOP_FLD,
            SUBOP_C_LW, SUBOP_C_LD, SUBOP_C_FLD,
            SUBOP_C_LWSP, SUBOP_C_LDSP, SUBOP_C_FLDSP
        };
    endfunction

    function automatic logic is_g3_store_subop(backend_exe_subop_t s);
        return s inside {
            SUBOP_SB, SUBOP_SH, SUBOP_SW, SUBOP_SD,
            SUBOP_FSW, SUBOP_FSD,
            SUBOP_C_SW, SUBOP_C_SD, SUBOP_C_FSD,
            SUBOP_C_SWSP, SUBOP_C_SDSP, SUBOP_C_FSDSP
        };
    endfunction

    function automatic logic is_g3_fp_load_subop(backend_exe_subop_t s);
        return s inside {SUBOP_FLW, SUBOP_FLD, SUBOP_C_FLD, SUBOP_C_FLDSP};
    endfunction

    function automatic logic is_g3_fp_store_subop(backend_exe_subop_t s);
        return s inside {SUBOP_FSW, SUBOP_FSD, SUBOP_C_FSD, SUBOP_C_FSDSP};
    endfunction

    function automatic logic is_g3_lr_subop(backend_exe_subop_t s);
        return s inside {SUBOP_LR_W, SUBOP_LR_D};
    endfunction

    function automatic logic is_g3_sc_subop(backend_exe_subop_t s);
        return s inside {SUBOP_SC_W, SUBOP_SC_D};
    endfunction

    function automatic logic is_g3_fence_subop(backend_exe_subop_t s);
        return s inside {SUBOP_FENCE, SUBOP_FENCEI};
    endfunction

    function automatic logic is_g3_atomic_subop(backend_exe_subop_t s);
        return s inside {
            SUBOP_LR_W, SUBOP_SC_W, SUBOP_AMOSWAP_W, SUBOP_AMOADD_W, SUBOP_AMOXOR_W,
            SUBOP_AMOAND_W, SUBOP_AMOOR_W, SUBOP_AMOMIN_W, SUBOP_AMOMAX_W,
            SUBOP_AMOMINU_W, SUBOP_AMOMAXU_W,
            SUBOP_LR_D, SUBOP_SC_D, SUBOP_AMOSWAP_D, SUBOP_AMOADD_D, SUBOP_AMOXOR_D,
            SUBOP_AMOAND_D, SUBOP_AMOOR_D, SUBOP_AMOMIN_D, SUBOP_AMOMAX_D,
            SUBOP_AMOMINU_D, SUBOP_AMOMAXU_D
        };
    endfunction

    function automatic logic is_g3_amo_subop(backend_exe_subop_t s);
        return is_g3_atomic_subop(s) && !is_g3_lr_subop(s) && !is_g3_sc_subop(s);
    endfunction

    function automatic logic is_g3_subop(backend_exe_subop_t s);
        return is_g3_lsu_subop(s) || is_g3_atomic_subop(s) || is_g3_fence_subop(s);
    endfunction

    function automatic logic is_lsu_store_side(backend_exe_subop_t s);
        // Ordinary store, AMO, and SC perform a write-side
        // commit. LR is read-side only; fences have no memory write side.
        return is_g3_store_subop(s) || is_g3_amo_subop(s) || is_g3_sc_subop(s);
    endfunction

    // Used by CompletionScoreboard's early plain-store wakeup scan.  A zero
    // means this instruction class cannot later create an architectural flush;
    // all other classes are conservatively treated as unresolved until their
    // terminal normal completion has been observed.
    function automatic logic may_flush_before_resolution(backend_exe_subop_t s,
                                                         logic illegal_effective);
        return illegal_effective ||
               !(is_g0_alu0_subop(s) || is_g1_alu1_subop(s) ||
                 is_g0_div_subop(s)  || is_g1_mul_subop(s)  ||
                 is_g2_fpu_subop(s));
    endfunction

endpackage

`endif // EXE_SUBOP_PKG_SV
