`timescale 1ns/1ps
`default_nettype none

// ---------------------------------------------------------------------------
// 存储器向量目录（2026-10-29 去硬编码）
//   默认 ../vectors：从 sim/run/ 启动 xsim 即指向 sim/vectors/（已提交的金标准）。
//   覆盖：xvlog/xelab -d MEM_DIR="\"<dir>\""；综合前改这一处即可。
// ---------------------------------------------------------------------------
`ifndef MEM_DIR
  `define MEM_DIR "../vectors"
`endif

// =============================================================================
// attn_core.v -- R2GFANet 模块① 与 模块② 的 PL 定点引擎
//
//   规格唯一来源：work2/fixpt.py。本文件必须与它**逐位一致**，由
//   work2/tb/tb_attn.v 的 in.mem / exp_h.mem / exp_ze.mem / exp_zo.mem 比对验收。
//   任何算术改动先改 fixpt.py，再改这里，再跑 tb。
//
//   定点口径：权重 INT8 per-tensor，激活 INT16 per-tensor（统一 s_act），
//   乘累加 48 bit，重定量化 = Q15 乘子 + 算术右移（round-half-up，负数向下
//   取整，与 Python 的 >> 一致）。exp 为 256 项 LUT（步长 2^(-1/32)）。
//
//   scratch RAM 布局（8192 x 16）见 work2/export.py 的 IN_E..ZPO 常量。
//   指令格式见 work2/export.py 的 enc()。
//
//   结构：单口 scratch（一拍一读一写）+ 指令 ROM 驱动的顺序引擎。所有重定
//   量化走同一个 3 拍单元 (wq_*)，除法走同一个 32 拍恢复余数除法器。
//   模块③（组间注意力，含 tanh）在 PS 侧，不在此文件。
// =============================================================================
module attn_core #(
    parameter integer T = 4,          // 时间步
    parameter integer D = 16,         // 每组隐维
    // ★ 2026-10-24：M=3 支持。UM = 注意力里 k/v 的最大行数 = T*(M-1)。
    //   M=2 时 U=4，M=3 时 U=8。array lgv/pv/aqv/avv 按 UM 开，索引位宽 UMW。
    parameter integer UM = 8
)(
    input  wire        clk,
    input  wire        rst_n,

    input  wire        start,
    output reg         busy,
    output reg         done,

    // ---- host 端口（TB / PS 装载输入、取回结果）
    input  wire        hw_en,
    input  wire [12:0] hw_addr,
    input  wire [15:0] hw_data,
    input  wire [12:0] hr_addr,
    output reg  [15:0] hr_data
);

    // ---------------------------------------------------------------- 常量
    localparam signed [15:0] QMINI = -16'sd32768;
    localparam integer LG2T = (T == 4) ? 2 : ((T == 8) ? 3 : 2);
    localparam [5:0] T6    = T[5:0];
    localparam [5:0] LG2T6 = LG2T[5:0];
    localparam integer UMW = (UM <= 2) ? 1 : ((UM <= 4) ? 2 : ((UM <= 8) ? 3 : 4));

    localparam [3:0] S_IDLE = 4'd0, S_FETCH = 4'd1, S_EXEC = 4'd2,
                     S_GM   = 4'd3, S_LD    = 4'd4, S_PE   = 4'd5,
                     S_AT   = 4'd6, S_RG    = 4'd7, S_CP   = 4'd8;
    localparam [1:0] C_ST0 = 2'd0, C_ST1 = 2'd1, C_ST2 = 2'd2;

    localparam [5:0] A_T0 = 5'd0,  A_QL = 5'd1,  A_K0 = 5'd2,  A_KM = 5'd3,
                     A_KQ = 5'd4,  A_KW = 5'd5,  A_MX0= 5'd6,  A_MX = 5'd7,
                     A_EX0= 5'd8,  A_EX = 5'd9,  A_EXB= 5'd10, A_EXC= 5'd11,
                     A_AQ0= 5'd12, A_AQI= 5'd13, A_AQW= 5'd14, A_KK0= 5'd15,
                     A_KK = 5'd16, A_AA0= 5'd17, A_AAI= 5'd18, A_AAW= 5'd19,
                     A_AV0= 5'd20, A_AV1= 5'd21, A_AV2= 5'd22, A_AV3= 5'd23,
                     A_AV4= 5'd24, A_TN = 5'd25,
                     A_QLW= 6'd26, A_KW2= 6'd27, A_AVW= 6'd28, A_AV2W=6'd29,
                     A_EXM= 6'd30, A_AVP= 6'd31, A_AVS= 6'd32, A_AVZ= 6'd33,
                     A_KV = 6'd34, A_KP = 6'd35, A_AVQ= 6'd36,
                     A_AQR= 6'd37, A_AAR= 6'd38, A_EXN= 6'd39,
                     A_KKR= 6'd40;

    // ---------------------------------------------------------------- ROM/RAM
    reg [15:0] mem [0:8191];

    // ★ 2026-10-24：dont_touch 见 wa_w 声明处（REQP-1962）。ROM 只读，钉死无副作用。
    (* dont_touch = "true" *) reg [7:0] wrom [0:131071];
    // ★ 2026-10-24：brom 2048→4096（M=3 的 bias 总数 2,656 > 2,047）。
    reg signed [15:0] brom [0:4095];
    // ★ 2026-10-24：irom 256→512（M=3 约 331 条指令）。
    reg [159:0]       irom [0:511];
    reg [15:0]        perom[0:63];
    reg [15:0]        dlut [0:7];
    reg [7:0]         elut [0:255];
    reg [23:0]        kcmem [0:0];
    wire [23:0]       kcreg = kcmem[0];

    reg [7:0]         wd;
    reg signed [15:0] bd;
    reg [159:0]       ir;
    reg signed [15:0] ped;
    reg [7:0]         eld;

`ifdef SIMULATION
    reg [1023:0] ipath;
