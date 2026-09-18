module mock_rtl (
  input logic clk,
  input logic rst_n,
  orbe_fe_if fe,
  or_be_lsu_if lsu,
  getter_if getter
);
  import mock_rtl_pkg::*;
  import or_be_lsu_protocol_pkg::*;

  typedef struct packed {
    logic valid;
    logic [MOCK_ROB_TAG_W-1:0] tag;
    logic is_csr;
    logic [63:0] pc;
    logic [31:0] inst_bits;
    logic is_compressed;
    logic pred_taken;
    logic [63:0] pred_target_pc;
    logic decoded;
    logic is_lsu;
    logic issued;
    logic lsu_meta_pending;
    logic lsu_meta_valid;
    logic store_wakeup_pending;
    logic done;
    logic exception;
    exception_cause_t cause;
    logic [63:0] tval;
    logic [63:0] actual_next_pc;
    logic mispredict;
    lsu_issue_metadata_t lsu_meta;
  } mock_rob_entry_t;

  mock_rob_entry_t rob [MOCK_ROB_DEPTH];
  logic [MOCK_ROB_TAG_W-1:0] head_ptr;
  logic [MOCK_ROB_TAG_W-1:0] tail_ptr;
  logic [MOCK_ROB_TAG_W:0] count;

  localparam int unsigned MOCK_ROB_DEPTH_VALUE = MOCK_ROB_DEPTH;
  logic candidate_found;
  logic candidate_can_issue;
  logic [MOCK_ROB_SLOT_W-1:0] candidate_slot;
  logic [MOCK_ISSUE_NUM-1:0] lane_is_csr;
  logic rob_has_csr;
  logic [MOCK_ROB_TAG_W:0] free_slots;
  logic [MOCK_ISSUE_NUM-1:0] alloc_fire;
  logic response_block;
  logic flush_level;
  logic [MOCK_ISSUE_NUM-1:0] rob_alloc_valid;
  rob_alloc_pld_t [MOCK_ISSUE_NUM-1:0] rob_alloc_pld;
  logic [MOCK_ISSUE_NUM-1:0][MOCK_ROB_ADDR_W-1:0] rob_alloc_rob_idx;
  logic [MOCK_ISSUE_NUM-1:0][MOCK_ROB_PTR_W-1:0] rob_alloc_rob_ptr;
  logic [MOCK_ISSUE_NUM-1:0] rob_commit_valid;
  rob_commit_pld_t [MOCK_ISSUE_NUM-1:0] rob_commit_pld;
  logic [MOCK_ISSUE_NUM-1:0][MOCK_ROB_ADDR_W-1:0] rob_commit_rob_idx;
  logic [MOCK_ROB_CMT_NUM-1:0] exe_rob_wr_vld;
  logic [MOCK_ROB_CMT_NUM-1:0][MOCK_ROB_ADDR_W-1:0] exe_rob_wr_idx;
  logic [MOCK_FLUSH_ALL_DUP-1:0] flush_all;
  logic pflush;
  logic [MOCK_ROB_ADDR_W-1:0] pflush_rob_idx;
  logic redirect_valid;
  logic [MOCK_VPC_W-1:0] redirect_pc;

  // Keep mock outputs in module-local signals.  Directly writing virtual
  // interface members from combinational logic makes the 5.020 toolchain
  // repeatedly reschedule the block while settling time zero.
  logic [MOCK_ISSUE_NUM-1:0] fe_instr_ready_int;
  logic [MOCK_ISSUE_NUM-1:0] decode_rsp_ready_int;
  logic lsu_meta_rsp_ready_int;
  logic execute_rsp_ready_int;
  logic commit_rsp_ready_int;
  logic lsu_entry_ready_int;
  logic lsu_issue_valid_int;
  be_lsu_issue_pld_t lsu_issue_pld_int;
  logic lsu_meta_req_valid_int;
  logic [MOCK_ROB_TAG_W-1:0] lsu_meta_req_tag_int;
  logic fe_redirect_valid_int;
  fe_redirect_pld_t fe_redirect_pld_int;
  logic lsu_store_wakeup_valid_int;
  logic global_flush_late_int;

  function automatic logic [63:0] predicted_next_pc(
      input mock_rob_entry_t entry);
    return entry.pred_taken ? entry.pred_target_pc
        : entry.pc + (entry.is_compressed ? 64'd2 : 64'd4);
  endfunction

  function automatic bit plain_store(input lsu_issue_metadata_t metadata);
    return metadata.req_property.is_store
        && !metadata.req_property.is_amo
        && !metadata.req_property.is_sc;
  endfunction

  function automatic logic predecode_csr(
      input logic [31:0] inst_bits,
      input logic is_compressed);
    logic [6:0] opcode;
    logic [2:0] funct3;
    begin
      opcode = inst_bits[6:0];
      funct3 = inst_bits[14:12];
      if (is_compressed || opcode != 7'b1110011) begin
        predecode_csr = 1'b0;
      end else begin
        case (funct3)
          3'b001, 3'b010, 3'b011, 3'b101, 3'b110, 3'b111:
            predecode_csr = 1'b1;
          3'b000:
            predecode_csr = (inst_bits == 32'h3020_0073)
                         || (inst_bits == 32'h1020_0073)
                         || (inst_bits == 32'h7b20_0073);
          default:
            predecode_csr = 1'b0;
        endcase
      end
    end
  endfunction

  always_comb begin
    logic older_all_done;
    logic lane0_ready;
    logic [MOCK_ROB_SLOT_W-1:0] scan_slot;

    flush_level = (|flush_all) || pflush || lsu.global_flush_late;
    response_block = getter.commit_rsp_valid || flush_level;

    rob_has_csr = 1'b0;
    for (int slot = 0; slot < MOCK_ROB_DEPTH; slot++)
      rob_has_csr |= rob[slot].valid && rob[slot].is_csr;
    for (int lane = 0; lane < MOCK_ISSUE_NUM; lane++)
      lane_is_csr[lane] = predecode_csr(
          fe.fe_be_instr_pld[lane].inst_bits,
          fe.fe_be_instr_pld[lane].is_compressed);
    free_slots = MOCK_ROB_DEPTH_VALUE[MOCK_ROB_TAG_W:0] - count;
    fe_instr_ready_int = '0;
    lane0_ready = 1'b0;
    if (rst_n && !response_block) begin
      lane0_ready = (free_slots >= 1)
          && (!rob_has_csr || lane_is_csr[0]);
      fe_instr_ready_int[0] = lane0_ready;
      fe_instr_ready_int[1] = (free_slots >= 2)
          && fe.fe_be_instr_valid[0]
          && lane0_ready
          && (!(rob_has_csr || lane_is_csr[0]) || lane_is_csr[1]);
    end
    alloc_fire = fe.fe_be_instr_valid & fe_instr_ready_int;

    decode_rsp_ready_int = {MOCK_ISSUE_NUM{rst_n && !response_block}};
    lsu_meta_rsp_ready_int = rst_n && !response_block;
    execute_rsp_ready_int = rst_n && !response_block;
    commit_rsp_ready_int = rst_n && rob[head_ptr[MOCK_ROB_SLOT_W-1:0]].valid
        && rob[head_ptr[MOCK_ROB_SLOT_W-1:0]].done;

    lsu_entry_ready_int = rst_n && !response_block;

    candidate_found = 1'b0;
    candidate_can_issue = 1'b0;
    candidate_slot = '0;
    older_all_done = 1'b1;
    for (int age = 0; age < MOCK_ROB_DEPTH; age++) begin
      scan_slot = head_ptr[MOCK_ROB_SLOT_W-1:0] + age[MOCK_ROB_SLOT_W-1:0];
      if ((age < count) && rob[scan_slot].valid) begin
        if (!candidate_found && !rob[scan_slot].issued) begin
          candidate_found = 1'b1;
          candidate_slot = scan_slot;
          candidate_can_issue = older_all_done && rob[scan_slot].decoded;
        end
        if (!rob[scan_slot].done)
          older_all_done = 1'b0;
      end
    end

    lsu_issue_valid_int = 1'b0;
    lsu_issue_pld_int = '0;
    if (rst_n && !response_block && candidate_found && candidate_can_issue
        && rob[candidate_slot].is_lsu && rob[candidate_slot].lsu_meta_valid) begin
      lsu_issue_valid_int = 1'b1;
      lsu_issue_pld_int.tag = rob[candidate_slot].tag;
      lsu_issue_pld_int.rs1_data = rob[candidate_slot].lsu_meta.rs1_data;
      lsu_issue_pld_int.imm_valid = rob[candidate_slot].lsu_meta.imm_valid;
      lsu_issue_pld_int.imm_data = rob[candidate_slot].lsu_meta.imm_data;
      lsu_issue_pld_int.store_data = rob[candidate_slot].lsu_meta.rs2_data;
      lsu_issue_pld_int.mem_funct3 = rob[candidate_slot].lsu_meta.mem_funct3;
      lsu_issue_pld_int.rd_is_fp = rob[candidate_slot].lsu_meta.rd_is_fp;
      lsu_issue_pld_int.exe_subop = rob[candidate_slot].lsu_meta.exe_subop;
      lsu_issue_pld_int.st_br_resolve =
          plain_store(rob[candidate_slot].lsu_meta)
          && (candidate_slot == head_ptr[MOCK_ROB_SLOT_W-1:0]);
    end
  end

  always_ff @(posedge clk or negedge rst_n) begin : rob_lifecycle
    logic commit_accept;
    logic final_trap;
    logic [MOCK_ROB_SLOT_W-1:0] head_slot;
    logic [MOCK_ROB_SLOT_W-1:0] rsp_slot;
    logic [MOCK_ROB_TAG_W-1:0] alloc_tag;
    int unsigned alloc_count;

    if (!rst_n) begin
      head_ptr <= '0;
      tail_ptr <= '0;
      count <= '0;
      getter.lsu_meta_req_valid <= 1'b0;
      getter.lsu_meta_req_tag <= '0;
      rob_alloc_valid <= '0;
      rob_alloc_pld <= '{default:'0};
      rob_alloc_rob_idx <= '0;
      rob_alloc_rob_ptr <= '0;
      rob_commit_valid <= '0;
      rob_commit_pld <= '{default:'0};
      rob_commit_rob_idx <= '0;
      exe_rob_wr_vld <= '0;
      exe_rob_wr_idx <= '0;
      flush_all <= '0;
      pflush <= 1'b0;
      pflush_rob_idx <= '0;
      redirect_valid <= 1'b0;
      redirect_pc <= '0;
      fe.be_fe_redirect_valid <= 1'b0;
      fe.be_fe_redirect_pld <= '0;
      lsu.be_lsu_store_wakeup_valid <= 1'b0;
      lsu.global_flush_late <= 1'b0;
      for (int slot = 0; slot < MOCK_ROB_DEPTH; slot++)
        rob[slot] <= '0;
    end else begin
      head_slot = head_ptr[MOCK_ROB_SLOT_W-1:0];
      commit_accept = getter.commit_rsp_valid && commit_rsp_ready_int;
      final_trap = rob[head_slot].exception || getter.commit_rsp_trap;
      alloc_count = 0;

      if (alloc_fire[1] && !alloc_fire[0])
        $fatal(1, "[MOCK] lane 1 allocation without lane 0");
      if (rob_has_csr) begin
        for (int lane = 0; lane < MOCK_ISSUE_NUM; lane++)
          if (alloc_fire[lane] && !lane_is_csr[lane])
            $fatal(1, "[MOCK] non-CSR allocation while CSR is in flight lane=%0d", lane);
      end
      if (alloc_fire[0] && lane_is_csr[0]
          && alloc_fire[1] && !lane_is_csr[1])
        $fatal(1, "[MOCK] non-CSR lane 1 follows CSR lane 0");
      for (int slot = 0; slot < MOCK_ROB_DEPTH; slot++)
        if (!rob[slot].valid && rob[slot].is_csr)
          $fatal(1, "[MOCK] released entry retains CSR admission metadata slot=%0d", slot);
      rob_alloc_valid <= '0;
      rob_commit_valid <= '0;
      exe_rob_wr_vld <= '0;
      flush_all <= '0;
      pflush <= 1'b0;
      redirect_valid <= 1'b0;
      fe.be_fe_redirect_valid <= 1'b0;
      lsu.be_lsu_store_wakeup_valid <= 1'b0;
      lsu.global_flush_late <= 1'b0;

      if (getter.commit_rsp_valid && !commit_rsp_ready_int)
        $fatal(1, "[MOCK] commit response without a completed ROB head");
      if (commit_accept && getter.commit_rsp_tag != rob[head_slot].tag)
        $fatal(1, "[MOCK] stale or mismatched commit response tag=0x%0h head=0x%0h",
               getter.commit_rsp_tag, rob[head_slot].tag);

      if (commit_accept) begin
        getter.lsu_meta_req_valid <= 1'b0;
        if (final_trap) begin
          fe.be_fe_redirect_valid <= 1'b1;
          fe.be_fe_redirect_pld.redirect_pc <= getter.commit_rsp_redirect_pc;
          fe.be_fe_redirect_pld.trap_valid <= 1'b1;
          fe.be_fe_redirect_pld.interrupt_valid <= 1'b0;
          redirect_valid <= 1'b1;
          redirect_pc <= getter.commit_rsp_redirect_pc;
          flush_all <= '1;
          lsu.global_flush_late <= 1'b1;
          for (int slot = 0; slot < MOCK_ROB_DEPTH; slot++)
            rob[slot] <= '0;
          head_ptr <= tail_ptr;
          count <= '0;
          $display("[MOCK][TRAP_FLUSH] tag=0x%0h pc=0x%016h redirect=0x%016h",
                   rob[head_slot].tag, rob[head_slot].pc,
                   getter.commit_rsp_redirect_pc);
        end else if (rob[head_slot].mispredict) begin
          fe.be_fe_redirect_valid <= 1'b1;
          fe.be_fe_redirect_pld.redirect_pc <= rob[head_slot].actual_next_pc;
          fe.be_fe_redirect_pld.trap_valid <= 1'b0;
          fe.be_fe_redirect_pld.interrupt_valid <= 1'b0;
          redirect_valid <= 1'b1;
          redirect_pc <= rob[head_slot].actual_next_pc;
          pflush <= 1'b1;
          pflush_rob_idx <= {{(MOCK_ROB_ADDR_W-MOCK_ROB_SLOT_W){1'b0}},
                             rob[head_slot].tag[MOCK_ROB_SLOT_W-1:0]};
          lsu.global_flush_late <= 1'b1;
          for (int slot = 0; slot < MOCK_ROB_DEPTH; slot++)
            rob[slot] <= '0;
          head_ptr <= head_ptr + 1'b1;
          tail_ptr <= head_ptr + 1'b1;
          count <= '0;
          $display("[MOCK][BRANCH_FLUSH] tag=0x%0h pc=0x%016h redirect=0x%016h",
                   rob[head_slot].tag, rob[head_slot].pc,
                   rob[head_slot].actual_next_pc);
        end else begin
          rob[head_slot] <= '0;
          head_ptr <= head_ptr + 1'b1;
          count <= count - 1'b1;
        end
      end else begin
        for (int lane = 0; lane < MOCK_ISSUE_NUM; lane++) begin
          if (getter.decode_rsp_valid[lane] && decode_rsp_ready_int[lane]) begin
            rsp_slot = getter.decode_rsp_tag[lane][MOCK_ROB_SLOT_W-1:0];
            if (!rob[rsp_slot].valid
                || rob[rsp_slot].tag != getter.decode_rsp_tag[lane]
                || rob[rsp_slot].decoded)
              $fatal(1, "[MOCK] stale, mismatched, or duplicate decode response lane=%0d tag=0x%0h",
                     lane, getter.decode_rsp_tag[lane]);
            rob[rsp_slot].decoded <= 1'b1;
            rob[rsp_slot].is_lsu <= getter.decode_rsp_is_lsu[lane];
            if (getter.decode_rsp_exception[lane]
                && !rob[rsp_slot].exception) begin
              rob[rsp_slot].exception <= 1'b1;
              rob[rsp_slot].cause <= getter.decode_rsp_cause[lane];
              rob[rsp_slot].tval <= getter.decode_rsp_tval[lane];
            end
          end
        end

        if (getter.lsu_meta_rsp_valid && lsu_meta_rsp_ready_int) begin
          rsp_slot = getter.lsu_meta_rsp_tag[MOCK_ROB_SLOT_W-1:0];
          if (!rob[rsp_slot].valid
              || rob[rsp_slot].tag != getter.lsu_meta_rsp_tag
              || !rob[rsp_slot].is_lsu || !rob[rsp_slot].lsu_meta_pending)
            $fatal(1, "[MOCK] stale or mismatched LSU metadata response tag=0x%0h",
                   getter.lsu_meta_rsp_tag);
          rob[rsp_slot].lsu_meta <= getter.lsu_meta_rsp_pld;
          rob[rsp_slot].lsu_meta_pending <= 1'b0;
          rob[rsp_slot].lsu_meta_valid <= 1'b1;
          getter.lsu_meta_req_valid <= 1'b0;
        end

        if (getter.execute_rsp_valid && execute_rsp_ready_int) begin
          rsp_slot = getter.execute_rsp_tag[MOCK_ROB_SLOT_W-1:0];
          if (!rob[rsp_slot].valid
              || rob[rsp_slot].tag != getter.execute_rsp_tag
              || rob[rsp_slot].is_lsu || !rob[rsp_slot].issued)
            $fatal(1, "[MOCK] stale, mismatched, or non-execute response tag=0x%0h",
                   getter.execute_rsp_tag);
          rob[rsp_slot].actual_next_pc <= getter.execute_rsp_next_pc;
          rob[rsp_slot].mispredict <= !getter.execute_rsp_exception
              && (getter.execute_rsp_next_pc != predicted_next_pc(rob[rsp_slot]));
          if (getter.execute_rsp_exception && !rob[rsp_slot].exception) begin
            rob[rsp_slot].exception <= 1'b1;
            rob[rsp_slot].cause <= getter.execute_rsp_cause;
            rob[rsp_slot].tval <= getter.execute_rsp_tval;
          end
          rob[rsp_slot].done <= 1'b1;
          if (!rob[head_slot].done
              && getter.execute_rsp_tag == rob[head_slot].tag) begin
            rob_commit_valid[0] <= 1'b1;
            rob_commit_pld[0].pc <= rob[head_slot].pc;
            rob_commit_pld[0].rob_idx <=
                {{(MOCK_ROB_PTR_W-MOCK_ROB_TAG_W){1'b0}}, rob[head_slot].tag};
            rob_commit_rob_idx[0] <=
                {{(MOCK_ROB_ADDR_W-MOCK_ROB_SLOT_W){1'b0}},
                 rob[head_slot].tag[MOCK_ROB_SLOT_W-1:0]};
          end
        end

        if (lsu.lsu_be_done_valid && lsu_entry_ready_int) begin
          rsp_slot = lsu.lsu_be_writeback_pld.tag[MOCK_ROB_SLOT_W-1:0];
          if (!rob[rsp_slot].valid
              || rob[rsp_slot].tag != lsu.lsu_be_writeback_pld.tag
              || !rob[rsp_slot].is_lsu || !rob[rsp_slot].issued) begin
            $warning("[MOCK] drop stale LSU done response tag=0x%0h",
                     lsu.lsu_be_writeback_pld.tag);
          end else begin
            rob[rsp_slot].done <= 1'b1;
            if (!rob[head_slot].done
                && lsu.lsu_be_writeback_pld.tag == rob[head_slot].tag) begin
              rob_commit_valid[0] <= 1'b1;
              rob_commit_pld[0].pc <= rob[head_slot].pc;
              rob_commit_pld[0].rob_idx <=
                  {{(MOCK_ROB_PTR_W-MOCK_ROB_TAG_W){1'b0}}, rob[head_slot].tag};
              rob_commit_rob_idx[0] <=
                  {{(MOCK_ROB_ADDR_W-MOCK_ROB_SLOT_W){1'b0}},
                   rob[head_slot].tag[MOCK_ROB_SLOT_W-1:0]};
            end
          end
        end

        if (lsu.lsu_be_exception_valid && lsu_entry_ready_int) begin
          rsp_slot = lsu.lsu_be_writeback_pld.tag[MOCK_ROB_SLOT_W-1:0];
          if (!rob[rsp_slot].valid
              || rob[rsp_slot].tag != lsu.lsu_be_writeback_pld.tag
              || !rob[rsp_slot].is_lsu || !rob[rsp_slot].issued) begin
            $warning("[MOCK] drop stale LSU exception response tag=0x%0h",
                     lsu.lsu_be_writeback_pld.tag);
          end else begin
            rob[rsp_slot].done <= 1'b1;
            if (!rob[rsp_slot].exception) begin
              rob[rsp_slot].exception <= 1'b1;
              rob[rsp_slot].cause <= lsu.lsu_be_writeback_pld.exception_cause[4:0];
              rob[rsp_slot].tval <= lsu.lsu_be_writeback_pld.exception_tval;
            end
            if (!rob[head_slot].done
                && lsu.lsu_be_writeback_pld.tag == rob[head_slot].tag) begin
              rob_commit_valid[0] <= 1'b1;
              rob_commit_pld[0].pc <= rob[head_slot].pc;
              rob_commit_pld[0].rob_idx <=
                  {{(MOCK_ROB_PTR_W-MOCK_ROB_TAG_W){1'b0}}, rob[head_slot].tag};
              rob_commit_rob_idx[0] <=
                  {{(MOCK_ROB_ADDR_W-MOCK_ROB_SLOT_W){1'b0}},
                   rob[head_slot].tag[MOCK_ROB_SLOT_W-1:0]};
            end
          end
        end

        if (candidate_found && candidate_can_issue && !response_block) begin
          if (rob[candidate_slot].is_lsu) begin
            if (!rob[candidate_slot].lsu_meta_valid
                && !rob[candidate_slot].lsu_meta_pending
                && !getter.lsu_meta_req_valid && getter.lsu_meta_req_ready) begin
              getter.lsu_meta_req_valid <= 1'b1;
              getter.lsu_meta_req_tag <= rob[candidate_slot].tag;
              rob[candidate_slot].lsu_meta_pending <= 1'b1;
            end else if (rob[candidate_slot].lsu_meta_valid
                         && lsu_issue_valid_int
                         && lsu.lsu_be_issue_ready) begin
              rob[candidate_slot].issued <= 1'b1;
              rob[candidate_slot].store_wakeup_pending <=
                  plain_store(rob[candidate_slot].lsu_meta)
                  && (candidate_slot != head_slot);
            end
          end else begin
            exe_rob_wr_vld[0] <= 1'b1;
            exe_rob_wr_idx[0] <=
                {{(MOCK_ROB_ADDR_W-MOCK_ROB_SLOT_W){1'b0}}, candidate_slot};
            rob[candidate_slot].issued <= 1'b1;
          end
        end

        if (rob[head_slot].valid && rob[head_slot].issued
            && rob[head_slot].store_wakeup_pending) begin
          lsu.be_lsu_store_wakeup_valid <= 1'b1;
          rob[head_slot].store_wakeup_pending <= 1'b0;
        end

        if (rob[head_slot].valid && rob[head_slot].done
            && !getter.commit_rsp_valid) begin
          rob_commit_valid[0] <= 1'b1;
          rob_commit_pld[0].pc <= rob[head_slot].pc;
          rob_commit_pld[0].rob_idx <=
              {{(MOCK_ROB_PTR_W-MOCK_ROB_TAG_W){1'b0}}, rob[head_slot].tag};
          rob_commit_rob_idx[0] <=
              {{(MOCK_ROB_ADDR_W-MOCK_ROB_SLOT_W){1'b0}},
               rob[head_slot].tag[MOCK_ROB_SLOT_W-1:0]};
        end

        for (int lane = 0; lane < MOCK_ISSUE_NUM; lane++) begin
          if (alloc_fire[lane]) begin
            alloc_tag = tail_ptr + lane[MOCK_ROB_TAG_W-1:0];
            rsp_slot = alloc_tag[MOCK_ROB_SLOT_W-1:0];
            if (rob[rsp_slot].valid)
              $fatal(1, "[MOCK] allocation overwrites live slot=%0d tag=0x%0h",
                     rsp_slot, rob[rsp_slot].tag);
            rob[rsp_slot] <= '0;
            rob[rsp_slot].valid <= 1'b1;
            if (lane_is_csr[lane] !== predecode_csr(
                    fe.fe_be_instr_pld[lane].inst_bits,
                    fe.fe_be_instr_pld[lane].is_compressed))
              $fatal(1, "[MOCK] CSR predecode changed during allocation lane=%0d", lane);
            rob[rsp_slot].is_csr <= lane_is_csr[lane];
            rob[rsp_slot].tag <= alloc_tag;
            rob[rsp_slot].pc <= fe.fe_be_instr_pld[lane].pc;
            rob[rsp_slot].inst_bits <= fe.fe_be_instr_pld[lane].inst_bits;
            rob[rsp_slot].is_compressed <= fe.fe_be_instr_pld[lane].is_compressed;
            rob[rsp_slot].pred_taken <= fe.fe_be_instr_pld[lane].pred_taken;
            rob[rsp_slot].pred_target_pc <= fe.fe_be_instr_pld[lane].pred_target_pc;
            rob[rsp_slot].exception <= fe.fe_be_instr_pld[lane].fetch_excp_vld;
            rob[rsp_slot].cause <= fe.fe_be_instr_pld[lane].exception_cause;
            rob[rsp_slot].tval <= fe.fe_be_instr_pld[lane].exception_tval;
            rob_alloc_valid[lane] <= 1'b1;
            rob_alloc_pld[lane].pc <= fe.fe_be_instr_pld[lane].pc;
            rob_alloc_pld[lane].inst_bits <= fe.fe_be_instr_pld[lane].inst_bits;
            rob_alloc_pld[lane].is_compressed <= fe.fe_be_instr_pld[lane].is_compressed;
            rob_alloc_pld[lane].fetch_excp_vld <= fe.fe_be_instr_pld[lane].fetch_excp_vld;
            rob_alloc_pld[lane].exception_cause <= fe.fe_be_instr_pld[lane].exception_cause;
            rob_alloc_pld[lane].exception_tval <= fe.fe_be_instr_pld[lane].exception_tval;
            rob_alloc_pld[lane].is_lsu <= 1'b0;
            rob_alloc_rob_idx[lane] <=
                {{(MOCK_ROB_ADDR_W-MOCK_ROB_SLOT_W){1'b0}},
                 alloc_tag[MOCK_ROB_SLOT_W-1:0]};
            rob_alloc_rob_ptr[lane] <=
                {{(MOCK_ROB_PTR_W-MOCK_ROB_TAG_W){1'b0}}, alloc_tag};
            alloc_count++;
          end
        end
        if (alloc_count != 0) begin
          tail_ptr <= tail_ptr + alloc_count[MOCK_ROB_TAG_W-1:0];
          count <= count + alloc_count[MOCK_ROB_TAG_W:0];
        end
      end
    end
  end
endmodule
