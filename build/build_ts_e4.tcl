# =============================================================================
# build_ts.tcl -- build the ts_top bitstream + .hwh for PYNQ-Z2
#
#   Usage (from a Vivado 2024.1 tcl console or shell):
#       vivado -mode batch -source build_ts.tcl
#   or from the GUI tcl console:
#       source <repo>/build/build_ts.tcl
#
#   Output goes to  <root>/build/  :
#       ts.bit   ts.hwh      <-- copy BOTH to the board (same base name!)
#
# -----------------------------------------------------------------------------
# VERSION -- DO NOT "UPGRADE" THIS CASUALLY
#
#   Vivado 2024.1 is required, not 2022.1.
#
#   The board runs PYNQ 3.1, whose kernel string is
#     Linux-6.6.10-xilinx-v2024.1-...-armv7l-with-glibc2.35
#   PYNQ's own changelog maps PYNQ v3.0.x -> Vivado 2022.1 and
#   PYNQ v3.1 -> Vivado 2024.1. A .hwh produced by a mismatched Vivado can fail
#   to parse on the board (e.g. "PortNotFound: ... s_axi_awid").
#
#   PYNQ-Z2 board files are NOT bundled with Vivado. They must be unpacked to
#      <Xilinx install>/Vivado/2024.1/data/xhub/boards/XilinxBoardStore/boards/Xilinx/
#   NOTE: that path is new in recent Vivado. Older guides say
#      .../Vivado/<ver>/data/boards/board_files/
#   which no longer works. Restart Vivado after copying.
#
# -----------------------------------------------------------------------------
# ASCII ONLY -- deliberately. A toolchain reading UTF-8 under a zh-CN code page
# is a classic silent failure. Explanations live in README_PL.md.
# =============================================================================

set root    [file normalize [file dirname [info script]]]
set rtl_dir "$root/rtl"
set con_dir "$root/constr"
set bld_dir "$root/build_ts_e4"
set ip_repo "$root/ip_repo"

set part_name  "xc7z020clg400-1"
set board_part "tul.com.tw:pynq-z2:part0:1.0"
set prj_name   "ts_build_e4"

file mkdir $bld_dir
file mkdir $ip_repo

puts "=============================================================="
puts " build_ts.tcl   root=$root"
puts "=============================================================="

# =============================================================================
# 1. Package ts_top as an IP
#
#    Why package instead of dropping the RTL straight into the block design?
#    A module reference in a BD bundles its s_axi_* signals into an AXI
#    interface only if Vivado infers it, which is not reliable. Packaging
#    declares the interface explicitly -- including the memory map PYNQ needs
#    to find the registers at run time.
# =============================================================================
puts "\n\[1/6\] packaging ts_top as IP ..."

create_project -in_memory -part $part_name
add_files -norecurse [list "$rtl_dir/ts_top.v"    "$rtl_dir/ts_core.v" \
                           "$rtl_dir/tau_comp.v" "$rtl_dir/strobe_gen.v"]

ipx::package_project -root_dir $ip_repo -vendor user.org -library user \
    -taxonomy /UserIP -import_files -set_current true -force

set core [ipx::current_core]
set_property name          ts_top                                   $core
set_property display_name  "Global Timestamp + tau Compensation"    $core
set_property description   "200 MHz free-running counter, 4-modality capture, shared timestamp FIFO, per-modality tau compensation (t_m = t - tau_m)." $core
set_property vendor        user.org                                 $core
set_property library       user                                     $core
set_property version       1.0                                      $core
set_property supported_families {zynq Production}                   $core

# ---------------------------------------------------------------- clock / reset
# These two signal interfaces are what ASSOCIATED_BUSIF / ASSOCIATED_RESET point
# at. Without them the AXI interface has no associated clock and the BD cannot
# be validated.
#
# ★ IDEMPOTENCE. ipx::package_project runs bus inference, and because the ports
#   are named s_axi_* it very often infers S_AXI, clk and rst_n by itself. If it
#   did, calling ipx::add_bus_interface with the same name creates "clk1"/"S_AXI1"
#   or errors out -- and the failure is confusing because the design then has two
#   candidate interfaces. So: fetch if it exists, add only if it does not.
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

