# -*- coding: utf-8 -*-
"""Does deploy/attn_vectors3.npz still match work2/out/*.mem ?

Read-only.  A stale npz would make cmp_dump3.py report a FAIL on a perfectly
good bitstream, so this is checked before every board run.

    python -I -X utf8 check_npz_vs_mem.py
"""
import os
import sys

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "out")
NPZ = os.path.abspath(os.path.join(HERE, "..", "deploy", "attn_vectors3.npz"))

FILES = [
    ("in_q", "in.mem",      1540),
    ("he",   "exp_h.mem",   1024),
    ("zpe",  "exp_ze.mem",   256),
    ("zpo",  "exp_zo.mem",   256),
    ("zpa",  "exp_za.mem",   256),
    ("hre",  "exp_hre.mem", 1024),
    ("hro",  "exp_hro.mem",   64),
    ("hra",  "exp_hra.mem",   64),
    ("ho",   "exp_ho.mem",    64),
    ("ha",   "exp_ha.mem",    64),
    ("qe",   "exp_qL_e.mem",  64),
    ("ke",   "exp_kL_e.mem", 128),
    ("ve",   "exp_vL_e.mem", 128),
    ("qo",   "exp_qL_o.mem",  64),
    ("ko",   "exp_kL_o.mem", 128),
    ("vo",   "exp_vL_o.mem", 128),
    ("qa",   "exp_qL_a.mem",  64),
    ("ka",   "exp_kL_a.mem", 128),
    ("va",   "exp_vL_a.mem", 128),
    ("z0e",  "exp_z0L_e.mem", 64),
    ("z0o",  "exp_z0L_o.mem", 64),
    ("z0a",  "exp_z0L_a.mem", 64),
]


def load(path, n):
    vals = []
    with open(path, "r") as f:
        for line in f:
            t = line.strip()
            if not t or t.startswith("//"):
                continue
            for tok in t.split():
                if tok.startswith("//") or tok.startswith("@"):
                    break
                vals.append(int(tok, 16))
    a = np.array(vals, dtype=np.int64) & 0xFFFF
    a = np.where(a >= 0x8000, a - 0x10000, a).astype(np.int16)
    if a.size < n:
        raise SystemExit("%s: only %d words, need %d" % (path, a.size, n))
    return a[:n]


def main():
    z = np.load(NPZ)
    bad = 0
    for key, fn, n in FILES:
        want = load(os.path.join(OUT, fn), n)
        if key not in z:
            print("  [FAIL] %-4s missing from the npz" % key)
            bad += 1
            continue
        got = z[key]
        same = int((got == want).sum())
        if same != n:
            print("  [FAIL] %-4s %d/%d differ" % (key, n - same, n))
            bad += 1
        else:
            print("  [ok  ] %-4s %d words" % (key, n))
    if bad:
        print("NPZ_STALE  %d array(s) differ -- re-run make_board_vectors3.py" % bad)
        return 1
    print("NPZ_FRESH  all %d arrays match out/*.mem" % len(FILES))
    return 0


if __name__ == "__main__":
    sys.exit(main())
