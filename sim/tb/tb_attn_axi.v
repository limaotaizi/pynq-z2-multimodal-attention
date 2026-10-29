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
// tb_attn_axi.v -- bit-exact check of the AXI4-Lite wrapper
//
//   Same golden vectors as tb_attn.v, but every byte goes through AXI:
//     1.  read ID / STATUS
//     2.  load out/in.mem (1336 words) as 668 packed 32-bit bursts
//     3.  CTRL.START, poll STATUS.DONE
//     4.  read back the 14 arrays (3,200 words) and compare with fixpt.py
//
//   A pass here means the wrapper is transparent: same data, same results.
//   ASCII only.
// =============================================================================
module tb_attn_axi;

    localparam integer NIN = 1336;
    localparam integer NHE = 1024;
    localparam integer NZP = 256;
    localparam [12:0]  A_HE  = 13'd3072;
    localparam [12:0]  A_ZPE = 13'd4864;
    localparam [12:0]  A_ZPO = 13'd5120;
    localparam [15:0]  DATA  = 16'h0100;

    reg clk = 1'b0;
    reg aresetn = 1'b0;

    reg  [15:0] s_awaddr = 16'd0;
    reg         s_awvalid = 1'b0;
    wire        s_awready;
    reg  [31:0] s_wdata = 32'd0;
    reg  [3:0]  s_wstrb = 4'd0;
    reg         s_wvalid = 1'b0;
    wire        s_wready;
    wire [1:0]  s_bresp;
    wire        s_bvalid;
    reg         s_bready = 1'b0;
    reg  [15:0] s_araddr = 16'd0;
    reg         s_arvalid = 1'b0;
    wire        s_arready;
    wire [31:0] s_rdata;
    wire [1:0]  s_rresp;
    wire        s_rvalid;
    reg         s_rready = 1'b0;

    reg aw_ok, w_ok;

    reg [15:0] inbuf [0:NIN-1];
    reg [15:0] exph  [0:NHE-1];
    reg [15:0] expze [0:NZP-1];
    reg [15:0] expzo [0:NZP-1];
    reg [15:0] exphre[0:NHE-1];
    reg [15:0] exphro[0:63];
    reg [15:0] eqe [0:63];
    reg [15:0] eke [0:63];
    reg [15:0] eve [0:63];
    reg [15:0] eqo [0:63];
    reg [15:0] eko [0:63];
    reg [15:0] evo [0:63];
    reg [15:0] ez0 [0:63];
    reg [15:0] ezo0[0:63];
    reg [15:0] eho [0:63];

    integer i, nbad, cyc;
    reg [31:0] d;
    reg [15:0] e0, e1;

    always #2.5 clk = ~clk;

    attn_axi #(.T(4), .D(16), .AW(16)) dut (
        .s_axi_aclk    (clk),
        .s_axi_aresetn (aresetn),
        .s_axi_awaddr  (s_awaddr),
        .s_axi_awvalid (s_awvalid),
        .s_axi_awready (s_awready),
        .s_axi_wdata   (s_wdata),
        .s_axi_wstrb   (s_wstrb),
        .s_axi_wvalid  (s_wvalid),
        .s_axi_wready  (s_wready),
        .s_axi_bresp   (s_bresp),
        .s_axi_bvalid  (s_bvalid),
        .s_axi_bready  (s_bready),
        .s_axi_araddr  (s_araddr),
        .s_axi_arvalid (s_arvalid),
        .s_axi_arready (s_arready),
        .s_axi_rdata   (s_rdata),
        .s_axi_rresp   (s_rresp),
        .s_axi_rvalid  (s_rvalid),
        .s_axi_rready  (s_rready)
    );

    // ---------------------------------------------------------------- AXI master
    task ax_write;
        input [15:0] addr;
        input [31:0] data;
        input [3:0]  strb;
        integer k;
        reg b_drop;
        begin
            @(negedge clk);
            s_awaddr = addr; s_awvalid = 1'b1;
            s_wdata  = data; s_wstrb = strb; s_wvalid = 1'b1;
            aw_ok = 1'b0; w_ok = 1'b0;
            while (!(aw_ok && w_ok)) begin
                @(posedge clk);
                if (s_awvalid && s_awready) aw_ok = 1'b1;
                if (s_wvalid  && s_wready)  w_ok  = 1'b1;
                @(negedge clk);
                if (aw_ok) s_awvalid = 1'b0;
                if (w_ok)  s_wvalid  = 1'b0;
            end
            while (!s_bvalid) @(posedge clk);
            @(negedge clk);
            s_bready = 1'b1;
            @(posedge clk);
            @(negedge clk);
            s_bready = 1'b0;
            // BVALID must drop after the handshake.  If it does not, every
            // later write retires against this stale response and the PS
            // wedges on its next store -- that is exactly what the board did
            // on the first control-register write.
            b_drop = 0;
            for (k = 0; k < 8 && !b_drop; k = k + 1) begin
                @(posedge clk);
                if (!s_bvalid) b_drop = 1;
            end
            if (!b_drop) begin
                $display("FAIL: BVALID stuck high after write to %04x", addr);
                nbad = nbad + 1;
            end
        end
    endtask

    task ax_read;
        input  [15:0] addr;
        output [31:0] data;
        begin
            @(negedge clk);
            s_araddr = addr; s_arvalid = 1'b1;
            @(posedge clk);
            while (!s_arready) @(posedge clk);
            @(negedge clk);
            s_arvalid = 1'b0;
            while (!s_rvalid) @(posedge clk);
            data = s_rdata;
            @(negedge clk);
            s_rready = 1'b1;
            @(posedge clk);
            @(negedge clk);
            s_rready = 1'b0;
        end
    endtask

    function [15:0] expval;
        input integer mode;
        input integer idx;
        begin
            case (mode)
                0:  expval = exph[idx];
                1:  expval = expze[idx];
                2:  expval = expzo[idx];
                3:  expval = exphre[idx];
                4:  expval = exphro[idx];
                5:  expval = eqe[idx];
                6:  expval = eke[idx];
                7:  expval = eve[idx];
                8:  expval = eqo[idx];
                9:  expval = eko[idx];
                10: expval = evo[idx];
                11: expval = ez0[idx];
                12: expval = ezo0[idx];
                default: expval = eho[idx];
            endcase
        end
    endfunction

    task chk;
        input [12:0] base;
        input integer n;
        input [8*16-1:0] tag;
        input integer mode;
        integer k, bad;
        begin
            bad = 0;
            for (k = 0; k < n/2; k = k + 1) begin
                ax_read(DATA + ((base + 2*k) << 1), d);
                e0 = expval(mode, 2*k);
                e1 = expval(mode, 2*k+1);
                if (d[15:0] !== e0 || d[31:16] !== e1) begin
                    if (bad < 8)
                        $display("  MISMATCH %0s[%0d] addr=%0d got=%04x %04x exp=%04x %04x",
                                 tag, 2*k, base + 2*k, d[31:16], d[15:0], e1, e0);
                    bad = bad + 1;
                end
            end
            if (bad == 0) $display("  %0s: %0d words OK", tag, n);
            else          $display("  %0s: %0d / %0d MISMATCH", tag, bad, n/2);
            nbad = nbad + bad;
        end
    endtask

    initial begin
        $readmemh({`MEM_DIR, "/in.mem"},      inbuf);
        $readmemh({`MEM_DIR, "/exp_h.mem"},   exph);
        $readmemh({`MEM_DIR, "/exp_ze.mem"},  expze);
        $readmemh({`MEM_DIR, "/exp_zo.mem"},  expzo);
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
        $readmemh({`MEM_DIR, "/exp_ho.mem"},   eho);
        nbad = 0;

        repeat (8) @(posedge clk);
        aresetn = 1'b1;
        repeat (2) @(posedge clk);

        // ---- control registers
        $display("--- AXI control ---");
        ax_read(16'h0008, d);
        if (d !== 32'h41540001) $display("  ID MISMATCH got=%08x", d);
        else                   $display("  ID  : %08x OK", d);
        ax_read(16'h0004, d);
        if (d[1:0] !== 2'b00) $display("  STATUS expected idle, got=%0d", d[1:0]);
        else                  $display("  STATUS idle OK");

        // ---- a control write must be followed by a working data write.
        //      On the board a stranded BVALID after the first control write
        //      wedged the PS on its next store.
        $display("--- control write then data write ---");
        ax_write(16'h000C, 32'h0000_0001, 4'b0001);      // DONE_CLR
        ax_write(DATA, 32'h1234_5678, 4'b1111);
        ax_read(DATA, d);
        if (d !== 32'h1234_5678)
            $display("  FAIL: post-CTRL write read back %08x", d);
        else
            $display("  post-CTRL write OK");

        // ---- load input, two scratch words per beat
        $display("--- AXI load %0d words ---", NIN);
        for (i = 0; i < NIN/2; i = i + 1)
            ax_write(DATA + (i << 2), {inbuf[2*i+1], inbuf[2*i]}, 4'b1111);

        // ---- run
        $display("--- start ---");
        ax_write(16'h0000, 32'h0000_0001, 4'b0001);

        cyc = 0;
        while (!dut.done_sticky && cyc < 3000000) begin
            @(posedge clk);
            cyc = cyc + 1;
        end
        if (!dut.done_sticky) begin
            $display("FAIL: timeout, busy=%b", dut.busy);
            $finish;
        end
        $display("  engine done, %0d clk waited", cyc);

        // ---- verify
        $display("--- compare against fixpt.py (through AXI) ---");
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

        // ---- status now
        ax_read(16'h0004, d);
        if (d[1:0] !== 2'b10) $display("  STATUS expected done, got=%0d", d[1:0]);
        else                  $display("  STATUS done OK");

        if (nbad == 0) $display("ALL PASS");
        else           $display("FAIL (%0d words)", nbad);
        $finish;
    end

endmodule
`default_nettype wire
