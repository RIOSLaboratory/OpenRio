`ifndef FU_INPUT_MUX_SV
`define FU_INPUT_MUX_SV

/* verilator lint_off IMPORTSTAR */
import or_be_types_pkg::*;
/* verilator lint_on IMPORTSTAR */

// FU_input_mux -- pure combinational two-way select of one issue-side source
// operand (FU_input_mux微架构文档).
//
// (1) per-entry state          : none
// (2) state transition         : none
// (3) condition                : none
// (4) data path                : entry_rsX_data vs the hitting bypass lane
// (5) data structure           : none -- no per-entry storage
//
// This is an *internal* sub-block of ISQ_Group, not a module of its own on the
// integration layer: nine copies exist (G0/G1/G3 rs1+rs2, G2 rs1+rs2+rs3) and
// each one lives inside the ISQ_Group that owns it.  entry_rsX_data /
// rsX_ready / rsX_wait_tag are that ISQ's internal signals, so the integration
// layer registers only `ISQ_Group -> FU` issue delivery, never this block.
//
// One instance = one source.  There is no cross-source logic and no
// parameterisation difference between the nine copies, so the module carries
// neither a group number nor a source number: the letter X in the port names
// is the placeholder the doc uses, and the instantiating ISQ_Group binds it.
//
// The select criterion is not recomputed here.  ISQ already has to evaluate
// fast_ready_rsX to raise issue_valid; this block only consumes that result
// (rsX_ready) plus the lane compare to pick the data.
//
// No clock and no reset on purpose: (1)(2)(3) are all "none", so the module
// holds no state and is not on any flush broadcast list.
module FU_input_mux (
    // in-event: broadcast -- `entry_rsX_data`(64), the source data stored in
    // the entry (this source went ready earlier).  The doc writes it as
    // `entry.rsX_data`; a dot is not a legal SV identifier, so the port name
    // is the 集成层 §2.5(5) spelling `entry_rsX_data`.
    input  logic [XLEN-1:0] entry_rsX_data,
    // in-event: broadcast -- `bypass_data[b]`(64x4), the other candidate: this
    // cycle's p3 bypass lanes, forwarded past the entry.
    input  logic [XLEN-1:0] bypass_data  [NUM_LANES],
    // in-event: broadcast -- `bypass_publish_valid[b]`(1x4), `bypass_tag[b]`(4x4) and
    // `rsX_wait_tag`(4) feed the hit[b] compare and are not retained.
    input  logic            bypass_publish_valid [NUM_LANES],
    input  logic [TAG_W-1:0] bypass_tag  [NUM_LANES],
    input  logic [TAG_W-1:0] rsX_wait_tag,
    // in-event: select -- `rsX_ready`(1), entry data or a bypass lane.
    input  logic            rsX_ready,
    // out-event: combinational read -- `fu_rsX_data`(64), this source's data on
    // the owning ISQ_Group's issue port.  集成层 maps it as
    // `ISQ_Group.issue.rsX_data <-> fu_rsX_data`; one 64-bit path, not two.
    output logic [XLEN-1:0] fu_rsX_data
);

    // ------------------------------------------------------------------
    // (4)#1 lane hit
    //
    //     hit[b] = bypass_publish_valid[b] & (rsX_wait_tag == bypass_tag[b])
    //                                                    b in {0..3}
    //
    // At most one bit of hit is set, and this module does not create that
    // invariant -- it consumes it.  CompletionScoreboard ⑥'s writeback
    // constraint makes the four valid tag_out belong to four different
    // in-flight tags, and 集成层 wires bypass_tag[b] straight to tag_out[b].
    // ------------------------------------------------------------------
    logic [NUM_LANES-1:0] hit;

    always_comb begin
        for (int b = 0; b < NUM_LANES; b++) begin
            hit[b] = bypass_publish_valid[b] && (rsX_wait_tag == bypass_tag[b]);
        end
    end

    // ------------------------------------------------------------------
    // (4)#1 fu_rsX_data
    //
    //     fu_rsX_data =
    //         rsX_ready : entry_rsX_data        // ready first
    //         hit[0]    : bypass_data[0]
    //         hit[1]    : bypass_data[1]
    //         hit[2]    : bypass_data[2]
    //         hit[3]    : bypass_data[3]
    //         else      : don't-care            // source not ready => no issue
    //                                           // this cycle => nobody samples
    //
    // Two priorities, both already owned elsewhere -- neither is chosen here:
    //   * rsX_ready outranks every hit[b]: ④ says "ready 优先" verbatim.
    //   * among hits, the lowest-numbered lane wins: 集成层 §2.5(3) freezes
    //     that for a multi-lane same-tag hit.  It only ever matters if the
    //     one-hot0 property above were violated; the order costs nothing and
    //     keeps this block's answer identical to every other lane consumer.
    // The descending scan below is that priority: the last write wins, so
    // lane 0 overrides lane 1, and so on.
    //
    // The `else` row is the one thing ④ leaves open.  Driving 'x is not
    // synthesisable-friendly, so the output is held at entry_rsX_data: it is
    // deterministic, it keeps the block a genuine 2:1 select as ④'s prose
    // describes it, and it introduces no constant that some consumer might
    // later be read as meaningful.  Any value is legal here -- no reader
    // exists in this case.
    // ------------------------------------------------------------------
    always_comb begin
        fu_rsX_data = entry_rsX_data;
        if (!rsX_ready) begin
            for (int b = NUM_LANES - 1; b >= 0; b--) begin
                if (hit[b]) begin
                    fu_rsX_data = bypass_data[b];
                end
            end
        end
    end

endmodule

`endif // FU_INPUT_MUX_SV
