`ifndef MUL_SIMPLE_SV
`define MUL_SIMPLE_SV

/* verilator lint_off IMPORTSTAR */
import or_be_types_pkg::*;
import exe_subop_pkg::*;
/* verilator lint_on IMPORTSTAR */

// mul_simple -- G1 requester 1 (FU接入契约 §1 表: ALU1 = 0, MUL = 1).
//
// This is the S3 re-port of RTL/mul_simple.sv onto the new backend schema.
// FU 接入契约 §3 / §4 is this module's ⑥ -- there is no separate
// microarchitecture document for a library-external FU.
//
// **Data path unchanged.**  The multiplier itself, the subop mux and the
// two-count delay model are copied verbatim from the first version; only the
// ports, the types and the three behavioural contracts of 契约 §2 differ.
//
// 契约 §2 behavioural contracts, as implemented here:
//   §2.1 flush kills in-flight work: `global_flush_late` resets cnt / busy_reg
//        / the whole held completion in the same cycle, gates the issue accept
//        term, and combinationally masks `request_valid` so nothing is driven
//        on the flush cycle itself.
//   §2.2 completion is registered relative to issue: the operands are
//        multiplied in the issue cycle, the product is registered into
//        `reg_result`, and the *whole* completion payload (`hold_*`) is a
//        second register stage -- issue at T, request_valid at T+3.  There is
//        no combinational path from any issue input to any `req_*` output.
//   §2.3 `FU_ready` = the FU can take a new instruction this cycle.  契约 §5
//        registers the migration as 「旧端口 busy → FU_ready（极性相反）」, so
//        it is `!busy_reg`, and 契约 §2.3 「输掉仲裁时 FU_ready 同样保持 0」
//        adds the `!loser_hold` term.
//
// 契约 §4.1: G1 carries **no** event fields.  `mispredict_*` / `exception_*` /
// `is_mret` / `fpu_fflags` are driven to zero *here*, not by the arbiter --
// 集成层 §1.2 「恒零字段由 FU 驱动、仲裁器不补造」, because G2/G3 connect
// straight to their lane and have no arbiter that could fill them in.
//
// 契约 §4: the completion side carries the `req_` prefix (集成层 §2.5(5)) and
// the names are the verbatim `p3_arbiter_G1` request-side input names, one
// element of its `[G1_NUM_FU]` arrays.
module mul_simple (
    input  logic                    clk,
    input  logic                    rst_n,

    // ------------------------------------------------------------------
    // in-event: flush (announce, 单线脉冲, 无载荷) -- 契约 §2.1
    // ------------------------------------------------------------------
    input  logic                    global_flush_late,

    // ------------------------------------------------------------------
    // in-event: issue -- ISQ_Group1 ⑥ out-event, field list 契约 §3 (G1).
    // G1 has no pc / branch-prediction / full_decode fields: it never
    // branches.  `imm_*` is on the group's issue bus and therefore on this
    // port list, but the M extension is R-type only, so it is unused here --
    // that is 契约 §3 verbatim, not a dropped connection.
    // ------------------------------------------------------------------
    input  logic                    issue_valid,
    input  logic [XLEN-1:0]         rs1_data,
    input  logic [XLEN-1:0]         rs2_data,
    input  logic [FU_GROUP_W-1:0]   FU_Group,
    input  logic                    imm_valid,
    // 无符号：值在 decode 已完整符号扩展到 64 位，端口跟生产端
    // （ISQ_Group1 的输出）写无符号，避免连线处符号性不匹配（契约 §3）。
    input  logic        [XLEN-1:0]  imm_data,
    input  logic [TAG_W-1:0]        self_tag,
    input  logic [EXE_SUBOP_W-1:0]  exe_subop,

    // ------------------------------------------------------------------
    // in-event: arbitration feedback from p3_arbiter_G1 (契约 §4)
    //   winner_grant -- 触发 (组合选择); this request won this cycle
    //   loser_hold   -- broadcast (组合电平, 可连续多拍); freeze and retry
    // ------------------------------------------------------------------
    input  logic                    winner_grant,
    input  logic                    loser_hold,

    // ------------------------------------------------------------------
    // out-event: completion request -> p3_arbiter_G1 (契约 §4)
    // ------------------------------------------------------------------
    output logic                    request_valid,
    output logic [TAG_W-1:0]        req_tag,
    output logic [XLEN-1:0]         req_result_data,
    output logic                    req_mispredict_flag,
    output logic [XLEN-1:0]         req_mispredict_target_pc,
    output logic                    req_exception_flag,
    output logic [EXCP_CAUSE_W-1:0] req_exception_cause,
    output logic [XLEN-1:0]         req_exception_tval,
    output logic                    req_is_mret,
    output logic                    req_is_sret,
    output logic [FFLAGS_W-1:0]     req_fpu_fflags,

    // ------------------------------------------------------------------
    // out: 组合读 -- FU_ready[1] of ISQ_Group1 (契约 §2.3)
    // ------------------------------------------------------------------
    output logic                    FU_ready
);

    // ------------------------------------------------------------------
    // 契约 §3: 「`FU_Group` 是组内索引 ... FU 拿它判断这条指令是不是发给
    // 自己的」.  `issue_valid` is one wire shared by ALU1 and MUL, so the
    // decode is mandatory, not decoration.  MUL is requester 1 (契约 §1).
    // ------------------------------------------------------------------

    // ==================================================================
    // Data path -- copied verbatim from the first version.
    //
    // The `32` here is the RV64 W-suffix word width (MULW is defined on the
    // low 32 bits whatever XLEN is), not a stand-in for a package width.
    // ==================================================================
    logic [XLEN-1:0] mul_result;
    logic signed [XLEN*2-1:0] full_res_ss;
    logic unsigned [XLEN*2-1:0] full_res_uu;
    logic signed [XLEN*2-1:0] full_res_su;

    logic signed [XLEN-1:0] rs1_s;
    logic signed [XLEN-1:0] rs2_s;
    logic unsigned [XLEN-1:0] rs1_u;
    logic unsigned [XLEN-1:0] rs2_u;

    logic [31:0] rs1_w;
    logic [31:0] rs2_w;

    assign rs1_s = rs1_data;
    assign rs2_s = rs2_data;
    assign rs1_u = rs1_data;
    assign rs2_u = rs2_data;

    assign rs1_w = rs1_data[31:0];
    assign rs2_w = rs2_data[31:0];

    assign full_res_ss = rs1_s * rs2_s;
    assign full_res_uu = rs1_u * rs2_u;
    assign full_res_su = rs1_s * $signed({1'b0, rs2_u});

    // Subop constants migrate from the vanished `orca_types` names to the
    // frozen `exe_subop_pkg` ones (契约 §5); the mux arms are unchanged.
    //   MUL_MUL -> SUBOP_MUL, MUL_MULH -> SUBOP_MULH, MUL_MULHU -> SUBOP_MULHU,
    //   MUL_MULHSU -> SUBOP_MULHSU, MUL_MULW -> SUBOP_MULW
    always_comb begin
        logic [31:0] w_res;
        mul_result = '0;
        w_res = '0;
        case (exe_subop)
            SUBOP_MUL:    mul_result = full_res_ss[XLEN-1:0];
            SUBOP_MULH:   mul_result = full_res_ss[XLEN*2-1:XLEN];
            SUBOP_MULHU:  mul_result = full_res_uu[XLEN*2-1:XLEN];
            SUBOP_MULHSU: mul_result = full_res_su[XLEN*2-1:XLEN];
            SUBOP_MULW: begin
                w_res = rs1_w * rs2_w;
                mul_result = {{32{w_res[31]}}, w_res};
            end
            default:    mul_result = '0;
        endcase
    end

    // ==================================================================
    // Sequencing -- same two-count delay model as the first version.
    // ==================================================================
    logic               cnt;
    logic               busy_reg;

    logic [TAG_W-1:0]   reg_tag;
    logic [XLEN-1:0]    reg_result;

    // Held completion payload.  `rd_idx` / `rd_is_fp` are gone (契约 §5:
    // the SCB stored them in the alloc batch, completion no longer carries
    // them) and the csr_sideband is G0-only (契约 §4), so what survives from
    // the old `result_payload_t` is exactly valid / tag / data.
    logic               hold_valid;
    logic [TAG_W-1:0]   hold_tag;
    logic [XLEN-1:0]    hold_result_data;

    // 契约 §3.0: `issue_valid` is the ISQ's *request* line, not a fire line --
    // it is `isq_valid ∧ operand_ready ∧ !global_flush_late` and deliberately
    // excludes `FU_ready`.  「FU 侧的捕获条件是 `issue_valid && <自己的
    // FU_ready>`」, so the accept term takes both.  No loop: `FU_ready` below
    // is a pure state term (`busy_reg`, `loser_hold`) and never looks at
    // `issue_valid`.  The payload is held stable by the ISQ until the
    // handshake succeeds, so sampling it on the ready cycle is safe.
    //
    // 契约 §2.1 「FU 自己也不得在这拍把 en 当成有效」.  The flush branch below
    // already outranks the accept branch, and 契约 §3.0's `issue_valid` is
    // already flush-gated on the ISQ side; the term is spelled out anyway so
    // the obligation is visible at the accept itself.
    logic issue_accept;
    assign issue_accept = issue_valid
                       && FU_ready
                       && (FU_Group == FU_GROUP_W'(G1_FU_MUL))
                       && !global_flush_late;

    // p3_arbiter_G1微架构文档 ④#1: 「各 FU 以直达的 flush 脉冲门控本地
    // `winner_ack[k] = winner_grant[k] ∧ !global_flush_late`」.  This is the
    // first version's `ack` port, now sourced from the arbiter.
    logic winner_ack;
    assign winner_ack = winner_grant && !global_flush_late;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cnt              <= 1'b0;
            busy_reg         <= 1'b0;
            reg_tag          <= '0;
            reg_result       <= '0;
            hold_valid       <= 1'b0;
            hold_tag         <= '0;
            hold_result_data <= '0;
        end else if (global_flush_late) begin
            // 契约 §2.1: unconditional, no tag compare -- flush happens at the
            // commit point, so everything in flight here is strictly younger.
            // 「多拍 FU 的内部流水与忙标志一并复位」: cnt and busy_reg go too,
            // which is what lets FU_ready come back the next cycle.
            cnt              <= 1'b0;
            busy_reg         <= 1'b0;
            reg_tag          <= '0;
            reg_result       <= '0;
            hold_valid       <= 1'b0;
            hold_tag         <= '0;
            hold_result_data <= '0;
        end else begin
            hold_valid       <= 1'b0;
            hold_tag         <= '0;
            hold_result_data <= '0;

            if (busy_reg) begin
                if (cnt == 1'b0) begin // Writeback state
                    hold_valid       <= 1'b1;
                    hold_tag         <= reg_tag;
                    hold_result_data <= reg_result;

                    // Losing arbitration means winner_ack stays 0, so the whole
                    // held request is simply re-driven next cycle and busy_reg
                    // stays set -- the freeze-and-retry the arbiter doc ④#1
                    // puts on the FU, with no result overwritten or dropped.
                    if (winner_ack) begin
                        busy_reg         <= 1'b0;
                        hold_valid       <= 1'b0;
                        hold_tag         <= '0;
                        hold_result_data <= '0;
                    end
                end else begin
                    cnt <= cnt - 1'b1;
                end
            end else if (issue_accept) begin
                cnt        <= 1'b1; // Countdown: 1, then 0 = writeback
                busy_reg   <= 1'b1;
                reg_tag    <= self_tag;
                reg_result <= mul_result;
            end
        end
    end

    // ==================================================================
    // Outputs
    // ==================================================================

    // 契約 §2.3 + §5.  `!busy_reg` is the first version's `busy` output with
    // the polarity flipped; `!loser_hold` is 「输掉仲裁时同样拉低」.  No
    // dependence on any ISQ valid (契约 §2.3 last paragraph).
    assign FU_ready = !busy_reg && !loser_hold;

    // 契约 §2.1 「本拍不得驱动 request_valid / Result_valid」.  The payload
    // register only clears at the *end* of the flush cycle, so the valid needs
    // this combinational mask to be silent during the cycle itself.
    assign request_valid   = hold_valid && !global_flush_late;
    assign req_tag         = hold_tag;
    assign req_result_data = hold_result_data;

    // 契约 §4.1, G1 row: 全部事件字段恒 0, driven here because the arbiter
    // 不补造.
    assign req_mispredict_flag      = 1'b0;
    assign req_mispredict_target_pc = '0;
    assign req_exception_flag       = 1'b0;
    assign req_exception_cause      = '0;
    assign req_exception_tval       = '0;
    assign req_is_mret              = 1'b0;
    assign req_is_sret              = 1'b0;   // §4.1 G1 zero
    assign req_fpu_fflags           = '0;

`ifndef SYNTHESIS
    // 契約 §2.1 「现有的 flush_late_q 那段延迟一拍的自检可以保留，但它是断言
    // 不是功能」.  Carried over unchanged in substance, renamed onto the new
    // signals.
    logic global_flush_late_q;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            global_flush_late_q <= 1'b0;
        end else begin
            global_flush_late_q <= global_flush_late;
            if (global_flush_late_q && (busy_reg || hold_valid)) begin
                $error("[MUL] stale state after flush: busy=%0b req_valid=%0b tag=%0d",
                       busy_reg, hold_valid, hold_tag);
                $stop;
            end
        end
    end
`endif

endmodule
`endif // MUL_SIMPLE_SV
