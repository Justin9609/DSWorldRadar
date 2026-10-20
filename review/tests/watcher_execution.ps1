param(
    [Parameter(Mandatory=$true)][string]$WatcherPath,
    [Parameter(Mandatory=$true)][string]$NodesPath,
    [Parameter(Mandatory=$true)][string]$OutputPath,
    [switch]$ExpectOldBug
)
$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path -Parent (Resolve-Path $WatcherPath)) 'radar_common.ps1')
$tokens=$null; $errors=$null
$ast=[System.Management.Automation.Language.Parser]::ParseFile($WatcherPath,[ref]$tokens,[ref]$errors)
if($errors.Count){throw ($errors | Out-String)}

# Execute the shipped function bodies. Only process memory, game-side callbacks,
# and unrelated runtime-profile/translation IO are replaced with in-memory doubles.
$names=@(
    'Reset-ActorCompletionSessionCache','Remember-ActorCompletedId',
    'Get-EffectiveOpenedChestSet','Reconcile-RuntimeChestState',
    'Reapply-CurrentSaveChestSnapshot','Consume-RuntimeCompletionResetRequest',
    'Sync-ImmediateChestCategoryCounts','Service-ActorStrongCompletionGuard',
    'Reassert-ChestIdsByCachedOffsets','Hide-ChestIdsByOffsetCache',
    'Read-IdSetFile','Read-FastChestSnapshotMap','Read-FastAreaSnapshotMap',
    'Read-NodeId','Build-ChestOffsetCache','Build-AreaOffsetCache',
    'Refresh-RadarAuthoritySnapshot','Get-AuthoritativeProfileSlot','Get-SaveProfileKey',
    'Read-CountMap','Get-SaveProfileDir','Write-IdSetFileAtomic','Read-ModLocalNativeChestCount','Write-ModLocalNativeChestCount',
    'Read-NativeWorldCompleteChestCount','Drain-ActorChestEvents','Run-LiveSync','Advance-WatcherChestSnapshotAndGetDelta','Sync-PersistentProfileAuthorityFromHelper'
)
foreach($name in $names){
    $found=@($ast.FindAll({param($a) $a -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $a.Name -eq $name},$true))
    if($found.Count -ne 1){throw "Function resolution failed: $name"}
    . ([scriptblock]::Create($found[0].Extent.Text))
}
$helperBoundaries=@($ast.FindAll({param($a)
    $a -is [System.Management.Automation.Language.IfStatementAst] -and
    $a.Clauses[0].Item1.Extent.Text -eq '$isFastBoundary' -and
    $a.Clauses[0].Item2.Extent.Text.Contains('$script:nativeChestGenerationEpochUtc')
},$true))
if($helperBoundaries.Count -ne 1){throw 'Helper boundary block missing/ambiguous'}
$helperBoundary=[scriptblock]::Create($helperBoundaries[0].Extent.Text)

$script:steps=[Collections.Generic.List[string]]::new()
$script:checks=[Collections.Generic.List[object]]::new()
function Log([string]$text){$script:steps.Add($text)}
function Check([string]$name,[bool]$ok){
    $script:checks.Add(@{name=$name;passed=$ok})
    if(-not $ok){throw "FAILED: $name"}
}
function Get-MnMModuleInfo { return @{Mode='test-memory'} }
function Get-NodeVector($module) { if(-not $script:memoryReady){return $null}; return @{Start=[long]4096;Count=$script:rows.Count;Bytes=$script:memory.Clone()} }
function Get-NodeVectorHeaderInfo($module) { return @{Start=[long]4096;Count=$script:rows.Count} }
function Write-RemoteByte([long]$address,[byte]$value){$script:memory[[int]($address-4096)]=$value;return $true}
function Read-RemoteBytes([long]$address,[int]$length){if($script:remoteStrings.ContainsKey($address)){return ,([byte[]]$script:remoteStrings[$address])};return ,([byte[]]$script:memory[($address-4096)..($address-4096+$length-1)])}

