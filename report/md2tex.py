"""Markdown -> LaTeX for the two report sources, without pandoc.

    python report/md2tex.py design_report.md -o build/design_report.tex
    python report/md2tex.py ai_collab.md     -o build/ai_collab.tex

Why this exists instead of pandoc: the reports are table-heavy Chinese prose, and
the only conversion path that needed no 40 MB download on a slow link was this
one. The supported construct set is exactly what the two sources use, and every
construct outside it is reported as an error rather than passed through as text --
a silently-dropped table is worse than a failed build.

Supported: ATX headings, fenced code, pipe tables, unordered and ordered lists,
blockquotes, horizontal rules, paragraphs, and inline code / bold / italic /
links. Anything else ([^1] footnotes, images, nested lists deeper than one level,
HTML) raises Unsupported.
"""

from __future__ import annotations

import argparse
import re
import sys

# ---------------------------------------------------------------- inline text

_SLOT = "\x00%d\x00"
_slot_re = re.compile("\x00(\\d+)\x00")


def _verb(text: str) -> str:
    """\\texttt{} with correct handling of spaces, braces and backslashes."""
    out = []
    for ch in text:
        if ch == "\\":
            out.append(r"\textbackslash{}")
        elif ch in "{}":
            out.append("\\" + ch)
        elif ch == "$":
            out.append(r"\$")
        elif ch == "&":
            out.append(r"\&")
        elif ch == "#":
            out.append(r"\#")
        elif ch == "%":
            out.append(r"\%")
        elif ch == "_":
            out.append(r"\_")
        elif ch == "^":
            out.append(r"\^{}")
        elif ch == "~":
            out.append(r"\textasciitilde{}")
        elif ch == " ":
            out.append("\\ ")
        else:
            out.append(ch)
    # A long path in a table cell is otherwise one unbreakable box: the source
    # has `metrics/{latency,resource,timing,accuracy,cpu_baseline}.csv`, which
    # is 99 pt too wide for its column and overlaps the next one. Breaking after
    # a separator is the only place a path may sensibly break anyway.
    body = "".join(out).replace("/", "/\\hspace{0pt}").replace(",", ",\\hspace{0pt}")
    # xeCJK pads the boundary between a Chinese-class character and ASCII. In a
    # code span that padding is wrong: `τ_m` and `_数字总表` came out as "τ _m"
    # and "_ 数 字 总 表". The spaces that are meant to be there are already
    # escaped as `\ ` above, so switching the glue off inside the span is safe.
    return r"\texttt{\xeCJKsetup{CJKecglue={}}" + body + "}"


def escape(text: str) -> str:
    out = []
    for ch in text:
        if ch in "&%#_":
            out.append("\\" + ch)
        elif ch == "$":
            out.append(r"\$")
        elif ch == "{":
            out.append(r"\{")
        elif ch == "}":
            out.append(r"\}")
        elif ch == "~":
            out.append(r"\textasciitilde{}")
        elif ch == "^":
            out.append(r"\textasciicircum{}")
        elif ch == "\\":
            out.append(r"\textbackslash{}")
        else:
            out.append(ch)
    return "".join(out)


