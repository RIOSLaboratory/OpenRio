`ifndef ALU_SIMPLE_SV
`define ALU_SIMPLE_SV

/* verilator lint_off IMPORTSTAR */
import or_be_types_pkg::*;
import exe_subop_pkg::*;
/* verilator lint_on IMPORTSTAR */

// alu_simple -- the G0 `ALU0/BRU` and the G1 `ALU1`, one source file, two
// instances (FU接入契约 §1, §6).
//
// This is the first-version `rtl/alu_simple.sv` re-fitted to the new
// architecture.  Per FU接入契约 §1 the boundary of the change is "端口与类型
// 改，数据通路一行不动": the ALU case table, the branch resolution and the
// mispredict decision below are copied verbatim; only the ports, the types and
// the three behavioural contracts of §2 are new.
//
// §1.2 draws the one exception to that: the first version predates RVC, and
// where it contradicts a microarchitecture document the document wins.  Two
// places therefore do NOT follow it -- `fallthrough_pc` (§1.2#1, A 类) and
// `exception_tval` (§1.2#2, B 类).  Both are marked at their definition.
//
// Role difference between the two instances (§1.1).  `mispredict_*`,
// `exception_*` and `is_mret` are driven by the G0 instance and are constant
// zero on the G1 instance.  That is NOT a parameter: dispatch_logic routes
// every branch / CSR / SYS / illegal instruction to G0, so the very same RTL
// sitting in the G1 slot only ever sees pure arithmetic subops and produces
// zero by itself.  The guarantee is therefore not self-checkable inside the FU,
// which is why §1.1 requires a simulation-only assertion -- see the `ifndef
// SYNTHESIS` block at the bottom.  `IS_G0` exists for that assertion and for
// nothing else; it must never reach functional logic.
//
// Handshake (§3.0).  `issue_valid` is a request line, not a fire line: the
// capture condition is `issue_valid && FU_ready`, and `FU_ready` must not
// depend combinationally on `issue_valid`.  Here `FU_ready = !loser_hold`,
// which depends only on the arbiter feedback, so the loop is not closed.
//
// Port sourcing.  There is no microarchitecture document for a library-external
// FU: FU接入契约 §3 (issue side, the G0 field list -- the G1 list is a strict
// subset of it, so the G1 instance simply leaves the branch / identity inputs
// tied off), §4.0 (the `predictor_update` edge to the front end) and §4
// (completion side, `req_` prefixed, straight into `p3_arbiter_G0` /
// `p3_arbiter_G1`) are its ⑥.
module alu_simple #(
    // Assertion-only (§1.1).  1 = this instance sits on G0, 0 = on G1.
    // Read by the `ifndef SYNTHESIS` routing check and by nothing else.
    parameter bit IS_G0 = 1'b1
) (
    input  logic                     clk,
    input  logic                     rst_n,

    // ------------------------------------------------------------------
    // in-event: flush (announce, single-wire pulse, no payload).  §2.1
    // ------------------------------------------------------------------
    input  logic                     global_flush_late,

    // ------------------------------------------------------------------
    // in-event: issue (transaction).  Request line + the §3 G0 field list;
    // `FU_Group` is the in-group FU index and the ALU is requester 0 in both
    // G0 and G1 (§1 table), so it is what tells this FU the instruction is
    // addressed to it.
    // ------------------------------------------------------------------
    input  logic                     issue_valid,
    input  logic [XLEN-1:0]          rs1_data,
    input  logic [XLEN-1:0]          rs2_data,
    input  logic [FU_GROUP_W-1:0]    FU_Group,
    input  logic [XLEN-1:0]          imm_data,
    input  logic [XLEN-1:0]          pc,
    input  logic [31:0]              inst_bits,
    input  logic                     is_compressed,
    input  logic                     pred_taken,
    input  logic [XLEN-1:0]          pred_target_pc,
    input  logic [TAG_W-1:0]         self_tag,
    input  logic [EXE_SUBOP_W-1:0]   exe_subop,
    input  logic [FULL_DECODE_W-1:0] full_decode,

    // 来自 system_instruction_handler（集成层 §1.2、FU接入契约 §3.1）。
    // **ECALL 的 cause 取决于当前特权级**，抛异常的地方才知道该给哪个。
    // G1 的 ALU1 实例收不到 SYS 类 subop，顶层接 PRIV_M 常量。
    input  logic [PRIV_W-1:0]        current_priv,
    // S9：M 态用来拦 S 态特权操作的两位（第三位 TVM 归 csr_unit）。
    input  logic                     mstatus_tsr,   // 拦 S 态的 SRET
    input  logic                     mstatus_tw,    // 拦 S 态的 WFI
    input  logic                     mstatus_tvm,   // 拦 S 态的 SFENCE.VMA

    // ④#7: the front end never fetched this PC, so `inst_bits` is garbage and
    // `exe_subop` is zero.  decode routed the entry here precisely so that it
    // can reach a completion lane and trap at the commit point -- an entry
    // whose terminal state came from nowhere would hang the scoreboard.
    // Tied to constant 0 on the G1 (ALU1) instance: G1 cannot raise an
    // exception at all, and decode never routes a fetch fault there.
    input  logic                     fetch_excp_vld,
    input  logic [FETCH_EXCP_CAUSE_W-1:0] fetch_excp_cause,
    input  logic [XLEN-1:0]          fetch_excp_tval,

    // ------------------------------------------------------------------
    // out: combinational read -- `FU_ready[FU_Group]` back to `ISQ_Group_g`
    // (§2.3).  Replaces the first version's `busy`, opposite polarity.
    // ------------------------------------------------------------------
    output logic                     FU_ready,

    // ------------------------------------------------------------------
    // out-event: completion request -> `p3_arbiter_G0` / `p3_arbiter_G1`
    // (§4).  The whole completion_common is registered one cycle behind
    // issue (§2.2); the zero fields are driven here, never by the arbiter
    // (§4.1).
    // ------------------------------------------------------------------
    output logic                     request_valid,
    output logic [TAG_W-1:0]         req_tag,
    output logic [XLEN-1:0]          req_result_data,
    output logic                     req_mispredict_flag,
    output logic [XLEN-1:0]          req_mispredict_target_pc,
    output logic                     req_exception_flag,
    output logic [EXCP_CAUSE_W-1:0]  req_exception_cause,
    output logic [XLEN-1:0]          req_exception_tval,
    output logic                     req_is_mret,
    // S9：与 req_is_mret 并列且互斥。G1 实例恒零（FU接入契约 §4.1）。
    output logic                     req_is_sret,
    output logic [FFLAGS_W-1:0]      req_fpu_fflags,

    // csr_sideband -- G0 only, and only the CSR FU drives non-zero values
    // (§4).  Driven to constant zero here rather than left to the arbiter,
    // per §4.1「恒零字段由 FU 驱动、仲裁器不补造」.  Unconnected on the G1
    // instance: `p3_arbiter_G1` carries no csr_sideband at all.
    output logic                     req_is_csr,
    output logic                     req_csr_write_enable,
    output logic [CSR_ADDR_W-1:0]    req_csr_addr,
    output logic [XLEN-1:0]          req_csr_wdata,

    // ------------------------------------------------------------------
    // out-event: predictor_update -> FE (§4.0, 集成层 §1.5).  Broadcast,
    // driven from the execute stage and NOT waiting for commit -- and NOT
    // routed through the arbiter: winning or losing in-group arbitration
    // does not change the branch outcome, which is already resolved, so
    // these five never hold and never retry.  Only the G0 instance ever
    // raises valid; ALU1 receives no branch subop, so on a G1 lane this is
    // naturally dead, by routing and not by parameter (§1.1).
    // ------------------------------------------------------------------
    output logic                     predictor_update_valid,
    output logic [XLEN-1:0]          predictor_update_branch_pc,
    output logic                     predictor_update_actual_taken,
    output logic [XLEN-1:0]          predictor_update_actual_target,
    output cf_class_e                predictor_update_cf_class,

    // ------------------------------------------------------------------
    // in: arbiter feedback (§4).  `winner_grant` is this requester's ready,
    // `loser_hold` says the request lost and must be held and retried.
    // ------------------------------------------------------------------
    input  logic                     winner_grant,
    input  logic                     loser_hold
);

    // The in-group FU index comes from the type package: `G0_FU_ALU` and
    // `G1_FU_ALU` are both 0 (§1 table), so one addressee test serves both
    // instances and no parameter is needed.
    // ------------------------------------------------------------------
    // §3.0 handshake and §2.3 FU_ready
    //
    //   FU_ready     = !loser_hold
    //   issue_fire   = issue_valid & FU_ready & addressed-to-me & !flush
    //
    // The ALU never lowers ready because it is busy executing -- it is done
    // in one cycle -- but it must lower it while it is holding a completion
    // request that lost arbitration, because the output register is still
    // occupied by the previous result (§2.3 的「外加一条」).  `FU_ready`
    // reads only arbiter feedback, never `issue_valid`, so no loop is
    // formed (§3.0 铁律 1).
    // ------------------------------------------------------------------
    assign FU_ready = !loser_hold;

    logic issue_fire;
    assign issue_fire = issue_valid && FU_ready &&
                        (FU_Group == FU_GROUP_W'(G0_FU_ALU)) && !global_flush_late;

    // `winner_ack[k] = winner_grant[k] & !global_flush_late` is formed inside
    // the FU, not in the arbiter (p3_arbiter_G1 ⑥ header).
    logic winner_ack;
    logic hold_request;

    // ------------------------------------------------------------------
    // Data path -- copied verbatim from the first version.  Only the subop
    // constant names changed (§5: the frozen `exe_subop_pkg` spells them
    // `SUBOP_*`; `orca_types`' `ALU_*` / `BRU_*` names do not exist), and
    // `en` became `issue_fire`.  The single deviation in this block is
    // `fallthrough_pc`, which §1.2#1 corrects for RVC.
    // ------------------------------------------------------------------
    logic [XLEN-1:0] alu_result;
    logic [XLEN-1:0] branch_target;
    logic [XLEN-1:0] fallthrough_pc;
    logic [XLEN-1:0] correct_pc;
    logic            branch_taken;
    logic            is_bru_op;
    logic            mispredict_flag;
    logic            is_illegal_op;
    logic            is_ecall_op;
    logic            is_ebreak_op;
    logic            is_mret_op;
    logic            is_sret_op;

    // `illegal` has no subop of its own in the frozen package -- it rides
    // full_decode[15] (or_be_types_pkg full_decode_t, ISQ_Group0 ⑤「ILLEGAL
    // 消费 illegal」).  The G1 instance has no full_decode source, so this is
    // constant 0 there, which is exactly the §1.1 requirement.
    full_decode_t fd;
    assign fd = full_decode_t'(full_decode);

    // xRET 的特权检查（S9）。MRET 只能在 M 态执行，SRET 只能在 M 或 S 态。
    // **在低特权级执行是非法指令，不是静默执行。**
    // S9 之前这两条一个都没查：M-only 时不可能违反，加了 U 态之后就是缺口了
    // ——`mret` 从 U 态执行会静默把机器拉回 M，是个提权漏洞。
    // 本核不实现 mstatus.TSR（恒 0），所以 S 态执行 SRET 合法。
    logic            xret_priv_bad;
    assign xret_priv_bad =
        ((exe_subop == SUBOP_MRET) && (current_priv != 2'b11)) ||
        ((exe_subop == SUBOP_SRET) && (current_priv == 2'b00)) ||
        // TSR：M 态置起后，S 态执行 SRET 是非法指令（规范）。
        ((exe_subop == SUBOP_SRET) && (current_priv == 2'b01) && mstatus_tsr);

    // SFENCE.VMA 的特权判据（bt 给的语义）：
    //   U 态          → 非法
    //   S 态 且 TVM=1 → 非法
    //   S 态 且 TVM=0 → 合法
    //   M 态          → 合法
    // 合法时本模块**什么都不做**：后端没有 TLB，可刷的东西不在这里。
    // 「把刷新传播给外部 MMU」是 BE_LSU 契约层的事，见该模块头注释。
    logic sfence_blocked;
    assign sfence_blocked = (exe_subop == SUBOP_SFENCE_VMA)
                         && ((current_priv == 2'b00)
                             || ((current_priv == 2'b01) && mstatus_tvm));

    // TW：M 态置起后，比 M 低的特权级执行 WFI 是非法指令（规范）。
    // 没有它的话 WFI 落 default 变成 NOP —— 那在 TW=1 时是错的。
    logic wfi_blocked;
    assign wfi_blocked = (exe_subop == SUBOP_WFI)
                      && (current_priv != 2'b11) && mstatus_tw;

    assign is_illegal_op = issue_fire
                        && (fd.illegal || xret_priv_bad || wfi_blocked || sfence_blocked);
    assign is_ecall_op   = issue_fire && (exe_subop == SUBOP_ECALL);
    // EBREAK：断点异常，cause 3。**两种编码都要认** —— 32 位的 EBREAK 与
    // 压缩的 C.EBREAK 是两个子码，漏掉任一个都会让它落 default 静默当 NOP。
    // 这一条 2026-08-25 之前**根本没实现**：子码在 is_g0_sys_subop 里、
    // 正常路由到本 FU，但这里没有任何分支认它，于是 `ebreak` 什么都不做。
    // 122 例回归零覆盖（riscv-tests 的 -p- 用例不执行 ebreak），
    // 是 subop/check_subop_coverage.py 机械查出来的。
    assign is_ebreak_op  = issue_fire && ((exe_subop == SUBOP_EBREAK) ||
                                          (exe_subop == SUBOP_C_EBREAK));
    // 特权不足时不认它是 xRET —— 那一拍它是非法指令，走 ILLEGAL 路径。
    assign is_mret_op    = issue_fire && (exe_subop == SUBOP_MRET) && !xret_priv_bad;
    assign is_sret_op    = issue_fire && (exe_subop == SUBOP_SRET) && !xret_priv_bad;
    // **WFI 实现为 NOP，靠的是「没有 case 分支」而不是一根信号。**
    // SUBOP_WFI 不匹配任何运算 arm，落 default 得 result_data = 0，
    // 事件字段全 0，正常完成、正常提交 —— 这就是 NOP。
    // 规范明确允许 WFI 实现成 NOP；本环境也必须这么做：中断由软件写
    // mip.SSIP 产生，没有异步源，真挂起等中断会死锁。
    // 它**不能**被当成非法指令丢掉：riscv-tests 的 S 态段在 wfi 之后还有代码。
    // 能走到这里的前提是冻结包 v4 把 SUBOP_WFI 并进了 is_g0_sys_subop，
    // 否则 dispatch_logic 判它 ROUTE_UNSUPPORTED，后果是挂死不是 trap。

    // §1.2#1 -- the first version hard-wired `pc + 4`.  ISQ_Group0 ⑤:
    // 「BRU 按 `is_compressed` 算链接地址与分支 fall-through 目标（压缩取
    // `pc + 2`、否则 `pc + 4`）」.  This one signal feeds both uses: the
    // not-taken branch target below and the JAL / JALR link address written
    // into result_data, so both follow ENABLE_C here.
    assign fallthrough_pc = is_compressed ? (pc + 64'd2) : (pc + 64'd4);

    function automatic logic [63:0] sext32(input logic [31:0] value);
        return {{32{value[31]}}, value};
    endfunction

    always_comb begin
        alu_result = '0;
        case (exe_subop)
            SUBOP_ADD:   alu_result = rs1_data + rs2_data;
            SUBOP_ADDI:  alu_result = rs1_data + imm_data;
            SUBOP_SUB:   alu_result = rs1_data - rs2_data;
            SUBOP_AND:   alu_result = rs1_data & rs2_data;
            SUBOP_ANDI:  alu_result = rs1_data & imm_data;
            SUBOP_OR:    alu_result = rs1_data | rs2_data;
            SUBOP_ORI:   alu_result = rs1_data | imm_data;
            SUBOP_XOR:   alu_result = rs1_data ^ rs2_data;
            SUBOP_XORI:  alu_result = rs1_data ^ imm_data;
            SUBOP_SLL:   alu_result = rs1_data << rs2_data[5:0];
            SUBOP_SLLI:  alu_result = rs1_data << imm_data[5:0];
            SUBOP_SRL:   alu_result = rs1_data >> rs2_data[5:0];
            SUBOP_SRLI:  alu_result = rs1_data >> imm_data[5:0];
            SUBOP_SRA:   alu_result = $signed(rs1_data) >>> rs2_data[5:0];
            SUBOP_SRAI:  alu_result = $signed(rs1_data) >>> imm_data[5:0];
            SUBOP_SLT:   alu_result = ($signed(rs1_data) < $signed(rs2_data)) ? 64'd1 : 64'd0;
            SUBOP_SLTI:  alu_result = ($signed(rs1_data) < $signed(imm_data)) ? 64'd1 : 64'd0;
            SUBOP_SLTU:  alu_result = (rs1_data < rs2_data) ? 64'd1 : 64'd0;
            SUBOP_SLTIU: alu_result = (rs1_data < imm_data) ? 64'd1 : 64'd0;
            SUBOP_LUI:   alu_result = imm_data;
            SUBOP_AUIPC: alu_result = pc + imm_data;

            SUBOP_ADDIW: alu_result = sext32(rs1_data[31:0] + imm_data[31:0]);
            SUBOP_ADDW:  alu_result = sext32(rs1_data[31:0] + rs2_data[31:0]);
            SUBOP_SUBW:  alu_result = sext32(rs1_data[31:0] - rs2_data[31:0]);
            SUBOP_SLLIW: alu_result = sext32(rs1_data[31:0] << imm_data[4:0]);
            SUBOP_SLLW:  alu_result = sext32(rs1_data[31:0] << rs2_data[4:0]);
            SUBOP_SRLIW: alu_result = sext32(rs1_data[31:0] >> imm_data[4:0]);
            SUBOP_SRLW:  alu_result = sext32(rs1_data[31:0] >> rs2_data[4:0]);
            SUBOP_SRAIW: alu_result = sext32($signed(rs1_data[31:0]) >>> imm_data[4:0]);
            SUBOP_SRAW:  alu_result = sext32($signed(rs1_data[31:0]) >>> rs2_data[4:0]);

            // ---- 压缩形态 (C 扩展) ------------------------------------
            // 冻结包把 SUBOP_C_* 归进 is_g0_alu0_subop / is_g1_alu1_subop，
            // 所以它们**会流到本 FU**，不是展开成基础 subop 再来的。
            // 第一版没有这些分支，全落 default → 结果恒 0，静默错。
            //
            // 操作数不用另算：decode 先用 rvc_decompress_rv64() 展开成 32 位，
            // 再从展开形态取 rs1/rs2/rd/imm，所以到这里的操作数已经是对的，
            // 本表只需说明「是哪一种运算」。
            SUBOP_C_ADDI4SPN,          // addi rd', x2, nzuimm
            SUBOP_C_ADDI16SP,          // addi x2, x2, nzimm
            SUBOP_C_ADDI,              // addi rd, rd, nzimm
            SUBOP_C_LI:                // addi rd, x0, imm   (rs1 = x0)
                         alu_result = rs1_data + imm_data;
            SUBOP_C_NOP: alu_result = '0;   // addi x0,x0,0，rd = x0 不写回
            SUBOP_C_LUI: alu_result = imm_data;
            SUBOP_C_ADDIW: alu_result = sext32(rs1_data[31:0] + imm_data[31:0]);
            SUBOP_C_SLLI:  alu_result = rs1_data << imm_data[5:0];
            SUBOP_C_SRLI:  alu_result = rs1_data >> imm_data[5:0];
            SUBOP_C_SRAI:  alu_result = $signed(rs1_data) >>> imm_data[5:0];
            SUBOP_C_ANDI:  alu_result = rs1_data & imm_data;
            SUBOP_C_MV,                // add rd, x0, rs2    (rs1 = x0)
            SUBOP_C_ADD: alu_result = rs1_data + rs2_data;
            SUBOP_C_SUB: alu_result = rs1_data - rs2_data;
            SUBOP_C_AND: alu_result = rs1_data & rs2_data;
            SUBOP_C_OR:  alu_result = rs1_data | rs2_data;
            SUBOP_C_XOR: alu_result = rs1_data ^ rs2_data;
            SUBOP_C_ADDW: alu_result = sext32(rs1_data[31:0] + rs2_data[31:0]);
            SUBOP_C_SUBW: alu_result = sext32(rs1_data[31:0] - rs2_data[31:0]);

            SUBOP_ECALL: alu_result = '0;
            default:     alu_result = '0;
        endcase
    end

    always_comb begin
        is_bru_op = is_g0_bru_subop(exe_subop);
        branch_taken = 1'b0;
        branch_target = fallthrough_pc;

        unique case (exe_subop)
            SUBOP_JAL,
            SUBOP_C_J: begin          // jal x0, offset
                branch_taken = 1'b1;
                branch_target = pc + imm_data;
            end
            SUBOP_JALR,
            SUBOP_C_JR,               // jalr x0, 0(rs1)
            SUBOP_C_JALR: begin       // jalr x1, 0(rs1)
                branch_taken = 1'b1;
                branch_target = (rs1_data + imm_data) & ~64'd1;
            end
            SUBOP_BEQ,
            SUBOP_C_BEQZ: begin       // beq rs1', x0, offset  (rs2 = x0)
                branch_taken = (rs1_data == rs2_data);
                branch_target = pc + imm_data;
            end
            SUBOP_BNE,
            SUBOP_C_BNEZ: begin       // bne rs1', x0, offset  (rs2 = x0)
                branch_taken = (rs1_data != rs2_data);
                branch_target = pc + imm_data;
            end
            SUBOP_BLT: begin
                branch_taken = ($signed(rs1_data) < $signed(rs2_data));
                branch_target = pc + imm_data;
            end
            SUBOP_BGE: begin
                branch_taken = ($signed(rs1_data) >= $signed(rs2_data));
                branch_target = pc + imm_data;
            end
            SUBOP_BLTU: begin
                branch_taken = (rs1_data < rs2_data);
                branch_target = pc + imm_data;
            end
            SUBOP_BGEU: begin
                branch_taken = (rs1_data >= rs2_data);
                branch_target = pc + imm_data;
            end
            default: begin
                branch_taken = 1'b0;
                branch_target = fallthrough_pc;
            end
        endcase
    end

    assign correct_pc = branch_taken ? branch_target : fallthrough_pc;

    // ------------------------------------------------------------------
    // §4.0: `cf_class` is produced by the BRU from `exe_subop`.  The three
    // sets below are exactly the partition of `is_g0_bru_subop()`'s thirteen
    // members -- 8 conditional + 2 direct + 3 indirect -- so every subop that
    // raises `is_bru_op` gets a real class and `CF_RESERVED` only ever shows
    // up on non-control-flow instructions, where valid is 0 anyway.  C_JAL is
    // RV32-only and has no constant in the frozen package.  There is no
    // call / return class: 集成层 §1.5 says this backend has no RAS.
    // ------------------------------------------------------------------
    cf_class_e cf_class;

    always_comb begin
        unique case (exe_subop)
            SUBOP_BEQ, SUBOP_BNE, SUBOP_BLT,
            SUBOP_BGE, SUBOP_BLTU, SUBOP_BGEU,
            SUBOP_C_BEQZ, SUBOP_C_BNEZ:            cf_class = CF_COND_BRANCH;
            SUBOP_JAL, SUBOP_C_J:                  cf_class = CF_JUMP_DIRECT;
            SUBOP_JALR, SUBOP_C_JR, SUBOP_C_JALR:  cf_class = CF_JUMP_INDIRECT;
            default:                               cf_class = CF_RESERVED;
        endcase
    end
    assign mispredict_flag = is_bru_op &&
                             ((branch_taken != pred_taken) ||
                              (branch_taken && (pred_target_pc != branch_target)));

    // ------------------------------------------------------------------
    // §2.2 completion is registered one cycle behind issue -- and it is the
    // whole `completion_common` that is registered, not just the valid.
    // §2.1 flush kills whatever is in flight, unconditionally and without a
    // tag compare.  Priority: flush > hold-after-losing > accept > idle.
    // ------------------------------------------------------------------
    completion_common_t comp_q;

    assign winner_ack   = winner_grant && !global_flush_late;
    assign hold_request = comp_q.result_valid && !winner_ack;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            comp_q <= '0;
        end else if (global_flush_late) begin
            comp_q <= '0;
        end else if (hold_request) begin
            // Lost arbitration: freeze the entire request and retry next
            // cycle.  FU_ready is 0 this cycle, so nothing can overwrite it.
            comp_q <= comp_q;
        end else begin
            comp_q <= '0;

            if (issue_fire) begin
                comp_q.result_valid         <= 1'b1;
                comp_q.tag_out              <= self_tag;
                comp_q.mispredict_flag      <= mispredict_flag;
                comp_q.mispredict_target_pc <= correct_pc;
                // ④#7 priority: fetch > illegal > ecall.  A fetch fault
                // outranks illegal because decode *sets* full_decode.illegal
                // for it (that is how it gets routed here at all), so both
                // conditions are true at once and only this order reports
                // the real cause.  Nothing outranks the fetch fault: it
                // happened strictly before the encoding was ever read.
                comp_q.exception_flag       <= fetch_excp_vld || is_illegal_op
                                            || is_ecall_op || is_ebreak_op;
                comp_q.exception_cause      <= fetch_excp_vld ?
                                                 EXCP_CAUSE_W'(fetch_excp_cause) :
                                               is_illegal_op ? EXCP_CAUSE_W'(2)  :
                                               // M 态 ECALL = 11，U 态 = 8。
                                               // 写死 11 是第一版 M-only 时的遗留；
                                               // riscv-tests 的测试体跑在 U 态。
                                               // ECALL 的 cause 取决于当前特权级
                                               // （FU接入契约 §3.1）：U=8 / S=9 / M=11
                                               is_ecall_op   ?
                                                 ((current_priv == 2'b00) ?
                                                    EXCP_CAUSE_W'(8) :
                                                  (current_priv == 2'b01) ?
                                                    EXCP_CAUSE_W'(9) :
                                                    EXCP_CAUSE_W'(11)) :
                                               // 断点，与特权级无关
                                               is_ebreak_op  ? EXCP_CAUSE_W'(3) :
                                                               EXCP_CAUSE_W'(0);
                // §1.2#2 / ISQ_Group0 ⑤: an illegal instruction's tval is
                // the faulting instruction's own encoding, and a compressed
                // one contributes only its low 16 bits (`is_compressed` says
                // which).  This is the sole consumer of `inst_bits`.  ECALL
                // keeps tval = 0.
                // A fetch fault's tval is the faulting *address*, not an
                // encoding -- there is no encoding.  It is not always equal
                // to `pc`: when only the second halfword of a 4-byte
                // instruction faults, the spec puts pc in mepc and pc+2 in
                // mtval, which is why this is carried rather than derived.
                // EBREAK 的 tval 取**出错指令自己的 PC**，不是 0。
                // 规范对断点的 mtval 两种都允许，这里跟参考模型走：
                // isa_model 的 InsnImpl<EBREAK>::calc 是
                // `trap.trigger(TrapType::BREAK_POINT, insn.inst_pc)`。
                comp_q.exception_tval       <= fetch_excp_vld ? fetch_excp_tval :
                                               is_illegal_op ?
                                               (is_compressed ? {48'b0, inst_bits[15:0]}
                                                              : {32'b0, inst_bits}) :
                                               is_ebreak_op  ? pc :
                                               '0;
                comp_q.is_mret              <= is_mret_op;
                comp_q.is_sret              <= is_sret_op;
                // §4.1: G0 must drive fpu_fflags to zero itself.
                comp_q.fpu_fflags           <= '0;

                if (is_bru_op) begin
                    // 写链接地址的形态：JAL / JALR 与它们的**压缩对应**。
                    // C_J / C_BEQZ / C_BNEZ 不写 rd（rd = x0），落 '0 即可；
                    // C_JR 是 jalr x0（不写），C_JALR 是 jalr x1（要写）。
                    // 第一版只认非压缩两个，压缩形态的 ra 会写成 0。
                    comp_q.result_data <=
                        ((exe_subop == SUBOP_JAL)   || (exe_subop == SUBOP_JALR) ||
                         (exe_subop == SUBOP_C_J)   || (exe_subop == SUBOP_C_JR) ||
                         (exe_subop == SUBOP_C_JALR)) ? fallthrough_pc : '0;
                end else begin
                    comp_q.result_data <= alu_result;
                end
            end
        end
    end

    // ------------------------------------------------------------------
    // §4 completion request out.  §2.1: on the flush cycle the FU must not
    // drive request_valid, so the trigger is gated combinationally as well
    // as cleared in the register above.
    // ------------------------------------------------------------------
    assign request_valid            = comp_q.result_valid && !global_flush_late;
    assign req_tag                  = comp_q.tag_out;
    assign req_result_data          = comp_q.result_data;
    assign req_mispredict_flag      = comp_q.mispredict_flag;
    assign req_mispredict_target_pc = comp_q.mispredict_target_pc;
    assign req_exception_flag       = comp_q.exception_flag;
    assign req_exception_cause      = comp_q.exception_cause;
    assign req_exception_tval       = comp_q.exception_tval;
    assign req_is_mret              = comp_q.is_mret;
    assign req_is_sret              = comp_q.is_sret;
    assign req_fpu_fflags           = comp_q.fpu_fflags;

    // csr_sideband: this FU is not the CSR FU, so it drives the layer to zero
    // itself (§4, §4.1).
    assign req_is_csr               = 1'b0;
    assign req_csr_write_enable     = 1'b0;
    assign req_csr_addr             = '0;
    assign req_csr_wdata            = '0;

    // ------------------------------------------------------------------
    // §4.0 predictor_update -- registered one cycle behind issue, the same
    // cycle as the completion request, but on its own path: no arbiter, no
    // `winner_grant` / `loser_hold`, no hold-and-retry.  A resolved branch
    // trains the predictor exactly once, whether or not its completion won
    // that cycle.  The payload tracks the issue cycle unconditionally; only
    // `valid` says whether it means anything.
    // ------------------------------------------------------------------
    logic            pu_valid_q;
    logic [XLEN-1:0] pu_branch_pc_q;
    logic            pu_actual_taken_q;
    logic [XLEN-1:0] pu_actual_target_q;
    cf_class_e       pu_cf_class_q;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pu_valid_q         <= 1'b0;
            pu_branch_pc_q     <= '0;
            pu_actual_taken_q  <= 1'b0;
            pu_actual_target_q <= '0;
            pu_cf_class_q      <= cf_class_e'('0);
        end else begin
            // `issue_fire` already excludes the flush cycle (§2.1), so a
            // flushed instruction can never load a valid here.
            pu_valid_q         <= issue_fire && is_bru_op;
            pu_branch_pc_q     <= pc;
            pu_actual_taken_q  <= branch_taken;
            // taken -> branch_target, not-taken -> fall-through; that is
            // exactly `correct_pc`, which follows is_compressed (§1.2#1).
            pu_actual_target_q <= correct_pc;
            pu_cf_class_q      <= cf_class;
        end
    end

    // §4.0 requirement 5: the flush cycle must not drive this valid either.
    assign predictor_update_valid         = pu_valid_q && !global_flush_late;
    assign predictor_update_branch_pc     = pu_branch_pc_q;
    assign predictor_update_actual_taken  = pu_actual_taken_q;
    assign predictor_update_actual_target = pu_actual_target_q;
    assign predictor_update_cf_class      = pu_cf_class_q;

`ifndef SYNTHESIS
    // ------------------------------------------------------------------
    // §1.1 routing self-check -- simulation only.  The G1 instance's event
    // fields are zero *because dispatch_logic routes every branch / CSR /
    // SYS / illegal instruction to G0*, and that guarantee cannot be checked
    // from inside the FU.  If this instance sits on a G1 lane and still
    // drives one of them, the routing is broken and a mispredict would
    // otherwise be pushed silently into the lane the SCB reads as G1.
    //
    // IS_G0 is read here and nowhere else.
    // ------------------------------------------------------------------
    always_ff @(posedge clk) begin
        // **加了新的事件字段就要加到这里。** S9 加 is_sret 时，
        // FU接入契约 §4.1 的恒零表改了三行，这条断言却漏了 ——
        // 于是「G1 驱动了 is_sret」这件事没有任何东西会报。
        if (!IS_G0 && comp_q.result_valid &&
            (comp_q.mispredict_flag || comp_q.exception_flag ||
             comp_q.is_mret || comp_q.is_sret)) begin
            $error("[ALU1] event field driven on a G1 lane: mispredict=%0b exception=%0b is_mret=%0b is_sret=%0b tag=%0d -- dispatch routing is broken",
                   comp_q.mispredict_flag, comp_q.exception_flag,
                   comp_q.is_mret, comp_q.is_sret, comp_q.tag_out);
            $stop;
        end
    end

    // §4.0 classifier completeness.  The cf_class partition above is written
    // against today's `is_g0_bru_subop()` membership; if that frozen set ever
    // gains a member the classifier would silently ship CF_RESERVED to the
    // predictor.  Catch the drift instead.
    always_ff @(posedge clk) begin
        if (predictor_update_valid &&
            (predictor_update_cf_class == CF_RESERVED)) begin
            $error("[BRU] predictor_update with CF_RESERVED: exe_subop=%0h is a BRU subop with no cf_class arm",
                   exe_subop);
            $stop;
        end
    end

    // Kept from the first version.  §2.1 allows it explicitly and says what
    // it is: an assertion, not function.  One cycle after a flush nothing may
    // still be in flight.
    logic flush_late_q;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            flush_late_q <= 1'b0;
        end else begin
            flush_late_q <= global_flush_late;
            if (flush_late_q && comp_q.result_valid) begin
                $error("[ALU] stale state after flush: result_valid=%0b tag=%0d",
                       comp_q.result_valid, comp_q.tag_out);
                $stop;
            end
        end
    end
`endif

endmodule
`endif // ALU_SIMPLE_SV
