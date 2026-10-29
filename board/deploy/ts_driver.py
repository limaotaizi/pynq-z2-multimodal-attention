# -*- coding: utf-8 -*-
"""
ts_driver.py -- PYNQ-side driver for the global timestamp + tau compensation unit.

    Overlay('ts.bit')          -> the bitstream built by ../build_ts.tcl
    TsTop('ts.bit')            -> this class

The unit is one free-running counter shared by all four modalities. Every
sample-arrival strobe captures the counter on the strobe edge, and the
captured value is pushed through one shared FIFO to the PS. Reading a
timestamp therefore costs nothing in *time* -- it costs time only to *deliver*
it. That distinction is the entire point of the design: on the PS side, the
delay between "the event happened" and "the timestamp was taken" is an
operating-system scheduling delay (tens of microseconds, non-deterministic);
here it is one flop (one clock period, deterministic).

  CLOCK: FCLK_CLK0 on this board measures **100.000 MHz**, not 200. Two
  independent methods agree (see fclk_meas.py): the 48-bit counter advances
  200,214,826 counts in 2.00208 s, and a div=2e6 internal strobe yields
  100.00 Hz. The IO PLL here is 500 MHz, so SLCR FPGA0_CLK_CTRL already sits
  at DIVISOR1=5 (=100 MHz) and 200 MHz is not reachable (500/2=250,
  500/3=166.7). Everything below therefore uses CLK_HZ = 100e6, i.e. one
  count = 10 ns. If a future FSBL ever delivers a different FCLK, call
  set_clk_hz(detect_fclk_hz(ts)) before trusting any seconds conversion.

REGISTER MAP -- must match rtl/ts_top.v. If you change one, change both.

    0x00 CTRL         RW  [0]=run [1]=clr_cnt(自清) [2]=fifo_rst(自清)
    0x04 STATUS       RO  [0]=fifo_empty [1]=fifo_full [2]=run [15:8]=level
    0x08 T_NOW_L      RO  counter [31:0]
    0x0C T_NOW_H      RO  counter [47:32]
    0x10 FIFO_DATA_L  RO  **reading this pops the FIFO**; returns t[31:0]
    0x14 ENQ_COUNT    RO  total samples ever timestamped
    0x18 FIFO_DATA_H  RO  {mod[1:0], t[47:32]} of the LAST pop; does not pop
    0x20+8m TMm_L     RO  last tau-compensated t_m[31:0] for modality m
    0x24+8m TMm_H     RO  t_m[47:32]
    0x40+4m TAUm      RW  tau for modality m, in COUNTS of 10 ns
    0x50 OVF_STICKY   RO/W1C  per-modality "a sample was lost"
    0x54 UF_STICKY    RO/W1C  per-modality "tau > t"
    0x5C SRC          RW  bit m: 1 = internal strobe generator, 0 = external pin
    0x60+4m DIVm      RW  internal strobe divider (FCLK counts: 100e6/div Hz)
    0x70+4m EPSm      RW  epsilon_m = the delay CONFIDENCE bound, same count unit
                          (design 10_ sec.3.4: TAUm + EPSm together = 2M=8 time
                           registers).  Stored only -- never subtracted from t.

Two things that will bite you if you forget them:

  (1) Reading 0x10 when the FIFO is EMPTY does not pop -- it returns whatever
      the read pointer happens to be sitting on. Always check STATUS first.
      pop() does. Nothing else should touch 0x10.

  (2) T_NOW_L / T_NOW_H are two separate 32-bit reads while the counter keeps
      running. Read H, then L, then H again; if H changed, retry. t_now()
      does. But for MEASUREMENT never use these -- use the FIFO. The FIFO
      timestamps on the strobe edge; T_NOW is read whenever software gets
      around to it, so it measures the AXI round trip, not the event.
"""

import mmap
import struct
import time

try:                                    # the board has pynq; the PC may not
    from pynq import Overlay, MMIO
except Exception:                       # noqa: BLE001
    Overlay = MMIO = None


class _RawMMIO(object):
    """Minimal /dev/mem window -- lets this driver run without an Overlay.

    Needed when the PL was configured over JTAG instead of by PYNQ: there is
    no .hwh on the board and no need for one, because the address map is a
    property of the bitstream. Must run as root.
    """

    def __init__(self, base, length=0x1000):
        self._f = open("/dev/mem", "r+b", buffering=0)
        self._m = mmap.mmap(self._f.fileno(), length, mmap.MAP_SHARED,
                            mmap.PROT_READ | mmap.PROT_WRITE, offset=base)

    def read(self, off):
        return struct.unpack_from("<I", self._m, off)[0]

    def write(self, off, val):
        struct.pack_into("<I", self._m, off, val & 0xFFFFFFFF)


