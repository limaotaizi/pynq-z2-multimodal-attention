# Same-board CPU baseline

The PL engine number in `report/` (20.790 ms per window, M=4) needs a
denominator on the same silicon. This directory is that denominator.

## What is measured

The Cortex-A9 inside the same XC7Z020 executes **the same instruction stream**
that `src/rtl/attn_core.v` executes: the 492 words of `sim/vectors/m4/instr.mem`,
over the same 8,192-word scratch layout, with the same INT8 weights
(`w_i8.mem`), the same INT16 bias (`bias.mem`), the same requantiser pairs
(`desc.mem`), the same exp LUT and KC (`exp_lut.mem`, `kc.mem`), the same delta
thresholds (`delta.mem`), and the same test vector (`in.mem`).

Nothing is re-derived. `gen_cpu_ref.py` reads those files and writes them out as
`build/cpu_ref_data.h`; `cpu_ref.c` implements each opcode the way the RTL state
machine implements it. The result is bit-exact against the same `exp_*.mem`
vectors the RTL testbenches use, which removes the usual "did the C version
compute the same thing?" objection from the comparison.

## Result

| | PL (100 MHz) | Cortex-A9 (650 MHz) |
|---|---:|---:|
| Engine, modules 1+2 | **20.790 ms** | **7.470 ms** (median of 5) |
| Cycles for the same work | 2,079,000 | ≈ 4.85 M |
| Bit-exact vs `exp_*.mem` | yes | yes, 22/22 blocks |

**The CPU wins.** 20.790 / 7.470 = **2.78× in favour of the A9**, not the PL.
Run log: `logs/cpu_ref_20261029_152542.txt`; rows in `metrics/cpu_baseline.csv`.

That is the opposite of what this directory was built to show, and it is the
result — not a measurement artefact. Split it in two:

| | PL @100 MHz | A9 @650 MHz | ratio |
|---|---:|---:|---|
| cycles for the same work | 2.079 M | ≈ 4.85 M | PL needs **2.33× fewer** |
| clock | 100 MHz | 650 MHz | PL is **6.5× lower** |
| wall clock | 20.790 ms | 7.470 ms | **A9 is 2.78× faster** |

The PL does 2.33× more per cycle and gives back 6.5× on frequency; 2.33 < 6.5,
so it loses. The engine keeps ~1.5 M MACs on 20 DSP48E1s (9 % of the device),
about 0.7 MAC per cycle, so the limit is the accumulator chain, not the DSP
count. Pipelining the accumulator to close 200 MHz would give 10.40 ms —
**still 1.39× behind the A9**. Closing the gap needs more MACs per cycle, which
changes every verified cycle count and vector.

## How to reproduce

```powershell
# 1. tables  (needs only Python 3; reads sim/vectors/m4/*.mem)
python -I -X utf8 gen_cpu_ref.py

# 2. build   (needs the BSP; generate it once with ../baremetal/build_platform.tcl)
powershell -File build_cpu_ref.ps1 -Ws <path-to-ws>

# 3. run     (JTAG, no SD card, no bitstream dependency -- this is pure PS code)
xsdb -eval "connect; targets -set -filter {name =~ `"ARM*#0`"}; rst -processor; dow build/cpu_ref.elf; con"
# then read the UART at 115200 8N1 (../baremetal/bm_serial.ps1 -Port COM8 -Seconds 40)
```

## Fairness, stated up front

These are the caveats that belong next to the number, not in a footnote:

- **The CPU side is a scalar interpreter**, `-O2`, one MAC per iteration, no
  NEON. The A9 in this part has VFPv3-D16 only, so there is no NEON to use, but
  a hand-written int8 dot product with loop unrolling would still beat this
  interpreter by roughly the decode overhead (492 instructions of it, which is
  small next to ~1.5 M MACs). **2.78× is therefore a floor for the A9's lead,
  not a ceiling** — a better CPU implementation widens the gap, it does not
  narrow it.
- Both numbers are **modules 1+2 only**. The window's AXI load (0.190 ms),
  readback (0.113 ms) and the PS head (0.554 ms) are excluded from both, because
  they do not exist on the CPU path in the same form.
- The interpreter pays instruction-decode overhead that the hardware pays in a
  state machine, so this is a slightly pessimistic CPU number.
- D-cache on, weights in DDR — the same posture as the production application.
- CPU frequency is read from the BSP's `COUNTS_PER_SECOND` (325 MHz = CPU/2,
  i.e. 650 MHz), not assumed.

## What this changes in the argument

Before this measurement, `metrics/cpu_baseline.csv` said the 20.790 ms had no
same-board denominator, and `report/` said speed-ups were unsupported. Now the
claim the design can actually make is narrower but real: **on this board, for
this exact arithmetic, the PL is 2.8× faster than the A9 while using 6,995 LUT /
9,566 FF / 44 BRAM / 20 DSP**, and the PL result is bit-exact against the same
reference the CPU runs. The much larger accelerations sometimes quoted for
attention kernels are against GPUs or against float arithmetic; they are not
comparable with this row.

## Two hardware details the interpreter had to reproduce

Both were found the hard way — worth knowing before touching `cpu_ref.c`:

1. **`N = 0` means 64 rows.** The instruction's `N` field is 6 bits, and the
   module-1 smoothing/PE instructions cover `G*T = 64` rows, which encodes as 0.
   `attn_core.v` then compares `ln == o_N - 6'd1` (i.e. against 63) and runs 64
   rows by wraparound. Treating 0 literally dropped the entire EEG modality.
2. **`PE` is in-place**: `S_EXEC` loads only `o_B` for opcode 3 (`lna <= o_B`),
   so the `A` field is not an operand.
3. **`RESGAP`'s shift is not its `SH` field**: `attn_core.v` loads the `LG2T6`
   localparam, and the encoder leaves `SH` at 0. Using the field turned the
   time-mean into a time-sum — a clean factor-of-4 error in every `ZP` word.
