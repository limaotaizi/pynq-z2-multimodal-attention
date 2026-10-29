# =============================================================================
# pynq_z2_audio_bb.xdc -- constraints for build_audio_bb.tcl
#
# Device : xc7z020clg400-1     Board part : tul.com.tw:pynq-z2:part0:1.0
# Vivado : 2024.1
#
# Identical to pynq_z2_audio.xdc except for the two I2C pads.  Those were
# previously driven through the board automation's IIC interface (SDA_I/O/T
# triples); now they are single inout ports from i2c_bb, so they are pinned
# here by hand.
#
# Pins, verbatim from the board file
#   .../XilinxBoardStore/boards/TUL/pynq-z2/A.0/part0_pins.xml
#     107 audio_sd_i  T9
#     108 audio_sc_i  U9
#
# ★ PULLTYPE PULLUP on both.  Reason: the whole point of i2c_bb is to read the
#   line level back, and an un-driven pin with no pull would float and give a
#   meaningless reading.  The board also carries 4k7 pull-ups on this header,
#   so the internal weak pull is belt-and-braces, not the primary source --
#   and because it is weak (~50k), a device holding the line low still wins,
#   which is exactly what the ACK measurement needs.
#
# ASCII ONLY.
# =============================================================================

set_property CFGBVS VCCO       [current_design]
set_property CONFIG_VOLTAGE 3.3 [current_design]

# --- codec interface -------------------------------------------------------
# audio_clk is the MCLK the PL must supply; the ADAU1761 has no oscillator of
# its own on this board (board.xml declares audio_clock as an OUTPUT from the
# PL).  It is driven by clk_wiz in the block design.
set_property -dict {PACKAGE_PIN U5  IOSTANDARD LVCMOS33} [get_ports audio_clk]
set_property -dict {PACKAGE_PIN R18 IOSTANDARD LVCMOS33} [get_ports bclk]
set_property -dict {PACKAGE_PIN T17 IOSTANDARD LVCMOS33} [get_ports lrclk]
set_property -dict {PACKAGE_PIN F17 IOSTANDARD LVCMOS33} [get_ports sd]
# DAC data: not used by the timestamp path, held at 0 so the codec sees a
# defined level instead of a floating pin on the header.
set_property -dict {PACKAGE_PIN G18 IOSTANDARD LVCMOS33} [get_ports audio_dout]

# --- I2C pads (i2c_bb) -----------------------------------------------------
set_property -dict {PACKAGE_PIN T9 IOSTANDARD LVCMOS33 PULLTYPE PULLUP} [get_ports sda_io]
set_property -dict {PACKAGE_PIN U9 IOSTANDARD LVCMOS33 PULLTYPE PULLUP} [get_ports scl_io]

# --- I2C address strapping -------------------------------------------------
# ADDR1:ADDR0 -> 7-bit address  00=0x38  01=0x39  10=0x3A  11=0x3B
# (The previous revision of this comment said "00 = 0x3A"; that was wrong and
#  is why the first address probes only tried 0x38 and looked wrong.)
# Driven from an axi_gpio rather than tied, so the strobe can walk all four
# without a rebuild.
set_property -dict {PACKAGE_PIN M17 IOSTANDARD LVCMOS33} [get_ports {audio_adr[0]}]
set_property -dict {PACKAGE_PIN M18 IOSTANDARD LVCMOS33} [get_ports {audio_adr[1]}]

# --- debug LEDs ------------------------------------------------------------
set_property -dict {PACKAGE_PIN R14 IOSTANDARD LVCMOS33} [get_ports {dbg_led[0]}]
set_property -dict {PACKAGE_PIN P14 IOSTANDARD LVCMOS33} [get_ports {dbg_led[1]}]
set_property -dict {PACKAGE_PIN N16 IOSTANDARD LVCMOS33} [get_ports {dbg_led[2]}]
set_property -dict {PACKAGE_PIN M14 IOSTANDARD LVCMOS33} [get_ports {dbg_led[3]}]

# --- clocks ----------------------------------------------------------------
# BCLK = 64 * 48 kHz = 3.072 MHz.  LRCLK is DATA relative to BCLK (it changes
# on a BCLK edge), so it is not declared as a clock of its own.
create_clock -name bclk -period 325.520 [get_ports bclk]

set_input_delay -clock bclk -max 10.0 [get_ports {lrclk sd}]
set_input_delay -clock bclk -min  0.0 [get_ports {lrclk sd}]
set_input_delay -clock bclk -max 10.0 [get_ports {lrclk sd}] -clock_fall -add_delay
set_input_delay -clock bclk -min  0.0 [get_ports {lrclk sd}] -clock_fall -add_delay

# The PL clock name (PS7 FCLK_CLK0 at 200 MHz) does not exist while this file
# is parsed during synthesis, so the bclk <-> clk_fpga_0 bound is applied from
# build_audio_bb.tcl after `open_run synth_1`:
#     set_max_delay -datapath_only -from [get_clocks bclk] \
#                   -to [get_clocks *clk_fpga_0*] 5.0   (and the reverse)
