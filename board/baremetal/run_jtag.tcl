# run_jtag.tcl -- 不换 SD 卡，直接把新 ELF 灌进去跑一遍。
#
#   xsdb run_jtag.tcl
#
# 为什么能这么干：PL 是 FSBL 从 SD 卡配好的，`rst -processor` 只复位 A9，
# 不动 PL，所以 attn_axi 还活着、scratch 还在。dow 把 ELF 写进 DDR 0x100000，
# con 从 _vector_table 起跳 —— 和从 SD 卡冷启动走的是同一段源码。
#
# 判据不变：串口上要看到 28 数组 / 5,504 字 ALL PASS、HEAD 的 OK。
#
# ★ 复位处理器会让 cache 失效，DDR 里也不会留下脏行，所以这里不需要额外刷 cache。

connect
puts "targets:"
puts [targets]

set apu [lindex [targets -filter {name =~ "*Cortex-A9*#0"}] 0]
if {$apu eq ""} { error "no Cortex-A9 #0 target" }
targets -set $apu

puts "-> stop / rst -processor"
stop
rst -processor
after 1000

puts "-> dow attn_m4.elf"
dow [file join [file normalize [file dirname [info script]]] ws attn_m4 Debug attn_m4.elf]

puts "-> con"
con
after 3000
exit
