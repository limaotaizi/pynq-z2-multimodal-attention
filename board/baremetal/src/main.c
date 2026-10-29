/* ============================================================================
 * main.c -- M=4 三从机整机（e+o+a+s，带 ε）的**裸机**验收程序
 *
 *   与板端 Python 路径（board_dump4.py + attn_driver.py）走的是同一套协议：
 *     装载 1,636 字 → 写 CTRL.START → 轮询 STATUS.done → 读回 28 个数组。
 *   判据也是同一条：28 数组 / 5,504 字逐位等于 xsim 的金标准。
 *   金标准来自 golden_m4.h，由 gen_golden.py 从 attn_vectors4.npz 生成。
 *
 *   本程序**不需要宿主**：BOOT.BIN 由 FSBL 加载并自动配置 PL，
 *   上电后自己跑、自己在串口上打印结论。
 *
 *   引擎验完之后接着跑模块③④（`head_m4.c`，纯 C）：从 scratch 读回四路 Zp，
 *   在板上算出 3 类 logits / 概率 / 类别，并与 Python 路径（`_board/ps_head.py`）
 *   的参考值比对。到这一步，"端侧独立运行"才是端到端——不再需要一台机器跑 Python。
 *
 *   串口命令（PS UART0，115200 8N1，PYNQ-Z2 的 micro-USB 那个口）：
 *     r   再跑一次（装载 + 引擎 + 逐位比对 + 模块③④）
 *     h   只重跑模块③④（读 scratch 里上一次的 Zp）
 *     t   只测一窗的生产路径耗时（装载 + 引擎 + 读 Zp + ③④，不含回读比对）
 *     R   连续跑引擎（装载一次，之后反复 START），用于测 S2「引擎满载」功耗
 *     f   读一次 FCLK_CLK0 与 FCLK0_CTRL
 *     q   从连续模式退出，回到空闲
 *     其它 忽略
 *
 *   时钟：FSBL 按 BD 的配置把 FCLK_CLK0 点起来（本设计的 BD 里 IO PLL
 *   1000 MHz、DIVISOR0 = 5 ⇒ **200 MHz**）。但这份位流只在 100 MHz 通过
 *   时序（整机 200 MHz 时 WNS −0.736 ns），所以本程序先把 FSBL 配出来的
 *   频率打印留证，再把 DIVISOR0 改成 10 钉到 100 MHz，之后的计时与判据
 *   全部基于 100 MHz。判据用引擎**拍数**（时钟无关），毫秒只作参考。
 *
 *   寄存器映射以 work2/rtl/attn_axi.v 为准：
 *     0x0000 CTRL   W  bit0 = START（one shot，busy 期间忽略）
 *     0x0004 STATUS R  bit0 = busy，bit1 = done（sticky）
 *     0x0008 ID     R  0x4154_0001
 *     0x000C CLR    W  bit0 = 清 sticky done
 *     0x0100..      RW scratch，8192×16 bit，一个 32 bit beat 装两个字：
 *                      beat W 的 [15:0]   -> scratch[2W]
 *                      beat W 的 [31:16]  -> scratch[2W+1]
 *
 *   地址：attn_axi @0x4000_0000，ts_top @0x4001_0000（BD 三从机译码）。
 *   两个基址都从 xparameters.h 取，取不到才回落到字面量。
 * ==========================================================================*/

#include <stdint.h>
#include <math.h>

#include "xparameters.h"
#include "xil_io.h"
#include "xil_printf.h"
#include "xil_cache.h"
#include "xtime_l.h"
#include "xuartps.h"

#include "golden_m4.h"
#include "head_m4.h"
#include "head_m4_gold.h"

/* ---------------------------------------------------------------- 地址 */
#ifndef XPAR_ATTN_AXI_0_BASEADDR
#define XPAR_ATTN_AXI_0_BASEADDR 0x40000000u
#endif
#ifndef XPAR_TS_TOP_0_BASEADDR
#define XPAR_TS_TOP_0_BASEADDR   0x40010000u
#endif
#ifndef XPAR_XUARTPS_0_BASEADDR
#define XPAR_XUARTPS_0_BASEADDR  0xE0000000u
#endif

#define ATTN_BASE   ((u32)XPAR_ATTN_AXI_0_BASEADDR)
#define TS_BASE     ((u32)XPAR_TS_TOP_0_BASEADDR)
#define UART_BASE   ((u32)XPAR_XUARTPS_0_BASEADDR)

/* 编译期校核：BD 的译码是三段 0x4000_0000 / 0x4001_0000 / 0x4002_0000，
   地址错了会读到一个不存在的从机、总线直接挂死，所以这里写死两个断言。 */
typedef char attn_base_must_be_0x40000000[((ATTN_BASE == 0x40000000u) ? 1 : -1)];
typedef char ts_base_must_be_0x40010000[((TS_BASE == 0x40010000u) ? 1 : -1)];

/* ---------------------------------------------------------------- 寄存器 */
#define A_CTRL   0x0000u
#define A_STAT   0x0004u
#define A_ID     0x0008u
#define A_CLR    0x000Cu
#define A_DATA   0x0100u
#define A_ID_VAL 0x41540001u

