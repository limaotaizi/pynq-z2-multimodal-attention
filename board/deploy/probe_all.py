# -*- coding: utf-8 -*-
"""probe_all.py -- acceptance probe for the three-slave BD (A1).

Each window is identified by a constant it must return, not by "it answers":
    attn  0x40000000 + 0x08 -> ID      0x41540001
    ts    0x40010000 + 0x08 -> T_NOW_L free-running 200 MHz counter
    eeg   0x40020000 + 0x20 -> BUILD   0x5EED0001
    eeg   0x40020000 + 0x24 -> GEOM    0x003E0500  (NCH=62, NB=5)

Every address is fsync'ed to /home/xilinx/sys/probe_all.log *before* it is
touched, because a stalled AXI read cannot be interrupted: after a hang the log
still names the window that has no slave.

Run only after boot.py has finished -- it loads base.bit at t = 118 s through
the kernel fpga_manager and replaces whatever JTAG programmed.
"""
import mmap
import os
import struct

LOG = "/home/xilinx/sys/probe_all.log"
_f = open(LOG, "w", buffering=1)
bad = 0


def say(m):
    _f.write(m + "\n")
    _f.flush()
    os.fsync(_f.fileno())


def m32(base):
    fd = open("/dev/mem", "r+b", buffering=0)
    return mmap.mmap(fd.fileno(), 0x1000, mmap.MAP_SHARED,
                     mmap.PROT_READ | mmap.PROT_WRITE, offset=base)


def rd(base, off):
    say("  read 0x%08X+0x%02X" % (base, off))
    return struct.unpack_from("<I", m32(base), off)[0]


def wr(base, off, val):
    say("  write 0x%08X+0x%02X <= 0x%08X" % (base, off, val))
    struct.pack_into("<I", m32(base), off, val & 0xFFFFFFFF)


def expect(name, got, want):
    global bad
    ok = got == want
    say("%s %-14s = 0x%08X  want 0x%08X" % ("PASS" if ok else "FAIL",
                                             name, got, want))
    if not ok:
        bad += 1


say("== attn_axi @ 0x40000000")
expect("attn ID", rd(0x40000000, 0x08), 0x41540001)

say("== ts_top @ 0x40010000")
# T_NOW only advances while CTRL[0] (run) is set -- ts_top gates the whole
# counter on it, so reading first and starting later always shows a stuck 0.
wr(0x40010000, 0x00, 0x01)               # CTRL = run
expect("ts  STATUS.run", rd(0x40010000, 0x04) & 0x4, 0x4)
a = rd(0x40010000, 0x08)                 # T_NOW_L
b = rd(0x40010000, 0x08)
if a != b:
    say("PASS ts  counter     0x%08X -> 0x%08X (running, +%d)"
        % (a, b, (b - a) & 0xFFFFFFFF))
else:
    say("FAIL ts  counter     stuck at 0x%08X" % a)
    bad += 1
expect("ts  ENQ(0)", rd(0x40010000, 0x14), 0)

say("== eeg_fe_top @ 0x40020000")
expect("eeg BUILD", rd(0x40020000, 0x20), 0x5EED0001)
expect("eeg GEOM", rd(0x40020000, 0x24), 0x003E0500)

say("PROBE_ALL_%s" % ("OK" if bad == 0 else "FAIL %d" % bad))
