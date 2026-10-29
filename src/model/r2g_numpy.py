# -*- coding: utf-8 -*-
"""方案三 · 板端纯 NumPy 前向（零 torch 依赖）。

与 `r2g_model.py` 的 PyTorch 实现逐模块对应，口径逐条对齐：

    模块① TimeEncoder      Conv1d(k=1) 逐组投影 → 因果 depthwise 平滑 → +PE
    模块② GroupAlign       逐功能组独立 Q/K/V；本路 Q 对**全体其余路** K/V；
                           因果下三角掩码；δ_i=1/i 阈值 + 行内重归一化；残差 + 时间维 GAP
    模块③ GroupAggregate   cat（各组 concat 后 Linear） / attn（逐组 softmax 加权和）
    模块④ R2G.head         Linear(M·d → hidden) → ReLU → Linear(hidden → 3)

★ **分组索引不在这里重算** —— `feat_dim`（逐组特征维）与 `offsets`（逐组切片）由权重
  npz 携带，导出时读的是 `groups.py` 的 `OFFSETS`，单一真源。
★ **只依赖 numpy**：PYNQ 基础镜像自带，板上不需要装 torch。

自检（需要先把权重导出来）：
    python r2g_numpy.py <weights.npz>
"""
import sys
import numpy as np


# ---------------------------------------------------------------- 数值原语
def _softmax(x, axis=-1):
    """数值稳定 softmax。x 里的 -inf（因果掩码）经 exp 后为 0，不产 NaN。

    行内至少有一个有限元（因果掩码保证 j<=i 合法），故 max 恒有限。
    """
    m = np.max(x, axis=axis, keepdims=True)
    e = np.exp(x - m)
    return e / e.sum(axis=axis, keepdims=True)


def causal_mask(T, n_other):
    """(T, n_other·T) 加法掩码：本路时刻 i 看不到他路时刻 j > i。M=2 时退化为 T×T 下三角。"""
    i = np.arange(T).reshape(T, 1)
    j = np.arange(n_other * T).reshape(1, -1) % T
    return np.where(j > i, -np.inf, 0.0).astype(np.float32)


def delta_lut(T, M=2, mode="t1"):
    """δ 阈值 LUT。mode="t1"：1/(t+1)（历史，与 M 无关）；"nvis"：1/((t+1)·(M-1))。

    与 `r2g_model.delta_lut` 同一约定；默认 t1 保证老权重逐位可复现。
    """
    if mode == "nvis":
        return (1.0 / ((np.arange(T) + 1) * max(M - 1, 1))).astype(np.float32)
    return np.array([1.0 / (t + 1) for t in range(T)], dtype=np.float32)


def apply_delta(a, delta):
    """δ_i 阈值 → 行内清零 → **按幸存权重重新归一化**（导师版 §2.2.3）。

    ★ 与 torch 版同样必须给保底：δ_1 = 1，满行输入下第 0 行会被整行清零。
      退化为「取最大权重那一个」，保证行和恒为 1，不产零向量。
    """
    keep = (a >= delta.reshape(1, -1, 1)).astype(a.dtype)
    a2 = a * keep
    s = a2.sum(-1, keepdims=True)
    empty = (s <= 0)[..., 0]
    if bool(empty.any()):
        idx = a.argmax(-1)[..., None]
        oh = np.zeros_like(a)
        np.put_along_axis(oh, idx, 1.0, axis=-1)
        a2 = np.where(empty[..., None], oh, a2)
        s = a2.sum(-1, keepdims=True)
    return a2 / s


# ---------------------------------------------------------------- 算子
def _linear(x, W, b):
    """nn.Linear：y = x @ Wᵀ + b。W 形如 (out, in)。"""
    return x @ W.T + b


def _conv1x1(x, W, b):
    """nn.Conv1d(k, d, 1)：权重 (d, k, 1)，等价于对最后一维做 Linear。"""
    return x @ W[:, :, 0].T + b


def _smooth_conv(x, W, b):
    """因果 depthwise Conv1d(d, d, 2, groups=d) + 左补一帧，取前 T 帧。

    out[t] = W₀·x[t−1] + W₁·x[t]（x[−1] := 0）。W 形如 (d, 1, 2)。
    """
    w0, w1 = W[:, 0, 0], W[:, 0, 1]                      # 各 (d,)
    xp = np.concatenate([np.zeros_like(x[..., :1, :]), x], axis=-2)   # (..., T+1, d)
    return w0 * xp[..., :-1, :] + w1 * xp[..., 1:, :] + b


