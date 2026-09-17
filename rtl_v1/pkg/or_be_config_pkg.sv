`ifndef OR_BE_CONFIG_PKG_SV
`define OR_BE_CONFIG_PKG_SV

// OR-BE build configuration.
//
// Separate from or_be_types_pkg on purpose: that package holds the frozen
// *schema* (widths, encodings, payload layouts) which is the same for every
// build.  This one holds the knobs that select *which ISA subset* a given
// build implements, and those must be visible to several modules at once.
//
// 集成层.md §2.4 is the normative home for the rule these encode:
//
//     一个扩展的开关同时驱动 misa、decode、FE 与 LSU，四处必须同源。
//     某个扩展的库外契约未闭合时，对应位必须为 0——misa 报告的是构建配置
//     **已经实现**的 ISA，不是开关、也不是路线图。
//
// Consumers today:
//   system_instruction_handler   misa extension bits (⑤); IALIGN for mepc (③)
//   dispatch_logic               illegal-instruction decode for disabled subops
//   IB / decode                  same
//
// **Do not** re-declare these as module parameters.  A per-module parameter
// can be overridden at one instantiation and not another, which is exactly the
// "四处必须同源" failure the rule above exists to prevent.
package or_be_config_pkg;

    // A extension -- LR / SC / 22 AMO.  Gates misa.A.
    localparam bit ENABLE_A  = 1'b1;

    // C extension -- compressed instructions.  Gates misa.C **and** IALIGN:
    // with C the architectural instruction alignment is 2 bytes, so mepc keeps
    // bit 0 clear only; without C it is 4 bytes.
    localparam bit ENABLE_C  = 1'b1;

    // F and D are enabled together -- the FP register file, fcsr/frm/fflags and
    // the G2 lane are shared, and there is no build that wants one without the
    // other.  Gates misa.F and misa.D.
    localparam bit ENABLE_FD = 1'b1;

    // Privilege modes.  The backend is **M + U**.  `current_priv` is a real
    // register, and mstatus.MPP is WARL-clamped to {M, U} -- writing S is
    // rejected, which is what a machine without S-mode must do.
    // There is no S mode: satp / medeleg / mideleg / SXL do not exist here.
    // The U-mode *counter shadows* (rdcycle / rdinstret, 0xC00 / 0xC02) are
    // read-only aliases -- riscv-tests read them, no privilege state involved.
    //
    // 2026-08-25 由 0 改为 1。B-14 当初定 M-only，S6 接 cosim 时发现：
    // riscv-tests 的 RVTEST_CODE_BEGIN 用 `csrwi mstatus,0` + `mret` 把测试体
    // 跑在 **U 态**，参考 ISA 模型照做，而模型的 U 态**关不掉**
    // （isa_string 去掉 u 无效，isa_dpi.md 也无别的特权配置）。
    // M-only 下 mret 留在 M 态，ecall 给 cause 11 而模型给 8 —— 每个用例
    // 末尾必定分叉。人拍板实现最小 U 态。
    //
    // 上面那句「isa_string 去掉 u 无效」后来被证明**对 `s` 同样成立**：
    // 用 rv64gcsu 与 rv64gc 各跑 rv64mi-p-illegal，mstatus 读回逐位相同，
    // SXL 恒 2、MPP=S 照样写得进（变更记录 D-02 补二）。
    // 也就是说模型的特权级行为整体不看 isa_string，不只是 u 这一个字母。
    // 即便如此，`dv/cfg/*.yaml` 里仍**必须**把 u 写上 —— 见那份配置的头注释。
    localparam bit ENABLE_U  = 1'b1;

    // S9（2026-08-25）。S 态与**中断投递**捆在一起做——见 RTL实施计划 §3 S9：
    // riscv-tests 的 S 态段是靠「委托到 S 的软件中断」驱动的，只做 S 态不做中断
    // 会让 rv64mi-p-illegal 从「在干净的点退出」变成「进 S 态后卡死」，比现状更糟。
    //
    // 关掉它时，system_instruction_handler 各节的公式**逐条退化回 M+U 形态**
    // （mideleg 恒 0 ⇒ delegated 恒 0 ⇒ 中断判据退化成 mstatus.MIE ∧ |(mie & mip)），
    // 退化路径在那份文档里就地写明，没有第二份 M+U 版本的规格。
    //
    // **不做地址翻译**：satp 只支持 Bare。本后端的 LSU 在库外，虚实转换由访存侧
    // 承担，Sv39/Sv48 不在 S9 范围内。
    localparam bit ENABLE_S  = 1'b1;

endpackage

`endif // OR_BE_CONFIG_PKG_SV