# FPGA0_CLK_CTRL in the SLCR. JTAG programming does not touch it, and neither
# does the bitstream: the PS divider is set by the FSBL/BOOT.BIN.
#
# 2026-10-21, measured twice by independent PL methods (fclk_meas.py): this
# board runs FCLK_CLK0 at 100.000 MHz. The register reads DIVISOR1=5,
# SRCSEL=0 (IO PLL) -> the IO PLL is 500 MHz, not the 1000 assumed everywhere
# else in this project. Writing 0x501 is therefore a no-op, and 200 MHz is
# unreachable from a 500 MHz PLL (500/2=250, 500/3=166.7). Do not call
# set_fclk0_mhz(200) expecting it to work.
SLCR_FPGA0_CLK_CTRL = 0xF8000170


def _fclk_divisor():
    """Current DIVISOR1 field of FPGA0_CLK_CTRL (the FCLK0 divider)."""
    m = _RawMMIO(SLCR_FPGA0_CLK_CTRL & ~0xFFF)
    off = SLCR_FPGA0_CLK_CTRL & 0xFFF
    return (m.read(off) >> 8) & 0x3F


def set_fclk0_mhz(mhz=100, pll_mhz=500.0, write=False):
    """Report FCLK_CLK0 as (mhz, source). **Does not write unless write=True.**

    This used to write the divider and was called by eight on-board scripts
    as `set_fclk0_mhz(200)`. Two things made that unsafe, so the default is
    now read-only:

      1. On this board the IO PLL is 500 MHz, so asking for 200 computes
         divisor 2 -> **250 MHz**, which the design was never signed off for.
      2. PYNQ's `Clocks` class is unusable on this image anyway -- it raises
         `RuntimeError: No Devices Found` (xrt_device), so the write only ever
         happened through the raw-SLCR fallback, silently.

    Callers that just want to know the clock get the truth here. Anything that
    really means to change it must pass write=True and own the consequence.
    """
    div = _fclk_divisor()
    hz = pll_mhz / float(div) if div else 0.0
    if not write:
        return hz, ("readback: DIVISOR1=%d, IO PLL %.0f MHz (not written)"
                    % (div, pll_mhz))
    want = int(round(pll_mhz / float(mhz)))
    if not (1 <= want <= 63):
        raise ValueError("divisor %d out of range" % want)
    m = _RawMMIO(SLCR_FPGA0_CLK_CTRL & ~0xFFF)
    off = SLCR_FPGA0_CLK_CTRL & 0xFFF
    # DIVISOR1 [13:8], SRCSEL0 [5:4] = 00 (IO PLL), CLKACT0 [0] = 1
    m.write(off, (want << 8) | 0x1)
    return pll_mhz / float(_fclk_divisor() or 1), "SLCR raw (IO PLL %.0f MHz)" % pll_mhz

# --------------------------------------------------------------------------- #
#  Constants
# --------------------------------------------------------------------------- #

CLK_HZ       = 100_000_000             # measured, not assumed -- see docstring
NS_PER_COUNT = 10                      # 1e9 / 100e6
COUNTS_PER_S = CLK_HZ                  # 1 count = 10 ns

# TAUm is 32 bits wide -> the largest representable tau.
TAU_MAX_S    = (2 ** 32 - 1) / float(COUNTS_PER_S)      # 42.9497... s
TW           = 48
T_WRAP_S     = (2 ** TW) / float(COUNTS_PER_S)          # 32.58 days


def set_clk_hz(hz):
    """Rescale every counts<->seconds conversion to a measured FCLK.

    Only needed if a future board/FSBL actually delivers something other than
    100 MHz. Recomputes the derived constants in place so that stale module
    globals cannot be used by accident afterwards.
    """
    global CLK_HZ, NS_PER_COUNT, COUNTS_PER_S, TAU_MAX_S, T_WRAP_S
    if hz <= 0:
        raise ValueError("hz must be positive, got %r" % (hz,))
    CLK_HZ = int(hz)
    NS_PER_COUNT = 1e9 / CLK_HZ
    COUNTS_PER_S = CLK_HZ
    TAU_MAX_S = (2 ** 32 - 1) / float(COUNTS_PER_S)
    T_WRAP_S = (2 ** TW) / float(COUNTS_PER_S)
    return CLK_HZ

