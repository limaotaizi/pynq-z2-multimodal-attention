# =============================================================================
# build_elf.ps1 -- 绕过 xsct，用 BSP 的同一套工具链编译 attn_m4.elf
#
#   为什么要绕过：
#     `app create` / `app build` 在本机 xsct 里会**卡死**（已复现三次）。
#     ws\attn_m4 和 .cproject 都写出来了，之后再也不返回：源码拷不进去、
#     编译不启动、ws\IDE.log 停在那一刻。现场是 eclipse 进程空转，
#     环境里 XILINX_VITIS 为空，PATH 里出现 '\gnu\microblaze\lin\bin\'。
#     与其修 IDE，不如把 IDE 那一步拆掉 —— 它本来就只是替你拼一条 gcc 命令行。
#
#   这条命令行不是猜的：
#     - 编译器用 Vitis 自带的那一份（arm-xilinx-eabi-gcc 12.2.0），
#       ABI 与预编译好的 libxil.a / 头文件完全对齐；
#     - 库和头文件用 platform generate 已经建好的 BSP 导出物（libxil.a + bspinclude）；
#     - 链接脚本用 Vitis 已经生成好的 ws\attn_m4\src\lscript.ld（DDR @0x100000）。
#   产物和 Vitis IDE 本该产出的 ELF 同口径，不是另起一套。
#
#   ★ 本文件必须带 UTF-8 BOM。PowerShell 5.1 读无 BOM 的 .ps1 时按系统 ANSI
#     （这里是 GBK）解码，中文注释被打乱后会蹦出解析错误，报的位置还指不到真凶。
#
#   Usage:  powershell -ExecutionPolicy Bypass -File build_elf.ps1
# =============================================================================
$ErrorActionPreference = 'Stop'

$bm   = $PSScriptRoot
$ws   = Join-Path $bm 'ws'
$src  = Join-Path $bm 'src'
$app  = 'attn_m4'

# 2026-10-29: the Vitis root is not part of the repo. Honor XILINX_VITIS
# (set by Vitis settings64.bat); otherwise fall back to the local 2024.1 install.
$vitis  = if ($env:XILINX_VITIS) { $env:XILINX_VITIS } else { 'D:\Xilinx\Vitis\2024.1' }
$gccbin = Join-Path $vitis 'gnu\aarch32\nt\gcc-arm-none-eabi\bin'
$gcc    = Join-Path $gccbin 'arm-none-eabi-gcc.exe'
$nm     = Join-Path $gccbin 'arm-none-eabi-nm.exe'
$szCmd  = Join-Path $gccbin 'arm-none-eabi-size.exe'

$dom    = Join-Path $ws 'attn4_plat\export\attn4_plat\sw\attn4_plat\standalone_domain'
$bspinc = Join-Path $dom 'bspinclude\include'
$bsplib = Join-Path $dom 'bsplib\lib'
$lsl    = Join-Path $ws "$app\src\lscript.ld"
$outdir = Join-Path $ws "$app\Debug"
$elf    = Join-Path $outdir "$app.elf"

# --- 标准 Cortex-A9 / Zynq-7020 裸机口径 -------------------------------------
#   -mfpu=vfpv3        Zynq-7020 的 FPU 是 VFPv3-D16，没有 NEON
#   -ffunction/-fdata-sections  配合 lscript.ld 里的 *(.text.*) / *(.data.*)
#   -fno-tree-loop-distribute-patterns  防止 GCC 把清零/拷贝循环变成 memset/memcpy
#     （裸机下这类隐式调用历史上出过问题，Vitis 自己的 CFLAGS 也带这一条）
$COMMON = @(
    '-mcpu=cortex-a9', '-mfpu=vfpv3', '-mfloat-abi=hard',
    '-O2', '-g', '-Wall',
    '-ffunction-sections', '-fdata-sections',
    '-fno-tree-loop-distribute-patterns',
    "-I$bspinc", "-I$src"
)

# crti.o / crtn.o 的目录，按编译器自己报的 multilib 路径取（不写死版本号）。
# 注意：本机这套 gcc 包装器上 `-print-file-name=crti.o` 会把扩展名吃掉、
# 只回显 "crti"，所以改用 -print-libgcc-file-name，它能给出完整的绝对路径。
$libgcc  = & $gcc @($COMMON | Where-Object { $_ -like '-m*' }) '-print-libgcc-file-name'
$libdir  = Split-Path $libgcc -Parent
$crti    = Join-Path $libdir 'crti.o'
$crtn    = Join-Path $libdir 'crtn.o'

$need = @(
    @{p = $gcc;       what = 'arm-none-eabi-gcc'},
    @{p = $bspinc;    what = 'BSP include dir'},
    @{p = (Join-Path $bsplib 'libxil.a'); what = 'libxil.a'},
    @{p = $lsl;       what = 'lscript.ld'},
    @{p = $crti;      what = 'crti.o'},
    @{p = $crtn;      what = 'crtn.o'},
    @{p = (Join-Path $src 'main.c');      what = 'src\main.c'},
    @{p = (Join-Path $src 'golden_m4.h'); what = 'src\golden_m4.h'},
    @{p = (Join-Path $src 'head_m4.c');        what = 'src\head_m4.c'},
    @{p = (Join-Path $src 'head_m4.h');        what = 'src\head_m4.h'},
    @{p = (Join-Path $src 'head_m4_w.h');      what = 'src\head_m4_w.h'},
    @{p = (Join-Path $src 'head_m4_gold.h');   what = 'src\head_m4_gold.h'}
)
foreach ($n in $need) {
    if (-not (Test-Path $n.p)) { throw "missing $($n.what): $($n.p)" }
}

