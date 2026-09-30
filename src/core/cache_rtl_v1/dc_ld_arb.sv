// OR_CACHE_LOAD_DATA_ARBITER: two sources of read-side done -- E3 pass-through (D cache data) and E4 merge (DATA_MERGE)
//   pass-through condition decided in top's E3: hit ∧ no ISB pre-filter candidate ∧ no overlapping WB bytes ∧ no exception / no wait needed
//   when both paths are present in the same cycle, both go to CDB (the E4 one first)
module dc_ld_arb
  import or_be_lsu_protocol_pkg::*;
  import or_cache_pkg::*;
(
  // E3 pass-through: D cache bytes of this part, concatenated and shaped here
  input  logic        f_vld,
  input  lsu_tag_t    f_tag,
  input  logic [63:0] f_bytes,
  input  logic        f_part,
  input  logic [63:0] f_p0data,
  input  logic [3:0]  f_len,
  input  logic [3:0]  f_plen,
  input  logic [2:0]  f_funct3,
  input  logic        f_rd_is_fp,
  // E4 merge: result already shaped by DATA_MERGE
  input  logic        m_vld,
  input  lsu_tag_t    m_tag,
  input  logic [63:0] m_result,
  // to CDB
  output logic        o_vld [2],
  output cdb_ent_t    o_ent [2]
);
  cdb_ent_t f_ent, m_ent;
  always_comb begin
    f_ent        = '0;
    f_ent.tag    = f_tag;
    f_ent.data   = ld_assemble(f_bytes, f_part, f_p0data, f_len, f_plen, f_funct3, f_rd_is_fp);
    f_ent.bypass = 1'b1;
    m_ent        = '0;
    m_ent.tag    = m_tag;
    m_ent.data   = m_result;
    m_ent.bypass = 1'b1;

    o_vld[0] = m_vld || f_vld;
    o_ent[0] = m_vld ? m_ent : f_ent;
    o_vld[1] = m_vld && f_vld;
    o_ent[1] = f_ent;
  end
endmodule
