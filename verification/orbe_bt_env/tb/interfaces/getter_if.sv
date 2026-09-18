interface getter_if (input logic clk);
  import mock_rtl_pkg::*;

  logic [MOCK_ISSUE_NUM-1:0] decode_rsp_valid;
  logic [MOCK_ISSUE_NUM-1:0] decode_rsp_ready;
  logic [MOCK_ISSUE_NUM-1:0][MOCK_ROB_TAG_W-1:0] decode_rsp_tag;
  logic [MOCK_ISSUE_NUM-1:0] decode_rsp_is_lsu;
  logic [MOCK_ISSUE_NUM-1:0] decode_rsp_exception;
  exception_cause_t [MOCK_ISSUE_NUM-1:0] decode_rsp_cause;
  logic [MOCK_ISSUE_NUM-1:0][63:0] decode_rsp_tval;

  logic lsu_meta_req_valid;
  logic lsu_meta_req_ready;
  logic [MOCK_ROB_TAG_W-1:0] lsu_meta_req_tag;
  logic lsu_meta_rsp_valid;
  logic lsu_meta_rsp_ready;
  logic [MOCK_ROB_TAG_W-1:0] lsu_meta_rsp_tag;
  lsu_issue_metadata_t lsu_meta_rsp_pld;

  logic execute_rsp_valid;
  logic execute_rsp_ready;
  logic [MOCK_ROB_TAG_W-1:0] execute_rsp_tag;
  logic execute_rsp_exception;
  logic execute_rsp_redirect;
  logic [63:0] execute_rsp_next_pc;
  exception_cause_t execute_rsp_cause;
  logic [63:0] execute_rsp_tval;

  logic commit_rsp_valid;
  logic commit_rsp_ready;
  logic [MOCK_ROB_TAG_W-1:0] commit_rsp_tag;
  logic commit_rsp_trap;
  exception_cause_t commit_rsp_cause;
  logic [63:0] commit_rsp_tval;
  logic [63:0] commit_rsp_redirect_pc;
endinterface