`endif
    integer ii;
    initial begin
`ifdef SIMULATION
        if (!$value$plusargs("INSTR=%s", ipath))
            ipath = {`MEM_DIR, "/instr.mem"};
`endif
        // ★★ 2026-10-24：Vivado 对 initial 块里的 for 循环有 65536 次上限
        //   （[Synth 8-6896]）。**一旦超限，整个 initial 块被丢弃** ——
        //   不只是这条循环，后面的每一条 $readmemh 都不执行，于是 IROM 全 0。
        //   位流里 op=0 就是 END，start 后 2 拍 done、输出全 0。
        //   M=2 的 wrom 只有 32,768 项（循环 32,768 次）所以一直没暴露；
        //   M=3 把 wrom 扩到 131,072 项就踩中了，而且综合只给一条 WARNING。
        //   现在拆成 8 段，每段 16,384 次。
        for (ii = 0;     ii < 16384;  ii = ii + 1) wrom[ii] = 8'd0;
        for (ii = 16384; ii < 32768;  ii = ii + 1) wrom[ii] = 8'd0;
        for (ii = 32768; ii < 49152;  ii = ii + 1) wrom[ii] = 8'd0;
        for (ii = 49152; ii < 65536;  ii = ii + 1) wrom[ii] = 8'd0;
        for (ii = 65536; ii < 81920;  ii = ii + 1) wrom[ii] = 8'd0;
        for (ii = 81920; ii < 98304;  ii = ii + 1) wrom[ii] = 8'd0;
        for (ii = 98304; ii < 114688; ii = ii + 1) wrom[ii] = 8'd0;
        for (ii = 114688;ii < 131072; ii = ii + 1) wrom[ii] = 8'd0;
        for (ii = 0; ii < 4096;  ii = ii + 1) brom[ii]  = 16'sd0;
        for (ii = 0; ii < 512;   ii = ii + 1) irom[ii]  = 160'd0;
        for (ii = 0; ii < 64;    ii = ii + 1) perom[ii] = 16'd0;
        for (ii = 0; ii < 8;     ii = ii + 1) dlut[ii]  = 16'd0;
        for (ii = 0; ii < 8192;  ii = ii + 1) mem[ii]   = 16'd0;
        $readmemh({`MEM_DIR, "/w_i8.mem"},    wrom);
        $readmemh({`MEM_DIR, "/bias.mem"},    brom);
`ifdef SIMULATION
        $readmemh(ipath,                                   irom);
`else
        $readmemh({`MEM_DIR, "/instr.mem"}, irom);
`endif
        $readmemh({`MEM_DIR, "/pe.mem"},      perom);
        $readmemh({`MEM_DIR, "/delta.mem"},   dlut);
        $readmemh({`MEM_DIR, "/exp_lut.mem"}, elut);
        $readmemh({`MEM_DIR, "/kc.mem"},      kcmem);
    end

    // ---------------------------------------------------------------- 地址口
    reg        e_we;
    reg [12:0] e_waddr;
    reg [15:0] e_wdata;
    reg [12:0] e_raddr;
    // ★ 2026-10-24：dont_touch 是 REQP-1962 的解药，不是时序调优。
    //   131,072 项的 wrom 在 7 系列上被实现成 16 列 × 2 级级联（32 块 RAMB36），
    //   级联对的两块 RAMB 必须拿到**同一个** ADDRARDADDR[15] 驱动。全 BD 的
    //   opt_design 会把这个地址锥重构/复制成不同的 LUT 锥（布线前网表里
    //   驱动叫 inst_n_8 之类），于是 place 前的 REQP-1962 报 16 条、拒绝布局。
    //   只读 ROM 不需要任何优化 ⇒ 连阵列带地址寄存器一起钉死。
    (* dont_touch = "true" *) reg [16:0] wa_w;
    reg [11:0] wa_b;
    reg [5:0]  wa_p;

    wire        m_we    = busy ? e_we    : hw_en;
    wire [12:0] m_waddr = busy ? e_waddr : hw_addr;
    wire [15:0] m_wdata = busy ? e_wdata : hw_data;
    wire [12:0] m_raddr = busy ? e_raddr : hr_addr;

    reg signed [15:0] rd;

    always @(posedge clk) begin
        if (m_we) mem[m_waddr] <= m_wdata;
        rd      <= mem[m_raddr];
        hr_data <= mem[m_raddr];
    end

    always @(posedge clk) begin
        wd  <= wrom[wa_w];
        bd  <= brom[wa_b];
        ped <= perom[wa_p];
    end

    // ---------------------------------------------------------------- 指令域
    // ★ 2026-10-24：W 16→17 bit（M=3 的 wrom ≈68,700 B 需要）。原来这里写的
    //   `wire [14:0] o_W = ir[45:30]` 本身就漏了最高位——enc() 按 16 bit 打包，
    //   RTL 只取 15 bit。M=2 的 W 最大 29,984 < 32,768 所以一直没暴露；
    //   一旦 W ≥ 32,768 就会静默别名。现在字段整体后移 1 bit，[159:154] 空闲。
    wire [3:0]  o_op = ir[3:0];
    wire [12:0] o_A  = ir[16:4];
    wire [12:0] o_B  = ir[29:17];
    wire [16:0] o_W  = ir[46:30];
    wire [12:0] o_C  = ir[59:47];
    wire [12:0] o_D  = ir[72:60];
    wire [5:0]  o_N  = ir[78:73];
    wire [5:0]  o_O  = ir[84:79];
    wire [8:0]  o_K  = ir[93:85];
    wire [14:0] o_M  = ir[108:94];
    wire [5:0]  o_SH = ir[114:109];
    wire [8:0]  o_SS = ir[123:115];
    wire [8:0]  o_DS = ir[132:124];
    wire [14:0] o_AM = ir[147:133];
    wire [5:0]  o_ASH= ir[153:148];

    // ---------------------------------------------------------------- 主状态机寄存器
    reg [3:0]  st;
    reg [8:0]  pc;          // ★ irom 512 项 ⇒ 9 bit

    reg [12:0] na, ncd, gco;
    reg [16:0] gw;
    reg [8:0]  ph;
    // ★ GEMM 结束标志改成一拍前寄存：原来 `ph == K+4` 要穿过 ph 自增的
    //   CARRY4（st1，扇出 66）再去驱动 wq_go（扇出 27）→ DSP 的 CE，是
    //   200 MHz 下的最差路径。现在 `ph == K+3` 时把标志打一拍，下一拍
    //   （正好 ph == K+4）直接用寄存器输出，控制链不再穿进位链。
    reg        ph_hit;
    // ★ GEMM 的"等重定量化完成"状态也用一位粘滞寄存器 gwait：原来靠
    //   `ph >= K+4` 比较（要穿过 ph 自增的 CARRY4）驱动 wq_go → DSP CE，
    //   是 200 MHz 下的一族最差路径。现在 wq_go 只由 ph_hit 这个寄存器决定。
    reg        gwait;
    reg [5:0]  gn, go;
    reg signed [47:0] acc;

    reg [3:0]  lp;
    reg [12:0] lna, lnd;
    reg [5:0]  lc, ln, lt;
    reg signed [15:0] lxc, w0r, w1r, py, pr;
    reg signed [15:0] prev [0:15];
    reg signed [15:0] prv;        // prev 的寄存读（喂 DSP，见 lp=4）
    reg signed [47:0] lds_r;      // LDS 和寄存一拍再进 requant
    reg signed [31:0] lds_p0r, lds_p1r;
    reg signed [15:0] rgv;         // RESGAP 读回值寄存（BRAM 出口先进触发器）   // 两个乘积各自寄存（DSP P 出口不能直接接另一个 DSP 的 C 口）

    // ★ OP_CPY（M=3 的 kv 拼接）：A→B，N 行，每行 O 字，源距 SS、目的距 DS。
    //   ★ 写口不能在 S_CP 里直接赋 e_we/e_waddr/e_wdata —— 那三个寄存器已经由
    //     重定量化那个 always 块驱动，两个 always 同时赋值会在 opt_design 时
    //     报 MDRV-1（Multiple Driver Nets）。所以这里只发「请求」，由块①统一提交。
    reg [1:0]  cpst;
    reg [12:0] cna, cnb;
    reg [5:0]  cco, cn;
    reg        cp_req;
    reg [12:0] cp_waddr;
    reg [15:0] cp_wdata;

    reg [2:0]  rgp;
    reg [12:0] rga;
    reg [5:0]  rn, rc;
    reg signed [47:0] racc;

    reg [5:0]  ast;
    reg [5:0]  at_t, at_u, at_c;
    // (at_u == o_O-1) 的寄存版：A_AVQ 拍锁存，A_AVS 拍用。
    // 原来是 at_u 比较 -> 13 位加法器 -> e_raddr 的多路选择，9 级逻辑、4 级进位链，
    // AXI 封装后 200 MHz 下 -0.020 ns。at_u 在 A_AVQ/A_AVP 两拍内不变，
    // 所以把它提前一拍寄存，选择信号就从关键路径上挪走了。
    reg        at_last;
    reg [12:0] qa, zb, tb2;
    reg [255:0] qsr;
    // ★ 2026-10-24：从 [0:3]（M=2，U=4）扩到 [0:UM-1]，M=3 时 U=8。
    reg signed [15:0] lgv [0:UM-1];
    reg [7:0]  pv  [0:UM-1];
    reg signed [15:0] aqv [0:UM-1];
    reg signed [15:0] avv [0:UM-1];
    // ★ δ 剪枝的 one-hot 保底：记录**剪枝前** aqv 的最大值与下标（对应
    //   fixpt.align 的 `am = np.argmax(pre)`）。M=2 下 at_S 恒 >0 不触发；
    //   M=3 下 δ=1/(t+1) 会让 91.8% 的行整行清零，必须走这条分支。
    reg signed [15:0] at_amx;
    reg [UMW-1:0]     at_ami;
    reg signed [15:0] at_mx, avtok;
    reg signed [47:0] at_acc;
    reg [31:0] at_P, at_S;
    reg [15:0] at_exd;
    reg signed [15:0] at_rv;      // ATTN 读回的 v（BRAM 输出先寄存）
    reg signed [15:0] at_rv2;     // 第二级（保证不被吸收进 BRAM 输出寄存器）
    reg signed [31:0] at_pd;      // ATTN v*avv 乘积
    reg signed [15:0] avvr;       // avv[at_u] 的寄存读（让 DSP 用 AREG）
    reg signed [15:0] pvr;        // pv [at_u] 的寄存读
    reg signed [15:0] aqvr;       // aqv[at_u] 的寄存读
    reg signed [15:0] akk_r;      // A_KK 的寄存读（LUTRAM 异步读 + 累加 + 判零同拍会崩）
    reg signed [15:0] at_kv;      // ATTN q*k 的 k（BRAM 输出先寄存）
    reg signed [31:0] at_kd;      // ATTN q*k 乘积
    reg [23:0] at_exi;
    reg [39:0] at_exm;            // ex_idx 的寄存（DSP P 出口不能直接挂钳位再进 BRAM 地址）
    reg        at_exv;
    reg signed [15:0] dcur;

    // ---------------------------------------------------------------- 乘法
    wire signed [15:0] qsr_hi = qsr[255:240];
    // ★ GEMM：rd/wd 都不能直接进 DSP。rd 的寄存器会被 Vivado 吸收进 RAMB 的
    //   输出寄存器（时序报告里就是 mem/CLKBWRCLK -> DOBDO -> DSP.A，2.45+1.38 ns），
    //   所以这里再插一级专用寄存器 gd_r/gwd_r，把 BRAM 输出和 DSP 彻底隔开。
    //   代价：GEMM 主循环 +1 拍（见 S_GM 的相位窗口）。
    reg  signed [15:0] gd_r;
    reg         [7:0] gwd_r;
    wire signed [23:0] prod24 = gd_r * $signed(gwd_r);
    wire signed [31:0] prod32 = qsr_hi * rd;
    wire signed [47:0] prod   = {{24{prod24[23]}}, prod24};
    reg  signed [47:0] prod_r;    // 乘积先寄存一拍（200 MHz 下 BRAM 输出不能直接挂 DSP+加法器）
    wire signed [47:0] prodq  = {{16{prod32[31]}}, prod32};

    wire signed [31:0] lds_p0 = prv * w0r;
    wire signed [31:0] lds_p1 = lxc * w1r;
    wire signed [47:0] lds_sum = (lt == 6'd0)
        ? {{16{lds_p1[31]}}, lds_p1}
        : ({{16{lds_p0[31]}}, lds_p0} + {{16{lds_p1[31]}}, lds_p1});

    // ---------------------------------------------------------------- 重定量化 + 写回
    // 7 拍流水（原本 3 拍，200 MHz 下 72 位变移位 + 两级钳位 + 加 bias 挤在
    // 一拍里 WNS=-10.8ns，拆开后每拍只做一件事）：
    //   0 乘   1 一位热码  2 加舍入  3 变移位  4 首次钳位  5 加 bias 再钳  6 写
    reg         wq_go, wq_wr;
    reg signed [47:0] wq_acc;
    reg [14:0]  wq_m;
    reg [5:0]   wq_sh;
    reg         wq_pre;
    reg signed [15:0] wq_add;
    reg [12:0]  wq_addr;
    reg [2:0]   wq_st;
    reg         wq_done;
    reg signed [71:0] wq_pm, wq_ps, wq_r, wq_s;
    reg signed [15:0] wq_c, wq_out;
    // ★ 原来 wq_out 那一拍要同时做「17 位加法 + 三次比较 + 选择」，
    //   综合出来 9 级（6 个 CARRY4），WNS -0.362。把加法单独打一拍：
    //   wq_sumr 先寄存和，下一拍只剩 17 位饱和判断。
    reg signed [16:0] wq_sumr;

    // ★ 48x15 的 M 乘法会被 Vivado 拆成两个 DSP48 并用 PCOUT->PCIN 级联，
    //   那条级联路径在 200 MHz 下 4.206 ns（WNS -0.692）。这里显式拆成
    //   hi/lo 两个独立的 24x15 部分积，各自进一个 DSP，和在 fabric 里合并：
    //       acc*M = (acc[47:24]*M)<<24 + acc[23:0]*M
    //   低 24 位直接就是 lo 部分积，只有高位需要一次 39 位加法。
    reg signed [38:0] wq_mhi;
    reg        [38:0] wq_mlo;
    wire signed [38:0] wq_msum = wq_mhi + $signed({24'd0, wq_mlo[38:24]});

    wire signed [71:0] wq_presh = wq_pre ? (72'sd1 <<< (wq_sh - 6'd1)) : 72'sd0;
    wire signed [71:0] wq_v1    = (wq_s > 72'sd32767) ? 72'sd32767 :
                                  ((wq_s < -72'sd32768) ? -72'sd32768 : wq_s);
    wire signed [16:0] wq_sum   = wq_sumr;
    wire signed [15:0] wq_v3    = (wq_sum > 17'sd32767) ? 16'sd32767 :
                                  ((wq_sum < -17'sd32768) ? -16'sd32768 : wq_sum[15:0]);

    always @(posedge clk) begin
        if (!rst_n) begin
            wq_st <= 3'd0; wq_done <= 1'b0; e_we <= 1'b0;
            wq_out <= 16'sd0; wq_pm <= 72'sd0;
            wq_ps <= 72'sd0; wq_r <= 72'sd0; wq_s <= 72'sd0; wq_c <= 16'sd0;
            wq_mhi <= 39'sd0; wq_mlo <= 39'd0; wq_sumr <= 17'sd0;
            e_waddr <= 13'd0; e_wdata <= 16'd0;
            // ★★ 2026-10-24：这里**不能**再写 cp_req/cp_waddr/cp_wdata。
            //   它们是 S_CP 状态发出的单拍脉冲，已经由主状态机那个 always
            //   块复位（本文件下面的 S_IDLE 分支）。两个块都赋同一个 reg
            //   就是 MDRV，Vivado 的处理方式是"保留常量驱动、忽略另一个"
            //   —— 于是 cp_req 恒为 0，OP_CPY 永远不写内存，而且只报
            //   90 条 CRITICAL WARNING，综合照常出位流。
        end else begin
            wq_done <= 1'b0;
            e_we    <= 1'b0;
            e_waddr <= wq_addr;
            e_wdata <= wq_out;
            case (wq_st)
            3'd0: if (wq_go) begin
                      wq_mhi <= $signed(wq_acc[47:24]) * $signed({1'b0, wq_m});
                      wq_mlo <= wq_acc[23:0] * {1'b0, wq_m};
                      wq_st <= 3'd1;
                  end
            3'd1: begin
                      wq_pm <= {{9{wq_msum[38]}}, wq_msum, wq_mlo[23:0]};
                      wq_ps <= wq_presh;      wq_st <= 3'd2;
                  end
            3'd2: begin wq_r   <= wq_pm + wq_ps; wq_st <= 3'd3; end
            3'd3: begin wq_s   <= wq_r >>> wq_sh; wq_st <= 3'd4; end
            3'd4: begin wq_c   <= wq_v1[15:0];   wq_st <= 3'd5; end
            3'd5: begin wq_sumr<= wq_c + wq_add; wq_st <= 3'd6; end
            3'd6: begin wq_out <= wq_v3;         wq_st <= 3'd7; end
            default: begin
                      if (wq_wr) e_we <= 1'b1;
                      wq_done <= 1'b1;
                      wq_st   <= 3'd0;
                  end
            endcase
            // ★ OP_CPY 的写请求由 S_CP 发出、在这里统一提交，保证
            //   e_we/e_waddr/e_wdata 只有这一个 always 块驱动（MDRV-1）。
            if (cp_req) begin
                e_we    <= 1'b1;
                e_waddr <= cp_waddr;
                e_wdata <= cp_wdata;
            end
        end
    end

    // ---------------------------------------------------------------- 除法器
    reg         dv_go, dv_done;
    // ★ 原来是 `{24'd0,pvr} * 32'd32767 + (at_P>>1)`，Vivado 把它实现成
    //   DSP48（A 口吃 pvr，B=32767），DSP 的 A 建立时间 3.722 ns 直接把
    //   pvr -> dv_num 这条控制路径压到 -0.444 ns。32767 = 2^15-1，改成
    //   移位相减即**逐位等价**（pvr/aqvr 都被零扩展后当无符号用），再把
    //   dv_num 钉死在 fabric，不再进 DSP。
    (* use_dsp = "no" *) reg [31:0] dv_num;
    reg [31:0]  dv_den;
    wire [31:0] dv_mul_p = ({16'd0, pvr } << 15) - {16'd0, pvr };   // pvr *32767
    wire [31:0] dv_mul_a = ({16'd0, aqvr} << 15) - {16'd0, aqvr};   // aqvr*32767
    reg [31:0]  dv_q, dv_r, dv_n;
    reg [5:0]   dv_i;
    reg         dv_busy;
    // ★ 逐位除法原来一拍里做"移位 + 33 位比较 + 32 位相减 + 写回"，
    //   dv_r -> dv_r 的进位链要走满 32 位（200 MHz 下 WNS=-0.129，最大一族）。
    //   现在拆成两拍：
    //     ph=0 减法拍：只算 candidate-dv_den 并把差/借位寄存下来；
    //     ph=1 提交拍：按借位选 diff 或 candidate，再移位。
    //   迭代数不变（32 次），每步 2 拍；32 位相减的进位链不再和移位/写回串一起。
    //   减法用 33 位无符号：sub[32] 就是借位，比较器一并省掉（逐位等价）。
    reg         dv_ph;
    reg [31:0]  dv_diff;
    reg         dv_ge;
    wire [31:0] dv_cand = {dv_r[30:0], dv_n[31]};
    wire [32:0] dv_sub  = {1'b0, dv_cand} - {1'b0, dv_den};

    always @(posedge clk) begin
        if (!rst_n) begin
            dv_busy <= 1'b0; dv_done <= 1'b0; dv_i <= 6'd0;
            dv_q <= 32'd0; dv_r <= 32'd0; dv_n <= 32'd0;
            dv_ph <= 1'b0; dv_diff <= 32'd0; dv_ge <= 1'b0;
        end else begin
            dv_done <= 1'b0;
            if (dv_go) begin
                dv_n <= dv_num; dv_r <= 32'd0; dv_q <= 32'd0;
                dv_i <= 6'd0; dv_busy <= 1'b1; dv_ph <= 1'b0;
            end else if (dv_busy) begin
                if (!dv_ph) begin
                    dv_diff <= dv_sub[31:0];
                    dv_ge   <= ~dv_sub[32];
                    dv_ph   <= 1'b1;
                end else if (dv_i == 6'd32) begin
                    dv_busy <= 1'b0;
                    dv_done <= 1'b1;
                end else begin
                    dv_r  <= dv_ge ? dv_diff : dv_cand;
                    dv_q  <= {dv_q[30:0], dv_ge};
                    dv_n  <= {dv_n[30:0], 1'b0};
                    dv_i  <= dv_i + 6'd1;
                    dv_ph <= 1'b0;
                end
            end
        end
    end

    // ---------------------------------------------------------------- exp 索引
    // ★ 2026-10-24：因果掩码的**下标是 u%T**，不是 u。
    //   kv 是按序列拼的（[tok_other1; tok_other2; ...]），第 i 段的第 t 行
    //   与第 j 段的第 t 行共享同一个时间下标，所以可见性 = (u % T) <= 查询 t。
    //   M=2 时 U=T，u%T == u，和原来的 `at_u <= at_t` 逐位等价（M=2 回归已证）。
    //   M=3 时原来只放行第 0 段，t>=2 起注意力权重整体偏掉 —— 这正是 Z 失配的根因。
    wire        at_val = (at_u[LG2T-1:0] <= at_t[LG2T-1:0]);   // u%T <= t
    wire [15:0] ex_diff = at_mx - lgv[at_u[UMW-1:0]];  // A_EX 拍：读 lgv
    wire [39:0] ex_mul  = at_exd * kcreg;          // A_EXM 拍：吃寄存的差值
    wire [39:0] ex_idx  = (ex_mul + 40'd8388608) >> 24;

    // krow/vrow1 原来是 at_u*o_K 的组合式，200 MHz 下 at_u -> 乘 -> 加 -> e_raddr
    // 两级链太慢；改成增量寄存：每换一个 u 就 += o_K。
    reg  [12:0] krow_r;
    reg  [12:0] qbase;            // qa + o_K - 1，预计算（去掉 q 地址的两级加法）

    // ---------------------------------------------------------------- 主状态机
    always @(posedge clk) begin
        if (!rst_n) begin
            st <= S_IDLE; busy <= 1'b0; done <= 1'b0; pc <= 8'd0;
            e_raddr <= 13'd0; wa_w <= 15'd0; wa_b <= 12'd0; wa_p <= 6'd0;
            wq_go <= 1'b0; wq_wr <= 1'b0; wq_acc <= 48'sd0; wq_m <= 15'd0;
            wq_sh <= 6'd0; wq_pre <= 1'b0; wq_add <= 16'sd0; wq_addr <= 13'd0;
            dv_go <= 1'b0; dv_num <= 32'd0; dv_den <= 32'd1;
            ph <= 9'd0; gwait <= 1'b0; gn <= 6'd0; go <= 6'd0; lp <= 3'd0; rgp <= 3'd0;
            ast <= A_T0; at_t <= 6'd0; at_u <= 6'd0; at_c <= 6'd0; at_last <= 1'b0;
            at_P <= 32'd0; at_S <= 32'd0; at_acc <= 48'sd0;
            at_exi <= 24'd0; at_exv <= 1'b0; at_mx <= 16'sd0; at_exd <= 16'd0;
            at_amx <= 16'sd0; at_ami <= {UMW{1'b0}};
            cpst <= C_ST0; cna <= 13'd0; cnb <= 13'd0; cco <= 6'd0; cn <= 6'd0;
            cp_req <= 1'b0; cp_waddr <= 13'd0; cp_wdata <= 16'd0;
            na <= 13'd0; ncd <= 13'd0; gco <= 13'd0; gw <= 17'd0;
            lna <= 13'd0; lnd <= 13'd0; rga <= 13'd0; racc <= 48'sd0;
            acc <= 48'sd0; qa <= 13'd0; zb <= 13'd0; tb2 <= 13'd0; prod_r <= 48'sd0;
            lc <= 6'd0; ln <= 6'd0; lt <= 6'd0; rn <= 6'd0; rc <= 6'd0;
            lxc <= 16'sd0; w0r <= 16'sd0; w1r <= 16'sd0; py <= 16'sd0;
            pr <= 16'sd0; avtok <= 16'sd0; dcur <= 16'sd0;
        end else begin
            done   <= 1'b0;
            wq_go  <= 1'b0;
            dv_go  <= 1'b0;
            cp_req <= 1'b0;          // 单拍脉冲：S_CP 的 C_ST2 里置 1

            case (st)
            S_IDLE: begin
                if (start) begin
                    busy <= 1'b1; pc <= 8'd0; st <= S_FETCH;
                end
            end
            S_FETCH: begin
                ir <= irom[pc];
                st <= S_EXEC;
            end
            S_EXEC: begin
                case (o_op)
                4'd0: begin busy <= 1'b0; done <= 1'b1; st <= S_IDLE; end
                4'd1: begin                                    // GEMM
                    na <= o_A; ncd <= o_B; gw <= o_W; gco <= o_C;
                    gn <= 6'd0; go <= 6'd0; ph <= 9'd0; acc <= 48'sd0;
                    gwait <= 1'b0;
                    st <= S_GM;
                end
                4'd2: begin                                    // LDS
                    lp <= 3'd0; lna <= o_A; lnd <= o_B; lc <= 6'd0; ln <= 6'd0; lt <= 6'd0;
                    st <= S_LD;
                end
                4'd3: begin                                    // PE
                    lp <= 3'd0; lna <= o_B; lc <= 6'd0; ln <= 6'd0; lt <= 6'd0;
                    st <= S_PE;
                end
                4'd4: begin                                    // ATTN
                    ast <= A_T0; at_t <= 6'd0; at_u <= 6'd0; at_c <= 6'd0; at_last <= 1'b0;
                    qa <= o_A; zb <= o_C; tb2 <= o_D;
                    at_P <= 32'd0; at_S <= 32'd0;
                    st <= S_AT;
                end
                4'd5: begin                                    // RESGAP
                    rgp <= 3'd0; rga <= o_A; racc <= 48'sd0;
                    rn <= 6'd0; rc <= 6'd0;
                    st <= S_RG;
                end
                4'd6: begin                                    // CPY
                    cpst <= C_ST0; cna <= o_A; cnb <= o_B;
                    cco <= 6'd0; cn <= 6'd0;
                    st <= S_CP;
                end
                default: begin busy <= 1'b0; done <= 1'b1; st <= S_IDLE; end
                endcase
            end

            // ------------------------------------------------ GEMM
            S_GM: begin
                gd_r  <= rd;
                gwd_r <= wd;
                prod_r <= prod;
                ph_hit <= (ph == ({1'b0, o_K} + 9'd3));
                if (ph < {1'b0, o_K}) begin
                    e_raddr <= na + {{7{1'b0}}, ph[5:0]};
                    wa_w    <= gw;
                    gw      <= gw + 17'd1;
                end else if (ph == {1'b0, o_K}) begin
                    wa_b <= gco[11:0];
                end
                // raddr/waddr -> rd/wd -> gd_r/gwd_r -> prod -> prod_r
                // prod_r 在 ph 拍装的是元素 ph-4；累加窗口随之下移一拍
                if (ph >= 9'd4 && ph < ({1'b0, o_K} + 9'd4))
                    acc <= acc + prod_r;
                if (ph_hit) begin
                    wq_acc  <= acc;
                    wq_m    <= o_M;
                    wq_sh   <= o_SH;
                    wq_pre  <= 1'b1;
                    wq_add  <= bd;
                    wq_addr <= ncd + {{7{1'b0}}, go};
                    wq_wr   <= 1'b1;
                    wq_go   <= 1'b1;
                    gwait   <= 1'b1;
                    ph      <= ph + 9'd1;
                end else if (!gwait) begin
                    ph <= ph + 9'd1;
                end else begin
                    if (wq_done) begin
                        ph    <= 9'd0;
                        gwait <= 1'b0;
                        acc   <= 48'sd0;
                        if (go == o_O - 6'd1) begin
                            go  <= 6'd0;
                            gco <= o_C;
                            if (gn == o_N - 6'd1) begin
                                pc <= pc + 8'd1; st <= S_FETCH;
                            end else begin
                                gn  <= gn + 6'd1;
                                na  <= na  + {{4{1'b0}}, o_SS};
                                ncd <= ncd + {{4{1'b0}}, o_DS};
                                // 同一权重矩阵作用于每一行输入 ⇒ 换行必须把权重指针复位
                                gw  <= o_W;
                            end
                        end else begin
                            go  <= go + 6'd1;
                            gco <= gco + 13'd1;
                        end
                    end
                end
            end

            // ------------------------------------------------ LDS
            S_LD: begin
                case (lp)
                3'd0: begin
                    e_raddr <= lna + {{7{1'b0}}, lc};
                    wa_w    <= o_W + {{10{1'b0}}, lc, 1'b0};
                    lp <= 3'd1;
                end
                3'd1: begin
                    lp <= 3'd2;          // wait: raddr/waddr are one stage deep
                end
                3'd2: begin
                    lxc  <= rd;
                    w0r  <= $signed(wd);
                    wa_w <= o_W + {{10{1'b0}}, lc, 1'b0} + 17'd1;
                    wa_b <= o_C[11:0] + {{6{1'b0}}, lc};
                    lp <= 3'd3;
                end
                3'd3: begin
                    lp <= 3'd4;          // wait: second weight one stage deep
                end
                3'd4: begin
                    w1r <= $signed(wd);
                    prv <= prev[lc[3:0]];    // prev 是 LUTRAM，读出来先寄存
                    lp  <= 3'd5;
                end
                3'd5: begin
                    lds_p0r <= lds_p0;       // 乘积各寄存一拍
                    lds_p1r <= lds_p1;
                    lp <= 3'd6;
                end
                3'd6: begin
                    // 两个乘积都已在触发器上：普通加法器即可（P->C 的 DSP 内部通路太慢）
                    lds_r <= (lt == 6'd0)
                        ? {{16{lds_p1r[31]}}, lds_p1r}
                        : ({{16{lds_p0r[31]}}, lds_p0r} + {{16{lds_p1r[31]}}, lds_p1r});
                    lp <= 3'd7;
                end
                3'd7: begin
                    wq_acc  <= lds_r;
                    wq_m    <= o_M;
                    wq_sh   <= o_SH;
                    wq_pre  <= 1'b1;
                    wq_add  <= bd;
                    wq_addr <= lnd + {{7{1'b0}}, lc};
                    wq_wr   <= 1'b1;
                    wq_go   <= 1'b1;
                    lp <= 4'd8;
                end
                default: begin
                    if (wq_done) begin
                        prev[lc[3:0]] <= lxc;
                        lp <= 3'd0;
                        if (lc == o_O - 6'd1) begin
                            lc  <= 6'd0;
                            ln  <= ln + 6'd1;
                            lna <= lna + {{4{1'b0}}, o_SS};
                            lnd <= lnd + {{4{1'b0}}, o_DS};
                            lt  <= (lt == T6 - 6'd1) ? 6'd0 : (lt + 6'd1);
                            if (ln == o_N - 6'd1) begin
                                pc <= pc + 8'd1; st <= S_FETCH;
                            end
                        end else begin
                            lc <= lc + 6'd1;
                        end
                    end
                end
                endcase
            end

            // ------------------------------------------------ PE
            S_PE: begin
                case (lp)
                3'd0: begin
                    e_raddr <= lna + {{7{1'b0}}, lc};
                    wa_p    <= {lt[1:0], lc[3:0]};
                    lp <= 3'd1;
                end
                3'd1: begin
                    lp <= 3'd2;          // wait: raddr is one stage deep
                end
                3'd2: begin
                    py <= rd;
                    pr <= ped;
                    lp <= 3'd3;
                end
                3'd3: begin
                    wq_acc  <= py;
                    wq_m    <= 15'd1;
                    wq_sh   <= 6'd0;
                    wq_pre  <= 1'b0;
                    wq_add  <= pr;
                    wq_addr <= lna + {{7{1'b0}}, lc};
                    wq_wr   <= 1'b1;
                    wq_go   <= 1'b1;
                    lp <= 3'd4;
                end
                default: begin
                    if (wq_done) begin
                        lp <= 3'd0;
                        if (lc == o_O - 6'd1) begin
                            lc  <= 6'd0;
                            ln  <= ln + 6'd1;
                            lna <= lna + {{4{1'b0}}, o_SS};
                            lt  <= (lt == T6 - 6'd1) ? 6'd0 : (lt + 6'd1);
                            if (ln == o_N - 6'd1) begin
                                pc <= pc + 8'd1; st <= S_FETCH;
                            end
                        end else begin
                            lc <= lc + 6'd1;
                        end
                    end
                end
                endcase
            end

            // ------------------------------------------------ RESGAP
            S_RG: begin
                case (rgp)
                3'd0: begin
                    e_raddr <= rga + {{7{1'b0}}, rc};
                    rgp <= 3'd1;
                end
                3'd1: begin
                    rgp <= 3'd2;          // wait: raddr is one stage deep
                end
                3'd2: begin
                    rgv <= rd;
                    rgp <= 3'd5;
                end
                3'd5: begin
                    racc <= racc + {{32{rgv[15]}}, rgv};
                    if (rn == o_N - 6'd1) begin
                        rgp <= 3'd3;
                    end else begin
                        rn  <= rn + 6'd1;
                        rga <= rga + {{4{1'b0}}, o_SS};
                        rgp <= 3'd0;
                    end
                end
                3'd3: begin
                    wq_acc  <= racc;
                    wq_m    <= 15'd1;
                    wq_sh   <= LG2T6;
                    wq_pre  <= 1'b1;
                    wq_add  <= 16'sd0;
                    wq_addr <= o_B + {{7{1'b0}}, rc};
                    wq_wr   <= 1'b1;
                    wq_go   <= 1'b1;
                    rgp <= 3'd4;
                end
                default: begin
                    if (wq_done) begin
                        racc <= 48'sd0;
                        rn   <= 6'd0;
                        rga  <= o_A;
                        if (rc == o_O - 6'd1) begin
                            pc <= pc + 8'd1; st <= S_FETCH;
                        end else begin
                            rc  <= rc + 6'd1;
                            rgp <= 3'd0;
                        end
                    end
                end
                endcase
            end

            // ------------------------------------------------ CPY
            //   M=3 的 kv = concat(其余两个模态的 token)，拼在**序列维**：
            //   (M-1)T = 8 行 × D 字，而 GEMM 只能读连续行 ⇒ 先把
            //   [tok_o(g); tok_a] / [tok_e(g); tok_o] 这两段 T 行接成连续的 2T 行。
            //   3 拍一个字（地址 / rd / 写回），源目的不重叠。
            S_CP: begin
                case (cpst)
                C_ST0: begin
                    e_raddr <= cna + {{7{1'b0}}, cco};
                    cpst <= C_ST1;
                end
                C_ST1: begin
                    cpst <= C_ST2;         // 地址一拍、rd 一拍
                end
                default: begin             // C_ST2：rd 已是 mem[cna+cco]
                    cp_req   <= 1'b1;      // 由块①统一提交到写口
                    cp_waddr <= cnb + {{7{1'b0}}, cco};
                    cp_wdata <= rd;
                    if (cco == o_O - 6'd1) begin
                        cco <= 6'd0;
                        cna <= cna + {{4{1'b0}}, o_SS};
                        cnb <= cnb + {{4{1'b0}}, o_DS};
                        if (cn == o_N - 6'd1) begin
                            pc <= pc + 8'd1; st <= S_FETCH;
                        end else begin
                            cn  <= cn + 6'd1;
                            cpst <= C_ST0;
                        end
                    end else begin
                        cco  <= cco + 6'd1;
                        cpst <= C_ST0;
                    end
                end
                endcase
            end

            // ------------------------------------------------ ATTN
            S_AT: begin
                case (ast)
                A_T0: begin
                    qsr     <= 256'd0;
                    krow_r  <= o_B;
                    qbase   <= qa + {4'b0, o_K} - 13'd1;
                    at_c    <= 6'd0;
                    e_raddr <= qa + {4'b0, o_K} - 13'd1;
                    ast     <= A_QLW;
                end
                A_QLW: begin                       // 读地址一拍、rd 一拍
                    ast <= A_QL;
                end
                A_QL: begin
                    qsr <= {rd, qsr[255:16]};
                    if (at_c == o_K - 6'd1) begin
                        // q 装满了：直接进 k 循环（qsr 是破坏性移位队列，
                        // 每个 u 都必须重装，见 A_K0）
                        at_acc  <= 48'sd0;
                        at_c    <= 6'd0;
                        e_raddr <= krow_r;
                        ast     <= A_KW2;
                    end else begin
                        at_c    <= at_c + 6'd1;
                        e_raddr <= qbase - 13'd1 - {{7{1'b0}}, at_c};
                        ast     <= A_QLW;
                    end
                end
                A_K0: begin                        // 重装 q（每个 u 一次）
                    at_c    <= 6'd0;
                    qbase   <= qa + {4'b0, o_K} - 13'd1;
                    e_raddr <= qbase;
                    ast     <= A_QLW;
                end
                A_KW2: begin                       // 读地址一拍、rd 一拍
                    ast <= A_KV;
                end
                A_KV: begin                        // 拍 A：只锁存 k（BRAM 后不挂逻辑）
                    at_kv <= rd;
                    ast   <= A_KP;
                end
                A_KP: begin                        // 拍 B：乘（qsr_hi 在本拍弹出）
                    at_kd <= qsr_hi * at_kv;
                    // 弹出队首 q[0]：整体向高位段挪一格，末尾补 0
                    // （{16'sd0, qsr[255:16]} 方向相反，等于在队首插 0，别写反）
                    qsr   <= {qsr[239:0], 16'sd0};
                    ast   <= A_KM;
                end
                A_KM: begin                        // 拍 C：累加 + 出下一个地址
                    at_acc <= at_acc + {{16{at_kd[31]}}, at_kd};
                    if (at_c == o_K - 6'd1) begin
                        ast <= A_KQ;
                    end else begin
                        at_c    <= at_c + 6'd1;
                        e_raddr <= e_raddr + 13'd1;
                        ast     <= A_KW2;
                    end
                end
                A_KQ: begin
                    wq_acc <= at_acc;
                    wq_m   <= o_M;
                    wq_sh  <= o_SH;
                    wq_pre <= 1'b1;
                    wq_add <= 16'sd0;
                    wq_wr  <= 1'b0;
                    wq_go  <= 1'b1;
                    ast    <= A_KW;
                end
                A_KW: begin
                    if (wq_done) begin
                        lgv[at_u[UMW-1:0]] <= wq_out;
                        at_u    <= at_u + 6'd1;
                        krow_r  <= krow_r + {{7{1'b0}}, o_K};
                        ast  <= (at_u == o_O - 6'd1) ? A_MX0 : A_K0;
                    end
                end
                A_MX0: begin
                    at_u  <= 6'd0;
                    at_mx <= QMINI;
                    ast   <= A_MX;
                end
                A_MX: begin
                    if (at_val && (lgv[at_u[UMW-1:0]] > at_mx))
                        at_mx <= lgv[at_u[UMW-1:0]];
                    at_u <= at_u + 6'd1;
                    if (at_u == o_O - 6'd1) ast <= A_EX0;
                end
                A_EX0: begin
                    at_u <= 6'd0;
                    at_P <= 32'd0;
                    ast  <= A_EX;
                end
                A_EX: begin                       // 拍 1：寄存差值（读 lgv 放在这里）
                    at_exv <= at_val;
                    if (at_val) at_exd <= ex_diff;
                    ast <= A_EXM;
                end
                A_EXM: begin                      // 拍 2：乘 KC + 四舍五入（结果先寄存）
                    if (at_exv) at_exm <= ex_idx;
                    ast <= A_EXN;
                end
                A_EXN: begin                      // 拍 2b：饱和到 0..255
                    if (at_exv)
                        at_exi <= (at_exm > 40'd255) ? 24'd255 : at_exm[23:0];
                    ast <= A_EXB;
                end
                A_EXB: begin                      // 拍 3：查 LUT
                    eld <= elut[at_exi[7:0]];
                    ast <= A_EXC;
                end
                A_EXC: begin
                    if (at_exv) begin
                        pv[at_u[UMW-1:0]] <= eld;
                        at_P <= at_P + {24'd0, eld};
                    end else begin
                        pv[at_u[UMW-1:0]] <= 8'd0;
                    end
                    at_u <= at_u + 6'd1;
                    ast  <= (at_u == o_O - 6'd1) ? A_AQ0 : A_EX;
                end
                A_AQ0: begin
                    at_u   <= 6'd0;
                    at_amx <= 16'sd0;         // 剪枝前 argmax 的哨兵（aqv 全为非负）
                    at_ami <= {UMW{1'b0}};
                    ast    <= A_AQR;
                end
                A_AQR: begin
                    pvr <= pv[at_u[UMW-1:0]];
                    ast <= A_AQI;
                end
                A_AQI: begin
                    dv_num <= dv_mul_p + (at_P >> 1);
                    dv_den <= at_P;
                    dv_go  <= 1'b1;
                    ast    <= A_AQW;
                end
                A_AQW: begin
                    if (dv_done) begin
                        aqv[at_u[UMW-1:0]] <= dv_q[15:0];
                        // 顺带记 pre-pruning 的 argmax（严格大于 ⇒ 平局取小下标，
                        // 与 np.argmax 一致）。δ 清零后 at_S==0 时用它做 one-hot。
                        if ($signed(dv_q[15:0]) > at_amx) begin
                            at_amx <= dv_q[15:0];
                            at_ami <= at_u[UMW-1:0];
                        end
                        at_u <= at_u + 6'd1;
                        ast  <= (at_u == o_O - 6'd1) ? A_KK0 : A_AQR;
                    end
                end
                A_KK0: begin
                    at_u <= 6'd0;
                    at_S <= 32'd0;
                    dcur <= dlut[at_t[2:0]];
                    ast  <= A_KKR;
                end
                A_KKR: begin
                    // 先把 LUTRAM 的异步读寄存下来，下一拍只做比较/累加/清零
                    akk_r <= aqv[at_u[UMW-1:0]];
                    ast   <= A_KK;
                end
                A_KK: begin
                    if (akk_r >= dcur)
                        at_S <= at_S + {{16{akk_r[15]}}, akk_r};
                    else
                        aqv[at_u[UMW-1:0]] <= 16'sd0;
                    at_u <= at_u + 6'd1;
                    if (at_u == o_O - 6'd1) ast <= A_AA0;
                    else                    ast <= A_KKR;
                end
                A_AA0: begin
                    at_u <= 6'd0;
                    // ★ 整行被 δ 清零时的 one-hot 保底（fixpt.align 同口径）：
                    //   取剪枝前最大权重那一路置 32767、其余已经是 0，S 取 32767。
                    //   后面的 A_AAR 循环会把它重新归一化，结果仍是 one-hot。
                    if (at_S == 32'd0) begin
                        aqv[at_ami] <= 16'sd32767;
                        at_S        <= 32'd32767;
                    end
                    ast  <= A_AAR;
                end
                A_AAR: begin
                    aqvr <= aqv[at_u[UMW-1:0]];
                    ast  <= A_AAI;
                end
                A_AAI: begin
                    dv_num <= dv_mul_a + (at_S >> 1);
                    dv_den <= (at_S == 32'd0) ? 32'd1 : at_S;
                    dv_go  <= 1'b1;
                    ast    <= A_AAW;
                end
                A_AAW: begin
                    if (dv_done) begin
                        avv[at_u[UMW-1:0]] <= (at_S == 32'd0) ? 16'sd0 : dv_q[15:0];
                        at_u <= at_u + 6'd1;
                        if (at_u == o_O - 6'd1) begin
                            at_c <= 6'd0;          // 每通道循环只在入口清一次
                            ast  <= A_AV0;
                        end else begin
                            ast  <= A_AAR;
                        end
                    end
                end
                A_AV0: begin
                    at_u    <= 6'd0;
                    at_acc  <= 48'sd0;
                    at_rv   <= 16'sd0;
                    at_rv2  <= 16'sd0;
                    at_pd   <= 32'sd0;
                    e_raddr <= o_W[12:0] + {{7{1'b0}}, at_c};   // u=0 也要加通道偏移
                    ast     <= A_AVW;
                end
                A_AVW: begin                       // 读地址一拍、rd 一拍
                    ast <= A_AV1;
                end
                A_AV1: begin                       // 拍 A：只锁存 v（BRAM 慢，后面不能挂逻辑）
                    at_rv <= rd;
                    ast   <= A_AVQ;
                end
                A_AVQ: begin                       // 拍 A2：第二级（免得被吸收进 BRAM 输出寄存器）
                    at_rv2 <= at_rv;
                    avvr   <= avv[at_u[UMW-1:0]];
                    at_last <= (at_u == o_O - 6'd1);   // A_AVQ/A_AVP 两拍 at_u 不变
                    ast    <= A_AVP;
                end
                A_AVP: begin                       // 拍 B：乘
                    // ★ 这里试过合并成 `at_acc <= at_acc + a*b`：Vivado 只把乘法
                    //   放进 DSP（P 口仍是组合输出，CLK->P = 4.0 ns），48 位累加
                    //   落到 fabric 的 12 级进位链，WNS 从 -0.156 掉到 -2.898。
                    //   原因是 at_acc 在别的状态要被清零、装不进 P 寄存器。
                    //   所以保持"先寄存乘积、下一拍再累加"两拍结构。
                    at_pd <= avvr * at_rv2;
                    ast   <= A_AVS;
                end
                A_AVS: begin                       // 拍 C：累加
                    at_acc <= at_acc + {{16{at_pd[31]}}, at_pd};
                    if (at_last) begin
                        e_raddr <= tb2 + {{7{1'b0}}, at_c};
                        ast     <= A_AV2W;
                    end else begin
                        at_u    <= at_u + 6'd1;
                        e_raddr <= e_raddr + {{7{1'b0}}, o_K};
                        ast     <= A_AVZ;
                    end
                end
                A_AVZ: begin
                    ast <= A_AV1;                  // 等地址 -> rd
                end
                A_AV2W: begin
                    ast <= A_AV2;
                end
                A_AV2: begin
                    avtok <= rd;
                    ast   <= A_AV3;
                end
                A_AV3: begin
                    wq_acc  <= at_acc;
                    wq_m    <= o_AM;
                    wq_sh   <= o_ASH;
                    wq_pre  <= 1'b1;
                    wq_add  <= avtok;
                    wq_addr <= zb + {{7{1'b0}}, at_c};
                    wq_wr   <= 1'b1;
                    wq_go   <= 1'b1;
                    ast     <= A_AV4;
                end
                A_AV4: begin
                    if (wq_done) begin
                        at_acc <= 48'sd0;
                        at_u   <= 6'd0;
                        if (at_c == o_K - 6'd1) begin
                            ast <= A_TN;
                        end else begin
                            at_c <= at_c + 6'd1;
                            ast  <= A_AV0;
                        end
                    end
                end
                default: begin // A_TN
                    if (at_t == o_N - 6'd1) begin
                        pc <= pc + 8'd1; st <= S_FETCH;
                    end else begin
                        at_t <= at_t + 6'd1;
                        qa   <= qa   + {{4{1'b0}}, o_SS};
                        zb   <= zb   + {{4{1'b0}}, o_SS};
                        tb2  <= tb2  + {{4{1'b0}}, o_SS};
                        ast  <= A_T0;
                    end
                end
                endcase
            end
            endcase
        end
    end

endmodule
`default_nettype wire
