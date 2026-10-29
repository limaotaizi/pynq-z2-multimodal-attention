# bm_capture_boot.ps1 -- wait for the board's COM port to appear, then grab
# the whole cold-boot banner.
#
# Why this exists: on the PYNQ-Z2 the USB-UART bridge lives on the board, so
# the COM port only exists while the board is powered. Opening the port before
# power-on is impossible, and opening it "a bit after" power-on misses the
# banner (that is exactly what happened the first time round). So this script
# polls the port list and opens the port the moment it shows up.
#
# ASCII only on purpose (PowerShell 5.1 + BOM-less .ps1 + non-ASCII = garbled).
#
# Usage:
#   powershell -ExecutionPolicy Bypass -File bm_capture_boot.ps1 -Seconds 45
#   then plug the board in.
param(
    [string]$Port    = $(if ($env:BM_PORT) { $env:BM_PORT } else { 'COM8' }),
    [int]   $Seconds = 45,
    [int]   $WaitFor = 300,
    [string]$Out     = 'bm_boot.txt',
    [string]$Send    = ''
)

$ErrorActionPreference = 'Stop'
$deadline = (Get-Date).AddSeconds($WaitFor)

Write-Host ("waiting for {0} to appear (up to {1} s) ..." -f $Port, $WaitFor)
$sp = $null
while ((Get-Date) -lt $deadline) {
    if ([System.IO.Ports.SerialPort]::GetPortNames() -contains $Port) {
        try {
            $sp = New-Object System.IO.Ports.SerialPort $Port, 115200, 'None', 8, 'One'
            $sp.ReadTimeout  = 200
            $sp.WriteTimeout = 1000
            $sp.Open()
            Write-Host ("opened {0} at {1}" -f $Port, (Get-Date -Format 'HH:mm:ss.fff'))
            break
        } catch {
            if ($sp -ne $null) { $sp.Dispose(); $sp = $null }
            Start-Sleep -Milliseconds 100
        }
    } else {
        Start-Sleep -Milliseconds 100
    }
}
if ($sp -eq $null) { throw "$Port never showed up within $WaitFor s" }

$all = New-Object System.Text.StringBuilder
$end = (Get-Date).AddSeconds($Seconds)

# Optional keys, one character at a time, sent a couple of seconds in so the
# banner is already in the buffer. The PYNQ-Z2 UART drops back-to-back bytes
# written as one burst, hence the per-character loop.
$sendAt = (Get-Date).AddSeconds([math]::Min(8, [math]::Max(2, $Seconds / 4)))
$sent   = $false

while ((Get-Date) -lt $end) {
    try {
        if ($sp.BytesToRead -gt 0) { [void]$all.Append($sp.ReadExisting()) }
        else { Start-Sleep -Milliseconds 30 }
    } catch { Start-Sleep -Milliseconds 30 }

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
Write-Host ("captured {0} chars -> {1}" -f $all.Length, $path)
Write-Host '--------------------------------------------------------------'
Write-Host $all.ToString()
Write-Host '--------------------------------------------------------------'
