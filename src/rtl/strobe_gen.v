`timescale 1ns / 1ps
`default_nettype none
// =============================================================================
// strobe_gen.v —— 四路采样节拍发生器（**仅用于自台架，不是方案的正式部分**）
//
//   板子上现在没有任何真实传感器，若不给个节拍源，"采集前端"就只能读一个
//   计数器，证明不了捕获/仲裁/打戳中的任何一件事。本模块用可写分频比在
//   200 MHz 上合成四路节拍，让整条链路在**没有外设**的情况下也能端到端跑。
//
//   ★ 与方案三 §3.1 的关系：§3.1 明说"只对 256 Hz 用精确分频产生基准节拍，
//     其余三路的采样点用到达时刻戳记记录真实间隔，不做分频"。
//     所以本模块**只是台架**，真接传感器时应当由 SRC 寄存器切回外部引脚。
//
//   分频比是 200 MHz 计数，四路默认值照 §2.1 的目标速率：
//     EEG 256 Hz →   781,250（精确）      眼动 150 Hz → 1,333,333（→ 150.000038 Hz，
//     GSR  50 Hz → 4,000,000（精确）      误差 +0.25 ppm）
//     AU   40 Hz → 5,000,000（精确）
//   0.25 ppm 比板载晶振本身（ADAU1761 那档是 1.6e-2）小五个数量级，够用；
//   但数字是多少就写多少，不要含混成"可忽略"。
// =============================================================================
module strobe_gen #(
    parameter integer NW = 4,
    parameter integer DW = 32
)(
    input  wire              clk,
    input  wire              rst_n,
    input  wire              run,           // = CTRL[0]
    input  wire [NW-1:0]     en,            // 逐路使能（此处直接接 SRC）
    input  wire [NW*DW-1:0]  div_flat,      // 逐路分频比（计数），0 视为停
    output reg  [NW-1:0]     s_valid        // 单周期脉冲
);
    reg [DW-1:0] cnt [0:NW-1];
    // ★ div-1 必须提前寄存（2026-10-18）。
    //   原写法 `cnt + 1 >= div` 把「32 位自增 + 32 位比较」串成一条组合路径，
    //   在 200 MHz（5 ns）下实测 6.26 ns（WNS = -1.256 ns，605 个端点违例）。
    //   把 div-1 寄存后，判据变成 `cnt == div_m1`（纯等值比较，无进位链）；
    //   在「cnt 从 0 数到 div-1 就清零」的前提下，两种写法逐拍等价。
    //   div 只在 AXI 写寄存器时变化，晚一拍生效对软件不可见。
    reg [DW-1:0] div_m1 [0:NW-1];
    integer i;

    always @(posedge clk) begin
        if (!rst_n) begin
            for (i = 0; i < NW; i = i + 1) div_m1[i] <= {DW{1'b0}};
        end else begin
            for (i = 0; i < NW; i = i + 1)
                div_m1[i] <= div_flat[i*DW +: DW] - 1'b1;
        end
    end

    always @(posedge clk) begin
        if (!rst_n) begin
            s_valid <= {NW{1'b0}};
            for (i = 0; i < NW; i = i + 1) cnt[i] <= {DW{1'b0}};
        end else begin
            for (i = 0; i < NW; i = i + 1) begin
                if (!run || !en[i] || (div_flat[i*DW +: DW] == {DW{1'b0}})) begin
                    s_valid[i] <= 1'b0;
                    cnt[i]     <= {DW{1'b0}};
                end else if (cnt[i] == div_m1[i]) begin
                    s_valid[i] <= 1'b1;          // 计满一拍 ⇒ 出一个节拍
                    cnt[i]     <= {DW{1'b0}};
                end else begin
                    s_valid[i] <= 1'b0;
                    cnt[i]     <= cnt[i] + 1'b1;
                end
            end
        end
    end

endmodule

`default_nettype wire
