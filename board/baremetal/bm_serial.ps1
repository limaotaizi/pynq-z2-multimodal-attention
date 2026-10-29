# bm_serial.ps1 -- open COM8 @115200, optionally send keys, capture output.
# ASCII only on purpose: PowerShell 5.1 reads BOM-less .ps1 as the system ANSI
# code page, so non-ASCII comments in this file would garble the parse.
param(
    [string]$Port    = $(if ($env:BM_PORT) { $env:BM_PORT } else { 'COM8' }),
    [int]   $Seconds = 30,
    [string]$Out     = 'bm_boot.txt',
    [string]$Send    = ''
)
$ErrorActionPreference = 'Stop'

$sp = New-Object System.IO.Ports.SerialPort $Port, 115200, 'None', 8, 'One'
$sp.ReadTimeout  = 300
$sp.WriteTimeout = 1000
$sp.Open()

$all = New-Object System.Text.StringBuilder
Start-Sleep -Milliseconds 500

# A bare CR first: harmless to the bare-metal app (it ignores everything but
# r/R/q) and it gets a shell prompt to redraw if something else is listening.
$sp.Write([string][char]13)
Start-Sleep -Milliseconds 300

# Send one character at a time. The PYNQ-Z2 UART drops back-to-back bytes
# written in one burst; this was a real trap on this board before.
if ($Send.Length -gt 0) {
    foreach ($ch in $Send.ToCharArray()) {
        $sp.Write([string]$ch)
        Start-Sleep -Milliseconds 60
    }
}

$end = (Get-Date).AddSeconds($Seconds)
while ((Get-Date) -lt $end) {
    try {
        if ($sp.BytesToRead -gt 0) { [void]$all.Append($sp.ReadExisting()) }
        else { Start-Sleep -Milliseconds 40 }
    } catch { Start-Sleep -Milliseconds 40 }
}
$sp.Close()

$path = Join-Path (Get-Location) $Out
[System.IO.File]::WriteAllText($path, $all.ToString(), (New-Object System.Text.UTF8Encoding($false)))
Write-Host ("captured {0} chars -> {1}" -f $all.Length, $path)
Write-Host '--------------------------------------------------------------'
Write-Host $all.ToString()
Write-Host '--------------------------------------------------------------'
