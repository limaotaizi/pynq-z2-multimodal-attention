`timescale 1ns / 1ps
`default_nettype none
// =============================================================================
// i2c_bb.v -- 用 AXI4-Lite 直接操纵两根 I2C 焊盘的"裸口"（B7 诊断/配置用）
//
//   为什么需要它：AXI IIC 核心只在 ARB_LOST / NACK 这两个**间接**结果里暴露
//   总线状态，既看不到引脚电平，也不能自己决定时序。ADAU1761 一直不 ACK 时，
//   这两条信息不足以区分三种可能：
//       (a) 引脚上根本没有上拉（线拉不上去）
//       (b) 编解码器被复位/没供电（线正常但没有器件应答）
//       (c) 地址不对（ADDR0/ADDR1 浮空）
//   本模块把 SDA/SCL 做成**软件可控的推挽/开漏口**，于是 (a)(b)(c) 都能直接读出来：
//       - 不驱动时读 STAT，两根线都读到 1  ⇒ 上拉存在，线是自由的
//       - 手工逐位发地址，看第 9 拍 SDA 被谁拉低 ⇒ 有器件应答
//   同一个口也就是一个完整的软件 I2C 主机，所以配置 ADAU1761 不再受 AXI IIC
//   的寄存器语义约束。
//
//   寄存器映射（字节地址，C_S_AXI_ADDR_WIDTH = 4 ⇒ 16 B）
//     0x00 CTRL      RW  [0]=SDA_OE [1]=SDA 电平 [2]=SCL_OE [3]=SCL 电平
//                        OE=1 时推挽驱动（电平由相邻位决定）；OE=0 时高阻，
//                        靠外部上拉拉高 —— 这就是开漏。软件两种都能模拟，
//                        所以"到底有没有上拉"这个问题也能被回答。
//     0x04 STAT      RO  [0]=sda_i [1]=scl_i [2]=sda_i 上一拍 [3]=scl_i 上一拍
//     0x08 SDA_EDGES RW  读=最近一次清零以来的 SDA 跳变数（16 位饱和），写任意值清零
//     0x0C SCL_EDGES RW  同上，SCL
//
//   ★ 200 MHz 下软件一次 mmap 读写约 1 us，所以 SCL 半周期 ≥ 2 us，
//     等效 ≤ 250 kHz，落在 ADAU1761 的 400 kHz 上限内。
//   ★ 引脚上 PULLTYPE 由 XDC 打开，这样 OE=0 时即使板上没有上拉也能读到稳定的 1。
// =============================================================================
module i2c_bb #(
    parameter integer C_S_AXI_ADDR_WIDTH = 4,
    parameter integer C_S_AXI_DATA_WIDTH = 32
)(
    input  wire                     clk,
    input  wire                     rst_n,

    // ---- 两根 I2C 焊盘（顶层 inout，IOBUF 在本模块内引出）----
    inout  wire                     sda_io,
    inout  wire                     scl_io,

    output wire [3:0]               dbg_led,

    // ---- AXI4-Lite 从口 ----
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

    // ==================================================================== 焊盘
    reg  sda_oe_r, sda_lvl_r, scl_oe_r, scl_lvl_r;
    wire sda_i, scl_i;

    IOBUF u_sda (
        .O  (sda_i),
        .IO (sda_io),
        .I  (sda_lvl_r),
        .T  (~sda_oe_r)
    );
    IOBUF u_scl (
        .O  (scl_i),
        .IO (scl_io),
        .I  (scl_lvl_r),
        .T  (~scl_oe_r)
    );

    // 引脚输入先各打两拍再用：跨到同步逻辑里，也避免边沿计数抖动
    (* ASYNC_REG = "TRUE" *) reg sda_d1, sda_d2, scl_d1, scl_d2;
    always @(posedge clk) begin
        if (!rst_n) begin
            sda_d1 <= 1'b1; sda_d2 <= 1'b1;
            scl_d1 <= 1'b1; scl_d2 <= 1'b1;
        end else begin
            sda_d1 <= sda_i; sda_d2 <= sda_d1;
            scl_d1 <= scl_i; scl_d2 <= scl_d1;
        end
    end

    // 边沿计数（16 位饱和；写 0x08/0x0C 清零）
    reg [15:0] sda_edge_r, scl_edge_r;
    wire sda_evt = sda_d2 ^ sda_d1;   // d1 是上一拍，d2 是当前拍采样
    wire scl_evt = scl_d2 ^ scl_d1;

    // ==================================================================== AXI4-Lite 从口
    reg  [C_S_AXI_ADDR_WIDTH-1:0] awaddr_r;
    reg  [31:0]                   wdata_r;
    reg  [3:0]                    wstrb_r;
    reg                           aw_hit, w_hit, bvalid_r;

    wire wr_commit = aw_hit & w_hit & ~bvalid_r;

    assign s_axi_awready = ~aw_hit & ~wr_commit;
    assign s_axi_wready  = ~w_hit  & ~wr_commit;
    assign s_axi_bvalid  = bvalid_r;
    assign s_axi_bresp   = 2'b00;

    always @(posedge clk) begin
        if (!rst_n) begin
            aw_hit <= 1'b0; w_hit <= 1'b0; bvalid_r <= 1'b0;
        end else begin
            if (s_axi_awvalid && s_axi_awready) begin
                aw_hit   <= 1'b1;
                awaddr_r <= s_axi_awaddr;
            end
            if (s_axi_wvalid && s_axi_wready) begin
                w_hit   <= 1'b1;
                wdata_r <= s_axi_wdata;
                wstrb_r <= s_axi_wstrb;
            end
            if (wr_commit) begin
                aw_hit   <= 1'b0;
                w_hit    <= 1'b0;
                bvalid_r <= 1'b1;
            end else if (bvalid_r && s_axi_bready) begin
                bvalid_r <= 1'b0;
            end
        end
    end

    wire [C_S_AXI_ADDR_WIDTH-3:0] wword = awaddr_r[C_S_AXI_ADDR_WIDTH-1:2];
    wire ctrl_wr  = wr_commit && (wword == 'd0);
    wire sda_clr  = wr_commit && (wword == 'd2);
    wire scl_clr  = wr_commit && (wword == 'd3);

    always @(posedge clk) begin
        if (!rst_n) begin
            sda_oe_r  <= 1'b0;
            sda_lvl_r <= 1'b1;
            scl_oe_r  <= 1'b0;
            scl_lvl_r <= 1'b1;
        end else if (ctrl_wr) begin
            sda_oe_r  <= wdata_r[0];
            sda_lvl_r <= wdata_r[1];
            scl_oe_r  <= wdata_r[2];
            scl_lvl_r <= wdata_r[3];
        end
    end

    always @(posedge clk) begin
        if (!rst_n) begin
            sda_edge_r <= 16'd0;
            scl_edge_r <= 16'd0;
        end else begin
            if (sda_clr)       sda_edge_r <= 16'd0;
            else if (sda_evt && sda_edge_r != 16'hFFFF) sda_edge_r <= sda_edge_r + 16'd1;

            if (scl_clr)       scl_edge_r <= 16'd0;
            else if (scl_evt && scl_edge_r != 16'hFFFF) scl_edge_r <= scl_edge_r + 16'd1;
        end
    end

    // ---- 读通道：两拍读，与 ts_top 一致 ----
    reg  [C_S_AXI_ADDR_WIDTH-1:0] araddr_r2;
    reg                           rd_pend;
    reg                           rvalid_r;
    reg  [31:0]                   rdata_r;
    wire rd_start = s_axi_arvalid & s_axi_arready;

    assign s_axi_arready = ~rvalid_r & ~rd_pend;
    assign s_axi_rvalid  = rvalid_r;
    assign s_axi_rresp   = 2'b00;
    assign s_axi_rdata   = rdata_r;

    always @(posedge clk) begin
        if (!rst_n) begin
            rvalid_r  <= 1'b0;
            rd_pend   <= 1'b0;
            araddr_r2 <= {C_S_AXI_ADDR_WIDTH{1'b0}};
        end else begin
            if (rd_start) begin
                araddr_r2 <= s_axi_araddr;
                rd_pend   <= 1'b1;
            end else if (rd_pend) begin
                rd_pend   <= 1'b0;
            end
            if (rd_pend)                        rvalid_r <= 1'b1;
            else if (rvalid_r && s_axi_rready)  rvalid_r <= 1'b0;
        end
    end

    wire [31:0] stat_w;
    // STAT：[0]=scl_i 当前 [1]=sda_i 当前 [2]=scl_i 上一拍 [3]=sda_i 上一拍
    //       [4]=scl_oe          [5]=sda_oe
    // 注意：下面是拼接，最右边的是 bit0，所以 bit0 是 scl_d2 不是 sda_d2。
    // 早期注释写反了，2026-10-20 上板读数因此全部对调，以本注释为准。
    assign stat_w = {26'h0,
                     sda_oe_r, scl_oe_r,
                     sda_d1, scl_d1,
                     sda_d2, scl_d2};

    reg [31:0] rdata_r_next;
    always @(*) begin
        case (araddr_r2[C_S_AXI_ADDR_WIDTH-1:2])
            'd0:     rdata_r_next = {28'h0, scl_lvl_r, scl_oe_r, sda_lvl_r, sda_oe_r};
            'd1:     rdata_r_next = stat_w;
            'd2:     rdata_r_next = {16'h0, sda_edge_r};
            'd3:     rdata_r_next = {16'h0, scl_edge_r};
            default: rdata_r_next = 32'hDEAD_BEEF;
        endcase
    end

    always @(posedge clk) if (rd_pend) rdata_r <= rdata_r_next;

    // ==================================================================== 调试灯
    // LD0/LD1 = 当前 SDA/SCL 电平（亮=高），LD2/LD3 = 两个跳变计数器在动
    assign dbg_led[0] = sda_d2;
    assign dbg_led[1] = scl_d2;
    assign dbg_led[2] = sda_evt;
    assign dbg_led[3] = scl_evt;

endmodule

`default_nettype wire
