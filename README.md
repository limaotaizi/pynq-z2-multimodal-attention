# Deterministic multimodal time-alignment and low-latency inference on a PYNQ-Z2

A fixed-point attention engine and timestamp front-end for four-modality
physiological signals (EEG, eye tracking, facial action units, GSR), running on
the programmable logic of a PYNQ-Z2 (XC7Z020). The engine is **bit-exact against
its Python reference model**, the whole inference path is characterised down to
the cycle, and the timestamp path quantises to 10 ns.

This repository is the submission package for the 2026 embedded chip and system
design competition, FPGA innovation track (self-selected topic).

Where to start: the design report is **`report/design_report.pdf`** (17 pages);
how the model was used, and where it was wrong, is **`report/ai_collab.pdf`**
(5 pages). Both are generated from the `.md` next to them by
`python report/make_pdf.py` — no pandoc, no network.

---

## What this repository claims, and what it does not

Being explicit about this up front is deliberate — several limitations below are
things a quick demonstration would happily hide.

### Established, reproducible from this repository

| Claim | Evidence |
|---|---|
| The PL engine is **bit-exact** against `src/model/fixpt.py` | `sim/run/run_attn_m{2,3,4}.sh` → 14 / 21 / 28 arrays, 3,200 / 4,224 / 5,504 words, all `PASS` |
| Engine latency at 100 MHz, measured in cycles | M=2 466,157 cyc (4.662 ms) · M=3 1,124,691 cyc (11.247 ms) · M=4 2,079,001 cyc (20.790 ms) |
| One window end-to-end on the board, no host in the loop | 21.650 ms median, bare-metal `BOOT.BIN`, reached two independent ways (JTAG reload and SD cold boot) |
| Agreement between the float model, the INT8/INT16 software arithmetic and the hardware | 99.61 % |
| Resource cost of the M=4 whole block design | 6,995 LUT · 9,566 FF · 44 BRAM tiles (31.4 %) · 20 DSP48E1 — `metrics/resource.csv`, `build/reports/util_m4.rpt` |
| Timing closure at the 100 MHz operating point | worst setup slack **+4.264 ns**, worst hold +0.037 ns, 0 failing endpoints |
| Adding the AU modality helps | +2.28 pp macro-F1, 3 seeds, 3/3 exclude zero; subject bootstrap [+1.47, +3.12] |

### Not established — do not read these into the results

| Not claimed | Why |
|---|---|
| Real-time **emotion recognition** | 3-class chance is 33.3 %; this design reports 0.34–0.40. It emits a prediction in real time; the prediction is near chance on held-out subjects. |
| The four sensors are synchronised | No external reference was ever connected. On the board the timestamp core runs from an **internal strobe** (`SRC=0xF`). What is proven is 10 ns quantisation and that the alignment framework and calibration interface exist. |
| Online calibration helps | 2-trial recalibration: +0.77 pp (RF) and +0.83 pp (R2G), both bootstrap CIs include zero. |
| Time-delta injection improves accuracy | Ablating ψ(Δt, ε) changes macro-F1 by −0.05 pp. The mechanism is real, traceable and nearly free; on AFFEC it buys nothing. |
| Timing closure at 200 MHz | The block design constrains 200 MHz and the routed M=4 design **misses by 0.736 ns** (274 of 25,366 endpoints). The delivered bitstreams all run at 100 MHz and are signed off there. See `build/reports/README.md` — do not quote the 200 MHz slack as a result. |
| Power | No meter and no PMBus on this board. **Not measured.** Do not infer it from resource counts. |
| That the PL is faster than the CPU | The same-board CPU baseline says the opposite: a scalar C interpreter on the A9 finishes the same instruction stream, bit-exact, in **7.470 ms** against the PL's **20.790 ms** — the A9 is **2.78× faster**. The PL uses 2.33× fewer cycles but runs at a 6.5× lower clock. See `board/baseline/README.md` and report §5.4. |
| That `skill/pynq_probe/overlay.py` works | Its three offline modules are tested (50 checks); the board module has **never been run on hardware** in this form. It is written against the PYNQ 3.x API. Validate it before trusting a number that came out of it. |

The `npz` results behind these tables are produced by scripts in the project's
analysis tree, which is distributed separately from this repository; the design
report cites each file.

---

## Layout

