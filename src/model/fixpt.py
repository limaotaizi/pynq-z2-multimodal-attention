# -*- coding: utf-8 -*-
"""方案三 ② 档 · PL 注意力主干的逐位定规格（INT8 权重 + INT16 激活）。

这是 `rtl/attn_core.v` 的**唯一规格来源**：RTL 必须逐位复现本文件。

与 `_board/r2g_numpy.py`（fp32 前向）的区别只在算术：
    - 权重 INT8 per-tensor（对称，s = max|w|/127）
    - 激活 INT16，**统一一个 s_act**（残差与 GAP 因此都是纯整数加/移位）
    - 乘累加 48-bit，重定量化 = Q15 乘子 + 算术右移（round-half-up，负数 floor）
    - softmax exp 用 256 项 LUT（步长 2^(-1/32)），tanh 用 1024 项 LUT

★ 定点口径登记（验收报告必须写，不许静默）：
  1. 激活 **per-tensor INT16**；不用 INT8 是因为模块②的残差要跨尺度相加，INT8 会塌。
  2. exp / tanh 都是**查表近似**（1 LSB 量级误差），不是逐位精确的超越函数；
     但**规格与 RTL 逐位一致**，这是本文件保证的东西。
  3. 除法是整数除法（正数下 floor+0.5 舍入），RTL 用移位减法实现。

口径与 fp32 版逐条对应：
    模块① Conv1x1 逐组投影 → 因果 depthwise 平滑 → +PE
    模块② 逐组独立 Q/K/V；Q 对本路对全体其余路 K/V；因果掩码；
          δ_i=1/i 阈值 + 行内重归一化；残差 + 时间维 GAP
    模块③ tanh(Wa·X) → wa → 组间 softmax → 加权和
    模块④ 留 PS（不在此实现）
"""
import os
import sys
import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

QMAX = 32767
QMIN = -32768
EXP_LUT_N = 256
TANH_LUT_N = 1024
TANH_LO = -8.0
TANH_STEP = 16.0 / (TANH_LUT_N - 1)


# ---------------------------------------------------------------- 数值原语
def requant_pack(s_acc, s_out):
    """acc(scale=s_acc) → out(scale=s_out) 的 (M, SH)，M 为 15-bit 无符号。"""
    ratio = float(s_acc) / float(s_out)
    if ratio <= 0:
        raise ValueError("requant: ratio<=0")
    sh = 0
    while ratio * (1 << sh) < 16384.0:
        sh += 1
        if sh > 60:
            raise ValueError("requant: ratio 过小 %r" % ratio)
    m = int(round(ratio * (1 << sh)))
    if m > 32767:
        raise ValueError("requant: M 超 15 bit（ratio=%r）" % ratio)
    return m, sh


def requant(acc, mp):
    m, sh = mp
    v = np.asarray(acc, dtype=np.int64) * np.int64(m)
    if sh > 0:
        v = (v + np.int64(1 << (sh - 1))) >> np.int64(sh)
    return np.clip(v, QMIN, QMAX)


def q_int8(w):
    w = np.asarray(w, dtype=np.float64)
    s = float(np.abs(w).max()) / 127.0
    if s <= 0:
        return np.zeros(w.shape, dtype=np.int64), 1.0
    return np.clip(np.round(w / s), -127, 127).astype(np.int64), s


def q_int16(x, s):
    return np.clip(np.round(np.asarray(x, np.float64) / s), QMIN, QMAX).astype(np.int64)


def qmaxabs(x):
    mx = float(np.abs(x).max()) if np.size(x) else 0.0
    return mx


EXP_LUT = np.round(255.0 * np.exp2(-np.arange(EXP_LUT_N) / 32.0)).astype(np.int64)
TANH_LUT = np.round(32767.0 * np.tanh(TANH_LO + np.arange(TANH_LUT_N) * TANH_STEP)).astype(np.int64)


EXP_KC_SHIFT = 24


def exp_kc(s_t):
    """LUT 索引乘子的定点常数：KC = round(s_t * 32/ln2 * 2^24)。"""
    return int(round(s_t * 32.0 / np.log(2.0) * (1 << EXP_KC_SHIFT)))


