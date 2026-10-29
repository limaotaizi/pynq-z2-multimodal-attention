"""Build the two report PDFs from the Markdown sources.

    python report/make_pdf.py            # both PDFs
    python report/make_pdf.py design     # only design_report.pdf
    python report/make_pdf.py collab     # only ai_collab.pdf

The Markdown file is the source of truth: edit the .md, re-run this, never edit
the PDF. The path is md2tex.py (Markdown -> LaTeX) plus two xelatex passes (the
second one resolves the table of contents). That is the whole toolchain: no
pandoc, no network, no package downloads -- on this project's link a 40 MB
pandoc wheel did not finish downloading, and a converter whose only dependency
is the TeX distribution that has to be installed anyway is easier to reproduce.

Why two passes, and why the build is declared a failure on a non-empty stderr
match: a silently-dropped glyph or a table pushed past the margin is exactly the
kind of defect that survives a casual read of the PDF. The build prints the
error / missing-glyph / overfull counts and fails if any of the first two are
non-zero.
"""

from __future__ import annotations

import io
import os
import re
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
# `python -I report/make_pdf.py` drops the script directory from sys.path, and
# running from the repository root does the same for some launchers; md2tex.py
# sits next to this file, so put it back explicitly.
if HERE not in sys.path:
    sys.path.insert(0, HERE)

import md2tex  # noqa: E402  (needs the path entry above)

TARGETS = {
    "design": ("design_report.md", "design_report.pdf",
               "确定性多模态时间对齐与低延迟推理平台", "提交版设计报告 · 2026-10-29"),
    "collab": ("ai_collab.md", "ai_collab.pdf",
               "大模型协作记录", "提交版附属材料 · 2026-10-29"),
}


def build_one(md: str, pdf: str, title: str, subtitle: str) -> bool:
    src = os.path.join(HERE, md)
    dst = os.path.join(HERE, pdf)
    if not os.path.exists(src):
        print(f"missing {src}")
        return False
    tex = md2tex.build(src, title, subtitle)

    # A scratch directory keeps the .aux/.toc/.log out of the submission tree.
    with tempfile.TemporaryDirectory() as tmp:
        tex_path = os.path.join(tmp, os.path.splitext(md)[0] + ".tex")
        with io.open(tex_path, "w", encoding="utf-8", newline="\n") as f:
            f.write(tex)
        for attempt in (1, 2):
            r = subprocess.run(["xelatex", "-interaction=nonstopmode",
                                os.path.basename(tex_path)],
                               cwd=tmp, capture_output=True)
            log_path = os.path.join(tmp, os.path.splitext(md)[0] + ".log")
            if not os.path.exists(log_path):
                print(f"xelatex pass {attempt} produced no log:\n"
                      f"{r.stdout[-2000:].decode('utf-8', 'replace')}")
                return False
        log = io.open(log_path, encoding="utf-8", errors="replace").read()
        out_pdf = os.path.join(tmp, os.path.splitext(md)[0] + ".pdf")
        if not os.path.exists(out_pdf):
            print(f"xelatex produced no PDF for {md}")
            return False
        shutil.copyfile(out_pdf, dst)

    errors = len(re.findall(r"(?m)^! ", log))
    missing = log.count("Missing character")
    overfull = [l for l in log.splitlines() if "Overfull" in l]
    pages = re.search(r"Output written on .*?\((\d+) pages?\)", log)
    print(f"wrote {dst}")
    print(f"  pages={pages.group(1) if pages else '?'} errors={errors} "
          f"missing_glyphs={missing} overfull={len(overfull)}")
    for line in overfull:
        print(f"    {line}")
    return errors == 0 and missing == 0


def main(argv: list[str]) -> int:
    want = argv[1:] or list(TARGETS)
    unknown = [w for w in want if w not in TARGETS]
    if unknown:
        print(f"unknown target(s): {unknown}; choose from {list(TARGETS)}")
        return 2
    if shutil.which("xelatex") is None:
        print("xelatex not found. Install MiKTeX or TeX Live, or put it on PATH.")
        return 1
    ok = True
    for w in want:
        ok = build_one(*TARGETS[w]) and ok
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
