`ifndef DIV_SIMPLE_SV
`define DIV_SIMPLE_SV

/* verilator lint_off IMPORTSTAR */
import or_be_types_pkg::*;
import exe_subop_pkg::*;
/* verilator lint_on IMPORTSTAR */

// div_simple -- G0 requester 2 (DIV), RV64M integer divide / remainder.
//
// Library-external FU: it has no microarchitecture document of its own, so
// `spec/微架构文档/FU接入契约.md` is its ⑥.  Section references below are to
// that contract unless stated otherwise.
//
//   §1     G0 = ALU0/BRU(0) > CSR(1) > DIV(2), static priority, DIV lowest.
//          (RTL实施计划 §1.3 wrongly files DIV under ISQ_Group1 ③; §1 corrects it.)
//   §2.1   flush cycle kills everything in flight, drives no request_valid
//   §2.2   the whole completion_common is registered, N >= 1 cycles after issue
//   §2.3   DIV: FU_ready = 0 while executing, and 0 while loser_hold = 1
//   §3.0   issue_valid is a *request* line, not a fire line: the FU captures on
//          issue_valid & FU_ready, and FU_ready must not combinationally depend
//          on issue_valid (that would close a loop)
//   §3     issue-side field list = ISQ_Group0 ⑥ out-event, verbatim, no union
//   §4     completion-side names = p3_arbiter_G0 ⑥ `req_*` inputs, verbatim
//   §4.1   constant-zero fields are driven by the FU; the arbiter never fills
//          them in.  For G0 the contract only *requires* fpu_fflags = 0, but
//          DIV has no mispredict / mret / exception source either (see below),
//          so those are driven to zero here as well.
//   §5     orca_types -> or_be_types_pkg; result_payload_t -> completion_common_t;
//          `en` -> issue handshake; `busy` -> FU_ready (opposite polarity)
//
// Divide by zero and signed overflow are NOT exceptions in RISC-V -- they are
// defined return values, already produced by the datapath below.  The v1 file
// raised exception cause 15 on `exe_subop == DIV_DIV_EXC`, but no such subop
// exists in the frozen `exe_subop_pkg` (and 15 is Store/AMO page fault, which
// a divide cannot raise), so that path has no counterpart here and
// exception_flag / cause / tval are constant zero.
//
// The divide iteration and the latency model are carried over from
// `rtl/div_simple.sv` unchanged (改造的边界: 端口与类型改, 数据通路一行不动).

