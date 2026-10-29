`timescale 1ns / 1ps
`default_nettype none
// =============================================================================
// log2_cordic.v —— 双曲 CORDIC 求 log2，Q16.16 定点输出
//
//   ln(m) = 2·atanh((m-1)/(m+1))，CORDIC 直接以 (x0,y0)=(m+1,m-1) 起转，
//   不需要除法。z 累加量已预乘 1/ln2，所以结束时 z = 0.5·log2(m)。
//
//   迭代 18 次（i=4 与 i=13 各重复一次，双曲 CORDIC 的收敛要求）。
//   实测（model/eeg_fe_model.py）：最大误差 3.7 LSB，rms 1.8 LSB。
//
//   ★ 2026-10-18 改成**18 级全展开流水**（原来是单加法器串行迭代）：
//     串行版里 `it` 是 17 选 1 的变量移位选择信号，扇出 101、横跨 35 行，
//     实测 7.9 ns / 13 级逻辑（综合器还把变量移位展开成一串 CARRY4）。
//     展开后每级的移位量是常量（纯连线），每级只有一次条件加减。
//     代价 ~1.9k FF；收益是延迟恒定 19 拍、吞吐升到每拍一个结果。
//
//   ★ 与 Python 模型逐位一致：Python 侧 cordic_log2_q16() 是本模块的直译。
// =============================================================================
module log2_cordic (
    input  wire                clk,
    input  wire                rst_n,
    input  wire                start,
    input  wire [30:0]         m,           // Q1.30，[1,2)
    input  wire [6:0]          er,          // 原值的二进制指数
    input  wire                zero,        // 原值为 0
    output wire                busy,
    output reg                 done,
    output reg  signed [31:0]  log2_q16     // log2(v)，Q16.16（无输入时给 -62<<16）
);
    localparam integer NSTG = 18;

    // ---------------------------------------------------------------- CORDIC 表
    // z_i = atanh(2^-i)/ln2, Q2.29；i=4、13 各重复一次
    function [31:0] tab(input integer idx);
        case (idx)
            0 : tab = 32'h195C01A4;   // i=1
            1 : tab = 32'h0BCA9C6F;   // i=2
            2 : tab = 32'h05CD1649;   // i=3
            3 : tab = 32'h02E39FB9;   // i=4 (1)
            4 : tab = 32'h02E39FB9;   // i=4 (2)
            5 : tab = 32'h01717342;   // i=5
            6 : tab = 32'h00B8AE14;   // i=6
            7 : tab = 32'h005C5599;   // i=7
            8 : tab = 32'h002E2A9E;   // i=8
            9 : tab = 32'h00171549;   // i=9
            10: tab = 32'h000B8AA4;   // i=10
            11: tab = 32'h0005C552;   // i=11
            12: tab = 32'h0002E2A9;   // i=12
            13: tab = 32'h00017154;   // i=13 (1)
            14: tab = 32'h00017154;   // i=13 (2)
            15: tab = 32'h0000B8AA;   // i=14
            16: tab = 32'h00005C55;   // i=15
            17: tab = 32'h00002E2B;   // i=16
            default: tab = 32'd0;
        endcase
    endfunction

    // 每级移位量（常量；i=4、13 重复）
    function integer shf(input integer idx);
        case (idx)
            0 : shf = 1;
            1 : shf = 2;
            2 : shf = 3;
            3 : shf = 4;
            4 : shf = 4;
            5 : shf = 5;
            6 : shf = 6;
            7 : shf = 7;
            8 : shf = 8;
            9 : shf = 9;
            10: shf = 10;
            11: shf = 11;
            12: shf = 12;
            13: shf = 13;
            14: shf = 13;
            15: shf = 14;
            16: shf = 15;
            17: shf = 16;
            default: shf = 0;
        endcase
    endfunction

    // ---------------------------------------------------------------- 流水线
    // ★ 2026-10-18：每级拆成**两个半拍**，理由是符号线的扇出。
    //   原结构里一级同时在算 x'、y'、z'，三组加法器都要吃 sgn = ya[k][33]：
    //   扇出 81，单根线布线 2.49 ns；而 ya[k+1] 的符号位又落在 34 位进位链
    //   **最后一位**（9 个 CARRY4 竖着排 9 行，1.9 ns），两段叠在一起
    //   ya_reg[7][33] -> xa_reg[8][33] 实测 -0.554 ns（全设计唯一的违例族）。
    //   拆法：
    //     偶半拍：y' = y ∓ (x>>i)，并把 u = (y>>i) 与两份符号同时寄存；
    //     奇半拍：x' = x ± u（用符号副本 sx），z' = z ± tab（用副本 sz）。
    //   于是符号线在偶半拍只扇出 34（只有 y 的加法器），在奇半拍分别从
    //   sx、sz 两个**扇出 1 驱动的**寄存器出发 —— placer 可以把它们直接摆在
    //   各自的加法器旁边。延迟 18 拍 -> 36 拍，但 CORDIC 每窗只用 310 次，
    //   多出的 18×310×5 ns = 28 us 可以忽略；吞吐仍是一拍一个结果。
    //   (* max_fanout = *) 这条路走不通（复制出 _rep__0..4 反而更差：
    //   -1.203 -> -1.770；-0.760 -> -0.904），已永久放弃。
    localparam integer NH = 2*NSTG;      // 半拍数 = 36

    reg signed [33:0] xa [0:NH];
    reg signed [33:0] ya [0:NH];
    reg signed [31:0] za [0:NH];
    reg signed [33:0] ua [0:NH];         // 偶半拍寄存 y>>i，给奇半拍的 x 加法
    reg               sx [0:NH];         // x 加法器专用的符号副本
    reg               sz [0:NH];         // z 加法器专用的符号副本
    reg [6:0]         ea [0:NH];
    reg               fa [0:NH];         // 原值为 0 的标志，随流水走
    reg [NH:0]        vld;

    wire [NH-1:0] sgn;                   // sgn[h] = ya[h][33]，h 只取偶半拍
    genvar gi;
    generate
        for (gi = 0; gi < NH; gi = gi + 1) begin : g_sgn
            assign sgn[gi] = ya[gi][33];
        end
    endgenerate

    assign busy = |vld;

    integer k;
    always @(posedge clk) begin
        if (!rst_n) begin
            for (k = 0; k <= NH; k = k + 1) begin
                xa[k] <= 34'sd0;
                ya[k] <= 34'sd0;
                za[k] <= 32'sd0;
                ua[k] <= 34'sd0;
                sx[k] <= 1'b0;
                sz[k] <= 1'b0;
                ea[k] <= 7'd0;
                fa[k] <= 1'b0;
            end
            vld <= {(NH+1){1'b0}};
            done <= 1'b0;
            log2_q16 <= -32'sd4063232;          // -62 << 16
        end else begin
            // ---- 半拍 0：装载 ----
            xa[0] <= $signed({1'b0, m[30:1]}) + 34'sd536870912;   // m+1
            ya[0] <= $signed({1'b0, m[30:1]}) - 34'sd536870912;   // m-1
            za[0] <= 32'sd0;
            ua[0] <= 34'sd0;
            sx[0] <= 1'b0;
            sz[0] <= 1'b0;
            ea[0] <= er;
            fa[0] <= zero;
            vld[0] <= start;

            // ---- 第 1..18 级，每级两个半拍 ----
            for (k = 0; k < NSTG; k = k + 1) begin
                // 偶半拍：y' = y ∓ (x>>i)，寄存 u 与两份符号
                ya[2*k+1] <= sgn[2*k] ? (ya[2*k] + (xa[2*k] >>> shf(k)))
                                      : (ya[2*k] - (xa[2*k] >>> shf(k)));
                ua[2*k+1] <= (ya[2*k] >>> shf(k));
                sx[2*k+1] <= sgn[2*k];
                sz[2*k+1] <= sgn[2*k];
                xa[2*k+1] <= xa[2*k];
                za[2*k+1] <= za[2*k];
                ea[2*k+1] <= ea[2*k];
                fa[2*k+1] <= fa[2*k];
                vld[2*k+1] <= vld[2*k];

                // 奇半拍：x' = x ± u，z' = z ± tab
                xa[2*k+2] <= sx[2*k+1] ? (xa[2*k+1] + ua[2*k+1])
                                       : (xa[2*k+1] - ua[2*k+1]);
                za[2*k+2] <= sz[2*k+1] ? (za[2*k+1] - $signed({1'b0, tab(k)}))
                                       : (za[2*k+1] + $signed({1'b0, tab(k)}));
                ya[2*k+2] <= ya[2*k+1];
                ea[2*k+2] <= ea[2*k+1];
                fa[2*k+2] <= fa[2*k+1];
                vld[2*k+2] <= vld[2*k+1];
            end

            // ---- 输出 ----
            done <= vld[NH];
            if (vld[NH]) begin
                if (fa[NH])
                    log2_q16 <= -32'sd4063232;
                else
                    // z = 0.5*log2(m) in Q2.29  ->  log2(m) = z >> 12
                    log2_q16 <= (za[NH] >>> 12) + $signed({11'd0, ea[NH], 16'd0});
            end
        end
    end
endmodule

// =============================================================================
// norm72.v —— 72 位无符号数归一化，六级流水
//
//   第一级：72 位优先编码器求最高非零位 emsb（纯组合，一拍寄存）
//   第二、三级：把"整体右移 emsb 位"拆成两段小移位
//
//   ★ 数学等价形式：先左垫 30 个 0 再整体右移 emsb 位，低 31 位就是 mantissa。
//       m = ((v << 30) >> emsb)[30:0]
//     因为 v 的最高位在 emsb，左垫 30 后再右移 emsb 恰好把它摆回 bit30。
//     写成一次右移的好处是**没有方向分支**：原来那句
//       (emsb<=30) ? v<<(30-emsb) : v>>(emsb-30)
//     综合成 72 位双向桶形移位器，5 级 LUT、控制线扇出 71，实测 7.1 ns
//     （build_eeg_fe timing_reg2reg 的最坏路径）。
//     拆成 emsb = 8q + r 两段后，每段只有 2 级 LUT：
//       第二级 >> r        (r = emsb[2:0]，0..7，102 位)
//       第三级 >> 8q       (q = emsb[6:3]，0..64，只算低 31 位输出)
//     第二级先右移不会丢需要的位：最终 bit0 来自垫零向量的第 (r+8q) 位。
//
//   ★ 2026-10-18 再拆成**每拍一级移位**（共 6 级流水）。原来"第二级"的
//     移位量是 emsb_r[2:0] 三个控制位，各扇出 ~89 个负载，实测单根线布线
//     2.49 ns；加上数据线 2.23 ns 后 FSM_onehot_st_reg[24] -> m_reg[1]/CE
//     = -0.852 ns（全设计最坏）。拆成每拍只移 1/2/4/8/32/64 位之一后，
//     每拍只有 1~2 级 LUT，控制线有整整一拍的时间去布线（2.5 ns 绰绰有余）。
//     代价：延迟 3 拍 -> 6 拍；每个窗口多 3 拍 ≈ 0.95 ms（≈2.4 %）。
// =============================================================================
module norm72 (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        start,           // 单拍：v 已稳定，开始归一化
    input  wire [71:0] v,
    output reg         valid,           // 六级都完成后拉高一拍
    output reg  [30:0] m,               // Q1.30，[1,2)
    output reg  [6:0]  er,              // 原值的二进制指数
    output reg         zero
);
    // ---- 第一级：最高位位置 ----
    reg [6:0]  emsb_r;
    reg        zero_r;
    integer    k;
    reg [6:0]  emsb;
    always @(*) begin
        emsb = 7'd0;
        for (k = 0; k < 72; k = k + 1)
            if (v[k]) emsb = k[6:0];
    end

    // ---- 第二..七级：每拍一级右移，控制位是 emsb_r 的一位或两位 ----
    reg  [101:0] s1, s2, s3, s4, s5, s6;
    reg  [5:0]   vd;

    // emsb = 1*emsb[0] + 2*emsb[1] + 4*emsb[2] + 8*emsb[4:3] + 32*emsb[6:5]
    wire [101:0] sh1 = s1 >> {4'd0, emsb_r[0]};
    wire [101:0] sh2 = s2 >> {3'd0, emsb_r[1], 1'b0};
    wire [101:0] sh3 = s3 >> {2'd0, emsb_r[2], 2'b00};
    wire [101:0] sh4 = s4 >> {emsb_r[4:3], 3'b000};
    wire [101:0] sh5 = s5 >> {emsb_r[6:5], 5'b00000};

    always @(posedge clk) begin
        if (!rst_n) begin
            emsb_r <= 7'd0; zero_r <= 1'b0;
            s1 <= 102'd0; s2 <= 102'd0; s3 <= 102'd0;
            s4 <= 102'd0; s5 <= 102'd0; s6 <= 102'd0;
            vd <= 6'd0;
            valid <= 1'b0; m <= 31'd0; er <= 7'd0; zero <= 1'b0;
        end else begin
            valid <= 1'b0;
            // ★ 六级移位**无条件**推进。原来用 case(st) 选通，那个状态位要
            //   同时驱动 102 个寄存器的 CE（实测 FSM_onehot_st_reg[24]/Q
            //   扇出 93、布线 2.62 ns，是全设计最坏路径）。改成常开流水后
            //   一条 CE 都没有，只需要一根 6 位的有效位移位线；无效拍的数据
            //   照样流过但不被采用。功耗上的代价可以忽略（这 102 位本来也
            //   每拍都在动），时序上省掉整片 CE 网络。
            s1 <= {v, 30'd0};
            s2 <= sh1;
            s3 <= sh2;
            s4 <= sh3;
            s5 <= sh4;
            s6 <= sh5;
            vd <= {vd[4:0], start};
            if (start) begin
                emsb_r <= emsb;
                zero_r <= (v == 72'd0);
            end
            if (vd[5]) begin
                m     <= s6[30:0];
                er    <= emsb_r;
                zero  <= zero_r;
                valid <= 1'b1;
            end
        end
    end
endmodule

`default_nettype wire
