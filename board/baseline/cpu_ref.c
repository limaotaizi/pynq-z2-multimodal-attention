/* =============================================================================
 * cpu_ref.c -- the M=4 attention engine, executed on the Cortex-A9.
 *
 * This is the same-board CPU baseline the report asks for: the *same*
 * instruction stream (instr.mem), the *same* weights, bias, requant pairs,
 * LUT and test vector that the bitstream runs, executed by a scalar C
 * interpreter over the same 8192-word scratch layout.
 *
 * Why an interpreter and not a hand-written attention kernel: the comparison
 * has to be the same work. A separate C implementation of "the same maths"
 * would differ in operand order, in where it rounds, and in what counts as one
 * window -- and any difference shows up as a fake speedup. Here every opcode
 * is implemented the way attn_core.v implements it, so the outputs are
 * bit-exact by construction and can be checked against the very vectors the
 * RTL testbenches use (exp_*.mem).
 *
 * Scope: modules 1 and 2 plus GAP, i.e. exactly what runs in the PL. The
 * window's load, read-back and the PS head (module 3) are outside both
 * numbers: on the board they are 0.190 ms + 0.113 ms + 0.554 ms.
 *
 * Fairness caveats, stated here because they belong with the number:
 *   - scalar code, -O2, no NEON, no threads. The A9 has VFPv3-D16 only (no
 *     NEON), so a SIMD version would not have been available anyway, but a
 *     hand-written int8 dot product would still beat this interpreter.
 *   - D-cache on, weights in DDR -- the same posture as the production app.
 *   - the interpreter pays decode overhead the hardware pays in a state
 *     machine, so this is a slightly pessimistic CPU number.
 * =============================================================================
 */
#include "xparameters.h"
#include "xil_printf.h"
#include "xil_cache.h"
#include "xtime_l.h"
#include "xuartps.h"

#include "cpu_ref_data.h"

#define SCRATCH_WORDS 8192
#define RUNS          5
#define UART_BASE     XPAR_XUARTPS_0_BASEADDR
#define BAUD          115200

static short S[SCRATCH_WORDS];

/* ---------------------------------------------------------------- uart */
static XUartPs uart_inst;
static int    uart_ready;

static void uart_setup(void)
{
        XUartPs_Config *cfg = XUartPs_LookupConfig(XPAR_XUARTPS_0_DEVICE_ID);
        if (cfg == NULL) {
                return;
        }
        if (XUartPs_CfgInitialize(&uart_inst, cfg, cfg->BaseAddress) != XST_SUCCESS) {
                return;
        }
        (void)XUartPs_SetBaudRate(&uart_inst, BAUD);
        XUartPs_SetOperMode(&uart_inst, XUARTPS_OPER_MODE_NORMAL);
        uart_ready = 1;
}

/* ---------------------------------------------------------------- timing */
static u64 now_ticks(void)
{
        XTime t;
        XTime_GetTime(&t);
        return (u64)t;
}

/* ticks -> milliseconds, printed as ms.us without floating point */
static void print_ms(u64 ticks)
{
        u64 us = (ticks * 1000000ULL) / (u64)COUNTS_PER_SECOND;
        xil_printf("%u.%03u", (unsigned)(us / 1000u), (unsigned)(us % 1000u));
}

/* ---------------------------------------------------------------- arithmetic
 * Mirrors the 7-stage requantiser in attn_core.v:
 *   v = acc*M;  if (pre) v += 1<<(SH-1);  v >>= SH;  sat16(v);  v += add;  sat16(v)
 * `pre` is set for every op that scales a product (and for RESGAP), cleared
 * for PE, which is a plain 16-bit add.
 */
static int sat16(long long v)
{
        if (v > 32767)  return 32767;
        if (v < -32768) return -32768;
        return (int)v;
}

static int requant(long long acc, unsigned m, unsigned sh, int pre, int add)
{
        long long v = acc * (long long)m;
        if (pre) {
                v += (1LL << (sh - 1));
        }
        v >>= sh;
        v = sat16(v);
        return sat16(v + add);
}

