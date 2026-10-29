# build_cpu_ref.ps1 -- build the A9 reference run (cpu_ref.elf).
#
# Uses the same BSP and the same gcc command line shape as
# ../baremetal/build_elf.ps1, so the ELF links against the identical libxil.a.
# The BSP workspace is a build artefact (not in git): generate it once with
# ../baremetal/build_platform.tcl, or point -Ws at an existing one.
#
#   powershell -ExecutionPolicy Bypass -File build_cpu_ref.ps1
#
# ASCII only: PowerShell 5.1 reads BOM-less .ps1 as the system ANSI code page.
param(
    [string]$Ws     = '',
    [string]$Python = 'python'
)
$ErrorActionPreference = 'Stop'

$here = $PSScriptRoot
$bm   = Join-Path (Split-Path $here -Parent) 'baremetal'
if (-not $Ws) { $Ws = Join-Path $bm 'ws' }
$src  = $here
$bld  = Join-Path $here 'build'
$app  = 'cpu_ref'

$vitis  = if ($env:XILINX_VITIS) { $env:XILINX_VITIS } else { 'D:\Xilinx\Vitis\2024.1' }
$gccbin = Join-Path $vitis 'gnu\aarch32\nt\gcc-arm-none-eabi\bin'
$gcc    = Join-Path $gccbin 'arm-none-eabi-gcc.exe'
$nm     = Join-Path $gccbin 'arm-none-eabi-nm.exe'
$szCmd  = Join-Path $gccbin 'arm-none-eabi-size.exe'

$dom    = Join-Path $Ws 'attn4_plat\export\attn4_plat\sw\attn4_plat\standalone_domain'
$bspinc = Join-Path $dom 'bspinclude\include'
$bsplib = Join-Path $dom 'bsplib\lib'
$lsl    = Join-Path $Ws 'attn_m4\src\lscript.ld'

foreach ($n in @(
    @{p = $gcc;    what = 'arm-none-eabi-gcc'},
    @{p = $bspinc; what = 'BSP include dir'},
    @{p = (Join-Path $bsplib 'libxil.a'); what = 'libxil.a'},
    @{p = $lsl;    what = 'lscript.ld (run ../baremetal/build_platform.tcl first)'}
)) {
    if (-not (Test-Path $n.p)) { throw "missing $($n.what): $($n.p)" }
}

if (-not (Test-Path $bld)) { New-Item -ItemType Directory -Force $bld | Out-Null }

# ---- 1. regenerate the tables from the committed RTL vectors --------------
Write-Host '--------------------------------------------------------------'
Write-Host ' tables   build\cpu_ref_data.h  <- sim\vectors\m4\*.mem'
Write-Host '--------------------------------------------------------------'
& $Python -I -X utf8 (Join-Path $src 'gen_cpu_ref.py')
if ($LASTEXITCODE -ne 0) { throw "gen_cpu_ref.py failed ($LASTEXITCODE)" }

$hdr = Join-Path $bld 'cpu_ref_data.h'
if (-not (Test-Path $hdr)) { throw "gen_cpu_ref.py did not produce $hdr" }

# ---- 2. compile / link ----------------------------------------------------
$COMMON = @(
    '-mcpu=cortex-a9', '-mfpu=vfpv3', '-mfloat-abi=hard',
    '-O2', '-g', '-Wall',
    '-ffunction-sections', '-fdata-sections',
    '-fno-tree-loop-distribute-patterns',
    "-I$bspinc", "-I$bld"
)

$libgcc = & $gcc @($COMMON | Where-Object { $_ -like '-m*' }) '-print-libgcc-file-name'
$libdir = Split-Path $libgcc -Parent
$crti   = Join-Path $libdir 'crti.o'
$crtn   = Join-Path $libdir 'crtn.o'

$obj = Join-Path $bld "$app.o"
$elf = Join-Path $bld "$app.elf"
$map = Join-Path $bld "$app.map"

Write-Host '--------------------------------------------------------------'
Write-Host ' compile  cpu_ref.c'
Write-Host '--------------------------------------------------------------'
& $gcc @COMMON -c (Join-Path $src 'cpu_ref.c') -o $obj
if ($LASTEXITCODE -ne 0) { throw "compile failed ($LASTEXITCODE)" }

Write-Host '--------------------------------------------------------------'
Write-Host " link     -> $elf"
Write-Host '--------------------------------------------------------------'
if (Test-Path $elf) { Remove-Item -Force $elf }

$linkArgs = @($COMMON) + @(
    '-nostartfiles',
    '-Wl,-T', "-Wl,$lsl",
    "-Wl,-Map,$map",
    '-Wl,--gc-sections',
    $crti,
    $obj,
    "-L$bsplib",
    '-Wl,--start-group,-lxil,-lgcc,-lc,-lm,--end-group',
    $crtn,
    '-o', $elf
)
& $gcc @linkArgs
if ($LASTEXITCODE -ne 0) { throw "link failed ($LASTEXITCODE)" }
if (-not (Test-Path $elf)) { throw "linker reported success but $elf does not exist" }

# ---- 3. sanity: the startup chain must still be the BSP's -----------------
Write-Host '--------------------------------------------------------------'
Write-Host ' verify'
Write-Host '--------------------------------------------------------------'
$symNames = @(& $nm $elf | ForEach-Object { ($_ -split '\s+')[-1] })
foreach ($s in @('_vector_table', '_boot', '_start', 'main', '__bss_start', '__stack')) {
    if ($symNames -notcontains $s) { throw "symbol '$s' not found -- startup chain is broken" }
}
& $szCmd $elf

$mtime = (Get-Item $elf).LastWriteTime
Write-Host ''
Write-Host ("  {0}.elf  {1:N0} B  {2}" -f $app, (Get-Item $elf).Length, $mtime)
Write-Host '  next: xsdb -eval "connect; targets; rst -processor; dow cpu_ref.elf; con"'
