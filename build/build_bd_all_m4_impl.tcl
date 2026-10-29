# =============================================================================
# build_bd_all_m4_impl.tcl -- A1 三从机 BD，**M=4 引擎 (e+o+a+s)** + E4 (eps) 版 ts_top
#
#   2026-10-27 从 build_bd_all_e4_impl.tcl 派生。与 E4 那版相比只改了四处：
#     1) out/ 必须是 M=4 导出（mods=e,o,a,s，wbytes=55824，scratch 8192/8192 用满）
#     2) attn_axi 这个 IP 的源码副本必须带 `parameter integer UM = 12`
#        —— M=4 的 k/v 行数 U = T*(M-1) = 12，BD 不会覆盖 Verilog 参数缺省值，
#           不改就是拿 U=8 的数组去跑 U=12 的指令流，静默算错
#     3) ipshared 生成后同时断言 attn_core.v 与 attn_axi.v 都是新副本
#     4) 产物写 attn4_e4.*，**绝不覆盖**已逐位验证的 attn3_all.bit / attn3_e4.bit /
#        attn_all.bit
#
#   其余配方（0d/0e/0f/0f2：ipshared 副本、增量综合、按 IP 的 OOC 检查点、
#   ts_top 的 eps_r、pblock、ROM 银行数、pc_reg 判据）与 E4 完全一致，
#   那些坑的来龙去脉见 build_bd_all_e4_impl.tcl 的注释。
#
#   ★ attn_core.v 用绝对路径 $readmemh 读 work2/out/*.mem；out/ 只有一份。
#     跑本脚本之前必须先 `python -I -X utf8 work2/export.py m4`。
#
#   Usage:  vivado -mode batch -source build_bd_all_m4_impl.tcl
#   VERSION: Vivado 2024.1.
# =============================================================================
set root [file normalize [file dirname [info script]]]
# ---------------------------------------------------------------------------
# 2026-10-29: these scripts were written against the developer working tree,
# where this file sits in _pl/ next to ip_repo_all/, work2/ and build_bd_all/.
# The submission repository is a flat English-named tree (src/rtl, src/model,
# sim/) and does not have those directories. Say so here, in one line, instead
# of failing forty lines later inside Vivado with a missing-file error.
# ---------------------------------------------------------------------------
if {![file isdirectory [file join $root ip_repo_all]]} {
    puts "ERROR: developer tree layout not found under $root"
    puts "       this script needs ip_repo_all/, work2/ and build_bd_all/ as siblings."
    puts "       The submission repo has src/rtl/, src/model/, sim/ -- see build/README.md"
    puts "       for how to assemble the working tree from them."
    error "developer tree layout not found under $root"
}

set bld  "$root/build_bd_all"
set prj  "$bld/bd_all/bd_all.xpr"
set xci  "$bld/bd_all/bd_all.srcs/sources_1/bd/all_bd/ip/all_bd_xbar_0/all_bd_xbar_0.xci"
set ipsrc "$root/ip_repo_all/attn_axi/src/attn_core.v"
set axsrc "$root/ip_repo_all/attn_axi/src/attn_axi.v"
set note  "$root/work2/out/exp_note.txt"
set tssrc "$root/ip_repo_all/ts_top/src/ts_top.v"

puts "=============================================================="
puts " build_bd_all_m4_impl.tcl   $prj"
puts "=============================================================="

# ---- 0. 前置断言 ----------------------------------------------------------
puts "\n\[0/6\] preflight"

# 0a. out/ 必须是 M=4 导出（四路 e,o,a,s，weights 55,824 B，scratch 用满 8192）
set fh [open $note r]
set ntxt [read $fh]
close $fh
if {[string first "mode=m4" $ntxt] < 0 || [string first "mods=e,o,a,s" $ntxt] < 0} {
    error "work2/out is not the M=4 export (exp_note.txt: [string trim $ntxt]) -- run export.py m4 first"
}
if {[string first "wbytes=55824" $ntxt] < 0} {
    error "work2/out M=4 export has an unexpected weight size -- refusing to build"
}
if {[string first "scratch=8192" $ntxt] < 0} {
    error "work2/out M=4 export does not use the full 8192-word scratch -- refusing to build"
}
puts "   out/exp_note : [string trim $ntxt]"

