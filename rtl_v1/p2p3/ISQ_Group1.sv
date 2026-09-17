`ifndef ISQ_GROUP1_SV
`define ISQ_GROUP1_SV

/* verilator lint_off IMPORTSTAR */
import or_be_types_pkg::*;
/* verilator lint_on IMPORTSTAR */

// ISQ_Group1 -- ALU1 + MUL issue queue, one entry (ISQ_Group1微架构文档).
//
// (1) per-entry state          : FREE / RESIDENT, carried by `isq_valid` alone;
//                                one entry, therefore no pointers
// (2) state transition         : dispatch / bypass_capture / issue / flush
// (3) condition                : flush > dispatch > issue > bypass_capture
// (4) data path                : payload capture at dispatch, per-source
//                                bypass capture, whole-payload issue
// (5) data structure           : state + header (ready / wait_tag / FU_Group)
//                                + payload (rsX_data, imm, self_tag, exe_subop)
//
// 组内 FU 索引 (⑥ 开头)：FU_Group = 0 是 ALU1，= 1 是 MUL。索引原样发射，
// 由 FU 自译；本模块只拿它选 `FU_ready`。
//
// 本组只有两个源。`rs3_*` 以及指令身份 / 分支预测 / 访存 / full_decode 字段
// 在 `payload_in` 上存在但**本组不捕获**（⑤「本组不存的字段」）——它们悬空是
// 有意的，不是漏接。
//
// 每个源在 issue 端口上的「entry 存的数据 vs 本拍 bypass 前递」二选一不在此
// 内联，而是例化内部子块 `FU_input_mux`（rs1 / rs2 各一份）。本模块仍自己算
// `fast_ready_rsX`——③ 的 issue 判据需要它——子块只拿数据做选择。
module ISQ_Group1 (
    input  logic                    clk,
    input  logic                    rst_n,

    // in-event: dispatch (Transaction, 单向选通, 1 写口)
    // ready 侧就是下面的 `isq_free_for_dispatch`，已被上游吸收。
    input  logic                    wr_en,
    input  isq_payload_t            payload_in,

    // in-event: bypass_capture (announce, 4 lane 全监听——bypass 是全局广播)
    input  logic                    bypass_valid [NUM_LANES],
    input  logic [TAG_W-1:0]        bypass_tag   [NUM_LANES],
    input  logic [XLEN-1:0]         bypass_data  [NUM_LANES],

    // in-event: flush (announce, 单线脉冲, 无载荷)
    input  logic                    global_flush_late,

    // in-event: 组合读 -- 组内每个 requester 一位，FU_Group ∈ {0,1}
    input  logic                    FU_ready [G1_NUM_FU],

    // out-event: issue -- 送往库外的 FU
    output logic                    issue_valid,
    output logic [XLEN-1:0]         rs1_data,
    output logic [XLEN-1:0]         rs2_data,
    output logic [FU_GROUP_W-1:0]   FU_Group,
    output logic                    imm_valid,
    output logic [XLEN-1:0]         imm_data,
    output logic [TAG_W-1:0]        self_tag,
    output logic [EXE_SUBOP_W-1:0]  exe_subop,

    // Static Info
    output logic                    isq_free_for_dispatch
);

    // ------------------------------------------------------------------
    // ⑥ 的组内 FU 索引。只有两个 requester，所以 `FU_ready` 是 2:1 选择，
    // 不是 FU_GROUP_W 位的全译码。
    // ------------------------------------------------------------------
    localparam logic [FU_GROUP_W-1:0] FU_GROUP_ALU1 = FU_GROUP_W'(0);
    localparam logic [FU_GROUP_W-1:0] FU_GROUP_MUL  = FU_GROUP_W'(1);

    // ------------------------------------------------------------------
    // (5) entry -- state + header + payload
    //
    // 端口已占用 ⑤ 的字段名（issue 侧原样外送），存储侧统一加 `ent_` 前缀；
    // `isq_valid` 不加前缀，⑤ 就是这么叫的，且没有同名端口。
    // ------------------------------------------------------------------
    logic                    isq_valid;          // state: 0 = FREE, 1 = RESIDENT

    logic                    ent_rs1_ready;      // header
    logic                    ent_rs2_ready;
    logic [TAG_W-1:0]        ent_rs1_wait_tag;
    logic [TAG_W-1:0]        ent_rs2_wait_tag;
    logic [FU_GROUP_W-1:0]   ent_fu_group;

    logic [XLEN-1:0]         ent_rs1_data;       // payload
    logic [XLEN-1:0]         ent_rs2_data;
    logic                    ent_imm_valid;
    logic [XLEN-1:0]         ent_imm_data;
    logic [TAG_W-1:0]        ent_self_tag;
    logic [EXE_SUBOP_W-1:0]  ent_exe_subop;

    // ------------------------------------------------------------------
    // (3) fast_ready_rsX
    //
    //     fast_ready_rsX = !rsX_ready ∧ OR over b∈{0..3}
    //                      (bypass_valid[b] ∧ rsX_wait_tag == bypass_tag[b])
    //
    // 四条 lane 全比。多条 lane 同拍命中同一 tag 时哪条赢，与本判据无关——
    // 它只要「有没有命中」；取哪条的 data 由 `FU_input_mux` 按集成层 §2.5(3)
    // 的「取编号最低的那条」决定。
    // ------------------------------------------------------------------
    logic bypass_hit_rs1;
    logic bypass_hit_rs2;
    logic fast_ready_rs1;
    logic fast_ready_rs2;

    always_comb begin
        bypass_hit_rs1 = 1'b0;
        bypass_hit_rs2 = 1'b0;
        for (int unsigned b = 0; b < NUM_LANES; b++) begin
            if (bypass_valid[b] && (ent_rs1_wait_tag == bypass_tag[b])) begin
                bypass_hit_rs1 = 1'b1;
            end
            if (bypass_valid[b] && (ent_rs2_wait_tag == bypass_tag[b])) begin
                bypass_hit_rs2 = 1'b1;
            end
        end
    end

    assign fast_ready_rs1 = !ent_rs1_ready && bypass_hit_rs1;
    assign fast_ready_rs2 = !ent_rs2_ready && bypass_hit_rs2;

    // ------------------------------------------------------------------
    // (3) issue
    //
    //     operand_ready = (rs1_ready ∨ fast_ready_rs1)
    //                   ∧ (rs2_ready ∨ fast_ready_rs2)      // 本组不用 rs3
    //     issue_req     = isq_valid ∧ operand_ready         // ③ 的 `issue_valid`
    //     issue         = issue_req ∧ FU_ready[FU_Group] ∧ !global_flush_late
    //
    // 名字撞车提示：③ 把 `isq_valid ∧ operand_ready` 叫 `issue_valid`，而 ④ 把
    // 对外那根登记成「`issue_valid` ← ③ 的 issue 判据」。对外端口取 ④ 的定义
    // （即完整的 `issue`），③ 的中间量在本文件里叫 `issue_req`，不外送。
    //
    // `FU_ready` 进 issue 判据是组合的，所以 FU 侧的 ready 不得反过来依赖本模块
    // 的 `issue_valid`（③ 的 FU_ready 契约：ALU1 恒 ready，MUL 只看自己的
    // output hold 与 P3 组内仲裁结果）。
    // ------------------------------------------------------------------
    logic operand_ready;
    logic fu_ready_sel;
    logic issue_req;
    logic issue_fire;
    logic bypass_capture;

    assign operand_ready = (ent_rs1_ready || fast_ready_rs1)
                        && (ent_rs2_ready || fast_ready_rs2);

    assign issue_req = isq_valid && operand_ready;

    always_comb begin
        // ③「`FU_ready[FU_Group]` 是按组内索引取用」。⑤ 冻结 FU_Group 取值
        // {0,1}，组内也只有两个 requester，故为 2:1。
        if (ent_fu_group == FU_GROUP_MUL) begin
            fu_ready_sel = FU_ready[1];
        end else begin
            fu_ready_sel = FU_ready[0];
        end
    end

    // ⑥ §issue：`issue_valid` 是**请求线不是 fire 线**——不含 FU_ready。
    // valid 含 ready 即耦合：ready 一掉 valid 就掉，「valid 一经拉高保持稳定
    // 到握手成功」当场被破坏，且 FU_ready 也不得反过来依赖 valid（成环）。
    // entry 的释放是 issue_fire = issue_valid ∧ FU_ready，即 ③ 的 `issue`。
    assign issue_valid = issue_req && !global_flush_late;
    assign issue_fire  = issue_valid && fu_ready_sel;

    // ------------------------------------------------------------------
    // (3) bypass_capture
    //
    //     bypass_capture = isq_valid ∧ !global_flush_late ∧ !issue
    //                    ∧ (fast_ready_rs1 ∨ fast_ready_rs2)
    //
    // 同拍 issue 时不捕获，只向 FU 前递（前递路径就是下面的 FU_input_mux）。
    // ------------------------------------------------------------------
    assign bypass_capture = isq_valid && !global_flush_late && !issue_fire
                         && (fast_ready_rs1 || fast_ready_rs2);

    // ------------------------------------------------------------------
    // (3) 采样约定：对外的空闲投影，含同拍 issue
    //
    //     isq_free_for_dispatch = !isq_valid ∨ issue
    //
    // 逐字照 ③。flush 拍不另做投影：flush 拍上游本就不 dispatch。
    // ------------------------------------------------------------------
    assign isq_free_for_dispatch = !isq_valid || issue_fire;

    // ------------------------------------------------------------------
    // (4)#1 issue 侧的每源二选一 -- 内部子块，每源一份
    //
    //   rsX_ready              → entry 里存的 rsX_data
    //   !rsX_ready ∧ 命中 lane → bypass_data[b]，绕过 entry 直接前递
    //
    // 这条前递值同时是 bypass_capture 的写数据源：capture 命中时写进 entry 的
    // 就是同一个 bypass_data[b]，所以不另写一份选择逻辑。
    // ------------------------------------------------------------------
    logic [XLEN-1:0] fu_rs1_data;
    logic [XLEN-1:0] fu_rs2_data;

    FU_input_mux u_fu_input_mux_rs1 (
        .entry_rsX_data (ent_rs1_data),
        .bypass_data    (bypass_data),
        .bypass_valid   (bypass_valid),
        .bypass_tag     (bypass_tag),
        .rsX_wait_tag   (ent_rs1_wait_tag),
        .rsX_ready      (ent_rs1_ready),
        .fu_rsX_data    (fu_rs1_data)
    );

    FU_input_mux u_fu_input_mux_rs2 (
        .entry_rsX_data (ent_rs2_data),
        .bypass_data    (bypass_data),
        .bypass_valid   (bypass_valid),
        .bypass_tag     (bypass_tag),
        .rsX_wait_tag   (ent_rs2_wait_tag),
        .rsX_ready      (ent_rs2_ready),
        .fu_rsX_data    (fu_rs2_data)
    );

    // ------------------------------------------------------------------
    // (4)#1 entry -> issue 输出端口
    //
    // 除源数据外的全部 payload 字段原样外送，不按 issue_valid 选通：
    // ④ 只登记了「entry → issue 输出端口」，没有登记清零，交付由 issue_valid
    // 定界。`exe_subop` 原样发射，不在本模块译码。
    // ------------------------------------------------------------------
    assign rs1_data  = fu_rs1_data;
    assign rs2_data  = fu_rs2_data;
    assign FU_Group  = ent_fu_group;
    assign imm_valid = ent_imm_valid;
    assign imm_data  = ent_imm_data;
    assign self_tag  = ent_self_tag;
    assign exe_subop = ent_exe_subop;

    // ------------------------------------------------------------------
    // (2) 状态与 entry 的更新
    //
    //   flush           isq_valid ← 0；本拍不 dispatch、不 issue、不 capture
    //   dispatch        isq_valid ← 1，⑤ 列出的全部字段 ← payload_in
    //                   （同拍 issue 时仍是 dispatch 赢：RESIDENT → RESIDENT）
    //   issue           本拍无 dispatch 时 isq_valid ← 0
    //   bypass_capture  只置 rsX_ready 与 rsX_data，rsX_wait_tag 不改——
    //                   改了下一拍会拿新 tag 重新匹配
    //
    // dispatch 排在 bypass_capture 之前：dispatch 整条覆盖 entry，此时本拍对
    // 旧 entry 的 capture 已无意义；新 payload 的同拍 bypass 由集成层 §2.1 的
    // 装配（rs_data_sel_t 的 sel_bypass）在入口处就并进 payload_in 了。
    // ------------------------------------------------------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            isq_valid        <= 1'b0;
            ent_rs1_ready    <= 1'b0;
            ent_rs2_ready    <= 1'b0;
            ent_rs1_wait_tag <= '0;
            ent_rs2_wait_tag <= '0;
            ent_fu_group     <= FU_GROUP_ALU1;
            ent_rs1_data     <= '0;
            ent_rs2_data     <= '0;
            ent_imm_valid    <= 1'b0;
            ent_imm_data     <= '0;
            ent_self_tag     <= '0;
            ent_exe_subop    <= '0;
        end else if (global_flush_late) begin
            // ③ flush 优先级最高，无载荷：只清 state，payload 留着不看。
            isq_valid        <= 1'b0;
        end else if (wr_en) begin
            // ④「dispatch 输入端口 → entry」：只捕获 ⑤ 列出的字段，其余丢弃。
            isq_valid        <= 1'b1;
            ent_rs1_ready    <= payload_in.rs1_ready;
            ent_rs2_ready    <= payload_in.rs2_ready;
            ent_rs1_wait_tag <= payload_in.rs1_wait_tag;
            ent_rs2_wait_tag <= payload_in.rs2_wait_tag;
            ent_fu_group     <= payload_in.fu_group;
            ent_rs1_data     <= payload_in.rs1_data;
            ent_rs2_data     <= payload_in.rs2_data;
            ent_imm_valid    <= payload_in.imm_valid;
            ent_imm_data     <= payload_in.imm_data;
            ent_self_tag     <= payload_in.self_tag;
            ent_exe_subop    <= payload_in.exe_subop;
        end else if (issue_fire) begin
            isq_valid        <= 1'b0;
        end else if (bypass_capture) begin
            if (fast_ready_rs1) begin
                ent_rs1_ready <= 1'b1;
                ent_rs1_data  <= fu_rs1_data;
            end
            if (fast_ready_rs2) begin
                ent_rs2_ready <= 1'b1;
                ent_rs2_data  <= fu_rs2_data;
            end
        end
    end

endmodule

`endif // ISQ_GROUP1_SV
