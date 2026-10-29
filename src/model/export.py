# -*- coding: utf-8 -*-
"""把 fixpt 规格导出成 RTL 直接 $readmemh 的 ROM/向量文件。

用法：
    python export.py            # 默认 m2（e+o，现役 A1 位流的口径）
    python export.py m2         # 同上
    python export.py m3         # e+o+a（AU 接入）

产物（都在 work2/out/）：
    w_i8.mem       INT8 权重，每行一个十六进制字节（按 flat offset 排）
    bias.mem       INT16 bias（已在输出 scale 上）
    desc.mem       每块一行 64bit：{M[15:0], SH[15:0], b_base[15:0], w_base[15:0]}
                    —— RTL 不用它，留作人工核对
    kg.mem         每个 EEG 功能组的输入维 K_g
    pe.mem         PE，T*D 个 INT16
    delta.mem      δ_i*32767，T 个 INT16
    exp_lut.mem / kc.mem
    instr.mem      指令 ROM
    in.mem         测试向量：按 IN_E / IN_O / IN_A 顺序平铺的 INT16
    exp_*.mem      期望值（RTL 必须逐位一致）

★ 2026-10-24：布局与指令生成全部按 `fx.mods` 泛化，M=2 的产物**逐字节不变**
  （`layout()` 的设计保证 IN_E=0 / IN_O=1240 / HRE=1536 / ... / ZPO=5120 原样复现）。
  M=3 新增：AU 输入区、`HA/QA/KA/VA/ZA/ZPA`、kv 拼接暂存区 `KVE/KVO/KVA`
  以及 `OP_CPY`（GEMM 只能读连续行，而 kv = [tok_e(g), tok_a] 必须拼出来）。
"""
import os
import sys
import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, HERE)

# 2026-10-29: asset locations are configurable, no drive letters, no assumptions
# about the original working tree. The three quantised weight files are committed
# under src/model/assets/. The ~27 MB calibration arrays are NOT (see
# DATA_LICENSE.md) -- point AFFEC_CACHE at them to regenerate vectors.
_CACHE = os.environ.get("AFFEC_CACHE") or os.path.join(HERE, "assets", "cache")
_BOARD = os.path.join(HERE, "assets")
sys.path.insert(0, _BOARD)

from fixpt import FixPtR2G, calibrate, requant, EXP_LUT, exp_kc, EXP_KC_SHIFT

MODES = {
    "m2": dict(W=os.path.join(_BOARD, "w_attn_p_emotion_v_f0.npz"),
               C=os.path.join(_CACHE, "scenario-end_T4_w4_eegeye.npz")),
    "m3": dict(W=os.path.join(_BOARD, "w_attn3_p_emotion_v_f0.npz"),
               C=os.path.join(_CACHE, "scenario-end_T4_w4_aueegeye_sub64.npz")),
    # M=4：四路（e+o+a+s），GSR 走 proj_s/lds_s，与前三路同构（G_s=1 广播）
    "m4": dict(W=os.path.join(_BOARD, "w_attn4_p_emotion_v_f0.npz"),
               C=os.path.join(_CACHE, "scenario-end_T4_w4_all4_sub64.npz")),
}
_argv = [a for a in sys.argv[1:]]
OUT_ARG = None
if "--out" in _argv:
    _i = _argv.index("--out")
    OUT_ARG = _argv[_i + 1]
    del _argv[_i:_i + 2]
MODE = (_argv[0] if _argv else "m2").lower()
if MODE not in MODES:
    raise SystemExit("usage: python export.py [m2|m3|m4] [--out DIR]")
W = MODES[MODE]["W"]
C = MODES[MODE]["C"]
for _p in (W, C):
    if not os.path.isfile(_p):
        raise SystemExit(
            "missing model asset: %s\n"
            "  weights     -> src/model/assets/w_attn*_p_emotion_v_f0.npz (committed)\n"
            "  calibration -> set AFFEC_CACHE to the directory holding\n"
            "                 scenario-end_T4_w4_*.npz (not redistributable)"
            % _p)
