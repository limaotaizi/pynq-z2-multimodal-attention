# Third-party components and what is not redistributed here

This repository is MIT-licensed (see `LICENSE`), but it is not self-contained in
the sense of "no other software was involved". This file states what was used,
under what terms, and whether it is included here.

**Headline: no third-party source code is vendored in this repository.** There
is no copied RTL, no copied Python module, no bundled library and no AMD IP
source in `src/`, `sim/`, `board/`, `skill/` or `report/`. Everything below is
either a tool that produced the artefacts, or a runtime dependency that is
imported but not shipped.

## Build and runtime tools (not redistributed)

| Component | Version used | Role | Licence | In this repo? |
|---|---|---|---|---|
| AMD Vivado / Vitis | 2024.1 | Synthesis, implementation, bitstream generation, `xvlog`/`xelab`/`xsim`, `bootgen` | AMD/Xilinx end-user licence | **No.** Bitstreams, `.dcp`, `BOOT.BIN` and `.elf` are excluded by `.gitignore` and distributed separately; `BITSTREAM_MANIFEST.md` records their md5 |
| arm-none-eabi-gcc | 12.2.0 (via Vitis) | Cross-compiles the bare-metal application | GPL (toolchain) | No — compiler only, no runtime library is shipped |
| PYNQ / PYNQ-Z2 image | 3.x API | Board-side Python runtime for `skill/pynq_probe/overlay.py` only | BSD 3-Clause | No — imported on the board, never vendored. The module has **not** been run on hardware in this form (stated in `skill/README.md`) |

## Python packages

Pinned in `environment.txt`. Two different relationships, worth separating:

| Package | Version | Needed for | Licence | In this repo? |
|---|---|---|---|---|
| `numpy` | 2.5.2 | imported by the shipped model/vector code, `skill/golden_compare.py`, `report/md2tex.py` | BSD 3-Clause | No — dependency only |
| `scipy`, `scikit-learn`, `pandas`, `matplotlib`, `reportlab`, `torch` | see `environment.txt` | used in the **analysis tree** that produced the numbers and figures quoted in the report, not required to build, simulate or run this repository | BSD-style / PSF-style per package | No |

If you want to regenerate the golden vectors (`sim/run/regen_vectors.sh`) you
need the first row plus the quantised weights already committed. The second row
is needed only to reproduce the accuracy numbers, whose source scripts live in
the analysis tree distributed separately from this repository.

## Data

| Dataset | Role | Licence / terms | In this repo? |
|---|---|---|---|
| AFFEC (multimodal affect recordings) | Source of the raw physiological signals | Third-party research data; **not redistributable** under its terms | **No.** Only derived, fixed-point test vectors are committed, and those fall under this repository's MIT licence. See `DATA_LICENSE.md`; the calibration arrays (26–27 MB each) are deliberately absent |

## Generated artefacts that look like vendor files but are not

- `skill/tests/data/all_bd.hwh` — a Vivado handoff file. It is **generated from
  this project's own block design** and contains no AMD IP source, only XML
  describing the IP instances, address apertures and clocks. It is committed
  because the offline tests parse a real handoff; without it those cases are
  skipped, and they are the ones that demonstrate the `UM` trap documented in
  `BITSTREAM_MANIFEST.md`.
- Reports in `build/reports/` are Vivado's own text output for this design. They
  are data about the build, not vendor code.

## Tooling used to produce the documents

The design report and the model-collaboration record were written with the
assistance of an AI model, which the competition brief asks to be declared. That
record — including prompts, corrections and the cases where the model was wrong
— is in `report/ai_collab.md` / `.pdf`. This is disclosure of the authoring
process, not a code dependency: nothing in `src/`, `sim/` or `build/` is
generated at run time by a model.

## Licensing summary

- Code and derived vectors in this repository: **MIT** (`LICENSE`).
- Raw recordings: **not included** (`DATA_LICENSE.md`).
- Anything in the tables above: governed by its own licence, and not
  redistributed here, so its terms do not extend to this repository's contents.
