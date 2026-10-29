# Metrics

One row per claim, with the artefact that backs it. A number goes in a table only
with the file that produced it; no number is transcribed from a slide, and a blank
cell means *not measured*, not *zero*.

| File | Content | Backed by |
|---|---|---|
| `metrics.csv` | the headline claims in one place: latency, resource, timing, verification, accuracy, baselines, non-measurements | rows point at the files below |
| `latency.csv` | cycles and milliseconds per mode, board readings, end-to-end breakdown | `sim/run/*.log`, board logs |
| `resource.csv` | LUT / FF / BRAM / DSP for M=2, M=3, M=4 | `build/reports/util_*.rpt` |
| `timing.csv` | 200 MHz constraint result and the 100 MHz signoff point, per bitstream | `build/reports/timing_*.rpt` |
| `accuracy.csv` | macro-F1 per arm / target / protocol, with CIs and the estimand | the result JSONs named in each row |
| `cpu_baseline.csv` | same-board CPU vs PL | `board/baseline/` — A9 executes the same instruction stream, bit-exact; the **A9 is 2.78× faster** than the PL (7.470 vs 20.790 ms). Adverse to the PL; see `board/baseline/README.md` |
| `make_evidence_manifest.py` | regenerates `../evidence_manifest.json`: one entry per row of `metrics.csv`, with the size and md5 of every file it cites | `metrics.csv` + `git ls-files`; run with `--check` to fail on any claim whose evidence does not ship |

## Protocol names used in `accuracy.csv`

These are not interchangeable. Two rows with different `protocol` values are two
different experiments, even when they quote the same model.

| `protocol` | What it means |
|---|---|
| `80fold_seed0_pooled_oof` | 80 cross-validation folds (4 targets × 20), seed 0, pooled out-of-fold predictions. The main table. |
| `80fold_seed1…2_pooled_oof` | Same folds, different seed. Used only to check that an effect is not a seed artefact. Seeds share folds, so their intervals must not be pooled. |
| `subject_bootstrap_64` | 20,000 paired resamples of the 64 held-out subjects over pooled OOF. **Different estimand** from the fold mean: C is +2.28 pt as a fold mean and +2.451 pt as pooled OOF. Both are reported; neither replaces the other. |
| `deployed_m4_single_fold` | One fold, one target (p_emotion_v), 1,016 test trials, using the exact fixed-point arithmetic the PL implements. This is the row that connects the hardware to an accuracy number. |
| `stimulus_disjoint` | Train and test share no stimulus identity, but do share participants. Used only to bound how much a stimulus-identity baseline could explain. **Not a paired causal estimate** against the subject-disjoint protocol. |
| `rf_*` / `r2g_*` | Two different reference implementations (random forest; the R2G network) under the same online-calibration protocol. Diagnostic, not new results. |

## Known-number caveats

1. **C's confidence interval has two versions.** `[+0.55, +3.74]` is a fold-cluster
   bootstrap (20,000 resamples); `[+1.19, +3.37]` is a 20-fold paired t. The point
   estimate is +2.28 either way. Say which one you are quoting.
2. **M=4 latency has three numbers and they are all correct**: 20.790 ms from
   simulation cycles (the engine alone), 20.89 ms from the board with a Python host
   in the loop, 21.650 ms for the whole bare-metal window including load, readback
   and the PS head. They differ by host polling granularity and by scope, not by a
   measurement error.
3. **The classification head timing is a secondary citation.** 0.242 ms pure CPU /
   0.167 ms PL / 1.004 ms with transfer comes from a design note that is not in this
   repository. It is included because it is the only same-board CPU measurement the
   project has, and labelled `secondary_citation` for that reason.
4. **`input_saturation_count` is zero on all four modalities** at the deployed
   scales, over 1.26 M / 98 K / 207 K / 98 K elements. That is the evidence that the
   INT8 input quantisation is not clipping, and it is the one quantisation risk that
   was checked.
