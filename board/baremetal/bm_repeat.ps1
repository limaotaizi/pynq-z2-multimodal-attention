# bm_repeat.ps1 -- one-command board re-verification.
#
# Sends 'r' N times (full 28-array / 5504-word bitwise check) and 't' M times
# (production-path window latency), then writes:
#   <OutDir>\bm_repeat_<stamp>.txt   raw serial capture
#   <OutDir>\..\repeat.json          parsed result + latency statistics
#
# ASCII only on purpose: PowerShell 5.1 reads BOM-less .ps1 as the system ANSI
# code page, so non-ASCII comments in this file would garble the parse.
param(
    [string]$Port    = $(if ($env:BM_PORT) { $env:BM_PORT } else { 'COM8' }),
    [int]   $NumRounds = 3,
    [int]   $Timing  = 50,
    [string]$OutDir  = (Join-Path $PSScriptRoot 'logs'),
    [string]$Json    = (Join-Path (Split-Path $PSScriptRoot -Parent) 'repeat.json')
)
$ErrorActionPreference = 'Stop'

# The block is over only once the WHOLE last line has arrived -- matching the
# bare phrase would cut the line in half and lose the millisecond value.
$SENTINEL = 'one window on the A9\s+\d+\.\d{3}\s+ms\s+\(class \d\)'
$TIMEOUT_S = 15

if (-not (Test-Path $OutDir)) { New-Item -ItemType Directory -Path $OutDir | Out-Null }
$stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$rawPath = Join-Path $OutDir ("bm_repeat_{0}.txt" -f $stamp)

$sp = New-Object System.IO.Ports.SerialPort $Port, 115200, 'None', 8, 'One'
$sp.ReadTimeout  = 200
$sp.WriteTimeout = 1000
$sp.Open()
Start-Sleep -Milliseconds 300
$sp.DiscardInBuffer()

# Send one command character and read until the block's last line shows up.
# Single-character writes: the PYNQ-Z2 UART drops back-to-back bytes in a burst.
function Invoke-Cmd([string]$ch) {
    $sb = New-Object System.Text.StringBuilder
    $sp.Write($ch)
    $deadline = (Get-Date).AddSeconds($TIMEOUT_S)
    while ((Get-Date) -lt $deadline) {
        if ($sp.BytesToRead -gt 0) {
            [void]$sb.Append($sp.ReadExisting())
            if ($sb.ToString() -match $SENTINEL) {
                # Drain the tail (CR/LF and anything still in flight) so the
                # next command does not read this block's leftovers.
                Start-Sleep -Milliseconds 60
                if ($sp.BytesToRead -gt 0) { [void]$sb.Append($sp.ReadExisting()) }
                break
            }
        } else {
            Start-Sleep -Milliseconds 25
        }
    }
    return $sb.ToString()
}

$log = New-Object System.Text.StringBuilder

# --- N full bitwise rounds -------------------------------------------------
$rounds = @()
for ($i = 1; $i -le $NumRounds; $i++) {
    Write-Host ("round {0}/{1} ..." -f $i, $NumRounds)
    $txt = Invoke-Cmd 'r'
    [void]$log.Append("### ROUND $i ###`r`n").Append($txt).Append("`r`n")

    $arrays = ([regex]::Matches($txt, '(?m)^\s*\[ok\s*\]')).Count
    $bad    = ([regex]::Matches($txt, '(?m)^\s*\[FAIL')).Count
    $words  = $null
    $m = [regex]::Match($txt, 'TOTAL\s+(\d+)/(\d+)\s+words,\s+(\d+)\s+arrays')
    if ($m.Success) { $words = [int]$m.Groups[1].Value }
    $engineMs = $null; $cycles = $null
    $m = [regex]::Match($txt, 'engine\s+(\d+\.\d+)\s+ms\s+=\s+(\d+)\s+cycles')
    if ($m.Success) { $engineMs = [double]$m.Groups[1].Value; $cycles = [int64]$m.Groups[2].Value }
    $totalMs = $null
    $m = [regex]::Match($txt, 'one window on the A9\s+(\d+\.\d+)\s+ms')
    if ($m.Success) { $totalMs = [double]$m.Groups[1].Value }

    $rounds += [pscustomobject]@{
        round    = $i
        all_pass = ($txt -match 'ALL PASS')
        ok_arrays = $arrays
        fail_arrays = $bad
        words    = $words
        engine_ms = $engineMs
        engine_cycles = $cycles
        window_ms = $totalMs
    }
}

