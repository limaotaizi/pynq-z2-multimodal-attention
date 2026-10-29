# =============================================================================
# write_bit_attn2.tcl -- sign attn2_e4_routed.dcp off at the board's real clock
#                        and write build_bd_all/attn2_e4.bit
#
#   usage:  vivado -mode batch -source <tree>/write_bit_attn2.tcl
#   input:  build_bd_all/attn2_e4_routed.dcp   (from build_bd_all_m2_e4.tcl)
#   output: build_bd_all/attn2_e4.bit, build_bd_all/attn2_e4.hwh
#
#   ★ attn_all.bit / attn3_e4.bit / attn4_e4.bit are NOT touched.  attn_all.bit
#     is the historical M=2 bitstream that the 3,200-word bit-exact board record
#     was taken on; this script must never overwrite it.  attn2_e4.bit is the
#     M=2 + E4 (eps in ts_top) combination, which is what metrics/timing.csv and
#     metrics/resource.csv quote.
#
# Why a second script at all: the block design constrains FCLK_CLK0 to 200 MHz.
# That is a pressure caliber, not an operating point -- the FSBL (DIVISOR0=10)
# drives the PL at 100 MHz, and M=2 does not close at 200 MHz either (the
# critical path is the same weight-ROM cascade -> DSP accumulator that M=3 and
# M=4 miss on).  Both honest ways to move the constraint are blocked in 2024.1
# (no remove_clock; PERIOD is read-only; editing FCLK0 in the BD is refused by
# the component.xml FREQ_HZ property), so the 100 MHz numbers are derived by an
# identity and CHECKED, not asserted:
#
#   one clock domain  =>  retargeting 5.000 -> 10.000 ns adds exactly +5.000 ns
#                          to the slack of every intra-clock setup path
#   WHS does not depend on the period, so it carries over unchanged
#
# and then, instead of claiming "nothing fails at 100 MHz", this script COUNTS
# it: the paths that still fail at 10 ns are exactly those with slack < -5.000
# at 5 ns.  If that set is non-empty the script errors out and no bitstream is
# written.  Same gate as write_bit_attn4.tcl; keep the two in step.
#
# The structural gates below are the other half of the argument: a netlist can
# close timing and still be the wrong design (stale per-IP OOC checkpoint merged
# by the block design -- see BITSTREAM_MANIFEST.md).  So before writing anything
# this script re-counts the weight-ROM banks, pc_reg/ir_reg, and the eps
# registers that E4 added to ts_top, and refuses on any of them.
#
# ASCII only.  Vivado 2024.1.
# =============================================================================
set root [file normalize [file dirname [info script]]]
set bld  "$root/build_bd_all"
set dcp  "$bld/attn2_e4_routed.dcp"

if {![file exists $dcp]} {
    error "no routed checkpoint at $dcp -- run build_bd_all_m2_e4.tcl first"
}
open_checkpoint $dcp

# ---- 1. prove the single clock domain before leaning on it -----------------
set allclk [get_clocks -quiet]
puts "   clocks in design: [llength $allclk] -> [get_property NAME $allclk]"
if {[llength $allclk] != 1} {
    error "expected exactly one clock domain; found [llength $allclk] -- the +5.000 ns argument does not hold, do not waive"
}
set p [get_property PERIOD [get_clocks clk_fpga_0]]
puts [format "   clock period = %.3f ns (BD declaration)" $p]
if {[expr {abs($p - 5.000)}] > 0.001} {
    error "period is $p ns, not the 5.000 this derivation was written for -- re-derive by hand"
}

# ---- 2. the 200 MHz numbers, for the record -------------------------------
set wns [get_property SLACK [get_timing_paths -delay_type max -max_paths 1 -nworst 1]]
set whs [get_property SLACK [get_timing_paths -delay_type min -max_paths 1 -nworst 1]]
set nfp [expr {
    [llength [get_timing_paths -quiet -delay_type max -slack_lesser_than 0 -max_paths 100000]]
  + [llength [get_timing_paths -quiet -delay_type min -slack_lesser_than 0 -max_paths 100000]]
}]
puts [format "   AT 200 MHz : WNS = %.3f  WHS = %.3f  failed_endpoints = %s" $wns $whs $nfp]

