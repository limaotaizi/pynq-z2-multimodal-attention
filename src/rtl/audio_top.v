`timescale 1ns / 1ps
`default_nettype none
// =============================================================================
// audio_top.v -- ADAU1761 I2S 到达时刻的"打戳口"顶层（B7/B8）
//
//   这就是方案三"任何一路异步采样到达都打上同一个 200 MHz 时间戳"的
//   **实物通路**，而不是纸面主张：
//
//     编解码器 ──BCLK/LRCLK/SDATA──▶ i2s_rx ──▶ audio_cdc ──▶ ts_top.s_valid[0]
//                                                              │
//                                            PS 读 FIFO (0x10/0x18) ◀┘
//
//   ★ 只用通路 0：SRC 寄存器写 0xE（bit0 = 0 走外部引脚，bit1..3 = 1 走
//     内部节拍发生器），这样另外三路仍然可以独立自测。
//
//   ★ MCLK 不在这里产生 —— 它由 block design 里的 clk_wiz 出 12.288 MHz
//     直接送 audio_clk 引脚。原因：时钟只应从一个地方来，否则 MMCM 与
//     本模块的时钟树会各说各话。
//
//   ★ 本模块**不产生复位以外的任何 200 MHz 逻辑**：i2s_rx 在 BCLK 域，
//     audio_cdc 只做两拍同步 + 边沿检测。整条新增时序压力不到 100 个 LUT。
// =============================================================================
module audio_top #(
    parameter integer TW = 48,
    parameter integer NW = 4,
    parameter integer C_S_AXI_ADDR_WIDTH = 7,
    parameter integer C_S_AXI_DATA_WIDTH = 32
)(
    input  wire                     clk,
    input  wire                     rst_n,

    // ---- 编解码器侧（全部异步于 clk）----
    input  wire                     bclk,
    input  wire                     lrclk,
    input  wire                     sd,

    // ---- 诊断 ----
    // 已收音频帧数不单独出端口：同一个数可以从 ts_top 的 ENQ_COUNT(0x14)
    // 读到（SRC=0xE 时 ch0 计数就是音频帧数），多一个 BD 端口就要多找一个
    // 未连接的输出引脚，validate_bd_design 会为此报 critical warning。
    output wire [3:0]               dbg_led,

    // ---- AXI4-Lite 从口（与 ts_top 完全一致）----
    input  wire [C_S_AXI_ADDR_WIDTH-1:0] s_axi_awaddr,
    input  wire                          s_axi_awvalid,
    output wire                          s_axi_awready,
    input  wire [31:0]                   s_axi_wdata,
    input  wire [3:0]                    s_axi_wstrb,
    input  wire                          s_axi_wvalid,
    output wire                          s_axi_wready,
    output wire [1:0]                    s_axi_bresp,
    output wire                          s_axi_bvalid,
    input  wire                          s_axi_bready,
    input  wire [C_S_AXI_ADDR_WIDTH-1:0] s_axi_araddr,
    input  wire                          s_axi_arvalid,
    output wire                          s_axi_arready,
    output wire [31:0]                   s_axi_rdata,
    output wire [1:0]                    s_axi_rresp,
    output wire                          s_axi_rvalid,
    input  wire                          s_axi_rready
);

    wire        aud_ev;
    wire [31:0] aud_data;
    wire [15:0] aud_cnt;

    audio_cdc #(.DW(16), .SLOT(32)) u_cdc (
        .clk         (clk),
        .rst_n       (rst_n),
        .bclk        (bclk),
        .lrclk       (lrclk),
        .sd          (sd),
        .ev          (aud_ev),
        .sample_data (aud_data),
        .sample_cnt  (aud_cnt)
    );

    // 只有通路 0 接真实音频；1..3 在 SRC=0xE 下走 ts_top 的内部发生器。
    wire [NW-1:0] s_valid = {{(NW-1){1'b0}}, aud_ev};

    wire        m_valid;
    wire [$clog2(NW)-1:0] m_mod;
    wire [TW-1:0] m_ts;

    ts_top #(.TW(TW), .NW(NW)) u_ts (
        .clk        (clk),
        .rst_n      (rst_n),
        .s_valid    (s_valid),
        .m_valid    (m_valid),
        .m_mod      (m_mod),
        .m_ts       (m_ts),
        .dbg_led    (dbg_led),
        .s_axi_awaddr  (s_axi_awaddr),
        .s_axi_awvalid (s_axi_awvalid),
        .s_axi_awready (s_axi_awready),
        .s_axi_wdata   (s_axi_wdata),
        .s_axi_wstrb   (s_axi_wstrb),
        .s_axi_wvalid  (s_axi_wvalid),
        .s_axi_wready  (s_axi_wready),
        .s_axi_bresp   (s_axi_bresp),
        .s_axi_bvalid  (s_axi_bvalid),
        .s_axi_bready  (s_axi_bready),
        .s_axi_araddr  (s_axi_araddr),
        .s_axi_arvalid (s_axi_arvalid),
        .s_axi_arready (s_axi_arready),
        .s_axi_rdata   (s_axi_rdata),
        .s_axi_rresp   (s_axi_rresp),
        .s_axi_rvalid  (s_axi_rvalid),
        .s_axi_rready  (s_axi_rready)
    );

endmodule
`default_nettype wire
