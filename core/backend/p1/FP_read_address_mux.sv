`ifndef FP_READ_ADDRESS_MUX_SV
`define FP_READ_ADDRESS_MUX_SV

/* verilator lint_off IMPORTSTAR */
import or_be_types_pkg::*;
/* verilator lint_on IMPORTSTAR */

// FP_read_address_mux -- pure combinational 6 candidate addresses -> 3 FP read
// ports (FP_read_address_mux微架构文档).
//
// (1) per-entry state          : none
// (2) state transition         : none
// (3) condition                : none
// (4) data path                : one 2:1 select per source index k in {1,2,3},
//                                all three driven by a single select bit
// (5) data structure           : none -- no per-entry storage
//
// The two candidate slots offer six possible FP source addresses
// (slot0/1.rs1/2/3_idx) while the FP side has only three read ports.  This
// module does that narrowing; its output drives the read address port of
// **both** FP_ARF and FP_tag_mapping (集成层 §1.1).
//
// No clock and no reset on purpose: ①②③ are all "none", so the module holds no
// state and is not on any flush broadcast list.
module FP_read_address_mux (
    // in-event: broadcast -- the six candidate addresses from IB.  The doc
    // writes them as `slot0/1.rs1/2/3_idx`(5x6); the source number is the port
    // name and the slot is the unpacked index (0 = slot0, 1 = slot1), so the
    // width annotation stays per-port and nothing is packed together.
    input  logic [REG_ADDR_W-1:0] rs1_idx     [ISSUE_WIDTH],
    input  logic [REG_ADDR_W-1:0] rs2_idx     [ISSUE_WIDTH],
    input  logic [REG_ADDR_W-1:0] rs3_idx     [ISSUE_WIDTH],

    // in-event: select -- `is_fp_opcode[0]`(1), slot0's bit and nothing else.
    // ④ is explicit that slot1's bit does not participate, so slot1's copy is
    // not a port here: there is no second wire to ignore.
    //
    // **不门控的 opcode 判据，不是 decode 的 `is_fp_instruction`。**
    // 两者的差别与为什么必须用前者，见 ④#1 的证明。
    input  logic                  is_fp_opcode,

    // out-event: `fp_read_idx[1:3]`(5x3, read addresses).  Numbered 1..3 to
    // match the source number x used by ④ and by 集成层 §2.1; or_be_types_pkg
    // has no constant for this multiplicity, so the range is the documented
    // one, exactly as FP_ARF declares its matching port.
    output logic [REG_ADDR_W-1:0] fp_read_idx [1:3]
);

    // Unpacked slot index of the six candidate addresses.
    localparam int SLOT0 = 0;
    localparam int SLOT1 = 1;

    // ------------------------------------------------------------------
    // (4)#1 fp_read_idx[k] = is_fp_opcode[0] ? slot0.rs{k}_idx
    //                                        : slot1.rs{k}_idx , k in {1,2,3}
    //
    // One select bit for all three ports, and it is slot0's bit alone.  The
    // port the FP side reads always belongs to the slot this bit picks:
    //
    //   let the accepted slot s have rsX_is_fp[s] = 1.  A legal FP instruction
    //   necessarily has an F/D opcode, so is_fp_opcode[s] = 1.
    //     s = 0 => select bit = 1                          => slot0 chosen  OK
    //     s = 1 => a double-FP dispatch is blocked on the SAME predicate, so
    //              is_fp_opcode[0] = 0 => select bit = 0    => slot1 chosen  OK
    //
    // The two remaining cases produce no consumer at all: select bit 1 with
    // slot0 not accepted means neither slot was accepted (accept[1] => accept[0]),
    // and both bits 0 means no FP source needs resolving this cycle.  So the
    // addresses driven out are either the right ones or unread -- there is no
    // case that would need a per-slot select, and none that would need a fourth
    // read port.
    //
    // ------------------------------------------------------------------
    // **为什么是 is_fp_opcode 而不是 decode 的 is_fp_instruction**
    // ------------------------------------------------------------------
    // 两个理由，一个正确性、一个时序，指向同一个结论。
    //
    // (a) 正确性：**选择位与双 FP 阻塞必须是同一个谓词。**
    //     `is_fp_instruction` 是门控后的（非法 / 取指故障 ⇒ 0）。若阻塞用它、
    //     选择位用不门控的 opcode 版，两者会在这条缝里分岔：
    //         slot0 = opcode 是 FP 但**非法**的指令，slot1 = 真 FP 指令。
    //     此时 fp0 = 0（门控），双 FP 阻塞放行；两条同拍派遣（slot0 走 G0 的
    //     ILLEGAL 路由、slot1 走 G2，groups_distinct 成立，非法指令不是 serial，
    //     illegal_effective=1 时路由是 ROUTE_BRU 而非 ROUTE_UNSUPPORTED，
    //     所以 subop_supported_now[0] 也成立）。而选择位若用 opcode 版会指向
    //     slot0，**slot1 就读不到自己的 FP 源**。
    //     现在两处都用 is_fp_opcode，耦合恢复，上面的证明才成立。
    //
    // (b) 时序：`is_fp_instruction` 要等 `subop_raw` 与 `d_no_encoding`——那是
    //     整个译码器。用它当选择位，FP 的读地址就排在全译码后面，而 INT 侧的
    //     读地址是 inst32 的固定切片、只等展开器的寄存器选择锥。
    //     `is_fp_opcode` 只吃 inst32[6:0]，是 7 位比对，两侧于是对齐。
    //
    // 代价：阻塞变保守，多挡掉的只有「opcode 像 FP 但马上要 trap」的指令
    // （取指故障 / 非法编码 / ENABLE_FD=0），它后面那条本来就会被 flush。
    // **FS == Off 不在此列**——那是派遣期才知道的，两个谓词在那里一致。
    // ------------------------------------------------------------------
    always_comb begin
        fp_read_idx[1] = is_fp_opcode ? rs1_idx[SLOT0] : rs1_idx[SLOT1];
        fp_read_idx[2] = is_fp_opcode ? rs2_idx[SLOT0] : rs2_idx[SLOT1];
        fp_read_idx[3] = is_fp_opcode ? rs3_idx[SLOT0] : rs3_idx[SLOT1];
    end

endmodule

`endif // FP_READ_ADDRESS_MUX_SV