OUT = OUT_ARG or os.path.join(HERE, "out")
os.makedirs(OUT, exist_ok=True)


def wr(path, lines):
    with open(path, "w", newline="\n") as f:
        f.write("\n".join(lines) + "\n")


def i16(v):
    return "%04x" % (int(v) & 0xFFFF)


def align_up(x, a):
    return (x + a - 1) // a * a


def layout(mods, G, T, D, in_dim):
    """scratch（8192 x 16）的字布局。

    约束（由 RTL 决定，不能随意改）：
      · 每个模态的输入（IN_*）按 (t, …) 平铺，GEMM 用 SS=该模态展平宽；
      · H 区（模块①输出）每组 T*D 连续，o/a 各 T*D；
      · kv 拼接区每行 (M-1)*D 连续（GEMM 只能读连续行）；
      · Q/K/V/Z 每模态 T*D 连续，组内复用 ⇒ 只要一组的大小；
      · ZP 每模态 G*D（逐组的 GAP 结果）。

    M=2 时必须逐字复现历史常量：
        IN_E=0 IN_O=1240 HRE=1536 HRO=2560 HE=3072 HO=4096
        QE=4352 KE=4416 VE=4480 QO=4544 KO=4608 VO=4672
        ZE=4736 ZO=4800 ZPE=4864 ZPO=5120
    """
    L = {}
    pos = 0
    for m in mods:
        L["IN_" + m.upper()] = pos
        pos += T * in_dim[m]
    pos = align_up(pos, 512)
    L["HRE"] = pos
    pos += G * T * D
    for m in mods[1:]:
        L["HR" + m.upper()] = pos
        pos += T * D
    pos = align_up(pos, 512)
    L["HE"] = pos
    pos += G * T * D
    for m in mods[1:]:
        L["H" + m.upper()] = pos
        pos += T * D
    if len(mods) >= 3:
        # kv = cat(其余模态的 token, dim=序列) ⇒ 2T 行 x D 字；GEMM 只能读
        # 连续行，所以 m=o/a 要先把 [tok_e(g); tok_x] 拼到一起（m=e 天然连续）。
        L["KV"] = pos
        pos += T * D * (len(mods) - 1)
    pos = align_up(pos, 256)
    # Q 与 Z 只有 T 行；K/V 有 (M-1)T 行（kv 是按序列拼的）
    for m in mods:
        L["Q" + m.upper()] = pos
        pos += T * D
        for pfx in ("K", "V"):
            L[pfx + m.upper()] = pos
            pos += T * D * (len(mods) - 1)
    for m in mods:
        L["Z" + m.upper()] = pos
        pos += T * D
    pos = align_up(pos, 256)
    for m in mods:
        L["ZP" + m.upper()] = pos
        pos += G * D
    L["END"] = pos
    return L


