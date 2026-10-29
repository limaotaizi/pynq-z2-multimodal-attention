`timescale 1ns / 1ps
`default_nettype none
// =============================================================================
// tau_comp.v —— τ 补偿单元（方案三 §3.2）
//
//       t_m = t − τ_m        τ_m 为每模态一个 32-bit 寄存器，AXI-Lite 可写
//
//   ★ 这是方案三相对 R2GFANet 唯一的**实质结构差异**。
//     R2GFANet 的"位置编码"只有槽位索引 ⇒ τ 恒等于 0；这里每路有一个独立
//     可写的偏移，于是 τ 可以对已经采进来的数据**在线扫描**（§5 的 τ 扫描实验）。
//
//   语义：
//     · 减法在 2^TW 模下回绕（计数器本来就回绕，保持一致）
//     · t_in < τ 时置该路 underflow 粘滞位 —— 这只说明 τ 设过了头
//       （比计数器当前值还大），不是错误，但必须能看见，否则会静默给出垃圾 t_m
//     · τ 寄存器由外部（AXI）维护，本模块只读
// =============================================================================
module tau_comp #(
    parameter integer TW  = 48,
    parameter integer NW  = 4,
    parameter integer TAW = 32
)(
    input  wire                  clk,
    input  wire                  rst_n,

    input  wire                  valid_in,
    input  wire [$clog2(NW)-1:0] mod_in,
    input  wire [TW-1:0]         t_in,

    input  wire [NW*TAW-1:0]     tau_flat,     // 每路一个 τ，扁平化传入
    input  wire [NW-1:0]         uf_clr,       // 写 1 清该路 underflow 粘滞

    output reg                   valid_out,
    output reg  [$clog2(NW)-1:0] mod_out,
    output reg  [TW-1:0]         t_out,
    output reg  [NW-1:0]         uf_sticky
);
    // ★ 两级流水（2026-10-18）。原实现把「仲裁 → τ 选择 → 48 位减法/比较」
    //   全压在一拍里，布局后实测 5.692 ns（WNS = -0.803 ns，50 个端点违例），
    //   最差路径是 cap_v_reg[2] → u_tau/uf_sticky_reg[*]。
    //   现在第一级只锁存事件与它那一路的 τ（cap_v → 仲裁 → τ 多路器），
    //   第二级再做减法/比较（纯 CARRY4，源是寄存器）。
    //   代价：valid_out / t_out 相对 valid_in 的延迟由 1 拍变 2 拍；
    //   model/ts_model.py 的 TSUnit 已同步。τ 寄存器本身仍只读。
    reg                  s1_valid;
    reg [$clog2(NW)-1:0] s1_mod;
    reg [TW-1:0]         s1_t;
    reg [TAW-1:0]        s1_tau;

    wire [TW-1:0] tau_ext = {{(TW-TAW){1'b0}}, s1_tau};
    wire          uf      = (s1_t < tau_ext);

    always @(posedge clk) begin
        if (!rst_n) begin
            s1_valid  <= 1'b0;
            s1_mod    <= {$clog2(NW){1'b0}};
            s1_t      <= {TW{1'b0}};
            s1_tau    <= {TAW{1'b0}};
            valid_out <= 1'b0;
            mod_out   <= {$clog2(NW){1'b0}};
            t_out     <= {TW{1'b0}};
            uf_sticky <= {NW{1'b0}};
        end else begin
            // ---- stage 1: 锁存事件 + 该路 τ ----
            s1_valid <= valid_in;
            if (valid_in) begin
                s1_mod <= mod_in;
                s1_t   <= t_in;
                s1_tau <= tau_flat[mod_in*TAW +: TAW];
            end

            // ---- stage 2: 补偿 ----
            valid_out <= s1_valid;
            if (s1_valid) begin
                mod_out <= s1_mod;
                t_out   <= s1_t - tau_ext;      // 2^TW 模回绕
                if (uf) uf_sticky[s1_mod] <= 1'b1;
            end
            if (|uf_clr) uf_sticky <= uf_sticky & ~uf_clr;
        end
    end

endmodule

`default_nettype wire