#define T_CTRL   0x00u          /* bit0 = RUN，自由计数器总开关 */
#define T_TNOW_L 0x08u
#define T_TNOW_H 0x0Cu

#define SCRATCH_WORDS 8192

/* ---------------------------------------------------------------- PS 时钟 */
/* FCLK_CLK0 的分频寄存器 = FPGA0_CLK_CTRL @ 0xF8000170，字段：
 *   [0]    CLKACT（复位值 1，不要去动）
 *   [5:4]  SRCSEL（0 = IO PLL）
 *   [13:8] DIVISOR0
 *   [25:20] DIVISOR1
 * 这三条不是照 TRM 背的，是从本工程 XSA 里的 ps7_init.c 读出来的原话：
 *   EMIT_MASKWRITE(0XF8000170, 0x03F03F30U, 0x00100500U)   DIVISOR0=5 DIVISOR1=1
 * 也就是说 FSBL 配的是 IO PLL 1000 / 5 / 1 = **200 MHz**。
 *
 * 两个必须知道的坑：
 *  1. 地址不是 0xF8000148 —— 那是 SMC_CLK_CTRL。写错地址不会报错，只是白写。
 *  2. SLCR 有写保护，动任何 SLCR 寄存器之前先往 SLCR_UNLOCK 写 0xDF0D，
 *     完之后往 SLCR_LOCK 写 0x767B。不解锁的写会被**静默丢弃**，
 *     回读还是老值——第一次改时钟就是这么"成功"地什么都没做的。
 *
 * 为什么要改：这份位流只在 100 MHz 通过时序（整机 200 MHz 时 WNS −0.736 ns）。
 * FSBL 按 BD 的 200 MHz 把 PL 点起来了，跑出来的 10.39 ms 是"200 MHz 且没签核"
 * 的数，不能进报告口径。 */
#define FCLK0_CTRL    0xF8000170u
#define SLCR_UNLOCK   0xF8000008u
#define SLCR_LOCK     0xF8000004u
#define SLCR_UNLOCK_KEY 0xDF0Du
#define SLCR_LOCK_KEY   0x767Bu

#define FCLK0_DIV0_SHIFT   8
#define FCLK0_DIV0_MASK    0x00003F00u
#define FCLK0_DIV1_SHIFT   20
#define FCLK0_DIV1_MASK    0x03F00000u
#define FCLK0_SRCSEL_MASK  0x00000030u

/* 引擎拍数（xsim 实测，AXI 包装不改变它）。拍数与时钟无关，是真正的位流指纹。 */
#define ENG_MS_X100   ((int)((G_ENGINE_CYCLES * 100ULL) / 100000ULL))  /* 2079 @100MHz */

/* 应用把 FCLK_CLK0 拉到的目标频率（MHz×100）。 */
#define FCLK_TARGET_X100 10000u

static u32 g_fclk_x100;         /* 实测 FCLK_CLK0，MHz×100；0 = 没测出来 */

/* ---------------------------------------------------------------- 小工具 */
static u64 now_ticks(void)
{
        XTime t;
        XTime_GetTime(&t);
        return (u64)t;
}

/* 把 tick 差换成 ms*100 的整数，避免浮点（xil_printf 不支持 %f） */
static u32 ticks_to_ms_x100(u64 d)
{
        return (u32)((d * 100000ULL) / (u64)COUNTS_PER_SECOND);
}

static void sleep_ms(u32 ms)
{
        u64 t0 = now_ticks();
        u64 d = ((u64)ms * (u64)COUNTS_PER_SECOND) / 1000ULL;
        while (now_ticks() - t0 < d) {
                /* spin */
        }
}

/* ---- UART ----------------------------------------------------------------
   显式把波特率再设一遍。FSBL 已经设过 115200，但这里不依赖它：
   BAUDGEN 是复位后软件写的，FSBL 一旦改了口径，本程序就会一句话也说不出来，
   而且那种失败看起来和"板子没起来"一模一样。
   顺便把驱动实例初始化好，接收侧才有 FIFO/状态可查。 */
static XUartPs uart_inst;
static int    uart_ready;

static void uart_setup(void)
{
        XUartPs_Config *cfg;

        uart_ready = 0;
        cfg = XUartPs_LookupConfig(XPAR_XUARTPS_0_DEVICE_ID);
        if (cfg == NULL) {
                return;
        }
        if (XUartPs_CfgInitialize(&uart_inst, cfg, cfg->BaseAddress) != XST_SUCCESS) {
                return;
        }
        (void)XUartPs_SetBaudRate(&uart_inst, 115200u);
        XUartPs_SetOperMode(&uart_inst, XUARTPS_OPER_MODE_NORMAL);
        uart_ready = 1;
}

static int uart_getc(void)
{
        if (!uart_ready) {
                return -1;
        }
        if (!XUartPs_IsReceiveData(UART_BASE)) {
                return -1;
        }
        return (int)(XUartPs_RecvByte(UART_BASE) & 0xFFu);
}

