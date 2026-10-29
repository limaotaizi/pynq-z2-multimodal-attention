"""pynq_probe -- validate what is in the FPGA before you trust what it prints.

Three offline modules, one board module:

    hwh.load(path)              parse a .hwh or .xsa: what IP, at what address
    regmap.load / validate      check a register-map spec against that parse
    capture.compare(got, want)  bit-exact verdict on a captured word block
    overlay.Board               board access, gated on an identity-register match

Nothing here imports `pynq` until you ask for a board, so the whole package runs
on a laptop and in CI.

Command line:

    python -m pynq_probe hwh    all_bd.hwh
    python -m pynq_probe check  all_bd.hwh --spec regmap.json
    python -m pynq_probe ident  all_bd.hwh --spec regmap.json
    python -m pynq_probe cmp    golden.mem captured.txt
"""

from . import capture, hwh, regmap  # noqa: F401

__all__ = ["capture", "hwh", "regmap"]
__version__ = "2.0"