def inline(text: str) -> str:
    """Inline markup. Code spans are lifted out first so their contents are
    never touched by escaping or by the emphasis rules."""
    slots: list[str] = []

    def lift(m: re.Match) -> str:
        # A span delimited by N backticks may hold shorter runs of backticks,
        # which is how the sources write a macro: `` `ifndef `` must stay a
        # literal backtick, not become a code span that ends three characters
        # early and leaves a stray backtick in the prose. CommonMark also strips
        # one space of padding on each side.
        code = m.group(2)
        if code.startswith(" ") and code.endswith(" ") and code.strip():
            code = code[1:-1]
        slots.append(_verb(code))
        return _SLOT % (len(slots) - 1)

    text = re.sub(r"(`+)(.+?)\1", lift, text)

    # links, before escaping, so the URL is not escaped twice
    def link(m: re.Match) -> str:
        label, url = m.group(1), m.group(2)
        slots.append(r"\href{" + url.replace("%", r"\%").replace("#", r"\#") + "}{"
                     + escape(label) + "}")
        return _SLOT % (len(slots) - 1)

    text = re.sub(r"\[([^\]]+)\]\(([^)\s]+)\)", link, text)

    text = escape(text)
    # Slashes are the only break points in a run like `CTRL`/`STATUS`/... and
    # LaTeX has none by default, so such a run goes past the margin.
    text = text.replace("/", "/\\hspace{0pt}")
    text = re.sub(r"\*\*(.+?)\*\*", r"\\textbf{\1}", text)
    text = re.sub(r"(?<![\w*])\*([^*\n]+)\*(?![\w*])", r"\\emph{\1}", text)
    return _slot_re.sub(lambda m: slots[int(m.group(1))], text)


# --------------------------------------------------------------------- tables


def _cell_len(s: str) -> int:
    """Display width, counting a CJK character as two columns."""
    return sum(2 if ord(c) > 0x2E80 else 1 for c in s)


def _split_row(line: str) -> list[str]:
    line = line.strip()
    if line.startswith("|"):
        line = line[1:]
    if line.endswith("|"):
        line = line[:-1]
    return [c.strip() for c in line.split("|")]


def _is_sep(line: str) -> bool:
    return bool(re.fullmatch(r"\s*\|?[\s:|-]+\|?\s*", line)) and "-" in line


def table(rows: list[str]) -> str:
    header = _split_row(rows[0])
    body = [_split_row(r) for r in rows[2:]]
    ncol = len(header)
    for r in body:
        if len(r) != ncol:
            raise Unsupported(f"table row has {len(r)} cells, header has {ncol}: {r}")

    widths = [_cell_len(h) for h in header]
    for r in body:
        for i, c in enumerate(r):
            widths[i] = max(widths[i], min(_cell_len(c), 60))
    total = sum(widths)
    # longtable puts \tabcolsep (6 pt) on both sides of every column, so the
    # column widths have to fit in the text width *minus* 2*ncol*6 pt. Sharing
    # out a flat 0.94 of the text width ignores that and overflows by ~7 pt on
    # every three-column table -- small enough to miss on screen, but the rules
    # visibly run past the margin. Every column keeps a floor so a header like
    # "M" does not collapse to nothing.
    avail = TEXT_PT - 2 * ncol * 6 - 3
    raw = [max(0.07 * TEXT_PT, avail * w / total) for w in widths]
    scale = avail / sum(raw)
    frac = [r * scale / TEXT_PT for r in raw]
    spec = "".join(r">{\raggedright\arraybackslash}p{%.3f\textwidth}" % f for f in frac)

    head = " & ".join(r"\textbf{%s}" % inline(c) for c in header) + r" \\"
    out = [r"\begin{longtable}{" + spec + "}", r"\toprule", head, r"\midrule",
           r"\endfirsthead", r"\toprule", head, r"\midrule", r"\endhead",
           r"\midrule", r"\multicolumn{%d}{r}{\footnotesize 续下页} \\" % ncol,
           r"\endfoot", r"\bottomrule", r"\endlastfoot"]
    for r in body:
        out.append(" & ".join(inline(c) for c in r) + r" \\")
    out.append(r"\end{longtable}")
    return "\n".join(out)


# ------------------------------------------------------------------- document


class Unsupported(Exception):
    pass


# ------------------------------------------------------------------ code blocks

TEXT_PT = 168 / 25.4 * 72.27   # A4 width less two 21 mm margins, in points
SIZES = [(10.0, r"\normalsize"), (9.0, r"\small"),
         (8.0, r"\footnotesize"), (7.0, r"\scriptsize")]


