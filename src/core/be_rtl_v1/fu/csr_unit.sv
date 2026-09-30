`ifndef CSR_UNIT_SV
`define CSR_UNIT_SV

/* verilator lint_off IMPORTSTAR */
import or_be_types_pkg::*;
import exe_subop_pkg::*;
/* verilator lint_on IMPORTSTAR */

// csr_unit -- G0 requester 1, the Zicsr execute-side FU.
//
// The instruction-side data path is the legality table (legal_csr_addr) and
// the CSRRW / CSRRS / CSRRC read-modify-write.  The boundary:
//
//   * types come from `or_be_types_pkg`; the completion request carries
//     completion_common + the lane-0 csr_sideband layer with the `req_`
//     prefix.
//   * the architectural CSR file, the P4 commit-time update path, the
//     performance counters and the architectural read mux are NOT here:
//     system_instruction_handler owns them.  This module has only a
//     combinational read port
//     (csr_fu -> SIH csr_addr, SIH -> csr_fu csr_rdata / current_priv /
//     mstatus_tvm / fs_enabled).
//   * capture is the issue handshake (capture = issue_valid & FU_ready),
//     and `FU_ready` is high when the FU can take an instruction.
//
// The three behaviour contracts:
//   * flush kills everything in flight and forbids request_valid this cycle
//   * the completion is registered one cycle after issue (whole
//     completion_common, not just the valid)
//   * FU_ready = 0 while executing, and 0 while loser_hold holds the output
//
// For G0: `fpu_fflags` must be driven to zero by the FU itself; the
// arbiter never fills a constant-zero field in.  CSR additionally produces no
// mispredict, and `is_mret` belongs to ALU0 (MRET takes the ALU SYS path),
// so both stay at zero here.
module csr_unit (
    input  logic                     clk,
    input  logic                     rst_n,

    // ------------------------------------------------------------------
    // in-event: flush (announce) -- single-wire pulse
    // ------------------------------------------------------------------
    input  logic                     global_flush_late,

    // ------------------------------------------------------------------
    // in-event: issue (move) -- the whole G0 bundle from ISQ_Group0, in
    // ISQ_Group0's port order.  Declared in full even though CSR reads only
    // rs1_data / self_tag / exe_subop / full_decode / inst_bits / FU_Group:
    // the per-group field list is fixed and must not be trimmed to a per-FU
    // subset.
    //
    // `issue_valid` is a request line, not a fire line: the transfer is
    // issue_valid & FU_ready, and the payload is held stable until then.
    // FU_Group is the *in-group* index (0 = ALU0/BRU, 1 = CSR, 2 = DIV).
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

    // ------------------------------------------------------------------
    // out: combinational read -- the software read address into
    // system_instruction_handler (csr_fu → SIH csr_addr).
    // Name and width are system_instruction_handler's, word for word.
    // ------------------------------------------------------------------
    output logic [CSR_ADDR_W-1:0]    csr_addr,

    // ------------------------------------------------------------------
    // in: combinational read --
    // SIH → csr_fu: CSR[csr_addr] old value, current_priv, fs_enabled.
    // Same three names and widths as system_instruction_handler's outputs.
    // A same-cycle broadcast that is never stored on this side.
    // ------------------------------------------------------------------
    input  logic [XLEN-1:0]          csr_rdata,
    input  logic [PRIV_W-1:0]        current_priv,
    // The bit M-mode uses to block S-mode access to satp.
    input  logic                     mstatus_tvm,
    input  logic                     fs_enabled,

    // ------------------------------------------------------------------
    // in-event: arbiter feedback.  winner_grant is the
    // trigger that retires the completion request; loser_hold is a level that
    // can stay high for many cycles while the request keeps losing.
    // ------------------------------------------------------------------
    input  logic                     winner_grant,
    input  logic                     loser_hold,

    // ------------------------------------------------------------------
    // out: combinational read -- ISQ_Group0 takes this as FU_ready[1].
    // 0 while executing, 0 while holding a lost completion request.
    // A pure state quantity with no combinational dependence on
    // issue_valid, so it never looks at whether anyone is asking.
    // ------------------------------------------------------------------
    output logic                     FU_ready,

    // ------------------------------------------------------------------
    // out-event: completion request -> p3_arbiter_G0 requester 1.
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

    // Layer 2, csr_sideband -- G0 only, and this is the FU that drives it
    // non-zero.  It bypasses the CompletionScoreboard entirely and goes
    // straight to system_instruction_handler.
    output logic                     req_is_csr,
    output logic                     req_csr_write_enable,
    output logic [CSR_ADDR_W-1:0]    req_csr_addr,
    output logic [XLEN-1:0]          req_csr_wdata
);

    // In-group identity comes from or_be_types_pkg (`G0_FU_CSR`), not from a
    // local constant: the chain ALU0/BRU(0) > CSR(1) > DIV(2) is fixed
    // for the whole group, so no single module owns that number.

    // Illegal instruction, the only cause this FU can raise.  63 bit -- the
    // cause number without the interrupt flag bit.
    localparam logic [EXCP_CAUSE_W-1:0] CAUSE_ILLEGAL_INSTRUCTION = EXCP_CAUSE_W'(2);

    // ------------------------------------------------------------------
    // Issue decode.  full_decode carries the two control fields:
    // csr_write_intent (bit 16) and csr_addr (bits 11:0).
    // ------------------------------------------------------------------
    full_decode_t fd;
    logic [CSR_ADDR_W-1:0] exe_csr_addr;
    logic                  csr_write_intent;
    logic                  fu_selected;
    logic                  accept;

    assign fd               = full_decode_t'(full_decode);
    assign exe_csr_addr     = fd.csr_addr;
    assign csr_write_intent = fd.csr_write_intent;

    // FU_Group is the in-group index; the FU uses it to tell whether this
    // issue is addressed to it.
    assign fu_selected = (FU_Group == FU_GROUP_W'(G0_FU_CSR));

    // Handshake: the capture condition is issue_valid & FU_ready, never
    // issue_valid alone.  Treating `en` as valid is additionally forbidden on
    // the flush cycle, so the term is repeated here even though ISQ_Group0
    // already gates its issue_valid with !global_flush_late.
    assign accept = issue_valid && fu_selected && FU_ready && !global_flush_late;

    // The software read address into system_instruction_handler.  Purely
    // combinational on both sides and it has no fire, so it is driven from the
    // live issue bundle; ISQ holds the payload stable until the handshake, so
    // the value sampled on the accept cycle is the right one.
    assign csr_addr = exe_csr_addr;

    // ------------------------------------------------------------------
    // Legality decode.
    //   * fs_enabled arrives from system_instruction_handler;
    //   * 0xB00 / 0xB02 are read/write, see the comment on that arm.
    //
    // With FS == Off the three FP addresses are ILLEGAL and this
    // FU must RAISE AN EXCEPTION, not merely clear csr_write_enable -- only
    // clearing the write enable would let the illegal access retire as an
    // ordinary completion.  exception_flag below is what implements that; the
    // write enable is cleared as well because system_instruction_handler
    // expects an illegal access to arrive with sb_csr_write_enable = 0.
    // ------------------------------------------------------------------
    // ------------------------------------------------------------------
    // Privilege check.  Without checking current_priv, a U-mode read of
    // mstatus would silently succeed.
    //
    // RISC-V encodes the lowest privilege level in CSR address bits [9:8]:
    // 00=U / 01=S / 11=M.  This is in exactly the same order as the
    // current_priv encoding (U=00 / S=01 / M=11), so they compare directly.
    // ------------------------------------------------------------------
    logic priv_ok;
    assign priv_ok = (csr_addr[9:8] <= current_priv);

    // TVM: once M-mode sets it, an S-mode access to satp is an illegal
    // instruction (spec).
    // **A separate term, not folded into the static table** -- the table says
    // "does this core have this address", this one is dynamic privilege
    // state; mix them and someone will inevitably change only one side.
    logic tvm_blocked;
    assign tvm_blocked = mstatus_tvm && (current_priv == 2'b01)
                      && (csr_addr == 12'h180);

    logic legal_csr_addr_tbl;
    logic legal_csr_addr;
    // The table decides "does this core have this address", the privilege
    // check decides "is the current level high enough"; both must pass.
    assign legal_csr_addr = legal_csr_addr_tbl && priv_ok && !tvm_blocked;

    always_comb begin
        unique case (exe_csr_addr)
            12'h001, 12'h002, 12'h003: legal_csr_addr_tbl = fs_enabled;
            12'h300, 12'h301, 12'h340, 12'h341, 12'h342, 12'h343,
            12'h305, 12'h304, 12'h344,
            // mcycle / minstret are M-mode read/WRITE counters, and
            // system_instruction_handler implements the write (ADDR_MCYCLE /
            // ADDR_MINSTRET in its apply path).  Putting them in the read-only
            // row would make `csrw mcycle` raise an illegal instruction.
            12'hB00, 12'hB02: legal_csr_addr_tbl = 1'b1;
            // PMP: this core implements 0 PMP regions.  The RISC-V privileged
            // spec then allows the PMP CSRs to be **hardwired to zero** (it
            // also allows omitting them as illegal).  Hardwired zero is chosen
            // here because the reference ISA model cannot turn PMP off (the
            // release YAML has no such switch); choosing illegal would make
            // cosim permanently fall two instructions out of step in the init
            // section of every riscv-tests test.
            // Writes are ignored, reads are constant 0; with 0 regions no
            // access check is done, which matches the model side configured
            // as allow-all (NAPOT|R|W|X covering the whole space).
            12'h3A0, 12'h3B0: legal_csr_addr_tbl = 1'b1;
            // medeleg / mideleg -- **real registers**, not hardwired zero.
            12'h302, 12'h303: legal_csr_addr_tbl = 1'b1;
            // S-mode CSRs.  sstatus/sie/sip are views of mstatus/mie/mip,
            // stvec/sscratch/sepc/scause/stval/satp are real registers.
            // satp's MODE is handled by SIH as WARL: with ENABLE_S it accepts
            // 0/8/9 (Bare/Sv39/Sv48), a write of any other MODE leaves satp
            // unchanged.  **The address is legal** -- flagging it illegal
            // would make the `csrwi satp,0` in every riscv-tests prologue
            // diverge from the reference model.
            // ENABLE_S comes from or_be_config_pkg; this file does not import
            // it and relies on the package having been imported elsewhere in
            // the compilation unit.
            12'h100, 12'h104, 12'h105,
            12'h140, 12'h141, 12'h142, 12'h143, 12'h144,
            12'h180: legal_csr_addr_tbl = ENABLE_S;
            12'hF11, 12'hF12, 12'hF13, 12'hF14: legal_csr_addr_tbl = !csr_write_intent;
            // cycle / instret are the read-only U-mode shadows of the two
            // counters above -- these are the genuinely read-only ones.
            12'hC00, 12'hC02: legal_csr_addr_tbl = !csr_write_intent;
            default: legal_csr_addr_tbl = 1'b0;
        endcase
    end

    // ------------------------------------------------------------------
    // Compute next write data based on Sub-Op.
    // The old value is system_instruction_handler's combinational csr_rdata;
    // the read mux lives there with the registers.
    // ------------------------------------------------------------------
    // Source operand of the CSR write data: rs1 for the register forms,
    // uimm for the immediate forms.
    logic [XLEN-1:0] csr_src;
    logic [XLEN-1:0] next_csr_wdata;
    logic            csr_write_en;

    always_comb begin
        next_csr_wdata = csr_rdata;
        csr_write_en   = 1'b0;

        // **Source operand selected by form**: CSRRW/S/C use rs1,
        // CSRRWI/SI/CI use uimm.
        // The immediate forms' uimm is placed into imm_data by decode (the
        // CSR branch of decode.sv, imm_valid = 1); in these three the rs1
        // field is uimm, not a register number (use_rs1 comes from FE's
        // opnd), so taking rs1_data here would be wrong --
        // rs1 is never even read for those three forms.
        // The csrwi in the riscv-tests init section all write 0, so they do
        // not cover this.
        csr_src = imm_valid ? imm_data : rs1_data;

        case (exe_subop)
            SUBOP_CSRRW, SUBOP_CSRRWI: begin
                next_csr_wdata = csr_src;
                csr_write_en   = 1'b1;
            end
            SUBOP_CSRRS, SUBOP_CSRRSI: begin
                next_csr_wdata = csr_rdata | csr_src;
                csr_write_en   = 1'b1;
            end
            SUBOP_CSRRC, SUBOP_CSRRCI: begin
                next_csr_wdata = csr_rdata & ~csr_src;
                csr_write_en   = 1'b1;
            end
            default: begin
                next_csr_wdata = csr_rdata;
                csr_write_en   = 1'b0;
            end
        endcase
    end

    // ------------------------------------------------------------------
    // FU_ready.
    //
    //   busy_q = an accepted instruction is still occupying the output
    //            register, i.e. its completion request has not been granted
    //
    // FU_ready = !busy_q & !loser_hold.  The loser_hold term is redundant --
    // loser_hold implies request_valid implies busy_q -- but it is written
    // out explicitly rather than left to be re-derived.
    // FU_ready deliberately does not look at issue_valid.
    // ------------------------------------------------------------------
    logic busy_q;

    assign FU_ready = !busy_q && !loser_hold;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            busy_q <= 1'b0;
        end else if (global_flush_late || winner_grant) begin
            // Everything in flight is voided unconditionally, no tag
            // compare -- a flush only happens at the commit point, so whatever
            // this FU holds is necessarily younger than the flush point.
            // winner_grant is the request's ready: the output register frees.
            // The two terms can share a branch because `accept` can never be
            // set at the same time as either one -- it carries
            // !global_flush_late, and FU_ready is 0 whenever busy_q is.
            busy_q <= 1'b0;
        end else if (accept) begin
            busy_q <= 1'b1;
        end
    end

    // ------------------------------------------------------------------
    // The completion register.  The whole completion_common plus
    // the csr_sideband layer is registered one cycle behind issue; a loser
    // holds it unchanged because accept cannot fire while busy_q is set.
    // ------------------------------------------------------------------
    logic [TAG_W-1:0]        tag_q;
    logic [XLEN-1:0]         result_data_q;
    logic                    exception_flag_q;
    logic [EXCP_CAUSE_W-1:0] exception_cause_q;
    logic [XLEN-1:0]         exception_tval_q;
    logic                    is_csr_q;
    logic                    csr_write_enable_q;
    logic [CSR_ADDR_W-1:0]   csr_addr_q;
    logic [XLEN-1:0]         csr_wdata_q;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            tag_q              <= '0;
            result_data_q      <= '0;
            exception_flag_q   <= 1'b0;
            exception_cause_q  <= '0;
            exception_tval_q   <= '0;
            is_csr_q           <= 1'b0;
            csr_write_enable_q <= 1'b0;
            csr_addr_q         <= '0;
            csr_wdata_q        <= '0;
        end else if (global_flush_late || winner_grant) begin
            tag_q              <= '0;
            result_data_q      <= '0;
            exception_flag_q   <= 1'b0;
            exception_cause_q  <= '0;
            exception_tval_q   <= '0;
            is_csr_q           <= 1'b0;
            csr_write_enable_q <= 1'b0;
            csr_addr_q         <= '0;
            csr_wdata_q        <= '0;
        end else if (accept) begin
            tag_q              <= self_tag;
            // the read value is bypassed and written to rd
            result_data_q      <= csr_rdata;
            exception_flag_q   <= !legal_csr_addr;
            exception_cause_q  <= !legal_csr_addr ? CAUSE_ILLEGAL_INSTRUCTION
                                                  : {EXCP_CAUSE_W{1'b0}};
            // tval for an illegal instruction is the instruction encoding.
            // inst_bits is carried to the execute side for exactly this, and
            // exception_tval is not among G0's zero fields.
            exception_tval_q   <= !legal_csr_addr ? {{(XLEN-32){1'b0}}, inst_bits}
                                                  : {XLEN{1'b0}};
            is_csr_q           <= 1'b1;
            csr_write_enable_q <= csr_write_en && csr_write_intent && legal_csr_addr;
            csr_addr_q         <= exe_csr_addr;
            // calculated next state
            csr_wdata_q        <= next_csr_wdata;
        end
    end

    // ------------------------------------------------------------------
    // Completion request drive.  No request_valid on the flush cycle.
    // ------------------------------------------------------------------
    assign request_valid        = busy_q && !global_flush_late;
    assign req_tag              = tag_q;
    assign req_result_data      = result_data_q;
    assign req_exception_flag   = exception_flag_q;
    assign req_exception_cause  = exception_cause_q;
    assign req_exception_tval   = exception_tval_q;
    assign req_is_csr           = is_csr_q;
    assign req_csr_write_enable = csr_write_enable_q;
    assign req_csr_addr         = csr_addr_q;
    assign req_csr_wdata        = csr_wdata_q;

    // Constant-zero fields, driven by the FU itself -- the arbiter
    // never fabricates them.  CSR produces no mispredict; is_mret belongs to
    // ALU0/BRU; fpu_fflags is zero for the whole of G0.
    assign req_mispredict_flag      = 1'b0;
    assign req_mispredict_target_pc = '0;
    assign req_is_mret              = 1'b0;
    // SRET, like MRET, goes through ALU0's SYS path; it is not a CSR instruction.
    assign req_is_sret              = 1'b0;
    assign req_fpu_fflags           = '0;

`ifndef SYNTHESIS
    // Flush self-check.  It is an assertion, not
    // function: a completion request must never survive a flush by one cycle.
    logic global_flush_late_q;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            global_flush_late_q <= 1'b0;
        end else begin
            global_flush_late_q <= global_flush_late;
            if (global_flush_late_q && request_valid) begin
                $error("[CSR] stale completion after flush: request_valid=%0b tag=%0d csr_addr=0x%03h",
                       request_valid, req_tag, req_csr_addr);
                $stop;
            end
        end
    end
`endif

endmodule

`endif // CSR_UNIT_SV
