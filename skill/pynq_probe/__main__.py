"""Command line. Every subcommand works without hardware except `run`."""

from __future__ import annotations

import argparse
import sys

from . import capture, hwh, regmap


def cmd_hwh(args) -> int:
    hw = hwh.load(args.hwh)
    print(f"design   {hw.board}  {hw.device}-{hw.package}")
    print(f"vivado   {hw.vivado}   handoff generated {hw.timestamp}")
    print()
    print("address map (AXI apertures, in address order)")
    for base, high, inst in hw.address_map():
        ip = hw.ips[inst]
        clk = "" if ip.clock_hz is None else f"  {ip.clock_hz / 1e6:g} MHz"
        print(f"  0x{base:08X}-0x{high:08X}  {inst:<14} {ip.modtype:<22}{clk}")
    print()
    custom = hw.custom_ips()
    print(f"user IP: {', '.join(ip.instance for ip in custom) or '(none)'}")
    for note in hw.notes_on_parameters():
        print()
        print("NOTE: " + note)
    return 0


def cmd_check(args) -> int:
    hw = hwh.load(args.hwh)
    spec = regmap.load(args.spec)
    problems = regmap.validate(spec, hw)
    if not problems:
        print(f"OK  {len(spec['ips'])} IP blocks match {args.hwh}")
        return 0
    print(f"FAIL  {len(problems)} problem(s):")
    for p in problems:
        print("  " + str(p))
    return 1


def cmd_ident(args) -> int:
    hw = hwh.load(args.hwh)
    spec = regmap.load(args.spec)
    expect = regmap.identity_expectations(spec)
    print("identity registers to match at run time:")
    for inst, regs in expect.items():
        ip = hw.find(inst)
        for name, val in regs.items():
            off = int(spec["ips"][inst]["regs"][name]["offset"])
            print(f"  {inst}.{name:<8} @0x{ip.base + off:08X}  == 0x{val:08X}")
    info = regmap.informational_identities(spec)
    if info:
        print("\nreport-only (no expected value):")
        for inst, name in info:
            off = int(spec["ips"][inst]["regs"][name]["offset"])
            print(f"  {inst}.{name:<8} @0x{hw.find(inst).base + off:08X}")
    return 0


def cmd_cmp(args) -> int:
    got = capture.read_file(args.captured)
    want = capture.read_file(args.golden)
    res = capture.compare(got, want, width_bytes=args.word_bytes,
                          bitstream_id=args.bitstream or "")
    print(res.summary())
    for d in res.diffs[:args.max_diffs]:
        print("  " + str(d))
    return 0 if res.ok else 1


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(prog="pynq_probe", description=__doc__)
    sub = ap.add_subparsers(dest="cmd", required=True)

    p = sub.add_parser("hwh", help="summarise an .hwh or .xsa")
    p.add_argument("hwh")
    p.set_defaults(fn=cmd_hwh)

    for name, fn, help_ in (("check", cmd_check, "validate a register spec"),
                            ("ident", cmd_ident, "list identity registers and addresses")):
        p = sub.add_parser(name, help=help_)
        p.add_argument("hwh")
        p.add_argument("--spec", required=True)
        p.set_defaults(fn=fn)

    p = sub.add_parser("cmp", help="bit-exact compare of two word dumps")
    p.add_argument("golden")
    p.add_argument("captured")
    p.add_argument("--word-bytes", type=int, default=2)
    p.add_argument("--bitstream", default="")
    p.add_argument("--max-diffs", type=int, default=8)
    p.set_defaults(fn=cmd_cmp)

    args = ap.parse_args(argv)
    return args.fn(args)


if __name__ == "__main__":
    sys.exit(main())