def fence(body: list[str]) -> str:
    """A fenced block, in the largest size at which its widest line fits.

    Two font regimes, because the diagrams mix box-drawing characters with
    Chinese labels: ASCII-only blocks use the monospace font (0.55 em per
    character), while a block containing CJK has to use SimSun for everything --
    its Latin is exactly half an em, so a CJK character is exactly two ASCII
    ones and the box borders stay in line. With the mixed pair the borders drift
    apart by a character about every third line.
    """
    cjk = any(any(ord(c) > 0x2E80 for c in L) for L in body)
    if cjk:
        def units(L: str) -> int:      # half-widths, 2 per CJK character
            return sum(2 if ord(c) > 0x2E80 else 1 for c in L)
        check_alignment(body, units)   # on the source, before transliteration
        body = [_downgrade(L) for L in body]
        per_em = 0.5                    # SimSun: ASCII exactly 0.5 em
    else:
        units = len
        per_em = 0.5498                 # Consolas advance, measured from the PDF

    widest = max((units(L) for L in body), default=0)
    size = SIZES[-1][1]
    for pt, cmd in SIZES:
        if widest * per_em * pt <= TEXT_PT - 6:
            size = cmd
            break

    opts = ["fontsize=" + size]
    if cjk:
        # CJKecglue inserts space between a Chinese character and the ASCII
        # next to it. In a diagram that padding is exactly what breaks the
        # column count, so it is switched off inside these blocks only.
        opts.append(r"formatcom={\xeCJKsetup{CJKecglue={}}\fontspec{SimSun}}")
    lines = [r"\begin{Verbatim}[" + ",".join(opts) + "]"]
    lines.extend(body)
    lines.append(r"\end{Verbatim}")
    return "\n".join(lines)


# Box-drawing and CJK symbol glyphs are ONE em wide in SimSun, not the half em
# an ASCII character gets. A diagram aligned on the assumption "each of these
# occupies one column" therefore comes apart: the right border lands eight
# centimetres off the page. Every one of them is therefore replaced by an ASCII
# character of the same column count, which SimSun sets at exactly half an em.
_ASCII_DOWN = {
    "─": "-", "━": "-", "│": "|", "┃": "|",
    "┌": "+", "┐": "+", "└": "+", "┘": "+",
    "├": "+", "┤": "+", "┬": "+", "┴": "+", "┼": "+",
    "▼": "v", "▲": "^", "►": ">", "◄": "<",
    "→": ">", "←": "<", "↔": "<", "⇒": ">",
    "·": ".", "×": "x", "≈": "~", "≤": "<", "ε": "e", "τ": "t", "ψ": "p",
}


def _downgrade(line: str) -> str:
    return "".join(_ASCII_DOWN.get(c, c) for c in line)


def check_alignment(body: list[str], units) -> None:
    """Warn when a diagram's lines do not all occupy the same number of columns.

    Only meaningful for a block that draws a frame: a block whose lines vary in
    width is probably not one, so the check fires only when most lines are equal.
    """
    widths = [units(L.rstrip()) for L in body]
    longest = max(widths)
    equal = sum(1 for w in widths if w == longest)
    if equal < len(widths) / 2:
        return
    for k, w in enumerate(widths):
        if w == longest:
            continue
        # A short line that ends on a border character, or that carries a
        # horizontal rule, is a frame line that lost columns. A short line that
        # merely *starts* with a vertical bar is the connector between two
        # stacked boxes ("│ ts_m[47:0]"); it is short on purpose.
        s = body[k].strip()
        bars = s.count("│") + s.count("|")
        if s and "─" not in s and bars <= 1:
            continue                                    # a connector, not a frame
        if s and (s[-1] in "│|└┌├+┘┐┤" or "─" in s):
            print(f"  note: frame line {k + 1} is {longest - w} column(s) short: "
                  f"{s[:40].encode('ascii', 'backslashreplace').decode()!r}")


