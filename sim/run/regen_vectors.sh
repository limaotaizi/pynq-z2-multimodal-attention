#!/bin/sh
# Regenerate the golden vectors in ../vectors/<mode> from the quantised model.
#
#   AFFEC_CACHE=/path/to/cache ./regen_vectors.sh m4
#
# This is the *reproduce* step, not the *verify* step. The vectors are committed,
# so run_one.sh / run_attn_m*.sh work without this script and without the model.
#
# Needs two things that are not all in the repository:
#   src/model/assets/w_attn[3|4]_p_emotion_v_f0.npz   -- committed (small)
#   $AFFEC_CACHE/scenario-end_T4_w4_*.npz             -- NOT committed, 26-27 MB
#                                                        each, see DATA_LICENSE.md
#
# After regenerating, copy the diff into git and look at it. A changed vector is
# a changed arithmetic contract, not a formatting detail.
set -e
MODE=${1:?usage: ./regen_vectors.sh <m2|m3|m4>}
HERE=$(cd "$(dirname "$0")" && pwd)
OUT="$HERE/../vectors/$MODE"

: "${AFFEC_CACHE:?set AFFEC_CACHE to the directory holding scenario-end_T4_w4_*.npz}"

echo "[i] regenerating $MODE -> $OUT"
python -I -X utf8 "$HERE/../../src/model/export.py" "$MODE" --out "$OUT"
rm -f "$OUT/exp_note.txt" "$OUT/wordmap.txt"
echo "[i] done: $(ls "$OUT" | wc -l) files"
