#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Turn the M=4 RTL vectors into C tables for the A9 reference run.

The point of this script is that it does NOT re-derive anything. It reads the
exact files the RTL `$readmemh`s and writes them out as C arrays, so the A9
program executes *the same instruction stream over the same data* as the
bitstream. Bit-exact agreement is then a property of implementing each opcode
correctly, not of re-quantising a model and hoping it lands on the same values.

Inputs (all committed under sim/vectors/m4/):
    w_i8.mem bias.mem desc.mem pe.mem delta.mem exp_lut.mem kc.mem
    instr.mem in.mem
    exp_hre.mem exp_h.mem exp_z{e,o,a,s}.mem
    exp_{q,k,v,z0}L_{e,o,a,s}.mem

Output: build/cpu_ref_data.h  (gitignored -- regenerate with this script)

Usage:
    python -I -X utf8 gen_cpu_ref.py [--vec DIR] [--out FILE]
"""
import argparse
import os

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))
DEFAULT_VEC = os.path.join(ROOT, "sim", "vectors", "m4")
DEFAULT_OUT = os.path.join(HERE, "build", "cpu_ref_data.h")

# The instruction word, as laid out by src/model/export.py's enc():
#   [3:0]op [16:4]A [29:17]B [46:30]W [59:47]C [72:60]D [78:73]N [84:79]O
#   [93:85]K [108:94]M [114:109]SH [123:115]SS [132:124]DS [147:133]AM [153:148]ASH
FIELDS = [
    ("op", 4, 0), ("A", 13, 4), ("B", 13, 17), ("W", 17, 30), ("C", 13, 47),
    ("D", 13, 60), ("N", 6, 73), ("O", 6, 79), ("K", 9, 85), ("M", 15, 94),
    ("SH", 6, 109), ("SS", 9, 115), ("DS", 9, 124), ("AM", 15, 133),
    ("ASH", 6, 148),
]

OP_GEMM, OP_LDS, OP_PE, OP_ATTN, OP_RESGAP, OP_CPY = 1, 2, 3, 4, 5, 6
MODS = ["e", "o", "a", "s"]
T, D, G, U = 4, 16, 16, 12


def hexwords(path):
    vals = []
    with open(path, "r") as f:
        for line in f:
            t = line.strip()
            if not t or t.startswith("//"):
                continue
            for tok in t.split():
                if tok.startswith("//") or tok.startswith("@"):
                    break
                vals.append(int(tok, 16))
    return vals


def s16(v):
    v &= 0xFFFF
    return v - 0x10000 if v >= 0x8000 else v


def s8(v):
    v &= 0xFF
    return v - 0x100 if v >= 0x80 else v


def carr(name, ctype, values, fmt):
    body = ",\n    ".join(
        ", ".join(fmt % v for v in values[i:i + 16])
        for i in range(0, len(values), 16))
    return "static const %s %s[%d] = {\n    %s\n};\n" % (
        ctype, name, len(values), body)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--vec", default=DEFAULT_VEC)
    ap.add_argument("--out", default=DEFAULT_OUT)
    a = ap.parse_args()
    v = a.vec

    def P(n):
        return os.path.join(v, n)

    # ---- what the bitstream reads -----------------------------------------
    w = [s8(x) for x in hexwords(P("w_i8.mem"))]
    bias = [s16(x) for x in hexwords(P("bias.mem"))]
    pe = [s16(x) for x in hexwords(P("pe.mem"))]
    delta = [s16(x) for x in hexwords(P("delta.mem"))]
    lut = [x & 0xFF for x in hexwords(P("exp_lut.mem"))]
    kc = hexwords(P("kc.mem"))[0]
    inp = [s16(x) for x in hexwords(P("in.mem"))]

    # desc.mem: one 16-hex-digit line per block = M[15:0] SH[15:0] b_base w_base
    desc = []
    with open(P("desc.mem")) as f:
        for line in f:
            t = line.strip()
            if not t:
                continue
            x = int(t, 16)
            desc.append(((x >> 48) & 0xFFFF, (x >> 32) & 0xFFFF,
                         (x >> 16) & 0xFFFF, x & 0xFFFF))

    ins = []
    with open(P("instr.mem")) as f:
        for line in f:
            t = line.strip()
            if not t:
                continue
            x = int(t, 16)
            ins.append({n: (x >> sh) & ((1 << wd) - 1) for (n, wd, sh) in FIELDS})

    # ---- addresses the checks need, taken from the instruction stream ------
    hre_base = next(i for i in ins if i["op"] == OP_GEMM)["B"]
    he_base = next(i for i in ins if i["op"] == OP_PE)["B"]

    rst = [i["B"] for i in ins if i["op"] == OP_RESGAP]
    if len(rst) != G * len(MODS):
        raise SystemExit("expected %d RESGAP, got %d" % (G * len(MODS), len(rst)))
    # execution order is  group -> modality, so index k is (group k//4, mods[k%4])
    zp_base = {}
    for k, b in enumerate(rst):
        zp_base[MODS[k % len(MODS)]] = b - (k // len(MODS)) * D

    attn_last = {}
    for i in ins:
        if i["op"] == OP_ATTN:
            attn_last[i["A"]] = i        # per-modality region; last write wins
    attn = {MODS[k]: i for k, i in enumerate(attn_last.values())}

    counts = {op: sum(1 for i in ins if i["op"] == op)
              for op in (OP_GEMM, OP_LDS, OP_PE, OP_ATTN, OP_RESGAP, OP_CPY)}

    # ---- goldens ----------------------------------------------------------
    hre = [s16(x) for x in hexwords(P("exp_hre.mem"))]
    he = [s16(x) for x in hexwords(P("exp_h.mem"))]
    gzp = {m: [s16(x) for x in hexwords(P("exp_z%s.mem" % m))] for m in MODS}
    gq = {m: [s16(x) for x in hexwords(P("exp_qL_%s.mem" % m))] for m in MODS}
    gk = {m: [s16(x) for x in hexwords(P("exp_kL_%s.mem" % m))] for m in MODS}
    gv = {m: [s16(x) for x in hexwords(P("exp_vL_%s.mem" % m))] for m in MODS}
    gz = {m: [s16(x) for x in hexwords(P("exp_z0L_%s.mem" % m))] for m in MODS}

    o = []
    o.append("/* generated by board/baseline/gen_cpu_ref.py -- do not edit */\n")
    o.append("#ifndef CPU_REF_DATA_H\n#define CPU_REF_DATA_H\n\n")
    o.append("typedef struct { unsigned short m, sh, bb, wb; } desc_t;\n")
    o.append("typedef struct { unsigned char op; unsigned short A, B, W, C, D;\n"
             "                 unsigned char N, O; unsigned short K, M, SS, DS;\n"
             "                 unsigned short AM; unsigned char SH, ASH; } ins_t;\n")
    o.append("typedef struct { const char *name; unsigned addr; unsigned len;\n"
             "                 const short *gold; } chk_t;\n\n")
    o.append("#define G_T %d\n#define G_D %d\n#define G_U %d\n#define G_G %d\n"
             % (T, D, U, G))
    o.append("#define N_INSTR %d\n" % len(ins))
    o.append("#define ADDR_IN %d\n#define ADDR_HRE %d\n#define ADDR_HE %d\n"
             % (0, hre_base, he_base))
    o.append("#define ADDR_ZP_E %d\n#define ADDR_ZP_O %d\n"
             "#define ADDR_ZP_A %d\n#define ADDR_ZP_S %d\n"
             % (zp_base["e"], zp_base["o"], zp_base["a"], zp_base["s"]))
    for m in MODS:
        o.append("#define ADDR_Q_%s %d\n#define ADDR_K_%s %d\n"
                 "#define ADDR_V_%s %d\n#define ADDR_Z_%s %d\n"
                 % (m.upper(), attn[m]["A"], m.upper(), attn[m]["B"],
                    m.upper(), attn[m]["W"], m.upper(), attn[m]["C"]))
    o.append("#define N_WEIGHTS %d\n#define N_BIAS %d\n#define N_DESC %d\n"
             % (len(w), len(bias), len(desc)))
    o.append("#define KC_CPU 0x%08x\n\n" % kc)

    o.append(carr("W_CPU", "signed char", w, "%d") + "\n")
    o.append(carr("B_CPU", "short", bias, "%d") + "\n")
    o.append(carr("PE_CPU", "short", pe, "%d") + "\n")
    o.append(carr("DELTA_CPU", "short", delta, "%d") + "\n")
    o.append(carr("LUT_CPU", "unsigned char", lut, "%d") + "\n")
    o.append(carr("IN_CPU", "short", inp, "%d") + "\n")

    o.append("static const desc_t DESC_CPU[N_DESC] = {\n    ")
    o.append(",\n    ".join("{%d, %d, %d, %d}" % d for d in desc))
    o.append("\n};\n\n")

    o.append("static const ins_t INS_CPU[N_INSTR] = {\n")
    for i in ins:
        o.append("    {%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d},\n" % (
            i["op"], i["A"], i["B"], i["W"], i["C"], i["D"], i["N"], i["O"],
            i["K"], i["M"], i["SS"], i["DS"], i["AM"], i["SH"], i["ASH"]))
    o.append("};\n\n")

    o.append(carr("GOLD_HRE", "short", hre, "%d") + "\n")
    o.append(carr("GOLD_HE", "short", he, "%d") + "\n")
    for m in MODS:
        o.append(carr("GOLD_ZP_%s" % m.upper(), "short", gzp[m], "%d"))
    for m in MODS:
        o.append(carr("GOLD_Q_%s" % m.upper(), "short", gq[m], "%d"))
        o.append(carr("GOLD_K_%s" % m.upper(), "short", gk[m], "%d"))
        o.append(carr("GOLD_V_%s" % m.upper(), "short", gv[m], "%d"))
        o.append(carr("GOLD_Z_%s" % m.upper(), "short", gz[m], "%d"))
    o.append("\n")

    o.append("static const chk_t CHECKS[] = {\n")
    o.append("    {\"hre\", ADDR_HRE, %d, GOLD_HRE},\n" % len(hre))
    o.append("    {\"he\",  ADDR_HE,  %d, GOLD_HE },\n" % len(he))
    for m in MODS:
        u = m.upper()
        o.append("    {\"zp%c\", ADDR_ZP_%s, %d, GOLD_ZP_%s},\n"
                 % (m, u, len(gzp[m]), u))
        o.append("    {\"q%c\",  ADDR_Q_%s,  %d, GOLD_Q_%s },\n"
                 % (m, u, len(gq[m]), u))
        o.append("    {\"k%c\",  ADDR_K_%s,  %d, GOLD_K_%s },\n"
                 % (m, u, len(gk[m]), u))
        o.append("    {\"v%c\",  ADDR_V_%s,  %d, GOLD_V_%s },\n"
                 % (m, u, len(gv[m]), u))
        o.append("    {\"z0%c\", ADDR_Z_%s,  %d, GOLD_Z_%s },\n"
                 % (m, u, len(gz[m]), u))
    o.append("};\n\n#define N_CHECKS %d\n\n#endif\n" %
             (2 + 5 * len(MODS)))

    os.makedirs(os.path.dirname(a.out), exist_ok=True)
    with open(a.out, "w", newline="\n") as f:
        f.write("".join(o))

    print("wrote %s" % a.out)
    print("  instr  %d (gemm %d, lds %d, pe %d, attn %d, resgap %d, cpy %d)" % (
        len(ins), counts[OP_GEMM], counts[OP_LDS], counts[OP_PE],
        counts[OP_ATTN], counts[OP_RESGAP], counts[OP_CPY]))
    print("  weights %d B, bias %d, desc %d, input %d words"
          % (len(w), len(bias), len(desc), len(inp)))
    print("  bases  HRE=%d HE=%d ZP=%s" % (hre_base, he_base, zp_base))
    print("  attn   " + " ".join("%s:q%d k%d v%d z%d" % (
        m, attn[m]["A"], attn[m]["B"], attn[m]["W"], attn[m]["C"]) for m in MODS))


if __name__ == "__main__":
    main()
