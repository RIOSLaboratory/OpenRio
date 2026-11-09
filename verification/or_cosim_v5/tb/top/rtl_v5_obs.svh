// ════════════════════════════════════════════════════════════════════════
// rtl_v5_obs.svh -- observation library for the v5 BE RTL
//
// Expanded via `include inside be_tb_top's `ifdef ORBE_DUT_RTL_V1 scope, in the
// same slot where rtl_v1_obs.svh sits for the v1 DUT. `include is textual
// expansion and creates no new module hierarchy.
//
// STATUS: **stage A placeholder** (2026-11-03). Intentionally empty for now.
//
// Why it is empty and not a port of rtl_v1_obs.svh:
//
//   rtl_v1_obs.svh (741 lines) reaches into ~90 non-port internals of v1's
//   backend_top -- isq0_self_tag, head_IB_Payload, dec_info, arbG0_Result_valid,
//   csrfu_csr_addr, sih_csr_rdata, scb_flush_tag, u_INT_ARF.entry_arf, ... --
//   and drives ob_cosim_vif from them. None of those names exist in v5:
//
//     v5 backend_top is a different decomposition (IB_ctrl / p2_p3_reg /
//     FU_input_mux inside ISQ_Group{g} / Buffer / PC_File), the ISQ payloads
//     are per-FU minimal sets rather than one shared isq_payload_t, INT_ARF /
//     FP_ARF store into an array named `mem` instead of `entry_arf`, and
//     csr_unit dropped the arbitration-loser hold (`winner_grant`,
//     `result_data_q`, `req_result_data`) that CNT_SYNC used to force.
//
//   So this is a re-derivation, not a rename pass. Each reference has to be
//   re-pointed at a v5 equivalent, and where v5 genuinely has no equivalent the
//   check has to be dropped with a written reason.
//
// Consequences of running stage A:
//
//   - The commit-level ISA model comparison still works: it is driven from
//     backend_top's PORTS (commit_valid / commit_tag / commit_data /
//     trace_pc / redirect_*), which be_tb_top wires to the cosim agent
//     independently of this file.
//   - ob_cosim_vif's observation fields are NOT driven, so the supplementary
//     per-FU / per-ISQ / ARF-snapshot checks are inactive. Expect the
//     [BE][COSIM_OB] and [*_EQUIV] lines to be absent or all-zero, and do not
//     read their absence as a pass.
//
// Stage B (next) will fill this in, in this order of value:
//   1. commit_* / recovery_* / flush_*   -- backend_top ports + scoreboard internals
//   2. int_arf / fp_arf                  -- u_INT_ARF.mem / u_FP_ARF.mem
//   3. decode_issue_*                    -- IB head payload + decode outputs
//   4. isq{g}_*_issue_*                  -- ISQ_Group{g} issue handshake
//   5. csr_in_* / csr_out_*              -- csr_unit completion interface
// ════════════════════════════════════════════════════════════════════════

// ─────────────────────────────────────────────────────────────────────────
// Minimum surface be_tb_top's own ORBE_CACHE_RTL section needs.
//
// That section identifies SFENCE.VMA at allocation (records is_sfence by tag)
// and pulses sfence to or_cache_top when the same tag commits. It only reads
// inst_bits / is_compressed out of the allocation payload, so only those two
// fields are modelled here instead of v1's 29-field rtl_v1_obs_alloc_pld_t.
//
// Source of each field:
//   obs_alloc_valid  <- backend_top.alloc_valid (FE accepted this slot this cycle)
//   obs_alloc_tag    <- backend_top.alloc_tag
//   obs_alloc_pld    <- the FE->BE instruction payload that was accepted
//   obs_commit_*     <- backend_top.commit_valid / commit_tag
// All four are real, so this part of stage A is complete rather than stubbed.
// ─────────────────────────────────────────────────────────────────────────
typedef struct packed {
  logic [31:0] inst_bits;
  logic        is_compressed;
} rtl_v5_obs_alloc_pld_t;

logic [or_be_types_pkg::ISSUE_WIDTH-1:0]            obs_alloc_valid;
rtl_v5_obs_alloc_pld_t [or_be_types_pkg::ISSUE_WIDTH-1:0] obs_alloc_pld;
logic [or_be_types_pkg::ISSUE_WIDTH-1:0][or_be_types_pkg::TAG_W-1:0] obs_alloc_tag;

logic [or_be_types_pkg::ISSUE_WIDTH-1:0]            obs_commit_valid;
logic [or_be_types_pkg::ISSUE_WIDTH-1:0][or_be_types_pkg::TAG_W-1:0] obs_commit_tag;