/* ---------------------------------------------------------------- opcodes
 * `N` is a 6-bit field. The module-1 smoothing and PE instructions cover
 * G*T = 64 rows, which encodes as 0 -- and attn_core.v then compares
 * `ln == o_N - 6'd1`, i.e. against 63, so the hardware runs 64 rows anyway.
 * Same wrap, same row count here: 0 means 64.
 */
static int rows_of(const ins_t *q)
{
        return q->N ? (int)q->N : 64;
}

static void op_gemm(const ins_t *q)
{
        int n, o, k;
        for (n = 0; n < rows_of(q); ++n) {
                const short *a = &S[q->A + n * q->SS];
                for (o = 0; o < q->O; ++o) {
                        const signed char *w = &W_CPU[q->W + o * q->K];
                        long long acc = 0;
                        for (k = 0; k < q->K; ++k) {
                                acc += (long long)a[k] * (long long)w[k];
                        }
                        S[q->B + n * q->DS + o] =
                                (short)requant(acc, q->M, q->SH, 1, B_CPU[q->C + o]);
                }
        }
}

/* causal depthwise conv: y[t] = w0*x[t-1] + w1*x[t] + b, and y[0] = w1*x[0] + b */
static void op_lds(const ins_t *q)
{
        int n, c, lt = 0;
        for (n = 0; n < rows_of(q); ++n) {
                const short *cur = &S[q->A + n * q->SS];
                const short *prv = &S[q->A + (n - 1) * q->SS];
                for (c = 0; c < q->O; ++c) {
                        int w0 = W_CPU[q->W + 2 * c];
                        int w1 = W_CPU[q->W + 2 * c + 1];
                        long long acc = (long long)cur[c] * w1;
                        if (lt != 0) {
                                acc += (long long)prv[c] * w0;
                        }
                        S[q->B + n * q->DS + c] =
                                (short)requant(acc, q->M, q->SH, 1, B_CPU[q->C + c]);
                }
                if (++lt == G_T) {
                        lt = 0;
                }
        }
}

/* positional encoding: plain add, pe index is {t, channel}.
 * In-place on the region at B -- attn_core.v's S_EXEC loads only o_B for this
 * opcode (lna <= o_B), so A is not an operand and the field is left 0 by the
 * exporter. Reading A here silently added the PE to the *input block* instead,
 * which is why he/zp mismatched while hre (the GEMM output) was exact. */
static void op_pe(const ins_t *q)
{
        int n, c, t = 0;
        for (n = 0; n < rows_of(q); ++n) {
                for (c = 0; c < q->O; ++c) {
                        S[q->B + n * q->SS + c] =
                                (short)requant(S[q->B + n * q->SS + c], 1, 0, 0,
                                               PE_CPU[t * G_D + c]);
                }
                if (++t == G_T) {
                        t = 0;
                }
        }
}

