// OR_CACHE_MSHR: line miss control path
//   port A: E3 load/LR/AMO pass miss; port B: ISB head store miss
//   DATA entry: notify ISB (inst_line) and DPB (inst_id), command WB to accept the install entry → INST;
//   when WB writes that entry into D cache (inst_wr), release and broadcast done (replay after the D cache write)
module dc_mshr
  import or_cache_pkg::*;
(
  input  logic                    clk,
  input  logic                    rst_n,
  // lookup / allocation port A (E3), port B (ISB head store miss); A has priority
  input  logic                    a_req,
  input  logic [LINE_ADDR_W-1:0]  a_line,
  output logic                    a_ok,
  output logic [MSHR_ID_W-1:0]    a_id,
  input  logic                    b_req,
  input  logic [LINE_ADDR_W-1:0]  b_line,
  output logic                    b_ok,
  output logic [MSHR_ID_W-1:0]    b_id,
  // external refill
  output logic                    l2_req_vld,
  output logic [MSHR_ID_W-1:0]    l2_req_id,
  output logic [LINE_ADDR_W-1:0]  l2_req_line,
  input  logic                    l2_req_ready,
  input  logic                    l2_resp,
  input  logic [MSHR_ID_W-1:0]    l2_resp_id,
  // DPB write
  output logic                    dpb_we,
  output logic [MSHR_ID_W-1:0]    dpb_widx,
  // install command (notify ISB / DPB, WB accepts)
  output logic                    inst_req,
  output logic [MSHR_ID_W-1:0]    inst_id,
  output logic [LINE_ADDR_W-1:0]  inst_line,
  input  logic                    inst_ack,
  // install entry written into D cache (WB)
  input  logic                    inst_wr,
  input  logic [MSHR_ID_W-1:0]    inst_wr_id,
  // completion broadcast
  output logic                    done,
  output logic [MSHR_ID_W-1:0]    done_id
);
  typedef enum logic [2:0] { M_FREE = 3'd0, M_REQ = 3'd1, M_WAIT = 3'd2, M_DATA = 3'd3, M_INST = 3'd4 } mst_e;
  mst_e                   st   [MSHR_N];
  logic [LINE_ADDR_W-1:0] line [MSHR_N];

  // port A
  logic                 a_hit, a_free;
  logic [MSHR_ID_W-1:0] a_hid, a_fid;
  always_comb begin
    a_hit = 1'b0; a_hid = '0; a_free = 1'b0; a_fid = '0;
    for (int i = MSHR_N-1; i >= 0; i--) begin
      if ((st[i] != M_FREE) && (line[i] == a_line)) begin a_hit = 1'b1; a_hid = MSHR_ID_W'(i); end
      if (st[i] == M_FREE) begin a_free = 1'b1; a_fid = MSHR_ID_W'(i); end
    end
  end
  assign a_ok = a_hit || a_free;
  assign a_id = a_hit ? a_hid : a_fid;
  logic a_new;
  assign a_new = a_req && !a_hit && a_free;

  // port B: may merge into A's entry newly allocated this cycle; a new allocation must not collide with A's new entry
  logic                 b_hit, b_free;
  logic [MSHR_ID_W-1:0] b_hid, b_fid;
  always_comb begin
    b_hit = 1'b0; b_hid = '0; b_free = 1'b0; b_fid = '0;
    for (int i = MSHR_N-1; i >= 0; i--) begin
      if ((st[i] != M_FREE) && (line[i] == b_line)) begin b_hit = 1'b1; b_hid = MSHR_ID_W'(i); end
      if ((st[i] == M_FREE) && !(a_new && (a_fid == MSHR_ID_W'(i)))) begin b_free = 1'b1; b_fid = MSHR_ID_W'(i); end
    end
    if (a_new && (a_line == b_line)) begin b_hit = 1'b1; b_hid = a_fid; end
  end
  assign b_ok = b_hit || b_free;
  assign b_id = b_hit ? b_hid : b_fid;
  logic b_new;
  assign b_new = b_req && !b_hit && b_free;

  // external request: lowest-numbered REQ entry
  always_comb begin
    l2_req_vld = 1'b0; l2_req_id = '0;
    for (int i = MSHR_N-1; i >= 0; i--)
      if (st[i] == M_REQ) begin l2_req_vld = 1'b1; l2_req_id = MSHR_ID_W'(i); end
  end
  assign l2_req_line = line[l2_req_id];

  assign dpb_we   = l2_resp;
  assign dpb_widx = l2_resp_id;

  // install request: lowest-numbered DATA entry
  always_comb begin
    inst_req = 1'b0; inst_id = '0;
    for (int i = MSHR_N-1; i >= 0; i--)
      if (st[i] == M_DATA) begin inst_req = 1'b1; inst_id = MSHR_ID_W'(i); end
  end
  assign inst_line = line[inst_id];
  assign done      = inst_wr;
  assign done_id   = inst_wr_id;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      for (int i = 0; i < MSHR_N; i++) begin st[i] <= M_FREE; line[i] <= '0; end
    end else begin
      if (l2_req_vld && l2_req_ready) st[l2_req_id] <= M_WAIT;
      if (l2_resp)                    st[l2_resp_id] <= M_DATA;
      if (inst_req && inst_ack)       st[inst_id] <= M_INST;
      if (done)                       st[inst_wr_id] <= M_FREE;
      if (a_new) begin st[a_fid] <= M_REQ; line[a_fid] <= a_line; end
      if (b_new) begin st[b_fid] <= M_REQ; line[b_fid] <= b_line; end
    end
  end

`ifndef SYNTHESIS
  always_ff @(posedge clk) if (rst_n) begin
    if (l2_resp) assert (st[l2_resp_id] == M_WAIT) else $error("[MSHR] response id=%0d not waiting", l2_resp_id);
    if (inst_wr) assert (st[inst_wr_id] == M_INST) else $error("[MSHR] install write for id=%0d not in INST", inst_wr_id);
    for (int i = 0; i < MSHR_N; i++)
      for (int j = i + 1; j < MSHR_N; j++)
        assert (!((st[i] != M_FREE) && (st[j] != M_FREE) && (line[i] == line[j])))
          else $error("[MSHR] duplicate line in entries %0d/%0d", i, j);
  end
`endif
endmodule
