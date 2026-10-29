# =============================================================================
# build_bd_all.tcl -- the whole PL in one block design:
#
#       PS7 M_AXI_GP0 (FCLK_CLK0 = 200 MHz)
#         +-- axi interconnect --- attn_axi    (0x4000_0000, 64K)
#                              \-- ts_top      (0x4001_0000, 4K)
#                              \-- eeg_fe_top  (0x4002_0000, 4K)
#
#   Three slaves, one clock, one reset.  ts_top's s_valid and eeg_fe_top's
#   ext_valid/ext_data are tied off: both blocks are driven from the PS side
#   (ts_top uses its internal strobe generator, eeg_fe_top takes samples
#   through its SAMPLE register).  Only ts_top's dbg_led goes to the board.
#
#   The EEG front-end is the block that never met the other two: its OOC
#   closure (+0.074 ns) relied on a tight pblock that does not exist inside a
#   BD.  This build measures the real thing.
#
#   Output: build_bd_all/  (project, timing.rpt, timing_paths.rpt, util.rpt,
#                           attn_all.bit, attn_all.hwh)
#   VERSION: Vivado 2024.1.  ASCII only.
# =============================================================================

set root    [file normalize [file dirname [info script]]]
# ---------------------------------------------------------------------------
# 2026-10-29: these scripts were written against the developer working tree,
# where this file sits in _pl/ next to ip_repo_all/, work2/ and build_bd_all/.
# The submission repository is a flat English-named tree (src/rtl, src/model,
# sim/) and does not have those directories. Say so here, in one line, instead
# of failing forty lines later inside Vivado with a missing-file error.
#
# Guard the inputs this script READS, not ip_repo_all/: line 35 below deletes
# and recreates ip_repo_all, so requiring it to pre-exist made this script
# impossible to run from a freshly assembled tree.
# ---------------------------------------------------------------------------
foreach d {rtl work2/rtl work2/out constr} {
    if {![file isdirectory [file join $root $d]]} {
        puts "ERROR: working tree incomplete under $root -- missing $d"
        puts "       this script needs rtl/, work2/rtl/, work2/out/ and constr/ as siblings."
        puts "       The submission repo has src/rtl/, src/model/, sim/ -- run"
        puts "       build/make_tree.ps1 to lay them out, see build/README.md."
        error "working tree incomplete under $root (missing $d)"
    }
}

set rtl_dir "$root/rtl"
set attn_rtl "$root/work2/rtl"
set bld_dir "$root/build_bd_all"
set ip_repo "$root/ip_repo_all"
set con_dir "$root/constr"

set part_name  "xc7z020clg400-1"
set board_part "tul.com.tw:pynq-z2:part0:1.0"
set prj_name   "bd_all"

file mkdir $bld_dir
file delete -force $ip_repo
file mkdir $ip_repo

puts "=============================================================="
puts " build_bd_all.tcl   root=$root"
puts "=============================================================="

# =============================================================================
# 1. Packaging helpers
#
#    The two traps from build_ts.tcl still apply:
#      * bus parameters are objects, not properties of the bus interface;
#      * package_project often infers clk/rst/s_axi already, so fetch-or-add.
# =============================================================================
proc bif {core name} {
    set l [ipx::get_bus_interfaces $name -of_objects $core -quiet]
    if {[llength $l] == 0} { return [ipx::add_bus_interface $name $core] }
    return [lindex $l 0]
}
proc pmap {b name physical} {
    set l [ipx::get_port_maps $name -of_objects $b -quiet]
    if {[llength $l] == 0} {
        ipx::add_port_map $name $b
        set l [ipx::get_port_maps $name -of_objects $b -quiet]
    }
    set_property physical_name $physical [lindex $l 0]
}
proc bparam {b name value} {
    set l [ipx::get_bus_parameters $name -of_objects $b -quiet]
    if {[llength $l] == 0} {
        ipx::add_bus_parameter $name $b
        set l [ipx::get_bus_parameters $name -of_objects $b -quiet]
    }
    set_property value $value [lindex $l 0]
}
proc find_bif_type {core type} {
    foreach b [ipx::get_bus_interfaces -of_objects $core] {
        if {[string first $type [get_property abstraction_type_vlnv $b]] >= 0} {
            return $b
        }
    }
    return ""
}

