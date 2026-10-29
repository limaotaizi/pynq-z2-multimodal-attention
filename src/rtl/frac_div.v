// =============================================================================
// frac_div.v -- ADAU1761 采样节拍的分数分频校正（设计 §6 / §7 第 10 项）
//
// 问题：板载 ADAU1761 的 I2S 节拍实测偏高约 17,250 ppm。
//       4 s 窗内累积漂移 = 4 s x 17,250e-6 = 69 ms
//                       = 69 ms / 3.906 ms ≈ 17.7 个 256 Hz EEG 采样点
//       晶振级 4.1-50 ppm 在 4 s 内只有 16-200 us（< 0.05 点）=> 差约 345 倍。
//
// 做法：不改 ADAU 的时钟，而是在 PL 里把它的 in_tick **分数分频**到名义网格：
//       每来一个 in_tick，相位累加 inc（Q32）；
//       累加器溢出即输出一个 out_tick，并扣掉 2^32。
//       平均输出率 = f_in * inc / 2^32，用 32 位 inc 可把误差压到 < 1 ppm。
//
// ★ **校正量本身可读**：phase 是当前残余相位（Q32，单位=输入采样周期），
//   n_in / kept 是输入、输出样本计数。PL 时间戳打在每个 out_tick 上；
//   软件用 (n_in - kept) 与 phase 就能还原出可观测的 Δt。
//
// 寄存器语义（Q32）：
//   inc = round(f_out / f_in * 2^32)
//   例：f_out = 48,000 Hz，f_in = 48,828 Hz（17,250 ppm 偏高）
//       inc ≈ 0.982913 x 2^32（见 frac_div_model.py）
//   inc = 2^32 表示直通（不校正）——用来复现缺陷。
//
// 时序：in_tick 与 clk 同步（I2S 的 LRCLK 在 PL 里先过一个同步器）。
// 全部是 32 位加减，200 MHz 下不构成关键路径。
// =============================================================================
`timescale 1ns / 1ps

module frac_div (
    input  wire        clk,
    input  wire        rst,
    input  wire        in_tick,      // ADAU1761 的采样节拍（已同步到 clk）
    input  wire [31:0] inc,          // Q32 分频比；2^32 = 直通
    output reg         out_tick,     // 校正后的名义网格节拍，单拍宽
    output reg  [31:0] phase,        // 残余相位（Q32，1 LSB = 2^-32 个输入周期）
    output reg  [31:0] kept,         // 已输出的样本数
    output reg  [31:0] n_in          // 已收到的输入样本数
);

    reg  [32:0] acc;                 // 33 位：装得下 acc + inc 再看进位
    wire [32:0] sum = acc + {1'b0, inc};

    always @(posedge clk) begin
        if (rst) begin
            acc      <= 33'd0;
            phase    <= 32'd0;
            kept     <= 32'd0;
            n_in     <= 32'd0;
            out_tick <= 1'b0;
        end else begin
            out_tick <= 1'b0;
            if (in_tick) begin
                n_in <= n_in + 32'd1;
                phase <= sum[31:0];
                if (sum[32]) begin
                    acc      <= {1'b0, sum[31:0]};   // 扣掉 2^32
                    out_tick <= 1'b1;
                    kept     <= kept + 32'd1;
                end else begin
                    acc   <= sum;
                end
            end
        end
    end

endmodule
