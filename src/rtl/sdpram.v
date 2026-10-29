`timescale 1ns / 1ps
`default_nettype none
// =============================================================================
// sdpram.v —— 简单双口 RAM（写口 A / 读口 B），强制 BRAM
//
//   ★ 为什么不用 `(* ram_style = "block" *)` 让 Vivado 自己推断：
//     在 eeg_fe 里同样的写法，512×32 能进 BRAM，1024×48 与 512×112 却被判
//     "Synth 8-6849 Infeasible ... trying to implement using LUTRAM"，
//     落到 2140 个 RAMD64E，把布局摊满 30+ 行，读地址到读数据实测 8.4 ns。
//     同样的两块内存在空模块里能正常进 BRAM（1×RAMB18 + 3×RAMB36），
//     说明是上下文触发的推断失败，不是形状问题。这里直接实例化 XPM，
//     让存储实现不再依赖推断。
//
//   ★ WRITE_MODE_B = "read_first"：读写同址时读口返回**旧值**，
//     与 RTL 行为（写读在不同 always 块，同一时钟沿两侧都取旧存储内容）
//     以及 xsim 里逐位对齐的模型一致。
//
//   读延迟固定 1 拍：addrb 打一拍，doutb 在下一沿有效。
// =============================================================================
module sdpram #(
    parameter integer DW = 48,      // 数据宽度
    parameter integer AW = 10,      // 地址宽度（深度 = 2**AW）
    // 读写同址时读口的行为。默认 read_first（与"写读分两个 always 块"的
    // RTL 语义一致）；FIFO 的预取结构需要 write_first。
    parameter         WMODE = "read_first"
) (
    input  wire          clk,
    input  wire          we,
    input  wire [AW-1:0] waddr,
    input  wire [DW-1:0] wdata,
    input  wire [AW-1:0] raddr,
    output wire [DW-1:0] rdata
);
    xpm_memory_sdpram #(
        .MEMORY_SIZE             (DW * (1 << AW)),
        .MEMORY_PRIMITIVE        ("block"),
        .CLOCKING_MODE           ("common_clock"),
        .ECC_MODE                ("no_ecc"),
        .MEMORY_INIT_FILE        ("none"),
        .MEMORY_INIT_PARAM       ("0"),
        .USE_MEM_INIT            (0),
        .USE_MEM_INIT_MMI        (0),
        .WAKEUP_TIME             ("disable_sleep"),
        .AUTO_SLEEP_TIME         (0),
        .MESSAGE_CONTROL         (0),
        .USE_EMBEDDED_CONSTRAINT (0),
        .MEMORY_OPTIMIZATION     ("false"),
        .CASCADE_HEIGHT          (0),
        .RAM_DECOMP              ("power"),
        .SIM_ASSERT_CHK          (0),
        .WRITE_PROTECT           (1),
        .IGNORE_INIT_SYNTH       (0),
        .WRITE_DATA_WIDTH_A      (DW),
        .BYTE_WRITE_WIDTH_A      (DW),
        .ADDR_WIDTH_A            (AW),
        .RST_MODE_A              ("SYNC"),
        .READ_DATA_WIDTH_B       (DW),
        .ADDR_WIDTH_B            (AW),
        .READ_RESET_VALUE_B      ("0"),
        .READ_LATENCY_B          (1),
        .WRITE_MODE_B            (WMODE),
        .RST_MODE_B              ("SYNC")
    ) u_ram (
        .sleep          (1'b0),
        .clka           (clk),
        .ena            (we),
        .wea            (we),
        .addra          (waddr),
        .dina           (wdata),
        .injectsbiterra (1'b0),
        .injectdbiterra (1'b0),
        .clkb           (clk),
        .rstb           (1'b0),
        .enb            (1'b1),
        .regceb         (1'b1),
        .addrb          (raddr),
        .doutb          (rdata),
        .sbiterrb       (),
        .dbiterrb       ()
    );
endmodule
`default_nettype wire