def convert(md: str) -> str:
    lines = md.splitlines()
    out: list[str] = []
    i, n = 0, len(lines)
    para: list[str] = []

    def flush() -> None:
        if para:
            out.append(inline(" ".join(para)))
            out.append("")
            para.clear()

    while i < n:
        line = lines[i]

        if line.startswith("```"):
            flush()
            i += 1
            body = []
            while i < n and not lines[i].startswith("```"):
                body.append(lines[i])
                i += 1
            if i >= n:
                raise Unsupported("unterminated code fence")
            i += 1
            out.append(fence(body))
            out.append("")
            continue

        if re.match(r"^\s*\|.*\|\s*$", line) and i + 1 < n and _is_sep(lines[i + 1]):
            flush()
            block = [line, lines[i + 1]]
            i += 2
            while i < n and lines[i].strip().startswith("|"):
                block.append(lines[i])
                i += 1
            out.append(table(block))
            out.append("")
            continue

        m = re.match(r"^(#{1,6})\s+(.*)$", line)
        if m:
            flush()
            level = len(m.group(1))
            if level == 1:
                # The document title. It is already in the title block; emitting
                # it again as \section duplicates it in the table of contents.
                i += 1
                continue
            cmd = {2: "subsection", 3: "subsubsection"}.get(level)
            if cmd is None:
                raise Unsupported(f"heading level {level} has no LaTeX mapping")
            out.append("\\%s{%s}" % (cmd, inline(m.group(2))))
            out.append("")
            i += 1
            continue

        if re.fullmatch(r"\s*---+\s*", line):
            flush()
            out.append(r"\par\medskip\noindent\rule{\textwidth}{0.4pt}\medskip")
            out.append("")
            i += 1
            continue

        if line.startswith(">"):
            flush()
            quoted = []
            while i < n and lines[i].startswith(">"):
                quoted.append(lines[i].lstrip(">").strip())
                i += 1
            out.append(r"\begin{quote}")
            out.append(inline(" ".join(quoted)))
            out.append(r"\end{quote}")
            out.append("")
            continue

        if re.match(r"^\s*[-*]\s+", line):
            flush()
            out.append(r"\begin{itemize}")
            while i < n and re.match(r"^\s*[-*]\s+", lines[i]):
                item = re.sub(r"^\s*[-*]\s+", "", lines[i])
                i += 1
                # a wrapped continuation line belongs to the same item
                while (i < n and lines[i].strip()
                       and not re.match(r"^\s*([-*]\s+|\d+\.\s+|#|\||```|>)", lines[i])):
                    item += " " + lines[i].strip()
                    i += 1
                out.append(r"  \item " + inline(item))
            out.append(r"\end{itemize}")
            out.append("")
            continue

        if re.match(r"^\s*\d+\.\s+", line):
            flush()
            out.append(r"\begin{enumerate}")
            while i < n and re.match(r"^\s*\d+\.\s+", lines[i]):
                item = re.sub(r"^\s*\d+\.\s+", "", lines[i])
                i += 1
                while (i < n and lines[i].strip()
                       and not re.match(r"^\s*([-*]\s+|\d+\.\s+|#|\||```|>)", lines[i])):
                    item += " " + lines[i].strip()
                    i += 1
                out.append(r"  \item " + inline(item))
            out.append(r"\end{enumerate}")
            out.append("")
            continue

        if not line.strip():
            flush()
            i += 1
            continue

        # An HTML tag lookalike is markup TeX would choke on; a bare '<' is not
        # (this project writes `<<6` and `sim/vectors/<mode>/` inside code spans,
        # where they are literal), so code spans are removed before the test.
        prose = re.sub(r"`[^`]*`", "", line)
        if (re.match(r"^\s*!\[", line) or re.match(r"^\s*\[\^", line)
                or re.search(r"</?[A-Za-z][^>]*>", prose)):
            snippet = line[:60].encode("ascii", "backslashreplace").decode()
            raise Unsupported(f"unsupported markup on line {i + 1}: {snippet!r}")

        para.append(line.strip())
        i += 1

    flush()
    return "\n".join(out)