always_comb begin
  for (int slot = 0; slot < or_be_types_pkg::ISSUE_WIDTH; slot++) begin
    obs_alloc_valid[slot] = rtl_alloc_valid[slot];
    obs_alloc_tag[slot]   = rtl_alloc_tag[slot];
    obs_alloc_pld[slot].inst_bits     = rtl_fe_instr_pld[slot].inst_bits;
    obs_alloc_pld[slot].is_compressed = rtl_fe_instr_pld[slot].is_compressed;

    obs_commit_valid[slot] = rtl_commit_valid[slot];
    obs_commit_tag[slot]   = rtl_commit_tag[slot];
  end
end

// ─────────────────────────────────────────────────────────────────────────
// TEMP bring-up probe (2026-11-03): why does IB_ctrl never accept?
//
// Enabled by +V5_DBG=1. Pure observation, no forcing, no RTL edit. Remove once
// the v5 BE commits its first instruction.
//
// accept[0] = inst_valid[0] & supported & can_alloc_1 & isq_free[grp]
//           & ~serial_inflight & (~serial0 | buffer_empty)
//           & ~missed_wakeup[0] & ~global_flush_late
// so the print lists every term of that expression.
// ─────────────────────────────────────────────────────────────────────────
int v5dbg_en  = 0;
int v5dbg_iv  = 0;   // "head valid seen" budget
int v5dbg_blk = 0;   // "valid but blocked" budget
initial void'($value$plusargs("V5_DBG=%d", v5dbg_en));