```
src/rtl/       Verilog: attention engine, AXI wrapper, timestamp core, EEG front-end
src/model/     Python reference model (fixpt.py) and the vector exporter
sim/tb/        Test benches, one per mode
sim/run/       One-command runners: export vectors -> xvlog -> xelab -> xsim
sim/vectors/   The golden vectors themselves (committed, so sim is self-contained)
build/         Vivado Tcl: block design, implementation, bitstream
build/reports/ Raw utilisation and timing reports (the source of metrics/resource.csv, timing.csv)
board/         Bare-metal application, BOOT.BIN build, PYNQ drivers
skill/         Reusable skill package: pynq_probe (handoff / register-map / capture checks)
               plus golden_compare.py, with 50 offline tests (sh skill/tests/run_tests.sh)
report/        Design report (PDF + Markdown source) and the model-collaboration
               record; make_pdf.py builds both with xelatex
metrics/       Machine-readable metrics tables (latency, resource, timing, accuracy, cpu_baseline)
BITSTREAM_MANIFEST.md   Which bitstream produced which number, and why UM matters
evidence_manifest.json  Every claim in metrics.csv -> the file that backs it -> its md5
checklist.md            Submission requirements, item by item, including what is NOT done
```

---

## Quick start

### Simulation (no board, no model assets, no network)

```sh
cd sim/run
./run_attn_m4.sh          # or run_one.sh m2 | m3 | m4
```

This compiles `src/rtl/attn_core.v` and the mode's test bench, runs them against
the **committed** golden vectors in `sim/vectors/<mode>/`, and greps for the
verdict. Expect:

```
  engine cycles = 2079001
  ...
  Z_S0: 64 words OK
ALL PASS
```

The script resolves the toolchain through `XILINX_VIVADO` and falls back to a
local install. The `MEM_DIR` macro picks the vector directory; the test benches
default it to `../vectors/<mode>` and the runner overrides it through a generated
`memdir.vh`. Run from `sim/run/` and everything resolves.

### Regenerating the vectors (optional, needs the model)

```sh
AFFEC_CACHE=/path/to/cache ./regen_vectors.sh m4
```

Regeneration is **deterministic** — it reproduces the committed vectors byte for
byte. It needs the quantised weights (committed, ~1 MB) and the calibration
arrays (**not** committed, 26–27 MB each — see `DATA_LICENSE.md`). If you
regenerate and the vectors change, that is an arithmetic-contract change, not a
formatting detail; look at the diff.

### Build

The Tcl was written against the developer working tree, so first lay that tree
out from the committed files — it also rewrites the one parameter that decides
whether the bitstream is the right design:

```powershell
powershell -File build/make_tree.ps1 -Mode m4      # UM=12 for M=4; m3 / m2 take 8
$env:BUILD_TREE_ONLY = '1'
vivado -mode batch -source ..\_repro_m4\build_bd_all.tcl   # project + block design
Remove-Item Env:BUILD_TREE_ONLY
vivado -mode batch -source ..\_repro_m4\build_bd_all_m4_impl.tcl   # synth + impl
vivado -mode batch -source ..\_repro_m4\write_bit_attn4.tcl        # -> attn4_e4.bit
```

The same three steps produce M=2 (`build_bd_all_m2_e4.tcl` +
`write_bit_attn2.tcl`) and M=3 (`build_bd_all_m3_impl.tcl` +
`write_bit_attn3.tcl`); `build/README.md` has the mode table. Step 2 never writes
a bitstream — the block design constrains 200 MHz and every mode misses it, so
step 3 re-reads the routed checkpoint, checks the 100 MHz operating point
properly, and refuses if anything still fails there.

All three modes were rebuilt this way on 2026-10-29 from the repository alone.
`attn4_e4.bit` and `attn2_e4.bit` are byte-for-byte identical to the shipped
bitstreams apart from the build timestamp in the `.bit` header (mask it and the
md5 matches); M=3 reproduces the delivered design's reports exactly, but its
bitstream differs in 57 configuration bytes — the same design routed differently,
which the manifest argues for rather than assumes. Read `BITSTREAM_MANIFEST.md`
for the comparison recipe, the evidence, and why the md5 can never match on a
rebuild without masking.

### Board

```powershell
# find the port (Bluetooth virtual ports are filtered out)
powershell -ExecutionPolicy Bypass -File board/baremetal/bm_ports.ps1
$env:BM_PORT = 'COM7'          # whatever bm_ports.ps1 reported

powershell -ExecutionPolicy Bypass -File board/baremetal/build_elf.ps1
powershell -ExecutionPolicy Bypass -File board/baremetal/build_bootbin.ps1
```

Copy `BOOT.BIN` to the FAT32 boot partition of the SD card, set the boot jumper
to SD, power cycle. The bare-metal application prints one line per check.

---

## Environment

`environment.txt` pins the host, the Python packages and the vendor tools used
to produce the committed vectors. The competition guide recommends Vivado/Vitis
2026.1 or 2025.2; this project used **2024.1**. Every script resolves the
install through `XILINX_VIVADO` / `XILINX_VITIS` rather than a hardcoded path, so
a newer toolchain works without editing the repository.

---

## License and data

Code and derived fixed-point vectors: MIT, see `LICENSE`.
Raw AFFEC recordings are **not** redistributed here — see `DATA_LICENSE.md`.