function Hide-ExactNodes {throw 'Unexpected missing runtime node in test'}
function Add-ChestIdsToCurrentProfile {}
function Mark-PressurePuzzleDoneByChestIds {return 0}
function Mark-SliderPuzzleDoneByChestIds {return 0}
function Mark-StatuePuzzleDoneByChestIds {return 0}
function Reconcile-PressurePuzzleStateFromChestAuthority {return $true}
function Capture-BoundaryRuntimeProfiles { $script:steps.Add('capture-destination');return $true }
function Apply-TransientProfileIfValid {throw 'Unexpected fallback'}
function Apply-StaticSliderProfileIfValid {throw 'Unexpected fallback'}
function Reset-ExactAreaCompletionSessionCache {}
function Set-RuntimeAreaStateFromIdSet {return $true}
function Reapply-ExactAreaCompletions {}
function Reset-ProfileStability {}
function Reset-StaticSliderProfileStability {}
function Arm-Runtime161Burst {}
function Patch-RuntimeCompletionCountKey($module,[string]$key,[int]$opened,[int]$total){
    $script:labels[$key]="$opened/$total"; return $true
}

$temp=Join-Path ([IO.Path]::GetTempPath()) ('dswr-crosssave-'+[guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($temp) | Out-Null
$script:fastChestSnapshotPath=Join-Path $temp 'chests.txt'
$script:fastAreaSnapshotPath=Join-Path $temp 'areas.txt'
$script:fastLiveSlotPath=Join-Path $temp 'slot.txt'
$script:runtimeResetRequestPath=Join-Path $temp 'reset.flag'
$script:actorCompletedCachePath=Join-Path $temp 'legacy-actor.txt'
$script:authorityStatePath=Join-Path $temp 'authority_state.v1.txt'
$script:chestCatalogSha256=(Get-FileHash -LiteralPath $NodesPath -Algorithm SHA256).Hash.ToLowerInvariant()
$script:saveProfileRoot=Join-Path $temp 'profiles'
$script:actorEventQueuePath=Join-Path $temp 'actor.queue'
$script:actorResetFlagPath=Join-Path $temp 'lua_reset.flag'
$script:saveReloadRequestPath=Join-Path $temp 'reload.request'
$script:gameStartEpoch=1000L
$script:nativeChestJsonPath=Join-Path $temp 'native.json'
$nativeChestJsonPath=$script:nativeChestJsonPath
$script:gameStartUtc=[DateTime]::UtcNow.AddMinutes(-1)
$syncRoot=$temp;$syncRootForTests=$temp
$script:chestCountPath=Join-Path $temp 'cache/chest_counts.txt'
$script:completionCountPath=Join-Path $temp 'cache/completion_counts.txt'
$chestCountPath=$script:chestCountPath;$completionCountPath=$script:completionCountPath
$runtimeResetRequestPath=$script:runtimeResetRequestPath
$actorResetFlagPath=$script:actorResetFlagPath
$exePath='fake-process-only';$dllsRoot=$temp

$script:rows=@(Import-Csv -LiteralPath $NodesPath | Where-Object {$_.id -like 'DSC_*'})
$target='DSC_11230106'
$another=($script:rows | Where-Object {$_.kind -eq 'chests_grade3' -and $_.id -ne $target} | Select-Object -First 1).id
$script:chestResetIds=@{};$script:chestKindById=@{};$script:chestOffsetCache=@{}
for($i=0;$i -lt $script:rows.Count;$i++){
    $r=$script:rows[$i];$script:chestResetIds[$r.id]=$true
    $script:chestKindById[$r.id]=$r.kind;$script:chestOffsetCache[$r.id]=[long]($i*0x70)
}
$script:chestOffsetCacheVectorStart=[long]4096
$script:chestOffsetCacheVectorCount=$script:rows.Count
$script:template=[byte[]]::new($script:rows.Count*0x70)
$script:remoteStrings=@{};$nodeCoords=@{}
for($i=0;$i -lt $script:rows.Count;$i++){
    $r=$script:rows[$i];$offset=$i*0x70;$addr=[long](0x200000+$i*128)
    $script:remoteStrings[$addr]=[Text.Encoding]::Unicode.GetBytes($r.id)
    [BitConverter]::GetBytes($addr).CopyTo($script:template,$offset)
    [BitConverter]::GetBytes([UInt64]$r.id.Length).CopyTo($script:template,$offset+0x10)
    [BitConverter]::GetBytes([UInt64]$r.id.Length).CopyTo($script:template,$offset+0x18)
    [BitConverter]::GetBytes([double]$r.x).CopyTo($script:template,$offset+0x40)
    [BitConverter]::GetBytes([double]$r.y).CopyTo($script:template,$offset+0x48)
    [BitConverter]::GetBytes([double]$r.z).CopyTo($script:template,$offset+0x50)
    $nodeCoords[$r.id]=@([double]$r.x,[double]$r.y,[double]$r.z)
}
$script:game=@{HasExited=$false}
function Init-Scenario {
    $script:memoryReady=$true
    $script:authoritySnapshot=$null
    $script:saveTransitionPending=$false
    $script:preparedBoundaryRequest=''
    $script:boundaryRestoreRetryAt=[DateTime]::MinValue
    Remove-Item -LiteralPath $script:actorEventQueuePath,($script:actorEventQueuePath+'.drain'),$script:runtimeResetRequestPath -Force -ErrorAction SilentlyContinue

    $script:memory=$script:template.Clone()
    $script:actorCompletedIds=@{};$script:actorStrongGuardUntil=@{};$script:actorCandidateIds=@{}
    $script:pendingHideIds=@{};$script:translationNodeCache=@{};$script:labels=@{}
    $script:actorGenerationPreReset=$false;$script:nativeGenerationPreInvalidated=$false
    $script:lastActorStrongGuardUtc=[DateTime]::MinValue
    $script:nativeChestGenerationEpochUtc=[DateTime]::MinValue
    $script:lastKnownFastSlot='slot-a.db';$script:profileGenerationReadySlot='slot-a.db'
    $script:lastImmediateChestCategorySig=''
    $script:untouched161='known-runtime-destination-state'
    [IO.File]::WriteAllText($script:fastAreaSnapshotPath,'')
    [IO.File]::WriteAllText($script:actorCompletedCachePath,'legacy')
    Write-Snapshot 'slot-a.db' @($target)
}
function Write-Snapshot([string]$slot,[string[]]$exclude){
    [IO.File]::WriteAllText($script:fastLiveSlotPath,$slot)
    $chests=[string[]]@($script:rows.id | Where-Object {$_ -notin $exclude})
    [IO.File]::WriteAllLines($script:fastChestSnapshotPath,$chests)
    $body=@('DSWR_STATE_V1',('revision='+[guid]::NewGuid().ToString('N')),('catalog_sha256='+$script:chestCatalogSha256),('slot_b64='+[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($slot))),('chests='+($chests -join ',')),'areas=') -join "`n"
    if(-not (Write-RadarTextAtomic $script:authorityStatePath $body)){throw 'Test state publication failed'}
    if(-not (Refresh-RadarAuthoritySnapshot)){throw 'Test snapshot rejected'}
}
function Request-Boundary([bool]$generation){
    $bit=if($generation){'1'}else{'0'}
    [IO.File]::WriteAllText($script:runtimeResetRequestPath,"reason=test;generation_reset=$bit")
    Consume-RuntimeCompletionResetRequest
}
function Done([string]$id){return [int]$script:memory[$script:chestOffsetCache[$id]+0x58]}
try {
    Check 'catalog contains 1503 exact chest IDs' ($script:rows.Count -eq 1503 -and $script:chestResetIds.ContainsKey($target))
    Init-Scenario
    Remember-ActorCompletedId $target
    Reapply-CurrentSaveChestSnapshot 'A-opened-before-save' | Out-Null
    Sync-ImmediateChestCategoryCounts 'A-opened' @() | Out-Null
    Check 'A open event hides the new chest before DB update' ((Done $target) -eq 1 -and $script:labels['cat.chests_grade3'] -eq '349/349')
    Write-Snapshot 'slot-b.db' @($target)
    Request-Boundary $true
    Sync-ImmediateChestCategoryCounts 'after-switch' @() | Out-Null
    if($ExpectOldBug){
        Check 'baseline reproduces stale hidden chest after switch' ((Done $target) -eq 1)
        Check 'baseline reproduces incorrect rare 349/349' ($script:labels['cat.chests_grade3'] -eq '349/349')
        Check 'baseline retains source Actor evidence and guard' ($script:actorCompletedIds.ContainsKey($target) -and $script:actorStrongGuardUntil.ContainsKey($target))
    } else {
        Check 'reload-worker boundary restores unopened B chest' ((Done $target) -eq 0)
        Check 'B category immediately returns to 348/349' ($script:labels['cat.chests_grade3'] -eq '348/349')
        Check 'source witnesses and 120-second guard are cleared' ($script:actorCompletedIds.Count -eq 0 -and $script:actorStrongGuardUntil.Count -eq 0)
        Service-ActorStrongCompletionGuard
        Check 'guard cannot hide B chest again' ((Done $target) -eq 0)
        Check 'destination runtime161 state is preserved' ($script:untouched161 -eq 'known-runtime-destination-state')
        Write-Snapshot 'slot-a.db' @()
        Request-Boundary $true
        Check 'return to A restores opened state and count' ((Done $target) -eq 1 -and $script:labels['cat.chests_grade3'] -eq '349/349')

        Init-Scenario
        Remember-ActorCompletedId $target
        Write-Snapshot 'slot-b.db' @($target,$another)
        $isFastBoundary=$true;$reason='test-helper'
        . $helperBoundary
        Check 'helper pre-boundary clears before count/profile phase' ($script:actorCompletedIds.Count -eq 0 -and $script:actorGenerationPreReset)
        $effective=Get-EffectiveOpenedChestSet
        Check 'helper effective set excludes source witness' (-not $effective.Set.ContainsKey($target))
        Remember-ActorCompletedId $another
        Request-Boundary $true
        Check 'queued boundary preserves a new destination open event' ($script:actorCompletedIds.ContainsKey($another) -and (Done $another) -eq 1)
        Check 'queued boundary still restores source-only chest' ((Done $target) -eq 0 -and -not $script:actorGenerationPreReset)

        Init-Scenario
        Remember-ActorCompletedId $target
        Reapply-CurrentSaveChestSnapshot 'same-slot' | Out-Null
        Request-Boundary $false
        Check 'ordinary same-slot travel keeps unsaved open witness' ($script:actorCompletedIds.ContainsKey($target) -and (Done $target) -eq 1)
        Request-Boundary $true
        Check 'same-slot rollback clears evidence and restores chest' (-not $script:actorCompletedIds.ContainsKey($target) -and (Done $target) -eq 0)

        Init-Scenario
        Remember-ActorCompletedId $target
        $script:actorCandidateIds[$target]=$true;$script:pendingHideIds[$target]=$true
        Write-Snapshot 'slot-b.db' @($target)
        Request-Boundary $false
        Check 'slot-change inference clears pending hides and candidates' ($script:actorCompletedIds.Count -eq 0 -and $script:actorCandidateIds.Count -eq 0 -and $script:pendingHideIds.Count -eq 0 -and (Done $target) -eq 0)
    }
    # Retry actual failed memory restores without discarding the request or new events.
    Init-Scenario
    $script:chestOffsetCache.Remove($target)
    $restored=Reapply-CurrentSaveChestSnapshot 'partial-cache'
    Check 'partial chest address cache rebuilds to include new chest' ($restored -and $script:chestOffsetCache.ContainsKey($target))
    $address=[BitConverter]::ToInt64($script:memory,$script:chestOffsetCache[$target])
    $original=$script:remoteStrings[$address]
    $script:remoteStrings[$address]=[Text.Encoding]::Unicode.GetBytes(('X'+$target.Substring(1)))
    $script:chestOffsetCache.Clear()
    $restored=Reapply-CurrentSaveChestSnapshot 'missing-node'
    Check 'missing required runtime chest cannot be reported restored' (-not $restored)
    $script:remoteStrings[$address]=$original
    $restored=Reapply-CurrentSaveChestSnapshot 'node-ready'
    Check 'missing-node cache is rebuilt when node becomes readable' ($restored -and $script:chestOffsetCache.ContainsKey($target))

    Init-Scenario
    Remember-ActorCompletedId $target
    Write-Snapshot 'slot-b.db' @($target,$another)
    $script:memoryReady=$false
    Request-Boundary $true
    Check 'unavailable vector retains boundary request' (Test-Path -LiteralPath $script:runtimeResetRequestPath)
    Remember-ActorCompletedId $another
    $script:memoryReady=$true;$script:boundaryRestoreRetryAt=[DateTime]::MinValue
    Consume-RuntimeCompletionResetRequest
    Check 'retry commits only after chest and area restoration succeeds' (-not (Test-Path -LiteralPath $script:runtimeResetRequestPath) -and (Done $target) -eq 0)
    Check 'retry does not erase destination event a second time' ($script:actorCompletedIds.ContainsKey($another) -and (Done $another) -eq 1)

    # Cached authoritative state stays coherent even while compatibility files change.
    Init-Scenario
    [IO.File]::WriteAllText($script:fastLiveSlotPath,'uncommitted-other-slot.db')
    [IO.File]::WriteAllText($script:fastChestSnapshotPath,'')
    Check 'legacy half-published files cannot change slot or chest authority' ((Get-AuthoritativeProfileSlot) -eq 'slot-a.db' -and (Read-FastChestSnapshotMap).Count -eq 1502)
    $revision=$script:authoritySnapshot.Revision
    [IO.File]::WriteAllText($script:authorityStatePath,'DSWR_STATE_V1')
    Check 'truncated authority publication is rejected and last complete snapshot retained' (-not (Refresh-RadarAuthoritySnapshot) -and $script:authoritySnapshot.Revision -eq $revision)
    Write-Snapshot 'slot-a.db' @($target)
    Check 'wrong-catalog authority is rejected' ($null -eq (Read-RadarAuthoritySnapshot $script:authorityStatePath ('f'*64)))

    # Actual event consumer rejects previous-process and unversioned legacy events.
    Init-Scenario
    [IO.File]::WriteAllLines($script:actorEventQueuePath,[string[]]@(
        "$target|opened|TreasureBox03_C|1|2|3|4|999",
        "$target|opened|TreasureBox03_C|1|2|3|4",
        'DSC_999999999|opened|TreasureBox03_C|1|2|3|4|1001'
    ))
    Drain-ActorChestEvents
    Check 'old untagged and unknown chest events cannot hide nodes' ($script:actorCompletedIds.Count -eq 0)
    [IO.File]::WriteAllText($script:actorEventQueuePath,"$target|opened|TreasureBox03_C|1|2|3|4|1001`n")
    Drain-ActorChestEvents
    Check 'current-process opening still hides immediately and updates category' ((Done $target) -eq 1 -and $script:labels['cat.chests_grade3'] -eq '349/349')

    # Native freshness and persistent-cache rules execute against real temp files.
    Init-Scenario
    $native='{"version":"DSWR-1.18.27-native-inprocess-A40B90","opened_map":"A40","total_map":"B90","mission_type":1,"opened":1502,"total":1503,"event":"test","handler":"0x1"}'
    [IO.File]::WriteAllText($nativeChestJsonPath,$native)
    $script:nativeChestGenerationEpochUtc=[DateTime]::UtcNow
    [IO.File]::SetLastWriteTimeUtc($nativeChestJsonPath,$script:nativeChestGenerationEpochUtc.AddMilliseconds(-500))
    Check 'native sidecar half a second before boundary is rejected' ($null -eq (Read-NativeWorldCompleteChestCount))
    [IO.File]::SetLastWriteTimeUtc($nativeChestJsonPath,$script:nativeChestGenerationEpochUtc.AddMilliseconds(100))
    Check 'native sidecar after boundary is accepted' ((Read-NativeWorldCompleteChestCount).Opened -eq 1502)
    $dir=Get-SaveProfileDir (Get-AuthoritativeProfileSlot) $true
    Write-IdSetFileAtomic (Join-Path $dir 'chests.txt') $script:authoritySnapshot.Chests | Out-Null
    [IO.File]::WriteAllText((Join-Path $dir 'chest_area.v3.valid'),'valid')
    $script:saveTransitionPending=$true
    Write-ModLocalNativeChestCount @{Source='native-current';Opened=1502;Total=1503} 'test-transition'
    Check 'unconfirmed transition cannot store native count under source profile' (-not (Test-Path -LiteralPath (Join-Path $dir 'native_chest.v2.txt')))
    $script:saveTransitionPending=$false
    Write-ModLocalNativeChestCount @{Source='native-current';Opened=1502;Total=1503} 'test-stable'
    Check 'confirmed native count can be restored from its save profile' ((Read-ModLocalNativeChestCount).Opened -eq 1502)
    $all=$script:authoritySnapshot.Chests.Clone();$all[$target]=$true
    Write-IdSetFileAtomic (Join-Path $dir 'chests.txt') $all | Out-Null
    Remember-ActorCompletedId $target
    Check 'native profile delta advances only with new current-save openings' ((Read-ModLocalNativeChestCount).Opened -eq 1503)

    # Exercise the actual Run-LiveSync orchestration, replacing only child creation
    # and unrelated native UI queries. The helper logic itself is tested separately.
    function Sync-MnMTranslationCountLabels {}
    function Sync-RuntimeTransientCompletionCountLabels {return $true}
    function Sync-RuntimeAreaQuestCountLabel {}
    function Sync-NativeWorldCompleteChestCountLabel {return $true}
    function Consume-Runtime161BurstRequest {}
    function Service-Runtime161Burst {}
    function Start-Process {
        param($FilePath,$ArgumentList,[switch]$NoNewWindow,[switch]$PassThru,$RedirectStandardOutput,$RedirectStandardError)
        $script:fakeLaunches++
        if($script:fakeMode -eq 'failure'){$output='controlled failure';$exitCode=1}
        else{
            if(-not (Write-RadarTextAtomic $script:authorityStatePath $script:fakeCommit)){throw 'Fixture commit failed'}
            $output="FAST_LIVE_MS=1`nLIVE_ADDED_IDS=`nLIVE_AREA_QUEST_ADDED_IDS=`nLIVE_AREA_QUEST_COUNT=0/147"
            if($script:fakeMode -eq 'boundary'){$output+="`nFAST_BOUNDARY_FULLSTATE=1"}
            $exitCode=0
        }
        [IO.File]::WriteAllText($RedirectStandardOutput,$output)
        [IO.File]::WriteAllText($RedirectStandardError,'')
        $p=[pscustomobject]@{ExitCode=$exitCode;Mode=$script:fakeMode;Killed=$false}
        $p|Add-Member ScriptMethod WaitForExit {param($milliseconds) if($this.Mode -eq 'hang' -and -not $this.Killed){return $false};if($null -ne $milliseconds){return $true}}
        $p|Add-Member ScriptMethod Kill {$this.Killed=$true;$script:fakeKills++}
        $p|Add-Member ScriptMethod Dispose {}
        return $p
    }
    Init-Scenario
    Write-Snapshot 'slot-b.db' @($target)
    $script:fakeCommit=[IO.File]::ReadAllText($script:authorityStatePath)
    Write-Snapshot 'slot-a.db' @()
    Remember-ActorCompletedId $target
    $script:fakeMode='boundary';$script:fakeLaunches=0
    $ok=Run-LiveSync 'reload'
    Check 'full live-sync pipeline adopts destination commit and restores new chest' ($ok -and (Get-AuthoritativeProfileSlot) -eq 'slot-b.db' -and (Done $target) -eq 0 -and $script:labels['cat.chests_grade3'] -eq '348/349')
    Check 'full pipeline confirms completed boundary request' (-not (Test-Path -LiteralPath $script:runtimeResetRequestPath) -and -not $script:saveTransitionPending)
    $script:fakeMode='failure';$script:fakeLaunches=0
    $ok=Run-LiveSync 'reload'
    Check 'four failed helper attempts report failure for dispatcher retry' (-not $ok -and $script:fakeLaunches -eq 4)

    # A hung child cannot block the sole event consumer forever or commit stale output.
    Write-Snapshot 'slot-hung.db' @($target)
    $script:fakeCommit=[IO.File]::ReadAllText($script:authorityStatePath)
    Write-Snapshot 'slot-b.db' @()
    $beforeRevision=$script:authoritySnapshot.Revision
    $script:fakeMode='hang';$script:fakeLaunches=0;$script:fakeKills=0;$script:liveSyncTimeoutMs=1
    $ok=Run-LiveSync 'reload'
    $script:liveSyncTimeoutMs=0
    Check 'hung helpers are cancelled and return failure for dispatcher retry' (-not $ok -and $script:fakeLaunches -eq 4 -and $script:fakeKills -eq 4)
    Check 'completion text from timed-out child cannot adopt its snapshot' ($script:authoritySnapshot.Revision -ceq $beforeRevision -and (Get-AuthoritativeProfileSlot) -eq 'slot-b.db')
    Check 'failed helper attempts clean up redirected temporary outputs' (@(Get-ChildItem -LiteralPath (Join-Path $syncRootForTests 'cache') -Filter 'live_sync_*.tmp').Count -eq 0)

    # Reload trigger publishes requests instead of starting a competing process.
    $reloadPath=Join-Path (Split-Path -Parent (Resolve-Path $WatcherPath)) 'reload_watcher.ps1'
    $rt=$null;$re=$null
    $ra=[Management.Automation.Language.Parser]::ParseFile($reloadPath,[ref]$rt,[ref]$re)
    $rf=@($ra.FindAll({param($a)$a -is [Management.Automation.Language.FunctionDefinitionAst] -and $a.Name -eq 'Start-ReloadSync'},$true))
    . ([scriptblock]::Create($rf[0].Extent.Text))
    $saveReloadRequestPath=$script:saveReloadRequestPath
    $first=Start-ReloadSync 'transition-one';$second=Start-ReloadSync 'transition-two'
    $batch=@(Take-RadarEventQueue $saveReloadRequestPath)
    Check 'rapid reloads coalesce to newest request without debounce loss' ($first -and $second -and $batch.Count -eq 1 -and $batch[0].Contains('transition-two'))

    $result=@{
        watcher_sha256=(Get-FileHash -LiteralPath $WatcherPath -Algorithm SHA256).Hash.ToLowerInvariant()
        powershell_version=$PSVersionTable.PSVersion.ToString()
        test_kind='actual-shipped-PowerShell-functions-with-memory-and-game-IO-doubles'
        game_runtime_executed=$false;windows_powershell_51_executed=$false
        baseline_bug_expected=[bool]$ExpectOldBug;passed=$true;checks=$script:checks;trace=$script:steps
    }
    $result | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $OutputPath -Encoding utf8
    Write-Output ('PASS: '+$script:checks.Count+'; baseline='+[bool]$ExpectOldBug)
} finally {
    Remove-Item -LiteralPath $temp -Recurse -Force
}