# ---------------------------------------------------------------- 模型
class R2GNumpy:
    """从 export_weights.py 产出的 npz 重建的纯 NumPy 前向。

    只做推理，无梯度。全部逐样本/逐批，不含 Python 级循环（功能组维已向量化）。
    """

    def __init__(self, npz_path):
        z = np.load(npz_path, allow_pickle=False)
        self.w = {k: z[k] for k in z.files if not k.startswith("meta_")}

        self.d = int(z["meta_d"])
        self.T = int(z["meta_T"])
        self.hidden = int(z["meta_hidden"])
        self.agg_mode = str(z["meta_agg"])
        self.lds = str(z["meta_lds"])
        self.mods = [str(m) for m in z["meta_mods"]]
        self.feat_dim = z["meta_feat_dim"].astype(np.int64)
        self.offsets = z["meta_offsets"][:, :2].astype(np.int64)   # (16,2) 的 [start, stop)
        # 逐模态的功能组数（G_m）：>1 的按组切片，==1 的整条广播（groups.py 的表 2）
        self.group_counts = {m: int(c) for m, c in
                             zip(self.mods, z["meta_group_counts"].astype(np.int64))}
        self.n_groups = len(self.feat_dim)
        self.target = str(z["meta_target"])
        self.fold = int(z["meta_fold"])
        self.int8 = bool(np.asarray(z["meta_int8"]).item())

        M = len(self.mods)
        self.mask = causal_mask(self.T, max(M - 1, 0))
        # 老权重没有 meta_delta_mode ⇒ 历史口径 t1，与训练时逐字一致
        self.delta_mode = str(z["meta_delta_mode"]) if "meta_delta_mode" in z.files else "t1"
        self.delta = delta_lut(self.T, M, self.delta_mode)
        self.pe = self.w["enc.pe"]                                  # (T, d)

    # -------------------------------------------------- 模块①
    def _encode(self, ze, zo, za=None, zs=None):
        h = {}
        if "e" in self.mods:
            parts = []
            for g in range(self.n_groups):
                s, t = self.offsets[g]
                xg = ze[:, :, s:t, :].reshape(ze.shape[0], self.T, -1)   # (B,T,5·n_e)
                parts.append(_conv1x1(xg, self.w[f"enc.proj_e.{g}.weight"],
                                      self.w[f"enc.proj_e.{g}.bias"]))
            he = np.stack(parts, axis=1)                             # (B,16,T,d)
            if self.lds == "conv":
                he = _smooth_conv(he, self.w["enc.lds_e.weight"], self.w["enc.lds_e.bias"])
            h["e"] = he + self.pe
        if "o" in self.mods:
            ho = _conv1x1(zo, self.w["enc.proj_o.weight"], self.w["enc.proj_o.bias"])
            if self.lds == "conv":
                ho = _smooth_conv(ho, self.w["enc.lds_o.weight"], self.w["enc.lds_o.bias"])
            h["o"] = ho + self.pe
        if "a" in self.mods:
            # AU 只有 1 个功能组（groups.G["a"]=1）：整条序列广播到全部组，
            # 所以这里只做一次 51→d 的投影，形状与 "o" 相同。
            ha = _conv1x1(za, self.w["enc.proj_a.weight"], self.w["enc.proj_a.bias"])
            if self.lds == "conv":
                ha = _smooth_conv(ha, self.w["enc.lds_a.weight"], self.w["enc.lds_a.bias"])
            h["a"] = ha + self.pe
        if "s" in self.mods:
            # GSR 同样只有 1 个功能组（groups.G["s"]=1）：24 维窗统计量整条广播。
            hs = _conv1x1(zs, self.w["enc.proj_s.weight"], self.w["enc.proj_s.bias"])
            if self.lds == "conv":
                hs = _smooth_conv(hs, self.w["enc.lds_s.weight"], self.w["enc.lds_s.bias"])
            h["s"] = hs + self.pe
        return h

    # -------------------------------------------------- 模块②
    def _align(self, h):
        mods = [m for m in self.mods if m in h]
        Zp = {m: [] for m in mods}
        for g in range(self.n_groups):
            tok = {}
            for m in mods:
                # β_g：G_m > 1 取本组；G_m == 1 取整条序列广播到每一个组
                tok[m] = h[m][:, g] if self.group_counts[m] > 1 else h[m]
            if len(mods) < 2:                                        # 单路：无「其余路」，退化为恒等
                for m in mods:
                    Zp[m].append(tok[m].mean(axis=1))
                continue
            for m in mods:
                q = _linear(tok[m], self.w[f"align.Wq.{g}.{m}.weight"],
                            self.w[f"align.Wq.{g}.{m}.bias"])         # (B,T,d)
                others = [m2 for m2 in mods if m2 != m]
                kv = np.concatenate([tok[m2] for m2 in others], axis=1)   # (B,(M-1)T,d)
                k = _linear(kv, self.w[f"align.Wk.{g}.{m}.weight"],
                            self.w[f"align.Wk.{g}.{m}.bias"])
                v = _linear(kv, self.w[f"align.Wv.{g}.{m}.weight"],
                            self.w[f"align.Wv.{g}.{m}.bias"])
                a = _softmax(q @ k.transpose(0, 2, 1) / np.sqrt(self.d) + self.mask, axis=-1)
                a = apply_delta(a, self.delta)
                z = a @ v + tok[m]                                    # 残差
                Zp[m].append(z.mean(axis=1))                          # 时间维 GAP
        return {m: np.stack(Zp[m], axis=1) for m in mods}             # (B, G', d)

    # -------------------------------------------------- 模块③
    def _aggregate(self, Zp):
        z = {}
        for m, X in Zp.items():
            if self.agg_mode == "cat":
                z[m] = _linear(X.reshape(X.shape[0], -1),
                               self.w[f"agg.Wc.{m}.weight"], self.w[f"agg.Wc.{m}.bias"])
                continue
            t = np.tanh(_linear(X, self.w[f"agg.Wa.{m}.weight"], self.w[f"agg.Wa.{m}.bias"]))
            a = _softmax(_linear(t, self.w[f"agg.wa.{m}.weight"],
                                 self.w[f"agg.wa.{m}.bias"]), axis=1)   # (B,G',1)
            z[m] = (a * X).sum(axis=1)
        return z

    # -------------------------------------------------- 前向
    def forward(self, Ze, Zo, Za=None, Zs=None):
        """返回 logits (B,3) 与逐路模块③输出 z。未参与的路传 None。"""
        Ze = None if Ze is None else np.asarray(Ze, dtype=np.float32)
        Zo = None if Zo is None else np.asarray(Zo, dtype=np.float32)
        Za = None if Za is None else np.asarray(Za, dtype=np.float32)
        Zs = None if Zs is None else np.asarray(Zs, dtype=np.float32)
        h = self._encode(Ze, Zo, Za, Zs)
        Zp = self._align(h)
        z = self._aggregate(Zp)
        zc = np.concatenate([z[m] for m in self.mods], axis=-1)
        h1 = np.maximum(_linear(zc, self.w["head.0.weight"], self.w["head.0.bias"]), 0.0)
        logits = _linear(h1, self.w["head.3.weight"], self.w["head.3.bias"])
        return logits, z

    def predict(self, Ze, Zo, Za=None, Zs=None, bs=256):
        """分批前向 → argmax 预测。分批是为了控制板上内存与 cache。"""
        out = []
        n = len(Ze) if Ze is not None else len(Zo)
        for i in range(0, n, bs):
            ix = slice(i, i + bs)
            lg, _ = self.forward(None if Ze is None else Ze[ix],
                                 None if Zo is None else Zo[ix],
                                 None if Za is None else Za[ix],
                                 None if Zs is None else Zs[ix])
            out.append(lg.argmax(-1))
        return np.concatenate(out)

    def n_params(self):
        return int(sum(v.size for k, v in self.w.items() if k.endswith("weight")
                       and v.ndim >= 2))


