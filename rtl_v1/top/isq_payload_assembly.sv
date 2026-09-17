`ifndef ISQ_PAYLOAD_ASSEMBLY_SV
`define ISQ_PAYLOAD_ASSEMBLY_SV

/* verilator lint_off IMPORTSTAR */
import or_be_types_pkg::*;
/* verilator lint_on IMPORTSTAR */

// isq_payload_assembly -- 集成层.md §2.1「`ISQ_Payload` 装配」的落地。
//
// (1) per-entry state          : none
// (2) state transition         : none
// (3) condition                : none
// (4) data path                : 每个 (slot s, source x) 按 onehot0 的
//                                rs_data_sel_t 选一路源数据；两个候选 slot 各
//                                装配一份完整 ISQ_Payload
// (5) data structure           : none -- 不持有任何状态
//
// 本模块是全库唯一一处「胶水」（§2 的判定：输出不是任何模块的 out-event，
// 且不持有状态）。层级上属顶层：§2.1 说它是唯一允许写在顶层的组合胶水。
// 拆成独立文件只为让 backend_top 保持纯接线（可被「无悬空端口」检查覆盖）、
// 让装配逻辑能独立 lint；它没有自己的微架构文档，**§2.1 就是它的规范**。
//
// 边界纪律，逐条来自 §2.1：
//   * 本层**不做任何 busy / tag 比较**。选择码由 dependency_check 唯一生成，
//     sel_commit 与 sel_bypass 之间的优先级也在那里实现（其 ④#3 step 3 的
//     行 4 先于行 5）。这里只做解码，不复算、不重排。
//   * ARF 的地址索引**已由 ARF 模块自己做完**：INT_ARF 的输出就是 ARF[s][x]、
//     FP_ARF 的是 ARF[x]（§2.5(1) 冻结的形状）。本层只在两者之间二选一，
//     不再拿 rsX_idx / fp_read_idx 去索引。
//   * **唯一一处装配侧覆写**是 full_decode.rm <- dispatch_logic.effective_rm；
//     其余 14 位（csr_write_intent / illegal / csr_addr）原样取自 IB。
//   * 两份 payload **都装配完整**，与哪个 slot 最终被接受无关——
//     accept 的语义在 p1_ISQ_input_mux 的 select_payload 上表达，不在这里。
//
// 没有 clk / rst_n：纯组合、无状态，也不在任何 flush 广播名单上。
module isq_payload_assembly (
    // ------------------------------------------------------------------
    // in: 组合读 -- IB 队头两 slot（§1.1「IB → §2.1 装配」）。
    // §1.1 逐字段列了 imm_valid/imm_data/pc/inst_bits/is_compressed/
    // pred_taken/pred_target_pc/is_store/mem_funct3/rd_is_fp/rs1/2/3_is_fp/
    // exe_subop/full_decode，但它们都装在同一个已冻结的 ib_payload_t 里
    // （§2.2），故端口就是那个 struct，端口名沿用 IB ⑥ 的 head_IB_Payload。
    // ------------------------------------------------------------------
    input  ib_payload_t              head_IB_Payload [ISSUE_WIDTH],
    // 2026-08-26：IB 只存 RAW，译码产物现在从出队侧的 decode 直接进来。
    // 两者同拍同源：dec_info[s] 就是 head_IB_Payload[s] 那条的译码结果。
    input  decoded_info_t            dec_info        [ISSUE_WIDTH],

    // ------------------------------------------------------------------
    // in: 组合读 -- dependency_check（§1.1「dependency_check → §2.1 装配」）。
    // 两个 unpacked 维按 ⑥ 的下标序 [s][x]；x 本身就是源号，x ∈ {1,2,3}，
    // 基是 1、没有 rs0（§2.5(1)）。
    // ------------------------------------------------------------------
    input  logic                     rsX_ready       [ISSUE_WIDTH][1:FP_READ_PORTS],
    input  logic [TAG_W-1:0]         rsX_wait_tag    [ISSUE_WIDTH][1:FP_READ_PORTS],
    input  logic [RS_DATA_SEL_W-1:0] rs_data_sel_t   [ISSUE_WIDTH][1:FP_READ_PORTS],
    input  logic [TAG_W-1:0]         self_tag        [ISSUE_WIDTH],

    // ------------------------------------------------------------------
    // in: 组合读 -- 两份同义的 ARF 读出。同名信号 `ARF` 来自两个不同模块、
    // 同拍可同时有效、物理上不能合并，按 §2.5(5) 加 INT_ / FP_ 前缀区分。
    // 形状与各自 ⑥ 逐格对应：INT 是 (s,x) 四口、FP 是无 slot 维的三口。
    // ------------------------------------------------------------------
    input  logic [XLEN-1:0]          INT_ARF         [ISSUE_WIDTH][1:INT_SRC_PER_SLOT],
    input  logic [XLEN-1:0]          FP_ARF          [1:FP_READ_PORTS],

    // ------------------------------------------------------------------
    // in: 组合读 -- Buffer 的两个队头读出（commit lane 0/1，无压缩，
    // lane c 恒为 head c）。只取数据：命中判定已在 dependency_check。
    // ------------------------------------------------------------------
    input  logic [XLEN-1:0]          commit_data     [ISSUE_WIDTH],

    // ------------------------------------------------------------------
    // in-event: bypass_publish（announce, 4 lane）。四条 lane 由顶层从
    // p3_arbiter_G0/G1 与 G2/G3 的 completion 聚合而来。同样只取数据，
    // bypass_valid / bypass_tag 不进本层。
    // ------------------------------------------------------------------
    input  logic [XLEN-1:0]          bypass_data     [NUM_LANES],

    // ------------------------------------------------------------------
    // in: 组合读 -- dispatch_logic（§1.1「dispatch_logic → §2.1 装配」）。
    // slot_FU_Group 是组内 FU 下标，不是组号；effective_rm 覆盖 payload 的
    // rm 三位，只有 G2 消费。
    // ------------------------------------------------------------------
    input  logic [FU_GROUP_W-1:0]    slot_FU_Group   [ISSUE_WIDTH],
    input  rm_e                      effective_rm    [ISSUE_WIDTH],

    // ------------------------------------------------------------------
    // out: 组合读 -> 4 个 p1_ISQ_input_mux（端口名沿用其 ⑥ 的 slot_payload）
    // ------------------------------------------------------------------
    output isq_payload_t             slot_payload    [ISSUE_WIDTH]
);

    // ------------------------------------------------------------------
    // 源号：下标本身，基是 1（§2.5(1)）。x ∈ {1,2} 有 INT 读口，
    // x ∈ {1,2,3} 有 FP 读口。
    // ------------------------------------------------------------------
    localparam int RS1 = 1;
    localparam int RS2 = 2;
    localparam int RS3 = 3;

    // ------------------------------------------------------------------
    // rs_data_sel_t 的位序，由 §2.5(2) 冻结：
    //
    //     [6]    sel_arf
    //     [5:4]  sel_commit[1:0]      bit4 = commit lane 0
    //     [3:0]  sel_bypass[3:0]      bit0 = bypass lane 0
    //
    // 即 {sel_arf, sel_commit[1:0], sel_bypass[3:0]} 的 MSB→LSB 直读，
    // 两个子域内部都是低位对低编号 lane。位置从 lane 重数导出，不写字面量：
    // commit 侧是 ISSUE_WIDTH 条、bypass 侧是 NUM_LANES 条，与
    // dependency_check 生成侧的推导逐字相同。
    // ------------------------------------------------------------------
    localparam int SEL_BYPASS_LSB = 0;
    localparam int SEL_BYPASS_MSB = NUM_LANES - 1;                  // [3:0]
    localparam int SEL_COMMIT_LSB = NUM_LANES;
    localparam int SEL_COMMIT_MSB = NUM_LANES + ISSUE_WIDTH - 1;    // [5:4]
    localparam int SEL_ARF_BIT    = NUM_LANES + ISSUE_WIDTH;        // [6]

    // sel_arf 必须落在最高位上，否则本层与生成侧对不上而静默取错 lane。
    if (SEL_ARF_BIT != RS_DATA_SEL_W - 1) begin : gen_chk_sel_layout
        $error("rs_data_sel_t layout: sel_arf at bit %0d but RS_DATA_SEL_W is %0d",
               SEL_ARF_BIT, RS_DATA_SEL_W);
    end

    // ------------------------------------------------------------------
    // 解码后的三个子域，逐 (s,x) 一份。
    // ------------------------------------------------------------------
    logic                       sel_arf    [ISSUE_WIDTH][1:FP_READ_PORTS];
    logic [ISSUE_WIDTH-1:0]     sel_commit [ISSUE_WIDTH][1:FP_READ_PORTS];
    logic [NUM_LANES-1:0]       sel_bypass [ISSUE_WIDTH][1:FP_READ_PORTS];

    always_comb begin
        for (int unsigned s = 0; s < ISSUE_WIDTH; s++) begin
            for (int unsigned x = 1; x <= FP_READ_PORTS; x++) begin
                sel_arf   [s][x] = rs_data_sel_t[s][x][SEL_ARF_BIT];
                sel_commit[s][x] = rs_data_sel_t[s][x][SEL_COMMIT_MSB:SEL_COMMIT_LSB];
                sel_bypass[s][x] = rs_data_sel_t[s][x][SEL_BYPASS_MSB:SEL_BYPASS_LSB];
            end
        end
    end

    // ------------------------------------------------------------------
    // (4)#1 sel_arf 那一路：rsX_is_fp[s] ? FP_ARF[x] : INT_ARF[s][x]
    //
    // 地址侧已经做完了——两个 ARF 送来的就是各自读口的读出值，本层只在
    // 「同一个源号的 INT 读出」与「同一个源号的 FP 读出」之间二选一。
    // FP 侧不带 slot 维度是 §2.5(1) 冻结的形状：三个 FP 读地址已经属于
    // FP_read_address_mux 选中的那一个 slot，故 rsX_is_fp[s] 成立时
    // 下标 x 的那口就是 slot s 的值。
    //
    // x = 3 只走 FP：rs3 永不选 INT_ARF（上游契约 use_rs3[s] ⇒ rs3_is_fp[s]），
    // INT_ARF 也只有 x ∈ {1,2} 两口，压根没有可选的第二路。契约万一被破坏，
    // 这里给出的仍是 FP 读出而不是越界索引——本层不做二次判定。
    // ------------------------------------------------------------------
    logic rs_is_fp [ISSUE_WIDTH][1:INT_SRC_PER_SLOT];

    always_comb begin
        for (int unsigned s = 0; s < ISSUE_WIDTH; s++) begin
            rs_is_fp[s][RS1] = dec_info[s].rs1_is_fp;
            rs_is_fp[s][RS2] = dec_info[s].rs2_is_fp;
        end
    end

    logic [XLEN-1:0] arf_data [ISSUE_WIDTH][1:FP_READ_PORTS];

    always_comb begin
        for (int unsigned s = 0; s < ISSUE_WIDTH; s++) begin
            for (int unsigned x = 1; x <= INT_SRC_PER_SLOT; x++) begin
                arf_data[s][x] = rs_is_fp[s][x] ? FP_ARF[x] : INT_ARF[s][x];
            end
            for (int unsigned x = INT_SRC_PER_SLOT + 1; x <= FP_READ_PORTS; x++) begin
                arf_data[s][x] = FP_ARF[x];
            end
        end
    end

    // ------------------------------------------------------------------
    // (4)#2 rsX_data[s][x] -- onehot0 选择
    //
    //     sel_arf       -> arf_data[s][x]
    //     sel_commit[c] -> commit_data[c]
    //     sel_bypass[b] -> bypass_data[b]
    //     全零          -> 0（本拍不采样该源）
    //
    // 写成与顺序无关的 AND-OR 选择，而不是 if/else 优先链：优先级已经由
    // dependency_check 决定完了（§2.1「本层不做任何 busy / tag 比较」），
    // 这里再写一条链就是把同一个判据实现两遍。选择码严格 onehot0 由
    // §2.5(3)（同 tag 多 lane 命中取编号最低）保证。
    // ------------------------------------------------------------------
    logic [XLEN-1:0] rsX_data [ISSUE_WIDTH][1:FP_READ_PORTS];

    always_comb begin
        for (int unsigned s = 0; s < ISSUE_WIDTH; s++) begin
            for (int unsigned x = 1; x <= FP_READ_PORTS; x++) begin
                rsX_data[s][x] = sel_arf[s][x] ? arf_data[s][x] : '0;
                for (int unsigned c = 0; c < ISSUE_WIDTH; c++) begin
                    rsX_data[s][x] |= sel_commit[s][x][c] ? commit_data[c] : '0;
                end
                for (int unsigned b = 0; b < NUM_LANES; b++) begin
                    rsX_data[s][x] |= sel_bypass[s][x][b] ? bypass_data[b] : '0;
                end
            end
        end
    end

    // ------------------------------------------------------------------
    // (4)#3 唯一一处装配侧覆写：full_decode.rm <- effective_rm[s]
    //
    // 其余 14 位（[16] csr_write_intent / [15] illegal / [11:0] csr_addr）
    // 原样取自 IB。逐字段写、不做整体拷贝再打补丁，是为了让「只覆写这三位」
    // 在代码里一眼可数；具名 assignment pattern 还会在 elaboration 强制
    // 覆盖 full_decode_t 的每个成员。
    // effective_rm = (rm == DYN) ? frm : rm 在派遣拍定格，只有 G2 消费；
    // 覆写的理由见 dispatch_logic微架构文档 ④#1，本层不重复。
    // ------------------------------------------------------------------
    full_decode_t payload_full_decode [ISSUE_WIDTH];

    always_comb begin
        for (int unsigned s = 0; s < ISSUE_WIDTH; s++) begin
            payload_full_decode[s] = '{
                csr_write_intent : dec_info[s].full_decode.csr_write_intent,
                illegal          : dec_info[s].full_decode.illegal,
                rm               : effective_rm[s],
                csr_addr         : dec_info[s].full_decode.csr_addr
            };
        end
    end

    // ------------------------------------------------------------------
    // (4)#4 两份完整 payload
    //
    // §2.1 的 schema 表逐行落在下面，一个字段不漏。用具名 assignment
    // pattern 而不是逐字段赋值：SV 要求具名 pattern 覆盖 struct 的每个成员，
    // 少填一个是 elaboration 错误，不会变成静默的 0。
    //
    // 两份都无条件装满，与 accept / select_payload 无关——本层没有「哪个
    // slot 被接受」这个信息，也不需要。
    //
    // 不进 payload 的（§2.1）：slot_ISQGroup（已译码成 select_payload，
    // mux 实例本身即代表目标组）、rd_idx / use_rd / rd_write_enable
    // （回写按 tag_out 寻址，目的寄存器信息在 alloc 拍已进 SCB）。
    // req_property 也不进，它在 G3 issue 边界由 exe_subop 组合生成。
    // ------------------------------------------------------------------
    always_comb begin
        for (int unsigned s = 0; s < ISSUE_WIDTH; s++) begin
            slot_payload[s] = '{
                // operands -- 数据本节选出，ready / wait_tag 来自 dependency_check
                rs1_data       : rsX_data    [s][RS1],
                rs2_data       : rsX_data    [s][RS2],
                rs3_data       : rsX_data    [s][RS3],
                rs1_ready      : rsX_ready   [s][RS1],
                rs2_ready      : rsX_ready   [s][RS2],
                rs3_ready      : rsX_ready   [s][RS3],
                rs1_wait_tag   : rsX_wait_tag[s][RS1],
                rs2_wait_tag   : rsX_wait_tag[s][RS2],
                rs3_wait_tag   : rsX_wait_tag[s][RS3],
                // routing
                self_tag       : self_tag[s],
                fu_group       : slot_FU_Group[s],
                // immediate -- imm_data 已由 decode 完成符号扩展
                imm_valid      : dec_info[s].imm_valid,
                imm_data       : dec_info[s].imm_data,
                // instruction identity + prediction
                pc             : head_IB_Payload[s].pc,
                // IB 存的就是 RAW，直读即可。非法指令的 mtval 必须是
                // **程序里真实存在的那个编码**，展开结果不是程序里的东西。
                inst_bits      : head_IB_Payload[s].inst_bits,
                is_compressed  : head_IB_Payload[s].is_compressed,
                pred_taken     : head_IB_Payload[s].pred_taken,
                pred_target_pc : head_IB_Payload[s].pred_target_pc,
                // memory sideband -- rd_is_fp 只为 G3 区分同宽度的整数与 FP load
                is_store       : dec_info[s].is_store,
                mem_funct3     : dec_info[s].mem_funct3,
                rd_is_fp       : dec_info[s].rd_is_fp,
                // decode results -- full_decode 的 rm 三位已被覆写
                exe_subop      : dec_info[s].exe_subop,
                full_decode    : payload_full_decode[s],
                // 取指异常 —— 原样透传。decode 已经把这条强制成 ILLEGAL 的
                // 形状（G0/ALU0、无源、无目的），本层不需要再判一次。
                fetch_excp_vld   : head_IB_Payload[s].fetch_excp_vld,
                fetch_excp_cause : head_IB_Payload[s].fetch_excp_cause,
                fetch_excp_tval  : head_IB_Payload[s].fetch_excp_tval
            };
        end
    end

endmodule

`endif // ISQ_PAYLOAD_ASSEMBLY_SV
