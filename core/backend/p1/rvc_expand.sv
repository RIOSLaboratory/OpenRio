`ifndef RVC_EXPAND_SV
`define RVC_EXPAND_SV

/* verilator lint_off IMPORTSTAR */
import or_be_types_pkg::*;
/* verilator lint_on IMPORTSTAR */

// rvc_expand -- 出队侧译码链的第一块：原始编码 -> 规范 32 位形态。
//
// (1) 责任        : 把 IB 队头的原始编码化成规范的 32 位形态，并把「这条压缩
//                   编码本身是否非法」判出来。此外什么都不做——不分类、不生成
//                   立即数、不判路由，那些是 decode 的事。
// (2) 状态        : 无。纯组合，不加流水级。
// (3) 条件        : 无。不产生任何 fire 判据。
// (4) 数据通路    : 每 lane 一次 `riscv_rvc_pkg::rvc_decompress_rv64`。
//
// -------------------------------------------------------------------------
// **为什么它在 IB 之后，而不是之前**
// -------------------------------------------------------------------------
// 2026-08-26 的实测结论：**取指拍（FE 的 flop -> IB 的 flop）连一块 RVC 展开
// 都放不下。** 所以 FE -> IB 必须是纯连线，任何与译码相关的逻辑——包括这一块——
// 都只能在 IB 之后。这否掉了「入队侧展开一次、把 inst32 存进 IB」那个形态
// （P1译码位置重构分析.md 的 B2），落地的是形态 A。
//
// -------------------------------------------------------------------------
// **本模块的输出怎么同时喂两条并行分支**
// -------------------------------------------------------------------------
// 出队那一拍有两条分支，共用**同一个**本模块实例：
//
//   地址支  inst32 的 20 位固定切片 -> rs1/rs2/rs3/rd -> ARF / tag_mapping 读
//   译码支  inst32 整条            -> decode -> decoded_info_t
//
// 关键在于**地址支只读 20 位**：`inst32[19:15]` / `[24:20]` / `[31:27]` / `[11:7]`。
// 喂这 20 位的逻辑锥就是下面 case 树里的**寄存器选择 mux**（浅），而立即数拼接与
// opcode 生成那些深锥不在这条路径上，综合会把它们从这条路径剪掉。
//
// 所以：
//   * **不需要手写第二份「RVC 寄存器号提取器」**——那会是同一件事的两份实现，
//     读错一个寄存器号没有任何东西能抓到。这里一份实现、一个实例，两条分支各取所需。
//   * 地址支的延迟 ≈ 寄存器选择 mux 树，不是整个展开器，更不是展开器 + 全译码。
module rvc_expand (
    // ---------------------------------------------------------------------
    // in-event: broadcast -- IB 队头的原始编码，per lane n in {0,1}
    // ---------------------------------------------------------------------
    // `ib_inst_bits` 是 FE 送来的 RAW 形态：压缩指令为 `{16'b0, 原始半字}`。
    input  logic [31:0] ib_inst_bits     [ISSUE_WIDTH],
    input  logic        ib_is_compressed [ISSUE_WIDTH],

    // ---------------------------------------------------------------------
    // out: combinational reads
    // ---------------------------------------------------------------------
    // 规范 32 位形态。非压缩时就是入参本身。
    output logic [31:0] inst32           [ISSUE_WIDTH],
    // 这 16 位不是任何一条合法的压缩编码（展开器的 valid 为 0）。
    output logic        rvc_illegal      [ISSUE_WIDTH]
);

    generate
        for (genvar n = 0; n < ISSUE_WIDTH; n++) begin : gen_lane
            logic [31:0] expanded;
            bit          rvc_ok;

            always_comb begin
                // 展开器对非压缩输入没有意义，所以只在压缩时取它的结果；
                // 非压缩时 FE 送的就已经是规范的 32 位形态。
                expanded  = riscv_rvc_pkg::rvc_decompress_rv64(
                                ib_inst_bits[n][15:0], rvc_ok);
                inst32[n] = ib_is_compressed[n] ? expanded : ib_inst_bits[n];

                // 例：C.ADDI4SPN 的 c[12:5] == 0 是保留编码。
                // decode 的 ④#6 用它当 `ill_rvc`。
                rvc_illegal[n] = ib_is_compressed[n] && !rvc_ok;
            end
        end
    endgenerate

endmodule

`endif // RVC_EXPAND_SV
