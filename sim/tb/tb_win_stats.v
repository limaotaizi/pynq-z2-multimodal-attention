`timescale 1ns/1ps
`default_nettype none
// Direct testbench for win_stats: C=3, DW=8, N=5.
// Compares all exported sufficient statistics against integer arithmetic in
// the testbench, including negative samples (the case that catches signedness
// mistakes in x*x and in min/max).
module tb_win_stats;

    localparam integer C = 3, DW = 8, N = 5, AW = 16;
    localparam integer SWW = DW + AW + 1;      // o_sum word width
    localparam integer UQW = 2*DW + AW;        // o_sumsq word width

    reg clk = 0, rst_n = 0, clr = 0, s_valid = 0;
    reg [C*DW-1:0] s_data = 0;

    wire done;
    wire [C*SWW-1:0] o_sum;
    wire [C*UQW-1:0] o_sumsq, o_sxy, o_sxx;
    wire [C*DW-1:0]  o_min, o_max, o_first, o_last;
    wire [AW-1:0]    o_count;

    win_stats #(.C(C), .DW(DW), .N(N), .AW(AW)) dut (
        .clk(clk), .rst_n(rst_n), .clr(clr), .s_valid(s_valid), .s_data(s_data),
        .done(done), .o_sum(o_sum), .o_sumsq(o_sumsq),
        .o_min(o_min), .o_max(o_max), .o_first(o_first), .o_last(o_last),
        .o_sxy(o_sxy), .o_sxx(o_sxx), .o_count(o_count));

    always #5 clk = ~clk;

    integer sum_e   [0:C-1];
    integer ssq_e   [0:C-1];
    integer sxy_e   [0:C-1];
    integer sxx_e   [0:C-1];
    integer min_e   [0:C-1];
    integer max_e   [0:C-1];
    integer first_e [0:C-1];
    integer last_e  [0:C-1];

    integer i, c, errs = 0, rounds = 0;
    integer x;

    task drive_sample(input integer idx);
        begin
            for (c = 0; c < C; c = c + 1) begin
                x = ((idx * 7 + c * 13) % 256) - 128;
                s_data[c*DW +: DW] = x;
                sum_e[c]   = sum_e[c] + x;
                ssq_e[c]   = ssq_e[c] + x*x;
                sxy_e[c]   = sxy_e[c] + idx*x;
                sxx_e[c]   = sxx_e[c] + idx*idx;
                if (idx == 0) begin
                    min_e[c] = x; max_e[c] = x; first_e[c] = x;
                end else begin
                    if (x < min_e[c]) min_e[c] = x;
                    if (x > max_e[c]) max_e[c] = x;
                end
                if (idx == N-1) last_e[c] = x;
            end
            s_valid = 1;
            @(posedge clk); #1;
            s_valid = 0;
        end
    endtask

    task check_window;
        begin
            for (c = 0; c < C; c = c + 1) begin
                if ($signed(o_sum[c*SWW +: SWW]) !== sum_e[c]) begin
                    $display("MISMATCH sum[%0d] got %0d want %0d", c,
                             $signed(o_sum[c*SWW +: SWW]), sum_e[c]);
                    errs = errs + 1;
                end
                if (o_sumsq[c*UQW +: UQW] !== ssq_e[c]) begin
                    $display("MISMATCH sumsq[%0d] got %0d want %0d", c,
                             o_sumsq[c*UQW +: UQW], ssq_e[c]);
                    errs = errs + 1;
                end
                if ($signed(o_sxy[c*UQW +: UQW]) !== sxy_e[c]) begin
                    $display("MISMATCH sxy[%0d] got %0d want %0d", c,
                             $signed(o_sxy[c*UQW +: UQW]), sxy_e[c]);
                    errs = errs + 1;
                end
                if (o_sxx[c*UQW +: UQW] !== sxx_e[c]) begin
                    $display("MISMATCH sxx[%0d] got %0d want %0d", c,
                             o_sxx[c*UQW +: UQW], sxx_e[c]);
                    errs = errs + 1;
                end
                if ($signed(o_min[c*DW +: DW]) !== min_e[c] ||
                    $signed(o_max[c*DW +: DW]) !== max_e[c] ||
                    $signed(o_first[c*DW +: DW]) !== first_e[c] ||
                    $signed(o_last[c*DW +: DW]) !== last_e[c]) begin
                    $display("MISMATCH min/max/first/last[%0d]: %0d/%0d/%0d/%0d want %0d/%0d/%0d/%0d",
                             c, $signed(o_min[c*DW +: DW]), $signed(o_max[c*DW +: DW]),
                             $signed(o_first[c*DW +: DW]), $signed(o_last[c*DW +: DW]),
                             min_e[c], max_e[c], first_e[c], last_e[c]);
                    errs = errs + 1;
                end
            end
        end
    endtask

    task clear_expect;
        begin
            for (c = 0; c < C; c = c + 1) begin
                sum_e[c] = 0; ssq_e[c] = 0; sxy_e[c] = 0; sxx_e[c] = 0;
                min_e[c] = 0; max_e[c] = 0; first_e[c] = 0; last_e[c] = 0;
            end
        end
    endtask

    initial begin
        clear_expect;
        repeat (3) @(posedge clk);
        rst_n = 1;
        repeat (2) @(posedge clk);
        // Park mid-cycle: assigning s_valid in the same time slot as a clock
        // edge races the DUT and silently adds one phantom sample.
        @(negedge clk);

        // ---- window 1.  done is registered on the Nth sample's edge, so it
        //      is already high when drive_sample returns; no extra edge here
        //      (that would consume the cycle and clear it).
        for (i = 0; i < N; i = i + 1) drive_sample(i);
        if (!done) begin $display("FAIL: done not asserted"); errs = errs + 1; end
        check_window;
        rounds = rounds + 1;

        // ---- window 2: same pattern, checks counter wrap and last/first
        clear_expect;
        for (i = 0; i < N; i = i + 1) drive_sample(i);
        if (!done) begin $display("FAIL: done not asserted (w2)"); errs = errs + 1; end
        check_window;
        rounds = rounds + 1;

        // ---- mid-window clear
        clear_expect;
        for (i = 0; i < 2; i = i + 1) drive_sample(i);
        clr = 1; @(posedge clk); #1; clr = 0;
        clear_expect;
        if (o_count !== 0) begin
            $display("FAIL: clr did not zero the counter (%0d)", o_count);
            errs = errs + 1;
        end
        for (i = 0; i < N; i = i + 1) drive_sample(i);
        if (!done) begin $display("FAIL: done after clr"); errs = errs + 1; end
        check_window;

        if (errs == 0)
            $display("ALL PASS  win_stats (%0d windows + clr check)", rounds);
        else
            $display("FAIL  win_stats: %0d mismatches", errs);
        $finish;
    end

endmodule

`default_nettype wire
