# -*- coding: utf-8 -*-
"""frac_div 的位精确模型 + 校正因子计算（设计 §6 / §7 第 10 项）。

用途：
    1. 由「实测的 ADAU1761 采样率 / 时钟误差」算出要写进 inc 寄存器的 Q32 值；
    2. 在软件侧复现 RTL 的行为（逐拍模拟），用来在没上板时做对拍；
    3. 给出设计 §6 引用的三个数：漂移样本数 / 毫秒 / 256 Hz EEG 点数。

用法：
    python frac_div_model.py                 # 用标称 17,250 ppm
    python frac_div_model.py --ppm -50       # 任意实测值
    python frac_div_model.py --f-in 48828.0  # 直接给实测采样率
"""
import argparse

Q32 = 1 << 32
F_OUT = 48000.0        # 名义网格
F_IN_NOM = 48000.0     # 标称采样率
PPM_DEF = 17250.0      # 设计 §6 引用的实测偏差


def make_inc(f_in, f_out=F_OUT):
    """分频比 f_out/f_in 的 Q32 定点表示（四舍五入）。"""
    return int(round(f_out / f_in * Q32))


def simulate(inc, n_in):
    """逐拍复现 frac_div 的行为，返回 (kept, 每拍 phase 的最后值)。"""
    acc, kept = 0, 0
    for _ in range(n_in):
        s = acc + inc
        if s >> 32:
            acc = s & 0xFFFFFFFF
            kept += 1
        else:
            acc = s
    return kept, acc


def report(f_in, f_out=F_OUT, secs=4.0):
    inc = make_inc(f_in, f_out)
    n_in = int(round(f_in * secs))
    want = int(round(f_out * secs))
    kept, phase = simulate(inc, n_in)
    drift = n_in - kept                       # 不校正时的输入-输出差
    print(f"f_in = {f_in:.3f} Hz   "
          f"偏差 {1e6*(f_in/F_IN_NOM-1):+.1f} ppm   f_out = {f_out:.1f} Hz")
    print(f"  inc = {inc} = 0x{inc:08X}   (Q32)")
    print(f"  实测分频比 {inc/Q32:.9f}，量化误差 "
          f"{1e6*(inc/Q32*f_in/f_out - 1):+.4f} ppm")
    print(f"  {secs:g} s 内输入 {n_in} 拍")
    print(f"  校正后输出 {kept}，目标 {want}，误差 {kept-want:+d} 个样本")
    print(f"  不校正的漂移 = {drift} 个 48 kHz 样本 = "
          f"{drift/f_out*1000:.1f} ms = {drift/f_out*256:.2f} 个 256 Hz EEG 点")
    # 每秒的累积误差
    for s in range(1, int(secs) + 1):
        k, _ = simulate(inc, int(round(f_in * s)))
        print(f"    t={s} s  kept={k:6d}  误差 {k-int(s*f_out):+d}")
    return inc


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--f-in", type=float, default=None,
                    help="实测 ADAU1761 采样率（Hz）；不给则由 --ppm 推")
    ap.add_argument("--ppm", type=float, default=PPM_DEF)
    ap.add_argument("--secs", type=float, default=4.0)
    a = ap.parse_args()
    f_in = a.f_in if a.f_in else F_IN_NOM * (1 + a.ppm * 1e-6)
    report(f_in, secs=a.secs)


if __name__ == "__main__":
    main()
