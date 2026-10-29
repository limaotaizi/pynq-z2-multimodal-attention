# =============================================================================
# build_bootbin.ps1 -- FSBL + bitstream + app  ->  BOOT.BIN
#
#   三个输入都按"文件名 + 大小 + mtime"打印出来：BOOT.BIN 只认这三份东西，
#   任何一份换了都会让板上行为变而没人知道，所以每次构建都把账摆出来。
#
#   Usage:  powershell -ExecutionPolicy Bypass -File build_bootbin.ps1
#   VERSION: Vitis 2024.1 的 bootgen
# =============================================================================
$ErrorActionPreference = 'Stop'

$bm   = $PSScriptRoot
$root = (Resolve-Path (Join-Path $bm '..')).Path

$fsbl = Join-Path $bm 'ws\attn4_plat\zynq_fsbl\fsbl.elf'
# 2026-10-29: the bitstream ships in the submission archive, not in git.
# Accept ATTN_BIT, else look next to this script, else the in-tree build output.
$bitCandidates = @()
if ($env:ATTN_BIT) { $bitCandidates += $env:ATTN_BIT }
$bitCandidates += (Join-Path $bm 'attn4_e4.bit')
$bitCandidates += (Join-Path $root 'build_bd_all\attn4_e4.bit')
$bit = $bitCandidates | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $bit) { throw 'attn4_e4.bit not found. Set ATTN_BIT, or copy it next to this script. BITSTREAM_MANIFEST.md has the md5 it must match.' }

$elfs = @(Get-ChildItem -Path (Join-Path $bm 'ws\attn_m4') -Recurse -Filter 'attn_m4.elf' -ErrorAction SilentlyContinue)
if ($elfs.Count -ne 1) {
    throw "expected exactly one attn_m4.elf under ws\attn_m4, found $($elfs.Count) -- run build_app.tcl first"
}
$elf = $elfs[0].FullName

foreach ($f in @($fsbl, $bit, $elf)) {
    if (-not (Test-Path $f)) { throw "missing: $f" }
}

Write-Host '--------------------------------------------------------------'
Write-Host ' BOOT.BIN inputs'
Write-Host '--------------------------------------------------------------'
foreach ($f in @($fsbl, $bit, $elf)) {
    $i = Get-Item $f
    Write-Host ("  {0,-62} {1,10:N0} B  {2}" -f $i.Name, $i.Length, $i.LastWriteTime)
}

# 展开成绝对路径的 BIF。bootgen 对相对路径的解析以 BIF 所在目录为基准，
# 所以模板里那几条相对路径只要 BIF 被搬到别处就会失效，这里一律写绝对路径。
#
#   ★ 第三个分区不加任何属性。写成 `<elf,ps7_cortexa9_0>xxx.elf` 会被 bootgen
#     直接拒掉（WARNING: bad character! '<'，然后 BootGen - syntax error）。
#     bootgen v2024.1 按扩展名识别分区类型：.elf 就是一个 ELF 分区，
#     默认交给 cpu0 起跳，并以 ELF 自己的 e_entry 作为入口 —— 正好是
#     lscript.ld 的 ENTRY(_vector_table) = 0x100000。
$bif = Join-Path $bm 'boot_resolved.bif'
$lines = @(
    'the_ROM_image:',
    '{',
    ('    [bootloader]' + $fsbl),
    ('    ' + $bit),
    ('    ' + $elf),
    '}'
)
Set-Content -Path $bif -Value $lines -Encoding ascii
Write-Host "  bif: $bif"

# 2026-10-29: the Vitis root is not part of the repo. Honor XILINX_VITIS
# (set by Vitis settings64.bat); otherwise fall back to the local 2024.1 install.
$vitis   = if ($env:XILINX_VITIS) { $env:XILINX_VITIS } else { 'D:\Xilinx\Vitis\2024.1' }
$bootgen = Join-Path $vitis 'bin\bootgen.bat'
if (-not (Test-Path $bootgen)) { throw "bootgen not found at $bootgen" }

$out = Join-Path $bm 'BOOT.BIN'
if (Test-Path $out) { Remove-Item -Force $out }

Write-Host '--------------------------------------------------------------'
& $bootgen -image $bif -arch zynq -o $out -w on
if ($LASTEXITCODE -ne 0) { throw "bootgen failed with exit code $LASTEXITCODE" }
if (-not (Test-Path $out)) { throw "bootgen reported success but $out does not exist" }

$md5 = (Get-FileHash -Path $out -Algorithm MD5).Hash.ToLower()
$sz  = (Get-Item $out).Length
Write-Host '--------------------------------------------------------------'
Write-Host ("  BOOT.BIN  {0:N0} B   md5 {1}" -f $sz, $md5)
Write-Host "  $out"
Write-Host '--------------------------------------------------------------'

# SD 卡：FAT32 根目录，只放这一个文件；启动方式跳到 SD（PYNQ-Z2 的 JP1）
Write-Host ''
Write-Host '  next: copy BOOT.BIN to the root of a FAT32 SD card, set the boot'
Write-Host '        jumper to SD, insert, power on.  See README.md sec.4.'
