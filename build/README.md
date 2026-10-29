# Build scripts

Vivado Tcl for the block design, implementation, bitstream and reports.

## Read this before running anything

These scripts were written against the **developer working tree**, where they
sit in `_pl/` alongside:

```
_pl/
├── build_bd_all.tcl                 <- these scripts
├── ip_repo_all/                     <- packaged IP (attn_axi, ts_top, eeg_fe_top, i2c_bb)
├── work2/rtl/, work2/tb/, work2/out/ <- canonical RTL, test benches, exported .mem
├── rtl/                             <- master copies of ts_top / eeg_fe_top / ...
└── constr/*.xdc
```

The submission repository is a **flat, English-named tree** (`src/rtl`,
`src/model`, `sim/`) and does not have those directories. The scripts detect
this and stop with a one-line message rather than failing forty lines later
inside Vivado. That guard is deliberate: a silent fallback to a stale IP copy is
the exact failure this project spent a week chasing (see the notes in
`build_bd_all_m4_impl.tcl` about REQP-1962).

## Assembling the working tree

`make_tree.ps1` does it in one command, from committed files only:

```powershell
powershell -File make_tree.ps1 -Mode m4      # or m2 / m3; default output G:\FPGA\_repro_<mode>

# 1. project + block design. BUILD_TREE_ONLY skips the A1 baseline build that this
#    script otherwise runs (a 200 MHz sign-off design that is not a shipped
#    bitstream) -- the m*_impl script resets and re-synthesises anyway.
$env:BUILD_TREE_ONLY = '1'
vivado -mode batch -source <Out>\build_bd_all.tcl
Remove-Item Env:BUILD_TREE_ONLY

# 2. synthesis, implementation, reports, routed checkpoint + .hwh
vivado -mode batch -source <Out>\build_bd_all_m4_impl.tcl

# 3. write the bitstream from the routed checkpoint (see the table below)
vivado -mode batch -source <Out>\write_bit_attn4.tcl
```

**Step 2 never writes a bitstream, and that is deliberate.** The block design
constrains `FCLK_CLK0` at 200 MHz; every mode misses that. Step 3 re-reads the
routed checkpoint, checks the sign-off period really is 5 ns, converts to the
board's 100 MHz operating point, *counts* the paths that would still fail there,
and refuses to write anything unless that set is empty and both structural gates
pass.

| Mode | step 1 | step 2 | step 3 | artefact |
|---|---|---|---|---|
| m2 | `build_bd_all.tcl` | `build_bd_all_m2_e4.tcl` → `attn2_e4_routed.dcp` | `write_bit_attn2.tcl` | `attn2_e4.bit` |
| m3 | `build_bd_all.tcl` | `build_bd_all_m3_impl.tcl` → `attn3_all_routed.dcp` | `write_bit_attn3.tcl` | `attn3_e4.bit` |
| m4 | `build_bd_all.tcl` | `build_bd_all_m4_impl.tcl` → `attn4_e4_routed.dcp` | `write_bit_attn4.tcl` | `attn4_e4.bit` |

(The M=3 checkpoint is named `attn3_all_routed.dcp` because the impl script
predates the `e4` naming; the design inside it does contain E4, and step 3's eps
gate is what proves that rather than the filename.)

All three modes were rebuilt this way on 2026-10-29. M=4 and M=2 reproduced the
shipped bitstreams byte for byte apart from the header date field (5 and 7 bytes
respectively; mask bytes 82–106 and the md5 matches). M=3 reproduced the
delivered design's reports exactly (7,135 LUT, −0.656 ns, +0.016 ns hold, 197
failing of 25,273 endpoints), which is why `reports/*_m3.rpt` are now that
rebuild's output rather than the older 2026-10-24 checkpoint's — but its
bitstream differs from the shipped one in 57 configuration bytes. Same design,
different route solution; the manifest's M=3 subsection lays out the evidence for
that reading and the provenance gap behind it. Details and the comparison recipe:
**Rebuild verification** in `../BITSTREAM_MANIFEST.md`.

It lays out `rtl/`, `work2/{rtl,out,tb}`, `constr/` and the Tcl, copies
`sim/vectors/<mode>` into `work2/out`, and rewrites exactly two lines in the
assembled copies (never in the repository):

| Line | Why |
|---|---|
| `` `define MEM_DIR `` in `attn_core.v` | the committed default `"../vectors"` is right for xsim launched from `sim/run/`, but Vivado synthesis resolves it against its own working directory, so a rebuild needs the absolute path of `work2/out` |
| `parameter integer UM` in `attn_axi.v` | Vivado does not override a Verilog parameter default from the block design — the default **is** the value in the bitstream. UM is the k/v row count `T*(M-1)`: 8 is enough for M=2 and M=3, M=4 needs 12 |

The IP package directories (`ip_repo_all/*`, with their `component.xml`,
`xgui/`) are Vivado artefacts and are not committed either — `build_bd_all.tcl`
creates them from `src/rtl` with `ipx::package_project` on every run, so they do
not have to be reconstructed by hand. That is also why the guard at the top of
`build_bd_all.tcl` checks `rtl/`, `work2/rtl`, `work2/out` and `constr/` rather
than `ip_repo_all/`, which that script deletes and recreates.

## Script inventory

| Script | Produces |
|---|---|
| `build_bd_all.tcl` | the base block design (`bd_all`) |
| `build_bd_all_m2_e4.tcl` | M=2 whole design → `attn2_e4_routed.dcp` (no bitstream) |
| `build_bd_all_m3_impl.tcl` | M=3 whole design → `attn3_all_routed.dcp` (no bitstream) |
| `build_bd_all_m4_impl.tcl` | M=4 whole design → `attn4_e4_routed.dcp` (no bitstream) |
| `build_ts_e4.tcl` / `impl_ts_e4.tcl` | standalone timestamp core → `ts_e4.bit` |
| `write_bit_attn{2,3,4}.tcl` | write the `.bit` from each mode's routed checkpoint after the 100 MHz check |
| `report_a1_util.tcl` | utilisation + worst setup/hold from a routed `.dcp` |
| `pullup_bit.tcl` | pull-up configuration pass |

## `UM` — the parameter that decides whether your bitstream is the right design

`src/rtl/attn_axi.v` carries `parameter integer UM = \`ATTNAXI_UM` and **Vivado
does not override a Verilog parameter default from the block design**. Rebuilding
M=4 without `ATTNAXI_UM=12` silently yields a different design. See
`../BITSTREAM_MANIFEST.md`.

## Toolchain

Vivado 2024.1. The competition guide recommends 2026.1 or 2025.2; nothing here
depends on 2024.1-specific behaviour that has been identified, but a rebuild on
a newer version has **not** been attempted, so treat that as untested.