/* ---------------------------------------------------------------- scratch */
/* 装载 n 个字到 scratch，从字 0 开始（与 attn_driver.write_words(0, ...) 同一条线）。
   一个 32 bit beat 装两个字，最后一个字为奇时低半有效、高半写 0。 */
static void load_input(const int16_t *w, int n)
{
        int i;
        for (i = 0; i + 1 < n; i += 2) {
                u32 d = ((u32)(u16)w[i] & 0xFFFFu)
                      | (((u32)(u16)w[i + 1] & 0xFFFFu) << 16);
                Xil_Out32(ATTN_BASE + A_DATA + 4u * (u32)(i >> 1), d);
        }
        /* 读回最后一个 beat：AXI 上读不会被重排到先前的写之前，
           这一步同时充当"写已经进了 PL"的栅栏和一次回读核对。 */
        (void)Xil_In32(ATTN_BASE + A_DATA + 4u * (u32)((n - 1) >> 1));
}

/* 读 n 个字，字索引从 base_word 开始。一个 beat 读一次，两个字用一次。 */
static void read_words(u32 base_word, int n, int16_t *out)
{
        int b0 = (int)(base_word >> 1);
        int b1 = (int)((base_word + (u32)n - 1) >> 1);
        int b, i = 0;
        for (b = b0; b <= b1; ++b) {
                u32 d = Xil_In32(ATTN_BASE + A_DATA + 4u * (u32)b);
                int w0 = b << 1;
                if (w0 >= (int)base_word && i < n) {
                        out[i++] = (int16_t)(d & 0xFFFFu);
                }
                if (w0 + 1 >= (int)base_word && i < n) {
                        out[i++] = (int16_t)(d >> 16);
                }
        }
}

/* ---------------------------------------------------------------- 引擎 */
static void engine_clear_done(void)
{
        Xil_Out32(ATTN_BASE + A_CLR, 1u);
}

static int engine_wait_done(u32 timeout_ms)
{
        u64 t0 = now_ticks();
        u64 lim = ((u64)timeout_ms * (u64)COUNTS_PER_SECOND) / 1000ULL;
        while (now_ticks() - t0 < lim) {
                if (Xil_In32(ATTN_BASE + A_STAT) & 2u) {
                        return 0;
                }
        }
        return -1;
}

/* 一次完整推理。返回引擎耗时（ms*100），失败返回 -1。 */
static int engine_run_once(u32 *ms_x100)
{
        u64 t0;
        u32 dt;

        engine_clear_done();
        load_input(G_IN_Q, G_N_IN);

        t0 = now_ticks();
        Xil_Out32(ATTN_BASE + A_CTRL, 1u);
        if (engine_wait_done(2000u) != 0) {
                return -1;
        }
        dt = ticks_to_ms_x100(now_ticks() - t0);
        *ms_x100 = dt;
        return 0;
}

/* ---------------------------------------------------------------- FCLK */
/* 用 ts_top 的自由计数器量 FCLK_CLK0：计数器每个 PL 时钟加一，
   所以 FCLK = Δcounts / Δt。这是一次独立于 BD 声明的实测。
   48 bit 计数器，低 32 bit 每 42.9 s 回绕一次，读的时候做一次防撕裂。 */
static u32 measure_fclk_mhz_x100(void)
{
        u32 l0, h0, l0b, l1, h1, l1b;
        u64 c0, c1, x0, x1, dc;

        Xil_Out32(TS_BASE + T_CTRL, 1u);        /* RUN */

        h0 = Xil_In32(TS_BASE + T_TNOW_H);
        l0 = Xil_In32(TS_BASE + T_TNOW_L);
        l0b = Xil_In32(TS_BASE + T_TNOW_L);
        if (l0b < l0) {                         /* 正好在回绕处，重读 */
                h0 = Xil_In32(TS_BASE + T_TNOW_H);
                l0 = Xil_In32(TS_BASE + T_TNOW_L);
        }
        x0 = now_ticks();

        sleep_ms(200u);

        h1 = Xil_In32(TS_BASE + T_TNOW_H);
        l1 = Xil_In32(TS_BASE + T_TNOW_L);
        l1b = Xil_In32(TS_BASE + T_TNOW_L);
        if (l1b < l1) {
                h1 = Xil_In32(TS_BASE + T_TNOW_H);
                l1 = Xil_In32(TS_BASE + T_TNOW_L);
        }
        x1 = now_ticks();

        c0 = (((u64)h0 & 0xFFFFu) << 32) | (u64)l0;
        c1 = (((u64)h1 & 0xFFFFu) << 32) | (u64)l1;
        if (c1 <= c0 || x1 <= x0) {
                return 0;                       /* 计数器没动：算不出来 */
        }
        dc = c1 - c0;

        /* fclk[Hz] = dc / dt[s]，而 dt[s] = (x1-x0) / COUNTS_PER_SECOND。
           要的是 MHz×100，所以再乘 100 除 1e6。
           第一版漏了那个 1e6，返回值其实是 Hz×100，200 MHz 时是 2e10，
           超出 u32 回绕成 2,820,131,392，打印出来是"28201313.92 MHz"。
           那个回绕值本身就等于 4×2^32 + 2,820,131,392 ≈ 2.0e10，反推正好 200 MHz。 */
        return (u32)((dc * (u64)COUNTS_PER_SECOND * 100ULL)
                     / ((x1 - x0) * 1000000ULL));
}