/* masked softmax with the delta threshold, one-hot fallback, then A*V + residual */
static void op_attn(const ins_t *q)
{
        short lg[G_U], p[G_U], aq[G_U], av[G_U];
        int t, u, c, k;

        for (t = 0; t < rows_of(q); ++t) {
                const short *qrow = &S[q->A + t * q->SS];

                /* (1) logits, requantised to 16 bit exactly like the datapath */
                for (u = 0; u < q->O; ++u) {
                        const short *krow = &S[q->B + u * q->K];
                        long long acc = 0;
                        for (k = 0; k < q->K; ++k) {
                                acc += (long long)qrow[k] * (long long)krow[k];
                        }
                        lg[u] = (short)requant(acc, q->M, q->SH, 1, 0);
                }

                /* (2) row max over the visible positions only (u % T <= t) */
                {
                        int mx = -32768;
                        for (u = 0; u < q->O; ++u) {
                                if (((u % G_T) <= t) && (lg[u] > mx)) {
                                        mx = lg[u];
                                }
                        }

                        /* (3) exp LUT: index = (mx - lg) * KC, rounded, clamped */
                        {
                                unsigned long long P = 0;
                                for (u = 0; u < q->O; ++u) {
                                        if ((u % G_T) <= t) {
                                                unsigned short d = (unsigned short)(mx - lg[u]);
                                                unsigned long long idx =
                                                        ((unsigned long long)d * (unsigned long long)KC_CPU
                                                         + (1ULL << 23)) >> 24;
                                                if (idx > 255ULL) {
                                                        idx = 255ULL;
                                                }
                                                p[u] = (short)LUT_CPU[idx];
                                                P += (unsigned)p[u];
                                        } else {
                                                p[u] = 0;
                                        }
                                }

                                /* (4) weights in Q1.15; P > 0 always (the max
                                 *     visible entry has d=0 -> LUT[0]=255) */
                                {
                                        int amx = 0, ami = 0;
                                        long Ssum = 0;
                                        int dcur = DELTA_CPU[t];

                                        for (u = 0; u < q->O; ++u) {
                                                aq[u] = (short)(((unsigned)p[u] * 32767u
                                                                 + (unsigned)(P >> 1))
                                                                / (unsigned)P);
                                        }
                                        /* pre-pruning argmax, strict > : ties keep the lower index */
                                        for (u = 0; u < q->O; ++u) {
                                                if (aq[u] > amx) {
                                                        amx = aq[u];
                                                        ami = u;
                                                }
                                        }
                                        /* (5) delta pruning + row renormalisation */
                                        for (u = 0; u < q->O; ++u) {
                                                if (aq[u] >= dcur) {
                                                        Ssum += aq[u];
                                                } else {
                                                        aq[u] = 0;
                                                }
                                        }
                                        if (Ssum == 0) {          /* one-hot fallback */
                                                aq[ami] = 32767;
                                                Ssum = 32767;
                                        }
                                        for (u = 0; u < q->O; ++u) {
                                                av[u] = (short)(((unsigned)aq[u] * 32767u
                                                                 + (unsigned)(Ssum / 2))
                                                                / (unsigned)Ssum);
                                        }
                                }
                        }
                }

                /* (6) A*V + residual, then requantise into Z */
                for (c = 0; c < q->K; ++c) {
                        long long acc = 0;
                        for (u = 0; u < q->O; ++u) {
                                acc += (long long)av[u] * S[q->W + u * q->K + c];
                        }
                        S[q->C + t * q->SS + c] =
                                (short)requant(acc, q->AM, q->ASH, 1,
                                               S[q->D + t * q->SS + c]);
                }
        }
}

/* time-dimension mean over T rows, rounded: (sum + T/2) / T.
 * The shift is NOT the instruction's SH field -- attn_core.v loads the
 * LG2T6 localparam here (wq_sh <= LG2T6), and the encoder leaves SH at 0.
 * Reading SH from the instruction silently turned the mean into a sum, which
 * is exactly a factor-of-T error in every ZP word. */
static void op_resgap(const ins_t *q)
{
        int n, c, sh = 0;
        while ((1 << sh) < G_T) {
                ++sh;                                   /* LG2T */
        }
        for (c = 0; c < q->O; ++c) {
                long long acc = 0;
                for (n = 0; n < rows_of(q); ++n) {
                        acc += S[q->A + n * q->SS + c];
                }
                S[q->B + c] = (short)requant(acc, 1, (unsigned)sh, 1, 0);
        }
}

/* kv assembly for the M>=3 builds: copy N rows of O words */
static void op_cpy(const ins_t *q)
{
        int n, c;
        for (n = 0; n < rows_of(q); ++n) {
                for (c = 0; c < q->O; ++c) {
                        S[q->B + n * q->DS + c] = S[q->A + n * q->SS + c];
                }
        }
}

