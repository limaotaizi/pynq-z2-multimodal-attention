# -*- coding: utf-8 -*-
"""Full 14-array bit-exact check of attn_axi on the board.

Same comparison tb_attn_axi.v does in simulation, but through AXI on real
silicon: 1336 input words in, 3200 output words out, every one compared with
the fixpt.py golden mem files.

    python3 -u board_check.py
    python3 -u board_check.py --base 0x40000000 --block 0x40010000

ASCII only (the board's console is a serial line in an unknown codepage).
"""
import argparse
import os
import sys
import time

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

from attn_driver import AttnAxi, N_IN, s16  # noqa: E402

OUT = os.path.join(os.path.dirname(HERE), "work2", "out")

# name, base word, length, mem file
ARRAYS = [
    ("H_E ",  3072, 1024, "exp_h.mem"),
    ("ZP_E",  4864,  256, "exp_ze.mem"),
    ("ZP_O",  5120,  256, "exp_zo.mem"),
    ("HR_E",  1536, 1024, "exp_hre.mem"),
    ("HR_O",  2560,   64, "exp_hro.mem"),
    ("Q_EL",  4352,   64, "exp_qL_e.mem"),
    ("K_E ",  4416,   64, "exp_kL_e.mem"),
    ("V_E ",  4480,   64, "exp_vL_e.mem"),
    ("Q_O ",  4544,   64, "exp_qL_o.mem"),
    ("K_O ",  4608,   64, "exp_kL_o.mem"),
    ("V_O ",  4672,   64, "exp_vL_o.mem"),
    ("Z_E0",  4736,   64, "exp_z0L_e.mem"),
    ("Z_O0",  4800,   64, "exp_z0L_o.mem"),
    ("H_O ",  4096,   64, "exp_ho.mem"),
]

T0 = time.time()


def log(msg):
    print("[%6.2fs] %s" % (time.time() - T0, msg), flush=True)


def load_mem(path):
    """Read a $readmemh file as int16."""
    vals = []
    with open(path, "r") as f:
        for line in f:
            t = line.strip()
            if not t:
                continue
            for tok in t.split():
                if tok.startswith("//") or tok.startswith("@"):
                    break
                vals.append(int(tok, 16))
    return s16(np.array(vals, dtype=np.int64))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--base", type=lambda s: int(s, 0), default=0x40000000)
    ap.add_argument("--ts-base", type=lambda s: int(s, 0), default=0x40010000)
    ap.add_argument("--no-fclk", action="store_true",
                    help="skip the FCLK0 = 200 MHz setup (already done)")
    a = ap.parse_args()

    if not a.no_fclk:
        try:
            from ts_driver import set_fclk0_mhz
            mhz, how = set_fclk0_mhz(200)
            log("FCLK0 = %.1f MHz (%s)" % (mhz, how))
        except Exception as e:                       # noqa: BLE001
            log("FCLK0 setup skipped: %s" % e)

    drv = AttnAxi(None, base=a.base)
    log("ID = 0x%08X" % drv.rd(0x0008))

    inw = load_mem(os.path.join(OUT, "in.mem"))
    if inw.size != N_IN:
        log("FAIL: in.mem has %d words, expected %d" % (inw.size, N_IN))
        return 1

    log("loading %d words ..." % N_IN)
    drv.clear_done()
    drv.write_words(0, inw)
    back = drv.read_words(0, 64)
    bad_in = int(np.sum(back != inw[:64]))
    log("input readback (first 64): %d mismatches" % bad_in)

    log("start")
    drv.start()
    if not drv.wait_done(timeout=10.0):
        log("FAIL: no done, status 0x%08X" % drv.rd(0x0004))
        return 1
    log("done")

    nbad_arrays = 0
    nbad_words = 0
    for name, base, n, fn in ARRAYS:
        got = drv.read_words(base, n)
        exp = load_mem(os.path.join(OUT, fn))
        if exp.size < n:
            log("  %-5s golden short (%d < %d)" % (name, exp.size, n))
            nbad_arrays += 1
            continue
        exp = exp[:n]
        bad = int(np.sum(got != exp))
        nbad_words += bad
        if bad:
            nbad_arrays += 1
            idx = int(np.argmax(got != exp))
            log("  %-5s %4d/%4d MISMATCH  first@%d got=%d exp=%d"
                % (name, bad, n, idx, int(got[idx]), int(exp[idx])))
        else:
            log("  %-5s %4d/%4d OK" % (name, n, n))

    log("")
    if nbad_words == 0:
        log("BOARD_CHECK: 14/14 arrays bit-exact (3200/3200 words, 0 mismatches)")
    else:
        log("BOARD_CHECK: %d/14 arrays bad, %d words total"
            % (nbad_arrays, nbad_words))

    # timing sanity: one engine run at 200 MHz is 466157 cycles = 2.331 ms
    log("engine cycles expected 466157 -> 2.331 ms at 200 MHz")
    return 0 if nbad_words == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