module div_simple (
    input  logic                     clk,
    input  logic                     rst_n,

    // ------------------------------------------------------------------
    // in-event: flush (announce) -- single-wire pulse from flush_model
    // (集成层 §1.5).  §2.1: this cycle nothing is accepted, everything in
    // flight is voided unconditionally (no tag compare -- flush happens at the
    // commit point, so whatever is inside the FU is necessarily younger).
    // ------------------------------------------------------------------
    input  logic                     global_flush_late,

    // ------------------------------------------------------------------
    // in-event: issue (move) -- the whole G0 bundle from ISQ_Group0 ⑥.
    // Declared in full and in ISQ_Group0's port order even though DIV reads
    // only rs1_data / rs2_data / self_tag / exe_subop / FU_Group: §3 fixes the
    // per-group field list and forbids trimming it to a per-FU subset.
    //
    // FU_Group is the *in-group* index (0 = ALU0/BRU, 1 = CSR, 2 = DIV); the
    // bundle is broadcast to all three G0 FUs and each decodes itself from it.
    // ------------------------------------------------------------------
    input  logic                     issue_valid,
    input  logic [XLEN-1:0]          rs1_data,
    input  logic [XLEN-1:0]          rs2_data,
    input  logic [FU_GROUP_W-1:0]    FU_Group,
    input  logic [TAG_W-1:0]         self_tag,
    input  logic [EXE_SUBOP_W-1:0]   exe_subop,

    // ------------------------------------------------------------------
    // in-event: arbiter feedback (§4, 集成层 §1.5).  winner_grant is the
    // trigger that retires the completion request; loser_hold is a level that
    // can stay high for many cycles while the request keeps losing.
    // ------------------------------------------------------------------
    input  logic                     winner_grant,
    input  logic                     loser_hold,

    // ------------------------------------------------------------------
    // out: combinational read -- ISQ_Group0 takes this as FU_ready[2].
    // §2.3: 0 while executing, 0 while holding a lost completion request.
    // A pure state quantity: §3.0 forbids any combinational dependence on
    // issue_valid, so it never looks at whether anyone is asking.
    // ------------------------------------------------------------------
    output logic                     FU_ready,

    // ------------------------------------------------------------------
    // out-event: completion request -> p3_arbiter_G0 requester 2 (§4).
    // Layer 1, completion_common -- every field driven by this FU.
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
    output logic                     req_is_sret,
    output logic [FFLAGS_W-1:0]      req_fpu_fflags,

    // Layer 2, csr_sideband -- G0 only, and only the CSR FU drives non-zero
    // values (§4).  DIV still owns its own slice of the arbiter's request
    // arrays, and §4.1 forbids the arbiter from fabricating the zeros.
    output logic                     req_is_csr,
    output logic                     req_csr_write_enable,
    output logic [CSR_ADDR_W-1:0]    req_csr_addr,
    output logic [XLEN-1:0]          req_csr_wdata
);

    // This FU's in-group requester index.  §1's table and ISQ_Group0.sv's
    // header both fix it at 2; or_be_types_pkg has no constant for it
    // (FU_GROUP_W is the encoding width, G0_NUM_FU the member count, neither
    // is an identity).  localparam, not parameter: a per-instance override
    // would silently make this FU answer to another requester's issues.

    logic [XLEN-1:0] div_result;

    logic signed [XLEN-1:0] rs1_s;
    logic signed [XLEN-1:0] rs2_s;
    logic unsigned [XLEN-1:0] rs1_u;
    logic unsigned [XLEN-1:0] rs2_u;

    logic [31:0] rs1_w;
    logic [31:0] rs2_w;
    logic signed [31:0] rs1_w_s;
    logic signed [31:0] rs2_w_s;

    assign rs1_s = rs1_data;
    assign rs2_s = rs2_data;
    assign rs1_u = rs1_data;
    assign rs2_u = rs2_data;

    assign rs1_w = rs1_data[31:0];
    assign rs2_w = rs2_data[31:0];
    assign rs1_w_s = rs1_data[31:0];
    assign rs2_w_s = rs2_data[31:0];

    logic [1:0] cnt;
    logic       busy_reg;

    logic [TAG_W-1:0]    reg_tag;
    logic [XLEN-1:0]     reg_result;

    // The registered completion_common (§2.2: the *whole* bundle is
    // registered, not just the valid bit).
    completion_common_t  wb_q;

    // ------------------------------------------------------------------
    // §2.3 FU_ready.  `busy_reg` covers both "iterating" and "result sitting
    // in the output register, not yet granted"; loser_hold is the contract's
    // extra term for G0/G1 members.  Neither term reads issue_valid (§3.0).
    // §5: this replaces the v1 `busy` output, opposite polarity.
    // ------------------------------------------------------------------
    assign FU_ready = !busy_reg && !loser_hold;

    // §3.0 capture condition: issue_valid & FU_ready, plus §3's self-decode
    // from FU_Group.  v1's `en` was a fire line; issue_valid is only a request
    // line, so the ready term is mandatory here.  ISQ holds issue_valid and
    // the payload stable until the handshake succeeds, so sampling on the
    // cycle this FU happens to be ready is safe.
    // §2.1 additionally forbids treating the issue as valid during the flush
    // cycle; the always_ff below gives the flush branch priority anyway, this
    // term just makes the requirement local.
    logic accept;
    assign accept = issue_valid
                 && (FU_Group == FU_GROUP_W'(G0_FU_DIV))
                 && FU_ready
                 && !global_flush_late;

    // ------------------------------------------------------------------
    // §2.1: no request_valid on the flush cycle.  wb_q is only cleared at the
    // next edge, so the kill has to be combinational here.  The payload is
    // don't-care while request_valid is low -- p3_arbiter_G0's winner select
    // looks at request_valid alone.
    // ------------------------------------------------------------------
    assign request_valid            = wb_q.result_valid && !global_flush_late;
    assign req_tag                  = wb_q.tag_out;
    assign req_result_data          = wb_q.result_data;
    assign req_mispredict_flag      = wb_q.mispredict_flag;
    assign req_mispredict_target_pc = wb_q.mispredict_target_pc;
    assign req_exception_flag       = wb_q.exception_flag;
    assign req_exception_cause      = wb_q.exception_cause;
    assign req_exception_tval       = wb_q.exception_tval;
    assign req_is_mret              = wb_q.is_mret;
    assign req_is_sret              = wb_q.is_sret;
    assign req_fpu_fflags           = wb_q.fpu_fflags;

    // csr_sideband: DIV is not the CSR FU (§4).
    assign req_is_csr               = 1'b0;
    assign req_csr_write_enable     = 1'b0;
    assign req_csr_addr             = '0;
    assign req_csr_wdata            = '0;

    // ==================================================================
    // Data path -- carried over from rtl/div_simple.sv verbatim.  The only
    // edits are the operand names (rs1/rs2 -> rs1_data/rs2_data) and the subop
    // constants (orca-era DIV_* -> frozen exe_subop_pkg SUBOP_*).  v1's
    // `DIV_DIV, DIV_DIV_EXC:` arm collapses to `SUBOP_DIV:` -- both v1 labels
    // shared one body and DIV_DIV_EXC has no frozen counterpart.
    // ==================================================================
    always_comb begin
        logic [31:0] w_res;
        div_result = '0;
        w_res = '0;
        case (exe_subop)
            SUBOP_DIV: begin
                if (rs2_data == 0) div_result = '1;
                else if (rs1_s == {1'b1, {(XLEN-1){1'b0}}} && rs2_s == -1) div_result = rs1_s;
                else div_result = rs1_s / rs2_s;
            end
            SUBOP_DIVU: begin
                if (rs2_data == 0) div_result = '1;
                else div_result = rs1_u / rs2_u;
            end
            SUBOP_REM: begin
                if (rs2_data == 0) div_result = rs1_data;
                else if (rs1_s == {1'b1, {(XLEN-1){1'b0}}} && rs2_s == -1) div_result = '0;
                else div_result = rs1_s % rs2_s;
            end
            SUBOP_REMU: begin
                if (rs2_data == 0) div_result = rs1_data;
                else div_result = rs1_u % rs2_u;
            end
            SUBOP_DIVW: begin
                if (rs2_w == 0) w_res = '1;
                else if (rs1_w_s == 32'h80000000 && rs2_w_s == -1) w_res = rs1_w_s;
                else w_res = rs1_w_s / rs2_w_s;
                div_result = {{32{w_res[31]}}, w_res};
            end
            SUBOP_DIVUW: begin
                if (rs2_w == 0) w_res = '1;
                else w_res = rs1_w / rs2_w;
                div_result = {{32{w_res[31]}}, w_res};
            end
            SUBOP_REMW: begin
                if (rs2_w == 0) w_res = rs1_w;
                else if (rs1_w_s == 32'h80000000 && rs2_w_s == -1) w_res = '0;
                else w_res = rs1_w_s % rs2_w_s;
                div_result = {{32{w_res[31]}}, w_res};
            end
            SUBOP_REMUW: begin
                if (rs2_w == 0) w_res = rs1_w;
                else w_res = rs1_w % rs2_w;
                div_result = {{32{w_res[31]}}, w_res};
            end
            default: div_result = '0;
        endcase
    end

    // ------------------------------------------------------------------
    // Latency model -- v1's countdown, unchanged.  cnt = 2 (cycle 1),
    // 1 (cycle 2), 0 (writeback state); wb_q is a register, so
    // request_valid rises the cycle after cnt reaches 0.  The result is then
    // held until winner_grant, which is v1's `ack` under §4's name.
    //
    // §2.1: the flush branch resets cnt / busy_reg / the whole wb_q, so the
    // internal pipeline and the busy flag go down together and FU_ready is
    // back up on the next cycle.  It sits above the accept branch, so nothing
    // is taken in on the flush cycle either.
    // ------------------------------------------------------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cnt         <= 2'd0;
            busy_reg    <= 1'b0;
            reg_tag     <= '0;
            reg_result  <= '0;
            wb_q        <= '0;
        end else if (global_flush_late) begin
            cnt         <= 2'd0;
            busy_reg    <= 1'b0;
            reg_tag     <= '0;
            reg_result  <= '0;
            wb_q        <= '0;
        end else begin
            wb_q        <= '0;

            if (busy_reg) begin
                if (cnt == 2'd0) begin // Cycle 3: Writeback state
                    wb_q.result_valid         <= 1'b1;
                    wb_q.tag_out              <= reg_tag;
                    wb_q.result_data          <= reg_result;
                    // §4.1 -- driven here, never fabricated by the arbiter.
                    // DIV produces no branch resolution, no MRET, no FP flags,
                    // and no exception (RISC-V defines div-by-zero and
                    // overflow as return values, computed above).
                    wb_q.mispredict_flag      <= 1'b0;
                    wb_q.mispredict_target_pc <= '0;
                    wb_q.exception_flag       <= 1'b0;
                    wb_q.exception_cause      <= '0;
                    wb_q.exception_tval       <= '0;
                    wb_q.is_mret              <= 1'b0;
                    wb_q.is_sret              <= 1'b0;
                    wb_q.fpu_fflags           <= '0;

                    if (winner_grant) begin // Writeback acknowledged!
                        busy_reg <= 1'b0;
                        wb_q     <= '0;
                    end
                end else begin
                    cnt <= cnt - 2'd1;
                end
            end else if (accept) begin
                cnt         <= 2'd2; // Countdown: 2 (Cycle 1), 1 (Cycle 2), 0 (Cycle 3 writeback)
                busy_reg    <= 1'b1;
                reg_tag     <= self_tag;
                reg_result  <= div_result;
            end
        end
    end

`ifndef SYNTHESIS
    // §2.1's self-check, kept from v1: an assertion, not a function.
    logic flush_late_q;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            flush_late_q <= 1'b0;
        end else begin
            flush_late_q <= global_flush_late;
            if (flush_late_q && (busy_reg || wb_q.result_valid)) begin
                $error("[DIV] stale state after flush: busy=%0b wb_valid=%0b tag=%0d",
                       busy_reg, wb_q.result_valid, wb_q.tag_out);
                $stop;
            end
        end
    end
`endif

endmodule
`endif // DIV_SIMPLE_SV
