#!/bin/sh
# Bit-exact regression, mode m4. Equivalent to: ./run_one.sh m4
set -e
exec "$(dirname "$0")/run_one.sh" m4 "$@"
