param([switch]$PostLoadSafe)
$ErrorActionPreference = 'Stop'
$syncRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $syncRoot 'radar_common.ps1')

# v1.18.42: mnm_nodes.csv stays immutable and complete on disk.
# Save-specific completion is applied to progress/runtime memory only.

$logPath = Join-Path $syncRoot 'bootstrap.log'
$startedPath = Join-Path $syncRoot 'bootstrap_started.txt'
$sourcePath = Join-Path $syncRoot 'MnMChestSaveSync.cs'
$exePath = Join-Path $syncRoot 'MnMChestSaveSync.exe'
$compileLog = Join-Path $syncRoot 'compile.log'
$consoleLog = Join-Path $syncRoot 'sync_console.log'
$errorPath = Join-Path $syncRoot 'bootstrap_error.txt'

function Log([string]$text) { Write-RadarLog $logPath $text }

function Set-MasterSwitchLanguage([string]$syncRoot, [string]$radarLang) {
    # v1.17 single-folder proxy runs this BEFORE main_original.dll is loaded.
    # The upstream FR/EN selector storage has two fixed 4-wchar slots at file
    # offsets 0x8337C and 0x83384. v1.15 repurposed those slots for the runtime
    # master switch but hard-coded Simplified Chinese. Keep the exact same UI/
    # click logic and change only those display slots to match the active radar language.
    $dllsRoot = Split-Path -Parent $syncRoot
    $corePath = Join-Path $dllsRoot 'main_original.dll'
    if (-not (Test-Path -LiteralPath $corePath)) {
        throw ('Radar core not found for master-switch localization: ' + $corePath)
    }

    switch ($radarLang) {
        'fr'    { $offText='NON'; $onText='OUI' }
        'zh-cn' { $offText='关';  $onText='开' }
        'zh-tw' { $offText='關';  $onText='開' }
        default { $offText='OFF'; $onText='ON' }
    }

    function Make-SwitchSlot([string]$s) {
        $enc = New-Object System.Text.UnicodeEncoding($false,$false)
        $raw = $enc.GetBytes($s + [char]0)
        if ($raw.Length -gt 8) { throw ('Master-switch label too long: ' + $s) }
        $buf = New-Object byte[] 8
        [Array]::Copy($raw,0,$buf,0,$raw.Length)
        return $buf
    }

    $allowed = @{}
    foreach ($pair in @(
        @('OFF','ON'), @('NON','OUI'), @('关','开'), @('關','開'),
        @('FR','EN')
    )) {
        $a = Make-SwitchSlot $pair[0]
        $c = Make-SwitchSlot $pair[1]
        $allowed[([BitConverter]::ToString($a)+'|'+[BitConverter]::ToString($c))] = $true
    }

    $fs = [IO.File]::Open($corePath,[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::Read)
    try {
        if ($fs.Length -ne 660480) { throw ('Unexpected radar core size: ' + $fs.Length) }
        $curOff = New-Object byte[] 8
        $curOn  = New-Object byte[] 8
        $fs.Position = 0x8337C; if ($fs.Read($curOff,0,8) -ne 8) { throw 'Unable to read OFF label slot.' }
        $fs.Position = 0x83384; if ($fs.Read($curOn,0,8) -ne 8)  { throw 'Unable to read ON label slot.' }
        $sig = [BitConverter]::ToString($curOff)+'|'+[BitConverter]::ToString($curOn)
        if (-not $allowed.ContainsKey($sig)) {
            throw ('Unexpected master-switch slot signature; refusing binary edit: ' + $sig)
        }
        $newOff = Make-SwitchSlot $offText
        $newOn  = Make-SwitchSlot $onText
        $fs.Position = 0x8337C; $fs.Write($newOff,0,8)
        $fs.Position = 0x83384; $fs.Write($newOn,0,8)
        $fs.Flush()
    }
    finally { $fs.Dispose() }
    Log ("Master switch localized: radar='"+$radarLang+"' labels='"+$offText+"/"+$onText+"'")
}

$bootstrapMutex=New-Object Threading.Mutex($false,('Local\DSWorldRadar_Bootstrap_'+(Get-RadarInstallKey $syncRoot)))
$bootstrapOwned=$false
try {
    try{$bootstrapOwned=$bootstrapMutex.WaitOne(0)}catch [Threading.AbandonedMutexException]{$bootstrapOwned=$true}
    if(-not $bootstrapOwned){Log 'Bootstrap already running; duplicate entry skipped.';return}
    $readyPath=Join-Path $syncRoot 'bootstrap_ready.json'
    Remove-Item -LiteralPath $readyPath -Force -ErrorAction SilentlyContinue
    try{
        $ownedScripts=@('live_chest_watcher.ps1','reload_watcher.ps1','reload_sync_worker.ps1')|ForEach-Object {Join-Path $syncRoot $_}
        $stale=@(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction Stop|Where-Object {$_.ProcessId -ne $PID -and $_.CommandLine})
        foreach($sp in $stale){foreach($ownedScript in $ownedScripts){
            if(Test-RadarWatcherCommandLine $sp.CommandLine $ownedScript){
                Stop-Process -Id ([int]$sp.ProcessId) -Force -ErrorAction Stop
                Log ('Stopped previous process for this installation. pid='+$sp.ProcessId)
                break
            }
        }}
    }catch{Log ('Previous watcher cleanup could not complete: '+$_.Exception.Message)}
    # Exact obsolete MOD-generated paths only; saves and user radar settings are excluded.
    foreach($obsolete in @('reload_sync_worker.ps1','reload_notify.txt','reload_sync_running.flag','reload_sync_last.txt','cache\actor_completed_chests.txt')){
        $oldPath=Join-Path $syncRoot $obsolete
        if(Test-Path -LiteralPath $oldPath){Remove-Item -LiteralPath $oldPath -Force -ErrorAction SilentlyContinue}
    }
    Set-Content -LiteralPath $startedPath -Value (Get-Date).ToString('O') -Encoding ASCII
    if (Test-Path -LiteralPath $errorPath) { Remove-Item -LiteralPath $errorPath -Force -ErrorAction SilentlyContinue }
    Log 'DSWorldRadar 1.0.6 bootstrap started: 11 languages + save-aware runtime completion.'

    # Resolve the saved game language before the native core reads its UI strings.
    . (Join-Path $syncRoot 'radar_language.ps1')
    $resolvedRadarLang = Apply-AutoRadarLanguage $syncRoot
    if ($PostLoadSafe) {
        # Lua fallback runs only after main_original.dll has already been loaded by the proxy.
        # Never try to rewrite the mapped DLL on this late path; doing so can abort bootstrap
        # before save synchronization on Windows.  The normal proxy/preload path still
        # localizes the switch exactly as before.
        Log 'PostLoadSafe bootstrap: skipping main_original.dll switch-label binary edit.'
    }
    else {
        Set-MasterSwitchLanguage $syncRoot $resolvedRadarLang
    }

    if (-not (Test-Path -LiteralPath $sourcePath)) {
        throw "Missing source file: $sourcePath"
    }

    $windir = $env:WINDIR
    $candidates = @(
        (Join-Path $windir 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'),
        (Join-Path $windir 'Microsoft.NET\Framework\v4.0.30319\csc.exe')
    )
    $csc = $candidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
    if (-not $csc) {
        throw 'Microsoft .NET Framework C# compiler (csc.exe) was not found.'
    }

    $hashStampPath = Join-Path $syncRoot 'compiled_source.sha256'
    $sourceHash = (Get-FileHash -LiteralPath $sourcePath -Algorithm SHA256).Hash.ToLowerInvariant()

    $compiledHash = ''
    if (Test-Path -LiteralPath $hashStampPath) {
        try {
            $compiledHash = (Get-Content -LiteralPath $hashStampPath -Raw).Trim().ToLowerInvariant()
        }
        catch {
            $compiledHash = ''
        }
    }

    $needCompile = -not (Test-Path -LiteralPath $exePath)
    if (-not $needCompile) {
        $needCompile = ($compiledHash -ne $sourceHash)
    }


    if ($needCompile) {
        Log ("Compiling helper with: " + $csc)
        Log ("Source SHA256: " + $sourceHash)

        if (Test-Path -LiteralPath $exePath) {
            Remove-Item -LiteralPath $exePath -Force -ErrorAction SilentlyContinue
        }

        $compilerArgs = @(
            '/nologo',
            '/optimize+',
            '/target:exe',
            '/platform:x64',
            '/reference:System.Core.dll',
            '/reference:System.Xml.dll',
            ("/out:" + $exePath),
            $sourcePath
        )
        $compileOutput = & $csc @compilerArgs 2>&1
        $compileOutput | Out-File -LiteralPath $compileLog -Encoding UTF8

        if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $exePath)) {
            throw ("C# helper compilation failed. ExitCode=" + $LASTEXITCODE + ". See compile.log")
        }

        Set-Content -LiteralPath $hashStampPath -Value $sourceHash -Encoding ASCII
        Log 'Helper compilation completed and source hash recorded.'
    }
    else {
        Log ("Existing helper matches source SHA256: " + $sourceHash)
    }


    # Current DSWorldRadar uses the direct DSC_<SaveID> catalog.
    # No PAK extraction/Oodle step is required in normal startup or live synchronization.
    Log 'Direct SaveID catalog path active; PAK/Oodle extraction is not used.'

    Log 'Starting 0.5a direct-catalog fast full-state synchronization.'

    # Windows PowerShell 5.1 otherwise may decode UTF-8 child-process output
    # using the active OEM code page, producing mojibake in sync_console.log.
    try {
        $null = & "$env:SystemRoot\System32\chcp.com" 65001
        $OutputEncoding = New-Object System.Text.UTF8Encoding($false)
        [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
    }
    catch {
        Log ('Unable to switch console to UTF-8: ' + $_.Exception.Message)
    }

    $runOutput = & $exePath '--in-game' '--fast-seed' 2>&1
    $exitCode = $LASTEXITCODE
    $runOutput | Out-File -LiteralPath $consoleLog -Encoding UTF8
    Log ("Save synchronization finished. ExitCode=" + $exitCode)
    if ($exitCode -ne 0) {
        throw ("MnMChestSaveSync.exe returned ExitCode=" + $exitCode + ". See sync_console.log or sync_error.txt")
    }

    Log 'Fast startup reconciliation completed; exact delta baseline is already seeded.'

    # v3.3: keep a tiny hidden watcher alive during this game session.
    # It tails UE4SS.log and runs a reconcile sync whenever MnMRadar observes a save/world reload.
    $watcherPath = Join-Path $syncRoot 'reload_watcher.ps1'
    if (Test-Path -LiteralPath $watcherPath) {
        $psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        if (-not (Test-Path -LiteralPath $psExe)) { $psExe = 'powershell.exe' }
        $watchArgs = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $watcherPath + '"'
        Start-Process -FilePath $psExe -ArgumentList $watchArgs -WindowStyle Hidden | Out-Null
        Log 'Reload safety watcher start requested.'
    }
    else {
        throw 'Required reload request watcher script is missing.'
    }

    # DSWorldGuide 0.4n: start the actual live save-file watcher with area-quest delta support.
    # Previous packages installed live_chest_watcher.ps1 but the bootstrap only
    # launched reload_watcher.ps1, so in-session save writes were never observed.
    $liveWatcherPath = Join-Path $syncRoot 'live_chest_watcher.ps1'
    if (Test-Path -LiteralPath $liveWatcherPath) {
        $psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        if (-not (Test-Path -LiteralPath $psExe)) { $psExe = 'powershell.exe' }

        $liveStdout = Join-Path $syncRoot 'live_chest_watcher.stdout.log'
        $liveStderr = Join-Path $syncRoot 'live_chest_watcher.stderr.log'
        try {
            Remove-Item -LiteralPath $liveStdout -Force -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath $liveStderr -Force -ErrorAction SilentlyContinue
        } catch { }

        $liveArgs = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $liveWatcherPath + '"'
        try {
            $liveProc = Start-Process -FilePath $psExe -ArgumentList $liveArgs -WindowStyle Hidden `
                -RedirectStandardOutput $liveStdout -RedirectStandardError $liveStderr -PassThru
            Log ('DSWorldRadar live watcher launched. powershellPid=' + $liveProc.Id)
            Start-Sleep -Milliseconds 700
            try { $liveProc.Refresh() } catch { }
            if ($liveProc.HasExited) {
                Log ('ERROR: live watcher exited during launch. exit=' + $liveProc.ExitCode +
                     '; inspect live_chest_watcher.stderr.log')
                throw 'Live watcher exited during launch.'
            }
            else {
                Log 'DSWorldRadar live watcher confirmed alive after launch grace period.'
            }
        }
        catch {
            Log ('ERROR: live watcher Start-Process failed: ' + $_.Exception.Message)
            throw
        }
    }
    else {
        throw 'Required live save-file watcher script is missing.'
    }

    $gameNow=Get-Process -Name 'DSClient-Win64-Shipping' -ErrorAction Stop|Sort-Object StartTime -Descending|Select-Object -First 1
    $ready=@{version='1.0.6';game_pid=$gameNow.Id;watcher_pid=$liveProc.Id;watcher_sha256=(Get-FileHash -LiteralPath $liveWatcherPath -Algorithm SHA256).Hash.ToLowerInvariant()}|ConvertTo-Json -Compress
    if(-not (Write-RadarTextAtomic $readyPath $ready)){throw 'Unable to publish bootstrap launch status.'}
}
catch {
    $detail = $_ | Out-String
    Set-Content -LiteralPath $errorPath -Value $detail -Encoding UTF8
    Log ("ERROR: " + $_.Exception.Message)
}

finally {
    if($bootstrapOwned){try{$bootstrapMutex.ReleaseMutex()}catch{}}
    $bootstrapMutex.Dispose()
}