# Modality index -- fixed by the register map, do not reorder.
MOD_EEG, MOD_EYE, MOD_GSR, MOD_AU = 0, 1, 2, 3
MOD_NAMES = ("eeg", "eye", "gsr", "au")

# Reset defaults of DIVm in rtl/ts_top.v:106-109. Those constants and their
# comments were written for a 200 MHz FCLK, so on this 100 MHz board the
# power-on rates are HALF what plan-3 sec.2.1 asks for: 128/75/25/20 Hz.
# Nothing scientific depends on this -- the generator exists to demonstrate
# the datapath with no sensors attached, and real use takes external pins --
# but do not quote the reset defaults as "256/150/50/40 Hz" on this board.
# DIV_DEFAULT_100MHZ below is what gives the intended rates at 100 MHz.
DIV_DEFAULT = (781250, 1333333, 4000000, 5000000)       # 128/75/25/20 Hz here
DIV_DEFAULT_100MHZ = (390625, 666667, 2000000, 2500000)  # 256/150/50/40 Hz

# Register addresses
R_CTRL, R_STATUS, R_TNOW_L, R_TNOW_H = 0x00, 0x04, 0x08, 0x0C
R_FIFO_L, R_ENQ, R_FIFO_H            = 0x10, 0x14, 0x18
R_TAU0, R_OVF, R_UF, R_SRC, R_DIV0   = 0x40, 0x50, 0x54, 0x5C, 0x60
R_EPS0                               = 0x70      # design 10_ sec.3.4: tau + eps = 2M=8

CTRL_RUN, CTRL_CLR_CNT, CTRL_FIFO_RST = 1, 2, 4


def counts_to_seconds(c):
    """Counts (10 ns LSB) -> seconds. Signed, because t - tau can go negative."""
    return c / float(COUNTS_PER_S)


def seconds_to_counts(s):
    """Seconds -> counts, rounded. Raises if it will not fit in a 32-bit TAUm."""
    c = int(round(s * COUNTS_PER_S))
    if not (0 <= c <= 0xFFFFFFFF):
        raise ValueError(
            "tau = %.6f s -> %d counts does not fit in 32 bits (max %.4f s)"
            % (s, c, TAU_MAX_S))
    return c


