`timescale 1ns / 1ps
`default_nettype none
// =============================================================================
// audio_cdc.v -- BCLK domain -> 200 MHz domain crossing for the I2S front end
//
//   Why this is the whole point of the audio path (design sec.3.4 / B7):
//   the ADAU1761 derives BCLK from the MCLK *we* give it, but the phase of
//   BCLK relative to the 200 MHz system clock is arbitrary and drifts.  So
//   the arrival instant of every audio sample is a genuinely asynchronous
//   event -- the only such source on this board.  Feeding it into ts_top's
//   external s_valid port is what turns "we timestamp samples" from a claim
//   into a measurement.
//
//   Structure:
//     i2s_rx   (BCLK domain)  -> sample_pulse, 1 BCLK wide (~325 ns)
//     sync[2:0] (clk domain)  -> 2-FF synchroniser + rising-edge detect
//     ev                       -> one clk-wide pulse per frame
//
//   ★ 325 ns is 65 clk periods, so a 2-FF synchroniser cannot miss the pulse
//     and the edge detector cannot double-count it.  A pulse only one clk wide
//     would be missed; that is why the pulse is left wide in the BCLK domain.
//
//   ★ sample_data is captured at the same BCLK edge as the pulse and is then
//     stable for a whole frame (20.8 us at 48 kHz), so reading it several clk
//     periods after ev is safe.  Formally this is a multi-cycle path; the XDC
//     sets max_delay -datapath_only on it rather than a false path, so the
//     route still has to be short enough to settle.
// =============================================================================
module audio_cdc #(
    parameter integer DW = 16,
    parameter integer SLOT = 32
)(
    input  wire        clk,        // 200 MHz system clock
    input  wire        rst_n,      // synchronous to clk
    input  wire        bclk,
    input  wire        lrclk,
    input  wire        sd,

    output wire        ev,         // one clk-wide pulse per audio frame
    output wire [2*DW-1:0] sample_data,
    output wire [15:0] sample_cnt  // frames seen, clk domain
);

    wire        spulse;
    wire [2*DW-1:0] sdata;
    wire [15:0] fcnt;

    i2s_rx #(.DW(DW), .SLOT(SLOT)) u_rx (
        .bclk         (bclk),
        .lrclk        (lrclk),
        .sd           (sd),
        .sample_pulse (spulse),
        .sample_data  (sdata),
        .frame_cnt    (fcnt)
    );

    // ------------------------------------------------------------------ sync
    // ASYNC_REG marks the first two flops so place_design keeps them together
    // and the router does not spread the two hops across the die.
    (* ASYNC_REG = "TRUE" *) reg [2:0] sync = 3'b000;
    reg [15:0] cnt = 16'd0;
    reg [2*DW-1:0] data_r = {(2*DW){1'b0}};

    wire ev_i = sync[2] & ~sync[1];

    always @(posedge clk) begin
        if (!rst_n) begin
            sync  <= 3'b000;
            cnt   <= 16'd0;
            data_r <= {(2*DW){1'b0}};
        end else begin
            sync <= {sync[1:0], spulse};
            if (ev_i) begin
                cnt    <= cnt + 16'd1;
                data_r <= sdata;      // stable: whole-frame hold in BCLK domain
            end
        end
    end

    assign ev          = ev_i;
    assign sample_data = data_r;
    assign sample_cnt  = cnt;

endmodule
`default_nettype wire
