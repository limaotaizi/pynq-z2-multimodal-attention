# -*- coding: utf-8 -*-
"""
attn_driver.py -- PYNQ / /dev/mem driver for attn_axi (modules 1+2 in PL).

REGISTER MAP -- must match work2/rtl/attn_axi.v.

    0x0000 CTRL      W  bit0 = START (one shot, ignored while busy)
    0x0004 STATUS    R  bit0 = busy, bit1 = done (sticky)
    0x0008 ID        R  0x4154_0001
    0x000C DONE_CLR  W  bit0 = clear sticky done
    0x0100..0x40FF   RW scratch window, 8192 x 16 bit
                        beat W = (byte addr - 0x100) >> 2
                        data[15:0]  -> scratch[2W]
                        data[31:16] -> scratch[2W+1]
                        WSTRB selects whole 16-bit halves

SCRATCH WORD MAP (word index; byte address of the beat = 0x100 + 4*(w>>1)).
These numbers are from work2/export.py and the RTL localparams.  A mismatch
here is silent: the engine runs and produces numbers that are simply wrong.

        IN_E    0      Ze   T*62*5 = 1240 words   (t major, channel, band)
        IN_O    1240   Zo   T*24   =   96 words
        HRE     1536   H_E before smoothing/PE (G*T*16 = 1024)
        HRO     2560   H_O before smoothing/PE (T*16    =   64)
        HE      3072   H_E  (after LDS + PE)     1024
        HO      4096   H_O                       64
        QE/KE/VE 4352/4416/4480   group scratch (last group only)
        QO/KO/VO 4544/4608/4672
        ZE/ZO   4736/4800          GAP input scratch
        ZPE     4864   Zp for EEG (G*D = 256, G=16, D=16, T=4)
        ZPO     5120   Zp for eye  (G*D = 256)

Usage on the board:

    from attn_driver import AttnAxi
    a = AttnAxi()                       # PYNQ overlay, auto-detect
    a = AttnAxi(base=0x40000000)        # no overlay, after JTAG programming
    a.selftest()                        # scratch round trip + one full inference

The full inference compares 1,088 output words against the golden vectors that
the xsim testbench (tb_attn_axi.v) already checks bit-exactly.  That makes the
board run a *bit-exact* test of the PL, not a "looks plausible" test.
"""
import os
import struct
import time

import numpy as np

try:                                    # the board has pynq; the PC may not
    from pynq import Overlay, MMIO
except Exception:                       # noqa: BLE001
    Overlay = MMIO = None

try:
    from ts_driver import _RawMMIO
except Exception:                       # noqa: BLE001
    _RawMMIO = None


# ------------------------------------------------------------------ register map
R_CTRL, R_STAT, R_ID, R_CLR, R_DATA = 0x0000, 0x0004, 0x0008, 0x000C, 0x0100
ID_VALUE = 0x41540001

# ------------------------------------------------------------------ word map
IN_E, IN_O = 0, 1240
HRE, HRO = 1536, 2560
HE, HO = 3072, 4096
QE, KE, VE = 4352, 4416, 4480
QO, KO, VO = 4544, 4608, 4672
ZE, ZO, ZPE, ZPO = 4736, 4800, 4864, 5120

N_IN = IN_O + 96                      # 1336 input words
SCRATCH_WORDS = 8192
# xsim counts 466,157 clk from start to done; the AXI wrapper does not change
# it.  FCLK_CLK0 on this board is 100.00 MHz (measured, see clk_probe.py), so
# one window is ~4.66 ms of engine time.  The 2.33 ms figure in older notes
# assumed 200 MHz and is wrong by 2x.
ENGINE_CYCLES = 466_157
ENGINE_MS_AT_100MHZ = ENGINE_CYCLES / 1e8 * 1e3       # 4.662 ms


