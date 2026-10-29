"""Board-side access, gated on proving which bitstream is loaded.

**This module has not been executed on hardware in its final form.** The offline
modules (`hwh`, `regmap`, `capture`) are tested; this one is written against the
PYNQ 3.x API and must be validated on a board before anyone trusts a number that
came out of it. It says so here rather than in a footnote.

The rule it enforces: nothing touches the design until an identity register has
been read and matched. Reading an ID register is the only cheap way to tell two
bitstreams apart from software -- the `.hwh` cannot do it (see
`hwh.HwDef.notes_on_parameters`), and neither can the bitstream md5 once the FPGA
is configured.

Usage on a board:

    from pynq_probe.overlay import Board
    b = Board.open("attn4_e4.xsa", "../regmap.json",
                   expect={"attn_0": {"ID": 0x41540001}})
    b.write_window("attn_0", "SCRATCH", words)
    b.start_and_wait("attn_0")
    got = b.read_window("attn_0", "SCRATCH", 8192)
"""

from __future__ import annotations

import time

from . import hwh, regmap


class IdentityMismatch(RuntimeError):
    pass


class Board:
    def __init__(self, overlay, spec: dict, hwdef: hwh.HwDef, addrs: dict):
        self.ol = overlay
        self.spec = spec
        self.hwdef = hwdef
        self.addrs = addrs

    # ------------------------------------------------------------------ open
    @classmethod
    def open(cls, overlay_path: str, spec_path: str, hwh_path: str | None = None,
             expect: dict | None = None) -> "Board":
        from pynq import Overlay          # imported here so the module is usable off-board

        spec = regmap.load(spec_path)
        if hwh_path is None:
            hwh_path = overlay_path if overlay_path.lower().endswith(".hwh") else None
            if hwh_path is None:
                hwh_path = overlay_path.rsplit(".", 1)[0] + ".hwh"
        hwdef = hwh.load(hwh_path)

        problems = regmap.validate(spec, hwdef)
        if problems:
            raise ValueError("register spec does not match the handoff file; refusing "
                             "to open the board:\n" +
                             "\n".join("  " + str(p) for p in problems))

        ol = Overlay(overlay_path)
        board = cls(ol, spec, hwdef, regmap.resolve(spec, hwdef))
        if expect:
            board.assert_identity(expect)
        return board

    # -------------------------------------------------------------- identity
    def read_reg(self, instance: str, name: str) -> int:
        ip = getattr(self.ol, instance)
        offset = self.addrs[instance][name] - self.hwdef.find(instance).base
        try:
            return int(ip.register_map.read(offset)) & 0xFFFFFFFF
        except AttributeError:
            return int(ip.mmio.read(offset)) & 0xFFFFFFFF

    def write_reg(self, instance: str, name: str, value: int) -> None:
        ip = getattr(self.ol, instance)
        offset = self.addrs[instance][name] - self.hwdef.find(instance).base
        try:
            ip.register_map.write(offset, value)
        except AttributeError:
            ip.mmio.write(offset, value)

    def identity(self, expect: dict) -> dict:
        """Read every identity register in `expect` and report actual vs wanted."""
        seen = {}
        for inst, regs in expect.items():
            seen[inst] = {name: self.read_reg(inst, name) for name in regs}
        return seen

    def assert_identity(self, expect: dict) -> dict:
        seen = self.identity(expect)
        bad = []
        for inst, regs in expect.items():
            for name, want in regs.items():
                got = seen[inst][name]
                if got != want:
                    bad.append(f"{inst}.{name}: got 0x{got:08X}, want 0x{want:08X}")
        if bad:
            raise IdentityMismatch(
                "the loaded bitstream is not the one this register map describes:\n  "
                + "\n  ".join(bad))
        return seen

    # --------------------------------------------------------------- windows
    def _window(self, instance: str, name: str):
        win = self.spec["ips"][instance]["windows"][name]
        base = self.addrs[instance][name]
        return win, base - self.hwdef.find(instance).base

    def write_window(self, instance: str, name: str, words: list[int]) -> None:
        """Write 16-bit words; each 32-bit beat carries two of them."""
        win, off = self._window(instance, name)
        if win.get("word_bits", 16) != 16:
            raise ValueError("write_window only handles 16-bit windows")
        if len(words) * 2 > win["size"]:
            raise ValueError(f"{len(words)} words do not fit {win['size']} B")
        ip = getattr(self.ol, instance)
        padded = words + [0] * (len(words) % 2)
        for i in range(0, len(padded), 2):
            beat = (padded[i] & 0xFFFF) | ((padded[i + 1] & 0xFFFF) << 16)
            try:
                ip.register_map.write(off + 4 * (i // 2), beat)
            except AttributeError:
                ip.mmio.write(off + 4 * (i // 2), beat)

    def read_window(self, instance: str, name: str, n_words: int) -> list[int]:
        win, off = self._window(instance, name)
        ip = getattr(self.ol, instance)
        out: list[int] = []
        for i in range((n_words + 1) // 2):
            try:
                beat = int(ip.register_map.read(off + 4 * i))
            except AttributeError:
                beat = int(ip.mmio.read(off + 4 * i))
            out.append(beat & 0xFFFF)
            out.append((beat >> 16) & 0xFFFF)
        return out[:n_words]

    # ----------------------------------------------------------------- run
    def start_and_wait(self, instance: str, ctrl="CTRL", status="STATUS",
                       start_bit=0, busy_bit=0, done_bit=1, clear="DONE_CLR",
                       timeout_s: float = 1.0, poll_s: float = 50e-6) -> float:
        """Pulse START, wait for the sticky DONE, clear it, return seconds elapsed.

        Returns the wall-clock duration spent polling. That is **not** the engine
        latency: it is latency plus polling granularity. If you need the engine
        latency, count cycles in a hardware counter or in simulation.
        """
        # Clear any DONE left over from a previous run first, otherwise the loop
        # below can return immediately on a stale bit and report a near-zero time.
        self.write_reg(instance, clear, 1)
        self.write_reg(instance, ctrl, 1 << start_bit)

        t0 = time.perf_counter()
        deadline = t0 + timeout_s
        saw_busy = False
        while time.perf_counter() < deadline:
            st = self.read_reg(instance, status)
            if st & (1 << done_bit):
                elapsed = time.perf_counter() - t0
                self.write_reg(instance, clear, 1)
                return elapsed
            busy = bool(st & (1 << busy_bit))
            if saw_busy and not busy:
                raise RuntimeError(
                    f"{instance}: BUSY dropped without DONE. The run either never "
                    f"completed or the status bit means something else -- do not "
                    f"report a time from this.")
            saw_busy = saw_busy or busy
            time.sleep(poll_s)
        raise TimeoutError(f"{instance}: DONE not seen within {timeout_s}s")
