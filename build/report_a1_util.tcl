# Report utilization and the worst setup/hold paths of the routed A1 design.
# 2026-10-29 去硬编码：路径一律相对本脚本所在目录（_pl/），不再写死盘符。
set root [file normalize [file dirname [info script]]]
open_checkpoint [file join $root build_bd_all attn_all_routed_v3.dcp]

set rpt [file join $root a1_util.rpt]
report_utilization -hierarchical -file $rpt
puts "=== A1_UTIL_BEGIN"
if {![catch {open $rpt r} fh]} {
    while {[gets $fh line] >= 0} {
        if {[string match "| *" $line] && [string match "*LUT*" $line]} { puts $line }
        if {[string match "| *" $line] && ([string match "*Registers*" $line] ||
            [string match "*RAMB*" $line] || [string match "*DSP*" $line])} { puts $line }
    }
    close $fh
}
puts "=== A1_TIMING_BEGIN"
report_timing_summary -delay_type min_max -max_paths 1 \
    -file [file join $root a1_timing_summary.rpt]
report_timing -delay_type max -max_paths 5 -path_type summary \
    -file [file join $root a1_worst_setup.rpt]
report_timing -delay_type min -max_paths 5 -path_type summary \
    -file [file join $root a1_worst_hold.rpt]
puts "=== A1_REPORT_DONE"
