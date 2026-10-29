# -*- coding: utf-8 -*-
"""i2c_bb_lib.py -- software I2C master on top of the i2c_bb AXI4-Lite IP.

Register map (byte offsets from the IP base):
    0x00 CTRL      RW  [0]=SDA_OE [1]=SDA level [2]=SCL_OE [3]=SCL level
    0x04 STAT      RO  [0]=scl_i [1]=sda_i [2]=scl_i previous [3]=sda_i prev
                       [4]=scl_oe [5]=sda_oe

    The order above is what the synthesised RTL actually packs
    (stat_w = {sda_oe, scl_oe, sda_d1, scl_d1, sda_d2, scl_d2} puts scl_d2 in
    bit 0).  The RTL comment and the first version of this file both said the
    other way round, and every board reading taken before 2026-10-20 14:00 was
    therefore labelled backwards.
    0x08 SDA_EDGES RW  read = edges since last clear, write anything clears
    0x0C SCL_EDGES RW  same for SCL

Open-drain is emulated by OE=0 (high-Z, external/internal pull-up) for a logic
one and OE=1 level=0 for a logic zero.  Because the level can also be driven
*high* (OE=1 level=1), the same object can tell a pulled-up bus apart from a
clamped or unpopulated one.

Timing: every mmap write costs about 1 us on the PS, so a "busy wait" of n
reads adds roughly 2*n us.  Default delays give about 70-100 kHz, comfortably
inside the ADAU1761's 400 kHz limit and slow enough to be immune to the fact
that PYTHON timing is not deterministic.
"""

import mmap
import struct
import time

CTRL, STAT, SDA_EDGES, SCL_EDGES = 0x00, 0x04, 0x08, 0x0C


