# -*- coding: utf-8 -*-
"""Word map of the M=4 (e+o+a+s) build -- single source of truth for the board side.

Every number here is copied from `work2/out/wordmap.txt`, which `export.py m4`
regenerates from the same `layout()` that drives the RTL.  **Do not hand-edit**:
a mismatch is silent -- the engine runs and the numbers are simply wrong.

`check_against_export()` re-reads wordmap.txt when it is next to the script,
so a stale copy is caught before a run rather than after.

Two things that differ from m3_map.py and that will silently corrupt a dump
if they are carried over from M=3:

  * K/V are **192** words per modality (kv is concatenated along the SEQUENCE
    axis: (M-1)*T*D = 3*4*16), not 128;
  * the scratch memory is used to **8192/8192** -- there is no slack left.
    A fifth modality needs a deeper `mem` in attn_core.v first.
"""
import os

N_IN = 1636          # T*(310 + 24 + 51 + 24) = 4 * 409
G, T, D = 16, 4, 16
M = 4

# (name, base word, words) -- same order as tb/tb_attn_m4.v's chk() list.
ARRAYS = [
    ("he",    3584, 1024),
    ("zpe",   7168,  256),
    ("zpo",   7424,  256),
    ("zpa",   7680,  256),
    ("zps",   7936,  256),
    ("hre",   2048, 1024),
    ("hro",   3072,   64),
    ("hra",   3136,   64),
    ("hrs",   3200,   64),
    ("ho",    4608,   64),
    ("ha",    4672,   64),
    ("hs",    4736,   64),
    ("qe",    5120,   64),
    ("ke",    5184,  192),
    ("ve",    5376,  192),
    ("qo",    5568,   64),
    ("ko",    5632,  192),
    ("vo",    5824,  192),
    ("qa",    6016,   64),
    ("ka",    6080,  192),
    ("va",    6272,  192),
    ("qs",    6464,   64),
    ("ks",    6528,  192),
    ("vs",    6720,  192),
    ("z0e",   6912,   64),
    ("z0o",   6976,   64),
    ("z0a",   7040,   64),
    ("z0s",   7104,   64),
]

# golden array name inside deploy/attn_vectors4.npz and the .mem it came from
MEM = {
    "he": "exp_h.mem",      "zpe": "exp_ze.mem",     "zpo": "exp_zo.mem",
    "zpa": "exp_za.mem",    "zps": "exp_zs.mem",     "hre": "exp_hre.mem",
    "hro": "exp_hro.mem",   "hra": "exp_hra.mem",    "hrs": "exp_hrs.mem",
    "ho": "exp_ho.mem",     "ha": "exp_ha.mem",      "hs": "exp_hs.mem",
    "qe": "exp_qL_e.mem",   "ke": "exp_kL_e.mem",    "ve": "exp_vL_e.mem",
    "qo": "exp_qL_o.mem",   "ko": "exp_kL_o.mem",    "vo": "exp_vL_o.mem",
    "qa": "exp_qL_a.mem",   "ka": "exp_kL_a.mem",    "va": "exp_vL_a.mem",
    "qs": "exp_qL_s.mem",   "ks": "exp_kL_s.mem",    "vs": "exp_vL_s.mem",
    "z0e": "exp_z0L_e.mem", "z0o": "exp_z0L_o.mem",  "z0a": "exp_z0L_a.mem",
    "z0s": "exp_z0L_s.mem",
}

TOTAL_WORDS = sum(n for _, _, n in ARRAYS)     # 5,504
END = 8192                                     # scratch words used (all of them)

# M=4 engine length measured in xsim 2026-10-26 (start -> done); the AXI
# wrapper does not change it.  At the board's 100.00 MHz FCLK_CLK0: 20.79 ms.
# (M=2 = 466,157 -> 4.66 ms; M=3 = 1,124,691 -> 11.25 ms.  Timing alone
#  therefore identifies which bitstream is loaded.)
ENGINE_CYCLES = 2_079_001
ENGINE_MS_AT_100MHZ = ENGINE_CYCLES / 1e8 * 1e3

WORDMAP_KEYS = [
    "IN_E", "IN_O", "IN_A", "IN_S",
    "HRE", "HRO", "HRA", "HRS", "HE", "HO", "HA", "HS", "KV",
    "QE", "KE", "VE", "QO", "KO", "VO", "QA", "KA", "VA", "QS", "KS", "VS",
    "ZE", "ZO", "ZA", "ZS", "ZPE", "ZPO", "ZPA", "ZPS", "END",
]

# base word for each wordmap key
BASES = {
    "IN_E": 0, "IN_O": 1240, "IN_A": 1336, "IN_S": 1540,
    "HRE": 2048, "HRO": 3072, "HRA": 3136, "HRS": 3200,
    "HE": 3584, "HO": 4608, "HA": 4672, "HS": 4736, "KV": 4800,
    "QE": 5120, "KE": 5184, "VE": 5376,
    "QO": 5568, "KO": 5632, "VO": 5824,
    "QA": 6016, "KA": 6080, "VA": 6272,
    "QS": 6464, "KS": 6528, "VS": 6720,
    "ZE": 6912, "ZO": 6976, "ZA": 7040, "ZS": 7104,
    "ZPE": 7168, "ZPO": 7424, "ZPA": 7680, "ZPS": 7936,
    "END": 8192,
}


def check_against_export(path=None, verbose=False):
    """Compare the constants above with work2/out/wordmap.txt.

    Returns [] when they agree, else a list of human-readable differences.
    Raises nothing: the caller decides whether a stale map is fatal.
    """
    if path is None:
        here = os.path.dirname(os.path.abspath(__file__))
        # deploy/wordmap_m4.txt 是 M=4 导出时拍下的快照，跟着脚本走；
        # work2/out 是 M=2/M=3/M=4 共用的一份目录，跑过别的 export 之后
        # 那里就是别的口径了。有快照先用快照，否则回落到 out/。
        snap = os.path.join(here, "wordmap_m4.txt")
        if os.path.exists(snap):
            path = snap
        else:
            path = os.path.join(os.path.dirname(here), "work2", "out", "wordmap.txt")
    if not os.path.exists(path):
        return ["wordmap.txt not found at %s" % path]
    want = {}
    for line in open(path):
        parts = line.split()
        if len(parts) == 2 and parts[0].isupper():
            want[parts[0]] = int(parts[1])
    if not want:
        return ["wordmap.txt at %s has no entries" % path]

    cur = dict(BASES)
    # the ARRAYS table must agree with `cur` too
    for name, base, n in ARRAYS:
        key = name.upper().replace("0", "")     # z0e -> ZE, hre -> HRE
        if key in cur and cur[key] != base:
            return ["ARRAYS[%s] base %d != map %d" % (name, base, cur[key])]

    out = []
    for k, v in cur.items():
        if k not in want:
            out.append("%s missing from wordmap.txt" % k)
        elif want[k] != v:
            out.append("%s: map says %d, wordmap.txt says %d" % (k, v, want[k]))
    if verbose and not out:
        print("m4_map: %d bases agree with %s" % (len(cur), path))
    return out


if __name__ == "__main__":
    bad = check_against_export(verbose=True)
    print("TOTAL_WORDS = %d over %d arrays, END = %d"
          % (TOTAL_WORDS, len(ARRAYS), END))
    if bad:
        print("MISMATCH:")
        for b in bad:
            print("  " + b)
        raise SystemExit(1)
    print("OK")
