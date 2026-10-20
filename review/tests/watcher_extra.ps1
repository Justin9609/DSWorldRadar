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
