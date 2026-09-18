`ifndef CSR_UNIT_SV
`define CSR_UNIT_SV

/* verilator lint_off IMPORTSTAR */
import or_be_types_pkg::*;
import exe_subop_pkg::*;
/* verilator lint_on IMPORTSTAR */

// csr_unit -- G0 requester 1, the Zicsr execute-side FU.
//
// Rewritten against FU接入契约.md.  The instruction-side data path is the
// first version's verbatim: the legality table (§legal_csr_addr) and the
// CSRRW / CSRRS / CSRRC read-modify-write are copied line for line.  What
// changed is the boundary only:
//
//   * `orca_types` -> `or_be_types_pkg` (契约 §5); result_payload_t is gone,
//     the completion request now carries completion_common + the lane-0
//     csr_sideband layer with the `req_` prefix (契约 §4).
//   * the architectural CSR file, the P4 commit-time update path, the
//     performance counters and the architectural read mux are NOT here any
//     more: system_instruction_handler owns them.  This module keeps only the
//     combinational read port 集成层 §1.2 gives it
//     (csr_fu -> SIH csr_addr, SIH -> csr_fu csr_rdata / current_priv /
//     fs_enabled).
//   * `en` -> the issue handshake (契约 §3.0: capture = issue_valid & FU_ready),
//     `busy` -> `FU_ready` (opposite polarity).
//
// The three behaviour contracts of 契约 §2:
//   §2.1 flush kills everything in flight and forbids request_valid this cycle
//   §2.2 the completion is registered one cycle after issue (whole
//        completion_common, not just the valid)
//   §2.3 FU_ready = 0 while executing, and 0 while loser_hold holds the output
//
// 契约 §4.1 for G0: `fpu_fflags` must be driven to zero by the FU itself; the
// arbiter never fills a constant-zero field in.  CSR additionally produces no
// mispredict, and `is_mret` belongs to ALU0 (MRET takes the ALU SYS path) --
// the first version drove neither, so both stay at zero here.
module csr_unit (
    input  logic                     clk,
    input  logic                     rst_n,

    // ------------------------------------------------------------------
    // in-event: flush (announce) -- single-wire pulse (契约 §2.1)
    // ------------------------------------------------------------------
    input  logic                     global_flush_late,

    // ------------------------------------------------------------------
    // in-event: issue (move) -- the whole G0 bundle from ISQ_Group0 ⑥, in
    // ISQ_Group0's port order.  Declared in full even though CSR reads only
    // rs1_data / self_tag / exe_subop / full_decode / inst_bits / FU_Group:
    // §3 fixes the per-group field list and forbids trimming it to a per-FU
    // subset.
    //
    // `issue_valid` is a request line, not a fire line (§3.0): the transfer is
    // issue_valid & FU_ready, and the payload is held stable until then.
    // FU_Group is the *in-group* index (0 = ALU0/BRU, 1 = CSR, 2 = DIV).
    // ------------------------------------------------------------------
    input  logic                     issue_valid,
    input  logic [XLEN-1:0]          rs1_data,
    input  logic [FU_GROUP_W-1:0]    FU_Group,
    input  logic                     imm_valid,
    input  logic [XLEN-1:0]          imm_data,
    input  logic [31:0]              inst_bits,
    input  logic [TAG_W-1:0]         self_tag,
    input  logic [EXE_SUBOP_W-1:0]   exe_subop,
    input  logic [FULL_DECODE_W-1:0] full_decode,

    // ------------------------------------------------------------------
    // out: combinational read -- the software read address into
    // system_instruction_handler (集成层 §1.2 「csr_fu → SIH csr_addr」).
    // Name and width are system_instruction_handler ⑥'s, word for word.
    // ------------------------------------------------------------------
    output logic [CSR_ADDR_W-1:0]    csr_addr,

    // ------------------------------------------------------------------
    // in: combinational read -- 集成层 §1.2
    // 「SIH → csr_fu  CSR[csr_addr] 旧值、current_priv、fs_enabled」.
    // Same three names and widths as system_instruction_handler ⑥'s outputs.
    // A same-cycle broadcast that is never stored on this side.
    // ------------------------------------------------------------------
    input  logic [XLEN-1:0]          csr_rdata,
    input  logic [PRIV_W-1:0]        current_priv,
    // S9：M 态用来拦 S 态访问 satp 的那一位。
    input  logic                     mstatus_tvm,
    input  logic                     fs_enabled,

    // ------------------------------------------------------------------
    // in-event: arbiter feedback (§4, 集成层 §1.5).  winner_grant is the
    // trigger that retires the completion request; loser_hold is a level that
    // can stay high for many cycles while the request keeps losing.
    // ------------------------------------------------------------------
    input  logic                     winner_grant,
    input  logic                     loser_hold,

    // ------------------------------------------------------------------
    // out: combinational read -- ISQ_Group0 takes this as FU_ready[1].
    // §2.3: 0 while executing, 0 while holding a lost completion request.
    // A pure state quantity: §3.0 forbids any combinational dependence on
    // issue_valid, so it never looks at whether anyone is asking.
    // ------------------------------------------------------------------
    output logic                     FU_ready,

    // ------------------------------------------------------------------
    // out-event: completion request -> p3_arbiter_G0 requester 1 (§4).
    // Layer 1, completion_common -- every field driven by this FU.
    // ------------------------------------------------------------------
    output logic                     request_valid,
    output logic [TAG_W-1:0]         req_tag,
    output logic [XLEN-1:0]          req_result_data,
    output logic                     req_mispredict_flag,
    output logic [XLEN-1:0]          req_mispredict_target_pc,
    output logic                     req_exception_flag,
    output logic [EXCP_CAUSE_W-1:0]  req_exception_cause,
    output logic [XLEN-1:0]          req_exception_tval,
    output logic                     req_is_mret,
    output logic                     req_is_sret,
    output logic [FFLAGS_W-1:0]      req_fpu_fflags,

    // Layer 2, csr_sideband -- G0 only, and this is the FU that drives it
    // non-zero (§4).  It bypasses the CompletionScoreboard entirely and goes
    // straight to system_instruction_handler (集成层 §1.2).
    output logic                     req_is_csr,
    output logic                     req_csr_write_enable,
    output logic [CSR_ADDR_W-1:0]    req_csr_addr,
    output logic [XLEN-1:0]          req_csr_wdata
);

    // In-group identity comes from or_be_types_pkg (`G0_FU_CSR`), not from a
    // local constant: 契约 §1 fixes the chain ALU0/BRU(0) > CSR(1) > DIV(2)
    // for the whole group, so no single module owns that number.

    // Illegal instruction, the only cause this FU can raise.  63 bit -- the
    // cause number without the interrupt flag bit (契约 §4).
    localparam logic [EXCP_CAUSE_W-1:0] CAUSE_ILLEGAL_INSTRUCTION = EXCP_CAUSE_W'(2);

    // ------------------------------------------------------------------
    // Issue decode.  full_decode carries the two control fields the first
    // version took as separate ports: csr_write_intent (bit 16) and
    // csr_addr (bits 11:0), 集成层 §2.2.
    // ------------------------------------------------------------------
    full_decode_t fd;
    logic [CSR_ADDR_W-1:0] exe_csr_addr;
    logic                  csr_write_intent;
    logic                  fu_selected;
    logic                  accept;

    assign fd               = full_decode_t'(full_decode);
    assign exe_csr_addr     = fd.csr_addr;
    assign csr_write_intent = fd.csr_write_intent;

    // FU_Group is the in-group index; the FU uses it to tell whether this
    // issue is addressed to it (契约 §3).
    assign fu_selected = (FU_Group == FU_GROUP_W'(G0_FU_CSR));

    // §3.0 handshake: the capture condition is issue_valid & FU_ready, never
    // issue_valid alone.  §2.1 additionally forbids treating `en` as valid on
    // the flush cycle, so the term is repeated here even though ISQ_Group0
    // already gates its issue_valid with !global_flush_late.
    assign accept = issue_valid && fu_selected && FU_ready && !global_flush_late;

    // The software read address into system_instruction_handler.  Purely
    // combinational on both sides and it has no fire, so it is driven from the
    // live issue bundle; ISQ holds the payload stable until the handshake, so
    // the value sampled on the accept cycle is the right one.
    assign csr_addr = exe_csr_addr;

    // ------------------------------------------------------------------
    // Legality decode -- first version verbatim except for two things:
    //   * fs_enabled now arrives from system_instruction_handler instead of
    //     being derived from a local mstatus copy;
    //   * 0xB00 / 0xB02 moved out of the read-only row, see the comment on
    //     that arm (契约 §1.2: where the first version and the microarchitecture
    //     document conflict, the document wins).
    //
    // 集成层 §1.2: with FS == Off the three FP addresses are ILLEGAL and this
    // FU must RAISE AN EXCEPTION, not merely clear csr_write_enable -- only
    // clearing the write enable would let the illegal access retire as an
    // ordinary completion.  exception_flag below is what implements that; the
    // write enable is cleared as well because system_instruction_handler ⑥
    // expects an illegal access to arrive with sb_csr_write_enable = 0.
    // ------------------------------------------------------------------
    // ------------------------------------------------------------------
    // 特权检查（S9）。**S9 之前 current_priv 是个从没被读过的输入端口**——
    // 端口在、顶层接了、模块内一次都没引用，所以 U 态读 mstatus 会静默成功。
    // M-only 时这不可能违反；加了 U/S 之后就是缺口。
    //
    // RISC-V 用 CSR 地址的 [9:8] 编码最低特权级：00=U / 01=S / 11=M。
    // 与 current_priv 的编码（U=00 / S=01 / M=11）刚好同序，可以直接比。
    // ------------------------------------------------------------------
    logic priv_ok;
    assign priv_ok = (csr_addr[9:8] <= current_priv);

    // TVM：M 态置起后，S 态访问 satp 是非法指令（规范）。
    // **单独一项，不揉进那张静态表**——表说「本核有没有这个地址」，
    // 这条是动态特权状态，混在一起以后必然有人只改一边。
    logic tvm_blocked;
    assign tvm_blocked = mstatus_tvm && (current_priv == 2'b01)
                      && (csr_addr == 12'h180);

    logic legal_csr_addr_tbl;
    logic legal_csr_addr;
    // 表判「这个地址本核有没有」，特权判「当前级够不够」，两者都要过。
    assign legal_csr_addr = legal_csr_addr_tbl && priv_ok && !tvm_blocked;

    always_comb begin
        unique case (exe_csr_addr)
            12'h001, 12'h002, 12'h003: legal_csr_addr_tbl = fs_enabled;
            12'h300, 12'h301, 12'h340, 12'h341, 12'h342, 12'h343,
            12'h305, 12'h304, 12'h344,
            // mcycle / minstret are M-mode read/WRITE counters, and
            // system_instruction_handler implements the write (ADDR_MCYCLE /
            // ADDR_MINSTRET in its apply path).  The first version had them in
            // the read-only row, which made `csrw mcycle` raise an illegal
            // instruction -- §1.2 class A, the document wins.
            12'hB00, 12'hB02: legal_csr_addr_tbl = 1'b1;
            // PMP：本核实现 0 个 PMP 区域。RISC-V 特权规范允许此时把 PMP CSR
            // **硬连零**（也允许省略成 illegal）。这里取硬连零，理由是参考
            // ISA 模型无法关掉 PMP（发布版 YAML 没有这个开关），取 illegal
            // 会让 cosim 在每个 riscv-tests 的初始化段就永久错开两条指令。
            // 写被忽略、读恒 0；区域数为 0 时不做任何访问检查，与
            // 模型侧配成全允许（NAPOT|R|W|X 覆盖全空间）行为一致。
            12'h3A0, 12'h3B0: legal_csr_addr_tbl = 1'b1;
            // medeleg / mideleg —— S9 起是**真寄存器**（不再是硬连零）。
            12'h302, 12'h303: legal_csr_addr_tbl = 1'b1;
            // S9：S 态 CSR。sstatus/sie/sip 是 mstatus/mie/mip 的视图，
            // stvec/sscratch/sepc/scause/stval/satp 是真寄存器。
            // satp 只支持 Bare（MODE WARL 到 0），但**地址是合法的**——
            // 判非法会让每个 riscv-tests 前导的 `csrwi satp,0` 与参考模型分岔。
            12'h100, 12'h104, 12'h105,
            12'h140, 12'h141, 12'h142, 12'h143, 12'h144,
            12'h180: legal_csr_addr_tbl = ENABLE_S;
            12'hF11, 12'hF12, 12'hF13, 12'hF14: legal_csr_addr_tbl = !csr_write_intent;
            // cycle / instret are the read-only U-mode shadows of the two
            // counters above -- these are the genuinely read-only ones.
            12'hC00, 12'hC02: legal_csr_addr_tbl = !csr_write_intent;
            default: legal_csr_addr_tbl = 1'b0;
        endcase
    end

    // ------------------------------------------------------------------
    // Compute next write data based on Sub-Op -- first version verbatim.
    // The old value is system_instruction_handler's combinational csr_rdata;
    // the first version's local read mux moved there with the registers.
    // ------------------------------------------------------------------
    // CSR 写数据的源操作数：寄存器形态取 rs1，立即数形态取 uimm。
    logic [XLEN-1:0] csr_src;
    logic [XLEN-1:0] next_csr_wdata;
    logic            csr_write_en;

    always_comb begin
        next_csr_wdata = csr_rdata;
        csr_write_en   = 1'b0;

        // **源操作数按形态选**：CSRRW/S/C 用 rs1，CSRRWI/SI/CI 用 uimm。
        // decode 对立即数型明确设 use_rs1 = 0、把 uimm 走 imm_data
        // （rtl/p1/decode.sv 的 CSR 分支），所以这里拿 rs1_data 是错的 ——
        // 那三条形态的 rs1 根本没被读过。
        // 一直没暴露是因为 riscv-tests 初始化段里的 csrwi 都写 0。
        csr_src = imm_valid ? imm_data : rs1_data;

        case (exe_subop)
            SUBOP_CSRRW, SUBOP_CSRRWI: begin
                next_csr_wdata = csr_src;
                csr_write_en   = 1'b1;
            end
            SUBOP_CSRRS, SUBOP_CSRRSI: begin
                next_csr_wdata = csr_rdata | csr_src;
                csr_write_en   = 1'b1;
            end
            SUBOP_CSRRC, SUBOP_CSRRCI: begin
                next_csr_wdata = csr_rdata & ~csr_src;
                csr_write_en   = 1'b1;
            end
            default: begin
                next_csr_wdata = csr_rdata;
                csr_write_en   = 1'b0;
            end
        endcase
    end

    // ------------------------------------------------------------------
    // (契约 §2.3) FU_ready.
    //
    //   busy_q = an accepted instruction is still occupying the output
    //            register, i.e. its completion request has not been granted
    //
    // FU_ready = !busy_q & !loser_hold.  The loser_hold term is redundant --
    // loser_hold implies request_valid implies busy_q -- but §2.3 names it
    // explicitly, so it is written out rather than left to be re-derived.
    // FU_ready deliberately does not look at issue_valid (§3.0 iron rule 1).
    // ------------------------------------------------------------------
    logic busy_q;

    assign FU_ready = !busy_q && !loser_hold;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            busy_q <= 1'b0;
        end else if (global_flush_late || winner_grant) begin
            // §2.1: everything in flight is voided unconditionally, no tag
            // compare -- a flush only happens at the commit point, so whatever
            // this FU holds is necessarily younger than the flush point.
            // winner_grant is the request's ready: the output register frees.
            // The two terms can share a branch because `accept` can never be
            // set at the same time as either one -- it carries
            // !global_flush_late, and FU_ready is 0 whenever busy_q is.
            busy_q <= 1'b0;
        end else if (accept) begin
            busy_q <= 1'b1;
        end
    end

    // ------------------------------------------------------------------
    // (契约 §2.2) the completion register.  The whole completion_common plus
    // the csr_sideband layer is registered one cycle behind issue; a loser
    // holds it unchanged because accept cannot fire while busy_q is set.
    // ------------------------------------------------------------------
    logic [TAG_W-1:0]        tag_q;
    logic [XLEN-1:0]         result_data_q;
    logic                    exception_flag_q;
    logic [EXCP_CAUSE_W-1:0] exception_cause_q;
    logic [XLEN-1:0]         exception_tval_q;
    logic                    is_csr_q;
    logic                    csr_write_enable_q;
    logic [CSR_ADDR_W-1:0]   csr_addr_q;
    logic [XLEN-1:0]         csr_wdata_q;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            tag_q              <= '0;
            result_data_q      <= '0;
            exception_flag_q   <= 1'b0;
            exception_cause_q  <= '0;
            exception_tval_q   <= '0;
            is_csr_q           <= 1'b0;
            csr_write_enable_q <= 1'b0;
            csr_addr_q         <= '0;
            csr_wdata_q        <= '0;
        end else if (global_flush_late || winner_grant) begin
            tag_q              <= '0;
            result_data_q      <= '0;
            exception_flag_q   <= 1'b0;
            exception_cause_q  <= '0;
            exception_tval_q   <= '0;
            is_csr_q           <= 1'b0;
            csr_write_enable_q <= 1'b0;
            csr_addr_q         <= '0;
            csr_wdata_q        <= '0;
        end else if (accept) begin
            tag_q              <= self_tag;
            // the read value is bypassed and written to rd
            result_data_q      <= csr_rdata;
            exception_flag_q   <= !legal_csr_addr;
            exception_cause_q  <= !legal_csr_addr ? CAUSE_ILLEGAL_INSTRUCTION
                                                  : {EXCP_CAUSE_W{1'b0}};
            // tval for an illegal instruction is the instruction encoding.
            // The contract does not spell out this FU's tval, but 集成层 §1.5
            // 「inst_bits 只在执行侧供 tval」 and §2.2「其 tval 由 inst_bits
            // 提供」 both put inst_bits on the execute side for exactly this,
            // and §4.1 does not list exception_tval among G0's zero fields.
            exception_tval_q   <= !legal_csr_addr ? {{(XLEN-32){1'b0}}, inst_bits}
                                                  : {XLEN{1'b0}};
            is_csr_q           <= 1'b1;
            csr_write_enable_q <= csr_write_en && csr_write_intent && legal_csr_addr;
            csr_addr_q         <= exe_csr_addr;
            // calculated next state
            csr_wdata_q        <= next_csr_wdata;
        end
    end

    // ------------------------------------------------------------------
    // Completion request drive.  §2.1: no request_valid on the flush cycle.
    // ------------------------------------------------------------------
    assign request_valid        = busy_q && !global_flush_late;
    assign req_tag              = tag_q;
    assign req_result_data      = result_data_q;
    assign req_exception_flag   = exception_flag_q;
    assign req_exception_cause  = exception_cause_q;
    assign req_exception_tval   = exception_tval_q;
    assign req_is_csr           = is_csr_q;
    assign req_csr_write_enable = csr_write_enable_q;
    assign req_csr_addr         = csr_addr_q;
    assign req_csr_wdata        = csr_wdata_q;

    // Constant-zero fields, driven by the FU itself -- 契约 §4.1: the arbiter
    // never fabricates them.  CSR produces no mispredict; is_mret belongs to
    // ALU0/BRU; fpu_fflags is zero for the whole of G0.
    assign req_mispredict_flag      = 1'b0;
    assign req_mispredict_target_pc = '0;
    assign req_is_mret              = 1'b0;
    // SRET 与 MRET 一样走 ALU0 的 SYS 路径，不是 CSR 指令。
    assign req_is_sret              = 1'b0;
    assign req_fpu_fflags           = '0;

`ifndef SYNTHESIS
    // §2.1 self-check, kept from the first version.  It is an assertion, not
    // function: a completion request must never survive a flush by one cycle.
    logic global_flush_late_q;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            global_flush_late_q <= 1'b0;
        end else begin
            global_flush_late_q <= global_flush_late;
            if (global_flush_late_q && request_valid) begin
                $error("[CSR] stale completion after flush: request_valid=%0b tag=%0d csr_addr=0x%03h",
                       request_valid, req_tag, req_csr_addr);
                $stop;
            end
        end
    end
`endif

endmodule

`endif // CSR_UNIT_SV