/* ---------------------------------------------------------------- 时钟设定 */
/* 把 FCLK_CLK0 的 DIVISOR0 改成 1000 MHz / mhz（DIVISOR1 保持 1）。
   只清 [13:8]，SRCSEL / DIVISOR1 / CLKACT 原样保留。
   **必须在引擎空闲时做**：改分频的瞬间 PL 侧时钟会变，正在跑的引擎会丢状态。 */
static u32 fclk0_div_for_mhz(u32 mhz)
{
        u32 div;

        if (mhz == 0u) {
                return 0u;
        }
        div = 1000u / mhz;              /* IO PLL = 1000 MHz */
        if (div < 1u)  { div = 1u; }
        if (div > 63u) { div = 63u; }
        return div;
}

static int set_fclk0_mhz(u32 mhz)
{
        u32 v, div;

        div = fclk0_div_for_mhz(mhz);
        if (div == 0u || (1000u % mhz) != 0u) {
                return -1;              /* 1000 MHz 除不尽，不做 */
        }

        Xil_Out32(SLCR_UNLOCK, SLCR_UNLOCK_KEY);
        v = Xil_In32(FCLK0_CTRL);
        v &= ~FCLK0_DIV0_MASK;
        v |= (div << FCLK0_DIV0_SHIFT) & FCLK0_DIV0_MASK;
        v &= ~FCLK0_SRCSEL_MASK;        /* SRCSEL = 0，IO PLL */
        Xil_Out32(FCLK0_CTRL, v);
        Xil_Out32(SLCR_LOCK, SLCR_LOCK_KEY);

        /* 等新分频彻底生效再量 */
        sleep_ms(50u);
        return 0;
}

/* 从 FCLK0_CTRL 的读回值里取 DIVISOR0 / DIVISOR1 */
static u32 fclk0_div0_reg(void) { return (Xil_In32(FCLK0_CTRL) & FCLK0_DIV0_MASK) >> FCLK0_DIV0_SHIFT; }
static u32 fclk0_div1_reg(void) { return (Xil_In32(FCLK0_CTRL) & FCLK0_DIV1_MASK) >> FCLK0_DIV1_SHIFT; }

/* 引擎拍数换算成"该时钟下的 ms×100"：ms×100 = cycles × 10 / fclk_x100 */
static u32 eng_ms_x100_at(u32 fclk_x100)
{
        if (fclk_x100 == 0u) {
                return (u32)ENG_MS_X100;
        }
        return (u32)(((u64)G_ENGINE_CYCLES * 10ULL) / (u64)fclk_x100);
}

/* 反向：由实测 ms 和实测时钟反推引擎拍数——时钟无关的位流指纹 */
static u32 ms_x100_to_cycles(u32 ms_x100, u32 fclk_x100)
{
        if (fclk_x100 == 0u) {
                return 0u;
        }
        return (u32)(((u64)ms_x100 * (u64)fclk_x100) / 10ULL);
}

/* ---------------------------------------------------------------- 逐位比对 */
static int16_t rd_buf[1024];

static int check_all(void)
{
        int a, i, bad_arrays = 0, total = 0, ok_total = 0;

        for (a = 0; a < G_N_ARRAYS; ++a) {
                const g_array_t *g = &G_ARRAYS[a];
                int ok = 0, bad = 0, first_bad = -1;
                u16 got0 = 0, exp0 = 0;

                read_words(g->base, (int)g->n, rd_buf);
                for (i = 0; i < (int)g->n; ++i) {
                        u16 e = (u16)g->exp[i];
                        u16 v = (u16)rd_buf[i];
                        if (e == v) {
                                ++ok;
                        } else {
                                ++bad;
                                if (first_bad < 0) {
                                        first_bad = i;
                                        got0 = v;
                                        exp0 = e;
                                }
                        }
                }
                total += (int)g->n;
                ok_total += ok;
                if (bad == 0) {
                        xil_printf("  [ok  ] %-4s %4d/%4d\r\n",
                                   g->name, ok, (int)g->n);
                } else {
                        ++bad_arrays;
                        xil_printf("  [FAIL] %-4s %4d/%4d  first@%d got=%04X exp=%04X\r\n",
                                   g->name, ok, (int)g->n, first_bad,
                                   (unsigned)got0, (unsigned)exp0);
                }
        }
        xil_printf("  ----------------------------------------------\r\n");
        if (bad_arrays == 0) {
                xil_printf("  TOTAL %d/%d words, %d arrays  =>  ALL PASS\r\n",
                           ok_total, total, G_N_ARRAYS);
        } else {
                xil_printf("  TOTAL %d/%d words, %d/%d arrays FAILED\r\n",
                           ok_total, total, bad_arrays, G_N_ARRAYS);
        }
        return bad_arrays;
}

