# -*- coding: utf-8 -*-
"""定点规格自检：fp32 (r2g_numpy) vs 定点 (fixpt) 在真实缓存数据上的偏差。

    python selftest.py [权重.npz] [缓存.npz]
"""
import os
import sys
import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(os.path.dirname(ROOT), "_board"))

from fixpt import FixPtR2G, calibrate, QMAX
from r2g_numpy import R2GNumpy

W = sys.argv[1] if len(sys.argv) > 1 else \
    os.path.join(os.path.dirname(ROOT), "_board", "w_attn_p_emotion_v_f0.npz")
C = sys.argv[2] if len(sys.argv) > 2 else \
    os.path.join(os.path.dirname(ROOT), "_cache", "r2g", "scenario-end_T4_w4_eegeye.npz")

print(f"[i] 权重 {W}")
print(f"[i] 缓存 {C}")

fp32 = R2GNumpy(W)
sc = calibrate(W, C, n_cal=1024)
print("[i] 校准 scale 表：")
for k, v in sc.items():
    print(f"      {k:6s} = {v:.6g}")

fx = FixPtR2G(W).quantize(sc)
print(f"[i] 权重字节 {fx.n_weight_bytes()} B（fp32 参数的 1/4 量级）")

z = np.load(C, allow_pickle=False)
Ze, Zo = z["Ze"], z["Zo"]
# ★ M=3 用的权重必须配带 Za 的 npz；缺 Za 时直接报错，而不是悄悄按 M=2 跑出好看的数字
Za = z["Za"] if "Za" in z.files else None
if "a" in fp32.mods and Za is None:
    raise SystemExit("★ 权重含 AU 分支，但缓存 npz 里没有 Za —— 换三模态 npz 再跑")
rng = np.random.default_rng(1)
idx = rng.permutation(len(Ze))[:256]
Ze, Zo = Ze[idx], Zo[idx]
Za = None if Za is None else Za[idx]

# ---- fp32
_, zf = fp32.forward(Ze, Zo, Za)
# ---- 定点
zfq, Zpq = fx.forward(Ze, Zo, Za)

print("\n--- 模块③输出 z 的偏差 ---")
for m in zf:
    d = (zfq[m] * sc["act"]) - zf[m]
    print(f"  z[{m}]: maxabs={np.abs(zf[m]).max():.4f}  "
          f"max|Δ|={np.abs(d).max():.5f}  rmsΔ={np.sqrt((d**2).mean()):.5f}")

# ---- 用 fp32 head 比较 logits（head 在 PS，不受 PL 定点影响）
def head_apply(zm):
    zc = np.concatenate([zm[m] for m in fp32.mods], axis=-1)
    h1 = np.maximum(zc @ fp32.w["head.0.weight"].T + fp32.w["head.0.bias"], 0.0)
    return h1 @ fp32.w["head.3.weight"].T + fp32.w["head.3.bias"]

l32 = head_apply(zf)
lq = head_apply({m: zfq[m] * sc["act"] for m in zfq})
ag32 = l32.argmax(-1)
agq = lq.argmax(-1)
print("\n--- logits / 预测一致率 ---")
print(f"  max|Δlogit| = {np.abs(l32 - lq).max():.5f}")
print(f"  argmax 一致 {int((ag32 == agq).sum())}/{len(ag32)} = {(ag32 == agq).mean()*100:.2f}%")
print(f"  与真实标签一致 fp32={100*np.mean(ag32==z['y'][idx].argmax(-1)):.2f}%  "
      f"fixpt={100*np.mean(agq==z['y'][idx].argmax(-1)):.2f}%")
print("\n若 argmax 一致率 < 99%，先看 logit 的 |Δ|——head 会放大 z 的误差。")