# ★ Bus parameters are their own objects, NOT properties of the bus interface.
#   `set_property -dict [list ASSOCIATED_BUSIF ...] $busif` dies with
#     ERROR: Unknown property 'ASSOCIATED_BUSIF' on bus_interface
#   in Vivado 2024.1 (found 2026-10-18). The supported API is
#     ipx::add_bus_parameter <name> $busif ; set_property value <v> <param>
proc bparam {b name value} {
    set l [ipx::get_bus_parameters $name -of_objects $b -quiet]
    if {[llength $l] == 0} {
        ipx::add_bus_parameter $name $b
        set l [ipx::get_bus_parameters $name -of_objects $b -quiet]
    }
    set_property value $value [lindex $l 0]
}

set clkif [bif $core clk]
set_property abstraction_type_vlnv xilinx.com:signal:clock_rtl:1.0 $clkif
set_property bus_type_vlnv         xilinx.com:signal:clock:1.0     $clkif
set_property interface_mode        slave                           $clkif
# NOTE: the inferred AXI interface is lower-case 's_axi' (it follows the port
#       prefix). Keep that name everywhere -- do not invent an upper-case S_AXI.
bparam $clkif ASSOCIATED_BUSIF s_axi
bparam $clkif ASSOCIATED_RESET rst_n
bparam $clkif FREQ_HZ          200000000
bparam $clkif PHASE            0.000
pmap $clkif CLK clk

set rstif [bif $core rst_n]
set_property abstraction_type_vlnv xilinx.com:signal:reset_rtl:1.0 $rstif
set_property bus_type_vlnv         xilinx.com:signal:reset:1.0     $rstif
set_property interface_mode        slave                           $rstif
# POLARITY is a bus parameter too (same trap as ASSOCIATED_BUSIF above).
bparam $rstif POLARITY ACTIVE_LOW
pmap $rstif RST rst_n

# ------------------------------------------------------------------- AXI4-Lite
set bifaxi [bif $core s_axi]
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

# The 17 AXI4-Lite signals. Logical name -> RTL port name.
set axi_map {
    AWADDR  s_axi_awaddr   AWVALID s_axi_awvalid  AWREADY s_axi_awready
    WDATA   s_axi_wdata    WSTRB   s_axi_wstrb    WVALID  s_axi_wvalid
    WREADY  s_axi_wready   BRESP   s_axi_bresp    BVALID  s_axi_bvalid
    BREADY  s_axi_bready   ARADDR  s_axi_araddr   ARVALID s_axi_arvalid
    ARREADY s_axi_arready  RDATA   s_axi_rdata    RRESP   s_axi_rresp
    RVALID  s_axi_rvalid   RREADY  s_axi_rready
}
foreach {logical phys} $axi_map { pmap $bifaxi $logical $phys }

# ---------------------------------------------------------------- memory map
# 128 bytes are actually decoded (C_S_AXI_ADDR_WIDTH = 7), but the address block
# is declared as 4K: the AXI interconnect maps whole 4K pages, and PYNQ derives
# the base address from this block. Declaring 128 would be technically true and
# practically annoying.
# The packager already inferred memory map 's_axi' with address block 'reg0'.
# Reuse them (names are lower-case); creating fresh ones would duplicate the map.
set mml [ipx::get_memory_maps s_axi -of_objects $core -quiet]
if {[llength $mml] == 0} {
    set mmap [ipx::add_memory_map s_axi $core]
} else {
    set mmap [lindex $mml 0]
}
set_property slave_memory_map_ref s_axi $bifaxi
set abll [ipx::get_address_blocks reg0 -of_objects $mmap -quiet]
if {[llength $abll] == 0} {
    set ablk [ipx::add_address_block reg0 $mmap]
} else {
    set ablk [lindex $abll 0]
}
set_property range {4K}  $ablk
set_property width {32}  $ablk

ipx::create_xgui_files  $core
ipx::update_checksums   $core
ipx::save_core          $core
close_project
puts "      IP written to $ip_repo"

