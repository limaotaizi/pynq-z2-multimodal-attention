`timescale 1ns / 1ps
`default_nettype none
// =============================================================================
// ts_top.v —— 全局时间戳 + τ 补偿 顶层（PYNQ-Z2 / XC7Z020）
//
//   ┌─ ts_core ──────────┐   ┌─ tau_comp ─┐
//   │ 200 MHz 自由计数器 ├──▶│ t_m = t−τ_m├──▶ 下游特征提取
//   │ 四路捕获 + 共享FIFO │   └────────────┘
//   └────────┬───────────┘
//            │ AXI4-Lite（PS 读写 τ、读计数器、弹出时间戳）
//            ▼
//        PS / ARM
//
//   ★★ 单时钟域：**PS 的 FCLK_CLK0 直接配成 200 MHz**，本模块全部逻辑
//      （含 AXI4-Lite 从口）跑在这一个时钟上 ⇒ 设计里**不存在任何跨时钟域**，
//      时间戳、τ 寄存器、总线访问共用同一条时基。这正是方案三 §3.1 的主张。
//      若把 FCLK0 配成 100 MHz 再打两拍同步，就等于自己把"统一时基"的论证毁掉了。
//
//   寄存器映射（字节地址，C_S_AXI_ADDR_WIDTH = 7 ⇒ 128 B 空间）
//     0x00 CTRL         RW  [0]=run [1]=clr_cnt(自清) [2]=fifo_rst(自清)
//     0x04 STATUS       RO  [0]=fifo_empty [1]=fifo_full [2]=run [15:8]=fifo_level
//     0x08 T_NOW_L      RO  计数器 [31:0]      ┐ 两次读之间计数器仍在跑，
//     0x0C T_NOW_H      RO  计数器 [47:32]     ┘ 高字可能比低字晚一拍（见注①）
//     0x10 FIFO_DATA_L  RO  **读此寄存器即出队**，返回 t[31:0]
//     0x14 ENQ_COUNT    RO  已打戳样本总数
//     0x18 FIFO_DATA_H  RO  返回**最近一次出队**的 {mod[1:0], t[47:32]}，不出队
//     0x20+8m TMm_L     RO  第 m 路最近一次 τ 补偿后的 t_m [31:0]
//     0x24+8m TMm_H     RO  第 m 路 t_m [47:32]
//     0x40+4m TAUm      RW  第 m 路 τ（单位=计数，5 ns/LSB），m: 0=EEG 1=眼动 2=GSR 3=AU
//     0x50 OVF_STICKY   RO/W1C  每路"丢样本"粘滞（上一戳未取走，或队列满）
//     0x54 UF_STICKY    RO/W1C  每路 τ > t 粘滞（τ 设过了头）
//     0x5C SRC          RW  bit m: 1 = 用内部节拍发生器，0 = 用外部 s_valid 引脚
//     0x60+4m DIVm      RW  第 m 路内部节拍分频比（200 MHz 计数），仅 SRC=1 时有意义
//     0x70+4m EPSm      RW  第 m 路 ε（时延置信度，同样的计数单位），m: 0=EEG 1=眼动 2=GSR 3=AU
//
//   ★ 0x40+4m 的 TAUm 与 0x70+4m 的 EPSm 合起来就是设计 §3.4 的 **2M=8 组时序寄存器**：
//     M 组设备时延 $\hat\tau_m^{dev}$ + M 组时延置信度 $\epsilon_m$（标定所得的上界，
//     各路相差 3–4 个数量级：e 为 µs 级、o/a 为 10–40 ms、s 为数十至数百 ms）。
//     ε 不做补偿、只供 PS 读走作为模型输入 —— 与 τ 的口径一致：PL 存的是**标定结果**，
//     物理时延 τ_phys 不被扣除（10_ §3.3）。
//     地址空间到此用满（7 bit ⇒ 0x00..0x7C），再加寄存器必须把 AW 从 7 加宽。
//
//   ★ SRC 默认全 0（用外部引脚）。板子上没有传感器时要先把 SRC 写成 0xF，
//     内部节拍发生器才会驱动采集前端 —— 这是让整条链路在无外设条件下也能
//     端到端跑通的那条通路，见 rtl/strobe_gen.v。DIVm 复位默认值已按 §2.1
//     的 256/150/50/40 Hz 填好，所以写 SRC=0xF + CTRL[0]=1 即可开始。
//
//   注①：读 48 位计数器要两次 32 位访问，中间会有几个计数（几十 ns）的偏斜。
//        做"PL 时基 vs PS 时基"对照实验时**不要**用这两个寄存器当采样值——
//        那条路径测的是 AXI 往返，不是计数器。采样值一律走 FIFO（0x10/0x18）。
// =============================================================================
module ts_top #(
    parameter integer TW = 48,
    parameter integer NW = 4,
    parameter integer AW = 8,
    parameter integer TAW = 32,
    parameter integer C_S_AXI_ADDR_WIDTH = 7,
    parameter integer C_S_AXI_DATA_WIDTH = 32
)(
    // ---- 200 MHz 时间基准域（= PS FCLK_CLK0）----
    input  wire                     clk,
    input  wire                     rst_n,

    // ---- 采集前端：四路采样点到达 ----
    input  wire [NW-1:0]            s_valid,

    // ---- 给下游（特征提取）的已补偿时间戳 ----
    output wire                     m_valid,
    output wire [$clog2(NW)-1:0]    m_mod,
    output wire [TW-1:0]            m_ts,

    // ---- 板载 4 个 LED（LD0..LD3），上板时不必接串口就能看出状态 ----
    //      需要 dbg_led 见文件末尾 assign
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
    localparam integer MW = $clog2(NW);
    localparam integer DW = TW + MW;

    // ==================================================================== 寄存器组
    reg  [31:0] ctrl_r;
    reg  [31:0] tau_r  [0:NW-1];
    reg  [31:0] eps_r  [0:NW-1];         // 0x70+4m：时延置信度 ε（设计 §3.4 的第 2 组 M 个）
    reg  [TW-1:0] tm_r  [0:NW-1];
    reg  [NW-1:0] src_r;                 // 0x5C：每路节拍来源选择
    reg  [31:0] div_r  [0:NW-1];         // 0x60+4m：内部节拍分频比

    wire run      = ctrl_r[0];
    wire clr_cnt  = ctrl_r[1];
    wire fifo_rst = ctrl_r[2];

    // 复位默认分频比（NW=4）。用函数而不是复位分支里写死下标，
    // 这样把 NW 改大时不会静默越界。
    function [31:0] div_default(input integer i);
        begin
            case (i)
                0:       div_default = 32'd781250;    // EEG  256 Hz（200e6/256，精确）
                1:       div_default = 32'd1333333;   // 眼动 150 Hz（→150.000038 Hz，+0.25 ppm）
                2:       div_default = 32'd4000000;   // GSR   50 Hz（精确）
                3:       div_default = 32'd5000000;   // AU    40 Hz（精确）
                default: div_default = 32'd1000000;
            endcase
        end
    endfunction

    // ==================================================================== AXI4-Lite 从口
    // ---- 写通道：AW 与 W 各自打一个"已到"标志，两者齐了才提交 ----
    reg  [C_S_AXI_ADDR_WIDTH-1:0] awaddr_r;
    reg  [31:0]                   wdata_r;
    reg  [3:0]                    wstrb_r;
    reg                           aw_hit, w_hit, bvalid_r;

    wire wr_commit = aw_hit & w_hit & ~bvalid_r;

    // 提交那一拍把 ready 拉低，避免同一个 always 块里"清标志"覆盖"置标志"而丢一拍地址
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

    // ---- 写译码 ----
    wire [4:0] wword = awaddr_r[C_S_AXI_ADDR_WIDTH-1:2];
    wire ctrl_wr   = wr_commit && (wword == 5'd0);
    wire tau_wr    = wr_commit && (wword >= 5'd16) && (wword <= 5'd19);
    wire ovf_clr_w = wr_commit && (wword == 5'd20);
    wire uf_clr_w  = wr_commit && (wword == 5'd21);
    wire src_wr    = wr_commit && (wword == 5'd23);                        // 0x5C
    wire div_wr    = wr_commit && (wword >= 5'd24) && (wword <= 5'd27);    // 0x60..0x6C
    wire eps_wr    = wr_commit && (wword >= 5'd28) && (wword <= 5'd31);    // 0x70..0x7C
    wire [1:0] tau_sel = wword[1:0];

    // CTRL：bit1..2 是自清脉冲，写 1 只维持一拍
    always @(posedge clk) begin
        if (!rst_n)     ctrl_r <= 32'h0;
        else if (ctrl_wr) ctrl_r <= wdata_r;
        else              ctrl_r <= ctrl_r & ~32'h0000_0006;   // bit1=clr_cnt, bit2=fifo_rst
    end

    // τ 寄存器：按 wstrb 逐字节写入
    integer t;
    always @(posedge clk) begin
        if (!rst_n) begin
            for (t = 0; t < NW; t = t + 1) tau_r[t] <= 32'd0;
        end else if (tau_wr) begin
            tau_r[tau_sel] <= { wstrb_r[3] ? wdata_r[31:24] : tau_r[tau_sel][31:24],
                                wstrb_r[2] ? wdata_r[23:16] : tau_r[tau_sel][23:16],
                                wstrb_r[1] ? wdata_r[15:8]  : tau_r[tau_sel][15:8],
                                wstrb_r[0] ? wdata_r[7:0]   : tau_r[tau_sel][7:0] };
        end
    end

    // ε 寄存器：与 τ 同样按 wstrb 逐字节写。**只读给 PS（0x70+4m）**，不参与补偿 ——
    // 设计 §3.4 要的是「物理时延与测量不确定度可分别进入模型」，故 ε 只存不扣。
    integer e;
    always @(posedge clk) begin
        if (!rst_n) begin
            for (e = 0; e < NW; e = e + 1) eps_r[e] <= 32'd0;
        end else if (eps_wr) begin
            eps_r[tau_sel] <= { wstrb_r[3] ? wdata_r[31:24] : eps_r[tau_sel][31:24],
                                wstrb_r[2] ? wdata_r[23:16] : eps_r[tau_sel][23:16],
                                wstrb_r[1] ? wdata_r[15:8]  : eps_r[tau_sel][15:8],
                                wstrb_r[0] ? wdata_r[7:0]   : eps_r[tau_sel][7:0] };
        end
    end

    wire [NW*TAW-1:0] tau_flat;
    genvar gi;
    generate
        for (gi = 0; gi < NW; gi = gi + 1) begin : g_tau
            assign tau_flat[gi*TAW +: TAW] = tau_r[gi];
        end
    endgenerate

    // ---- SRC / DIV：内部节拍发生器（台架用，见 rtl/strobe_gen.v）----
    integer d;
    always @(posedge clk) begin
        if (!rst_n) begin
            src_r <= {NW{1'b0}};                        // 默认走外部引脚
            for (d = 0; d < NW; d = d + 1) div_r[d] <= div_default(d);
        end else begin
            if (src_wr) src_r <= wdata_r[NW-1:0];
            if (div_wr) div_r[wword[1:0]] <= wdata_r;
        end
    end

    wire [NW*32-1:0] div_flat;
    genvar di;
    generate
        for (di = 0; di < NW; di = di + 1) begin : g_div
            assign div_flat[di*32 +: 32] = div_r[di];
        end
    endgenerate

    wire [NW-1:0] s_valid_gen;
    strobe_gen #(.NW(NW), .DW(32)) u_strobe (
        .clk      (clk),
        .rst_n    (rst_n),
        .run      (run),
        .en       (src_r),                 // 只给选中的路产生节拍
        .div_flat (div_flat),
        .s_valid  (s_valid_gen)
    );

    // 逐路选择：SRC=1 用内部节拍，SRC=0 用外部引脚
    wire [NW-1:0] s_valid_int;
    genvar si;
    generate
        for (si = 0; si < NW; si = si + 1) begin : g_src
            assign s_valid_int[si] = src_r[si] ? s_valid_gen[si] : s_valid[si];
        end
    endgenerate

    // ==================================================================== 时间戳核心
    wire [TW-1:0]            t_now;
    wire [DW-1:0]            fifo_dout;
    wire                     fifo_tvalid, fifo_empty, fifo_full;
    wire [AW:0]              fifo_level;
    wire [NW-1:0]            ovf_sticky;
    wire [31:0]              enq_count;
    wire                     arb_valid;
    wire [MW-1:0]            arb_mod;
    wire [TW-1:0]            arb_ts;

    wire [NW-1:0] ovf_clr_p = ovf_clr_w ? wdata_r[NW-1:0] : {NW{1'b0}};
    wire [NW-1:0] uf_clr_p  = uf_clr_w  ? wdata_r[NW-1:0] : {NW{1'b0}};

    // ---- 读通道：读 0x10 即出队 ----
    // ★ 两拍读（2026-10-18）。原实现把 PS7 地址管线 → 读数据多路器 → rdata_r
    //   压在一拍里，布局后 5.164 ns（WNS = -0.273 ns，75% 是布线）。
    //   现在第一拍只把地址锁进 araddr_r2（长走线止于寄存器），第二拍用寄存后的
    //   地址译码、取数并给 rvalid。AXI 允许从设备晚一拍返回 RVALID，主机只等
    //   RVALID；TB 与 PYNQ 驱动都不依赖固定读延迟。
    reg  [C_S_AXI_ADDR_WIDTH-1:0] araddr_r2;
    reg                       rd_pend;
    reg                       rvalid_r;
    reg  [31:0]               rdata_r;
    wire rd_start = s_axi_arvalid & s_axi_arready;
    // 数据相：上一拍已锁存地址
    wire rd_fifo  = rd_pend && (araddr_r2[C_S_AXI_ADDR_WIDTH-1:2] == 5'd4);
    wire fifo_pop = rd_fifo && fifo_tvalid;

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
            if (rd_pend)                    rvalid_r <= 1'b1;
            else if (rvalid_r && s_axi_rready) rvalid_r <= 1'b0;
        end
    end

    // 最近一次出队的样本（供 FIFO_DATA_H 取值，不出队）
    reg [DW-1:0] fifo_last;
    always @(posedge clk) begin
        if (!rst_n)          fifo_last <= {DW{1'b0}};
        else if (fifo_pop)   fifo_last <= fifo_dout;
    end

    ts_core #(.TW(TW), .NW(NW), .AW(AW)) u_core (
        .clk        (clk),
        .rst_n      (rst_n),
        .run        (run),
        .clr        (clr_cnt),
        .fifo_rst   (fifo_rst),
        .s_valid    (s_valid_int),
        .ovf_clr    (ovf_clr_p),
        .t_now      (t_now),
        .m_tdata    (fifo_dout),
        .m_tvalid   (fifo_tvalid),
        .m_tready   (fifo_pop),
        .fifo_empty (fifo_empty),
        .fifo_full  (fifo_full),
        .fifo_level (fifo_level),
        .ovf_sticky (ovf_sticky),
        .enq_count  (enq_count),
        .arb_valid  (arb_valid),
        .arb_mod    (arb_mod),
        .arb_ts     (arb_ts)
    );

    // ==================================================================== τ 补偿
    wire                     cm_valid;
    wire [MW-1:0]            cm_mod;
    wire [TW-1:0]            cm_ts;
    wire [NW-1:0]            uf_sticky;

    tau_comp #(.TW(TW), .NW(NW), .TAW(TAW)) u_tau (
        .clk       (clk),
        .rst_n     (rst_n),
        .valid_in  (arb_valid),
        .mod_in    (arb_mod),
        .t_in      (arb_ts),
        .tau_flat  (tau_flat),
        .uf_clr    (uf_clr_p),
        .valid_out (cm_valid),
        .mod_out   (cm_mod),
        .t_out     (cm_ts),
        .uf_sticky (uf_sticky)
    );

    assign m_valid = cm_valid;
    assign m_mod   = cm_mod;
    assign m_ts    = cm_ts;

    always @(posedge clk) begin
        if (cm_valid) tm_r[cm_mod] <= cm_ts;
    end

    // ==================================================================== 读数据多路
    wire [31:0] status_w;
    assign status_w[0]     = fifo_empty;
    assign status_w[1]     = fifo_full;
    assign status_w[2]     = run;
    assign status_w[7:3]   = 5'b0;
    assign status_w[15:8]  = fifo_level[7:0];
    assign status_w[31:16] = 16'h0;

    reg [31:0] rdata_r_next;
    always @(*) begin
        case (araddr_r2)
            7'h00:   rdata_r_next = ctrl_r;
            7'h04:   rdata_r_next = status_w;
            7'h08:   rdata_r_next = t_now[31:0];
            7'h0C:   rdata_r_next = {16'h0, t_now[TW-1:32]};
            7'h10:   rdata_r_next = fifo_dout[31:0];                      // ★ 读即出队
            7'h14:   rdata_r_next = enq_count;
            7'h18:   rdata_r_next = {14'h0, fifo_last[DW-1:32]};          // {mod, t[47:32]}
            7'h20:   rdata_r_next = tm_r[0][31:0];
            7'h24:   rdata_r_next = {16'h0, tm_r[0][TW-1:32]};
            7'h28:   rdata_r_next = tm_r[1][31:0];
            7'h2C:   rdata_r_next = {16'h0, tm_r[1][TW-1:32]};
            7'h30:   rdata_r_next = tm_r[2][31:0];
            7'h34:   rdata_r_next = {16'h0, tm_r[2][TW-1:32]};
            7'h38:   rdata_r_next = tm_r[3][31:0];
            7'h3C:   rdata_r_next = {16'h0, tm_r[3][TW-1:32]};
            7'h40:   rdata_r_next = tau_r[0];
            7'h44:   rdata_r_next = tau_r[1];
            7'h48:   rdata_r_next = tau_r[2];
            7'h4C:   rdata_r_next = tau_r[3];
            7'h50:   rdata_r_next = {{(32-NW){1'b0}}, ovf_sticky};
            7'h54:   rdata_r_next = {{(32-NW){1'b0}}, uf_sticky};
            7'h5C:   rdata_r_next = {{(32-NW){1'b0}}, src_r};
            7'h60:   rdata_r_next = div_r[0];
            7'h64:   rdata_r_next = div_r[1];
            7'h68:   rdata_r_next = div_r[2];
            7'h6C:   rdata_r_next = div_r[3];
            7'h70:   rdata_r_next = eps_r[0];                             // ε：时延置信度
            7'h74:   rdata_r_next = eps_r[1];
            7'h78:   rdata_r_next = eps_r[2];
            7'h7C:   rdata_r_next = eps_r[3];
            default: rdata_r_next = 32'hDEAD_BEEF;
        endcase
    end

    always @(posedge clk) if (rd_pend) rdata_r <= rdata_r_next;

    // ==================================================================== 调试灯
    // 上板时最有用的四个状态，一眼可见。
    // ★ PYNQ-Z2 的 LD0..LD3 是**高有效**（写 1 点亮），所以这里不需要取反。
    //   LD0 亮 = run（计数器在跑）      LD1 亮 = 队列空（PS 跟得上）
    //   LD2 亮 = 队列满（PS 读太慢）    LD3 亮 = 曾经丢过样本（粘滞，需写 0x50 清）
    assign dbg_led[0] = run;
    assign dbg_led[1] = fifo_empty;
    assign dbg_led[2] = fifo_full;
    assign dbg_led[3] = |ovf_sticky;

endmodule

`default_nettype wire
