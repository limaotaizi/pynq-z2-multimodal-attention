# -*- coding: utf-8 -*-
"""验收：PS 侧模块③+④ 与 PC 端整条管线是否一致。

三级对照（设计 §7 第 8 项）：

    A. PC fp32 全管线         R2GNumpy.forward(Ze, Zo)
    B. PS 侧吃 fp32 的 Zp      ps_head.PSHead(Zp_fp32)
       -> 必须与 A 的小数位一致（只差模块③④本身的浮点结合顺序）
    C. PS 侧吃 PL 口径的 Zp    PSHead.forward_int(Zp_q16, act)
       -> Zp 按 PL 的 INT16 全局 act scale 量化；用来衡量 PL/PS 边界的损失

用法：
    python verify_ps_head.py
"""
import os
import re
import sys
import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
PL = os.path.dirname(HERE)
BOARD = os.path.join(os.path.dirname(PL), "_board")
sys.path.insert(0, BOARD)

from r2g_numpy import R2GNumpy          # noqa: E402
from ps_head import PSHead              # noqa: E402

W = os.path.join(BOARD, "w_attn_p_emotion_v_f0.npz")
REPLAY = os.path.join(BOARD, "replay_cat_pv_f0.npz")
GOLDEN = os.path.join(BOARD, "golden_attn_pv_f0.npz")
NOTE = os.path.join(HERE, "out", "exp_note.txt")


def macro_f1(y, p, n_class=3):
    out = []
    for c in range(n_class):
        tp = int(((p == c) & (y == c)).sum())
        fp = int(((p == c) & (y != c)).sum())
        fn = int(((p != c) & (y == c)).sum())
        pr = tp / (tp + fp) if tp + fp else 0.0
        rc = tp / (tp + fn) if tp + fn else 0.0
        out.append(2 * pr * rc / (pr + rc) if pr + rc else 0.0)
    return float(np.mean(out))


def read_act_scale():
    """PL 用的全局激活 scale，由 export.py 写在 out/exp_note.txt。"""
    txt = open(NOTE, encoding="utf-8").read()
    m = re.search(r"act=([0-9.eE+-]+)", txt)
    if not m:
        raise SystemExit(f"读不到 act scale：{NOTE}")
    return float(m.group(1))


def main():
    m = R2GNumpy(W)
    h = PSHead(W)
    r = np.load(REPLAY, allow_pickle=True)
    Ze, Zo, y = r["Ze"], r["Zo"], r["y"].astype(np.int64)
    act = read_act_scale()
    print(f"权重 {os.path.basename(W)}  agg={m.agg_mode} d={h.d} G={h.n_groups}")
    print(f"回放 {len(y)} 窗  Ze{Ze.shape} Zo{Zo.shape}")
    print(f"PL 全局 act scale = {act:.9g}（来自 out/exp_note.txt）\n")

    # ---- A：PC fp32 全管线
    lgA, zA = m.forward(Ze, Zo)
    predA = lgA.argmax(-1)
    f1A = macro_f1(y, predA)

    # ---- 取 PC 侧的 Zp（fp32）
    Zp32 = m._align(m._encode(Ze, Zo))
    # 校验：PS 侧自己从 Zp 起算，应与全管线逐位一致
    lgB, zB = h.forward(Zp32)
    predB = lgB.argmax(-1)
    f1B = macro_f1(y, predB)
    dmax = float(np.abs(lgB - lgA).max())

    # ---- C：Zp 按 PL 的 INT16 口径量化后再进 PS
    Zp16 = {k: np.clip(np.round(v / act), -32768, 32767).astype(np.int64)
            for k, v in Zp32.items()}
    lgC, zC = h.forward_int(Zp16, act)
    predC = lgC.argmax(-1)
    f1C = macro_f1(y, predC)

    print("--- 结果 ---")
    print(f"  A  PC fp32 全管线        macro-F1 {f1A:.4f}")
    print(f"  B  PS 吃 fp32 Zp         macro-F1 {f1B:.4f}   "
          f"pred 与 A 一致 {int((predA == predB).sum())}/{len(y)}   "
          f"max|Δlogit| {dmax:.2e}")
    print(f"  C  PS 吃 INT16 Zp        macro-F1 {f1C:.4f}   "
          f"pred 与 A 一致 {int((predA == predC).sum())}/{len(y)}   "
          f"ΔF1 {f1C - f1A:+.4f}")
    print(f"  Zp 量化误差  max|ΔZp| = "
          f"{max(float(np.abs(Zp16[k] * act - Zp32[k]).max()) for k in Zp32):.2e}")

    okB = (predA == predB).all() and dmax < 1e-5
    okC = abs(f1C - f1A) < 0.02
    print("\n  " + ("★ B 通过：PS 模块③④ 与 PC 全管线等价" if okB
                    else "★★ B 不通过：PS 侧模块③④ 与 PC 管线不等价"))
    print("  " + ("★ C 通过：PL→PS 的 INT16 Zp 边界损失可接受（|ΔF1|<.02）" if okC
                  else "★★ C 不通过：Zp 量化损失偏大，先查 act scale 口径"))

    if os.path.exists(GOLDEN) and okB and okC:
        g = np.load(GOLDEN, allow_pickle=True)
        gp = g["pred"]
        same = int((gp == predA).sum())
        print(f"\n--- vs 板端黄金（{os.path.basename(GOLDEN)}）---")
        print(f"  pred 一致 {same}/{len(y)}；"
              f" 黄金 F1 {float(g['macro_f1']):.6f} vs 本脚本 {f1A:.6f}")
    return 0 if (okB and okC) else 1


if __name__ == "__main__":
    sys.exit(main())