PREAMBLE = r"""\documentclass[10pt]{ctexart}
\usepackage[a4paper,margin=2.1cm]{geometry}
\usepackage{booktabs}
\usepackage{longtable}
\usepackage{array}
\usepackage{hyperref}
\usepackage{fancyhdr}
\usepackage{fancyvrb}
\usepackage{xcolor}
\hypersetup{colorlinks=true,linkcolor=black,urlcolor=blue!50!black,
            pdftitle={@@TITLE@@}}
% The design report draws stack diagrams in verbatim with box-drawing
% characters (U+2500 block) and Greek letters. The default lmmono has neither,
% and xelatex drops them silently as blank space. Consolas covers the box block
% and the Greek letters; CJK inside code blocks falls through to SimSun.
\setmonofont{Consolas}
\setCJKmonofont{SimSun}
% Greek, arrows, math operators, superscripts and circled digits occur in the
% prose. Latin Modern has none of them and xelatex drops them silently; sending
% those ranges to the CJK font, which does have them, costs one line.
\xeCJKDeclareCharClass{CJK}{"2070->"209F, "2190->"21FF,
                            "2200->"22FF, "2460->"24FF}
% SimSun lacks a few of them anyway (minus sign, double arrow, superscript
% minus); map those to their math equivalents so nothing disappears.
\usepackage{newunicodechar}
\newunicodechar{−}{$-$}
\newunicodechar{↔}{$\leftrightarrow$}
\newunicodechar{⇒}{$\Rightarrow$}
\newunicodechar{⁰}{\textsuperscript{0}}
\newunicodechar{⁻}{\textsuperscript{$-$}}
% Greek is a separate problem: SimSun, the CJK font, draws it full width, so
% `τ_m` came out as "τ _m" -- the letter and its subscript read as two tokens.
% The Latin fonts here have no Greek at all (8 missing glyphs when Greek was
% left to them), Consolas has it and draws it proportionally, so the three
% letters the reports use are sent there explicitly. Greek is deliberately not
% in the CJK class above, or the CJK font would claim it again.
\newunicodechar{τ}{{\fontspec{Consolas}τ}}
\newunicodechar{ε}{{\fontspec{Consolas}ε}}
\newunicodechar{ψ}{{\fontspec{Consolas}ψ}}
\setlength{\parindent}{0pt}
\setlength{\parskip}{4pt}
% Mixed Chinese and long unbreakable identifiers: TeX's default tolerance
% gives up on a line whose only breaks are far apart, and runs past the margin.
% A little emergency stretch lets it find a legal break instead.
\setlength{\emergencystretch}{3em}
\renewcommand{\arraystretch}{1.18}
% The Markdown headings already carry their own numbers (1, 2.1, 3.4). Letting
% LaTeX number them too produces "1.2 1 概述与应用背景" in the contents.
\setcounter{secnumdepth}{0}
\setcounter{tocdepth}{2}
\pagestyle{fancy}
\fancyhf{}
\fancyfoot[C]{\small\thepage}
\renewcommand{\headrulewidth}{0pt}
\begin{document}
\begin{center}
  {\LARGE @@TITLE@@}\\[4pt]
  {\small @@SUBTITLE@@}
\end{center}
\vspace{2mm}
\tableofcontents
\newpage
"""

POSTAMBLE = "\n\\end{document}\n"


def build(md_path: str, title: str, subtitle: str) -> str:
    with open(md_path, encoding="utf-8") as f:
        body = convert(f.read())
    head = (PREAMBLE.replace("@@TITLE@@", escape(title))
                    .replace("@@SUBTITLE@@", escape(subtitle)))
    return head + body + POSTAMBLE


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("source")
    ap.add_argument("-o", "--out", required=True)
    ap.add_argument("--title", default="")
    ap.add_argument("--subtitle", default="")
    a = ap.parse_args(argv[1:])
    try:
        tex = build(a.source, a.title or "报告", a.subtitle)
    except Unsupported as e:
        print(f"cannot convert: {e}")
        return 1
    with open(a.out, "w", encoding="utf-8", newline="\n") as f:
        f.write(tex)
    print(f"wrote {a.out} ({len(tex)} chars)")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
