# Bitstream manifest

Every number in `report/` and `metrics/` refers to one of the bitstreams below.

**The md5 below cannot be reproduced by a rebuild, and that is not a failure.**
`write_bitstream` stamps the build date and time into the `.bit` header (bytes
82–106: a length-prefixed `2026/10/27 15:57:48`-style string). Two builds of the
same routed design differ in those bytes and in nothing else. Compare the header
with the date field zeroed:

```sh
python -c "import sys,hashlib; d=bytearray(open(sys.argv[1],'rb').read()); \
d[82:107]=bytes(24); print(hashlib.md5(d).hexdigest())" attn4_e4.bit
# attn4_e4.bit (2026-10-27 build and the 2026-10-29 clean rebuild) -> 7f2a3fea4a43bddd5d34587df9d9f7be
```

That masked hash **is** the identity: if it does not match, the configuration
data differs and it is not the design that produced the published numbers, even
if it simulates correctly. See *Rebuild verification* at the bottom for the
2026-10-29 run that established this.

| File | md5 | Size (bytes) | Mode `M` | `attn_axi.UM` | Notes |
|---|---|---:|---:|---:|---|
| `attn4_e4.bit` | `1e2555571c380d8fbaa2324141023e6f` | 4,045,674 | 4 (e+o+a+s) | **12** | The production design. 20.89 ms / window @100 MHz. |
| `attn3_e4.bit` | `a607316a7041fdb9798c139bff430a6c` | 4,045,674 | 3 (e+o+a) | 12 | 11.33 ms / window @100 MHz. |
| `attn2_e4.bit` | `d9fd5e4565f20f931e51df18aa89da48` | 4,045,674 | 2 (e+o) | **8** | 4.66 ms / window @100 MHz. |
| `ts_e4.bit` | `4fa3518fcb61ad5d91d8379001909806` | 4,045,673 | — | — | 48-bit 10 ns timestamp core, standalone. |
| `BOOT.BIN` | `93f8caee4a2e4b365622cfa0dee230d2` | 4,231,752 | 4 | 12 | FSBL + `attn4_e4.bit` + bare-metal `attn_m4.elf`. |

Bitstreams and `BOOT.BIN` are **not committed to the repository** (see `.gitignore`);
they are distributed with the submission archive. The md5 above is the check.

---

## `UM` is not a cosmetic parameter — read this before rebuilding

`src/rtl/attn_axi.v` carries the scratch-RAM depth as a Verilog parameter:

```verilog
`ifndef ATTNAXI_UM
  `define ATTNAXI_UM 8
`endif
    parameter integer UM = `ATTNAXI_UM,
```

**Vivado does not override a Verilog parameter default from the block design.**
The default *is* the value that ends up in the bitstream. If you rebuild the M=4
design with the default `8`, you get a different design that still passes
synthesis, still closes timing, and still boots — and silently computes the wrong
thing. This is exactly the class of failure the bit-exact test benches exist to catch,
so run them:

For simulation, define it in a header compiled first (this is the method that is
verified to work — `xvlog.bat -d NAME=VALUE` mangles the value on Windows):

