param([string]$SourceRoot,[string]$TracePath,[string]$OutputPath)
$ErrorActionPreference='Stop'
. (Join-Path $SourceRoot 'dlls/sync/radar_common.ps1')
$checks=New-Object Collections.Generic.List[object]
$script:messages=New-Object Collections.Generic.List[string]
$script:bursts=New-Object Collections.Generic.List[object]
function Check($name,$ok){$checks.Add(@{name=$name;passed=[bool]$ok});if(-not $ok){throw $name}}
function Log([string]$message){$script:messages.Add($message)}
foreach($pair in @(
    @('reload_watcher.ps1',@('Get-ActiveUE4SSLog','Read-ReloadLogLines','Process-ReloadLogLine','Request-Runtime161Burst','Start-ReloadSync')),
    @('live_chest_watcher.ps1',@('Consume-Runtime161BurstRequest','Service-StartupStateRestore'))
)){
    $path=Join-Path $SourceRoot ('dlls/sync/'+$pair[0]);$tokens=$null;$errors=$null
    $ast=[Management.Automation.Language.Parser]::ParseFile($path,[ref]$tokens,[ref]$errors)
    if($errors.Count){throw ($errors|Out-String)}
    foreach($name in $pair[1]){
        $fn=@($ast.FindAll({param($a)$a -is [Management.Automation.Language.FunctionDefinitionAst] -and $a.Name -eq $name},$true))
        if($fn.Count -ne 1){throw ('Function resolution: '+$name)}
        . ([scriptblock]::Create($fn[0].Extent.Text))
    }
}
function Arm-Runtime161Burst([string]$reason,[bool]$capture){$script:bursts.Add(@{reason=$reason;capture=$capture})}
function Reapply-CurrentSaveChestSnapshot{return $script:memoryReady}
function Set-RuntimeAreaStateFromIdSet{return $script:memoryReady}
function Read-FastAreaSnapshotMap{return @{}}
$temp=Join-Path ([IO.Path]::GetTempPath()) ('dswr-reload-'+[guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory((Join-Path $temp 'ue4ss'))|Out-Null
$win64=$temp
$script:gameStartUtc=[DateTime]::UtcNow.AddMinutes(-1)
$script:gameStartEpoch=[long][Math]::Floor(($script:gameStartUtc-[DateTime]'1970-01-01').TotalSeconds)
$epoch=[long][Math]::Floor(([DateTime]::UtcNow-[DateTime]'1970-01-01').TotalSeconds)
$runtimeBurstRequestPath=Join-Path $temp 'burst.request'
$script:runtime161BurstRequestPath=$runtimeBurstRequestPath
$saveReloadRequestPath=Join-Path $temp 'reload.request'
try{
    $flat=Join-Path $temp 'UE4SS.log';$nested=Join-Path $temp 'ue4ss/UE4SS.log'
    [IO.File]::WriteAllText($flat,'stale flat log')
    [IO.File]::SetLastWriteTimeUtc($flat,[DateTime]::UtcNow.AddDays(-1))
    [IO.File]::WriteAllText($nested,'current loader log')
    Check 'current nested UE4SS log wins over stale flat log' ((Get-ActiveUE4SSLog) -eq $nested)
    Remove-Item -LiteralPath $nested
    Check 'old-session logs are not replayed as current transitions' ($null -eq (Get-ActiveUE4SSLog))
    [IO.File]::WriteAllText($flat,'current flat layout')
    Check 'legacy flat UE4SS layout remains supported' ((Get-ActiveUE4SSLog) -eq $flat)

    $streamPath=Join-Path $temp 'partial.log';$state=@{Offset=0L;Partial='';Decoder=$null}
    [IO.File]::WriteAllText($streamPath,'[MnMRadar] PlayerController tro')
    Check 'incomplete controller line is buffered' (@(Read-ReloadLogLines $streamPath $state).Count -eq 0)
    [IO.File]::AppendAllText($streamPath,"uve`r`n")
    $lines=@(Read-ReloadLogLines $streamPath $state)
    Check 'split controller signal is reconstructed exactly once' ($lines.Count -eq 1 -and $lines[0] -ceq '[MnMRadar] PlayerController trouve' -and @(Read-ReloadLogLines $streamPath $state).Count -eq 0)
    [IO.File]::WriteAllText($streamPath,"new log`n")
    $lines=@(Read-ReloadLogLines $streamPath $state)
    Check 'truncation resets the tail offset and decoder' ($lines.Count -eq 1 -and $lines[0] -ceq 'new log')

    $utfPath=Join-Path $temp 'utf8.log';$state=@{Offset=0L;Partial='';Decoder=$null}
    $long=('a'*65535)+[char]0x4E2D+"`n"
    [IO.File]::WriteAllText($utfPath,$long,(New-Object Text.UTF8Encoding($false)))
    $first=@(Read-ReloadLogLines $utfPath $state);$second=@(Read-ReloadLogLines $utfPath $state)
    Check 'UTF-8 character crossing a read boundary is preserved' ($first.Count -eq 0 -and $second.Count -eq 1 -and $second[0] -ceq $long.TrimEnd([char]10))

    Request-Runtime161Burst 'test-transition' 'transition'
    [IO.File]::AppendAllText($runtimeBurstRequestPath,"phase=completion;source=lua;epoch=$epoch`n")
    Consume-Runtime161BurstRequest
    Check 'transition and completion requests cannot overwrite each other' ($script:bursts.Count -eq 2 -and $script:bursts[0].capture -and -not $script:bursts[1].capture)
    [IO.File]::WriteAllText(($runtimeBurstRequestPath+'.drain'),"phase=transition;source=claimed;epoch=$epoch`n")
    [IO.File]::WriteAllText($runtimeBurstRequestPath,"phase=world-ready;source=new;epoch=$epoch`n")
    Consume-Runtime161BurstRequest;Consume-Runtime161BurstRequest
    Check 'request appended after a claim remains available' ($script:bursts.Count -eq 4 -and $script:bursts[2].capture -and -not $script:bursts[3].capture)

    $before=$script:bursts.Count
    [IO.File]::WriteAllText($runtimeBurstRequestPath,('phase=transition;epoch='+($script:gameStartEpoch-1)+"`n"))
    Consume-Runtime161BurstRequest
    Check 'previous-session burst cannot arm a fresh game transition' ($script:bursts.Count -eq $before)
    [IO.File]::WriteAllText($runtimeBurstRequestPath,"phase=transition;source=legacy`n")
    Consume-Runtime161BurstRequest
    Check 'untagged legacy burst cannot arm a fresh transition' ($script:bursts.Count -eq $before)

    $script:seenWorldController=$false;$script:pendingTransitionSync=$false;$script:pendingWorldReadyUtc=[DateTime]::MinValue
    Process-ReloadLogLine '[MnMRadar] PlayerController trouve'
    Process-ReloadLogLine '[MnMRadar][diag] PlayerController introuvable'
    Check 'controller loss arms a pending transition' $script:pendingTransitionSync
    Process-ReloadLogLine '[MnMRadar] PlayerController trouve'
    Process-ReloadLogLine '[MnMRadar][ask] 161 mini-jeux interroges'
    $queued=@(Take-RadarEventQueue $saveReloadRequestPath)
    Check 'destination query queues reload and confirms the trigger' (-not $script:pendingTransitionSync -and $queued.Count -eq 1 -and $queued[0].Contains('Runtime161_query_ready'))

    $realReloadPath=$saveReloadRequestPath;$saveReloadRequestPath=Join-Path $temp 'blocked'
    [IO.Directory]::CreateDirectory($saveReloadRequestPath)|Out-Null
    Process-ReloadLogLine '[MnMRadar] Partie rechargee : test'
    Check 'reload publication failure retains pending transition' ($script:pendingTransitionSync -and $script:pendingWorldReadyUtc -ne [DateTime]::MinValue)
    $saveReloadRequestPath=$realReloadPath

    $script:seenWorldController=$false;$script:pendingTransitionSync=$false;$script:pendingWorldReadyUtc=[DateTime]::MinValue
    $state=@{Offset=0L;Partial='';Decoder=$null}
    if(Test-Path -LiteralPath $TracePath){
        while($state.Offset -lt (Get-Item -LiteralPath $TracePath).Length){
            foreach($line in @(Read-ReloadLogLines $TracePath $state)){Process-ReloadLogLine $line}
        }
        $queued=@(Take-RadarEventQueue $saveReloadRequestPath)
        Check 'actual 1.0.5 game trace now emits a reload request' ($queued.Count -eq 1 -and $queued[0].Contains('Runtime161_query_ready'))
    }

    $script:startupStateRestorePending=$true;$script:startupStateRestoreNextUtc=[DateTime]::MinValue
    $script:saveTransitionPending=$false;$script:authoritySnapshot=@{Slot='test.db'};$script:memoryReady=$false
    Service-StartupStateRestore
    Check 'startup without a vector stays pending without a blocking loop' $script:startupStateRestorePending
    $script:memoryReady=$true;$script:startupStateRestoreNextUtc=[DateTime]::MinValue
    Service-StartupStateRestore
    Check 'late startup vector completes the retained full-state restore' (-not $script:startupStateRestorePending)
    $script:startupStateRestorePending=$true;$script:startupStateRestoreNextUtc=[DateTime]::MinValue;$script:saveTransitionPending=$true
    Service-StartupStateRestore
    Check 'startup restore waits during an unconfirmed save transition' $script:startupStateRestorePending
    @{passed=$true;checks=$checks;trace=$script:messages;runtime=$PSVersionTable.PSVersion.ToString();source_hashes=@{
        reload=(Get-FileHash (Join-Path $SourceRoot 'dlls/sync/reload_watcher.ps1') -Algorithm SHA256).Hash.ToLowerInvariant()
        watcher=(Get-FileHash (Join-Path $SourceRoot 'dlls/sync/live_chest_watcher.ps1') -Algorithm SHA256).Hash.ToLowerInvariant()
    };game_runtime_executed=$false}|ConvertTo-Json -Depth 6|Set-Content -LiteralPath $OutputPath -Encoding utf8
    Write-Output ('PASS: '+$checks.Count+' reload/startup checks')
}finally{Remove-Item -LiteralPath $temp -Recurse -Force}