/* ---------------------------------------------------------------- driver */
static void run_engine(void)
{
        int pc;

        /* the input is the one word block the host would have written over AXI */
        for (pc = 0; pc < 1636; ++pc) {
                S[ADDR_IN + pc] = IN_CPU[pc];
        }
        for (pc = 0; pc < N_INSTR; ++pc) {
                const ins_t *q = &INS_CPU[pc];
                switch (q->op) {
                case 1: op_gemm(q);   break;
                case 2: op_lds(q);    break;
                case 3: op_pe(q);     break;
                case 4: op_attn(q);   break;
                case 5: op_resgap(q); break;
                case 6: op_cpy(q);    break;
                default: return;
                }
        }
}

static int check_all(void)
{
        int i, bad = 0;
        for (i = 0; i < N_CHECKS; ++i) {
                const chk_t *c = &CHECKS[i];
                unsigned n, diff = 0;
                for (n = 0; n < c->len; ++n) {
                        if (S[c->addr + n] != c->gold[n]) {
                                ++diff;
                        }
                }
                xil_printf("  %-5s %5u words  %s\r\n", c->name, c->len,
                           diff ? "MISMATCH" : "ok");
                /* first three differences, so a failure says where to look */
                if (diff) {
                        unsigned shown = 0;
                        for (n = 0; n < c->len && shown < 3; ++n) {
                                if (S[c->addr + n] != c->gold[n]) {
                                        xil_printf("        [%u] got %d want %d\r\n",
                                                   n, (int)S[c->addr + n],
                                                   (int)c->gold[n]);
                                        ++shown;
                                }
                        }
                }
                bad |= (int)diff;
        }
        return bad;
}

int main(void)
{
        u64 t0, dt[RUNS], best;
        int r, bad;

        uart_setup();
        Xil_ICacheEnable();
        Xil_DCacheEnable();

        xil_printf("\r\n");
        xil_printf("================================================\r\n");
        xil_printf(" CPU reference: modules 1+2 on the Cortex-A9\r\n");
        xil_printf(" same instr stream, same weights, same vector\r\n");
        xil_printf("================================================\r\n");
        xil_printf("  %d instructions, %d weight bytes, %d bias words\r\n",
                   N_INSTR, N_WEIGHTS, N_BIAS);
        xil_printf("  scratch 8192 words, input %d words\r\n", 1636);
        xil_printf("  XTime counts per second = %u\r\n", (unsigned)COUNTS_PER_SECOND);

        /* one untimed pass: warms the caches and proves the arithmetic */
        run_engine();
        xil_printf("\r\n-- bit-exactness against the RTL vectors --\r\n");
        bad = check_all();
        xil_printf("  %s\r\n", bad ? "*** MISMATCH ***" : "ALL PASS");

        xil_printf("\r\n-- engine time on the A9 (%d runs) --\r\n", RUNS);
        best = (u64)-1;
        for (r = 0; r < RUNS; ++r) {
                t0 = now_ticks();
                run_engine();
                dt[r] = now_ticks() - t0;
                if (dt[r] < best) {
                        best = dt[r];
                }
                xil_printf("  run %d: ", r + 1);
                print_ms(dt[r]);
                xil_printf(" ms\r\n");
        }
        /* median of 5 = sorted[2] */
        for (r = 0; r < RUNS; ++r) {
                int j;
                for (j = r + 1; j < RUNS; ++j) {
                        if (dt[j] < dt[r]) {
                                u64 tmp = dt[r];
                                dt[r] = dt[j];
                                dt[j] = tmp;
                        }
                }
        }
        xil_printf("  ------------------------------------------\r\n");
        xil_printf("  min    ");
        print_ms(dt[0]);
        xil_printf(" ms\r\n  median ");
        print_ms(dt[RUNS / 2]);
        xil_printf(" ms\r\n  max    ");
        print_ms(dt[RUNS - 1]);
        xil_printf(" ms\r\n");
        xil_printf("  PL engine for the same instruction stream: 20.790 ms\r\n");

        xil_printf("\r\n-- done.  'q' not needed; reset the board to reboot --\r\n");
        for (;;) {
                /* idle; the JTAG loader can re-download at any time */
        }
        return 0;
}
