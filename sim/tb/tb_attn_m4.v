`timescale 1ns/1ps
`default_nettype none

// ---------------------------------------------------------------------------
// 存储器向量目录（2026-10-29 去硬编码）
//   默认 ../vectors/m4：从 sim/run/ 启动 xsim 即指向该档已提交的金标准向量。
//   覆盖：xvlog/xelab -d MEM_DIR="\"<dir>\""；综合前改这一处即可。
// ---------------------------------------------------------------------------
`ifndef MEM_DIR
  `define MEM_DIR "../vectors/m4"
`endif

// =============================================================================
// tb_attn_m4.v -- 四模态（e+o+a+s）逐位验收
//
//   与 tb_attn_m3.v 的差别只有三处：
//     · 地址取 export.py m4 的 wordmap（HRE=2048 / HE=3584 / KV=4800 / ...）
//     · 输入多一路 GSR（NIN 1540 -> 1636，proj_s 吃 24 维窗统计量）
//     · 每个模态的 K/V 是 3T=12 行（kv 按**序列**拼），所以是 192 字不是 128
//     · UM 从 8 加到 12（attn_core 的 k/v 最大行数 = T*(M-1)）
//   其余（激励、比对方式、超时）刻意保持一致，便于与 M=2 / M=3 的结果对照。
//
//   注意：scratch 在这里被用到 8192/8192（ZP_S 的最后一个是 8191），零余量。
//   再加模态必须先把 attn_core 的 mem 加深。
//
//   运行：sh sim/run_attn_m4.sh
// =============================================================================
module tb_attn_m4;

    localparam integer NIN = 1636;    // IN_E 1240 + IN_O 96 + IN_A 204 + IN_S 96
    localparam integer NH  = 64;      // 单模态 token / Q / Z 的字数 (T*D)
    localparam integer NKV = 192;     // K/V 字数 ((M-1)T*D = 3*4*16)
    localparam integer NHE = 1024;    // EEG 的 H (G*T*D)
    localparam integer NZP = 256;     // 单模态逐组 GAP (G*D)

    localparam [12:0] A_IN  = 13'd0;
    localparam [12:0] A_HRE = 13'd2048;
    localparam [12:0] A_HRO = 13'd3072;
    localparam [12:0] A_HRA = 13'd3136;
    localparam [12:0] A_HRS = 13'd3200;
    localparam [12:0] A_HE  = 13'd3584;
    localparam [12:0] A_HO  = 13'd4608;
    localparam [12:0] A_HA  = 13'd4672;
    localparam [12:0] A_HS  = 13'd4736;
    localparam [12:0] A_KV  = 13'd4800;
    localparam [12:0] A_QE  = 13'd5120;
    localparam [12:0] A_KE  = 13'd5184;
    localparam [12:0] A_VE  = 13'd5376;
    localparam [12:0] A_QO  = 13'd5568;
    localparam [12:0] A_KO  = 13'd5632;
    localparam [12:0] A_VO  = 13'd5824;
    localparam [12:0] A_QA  = 13'd6016;
    localparam [12:0] A_KA  = 13'd6080;
    localparam [12:0] A_VA  = 13'd6272;
    localparam [12:0] A_QS  = 13'd6464;
    localparam [12:0] A_KS  = 13'd6528;
    localparam [12:0] A_VS  = 13'd6720;
    localparam [12:0] A_ZE  = 13'd6912;
    localparam [12:0] A_ZO  = 13'd6976;
    localparam [12:0] A_ZA  = 13'd7040;
    localparam [12:0] A_ZS  = 13'd7104;
    localparam [12:0] A_ZPE = 13'd7168;
    localparam [12:0] A_ZPO = 13'd7424;
    localparam [12:0] A_ZPA = 13'd7680;
    localparam [12:0] A_ZPS = 13'd7936;

    reg clk = 1'b0;
    reg rst_n = 1'b0;
    reg start = 1'b0;
    wire busy, done;

    reg        hw_en   = 1'b0;
    reg [12:0] hw_addr = 13'd0;
    reg [15:0] hw_data = 16'd0;
    reg [12:0] hr_addr = 13'd0;
    wire [15:0] hr_data;

    reg [15:0] inbuf  [0:NIN-1];
    reg [15:0] exph   [0:NHE-1];
    reg [15:0] expze  [0:NZP-1];
    reg [15:0] expzo  [0:NZP-1];
    reg [15:0] expza  [0:NZP-1];
    reg [15:0] expzs  [0:NZP-1];
    reg [15:0] exphre [0:NHE-1];
    reg [15:0] exphro [0:NH-1];
    reg [15:0] exphra [0:NH-1];
    reg [15:0] exphrs [0:NH-1];
    reg [15:0] expho  [0:NH-1];
    reg [15:0] expha  [0:NH-1];
    reg [15:0] exphs  [0:NH-1];
    reg [15:0] eqe [0:NH-1];
    reg [15:0] eke [0:NKV-1];
    reg [15:0] eve [0:NKV-1];
    reg [15:0] eqo [0:NH-1];
    reg [15:0] eko [0:NKV-1];
    reg [15:0] evo [0:NKV-1];
    reg [15:0] eqa [0:NH-1];
    reg [15:0] eka [0:NKV-1];
    reg [15:0] eva [0:NKV-1];
    reg [15:0] eqs [0:NH-1];
    reg [15:0] eks [0:NKV-1];
    reg [15:0] evs [0:NKV-1];
    reg [15:0] ez0 [0:NH-1];
    reg [15:0] ezo0[0:NH-1];
    reg [15:0] eza0[0:NH-1];
    reg [15:0] ezs0[0:NH-1];

    integer i, nbad, cyc;
    reg [15:0] v;

    always #2.5 clk = ~clk;

    attn_core #(.T(4), .D(16), .UM(12)) dut (
        .clk(clk), .rst_n(rst_n),
        .start(start), .busy(busy), .done(done),
        .hw_en(hw_en), .hw_addr(hw_addr), .hw_data(hw_data),
        .hr_addr(hr_addr), .hr_data(hr_data)
    );

    task rd;
        input [12:0] a;
        output [15:0] d;
        begin
            @(negedge clk); hr_addr = a;
            @(negedge clk); d = hr_data;
        end
    endtask

    // mode: 选期望数组（Verilog 的 task 不能传 unpacked array，只好这样）
    task chk;
        input [12:0] base;
        input integer n;
        input [8*16-1:0] tag;
        input integer mode;
        integer k, bad;
        reg [15:0] e;
        begin
            bad = 0;
            for (k = 0; k < n; k = k + 1) begin
                rd(base + k[12:0], v);
                case (mode)
                 0: e = exph[k];
                 1: e = expze[k];
                 2: e = expzo[k];
                 3: e = expza[k];
                 4: e = expzs[k];
                 5: e = exphre[k];
                 6: e = exphro[k];
                 7: e = exphra[k];
                 8: e = exphrs[k];
                 9: e = expho[k];
                10: e = expha[k];
                11: e = exphs[k];
                12: e = eqe[k];
                13: e = eke[k];
                14: e = eve[k];
                15: e = eqo[k];
                16: e = eko[k];
                17: e = evo[k];
                18: e = eqa[k];
                19: e = eka[k];
                20: e = eva[k];
                21: e = eqs[k];
                22: e = eks[k];
                23: e = evs[k];
                24: e = ez0[k];
                25: e = ezo0[k];
                26: e = eza0[k];
                default: e = ezs0[k];
                endcase
                if (v !== e) begin
                    if (bad < 8)
                        $display("  MISMATCH %0s[%0d] addr=%0d got=%04x exp=%04x",
                                 tag, k, base + k, v, e);
                    bad = bad + 1;
                end
            end
            if (bad == 0) $display("  %0s: %0d words OK", tag, n);
            else          $display("  %0s: %0d / %0d MISMATCH", tag, bad, n);
            nbad = nbad + bad;
        end
    endtask

    always @(posedge clk) begin
        if (busy && (cyc % 200000 == 0))
            $display("  t=%0t cyc=%0d pc=%0d st=%0d ast=%0d ph=%0d",
                     $time, cyc, dut.pc, dut.st, dut.ast, dut.ph);
    end

    initial begin
        $readmemh({`MEM_DIR, "/in.mem"},       inbuf);
        $readmemh({`MEM_DIR, "/exp_h.mem"},    exph);
        $readmemh({`MEM_DIR, "/exp_ze.mem"},   expze);
        $readmemh({`MEM_DIR, "/exp_zo.mem"},   expzo);
        $readmemh({`MEM_DIR, "/exp_za.mem"},   expza);
        $readmemh({`MEM_DIR, "/exp_zs.mem"},   expzs);
        $readmemh({`MEM_DIR, "/exp_hre.mem"},  exphre);
        $readmemh({`MEM_DIR, "/exp_hro.mem"},  exphro);
        $readmemh({`MEM_DIR, "/exp_hra.mem"},  exphra);
        $readmemh({`MEM_DIR, "/exp_hrs.mem"},  exphrs);
        $readmemh({`MEM_DIR, "/exp_ho.mem"},   expho);
        $readmemh({`MEM_DIR, "/exp_ha.mem"},   expha);
        $readmemh({`MEM_DIR, "/exp_hs.mem"},   exphs);
        $readmemh({`MEM_DIR, "/exp_qL_e.mem"}, eqe);
        $readmemh({`MEM_DIR, "/exp_kL_e.mem"}, eke);
        $readmemh({`MEM_DIR, "/exp_vL_e.mem"}, eve);
        $readmemh({`MEM_DIR, "/exp_qL_o.mem"}, eqo);
        $readmemh({`MEM_DIR, "/exp_kL_o.mem"}, eko);
        $readmemh({`MEM_DIR, "/exp_vL_o.mem"}, evo);
        $readmemh({`MEM_DIR, "/exp_qL_a.mem"}, eqa);
        $readmemh({`MEM_DIR, "/exp_kL_a.mem"}, eka);
        $readmemh({`MEM_DIR, "/exp_vL_a.mem"}, eva);
        $readmemh({`MEM_DIR, "/exp_qL_s.mem"}, eqs);
        $readmemh({`MEM_DIR, "/exp_kL_s.mem"}, eks);
        $readmemh({`MEM_DIR, "/exp_vL_s.mem"}, evs);
        $readmemh({`MEM_DIR, "/exp_z0L_e.mem"}, ez0);
        $readmemh({`MEM_DIR, "/exp_z0L_o.mem"}, ezo0);
        $readmemh({`MEM_DIR, "/exp_z0L_a.mem"}, eza0);
        $readmemh({`MEM_DIR, "/exp_z0L_s.mem"}, ezs0);
        nbad = 0;

        repeat (4) @(posedge clk);
        rst_n = 1'b1;
        repeat (2) @(posedge clk);

        for (i = 0; i < NIN; i = i + 1) begin
            @(negedge clk);
            hw_en   = 1'b1;
            hw_addr = A_IN + i[12:0];
            hw_data = inbuf[i];
        end
        @(negedge clk); hw_en = 1'b0;
        repeat (2) @(posedge clk);

        cyc = 0;
        @(negedge clk); start = 1'b1;
        @(negedge clk); start = 1'b0;
        while (!done) begin
            @(posedge clk);
            cyc = cyc + 1;
            if (cyc > 8000000) begin
                $display("FAIL: timeout, busy=%b st=%0d pc=%0d", busy, dut.st, dut.pc);
                $finish;
            end
        end
        $display("  engine cycles = %0d", cyc);
        repeat (4) @(posedge clk);

        $display("--- compare against fixpt.py (M=4) ---");
        chk(A_HE,  NHE, "H_E ", 0);
        chk(A_ZPE, NZP, "ZP_E", 1);
        chk(A_ZPO, NZP, "ZP_O", 2);
        chk(A_ZPA, NZP, "ZP_A", 3);
        chk(A_ZPS, NZP, "ZP_S", 4);
        chk(A_HRE, NHE, "HR_E", 5);
        chk(A_HRO, NH,  "HR_O", 6);
        chk(A_HRA, NH,  "HR_A", 7);
        chk(A_HRS, NH,  "HR_S", 8);
        chk(A_HO,  NH,  "H_O ", 9);
        chk(A_HA,  NH,  "H_A ", 10);
        chk(A_HS,  NH,  "H_S ", 11);
        chk(A_QE, NH,  "Q_E ", 12);
        chk(A_KE, NKV, "K_E ", 13);
        chk(A_VE, NKV, "V_E ", 14);
        chk(A_QO, NH,  "Q_O ", 15);
        chk(A_KO, NKV, "K_O ", 16);
        chk(A_VO, NKV, "V_O ", 17);
        chk(A_QA, NH,  "Q_A ", 18);
        chk(A_KA, NKV, "K_A ", 19);
        chk(A_VA, NKV, "V_A ", 20);
        chk(A_QS, NH,  "Q_S ", 21);
        chk(A_KS, NKV, "K_S ", 22);
        chk(A_VS, NKV, "V_S ", 23);
        chk(A_ZE, NH,  "Z_E0", 24);
        chk(A_ZO, NH,  "Z_O0", 25);
        chk(A_ZA, NH,  "Z_A0", 26);
        chk(A_ZS, NH,  "Z_S0", 27);

        if (nbad == 0) $display("ALL PASS");
        else           $display("FAIL (%0d words)", nbad);
        $finish;
    end

endmodule
`default_nettype wire
