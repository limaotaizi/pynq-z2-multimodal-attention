"""verify_bootbin.py -- 证明 BOOT.BIN 里装的就是那三份验收过的文件。

为什么必须核：
  BOOT.BIN 是二进制黑盒。"Bootimage generated successfully" 只说明 bootgen
  自己没出错，不说明里面装的是 attn4_e4.bit（逐位验收过、md5 1e2555…）
  还是导出时另外拼出来的另一份。把每个分区的实际镜像在 BOOT.BIN 里定位、
  整段比 md5，是唯一能证明"进卡的位流就是验收过的位流"的做法。

三个必须知道的格式事实（都是实测出来的，不是猜的）：
  1. .elf 分区不是整份 ELF 原样拷入，只取 PT_LOAD 段。所以先读程序头，
     拿到 (offset, filesz)，再拿那一段去找。
  2. .bit 分区会**丢掉 ASCII 头**。attn4_e4.bit 的头是 110 B。
  3. 丢掉头之后，位流按 32 bit 字**字节反序**存进 BOOT.BIN
     （.bit 里的 20 00 00 00 在 BOOT.BIN 里是 00 00 00 20）。
     这是 Zynq 引导镜像的位流字节序，不反序去找永远找不到。

用法：python -I -X utf8 verify_bootbin.py
退出码 0 = 三个分区全部逐字节一致。
"""
import hashlib
import os
import struct
import sys

BM = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(BM)

BOOT = os.path.join(BM, "BOOT.BIN")
FSBL = os.path.join(BM, "ws", "attn4_plat", "zynq_fsbl", "fsbl.elf")
BIT = os.path.join(ROOT, "build_bd_all", "attn4_e4.bit")
ELF = os.path.join(BM, "ws", "attn_m4", "Debug", "attn_m4.elf")

BIT_MD5_EXPECT = "1e2555571c380d8fbaa2324141023e6f"   # 逐位验收过的那份位流


def md5(b):
    return hashlib.md5(b).hexdigest()


def rev4(data):
    """每 4 字节一组做字节反序。用切片赋值，比逐组拼接快得多。"""
    n = len(data) & ~3
    out = bytearray(data[:n])
    out[0::4] = data[3:n:4]
    out[1::4] = data[2:n:4]
    out[2::4] = data[1:n:4]
    out[3::4] = data[0:n:4]
    return bytes(out)


def elf_loads(raw):
    """返回 (e_entry, [(file_off, filesz, vaddr, memsz), ...])，只保留 PT_LOAD。"""
    e_entry = struct.unpack_from("<I", raw, 0x18)[0]
    phoff = struct.unpack_from("<I", raw, 0x1C)[0]
    phentsize = struct.unpack_from("<H", raw, 0x2A)[0]
    phnum = struct.unpack_from("<H", raw, 0x2C)[0]
    segs = []
    for i in range(phnum):
        base = phoff + i * phentsize
        p_type, p_offset, p_vaddr, p_paddr, p_filesz, p_memsz = struct.unpack_from(
            "<6I", raw, base)
        if p_type == 1:
            segs.append((p_offset, p_filesz, p_vaddr, p_memsz))
    return e_entry, segs


def find_bit_payload(blob, raw):
    """在 BOOT.BIN 里定位位流 payload，返回 (头长, 偏移, 长度) 或 None。

    ★ 字反序的分组起点必须落在 payload 起点 S 上。若先固定一个 raw 内的
      偏移取探针，那个偏移未必与头长 H 同余 mod 4，分组就错开了 2 字节，
      探针变成乱码 —— 第一版就是这么失败的。所以这里按候选 H 分组取探针：
      H 就在一百来字节附近，通常前 200 次试探内命中，然后是整段 md5 校验，
      命中即为全段相等，不存在误判。
    """
    for H in range(0, 2048):
        n = len(raw) - H
        n4 = n & ~3
        if n4 <= 0:
            continue
        probe = rev4(raw[H:H + 64])
        if len(probe) < 64:
            continue
        want = (md5(rev4(raw[H:H + n4])), raw[H + n4:])
        o = blob.find(probe)
        while o >= 0:
            if o + n <= len(blob):
                seg = blob[o:o + n]
                if (md5(seg[:n4]), seg[n4:]) == want:
                    return H, o, n
            o = blob.find(probe, o + 1)
    return None


def main():
    import argparse
    ap = argparse.ArgumentParser()
    ap.add_argument("--boot", default=BOOT, help="BOOT.BIN to inspect; read-only")
    a = ap.parse_args()
    blob = open(a.boot, "rb").read()
    ok = []

    print("=" * 66)
    print(f"BOOT.BIN  {len(blob):,} B   md5 {md5(blob)}")
    print("=" * 66)

    # ---- 1. 位流 ------------------------------------------------------------
    raw = open(BIT, "rb").read()
    print("\n-- attn4_e4.bit")
    print(f"   源文件 {len(raw):,} B   md5 {md5(raw)}")
    if md5(raw) != BIT_MD5_EXPECT:
        print(f"   !! 源文件 md5 不是逐位验收过的那份（期望 {BIT_MD5_EXPECT}）")
        ok.append(False)
    hit = find_bit_payload(blob, raw)
    if hit is None:
        print("   !! BOOT.BIN 里找不到这份位流的 payload")
        ok.append(False)
    else:
        H, S, n = hit
        body = rev4(raw[H:H + n])
        print(f"   ASCII 头 {H} B（bootgen 丢掉），payload {n:,} B")
        print(f"   payload 按 32 bit 字字节反序后：")
        print(f"     源    md5 {md5(body)}")
        print(f"     BOOT  md5 {md5(blob[S:S + n])}   @0x{S:08X}")
        same = body == blob[S:S + n]
        print(f"   => {'逐字节一致（整段，非抽样）' if same else '!! 不一致'}")
        ok.append(same)

    # ---- 2. FSBL 与应用的 PT_LOAD ------------------------------------------
    for label, path in (("fsbl.elf", FSBL), ("attn_m4.elf", ELF)):
        raw = open(path, "rb").read()
        entry, segs = elf_loads(raw)
        print(f"\n-- {label}")
        print(f"   源文件 {len(raw):,} B   md5 {md5(raw)}   e_entry 0x{entry:08X}")
        for (fo, fsz, va, msz) in segs:
            img = raw[fo:fo + fsz]
            if fsz == 0:
                print(f"   PT_LOAD vaddr 0x{va:08X}  filesz 0 — 纯 .bss，无内容可比")
                continue
            o = blob.find(img[:64])
            same = o >= 0 and md5(blob[o:o + fsz]) == md5(img)
            print(f"   PT_LOAD vaddr 0x{va:08X}  {fsz:,} B  md5 {md5(img)}")
            print(f"     BOOT @0x{o:08X}   => "
                  f"{'逐字节一致' if same else '!! 找不到或不一致'}")
            ok.append(same)

    print("\n" + "=" * 66)
    good = all(ok)
    print(f"{sum(ok)}/{len(ok)} 个分区镜像逐字节一致  =>  "
          f"{'ALL PASS' if good else 'FAIL'}")
    print("=" * 66)
    return 0 if good else 1


if __name__ == "__main__":
    sys.exit(main())