# --- M latency samples -----------------------------------------------------
$samples = @()
for ($i = 1; $i -le $Timing; $i++) {
    if (($i % 10) -eq 1) { Write-Host ("timing {0}/{1} ..." -f $i, $Timing) }
    $txt = Invoke-Cmd 't'
    [void]$log.Append("### TIMING $i ###`r`n").Append($txt).Append("`r`n")
    $m = [regex]::Match($txt, 'one window on the A9\s+(\d+\.\d+)\s+ms')
    if ($m.Success) { $samples += [double]$m.Groups[1].Value }
}
$sp.Close()

[System.IO.File]::WriteAllText($rawPath, $log.ToString(), (New-Object System.Text.UTF8Encoding($false)))

# --- statistics ------------------------------------------------------------
$sorted = @($samples | Sort-Object)
function Pct([double[]]$a, [double]$p) {
    if ($a.Count -eq 0) { return $null }
    $idx = [int][math]::Floor($p * ($a.Count - 1) + 0.5)
    return $a[$idx]
}
$stats = $null
if ($sorted.Count -gt 0) {
    $stats = [pscustomobject]@{
        n       = $sorted.Count
        min_ms  = $sorted[0]
        p10_ms  = Pct $sorted 0.10
        median_ms = Pct $sorted 0.50
        p90_ms  = Pct $sorted 0.90
        max_ms  = $sorted[-1]
        mean_ms = [math]::Round((($sorted | Measure-Object -Average).Average), 3)
    }
}

$allPass = (@($rounds | Where-Object { -not $_.all_pass }).Count -eq 0)
$all28   = (@($rounds | Where-Object { $_.ok_arrays -ne 28 }).Count -eq 0)
$all5504 = (@($rounds | Where-Object { $_.words -ne 5504 }).Count -eq 0)

$result = [pscustomobject]@{
    generated   = (Get-Date).ToString('s')
    port        = $Port
    source      = 'bm_repeat.ps1'
    rounds      = $rounds
    timing      = $stats
    samples_ms  = $samples
    raw_log     = (Resolve-Path $rawPath).Path
    verdict     = [pscustomobject]@{
        all_rounds_pass  = $allPass
        all_28_arrays    = $all28
        all_5504_words   = $all5504
        median_in_range  = (($null -ne $stats) -and ($stats.median_ms -ge 21.0) -and ($stats.median_ms -le 22.5))
    }
}

$jsonText = $result | ConvertTo-Json -Depth 6
$jsonDir = Split-Path $Json -Parent
if (-not (Test-Path $jsonDir)) { New-Item -ItemType Directory -Path $jsonDir | Out-Null }
[System.IO.File]::WriteAllText($Json, $jsonText, (New-Object System.Text.UTF8Encoding($false)))

Write-Host ''
Write-Host ('rounds : {0}/{1} ALL PASS, 28 arrays, 5504 words' -f (@($rounds | Where-Object {$_.all_pass}).Count), $NumRounds)
if ($stats) {
    Write-Host ('latency: n={0} median={1} ms  min={2}  p90={3}  max={4}' -f $stats.n, $stats.median_ms, $stats.min_ms, $stats.p90_ms, $stats.max_ms)
}
Write-Host ('raw    : {0}' -f $rawPath)
Write-Host ('json   : {0}' -f $Json)
if (-not ($allPass -and $all28 -and $all5504)) { exit 1 }
