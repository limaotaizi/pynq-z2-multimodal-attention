# -*- coding: utf-8 -*-
"""bit2bin.py -- convert a Xilinx .bit to the byte-swapped raw .bin that this
kernel's fpga_manager accepts ("Bitstream must be a byte swapped .bin file").

We look for the bitstream sync word 0xAA995566, keep everything from there, and
swap the bytes inside every 32-bit word.
"""
import struct
import sys

src = sys.argv[1]
dst = sys.argv[2]
d = open(src, "rb").read()

i = d.find(b"\xaa\x99\x55\x66")          # sync word as stored in a .bit
swapped = False
if i < 0:
    i = d.find(b"\x66\x55\x99\xaa")
    swapped = True
if i < 0:
    print("no sync word found")
    sys.exit(1)
print("sync at 0x%X (%s order), %d bytes payload" % (i, "swapped" if swapped else "big", len(d) - i))

pay = d[i:]
pay = pay[: len(pay) // 4 * 4]
n = len(pay) // 4
words = struct.unpack(">%dI" % n, pay)
out = struct.pack("<%dI" % n, *words)
open(dst, "wb").write(out)
print("wrote %s (%d bytes)" % (dst, len(out)))
