`ifndef OR_BE_LSU_PROTOCOL_PKG_SV
`define OR_BE_LSU_PROTOCOL_PKG_SV

// Frozen OR-BE <-> LSU protocol schema.
//
// This package describes the OR-BE shape: one logical request per handshake,
// a 4-bit tag and 64-bit data.  It deliberately does not mirror the physical
// lane count or wide ROB pointer width of the reference environment; an
// adapter may fan the logical events out to such a model, but the OR-BE
// invariants (one G3 entry, 4-bit tag, 64-bit data and dual-retire
// scoreboard) remain outside this package.
package or_be_lsu_protocol_pkg;

    import exe_subop_pkg::*;

    localparam int LSU_TAG_W       = 4;
    // LSU capacity, frozen together with the protocol.
    //
    // The read side is a fixed AGU->cache pipeline: it never refuses a
    // request, so a load is never a reason to lower the acceptance line.
    // The write side is a buffer: a store-side request is refused only while
    // that buffer is full.  These two shapes are why acceptance has to be
    // qualified by the offered request's class rather than being a single
    // "busy" bit.
    localparam int LSU_LOAD_PIPE_STAGES   = 2;
    localparam int LSU_STORE_BUFFER_DEPTH = 4;
    localparam int LSU_DATA_W      = 64;
    localparam int LSU_EXE_SUBOP_W = 24;
    localparam int LSU_MEM_F3_W    = 3;
    // 架构 mcause 宽度（RV64 去掉 interrupt 位）。边界上直接按架构宽度
    // 传送，BE 侧不再做零扩展适配。
    localparam int LSU_CAUSE_W     = 63;

    typedef logic [LSU_TAG_W-1:0]       lsu_tag_t;
    typedef logic [LSU_DATA_W-1:0]      lsu_data_t;
    typedef logic [LSU_EXE_SUBOP_W-1:0] lsu_exe_subop_t;
    typedef logic [LSU_CAUSE_W-1:0]     lsu_cause_t;

    // Bit order is architectural: {load, store, amo, lr, sc, fence, fence_i}.
    // Exactly one bit is set for every legal G3 request.
    typedef struct packed {
        logic is_load;
        logic is_store;
        logic is_amo;
        logic is_lr;
        logic is_sc;
        logic is_fence;
        logic is_fence_i;
    } lsu_req_property_t;

    // BE 送入 LSU 的访存请求（schema_v3.md §1 `be_lsu_issue_pld_t`，226 bit）。
    // 地址生成与请求分类都在 LSU 内部完成，本 payload 只承载原料字段：BE 不
    // 计算 vaddr，也不计算 req_property——后者由 LSU 自己对 exe_subop 调用
    // req_property_from_subop() 得到。
    typedef struct packed {
        lsu_tag_t       tag;
        logic [LSU_DATA_W-1:0] rs1_data;
        logic           imm_valid;
        logic signed [LSU_DATA_W-1:0] imm_data;
        logic [LSU_DATA_W-1:0] store_data;
        logic [LSU_MEM_F3_W-1:0] mem_funct3;
        logic           rd_is_fp;
        lsu_exe_subop_t exe_subop;
        // CompletionScoreboard.st_br_resolve 的同拍快照，原样送入；是否与本次
        // 请求相关由 LSU 判断（只有 store 侧请求才看它）。
        logic           st_br_resolve;
    } be_lsu_issue_pld_t;

    // LSU 一次访存的终态回送（schema_v3.md §2，197 bit）。一次访存只回一次；
    // done_valid 与 exception_valid 互斥，tag 两种情况下都有效。
    typedef struct packed {
        lsu_tag_t   tag;
        logic       done_valid;
        lsu_data_t  data;
        logic       exception_valid;
        lsu_cause_t exception_cause;
        lsu_data_t  exception_tval;
    } lsu_be_writeback_pld_t;

    // read-side data 的独立复制线（schema_v3.md §3，68 bit）。必须与 writeback
    // 的 done_valid 同拍；异常时恒为 0。
    typedef struct packed {
        lsu_tag_t  tag;
        lsu_data_t data;
    } lsu_be_bypass_pld_t;

    // Logical memory operation names handed to the ISA model shim.
    typedef enum logic [4:0] {
        LSU_MEMOP_LOAD       = 5'd0,
        LSU_MEMOP_STORE      = 5'd1,
        LSU_MEMOP_LR         = 5'd2,
        LSU_MEMOP_SC         = 5'd3,
        LSU_MEMOP_AMOSWAP    = 5'd4,
        LSU_MEMOP_AMOADD     = 5'd5,
        LSU_MEMOP_AMOXOR     = 5'd6,
        LSU_MEMOP_AMOAND     = 5'd7,
        LSU_MEMOP_AMOOR      = 5'd8,
        LSU_MEMOP_AMOMIN     = 5'd9,
        LSU_MEMOP_AMOMAX     = 5'd10,
        LSU_MEMOP_AMOMINU    = 5'd11,
        LSU_MEMOP_AMOMAXU    = 5'd12,
        LSU_MEMOP_FENCE      = 5'd13,
        LSU_MEMOP_FENCE_I    = 5'd14,
        LSU_MEMOP_INVALID    = 5'd31
    } lsu_memop_t;

    function automatic lsu_req_property_t req_property_from_subop(
        input lsu_exe_subop_t s
    );
        lsu_req_property_t p;
        p = '0;
        if (is_g3_load_subop(s))       p.is_load   = 1'b1;
        else if (is_g3_store_subop(s)) p.is_store  = 1'b1;
        else if (is_g3_amo_subop(s))   p.is_amo    = 1'b1;
        else if (is_g3_lr_subop(s))    p.is_lr     = 1'b1;
        else if (is_g3_sc_subop(s))    p.is_sc     = 1'b1;
        else if (s == SUBOP_FENCE)     p.is_fence  = 1'b1;
        else if (s == SUBOP_FENCEI)    p.is_fence_i = 1'b1;
        return p;
    endfunction

    function automatic logic req_property_is_onehot(
        input lsu_req_property_t p
    );
        logic [6:0] bits;
        bits = p;
        return $onehot(bits);
    endfunction

    function automatic logic req_property_is_read_side(
        input lsu_req_property_t p
    );
        return p.is_load || p.is_lr || p.is_amo || p.is_sc;
    endfunction

    function automatic logic req_property_is_store_side(
        input lsu_req_property_t p
    );
        // AMO and SC have both a read side and a write side.
        return p.is_store || p.is_amo || p.is_sc;
    endfunction

    function automatic logic req_property_is_plain_store(
        input lsu_req_property_t p
    );
        return p.is_store;
    endfunction

    function automatic logic req_property_matches_subop(
        input lsu_req_property_t p,
        input lsu_exe_subop_t s
    );
        return req_property_is_onehot(p) && (p == req_property_from_subop(s));
    endfunction

    function automatic logic subop_is_fp_memory(
        input lsu_exe_subop_t s
    );
        return is_g3_fp_load_subop(s) || is_g3_fp_store_subop(s);
    endfunction

    function automatic logic subop_has_memory_access(
        input lsu_exe_subop_t s
    );
        return is_g3_load_subop(s) || is_g3_store_subop(s) ||
               is_g3_atomic_subop(s);
    endfunction

    // Return the canonical RISC-V memory funct3 for an OR-BE G3 subop.
    // RVC encoding funct3 selects the compressed opcode class, so compressed
    // load/store forms need explicit canonical values.
    function automatic logic [LSU_MEM_F3_W-1:0] canonical_mem_funct3_from_subop(
        input lsu_exe_subop_t s
    );
        case (s)
            SUBOP_C_LW, SUBOP_C_LWSP, SUBOP_C_SW, SUBOP_C_SWSP:
                return 3'b010;
            SUBOP_C_LD, SUBOP_C_LDSP, SUBOP_C_FLD, SUBOP_C_FLDSP,
            SUBOP_C_SD, SUBOP_C_SDSP, SUBOP_C_FSD, SUBOP_C_FSDSP:
                return 3'b011;
            default:
                return s[14:12];
        endcase
    endfunction

    function automatic logic mem_funct3_matches_subop(
        input logic [LSU_MEM_F3_W-1:0] f3,
        input lsu_exe_subop_t s
    );
        return !subop_has_memory_access(s) ||
               (f3 == canonical_mem_funct3_from_subop(s));
    endfunction

    function automatic logic [3:0] mem_funct3_bytes(
        input logic [LSU_MEM_F3_W-1:0] f3
    );
        case (f3)
            3'b000, 3'b100: return 4'd1;
            3'b001, 3'b101: return 4'd2;
            3'b010, 3'b110: return 4'd4;
            3'b011:         return 4'd8;
            default:        return 4'd0;
        endcase
    endfunction

    function automatic logic mem_funct3_unsigned(
        input logic [LSU_MEM_F3_W-1:0] f3
    );
        return f3 inside {3'b100, 3'b101, 3'b110};
    endfunction

    function automatic logic mem_funct3_valid(
        input logic [LSU_MEM_F3_W-1:0] f3
    );
        return (mem_funct3_bytes(f3) != 4'd0);
    endfunction

    function automatic lsu_memop_t lsu_memop_from_subop(
        input lsu_exe_subop_t s
    );
        if (is_g3_load_subop(s)) return LSU_MEMOP_LOAD;
        if (is_g3_store_subop(s)) return LSU_MEMOP_STORE;
        if (is_g3_lr_subop(s)) return LSU_MEMOP_LR;
        if (is_g3_sc_subop(s)) return LSU_MEMOP_SC;
        if (s == SUBOP_FENCE) return LSU_MEMOP_FENCE;
        if (s == SUBOP_FENCEI) return LSU_MEMOP_FENCE_I;
        case (s)
            SUBOP_AMOSWAP_W, SUBOP_AMOSWAP_D: return LSU_MEMOP_AMOSWAP;
            SUBOP_AMOADD_W,  SUBOP_AMOADD_D:  return LSU_MEMOP_AMOADD;
            SUBOP_AMOXOR_W,  SUBOP_AMOXOR_D:  return LSU_MEMOP_AMOXOR;
            SUBOP_AMOAND_W,  SUBOP_AMOAND_D:  return LSU_MEMOP_AMOAND;
            SUBOP_AMOOR_W,   SUBOP_AMOOR_D:   return LSU_MEMOP_AMOOR;
            SUBOP_AMOMIN_W,  SUBOP_AMOMIN_D:  return LSU_MEMOP_AMOMIN;
            SUBOP_AMOMAX_W,  SUBOP_AMOMAX_D:  return LSU_MEMOP_AMOMAX;
            SUBOP_AMOMINU_W, SUBOP_AMOMINU_D: return LSU_MEMOP_AMOMINU;
            SUBOP_AMOMAXU_W, SUBOP_AMOMAXU_D: return LSU_MEMOP_AMOMAXU;
            default:                          return LSU_MEMOP_INVALID;
        endcase
    endfunction

    function automatic logic subop_is_word(
        input lsu_exe_subop_t s
    );
        return s inside {
            SUBOP_LW, SUBOP_LWU, SUBOP_SW, SUBOP_FLW, SUBOP_FSW,
            SUBOP_LR_W, SUBOP_SC_W, SUBOP_AMOSWAP_W, SUBOP_AMOADD_W,
            SUBOP_AMOXOR_W, SUBOP_AMOAND_W, SUBOP_AMOOR_W, SUBOP_AMOMIN_W,
            SUBOP_AMOMAX_W, SUBOP_AMOMINU_W, SUBOP_AMOMAXU_W,
            SUBOP_C_LW, SUBOP_C_LWSP, SUBOP_C_SW, SUBOP_C_SWSP
        };
    endfunction

    function automatic logic subop_is_doubleword(
        input lsu_exe_subop_t s
    );
        return s inside {
            SUBOP_LD, SUBOP_SD, SUBOP_FLD, SUBOP_FSD,
            SUBOP_LR_D, SUBOP_SC_D, SUBOP_AMOSWAP_D, SUBOP_AMOADD_D,
            SUBOP_AMOXOR_D, SUBOP_AMOAND_D, SUBOP_AMOOR_D, SUBOP_AMOMIN_D,
            SUBOP_AMOMAX_D, SUBOP_AMOMINU_D, SUBOP_AMOMAXU_D,
            SUBOP_C_LD, SUBOP_C_LDSP, SUBOP_C_SD, SUBOP_C_SDSP,
            SUBOP_C_FLD, SUBOP_C_FLDSP, SUBOP_C_FSD, SUBOP_C_FSDSP
        };
    endfunction

endpackage

`endif
