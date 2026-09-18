`ifndef FE_BE_PROTOCOL_PKG_SV
`define FE_BE_PROTOCOL_PKG_SV

// 冻结的 FE <-> BE 边界 schema。
//
// **为什么要单独成包。** 这条边此前没有契约包：payload 类型住在
// `dv/mock_tb/be_tb_pkg.sv`（那个包自己写明「只有前端 payload 与 mock DUT 的
// 分配记录住在这里，因为它们在冻结契约里没有对应物」），而 `backend_top` 那侧
// 是九根平铺端口，中间靠 `backend_top_wrap` 一个手写 always_comb 逐字段搬。
//
// 手工搬**漏过一次**：三个 fetch-exception 字段被 wrap 丢在地上
// （见 backend_top_wrap.sv 头注释里的 §8.10），FE 老老实实驱动了、BE 从来没
// 收到，编译与仿真都不报错。一个 struct 过边界，漏字段就是编译错误。
// LSU 那条边一直是这么做的（`be_lsu_issue_pld_t` 来自 or_be_lsu_protocol_pkg），
// 本包是同一条纪律在 FE 边的落地。
//
// **依赖方向**：exe_subop_pkg / or_be_lsu_protocol_pkg -> or_be_types_pkg -> 本包。
// 本包只**组装**，不新造任何宽度或编码：`xlen_t` / `ISSUE_WIDTH` /
// `FETCH_EXCP_CAUSE_W` / `recovery_kind_e` 全部取自 or_be_types_pkg，
// 一个数字都不重述。

