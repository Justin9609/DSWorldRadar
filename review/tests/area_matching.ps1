param(
    [Parameter(Mandatory=$true)][string]$WatcherPath,
    [Parameter(Mandatory=$true)][string]$IdsPath,
    [Parameter(Mandatory=$true)][string]$OutputPath,
    [switch]$ExpectOldBug
)
$ErrorActionPreference='Stop'
$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile($WatcherPath,[ref]$tokens,[ref]$errors)
if($errors.Count){throw ($errors|Out-String)}
foreach($name in @('Read-NodeId','Build-AreaOffsetCache','Set-RuntimeAreaStateFromIdSet','Consume-RuntimeCompletionResetRequest')){
    $found=@($ast.FindAll({param($a)$a -is [Management.Automation.Language.FunctionDefinitionAst] -and $a.Name -eq $name},$true))
    if($found.Count -ne 1){throw ('Function missing: '+$name)}
    . ([scriptblock]::Create($found[0].Extent.Text))
}
$script:checks=New-Object System.Collections.Generic.List[object]
$script:trace=New-Object System.Collections.Generic.List[string]
function Check([string]$name,[bool]$ok){$script:checks.Add(@{name=$name;passed=$ok});if(-not $ok){throw ('FAILED: '+$name)}}
function Log([string]$message){$script:trace.Add($message)}
function Get-MnMModuleInfo{return @{Test=$true}}
function Get-NodeVector($module){return @{Start=[long]4096;Count=$script:rows.Count;Bytes=$script:memory.Clone()}}
function Read-RemoteBytes {throw 'All synthetic numeric quest IDs use real inline UTF-16 strings'}
function Write-RemoteByte([long]$address,[byte]$value){
    if($address -eq $script:failAddress){return $false}
    $script:memory[[int]($address-4096)]=$value;return $true
}
function Get-AuthoritativeProfileSlot{return 'slot-b.db'}
function Get-SaveProfileKey($slot){return 'test-profile-key'}
function Reapply-CurrentSaveChestSnapshot{return $true}
function Read-FastAreaSnapshotMap{return $script:desired}
function Reset-ActorCompletionSessionCache{}
function Capture-BoundaryRuntimeProfiles{return $true}
function Apply-TransientProfileIfValid{throw 'Unexpected runtime profile fallback'}
function Apply-StaticSliderProfileIfValid{throw 'Unexpected slider profile fallback'}
function Reset-ExactAreaCompletionSessionCache{}
function Sync-ImmediateChestCategoryCounts{return $true}
function Reset-ProfileStability{}
function Reset-StaticSliderProfileStability{}
function Arm-Runtime161Burst{}
function Reapply-ExactAreaCompletions{}

