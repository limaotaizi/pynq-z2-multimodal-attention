# =============================================================================
# write_bit_attn4.tcl -- 从已布线的 M=4 整机检查点补写位流
#
#   为什么需要这一步：BD 里 PS7 的 FCLK0 声明是 200 MHz（自设的压力口径），
#   build_bd_all_m4_impl.tcl 沿用 M=3/E4 的配方，要求 WNS>=0 && WHS>=0 才写位流。
#   M=4 引擎在 200 MHz 下 WNS = -0.736 ns，于是它只写了 routed.dcp + .hwh。
#
#   板端 FCLK_CLK0 实测是 **100.00 MHz**（分频在 BOOT.BIN/FSBL，位流与 JTAG 都不碰），
#   单时钟域 ⇒ WNS(10 ns) = WNS(5 ns) + 5.000 = +4.264 ns。也就是说位流在板子
#   真正跑的频率上是收敛的。
#
#   本脚本**不重新实现**：只是 open_checkpoint + write_bitstream，并把这个换算
#   打印出来存档。它绝不动 attn3_all.bit / attn3_e4.bit / attn_all.bit。
#
#   Usage: vivado -mode batch -source write_bit_attn4.tcl
#   VERSION: Vivado 2024.1.
# =============================================================================
set root [file normalize [file dirname [info script]]]
set bld  "$root/build_bd_all"
set dcp  "$bld/attn4_e4_routed.dcp"
set bit  "$bld/attn4_e4.bit"

if {![file exists $dcp]} {
    error "$dcp missing -- run build_bd_all_m4_impl.tcl first"
}

puts "=============================================================="
puts " write_bit_attn4.tcl"
puts "=============================================================="
puts "   checkpoint: $dcp  ([clock format [file mtime $dcp]])"

open_checkpoint $dcp

set wns5 [get_property SLACK [get_timing_paths -delay_type max -max_paths 1 -nworst 1]]
set whs5 [get_property SLACK [get_timing_paths -delay_type min -max_paths 1 -nworst 1]]
set nfp  [expr {
    [llength [get_timing_paths -quiet -delay_type max -slack_lesser_than 0 -max_paths 100000]]
  + [llength [get_timing_paths -quiet -delay_type min -slack_lesser_than 0 -max_paths 100000]]
}]
set req  [get_property REQUIREMENT [get_timing_paths -delay_type max -max_paths 1 -nworst 1]]
puts [format "   sign-off clock : %.3f ns (%.3f MHz)" $req [expr {1000.0/$req}]]
puts [format "   WNS @sign-off  = %.3f ns   WHS = %.3f ns   failed endpoints = %d" $wns5 $whs5 $nfp]

# 单时钟域换算。板端实测 FCLK_CLK0 = 100.00 MHz ⇒ 周期 10.000 ns。
# 只有当签核周期确实是 5 ns 时才加 5.000；否则只打印、不猜。
if {abs($req - 5.0) < 0.001} {
    # +5.000 on the worst path is necessary but not sufficient: what has to be
    # empty is the set of paths that are still negative at 10 ns, i.e. those with
    # slack < -5.000 at 5 ns. Count them instead of assuming they do not exist.
    set d 5.000
    set fp10 [expr {
        [llength [get_timing_paths -quiet -delay_type max -slack_lesser_than [expr {-$d}] -max_paths 100000]]
      + [llength [get_timing_paths -quiet -delay_type min -slack_lesser_than 0 -max_paths 100000]]
    }]
    set wns10 [expr {$wns5 + $d}]
    puts [format "   WNS @100 MHz   = %.3f ns  (= WNS@5ns + 5.000, board FCLK_CLK0 = 100.00 MHz)" $wns10]
    puts [format "   failed endpoints at 100 MHz = %d  (measured: slack < -5.000 ns at the 5 ns constraint)" $fp10]
    if {$wns10 < 0 || $fp10 != 0} {
        error "still not closed at the board's real clock -- refusing to write a bitstream"
    }
} else {
    puts "   sign-off period is not 5 ns -- the +5.000 conversion does not apply, not guessing"
    if {$wns5 < 0} {
        error "negative slack at an unexpected sign-off period -- refusing"
    }
}

# 与 2b 相同的两条"这份网表真的是 M=4 引擎"的判据，在写位流前再问一次。
set nattn [llength [get_cells -hier -quiet -filter {REF_NAME =~ RAMB36E1 && NAME =~ "*attn_0*"}]]
set nmem  [llength [get_cells -hier -quiet -filter {REF_NAME =~ RAMB36E1 && NAME =~ "*attn_0*mem_reg*"}]]
set nba   [llength [get_cells -hier -quiet -filter {REF_NAME =~ RAMB36E1 && NAME =~ "*attn_0*wa_b_reg*"}]]
set nw    [expr {$nattn - $nmem - $nba}]
set npc   [llength [get_cells -hier -quiet -filter {NAME =~ "*pc_reg*"}]]
puts "   attn_0 RAMB36: $nattn = weight $nw + scratch $nmem + bias $nba ; pc_reg = $npc"
if {$nw < 11} { error "weight ROM only $nw banks -- not the M=4 engine" }
if {$npc == 0} { error "pc_reg gone -- the instruction ROM is empty" }

write_bitstream -force $bit
puts "   bitstream written: $bit"
puts "   (attn3_all.bit / attn3_e4.bit / attn_all.bit were NOT touched)"
puts "WRITE_BIT_DONE"
exit 0
