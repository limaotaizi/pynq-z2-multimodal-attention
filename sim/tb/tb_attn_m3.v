`timescale 1ns/1ps
`default_nettype none

// ---------------------------------------------------------------------------
// 存储器向量目录（2026-10-29 去硬编码）
//   默认 ../vectors/m3：从 sim/run/ 启动 xsim 即指向该档已提交的金标准向量。
//   覆盖：xvlog/xelab -d MEM_DIR="\"<dir>\""；综合前改这一处即可。
// ---------------------------------------------------------------------------
`ifndef MEM_DIR
  `define MEM_DIR "../vectors/m3"
`endif

// =============================================================================
// tb_attn_m3.v -- 三模态（e+o+a）逐位验收
//
//   与 tb_attn.v 的差别只有三处：
//     · 地址取 export.py m3 的 wordmap（HRE=2048 / HE=3584 / KV=4736 / ...）
//     · 输入多一路 AU（NIN 1336 -> 1540）
//     · 每个模态的 K/V 是 2T=8 行（kv 按**序列**拼），所以是 128 字不是 64
//   其余（激励、比对方式、超时）刻意保持一致，便于两套结果对照。
//
//   运行：sh sim/run_attn_m3.sh
// =============================================================================
module tb_attn_m3;

    localparam integer NIN = 1540;
    localparam integer NH  = 64;      // 单模态 token / Q / Z 的字数 (T*D)
    localparam integer NKV = 128;     // K/V 字数 ((M-1)T*D)
    localparam integer NHE = 1024;    // EEG 的 H (G*T*D)
    localparam integer NZP = 256;     // 单模态逐组 GAP (G*D)

    localparam [12:0] A_IN  = 13'd0;
    localparam [12:0] A_HRE = 13'd2048;
    localparam [12:0] A_HRO = 13'd3072;
    localparam [12:0] A_HRA = 13'd3136;
    localparam [12:0] A_HE  = 13'd3584;
    localparam [12:0] A_HO  = 13'd4608;
    localparam [12:0] A_HA  = 13'd4672;
    localparam [12:0] A_KV  = 13'd4736;
    localparam [12:0] A_QE  = 13'd4864;
    localparam [12:0] A_KE  = 13'd4928;
    localparam [12:0] A_VE  = 13'd5056;
    localparam [12:0] A_QO  = 13'd5184;
    localparam [12:0] A_KO  = 13'd5248;
    localparam [12:0] A_VO  = 13'd5376;
    localparam [12:0] A_QA  = 13'd5504;
    localparam [12:0] A_KA  = 13'd5568;
    localparam [12:0] A_VA  = 13'd5696;
    localparam [12:0] A_ZE  = 13'd5824;
    localparam [12:0] A_ZO  = 13'd5888;
    localparam [12:0] A_ZA  = 13'd5952;
    localparam [12:0] A_ZPE = 13'd6144;
    localparam [12:0] A_ZPO = 13'd6400;
    localparam [12:0] A_ZPA = 13'd6656;

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
    reg [15:0] exphre [0:NHE-1];
    reg [15:0] exphro [0:NH-1];
    reg [15:0] exphra [0:NH-1];
    reg [15:0] expho  [0:NH-1];
    reg [15:0] expha  [0:NH-1];
    reg [15:0] eqe [0:NH-1];
    reg [15:0] eke [0:NKV-1];
    reg [15:0] eve [0:NKV-1];
    reg [15:0] eqo [0:NH-1];
    reg [15:0] eko [0:NKV-1];
    reg [15:0] evo [0:NKV-1];
    reg [15:0] eqa [0:NH-1];
    reg [15:0] eka [0:NKV-1];
    reg [15:0] eva [0:NKV-1];
    reg [15:0] ez0 [0:NH-1];
    reg [15:0] ezo0[0:NH-1];
    reg [15:0] eza0[0:NH-1];

    integer i, nbad, cyc;
    reg [15:0] v;

    always #2.5 clk = ~clk;

    attn_core #(.T(4), .D(16), .UM(8)) dut (
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
                 4: e = exphre[k];
                 5: e = exphro[k];
                 6: e = exphra[k];
                 7: e = expho[k];
                 8: e = expha[k];
                 9: e = eqe[k];
                10: e = eke[k];
                11: e = eve[k];
                12: e = eqo[k];
                13: e = eko[k];
                14: e = evo[k];
                15: e = eqa[k];
                16: e = eka[k];
                17: e = eva[k];
                18: e = ez0[k];
                19: e = ezo0[k];
                default: e = eza0[k];
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
        $readmemh({`MEM_DIR, "/in.mem"},      inbuf);
        $readmemh({`MEM_DIR, "/exp_h.mem"},   exph);
        $readmemh({`MEM_DIR, "/exp_ze.mem"},  expze);
        $readmemh({`MEM_DIR, "/exp_zo.mem"},  expzo);
        $readmemh({`MEM_DIR, "/exp_za.mem"},  expza);
        $readmemh({`MEM_DIR, "/exp_hre.mem"}, exphre);
        $readmemh({`MEM_DIR, "/exp_hro.mem"}, exphro);
        $readmemh({`MEM_DIR, "/exp_hra.mem"}, exphra);
        $readmemh({`MEM_DIR, "/exp_ho.mem"},  expho);
        $readmemh({`MEM_DIR, "/exp_ha.mem"},  expha);
        $readmemh({`MEM_DIR, "/exp_qL_e.mem"}, eqe);
        $readmemh({`MEM_DIR, "/exp_kL_e.mem"}, eke);
        $readmemh({`MEM_DIR, "/exp_vL_e.mem"}, eve);
        $readmemh({`MEM_DIR, "/exp_qL_o.mem"}, eqo);
        $readmemh({`MEM_DIR, "/exp_kL_o.mem"}, eko);
        $readmemh({`MEM_DIR, "/exp_vL_o.mem"}, evo);
        $readmemh({`MEM_DIR, "/exp_qL_a.mem"}, eqa);
        $readmemh({`MEM_DIR, "/exp_kL_a.mem"}, eka);
        $readmemh({`MEM_DIR, "/exp_vL_a.mem"}, eva);
        $readmemh({`MEM_DIR, "/exp_z0L_e.mem"}, ez0);
        $readmemh({`MEM_DIR, "/exp_z0L_o.mem"}, ezo0);
        $readmemh({`MEM_DIR, "/exp_z0L_a.mem"}, eza0);
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
            if (cyc > 4000000) begin
                $display("FAIL: timeout, busy=%b st=%0d pc=%0d", busy, dut.st, dut.pc);
                $finish;
            end
        end
        $display("  engine cycles = %0d", cyc);
        repeat (4) @(posedge clk);

        $display("--- compare against fixpt.py (M=3) ---");
        chk(A_HE,  NHE, "H_E ", 0);
        chk(A_ZPE, NZP, "ZP_E", 1);
        chk(A_ZPO, NZP, "ZP_O", 2);
        chk(A_ZPA, NZP, "ZP_A", 3);
        chk(A_HRE, NHE, "HR_E", 4);
        chk(A_HRO, NH,  "HR_O", 5);
        chk(A_HRA, NH,  "HR_A", 6);
        chk(A_HO,  NH,  "H_O ", 7);
        chk(A_HA,  NH,  "H_A ", 8);
        chk(A_QE, NH,  "Q_E ", 9);
        chk(A_KE, NKV, "K_E ", 10);
        chk(A_VE, NKV, "V_E ", 11);
        chk(A_QO, NH,  "Q_O ", 12);
        chk(A_KO, NKV, "K_O ", 13);
        chk(A_VO, NKV, "V_O ", 14);
        chk(A_QA, NH,  "Q_A ", 15);
        chk(A_KA, NKV, "K_A ", 16);
        chk(A_VA, NKV, "V_A ", 17);
        chk(A_ZE, NH,  "Z_E0", 18);
        chk(A_ZO, NH,  "Z_O0", 19);
        chk(A_ZA, NH,  "Z_A0", 20);

        if (nbad == 0) $display("ALL PASS");
        else           $display("FAIL (%0d words)", nbad);
        $finish;
    end

endmodule
`default_nettype wire
