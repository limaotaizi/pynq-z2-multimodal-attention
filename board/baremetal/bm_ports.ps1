# bm_ports.ps1 -- list the serial ports that could be the PYNQ-Z2 UART.
#
# Why this exists: the board scripts used to default to a hardcoded COM8.
# The port number depends on which USB socket and which driver instance the
# host enumerates, so it drifts between machines and between reboots.
#
# ASCII only on purpose: PowerShell 5.1 reads BOM-less .ps1 as the system ANSI
# code page, so non-ASCII comments here would garble the parse.
#
# Usage:
#   powershell -ExecutionPolicy Bypass -File bm_ports.ps1
#   then pass the port you see, or set $env:BM_PORT to it:
#     $env:BM_PORT = 'COM7'
#
# Bluetooth virtual COM ports are filtered out on purpose -- they show up even
# when nothing is plugged in and they never carry the board's output.

$all = Get-CimInstance Win32_PnPEntity |
       Where-Object { $_.Name -match '\((COM\d+)\)' } |
       ForEach-Object {
           [pscustomobject]@{
               Port = [regex]::Match($_.Name, '\((COM\d+)\)').Groups[1].Value
               Name = $_.Name
               Device = $_.DeviceID
           }
       }

$bt    = $all | Where-Object { $_.Device -like 'BTHENUM*' }
$cands = $all | Where-Object { $_.Device -notlike 'BTHENUM*' }

if ($cands) {
    Write-Host "Candidate board ports (non-Bluetooth):"
    $cands | Sort-Object Port | Format-Table Port, Name -AutoSize
} else {
    Write-Host "No candidate board port found. The USB-UART is not enumerated."
    Write-Host "Check: micro-USB cable plugged into the PYNQ-Z2 UART port, board powered."
}

if ($bt) {
    Write-Host ("Ignored {0} Bluetooth virtual port(s): {1}" -f $bt.Count,
        (($bt | Sort-Object Port | ForEach-Object { $_.Port }) -join ', '))
}
