// =============================================================================
// tb_frac_div.v -- 验证 ADAU1761 分数分频校正（设计 §6 的量化结论）
//
// 仿真的是**分频比**，不是墙钟时长：
//   输入节拍每 TICK_DIV 个 clk 来一次，等价于 f_in = f_clk / TICK_DIV。
//   4 s 的 ADAU 时间 = 48828 x 4 = 195,312 个输入节拍 —— 与绝对频率无关，
//   所以这里只要跑满 195,312 个节拍，漂移量就和真实 4 s 完全一致。
//
// 判据（设计 §6 的原话）：
//   不校正：4 s 内漂 3,313 个 48 kHz 样本 = 69.0 ms = 17.7 个 256 Hz EEG 点
//   校正后：4 s 内漂 <= 1 个样本（1 ppm 级别的 inc 量化误差）
// =============================================================================
`timescale 1ns / 1ps

module tb_frac_div;

    localparam integer TICK_DIV = 20;          // 每 20 个 clk 一个 ADAU 节拍
    localparam integer N_TICK   = 195312;      // 4 s x 48828 Hz

    reg clk = 0, rst = 1;
    always #2.5 clk = ~clk;                    // 200 MHz

    reg  in_tick = 0;
    integer tick_cnt = 0;

    // 校正臂
    wire        c_tick;
    wire [31:0] c_phase, c_kept, c_nin;
    // 直通臂（inc = 2^32，复现缺陷）
    wire        p_tick;
    wire [31:0] p_phase, p_kept, p_nin;

    frac_div u_corr (
        .clk(clk), .rst(rst), .in_tick(in_tick),
        .inc(32'd4222135459),                  // 48000/48828 in Q32
        .out_tick(c_tick), .phase(c_phase), .kept(c_kept), .n_in(c_nin)
    );

    frac_div u_pass (
        .clk(clk), .rst(rst), .in_tick(in_tick),
        .inc(32'hFFFFFFFF),                    // 直通：最接近 2^32（每拍都溢出）
        .out_tick(p_tick), .phase(p_phase), .kept(p_kept), .n_in(p_nin)
    );

    // ---- 输入节拍
    integer div = 0;
    always @(posedge clk) begin
        if (rst) begin
            div <= 0; in_tick <= 0;
        end else begin
            if (div == TICK_DIV - 1) begin
                div     <= 0;
                in_tick <= 1'b1;
                tick_cnt <= tick_cnt + 1;
            end else begin
                div     <= div + 1;
                in_tick <= 1'b0;
            end
        end
    end

    // ---- 1 s 边界记录
    integer kept_1s [1:4];
    integer shown = 0;
    always @(posedge clk) begin
        if (c_nin == 48828  * 1) kept_1s[1] = c_kept;
        if (c_nin == 48828  * 2) kept_1s[2] = c_kept;
        if (c_nin == 48828  * 3) kept_1s[3] = c_kept;
        if (c_nin == 48828  * 4) kept_1s[4] = c_kept;
        if (p_nin == 48828  * 4 && shown == 0) begin
            shown = 1;
            $display("  pass 臂在 4 s 处 n_in=%0d kept=%0d", p_nin, p_kept);
        end
    end

    integer err, i;
    integer cerr;
    initial begin
        repeat (5) @(posedge clk);
        rst = 0;
        wait (c_nin == N_TICK);
        repeat (5) @(posedge clk);

        $display("");
        $display("========== ADAU1761 分数分频校正 ==========");
        $display("  输入节拍 %0d 个（= 48828 Hz x 4 s）", c_nin);
        $display("");
        cerr = c_kept - 192000;
        $display("  [校正] inc = 0x%08x   输出 %0d 个（目标 192000）  误差 %0d",
                 32'd4222135459, c_kept, cerr);
        $display("  [直通] inc = 0xFFFFFFFF 输出 %0d 个", p_kept);
        cerr = p_kept - 192000;
        $display("        漂移 %0d 个样本 = %.1f ms = %.2f 个 256 Hz EEG 点",
                 cerr,
                 (p_kept - 192000) / 48000.0 * 1000.0,
                 (p_kept - 192000) / 48000.0 * 256.0);
        $display("  逐秒误差（校正臂）：");
        for (i = 1; i <= 4; i = i + 1) begin
            $display("    t=%0d s  kept=%0d  误差 %0d", i, kept_1s[i],
                     kept_1s[i] - 48000 * i);
        end

        err = c_kept - 192000;   // 有符号赋给 integer
        $display("");
        if (err >= -1 && err <= 1)
            $display("  PASS  校正臂 4 s 误差 %0d 个样本（<= 1 ppm 级）", err);
        else
            $display("  FAIL  校正臂 4 s 误差 %0d 个样本", err);
        // inc 最大只能写 2^32-1，所以直通臂恰好少一个节拍（195311）
        if (p_kept >= 195311)
            $display("  PASS  直通臂复现缺陷：%0d - 192000 = %0d",
                     p_kept, p_kept - 192000);
        else
            $display("  FAIL  直通臂 kept=%0d，期望 195311", p_kept);
        if (err >= -1 && err <= 1 && p_kept >= 195311)
            $display("ALL PASS");
        $finish;
    end

    // 超时保护
    initial begin
        #200000000;
        $display("TIMEOUT: n_in=%0d", c_nin);
        $finish;
    end

endmodule
