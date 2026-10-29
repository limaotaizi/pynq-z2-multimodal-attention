`timescale 1ns/1ps
`default_nettype none
// =============================================================================
// align_buf.v -- the 4 s window alignment buffer (design 03 sec.3.5).
//
// Common grid: 0.5 s.  A 4 s window is exactly NSLOT = 8 grid cells.  Four
// modalities each deliver one grid cell of statistics per slot_done pulse;
// when all four have delivered all 8 cells, the bank is complete and the
// consumer reads it while the other bank is being filled (ping-pong,
// non-overlapping windows).
//
// This block is deliberately a *control + storage* layer: one slot of one
// modality is WORDS words of DW bits, whatever a modality's statistics block
// happens to be.  Sizing is therefore a parameter, not a hard-coded 44 KB:
//
//      eye  37 ch * 6 stats = 222 words
//      GSR  40 ch * 3       = 120 words
//      AU   17 ch * 6       = 102 words   (or 17*152 if the in-window sequence
//                                          is kept; design 03 sec.3.4 decides)
//
// Fairness rule: no modality may run ahead by a whole window.  If one does,
// its slot_done arrives while mod_done is already set and ovf[m] sticks.  That
// is the one failure mode that silently shifts windows against each other, so
// it is surfaced, not ignored.
//
// Read side is **synchronous** (registered, 1-cycle latency) since 2026-10-24.
// With an asynchronous read the 14,208 x 32 array was inferred as distributed
// RAM (LUTRAM) -- hundreds of LUTs with long combinational paths, which cannot
// close 200 MHz.  A registered read infers block RAM.  Consumers must present
// rd_mod/rd_slot/rd_addr one clock before the data is wanted.
// (The old async version is kept as mem-async in _pl/sim_win/_neg for the
// negative control.)
// =============================================================================
module align_buf #(
    parameter integer NSLOT = 8,
    parameter integer WORDS = 8,     // words per modality per slot
    parameter integer DW    = 32,
    parameter integer NCH   = 4,
    // Derived widths -- do not override.  They used to be hard-wired to 4 bit
    // (address) and 3 bit (slot), which silently capped WORDS at 16 against a
    // design requirement of 222/120/102 words per slot, and tied NSLOT to 8.
    // See _pl/_设计与实现核验_20261021.md.
    parameter integer AW    = (WORDS <= 1) ? 1 : $clog2(WORDS),
    parameter integer SLOTW = (NSLOT <= 1) ? 1 : $clog2(NSLOT)
)(
    input  wire                          clk,
    input  wire                          rst_n,
    input  wire                          clr,

    // write side: one word per cycle
    input  wire                          wr_en,
    input  wire [1:0]                    wr_mod,
    input  wire [SLOTW-1:0]              wr_slot,
    input  wire [AW-1:0]                 wr_addr,
    input  wire [DW-1:0]                 wr_data,

    // one pulse when a modality has finished writing one grid slot
    input  wire [NCH-1:0]                slot_done,

    // completed-window handoff
    output reg                           win_ready,
    output reg                           rd_bank,
    output wire [NCH-1:0]                ovf,

    // read side of the completed bank
    input  wire [1:0]                    rd_mod,
    input  wire [SLOTW-1:0]              rd_slot,
    input  wire [AW-1:0]                 rd_addr,
    output wire [DW-1:0]                 rd_data
);

    localparam integer SLW = (NSLOT <= 1) ? 1 : $clog2(NSLOT + 1);
    localparam integer DEPTH = 2 * NCH * NSLOT * WORDS;

    reg [DW-1:0] mem [0:DEPTH-1];

    // ------------------------------------------------------------ write
    wire [31:0] wr_idx = (((rd_bank ? 0 : 1) * NCH + wr_mod) * NSLOT + wr_slot)
                         * WORDS + wr_addr;

    always @(posedge clk) begin
        if (wr_en && wr_addr < WORDS)
            mem[wr_idx] <= wr_data;
    end

    // ------------------------------------------------------------ read
    // Registered read: rd_data is valid one clk after rd_* is presented.  This
    // is what makes the array map to BRAM instead of LUTRAM.
    wire [31:0] rd_idx = (((rd_bank ? 1 : 0) * NCH + rd_mod) * NSLOT + rd_slot)
                         * WORDS + rd_addr;
    reg  [DW-1:0] rd_data_r;
    always @(posedge clk) rd_data_r <= mem[rd_idx];
    assign rd_data = rd_data_r;

    // ------------------------------------------------------------ slot counters
    reg [SLW-1:0] slot_cnt [0:NCH-1];
    reg [NCH-1:0] mod_done;
    reg [NCH-1:0] ovf_r;

    // A modality finishes its window on the pulse that fills its last slot.
    // Evaluate that combinationally: waiting one cycle would let the swap see
    // a stale mod_done and either miss a window or flag a false overflow.
    wire [NCH-1:0] fin_now;
    genvar gi;
    generate
        for (gi = 0; gi < NCH; gi = gi + 1) begin : fin
            assign fin_now[gi] = slot_done[gi] && !mod_done[gi] &&
                                 (slot_cnt[gi] == NSLOT - 1);
        end
    endgenerate
    wire all_now = &(mod_done | fin_now);

    integer m;
    always @(posedge clk) begin
        if (!rst_n || clr) begin
            for (m = 0; m < NCH; m = m + 1) slot_cnt[m] <= {SLW{1'b0}};
            mod_done <= {NCH{1'b0}};
            ovf_r    <= {NCH{1'b0}};
            win_ready <= 1'b0;
            rd_bank   <= 1'b0;
        end else begin
            win_ready <= 1'b0;
            if (all_now) begin
                rd_bank   <= ~rd_bank;             // completed bank becomes readable
                win_ready <= 1'b1;
                mod_done  <= {NCH{1'b0}};
                for (m = 0; m < NCH; m = m + 1) slot_cnt[m] <= {SLW{1'b0}};
            end else begin
                for (m = 0; m < NCH; m = m + 1) begin
                    if (slot_done[m]) begin
                        if (mod_done[m]) begin
                            ovf_r[m] <= 1'b1;      // ran a whole window ahead
                        end else if (slot_cnt[m] == NSLOT - 1) begin
                            slot_cnt[m] <= {SLW{1'b0}};
                            mod_done[m] <= 1'b1;
                        end else begin
                            slot_cnt[m] <= slot_cnt[m] + 1'b1;
                        end
                    end
                end
            end
        end
    end

    assign ovf = ovf_r;

endmodule

`default_nettype wire