```sh
printf '`define ATTNAXI_UM 12\n' > um12.vh
xvlog um12.vh memdir.vh src/rtl/attn_core.v src/rtl/attn_axi.v sim/tb/tb_attn_axi.v
```

For synthesis, do **not** try to pass `-d`/`-verilog_define` down into the block
design: `generate_target` synthesises the IP out-of-context before `synth_1` ever
sees the BD's properties, and `build_bd_all_m4_impl.tcl` reads the value back out
of the RTL source, not out of the project. The supported route is
`build/make_tree.ps1`, which rewrites the parameter default in the *assembled
copy* of `attn_axi.v` (never in the repository) according to `-Mode`:

```powershell
powershell -File build/make_tree.ps1 -Mode m4    # UM = 12
powershell -File build/make_tree.ps1 -Mode m3    # UM = 8
powershell -File build/make_tree.ps1 -Mode m2    # UM = 8
```

| Mode | `T*(M-1)` | `UM` written | Default already correct? |
|---|---:|---:|---|
| M=2 | 4 | 8 | yes |
| M=3 | 8 | 8 | yes |
| M=4 | 12 | 12 | **no — this is the one that bites** |

Repository history behind the two values:

- 2026-10-27 — `UM` raised to 12 for the M=4 build (`attn4_e4.bit`).
- 2026-10-28 — default returned to 8 for the M=2 rebuild (`attn2_e4.bit`).
- 2026-10-29 — turned into the `ATTNAXI_UM` macro so the two variants are
  switchable without editing a literal, and this manifest written because the
  tree had drifted from what was shipped.

**M=3, resolved (2026-10-29):** the build notes record `attn3_e4.bit` as `UM=12`,
but a clean rebuild from this repository with `UM=8` (`make_tree.ps1 -Mode m3`)
reproduces the delivered design's figures exactly — 7,135 LUT, WNS −0.656 ns,
WHS +0.016 ns, 197 failing of 25,273 endpoints. So `UM` is not what the delivered
M=3 bitstream depends on. Two further measurements settle it:

- **The bitstreams differ, but only by 57 configuration bytes** (see the M=3
  subsection below). A wrong `UM` is a *logical* difference — different ROM
  contents, different address arithmetic — and would move LUT counts and the
  failing-endpoint count too. It moved neither; it moved bits that look like
  routing. This is a different place-and-route solution of the same design.
- **All three shipped handoffs report no `UM` parameter at all.** Unpacking
  `attn2/3/4_e4.hwh` and grepping `all_bd.hwh` for it gives `ABSENT` in every
  case — including M=4, whose bitstream *does* rebuild byte-identically with
  `UM=12`. The packaged IP never exposed `UM` to the block design, so the source
  default decided in all three builds, exactly as the warning above says. The
  absence of `UM` from a delivered `.hwh` therefore says nothing about the
  delivered netlist, and must not be read as evidence either way.

M=3 resource and timing figures are no longer provisional and now come from that
rebuild (see `build/reports/README.md`). No correctness argument depends on the
M=3 `UM` value: `T*(M-1)` is 8 there, so 8 is exact and 12 is merely oversized —
both are sufficient, and only the second wastes ROM. M=4 is the mode where
under-sizing is a real fault.

---

## Resource utilisation (M=4 whole block design, `attn4_e4.bit`)

From `build/reports/util_m4.rpt` (routed, XC7Z020-1CLG400C):

| Resource | Used | Share |
|---|---:|---:|
| Slice LUT | 6,995 | 13.15 % |
| Slice register | 9,566 | 8.99 % |
| Block RAM tile | 44 (42×RAMB36 + 4×RAMB18) | 31.43 % |
| DSP48E1 | 20 | 9.09 % |

This is the whole-design figure, not the attention engine alone. The separate
figure **54.5 KB** that appears elsewhere is the *weight ROM* only, 8.65 % of a
different denominator — do not confuse it with the 44 block RAM tiles (~198 KB of
BRAM). Re-derive both with `build/report_a1_util.tcl` against a routed checkpoint.

## Timing — which frequency the numbers belong to

The block design constrains `FCLK_CLK0` at 200 MHz, so Vivado's default report is
a 200 MHz report and it **fails**:

| Mode | WNS @200 MHz | Failing setup endpoints | WNS @100 MHz (operating point) |
|---|---:|---:|---:|
| M=2 `attn2_e4.bit` | −0.919 ns | 843 / 25,249 | +4.081 ns |
| M=3 `attn3_e4.bit` | −0.656 ns | 197 / 25,273 | +4.344 ns |
| M=4 `attn4_e4.bit` | −0.736 ns | 274 / 25,366 | +4.264 ns |

On the board the application sets `DIVISOR0 = 10`, so the delivered designs run at
**100 MHz** and have 4.1–4.3 ns of setup margin with zero hold failures. Every
latency number in `metrics/` assumes 100 MHz. See `build/reports/README.md`.

---

## Rebuild verification — all three modes, 2026-10-29

A clean rebuild was run from the repository alone, on a machine that had no
developer tree: `make_tree.ps1 -Mode m4` → `build_bd_all.tcl` with
`BUILD_TREE_ONLY=1` → `build_bd_all_m4_impl.tcl` → `write_bit_attn4.tcl`
(Vivado 2024.1, 13 min 12 s for synthesis + implementation, 51 s for bitgen).

| Artefact | Result vs the shipped build |
|---|---|
| `attn4_e4.bit` | 4,045,674 B, **5 differing bytes**, all inside the header date field (82–106). Masked md5 `7f2a3fea…` on both sides ⇒ configuration data identical |
| `util_m4.rpt` | identical except the `Date` and `Command` lines |
| `timing_m4.rpt` | identical except the `Date` and `Command` lines |
| `worst_m4.rpt` | identical except the `Date` and `Command` lines |
| `hwdef.xml` inside `attn4_e4.hwh` | identical |

Gates the run passed, in order: `exp_note` says `mode=m4 mods=e,o,a,s`; ipshared
`attn_axi.v` is `UM=12` after `generate_target`; ipshared `ts_top.v` has
`eps_r` ×11; crossbar decode M00/M01/M02 = `0x4000_0000`/`0x4001_0000`/`0x4002_0000`
with widths 16/12/12; `pc_reg` = 30 and `ir_reg` = 282 after synthesis; weight ROM
= 32 × RAMB36 = 131,072 entries; `pc_reg` still 30 post-route.

Reproduced timing exactly: WNS −0.736 ns, WHS +0.037 ns, 274 failing setup
endpoints of 25,366 at the 200 MHz constraint, +4.264 ns at the board's 100 MHz.

The 200 MHz run ends with `timing not met, no bitstream` — that gate is deliberate.
`write_bit_attn4.tcl` is what writes the shipped bitstream, after checking that the
sign-off period is really 5 ns and converting. **Each mode needs three commands, not two.**

### M=2 — same day, same procedure, bit-exact

`make_tree.ps1 -Mode m2` → `build_bd_all.tcl` → `build_bd_all_m2_e4.tcl` →
`write_bit_attn2.tcl`.

| Artefact | Result vs the shipped build |
|---|---|
| `attn2_e4.bit` | 4,045,674 B, **7 differing bytes**, all inside the header date field (82–106, offsets 91/96/97/99/100/102/103). Masked md5 `4cb32e0c…` on both sides ⇒ configuration data identical |
| `util_m2_e4.rpt` | 6,649 LUT / 9,537 FF / 44 BRAM tiles (42+4) / 20 DSP — identical to `metrics/resource.csv` |
| timing | WNS −0.919 ns, WHS +0.040 ns, 843 failing of 25,249 at 200 MHz; 0 failing at the derived 100 MHz point (WNS +4.081 ns) |

Post-synthesis gates: `pc_reg` = 15, `ir_reg` = 185, weight ROM 32 banks; post-route
`ts_0` eps cells = 196, `tau_r` = 228, and the bitstream writer re-counted 32 weight
banks before writing.

### M=3 — reports reproduced, bitstream not bit-identical

`make_tree.ps1 -Mode m3` → `build_bd_all.tcl` → `build_bd_all_m3_impl.tcl` →
`write_bit_attn3.tcl` (13 min 15 s).

Reproduced the delivered design rather than an older checkpoint: **7,135 LUT,
WNS −0.656 ns, WHS +0.016 ns, 197 failing of 25,273** — every figure the master
number table attributes to the 2026-10-26 `attn3_e4.bit`. The three `.rpt` files
shipped in `build/reports/` are now this rebuild's output; the previous ones were
the 2026-10-24 checkpoint (7,071 LUT, −0.639 ns, 239 endpoints) and described a
design that was never shipped. Gates: `pc_reg` = 35, `ir_reg` = 273, 32 weight
banks after synthesis; `ts_0` eps cells present post-route.

**The bitstream is not byte-identical, and this is recorded here rather than
smoothed over.** Same size (4,045,674 B), but 63 bytes differ: 6 in the header
date field (offsets 91, 97, 99, 100, 102, 103) and **57 in configuration data**,
in three clusters around 1,399,196–1,406,144, 1,491,152–1,492,924 and
4,043,582–4,043,585. Masked md5: rebuild `e454a7d9…`, shipped `5a7f95c8…`.

Why this is a place-and-route difference and not a different design:

- Every quantity that would move if the logic changed — LUT, FF, BRAM, DSP, WNS,
  WHS, failing-endpoint count — is identical to the delivered figure.
- Unpacking both `attn3_e4.hwh` archives gives **identical** `hwdef.xml`,
  `all_bd.bda` and every `ps7_init.*`; only `all_bd.hwh` differs, and its only
  content differences are a `TIMESTAMP` attribute and a
  `<PARAMETER NAME="UM" VALUE="8"/>` entry that the rebuild's packaging emits and
  the delivered one does not.
- That `UM` entry is **not** an explanation: the delivered M=2 and M=4 handoffs
  also lack it, and both of those bitstreams *do* reproduce byte-for-byte with
  the parameter present. Parameter exposure changes the packaging metadata, not
  the configuration data.

What is known about provenance: the shipped `attn3_e4.bit` came from a script
called `build_bd_all_e4_impl.tcl`, which is not in this repository; the rebuild
used `build_bd_all_m3_impl.tcl`. The delivered M=2 and M=4 builds, by contrast,
reproduce exactly from the scripts that *are* here. Two implementation scripts
targeting the same design can legitimately settle on different legal route
solutions; that is the most economical explanation, and it is offered as the
explanation, not as proof of one.
