#!/bin/sh
# Offline skill tests. No board, no pynq, no network.
# Needs Python 3.10+ and numpy (numpy only for the golden_compare cases).
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
PY="${PYTHON:-python}"
exec "$PY" -I -X utf8 "$HERE/test_offline.py"