set axi_map {
    AWADDR  s_axi_awaddr   AWVALID s_axi_awvalid  AWREADY s_axi_awready
    WDATA   s_axi_wdata    WSTRB   s_axi_wstrb    WVALID  s_axi_wvalid
    WREADY  s_axi_wready   BRESP   s_axi_bresp    BVALID  s_axi_bvalid
    BREADY  s_axi_bready   ARADDR  s_axi_araddr   ARVALID s_axi_arvalid
    ARREADY s_axi_arready  RDATA   s_axi_rdata    RRESP   s_axi_rresp
    RVALID  s_axi_rvalid   RREADY  s_axi_rready
}

# package_one <name> <file list> <top> <clk port> <rst port> <display> <desc> <range>
proc package_one {repo part name files top clkport rstport display desc range argmap} {
    create_project -in_memory -part $part
    add_files -norecurse $files
    set_property top $top [current_fileset]
    update_compile_order -fileset sources_1

    # One core per -root_dir.  Pointing three packagings at the SAME root makes
    # each one overwrite component.xml, and the repo then exposes only the last
    # core (ERROR: [BD 5-390] IP definition not found).  Subdirectory per core.
    ipx::package_project -root_dir [file join $repo $name] -vendor user.org -library user \
        -taxonomy /UserIP -import_files -set_current true -force

    set core [ipx::current_core]
    set_property name         $name    $core
    set_property display_name $display $core
    set_property description  $desc    $core
    set_property vendor       user.org  $core
    set_property library      user      $core
    set_property version      1.0       $core
    set_property supported_families {zynq Production} $core

    set clkif [find_bif_type $core signal:clock]
    if {$clkif eq ""} { set clkif [bif $core $clkport] }
    set_property abstraction_type_vlnv xilinx.com:signal:clock_rtl:1.0 $clkif
    set_property bus_type_vlnv         xilinx.com:signal:clock:1.0     $clkif
    set_property interface_mode        slave                           $clkif
    bparam $clkif ASSOCIATED_BUSIF s_axi
    bparam $clkif ASSOCIATED_RESET $rstport
    bparam $clkif FREQ_HZ          200000000
    bparam $clkif PHASE            0.000
    pmap $clkif CLK $clkport

    set rstif [find_bif_type $core signal:reset]
    if {$rstif eq ""} { set rstif [bif $core $rstport] }
    set_property abstraction_type_vlnv xilinx.com:signal:reset_rtl:1.0 $rstif
    set_property bus_type_vlnv         xilinx.com:signal:reset:1.0     $rstif
    set_property interface_mode        slave                           $rstif
    bparam $rstif POLARITY ACTIVE_LOW
    pmap $rstif RST $rstport

    set bifaxi [find_bif_type $core interface:aximm]
    if {$bifaxi eq ""} { set bifaxi [bif $core s_axi] }
    set axiname [get_property name $bifaxi]
    set_property abstraction_type_vlnv xilinx.com:interface:aximm_rtl:1.0 $bifaxi
    set_property bus_type_vlnv         xilinx.com:interface:aximm:1.0     $bifaxi
    set_property interface_mode        slave                              $bifaxi
    bparam $bifaxi PROTOCOL               AXI4LITE
    bparam $bifaxi READ_WRITE_MODE        READ_WRITE
    bparam $bifaxi HAS_BURST              0
    bparam $bifaxi SUPPORTS_NARROW_BURST  0
    bparam $bifaxi MAX_BURST_LENGTH       1
    bparam $bifaxi NUM_READ_OUTSTANDING   1
    bparam $bifaxi NUM_WRITE_OUTSTANDING  1
    bparam $bifaxi FREQ_HZ                200000000
    bparam $bifaxi PHASE                  0.000
    foreach {logical phys} $argmap { pmap $bifaxi $logical $phys }

    set mml [ipx::get_memory_maps $axiname -of_objects $core -quiet]
    if {[llength $mml] == 0} {
        set mmap [ipx::add_memory_map $axiname $core]
    } else {
        set mmap [lindex $mml 0]
    }
    set_property slave_memory_map_ref $axiname $bifaxi
    set abll [ipx::get_address_blocks reg0 -of_objects $mmap -quiet]
    if {[llength $abll] == 0} {
        set ablk [ipx::add_address_block reg0 $mmap]
    } else {
        set ablk [lindex $abll 0]
    }
    set_property range $range $ablk
    set_property width {32}  $ablk

    ipx::create_xgui_files  $core
    ipx::update_checksums   $core
    ipx::save_core          $core
    close_project
    puts "      packaged $name"
}