# =============================================================================
# 2. Real project + block design
# =============================================================================
puts "\n\[2/6\] creating project and block design ..."

create_project $prj_name "$bld_dir/$prj_name" -part $part_name -force
set_property board_part $board_part [current_project]
set_property ip_repo_paths $ip_repo  [current_project]
update_ip_catalog -rebuild

create_bd_design "ts_bd"

# --- PS7 with the PYNQ-Z2 board preset --------------------------------------
create_bd_cell -type ip -vlnv xilinx.com:ip:processing_system7:5.5 ps7
apply_bd_automation -rule xilinx.com:bd_rule:processing_system7 \
    -config {make_external "FIXED_IO, DDR" apply_board_preset "1"} [get_bd_cells ps7]

# --- THE design decision: FCLK_CLK0 = 200 MHz -------------------------------
# One clock for the counter, the tau registers and the AXI slave => no CDC.
# Zynq-7000 FCLK range is 0.1-250 MHz (UG585), so 200 is legal. The PS7 PLL
# re-solves automatically (33.333 MHz x 60 / 10 = 200 MHz).
set_property -dict [list \
    CONFIG.PCW_FPGA0_PERIPHERAL_FREQMHZ {200} \
    CONFIG.PCW_EN_CLK0_PORT              {1}   \
    CONFIG.PCW_EN_RST0_PORT              {1}   \
    CONFIG.PCW_USE_M_AXI_GP0             {1}   \
] [get_bd_cells ps7]

# --- ts_top ------------------------------------------------------------------
create_bd_cell -type ip -vlnv user.org:user:ts_top:1.0 ts_top_0

# Wire M_AXI_GP0 -> ts_top/S_AXI. The automation inserts the AXI interconnect,
# the proc_sys_reset and the clock connection, and connects clk to FCLK_CLK0.
apply_bd_automation -rule xilinx.com:bd_rule:axi4 \
    -config {Master "/ps7/M_AXI_GP0" Clk "Auto" ProcSysReset "Auto"} \
    [get_bd_intf_pins ts_top_0/s_axi]

# --- tie off the external sample strobes -------------------------------------
# Nothing drives s_valid yet: the SRC register is written to 0xF at run time so
# all four modalities use the internal strobe generator (rtl/strobe_gen.v).
create_bd_cell -type ip -vlnv xilinx.com:ip:xlconstant:1.1 const_svalid
set_property -dict [list CONFIG.CONST_WIDTH {4} CONFIG.CONST_VAL {0}] [get_bd_cells const_svalid]
connect_bd_net [get_bd_pins const_svalid/dout] [get_bd_pins ts_top_0/s_valid]

# --- debug LEDs ---------------------------------------------------------------
# Port name must stay exactly 'dbg_led' -- constr/pynq_z2_ts.xdc constrains
# dbg_led[0..3] by that name.
create_bd_port -dir O -from 3 -to 0 dbg_led
connect_bd_net [get_bd_pins ts_top_0/dbg_led] [get_bd_ports dbg_led]

# NOTE: ts_top's m_valid / m_mod / m_ts (the tau-compensated timestamps feeding
# the feature extractor) have no consumer yet, so they will show up as
# unconnected-output warnings. That is expected at this stage -- the point of
# this first bitstream is the timestamp + tau path and its readout, not the
# downstream extractor.

regenerate_bd_layout
validate_bd_design
save_bd_design

# =============================================================================
# 3. Wrapper + constraints
# =============================================================================
puts "\n\[3/6\] wrapper and constraints ..."

set bd_file [get_files "$bld_dir/$prj_name/$prj_name.srcs/sources_1/bd/ts_bd/ts_bd.bd"]
make_wrapper -files $bd_file -top
add_files -norecurse "$bld_dir/$prj_name/$prj_name.gen/sources_1/bd/ts_bd/hdl/ts_bd_wrapper.v"
set_property top ts_bd_wrapper [current_fileset]
update_compile_order -fileset sources_1

add_files -fileset constrs_1 -norecurse "$con_dir/pynq_z2_ts.xdc"