def main():
    sc = calibrate(W, C, n_cal=1024)
    fx = FixPtR2G(W).quantize(sc)
    G, T, D = fx.n_groups, fx.T, fx.d
    mods = fx.mods
    M = len(mods)
    # ★ kv 是「其余模态的 token 拼在**序列维**」（r2g_model: cat(dim=1)），
    #   每行仍是 D 字、Wk/Wv 仍是 d->d。所以 KVW 不是 (M-1)*D！
    KVW = D
    U = T * (M - 1)                         # 注意力的 k/v 行数 = kv 行数
    print(f"[i] 模式 {MODE}  模态 {mods}  G={G} T={T} D={D} "
          f"U={U} kv 行宽={KVW}  权重字节={fx.n_weight_bytes()}")

    # 输入展平宽：e 是 62 通道 x 5 带 = 310；o=24；a=51
    in_dim = {"e": int(fx.feat_dim.sum())}
    for m in mods[1:]:
        in_dim[m] = int(fx.qw[f"proj_{m}"].shape[1])
    L = layout(mods, G, T, D, in_dim)
    print(f"[i] scratch 用 {L['END']} / 8192 字")

    # ---------------- 权重 flat 排布
    wbytes, desc, order = [], [], []
    for g in range(G):
        order.append((f"proj_e.{g}", int(fx.feat_dim[g])))
    for m in mods[1:]:
        order.append((f"proj_{m}", in_dim[m]))
    order.append(("lds_e", 2))
    for m in mods[1:]:
        order.append((f"lds_{m}", 2))
    for g in range(G):
        for m in mods:
            order.append((f"Wq.{g}.{m}", D))
            order.append((f"Wk.{g}.{m}", D))
            order.append((f"Wv.{g}.{m}", D))

    bias_all = []
    for name, K in order:
        q = fx.qw[name]
        assert q.shape[1] == K, (name, q.shape, K)
        m_, sh = fx.rq[name]
        w_base = len(wbytes)
        # 每行 (O,K) 连续；RTL 换输入行时把权重指针复位到 w_base
        wbytes.extend(int(x) & 0xFF for x in q.reshape(-1))
        b_base = len(bias_all)
        bias_all.extend(int(x) & 0xFFFF for x in fx.bias[name])
        desc.append((m_, sh, b_base, w_base))

    print(f"[i] 权重 {len(wbytes)} B，bias {len(bias_all)} 个，块 {len(desc)} 个")
    assert len(wbytes) <= 131072, "wrom 只有 128 KiB"
    assert len(bias_all) <= 4096, "brom 只有 4096 项"
    wr(os.path.join(OUT, "w_i8.mem"), ["%02x" % x for x in wbytes])
    wr(os.path.join(OUT, "bias.mem"), [i16(x) for x in bias_all])
    wr(os.path.join(OUT, "desc.mem"),
       ["%04x%04x%04x%04x" % (m_, sh, bb, wb) for (m_, sh, bb, wb) in desc])

    wr(os.path.join(OUT, "kg.mem"), ["%02x" % int(n) for n in fx.feat_dim])

    pe = np.round(fx.pe / sc["act"]).astype(np.int64).reshape(-1)
    wr(os.path.join(OUT, "pe.mem"), [i16(x) for x in pe])
    wr(os.path.join(OUT, "delta.mem"), [i16(x) for x in fx.delta_q15])
    wr(os.path.join(OUT, "exp_lut.mem"), ["%02x" % int(x) for x in EXP_LUT])
    wr(os.path.join(OUT, "kc.mem"), ["%08x" % exp_kc(sc["logit"])])

    # ---------------- 指令表（字段位置必须与 rtl/attn_core.v 一致）
    # [3:0]op [16:4]A [29:17]B [46:30]W [59:47]C [72:60]D [78:73]N [84:79]O
    # [93:85]K [108:94]M [114:109]SH [123:115]SS [132:124]DS
    # [147:133]AM [153:148]ASH   （[159:154] 空闲）
    OP_GEMM, OP_LDS, OP_PE, OP_ATTN, OP_RESGAP, OP_CPY = 1, 2, 3, 4, 5, 6

    def enc(op=0, A=0, B=0, W=0, C=0, D=0, N=0, O=0, K=0, M=0, SH=0, SS=0, DS=0,
            AM=0, ASH=0):
        v = (op & 0xF)
        v |= (A & 0x1FFF) << 4
        v |= (B & 0x1FFF) << 17
        v |= (W & 0x1FFFF) << 30
        v |= (C & 0x1FFF) << 47
        v |= (D & 0x1FFF) << 60
        v |= (N & 0x3F) << 73
        v |= (O & 0x3F) << 79
        v |= (K & 0x1FF) << 85
        v |= (M & 0x7FFF) << 94
        v |= (SH & 0x3F) << 109
        v |= (SS & 0x1FF) << 115
        v |= (DS & 0x1FF) << 124
        v |= (AM & 0x7FFF) << 133
        v |= (ASH & 0x3F) << 148
        return "%040x" % v

    blk = {name: i for i, (name, _) in enumerate(order)}
    ins = []

    # ---- 模块① EEG：逐组投影 → 平滑 → PE
    for g in range(G):
        m_, sh, bb, wb = desc[blk[f"proj_e.{g}"]]
        # offsets 是**通道**下标，输入按 (t, 62, 5) 平铺 ⇒ 乘 5 才对
        ins.append(enc(OP_GEMM, A=L["IN_E"] + int(fx.offsets[g][0]) * 5,
                       B=L["HRE"] + g * T * D, W=wb, C=bb, N=T, O=D,
                       K=int(fx.feat_dim[g]), M=m_, SH=sh, SS=in_dim["e"], DS=D))
    m_, sh, bb, wb = desc[blk["lds_e"]]
    ins.append(enc(OP_LDS, A=L["HRE"], B=L["HE"], W=wb, C=bb, N=G * T, O=D,
                   M=m_, SH=sh, SS=D, DS=D))
    ins.append(enc(OP_PE, B=L["HE"], N=G * T, O=D, SS=D, DS=D))
    # ---- 模块① 其余模态（眼动 / AU）
    for mname in mods[1:]:
        u = mname.upper()
        m_, sh, bb, wb = desc[blk[f"proj_{mname}"]]
        kd = in_dim[mname]
        ins.append(enc(OP_GEMM, A=L["IN_" + u], B=L["HR" + u], W=wb, C=bb,
                       N=T, O=D, K=kd, M=m_, SH=sh, SS=kd, DS=D))
        m_, sh, bb, wb = desc[blk[f"lds_{mname}"]]
        ins.append(enc(OP_LDS, A=L["HR" + u], B=L["H" + u], W=wb, C=bb, N=T, O=D,
                       M=m_, SH=sh, SS=D, DS=D))
        ins.append(enc(OP_PE, B=L["H" + u], N=T, O=D, SS=D, DS=D))

    # ---- kv 拼接（只有 M>=3 才需要；M=2 时另一模态天然连续）
    def kv_of(g, mname):
        """返回 (kv 基址, 行距, 行数)，必要时先发 CPY 把两段接到一起。"""
        others = [m2 for m2 in mods if m2 != mname]
        if M == 2:
            o2 = others[0]
            src = (L["HE"] + g * T * D) if fx.group_counts[o2] > 1 \
                else L["H" + o2.upper()]
            return src, D, T
        # m=e：其余两路的 H 区首尾相接（layout 保证），[tok_o; tok_a] 天然连续
        if others == mods[1:] and all(fx.group_counts[m2] == 1 for m2 in others):
            return L["H" + others[0].upper()], D, T * len(others)
        # m=o/a：第一段是 HE+g*T*D，第二段是另一路的 H 区 ⇒ 必须拷进暂存区
        for i, m2 in enumerate(others):
            src = (L["HE"] + g * T * D) if fx.group_counts[m2] > 1 \
                else L["H" + m2.upper()]
            ins.append(enc(OP_CPY, A=src, B=L["KV"] + i * T * D,
                           N=T, O=D, SS=D, DS=D))
        return L["KV"], D, T * len(others)

    mqk, shqk = fx.rq["qk"]
    mav, shav = fx.rq["av"]
    for g in range(G):
        for mname in mods:
            u = mname.upper()
            own = (L["HE"] + g * T * D) if fx.group_counts[mname] > 1 \
                else L["H" + u]
            kvsrc, kvss, kvn = kv_of(g, mname)
            for key, src_k, dst in (("Wq", own, L["Q" + u]),
                                    ("Wk", kvsrc, L["K" + u]),
                                    ("Wv", kvsrc, L["V" + u])):
                mm, ss_, bb, wb = desc[blk[f"{key}.{g}.{mname}"]]
                # Wq 吃本模态（T 行），Wk/Wv 吃其余模态的 token（(M-1)T 行）
                nn = T if key == "Wq" else kvn
                ins.append(enc(OP_GEMM, A=src_k, B=dst, W=wb, C=bb, N=nn, O=D,
                               K=D, M=mm, SH=ss_,
                               SS=(D if key == "Wq" else kvss), DS=D))
            # ATTN 字段约定：A=q B=k W=v（当基址用）C=z D=残差目标
            #   K=向量宽 D，N=q 行数 T，O=k/v 行数 U，SS=q/z 行距
            ins.append(enc(OP_ATTN, A=L["Q" + u], B=L["K" + u], W=L["V" + u],
                           C=L["Z" + u], D=own, N=T, O=U, K=D,
                           M=mqk, SH=shqk, AM=mav, ASH=shav, SS=D))
            ins.append(enc(OP_RESGAP, A=L["Z" + u], B=L["ZP" + u] + g * D,
                           N=T, O=D, SS=D))
    ins.append(enc(0))            # END
    assert len(ins) <= 512, f"irom 只有 512 项，现在 {len(ins)} 条"
    wr(os.path.join(OUT, "instr.mem"), ins)
    print(f"[i] 指令 {len(ins)} 条（含 END）")

    # ---------------- 测试向量（取第 0 个样本）
    z = np.load(C, allow_pickle=False)
    Ze = z["Ze"][:1].astype(np.float64)
    Zo = z["Zo"][:1].astype(np.float64) if "o" in mods else None
    Za = z["Za"][:1].astype(np.float64) if "a" in mods else None
    Zs = z["Zs"][:1].astype(np.float64) if "s" in mods else None

    def qz(x, key):
        return None if x is None else np.clip(
            np.round(x / sc[key]), -32768, 32767).astype(np.int64)

    Zeq, Zoq, Zaq = qz(Ze, "ze"), qz(Zo, "zo"), qz(Za, "za")
    Zsq = qz(Zs, "zs")
    # 布局：t 主序，通道次之，带最后 —— 与 r2g_numpy 的 (B,T,62,5) 一致；
    #       三个模态按 IN_E / IN_O / IN_A 顺序首尾相接
    inlines = [i16(x) for x in Zeq[0].reshape(-1)]
    for q in (Zoq, Zaq, Zsq):
        if q is not None:
            inlines += [i16(x) for x in q[0].reshape(-1)]
    wr(os.path.join(OUT, "in.mem"), inlines)

    # 中间期望：模块① 的逐组投影输出（平滑/PE 之前）
    hpre = np.empty((G, T, D), dtype=np.int64)
    for g in range(G):
        s0, s1 = fx.offsets[g]
        xg = Zeq[:, :, s0:s1, :].reshape(1, T, -1)
        hpre[g] = fx._lin(xg, f"proj_e.{g}", fx.rq[f"proj_e.{g}"])[0]
    wr(os.path.join(OUT, "exp_hre.mem"), [i16(x) for x in hpre.reshape(-1)])
    for mname, q in (("o", Zoq), ("a", Zaq), ("s", Zsq)):
        if q is not None:
            hr = fx._lin(q, f"proj_{mname}", fx.rq[f"proj_{mname}"])[0]
            wr(os.path.join(OUT, f"exp_hr{mname}.mem"),
               [i16(x) for x in hr.reshape(-1)])

    # 期望值（用定点模型自身算，RTL 必须逐位一致）
    h = fx.encode(Zeq, Zoq, Zaq, Zsq)
    Zp = fx.align(h)

    # ---- 模块② 逐组分段期望
    #   Q/K/V/Z 是每组复用的暂存区 ⇒ 跑全套指令后里面是**最后一组**的内容，
    #   所以 g=0 与 g=G-1 两套都导出（分段调试用）。
    def group_qkvz(g0):
        tok = {m: (h[m][:, g0] if fx.group_counts[m] > 1 else h[m]) for m in fx.mods}
        out = {}
        for m in fx.mods:
            q = fx._lin(tok[m], f"Wq.{g0}.{m}", fx.rq[f"Wq.{g0}.{m}"])
            kv = np.concatenate([tok[m2] for m2 in fx.mods if m2 != m], axis=1)
            k = fx._lin(kv, f"Wk.{g0}.{m}", fx.rq[f"Wk.{g0}.{m}"])
            v = fx._lin(kv, f"Wv.{g0}.{m}", fx.rq[f"Wv.{g0}.{m}"])
            acc = np.einsum("btd,bud->btu", q, k)
            lg = np.clip(requant(acc, fx.rq["qk"]), -32768, 32767)
            a = np.zeros_like(lg)
            UU = lg.shape[2]
            for t in range(fx.T):
                valid = np.array([(uu % fx.T) <= t for uu in range(UU)])
                aq, _ = fx._attn_rows(lg[:, t, :], valid)
                pre = aq
                keep = aq >= fx.delta_q15[t]
                aq = np.where(keep, aq, 0)
                S = aq.sum(axis=1, keepdims=True)
                zero = S[:, 0] <= 0
                if zero.any():
                    am = np.argmax(pre, axis=1)
                    fb = np.zeros_like(aq)
                    fb[np.arange(aq.shape[0]), am] = 32767
                    aq = np.where(zero[:, None], fb, aq)
                    S = aq.sum(axis=1, keepdims=True)
                a[:, t, :] = (aq * 32767 + S // 2) // S
            zacc = np.einsum("btu,bud->btd", a, v)
            zz = np.clip(requant(zacc, fx.rq["av"]), -32768, 32767)
            zz = np.clip(zz + tok[m], -32768, 32767)
            out[m] = (q[0].reshape(-1), k[0].reshape(-1), v[0].reshape(-1),
                      zz[0].reshape(-1))
        return out

    for tag, g0, suf in (("0", 0, ""), ("L", G - 1, "L")):
        d = group_qkvz(g0)
        for m in fx.mods:
            q, k, v, zz = d[m]
            wr(os.path.join(OUT, f"exp_q{suf}_{m}.mem"), [i16(x) for x in q])
            wr(os.path.join(OUT, f"exp_k{suf}_{m}.mem"), [i16(x) for x in k])
            wr(os.path.join(OUT, f"exp_v{suf}_{m}.mem"), [i16(x) for x in v])
            wr(os.path.join(OUT, f"exp_z0{suf}_{m}.mem"), [i16(x) for x in zz])
    he = h["e"][0].reshape(-1)
    wr(os.path.join(OUT, "exp_h.mem"), [i16(x) for x in he])
    for m in mods[1:]:
        wr(os.path.join(OUT, f"exp_h{m}.mem"),
           [i16(x) for x in h[m][0].reshape(-1)])
    for m in mods:
        wr(os.path.join(OUT, f"exp_z{m}.mem"),
           [i16(x) for x in Zp[m][0].reshape(-1)])

    # 布局表：PS 侧 word map 由这里出，不再手抄（_M3 验收口径第 3 条）
    with open(os.path.join(OUT, "wordmap.txt"), "w", newline="\n") as f:
        f.write(f"mode={MODE} mods={','.join(mods)} G={G} T={T} D={D} "
                f"U={U} kvw={KVW}\n")
        for k in sorted(L, key=lambda k: L[k]):
            f.write(f"{k:8s} {L[k]:5d}\n")

    scs = " ".join(f"{k}={sc[k]:.9g}" for k in ("ze", "zo") if k in sc)
    if "za" in sc and "a" in mods:
        scs += f" za={sc['za']:.9g}"
    if "zs" in sc and "s" in mods:
        scs += f" zs={sc['zs']:.9g}"
    wr(os.path.join(OUT, "exp_note.txt"),
       [f"mode={MODE} mods={','.join(mods)}",
        f"{scs} act={sc['act']:.9g} logit={sc['logit']:.9g}",
        f"wbytes={len(wbytes)} nblocks={len(desc)} nins={len(ins)} "
        f"scratch={L['END']}"])

    print(f"[i] 向量写毕：in.mem {len(inlines)} 行，exp_h {he.size}，"
          f"exp_z{mods[0]} {Zp[mods[0]][0].size}")
    print("[i] 布局 " + " ".join(f"{k}={L[k]}" for k in
                                 ("IN_E", "HRE", "HE", "QE", "ZE", "ZPE", "END")))


if __name__ == "__main__":
    main()
