# Design report

| File | Content |
|---|---|
| `design_report.md` | Seven sections per competition guide 3.3.5.3, with a dedicated failure-analysis section (§7) |
| `design_report.pdf` | The same, typeset — 17 pages |
| `ai_collab.md` | How the model was used, what it got wrong, and the reusable rules that came out of it |
| `ai_collab.pdf` | The same, typeset — 5 pages |
| `md2tex.py` | The converter that produces the `.tex` from the two Markdown sources |

Status: both written and both typeset. The Markdown is the source of truth; the
PDFs are generated from it by `md2tex.py` + two passes of `xelatex`, so an edit
to the Markdown is one command away from the PDF. No pandoc, no network.

```sh
python report/md2tex.py report/design_report.md -o build/design_report.tex \
    --title "确定性多模态时间对齐与低延迟推理平台" --subtitle "提交版设计报告 · 2026-10-29"
cd build && xelatex design_report.tex && xelatex design_report.tex
```

Build hygiene for these PDFs: zero LaTeX errors, zero missing glyphs, and at
most a sub-point overfull box. The converter is what makes that checkable —
it reports any Markdown construct it does not support instead of dropping it,
and it warns when a box diagram's frame lines disagree on width.

Numbers cited in the report come from `metrics/` or `sim/`. Anything that cannot
be reproduced from this repository is marked as such: either in the main README's
"not established" table or, for the two figures that are secondary citations,
in the `status` column of `metrics/cpu_baseline.csv`.

## Self-check on the report

Before the report is considered done, these should hold:

- [x] Every table has a source line underneath or a column naming the file.
- [x] The 200 MHz timing failure is stated, not omitted, and the 100 MHz
      operating point is given with its own number.
- [x] The three M=4 latency figures (20.790 / 20.89 / 21.650) are all present
      and each is labelled with its scope.
- [x] The two C confidence intervals (+2.28 fold mean vs +2.451 pooled OOF) are
      labelled as different estimators.
- [x] "Not measured" appears for power and the CPU baseline, in the report body,
      not only in a limitations appendix.
- [x] No school name, advisor name, or personal information.
- [x] PDF generated and page-checked: 15 + 5 pages, 0 errors, 0 missing glyphs,
      one 0.7 pt overfull box in a table cell.
- [x] Chinese body text, English file and directory names throughout.
