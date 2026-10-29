# Runs ON THE BOARD.  Convert a .bit into the byte-swapped .bin that
# fpga_manager accepts.  The only structural facts used are:
#   - the sync word AA 99 55 66 exists as a byte string
#   - the payload begins 8 bytes earlier (00 00 00 BB / 11 22 00 44 bus-width
#     auto-detect words)
#   - each 32-bit word is byte-reversed in the .bin
# Nothing here touches an AXI address, so a mistake costs a failed load, not a
# hung PS.
import sys

src = sys.argv[1] if len(sys.argv) > 1 else '/home/xilinx/pynq/overlays/base/base.bit'
dst = sys.argv[2] if len(sys.argv) > 2 else '/home/xilinx/sys/base3.bin'

d = open(src, 'rb').read()
i = d.find(b'\xaa\x99\x55\x66')
print('src=%s size=%d sync_at=%d' % (src, len(d), i))
if i < 8:
    raise SystemExit('MK_FAIL no sync word')

start = i - 8
pay = d[start:]
n = len(pay) - (len(pay) % 4)
pay = pay[:n]
out = bytearray(n)
for k in range(0, n, 4):
    out[k:k + 4] = pay[k:k + 4][::-1]

data = bytes(out)
with open(dst, 'wb') as f:
    f.write(data)
print('wrote %s %d bytes' % (dst, len(data)))
print('head %s' % data[:16].hex())
print('MK_OK')
