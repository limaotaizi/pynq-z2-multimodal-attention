# -*- coding: utf-8 -*-
"""Bundle in.mem + the 28 golden exp_*.mem files of the M=4 build into one npz.

Same idea as make_board_vectors3.py (M=3, 21 arrays), extended to the M=4
(e+o+a+s) array set.  Two differences from M=3:

  * the input block is 1,636 words (IN_S adds 96: 24 GSR window features x T=4)
  * K/V are 3*T*D = 192 words per modality, not 128 -- kv is concatenated
    along the SEQUENCE axis, so each modality's K/V has 3T=12 rows

    python -I -X utf8 make_board_vectors4.py     (after `export.py m4`)
writes ../deploy/attn_vectors4.npz
"""
import os
import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "out")
DST = os.path.abspath(os.path.join(HERE, "..", "deploy", "attn_vectors4.npz"))

# order mirrors tb/tb_attn_m4.v's chk() list, so a board dump can be compared
# array by array with the same names.
FILES = [
    ("in_q", "in.mem",       1636),   # 1240 (e) + 96 (o) + 204 (a) + 96 (s)
    ("he",   "exp_h.mem",    1024),
    ("zpe",  "exp_ze.mem",    256),
    ("zpo",  "exp_zo.mem",    256),
    ("zpa",  "exp_za.mem",    256),
    ("zps",  "exp_zs.mem",    256),
    ("hre",  "exp_hre.mem",  1024),
    ("hro",  "exp_hro.mem",    64),
    ("hra",  "exp_hra.mem",    64),
    ("hrs",  "exp_hrs.mem",    64),
    ("ho",   "exp_ho.mem",     64),
    ("ha",   "exp_ha.mem",     64),
    ("hs",   "exp_hs.mem",     64),
    ("qe",   "exp_qL_e.mem",   64),
    ("ke",   "exp_kL_e.mem",  192),
    ("ve",   "exp_vL_e.mem",  192),
    ("qo",   "exp_qL_o.mem",   64),
    ("ko",   "exp_kL_o.mem",  192),
    ("vo",   "exp_vL_o.mem",  192),
    ("qa",   "exp_qL_a.mem",   64),
    ("ka",   "exp_kL_a.mem",  192),
    ("va",   "exp_vL_a.mem",  192),
    ("qs",   "exp_qL_s.mem",   64),
    ("ks",   "exp_kL_s.mem",  192),
    ("vs",   "exp_vL_s.mem",  192),
    ("z0e",  "exp_z0L_e.mem",  64),
    ("z0o",  "exp_z0L_o.mem",  64),
    ("z0a",  "exp_z0L_a.mem",  64),
    ("z0s",  "exp_z0L_s.mem",  64),
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
        if "mods=e,o,a,s" not in first:
            raise SystemExit("out/ is not the M=4 export; run `export.py m4` first")

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
