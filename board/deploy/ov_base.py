# -*- coding: utf-8 -*-
"""ov_base.py -- load TUL's reference overlay and let PYNQ's own audio driver
talk to the ADAU1761.

If the vendor bitstream plus the vendor driver cannot reach the codec either,
the fault is in the board's audio section, not in our AXI IIC setup.
Nothing here touches 0x4160_0000, so a half-loaded overlay cannot hang the PS.

    python3 -u ov_base.py
"""
import traceback

print("step 1: load base overlay", flush=True)
from pynq.overlays.base import BaseOverlay     # noqa: E402

ol = BaseOverlay("base.bit")
keys = sorted(ol.ip_dict)
print("ip_dict:", keys, flush=True)
aud = [k for k in keys if "aud" in k.lower() or "iic" in k.lower()]
print("audio-ish ips:", aud, flush=True)

bufs = [k for k in keys if "buffer" in k.lower() or "dma" in k.lower()]
print("dma-ish ips:", bufs, flush=True)

print("\nstep 2: PYNQ audio driver", flush=True)
try:
    from pynq.lib.audio import Audio
    a = Audio(0)
    print("Audio() OK ->", a, flush=True)
    print("  info:", a.info(), flush=True)
except Exception:
    traceback.print_exc()

print("\nstep 3: raw IIC probes with the vendor driver", flush=True)
try:
    from pynq.lib.iic import AxiIIC
    for name in aud:
        if "iic" in name.lower() or "i2c" in name.lower():
            dev = getattr(ol, name)
            print("  %s at %s" % (name, hex(dev.mmio.base_addr)), flush=True)
            for adr in (0x3A, 0x3B):
                buf = bytearray([0x40, 0x00, 0x00])
                try:
                    n = dev.send(adr, buf, 3)
                    print("    0x%02X send -> %d" % (adr, n), flush=True)
                except Exception as e:             # noqa: BLE001
                    print("    0x%02X send raised %s" % (adr, e), flush=True)
except Exception:
    traceback.print_exc()

print("OV_BASE_DONE", flush=True)