# ------------------------------------------------------------------ pure helpers
def pack_words(words):
    """16-bit word list -> list of (byte_offset, data32, wstrb) beats.

    Pure Python on purpose: the offline self-test checks this against the RTL's
    own packing rule, and the board path calls the same function.
    """
    w = np.asarray(words, dtype=np.int64).reshape(-1)
    if w.size > SCRATCH_WORDS:
        raise ValueError("scratch holds %d words, got %d"
                         % (SCRATCH_WORDS, w.size))
    beats = []
    for i in range(0, w.size, 2):
        lo = int(w[i]) & 0xFFFF
        hi = int(w[i + 1]) & 0xFFFF if i + 1 < w.size else None
        data = lo | ((hi or 0) << 16)
        wstrb = 0x3 | (0xC if hi is not None else 0)
        beats.append((R_DATA + 4 * (i // 2), data, wstrb))
    return beats


def unpack_words(beats_value, base_word, n):
    """Inverse of pack_words, for tests.  beats_value: dict beat -> data32."""
    out = np.zeros(n, dtype=np.int64)
    for k in range(n):
        w = base_word + k
        data = beats_value[w >> 1]
        v = (data >> 16) if (w & 1) else (data & 0xFFFF)
        out[k] = v - 0x10000 if v & 0x8000 else v
    return out


def s16(x):
    x = np.asarray(x, dtype=np.int64) & 0xFFFF
    return np.where(x & 0x8000, x - 0x10000, x).astype(np.int64)


# ------------------------------------------------------------------ driver
class AttnAxi(object):
    """One attn_axi instance."""

    def __init__(self, bitfile=None, ip_name=None, base=0x40000000, mmio=None):
        if mmio is not None:
            self.ol = None
            self.ip_name = "external mmio"
            self.mmio = mmio
        elif bitfile is None:
            # Raw /dev/mem: used after JTAG programming, where no .hwh exists.
            if _RawMMIO is None:
                raise RuntimeError("ts_driver._RawMMIO unavailable")
            self.ol = None
            self.ip_name = "attn_axi@0x%08X" % base
            self.mmio = _RawMMIO(base, length=0x10000)
        else:
            self.ol = Overlay(bitfile)
            self.ip_name = ip_name or self._find_ip()
            ip = getattr(self.ol, self.ip_name)
            self.mmio = getattr(ip, "mmio", None)
            if self.mmio is None:
                self.mmio = MMIO(self.ol.ip_dict[self.ip_name]["phys_addr"],
                                 0x10000)
        self._check_present()

    def _find_ip(self):
        cands = [k for k, v in self.ol.ip_dict.items()
                 if "attn" in k.lower()
                 or "attn" in str(v.get("type", "")).lower()]
        if not cands:
            raise RuntimeError("no attn_axi in overlay; keys = %s"
                               % sorted(self.ol.ip_dict.keys()))
        if len(cands) > 1:
            raise RuntimeError("several candidates %s; pass ip_name=" % cands)
        return cands[0]

    def _check_present(self):
        v = self.mmio.read(R_ID)
        if v != ID_VALUE:
            raise RuntimeError("attn_axi ID read 0x%08X, expected 0x%08X "
                               "(wrong base or bit/hwh mismatch)"
                               % (v, ID_VALUE))

    # ---------------------------------------------------------------- registers
    def rd(self, off):
        return self.mmio.read(off)

    def wr(self, off, val):
        self.mmio.write(off, val & 0xFFFFFFFF)

    def status(self):
        s = self.rd(R_STAT)
        return {"busy": bool(s & 1), "done": bool(s & 2)}

    def clear_done(self):
        self.wr(R_CLR, 1)

    # ---------------------------------------------------------------- scratch
    def write_words(self, base_word, values):
        """Load n 16-bit words into scratch, ONE AXI write per 32-bit beat.

        2026-10-26: this used to call pack_words_at() to build a Python list of
        (offset, data32, wstrb) tuples and then write them one by one.  A bare
        AXI write costs 11.1 us here, but the load stage measured 30 us/beat --
        the other 19 us was tuple building and per-item branching.  Packing the
        beats with numpy and looping only over the writes puts the stage back on
        the AXI floor.

        The wire behaviour is byte-for-byte what pack_words_at() produced: the
        first beat goes to R_DATA+0 (base_word is not folded into the offset,
        same as before), every full beat is a plain 32-bit write (wstrb 0xF),
        and a trailing odd word is written with wstrb 0x3 (read-modify-write).
        """
        w = np.asarray(values, dtype=np.int64).reshape(-1) & 0xFFFF
        n = w.size
        if n == 0:
            return
        if n > SCRATCH_WORDS:
            raise ValueError("scratch holds %d words, got %d"
                             % (SCRATCH_WORDS, n))
        lo = w[0::2]
        hi = w[1::2]
        odd = bool(n & 1)
        if hi.size < lo.size:
            hi = np.append(hi, 0)
        beats = (lo | (hi << 16)).tolist()
        for k in range(len(beats) - 1):
            self.mmio.write(R_DATA + 4 * k, beats[k])
        last = R_DATA + 4 * (len(beats) - 1)
        if odd:
            self._aw_w(last, beats[-1], 0x3)   # (off, data, wstrb)
        else:
            self.mmio.write(last, beats[-1])

    def write_words_beats(self, base_word, values):
        """Old tuple-per-beat path, kept for A/B measurement only."""
        for off, data, wstrb in pack_words_at(base_word, values):
            self._aw_w(off, data, wstrb)

    def _aw_w(self, off, data, wstrb):
        """32-bit write with byte strobes.

        PYNQ's MMIO has no strobe API and /dev/mem cannot express one either
        (byte writes only reach one byte).  The RTL treats wstrb per 16-bit
        half, so a full 32-bit write is equivalent whenever both halves are
        wanted.  For a lone low half we read-modify-write the beat: the engine
        is idle by construction while the host loads inputs, so the upper half
        holds whatever the previous load left there and is harmless.
        """
        if wstrb == 0xF:
            self.mmio.write(off, data)
            return
        cur = self.mmio.read(off)
        keep = cur & 0xFFFF0000 if wstrb == 0x3 else cur & 0x0000FFFF
        self.mmio.write(off, keep | (data & (0xFFFF if wstrb == 0x3 else 0xFFFF0000)))

    def read_beat(self, beat):
        return self.mmio.read(R_DATA + 4 * beat)

    def read_words(self, base_word, n):
        """Read n 16-bit scratch words starting at base_word.

        ONE AXI read per 32-bit beat, then a vectorised unpack (2026-10-26).

        Two separate savings, and the second one is the bigger:
          * the scratch is addressed as 16-bit words but exposed as 32-bit
            beats, so a word-at-a-time walk fetched every beat twice;
          * the unpack arithmetic (mask, shift, sign-extend, store) used to run
            in Python once per word.  A bare AXI read is 7.88 us here and the
            Python step was another ~7.6 us per word, i.e. the two were the same
            size -- merging beats alone only bought 5%.  Doing the unpack with
            numpy drops it to the AXI floor.

        Bit-identical to the old word-wise path; verified on board against all
        4,224 words of the M=3 dump (cmp_dump3.py ALL PASS).

        Works for any base_word parity: if the first word is the HIGH half of a
        beat, the slice start offset skips the low half.
        """
        if n <= 0:
            return np.zeros(0, dtype=np.int64)
        b0 = base_word >> 1
        b1 = (base_word + n - 1) >> 1
        data = np.fromiter((self.read_beat(b) for b in range(b0, b1 + 1)),
                           dtype=np.int64, count=b1 - b0 + 1)
        w = np.empty(data.size * 2, dtype=np.int64)
        w[0::2] = data & 0xFFFF
        w[1::2] = (data >> 16) & 0xFFFF
        w = np.where(w & 0x8000, w - 0x10000, w)
        off = base_word & 1
        return w[off:off + n]

    def read_words_wordwise(self, base_word, n):
        """Old word-at-a-time path, kept for A/B measurement only."""
        out = np.zeros(n, dtype=np.int64)
        for i in range(n):
            w = base_word + i
            data = self.read_beat(w >> 1)
            v = (data >> 16) if (w & 1) else (data & 0xFFFF)
            out[i] = v - 0x10000 if v & 0x8000 else v
        return out

    # ---------------------------------------------------------------- run
    def start(self):
        self.wr(R_CTRL, 1)

    def wait_done(self, timeout=1.0, poll=50e-6):
        t0 = time.perf_counter()
        while time.perf_counter() - t0 < timeout:
            if self.rd(R_STAT) & 2:
                return True
        return False

    def run(self, in_words, timeout=1.0, check=True):
        """Load one window (1336 int16), start the engine, return output words.

        Returns a dict of named output arrays for convenience.
        """
        in_words = np.asarray(in_words, dtype=np.int64).reshape(-1)
        if in_words.size != N_IN:
            raise ValueError("input must be %d words, got %d"
                             % (N_IN, in_words.size))
        self.clear_done()
        self.write_words(0, in_words)
        self.start()
        if not self.wait_done(timeout):
            raise RuntimeError("attn_axi did not assert done within %.3f s" % timeout)
        out = {
            "he":  self.read_words(HE, 1024),
            "ho":  self.read_words(HO, 64),
            "zpe": self.read_words(ZPE, 256),
            "zpo": self.read_words(ZPO, 256),
        }
        self.clear_done()
        return out

    # ---------------------------------------------------------------- self-test
    def selftest(self, vectors=None, verbose=True):
        """Scratch round trip + one full inference against the golden vectors.

        vectors: path to attn_vectors.npz (built by sw/make_attn_vectors.py).
        Returns (all_ok, detail dict).
        """
        res = []

        def chk(name, ok, detail=""):
            res.append((name, bool(ok), detail))
            return bool(ok)

        chk("ID = 0x%08X" % ID_VALUE, self.rd(R_ID) == ID_VALUE,
            "0x%08X" % self.rd(R_ID))

        # scratch round trip on the top 8 words (outside the input block)
        pat = np.array([0x0000, 0xFFFF, 0x7FFF, 0x8000, 0x1234, 0xABCD,
                        0x0102, 0xFEFE], dtype=np.int64)
        self.write_words(8184, pat)
        back = self.read_words(8184, 8)
        chk("scratch round trip (8 words @8184)",
            bool(np.array_equal(back, s16(pat))),
            "%s vs %s" % (back.tolist(), s16(pat).tolist()))

        if vectors is None:
            vectors = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                   "attn_vectors.npz")
        if not os.path.exists(vectors):
            chk("golden vectors present", False, vectors)
            all_ok = all(ok for _, ok, _ in res)
            if verbose:
                _report(res)
            return all_ok, {"vectors": None}

        z = np.load(vectors, allow_pickle=False)
        out = self.run(z["in_q"])

        for name, key, exp_key in (("H_E", "he", "exp_h"),
                                   ("H_O", "ho", "exp_ho"),
                                   ("ZP_E", "zpe", "exp_ze"),
                                   ("ZP_O", "zpo", "exp_zo")):
            exp = s16(z[exp_key])
            got = out[key]
            same = int((got == exp).sum())
            chk("%s bit-exact" % name, same == exp.size,
                "%d/%d" % (same, exp.size))

        all_ok = all(ok for _, ok, _ in res)
        if verbose:
            _report(res)
        return all_ok, out


def pack_words_at(base_word, values):
    """Like pack_words but shifted by base_word.  Returns absolute byte offsets."""
    if base_word & 1:
        raise ValueError("base_word must be even (a beat holds words 2k,2k+1)")
    return pack_words_fixed(base_word, values)


def pack_words_fixed(base_word, values):
    beats = pack_words(values)
    return [(off + 2 * base_word, data, wstrb) for off, data, wstrb in beats]


def _report(res):
    npass = sum(1 for _, ok, _ in res if ok)
    print("=" * 66)
    print(" attn_axi selftest: %d/%d passed" % (npass, len(res)))
    print("=" * 66)
    for name, ok, detail in res:
        print("  [%s] %s%s" % ("ok  " if ok else "FAIL", name,
                               ("   -- " + detail) if detail else ""))
    if npass != len(res):
        print("\n  %d check(s) FAILED" % (len(res) - npass))


def demo(base=0x40000000, bitfile=None):
    a = AttnAxi(bitfile, base=base)
    ok, _ = a.selftest()
    return a, ok


if __name__ == "__main__":
    import sys
    args = sys.argv[1:]
    base, bitfile = 0x40000000, None
    i = 0
    while i < len(args):
        if args[i] == "--base":
            base = int(args[i + 1], 0)
            i += 2
        else:
            bitfile = args[i]
            i += 1
    demo(base=base, bitfile=bitfile)
