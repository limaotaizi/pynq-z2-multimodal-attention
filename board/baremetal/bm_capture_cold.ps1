# bm_capture_cold.ps1 -- grab a real cold boot, tolerating human latency.
#
# Why this exists (2026-10-28, second time round):
#   bm_capture_boot.ps1 opens the port the moment it appears. That is right when
#   the board is already off, but it loses if the port is *still* enumerated
#   when the script starts: it opens a dead port, reads nothing, and its fixed
#   window expires long before the person gets round to plugging the USB back
#   in. That is exactly what happened -- 45 s of silence while the board was
#   powered down, then "done".
#
# So this one has three phases and says which one it is in:
#   1. wait for the port to DISAPPEAR   (proof the board is really off)
#   2. wait for it to come BACK         (your power-on)
#   3. open and read for -Seconds
#
# Usage:
#   powershell -ExecutionPolicy Bypass -File bm_capture_cold.ps1 -Seconds 60 -AbsentWait 180
#   ... it prints "phase 1 waiting for COM8 to go away"
#   ... you unplug the micro-USB, it prints "gone"
#   ... it prints "phase 2 waiting for COM8" -- now plug it back in, whenever
param(
    [string]$Port        = $(if ($env:BM_PORT) { $env:BM_PORT } else { 'COM8' }),
    [int]   $Seconds     = 60,
    [int]   $AbsentWait  = 180,
    [int]   $PresentWait = 300,
    [string]$Out         = 'bm_cold_boot.txt',
    [string]$Send        = ''
)

$ErrorActionPreference = 'Stop'

function PortPresent([string]$p) {
    return ([System.IO.Ports.SerialPort]::GetPortNames() -contains $p)
}
function Stamp { (Get-Date -Format 'HH:mm:ss.fff') }

# ---- phase 1: the port must go away ----------------------------------------
Write-Host ("[{0}] phase 1: waiting up to {1} s for {2} to DISAPPEAR" -f (Stamp), $AbsentWait, $Port)
$deadline = (Get-Date).AddSeconds($AbsentWait)
while (PortPresent $Port) {
    if ((Get-Date) -gt $deadline) {
        Write-Host ("[{0}] WARNING: {1} never went away -- the board may still be powered." -f (Stamp), $Port)
        Write-Host '          Capturing anyway; if the banner is missing, that is why.'
        break
    }
    Start-Sleep -Milliseconds 100
}
if (-not (PortPresent $Port)) { Write-Host ("[{0}] gone" -f (Stamp)) }

# ---- phase 2 + 3: it comes back, open instantly, read -----------------------
Write-Host ("[{0}] phase 2: waiting up to {1} s for {2} to APPEAR -- plug the micro-USB in now" -f (Stamp), $PresentWait, $Port)
$sp = $null
$deadline = (Get-Date).AddSeconds($PresentWait)
while ((Get-Date) -lt $deadline) {
    if (PortPresent $Port) {
        try {
            $sp = New-Object System.IO.Ports.SerialPort $Port, 115200, 'None', 8, 'One'
            $sp.ReadTimeout  = 200
            $sp.WriteTimeout = 1000
            $sp.Open()
            Write-Host ("[{0}] opened {1}" -f (Stamp), $Port)
            break
        } catch {
            if ($sp -ne $null) { $sp.Dispose(); $sp = $null }
            Start-Sleep -Milliseconds 50
        }
    } else {
        Start-Sleep -Milliseconds 50
    }
}
if ($sp -eq $null) { throw "$Port never came back within $PresentWait s" }

$all = New-Object System.Text.StringBuilder
$end = (Get-Date).AddSeconds($Seconds)
$sendAt = (Get-Date).AddSeconds([math]::Min(20, [math]::Max(5, $Seconds / 3)))
$sent = $false

while ((Get-Date) -lt $end) {
    try {
        if ($sp.BytesToRead -gt 0) { [void]$all.Append($sp.ReadExisting()) }
        else { Start-Sleep -Milliseconds 20 }
    } catch { Start-Sleep -Milliseconds 20 }

    if (-not $sent -and $Send.Length -gt 0 -and (Get-Date) -ge $sendAt) {
        foreach ($ch in $Send.ToCharArray()) {
            $sp.Write([string]$ch)
            Start-Sleep -Milliseconds 60
        }
        $sent = $true
    }
}
$sp.Close()

$path = Join-Path (Get-Location) $Out
[System.IO.File]::WriteAllText($path, $all.ToString(), (New-Object System.Text.UTF8Encoding($false)))
Write-Host ("[{0}] captured {1} chars -> {2}" -f (Stamp), $all.Length, $path)
Write-Host '--------------------------------------------------------------'
Write-Host $all.ToString()