class BbI2C(object):
    def __init__(self, base=0x40001000, half_us=6.0, swap=False):
        self.base = base
        self.half = half_us
        # swap=True exchanges the two pads at this layer only: the logical SDA
        # is then driven on the pin the XDC calls scl_io and vice versa.  It
        # exists because "no device ACKs on any address" is also what you see
        # when the two lines are the other way round on the board, and the
        # idle levels (both pulled high) cannot tell the two cases apart.
        self.swap = swap
        page = base & ~0xFFF
        self.delta = base - page
        fd = open("/dev/mem", "r+b", buffering=0)
        self.m = mmap.mmap(fd.fileno(), 0x1000, mmap.MAP_SHARED,
                           mmap.PROT_READ | mmap.PROT_WRITE, offset=page)
        self.fd = fd
        # park the bus released (mirror defaults first, ctrl() updates them)
        self._sda_oe, self._sda_lvl, self._scl_oe, self._scl_lvl = 0, 1, 0, 1
        self.ctrl(0, 1, 0, 1)
        self.dly(2)

    # ---------------------------------------------------------------- plumbing
    def _wr(self, off, val):
        struct.pack_into("<I", self.m, self.delta + off, val & 0xFFFFFFFF)

    def _rd(self, off):
        return struct.unpack_from("<I", self.m, self.delta + off)[0]

    def dly(self, mult=1):
        t0 = time.time()
        while True:
            self._rd(STAT)
            if (time.time() - t0) * 1e6 >= self.half * mult:
                break

    # ------------------------------------------------------------- line control
    def ctrl(self, sda_oe, sda_lvl, scl_oe, scl_lvl):
        # keep the local mirror in step: _set() reads it for the fields it was
        # not given, so a ctrl() that skipped this would leave them undefined
        # and _set(sda_oe=...) would raise AttributeError on the SCL half.
        self._sda_oe, self._sda_lvl = sda_oe, sda_lvl
        self._scl_oe, self._scl_lvl = scl_oe, scl_lvl
        if self.swap:
            sda_oe, sda_lvl, scl_oe, scl_lvl = scl_oe, scl_lvl, sda_oe, sda_lvl
        self._wr(CTRL, (scl_lvl << 3) | (scl_oe << 2) |
                        (sda_lvl << 1) | sda_oe)

    def sda(self, low):
        """Drive SDA low, or release it to the pull-up."""
        self.ctrl(1 if low else 0, 0 if low else 1, self._scl_oe, self._scl_lvl)

    def scl(self, low):
        self.ctrl(self._sda_oe, self._sda_lvl, 1 if low else 0, 0 if low else 1)

    # current state is mirrored locally so a single line can be changed without
    # a read-modify-write round trip
    _sda_oe, _sda_lvl, _scl_oe, _scl_lvl = 0, 1, 0, 1

    def _set(self, sda_oe=None, sda_lvl=None, scl_oe=None, scl_lvl=None):
        if sda_oe is not None:
            self._sda_oe = sda_oe
        if sda_lvl is not None:
            self._sda_lvl = sda_lvl
        if scl_oe is not None:
            self._scl_oe = scl_oe
        if scl_lvl is not None:
            self._scl_lvl = scl_lvl
        self.ctrl(self._sda_oe, self._sda_lvl, self._scl_oe, self._scl_lvl)

    def sda_rel(self):
        self._set(sda_oe=0, sda_lvl=1)
        self.dly()

    def sda_low_d(self):
        self._set(sda_oe=1, sda_lvl=0)
        self.dly()

    def scl_rel(self):
        self._set(scl_oe=0, scl_lvl=1)
        self.dly()

    def scl_low_d(self):
        self._set(scl_oe=1, scl_lvl=0)
        self.dly()

    # --------------------------------------------------------------- readback
    def stat(self):
        v = self._rd(STAT)
        d = {"scl": (v >> 0) & 1, "sda": (v >> 1) & 1,
             "scl_p": (v >> 2) & 1, "sda_p": (v >> 3) & 1,
             "scl_oe": (v >> 4) & 1, "sda_oe": (v >> 5) & 1}
        if self.swap:
            d["scl"], d["sda"] = d["sda"], d["scl"]
            d["scl_p"], d["sda_p"] = d["sda_p"], d["scl_p"]
            d["scl_oe"], d["sda_oe"] = d["sda_oe"], d["scl_oe"]
        return d

    def sda_in(self):
        return self.stat()["sda"]

    def scl_in(self):
        return self.stat()["scl"]

    # ------------------------------------------------------------ bus protocol
    def start(self):
        self.sda_rel()
        self.scl_rel()
        self.sda_low_d()     # SDA falls while SCL high
        self.scl_low_d()     # pull SCL low to make room for the first bit

    def stop(self):
        self.sda_low_d()
        self.scl_rel()
        self.sda_rel()       # SDA rises while SCL high
        self.dly()

    def write_bit(self, bit):
        if bit:
            self._set(sda_oe=0, sda_lvl=1)
        else:
            self._set(sda_oe=1, sda_lvl=0)
        self.dly()
        self.scl_rel()
        self.dly()
        self.scl_low_d()

    def read_bit(self):
        self._set(sda_oe=0, sda_lvl=1)
        self.dly()
        self.scl_rel()
        self.dly()
        b = self.sda_in()
        self.scl_low_d()
        return b

    def write_byte(self, val):
        """Shift out 8 bits MSB first, then sample the ACK slot.
        Returns True if the slave pulled SDA low on the 9th clock."""
        for i in range(7, -1, -1):
            self.write_bit((val >> i) & 1)
        return self.read_bit() == 0     # ACK is a zero

    def read_byte(self, ack):
        v = 0
        for _ in range(8):
            v = (v << 1) | self.read_bit()
        self.write_bit(0 if ack else 1)  # ACK = drive low
        return v

    # ------------------------------------------------------------- transactions
    def probe(self, dev7):
        """Address-only probe. True = the device ACKed."""
        self.start()
        ack = self.write_byte((dev7 << 1) | 0)
        self.stop()
        return ack

    def scan(self, lo=0x08, hi=0x77):
        found = []
        for a in range(lo, hi + 1):
            if self.probe(a):
                found.append(a)
        return found

    def write_reg(self, dev7, reg16, val8):
        self.start()
        ok = self.write_byte((dev7 << 1) | 0)
        if not ok:
            self.stop()
            return False
        ok &= self.write_byte((reg16 >> 8) & 0xFF)
        ok &= self.write_byte(reg16 & 0xFF)
        ok &= self.write_byte(val8 & 0xFF)
        self.stop()
        return ok

    def read_reg(self, dev7, reg16):
        self.start()
        if not self.write_byte((dev7 << 1) | 0):
            self.stop()
            return None
        self.write_byte((reg16 >> 8) & 0xFF)
        self.write_byte(reg16 & 0xFF)
        self.start()
        if not self.write_byte((dev7 << 1) | 1):
            self.stop()
            return None
        v = self.read_byte(False)
        self.stop()
        return v