puts "\n\[1/5\] packaging attn_axi, ts_top, eeg_fe_top ..."
package_one $ip_repo $part_name attn_axi \
    [list "$attn_rtl/attn_core.v" "$attn_rtl/attn_axi.v"] attn_axi \
    s_axi_aclk s_axi_aresetn \
    "INT8 Attention Core (AXI4-Lite)" \
    "INT8/INT16 attention backbone, modules 1+2, AXI4-Lite register file and 8192x16 scratch window." \
    64K $axi_map

package_one $ip_repo $part_name ts_top \
    [list "$rtl_dir/ts_core.v" "$rtl_dir/strobe_gen.v" "$rtl_dir/tau_comp.v" "$rtl_dir/ts_top.v"] ts_top \
    clk rst_n \
    "Global Timestamp + tau Compensation" \
    "200 MHz counter, 4-modality capture, shared timestamp FIFO, per-modality tau compensation." \
    4K $axi_map

package_one $ip_repo $part_name eeg_fe_top \
    [list "$rtl_dir/log2_cordic.v" "$rtl_dir/sdpram.v" "$rtl_dir/eeg_fe.v" "$rtl_dir/eeg_fe_top.v"] eeg_fe_top \
    clk rst_n \
    "EEG Front End (IIR + variance + CORDIC log2)" \
    "62-channel 5-band IIR front end with buffer-free variance and CORDIC log2, AXI4-Lite sample port." \
    4K $axi_map

# =============================================================================
# 2. Project + block design
# =============================================================================
puts "\n\[2/5\] creating project and block design ..."

create_project $prj_name "$bld_dir/$prj_name" -part $part_name -force
set_property board_part $board_part [current_project]
set_property ip_repo_paths [list "$ip_repo/attn_axi" "$ip_repo/ts_top" \
                                 "$ip_repo/eeg_fe_top"] [current_project]
update_ip_catalog -rebuild

create_bd_design "all_bd"

create_bd_cell -type ip -vlnv xilinx.com:ip:processing_system7:5.5 ps7
apply_bd_automation -rule xilinx.com:bd_rule:processing_system7 \
    -config {make_external "FIXED_IO, DDR" apply_board_preset "1"} [get_bd_cells ps7]
set_property -dict [list \
    CONFIG.PCW_FPGA0_PERIPHERAL_FREQMHZ {200} \
    CONFIG.PCW_EN_CLK0_PORT              {1}   \
    CONFIG.PCW_EN_RST0_PORT              {1}   \
    CONFIG.PCW_USE_M_AXI_GP0             {1}   \
] [get_bd_cells ps7]

create_bd_cell -type ip -vlnv user.org:user:attn_axi:1.0    attn_0
create_bd_cell -type ip -vlnv user.org:user:ts_top:1.0      ts_0
create_bd_cell -type ip -vlnv user.org:user:eeg_fe_top:1.0  eeg_0