/* ---------------------------------------------------------------- 模块③④ */
/* 引擎交出来的 Zp 在 scratch 里，每模态 G*D = 256 字（INT16 + 全局 act）。
   这里把四个数组读回来，交给 head_m4.c 在板上算完三类概率。 */
static const char *const ZP_NAME[HEAD_M] = { "zpe", "zpo", "zpa", "zps" };
static int16_t zp_buf[HEAD_M][HEAD_G * HEAD_D];

/* 名字在 golden_m4.h 里是 "%-4s" 打的，短名后面**有空格**（"zpe "、"zpo "），
   所以比较时把尾随空格当结束符，别要求两边同时 '\0'。 */
static const g_array_t *find_array(const char *name)
{
        int a, i;

        for (a = 0; a < G_N_ARRAYS; ++a) {
                const char *p = G_ARRAYS[a].name;
                for (i = 0; name[i] != '\0'; ++i) {
                        if (p[i] != name[i]) {
                                break;
                        }
                }
                if (name[i] == '\0' && (p[i] == '\0' || p[i] == ' ')) {
                        return &G_ARRAYS[a];
                }
        }
        return 0;
}

/* xil_printf 没有 %f，浮点一律手打。固定 3 位小数，带符号。 */
static void print_f3(float v)
{
        int neg = (v < 0.0f);
        float a = neg ? -v : v;
        u32 q = (u32)(a * 1000.0f + 0.5f);

        if (neg && q != 0u) {
                xil_printf("-");
        } else {
                xil_printf("+");
        }
        xil_printf("%u.%03u", (unsigned)(q / 1000u), (unsigned)(q % 1000u));
}

/* 一行：logits 与概率，最后给类别。
   q 是概率的**万分位**整数（prob*10000），打印时再拆成 "q/100 . q%100"，
   即两位小数的百分数。早先误按 prob*100 取整、仍按 q/100 拆，
   0.4936 会打成 0.49%，整数位小数位都错了一位。 */
static void print_cls_line(const char *tag, const float *logits,
                           const float *prob, int cls)
{
        int c;

        xil_printf("  %s logits", tag);
        for (c = 0; c < HEAD_NCLS; ++c) {
                xil_printf(" ");
                print_f3(logits[c]);
        }
        xil_printf("   prob");
        for (c = 0; c < HEAD_NCLS; ++c) {
                u32 q = (u32)(prob[c] * 10000.0f + 0.5f);
                xil_printf(" %3u.%02u%%", (unsigned)(q / 100u), (unsigned)(q % 100u));
        }
        xil_printf("   class %d\r\n", cls);
}

static u32 ticks_to_us(u64 d)
{
        return (u32)((d * 1000000ULL) / (u64)COUNTS_PER_SECOND);
}

/* 读 Zp、跑模块③④、打印、对参考值。返回 0 = 与 Python 路径一致。 */
static int report_head(void)
{
        const int16_t *p[HEAD_M];
        float logits[HEAD_NCLS], prob[HEAD_NCLS];
        u64 t0;
        u32 us;
        float dmax = 0.0f;
        int m, c, cls, bad = 0;

        for (m = 0; m < HEAD_M; ++m) {
                const g_array_t *g = find_array(ZP_NAME[m]);
                if (g == 0 || (int)g->n != HEAD_G * HEAD_D) {
                        xil_printf("  HEAD: cannot find %s in the array map\r\n",
                                   ZP_NAME[m]);
                        return -1;
                }
                read_words(g->base, (int)g->n, zp_buf[m]);
                p[m] = zp_buf[m];
        }

        t0 = now_ticks();
        head_forward(p, HEAD_ACT, logits, prob, &cls);
        us = ticks_to_us(now_ticks() - t0);

        print_cls_line("HEAD", logits, prob, cls);
        xil_printf("  HEAD %u.%03u ms on the A9 (pure C, no host;"
                   " act = %u e-6)\r\n",
                   (unsigned)(us / 1000u), (unsigned)(us % 1000u),
                   (unsigned)((u32)(HEAD_ACT * 1000000.0f + 0.5f)));

        for (c = 0; c < HEAD_NCLS; ++c) {
                float d = logits[c] - HEAD_GOLD_LOGITS[c];
                if (d < 0.0f) {
                        d = -d;
                }
                if (d > dmax) {
                        dmax = d;
                }
        }
        xil_printf("  HEAD vs Python reference: max|dlogit| = %u.%03u (tol %u.%03u)",
                   (unsigned)((u32)(dmax * 1000.0f) / 1000u),
                   (unsigned)((u32)(dmax * 1000.0f) % 1000u),
                   (unsigned)((u32)(HEAD_TOL_LOGIT * 1000.0f) / 1000u),
                   (unsigned)((u32)(HEAD_TOL_LOGIT * 1000.0f) % 1000u));
        if (dmax > HEAD_TOL_LOGIT) {
                xil_printf("  FAIL\r\n");
                bad = 1;
        } else if (cls != HEAD_GOLD_CLASS) {
                xil_printf("  FAIL (class %d != %d)\r\n", cls, HEAD_GOLD_CLASS);
                bad = 1;
        } else {
                xil_printf("  OK\r\n");
        }
        return bad;
}