# =============================================================================
# 4. Build
# =============================================================================
puts "\n\[4/6\] synthesis / implementation / bitstream ..."


# =============================================================================
# 3b. E4 GUARD -- the BD must synthesise the eps-aware ts_top
#
#   Vivado copies an IP's sources into <prj>.gen/.../ipshared/<hash>/src/ and
#   synthesises THAT copy, not ip_repo.  A stale ipshared directory therefore
#   produces a correct-looking bitstream that silently lacks the eps registers;
#   the only symptom is a 0x70 read returning 0 on the board.  Assert here, so
#   a stale copy costs seconds instead of a 20 minute build plus a burn.
# =============================================================================
generate_target all [get_files $bd_file]
set eps_hits  0
set eps_files [glob -nocomplain "$bld_dir/$prj_name/$prj_name.gen/sources_1/bd/ts_bd/ipshared/*/src/ts_top.v"]
foreach f $eps_files {
    set fh [open $f r]
    set txt [read $fh]
    close $fh
    incr eps_hits [llength [regexp -all -inline {eps_r} $txt]]
}
puts "      E4 guard: eps_r in the BD ipshared ts_top.v = $eps_hits ([llength $eps_files] file(s))"
if {$eps_hits < 1} {
    error "STALE IP SOURCE: the BD ipshared ts_top.v has no eps_r. Refusing to build."
}

# -jobs 2, not 8. The 15:46 run spawned 4 impl workers at ~640 MB each on top of
# a 1.1 GB parent (~3.6 GB total) and pushed free memory to 288 MB, which tripped
# the training queue's low-memory guard and cost one fold. This design is small;
# 2 jobs costs a few minutes and keeps the peak under ~1.5 GB.
launch_runs impl_1 -to_step write_bitstream -jobs 2
wait_on_run impl_1

set st [get_property STATUS [get_runs impl_1]]
puts "      impl_1 status: $st"
if {[string first "Complete" $st] < 0} {
    error "impl_1 did not complete (status: $st). Check the run log."
}

# =============================================================================
# 5. Export: .bit + .hwh with the SAME base name
# =============================================================================
puts "\n\[5/6\] exporting ts.bit and ts.hwh ..."

open_run impl_1

# ★ Timing sign-off gate. "write_bitstream Complete" only means a bit file was
#   produced -- not that the design meets 200 MHz. 2026-10-18: the first run
#   completed with WNS=-1.256 ns / 605 failing endpoints and still exported a
#   .bit. A bitstream with negative slack is not acceptable for the board.
set wns [get_property SLACK [get_timing_paths -delay_type max -max_paths 1 -nworst 1]]
set whs [get_property SLACK [get_timing_paths -delay_type min -max_paths 1 -nworst 1]]
puts [format "      WNS = %.3f ns   WHS = %.3f ns" $wns $whs]
if {$wns < 0 || $whs < 0} {
    error "Timing not met: WNS=$wns ns, WHS=$whs ns. Refusing to export ts.bit."
}

set bit_src "$bld_dir/$prj_name/$prj_name.runs/impl_1/ts_bd_wrapper.bit"
file copy -force $bit_src "$bld_dir/ts_e4.bit"
# PYNQ finds the hardware description by matching the .bit's base name.
write_hwdef -force "$bld_dir/ts_e4.hwh"

# =============================================================================
# 6. Report
# =============================================================================
puts "\n\[6/6\] done."
puts "=============================================================="
foreach f {ts_e4.bit ts_e4.hwh} {
    set p "$bld_dir/$f"
    if {[file exists $p]} {
        puts [format "  %-8s %8.2f KB" $f [expr {[file size $p]/1024.0}]]
    } else {
        puts "  $f  MISSING"
    }
}
puts ""
puts "  Copy BOTH files to the board, same directory, same base name."
puts "  Timing summary:"
puts "=============================================================="
report_timing_summary -delay_type min_max -max_paths 5 -file "$bld_dir/timing_summary.rpt"
puts "  (full report: $bld_dir/timing_summary.rpt)"
