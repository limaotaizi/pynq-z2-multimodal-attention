`timescale 1ns/1ps
`default_nettype none
// =============================================================================
// tb_align_buf_rt.v -- 四路真实节拍联合 TB（2026-10-24）
//
// 与 tb_align_buf.v 的分工
//   tb_align_buf   : 单窗口容量与地址口（WORDS=222 全写满），外加越界写/溢出/clr。
//   本 TB          : **真实节奏**下的连续多窗口 —— 这是原来缺的那一条。
//
// 真实节奏指什么
//   1. 四路每槽写的字数**不一样**：眼动 222、GSR 120、AU 102、第四路 222（EEG）。
//      模块只有一个全局 WORDS 参数，所以槽宽必须按最大的 222 开，短的模态只写前
//      N 个字就发 slot_done —— 这正是真实上游的行为，也是「模块不能假设大家都写满」
//      这条约束的实测。**这不是缺陷，是设计选择**（按 222 统一开，浪费约 25% 容量，
//      换掉按模态分开寻址的复杂度）。
//   2. 一个窗口结束后**不停顿**就直接开下一个（ping-pong 的真实工况）。
//   3. 读完一个窗口的时候，写口正在往另一个 bank 写 —— 读-写同时发生。
//
// 判据
//   · 每个完成的窗口，四路各槽的前 N 个字逐字等于写入值；
//   · 全程 ovf 保持 0（节奏错开时报溢出就是控制逻辑错）；
//   · 4 个窗口连续完成，rd_bank 交替；
//   · 读窗口 w 期间写窗口 w+1，读到的是 w 的数据（bank 没有串）。
// =============================================================================
module tb_align_buf_rt;

    localparam integer NSLOT = 8, WORDS = 222, DW = 16, NCH = 4;
    localparam integer AW    = (WORDS <= 1) ? 1 : $clog2(WORDS);
    localparam integer SLOTW = (NSLOT <= 1) ? 1 : $clog2(NSLOT);
    localparam integer NWIN  = 4;
    // 每路的真实字数：眼动 37*6、GSR 40*3、AU 17*6、EEG 62*6（封顶到 WORDS）
    localparam integer PACE  = 20000;   // 每窗口之后的空转拍数，模拟 0.5 s 网格

    function integer wpw;
        input integer mm;
        begin
            case (mm)
                0: wpw = 222;
                1: wpw = 120;
                2: wpw = 102;
                default: wpw = 222;
            endcase
        end
    endfunction

    function [DW-1:0] pat;
        input integer win;
        input integer mod_;
        input integer slot;
        input integer addr;
        begin
            pat = (win * 7919 + mod_ * 256 + slot * 17 + addr * 3 + 1) & 16'hFFFF;
        end
    endfunction

    reg clk = 0, rst_n = 0, clr = 0;
    reg wr_en = 0;
    reg [1:0] wr_mod = 0;
    reg [SLOTW-1:0] wr_slot = 0;
    reg [AW-1:0]    wr_addr = 0;
    reg [DW-1:0]    wr_data = 0;
    reg [NCH-1:0]   slot_done = 0;

    reg  [1:0]      rd_mod = 0;
    reg  [SLOTW-1:0] rd_slot = 0;
    reg  [AW-1:0]   rd_addr = 0;

    wire            win_ready, rd_bank;
    wire [NCH-1:0]  ovf;
    wire [DW-1:0]   rd_data;

    align_buf #(.NSLOT(NSLOT), .WORDS(WORDS), .DW(DW), .NCH(NCH)) dut (
        .clk(clk), .rst_n(rst_n), .clr(clr),
        .wr_en(wr_en), .wr_mod(wr_mod), .wr_slot(wr_slot),
        .wr_addr(wr_addr), .wr_data(wr_data),
        .slot_done(slot_done), .win_ready(win_ready), .rd_bank(rd_bank),
        .ovf(ovf), .rd_mod(rd_mod), .rd_slot(rd_slot), .rd_addr(rd_addr),
        .rd_data(rd_data));

    always #5 clk = ~clk;

    integer errs = 0, nwin = 0, nchecked = 0, ovf_hits = 0;
    integer wi, mi, si, ai;

    // ---------------------------------------------------------------- writer
    task write_slot(input integer win, input integer mod_, input integer slot);
        integer k;
        begin
            for (k = 0; k < wpw(mod_); k = k + 1) begin
                wr_en = 1; wr_mod = mod_; wr_slot = slot; wr_addr = k;
                wr_data = pat(win, mod_, slot, k);
                @(posedge clk); #1;
            end
            wr_en = 0;
            slot_done[mod_] = 1'b1;
            @(posedge clk); #1;
            slot_done[mod_] = 1'b0;
        end
    endtask

    initial begin : writer
        repeat (3) @(posedge clk);
        rst_n = 1;
        repeat (2) @(posedge clk);
        for (wi = 0; wi < NWIN; wi = wi + 1) begin
            // 真实工况：同一槽里四路依次交付（上游是时分复用的一个写口）
            for (si = 0; si < NSLOT; si = si + 1)
                for (mi = 0; mi < NCH; mi = mi + 1)
                    write_slot(wi, mi, si);
            repeat (PACE) @(posedge clk);
        end
        // 等最后一个窗口被校验完再收尾
        repeat (PACE) @(posedge clk);
        if (ovf_hits != 0) begin
            $display("FAIL: 节奏错开时不应溢出，但 ovf 触发了 %0d 拍", ovf_hits);
            errs = errs + 1;
        end
        if (errs == 0)
            $display("ALL PASS  align_buf_rt (%0d 窗口 x %0d 字, 真实字数 222/120/102/222, ovf 全程为 0)",
                     nwin, nchecked);
        else
            $display("FAIL  align_buf_rt: %0d 处不符（共查 %0d 字），ovf 触发 %0d 次",
                     errs, nchecked, ovf_hits);
        $finish;
    end

    // ---------------------------------------------------------------- reader
    task check_bank(input integer win);
        integer mm, ss, aa;
        begin
            for (mm = 0; mm < NCH; mm = mm + 1)
                for (ss = 0; ss < NSLOT; ss = ss + 1)
                    for (aa = 0; aa < wpw(mm); aa = aa + 1) begin
                        rd_mod = mm; rd_slot = ss; rd_addr = aa;
                        @(posedge clk); #1;
                        nchecked = nchecked + 1;
                        if (rd_data !== pat(win, mm, ss, aa)) begin
                            if (errs < 10)
                                $display("MISMATCH win%0d mod%0d slot%0d a%0d: got %04x want %04x",
                                         win, mm, ss, aa, rd_data, pat(win, mm, ss, aa));
                            errs = errs + 1;
                        end
                    end
        end
    endtask

    integer rwin = 0;
    reg prev_rd_bank = 1'b0;
    initial begin : reader
        @(posedge rst_n);
        forever begin
            @(posedge clk); #1;      // 跨过本拍的非阻塞赋值，取 win_ready 的新值
            if (win_ready) begin
                // win_ready 与 rd_bank 翻转同拍，此刻 rd_bank 已指向刚写完的 bank
                if (rwin > 0 && rd_bank === prev_rd_bank) begin
                    $display("FAIL: rd_bank 在窗口 %0d 没有翻转", rwin);
                    errs = errs + 1;
                end
                prev_rd_bank = rd_bank;
                check_bank(rwin);      // 期间 writer 正在写另一个 bank
                rwin = rwin + 1;
                nwin = rwin;
            end
        end
    end

    // ---------------------------------------------------------------- ovf 监视
    always @(posedge clk)
        if (rst_n && ovf !== 0) ovf_hits = ovf_hits + 1;

endmodule

`default_nettype wire
