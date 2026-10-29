# Skill package

Two reusable tools and the register map of this design. Both come out of failures
this project actually had, and the boundary of each is stated by its own author,
not left for a reviewer to discover.

```
skill/
  golden_compare.py     NPZ numerical comparator (bit-exact by default)
  regmap.json           the register map of all three user IP, transcribed from RTL
  pynq_probe/           handoff parsing, register-map checking, capture comparison
  tests/                50 offline checks, no board required
  validation.json       what has been verified, and what has not
```

Run the tests:

```sh
sh skill/tests/run_tests.sh
```

---

## 1 `pynq_probe` — check what is in the FPGA, then talk to it

The recurring failure in FPGA/SoC work is not a bug in the logic. It is **software
talking to a design that is not the one the software was written for**. The
symptoms look like logic bugs: a write lands in the wrong block, a status bit reads
back as a data bit, a result block is off by a fixed offset, a window silently runs
past the end of an aperture (AXI slaves answer OKAY outside their real range).

`pynq_probe` attacks that with three offline steps before the first MMIO access,
plus one board module.

### `pynq_probe.hwh` — what is actually in the bitstream

```python
>>> from pynq_probe import hwh
>>> hw = hwh.load("all_bd.xsa")          # .xsa or .hwh, either is fine
>>> for base, high, inst in hw.address_map(): print(f"{inst} 0x{base:08X}")
attn_0 0x40000000
ts_0 0x40010000
eeg_0 0x40020000
```

It also reports what the handoff file **cannot** tell you: parameters set through a
Verilog `` `define `` are resolved by the file reader, never written into the
handoff file, and therefore cannot be changed from the block design. In this design
that is `UM`, the scratch depth — two builds can be byte-identical in the `.hwh`
and compute different things. `hw.notes_on_parameters()` says so, and
`tests/test_offline.py` asserts the parameter's absence so the point cannot quietly
disappear from the file.

### `pynq_probe.regmap` — does my driver match that?

Describe the map once, in JSON (`regmap.json`), and validate it against the
handoff file:

```sh
python -m pynq_probe hwh   board/all_bd.hwh
python -m pynq_probe check board/all_bd.hwh --spec skill/regmap.json
python -m pynq_probe ident board/all_bd.hwh --spec skill/regmap.json
```

`check` rejects: a register or window outside the IP's AXI aperture, overlapping
regions, overlapping fields, a field wider than its register, a `modtype` mismatch,
a parameter mismatch, and an instance that is not in the FPGA. `resolve()` refuses
to hand out addresses for a spec that did not validate — an address you cannot
trust is worse than no address.

Field helpers round-trip:

```python
regmap.decode(spec, "eeg_0", "STATUS", 0x00010206)
# {'BUSY': 0, 'DONE': 1, 'FIFO_EMPTY': 1, 'FIFO_FULL': 0, 'FCNT': 2, 'OVF': 1}
```

### `pynq_probe.capture` — is the result block right?

```sh
python -m pynq_probe cmp sim/vectors/m4/in.mem captured.txt --bitstream attn4_e4.bit
```

Exact length, exact values, no tolerance, first differing word reported by index.
A short capture **fails** even if every word it did contain matched — that is the
whole point, and it is the case most scripts get wrong.

### `pynq_probe.overlay` — the board module (unverified)

`Board.open(...)` refuses to run unless an identity register matches, then gives
you `write_window` / `read_window` / `start_and_wait` with DONE-clear and
busy-drop handling.

**This module has not been executed on hardware in this form.** The three offline
modules are tested (50 checks); this one is written against the PYNQ 3.x API and
must be validated on a board before you trust a number that came out of it. Saying
that here is cheaper than a reviewer discovering it.

---

## 2 `golden_compare.py` — NPZ comparison

```sh
python golden_compare.py reference.npz candidate.npz --out comparison.json
```

Values, shapes, dtypes and key sets must match exactly by default. Missing or extra
arrays fail. Object arrays are rejected rather than unpickled. Floating point needs
an explicit `--atol`; relative tolerance is always zero, because a relative
tolerance lets a large value be wrong by more than a small one. No tolerance is
allowed for a claimed integer bit-exact check.

Origin: signed/unsigned hex mismatch, stale generated ROM files, missing output
tensors, stale synthesised IP checkpoints. Each of those would have been caught by
one of these cases, and each cost real time before it was.

---

## 3 What this package does not prove

Passing anything here does **not** prove timing closure, physical synchronisation,
model accuracy, electrical safety, or that the intended bitstream is loaded. The
register map check proves the *description* matches the handoff file. Only the
identity-register check at run time, and the bitstream md5, tie a number to a
design.
