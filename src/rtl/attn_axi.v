`timescale 1ns/1ps
`default_nettype none
// =============================================================================
// attn_axi.v -- AXI4-Lite wrapper around attn_core (modules 1+2)
//
//   Why: the 200 MHz study of attn_core ran with hw_*/hr_* as top-level pins
//   and an output delay of 0 ns.  In the block design the engine hangs off the
//   PS AXI interconnect instead, so the real boundary is a registered AXI4-Lite
//   slave: every input is sampled by a flop and every output is driven by one.
//   This wrapper is what must actually close 200 MHz.
//
//   Address map (16-bit byte address, one 32-bit beat per access):
//     0x0000  CTRL      W  bit0 = START (one shot; ignored while busy)
//     0x0004  STATUS    R  bit0 = busy, bit1 = done (sticky)
//     0x0008  ID        R  0x4154_0001
//     0x000C  DONE_CLR  W  bit0 = clear sticky done
//     0x0100  ..0x40FF  RW scratch window (8192 x 16 bit)
//                          beat W = (byte addr - 0x0100) >> 2
//                          data[15:0]  -> scratch[2W]
//                          data[31:16] -> scratch[2W+1]
//                          WSTRB selects whole 16-bit halves (byte granularity
//                          inside a half is not supported by the engine port).
//
//   The engine owns a single-port scratch RAM.  While it is busy (and for the
//   window between START and busy, covered by run_lock) the slave stalls the
//   master by holding AW/W/AR ready low; host accesses never race the engine.
//   Read latency: 1 cycle to decode + 3 cycles of the 2-word single-port read.
//
//   Resp is always OKAY.  Out-of-range data-window addresses are ignored on
//   write and read back as 0.
// =============================================================================
module attn_axi #(
    parameter integer T  = 4,
    parameter integer D  = 16,
    // ★ 2026-10-26：透传 attn_core 的 UM（k/v 最大行数 = T*(M-1)）。
    //   缺省 8 覆盖 M=2(U=4) 与 M=3(U=8)，与改前逐位相同；M=4 需 U=12。
    // ---------------------------------------------------------------------
    // UM = M（模态数）上限。**不能靠 BD 覆盖**：Vivado 不会改写 Verilog
    // 参数缺省值，缺省值就是位流里的真值，写错会静默算错。
    //   2026-10-27 交付的 attn4_e4.bit（M=4）用的是 UM=12，
    //   备份见 ip_repo_all/attn_axi/src/attn_axi.v.bak_um12_20261028。
    //   2026-10-28 为 M=2 整机位流 attn2_e4.bit 把缺省改回 8。
    // 现在改成宏，缺省保持 8（不改变现有 TB 与 M=2 重建的行为）；
    // 重建 M=4 时必须显式 -d ATTNAXI_UM=12，否则得到的是另一个设计。
    // 位流 -> UM 对照见 BITSTREAM_MANIFEST.md。
    // ---------------------------------------------------------------------
`ifndef ATTNAXI_UM
  `define ATTNAXI_UM 8
