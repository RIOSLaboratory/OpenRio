package mock_rtl_pkg;
  localparam int unsigned MOCK_ISSUE_NUM = 2;
  localparam int unsigned MOCK_ROB_DEPTH = 16;
  localparam int unsigned MOCK_ROB_SLOT_W = 4;
  localparam int unsigned MOCK_ROB_TAG_W = 4;
  localparam int unsigned MOCK_ROB_ADDR_W = 6;
  localparam int unsigned MOCK_ROB_PTR_W = 7;
  localparam int unsigned MOCK_ROB_CMT_NUM = 4;
  localparam int unsigned MOCK_FLUSH_ALL_DUP = 2;
  localparam int unsigned MOCK_VPC_W = 64;

  typedef logic [4:0] exception_cause_t;

  typedef struct packed {
    logic [63:0] pc;
    logic [31:0] inst_bits;
    logic        is_compressed;
    logic        pred_taken;
    logic [63:0] pred_target_pc;
    logic        fetch_excp_vld;
    exception_cause_t exception_cause;
    logic [63:0] exception_tval;
  } fe_instr_pld_t;

  typedef struct packed {
    logic [63:0] redirect_pc;
    logic        interrupt_valid;
    logic        trap_valid;
  } fe_redirect_pld_t;

  typedef struct packed {
    logic [63:0] pc;
    logic [31:0] inst_bits;
    logic        is_compressed;
    logic        fetch_excp_vld;
    exception_cause_t exception_cause;
    logic [63:0] exception_tval;
    logic        is_lsu;
  } rob_alloc_pld_t;

  typedef struct packed {
    logic [63:0] pc;
    logic [MOCK_ROB_PTR_W-1:0] rob_idx;
  } rob_commit_pld_t;

  typedef struct packed {
    logic is_load;
    logic is_store;
    logic is_amo;
    logic is_lr;
    logic is_sc;
    logic is_fence;
    logic is_fence_i;
  } mock_lsu_req_property_t;

  typedef struct packed {
    mock_lsu_req_property_t req_property;
    logic [23:0] exe_subop;
    logic [2:0] mem_funct3;
    logic       rd_is_fp;
    logic [63:0] rs1_data;
    logic [63:0] rs2_data;
    logic        imm_valid;
    logic signed [63:0] imm_data;
    logic        is_store;
  } lsu_issue_metadata_t;

  typedef struct packed {
    logic [MOCK_ROB_TAG_W-1:0] self_tag;
    mock_lsu_req_property_t req_property;
    logic [23:0] exe_subop;
    logic [2:0] mem_funct3;
    logic       rd_is_fp;
    logic [63:0] rs1_data;
    logic [63:0] rs2_data;
    logic        imm_valid;
    logic signed [63:0] imm_data;
    logic        is_store;
    logic        st_br_resolve;
  } lsu_issue_pld_t;

  typedef struct packed {
    logic [MOCK_ROB_TAG_W-1:0] lsu_be_done_tag;
    logic [63:0] lsu_be_done_data;
  } lsu_done_pld_t;

  typedef struct packed {
    logic [MOCK_ROB_TAG_W-1:0] lsu_be_exception_tag;
    exception_cause_t lsu_be_exception_cause;
    logic [63:0] lsu_be_exception_tval;
  } lsu_exception_pld_t;
endpackage
