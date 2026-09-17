`ifndef DISPATCH_LOGIC_SV
`define DISPATCH_LOGIC_SV

/* verilator lint_off IMPORTSTAR */
import or_be_types_pkg::*;
import or_be_config_pkg::*;
import exe_subop_pkg::*;
/* verilator lint_on IMPORTSTAR */

// dispatch_logic -- the backend's single admission point (dispatch_logic微架构文档).
//
// (1) per-entry state          : none
// (2) state transition         : none
// (3) condition                : none
// (4) data path                : #1 exe_subop -> dispatch_route_class, the FP
//                                   dynamic illegal check, the effective_rm
//                                   snapshot and the two-step ISQ group
//                                   choice; #2 the two admission guards;
//                                   #3 select_payload; #4 ib_dequeue /
//                                   isq_wr_en / serial_set
// (5) data structure           : none -- no per-entry storage
//
// No clock and no reset on purpose: ①②③ are all "none", so the module holds no
// state and is not on any flush broadcast list.  global_flush_late only masks
// this cycle's new fire; nothing about the flush is remembered here.
//
// Classification is never re-derived.  Every subop set comes from the frozen
// exe_subop_pkg, and the three bits that leave for CompletionScoreboard are
// pure functions of exe_subop taken straight from it:
//
//     is_fence_i[s] = (exe_subop[s] == SUBOP_FENCEI)
//     may_flush[s]  = may_flush_before_resolution(exe_subop[s], illegal_effective[s])
//     is_atomic[s]  = is_g3_atomic_subop(exe_subop[s])
//
// is_atomic matters beyond routing: the SCB never sees exe_subop, so this bit
// is its only source for the "irrevocable head0" test in its decision chain.
// Dropping it would leave an in-flight LR / SC / AMO looking revocable and
// would postpone interrupts for no reason.
//
// Reading architectural FP state (fs_enabled / frm) in the dispatch cycle is
// safe, and ④#1 is the argument: only CSR instructions (is_serial) and
// trap / mret change FS or frm, and both require an empty retire window, while
// the commit-cycle fflags accrue can only drive FS towards Dirty.  So the value
// an FP instruction reads at dispatch is the value it will retire with, and
// effective_rm can be frozen here instead of letting the FPU read a live frm.
//
// The ENABLE_A / ENABLE_C / ENABLE_FD / ENABLE_U knobs are imported for the
// record only: ④#1 puts extension gating in decode (a disabled subop arrives
// with full_decode.illegal = 1 and takes the G0 ILLEGAL path like any other
// illegal instruction), so this module must not gate a second time.
//
// Port naming follows doc ⑥ verbatim except for the one place ⑥ leaves two
// opposite-direction ports sharing a name; see dispatch_logic.portmap.
module dispatch_logic (
    // ------------------------------------------------------------------
    // in-event: broadcast -- dependency_check's admission bits, all of them
    // consumed by the ④#2 guards
    // ------------------------------------------------------------------
    input  logic                    slot0_present,
    input  logic                    slot1_present,
    input  logic                    serial0,
    input  logic                    serial_inst,
    input  logic                    fp0,
    input  logic                    fp1,
    input  logic                    slot_missed_wakeup    [ISSUE_WIDTH],

    // ------------------------------------------------------------------
    // in-event: broadcast -- IB's decode results.  ⑥ writes the two decode
    // control bits as `full_decode.illegal[0/1]`(1x2) and
    // `full_decode.rm[0/1]`(3x2); they arrive inside the one frozen
    // full_decode_t (集成层 §2.2), so the port is that struct and the doc
    // names are read as full_decode[s].illegal / full_decode[s].rm.
    // ------------------------------------------------------------------
    input  logic [EXE_SUBOP_W-1:0]  exe_subop             [ISSUE_WIDTH],
    input  full_decode_t            full_decode           [ISSUE_WIDTH],
    input  logic                    is_fp_instruction     [ISSUE_WIDTH],

    // ------------------------------------------------------------------
    // in-event: broadcast -- architectural FP state from
    // system_instruction_handler, sampled in the dispatch cycle and not kept.
    // fs_enabled = (mstatus.FS != Off).  frm is the same 3-bit encoding as
    // full_decode.rm, so it takes the same named type rather than a literal 3.
    // ------------------------------------------------------------------
    input  logic                    fs_enabled,
    input  rm_e                     frm,

    // ------------------------------------------------------------------
    // in-event: broadcast -- CompletionScoreboard, cycle-start values
    // ------------------------------------------------------------------
    input  logic                    can_alloc_1,
    input  logic                    can_alloc_2,
    input  logic                    buffer_empty,

    // ------------------------------------------------------------------
    // in-event: broadcast -- one bit per ISQ_Group, this cycle's issue already
    // folded in
    // ------------------------------------------------------------------
    input  logic                    isq_free_for_dispatch [NUM_LANES],

    // ------------------------------------------------------------------
    // in-event: broadcast -- SerialInstructionTracker's state
    // ------------------------------------------------------------------
    input  logic                    serial_inflight_valid,

    // ------------------------------------------------------------------
    // in-event: broadcast -- `self_tag[0]`(4) from dependency_check.  Slot 0
    // only: serial_set is an accept[0] term, so slot 1's tag has no consumer
    // here and there is no second wire to ignore.
    // ------------------------------------------------------------------
    input  logic [TAG_W-1:0]        self_tag,

    // ------------------------------------------------------------------
    // in-event: flush (announce, single-wire pulse).  Masks this cycle's
    // accepts and nothing else.
    // ------------------------------------------------------------------
    input  logic                    global_flush_late,

    // ------------------------------------------------------------------
    // out-event: accept / ib_dequeue.  accept[1] implies accept[0], so the
    // "10" combination is structurally impossible.
    // ------------------------------------------------------------------
    output logic                    accept                [ISSUE_WIDTH],
    output logic                    ib_dequeue            [ISSUE_WIDTH],

    // ------------------------------------------------------------------
    // out-event: isq_wr_en, one per ISQ_Group
    // ------------------------------------------------------------------
    output logic                    isq_wr_en             [NUM_LANES],

    // ------------------------------------------------------------------
    // out: combinational reads -- 集成层 §2.1 ISQ_Payload assembly.
    // slot_FU_Group is the FU index *within* the chosen group, never a group
    // number; effective_rm overwrites the payload's rm field and only G2 reads
    // the result.
    // ------------------------------------------------------------------
    output logic [FU_GROUP_W-1:0]   slot_FU_Group         [ISSUE_WIDTH],
    output rm_e                     effective_rm          [ISSUE_WIDTH],

    // ------------------------------------------------------------------
    // out: combinational reads -- CompletionScoreboard's alloc batch, written
    // with accept[s] into entry[alloc_self_tag[s]].  Not gated by accept here:
    // the SCB writes them only in the alloc cycle.
    // ------------------------------------------------------------------
    output logic                    is_fence_i            [ISSUE_WIDTH],
    output logic                    may_flush             [ISSUE_WIDTH],
    output logic                    is_atomic             [ISSUE_WIDTH],

    // ------------------------------------------------------------------
    // out-event: serial_set (trigger + the forwarded slot-0 tag).  ⑥ calls the
    // payload `self_tag[0]`(4) on both edges; the outgoing copy is renamed
    // serial_set_tag because an input and an output cannot share an
    // identifier.  It is forwarded unconditionally -- SerialInstructionTracker
    // captures it under serial_set, so gating would only add a mux.
    // ------------------------------------------------------------------
    output logic                    serial_set,
    output logic [TAG_W-1:0]        serial_set_tag,

    // ------------------------------------------------------------------
    // out: combinational reads -- p1_ISQ_input_mux x4; copy g takes its own
    // two bits.  This is a valid-candidate select, not just a route: 00 means
    // no accepted candidate for that group and the mux drives all zero.
    // ------------------------------------------------------------------
    output logic                    select_payload        [NUM_LANES][ISSUE_WIDTH]
);

    // ------------------------------------------------------------------
    // Local constants.
    //
    // The four ISQ groups.  or_be_types_pkg carries no separate group count
    // because there is none to carry: group g completes on lane g (集成层
    // §1.2), and Buffer / CompletionScoreboard already index the four lanes
    // with g, so NUM_LANES *is* this multiplicity.
    //
    // ISQ_GROUP_W is the width of a group id (G0..G3).  It is not FU_GROUP_W:
    // that one is the FU index inside a group and leaves the module as
    // slot_FU_Group.  They happen to be equal here and mean different things.
    // ------------------------------------------------------------------
    localparam int ISQ_GROUP_W = $clog2(NUM_LANES);

    localparam logic [ISQ_GROUP_W-1:0] GRP_G0 = ISQ_GROUP_W'(0);
    localparam logic [ISQ_GROUP_W-1:0] GRP_G1 = ISQ_GROUP_W'(1);
    localparam logic [ISQ_GROUP_W-1:0] GRP_G2 = ISQ_GROUP_W'(2);
    localparam logic [ISQ_GROUP_W-1:0] GRP_G3 = ISQ_GROUP_W'(3);

    // ------------------------------------------------------------------
    // dispatch_route_class -- ④#1's first step.  Internal to this module: it
    // is not an ISQ payload field and it has no cross-module consumer.
    //
    // ILLEGAL is not a separate member.  ④ puts illegal_effective and the
    // FETCH_FAULT subop in the same bucket as BRU -- fixed G0, requester 0,
    // FU index 0 -- and says so explicitly ("对本模块完全同形，不另立分类").
    //
    // ROUTE_UNSUPPORTED is the decode-went-wrong catch: SUBOP_INVALID or an
    // encoding no set covers, and only when illegal_effective is 0.  It blocks
    // accept, which stalls the slot forever, so it must never be reachable by
    // a real instruction -- an unimplemented instruction has to arrive with
    // illegal = 1 and take the completable ILLEGAL path instead.
    // ------------------------------------------------------------------
    typedef enum logic [3:0] {
        ROUTE_ALU         = 4'd0,
        ROUTE_BRU         = 4'd1,   // also ILLEGAL and FETCH_FAULT
        ROUTE_CSR         = 4'd2,
        ROUTE_DIV         = 4'd3,
        ROUTE_MUL         = 4'd4,
        ROUTE_FPU         = 4'd5,
        ROUTE_LSU         = 4'd6,
        ROUTE_ATOMIC      = 4'd7,
        ROUTE_FENCE       = 4'd8,
        ROUTE_SYS         = 4'd9,
        ROUTE_UNSUPPORTED = 4'd10
    } dispatch_route_class_e;

    dispatch_route_class_e     dispatch_route_class [ISSUE_WIDTH];
    logic                      alu_g1_capable       [ISSUE_WIDTH];
    logic                      subop_supported_now  [ISSUE_WIDTH];
    logic [ISQ_GROUP_W-1:0]    fixed_group          [ISSUE_WIDTH];

    logic                      frm_illegal;
    logic                      rm_illegal           [ISSUE_WIDTH];
    logic                      fp_illegal           [ISSUE_WIDTH];
    logic                      illegal_effective    [ISSUE_WIDTH];

    logic [ISQ_GROUP_W-1:0]    slot_ISQGroup        [ISSUE_WIDTH];
    logic                      slot0_takes_G0;
    logic                      groups_distinct;

    logic                      serial0_ok;
    logic                      slot0_guard_ok;
    logic                      slot0_fire_candidate;
    logic                      slot1_guard_ok;

    // ------------------------------------------------------------------
    // uses_rm -- ④#1.  Static classification by exe_subop, never a blind look
    // at the rm field of every FP instruction.
    //
    // In:  the arithmetic class (FADD / FSUB / FMUL / FDIV / FSQRT and the four
    //      FMA forms) and the whole conversion class (FCVT.*).
    // Out: FSGNJ* / FMIN / FMAX / FEQ / FLT / FLE / FCLASS / FMV.*, whose three
    //      encoding bits mean something other than a rounding mode -- checking
    //      them would turn legal instructions illegal -- and FP load / store,
    //      whose funct3 is an access width.
    //
    // exe_subop_pkg has no uses_rm helper, and ④#1 assigns this split to this
    // module, so the set is spelled out here rather than re-derived from the
    // encoding fields.
    // ------------------------------------------------------------------
    function automatic logic uses_rm(input logic [EXE_SUBOP_W-1:0] sub);
        return sub inside {
            SUBOP_FADD_S, SUBOP_FSUB_S, SUBOP_FMUL_S, SUBOP_FDIV_S, SUBOP_FSQRT_S,
            SUBOP_FADD_D, SUBOP_FSUB_D, SUBOP_FMUL_D, SUBOP_FDIV_D, SUBOP_FSQRT_D,
            SUBOP_FMADD_S, SUBOP_FMSUB_S, SUBOP_FNMSUB_S, SUBOP_FNMADD_S,
            SUBOP_FMADD_D, SUBOP_FMSUB_D, SUBOP_FNMSUB_D, SUBOP_FNMADD_D,
            SUBOP_FCVT_W_S, SUBOP_FCVT_WU_S, SUBOP_FCVT_L_S, SUBOP_FCVT_LU_S,
            SUBOP_FCVT_W_D, SUBOP_FCVT_WU_D, SUBOP_FCVT_L_D, SUBOP_FCVT_LU_D,
            SUBOP_FCVT_S_W, SUBOP_FCVT_S_WU, SUBOP_FCVT_S_L, SUBOP_FCVT_S_LU,
            SUBOP_FCVT_D_W, SUBOP_FCVT_D_WU, SUBOP_FCVT_D_L, SUBOP_FCVT_D_LU,
            SUBOP_FCVT_S_D, SUBOP_FCVT_D_S
        };
    endfunction

    // ------------------------------------------------------------------
    // (4)#1 first step -- the FP dynamic illegal check, illegal_effective, the
    // effective_rm snapshot, and the classification table.
    //
    //     frm_illegal = (frm > 3'b100)
    //     rm_illegal  = uses_rm & (rm reserved | (rm == DYN & frm_illegal))
    //     fp_illegal  = is_fp_instruction & (!fs_enabled | rm_illegal)
    //     illegal_effective = full_decode.illegal | fp_illegal
    //
    // rm == DYN with frm == 3'b111 is illegal, not a second indirection: DYN
    // means "take frm", and frm holding DYN resolves to no rounding mode.
    // is_fp_instruction is the input and covers FLW / FLD / FSW / FSD as well;
    // rd_is_fp would miss the FP stores, and FS == Off makes those illegal too.
    // ------------------------------------------------------------------
    always_comb begin
        frm_illegal = (frm == RM_RSV5) || (frm == RM_RSV6) || (frm == RM_DYN);

        for (int unsigned s = 0; s < ISSUE_WIDTH; s++) begin
            rm_illegal[s] = uses_rm(exe_subop[s])
                         && (rm_is_reserved(full_decode[s].rm)
                             || ((full_decode[s].rm == RM_DYN) && frm_illegal));

            fp_illegal[s] = is_fp_instruction[s] && (!fs_enabled || rm_illegal[s]);

            illegal_effective[s] = full_decode[s].illegal || fp_illegal[s];

            // Frozen in the dispatch cycle; a G2 entry may sit for several
            // cycles and must not re-read a live frm.
            effective_rm[s] = (full_decode[s].rm == RM_DYN) ? frm : full_decode[s].rm;

            // illegal_effective wins over everything: it is a completable
            // instruction that takes G0's ILLEGAL path with tval = inst_bits.
            // Only when it is 0 can an uncovered encoding fall through to
            // ROUTE_UNSUPPORTED.
            if (illegal_effective[s]) begin
                dispatch_route_class[s] = ROUTE_BRU;
            end else if (exe_subop[s] == SUBOP_INVALID) begin
                dispatch_route_class[s] = ROUTE_UNSUPPORTED;
            end else if (is_g3_atomic_subop(exe_subop[s])) begin
                dispatch_route_class[s] = ROUTE_ATOMIC;
            end else if (is_g3_fence_subop(exe_subop[s])) begin
                dispatch_route_class[s] = ROUTE_FENCE;
            end else if (is_g3_lsu_subop(exe_subop[s])) begin
                dispatch_route_class[s] = ROUTE_LSU;
            end else if (is_g0_sys_subop(exe_subop[s])) begin
                dispatch_route_class[s] = ROUTE_SYS;
            end else if (is_g0_csr_subop(exe_subop[s])) begin
                dispatch_route_class[s] = ROUTE_CSR;
            end else if (is_g0_div_subop(exe_subop[s])) begin
                dispatch_route_class[s] = ROUTE_DIV;
            end else if (is_g1_mul_subop(exe_subop[s])) begin
                dispatch_route_class[s] = ROUTE_MUL;
            end else if (is_g2_fpu_subop(exe_subop[s])) begin
                dispatch_route_class[s] = ROUTE_FPU;
            end else if (is_g0_bru_subop(exe_subop[s])) begin
                dispatch_route_class[s] = ROUTE_BRU;
            end else if (is_g0_alu0_subop(exe_subop[s])) begin
                // is_g1_alu1_subop is is_g0_alu0_subop minus SUBOP_AUIPC, so
                // the G0 set alone identifies the class.
                dispatch_route_class[s] = ROUTE_ALU;
            end else begin
                dispatch_route_class[s] = ROUTE_UNSUPPORTED;
            end

            subop_supported_now[s] = (dispatch_route_class[s] != ROUTE_UNSUPPORTED);

            // Whether an ALU op may be moved to G1 is a property of the subop,
            // not of the class: AUIPC needs pc, which ISQ_Group1 does not keep,
            // so the package leaves it out of the G1 set.  LUI is in both.
            alu_g1_capable[s] = is_g1_alu1_subop(exe_subop[s]);

            // ④#1's fixed-group column.  ATOMIC and FENCE join LSU in G3
            // because only the LSU can execute a memory-ordering operation;
            // SYS joins BRU / ILLEGAL in G0 because it shares G0's requester 0
            // and its exception completion path.  Neither may enter the ALU's
            // dynamic split: G1 cannot produce an exception at all.
            unique case (dispatch_route_class[s])
                ROUTE_MUL:                          fixed_group[s] = GRP_G1;
                ROUTE_FPU:                          fixed_group[s] = GRP_G2;
                ROUTE_LSU, ROUTE_ATOMIC, ROUTE_FENCE: fixed_group[s] = GRP_G3;
                // ALU's G0-only half (AUIPC and friends), BRU / ILLEGAL, CSR,
                // DIV, SYS, and the never-accepted UNSUPPORTED slot.
                default:                            fixed_group[s] = GRP_G0;
            endcase

            // ④#1's FU index table -- inside the group, never a group number.
            //   ALU / BRU / FPU / LSU / ILLEGAL / ATOMIC / FENCE / SYS -> 0
            //   CSR -> 1        MUL -> 1        DIV -> 2
            unique case (dispatch_route_class[s])
                ROUTE_CSR: slot_FU_Group[s] = FU_GROUP_W'(1);
                ROUTE_MUL: slot_FU_Group[s] = FU_GROUP_W'(1);
                ROUTE_DIV: slot_FU_Group[s] = FU_GROUP_W'(2);
                default:   slot_FU_Group[s] = FU_GROUP_W'(0);
            endcase
        end
    end

    // ------------------------------------------------------------------
    // (4)#1 second step -- group choice, interleaved with (4)#2's guards
    // because ④ orders them that way: slot1's group choice needs to know
    // whether slot0 is really taking G0 this cycle, and that is slot0's fire
    // candidate, not merely slot0's group.
    //
    // Group choice always yields a definite number.  A splittable ALU op with
    // both G0 and G1 full still reports G1; the collision is stopped by
    // groups_distinct, and a full group is stopped by the guard's own
    // isq_free_for_dispatch term.  Two G0-only slots make groups_distinct = 0,
    // so slot1 simply waits for the next cycle.
    //
    // (4)#2 admission.  accept[1] carries accept[0] as a factor, so slot1 can
    // never fire alone.  can_alloc_1 / can_alloc_2 / buffer_empty are the SCB's
    // cycle-start values; isq_free_for_dispatch already folds in this cycle's
    // issue.
    //
    // The serial rules are two separate things.  serial0_ok makes a serial
    // slot-0 instruction wait until the retire window is empty -- which is what
    // makes an ATOMIC or FENCE non-speculative when it finally executes, with
    // every older store already drained.  !serial_inflight_valid then blocks
    // every younger dispatch while it is in flight, and !serial_inst keeps the
    // second slot out of a cycle that dispatches a serial instruction.
    // ------------------------------------------------------------------
    always_comb begin
        slot_ISQGroup[0] = ((dispatch_route_class[0] == ROUTE_ALU) && alu_g1_capable[0])
                         ? (isq_free_for_dispatch[GRP_G0] ? GRP_G0 : GRP_G1)
                         : fixed_group[0];

        serial0_ok = !serial0 || buffer_empty;

        slot0_guard_ok = subop_supported_now[0]
                      && can_alloc_1
                      && isq_free_for_dispatch[slot_ISQGroup[0]]
                      && !serial_inflight_valid
                      && serial0_ok
                      && !slot_missed_wakeup[0]
                      && !global_flush_late;

        slot0_fire_candidate = slot0_present && slot0_guard_ok;
        accept[0]            = slot0_fire_candidate;

        // G0 is only taken if slot0 actually fires; a blocked slot0 does not
        // reserve the group.
        slot0_takes_G0 = slot0_fire_candidate && (slot_ISQGroup[0] == GRP_G0);

        slot_ISQGroup[1] = ((dispatch_route_class[1] == ROUTE_ALU) && alu_g1_capable[1])
                         ? ((isq_free_for_dispatch[GRP_G0] && !slot0_takes_G0)
                                ? GRP_G0 : GRP_G1)
                         : fixed_group[1];

        groups_distinct = (slot_ISQGroup[1] != slot_ISQGroup[0]);

        slot1_guard_ok = subop_supported_now[1]
                      && can_alloc_2
                      && isq_free_for_dispatch[slot_ISQGroup[1]]
                      && groups_distinct
                      && !(fp0 && fp1)          // dual-FP dispatch is blocked
                      && !serial_inst
                      && !slot_missed_wakeup[1]
                      && !global_flush_late;

        accept[1] = accept[0] && slot1_present && slot1_guard_ok;
    end

    // ------------------------------------------------------------------
    // (4)#3 select_payload[g][s] = accept[s] & (slot_ISQGroup[s] == g).
    //
    // accept[1] already contains groups_distinct, so at most one slot bit is
    // set per group and the downstream mux never has to arbitrate.
    // ------------------------------------------------------------------
    always_comb begin
        for (int unsigned g = 0; g < NUM_LANES; g++) begin
            for (int unsigned s = 0; s < ISSUE_WIDTH; s++) begin
                select_payload[g][s] = accept[s]
                                    && (slot_ISQGroup[s] == ISQ_GROUP_W'(g));
            end
        end
    end

    // ------------------------------------------------------------------
    // (4)#4 ib_dequeue / isq_wr_en / serial_set
    // ------------------------------------------------------------------
    always_comb begin
        for (int unsigned s = 0; s < ISSUE_WIDTH; s++) begin
            ib_dequeue[s] = accept[s];
        end

        for (int unsigned g = 0; g < NUM_LANES; g++) begin
            isq_wr_en[g] = select_payload[g][0] || select_payload[g][1];
        end

        serial_set     = accept[0] && serial0;
        serial_set_tag = self_tag;
    end

    // ------------------------------------------------------------------
    // (6) out: the CompletionScoreboard alloc trio.  All three are pure
    // functions of exe_subop, so they are exported from here instead of
    // travelling a second time through the IB payload (the same precedent
    // §1.8 sets for FU_Group).
    //
    // is_fence_i is what lets the SCB recognise "head0 is a FENCE.I, flush
    // after commit" in step 5 of its decision chain: none of its four
    // flush-producing predicates -- exception, mispredict, is_mret, external
    // interrupt -- matches FENCE.I, so without this bit FENCE.I would fall
    // through to "commit normally" and the re-fetch would never happen.
    // ------------------------------------------------------------------
    always_comb begin
        for (int unsigned s = 0; s < ISSUE_WIDTH; s++) begin
            is_fence_i[s] = (exe_subop[s] == SUBOP_FENCEI);
            may_flush[s]  = may_flush_before_resolution(exe_subop[s],
                                                        illegal_effective[s]);
            is_atomic[s]  = is_g3_atomic_subop(exe_subop[s]);
        end
    end

endmodule

`endif // DISPATCH_LOGIC_SV