def exp_neg(tq, s_t):
    """exp(-t_real)，tq>=0、scale=s_t；返回 0..255（数组亦可）。

    ★ 索引必须用 **floor(x+0.5)**（四舍五入），不能用 np.round——后者是
      银行家舍入（round(0.5)=0、round(1.5)=2），RTL 里没有对应物。原实现用的
      正是 np.round，会让规格与 RTL 在 0.5 处系统性分叉。
    """
    KC = exp_kc(s_t)
    x = np.asarray(tq, np.int64) * KC
    k = (x + (1 << (EXP_KC_SHIFT - 1))) >> EXP_KC_SHIFT
    k = np.clip(k, 0, EXP_LUT_N - 1)
    return EXP_LUT[k]


def tanh_q(xq, s_x):
    """tanh(x_real) → Q1.15（数组）。"""
    x = np.asarray(xq, np.float64) * s_x
    k = np.round((x - TANH_LO) / TANH_STEP).astype(np.int64)
    k = np.clip(k, 0, TANH_LUT_N - 1)
    return TANH_LUT[k]


def idiv_round(n, d):
    """(n + d//2)//d —— 正的整数除法，四舍五入。n/d 均可为数组（d 按广播）。"""
    n = np.asarray(n, np.int64)
    d = np.asarray(d, np.int64)
    return (n + d // 2) // d


# ---------------------------------------------------------------- 模型
class FixPtR2G:
    """从 `_board/export_weights.py` 的 npz 重建模块①②③的定点前向。"""

    def __init__(self, npz_path):
        z = np.load(npz_path, allow_pickle=False)
        self.wf = {k: z[k] for k in z.files if not k.startswith("meta_")}
        self.d = int(z["meta_d"])
        self.T = int(z["meta_T"])
        self.agg_mode = str(z["meta_agg"])
        self.lds = str(z["meta_lds"])
        self.mods = [str(m) for m in z["meta_mods"]]
        self.feat_dim = z["meta_feat_dim"].astype(np.int64)
        self.offsets = z["meta_offsets"][:, :2].astype(np.int64)
        self.group_counts = {m: int(c) for m, c in
                             zip(self.mods, z["meta_group_counts"].astype(np.int64))}
        self.n_groups = len(self.feat_dim)
        self.pe = self.wf["enc.pe"].astype(np.float64)
        M = len(self.mods)
        i = np.arange(self.T).reshape(self.T, 1)
        j = np.arange(max(M - 1, 0) * self.T).reshape(1, -1) % self.T
        self.masked = (j > i)                                  # True = 不可见
        # δ 表与 fp32 参考 `r2g_numpy.delta_lut` **必须逐字相同**，口径随权重走：
        #   "t1"  = 1/(t+1)（历史，与 M 无关；M=3 下 91.8% 的行会被整行清零，
        #           靠下面的 one-hot 保底兜住 —— 训练用的就是这个口径）；
        #   "nvis"= 1/可见槽数（M=3 的修正口径，需配套重训）。
        self.delta_mode = str(z["meta_delta_mode"]) if "meta_delta_mode" in z.files else "t1"
        self.n_visible = (np.arange(self.T) + 1) * max(M - 1, 1)
        denom = self.n_visible if self.delta_mode == "nvis" else (np.arange(self.T) + 1)
        self.delta_q15 = np.round(32767.0 / denom).astype(np.int64)
        self.qw, self.sw, self.bias, self.rq = {}, {}, {}, {}
        self.sc = {}

    # -------------------------------------------------- 量化
    def quantize(self, sc):
        """sc: 激活 scale 表（键见 calibrate()）。"""
        self.sc = dict(sc)
        wf = self.wf

        def add(name, W, b, s_out):
            q, s = q_int8(W)
            self.qw[name] = q
            self.sw[name] = s
            self.bias[name] = np.round(np.asarray(b, np.float64) / s_out).astype(np.int64)

        for g in range(self.n_groups):
            add(f"proj_e.{g}", wf[f"enc.proj_e.{g}.weight"][:, :, 0],
                wf[f"enc.proj_e.{g}.bias"], sc["act"])
        if "o" in self.mods:
            add("proj_o", wf["enc.proj_o.weight"][:, :, 0], wf["enc.proj_o.bias"], sc["act"])
        if "a" in self.mods:
            # 输入是 AU 的 51 维窗统计量，量化尺度单独一张表（sc["za"]）
            add("proj_a", wf["enc.proj_a.weight"][:, :, 0], wf["enc.proj_a.bias"], sc["act"])
        if "s" in self.mods:
            # GSR：24 维窗级描述子，量化尺度 sc["zs"]
            add("proj_s", wf["enc.proj_s.weight"][:, :, 0], wf["enc.proj_s.bias"], sc["act"])
        if self.lds == "conv":
            add("lds_e", wf["enc.lds_e.weight"][:, 0, :], wf["enc.lds_e.bias"], sc["act"])
            if "o" in self.mods:
                add("lds_o", wf["enc.lds_o.weight"][:, 0, :], wf["enc.lds_o.bias"], sc["act"])
            if "a" in self.mods:
                add("lds_a", wf["enc.lds_a.weight"][:, 0, :], wf["enc.lds_a.bias"], sc["act"])
            if "s" in self.mods:
                add("lds_s", wf["enc.lds_s.weight"][:, 0, :], wf["enc.lds_s.bias"], sc["act"])
        for g in range(self.n_groups):
            for m in self.mods:
                for key in ("Wq", "Wk", "Wv"):
                    add(f"{key}.{g}.{m}", wf[f"align.{key}.{g}.{m}.weight"],
                        wf[f"align.{key}.{g}.{m}.bias"], sc["act"])
        if self.agg_mode == "attn":
            for m in self.mods:
                add(f"Wa.{m}", wf[f"agg.Wa.{m}.weight"], wf[f"agg.Wa.{m}.bias"], sc["tin"])
                add(f"wa.{m}", wf[f"agg.wa.{m}.weight"], wf[f"agg.wa.{m}.bias"], sc["tlog"])

        S = self.sc
        for g in range(self.n_groups):
            self.rq[f"proj_e.{g}"] = requant_pack(self.sw[f"proj_e.{g}"] * S["ze"], S["act"])
        if "o" in self.mods:
            self.rq["proj_o"] = requant_pack(self.sw["proj_o"] * S["zo"], S["act"])
        if "a" in self.mods:
            self.rq["proj_a"] = requant_pack(self.sw["proj_a"] * S["za"], S["act"])
        if "s" in self.mods:
            self.rq["proj_s"] = requant_pack(self.sw["proj_s"] * S["zs"], S["act"])
        if self.lds == "conv":
            self.rq["lds_e"] = requant_pack(self.sw["lds_e"] * S["act"], S["act"])
            if "o" in self.mods:
                self.rq["lds_o"] = requant_pack(self.sw["lds_o"] * S["act"], S["act"])
            if "a" in self.mods:
                self.rq["lds_a"] = requant_pack(self.sw["lds_a"] * S["act"], S["act"])
            if "s" in self.mods:
                self.rq["lds_s"] = requant_pack(self.sw["lds_s"] * S["act"], S["act"])
        for g in range(self.n_groups):
            for m in self.mods:
                for key in ("Wq", "Wk", "Wv"):
                    self.rq[f"{key}.{g}.{m}"] = requant_pack(self.sw[f"{key}.{g}.{m}"] * S["act"], S["act"])
        self.rq["qk"] = requant_pack(S["act"] * S["act"] / np.sqrt(self.d), S["logit"])
        self.rq["av"] = requant_pack(S["act"] / 32767.0, S["act"])
        if self.agg_mode == "attn":
            for m in self.mods:
                self.rq[f"Wa.{m}"] = requant_pack(self.sw[f"Wa.{m}"] * S["act"], S["tin"])
                self.rq[f"wa.{m}"] = requant_pack(self.sw[f"wa.{m}"] / 32767.0, S["tlog"])
                self.rq[f"agg.{m}"] = requant_pack(S["act"] / 32767.0, S["act"])
        return self

    # -------------------------------------------------- 基本层
    def _lin(self, xq, name, mp):
        W, b = self.qw[name], self.bias[name]
        acc = np.tensordot(xq, W, axes=([-1], [-1]))
        return np.clip(requant(acc, mp) + b, QMIN, QMAX)

    def _smooth(self, x, name):
        """因果 depthwise Conv1d(d,d,2)：x[t] ← w0*x[t-1] + w1*x[t] + b。"""
        if self.lds != "conv":
            return x
        W, b, mp = self.qw[name], self.bias[name], self.rq[name]
        y = np.empty_like(x)
        y[..., 0, :] = np.clip(requant(x[..., 0, :] * W[:, 1], mp) + b, QMIN, QMAX)
        for t in range(1, self.T):
            acc = x[..., t - 1, :] * W[:, 0] + x[..., t, :] * W[:, 1]
            y[..., t, :] = np.clip(requant(acc, mp) + b, QMIN, QMAX)
        return y

    # -------------------------------------------------- 模块①
    def encode(self, Zeq, Zoq, Zaq=None, Zsq=None):
        B, T, G = Zeq.shape[0], self.T, self.n_groups
        he = np.empty((B, G, T, self.d), dtype=np.int64)
        for g in range(G):
            s0, s1 = self.offsets[g]
            xg = Zeq[:, :, s0:s1, :].reshape(B, T, -1)
            he[:, g] = self._lin(xg, f"proj_e.{g}", self.rq[f"proj_e.{g}"])
        he = self._smooth(he, "lds_e")
        he = np.clip(he + np.round(self.pe / self.sc["act"]).astype(np.int64), QMIN, QMAX)
        h = {"e": he}
        if Zoq is not None and "o" in self.mods:
            ho = self._lin(Zoq, "proj_o", self.rq["proj_o"])
            ho = self._smooth(ho, "lds_o")
            ho = np.clip(ho + np.round(self.pe / self.sc["act"]).astype(np.int64), QMIN, QMAX)
            h["o"] = ho
        if Zaq is not None and "a" in self.mods:
            ha = self._lin(Zaq, "proj_a", self.rq["proj_a"])
            ha = self._smooth(ha, "lds_a")
            ha = np.clip(ha + np.round(self.pe / self.sc["act"]).astype(np.int64), QMIN, QMAX)
            h["a"] = ha
        if Zsq is not None and "s" in self.mods:
            hs = self._lin(Zsq, "proj_s", self.rq["proj_s"])
            hs = self._smooth(hs, "lds_s")
            hs = np.clip(hs + np.round(self.pe / self.sc["act"]).astype(np.int64), QMIN, QMAX)
            h["s"] = hs
        return h

    # -------------------------------------------------- 模块②
    def _attn_rows(self, lg, valid):
        """lg (B,U) int；valid (U,) bool → a (B,U) Q1.15。"""
        B, U = lg.shape
        rows = np.where(valid[None, :], lg, np.int64(QMIN))
        mx = rows.max(axis=1, keepdims=True)
        t = np.clip(mx - lg, 0, QMAX)
        p = exp_neg(t, self.sc["logit"])
        p = np.where(valid[None, :], p, 0)
        P = p.sum(axis=1, keepdims=True)
        ok = P[:, 0] > 0
        P_safe = np.where(ok[:, None], P, 1)
        aq = idiv_round(p * 32767, P_safe)
        # 行内全零保底：取 lg 最大者
        if (~ok).any():
            am = np.argmax(np.where(valid[None, :], lg, np.int64(QMIN)), axis=1)
            fallback = np.zeros_like(aq)
            fallback[np.arange(B), am] = 32767
            aq = np.where(ok[:, None], aq, fallback)
            p = np.where(ok[:, None], p, fallback)
        return aq, p

    def align(self, h):
        mods = [m for m in self.mods if m in h]
        Zp = {m: [] for m in mods}
        for g in range(self.n_groups):
            tok = {m: (h[m][:, g] if self.group_counts[m] > 1 else h[m]) for m in mods}
            if len(mods) < 2:
                for m in mods:
                    Zp[m].append(self._gap(tok[m]))
                continue
            for m in mods:
                q = self._lin(tok[m], f"Wq.{g}.{m}", self.rq[f"Wq.{g}.{m}"])
                others = [m2 for m2 in mods if m2 != m]
                kv = np.concatenate([tok[m2] for m2 in others], axis=1)
                k = self._lin(kv, f"Wk.{g}.{m}", self.rq[f"Wk.{g}.{m}"])
                v = self._lin(kv, f"Wv.{g}.{m}", self.rq[f"Wv.{g}.{m}"])
                acc = np.einsum("btd,bud->btu", q, k)
                lg = np.clip(requant(acc, self.rq["qk"]), QMIN, QMAX)   # (B,T,U)
                # 逐时刻：masked 按 u%T > t
                a = np.empty_like(lg)
                U = lg.shape[2]
                for t in range(self.T):
                    valid = ~np.array([(u % self.T) > t for u in range(U)])
                    aq, _ = self._attn_rows(lg[:, t, :], valid)
                    # δ 阈值 + 重归一化
                    pre = aq                                   # 保底要取**剪枝前**的最大权重
                    keep = aq >= self.delta_q15[t]
                    aq = np.where(keep, aq, 0)
                    S = aq.sum(axis=1, keepdims=True)
                    # ★ 整行清零保底：与 fp32 `apply_delta` 同口径 —— 取剪枝前最大权重那一路，
                    #   置为 32767（one-hot）。M=3 的可见槽翻倍，δ=1/(t+1) 在早期时刻必然触发这里。
                    zero = S[:, 0] <= 0
                    if zero.any():
                        am = np.argmax(pre, axis=1)
                        fb = np.zeros_like(aq)
                        fb[np.arange(aq.shape[0]), am] = 32767
                        aq = np.where(zero[:, None], fb, aq)
                        S = aq.sum(axis=1, keepdims=True)
                    a[:, t, :] = (aq * 32767 + S // 2) // S
                zacc = np.einsum("btu,bud->btd", a, v)
                z = np.clip(requant(zacc, self.rq["av"]), QMIN, QMAX)
                z = np.clip(z + tok[m], QMIN, QMAX)
                Zp[m].append(self._gap(z))
        return {m: np.stack(Zp[m], axis=1) for m in mods}

    def _gap(self, z):
        s = z.sum(axis=1)
        return (s + (self.T // 2)) // self.T

    # -------------------------------------------------- 模块③
    def aggregate(self, Zp):
        S = self.sc
        z = {}
        for m, X in Zp.items():
            if self.agg_mode != "attn":
                raise NotImplementedError("cat 口径不在 PL 侧做")
            y = self._lin(X, f"Wa.{m}", self.rq[f"Wa.{m}"])        # (B,G,d)
            tq = tanh_q(y, S["tin"])
            lg = self._lin(tq, f"wa.{m}", self.rq[f"wa.{m}"])      # (B,G,1)
            B, G = lg.shape[0], lg.shape[1]
            a = np.empty((B, G), dtype=np.int64)
            for b in range(B):
                row = lg[b, :, 0]
                mx = int(row.max())
                p = exp_neg(mx - row, S["tlog"])
                P = int(p.sum())
                a[b] = (p * 32767 + P // 2) // P
            acc = np.einsum("bgd,bg->bd", X, a)
            z[m] = np.clip(requant(acc, self.rq[f"agg.{m}"]), QMIN, QMAX)
        return z

    # -------------------------------------------------- 总前向
    def forward(self, Ze, Zo, Za=None, Zs=None):
        Zeq = q_int16(Ze, self.sc["ze"])
        Zoq = q_int16(Zo, self.sc["zo"]) if Zo is not None else None
        Zaq = q_int16(Za, self.sc["za"]) if (Za is not None and "a" in self.mods) else None
        Zsq = q_int16(Zs, self.sc["zs"]) if (Zs is not None and "s" in self.mods) else None
        h = self.encode(Zeq, Zoq, Zaq, Zsq)
        Zp = self.align(h)
        z = self.aggregate(Zp)
        return z, Zp

    def n_weight_bytes(self):
        return int(sum(v.size for v in self.qw.values()))


# ---------------------------------------------------------------- 校准
def calibrate(npz_w, cache_npz, n_cal=1024, seed=0, headroom=1.5):
    """在 fp32 模型上跑一段数据，给出一张激活 scale 表。

    返回 dict，键：ze zo act logit tin tlog。
    """
    sys.path.insert(0, os.path.join(os.path.dirname(HERE), "..", "_board"))
    from r2g_numpy import R2GNumpy
    m = R2GNumpy(npz_w)
    z = np.load(cache_npz, allow_pickle=False)
    Ze, Zo = z["Ze"], z["Zo"]
    Za = z["Za"] if ("a" in m.mods and "Za" in z.files) else None
    Zs = z["Zs"] if ("s" in m.mods and "Zs" in z.files) else None
    idx = np.random.default_rng(seed).permutation(len(Ze))[:n_cal]
    Ze, Zo = Ze[idx], Zo[idx]
    Za = None if Za is None else Za[idx]
    Zs = None if Zs is None else Zs[idx]
    rec = {"act": 0.0, "logit": 0.0, "tin": 0.0}
    h = m._encode(Ze, Zo, Za, Zs)
    for k in h:
        rec["act"] = max(rec["act"], qmaxabs(h[k]))
    for g in range(m.n_groups):
        tok = {mm: (h[mm][:, g] if m.group_counts[mm] > 1 else h[mm]) for mm in m.mods}
        for mm in m.mods:
            others = [x for x in m.mods if x != mm]
            kv = np.concatenate([tok[x] for x in others], axis=1)
            for key in ("Wq", "Wk", "Wv"):
                src = tok[mm] if key == "Wq" else kv
                W = m.w[f"align.{key}.{g}.{mm}.weight"]
                b = m.w[f"align.{key}.{g}.{mm}.bias"]
                rec["act"] = max(rec["act"], qmaxabs(src @ W.T + b))
            q = tok[mm] @ m.w[f"align.Wq.{g}.{mm}.weight"].T + m.w[f"align.Wq.{g}.{mm}.bias"]
            kk = kv @ m.w[f"align.Wk.{g}.{mm}.weight"].T + m.w[f"align.Wk.{g}.{mm}.bias"]
            rec["logit"] = max(rec["logit"], qmaxabs(np.einsum("btd,bud->btu", q, kk) / np.sqrt(m.d)))
    Zp = m._align(h)
    for mm, X in Zp.items():
        rec["act"] = max(rec["act"], qmaxabs(X))
        W = m.w[f"agg.Wa.{mm}.weight"]; b = m.w[f"agg.Wa.{mm}.bias"]
        y = X @ W.T + b
        rec["tin"] = max(rec["tin"], qmaxabs(y))
        t = np.tanh(y)
        rec["tlog"] = max(rec.get("tlog", 0.0), qmaxabs(t @ m.w[f"agg.wa.{mm}.weight"].T
                                                      + m.w[f"agg.wa.{mm}.bias"]))
    return {
        "ze": 1.0 / 1024.0,
        "zo": 1.0 / 1024.0,
        # AU 的 51 维统计量量级与眼动同档（都已按被试 z-score），沿用 1/1024
        "za": 1.0 / 1024.0,
        # GSR 的 24 维窗级描述子量级与前三路同档（实测 max|Zs|=15.5、p99=2.7，
        # Ze/Zo/Za 分别是 17.0/18.6/18.2 与 3.3/3.1/3.4），沿用 1/1024 不溢出
        "zs": 1.0 / 1024.0,
        "act": rec["act"] * headroom / QMAX,
        "logit": rec["logit"] * headroom / QMAX,
        "tin": rec["tin"] * headroom / QMAX,
        "tlog": max(rec["tlog"] * headroom / QMAX, 1e-6),
    }


if __name__ == "__main__":
    print(__doc__)