/* ---------------------------------------------------------------- 子流程 */
/* 计时指纹。判据用**拍数**而不是毫秒：拍数与时钟无关，是位流的真指纹。
   M=2 / M=3 / M=4 的拍数分别约 466k / 1133k / 2079k，互不重叠。
   毫秒只作参考，且按实测时钟换算，换到 200 MHz 也不会误报。 */
static void report_engine_time(u32 ms_x100)
{
        u32 fclk = g_fclk_x100;
        u32 cyc  = ms_x100_to_cycles(ms_x100, fclk);
        u32 exp  = eng_ms_x100_at(fclk);
        u32 lo   = (u32)((u64)G_ENGINE_CYCLES * 97ULL / 100ULL);
        u32 hi   = (u32)((u64)G_ENGINE_CYCLES * 103ULL / 100ULL);

        if (fclk == 0u) {
                xil_printf("  engine %d.%02d ms   (clock unknown, cannot check cycles)\r\n",
                           ms_x100 / 100, ms_x100 % 100);
                return;
        }
        xil_printf("  engine %d.%02d ms  = %u cycles @ %u.%02u MHz"
                   "   (M=4 expects %u / %d.%02d ms)\r\n",
                   ms_x100 / 100, ms_x100 % 100,
                   (unsigned)cyc,
                   (unsigned)(fclk / 100U), (unsigned)(fclk % 100U),
                   (unsigned)G_ENGINE_CYCLES, exp / 100, exp % 100);
        if (cyc < lo || cyc > hi) {
                xil_printf("  *** WARNING: %u cycles is not the M=4 engine"
                           " (%u +-3%%) -- wrong bitstream or empty IROM ***\r\n",
                           (unsigned)cyc, (unsigned)G_ENGINE_CYCLES);
        }
}

/* 生产路径的端到端计时：装载输入 -> 引擎 -> 读回 Zp -> 模块③④。
 * 这四段才是每 4 s 一窗真跑的东西；do_one_run 里那个 5,504 字的回读比对
 * 是验收动作，不属于生产路径，所以这里单独测一遍，不把它算进去。
 * 跑的时候权重已经在 cache 里（前面 report_head 走过一遍），这正是稳态。 */
static void report_window_latency(void)
{
        const int16_t *p[HEAD_M];
        float logits[HEAD_NCLS], prob[HEAD_NCLS];
        u64 t_all, t0, t1;
        u32 us_load, us_eng, us_zp, us_head, us;
        int m, cls;

        xil_printf("\r\n-- window latency: production path only (no readback check) --\r\n");

        t_all = now_ticks();

        t0 = now_ticks();
        load_input(G_IN_Q, G_N_IN);
        t1 = now_ticks();
        us_load = ticks_to_us(t1 - t0);

        engine_clear_done();
        t0 = now_ticks();
        Xil_Out32(ATTN_BASE + A_CTRL, 1u);
        if (engine_wait_done(2000u) != 0) {
                xil_printf("  FAIL: done never asserted, STATUS = 0x%08X\r\n",
                           (unsigned)Xil_In32(ATTN_BASE + A_STAT));
                return;
        }
        t1 = now_ticks();
        us_eng = ticks_to_us(t1 - t0);

        t0 = now_ticks();
        for (m = 0; m < HEAD_M; ++m) {
                const g_array_t *g = find_array(ZP_NAME[m]);
                if (g == 0 || (int)g->n != HEAD_G * HEAD_D) {
                        xil_printf("  FAIL: cannot find %s\r\n", ZP_NAME[m]);
                        return;
                }
                read_words(g->base, (int)g->n, zp_buf[m]);
                p[m] = zp_buf[m];
        }
        t1 = now_ticks();
        us_zp = ticks_to_us(t1 - t0);

        t0 = now_ticks();
        head_forward(p, HEAD_ACT, logits, prob, &cls);
        t1 = now_ticks();
        us_head = ticks_to_us(t1 - t0);

        us = ticks_to_us(t1 - t_all);

        xil_printf("  load    %4d words (AXI)   %u.%03u ms\r\n",
                   G_N_IN, (unsigned)(us_load / 1000u), (unsigned)(us_load % 1000u));
        xil_printf("  engine                     %u.%03u ms\r\n",
                   (unsigned)(us_eng / 1000u), (unsigned)(us_eng % 1000u));
        xil_printf("  read Zp %4d words (AXI)   %u.%03u ms\r\n",
                   HEAD_M * HEAD_G * HEAD_D,
                   (unsigned)(us_zp / 1000u), (unsigned)(us_zp % 1000u));
        xil_printf("  head -> 3 classes          %u.%03u ms\r\n",
                   (unsigned)(us_head / 1000u), (unsigned)(us_head % 1000u));
        xil_printf("  ------------------------------------------\r\n");
        xil_printf("  one window on the A9       %u.%03u ms"
                   "   (class %d)\r\n",
                   (unsigned)(us / 1000u), (unsigned)(us % 1000u), cls);
}

