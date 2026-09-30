// OR_Cache common parameters, encodings, types and functions
`ifndef OR_CACHE_PKG_SV
`define OR_CACHE_PKG_SV

package or_cache_pkg;
  import or_be_lsu_protocol_pkg::*;

  // ---------------------------------------------------------------- parameters
  localparam int XLEN        = 64;
  localparam int NTAG        = 1 << LSU_TAG_W;          // in-flight tag limit 16
  localparam int LINE_BYTES  = 64;                      // ⟨to confirm⟩
  localparam int OFF_W       = 6;
  localparam int LINE_W      = 8 * LINE_BYTES;
  localparam int DC_SETS     = 64;                      // ⟨to confirm⟩
  localparam int IDX_W       = 6;
  localparam int DC_WAYS     = 4;                       // ⟨to confirm⟩
  localparam int WAY_W       = 2;
  localparam int PA_W        = 56;
  localparam int LINE_ADDR_W = PA_W - OFF_W;            // 50
  localparam int DC_TAG_W    = PA_W - OFF_W - IDX_W;    // 44 (OFF_W+IDX_W == 12)
  localparam int VPN_W       = 52;                      // VA[63:12]
  localparam int PPN_W       = PA_W - 12;               // 44
  localparam int DTLB_N      = 16;                      // ⟨to confirm⟩
  localparam int DTLB_IDX_W  = 4;
  localparam int TMQ_N       = 2;                       // ⟨to confirm⟩
  localparam int TMQ_ID_W    = 1;
  localparam int TLB_EPOCH_W = 2;
  localparam int MSHR_N      = 2;                       // ⟨to confirm⟩
  localparam int MSHR_ID_W   = 1;
  localparam int MISSQ_N     = NTAG;                    // = in-flight limit, read side never rejected
  localparam int MQ_IDX_W    = 4;
  localparam int ISB_N       = LSU_STORE_BUFFER_DEPTH;  // 4
  localparam int ISB_IDX_W   = 2;
  localparam int ISB_PTR_W   = ISB_IDX_W + 1;
  localparam int WB_N        = 4;                       // ⟨to confirm⟩
  localparam int WB_PTR_W    = 3;
  localparam int CDB_N       = NTAG;
  localparam int CDB_PTR_W   = 5;
  localparam int SEQ_W       = 6;                       // program sequence number (in-flight window < 32)

  // PMA: platform memory_segments (dpi/rivai_0x80000000_1core_rom.yaml) ⟨to confirm: keep in sync when the config changes⟩
  localparam int PMA_N = 6;
  localparam logic [63:0] PMA_BASE [PMA_N] = '{64'h0,         64'h1000_0000,  64'h8000_0000,
                                               64'h1_0000_0000, 64'h1_1010_0000, 64'h7_0000_0000};
  localparam logic [63:0] PMA_SIZE [PMA_N] = '{64'h1000_0000, 64'h1000_1000,  64'h2000_0000,
                                               64'h1000_0000,   64'h1000_0000,   64'h2000_0000};

  // ---------------------------------------------------------------- encodings
  typedef enum logic [1:0] { PG_4K = 2'd0, PG_2M = 2'd1, PG_1G = 2'd2 } pg_lvl_t;

  localparam logic [4:0] CAUSE_LD_MISALIGN = 5'd4;
  localparam logic [4:0] CAUSE_LD_ACCESS   = 5'd5;
  localparam logic [4:0] CAUSE_ST_MISALIGN = 5'd6;
  localparam logic [4:0] CAUSE_ST_ACCESS   = 5'd7;

  // MissQ wait reasons
  typedef enum logic [2:0] {
    W_NONE     = 3'd0,   // ready
    W_TLB      = 3'd1,   // wait for PTW response of TMQ[wait_id]
    W_TLB_ANY  = 3'd2,   // TMQ full, wait for any PTW response or DTLB invalidation
    W_MSHR     = 3'd3,   // wait for MSHR[wait_id] install to complete
    W_MSHR_ANY = 3'd4,   // MSHR full, wait for any MSHR release
    W_ISB      = 3'd5    // wait for older store's PA / AMO/SC commit (hand to WB)
  } mq_wait_e;

  // ISB entry kinds
  typedef enum logic [1:0] { K_STORE = 2'd0, K_AMO = 2'd1, K_SC = 2'd2 } isb_kind_e;

  // ---------------------------------------------------------------- types
  // one op in the pipeline / MissQ (one pass of one part)
  typedef struct packed {
    lsu_tag_t              tag;
    lsu_req_property_t     prop;
    lsu_memop_t            memop;
    logic [2:0]            funct3;
    logic                  rd_is_fp;
    logic [SEQ_W-1:0]      seq;
    logic [63:0]           va;         // original access VA (on the issue pass computed by AGU in E1, travels with the op into E2)
    logic [3:0]            len;        // total access byte count 1..8
    logic                  part;       // 0 / 1 (1 on the second pass of a cross-line access)
    logic [63:0]           p0data;     // part1 pass: bytes collected by part0 (LSB-aligned)
    logic [ISB_IDX_W-1:0]  isb_idx;    // store side: ISB entry
    logic                  pre_fault;  // this class's fault given by the PTW response (reported directly as exception on replay)
    logic [4:0]            pre_cause;
  } dc_op_t;

  // CDB terminal state
  typedef struct packed {
    logic                  is_exc;
    lsu_tag_t              tag;
    logic [63:0]           data;       // done: result; exception: tval
    logic [4:0]            cause;
    logic                  bypass;
  } cdb_ent_t;

  // one part committed by ISB to WB (WB is per line; ISB supplies this part's bytes and the L1D lookup result)
  typedef struct packed {
    logic [LINE_ADDR_W-1:0] line;
    logic [OFF_W-1:0]       off;
    logic [3:0]             plen;
    logic [63:0]            data;      // bytes of this part (LSB-aligned)
    logic                   hit;       // L1D hit (way valid)
    logic [WAY_W-1:0]       way;
  } st_part_t;

  // forwarding level 1 (E2, VA page-offset pre-filter) result for one ISB entry: candidate for each byte of the read
  typedef struct packed {
    logic [7:0]       v;               // byte b has the same page offset as some store byte of this entry
    logic [7:0][2:0]  j;               // corresponding store byte index
    logic [7:0]       p;               // part that store byte belongs to
  } pf_ent_t;

  // ---------------------------------------------------------------- functions
  function automatic logic is_store_class(input lsu_req_property_t p);
    return p.is_store || p.is_amo || p.is_sc;
  endfunction

  function automatic logic is_read_only(input lsu_req_property_t p);   // load / LR
    return p.is_load || p.is_lr;
  endfunction

  function automatic logic is_misc(input lsu_req_property_t p);
    return p.is_fence || p.is_fence_i;
  endfunction

  // a is older than b (program order; window < 2^(SEQ_W-1))
  function automatic logic seq_older(input logic [SEQ_W-1:0] a, input logic [SEQ_W-1:0] b);
    logic [SEQ_W-1:0] d;
    d = b - a;
    return (d != '0) && !d[SEQ_W-1];
  endfunction

  function automatic logic pma_ok(input logic [63:0] pa);
    logic ok;
    ok = 1'b0;
    for (int i = 0; i < PMA_N; i++)
      if ((pa >= PMA_BASE[i]) && (pa - PMA_BASE[i] < PMA_SIZE[i])) ok = 1'b1;
    return ok;
  endfunction

  // whether an atomic is naturally aligned
  function automatic logic atomic_aligned(input logic [63:0] va, input logic [3:0] len);
    return (len == 4'd8) ? (va[2:0] == 3'd0) : (va[1:0] == 2'd0);
  endfunction

  // shape by mem_funct3 / rd_is_fp: sign/zero extension, FLW NaN-box
  function automatic logic [63:0] shape_load(input logic [2:0] f3, input logic fp,
                                             input logic [63:0] raw);
    case (f3)
      3'b000: return {{56{raw[7]}},  raw[7:0]};
      3'b001: return {{48{raw[15]}}, raw[15:0]};
      3'b010: return fp ? {32'hFFFF_FFFF, raw[31:0]} : {{32{raw[31]}}, raw[31:0]};
      3'b100: return {56'd0, raw[7:0]};
      3'b101: return {48'd0, raw[15:0]};
      3'b110: return {32'd0, raw[31:0]};
      default: return raw;
    endcase
  endfunction

  // mask of the low n bytes
  function automatic logic [7:0] byte_mask(input logic [3:0] n);
    return (n >= 4'd8) ? 8'hFF : 8'((9'd1 << n) - 9'd1);
  endfunction

  // read-side result: this part's bytes (LSB-aligned) concatenated with cross-line part0 collected bytes into len bytes, then shaped by funct3 / rd_is_fp
  // (shared by DATA_MERGE and LOAD_DATA_ARBITER)
  function automatic logic [63:0] ld_assemble(input logic [63:0] part_bytes, input logic part,
                                              input logic [63:0] p0data, input logic [3:0] len,
                                              input logic [3:0] plen, input logic [2:0] f3, input logic fp);
    logic [63:0] raw;
    logic [7:0]  m;
    raw = part ? (p0data | (part_bytes << (8 * (len - plen)))) : part_bytes;
    m   = byte_mask(len);
    for (int j = 0; j < 8; j++) if (!m[j]) raw[8*j +: 8] = 8'd0;
    return shape_load(f3, fp, raw);
  endfunction

  // AMO new value (same semantics as isa_model process_mem_load; w means .W)
  function automatic logic [63:0] amo_calc(input lsu_memop_t op, input logic w,
                                           input logic [63:0] old_raw, input logic [63:0] src);
    logic [63:0] a_s, b_s, a_u, b_u, r;
    a_s = w ? {{32{old_raw[31]}}, old_raw[31:0]} : old_raw;
    b_s = w ? {{32{src[31]}}, src[31:0]}         : src;
    a_u = w ? {32'd0, old_raw[31:0]} : old_raw;
    b_u = w ? {32'd0, src[31:0]}     : src;
    case (op)
      LSU_MEMOP_AMOSWAP: r = src;
      LSU_MEMOP_AMOADD:  r = old_raw + src;
      LSU_MEMOP_AMOXOR:  r = old_raw ^ src;
      LSU_MEMOP_AMOAND:  r = old_raw & src;
      LSU_MEMOP_AMOOR:   r = old_raw | src;
      LSU_MEMOP_AMOMIN:  r = ($signed(a_s) < $signed(b_s)) ? old_raw : src;
      LSU_MEMOP_AMOMAX:  r = ($signed(a_s) > $signed(b_s)) ? old_raw : src;
      LSU_MEMOP_AMOMINU: r = (a_u < b_u) ? old_raw : src;
      LSU_MEMOP_AMOMAXU: r = (a_u > b_u) ? old_raw : src;
      default:           r = src;
    endcase
    return r;
  endfunction

  // tree-PLRU (4 ways, 3 bits): b[0] root, b[1] covers way0/1, b[2] covers way2/3; bit=1 means right side is older
  function automatic logic [2:0] plru_touch(input logic [2:0] b, input logic [WAY_W-1:0] w);
    logic [2:0] n;
    n = b;
    if (w[1] == 1'b0) begin n[0] = 1'b1; n[1] = ~w[0]; end
    else              begin n[0] = 1'b0; n[2] = ~w[0]; end
    return n;
  endfunction

  function automatic logic [WAY_W-1:0] plru_victim(input logic [2:0] b);
    return b[0] ? {1'b1, b[2]} : {1'b0, b[1]};
  endfunction
endpackage

`endif
