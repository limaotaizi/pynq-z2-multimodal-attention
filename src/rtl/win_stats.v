`timescale 1ns/1ps
`default_nettype none
// =============================================================================
// win_stats.v -- per-channel window statistics for the eye / GSR / AU streams.
//
// Design 03 sec.3.4: "window mean / variance / extremes / slope".  This block
// computes the *sufficient statistics* on the stream and leaves the divisions
// to the PS:
//
//      mean   = sum / N
//      var    = sumsq / N - mean^2          (population variance, N samples)
//      slope  = (N*Sxy - Sx*Sy) / (N*Sxx - Sx^2)  -- needs Sxy/Sxx, added below
//      min / max / first / last
//
// Slope needs Sxy = sum(t*x) and Sxx = sum(t^2).  Both are accumulated here
// (t = sample index 0..N-1), so PS can form the exact least-squares slope.
// Computing sum(t*x) on the fly is one extra multiply-add per sample; at
// 150/50/38 Hz that is nothing, and it avoids a second pass over the buffer.
//
// Why statistics instead of buffering: design 03 sec.3.4 "先降维，再缓冲".
// Eye is 37 ch * 600 samples * 2 B = 44.4 KB per window; the stats are
// 37 * 6 values * (a few bytes) = ~2 KB.  22x smaller, and it is the only
// representation the downstream token projection actually needs.
//
// Interface: C parallel channels, one sample (C*DW bits) per s_valid.
// A window is exactly N accepted samples.  done is a one-cycle pulse on the
// cycle after the N-th sample; the o_* buses are valid while done is high and
// remain valid until the next window's first sample overwrites them.
// =============================================================================
module win_stats #(
    parameter integer C  = 37,      // channels
    parameter integer DW = 16,      // sample width (signed)
    parameter integer N  = 600,     // samples per window
    parameter integer AW = 16       // width of the exported sum/sumsq words
)(
    input  wire                     clk,
    input  wire                     rst_n,
    input  wire                     clr,       // async window abort (sync here)
    input  wire                     s_valid,
    input  wire [C*DW-1:0]          s_data,

    output wire                     done,
    output wire [C*(DW+AW+1)-1:0]   o_sum,
    output wire [C*(2*DW+AW)-1:0]   o_sumsq,
    output wire [C*DW-1:0]          o_min,
    output wire [C*DW-1:0]          o_max,
    output wire [C*DW-1:0]          o_first,
    output wire [C*DW-1:0]          o_last,
    output wire [C*(2*DW+AW)-1:0]   o_sxy,      // sum(t*x), t = 0..N-1
    output wire [C*(2*DW+AW)-1:0]   o_sxx,      // sum(t*t)
    output wire [AW-1:0]            o_count
);

    localparam integer CNTW = (N <= 1) ? 1 : $clog2(N + 1);
    localparam integer SW   = DW + CNTW + 1;    // signed sum
    localparam integer UQ   = 2*DW + CNTW + 1;  // unsigned sumsq / sxy

    reg [CNTW-1:0] cnt;
    reg            done_r;

    always @(posedge clk) begin
        if (!rst_n || clr) begin
            cnt    <= {CNTW{1'b0}};
            done_r <= 1'b0;
        end else if (s_valid) begin
            if (cnt == N - 1) begin
                cnt    <= {CNTW{1'b0}};
                done_r <= 1'b1;
            end else begin
                cnt    <= cnt + 1'b1;
                done_r <= 1'b0;
            end
        end else begin
            done_r <= 1'b0;
        end
    end

    assign done    = done_r;
    assign o_count = {{(AW-CNTW){1'b0}}, cnt};

    genvar g;
    generate
        for (g = 0; g < C; g = g + 1) begin : ch
            wire signed [DW-1:0] x = s_data[g*DW +: DW];

            reg signed [SW-1:0] sum;
            reg        [UQ-1:0] ssq;
            reg        [UQ-1:0] sxy;
            reg        [UQ-1:0] sxx;
            reg signed [DW-1:0] vmin, vmax, vfirst, vlast;

            // Full-width products: a narrower signed product that is added to
            // an unsigned accumulator is zero-extended (not sign-extended) by
            // 1364 mixed-signedness rules, which turns sum(t*x) into garbage.
            // Widening the products to UQ keeps the bit pattern exact.
            wire signed [UQ-1:0] x2 = x * x;
            wire signed [UQ-1:0] xt = x * $signed({1'b0, cnt});
            wire        [UQ-1:0] tt = cnt * cnt;

            always @(posedge clk) begin
                if (!rst_n || clr) begin
                    sum    <= {SW{1'b0}};
                    ssq    <= {UQ{1'b0}};
                    sxy    <= {UQ{1'b0}};
                    sxx    <= {UQ{1'b0}};
                    vmin   <= {DW{1'b0}};
                    vmax   <= {DW{1'b0}};
                    vfirst <= {DW{1'b0}};
                    vlast  <= {DW{1'b0}};
                end else if (s_valid) begin
                    // First sample of a window seeds the accumulators instead
                    // of adding to the previous window's totals.
                    if (cnt == 0) begin
                        sum    <= {{(SW-DW){x[DW-1]}}, x};
                        ssq    <= x2;
                        sxy    <= xt;
                        sxx    <= tt;
                        vmin   <= x;
                        vmax   <= x;
                        vfirst <= x;
                    end else begin
                        sum <= sum + x;
                        ssq <= ssq + x2;
                        sxy <= sxy + xt;
                        sxx <= sxx + tt;
                        if (x < vmin) vmin <= x;
                        if (x > vmax) vmax <= x;
                    end
                    if (cnt == N - 1) vlast <= x;
                end
            end

            assign o_sum  [g*(DW+AW+1) +: (DW+AW+1)] = {{(DW+AW+1-SW){sum[SW-1]}}, sum};
            assign o_sumsq[g*(2*DW+AW)  +: (2*DW+AW)] = {{(2*DW+AW-UQ){1'b0}}, ssq};
            // sum(t*x) is signed: sign-extend, not zero-extend.  ssq/sxx are
            // non-negative by construction, so zero-extension is exact there.
            assign o_sxy  [g*(2*DW+AW)  +: (2*DW+AW)] = {{(2*DW+AW-UQ){sxy[UQ-1]}}, sxy};
            assign o_sxx  [g*(2*DW+AW)  +: (2*DW+AW)] = {{(2*DW+AW-UQ){1'b0}}, sxx};
            assign o_min  [g*DW +: DW] = vmin;
            assign o_max  [g*DW +: DW] = vmax;
            assign o_first[g*DW +: DW] = vfirst;
            assign o_last [g*DW +: DW] = vlast;
        end
    endgenerate

endmodule

`default_nettype wire
