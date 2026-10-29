# =============================================================================
# build_platform.tcl -- XSA -> Vitis 平台（standalone，ps7_cortexa9_0）+ FSBL
#
#   平台默认就会构建启动组件（FSBL），所以不要加 -no-boot-bsp。
#   产物位置（Vitis 2024.1 classic 流程）：
#     ws/attn4_plat/export/attn4_plat/sw/standalone_domain/boot/fsbl.elf
#
#   Usage: xsct build_platform.tcl
#   VERSION: Vitis 2024.1.
# =============================================================================
set bm [file normalize [file dirname [info script]]]
set ws "$bm/ws"
set xsa "$bm/attn4_e4.xsa"

if {![file exists $xsa]} { error "missing $xsa -- run export_xsa.tcl first" }

file mkdir $ws
setws $ws

# 干净重来：上一次的 tplat / attn4_plat 都在 ws 里，留着会让 platform create 报重名
foreach d [glob -nocomplain "$ws/*"] {
    file delete -force $d
}

puts "=============================================================="
puts " build_platform.tcl"
puts "   ws  = $ws"
puts "   xsa = $xsa ([file size $xsa] B, [clock format [file mtime $xsa]])"
puts "=============================================================="

platform create -name attn4_plat -hw $xsa -proc ps7_cortexa9_0 -os standalone
platform generate

puts "---- platform report ----"
puts [platform report attn4_plat]

puts "---- key artifacts ----"
# 注意：Tcl 的 glob 没有 -recurse（那是 PowerShell 的写法）。
# 与其拼一个递归 glob，不如直接点名要这三样：既能打印，又顺手当成存在性检查。
set must [list \
    "$ws/attn4_plat/export/attn4_plat/attn4_plat.xpfm" \
    "$ws/attn4_plat/zynq_fsbl/fsbl.elf" \
    "$ws/attn4_plat/export/attn4_plat/sw/attn4_plat/standalone_domain/bsplib/lib/libxil.a"]
set bad 0
foreach f $must {
    if {[file exists $f]} {
        puts "   ok  $f  ([file size $f] B)"
    } else {
        puts "   MISSING  $f"
        incr bad
    }
}
if {$bad > 0} { error "$bad expected artifact(s) missing -- platform generate did not finish" }
puts "PLATFORM_DONE"
exit 0
