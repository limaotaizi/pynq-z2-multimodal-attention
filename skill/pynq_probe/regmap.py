"""Register-map specifications, checked against the hardware before you touch it.

The failure this prevents: a driver written against a register map that no longer
matches the bitstream in the FPGA. The symptoms are ugly and varied -- a write
lands in the wrong block, a status bit reads back as a data bit, a window runs
past the aperture into unmapped address space (where an AXI slave may still
answer OKAY and return garbage). None of them look like a register-map problem,
so people debug the wrong thing for a day.

So: describe the map once, in JSON, and validate it against the `.hwh` before the
first MMIO access. `validate()` is offline and catches every one of those.

Spec format -- see `../regmap.json` for a filled-in example:

    {
      "design": "all_bd",
      "ips": {
        "<instance>": {
          "modtype": "<MODTYPE from the hwh>",        // checked
          "params":  {"T": 4},                         // checked where listed
          "regs": {
            "<NAME>": {"offset": 0, "width": 32, "access": "rw"|"r"|"w",
                       "fields": {"<FIELD>": {"bits": [hi, lo], "desc": "..."}}}
          },
          "windows": {
            "<NAME>": {"offset": 256, "size": 16384,
                       "word_bits": 16, "access": "rw"}
          }
        }
      }
    }
"""

from __future__ import annotations

import json
from dataclasses import dataclass

from .hwh import HwDef, Ip


@dataclass
class Problem:
    instance: str
    where: str
    message: str

    def __str__(self) -> str:
        return f"{self.instance}/{self.where}: {self.message}"


def load(path: str) -> dict:
    with open(path, encoding="utf-8") as f:
        spec = json.load(f)
    if "ips" not in spec:
        raise ValueError(f"{path}: spec has no 'ips' section")
    return spec


def validate(spec: dict, hwdef: HwDef) -> list[Problem]:
    """Return every mismatch between the spec and the handoff file. Empty == ok."""
    problems: list[Problem] = []

    for inst, debe in spec["ips"].items():
        try:
            hw = hwdef.find(inst)
        except KeyError as exc:
            problems.append(Problem(inst, "-", str(exc)))
            continue

        modtype = debe.get("modtype")
        if modtype and modtype != hw.modtype:
            problems.append(Problem(
                inst, "-", f"spec says modtype {modtype!r}, hardware says {hw.modtype!r}"))

        problems += _check_params(inst, debe, hw)
        problems += _check_regions(inst, debe, hw)
        problems += _check_fields(inst, debe)

    return problems


def _check_params(inst: str, debe: dict, hw: Ip) -> list[Problem]:
    out = []
    for name, want in (debe.get("params") or {}).items():
        got = hw.params.get(name)
        if got is None:
            out.append(Problem(inst, f"param {name}",
                               f"spec expects {want!r}, but the handoff file does not "
                               f"record this parameter at all -- it cannot be checked "
                               f"from here, and it may not be settable from the block "
                               f"design either"))
        elif str(got) != str(want):
            out.append(Problem(inst, f"param {name}",
                               f"spec expects {want!r}, hardware has {got!r}"))
    return out


def _check_regions(inst: str, debe: dict, hw: Ip) -> list[Problem]:
    out = []
    if hw.base is None:
        if debe.get("regs") or debe.get("windows"):
            out.append(Problem(inst, "-",
                               "spec declares registers but this IP has no AXI aperture"))
        return out

    ap = hw.aperture
    spans: list[tuple[int, int, str]] = []

    for name, reg in (debe.get("regs") or {}).items():
        off = int(reg["offset"])
        width_bytes = int(reg.get("width", 32)) // 8
        if off < 0 or off + width_bytes > ap:
            out.append(Problem(inst, name,
                               f"register at offset 0x{off:X} (+{width_bytes} B) is outside "
                               f"the aperture 0x0-0x{ap - 1:X}"))
        spans.append((off, off + width_bytes, name))

    for name, win in (debe.get("windows") or {}).items():
        off = int(win["offset"])
        size = int(win["size"])
        if off < 0 or off + size > ap:
            out.append(Problem(inst, name,
                               f"window 0x{off:X}..0x{off + size - 1:X} runs past the "
                               f"aperture 0x0-0x{ap - 1:X}"))
        spans.append((off, off + size, name))

    spans.sort()
    for (a0, a1, a), (b0, b1, b) in zip(spans, spans[1:]):
        if b0 < a1:
            out.append(Problem(inst, f"{a}/{b}",
                               f"regions overlap: {a} 0x{a0:X}-0x{a1 - 1:X} and "
                               f"{b} 0x{b0:X}-0x{b1 - 1:X}"))
    return out


