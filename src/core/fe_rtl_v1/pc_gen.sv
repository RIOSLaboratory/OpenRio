// PC_GEN: S0 fetch address generation and level-2 redirect arbitration
module pc_gen
  import or_fe_pkg::*;
(
  input  logic                clk,
  input  logic                rst_n,
  // In-event
  input  logic                fetch_req_rdy,
  input  logic                be_redirect,
  input  logic [VA_W-1:0]     be_redirect_pc,
  input  logic                prechk_redirect,
  input  logic [VA_W-1:0]     prechk_redirect_pc,
  input  logic                l1btb_redirect,
  input  logic [VA_W-1:0]     l1btb_redirect_pc,
  input  logic                replay,
  input  logic [VA_W-1:0]     replay_pc,
  input  logic                miss_drop,
  // In Static Info
  input  logic [VA_W-1:0]     boot_pc,
  input  logic                sleep_stall,
  // Out Static Info
  output logic                fetch_req_vld,
  output logic [VA_W-1:0]     fetch_pc
);

  typedef enum logic [1:0] {
    RESET       = 2'd0,
    RUN         = 2'd1,
    WAIT_REPLAY = 2'd2
  } state_e;

  state_e             state_q;
  logic [VA_W-1:0]    pc_q;

  logic            fetch_req_hsk;
  logic            boot_fire;
  logic            redirect_take;
  logic            wait_replay;
  logic [VA_W-1:0] sel_pc;
  logic [VA_W-1:0] pc_next;

  assign boot_fire     = (state_q == RESET);
  assign redirect_take = (be_redirect | prechk_redirect | l1btb_redirect | replay) & (state_q != RESET);
  assign wait_replay   = miss_drop & ~redirect_take;

  assign sel_pc = be_redirect     ? be_redirect_pc     :
                  prechk_redirect ? prechk_redirect_pc :
                  l1btb_redirect  ? l1btb_redirect_pc  :
                                    replay_pc;

  assign fetch_pc      = redirect_take ? sel_pc : pc_q;
  assign fetch_req_vld = ~sleep_stall & (state_q != RESET) & ((state_q == RUN) | redirect_take);

  assign fetch_req_hsk = fetch_req_vld & fetch_req_rdy;

  assign pc_next = fetch_req_hsk ? (line_base(fetch_pc) + VA_W'(FETCH_BYTES)) : fetch_pc;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state_q <= RESET;
      pc_q    <= '0;
    end else if (boot_fire) begin
      state_q <= RUN;
      pc_q    <= boot_pc;
    end else begin
      if (redirect_take || fetch_req_hsk) begin
        pc_q    <= pc_next;
      end
      if (redirect_take) begin
        state_q <= RUN;
      end else if (wait_replay) begin
        state_q <= WAIT_REPLAY;
      end
    end
  end

endmodule