# 0b. IP 仓库里的 attn_core.v 必须是带 UM 参数的那一版（M=3 起才有的）
set fh [open $ipsrc r]
set itxt [read $fh]
close $fh
if {[string first "parameter integer UM" $itxt] < 0} {
    error "$ipsrc is still the M=2 copy -- copy work2/rtl/attn_core.v over it first"
}
set nb [string length $itxt]
puts "   ip_repo attn_core.v : [expr {$nb/1024}] KiB, UM= present -> ok"
# ★ 2026-10-24：UM 只能证明"是 M=3 的深度"，不能证明"带上了最新的 RTL 修改"。
#   这一版必须带 REQP-1962 的解药（wrom / wa_w 的 dont_touch）：全 BD 的
#   opt_design 会把 131,072 项 ROM 的地址锥复制成两个不同的 LUT 锥，级联对的
#   ADDRARDADDR[15] 于是不同源，place 前报 16 条 REQP-1962 直接拒绝布局。
#   漏拷 ip_repo_all 会静默拿旧 RTL 再撞一次同一面墙。
if {[string first {(* dont_touch = "true" *)} $itxt] < 0} {
    error "$ipsrc lacks the REQP-1962 dont_touch fix -- copy work2/rtl/attn_core.v over it"
}
set dm [expr {[file mtime $ipsrc] >= [file mtime "$root/work2/rtl/attn_core.v"]}]
puts "   ip_repo mtime >= work2/rtl mtime : $dm"
if {!$dm} {
    error "$ipsrc is OLDER than work2/rtl/attn_core.v -- copy it over first"
}

# 0b1. ★ 2026-10-27 M=4 专属：IP 仓库里的 attn_axi.v 必须 (a) 有 UM 端口参数、
#      (b) 缺省值就是 12、(c) 真的把 UM 透传给 attn_core。
#   BD 实例化 IP 时用的是源码里的参数缺省值，UCI/component.xml 不会去改它 ——
#   缺省还是 8 的话，k/v 数组按 8 行开，而 M=4 的指令流要写第 9~12 行：
#   多驱动同一组寄存器会被综合保留成常量，或者干脆写丢，**综合全程零报错**。
set fh [open $axsrc r]
set atxt [read $fh]
close $fh
if {[string first "parameter integer UM" $atxt] < 0} {
    error "$axsrc is the pre-2026-10-26 copy (no UM) -- copy work2/rtl/attn_axi.v over it"
}
if {[string first "parameter integer UM = 12" $atxt] < 0} {
    error "$axsrc does not default UM to 12 -- M=4 would silently run with U=8"
}
if {[string first ".UM(UM)" $atxt] < 0} {
    error "$axsrc does not forward UM to attn_core -- the parameter would be ignored"
}
set dam [expr {[file mtime $axsrc] >= [file mtime "$root/work2/rtl/attn_axi.v"]}]
puts "   ip_repo attn_axi.v : UM=12 and .UM(UM) present, mtime ok = $dam"
if {!$dam} {
    error "$axsrc is OLDER than work2/rtl/attn_axi.v -- copy it over first"
}

# 0b2. E4: ip_repo_all 的 ts_top.v 必须是带 eps_r 的那一版
#   这一条和 0b 是同一个道理：IP 仓库里放的是旧 RTL，编出来的就是旧逻辑。
#   srcs/rtl 那一侧已经在 build_ts_e4 里验过（板上自检 40/40），这里只需要它真的被拷进来了。
set fh [open $tssrc r]
set ttxt [read $fh]
close $fh
set neps [llength [regexp -all -inline {eps_r} $ttxt]]
puts "   ip_repo ts_top.v : [expr {[string length $ttxt]/1024}] KiB, eps_r x $neps"
if {$neps < 1} {
    error "$tssrc has no eps_r -- copy rtl/ts_top.v over it first (E4)"
}

# 0c. 交叉开关译码必须还是 M=3 之前的三个从机（本脚本不改地址）
set fh [open $xci r]
set xtxt [read $fh]
close $fh
set ok 1
foreach {port base width} {
    M00 0x0000000040000000 16
    M01 0x0000000040010000 12
    M02 0x0000000040020000 12
} {
    set b "<not found>"
    set w "<not found>"
    foreach line [split $xtxt "\n"] {
        if {[string first "\"${port}_A00_BASE_ADDR\"" $line] >= 0} {
            regexp {"value": "([^"]*)"} $line m b
        }
        if {[string first "\"${port}_A00_ADDR_WIDTH\"" $line] >= 0} {
            regexp {"value": "([^"]*)"} $line m w
        }
    }
    set bad 0
    if {[expr {$b != $base}]}   { set bad 1 }
    if {[expr {$w != $width}]}  { set bad 1 }
    puts [format "   %s  base = %s  width = %s  %s" \
          $port $b $w [expr {$bad ? "MISMATCH" : "ok"}]]
    if {$bad} { set ok 0 }
}
if {!$ok} { error "crossbar decode changed -- refusing to synthesise" }

