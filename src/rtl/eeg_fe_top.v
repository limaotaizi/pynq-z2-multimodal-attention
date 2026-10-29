`timescale 1ns / 1ps
`default_nettype none
// =============================================================================
// eeg_fe_top.v —— EEG 前端 AXI4-Lite 顶层（PYNQ-Z2 / XC7Z020）
//
//   PS 通过 SAMPLE 寄存器逐拍写入 {ch[5:0], int16 采样}，先进 128 深 FIFO，
//   eeg_fe 引擎按拍消化；每 62×1024 拍收一个窗，产出 310 个 log2(var)。
//
//   ★ 采样顺序无关：累加器按 (ch, band) 索引，状态按 (ch, band, stage) 索引，
//     所以 PS 端怎么排都能算对，只要"一拍一路通道、总拍数 = 62×1024"。
//     真实流式系统里这拍由 ADC/AXI-Stream 提供，本模块的 SAMPLE 口就是它的替身。
//
//   寄存器映射（字节地址，C_S_AXI_ADDR_WIDTH = 8 ⇒ 256 B 空间）
//     0x00 CTRL        RW  [0]=run [1]=state_clr [2]=acc_clr [3]=done_clr [4]=fifo_rst
//                          bit1..4 自清（写 1 只维持一拍）
//     0x04 STATUS      RO  [0]=busy [1]=done [2]=fifo_empty [3]=fifo_full
//                          [7:4]=0 [15:8]=fifo_level [16]=ovf_sticky
//     0x08 WIN_CNT     RO  已完成的窗数
//     0x0C BEAT_CNT    RO  当前窗已收拍数（0..63487）
//     0x10 SAMPLE      WO  写入即入队：{ch[5:0], sample[15:0]}
//     0x14 RES_INDEX   RW  结果下标 0..309，排列 c*5+band
//     0x18 RES_DATA    RO  该下标的 log2(var)，Q16.16
//     0x1C OVF         RO/W1C  [0]=FIFO 满时写入被丢（粘滞）
//     0x20 BUILD       RO  0x5EED_0001
//     0x24 GEOM        RO  {8'd0, NCH[7:0], NB[7:0], 8'd0}  = 0x003E_0500
//
//   ★ 单时钟域：与 ts_top 一致，全部逻辑跑在 200 MHz FCLK_CLK0 上。
// =============================================================================
module eeg_fe_top #(
    parameter integer NCH = 62,
    parameter integer NB  = 5,
    parameter integer WIN = 1024,
    parameter integer FIFO_AW = 7,                  // 128 深
    parameter integer C_S_AXI_ADDR_WIDTH = 8,
    parameter integer C_S_AXI_DATA_WIDTH = 32
)(
    input  wire                     clk,
    input  wire                     rst_n,

    // ---- 可选：外部采样流（与 SAMPLE 寄存器二选一，valid 优先）----
    input  wire                     ext_valid,
    input  wire [21:0]              ext_data,

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
    localparam integer NSAMP = NCH * WIN;

    // ==================================================================== 寄存器组
    reg  [31:0] ctrl_r;
    reg  [8:0]  res_idx_r;
    reg         ovf_sticky;

    wire run       = ctrl_r[0];
    wire state_clr = ctrl_r[1];
    wire acc_clr   = ctrl_r[2];
    wire done_clr  = ctrl_r[3];
    wire fifo_rst  = ctrl_r[4];

    // ==================================================================== AXI4-Lite 写通道
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

    // ---- 写译码：寄存 one-hot（wsel），与读通道的 rsel 同一手法 ----
    // ★ 2026-10-18：原来 ctrl_wr/samp_wr/ridx_wr/ovf_wr 都是
    //   wr_commit & (wword==n) 的组合式，于是 aw_hit_reg / w_hit_reg 这两个
    //   握手寄存器要各自拉一根线到每个目的寄存器的 CE 上。实测
    //   aw_hit_reg -> res_idx_r_reg[0]/CE = 0.83 ns 逻辑 + 5.20 ns 布线
    //   （横穿整个 pblock），-1.591 ns，是全设计最坏族。
    //   把译码寄存成 one-hot 之后，每个目的寄存器的 CE 只由**它自己的一位**
    //   wsel 驱动，placer 自然把这一位摆在它旁边；aw_hit/w_hit 的负载只剩
    //   wsel 这一个 10 位寄存器。写通道晚一拍无副作用：wdata_r 与 wsel 在
    //   同一个沿更新，所以它们天然对齐。
    wire [5:0] wword = awaddr_r[C_S_AXI_ADDR_WIDTH-1:2];

    reg [9:0] wsel;                       // bit0=CTRL bit4=SAMPLE bit5=RES_INDEX bit7=OVF
    always @(posedge clk) begin
        if (!rst_n) wsel <= 10'd0;
        else if (wr_commit)
            case (wword)
                6'd0:    wsel <= 10'h001;
                6'd4:    wsel <= 10'h010;
                6'd5:    wsel <= 10'h020;
                6'd7:    wsel <= 10'h080;
                default: wsel <= 10'd0;   // 未映射地址：不写任何东西
            endcase
        else wsel <= 10'd0;
    end

    always @(posedge clk) begin
        if (!rst_n)        ctrl_r <= 32'h0;
        else if (wsel[0])  ctrl_r <= wdata_r;
        else               ctrl_r <= ctrl_r & ~32'h0000_001E;   // bit1..4 自清
    end

    always @(posedge clk) begin
        if (!rst_n)        res_idx_r <= 9'd0;
        else if (wsel[5])  res_idx_r <= wdata_r[8:0];
    end

    // ==================================================================== 采样 FIFO
    wire        fifo_full, fifo_empty;
    wire [21:0] fifo_dout;
    wire        fifo_pop;
    reg  [FIFO_AW-1:0] wptr, rptr;
    reg  [FIFO_AW:0]   fcnt;

    assign fifo_empty = (fcnt == 0);
    assign fifo_full  = (fcnt == (1<<FIFO_AW));

    // ★ 2026-10-18：FIFO 写使能已由寄存的 wsel[4] 给出，FIFO 写**同拍**。
    //   实测 aw_hit_reg -> fcnt_reg[6]_replica 曾是 1.82 ns 逻辑 +
    //   3.44 ns 布线（-0.868 ns），现在是 FF -> 或 -> 与 -> 进位链。
    //   ★ 不能把 fifo_wr 本身再打一拍：那样写会晚 2 拍，而生产者是按
    //   fifo_full 的**当拍**值给背压的，满边界上会丢样本 —— 仿真里
    //   表现为末样本永远进不了 FIFO，等 done 直接超时。
    wire        fifo_wr  = (wsel[4] || ext_valid) && !fifo_full;
    wire [21:0] fifo_win = ext_valid ? ext_data : wdata_r[21:0];

    // ★ 原来是 `fifo_dout = fifo_mem[rptr]` 的组合读（128×22 分布式 RAM）。
    //   44 个 RAMD64E 摊在整片上，rptr[0] → fifo_dout → rdata_r 实测 7.2 ns
    //   （布线 6.2 ns）。改成 BRAM：读地址恒为当前头，读数据比地址晚一拍。
    //   因此弹出后要空一拍（fifo_q_vld 拉低）才能拿到新头；本设计每拍
    //   吞吐只要 ~87 周期一个样本，这一拍空转没有代价。
    //   ★ 不能用 write_first：XPM 规定简单双口 BRAM 的 B 口只能 read_first。
    //   同址碰撞只发生在"空时写入"（wptr==rptr 且 fcnt==0），那一拍把
    //   fifo_q_vld 拉低即可 —— 读回的是旧值，但下一拍会重新预取。
    wire [21:0] fifo_q;
    reg         fifo_q_vld;

    sdpram #(.DW(22), .AW(FIFO_AW)) u_fifo (
        .clk(clk), .we(fifo_wr), .waddr(wptr), .wdata(fifo_win),
        .raddr(rptr), .rdata(fifo_q)
    );
    assign fifo_dout = fifo_q;

    always @(posedge clk) begin
        if (!rst_n || fifo_rst) fifo_q_vld <= 1'b0;
        else fifo_q_vld <= !fifo_pop && (fcnt != 0) && !(fifo_wr && (wptr == rptr));
    end

    always @(posedge clk) begin
        if (!rst_n || fifo_rst) begin
            wptr <= {FIFO_AW{1'b0}};
            rptr <= {FIFO_AW{1'b0}};
            fcnt <= {(FIFO_AW+1){1'b0}};
        end else begin
            if (fifo_wr) wptr <= wptr + 1'b1;
            if (fifo_pop)  rptr <= rptr + 1'b1;
            case ({fifo_wr, fifo_pop})
                2'b10:   fcnt <= fcnt + 1'b1;
                2'b01:   fcnt <= fcnt - 1'b1;
                default: fcnt <= fcnt;
            endcase
        end
    end

    // 满时写入 → 粘滞
    always @(posedge clk) begin
        if (!rst_n)                    ovf_sticky <= 1'b0;
        else if (wsel[7] && wdata_r[0]) ovf_sticky <= 1'b0;
        else if ((wsel[4] || ext_valid) && fifo_full) ovf_sticky <= 1'b1;
    end

    // ==================================================================== 引擎
    wire        busy, done;
    wire [31:0] win_cnt;
    wire [16:0] beat_cnt;
    wire [31:0] res_rdata;

    eeg_fe #(.NCH(NCH), .NB(NB), .WIN(WIN)) u_fe (
        .clk          (clk),
        .rst_n        (rst_n),
        .run          (run),
        .win_rst      (1'b0),
        .state_clr    (state_clr),
        .acc_clr      (acc_clr),
        .s_valid      (fifo_q_vld),
        .s_data       (fifo_dout),
        .s_take       (fifo_pop),
        .busy         (busy),
        .done         (done),
        .done_clr     (done_clr),
        .win_cnt      (win_cnt),
        .beat_cnt_dbg (beat_cnt),
        .res_raddr    (res_idx_r),
        .res_rdata    (res_rdata)
    );

    // ==================================================================== AXI4-Lite 读通道（两拍）
    reg  [C_S_AXI_ADDR_WIDTH-1:0] araddr_r2;
    reg  [15:0] rsel;                    // 读地址 one-hot 译码，与地址同拍寄存
    reg                       rd_pend, rd_pend2;
    reg                       rvalid_r;
    reg  [31:0]               rd_mux_r;
    reg  [31:0]               rdata_r;
    wire rd_start = s_axi_arvalid & s_axi_arready;

    assign s_axi_arready = ~rvalid_r & ~rd_pend & ~rd_pend2;
    assign s_axi_rvalid  = rvalid_r;
    assign s_axi_rresp   = 2'b00;
    assign s_axi_rdata   = rdata_r;

    always @(posedge clk) begin
        if (!rst_n) begin
            rvalid_r  <= 1'b0;
            rd_pend   <= 1'b0;
            rd_pend2  <= 1'b0;
            araddr_r2 <= {C_S_AXI_ADDR_WIDTH{1'b0}};
            rsel      <= 16'd0;
        end else begin
            if (rd_start) begin
                araddr_r2 <= s_axi_araddr;
                rsel      <= 16'd1 << s_axi_araddr[7:2];   // 与地址同拍译码
                rd_pend   <= 1'b1;
            end else if (rd_pend) begin
                rd_pend   <= 1'b0;
            end
            if (rd_pend)       rd_pend2 <= 1'b1;
            else if (rd_pend2) rd_pend2 <= 1'b0;
            if (rd_pend2)                       rvalid_r <= 1'b1;
            else if (rvalid_r && s_axi_rready)  rvalid_r <= 1'b0;
        end
    end

    wire [31:0] status_w;
    assign status_w[0]     = busy;
    assign status_w[1]     = done;
    assign status_w[2]     = fifo_empty;
    assign status_w[3]     = fifo_full;
    assign status_w[7:4]   = 4'b0;
    assign status_w[15:8]  = fcnt[FIFO_AW-1:0];
    assign status_w[16]    = ovf_sticky;
    assign status_w[31:17] = 15'h0;

    // ★ 地址译码**和 araddr_r2 同拍寄存**成 one-hot（rsel），读选择只由
    //   这一个 16 位局部寄存器驱动。原来 case(araddr_r2) 让 araddr_r2 的
    //   每位带 53 个负载，实测 araddr_r2[2] → 读 mux 走了 6.3 ns 的线
    //   （源 X108Y85、mux X112Y131，跨 46 行）。rsel 只被 mux 用，placer
    //   自然把它放在 mux 旁边；读延迟仍是 1 拍。
    // ★ 两块内部 RAM 的读数据各打一拍再进读 mux。原来 fifo_dout（BRAM 输出）
    //   和 res_rdata 直接接进 10 选 1 与或树，实测
    //   FIFO 的 RAMB18 -> rd_mux_r_reg = -1.079 ns（3 级 LUT + 3.2 ns 布线，
    //   是当前全设计最坏）。这两项本来每个窗只读几次，多一拍延迟没有代价。
    reg [21:0] fifo_dbg_r;
    reg [31:0] res_dbg_r;
    always @(posedge clk) begin
        fifo_dbg_r <= fifo_dout;
        res_dbg_r  <= res_rdata;
    end

    wire [31:0] rd_mux =
          ({32{rsel[0]}} & ctrl_r)
        | ({32{rsel[1]}} & status_w)
        | ({32{rsel[2]}} & win_cnt)
        | ({32{rsel[3]}} & {15'h0, beat_cnt})
        | ({32{rsel[4]}} & {10'h0, fifo_dbg_r})      // 调试：只看不入队
        | ({32{rsel[5]}} & {23'h0, res_idx_r})
        | ({32{rsel[6]}} & res_dbg_r)
        | ({32{rsel[7]}} & {31'h0, ovf_sticky})
        | ({32{rsel[8]}} & 32'h5EED_0001)
        | ({32{rsel[9]}} & {8'h0, NCH[7:0], NB[7:0], 8'h0})
        | ({32{~|rsel}} & 32'hDEAD_BEEF);

    // ★ 读数据多打一拍：rd_mux 是 10 选 1 的与或树（3 级 LUT），其中一个
    //   源是 FIFO 的 BRAM 输出。BRAM → 与或树 → rdata_r 挤在一拍里实测
    //   -1.202 ns（全设计最坏）。无条件寄存一级后，mux 和 rdata_r 各自独占
    //   一拍。代价：AXI 读延迟 2 拍 → 3 拍，寄存器每次窗只读几次，无影响。
    always @(posedge clk) rd_mux_r <= rd_mux;
    always @(posedge clk) if (rd_pend2) rdata_r <= rd_mux_r;

    // ==================================================================== 调试灯
    //   LD0 亮 = run          LD1 亮 = FIFO 空（PS 没跟上）
    //   LD2 亮 = FIFO 满      LD3 亮 = 曾经丢样本（写 0x1C=1 清）
    assign dbg_led[0] = run;
    assign dbg_led[1] = fifo_empty;
    assign dbg_led[2] = fifo_full;
    assign dbg_led[3] = ovf_sticky;

endmodule

`default_nettype wire
