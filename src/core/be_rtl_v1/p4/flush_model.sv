`ifndef FLUSH_MODEL_SV
`define FLUSH_MODEL_SV

/* verilator lint_off IMPORTSTAR */
import or_be_types_pkg::*;
/* verilator lint_on IMPORTSTAR */

// flush_model -- pure combinational flush boundary, recovery target and
// broadcast.
//
// (1) per-entry state          : none
// (2) state transition         : none
// (3) condition                : none
// (4) data path                : flush_apply fan-out, one cause select, one
//                                recovery-PC select, one trap_state_write pack
// (5) data structure           : none -- no per-entry storage
//
// No clock, no reset, no state: every output is a function of this cycle's
// flush announce and of the two combinational recovery read ports.
//
// The retire decision belongs to the CompletionScoreboard; this module only
// translates an already-decided flush into a recovery target and broadcasts it.
// global_flush_late is generated here and nowhere else -- one net, never
// aliased for a consumer.  Buffer and FE are not on that broadcast list, and
// commit_count does not pass through here.
//
// flush_tag is an address, not a roll-back boundary: it indexes the SCB
// recovery read port and the PC_File read port this module owns, and under
// MISPREDICT / MRET / SRET it names the entry that retired this cycle.  The boundary
// itself is carried by the commit count inside the SCB, so flush_tag is neither
// forwarded on nor turned into a landing value here.
module flush_model (
    // ------------------------------------------------------------------
    // in-event: flush (announce, from CompletionScoreboard)
    // ------------------------------------------------------------------
    input  logic [RECOVERY_KIND_W-1:0] recovery_kind,
    input  logic                       flush_valid,
    input  logic [TAG_W-1:0]           flush_tag,

    // ------------------------------------------------------------------
    // in-event: combinational read data
    // ------------------------------------------------------------------
    // SCB[flush_tag] recovery read port (CompletionScoreboard (4))
    input  logic [XLEN-1:0]            mispredict_target_pc,
    input  logic [EXCP_CAUSE_W-1:0]    exception_cause,
    input  logic [XLEN-1:0]            exception_tval,

    // PC_File[flush_tag] read port, used as the trap epc
    input  logic [XLEN-1:0]            inst_pc,

    // system_instruction_handler architectural state
    input  logic [XLEN-1:0]            mepc,
    // SRET recovery PC. Same nature as mepc; read by name.
    input  logic [XLEN-1:0]            sepc,
    input  logic [EXCP_CAUSE_W-1:0]    interrupt_cause,

    // system_instruction_handler trap_vector(cause, is_interrupt) return value;
    // this module drives the two arguments below, the far side answers
    // combinationally
    input  logic [XLEN-1:0]            trap_vector,

    // ------------------------------------------------------------------
    // out-event: global_flush_late (single generator, library-wide broadcast)
    // ------------------------------------------------------------------
    output logic                       global_flush_late,

    // ------------------------------------------------------------------
    // out-event: redirect (to FE)
    // ------------------------------------------------------------------
    output logic                       redirect_valid,
    output logic [XLEN-1:0]            redirect_pc,
    output logic [RECOVERY_KIND_W-1:0] redirect_kind,
    output logic                       frontend_icache_invalidate,

    // ------------------------------------------------------------------
    // out-event: trap_state_write (to system_instruction_handler)
    // valid / kind / epc / cause / tval
    // ------------------------------------------------------------------
    output trap_state_write_t          trap_state_write,

    // ------------------------------------------------------------------
    // out-event: combinational read arguments of trap_vector(...)
    // ------------------------------------------------------------------
    output logic [EXCP_CAUSE_W-1:0]    cause,
    output logic                       is_interrupt
);

    // ------------------------------------------------------------------
    // flush_apply
    //
    // The SCB has already decided; flush_valid is the whole condition.  Every
    // output below is qualified by it, so flush_apply == 0 leaves the machine
    // untouched: no structure is modified and no redirect is produced.
    // ------------------------------------------------------------------
    logic flush_apply;

    assign flush_apply = flush_valid;

    // recovery_kind carried on the announce, read back as the encoding it is.
    // 6..7 are reserved (5 = SRET) and fall into the default arms below.
    recovery_kind_e kind_sel;

    assign kind_sel = recovery_kind_e'(recovery_kind);

    // ------------------------------------------------------------------
    // cause / is_interrupt
    //
    // These two drive the trap_vector read port; trap_state_write.cause reuses
    // the same cause, so the select happens exactly once.
    //
    // redirect_kind / redirect_pc / frontend_icache_invalidate
    //
    // All six kinds (MISPREDICT / EXCEPTION / MRET / INTERRUPT / FENCE_I /
    // SRET) redirect the front end.  The recovery data is picked by
    // kind alone -- the event bits are never re-examined here.
    //   MISPREDICT : the predicted-wrong branch's resolved target
    //   MRET       : the architectural mepc, never a prediction field
    //   SRET       : the architectural sepc.  This module does NOT
    //                decide delegation -- trap_vector already picks
    //                stvec vs mtvec inside the SIH.  We have no medeleg /
    //                mideleg / current_priv here, and should not.
    //   FENCE_I    : the FENCE.I's own PC + 4.  RVC has no C.FENCE.I, so the
    //                instruction is always 32 bit and no per-tag length bit is
    //                needed anywhere.
    //   otherwise  : trap_vector(cause, is_interrupt); EXCEPTION passes
    //                is_interrupt = 0 and therefore never takes vectored mode,
    //                INTERRUPT passes 1 and may.
    // frontend_icache_invalidate is produced here rather than decoded from
    // redirect_kind by FE: the nature of the redirect is this module's to
    // interpret, FE just acts on the wire.
    //
    // trap_state_write
    //
    // Only EXCEPTION / MRET / SRET / INTERRUPT update architectural privileged
    // state.  MISPREDICT is a prediction failure and FENCE_I an instruction-fetch
    // synchronisation, so both leave the privileged state alone and their
    // packet is never sampled.  MRET / SRET consume kind only -- epc / cause / tval
    // carry values on the bus that the far side does not sample.
    // ------------------------------------------------------------------
    always_comb begin
        // flush_apply == 0 -> all outputs zero
        global_flush_late          = 1'b0;
        redirect_valid             = 1'b0;
        redirect_kind              = '0;
        redirect_pc                = '0;
        frontend_icache_invalidate = 1'b0;
        cause                      = '0;
        is_interrupt               = 1'b0;
        trap_state_write.valid     = 1'b0;
        trap_state_write.kind      = recovery_kind_e'('0);
        trap_state_write.epc       = '0;
        trap_state_write.cause     = '0;
        trap_state_write.tval      = '0;

        if (flush_apply) begin
            global_flush_late = 1'b1;
            redirect_valid    = 1'b1;
            redirect_kind     = recovery_kind;

            case (kind_sel)
                RECOVERY_EXCEPTION: cause = exception_cause;
                RECOVERY_INTERRUPT: cause = interrupt_cause;
                default:            cause = '0;
            endcase
            is_interrupt = (kind_sel == RECOVERY_INTERRUPT);

            case (kind_sel)
                RECOVERY_MISPREDICT: redirect_pc = mispredict_target_pc;
                RECOVERY_MRET:       redirect_pc = mepc;
                RECOVERY_SRET:       redirect_pc = sepc;
                RECOVERY_FENCE_I:    redirect_pc = inst_pc + xlen_t'(4);
                default:             redirect_pc = trap_vector;
            endcase
            frontend_icache_invalidate = (kind_sel == RECOVERY_FENCE_I);

            trap_state_write.valid = (kind_sel == RECOVERY_EXCEPTION) ||
                                     (kind_sel == RECOVERY_MRET)      ||
                                     (kind_sel == RECOVERY_SRET)      ||
                                     (kind_sel == RECOVERY_INTERRUPT);
            trap_state_write.kind  = kind_sel;
            trap_state_write.epc   = inst_pc;
            trap_state_write.cause = cause;
            trap_state_write.tval  = (kind_sel == RECOVERY_EXCEPTION) ? exception_tval : '0;
        end
    end

endmodule

`endif // FLUSH_MODEL_SV