class TsTop(object):
    """Driver for one ts_top instance in a PYNQ overlay.

    Parameters
    ----------
    bitfile : str
        Path to ts.bit. ts.hwh must sit beside it with the same base name --
        that is how PYNQ finds the hardware description.
    ip_name : str, optional
        Overlay key of the IP. Normally auto-detected; pass it explicitly if
        the overlay contains more than one candidate.
    """

    def __init__(self, bitfile=None, ip_name=None, base=0x40000000,
                 **overlay_kwargs):
        # bitfile=None -> raw /dev/mem at `base`. Used after JTAG programming.
        if bitfile is None:
            self.ol = None
            self.ip_name = "ts_top@0x%08X" % base
            self.mmio = _RawMMIO(base)
        else:
            self.ol = Overlay(bitfile, **overlay_kwargs)
            self.ip_name = ip_name or self._find_ip()
            # DefaultIP.mmio is what PYNQ binds to an IP it has no specific
            # driver for, which is our case. Fall back to an explicit MMIO if
            # the overlay did not bind one.
            ip = getattr(self.ol, self.ip_name)
            self.mmio = getattr(ip, "mmio", None)
            if self.mmio is None:
                self.mmio = MMIO(
                    self.ol.ip_dict[self.ip_name]["phys_addr"], 0x1000)
        # Everything starts stopped: CTRL resets to 0.
        self._check_present()

    # ------------------------------------------------------------------ setup

    def _find_ip(self):
        cands = [k for k, v in self.ol.ip_dict.items()
                 if "ts_top" in k.lower()
                 or "ts_top" in str(v.get("type", "")).lower()]
        if not cands:
            raise RuntimeError(
                "no ts_top instance in the overlay; ip_dict keys = %s"
                % sorted(self.ol.ip_dict.keys()))
        if len(cands) > 1:
            raise RuntimeError("several ts_top instances: %s; pass ip_name="
                               % cands)
        return cands[0]

    def _check_present(self):
        """Cheap liveness probe: the unused-register read returns 0xDEADBEEF.

        This catches the two ways a bring-up actually fails -- the .hwh does not
        match the .bit (wrong base address), or the PL is not configured at all
        (AXI times out, which PYNQ raises on). Without it the first symptom is a
        nonsensical timestamp minutes later.
        """
        # 0x1C -- NOT 0x7C. 0x7C used to be the unmapped hole, but E4 (design
        # 10_ sec.3.4) put EPS3 there, so the hole moved to 0x1C. Both the old
        # and the new bitstream leave 0x1C unmapped, so this probe is valid
        # against either.
        v = self.mmio.read(0x1C)          # unmapped by design
        if v != 0xDEADBEEF:
            raise RuntimeError(
                "ts_top not responding as expected: read(0x1C) = 0x%08X "
                "(expected 0xDEADBEEF). Check that ts.hwh matches ts.bit."
                % v)

    # -------------------------------------------------------------- registers

    def rd(self, off):
        return self.mmio.read(off)

    def wr(self, off, val):
        self.mmio.write(off, val & 0xFFFFFFFF)

    # ------------------------------------------------------------- run control

    def start(self):
        """Start the counter (and, with SRC set, the internal strobe generator)."""
        self.wr(R_CTRL, CTRL_RUN)

    def stop(self):
        self.wr(R_CTRL, 0)

    def reset_counter(self):
        """Zero the free-running counter. Self-clearing pulse in the RTL."""
        self.wr(R_CTRL, (self.rd(R_CTRL) & ~CTRL_CLR_CNT) | CTRL_CLR_CNT)

    def reset_fifo(self):
        """Flush the timestamp FIFO and the per-modality capture slots."""
        self.wr(R_CTRL, (self.rd(R_CTRL) & ~CTRL_FIFO_RST) | CTRL_FIFO_RST)

    def is_running(self):
        return bool(self.rd(R_STATUS) & 0x4)

    # ------------------------------------------------------------------- tau

    def set_tau(self, mod, seconds):
        """Write tau_m. Units on the wire are counts; callers use seconds.

        tau is subtracted from the raw timestamp, so it means "this modality's
        data is late by tau": t_m = t - tau_m moves the sample back to when the
        physiological event is believed to have happened.

        Note that tau is *not* a number this project can currently justify from
        the data -- see README_PL.md and the plan-3 sec.3.2 discussion. Reading
        a tau register back proves the register works; it does not validate the
        value in it.
        """
        if mod not in (0, 1, 2, 3):
            raise ValueError("mod must be 0..3, got %r" % (mod,))
        self.wr(R_TAU0 + 4 * mod, seconds_to_counts(seconds))

    def get_tau(self, mod):
        return counts_to_seconds(self.rd(R_TAU0 + 4 * mod))

    def set_all_tau(self, taus):
        """taus: sequence of four values in seconds, ordered eeg/eye/gsr/au."""
        for m, s in enumerate(taus):
            self.set_tau(m, s)

    def get_all_tau(self):
        return tuple(self.get_tau(m) for m in range(4))

    # ------------------------------------------------------------------- eps
    # Design 10_ sec.3.4 asks for 2M=8 time registers per modality: the device
    # delay tau_m AND its confidence bound eps_m. eps is an error bar, not a
    # correction -- it is stored and read back, never subtracted from t. That
    # is the whole difference from tau: tau is subtracted by tau_comp, eps is
    # not, but neither one is removed from the physical delay fed to the model.

    def set_eps_counts(self, mod, counts):
        """Write eps_m in raw counts (10 ns LSB). No units conversion."""
        if mod not in (0, 1, 2, 3):
            raise ValueError("mod must be 0..3, got %r" % (mod,))
        c = int(counts)
        if not (0 <= c <= 0xFFFFFFFF):
            raise ValueError("eps = %d counts does not fit in 32 bits" % c)
        self.wr(R_EPS0 + 4 * mod, c)

    def get_eps_counts(self, mod):
        return self.rd(R_EPS0 + 4 * mod)

    def set_eps(self, mod, seconds):
        self.set_eps_counts(mod, seconds_to_counts(seconds))

    def get_eps(self, mod):
        return counts_to_seconds(self.get_eps_counts(mod))

    def get_all_eps(self):
        return tuple(self.get_eps(m) for m in range(4))

    def tau_table(self):
        """The starting point proposed in plan-3 sec.3.2, in seconds."""
        return (0.1, 0.3, 2.0, 0.5)        # eeg, eye, gsr, au

    # -------------------------------------------------- internal strobe source

    def set_src(self, bits):
        """Select the strobe source per modality. bit m = 1 -> internal generator.

        With no sensors attached this must be 0xF, otherwise nothing strobes and
        the FIFO stays empty forever. That failure mode looks exactly like a
        broken design, so check SRC early when something seems dead.
        """
        self.wr(R_SRC, bits & 0xF)

    def get_src(self):
        return self.rd(R_SRC) & 0xF

    def set_div(self, mod, counts):
        """Set the internal strobe divider for one modality (FCLK counts).

        A divider of N produces a strobe every N cycles, i.e. CLK_HZ/N Hz
        (100e6/N on this board). 0 stops that channel. Note the RTL fires when
        cnt+1 >= div, so div=1 strobes every cycle -- dividing by N gives
        exactly N if you count the edge-to-edge distance, which is what the
        jitter test checks.
        """
        if mod not in (0, 1, 2, 3):
            raise ValueError("mod must be 0..3, got %r" % (mod,))
        self.wr(R_DIV0 + 4 * mod, counts & 0xFFFFFFFF)

    def get_div(self, mod):
        return self.rd(R_DIV0 + 4 * mod)

    def set_div_hz(self, mod, hz):
        """Convenience: ask for a frequency instead of a count."""
        if hz <= 0:
            self.set_div(mod, 0)
            return
        n = int(round(CLK_HZ / float(hz)))
        self.set_div(mod, max(1, min(n, 0xFFFFFFFF)))

    def div_actual_hz(self, mod):
        n = self.get_div(mod)
        return 0.0 if n == 0 else CLK_HZ / float(n)

    # ------------------------------------------------------------------ status

    def status(self):
        s = self.rd(R_STATUS)
        return {
            "empty": bool(s & 0x1),
            "full":  bool(s & 0x2),
            "run":   bool(s & 0x4),
            "level": (s >> 8) & 0xFF,
        }

    def enq_count(self):
        """Samples successfully timestamped since the last FIFO reset."""
        return self.rd(R_ENQ)

    def ovf_sticky(self):
        """Which modalities lost a sample (sticky until cleared).

        Set when a modality's previous capture had not been read out before the
        next one arrived, or when the FIFO was full. If this is non-zero during
        a measurement, the measurement is not trustworthy -- report it, do not
        quietly drop the samples.
        """
        return self.rd(R_OVF) & 0xF

    def clear_ovf(self, mask=0xF):
        self.wr(R_OVF, mask & 0xF)

    def uf_sticky(self):
        """Which modalities were given tau > t, i.e. a timestamp before zero."""
        return self.rd(R_UF) & 0xF

    def clear_uf(self, mask=0xF):
        self.wr(R_UF, mask & 0xF)

    # ------------------------------------------------------------- timestamps

    def t_now(self):
        """Coherent 48-bit read of the free-running counter, in counts.

        Read H, L, H and retry if H moved -- the counter can carry between the
        two reads, which would otherwise yield a value 2**32 counts (42.9 s at
        100 MHz) wrong. Retries are bounded: the carry happens once per 42.9 s,
        so this essentially never loops.
        """
        for _ in range(8):
            hi = self.rd(R_TNOW_H) & 0xFFFF
            lo = self.rd(R_TNOW_L)
            hi2 = self.rd(R_TNOW_H) & 0xFFFF
            if hi == hi2:
                return (hi << 32) | lo
        raise RuntimeError("counter carried on every retry -- counter running?")

    def t_now_s(self):
        return counts_to_seconds(self.t_now())

    def pop(self):
        """Pop one (mod, ts_counts) from the FIFO, or None if empty.

        Race-free by construction: the hardware only pushes, and software is the
        only thing that pops, so once STATUS says non-empty the head cannot
        vanish before we read it.
        """
        if self.rd(R_STATUS) & 0x1:
            return None
        lo = self.rd(R_FIFO_L)             # this read is what pops
        hi = self.rd(R_FIFO_H)             # {mod[1:0], t[47:32]} of the pop just done
        # The RTL packs this as {14'h0, mod, t[47:32]}, so it is 18 significant
        # bits in a 32-bit word -- never above 0x3FFFF.
        mod = (hi >> 16) & 0x3
        return mod, ((hi & 0xFFFF) << 32) | lo

    def pop_s(self):
        """Like pop() but converts the timestamp to seconds."""
        r = self.pop()
        return None if r is None else (r[0], counts_to_seconds(r[1]))

    def drain(self, max_n=None, timeout=0.0, poll_s=1e-4):
        """Pop everything currently available.

        Returns a list of (mod, counts) sorted in pop order (which is FIFO
        order). Stops when the FIFO is empty, after max_n samples, or after
        `timeout` seconds of continuous draining have elapsed.
        """
        out, t0 = [], time.perf_counter()
        while max_n is None or len(out) < max_n:
            r = self.pop()
            if r is None:
                if timeout <= 0.0 or (time.perf_counter() - t0) > timeout:
                    break
                time.sleep(poll_s)
                continue
            out.append(r)
        return out

    def tm(self, mod):
        """The most recent tau-compensated timestamp for one modality, in counts."""
        lo = self.rd(0x20 + 8 * mod)
        hi = self.rd(0x24 + 8 * mod) & 0xFFFF
        return (hi << 32) | lo

    def tm_s(self, mod):
        return counts_to_seconds(self.tm(mod))

    # ------------------------------------------------------------ self-test

    def selftest(self, n=64):
        """Run the checks that catch a bad build, on the real hardware.

        Returns a list of (name, ok, detail). Prints a table and raises nothing,
        so the caller decides what a failure means. Roughly mirrors the 60
        checks in ../model/ts_model.py, but these exercise real silicon:
        mostly they catch constraint/pin/clock mistakes that simulation cannot.
        """
        res = []

        def chk(name, ok, detail=""):
            res.append((name, bool(ok), detail))
            return bool(ok)

        # -- liveness (already done in __init__, repeat for the record) -------
        chk("unmapped read = 0xDEADBEEF", self.rd(0x1C) == 0xDEADBEEF,
            "0x%08X" % self.rd(0x1C))

        # -- register round trip ---------------------------------------------
        for mod in range(4):
            for s in (0.0, 1.0, 2.5):
                self.set_tau(mod, s)
                got = self.get_tau(mod)
                chk("tau[%d]=%.1fs round trip" % (mod, s), abs(got - s) < 1e-6,
                    "read back %.9f s" % got)
        self.set_tau(0, 0.1)
        chk("tau[0]=0.1s -> 10000000 counts (100 MHz)", self.rd(R_TAU0) == 10000000,
            "%d" % self.rd(R_TAU0))
        try:
            self.set_tau(0, TAU_MAX_S * 2)
            chk("tau overflow rejected", False, "no exception raised")
        except ValueError:
            chk("tau overflow rejected", True, "")
        self.set_tau(0, 0.0)

        # -- eps registers (E4): the second half of the 2M=8 group ------------
        # One value per magnitude class from sec.3.3 (e ~us, o/a ~10-40 ms,
        # s ~1 s), in counts of 10 ns. These are exact integers, so the round
        # trip is compared without a float tolerance.
        # NOTE: "eps reads 0 out of reset" is deliberately NOT checked here --
        # there is no register reset available from the PS, so it is only true
        # on a freshly programmed PL and would make this test non-idempotent.
        # Check it once, right after programming, before running anything else.
        eps_vals = (100, 2_000_000, 4_000_000, 100_000_000)
        for m, v in enumerate(eps_vals):
            self.set_eps_counts(m, v)
            chk("eps[%d]=%d counts round trip" % (m, v),
                self.get_eps_counts(m) == v, "%d" % self.get_eps_counts(m))
        got = [self.get_eps_counts(m) for m in range(4)]
        chk("eps[0..3] hold independent values", got == list(eps_vals), str(got))
        # The two banks must not alias: tau and eps share the wstrb write path.
        self.set_tau(0, 0.1)
        chk("writing TAU0 leaves EPS1 alone", self.get_eps_counts(1) == 2_000_000,
            "%d" % self.get_eps_counts(1))
        self.set_eps_counts(0, 12345)
        chk("writing EPS0 leaves TAU0 alone", self.rd(R_TAU0) == 10000000,
            "%d" % self.rd(R_TAU0))
        try:
            self.set_eps_counts(0, 0x1_0000_0000)
            chk("eps overflow rejected", False, "no exception raised")
        except ValueError:
            chk("eps overflow rejected", True, "")
        # 0xFFFFFFFF must be accepted: eps is an upper bound, not a signed delay.
        self.set_eps_counts(0, 0xFFFFFFFF)
        chk("eps = 0xFFFFFFFF round trip", self.get_eps_counts(0) == 0xFFFFFFFF,
            "0x%08X" % self.get_eps_counts(0))
        for m, v in enumerate(eps_vals):
            self.set_eps_counts(m, v)
        self.set_tau(0, 0.0)

        # -- counter runs -----------------------------------------------------
        self.start()
        a = self.t_now()
        time.sleep(0.01)
        b = self.t_now()
        # 10 ms at 100 MHz = 1,000,000 counts. Allow a wide band: this is a
        # liveness check, not a rate measurement (the PS sleep is not precise).
        chk("counter advances ~10ms", 0.25e6 < (b - a) < 3.0e6,
            "delta = %d counts = %.3f ms" % (b - a, counts_to_seconds(b - a) * 1e3))
        chk("counter is monotonic", b > a, "")
        self.stop()
        c = self.t_now()
        time.sleep(0.005)
        chk("counter frozen when stopped", self.t_now() == c, "")

        # -- clr_cnt self-clears ---------------------------------------------
        self.start()
        self.reset_counter()
        time.sleep(0.001)
        chk("clr_cnt is a pulse, not a latch", self.is_running(),
            "CTRL = 0x%08X" % self.rd(R_CTRL))
        chk("counter restarted from ~0", self.t_now() < 5_000_000,
            "%d counts" % self.t_now())

        # -- internal strobe generator ---------------------------------------
        # The one path that makes the whole design demonstrable with no sensors.
        self.reset_fifo()
        self.clear_ovf()
        for m in range(4):
            self.set_div(m, 0)             # silence everything first
        self.set_src(0x0)
        self.start()
        time.sleep(0.02)
        chk("SRC=0 -> nothing strobes, FIFO empty", self.status()["empty"],
            "level = %d" % self.status()["level"])

        self.set_src(0x1)                  # EEG only
        self.set_div(0, 20000)             # 10 kHz -- fast enough to fill in 20 ms
        time.sleep(0.02)
        lvl = self.status()["level"]
        chk("SRC=1 -> EEG strobes, FIFO fills", lvl > 0,
            "level = %d after 20 ms at 10 kHz" % lvl)
        self.stop()

        # -- pop semantics ----------------------------------------------------
        samp = self.drain()
        chk("drained samples have mod 0", all(m == 0 for m, _ in samp),
            "%d samples" % len(samp))
        chk("popped timestamps are non-decreasing",
            all(samp[i][1] <= samp[i + 1][1] for i in range(len(samp) - 1)), "")
        chk("pop on empty FIFO returns None", self.pop() is None, "")

        # -- reset_fifo -------------------------------------------------------
        self.reset_fifo()
        chk("fifo_rst empties the FIFO", self.status()["empty"], "")
        chk("fifo_rst zeroes enq_count", self.enq_count() == 0,
            "%d" % self.enq_count())

        # -- tau compensation actually subtracts ------------------------------
        # Run one strobe, read the raw stamp from the FIFO and the compensated
        # one from TMm, and check the difference equals tau exactly.
        #
        # ★ The counter is reset first on purpose. tau_comp subtracts mod 2**48,
        #   so if tau is larger than the counter's current value you get a huge
        #   wrapped t_m rather than a negative one. That is a real trap: pick
        #   tau = 0.5 s while the counter sits at 0.09 s and the check fails
        #   with a number that looks like a broken adder. Keeping t >> tau makes
        #   the test say what it means.
        #
        # ★ tau must also be smaller than the FIRST strobe interval. The
        #   divider holds cnt=0 while run=0, so after start the first sample
        #   arrives at t = DIV exactly. With tau = 2,000,000 counts and
        #   DIV = 1,000,000 that first sample has t < tau and correctly sets
        #   uf_sticky -- the hardware was right, this check was wrong.
        self.set_tau(0, 0.001)             # 100,000 counts < DIV
        self.clear_uf()
        self.set_src(0x1)
        self.set_div(0, 1_000_000)         # 100 Hz, one strobe every 10 ms
        self.reset_counter()
        self.start()
        time.sleep(0.05)                   # t ~ 5e6 counts, 50x tau
        s = self.drain()
        self.stop()
        if s:
            raw = s[-1][1]
            comp = self.tm(0)
            d = raw - comp
            chk("t_m = t - tau", d == 100_000,
                "t=%d t_m=%d diff=%d (want 100000)" % (raw, comp, d))
            chk("no underflow when t > tau", self.uf_sticky() == 0,
                "uf_sticky = 0x%X" % self.uf_sticky())
        else:
            chk("t_m = t - tau", False, "no sample arrived")
        self.set_tau(0, 0.0)

        # -- wrap / range documentation ---------------------------------------
        chk("tau range = 0..42.95 s", abs(TAU_MAX_S - 42.94967295) < 1e-6,
            "%.8f s" % TAU_MAX_S)
        chk("counter wraps after 32.58 days", abs(T_WRAP_S / 86400 - 32.58) < 0.01,
            "%.2f days" % (T_WRAP_S / 86400.0))

        self.stop()
        self.set_src(0x0)

        # -- report ------------------------------------------------------------
        npass = sum(1 for _, ok, _ in res if ok)
        print("=" * 66)
        print(" ts_top selftest: %d/%d passed" % (npass, len(res)))
        print("=" * 66)
        for name, ok, detail in res:
            mark = "ok  " if ok else "FAIL"
            line = "  [%s] %s" % (mark, name)
            if detail:
                line += "   -- %s" % detail
            print(line)
        if npass != len(res):
            print("\n  %d check(s) FAILED" % (len(res) - npass))
        return res