def _check_fields(inst: str, debe: dict) -> list[Problem]:
    out = []
    for name, reg in (debe.get("regs") or {}).items():
        width = int(reg.get("width", 32))
        used: dict[int, str] = {}
        for fname, fdef in (reg.get("fields") or {}).items():
            hi, lo = fdef["bits"]
            if not (0 <= lo <= hi < width):
                out.append(Problem(inst, f"{name}.{fname}",
                                   f"bits [{hi}:{lo}] do not fit a {width}-bit register"))
                continue
            for bit in range(lo, hi + 1):
                if bit in used:
                    out.append(Problem(inst, f"{name}.{fname}",
                                       f"bit {bit} already used by field {used[bit]}"))
                used[bit] = fname
    return out


def resolve(spec: dict, hwdef: HwDef) -> dict[str, dict[str, int]]:
    """Absolute address for every register and window, keyed by instance.

    Refuses to resolve a spec that does not validate: an address you cannot
    trust is worse than no address.
    """
    problems = validate(spec, hwdef)
    if problems:
        raise ValueError("spec does not match the hardware:\n" +
                         "\n".join("  " + str(p) for p in problems))
    out: dict[str, dict[str, int]] = {}
    for inst, debe in spec["ips"].items():
        base = hwdef.find(inst).base
        rows: dict[str, int] = {}
        for name, reg in (debe.get("regs") or {}).items():
            rows[name] = base + int(reg["offset"])
        for name, win in (debe.get("windows") or {}).items():
            rows[name] = base + int(win["offset"])
        out[inst] = rows
    return out


def identity_expectations(spec: dict) -> dict[str, dict[str, int]]:
    """Registers marked `identity: true` and carrying an expected value.

    Pass the result to `overlay.Board.open(..., expect=...)`. A register marked
    identity without `expect` is informational: report it, do not match it.
    """
    out: dict[str, dict[str, int]] = {}
    for inst, debe in spec["ips"].items():
        for name, reg in (debe.get("regs") or {}).items():
            if reg.get("identity") and "expect" in reg:
                out.setdefault(inst, {})[name] = int(reg["expect"])
    return out


def informational_identities(spec: dict) -> list[tuple[str, str]]:
    """Identity registers with no expected value (e.g. a source-select field)."""
    out = []
    for inst, debe in spec["ips"].items():
        for name, reg in (debe.get("regs") or {}).items():
            if reg.get("identity") and "expect" not in reg:
                out.append((inst, name))
    return out


def decode(spec: dict, instance: str, reg_name: str, value: int) -> dict[str, int]:
    """Split a register value into its named fields."""
    reg = spec["ips"][instance]["regs"][reg_name]
    out = {}
    for fname, fdef in (reg.get("fields") or {}).items():
        hi, lo = fdef["bits"]
        out[fname] = (value >> lo) & ((1 << (hi - lo + 1)) - 1)
    return out


def encode(spec: dict, instance: str, reg_name: str, **fields) -> int:
    """Build a register value from named fields. Unknown or out-of-range fails."""
    reg = spec["ips"][instance]["regs"][reg_name]
    fdefs = reg.get("fields") or {}
    width = int(reg.get("width", 32))
    value = 0
    for fname, fval in fields.items():
        if fname not in fdefs:
            raise KeyError(f"{instance}.{reg_name} has no field {fname!r}; "
                           f"known: {sorted(fdefs)}")
        hi, lo = fdefs[fname]["bits"]
        nbits = hi - lo + 1
        if not (0 <= fval < (1 << nbits)):
            raise ValueError(f"{fname}={fval} does not fit {nbits} bits")
        value |= fval << lo
    if value >= (1 << width):
        raise ValueError(f"value 0x{value:X} does not fit a {width}-bit register")
    return value
