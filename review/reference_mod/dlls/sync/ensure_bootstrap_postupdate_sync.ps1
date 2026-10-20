param()
$ErrorActionPreference = 'Stop'
$syncRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $syncRoot 'radar_common.ps1')
$bootstrap = Join-Path $syncRoot 'bootstrap.ps1'
$started = Join-Path $syncRoot 'bootstrap_started.txt'
$bootError = Join-Path $syncRoot 'bootstrap_error.txt'
$fastChest = Join-Path $syncRoot 'cache\fast_live_chest_snapshot.txt'
$fastSlot = Join-Path $syncRoot 'cache\fast_live_slot.txt'
$authorityPath=Join-Path $syncRoot 'cache\authority_state.v1.txt'
$selfLog = Join-Path $syncRoot 'bootstrap_selfheal.log'

function Log([string]$s) { Write-RadarLog $selfLog $s }
function AgeSeconds([string]$p) {
    if (-not (Test-Path -LiteralPath $p)) { return [double]::PositiveInfinity }
    try { return ((Get-Date).ToUniversalTime() - (Get-Item -LiteralPath $p).LastWriteTimeUtc).TotalSeconds } catch { return [double]::PositiveInfinity }
}

$startedAge = AgeSeconds $started
$chestAge = AgeSeconds $fastChest
$slotAge = AgeSeconds $fastSlot
$hasError = Test-Path -LiteralPath $bootError
Log ("SYNC_ENSURE enter startedAge={0:N1}s chestAge={1:N1}s slotAge={2:N1}s error={3}" -f $startedAge,$chestAge,$slotAge,$hasError)

# A genuinely successful proxy/preload bootstrap has BOTH a fresh started marker and
# fresh live-cache output.  A fresh marker by itself is not enough: bootstrap writes
# it before later steps and a failure can otherwise look healthy.
if (($startedAge -lt 25) -and ((AgeSeconds $authorityPath) -lt 25) -and (-not $hasError) -and (Test-RadarBootstrapReady $syncRoot)) {
    Log 'Proxy bootstrap already healthy; synchronous fallback not needed.'
    exit 0
}

if (-not (Test-Path -LiteralPath $bootstrap)) {
    Log ('FATAL missing bootstrap: ' + $bootstrap)
    exit 2
}

Log 'Running bootstrap.ps1 synchronously in PostLoadSafe mode.'
try {
    & $bootstrap -PostLoadSafe
}
catch {
    Log ('Synchronous bootstrap threw: ' + $_.Exception.Message)
    exit 3
}

$startedAge2 = AgeSeconds $started
$chestAge2 = AgeSeconds $fastChest
$slotAge2 = AgeSeconds $fastSlot
$hasError2 = Test-Path -LiteralPath $bootError
Log ("SYNC_ENSURE return startedAge={0:N1}s chestAge={1:N1}s slotAge={2:N1}s error={3}" -f $startedAge2,$chestAge2,$slotAge2,$hasError2)

if ($hasError2) { exit 4 }
if ((AgeSeconds $authorityPath) -gt 40) { exit 5 }
if (-not (Test-RadarBootstrapReady $syncRoot)) { exit 6 }
exit 0
