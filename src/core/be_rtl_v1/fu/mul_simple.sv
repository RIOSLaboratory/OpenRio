`ifndef MUL_SIMPLE_SV
`define MUL_SIMPLE_SV

/* verilator lint_off IMPORTSTAR */
import or_be_types_pkg::*;
import exe_subop_pkg::*;
/* verilator lint_on IMPORTSTAR */

// mul_simple -- G1 requester 1 (ALU1 = 0, MUL = 1).
//
// The module is the multiplier itself, the subop mux and the two-count delay
// model, wrapped in the ports, the types and the three behavioural contracts.
//
// Behavioural contracts, as implemented here:
//   - Flush kills in-flight work: `global_flush_late` resets cnt / busy_reg
//     / the whole held completion in the same cycle, gates the issue accept
//     term, and combinationally masks `request_valid` so nothing is driven
//     on the flush cycle itself.
//   - Completion is registered relative to issue: the operands are
//     multiplied in the issue cycle, the product is registered into
//     `reg_result`, and the *whole* completion payload (`hold_*`) is a
//     second register stage -- issue at T, request_valid at T+3.  There is
//     no combinational path from any issue input to any `req_*` output.
//   - `FU_ready` = the FU can take a new instruction this cycle, so it is
//     `!busy_reg`, and since FU_ready likewise stays 0 on losing
//     arbitration, the `!loser_hold` term is added.
//
// G1 carries **no** event fields.  `mispredict_*` / `exception_*` /
// `is_mret` / `is_sret` / `fpu_fflags` are driven to zero *here*, not by the arbiter --
// constant-zero fields are driven by the FU, the arbiter does not fill them
// in, because G2/G3 connect
// straight to their lane and have no arbiter that could fill them in.
//
// The completion side carries the `req_` prefix and
// the names are the verbatim `p3_arbiter_G1` request-side input names, one
// element of its `[G1_NUM_FU]` arrays.
module mul_simple (
    input  logic                    clk,
    input  logic                    rst_n,

    // ------------------------------------------------------------------
    // in-event: flush (announce, single-wire pulse, no payload)
    // ------------------------------------------------------------------
    input  logic                    global_flush_late,

    // ------------------------------------------------------------------
    // in-event: issue -- ISQ_Group1 out-event, G1 field list.
    // G1 has no pc / branch-prediction / full_decode fields: it never
    // branches.  `imm_*` is on the group's issue bus and therefore on this
    // port list, but the M extension is R-type only, so it is unused here --
    // that is the field list verbatim, not a dropped connection.
    // ------------------------------------------------------------------
    input  logic                    issue_valid,
    input  logic [XLEN-1:0]         rs1_data,
    input  logic [XLEN-1:0]         rs2_data,
    input  logic [FU_GROUP_W-1:0]   FU_Group,
    input  logic                    imm_valid,
    // Unsigned: the value is already fully sign-extended to 64 bits in decode;
    // the port follows the producer (ISQ_Group1's output) and is written
    // unsigned, avoiding a signedness mismatch at the connection.
    input  logic        [XLEN-1:0]  imm_data,
    input  logic [TAG_W-1:0]        self_tag,
    input  logic [EXE_SUBOP_W-1:0]  exe_subop,

    // ------------------------------------------------------------------
    // in-event: arbitration feedback from p3_arbiter_G1
    //   winner_grant -- trigger (combinational select); this request won this cycle
    //   loser_hold   -- broadcast (combinational level, may last several cycles); freeze and retry
    // ------------------------------------------------------------------
    input  logic                    winner_grant,
    input  logic                    loser_hold,

    // ------------------------------------------------------------------
    // out-event: completion request -> p3_arbiter_G1
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
    // out: combinational read -- FU_ready[1] of ISQ_Group1
    // ------------------------------------------------------------------
    output logic                    FU_ready
);

    // ------------------------------------------------------------------
    // `FU_Group` is the in-group index; the FU uses it to decide
    // whether this instruction is issued to itself.  `issue_valid` is one wire shared by ALU1 and MUL, so the
    // decode is mandatory, not decoration.  MUL is requester 1.
    // ------------------------------------------------------------------

    // ==================================================================
    // Data path.
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

    // Subop constants are the frozen `exe_subop_pkg` names.
    // SUBOP_C_MUL (Zcb) shares one arm with SUBOP_MUL.
    always_comb begin
        logic [31:0] w_res;
        mul_result = '0;
        w_res = '0;
        case (exe_subop)
            SUBOP_MUL,
            SUBOP_C_MUL:  mul_result = full_res_ss[XLEN-1:0];   // c.mul (Zcb) = mul rd', rd', rs2
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
    // Sequencing -- two-count delay model.
    // ==================================================================
    logic               cnt;
    logic               busy_reg;

    logic [TAG_W-1:0]   reg_tag;
    logic [XLEN-1:0]    reg_result;

    // Held completion payload.  The completion carries no `rd_idx` /
    // `rd_is_fp` (the SCB stores them in the alloc batch) and the
    // csr_sideband is G0-only, so the payload is exactly valid / tag /
    // data.
    logic               hold_valid;
    logic [TAG_W-1:0]   hold_tag;
    logic [XLEN-1:0]    hold_result_data;

    // `issue_valid` is the ISQ's *request* line, not a fire line --
    // it is `isq_valid ∧ operand_ready ∧ !global_flush_late` and deliberately
    // excludes `FU_ready`.  The FU-side capture condition is `issue_valid &&
    // <its own FU_ready>`, so the accept term takes both.  No loop: `FU_ready` below
    // is a pure state term (`busy_reg`, `loser_hold`) and never looks at
    // `issue_valid`.  The payload is held stable by the ISQ until the
    // handshake succeeds, so sampling it on the ready cycle is safe.
    //
    // On the flush cycle the FU itself must not treat en as valid either.
    // The flush branch below
    // already outranks the accept branch, and `issue_valid` is
    // already flush-gated on the ISQ side; the term is spelled out anyway so
    // the obligation is visible at the accept itself.
    logic issue_accept;
    assign issue_accept = issue_valid
                       && FU_ready
                       && (FU_Group == FU_GROUP_W'(G1_FU_MUL))
                       && !global_flush_late;

    // Each FU gates its local
    // `winner_ack[k] = winner_grant[k] ∧ !global_flush_late` with the direct
    // flush pulse.
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
            // Unconditional, no tag compare -- flush happens at the
            // commit point, so everything in flight here is strictly younger.
            // A multi-cycle FU's internal pipeline and busy flag are reset
            // together: cnt and busy_reg go too,
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
                    // stays set -- the freeze-and-retry the arbiter
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

    // `!busy_reg` = not occupied; `!loser_hold` is likewise pulled low
    // on losing arbitration.  No dependence on any ISQ valid.
    assign FU_ready = !busy_reg && !loser_hold;

    // Must not drive request_valid / Result_valid on the flush cycle.  The payload
    // register only clears at the *end* of the flush cycle, so the valid needs
    // this combinational mask to be silent during the cycle itself.
    assign request_valid   = hold_valid && !global_flush_late;
    assign req_tag         = hold_tag;
    assign req_result_data = hold_result_data;

    // G1: all event fields constant 0, driven here because the arbiter
    // does not fill them in.
    assign req_mispredict_flag      = 1'b0;
    assign req_mispredict_target_pc = '0;
    assign req_exception_flag       = 1'b0;
    assign req_exception_cause      = '0;
    assign req_exception_tval       = '0;
    assign req_is_mret              = 1'b0;
    assign req_is_sret              = 1'b0;   // G1 zero
    assign req_fpu_fflags           = '0;

`ifndef SYNTHESIS
    // The one-cycle-delayed flush self-check is an assertion, not
    // function.
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
