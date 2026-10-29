`timescale 1ns/1ps
`default_nettype none
// Testbench for align_buf.
//
// ★ 2026-10-23 改：尺寸从 NSLOT=4 / WORDS=2 换成**设计真实尺寸**
//   NSLOT=8、WORDS=222（眼动 37 ch * 6 stats），DW=16，NCH=4。
//   旧版用 WORDS=2，只能证明控制逻辑；`align_buf.v` 的地址口当时硬编码 4 bit
//   （WORDS ≤ 16），装不下 222/120/102 字/槽这个设计需求，而旧 TB 根本测不到。
//   现在地址口是 AW = $clog2(WORDS) = 8 bit，本 TB 逐字写满并逐字读回，
//   若地址口再退回窄位宽，writes 会串到相邻槽，check_bank 立刻报 MISMATCH。
//
// ★ 2026-10-24 改：读口从异步改成**同步**（寄存一拍）。原因是要推成 BRAM 才能上
//   200 MHz；异步读只会被推成分布式 RAM。check_bank 因此每个字多等一个时钟沿。
//
// Checks:
//   1. two complete windows at full size: win_ready pulses, rd_bank toggles, and
//      every one of NCH*NSLOT*WORDS = 7,104 words reads back what was written;
//   2. windows do not overlap: the second window's data lives in the other bank;
//   3. an out-of-range wr_addr (>= WORDS) is dropped, not aliased into the next
//      slot (the guard `wr_addr < WORDS` is a real safety net at AW=8, where
//      addresses 222..255 exist on the port but have no meaning);
//   4. a modality that runs a whole window ahead sets ovf and does not corrupt
//      the window handoff;
//   5. clr resets counters and overflow.
module tb_align_buf;

    localparam integer NSLOT = 8, WORDS = 222, DW = 16, NCH = 4;
    localparam integer AW    = (WORDS <= 1) ? 1 : $clog2(WORDS);
    localparam integer SLOTW = (NSLOT <= 1) ? 1 : $clog2(NSLOT);

    reg clk = 0, rst_n = 0, clr = 0;
    reg wr_en = 0;
    reg [1:0] wr_mod = 0;
    reg [SLOTW-1:0] wr_slot = 0;
    reg [AW-1:0] wr_addr = 0;
    reg [DW-1:0] wr_data = 0;
    reg [NCH-1:0] slot_done = 0;

    reg [1:0] rd_mod = 0;
    reg [SLOTW-1:0] rd_slot = 0;
    reg [AW-1:0] rd_addr = 0;

    wire win_ready, rd_bank;
    wire [NCH-1:0] ovf;
    wire [DW-1:0] rd_data;

    align_buf #(.NSLOT(NSLOT), .WORDS(WORDS), .DW(DW), .NCH(NCH)) dut (
        .clk(clk), .rst_n(rst_n), .clr(clr),
        .wr_en(wr_en), .wr_mod(wr_mod), .wr_slot(wr_slot),
        .wr_addr(wr_addr), .wr_data(wr_data),
        .slot_done(slot_done), .win_ready(win_ready), .rd_bank(rd_bank),
        .ovf(ovf), .rd_mod(rd_mod), .rd_slot(rd_slot), .rd_addr(rd_addr),
        .rd_data(rd_data));

    always #5 clk = ~clk;

    integer errs = 0, m, s, a, nwin = 0, nchecked = 0;
    function [DW-1:0] pat;
        input integer win;
        input integer mod_;
        input integer slot;
        input integer addr;
        begin
            pat = (win * 4096 + mod_ * 256 + slot * 17 + addr * 3) & 16'hFFFF;
        end
    endfunction

    // Write one slot (WORDS words), then pulse slot_done for that modality.
    task write_slot(input integer win, input integer mod_, input integer slot);
        begin
            for (a = 0; a < WORDS; a = a + 1) begin
                wr_en = 1; wr_mod = mod_; wr_slot = slot; wr_addr = a;
                wr_data = pat(win, mod_, slot, a);
                @(posedge clk); #1;
            end
            wr_en = 0;
            slot_done = (1 << mod_);
            @(posedge clk); #1;
            slot_done = 0;
        end
    endtask

    task check_bank(input integer win);
        begin
            for (m = 0; m < NCH; m = m + 1)
                for (s = 0; s < NSLOT; s = s + 1)
                    for (a = 0; a < WORDS; a = a + 1) begin
                        // 读口自 2026-10-24 起是**同步**的（为了推成 BRAM、
                        // 200 MHz 才收得掉），地址给进去后要等一个时钟沿才出数。
                        rd_mod = m; rd_slot = s; rd_addr = a;
                        @(posedge clk); #1;
                        nchecked = nchecked + 1;
                        if (rd_data !== pat(win, m, s, a)) begin
                            // 只报前 10 条，避免窄地址口时刷屏
                            if (errs < 10)
                                $display("MISMATCH win%0d mod%0d slot%0d a%0d: got %04x want %04x",
                                         win, m, s, a, rd_data, pat(win, m, s, a));
                            errs = errs + 1;
                        end
                    end
        end
    endtask

    initial begin
        $display("align_buf TB: NSLOT=%0d WORDS=%0d AW=%0d SLOTW=%0d DW=%0d NCH=%0d",
                 NSLOT, WORDS, AW, SLOTW, DW, NCH);
        repeat (3) @(posedge clk);
        rst_n = 1;
        repeat (2) @(posedge clk);

        // ---------------- window 0: fill bank 1, expect toggle 0 -> 1
        for (m = 0; m < NCH; m = m + 1)
            for (s = 0; s < NSLOT; s = s + 1)
                write_slot(0, m, s);
        // win_ready/rd_bank were registered on the completing edge, which is
        // the last edge write_slot consumed; they are valid right now.
        if (!win_ready) begin $display("FAIL: win_ready not asserted (w0)"); errs = errs + 1; end
        if (rd_bank !== 1'b1) begin $display("FAIL: rd_bank did not toggle to 1"); errs = errs + 1; end
        nwin = nwin + 1;
        check_bank(0);

        // ---------------- window 1: fills the other bank, with a poison write
        // (m0,s1) is written first and never touched again, so a poisoned
        // out-of-range address that aliased into it would survive to check_bank.
        // addr = WORDS maps to base(m0,s1) + (WORDS - WORDS) = (m0,s1,0) ... i.e.
        // base(m0,s0) + WORDS == base(m0,s1) + 0 under a broken guard.
        write_slot(1, 0, 1);
        wr_en = 1; wr_mod = 0; wr_slot = 0; wr_addr = WORDS; wr_data = 16'hDEAD;
        @(posedge clk); #1;
        wr_en = 0;
        for (s = 0; s < NSLOT; s = s + 1)
            if (s != 1) write_slot(1, 0, s);
        for (m = 1; m < NCH; m = m + 1)
            for (s = 0; s < NSLOT; s = s + 1)
                write_slot(1, m, s);
        if (!win_ready) begin $display("FAIL: win_ready not asserted (w1)"); errs = errs + 1; end
        if (rd_bank !== 1'b0) begin $display("FAIL: rd_bank did not toggle back to 0"); errs = errs + 1; end
        nwin = nwin + 1;
        check_bank(1);

        // ---------------- overflow: mod 0 runs a whole window ahead
        // Fill window 2 slot 0 for mod 0, then send five more slot_done pulses
        // from mod 0 without completing the others; the 5th extra pulse is a
        // whole window ahead and must set ovf[0].
        for (m = 0; m < NCH; m = m + 1) begin
            wr_en = 1; wr_mod = m; wr_slot = 0; wr_addr = 0; wr_data = 16'hAAAA;
            @(posedge clk); #1;
        end
        wr_en = 0;
        for (s = 0; s < NSLOT; s = s + 1) begin
            slot_done = 4'b0001; @(posedge clk); #1; slot_done = 0;
        end
        // mod 0 complete; give it one more pulse -> overflow
        slot_done = 4'b0001; @(posedge clk); #1; slot_done = 0;
        if (ovf[0] !== 1'b1) begin
            $display("FAIL: ovf[0] not set on a whole-window lead"); errs = errs + 1;
        end else begin
            $display("  ovf[0] set as expected");
        end
        if (win_ready) begin $display("FAIL: win_ready fired with only one modality done"); errs = errs + 1; end

        // ---------------- clr resets counters and overflow
        clr = 1; @(posedge clk); #1; clr = 0; @(posedge clk); #1;
        if (ovf !== 0) begin $display("FAIL: clr did not clear ovf"); errs = errs + 1; end

        if (errs == 0)
            $display("ALL PASS  align_buf (%0d words x %0d windows checked, overflow/clr ok)",
                     nchecked, nwin);
        else
            $display("FAIL  align_buf: %0d mismatches (of %0d words)", errs, nchecked);
        $finish;
    end

endmodule

`default_nettype wire
