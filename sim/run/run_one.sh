#!/bin/sh
# Bit-exact regression for one mode.  Usage:  ./run_one.sh <m2|m3|m4> [tb_module]
#
# Reads the committed golden vectors in ../vectors/<mode> -- no regeneration,
# no model assets, no network.  This is the check a reviewer can run first.
#
# How MEM_DIR is delivered: the test benches default it to ../vectors/<mode>,
# but a single attn_core.v serves all three modes, so its default cannot be
# per-mode.  Rather than fight shell/argv quoting through xvlog.bat -d, the
# runner writes a one-line memdir.vh and compiles it FIRST -- `ifndef MEM_DIR
# then sees it already defined and the RTL default is skipped.
#
# Vivado root: honour XILINX_VIVADO (set by Vivado settings64.sh/.bat),
# otherwise fall back to the local install.
set -e

MODE=${1:-m4}
HERE=$(cd "$(dirname "$0")" && pwd)
XV="${XILINX_VIVADO:-D:/Xilinx/Vivado/2024.1}/bin"
CORE="$HERE/../../src/rtl/attn_core.v"

case "$MODE" in
  m2) TB="$HERE/../../sim/tb/tb_attn.v";    TOP="${2:-tb_attn}" ;;
  m3) TB="$HERE/../../sim/tb/tb_attn_m3.v"; TOP="${2:-tb_attn_m3}" ;;
  m4) TB="$HERE/../../sim/tb/tb_attn_m4.v"; TOP="${2:-tb_attn_m4}" ;;
  *)  echo "usage: ./run_one.sh <m2|m3|m4>" >&2; exit 2 ;;
esac

cd "$HERE"
rm -rf xsim.dir
printf '`define MEM_DIR "../vectors/%s"\n' "$MODE" > memdir.vh
echo "[i] mode=$MODE  MEM_DIR=../vectors/$MODE  top=$TOP"

"$XV/xvlog.bat" memdir.vh "$CORE" "$TB" > "vlog_$MODE.log" 2>&1 || { tail -40 "vlog_$MODE.log"; exit 1; }
"$XV/xelab.bat" "$TOP" -s "tb_$MODE" --timescale 1ns/1ps > "elab_$MODE.log" 2>&1 || { tail -40 "elab_$MODE.log"; exit 1; }
"$XV/xsim.bat" "tb_$MODE" -runall > "run_$MODE.log" 2>&1 || true

if grep -q "WARNING: File ../vectors/" "run_$MODE.log"; then
    echo "FATAL: vector files not found -- check ../vectors/$MODE" >&2
    grep "WARNING: File" "run_$MODE.log" | head -3 >&2
    exit 1
fi

grep -E "MISMATCH|OK$|ALL PASS|FAIL|engine cycles" "run_$MODE.log"
