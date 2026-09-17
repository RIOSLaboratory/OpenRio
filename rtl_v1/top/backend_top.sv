`ifndef BACKEND_TOP_SV
`define BACKEND_TOP_SV

/* verilator lint_off IMPORTSTAR */
import or_be_lsu_protocol_pkg::*;
import or_be_types_pkg::*;
import fe_be_protocol_pkg::*;
/* verilator lint_on IMPORTSTAR */

// backend_top -- OR-BE 的顶层接线。
//
// **纯接线**：32 个实例按 集成层.md §1 的接线表连起来，不新增任何模块逻辑。
// 本文件里允许出现的组合式内容只有七项胶水，逐项在下面标注：
//
//   胶水#1  head_IB_Payload[s] 的字段提取
//           IB 出的是整条 ib_payload_t，而 dependency_check / dispatch_logic /
//           INT_ARF / INT_tag_mapping / FP_tag_mapping / FP_read_address_mux /
//           CompletionScoreboard / PC_File 收的是散字段（§1.1）。
//   胶水#2  四条完成 lane 的聚合（§1.2）
//           lane0 = p3_arbiter_G0、lane1 = p3_arbiter_G1、lane2 = fpu_simple
//           直连、lane3 = g3_lsu_iface。**每组数组只聚合一次**，然后扇出到
//           Buffer / CompletionScoreboard / dependency_check / 四个 ISQ_Group /
//           isq_payload_assembly——分别聚合两遍就可能让 bypass_data[b] 与
//           bypass_valid[b]/bypass_tag[b] 的 b 错位，而这种错位无工具可查。
//   胶水#3  各 FU 的 completion request 按 **组内 requester 编号** 聚合送仲裁器
//           （G0_FU_ALU/CSR/DIV、G1_FU_ALU/MUL，取自类型包，不写字面量）。
//   胶水#4  isq_free_for_dispatch[NUM_LANES] 与 FU_ready[G*_NUM_FU] 的按组聚合。
//   胶水#5  fe_instr_pld[s] 的字段提取
//   胶水#6  入队 payload 装配（FE 直通字段 + rvc_expand 的三个产物）
//   胶水#7  队头 -> decode 的五根输入
//           与胶水#1 同性质、方向相反：边界上是一条冻结的 fe_be_instr_pld_t，
//           decode 收的是散字段（§1.1）。**提取只在这一处**，且是 struct ->
//           散字段，漏一个字段在这里是编译错误而不是静默丢数。
//
// 顶层端口是**离散信号**，不用 interface：本模块要能综合，fe_if / lsu_if 的
// interface 转接由 S6 的 TB 侧 adapter 做。
//
// 观测面（alloc_* / exec_* / commit_* / trace_pc / global_flush_valid）
// **不新增逻辑**：它们要么直接就是某个实例的输出端口所连的那根网，要么就是
// 胶水#2 聚合出来的那一组数组本身。顶层输出端口在模块内部可读，所以这些网
// 同时也是内部消费者的源——不为观测另起别名，与 §1.4「global_flush_late 只
// 允许一个网络」是同一条纪律。
module backend_top (
    input  logic                        clk,
    input  logic                        rst_n,

    // ==================================================================
    // FE 侧（离散化的 fe_if）。§1.1 的 `FE → decode`、§1.5 的
    // `IB → FE fe_ready` / `flush_model → FE redirect_*` /
    // `G0 的 BRU → FE predictor_update`。
    // fe_valid / fe_ready / accepted_slot 是 packed 2-bit 向量（§2.5(4)）。
    //
    // **握手是普通的 per-lane valid/ready。** FE 在同一个 posedge 上用
    // `fe_valid & fe_ready` 就知道这拍进去了几条，不需要第二根 accept：
    // `accepted_slot` 在 IB 里就是这个与，不是另一个判据（IB ③）。
    //
    // **指令 payload 走一个冻结的 struct，不再是九根平铺端口。**
    // 平铺时它的每一个字段都要在库外的转接层里手工搬一次，而漏搬不报错——
    // fetch-exception 那三个字段就这么被丢过一次（backend_top_wrap §8.10）。
    // schema 见 fe_be_protocol_pkg.sv，与 LSU 侧 be_lsu_issue_pld_t 同一条纪律。
    // ==================================================================
    input  logic [ISSUE_WIDTH-1:0]      fe_valid,
    input  fe_be_instr_pld_t            fe_instr_pld                   [ISSUE_WIDTH],

    output logic [ISSUE_WIDTH-1:0]      fe_ready,
    // 观测面用：本拍实际入队的是哪几条。等于 fe_valid & fe_ready，
    // 不带额外信息，FE 不需要读它。
    output logic [ISSUE_WIDTH-1:0]      accepted_slot,

    output logic                        redirect_valid,
    output logic [XLEN-1:0]             redirect_pc,
    output logic [RECOVERY_KIND_W-1:0]  redirect_kind,
    // §1.5 登记、mock FE 无对端——导出后在 TB 里悬空，不是缺陷。
    output logic                        frontend_icache_invalidate,

    // 同上：§1.5 登记的 predictor_update 五根，mock FE 没有预测器通道。
    output logic                        predictor_update_valid,
    output logic [XLEN-1:0]             predictor_update_branch_pc,
    output logic                        predictor_update_actual_taken,
    output logic [XLEN-1:0]             predictor_update_actual_target,
    output cf_class_e                   predictor_update_cf_class,

    // ==================================================================
    // LSU 侧（离散化的 lsu_if）。全部是 g3_lsu_iface 的对外半边，
    // 加上送 lsu_if 同名线的 global_flush_late。
    // ==================================================================
    output logic                        be_lsu_issue_valid,
    output be_lsu_issue_pld_t           be_lsu_issue_pld,
    output logic                        be_lsu_entry_ready,
    output logic                        be_lsu_store_wakeup_valid,
    output logic                        global_flush_late,

    input  logic                        lsu_be_issue_ready,
    input  logic                        lsu_be_done_valid,
    input  lsu_be_done_pld_t            lsu_be_done_pld,
    input  logic                        lsu_be_exception_valid,
    input  lsu_be_exception_pld_t       lsu_be_exception_pld,
    input  logic                        lsu_be_bypass_valid,
    input  lsu_be_done_pld_t            lsu_be_bypass_pld,

    // ==================================================================
    // 中断。§1.3「顶层 → system_instruction_handler  mip 的外部中断位」，
    // §1.5 记其语义为电平（无 fire、不落盘）。
    // ==================================================================
    input  logic                        mip_meip,
    input  logic                        mip_mtip,
    input  logic                        mip_msip,

    // ==================================================================
    // 观测面（ob_if / cosim）。全部直接引自模块输出或胶水#2 的聚合数组。
    // ==================================================================
    output logic                        alloc_valid                    [ISSUE_WIDTH],
    output logic [TAG_W-1:0]            alloc_tag                      [ISSUE_WIDTH],
    output logic                        exec_valid                     [NUM_LANES],
    output logic [TAG_W-1:0]            exec_tag                       [NUM_LANES],
    output logic                        commit_valid                   [ISSUE_WIDTH],
    output logic [TAG_W-1:0]            commit_tag                     [ISSUE_WIDTH],
    output logic [REG_ADDR_W-1:0]       commit_rd_idx                  [ISSUE_WIDTH],
    output logic                        commit_rd_is_fp                [ISSUE_WIDTH],
    output logic                        commit_rd_write_enable         [ISSUE_WIDTH],
    output logic [FFLAGS_W-1:0]         commit_fflags                  [ISSUE_WIDTH],
    output logic [COMMIT_COUNT_W-1:0]   commit_count,
    output logic [XLEN-1:0]             commit_data                    [ISSUE_WIDTH],
    output logic [XLEN-1:0]             trace_pc                       [ISSUE_WIDTH],
    output logic                        global_flush_valid
);

    // ------------------------------------------------------------------
    // lane / group 下标。§1.2 把四条 lane 的驱动方钉死为 lane0 = p3_arbiter_G0、
    // lane1 = p3_arbiter_G1、lane2 = FPU 直连、lane3 = g3_lsu_iface；
    // ISQ_Group_g 的 g 与 lane 号同值（dispatch_logic 的 GRP_G0..G3 也是 0..3），
    // 所以同一组常量既当 lane 号也当组号。只是可读性命名，没有第二种取值。
    // 组内 requester 编号不在这里另立——用类型包的 G0_FU_* / G1_FU_*。
    // ------------------------------------------------------------------
    localparam int LANE_G0 = 0;
    localparam int LANE_G1 = 1;
    localparam int LANE_G2 = 2;
    localparam int LANE_G3 = 3;

    // ==================================================================
    // 内部网。命名一律 <生产方前缀>_<生产方端口名>；两端不同名是正常的
    // （§2.5(5b)），以各自 ⑥ 为准，由本层接线。
    // ==================================================================

    // ---- 胶水#6 的产物：入队 payload（**纯连线**）-------------------
    ib_payload_t                    enq_IB_Payload            [ISSUE_WIDTH];

    // ---- rvc_expand（**在 IB 之后**，出队侧译码链的第一块）---------
    logic [31:0]                    rvce_inst32               [ISSUE_WIDTH];
    logic                           rvce_rvc_illegal          [ISSUE_WIDTH];

    // ---- IB -----------------------------------------------------------
    ib_payload_t                    head_IB_Payload           [ISSUE_WIDTH];
    logic [ISSUE_WIDTH-1:0]         ib_inst_valid;

    // ---- decode（2026-08-26 起在 IB **之后**）--------------------------
    decoded_info_t                  dec_info                  [ISSUE_WIDTH];
    logic                           dec_is_fp_opcode          [ISSUE_WIDTH];

    // ---- 胶水#1 的产物：队头 RAW 字段 + 出队侧译码产物的散字段 --------
    logic [REG_ADDR_W-1:0]          ib_rd_idx                 [ISSUE_WIDTH];
    logic                           ib_rd_is_fp               [ISSUE_WIDTH];
    logic                           ib_use_rd                 [ISSUE_WIDTH];
    logic                           ib_is_serial              [ISSUE_WIDTH];
    // **门控版**：喂 dispatch_logic 的 fp_illegal（架构判定，必须门控）。
    logic                           ib_is_fp_instruction      [ISSUE_WIDTH];
    // **不门控版**：喂 dependency_check 的 fp0/fp1（双 FP 阻塞）与
    // FP_read_address_mux 的选择位。两处必须同源，理由见 mux 的 ④#1。
    logic                           ib_is_fp_opcode           [ISSUE_WIDTH];
    logic                           ib_use_rs1                [ISSUE_WIDTH];
    logic                           ib_use_rs2                [ISSUE_WIDTH];
    logic                           ib_use_rs3                [ISSUE_WIDTH];
    logic [REG_ADDR_W-1:0]          ib_rs1_idx                [ISSUE_WIDTH];
    logic [REG_ADDR_W-1:0]          ib_rs2_idx                [ISSUE_WIDTH];
    logic [REG_ADDR_W-1:0]          ib_rs3_idx                [ISSUE_WIDTH];
    logic                           ib_rs1_is_fp              [ISSUE_WIDTH];
    logic                           ib_rs2_is_fp              [ISSUE_WIDTH];
    logic                           ib_rs3_is_fp              [ISSUE_WIDTH];
    logic                           ib_is_store               [ISSUE_WIDTH];
    logic [XLEN-1:0]                ib_pc                     [ISSUE_WIDTH];
    logic [EXE_SUBOP_W-1:0]         ib_exe_subop              [ISSUE_WIDTH];
    full_decode_t                   ib_full_decode            [ISSUE_WIDTH];
    // INT 侧 4 个读地址，形状按 §2.5(1) 冻结的 [ISSUE_WIDTH][1:2]，
    // 与 INT_ARF / INT_tag_mapping 的读出值同形同序逐格对应。
    logic [REG_ADDR_W-1:0]          ib_int_rs_idx             [ISSUE_WIDTH][1:INT_SRC_PER_SLOT];

    // ---- dependency_check ---------------------------------------------
    // self_tag 就是观测面的 alloc_tag，见模块头注释。
    logic                           dc_rd_write_enable        [ISSUE_WIDTH];
    logic                           dc_slot0_present;
    logic                           dc_slot1_present;
    logic                           dc_serial0;
    logic                           dc_serial_inst;
    logic                           dc_fp0;
    logic                           dc_fp1;
    logic                           dc_slot_missed_wakeup     [ISSUE_WIDTH];
    logic                           dc_rsX_ready              [ISSUE_WIDTH][1:FP_READ_PORTS];
    logic [TAG_W-1:0]               dc_rsX_wait_tag           [ISSUE_WIDTH][1:FP_READ_PORTS];
    logic [RS_DATA_SEL_W-1:0]       dc_rs_data_sel_t          [ISSUE_WIDTH][1:FP_READ_PORTS];

    // ---- dispatch_logic -------------------------------------------------
    // accept 就是观测面的 alloc_valid。
    logic                           dl_ib_dequeue             [ISSUE_WIDTH];
    logic                           dl_isq_wr_en              [NUM_LANES];
    logic [FU_GROUP_W-1:0]          dl_slot_FU_Group          [ISSUE_WIDTH];
    rm_e                            dl_effective_rm           [ISSUE_WIDTH];
    logic                           dl_is_fence_i             [ISSUE_WIDTH];
    logic                           dl_may_flush              [ISSUE_WIDTH];
    logic                           dl_is_atomic              [ISSUE_WIDTH];
    logic                           dl_serial_set;
    logic [TAG_W-1:0]               dl_serial_set_tag;
    logic                           dl_select_payload         [NUM_LANES][ISSUE_WIDTH];

    // ---- 寄存器堆 / tag mapping / 读地址 mux ---------------------------
    logic [XLEN-1:0]                intarf_ARF                [ISSUE_WIDTH][1:INT_SRC_PER_SLOT];
    logic [XLEN-1:0]                fparf_ARF                 [1:FP_READ_PORTS];
    logic [TAG_W-1:0]               intmap_tag                [ISSUE_WIDTH][1:INT_SRC_PER_SLOT];
    logic                           intmap_busy               [ISSUE_WIDTH][1:INT_SRC_PER_SLOT];
    logic [TAG_W-1:0]               fpmap_tag                 [1:FP_READ_PORTS];
    logic                           fpmap_busy                [1:FP_READ_PORTS];
    logic [REG_ADDR_W-1:0]          fpmux_fp_read_idx         [1:FP_READ_PORTS];

    // ---- §2.1 装配 与 4 个 p1_ISQ_input_mux ----------------------------
    isq_payload_t                   asm_slot_payload          [ISSUE_WIDTH];
    isq_payload_t                   mux_ISQ_payload_in        [NUM_LANES];

    // ---- ISQ_Group0..3 ------------------------------------------------
    logic                           isq0_issue_valid;
    logic [XLEN-1:0]                isq0_rs1_data;
    logic [XLEN-1:0]                isq0_rs2_data;
    logic [FU_GROUP_W-1:0]          isq0_FU_Group;
    logic                           isq0_imm_valid;
    logic [XLEN-1:0]                isq0_imm_data;
    logic [XLEN-1:0]                isq0_pc;
    logic [31:0]                    isq0_inst_bits;
    logic                           isq0_is_compressed;
    logic                           isq0_pred_taken;
    logic [XLEN-1:0]                isq0_pred_target_pc;
    logic [TAG_W-1:0]               isq0_self_tag;
    logic [EXE_SUBOP_W-1:0]         isq0_exe_subop;
    logic [FULL_DECODE_W-1:0]       isq0_full_decode;
    logic                           isq0_fetch_excp_vld;
    logic [FETCH_EXCP_CAUSE_W-1:0]  isq0_fetch_excp_cause;
    logic [XLEN-1:0]                isq0_fetch_excp_tval;
    logic                           isq0_isq_free_for_dispatch;

    logic                           isq1_issue_valid;
    logic [XLEN-1:0]                isq1_rs1_data;
    logic [XLEN-1:0]                isq1_rs2_data;
    logic [FU_GROUP_W-1:0]          isq1_FU_Group;
    logic                           isq1_imm_valid;
    logic [XLEN-1:0]                isq1_imm_data;
    logic [TAG_W-1:0]               isq1_self_tag;
    logic [EXE_SUBOP_W-1:0]         isq1_exe_subop;
    logic                           isq1_isq_free_for_dispatch;

    logic                           isq2_issue_valid;
    logic [XLEN-1:0]                isq2_rs1_data;
    logic [XLEN-1:0]                isq2_rs2_data;
    logic [XLEN-1:0]                isq2_rs3_data;
    logic [TAG_W-1:0]               isq2_self_tag;
    logic [EXE_SUBOP_W-1:0]         isq2_exe_subop;
    logic [FULL_DECODE_W-1:0]       isq2_full_decode;
    logic                           isq2_isq_free_for_dispatch;

    logic                           isq3_issue_valid;
    logic [XLEN-1:0]                isq3_rs1_data;
    logic [XLEN-1:0]                isq3_rs2_data;
    logic                           isq3_imm_valid;
    logic [XLEN-1:0]                isq3_imm_data;
    logic                           isq3_is_store;
    logic [MEM_FUNCT3_W-1:0]        isq3_mem_funct3;
    logic                           isq3_rd_is_fp;
    logic [TAG_W-1:0]               isq3_self_tag;
    logic [EXE_SUBOP_W-1:0]         isq3_exe_subop;
    logic                           isq3_isq_free_for_dispatch;
    logic                           isq3_occupied;

    // ---- G0 的三个 FU -------------------------------------------------
    logic                           alu0_FU_ready;
    logic                           alu0_request_valid;
    logic [TAG_W-1:0]               alu0_req_tag;
    logic [XLEN-1:0]                alu0_req_result_data;
    logic                           alu0_req_mispredict_flag;
    logic [XLEN-1:0]                alu0_req_mispredict_target_pc;
    logic                           alu0_req_exception_flag;
    logic [EXCP_CAUSE_W-1:0]        alu0_req_exception_cause;
    logic [XLEN-1:0]                alu0_req_exception_tval;
    logic                           alu0_req_is_mret;
    logic                           alu0_req_is_sret;
    logic [FFLAGS_W-1:0]            alu0_req_fpu_fflags;
    logic                           alu0_req_is_csr;
    logic                           alu0_req_csr_write_enable;
    logic [CSR_ADDR_W-1:0]          alu0_req_csr_addr;
    logic [XLEN-1:0]                alu0_req_csr_wdata;

    logic [CSR_ADDR_W-1:0]          csrfu_csr_addr;
    logic                           csrfu_FU_ready;
    logic                           csrfu_request_valid;
    logic [TAG_W-1:0]               csrfu_req_tag;
    logic [XLEN-1:0]                csrfu_req_result_data;
    logic                           csrfu_req_mispredict_flag;
    logic [XLEN-1:0]                csrfu_req_mispredict_target_pc;
    logic                           csrfu_req_exception_flag;
    logic [EXCP_CAUSE_W-1:0]        csrfu_req_exception_cause;
    logic [XLEN-1:0]                csrfu_req_exception_tval;
    logic                           csrfu_req_is_mret;
    logic                           csrfu_req_is_sret;
    logic [FFLAGS_W-1:0]            csrfu_req_fpu_fflags;
    logic                           csrfu_req_is_csr;
    logic                           csrfu_req_csr_write_enable;
    logic [CSR_ADDR_W-1:0]          csrfu_req_csr_addr;
    logic [XLEN-1:0]                csrfu_req_csr_wdata;

    logic                           div_FU_ready;
    logic                           div_request_valid;
    logic [TAG_W-1:0]               div_req_tag;
    logic [XLEN-1:0]                div_req_result_data;
    logic                           div_req_mispredict_flag;
    logic [XLEN-1:0]                div_req_mispredict_target_pc;
    logic                           div_req_exception_flag;
    logic [EXCP_CAUSE_W-1:0]        div_req_exception_cause;
    logic [XLEN-1:0]                div_req_exception_tval;
    logic                           div_req_is_mret;
    logic                           div_req_is_sret;
    logic [FFLAGS_W-1:0]            div_req_fpu_fflags;
    logic                           div_req_is_csr;
    logic                           div_req_csr_write_enable;
    logic [CSR_ADDR_W-1:0]          div_req_csr_addr;
    logic [XLEN-1:0]                div_req_csr_wdata;

    // ---- G1 的两个 FU -------------------------------------------------
    logic                           alu1_FU_ready;
    logic                           alu1_request_valid;
    logic [TAG_W-1:0]               alu1_req_tag;
    logic [XLEN-1:0]                alu1_req_result_data;
    logic                           alu1_req_mispredict_flag;
    logic [XLEN-1:0]                alu1_req_mispredict_target_pc;
    logic                           alu1_req_exception_flag;
    logic [EXCP_CAUSE_W-1:0]        alu1_req_exception_cause;
    logic [XLEN-1:0]                alu1_req_exception_tval;
    logic                           alu1_req_is_mret;
    logic                           alu1_req_is_sret;
    logic [FFLAGS_W-1:0]            alu1_req_fpu_fflags;
    // 无对端（正常）：p3_arbiter_G1 没有 csr_sideband 层，G1 的 alu_simple
    // 这四根输出在 G1 位置上恒零、无人消费。仍具名接出，不省略端口行。
    logic                           alu1_req_is_csr;
    logic                           alu1_req_csr_write_enable;
    logic [CSR_ADDR_W-1:0]          alu1_req_csr_addr;
    logic [XLEN-1:0]                alu1_req_csr_wdata;
    // 同上：predictor_update 只有 G0 的 BRU 有对端（§1.5 / FU接入契约 §4.0），
    // G1 实例这五根靠路由自然恒零、无人消费。
    logic                           alu1_predictor_update_valid;
    logic [XLEN-1:0]                alu1_predictor_update_branch_pc;
    logic                           alu1_predictor_update_actual_taken;
    logic [XLEN-1:0]                alu1_predictor_update_actual_target;
    cf_class_e                      alu1_predictor_update_cf_class;

    logic                           mul_FU_ready;
    logic                           mul_request_valid;
    logic [TAG_W-1:0]               mul_req_tag;
    logic [XLEN-1:0]                mul_req_result_data;
    logic                           mul_req_mispredict_flag;
    logic [XLEN-1:0]                mul_req_mispredict_target_pc;
    logic                           mul_req_exception_flag;
    logic [EXCP_CAUSE_W-1:0]        mul_req_exception_cause;
    logic [XLEN-1:0]                mul_req_exception_tval;
    logic                           mul_req_is_mret;
    logic                           mul_req_is_sret;
    logic [FFLAGS_W-1:0]            mul_req_fpu_fflags;

    // ---- G2 的 FPU（无仲裁器，completion 直连 lane 2）------------------
    logic                           g2fu_FU_ready;
    logic                           g2fu_Result_valid;
    logic [TAG_W-1:0]               g2fu_tag_out;
    logic [XLEN-1:0]                g2fu_result_data;
    logic                           g2fu_mispredict_flag;
    logic [XLEN-1:0]                g2fu_mispredict_target_pc;
    logic                           g2fu_exception_flag;
    logic [EXCP_CAUSE_W-1:0]        g2fu_exception_cause;
    logic                           g2fu_bypass_valid;
    logic [TAG_W-1:0]               g2fu_bypass_tag;
    logic [XLEN-1:0]                g2fu_bypass_data;
    logic [XLEN-1:0]                g2fu_exception_tval;
    logic                           g2fu_is_mret;
    logic                           g2fu_is_sret;
    logic [FFLAGS_W-1:0]            g2fu_fpu_fflags;

    // ---- 两个组内仲裁器 -------------------------------------------------
    logic                           arbG0_Result_valid;
    logic [TAG_W-1:0]               arbG0_tag_out;
    logic [XLEN-1:0]                arbG0_result_data;
    logic                           arbG0_mispredict_flag;
    logic [XLEN-1:0]                arbG0_mispredict_target_pc;
    logic                           arbG0_exception_flag;
    logic [EXCP_CAUSE_W-1:0]        arbG0_exception_cause;
    logic [XLEN-1:0]                arbG0_exception_tval;
    logic                           arbG0_is_mret;
    logic                           arbG0_is_sret;
    logic [FFLAGS_W-1:0]            arbG0_fpu_fflags;
    logic                           arbG0_is_csr;
    logic                           arbG0_csr_write_enable;
    logic [CSR_ADDR_W-1:0]          arbG0_csr_addr;
    logic [XLEN-1:0]                arbG0_csr_wdata;
    logic                           arbG0_bypass_valid;
    logic [TAG_W-1:0]               arbG0_bypass_tag;
    logic [XLEN-1:0]                arbG0_bypass_data;
    logic                           arbG0_winner_grant        [G0_NUM_FU];
    logic                           arbG0_loser_hold          [G0_NUM_FU];

    logic                           arbG1_Result_valid;
    logic [TAG_W-1:0]               arbG1_tag_out;
    logic [XLEN-1:0]                arbG1_result_data;
    logic                           arbG1_exception_flag;
    logic [EXCP_CAUSE_W-1:0]        arbG1_exception_cause;
    logic [XLEN-1:0]                arbG1_exception_tval;
    logic                           arbG1_mispredict_flag;
    logic [XLEN-1:0]                arbG1_mispredict_target_pc;
    logic                           arbG1_is_mret;
    logic                           arbG1_is_sret;
    logic [FFLAGS_W-1:0]            arbG1_fpu_fflags;
    logic                           arbG1_bypass_valid;
    logic [TAG_W-1:0]               arbG1_bypass_tag;
    logic [XLEN-1:0]                arbG1_bypass_data;
    logic                           arbG1_winner_grant        [G1_NUM_FU];
    logic                           arbG1_loser_hold          [G1_NUM_FU];

    // ---- g3_lsu_iface（lane 3 的驱动方）--------------------------------
    logic                           lsuif_FU_ready;
    logic                           lsuif_Result_valid;
    logic [TAG_W-1:0]               lsuif_tag_out;
    logic [XLEN-1:0]                lsuif_result_data;
    logic                           lsuif_mispredict_flag;
    logic [XLEN-1:0]                lsuif_mispredict_target_pc;
    logic                           lsuif_exception_flag;
    logic [EXCP_CAUSE_W-1:0]        lsuif_exception_cause;
    logic [XLEN-1:0]                lsuif_exception_tval;
    logic                           lsuif_is_mret;
    logic                           lsuif_is_sret;
    logic [FFLAGS_W-1:0]            lsuif_fpu_fflags;
    logic                           lsuif_bypass_valid;
    logic [TAG_W-1:0]               lsuif_bypass_tag;
    logic [XLEN-1:0]                lsuif_bypass_data;

    // ---- P4 -----------------------------------------------------------
    logic [XLEN-1:0]                pcf_inst_pc;
    logic                           sit_serial_inflight_valid;

    trap_state_write_t              fm_trap_state_write;
    logic [EXCP_CAUSE_W-1:0]        fm_cause;
    logic                           fm_is_interrupt;

    logic [XLEN-1:0]                sih_csr_rdata;
    logic [PRIV_W-1:0]              sih_current_priv;
    rm_e                            sih_frm;
    logic                           sih_fs_enabled;
    logic [XLEN-1:0]                sih_trap_vector;
    logic                           sih_interrupt_pending;
    logic [EXCP_CAUSE_W-1:0]        sih_interrupt_cause;
    logic [XLEN-1:0]                sih_mepc;
    logic [XLEN-1:0]                sih_sepc;
    logic                           sih_mstatus_tvm;
    logic                           sih_mstatus_tw;
    logic                           sih_mstatus_tsr;

    logic                           scb_store_wakeup_valid;
    logic [TAG_W-1:0]               scb_store_wakeup_tag;
    logic                           scb_flush_valid;
    logic [TAG_W-1:0]               scb_flush_tag;
    logic [RECOVERY_KIND_W-1:0]     scb_recovery_kind;
    logic [TAG_W-1:0]               scb_head0_tag;
    logic [TAG_W-1:0]               scb_head1_tag;
    logic [XLEN-1:0]                scb_recovery_mispredict_target_pc;
    logic [EXCP_CAUSE_W-1:0]        scb_recovery_exception_cause;
    logic [XLEN-1:0]                scb_recovery_exception_tval;
    logic                           scb_st_br_resolve;
    logic [ROB_DEPTH-1:0]           scb_scoreboard_valid_bits;
    logic [ROB_DEPTH-1:0]           scb_scoreboard_exec_done_bits;
    logic [TAG_W-1:0]               scb_Buffer_tail;
    logic                           scb_can_alloc_1;
    logic                           scb_can_alloc_2;
    logic                           scb_buffer_empty;

    // ---- 胶水#2 的产物：四条 lane 的聚合数组 ---------------------------
    // exec_valid / exec_tag 就是这里的 Result_valid[NUM_LANES] / tag_out[NUM_LANES]
    // （见模块头注释：观测面不另起别名）。
    logic [XLEN-1:0]                lane_result_data          [NUM_LANES];
    logic                           lane_mispredict_flag      [NUM_LANES];
    logic [XLEN-1:0]                lane_mispredict_target_pc [NUM_LANES];
    logic                           lane_exception_flag       [NUM_LANES];
    logic [EXCP_CAUSE_W-1:0]        lane_exception_cause      [NUM_LANES];
    logic [XLEN-1:0]                lane_exception_tval       [NUM_LANES];
    logic                           lane_is_mret              [NUM_LANES];
    logic                           lane_is_sret              [NUM_LANES];
    logic [FFLAGS_W-1:0]            lane_fpu_fflags           [NUM_LANES];
    logic                           lane_bypass_valid         [NUM_LANES];
    logic [TAG_W-1:0]               lane_bypass_tag           [NUM_LANES];
    logic [XLEN-1:0]                lane_bypass_data          [NUM_LANES];

    // ---- 胶水#3 的产物：按组内 requester 编号聚合的 request ------------
    logic                           g0_request_valid          [G0_NUM_FU];
    logic [TAG_W-1:0]               g0_req_tag                [G0_NUM_FU];
    logic [XLEN-1:0]                g0_req_result_data        [G0_NUM_FU];
    logic                           g0_req_mispredict_flag    [G0_NUM_FU];
    logic [XLEN-1:0]                g0_req_mispredict_target_pc [G0_NUM_FU];
    logic                           g0_req_exception_flag     [G0_NUM_FU];
    logic [EXCP_CAUSE_W-1:0]        g0_req_exception_cause    [G0_NUM_FU];
    logic [XLEN-1:0]                g0_req_exception_tval     [G0_NUM_FU];
    logic                           g0_req_is_mret            [G0_NUM_FU];
    logic                           g0_req_is_sret            [G0_NUM_FU];
    logic [FFLAGS_W-1:0]            g0_req_fpu_fflags         [G0_NUM_FU];
    logic                           g0_req_is_csr             [G0_NUM_FU];
    logic                           g0_req_csr_write_enable   [G0_NUM_FU];
    logic [CSR_ADDR_W-1:0]          g0_req_csr_addr           [G0_NUM_FU];
    logic [XLEN-1:0]                g0_req_csr_wdata          [G0_NUM_FU];

    logic                           g1_request_valid          [G1_NUM_FU];
    logic [TAG_W-1:0]               g1_req_tag                [G1_NUM_FU];
    logic [XLEN-1:0]                g1_req_result_data        [G1_NUM_FU];
    logic                           g1_req_mispredict_flag    [G1_NUM_FU];
    logic [XLEN-1:0]                g1_req_mispredict_target_pc [G1_NUM_FU];
    logic                           g1_req_exception_flag     [G1_NUM_FU];
    logic [EXCP_CAUSE_W-1:0]        g1_req_exception_cause    [G1_NUM_FU];
    logic [XLEN-1:0]                g1_req_exception_tval     [G1_NUM_FU];
    logic                           g1_req_is_mret            [G1_NUM_FU];
    logic                           g1_req_is_sret            [G1_NUM_FU];
    logic [FFLAGS_W-1:0]            g1_req_fpu_fflags         [G1_NUM_FU];

    // ---- 胶水#4 的产物：按组聚合的 ready / free ------------------------
    logic                           g0_FU_ready               [G0_NUM_FU];
    logic                           g1_FU_ready               [G1_NUM_FU];
    logic                           isq_free_for_dispatch     [NUM_LANES];

    // ==================================================================
    // 胶水#1 · 队头字段提取（§1.1）
    //
    // §1.1 的「IB → dependency_check / dispatch_logic / FP_read_address_mux /
    // INT_ARF / INT_tag_mapping / FP_tag_mapping / CompletionScoreboard /
    // PC_File」八行收的是散字段。这里只做**字段选取**，不做任何判断、不改任何位。
    //
    // 2026-08-26 起来源分两处（IB 只存 RAW，重译码在出队侧）：
    //
    //   **寄存器索引 = `rvc_expand` 输出 `inst32` 的固定切片，不经过 decode。**
    //   这就是「寄存器读提前起跑」的全部内容：地址路径只等展开器里的
    //   **寄存器选择 mux 树**（浅），不等全译码，更不等 `subop_supported()`。
    //   立即数与 opcode 那些深锥不在这条路径上，综合会剪掉。
    //   索引因此**不被 ④#6 的 illegal 清零门控**——安全性由消费者侧保证
    //   （use_rs* / use_rd / rd_write_enable 三重限定），逐条核过，
    //   见 or_be_types_pkg 里 `decoded_info_t` 的注释。
    //
    //   其余译码产物来自 `dec_info[s]`，与队头同拍同源。
    // ==================================================================
    always_comb begin
        for (int unsigned s = 0; s < ISSUE_WIDTH; s++) begin
            // —— 队头 RAW ——
            ib_pc               [s] = head_IB_Payload[s].pc;
            // —— 地址支：只等 rvc_expand 的寄存器选择锥 ——
            ib_rs1_idx          [s] = rvce_inst32[s][19:15];
            ib_rs2_idx          [s] = rvce_inst32[s][24:20];
            ib_rs3_idx          [s] = rvce_inst32[s][31:27];
            ib_rd_idx           [s] = rvce_inst32[s][11:7];
            // §2.5(1)：源号就是下标，基是 1，没有 rs0。
            ib_int_rs_idx       [s][1] = rvce_inst32[s][19:15];
            ib_int_rs_idx       [s][2] = rvce_inst32[s][24:20];

            // —— 出队侧 decode ——
            ib_rd_is_fp         [s] = dec_info[s].rd_is_fp;
            ib_use_rd           [s] = dec_info[s].use_rd;
            ib_is_serial        [s] = dec_info[s].is_serial;
            ib_is_fp_instruction[s] = dec_info[s].is_fp_instruction;
            // 不经 dec_info：它只吃 inst32[6:0]，是 7 位比对，与 subop_raw
            // 和 d_no_encoding 都无关，所以 FP 的读地址不必等全译码。
            ib_is_fp_opcode     [s] = dec_is_fp_opcode[s];
            ib_use_rs1          [s] = dec_info[s].use_rs1;
            ib_use_rs2          [s] = dec_info[s].use_rs2;
            ib_use_rs3          [s] = dec_info[s].use_rs3;
            ib_rs1_is_fp        [s] = dec_info[s].rs1_is_fp;
            ib_rs2_is_fp        [s] = dec_info[s].rs2_is_fp;
            ib_rs3_is_fp        [s] = dec_info[s].rs3_is_fp;
            ib_is_store         [s] = dec_info[s].is_store;
            ib_exe_subop        [s] = dec_info[s].exe_subop;
            ib_full_decode      [s] = dec_info[s].full_decode;
        end
    end

    // ==================================================================
    // 胶水#2 · 四条完成 lane 的聚合（§1.2）
    //
    //   lane0 = p3_arbiter_G0   lane1 = p3_arbiter_G1
    //   lane2 = fpu_simple 直连（G2 单成员，无仲裁器）
    //   lane3 = g3_lsu_iface
    //
    // **每组数组只在这里聚合一次**，之后纯扇出到 Buffer /
    // CompletionScoreboard / dependency_check / 四个 ISQ_Group /
    // isq_payload_assembly。只聚合一次，bypass_data[b] 与
    // bypass_valid[b]/bypass_tag[b] 的 b 就天然是同一个。
    //
    // 恒零字段由 FU 自己驱动、仲裁器不补造（§1.2、FU接入契约 §4.1），
    // 所以这里一个字段都不合成、不补 0。
    // ==================================================================
    always_comb begin
        // ---------------- lane 0 : p3_arbiter_G0 ----------------
        exec_valid               [LANE_G0] = arbG0_Result_valid;
        exec_tag                 [LANE_G0] = arbG0_tag_out;
        lane_result_data         [LANE_G0] = arbG0_result_data;
        lane_mispredict_flag     [LANE_G0] = arbG0_mispredict_flag;
        lane_mispredict_target_pc[LANE_G0] = arbG0_mispredict_target_pc;
        lane_exception_flag      [LANE_G0] = arbG0_exception_flag;
        lane_exception_cause     [LANE_G0] = arbG0_exception_cause;
        lane_exception_tval      [LANE_G0] = arbG0_exception_tval;
        lane_is_mret             [LANE_G0] = arbG0_is_mret;
        lane_is_sret             [LANE_G0] = arbG0_is_sret;
        lane_fpu_fflags          [LANE_G0] = arbG0_fpu_fflags;
        lane_bypass_valid        [LANE_G0] = arbG0_bypass_valid;
        lane_bypass_tag          [LANE_G0] = arbG0_bypass_tag;
        lane_bypass_data         [LANE_G0] = arbG0_bypass_data;

        // ---------------- lane 1 : p3_arbiter_G1 ----------------
        exec_valid               [LANE_G1] = arbG1_Result_valid;
        exec_tag                 [LANE_G1] = arbG1_tag_out;
        lane_result_data         [LANE_G1] = arbG1_result_data;
        lane_mispredict_flag     [LANE_G1] = arbG1_mispredict_flag;
        lane_mispredict_target_pc[LANE_G1] = arbG1_mispredict_target_pc;
        lane_exception_flag      [LANE_G1] = arbG1_exception_flag;
        lane_exception_cause     [LANE_G1] = arbG1_exception_cause;
        lane_exception_tval      [LANE_G1] = arbG1_exception_tval;
        lane_is_mret             [LANE_G1] = arbG1_is_mret;
        lane_is_sret             [LANE_G1] = arbG1_is_sret;
        lane_fpu_fflags          [LANE_G1] = arbG1_fpu_fflags;
        lane_bypass_valid        [LANE_G1] = arbG1_bypass_valid;
        lane_bypass_tag          [LANE_G1] = arbG1_bypass_tag;
        lane_bypass_data         [LANE_G1] = arbG1_bypass_data;

        // ---------------- lane 2 : fpu_simple 直连 ----------------
        // ⚠ 接线表对不上的一处（已在交付说明里单列）：§1.2 要求「lane 驱动方
        // → bypass_valid[b]/bypass_tag[b]/bypass_data[b]」四条 lane 全有，
        // 但 fpu_simple ⑥ **没有 bypass_* 三个输出端口**——G2 无仲裁器，
        // 而 G0/G1 的 bypass 是仲裁器产的。这里取 lane 2 的 completion 本身：
        // 两个仲裁器的 bypass 就是 {Result_valid & !exception_flag, tag_out,
        // result_data}，而 G2 的 exception_flag 按 FU接入契约 §4.1 恒 0，
        // 该式在 lane 2 上退化成 Result_valid。故这是**同一根网的扇出**，
        // 不是本层新造的逻辑，也没有接常量。
        exec_valid               [LANE_G2] = g2fu_Result_valid;
        exec_tag                 [LANE_G2] = g2fu_tag_out;
        lane_result_data         [LANE_G2] = g2fu_result_data;
        lane_mispredict_flag     [LANE_G2] = g2fu_mispredict_flag;
        lane_mispredict_target_pc[LANE_G2] = g2fu_mispredict_target_pc;
        lane_exception_flag      [LANE_G2] = g2fu_exception_flag;
        lane_exception_cause     [LANE_G2] = g2fu_exception_cause;
        lane_exception_tval      [LANE_G2] = g2fu_exception_tval;
        lane_is_mret             [LANE_G2] = g2fu_is_mret;
        lane_is_sret             [LANE_G2] = g2fu_is_sret;
        lane_fpu_fflags          [LANE_G2] = g2fu_fpu_fflags;
        // FPU 自己驱动 lane 2 的 bypass（FU接入契约 §4），顶层不推导。
        lane_bypass_valid        [LANE_G2] = g2fu_bypass_valid;
        lane_bypass_tag          [LANE_G2] = g2fu_bypass_tag;
        lane_bypass_data         [LANE_G2] = g2fu_bypass_data;

        // ---------------- lane 3 : g3_lsu_iface ----------------
        exec_valid               [LANE_G3] = lsuif_Result_valid;
        exec_tag                 [LANE_G3] = lsuif_tag_out;
        lane_result_data         [LANE_G3] = lsuif_result_data;
        lane_mispredict_flag     [LANE_G3] = lsuif_mispredict_flag;
        lane_mispredict_target_pc[LANE_G3] = lsuif_mispredict_target_pc;
        lane_exception_flag      [LANE_G3] = lsuif_exception_flag;
        lane_exception_cause     [LANE_G3] = lsuif_exception_cause;
        lane_exception_tval      [LANE_G3] = lsuif_exception_tval;
        lane_is_mret             [LANE_G3] = lsuif_is_mret;
        lane_is_sret             [LANE_G3] = lsuif_is_sret;
        lane_fpu_fflags          [LANE_G3] = lsuif_fpu_fflags;
        lane_bypass_valid        [LANE_G3] = lsuif_bypass_valid;
        lane_bypass_tag          [LANE_G3] = lsuif_bypass_tag;
        lane_bypass_data         [LANE_G3] = lsuif_bypass_data;
    end

    // ==================================================================
    // 胶水#3 · 各 FU 的 completion request 按组内 requester 编号聚合
    //
    // 编号取自类型包的 G0_FU_* / G1_FU_*（FU接入契约 §1「个数不是身份」），
    // 不写字面 0/1/2：仲裁器的静态优先级链就是按这个下标排的。
    // ==================================================================
    always_comb begin
        // -------- G0 : ALU0/BRU、CSR、DIV --------
        g0_request_valid           [G0_FU_ALU] = alu0_request_valid;
        g0_req_tag                 [G0_FU_ALU] = alu0_req_tag;
        g0_req_result_data         [G0_FU_ALU] = alu0_req_result_data;
        g0_req_mispredict_flag     [G0_FU_ALU] = alu0_req_mispredict_flag;
        g0_req_mispredict_target_pc[G0_FU_ALU] = alu0_req_mispredict_target_pc;
        g0_req_exception_flag      [G0_FU_ALU] = alu0_req_exception_flag;
        g0_req_exception_cause     [G0_FU_ALU] = alu0_req_exception_cause;
        g0_req_exception_tval      [G0_FU_ALU] = alu0_req_exception_tval;
        g0_req_is_mret             [G0_FU_ALU] = alu0_req_is_mret;
        g0_req_is_sret             [G0_FU_ALU] = alu0_req_is_sret;
        g0_req_fpu_fflags          [G0_FU_ALU] = alu0_req_fpu_fflags;
        g0_req_is_csr              [G0_FU_ALU] = alu0_req_is_csr;
        g0_req_csr_write_enable    [G0_FU_ALU] = alu0_req_csr_write_enable;
        g0_req_csr_addr            [G0_FU_ALU] = alu0_req_csr_addr;
        g0_req_csr_wdata           [G0_FU_ALU] = alu0_req_csr_wdata;

        g0_request_valid           [G0_FU_CSR] = csrfu_request_valid;
        g0_req_tag                 [G0_FU_CSR] = csrfu_req_tag;
        g0_req_result_data         [G0_FU_CSR] = csrfu_req_result_data;
        g0_req_mispredict_flag     [G0_FU_CSR] = csrfu_req_mispredict_flag;
        g0_req_mispredict_target_pc[G0_FU_CSR] = csrfu_req_mispredict_target_pc;
        g0_req_exception_flag      [G0_FU_CSR] = csrfu_req_exception_flag;
        g0_req_exception_cause     [G0_FU_CSR] = csrfu_req_exception_cause;
        g0_req_exception_tval      [G0_FU_CSR] = csrfu_req_exception_tval;
        g0_req_is_mret             [G0_FU_CSR] = csrfu_req_is_mret;
        g0_req_is_sret             [G0_FU_CSR] = csrfu_req_is_sret;
        g0_req_fpu_fflags          [G0_FU_CSR] = csrfu_req_fpu_fflags;
        g0_req_is_csr              [G0_FU_CSR] = csrfu_req_is_csr;
        g0_req_csr_write_enable    [G0_FU_CSR] = csrfu_req_csr_write_enable;
        g0_req_csr_addr            [G0_FU_CSR] = csrfu_req_csr_addr;
        g0_req_csr_wdata           [G0_FU_CSR] = csrfu_req_csr_wdata;

        g0_request_valid           [G0_FU_DIV] = div_request_valid;
        g0_req_tag                 [G0_FU_DIV] = div_req_tag;
        g0_req_result_data         [G0_FU_DIV] = div_req_result_data;
        g0_req_mispredict_flag     [G0_FU_DIV] = div_req_mispredict_flag;
        g0_req_mispredict_target_pc[G0_FU_DIV] = div_req_mispredict_target_pc;
        g0_req_exception_flag      [G0_FU_DIV] = div_req_exception_flag;
        g0_req_exception_cause     [G0_FU_DIV] = div_req_exception_cause;
        g0_req_exception_tval      [G0_FU_DIV] = div_req_exception_tval;
        g0_req_is_mret             [G0_FU_DIV] = div_req_is_mret;
        g0_req_is_sret             [G0_FU_DIV] = div_req_is_sret;
        g0_req_fpu_fflags          [G0_FU_DIV] = div_req_fpu_fflags;
        g0_req_is_csr              [G0_FU_DIV] = div_req_is_csr;
        g0_req_csr_write_enable    [G0_FU_DIV] = div_req_csr_write_enable;
        g0_req_csr_addr            [G0_FU_DIV] = div_req_csr_addr;
        g0_req_csr_wdata           [G0_FU_DIV] = div_req_csr_wdata;

        // -------- G1 : ALU1、MUL（无 csr_sideband 层）--------
        g1_request_valid           [G1_FU_ALU] = alu1_request_valid;
        g1_req_tag                 [G1_FU_ALU] = alu1_req_tag;
        g1_req_result_data         [G1_FU_ALU] = alu1_req_result_data;
        g1_req_mispredict_flag     [G1_FU_ALU] = alu1_req_mispredict_flag;
        g1_req_mispredict_target_pc[G1_FU_ALU] = alu1_req_mispredict_target_pc;
        g1_req_exception_flag      [G1_FU_ALU] = alu1_req_exception_flag;
        g1_req_exception_cause     [G1_FU_ALU] = alu1_req_exception_cause;
        g1_req_exception_tval      [G1_FU_ALU] = alu1_req_exception_tval;
        g1_req_is_mret             [G1_FU_ALU] = alu1_req_is_mret;
        g1_req_is_sret             [G1_FU_ALU] = alu1_req_is_sret;
        g1_req_fpu_fflags          [G1_FU_ALU] = alu1_req_fpu_fflags;

        g1_request_valid           [G1_FU_MUL] = mul_request_valid;
        g1_req_tag                 [G1_FU_MUL] = mul_req_tag;
        g1_req_result_data         [G1_FU_MUL] = mul_req_result_data;
        g1_req_mispredict_flag     [G1_FU_MUL] = mul_req_mispredict_flag;
        g1_req_mispredict_target_pc[G1_FU_MUL] = mul_req_mispredict_target_pc;
        g1_req_exception_flag      [G1_FU_MUL] = mul_req_exception_flag;
        g1_req_exception_cause     [G1_FU_MUL] = mul_req_exception_cause;
        g1_req_exception_tval      [G1_FU_MUL] = mul_req_exception_tval;
        g1_req_is_mret             [G1_FU_MUL] = mul_req_is_mret;
        g1_req_is_sret             [G1_FU_MUL] = mul_req_is_sret;
        g1_req_fpu_fflags          [G1_FU_MUL] = mul_req_fpu_fflags;
    end

    // ==================================================================
    // 胶水#4 · 按组聚合的 FU_ready 与 isq_free_for_dispatch
    //
    //   FU_ready[k]              §1.2「组内各 FU → ISQ_Group_g」，k 是组内
    //                            requester 编号，同胶水#3 取自类型包。
    //   isq_free_for_dispatch[g] §1.1「ISQ_Group_g → dispatch_logic」，
    //                            g 是组号（dispatch_logic 的 GRP_G0..G3）。
    // ==================================================================
    always_comb begin
        g0_FU_ready[G0_FU_ALU] = alu0_FU_ready;
        g0_FU_ready[G0_FU_CSR] = csrfu_FU_ready;
        g0_FU_ready[G0_FU_DIV] = div_FU_ready;

        g1_FU_ready[G1_FU_ALU] = alu1_FU_ready;
        g1_FU_ready[G1_FU_MUL] = mul_FU_ready;

        isq_free_for_dispatch[LANE_G0] = isq0_isq_free_for_dispatch;
        isq_free_for_dispatch[LANE_G1] = isq1_isq_free_for_dispatch;
        isq_free_for_dispatch[LANE_G2] = isq2_isq_free_for_dispatch;
        isq_free_for_dispatch[LANE_G3] = isq3_isq_free_for_dispatch;
    end

    // ==================================================================
    // 观测面唯一的一根别名：global_flush_valid 与送 lsu_if 的
    // global_flush_late 同源同网，只是观测面用名（§1.4 只允许一个网络，
    // 这里没有第二个驱动，只是把同一根网再引到一个顶层端口上）。
    // ==================================================================
    assign global_flush_valid = global_flush_late;

    // ==================================================================
    // §1.1 · P1 取指到派遣
    // ==================================================================

    // ---- 胶水#5：fe_instr_pld[s] -> 入队侧的散字段 -------------------
    // 八个字段全部在此展开。下游端口表是权威，少接一个就编译不过。
    logic [XLEN-1:0]               fe_pc               [ISSUE_WIDTH];
    logic [31:0]                   fe_inst_bits        [ISSUE_WIDTH];
    logic                          fe_is_compressed    [ISSUE_WIDTH];
    logic                          fe_pred_taken       [ISSUE_WIDTH];
    logic [XLEN-1:0]               fe_pred_target_pc   [ISSUE_WIDTH];
    logic                          fe_fetch_excp_vld   [ISSUE_WIDTH];
    logic [FETCH_EXCP_CAUSE_W-1:0] fe_fetch_excp_cause [ISSUE_WIDTH];
    logic [XLEN-1:0]               fe_fetch_excp_tval  [ISSUE_WIDTH];

    always_comb begin
        for (int unsigned s = 0; s < ISSUE_WIDTH; s++) begin
            fe_pc[s]               = fe_instr_pld[s].pc;
            fe_inst_bits[s]        = fe_instr_pld[s].inst_bits;
            fe_is_compressed[s]    = fe_instr_pld[s].is_compressed;
            fe_pred_taken[s]       = fe_instr_pld[s].pred_taken;
            fe_pred_target_pc[s]   = fe_instr_pld[s].pred_target_pc;
            fe_fetch_excp_vld[s]   = fe_instr_pld[s].fetch_excp_vld;
            fe_fetch_excp_cause[s] = fe_instr_pld[s].fetch_excp_cause;
            fe_fetch_excp_tval[s]  = fe_instr_pld[s].fetch_excp_tval;
        end
    end

    // ---- 胶水#6：入队 payload 装配（**纯连线**）-----------------------
    // 取指拍（FE 的 flop -> IB 的 flop）**不允许有任何逻辑**：2026-08-26 实测
    // 确认这一拍连一块 RVC 展开都放不下。所以这里只是把 FE payload 的八个字段
    // 原样搬进 ib_payload_t，连 `fetch_excp` 的清零掩码都不做——消费者本来就
    // 用 `fetch_excp_vld` 限定（alu_simple ④#7），那个掩码只是卫生。
    //
    // 两边字段集必须一致，由 or_be_types_check 的
    // `IB_PAYLOAD_W == FE_BE_INSTR_PLD_W` 钉住。
    always_comb begin
        for (int unsigned s = 0; s < ISSUE_WIDTH; s++) begin
            enq_IB_Payload[s] = '0;

            enq_IB_Payload[s].pc               = fe_pc[s];
            enq_IB_Payload[s].inst_bits        = fe_inst_bits[s];
            enq_IB_Payload[s].is_compressed    = fe_is_compressed[s];
            enq_IB_Payload[s].pred_taken       = fe_pred_taken[s];
            enq_IB_Payload[s].pred_target_pc   = fe_pred_target_pc[s];
            enq_IB_Payload[s].fetch_excp_vld   = fe_fetch_excp_vld[s];
            enq_IB_Payload[s].fetch_excp_cause = fe_fetch_excp_cause[s];
            enq_IB_Payload[s].fetch_excp_tval  = fe_fetch_excp_tval[s];
        end
    end

    IB u_IB (
        .clk               (clk),
        .rst_n             (rst_n),
        .enq_IB_Payload    (enq_IB_Payload),
        // **fe_valid 现在 FE 直连 IB。** 从前它经 decode 直通（`dec_fe_valid
        // = fe_valid`），decode 挪到出队侧之后连那一段直通也不需要了；
        // IB ③ 的准入链与 accepted_slot 回压契约仍然一个字都没变。
        .fe_valid          (fe_valid),
        .ib_dequeue        (dl_ib_dequeue),
        .global_flush_late (global_flush_late),
        .head_IB_Payload   (head_IB_Payload),
        .inst_valid        (ib_inst_valid),
        .fe_ready          (fe_ready),
        .accepted_slot     (accepted_slot)
    );

    // ---- 胶水#7：队头的四根 RAW 字段 ---------------------------------
    // 剩下的（pc / pred / fetch_excp 的 cause 与 tval）是纯直通字段，
    // 消费者直接从队头读，不穿过这里也不穿过 decode。
    logic [31:0] ibh_inst_bits       [ISSUE_WIDTH];
    logic [15:0] ibh_inst16          [ISSUE_WIDTH];
    logic        ibh_is_compressed   [ISSUE_WIDTH];
    logic        ibh_fetch_excp_vld  [ISSUE_WIDTH];

    always_comb begin
        for (int unsigned s = 0; s < ISSUE_WIDTH; s++) begin
            ibh_inst_bits     [s] = head_IB_Payload[s].inst_bits;
            // 压缩子码重编码（decode ④#5）用的是**原始半字**，不是展开结果。
            ibh_inst16        [s] = head_IB_Payload[s].inst_bits[15:0];
            ibh_is_compressed [s] = head_IB_Payload[s].is_compressed;
            ibh_fetch_excp_vld[s] = head_IB_Payload[s].fetch_excp_vld;
        end
    end

    // ---- 出队侧译码链第一块：RVC 展开 --------------------------------
    // **一个实例，两条分支共用。** 地址支只读它输出的 20 位固定切片（胶水#1），
    // 译码支读整条。不写第二份「寄存器号提取器」—— 那会是同一件事的两份实现，
    // 读错一个寄存器号没有任何东西能抓到。
    rvc_expand u_rvc_expand (
        .ib_inst_bits     (ibh_inst_bits),
        .ib_is_compressed (ibh_is_compressed),
        .inst32           (rvce_inst32),
        .rvc_illegal      (rvce_rvc_illegal)
    );

    // **decode 在 IB 之后，与地址支并行。**
    //   地址支  rvce_inst32 的 20 位切片 -> ARF / tag_mapping 读（胶水#1）
    //   译码支  rvce_inst32 整条 -> decode -> dec_info
    // 两条在 dependency_check 的限定项与 §2.1 装配处汇合。
    // 理由见 spec/微架构文档/P1译码位置重构分析.md（形态 A）。
    decode u_decode (
        .ib_inst32         (rvce_inst32),
        .ib_inst16         (ibh_inst16),
        .ib_is_compressed  (ibh_is_compressed),
        .ib_rvc_illegal    (rvce_rvc_illegal),
        .ib_fetch_excp_vld (ibh_fetch_excp_vld),
        .dec_info          (dec_info),
        .dec_is_fp_opcode  (dec_is_fp_opcode)
    );

    dependency_check u_dependency_check (
        .inst_valid                (ib_inst_valid),
        .rd_idx                    (ib_rd_idx),
        .rd_is_fp                  (ib_rd_is_fp),
        .use_rd                    (ib_use_rd),
        .is_serial                 (ib_is_serial),
        .is_fp_opcode              (ib_is_fp_opcode),
        .use_rs1                   (ib_use_rs1),
        .use_rs2                   (ib_use_rs2),
        .use_rs3                   (ib_use_rs3),
        .rs1_idx                   (ib_rs1_idx),
        .rs2_idx                   (ib_rs2_idx),
        .rs3_idx                   (ib_rs3_idx),
        .rs1_is_fp                 (ib_rs1_is_fp),
        .rs2_is_fp                 (ib_rs2_is_fp),
        .rs3_is_fp                 (ib_rs3_is_fp),
        .Buffer_tail               (scb_Buffer_tail),
        .INT_tag_mapping_tag       (intmap_tag),
        .INT_tag_mapping_busy      (intmap_busy),
        .FP_tag_mapping_tag        (fpmap_tag),
        .FP_tag_mapping_busy       (fpmap_busy),
        .scoreboard_valid_bits     (scb_scoreboard_valid_bits),
        .scoreboard_exec_done_bits (scb_scoreboard_exec_done_bits),
        .commit_valid              (commit_valid),
        .commit_tag                (commit_tag),
        // §1.2「lane 驱动方 → dependency_check  bypass_valid[b]、bypass_tag[b]
        // （不含 data）」——与送各 ISQ_Group / 装配的是同一组数组。
        .bypass_valid              (lane_bypass_valid),
        .bypass_tag                (lane_bypass_tag),
        .self_tag                  (alloc_tag),
        .rd_write_enable           (dc_rd_write_enable),
        .slot0_present             (dc_slot0_present),
        .slot1_present             (dc_slot1_present),
        .serial0                   (dc_serial0),
        .serial_inst               (dc_serial_inst),
        .fp0                       (dc_fp0),
        .fp1                       (dc_fp1),
        .slot_missed_wakeup        (dc_slot_missed_wakeup),
        .rsX_ready                 (dc_rsX_ready),
        .rsX_wait_tag              (dc_rsX_wait_tag),
        .rs_data_sel_t             (dc_rs_data_sel_t)
    );

    dispatch_logic u_dispatch_logic (
        .slot0_present         (dc_slot0_present),
        .slot1_present         (dc_slot1_present),
        .serial0               (dc_serial0),
        .serial_inst           (dc_serial_inst),
        .fp0                   (dc_fp0),
        .fp1                   (dc_fp1),
        .slot_missed_wakeup    (dc_slot_missed_wakeup),
        .exe_subop             (ib_exe_subop),
        .full_decode           (ib_full_decode),
        .is_fp_instruction     (ib_is_fp_instruction),
        .fs_enabled            (sih_fs_enabled),
        .frm                   (sih_frm),
        .can_alloc_1           (scb_can_alloc_1),
        .can_alloc_2           (scb_can_alloc_2),
        .buffer_empty          (scb_buffer_empty),
        .isq_free_for_dispatch (isq_free_for_dispatch),
        .serial_inflight_valid (sit_serial_inflight_valid),
        // §1.1「dependency_check → dispatch_logic  self_tag[0]
        //（serial_set 的转发载荷）」——只取 slot 0 那一个。
        .self_tag              (alloc_tag[0]),
        .global_flush_late     (global_flush_late),
        .accept                (alloc_valid),
        .ib_dequeue            (dl_ib_dequeue),
        .isq_wr_en             (dl_isq_wr_en),
        .slot_FU_Group         (dl_slot_FU_Group),
        .effective_rm          (dl_effective_rm),
        .is_fence_i            (dl_is_fence_i),
        .may_flush             (dl_may_flush),
        .is_atomic             (dl_is_atomic),
        .serial_set            (dl_serial_set),
        .serial_set_tag        (dl_serial_set_tag),
        .select_payload        (dl_select_payload)
    );

    INT_ARF u_INT_ARF (
        .clk             (clk),
        .rst_n           (rst_n),
        .commit_valid    (commit_valid),
        .rd_idx          (commit_rd_idx),
        .rd_is_fp        (commit_rd_is_fp),
        .rd_write_enable (commit_rd_write_enable),
        .commit_data     (commit_data),
        .rs_idx          (ib_int_rs_idx),
        .ARF             (intarf_ARF)
    );

    FP_ARF u_FP_ARF (
        .clk             (clk),
        .rst_n           (rst_n),
        .commit_valid    (commit_valid),
        .rd_write_enable (commit_rd_write_enable),
        .rd_is_fp        (commit_rd_is_fp),
        .rd_idx          (commit_rd_idx),
        .commit_data     (commit_data),
        .fp_read_idx     (fpmux_fp_read_idx),
        .ARF             (fparf_ARF)
    );

    INT_tag_mapping u_INT_tag_mapping (
        .clk                    (clk),
        .rst_n                  (rst_n),
        .accept                 (alloc_valid),
        .self_tag               (alloc_tag),
        .alloc_rd_idx           (ib_rd_idx),
        .alloc_rd_is_fp         (ib_rd_is_fp),
        .alloc_rd_write_enable  (dc_rd_write_enable),
        .commit_valid           (commit_valid),
        .commit_tag             (commit_tag),
        .commit_rd_idx          (commit_rd_idx),
        .commit_rd_is_fp        (commit_rd_is_fp),
        .commit_rd_write_enable (commit_rd_write_enable),
        .global_flush_late      (global_flush_late),
        .rs_idx                 (ib_int_rs_idx),
        .tag                    (intmap_tag),
        .busy                   (intmap_busy)
    );

    FP_tag_mapping u_FP_tag_mapping (
        .clk                    (clk),
        .rst_n                  (rst_n),
        .accept                 (alloc_valid),
        .alloc_rd_write_enable  (dc_rd_write_enable),
        .alloc_rd_is_fp         (ib_rd_is_fp),
        .alloc_rd_idx           (ib_rd_idx),
        .self_tag               (alloc_tag),
        .commit_valid           (commit_valid),
        .commit_tag             (commit_tag),
        .commit_rd_idx          (commit_rd_idx),
        .commit_rd_is_fp        (commit_rd_is_fp),
        .commit_rd_write_enable (commit_rd_write_enable),
        .global_flush_late      (global_flush_late),
        .fp_read_idx            (fpmux_fp_read_idx),
        .tag                    (fpmap_tag),
        .busy                   (fpmap_busy)
    );

    FP_read_address_mux u_FP_read_address_mux (
        .rs1_idx           (ib_rs1_idx),
        .rs2_idx           (ib_rs2_idx),
        .rs3_idx           (ib_rs3_idx),
        // §1.1「IB → FP_read_address_mux ... is_fp_instruction[0]」：
        // 端口是标量，只收 slot 0 那一位。
        .is_fp_opcode      (ib_is_fp_opcode[0]),
        .fp_read_idx       (fpmux_fp_read_idx)
    );

    // §2.1 的装配（全库唯一一处胶水，已独立成模块，顶层只接线）
    isq_payload_assembly u_isq_payload_assembly (
        .head_IB_Payload (head_IB_Payload),
        .dec_info        (dec_info),
        .rsX_ready       (dc_rsX_ready),
        .rsX_wait_tag    (dc_rsX_wait_tag),
        .rs_data_sel_t   (dc_rs_data_sel_t),
        .self_tag        (alloc_tag),
        .INT_ARF         (intarf_ARF),
        .FP_ARF          (fparf_ARF),
        .commit_data     (commit_data),
        // §1.2「lane 驱动方 → §2.1 装配  bypass_data[b]」——与送
        // dependency_check 的 bypass_valid/tag 是同一次聚合的同一个 b。
        .bypass_data     (lane_bypass_data),
        .slot_FU_Group   (dl_slot_FU_Group),
        .effective_rm    (dl_effective_rm),
        .slot_payload    (asm_slot_payload)
    );

    // 4 个 p1_ISQ_input_mux，每组一份；第 g 份收 select_payload[g][0/1]（§1.1）。
    // 输出端口名 ISQ_payload_in、ISQ_Group 侧入口名 payload_in——同一根网的
    // 两端不同名是正常的（§2.5(5b)）。
    p1_ISQ_input_mux u_p1_ISQ_input_mux_G0 (
        .slot_payload   (asm_slot_payload),
        .select_payload (dl_select_payload[LANE_G0]),
        .ISQ_payload_in (mux_ISQ_payload_in[LANE_G0])
    );

    p1_ISQ_input_mux u_p1_ISQ_input_mux_G1 (
        .slot_payload   (asm_slot_payload),
        .select_payload (dl_select_payload[LANE_G1]),
        .ISQ_payload_in (mux_ISQ_payload_in[LANE_G1])
    );

    p1_ISQ_input_mux u_p1_ISQ_input_mux_G2 (
        .slot_payload   (asm_slot_payload),
        .select_payload (dl_select_payload[LANE_G2]),
        .ISQ_payload_in (mux_ISQ_payload_in[LANE_G2])
    );

    p1_ISQ_input_mux u_p1_ISQ_input_mux_G3 (
        .slot_payload   (asm_slot_payload),
        .select_payload (dl_select_payload[LANE_G3]),
        .ISQ_payload_in (mux_ISQ_payload_in[LANE_G3])
    );

    // ==================================================================
    // §1.2 · P2 / P3 发射到完成
    // ==================================================================

    ISQ_Group0 u_ISQ_Group0 (
        .clk                   (clk),
        .rst_n                 (rst_n),
        .wr_en                 (dl_isq_wr_en[LANE_G0]),
        .payload_in            (mux_ISQ_payload_in[LANE_G0]),
        .bypass_valid          (lane_bypass_valid),
        .bypass_tag            (lane_bypass_tag),
        .bypass_data           (lane_bypass_data),
        .global_flush_late     (global_flush_late),
        .FU_ready              (g0_FU_ready),
        .issue_valid           (isq0_issue_valid),
        .rs1_data              (isq0_rs1_data),
        .rs2_data              (isq0_rs2_data),
        .FU_Group              (isq0_FU_Group),
        .imm_valid             (isq0_imm_valid),
        .imm_data              (isq0_imm_data),
        .pc                    (isq0_pc),
        .inst_bits             (isq0_inst_bits),
        .is_compressed         (isq0_is_compressed),
        .pred_taken            (isq0_pred_taken),
        .pred_target_pc        (isq0_pred_target_pc),
        .self_tag              (isq0_self_tag),
        .exe_subop             (isq0_exe_subop),
        .full_decode           (isq0_full_decode),
        .fetch_excp_vld        (isq0_fetch_excp_vld),
        .fetch_excp_cause      (isq0_fetch_excp_cause),
        .fetch_excp_tval       (isq0_fetch_excp_tval),
        .isq_free_for_dispatch (isq0_isq_free_for_dispatch)
    );

    ISQ_Group1 u_ISQ_Group1 (
        .clk                   (clk),
        .rst_n                 (rst_n),
        .wr_en                 (dl_isq_wr_en[LANE_G1]),
        .payload_in            (mux_ISQ_payload_in[LANE_G1]),
        .bypass_valid          (lane_bypass_valid),
        .bypass_tag            (lane_bypass_tag),
        .bypass_data           (lane_bypass_data),
        .global_flush_late     (global_flush_late),
        .FU_ready              (g1_FU_ready),
        .issue_valid           (isq1_issue_valid),
        .rs1_data              (isq1_rs1_data),
        .rs2_data              (isq1_rs2_data),
        .FU_Group              (isq1_FU_Group),
        .imm_valid             (isq1_imm_valid),
        .imm_data              (isq1_imm_data),
        .self_tag              (isq1_self_tag),
        .exe_subop             (isq1_exe_subop),
        .isq_free_for_dispatch (isq1_isq_free_for_dispatch)
    );

    ISQ_Group2 u_ISQ_Group2 (
        .clk                   (clk),
        .rst_n                 (rst_n),
        .payload_in            (mux_ISQ_payload_in[LANE_G2]),
        .wr_en                 (dl_isq_wr_en[LANE_G2]),
        .bypass_valid          (lane_bypass_valid),
        .bypass_tag            (lane_bypass_tag),
        .bypass_data           (lane_bypass_data),
        .global_flush_late     (global_flush_late),
        // G2 单成员，FU_ready 是标量（§2.5(6)：G2_NUM_FU = 1，无仲裁器）
        .FU_ready              (g2fu_FU_ready),
        .issue_valid           (isq2_issue_valid),
        .rs1_data              (isq2_rs1_data),
        .rs2_data              (isq2_rs2_data),
        .rs3_data              (isq2_rs3_data),
        .self_tag              (isq2_self_tag),
        .exe_subop             (isq2_exe_subop),
        .full_decode           (isq2_full_decode),
        .isq_free_for_dispatch (isq2_isq_free_for_dispatch)
    );

    ISQ_Group3 u_ISQ_Group3 (
        .clk                   (clk),
        .rst_n                 (rst_n),
        .wr_en                 (dl_isq_wr_en[LANE_G3]),
        .payload_in            (mux_ISQ_payload_in[LANE_G3]),
        .bypass_valid          (lane_bypass_valid),
        .bypass_tag            (lane_bypass_tag),
        .bypass_data           (lane_bypass_data),
        .global_flush_late     (global_flush_late),
        // §1.2「g3_lsu_iface → ISQ_Group3  FU_ready（一位，按 entry 类别限定）」
        .FU_ready              (lsuif_FU_ready),
        .issue_valid           (isq3_issue_valid),
        .rs1_data              (isq3_rs1_data),
        .rs2_data              (isq3_rs2_data),
        .imm_valid             (isq3_imm_valid),
        .imm_data              (isq3_imm_data),
        .is_store              (isq3_is_store),
        .mem_funct3            (isq3_mem_funct3),
        .rd_is_fp              (isq3_rd_is_fp),
        .self_tag              (isq3_self_tag),
        .exe_subop             (isq3_exe_subop),
        .isq_free_for_dispatch (isq3_isq_free_for_dispatch),
        // §1.3「ISQ_Group3 → CompletionScoreboard  isq_occupied」的值。
        // 与 self_tag 同源同拍，构成 st_br_resolve 读口的「地址 + 地址有效」两半。
        .isq_occupied          (isq3_occupied)
    );

    // ---- G0 的三个 FU。issue 字段清单逐字取自 FU接入契约 §3 的 G0 行 ----
    alu_simple #(
        // 断言专用（FU接入契约 §1.1）：1 = 本实例在 G0。
        .IS_G0 (1'b1)
    ) u_alu0_bru (
        .clk                            (clk),
        .rst_n                          (rst_n),
        .global_flush_late              (global_flush_late),
        .issue_valid                    (isq0_issue_valid),
        .rs1_data                       (isq0_rs1_data),
        .rs2_data                       (isq0_rs2_data),
        .FU_Group                       (isq0_FU_Group),
        .imm_valid                      (isq0_imm_valid),
        .imm_data                       (isq0_imm_data),
        .pc                             (isq0_pc),
        .inst_bits                      (isq0_inst_bits),
        .is_compressed                  (isq0_is_compressed),
        .pred_taken                     (isq0_pred_taken),
        .pred_target_pc                 (isq0_pred_target_pc),
        .self_tag                       (isq0_self_tag),
        .exe_subop                      (isq0_exe_subop),
        .full_decode                    (isq0_full_decode),
        .fetch_excp_vld                 (isq0_fetch_excp_vld),
        .fetch_excp_cause               (isq0_fetch_excp_cause),
        .fetch_excp_tval                (isq0_fetch_excp_tval),
        .current_priv                   (sih_current_priv),
        .mstatus_tsr                    (sih_mstatus_tsr),
        .mstatus_tw                     (sih_mstatus_tw),
        .mstatus_tvm                    (sih_mstatus_tvm),
        .FU_ready                       (alu0_FU_ready),
        .request_valid                  (alu0_request_valid),
        .req_tag                        (alu0_req_tag),
        .req_result_data                (alu0_req_result_data),
        .req_mispredict_flag            (alu0_req_mispredict_flag),
        .req_mispredict_target_pc       (alu0_req_mispredict_target_pc),
        .req_exception_flag             (alu0_req_exception_flag),
        .req_exception_cause            (alu0_req_exception_cause),
        .req_exception_tval             (alu0_req_exception_tval),
        .req_is_mret                    (alu0_req_is_mret),
        .req_is_sret                    (alu0_req_is_sret),
        .req_fpu_fflags                 (alu0_req_fpu_fflags),
        .req_is_csr                     (alu0_req_is_csr),
        .req_csr_write_enable           (alu0_req_csr_write_enable),
        .req_csr_addr                   (alu0_req_csr_addr),
        .req_csr_wdata                  (alu0_req_csr_wdata),
        // §1.5「G0 的 BRU → FE  predictor_update」，执行拍直发、不经仲裁器
        .predictor_update_valid         (predictor_update_valid),
        .predictor_update_branch_pc     (predictor_update_branch_pc),
        .predictor_update_actual_taken  (predictor_update_actual_taken),
        .predictor_update_actual_target (predictor_update_actual_target),
        .predictor_update_cf_class      (predictor_update_cf_class),
        .winner_grant                   (arbG0_winner_grant[G0_FU_ALU]),
        .loser_hold                     (arbG0_loser_hold  [G0_FU_ALU])
    );

    csr_unit u_csr_unit (
        .clk                      (clk),
        .rst_n                    (rst_n),
        .global_flush_late        (global_flush_late),
        .issue_valid              (isq0_issue_valid),
        .rs1_data                 (isq0_rs1_data),
        .rs2_data                 (isq0_rs2_data),
        .FU_Group                 (isq0_FU_Group),
        .imm_valid                (isq0_imm_valid),
        .imm_data                 (isq0_imm_data),
        .pc                       (isq0_pc),
        .inst_bits                (isq0_inst_bits),
        .is_compressed            (isq0_is_compressed),
        .pred_taken               (isq0_pred_taken),
        .pred_target_pc           (isq0_pred_target_pc),
        .self_tag                 (isq0_self_tag),
        .exe_subop                (isq0_exe_subop),
        .full_decode              (isq0_full_decode),
        // §1.2「csr_fu → system_instruction_handler  csr_addr（读地址）」与
        // 反向的「CSR[csr_addr] 旧值、current_priv、fs_enabled」——组合读口
        // 的两半（§4「带外部参数的组合读口是两条边」）。
        .csr_addr                 (csrfu_csr_addr),
        .csr_rdata                (sih_csr_rdata),
        .current_priv             (sih_current_priv),
        .mstatus_tvm              (sih_mstatus_tvm),
        .fs_enabled               (sih_fs_enabled),
        .winner_grant             (arbG0_winner_grant[G0_FU_CSR]),
        .loser_hold               (arbG0_loser_hold  [G0_FU_CSR]),
        .FU_ready                 (csrfu_FU_ready),
        .request_valid            (csrfu_request_valid),
        .req_tag                  (csrfu_req_tag),
        .req_result_data          (csrfu_req_result_data),
        .req_mispredict_flag      (csrfu_req_mispredict_flag),
        .req_mispredict_target_pc (csrfu_req_mispredict_target_pc),
        .req_exception_flag       (csrfu_req_exception_flag),
        .req_exception_cause      (csrfu_req_exception_cause),
        .req_exception_tval       (csrfu_req_exception_tval),
        .req_is_mret              (csrfu_req_is_mret),
        .req_is_sret              (csrfu_req_is_sret),
        .req_fpu_fflags           (csrfu_req_fpu_fflags),
        .req_is_csr               (csrfu_req_is_csr),
        .req_csr_write_enable     (csrfu_req_csr_write_enable),
        .req_csr_addr             (csrfu_req_csr_addr),
        .req_csr_wdata            (csrfu_req_csr_wdata)
    );

    div_simple u_div_simple (
        .clk                      (clk),
        .rst_n                    (rst_n),
        .global_flush_late        (global_flush_late),
        .issue_valid              (isq0_issue_valid),
        .rs1_data                 (isq0_rs1_data),
        .rs2_data                 (isq0_rs2_data),
        .FU_Group                 (isq0_FU_Group),
        .imm_valid                (isq0_imm_valid),
        .imm_data                 (isq0_imm_data),
        .pc                       (isq0_pc),
        .inst_bits                (isq0_inst_bits),
        .is_compressed            (isq0_is_compressed),
        .pred_taken               (isq0_pred_taken),
        .pred_target_pc           (isq0_pred_target_pc),
        .self_tag                 (isq0_self_tag),
        .exe_subop                (isq0_exe_subop),
        .full_decode              (isq0_full_decode),
        .winner_grant             (arbG0_winner_grant[G0_FU_DIV]),
        .loser_hold               (arbG0_loser_hold  [G0_FU_DIV]),
        .FU_ready                 (div_FU_ready),
        .request_valid            (div_request_valid),
        .req_tag                  (div_req_tag),
        .req_result_data          (div_req_result_data),
        .req_mispredict_flag      (div_req_mispredict_flag),
        .req_mispredict_target_pc (div_req_mispredict_target_pc),
        .req_exception_flag       (div_req_exception_flag),
        .req_exception_cause      (div_req_exception_cause),
        .req_exception_tval       (div_req_exception_tval),
        .req_is_mret              (div_req_is_mret),
        .req_is_sret              (div_req_is_sret),
        .req_fpu_fflags           (div_req_fpu_fflags),
        .req_is_csr               (div_req_is_csr),
        .req_csr_write_enable     (div_req_csr_write_enable),
        .req_csr_addr             (div_req_csr_addr),
        .req_csr_wdata            (div_req_csr_wdata)
    );

    // ---- G1 的两个 FU。issue 字段清单逐字取自 FU接入契约 §3 的 G1 行：
    // G1 没有 pc / inst_bits / is_compressed / pred_taken / pred_target_pc /
    // full_decode——ISQ_Group1 ⑥ 根本不产这六个字段。alu_simple 是同一份 RTL，
    // 端口在 G1 位置无源，按 §1.1 接常量 0：这正是「事件字段自然恒零」的
    // 物理原因（分支 / CSR / SYS / 非法全被 dispatch_logic 路由去 G0）。
    alu_simple #(
        // 断言专用（§1.1）：0 = 本实例在 G1。
        .IS_G0 (1'b0)
    ) u_alu1 (
        .clk                            (clk),
        .rst_n                          (rst_n),
        .global_flush_late              (global_flush_late),
        .issue_valid                    (isq1_issue_valid),
        .rs1_data                       (isq1_rs1_data),
        .rs2_data                       (isq1_rs2_data),
        .FU_Group                       (isq1_FU_Group),
        .imm_valid                      (isq1_imm_valid),
        .imm_data                       (isq1_imm_data),
        .pc                             ('0),
        .inst_bits                      ('0),
        .is_compressed                  ('0),
        .pred_taken                     ('0),
        .pred_target_pc                 ('0),
        .self_tag                       (isq1_self_tag),
        .exe_subop                      (isq1_exe_subop),
        .full_decode                    ('0),
        // 同上：ISQ_Group1 ⑥ 不产取指异常字段，decode 也从不把取指出错的
        // 条目路由到 G1（④#7 强制走 ILLEGAL 的 G0 路径）。
        .fetch_excp_vld                 (1'b0),
        .fetch_excp_cause               ('0),
        .fetch_excp_tval                ('0),
        .current_priv                   (2'b11),   // G1 收不到 SYS，接 M 常量
        // 同理：G1 收不到 SRET / WFI，这两根接 0。
        .mstatus_tsr                    (1'b0),
        .mstatus_tw                     (1'b0),
        .mstatus_tvm                    (1'b0),
        .FU_ready                       (alu1_FU_ready),
        .request_valid                  (alu1_request_valid),
        .req_tag                        (alu1_req_tag),
        .req_result_data                (alu1_req_result_data),
        .req_mispredict_flag            (alu1_req_mispredict_flag),
        .req_mispredict_target_pc       (alu1_req_mispredict_target_pc),
        .req_exception_flag             (alu1_req_exception_flag),
        .req_exception_cause            (alu1_req_exception_cause),
        .req_exception_tval             (alu1_req_exception_tval),
        .req_is_mret                    (alu1_req_is_mret),
        .req_is_sret                    (alu1_req_is_sret),
        .req_fpu_fflags                 (alu1_req_fpu_fflags),
        // 无对端（p3_arbiter_G1 无 csr_sideband 层）：接具名 wire 导不出去，
        // 不省略端口行。
        .req_is_csr                     (alu1_req_is_csr),
        .req_csr_write_enable           (alu1_req_csr_write_enable),
        .req_csr_addr                   (alu1_req_csr_addr),
        .req_csr_wdata                  (alu1_req_csr_wdata),
        // 同上：predictor_update 只有 G0 的 BRU 有对端。
        .predictor_update_valid         (alu1_predictor_update_valid),
        .predictor_update_branch_pc     (alu1_predictor_update_branch_pc),
        .predictor_update_actual_taken  (alu1_predictor_update_actual_taken),
        .predictor_update_actual_target (alu1_predictor_update_actual_target),
        .predictor_update_cf_class      (alu1_predictor_update_cf_class),
        .winner_grant                   (arbG1_winner_grant[G1_FU_ALU]),
        .loser_hold                     (arbG1_loser_hold  [G1_FU_ALU])
    );

    mul_simple u_mul_simple (
        .clk                      (clk),
        .rst_n                    (rst_n),
        .global_flush_late        (global_flush_late),
        .issue_valid              (isq1_issue_valid),
        .rs1_data                 (isq1_rs1_data),
        .rs2_data                 (isq1_rs2_data),
        .FU_Group                 (isq1_FU_Group),
        .imm_valid                (isq1_imm_valid),
        .imm_data                 (isq1_imm_data),
        .self_tag                 (isq1_self_tag),
        .exe_subop                (isq1_exe_subop),
        .winner_grant             (arbG1_winner_grant[G1_FU_MUL]),
        .loser_hold               (arbG1_loser_hold  [G1_FU_MUL]),
        .request_valid            (mul_request_valid),
        .req_tag                  (mul_req_tag),
        .req_result_data          (mul_req_result_data),
        .req_mispredict_flag      (mul_req_mispredict_flag),
        .req_mispredict_target_pc (mul_req_mispredict_target_pc),
        .req_exception_flag       (mul_req_exception_flag),
        .req_exception_cause      (mul_req_exception_cause),
        .req_exception_tval       (mul_req_exception_tval),
        .req_is_mret              (mul_req_is_mret),
        .req_is_sret              (mul_req_is_sret),
        .req_fpu_fflags           (mul_req_fpu_fflags),
        .FU_ready                 (mul_FU_ready)
    );

    // ---- G2 的 FPU：无仲裁器，completion 直连 lane 2，端口用裸名 ----
    fpu_simple u_fpu_simple (
        .clk                  (clk),
        .rst_n                (rst_n),
        .global_flush_late    (global_flush_late),
        .issue_valid          (isq2_issue_valid),
        .rs1_data             (isq2_rs1_data),
        .rs2_data             (isq2_rs2_data),
        .rs3_data             (isq2_rs3_data),
        .self_tag             (isq2_self_tag),
        .exe_subop            (isq2_exe_subop),
        // full_decode 的 rm 三位在装配拍已被 effective_rm 覆盖；FPU 直接用它，
        // §1.2 明写「system_instruction_handler → FPU  frm 这条边不存在」。
        .full_decode          (isq2_full_decode),
        .FU_ready             (g2fu_FU_ready),
        .Result_valid         (g2fu_Result_valid),
        .tag_out              (g2fu_tag_out),
        .result_data          (g2fu_result_data),
        .mispredict_flag      (g2fu_mispredict_flag),
        .mispredict_target_pc (g2fu_mispredict_target_pc),
        .exception_flag       (g2fu_exception_flag),
        .exception_cause      (g2fu_exception_cause),
        .exception_tval       (g2fu_exception_tval),
        .is_mret              (g2fu_is_mret),
        .is_sret              (g2fu_is_sret),
        .fpu_fflags           (g2fu_fpu_fflags),
        .bypass_valid              (g2fu_bypass_valid),
        .bypass_tag                (g2fu_bypass_tag),
        .bypass_data               (g2fu_bypass_data)
    );

    // ---- 两个组内仲裁器 ----
    p3_arbiter_G0 u_p3_arbiter_G0 (
        .request_valid            (g0_request_valid),
        .req_tag                  (g0_req_tag),
        .req_result_data          (g0_req_result_data),
        .req_mispredict_flag      (g0_req_mispredict_flag),
        .req_mispredict_target_pc (g0_req_mispredict_target_pc),
        .req_exception_flag       (g0_req_exception_flag),
        .req_exception_cause      (g0_req_exception_cause),
        .req_exception_tval       (g0_req_exception_tval),
        .req_is_mret              (g0_req_is_mret),
        .req_is_sret              (g0_req_is_sret),
        .req_fpu_fflags           (g0_req_fpu_fflags),
        .req_is_csr               (g0_req_is_csr),
        .req_csr_write_enable     (g0_req_csr_write_enable),
        .req_csr_addr             (g0_req_csr_addr),
        .req_csr_wdata            (g0_req_csr_wdata),
        .Result_valid             (arbG0_Result_valid),
        .tag_out                  (arbG0_tag_out),
        .result_data              (arbG0_result_data),
        .mispredict_flag          (arbG0_mispredict_flag),
        .mispredict_target_pc     (arbG0_mispredict_target_pc),
        .exception_flag           (arbG0_exception_flag),
        .exception_cause          (arbG0_exception_cause),
        .exception_tval           (arbG0_exception_tval),
        .is_mret                  (arbG0_is_mret),
        .is_sret                  (arbG0_is_sret),
        .fpu_fflags               (arbG0_fpu_fflags),
        .is_csr                   (arbG0_is_csr),
        .csr_write_enable         (arbG0_csr_write_enable),
        .csr_addr                 (arbG0_csr_addr),
        .csr_wdata                (arbG0_csr_wdata),
        .bypass_valid             (arbG0_bypass_valid),
        .bypass_tag               (arbG0_bypass_tag),
        .bypass_data              (arbG0_bypass_data),
        .winner_grant             (arbG0_winner_grant),
        .loser_hold               (arbG0_loser_hold)
    );

    p3_arbiter_G1 u_p3_arbiter_G1 (
        .req_tag                  (g1_req_tag),
        .req_result_data          (g1_req_result_data),
        .req_exception_flag       (g1_req_exception_flag),
        .req_exception_cause      (g1_req_exception_cause),
        .req_exception_tval       (g1_req_exception_tval),
        .req_mispredict_flag      (g1_req_mispredict_flag),
        .req_mispredict_target_pc (g1_req_mispredict_target_pc),
        .req_is_mret              (g1_req_is_mret),
        .req_is_sret              (g1_req_is_sret),
        .req_fpu_fflags           (g1_req_fpu_fflags),
        .request_valid            (g1_request_valid),
        .Result_valid             (arbG1_Result_valid),
        .tag_out                  (arbG1_tag_out),
        .result_data              (arbG1_result_data),
        .exception_flag           (arbG1_exception_flag),
        .exception_cause          (arbG1_exception_cause),
        .exception_tval           (arbG1_exception_tval),
        .mispredict_flag          (arbG1_mispredict_flag),
        .mispredict_target_pc     (arbG1_mispredict_target_pc),
        .is_mret                  (arbG1_is_mret),
        .is_sret                  (arbG1_is_sret),
        .fpu_fflags               (arbG1_fpu_fflags),
        .bypass_valid             (arbG1_bypass_valid),
        .bypass_tag               (arbG1_bypass_tag),
        .bypass_data              (arbG1_bypass_data),
        .winner_grant             (arbG1_winner_grant),
        .loser_hold               (arbG1_loser_hold)
    );

    // ---- G3 的边界桥（lane 3 的驱动方）----
    g3_lsu_iface u_g3_lsu_iface (
        .clk                       (clk),
        .rst_n                     (rst_n),
        .issue_valid               (isq3_issue_valid),
        .self_tag                  (isq3_self_tag),
        .exe_subop                 (isq3_exe_subop),
        .mem_funct3                (isq3_mem_funct3),
        .rd_is_fp                  (isq3_rd_is_fp),
        .rs1_data                  (isq3_rs1_data),
        .rs2_data                  (isq3_rs2_data),
        .imm_valid                 (isq3_imm_valid),
        .imm_data                  (isq3_imm_data),
        .is_store                  (isq3_is_store),
        // §1.3「CompletionScoreboard → g3_lsu_iface  st_br_resolve_by_tag」的
        // 值那一半；地址那一半见 CompletionScoreboard 的 st_br_resolve_tag。
        .st_br_resolve             (scb_st_br_resolve),
        .store_wakeup_valid        (scb_store_wakeup_valid),
        .store_wakeup_tag          (scb_store_wakeup_tag),
        .global_flush_late         (global_flush_late),
        .lsu_be_issue_ready        (lsu_be_issue_ready),
        .lsu_be_done_valid         (lsu_be_done_valid),
        .lsu_be_done_pld           (lsu_be_done_pld),
        .lsu_be_exception_valid    (lsu_be_exception_valid),
        .lsu_be_exception_pld      (lsu_be_exception_pld),
        .lsu_be_bypass_valid       (lsu_be_bypass_valid),
        .lsu_be_bypass_pld         (lsu_be_bypass_pld),
        .FU_ready                  (lsuif_FU_ready),
        .Result_valid              (lsuif_Result_valid),
        .tag_out                   (lsuif_tag_out),
        .result_data               (lsuif_result_data),
        .mispredict_flag           (lsuif_mispredict_flag),
        .mispredict_target_pc      (lsuif_mispredict_target_pc),
        .exception_flag            (lsuif_exception_flag),
        .exception_cause           (lsuif_exception_cause),
        .exception_tval            (lsuif_exception_tval),
        .is_mret                   (lsuif_is_mret),
        .is_sret                   (lsuif_is_sret),
        .fpu_fflags                (lsuif_fpu_fflags),
        .bypass_valid              (lsuif_bypass_valid),
        .bypass_tag                (lsuif_bypass_tag),
        .bypass_data               (lsuif_bypass_data),
        .be_lsu_issue_valid        (be_lsu_issue_valid),
        .be_lsu_issue_pld          (be_lsu_issue_pld),
        .be_lsu_entry_ready        (be_lsu_entry_ready),
        .be_lsu_store_wakeup_valid (be_lsu_store_wakeup_valid)
    );

    // ==================================================================
    // §1.3 / §1.4 · P4 提交、flush 与恢复
    // ==================================================================

    Buffer u_Buffer (
        .clk          (clk),
        .rst_n        (rst_n),
        .Result_valid (exec_valid),
        .tag_out      (exec_tag),
        .result_data  (lane_result_data),
        .head0_tag    (scb_head0_tag),
        .head1_tag    (scb_head1_tag),
        .commit_data  (commit_data)
    );

    PC_File u_PC_File (
        .clk       (clk),
        .rst_n     (rst_n),
        .accept    (alloc_valid),
        .self_tag  (alloc_tag),
        .pc        (ib_pc),
        // §1.4：两个恢复读口的地址是 SCB 产生的同一根 flush_tag，
        // 同拍扇出，flush_model 不重新驱动它。
        .flush_tag (scb_flush_tag),
        .head0_tag (scb_head0_tag),
        .head1_tag (scb_head1_tag),
        .inst_pc   (pcf_inst_pc),
        .trace_pc  (trace_pc)
    );

    SerialInstructionTracker u_SerialInstructionTracker (
        .clk                   (clk),
        .rst_n                 (rst_n),
        .serial_set            (dl_serial_set),
        // §1.1「dispatch_logic → SerialInstructionTracker  serial_set、
        // self_tag[0]」：转发载荷在 dispatch_logic 侧叫 serial_set_tag。
        .self_tag              (dl_serial_set_tag),
        .commit_valid          (commit_valid),
        .commit_tag            (commit_tag),
        .global_flush_late     (global_flush_late),
        .serial_inflight_valid (sit_serial_inflight_valid)
    );

    flush_model u_flush_model (
        .recovery_kind              (scb_recovery_kind),
        .flush_valid                (scb_flush_valid),
        .flush_tag                  (scb_flush_tag),
        .mispredict_target_pc       (scb_recovery_mispredict_target_pc),
        .exception_cause            (scb_recovery_exception_cause),
        .exception_tval             (scb_recovery_exception_tval),
        .inst_pc                    (pcf_inst_pc),
        .mepc                       (sih_mepc),
        .sepc                       (sih_sepc),
        .interrupt_cause            (sih_interrupt_cause),
        // trap_vector(cause, is_interrupt) 组合读口的「值」那一半；
        // 「参数」那一半是下面 cause / is_interrupt 两根（§4）。
        .trap_vector                (sih_trap_vector),
        .global_flush_late          (global_flush_late),
        .redirect_valid             (redirect_valid),
        .redirect_pc                (redirect_pc),
        .redirect_kind              (redirect_kind),
        .frontend_icache_invalidate (frontend_icache_invalidate),
        .trap_state_write           (fm_trap_state_write),
        .cause                      (fm_cause),
        .is_interrupt               (fm_is_interrupt)
    );

    system_instruction_handler u_system_instruction_handler (
        .clk                    (clk),
        .rst_n                  (rst_n),
        // §1.2：lane 0 的 csr_sideband 绕过 SCB，直连本模块——全库唯一一条。
        .Result_valid           (arbG0_Result_valid),
        .tag_out                (arbG0_tag_out),
        .sb_is_csr              (arbG0_is_csr),
        .sb_csr_write_enable    (arbG0_csr_write_enable),
        .sb_csr_addr            (arbG0_csr_addr),
        .sb_csr_wdata           (arbG0_csr_wdata),
        .commit_valid           (commit_valid),
        .commit_tag             (commit_tag),
        .commit_fflags          (commit_fflags),
        .rd_is_fp               (commit_rd_is_fp),
        .rd_write_enable        (commit_rd_write_enable),
        .commit_count           (commit_count),
        .trap_state_write       (fm_trap_state_write),
        .global_flush_late      (global_flush_late),
        // csr_fu 的软件读地址（§1.2「csr_fu → system_instruction_handler
        // csr_addr（读地址）」），与 sb_csr_addr 是两个不同的 in-event，
        // 按 §2.5(5) 分成两个端口。
        .csr_addr               (csrfu_csr_addr),
        .trap_cause_in          (fm_cause),
        .trap_is_interrupt_in   (fm_is_interrupt),
        .mip_meip               (mip_meip),
        .mip_mtip               (mip_mtip),
        .mip_msip               (mip_msip),
        .csr_rdata              (sih_csr_rdata),
        .current_priv           (sih_current_priv),
        .frm                    (sih_frm),
        .fs_enabled             (sih_fs_enabled),
        .trap_vector            (sih_trap_vector),
        .interrupt_pending      (sih_interrupt_pending),
        .interrupt_cause        (sih_interrupt_cause),
        .mepc                   (sih_mepc),
        .sepc                   (sih_sepc),
        .mstatus_tvm            (sih_mstatus_tvm),
        .mstatus_tw             (sih_mstatus_tw),
        .mstatus_tsr            (sih_mstatus_tsr)
    );

    CompletionScoreboard u_CompletionScoreboard (
        .clk                           (clk),
        .rst_n                         (rst_n),
        .accept                        (alloc_valid),
        .alloc_self_tag                (alloc_tag),
        .rd_idx                        (ib_rd_idx),
        .rd_is_fp                      (ib_rd_is_fp),
        .rd_write_enable               (dc_rd_write_enable),
        .is_store                      (ib_is_store),
        .is_fence_i                    (dl_is_fence_i),
        .may_flush                     (dl_may_flush),
        .is_atomic                     (dl_is_atomic),
        // 四条 lane 的写回事件批，胶水#2 聚合而来
        .Result_valid                  (exec_valid),
        .tag_out                       (exec_tag),
        .mispredict_flag               (lane_mispredict_flag),
        .mispredict_target_pc          (lane_mispredict_target_pc),
        .exception_flag                (lane_exception_flag),
        .exception_cause               (lane_exception_cause),
        .exception_tval                (lane_exception_tval),
        .is_mret                       (lane_is_mret),
        .is_sret                       (lane_is_sret),
        .fpu_fflags                    (lane_fpu_fflags),
        .global_flush_late             (global_flush_late),
        .interrupt_pending             (sih_interrupt_pending),
        // st_br_resolve 读口的地址那一半（§4）：G3 issue 边界上的 self_tag，
        // 与送 g3_lsu_iface 的是同一根网。
        .st_br_resolve_tag             (isq3_self_tag),
        // 读地址的有效位（2026-08-26 新增边）：ISQ_Group3 此刻是否真驻留着
        // 一条指令。SCB 拿它区分「store 还在 ISQ3」与「已进 LSU」，
        // 从而选就地解析还是发唤醒脉冲。空队列时 isq3_self_tag 是残留值。
        //
        // **接的是 isq_occupied 不是 issue_valid。** issue_valid 含
        // operand_ready，store 等操作数期间是 0 —— 而那正是需要就地授权的
        // 时候。也不是 !isq_free_for_dispatch：那一位含同拍 issue，
        // 发射拍是 0，会把洞 B 的同拍前递打掉。
        .st_br_resolve_tag_valid       (isq3_occupied),
        .commit_valid                  (commit_valid),
        .commit_tag                    (commit_tag),
        .commit_rd_idx                 (commit_rd_idx),
        .commit_rd_is_fp               (commit_rd_is_fp),
        .commit_rd_write_enable        (commit_rd_write_enable),
        .commit_fflags                 (commit_fflags),
        .commit_count                  (commit_count),
        .store_wakeup_valid            (scb_store_wakeup_valid),
        .store_wakeup_tag              (scb_store_wakeup_tag),
        .flush_valid                   (scb_flush_valid),
        .flush_tag                     (scb_flush_tag),
        .recovery_kind                 (scb_recovery_kind),
        .head0_tag                     (scb_head0_tag),
        .head1_tag                     (scb_head1_tag),
        .recovery_mispredict_target_pc (scb_recovery_mispredict_target_pc),
        .recovery_exception_cause      (scb_recovery_exception_cause),
        .recovery_exception_tval       (scb_recovery_exception_tval),
        .st_br_resolve                 (scb_st_br_resolve),
        .scoreboard_valid_bits         (scb_scoreboard_valid_bits),
        .scoreboard_exec_done_bits     (scb_scoreboard_exec_done_bits),
        .Buffer_tail                   (scb_Buffer_tail),
        .can_alloc_1                   (scb_can_alloc_1),
        .can_alloc_2                   (scb_can_alloc_2),
        .buffer_empty                  (scb_buffer_empty)
    );

endmodule

`endif // BACKEND_TOP_SV