`endif
    parameter integer UM = `ATTNAXI_UM,
    parameter integer AW = 16
)(
    input  wire          s_axi_aclk,
    input  wire          s_axi_aresetn,

    input  wire [AW-1:0] s_axi_awaddr,
    input  wire          s_axi_awvalid,
    output wire          s_axi_awready,
    input  wire [31:0]   s_axi_wdata,
    input  wire [3:0]    s_axi_wstrb,
    input  wire          s_axi_wvalid,
    output wire          s_axi_wready,
    output wire [1:0]    s_axi_bresp,
    output wire          s_axi_bvalid,
    input  wire          s_axi_bready,

    input  wire [AW-1:0] s_axi_araddr,
    input  wire          s_axi_arvalid,
    output wire          s_axi_arready,
    output wire [31:0]   s_axi_rdata,
    output wire [1:0]    s_axi_rresp,
    output wire          s_axi_rvalid,
    input  wire          s_axi_rready
);

    localparam [15:0] A_CTRL = 16'h0000;
    localparam [15:0] A_STAT = 16'h0004;
    localparam [15:0] A_ID   = 16'h0008;
    localparam [15:0] A_CLR  = 16'h000C;
    localparam [15:0] A_DATA = 16'h0100;
    localparam [15:0] A_END  = 16'h40FF;

    assign s_axi_bresp = 2'b00;
    assign s_axi_rresp = 2'b00;

    // ---------------------------------------------------------------- engine
    wire        busy;
    wire        done;
    reg         start_r;
    reg         done_sticky;
    reg         run_lock;

    wire [12:0] hr_addr;
    wire [15:0] hr_data;
    wire        hw_en;
    wire [12:0] hw_addr;
    wire [15:0] hw_data;

    // ---------------------------------------------------------------- read FSM
    // rd_ph: 0 idle, 1 decode, 2 addr lo, 3 addr hi, 4 capture, 5 wait R
    reg  [2:0]  rd_ph;
    reg  [AW-1:0] araddr_q;
    reg  [31:0] rdata_r;
    reg  [15:0] rdata_lo;
    reg         rvalid_r;

    // ---------------------------------------------------------------- write FSM
    // wr_ph: 0 idle/accept, 1 write low half, 2 write high half, 3 wait B
    reg  [1:0]  wr_ph;
    reg         aw_have;
    reg  [AW-1:0] awaddr_q;
    reg         w_have;
    reg  [31:0] wdata_q;
    reg  [3:0]  wstrb_q;
    reg         bvalid_r;

    // ---------------------------------------------------------------- reset
    // aresetn drives every reset pin.  As a top-level input in OOC that is a
    // 3.5 ns route to the far side of the die (-0.114 ns slack).  Two flops
    // absorb the fanout; assertion is then synchronous (fine for OOC timing,
    // and the AXI interconnect de-asserts reset synchronously anyway).
    reg  [1:0] rst_sync = 2'b00;
    wire       rst_n = rst_sync[1];

    always @(posedge s_axi_aclk)
        rst_sync <= {rst_sync[0], s_axi_aresetn};

    wire        bus_hold = busy | run_lock;
    wire [15:0] wr_off = awaddr_q - A_DATA;
    wire [11:0] wr_w   = wr_off[13:2];
    wire        wr_rng = (awaddr_q >= A_DATA) && (awaddr_q <= A_END);
    wire        aw_is_ctl = (awaddr_q < A_DATA);

    // Ready signals are registered.  Two reasons, both from the first AXI
    // build: (1) ready must not be gated by s_axi_aresetn, which made an
    // input->output path with only 1 ns of budget (-1.105 ns); (2) bus_hold
    // comes from attn_core's busy flop and the combinational ready path was
    // 2.7 ns with 1.9 ns of route (-0.719 ns best variant).  One cycle of
    // ready latency is legal: only VALID may not depend on READY.
    //
    // The pins are driven directly by the flops.  The pending-flag term that
    // used to sit in a post-flop AND now sits in the flop input instead: a
    // handshake this cycle must not leave the pin high next cycle, so the
    // "will be accepted now" term is folded into the next-state value.  With
    // the AND at the pin that path was flop -> LUT3 -> pad, 1.4 ns of route
    // on a 2.0 ns output-delay budget (-0.067 / -0.045 ns).
    reg awready_r, wready_r, arready_r;

    assign s_axi_awready = awready_r;
    assign s_axi_wready  = wready_r;
    assign s_axi_arready = arready_r;
    assign s_axi_bvalid  = bvalid_r;

    assign hw_en   = (wr_ph == 2'd1 && wstrb_q[1:0] != 2'b00) ||
                     (wr_ph == 2'd2 && wstrb_q[3:2] != 2'b00);
    assign hw_addr = (wr_ph == 2'd1) ? {wr_w, 1'b0} : {wr_w, 1'b1};
    assign hw_data = (wr_ph == 2'd1) ? wdata_q[15:0] : wdata_q[31:16];

    wire [15:0] rd_off = araddr_q - A_DATA;
    wire [11:0] rd_w   = rd_off[13:2];
    wire        rd_rng = (araddr_q >= A_DATA) && (araddr_q <= A_END);

    assign s_axi_rvalid  = rvalid_r;
    assign s_axi_rdata   = rdata_r;

    // one 16-bit word per clock on the single-port scratch RAM
    assign hr_addr = (rd_ph == 3'd2) ? {rd_w, 1'b0} :
                     (rd_ph == 3'd3) ? {rd_w, 1'b1} : 13'd0;

    // ---------------------------------------------------------------- control
    always @(posedge s_axi_aclk) begin
        if (!rst_n) begin
            wr_ph   <= 2'd0;
            aw_have <= 1'b0;
            awaddr_q<= {AW{1'b0}};
            w_have  <= 1'b0;
            wdata_q <= 32'd0;
            wstrb_q <= 4'd0;
            bvalid_r<= 1'b0;

            rd_ph   <= 3'd0;
            araddr_q<= {AW{1'b0}};
            rdata_r <= 32'd0;
            rdata_lo<= 16'd0;
            rvalid_r<= 1'b0;

            start_r    <= 1'b0;
            done_sticky<= 1'b0;
            run_lock   <= 1'b0;

            awready_r  <= 1'b0;
            wready_r   <= 1'b0;
            arready_r  <= 1'b0;
        end else begin
            start_r <= 1'b0;

            // registered ready (one cycle behind the state).  The last term
            // is "a transfer is being accepted on this channel right now";
            // dropping ready for the following cycle is what the post-flop
            // AND used to do.
            awready_r <= (wr_ph == 2'd0) && !aw_have && !bvalid_r &&
                         !bus_hold && (rd_ph == 3'd0) &&
                         !(s_axi_awvalid && awready_r);
            wready_r  <= (wr_ph == 2'd0) && !w_have  && !bvalid_r &&
                         !bus_hold && (rd_ph == 3'd0) &&
                         !(s_axi_wvalid && wready_r);
            arready_r <= (rd_ph == 3'd0) && !rvalid_r && !bus_hold &&
                         (wr_ph == 2'd0) &&
                         !(s_axi_arvalid && arready_r);

            if (done)          done_sticky <= 1'b1;
            if (done)          run_lock    <= 1'b0;

            // ---- write channel ------------------------------------------------
            if (wr_ph == 2'd0) begin
                if (s_axi_awvalid && s_axi_awready) begin
                    aw_have  <= 1'b1;
                    awaddr_q <= s_axi_awaddr;
                end
                if (s_axi_wvalid && s_axi_wready) begin
                    w_have  <= 1'b1;
                    wdata_q <= s_axi_wdata;
                    wstrb_q <= s_axi_wstrb;
                end
                if (aw_have && w_have) begin
                    aw_have <= 1'b0;
                    w_have  <= 1'b0;
                    if (aw_is_ctl) begin
                        if ((awaddr_q[15:2] == A_CTRL[15:2]) && wstrb_q[0] &&
                            wdata_q[0]) begin
                            start_r     <= 1'b1;
                            run_lock    <= 1'b1;
                            done_sticky <= 1'b0;
                        end else if ((awaddr_q[15:2] == A_CLR[15:2]) &&
                                     wstrb_q[0] && wdata_q[0]) begin
                            done_sticky <= 1'b0;
                        end
                        // BVALID is only ever cleared in wr_ph == 3, so a
                        // control write has to enter that state as well.
                        // Leaving wr_ph at 0 here strands BVALID high: the
                        // interconnect then retires the *next* write against
                        // a stale response and the PS wedges on its next
                        // store (seen on the board, not in the first TB).
                        bvalid_r <= 1'b1;
                        wr_ph    <= 2'd3;
                    end else if (wr_rng) begin
                        wr_ph <= 2'd1;
                    end else begin
                        bvalid_r <= 1'b1;   // outside the window: ignore
                        wr_ph    <= 2'd3;
                    end
                end
            end else if (wr_ph == 2'd1) begin
                wr_ph <= 2'd2;
            end else if (wr_ph == 2'd2) begin
                wr_ph    <= 2'd3;
                bvalid_r <= 1'b1;
            end else begin
                if (s_axi_bready) begin
                    bvalid_r <= 1'b0;
                    wr_ph    <= 2'd0;
                end
            end

            // ---- read channel -------------------------------------------------
            if (rd_ph == 3'd0) begin
                if (s_axi_arvalid && s_axi_arready) begin
                    araddr_q <= s_axi_araddr;
                    rd_ph    <= 3'd1;
                end
            end else if (rd_ph == 3'd1) begin
                if (araddr_q < A_DATA) begin
                    case (araddr_q[3:2])
                        2'd1:    rdata_r <= {30'd0, done_sticky, busy};
                        2'd2:    rdata_r <= 32'h4154_0001;
                        default: rdata_r <= 32'd0;
                    endcase
                    rvalid_r <= 1'b1;
                    rd_ph    <= 3'd5;
                end else if (!rd_rng) begin
                    rdata_r  <= 32'd0;
                    rvalid_r <= 1'b1;
                    rd_ph    <= 3'd5;
                end else begin
                    rd_ph <= 3'd2;
                end
            end else if (rd_ph == 3'd2) begin
                rd_ph <= 3'd3;
            end else if (rd_ph == 3'd3) begin
                rdata_lo <= hr_data;
                rd_ph    <= 3'd4;
            end else if (rd_ph == 3'd4) begin
                rdata_r  <= {hr_data, rdata_lo};
                rvalid_r <= 1'b1;
                rd_ph    <= 3'd5;
            end else begin
                if (s_axi_rready) begin
                    rvalid_r <= 1'b0;
                    rd_ph    <= 3'd0;
                end
            end
        end
    end

    // ---------------------------------------------------------------- engine
    attn_core #(.T(T), .D(D), .UM(UM)) u_core (
        .clk     (s_axi_aclk),
        .rst_n   (rst_n),
        .start   (start_r),
        .busy    (busy),
        .done    (done),
        .hw_en   (hw_en),
        .hw_addr (hw_addr),
        .hw_data (hw_data),
        .hr_addr (hr_addr),
        .hr_data (hr_data)
    );

endmodule
`default_nettype wire
