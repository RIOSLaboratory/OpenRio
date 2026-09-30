`ifndef ALU_SIMPLE_SV
`define ALU_SIMPLE_SV

/* verilator lint_off IMPORTSTAR */
import or_be_types_pkg::*;
import exe_subop_pkg::*;
/* verilator lint_on IMPORTSTAR */

// alu_simple -- the G0 `ALU0/BRU` and the G1 `ALU1`, one source file, two
// instances.
//
// The module consists of the ALU case table, the branch resolution and the
// mispredict decision, wrapped in the ports, the types and the three
// behavioural contracts.
//
// Two places are RVC-aware -- `fallthrough_pc` and `exception_tval`.  Both
// are marked at their definition.
//
// Role difference between the two instances.  `mispredict_*`,
// `exception_*`, `is_mret` and `is_sret` are driven by the G0 instance and are constant
// zero on the G1 instance.  That is NOT a parameter: dispatch_logic routes
// every branch / CSR / SYS / illegal instruction to G0, so the very same RTL
// sitting in the G1 slot only ever sees pure arithmetic subops and produces
// zero by itself.  The guarantee is therefore not self-checkable inside the FU,
// which is why a simulation-only assertion is required -- see the `ifndef
// SYNTHESIS` block at the bottom.  `IS_G0` exists for that assertion and for
// nothing else; it must never reach functional logic.
//
// Handshake.  `issue_valid` is a request line, not a fire line: the
// capture condition is `issue_valid && FU_ready`, and `FU_ready` must not
// depend combinationally on `issue_valid`.  Here `FU_ready = !loser_hold`,
// which depends only on the arbiter feedback, so the loop is not closed.
//
// Port sourcing.  The issue side is the G0 field list -- the G1 list is a
// strict subset of it, so the G1 instance simply leaves the branch / identity
// inputs tied off; `predictor_update` is the edge to the front end; the
// completion side is `req_` prefixed, straight into `p3_arbiter_G0` /
// `p3_arbiter_G1`.
module alu_simple #(
    // Assertion-only.  1 = this instance sits on G0, 0 = on G1.
    // Read by the `ifndef SYNTHESIS` routing check and by nothing else.
    parameter bit IS_G0 = 1'b1
) (
    input  logic                     clk,
    input  logic                     rst_n,

    // ------------------------------------------------------------------
    // in-event: flush (announce, single-wire pulse, no payload).
    // ------------------------------------------------------------------
    input  logic                     global_flush_late,

    // ------------------------------------------------------------------
    // in-event: issue (transaction).  Request line + the G0 field list;
    // `FU_Group` is the in-group FU index and the ALU is requester 0 in both
    // G0 and G1, so it is what tells this FU the instruction is
    // addressed to it.
    // ------------------------------------------------------------------
    input  logic                     issue_valid,
    input  logic [XLEN-1:0]          rs1_data,
    input  logic [XLEN-1:0]          rs2_data,
    input  logic [FU_GROUP_W-1:0]    FU_Group,
    input  logic                     imm_valid,
    input  logic [XLEN-1:0]          imm_data,
    input  logic [XLEN-1:0]          pc,
    input  logic [31:0]              inst_bits,
    input  logic                     is_compressed,
    input  logic                     pred_taken,
    input  logic [XLEN-1:0]          pred_target_pc,
    input  logic [TAG_W-1:0]         self_tag,
    input  logic [EXE_SUBOP_W-1:0]   exe_subop,
    input  logic [FULL_DECODE_W-1:0] full_decode,

    // From system_instruction_handler.
    // **ECALL's cause depends on the current privilege level**; only the
    // place that raises the exception knows which one to give.
    // G1's ALU1 instance never receives SYS-class subops; the top level ties
    // it to the PRIV_M constant.
    input  logic [PRIV_W-1:0]        current_priv,
    // The three bits M-mode uses to block S-mode privileged operations (this
    // module uses TVM to block SFENCE.VMA; the same wire also goes to
    // csr_unit to block satp access).  The G1 instance ties all three to 0.
    input  logic                     mstatus_tsr,   // blocks S-mode SRET
    input  logic                     mstatus_tw,    // blocks S-mode WFI
    input  logic                     mstatus_tvm,   // blocks S-mode SFENCE.VMA

    // The front end never fetched this PC, so `inst_bits` is garbage and
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
    // High = the FU can take an instruction this cycle.
    // ------------------------------------------------------------------
    output logic                     FU_ready,

    // ------------------------------------------------------------------
    // out-event: completion request -> `p3_arbiter_G0` / `p3_arbiter_G1`
    // The whole completion_common is registered one cycle behind
    // issue; the zero fields are driven here, never by the arbiter.
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
    // Parallel to and mutually exclusive with req_is_mret.  Constant zero on
    // the G1 instance.
    output logic                     req_is_sret,
    output logic [FFLAGS_W-1:0]      req_fpu_fflags,

    // csr_sideband -- G0 only, and only the CSR FU drives non-zero values.
    // Driven to constant zero here rather than left to the arbiter:
    // constant-zero fields are driven by the FU, the arbiter does
    // not fill them in.  Unconnected on the G1
    // instance: `p3_arbiter_G1` carries no csr_sideband at all.
    output logic                     req_is_csr,
    output logic                     req_csr_write_enable,
    output logic [CSR_ADDR_W-1:0]    req_csr_addr,
    output logic [XLEN-1:0]          req_csr_wdata,

    // ------------------------------------------------------------------
    // out-event: predictor_update -> FE.  Broadcast,
    // driven from the execute stage and NOT waiting for commit -- and NOT
    // routed through the arbiter: winning or losing in-group arbitration
    // does not change the branch outcome, which is already resolved, so
    // these five never hold and never retry.  Only the G0 instance ever
    // raises valid; ALU1 receives no branch subop, so on a G1 lane this is
    // naturally dead, by routing and not by parameter.
    // ------------------------------------------------------------------
    output logic                     predictor_update_valid,
    output logic [XLEN-1:0]          predictor_update_branch_pc,
    output logic                     predictor_update_actual_taken,
    output logic [XLEN-1:0]          predictor_update_actual_target,
    output cf_class_e                predictor_update_cf_class,

    // ------------------------------------------------------------------
    // in: arbiter feedback.  `winner_grant` is this requester's ready,
    // `loser_hold` says the request lost and must be held and retried.
    // ------------------------------------------------------------------
    input  logic                     winner_grant,
    input  logic                     loser_hold
);

    // The in-group FU index comes from the type package: `G0_FU_ALU` and
    // `G1_FU_ALU` are both 0, so one addressee test serves both
    // instances and no parameter is needed.
    // ------------------------------------------------------------------
    // Handshake and FU_ready
    //
    //   FU_ready     = !loser_hold
    //   issue_fire   = issue_valid & FU_ready & addressed-to-me & !flush
    //
    // The ALU never lowers ready because it is busy executing -- it is done
    // in one cycle -- but it must lower it while it is holding a completion
    // request that lost arbitration, because the output register is still
    // occupied by the previous result.
    // `FU_ready` reads only arbiter feedback, never `issue_valid`, so no loop
    // is formed.
    // ------------------------------------------------------------------
    assign FU_ready = !loser_hold;

    logic issue_fire;
    assign issue_fire = issue_valid && FU_ready &&
                        (FU_Group == FU_GROUP_W'(G0_FU_ALU)) && !global_flush_late;

    // `winner_ack[k] = winner_grant[k] & !global_flush_late` is formed inside
    // the FU, not in the arbiter (see the p3_arbiter_G1 header).
    logic winner_ack;
    logic hold_request;

    // ------------------------------------------------------------------
    // Data path.  Subop constants are the frozen `exe_subop_pkg` `SUBOP_*`
    // names, and the capture strobe is `issue_fire`.  `fallthrough_pc`
    // is RVC-aware.
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
    // full_decode[15] (or_be_types_pkg full_decode_t).  The G1 instance has
    // no full_decode source, so this is constant 0 there, as required.
    full_decode_t fd;
    assign fd = full_decode_t'(full_decode);

    // xRET privilege check.  MRET may only execute in M-mode, SRET only in
    // M- or S-mode.
    // **Executing at a lower privilege level is an illegal instruction, not a
    // silent execution.**
    // Without the check, `mret` executed from U-mode would silently pull the
    // machine back to M -- a privilege escalation hole.
    // mstatus.TSR is implemented (SIH has BIT_TSR, delivered via
    // mstatus_tsr): with TSR=0 SRET in S-mode is legal, with TSR=1 it is
    // illegal (see the third term below).
    logic            xret_priv_bad;
    assign xret_priv_bad =
        ((exe_subop == SUBOP_MRET) && (current_priv != 2'b11)) ||
        ((exe_subop == SUBOP_SRET) && (current_priv == 2'b00)) ||
        // TSR: once M-mode sets it, SRET executed in S-mode is an illegal instruction (spec).
        ((exe_subop == SUBOP_SRET) && (current_priv == 2'b01) && mstatus_tsr);

    // SFENCE.VMA privilege checker (semantics given by bt):
    //   U-mode            → illegal
    //   S-mode and TVM=1  → illegal
    //   S-mode and TVM=0  → legal
    //   M-mode            → legal
    // When legal this module **does nothing**: the backend has no TLB, so
    // there is nothing here to flush.
    // "Propagating the flush to the external MMU" belongs to the interface
    // between BE and LSU, not to this module.
    logic sfence_blocked;
    assign sfence_blocked = (exe_subop == SUBOP_SFENCE_VMA)
                         && ((current_priv == 2'b00)
                             || ((current_priv == 2'b01) && mstatus_tvm));

    // TW: once M-mode sets it, WFI executed at a privilege level below M is
    // an illegal instruction (spec).
    // Without it WFI falls into default and becomes a NOP -- which is wrong
    // when TW=1.
    logic wfi_blocked;
    assign wfi_blocked = (exe_subop == SUBOP_WFI)
                      && (current_priv != 2'b11) && mstatus_tw;

    assign is_illegal_op = issue_fire
                        && (fd.illegal || xret_priv_bad || wfi_blocked || sfence_blocked);
    assign is_ecall_op   = issue_fire && (exe_subop == SUBOP_ECALL);
    // EBREAK: breakpoint exception, cause 3.  **Both encodings must be
    // recognized** -- the 32-bit EBREAK and the compressed C.EBREAK are two
    // sub-codes, and missing either one makes it fall into default and
    // silently act as a NOP.
    // The sub-codes are in is_g0_sys_subop and route normally to this FU; if
    // no branch here recognized them, `ebreak` would do nothing.  The
    // riscv-tests -p- cases do not execute ebreak, so regression does not
    // cover this kind of omission.
    assign is_ebreak_op  = issue_fire && ((exe_subop == SUBOP_EBREAK) ||
                                          (exe_subop == SUBOP_C_EBREAK));
    // With insufficient privilege it is not treated as xRET -- in that cycle
    // it is an illegal instruction and takes the ILLEGAL path.
    assign is_mret_op    = issue_fire && (exe_subop == SUBOP_MRET) && !xret_priv_bad;
    assign is_sret_op    = issue_fire && (exe_subop == SUBOP_SRET) && !xret_priv_bad;
    // **WFI is implemented as a NOP by "having no case branch", not by a
    // signal.**
    // SUBOP_WFI matches no arithmetic arm, falls into default and gets
    // result_data = 0, all event fields 0, completes normally and commits
    // normally -- that is a NOP.
    // The spec explicitly allows WFI to be implemented as a NOP; this
    // environment must do so as well: interrupts are generated by software
    // writing mip.SSIP, there is no asynchronous source, and really stalling
    // to wait for an interrupt would deadlock.
    // It **must not** be dropped as an illegal instruction: the riscv-tests
    // S-mode section has more code after wfi.
    // Reaching here requires the frozen package to list SUBOP_WFI in
    // is_g0_sys_subop; otherwise dispatch_logic judges it ROUTE_UNSUPPORTED,
    // and the result is a hang, not a trap.

    // The fall-through is not a fixed `pc + 4`: the BRU computes the link
    // address and the branch fall-through target from `is_compressed`
    // (`pc + 2` when compressed, otherwise `pc + 4`).  This one signal feeds both uses: the
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

            // ---- compressed forms (C extension) ----------------------
            // The frozen package puts SUBOP_C_* into is_g0_alu0_subop /
            // is_g1_alu1_subop, so they **do flow to this FU**, rather than
            // arriving expanded into base subops.
            // Without these branches they would all fall into default →
            // result constant 0, silently wrong.
            //
            // Operands need no separate computation: RVC expansion is done in
            // FE (or_fe_pkg::rvc_expand), register numbers come from the IB
            // entry's opnd, and decode takes imm from FE's expanded
            // inst_expanded, so the operands arriving here are already right;
            // this table only has to say "which operation it is".
            SUBOP_C_ADDI4SPN,          // addi rd', x2, nzuimm
            SUBOP_C_ADDI16SP,          // addi x2, x2, nzimm
            SUBOP_C_ADDI,              // addi rd, rd, nzimm
            SUBOP_C_LI:                // addi rd, x0, imm   (rs1 = x0)
                         alu_result = rs1_data + imm_data;
            SUBOP_C_NOP: alu_result = '0;   // addi x0,x0,0, rd = x0 no writeback
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
            // Zcb (rd' = rs1'): zext.b = andi 255, not = xori -1,
            // sext.b / zext.h / sext.h are Zbb, zext.w = add.uw rd, rd, x0 (Zba)
            SUBOP_C_ZEXT_B: alu_result = {56'b0, rs1_data[7:0]};
            SUBOP_C_SEXT_B: alu_result = {{56{rs1_data[7]}}, rs1_data[7:0]};
            SUBOP_C_ZEXT_H: alu_result = {48'b0, rs1_data[15:0]};
            SUBOP_C_SEXT_H: alu_result = {{48{rs1_data[15]}}, rs1_data[15:0]};
            SUBOP_C_ZEXT_W: alu_result = {32'b0, rs1_data[31:0]};
            SUBOP_C_NOT:    alu_result = ~rs1_data;

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
    // `cf_class` is produced by the BRU from `exe_subop`.  The three
    // sets below are exactly the partition of `is_g0_bru_subop()`'s thirteen
    // members -- 8 conditional + 2 direct + 3 indirect -- so every subop that
    // raises `is_bru_op` gets a real class and `CF_RESERVED` only ever shows
    // up on non-control-flow instructions, where valid is 0 anyway.  C_JAL is
    // RV32-only and has no constant in the frozen package.  There is no
    // call / return class: this backend has no RAS.
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
    // Completion is registered one cycle behind issue -- and it is the
    // whole `completion_common` that is registered, not just the valid.
    // Flush kills whatever is in flight, unconditionally and without a
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
                // Priority: fetch > illegal > ecall.  A fetch fault
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
                                               // M-mode ECALL = 11, U-mode = 8.
                                               // riscv-tests test bodies run in U-mode.
                                               // ECALL's cause depends on the current
                                               // privilege level: U=8 / S=9 / M=11
                                               is_ecall_op   ?
                                                 ((current_priv == 2'b00) ?
                                                    EXCP_CAUSE_W'(8) :
                                                  (current_priv == 2'b01) ?
                                                    EXCP_CAUSE_W'(9) :
                                                    EXCP_CAUSE_W'(11)) :
                                               // breakpoint, independent of privilege level
                                               is_ebreak_op  ? EXCP_CAUSE_W'(3) :
                                                               EXCP_CAUSE_W'(0);
                // An illegal instruction's tval is
                // the faulting instruction's own encoding, and a compressed
                // one contributes only its low 16 bits (`is_compressed` says
                // which).  This is the sole consumer of `inst_bits`.  ECALL
                // keeps tval = 0.
                // A fetch fault's tval is the faulting *address*, not an
                // encoding -- there is no encoding.  It is not always equal
                // to `pc`: when only the second halfword of a 4-byte
                // instruction faults, the spec puts pc in mepc and pc+2 in
                // mtval, which is why this is carried rather than derived.
                // EBREAK's tval is **the faulting instruction's own PC**, not 0.
                // The spec allows either for a breakpoint's mtval; here we
                // follow the reference model: isa_model's
                // InsnImpl<EBREAK>::calc is
                // `trap.trigger(TrapType::BREAK_POINT, insn.inst_pc)`.
                comp_q.exception_tval       <= fetch_excp_vld ? fetch_excp_tval :
                                               is_illegal_op ?
                                               (is_compressed ? {48'b0, inst_bits[15:0]}
                                                              : {32'b0, inst_bits}) :
                                               is_ebreak_op  ? pc :
                                               '0;
                comp_q.is_mret              <= is_mret_op;
                comp_q.is_sret              <= is_sret_op;
                // G0 must drive fpu_fflags to zero itself.
                comp_q.fpu_fflags           <= '0;

                if (is_bru_op) begin
                    // Forms that write a link address: JAL / JALR and their
                    // **compressed counterparts**.
                    // C_J / C_BEQZ / C_BNEZ do not write rd (rd = x0), so
                    // falling to '0 is fine; C_JR is jalr x0 (no write),
                    // C_JALR is jalr x1 (writes).
                    // Missing the compressed forms would write ra as 0.
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
    // Completion request out.  On the flush cycle the FU must not
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
    // itself.
    assign req_is_csr               = 1'b0;
    assign req_csr_write_enable     = 1'b0;
    assign req_csr_addr             = '0;
    assign req_csr_wdata            = '0;

    // ------------------------------------------------------------------
    // predictor_update -- registered one cycle behind issue, the same
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
            // `issue_fire` already excludes the flush cycle, so a
            // flushed instruction can never load a valid here.
            pu_valid_q         <= issue_fire && is_bru_op;
            pu_branch_pc_q     <= pc;
            pu_actual_taken_q  <= branch_taken;
            // taken -> branch_target, not-taken -> fall-through; that is
            // exactly `correct_pc`, which follows is_compressed.
            pu_actual_target_q <= correct_pc;
            pu_cf_class_q      <= cf_class;
        end
    end

    // The flush cycle must not drive this valid either.
    assign predictor_update_valid         = pu_valid_q && !global_flush_late;
    assign predictor_update_branch_pc     = pu_branch_pc_q;
    assign predictor_update_actual_taken  = pu_actual_taken_q;
    assign predictor_update_actual_target = pu_actual_target_q;
    assign predictor_update_cf_class      = pu_cf_class_q;

`ifndef SYNTHESIS
    // ------------------------------------------------------------------
    // Routing self-check -- simulation only.  The G1 instance's event
    // fields are zero *because dispatch_logic routes every branch / CSR /
    // SYS / illegal instruction to G0*, and that guarantee cannot be checked
    // from inside the FU.  If this instance sits on a G1 lane and still
    // drives one of them, the routing is broken and a mispredict would
    // otherwise be pushed silently into the lane the SCB reads as G1.
    //
    // IS_G0 is read here and nowhere else.
    // ------------------------------------------------------------------
    always_ff @(posedge clk) begin
        // **Any new event field must be added here.**  For every field added
        // to the constant-zero fields, this assertion must check one more;
        // if one is missed, nothing will ever report "G1 drove that field".
        if (!IS_G0 && comp_q.result_valid &&
            (comp_q.mispredict_flag || comp_q.exception_flag ||
             comp_q.is_mret || comp_q.is_sret)) begin
            $error("[ALU1] event field driven on a G1 lane: mispredict=%0b exception=%0b is_mret=%0b is_sret=%0b tag=%0d -- dispatch routing is broken",
                   comp_q.mispredict_flag, comp_q.exception_flag,
                   comp_q.is_mret, comp_q.is_sret, comp_q.tag_out);
            $stop;
        end
    end

    // Classifier completeness.  The cf_class partition above is written
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

    // This check is allowed, and it is an assertion, not function.  One cycle after a flush nothing may
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
