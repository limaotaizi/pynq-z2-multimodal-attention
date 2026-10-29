/* head_m4.c -- 模块③+④ 的板端实现，见 head_m4.h 的口径说明。
 *
 * 只用 math.h 的 tanhf / expf。裸机 newlib 两份都有（链接要 -lm，已在
 * build_elf.ps1 的库里）。
 *
 * 为什么不用 double：numpy 那条路（`_board/ps_head.py`）全程 float32，
 * 板端跟着用 float32 才同档；换 double 反而会与"已验证的参考值"多出一档
 * 差异，判据就得放宽，得不偿失。
 */
#include <math.h>

#include "head_m4.h"
#include "head_m4_w.h"

void head_dequant(const int16_t *zp, float act, float x[HEAD_G][HEAD_D])
{
        int g, i;

        for (g = 0; g < HEAD_G; ++g) {
                for (i = 0; i < HEAD_D; ++i) {
                        x[g][i] = (float)zp[g * HEAD_D + i] * act;
                }
        }
}

/* 组维 softmax 在栈上做，G=16 很小，直接两遍扫。 */
void head_aggregate_m(int m, const int16_t *zp, float act, float z[HEAD_D])
{
        float x[HEAD_G][HEAD_D];
        float t[HEAD_G][HEAD_D];
        float s[HEAD_G];
        float a[HEAD_G];
        /* Wa / ba 是 (d,d) / (d,)，在 G 个组上**共用**一份（nn.Linear 对
           第 1 维 G 广播）。第一次写成"每组一套"时读越界，z 全成 0，
           结果 logits 恰好等于 head.3 的 bias——这个形状很好认。 */
        const float *wa = HEAD_WA + (size_t)m * HEAD_D * HEAD_D;
        const float *ba = HEAD_BA + (size_t)m * HEAD_D;
        const float *wwa = HEAD_WWA + (size_t)m * HEAD_D;
        const float bwa = HEAD_BWA[m];
        float mx, sum;
        int g, i, o;

        head_dequant(zp, act, x);

        for (g = 0; g < HEAD_G; ++g) {
                for (o = 0; o < HEAD_D; ++o) {
                        const float *wr = wa + (size_t)o * HEAD_D;
                        float acc = ba[o];
                        for (i = 0; i < HEAD_D; ++i) {
                                acc += wr[i] * x[g][i];
                        }
                        t[g][o] = tanhf(acc);
                }
        }

        mx = -1e30f;
        for (g = 0; g < HEAD_G; ++g) {
                float acc = bwa;
                for (i = 0; i < HEAD_D; ++i) {
                        acc += wwa[i] * t[g][i];
                }
                s[g] = acc;
                if (acc > mx) {
                        mx = acc;
                }
        }
        sum = 0.0f;
        for (g = 0; g < HEAD_G; ++g) {
                a[g] = expf(s[g] - mx);
                sum += a[g];
        }
        if (sum <= 0.0f) {              /* 不可能，但别让 0 除 */
                sum = 1.0f;
        }

        for (i = 0; i < HEAD_D; ++i) {
                float acc = 0.0f;
                for (g = 0; g < HEAD_G; ++g) {
                        acc += (a[g] / sum) * x[g][i];
                }
                z[i] = acc;
        }
}

void head_classifier(const float zc[HEAD_M * HEAD_D], float logits[HEAD_NCLS])
{
        float h1[HEAD_HIDDEN];
        int o, i, c;

        for (o = 0; o < HEAD_HIDDEN; ++o) {
                const float *wr = HEAD_W0 + (size_t)o * (HEAD_M * HEAD_D);
                float acc = HEAD_B0[o];
                for (i = 0; i < HEAD_M * HEAD_D; ++i) {
                        acc += wr[i] * zc[i];
                }
                h1[o] = (acc > 0.0f) ? acc : 0.0f;
        }
        for (c = 0; c < HEAD_NCLS; ++c) {
                const float *wr = HEAD_W3 + (size_t)c * HEAD_HIDDEN;
                float acc = HEAD_B3[c];
                for (i = 0; i < HEAD_HIDDEN; ++i) {
                        acc += wr[i] * h1[i];
                }
                logits[c] = acc;
        }
}

void head_forward(const int16_t *const zp[HEAD_M], float act,
                  float logits[HEAD_NCLS], float prob[HEAD_NCLS], int *cls)
{
        float zc[HEAD_M * HEAD_D];
        float mx, sum;
        int m, c, best;

        for (m = 0; m < HEAD_M; ++m) {
                head_aggregate_m(m, zp[m], act, zc + m * HEAD_D);
        }
        head_classifier(zc, logits);

        mx = logits[0];
        best = 0;
        for (c = 1; c < HEAD_NCLS; ++c) {
                if (logits[c] > mx) {
                        mx = logits[c];
                        best = c;
                }
        }
        sum = 0.0f;
        for (c = 0; c < HEAD_NCLS; ++c) {
                prob[c] = expf(logits[c] - mx);
                sum += prob[c];
        }
        for (c = 0; c < HEAD_NCLS; ++c) {
                prob[c] /= sum;
        }
        *cls = best;
}
