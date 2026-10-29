# -*- coding: utf-8 -*-
"""Word map of the M=3 (e+o+a) build -- single source of truth for the board side.

Every number here is copied from `work2/out/wordmap.txt`, which `export.py m3`
regenerates from the same `layout()` that drives the RTL.  **Do not hand-edit**:
a mismatch is silent -- the engine runs and the numbers are simply wrong.

`check_against_export()` re-reads wordmap.txt when it is next to the script,
so a stale copy is caught before a run rather than after.
"""
import os

N_IN = 1540          # T*(310 + 24 + 51) = 4 * 385
G, T, D = 16, 4, 16

# (name, base word, words) -- same order as tb/tb_attn_m3.v's chk() list.
ARRAYS = [
    ("he",   3584, 1024),   # NA
    ("zpe",  6144,  256),
    ("zpo",  6400,  256),
    ("zpa",  6656,  256),
    ("hre",  2048, 1024),
    ("hro",  3072,   64),
    ("hra",  3136,   64),
    ("ho",   4608,   64),
    ("ha",   4672,   64),
    ("qe",   4864,   64),
    ("ke",   4928,  128),
    ("ve",   5056,  128),
    ("qo",   5184,   64),
    ("ko",   5248,  128),
    ("vo",   5376,  128),
    ("qa",   5504,   64),
    ("ka",   5568,  128),
    ("va",   5696,  128),
    ("z0e",  5824,   64),
    ("z0o",  5888,   64),
    ("z0a",  5952,   64),
]

# golden .mem file for each dump name (all under work2/out/)
MEM = {
    "he": "exp_h.mem",    "zpe": "exp_ze.mem",   "zpo": "exp_zo.mem",
    "zpa": "exp_za.mem",  "hre": "exp_hre.mem",  "hro": "exp_hro.mem",
    "hra": "exp_hra.mem", "ho": "exp_ho.mem",    "ha": "exp_ha.mem",
    "qe": "exp_qL_e.mem", "ke": "exp_kL_e.mem",  "ve": "exp_vL_e.mem",
    "qo": "exp_qL_o.mem", "ko": "exp_kL_o.mem",  "vo": "exp_vL_o.mem",
    "qa": "exp_qL_a.mem", "ka": "exp_kL_a.mem",  "va": "exp_vL_a.mem",
    "z0e": "exp_z0L_e.mem", "z0o": "exp_z0L_o.mem", "z0a": "exp_z0L_a.mem",
}

TOTAL_WORDS = sum(n for _, _, n in ARRAYS)     # 4,224
END = 6912                                     # scratch words used

# M=3 engine length, measured in xsim (start -> done); the AXI wrapper does not
# change it.  At the board's 100.00 MHz FCLK_CLK0 that is 11.25 ms.
ENGINE_CYCLES = 1_124_691
ENGINE_MS_AT_100MHZ = ENGINE_CYCLES / 1e8 * 1e3

WORDMAP_KEYS = [
    "IN_E", "IN_O", "IN_A", "HRE", "HRO", "HRA", "HE", "HO", "HA", "KV",
    "QE", "KE", "VE", "QO", "KO", "VO", "QA", "KA", "VA",
    "ZE", "ZO", "ZA", "ZPE", "ZPO", "ZPA", "END",
]


def check_against_export(path=None, verbose=False):
    """Compare the constants above with work2/out/wordmap.txt.

    Returns [] when they agree, else a list of human-readable differences.
    Raises nothing: the caller decides whether a stale map is fatal.
    """
    if path is None:
        here = os.path.dirname(os.path.abspath(__file__))
        # deploy/wordmap_m3.txt 是 M=3 导出时拍下的快照，跟着脚本走；
        # work2/out 是 M=2/M=3 共用的一份目录，跑过 export.py m2 之后那里
        # 就是 M=2 的 wordmap 了。有快照先用快照，否则回落到 out/。
        snap = os.path.join(here, "wordmap_m3.txt")
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

    cur = {
        "IN_E": 0, "IN_O": 1240, "IN_A": 1336,
        "HRE": 2048, "HRO": 3072, "HRA": 3136,
        "HE": 3584, "HO": 4608, "HA": 4672, "KV": 4736,
        "QE": 4864, "KE": 4928, "VE": 5056,
        "QO": 5184, "KO": 5248, "VO": 5376,
        "QA": 5504, "KA": 5568, "VA": 5696,
        "ZE": 5824, "ZO": 5888, "ZA": 5952,
        "ZPE": 6144, "ZPO": 6400, "ZPA": 6656, "END": 6912,
    }
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
        print("m3_map: %d bases agree with %s" % (len(cur), path))
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