$script:game=@{HasExited=$false}
$script:failAddress=0L
$script:areaQuestIds=@{};$nodeCoords=@{}
$catalog=@(Import-Csv -LiteralPath $IdsPath | Where-Object {$_.kind -eq 'area_quests'})
Check 'production catalog has 147 area quests' ($catalog.Count -eq 147)
foreach($row in $catalog){
    $script:areaQuestIds[[string]$row.id]=$true
    $nodeCoords[[string]$row.id]=@([double]$row.x,[double]$row.y,[double]$row.z)
}
Check 'actual distinct quest IDs share the same coordinates' (($nodeCoords['1110052'] -join ',') -ceq ($nodeCoords['1110061'] -join ','))
$script:rows=@($catalog)+@([pscustomobject]@{id='9999999';x=31963;y=105378;z=921})
$script:memory=New-Object byte[] ($script:rows.Count*0x70)
$script:offsets=@{}
for($i=0;$i -lt $script:rows.Count;$i++){
    $r=$script:rows[$i];$offset=$i*0x70
    [Text.Encoding]::Unicode.GetBytes([string]$r.id).CopyTo($script:memory,$offset)
    [BitConverter]::GetBytes([UInt64]([string]$r.id).Length).CopyTo($script:memory,$offset+0x10)
    [BitConverter]::GetBytes([UInt64]7).CopyTo($script:memory,$offset+0x18)
    [BitConverter]::GetBytes([double]$r.x).CopyTo($script:memory,$offset+0x40)
    [BitConverter]::GetBytes([double]$r.y).CopyTo($script:memory,$offset+0x48)
    [BitConverter]::GetBytes([double]$r.z).CopyTo($script:memory,$offset+0x50)
    $script:offsets[[string]$r.id]=$offset
    $script:memory[$offset+0x58]=1
}
$script:memory[$script:offsets['9999999']+0x58]=90
$script:areaOffsetCache=@{};$script:areaOffsetCacheVectorStart=0L;$script:areaOffsetCacheVectorCount=0
$script:desired=$script:areaQuestIds.Clone()
Build-AreaOffsetCache (Get-NodeVector $null)
$temp=Join-Path ([IO.Path]::GetTempPath()) ('dswr-area-'+[guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($temp)|Out-Null
$script:runtimeResetRequestPath=Join-Path $temp 'runtime-reset.flag'
function Request-Boundary {
    $script:saveTransitionPending=$true
    $script:lastKnownFastSlot='slot-a.db'
    $script:preparedBoundaryRequest=''
    $script:boundaryRestoreRetryAt=[DateTime]::MinValue
    $script:authoritySnapshot=@{Slot='slot-b.db'}
    $script:actorGenerationPreReset=$false
    $script:nativeGenerationPreInvalidated=$false
    [IO.File]::WriteAllText($script:runtimeResetRequestPath,'time=test;generation_reset=1')
    Consume-RuntimeCompletionResetRequest
}
try{
    if($ExpectOldBug){
        Check '1.0.4 reproduces the logged 146-of-147 cache' ($script:areaOffsetCache.Count -eq 146)
        Request-Boundary
        Check '1.0.4 leaves transition pending despite all 147 nodes being present' ((Test-Path -LiteralPath $script:runtimeResetRequestPath) -and $script:saveTransitionPending)
    }else{
        Check 'all 147 production quest IDs are mapped' ($script:areaOffsetCache.Count -eq 147)
        Check 'coincident quests retain distinct runtime offsets' ($script:areaOffsetCache['1110052'] -ne $script:areaOffsetCache['1110061'])
        Check 'same-coordinate unrelated node is not accepted' (-not $script:areaOffsetCache.ContainsKey('9999999'))
        $script:desired.Remove('1110052')
        $ok=Set-RuntimeAreaStateFromIdSet $script:desired 'coincident-A-incomplete'
        Check 'first coincident quest can be incomplete independently' ($ok -and $script:memory[$script:offsets['1110052']+0x58] -eq 0 -and $script:memory[$script:offsets['1110061']+0x58] -eq 1)
        $script:desired['1110052']=$true;$script:desired.Remove('1110061')
        $ok=Set-RuntimeAreaStateFromIdSet $script:desired 'coincident-B-incomplete'
        Check 'second coincident quest can be incomplete independently' ($ok -and $script:memory[$script:offsets['1110052']+0x58] -eq 1 -and $script:memory[$script:offsets['1110061']+0x58] -eq 0)
        Request-Boundary
        Check 'actual boundary consumer commits with all 147 nodes mapped' (-not (Test-Path -LiteralPath $script:runtimeResetRequestPath) -and -not $script:saveTransitionPending -and $script:profileGenerationReadySlot -eq 'slot-b.db')
        $offset=$script:offsets['1110052']
        [Text.Encoding]::Unicode.GetBytes('7777777').CopyTo($script:memory,$offset)
        $script:areaOffsetCache.Clear()
        Request-Boundary
        Check 'truly missing required node still retains the boundary request' ((Test-Path -LiteralPath $script:runtimeResetRequestPath) -and $script:saveTransitionPending)
        Check 'incomplete cache reports the exact missing quest ID' (@($script:trace | Where-Object {$_ -like '*missingIds=1110052*'}).Count -gt 0)
        [Text.Encoding]::Unicode.GetBytes('1110052').CopyTo($script:memory,$offset)
        $script:boundaryRestoreRetryAt=[DateTime]::MinValue
        Consume-RuntimeCompletionResetRequest
        Check 'missing node becoming readable allows retry to commit' (-not (Test-Path -LiteralPath $script:runtimeResetRequestPath) -and -not $script:saveTransitionPending)
        $script:desired=$script:areaQuestIds.Clone()
        $script:failAddress=[long](4096+$script:offsets['1110061']+0x58)
        Request-Boundary
        Check 'remote write failure is not mistaken for completion' ((Test-Path -LiteralPath $script:runtimeResetRequestPath) -and $script:saveTransitionPending)
        $script:failAddress=0L;$script:boundaryRestoreRetryAt=[DateTime]::MinValue
        Consume-RuntimeCompletionResetRequest
        Check 'failed memory write is retried successfully' (-not (Test-Path -LiteralPath $script:runtimeResetRequestPath) -and $script:memory[$script:offsets['1110061']+0x58] -eq 1)
        $script:desired.Remove('1110052')
        $script:exactAreaCompletedIds=@{'1110052'=$true}
        $ok=Set-RuntimeAreaStateFromIdSet $script:desired 'new-session-area-event'
        Check 'current-session area completion survives an older save snapshot' ($ok -and $script:memory[$script:offsets['1110052']+0x58] -eq 1 -and -not $script:desired.ContainsKey('1110052'))
        $script:exactAreaCompletedIds.Clear()
        $ok=Set-RuntimeAreaStateFromIdSet $script:desired 'next-session-no-witness'
        Check 'clearing area session evidence restores destination save state' ($ok -and $script:memory[$script:offsets['1110052']+0x58] -eq 0)
        Check 'unrelated same-coordinate done byte is untouched throughout' ($script:memory[$script:offsets['9999999']+0x58] -eq 90)
    }
    @{passed=$true;checks=$script:checks;trace=$script:trace;source_sha256=(Get-FileHash -LiteralPath $WatcherPath -Algorithm SHA256).Hash.ToLowerInvariant();catalog_sha256=(Get-FileHash -LiteralPath $IdsPath -Algorithm SHA256).Hash.ToLowerInvariant();baseline_bug_expected=[bool]$ExpectOldBug;runtime=$PSVersionTable.PSVersion.ToString();game_runtime_executed=$false}|ConvertTo-Json -Depth 6|Set-Content -LiteralPath $OutputPath -Encoding utf8
    Write-Output ('PASS: '+$script:checks.Count+'; baseline='+[bool]$ExpectOldBug)
}finally{Remove-Item -LiteralPath $temp -Recurse -Force}
