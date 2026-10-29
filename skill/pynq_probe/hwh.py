"""Read a Vivado hardware handoff file (.hwh) and answer three questions.

   1. What IP is actually in this bitstream, and at which address?
   2. What clock does each AXI slave see?
   3. Which parameters did Vivado record -- and, more importantly, which did it
      not?

The third question is the reason this module exists. An .hwh is the closest
thing PYNQ gives you to a description of the loaded programmable logic, and it
is easy to over-trust: it lists the IP, its address aperture and its AXI
parameters, but it does **not** list Verilog parameters whose value came from a
macro default rather than from the IP packaging. Those parameters still decide
what the design computes. See `notes_on_parameters()` and the test in
`tests/test_offline.py` that pins this down for this project.
"""

from __future__ import annotations

import os
import zipfile
import xml.etree.ElementTree as ET
from dataclasses import dataclass, field


@dataclass
class Ip:
    instance: str
    modtype: str
    vlnv: str
    base: int | None = None
    high: int | None = None
    params: dict[str, str] = field(default_factory=dict)
    clock_hz: int | None = None

    @property
    def aperture(self) -> int | None:
        if self.base is None or self.high is None:
            return None
        return self.high - self.base + 1

    def __str__(self) -> str:
        addr = "no AXI" if self.base is None else f"0x{self.base:08X}-0x{self.high:08X}"
        clk = "" if self.clock_hz is None else f" @{self.clock_hz/1e6:g} MHz"
        return f"{self.instance:<16} {self.modtype:<24} {addr}{clk}"


@dataclass
class HwDef:
    path: str
    device: str
    package: str
    arch: str
    board: str
    vivado: str
    timestamp: str
    ips: dict[str, Ip]

    def find(self, name: str) -> Ip:
        """Look up by instance name first, then by MODTYPE. Raises if ambiguous."""
        if name in self.ips:
            return self.ips[name]
        hits = [ip for ip in self.ips.values() if ip.modtype == name]
        if not hits:
            known = ", ".join(f"{i}({p.modtype})" for i, p in self.ips.items())
            raise KeyError(f"no IP named {name!r} in {self.path}; known: {known}")
        if len(hits) > 1:
            raise KeyError(f"{name!r} matches {len(hits)} instances: "
                           f"{[h.instance for h in hits]}")
        return hits[0]

    def address_map(self) -> list[tuple[int, int, str]]:
        """(base, high, instance) for every IP with an AXI aperture, in address order."""
        rows = [(ip.base, ip.high, ip.instance) for ip in self.ips.values()
                if ip.base is not None]
        return sorted(rows)

    def custom_ips(self) -> list[Ip]:
        """IP not packaged by Xilinx -- i.e. the user's own RTL."""
        return [ip for ip in self.ips.values() if not ip.vlnv.startswith("xilinx.com:")]

    def notes_on_parameters(self) -> list[str]:
        """Parameters that a reader might expect to find here but will not."""
        out = []
        missing_um = [ip.instance for ip in self.custom_ips()
                      if ip.base is not None and "UM" not in ip.params]
        if missing_um:
            out.append(
                "No parameter named 'UM' is recorded for " + ", ".join(missing_um) + ".\n"
                "  That is not an omission. A Verilog parameter whose value comes from\n"
                "  a `define is resolved by the file reader, not by the block design,\n"
                "  so Vivado never writes it here. Two builds of the same IP can be\n"
                "  identical in this file and compute different things. If the data\n"
                "  path depth matters, verify it from an identity register or from\n"
                "  the bitstream md5 -- not from this file.")
        return out


def _read_text(path: str) -> str:
    """Accept a .hwh, or a .xsa (zip) containing one."""
    if zipfile.is_zipfile(path):
        with zipfile.ZipFile(path) as z:
            names = [n for n in z.namelist() if n.lower().endswith(".hwh")]
            if not names:
                raise ValueError(f"{path} is an archive but has no .hwh inside")
            if len(names) > 1:
                raise ValueError(f"{path} has several .hwh files: {names}")
            return z.read(names[0]).decode("utf-8-sig", errors="replace")
    with open(path, "rb") as f:
        return f.read().decode("utf-8-sig", errors="replace")


def load(path: str) -> HwDef:
    """Parse a .hwh or .xsa into a HwDef."""
    if not os.path.exists(path):
        raise FileNotFoundError(path)
    root = ET.fromstring(_read_text(path))

    sysinfo = root.find("SYSTEMINFO")
    if sysinfo is None:
        raise ValueError("no <SYSTEMINFO> element: this is not a Vivado handoff file")

    ips: dict[str, Ip] = {}
    for mod in root.iter("MODULE"):
        inst = mod.get("INSTANCE")
        if not inst:
            continue
        ip = Ip(instance=inst,
                modtype=mod.get("MODTYPE", ""),
                vlnv=mod.get("VLNV", ""))

        for p in mod.iter("PARAMETER"):
            name, value = p.get("NAME"), p.get("VALUE", "")
            ip.params[name] = value
        try:
            ip.base = int(ip.params["C_BASEADDR"], 0)
            ip.high = int(ip.params["C_HIGHADDR"], 0)
        except (KeyError, ValueError):
            ip.base = ip.high = None

        # First clock port with a declared frequency wins; all ports of one IP
        # sit on the same AXI clock in every design this tool has been used on,
        # and if they ever differ we want the number to be obviously suspicious.
        for port in mod.iter("PORT"):
            if port.get("SIGIS") == "clk" and port.get("CLKFREQUENCY"):
                try:
                    ip.clock_hz = int(port.get("CLKFREQUENCY"))
                except ValueError:
                    pass
                break

        ips[inst] = ip

    if not ips:
        raise ValueError("no <MODULE> elements: handoff file is empty?")

    return HwDef(path=path,
                 device=sysinfo.get("DEVICE", "?"),
                 package=sysinfo.get("PACKAGE", "?"),
                 arch=sysinfo.get("ARCH", "?"),
                 board=sysinfo.get("BOARD", "?"),
                 vivado=root.get("VIVADOVERSION", "?"),
                 timestamp=root.get("TIMESTAMP", "?"),
                 ips=ips)
