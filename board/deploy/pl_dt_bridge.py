# -*- coding: utf-8 -*-
"""pl_dt_bridge.py -- the missing link between the PL's tau/eps registers and the model.

    # read what the PL currently holds (no writes)
    python3 pl_dt_bridge.py --read

    # write the physically-motivated table, then read it back and emit JSON
    python3 pl_dt_bridge.py --write --json pl_eps_tau.json

    # override single values
    python3 pl_dt_bridge.py --write --eps e=0.024,o=0.080,a=0.066,s=1.8

Why this file exists (F4, 2026-10-27)
-------------------------------------
`ts_driver.py` could already write TAUm (0x40+4m) and EPSm (0x70+4m), but only the
bring-up tests (`verify_e4.py`, `verify_e4_sys.py`) ever called `set_eps`. **No
training or deployment script wrote them, and nothing read them back into the
model.** The model's eps came from hard-coded literature bounds (`EPS_DEV` in
`_build_npz_dt.py`) and tau_s was a constant handed to `build_gsr.py`.

This script closes that loop: it is the ONLY producer of the JSON that
`_build_npz_dt.py --pl-json` consumes, so the eps the model trains on is by
construction the number the hardware holds.

Sign convention, stated once so nobody has to guess
---------------------------------------------------
  * PL `TAUm` is SUBTRACTED from the timestamp by `tau_comp` (t_out = t − tau):
    it converts "sample arrival time" into "physiological event time".
  * `build_gsr.py` shifts the WINDOW by +tau (x0+tau, x1+tau): at model time
    [x0,x1] it feeds the GSR that RESPONDS to that interval, which arrives
    tau later.
  Both express "GSR lags the stimulus by tau"; one is applied to the timestamp,
  the other to the window. They are the same number, not the same operation.

  * `EPSm` is an ERROR BAR: stored, read back, never subtracted. Design 10_
    sec.3.4 asks for 2M = 8 time registers per modality, tau_m and eps_m.

ASCII only.  Needs root (raw /dev/mem at 0x40010000 -- the ts window of the
three-slave A1 BD; JTAG programming, so there is no .hwh).
"""

import argparse
import json
import os
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

from ts_driver import (TsTop, R_TAU0, R_EPS0,               # noqa: E402
                       seconds_to_counts, counts_to_seconds)

TS_BASE = 0x40010000          # three-slave BD: attn 0x4000_0000, ts 0x4001_0000
MODS = ["e", "o", "s", "a"]   # MOD_NAME = {0:EEG, 1:eye, 2:GSR, 3:AU}

# Physically motivated starting table. e/o/a are the DEVICE latency upper bounds
# already used as EPS_DEV in _build_npz_dt.py (12 / 40 / 33 ms, from the measured
# LSL setup offset 6-12 ms and the 40 ms camera pipeline). s is the GSR response
# lag, whose plausible span is seconds, not milliseconds.
EPS_TABLE = {"e": 0.012, "o": 0.040, "a": 0.033, "s": 0.900}
TAU_TABLE = {"e": 0.100, "o": 0.300, "a": 0.500, "s": 3.250}


def parse_pairs(s):
    out = {}
    for item in s.split(","):
        item = item.strip()
        if not item:
            continue
        k, v = item.split("=")
        k = k.strip()
        if k not in MODS:
            raise SystemExit("unknown modality %r (want e/o/s/a)" % k)
        out[k] = float(v)
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--base", default=hex(TS_BASE))
    ap.add_argument("--read", action="store_true", help="read only, no writes")
    ap.add_argument("--write", action="store_true", help="write then read back")
    ap.add_argument("--eps", default="", help="e=..,o=..,a=..,s=.. (seconds)")
    ap.add_argument("--tau", default="", help="e=..,o=..,a=..,s=.. (seconds)")
    ap.add_argument("--json", default="", help="write the result here")
    ap.add_argument("--note", default="", help="free text carried into the JSON")
    a = ap.parse_args()

    base = int(a.base, 0)
    ts = TsTop(None, base=base)            # raw /dev/mem, JTAG-programmed PL

    # `--write` with no explicit table means "write the physically motivated
    # table below".  Without this the constants were documentation only, and
    # `--write` silently printed eight zeros back (2026-10-27 first run).
    eps_t = parse_pairs(a.eps) if a.eps else (dict(EPS_TABLE) if a.write else {})
    tau_t = parse_pairs(a.tau) if a.tau else (dict(TAU_TABLE) if a.write else {})

    print("=== ts_top @ 0x%08X ===" % base)
    print("  LSB = %s counts/ns (model says 5 ns @200 MHz; the board's FCLK0 is 100 MHz"
          " -> 10 ns. The register unit here is whatever the driver's LSB is.)"
          % COUNT_LSB_NOTE)

    if a.write:
        print("")
        print("  writing tau_m (0x40+4m) and eps_m (0x70+4m)")
        for m, name in enumerate(MODS):
            if name in tau_t:
                ts.set_tau(m, tau_t[name])
            if name in eps_t:
                ts.set_eps(m, eps_t[name])
            print("    %s (mod %d)  tau = %10.6f s (%10d counts)"
                  "   eps = %10.6f s (%10d counts)"
                  % (name, m, ts.get_tau(m), ts.rd(R_TAU0 + 4 * m),
                     ts.get_eps(m), ts.get_eps_counts(m)))

    eps_s = {name: ts.get_eps(m) for m, name in enumerate(MODS)}
    tau_s = {name: ts.get_tau(m) for m, name in enumerate(MODS)}
    eps_c = {name: ts.get_eps_counts(m) for m, name in enumerate(MODS)}
    tau_c = {name: ts.rd(R_TAU0 + 4 * m) for m, name in enumerate(MODS)}

    print("")
    print("=== readback (this is what the model will train on) ===")
    for name in MODS:
        print("  %s  tau %12.6f s   eps %12.6f s" % (name, tau_s[name], eps_s[name]))

    # eps must survive a write/read round trip, and it must NOT be subtracted
    # from anything -- there is no readback path for "eps was applied", by design.
    bad = [n for n in MODS if a.write and n in eps_t
           and abs(eps_s[n] - eps_t[n]) > 2e-8]
    if bad:
        print("FAIL: eps did not round-trip for %s" % ",".join(bad))
        return 1

    doc = {
        "generated": time.strftime("%Y-%m-%dT%H:%M:%S"),
        "source": "pl_dt_bridge.py",
        "base": "0x%08X" % base,
        "eps_s": eps_s,
        "tau_s": tau_s,
        "eps_counts": eps_c,
        "tau_counts": tau_c,
        "note": a.note,
    }
    if a.json:
        with open(a.json, "w", encoding="utf-8") as f:
            json.dump(doc, f, indent=1, ensure_ascii=False)
        print("")
        print("  -> %s" % a.json)
    else:
        print("")
        print(json.dumps(doc, ensure_ascii=False))

    print("")
    print("BRIDGE_OK")
    return 0


COUNT_LSB_NOTE = "10 ns on the board (100 MHz FCLK0)"

if __name__ == "__main__":
    sys.exit(main())