def measure_strobe_hz(ts, mod=0, div=2_000_000, seconds=1.0):
    """Strobe rate over `seconds` of wall clock, from ENQ_COUNT.

    This is the check that actually proves which FCLK_CLK0 the PL is fed,
    because the divider is in PL cycles: div=2e6 gives 100 Hz at 200 MHz and
    50 Hz at 100 MHz. Independent of the counter path -- it counts strobes
    against perf_counter, so a stale CLK_HZ constant cannot fake it. The FIFO
    is deep enough (256) for div >= 2e6 over one second.
    """
    ts.stop()
    ts.reset_fifo()
    ts.clear_ovf()
    for m in range(4):
        ts.set_div(m, 0)
    ts.set_div(mod, div)
    ts.set_src(1 << mod)
    ts.start()
    time.sleep(seconds)
    ts.stop()
    n = ts.enq_count()
    ts.set_src(0)
    return n / float(seconds)


def detect_fclk_hz(ts, div=2_000_000, seconds=1.0):
    """Measure FCLK_CLK0 from the PL side, in Hz.

    One PL divider cycle per FCLK period, so the strobe rate times `div` is
    the clock. Uses no assumption about what the clock should be.
    """
    return measure_strobe_hz(ts, mod=0, div=div, seconds=seconds) * float(div)


