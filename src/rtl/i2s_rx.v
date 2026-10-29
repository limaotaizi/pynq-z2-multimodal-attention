`timescale 1ns / 1ps
`default_nettype none
// =============================================================================
// i2s_rx.v —— I2S 接收前端的"打戳口"（ADAU1761 → ts_top）
//
//   为什么要有这一块：方案三的主张是"任何一路异步采样到达都打上同一个
//   200 MHz 时间戳"。EEG/眼动/GSR 在本项目里都是离线数据，板上唯一真正
//   异步、且时钟与 PL 无关的源就是音频编解码器 ADAU1761。它的 MCLK 由
//   PL 给（12.288 MHz 量级），BCLK/LRCLK 由它自己产生，所以**音频的采样
//   时刻和 200 MHz 计数器之间没有任何固定相位关系** —— 这正是要测的东西。
//
//   本模块只做三件事：
//     1. 在 BCLK 域里把 SDATA 移位成左右各 DW 位的样本；
//     2. 每帧（一个 LRCLK 周期）产出一个**单 BCLK 宽**的 sample_pulse；
//     3. 把该脉冲交给 200 MHz 域（调用方打两拍同步），送 ts_top 的 s_valid。
//
//   ★ BCLK 3.072 MHz ⇒ 单拍 325 ns，比 200 MHz 目标域的一拍宽 65 倍，
//     两拍同步器一定能采到，**不需要握手/翻转位**。这是本模块刻意选择的
//     信号形态；换成"一个 200 MHz 拍宽"的窄脉冲就会漏样本。
//
//   ★ I2S 相位：LRCLK 跳变后**第二拍**才是 MSB，所以每槽的第 1..DW 拍
//     才是数据位（第 0 拍是上一槽的 LSB）。槽宽 SLOT 默认 32 位。
//
//   ★ 若 BCLK 停摆：帧计数器不再增加，sample_pulse 也不再出现 —— 上层
//     看到的是"没有新样本"，而不是"伪样本"，这对时序测量是必需的。
//
//   ★ 上电后的**第一帧不保证对齐**（左槽开始前还没有 LRCLK 边沿来对齐
//     位计数），从第一个下降沿之后的所有帧都是对齐的。所以 sample_pulse
//     只在"见过高电平之后又回低"时才产生，第一帧不会被当成样本。
//
//   端口：
//     bclk, lrclk, sd   ← 编解码器（三者同源，本模块内部不跨时钟域）
//     sample_pulse      → 每帧一个 BCLK 宽脉冲（仍在 BCLK 域！）
//     sample_data       → {R[DW-1:0], L[DW-1:0]}，与 sample_pulse 同拍更新
//     frame_cnt         → 已收帧数，仅做诊断
// =============================================================================
module i2s_rx #(
    parameter integer DW   = 16,   // 每声道位数（ADAU1761 常用 16/24）
    parameter integer SLOT = 32    // 每声道槽位数（BCLK/帧 = 2*SLOT）
)(
    input  wire             bclk,
    input  wire             lrclk,
    input  wire             sd,

    output reg              sample_pulse,
    output reg  [2*DW-1:0]  sample_data,
    output reg  [15:0]      frame_cnt
);

    // 位宽常量：Verilog-2001 不允许直接对 integer parameter 做位选，
    // 所以先转成定宽 localparam。
    localparam [5:0] SLOT_C = SLOT;
    localparam [5:0] DW_C   = DW;
    localparam [5:0] SLOT_M = SLOT - 1;

    // ★ 本模块没有复位端口：它跨在编解码器的自由运行 BCLK 上，任何来自
    //   200 MHz 域的复位在这里都是新的一次跨时钟域。改用**上电初值**
    //   （Vivado 把它编成 FF 的 INIT 值，仿真里表现为 0），状态随后由
    //   LRCLK 边沿自我对齐。
    reg        lr_d    = 1'b0;
    reg        seen_hi = 1'b0;      // 至少见过一次右声道槽，才允许出样本
    reg  [5:0] bitcnt  = 6'd0;      // 槽内位计数 0 .. SLOT-1
    reg  [DW-1:0] lsh = {DW{1'b0}}, rsh = {DW{1'b0}};

    initial begin
        sample_pulse = 1'b0;
        sample_data  = {(2*DW){1'b0}};
        frame_cnt    = 16'd0;
    end

    wire lr_edge = lr_d ^ lrclk;
    // 槽内第 0 拍是上一位的延迟拍（非数据），数据在 1..DW 拍。
    // bitcnt 在 LRCLK 边沿的那一拍才清 0，所以"采样到第 j 拍"时 bitcnt=j-1：
    // 取 bitcnt 0..DW-1 恰好就是数据位 1..DW。
    wire cap = (bitcnt <= DW_C - 6'd1);

    always @(posedge bclk) begin
        lr_d <= lrclk;

        // 槽内位计数：LRCLK 每次跳变都清 0
        if (lr_edge)
            bitcnt <= 6'd0;
        else if (bitcnt == SLOT_M)
            bitcnt <= 6'd0;
        else
            bitcnt <= bitcnt + 6'd1;

        if (cap) begin
            if (lrclk == 1'b0) lsh <= {lsh[DW-2:0], sd};
            else               rsh <= {rsh[DW-2:0], sd};
        end

        if (lr_edge && lrclk) seen_hi <= 1'b1;

        sample_pulse <= 1'b0;
        // 只在一帧真正结束（LRCLK 由高回低）时打一拍脉冲：这样
        //   * 一帧恰好一个样本；
        //   * LRCLK 停摆时**不会**冒出伪样本（帧计数也停）。
        if (lr_edge && !lrclk && seen_hi) begin
            sample_data  <= {rsh, lsh};
            sample_pulse <= 1'b1;      // 单 BCLK 宽
            frame_cnt    <= frame_cnt + 16'd1;
        end
    end

endmodule
`default_nettype wire
