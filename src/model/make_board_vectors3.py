# -*- coding: utf-8 -*-
"""Bundle in.mem + the 21 golden exp_*.mem files of the M=3 build into one npz.

Same idea as make_board_vectors.py (M=2, 14 arrays), extended to the M=3
(e+o+a) array set so the board run can be a *bit-exact* test, not a
"looks plausible" one.

    python -I -X utf8 make_board_vectors3.py     (after `export.py m3`)
writes ../deploy/attn_vectors3.npz
"""
import os
import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "out")
DST = os.path.abspath(os.path.join(HERE, "..", "deploy", "attn_vectors3.npz"))

# order mirrors tb/tb_attn_m3.v's chk() list, so a board dump can be compared
# array by array with the same names.
FILES = [
    ("in_q", "in.mem",      1540),   # T*(310 + 24 + 51) = 4*385
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
    note = os.path.join(OUT, "exp_note.txt")
    if os.path.exists(note):
        first = open(note).readline().strip()
        print("out/ exp_note: %s" % first)
        if "mods=e,o,a" not in first:
            raise SystemExit("out/ is not the M=3 export; run `export.py m3` first")

    d, total = {}, 0
    for key, fn, n in FILES:
        a = load(os.path.join(OUT, fn))
        if a.size < n:
            raise SystemExit("%s: got %d words, need %d" % (fn, a.size, n))
        d[key] = a[:n]
        if key != "in_q":
            total += n
        print("  %-5s %5d" % (key, n))
    np.savez_compressed(DST, **d)
    print("golden words (excl. input) = %d over %d arrays"
          % (total, len(FILES) - 1))
    print("wrote %s (%.1f KB)" % (DST, os.path.getsize(DST) / 1024.0))


if __name__ == "__main__":
    main()
