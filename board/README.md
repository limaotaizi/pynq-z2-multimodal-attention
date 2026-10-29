# Board software

Three layers, in the order you would normally use them.

## 1. Bare metal (no OS, no host in the loop)

`baremetal/` runs the attention engine from an SD card with nothing but the
PS on the other side. This is the configuration behind the 21.650 ms
one-window figure — it is the only number in the report that has no host
overhead in it.

| File | Role |
|---|---|
| `src/main.c` | one window: load input, start the engine, poll `done`, write out |
| `src/golden_m4.h` | 28 arrays / 5,504 words of expected output, compiled in |
| `build_platform.tcl` | Vitis platform + BSP (xsct) |
| `build_elf.ps1` | compiles `main.c` directly with the BSP toolchain, bypassing the Vitis IDE |
| `build_bootbin.ps1` | FSBL + bitstream + ELF → `BOOT.BIN` (bootgen) |
| `run_jtag.tcl` | reload a new ELF over JTAG without touching the SD card |

Why `build_elf.ps1` exists: `xsct` hangs at `app create` / `app build` on this
machine (reproduced three times; the IDE process spins with `XILINX_VITIS` empty
and a microblaze path on `PATH`). It assembles the same gcc command line the IDE
would have. The resulting ELF links against the same `libxil.a` from the
generated BSP, so it is the same binary, not a parallel build.

### Generated artefacts that are not in git

`ws/attn4_plat/...` (platform, BSP, `fsbl.elf`), `ws/attn_m4/...` and the
bitstream are all build outputs. Build them in this order:

```powershell
xsct build_platform.tcl                 # or open the platform in the Vitis GUI
powershell -File build_elf.ps1
$env:ATTN_BIT = 'C:\path\to\attn4_e4.bit'   # see BITSTREAM_MANIFEST.md for the md5
powershell -File build_bootbin.ps1
```

## 2. Serial helpers

| File | Role |
|---|---|
| `bm_ports.ps1` | lists non-Bluetooth COM ports — run this first |
| `bm_serial.ps1` | open a port, send keys, capture output |
| `bm_capture_boot.ps1` | start listening, then power the board on |
| `bm_capture_cold.ps1` | capture a full cold boot, including the unplug/replug |
| `bm_repeat.ps1` | one command re-verification: `r`×N bit-exact rounds + `t`×M timed samples, writes `repeat.json` and exits non-zero on any failure |

The port is **not** hardcoded. `bm_ports.ps1` prints the candidates; set
`$env:BM_PORT` to the one you want and the other scripts use it. The scripts
still accept an explicit `-Port` argument.

## 3. PYNQ Linux drivers (`deploy/`)

Python, running on the board under the stock PYNQ image. `attn_driver.py` maps
the AXI window, `ts_driver.py` reads the timestamp registers, `m4_map.py` holds
the scratch-RAM layout shared with `src/model/export.py`.

There is a deliberate duplication here: `deploy/` has its own copy of the layout
constants. They are checked against `export.py` by `src/model/check_npz_vs_mem.py`.
If they disagree, the model is right and the driver is stale.

## 4. CPU baseline (`baseline/`)

The same-board denominator for the PL engine: the Cortex-A9 executes the *same*
instruction stream, over the same weights and the same 8,192-word scratch, and
lands bit-exact on the same `exp_*.mem` vectors — 7.470 ms on the A9 against
20.790 ms on the PL, i.e. **2.78× in favour of the A9**. The PL needs 2.33× fewer
cycles but runs at a 6.5× lower clock, and loses the wall-clock comparison. It is
a scalar interpreter (`-O2`, no NEON, single-threaded), so read that factor as a
floor for the CPU's lead. Method, caveats and the three RTL details it had to
reproduce are in `baseline/README.md`.

```powershell
python -I -X utf8 baseline/gen_cpu_ref.py             # sim/vectors/m4/*.mem -> C tables
powershell -File baseline/build_cpu_ref.ps1 -Ws <ws>  # link against the same BSP
```

## Recorded runs

| File | What it is |
|---|---|
| `port.txt` | the port / JTAG idcode actually seen on this board (COM8, FT2232H, 0x23727093) |
| `repeat.json` | machine-readable result of the last `bm_repeat.ps1` run (per-round checks + latency statistics) |
| `baremetal/logs/` | raw UART captures, one file per run |
| `baseline/logs/` | raw capture of the CPU baseline run |
