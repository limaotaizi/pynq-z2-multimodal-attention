# -*- coding: utf-8 -*-
"""fclk_meas.py -- how fast is FCLK_CLK0, really?

Run on the board after ts.bit has been programmed:

    echo xilinx | sudo -S /usr/local/share/pynq-venv/bin/python3 -u fclk_meas.py

Two independent methods, both against the PS wall clock:

  (1) free-running counter  -- read T_NOW at t0 and t1, divide the count
      difference by the elapsed time. Uses nothing but the 48-bit counter.
  (2) internal strobe divider -- the divider counts *PL cycles*, so a divider
      of N strobes at FCLK/N Hz. ENQ_COUNT over a known interval gives FCLK.

Neither touches the SLCR, so neither can disturb the design under test.

WHY THIS EXISTS (2026-10-21, measured): this board's IO PLL runs at 500 MHz,
not the 1000 MHz everyone assumes. FPGA0_CLK_CTRL = 0x00200500 has
DIVISOR1 = 5 and SRCSEL = 0, so FCLK_CLK0 = 500/5 = 100 MHz, and both methods
above return 100.00 MHz.

That makes the old advice -- "write 0xF8000170 = (5<<8)|1 to get 200 MHz" --
wrong: 5 is already the programmed divisor, so the write is a no-op. 200 MHz
is not reachable from a 500 MHz IO PLL at all (500/2 = 250, 500/3 = 166.7).
Getting a true 200 MHz needs a different PLL source or a different FSBL.

Consequence for anything with a clk_wiz: a clk_wiz declared with
PRIM_IN_FREQ = 200.0 fed by a 100 MHz FCLK produces exactly half the
requested output. The codec MCLK was 6.144 MHz for that reason, not 12.288.
"""

import mmap
import struct
import time

BASE = 0x40000000

R_CTRL, R_TNOW_L, R_TNOW_H, R_ENQ = 0x00, 0x08, 0x0C, 0x14
R_SRC, R_DIV0 = 0x5C, 0x60


def _open(base=BASE):
    f = open("/dev/mem", "r+b", buffering=0)
    return f, mmap.mmap(f.fileno(), 0x1000, mmap.MAP_SHARED,
                        mmap.PROT_READ | mmap.PROT_WRITE, offset=base)


def measure(m, rd, wr, seconds=2.0):
    """Return (fclk_from_counter_mhz, fclk_from_strobe_mhz)."""

    def t_now():
        # H, L, H with a retry: the counter can carry between the two reads.
        for _ in range(8):
            hi = rd(R_TNOW_H) & 0xFFFF
            lo = rd(R_TNOW_L)
            if (rd(R_TNOW_H) & 0xFFFF) == hi:
                return (hi << 32) | lo
        raise RuntimeError("counter carried on every retry -- is it running?")

    # (1) counter vs wall clock
    wr(R_CTRL, 0)
    wr(R_CTRL, 1)
    time.sleep(0.2)                      # let the start settle
    a = t_now()
    t0 = time.perf_counter()
    time.sleep(seconds)
    t1 = time.perf_counter()
    b = t_now()
    wr(R_CTRL, 0)
    mhz_counter = (b - a) / (t1 - t0) / 1e6

    # (2) strobe divider: div = 2e6 -> 100 Hz at 200 MHz, 50 Hz at 100 MHz
    wr(R_CTRL, 0)
    wr(R_CTRL, 4)                        # fifo_rst, self-clearing
    for i in range(4):
        wr(R_DIV0 + 4 * i, 0)
    wr(R_SRC, 0)
    wr(R_DIV0, 2000000)
    wr(R_SRC, 1)
    t0 = time.perf_counter()
    wr(R_CTRL, 1)
    time.sleep(seconds / 2.0)
    wr(R_CTRL, 0)
    t1 = time.perf_counter()
    n = rd(R_ENQ)
    wr(R_SRC, 0)
    mhz_strobe = 2.0 * n / (t1 - t0)     # rate * div, in MHz

    return mhz_counter, mhz_strobe


def main():
    f, m = _open()
    rd = lambda o: struct.unpack_from("<I", m, o)[0]
    wr = lambda o, v: struct.pack_into("<I", m, o, v & 0xFFFFFFFF)

    ident = rd(0x7C)
    print("ID=%08X%s" % (ident, "" if ident == 0xDEADBEEF else "  (ts_top not there!)"))
    if ident != 0xDEADBEEF:
        return 1

    c, s = measure(m, rd, wr)
    print("FCLK counter = %.2f MHz" % c)
    print("FCLK strobe  = %.2f MHz" % s)
    print("FCLK = %.1f MHz" % ((c + s) / 2.0))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
