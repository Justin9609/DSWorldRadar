$ErrorActionPreference = 'Continue'
$syncRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $syncRoot 'radar_common.ps1')
$watchLog = Join-Path $syncRoot 'reload_watcher.log'
$enabledPath = Join-Path $syncRoot 'reload_on_load.txt'
$saveReloadRequestPath = Join-Path (Join-Path $syncRoot 'cache') 'save_reload.request'
$runtimeBurstRequestPath = Join-Path (Join-Path $syncRoot 'cache') 'runtime161_burst.request'

function Log([string]$text) { Write-RadarLog $watchLog $text }

function Resolve-Win64Root([string]$startPath) {
    try {
        $d = Get-Item -LiteralPath $startPath -ErrorAction Stop
        if (-not $d.PSIsContainer) { $d = $d.Directory }
        for ($i = 0; $i -lt 10 -and $d; $i++) {
            if (Test-Path -LiteralPath (Join-Path $d.FullName 'DSClient-Win64-Shipping.exe')) { return $d.FullName }
            $d = $d.Parent
        }
    } catch { }
    throw ('Unable to resolve Win64 root from ' + $startPath)
}

$mutex = New-Object System.Threading.Mutex($false, ('Local\DSWorldRadar_ReloadWatcher_'+(Get-RadarInstallKey $syncRoot)))
$hasMutex = $false
try {
    try { $hasMutex = $mutex.WaitOne(0, $false) } catch [Threading.AbandonedMutexException] { $hasMutex = $true } catch { $hasMutex = $false }
    if (-not $hasMutex) { exit 0 }

    if ((Test-Path -LiteralPath $enabledPath) -and ((Get-Content -LiteralPath $enabledPath -Raw).Trim() -eq '0')) {
        Log 'Watcher disabled by reload_on_load.txt.'
        exit 0
    }

    $win64 = Resolve-Win64Root $syncRoot
    $game = Get-Process -Name 'DSClient-Win64-Shipping' -ErrorAction Stop | Sort-Object StartTime -Descending | Select-Object -First 1
    $script:gameStartUtc = $game.StartTime.ToUniversalTime()

    function Get-ActiveUE4SSLog {
        try {
            # UE4SS 3.x in the shipped layout writes under Win64/ue4ss.
            # Retain the older flat layout, but ignore files from earlier sessions.
            $items = @(foreach ($directory in @((Join-Path $win64 'ue4ss'), $win64)) {
                Get-ChildItem -LiteralPath $directory -Filter 'UE4SS*.log' -File -ErrorAction SilentlyContinue |
                    Where-Object { $_.LastWriteTimeUtc -ge $script:gameStartUtc }
            })
            $item = $items | Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1
            if ($item) { return $item.FullName }
        }
        catch { }
        return $null
    }

    function Read-ReloadLogLines([string]$path,[hashtable]$state) {
        $fs = $null
        try {
            $fs = New-Object IO.FileStream($path,[IO.FileMode]::Open,[IO.FileAccess]::Read,([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
            if ($null -eq $state.Decoder -or $fs.Length -lt [long]$state.Offset) {
                $state.Offset = 0L
                $state.Partial = ''
                $state.Decoder = [Text.Encoding]::UTF8.GetDecoder()
            }
            $null = $fs.Seek([long]$state.Offset,[IO.SeekOrigin]::Begin)
            $buffer = New-Object byte[] 65536
            $count = $fs.Read($buffer,0,$buffer.Length)
            if ($count -eq 0) { return @() }
            $chars = New-Object char[] ([Text.Encoding]::UTF8.GetMaxCharCount($count))
            $used = $state.Decoder.GetChars($buffer,0,$count,$chars,0,$false)
            $state.Offset += $count
            $text = [string]$state.Partial + (New-Object string($chars,0,$used))
            $lastNewline = $text.LastIndexOf("`n")
            if ($lastNewline -lt 0) { $state.Partial = $text; return @() }
            $state.Partial = $text.Substring($lastNewline+1)
            return @($text.Substring(0,$lastNewline).Split([char]10) | ForEach-Object { $_.TrimEnd([char]13) })
        } finally { if ($null -ne $fs) { $fs.Dispose() } }
    }

    function Process-ReloadLogLine([string]$line) {
        if ([string]::IsNullOrWhiteSpace($line)) { return }
        if ($line.Contains('[MnMRadar] PlayerController trouve')) {
            Request-Runtime161Burst 'PlayerController_found' 'world-ready'
            if ($script:pendingTransitionSync) { $script:pendingWorldReadyUtc = [DateTime]::UtcNow }
            $script:seenWorldController = $true
            return
        }
        if ($script:seenWorldController -and ($line.Contains('EmptyTransitionMap') -or $line.Contains('[MnMRadar][diag] PlayerController introuvable'))) {
            Request-Runtime161Burst 'World_transition' 'transition'
            $script:pendingTransitionSync = $true
            $script:pendingWorldReadyUtc = [DateTime]::MinValue
            Log 'Cross-save/travel transition armed; helper waits for destination runtime.'
            return
        }
        if ($script:pendingTransitionSync -and $line.Contains('[MnMRadar][ask] 161 mini-jeux interroges')) {
            Request-Runtime161Burst 'Runtime161_query_ready' 'world-ready'
            if (Start-ReloadSync 'Runtime161_query_ready') {
                $script:pendingTransitionSync = $false
                $script:pendingWorldReadyUtc = [DateTime]::MinValue
            }
            return
        }
        if ($line.Contains('[MnMRadar] Partie rechargee :')) {
            Request-Runtime161Burst 'MnMRadar_Partie_rechargee' 'world-ready'
            if (-not (Start-ReloadSync 'MnMRadar_Partie_rechargee')) {
                $script:pendingTransitionSync = $true
                $script:pendingWorldReadyUtc = [DateTime]::UtcNow
            }
        }
    }

    function Request-Runtime161Burst([string]$reason,[string]$phase) {
        try {
            $dir=Split-Path -Parent $runtimeBurstRequestPath
            if(-not (Test-Path -LiteralPath $dir)){[void](New-Item -ItemType Directory -Path $dir -Force)}
            $epoch=[long][Math]::Floor(([DateTime]::UtcNow-[DateTime]'1970-01-01').TotalSeconds)
            $payload=('time={0:O};reason={1};phase={2};epoch={3}' -f (Get-Date),$reason.Replace(';','_'),$phase,$epoch)
            [IO.File]::AppendAllText($runtimeBurstRequestPath,($payload+"`n"),(New-Object Text.UTF8Encoding($false)))
            Log ('Runtime161 burst requested. phase=' + $phase + '; reason=' + $reason)
        } catch { Log ('Runtime161 burst request failed: ' + $_.Exception.Message) }
    }

    function Start-ReloadSync([string]$reason) {
    # Coalescing a request never discards a rapid second transition or competes
    # with an already-running helper. The live watcher is the only dispatcher.
    $payload=('time={0:O};reason={1}' -f (Get-Date),$reason.Replace(';','_'))
    if(Write-RadarTextAtomic $saveReloadRequestPath $payload){
        Log ('Reload sync queued for live watcher. reason='+$reason)
    }else{Log ('Reload sync request write failed; transition remains pending. reason='+$reason);return $false}
    return $true
}

    $currentLog = $null
    $tailState = @{Offset=0L;Partial='';Decoder=$null}
    $seenWorldController = $false
    $pendingTransitionSync = $false
    $pendingWorldReadyUtc = [DateTime]::MinValue
    $lastProcessCheckUtc = [DateTime]::MinValue
    $lastLogDiscoveryUtc = [DateTime]::MinValue
    Log ('DSWorldRadar 1.0.6 reload request watcher started. Win64=' + $win64)

    while ($true) {
        $nowUtc = [DateTime]::UtcNow
        # Process existence changes slowly; do not query the process table every 500 ms.
        if (($nowUtc - $lastProcessCheckUtc).TotalSeconds -ge 2) {
            $lastProcessCheckUtc = $nowUtc
            if ($game.HasExited) {
                Log 'Game process ended; watcher exits.'
                break
            }
        }

        # Timestamped UE4SS log names change only at launch. Re-discover at most every 5 s;
        # between discoveries, tail the already known file directly.
        $candidate = $currentLog
        if (($nowUtc - $lastLogDiscoveryUtc).TotalSeconds -ge 5) {
            $lastLogDiscoveryUtc = $nowUtc
            $candidate = Get-ActiveUE4SSLog
        }
        if ($candidate -ne $currentLog) {
            $currentLog = $candidate
            $tailState = @{Offset=0L;Partial='';Decoder=$null}
            Log ('Following active UE4SS log: ' + $currentLog)
        }

        if ($null -eq $currentLog -or -not (Test-Path -LiteralPath $currentLog)) {
            Start-Sleep -Milliseconds 500
            continue
        }

        try {
            foreach ($line in @(Read-ReloadLogLines $currentLog $tailState)) {
                Process-ReloadLogLine $line
            }
        }
        catch {
            Log ('Watcher read error: ' + $_.Exception.Message)
        }

        if($pendingTransitionSync -and $pendingWorldReadyUtc -ne [DateTime]::MinValue -and
           ([DateTime]::UtcNow-$pendingWorldReadyUtc).TotalSeconds -ge 1.5){
            Request-Runtime161Burst 'WorldReady_fallback' 'world-ready'
            if(-not (Start-ReloadSync 'WorldReady_fallback')){Start-Sleep -Milliseconds 500;continue}
            $pendingTransitionSync=$false
            $pendingWorldReadyUtc=[DateTime]::MinValue
        }

        Start-Sleep -Milliseconds 500
    }
}
finally {
    if ($hasMutex) { try { $mutex.ReleaseMutex() } catch { } }
    try { $mutex.Dispose() } catch { }
}
