# reset-rig.ps1 — bring the rig to a known state before a scenario.
#
# Windows companion to reset-rig.sh. Same contract:
#   1. PDU off → wait → on (full power cycle of the printer).
#   2. eMMC mux → printer (in case the previous run left it on host).
#   3. Wait for SSH on the printer's known IP, up to 5 minutes.
#
# Vendor-specific PDU + mux drivers live under .\pdu\ and .\mux\;
# this script only knows the abstract interface. Each driver is a
# `.ps1` whose first arg is the verb (`on`/`off`/`to-printer`).

param()

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$rigConfig = if ($env:HITL_RIG_CONFIG) { $env:HITL_RIG_CONFIG } else { Join-Path $here '..\rig.env' }

if (-not (Test-Path $rigConfig)) {
    Write-Error "missing rig config at $rigConfig (expected variables: PRINTER_IP, PDU_DRIVER, PDU_OUTLET, MUX_DRIVER, MUX_PORT)"
}

# Source rig.env (KEY=value lines) into env vars for this process.
foreach ($line in Get-Content $rigConfig) {
    if ($line -match '^\s*#' -or $line -match '^\s*$') { continue }
    if ($line -match '^\s*([A-Z_][A-Z0-9_]*)\s*=\s*(.*?)\s*$') {
        Set-Item -Path "env:$($Matches[1])" -Value $Matches[2]
    }
}

if (-not $env:PRINTER_IP) { Write-Error 'PRINTER_IP must be set in rig.env' }
if (-not $env:PDU_DRIVER) { Write-Error 'PDU_DRIVER must be set in rig.env' }
if (-not $env:MUX_DRIVER) { Write-Error 'MUX_DRIVER must be set in rig.env' }

function Run-Pdu([string]$verb) {
    $script = Join-Path $here "pdu\$($env:PDU_DRIVER).ps1"
    & $script $verb $($env:PDU_OUTLET ?? '0')
}

function Run-Mux([string]$verb) {
    $script = Join-Path $here "mux\$($env:MUX_DRIVER).ps1"
    & $script $verb $($env:MUX_PORT ?? '0')
}

Write-Host ':: powering off'
Run-Pdu 'off'
Start-Sleep -Seconds 5

Write-Host ':: switching eMMC mux back to printer'
Run-Mux 'to-printer'

Write-Host ':: powering on'
Run-Pdu 'on'

Write-Host ":: waiting for SSH on $($env:PRINTER_IP)"
$deadline = [DateTime]::UtcNow.AddSeconds(300)
while ([DateTime]::UtcNow -lt $deadline) {
    try {
        $tcp = New-Object System.Net.Sockets.TcpClient
        $iar = $tcp.BeginConnect($env:PRINTER_IP, 22, $null, $null)
        $ok = $iar.AsyncWaitHandle.WaitOne(2000, $false)
        if ($ok -and $tcp.Connected) {
            $tcp.EndConnect($iar) | Out-Null
            $tcp.Close()
            Write-Host ':: rig reset complete'
            exit 0
        }
        $tcp.Close()
    }
    catch {
        # Connection refused / timed out — keep polling.
    }
    Start-Sleep -Seconds 5
}
Write-Error "printer at $($env:PRINTER_IP) did not come up within 300s"