if (-not (Test-Path $outdir)) { New-Item -ItemType Directory -Force $outdir | Out-Null }

$obj  = Join-Path $outdir 'main.o'
$objH = Join-Path $outdir 'head_m4.o'
$map  = Join-Path $outdir "$app.map"

Write-Host '--------------------------------------------------------------'
Write-Host ' compile  src\main.c  src\head_m4.c'
Write-Host '--------------------------------------------------------------'
& $gcc @COMMON -c (Join-Path $src 'main.c') -o $obj
if ($LASTEXITCODE -ne 0) { throw "compile failed ($LASTEXITCODE)" }
& $gcc @COMMON -c (Join-Path $src 'head_m4.c') -o $objH
if ($LASTEXITCODE -ne 0) { throw "compile failed (head_m4.c, $LASTEXITCODE)" }

Write-Host '--------------------------------------------------------------'
Write-Host " link     -> $elf"
Write-Host '--------------------------------------------------------------'
if (Test-Path $elf) { Remove-Item -Force $elf }

#   三个不能省的细节，都是链接失败换来的：
#
#   1) -nostartfiles
#      要 BSP 自己的启动链：_vector_table(asm_vectors.o) -> _boot(boot.o)
#      -> _start(xil-crt0.o) -> main。这三段都在 libxil.a 里，而且 xil-crt0.o
#      负责 __cpu_init / MMU 表 / __bss 清零 / XTime_SetTime。
#      不加它，工具链的 libgloss crt0.o 会抢先定义 _start，BSP 启动链整段被跳过。
#
#   2) crti.o / crtn.o 显式给出
#      -nostartfiles 连它们一起去掉了，而 libc 的 __libc_init_array / __libc_fini_array
#      要调 _init / _fini；缺了就报 undefined reference to `_init'。它们通常是空的。
#
#   3) $obj 放在库之前
#      ld 按命令行顺序扫归档。库组写在 main.o 前面时，扫描那一刻
#      xil_printf / XTime_GetTime 还是未知符号，libxil.a 一个成员都不会被拉进来。
$linkArgs = @($COMMON) + @(
    '-nostartfiles',
    '-Wl,-T', "-Wl,$lsl",
    "-Wl,-Map,$map",
    '-Wl,--gc-sections',
    $crti,
    $obj,
    $objH,
    "-L$bsplib",
    #   -lm 是模块③④ 要的（tanhf / expf，见 head_m4.c）。
    '-Wl,--start-group,-lxil,-lgcc,-lc,-lm,--end-group',
    $crtn,
    '-o', $elf
)
& $gcc @linkArgs
if ($LASTEXITCODE -ne 0) { throw "link failed ($LASTEXITCODE)" }
if (-not (Test-Path $elf)) { throw "linker reported success but $elf does not exist" }

# --- 验货：入口、启动链、大小 ------------------------------------------------
Write-Host '--------------------------------------------------------------'
Write-Host ' verify'
Write-Host '--------------------------------------------------------------'
$symNames = @(& $nm $elf | ForEach-Object { ($_ -split '\s+')[-1] })
foreach ($s in @('_vector_table', '_boot', '_start', 'main', '__bss_start', '__stack')) {
    if ($symNames -notcontains $s) { throw "symbol '$s' not found in $elf -- startup chain is broken" }
    Write-Host "  symbol ok: $s"
}
Write-Host ''
& $szCmd $elf

# 入口必须是 _vector_table（lscript.ld 的 ENTRY）。bootgen 对 <elf,...> 分区
# 就是按 ELF 的 e_entry 跳转的，这里错了板上跑的第一条指令就不是复位向量。
$readelf = Join-Path $gccbin 'arm-none-eabi-readelf.exe'
$entryLine = & $readelf -h $elf | Select-String -Pattern 'Entry point address'
Write-Host ''
Write-Host "  $($entryLine.ToString().Trim())"
if ($entryLine.ToString() -notmatch '0x100000') {
    throw "ELF entry point is not 0x100000 -- check lscript.ld ENTRY(_vector_table)"
}
Write-Host '  entry ok: 0x100000 (= _vector_table)'

$md5 = (Get-FileHash $elf -Algorithm MD5).Hash.ToLower()
$sz  = (Get-Item $elf).Length
Write-Host '--------------------------------------------------------------'
Write-Host ("  {0}.elf  {1:N0} B   md5 {2}" -f $app, $sz, $md5)
Write-Host "  $elf"
Write-Host '--------------------------------------------------------------'
Write-Host ''
Write-Host '  next: powershell -ExecutionPolicy Bypass -File build_bootbin.ps1'
