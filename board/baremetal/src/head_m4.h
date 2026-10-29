/* ============================================================================
 * head_m4.h -- 模块③（GroupAggregate）+ 模块④（分类头）的板端 C 实现
 *
 * 设计 03_ §2.1 / §2.2 把这两块放在 PS：PL 交出 Zp（每模态 G 个功能组的
 * (T·d) 时间维 GAP 结果，INT16 + 全局 act scale），PS 再把 G 个组压成一路
 * d 维向量，最后两个 FC 出 3 类 logits。
 *
 * 原来这一层只有 Python（`_board/ps_head.py`），也就是说"端侧独立运行"
 * 到引擎为止，后面还得有台机器跑 Python。这里把它写成纯 C：
 * 裸机程序读到 scratch 里的 Zp 就能自己算完三类概率。
 *
 * 口径（与 Python 逐条对应，不许改）：
 *     反量化   x = zp * act
 *     模块③   t = tanh(x @ Wa^T + ba)          → (G,d)
 *              s = t @ wa^T + bwa               → (G,1)
 *              a = softmax_g(s)
 *              z = Σ_g a_g · x_g                → (d,)
 *     拼接     zc = [z_e, z_o, z_a, z_s]        → (M·d,)
 *     模块④   h1 = relu(zc @ W0^T + b0)        → (hidden,)
 *              logits = h1 @ W3^T + b3          → (3,)
 *     概率     softmax(logits)
 *
 * 全程 float（单精度），与 numpy 的 float32 路径同档；差异在 1e-6 量级，
 * 判据给到 1e-3（见 head_m4_gold.h 的 HEAD_TOL_LOGIT）。
 * ==========================================================================*/
#ifndef HEAD_M4_H
#define HEAD_M4_H

#include <stdint.h>

#define HEAD_M       4          /* 模态数 e,o,a,s */
#define HEAD_G       16         /* 功能组数 */
#define HEAD_D       16         /* 每组/每模态的输出维 */
#define HEAD_HIDDEN  64
#define HEAD_NCLS    3

/* 反量化：zp（G·d 个字） -> x[g][i] */
void head_dequant(const int16_t *zp, float act, float x[HEAD_G][HEAD_D]);

/* 模块③ 单模态：m = 0..3（e,o,a,s）。z 输出 d 维。 */
void head_aggregate_m(int m, const int16_t *zp, float act, float z[HEAD_D]);

/* 模块④：zc 长 M·d，输出 3 个 logits。 */
void head_classifier(const float zc[HEAD_M * HEAD_D], float logits[HEAD_NCLS]);

/* 整条：4 路 Zp -> logits / 概率 / 类。zp[m] 指向该模态的 HEAD_G*HEAD_D 个字。 */
void head_forward(const int16_t *const zp[HEAD_M], float act,
                  float logits[HEAD_NCLS], float prob[HEAD_NCLS], int *cls);

#endif /* HEAD_M4_H */
