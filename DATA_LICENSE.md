# Data licensing and what is *not* in this repository

Two different things are called "data" here, and they have different answers.

## 1. Derived fixed-point vectors — committed, MIT

`sim/vectors/m2/`, `sim/vectors/m3/`, `sim/vectors/m4/` (~1 MB total) are the
integer weight, instruction and expected-activation arrays for the three engine
configurations. They are the output of `src/model/export.py` and they carry no
identifiable information about any participant. They are covered by `LICENSE`.

## 2. Raw AFFEC recordings — not redistributed

The model was trained and evaluated on **AFFEC**, a multimodal emotion dataset
(EEG / eye tracking / facial action units / GSR, 64 subjects, 5,049 trials).
The recordings are not ours to redistribute. Nothing in this repository contains
raw signals, per-subject features, or per-trial predictions that could be traced
back to a participant.

To reproduce the *modelling* results you need the dataset from its own
distributors, under their terms.

## 3. Calibration arrays — not committed, needed only to re-export

`src/model/export.py` needs one calibration file per mode:

| Mode | File | Size |
|---|---|---:|
| M=2 | `scenario-end_T4_w4_eegeye.npz` | 27.3 MB |
| M=3 | `scenario-end_T4_w4_aueegeye_sub64.npz` | 26.7 MB |
| M=4 | `scenario-end_T4_w4_all4_sub64.npz` | 27.4 MB |

These are derived feature arrays, still traceable to AFFEC participants, so they
are excluded from git. Point `AFFEC_CACHE` at a directory containing them to
regenerate vectors. **You do not need them to run the test benches** — the
committed vectors are the contract.

## 4. Weights — committed

`src/model/assets/w_attn{,3,4}_p_emotion_v_f0.npz` (~1 MB total) are quantisation
metadata plus the trained parameters for one fold. Committed under `LICENSE`;
they are model parameters, not recordings.

## 5. Bitstreams

`attn{2,3,4}_e4.bit` and `BOOT.BIN` are distributed with the submission archive,
not in git. `BITSTREAM_MANIFEST.md` records their md5 — use that, not the
filename, to identify a build.