static int do_one_run(void)
{
        u32 ms = 0;
        int bad;

        xil_printf("\r\n-- run 1 window: load %d words, start, poll --\r\n", G_N_IN);
        if (engine_run_once(&ms) != 0) {
                xil_printf("  FAIL: done never asserted, STATUS = 0x%08X\r\n",
                           (unsigned)Xil_In32(ATTN_BASE + A_STAT));
                return -1;
        }
        report_engine_time(ms);
        bad = check_all();

        /* 引擎的 28 个数组都对上之后，Zp 就是可信的输入，接着在板上算 ③④。
           引擎不对时照样跑：这时候 ③④ 的数没有意义，但能让串口上看到
           "哪一段开始不对"，比直接跳过更有用。 */
        if (report_head() != 0) {
                bad = (bad != 0) ? bad : 1;
        }
        /* 四段都是纯生产动作，验收用的回读比对不计入。 */
        report_window_latency();
        return bad;
}

/* 连续跑引擎：装载一次，之后只 START/等 done。
   宿主侧几乎不参与 ⇒ 引擎占空比接近 100%，这是测 S2 用的状态。 */
static void run_continuous(void)
{
        u32 n = 0;
        u32 stat;

        xil_printf("\r\n-- continuous mode (engine ~99.9%% busy). 'q' to stop --\r\n");
        engine_clear_done();
        load_input(G_IN_Q, G_N_IN);
        for (;;) {
                int c;
                engine_clear_done();
                Xil_Out32(ATTN_BASE + A_CTRL, 1u);
                if (engine_wait_done(2000u) != 0) {
                        xil_printf("  FAIL: done never asserted in continuous mode\r\n");
                        return;
                }
                ++n;
                if ((n % 100u) == 0u) {
                        stat = Xil_In32(ATTN_BASE + A_STAT);
                        xil_printf("  %9u windows, STATUS = 0x%08X\r\n",
                                   (unsigned)n, (unsigned)stat);
                }
                c = uart_getc();
                if (c == 'q' || c == 'Q') {
                        break;
                }
        }
        engine_clear_done();
        xil_printf("  continuous mode stopped after %u windows\r\n", (unsigned)n);
}

