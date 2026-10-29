# =============================================================================
# pynq_z2_audio.xdc -- constraints for the ADAU1761 I2S timestamp path (B7/B8)
#
# Device : xc7z020clg400-1     Board part : tul.com.tw:pynq-z2:part0:1.0
# Vivado : 2024.1
#
# Pins are taken from the board file itself
#   .../XilinxBoardStore/boards/TUL/pynq-z2/A.0/part0_pins.xml
# and not from memory, because the audio header wiring differs between
# the PYNQ-Z1 and the PYNQ-Z2.
#
# -----------------------------------------------------------------------------
# THE ONE THING THAT MATTERS IN THIS FILE
#
# Everything in the design runs on the 200 MHz PS clock (clk_fpga_0).  The
# codec's BCLK and LRCLK come back from the ADAU1761 as free-running clocks
# whose phase relative to the 200 MHz clock is arbitrary and drifts.  They are
# therefore declared as their own clock domains and grouped as asynchronous
# with the system clock: the only paths that cross are the two-flop
# synchroniser in audio_cdc (marked ASYNC_REG) and the sample data word, which
# the BCLK domain holds stable for a full frame (20.8 us) before the 200 MHz
# domain samples it.
#
# ★ Do NOT "fix" this with a plain set_false_path on everything: the edge
#   detector in audio_cdc is a real, timed path inside clk_fpga_0.
# -----------------------------------------------------------------------------
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
# I2C address strapping: 00 = 0x3A, the PYNQ-Z2 default.  Driven, not left
# floating, so that a later I2C bring-up does not have to guess the address.
set_property -dict {PACKAGE_PIN M17 IOSTANDARD LVCMOS33} [get_ports {audio_adr[0]}]
set_property -dict {PACKAGE_PIN M18 IOSTANDARD LVCMOS33} [get_ports {audio_adr[1]}]

# --- debug LEDs ------------------------------------------------------------
# Same mapping as pynq_z2_ts.xdc: LD0 run, LD1 FIFO empty, LD2 FIFO full,
# LD3 samples lost (sticky).  SRC reset value is 0, so channel 0 is fed by the
# external s_valid pin -- i.e. by the codec.  With the codec streaming,
# LD3 dark and LD1 toggling is enough to see at a glance that frames arrive.
set_property -dict {PACKAGE_PIN R14 IOSTANDARD LVCMOS33} [get_ports {dbg_led[0]}]
set_property -dict {PACKAGE_PIN P14 IOSTANDARD LVCMOS33} [get_ports {dbg_led[1]}]
set_property -dict {PACKAGE_PIN N16 IOSTANDARD LVCMOS33} [get_ports {dbg_led[2]}]
set_property -dict {PACKAGE_PIN M14 IOSTANDARD LVCMOS33} [get_ports {dbg_led[3]}]

# --- clocks ----------------------------------------------------------------
# BCLK = 64 * 48 kHz = 3.072 MHz.  LRCLK is DATA relative to BCLK (it changes
# on a BCLK edge), so it is not declared as a clock of its own.
create_clock -name bclk -period 325.520 [get_ports bclk]

# The codec launches both edges off the same MCLK we give it, but the PL-side
# input delay is not specified by the datasheet push-pull timing in a way we
# can bound here; 10 ns of board + package skew is a deliberately pessimistic
# number for a 3.072 MHz clock and is enough to prove the synchroniser input
# is not a timing risk.
set_input_delay -clock bclk -max 10.0 [get_ports {lrclk sd}]
set_input_delay -clock bclk -min  0.0 [get_ports {lrclk sd}]
set_input_delay -clock bclk -max 10.0 [get_ports {lrclk sd}] -clock_fall -add_delay
set_input_delay -clock bclk -min  0.0 [get_ports {lrclk sd}] -clock_fall -add_delay

# The PL clock name is produced by the block design (PS7 FCLK_CLK0 at 200 MHz),
# and it does not exist yet when this file is parsed during synthesis -- the
# guard below therefore always failed and the bclk -> clk_fpga_0 path reached
# implementation untimed, which is where the -2.191 ns violation came from
# (2026-10-20).  The async bound is now applied from build_audio_impl.tcl,
# *after* `open_run synth_1`, where both clocks exist:
#     set_max_delay -datapath_only -from [get_clocks bclk] \
#                   -to [get_clocks *clk_fpga_0*] 5.0   (and the reverse)
# A clock-group claim was deliberately not used: max_delay -datapath_only keeps
# the synchroniser path timed (it must be shorter than one destination period)
# instead of declaring it don't-care.

# audio_clk is an OUTPUT clock (MMCM -> pin).  It has no PL-side setup/hold
# relationship to anything, so it is intentionally left unconstrained; adding
# a create_clock on an output pin is a common way to invent a false failure.
