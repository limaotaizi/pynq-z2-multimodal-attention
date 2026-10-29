#!/bin/sh
# Bit-exact regression, mode m3. Equivalent to: ./run_one.sh m3
set -e
exec "$(dirname "$0")/run_one.sh" m3 "$@"