# 0c2. 签核频率：打印 BD 里 PS7 的 FCLK0 声明值。板上实测是 100 MHz
#      （分频在 FSBL），200 是自设的压力口径。两个数都要进报告。
set bdjson "$bld/bd_all/bd_all.srcs/sources_1/bd/all_bd/all_bd.bd"
set fh [open $bdjson r]; set btxt [read $fh]; close $fh
set fclk "?"
regexp {"PCW_FPGA0_PERIPHERAL_FREQMHZ"\s*:\s*\{\s*"value"\s*:\s*"([0-9.]+)"} $btxt -> fclk
puts "   BD FCLK0 (sign-off clock) = $fclk MHz"

open_project $prj

# ---- 续跑开关（2026-10-24）------------------------------------------------
#   综合 + synth_1 合并约 6 min，实现约 20 min。若上一轮死在「开 run 之后、
#   opt 之前」的闸门上（例如判据数错了 bank 名），网表本身是好的，
#   用 M3_RESUME=1 直接从 open_run synth_1 往下走，不必重复综合。
#   这条路径只跳过 0d~1 节的**生成**动作，2b 之后的所有闸门照跑。
set resume [expr {[info exists ::env(M3_RESUME)]}]
if {$resume} {
    set sst0 [get_property STATUS [get_runs synth_1]]
    puts "   M3_RESUME=1 : reusing synth_1 (status: $sst0)"
    if {[string first "Complete" $sst0] < 0} {
        error "M3_RESUME set but synth_1 is '$sst0' -- run without it"
    }
}

if {!$resume} {

# ---- 0d. ★ 真正的陷阱：BD 工程有自己的 IP 源码副本 ------------------------
#   Vivado 在 IP 生成时把 ip_repo_all/attn_axi/src/* 拷进
#   bd_all.gen/sources_1/bd/all_bd/ipshared/<hash>/src/，**综合读的是那一份**。
#   只改 ip_repo_all 不生效，会静默拿 M=2 的 RTL 配 M=3 的 .mem
#   （wrom 只有 32 K 项 → $readmemh 装不下 43,120 项）。
#   这里在 open_project 之后再断言一次，因为 open_project 有可能重新生成覆盖掉。
# ★ 2026-10-24：ipshared 为空**不是**错误状态。上一轮如果死在
#   「删 IP 产物 → generate_target 重拷」之间（被 Ctrl-C、被 TaskStop、
#   或断言失败），ipshared 就只剩一个无关的 hash 目录，ip/all_bd_attn_0_0
#   也一起没了。这正是本脚本下一步要重置并重建的东西 —— 在这里 error 会让
#   整个工程卡死在一个自己造成的中间态里，只能手工 regenerate。
#   所以这里只做"存在就核对"，真正的闸门是 generate_target 之后那一次断言。
set ips [glob -nocomplain "$bld/bd_all/bd_all.gen/sources_1/bd/all_bd/ipshared/*/src/attn_core.v"]
if {[llength $ips] == 0} {
    puts "   ipshared is empty (interrupted previous run) -- generate_target will repopulate it"
}
foreach f $ips {
    set fh [open $f r]
    set t [read $fh]
    close $fh
    set hasum [expr {[string first "parameter integer UM" $t] >= 0}]
    set hasdt [expr {[string first {(* dont_touch = "true" *)} $t] >= 0}]
    puts [format "   %s  %d KiB  UM=%s dont_touch=%s" $f [expr {[string length $t]/1024}] $hasum $hasdt]
    if {!$hasum} {
        error "ipshared copy is still M=2: $f -- copy work2/rtl/attn_core.v over it"
    }
    if {!$hasdt} {
        error "ipshared copy lacks the REQP-1962 dont_touch fix: $f"
    }
}
# ★ M=4：UM 的宿主是 attn_axi.v。这里的 ipshared 副本**必然是旧的** ——
#   上一轮（M=3/E4）生成的那份是 UM=8，而 0f 马上就会把它连同 IP 产物一起删掉重生成。
#   所以这里只报告、不判死；真正的闸门是 generate_target 之后的 0f3b。
foreach f [glob -nocomplain "$bld/bd_all/bd_all.gen/sources_1/bd/all_bd/ipshared/*/src/attn_axi.v"] {
    set fh [open $f r]
    set ta [read $fh]
    close $fh
    set um12 [expr {[string first "parameter integer UM = 12" $ta] >= 0}]
    puts "   ipshared attn_axi.v  [clock format [file mtime $f]]  UM=12 -> $um12 (expected 0, regenerated in 0f)"
}

# ---- 0e. ★ 关掉增量综合，删掉上一次的参考检查点 ---------------------------
#   2026-10-24 第一版 M=3 位流就是这样坏掉的，而且**全程零报错**：
#   RTL 已经是 M=3（0d 的 ipshared 断言 UM 通过、wrom 131,072 项），
#   但 synth_1 默认走 incremental synthesis，参考检查点是 Oct-20 的 M=2 网表
#   （日志第 130 行 "Read reference checkpoint ... for incremental synthesis"），
#   综合沿用了旧的存储器深度 —— 布线后的网表里权重 ROM 只有 **8 块 RAMB36**
#   （8 x 4,096 = 32,768 项，正是 M=2 的 wrom 深度），而 M=3 的 43,120 项要 11 块。
#   同一份网表里 brom 也只有 1 块 RAMB36（= 2,048 项，M=2 的深度）。
#   ⇒ 那一版 attn3_all.bit 实际是「M=2 的引擎 + M=3 的 .mem」，已删除。
# ---- 0f. ★★ 真正被合进网表的是「按 IP 生成的 OOC 检查点」，不是 ipshared 源码 ----
#   这是 2026-10-24 的第二个坑，比增量综合更硬：BD 里的用户 IP（attn_axi）在
#   `generate_target` 时被**单独 OOC 综合**成
#       bd_all.gen/sources_1/bd/all_bd/ip/all_bd_attn_0_0/all_bd_attn_0_0.dcp
#   然后 `synth_1` 只是把这个 dcp **合并**进 BD 网表。所以：
#     - 换 ipshared 源码 → 不生效（那份 dcp 是 10-20 的）
#     - 关增量综合 → 也不生效（增量是 synth_1 自己的事，跟 IP dcp 无关）
#     - `synth_1` 的利用率报告里 BRAM = 0，因为存储器在 IP dcp 里早就映射完了
#   证据：那块 dcp 的 mtime 是 10-20 13:45，权重 ROM 仍是 8 块（32,768 项）。
#   做法：reset_target 把它删掉、generate_target 重新 OOC 综合，再用 mtime 断言。
set attnip [get_ips -quiet all_bd_attn_0_0]
if {[llength $attnip] == 0} { error "BD has no all_bd_attn_0_0 IP -- BD layout changed" }
set attndcp "$bld/bd_all/bd_all.gen/sources_1/bd/all_bd/ip/all_bd_attn_0_0/all_bd_attn_0_0.dcp"
if {[file exists $attndcp]} {
    puts "   attn IP checkpoint before regeneration: [clock format [file mtime $attndcp]]"
}
puts "   regenerating the attn IP output products (this re-runs its OOC synthesis)"
# 注意：不能对**嵌套 IP** 直接 generate_target —— Vivado 会报
#   ERROR: [Vivado 12-3563] The Nested sub-design '...all_bd_attn_0_0.xci'
#                            can only be generated by its parent sub-design.
# 必须由 BD 本体（all_bd.bd）去生成。
set bdf [get_files all_bd.bd]
if {[llength $bdf] == 0} { error "all_bd.bd not found in the project" }
catch { reset_target all $bdf }
# 兜底：把这个 IP 的产物目录和缓存里的旧 dcp 一并删掉（按通配，不硬编码 hash）
file delete -force "$bld/bd_all/bd_all.gen/sources_1/bd/all_bd/ip/all_bd_attn_0_0"
foreach f [glob -nocomplain "$bld/bd_all/bd_all.cache/ip/*/*/*/*/all_bd_attn_0_0.*"] {
    file delete -force $f
}

# ---- 0f2. E4：同样处理 ts_top ---------------------------------------------
#   0f 讲的陷阱对 ts_top 一字不差：all_bd_ts_0_0.dcp（2026-10-24 08:15，250 KB）
#   里是**没有 eps_r** 的旧网表。不删它，synth_1 就把它合进 BD，
#   烧出来的"带 eps 的系统位流"读 0x70 全是 0 —— 而且全程零报错。
set tsip [get_ips -quiet all_bd_ts_0_0]
if {[llength $tsip] == 0} { error "BD has no all_bd_ts_0_0 IP -- BD layout changed" }
set tsdcp "$bld/bd_all/bd_all.gen/sources_1/bd/all_bd/ip/all_bd_ts_0_0/all_bd_ts_0_0.dcp"
if {[file exists $tsdcp]} {
    puts "   ts IP checkpoint before regeneration: [clock format [file mtime $tsdcp]]"
}
file delete -force "$bld/bd_all/bd_all.gen/sources_1/bd/all_bd/ip/all_bd_ts_0_0"
foreach f [glob -nocomplain "$bld/bd_all/bd_all.cache/ip/*/*/*/*/all_bd_ts_0_0.*"] {
    file delete -force $f
}
puts "   ts_top output products deleted -> generate_target will rebuild them"

generate_target all $bdf

# ---- 0f3. E4：生成之后再断言一次 ts_top 真的是带 eps 的那份 ---------------
#   ipshared 是综合真正读的副本；它没有 eps_r，位流就一定没有 eps 寄存器。
set tsipsh [glob -nocomplain "$bld/bd_all/bd_all.gen/sources_1/bd/all_bd/ipshared/*/src/ts_top.v"]
if {[llength $tsipsh] == 0} {
    error "E4: no ipshared ts_top.v after generate_target -- the ts IP was not regenerated"
}
set tseps 0
foreach f $tsipsh {
    set fh [open $f r]
    set t3 [read $fh]
    close $fh
    set n [llength [regexp -all -inline {eps_r} $t3]]
    incr tseps $n
    puts [format "   ipshared %s  %d KiB  eps_r x %d" $f [expr {[string length $t3]/1024}] $n]
}
puts "   E4 guard: eps_r in the BD ipshared ts_top.v = $tseps ([llength $tsipsh] file(s))"
if {$tseps < 1} {
    error "STALE IP SOURCE: the BD ipshared ts_top.v has no eps_r. Refusing to build."
}

# ---- 0f3b. M=4：生成之后再断言一次 attn 这个 IP 的两份源码都是新的 ---------
#   这一条是 0f 那个坑（综合读 ipshared / 合并 OOC 检查点）的最终闸门。
#   只要 attn_axi.v 不是 UM=12，或 attn_core.v 不是 128 KiB wrom 版，
#   位流就是错的，而且 **on-board 也只会"跑完、全 0 或部分位错"，不会报错**。
set axs2 [glob -nocomplain "$bld/bd_all/bd_all.gen/sources_1/bd/all_bd/ipshared/*/src/attn_axi.v"]
set cs2  [glob -nocomplain "$bld/bd_all/bd_all.gen/sources_1/bd/all_bd/ipshared/*/src/attn_core.v"]
puts "   M4 guard: ipshared attn_axi.v x [llength $axs2], attn_core.v x [llength $cs2]"
if {[llength $axs2] == 0 || [llength $cs2] == 0} {
    error "M=4: ipshared has no attn_axi.v/attn_core.v after generate_target -- the IP was not regenerated"
}
foreach f $axs2 {
    set fh [open $f r]; set ta2 [read $fh]; close $fh
    puts [format "   ipshared %s  %d KiB  UM=12 -> %s" $f [expr {[string length $ta2]/1024}] \
          [expr {[string first "parameter integer UM = 12" $ta2] >= 0}]]
    if {[string first "parameter integer UM = 12" $ta2] < 0} {
        error "STALE IP SOURCE: the BD ipshared attn_axi.v is not UM=12. Refusing to build."
    }
    if {[string first ".UM(UM)" $ta2] < 0} {
        error "STALE IP SOURCE: the BD ipshared attn_axi.v does not forward UM. Refusing to build."
    }
}
foreach f $cs2 {
    set fh [open $f r]; set tc2 [read $fh]; close $fh
    if {[string first "wrom \[0:131071\]" $tc2] < 0} {
        error "STALE IP SOURCE: $f is not the 128 KiB wrom version"
    }
}
# 这个 IP 的 synth_checkpoint_mode 是 **Global**（不是 Singular），所以
# generate_target 只产出 port stub（`synth/all_bd_attn_0_0.v`，6 KB、零 RAMB），
# 真正的综合发生在 synth_1 里。原先那块 560 KB 的 `.dcp` 是更早一次 Singular
# 流程的遗留物，synth_1 会优先用它 —— 这就是前两版位流变成 M=2 的原因。
# ⇒ 正确做法不是"要求 dcp 存在"，而是"要求 dcp 要么不存在、要么比 RTL 新"。
set ipsharedf [lindex [glob -nocomplain "$bld/bd_all/bd_all.gen/sources_1/bd/all_bd/ipshared/*/src/attn_core.v"] 0]
set newest [expr {max([file mtime $ipsharedf], [file mtime $ipsrc])}]
puts "   ipshared source mtime: [clock format $newest]"
set attnstale [glob -nocomplain "$bld/bd_all/bd_all.gen/sources_1/bd/all_bd/ip/all_bd_attn_0_0/*.dcp"]
if {[llength $attnstale] == 0} {
    puts "   no IP checkpoint present -> synth_1 will synthesise from RTL (Global mode). Good."
} else {
    foreach f $attnstale {
        puts "   IP checkpoint: $f  [clock format [file mtime $f]]"
        if {[file mtime $f] < $newest} {
            error "attn IP checkpoint $f is OLDER than the RTL -- synth_1 would reuse the M=2 netlist"
        }
    }
}
# 缓存里也不能有旧的
foreach f [glob -nocomplain "$bld/bd_all/bd_all.cache/ip/*/*/*/*/all_bd_attn_0_0.dcp"] {
    puts "   cache checkpoint: $f  [clock format [file mtime $f]]"
    if {[file mtime $f] < $newest} {
        error "stale cached IP checkpoint $f -- delete it before synthesising"
    }
}

# ---- 1. 重新综合（必须 reset，否则拿到的是 M=2 的缓存网表）---------------
puts "\n\[1/6\] synthesis (fresh) ..."
reset_run synth_1

# ★ 关增量的正确位置是 reset_run **之后**：reset_run 会把 runs/synth_1/ 里的 dcp
#   拷回 srcs/utils_1/imports/synth_1/ 当参考检查点，所以先删文件没用。
#   driver 是这三个属性（report_property [get_runs synth_1] 查到的）：
#     INCREMENTAL_CHECKPOINT               = <imports>/synth_1/all_bd_wrapper.dcp
#     AUTO_INCREMENTAL_CHECKPOINT          = 1
#     STEPS.SYNTH_DESIGN.ARGS.INCREMENTAL_MODE = default
puts "   forcing non-incremental synthesis"
catch { set_property AUTO_INCREMENTAL_CHECKPOINT 0 [get_runs synth_1] }
catch { set_property INCREMENTAL_CHECKPOINT ""        [get_runs synth_1] }
catch { set_property STEPS.SYNTH_DESIGN.ARGS.INCREMENTAL_MODE off [get_runs synth_1] }
puts "   AUTO_INCREMENTAL_CHECKPOINT = [get_property AUTO_INCREMENTAL_CHECKPOINT [get_runs synth_1]]"
puts "   INCREMENTAL_CHECKPOINT      = [get_property INCREMENTAL_CHECKPOINT [get_runs synth_1]]"
puts "   INCREMENTAL_MODE            = [get_property STEPS.SYNTH_DESIGN.ARGS.INCREMENTAL_MODE [get_runs synth_1]]"
if {[get_property AUTO_INCREMENTAL_CHECKPOINT [get_runs synth_1]] != 0} {
    error "could not disable incremental synthesis -- refusing to synthesise a possibly stale ROM"
}

# reset_run 之后再看一眼：万一 launch_runs 那一刻重新生成 output products，
# 有可能从别处把 ipshared 又覆盖回旧版。这里再断言一次，代价是零。
set ips2 [glob -nocomplain "$bld/bd_all/bd_all.gen/sources_1/bd/all_bd/ipshared/*/src/attn_core.v"]
# 空 glob 会让下面的 foreach 一声不响地跳过 —— 那正是"闸门看起来通过了"的形态。
if {[llength $ips2] == 0} {
    error "post-reset: ipshared is still empty -- generate_target did not repopulate it"
}
foreach f $ips2 {
    set fh [open $f r]
    set t2 [read $fh]
    close $fh
    # ★ 别写成整行匹配：2026-10-24 给 wrom 加了 dont_touch 前缀后，
    #   原来那句 "reg \[7:0\]         wrom \[0:131071\]" 就不再是这一行的样子了，
    #   闸门会把正确版本判成错的。只匹配声明本体。
    if {[string first "wrom \[0:131071\]" $t2] < 0} {
        error "post-reset: $f is not the 128 KiB wrom version"
    }
    if {[string first {(* dont_touch = "true" *)} $t2] < 0} {
        error "post-reset: $f lacks the REQP-1962 dont_touch fix"
    }
}

# -jobs 2, not 8 -- see the note in build_ts_e4.tcl. The training queue
# (_orchestr.ps1) has a 700 MB low-memory kill gate; Vivado's -jobs 8 forked
# 5 processes totalling 3.6 GB on 2026-10-26 and cost one fold.
launch_runs synth_1 -jobs 2
wait_on_run synth_1
set sst [get_property STATUS [get_runs synth_1]]
puts "      synth_1 status: $sst"
if {[string first "Complete" $sst] < 0} { error "synth_1 failed: $sst" }

} ;# end of if {!$resume}

# ---- 2. pblocks -----------------------------------------------------------
puts "\n\[2/6\] opening the synthesised netlist ..."
open_run synth_1 -name synth_1

# ---- 2a0. REQP-1962 的兜底开关（默认不启用）--------------------------------
# 2026-10-24：131,072 项 wrom 在 7 系列上被实现成 32 块 RAMB36、按 2 级级联。
# 级联对必须共享同一个 ADDRARDADDR[15]；全 BD 的 opt_design 会把地址锥复制成
# 两个不同的 LUT 锥，于是 place 前的 REQP-1962 报 16 条并拒绝布局。
# 这是 Vivado 2024.1 的已知缺陷（2024.2 修复），与 Vivado 2022.2/2023.2 相比
# 只有 2024.1 把它当 Error。首选修法是 RTL 里给 wrom / wa_w 加 dont_touch
# （掐掉复制）；本开关只在那个修法无效时才用，靠板端逐位比对作为最终判据。
if {[info exists ::env(M3_WAIVE_REQP1962)]} {
    set_property SEVERITY {Warning} [get_drc_checks REQP-1962]
    puts "   *** M3_WAIVE_REQP1962: REQP-1962 downgraded to Warning ***"
    puts "   *** (known Vivado 2024.1 ADDR15 replication bug; bit-exact board dump is the real check) ***"
}

# ---- 2b. ★★ 2026-10-24：程序计数器必须还在 ---------------------------------
#   第一版 M=3 位流的真正死因不是增量综合，而是 attn_core.v 里
#       for (ii = 0; ii < 131072; ii = ii + 1) wrom[ii] = 8'd0;
#   超过了 Vivado 的 initial 块 65,536 次循环上限：
#       WARNING: [Synth 8-6896] loop limit (65536) exceeded inside initial block,
#                initial block items will be ignored
#   **整个 initial 块被丢弃**，连同块里所有的 $readmemh ⇒ irom 全是 0 ⇒
#   上板后 start 一拍就读到 op=0（END），51 us 内 done、21 个数组全 0。
#   综合只给一条 WARNING，时序还从 +0.002 涨到 +0.021（因为 attn 只剩 427 LUT）。
#   判据：pc_reg / ir_reg 必须存在（M=3 实测 35 / 273 个 cell）。
set npc [llength [get_cells -hier -quiet -filter {NAME =~ "*pc_reg*"}]]
set nir [llength [get_cells -hier -quiet -filter {NAME =~ "*ir_reg*"}]]
puts "   pc_reg cells = $npc   ir_reg cells = $nir   (a real program needs both > 0)"
if {$npc == 0 || $nir == 0} {
    error "pc_reg/ir_reg are gone -- the instruction ROM synthesised as a constant.  Check the attn_0 synth log for [Synth 8-6896] (initial-block loop limit)."
}

proc put_in_box {pbname box pattern} {
    if {[llength [get_pblocks -quiet $pbname]] > 0} {
        delete_pblock [get_pblocks $pbname]
    }
    create_pblock $pbname
    resize_pblock [get_pblocks $pbname] -add $box
    set_property IS_SOFT 0 [get_pblocks $pbname]
    set cells [get_cells -hier -quiet -filter "NAME =~ \"$pattern\" && \
        (REF_NAME =~ LUT*   || REF_NAME =~ FD*    || REF_NAME =~ SRL*   || \
         REF_NAME =~ MUXF*  || REF_NAME =~ CARRY* || REF_NAME =~ RAMB*  || \
         REF_NAME =~ DSP48* || REF_NAME =~ IOBUF) "]
    puts "  [format %-10s $pbname] $box   cells = [llength $cells]"
    if {[llength $cells] > 0} { add_cells_to_pblock [get_pblocks $pbname] $cells }
    return [llength $cells]
}

set na [put_in_box pb_attn {CLOCKREGION_X0Y0:CLOCKREGION_X0Y1} "*/attn_0/*"]
set ne [put_in_box pb_eeg  {CLOCKREGION_X1Y1:CLOCKREGION_X1Y1} "*/eeg_0/*"]
if {$na == 0 && $ne == 0} { error "pblock patterns matched nothing" }

# 判据要**按 ROM 深度**判，不能按"存储器总数"判 —— 2026-10-24 第一版就是被
# 后者骗过去的：`PRIMITIVE_TYPE =~ BMEM.*` 把 4 块 RAMB18 也算进来，
# M=2 的 17 块 RAMB36 + 4 块 RAMB18 = 21，恰好过了 ">= 20" 这道闸。
# 真正该问的是：权重 ROM 被实现成几块、每块多深。
#   M=2：32,768 项（2^15）/ 4,096 ⇒ **8 块**
#   M=3：131,072 项（2^17，数组声明 0:131071）/ 4,096 ⇒ **32 块**
#   M=4：仍是 131,072 项声明的同一块 ROM，内容 55,824 B（14 块就装得下），
#        实现上仍是 32 块 —— 所以这一道闸对 M=4 只判"是不是又退回 8 块"，
#        真正区分 M=3/M=4 的是 0a 的 wbytes 与板端逐位比对。
#   （旧文档写的"16 块"是 IROM 被 8-6896 清空那一版的假网表给出的，已作废）
# 闸门写 ">= 11"：不被幂次取整卡住，但 8 与 32 分得很开。
#
# ★ 2026-10-24 第二次踩到：加了 dont_touch 之后 Vivado 给这组 RAMB 换了名字 ——
#   从 `wa_w_reg_*`（按地址寄存器命名）变成 `wd_reg_*`（按数据寄存器命名）。
#   判据死盯 "*wa_w*" 于是数出 0，在一份**完全正确**的网表上把构建掐了。
#   教训：名字是综合器的自由，判据不能绑名字。改成结构式 —— attn_0 里的 RAMB36
#   减去 scratch（mem_reg）与 bias ROM（wa_b_reg），剩下的就是权重 ROM。
#   名字式计数只作旁证打印，不再决定生死。
set n36 [llength [get_cells -hier -quiet -filter {REF_NAME =~ RAMB36E1}]]
set nattn [llength [get_cells -hier -quiet -filter {REF_NAME =~ RAMB36E1 && NAME =~ "*attn_0*"}]]
set nmem  [llength [get_cells -hier -quiet -filter {REF_NAME =~ RAMB36E1 && NAME =~ "*attn_0*mem_reg*"}]]
set nba   [llength [get_cells -hier -quiet -filter {REF_NAME =~ RAMB36E1 && NAME =~ "*attn_0*wa_b_reg*"}]]
set nw    [expr {$nattn - $nmem - $nba}]
set nwpat [llength [get_cells -hier -quiet -filter {REF_NAME =~ RAMB36E1 && (NAME =~ "*wd_reg_*" || NAME =~ "*wa_w*" || NAME =~ "*wrom*")}]]
puts "   RAMB36 cells in netlist: $n36   (A1/M=2 was 17)"
puts "   RAMB36 in attn_0: $nattn  = weight $nw + scratch $nmem + bias $nba"
puts "   weight-ROM banks (8 bit x 4096): $nw  [expr {$nw*4096}] entries   (M=2 = 8, M=3 = 32)"
if {$n36 < 19} {
    error "only $n36 RAMB36 -- this does not look like the three-slave system at all"
}
if {$nwpat != $nw} {
    puts "   note: name-based count ($nwpat) != structural count ($nw) -- cell naming changed, using structural"
}
if {$nw < 11} {
    error "weight ROM is only $nw x 4096 = [expr {$nw*4096}] entries -- the M=4 wrom needs 55,824.  Incremental synthesis reused the M=2 netlist."
}

# ---- 3. 实现 --------------------------------------------------------------
puts "\n\[3/6\] opt / place / phys_opt / route ..."
opt_design
place_design -directive Explore
puts [format " after place: WNS = %.3f ns" \
      [get_property SLACK [get_timing_paths -delay_type max -max_paths 1 -nworst 1]]]
phys_opt_design -directive AggressiveExplore
route_design -directive Explore

set wns [get_property SLACK [get_timing_paths -delay_type max -max_paths 1 -nworst 1]]
set whs [get_property SLACK [get_timing_paths -delay_type min -max_paths 1 -nworst 1]]
puts [format " after route: WNS = %.3f ns  WHS = %.3f ns" $wns $whs]

if {$wns < 0 || $whs < 0} {
    puts "\n\[3b\] retry: phys_opt + route x2"
    phys_opt_design -directive AggressiveExplore
    route_design -directive Explore
    phys_opt_design -directive AggressiveExplore
    route_design -directive Explore
    set wns [get_property SLACK [get_timing_paths -delay_type max -max_paths 1 -nworst 1]]
    set whs [get_property SLACK [get_timing_paths -delay_type min -max_paths 1 -nworst 1]]
    puts [format " retry:      WNS = %.3f ns  WHS = %.3f ns" $wns $whs]
}

set nfp [expr {
    [llength [get_timing_paths -quiet -delay_type max -slack_lesser_than 0 -max_paths 100000]]
  + [llength [get_timing_paths -quiet -delay_type min -slack_lesser_than 0 -max_paths 100000]]
}]

# ---- 4. 报告 --------------------------------------------------------------
puts "\n\[4/6\] reports ..."
report_timing_summary -delay_type min_max -max_paths 10 -file "$bld/timing_m4.rpt"
report_timing -delay_type max -max_paths 12 -nworst 1 -file "$bld/worst_m4.rpt"
report_utilization -file "$bld/util_m4.rpt"

puts "\n=============================================================="
puts [format " M4_RESULT: WNS = %.3f ns  WHS = %.3f ns  failed_endpoints = %s  RAMB36 = %s  wrom_banks = %s" \
      $wns $whs $nfp $n36 $nw]
puts "=============================================================="

# ---- 5. 产物（名字带 attn4，绝不覆盖 attn3_all / attn3_e4 / attn_all）-----
puts "\n\[5/6\] writing artefacts ..."
write_checkpoint -force "$bld/attn4_e4_routed.dcp"
write_hwdef      -force "$bld/attn4_e4.hwh"

# 布线后再问一次同一个问题：最终网表里的权重 ROM 到底是几块、多深。
# 位流只看最终网表，所以这一道不是重复，而是唯一真正拦得住的那一道。
# ★ 判据与 2b 相同：结构式（attn_0 的 RAMB36 减去 scratch 与 bias），不绑名字。
#   dont_touch 之后这组 RAMB 从 `wa_w_reg_*` 改名成了 `wd_reg_*`，名字式计数
#   会数出 0 —— 2026-10-24 已经因此在一份正确网表上误杀过一次构建。
set nattn2 [llength [get_cells -hier -quiet -filter {REF_NAME =~ RAMB36E1 && NAME =~ "*attn_0*"}]]
set nmem2  [llength [get_cells -hier -quiet -filter {REF_NAME =~ RAMB36E1 && NAME =~ "*attn_0*mem_reg*"}]]
set nba2   [llength [get_cells -hier -quiet -filter {REF_NAME =~ RAMB36E1 && NAME =~ "*attn_0*wa_b_reg*"}]]
set fw     [expr {$nattn2 - $nmem2 - $nba2}]
puts "   post-route attn_0 RAMB36: $nattn2 = weight $fw + scratch $nmem2 + bias $nba2   (M=2 was 8, M=3 = 32)"
if {$fw < 11} {
    error "post-route check failed: weight ROM has only $fw banks -- NOT writing a bitstream"
}
# 同 2b：布线后再确认一次程序计数器还在（合成时被常量折叠的引擎会静默跑空）
set pc2 [llength [get_cells -hier -quiet -filter {NAME =~ "*pc_reg*"}]]
puts "   post-route pc_reg cells: $pc2"
if {$pc2 == 0} { error "post-route: pc_reg is gone -- the engine would start and finish in 2 cycles" }

if {$wns >= 0 && $whs >= 0} {
    write_bitstream -force "$bld/attn4_e4.bit"
    puts " bitstream written: $bld/attn4_e4.bit"
    puts " (the verified attn3_all.bit / attn3_e4.bit / attn_all.bit were NOT touched)"
} else {
    puts " timing not met, no bitstream"
}
puts "\n\[6/6\] M4_DONE"
exit 0