# ---------------------------------------------------------------- 自检
def _selfcheck(npz_path):
    m = R2GNumpy(npz_path)
    print(f"[OK] 载入 {npz_path}")
    print(f"     配置 d={m.d} T={m.T} hidden={m.hidden} agg={m.agg_mode} "
          f"lds={m.lds} mods={m.mods} target={m.target} fold={m.fold} int8={m.int8}")
    print(f"[OK] 逐组特征维 {m.feat_dim.tolist()}  合计 {int(m.feat_dim.sum())}")

    rng = np.random.default_rng(0)
    Ze = rng.standard_normal((8, m.T, 62, 5)).astype(np.float32)
    Zo = rng.standard_normal((8, m.T, 24)).astype(np.float32)
    logits, z = m.forward(Ze, Zo)
    assert logits.shape == (8, 3), logits.shape
    assert np.isfinite(logits).all(), "logits 含 NaN/Inf"
    for k, v in z.items():
        assert v.shape == (8, m.d), (k, v.shape)
        assert np.isfinite(v).all(), f"z[{k}] 含 NaN/Inf"
    print(f"[OK] 前向：logits {logits.shape}  z " +
          " ".join(f"{k}{v.shape}" for k, v in z.items()))
    print(f"[OK] 参数量 {m.n_params():,}（不含 PE/掩码）")
    print(f"[OK] 预测分布 {np.bincount(logits.argmax(-1), minlength=3).tolist()}")
    print("\n纯 NumPy 前向自检通过。")


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(1)
    _selfcheck(sys.argv[1])
