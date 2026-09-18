`ifndef FPU_SIMPLE_SV
`define FPU_SIMPLE_SV

/* verilator lint_off IMPORTSTAR */
import or_be_types_pkg::*;
import exe_subop_pkg::*;
/* verilator lint_on IMPORTSTAR */

// ============================================================================
// Synthesizable FPU for RV64FD -- G2, the single member of its group.
//
// Design choices:
//   - Single-cycle combinational datapath (synthesis tool handles timing)
//   - Full IEEE 754 rounding: guard / round / sticky on every arithmetic
//     path, all five RISC-V rounding modes (RNE/RTZ/RDN/RUP/RMM)
//   - Subnormals are produced and consumed, never flushed to zero
//   - NaN-boxing checked on every 32-bit operand read out of an FP register
//   - All five exception flags: NX=0 UF=1 OF=2 DZ=3 NV=4
//   - Division and sqrt use Verilog operators / a restoring iteration
//     (synth tool infers hardware)
//   - FMA is a true fused multiply-add: one product, one alignment, ONE
//     rounding at the end
//
// Datapath shape.  Every operand is unpacked into one canonical internal
// form before anything arithmetic happens:
//
//     value = (sig64 / 2^63) * 2^(e - bias)     with sig64[63] the hidden bit
//
// Subnormals are left-normalised into that form at unpack time (their `e`
// simply goes below 1), so no downstream block has a denormal special case.
// Zeros get a sentinel `e` far below every real exponent, which makes the
// generic add path return "the other operand" without a special case while
// keeping every alignment shift inside the 16-bit shift-amount budget.
//
// Every result comes back through one shared rounder per format
// (fpu_round_sp / fpu_round_dp), which owns the GRS extraction, the five
// rounding modes, the subnormal right-shift, the round-carry renormalise and
// the NX / UF / OF flags.  NV and DZ are decided by the caller, in the result
// MUX, where the operand classes are known.
//
// Sticky bits are carried by shift-right-jam (fpu_srj64 / fpu_srj128): every
// bit that leaves the field is OR-ed into bit 0.  Because the aligned operand
// always has spare zero bits under its significand (40 for SP, 11 for DP, 64
// for the 128-bit FMA accumulator), a jam can only happen when the exponent
// difference is already large enough that at most one leading bit can cancel,
// which is what makes the single-jam-bit scheme exact -- the same argument
// Berkeley SoftFloat's softfloat_shiftRightJam relies on.
//
// PPA note: div_simple.sv and mul_simple.sv use the same approach --
// combinational operators, leaving area/timing tradeoffs to the synthesis
// tool.  This FPU follows the same convention.
//
// Lint note: the first version of this file needed a scoped WIDTHEXPAND /
// WIDTHTRUNC waiver around the whole datapath because it leaned on Verilog's
// context-determined operand widths.  That waiver is gone -- every line below
// is width-explicit and lints under the full -Wall set.
//
// FU接入契约 conformance:
//   §2.1 flush     global_flush_late kills the in-flight instruction and the
//                  busy flag in the same cycle, drives no completion, and
//                  captures no new issue.  Unconditional -- no tag compare.
//   §2.2 timing    the whole completion_common is registered one cycle after
//                  issue (N = 1).  There is no zero-cycle completion.
//   §2.3 FU_ready  0 while executing.  G2 has one member and no arbiter, so
//                  there is no loser_hold input.
//   §3.0 handshake capture = issue_valid && FU_ready.  FU_ready is a pure
//                  registered state and never looks at issue_valid.
//   §4   lane 2    driven directly with the bare completion_common names --
//                  no arbiter, therefore no req_ prefix.
//   §4.1 zeros     mispredict_* / exception_* / is_mret driven to 0 here;
//                  fpu_fflags driven -- G2 is the only group that drives it.
// ============================================================================