foreach s {attn_0 ts_0 eeg_0} {
    apply_bd_automation -rule xilinx.com:bd_rule:axi4 \
        -config {Master "/ps7/M_AXI_GP0" Clk "Auto" ProcSysReset "Auto"} \
        [get_bd_intf_pins $s/s_axi]
}

# ts_top: internal strobe generator (SRC reset value 0xF), no external strobes.
create_bd_cell -type ip -vlnv xilinx.com:ip:xlconstant:1.1 const_svalid
set_property -dict [list CONFIG.CONST_WIDTH {4} CONFIG.CONST_VAL {0}] [get_bd_cells const_svalid]
connect_bd_net [get_bd_pins const_svalid/dout] [get_bd_pins ts_0/s_valid]

# eeg_fe_top: no external sample stream in this build -- samples arrive through
# the SAMPLE register.  Tie ext_valid low and ext_data to zero.
create_bd_cell -type ip -vlnv xilinx.com:ip:xlconstant:1.1 const_ev
set_property -dict [list CONFIG.CONST_WIDTH {1} CONFIG.CONST_VAL {0}] [get_bd_cells const_ev]
connect_bd_net [get_bd_pins const_ev/dout] [get_bd_pins eeg_0/ext_valid]
create_bd_cell -type ip -vlnv xilinx.com:ip:xlconstant:1.1 const_ed
set_property -dict [list CONFIG.CONST_WIDTH {22} CONFIG.CONST_VAL {0}] [get_bd_cells const_ed]
connect_bd_net [get_bd_pins const_ed/dout] [get_bd_pins eeg_0/ext_data]

# Only ts_top drives the four board LEDs; eeg_0/dbg_led stays unconnected.
create_bd_port -dir O -from 3 -to 0 dbg_led
connect_bd_net [get_bd_pins ts_0/dbg_led] [get_bd_ports dbg_led]

# ---- address map: pinned, not auto-assigned -------------------------------
# 2026-10-29: the slaves used to take whatever the address editor's auto-assign
# gave them, and it does not give the same answer on a fresh project -- a clean
# rebuild landed eeg_0 at 0x4001_1000 instead of 0x4002_0000. That is not a
# cosmetic difference: board/baremetal/src/main.c and board/deploy/probe_all.py
# hard-code 0x4000_0000 / 0x4001_0000 / 0x4002_0000, and main.c carries a
# compile-time assert on TS_BASE. A bitstream with a different decode would
# boot, run, and miss every peripheral.
# Pin all three so the rebuilt decode is the decoded one, byte for byte.
set aspace [get_bd_addr_spaces ps7/Data]
foreach {cell off rng} {
    attn_0 0x40000000 64K
    ts_0   0x40010000 4K
    eeg_0  0x40020000 4K
} {
    assign_bd_address -offset $off -range $rng -target_address_space $aspace \
        [get_bd_addr_segs "$cell/s_axi/reg0"]
}

# Read the assignment back out of the address space rather than trusting the
# command. get_property OFFSET returns it with digit separators (0x4000_0000),
# so compare with the separators stripped. Match on get_property NAME, not on
# the object's string form -- an IPI object does not stringify to its path.
proc addrval {s} { string map {_ ""} [string tolower $s] }
set segs [get_bd_addr_segs -quiet -of_objects $aspace]
puts "   ps7/Data holds [llength $segs] segment(s):"
foreach s $segs { puts "      [get_property NAME $s]" }

set found 0
foreach {cell off} {attn_0 0x40000000 ts_0 0x40010000 eeg_0 0x40020000} {
    # The segment is named SEG_<cell>_reg0 by the address editor; it does not
    # answer to the bus-interface path in get_property NAME.
    set hit ""
    foreach s $segs {
        if {[string match "SEG_${cell}_reg0" [get_property NAME $s]]} { set hit $s ; break }
    }
    if {$hit eq ""} { error "no address segment named SEG_${cell}_reg0 in ps7/Data" }
    set got [get_property OFFSET $hit]
    set okc [expr {[addrval $got] eq [addrval $off]}]
    puts [format "   %-7s @ %-14s (wanted %-12s) %s" $cell $got $off \
          [expr {$okc ? "ok" : "MISMATCH"}]]
    if {!$okc} { error "address assignment wrong for $cell: $got != $off" }
    incr found
}
if {$found != 3} { error "expected 3 slave address segments, verified $found" }

