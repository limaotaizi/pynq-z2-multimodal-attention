#!/bin/sh
# Bit-exact regression, mode m2. Equivalent to: ./run_one.sh m2
set -e
exec "$(dirname "$0")/run_one.sh" m2 "$@"
