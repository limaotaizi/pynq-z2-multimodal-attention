`timescale 1ns / 1ps
`default_nettype none
// =============================================================================
// ts_core.v —— 全局时间戳核心（方案三 §3.1）
//
//   一颗 200 MHz 自由计数器（分辨率 5 ns）供**全部四路模态共用**。
//   每路采样点到达时抓取当前计数值，经仲裁压入共享时间戳 FIFO。
//
//   ★ 整个设计只有一个时钟 ⇒ 全程无跨时钟域。
//     这就是"统一时基"最直接的实现形式，也是 PS 侧 clock_gettime 给不出的：
//     那边每个采样点都要过一次 vDSO/系统调用与调度器，硬件事件与时间戳之间
//     隔着一整个操作系统，抖动是**软件栈"的，不是时间的。
//
//   溢出周期：2^48 × 5 ns = 1.407e6 s ≈ 16.3 天
//     （设计文档 03 §3.1 写"≈ 3.9 天"，那对应 2^46；已勘误，见 README_PL.md）
//
//   ovf_sticky 有两种来源，语义统一为"丢了一个样本"：
//     (a) 某路的上一戳还没被取走，新样本又到了（物理上不该发生）
//     (b) FIFO 满，这一戳进不去
// =============================================================================
module ts_core #(
    parameter integer TW = 48,   // 时间戳位宽
    parameter integer NW = 4,    // 模态路数（须为 2 的幂）
    parameter integer AW = 8     // FIFO 深度 = 2**AW
)(
    input  wire                     clk,
    input  wire                     rst_n,
    input  wire                     run,          // 1 = 计数器自由运行
    input  wire                     clr,          // 单周期脉冲：计数器归零
    input  wire                     fifo_rst,     // 单周期脉冲：清空 FIFO 与捕获槽
    input  wire [NW-1:0]            s_valid,      // 各路采样到达（每路 1 bit，单周期脉冲）
    input  wire [NW-1:0]            ovf_clr,      // 写 1 清该路的 lost 粘滞位

    output wire [TW-1:0]            t_now,        // 当前计数值（给 AXI 读回）
    output wire [TW+$clog2(NW)-1:0] m_tdata,      // FIFO 出队：{mod, t}
    output wire                     m_tvalid,
    input  wire                     m_tready,
    output wire                     fifo_empty,
    output wire                     fifo_full,
    output wire [AW:0]              fifo_level,
    output wire [NW-1:0]            ovf_sticky,
    output reg  [31:0]              enq_count,

    // 仲裁结果同时送给下游 τ 补偿单元（同一拍、同一份样本）
    output wire                     arb_valid,
    output wire [$clog2(NW)-1:0]    arb_mod,
    output wire [TW-1:0]            arb_ts
);
    localparam integer MW    = $clog2(NW);
    localparam integer DW    = TW + MW;
    localparam integer DEPTH = (1 << AW);

    // ------------------------------------------------------------------ 自由计数器
    reg [TW-1:0] cnt;
    always @(posedge clk) begin
        if      (!rst_n) cnt <= {TW{1'b0}};
        else if (clr)    cnt <= {TW{1'b0}};
        else if (run)    cnt <= cnt + 1'b1;
    end
    assign t_now = cnt;

    // ------------------------------------------------------------------ 逐路捕获槽
    reg [TW-1:0] cap_t [0:NW-1];
    reg [NW-1:0] cap_v;
    reg [NW-1:0] ovf;

    // ------------------------------------------------------------------ 轮转仲裁
    // 从 rr_ptr 起按固定优先级找第一个有数据的路；NW 是 2 的幂，
    // 故 (rr_ptr + k) 截断到 MW 位即等于对 NW 取模。
    reg  [MW-1:0] rr_ptr;
    reg  [MW-1:0] sel_idx;
    reg           sel_v;
    integer       k;
    always @(*) begin
        sel_v   = 1'b0;
        sel_idx = rr_ptr;
        for (k = NW-1; k >= 0; k = k - 1) begin
            if (cap_v[rr_ptr + k[MW-1:0]]) begin   // 降序 + 覆盖 ⇒ 最后执行的 k=0 优先
                sel_idx = rr_ptr + k[MW-1:0];
                sel_v   = 1'b1;
            end
        end
    end
    assign arb_valid = sel_v;
    assign arb_mod   = sel_idx;
    assign arb_ts    = cap_t[sel_idx];

    // ------------------------------------------------------------------ 共享时间戳 FIFO
    // ★ 强制块 RAM（2026-10-18）。48 bit × 256 = 12 Kb，一个 BRAM 足够；
    //   推断成分布式 RAM 时 Vivado 铺了 68 个 RAMD64E，地址/数据布线跨 4.45 ns，
    //   rd_ptr → dout_r 收敛不了（WNS = -1.482 ns）。BRAM 的地址与输出都在
    //   同一个 primitive 里，这条路天然短。整个设计只用 1~2 个 BRAM。
    (* ram_style = "block" *)
    reg  [DW-1:0] fifo_mem [0:DEPTH-1];
    reg  [AW:0]   wr_ptr, rd_ptr;
    wire [AW:0]   level = wr_ptr - rd_ptr;
    wire          empty = (wr_ptr == rd_ptr);
    wire          full  = (wr_ptr[AW-1:0] == rd_ptr[AW-1:0]) && (wr_ptr[AW] != rd_ptr[AW]);

    wire        push = sel_v;                 // 有样本就尝试入队（满则丢弃并记 lost）
    wire        push_wr = push && !full;
    wire        pop  = m_tready && !empty;
    wire [DW-1:0] wr_data = {sel_idx, cap_t[sel_idx]};

    // ★ 出队口寄存一级（2026-10-18）。
    //   原实现 `m_tdata = fifo_mem[rd_ptr]` 让「读指针 → 异步读 RAM → 读数据
    //   多路器 → rdata_r」成为一条组合路径，布局后 5.175 ns（WNS = -0.290 ns）。
    //   这里把队头预先寄存：dout_r 在每一拍都等于 mem[rd_ptr_next]，其中
    //   rd_ptr_next = rd_ptr + pop。对外仍是 FWFT 语义（读走的是当前队头）。
    //
    //   ★ 写直达旁路（放在 RAM 外面）：FIFO 空时同一拍 push 与「下一拍要读的
    //     地址」重合，同步 RAM 的非阻塞读会拿到旧值（X）。早先把旁路写进
    //     dout_r 的同一 always 块里，Vivado 判定 `ram_style="block"` 不可行
    //     （Synth 8-6849，强制降级成 272 个 LUTRAM）；把旁路拆成独立的一拍
    //     寄存器后，fifo_mem 的模板变干净，合成出 1 个 Block RAM。
    wire [AW:0]   rd_ptr_next = rd_ptr + (pop ? 1'b1 : 1'b0);
    reg  [DW-1:0] dout_r;

    always @(posedge clk) begin
        if (!rst_n || fifo_rst) begin
            wr_ptr <= {(AW+1){1'b0}};
            rd_ptr <= {(AW+1){1'b0}};
            dout_r <= {DW{1'b0}};
        end else begin
            if (push_wr) begin
                fifo_mem[wr_ptr[AW-1:0]] <= wr_data;
                wr_ptr <= wr_ptr + 1'b1;
            end
            if (pop) rd_ptr <= rd_ptr + 1'b1;
            dout_r <= fifo_mem[rd_ptr_next[AW-1:0]];
        end
    end

    // 写-读同址旁路：只影响紧接着的那一拍，之后 RAM 里已经是新值
    reg           bypass_v;
    reg  [DW-1:0] bypass_d;
    wire bypass_hit = push_wr && (wr_ptr[AW-1:0] == rd_ptr_next[AW-1:0]);

    always @(posedge clk) begin
        if (!rst_n || fifo_rst) begin
            bypass_v <= 1'b0;
            bypass_d <= {DW{1'b0}};
        end else begin
            bypass_v <= bypass_hit;
            // ★ 不设时钟使能（2026-10-18）：`bypass_hit` 曾直接驱动 50 位
            //   bypass_d 的 CE，比较逻辑 + 3.14 ns 布线使它成为唯一违例路径
            //   （WNS = -0.223 ns）。改为每拍加载，只有 bypass_v 一个触发器
            //   使用该比较结果；没有 push 时装载的是无关值，反正被 bypass_v 屏蔽。
            bypass_d <= wr_data;
        end
    end

    assign m_tvalid   = !empty;
    assign m_tdata    = bypass_v ? bypass_d : dout_r;
    assign fifo_empty = empty;
    assign fifo_full  = full;
    assign fifo_level = level;
    assign ovf_sticky = ovf;

    // ------------------------------------------------------------------ 捕获 / lost
    always @(posedge clk) begin
        if (!rst_n || fifo_rst) begin
            cap_v <= {NW{1'b0}};
            for (k = 0; k < NW; k = k + 1) cap_t[k] <= {TW{1'b0}};
        end else begin
            for (k = 0; k < NW; k = k + 1) begin
                if (s_valid[k]) begin
                    cap_t[k] <= cnt;                     // ★ 抓的是**本拍**计数值
                    cap_v[k] <= 1'b1;
                end else if (sel_v && (sel_idx == k[MW-1:0])) begin
                    cap_v[k] <= 1'b0;                    // 已被取走
                end
            end
        end
    end

    // ★ 判据必须是"上一戳**没被取走**"，不能只看 cap_v[k]：
    //   若新样本恰好在旧样本被仲裁取走的同一拍到达，旧样本进了 FIFO，没丢东西。
    //   早先写成 `s_valid[k] && cap_v[k]` 会把这种情况误报成丢样本
    //   （由 model/ts_model.py 的自检抓出）。
    always @(posedge clk) begin
        if (!rst_n || fifo_rst) begin
            ovf <= {NW{1'b0}};
        end else begin
            for (k = 0; k < NW; k = k + 1) begin
                if (s_valid[k] && cap_v[k] && !(sel_v && (sel_idx == k[MW-1:0])))
                                                 ovf[k] <= 1'b1;  // (a) 上一戳未取走
                else if (sel_v && (sel_idx == k[MW-1:0]) && full)
                                                 ovf[k] <= 1'b1;  // (b) 队列满，丢弃
                else if (ovf_clr[k])             ovf[k] <= 1'b0;
            end
        end
    end

    // ------------------------------------------------------------------ 轮转指针
    always @(posedge clk) begin
        if (!rst_n || fifo_rst) rr_ptr <= {MW{1'b0}};
        else if (push)          rr_ptr <= sel_idx + 1'b1;
    end

    // ------------------------------------------------------------------ 打戳计数
    always @(posedge clk) begin
        if (!rst_n || fifo_rst)              enq_count <= 32'd0;
        else if (push && !full)              enq_count <= enq_count + 32'd1;
    end

endmodule

`default_nettype wire