regenerate_bd_layout
validate_bd_design
save_bd_design

# =============================================================================
# 3. Wrapper + constraints
# =============================================================================
puts "\n\[3/5\] wrapper ..."
set bd_file [get_files "$bld_dir/$prj_name/$prj_name.srcs/sources_1/bd/all_bd/all_bd.bd"]
make_wrapper -files $bd_file -top
add_files -norecurse "$bld_dir/$prj_name/$prj_name.gen/sources_1/bd/all_bd/hdl/all_bd_wrapper.v"
set_property top all_bd_wrapper [current_fileset]
update_compile_order -fileset sources_1

# Board-level pins (dbg_led).  Attach BEFORE implementation: without it the
# bitgen DRC stops the run after timing has already been solved.
add_files -fileset constrs_1 -norecurse "$con_dir/pynq_z2_ts.xdc"
set_property target_constrs_file "$con_dir/pynq_z2_ts.xdc" [get_filesets constrs_1]

# =============================================================================
# 4. Build
# =============================================================================
# This script's own synth/impl produces the A1 baseline (attn_all.bit), a 200 MHz
# sign-off design that is not one of the shipped bitstreams. When what you want is
# the M=2/M=3/M=4 *project* for build_bd_all_m*_impl.tcl to work in, set
# BUILD_TREE_ONLY=1 and skip it -- those scripts reset_run synth_1 and synthesise
# from scratch anyway, so this run would be paid for twice.
if {[info exists ::env(BUILD_TREE_ONLY)]} {
    puts "\n\[4/5\] BUILD_TREE_ONLY set -- project + block design only, no runs launched"
    puts "      next: vivado -mode batch -source <tree>/build_bd_all_m4_impl.tcl"
    puts "\[5/5\] done"
    return
}

puts "\n\[4/5\] synthesis / implementation / bitstream ..."

launch_runs synth_1 -jobs 8
wait_on_run synth_1
set st [get_property STATUS [get_runs synth_1]]
puts "      synth_1 status: $st"
if {[string first "Complete" $st] < 0} {
    error "synth_1 did not complete (status: $st). Check the run log."
}
open_run synth_1

# Explicit physical steps: the default impl_1 flow lands at -0.113 on the
# attn-only BD while Explore/Explore closes the same netlist.
opt_design
place_design -directive Explore
phys_opt_design -directive AggressiveExplore
route_design -directive Explore
phys_opt_design -directive AggressiveExplore
route_design

# =============================================================================
# 5. Timing sign-off
# =============================================================================
report_timing_summary -delay_type min_max -max_paths 10 -file "$bld_dir/timing.rpt"
report_timing -delay_type max -max_paths 10 -sort_by group -file "$bld_dir/timing_paths.rpt"
report_utilization -file "$bld_dir/util.rpt"

set wns [get_property SLACK [get_timing_paths -delay_type max -max_paths 1 -nworst 1]]
set whs [get_property SLACK [get_timing_paths -delay_type min -max_paths 1 -nworst 1]]

puts "=============================================================="
puts " all_bd (PS7 + interconnect + attn_axi + ts_top + eeg_fe_top @ 200 MHz)"
puts "   WNS = $wns ns   WHS = $whs ns"
puts "=============================================================="

write_hwdef -force "$bld_dir/attn_all.hwh"
if {$wns >= 0 && $whs >= 0} {
    write_bitstream -force "$bld_dir/attn_all.bit"
    puts " bitstream written: $bld_dir/attn_all.bit"
} else {
    puts " timing not met, no bitstream"
}

puts "\[5/5\] done"
