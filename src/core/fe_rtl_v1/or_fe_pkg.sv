// or_fe_pkg: OR_FE common parameters, encodings, types and functions
// parameter values are placeholders for lint, actual values ⟨to confirm⟩.
package or_fe_pkg;

  // ---------------- parameters ----------------
  localparam int VA_W        = 39;                       // ⟨to confirm⟩
  localparam int PA_W        = 56;                       // ⟨to confirm⟩
  localparam int FETCH_BYTES = 32;
  localparam int OFF_W       = $clog2(FETCH_BYTES);
  localparam int SLOT_NUM    = FETCH_BYTES / 2;
  localparam int SLOT_W      = $clog2(SLOT_NUM);
  localparam int LINE_W      = 8 * FETCH_BYTES;
  localparam int IC_SETS     = 128;                      // OFF_W + IC_IDX_W <= 12
  localparam int IC_IDX_W    = $clog2(IC_SETS);
  localparam int IC_WAYS     = 4;
  localparam int IC_WAY_W    = (IC_WAYS > 1) ? $clog2(IC_WAYS) : 1;
  localparam int IC_TAG_W    = PA_W - IC_IDX_W - OFF_W;
  localparam int ITLB_NUM    = 16;
  localparam int ITLB_IDX_W  = (ITLB_NUM > 1) ? $clog2(ITLB_NUM) : 1;
  localparam int VPN_W       = VA_W - 12;
  localparam int PPN_W       = PA_W - 12;
  localparam int MSHR_NUM    = 4;
  localparam int MSHR_ID_W   = (MSHR_NUM > 1) ? $clog2(MSHR_NUM) : 1;
  localparam int BTB_SETS    = 256;
  localparam int BTB_IDX_W   = $clog2(BTB_SETS);
  localparam int BTB_WAYS    = 4;
  localparam int BTB_WAY_W   = (BTB_WAYS > 1) ? $clog2(BTB_WAYS) : 1;
  localparam int BTB_TAG_W   = VA_W - BTB_IDX_W - OFF_W;
  localparam int RAS_DEPTH   = 16;
  localparam int RAS_PTR_W   = $clog2(RAS_DEPTH);
  localparam int RAS_CNT_W   = RAS_PTR_W + 1;
  localparam int RAS_CQ_DEPTH = 32;                      // in-flight call/ret queue, ≥ Backend IB + ROB depth
  localparam int RAS_CQ_W    = $clog2(RAS_CQ_DEPTH);
  localparam int BPF_DEPTH   = 16;
  localparam int BPF_IDX_W   = $clog2(BPF_DEPTH);
  localparam int ISSUE_W     = 2;
  localparam int CAUSE_W     = 4;
  localparam int PMP_CFG_W   = 64;                       // ⟨to confirm⟩

  // ---------------- encodings ----------------
  typedef logic [2:0] bp_type_t;
  localparam bp_type_t BP_NO_BR   = 3'd0;
  localparam bp_type_t BP_BR      = 3'd1;
  localparam bp_type_t BP_JUMP    = 3'd2;
  localparam bp_type_t BP_FCALL   = 3'd3;
  localparam bp_type_t BP_FRET    = 3'd4;
  localparam bp_type_t BP_INJP    = 3'd5;
  localparam bp_type_t BP_FRC     = 3'd6;
  localparam bp_type_t BP_INFCALL = 3'd7;

  localparam logic [CAUSE_W-1:0] CAUSE_IAF = 4'd1;
  localparam logic [CAUSE_W-1:0] CAUSE_IPF = 4'd12;

  typedef logic [1:0] btb_wr_mode_t;
  localparam btb_wr_mode_t BTB_UPD   = 2'd0;
  localparam btb_wr_mode_t BTB_ALLOC = 2'd1;
  localparam btb_wr_mode_t BTB_CLR   = 2'd2;

  /* verilator lint_off UNUSEDPARAM */
  typedef logic [1:0] pg_lvl_t;
  localparam pg_lvl_t PG_4K = 2'd0;
  localparam pg_lvl_t PG_2M = 2'd1;
  localparam pg_lvl_t PG_1G = 2'd2;   // else branch of vpn_match / pa_of
  /* verilator lint_on UNUSEDPARAM */

  typedef logic [1:0] priv_t;
  localparam priv_t PRV_U = 2'd0;
  localparam priv_t PRV_S = 2'd1;
  localparam priv_t PRV_M = 2'd3;

  localparam logic [1:0] CTR_WT = 2'b10;

  // ---------------- RVC legality follows the platform ISA ----------------
  // only affects the legality decision of compressed encodings; must match isa_model's isa_string
  // (orbe_bt_env/dpi/rivai_0x80000000_1core_rom.yaml: rv64imafdc_zcb_zifencei_zicsr).
  // requirement: all 12 Zcb instructions supported.
  // RTL (this expander, BE SUBOP_C_*, ALU) implements all 12; the 4 that depend on Zbb / Zba are off by default because
  // the isa_model config does not enable Zbb / Zba; when the model enables Zbb / Zba, just set the corresponding switch to 1.
  localparam bit EXT_ZCB   = 1'b1;   // c.lbu/lhu/lh/sb/sh, c.zext.b, c.not, c.mul
  localparam bit EXT_ZBB   = 1'b0;   // needed by c.sext.b / c.zext.h / c.sext.h
  localparam bit EXT_ZBA   = 1'b0;   // needed by c.zext.w
  // Zcmop (c.mop.n, C.LUI with zero immediate and odd rd) not enabled and no expansion implemented: always illegal (C.LUI branch ill)

  // ---------------- types ----------------
  // product of Operand_Extract: register numbers are fixed slices of the expanded word; use_* / *_is_fp are not gated,
  // gating on illegal / fetch exception is done uniformly by the BE top-level glue logic. is_fp_opcode looks only at opcode.
  typedef struct packed {
    logic [4:0] rs1;
    logic [4:0] rs2;
    logic [4:0] rs3;
    logic [4:0] rd;
    logic       use_rs1;
    logic       use_rs2;
    logic       use_rs3;
    logic       use_rd;
    logic       rs1_is_fp;
    logic       rs2_is_fp;
    logic       rs3_is_fp;
    logic       rd_is_fp;
    logic       is_fp_opcode;
  } operand_info_t;

  typedef struct packed {
    logic [BTB_WAYS-1:0]             hit_w;
    logic [BTB_WAYS-1:0][SLOT_W-1:0] slot_w;
    logic [BTB_WAYS-1:0][1:0]        ctr_w;
    logic                            taken;
    logic [BTB_WAY_W-1:0]            tk_way;
    logic [SLOT_W-1:0]               tk_slot;
    bp_type_t                        tk_type;
    logic [VA_W-1:0]                 tk_target;
  } l1btb_meta_t;

  typedef struct packed {
    logic [VA_W-1:0]      pc;
    logic [31:0]          inst;       // expanded 32-bit instruction
    logic [31:0]          raw;        // original encoding: RVC only low 16 bits valid, upper bits zeroed; NOP for exception entry
    logic                 is_rvc;
    logic                 rvc_ill;
    operand_info_t        opnd;       // Operand_Extract (all 0 for exception entry)
    logic                 pred_taken;
    logic [VA_W-1:0]      pred_target;
    logic                 excp_vld;
    logic [CAUSE_W-1:0]   excp_cause;
    logic [VA_W-1:0]      excp_tval;  // faulting address of the fetch exception
    logic                 bpf_vld;
    logic [BPF_IDX_W-1:0] bpf_idx;
    logic [SLOT_W-1:0]    bpf_slot;
  } ib_inst_t;

  // ---------------- functions ----------------
  // truncation / decode functions use only part of the argument bits
  /* verilator lint_off UNUSEDSIGNAL */
  function automatic logic [VA_W-1:0] line_base(input logic [VA_W-1:0] pc);
    return {pc[VA_W-1:OFF_W], {OFF_W{1'b0}}};
  endfunction

  function automatic logic [SLOT_W-1:0] slot_of(input logic [VA_W-1:0] pc);
    return pc[OFF_W-1:1];
  endfunction

  function automatic logic [IC_IDX_W-1:0] ic_idx(input logic [VA_W-1:0] va);
    return va[OFF_W+IC_IDX_W-1:OFF_W];
  endfunction

  function automatic logic [IC_TAG_W-1:0] ic_tag(input logic [PA_W-1:0] pa);
    return pa[PA_W-1:OFF_W+IC_IDX_W];
  endfunction

  function automatic logic [BTB_IDX_W-1:0] btb_idx(input logic [VA_W-1:0] va);
    return va[OFF_W+BTB_IDX_W-1:OFF_W];
  endfunction

  function automatic logic [BTB_TAG_W-1:0] btb_tag(input logic [VA_W-1:0] va);
    return va[VA_W-1:OFF_W+BTB_IDX_W];
  endfunction

  function automatic logic [VPN_W-1:0] vpn_of(input logic [VA_W-1:0] va);
    return va[VA_W-1:12];
  endfunction

  function automatic logic is_rvc(input logic [15:0] h);
    return h[1:0] != 2'b11;
  endfunction

  function automatic logic is_link(input logic [4:0] r);
    return (r == 5'd1) || (r == 5'd5);
  endfunction

  function automatic logic [1:0] sat_ctr(input logic [1:0] c, input logic t);
    if (t) return (c == 2'b11) ? 2'b11 : c + 2'd1;
    else   return (c == 2'b00) ? 2'b00 : c - 2'd1;
  endfunction

  // RV64C expansion: returns {illegal, inst32}
  function automatic logic [32:0] rvc_dec(input logic [15:0] h);
    logic [31:0] i;
    logic        ill;
    logic [4:0]  rd, rs1, rs2, rdp, rs1p, rs2p;
    logic [11:0] imm6s;
    logic [20:0] jimm;
    logic [12:0] bimm;
    i    = 32'h0;
    ill  = 1'b0;
    rd   = h[11:7];
    rs1  = h[11:7];
    rs2  = h[6:2];
    rdp  = {2'b01, h[4:2]};
    rs1p = {2'b01, h[9:7]};
    rs2p = {2'b01, h[4:2]};
    imm6s = {{6{h[12]}}, h[12], h[6:2]};
    jimm = {{10{h[12]}}, h[8], h[10:9], h[6], h[7], h[2], h[11], h[5:3], 1'b0};
    bimm = {{5{h[12]}}, h[6:5], h[2], h[11:10], h[4:3], 1'b0};
    case (h[1:0])
      2'b00: begin
        case (h[15:13])
          3'b000: begin // C.ADDI4SPN
            i = {2'b00, h[10:7], h[12:11], h[5], h[6], 2'b00, 5'd2, 3'b000, rdp, 7'b0010011};
            ill = (h[12:5] == 8'd0);
          end
          3'b001: i = {4'b0, h[6:5], h[12:10], 3'b000, rs1p, 3'b011, rdp, 7'b0000111};           // C.FLD
          3'b010: i = {5'b0, h[5], h[12:10], h[6], 2'b00, rs1p, 3'b010, rdp, 7'b0000011};        // C.LW
          3'b011: i = {4'b0, h[6:5], h[12:10], 3'b000, rs1p, 3'b011, rdp, 7'b0000011};           // C.LD
          3'b100: begin                                                                          // Zcb load/store
            ill = !EXT_ZCB;
            case (h[12:10])
              3'b000: i = {10'b0, h[5], h[6], rs1p, 3'b100, rdp, 7'b0000011};                    // C.LBU
              3'b001: i = {10'b0, h[5], 1'b0, rs1p, (h[6] ? 3'b001 : 3'b101), rdp, 7'b0000011};  // C.LH / C.LHU
              3'b010: i = {7'b0, rs2p, rs1p, 3'b000, 3'b000, h[5], h[6], 7'b0100011};            // C.SB
              3'b011: begin                                                                      // C.SH
                i = {7'b0, rs2p, rs1p, 3'b001, 3'b000, h[5], 1'b0, 7'b0100011};
                ill = !EXT_ZCB || h[6];
              end
              default: ill = 1'b1;
            endcase
          end
          3'b101: i = {4'b0, h[6:5], h[12], rs2p, rs1p, 3'b011, h[11:10], 3'b000, 7'b0100111};   // C.FSD
          3'b110: i = {5'b0, h[5], h[12], rs2p, rs1p, 3'b010, h[11:10], h[6], 2'b00, 7'b0100011}; // C.SW
          3'b111: i = {4'b0, h[6:5], h[12], rs2p, rs1p, 3'b011, h[11:10], 3'b000, 7'b0100011};   // C.SD
          default: ill = 1'b1;
        endcase
      end
      2'b01: begin
        case (h[15:13])
          3'b000: i = {imm6s, rd, 3'b000, rd, 7'b0010011};                       // C.ADDI / C.NOP
          3'b001: begin                                                           // C.ADDIW
            i = {imm6s, rd, 3'b000, rd, 7'b0011011};
            ill = (rd == 5'd0);
          end
          3'b010: i = {imm6s, 5'd0, 3'b000, rd, 7'b0010011};                      // C.LI
          3'b011: begin
            if (rd == 5'd2) begin                                                 // C.ADDI16SP
              i = {{3{h[12]}}, h[4:3], h[5], h[2], h[6], 4'b0000, 5'd2, 3'b000, 5'd2, 7'b0010011};
              ill = ({h[12], h[6:2]} == 6'd0);
            end else begin                                                        // C.LUI
              i = {{15{h[12]}}, h[6:2], rd, 7'b0110111};
              ill = ({h[12], h[6:2]} == 6'd0);
            end
          end
          3'b100: begin
            case (h[11:10])
              2'b00: i = {6'b000000, h[12], h[6:2], rs1p, 3'b101, rs1p, 7'b0010011}; // C.SRLI
              2'b01: i = {6'b010000, h[12], h[6:2], rs1p, 3'b101, rs1p, 7'b0010011}; // C.SRAI
              2'b10: i = {imm6s, rs1p, 3'b111, rs1p, 7'b0010011};                    // C.ANDI
              default: begin
                case ({h[12], h[6:5]})
                  3'b000: i = {7'b0100000, rs2p, rs1p, 3'b000, rs1p, 7'b0110011};    // C.SUB
                  3'b001: i = {7'b0000000, rs2p, rs1p, 3'b100, rs1p, 7'b0110011};    // C.XOR
                  3'b010: i = {7'b0000000, rs2p, rs1p, 3'b110, rs1p, 7'b0110011};    // C.OR
                  3'b011: i = {7'b0000000, rs2p, rs1p, 3'b111, rs1p, 7'b0110011};    // C.AND
                  3'b100: i = {7'b0100000, rs2p, rs1p, 3'b000, rs1p, 7'b0111011};    // C.SUBW
                  3'b101: i = {7'b0000000, rs2p, rs1p, 3'b000, rs1p, 7'b0111011};    // C.ADDW
                  3'b110: begin                                                        // C.MUL (Zcb)
                    i = {7'b0000001, rs2p, rs1p, 3'b000, rs1p, 7'b0110011};
                    ill = !EXT_ZCB;
                  end
                  default: begin                                                       // Zcb single-operand
                    case (h[4:2])
                      3'b000: begin i = {12'h0ff, rs1p, 3'b111, rs1p, 7'b0010011};          ill = !EXT_ZCB;             end // C.ZEXT.B
                      3'b001: begin i = {12'b011000000100, rs1p, 3'b001, rs1p, 7'b0010011}; ill = !(EXT_ZCB && EXT_ZBB); end // C.SEXT.B
                      3'b010: begin i = {12'b000010000000, rs1p, 3'b100, rs1p, 7'b0111011}; ill = !(EXT_ZCB && EXT_ZBB); end // C.ZEXT.H
                      3'b011: begin i = {12'b011000000101, rs1p, 3'b001, rs1p, 7'b0010011}; ill = !(EXT_ZCB && EXT_ZBB); end // C.SEXT.H
                      3'b100: begin i = {12'b000010000000, rs1p, 3'b000, rs1p, 7'b0111011}; ill = !(EXT_ZCB && EXT_ZBA); end // C.ZEXT.W
                      3'b101: begin i = {12'hfff, rs1p, 3'b100, rs1p, 7'b0010011};          ill = !EXT_ZCB;             end // C.NOT
                      default: ill = 1'b1;
                    endcase
                  end
                endcase
              end
            endcase
          end
          3'b101: i = {jimm[20], jimm[10:1], jimm[11], jimm[19:12], 5'd0, 7'b1101111};             // C.J
          3'b110: i = {bimm[12], bimm[10:5], 5'd0, rs1p, 3'b000, bimm[4:1], bimm[11], 7'b1100011}; // C.BEQZ
          default: i = {bimm[12], bimm[10:5], 5'd0, rs1p, 3'b001, bimm[4:1], bimm[11], 7'b1100011}; // C.BNEZ
        endcase
      end
      2'b10: begin
        case (h[15:13])
          3'b000: i = {6'b000000, h[12], h[6:2], rd, 3'b001, rd, 7'b0010011};                   // C.SLLI
          3'b001: i = {3'b0, h[4:2], h[12], h[6:5], 3'b000, 5'd2, 3'b011, rd, 7'b0000111};      // C.FLDSP
          3'b010: begin                                                                          // C.LWSP
            i = {4'b0, h[3:2], h[12], h[6:4], 2'b00, 5'd2, 3'b010, rd, 7'b0000011};
            ill = (rd == 5'd0);
          end
          3'b011: begin                                                                          // C.LDSP
            i = {3'b0, h[4:2], h[12], h[6:5], 3'b000, 5'd2, 3'b011, rd, 7'b0000011};
            ill = (rd == 5'd0);
          end
          3'b100: begin
            if (!h[12]) begin
              if (rs2 == 5'd0) begin                                                             // C.JR
                i = {12'd0, rs1, 3'b000, 5'd0, 7'b1100111};
                ill = (rs1 == 5'd0);
              end else begin                                                                     // C.MV
                i = {7'b0000000, rs2, 5'd0, 3'b000, rd, 7'b0110011};
              end
            end else begin
              if ((rs1 == 5'd0) && (rs2 == 5'd0)) i = 32'h0010_0073;                            // C.EBREAK
              else if (rs2 == 5'd0) i = {12'd0, rs1, 3'b000, 5'd1, 7'b1100111};                  // C.JALR
              else i = {7'b0000000, rs2, rd, 3'b000, rd, 7'b0110011};                            // C.ADD
            end
          end
          3'b101: i = {3'b0, h[9:7], h[12], rs2, 5'd2, 3'b011, h[11:10], 3'b000, 7'b0100111};   // C.FSDSP
          3'b110: i = {4'b0, h[8:7], h[12], rs2, 5'd2, 3'b010, h[11:9], 2'b00, 7'b0100011};     // C.SWSP
          default: i = {3'b0, h[9:7], h[12], rs2, 5'd2, 3'b011, h[11:10], 3'b000, 7'b0100011};  // C.SDSP
        endcase
      end
      default: ill = 1'b1;
    endcase
    return {ill, i};
  endfunction

  function automatic logic [31:0] rvc_expand(input logic [15:0] h);
    logic [32:0] r;
    r = rvc_dec(h);
    return r[31:0];
  endfunction

  function automatic logic rvc_illegal(input logic [15:0] h);
    logic [32:0] r;
    r = rvc_dec(h);
    return r[32];
  endfunction

  // Operand_Extract: input is the expanded 32-bit instruction word, operand rules match BE decode instruction by instruction,
  // but no illegal gating (gated uniformly by backend_top glue logic using decode's illegal).
  function automatic operand_info_t operand_extract(input logic [31:0] i);
    operand_info_t o;
    logic [6:0] op, f7;
    logic [2:0] f3;
    logic       has_rd;
    op = i[6:0];
    f3 = i[14:12];
    f7 = i[31:25];
    o  = '0;
    o.rs1 = i[19:15];
    o.rs2 = i[24:20];
    o.rs3 = i[31:27];
    o.rd  = i[11:7];
    o.rs3_is_fp = 1'b1;                       // only FMA uses rs3, and it is always FP (BE convention use_rs3 ⇒ rs3_is_fp)
    has_rd = 1'b0;
    case (op)
      7'b0000011: begin o.use_rs1 = 1'b1; has_rd = 1'b1; end                         // LOAD
      7'b0000111: begin o.use_rs1 = 1'b1; has_rd = 1'b1; o.rd_is_fp = 1'b1; end      // LOAD-FP
      7'b0010011,                                                                     // OP-IMM
      7'b0011011,                                                                     // OP-IMM-32
      7'b1100111: begin o.use_rs1 = 1'b1; has_rd = 1'b1; end                         // JALR
      7'b0010111,                                                                     // AUIPC
      7'b0110111,                                                                     // LUI
      7'b1101111: has_rd = 1'b1;                                                      // JAL
      7'b0100011,                                                                     // STORE
      7'b1100011: begin o.use_rs1 = 1'b1; o.use_rs2 = 1'b1; end                      // BRANCH
      7'b0100111: begin o.use_rs1 = 1'b1; o.use_rs2 = 1'b1; o.rs2_is_fp = 1'b1; end  // STORE-FP
      7'b0101111: begin                                                               // AMO: LR has no rs2
        o.use_rs1 = 1'b1;
        o.use_rs2 = !((i[31:27] == 5'b00010) && (f3 inside {3'b010, 3'b011}));
        has_rd    = 1'b1;
      end
      7'b0110011,                                                                     // OP
      7'b0111011: begin o.use_rs1 = 1'b1; o.use_rs2 = 1'b1; has_rd = 1'b1; end       // OP-32
      7'b1000011, 7'b1000111, 7'b1001011, 7'b1001111: begin                           // FMA
        o.use_rs1 = 1'b1; o.use_rs2 = 1'b1; o.use_rs3 = 1'b1;
        o.rs1_is_fp = 1'b1; o.rs2_is_fp = 1'b1;
        has_rd = 1'b1; o.rd_is_fp = 1'b1;
      end
      7'b1010011: begin                                                               // OP-FP
        o.use_rs1   = 1'b1;
        o.rs1_is_fp = !(f7 inside {7'b1101000, 7'b1101001, 7'b1111000, 7'b1111001});
        o.use_rs2   = !(f7 inside {7'b0100000, 7'b0100001, 7'b0101100, 7'b0101101,
                                   7'b1100000, 7'b1100001, 7'b1101000, 7'b1101001,
                                   7'b1110000, 7'b1110001, 7'b1111000, 7'b1111001});
        o.rs2_is_fp = o.use_rs2;
        has_rd      = 1'b1;
        o.rd_is_fp  = !(f7 inside {7'b1100000, 7'b1100001, 7'b1110000, 7'b1110001,
                                   7'b1010000, 7'b1010001});
      end
      7'b1110011: begin                                                               // SYSTEM: only CSR forms have operands
        if ((f3 != 3'b000) && (f3 != 3'b100)) begin
          has_rd    = 1'b1;
          o.use_rs1 = (f3 inside {3'b001, 3'b010, 3'b011});
        end
      end
      default: ;
    endcase
    o.use_rd = has_rd && !((o.rd == 5'd0) && !o.rd_is_fp);                            // x0 suppression only for integer rd
    o.is_fp_opcode = op inside {7'b1010011, 7'b1000011, 7'b1000111, 7'b1001011,
                                7'b1001111, 7'b0000111, 7'b0100111};
    return o;
  endfunction

  function automatic bp_type_t bp_classify(input logic [31:0] i);
    logic jal, jalr, br;
    jal  = (i[6:0] == 7'b1101111);
    jalr = (i[6:0] == 7'b1100111) && (i[14:12] == 3'b000);
    br   = (i[6:0] == 7'b1100011);
    if (jal) return is_link(i[11:7]) ? BP_FCALL : BP_JUMP;
    if (jalr) begin
      if (is_link(i[11:7])) return (is_link(i[19:15]) && (i[19:15] != i[11:7])) ? BP_FRC : BP_INFCALL;
      else                  return is_link(i[19:15]) ? BP_FRET : BP_INJP;
    end
    if (br) return BP_BR;
    return BP_NO_BR;
  endfunction

  // signed offset in halfword units
  function automatic logic [VA_W-1:0] bp_imm(input logic [31:0] i);
    if (i[6:0] == 7'b1101111) return VA_W'($signed({i[31], i[19:12], i[20], i[30:21]}));
    if (i[6:0] == 7'b1100011) return VA_W'($signed({i[31], i[7], i[30:25], i[11:8]}));
    return '0;
  endfunction

  // ⟨to confirm⟩ PMP check: entry count and match mode undecided, currently never reports access fault
  function automatic logic pmp_af(input logic [PA_W-1:0] pa, input priv_t priv, input logic [PMP_CFG_W-1:0] cfg);
    logic unused;
    unused = ^{pa, priv, cfg};
    return 1'b0;
  endfunction

  /* verilator lint_on UNUSEDSIGNAL */

endpackage
