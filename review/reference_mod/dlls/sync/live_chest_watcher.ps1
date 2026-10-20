$ErrorActionPreference = 'Continue'
$syncRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $syncRoot 'radar_common.ps1')
$watchLog = Join-Path $syncRoot 'live_chest_watcher.log'
$watchVersion = 'DSWR-1.0.7-dispatch-reason-reset'
$exePath = Join-Path $syncRoot 'MnMChestSaveSync.exe'
$dllsRoot = Split-Path -Parent $syncRoot
$runtimeNodesPath = Join-Path $dllsRoot 'mnm_nodes.csv'
$nodesPath = $runtimeNodesPath
$idsPath = Join-Path $dllsRoot 'mnm_ids.csv'
$marmotPath = Join-Path $dllsRoot 'marmot_locations.csv'

# v1.18.28: chest authority remains the proven type-1 in-process bridge.
# A second native A40-increment bridge now supplies mission-type-specific counts
# (notably type 2 MINIGAME) and a native quest packet bridge supplies area QuestID.
# DSWorldRadar/wcbridge.dll listens to WS2GC_WORLD_COMPLETE_GROUP_COUNT_NTY and
# directly queries DMapWorldCompleteHandler A40/B90 after the original callback.
# Lua writes a tiny fresh sidecar here; there is no DSWorldCompleteProbe process-memory worker.
$nativeChestJsonPath = Join-Path $syncRoot 'native_worldcomplete_chest_count.json'
$nativeChestMirrorPath = Join-Path $syncRoot 'cache\native_worldcomplete_chest_count.txt'
$nativeMiniGameJsonPath = Join-Path $syncRoot 'native_worldcomplete_minigame_count.json'
$script:gameStartUtc = [DateTime]::MinValue
$script:nativeChestGenerationEpochUtc = [DateTime]::MinValue
# v1.18.43: set when FAST_BOUNDARY_FULLSTATE invalidates the non-slot-tagged native sidecar
# before any post-helper label/cache reconciliation can observe it.
# The helper clears Actor evidence before destination counts/profile reconciliation.
# Consume the queued boundary once without clearing new destination events again.
$script:actorGenerationPreReset = $false
$script:nativeGenerationPreInvalidated = $false
$script:lastNativeChestSignature = ''
$script:lastNativeChestAvailability = 'unknown'
$script:lastNativeMiniGameAvailability = 'unknown'
# Packaged catalog fallback only; a fresh A40/B90 result overrides it.
$script:nativeWorldCompleteTreasureTotal = 1503
# A catalog update must not be mistaken for newly opened chests in a saved native count.
$script:chestCatalogSha256 = ''
try { $script:chestCatalogSha256 = (Get-FileHash -LiteralPath $nodesPath -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant() } catch { }
$script:nativeWorldCompleteMiniGameTotal = 84


# v1.18.42: mnm_nodes.csv is now the immutable full catalog.
# Per-save hiding is handled only through progress/runtime completion state; no CSV pruning/restoration.

function Log([string]$text) { Write-RadarLog $watchLog $text }

function Read-CountMap([string]$path) {
    $map = @{}
    try {
        if (-not (Test-Path -LiteralPath $path)) { return $map }
        foreach ($line in (Get-Content -LiteralPath $path -ErrorAction Stop)) {
            if ([String]::IsNullOrWhiteSpace($line)) { continue }
            $t = $line.Trim()
            if ($t.StartsWith('#')) { continue }
            $eq = $t.IndexOf('=')
            if ($eq -le 0 -or $eq -ge ($t.Length - 1)) { continue }
            $k = $t.Substring(0, $eq).Trim()
            $v = $t.Substring($eq + 1).Trim()
            if ($k.Length -gt 0) { $map[$k] = $v }
        }
    } catch {
        Log ('Count-map read failed: ' + $path + ': ' + $_.Exception.Message)
    }
    return $map
}

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

# v1.18.18: per-save radar sidecar helpers. These files are radar-only and never modify
# DragonSword's save databases. v1.18.17 profiles are deliberately ignored unless they
# carry the v2 validity marker, preventing an early all-zero snapshot from poisoning a save.
function Get-SaveProfileKey([string]$slot) {
    if ([String]::IsNullOrWhiteSpace($slot)) { return '' }
    $norm = $slot.Trim().ToLowerInvariant()
    try {
        $sha = [Security.Cryptography.SHA256]::Create()
        try {
            $bytes = [Text.Encoding]::UTF8.GetBytes($norm)
            $hash = $sha.ComputeHash($bytes)
            $hex = -join ($hash | ForEach-Object { $_.ToString('x2') })
            return $hex.Substring(0,24)
        } finally { $sha.Dispose() }
    } catch { return ([Math]::Abs($norm.GetHashCode())).ToString('x8') }
}

function Get-SaveProfileDir([string]$slot,[bool]$create) {
    $key = Get-SaveProfileKey $slot
    if ($key.Length -eq 0) { return '' }
    $dir = Join-Path $script:saveProfileRoot $key
    if ($create -and -not (Test-Path -LiteralPath $dir)) {
        try { [void](New-Item -ItemType Directory -Path $dir -Force) } catch { return '' }
    }
    return $dir
}

function Read-IdSetFile([string]$path) {
    $set = @{}
    try {
        if (-not (Test-Path -LiteralPath $path)) { return $set }
        foreach ($raw in (Get-Content -LiteralPath $path -ErrorAction Stop)) {
            if ([String]::IsNullOrWhiteSpace($raw)) { continue }
            $id = ([string]$raw).Trim()
            if ($id.Length -gt 0 -and -not $id.StartsWith('#')) { $set[$id] = $true }
        }
    } catch { }
    return $set
}

function Write-IdSetFileAtomic([string]$path,[hashtable]$set) {
    $lines=@($set.Keys|ForEach-Object {[string]$_}|Sort-Object -Unique)
    $text=if($lines.Count){($lines -join "`r`n")+"`r`n"}else{''}
    return (Write-RadarTextAtomic $path $text)
}

function Refresh-RadarAuthoritySnapshot {
    $state=Read-RadarAuthoritySnapshot $script:authorityStatePath $script:chestCatalogSha256
    if($null -eq $state){Log 'Save-authoritative snapshot unavailable/incomplete; no state adopted.';return $false}
    $script:authoritySnapshot=$state
    return $true
}

function Read-StateTextSafe([string]$path) {
    try {
        if (Test-Path -LiteralPath $path) { return (Get-Content -LiteralPath $path -Raw -ErrorAction Stop).Trim().ToLowerInvariant() }
    } catch { }
    return ''
}

function Clear-PersistentRuntimeProfileState([string]$dir,[string]$reason) {
    if ([String]::IsNullOrWhiteSpace($dir)) { return }
    foreach($name in @(
        'transient161.txt','transient161.v2.valid',
        'slider29.txt','slider29.v1.valid',
        'native_chest.v1.txt','native_chest.v1.valid',
        'native_chest.v2.txt','native_chest.v2.valid'
    )){
        try{Remove-Item -LiteralPath (Join-Path $dir $name) -Force -ErrorAction SilentlyContinue}catch{}
    }
    Log ('MOD-local runtime-only profile cleared: dir=' + $dir + '; reason=' + $reason)
}

function Test-SetSuperset([hashtable]$current,[hashtable]$previous) {
    if ($null -eq $previous -or $previous.Count -eq 0) { return $true }
    if ($null -eq $current) { return $false }
    foreach($k in @($previous.Keys)){
        if(-not $current.ContainsKey([string]$k)){return $false}
    }
    return $true
}

function Sync-PersistentProfileAuthorityFromHelper([string]$reason) {
    try {
        if ([String]::IsNullOrWhiteSpace($script:saveProfileRoot)) { return $false }
        $state=$script:authoritySnapshot
        if($null -eq $state){return $false}
        $slot=[string]$state.Slot
        $currentChest=$state.Chests.Clone()
        $currentArea=$state.Areas.Clone()
        $dst = Get-SaveProfileDir $slot $true
        if ([String]::IsNullOrWhiteSpace($dst)) { return $false }

        $dstValid = Join-Path $dst 'chest_area.v3.valid'
        $oldChest = @{}
        $oldArea = @{}
        $hadPersistent = (Test-Path -LiteralPath $dstValid)
        if ($hadPersistent) {
            $oldChest = Read-IdSetFile (Join-Path $dst 'chests.txt')
            $oldArea = Read-IdSetFile (Join-Path $dst 'area_quests.txt')
        }

        # Ordinary play is monotonic for these two save-authoritative sets.  A strict
        # shrink means the same Slot path now represents an older/replaced generation.
        # Clear only runtime-only caches in that case; normal forward progress preserves them.
        $generationReset = $false
        if ($hadPersistent) {
            if (-not (Test-SetSuperset $currentChest $oldChest) -or
                -not (Test-SetSuperset $currentArea $oldArea)) {
                $generationReset = $true
                Clear-PersistentRuntimeProfileState $dst ('authority-shrink|' + $reason)
            }
        }

        if(Test-Path -LiteralPath $dstValid){Remove-Item -LiteralPath $dstValid -Force -ErrorAction Stop}
        if(-not (Write-IdSetFileAtomic (Join-Path $dst 'chests.txt') $currentChest)){return $false}
        if(-not (Write-IdSetFileAtomic (Join-Path $dst 'area_quests.txt') $currentArea)){return $false}
        if(-not (Write-RadarTextAtomic (Join-Path $dst 'slot_path.txt') ($slot+"`r`n"))){return $false}
        if(-not (Write-RadarTextAtomic $dstValid ((Get-Date).ToString('O')+"`r`n"))){return $false}
        Log ('MOD-local authority profile synced: key=' + (Get-SaveProfileKey $slot) +
             '; chests=' + $currentChest.Count + '; area=' + $currentArea.Count +
             '; generationReset=' + $generationReset + '; reason=' + $reason)
        return $true
    } catch {
        Log ('MOD-local authority profile sync failed: ' + $_.Exception.Message + '; reason=' + $reason)
        return $false
    }
}

function Read-ModLocalNativeChestCount {
    try {
        $slot = Get-AuthoritativeProfileSlot
        if ([String]::IsNullOrWhiteSpace($slot)) { return $null }
        $dir = Get-SaveProfileDir $slot $false
        if ([String]::IsNullOrWhiteSpace($dir) -or -not (Test-Path -LiteralPath (Join-Path $dir 'chest_area.v3.valid'))) { return $null }

        # v1.18.43: v1 caches are intentionally retired.  A v1 cache could have been
        # written during the old FAST_BOUNDARY_FULLSTATE race, where the destination
        # save key had already changed but the non-slot-tagged A40 sidecar still belonged
        # to the source save.  Never trust/migrate that value; delete it lazily.
        $legacyValid = Join-Path $dir 'native_chest.v1.valid'
        $legacyPath = Join-Path $dir 'native_chest.v1.txt'
        if ((Test-Path -LiteralPath $legacyValid) -or (Test-Path -LiteralPath $legacyPath)) {
            try {
                Remove-Item -LiteralPath $legacyValid,$legacyPath -Force -ErrorAction SilentlyContinue
                Log ('Retired legacy native chest cache removed for key=' + (Get-SaveProfileKey $slot) + '; cache=v1-crosssave-unsafe')
            } catch { }
        }

        $valid = Join-Path $dir 'native_chest.v2.valid'
        $path = Join-Path $dir 'native_chest.v2.txt'
        if (-not (Test-Path -LiteralPath $valid) -or -not (Test-Path -LiteralPath $path)) { return $null }

        $m = Read-CountMap $path
        foreach($required in @('cache_version','slot_key','source','opened','total','catalog_opened','catalog_sha256')) {
            if (-not $m.ContainsKey($required)) { return $null }
        }
        $slotKey = Get-SaveProfileKey $slot
        if ([string]$m['cache_version'] -ne '2' -or [string]$m['slot_key'] -ne $slotKey -or [string]$m['source'] -ne 'native-current') { return $null }
        if ([String]::IsNullOrWhiteSpace($script:chestCatalogSha256) -or [string]$m['catalog_sha256'] -ne $script:chestCatalogSha256) { return $null }
        $opened=[int]$m['opened']; $total=[int]$m['total']; $capturedCatalog=[int]$m['catalog_opened']
        if($total -le 0 -or $total -gt 10000 -or $opened -lt 0 -or $opened -gt $total){return $null}
        $currentCatalog=(Get-EffectiveOpenedChestSet).Set.Count
        $delta=$currentCatalog-$capturedCatalog
        if($delta -lt 0){return $null}
        $predicted=$opened+$delta
        if($predicted -lt 0 -or $predicted -gt $total){return $null}
        return @{
            Opened=$predicted; Total=$total; Remaining=($total-$predicted)
            Event='persistent-profile-v2'; Handler='per-save-cache'; Version='profile-v2'
            FileUtc=(Get-Item -LiteralPath $path).LastWriteTimeUtc
            Source='profile-cache'; CapturedOpened=$opened; CatalogDelta=$delta
        }
    } catch { return $null }
}

function Write-ModLocalNativeChestCount([hashtable]$native,[string]$reason) {
    try {
        if($null -eq $native){return}
        if($script:saveTransitionPending){return}
        if ([String]::IsNullOrWhiteSpace($script:chestCatalogSha256)) { return }
        # Defense in depth: only a fresh, current-generation A40/B90 observation may
        # seed a persistent per-save native cache.  Profile restores/fallbacks are never
        # allowed to create another profile.
        if ([string]$native.Source -ne 'native-current') {
            Log ('MOD-local native chest cache write rejected: non-current source=' + [string]$native.Source + '; reason=' + $reason)
            return
        }
        $slot=Get-AuthoritativeProfileSlot
        if([String]::IsNullOrWhiteSpace($slot)){return}
        $dir=Get-SaveProfileDir $slot $true
        if([String]::IsNullOrWhiteSpace($dir) -or -not (Test-Path -LiteralPath (Join-Path $dir 'chest_area.v3.valid'))){return}
        $slotKey=Get-SaveProfileKey $slot
        $catalog=(Get-EffectiveOpenedChestSet).Set.Count
        $path=Join-Path $dir 'native_chest.v2.txt'
        try {
            if (Test-Path -LiteralPath $path) {
                $oldMap=Read-CountMap $path
                if($oldMap.ContainsKey('cache_version') -and $oldMap.ContainsKey('slot_key') -and $oldMap.ContainsKey('source') -and
                   $oldMap.ContainsKey('opened') -and $oldMap.ContainsKey('total') -and $oldMap.ContainsKey('catalog_opened') -and
                   [string]$oldMap['cache_version'] -eq '2' -and [string]$oldMap['slot_key'] -eq $slotKey -and
                   [string]$oldMap['source'] -eq 'native-current' -and
                   $oldMap.ContainsKey('catalog_sha256') -and [string]$oldMap['catalog_sha256'] -eq $script:chestCatalogSha256 -and
                   [int]$oldMap['opened'] -eq [int]$native.Opened -and
                   [int]$oldMap['total'] -eq [int]$native.Total -and
                   [int]$oldMap['catalog_opened'] -eq [int]$catalog) { return }
            }
        } catch { }
        $tmp=$path+'.tmp.'+$PID
        $sidecarUtc=''
        try { if($native.ContainsKey('FileUtc')){$sidecarUtc=([DateTime]$native.FileUtc).ToString('O')} } catch { }
        $lines=@(
            '# DSWorldRadar v1.0.2 catalog-bound per-save native TREASUREBOX_OPEN cache',
            'cache_version=2',
            ('slot_key=' + $slotKey),
            'source=native-current',
            ('opened=' + [int]$native.Opened),
            ('total=' + [int]$native.Total),
            ('catalog_opened=' + [int]$catalog),
            ('catalog_sha256=' + $script:chestCatalogSha256),
            ('sidecar_utc=' + $sidecarUtc),
            ('updated=' + (Get-Date).ToString('O')),
            ('reason=' + $reason)
        )
        [IO.File]::WriteAllLines($tmp,$lines,(New-Object Text.UTF8Encoding($false)))
        Move-Item -LiteralPath $tmp -Destination $path -Force
        [IO.File]::WriteAllText((Join-Path $dir 'native_chest.v2.valid'),((Get-Date).ToString('O')+"`r`n"),(New-Object Text.UTF8Encoding($false)))
        # Remove any unsafe legacy value for this slot after a verified v2 commit.
        Remove-Item -LiteralPath (Join-Path $dir 'native_chest.v1.txt'),(Join-Path $dir 'native_chest.v1.valid') -Force -ErrorAction SilentlyContinue
        Log ('MOD-local per-save native chest cache v2 committed: key=' + $slotKey +
             '; native=' + $native.Opened + '/' + $native.Total +
             '; catalog=' + $catalog + '; reason=' + $reason)
    } catch { Log ('MOD-local per-save native chest cache v2 commit failed: ' + $_.Exception.Message) }
}

# v1.18.4: log before mutex acquisition so a failed/duplicate watcher is visible.
Log ('Live watcher process entered. version=' + $watchVersion + '; selfPid=' + $PID)
$mutex = $null
try {
    $mutex = New-Object System.Threading.Mutex($false, ('Local\DSWorldRadar_LiveWatcher_'+(Get-RadarInstallKey $syncRoot)))
}
catch {
    Log ('FATAL mutex creation failed: ' + $_.Exception.Message)
    exit 0
}
$hasMutex = $false
$game = $null
$processHandle = [IntPtr]::Zero
$slotWatcher = $null
$runtimeMemoryDisabled = $false
$cachedMnMModuleInfo = $null
# v1.18.31: adaptive scheduling + translation-node cache + stale-helper race guard.  The cache stores only
# addresses inside the already-verified MnMRadar translation unordered_map.  It is
# invalidated automatically if the native module base/hash changes.
$translationNodeCache = @{}
$translationNodeCacheBase = [Int64]0
$translationNodeCacheHash = ''
$steadyRuntimeCountPollMs = 3000
$progressFingerprintPollMs = 500
$lastProgressFingerprintPollUtc = [DateTime]::MinValue
$pendingHideIds = @{}
$lastPendingHideRetryUtc = [DateTime]::MinValue
$actorEventQueuePath = Join-Path $syncRoot 'actor_chest_events.queue'
$areaQuestEventQueuePath = Join-Path $syncRoot 'area_quest_events.queue'
$runtimeResetRequestPath = Join-Path (Join-Path $syncRoot 'cache') 'completion_runtime_reset.request'
$actorResetFlagPath = Join-Path $syncRoot 'save_boundary_actor_reset.flag'
$actorCompletedIds = @{}
# v1.18.20: strong Actor completion temporarily outranks MnMRadar's slower chest-presence scan.
# The native scan can still see an opened chest actor for tens of seconds and write done=0 again.
$actorStrongGuardUntil = @{}
$lastActorStrongGuardUtc = [DateTime]::MinValue
$actorCandidateIds = @{}
$lastImmediateChestCategorySig = ''
$completionResetIds = @{}
$completionKindById = @{}
$chestResetIds = @{}
$completionCoordCount = 0
$lastRuntimeAreaOpened = -1
$lastRuntimeAreaRefreshUtc = [DateTime]::MinValue
$postLoadCountRefreshRemaining = 0
$postLoadCountRefreshNextUtc = [DateTime]::MinValue
$lastRuntimeTransientCountPollUtc = [DateTime]::MinValue
$transientOffsetCache = @{}
$transientOffsetCacheVectorStart = [Int64]0
$transientOffsetCacheVectorCount = 0
$areaOffsetCache = @{}
$areaOffsetCacheVectorStart = [Int64]0
$areaOffsetCacheVectorCount = 0
$exactAreaCompletedIds = @{}
$exactAreaReassertRemaining = 0
$exactAreaNextReassertUtc = [DateTime]::MinValue
$fastLiveSlotPath = Join-Path (Join-Path $syncRoot 'cache') 'fast_live_slot.txt'
$script:authorityStatePath = Join-Path (Join-Path $syncRoot 'cache') 'authority_state.v1.txt'
$script:authoritySnapshot = $null
$script:saveTransitionPending = $false
$script:preparedBoundaryRequest = ''
$script:boundaryRestoreRetryAt = [DateTime]::MinValue
$saveReloadRequestPath = Join-Path (Join-Path $syncRoot 'cache') 'save_reload.request' 
# v1.18.38: use a fresh v4 MOD-local profile namespace. v3 may contain values captured
# after the old save-boundary clear path zeroed minigame/slider runtime bytes, so it is
# deliberately not trusted by this build. Everything remains inside the MOD folder.
$script:saveProfileRoot = Join-Path (Join-Path $syncRoot 'cache') 'save_profiles_v4'
$runtime161BurstRequestPath = Join-Path (Join-Path $syncRoot 'cache') 'runtime161_burst.request'
$profileHintSlotPath = Join-Path (Join-Path $syncRoot 'cache') 'fast_profile_hint_slot.txt'
$profileGenerationReadySlot = ''
$profileWarmTransientSlot = ''
$profileStableSlot = ''
$profileStableSignature = ''
$profileStableSinceUtc = [DateTime]::MinValue
$profileStableSamples = 0
$profileWatcherStartedUtc = [DateTime]::UtcNow
$runtime161BurstUntilUtc = [DateTime]::MinValue
$runtime161BurstNextUtc = [DateTime]::MinValue
$transitionRuntime161BaselineSignature = ''
$profileFingerprintSignature = ''
$profileFingerprintSamples = 0
$profileFingerprintSinceUtc = [DateTime]::MinValue
$profileFingerprintBoundSlot = ''
$lastObservedRuntime161Signature = ''
$chestKindById = @{}
$chestOffsetCache = @{}
$chestOffsetCacheVectorStart = [Int64]0
$chestOffsetCacheVectorCount = 0
# v1.18.41: corrected puzzle taxonomy. The 77 DT_PressurePuzzle reward rows are
# 48 true 140xx pressure/platform puzzles + 29 150xx reward records belonging to the
# 29 SliderPuzzle markers. The 150xx rows are NOT a second independent pressure family.
# Slider marker IDs are local and permuted relative to their reward-chest IDs, so keep
# an explicit one-to-one mapping and use current-save reward-chest state as authority.
$pressurePuzzleIds = @{}
$sliderStaticCoords = @{}
$sliderStaticOffsetCache = @{}
$sliderStaticOffsetCacheVectorStart = [Int64]0
$sliderStaticOffsetCacheVectorCount = 0
$sliderRewardChestById = @{
    '15001'='DSC_15005'; '15011'='DSC_15007'; '15003'='DSC_15003'; '15002'='DSC_15002';
    '15012'='DSC_15014'; '15008'='DSC_15013'; '15029'='DSC_15001'; '15005'='DSC_15017';
    '15006'='DSC_15015'; '15010'='DSC_15008'; '15007'='DSC_15006'; '15009'='DSC_15016';
    '15004'='DSC_15004'; '15013'='DSC_15009'; '15024'='DSC_15022'; '15014'='DSC_15012';
    '15016'='DSC_15011'; '15015'='DSC_15010'; '15026'='DSC_15028'; '15025'='DSC_15029';
    '15028'='DSC_15020'; '15027'='DSC_15025'; '15023'='DSC_15018'; '15022'='DSC_15026';
    '15021'='DSC_15023'; '15018'='DSC_15024'; '15017'='DSC_15021'; '15019'='DSC_15027';
    '15020'='DSC_15019'
}
$sliderIdByRewardChest = @{}
foreach($kv in $sliderRewardChestById.GetEnumerator()){$sliderIdByRewardChest[[string]$kv.Value]=[string]$kv.Key}
# v1.18.40: DSTool 1.4.4 has one additional independent StatuePuzzle (16001).
# Keep it separate from the 48 pressure + 29 slider families. Its reward chest is
# DSC_16001, so current-save reward-chest authority gives an exact per-save completion bit.
$statueStaticCoords = @{}
$statueStaticOffsetCache = @{}
$statueStaticOffsetCacheVectorStart = [Int64]0
$statueStaticOffsetCacheVectorCount = 0
$statuePuzzleChestId = 'DSC_16001'
$sliderProfileStableSlot = ''
$sliderProfileStableSignature = ''
$sliderProfileStableSinceUtc = [DateTime]::MinValue
$sliderProfileStableSamples = 0
$lastKnownFastSlot = ''
try {
    if (Test-Path -LiteralPath $fastLiveSlotPath) {
        $lastKnownFastSlot = (Get-Content -LiteralPath $fastLiveSlotPath -Raw -ErrorAction Stop).Trim().ToLowerInvariant()
    }
} catch { $lastKnownFastSlot = '' }
try {
    $cacheDir = Join-Path $syncRoot 'cache'
    if (-not (Test-Path -LiteralPath $cacheDir)) { [void](New-Item -ItemType Directory -Path $cacheDir -Force) }
    # v1.18.18: never restore the historical process-global chest witness cache across saves.
    if (-not (Test-Path -LiteralPath $script:saveProfileRoot)) { [void](New-Item -ItemType Directory -Path $script:saveProfileRoot -Force) }
} catch { }

try {
    try { $hasMutex = $mutex.WaitOne(0, $false) } catch [Threading.AbandonedMutexException] { $hasMutex = $true } catch { $hasMutex = $false }
    if (-not $hasMutex) { Log 'Live watcher mutex already held; duplicate instance exits.'; exit 0 }

    # sync -> dlls -> MnMRadar -> Mods -> Win64
    if (-not (Refresh-RadarAuthoritySnapshot)) { throw 'Save-authoritative snapshot missing or invalid; synchronization stopped safely.' }
    $script:lastKnownFastSlot = [string]$script:authoritySnapshot.Slot
    $win64 = Resolve-Win64Root $syncRoot
    $saveRoot = [IO.Path]::GetFullPath((Join-Path $win64 '..\..\Saved\SaveGames'))
    # v1.18.36: profile root is intentionally MOD-local.
    # It persists across normal game restarts while this MOD install exists, but is
    # deleted together with DSWorldRadar during a clean update/reinstall.
    Log ('MOD-local per-save profile root: ' + $script:saveProfileRoot)

    # 0.5a: OS file notifications are the primary save-change trigger. A slow
    # fingerprint check remains only as a bounded fallback for coalesced/missed events.
    try {
        $slotWatcher = New-Object System.IO.FileSystemWatcher
        $slotWatcher.Path = $saveRoot
        $slotWatcher.Filter = '*_Slot*'
        $slotWatcher.IncludeSubdirectories = $true
        $slotWatcher.NotifyFilter = [IO.NotifyFilters]::LastWrite -bor [IO.NotifyFilters]::Size -bor [IO.NotifyFilters]::FileName -bor [IO.NotifyFilters]::CreationTime
        $slotWatcher.EnableRaisingEvents = $true
    } catch {
        $slotWatcher = $null
        Log ('FileSystemWatcher unavailable; 2s fingerprint fallback will be used: ' + $_.Exception.Message)
    }

    $game = Get-Process -Name 'DSClient-Win64-Shipping' -ErrorAction SilentlyContinue |
        Sort-Object StartTime -Descending |
        Select-Object -First 1
    if (-not $game) {
        Log 'Game process not found; live watcher exits.'
        exit 0
    }
    try {
        $script:gameStartUtc = $game.StartTime.ToUniversalTime()
        $script:gameStartEpoch = ([DateTimeOffset]$script:gameStartUtc).ToUnixTimeSeconds()
        $script:nativeChestGenerationEpochUtc = $script:gameStartUtc
        Log ('Native chest authority freshness epoch seeded from game start: ' + $script:gameStartUtc.ToString('O'))
    } catch {
        $script:gameStartUtc = [DateTime]::UtcNow
        $script:gameStartEpoch = ([DateTimeOffset]$script:gameStartUtc).ToUnixTimeSeconds()
        $script:nativeChestGenerationEpochUtc = $script:gameStartUtc
    }

    if (-not (Test-Path -LiteralPath $exePath)) {
        Log ('Helper missing: ' + $exePath)
        exit 0
    }
    if (-not (Test-Path -LiteralPath $nodesPath)) {
        Log ('mnm_nodes.csv missing: ' + $nodesPath)
        exit 0
    }
    if (-not (Test-Path -LiteralPath $idsPath)) {
        Log ('mnm_ids.csv missing: ' + $idsPath)
        exit 0
    }

    # Exact coordinates are only a fast candidate filter; every write still verifies
    # the exact node ID string in MnMRadar memory.  Chests come from our reconciled
    # mnm_nodes.csv, while area quests come from MnM's mnm_ids.csv.
    $nodeCoords = @{}
    $areaQuestIds = @{}
    $chestCoordCount = 0
    $areaCoordCount = 0
    try {
        foreach ($row in (Import-Csv -LiteralPath $nodesPath)) {
            if ($row.kind -like 'chests_*' -and $row.id) {
                $nodeCoords[$row.id] = @(
                    [double]([Int64]$row.x),
                    [double]([Int64]$row.y),
                    [double]([Int64]$row.z)
                )
                $chestResetIds[[string]$row.id] = $true
                $chestKindById[[string]$row.id] = [string]$row.kind
                $chestCoordCount++
            }
            elseif ($row.kind -eq 'puzzle_slider' -and $row.id) {
                # v1.18.41 true SliderPuzzle markers imported from DSTool's 29-point
                # world ESP database. They live in mnm_nodes.csv; the corrected transient
                # query universe is 84 WorldComplete minigames + 48 true pressure puzzles.
                # Slider completion is reconciled from its mapped 150xx reward chest.
                $sliderStaticCoords[[string]$row.id] = @(
                    [double]([Int64]$row.x),
                    [double]([Int64]$row.y),
                    [double]([Int64]$row.z)
                )
            }
            elseif ($row.kind -eq 'puzzle_statue' -and $row.id) {
                # v1.18.40: one independent StatuePuzzle (ID 16001) from DSTool 1.4.4.
                # It is a dynamic MnMRadar category, while completion is reconciled from
                # its exact reward chest DSC_16001 to avoid polluting the 161-query universe.
                $statueStaticCoords[[string]$row.id] = @(
                    [double]([Int64]$row.x),
                    [double]([Int64]$row.y),
                    [double]([Int64]$row.z)
                )
            }
        }
        if (Test-Path -LiteralPath $marmotPath) {
            foreach ($row in (Import-Csv -LiteralPath $marmotPath)) {
                if (($row.kind -eq 'fly' -or $row.kind -eq 'mole' -or $row.kind -eq 'wave') -and $row.mini_game_id) {
                    $id = [string]$row.mini_game_id
                    $nodeCoords[$id] = @(
                        [double]([Int64]$row.x),
                        [double]([Int64]$row.y),
                        [double]([Int64]$row.z)
                    )
                    $completionResetIds[$id] = $true
                    $completionKindById[$id] = [string]$row.kind
                    $completionCoordCount++
                }
            }
        }
        foreach ($row in (Import-Csv -LiteralPath $idsPath)) {
            if ($row.kind -eq 'area_quests' -and $row.id) {
                $nodeCoords[$row.id] = @(
                    [double]([Int64]$row.x),
                    [double]([Int64]$row.y),
                    [double]([Int64]$row.z)
                )
                $areaQuestIds[[string]$row.id] = $true
                $areaCoordCount++
            }
            elseif (($row.kind -eq 'puzzle_platform' -or $row.kind -eq 'puzzle_slider') -and $row.id) {
                $id = [string]$row.id
                $nodeCoords[$id] = @(
                    [double]([Int64]$row.x),
                    [double]([Int64]$row.y),
                    [double]([Int64]$row.z)
                )
                $completionResetIds[$id] = $true
                $completionKindById[$id] = [string]$row.kind
                if ($row.kind -eq 'puzzle_platform') { $pressurePuzzleIds[$id] = $true }
                $completionCoordCount++
            }
        }
        $sliderMapValid = ($sliderRewardChestById.Count -eq $sliderStaticCoords.Count -and $sliderIdByRewardChest.Count -eq $sliderStaticCoords.Count)
        foreach($sid in @($sliderStaticCoords.Keys)){
            if(-not $sliderRewardChestById.ContainsKey([string]$sid)){ $sliderMapValid=$false; break }
            $cid=[string]$sliderRewardChestById[[string]$sid]
            if(-not $nodeCoords.ContainsKey($cid)){ $sliderMapValid=$false; break }
        }
        Log ('Slider reward-chest map validation: mapped=' + $sliderRewardChestById.Count + '/' + $sliderStaticCoords.Count + '; unique_chests=' + $sliderIdByRewardChest.Count + '; valid=' + $sliderMapValid)
        Log ('Loaded exact coordinate index: chest=' + $chestCoordCount + '; area_quests=' + $areaCoordCount + '; transient_completion=' + $completionCoordCount + '; pressure=' + $pressurePuzzleIds.Count + '; slider_static=' + $sliderStaticCoords.Count + '; unique=' + $nodeCoords.Count)
    }
    catch {
        Log ('Failed to load exact node coordinate index: ' + $_.Exception.Message)
        exit 0
    }

    $nativeSource = @'
using System;
using System.Runtime.InteropServices;

public static class MnMLiveNativeV3643
{
    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern IntPtr OpenProcess(
        UInt32 dwDesiredAccess,
        bool bInheritHandle,
        Int32 dwProcessId);

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool ReadProcessMemory(
        IntPtr hProcess,
        IntPtr lpBaseAddress,
        [Out] byte[] lpBuffer,
        IntPtr nSize,
        out IntPtr lpNumberOfBytesRead);

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool WriteProcessMemory(
        IntPtr hProcess,
        IntPtr lpBaseAddress,
        byte[] lpBuffer,
        IntPtr nSize,
        out IntPtr lpNumberOfBytesWritten);

    [StructLayout(LayoutKind.Sequential)]
    public struct MEMORY_BASIC_INFORMATION64
    {
        public UInt64 BaseAddress;
        public UInt64 AllocationBase;
        public UInt32 AllocationProtect;
        public UInt32 __alignment1;
        public UInt64 RegionSize;
        public UInt32 State;
        public UInt32 Protect;
        public UInt32 Type;
        public UInt32 __alignment2;
    }

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern UIntPtr VirtualQueryEx(
        IntPtr hProcess,
        IntPtr lpAddress,
        out MEMORY_BASIC_INFORMATION64 lpBuffer,
        UIntPtr dwLength);

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool CloseHandle(IntPtr hObject);


    private const UInt32 TH32CS_SNAPMODULE = 0x00000008;
    private const UInt32 TH32CS_SNAPMODULE32 = 0x00000010;

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct MODULEENTRY32
    {
        public UInt32 dwSize;
        public UInt32 th32ModuleID;
        public UInt32 th32ProcessID;
        public UInt32 GlblcntUsage;
        public UInt32 ProccntUsage;
        public IntPtr modBaseAddr;
        public UInt32 modBaseSize;
        public IntPtr hModule;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 256)]
        public string szModule;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 260)]
        public string szExePath;
    }

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern IntPtr CreateToolhelp32Snapshot(UInt32 dwFlags, UInt32 th32ProcessID);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool Module32FirstW(IntPtr hSnapshot, ref MODULEENTRY32 lpme);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool Module32NextW(IntPtr hSnapshot, ref MODULEENTRY32 lpme);

    public static bool FindModuleByPathSuffix(
        Int32 processId,
        string pathSuffix,
        out IntPtr baseAddress,
        out UInt32 moduleSize,
        out string modulePath)
    {
        baseAddress = IntPtr.Zero;
        moduleSize = 0;
        modulePath = null;
        IntPtr snap = CreateToolhelp32Snapshot(TH32CS_SNAPMODULE | TH32CS_SNAPMODULE32, (UInt32)processId);
        if (snap == new IntPtr(-1)) return false;
        try
        {
            MODULEENTRY32 me = new MODULEENTRY32();
            me.dwSize = (UInt32)Marshal.SizeOf(typeof(MODULEENTRY32));
            if (!Module32FirstW(snap, ref me)) return false;
            string suffix = (pathSuffix ?? String.Empty).Replace('/', '\\');
            do
            {
                string p = (me.szExePath ?? String.Empty).Replace('/', '\\');
                if (p.EndsWith(suffix, StringComparison.OrdinalIgnoreCase))
                {
                    baseAddress = me.modBaseAddr;
                    moduleSize = me.modBaseSize;
                    modulePath = me.szExePath;
                    return true;
                }
                me.dwSize = (UInt32)Marshal.SizeOf(typeof(MODULEENTRY32));
            }
            while (Module32NextW(snap, ref me));
            return false;
        }
        finally
        {
            CloseHandle(snap);
        }
    }

    public static UInt64 Fnv1aUtf16(string text)
    {
        unchecked
        {
            UInt64 h = 0xcbf29ce484222325UL;
            UInt64 prime = 0x100000001b3UL;
            byte[] bytes = System.Text.Encoding.Unicode.GetBytes(text ?? String.Empty);
            for (int i = 0; i < bytes.Length; i++) { h ^= bytes[i]; h *= prime; }
            return h;
        }
    }
}
'@

    try {
        Add-Type -TypeDefinition $nativeSource -Language CSharp -ErrorAction Stop
    }
    catch {
        # Add-Type may report an existing type if a host reuses the runspace.
        if (-not ('MnMLiveNativeV3643' -as [type])) {
            Log ('Native helper compilation failed: ' + $_.Exception.Message)
            exit 0
        }
    }

    $PROCESS_ACCESS = [UInt32]0x0438 # QUERY_INFORMATION | VM_OPERATION | VM_READ | VM_WRITE
    $processHandle = [MnMLiveNativeV3643]::OpenProcess($PROCESS_ACCESS, $false, $game.Id)
    if ($processHandle -eq [IntPtr]::Zero) {
        Log ('OpenProcess failed. Win32=' + [Runtime.InteropServices.Marshal]::GetLastWin32Error())
        exit 0
    }

    function Read-RemoteBytes([Int64]$address, [Int32]$size) {
        if ($size -le 0 -or $size -gt 16777216) { return $null }
        $buffer = New-Object byte[] $size
        $read = [IntPtr]::Zero
        $ok = [MnMLiveNativeV3643]::ReadProcessMemory(
            $processHandle,
            [IntPtr]$address,
            $buffer,
            [IntPtr]$size,
            [ref]$read)
        if (-not $ok -or $read.ToInt64() -ne $size) { return $null }
        return ,$buffer
    }

    function Write-RemoteByte([Int64]$address, [Byte]$value) {
        $buffer = New-Object byte[] 1
        $buffer[0] = $value
        $written = [IntPtr]::Zero
        $ok = [MnMLiveNativeV3643]::WriteProcessMemory(
            $processHandle,
            [IntPtr]$address,
            $buffer,
            [IntPtr]1,
            [ref]$written)
        return ($ok -and $written.ToInt64() -eq 1)
    }


    function Write-RemoteBytes([Int64]$address, [byte[]]$buffer) {
        if ($null -eq $buffer -or $buffer.Length -le 0 -or $buffer.Length -gt 65536) { return $false }
        $written = [IntPtr]::Zero
        $ok = [MnMLiveNativeV3643]::WriteProcessMemory($processHandle,[IntPtr]$address,$buffer,[IntPtr]$buffer.Length,[ref]$written)
        return ($ok -and $written.ToInt64() -eq $buffer.Length)
    }

    function Get-SelectedLanguagePath {
        try {
            $languageCode = 'en'
            $sel = Join-Path $dllsRoot 'langue.txt'
            if (Test-Path -LiteralPath $sel) {
                $first = (Get-Content -LiteralPath $sel -Encoding UTF8 -ErrorAction Stop | Where-Object { $_ -and -not $_.Trim().StartsWith('#') } | Select-Object -First 1)
                if ($first) { $languageCode = $first.Trim() }
            }
            $path = Join-Path (Join-Path $dllsRoot 'lang') ($languageCode + '.txt')
            if (-not (Test-Path -LiteralPath $path)) { return $null }
            return $path
        } catch { return $null }
    }

    function Read-LanguageValue([string]$path,[string]$key) {
        try {
            foreach ($line in (Get-Content -LiteralPath $path -Encoding UTF8 -ErrorAction Stop)) {
                $eq=$line.IndexOf('='); if($eq -lt 0){continue}
                if($line.Substring(0,$eq).Trim() -ieq $key){ return $line.Substring($eq+1).Trim() }
            }
        } catch {}
        return $null
    }

    function Read-RemoteUInt64([Int64]$address) {
        $b = Read-RemoteBytes $address 8
        if ($null -eq $b) { return $null }
        return [BitConverter]::ToUInt64($b,0)
    }

    function Read-RemoteWStringObject([Int64]$objectAddress) {
        try {
            $hdr = Read-RemoteBytes $objectAddress 0x20
            if ($null -eq $hdr) { return $null }
            [UInt64]$len = [BitConverter]::ToUInt64($hdr,0x10)
            [UInt64]$cap = [BitConverter]::ToUInt64($hdr,0x18)
            if ($len -gt 1024 -or $cap -gt 65535 -or $cap -lt $len) { return $null }
            [Int64]$dataAddress = $objectAddress
            if ($cap -ge 8) {
                $dataAddress = [BitConverter]::ToInt64($hdr,0)
                if ($dataAddress -le 0) { return $null }
            }
            [byte[]]$tb = New-Object byte[] 0
            if ($len -gt 0) {
                $tb = Read-RemoteBytes $dataAddress ([int]($len*2))
                if ($null -eq $tb) { return $null }
            }
            return @{
                Address=$objectAddress; DataAddress=$dataAddress; Length=$len; Capacity=$cap;
                Text=([Text.Encoding]::Unicode.GetString($tb))
            }
        } catch { return $null }
    }

    function Get-MnMTranslationMapRva([hashtable]$moduleInfo) {
        # v1.18.14: std::unordered_map layout is unchanged, but the global map object
        # moved together with the compact single-folder core.  The previous watcher
        # still read the legacy 0x116A00 object, which is outside the compact image.
        if ($compactNodeVectorHashes -contains $moduleInfo.Hash) { return [Int64]0x9E1D0 }
        return [Int64]0x116A00
    }

    function Find-MnMTranslationNode([hashtable]$moduleInfo,[string]$key) {
        try {
            if ($null -eq $moduleInfo -or [String]::IsNullOrWhiteSpace($key)) { return $null }
            [Int64]$baseNow = [Int64]$moduleInfo.Base
            [string]$hashNow = [string]$moduleInfo.Hash
            if ($script:translationNodeCacheBase -ne $baseNow -or $script:translationNodeCacheHash -cne $hashNow) {
                $script:translationNodeCache.Clear()
                $script:translationNodeCacheBase = $baseNow
                $script:translationNodeCacheHash = $hashNow
                Log ('Translation-node cache context reset. base=0x{0:X}; hash={1}' -f $baseNow,$hashNow)
            }
            if ($script:translationNodeCache.ContainsKey($key)) {
                [Int64]$cached = [Int64]$script:translationNodeCache[$key]
                if ($cached -gt 0) { return $cached }
                $script:translationNodeCache.Remove($key)
            }

            # MSVC unordered_map object fields verified against both layouts:
            #   +0x08 list sentinel, +0x18 bucket-pair array, +0x30 bucket mask.
            # Each bucket is {stop,node} (16 bytes); nodes keep key +0x10/value +0x30.
            [Int64]$mapRva = Get-MnMTranslationMapRva $moduleInfo
            $g = Read-RemoteBytes ($moduleInfo.Base + $mapRva) 0x40
            if ($null -eq $g) { return $null }
            [Int64]$sentinel = [BitConverter]::ToInt64($g,0x08)
            [Int64]$buckets  = [BitConverter]::ToInt64($g,0x18)
            [UInt64]$mask    = [BitConverter]::ToUInt64($g,0x30)
            [UInt64]$bucketCount = [BitConverter]::ToUInt64($g,0x38)
            if ($sentinel -le 0 -or $buckets -le 0 -or $mask -gt 0x1000000 -or $bucketCount -gt 0x1000001) { return $null }
            if (-not $script:translationMapLayoutLogged) {
                $layout = if ($compactNodeVectorHashes -contains $moduleInfo.Hash) { 'compact-single-folder' } else { 'legacy' }
                Log ('MnM translation map ABI selected: layout=' + $layout + '; rva=0x{0:X}; mask=0x{1:X}; buckets={2}' -f $mapRva,$mask,$bucketCount)
                $script:translationMapLayoutLogged = $true
            }

            [UInt64]$hash = [MnMLiveNativeV3643]::Fnv1aUtf16($key)
            [UInt64]$bucketIndex = $hash -band $mask
            [Int64]$pairAddress = [Int64]($buckets + [Int64]($bucketIndex * 16))
            $pair = Read-RemoteBytes $pairAddress 16
            if ($null -eq $pair) { return $null }
            [Int64]$stop = [BitConverter]::ToInt64($pair,0)
            [Int64]$node = [BitConverter]::ToInt64($pair,8)
            if ($node -eq $sentinel) { return $null }

            for($guard=0;$guard -lt 4096;$guard++) {
                if($node -le 0 -or $node -eq $sentinel){break}
                $keyObj = Read-RemoteWStringObject ($node + 0x10)
                if($null -ne $keyObj -and $keyObj.Text -ceq $key){
                    $script:translationNodeCache[$key] = [Int64]$node
                    return $node
                }
                if($node -eq $stop){break}
                $next = Read-RemoteUInt64 ($node + 0x08)
                if($null -eq $next){break}
                $node = [Int64]$next
            }
        } catch { }
        return $null
    }

    function Get-CachedMnMTranslationValue([hashtable]$moduleInfo,[string]$key) {
        # Cached node lookup is optimistic. If the map was rebuilt in place and the
        # cached value object becomes unreadable, evict just that key and resolve once.
        $node = Find-MnMTranslationNode $moduleInfo $key
        if ($null -eq $node) { return $null }
        $valueObj = Read-RemoteWStringObject ($node + 0x30)
        if ($null -ne $valueObj) { return @{Node=[Int64]$node;Value=$valueObj} }
        if ($script:translationNodeCache.ContainsKey($key)) { $script:translationNodeCache.Remove($key) }
        $node = Find-MnMTranslationNode $moduleInfo $key
        if ($null -eq $node) { return $null }
        $valueObj = Read-RemoteWStringObject ($node + 0x30)
        if ($null -eq $valueObj) { return $null }
        return @{Node=[Int64]$node;Value=$valueObj}
    }

    function Patch-MnMTranslationValue([hashtable]$moduleInfo,[string]$key,[string]$target) {
        if([String]::IsNullOrWhiteSpace($key)-or$null -eq $target){return $false}
        $entry = Get-CachedMnMTranslationValue $moduleInfo $key
        if($null -eq $entry){ Log ('MnM translation key/value unreadable: '+$key); return $false }
        $node = [Int64]$entry.Node
        $valueObj = $entry.Value
        if($valueObj.Text -ceq $target){ return $true }
        # 0.4t deliberately uses constant-width count suffixes. Never change the
        # std::wstring allocation/header in the game; only overwrite its existing buffer.
        if([UInt64]$target.Length -ne [UInt64]$valueObj.Length){
            Log ('MnM translation length guard: '+$key+' oldLen='+$valueObj.Length+' newLen='+$target.Length+' old="'+$valueObj.Text+'" target="'+$target+'"')
            return $false
        }
        if([UInt64]$target.Length -gt [UInt64]$valueObj.Capacity){
            Log ('MnM translation capacity guard: '+$key+' len='+$target.Length+' cap='+$valueObj.Capacity)
            return $false
        }
        [byte[]]$bytes = [Text.Encoding]::Unicode.GetBytes($target + [char]0)
        if(Write-RemoteBytes ([Int64]$valueObj.DataAddress) $bytes){
            Log ('MnM translation count updated: '+$key+' "'+$valueObj.Text+'" -> "'+$target+'"')
            return $true
        }
        Log ('MnM translation write failed: '+$key)
        return $false
    }

    function Sync-MnMTranslationCountLabels([string]$reason) {
        try {
            $langPath = Get-SelectedLanguagePath
            if(-not $langPath){ Log ('MnM translation sync skipped; selected language file unavailable. reason='+$reason); return }
            $moduleInfo = Get-MnMModuleInfo
            if($null -eq $moduleInfo){ return }
            # Keys below are taken from MnMRadar's own supplied zh-cn/en language tables
            # and from MnMChestSaveSync_DSWG.cs UpdateCompletionCountLabels().
            # 0.4t only patched area/chest keys, so fly/mole/wave/puzzle group labels
            # were never copied from the refreshed language file into MnM's live map.
            $keys = @(
                'cat.area_quests',
                'cat.fly','cat.mole','cat.wave','grp.minigames',
                'cat.puzzle_platform','cat.platform','cat.puzzle_slider','cat.slider','cat.puzzle_statue','grp.puzzles',
                'grp.chests',
                'cat.chests_grade1','cat.chests_grade2','cat.chests_grade3','cat.chests_grade4','cat.chests_grade5',
                'cat.chests_key','cat.chests_map','cat.chests_puzzle_sep','cat.chests_puzzle','cat.chests_minigame'
            )
            # v1.18.31: a save helper may finish after a newer Actor/native event.
            # Its language file can therefore be one chest behind, and helper-owned
            # runtime-only puzzle counters can briefly be 0/xx. Never replay those
            # stale derived counters into the live map during a live-save reconcile.
            $liveSaveDerivedKeys=@{}
            if($reason -like 'live-save-sync*'){
                foreach($k in @(
                    'cat.area_quests',
                    'cat.fly','cat.mole','cat.wave','grp.minigames',
                    'cat.puzzle_platform','cat.platform','cat.puzzle_slider','cat.slider','cat.puzzle_statue','grp.puzzles',
                    'grp.chests',
                    'cat.chests_grade1','cat.chests_grade2','cat.chests_grade3','cat.chests_grade4','cat.chests_grade5',
                    'cat.chests_key','cat.chests_map','cat.chests_puzzle_sep','cat.chests_puzzle','cat.chests_minigame'
                )){$liveSaveDerivedKeys[[string]$k]=$true}
            }
            $ok=0; $wanted=0; $skippedDerived=0
            foreach($key in $keys){
                if($liveSaveDerivedKeys.ContainsKey([string]$key)){$skippedDerived++;continue}
                $target=Read-LanguageValue $langPath $key
                if($null -eq $target){continue}
                $wanted++
                if(Patch-MnMTranslationValue $moduleInfo $key $target){$ok++}
            }
            if($skippedDerived -gt 0){
                Log ('MnM translation stale-derived guard: skipped=' + $skippedDerived + '; reason=' + $reason)
            }
            Log ('MnM translation count sync: '+$ok+'/'+$wanted+' labels valid; reason='+$reason+'; lang='+[IO.Path]::GetFileName($langPath))
            # v1.18.27: language/save-derived grp.chests is only a fallback. If the in-process
            # sidecar belongs to this game/save generation, immediately restore native A40/B90.
            Sync-NativeWorldCompleteChestCountLabel ('after-language|' + $reason) | Out-Null
        } catch { Log ('MnM translation count sync failed: '+$_.Exception.Message) }
    }

    function Read-NodeId([Int64]$nodeAddress, [byte[]]$nodeBytes) {
        try {
            if ($null -eq $nodeBytes -or $nodeBytes.Length -lt 0x20) { return $null }
            $length = [BitConverter]::ToUInt64($nodeBytes, 0x10)
            $capacity = [BitConverter]::ToUInt64($nodeBytes, 0x18)
            if ($length -eq 0 -or $length -gt 128) { return $null }
            $byteCount = [int]($length * 2)
            [byte[]]$textBytes = $null
            if ($capacity -lt 8) {
                if ($byteCount -gt 16) { return $null }
                $textBytes = New-Object byte[] $byteCount
                [Array]::Copy($nodeBytes, 0, $textBytes, 0, $byteCount)
            }
            else {
                $stringAddress = [BitConverter]::ToInt64($nodeBytes, 0)
                if ($stringAddress -le 0) { return $null }
                $textBytes = Read-RemoteBytes $stringAddress $byteCount
                if ($null -eq $textBytes) { return $null }
            }
            return [Text.Encoding]::Unicode.GetString($textBytes)
        }
        catch { return $null }
    }

    $supportedHashes = @{
        '831f735ade75439ed92127227ce4975dee263654c941b20abc83763d7a578b33' = 'adaptive_2m_3confirm'
        # DSWorldRadar v1.15c FINAL: same MnMRadar 1.4 ABI; only UI/hotkey/runtime-gate bytes differ.
        # DSWorldRadar v1.17 single-folder localized master-switch core variants.
        'a0e6077fada436350dacdce48c1a40648849dd58e18e564d4ba36431ec0acf2b' = 'adaptive_2m_3confirm' # v1.17 en
        'c621ce0acdfed32046f19471ec05702c6fdabecb3841d32ea7dd6fab8c889f40' = 'adaptive_2m_3confirm' # v1.17 fr
        'd1bfc91ee9a71b10afdfda009f6e5554e1301aa61029a106388f4803f9601282' = 'adaptive_2m_3confirm' # v1.17 zh-cn
        '9486c1713dca87df3c067110fcc71b3a43b969d4a665ce930b98d194add81978' = 'adaptive_2m_3confirm' # v1.17 zh-tw
        # PERF TEST B6: preserve 4000-object slice, but run the dynamic UObject slice only once every 32 PostRender frames.
        '7502395b6702c1f1296ac4bad1b64b4d16941e329c427519bf21c07b620ad67e' = 'adaptive_2m_3confirm' # v1.18 FINAL performance-throttled core
        '9510d0bb4045b88a7aa66dce31e5ed76dac8b7a216941263e39dac2bbe16db6d' = 'adaptive_2m_3confirm' # PERF B6 fr
        'c89e5967516020d5aa84dd98a905873b5c1dc569a34c7ac4e70614248071cb95' = 'adaptive_2m_3confirm' # PERF B6 zh-cn
        'abdbf4c7fbb10bd947c9877bc86df1b497d2ab8c144dbf9137a845ef10802912' = 'adaptive_2m_3confirm' # PERF B6 zh-tw
        'ea167642ce2570f5107fa158a66bbb6b0c8896bf8d74ffc3ea9d0ff257d1be04' = 'balanced_3m'
        '6dc317fad1d387f286170bdb95a1b9b7418d3988a35c2b535039c98609bd82ae' = 'strict_0m'
    }

    # v1.18.5: the single-folder compact cores have a different .data layout from
    # the older MnMRadar 1.4 binary.  Their real node vector is at RVA 0x9E1B8,
    # not the legacy 0x1170B0 address (which lies outside the compact image).
    $compactNodeVectorHashes = @(
        'a0e6077fada436350dacdce48c1a40648849dd58e18e564d4ba36431ec0acf2b',
        'c621ce0acdfed32046f19471ec05702c6fdabecb3841d32ea7dd6fab8c889f40',
        'd1bfc91ee9a71b10afdfda009f6e5554e1301aa61029a106388f4803f9601282',
        '9486c1713dca87df3c067110fcc71b3a43b969d4a665ce930b98d194add81978',
        '7502395b6702c1f1296ac4bad1b64b4d16941e329c427519bf21c07b620ad67e',
        '9510d0bb4045b88a7aa66dce31e5ed76dac8b7a216941263e39dac2bbe16db6d',
        'c89e5967516020d5aa84dd98a905873b5c1dc569a34c7ac4e70614248071cb95',
        'abdbf4c7fbb10bd947c9877bc86df1b497d2ab8c144dbf9137a845ef10802912'
    )

    function Get-MnMModuleInfo {
        try {
            # v1.18.2:
            # 1) Toolhelp32 module enumeration is the primary path because it sees
            #    dynamically LoadLibrary-loaded main_original.dll reliably even when
            #    System.Diagnostics.Process.Modules is stale/cached.
            # 2) Process.Modules remains a compatibility fallback.
            # 3) The 7 KB proxy main.dll is never accepted as the MnMRadar ABI target.
            if ($null -ne $script:cachedMnMModuleInfo) { return $script:cachedMnMModuleInfo }
            if ($script:runtimeMemoryDisabled) { return $null }

            $realSuffix = '\DSWorldRadar\dlls\main_original.dll'
            [IntPtr]$toolBase = [IntPtr]::Zero
            [UInt32]$toolSize = 0
            [string]$toolPath = $null

            try {
                $toolFound = [MnMLiveNativeV3643]::FindModuleByPathSuffix(
                    [Int32]$game.Id,
                    $realSuffix,
                    [ref]$toolBase,
                    [ref]$toolSize,
                    [ref]$toolPath)

                if ($toolFound -and $toolBase -ne [IntPtr]::Zero -and -not [String]::IsNullOrWhiteSpace($toolPath)) {
                    $hash = (Get-FileHash -LiteralPath $toolPath -Algorithm SHA256).Hash.ToLowerInvariant()
                    if ($supportedHashes.ContainsKey($hash)) {
                        $info = @{
                            Base = [Int64]$toolBase.ToInt64()
                            Hash = $hash
                            Mode = $supportedHashes[$hash]
                            Path = $toolPath
                        }
                        $script:cachedMnMModuleInfo = $info
                        Log ('DSWorldRadar real runtime core ABI verified by Toolhelp32 and cached. path=' + $toolPath +
                             '; base=0x{0:X}; imageBytes={1}; sha256={2}; mode={3}' -f
                             $info.Base, $toolSize, $hash, $info.Mode)
                        return $info
                    }
                    else {
                        $script:runtimeMemoryDisabled = $true
                        Log ('Unsupported Experimental DSWorldRadar real core found by Toolhelp32; runtime-memory patching disabled for this session. path=' +
                             $toolPath + '; sha256=' + $hash + '; imageBytes=' + $toolSize)
                        return $null
                    }
                }
            }
            catch {
                Log ('Toolhelp32 core lookup failed; Process.Modules fallback will be tried: ' + $_.Exception.Message)
            }

            $game.Refresh()
            $modules = @($game.Modules)
            $candidates = New-Object System.Collections.Generic.List[object]

            foreach ($m in $modules) {
                if ($m.ModuleName -ieq 'main_original.dll' -and
                    $m.FileName -match '(?i)\\DSWorldRadar\\dlls\\main_original\.dll$') {
                    $candidates.Add($m)
                }
            }

            foreach ($m in $modules) {
                if ($m.ModuleName -ieq 'main.dll' -and
                    $m.FileName -match '(?i)\\DSWorldRadar\\dlls\\main\.dll$') {
                    try {
                        $len = (Get-Item -LiteralPath $m.FileName -ErrorAction Stop).Length
                        if ($len -ge 500000) {
                            $candidates.Add($m)
                        }
                        else {
                            Log ('DSWorldRadar proxy detected and skipped for runtime ABI lookup: ' + $m.FileName + '; bytes=' + $len)
                        }
                    }
                    catch { }
                }
            }

            if ($candidates.Count -eq 0) {
                Log 'DSWorldRadar real native core is not visible yet; runtime hide deferred and queued IDs will retry.'
                return $null
            }

            $unsupported = New-Object System.Collections.Generic.List[string]
            foreach ($module in $candidates) {
                try {
                    $hash = (Get-FileHash -LiteralPath $module.FileName -Algorithm SHA256).Hash.ToLowerInvariant()
                    if (-not $supportedHashes.ContainsKey($hash)) {
                        $unsupported.Add(($module.FileName + '|sha256=' + $hash))
                        continue
                    }

                    $info = @{
                        Base = [Int64]$module.BaseAddress.ToInt64()
                        Hash = $hash
                        Mode = $supportedHashes[$hash]
                        Path = $module.FileName
                    }
                    $script:cachedMnMModuleInfo = $info
                    Log ('DSWorldRadar real runtime core ABI verified by Process.Modules fallback and cached. path=' +
                         $module.FileName + '; sha256=' + $hash + '; mode=' + $info.Mode)
                    return $info
                }
                catch {
                    $unsupported.Add(($module.FileName + '|error=' + $_.Exception.Message))
                }
            }

            $script:runtimeMemoryDisabled = $true
            Log ('Unsupported Experimental DSWorldRadar real core; runtime-memory patching disabled for this session. candidates=' + ($unsupported -join ' ; '))
            return $null
        }
        catch {
            Log ('Module lookup failed: ' + $_.Exception.Message)
            return $null
        }
    }

    function Get-NodeVectorHeaderInfo([hashtable]$moduleInfo) {
        # v1.18.31 lightweight vector identity check: 16 bytes only.  Used by the
        # 120s anti-revive guard so it never needs a full ~1 MB vector body just to
        # reassert one recently opened chest.
        try {
            [Int64]$vectorRva = 0x1170B0
            [string]$layout = 'legacy'
            if ($compactNodeVectorHashes -contains $moduleInfo.Hash) {
                $vectorRva = 0x9E1B8
                $layout = 'compact-single-folder'
            }
            $vectorHeader = Read-RemoteBytes ($moduleInfo.Base + $vectorRva) 16
            if ($null -eq $vectorHeader) { return $null }
            [Int64]$start = [BitConverter]::ToInt64($vectorHeader,0)
            [Int64]$end = [BitConverter]::ToInt64($vectorHeader,8)
            if ($start -le 0 -or $end -le $start) { return $null }
            [Int64]$span = $end - $start
            if (($span % 0x70) -ne 0) { return $null }
            [int]$count = [int]($span / 0x70)
            if ($count -lt 1000 -or $count -gt 20000) { return $null }
            return @{Start=$start;End=$end;Count=$count;Rva=$vectorRva;Layout=$layout}
        } catch { return $null }
    }

    function Get-NodeVector([hashtable]$moduleInfo) {
        # Node ABI is stable (0x70 bytes, completion byte +0x58), but the global
        # std::vector moved when DSWorldRadar switched to the compact single-folder core.
        [Int64]$vectorRva = 0x1170B0
        [string]$layout = 'legacy'
        if ($compactNodeVectorHashes -contains $moduleInfo.Hash) {
            $vectorRva = 0x9E1B8
            $layout = 'compact-single-folder'
        }
        $vectorHeader = Read-RemoteBytes ($moduleInfo.Base + $vectorRva) 16
        if ($null -eq $vectorHeader) {
            Log ('Unable to read MnMRadar node-vector header. layout=' + $layout +
                 '; rva=0x{0:X}' -f $vectorRva)
            return $null
        }
        $start = [BitConverter]::ToInt64($vectorHeader, 0)
        $end = [BitConverter]::ToInt64($vectorHeader, 8)
        if ($start -le 0 -or $end -le $start) {
            Log ('Invalid node-vector pointers: start=0x{0:X} end=0x{1:X}' -f $start, $end)
            return $null
        }
        $span = $end - $start
        if (($span % 0x70) -ne 0) {
            Log ('Invalid node-vector span/alignment: ' + $span)
            return $null
        }
        $count = [int]($span / 0x70)
        if ($count -lt 1000 -or $count -gt 20000) {
            Log ('Unexpected node-vector count: ' + $count + '; layout=' + $layout + '; rva=0x{0:X}' -f $vectorRva)
            return $null
        }
        if (-not $script:nodeVectorLayoutLogged) {
            Log ('MnMRadar node-vector verified. layout=' + $layout + '; rva=0x{0:X}; count={1}; nodeSize=0x70' -f $vectorRva, $count)
            $script:nodeVectorLayoutLogged = $true
        }
        $all = Read-RemoteBytes $start ([int]$span)
        if ($null -eq $all) {
            Log ('Unable to read MnMRadar node-vector body. count=' + $count)
            return $null
        }
        return @{
            Start = $start
            End = $end
            Count = $count
            Bytes = $all
        }
    }

    function Find-NodeAddressById(
        [string]$nodeId,
        [hashtable]$vector) {
        $bytes = $vector.Bytes

        # First pass: exact coordinate candidates when a trusted coordinate exists,
        # then verify the std::wstring ID before returning an address.
        if ($nodeCoords.ContainsKey($nodeId)) {
            $coord = $nodeCoords[$nodeId]
            $targetX = [double]$coord[0]
            $targetY = [double]$coord[1]
            $targetZ = [double]$coord[2]
            for ($i = 0; $i -lt $vector.Count; $i++) {
                $offset = $i * 0x70
                $x = [BitConverter]::ToDouble($bytes, $offset + 0x40)
                $y = [BitConverter]::ToDouble($bytes, $offset + 0x48)
                $z = [BitConverter]::ToDouble($bytes, $offset + 0x50)
                if ([Math]::Abs($x - $targetX) -le 0.51 -and
                    [Math]::Abs($y - $targetY) -le 0.51 -and
                    [Math]::Abs($z - $targetZ) -le 0.51) {
                    $nodeAddress = [Int64]($vector.Start + $offset)
                    $header = New-Object byte[] 0x20
                    [Array]::Copy($bytes, $offset, $header, 0, 0x20)
                    $memoryId = Read-NodeId $nodeAddress $header
                    if ($memoryId -ceq $nodeId) {
                        return $nodeAddress
                    }
                }
            }
        }

        # Conservative fallback: scan only nodes with the same string length.
        # This is slower but still verifies the exact ID before any write.
        for ($i = 0; $i -lt $vector.Count; $i++) {
            $offset = $i * 0x70
            $length = [BitConverter]::ToUInt64($bytes, $offset + 0x10)
            if ($length -ne [UInt64]$nodeId.Length) { continue }
            $nodeAddress = [Int64]($vector.Start + $offset)
            $header = New-Object byte[] 0x20
            [Array]::Copy($bytes, $offset, $header, 0, 0x20)
            $memoryId = Read-NodeId $nodeAddress $header
            if ($memoryId -ceq $nodeId) {
                return $nodeAddress
            }
        }

        return [Int64]0
    }

    function Hide-ExactNodes([string[]]$ids) {
        if ($null -eq $ids -or $ids.Count -eq 0) { return }
        if ($game.HasExited) { return }

        # v1.18.2: never lose a save-confirmed completion just because the real
        # main_original.dll or its node vector is not visible at that exact instant.
        foreach ($rawId in $ids) {
            if ([String]::IsNullOrWhiteSpace($rawId)) { continue }
            $id = $rawId.Trim()
            if ($id.Length -gt 0) { $script:pendingHideIds[$id] = $true }
        }
        if ($script:pendingHideIds.Count -eq 0) { return }

        $moduleInfo = Get-MnMModuleInfo
        if ($null -eq $moduleInfo) { return }
        $vector = Get-NodeVector $moduleInfo
        if ($null -eq $vector) { return }

        $targets = @($script:pendingHideIds.Keys)
        Log ('Runtime hide begin. mode=' + $moduleInfo.Mode + '; vectorCount=' + $vector.Count +
             '; queued=' + $targets.Count + '; ids=' + ($targets -join ','))

        foreach ($id in $targets) {
            if ([String]::IsNullOrWhiteSpace($id)) {
                $script:pendingHideIds.Remove($id)
                continue
            }
            $nodeAddress = Find-NodeAddressById $id $vector
            if ($nodeAddress -le 0) {
                # If it is not in the in-memory vector, it is already absent from the
                # current runtime catalog or is not a MnMRadar node. Do not spin forever.
                Log ('Exact node not found in MnMRadar memory; dropping queued hide as already absent/non-runtime: ' + $id)
                $script:pendingHideIds.Remove($id)
                continue
            }
            $before = Read-RemoteBytes ($nodeAddress + 0x58) 1
            if ($null -ne $before -and $before[0] -eq 1) {
                Log ('Node already hidden in runtime: ' + $id)
                $script:pendingHideIds.Remove($id)
                continue
            }
            if (Write-RemoteByte ($nodeAddress + 0x58) 1) {
                Log ('Runtime hidden by exact NodeID: ' + $id)
                $script:pendingHideIds.Remove($id)
            }
            else {
                Log ('WriteProcessMemory failed for ' + $id + '. Win32=' + [Runtime.InteropServices.Marshal]::GetLastWin32Error() +
                     '; ID remains queued for retry.')
            }
        }
    }

    function Flush-PendingHideIds {
        if ($script:pendingHideIds.Count -eq 0 -or $game.HasExited) { return }
        Hide-ExactNodes @($script:pendingHideIds.Keys)
    }

    function Reset-ActorCompletionSessionCache([string]$reason) {
        try {
            $script:actorCompletedIds.Clear()
            $script:actorStrongGuardUntil.Clear()
            $script:lastActorStrongGuardUtc = [DateTime]::MinValue
            $script:actorCandidateIds.Clear()
            $script:pendingHideIds.Clear()
            $script:translationNodeCache.Clear()
            Log ('Save-boundary actor completion cache reset. reason=' + $reason)
        } catch {
            Log ('Save-boundary actor completion cache reset failed: ' + $_.Exception.Message)
        }
    }

    function Build-ChestOffsetCache([hashtable]$vector) {
        $lookup = @{}
        foreach ($id in @($script:chestResetIds.Keys)) {
            if (-not $nodeCoords.ContainsKey($id)) { continue }
            $c = $nodeCoords[$id]
            $key = ([Int64][Math]::Round([double]$c[0])).ToString() + '|' +
                   ([Int64][Math]::Round([double]$c[1])).ToString() + '|' +
                   ([Int64][Math]::Round([double]$c[2])).ToString()
            if (-not $lookup.ContainsKey($key)) { $lookup[$key] = New-Object System.Collections.Generic.List[string] }
            [void]$lookup[$key].Add([string]$id)
        }
        $cache = @{}
        for ($i = 0; $i -lt $vector.Count; $i++) {
            $offset = $i * 0x70
            $x = [BitConverter]::ToDouble($vector.Bytes, $offset + 0x40)
            $y = [BitConverter]::ToDouble($vector.Bytes, $offset + 0x48)
            $z = [BitConverter]::ToDouble($vector.Bytes, $offset + 0x50)
            $key = ([Int64][Math]::Round($x)).ToString() + '|' + ([Int64][Math]::Round($y)).ToString() + '|' + ([Int64][Math]::Round($z)).ToString()
            if (-not $lookup.ContainsKey($key)) { continue }
            $nodeAddress = [Int64]($vector.Start + $offset)
            $header = New-Object byte[] 0x20
            [Array]::Copy($vector.Bytes, $offset, $header, 0, 0x20)
            $memoryId = Read-NodeId $nodeAddress $header
            if ([String]::IsNullOrWhiteSpace($memoryId)) { continue }
            foreach ($candidate in @($lookup[$key])) {
                if ($memoryId -ceq [string]$candidate) { $cache[[string]$candidate] = $offset; break }
            }
        }
        $script:chestOffsetCache = $cache
        $script:chestOffsetCacheVectorStart = [Int64]$vector.Start
        $script:chestOffsetCacheVectorCount = [int]$vector.Count
        Log ('Chest offset cache built: ' + $cache.Count + '/' + $script:chestResetIds.Count)
    }

    function Reconcile-RuntimeChestState([hashtable]$desired,[string]$reason) {
        if ($game.HasExited) { return $false }
        # v1.18.20: a strong treasure-open Actor event is current-generation evidence.
        # Never let a stale save snapshot or the native actor-presence scan revive it.
        # Save-boundary reset clears actorCompletedIds before a different save is applied.
        $effectiveDesired = @{}
        foreach ($k in @($desired.Keys)) { $effectiveDesired[[string]$k] = $true }
        foreach ($k in @($script:actorCompletedIds.Keys)) { $effectiveDesired[[string]$k] = $true }
        $moduleInfo = Get-MnMModuleInfo
        if ($null -eq $moduleInfo) { return $false }
        $vector = Get-NodeVector $moduleInfo
        if ($null -eq $vector) { return $false }
        if ($script:chestOffsetCache.Count -lt $script:chestResetIds.Count -or $script:chestOffsetCacheVectorStart -ne [Int64]$vector.Start -or $script:chestOffsetCacheVectorCount -ne [int]$vector.Count) { Build-ChestOffsetCache $vector }
        if ($script:chestOffsetCache.Count -lt 1) { return $false }
        $setOne=0; $setZero=0; $same=0; $missing=0; $writeFail=0
        foreach ($id in @($script:chestResetIds.Keys)) {
            if (-not $script:chestOffsetCache.ContainsKey($id)) { $missing++; continue }
            $offset = [Int64]$script:chestOffsetCache[$id]
            if ($offset -lt 0 -or ($offset + 0x58) -ge $vector.Bytes.Length) { $missing++; continue }
            $want = if ($effectiveDesired.ContainsKey([string]$id)) { 1 } else { 0 }
            $have = [int]$vector.Bytes[$offset + 0x58]
            if ($have -eq $want) { $same++; continue }
            if (Write-RemoteByte ([Int64]($vector.Start + $offset + 0x58)) ([byte]$want)) {
                if ($want -eq 1) { $setOne++ } else { $setZero++ }
            } else { $writeFail++ }
        }
        $script:watcherChestSnapshot = $effectiveDesired
        Log ('Chest state reconciled cached-pass: desired=' + $effectiveDesired.Count + '; set1=' + $setOne + '; set0=' + $setZero + '; same=' + $same + '; missing=' + $missing + '; writeFail=' + $writeFail + '; reason=' + $reason)
        return ($writeFail -eq 0 -and $missing -eq 0)
    }

    function Hide-ChestIdsByOffsetCache([string[]]$ids,[string]$reason) {
        if ($null -eq $ids -or $ids.Count -eq 0 -or $game.HasExited) { return $false }
        $moduleInfo=Get-MnMModuleInfo; if($null -eq $moduleInfo){return $false}

        # v1.18.31 fast path: once the chest offset cache has been built, a normal
        # open event needs only the 16-byte vector header plus one done byte per ID.
        # A full vector body is read only when the vector identity changes or the
        # cache is not initialized yet.
        $header=Get-NodeVectorHeaderInfo $moduleInfo
        if($null -ne $header -and $script:chestOffsetCache.Count -gt 0 -and
           $script:chestOffsetCacheVectorStart -eq [Int64]$header.Start -and
           $script:chestOffsetCacheVectorCount -eq [int]$header.Count){
            $missing=New-Object System.Collections.Generic.List[string];$hidden=0;$already=0;$fail=0
            foreach($rawId in $ids){
                if([String]::IsNullOrWhiteSpace($rawId)){continue}
                $id=([string]$rawId).Trim()
                if(-not $script:chestOffsetCache.ContainsKey($id)){[void]$missing.Add($id);continue}
                [Int64]$offset=[Int64]$script:chestOffsetCache[$id]
                if($offset -lt 0 -or $offset -ge ([Int64]$header.Count*0x70)){[void]$missing.Add($id);continue}
                [Int64]$addr=[Int64]$header.Start+$offset+0x58
                $b=Read-RemoteBytes $addr 1
                if($null -eq $b){$fail++;continue}
                if([int]$b[0] -eq 1){$already++;continue}
                if(Write-RemoteByte $addr ([byte]1)){$hidden++}else{$fail++}
            }
            if($missing.Count -gt 0){Hide-ExactNodes @($missing)}
            if($reason -notlike 'actor-strong-reassert*' -or $hidden -gt 0 -or $missing.Count -gt 0 -or $fail -gt 0){
                Log ('Actor chest cached-byte fast-hide: hidden=' + $hidden + '; already=' + $already + '; missing=' + $missing.Count + '; fail=' + $fail + '; reason=' + $reason)
            }
            return ($fail -eq 0)
        }

        # Cache-build / vector-change fallback: one full vector read, then retain all
        # chest offsets for subsequent events and anti-revive passes.
        $vector=Get-NodeVector $moduleInfo; if($null -eq $vector){return $false}
        if($script:chestOffsetCache.Count -lt $script:chestResetIds.Count -or
           $script:chestOffsetCacheVectorStart -ne [Int64]$vector.Start -or
           $script:chestOffsetCacheVectorCount -ne [int]$vector.Count){Build-ChestOffsetCache $vector}
        $missing=New-Object System.Collections.Generic.List[string];$hidden=0;$already=0;$fail=0
        foreach($rawId in $ids){
            if([String]::IsNullOrWhiteSpace($rawId)){continue}
            $id=([string]$rawId).Trim()
            if(-not $script:chestOffsetCache.ContainsKey($id)){[void]$missing.Add($id);continue}
            $offset=[Int64]$script:chestOffsetCache[$id]
            if($offset -lt 0 -or ($offset+0x58) -ge $vector.Bytes.Length){[void]$missing.Add($id);continue}
            $have=[int]$vector.Bytes[$offset+0x58]
            if($have -eq 1){$already++;continue}
            if(Write-RemoteByte ([Int64]($vector.Start+$offset+0x58)) ([byte]1)){$hidden++}else{$fail++}
        }
        if($missing.Count -gt 0){Hide-ExactNodes @($missing)}
        Log ('Actor chest full-vector cache-build hide: hidden=' + $hidden + '; already=' + $already + '; missing=' + $missing.Count + '; fail=' + $fail + '; reason=' + $reason)
        return ($fail -eq 0)
    }

    function Reassert-ChestIdsByCachedOffsets([string[]]$ids,[string]$reason) {
        if ($null -eq $ids -or $ids.Count -eq 0 -or $game.HasExited) { return $false }
        $moduleInfo=Get-MnMModuleInfo; if($null -eq $moduleInfo){return $false}
        $header=Get-NodeVectorHeaderInfo $moduleInfo
        if($null -eq $header){return $false}
        if($script:chestOffsetCache.Count -lt $script:chestResetIds.Count -or
           $script:chestOffsetCacheVectorStart -ne [Int64]$header.Start -or
           $script:chestOffsetCacheVectorCount -ne [int]$header.Count){
            # Vector identity changed or cache is not ready. Rebuild once through the
            # proven full-vector path; subsequent 500ms guard passes become byte-only.
            return (Hide-ChestIdsByOffsetCache $ids ($reason + '-cache-rebuild'))
        }
        $recovered=0;$already=0;$missing=0;$fail=0
        foreach($rawId in $ids){
            if([String]::IsNullOrWhiteSpace($rawId)){continue}
            $id=([string]$rawId).Trim()
            if(-not $script:chestOffsetCache.ContainsKey($id)){$missing++;continue}
            [Int64]$offset=[Int64]$script:chestOffsetCache[$id]
            if($offset -lt 0 -or $offset -ge ([Int64]$header.Count*0x70)){$missing++;continue}
            [Int64]$addr=[Int64]$header.Start+$offset+0x58
            $b=Read-RemoteBytes $addr 1
            if($null -eq $b){$fail++;continue}
            if([int]$b[0] -eq 1){$already++;continue}
            if(Write-RemoteByte $addr ([byte]1)){$recovered++}else{$fail++}
        }
        if($missing -gt 0){
            # Exact fallback is bounded to IDs absent from the verified offset cache.
            $fallback=@($ids | Where-Object { $_ -and -not $script:chestOffsetCache.ContainsKey(([string]$_).Trim()) })
            if($fallback.Count -gt 0){Hide-ExactNodes $fallback}
        }
        if($recovered -gt 0 -or $fail -gt 0){
            Log ('Actor chest byte-only anti-revive: recovered=' + $recovered + '; already=' + $already + '; missing=' + $missing + '; fail=' + $fail + '; reason=' + $reason)
        }
        return ($fail -eq 0)
    }

    function Service-ActorStrongCompletionGuard {
        if ($script:actorStrongGuardUntil.Count -eq 0 -or $game.HasExited) { return }
        $now = [DateTime]::UtcNow
        if (($now - $script:lastActorStrongGuardUtc).TotalMilliseconds -lt 500) { return }
        $script:lastActorStrongGuardUtc = $now
        $active = New-Object System.Collections.Generic.List[string]
        foreach ($id in @($script:actorStrongGuardUntil.Keys)) {
            $until = $script:actorStrongGuardUntil[$id]
            if ($null -eq $until -or $now -gt [DateTime]$until) {
                $script:actorStrongGuardUntil.Remove($id)
                continue
            }
            [void]$active.Add([string]$id)
        }
        if ($active.Count -eq 0) { return }
        # Keep the just-opened chest hidden while MnMRadar's slower presence scan can still
        # observe the old Actor and write done=0.  This is external Read/WriteProcessMemory,
        # never a UObject scan and never runs on the game thread.
        [void](Reassert-ChestIdsByCachedOffsets @($active) 'actor-strong-reassert-500ms')
    }

    function Reapply-CurrentSaveChestSnapshot([string]$reason) {
        # fast_live_chest_snapshot.txt is produced by the same fast-live pass that
        # identifies the active slot.  An existing but empty file is a valid 0-opened
        # save.  If the snapshot is unavailable, fail closed and do not invent state.
        try {
            if (-not (Test-Path -LiteralPath $script:fastChestSnapshotPath)) {
                Log ('Chest generation reapply deferred; authoritative fast snapshot missing. reason=' + $reason)
                return $false
            }
            $current = Read-FastChestSnapshotMap
            $ok = Reconcile-RuntimeChestState $current ('authoritative-snapshot|' + $reason)
            # Pressure-puzzle reward chests are instant-open completion witnesses.
            # Reconcile both directions so the 150xx ID collision with true SliderPuzzle
            # can never leak a slider completion into a pressure marker after a slot switch.
            $moduleInfo=Get-MnMModuleInfo
            $vector=if($null -ne $moduleInfo){Get-NodeVector $moduleInfo}else{$null}
            [void](Reconcile-PressurePuzzleStateFromChestAuthority $moduleInfo $vector ('authoritative-snapshot|' + $reason))
            return $ok
        } catch {
            Log ('Chest generation reapply failed: ' + $_.Exception.Message)
            return $false
        }
    }


    # v1.18.38: the destination save's fly/mole/wave + true SliderPuzzle bytes are
    # already refreshed by the game before the save helper reports the new Slot in
    # normal load transitions.  The old v1.18.36 path then cleared those correct
    # destination bytes to zero when no cache existed.  Capture two stable snapshots
    # into the destination profile instead of destroying them.
    function Capture-BoundaryRuntimeProfiles([string]$slot,[string]$reason) {
        if ([String]::IsNullOrWhiteSpace($slot) -or $game.HasExited) { return $false }
        try {
            $module1 = Get-MnMModuleInfo
            if ($null -eq $module1) { return $false }
            $vector1 = Get-NodeVector $module1
            if ($null -eq $vector1) { return $false }

            # Pressure puzzles are chest-authoritative; make their 48 runtime bytes match
            # the newly selected save before the corrected 132-node snapshot is fingerprinted.
            Reconcile-PressurePuzzleStateFromChestAuthority $module1 $vector1 ('boundary-capture|' + $reason) | Out-Null

            $state1 = Get-RuntimeTransientCompletionCounts
            $slider1 = Reconcile-SliderPuzzleStateFromChestAuthority $module1 $null ('boundary-capture|' + $reason)
            if($null -eq $slider1){$slider1 = Get-RuntimeStaticSliderCount $module1 $null}
            if ($null -eq $state1 -or $null -eq $slider1) { return $false }

            $sig161a = (@($state1.CompletedIds | ForEach-Object { [string]$_ } | Sort-Object -Unique) -join ',')
            $sigSlida = (@($slider1.CompletedIds | ForEach-Object { [string]$_ } | Sort-Object -Unique) -join ',')

            Start-Sleep -Milliseconds 220
            if ($game.HasExited) { return $false }

            $module2 = Get-MnMModuleInfo
            if ($null -eq $module2) { return $false }
            $vector2 = Get-NodeVector $module2
            if ($null -eq $vector2) { return $false }
            Reconcile-PressurePuzzleStateFromChestAuthority $module2 $vector2 ('boundary-capture-confirm|' + $reason) | Out-Null

            $state2 = Get-RuntimeTransientCompletionCounts
            $slider2 = Reconcile-SliderPuzzleStateFromChestAuthority $module2 $null ('boundary-capture-confirm|' + $reason)
            if($null -eq $slider2){$slider2 = Get-RuntimeStaticSliderCount $module2 $null}
            if ($null -eq $state2 -or $null -eq $slider2) { return $false }

            $sig161b = (@($state2.CompletedIds | ForEach-Object { [string]$_ } | Sort-Object -Unique) -join ',')
            $sigSlidb = (@($slider2.CompletedIds | ForEach-Object { [string]$_ } | Sort-Object -Unique) -join ',')
            if ($sig161a -cne $sig161b -or $sigSlida -cne $sigSlidb) {
                Log ('Boundary runtime profile capture deferred; destination state still changing. runtime161=' +
                     $state1.CompletedIds.Count + '->' + $state2.CompletedIds.Count +
                     '; slider=' + $slider1.CompletedIds.Count + '->' + $slider2.CompletedIds.Count +
                     '; reason=' + $reason)
                return $false
            }

            $dir = Get-SaveProfileDir $slot $true
            if ([String]::IsNullOrWhiteSpace($dir)) { return $false }

            $set161 = @{}
            foreach($id in @($state2.CompletedIds)){ if(-not [String]::IsNullOrWhiteSpace([string]$id)){$set161[[string]$id]=$true} }
            $setSlider = @{}
            foreach($id in @($slider2.CompletedIds)){ if(-not [String]::IsNullOrWhiteSpace([string]$id)){$setSlider[[string]$id]=$true} }

            if (-not (Write-IdSetFileAtomic (Join-Path $dir 'transient161.txt') $set161)) { return $false }
            if (-not (Write-IdSetFileAtomic (Join-Path $dir 'slider29.txt') $setSlider)) { return $false }
            [IO.File]::WriteAllText((Join-Path $dir 'transient161.v2.valid'),((Get-Date).ToString('O')+"`r`n"),(New-Object Text.UTF8Encoding($false)))
            [IO.File]::WriteAllText((Join-Path $dir 'slider29.v1.valid'),((Get-Date).ToString('O')+"`r`n"),(New-Object Text.UTF8Encoding($false)))
            [IO.File]::WriteAllText((Join-Path $dir 'slot_path.txt'),($slot+"`r`n"),(New-Object Text.UTF8Encoding($false)))
            $script:profileWarmTransientSlot = $slot
            Log ('Boundary destination runtime profiles captured without clearing: key=' + (Get-SaveProfileKey $slot) +
                 '; runtime161=' + $set161.Count + '; slider29=' + $setSlider.Count + '; reason=' + $reason)
            return $true
        } catch {
            Log ('Boundary runtime profile capture failed: ' + $_.Exception.Message + '; reason=' + $reason)
            return $false
        }
    }

    function Consume-RuntimeCompletionResetRequest {
    if(-not (Test-Path -LiteralPath $script:runtimeResetRequestPath)){return}
    if([DateTime]::UtcNow -lt $script:boundaryRestoreRetryAt){return}
    $reason=''
    try{$reason=(Get-Content -LiteralPath $script:runtimeResetRequestPath -Raw -ErrorAction Stop).Trim()}catch{return}
    if([string]::IsNullOrWhiteSpace($reason)){return}
    $currentSlot=Get-AuthoritativeProfileSlot
    if([string]::IsNullOrWhiteSpace($currentSlot)){return}
    $generationReset=($reason -match '(?i)(?:^|;)generation_reset=1(?:;|$)')
    if(-not $generationReset -and $script:lastKnownFastSlot.Length -gt 0 -and $currentSlot -ne $script:lastKnownFastSlot){$generationReset=$true}
    $requestKey=$currentSlot+'|'+$reason
    $warm161=$false
    if($generationReset -and $script:preparedBoundaryRequest -cne $requestKey){
        if($script:actorGenerationPreReset){$script:actorGenerationPreReset=$false}
        else{Reset-ActorCompletionSessionCache $reason}
        if($script:nativeGenerationPreInvalidated){$script:nativeGenerationPreInvalidated=$false}
        else{
            if(-not $script:saveTransitionPending){$script:nativeChestGenerationEpochUtc=[DateTime]::UtcNow}
            $script:lastNativeChestSignature=''
            $script:lastNativeChestAvailability='generation-reset'
            $script:lastNativeMiniGameAvailability='generation-reset'
        }
        $warm161=Capture-BoundaryRuntimeProfiles $currentSlot $reason
        if(-not $warm161){
            Apply-TransientProfileIfValid $currentSlot $reason | Out-Null
            Apply-StaticSliderProfileIfValid $currentSlot $reason | Out-Null
        }
        Reset-ExactAreaCompletionSessionCache $reason
        $script:preparedBoundaryRequest=$requestKey
    }
    if($generationReset){
        $chestOk=Reapply-CurrentSaveChestSnapshot $reason
        $areaOk=$false
        if($null -ne $script:authoritySnapshot){
            $areaOk=Set-RuntimeAreaStateFromIdSet (Read-FastAreaSnapshotMap) ('authoritative-boundary|'+$reason)
        }
        if(-not $chestOk -or -not $areaOk){
            $script:boundaryRestoreRetryAt=[DateTime]::UtcNow.AddSeconds(1)
            Log ('Boundary memory restore deferred; request retained. chest='+$chestOk+'; area='+$areaOk)
            return
        }
        Sync-ImmediateChestCategoryCounts 'save-boundary-authoritative' @() | Out-Null
    }else{Reapply-ExactAreaCompletions 'same-slot-travel-preserve'}
    # A replacement request must never be removed by completion of an older one.
    try{
        if((Get-Content -LiteralPath $script:runtimeResetRequestPath -Raw -ErrorAction Stop).Trim() -ceq $reason){
            Remove-Item -LiteralPath $script:runtimeResetRequestPath -Force -ErrorAction Stop
        }
    }catch{return}
    $script:preparedBoundaryRequest=''
    $script:boundaryRestoreRetryAt=[DateTime]::MinValue
    $script:lastKnownFastSlot=$currentSlot
    $script:profileGenerationReadySlot=$currentSlot
    $script:saveTransitionPending=$false
    Reset-ProfileStability $currentSlot
    Reset-StaticSliderProfileStability $currentSlot
    $script:postLoadCountRefreshRemaining=5
    $script:postLoadCountRefreshNextUtc=[DateTime]::UtcNow.AddMilliseconds(100)
    Arm-Runtime161Burst ('runtime-reset|'+$reason) $false
    Log ('Boundary restore committed. slotKey='+(Get-SaveProfileKey $currentSlot)+'; generation='+$generationReset+'; runtime161-preserved=true')
}

    function Build-TransientOffsetCache([hashtable]$vector) {
        $lookup = @{}
        foreach ($id in @($script:completionResetIds.Keys)) {
            if (-not $nodeCoords.ContainsKey($id)) { continue }
            $c = $nodeCoords[$id]
            $key = ([Int64][Math]::Round([double]$c[0])).ToString() + '|' +
                   ([Int64][Math]::Round([double]$c[1])).ToString() + '|' +
                   ([Int64][Math]::Round([double]$c[2])).ToString()
            if (-not $lookup.ContainsKey($key)) {
                $lookup[$key] = New-Object System.Collections.Generic.List[string]
            }
            [void]$lookup[$key].Add([string]$id)
        }

        $cache = @{}
        for ($i = 0; $i -lt $vector.Count; $i++) {
            $offset = $i * 0x70
            $x = [BitConverter]::ToDouble($vector.Bytes, $offset + 0x40)
            $y = [BitConverter]::ToDouble($vector.Bytes, $offset + 0x48)
            $z = [BitConverter]::ToDouble($vector.Bytes, $offset + 0x50)
            $key = ([Int64][Math]::Round($x)).ToString() + '|' +
                   ([Int64][Math]::Round($y)).ToString() + '|' +
                   ([Int64][Math]::Round($z)).ToString()
            if (-not $lookup.ContainsKey($key)) { continue }
            $nodeAddress = [Int64]($vector.Start + $offset)
            $header = New-Object byte[] 0x20
            [Array]::Copy($vector.Bytes, $offset, $header, 0, 0x20)
            $memoryId = Read-NodeId $nodeAddress $header
            if ([String]::IsNullOrWhiteSpace($memoryId)) { continue }
            foreach ($candidate in @($lookup[$key])) {
                if ($memoryId -ceq [string]$candidate) {
                    $cache[[string]$candidate] = $offset
                    break
                }
            }
        }
        $script:transientOffsetCache = $cache
        $script:transientOffsetCacheVectorStart = [Int64]$vector.Start
        $script:transientOffsetCacheVectorCount = [int]$vector.Count
        Log ('Runtime 161 completion offset cache built: ' + $cache.Count + '/' + $script:completionResetIds.Count)
    }


    function Build-StaticSliderOffsetCache([hashtable]$vector) {
        $lookup = @{}
        foreach ($id in @($script:sliderStaticCoords.Keys)) {
            $c = $script:sliderStaticCoords[$id]
            $key = ([Int64][Math]::Round([double]$c[0])).ToString() + '|' +
                   ([Int64][Math]::Round([double]$c[1])).ToString() + '|' +
                   ([Int64][Math]::Round([double]$c[2])).ToString()
            if (-not $lookup.ContainsKey($key)) { $lookup[$key] = New-Object System.Collections.Generic.List[string] }
            [void]$lookup[$key].Add([string]$id)
        }
        $cache = @{}
        for ($i = 0; $i -lt $vector.Count; $i++) {
            $offset = $i * 0x70
            if (($offset + 0x58) -ge $vector.Bytes.Length) { break }
            $x = [BitConverter]::ToDouble($vector.Bytes, $offset + 0x40)
            $y = [BitConverter]::ToDouble($vector.Bytes, $offset + 0x48)
            $z = [BitConverter]::ToDouble($vector.Bytes, $offset + 0x50)
            $key = ([Int64][Math]::Round($x)).ToString() + '|' +
                   ([Int64][Math]::Round($y)).ToString() + '|' +
                   ([Int64][Math]::Round($z)).ToString()
            if (-not $lookup.ContainsKey($key)) { continue }
            $nodeAddress = [Int64]($vector.Start + $offset)
            $header = New-Object byte[] 0x20
            [Array]::Copy($vector.Bytes, $offset, $header, 0, 0x20)
            $memoryId = Read-NodeId $nodeAddress $header
            if ([String]::IsNullOrWhiteSpace($memoryId)) { continue }
            foreach ($candidate in @($lookup[$key])) {
                if ($memoryId -ceq [string]$candidate) {
                    # Slider IDs are numerically identical to one pressure-puzzle family.
                    # Coordinate matching is therefore mandatory and is the disambiguator.
                    $cache[[string]$candidate] = $offset
                    break
                }
            }
        }
        $script:sliderStaticOffsetCache = $cache
        $script:sliderStaticOffsetCacheVectorStart = [Int64]$vector.Start
        $script:sliderStaticOffsetCacheVectorCount = [int]$vector.Count
        Log ('True SliderPuzzle offset cache built: ' + $cache.Count + '/' + $script:sliderStaticCoords.Count)
    }

    function Get-RuntimeStaticSliderCount([hashtable]$moduleInfo,[hashtable]$vector) {
        if ($null -eq $moduleInfo) { $moduleInfo = Get-MnMModuleInfo }
        if ($null -eq $moduleInfo) { return $null }
        if ($null -eq $vector) { $vector = Get-NodeVector $moduleInfo }
        if ($null -eq $vector) { return $null }
        if ($script:sliderStaticOffsetCache.Count -ne $script:sliderStaticCoords.Count -or
            $script:sliderStaticOffsetCacheVectorStart -ne [Int64]$vector.Start -or
            $script:sliderStaticOffsetCacheVectorCount -ne [int]$vector.Count) {
            Build-StaticSliderOffsetCache $vector
        }
        if ($script:sliderStaticOffsetCache.Count -ne $script:sliderStaticCoords.Count) {
            Log ('True SliderPuzzle count deferred: offset coverage=' + $script:sliderStaticOffsetCache.Count + '/' + $script:sliderStaticCoords.Count)
            return $null
        }
        $opened = 0
        $completed = New-Object System.Collections.Generic.List[string]
        foreach ($id in @($script:sliderStaticCoords.Keys)) {
            $offset = [Int64]$script:sliderStaticOffsetCache[$id]
            if ($offset -ge 0 -and ($offset + 0x58) -lt $vector.Bytes.Length -and [int]$vector.Bytes[$offset + 0x58] -eq 1) {
                $opened++
                [void]$completed.Add([string]$id)
            }
        }
        return @{ Opened=$opened; Total=$script:sliderStaticCoords.Count; CompletedIds=@($completed); Vector=$vector; Module=$moduleInfo }
    }

    function Reconcile-SliderPuzzleStateFromChestAuthority([hashtable]$moduleInfo,[hashtable]$vector,[string]$reason) {
        # v1.18.41: the 29 SliderPuzzle trigger IDs are local/permuted, but each one has
        # exactly one 150xx reward chest. Current-save chest state is the persistent authority.
        # With a full snapshot reconcile both 1 and 0; with actor-only evidence apply positive only.
        if($script:sliderStaticCoords.Count -eq 0 -or $game.HasExited){return $null}
        if($null -eq $moduleInfo){$moduleInfo=Get-MnMModuleInfo}; if($null -eq $moduleInfo){return $null}
        if($null -eq $vector){$vector=Get-NodeVector $moduleInfo}; if($null -eq $vector){return $null}
        if($script:sliderStaticOffsetCache.Count -ne $script:sliderStaticCoords.Count -or
           $script:sliderStaticOffsetCacheVectorStart -ne [Int64]$vector.Start -or
           $script:sliderStaticOffsetCacheVectorCount -ne [int]$vector.Count){Build-StaticSliderOffsetCache $vector}
        if($script:sliderStaticOffsetCache.Count -ne $script:sliderStaticCoords.Count){return $null}
        if($script:sliderRewardChestById.Count -ne $script:sliderStaticCoords.Count){return $null}

        $effectiveInfo=Get-EffectiveOpenedChestSet
        $effective=$effectiveInfo.Set
        $opened=0;$set1=0;$set0=0;$same=0;$fail=0
        $completed=New-Object System.Collections.Generic.List[string]
        foreach($id in @($script:sliderStaticCoords.Keys)){
            if(-not $script:sliderRewardChestById.ContainsKey([string]$id)){continue}
            $chestId=[string]$script:sliderRewardChestById[[string]$id]
            $hasPositive=$effective.ContainsKey($chestId)
            $offset=[Int64]$script:sliderStaticOffsetCache[$id]
            if($offset -lt 0 -or ($offset+0x58) -ge $vector.Bytes.Length){continue}
            $have=[int]$vector.Bytes[$offset+0x58]
            if($effectiveInfo.HasSnapshot){$want=if($hasPositive){1}else{0}}
            elseif($hasPositive){$want=1}
            else{$want=$have}
            if($want -eq 1){$opened++;[void]$completed.Add([string]$id)}
            if($have -eq $want){$same++;continue}
            if(Write-RemoteByte ([Int64]($vector.Start+$offset+0x58)) ([byte]$want)){
                if($want -eq 1){$set1++}else{$set0++}
            }else{$fail++}
        }
        if($set1 -gt 0 -or $set0 -gt 0 -or $fail -gt 0){
            Log ('SliderPuzzle state reconciled from mapped reward-chest authority: opened=' + $opened + '/' + $script:sliderStaticCoords.Count +
                 '; set1=' + $set1 + '; set0=' + $set0 + '; same=' + $same + '; fail=' + $fail + '; fullSnapshot=' + $effectiveInfo.HasSnapshot + '; reason=' + $reason)
        }
        return @{Opened=$opened;Total=$script:sliderStaticCoords.Count;CompletedIds=@($completed);Set1=$set1;Set0=$set0;Fail=$fail;Vector=$vector;Module=$moduleInfo}
    }

    function Mark-SliderPuzzleDoneByChestIds([string[]]$chestIds,[string]$reason) {
        if($null -eq $chestIds -or $chestIds.Count -eq 0 -or $script:sliderStaticCoords.Count -eq 0 -or $game.HasExited){return 0}
        $targets=New-Object System.Collections.Generic.List[string]
        foreach($raw in $chestIds){
            $cid=([string]$raw).Trim()
            if($script:sliderIdByRewardChest.ContainsKey($cid)){
                $sid=[string]$script:sliderIdByRewardChest[$cid]
                if(-not $targets.Contains($sid)){[void]$targets.Add($sid)}
            }
        }
        if($targets.Count -eq 0){return 0}
        $moduleInfo=Get-MnMModuleInfo; if($null -eq $moduleInfo){return 0}
        $vector=Get-NodeVector $moduleInfo; if($null -eq $vector){return 0}
        if($script:sliderStaticOffsetCache.Count -ne $script:sliderStaticCoords.Count -or
           $script:sliderStaticOffsetCacheVectorStart -ne [Int64]$vector.Start -or
           $script:sliderStaticOffsetCacheVectorCount -ne [int]$vector.Count){Build-StaticSliderOffsetCache $vector}
        if($script:sliderStaticOffsetCache.Count -ne $script:sliderStaticCoords.Count){return 0}
        $changed=0;$same=0;$fail=0
        foreach($sid in @($targets)){
            $offset=[Int64]$script:sliderStaticOffsetCache[$sid]
            if($offset -lt 0 -or ($offset+0x58) -ge $vector.Bytes.Length){continue}
            if([int]$vector.Bytes[$offset+0x58] -eq 1){$same++;continue}
            if(Write-RemoteByte ([Int64]($vector.Start+$offset+0x58)) ([byte]1)){$changed++}else{$fail++}
        }
        Log ('SliderPuzzle reward-chest completion applied: matched=' + $targets.Count + '; changed=' + $changed + '; same=' + $same + '; fail=' + $fail + '; reason=' + $reason)
        return $targets.Count
    }

    function Build-StaticStatueOffsetCache([hashtable]$vector) {
        $cache = @{}
        if ($script:statueStaticCoords.Count -eq 0) {
            $script:statueStaticOffsetCache = $cache
            return
        }
        $lookup = @{}
        foreach ($id in @($script:statueStaticCoords.Keys)) {
            $c = $script:statueStaticCoords[$id]
            $key = ([Int64][Math]::Round([double]$c[0])).ToString() + '|' +
                   ([Int64][Math]::Round([double]$c[1])).ToString() + '|' +
                   ([Int64][Math]::Round([double]$c[2])).ToString()
            if (-not $lookup.ContainsKey($key)) { $lookup[$key] = New-Object System.Collections.Generic.List[string] }
            [void]$lookup[$key].Add([string]$id)
        }
        for ($i = 0; $i -lt $vector.Count; $i++) {
            $offset = $i * 0x70
            if (($offset + 0x58) -ge $vector.Bytes.Length) { break }
            $x = [BitConverter]::ToDouble($vector.Bytes, $offset + 0x40)
            $y = [BitConverter]::ToDouble($vector.Bytes, $offset + 0x48)
            $z = [BitConverter]::ToDouble($vector.Bytes, $offset + 0x50)
            $key = ([Int64][Math]::Round($x)).ToString() + '|' +
                   ([Int64][Math]::Round($y)).ToString() + '|' +
                   ([Int64][Math]::Round($z)).ToString()
            if (-not $lookup.ContainsKey($key)) { continue }
            $nodeAddress = [Int64]($vector.Start + $offset)
            $header = New-Object byte[] 0x20
            [Array]::Copy($vector.Bytes, $offset, $header, 0, 0x20)
            $memoryId = Read-NodeId $nodeAddress $header
            if ([String]::IsNullOrWhiteSpace($memoryId)) { continue }
            foreach ($candidate in @($lookup[$key])) {
                if ($memoryId -ceq [string]$candidate) {
                    $cache[[string]$candidate] = $offset
                    break
                }
            }
        }
        $script:statueStaticOffsetCache = $cache
        $script:statueStaticOffsetCacheVectorStart = [Int64]$vector.Start
        $script:statueStaticOffsetCacheVectorCount = [int]$vector.Count
        Log ('StatuePuzzle offset cache built: ' + $cache.Count + '/' + $script:statueStaticCoords.Count)
    }

    function Get-RuntimeStaticStatueCount([hashtable]$moduleInfo,[hashtable]$vector) {
        if ($null -eq $moduleInfo) { $moduleInfo = Get-MnMModuleInfo }
        if ($null -eq $moduleInfo) { return $null }
        if ($null -eq $vector) { $vector = Get-NodeVector $moduleInfo }
        if ($null -eq $vector) { return $null }
        if ($script:statueStaticOffsetCache.Count -ne $script:statueStaticCoords.Count -or
            $script:statueStaticOffsetCacheVectorStart -ne [Int64]$vector.Start -or
            $script:statueStaticOffsetCacheVectorCount -ne [int]$vector.Count) {
            Build-StaticStatueOffsetCache $vector
        }
        if ($script:statueStaticOffsetCache.Count -ne $script:statueStaticCoords.Count) {
            Log ('StatuePuzzle count deferred: offset coverage=' + $script:statueStaticOffsetCache.Count + '/' + $script:statueStaticCoords.Count)
            return $null
        }
        $opened=0
        foreach($id in @($script:statueStaticCoords.Keys)){
            $offset=[Int64]$script:statueStaticOffsetCache[$id]
            if($offset -ge 0 -and ($offset+0x58) -lt $vector.Bytes.Length -and [int]$vector.Bytes[$offset+0x58] -eq 1){$opened++}
        }
        return @{Opened=$opened;Total=$script:statueStaticCoords.Count;Vector=$vector;Module=$moduleInfo}
    }

    function Get-StaticSliderProfileSet([string]$slot) {
        if ([String]::IsNullOrWhiteSpace($slot)) { return $null }
        $dir = Get-SaveProfileDir $slot $false
        if ($dir.Length -eq 0 -or -not (Test-Path -LiteralPath $dir)) { return $null }
        $valid = Join-Path $dir 'slider29.v1.valid'
        $path = Join-Path $dir 'slider29.txt'
        if (-not (Test-Path -LiteralPath $valid) -or -not (Test-Path -LiteralPath $path)) { return $null }
        return (Read-IdSetFile $path)
    }

    function Set-RuntimeStaticSliderStateFromIdSet([hashtable]$desired,[string]$reason) {
        if ($null -eq $desired -or $game.HasExited) { return $false }
        $moduleInfo=Get-MnMModuleInfo; if($null -eq $moduleInfo){return $false}
        $vector=Get-NodeVector $moduleInfo; if($null -eq $vector){return $false}
        if ($script:sliderStaticOffsetCache.Count -ne $script:sliderStaticCoords.Count -or
            $script:sliderStaticOffsetCacheVectorStart -ne [Int64]$vector.Start -or
            $script:sliderStaticOffsetCacheVectorCount -ne [int]$vector.Count) { Build-StaticSliderOffsetCache $vector }
        if ($script:sliderStaticOffsetCache.Count -ne $script:sliderStaticCoords.Count) { return $false }
        $set1=0;$set0=0;$same=0;$fail=0
        foreach($id in @($script:sliderStaticCoords.Keys)){
            $offset=[Int64]$script:sliderStaticOffsetCache[$id]
            $want=if($desired.ContainsKey([string]$id)){1}else{0}
            $have=[int]$vector.Bytes[$offset+0x58]
            if($have -eq $want){$same++;continue}
            if(Write-RemoteByte ([Int64]($vector.Start+$offset+0x58)) ([byte]$want)){
                if($want -eq 1){$set1++}else{$set0++}
            }else{$fail++}
        }
        Log ('True SliderPuzzle profile state applied: desired=' + $desired.Count + '; set1=' + $set1 + '; set0=' + $set0 + '; same=' + $same + '; fail=' + $fail + '; reason=' + $reason)
        return ($fail -eq 0)
    }

    function Apply-StaticSliderProfileIfValid([string]$slot,[string]$reason) {
        $set = Get-StaticSliderProfileSet $slot
        if ($null -eq $set) {
            Log ('True SliderPuzzle profile miss/unvalidated: key=' + (Get-SaveProfileKey $slot) + '; reason=' + $reason)
            return $false
        }
        if (Set-RuntimeStaticSliderStateFromIdSet $set ('slider29-profile|' + $reason)) {
            Log ('True SliderPuzzle profile applied: key=' + (Get-SaveProfileKey $slot) + '; done=' + $set.Count + '; reason=' + $reason)
            return $true
        }
        return $false
    }

    function Reset-StaticSliderProfileStability([string]$slot) {
        $script:sliderProfileStableSlot=$slot
        $script:sliderProfileStableSignature=''
        $script:sliderProfileStableSinceUtc=[DateTime]::MinValue
        $script:sliderProfileStableSamples=0
    }

    function Observe-StaticSliderProfile([string[]]$ids,[string]$reason) {
        if($script:saveTransitionPending){return}
        $slot = Get-AuthoritativeProfileSlot
        if ([String]::IsNullOrWhiteSpace($slot)) { return }
        if ($slot -ne $script:profileGenerationReadySlot) { return }

        # v1.18.38: only a save-boundary capture may create a slider profile.
        # Ordinary observation may advance an existing profile by one marker, but it may
        # never create a profile from a large destination-world jump while fast_live_slot
        # still names the source save.
        $existing = Get-StaticSliderProfileSet $slot
        if ($null -eq $existing) { return }

        if ($script:sliderProfileStableSlot -ne $slot) { Reset-StaticSliderProfileStability $slot }
        $set=@{}
        foreach($id in @($ids)){ if(-not [String]::IsNullOrWhiteSpace($id)){$set[[string]$id]=$true} }

        foreach($k in @($existing.Keys)){
            if(-not $set.ContainsKey([string]$k)){
                Log ('Slider profile update quarantined: runtime shrank before slot authority changed; key=' +
                     (Get-SaveProfileKey $slot) + '; reason=' + $reason)
                return
            }
        }
        $added = $set.Count - $existing.Count
        if ($added -gt 1) {
            Log ('Slider profile update quarantined: large jump +' + $added +
                 ' suggests save transition; key=' + (Get-SaveProfileKey $slot) + '; reason=' + $reason)
            return
        }
        if ($added -le 0) { return }

        $sig=(@($set.Keys | Sort-Object) -join ',')
        $now=[DateTime]::UtcNow
        if($sig -cne $script:sliderProfileStableSignature){
            $script:sliderProfileStableSignature=$sig
            $script:sliderProfileStableSinceUtc=$now
            $script:sliderProfileStableSamples=1
            return
        }
        $script:sliderProfileStableSamples++
        $elapsed=($now-$script:sliderProfileStableSinceUtc).TotalSeconds
        if($script:sliderProfileStableSamples -lt 2 -or $elapsed -lt 0.45){return}
        try{
            $dir=Get-SaveProfileDir $slot $true
            if($dir.Length -eq 0){return}
            if(Write-IdSetFileAtomic (Join-Path $dir 'slider29.txt') $set){
                [IO.File]::WriteAllText((Join-Path $dir 'slider29.v1.valid'),((Get-Date).ToString('O')+"`r`n"),(New-Object Text.UTF8Encoding($false)))
                [IO.File]::WriteAllText((Join-Path $dir 'slot_path.txt'),($slot+"`r`n"),(New-Object Text.UTF8Encoding($false)))
                Log ('True SliderPuzzle profile advanced safely: key=' + (Get-SaveProfileKey $slot) +
                     '; done=' + $set.Count + '; added=' + $added + '; reason=' + $reason)
            }
        }catch{Log ('True SliderPuzzle profile commit failed: ' + $_.Exception.Message)}
    }

    function Get-EffectiveOpenedChestSet {
    $set=@{}
    $hasSnapshot=($null -ne $script:authoritySnapshot)
    if($hasSnapshot){foreach($id in @($script:authoritySnapshot.Chests.Keys)){
        if($script:chestKindById.ContainsKey([string]$id)){$set[[string]$id]=$true}
    }}
    foreach($id in @($script:actorCompletedIds.Keys)){
        if($script:chestKindById.ContainsKey([string]$id)){$set[[string]$id]=$true}
    }
    return @{Set=$set;HasSnapshot=$hasSnapshot}
}

    function Reconcile-StatuePuzzleStateFromChestAuthority([hashtable]$moduleInfo,[hashtable]$vector,[string]$reason) {
        # v1.18.40: StatuePuzzle 16001 has an exact reward chest DSC_16001 in the
        # corrected exploration catalog. Full current-save chest snapshots are used
        # bidirectionally; an Actor witness is positive-only when the baseline is absent.
        if($script:statueStaticCoords.Count -eq 0 -or $game.HasExited){return $null}
        if($null -eq $moduleInfo){$moduleInfo=Get-MnMModuleInfo}; if($null -eq $moduleInfo){return $null}
        if($null -eq $vector){$vector=Get-NodeVector $moduleInfo}; if($null -eq $vector){return $null}
        if($script:statueStaticOffsetCache.Count -ne $script:statueStaticCoords.Count -or
           $script:statueStaticOffsetCacheVectorStart -ne [Int64]$vector.Start -or
           $script:statueStaticOffsetCacheVectorCount -ne [int]$vector.Count){Build-StaticStatueOffsetCache $vector}
        if($script:statueStaticOffsetCache.Count -ne $script:statueStaticCoords.Count){return $null}

        $effectiveInfo=Get-EffectiveOpenedChestSet
        $effective=$effectiveInfo.Set
        $hasPositive=$effective.ContainsKey([string]$script:statuePuzzleChestId)
        $opened=0;$set1=0;$set0=0;$same=0;$fail=0
        foreach($id in @($script:statueStaticCoords.Keys)){
            $offset=[Int64]$script:statueStaticOffsetCache[$id]
            if($offset -lt 0 -or ($offset+0x58) -ge $vector.Bytes.Length){continue}
            $have=[int]$vector.Bytes[$offset+0x58]
            if($effectiveInfo.HasSnapshot){$want=if($hasPositive){1}else{0}}
            elseif($hasPositive){$want=1}
            else{$want=$have} # no baseline: never clear a possibly valid destination state
            if($want -eq 1){$opened++}
            if($have -eq $want){$same++;continue}
            if(Write-RemoteByte ([Int64]($vector.Start+$offset+0x58)) ([byte]$want)){
                if($want -eq 1){$set1++}else{$set0++}
            }else{$fail++}
        }
        if($set1 -gt 0 -or $set0 -gt 0 -or $fail -gt 0){
            Log ('StatuePuzzle state reconciled from reward-chest authority: opened=' + $opened + '/' + $script:statueStaticCoords.Count +
                 '; set1=' + $set1 + '; set0=' + $set0 + '; same=' + $same + '; fail=' + $fail + '; fullSnapshot=' + $effectiveInfo.HasSnapshot + '; reason=' + $reason)
        }
        return @{Opened=$opened;Total=$script:statueStaticCoords.Count;Set1=$set1;Set0=$set0;Fail=$fail}
    }

    function Mark-StatuePuzzleDoneByChestIds([string[]]$chestIds,[string]$reason) {
        if($null -eq $chestIds -or $chestIds.Count -eq 0 -or $script:statueStaticCoords.Count -eq 0 -or $game.HasExited){return 0}
        $hit=$false
        foreach($raw in $chestIds){if(([string]$raw).Trim() -ceq [string]$script:statuePuzzleChestId){$hit=$true;break}}
        if(-not $hit){return 0}
        $moduleInfo=Get-MnMModuleInfo; if($null -eq $moduleInfo){return 0}
        $vector=Get-NodeVector $moduleInfo; if($null -eq $vector){return 0}
        if($script:statueStaticOffsetCache.Count -ne $script:statueStaticCoords.Count -or
           $script:statueStaticOffsetCacheVectorStart -ne [Int64]$vector.Start -or
           $script:statueStaticOffsetCacheVectorCount -ne [int]$vector.Count){Build-StaticStatueOffsetCache $vector}
        if($script:statueStaticOffsetCache.Count -ne $script:statueStaticCoords.Count){return 0}
        $changed=0
        foreach($id in @($script:statueStaticCoords.Keys)){
            $offset=[Int64]$script:statueStaticOffsetCache[$id]
            if($offset -lt 0 -or ($offset+0x58) -ge $vector.Bytes.Length){continue}
            if([int]$vector.Bytes[$offset+0x58] -eq 1){continue}
            if(Write-RemoteByte ([Int64]($vector.Start+$offset+0x58)) ([byte]1)){$changed++}
        }
        Log ('StatuePuzzle actor/save completion applied from ' + $script:statuePuzzleChestId + '; changed=' + $changed + '; reason=' + $reason)
        return 1
    }

    function Reconcile-PressurePuzzleStateFromChestAuthority([hashtable]$moduleInfo,[hashtable]$vector,[string]$reason) {
        # The 48 true 140xx pressure/platform markers each have a matching instant-open
        # reward chest DSC_<same numeric id> in the updated exploration catalog.
        # The 29 150xx reward rows belong to SliderPuzzle and are intentionally excluded
        # from pressurePuzzleIds in v1.18.41. Reconcile pressure in both 1 and 0 directions.
        if($script:pressurePuzzleIds.Count -eq 0 -or $game.HasExited){return $null}
        $effectiveInfo=Get-EffectiveOpenedChestSet
        # Two-way reconciliation requires a full current-save baseline. Actor evidence
        # alone is positive-only and must never be used to clear other pressure markers.
        if(-not $effectiveInfo.HasSnapshot){return $null}
        $effective=$effectiveInfo.Set
        if($null -eq $moduleInfo){$moduleInfo=Get-MnMModuleInfo}; if($null -eq $moduleInfo){return $null}
        if($null -eq $vector){$vector=Get-NodeVector $moduleInfo}; if($null -eq $vector){return $null}
        if($script:transientOffsetCache.Count -ne $script:completionResetIds.Count -or
           $script:transientOffsetCacheVectorStart -ne [Int64]$vector.Start -or
           $script:transientOffsetCacheVectorCount -ne [int]$vector.Count){Build-TransientOffsetCache $vector}

        $opened=0;$set1=0;$set0=0;$same=0;$missing=0;$fail=0
        $completed=New-Object System.Collections.Generic.List[string]
        foreach($id in @($script:pressurePuzzleIds.Keys)){
            $chestId='DSC_'+[string]$id
            $want=if($effective.ContainsKey($chestId)){1}else{0}
            if($want -eq 1){$opened++;[void]$completed.Add([string]$id)}
            if(-not $script:transientOffsetCache.ContainsKey([string]$id)){$missing++;continue}
            $offset=[Int64]$script:transientOffsetCache[[string]$id]
            if($offset -lt 0 -or ($offset+0x58) -ge $vector.Bytes.Length){$missing++;continue}
            $have=[int]$vector.Bytes[$offset+0x58]
            if($have -eq $want){$same++;continue}
            if(Write-RemoteByte ([Int64]($vector.Start+$offset+0x58)) ([byte]$want)){
                if($want -eq 1){$set1++}else{$set0++}
            }else{$fail++}
        }
        if($set1 -gt 0 -or $set0 -gt 0 -or $fail -gt 0){
            Log ('Pressure-puzzle state reconciled from reward-chest authority: opened=' + $opened + '/' + $script:pressurePuzzleIds.Count +
                 '; set1=' + $set1 + '; set0=' + $set0 + '; same=' + $same + '; missing=' + $missing + '; fail=' + $fail + '; reason=' + $reason)
        }
        return @{Opened=$opened;Total=$script:pressurePuzzleIds.Count;CompletedIds=@($completed);Set1=$set1;Set0=$set0;Missing=$missing;Fail=$fail}
    }

    function Mark-PressurePuzzleDoneByChestIds([string[]]$chestIds,[string]$reason) {
        # Fast single-event path. Full save-authoritative two-way reconciliation is
        # performed by Reconcile-PressurePuzzleStateFromChestAuthority on the next
        # count/burst pass.
        if ($null -eq $chestIds -or $chestIds.Count -eq 0 -or $script:pressurePuzzleIds.Count -eq 0 -or $game.HasExited) { return 0 }
        $targets = New-Object System.Collections.Generic.List[string]
        foreach($raw in $chestIds){
            if([String]::IsNullOrWhiteSpace($raw)){continue}
            $s=([string]$raw).Trim()
            if($s -match '^DSC_(\d+)$'){
                $id=$Matches[1]
                if($script:pressurePuzzleIds.ContainsKey($id) -and -not $targets.Contains($id)){[void]$targets.Add($id)}
            }
        }
        if($targets.Count -eq 0){return 0}
        $moduleInfo=Get-MnMModuleInfo; if($null -eq $moduleInfo){return 0}
        $vector=Get-NodeVector $moduleInfo; if($null -eq $vector){return 0}
        if($script:transientOffsetCache.Count -ne $script:completionResetIds.Count -or
           $script:transientOffsetCacheVectorStart -ne [Int64]$vector.Start -or
           $script:transientOffsetCacheVectorCount -ne [int]$vector.Count){Build-TransientOffsetCache $vector}
        $set=0;$same=0;$fail=0
        foreach($id in @($targets)){
            if(-not $script:transientOffsetCache.ContainsKey($id)){continue}
            $offset=[Int64]$script:transientOffsetCache[$id]
            $have=[int]$vector.Bytes[$offset+0x58]
            if($have -eq 1){$same++;continue}
            if(Write-RemoteByte ([Int64]($vector.Start+$offset+0x58)) ([byte]1)){$set++}else{$fail++}
        }
        if($set -gt 0 -or $fail -gt 0){
            Log ('Pressure-puzzle completion mirrored from reward chest: set=' + $set + '; same=' + $same + '; fail=' + $fail + '; ids=' + ($targets -join ',') + '; reason=' + $reason)
        }
        return $set
    }

    function Get-RuntimeTransientCompletionCounts {
        if ($game.HasExited) { return $null }
        $moduleInfo = Get-MnMModuleInfo
        if ($null -eq $moduleInfo) { return $null }
        $vector = Get-NodeVector $moduleInfo
        if ($null -eq $vector) { return $null }
        if ($script:transientOffsetCache.Count -ne $script:completionResetIds.Count -or
            $script:transientOffsetCacheVectorStart -ne [Int64]$vector.Start -or
            $script:transientOffsetCacheVectorCount -ne [int]$vector.Count) {
            Build-TransientOffsetCache $vector
        }
        if ($script:transientOffsetCache.Count -ne $script:completionResetIds.Count) {
            Log ('Runtime 161 count deferred: offset coverage=' + $script:transientOffsetCache.Count + '/' + $script:completionResetIds.Count)
            return $null
        }

        $r = @{
            fly = @{ Opened = 0; Total = 0 }
            mole = @{ Opened = 0; Total = 0 }
            wave = @{ Opened = 0; Total = 0 }
            puzzle_platform = @{ Opened = 0; Total = 0 }
            puzzle_slider = @{ Opened = 0; Total = 0 }
        }
        $completedIds = New-Object System.Collections.Generic.List[string]
        foreach ($id in @($script:completionResetIds.Keys)) {
            if (-not $script:completionKindById.ContainsKey($id)) { continue }
            $kind = [string]$script:completionKindById[$id]
            if (-not $r.ContainsKey($kind)) { continue }
            $bucket = $r[$kind]
            $bucket['Total'] = [int]$bucket['Total'] + 1
            $offset = [Int64]$script:transientOffsetCache[$id]
            if ($offset -ge 0 -and ($offset + 0x58) -lt $vector.Bytes.Length -and
                [int]$vector.Bytes[$offset + 0x58] -eq 1) {
                $bucket['Opened'] = [int]$bucket['Opened'] + 1
                [void]$completedIds.Add([string]$id)
            }
        }
        return @{ Module = $moduleInfo; Counts = $r; CompletedIds = @($completedIds) }
    }

    function Set-RuntimeTransientStateFromIdSet([hashtable]$desired,[string]$reason) {
        if ($game.HasExited) { return $false }
        $moduleInfo = Get-MnMModuleInfo; if ($null -eq $moduleInfo) { return $false }
        $vector = Get-NodeVector $moduleInfo; if ($null -eq $vector) { return $false }
        if ($script:transientOffsetCache.Count -ne $script:completionResetIds.Count -or $script:transientOffsetCacheVectorStart -ne [Int64]$vector.Start -or $script:transientOffsetCacheVectorCount -ne [int]$vector.Count) { Build-TransientOffsetCache $vector }
        if ($script:transientOffsetCache.Count -ne $script:completionResetIds.Count) { return $false }
        $set1=0; $set0=0; $same=0; $fail=0
        foreach ($id in @($script:completionResetIds.Keys)) {
            $offset=[Int64]$script:transientOffsetCache[$id]
            $want=if($desired.ContainsKey([string]$id)){1}else{0}; $have=[int]$vector.Bytes[$offset+0x58]
            if($have -eq $want){$same++;continue}
            if(Write-RemoteByte ([Int64]($vector.Start+$offset+0x58)) ([byte]$want)){if($want -eq 1){$set1++}else{$set0++}}else{$fail++}
        }
        Log ('Per-save 161 state applied: desired=' + $desired.Count + '; set1=' + $set1 + '; set0=' + $set0 + '; same=' + $same + '; fail=' + $fail + '; reason=' + $reason)
        return ($fail -eq 0)
    }

    function Patch-RuntimeCompletionCountKey([hashtable]$moduleInfo,[string]$key,[int]$opened,[int]$total) {
        $entry = Get-CachedMnMTranslationValue $moduleInfo $key
        if ($null -eq $entry) { return $false }
        $node = [Int64]$entry.Node
        $valueObj = $entry.Value
        $m = [regex]::Match($valueObj.Text, '(\d+)/(\d+)')
        if (-not $m.Success) { return $false }
        $ow = $m.Groups[1].Value.Length
        $tw = $m.Groups[2].Value.Length
        $o = $opened.ToString('D' + $ow)
        $t = $total.ToString('D' + $tw)
        if ($o.Length -ne $ow -or $t.Length -ne $tw) { return $false }
        $target = $valueObj.Text.Substring(0,$m.Groups[1].Index) + $o + '/' + $t +
                  $valueObj.Text.Substring($m.Groups[2].Index + $m.Groups[2].Length)
        if ($target -ceq $valueObj.Text) { return $true }
        return (Patch-MnMTranslationValue $moduleInfo $key $target)
    }


    function Read-NativeWorldCompleteChestCount {
        try {
            if (-not (Test-Path -LiteralPath $nativeChestJsonPath)) {
                if ($script:lastNativeChestAvailability -ne 'missing') {
                    $script:lastNativeChestAvailability = 'missing'
                    Log ('Native chest authority unavailable: sidecar missing at ' + $nativeChestJsonPath)
                }
                $cached = Read-ModLocalNativeChestCount
                if ($null -ne $cached) {
                    if ($script:lastNativeChestAvailability -ne 'profile-cache') {
                        $script:lastNativeChestAvailability = 'profile-cache'
                        Log ('Native chest authority warm-restored from persistent per-save cache: ' +
                             $cached.Opened + '/' + $cached.Total + '; catalogDelta=' + $cached.CatalogDelta)
                    }
                    return $cached
                }
                return $null
            }

            $fi = Get-Item -LiteralPath $nativeChestJsonPath -ErrorAction Stop
            $freshAfter = $script:gameStartUtc
            if ($script:nativeChestGenerationEpochUtc -gt $freshAfter) { $freshAfter = $script:nativeChestGenerationEpochUtc }
            if ($fi.LastWriteTimeUtc -lt $freshAfter) {
                if ($script:lastNativeChestAvailability -ne 'stale') {
                    $script:lastNativeChestAvailability = 'stale'
                    Log ('Native chest authority deferred: sidecar predates current game/save generation. sidecarUtc=' +
                         $fi.LastWriteTimeUtc.ToString('O') + '; freshAfter=' + $freshAfter.ToString('O'))
                }
                $cached = Read-ModLocalNativeChestCount
                if ($null -ne $cached) {
                    if ($script:lastNativeChestAvailability -ne 'profile-cache') {
                        $script:lastNativeChestAvailability = 'profile-cache'
                        Log ('Native chest authority warm-restored from persistent per-save cache: ' +
                             $cached.Opened + '/' + $cached.Total + '; catalogDelta=' + $cached.CatalogDelta)
                    }
                    return $cached
                }
                return $null
            }

            $raw = Get-Content -LiteralPath $nativeChestJsonPath -Raw -ErrorAction Stop
            if ([String]::IsNullOrWhiteSpace($raw)) { return $null }
            $j = $raw | ConvertFrom-Json -ErrorAction Stop

            $ver = [string]$j.version
            $openedMap = [string]$j.opened_map
            $totalMap = [string]$j.total_map
            $missionType = [int]$j.mission_type
            $opened = [int]$j.opened
            $total = [int]$j.total
            $event = [string]$j.event
            $handler = [string]$j.handler

            if ($ver -notlike 'DSWR-1.18.27-native-inprocess-*' -or $openedMap -ne 'A40' -or $totalMap -ne 'B90' -or $missionType -ne 1) {
                if ($script:lastNativeChestAvailability -ne 'schema') {
                    $script:lastNativeChestAvailability = 'schema'
                    Log ('Native chest authority rejected: unexpected bridge schema/version=' + $ver +
                         '; openedMap=' + $openedMap + '; totalMap=' + $totalMap + '; missionType=' + $missionType)
                }
                return $null
            }
            if ($total -le 0 -or $total -gt 10000 -or $opened -lt 0 -or $opened -gt $total) {
                if ($script:lastNativeChestAvailability -ne 'range') {
                    $script:lastNativeChestAvailability = 'range'
                    Log ('Native chest authority rejected: invalid count range opened=' + $opened + '; total=' + $total)
                }
                return $null
            }

            $script:lastNativeChestAvailability = 'ready'
            return @{
                Opened = $opened
                Total = $total
                Remaining = ($total - $opened)
                Event = $event
                Handler = $handler
                Version = $ver
                FileUtc = $fi.LastWriteTimeUtc
                Source = 'native-current'
                CatalogDelta = 0
            }
        } catch {
            if ($script:lastNativeChestAvailability -ne 'error') {
                $script:lastNativeChestAvailability = 'error'
                Log ('Native chest authority read failed: ' + $_.Exception.Message)
            }
            return $null
        }
    }

    function Sync-NativeWorldCompleteChestCountLabel([string]$reason) {
        try {
            $native = Read-NativeWorldCompleteChestCount
            $moduleInfo = Get-MnMModuleInfo
            if ($null -eq $moduleInfo) { return $false }

            if ($null -eq $native) {
                # v1.18.38: never preserve the previous save's opened number. That was the
                # exact cause of the observed 775 <-> 1502 cross-slot display swap: the fresh
                # native sidecar was absent, so the old label survived unchanged. Use the
                # current save-authoritative chest snapshot/profile as the opened fallback,
                # using the packaged catalog total until fresh native authority arrives.
                try {
                    $fallbackOpened = -1
                    $slot = Get-AuthoritativeProfileSlot
                    if (-not [String]::IsNullOrWhiteSpace($slot)) {
                        $dir = Get-SaveProfileDir $slot $false
                        if (-not [String]::IsNullOrWhiteSpace($dir) -and (Test-Path -LiteralPath (Join-Path $dir 'chest_area.v3.valid'))) {
                            $fallbackOpened = (Read-IdSetFile (Join-Path $dir 'chests.txt')).Count
                        }
                    }
                    if ($fallbackOpened -lt 0 -and (Test-Path -LiteralPath $script:fastChestSnapshotPath)) {
                        $fallbackOpened = (Read-FastChestSnapshotMap).Count
                    }
                    if ($fallbackOpened -ge 0 -and $fallbackOpened -le [int]$script:nativeWorldCompleteTreasureTotal) {
                        Patch-RuntimeCompletionCountKey $moduleInfo 'grp.chests' $fallbackOpened ([int]$script:nativeWorldCompleteTreasureTotal) | Out-Null
                        $sig = ('fallback-current-save:' + $fallbackOpened + '/' + [int]$script:nativeWorldCompleteTreasureTotal)
                        if ($sig -cne $script:lastNativeChestSignature) {
                            $script:lastNativeChestSignature = $sig
                            Log ('Native chest label fallback refreshed from current save authority: ' +
                                 $fallbackOpened + '/' + [int]$script:nativeWorldCompleteTreasureTotal +
                                 '; reason=' + $reason)
                        }
                    }
                } catch { }
                return $false
            }

            $ok = Patch-RuntimeCompletionCountKey $moduleInfo 'grp.chests' ([int]$native.Opened) ([int]$native.Total)
            if (-not $ok) { return $false }

            if ([string]$native.Source -eq 'native-current') {
                Write-ModLocalNativeChestCount $native $reason
            }

            $sig = ([string]$native.Opened + '/' + [string]$native.Total + '|' + [string]$native.Event + '|' + [string]$native.Handler + '|' + [string]$native.Source)
            if ($sig -cne $script:lastNativeChestSignature) {
                $script:lastNativeChestSignature = $sig
                try {
                    $dir = Split-Path -Parent $nativeChestMirrorPath
                    if (-not (Test-Path -LiteralPath $dir)) { [void](New-Item -ItemType Directory -Path $dir -Force) }
                    $mirror = @(
                        '# DSWorldRadar v1.18.27 game-native WorldComplete chest authority',
                        ('generated=' + (Get-Date).ToString('O')),
                        ('opened=' + $native.Opened),
                        ('total=' + $native.Total),
                        ('remaining=' + $native.Remaining),
                        ('event=' + $native.Event),
                        ('handler=' + $native.Handler),
                        'opened_map=A40',
                        'total_map=B90',
                        'mission_type=1',
                        ('reason=' + $reason)
                    )
                    [IO.File]::WriteAllLines($nativeChestMirrorPath,$mirror,(New-Object Text.UTF8Encoding($false)))
                } catch { }
                Log ('Native WorldComplete chest count synced to radar: ' + $native.Opened + '/' + $native.Total +
                     '; remaining=' + $native.Remaining + '; event=' + $native.Event +
                     '; source=' + [string]$native.Source + '; reason=' + $reason)
            }
            return $true
        } catch {
            Log ('Native WorldComplete chest count sync failed: ' + $_.Exception.Message)
            return $false
        }
    }

    function Read-NativeWorldCompleteMiniGameCount {
        try {
            if (-not (Test-Path -LiteralPath $nativeMiniGameJsonPath)) {
                if ($script:lastNativeMiniGameAvailability -ne 'missing') {
                    $script:lastNativeMiniGameAvailability = 'missing'
                    Log ('Native minigame authority unavailable: sidecar missing at ' + $nativeMiniGameJsonPath)
                }
                return $null
            }
            $fi = Get-Item -LiteralPath $nativeMiniGameJsonPath -ErrorAction Stop
            $freshAfter = $script:gameStartUtc
            if ($script:nativeChestGenerationEpochUtc -gt $freshAfter) { $freshAfter = $script:nativeChestGenerationEpochUtc }
            if ($fi.LastWriteTimeUtc -lt $freshAfter) {
                if ($script:lastNativeMiniGameAvailability -ne 'stale') {
                    $script:lastNativeMiniGameAvailability = 'stale'
                    Log ('Native minigame authority deferred: sidecar predates current game/save generation.')
                }
                return $null
            }
            $j = (Get-Content -LiteralPath $nativeMiniGameJsonPath -Raw -ErrorAction Stop) | ConvertFrom-Json -ErrorAction Stop
            $ver=[string]$j.version; $missionType=[int]$j.mission_type; $opened=[int]$j.opened; $total=[int]$j.total
            if ($ver -notlike 'DSWR-1.18.28-native-A40-*' -or $missionType -ne 2) {
                $script:lastNativeMiniGameAvailability='schema'; return $null
            }
            # The radar's game-native exploration minigame universe is Fly 34 + Mole 40 + Wave 10 = 84.
            # Reject any unexpected total rather than silently changing the UI's category universe.
            if ($total -ne [int]$script:nativeWorldCompleteMiniGameTotal -or $opened -lt 0 -or $opened -gt $total) {
                if ($script:lastNativeMiniGameAvailability -ne 'range') {
                    $script:lastNativeMiniGameAvailability='range'
                    Log ('Native minigame authority observed but not applied: opened=' + $opened + '; total=' + $total + '; expectedTotal=' + $script:nativeWorldCompleteMiniGameTotal)
                }
                return $null
            }
            $script:lastNativeMiniGameAvailability='ready'
            return @{ Opened=$opened; Total=$total; FogSectionId=[int]$j.fogsection_id; Seq=[int]$j.seq; Handler=[string]$j.handler }
        } catch {
            if ($script:lastNativeMiniGameAvailability -ne 'error') {
                $script:lastNativeMiniGameAvailability='error'; Log ('Native minigame authority read failed: ' + $_.Exception.Message)
            }
            return $null
        }
    }

    function Sync-RuntimeTransientCompletionCountLabels([string]$reason) {
        try {
            $state = Get-RuntimeTransientCompletionCounts
            if ($null -eq $state) { return $false }
            $moduleInfo = $state.Module
            $c = $state.Counts
            $fly = $c.fly; $mole = $c.mole; $wave = $c.wave
            # v1.18.41: only the 48 140xx rows are true pressure/platform puzzles.
            # The 29 150xx reward rows belong to the separate SliderPuzzle markers and were
            # previously double-counted. Both families now use exact reward-chest authority.
            $pressure = Reconcile-PressurePuzzleStateFromChestAuthority $moduleInfo $state.Vector ('count-sync|' + $reason)
            if ($null -eq $pressure) { $pressure = $c.puzzle_platform }
            $slider = Reconcile-SliderPuzzleStateFromChestAuthority $moduleInfo $null ('count-sync|' + $reason)
            if ($null -eq $slider) { $slider = Get-RuntimeStaticSliderCount $moduleInfo $null }
            if ($null -eq $slider) { $slider = @{ Opened=0; Total=$script:sliderStaticCoords.Count; CompletedIds=@() } }
            Observe-StaticSliderProfile @($slider.CompletedIds) ('count-sync|' + $reason)
            $statue = Reconcile-StatuePuzzleStateFromChestAuthority $moduleInfo $null ('count-sync|' + $reason)
            if ($null -eq $statue) {
                $statue = Get-RuntimeStaticStatueCount $moduleInfo $null
                if ($null -eq $statue) { $statue = @{ Opened=0; Total=$script:statueStaticCoords.Count } }
            }

            $mgOpened = [int]$fly.Opened + [int]$mole.Opened + [int]$wave.Opened
            $mgTotal = [int]$fly.Total + [int]$mole.Total + [int]$wave.Total
            $nativeMg = Read-NativeWorldCompleteMiniGameCount
            $mgGroupOpened = if ($null -ne $nativeMg) { [int]$nativeMg.Opened } else { $mgOpened }
            $mgGroupTotal  = if ($null -ne $nativeMg) { [int]$nativeMg.Total } else { $mgTotal }
            $pzOpened = [int]$pressure.Opened + [int]$slider.Opened + [int]$statue.Opened
            $pzTotal = [int]$pressure.Total + [int]$slider.Total + [int]$statue.Total

            $langPath = Get-SelectedLanguagePath
            $pairs = @(
                @('cat.fly',[int]$fly.Opened,[int]$fly.Total),
                @('cat.mole',[int]$mole.Opened,[int]$mole.Total),
                @('cat.wave',[int]$wave.Opened,[int]$wave.Total),
                @('grp.minigames',$mgGroupOpened,$mgGroupTotal),
                @('cat.puzzle_platform',[int]$pressure.Opened,[int]$pressure.Total),
                @('cat.platform',[int]$pressure.Opened,[int]$pressure.Total),
                @('cat.puzzle_slider',[int]$slider.Opened,[int]$slider.Total),
                @('cat.slider',[int]$slider.Opened,[int]$slider.Total),
                @('cat.puzzle_statue',[int]$statue.Opened,[int]$statue.Total),
                @('grp.puzzles',$pzOpened,$pzTotal)
            )
            $ok = 0; $wanted = 0
            foreach ($p in $pairs) {
                $key = [string]$p[0]
                if ($langPath -and $null -eq (Read-LanguageValue $langPath $key)) { continue }
                $wanted++
                if (Patch-RuntimeCompletionCountKey $moduleInfo $key ([int]$p[1]) ([int]$p[2])) { $ok++ }
            }

            $summarySig=($pairs | ForEach-Object {$_ -join '='}) -join ';'
            $summaryChanged=($summarySig -cne $script:lastRuntimeSummarySignature)
            if($summaryChanged){
                $script:lastRuntimeSummarySignature=$summarySig
            try {
                $summary = @(
                    '# DSWorldRadar 1.0.6 runtime completion summary',
                    ('# Generated=' + (Get-Date).ToString('O')),
                    ('fly=' + $fly.Opened + '/' + $fly.Total),
                    ('mole=' + $mole.Opened + '/' + $mole.Total),
                    ('wave=' + $wave.Opened + '/' + $wave.Total),
                    ('minigames=' + $mgGroupOpened + '/' + $mgGroupTotal),
                    ('pressure_puzzle=' + $pressure.Opened + '/' + $pressure.Total),
                    ('slider_puzzle=' + $slider.Opened + '/' + $slider.Total),
                    ('statue_puzzle=' + $statue.Opened + '/' + $statue.Total),
                    ('puzzles=' + $pzOpened + '/' + $pzTotal)
                )
                [IO.File]::WriteAllLines((Join-Path $syncRoot 'cache\runtime_completion_counts.txt'),$summary,(New-Object Text.UTF8Encoding($false)))
            } catch { }
            Log ('Runtime split count synced: fly=' + $fly.Opened + '/' + $fly.Total +
                 '; mole=' + $mole.Opened + '/' + $mole.Total +
                 '; wave=' + $wave.Opened + '/' + $wave.Total +
                 '; pressure=' + $pressure.Opened + '/' + $pressure.Total +
                 '; slider=' + $slider.Opened + '/' + $slider.Total +
                 '; statue=' + $statue.Opened + '/' + $statue.Total +
                 '; puzzles=' + $pzOpened + '/' + $pzTotal +
                 '; labels=' + $ok + '/' + $wanted + '; reason=' + $reason)
            }
            $script:lastObservedRuntime161Signature = Get-IdSetSignature @($state.CompletedIds)
            Observe-Runtime161ForProfile @($state.CompletedIds) $reason
            return $true
        } catch {
            Log ('Runtime split count sync failed: ' + $_.Exception.Message)
            return $false
        }
    }

    function Build-AreaOffsetCache([hashtable]$vector) {
        $lookup = @{}
        foreach ($id in @($script:areaQuestIds.Keys)) {
            if (-not $nodeCoords.ContainsKey($id)) { continue }
            $c = $nodeCoords[$id]
            $key = ([Int64][Math]::Round([double]$c[0])).ToString() + '|' +
                   ([Int64][Math]::Round([double]$c[1])).ToString() + '|' +
                   ([Int64][Math]::Round([double]$c[2])).ToString()
            # Distinct quests may share coordinates (1110052 / 1110061).
            # Coordinates select candidates; the runtime ID identifies the node.
            if (-not $lookup.ContainsKey($key)) { $lookup[$key] = New-Object System.Collections.Generic.List[string] }
            [void]$lookup[$key].Add([string]$id)
        }

        $cache = @{}
        for ($i = 0; $i -lt $vector.Count; $i++) {
            $offset = $i * 0x70
            $x = [BitConverter]::ToDouble($vector.Bytes, $offset + 0x40)
            $y = [BitConverter]::ToDouble($vector.Bytes, $offset + 0x48)
            $z = [BitConverter]::ToDouble($vector.Bytes, $offset + 0x50)
            $key = ([Int64][Math]::Round($x)).ToString() + '|' +
                   ([Int64][Math]::Round($y)).ToString() + '|' +
                   ([Int64][Math]::Round($z)).ToString()
            if (-not $lookup.ContainsKey($key)) { continue }
            $nodeAddress = [Int64]($vector.Start + $offset)
            $header = New-Object byte[] 0x20
            [Array]::Copy($vector.Bytes, $offset, $header, 0, 0x20)
            $memoryId = Read-NodeId $nodeAddress $header
            foreach ($candidate in @($lookup[$key])) {
                if ($memoryId -ceq [string]$candidate) { $cache[[string]$candidate] = $offset; break }
            }
        }
        $script:areaOffsetCache = $cache
        $script:areaOffsetCacheVectorStart = [Int64]$vector.Start
        $script:areaOffsetCacheVectorCount = [int]$vector.Count
        $missingIds = @($script:areaQuestIds.Keys | Where-Object { -not $cache.ContainsKey([string]$_) } | Sort-Object)
        $missingText = if ($missingIds.Count -eq 0) { 'none' } else { (@($missingIds | Select-Object -First 16) -join ',') }
        Log ('Area-quest runtime count cache built: ' + $cache.Count + '/' + $script:areaQuestIds.Count + '; missingIds=' + $missingText)
    }

    function Set-RuntimeAreaStateFromIdSet([hashtable]$desired,[string]$reason) {
        if ($game.HasExited) { return $false }
        $effectiveDesired=$desired.Clone()
        if($null -ne $script:exactAreaCompletedIds){
            foreach($id in @($script:exactAreaCompletedIds.Keys)){$effectiveDesired[[string]$id]=$true}
        }
        $moduleInfo=Get-MnMModuleInfo; if($null -eq $moduleInfo){return $false}
        $vector=Get-NodeVector $moduleInfo; if($null -eq $vector){return $false}
        if($script:areaOffsetCache.Count -ne $script:areaQuestIds.Count -or $script:areaOffsetCacheVectorStart -ne [Int64]$vector.Start -or $script:areaOffsetCacheVectorCount -ne [int]$vector.Count){Build-AreaOffsetCache $vector}
        if($script:areaOffsetCache.Count -lt 1){return $false}
        $set1=0;$set0=0;$same=0;$missing=0;$fail=0
        foreach($id in @($script:areaQuestIds.Keys)){
            if(-not $script:areaOffsetCache.ContainsKey($id)){$missing++;continue}
            $offset=[Int64]$script:areaOffsetCache[$id];$want=if($effectiveDesired.ContainsKey([string]$id)){1}else{0};$have=[int]$vector.Bytes[$offset+0x58]
            if($have -eq $want){$same++;continue}
            if(Write-RemoteByte ([Int64]($vector.Start+$offset+0x58)) ([byte]$want)){if($want -eq 1){$set1++}else{$set0++}}else{$fail++}
        }
        Log ('Area state reconciled: desired=' + $effectiveDesired.Count + '; set1=' + $set1 + '; set0=' + $set0 + '; same=' + $same + '; missing=' + $missing + '; fail=' + $fail + '; reason=' + $reason)
        return ($fail -eq 0 -and $missing -eq 0)
    }

    function Get-AuthoritativeAreaQuestCountFromProgress {
        # v1.18.16: area-quest count authority is progress.txt after MnMChestSaveSync
        # has reconciled it from all three quest-completion tables.  Do not derive the
        # numerator from MnMRadar's runtime done byte: that byte can legitimately lag
        # during first-load/travel and previously overwrote a correct save count back to
        # the partial dynamic-table value (e.g. 27/147).
        try {
            $progressPath = Join-Path $dllsRoot 'progress.txt'
            $done = 0
            if (Test-Path -LiteralPath $progressPath) {
                $seen = @{}
                foreach ($raw in (Get-Content -LiteralPath $progressPath -ErrorAction Stop)) {
                    if ([String]::IsNullOrWhiteSpace($raw)) { continue }
                    $id = $raw.Trim()
                    if ($script:areaQuestIds.ContainsKey($id) -and -not $seen.ContainsKey($id)) {
                        $seen[$id] = $true
                        $done++
                    }
                }
            }
            return @{ Opened = $done; Total = $script:areaQuestIds.Count }
        } catch {
            Log ('Area-quest authoritative progress count failed: ' + $_.Exception.Message)
            return $null
        }
    }

    function Sync-RuntimeAreaQuestCountLabel([string]$reason) {
        try {
            $count = Get-AuthoritativeAreaQuestCountFromProgress
            if ($null -eq $count -or $count.Total -le 0) { return }
            $moduleInfo = Get-MnMModuleInfo
            if ($null -eq $moduleInfo) { return }
            $entry = Get-CachedMnMTranslationValue $moduleInfo 'cat.area_quests'
            if ($null -eq $entry) { return }
            $valueObj = $entry.Value
            $m = [regex]::Match($valueObj.Text, '(\d+)/(\d+)')
            if (-not $m.Success) {
                Log ('Area-quest authoritative count label pattern not found: ' + $valueObj.Text)
                return
            }
            $width = $m.Groups[1].Value.Length
            $openedText = ([int]$count.Opened).ToString('D' + $width)
            if ($openedText.Length -ne $width) { return }
            $target = $valueObj.Text.Substring(0, $m.Groups[1].Index) + $openedText +
                      $valueObj.Text.Substring($m.Groups[1].Index + $m.Groups[1].Length)
            if ($target -ceq $valueObj.Text) {
                $script:lastRuntimeAreaOpened = [int]$count.Opened
                return
            }
            if (Patch-MnMTranslationValue $moduleInfo 'cat.area_quests' $target) {
                $script:lastRuntimeAreaOpened = [int]$count.Opened
                Log ('Area-quest authoritative count synced: ' + $count.Opened + '/' + $count.Total + '; reason=' + $reason)
            }
        } catch { Log ('Area-quest authoritative count sync failed: ' + $_.Exception.Message) }
    }


    function Sync-ImmediateChestCategoryCounts([string]$reason,[string[]]$changedIds) {
        # v1.18.29: do not wait for the Slot DB/helper round-trip.  The Actor completion
        # witness already identifies the exact DSC_* row, so use the current save snapshot
        # as the baseline, union current-generation strong Actor witnesses, and patch only
        # the nine category labels immediately.  The later save pass remains the final
        # authority and will correct any mismatch automatically.
        try {
            $effectiveInfo=Get-EffectiveOpenedChestSet
            # Without a full save snapshot we cannot reconstruct already-open categories
            # safely. Defer rather than momentarily showing a one-chest-only baseline.
            if(-not $effectiveInfo.HasSnapshot){return $false}
            $effective=$effectiveInfo.Set

            $totals=@{chests_grade1=0;chests_grade2=0;chests_grade3=0;chests_grade4=0;chests_grade5=0;chests_key=0;chests_map=0;chests_puzzle_sep=0;chests_minigame=0}
            $opened=@{}
            foreach($k in @($totals.Keys)){$opened[$k]=0}
            foreach($id in @($script:chestKindById.Keys)){
                $k=[string]$script:chestKindById[$id]
                if($totals.ContainsKey($k)){$totals[$k]=[int]$totals[$k]+1}
            }
            foreach($id in @($effective.Keys)){
                $k=[string]$script:chestKindById[$id]
                if($opened.ContainsKey($k)){$opened[$k]=[int]$opened[$k]+1}
            }

            $moduleInfo=Get-MnMModuleInfo
            if($null -eq $moduleInfo){return $false}
            $changedKinds=@{}
            if($null -ne $changedIds -and $changedIds.Count -gt 0){
                foreach($rawChanged in $changedIds){
                    if([String]::IsNullOrWhiteSpace($rawChanged)){continue}
                    $cid=([string]$rawChanged).Trim()
                    if($script:chestKindById.ContainsKey($cid)){$changedKinds[[string]$script:chestKindById[$cid]]=$true}
                }
            }
            foreach($p in @(
                @('cat.chests_grade1','chests_grade1'),@('cat.chests_grade2','chests_grade2'),@('cat.chests_grade3','chests_grade3'),
                @('cat.chests_grade4','chests_grade4'),@('cat.chests_grade5','chests_grade5'),@('cat.chests_key','chests_key'),
                @('cat.chests_map','chests_map'),@('cat.chests_puzzle_sep','chests_puzzle_sep'),@('cat.chests_puzzle','chests_puzzle_sep'),
                @('cat.chests_minigame','chests_minigame')
            )){
                $key=[string]$p[0];$kind=[string]$p[1]
                if($changedKinds.Count -gt 0 -and -not $changedKinds.ContainsKey($kind)){continue}
                Patch-RuntimeCompletionCountKey $moduleInfo $key ([int]$opened[$kind]) ([int]$totals[$kind]) | Out-Null
            }

            $sig=(@($totals.Keys | Sort-Object | ForEach-Object { $_ + '=' + $opened[$_] + '/' + $totals[$_] }) -join ';')
            if($sig -cne $script:lastImmediateChestCategorySig){
                $script:lastImmediateChestCategorySig=$sig
                Log ('Immediate chest category counts synced from Actor witness: ' + $sig + '; reason=' + $reason)
            }
            return $true
        } catch {
            Log ('Immediate chest category sync failed: ' + $_.Exception.Message + '; reason=' + $reason)
            return $false
        }
    }

    function Remember-ActorCompletedId([string]$id) {
        if ([String]::IsNullOrWhiteSpace($id) -or $id -notmatch '^DSC_\d+$') { return }
        $script:actorCompletedIds[$id] = $true
        # Native presence reconciliation can revive an opened chest very late (observed ~55s),
        # so keep a bounded 120s high-priority reassert window for each strong completion.
        $script:actorStrongGuardUntil[$id] = [DateTime]::UtcNow.AddSeconds(120)
        # v1.18.18+: persistence is per-save only; no process-global chest cache write.
    }

    function Drain-ActorChestEvents {
        $lines=@(Take-RadarEventQueue $script:actorEventQueuePath)
        if($lines.Count -eq 0){return}
        $ids = New-Object System.Collections.Generic.List[string]
        foreach ($line in $lines) {
            if ([String]::IsNullOrWhiteSpace($line)) { continue }
            $parts = ([string]$line).Split('|')
            if ($parts.Count -lt 1) { continue }
            $id = $parts[0].Trim()
            if ($id -notmatch '^DSC_\d+$') { continue }
            # New producers timestamp every chest event. Untagged legacy queue rows
            # cannot be assigned to this process and must await save confirmation.
            $eventEpoch=0L
            if($parts.Count -lt 8 -or -not [Int64]::TryParse($parts[7],[ref]$eventEpoch) -or $eventEpoch -lt $script:gameStartEpoch){
                Log ('Chest event rejected as stale/untagged: '+$id);continue
            }
            if(-not $script:chestKindById.ContainsKey($id)){continue}
            $src = if ($parts.Count -ge 2) { $parts[1] } else { 'actor-state' }
            if ($src.StartsWith('candidate_')) {
                $script:actorCandidateIds[$id] = $true
                Log ('Actor-state treasure candidate: ' + $id + '; source=' + $src + '; action=await_save_positive_confirmation')
                continue
            }
            Remember-ActorCompletedId $id
            if (-not $ids.Contains($id)) { [void]$ids.Add($id) }
            Log ('Actor-state treasure completion witness: ' + $id + '; source=' + $src)
        }
        if ($ids.Count -gt 0) {
            if (-not (Hide-ChestIdsByOffsetCache @($ids) 'actor-strong-completion')) { Hide-ExactNodes @($ids) }
            $pressureSet = Mark-PressurePuzzleDoneByChestIds @($ids) 'actor-strong-completion'
            $sliderSet = Mark-SliderPuzzleDoneByChestIds @($ids) 'actor-strong-completion'
            $statueSet = Mark-StatuePuzzleDoneByChestIds @($ids) 'actor-strong-completion'
            Sync-ImmediateChestCategoryCounts 'actor-strong-completion' @($ids) | Out-Null
            if ($pressureSet -gt 0 -or $sliderSet -gt 0 -or $statueSet -gt 0) { Sync-RuntimeTransientCompletionCountLabels 'puzzle-from-actor' | Out-Null }
        }
    }


    function Ensure-AreaProgressIds([string[]]$ids,[string]$reason) {
        if ($null -eq $ids -or $ids.Count -eq 0) { return 0 }
        $progressPath = Join-Path $dllsRoot 'progress.txt'
        try {
            $seen = @{}
            if (Test-Path -LiteralPath $progressPath) {
                foreach ($raw in (Get-Content -LiteralPath $progressPath -ErrorAction Stop)) {
                    if ([String]::IsNullOrWhiteSpace($raw)) { continue }
                    $t = ([string]$raw).Trim()
                    if ($t.Length -gt 0) { $seen[$t] = $true }
                }
            }
            $added = 0
            foreach ($raw in $ids) {
                if ([String]::IsNullOrWhiteSpace($raw)) { continue }
                $id = ([string]$raw).Trim()
                if (-not $script:areaQuestIds.ContainsKey($id) -or $seen.ContainsKey($id)) { continue }
                # Append only the exact numeric ID. This cannot overwrite a concurrent
                # MnMRadar completion line the way a read/replace transaction could.
                Add-Content -LiteralPath $progressPath -Value $id -Encoding ASCII
                $seen[$id] = $true
                $added++
            }
            if ($added -gt 0) {
                Log ('Exact area-quest completion appended to progress.txt: added=' + $added + '; reason=' + $reason)
            }
            return $added
        }
        catch {
            Log ('Exact area-quest progress append failed: ' + $_.Exception.Message + '; reason=' + $reason)
            return 0
        }
    }

    function Reset-ExactAreaCompletionSessionCache([string]$reason) {
        $count = $script:exactAreaCompletedIds.Count
        $script:exactAreaCompletedIds.Clear()
        $script:exactAreaReassertRemaining = 0
        $script:exactAreaNextReassertUtc = [DateTime]::MinValue
        Log ('Exact area-quest activation cache reset: previous=' + $count + '; reason=' + $reason)
    }

    function Reapply-ExactAreaCompletions([string]$reason) {
        if ($script:exactAreaCompletedIds.Count -eq 0) { return }
        $ids = @($script:exactAreaCompletedIds.Keys)
        [void](Ensure-AreaProgressIds $ids $reason)
        Hide-ExactNodes $ids
        Sync-RuntimeAreaQuestCountLabel $reason
        Log ('Exact area-quest completion reapply: count=' + $ids.Count + '; reason=' + $reason)
    }

    function Drain-AreaQuestEvents {
        $lines=@(Take-RadarEventQueue $script:areaQuestEventQueuePath)
        if($lines.Count -eq 0){return}

        $ids = New-Object System.Collections.Generic.List[string]
        foreach ($line in $lines) {
            if ([String]::IsNullOrWhiteSpace($line)) { continue }
            $parts = ([string]$line).Split('|')
            if ($parts.Count -lt 4 -or $parts[0].Trim() -ne 'AREA_QUEST_COMPLETE') { continue }
            $eventEpoch = 0L
            $null = [Int64]::TryParse($parts[1].Trim(), [ref]$eventEpoch)
            if ($eventEpoch -le 0 -or $eventEpoch -lt $script:gameStartEpoch) {
                Log ('Exact area-quest event rejected as stale from previous process: epoch=' + $eventEpoch)
                continue
            }
            $id = $parts[2].Trim()
            if (-not $script:areaQuestIds.ContainsKey($id)) {
                Log ('Exact area-quest event rejected: unknown catalog ID=' + $id)
                continue
            }
            $source = $parts[3].Trim()
            if (-not $script:exactAreaCompletedIds.ContainsKey($id)) {
                $script:exactAreaCompletedIds[$id] = $true
                if (-not $ids.Contains($id)) { [void]$ids.Add($id) }
            }
            Log ('AREA_QUEST_EXACT_COMPLETION_OBSERVED id=' + $id + '; source=' + $source)
        }

        if ($ids.Count -gt 0) {
            [void](Ensure-AreaProgressIds $ids.ToArray() 'exact-native-callback')
            Hide-ExactNodes $ids.ToArray()
            Sync-RuntimeAreaQuestCountLabel 'exact-native-callback'
            # Two event-only reassertions protect against an older in-flight native scan
            # publishing a stale ACCEPTABLE/PROGRESS state after the completion edge.
            # No steady polling is added.
            $script:exactAreaReassertRemaining = 2
            $script:exactAreaNextReassertUtc = [DateTime]::UtcNow.AddMilliseconds(900)
            Log ('AREA_QUEST_EXACT_COMPLETION_APPLIED ids=' + ($ids -join ',') + '; stale-scan-guard=2')
        }
    }

    function Service-ExactAreaReassert {
        if ($script:exactAreaReassertRemaining -le 0 -or $script:exactAreaCompletedIds.Count -eq 0) { return }
        $now = [DateTime]::UtcNow
        if ($now -lt $script:exactAreaNextReassertUtc) { return }
        Reapply-ExactAreaCompletions ('stale-scan-guard-' + $script:exactAreaReassertRemaining)
        $script:exactAreaReassertRemaining--
        if ($script:exactAreaReassertRemaining -gt 0) {
            $script:exactAreaNextReassertUtc = $now.AddMilliseconds(1800)
        } else {
            $script:exactAreaNextReassertUtc = [DateTime]::MinValue
        }
    }

    function Service-StartupStateRestore {
        if(-not $script:startupStateRestorePending -or $script:saveTransitionPending){return}
        if([DateTime]::UtcNow -lt $script:startupStateRestoreNextUtc){return}
        $script:startupStateRestoreNextUtc=[DateTime]::UtcNow.AddSeconds(1)
        if($null -eq $script:authoritySnapshot){return}
        $chestOk=Reapply-CurrentSaveChestSnapshot 'startup-authoritative-retry'
        $areaOk=Set-RuntimeAreaStateFromIdSet (Read-FastAreaSnapshotMap) 'startup-authoritative-retry'
        if($chestOk -and $areaOk){
            $script:startupStateRestorePending=$false
            Log 'Startup chest/area state restore committed.'
        }
    }

    function Get-SaveFingerprint {
        try {
            if (-not (Test-Path -LiteralPath $saveRoot)) { return 'missing' }
            $parts = New-Object System.Collections.Generic.List[string]
            # Use the provider filter so the 15-second safety fallback does not enumerate
            # every unrelated file in the SaveGames tree. SQLite Slot sidecars still match.
            $files = Get-ChildItem -LiteralPath $saveRoot -Recurse -File -Filter '*_Slot*' -ErrorAction SilentlyContinue |
                Sort-Object FullName
            foreach ($f in $files) {
                $parts.Add(
                    $f.FullName + '|' +
                    $f.LastWriteTimeUtc.Ticks + '|' +
                    $f.Length)
            }
            return [String]::Join("`n", $parts.ToArray())
        }
        catch {
            return 'error:' + $_.Exception.Message
        }
    }

    function Get-MnMProgressFingerprint {
        try {
            $p = Join-Path $dllsRoot 'progress.txt'
            if (-not (Test-Path -LiteralPath $p)) { return 'missing' }
            $f = Get-Item -LiteralPath $p -ErrorAction Stop
            return ($f.LastWriteTimeUtc.Ticks.ToString() + '|' + $f.Length.ToString())
        } catch { return 'error:' + $_.Exception.Message }
    }


    $fastChestSnapshotPath = Join-Path $syncRoot 'cache\fast_live_chest_snapshot.txt'
    $fastAreaSnapshotPath = Join-Path $syncRoot 'cache\fast_live_area_snapshot.txt'
    $watcherChestSnapshot = @{}

    function Read-FastChestSnapshotMap {
    if($null -eq $script:authoritySnapshot){return @{}}
    return $script:authoritySnapshot.Chests.Clone()
}

    function Read-FastAreaSnapshotMap {
    if($null -eq $script:authoritySnapshot){return @{}}
    return $script:authoritySnapshot.Areas.Clone()
}

    function Get-AuthoritativeProfileSlot {
    if($null -eq $script:authoritySnapshot){return ''}
    return [string]$script:authoritySnapshot.Slot
}

    function Get-IdSetSignature([string[]]$ids) {
        if ($null -eq $ids) { return '' }
        return (@($ids | Where-Object { -not [String]::IsNullOrWhiteSpace($_) } | ForEach-Object { ([string]$_).Trim() } | Sort-Object -Unique) -join ',')
    }

    function Get-IdMapSignature([hashtable]$set) {
        if ($null -eq $set) { return '' }
        return (@($set.Keys | ForEach-Object { [string]$_ } | Sort-Object -Unique) -join ',')
    }

    function Patch-ProfileChestAreaCounts([hashtable]$chests,[hashtable]$areas,[string]$reason) {
        try {
            $moduleInfo = Get-MnMModuleInfo
            if ($null -eq $moduleInfo) { return }
            $totals = @{
                chests_grade1=0; chests_grade2=0; chests_grade3=0; chests_grade4=0; chests_grade5=0
                chests_key=0; chests_map=0; chests_puzzle_sep=0; chests_minigame=0
            }
            foreach ($id in @($script:chestKindById.Keys)) {
                $k=[string]$script:chestKindById[$id]
                if($totals.ContainsKey($k)){ $totals[$k]=[int]$totals[$k]+1 }
            }
            $opened=@{}
            foreach($k in @($totals.Keys)){ $opened[$k]=0 }
            foreach ($id in @($chests.Keys)) {
                if(-not $script:chestKindById.ContainsKey([string]$id)){continue}
                $k=[string]$script:chestKindById[[string]$id]
                if($opened.ContainsKey($k)){ $opened[$k]=[int]$opened[$k]+1 }
            }
            $pairs=@(
                @('cat.chests_grade1','chests_grade1'),@('cat.chests_grade2','chests_grade2'),@('cat.chests_grade3','chests_grade3'),
                @('cat.chests_grade4','chests_grade4'),@('cat.chests_grade5','chests_grade5'),@('cat.chests_key','chests_key'),
                @('cat.chests_map','chests_map'),@('cat.chests_puzzle_sep','chests_puzzle_sep'),@('cat.chests_puzzle','chests_puzzle_sep'),
                @('cat.chests_minigame','chests_minigame')
            )
            foreach($pair in $pairs){
                $key=[string]$pair[0];$kind=[string]$pair[1]
                Patch-RuntimeCompletionCountKey $moduleInfo $key ([int]$opened[$kind]) ([int]$totals[$kind]) | Out-Null
            }
            $allOpened=0;$allTotal=0
            foreach($k in @($totals.Keys)){ $allOpened += [int]$opened[$k]; $allTotal += [int]$totals[$k] }

            # v1.18.29: per-category counts use the updated exploration-chest catalog,
            # while the aggregate row remains the game's own WorldComplete TREASUREBOX_OPEN universe
            # (A40 opened / B90 target) whenever a current-generation in-process sidecar exists.
            $native = Read-NativeWorldCompleteChestCount
            if ($null -ne $native) {
                Patch-RuntimeCompletionCountKey $moduleInfo 'grp.chests' ([int]$native.Opened) ([int]$native.Total) | Out-Null
                $aggregateText = ([string]$native.Opened + '/' + [string]$native.Total + ' native-A40/B90')
            } else {
                Patch-RuntimeCompletionCountKey $moduleInfo 'grp.chests' $allOpened ([int]$script:nativeWorldCompleteTreasureTotal) | Out-Null
                $aggregateText = ([string]$allOpened + '/' + [string]$script:nativeWorldCompleteTreasureTotal + ' radar-opened/native-total-fallback')
            }
            Patch-RuntimeCompletionCountKey $moduleInfo 'cat.area_quests' ([int]$areas.Count) ([int]$script:areaQuestIds.Count) | Out-Null
            Log ('Known-profile count labels applied: chests=' + $aggregateText + '; area=' + $areas.Count + '/' + $script:areaQuestIds.Count + '; reason=' + $reason)
        } catch { Log ('Known-profile count patch failed: ' + $_.Exception.Message) }
    }

    function Find-UniqueKnownProfileByRuntime161([string]$signature) {
        if ([String]::IsNullOrWhiteSpace($signature) -or -not (Test-Path -LiteralPath $script:saveProfileRoot)) { return $null }
        $matches = New-Object System.Collections.Generic.List[object]
        try {
            foreach($dir in @(Get-ChildItem -LiteralPath $script:saveProfileRoot -Directory -ErrorAction SilentlyContinue)) {
                $valid161=Join-Path $dir.FullName 'transient161.v2.valid'
                $transient=Join-Path $dir.FullName 'transient161.txt'
                $slotFile=Join-Path $dir.FullName 'slot_path.txt'
                $validAuth=Join-Path $dir.FullName 'chest_area.v3.valid'
                $chestFile=Join-Path $dir.FullName 'chests.txt'
                $areaFile=Join-Path $dir.FullName 'area_quests.txt'
                if(-not (Test-Path -LiteralPath $valid161) -or -not (Test-Path -LiteralPath $transient) -or -not (Test-Path -LiteralPath $slotFile)){continue}
                $set=Read-IdSetFile $transient
                if((Get-IdMapSignature $set) -cne $signature){continue}
                $slot=Read-StateTextSafe $slotFile
                if([String]::IsNullOrWhiteSpace($slot)){continue}
                $chests=@{};$areas=@{}
                if((Test-Path -LiteralPath $validAuth) -and (Test-Path -LiteralPath $chestFile) -and (Test-Path -LiteralPath $areaFile)){
                    $chests=Read-IdSetFile $chestFile; $areas=Read-IdSetFile $areaFile
                }
                $matches.Add([pscustomobject]@{Slot=$slot;Transient=$set;Chests=$chests;Areas=$areas;Key=$dir.Name}) | Out-Null
                if($matches.Count -gt 1){break}
            }
        } catch { return $null }
        if($matches.Count -eq 1){return $matches[0]}
        return $null
    }

    function Try-ApplyKnownProfileFingerprint([hashtable]$state,[string]$reason) {
        if($null -eq $state -or $null -eq $state.CompletedIds){return}
        $sig=Get-IdSetSignature @($state.CompletedIds)
        if([String]::IsNullOrWhiteSpace($script:transitionRuntime161BaselineSignature)){return}
        if($sig -ceq $script:transitionRuntime161BaselineSignature){
            $script:profileFingerprintSignature='';$script:profileFingerprintSamples=0;$script:profileFingerprintSinceUtc=[DateTime]::MinValue
            return
        }
        $now=[DateTime]::UtcNow
        if($sig -cne $script:profileFingerprintSignature){
            $script:profileFingerprintSignature=$sig;$script:profileFingerprintSamples=1;$script:profileFingerprintSinceUtc=$now
            return
        }
        $script:profileFingerprintSamples++
        if($script:profileFingerprintSamples -lt 2 -or ($now-$script:profileFingerprintSinceUtc).TotalMilliseconds -lt 180){return}
        $match=Find-UniqueKnownProfileByRuntime161 $sig
        if($null -eq $match){return}
        if($script:profileFingerprintBoundSlot -ceq [string]$match.Slot){return}
        # This is a cache-only fast hint. It never rewrites fast_live_slot or game save data.
        # The later save-authoritative helper is still allowed to override every value.
        if($match.Chests.Count -gt 0 -or (Test-Path -LiteralPath (Join-Path (Get-SaveProfileDir $match.Slot $false) 'chest_area.v3.valid'))){
            Reconcile-RuntimeChestState $match.Chests ('runtime161-unique-profile|' + $reason) | Out-Null
            Set-RuntimeAreaStateFromIdSet $match.Areas ('runtime161-unique-profile|' + $reason) | Out-Null
            Patch-ProfileChestAreaCounts $match.Chests $match.Areas ('runtime161-unique-profile|' + $reason)
        }
        if(-not (Write-RadarTextAtomic $script:profileHintSlotPath ([string]$match.Slot + "`r`n"))){
            Log 'Profile hint publication deferred; a later burst may retry.'
            return
        }
        $script:profileFingerprintBoundSlot=[string]$match.Slot
        Log ('Per-save fast profile fingerprint applied: key=' + $match.Key + '; runtime161=' + $state.CompletedIds.Count + '; reason=' + $reason + '; authority=pending-save-confirmation')
    }

    function Arm-Runtime161Burst([string]$reason,[bool]$captureBaseline) {
        if($captureBaseline){
            $script:saveTransitionPending=$true
            $script:nativeChestGenerationEpochUtc=[DateTime]::UtcNow
            $script:lastNativeChestSignature=''
            Remove-Item -LiteralPath $script:profileHintSlotPath -Force -ErrorAction SilentlyContinue
            $script:transitionRuntime161BaselineSignature=''
            try{
                $baseline=Get-RuntimeTransientCompletionCounts
                if($null -ne $baseline){$script:transitionRuntime161BaselineSignature=Get-IdSetSignature @($baseline.CompletedIds)}
            }catch{}
            if([String]::IsNullOrWhiteSpace($script:transitionRuntime161BaselineSignature) -and -not [String]::IsNullOrWhiteSpace($script:lastObservedRuntime161Signature)){
                $script:transitionRuntime161BaselineSignature=$script:lastObservedRuntime161Signature
            }
            $script:profileFingerprintBoundSlot=''
            $script:profileFingerprintSignature=''
            $script:profileFingerprintSamples=0
            $script:profileFingerprintSinceUtc=[DateTime]::MinValue
            $baselineCount = if([String]::IsNullOrWhiteSpace($script:transitionRuntime161BaselineSignature)){0}else{($script:transitionRuntime161BaselineSignature -split ',').Count}
            Log ('Runtime 161 transition baseline captured: doneSigCount=' + $baselineCount + '; reason=' + $reason)
        }
        $until=[DateTime]::UtcNow.AddSeconds(15)
        if($until -gt $script:runtime161BurstUntilUtc){$script:runtime161BurstUntilUtc=$until}
        $script:runtime161BurstNextUtc=[DateTime]::UtcNow
        Log ('Runtime 161 fast burst armed: 250ms/15s; reason=' + $reason)
    }

    function Consume-Runtime161BurstRequest {
        foreach($raw in @(Take-RadarEventQueue $script:runtime161BurstRequestPath)){
            if([string]::IsNullOrWhiteSpace($raw)){continue}
            $stamp=[regex]::Match($raw,'(?:^|;)epoch=([0-9]+)(?:;|$)')
            $eventEpoch=0L
            if(-not $stamp.Success -or -not [long]::TryParse($stamp.Groups[1].Value,[ref]$eventEpoch) -or $eventEpoch -lt $script:gameStartEpoch){
                Log 'Runtime burst request rejected as stale/untagged.';continue
            }
            $capture=($raw -match '(?i)(?:^|;)phase=transition(?:;|$)')
            Arm-Runtime161Burst $raw $capture
        }
    }

    function Service-Runtime161Burst([string]$reason) {
        $now=[DateTime]::UtcNow
        if($now -gt $script:runtime161BurstUntilUtc -or $now -lt $script:runtime161BurstNextUtc){return}
        $script:runtime161BurstNextUtc=$now.AddMilliseconds(250)
        try{
            $state=Get-RuntimeTransientCompletionCounts
            if($null -eq $state){return}
            $script:lastObservedRuntime161Signature=Get-IdSetSignature @($state.CompletedIds)
            # Patch the visible counters from this same snapshot; avoid waiting for the old 5s safety poll.
            $moduleInfo=$state.Module;$c=$state.Counts
            $fly=$c.fly;$mole=$c.mole;$wave=$c.wave
            $pressure=Reconcile-PressurePuzzleStateFromChestAuthority $moduleInfo $state.Vector ('burst|' + $reason)
            if($null -eq $pressure){$pressure=$c.puzzle_platform}
            $slider=Reconcile-SliderPuzzleStateFromChestAuthority $moduleInfo $null ('burst|' + $reason)
            if($null -eq $slider){$slider=Get-RuntimeStaticSliderCount $moduleInfo $null}
            if($null -eq $slider){$slider=@{Opened=0;Total=$script:sliderStaticCoords.Count;CompletedIds=@()}}
            Observe-StaticSliderProfile @($slider.CompletedIds) ('burst|' + $reason)
            $statue=Reconcile-StatuePuzzleStateFromChestAuthority $moduleInfo $null ('burst|' + $reason)
            if($null -eq $statue){$statue=Get-RuntimeStaticStatueCount $moduleInfo $null;if($null -eq $statue){$statue=@{Opened=0;Total=$script:statueStaticCoords.Count}}}
            $mgOpened=[int]$fly.Opened+[int]$mole.Opened+[int]$wave.Opened;$mgTotal=[int]$fly.Total+[int]$mole.Total+[int]$wave.Total
            $nativeMg=Read-NativeWorldCompleteMiniGameCount
            $mgGroupOpened=if($null -ne $nativeMg){[int]$nativeMg.Opened}else{$mgOpened};$mgGroupTotal=if($null -ne $nativeMg){[int]$nativeMg.Total}else{$mgTotal}
            $pzOpened=[int]$pressure.Opened+[int]$slider.Opened+[int]$statue.Opened;$pzTotal=[int]$pressure.Total+[int]$slider.Total+[int]$statue.Total
            foreach($p in @(
                @('cat.fly',[int]$fly.Opened,[int]$fly.Total),@('cat.mole',[int]$mole.Opened,[int]$mole.Total),@('cat.wave',[int]$wave.Opened,[int]$wave.Total),@('grp.minigames',$mgGroupOpened,$mgGroupTotal),
                @('cat.puzzle_platform',[int]$pressure.Opened,[int]$pressure.Total),@('cat.platform',[int]$pressure.Opened,[int]$pressure.Total),@('cat.puzzle_slider',[int]$slider.Opened,[int]$slider.Total),@('cat.slider',[int]$slider.Opened,[int]$slider.Total),@('cat.puzzle_statue',[int]$statue.Opened,[int]$statue.Total),@('grp.puzzles',$pzOpened,$pzTotal)
            )){Patch-RuntimeCompletionCountKey $moduleInfo ([string]$p[0]) ([int]$p[1]) ([int]$p[2]) | Out-Null}
            Observe-Runtime161ForProfile @($state.CompletedIds) ('burst|' + $reason)
            Try-ApplyKnownProfileFingerprint $state ('burst|' + $reason)
        }catch{Log ('Runtime 161 burst sample failed: ' + $_.Exception.Message)}
    }

    function Get-TransientProfileSet([string]$slot) {
        if ([String]::IsNullOrWhiteSpace($slot)) { return $null }
        $dir = Get-SaveProfileDir $slot $false
        if ($dir.Length -eq 0 -or -not (Test-Path -LiteralPath $dir)) { return $null }
        $valid = Join-Path $dir 'transient161.v2.valid'
        $path = Join-Path $dir 'transient161.txt'
        if (-not (Test-Path -LiteralPath $valid) -or -not (Test-Path -LiteralPath $path)) { return $null }
        return (Read-IdSetFile $path)
    }

    function Apply-TransientProfileIfValid([string]$slot,[string]$reason) {
        $set = Get-TransientProfileSet $slot
        if ($null -eq $set) {
            Log ('Per-save 161 profile miss/unvalidated: key=' + (Get-SaveProfileKey $slot) + '; reason=' + $reason)
            return $false
        }
        if (Set-RuntimeTransientStateFromIdSet $set ('profile-v2|' + $reason)) {
            $script:profileWarmTransientSlot = $slot
            Log ('Per-save 161 profile applied: key=' + (Get-SaveProfileKey $slot) + '; done=' + $set.Count + '; reason=' + $reason)
            return $true
        }
        return $false
    }

    function Reset-ProfileStability([string]$slot) {
        $script:profileStableSlot = $slot
        $script:profileStableSignature = ''
        $script:profileStableSinceUtc = [DateTime]::MinValue
        $script:profileStableSamples = 0
    }

    function Observe-Runtime161ForProfile([string[]]$ids,[string]$reason) {
        if($script:saveTransitionPending){return}
        $slot = Get-AuthoritativeProfileSlot
        if ([String]::IsNullOrWhiteSpace($slot)) { return }
        if ($slot -ne $script:profileGenerationReadySlot) { return }

        # v1.18.38: save transitions can refresh destination runtime nodes many seconds
        # before the Slot database fingerprint changes. Never create/overwrite the source
        # profile from that large jump. A boundary capture is the only creator; normal play
        # may then advance the profile by a small monotonic delta.
        $existing = Get-TransientProfileSet $slot
        if ($null -eq $existing) { return }

        if ($script:profileStableSlot -ne $slot) { Reset-ProfileStability $slot }
        $set = @{}
        foreach ($id in $ids) { if (-not [String]::IsNullOrWhiteSpace($id)) { $set[[string]$id]=$true } }

        foreach($k in @($existing.Keys)){
            if(-not $set.ContainsKey([string]$k)){
                Log ('Per-save 161 profile update quarantined: runtime shrank before slot authority changed; key=' +
                     (Get-SaveProfileKey $slot) + '; reason=' + $reason)
                return
            }
        }
        $added = $set.Count - $existing.Count
        # One interaction can legitimately complete a minigame and/or its pressure witness.
        # A jump larger than two is treated as a destination-world transition, not gameplay.
        if ($added -gt 2) {
            Log ('Per-save 161 profile update quarantined: large jump +' + $added +
                 ' suggests save transition; key=' + (Get-SaveProfileKey $slot) + '; reason=' + $reason)
            return
        }
        if ($added -le 0) { return }

        $sig = ($set.Keys | Sort-Object) -join ','
        $now = [DateTime]::UtcNow
        if ($sig -cne $script:profileStableSignature) {
            $script:profileStableSignature = $sig
            $script:profileStableSinceUtc = $now
            $script:profileStableSamples = 1
            return
        }
        $script:profileStableSamples++
        $elapsed = ($now - $script:profileStableSinceUtc).TotalSeconds
        if ($script:profileStableSamples -lt 2 -or $elapsed -lt 0.45) { return }
        try {
            $dir = Get-SaveProfileDir $slot $true
            if ($dir.Length -eq 0) { return }
            if (Write-IdSetFileAtomic (Join-Path $dir 'transient161.txt') $set) {
                [IO.File]::WriteAllText((Join-Path $dir 'transient161.v2.valid'),((Get-Date).ToString('O') + "`r`n"),(New-Object Text.UTF8Encoding($false)))
                [IO.File]::WriteAllText((Join-Path $dir 'slot_path.txt'),($slot + "`r`n"),(New-Object Text.UTF8Encoding($false)))
                Log ('Per-save 161 profile advanced safely: key=' + (Get-SaveProfileKey $slot) +
                     '; done=' + $set.Count + '; added=' + $added + '; reason=' + $reason)
            }
        } catch { Log ('Per-save 161 profile commit failed: ' + $_.Exception.Message) }
    }

    function Advance-WatcherChestSnapshotAndGetDelta {
        $current = Read-FastChestSnapshotMap
        $delta = New-Object System.Collections.Generic.List[string]
        foreach ($id in $current.Keys) {
            if (-not $script:watcherChestSnapshot.ContainsKey($id)) { $delta.Add([string]$id) }
        }
        $script:watcherChestSnapshot = $current
        return @($delta | Sort-Object -Unique)
    }

    $watcherChestSnapshot = Read-FastChestSnapshotMap
    Log ('Watcher-owned chest delta baseline seeded: ' + $watcherChestSnapshot.Count + ' opened chest node(s).')

    function Run-LiveSync([string]$reason) {
        for ($attempt = 1; $attempt -le 4; $attempt++) {
            if ($game.HasExited) { return $false }
            $stdoutPath=$null;$stderrPath=$null
            try {
                Log ('Live sync helper start. attempt=' + $attempt)

                # v1.18.11: run the save/progress helper as a child process but keep this
                # watcher responsive while it is working.  The old synchronous '& exe'
                # blocked the only actor-event consumer for 3-5 seconds on some save passes,
                # so a real NetMultiExecuteInteractProp event could sit in the queue until
                # save decryption finished.  Poll the child every 50 ms and drain actor
                # evidence between waits; save confirmation remains authoritative afterwards.
                $tmpDir = Join-Path $syncRoot 'cache'
                if (-not (Test-Path -LiteralPath $tmpDir)) { [void](New-Item -ItemType Directory -Path $tmpDir -Force) }
                $stdoutPath = Join-Path $tmpDir ('live_sync_stdout_' + $PID + '_' + $attempt + '.tmp')
                $stderrPath = Join-Path $tmpDir ('live_sync_stderr_' + $PID + '_' + $attempt + '.tmp')
                Remove-Item -LiteralPath $stdoutPath,$stderrPath -Force -ErrorAction SilentlyContinue
                $argList = if ($reason -eq 'mnm-progress') { @('--in-game','--progress-only') } elseif ($reason -eq 'reload') { @('--in-game','--fast-live','--save-reload') } else { @('--in-game','--fast-live') }
                $syncProc = Start-Process -FilePath $exePath -ArgumentList $argList -NoNewWindow -PassThru `
                    -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath
                $helperWatch = [Diagnostics.Stopwatch]::StartNew()
                $helperTimedOut = $false
                $timeoutMs = 45000
                if($script:liveSyncTimeoutMs -gt 0){$timeoutMs=[int]$script:liveSyncTimeoutMs}
                try {
                    while (-not $syncProc.WaitForExit(50)) {
                        Drain-ActorChestEvents
                        Consume-Runtime161BurstRequest
                        Service-Runtime161Burst 'helper-wait'
                        if ($game.HasExited -or $helperWatch.ElapsedMilliseconds -ge $timeoutMs) {
                            $helperTimedOut = -not $game.HasExited
                            try { $syncProc.Kill() } catch { }
                            break
                        }
                    }
                    if(-not $syncProc.WaitForExit(2000)){throw 'Sync helper did not exit after cancellation; result not adopted.'}
                    if($helperTimedOut){throw ('Sync helper exceeded '+$timeoutMs+' ms; trigger will be retried.')}
                    # Catch an event appended during the final child-process exit window.
                    Drain-ActorChestEvents
                    $code = $syncProc.ExitCode
                } finally {
                    try { $syncProc.Dispose() } catch { }
                }
                $out = @()
                if (Test-Path -LiteralPath $stdoutPath) {
                    try { $out += @(Get-Content -LiteralPath $stdoutPath -ErrorAction Stop) } catch { }
                }
                if (Test-Path -LiteralPath $stderrPath) {
                    try { $out += @(Get-Content -LiteralPath $stderrPath -ErrorAction Stop) } catch { }
                }
                $text = ($out | ForEach-Object { $_.ToString() }) -join "`n"
                $codeDisplay = if ($null -eq $code -or [String]::IsNullOrWhiteSpace([string]$code)) { '<blank>' } else { [string]$code }
                Log ('Live sync helper returned. attempt=' + $attempt + '; exit=' + $codeDisplay)

                # v1.18.12: Windows PowerShell 5.1 can return a Process object whose ExitCode
                # is blank after Start-Process + redirected output, even though the helper
                # completed normally.  The helper emits FAST_LIVE_MS only on the normal
                # successful return path, so use that completion marker as a deterministic
                # fallback when ExitCode is unavailable.  This preserves v1.18.11's
                # non-blocking actor-event drain without breaking save-authoritative sync.
                $helperSuccess = ($code -eq 0)
                if (-not $helperSuccess -and ($null -eq $code -or [String]::IsNullOrWhiteSpace([string]$code))) {
                    if ($text -match '(?m)^FAST_LIVE_MS=\d+\s*$') {
                        $helperSuccess = $true
                        Log 'Live sync helper exit code unavailable; accepted success by FAST_LIVE_MS completion marker.'
                    }
                }

                if ($helperSuccess) {
                    if (-not (Refresh-RadarAuthoritySnapshot)) { throw 'Helper completed without a valid authority snapshot.' }
                    # v1.18.43 CROSS-SAVE NATIVE CACHE FIX:
                    # Parse/invalidate the save boundary BEFORE profile sync and BEFORE
                    # Sync-MnMTranslationCountLabels can call Read-NativeWorldCompleteChestCount.
                    # A40/B90 sidecars are process-global (not slot-tagged); without this
                    # ordering the source save's last native value can be committed under
                    # the destination save key during the ~1 frame boundary window.
                    $boundaryLine = ($text -split "`r?`n" | Where-Object { $_ -like 'FAST_BOUNDARY_FULLSTATE=*' } | Select-Object -Last 1)
                    $isFastBoundary = ($boundaryLine -and $boundaryLine.Trim().EndsWith('=1'))
                    if ($isFastBoundary) {
                        # Clear before category labels, puzzle witnesses, or profile
                        # reconciliation can reuse source-save Actor completions.
                        Reset-ActorCompletionSessionCache ('fast-live-boundary|' + $reason)
                        $script:actorGenerationPreReset = $true
                        if(-not $script:saveTransitionPending){$script:nativeChestGenerationEpochUtc = [DateTime]::UtcNow}
                        $script:saveTransitionPending=$true
                        $script:nativeGenerationPreInvalidated = $true
                        $script:lastNativeChestSignature = ''
                        $script:lastNativeChestAvailability = 'generation-reset-prehelper'
                        $script:lastNativeMiniGameAvailability = 'generation-reset-prehelper'
                        Log ('FAST boundary pre-invalidation applied before destination profile/label sync; stale source A40/B90 sidecar is now rejected.')
                    }

                    Sync-PersistentProfileAuthorityFromHelper ('fast-live|' + $reason) | Out-Null
                    if ($isFastBoundary) {
                        try {
                            $payload=('time={0:O};reason=fast-live-boundary;generation_reset=1' -f (Get-Date))
                            if(-not (Write-RadarTextAtomic $runtimeResetRequestPath $payload)){throw 'Unable to publish boundary request.'}
                            Set-Content -LiteralPath $actorResetFlagPath -Value (Get-Date).ToString('O') -Encoding ASCII
                            Log 'Fast-live helper detected a save-state boundary; runtime completion reset queued after native pre-invalidation.'
                        } catch {
                            $script:nativeGenerationPreInvalidated = $false
                            $script:actorGenerationPreReset = $false
                            Log ('Unable to queue fast-live boundary reset: ' + $_.Exception.Message)
                            throw
                        }
                    }
                    if($reason -eq 'reload' -and -not $isFastBoundary){
                        $payload=('time={0:O};reason=queued-reload;generation_reset=0' -f (Get-Date))
                        if(-not (Write-RadarTextAtomic $runtimeResetRequestPath $payload)){throw 'Unable to publish reload reconciliation request.'}
                    }
                    if($isFastBoundary -or $reason -eq 'reload'){Consume-RuntimeCompletionResetRequest}
                    $fastMsLine = ($text -split "`r?`n" | Where-Object { $_ -like 'FAST_LIVE_MS=*' } | Select-Object -Last 1)
                    if ($fastMsLine) { Log ('Fast helper timing: ' + $fastMsLine.Substring('FAST_LIVE_MS='.Length) + ' ms; reason=' + $reason) }

                    if ($reason -eq 'mnm-progress') {
                        Sync-MnMTranslationCountLabels 'progress-only'
                        Sync-RuntimeTransientCompletionCountLabels 'progress-only-runtime161' | Out-Null
                        Sync-RuntimeAreaQuestCountLabel 'progress-only-authority'
                        Log 'Progress-only count refresh completed without save decryption.'
                        return $true
                    }

                    $idsLine = ($text -split "`r?`n" |
                        Where-Object { $_ -like 'LIVE_ADDED_IDS=*' } |
                        Select-Object -Last 1)
                    $ids = @()
                    if ($idsLine) {
                        $payload = $idsLine.Substring('LIVE_ADDED_IDS='.Length).Trim()
                        if ($payload.Length -gt 0) {
                            $ids = @($payload.Split(',') |
                                ForEach-Object { $_.Trim() } |
                                Where-Object { $_.Length -gt 0 } |
                                Select-Object -Unique)
                        }
                    }

                    # v1.18.2: maintain an independent watcher-side snapshot.
                    # Even if another seed path or helper output suppresses LIVE_ADDED_IDS,
                    # the save-authoritative fast snapshot still exposes newly opened chests.
                    $watcherDelta = @(Advance-WatcherChestSnapshotAndGetDelta)
                    if ($watcherDelta.Count -gt 0) {
                        Log ('Watcher-owned chest snapshot delta: ' + ($watcherDelta -join ','))
                        $ids = @($ids + $watcherDelta | Where-Object { $_ -and $_.Trim().Length -gt 0 } | Select-Object -Unique)
                    }

                    $areaLine = ($text -split "`r?`n" |
                        Where-Object { $_ -like 'LIVE_AREA_QUEST_ADDED_IDS=*' } |
                        Select-Object -Last 1)
                    $areaIds = @()
                    if ($areaLine) {
                        $payload = $areaLine.Substring('LIVE_AREA_QUEST_ADDED_IDS='.Length).Trim()
                        if ($payload.Length -gt 0) {
                            $areaIds = @($payload.Split(',') |
                                ForEach-Object { $_.Trim() } |
                                Where-Object { $_.Length -gt 0 } |
                                Select-Object -Unique)
                        }
                    }
                    $areaCountLine = ($text -split "`r?`n" |
                        Where-Object { $_ -like 'LIVE_AREA_QUEST_COUNT=*' } |
                        Select-Object -Last 1)
                    if ($areaCountLine) { Log ('Area-quest save count refreshed: ' + $areaCountLine.Substring('LIVE_AREA_QUEST_COUNT='.Length)) }
                    # 0.4h diagnostic: the helper has already refreshed chest_counts.txt
                    # from the same save pass. Log the current summary so we can distinguish
                    # a backend-count problem from MnMRadar's cached UI-label problem.
                    try {
                        $countPath = Join-Path $syncRoot 'cache\chest_counts.txt'
                        if (Test-Path -LiteralPath $countPath) {
                            $compact = ((Get-Content -LiteralPath $countPath -ErrorAction Stop |
                                Where-Object { $_ -match '^[a-zA-Z0-9_]+=\d+/\d+$' }) -join '; ')
                            if ($compact) { Log ('Chest counts refreshed: ' + $compact) }
                        }
                    } catch {
                        Log ('Chest-count diagnostic read failed: ' + $_.Exception.Message)
                    }

                    # 0.4t: helper has written fixed-width save-authoritative labels to disk.
                    # Update MnMRadar's real translation-map values directly by key; no process scan.
                    # v1.18.31 stale-helper race fix:
                    # A helper launched before a chest opens can return after the Actor witness
                    # and carry an older chest_counts/language snapshot. Do not let that older
                    # snapshot make the just-opened category count go backwards even briefly.
                    Sync-MnMTranslationCountLabels 'live-save-sync'
                    Sync-ImmediateChestCategoryCounts 'live-save-reconcile-effective-union' @() | Out-Null
                    Sync-RuntimeTransientCompletionCountLabels 'live-save-sync-runtime161' | Out-Null
                    Sync-RuntimeAreaQuestCountLabel 'live-save-sync-authority'
                    Sync-NativeWorldCompleteChestCountLabel 'live-save-reconcile-native' | Out-Null

                    if ($ids.Count -gt 0) {
                        Log ('Save-confirmed newly opened chest node(s), location-independent: ' + ($ids -join ','))
                        foreach ($confirmedId in $ids) {
                            if ($script:actorCandidateIds.ContainsKey([string]$confirmedId)) {
                                Log ('Actor-state candidate save-positive confirmation applied: ' + [string]$confirmedId)
                                $script:actorCandidateIds.Remove([string]$confirmedId)
                            }
                        }
                        # 0.4k: ids come from the save-state snapshot delta, not progress.txt additions.
                        # Therefore this still fires if MnMRadar already wrote progress.txt locally,
                        # and it remains valid after the player moves away from the chest.
                        # Mirror the exact done byte in MnMRadar's global node table.
                        Hide-ExactNodes $ids
                        $pressureSaveSet = Mark-PressurePuzzleDoneByChestIds @($ids) 'save-confirmed-delta'
                        $sliderSaveSet = Mark-SliderPuzzleDoneByChestIds @($ids) 'save-confirmed-delta'
                        $statueSaveSet = Mark-StatuePuzzleDoneByChestIds @($ids) 'save-confirmed-delta'
                        Sync-ImmediateChestCategoryCounts 'save-confirmed-delta' @($ids) | Out-Null
                        if ($pressureSaveSet -gt 0 -or $sliderSaveSet -gt 0 -or $statueSaveSet -gt 0) { Sync-RuntimeTransientCompletionCountLabels 'puzzle-from-save' | Out-Null }
                    }
                    else {
                        Log 'Save change reconciled; no newly opened MnM chest nodes.'
                    }

                    if ($areaIds.Count -gt 0) {
                        Log ('Save-confirmed completed area quest node(s): ' + ($areaIds -join ','))
                        Hide-ExactNodes $areaIds
                    }
                    else {
                        Log 'Save change reconciled; no newly completed area-quest nodes.'
                    }
                    return $true
                }
                Log ('Live sync failed. attempt=' + $attempt + ' exit=' + $codeDisplay)
            }
            catch {
                Log ('Live sync exception. attempt=' + $attempt + ': ' + $_.Exception.Message)
            }
            finally {
                foreach($tempOutput in @($stdoutPath,$stderrPath)){
                    if(-not [string]::IsNullOrWhiteSpace($tempOutput)){Remove-Item -LiteralPath $tempOutput -Force -ErrorAction SilentlyContinue}
                }
            }
            Start-Sleep -Milliseconds 250
        }
        return $false
    }

    $lastFingerprint = Get-SaveFingerprint
    $lastFingerprintCheckUtc = [DateTime]::UtcNow
    $lastProgressFingerprint = Get-MnMProgressFingerprint
    $pending = $false
    $pendingReason = 'save'
    $lastChangeUtc = [DateTime]::MinValue
    Log ('Live save watcher started. version=' + $watchVersion + '; pid=' + $game.Id + '; saveRoot=' + $saveRoot + '; steadyRuntimePollMs=' + $script:steadyRuntimeCountPollMs + '; progressPollMs=' + $script:progressFingerprintPollMs)
    # Bootstrap launches this watcher only AFTER the authoritative seed helper returns.
    # Use the helper's coherent selected-slot snapshot until another full commit arrives.
    $startupSlot = Get-AuthoritativeProfileSlot
    if (-not [String]::IsNullOrWhiteSpace($startupSlot)) {
        Sync-PersistentProfileAuthorityFromHelper 'watcher-start' | Out-Null
        Apply-TransientProfileIfValid $startupSlot 'watcher-start' | Out-Null
        # v1.18.36: v1.18.29 introduced slider29 per-save MOD-local persistence but ordinary
        # process startup never reapplied it; only generation-reset paths did.
        # Restore it here as well so the slider row does not sit at 00/29 while the
        # world streams/requeries the 29 static SliderPuzzle nodes.
        Apply-StaticSliderProfileIfValid $startupSlot 'watcher-start' | Out-Null
    }
    $script:startupStateRestorePending=$true
    $script:startupStateRestoreNextUtc=[DateTime]::MinValue
    Service-StartupStateRestore
    Sync-MnMTranslationCountLabels 'watcher-start'

    Sync-RuntimeAreaQuestCountLabel 'startup-full3table-authority'
    Sync-RuntimeTransientCompletionCountLabels 'watcher-start-runtime161' | Out-Null

    # v1.18.31: prewarm the chest offset cache once during watcher startup.
    # v1.18.30 built it on the first real chest event, which made only that first
    # category update ~1.5 s slower. Moving the one full-vector build here keeps
    # normal chest opens on the cached-byte path from the first interaction onward.
    try {
        $prewarmModule=Get-MnMModuleInfo
        if($null -ne $prewarmModule){
            $prewarmVector=Get-NodeVector $prewarmModule
            if($null -ne $prewarmVector){
                Build-ChestOffsetCache $prewarmVector
                Log ('Chest offset cache prewarmed at startup: coverage=' + $script:chestOffsetCache.Count + '/' + $script:chestResetIds.Count)
            } else { Log 'Chest offset cache startup prewarm deferred: node vector unavailable.' }
        }
    } catch { Log ('Chest offset cache startup prewarm failed: ' + $_.Exception.Message) }

    Consume-RuntimeCompletionResetRequest
    if (-not [String]::IsNullOrWhiteSpace($startupSlot) -and [String]::IsNullOrWhiteSpace($script:profileGenerationReadySlot)) {
        $script:profileGenerationReadySlot = $startupSlot
        Reset-ProfileStability $startupSlot
    }
    $script:postLoadCountRefreshRemaining = [Math]::Max($script:postLoadCountRefreshRemaining,5)
    $script:postLoadCountRefreshNextUtc = [DateTime]::UtcNow.AddMilliseconds(100)
    Arm-Runtime161Burst 'watcher-start' $false
    Flush-PendingHideIds
    if ($script:actorCompletedIds.Count -gt 0) {
        Log ('Applying persisted actor-state chest completions: ' + $script:actorCompletedIds.Count)
        Hide-ExactNodes @($script:actorCompletedIds.Keys)
    }
    Drain-ActorChestEvents
    Drain-AreaQuestEvents

    while (-not $game.HasExited) {
        # Primary trigger: block briefly for a real Slot filesystem event instead of
        # recursively enumerating SaveGames during normal idle play.
        $saveEvent = $null
        if ($null -ne $slotWatcher) {
            try { $saveEvent = $slotWatcher.WaitForChanged([IO.WatcherChangeTypes]::All, 200) } catch { $saveEvent = $null }
        } else {
            Start-Sleep -Milliseconds 200
        }

        # v1.18.20: chest interaction is latency-sensitive. Drain it before any save/profile
        # reconciliation work so a simultaneous Slot write cannot delay the strong Actor path.
        Drain-ActorChestEvents
        Service-ActorStrongCompletionGuard

        Consume-Runtime161BurstRequest
        Service-Runtime161Burst 'main-loop'

        $saveSignal = $false
        if ($null -ne $saveEvent -and -not $saveEvent.TimedOut) {
            $saveSignal = $true
            Log ('Slot filesystem event: ' + $saveEvent.ChangeType + '; name=' + $saveEvent.Name)
        }

        # Bounded 2-second fallback: safety net for a coalesced/missed filesystem event.
        # FileSystemWatcher remains the immediate normal trigger path.
        $nowForFingerprint = [DateTime]::UtcNow
        if (($nowForFingerprint - $lastFingerprintCheckUtc).TotalMilliseconds -ge 2000) {
            $lastFingerprintCheckUtc = $nowForFingerprint
            $fingerprint = Get-SaveFingerprint
            if ($fingerprint -ne $lastFingerprint) {
                $lastFingerprint = $fingerprint
                $saveSignal = $true
                Log '2s fallback detected Slot fingerprint change.'
            }
        }

        if ($saveSignal) {
            $lastChangeUtc = [DateTime]::UtcNow
            if(-not $pending -or $pendingReason -ne 'reload'){$pendingReason = 'save'}
            $pending = $true
            Log 'Detected Slot save-file change; fast debounce started.'
        }

        $reloadRequests=@(Take-RadarEventQueue $saveReloadRequestPath)
        if($reloadRequests.Count -gt 0){
            $pending=$true;$pendingReason='reload';$lastChangeUtc=[DateTime]::UtcNow
            Log ('Queued reload adopted by the live synchronizer: '+$reloadRequests[-1])
        }

        # v1.18.13: a reload worker can request a one-shot reset of the five
        # runtime-derived completion classes. The request remains on disk until the
        # verified MnMRadar node vector is available, so map transitions cannot lose it.
        Consume-RuntimeCompletionResetRequest
        Service-StartupStateRestore

        # v1.18.16d: the five 161-node classes are runtime-authoritative.  progress.txt
        # is intentionally purged at a real save-generation boundary and therefore cannot
        # reconstruct an already-partially-completed save.  Sample MnMRadar's done bytes
        # directly during bounded post-load convergence instead of rewriting labels from
        # the incomplete progress file.
        if ($script:postLoadCountRefreshRemaining -gt 0 -and
            [DateTime]::UtcNow -ge $script:postLoadCountRefreshNextUtc) {
            $step = 6 - $script:postLoadCountRefreshRemaining
            Log ('Post-load runtime 161-count convergence sample #' + $step)
            Sync-RuntimeTransientCompletionCountLabels ('post-load-runtime161-' + $step) | Out-Null
            Sync-RuntimeAreaQuestCountLabel ('post-load-convergence-' + $step)
            $script:postLoadCountRefreshRemaining--
            if ($script:postLoadCountRefreshRemaining -gt 0) {
                $delays = @(150,250,400,700)
                $idx = [Math]::Min($step-1,$delays.Count-1)
                $script:postLoadCountRefreshNextUtc = [DateTime]::UtcNow.AddMilliseconds($delays[$idx])
            } else {
                $script:postLoadCountRefreshNextUtc = [DateTime]::MinValue
            }
        }

        # v1.18.31: adaptive safety refresh. Real completion changes are already event-driven
        # (Actor queue, progress.txt, WCX burst, save watcher). The full ~1 MB MnMRadar node-vector
        # snapshot is therefore only a 3s safety net in steady play, while transitions keep the
        # existing bounded 250 ms burst. Native chest sidecar reads remain cheap and happen here.
        $runtimeCountNow = [DateTime]::UtcNow
        if (($runtimeCountNow - $script:lastRuntimeTransientCountPollUtc).TotalMilliseconds -ge $script:steadyRuntimeCountPollMs) {
            $script:lastRuntimeTransientCountPollUtc = $runtimeCountNow
            Sync-RuntimeTransientCompletionCountLabels 'steady-adaptive-runtime161' | Out-Null
            Sync-NativeWorldCompleteChestCountLabel 'steady-native-worldcomplete' | Out-Null
        }

        # v1.18.7: event-driven actor-state bridge. No UObject polling is done here;
        # this is a tiny file drain only when the Lua interaction hook emitted evidence.
        Drain-ActorChestEvents
        Service-ActorStrongCompletionGuard

        # v1.18.33: exact native DynamicQuest area-completion queue.
        # Queue drain is event-only; two bounded post-event reassertions prevent a stale
        # in-flight scan from reviving the just-completed task.
        Drain-AreaQuestEvents
        Service-ExactAreaReassert

        # v1.18.2: bounded retry for save-confirmed IDs that arrived before
        # main_original.dll/node-vector visibility. This runs at most once per second
        # and is a no-op when the queue is empty.
        $retryNow = [DateTime]::UtcNow
        if ($script:pendingHideIds.Count -gt 0 -and
            ($retryNow - $script:lastPendingHideRetryUtc).TotalMilliseconds -ge 1000) {
            $script:lastPendingHideRetryUtc = $retryNow
            Log ('Retrying queued runtime hide IDs: ' + ($script:pendingHideIds.Keys -join ','))
            Flush-PendingHideIds
        }

        # v1.18.16: cheap fail-safe only.  The numerator comes from save-reconciled
        # progress.txt (plus exact completion events), never from the runtime done byte.
        # This prevents first-load/travel state from overwriting the authoritative count.
        $areaNow = [DateTime]::UtcNow
        if (($areaNow - $script:lastRuntimeAreaRefreshUtc).TotalMilliseconds -ge 5000) {
            $script:lastRuntimeAreaRefreshUtc = $areaNow
            Sync-RuntimeAreaQuestCountLabel 'runtime-5s'
        }

        # MnMRadar updates progress.txt immediately for its own completion classes
        # (fly/mole/wave/platform/slider). These events do not always coincide with a
        # Slot DB write, so watch progress.txt independently. 0.5a refreshes only
        # completion labels for this path and does not decrypt/query the save.
        $progressPollNow = [DateTime]::UtcNow
        if (($progressPollNow - $script:lastProgressFingerprintPollUtc).TotalMilliseconds -ge $script:progressFingerprintPollMs) {
            $script:lastProgressFingerprintPollUtc = $progressPollNow
            $progressFingerprint = Get-MnMProgressFingerprint
            if ($progressFingerprint -ne $lastProgressFingerprint) {
                $lastProgressFingerprint = $progressFingerprint
                $lastChangeUtc = $progressPollNow
                $saveAlreadyPending = ($pending -and $pendingReason -in @('save','reload'))
                $pending = $true
                if (-not $saveAlreadyPending) { $pendingReason = 'mnm-progress' }
                Log ('Detected MnMRadar progress.txt change; queued reason=' + $pendingReason)
            }
        }

        # 0.5a: save changes use a short quiet window; progress-only changes need
        # no SQL/save decrypt at all and can refresh almost immediately.
        $quietMs = 120
        if ($pendingReason -in @('save','reload')) { $quietMs = 180 }
        if ($pending -and
            ([DateTime]::UtcNow - $lastChangeUtc).TotalMilliseconds -ge $quietMs) {
            $pending = $false
            Log ('Completion/save sync dispatch. reason=' + $pendingReason + '; quietMs=' + $quietMs)
            $syncOk=Run-LiveSync $pendingReason
            if(-not $syncOk){
                $pending=$true;$lastChangeUtc=[DateTime]::UtcNow.AddSeconds(2)
                Log 'Sync failed; trigger retained for bounded retry.'
                continue
            }
            # Reload priority belongs only to the request just completed.
            # A later filesystem event starts a normal save pass; new reload requests
            # remain queued on disk and will be adopted by the next loop.
            $pendingReason = 'save'
            # Refresh both baselines. The helper may update compatibility progress.txt
            # itself; taking the post-sync state prevents a self-trigger loop.
            $lastFingerprint = Get-SaveFingerprint
            $lastProgressFingerprint = Get-MnMProgressFingerprint
        }
    }

    Log 'Game process exited; live chest watcher exits.'
}
catch {
    Log ('FATAL watcher error: ' + $_.Exception.Message)
}
finally {
    if ($null -ne $slotWatcher) { try { $slotWatcher.Dispose() } catch { } }
    if ($processHandle -ne [IntPtr]::Zero) {
        try { [void][MnMLiveNativeV3643]::CloseHandle($processHandle) } catch { }
    }
    if ($hasMutex -and $null -ne $mutex) { try { $mutex.ReleaseMutex() } catch { } }
    if ($null -ne $mutex) { try { $mutex.Dispose() } catch { } }
}
