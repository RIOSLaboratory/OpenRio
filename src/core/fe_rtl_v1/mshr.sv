// MSHR: ICache miss tracking
module mshr
  import or_fe_pkg::*;
(
  input  logic                        clk,
  input  logic                        rst_n,
  // In-event
  input  logic                        alloc,
  input  logic [PA_W-OFF_W-1:0]       alloc_pa_line,
  input  logic [IC_IDX_W-1:0]         alloc_set,
  input  logic [IC_WAY_W-1:0]         alloc_way,
  input  logic                        cancel,
  input  logic                        l2_resp,
  input  logic [MSHR_ID_W-1:0]        l2_resp_id,
  input  logic [LINE_W-1:0]           l2_resp_data,
  // In Static Info
  input  logic                        l2_req_ready,
  // Out-event
  output logic                        l2_req_vld,
  output logic [MSHR_ID_W-1:0]        l2_req_id,
  output logic [PA_W-OFF_W-1:0]       l2_req_pa_line,
  output logic                        l2_cancel,
  output logic [MSHR_ID_W-1:0]        l2_cancel_id,
  output logic                        refill_done,
  output logic [MSHR_ID_W-1:0]        refill_done_id,
  output logic [IC_IDX_W-1:0]         refill_done_set,
  output logic [IC_WAY_W-1:0]         refill_done_way,
  output logic [IC_TAG_W-1:0]         refill_done_tag,
  output logic [LINE_W-1:0]           refill_done_data,
  // Out Static Info
  output logic                        alloc_ready,
  output logic [MSHR_ID_W-1:0]        alloc_id
);

  typedef enum logic [1:0] {
    FREE   = 2'd0,
    PEND   = 2'd1,
    CANCEL = 2'd2
  } ent_state_e;

  ent_state_e [MSHR_NUM-1:0]           state_q;
  logic [MSHR_NUM-1:0]                 sent_q;
  logic [MSHR_NUM-1:0][PA_W-OFF_W-1:0] pa_line_q;
  logic [MSHR_NUM-1:0][IC_IDX_W-1:0]   set_q;
  logic [MSHR_NUM-1:0][IC_WAY_W-1:0]   way_q;

  logic [MSHR_NUM-1:0] free_vec;
  logic [MSHR_NUM-1:0] pend_unsent;
  logic [MSHR_ID_W-1:0] req_idx;
  logic [MSHR_NUM-1:0] refill_v;
  logic [MSHR_NUM-1:0] cancel_sent_v;
  logic [MSHR_NUM-1:0] cancel_unsent_v;
  logic [MSHR_NUM-1:0] drop_v;
  logic                l2_req_fire;

  always_comb begin
    for (int i = 0; i < MSHR_NUM; i++) begin
      free_vec[i]    = (state_q[i] == FREE);
      pend_unsent[i] = (state_q[i] == PEND) && !sent_q[i];
    end
  end

  always_comb begin
    alloc_id = '0;
    req_idx  = '0;
    for (int i = MSHR_NUM - 1; i >= 0; i--) begin
      if (free_vec[i])    alloc_id = MSHR_ID_W'(i);
      if (pend_unsent[i]) req_idx  = MSHR_ID_W'(i);
    end
  end

  assign alloc_ready    = |free_vec;
  assign l2_req_vld     = (|pend_unsent) & ~cancel;
  assign l2_req_id      = req_idx;
  assign l2_req_pa_line = pa_line_q[req_idx];
  assign l2_req_fire    = l2_req_vld & l2_req_ready;

  always_comb begin
    for (int i = 0; i < MSHR_NUM; i++) begin
      refill_v[i]        = l2_resp && (l2_resp_id == MSHR_ID_W'(i)) && (state_q[i] == PEND);
      drop_v[i]          = l2_resp && (l2_resp_id == MSHR_ID_W'(i)) && (state_q[i] == CANCEL);
      cancel_sent_v[i]   = cancel && (state_q[i] == PEND) && sent_q[i] && !refill_v[i];
      cancel_unsent_v[i] = cancel && (state_q[i] == PEND) && !sent_q[i];
    end
  end

  assign l2_cancel = |cancel_sent_v;
  always_comb begin
    l2_cancel_id = '0;
    for (int i = MSHR_NUM - 1; i >= 0; i--) begin
      if (cancel_sent_v[i]) l2_cancel_id = MSHR_ID_W'(i);
    end
  end

  assign refill_done      = |refill_v;
  assign refill_done_id   = l2_resp_id;
  assign refill_done_set  = set_q[l2_resp_id];
  assign refill_done_way  = way_q[l2_resp_id];
  assign refill_done_tag  = pa_line_q[l2_resp_id][PA_W-OFF_W-1:IC_IDX_W];
  assign refill_done_data = l2_resp_data;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      for (int i = 0; i < MSHR_NUM; i++) begin
        state_q[i] <= FREE;
      end
      sent_q <= '0;
    end else begin
      for (int i = 0; i < MSHR_NUM; i++) begin
        if (alloc && (alloc_id == MSHR_ID_W'(i))) begin
          state_q[i] <= PEND;
          sent_q[i]  <= 1'b0;
        end else if (refill_v[i] || cancel_unsent_v[i] || drop_v[i]) begin
          state_q[i] <= FREE;
        end else if (cancel_sent_v[i]) begin
          state_q[i] <= CANCEL;
        end else if (l2_req_fire && (req_idx == MSHR_ID_W'(i))) begin
          sent_q[i] <= 1'b1;
        end
      end
    end
  end

  always_ff @(posedge clk) begin
    if (alloc) begin
      pa_line_q[alloc_id] <= alloc_pa_line;
      set_q[alloc_id]     <= alloc_set;
      way_q[alloc_id]     <= alloc_way;
    end
  end

endmodule
