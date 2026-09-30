`ifndef SYSTEM_INSTRUCTION_HANDLER_SV
`define SYSTEM_INSTRUCTION_HANDLER_SV

/* verilator lint_off IMPORTSTAR */
import or_be_types_pkg::*;
import or_be_config_pkg::*;
/* verilator lint_on IMPORTSTAR */

// system_instruction_handler -- architectural CSR file, privilege state and
// csr_stage.
//
// (1) per-entry state          : csr_stage.valid -- EMPTY / STAGED.  The one
//                                speculative register here; the architectural
//                                registers have values but no lifecycle.
// (2) state transition         : EMPTY -> STAGED on capture,
//                                STAGED -> EMPTY on apply_fire / flush.
//                                Architectural writes are events, not stages:
//                                apply / trap_entry (to M or, delegated, to S)
//                                / mret_update / sret_update /
//                                fflags_accrue, plus the counter increments.
// (3) condition                : capture   = Result_valid & sb_is_csr &
//                                            sb_csr_write_enable & !flush
//                                apply_fire= csr_stage.valid & tag hit on
//                                            either commit lane
// (4) data path                : 1 architectural write port (apply), the trap
//                                boundary write, the FP retire accrue, two
//                                free-running counters, and three
//                                combinational read ports (csr_rdata,
//                                trap_vector, the Static Info projections)
// (5) data structure           : csr_stage{valid,tag,addr,wdata} +
//                                mstatus / mie / mtvec / mepc / mcause /
//                                mtval / mscratch / mcycle / minstret /
//                                fflags / frm, plus stvec / sepc /
//                                scause / stval / sscratch / medeleg /
//                                mideleg / satp.  misa and the four ID
//                                registers have no storage at all; of mip
//                                only SSIP is stored.
//
// **M + S + U**.  current_priv and
// mstatus.MPP are real registers -- see the block at `mstatus_mpp_q`.
// MPP is WARL-clamped to the implemented levels: {M, S, U} with ENABLE_S,
// {M, U} without (reserved / unimplemented values clamp to U).  Traps are
// delegated to S via medeleg / mideleg when current_priv != M.  mip is the
// three top-level M levels plus the stored SSIP (writable when ENABLE_S);
// SEIP / STIP read 0.
//
// The capture-side sideband carries the sb_ prefix so the write address
// sb_csr_addr stays apart from csr_addr, which is the software read port.
//
// global_flush_late clears csr_stage.valid and nothing else: the architectural
// registers hold no speculative state, so there is nothing to roll back.
// ENABLE_A / ENABLE_C / ENABLE_FD / ENABLE_S / ENABLE_U come from
// or_be_config_pkg, NOT from module
// parameters: the same switches drive misa, decode, FE and the LSU, and those
// four must agree.  A per-module parameter can be overridden at one
// instantiation and not another, which is exactly that failure.
module system_instruction_handler (
    input  logic                      clk,
    input  logic                      rst_n,

    // in-event: capture (announce x1) -- p3_arbiter_G0 lane 0 only.
    // Result_valid / tag_out are the completion_common trigger and identity;
    // the sb_* four are the lane-0 sideband layer, which never enters the SCB.
    input  logic                      Result_valid,
    input  logic [TAG_W-1:0]          tag_out,
    input  logic                      sb_is_csr,
    input  logic                      sb_csr_write_enable,
    // 12 bit -- the very same field as full_decode_t.csr_addr, whose width is
    // FULL_DECODE_W(17) - csr_write_intent(1) - illegal(1) - rm(3).
    input  logic [CSR_ADDR_W-1:0]   sb_csr_addr,
    input  logic [XLEN-1:0]           sb_csr_wdata,

    // in-event: commit (announce, 2 lanes) -- tag compare for apply, fflags /
    // FS accrue, and the minstret increment.
    input  logic                      commit_valid    [ISSUE_WIDTH],
    input  logic [TAG_W-1:0]          commit_tag      [ISSUE_WIDTH],
    input  logic [FFLAGS_W-1:0]       commit_fflags   [ISSUE_WIDTH],
    input  logic                      rd_is_fp        [ISSUE_WIDTH],
    input  logic                      rd_write_enable [ISSUE_WIDTH],
    // 0..ISSUE_WIDTH retirements per cycle, so 2 bit at ISSUE_WIDTH = 2.
    input  logic [COMMIT_COUNT_W-1:0] commit_count,

    // in-event: trap_state_write (announce x1) -- {valid, kind, epc, cause,
    // tval}; MISPREDICT / FENCE_I never arrive with valid set.
    input  trap_state_write_t         trap_state_write,

    // in-event: flush (announce) -- single wire pulse, clears csr_stage only
    input  logic                      global_flush_late,

    // in-event: combinational read side.  csr_addr is the software read
    // address from csr_fu; trap_cause_in / trap_is_interrupt_in are the
    // trap_vector arguments; the three mip levels are driven straight from the
    // top level, no fire and no storage.
    input  logic [CSR_ADDR_W-1:0]   csr_addr,
    input  logic [EXCP_CAUSE_W-1:0]   trap_cause_in,
    input  logic                      trap_is_interrupt_in,
    input  logic                      mip_meip,
    input  logic                      mip_mtip,
    input  logic                      mip_msip,

    // out-event: combinational reads.  csr_rdata is CSR[csr_addr].
    output logic [XLEN-1:0]           csr_rdata,
    output logic [PRIV_W-1:0]         current_priv,
    // 3 bit -- the rounding mode is the same width as full_decode_t.rm, i.e.
    // FULL_DECODE_W(17) - csr_write_intent(1) - illegal(1) - csr_addr(12).
    output rm_e                       frm,
    output logic                      fs_enabled,
    output logic [XLEN-1:0]           trap_vector,

    // Static Info -- no fire, no external argument
    output logic                      interrupt_pending,
    output logic [EXCP_CAUSE_W-1:0]   interrupt_cause,
    output logic [XLEN-1:0]           mepc,
    // SRET recovery PC. Same nature as mepc -- the architectural register
    // itself, read by name, no address.
    output logic [XLEN-1:0]           sepc,
    // The three "intercept S-mode operation" bits, sent to the two consumers
    // that make the legality decision.
    //   tvm → csr_unit  (S-mode access to satp judged illegal)
    //       → ALU0/BRU  (S-mode SFENCE.VMA judged illegal)
    //   tsr → ALU0/BRU  (S-mode SRET judged illegal)
    //   tw  → ALU0/BRU  (S-mode WFI judged illegal)
    output logic                      mstatus_tvm,
    output logic                      mstatus_tw,
    output logic                      mstatus_tsr
);

    // ------------------------------------------------------------------
    // Local constants
    // ------------------------------------------------------------------
    // CSR_ADDR_W comes from or_be_types_pkg; no local localparam of the same
    // name is declared here, so as not to shadow the one in the package.
    localparam int FRM_W      = $bits(rm_e);
    localparam int FS_W       = 2;
    localparam int MTVEC_MODE_W = 2;

    // mstatus / mie / mip field positions (RISC-V machine mode).
    localparam int BIT_MIE    = 3;
    localparam int BIT_MPIE   = 7;
    // RV64 mstatus XLEN fields. UXL reports the U-mode XLEN, SXL the S-mode one.
    // This implementation has both S and U: both follow ENABLE_S / ENABLE_U (see
    // the read-side views).
    localparam int BIT_SXL_HI = 35;
    localparam int BIT_SXL_LO = 34;
    localparam int BIT_UXL_HI = 33;
    localparam int BIT_UXL_LO = 32;
    localparam int BIT_MPP_HI = 12;
    localparam int BIT_MPP_LO = 11;
    localparam int BIT_FS_HI  = 14;
    localparam int BIT_FS_LO  = 13;
    localparam int BIT_SD     = XLEN - 1;
    localparam int BIT_MEI    = 11;   // mip.MEIP / mie.MEIE, interrupt cause 11
    localparam int BIT_MTI    = 7;    // mip.MTIP / mie.MTIE, interrupt cause 7
    localparam int BIT_MSI    = 3;    // mip.MSIP / mie.MSIE, interrupt cause 3
    localparam int BIT_SEI    = 9;    // mip.SEIP / mie.SEIE, interrupt cause 9
    localparam int BIT_STI    = 5;    // mip.STIP / mie.STIE, interrupt cause 5
    localparam int BIT_SSI    = 1;    // mip.SSIP / mie.SSIE, interrupt cause 1
    localparam int BIT_SIE    = 1;    // mstatus.SIE
    localparam int BIT_SPIE   = 5;    // mstatus.SPIE
    localparam int BIT_SPP    = 8;    // mstatus.SPP (one bit)
    // The three bits that intercept S-mode privileged operations. Only machines
    // with S-mode define them; since misa reports S, these three bits must
    // exist -- otherwise it is again "declared but absent".
    // The two paged-virtual-memory control bits. Spec: **read-only 0 when paged
    // virtual memory is not implemented**, writable only when implemented. This
    // core's satp accepts Sv39/Sv48 (translation is not in the backend; this
    // module only holds satp_q, read out via csr_rdata, with no satp output
    // port <needs confirmation>), hence writable.
    localparam int BIT_SUM    = 18;   // may S-mode access U pages
    localparam int BIT_MXR    = 19;   // may executable pages be read as readable
    localparam int BIT_TVM    = 20;   // intercept S-mode satp access / sfence.vma
    localparam int BIT_TW     = 21;   // intercept S-mode WFI
    localparam int BIT_TSR    = 22;   // intercept S-mode SRET
    localparam logic [PRIV_W-1:0] PRIV_S = 2'b01;
    // Delegation masks. Spec hard requirement: M-mode interrupts are not
    // delegable, M-mode ECALL is not delegable.
    // With ENABLE_S = 0 both registers are constant 0 as a whole (see reset and
    // apply).
    localparam logic [XLEN-1:0] MIDELEG_MASK =
        (64'(1) << BIT_SEI) | (64'(1) << BIT_STI) | (64'(1) << BIT_SSI);
    // Of sync exception causes 0..15, cause 11 (M-mode ECALL) is constant 0;
    // the rest are delegable.
    localparam logic [XLEN-1:0] MEDELEG_MASK = 64'h0000_0000_0000_F7FF;
    // satp.MODE field position. WARL: accepts Bare(0) / Sv39(8) / Sv48(9), see
    // apply.
    localparam int BIT_SATP_MODE_HI = 63;
    localparam int BIT_SATP_MODE_LO = 60;

    localparam logic [PRIV_W-1:0] PRIV_M = 2'b11;
    localparam logic [PRIV_W-1:0] PRIV_U = 2'b00;

    localparam logic [FS_W-1:0] FS_OFF   = 2'b00;
    localparam logic [FS_W-1:0] FS_DIRTY = 2'b11;

    localparam logic [MTVEC_MODE_W-1:0] MTVEC_MODE_DIRECT   = 2'b00;
    localparam logic [MTVEC_MODE_W-1:0] MTVEC_MODE_VECTORED = 2'b01;
    // MTVEC_MODE has no references at all:
    // the MODE of mtvec / stvec is a register (mtvec_mode_q / stvec_mode_q),
    // WARL to {Direct, Vectored}, see apply and trap_vector.
    localparam logic [MTVEC_MODE_W-1:0] MTVEC_MODE = MTVEC_MODE_DIRECT;

    // fcsr = {frm, fflags}: no register of its own, just the two halves.
    localparam int FCSR_FRM_LSB = FFLAGS_W;

    // CSR addresses.  0x001 / 0x002 / 0x003 are fixed; the rest are the standard
    // machine-mode numbers for the registers (5) names.
    localparam logic [CSR_ADDR_W-1:0] ADDR_FFLAGS    = 'h001;
    localparam logic [CSR_ADDR_W-1:0] ADDR_FRM       = 'h002;
    localparam logic [CSR_ADDR_W-1:0] ADDR_FCSR      = 'h003;
    localparam logic [CSR_ADDR_W-1:0] ADDR_MSTATUS   = 'h300;
    localparam logic [CSR_ADDR_W-1:0] ADDR_MISA      = 'h301;
    localparam logic [CSR_ADDR_W-1:0] ADDR_MIE       = 'h304;
    localparam logic [CSR_ADDR_W-1:0] ADDR_MTVEC     = 'h305;
    localparam logic [CSR_ADDR_W-1:0] ADDR_MSCRATCH  = 'h340;
    localparam logic [CSR_ADDR_W-1:0] ADDR_MEPC      = 'h341;
    localparam logic [CSR_ADDR_W-1:0] ADDR_MCAUSE    = 'h342;
    localparam logic [CSR_ADDR_W-1:0] ADDR_MTVAL     = 'h343;
    localparam logic [CSR_ADDR_W-1:0] ADDR_MIP       = 'h344;
    localparam logic [CSR_ADDR_W-1:0] ADDR_MCYCLE    = 'hB00;
    localparam logic [CSR_ADDR_W-1:0] ADDR_MINSTRET  = 'hB02;
    localparam logic [CSR_ADDR_W-1:0] ADDR_CYCLE     = 'hC00;   // read-only alias
    localparam logic [CSR_ADDR_W-1:0] ADDR_INSTRET   = 'hC02;   // read-only alias
    // PMP: 0 regions, CSRs hardwired to zero (allowed by the RISC-V privileged
    // spec). They appear only in the read mux, returning 0; the apply path
    // **stores no register for them**.
    localparam logic [CSR_ADDR_W-1:0] ADDR_MEDELEG   = 'h302;
    localparam logic [CSR_ADDR_W-1:0] ADDR_MIDELEG   = 'h303;
    localparam logic [CSR_ADDR_W-1:0] ADDR_PMPCFG0   = 'h3A0;
    localparam logic [CSR_ADDR_W-1:0] ADDR_PMPADDR0  = 'h3B0;
    // S-mode CSRs. sstatus/sie/sip are views of mstatus/mie/mip, not independent
    // storage, but each has its own address, so reads and writes must be
    // recognised here (window definition: see the read-side views).
    localparam logic [CSR_ADDR_W-1:0] ADDR_SSTATUS   = 'h100;
    localparam logic [CSR_ADDR_W-1:0] ADDR_SIE       = 'h104;
    localparam logic [CSR_ADDR_W-1:0] ADDR_STVEC     = 'h105;
    localparam logic [CSR_ADDR_W-1:0] ADDR_SSCRATCH  = 'h140;
    localparam logic [CSR_ADDR_W-1:0] ADDR_SEPC      = 'h141;
    localparam logic [CSR_ADDR_W-1:0] ADDR_SCAUSE    = 'h142;
    localparam logic [CSR_ADDR_W-1:0] ADDR_STVAL     = 'h143;
    localparam logic [CSR_ADDR_W-1:0] ADDR_SIP       = 'h144;
    localparam logic [CSR_ADDR_W-1:0] ADDR_SATP      = 'h180;

    localparam logic [CSR_ADDR_W-1:0] ADDR_MVENDORID = 'hF11;
    localparam logic [CSR_ADDR_W-1:0] ADDR_MARCHID   = 'hF12;
    localparam logic [CSR_ADDR_W-1:0] ADDR_MIMPID    = 'hF13;
    localparam logic [CSR_ADDR_W-1:0] ADDR_MHARTID   = 'hF14;

    // ------------------------------------------------------------------
    // (5) misa -- not a constant, a read-only value packed from the static
    // configuration.  MXL = 2 (RV64); an extension bit is 1 only when that
    // extension is actually built.  All on -> 0x8000_0000_0000_112D.
    // ------------------------------------------------------------------
    localparam int MISA_EXT_W  = 26;          // one bit per ISA letter
    localparam int BIT_MISA_A  = 0;
    localparam int BIT_MISA_C  = 2;
    localparam int BIT_MISA_D  = 3;
    localparam int BIT_MISA_F  = 5;
    localparam int BIT_MISA_I  = 8;
    localparam int BIT_MISA_M  = 12;
    // The privilege levels are reported in misa too. **Omitting them =
    // declaration inconsistent with implementation** -- with ENABLE_S = 1, all
    // S-mode CSRs present and mstatus.SXL reading 2, while misa says no S,
    // software reading these two would get conflicting answers.
    localparam int BIT_MISA_S  = 18;
    localparam int BIT_MISA_U  = 20;
    localparam logic [1:0] MISA_MXL_64 = 2'b10;

    localparam logic [MISA_EXT_W-1:0] MISA_EXT =
          (MISA_EXT_W'(ENABLE_A)  << BIT_MISA_A)
        | (MISA_EXT_W'(ENABLE_C)  << BIT_MISA_C)
        | (MISA_EXT_W'(ENABLE_FD) << BIT_MISA_D)
        | (MISA_EXT_W'(ENABLE_FD) << BIT_MISA_F)
        | (MISA_EXT_W'(1'b1)      << BIT_MISA_I)
        | (MISA_EXT_W'(1'b1)      << BIT_MISA_M)
        | (MISA_EXT_W'(ENABLE_S)  << BIT_MISA_S)
        | (MISA_EXT_W'(ENABLE_U)  << BIT_MISA_U);

    localparam logic [XLEN-1:0] MISA_VALUE =
        {MISA_MXL_64, {(XLEN-2-MISA_EXT_W){1'b0}}, MISA_EXT};

    // ------------------------------------------------------------------
    // (5) csr_stage -- the only speculative register
    // ------------------------------------------------------------------
    logic                  stage_valid_q;
    logic [TAG_W-1:0]      stage_tag_q;
    logic [CSR_ADDR_W-1:0] stage_addr_q;
    logic [XLEN-1:0]       stage_wdata_q;

    // ------------------------------------------------------------------
    // (5) architectural registers.  Only the implemented bits are stored:
    // mstatus.SD (derived from FS), misa and the four ID registers have no
    // storage, mip stores only SSIP, and mtvec / stvec keep BASE plus a
    // WARL MODE register.
    // ------------------------------------------------------------------
    logic              mstatus_mie_q;
    logic              mstatus_mpie_q;
    logic [FS_W-1:0]   mstatus_fs_q;
    // MPP and the current privilege level are both real registers (M + S + U).
    logic [PRIV_W-1:0] mstatus_mpp_q;
    logic [PRIV_W-1:0] current_priv_q;
    // The three S-mode bits. Constant 0 with ENABLE_S = 0 (already stated in
    // the read-side view).
    logic              mstatus_sie_q;
    logic              mstatus_spie_q;
    logic              mstatus_spp_q;      // one bit: S(1) / U(0)
    logic              mstatus_sum_q;
    logic              mstatus_mxr_q;
    logic              mstatus_tvm_q;
    logic              mstatus_tw_q;
    logic              mstatus_tsr_q;

    logic              mie_meie_q;
    logic              mie_mtie_q;
    logic              mie_msie_q;
    logic              mie_seie_q;
    logic              mie_stie_q;
    logic              mie_ssie_q;

    // The only bit of mip with storage. The other bits are top-level levels or
    // constant 0.
    logic              mip_ssip_q;

    logic [XLEN-1:MTVEC_MODE_W]  mtvec_base_q;
    // MODE is a WARL register, values {Direct, Vectored}.
    logic [MTVEC_MODE_W-1:0]     mtvec_mode_q;
    logic [XLEN-1:MTVEC_MODE_W]  stvec_base_q;
    logic [MTVEC_MODE_W-1:0]     stvec_mode_q;

    logic [XLEN-1:0]     mepc_q;
    logic [XLEN-1:0]     mcause_q;
    logic [XLEN-1:0]     mtval_q;
    logic [XLEN-1:0]     mscratch_q;
    logic [XLEN-1:0]     mcycle_q;
    logic [XLEN-1:0]     minstret_q;
    logic [FFLAGS_W-1:0] fflags_q;
    logic [FRM_W-1:0]    frm_q;

    // S-mode trap group + delegation + satp.
    logic [XLEN-1:0]     sepc_q;
    logic [XLEN-1:0]     scause_q;
    logic [XLEN-1:0]     stval_q;
    logic [XLEN-1:0]     sscratch_q;
    logic [XLEN-1:0]     medeleg_q;
    logic [XLEN-1:0]     mideleg_q;
    // satp: MODE(63:60) WARL, accepts Bare(0)/Sv39(8)/Sv48(9); a write with any
    // other MODE leaves the whole word unchanged.
    logic [XLEN-1:0]     satp_q;

    // ------------------------------------------------------------------
    // (3) capture -- lane 0 only.  MRET carries sb_is_csr = 0 so it never
    // fires this, and an illegal CSR access arrives with sb_csr_write_enable =
    // 0 because csr_fu already judged it on the execute side.
    // ------------------------------------------------------------------
    logic capture;
    assign capture = Result_valid && sb_is_csr
                     && sb_csr_write_enable && !global_flush_late;

    // ------------------------------------------------------------------
    // (3) apply_fire -- the staged intent proves its identity by tag against
    // either commit lane.  Not gated by global_flush_late: this is the
    // architectural effect of an instruction that has already retired.
    // ------------------------------------------------------------------
    logic stage_tag_hit;
    logic apply_fire;

    always_comb begin
        stage_tag_hit = 1'b0;
        for (int unsigned k = 0; k < ISSUE_WIDTH; k++) begin
            if (commit_valid[k] && (commit_tag[k] == stage_tag_q)) begin
                stage_tag_hit = 1'b1;
            end
        end
    end

    assign apply_fire = stage_valid_q && stage_tag_hit;

    // ------------------------------------------------------------------
    // (3) fflags_accrue -- both lanes just OR in; fflags is a sticky flag
    // set, so there is nothing to arbitrate.  FS goes Dirty only when the
    // lane really wrote an FP register or really produced a flag, which is
    // why rd_write_enable has to qualify rd_is_fp.  This path only ever
    // drives FS towards Dirty, never back to Off.
    // ------------------------------------------------------------------
    logic [FFLAGS_W-1:0] fflags_accrued;
    logic                fp_dirty;

    always_comb begin
        fflags_accrued = '0;
        fp_dirty       = 1'b0;
        for (int unsigned k = 0; k < ISSUE_WIDTH; k++) begin
            if (commit_valid[k]) begin
                fflags_accrued = fflags_accrued | commit_fflags[k];
                fp_dirty = fp_dirty
                           || (rd_write_enable[k] && rd_is_fp[k])
                           || (commit_fflags[k] != '0);
            end
        end
    end

    // ------------------------------------------------------------------
    // (3) trap boundary.  kind selects which hardware write runs (trap_entry,
    // to M or delegated to S / mret_update / sret_update);
    // MISPREDICT / FENCE_I arrive with valid = 0 and are ignored here anyway.
    // mret_update / sret_update consume kind alone -- epc / cause / tval carry values on
    // the bus but this module does not sample them, and MRET must not write
    // mepc because it is about to read it as the resume PC.
    // ------------------------------------------------------------------
    logic trap_entry;
    logic mret_update;

    assign trap_entry = trap_state_write.valid
                        && ((trap_state_write.kind == RECOVERY_EXCEPTION)
                            || (trap_state_write.kind == RECOVERY_INTERRUPT));
    assign mret_update = trap_state_write.valid
                         && (trap_state_write.kind == RECOVERY_MRET);
    logic sret_update;
    assign sret_update = trap_state_write.valid
                         && (trap_state_write.kind == RECOVERY_SRET);

    // The landing level is decided by delegation. **Delegation is possible only
    // when current_priv != M** -- a trap taken in M-mode always goes to M,
    // regardless of medeleg/mideleg (spec: delegation cannot send a trap to a
    // privilege level lower than the current one). With ENABLE_S = 0 both deleg
    // registers are constant 0, so delegated is naturally constant 0.
    logic trap_delegated;
    always_comb begin
        trap_delegated = 1'b0;
        if (ENABLE_S && (current_priv_q != PRIV_M) && trap_state_write.valid) begin
            if (trap_state_write.kind == RECOVERY_INTERRUPT)
                trap_delegated = mideleg_q[trap_state_write.cause[5:0]];
            else if (trap_state_write.kind == RECOVERY_EXCEPTION)
                trap_delegated = medeleg_q[trap_state_write.cause[5:0]];
        end
    end

    // trap_state_write.cause is always the plain cause number without bit 63;
    // only mcause gets the interrupt bit pasted on.
    logic [XLEN-1:0] mcause_trap_value;
    assign mcause_trap_value =
        {(trap_state_write.kind == RECOVERY_INTERRUPT), trap_state_write.cause};

    // ------------------------------------------------------------------
    // (2)(4) csr_stage sequencing
    // ------------------------------------------------------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            stage_valid_q <= 1'b0;
            stage_tag_q   <= '0;
            stage_addr_q  <= '0;
            stage_wdata_q <= '0;
        end else begin
            stage_valid_q <= (global_flush_late || apply_fire) ? 1'b0
                             : (capture ? 1'b1 : stage_valid_q);
            if (capture) begin
                stage_tag_q   <= tag_out;
                stage_addr_q  <= sb_csr_addr;
                stage_wdata_q <= sb_csr_wdata;
            end
        end
    end

    // ------------------------------------------------------------------
    // architectural write ports, in this order:
    //
    //   counters      free-running, then
    //   fflags_accrue FP retire side effect, then
    //   apply         the software write lands last of the two so a software
    //                 write of mcycle / minstret / fcsr overrides the same
    //                 cycle's increment or accrue, then
    //   trap          the hardware trap boundary wins over everything.
    //
    // Only the last non-blocking assignment to a given register survives, so
    // this ordering *is* the priority.  The serialisation invariant means
    // apply never actually collides with accrue or with a trap; the ordering
    // only pins down what would otherwise be undefined.
    // ------------------------------------------------------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            mstatus_mie_q  <= 1'b0;
            mstatus_mpie_q <= 1'b0;
            mstatus_fs_q   <= FS_OFF;
            mstatus_mpp_q  <= PRIV_M;
            current_priv_q <= PRIV_M;   // reset into M-mode
            mstatus_sie_q  <= 1'b0;
            mstatus_spie_q <= 1'b0;
            mstatus_spp_q  <= 1'b0;
            mstatus_sum_q  <= 1'b0;
            mstatus_mxr_q  <= 1'b0;
            mstatus_tvm_q  <= 1'b0;
            mstatus_tw_q   <= 1'b0;
            mstatus_tsr_q  <= 1'b0;
            mie_meie_q     <= 1'b0;
            mie_mtie_q     <= 1'b0;
            mie_msie_q     <= 1'b0;
            mie_seie_q     <= 1'b0;
            mie_stie_q     <= 1'b0;
            mie_ssie_q     <= 1'b0;
            mip_ssip_q     <= 1'b0;
            mtvec_base_q   <= '0;
            mtvec_mode_q   <= MTVEC_MODE_DIRECT;
            stvec_base_q   <= '0;
            stvec_mode_q   <= MTVEC_MODE_DIRECT;
            sepc_q         <= '0;
            scause_q       <= '0;
            stval_q        <= '0;
            sscratch_q     <= '0;
            medeleg_q      <= '0;
            mideleg_q      <= '0;
            satp_q         <= '0;
            mepc_q         <= '0;
            mcause_q       <= '0;
            mtval_q        <= '0;
            mscratch_q     <= '0;
            mcycle_q       <= '0;
            minstret_q     <= '0;
            fflags_q       <= '0;
            frm_q          <= FRM_W'(RM_RNE);
        end else begin
            // counters: mcycle += 1 every cycle, minstret += commit_count
            mcycle_q   <= mcycle_q   + XLEN'(1);
            minstret_q <= minstret_q + XLEN'(commit_count);

            // fflags_accrue: sticky OR, plus the one-way FS -> Dirty
            fflags_q <= fflags_q | fflags_accrued;
            if (fp_dirty) begin
                mstatus_fs_q <= FS_DIRTY;
            end

            // apply: per-register writable masks, never a whole-word store.
            // Legality is not re-judged here -- csr_fu already did that.  A
            // write that lands on the hardwired group or on mip is silently
            // dropped (WARL), which is why they have no case arm.
            if (apply_fire) begin
                case (stage_addr_q)
                    ADDR_FFLAGS: begin
                        fflags_q     <= stage_wdata_q[FFLAGS_W-1:0];
                        mstatus_fs_q <= FS_DIRTY;
                    end
                    ADDR_FRM: begin
                        frm_q        <= stage_wdata_q[FRM_W-1:0];
                        mstatus_fs_q <= FS_DIRTY;
                    end
                    ADDR_FCSR: begin
                        fflags_q     <= stage_wdata_q[FFLAGS_W-1:0];
                        frm_q        <= stage_wdata_q[FCSR_FRM_LSB +: FRM_W];
                        mstatus_fs_q <= FS_DIRTY;
                    end
                    ADDR_MSTATUS: begin
                        // MIE / MPIE / FS / MPP are writable (plus the S-mode
                        // fields below when ENABLE_S).  MPP is stored and
                        // WARL-clamped as below; SD is derived from FS.
                        mstatus_mie_q  <= stage_wdata_q[BIT_MIE];
                        mstatus_mpie_q <= stage_wdata_q[BIT_MPIE];
                        mstatus_fs_q   <= stage_wdata_q[BIT_FS_HI:BIT_FS_LO];
                        // MPP is WARL, clamped to the **implemented**
                        // privilege levels.
                        // ENABLE_S = 1 ⇒ {M, S, U}, reserved value 10 clamps to U;
                        // ENABLE_S = 0 ⇒ {M, U}, a write of S also clamps to U.
                        mstatus_mpp_q  <=
                            (stage_wdata_q[BIT_MPP_HI:BIT_MPP_LO] == PRIV_M) ? PRIV_M :
                            (ENABLE_S &&
                             stage_wdata_q[BIT_MPP_HI:BIT_MPP_LO] == PRIV_S) ? PRIV_S :
                                                                               PRIV_U;
                        if (ENABLE_S) begin
                            mstatus_sie_q  <= stage_wdata_q[BIT_SIE];
                            mstatus_spie_q <= stage_wdata_q[BIT_SPIE];
                            mstatus_spp_q  <= stage_wdata_q[BIT_SPP];
                            // TVM/TW/TSR are writable only in mstatus, **not in
                            // the sstatus window**: M-mode uses them to intercept
                            // S-mode, S itself can neither see nor change them.
                            mstatus_sum_q  <= stage_wdata_q[BIT_SUM];
                            mstatus_mxr_q  <= stage_wdata_q[BIT_MXR];
                            mstatus_tvm_q  <= stage_wdata_q[BIT_TVM];
                            mstatus_tw_q   <= stage_wdata_q[BIT_TW];
                            mstatus_tsr_q  <= stage_wdata_q[BIT_TSR];
                        end
                    end
                    // sstatus is a **windowed view** of mstatus, not an
                    // independent register: only the in-window bits change
                    // (FS / SPP / SPIE / SIE), MIE/MPIE/MPP stay untouched.
                    ADDR_SSTATUS: if (ENABLE_S) begin
                        mstatus_fs_q   <= stage_wdata_q[BIT_FS_HI:BIT_FS_LO];
                        mstatus_spp_q  <= stage_wdata_q[BIT_SPP];
                        mstatus_spie_q <= stage_wdata_q[BIT_SPIE];
                        mstatus_sie_q  <= stage_wdata_q[BIT_SIE];
                        // SUM / MXR **are** inside the sstatus visible window
                        // (they are for S-mode use); TVM / TW / TSR are not
                        // (M-mode uses those to intercept S-mode).
                        mstatus_sum_q  <= stage_wdata_q[BIT_SUM];
                        mstatus_mxr_q  <= stage_wdata_q[BIT_MXR];
                    end
                    ADDR_MIE: begin
                        mie_meie_q <= stage_wdata_q[BIT_MEI];
                        mie_mtie_q <= stage_wdata_q[BIT_MTI];
                        mie_msie_q <= stage_wdata_q[BIT_MSI];
                        if (ENABLE_S) begin
                            mie_seie_q <= stage_wdata_q[BIT_SEI];
                            mie_stie_q <= stage_wdata_q[BIT_STI];
                            mie_ssie_q <= stage_wdata_q[BIT_SSI];
                        end
                    end
                    // sie is the windowed view of mie through mideleg.
                    ADDR_SIE: if (ENABLE_S) begin
                        if (mideleg_q[BIT_SEI]) mie_seie_q <= stage_wdata_q[BIT_SEI];
                        if (mideleg_q[BIT_STI]) mie_stie_q <= stage_wdata_q[BIT_STI];
                        if (mideleg_q[BIT_SSI]) mie_ssie_q <= stage_wdata_q[BIT_SSI];
                    end
                    // mip: only SSIP has storage and is writable. The three
                    // M-mode bits are top-level levels; writes are ignored.
                    ADDR_MIP: if (ENABLE_S) mip_ssip_q <= stage_wdata_q[BIT_SSI];
                    // sip: S can only write SSIP when it is delegated.
                    ADDR_SIP: if (ENABLE_S && mideleg_q[BIT_SSI])
                                  mip_ssip_q <= stage_wdata_q[BIT_SSI];
                    // MODE is WARL: {Direct, Vectored} accepted, a reserved
                    // value keeps the old value.
                    ADDR_MTVEC: begin
                        mtvec_base_q <= stage_wdata_q[XLEN-1:MTVEC_MODE_W];
                        if (stage_wdata_q[MTVEC_MODE_W-1:0] == MTVEC_MODE_DIRECT ||
                            stage_wdata_q[MTVEC_MODE_W-1:0] == MTVEC_MODE_VECTORED)
                            mtvec_mode_q <= stage_wdata_q[MTVEC_MODE_W-1:0];
                    end
                    ADDR_STVEC: if (ENABLE_S) begin
                        stvec_base_q <= stage_wdata_q[XLEN-1:MTVEC_MODE_W];
                        if (stage_wdata_q[MTVEC_MODE_W-1:0] == MTVEC_MODE_DIRECT ||
                            stage_wdata_q[MTVEC_MODE_W-1:0] == MTVEC_MODE_VECTORED)
                            stvec_mode_q <= stage_wdata_q[MTVEC_MODE_W-1:0];
                    end
                    ADDR_MEDELEG: if (ENABLE_S) medeleg_q <= stage_wdata_q & MEDELEG_MASK;
                    ADDR_MIDELEG: if (ENABLE_S) mideleg_q <= stage_wdata_q & MIDELEG_MASK;
                    // satp.MODE is WARL, accepts {Bare(0), Sv39(8), Sv48(9)};
                    // the rest (Sv57=10, Sv64=11, reserved values) **leave the
                    // whole word unchanged** (spec: a write of an unsupported
                    // MODE is ignored). satp is not writable with ENABLE_S = 0.
                    // **Translation itself is not in the backend**: the LSU is
                    // outside the library (the backend hands over
                    // vaddr). The backend only holds this
                    // state, currently read out only via csr_rdata, with no
                    // satp output port <needs confirmation>.
                    ADDR_SATP: if (ENABLE_S &&
                                   (stage_wdata_q[BIT_SATP_MODE_HI:BIT_SATP_MODE_LO] == 4'd0  ||
                                    stage_wdata_q[BIT_SATP_MODE_HI:BIT_SATP_MODE_LO] == 4'd8  ||
                                    stage_wdata_q[BIT_SATP_MODE_HI:BIT_SATP_MODE_LO] == 4'd9))
                                   satp_q <= stage_wdata_q;
                    ADDR_SEPC: if (ENABLE_S)
                        sepc_q <= ENABLE_C ? {stage_wdata_q[XLEN-1:1], 1'b0}
                                           : {stage_wdata_q[XLEN-1:2], 2'b00};
                    ADDR_SCAUSE:   if (ENABLE_S) scause_q   <= stage_wdata_q;
                    ADDR_STVAL:    if (ENABLE_S) stval_q    <= stage_wdata_q;
                    ADDR_SSCRATCH: if (ENABLE_S) sscratch_q <= stage_wdata_q;
                    // Writable bits follow IALIGN, same source as ENABLE_C:
                    // with C an instruction can sit on a 2 byte boundary and
                    // mepc has to be able to represent that PC.
                    ADDR_MEPC:     mepc_q <= ENABLE_C ? {stage_wdata_q[XLEN-1:1], 1'b0}
                                                     : {stage_wdata_q[XLEN-1:2], 2'b00};
                    ADDR_MCAUSE:   mcause_q   <= stage_wdata_q;
                    ADDR_MTVAL:    mtval_q    <= stage_wdata_q;
                    ADDR_MSCRATCH: mscratch_q <= stage_wdata_q;
                    // A software write of a counter overrides this cycle's
                    // increment because it is assigned after it.
                    ADDR_MCYCLE:   mcycle_q   <= stage_wdata_q;
                    ADDR_MINSTRET: minstret_q <= stage_wdata_q;
                    default: ;  // hardwired read-only group, mip, unimplemented
                endcase
            end

            // trap_entry / mret_update / sret_update: besides a csrw of
            // mstatus / sstatus, the only paths that touch MIE/MPIE (SIE/SPIE),
            // and **the only privilege transitions**.  None touches FS or frm.
            //
            // These two are written after the csrw branch, so when a csrw
            // mstatus and a trap/mret coexist in the same cycle the latter wins
            // -- the S-mode bits use the same ordering as MIE/MPIE.
            if (trap_entry && !trap_delegated) begin
                // enter M
                mepc_q         <= trap_state_write.epc;
                mcause_q       <= mcause_trap_value;
                mtval_q        <= trap_state_write.tval;
                mstatus_mpie_q <= mstatus_mie_q;
                mstatus_mie_q  <= 1'b0;
                mstatus_mpp_q  <= current_priv_q;   // save the interrupted privilege level
                current_priv_q <= PRIV_M;
            end else if (trap_entry && trap_delegated) begin
                // enter S. **Only the S group of bits moves; MPP/MPIE/MIE are
                // not touched.**
                sepc_q         <= trap_state_write.epc;
                scause_q       <= mcause_trap_value;
                stval_q        <= trap_state_write.tval;
                mstatus_spie_q <= mstatus_sie_q;
                mstatus_sie_q  <= 1'b0;
                // SPP has only one bit: it only distinguishes S from U. There
                // is no "trap from M into S" (M-mode does not delegate), so one
                // bit is enough.
                mstatus_spp_q  <= (current_priv_q == PRIV_S);
                current_priv_q <= PRIV_S;
            end else if (mret_update) begin
                mstatus_mie_q  <= mstatus_mpie_q;
                mstatus_mpie_q <= 1'b1;
                current_priv_q <= mstatus_mpp_q;    // return to the level recorded in MPP
                // spec obligation: set to the lowest supported privilege level.
                // The lowest in this implementation is U.
                mstatus_mpp_q  <= PRIV_U;
            end else if (sret_update) begin
                mstatus_sie_q  <= mstatus_spie_q;
                mstatus_spie_q <= 1'b1;
                current_priv_q <= mstatus_spp_q ? PRIV_S : PRIV_U;
                mstatus_spp_q  <= 1'b0;             // likewise "set to the lowest supported privilege level"
            end
        end
    end

    // ------------------------------------------------------------------
    // mip --the three M bits have no storage: they are a view of the
    // top-level levels mip_meip / mip_mtip / mip_msip.  SSIP is the only
    // stored (software-writable) bit; SEIP / STIP read 0.  The top level owes us levels that are already
    // synchronised, and pending-latched if the source could pulse; an
    // unconnected source is tied to 0.
    // ------------------------------------------------------------------
    logic [XLEN-1:0] mip_view;
    logic [XLEN-1:0] mie_view;
    logic [XLEN-1:0] pending_bits;

    always_comb begin
        mip_view = '0;
        mip_view[BIT_MEI] = mip_meip;
        mip_view[BIT_MTI] = mip_mtip;
        mip_view[BIT_MSI] = mip_msip;
        // SSIP is the only stored bit of mip. SEIP/STIP have no source in this
        // core, constant 0.
        mip_view[BIT_SSI] = mip_ssip_q;

        mie_view = '0;
        mie_view[BIT_MEI] = mie_meie_q;
        mie_view[BIT_MTI] = mie_mtie_q;
        mie_view[BIT_MSI] = mie_msie_q;
        mie_view[BIT_SEI] = mie_seie_q;
        mie_view[BIT_STI] = mie_stie_q;
        mie_view[BIT_SSI] = mie_ssie_q;
    end

    assign pending_bits = mie_view & mip_view;

    // ------------------------------------------------------------------
    // Static Info.  interrupt_pending is finished here so the SCB
    // decision chain never recombines mie / mip / mstatus.MIE itself.
    // interrupt_cause is combinational on purpose: the consumer latches it in
    // the cycle it selects the interrupt, because the levels may move before
    // the trap_entry cycle.  With nothing pending it reads 0, and the consumer
    // only takes it while interrupt_pending is 1.
    // ------------------------------------------------------------------
    // Whether an interrupt can be taken depends on the relation between the
    // **target privilege level** and the current one, not on mstatus.MIE alone.
    //
    // "A privilege level lower than the current one can always be interrupted
    // by a higher-level interrupt" is a spec hard requirement: in U-mode, even
    // with mstatus.MIE = 0, an M-mode interrupt must still be taken. Looking
    // only at `mstatus_mie_q && ...` **is wrong** once U/S exist.
    logic [XLEN-1:0] m_targeted;
    logic [XLEN-1:0] s_targeted;
    logic            m_enabled;
    logic            s_enabled;
    logic [XLEN-1:0] takeable;

    assign m_targeted = pending_bits & ~mideleg_q;
    assign s_targeted = pending_bits &  mideleg_q;
    assign m_enabled  = (current_priv_q == PRIV_M) ? mstatus_mie_q : 1'b1;
    // M-mode does not take interrupts delegated to S.
    assign s_enabled  = (current_priv_q == PRIV_M) ? 1'b0 :
                        (current_priv_q == PRIV_S) ? mstatus_sie_q : 1'b1;
    assign takeable   = (m_enabled ? m_targeted : '0)
                      | (s_enabled ? s_targeted : '0);

    assign interrupt_pending = |takeable;

    always_comb begin
        // spec order: MEI > MSI > MTI > SEI > SSI > STI
        if (takeable[BIT_MEI]) begin
            interrupt_cause = EXCP_CAUSE_W'(BIT_MEI);
        end else if (takeable[BIT_MSI]) begin
            interrupt_cause = EXCP_CAUSE_W'(BIT_MSI);
        end else if (takeable[BIT_MTI]) begin
            interrupt_cause = EXCP_CAUSE_W'(BIT_MTI);
        end else if (takeable[BIT_SEI]) begin
            interrupt_cause = EXCP_CAUSE_W'(BIT_SEI);
        end else if (takeable[BIT_SSI]) begin
            interrupt_cause = EXCP_CAUSE_W'(BIT_SSI);
        end else if (takeable[BIT_STI]) begin
            interrupt_cause = EXCP_CAUSE_W'(BIT_STI);
        end else begin
            interrupt_cause = '0;
        end
    end

    assign mepc = mepc_q;
    assign sepc = sepc_q;
    assign mstatus_tvm = mstatus_tvm_q;
    assign mstatus_tw  = mstatus_tw_q;
    assign mstatus_tsr = mstatus_tsr_q;

    // ------------------------------------------------------------------
    // trap_vector --takes external arguments (trap_cause_in /
    // trap_is_interrupt_in), so it is a read port and not Static Info.  The
    // selected tvec (stvec if delegated, else mtvec) uses its own MODE:
    // Vectored adds 4*cause for interrupts only, exceptions always go Direct.
    // ------------------------------------------------------------------
    logic [XLEN-1:0]          mtvec_view;
    logic [XLEN-1:0]          stvec_view;
    logic [XLEN-1:0]          tvec_sel;
    logic [MTVEC_MODE_W-1:0]  tvec_mode_sel;
    logic [XLEN-1:0]          trap_cause_x;

    assign mtvec_view   = {mtvec_base_q, mtvec_mode_q};
    assign stvec_view   = {stvec_base_q, stvec_mode_q};
    assign trap_cause_x = {{(XLEN-EXCP_CAUSE_W){1'b0}}, trap_cause_in};

    // stvec when delegated, else mtvec. Same source and same cycle as
    // trap_delegated in (3).
    assign tvec_sel      = trap_delegated ? stvec_view    : mtvec_view;
    assign tvec_mode_sel = trap_delegated ? stvec_mode_q  : mtvec_mode_q;

    // **Vectored mode applies to interrupts only**; exceptions always go Direct.
    assign trap_vector = ((tvec_mode_sel == MTVEC_MODE_VECTORED) && trap_is_interrupt_in)
                         ? ({tvec_sel[XLEN-1:MTVEC_MODE_W], {MTVEC_MODE_W{1'b0}}}
                            + (trap_cause_x << 2))
                         : {tvec_sel[XLEN-1:MTVEC_MODE_W], {MTVEC_MODE_W{1'b0}}};

    // ------------------------------------------------------------------
    // mstatus view --SD is a derived read-only projection of FS, never
    // a stored sticky bit, and MPP reads back the stored mstatus_mpp_q.
    // ------------------------------------------------------------------
    logic [XLEN-1:0] mstatus_view;

    always_comb begin
        mstatus_view = '0;
        mstatus_view[BIT_SD]                = (mstatus_fs_q == FS_DIRTY);
        mstatus_view[BIT_FS_HI:BIT_FS_LO]   = mstatus_fs_q;
        // MPP reads the real register mstatus_mpp_q -- if hardwired to PRIV_M,
        // a read-modify-write such as `csrs mstatus, x` would turn an MPP that
        // `csrwi mstatus,0` just set to U back into M.
        // The riscv-tests FP init section is exactly "csrwi mstatus,0" followed
        // by a "csrs mstatus, FS"; the integer tests lack it, so only the FP
        // tests cover this point.
        // UXL: read-only, constant 2 (RV64). With ENABLE_U = 0 U-mode does not
        // exist and it should read 0.
        mstatus_view[BIT_UXL_HI:BIT_UXL_LO] = ENABLE_U ? MISA_MXL_64 : 2'b00;
        // SXL: read-only XLEN report bits. ENABLE_S = 1 ⇒ reads 2.
        mstatus_view[BIT_SXL_HI:BIT_SXL_LO] = ENABLE_S ? MISA_MXL_64 : 2'b00;
        mstatus_view[BIT_MPP_HI:BIT_MPP_LO] = mstatus_mpp_q;
        mstatus_view[BIT_MPIE]              = mstatus_mpie_q;
        mstatus_view[BIT_MIE]               = mstatus_mie_q;
        // The three S-mode bits. Constant 0 with ENABLE_S = 0 (the registers
        // themselves are never written either).
        mstatus_view[BIT_SPP]               = mstatus_spp_q;
        mstatus_view[BIT_SPIE]              = mstatus_spie_q;
        mstatus_view[BIT_SIE]               = mstatus_sie_q;
        mstatus_view[BIT_SUM]               = mstatus_sum_q;
        mstatus_view[BIT_MXR]               = mstatus_mxr_q;
        mstatus_view[BIT_TVM]               = mstatus_tvm_q;
        mstatus_view[BIT_TW]                = mstatus_tw_q;
        mstatus_view[BIT_TSR]               = mstatus_tsr_q;
    end

    // ------------------------------------------------------------------
    // Read-side views. **Write side and read side must be changed
    // as a pair.**
    // sstatus / sie / sip are not independent registers; they are windowed
    // projections of the three above.
    // ------------------------------------------------------------------
    logic [XLEN-1:0] sstatus_view;
    logic [XLEN-1:0] sstatus_mask;
    assign sstatus_mask = (64'(1) << BIT_SD)
                        | (64'(1) << BIT_MXR)
                        | (64'(1) << BIT_SUM)
                        | (64'(3) << BIT_UXL_LO)
                        | (64'(3) << BIT_FS_LO)
                        | (64'(1) << BIT_SPP)
                        | (64'(1) << BIT_SPIE)
                        | (64'(1) << BIT_SIE);
    assign sstatus_view = mstatus_view & sstatus_mask;

    // sie / sip windowed through mideleg: only delegated bits are visible to S.
    logic [XLEN-1:0] sie_view;
    logic [XLEN-1:0] sip_view;
    assign sie_view = mie_view & mideleg_q;
    assign sip_view = mip_view & mideleg_q;

    assign fs_enabled   = (mstatus_fs_q != FS_OFF);
    assign current_priv = current_priv_q;
    // The port is rm_e (a named enum), frm_q is logic[FRM_W-1:0]: an implicit
    // conversion triggers %Error-ENUMVALUE, so an explicit cast is required.
    // The value range of frm_q is guaranteed by the CSR write path.
    assign frm          = rm_e'(frm_q);

    // ------------------------------------------------------------------
    // software read port --csr_rdata = CSR[csr_addr], one port.  The
    // hardwired group answers with its constant, everything else with the
    // register as it stands.  An unimplemented address reads 0, and that read
    // is never taken: csr_fu already judged it illegal on the execute side.
    // ------------------------------------------------------------------
    always_comb begin
        case (csr_addr)
            ADDR_FFLAGS:   csr_rdata = {{(XLEN-FFLAGS_W){1'b0}}, fflags_q};
            ADDR_FRM:      csr_rdata = {{(XLEN-FRM_W){1'b0}}, frm_q};
            // fcsr is not a register, it is the {frm, fflags} view
            ADDR_FCSR:     csr_rdata = {{(XLEN-FRM_W-FFLAGS_W){1'b0}}, frm_q, fflags_q};
            ADDR_MSTATUS:  csr_rdata = mstatus_view;
            ADDR_MISA:     csr_rdata = MISA_VALUE;
            ADDR_MIE:      csr_rdata = mie_view;
            ADDR_MTVEC:    csr_rdata = mtvec_view;
            ADDR_MSCRATCH: csr_rdata = mscratch_q;
            ADDR_MEPC:     csr_rdata = mepc_q;
            ADDR_MCAUSE:   csr_rdata = mcause_q;
            ADDR_MTVAL:    csr_rdata = mtval_q;
            ADDR_MIP:      csr_rdata = mip_view;
            // rdcycle / rdinstret are the read-only aliases of the same two
            // counters, so they share the read arm.
            ADDR_MCYCLE,
            ADDR_CYCLE:    csr_rdata = mcycle_q;
            ADDR_MINSTRET,
            ADDR_INSTRET:  csr_rdata = minstret_q;
            // hardwired read-only group: mhartid = 0 means hart 0
            ADDR_MVENDORID,
            ADDR_MARCHID,
            ADDR_MIMPID,
            ADDR_MHARTID:  csr_rdata = '0;
            // PMP hardwired to zero: listed explicitly rather than falling into
            // default, so the fact "this core has these two CSRs and they are
            // constant 0" can be pointed at in the code. The write side is
            // ignored by apply's default.
            // medeleg/mideleg are real registers, their read side is below, not
            // here -- the same address twice in a case = overlap.
            ADDR_PMPCFG0,
            ADDR_PMPADDR0: csr_rdata = '0;
            // Read side of the S-mode CSRs. sstatus/sie/sip are
            // projections, not independent storage.
            ADDR_SSTATUS:  csr_rdata = sstatus_view;
            ADDR_SIE:      csr_rdata = sie_view;
            ADDR_SIP:      csr_rdata = sip_view;
            ADDR_STVEC:    csr_rdata = stvec_view;
            ADDR_SSCRATCH: csr_rdata = sscratch_q;
            ADDR_SEPC:     csr_rdata = sepc_q;
            ADDR_SCAUSE:   csr_rdata = scause_q;
            ADDR_STVAL:    csr_rdata = stval_q;
            ADDR_SATP:     csr_rdata = satp_q;
            ADDR_MEDELEG:  csr_rdata = medeleg_q;
            ADDR_MIDELEG:  csr_rdata = mideleg_q;
            default:       csr_rdata = '0;
        endcase
    end

endmodule

`endif // SYSTEM_INSTRUCTION_HANDLER_SV
