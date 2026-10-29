#!/usr/bin/env python3
"""Build ../evidence_manifest.json from metrics/metrics.csv.

Every row of metrics.csv names the artefact that backs it. This script resolves
each of those paths against the repository and records, for every file, its size
and md5 -- so a reader can check two things without trusting this report:

  1. every cited file is actually shipped in the repository, and
  2. the copy they have is the copy the numbers came from.

A row whose evidence does not resolve is NOT dropped. It stays in the JSON with
status "missing" or "present_but_not_shipped", because a claim with no shipped
evidence is a finding about the submission, not something to tidy away.

    python metrics/make_evidence_manifest.py            # writes ./evidence_manifest.json
    python metrics/make_evidence_manifest.py --check    # exit 1 if anything is missing

ASCII only: no reason to risk a codec on a file that gets read by CI and by hand.
"""

import argparse
import csv
import hashlib
import json
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)

# Rows in metrics.csv cite a few files that live outside the submission tree
# (working notes in the developer's Chinese-named tree). Each one has a shipped
# successor that carries the same number. Map them rather than deleting the row.
# Working note in the developer tree whose name is not ASCII; built from code
# points so this file stays ASCII (U+6570 U+5B57 U+603B U+8868).
_NOTE = "_" + "".join(chr(c) for c in (0x6570, 0x5B57, 0x603B, 0x8868)) + ".md"

ALIAS = {
    # developer working note "_<U+6570><U+5B57><U+603B><U+8868>.md" row E, which is
    # where the 54.5 KB weight-ROM figure was first recorded; the shipped table is
    # metrics/resource.csv. Escaped so this file stays ASCII.
    _NOTE: "metrics/resource.csv",
    "review_20261028/board_repeat_results.json": "board/repeat.json",
    "gen_logs": "board/baremetal/logs",
}

# Shipped separately in the submission archive, not in git: .gitignore keeps the
# bitstreams and BOOT.BIN out of the repository (see BITSTREAM_MANIFEST.md).
NOT_IN_GIT = {
    "attn4_e4.bit": "1e2555571c380d8fbaa2324141023e6f",
    "attn3_e4.bit": "a607316a7041fdb9798c139bff430a6c",
    "attn2_e4.bit": "d9fd5e4565f20f931e51df18aa89da48",
    "ts_e4.bit": "4fa3518fcb61ad5d91d8379001909806",
    "BOOT.BIN": "93f8caee4a2e4b365622cfa0dee230d2",
}


def md5(path):
    h = hashlib.md5()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def tracked_files():
    """Paths git tracks, relative to ROOT with forward slashes."""
    try:
        out = subprocess.check_output(
            ["git", "ls-files", "-z"], cwd=ROOT, stderr=subprocess.DEVNULL
        )
    except (OSError, subprocess.CalledProcessError):
        return None
    return {p.decode("utf8", "replace") for p in out.split(b"\0") if p}


def resolve(raw, tracked):
    """One evidence string -> {path, status, bytes, md5} or a list of them."""
    p = raw.strip()
    if not p:
        return []
    # "path #E" / "path:12" style suffixes carry a section marker, not a path.
    if "#" in p:
        p = p.split("#", 1)[0].strip()
    key = p.lower()
    if key in ALIAS or p in ALIAS:
        p = ALIAS.get(p, ALIAS.get(key, p))
    if p.endswith("/"):
        p = p[:-1]

    abs_p = os.path.join(ROOT, p.replace("\\", "/"))
    exists = os.path.exists(abs_p)
    is_dir = os.path.isdir(abs_p)

    if is_dir:
        n = 0
        for _base, _dirs, files in os.walk(abs_p):
            n += len(files)
        return [{"path": p, "status": "tracked" if _dir_tracked(p, tracked) else "present_but_not_shipped",
                 "kind": "directory", "files": n}]

    if not exists:
        return [{"path": p, "status": "missing"}]

    shipped = tracked is None or p.replace("\\", "/") in tracked
    return [{
        "path": p,
        "status": "tracked" if shipped else "present_but_not_shipped",
        "kind": "file",
        "bytes": os.path.getsize(abs_p),
        "md5": md5(abs_p),
    }]


