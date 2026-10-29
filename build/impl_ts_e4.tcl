# =============================================================================
# impl_ts_e4.tcl -- re-implement ts_build_e4 with explicit place/route
#                   directives, then export ts_e4.bit.
#
#   The default impl_1 flow landed at WNS = -0.012 ns once the eps registers
#   were in place (the same design without eps was +0.111 ns). This is the
#   known behaviour of this toolchain on these designs: the system BDs went
#   from -0.113 ns on impl_1 to +0.003 ns on the identical netlist with
#   place Explore, and attn_axi needed the same treatment.
#
#   Re-synthesis is NOT done here. synth_1 already holds the eps-aware netlist
#   and build_ts_e4.tcl asserted it (eps_r = 11 occurrences in the BD's
#   ipshared copy), so this script only re-implements that netlist.
#
#   Usage: vivado -mode batch -source impl_ts_e4.tcl
#   Output: build_ts_e4/ts_e4.bit, ts_e4.hwh, timing_e4.rpt, util_e4.rpt
#   VERSION: Vivado 2024.1.  ASCII only.
# =============================================================================

set root    [file normalize [file dirname [info script]]]
set bld_dir "$root/build_ts_e4"
set prj     "$bld_dir/ts_build_e4/ts_build_e4.xpr"

puts "=============================================================="
puts " ts_e4 re-implement  place=Explore  phys_opt=AggressiveExplore"
puts "=============================================================="

open_project $prj
open_run synth_1

opt_design
place_design -directive Explore
phys_opt_design -directive AggressiveExplore
route_design -directive Explore
phys_opt_design -directive AggressiveExplore
route_design

report_timing_summary -delay_type min_max -max_paths 10 -file "$bld_dir/timing_e4.rpt"
report_utilization -file "$bld_dir/util_e4.rpt"

set wns [get_property SLACK [get_timing_paths -delay_type max -max_paths 1 -nworst 1]]
set whs [get_property SLACK [get_timing_paths -delay_type min -max_paths 1 -nworst 1]]
puts [format "      WNS = %.3f ns   WHS = %.3f ns" $wns $whs]

if {$wns < 0 || $whs < 0} {
    error "Timing not met after directives: WNS=$wns ns, WHS=$whs ns. No bitstream."
}

write_bitstream -force "$bld_dir/ts_e4.bit"
write_hwdef      -force "$bld_dir/ts_e4.hwh"
puts "      ts_e4.bit written to $bld_dir"
