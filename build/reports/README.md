# Vivado implementation reports

Raw output of `report_utilization` and `report_timing` on routed checkpoints.
`metrics/resource.csv` and `metrics/timing.csv` are transcriptions of these files;
if the two disagree, these files win.

| File | Design | Generated | Notes |
|---|---|---|---|
| `util_m2_e4.rpt` | M=2 whole BD + ε | 2026-10-28 01:09 | matches `attn2_e4.bit` (2026-10-28 01:15) |
| `util_m3.rpt` | M=3 whole BD | 2026-10-29 (rebuild) | reproduces `attn3_e4.bit`'s figures exactly — see the note below |
| `util_m4.rpt` | M=4 whole BD + ε | 2026-10-27 15:45 | matches `attn4_e4.bit` (2026-10-27 15:57) |
| `timing_m2_e4.rpt` | M=2 whole BD + ε | 2026-10-28 01:09 | |
| `timing_m3.rpt` | M=3 whole BD | 2026-10-29 (rebuild) | reproduces `attn3_e4.bit`'s figures exactly |
| `timing_m4.rpt` | M=4 whole BD + ε | 2026-10-27 15:45 | the production build |
| `worst_m4.rpt` | M=4 worst 12 paths | 2026-10-27 15:45 | the acc0 → DSP accumulator path that limits 200 MHz |
| `a1_util.rpt`, `a1_timing_summary.rpt` | A1 three-slave BD, no ε | 2026-10-20 14:47 | the pre-ε baseline reference in `metrics/timing.csv` |

## The 200 MHz / 100 MHz trap — read before quoting any slack number

The block design configures `PCW_FPGA0_PERIPHERAL_FREQMHZ {200}`, so **Vivado
constrains the whole design at 200 MHz and reports negative slack**. That is not
the operating point:

- the delivered bitstreams run at **100 MHz** — the application sets `DIVISOR0 = 10`
  before use, and `measure_fclk_mhz_x100` on the board reads 100.00;
- at 100 MHz the same routed design has **+4.264 ns** of setup margin (M=4) and
  all hold slacks are positive with zero failing endpoints.

The 100 MHz slack is not a committed `.rpt`: it was obtained by re-reporting the
routed checkpoint against a 10 ns period. It is recorded in the master number
table (`_数字总表.md` §C) and reproduced in `metrics/timing.csv`. To regenerate it:

```tcl
open_checkpoint attn_all_routed_v3.dcp
create_clock -period 10.000 -name clk_fpga_0 [get_pins ps7/inst/PS7_i/FCLKCLK[0]]
report_timing_summary -file timing_100mhz.rpt
```

**Do not quote the 200 MHz slack as a result.** It says "this design cannot run at
200 MHz without pipelining the accumulator", which is true and is stated in the
design report as a limitation — but the deliverable operates at 100 MHz and is
signed off there.

## The M=3 discrepancy, now resolved

Until 2026-10-29 the M=3 reports in this directory were the **2026-10-24**
checkpoint: `util_m3.rpt` reported 7,071 LUTs and `timing_m3.rpt` WNS −0.639 ns
with 239 failing endpoints, while the master number table recorded 7,135 LUTs and
−0.656 ns for the delivered `attn3_e4.bit` (built 2026-10-26). The reports were
two days older than the bitstream they were being attributed to.

A clean rebuild from this repository on 2026-10-29 (`make_tree.ps1 -Mode m3` →
`build_bd_all_m3_impl.tcl`) settled it: it produces **7,135 LUT, −0.656 ns,
+0.016 ns hold, 197 failing of 25,273 endpoints** — every figure the master table
attributes to the delivered bitstream. The three `.rpt` files here have been
replaced with that rebuild's output, so `metrics/resource.csv` and
`metrics/timing.csv` now point at reports that describe the shipped design.

M=4 and M=2 were rebuilt the same way on the same day, and both reproduce their
shipped reports **and** their shipped bitstreams — the `.bit` files are identical
apart from the build-date field in the header (5 and 7 bytes), so masking bytes
82–106 makes the md5 agree (`7f2a3fea…` and `4cb32e0c…`). M=3 matches the reports
exactly but not the bitstream: 57 configuration bytes differ, which
`BITSTREAM_MANIFEST.md` argues is a different route solution of the same design
rather than a different design.
