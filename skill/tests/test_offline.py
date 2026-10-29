"""Offline tests for pynq_probe. No board, no pynq, no network.

Run:  python test_offline.py          (from this directory)
      ./run_tests.sh                  (any directory)

Every case here is a failure that actually occurred in this project or one that
the tool is specifically built to catch. The last case is the important one: it
pins down that the handoff file cannot tell you the engine's scratch depth, which
is why an identity register exists.
"""

from __future__ import annotations

import json
import os
import shutil
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
SKILL = os.path.dirname(HERE)
REPO = os.path.dirname(SKILL)
sys.path.insert(0, SKILL)

from pynq_probe import capture, hwh, regmap  # noqa: E402

HWH = os.path.join(HERE, "data", "all_bd.hwh")
SPEC = os.path.join(SKILL, "regmap.json")
VEC_M4 = os.path.join(REPO, "sim", "vectors", "m4")

_failures: list[str] = []


def check(name: str, cond: bool, detail: str = "") -> None:
    if cond:
        print(f"  PASS  {name}")
    else:
        print(f"  FAIL  {name}" + (f"\n        {detail}" if detail else ""))
        _failures.append(name)


def eq(name: str, got, want) -> None:
    check(name, got == want, f"got {got!r}, want {want!r}")


def _run_golden_compare_cases() -> int:
    """Run golden_compare.py against a real committed weight file, five ways."""
    import subprocess

    import numpy as np

    src = os.path.join(REPO, "src", "model", "assets", "w_attn4_p_emotion_v_f0.npz")
    if not os.path.exists(src):
        print("        (weight file not found, skipping)")
        return 1

    tool = os.path.join(SKILL, "golden_compare.py")
    tmp = tempfile.mkdtemp(prefix="gc_")
    try:
        def run(cand: str) -> int:
            out = os.path.join(tmp, "cmp.json")
            return subprocess.run(
                [sys.executable, "-I", tool, src, cand, "--out", out],
                capture_output=True).returncode

        with np.load(src, allow_pickle=False) as g:
            data = {k: g[k] for k in g.files}
        keys = sorted(data)
        if not keys:
            print("        (weight file is empty)")
            return 1
        k0 = keys[0]

        def save(name: str, **override) -> str:
            d = dict(data)
            d.update(override)
            p = os.path.join(tmp, name)
            np.savez(p, **d)
            return p + ".npz" if not p.endswith(".npz") else p

        cases = []

        same = save("same.npz")
        cases.append(("identical copies pass", run(same) == 0))

        w = data[k0].copy()
        flat = w.reshape(-1)
        if flat.dtype.kind in "iu":
            flat[0] = int(flat[0]) + 1
        else:
            flat[0] = np.nextafter(flat[0], np.inf)
        cases.append(("one changed word fails", run(save("word.npz", **{k0: w})) != 0))

        missing = {k: v for k, v in data.items() if k != k0}
        p = os.path.join(tmp, "missing.npz")
        np.savez(p, **missing)
        cases.append(("a missing array fails", run(p) != 0))

        cases.append(("a dtype change fails",
                      run(save("dtype.npz", **{k0: data[k0].astype(np.float64)
                                               if data[k0].dtype != np.float64
                                               else data[k0].astype(np.float32)})) != 0))

        cases.append(("a shape change fails",
                      run(save("shape.npz", **{k0: np.resize(data[k0],
                                                            data[k0].size - 1)})) != 0))

        ok = 0
        for name, passed in cases:
            check(name, passed)
            ok += passed
        return 0 if ok == len(cases) else 1
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def main() -> int:
    print("1. handoff file parses")
    hw = hwh.load(HWH)
    eq("9 IP blocks", len(hw.ips), 9)
    eq("device", hw.device, "7z020")
    eq("speed grade", hw.package, "clg400")
    eq("three user IP", sorted(ip.instance for ip in hw.custom_ips()),
       ["attn_0", "eeg_0", "ts_0"])

    attn = hw.find("attn_0")
    eq("attn_0 base", attn.base, 0x40000000)
    eq("attn_0 high", attn.high, 0x4000FFFF)
    eq("attn_0 aperture bytes", attn.aperture, 0x10000)
    eq("attn_0 clock", attn.clock_hz, 200_000_000)
    eq("find by modtype", hw.find("attn_axi").instance, "attn_0")

    eq("address map is ordered",
       [(inst) for _, _, inst in hw.address_map()][:3],
       ["attn_0", "ts_0", "eeg_0"])

    print("2. the handoff file does not record the scratch depth")
    eq("no UM parameter for attn_0", "UM" in attn.params, False)
    check("and the tool says so", bool(hw.notes_on_parameters()),
          "notes_on_parameters() returned nothing")

    print("3. register spec validates against the handoff file")
    spec = regmap.load(SPEC)
    problems = regmap.validate(spec, hw)
    check("no problems", not problems, "\n        ".join(str(p) for p in problems))

    print("4. addresses resolve to what the RTL decodes")
    addrs = regmap.resolve(spec, hw)
    eq("attn_0.ID", hex(addrs["attn_0"]["ID"]), hex(0x40000008))
    eq("attn_0.SCRATCH", hex(addrs["attn_0"]["SCRATCH"]), hex(0x40000100))
    eq("eeg_0.BUILD", hex(addrs["eeg_0"]["BUILD"]), hex(0x40020020))
    eq("eeg_0.GEOM", hex(addrs["eeg_0"]["GEOM"]), hex(0x40020024))
    eq("ts_0.SRC", hex(addrs["ts_0"]["SRC"]), hex(0x4001005C))

    print("5. identity expectations")
    expect = regmap.identity_expectations(spec)
    eq("attn_0.ID value", hex(expect["attn_0"]["ID"]), hex(0x41540001))
    eq("eeg_0.BUILD value", hex(expect["eeg_0"]["BUILD"]), hex(0x5EED0001))
    eq("ts_0.SRC is report-only",
       [n for i, n in regmap.informational_identities(spec) if i == "ts_0"], ["SRC"])

    print("6. a spec that has drifted is rejected, not accepted")
    tmp = tempfile.mkdtemp(prefix="pynq_probe_")
    try:
        bad = json.loads(json.dumps(spec))

        bad["ips"]["attn_0"]["windows"]["SCRATCH"]["size"] = 0x10000 + 4
        p = regmap.validate(bad, hw)
        check("window past the aperture is caught",
              any("runs past the aperture" in str(x) for x in p), str(p))

        bad = json.loads(json.dumps(spec))
        bad["ips"]["attn_0"]["regs"]["CLASH"] = {"offset": 8, "width": 32}
        p = regmap.validate(bad, hw)
        check("overlapping registers are caught",
              any("overlap" in str(x) for x in p), str(p))

        bad = json.loads(json.dumps(spec))
        bad["ips"]["eeg_0"]["regs"]["STATUS"]["fields"]["FCNT"]["bits"] = [15, 9]
        bad["ips"]["eeg_0"]["regs"]["STATUS"]["fields"]["OVF"]["bits"] = [16, 15]
        p = regmap.validate(bad, hw)
        check("overlapping fields are caught",
              any("already used by field" in str(x) for x in p), str(p))

        bad = json.loads(json.dumps(spec))
        bad["ips"]["attn_0"]["modtype"] = "attn_axi_v2"
        p = regmap.validate(bad, hw)
        check("a renamed IP is caught",
              any("modtype" in str(x) for x in p), str(p))

        bad = json.loads(json.dumps(spec))
        bad["ips"]["attn_0"]["params"]["T"] = 8
        p = regmap.validate(bad, hw)
        check("a parameter mismatch is caught",
              any("param T" in str(x) for x in p), str(p))

        bad = json.loads(json.dumps(spec))
        bad["ips"]["nope_0"] = {"regs": {}}
        p = regmap.validate(bad, hw)
        check("an instance that is not in the FPGA is caught",
              any("nope_0" in str(x) for x in p), str(p))

        path = os.path.join(tmp, "bad.json")
        with open(path, "w", encoding="utf-8") as f:
            json.dump(bad, f)
        try:
            regmap.resolve(bad, hw)
            check("resolve refuses a bad spec", False, "no exception raised")
        except ValueError:
            check("resolve refuses a bad spec", True)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)

    print("7. field encode / decode")
    v = 0x00010206
    d = regmap.decode(spec, "eeg_0", "STATUS", v)
    eq("DONE", d["DONE"], 1)
    eq("FIFO_EMPTY", d["FIFO_EMPTY"], 1)
    eq("FCNT", d["FCNT"], 0x02)
    eq("OVF", d["OVF"], 1)
    eq("round trip", regmap.encode(spec, "eeg_0", "STATUS", **d), v)

    try:
        regmap.encode(spec, "eeg_0", "STATUS", FCNT=256)
        check("an out-of-range field is refused", False, "no exception raised")
    except ValueError:
        check("an out-of-range field is refused", True)

    try:
        regmap.encode(spec, "attn_0", "CTRL", NOPE=1)
        check("an unknown field is refused", False, "no exception raised")
    except KeyError:
        check("an unknown field is refused", True)

    print("8. captured words round trip and compare exactly")
    golden_path = os.path.join(VEC_M4, "in.mem")
    golden = capture.read_file(golden_path)
    eq("in.mem has 1636 words", len(golden), 1636)
    eq("first word", hex(golden[0]), hex(0xFE40))

    ok = capture.compare(golden, list(golden))
    check("identical blocks pass", ok.ok and ok.n == 1636)

    changed = list(golden)
    changed[900] ^= 1
    res = capture.compare(changed, golden)
    check("a one-bit change fails", not res.ok)
    eq("and names the word", res.diffs[0].index if res.diffs else None, 900)

    trunc = capture.compare(golden[:-1], golden)
    check("a short capture fails even though every word matches", not trunc.ok)
    check("and says why", "length 1635 vs 1636" in trunc.note, trunc.note)

    eq("a serial-style dump parses the same",
       capture.parse_words("Z_S0: %04x %04x  // trailing comment"
                           % (golden[0], golden[1])),
       golden[:2])
    eq("address markers are ignored", capture.parse_words("@0000 dead 0xBEEF"), [0xDEAD, 0xBEEF])

    print("9. golden_compare still passes and still fails for the right reasons")
    rc = _run_golden_compare_cases()
    check("all five NPZ cases behave", rc == 0)

    print()
    if _failures:
        print(f"{len(_failures)} FAILED: {', '.join(_failures)}")
        return 1
    print("all offline checks passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
