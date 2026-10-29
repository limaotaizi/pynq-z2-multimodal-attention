`timescale 1ns / 1ps
`default_nettype none
// =============================================================================
// eeg_fe.v —— EEG 前端：5 带 IIR + 单遍方差 + CORDIC log（方案三 03 §3.3）
//
//   每个采样点（一路通道）串行跑 5 个带 × 2 个 biquad（DF2T），
//   再把带通输出累加进 sum/sumsq；1024 个采样后逐 (通道,带) 出 log2(var)。
//
//   数值口径（与 model/eeg_fe_model.py 逐位相同）：
//     x  : int16 采样 << 6  → Q3.21
//     c  : Q3.15（18 bit，范围 ±4）
//     状态/输出 : Q3.21（24 bit）
//     乘积 : 42 bit；累加 48 bit；>>15 带舍入；饱和到 24 bit
//     var  : varnum = WIN*sumsq − sum^2（Q6.42）
//     输出 : log2(var)，Q16.16（已减 62 的定标常数）
//
//   资源：状态 620×48 bit、累加器 310×112 bit、结果 310×32 bit。
//   吞吐：一个采样 ~87 拍 ⇒ 62 通道 × 256 Hz 占 200 MHz 的 0.7%。
//
//   ★ 三个必须显式写成"自定上下文"的地方（都在下面的注释里标了）：
//     1. 有符号数混进无符号表达式时，操作数会先被**零扩展**再运算；
//        所以 y²、sum² 都在独立的有符号线网上算，绝不写进含
//        acc_dout 切片的大表达式。
//     2. 乘法的结果宽度 = 表达式宽度（不是两操作数宽度之和）⇒ 想得到
//        全精度乘积，必须让整个表达式处在**乘积宽度**的上下文里。
//     3. 大位宽乘法/加法一律拆拍：200 MHz 下 72×72 一个周期收不住
//        （实测 WNS −10.0 ns）。
// =============================================================================
module eeg_fe #(
    parameter integer NCH  = 62,
    parameter integer NB   = 5,
    parameter integer WIN  = 1024,
    parameter integer NST  = 2                       // 每带 biquad 数
)(
    input  wire         clk,
    input  wire         rst_n,

    // ---- 控制 ----
    input  wire         run,
    input  wire         win_rst,
    input  wire         state_clr,      // 单拍：清 IIR 状态
    input  wire         acc_clr,        // 单拍：清累加器

    // ---- 采样输入（一拍一个通道）----
    input  wire         s_valid,
    input  wire [21:0]  s_data,         // {ch[5:0], sample[15:0]}
    output wire         s_take,         // 接收一拍

    // ---- 状态 ----
    output reg          busy,
    output reg          done,           // 一个窗算完，粘滞到 done_clr
    input  wire         done_clr,
    output reg  [31:0]  win_cnt,
    output wire [16:0]  beat_cnt_dbg,

    // ---- 结果读出 ----
    input  wire [8:0]   res_raddr,
    output wire [31:0]  res_rdata
);
    localparam integer NSAMP   = NCH * WIN;          // 63488
    localparam integer NSTATE  = NCH * NB * NST;     // 620
    localparam integer NACC    = NCH * NB;           // 310
    localparam integer LOG_OFF = 2*21 + 2*10;        // Q3.21 与 N^2 的定标补偿 = 62

    // ---- 状态编码（33 个，6 bit）----
    //   ★ 2026-10-18 从 5 bit 扩到 6 bit 只为腾出一个 S_Y3：原来 5 位刚好用满
    //     0..31。前面所有状态的数值没动，tb_biquad 的探针编号仍然对得上。
    localparam [5:0]
        S_IDLE  = 5'd0,  S_LAT   = 5'd1,  S_RD    = 5'd2,  S_RD2   = 5'd3,
        S_MUL   = 5'd4,  S_Y     = 5'd5,  S_N1    = 5'd6,  S_N2    = 5'd7,
        S_WR    = 5'd8,  S_WR2   = 5'd9,  S_ARD   = 5'd10, S_ARD2  = 5'd11,
        S_ARD3  = 5'd12, S_ARD4  = 5'd13, S_AWR   = 5'd14, S_FRD   = 5'd15,
        S_FRD2  = 5'd16, S_FRD3  = 5'd17, S_FRD4  = 5'd18, S_FRD5  = 5'd19,
        S_FRD6  = 5'd20, S_FRD7  = 5'd21, S_FNORM = 5'd22, S_FNORM2= 5'd23,
        S_FNORM3= 5'd24, S_FWT   = 5'd25, S_FW    = 5'd26, S_CLRW  = 5'd27,
        S_CLRW2 = 5'd28, S_SCLR  = 5'd29, S_SCLR2 = 5'd30,
        // ★ 追加在末尾，不改前面任何状态的编号：tb_biquad 的探针按编号打点。
        S_Y2    = 5'd31, S_Y3 = 6'd32,
        S_ARD5  = 6'd33;

    // ★ one-hot：31 个状态用二进制编码时，5 位 st 要扇出到 263 个负载，
    //   其中一位的单根本地布线实测 4.7 ns。one-hot 后每个状态位只驱动
    //   自己那段逻辑，扇出自然变小、也便于复制。
    (* fsm_encoding = "one_hot" *) reg [5:0]  st;
    reg [8:0]  idx;
    reg [9:0]  clr_idx;
    reg        stclr_req, acclr_req;
    reg        auto_clr;                 // 1 = 这次清累加器是"窗收尾"，不是外部请求

    // ==================================================================== 存储
    // ★ 直接实例化 XPM 双口 BRAM（见 sdpram.v 的说明）：让 Vivado 自己推断时，
    //   同样写法的 512×32 能进 BRAM，1024×48 与 512×112 却被判
    //   "Synth 8-6849 Infeasible ... trying to implement using LUTRAM"，
    //   落到 2140 个 RAMD64E 把布局摊满 30+ 行，读地址到读数据实测 8.4 ns。
    //   显式实例化后存储实现不再依赖推断，总共只占 ~7 块 BRAM。
    reg  [9:0]   st_raddr;
    reg          st_we;
    reg  [9:0]   st_waddr;
    reg  [47:0]  st_wdata;
    wire [47:0]  st_dout;

    reg  [8:0]   acc_raddr;
    reg          acc_we;
    reg  [8:0]   acc_waddr;
    reg  [111:0] acc_wdata;
    wire [111:0] acc_dout;

    reg          res_we;
    reg  [8:0]   res_waddr;
    reg  [31:0]  res_wdata;

    // 读延迟 1 拍：地址在上一沿打入，数据在本沿有效（与原来的 `dout <= mem[addr]` 同拍）
    sdpram #(.DW(48),  .AW(10)) u_st_ram (
        .clk(clk), .we(st_we),  .waddr(st_waddr),  .wdata(st_wdata),
        .raddr(st_raddr), .rdata(st_dout)
    );
    sdpram #(.DW(112), .AW(9)) u_acc_ram (
        .clk(clk), .we(acc_we), .waddr(acc_waddr), .wdata(acc_wdata),
        .raddr(acc_raddr), .rdata(acc_dout)
    );
    sdpram #(.DW(32),  .AW(9)) u_res_ram (
        .clk(clk), .we(res_we), .waddr(res_waddr), .wdata(res_wdata),
        .raddr(res_raddr), .rdata(res_rdata)
    );

    // ==================================================================== 系数
    function [89:0] coefs(input [2:0] bi, input stg);
        case ({bi, stg})
            4'd0: coefs = {18'sd42,   18'sd84,   18'sd42,   18'sd62821, -18'sd30288}; // delta 0
            4'd1: coefs = {18'sd32768,-18'sd65536,18'sd32768,18'sd64688, -18'sd31945}; // delta 1
            4'd2: coefs = {18'sd74,   18'sd148,  18'sd74,   18'sd61810, -18'sd30048}; // theta 0
            4'd3: coefs = {18'sd32768,-18'sd65536,18'sd32768,18'sd63500, -18'sd31102}; // theta 1
            4'd4: coefs = {18'sd161,  18'sd321,  18'sd161,  18'sd58597, -18'sd28930}; // alpha 0
            4'd5: coefs = {18'sd32768,-18'sd65536,18'sd32768,18'sd61496, -18'sd30137}; // alpha 1
            4'd6: coefs = {18'sd1093, 18'sd2185, 18'sd1093, 18'sd42629, -18'sd22555}; // beta 0
            4'd7: coefs = {18'sd32768,-18'sd65536,18'sd32768,18'sd54928, -18'sd26399}; // beta 1
            4'd8: coefs = {18'sd1451, 18'sd2902, 18'sd1451, 18'sd21141, -18'sd22232}; // gamma 0
            4'd9: coefs = {18'sd32768,-18'sd65536,18'sd32768,18'sd38912, -18'sd24149}; // gamma 1
            default: coefs = 90'd0;
        endcase
    endfunction

    // ==================================================================== 数据通路
    reg  [2:0]         band_r;
    reg                stage_r;
    reg  [5:0]         ch_r;
    reg  signed [23:0] x_beat, y_r;
    reg  signed [23:0] s1_r, s2_r;
    reg  signed [41:0] p0, p1, p2, p3, p4;

    wire [89:0] cf = coefs(band_r, stage_r);
    wire signed [17:0] cb0 = cf[89:72];
    wire signed [17:0] cb1 = cf[71:54];
    wire signed [17:0] cb2 = cf[53:36];
    wire signed [17:0] ca1 = cf[35:18];
    wire signed [17:0] ca2 = cf[17:0];

    // ★ 系数先打一拍再进 DSP：{band,stage} 选择位扇出 46 个负载，直接
    //   接到 DSP 的 B 口时实测 band_r→B 是一条 4.8 ns 的路（其中布线
    //   3.5 ns，DSP 建立时间另有 3.5 ns）。寄存以后 DSP 的 B 口只吃
    //   本地寄存器的输出。S_RD2 本来就是等 BRAM 的拍，不增加周期。
    reg signed [17:0] k_b0, k_b1, k_b2, k_a1, k_a2;

    // ★ DSP48E1 在 200 MHz 下 A 口的建立时间是 3.7 ns：操作数必须来自
    //   **紧贴该 DSP 的寄存器**（最好直接被吸收进 DSP 内部 A 寄存器）。
    //   所以每个 DSP 的 A 操作数各留一份副本，扇出为 1。
    (* dont_touch = "true" *) reg signed [23:0] xin_a0, xin_a1, xin_a2;   // → p0, p1, p2
    reg signed [23:0] y_a0, y_a1;               // → p3, p4

    // ★ S_Y / S_Y2 两级：DSP 会把 y_r 吸进 y_sq_w 的 A/B 寄存器，于是
    //   「上一级 DSP 的 P 寄存器 → 饱和逻辑 → 本级 DSP 的 B 口」被拼成一整条
    //   组合路径（实测 7.3 ns，逻辑 3.4 ns 全是 sat24q 的两条 CARRY4）。
    //   把饱和结果先打进 y_sat，下一拍再进 y_r/y_a0/y_a1，饱和逻辑就独占
    //   一整拍。代价是每个 (通道,频带) +1 拍。
    //   ★ dont_touch 不能省：phys_opt 的寄存器重定时会把这一级搬进下游 DSP
    //     的 A/B 寄存器，等于把饱和逻辑又接回 DSP 口上（实测 -2.856 →
    //     -2.558 就是只挪了个目标端口，路径一级没少）。
    (* dont_touch = "true" *) reg signed [23:0] y_sat;
    // DSP 的 P 寄存器 → 饱和逻辑 → y_sat 仍然是一整拍（实测 -0.841 ns，
    // 3 级 LUT + 3.1 ns 布线）。再把"右移 15 位"先寄存一拍：DSP 输出直接
    // 进 FF，饱和逻辑从 y_shf 出发又独占一拍。代价每个 (通道,频带) +1 拍。
    reg signed [32:0] y_shf;

    wire signed [23:0] xin = (stage_r == 1'b0) ? x_beat : y_r;

    // ★ xin 的 2:1 选择提前一级（S_RD）寄存。
    //   原来 xin 是纯组合，直接接到三个乘法器的 24 位选择 LUT 上：stage_r
    //   一根线扇出 68 个负载，实测布线 3.588 ns，再加上 LUT3 之后**直接进
    //   DSP48E1 的 A 口**（xin_aN 被吸进 DSP 内部 A 寄存器），A 口建立时间
    //   还要 3.7 ns ⇒ stage_r_reg/C -> n2_acc/A[13] = -0.841 ns。
    //   现在选择在 S_RD 就做完（stage_r 与 x_beat/y_r 都已稳定，S_RD 到
    //   S_RD2 有一整拍），stage_r 只扇出 24 个 LUT，且这一级不再进 DSP 口。
    //   dont_touch 两个都不能省：吸进 DSP 的 A 寄存器就等于把选择逻辑
    //   又接回 DSP 口上（与本文件其它几处是同一个坑）。
    (* dont_touch = "true" *) reg signed [23:0] xin_sel;

    // 饱和到 24 位，输入是**已右移 15 位**的 33 位值。单独写一个窄口
    // 版本的目的是把 48 位比较从关键路径上拿掉（见 sat24_shift 的用法）。
    // ★ 2026-10-18：判据从"两次 33 位幅度比较"改成"看符号扩展段"。
    //   等价，但省掉两条 33 位 CARRY4 比较链（实测逻辑 3.3 ns，是全设计
    //   次坏路径）。v 是 33 位有符号，[23:0] 是保留段、[32:24] 是扩展段：
    //   在范围内 ⇔ 扩展段全 0（正）或全 1（负）；否则按 v[32] 饱和。
    //   全 0 / 全 1 是纯 LUT 归约，2 级就够，没有进位链。
    function signed [23:0] sat24q(input signed [32:0] v);
        reg [8:0] hi;
        begin
            hi = v[32:24];
            if (hi == 9'd0 || hi == 9'h1FF) sat24q = v[23:0];
            else if (v[32])                 sat24q = -24'sd8388608;
            else                            sat24q = 24'sd8388607;
        end
    endfunction

    function signed [23:0] sat24(input signed [47:0] v);
        begin
            if (v > 48'sd8388607)       sat24 = 24'sd8388607;
            else if (v < -48'sd8388608) sat24 = -24'sd8388608;
            else                        sat24 = v[23:0];
        end
    endfunction

    // 显式把 24 位状态符号扩展成 48 位再左移 —— 不依赖工具对移位表达式的
    // 上下文位宽推断（<<< 在自决定上下文里只保留左操作数的 24 位）。
    wire signed [47:0] s1_ext = {{24{s1_r[23]}}, s1_r};
    wire signed [47:0] s2_ext = {{24{s2_r[23]}}, s2_r};
    wire signed [47:0] y_acc  = p0 + (s1_ext <<< 15) + 48'sd16384;
    wire signed [47:0] n1_acc = p1 + (s2_ext <<< 15) + p3 + 48'sd16384;
    wire signed [47:0] n2_acc = p2 + p4 + 48'sd16384;
    wire signed [32:0] y_acc_sh = y_acc >>> 15;
    wire signed [23:0] y_new  = sat24q(y_shf);

    // ★ 42 位加法 + 移位 + 饱和原来全挤在写状态那一拍（实测 −3.4 ns）。
    //   加法挪到 S_N2（本来就是空等拍），写状态只剩移位与饱和。
    reg  signed [47:0] sum_n1_r, sum_n2_r;
    wire signed [23:0] s1_new = sat24q(sum_n1_r >>> 15);
    wire signed [23:0] s2_new = sat24q(sum_n2_r >>> 15);

    // ==================================================================== 累加器流水
    // ★ y² 单独算（见文件头注 1）。
    //
    // ★ 2026-10-20：y² 改成和下面 varnum 段一样的 hi/lo 拆分。
    //   起因：`wire y_sq_w = y_r * y_r;` 是 **24×24** 乘法，而 DSP48E1 只有
    //   25×18，综合器必须把操作数拆成两半、用**两个 DSP** 算，两个都配成
    //   PREG=0 MREG=0 —— 于是 DSP10 的 CLK->PCOUT 是乘法器内部的**组合**
    //   路径 4.206 ns，再经 DSP11 的 PCIN->P 组合 1.518 ns、布线 0.684 ns，
    //   合计 6.410 ns，200 MHz 下 WNS = -1.647。
    //   试过的错解：给 y_sq_r 加 dont_touch。它只把**最后那级 FF** 挡住，
    //   级联照旧存在，反而让失败端点从 67 个涨到 2884 个（-0.197 -> -1.647）。
    //
    //   正解：把 y_r 自己 6/18 拆开，三个乘法都 ≤18×18（各自独占一个 DSP，
    //   用 P 寄存器输出），加法改到 FF->FF：
    //       y = yh·2^6 + yl   (yh 18 位有符号 = y_r>>>6，yl 6 位无符号 = y_r[5:0])
    //       y² = yh²·2^12 + yh·yl·2^7 + yl²
    //   三项各自打一拍（S_ARD2），合成一项打一拍（S_ARD3），状态数不变。
    //   位宽：|y| ≤ 2^23 ⇒ y² ≤ 2^46，48 位有符号装得下，且三项移位后
    //   最大 2^46，无溢出 ⇒ 与 `y_r*y_r` **逐位等价**。
    wire signed [23:0] yq_        = y_r;
    wire signed [17:0] y_hi       = yq_ >>> 6;            // 18 位有符号
    wire signed [6:0]  y_lo_s     = $signed({1'b0, yq_[5:0]});   // 7 位正数
    wire signed [37:0] yphh_w     = y_hi * y_hi;          // 18×18
    wire signed [37:0] yphl_w     = y_hi * y_lo_s;        // 18×7
    wire signed [37:0] ypll_w     = y_lo_s * y_lo_s;      // 7×7
    reg  signed [37:0] yphh, yphl, ypll;                  // 各自进 DSP 的 P 寄存器
    wire signed [47:0] yphh48 = {{10{yphh[37]}}, yphh};
    wire signed [47:0] yphl48 = {{10{yphl[37]}}, yphl};
    wire signed [47:0] ypll48 = {{10{ypll[37]}}, ypll};
    wire signed [47:0] y_sq_w = (yphh48 <<< 12) + (yphl48 <<< 7) + ypll48;
    reg  signed [47:0] y_sq_r;
    reg  signed [47:0] sum_new_r;
    reg  [63:0]        qsum_r;                     // 累加器高段，寄存一拍再相加
    // ★ 2026-10-18：64 位累加加法拆成两拍（见 S_ARD4 / S_ARD5）。
    wire [47:0] yrext = {{24{y_r[23]}}, y_r};      // y_r 零/符号扩展到 48 位
    // ★ 名字必须避开 varnum 段的 wire lo_s（同模块内重名会让 xvlog 直接报
    //   VRFC 10-9364 并把整个 module 丢掉）。2026-10-18 曾因这个重名让
    //   磁盘上的 RTL 变成不可编译状态。
    reg  [31:0] acc_lo_s, acc_lo_q;                // 低半和
    reg         cy_s, cy_q;                        // 低半进位

    // ==================================================================== varnum 流水
    // |sum| ≤ WIN·2^23 = 2^33。拆成 hi·2^18 + lo（hi 18 位有符号、lo 18 位
    // 无符号）后，三个 18×18 乘法各占一拍，合并再占两拍：
    //   sum² = (hi² << 36) + (hi·lo << 19) + lo²
    // 位宽上限：|hi| ≤ 2^15 ⇒ hi² ≤ 2^30、(hi·lo) ≤ 2^33、lo² < 2^36，
    // 所以后两个乘积都要 38 位（36 位有符号装不下 lo²）。
    reg  [63:0]        q_r;                       // sumsq（≤ 2^56）
    // ★ dont_touch：hi_r / lo_r 只喂三个乘法器，不加约束就会被吸进 DSP 的
    //   A 口内部寄存器，于是 "acc_ram 的 BRAM 输出 → DSP A 口" 变成一整条
    //   组合路径（实测 -0.735 ns，源是 BRAM 的输出寄存器）。
    //   保留成独立 FF 后，BRAM→FF 和 FF→DSP 各走一段，placer 会把 FF 贴到 DSP 旁。
    (* dont_touch = "true" *) reg  signed [17:0] hi_r;
    (* dont_touch = "true" *) reg  [17:0]        lo_r;
    reg  signed [71:0] q72_r;                     // q << 10
    reg  signed [37:0] phh, phl, pll;
    reg  signed [71:0] sq_a, sq_b, sq_sum_r;

    wire signed [18:0] lo_s  = $signed({1'b0, lo_r});   // 19 位正数
    wire signed [37:0] phh_w = hi_r * hi_r;             // 18×18 → 38 位上下文
    wire signed [37:0] phl_w = hi_r * lo_s;             // 18×19 → 38 位
    wire signed [37:0] pll_w = lo_s * lo_s;             // 19×19 → 38 位

    // 显式符号扩展到 72 位再做移位，避免移位在自决定上下文里截断
    wire signed [71:0] phh72   = {{34{phh[37]}}, phh};
    wire signed [71:0] phl72   = {{34{phl[37]}}, phl};
    wire signed [71:0] pll72   = {{34{pll[37]}}, pll};
    wire signed [71:0] sq_a_w  = phh72 <<< 36;
    wire signed [71:0] sq_b_w  = (phl72 <<< 19) + pll72;
    wire signed [71:0] sq_sum_w = sq_a + sq_b;
    wire signed [71:0] varnum_w = q72_r - sq_sum_r;

    // ==================================================================== 归一化 + CORDIC
    reg  [71:0] varnum_r;
    wire        norm_valid;
    wire [30:0] norm_m;
    wire [6:0]  norm_er;
    wire        norm_zero;
    wire        norm_start = (st == S_FNORM);     // varnum_r 在进 S_FNORM 时已稳

    norm72 u_norm (
        .clk   (clk),
        .rst_n (rst_n),
        .start (norm_start),
        .v     (varnum_r),
        .valid (norm_valid),
        .m     (norm_m),
        .er    (norm_er),
        .zero  (norm_zero)
    );

    // norm72 现在是三级流水（valid 在 start 后第 3 拍），所以 S_FNORM2 等它，
    // 不再用固定的 S_FNORM3。S_FNORM3 保留在枚举里只为不挪动状态编号。
    wire        cordic_start = (st == S_FNORM2) & norm_valid;
    wire        cordic_busy, cordic_done;
    wire signed [31:0] cordic_out;

    log2_cordic u_log (
        .clk      (clk),
        .rst_n    (rst_n),
        .start    (cordic_start),
        .m        (norm_m),
        .er       (norm_er),
        .zero     (norm_zero),
        .busy     (cordic_busy),
        .done     (cordic_done),
        .log2_q16 (cordic_out)
    );

    // ==================================================================== 窗计数
    reg [16:0] beat_cnt;
    assign beat_cnt_dbg = beat_cnt;

    // ★ 终拍判定寄存。原来 S_AWR 里直接写 `beat_cnt == NSAMP-1`，那个 17 位
    //   比较器的输出同时驱动 beat_cnt 全部 17 位的 CE，实测
    //   beat_cnt_reg[5]/C -> beat_cnt_reg[10..16]/CE = -0.904 ns。
    //   beat_cnt 每 ~87 拍才动一次，比较结果提前一拍打进单比特寄存器后，
    //   CE 只由一根 FF 线驱动，比较器本身只带 1 个负载。
    //   beat_cnt 在 S_AWR 之外恒定，所以 S_AWR 那一拍的 beat_last_r 恒等于
    //   "(上一拍的 beat_cnt == NSAMP-1)"，而此时 beat_cnt 早已是 NSAMP-1。
    (* dont_touch = "true" *) reg beat_last_r;
    always @(posedge clk) begin
        if (!rst_n) beat_last_r <= 1'b0;
        else        beat_last_r <= (beat_cnt == NSAMP-1);
    end

    // ==================================================================== 清空请求寄存
    always @(posedge clk) begin
        if (!rst_n) begin
            stclr_req <= 1'b0;
            acclr_req <= 1'b0;
        end else begin
            if (state_clr) stclr_req <= 1'b1;
            if (acc_clr)   acclr_req <= 1'b1;
            if (st == S_SCLR2 && clr_idx == NSTATE-1) stclr_req <= 1'b0;
            if (st == S_CLRW2 && clr_idx == NACC-1)   acclr_req <= 1'b0;
        end
    end

    // ==================================================================== 主状态机
    assign s_take = (st == S_LAT) & run;

    always @(posedge clk) begin
        if (!rst_n) begin
            st <= S_IDLE;
            busy <= 1'b0; done <= 1'b0; win_cnt <= 32'd0;
            beat_cnt <= 17'd0;
            band_r <= 3'd0; stage_r <= 1'b0; ch_r <= 6'd0;
            x_beat <= 24'sd0; y_r <= 24'sd0; s1_r <= 24'sd0; s2_r <= 24'sd0;
            p0 <= 42'sd0; p1 <= 42'sd0; p2 <= 42'sd0; p3 <= 42'sd0; p4 <= 42'sd0;
            k_b0 <= 18'sd0; k_b1 <= 18'sd0; k_b2 <= 18'sd0;
            k_a1 <= 18'sd0; k_a2 <= 18'sd0;
            xin_a0 <= 24'sd0; xin_a1 <= 24'sd0; xin_a2 <= 24'sd0; xin_sel <= 24'sd0;
            y_a0 <= 24'sd0; y_a1 <= 24'sd0; y_sat <= 24'sd0; y_shf <= 33'sd0;
            sum_n1_r <= 48'sd0; sum_n2_r <= 48'sd0;
            st_we <= 1'b0; st_raddr <= 10'd0; st_waddr <= 10'd0; st_wdata <= 48'd0;
            acc_we <= 1'b0; acc_raddr <= 9'd0; acc_waddr <= 9'd0; acc_wdata <= 112'd0;
            res_we <= 1'b0; res_waddr <= 9'd0; res_wdata <= 32'd0;
            varnum_r <= 72'd0;
            idx <= 9'd0; clr_idx <= 10'd0; auto_clr <= 1'b0;
            y_sq_r <= 48'sd0; sum_new_r <= 48'sd0; qsum_r <= 64'd0;
            yphh <= 38'sd0; yphl <= 38'sd0; ypll <= 38'sd0;
            q_r <= 64'd0; hi_r <= 18'sd0; lo_r <= 18'd0; q72_r <= 72'sd0;
            phh <= 38'sd0; phl <= 38'sd0; pll <= 38'sd0;
            sq_a <= 72'sd0; sq_b <= 72'sd0; sq_sum_r <= 72'sd0;
        end else begin
            st_we  <= 1'b0;
            acc_we <= 1'b0;
            res_we <= 1'b0;
            if (done_clr || win_rst) done <= 1'b0;

            case (st)
            // ---------------------------------------------------------- 空闲
            S_IDLE: begin
                busy <= 1'b0;
                if (stclr_req) begin
                    clr_idx <= 10'd0; st <= S_SCLR;
                end else if (acclr_req) begin
                    clr_idx <= 10'd0; auto_clr <= 1'b0; st <= S_CLRW;
                end else if (run && s_valid) begin
                    busy <= 1'b1;
                    st <= S_LAT;
                end
            end

            // ---------------------------------------------------------- 取一拍
            S_LAT: begin
                ch_r    <= s_data[21:16];
                x_beat  <= {{8{s_data[15]}}, s_data[15:0]} <<< 6;
                band_r  <= 3'd0;
                stage_r <= 1'b0;
                st <= S_RD;
            end

            // ---------------------------------------------------------- biquad
            S_RD: begin                       // 发地址 + 选输入 + 算累加器地址
                st_raddr <= ch_r * (NB*NST) + band_r * NST + stage_r;
                xin_sel  <= xin;
                // ★ 累加器地址提前到这里算。原来写在 S_ARD4（紧挨着写），
                //   路径只有一拍：ch_r*5+band_r 是 3 级 LUT 乘常数，实测
                //   ch_r_reg[1] -> acc_waddr_reg[2] = -0.392 ns（那条路的
                //   16 条路径是 CE 修掉之后的新最坏族）。band_r 在整个
                //   (ch,band) 通道内不变，提前 6 拍算完全等价。
                acc_waddr <= ch_r * NB + band_r;
                st <= S_RD2;
            end
            S_RD2: begin                      // 等一拍 BRAM 读延迟，同时锁系数
                k_b0  <= cb0;
                k_b1  <= cb1;
                k_b2  <= cb2;
                k_a1  <= ca1;
                k_a2  <= ca2;
                xin_a0 <= xin_sel;
                xin_a1 <= xin_sel;
                xin_a2 <= xin_sel;
                st    <= S_MUL;
            end
            S_MUL: begin
                s1_r <= st_dout[47:24];
                s2_r <= st_dout[23:0];
                p0   <= k_b0 * xin_a0;
                p1   <= k_b1 * xin_a1;
                p2   <= k_b2 * xin_a2;
                st   <= S_Y;
            end
            S_Y: begin
                y_shf <= y_acc_sh;             // DSP 的 P 寄存器直接进 FF
                st    <= S_Y2;
            end
            S_Y2: begin
                y_sat <= y_new;                // 饱和逻辑独占这一拍
                st    <= S_Y3;
            end
            S_Y3: begin
                y_r  <= y_sat;
                y_a0 <= y_sat;
                y_a1 <= y_sat;
                st   <= S_N1;
            end
            S_N1: begin
                p3 <= k_a1 * y_a0;
                p4 <= k_a2 * y_a1;
                st <= S_N2;
            end
            S_N2: begin                        // 空等拍：把两个 42 位和寄存
                sum_n1_r <= n1_acc;
                sum_n2_r <= n2_acc;
                st <= S_WR;
            end
            S_WR: begin
                st_waddr <= ch_r * (NB*NST) + band_r * NST + stage_r;
                st_wdata <= {s1_new, s2_new};
                st_we    <= 1'b1;
                st       <= S_WR2;
            end
            S_WR2: begin
                if (stage_r == 1'b0) begin
                    stage_r <= 1'b1;
                    st <= S_RD;
                end else begin
                    st <= S_ARD;
                end
            end

            // ---------------------------------------------------------- 累加器
            S_ARD: begin
                acc_raddr <= ch_r * NB + band_r;
                st <= S_ARD2;
            end
            S_ARD2: begin                     // 等 BRAM 读延迟；同时三个小乘法各打一拍
                // ★ 这一拍原来只是空等。y² 拆成 hi/lo 之后，三个 ≤18×18 乘法
                //   在这里各自落进自己 DSP 的 P 寄存器（y_r 整个累加器过程中
                //   都不变，提前一拍算完全等价），下一拍只剩一次加法。
                yphh <= yphh_w;
                yphl <= yphl_w;
                ypll <= ypll_w;
                st   <= S_ARD3;
            end
            S_ARD3: begin                     // 合项一拍 y² = yh²<<12 + yh·yl<<7 + yl²
                y_sq_r    <= y_sq_w;
                // ★ 这里原来写的是 sum_new_r <= sum_inc（BRAM 输出 + 48 位
                //   加法 → 寄存），实测 -0.795 ns，是全设计最坏路径。
                //   和平方和那条路一样拆：S_ARD3 只把 BRAM 输出打一拍，
                //   加法挪到 S_ARD4，那条路就变成 FF → 加法 → FF。
                sum_new_r <= acc_dout[47:0];
                // ★ BRAM 输出到写数据的 64 位加法必须拆开：BRAM 输出寄存器
                //   的时钟到出 + 一个 64 位 CARRY4 链串在一拍里实测 5.2 ns 逻辑。
                //   平方和这条路和 sum_inc 一样先寄存一拍。
                qsum_r    <= acc_dout[111:48];
                st <= S_ARD4;
            end
            // ★ 2026-10-18：64 位加法一拍做不完，拆成两拍。
            //   实测 y_sq_r_reg(CLK/P) -> acc_wdata_reg[107]/D = 4.896 ns
            //   = DSP 出 0.434 + 布线 0.844 + LUT2 0.124 + 布线 0.428
            //     + 11 级 CARRY4 ≈ 1.81 ns，只剩 +0.021 ns 裕量，而且是靠
            //   phys_opt 给 y_sq_w 这个 DSP 的时钟插了 5 级 BUFG
            //   （累计 +0.95 ns 的有用偏斜）才勉强转正的 —— 换一次实现就
            //   不一定成立。这里把 48 位有效加法分成低半/高半两拍，
            //   每拍进位链从 11 级降到 6 级，裕量不再依赖偏斜技巧。
            //   代价：每个 (通道,频带) +1 拍 = 一个窗多 310 拍，
            //   相对 63488 × 87 拍可忽略。
            S_ARD4: begin                     // 低 32 位相加（两条累加各一半）
                {cy_s, acc_lo_s} <= {1'b0, sum_new_r[31:0]} + {1'b0, yrext[31:0]};
                {cy_q, acc_lo_q} <= {1'b0, qsum_r[31:0]}    + {1'b0, y_sq_r[31:0]};
                st <= S_ARD5;
            end
            S_ARD5: begin                     // 高半 + 进位，然后置写
                acc_wdata[31:0]   <= acc_lo_s;
                acc_wdata[79:48]  <= acc_lo_q;
                acc_wdata[47:32]  <= {1'b0, sum_new_r[47:32]} + {1'b0, yrext[47:32]} + cy_s;
                acc_wdata[111:80] <= qsum_r[63:32] + {16'd0, y_sq_r[47:32]} + cy_q;
                acc_we <= 1'b1;
                st <= S_AWR;
            end
            S_AWR: begin
                if (band_r == NB-1) begin
                    if (beat_last_r) begin
                        idx <= 9'd0;
                        st  <= S_FRD;
                    end else begin
                        beat_cnt <= beat_cnt + 17'd1;
                        st <= S_IDLE;
                    end
                end else begin
                    band_r  <= band_r + 3'd1;
                    stage_r <= 1'b0;
                    st <= S_RD;
                end
            end

            // ---------------------------------------------------------- 收窗：逐个 log
            S_FRD: begin
                acc_raddr <= idx[8:0];
                res_waddr <= idx[8:0];
                st <= S_FRD2;
            end
            S_FRD2: st <= S_FRD3;             // 等 BRAM 读延迟
            S_FRD3: begin                     // 拆 hi/lo，锁 sumsq
                q_r   <= acc_dout[111:48];
                hi_r  <= acc_dout[35:18];
                lo_r  <= acc_dout[17:0];
                q72_r <= $signed({8'd0, acc_dout[111:48]}) <<< 10;
                st <= S_FRD4;
            end
            S_FRD4: begin                     // 三个 18×18 乘法
                phh <= phh_w;
                phl <= phl_w;
                pll <= pll_w;
                st <= S_FRD5;
            end
            S_FRD5: begin                     // 移位合并
                sq_a <= sq_a_w;
                sq_b <= sq_b_w;
                st <= S_FRD6;
            end
            S_FRD6: begin
                sq_sum_r <= sq_sum_w;
                st <= S_FRD7;
            end
            S_FRD7: begin
                varnum_r <= varnum_w;
                st <= S_FNORM;
            end
            S_FNORM: begin                    // 优先编码（norm_start 组合有效）
                st <= S_FNORM2;
            end
            S_FNORM2: begin                   // 等 norm72 的 valid（三级流水）
                if (norm_valid) st <= S_FWT;
                else            st <= S_FNORM2;
            end
            S_FNORM3: st <= S_FWT;            // 保留：当前流程不再进入
            S_FWT: begin
                if (cordic_done) begin
                    res_wdata <= cordic_out - (LOG_OFF <<< 16);
                    res_we    <= 1'b1;
                    st <= S_FW;
                end
            end
            S_FW: begin
                if (idx == NACC-1) begin
                    clr_idx  <= 10'd0;
                    auto_clr <= 1'b1;
                    st <= S_CLRW;
                end else begin
                    idx <= idx + 9'd1;
                    st  <= S_FRD;
                end
            end

            // ---------------------------------------------------------- 清累加器
            S_CLRW: begin
                acc_waddr <= clr_idx[8:0];
                acc_wdata <= 112'd0;
                acc_we    <= 1'b1;
                st <= S_CLRW2;
            end
            S_CLRW2: begin
                if (clr_idx == NACC-1) begin
                    if (auto_clr) begin
                        done     <= 1'b1;
                        win_cnt  <= win_cnt + 32'd1;
                        beat_cnt <= 17'd0;
                        st <= S_IDLE;
                    end else begin
                        st <= S_IDLE;                 // 外部请求：不置 done
                    end
                end else begin
                    clr_idx <= clr_idx + 10'd1;
                    st <= S_CLRW;
                end
            end

            // ---------------------------------------------------------- 清 IIR 状态
            S_SCLR: begin
                st_waddr <= clr_idx;
                st_wdata <= 48'd0;
                st_we    <= 1'b1;
                st <= S_SCLR2;
            end
            S_SCLR2: begin
                if (clr_idx == NSTATE-1) begin
                    st <= S_IDLE;
                end else begin
                    clr_idx <= clr_idx + 10'd1;
                    st <= S_SCLR;
                end
            end

            default: st <= S_IDLE;
            endcase
        end
    end
endmodule

`default_nettype wire