def demo(bitfile=None, base=0x40000000):
    """Run the selftest and print the register state. The bring-up entry point.

    Does not try to *set* FCLK: the PS divider is fixed by BOOT.BIN, JTAG does
    not touch it, and on this board 200 MHz is not reachable anyway. What
    matters is that CLK_HZ matches what the PL is actually being fed, so the
    clock is measured and the conversions are rescaled from the measurement.
    """
    ts = TsTop(bitfile, base=base)
    hz = detect_fclk_hz(ts)
    print("  FCLK_CLK0      : %.2f MHz (measured by PL strobe)" % (hz / 1e6))
    if abs(hz - CLK_HZ) > 0.02 * CLK_HZ:
        set_clk_hz(round(hz))
        print("  *** rescaled: CLK_HZ -> %d MHz (was %d) ***"
              % (CLK_HZ // 10 ** 6, int(round(hz / 1e6))))
    ts.selftest()
    print("\n  ip_name        : %s" % ts.ip_name)
    print("  tau (s)        : %s" % (ts.get_all_tau(),))
    print("  src / div      : 0x%X / %s" % (ts.get_src(),
                                            [ts.get_div(m) for m in range(4)]))
    print("  ovf / uf sticky: 0x%X / 0x%X" % (ts.ovf_sticky(), ts.uf_sticky()))
    n256 = int(round(CLK_HZ / 256.0))
    print("  for 256 Hz       : div %d -> %.4f Hz" % (n256, CLK_HZ / float(n256)))
    return ts


if __name__ == "__main__":
    import sys
    args = sys.argv[1:]
    base, bitfile = 0x40000000, None
    i = 0
    while i < len(args):
        if args[i] == "--base":
            base = int(args[i + 1], 0)
            i += 2
        elif args[i] in ("--raw", "-r"):
            i += 1
        else:
            bitfile = args[i]
            i += 1
    demo(bitfile, base=base)
