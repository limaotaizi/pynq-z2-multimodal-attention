"""Turn captured words into a verdict.

Reading a block of words out of an AXI window is easy. Deciding whether what came
back is *the right* block is the part people get wrong, in three specific ways:

  * comparing only the words that happen to be printed, so a short capture passes;
  * comparing values with a tolerance, so an off-by-one bit passes;
  * not recording which bitstream produced the capture, so a pass cannot be tied
    to a design at all.

`compare()` refuses all three: lengths must match exactly, values must match
exactly, and the caller is expected to pass a `bitstream_id` that ends up in the
report.

Word formats accepted by `parse_words()`: any whitespace-separated tokens that
parse as hexadecimal integers, after stripping `0x`, `@address` markers, `//`
comments and `#` comments. That covers a `.mem` file and a serial dump.
"""

from __future__ import annotations

import hashlib
import re
from dataclasses import dataclass, field

_TOKEN = re.compile(r"^(0[xX])?([0-9a-fA-F]+)$")


def parse_words(text: str) -> list[int]:
    """Extract hex words from text, ignoring comments, addresses and labels."""
    words: list[int] = []
    for line in text.splitlines():
        line = line.split("//", 1)[0].split("#", 1)[0]
        # "Z_S0: 00 01" -> drop the label; "0x0100: dead" -> drop the address
        line = re.sub(r"[A-Za-z_][A-Za-z0-9_.\[\]]*\s*:", " ", line)
        line = re.sub(r"@[0-9a-fA-F]+", " ", line)
        for tok in line.split():
            m = _TOKEN.match(tok)
            if m:
                words.append(int(m.group(2), 16))
    return words


@dataclass
class Diff:
    index: int
    got: int
    want: int

    def __str__(self) -> str:
        return f"word[{self.index}] got 0x{self.got:X} want 0x{want:X}"


@dataclass
class Result:
    ok: bool
    n: int
    diffs: list[Diff] = field(default_factory=list)
    got_sha256: str = ""
    want_sha256: str = ""
    note: str = ""

    def summary(self) -> str:
        if self.ok:
            return f"PASS  {self.n} words bit-exact  sha256 {self.got_sha256[:16]}"
        head = f"FAIL  {len(self.diffs)} of {self.n} words differ"
        if self.diffs:
            head += f"  first: {self.diffs[0]}"
        return head + (f"  ({self.note})" if self.note else "")


def _sha(words: list[int], width_bytes: int = 2) -> str:
    h = hashlib.sha256()
    for w in words:
        h.update(w.to_bytes(width_bytes, "big", signed=False))
    return h.hexdigest()


def compare(got: list[int], want: list[int], *, width_bytes: int = 2,
            bitstream_id: str = "") -> Result:
    """Bit-exact comparison. Length mismatch is a failure, not a warning."""
    note = ""
    if len(got) != len(want):
        note = f"length {len(got)} vs {len(want)}"
    if bitstream_id:
        note = (note + "; " if note else "") + f"bitstream {bitstream_id}"

    n = min(len(got), len(want))
    diffs = [Diff(i, got[i], want[i]) for i in range(n) if got[i] != want[i]]

    return Result(ok=not diffs and len(got) == len(want),
                  n=len(want),
                  diffs=diffs[:64],
                  got_sha256=_sha(got, width_bytes),
                  want_sha256=_sha(want, width_bytes),
                  note=note)


def read_file(path: str) -> list[int]:
    with open(path, encoding="utf-8", errors="replace") as f:
        return parse_words(f.read())
