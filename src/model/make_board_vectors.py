# -*- coding: utf-8 -*-
"""Bundle in.mem + the 14 golden exp_*.mem files into one npz for the board.

The board has no path back to this machine (no network), so the golden vectors
have to travel with the script.  One npz is one base64 blob over the serial
line; 14 separate mem files would be 14 transfers and 14 chances to typo a
trailing marker.

    python make_board_vectors.py
writes ../deploy/attn_vectors14.npz
"""
import os
import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "out")
DST = os.path.abspath(os.path.join(HERE, "..", "deploy", "attn_vectors14.npz"))

FILES = [
    ("in_q",  "in.mem",      1336),
    ("he",    "exp_h.mem",   1024),
    ("ze",    "exp_ze.mem",   256),
    ("zo",    "exp_zo.mem",   256),
    ("hre",   "exp_hre.mem", 1024),
    ("hro",   "exp_hro.mem",   64),
    ("qe",    "exp_qL_e.mem",  64),
    ("ke",    "exp_kL_e.mem",  64),
    ("ve",    "exp_vL_e.mem",  64),
    ("qo",    "exp_qL_o.mem",  64),
    ("ko",    "exp_kL_o.mem",  64),
    ("vo",    "exp_vL_o.mem",  64),
    ("z0e",   "exp_z0L_e.mem", 64),
    ("z0o",   "exp_z0L_o.mem", 64),
    ("ho",    "exp_ho.mem",    64),
]


def load(path):
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
    return np.where(a >= 0x8000, a - 0x10000, a).astype(np.int16)


def main():
    d = {}
    for key, fn, n in FILES:
        a = load(os.path.join(OUT, fn))
        if a.size < n:
            raise SystemExit("%s: got %d words, need %d" % (fn, a.size, n))
        d[key] = a[:n]
        print("  %-6s %5d" % (key, n))
    np.savez_compressed(DST, **d)
    print("wrote %s (%.1f KB)" % (DST, os.path.getsize(DST) / 1024.0))


if __name__ == "__main__":
    main()
