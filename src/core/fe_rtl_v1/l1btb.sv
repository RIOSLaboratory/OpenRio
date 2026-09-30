// L1BTB: the only branch predictor, S0 read, S1 read-out, S1/S2 register, S2 compare and redirect
module l1btb
  import or_fe_pkg::*;
(
  input  logic                  clk,
  input  logic                  rst_n,
  // In-event
  input  logic                  req_hsk,
  input  logic [VA_W-1:0]       req_pc,
  input  logic                  rd_hsk,
  input  logic                  pred_hsk,
  input  logic                  pred_kill,
  input  logic                  update,
  input  logic [VA_W-1:0]       upd_pc,
  input  logic [BTB_WAY_W-1:0]  upd_way,
  input  btb_wr_mode_t          upd_mode,
  input  logic [SLOT_W-1:0]     upd_slot,
  input  bp_type_t              upd_type,
  input  logic [1:0]            upd_ctr,
  input  logic [VA_W-1:0]       upd_target,
  input  logic                  upd_wr_tgt,
  // In Static Info
  input  logic                  pred_vld,
  input  logic [VA_W-1:0]       pred_pc,
  // Out-event
  output logic                  redirect,
  output logic [VA_W-1:0]       redirect_pc,
  // Out Static Info
  output l1btb_meta_t           meta
);

  typedef struct packed {
    logic                  vld;
    logic [BTB_TAG_W-1:0]  tag;
    logic [SLOT_W-1:0]     slot;
    bp_type_t              btype;
    logic [1:0]            ctr;
    logic [VA_W-1:0]       target;
  } btb_ent_t;

  btb_ent_t                     btb_arr [BTB_SETS][BTB_WAYS];
  logic [BTB_SETS-1:0][BTB_WAYS-1:0] vld_q;
  btb_ent_t [BTB_WAYS-1:0]      rd_q;
  btb_ent_t [BTB_WAYS-1:0]      pred_q;
  l1btb_meta_t                  meta_q;
  logic                         done_q;

  // ---------------- S2 prediction ----------------
  l1btb_meta_t          pred;
  logic [BTB_WAYS-1:0]  tk_w;
  logic                 found;

  always_comb begin
    pred = '0;
    for (int w = 0; w < BTB_WAYS; w++) begin
      pred.hit_w[w]  = pred_q[w].vld && (pred_q[w].tag == btb_tag(pred_pc)) && (pred_q[w].slot >= slot_of(pred_pc));
      pred.slot_w[w] = pred_q[w].slot;
      pred.ctr_w[w]  = pred_q[w].ctr;
      tk_w[w]        = pred.hit_w[w] && (pred_q[w].btype != BP_NO_BR) &&
                       ((pred_q[w].btype != BP_BR) || pred_q[w].ctr[1]);
    end
    pred.taken = |tk_w;
    // predicted-taken jump in the earliest slot; lowest way wins within the same slot
    found = 1'b0;
    for (int w = 0; w < BTB_WAYS; w++) begin
      if (tk_w[w] && (!found || (pred_q[w].slot < pred_q[pred.tk_way].slot))) begin
        pred.tk_way = BTB_WAY_W'(w);
        found       = 1'b1;
      end
    end
    pred.tk_slot   = pred_q[pred.tk_way].slot;
    pred.tk_type   = pred_q[pred.tk_way].btype;
    pred.tk_target = pred_q[pred.tk_way].target;
  end

  assign redirect        = pred_vld & pred.taken & ~done_q;
  assign redirect_pc = pred.tk_target;
  assign meta         = meta_q;

  // ---------------- state ----------------
  logic [BTB_IDX_W-1:0] upd_set;
  assign upd_set = btb_idx(upd_pc);

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      done_q <= 1'b0;
      vld_q  <= '0;
    end else begin
      if (pred_hsk || pred_kill) begin
        done_q <= 1'b0;
      end else if (redirect) begin
        done_q <= 1'b1;
      end
      if (update) begin
        vld_q[upd_set][upd_way] <= (upd_mode != BTB_CLR);
      end
    end
  end

  always_ff @(posedge clk) begin
    if (update && (upd_mode != BTB_CLR)) begin
      btb_arr[upd_set][upd_way].tag   <= btb_tag(upd_pc);
      btb_arr[upd_set][upd_way].slot  <= upd_slot;
      btb_arr[upd_set][upd_way].btype <= upd_type;
      btb_arr[upd_set][upd_way].ctr   <= upd_ctr;
      if ((upd_mode == BTB_ALLOC) || upd_wr_tgt) begin
        btb_arr[upd_set][upd_way].target <= upd_target;
      end
    end
    if (req_hsk) begin
      for (int w = 0; w < BTB_WAYS; w++) begin
        rd_q[w]     <= btb_arr[btb_idx(req_pc)][w];
        rd_q[w].vld <= vld_q[btb_idx(req_pc)][w];
      end
    end
    if (rd_hsk) begin
      pred_q <= rd_q;
    end
    if (pred_hsk) begin
      meta_q <= pred;
    end
  end

endmodule
