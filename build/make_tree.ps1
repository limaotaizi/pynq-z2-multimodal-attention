# make_tree.ps1 -- assemble the working tree that build_bd_all*.tcl expect,
# using ONLY files committed in this repository.
#
#   powershell -File make_tree.ps1 -Mode m4
#   vivado -mode batch -source <Out>\build_bd_all.tcl
#   vivado -mode batch -source <Out>\build_bd_all_m4_impl.tcl
#
# Why this exists: the Tcl was written against the developer tree, where the
# scripts sat next to ip_repo_all/, rtl/, work2/ and constr/ as siblings. That
# tree is not in git (it held vendor artefacts and 100 MB of snapshots), so
# "rebuild a bitstream" was a promise the repository could not keep. Everything
# the scripts actually read is in src/rtl and sim/; this script lays it back out.
#
# Two lines are rewritten in the assembled copies -- never in the repository:
#
#   1. MEM_DIR in attn_core.v. The committed default is "../vectors", which is
#      right for xsim launched from sim/run/. Vivado synthesis resolves it
#      against its own working directory instead, so a rebuild needs the
#      absolute path of work2/out here.
#
#   2. ATTNAXI_UM in attn_axi.v. Vivado does not override a Verilog parameter
#      default from the block design -- the default IS the value in the
#      bitstream. UM is the k/v row count T*(M-1): 8 covers M=2 and M=3, M=4
#      needs 12. Building M=4 with 8 synthesises, closes timing, boots, and
#      silently computes the wrong thing. See BITSTREAM_MANIFEST.md.
#
# ASCII only: PowerShell 5.1 reads a BOM-less .ps1 as the system ANSI code page.
param(
    [ValidateSet('m2', 'm3', 'm4')]
    [string]$Mode = 'm4',
    [string]$Out  = '',
    [switch]$Force
)
$ErrorActionPreference = 'Stop'

# ---- mode table -----------------------------------------------------------
# UM is the only thing that differs between the three whole-design builds.
# M=2 was shipped with the default 8; M=4 needed 12. M=3 uses U = 4*(3-1) = 8,
# which the default already covers -- see the open item in BITSTREAM_MANIFEST.md.
$MODES = @{
    m2 = @{ UM = 8;  Tcl = 'build_bd_all_m2_e4.tcl';     Bit = 'attn2_e4.bit'; Wbytes = 29984; Nins = 182 }
    m3 = @{ UM = 8;  Tcl = 'build_bd_all_m3_impl.tcl';   Bit = 'attn3_e4.bit'; Wbytes = 43120; Nins = 329 }
    m4 = @{ UM = 12; Tcl = 'build_bd_all_m4_impl.tcl';   Bit = 'attn4_e4.bit'; Wbytes = 55824; Nins = 492 }
}
$m = $MODES[$Mode]

$build = $PSScriptRoot
$repo  = Split-Path $build -Parent
if (-not $Out) { $Out = Join-Path (Split-Path $repo -Parent) "_repro_$Mode" }

$srcRtl = Join-Path $repo 'src\rtl'
$srcTb  = Join-Path $repo 'sim\tb'
$srcVec = Join-Path $repo "sim\vectors\$Mode"
$srcCon = Join-Path $build 'constr'

foreach ($p in @($srcRtl, $srcTb, $srcVec, $srcCon)) {
    if (-not (Test-Path $p)) { throw "missing in repository: $p" }
}

$outRtl  = Join-Path $Out 'rtl'
$outW2   = Join-Path $Out 'work2'
$outW2Rt = Join-Path $outW2 'rtl'
$outW2Out= Join-Path $outW2 'out'
$outW2Tb = Join-Path $outW2 'tb'
$outCon  = Join-Path $Out 'constr'

Write-Host '--------------------------------------------------------------'
Write-Host " make_tree.ps1   mode=$Mode  UM=$($m.UM)"
Write-Host "   from $repo"
Write-Host "   to   $Out"
Write-Host '--------------------------------------------------------------'

if (Test-Path $Out) {
    if (-not $Force) {
        throw "$Out already exists -- pass -Force to wipe it, or -Out <dir>"
    }
    Write-Host ' [0/6] removing the previous tree'
    Remove-Item -Recurse -Force $Out
}

# ---- 1. directories -------------------------------------------------------
Write-Host ' [1/6] directories'
foreach ($d in @($Out, $outRtl, $outW2, $outW2Rt, $outW2Out, $outW2Tb, $outCon)) {
    New-Item -ItemType Directory -Force $d | Out-Null
}

# ---- 2. RTL: two copies, because the scripts read both --------------------
#   rtl/       master copies, packaged as ts_top / eeg_fe_top
#   work2/rtl/ the attention engine, packaged as attn_axi
Write-Host ' [2/6] rtl/ and work2/rtl/  <- src/rtl'
$v = Get-ChildItem -Path $srcRtl -Filter *.v
if ($v.Count -eq 0) { throw "no .v files in $srcRtl" }
foreach ($f in $v) {
    Copy-Item $f.FullName (Join-Path $outRtl  $f.Name)
    Copy-Item $f.FullName (Join-Path $outW2Rt $f.Name)
}
Write-Host ("        {0} Verilog files" -f $v.Count)