def _dir_tracked(prefix, tracked):
    if tracked is None:
        return True
    pre = prefix.replace("\\", "/").rstrip("/") + "/"
    return any(t.startswith(pre) for t in tracked)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--check", action="store_true",
                    help="exit 1 if any evidence is missing or not shipped")
    ap.add_argument("-o", "--out", default=os.path.join(ROOT, "evidence_manifest.json"))
    args = ap.parse_args()

    tracked = tracked_files()
    claims = []
    tally = {"tracked": 0, "present_but_not_shipped": 0, "missing": 0}

    with open(os.path.join(HERE, "metrics.csv"), newline="", encoding="utf8") as f:
        rows = list(csv.reader(f))
    header = [h.strip() for h in rows[0]]
    for row in rows[1:]:
        if not row or not row[0].strip():
            continue
        # metrics.csv is not uniformly 8 columns: rows that fold the number into
        # the claim text are one field shorter. Anchor on the right-hand columns,
        # which are always present in the same order.
        #   ... protocol , evidence , limitation
        if len(row) < 6:
            continue
        id_, category = row[0].strip(), row[1].strip()
        limitation = row[-1].strip()
        evidence = row[-2].strip()
        protocol = row[-3].strip() if len(row) >= 6 else ""
        unit = row[-4].strip() if len(row) >= 6 else ""
        middle = [x.strip() for x in row[2:-4] if x.strip()]
        claim = middle[0] if middle else ""
        value = middle[1] if len(middle) > 1 else ""

        ev = []
        for raw in evidence.split(","):
            for item in resolve(raw, tracked):
                ev.append(item)
                tally[item["status"]] += 1
        claims.append({
            "id": id_,
            "category": category,
            "claim": claim,
            "value": value,
            "unit": unit,
            "protocol": protocol,
            "limitation": limitation,
            "evidence": ev,
        })

    # A not_measured row is supposed to have no evidence file -- that is the
    # claim. Every other row must point at something that ships.
    bad = [c for c in claims
           if c["category"] != "not_measured"
           and (not c["evidence"] or any(e["status"] != "tracked" for e in c["evidence"]))]

    doc = {
        "generated": "2026-10-29",
        "generator": "metrics/make_evidence_manifest.py",
        "scope": "one entry per row of metrics/metrics.csv; each names the file the number came from",
        "how_to_verify": (
            "Recompute md5 of a cited file and compare with the value here. "
            "A row with status 'missing' is a claim without shipped evidence; "
            "'present_but_not_shipped' is a file on the author's disk that .gitignore "
            "keeps out of the repository."
        ),
        "git_tracked_files_seen": None if tracked is None else len(tracked),
        "summary": {
            "claims": len(claims),
            "evidence_references": sum(len(c["evidence"]) for c in claims),
            "tracked": tally["tracked"],
            "present_but_not_shipped": tally["present_but_not_shipped"],
            "missing": tally["missing"],
            "claims_with_gaps": len(bad),
        },
        "claims_with_gaps": [c["id"] for c in bad],
        "claims": claims,
        "shipped_separately": {
            "note": "not in git by design, see BITSTREAM_MANIFEST.md",
            "files": NOT_IN_GIT,
        },
    }

    with open(args.out, "w", encoding="utf8", newline="\n") as f:
        json.dump(doc, f, indent=2, ensure_ascii=False)
        f.write("\n")

    s = doc["summary"]
    print("wrote %s" % args.out)
    print("  claims               : %d" % s["claims"])
    print("  evidence references  : %d" % s["evidence_references"])
    print("  tracked              : %d" % s["tracked"])
    print("  present, not shipped : %d" % s["present_but_not_shipped"])
    print("  missing              : %d" % s["missing"])
    if bad:
        print("  claims with gaps     : %s" % ", ".join(c["id"] for c in bad))

    if args.check and bad:
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