# ---- 3. retarget to 100 MHz and MEASURE what is left -----------------------
set d [expr {10.000 - $p}]
set wns100 [expr {$wns + $d}]
# slack < -d  <=>  slack + d < 0  <=>  still failing at 10 ns
set fp100 [expr {
    [llength [get_timing_paths -quiet -delay_type max -slack_lesser_than [expr {-$d}] -max_paths 100000]]
  + [llength [get_timing_paths -quiet -delay_type min -slack_lesser_than 0 -max_paths 100000]]
}]
set tw100 [get_timing_paths -quiet -delay_type max -slack_lesser_than [expr {-$d}] -max_paths 3]
puts [format "   AT 100 MHz (derived, +%.3f ns on every setup path): WNS = %.3f  WHS = %.3f  failed_endpoints = %s" \
      $d $wns100 $whs $fp100]
if {$fp100 != 0} {
    puts "   the paths that still fail at 100 MHz:"
    foreach_in_collection tp $tw100 {
        puts [format "     slack %.3f  %s -> %s" \
            [get_property SLACK $tp] \
            [get_property STARTPOINT_PIN $tp] [get_property ENDPOINT_PIN $tp]]
    }
}
if {$wns100 < 0 || $whs < 0 || $fp100 != 0} {
    error "even at 100 MHz this does not close (WNS100 $wns100 / WHS $whs / failed100 $fp100) -- real timing bug, not a clock-rate issue"
}

# ---- 4a. content gate: is this really the M=2 engine? ---------------------
# The unified RTL declares wrom 0:131071 unconditionally, so M=2 also fills 32
# banks (the historical A1 build used 8).  Require >= 8, the minimum that holds
# the 29,984 B of M=2 weights; the real discriminator is the 14-array bit-exact
# comparison on the board, not a bank count.
set nattn [llength [get_cells -hier -quiet -filter {REF_NAME =~ RAMB36E1 && NAME =~ "*attn_0*"}]]
set nmem  [llength [get_cells -hier -quiet -filter {REF_NAME =~ RAMB36E1 && NAME =~ "*attn_0*mem_reg*"}]]
set nba   [llength [get_cells -hier -quiet -filter {REF_NAME =~ RAMB36E1 && NAME =~ "*attn_0*wa_b_reg*"}]]
set nw    [expr {$nattn - $nmem - $nba}]
set npc   [llength [get_cells -hier -quiet -filter {NAME =~ "*pc_reg*"}]]
set nir   [llength [get_cells -hier -quiet -filter {NAME =~ "*ir_reg*"}]]
puts "   weight-ROM banks = $nw (need >= 8)   pc_reg = $npc   ir_reg = $nir"
if {$nw < 8}  { error "weight ROM only $nw banks -- wrong netlist, refusing to write a bitstream" }
if {$npc == 0 || $nir == 0} { error "pc_reg/ir_reg gone -- refusing to write a bitstream" }

# ---- 4b. content gate: E4 (the eps registers are in the netlist) ----------
set neps [llength [get_cells -hier -quiet -filter {NAME =~ "*ts_0*eps*"}]]
set ntau [llength [get_cells -hier -quiet -filter {NAME =~ "*ts_0*tau_r*"}]]
puts "   ts_0 eps cells = $neps (need >= 1)   tau_r cells = $ntau"
if {$neps < 1} {
    error "no eps registers in ts_0 of this netlist -- the BD merged a pre-E4 ts_top checkpoint, refusing to write a bitstream"
}

# ---- 5. write (e4 in the name; attn_all.bit is never a target) ------------
write_bitstream -force "$bld/attn2_e4.bit"
write_hwdef      -force "$bld/attn2_e4.hwh"
puts " SIGNOFF_100MHZ_DERIVED_M2: WNS_200m = [format %.3f $wns]  WNS_100m = [format %.3f $wns100]  WHS = [format %.3f $whs]  failed_200m = $nfp  failed_100m = $fp100"
puts " bitstream written: $bld/attn2_e4.bit"
puts " (attn_all.bit / attn3_e4.bit / attn4_e4.bit were NOT touched)"
puts "M2_SIGNOFF_DONE"
exit 0