package fe_be_protocol_pkg;

    import or_be_types_pkg::*;

    // 改这个包的规矩与另外两个冻结包相同（RTL实施计划 §9.4）：
    // 先停下来问，改编码就把版本号加一，三方解码器同步迁移。
    localparam int FE_BE_SPEC_VERSION = 1;

    // FE 的 lane 数**就是**派遣宽度，不是第二个 2。
    localparam int FE_BE_LANES = ISSUE_WIDTH;

    // ---------------------------------------------------------------------
    // FE -> BE 指令 payload
    // ---------------------------------------------------------------------
    // 冻结语义（三方必须一致，任何一条不一致都不会报错、只会算错）：
    //
    //   * **压缩指令不展开。** `inst_bits[15:0]` 放原始半字、高 16 位补 0，
    //     `is_compressed = 1`。展开是 decode 的事（它调 rvc_decompress_rv64）。
    //     这条决定了非法指令的 tval：压缩形态只把低 16 位写进 mtval。
    //
    //   * **`fetch_excp_vld = 1` 时 `inst_bits` 无意义。** 「没读到编码」与
    //     「读到的编码非法」是两件事；FE 填什么占位值都行，decode ④#7 会把
    //     这条强制走 ILLEGAL 的路由，而由 ALU 报**取指**的 cause 而不是 cause 2。
    //
    //   * **`fetch_excp_tval` 是故障半字的地址，不一定等于 `pc`。** 4 字节指令
    //     只有后半字取不到时，规范要求 pc 进 mepc、pc+2 进 mtval，所以这个值
    //     必须由 FE 携带，不能由 BE 从 pc 推。
    //
    //   * **`fetch_excp_cause` 是 RISC-V 标准同步异常号**，合法集合见
    //     `fe_be_fetch_cause_legal()`。BE 会把它零扩展进 mcause，不做改写。
    typedef struct packed {
        xlen_t       pc;
        logic [31:0] inst_bits;
        logic        is_compressed;
        logic        pred_taken;
        xlen_t       pred_target_pc;
        logic                          fetch_excp_vld;
        logic [FETCH_EXCP_CAUSE_W-1:0] fetch_excp_cause;
        xlen_t                         fetch_excp_tval;
    } fe_be_instr_pld_t;

    localparam int FE_BE_INSTR_PLD_W = $bits(fe_be_instr_pld_t);

    // 取指侧唯一合法的 cause 集合。
    //
    // 前端只可能报「取不到这个 PC」，能命名的号就这三个：
    //   0   指令地址未对齐 —— ENABLE_C 下 IALIGN = 2，架构上不可达。
    //       列在这里不是为了今天，是为了「关掉 C 之后它就变成可达」这件事有处可查。
    //   1   取指访问故障
    //   12  取指页故障
    //
    // 其余任何数字都是**产生方出了状况**，不是一条可以往 mcause 里写的号。
    // 没有这个判据时，FE 侧是 `cause = trap_type[4:0]` 直接截位透传：既不查
    // 集合，也不查截断（trap_type 是 64 位，≥32 的值会静默变成别的号）。
    function automatic logic fe_be_fetch_cause_legal(
        input logic [FETCH_EXCP_CAUSE_W-1:0] cause
    );
        return (cause == FETCH_EXCP_CAUSE_W'(0))
            || (cause == FETCH_EXCP_CAUSE_W'(1))
            || (cause == FETCH_EXCP_CAUSE_W'(12));
    endfunction

    // ---------------------------------------------------------------------
    // BE -> FE 重定向 payload
    // ---------------------------------------------------------------------
    // `kind` **直接就是 `recovery_kind_e`，不投影成 bool。**
    //
    // 投影过一版：mock 的 payload 只有 {interrupt_valid, trap_valid} 两位，
    // 于是 MISPREDICT / MRET / SRET / FENCE_I 四种全落成「两位都不置」。
    // 代价是前端分不出 FENCE.I 重取与普通控制流重定向——而这两者对 icache
    // 的要求不同。当时没暴露，只因为 mock FE 只读 `redirect_pc`、且没有 icache。
    //
    // icache 失效**不另立一个字段**：它就是 `kind == RECOVERY_FENCE_I`
    // （flush_model ④#3 就是这么产生 `frontend_icache_invalidate` 的）。
    // 契约里同一件事只留一个来源，两个字段就会有对不上的那天。
    typedef struct packed {
        xlen_t          redirect_pc;
        recovery_kind_e kind;
    } be_fe_redirect_pld_t;

    localparam int FE_BE_REDIRECT_PLD_W = $bits(be_fe_redirect_pld_t);

    function automatic logic fe_be_redirect_invalidates_icache(
        input be_fe_redirect_pld_t pld
    );
        return (pld.kind == RECOVERY_FENCE_I);
    endfunction

    // ---------------------------------------------------------------------
    // 握手语义（本包只能用注释冻结，信号住在 fe_if / backend_top 端口上）
    // ---------------------------------------------------------------------
    //   * **普通的 per-lane valid/ready，在 posedge 成交。** 一条 offer 是否被
    //     吃掉，就是这一拍的 `fe_valid[l] && fe_ready[l]`；IB 的 `accepted_slot`
    //     就是这个与本身（由 `fe_ready` 推出，不是第二个判据），所以边界上
    //     **没有** accept 这根线。
    //
    //   * `fe_ready` 是组合的。**FE 必须在 posedge 采样**：边沿前的稳定值才是
    //     DUT 在这个边沿上真正用的那个决定。在 negedge 读组合准入线，读到的是
    //     下一个 posedge 的决定，按它退休 offer 会丢指令或重复一条 —— 早先 TB
    //     那根寄存过的 accept 就是为了绕开这个歧义，相位改对之后不再需要。
    //
    //   * admission 是**前缀**：合法的 `accepted_slot` 只有 00 / 01 / 11，
    //     **10 不可能出现**。两条推论都必须遵守：
    //       - FE 把有效 offer 压到低 lane，`valid[1]` 蕴含 `valid[0]`；
    //       - `fe_ready[1]` 里**含** `fe_valid[0]`（IB ③），这样
    //         `accepted_slot == fe_valid & fe_ready` 才是恒等式。
    //     fe_if 就地断言了这两条前缀性质。
    //
    //   * flush 拍 `fe_ready` 与 `accepted_slot` 都恒 00（IB ③ 的
    //     `!global_flush_late` 项），整组 offer 作废。

endpackage

`endif // FE_BE_PROTOCOL_PKG_SV