# ---- 3. the exported vectors the synthesised ROMs are built from ----------
Write-Host " [3/6] work2/out/  <- sim/vectors/$Mode"
foreach ($f in (Get-ChildItem -Path $srcVec -Filter *.mem)) {
    Copy-Item $f.FullName (Join-Path $outW2Out $f.Name)
}
Copy-Item (Join-Path $srcVec 'exp_note.txt') (Join-Path $outW2Out 'exp_note.txt')

# ---- 4. test benches, constraints, the build scripts themselves -----------
Write-Host ' [4/6] work2/tb/, constr/, *.tcl'
Copy-Item (Join-Path $srcTb '*') $outW2Tb -Recurse
Copy-Item (Join-Path $srcCon '*') $outCon
Copy-Item (Join-Path $build '*.tcl') $Out
Copy-Item (Join-Path $build 'report_a1_util.tcl') $Out -ErrorAction SilentlyContinue

# ---- 5. the two rewritten lines -------------------------------------------
Write-Host ' [5/6] patching MEM_DIR and ATTNAXI_UM in the assembled copies'

$memDir = ($outW2Out -replace '\\', '/')
$patched = 0
foreach ($d in @($outRtl, $outW2Rt)) {
    $p = Join-Path $d 'attn_core.v'
    $t = [System.IO.File]::ReadAllText($p)
    $before = $t
    $t = $t -replace '`define\s+MEM_DIR\s+"[^"]*"', ('`define MEM_DIR "' + $memDir + '"')
    if ($t -eq $before) { throw "MEM_DIR default not found in $p -- the RTL changed, update this script" }
    [System.IO.File]::WriteAllText($p, $t, (New-Object System.Text.UTF8Encoding($false)))
    $patched++

    $p = Join-Path $d 'attn_axi.v'
    $t = [System.IO.File]::ReadAllText($p)
    $before = $t
    # The macro, and the parameter literal it feeds. Both, because the shipped
    # impl scripts grep for the literal `parameter integer UM = 12` -- the
    # macro form arrived on 2026-10-29, after attn4_e4.bit was built. Writing
    # the literal reconstructs the source that produced the shipped bitstream
    # instead of reinterpreting it.
    $t = $t -replace '(`define\s+ATTNAXI_UM\s+)\d+', ('${1}' + $m.UM)
    $t = $t -replace 'parameter\s+integer\s+UM\s*=\s*`ATTNAXI_UM', ('parameter integer UM = ' + $m.UM)
    if ($t -eq $before) {
        throw "ATTNAXI_UM not found in $p -- the RTL changed, update this script"
    }
    [System.IO.File]::WriteAllText($p, $t, (New-Object System.Text.UTF8Encoding($false)))
}
Write-Host "        MEM_DIR     = $memDir"
Write-Host "        ATTNAXI_UM  = $($m.UM)"

# ---- 6. assert the tree is what the Tcl preflight will check --------------
Write-Host ' [6/6] preflight (mirrors the guards at the top of the impl script)'

function Need([string]$path, [string]$what) {
    if (-not (Test-Path $path)) { throw "missing $what : $path" }
}
Need (Join-Path $outW2Rt 'attn_core.v') 'attn_core.v'
Need (Join-Path $outW2Rt 'attn_axi.v')  'attn_axi.v'
Need (Join-Path $outRtl  'ts_top.v')    'ts_top.v'
Need (Join-Path $Out "$($m.Tcl)")       'impl script'

$note = (Get-Content (Join-Path $outW2Out 'exp_note.txt') -Raw).Trim()
if ($note -notmatch "mode=$Mode") { throw "exp_note.txt does not say mode=$Mode : $note" }
if ($note -notmatch "wbytes=$($m.Wbytes)") {
    throw "exp_note.txt wbytes does not match $($m.Wbytes) : $note"
}
Write-Host "        exp_note : $($note -replace "`r?`n", ' | ')"

$core = Get-Content (Join-Path $outW2Rt 'attn_core.v') -Raw
if ($core -notmatch [regex]::Escape($memDir)) { throw 'MEM_DIR patch did not stick' }
if ($core -notmatch 'parameter integer UM') { throw 'attn_core.v has no UM parameter' }
if ($core -notmatch [regex]::Escape('(* dont_touch = "true" *)')) {
    throw 'attn_core.v lacks the REQP-1962 dont_touch fix'
}
$axi = Get-Content (Join-Path $outW2Rt 'attn_axi.v') -Raw
if ($axi -notmatch "parameter integer UM = $($m.UM)") {
    throw "attn_axi.v does not default UM to $($m.UM)"
}
if ($axi -notmatch '\.UM\(UM\)') { throw 'attn_axi.v does not forward UM to attn_core' }
Write-Host '        all guards pass'

# instruction count, so a wrong-mode vector set is caught here not in Vivado
$nins = (Get-Content (Join-Path $outW2Out 'instr.mem') | Where-Object { $_.Trim() -ne '' }).Count
Write-Host ("        instr.mem {0} words (expected {1})" -f $nins, $m.Nins)
if ($nins -ne $m.Nins) { throw "instr.mem has $nins words, $Mode needs $($m.Nins)" }

Write-Host ''
Write-Host '--------------------------------------------------------------'
Write-Host ' next:'
Write-Host ("   vivado -mode batch -source `"{0}`"" -f (Join-Path $Out 'build_bd_all.tcl'))
Write-Host ("   vivado -mode batch -source `"{0}`"" -f (Join-Path $Out $m.Tcl))
Write-Host (" expects {0}  (md5 in BITSTREAM_MANIFEST.md)" -f $m.Bit)
Write-Host '--------------------------------------------------------------'