module fpu_simple (
    input  logic                        clk,
    input  logic                        rst_n,

    // in-event: flush (announce, single-wire pulse -- 集成层 §1.5)
    input  logic                        global_flush_late,

    // in-event: issue from ISQ_Group2 (move; field list = 接入契约 §3 "G2").
    // issue_valid is a request line, not a fire line (§3.0): the transfer
    // happens on issue_valid && FU_ready, and ISQ_Group2 holds the payload
    // stable until the handshake succeeds.
    input  logic                        issue_valid,
    input  logic [XLEN-1:0]             rs1_data,
    input  logic [XLEN-1:0]             rs2_data,
    input  logic [XLEN-1:0]             rs3_data,
    input  logic [TAG_W-1:0]            self_tag,
    input  logic [EXE_SUBOP_W-1:0]      exe_subop,
    input  logic [FULL_DECODE_W-1:0]    full_decode,

    // Static Info -> ISQ_Group2 (接入契约 §2.3 / §3.0).  Replaces the first
    // version's `busy`, opposite polarity (§5).
    output logic                        FU_ready,

    // out-event: completion -> lane 2 (接入契约 §4, completion_common shape)
    output logic                        writeback_valid,
    output logic [TAG_W-1:0]            tag_out,
    output logic [XLEN-1:0]             result_data,
    output logic                        mispredict_flag,
    output logic [XLEN-1:0]             mispredict_target_pc,
    output logic                        exception_flag,
    output logic [EXCP_CAUSE_W-1:0]     exception_cause,
    output logic [XLEN-1:0]             exception_tval,
    output logic                        is_mret,
    output logic                        is_sret,
    output logic [FFLAGS_W-1:0]         fpu_fflags,

    // bypass_publish —— 集成层 §1.2「lane 驱动方 → bypass_publish_valid[b]/tag/data，
    // 4 lane 四组全收」。G2 无仲裁器，所以由本模块自己驱动 lane 2 的这三根，
    // 与 lsu_bridge 对 lane 3 的做法一致。
    output logic                        bypass_publish_valid,
    output logic [TAG_W-1:0]            bypass_tag,
    output logic [XLEN-1:0]             bypass_data
);

    // FLEN -- the FP register width the datapath declares its result with.
    // or_be_types_pkg has no such constant (see the conversion report); RV64FD
    // makes it 64, i.e. XLEN.  Declared here so the datapath below is verbatim.

    // ---------------------------------------------------------------
    // Issue capture (§3.0) and busy state (§2.3)
    // ---------------------------------------------------------------
    logic issue_fire;
    logic busy_q;

    // §3.0 rule 1: FU_ready is a pure registered state.  It must never be a
    // combinational function of issue_valid, or ISQ_Group2's issue predicate
    // would close a loop through this module.
    assign FU_ready = !busy_q;

    // §3.0: the transfer is issue_valid && FU_ready.  §2.1 additionally
    // forbids treating issue as valid during the flush cycle, so the FU
    // re-qualifies it here instead of trusting the upstream gate alone.
    assign issue_fire = issue_valid && FU_ready && !global_flush_late;

    // §2.3 executing -> FU_ready = 0.  The datapath is combinational and the
    // completion is registered once (§2.2, N = 1), so the busy window is the
    // single cycle in which the completion sits on lane 2.
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            busy_q <= 1'b0;
        end else if (global_flush_late) begin
            busy_q <= 1'b0;             // §2.1: busy flag resets with the pipe
        end else begin
            busy_q <= issue_fire;
        end
    end

    // ---------------------------------------------------------------
    // Operand aliases.  §3 names the issue ports rs1_data / rs2_data /
    // rs3_data; the datapath below names them rs1 / rs2 / rs3.
    // ---------------------------------------------------------------
    logic [FLEN-1:0] rs1, rs2, rs3;
    assign rs1 = rs1_data;
    assign rs2 = rs2_data;
    assign rs3 = rs3_data;

    // ---------------------------------------------------------------
    // Rounding mode
    //
    // full_decode[14:12] is `rm` in the 集成层 §2.2 packing, and what G2
    // receives there is the dispatch-cycle effective_rm (接入契约 §3,
    // dispatch_logic: effective_rm = (rm == 3'b111) ? frm : rm).  DYN is
    // therefore already resolved and there is nothing to resolve here.
    //
    // The system_instruction_handler -> FPU `frm` edge DOES NOT EXIST
    // (集成层 §1.2).  Do not wire it up: an entry can sit in ISQ_Group2 for
    // many cycles and the live frm may have changed underneath it.
    //
    // fpu_eff_rm is the signal every rounder below reads.  For the opcodes
    // that repurpose funct3 (FSGNJ*/FMIN/FMAX/FEQ/FLT/FLE/FCLASS/FMV) the
    // field is not a rounding mode at all, but none of those round, so the
    // rounders' outputs are simply not selected by the result MUX.
    // ---------------------------------------------------------------
    logic [2:0] fpu_rm;
    logic [2:0] fpu_eff_rm;

    assign fpu_rm     = full_decode[14:12];
    assign fpu_eff_rm = fpu_rm;

    // ---------------------------------------------------------------
    // exe_subop decode
    //
    // The frozen exe_subop encoding carries the .S/.D precision in its fixed
    // high field (ISQ_Group2 header: "no extra precision bit is stored"), so
    // the first version's `fpu_meta` sideband is gone.  fpu_op is that
    // version's operation class and fpu_fmt its format bit (0 = S, 1 = D);
    // both are pure functions of exe_subop.
    // ---------------------------------------------------------------
    typedef enum logic [5:0] {
        FPU_NONE,
        FPU_FADD,      FPU_FSUB,       FPU_FMUL,       FPU_FDIV,
        FPU_FSQRT,     FPU_FSGNJ,      FPU_FSGNJN,     FPU_FSGNJX,
        FPU_FMIN,      FPU_FMAX,       FPU_FEQ,        FPU_FLT,
        FPU_FLE,       FPU_FCLASS,     FPU_FMADD,      FPU_FMSUB,
        FPU_FNMSUB,    FPU_FNMADD,
        FPU_FCVT_W_S,  FPU_FCVT_WU_S,  FPU_FCVT_L_S,   FPU_FCVT_LU_S,
        FPU_FCVT_W_D,  FPU_FCVT_WU_D,  FPU_FCVT_L_D,   FPU_FCVT_LU_D,
        FPU_FCVT_S_W,  FPU_FCVT_S_WU,  FPU_FCVT_S_L,   FPU_FCVT_S_LU,
        FPU_FCVT_D_W,  FPU_FCVT_D_WU,  FPU_FCVT_D_L,   FPU_FCVT_D_LU,
        FPU_FCVT_S_D,  FPU_FCVT_D_S,
        FPU_FMV_X_W,   FPU_FMV_W_X,    FPU_FMV_X_D,    FPU_FMV_D_X
    } fpu_op_e;

    fpu_op_e    fpu_op;
    logic [1:0] fpu_fmt;   // 0 = S, 1 = D

    always_comb begin
        fpu_op  = FPU_NONE;
        fpu_fmt = 2'd0;
        case (exe_subop)
            SUBOP_FADD_S:    begin fpu_op = FPU_FADD;      fpu_fmt = 2'd0; end
            SUBOP_FSUB_S:    begin fpu_op = FPU_FSUB;      fpu_fmt = 2'd0; end
            SUBOP_FMUL_S:    begin fpu_op = FPU_FMUL;      fpu_fmt = 2'd0; end
            SUBOP_FDIV_S:    begin fpu_op = FPU_FDIV;      fpu_fmt = 2'd0; end
            SUBOP_FSQRT_S:   begin fpu_op = FPU_FSQRT;     fpu_fmt = 2'd0; end
            SUBOP_FADD_D:    begin fpu_op = FPU_FADD;      fpu_fmt = 2'd1; end
            SUBOP_FSUB_D:    begin fpu_op = FPU_FSUB;      fpu_fmt = 2'd1; end
            SUBOP_FMUL_D:    begin fpu_op = FPU_FMUL;      fpu_fmt = 2'd1; end
            SUBOP_FDIV_D:    begin fpu_op = FPU_FDIV;      fpu_fmt = 2'd1; end
            SUBOP_FSQRT_D:   begin fpu_op = FPU_FSQRT;     fpu_fmt = 2'd1; end

            SUBOP_FSGNJ_S:   begin fpu_op = FPU_FSGNJ;     fpu_fmt = 2'd0; end
            SUBOP_FSGNJN_S:  begin fpu_op = FPU_FSGNJN;    fpu_fmt = 2'd0; end
            SUBOP_FSGNJX_S:  begin fpu_op = FPU_FSGNJX;    fpu_fmt = 2'd0; end
            SUBOP_FMIN_S:    begin fpu_op = FPU_FMIN;      fpu_fmt = 2'd0; end
            SUBOP_FMAX_S:    begin fpu_op = FPU_FMAX;      fpu_fmt = 2'd0; end
            SUBOP_FSGNJ_D:   begin fpu_op = FPU_FSGNJ;     fpu_fmt = 2'd1; end
            SUBOP_FSGNJN_D:  begin fpu_op = FPU_FSGNJN;    fpu_fmt = 2'd1; end
            SUBOP_FSGNJX_D:  begin fpu_op = FPU_FSGNJX;    fpu_fmt = 2'd1; end
            SUBOP_FMIN_D:    begin fpu_op = FPU_FMIN;      fpu_fmt = 2'd1; end
            SUBOP_FMAX_D:    begin fpu_op = FPU_FMAX;      fpu_fmt = 2'd1; end

            SUBOP_FEQ_S:     begin fpu_op = FPU_FEQ;       fpu_fmt = 2'd0; end
            SUBOP_FLT_S:     begin fpu_op = FPU_FLT;       fpu_fmt = 2'd0; end
            SUBOP_FLE_S:     begin fpu_op = FPU_FLE;       fpu_fmt = 2'd0; end
            SUBOP_FCLASS_S:  begin fpu_op = FPU_FCLASS;    fpu_fmt = 2'd0; end
            SUBOP_FEQ_D:     begin fpu_op = FPU_FEQ;       fpu_fmt = 2'd1; end
            SUBOP_FLT_D:     begin fpu_op = FPU_FLT;       fpu_fmt = 2'd1; end
            SUBOP_FLE_D:     begin fpu_op = FPU_FLE;       fpu_fmt = 2'd1; end
            SUBOP_FCLASS_D:  begin fpu_op = FPU_FCLASS;    fpu_fmt = 2'd1; end

            SUBOP_FMADD_S:   begin fpu_op = FPU_FMADD;     fpu_fmt = 2'd0; end
            SUBOP_FMSUB_S:   begin fpu_op = FPU_FMSUB;     fpu_fmt = 2'd0; end
            SUBOP_FNMSUB_S:  begin fpu_op = FPU_FNMSUB;    fpu_fmt = 2'd0; end
            SUBOP_FNMADD_S:  begin fpu_op = FPU_FNMADD;    fpu_fmt = 2'd0; end
            SUBOP_FMADD_D:   begin fpu_op = FPU_FMADD;     fpu_fmt = 2'd1; end
            SUBOP_FMSUB_D:   begin fpu_op = FPU_FMSUB;     fpu_fmt = 2'd1; end
            SUBOP_FNMSUB_D:  begin fpu_op = FPU_FNMSUB;    fpu_fmt = 2'd1; end
            SUBOP_FNMADD_D:  begin fpu_op = FPU_FNMADD;    fpu_fmt = 2'd1; end

            // Conversions and moves name their own precision, so their case
            // arms in the result MUX never consult fpu_fmt.  It is still set
            // to the *source* format so the signal is never a don't-care.
            SUBOP_FCVT_W_S:  begin fpu_op = FPU_FCVT_W_S;  fpu_fmt = 2'd0; end
            SUBOP_FCVT_WU_S: begin fpu_op = FPU_FCVT_WU_S; fpu_fmt = 2'd0; end
            SUBOP_FCVT_L_S:  begin fpu_op = FPU_FCVT_L_S;  fpu_fmt = 2'd0; end
            SUBOP_FCVT_LU_S: begin fpu_op = FPU_FCVT_LU_S; fpu_fmt = 2'd0; end
            SUBOP_FCVT_W_D:  begin fpu_op = FPU_FCVT_W_D;  fpu_fmt = 2'd1; end
            SUBOP_FCVT_WU_D: begin fpu_op = FPU_FCVT_WU_D; fpu_fmt = 2'd1; end
            SUBOP_FCVT_L_D:  begin fpu_op = FPU_FCVT_L_D;  fpu_fmt = 2'd1; end
            SUBOP_FCVT_LU_D: begin fpu_op = FPU_FCVT_LU_D; fpu_fmt = 2'd1; end
            SUBOP_FCVT_S_W:  begin fpu_op = FPU_FCVT_S_W;  fpu_fmt = 2'd0; end
            SUBOP_FCVT_S_WU: begin fpu_op = FPU_FCVT_S_WU; fpu_fmt = 2'd0; end
            SUBOP_FCVT_S_L:  begin fpu_op = FPU_FCVT_S_L;  fpu_fmt = 2'd0; end
            SUBOP_FCVT_S_LU: begin fpu_op = FPU_FCVT_S_LU; fpu_fmt = 2'd0; end
            SUBOP_FCVT_D_W:  begin fpu_op = FPU_FCVT_D_W;  fpu_fmt = 2'd1; end
            SUBOP_FCVT_D_WU: begin fpu_op = FPU_FCVT_D_WU; fpu_fmt = 2'd1; end
            SUBOP_FCVT_D_L:  begin fpu_op = FPU_FCVT_D_L;  fpu_fmt = 2'd1; end
            SUBOP_FCVT_D_LU: begin fpu_op = FPU_FCVT_D_LU; fpu_fmt = 2'd1; end
            SUBOP_FCVT_S_D:  begin fpu_op = FPU_FCVT_S_D;  fpu_fmt = 2'd1; end
            SUBOP_FCVT_D_S:  begin fpu_op = FPU_FCVT_D_S;  fpu_fmt = 2'd0; end

            SUBOP_FMV_X_W:   begin fpu_op = FPU_FMV_X_W;   fpu_fmt = 2'd0; end
            SUBOP_FMV_W_X:   begin fpu_op = FPU_FMV_W_X;   fpu_fmt = 2'd0; end
            SUBOP_FMV_X_D:   begin fpu_op = FPU_FMV_X_D;   fpu_fmt = 2'd1; end
            SUBOP_FMV_D_X:   begin fpu_op = FPU_FMV_D_X;   fpu_fmt = 2'd1; end

            default:         begin fpu_op = FPU_NONE;      fpu_fmt = 2'd0; end
        endcase
    end

    logic fmt_dp;
    assign fmt_dp = (fpu_fmt == 2'd1);

    // ===============================================================
    // IEEE 754 datapath
    // ===============================================================

    // Rounding modes.  Named apart from or_be_types_pkg's rm_e labels so a
    // plain 3-bit compare stays a plain 3-bit compare (no enum coercion).
    localparam logic [2:0] FRM_RNE = 3'b000;
    localparam logic [2:0] FRM_RTZ = 3'b001;
    localparam logic [2:0] FRM_RDN = 3'b010;
    localparam logic [2:0] FRM_RUP = 3'b011;
    localparam logic [2:0] FRM_RMM = 3'b100;

    // Canonical quiet NaNs.
    localparam logic [31:0] SP_QNAN = 32'h7FC00000;
    localparam logic [63:0] DP_QNAN = 64'h7FF8000000000000;

    // Exponent sentinel for a zero operand: below every real exponent, and
    // close enough that every alignment shift stays inside 16 bits.
    localparam logic signed [15:0] SP_EZERO = -16'sd400;
    localparam logic signed [15:0] DP_EZERO = -16'sd2000;

    // ---------------------------------------------------------------
    // Shared primitives
    // ---------------------------------------------------------------

    // Leading-zero count.  Returns the width itself for an all-zero input.
    function automatic logic [6:0] fpu_lzc64(input logic [63:0] lv);
        logic [6:0] lr;
        lr = 7'd64;
        for (int li = 0; li < 64; li++) begin
            if (lv[li]) lr = 7'(63 - li);
        end
        return lr;
    endfunction

    function automatic logic [7:0] fpu_lzc128(input logic [127:0] lv);
        logic [7:0] lr;
        lr = 8'd128;
        for (int li = 0; li < 128; li++) begin
            if (lv[li]) lr = 8'(127 - li);
        end
        return lr;
    endfunction

    // Shift right, jamming every bit that leaves the field into bit 0.
    function automatic logic [63:0] fpu_srj64(input logic [63:0] sv,
                                              input logic [15:0] ss);
        logic [63:0] smask;
        smask = 64'd0;
        if (ss == 16'd0) begin
            return sv;
        end else if (ss >= 16'd64) begin
            return {63'd0, |sv};
        end else begin
            smask = (64'd1 << ss[5:0]) - 64'd1;
            return (sv >> ss[5:0]) | {63'd0, |(sv & smask)};
        end
    endfunction

    function automatic logic [127:0] fpu_srj128(input logic [127:0] sv,
                                                input logic [15:0] ss);
        logic [127:0] smask;
        smask = 128'd0;
        if (ss == 16'd0) begin
            return sv;
        end else if (ss >= 16'd128) begin
            return {127'd0, |sv};
        end else begin
            smask = (128'd1 << ss[6:0]) - 128'd1;
            return (sv >> ss[6:0]) | {127'd0, |(sv & smask)};
        end
    endfunction

    // ---------------------------------------------------------------
    // Rounding core
    //
    // Contract: the value is (rsig / 2^63) * 2^(rexp - bias) -- significand
    // left-aligned with its hidden bit in rsig[63].  Anything below the
    // format's guard bit has already been jammed into rsig's low bits, so the
    // sticky is just the OR of what sits under the guard.
    //
    // Returns {NX,UF,OF,DZ,NV, packed result}.  Only NX / UF / OF are set
    // here; NV and DZ belong to the caller.
    //
    // Underflow follows RISC-V "tiny after rounding": the flag is raised when
    // the rounded result is still subnormal AND the operation was inexact.
    // ---------------------------------------------------------------
    function automatic logic [36:0] fpu_round_sp(input logic               rsign,
                                                 input logic signed [15:0] rexp,
                                                 input logic [63:0]        rsig,
                                                 input logic [2:0]         rmode);
        logic signed [15:0] re;
        logic signed [15:0] rsh;
        logic [63:0]        rs;
        logic [63:0]        rmask;
        logic [24:0]        rm25;
        logic               rg, rst, rl, rup, rix, rtiny, rsub;
        logic [7:0]         rexpf;
        logic [22:0]        rmanf;
        logic [4:0]         rfl;

        re    = rexp;
        rs    = rsig;
        rsub  = 1'b0;
        rfl   = 5'd0;
        rmask = 64'd0;
        rsh   = 16'sd0;

        // ---- subnormal alignment ----------------------------------
        if (re <= 16'sd0) begin
            rsub = 1'b1;
            rsh  = 16'sd1 - re;                       // >= 1
            if (rsh >= 16'sd64) begin
                rs = {63'd0, |rs};
            end else begin
                rmask = (64'd1 << rsh[5:0]) - 64'd1;
                rs    = (rs >> rsh[5:0]) | {63'd0, |(rs & rmask)};
            end
            re = 16'sd0;
        end

        // ---- guard / round / sticky -------------------------------
        rm25 = {1'b0, rs[63:40]};                     // {carry, hidden, man}
        rl   = rs[40];
        rg   = rs[39];
        rst  = |rs[38:0];
        rix  = rg | rst;

        case (rmode)
            FRM_RTZ: rup = 1'b0;
            FRM_RDN: rup = rsign & rix;
            FRM_RUP: rup = (~rsign) & rix;
            FRM_RMM: rup = rg;
            default: rup = rg & (rst | rl);           // RNE
        endcase

        if (rup) rm25 = rm25 + 25'd1;
        if (rm25[24]) begin                           // 1.111..1 -> 10.000
            rm25 = {1'b0, rm25[24:1]};
            re   = re + 16'sd1;
        end

        // ---- pack -------------------------------------------------
        // In the subnormal path rm25[23] is the rounding carry into the
        // hidden position: it means the result just became the smallest
        // normal, whose encoded exponent field is 1.
        rtiny = rsub & ~rm25[23];
        rexpf = rsub ? {7'd0, rm25[23]} : re[7:0];
        rmanf = rm25[22:0];

        if (!rsub && (re >= 16'sd255)) begin
            rfl[2] = 1'b1;                            // OF
            rix    = 1'b1;
            if ((rmode == FRM_RTZ) ||
                ((rmode == FRM_RDN) && !rsign) ||
                ((rmode == FRM_RUP) &&  rsign)) begin
                rexpf = 8'hFE;                        // largest finite
                rmanf = 23'h7FFFFF;
            end else begin
                rexpf = 8'hFF;                        // infinity
                rmanf = 23'd0;
            end
        end

        rfl[0] = rix;                                 // NX
        rfl[1] = rtiny & rix;                         // UF
        return {rfl, rsign, rexpf, rmanf};
    endfunction

    function automatic logic [68:0] fpu_round_dp(input logic               rsign,
                                                 input logic signed [15:0] rexp,
                                                 input logic [63:0]        rsig,
                                                 input logic [2:0]         rmode);
        logic signed [15:0] re;
        logic signed [15:0] rsh;
        logic [63:0]        rs;
        logic [63:0]        rmask;
        logic [53:0]        rm54;
        logic               rg, rst, rl, rup, rix, rtiny, rsub;
        logic [10:0]        rexpf;
        logic [51:0]        rmanf;
        logic [4:0]         rfl;

        re    = rexp;
        rs    = rsig;
        rsub  = 1'b0;
        rfl   = 5'd0;
        rmask = 64'd0;
        rsh   = 16'sd0;

        if (re <= 16'sd0) begin
            rsub = 1'b1;
            rsh  = 16'sd1 - re;
            if (rsh >= 16'sd64) begin
                rs = {63'd0, |rs};
            end else begin
                rmask = (64'd1 << rsh[5:0]) - 64'd1;
                rs    = (rs >> rsh[5:0]) | {63'd0, |(rs & rmask)};
            end
            re = 16'sd0;
        end

        rm54 = {1'b0, rs[63:11]};
        rl   = rs[11];
        rg   = rs[10];
        rst  = |rs[9:0];
        rix  = rg | rst;

        case (rmode)
            FRM_RTZ: rup = 1'b0;
            FRM_RDN: rup = rsign & rix;
            FRM_RUP: rup = (~rsign) & rix;
            FRM_RMM: rup = rg;
            default: rup = rg & (rst | rl);
        endcase

        if (rup) rm54 = rm54 + 54'd1;
        if (rm54[53]) begin
            rm54 = {1'b0, rm54[53:1]};
            re   = re + 16'sd1;
        end

        rtiny = rsub & ~rm54[52];
        rexpf = rsub ? {10'd0, rm54[52]} : re[10:0];
        rmanf = rm54[51:0];

        if (!rsub && (re >= 16'sd2047)) begin
            rfl[2] = 1'b1;
            rix    = 1'b1;
            if ((rmode == FRM_RTZ) ||
                ((rmode == FRM_RDN) && !rsign) ||
                ((rmode == FRM_RUP) &&  rsign)) begin
                rexpf = 11'h7FE;
                rmanf = 52'hF_FFFF_FFFF_FFFF;
            end else begin
                rexpf = 11'h7FF;
                rmanf = 52'd0;
            end
        end

        rfl[0] = rix;
        rfl[1] = rtiny & rix;
        return {rfl, rsign, rexpf, rmanf};
    endfunction

    // ---------------------------------------------------------------
    // Operand unpacking
    //
    // NaN-boxing (RV64 + F): a 32-bit operand read out of an FP register is
    // only a float when the upper half is all ones; otherwise it *is* the
    // canonical quiet NaN.  FMV.X.W is the documented exception -- it moves
    // the raw low half -- so its MUX arm reads rs1 directly.
    // ---------------------------------------------------------------
    logic sp_a_boxed, sp_b_boxed, sp_c_boxed;
    assign sp_a_boxed = (rs1[63:32] == 32'hFFFFFFFF);
    assign sp_b_boxed = (rs2[63:32] == 32'hFFFFFFFF);
    assign sp_c_boxed = (rs3[63:32] == 32'hFFFFFFFF);

    logic [31:0] sp_a, sp_b, sp_c;
    logic [63:0] dp_a, dp_b, dp_c;
    assign sp_a = sp_a_boxed ? rs1[31:0] : SP_QNAN;
    assign sp_b = sp_b_boxed ? rs2[31:0] : SP_QNAN;
    assign sp_c = sp_c_boxed ? rs3[31:0] : SP_QNAN;
    assign dp_a = rs1;
    assign dp_b = rs2;
    assign dp_c = rs3;

    // ---- SP fields ----
    logic        sp_a_sign, sp_b_sign, sp_c_sign;
    logic [7:0]  sp_a_exp,  sp_b_exp,  sp_c_exp;
    logic [22:0] sp_a_man,  sp_b_man,  sp_c_man;
    logic        sp_a_zero, sp_b_zero, sp_c_zero;
    logic        sp_a_inf,  sp_b_inf,  sp_c_inf;
    logic        sp_a_nan,  sp_b_nan,  sp_c_nan;
    logic        sp_a_snan, sp_b_snan, sp_c_snan;

    assign sp_a_sign = sp_a[31];
    assign sp_a_exp  = sp_a[30:23];
    assign sp_a_man  = sp_a[22:0];
    assign sp_a_zero = (sp_a_exp == 8'd0)  && (sp_a_man == 23'd0);
    assign sp_a_inf  = (sp_a_exp == 8'hFF) && (sp_a_man == 23'd0);
    assign sp_a_nan  = (sp_a_exp == 8'hFF) && (sp_a_man != 23'd0);
    assign sp_a_snan = sp_a_nan && !sp_a_man[22];

    assign sp_b_sign = sp_b[31];
    assign sp_b_exp  = sp_b[30:23];
    assign sp_b_man  = sp_b[22:0];
    assign sp_b_zero = (sp_b_exp == 8'd0)  && (sp_b_man == 23'd0);
    assign sp_b_inf  = (sp_b_exp == 8'hFF) && (sp_b_man == 23'd0);
    assign sp_b_nan  = (sp_b_exp == 8'hFF) && (sp_b_man != 23'd0);
    assign sp_b_snan = sp_b_nan && !sp_b_man[22];

    assign sp_c_sign = sp_c[31];
    assign sp_c_exp  = sp_c[30:23];
    assign sp_c_man  = sp_c[22:0];
    assign sp_c_zero = (sp_c_exp == 8'd0)  && (sp_c_man == 23'd0);
    assign sp_c_inf  = (sp_c_exp == 8'hFF) && (sp_c_man == 23'd0);
    assign sp_c_nan  = (sp_c_exp == 8'hFF) && (sp_c_man != 23'd0);
    assign sp_c_snan = sp_c_nan && !sp_c_man[22];

    // ---- DP fields ----
    logic        dp_a_sign, dp_b_sign, dp_c_sign;
    logic [10:0] dp_a_exp,  dp_b_exp,  dp_c_exp;
    logic [51:0] dp_a_man,  dp_b_man,  dp_c_man;
    logic        dp_a_zero, dp_b_zero, dp_c_zero;
    logic        dp_a_inf,  dp_b_inf,  dp_c_inf;
    logic        dp_a_nan,  dp_b_nan,  dp_c_nan;
    logic        dp_a_snan, dp_b_snan, dp_c_snan;

    assign dp_a_sign = dp_a[63];
    assign dp_a_exp  = dp_a[62:52];
    assign dp_a_man  = dp_a[51:0];
    assign dp_a_zero = (dp_a_exp == 11'd0)   && (dp_a_man == 52'd0);
    assign dp_a_inf  = (dp_a_exp == 11'h7FF) && (dp_a_man == 52'd0);
    assign dp_a_nan  = (dp_a_exp == 11'h7FF) && (dp_a_man != 52'd0);
    assign dp_a_snan = dp_a_nan && !dp_a_man[51];

    assign dp_b_sign = dp_b[63];
    assign dp_b_exp  = dp_b[62:52];
    assign dp_b_man  = dp_b[51:0];
    assign dp_b_zero = (dp_b_exp == 11'd0)   && (dp_b_man == 52'd0);
    assign dp_b_inf  = (dp_b_exp == 11'h7FF) && (dp_b_man == 52'd0);
    assign dp_b_nan  = (dp_b_exp == 11'h7FF) && (dp_b_man != 52'd0);
    assign dp_b_snan = dp_b_nan && !dp_b_man[51];

    assign dp_c_sign = dp_c[63];
    assign dp_c_exp  = dp_c[62:52];
    assign dp_c_man  = dp_c[51:0];
    assign dp_c_zero = (dp_c_exp == 11'd0)   && (dp_c_man == 52'd0);
    assign dp_c_inf  = (dp_c_exp == 11'h7FF) && (dp_c_man == 52'd0);
    assign dp_c_nan  = (dp_c_exp == 11'h7FF) && (dp_c_man != 52'd0);
    assign dp_c_snan = dp_c_nan && !dp_c_man[51];

    // ---- canonical internal form ----
    // value = (sig / 2^63) * 2^(e - bias).  Subnormals are left-normalised
    // here; zeros get the sentinel exponent.
    logic [6:0]         sa_lz, sb_lz, sc_lz;
    logic [63:0]        sa_sig, sb_sig, sc_sig;
    logic signed [15:0] sa_e, sb_e, sc_e;

    assign sa_lz = fpu_lzc64({1'b0, sp_a_man, 40'd0});
    assign sb_lz = fpu_lzc64({1'b0, sp_b_man, 40'd0});
    assign sc_lz = fpu_lzc64({1'b0, sp_c_man, 40'd0});

    always_comb begin
        if (sp_a_exp != 8'd0) begin
            sa_sig = {1'b1, sp_a_man, 40'd0};
            sa_e   = {8'd0, sp_a_exp};
        end else if (sp_a_man == 23'd0) begin
            sa_sig = 64'd0;
            sa_e   = SP_EZERO;
        end else begin
            sa_sig = {1'b0, sp_a_man, 40'd0} << sa_lz[5:0];
            sa_e   = 16'sd1 - $signed({9'd0, sa_lz});
        end
    end

    always_comb begin
        if (sp_b_exp != 8'd0) begin
            sb_sig = {1'b1, sp_b_man, 40'd0};
            sb_e   = {8'd0, sp_b_exp};
        end else if (sp_b_man == 23'd0) begin
            sb_sig = 64'd0;
            sb_e   = SP_EZERO;
        end else begin
            sb_sig = {1'b0, sp_b_man, 40'd0} << sb_lz[5:0];
            sb_e   = 16'sd1 - $signed({9'd0, sb_lz});
        end
    end

    always_comb begin
        if (sp_c_exp != 8'd0) begin
            sc_sig = {1'b1, sp_c_man, 40'd0};
            sc_e   = {8'd0, sp_c_exp};
        end else if (sp_c_man == 23'd0) begin
            sc_sig = 64'd0;
            sc_e   = SP_EZERO;
        end else begin
            sc_sig = {1'b0, sp_c_man, 40'd0} << sc_lz[5:0];
            sc_e   = 16'sd1 - $signed({9'd0, sc_lz});
        end
    end

    logic [6:0]         da_lz, db_lz, dc_lz;
    logic [63:0]        da_sig, db_sig, dc_sig;
    logic signed [15:0] da_e, db_e, dc_e;

    assign da_lz = fpu_lzc64({1'b0, dp_a_man, 11'd0});
    assign db_lz = fpu_lzc64({1'b0, dp_b_man, 11'd0});
    assign dc_lz = fpu_lzc64({1'b0, dp_c_man, 11'd0});

    always_comb begin
        if (dp_a_exp != 11'd0) begin
            da_sig = {1'b1, dp_a_man, 11'd0};
            da_e   = {5'd0, dp_a_exp};
        end else if (dp_a_man == 52'd0) begin
            da_sig = 64'd0;
            da_e   = DP_EZERO;
        end else begin
            da_sig = {1'b0, dp_a_man, 11'd0} << da_lz[5:0];
            da_e   = 16'sd1 - $signed({9'd0, da_lz});
        end
    end

    always_comb begin
        if (dp_b_exp != 11'd0) begin
            db_sig = {1'b1, dp_b_man, 11'd0};
            db_e   = {5'd0, dp_b_exp};
        end else if (dp_b_man == 52'd0) begin
            db_sig = 64'd0;
            db_e   = DP_EZERO;
        end else begin
            db_sig = {1'b0, dp_b_man, 11'd0} << db_lz[5:0];
            db_e   = 16'sd1 - $signed({9'd0, db_lz});
        end
    end

    always_comb begin
        if (dp_c_exp != 11'd0) begin
            dc_sig = {1'b1, dp_c_man, 11'd0};
            dc_e   = {5'd0, dp_c_exp};
        end else if (dp_c_man == 52'd0) begin
            dc_sig = 64'd0;
            dc_e   = DP_EZERO;
        end else begin
            dc_sig = {1'b0, dp_c_man, 11'd0} << dc_lz[5:0];
            dc_e   = 16'sd1 - $signed({9'd0, dc_lz});
        end
    end

    // ---------------------------------------------------------------
    // SP add / sub
    // ---------------------------------------------------------------
    logic               sp_add_bsign;
    logic               sp_add_a_ge;
    logic signed [15:0] sp_add_le, sp_add_se;
    logic [63:0]        sp_add_lm, sp_add_sm;
    logic               sp_add_lsign;
    logic [15:0]        sp_add_shamt;
    logic [63:0]        sp_add_smal;
    logic [64:0]        sp_add_raw;
    logic [6:0]         sp_add_lz;
    logic [63:0]        sp_add_nsig;
    logic signed [15:0] sp_add_nexp;
    logic               sp_add_zres;
    logic               sp_add_zsign;

    assign sp_add_bsign = sp_b_sign ^ (fpu_op == FPU_FSUB);
    assign sp_add_a_ge  = (sa_e > sb_e) || ((sa_e == sb_e) && (sa_sig >= sb_sig));

    always_comb begin
        if (sp_add_a_ge) begin
            sp_add_le    = sa_e;  sp_add_lm = sa_sig;  sp_add_lsign = sp_a_sign;
            sp_add_se    = sb_e;  sp_add_sm = sb_sig;
        end else begin
            sp_add_le    = sb_e;  sp_add_lm = sb_sig;  sp_add_lsign = sp_add_bsign;
            sp_add_se    = sa_e;  sp_add_sm = sa_sig;
        end
    end

    assign sp_add_shamt = sp_add_le - sp_add_se;      // >= 0 by construction
    assign sp_add_smal  = fpu_srj64(sp_add_sm, sp_add_shamt);

    always_comb begin
        if (sp_a_sign == sp_add_bsign) sp_add_raw = {1'b0, sp_add_lm} + {1'b0, sp_add_smal};
        else                           sp_add_raw = {1'b0, sp_add_lm} - {1'b0, sp_add_smal};
    end

    assign sp_add_lz   = fpu_lzc64(sp_add_raw[63:0]);
    assign sp_add_zres = (sp_add_raw == 65'd0);

    always_comb begin
        if (sp_add_raw[64]) begin
            sp_add_nsig = sp_add_raw[64:1] | {63'd0, sp_add_raw[0]};
            sp_add_nexp = sp_add_le + 16'sd1;
        end else begin
            sp_add_nsig = sp_add_raw[63:0] << sp_add_lz[5:0];
            sp_add_nexp = sp_add_le - $signed({9'd0, sp_add_lz});
        end
    end

    // Exact zero: IEEE gives + except in roundTowardNegative.  Two real zeros
    // keep their common sign instead.
    assign sp_add_zsign = (sp_a_zero && sp_b_zero && (sp_a_sign == sp_add_bsign))
                          ? sp_a_sign : (fpu_eff_rm == FRM_RDN);

    // ---------------------------------------------------------------
    // DP add / sub
    // ---------------------------------------------------------------
    logic               dp_add_bsign;
    logic               dp_add_a_ge;
    logic signed [15:0] dp_add_le, dp_add_se;
    logic [63:0]        dp_add_lm, dp_add_sm;
    logic               dp_add_lsign;
    logic [15:0]        dp_add_shamt;
    logic [63:0]        dp_add_smal;
    logic [64:0]        dp_add_raw;
    logic [6:0]         dp_add_lz;
    logic [63:0]        dp_add_nsig;
    logic signed [15:0] dp_add_nexp;
    logic               dp_add_zres;
    logic               dp_add_zsign;

    assign dp_add_bsign = dp_b_sign ^ (fpu_op == FPU_FSUB);
    assign dp_add_a_ge  = (da_e > db_e) || ((da_e == db_e) && (da_sig >= db_sig));

    always_comb begin
        if (dp_add_a_ge) begin
            dp_add_le    = da_e;  dp_add_lm = da_sig;  dp_add_lsign = dp_a_sign;
            dp_add_se    = db_e;  dp_add_sm = db_sig;
        end else begin
            dp_add_le    = db_e;  dp_add_lm = db_sig;  dp_add_lsign = dp_add_bsign;
            dp_add_se    = da_e;  dp_add_sm = da_sig;
        end
    end

    assign dp_add_shamt = dp_add_le - dp_add_se;
    assign dp_add_smal  = fpu_srj64(dp_add_sm, dp_add_shamt);

    always_comb begin
        if (dp_a_sign == dp_add_bsign) dp_add_raw = {1'b0, dp_add_lm} + {1'b0, dp_add_smal};
        else                           dp_add_raw = {1'b0, dp_add_lm} - {1'b0, dp_add_smal};
    end

    assign dp_add_lz   = fpu_lzc64(dp_add_raw[63:0]);
    assign dp_add_zres = (dp_add_raw == 65'd0);

    always_comb begin
        if (dp_add_raw[64]) begin
            dp_add_nsig = dp_add_raw[64:1] | {63'd0, dp_add_raw[0]};
            dp_add_nexp = dp_add_le + 16'sd1;
        end else begin
            dp_add_nsig = dp_add_raw[63:0] << dp_add_lz[5:0];
            dp_add_nexp = dp_add_le - $signed({9'd0, dp_add_lz});
        end
    end

    assign dp_add_zsign = (dp_a_zero && dp_b_zero && (dp_a_sign == dp_add_bsign))
                          ? dp_a_sign : (fpu_eff_rm == FRM_RDN);

    // ---------------------------------------------------------------
    // SP multiply
    // ---------------------------------------------------------------
    logic               sp_mul_sign;
    logic [47:0]        sp_mul_prod;
    logic [63:0]        sp_mul_sig;
    logic signed [15:0] sp_mul_exp;

    assign sp_mul_sign = sp_a_sign ^ sp_b_sign;
    assign sp_mul_prod = {24'd0, sa_sig[63:40]} * {24'd0, sb_sig[63:40]};

    always_comb begin
        if (sp_mul_prod[47]) begin
            sp_mul_sig = {sp_mul_prod, 16'd0};
            sp_mul_exp = sa_e + sb_e - 16'sd126;
        end else begin
            sp_mul_sig = {sp_mul_prod[46:0], 17'd0};
            sp_mul_exp = sa_e + sb_e - 16'sd127;
        end
    end

    // ---------------------------------------------------------------
    // DP multiply
    // ---------------------------------------------------------------
    logic               dp_mul_sign;
    logic [105:0]       dp_mul_prod;
    logic [63:0]        dp_mul_sig;
    logic signed [15:0] dp_mul_exp;

    assign dp_mul_sign = dp_a_sign ^ dp_b_sign;
    assign dp_mul_prod = {53'd0, da_sig[63:11]} * {53'd0, db_sig[63:11]};

    // The 106-bit product does not fit in the 64-bit rounder field; the 42
    // bits that fall out are jammed into bit 0, which is what the rounder
    // reads as sticky.  53 significand bits + guard still sit above it.
    always_comb begin
        if (dp_mul_prod[105]) begin
            dp_mul_sig = dp_mul_prod[105:42] | {63'd0, |dp_mul_prod[41:0]};
            dp_mul_exp = da_e + db_e - 16'sd1022;
        end else begin
            dp_mul_sig = dp_mul_prod[104:41] | {63'd0, |dp_mul_prod[40:0]};
            dp_mul_exp = da_e + db_e - 16'sd1023;
        end
    end

    // ---------------------------------------------------------------
    // SP divide
    // ---------------------------------------------------------------
    logic               sp_div_sign;
    logic [63:0]        sp_div_num, sp_div_den, sp_div_q, sp_div_rem;
    logic [6:0]         sp_div_lz;
    logic [63:0]        sp_div_sig;
    logic signed [15:0] sp_div_exp;

    assign sp_div_sign = sp_a_sign ^ sp_b_sign;
    assign sp_div_num  = {sa_sig[63:40], 40'd0};
    assign sp_div_den  = {40'd0, sb_sig[63:40]};
    assign sp_div_q    = (sp_div_den == 64'd0) ? 64'd0 : (sp_div_num / sp_div_den);
    assign sp_div_rem  = (sp_div_den == 64'd0) ? 64'd0 : (sp_div_num % sp_div_den);
    assign sp_div_lz   = fpu_lzc64(sp_div_q);
    assign sp_div_sig  = (sp_div_q << sp_div_lz[5:0]) | {63'd0, |sp_div_rem};
    assign sp_div_exp  = sa_e - sb_e + 16'sd150 - $signed({9'd0, sp_div_lz});

    // ---------------------------------------------------------------
    // DP divide
    // ---------------------------------------------------------------
    logic               dp_div_sign;
    logic [116:0]       dp_div_num, dp_div_den, dp_div_q, dp_div_rem;
    logic [7:0]         dp_div_lz;
    logic [127:0]       dp_div_qw;
    logic [63:0]        dp_div_sig;
    logic signed [15:0] dp_div_exp;

    assign dp_div_sign = dp_a_sign ^ dp_b_sign;
    // 53-bit numerator scaled by 2^64 -> the quotient carries 64..65 bits,
    // far more than the 53 + guard + sticky the rounder needs.
    assign dp_div_num  = {da_sig[63:11], 64'd0};
    assign dp_div_den  = {64'd0, db_sig[63:11]};
    assign dp_div_q    = (dp_div_den == 117'd0) ? 117'd0 : (dp_div_num / dp_div_den);
    assign dp_div_rem  = (dp_div_den == 117'd0) ? 117'd0 : (dp_div_num % dp_div_den);
    assign dp_div_lz   = fpu_lzc128({11'd0, dp_div_q});
    assign dp_div_qw   = {11'd0, dp_div_q} << dp_div_lz[6:0];
    assign dp_div_sig  = dp_div_qw[127:64] | {63'd0, (|dp_div_qw[63:0]) | (|dp_div_rem)};
    assign dp_div_exp  = da_e - db_e + 16'sd1086 - $signed({8'd0, dp_div_lz});

    // ---------------------------------------------------------------
    // SP square root -- restoring, 31 result bits (24 + guard + 6 sticky)
    // ---------------------------------------------------------------
    logic signed [15:0] sp_sq_ep;
    logic               sp_sq_odd;
    logic [61:0]        sp_sq_rad;
    logic [30:0]        sp_sq_res;
    logic [33:0]        sp_sq_rem;
    logic [33:0]        sp_sq_tst;
    logic [63:0]        sp_sq_sig;
    logic signed [15:0] sp_sq_exp;

    assign sp_sq_ep  = sa_e - 16'sd127;
    assign sp_sq_odd = sp_sq_ep[0];
    assign sp_sq_rad = sp_sq_odd ? {sa_sig[63:40], 38'd0} : {1'b0, sa_sig[63:40], 37'd0};

    always_comb begin
        sp_sq_res = 31'd0;
        sp_sq_rem = 34'd0;
        sp_sq_tst = 34'd0;
        for (int i = 30; i >= 0; i--) begin
            sp_sq_rem = {sp_sq_rem[31:0], sp_sq_rad[2*i+1], sp_sq_rad[2*i]};
            sp_sq_tst = {1'b0, sp_sq_res, 2'b01};
            if (sp_sq_rem >= sp_sq_tst) begin
                sp_sq_rem = sp_sq_rem - sp_sq_tst;
                sp_sq_res = {sp_sq_res[29:0], 1'b1};
            end else begin
                sp_sq_res = {sp_sq_res[29:0], 1'b0};
            end
        end
    end

    assign sp_sq_sig = {sp_sq_res, 33'd0} | {63'd0, |sp_sq_rem};
    assign sp_sq_exp = (sp_sq_ep >>> 1) + 16'sd127;

    // ---------------------------------------------------------------
    // DP square root -- restoring, 60 result bits (53 + guard + 6 sticky)
    // ---------------------------------------------------------------
    logic signed [15:0] dp_sq_ep;
    logic               dp_sq_odd;
    logic [119:0]       dp_sq_rad;
    logic [59:0]        dp_sq_res;
    logic [62:0]        dp_sq_rem;
    logic [62:0]        dp_sq_tst;
    logic [63:0]        dp_sq_sig;
    logic signed [15:0] dp_sq_exp;

    assign dp_sq_ep  = da_e - 16'sd1023;
    assign dp_sq_odd = dp_sq_ep[0];
    assign dp_sq_rad = dp_sq_odd ? {da_sig[63:11], 67'd0} : {1'b0, da_sig[63:11], 66'd0};

    always_comb begin
        dp_sq_res = 60'd0;
        dp_sq_rem = 63'd0;
        dp_sq_tst = 63'd0;
        for (int i = 59; i >= 0; i--) begin
            dp_sq_rem = {dp_sq_rem[60:0], dp_sq_rad[2*i+1], dp_sq_rad[2*i]};
            dp_sq_tst = {1'b0, dp_sq_res, 2'b01};
            if (dp_sq_rem >= dp_sq_tst) begin
                dp_sq_rem = dp_sq_rem - dp_sq_tst;
                dp_sq_res = {dp_sq_res[58:0], 1'b1};
            end else begin
                dp_sq_res = {dp_sq_res[58:0], 1'b0};
            end
        end
    end

    assign dp_sq_sig = {dp_sq_res, 4'd0} | {63'd0, |dp_sq_rem};
    assign dp_sq_exp = (dp_sq_ep >>> 1) + 16'sd1023;

    // ---------------------------------------------------------------
    // FMA -- one product, one alignment, ONE rounding.
    // ---------------------------------------------------------------
    logic fma_neg_ab, fma_neg_c;
    assign fma_neg_ab = (fpu_op == FPU_FNMSUB) || (fpu_op == FPU_FNMADD);
    assign fma_neg_c  = (fpu_op == FPU_FMSUB)  || (fpu_op == FPU_FNMADD);

    // ---- SP FMA (64-bit accumulator: 48-bit product + 16 spare) ----
    logic               sp_fma_psign, sp_fma_csign, sp_fma_pzero;
    logic [47:0]        sp_fma_prod;
    logic [63:0]        sp_fma_psig;
    logic signed [15:0] sp_fma_pexp;
    logic               sp_fma_p_ge;
    logic signed [15:0] sp_fma_le, sp_fma_se;
    logic [63:0]        sp_fma_lm, sp_fma_sm;
    logic               sp_fma_lsign;
    logic [15:0]        sp_fma_shamt;
    logic [63:0]        sp_fma_smal;
    logic [64:0]        sp_fma_raw;
    logic [6:0]         sp_fma_lz;
    logic [63:0]        sp_fma_nsig;
    logic signed [15:0] sp_fma_nexp;
    logic               sp_fma_zres, sp_fma_zsign;

    assign sp_fma_psign = sp_a_sign ^ sp_b_sign ^ fma_neg_ab;
    assign sp_fma_csign = sp_c_sign ^ fma_neg_c;
    assign sp_fma_pzero = sp_a_zero || sp_b_zero;
    assign sp_fma_prod  = {24'd0, sa_sig[63:40]} * {24'd0, sb_sig[63:40]};

    always_comb begin
        if (sp_fma_pzero) begin
            sp_fma_psig = 64'd0;
            sp_fma_pexp = SP_EZERO;
        end else if (sp_fma_prod[47]) begin
            sp_fma_psig = {sp_fma_prod, 16'd0};
            sp_fma_pexp = sa_e + sb_e - 16'sd126;
        end else begin
            sp_fma_psig = {sp_fma_prod[46:0], 17'd0};
            sp_fma_pexp = sa_e + sb_e - 16'sd127;
        end
    end

    assign sp_fma_p_ge = (sp_fma_pexp > sc_e) ||
                         ((sp_fma_pexp == sc_e) && (sp_fma_psig >= sc_sig));

    always_comb begin
        if (sp_fma_p_ge) begin
            sp_fma_le = sp_fma_pexp;  sp_fma_lm = sp_fma_psig;  sp_fma_lsign = sp_fma_psign;
            sp_fma_se = sc_e;         sp_fma_sm = sc_sig;
        end else begin
            sp_fma_le = sc_e;         sp_fma_lm = sc_sig;       sp_fma_lsign = sp_fma_csign;
            sp_fma_se = sp_fma_pexp;  sp_fma_sm = sp_fma_psig;
        end
    end

    assign sp_fma_shamt = sp_fma_le - sp_fma_se;
    assign sp_fma_smal  = fpu_srj64(sp_fma_sm, sp_fma_shamt);

    always_comb begin
        if (sp_fma_psign == sp_fma_csign) sp_fma_raw = {1'b0, sp_fma_lm} + {1'b0, sp_fma_smal};
        else                              sp_fma_raw = {1'b0, sp_fma_lm} - {1'b0, sp_fma_smal};
    end

    assign sp_fma_lz   = fpu_lzc64(sp_fma_raw[63:0]);
    assign sp_fma_zres = (sp_fma_raw == 65'd0);

    always_comb begin
        if (sp_fma_raw[64]) begin
            sp_fma_nsig = sp_fma_raw[64:1] | {63'd0, sp_fma_raw[0]};
            sp_fma_nexp = sp_fma_le + 16'sd1;
        end else begin
            sp_fma_nsig = sp_fma_raw[63:0] << sp_fma_lz[5:0];
            sp_fma_nexp = sp_fma_le - $signed({9'd0, sp_fma_lz});
        end
    end

    assign sp_fma_zsign = (sp_fma_pzero && sp_c_zero && (sp_fma_psign == sp_fma_csign))
                          ? sp_fma_psign : (fpu_eff_rm == FRM_RDN);

    // ---- DP FMA (128-bit accumulator: 106-bit product + 22 spare) ----
    logic               dp_fma_psign, dp_fma_csign, dp_fma_pzero;
    logic [105:0]       dp_fma_prod;
    logic [127:0]       dp_fma_psig, dp_fma_csig128;
    logic signed [15:0] dp_fma_pexp;
    logic               dp_fma_p_ge;
    logic signed [15:0] dp_fma_le, dp_fma_se;
    logic [127:0]       dp_fma_lm, dp_fma_sm;
    logic               dp_fma_lsign;
    logic [15:0]        dp_fma_shamt;
    logic [127:0]       dp_fma_smal;
    logic [128:0]       dp_fma_raw;
    logic [7:0]         dp_fma_lz;
    logic [127:0]       dp_fma_nsig128;
    logic [63:0]        dp_fma_nsig;
    logic signed [15:0] dp_fma_nexp;
    logic               dp_fma_zres, dp_fma_zsign;

    assign dp_fma_psign = dp_a_sign ^ dp_b_sign ^ fma_neg_ab;
    assign dp_fma_csign = dp_c_sign ^ fma_neg_c;
    assign dp_fma_pzero = dp_a_zero || dp_b_zero;
    assign dp_fma_prod  = {53'd0, da_sig[63:11]} * {53'd0, db_sig[63:11]};
    assign dp_fma_csig128 = {dc_sig, 64'd0};

    always_comb begin
        if (dp_fma_pzero) begin
            dp_fma_psig = 128'd0;
            dp_fma_pexp = DP_EZERO;
        end else if (dp_fma_prod[105]) begin
            dp_fma_psig = {dp_fma_prod, 22'd0};
            dp_fma_pexp = da_e + db_e - 16'sd1022;
        end else begin
            dp_fma_psig = {dp_fma_prod[104:0], 23'd0};
            dp_fma_pexp = da_e + db_e - 16'sd1023;
        end
    end

    assign dp_fma_p_ge = (dp_fma_pexp > dc_e) ||
                         ((dp_fma_pexp == dc_e) && (dp_fma_psig >= dp_fma_csig128));

    always_comb begin
        if (dp_fma_p_ge) begin
            dp_fma_le = dp_fma_pexp;  dp_fma_lm = dp_fma_psig;    dp_fma_lsign = dp_fma_psign;
            dp_fma_se = dc_e;         dp_fma_sm = dp_fma_csig128;
        end else begin
            dp_fma_le = dc_e;         dp_fma_lm = dp_fma_csig128; dp_fma_lsign = dp_fma_csign;
            dp_fma_se = dp_fma_pexp;  dp_fma_sm = dp_fma_psig;
        end
    end

    assign dp_fma_shamt = dp_fma_le - dp_fma_se;
    assign dp_fma_smal  = fpu_srj128(dp_fma_sm, dp_fma_shamt);

    always_comb begin
        if (dp_fma_psign == dp_fma_csign) dp_fma_raw = {1'b0, dp_fma_lm} + {1'b0, dp_fma_smal};
        else                              dp_fma_raw = {1'b0, dp_fma_lm} - {1'b0, dp_fma_smal};
    end

    assign dp_fma_lz   = fpu_lzc128(dp_fma_raw[127:0]);
    assign dp_fma_zres = (dp_fma_raw == 129'd0);

    always_comb begin
        if (dp_fma_raw[128]) begin
            dp_fma_nsig128 = dp_fma_raw[128:1] | {127'd0, dp_fma_raw[0]};
            dp_fma_nexp    = dp_fma_le + 16'sd1;
        end else begin
            dp_fma_nsig128 = dp_fma_raw[127:0] << dp_fma_lz[6:0];
            dp_fma_nexp    = dp_fma_le - $signed({8'd0, dp_fma_lz});
        end
    end

    // Compress 128 -> 64 for the rounder, jamming the tail into bit 0.
    assign dp_fma_nsig = dp_fma_nsig128[127:64] | {63'd0, |dp_fma_nsig128[63:0]};

    assign dp_fma_zsign = (dp_fma_pzero && dp_c_zero && (dp_fma_psign == dp_fma_csign))
                          ? dp_fma_psign : (fpu_eff_rm == FRM_RDN);

    // ---------------------------------------------------------------
    // INT -> FP
    // ---------------------------------------------------------------
    logic        i2f_sign;
    logic [63:0] i2f_mag;
    logic [6:0]  i2f_lz;
    logic [63:0] i2f_sig;

    always_comb begin
        case (fpu_op)
            FPU_FCVT_S_W, FPU_FCVT_D_W: begin
                i2f_sign = rs1[31];
                i2f_mag  = rs1[31] ? {32'd0, (~rs1[31:0] + 32'd1)} : {32'd0, rs1[31:0]};
            end
            FPU_FCVT_S_WU, FPU_FCVT_D_WU: begin
                i2f_sign = 1'b0;
                i2f_mag  = {32'd0, rs1[31:0]};
            end
            FPU_FCVT_S_L, FPU_FCVT_D_L: begin
                i2f_sign = rs1[63];
                i2f_mag  = rs1[63] ? (~rs1 + 64'd1) : rs1;
            end
            default: begin                                   // *_LU
                i2f_sign = 1'b0;
                i2f_mag  = rs1;
            end
        endcase
    end

    assign i2f_lz  = fpu_lzc64(i2f_mag);
    assign i2f_sig = i2f_mag << i2f_lz[5:0];

    // ---------------------------------------------------------------
    // FP -> INT.  Shared rounder; the source format is muxed in.
    // ---------------------------------------------------------------
    logic f2i_from_dp, f2i_is_32, f2i_is_unsigned;

    always_comb begin
        case (fpu_op)
            FPU_FCVT_W_S:  begin f2i_from_dp = 1'b0; f2i_is_32 = 1'b1; f2i_is_unsigned = 1'b0; end
            FPU_FCVT_WU_S: begin f2i_from_dp = 1'b0; f2i_is_32 = 1'b1; f2i_is_unsigned = 1'b1; end
            FPU_FCVT_L_S:  begin f2i_from_dp = 1'b0; f2i_is_32 = 1'b0; f2i_is_unsigned = 1'b0; end
            FPU_FCVT_LU_S: begin f2i_from_dp = 1'b0; f2i_is_32 = 1'b0; f2i_is_unsigned = 1'b1; end
            FPU_FCVT_W_D:  begin f2i_from_dp = 1'b1; f2i_is_32 = 1'b1; f2i_is_unsigned = 1'b0; end
            FPU_FCVT_WU_D: begin f2i_from_dp = 1'b1; f2i_is_32 = 1'b1; f2i_is_unsigned = 1'b1; end
            FPU_FCVT_L_D:  begin f2i_from_dp = 1'b1; f2i_is_32 = 1'b0; f2i_is_unsigned = 1'b0; end
            FPU_FCVT_LU_D: begin f2i_from_dp = 1'b1; f2i_is_32 = 1'b0; f2i_is_unsigned = 1'b1; end
            default:       begin f2i_from_dp = 1'b0; f2i_is_32 = 1'b0; f2i_is_unsigned = 1'b0; end
        endcase
    end

    logic               f2i_sign, f2i_nan, f2i_inf, f2i_snan;
    logic [63:0]        f2i_sig;
    logic signed [15:0] f2i_sh;

    assign f2i_sign = f2i_from_dp ? dp_a_sign : sp_a_sign;
    assign f2i_nan  = f2i_from_dp ? dp_a_nan  : sp_a_nan;
    assign f2i_inf  = f2i_from_dp ? dp_a_inf  : sp_a_inf;
    assign f2i_snan = f2i_from_dp ? dp_a_snan : sp_a_snan;
    assign f2i_sig  = f2i_from_dp ? da_sig    : sa_sig;
    // 64 + (e - bias - 63): the integer part lands in w[127:64] and the
    // fraction in w[63:0].
    assign f2i_sh   = f2i_from_dp ? (da_e - 16'sd1022) : (sa_e - 16'sd126);

    logic [127:0]       f2i_w;
    logic               f2i_exp_ovf;
    logic signed [15:0] f2i_shneg;

    assign f2i_exp_ovf = (f2i_sh >= 16'sd65);            // |value| >= 2^64
    assign f2i_shneg   = -f2i_sh;

    always_comb begin
        if (f2i_sh >= 16'sd128)       f2i_w = 128'd0;    // out of range anyway
        else if (f2i_sh >= 16'sd0)    f2i_w = {64'd0, f2i_sig} << f2i_sh[6:0];
        else if (f2i_sh <= -16'sd128) f2i_w = {127'd0, |f2i_sig};
        else                          f2i_w = fpu_srj128({64'd0, f2i_sig},
                                                         f2i_shneg[15:0]);
    end

    logic        f2i_g, f2i_st, f2i_l, f2i_ru, f2i_ix;
    logic [64:0] f2i_magr;

    assign f2i_l  = f2i_w[64];
    assign f2i_g  = f2i_w[63];
    assign f2i_st = |f2i_w[62:0];
    assign f2i_ix = f2i_g | f2i_st;

    always_comb begin
        case (fpu_eff_rm)
            FRM_RTZ: f2i_ru = 1'b0;
            FRM_RDN: f2i_ru = f2i_sign & f2i_ix;
            FRM_RUP: f2i_ru = (~f2i_sign) & f2i_ix;
            FRM_RMM: f2i_ru = f2i_g;
            default: f2i_ru = f2i_g & (f2i_st | f2i_l);
        endcase
    end

    assign f2i_magr = {1'b0, f2i_w[127:64]} + {64'd0, f2i_ru};

    logic [64:0] f2i_lim;
    always_comb begin
        if (f2i_is_32) begin
            if (f2i_is_unsigned) f2i_lim = f2i_sign ? 65'd0 : {33'd0, 32'hFFFFFFFF};
            else                 f2i_lim = f2i_sign ? {33'd0, 32'h80000000}
                                                    : {33'd0, 32'h7FFFFFFF};
        end else begin
            if (f2i_is_unsigned) f2i_lim = f2i_sign ? 65'd0 : {1'b0, 64'hFFFFFFFFFFFFFFFF};
            else                 f2i_lim = f2i_sign ? {1'b0, 64'h8000000000000000}
                                                    : {1'b0, 64'h7FFFFFFFFFFFFFFF};
        end
    end

    logic        f2i_invalid;
    logic [63:0] f2i_val, f2i_inval;

    assign f2i_invalid = f2i_nan || f2i_inf || f2i_exp_ovf || (f2i_magr > f2i_lim);
    assign f2i_val     = f2i_sign ? (~f2i_magr[63:0] + 64'd1) : f2i_magr[63:0];

    always_comb begin
        if (f2i_nan || !f2i_sign) begin
            if (f2i_is_32) f2i_inval = f2i_is_unsigned ? 64'hFFFFFFFFFFFFFFFF
                                                       : 64'h000000007FFFFFFF;
            else           f2i_inval = f2i_is_unsigned ? 64'hFFFFFFFFFFFFFFFF
                                                       : 64'h7FFFFFFFFFFFFFFF;
        end else begin
            if      (f2i_is_unsigned) f2i_inval = 64'd0;
            else if (f2i_is_32)       f2i_inval = 64'hFFFFFFFF80000000;
            else                      f2i_inval = 64'h8000000000000000;
        end
    end

    logic [63:0] f2i_result;
    assign f2i_result = f2i_invalid ? f2i_inval : f2i_val;

    // ---------------------------------------------------------------
    // SP -> DP is exact (the DP exponent range covers every SP subnormal),
    // so it never goes through a rounder.
    // ---------------------------------------------------------------
    logic signed [15:0] sp2dp_exp;
    logic [63:0]        sp2dp_result;
    assign sp2dp_exp    = sa_e + 16'sd896;              // -127 + 1023
    assign sp2dp_result = {sp_a_sign, sp2dp_exp[10:0], sa_sig[62:11]};

    // DP -> SP goes through the SP rounder with a rebiased exponent.
    logic signed [15:0] dp2sp_exp;
    assign dp2sp_exp = da_e - 16'sd896;

    // ---------------------------------------------------------------
    // FCLASS
    // ---------------------------------------------------------------
    logic [9:0] sp_fclass_result;
    always_comb begin
        sp_fclass_result = 10'd0;
        if (sp_a_nan) begin
            if (sp_a_snan) sp_fclass_result[8] = 1'b1;
            else           sp_fclass_result[9] = 1'b1;
        end else if (sp_a_inf) begin
            sp_fclass_result[sp_a_sign ? 0 : 7] = 1'b1;
        end else if (sp_a_zero) begin
            sp_fclass_result[sp_a_sign ? 3 : 4] = 1'b1;
        end else if (sp_a_exp == 8'd0) begin
            sp_fclass_result[sp_a_sign ? 2 : 5] = 1'b1; // subnormal
        end else begin
            sp_fclass_result[sp_a_sign ? 1 : 6] = 1'b1; // normal
        end
    end

    logic [9:0] dp_fclass_result;
    always_comb begin
        dp_fclass_result = 10'd0;
        if (dp_a_nan) begin
            if (dp_a_snan) dp_fclass_result[8] = 1'b1;
            else           dp_fclass_result[9] = 1'b1;
        end else if (dp_a_inf) begin
            dp_fclass_result[dp_a_sign ? 0 : 7] = 1'b1;
        end else if (dp_a_zero) begin
            dp_fclass_result[dp_a_sign ? 3 : 4] = 1'b1;
        end else if (dp_a_exp == 11'd0) begin
            dp_fclass_result[dp_a_sign ? 2 : 5] = 1'b1;
        end else begin
            dp_fclass_result[dp_a_sign ? 1 : 6] = 1'b1;
        end
    end

    // ---------------------------------------------------------------
    // Sign injection (FSGNJ/FSGNJN/FSGNJX)
    // ---------------------------------------------------------------
    logic sp_sgnj_sign;
    always_comb begin
        case (fpu_op)
            FPU_FSGNJ:  sp_sgnj_sign = sp_b_sign;
            FPU_FSGNJN: sp_sgnj_sign = ~sp_b_sign;
            FPU_FSGNJX: sp_sgnj_sign = sp_a_sign ^ sp_b_sign;
            default:    sp_sgnj_sign = sp_a_sign;
        endcase
    end

    logic dp_sgnj_sign;
    always_comb begin
        case (fpu_op)
            FPU_FSGNJ:  dp_sgnj_sign = dp_b_sign;
            FPU_FSGNJN: dp_sgnj_sign = ~dp_b_sign;
            FPU_FSGNJX: dp_sgnj_sign = dp_a_sign ^ dp_b_sign;
            default:    dp_sgnj_sign = dp_a_sign;
        endcase
    end

    // ---------------------------------------------------------------
    // Magnitude comparison helpers
    // ---------------------------------------------------------------
    logic cmp_a_lesser, cmp_a_greater;
    assign cmp_a_lesser  = (sp_a_sign != sp_b_sign) ? sp_a_sign :
                           sp_a_sign ? (sp_a[30:0] > sp_b[30:0]) : (sp_a[30:0] < sp_b[30:0]);
    assign cmp_a_greater = (sp_a_sign != sp_b_sign) ? sp_b_sign :
                           sp_a_sign ? (sp_a[30:0] < sp_b[30:0]) : (sp_a[30:0] > sp_b[30:0]);

    logic dp_cmp_a_lesser, dp_cmp_a_greater;
    assign dp_cmp_a_lesser  = (dp_a_sign != dp_b_sign) ? dp_a_sign :
                              dp_a_sign ? (dp_a[62:0] > dp_b[62:0]) : (dp_a[62:0] < dp_b[62:0]);
    assign dp_cmp_a_greater = (dp_a_sign != dp_b_sign) ? dp_b_sign :
                              dp_a_sign ? (dp_a[62:0] < dp_b[62:0]) : (dp_a[62:0] > dp_b[62:0]);

    // ---------------------------------------------------------------
    // One shared rounder per format; its inputs are muxed by fpu_op.
    // ---------------------------------------------------------------
    logic               rnd_sign;
    logic signed [15:0] rnd_exp;
    logic [63:0]        rnd_sig;

    always_comb begin
        rnd_sign = 1'b0;
        rnd_exp  = 16'sd0;
        rnd_sig  = 64'd0;
        case (fpu_op)
            FPU_FADD, FPU_FSUB: begin
                rnd_sign = fmt_dp ? dp_add_lsign : sp_add_lsign;
                rnd_exp  = fmt_dp ? dp_add_nexp  : sp_add_nexp;
                rnd_sig  = fmt_dp ? dp_add_nsig  : sp_add_nsig;
            end
            FPU_FMUL: begin
                rnd_sign = fmt_dp ? dp_mul_sign : sp_mul_sign;
                rnd_exp  = fmt_dp ? dp_mul_exp  : sp_mul_exp;
                rnd_sig  = fmt_dp ? dp_mul_sig  : sp_mul_sig;
            end
            FPU_FDIV: begin
                rnd_sign = fmt_dp ? dp_div_sign : sp_div_sign;
                rnd_exp  = fmt_dp ? dp_div_exp  : sp_div_exp;
                rnd_sig  = fmt_dp ? dp_div_sig  : sp_div_sig;
            end
            FPU_FSQRT: begin
                rnd_sign = 1'b0;
                rnd_exp  = fmt_dp ? dp_sq_exp : sp_sq_exp;
                rnd_sig  = fmt_dp ? dp_sq_sig : sp_sq_sig;
            end
            FPU_FMADD, FPU_FMSUB, FPU_FNMSUB, FPU_FNMADD: begin
                rnd_sign = fmt_dp ? dp_fma_lsign : sp_fma_lsign;
                rnd_exp  = fmt_dp ? dp_fma_nexp  : sp_fma_nexp;
                rnd_sig  = fmt_dp ? dp_fma_nsig  : sp_fma_nsig;
            end
            FPU_FCVT_S_W, FPU_FCVT_S_WU, FPU_FCVT_S_L, FPU_FCVT_S_LU: begin
                rnd_sign = i2f_sign;
                rnd_exp  = 16'sd190 - $signed({9'd0, i2f_lz});   // 127 + 63
                rnd_sig  = i2f_sig;
            end
            FPU_FCVT_D_W, FPU_FCVT_D_WU, FPU_FCVT_D_L, FPU_FCVT_D_LU: begin
                rnd_sign = i2f_sign;
                rnd_exp  = 16'sd1086 - $signed({9'd0, i2f_lz});  // 1023 + 63
                rnd_sig  = i2f_sig;
            end
            FPU_FCVT_S_D: begin
                rnd_sign = dp_a_sign;
                rnd_exp  = dp2sp_exp;
                rnd_sig  = da_sig;
            end
            default: begin
                rnd_sign = 1'b0;
                rnd_exp  = 16'sd0;
                rnd_sig  = 64'd0;
            end
        endcase
    end

    logic [31:0] rnd_sp_val;
    logic [4:0]  rnd_sp_fl;
    logic [63:0] rnd_dp_val;
    logic [4:0]  rnd_dp_fl;

    assign {rnd_sp_fl, rnd_sp_val} = fpu_round_sp(rnd_sign, rnd_exp, rnd_sig, fpu_eff_rm);
    assign {rnd_dp_fl, rnd_dp_val} = fpu_round_dp(rnd_sign, rnd_exp, rnd_sig, fpu_eff_rm);

    // FMA product-side invalid (0 * Inf) and the Inf-vs-Inf cancellation.
    logic sp_fma_nv0, sp_fma_pinf, dp_fma_nv0, dp_fma_pinf;
    assign sp_fma_nv0  = (sp_a_inf && sp_b_zero) || (sp_a_zero && sp_b_inf);
    assign sp_fma_pinf = (sp_a_inf || sp_b_inf) && !sp_fma_nv0;
    assign dp_fma_nv0  = (dp_a_inf && dp_b_zero) || (dp_a_zero && dp_b_inf);
    assign dp_fma_pinf = (dp_a_inf || dp_b_inf) && !dp_fma_nv0;

    // ---------------------------------------------------------------
    // Main result MUX
    // ---------------------------------------------------------------
    logic [FLEN-1:0]     fpu_result;
    logic [FFLAGS_W-1:0] fpu_fflags_c;

    always_comb begin
        fpu_result   = 64'hFFFFFFFF00000000; // NaN-boxing: SP results get high 32-bit = all 1s
        fpu_fflags_c = '0;

        // The first version wrapped the whole MUX in `if (!fs_enabled)` and
        // reported an illegal-instruction exception when FS was Off.  That arm
        // is gone: 接入契约 §4.1 makes exception_flag a constant zero on the G2
        // lane, and §3 hands this FU no `fs_enabled` input.  FS == Off never
        // reaches G2 at all -- dispatch_logic ④#1 computes
        //   fp_illegal = is_fp_instruction & (!fs_enabled | rm_illegal)
        // and illegal_effective pins those to G0's ILLEGAL completion path.
        begin
            case (fpu_op)
                // --- ADD / SUB ---
                FPU_FADD, FPU_FSUB: begin
                    if (!fmt_dp) begin
                        if (sp_a_nan || sp_b_nan) begin
                            fpu_result[31:0] = SP_QNAN;
                            if (sp_a_snan || sp_b_snan) fpu_fflags_c[4] = 1'b1;
                        end else if (sp_a_inf && sp_b_inf && (sp_a_sign != sp_add_bsign)) begin
                            fpu_result[31:0] = SP_QNAN;
                            fpu_fflags_c[4]  = 1'b1;
                        end else if (sp_a_inf) begin
                            fpu_result[31:0] = {sp_a_sign, 8'hFF, 23'd0};
                        end else if (sp_b_inf) begin
                            fpu_result[31:0] = {sp_add_bsign, 8'hFF, 23'd0};
                        end else if (sp_add_zres) begin
                            fpu_result[31:0] = {sp_add_zsign, 31'd0};
                        end else begin
                            fpu_result[31:0] = rnd_sp_val;
                            fpu_fflags_c     = rnd_sp_fl;
                        end
                    end else begin
                        if (dp_a_nan || dp_b_nan) begin
                            fpu_result = DP_QNAN;
                            if (dp_a_snan || dp_b_snan) fpu_fflags_c[4] = 1'b1;
                        end else if (dp_a_inf && dp_b_inf && (dp_a_sign != dp_add_bsign)) begin
                            fpu_result      = DP_QNAN;
                            fpu_fflags_c[4] = 1'b1;
                        end else if (dp_a_inf) begin
                            fpu_result = {dp_a_sign, 11'h7FF, 52'd0};
                        end else if (dp_b_inf) begin
                            fpu_result = {dp_add_bsign, 11'h7FF, 52'd0};
                        end else if (dp_add_zres) begin
                            fpu_result = {dp_add_zsign, 63'd0};
                        end else begin
                            fpu_result   = rnd_dp_val;
                            fpu_fflags_c = rnd_dp_fl;
                        end
                    end
                end

                // --- MUL ---
                FPU_FMUL: begin
                    if (!fmt_dp) begin
                        if (sp_a_nan || sp_b_nan) begin
                            fpu_result[31:0] = SP_QNAN;
                            if (sp_a_snan || sp_b_snan) fpu_fflags_c[4] = 1'b1;
                        end else if ((sp_a_inf && sp_b_zero) || (sp_a_zero && sp_b_inf)) begin
                            fpu_result[31:0] = SP_QNAN;
                            fpu_fflags_c[4]  = 1'b1;
                        end else if (sp_a_inf || sp_b_inf) begin
                            fpu_result[31:0] = {sp_mul_sign, 8'hFF, 23'd0};
                        end else if (sp_a_zero || sp_b_zero) begin
                            fpu_result[31:0] = {sp_mul_sign, 31'd0};
                        end else begin
                            fpu_result[31:0] = rnd_sp_val;
                            fpu_fflags_c     = rnd_sp_fl;
                        end
                    end else begin
                        if (dp_a_nan || dp_b_nan) begin
                            fpu_result = DP_QNAN;
                            if (dp_a_snan || dp_b_snan) fpu_fflags_c[4] = 1'b1;
                        end else if ((dp_a_inf && dp_b_zero) || (dp_a_zero && dp_b_inf)) begin
                            fpu_result      = DP_QNAN;
                            fpu_fflags_c[4] = 1'b1;
                        end else if (dp_a_inf || dp_b_inf) begin
                            fpu_result = {dp_mul_sign, 11'h7FF, 52'd0};
                        end else if (dp_a_zero || dp_b_zero) begin
                            fpu_result = {dp_mul_sign, 63'd0};
                        end else begin
                            fpu_result   = rnd_dp_val;
                            fpu_fflags_c = rnd_dp_fl;
                        end
                    end
                end

                // --- DIV ---
                FPU_FDIV: begin
                    if (!fmt_dp) begin
                        if (sp_a_nan || sp_b_nan) begin
                            fpu_result[31:0] = SP_QNAN;
                            if (sp_a_snan || sp_b_snan) fpu_fflags_c[4] = 1'b1;
                        end else if ((sp_a_inf && sp_b_inf) || (sp_a_zero && sp_b_zero)) begin
                            fpu_result[31:0] = SP_QNAN;
                            fpu_fflags_c[4]  = 1'b1;
                        end else if (sp_b_zero) begin
                            fpu_result[31:0] = {sp_div_sign, 8'hFF, 23'd0};
                            fpu_fflags_c[3]  = 1'b1;                     // DZ
                        end else if (sp_a_inf) begin
                            fpu_result[31:0] = {sp_div_sign, 8'hFF, 23'd0};
                        end else if (sp_b_inf || sp_a_zero) begin
                            fpu_result[31:0] = {sp_div_sign, 31'd0};
                        end else begin
                            fpu_result[31:0] = rnd_sp_val;
                            fpu_fflags_c     = rnd_sp_fl;
                        end
                    end else begin
                        if (dp_a_nan || dp_b_nan) begin
                            fpu_result = DP_QNAN;
                            if (dp_a_snan || dp_b_snan) fpu_fflags_c[4] = 1'b1;
                        end else if ((dp_a_inf && dp_b_inf) || (dp_a_zero && dp_b_zero)) begin
                            fpu_result      = DP_QNAN;
                            fpu_fflags_c[4] = 1'b1;
                        end else if (dp_b_zero) begin
                            fpu_result      = {dp_div_sign, 11'h7FF, 52'd0};
                            fpu_fflags_c[3] = 1'b1;                      // DZ
                        end else if (dp_a_inf) begin
                            fpu_result = {dp_div_sign, 11'h7FF, 52'd0};
                        end else if (dp_b_inf || dp_a_zero) begin
                            fpu_result = {dp_div_sign, 63'd0};
                        end else begin
                            fpu_result   = rnd_dp_val;
                            fpu_fflags_c = rnd_dp_fl;
                        end
                    end
                end

                // --- SQRT ---
                FPU_FSQRT: begin
                    if (!fmt_dp) begin
                        if (sp_a_nan) begin
                            fpu_result[31:0] = SP_QNAN;
                            if (sp_a_snan) fpu_fflags_c[4] = 1'b1;
                        end else if (sp_a_zero) begin
                            fpu_result[31:0] = {sp_a_sign, 31'd0};
                        end else if (sp_a_sign) begin
                            fpu_result[31:0] = SP_QNAN;
                            fpu_fflags_c[4]  = 1'b1;
                        end else if (sp_a_inf) begin
                            fpu_result[31:0] = 32'h7F800000;
                        end else begin
                            fpu_result[31:0] = rnd_sp_val;
                            fpu_fflags_c     = rnd_sp_fl;
                        end
                    end else begin
                        if (dp_a_nan) begin
                            fpu_result = DP_QNAN;
                            if (dp_a_snan) fpu_fflags_c[4] = 1'b1;
                        end else if (dp_a_zero) begin
                            fpu_result = {dp_a_sign, 63'd0};
                        end else if (dp_a_sign) begin
                            fpu_result      = DP_QNAN;
                            fpu_fflags_c[4] = 1'b1;
                        end else if (dp_a_inf) begin
                            fpu_result = {1'b0, 11'h7FF, 52'd0};
                        end else begin
                            fpu_result   = rnd_dp_val;
                            fpu_fflags_c = rnd_dp_fl;
                        end
                    end
                end

                // --- FEQ / FLT / FLE ---
                // FEQ is a quiet compare (NV only on sNaN); FLT/FLE signal on
                // any NaN.
                FPU_FEQ, FPU_FLT, FPU_FLE: begin
                    fpu_result = 64'd0; // GPR output, clear high bits
                    if (!fmt_dp) begin
                        if (sp_a_nan || sp_b_nan) begin
                            fpu_result[0] = 1'b0;
                            if (fpu_op != FPU_FEQ)          fpu_fflags_c[4] = 1'b1;
                            else if (sp_a_snan || sp_b_snan) fpu_fflags_c[4] = 1'b1;
                        end else begin
                            case (fpu_op)
                                FPU_FEQ: fpu_result[0] = (sp_a_zero && sp_b_zero) || (sp_a == sp_b);
                                FPU_FLT: begin
                                    if (sp_a_zero && sp_b_zero) fpu_result[0] = 1'b0;
                                    else fpu_result[0] = cmp_a_lesser;
                                end
                                FPU_FLE: begin
                                    if (sp_a_zero && sp_b_zero) fpu_result[0] = 1'b1;
                                    else fpu_result[0] = cmp_a_lesser || (sp_a == sp_b);
                                end
                                default: fpu_result[0] = 1'b0;
                            endcase
                        end
                    end else begin
                        if (dp_a_nan || dp_b_nan) begin
                            fpu_result[0] = 1'b0;
                            if (fpu_op != FPU_FEQ)           fpu_fflags_c[4] = 1'b1;
                            else if (dp_a_snan || dp_b_snan) fpu_fflags_c[4] = 1'b1;
                        end else begin
                            case (fpu_op)
                                FPU_FEQ: fpu_result[0] = (dp_a_zero && dp_b_zero) || (dp_a == dp_b);
                                FPU_FLT: begin
                                    if (dp_a_zero && dp_b_zero) fpu_result[0] = 1'b0;
                                    else fpu_result[0] = dp_cmp_a_lesser;
                                end
                                FPU_FLE: begin
                                    if (dp_a_zero && dp_b_zero) fpu_result[0] = 1'b1;
                                    else fpu_result[0] = dp_cmp_a_lesser || (dp_a == dp_b);
                                end
                                default: fpu_result[0] = 1'b0;
                            endcase
                        end
                    end
                end

                // --- FMIN / FMAX ---
                // RISC-V >= 2.2: the non-NaN operand wins, only a signalling
                // NaN raises NV.
                FPU_FMIN: begin
                    if (!fmt_dp) begin
                        if (sp_a_snan || sp_b_snan) fpu_fflags_c[4] = 1'b1;
                        if (sp_a_nan && sp_b_nan)
                            fpu_result[31:0] = SP_QNAN;
                        else if (sp_a_nan)
                            fpu_result[31:0] = sp_b;
                        else if (sp_b_nan)
                            fpu_result[31:0] = sp_a;
                        else if (sp_a_zero && sp_b_zero)
                            fpu_result[31:0] = (sp_a_sign || sp_b_sign) ? 32'h80000000 : 32'h00000000;
                        else
                            fpu_result[31:0] = cmp_a_lesser ? sp_a : sp_b;
                    end else begin
                        if (dp_a_snan || dp_b_snan) fpu_fflags_c[4] = 1'b1;
                        if (dp_a_nan && dp_b_nan)
                            fpu_result = DP_QNAN;
                        else if (dp_a_nan)
                            fpu_result = dp_b;
                        else if (dp_b_nan)
                            fpu_result = dp_a;
                        else if (dp_a_zero && dp_b_zero)
                            fpu_result = (dp_a_sign || dp_b_sign) ? 64'h8000000000000000
                                                                  : 64'h0000000000000000;
                        else
                            fpu_result = dp_cmp_a_lesser ? dp_a : dp_b;
                    end
                end

                FPU_FMAX: begin
                    if (!fmt_dp) begin
                        if (sp_a_snan || sp_b_snan) fpu_fflags_c[4] = 1'b1;
                        if (sp_a_nan && sp_b_nan)
                            fpu_result[31:0] = SP_QNAN;
                        else if (sp_a_nan)
                            fpu_result[31:0] = sp_b;
                        else if (sp_b_nan)
                            fpu_result[31:0] = sp_a;
                        else if (sp_a_zero && sp_b_zero)
                            fpu_result[31:0] = (sp_a_sign && sp_b_sign) ? 32'h80000000 : 32'h00000000;
                        else
                            fpu_result[31:0] = cmp_a_greater ? sp_a : sp_b;
                    end else begin
                        if (dp_a_snan || dp_b_snan) fpu_fflags_c[4] = 1'b1;
                        if (dp_a_nan && dp_b_nan)
                            fpu_result = DP_QNAN;
                        else if (dp_a_nan)
                            fpu_result = dp_b;
                        else if (dp_b_nan)
                            fpu_result = dp_a;
                        else if (dp_a_zero && dp_b_zero)
                            fpu_result = (dp_a_sign && dp_b_sign) ? 64'h8000000000000000
                                                                  : 64'h0000000000000000;
                        else
                            fpu_result = dp_cmp_a_greater ? dp_a : dp_b;
                    end
                end

                // --- Sign injection ---
                FPU_FSGNJ, FPU_FSGNJN, FPU_FSGNJX: begin
                    if (!fmt_dp)
                        fpu_result[31:0] = {sp_sgnj_sign, sp_a[30:0]};
                    else
                        fpu_result       = {dp_sgnj_sign, dp_a[62:0]};
                end

                // --- Classification ---
                FPU_FCLASS: begin
                    fpu_result = 64'd0; // GPR output, clear high bits
                    if (!fmt_dp)
                        fpu_result[9:0] = sp_fclass_result;
                    else
                        fpu_result[9:0] = dp_fclass_result;
                end

                // --- SP moves ---
                // FMV.X.W moves the raw low half; NaN-boxing is deliberately
                // NOT applied here (RISC-V unprivileged spec, F chapter).
                FPU_FMV_X_W:  fpu_result = {{32{rs1[31]}}, rs1[31:0]};
                FPU_FMV_W_X:  fpu_result[31:0] = rs1[31:0]; // NaN-boxed by initial value

                // --- DP moves ---
                FPU_FMV_X_D:  fpu_result = dp_a;
                FPU_FMV_D_X:  fpu_result = rs1;

                // --- SP -> DP (exact) ---
                FPU_FCVT_D_S: begin
                    if (sp_a_nan) begin
                        fpu_result = DP_QNAN;
                        if (sp_a_snan) fpu_fflags_c[4] = 1'b1;
                    end else if (sp_a_inf) begin
                        fpu_result = {sp_a_sign, 11'h7FF, 52'd0};
                    end else if (sp_a_zero) begin
                        fpu_result = {sp_a_sign, 63'd0};
                    end else begin
                        fpu_result = sp2dp_result;
                    end
                end

                // --- DP -> SP (rounded) ---
                FPU_FCVT_S_D: begin
                    if (dp_a_nan) begin
                        fpu_result[31:0] = SP_QNAN;
                        if (dp_a_snan) fpu_fflags_c[4] = 1'b1;
                    end else if (dp_a_inf) begin
                        fpu_result[31:0] = {dp_a_sign, 8'hFF, 23'd0};
                    end else if (dp_a_zero) begin
                        fpu_result[31:0] = {dp_a_sign, 31'd0};
                    end else begin
                        fpu_result[31:0] = rnd_sp_val;
                        fpu_fflags_c     = rnd_sp_fl;
                    end
                end

                // --- INT -> SP ---
                FPU_FCVT_S_W, FPU_FCVT_S_WU,
                FPU_FCVT_S_L, FPU_FCVT_S_LU: begin
                    if (i2f_mag == 64'd0) begin
                        fpu_result[31:0] = 32'd0;
                    end else begin
                        fpu_result[31:0] = rnd_sp_val;
                        fpu_fflags_c     = rnd_sp_fl;
                    end
                end

                // --- INT -> DP ---
                FPU_FCVT_D_W, FPU_FCVT_D_WU,
                FPU_FCVT_D_L, FPU_FCVT_D_LU: begin
                    if (i2f_mag == 64'd0) begin
                        fpu_result = 64'd0;
                    end else begin
                        fpu_result   = rnd_dp_val;
                        fpu_fflags_c = rnd_dp_fl;
                    end
                end

                // --- FP -> INT (write to GPR) ---
                FPU_FCVT_W_S, FPU_FCVT_WU_S,
                FPU_FCVT_W_D, FPU_FCVT_WU_D: begin
                    fpu_result = {{32{f2i_result[31]}}, f2i_result[31:0]};
                    if (f2i_invalid) fpu_fflags_c[4] = 1'b1;
                    else if (f2i_ix) fpu_fflags_c[0] = 1'b1;
                end
                FPU_FCVT_L_S, FPU_FCVT_LU_S,
                FPU_FCVT_L_D, FPU_FCVT_LU_D: begin
                    fpu_result = f2i_result;
                    if (f2i_invalid) fpu_fflags_c[4] = 1'b1;
                    else if (f2i_ix) fpu_fflags_c[0] = 1'b1;
                end

                // --- FMA ---
                FPU_FMADD, FPU_FMSUB, FPU_FNMSUB, FPU_FNMADD: begin
                    if (!fmt_dp) begin
                        if (sp_fma_nv0) begin
                            fpu_result[31:0] = SP_QNAN;
                            fpu_fflags_c[4]  = 1'b1;
                        end else if (sp_a_nan || sp_b_nan || sp_c_nan) begin
                            fpu_result[31:0] = SP_QNAN;
                            if (sp_a_snan || sp_b_snan || sp_c_snan) fpu_fflags_c[4] = 1'b1;
                        end else if (sp_fma_pinf && sp_c_inf &&
                                     (sp_fma_psign != sp_fma_csign)) begin
                            fpu_result[31:0] = SP_QNAN;
                            fpu_fflags_c[4]  = 1'b1;
                        end else if (sp_fma_pinf) begin
                            fpu_result[31:0] = {sp_fma_psign, 8'hFF, 23'd0};
                        end else if (sp_c_inf) begin
                            fpu_result[31:0] = {sp_fma_csign, 8'hFF, 23'd0};
                        end else if (sp_fma_zres) begin
                            fpu_result[31:0] = {sp_fma_zsign, 31'd0};
                        end else begin
                            fpu_result[31:0] = rnd_sp_val;
                            fpu_fflags_c     = rnd_sp_fl;
                        end
                    end else begin
                        if (dp_fma_nv0) begin
                            fpu_result      = DP_QNAN;
                            fpu_fflags_c[4] = 1'b1;
                        end else if (dp_a_nan || dp_b_nan || dp_c_nan) begin
                            fpu_result = DP_QNAN;
                            if (dp_a_snan || dp_b_snan || dp_c_snan) fpu_fflags_c[4] = 1'b1;
                        end else if (dp_fma_pinf && dp_c_inf &&
                                     (dp_fma_psign != dp_fma_csign)) begin
                            fpu_result      = DP_QNAN;
                            fpu_fflags_c[4] = 1'b1;
                        end else if (dp_fma_pinf) begin
                            fpu_result = {dp_fma_psign, 11'h7FF, 52'd0};
                        end else if (dp_c_inf) begin
                            fpu_result = {dp_fma_csign, 11'h7FF, 52'd0};
                        end else if (dp_fma_zres) begin
                            fpu_result = {dp_fma_zsign, 63'd0};
                        end else begin
                            fpu_result   = rnd_dp_val;
                            fpu_fflags_c = rnd_dp_fl;
                        end
                    end
                end

                default: begin
                    fpu_result   = '0;
                    fpu_fflags_c = '0;
                end
            endcase
        end
    end
    // Datapath ends here.

    // ---------------------------------------------------------------
    // Output register -- 接入契约 §2.2
    //
    // The *whole* completion_common is registered, not just the valid: it
    // feeds Buffer's write port and CompletionScoreboard's event batch, both
    // timed writes, so a combinational path from issue through this FU into
    // the SCB's criteria is not acceptable.
    //
    // §2.1: global_flush_late voids the in-flight instruction unconditionally
    // -- no tag compare, because anything in flight here is younger than the
    // flush point by construction.  It has priority over issue_fire, so an
    // issue arriving in the flush cycle is not captured either.
    // ---------------------------------------------------------------
    completion_common_t wb_payload;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wb_payload <= '0;
        end else if (global_flush_late) begin
            wb_payload <= '0;
        end else if (issue_fire) begin
            wb_payload.result_valid         <= 1'b1;
            wb_payload.tag_out              <= self_tag;
            wb_payload.result_data          <= fpu_result;
            wb_payload.mispredict_flag      <= 1'b0;            // §4.1 G2 zero
            wb_payload.mispredict_target_pc <= '0;              // §4.1 G2 zero
            wb_payload.exception_flag       <= 1'b0;            // §4.1 G2 zero
            wb_payload.exception_cause      <= '0;              // §4.1 G2 zero
            wb_payload.exception_tval       <= '0;              // §4.1 G2 zero
            wb_payload.is_mret              <= 1'b0;            // §4.1 G2 zero
            wb_payload.is_sret              <= 1'b0;            // §4.1 G2 zero
            wb_payload.fpu_fflags           <= fpu_fflags_c;    // §4.1 only G2 drives it
        end else begin
            wb_payload <= '0;
        end
    end

    // §4: lane 2 is driven directly -- G2 has no arbiter, so the ports carry
    // the bare completion_common names, matching CompletionScoreboard's frozen
    // writeback inputs verbatim.  No req_ prefix: that belongs to G0/G1.
    assign writeback_valid         = wb_payload.result_valid;
    assign tag_out              = wb_payload.tag_out;
    assign result_data          = wb_payload.result_data;

    // 两个仲裁器的公式是 bypass_publish_valid = winner_valid && !exception_flag。
    // G2 的 exception_flag 恒 0（FU接入契约 §4.1），该式在 lane 2 上退化成
    // writeback_valid。tag/data 与 lane-2 completion 同源同拍。
    assign bypass_publish_valid         = wb_payload.result_valid;
    assign bypass_tag           = wb_payload.tag_out;
    assign bypass_data          = wb_payload.result_data;
    assign mispredict_flag      = wb_payload.mispredict_flag;
    assign mispredict_target_pc = wb_payload.mispredict_target_pc;
    assign exception_flag       = wb_payload.exception_flag;
    assign exception_cause      = wb_payload.exception_cause;
    assign exception_tval       = wb_payload.exception_tval;
    assign is_mret              = wb_payload.is_mret;
    assign is_sret              = wb_payload.is_sret;
    assign fpu_fflags           = wb_payload.fpu_fflags;

endmodule

`endif // FPU_SIMPLE_SV