/* ---------------------------------------------------------------- main */
int main(void)
{
        u32 id, fclk;
        int bad;

        Xil_DCacheDisable();
        uart_setup();

        xil_printf("\r\n");
        xil_printf("================================================\r\n");
        xil_printf(" attn_m4 bare-metal acceptance  (no host)\r\n");
        xil_printf(" 4 modalities e+o+a+s, M=4 engine, eps regs\r\n");
        xil_printf("================================================\r\n");

        id = Xil_In32(ATTN_BASE + A_ID);
        xil_printf("  attn_axi ID = 0x%08X  (expect 0x%08X) %s\r\n",
                   (unsigned)id, (unsigned)A_ID_VAL,
                   (id == A_ID_VAL) ? "ok" : "MISMATCH");
        if (id != A_ID_VAL) {
                xil_printf("  PL is not configured, or the bitstream is not this design."
                           "  Halting.\r\n");
                while (1) {
                        sleep_ms(1000u);
                }
        }

        /* 先量 FSBL 配出来的那个频率——这是证据，不覆盖。 */
        fclk = measure_fclk_mhz_x100();
        if (fclk != 0u) {
                xil_printf("  FCLK_CLK0   = %u.%02u MHz  as configured by FSBL"
                           "  (ts_top counter vs global timer)\r\n",
                           (unsigned)(fclk / 100U), (unsigned)(fclk % 100U));
        } else {
                xil_printf("  FCLK_CLK0   = ?  (ts_top counter did not move)\r\n");
        }
        xil_printf("  FCLK0_CTRL  = 0x%08X  (div0 = %u, div1 = %u, src = %u)\r\n",
                   (unsigned)Xil_In32(FCLK0_CTRL),
                   (unsigned)fclk0_div0_reg(), (unsigned)fclk0_div1_reg(),
                   (unsigned)((Xil_In32(FCLK0_CTRL) & FCLK0_SRCSEL_MASK) >> 4));

        /* 把时钟钉到 100 MHz——那份位流只在这个频率上通过了时序。
           跑到别的频率上，结果不作数（200 MHz 整机 WNS −0.736 ns）。 */
        if (fclk != FCLK_TARGET_X100) {
                xil_printf("  -> setting FCLK_CLK0 to %u.%02u MHz (timing-signed-off point)\r\n",
                           (unsigned)(FCLK_TARGET_X100 / 100U),
                           (unsigned)(FCLK_TARGET_X100 % 100U));
                if (set_fclk0_mhz(FCLK_TARGET_X100 / 100U) != 0) {
                        xil_printf("  *** set_fclk0 rejected (1000 MHz not divisible) ***\r\n");
                } else {
                        /* 这两行是故意分开打的：万一改时钟把 PS 挂死，
                           串口最后停在哪一行就说明挂在哪一步。 */
                        xil_printf("  clock register written, FCLK0_CTRL = 0x%08X, re-measuring\r\n",
                                   (unsigned)Xil_In32(FCLK0_CTRL));
                        fclk = measure_fclk_mhz_x100();
                }
        }
        g_fclk_x100 = fclk;
        xil_printf("  FCLK_CLK0   = %u.%02u MHz  used for all timing below\r\n",
                   (unsigned)(fclk / 100U), (unsigned)(fclk % 100U));

        /* 改时钟之后先做一次已知答案的 AXI 读：配置没生效、或总线被改挂了，
           这一步就能在逐位比对之前看出来（挂了则是另一回事，只能断电）。 */
        id = Xil_In32(ATTN_BASE + A_ID);
        xil_printf("  attn_axi ID = 0x%08X  after the clock change %s\r\n",
                   (unsigned)id, (id == A_ID_VAL) ? "ok" : "MISMATCH");

        /* D-cache 打开。安全性不是"看着像没事"，是查 BSP 的 MMU 表得来的：
         *   translation_table.S 里 DDR 是 0x15de6（TEX=101,C=0,B=1，内外 write-back
         *   write-allocate），PL 窗口 0x40000000-0xBFFFFFFF 是 0xc02（Strongly
         *   Ordered，不可缓存），SLCR/UART 所在的 0xf8000000 段是 0xc06（Device）。
         * 所以 PL 寄存器与 scratch 的每一次访问都绕过 cache，和 C 位无关。
         * 本来唯一能出问题的是"PL 往 DDR 里写、PS 读"，本设计没有这条通路：
         * 数据只走 A_DATA 寄存器（见 load_input / read_words），PL 没有 DDR 主口。
         * 打开后逐位比对（5,504 字 ALL PASS）仍要成立——那一步就是判据。
         *
         * 开之前先 invalidate：启动链里谁碰过 DDR 都可能留下脏行。
         * 实测留在文档里的两个数是：关着 2.752 ms、开着见本行下面的 HEAD 行。 */
        Xil_DCacheInvalidate();
        Xil_ICacheEnable();
        Xil_DCacheEnable();
        xil_printf("  D-cache / I-cache = on  (PL window is strongly-ordered; no PL DMA"
                   " into DDR)\r\n");

        if (fclk < FCLK_TARGET_X100 - 100u || fclk > FCLK_TARGET_X100 + 100u) {
                xil_printf("  *** FCLK_CLK0 did NOT land on %u.%02u MHz --"
                           " the numbers below are at %u.%02u MHz ***\r\n",
                           (unsigned)(FCLK_TARGET_X100 / 100U),
                           (unsigned)(FCLK_TARGET_X100 % 100U),
                           (unsigned)(fclk / 100U), (unsigned)(fclk % 100U));
        }

        bad = do_one_run();
        (void)bad;

        xil_printf("\r\n-- idle.  commands: r=run once  h=head only  t=latency"
                   "  R=continuous  f=fclk  c=100MHz  C=200MHz  q=stop --\r\n");
        for (;;) {
                int c = uart_getc();
                if (c < 0) {
                        sleep_ms(10u);
                        continue;
                }
                if (c == 'r') {
                        bad = do_one_run();
                        (void)bad;
                } else if (c == 'h') {
                        xil_printf("\r\n");
                        (void)report_head();
                } else if (c == 't') {
                        report_window_latency();
                } else if (c == 'R') {
                        run_continuous();
                } else if (c == 'f') {
                        u32 f = measure_fclk_mhz_x100();
                        xil_printf("  FCLK_CLK0 = %u.%02u MHz   FCLK0_CTRL = 0x%08X"
                                   " (div0=%u div1=%u src=%u)\r\n",
                                   (unsigned)(f / 100U), (unsigned)(f % 100U),
                                   (unsigned)Xil_In32(FCLK0_CTRL),
                                   (unsigned)fclk0_div0_reg(),
                                   (unsigned)fclk0_div1_reg(),
                                   (unsigned)((Xil_In32(FCLK0_CTRL) & FCLK0_SRCSEL_MASK) >> 4));
                } else if (c == 'c' || c == 'C') {
                        /* 现场切时钟：c = 100 MHz（时序签核点），C = 200 MHz。
                           切完再按 r 就能看到同一份位流在两个频率下的耗时，
                           拍数应当完全一样——这本身就是一条判据。 */
                        u32 want = (c == 'c') ? 100u : 200u;
                        if (set_fclk0_mhz(want) != 0) {
                                xil_printf("  set_fclk0(%u) rejected\r\n", (unsigned)want);
                        } else {
                                g_fclk_x100 = measure_fclk_mhz_x100();
                                xil_printf("  FCLK_CLK0 -> %u.%02u MHz, FCLK0_CTRL = 0x%08X"
                                           " (div0=%u div1=%u)\r\n",
                                           (unsigned)(g_fclk_x100 / 100U),
                                           (unsigned)(g_fclk_x100 % 100U),
                                           (unsigned)Xil_In32(FCLK0_CTRL),
                                           (unsigned)fclk0_div0_reg(),
                                           (unsigned)fclk0_div1_reg());
                        }
                }
        }
        return 0;
}