always_ff @(posedge clk) begin
  if (v5dbg_en != 0 && rstn) begin
    if (u_backend.ib_inst_valid != '0 && v5dbg_iv < 10) begin
      v5dbg_iv++;
      $display("[V5DBG][IB] t=%0t inst_valid=%b head_pc0=0x%08h head_inst0=0x%08h enq_pc0=0x%08h enq_vld=%b",
               $time, u_backend.ib_inst_valid,
               u_backend.head_ib_payload[0].pc, u_backend.head_ib_payload[0].inst_bits,
               u_backend.enq_ib_payload[0].pc, rtl_fe_valid);
    end
    if (u_backend.ib_inst_valid[0] && !u_backend.ctrl_accept[0] && v5dbg_blk < 24) begin
      v5dbg_blk++;
      $display("[V5DBG][BLK] t=%0t route=%0d fixed_grp=%0d alu_g1=%b grp=%0d | can_alloc_1=%b can_alloc_2=%b isq_free=%b buf_empty=%b serial0=%b ser_inflight=%b missed_wk=%b flush=%b",
               $time,
               u_backend.dl_route_class[0], u_backend.dl_fixed_group[0],
               u_backend.dl_alu_g1_capable[0], 0,
               u_backend.scb_can_alloc_1, u_backend.scb_can_alloc_2,
               u_backend.isq_free_for_dispatch, u_backend.scb_buffer_empty,
               u_backend.dc_serial0, u_backend.sit_serial_inflight_valid,
               u_backend.dc_slot_missed_wakeup_v[0], u_backend.fm_global_flush_late);
    end
  end
end

// Heartbeat on the completion side: does anything ever come back from the
// ISQ / FU / lane path, and does the scoreboard ever commit?
int v5dbg_cyc = 0;
always_ff @(posedge clk) begin
  if (v5dbg_en != 0 && rstn) begin
    v5dbg_cyc <= v5dbg_cyc + 1;
    if (v5dbg_cyc < 600 && (v5dbg_cyc % 20) == 0) begin
      $display("[V5DBG][HB] cyc=%0d rob_valid=0x%04h rob_done=0x%04h lane_res=%b%b%b%b commit=%b%b ser=%b isq_iss=%b%b%b%b | fe_rdy=%b fe_vld=%b ib_iv=%b acc=%b buf_e=%b can1=%b occ=%0d tail=%0d head=%0d",
               v5dbg_cyc,
               u_backend.scb_valid_bits, u_backend.scb_exec_done_bits,
               u_backend.lane_result_valid[3], u_backend.lane_result_valid[2],
               u_backend.lane_result_valid[1], u_backend.lane_result_valid[0],
               u_backend.scb_commit_valid[1], u_backend.scb_commit_valid[0],
               u_backend.sit_serial_inflight_valid,
               u_backend.u_ISQ_Group0.issue_valid, u_backend.u_ISQ_Group1.issue_valid,
               u_backend.u_ISQ_Group2.issue_valid, u_backend.u_ISQ_Group3.issue_valid,
               u_backend.fe_ready, rtl_fe_valid, u_backend.ib_inst_valid,
               u_backend.ctrl_accept, u_backend.scb_buffer_empty,
               u_backend.scb_can_alloc_1,
               u_backend.u_scoreboard.tail_q - u_backend.u_scoreboard.head_q,
               u_backend.u_scoreboard.tail_q, u_backend.u_scoreboard.head_q);
    end

    // FE side: is the frontend itself stalled, or is a BE-issued control pulse
    // holding it down? gflush / fe_inv / rdr_* all come out of backend_top's
    // flush_model and are consumed by or_fe_top.
    // u_fe only exists for the RTL-FE kinds (ORBE_FE_RTL); the agent kinds have
    // no or_fe_top instance, so this line is compiled out there.
`ifdef ORBE_FE_RTL
    if (v5dbg_cyc < 600 && (v5dbg_cyc % 20) == 0) begin
      $display("[V5DBG][FE] cyc=%0d gflush=%b fe_inv=%b rdr_v=%b rdr_pc=0x%08h | enq_vld=%b enq_rdy=%b",
               v5dbg_cyc, rtl_global_flush, rtl_frontend_icache_invalidate,
               rtl_redirect_valid, rtl_redirect_pc[31:0],
               u_fe.ib_enq_vld, u_fe.ib_enq_rdy);
    end
`else
    if (v5dbg_cyc < 600 && (v5dbg_cyc % 20) == 0) begin
      $display("[V5DBG][FE] cyc=%0d gflush=%b fe_inv=%b rdr_v=%b rdr_pc=0x%08h | (fe_agent)",
               v5dbg_cyc, rtl_global_flush, rtl_frontend_icache_invalidate,
               rtl_redirect_valid, rtl_redirect_pc[31:0]);
    end
`endif
  end
end

// ─────────────────────────────────────────────────────────────────────────
// TEMP: watch the ALU's view of the branch at 0x800003a0 (bne, imm = -0x18).
// v1 redirects on it every loop iteration; v5 never does. This prints the whole
// decision: decoded subop, whether it is recognised as a BRU op, the computed
// taken/target and the prediction that was attached to the payload.
// DELETE THIS BLOCK when the bring-up is done.
// ─────────────────────────────────────────────────────────────────────────
always_ff @(posedge clk) begin
  if (v5dbg_en != 0) begin
    if (u_backend.u_alu0_bru.completion_write_valid &&
        u_backend.u_alu0_bru.pc[31:0] == 32'h8000_03a0)
      $display("[ALUDBG] G0 t=%0t subop=%06h is_bru=%b taken=%b pred_t=%b tgt=%08h pred_tgt=%08h misp=%b tag=%0d pc=%08h imm=%08h rs1=%016h rs2=%016h",
               $time, u_backend.u_alu0_bru.exe_subop, u_backend.u_alu0_bru.is_bru_op,
               u_backend.u_alu0_bru.branch_taken, u_backend.u_alu0_bru.pred_taken,
               u_backend.u_alu0_bru.branch_target[31:0], u_backend.u_alu0_bru.pred_target_pc[31:0],
               u_backend.u_alu0_bru.mispredict_flag, u_backend.u_alu0_bru.self_tag,
               u_backend.u_alu0_bru.pc[31:0], u_backend.u_alu0_bru.imm_data[31:0],
               u_backend.u_alu0_bru.rs1_data, u_backend.u_alu0_bru.rs2_data);
    if (u_backend.u_alu1.completion_write_valid &&
        u_backend.u_alu1.pc[31:0] == 32'h8000_03a0)
      $display("[ALUDBG] G1 t=%0t subop=%06h is_bru=%b taken=%b pred_t=%b tgt=%08h pred_tgt=%08h misp=%b tag=%0d pc=%08h imm=%08h rs1=%016h rs2=%016h",
               $time, u_backend.u_alu1.exe_subop, u_backend.u_alu1.is_bru_op,
               u_backend.u_alu1.branch_taken, u_backend.u_alu1.pred_taken,
               u_backend.u_alu1.branch_target[31:0], u_backend.u_alu1.pred_target_pc[31:0],
               u_backend.u_alu1.mispredict_flag, u_backend.u_alu1.self_tag,
               u_backend.u_alu1.pc[31:0], u_backend.u_alu1.imm_data[31:0],
               u_backend.u_alu1.rs1_data, u_backend.u_alu1.rs2_data);
  end
end

// ─────────────────────────────────────────────────────────────────────────
// TEMP: same BNE, watched from inside ISQ_Group0 -- separates "the value was
// captured stale" from "the bypass mux picked the wrong value".
//   entry_q.rs2_data   : what was latched at dispatch
//   entry_q.rs2_ready  : 1 = producer already wrote back, 0 = still waiting
//   entry_q.rs2_wait_tag: producer tag the entry is parked on
//   mux_rs2_data       : what actually leaves the ISQ towards the FU
// DELETE THIS BLOCK when the bring-up is done.
// ─────────────────────────────────────────────────────────────────────────
integer isqdbg_cnt = 0;
always_ff @(posedge clk) begin
  if (v5dbg_en != 0 && isqdbg_cnt < 16 &&
      u_backend.u_ISQ_Group0.isq_valid_q &&
      u_backend.u_ISQ_Group0.pc[31:0] == 32'h8000_03a0) begin
    isqdbg_cnt <= isqdbg_cnt + 1;
    $display("[ISQDBG] t=%0t tag=%0d | rs1 wait=%0d rdy=%b data=%016h | rs2 wait=%0d rdy=%b data=%016h | mux2=%016h hit2=%b fast2=%b opnd_rdy=%b fire=%b | bv=%b btag=%0d,%0d,%0d,%0d",
             $time, u_backend.u_ISQ_Group0.entry_q.self_tag,
             u_backend.u_ISQ_Group0.entry_q.rs1_wait_tag,
             u_backend.u_ISQ_Group0.entry_q.rs1_ready,
             u_backend.u_ISQ_Group0.entry_q.rs1_data,
             u_backend.u_ISQ_Group0.entry_q.rs2_wait_tag,
             u_backend.u_ISQ_Group0.entry_q.rs2_ready,
             u_backend.u_ISQ_Group0.entry_q.rs2_data,
             u_backend.u_ISQ_Group0.mux_rs2_data,
             u_backend.u_ISQ_Group0.rs2_bypass_hit,
             u_backend.u_ISQ_Group0.fast_ready_rs2,
             u_backend.u_ISQ_Group0.operand_ready,
             u_backend.u_ISQ_Group0.issue_fire,
             u_backend.u_ISQ_Group0.bypass_valid,
             u_backend.u_ISQ_Group0.bypass_tag[0],
             u_backend.u_ISQ_Group0.bypass_tag[1],
             u_backend.u_ISQ_Group0.bypass_tag[2],
             u_backend.u_ISQ_Group0.bypass_tag[3]);
  end
end

// ─────────────────────────────────────────────────────────────────────────
// TEMP: the dispatch-cycle view of the same instruction (tag 11).
//
// dependency_check's chain is: row2 !use_rs -> row3 arf_ready -> row4
// commit_match -> row5 bypass_match -> row6 wait. Rows 3/4/5 all set ready
// without clearing wait_tag, so "ready=1, wait_tag=9" is normal for any of
// them; the value can still be stale if row 3 (= plain ARF read) wins while
// the producer is committing in the same cycle.
//
// source_kind: 0=WAIT_PRODUCER 1=WAIT_OVERLAY 2=NONE 3=ARF 4=COMMIT 5=BYPASS
// DELETE THIS BLOCK when the bring-up is done.
// ─────────────────────────────────────────────────────────────────────────
always_ff @(posedge clk) begin
  if (v5dbg_en != 0) begin
    for (int s = 0; s < 2; s++) begin
      if (rtl_alloc_valid[s] && rtl_alloc_tag[s] == 4'd11)
        $display("[DCDBG] t=%0t slot=%0d tag=%0d | rs1 kind=%0d arf_rdy=%b cmt_m=%b byp_m=%b prod_tag=%0d | rs2 kind=%0d arf_rdy=%b cmt_m=%b byp_m=%b prod_tag=%0d",
                 $time, s, rtl_alloc_tag[s],
                 u_backend.u_dependency_check.source_kind[s][1],
                 u_backend.u_dependency_check.arf_ready[s][1],
                 u_backend.u_dependency_check.commit_match[s][1],
                 u_backend.u_dependency_check.bypass_match[s][1],
                 u_backend.u_dependency_check.producer_tag[s][1],
                 u_backend.u_dependency_check.source_kind[s][2],
                 u_backend.u_dependency_check.arf_ready[s][2],
                 u_backend.u_dependency_check.commit_match[s][2],
                 u_backend.u_dependency_check.bypass_match[s][2],
                 u_backend.u_dependency_check.producer_tag[s][2]);
    end
  end
end
