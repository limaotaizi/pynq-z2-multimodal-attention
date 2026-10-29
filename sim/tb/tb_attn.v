`timescale 1ns/1ps
`default_nettype none

// ---------------------------------------------------------------------------
// 存储器向量目录（2026-10-29 去硬编码）
//   默认 ../vectors/m2：从 sim/run/ 启动 xsim 即指向该档已提交的金标准向量。
//   覆盖：xvlog/xelab -d MEM_DIR="\"<dir>\""；综合前改这一处即可。
// ---------------------------------------------------------------------------
`ifndef MEM_DIR
  `define MEM_DIR "../vectors/m2"
`endif

// =============================================================================
// tb_attn.v -- bit-exact check of attn_core against work2/fixpt.py
//
//   1. load out/in.mem into scratch at IN_E (=0)
//   2. pulse start, wait for done
//   3. read back
//        HE   at 3072  (G*T*D = 1024 words) vs out/exp_h.mem
//        ZPE  at 4864  (G*D   = 256  words) vs out/exp_ze.mem
//        ZPO  at 5120  (G*D   = 256  words) vs out/exp_zo.mem
//
//   Any single-word mismatch is printed. Exit status is implied by the
//   "ALL PASS" / "FAIL" line. ASCII only.
// =============================================================================
module tb_attn;

    localparam integer NIN = 1336;
    localparam integer NHE = 1024;
    localparam integer NZP = 256;
    localparam [12:0]  A_IN  = 13'd0;
    localparam [12:0]  A_HE  = 13'd3072;
    localparam [12:0]  A_ZPE = 13'd4864;
    localparam [12:0]  A_ZPO = 13'd5120;

    reg clk = 1'b0;
    reg rst_n = 1'b0;
    reg start = 1'b0;
    wire busy, done;

    reg        hw_en   = 1'b0;
    reg [12:0] hw_addr = 13'd0;
    reg [15:0] hw_data = 16'd0;
    reg [12:0] hr_addr = 13'd0;
    wire [15:0] hr_data;

    reg [15:0] inbuf [0:NIN-1];
    reg [15:0] exph  [0:NHE-1];
    reg [15:0] expze [0:NZP-1];
    reg [15:0] expzo [0:NZP-1];
    reg [15:0] exphre[0:NHE-1];
    reg [15:0] exphro[0:63];
    reg [15:0] got   [0:NHE-1];
    reg [15:0] eqe [0:63];
    reg [15:0] eke [0:63];
    reg [15:0] eve [0:63];
    reg [15:0] eqo [0:63];
    reg [15:0] eko [0:63];
    reg [15:0] evo [0:63];
    reg [15:0] ez0 [0:63];
    reg [15:0] ezo0[0:63];
    reg [15:0] eho [0:63];

    integer i, nbad;
    integer cyc;
    reg [15:0] v;

    always #2.5 clk = ~clk;

    attn_core #(.T(4), .D(16)) dut (
        .clk(clk), .rst_n(rst_n),
        .start(start), .busy(busy), .done(done),
        .hw_en(hw_en), .hw_addr(hw_addr), .hw_data(hw_data),
        .hr_addr(hr_addr), .hr_data(hr_data)
    );

    // one host read: address -> data (1 cycle later)
    task rd;
        input [12:0] a;
        output [15:0] d;
        begin
            @(negedge clk); hr_addr = a;
            @(negedge clk); d = hr_data;
        end
    endtask

    task chk;
        input [12:0] base;
        input integer n;
        input [8*16-1:0] tag;
        input integer mode;   // 0=exph 1=expze 2=expzo
        integer k, bad;
        reg [15:0] e;
        begin
            bad = 0;
            for (k = 0; k < n; k = k + 1) begin
                rd(base + k[12:0], v);
                if (mode == 0) e = exph[k];
                else if (mode == 1) e = expze[k];
                else if (mode == 2) e = expzo[k];
                else if (mode == 3) e = exphre[k];
                else if (mode == 4) e = exphro[k];
                else if (mode == 5) e = eqe[k];
                else if (mode == 6) e = eke[k];
                else if (mode == 7) e = eve[k];
                else if (mode == 8) e = eqo[k];
                else if (mode == 9) e = eko[k];
                else if (mode == 10) e = evo[k];
                else if (mode == 11) e = ez0[k];
                else if (mode == 12) e = ezo0[k];
                else e = eho[k];
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
        if (dut.st == 4'd6 && dut.pc == 8'd177 && dut.ast == 5'd23 && dut.at_t == 0 && dut.at_c == 0) begin
            $display("  AT pc=%0d t=%0d c=%0d lg=%0d %0d %0d %0d mx=%0d pv=%0d %0d %0d %0d aq=%0d %0d %0d %0d av=%0d %0d %0d %0d S=%0d P=%0d acc=%0d tok=%0d M=%0d SH=%0d",
                dut.pc, dut.at_t, dut.at_c,
                $signed(dut.lgv[0]), $signed(dut.lgv[1]), $signed(dut.lgv[2]), $signed(dut.lgv[3]),
                $signed(dut.at_mx),
                dut.pv[0], dut.pv[1], dut.pv[2], dut.pv[3],
                $signed(dut.aqv[0]), $signed(dut.aqv[1]), $signed(dut.aqv[2]), $signed(dut.aqv[3]),
                $signed(dut.avv[0]), $signed(dut.avv[1]), $signed(dut.avv[2]), $signed(dut.avv[3]),
                dut.at_S, dut.at_P, $signed(dut.at_acc), $signed(dut.avtok), dut.o_AM, dut.o_ASH);
        end
    end
    always @(posedge clk) begin
        if (busy && (cyc % 20000 == 0))
            $display("  t=%0t cyc=%0d pc=%0d st=%0d ast=%0d ph=%0d lp=%0d lp2=%0d",
                     $time, cyc, dut.pc, dut.st, dut.ast, dut.ph, dut.lp, dut.rgp);
    end

    initial begin
        $readmemh({`MEM_DIR, "/in.mem"},     inbuf);
        $readmemh({`MEM_DIR, "/exp_h.mem"},  exph);
        $readmemh({`MEM_DIR, "/exp_ze.mem"}, expze);
        $readmemh({`MEM_DIR, "/exp_zo.mem"}, expzo);
        $readmemh({`MEM_DIR, "/exp_hre.mem"}, exphre);
        $readmemh({`MEM_DIR, "/exp_hro.mem"}, exphro);
        $readmemh({`MEM_DIR, "/exp_qL_e.mem"}, eqe);
        $readmemh({`MEM_DIR, "/exp_kL_e.mem"}, eke);
        $readmemh({`MEM_DIR, "/exp_vL_e.mem"}, eve);
        $readmemh({`MEM_DIR, "/exp_qL_o.mem"}, eqo);
        $readmemh({`MEM_DIR, "/exp_kL_o.mem"}, eko);
        $readmemh({`MEM_DIR, "/exp_vL_o.mem"}, evo);
        $readmemh({`MEM_DIR, "/exp_z0L_e.mem"}, ez0);
        $readmemh({`MEM_DIR, "/exp_z0L_o.mem"}, ezo0);
        $readmemh({`MEM_DIR, "/exp_ho.mem"}, eho);
        nbad = 0;

        repeat (4) @(posedge clk);
        rst_n = 1'b1;
        repeat (2) @(posedge clk);

        // ---- load input
        for (i = 0; i < NIN; i = i + 1) begin
            @(negedge clk);
            hw_en   = 1'b1;
            hw_addr = A_IN + i[12:0];
            hw_data = inbuf[i];
        end
        @(negedge clk); hw_en = 1'b0;
        repeat (2) @(posedge clk);

        // ---- run
        cyc = 0;
        @(negedge clk); start = 1'b1;
        @(negedge clk); start = 1'b0;
        while (!done) begin
            @(posedge clk);
            cyc = cyc + 1;
            if (cyc > 2000000) begin
                $display("FAIL: timeout, busy=%b", busy);
                $finish;
            end
        end
        $display("  engine cycles = %0d", cyc);
        repeat (4) @(posedge clk);

        // ---- verify
        $display("--- compare against fixpt.py ---");
        chk(A_HE,  NHE, "H_E ", 0);
        chk(A_ZPE, NZP, "ZP_E", 1);
        chk(A_ZPO, NZP, "ZP_O", 2);
        chk(13'd1536, NHE, "HR_E", 3);
        chk(13'd2560, 64,  "HR_O", 4);
        chk(13'd4352, 64,  "Q_EL", 5);
        chk(13'd4416, 64,  "K_E ", 6);
        chk(13'd4480, 64,  "V_E ", 7);
        chk(13'd4544, 64,  "Q_O ", 8);
        chk(13'd4608, 64,  "K_O ", 9);
        chk(13'd4672, 64,  "V_O ", 10);
        chk(13'd4736, 64,  "Z_E0", 11);
        chk(13'd4800, 64,  "Z_O0", 12);
        chk(13'd4096, 64,  "H_O ", 13);

        if (nbad == 0) $display("ALL PASS");
        else           $display("FAIL (%0d words)", nbad);
        $finish;
    end

endmodule
`default_nettype wire
