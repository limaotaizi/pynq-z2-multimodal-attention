# =============================================================================
# write_bit_attn3.tcl -- sign attn3_all_routed.dcp off at the board's real clock
#                        and write build_bd_all/attn3_e4.bit
#
#   usage:  vivado -mode batch -source <tree>/write_bit_attn3.tcl
#   input:  build_bd_all/attn3_all_routed.dcp  (from build_bd_all_m3_impl.tcl)
#   output: build_bd_all/attn3_e4.bit, build_bd_all/attn3_e4.hwh
#
#   ★ attn3_all.bit (the M=3 bitstream without the E4 timestamp changes) and
#     attn_all.bit / attn2_e4.bit / attn4_e4.bit are NOT touched.  The routed
#     checkpoint this reads is named attn3_all_routed.dcp because the impl
#     script that writes it predates the E4 naming; the design inside it does
#     contain E4 (the eps gate in step 4b is what proves that).
#
# Same argument as write_bit_attn4.tcl, same order of operations, and the same
# "measure it, do not assert it" rule for the 100 MHz conversion -- read that
# file's header for the derivation.  The only differences are the input
# checkpoint, the output name, and the minimum weight-ROM bank count (M=3 needs
# 43,120 entries = 11 banks of 4096; the unified RTL fills 32).
#
# ASCII only.  Vivado 2024.1.
# =============================================================================
set root [file normalize [file dirname [info script]]]
set bld  "$root/build_bd_all"
set dcp  "$bld/attn3_all_routed.dcp"

if {![file exists $dcp]} {
    error "no routed checkpoint at $dcp -- run build_bd_all_m3_impl.tcl first"
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

# ---- 4a. content gate: is this really the M=3 engine? ---------------------
# Structural count (attn_0 RAMB36 minus scratch and bias), not a name match:
# after dont_touch the weight banks are renamed wd_reg_*, and a name-based count
# silently returned 0 on a correct netlist once already (2026-10-24).
set nattn [llength [get_cells -hier -quiet -filter {REF_NAME =~ RAMB36E1 && NAME =~ "*attn_0*"}]]
set nmem  [llength [get_cells -hier -quiet -filter {REF_NAME =~ RAMB36E1 && NAME =~ "*attn_0*mem_reg*"}]]
set nba   [llength [get_cells -hier -quiet -filter {REF_NAME =~ RAMB36E1 && NAME =~ "*attn_0*wa_b_reg*"}]]
set nw    [expr {$nattn - $nmem - $nba}]
set npc   [llength [get_cells -hier -quiet -filter {NAME =~ "*pc_reg*"}]]
set nir   [llength [get_cells -hier -quiet -filter {NAME =~ "*ir_reg*"}]]
puts "   weight-ROM banks = $nw (need >= 11 for the 43,120-entry M=3 wrom)   pc_reg = $npc   ir_reg = $nir"
if {$nw < 11} { error "weight ROM only $nw banks -- the M=3 wrom needs 43,120 entries; wrong netlist, refusing to write a bitstream" }
if {$npc == 0 || $nir == 0} { error "pc_reg/ir_reg gone -- refusing to write a bitstream" }

# ---- 4b. content gate: E4 (the eps registers are in the netlist) ----------
set neps [llength [get_cells -hier -quiet -filter {NAME =~ "*ts_0*eps*"}]]
set ntau [llength [get_cells -hier -quiet -filter {NAME =~ "*ts_0*tau_r*"}]]
puts "   ts_0 eps cells = $neps (need >= 1)   tau_r cells = $ntau"
if {$neps < 1} {
    error "no eps registers in ts_0 of this netlist -- the BD merged a pre-E4 ts_top checkpoint, refusing to write a bitstream"
}

# ---- 5. write (e4 in the name; attn3_all.bit is never a target) -----------
write_bitstream -force "$bld/attn3_e4.bit"
write_hwdef      -force "$bld/attn3_e4.hwh"
puts " SIGNOFF_100MHZ_DERIVED_M3: WNS_200m = [format %.3f $wns]  WNS_100m = [format %.3f $wns100]  WHS = [format %.3f $whs]  failed_200m = $nfp  failed_100m = $fp100"
puts " bitstream written: $bld/attn3_e4.bit"
puts " (attn3_all.bit / attn_all.bit / attn2_e4.bit / attn4_e4.bit were NOT touched)"
puts "M3_SIGNOFF_DONE"
exit 0
