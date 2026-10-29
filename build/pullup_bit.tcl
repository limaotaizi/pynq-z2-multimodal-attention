# =============================================================================
# pullup_bit.tcl -- rebuild the audio bitstream with the FPGA's weak pull-ups
#                   enabled on the two I2C pads, nothing else changed.
#
#   The AXI IIC generates a START, then loses arbitration on the first address
#   bit that has to be a 1: the RTL raises arb_lost exactly when it is driving
#   SDA high and samples it low.  Xilinx's own libiic.so fails the same way,
#   and 40 recovery clocks change nothing, so the pad is not being released by
#   a confused slave -- the net simply cannot rise.
#
#   Two candidates: no pull-up on the net at all, or the ADAU1761 clamping it
#   (an unpowered codec clamps through its ESD diodes).  A weak on-chip
#   pull-up separates them: it is far too weak to run I2C at 100 kHz, but it
#   is plenty to make a static read return 1.  So
#       - ARB_LOST goes away, NACKs appear   -> net is free, pull-up missing
#       - ARB_LOST stays                     -> net is clamped low
#
#   This opens the routed checkpoint instead of re-running the whole flow, so
#   it costs a bitgen, not a place and route.
#
#   ASCII ONLY.
# =============================================================================
set root [file normalize [file dirname [info script]]]
set dcp  "$root/build_audio/audio_routed.dcp"
set bit  "$root/build_audio/audio_pullup.bit"

puts "=============================================================="
puts " pullup_bit.tcl"
puts "=============================================================="
open_checkpoint $dcp

foreach p {audio_i2c_sda_io audio_i2c_scl_io} {
    set port [get_ports -quiet $p]
    if {[llength $port] == 0} { puts "  port $p NOT FOUND" ; continue }
    puts "  port $p : [get_property IOSTANDARD $port] pull=[get_property PULLTYPE $port]"
    if {[catch { set_property PULLTYPE PULLUP $port } m]} { puts "    PULLTYPE failed: $m" }
    if {[catch { set_property PULLUP TRUE     $port } m]} { puts "    PULLUP failed: $m" }
    puts "    -> [get_property PULLTYPE $port]"
}

foreach c {audio_i2c_sda_iobuf audio_i2c_scl_iobuf} {
    set cell [get_cells -quiet $c]
    if {[llength $cell] == 0} { puts "  cell $c NOT FOUND" ; continue }
    if {[catch { set_property PULLTYPE PULLUP $cell } m]} { puts "    cell $c: $m" }
    puts "  cell $c -> [get_property PULLTYPE $cell]"
}

write_bitstream -force $bit
puts " bitstream: $bit"
puts "PULLUP_DONE"
exit 0
