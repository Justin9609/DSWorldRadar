param([string]$WatcherPath,[string]$OutputPath,[switch]$ExpectOldBug)
$ErrorActionPreference='Stop'
. (Join-Path (Split-Path -Parent (Resolve-Path $WatcherPath)) 'radar_common.ps1')
$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile($WatcherPath,[ref]$tokens,[ref]$errors)
if($errors.Count){throw ($errors|Out-String)}
function Select-IfCode([string]$condition,[string]$bodyMarker){
    $found=@($ast.FindAll({param($a)
        $a -is [Management.Automation.Language.IfStatementAst] -and
        (($condition -and $a.Clauses[0].Item1.Extent.Text -ceq $condition) -or
         ($bodyMarker -and $a.Clauses[0].Item2.Extent.Text.Contains($bodyMarker)))
    },$true))
    if($found.Count -ne 1){throw ('Ambiguous main-loop branch: '+$condition+' '+$bodyMarker)}
    return $found[0].Extent.Text
}
$saveCode=[scriptblock]::Create((Select-IfCode '$saveSignal' ''))
$dispatchCode=[scriptblock]::Create(('foreach($testFrame in 1){'+(Select-IfCode '' 'Completion/save sync dispatch.')+'}'))
$progressCode=[scriptblock]::Create((Select-IfCode '$progressFingerprint -ne $lastProgressFingerprint' ''))
$reloadCode=[scriptblock]::Create((Select-IfCode '$reloadRequests.Count -gt 0' ''))
$script:checks=New-Object Collections.Generic.List[object]
$script:calls=New-Object Collections.Generic.List[string]
$script:messages=New-Object Collections.Generic.List[string]
function Check($name,$ok){$script:checks.Add(@{name=$name;passed=[bool]$ok});if(-not $ok){throw $name}}
function Log($message){$script:messages.Add($message)}
function Get-SaveFingerprint{return 'after-save'}
function Get-MnMProgressFingerprint{return 'after-progress'}
function Run-LiveSync([string]$reason){
    $script:calls.Add($reason)
    if($script:queueDuringRun){
        if(-not (Write-RadarTextAtomic $script:requestPath 'reason=second-real-reload')){throw 'Queue fixture failed'}
    }
    return $script:syncResult
}
$temp=Join-Path ([IO.Path]::GetTempPath()) ('dswr-dispatch-'+[guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($temp)|Out-Null
$script:requestPath=Join-Path $temp 'reload.request'
$quietMs=180;$script:syncResult=$true;$script:queueDuringRun=$false
$pending=$true;$pendingReason='reload';$lastChangeUtc=[DateTime]::UtcNow.AddSeconds(-10)
$lastFingerprint='before-save';$lastProgressFingerprint='before-progress'
try{
    . $dispatchCode
    if($ExpectOldBug){
        Check 'old completed reload leaves stale reload reason' (-not $pending -and $pendingReason -eq 'reload')
        $saveSignal=$true;. $saveCode
        Check 'old next ordinary save is incorrectly promoted to reload' ($pending -and $pendingReason -eq 'reload')
        $lastChangeUtc=[DateTime]::UtcNow.AddSeconds(-10);. $dispatchCode
        Check 'old helper actually receives a second reload without a new request' ($script:calls.Count -eq 2 -and $script:calls[1] -eq 'reload')
    }else{
        Check 'completed reload clears priority while consuming the current request' (-not $pending -and $pendingReason -eq 'save' -and $script:calls[0] -eq 'reload')
        $saveSignal=$true;. $saveCode
        $lastChangeUtc=[DateTime]::UtcNow.AddSeconds(-10);. $dispatchCode
        Check 'ordinary save after reload invokes normal save mode' ($script:calls[1] -eq 'save' -and -not $pending)

        $pending=$false;$pendingReason='reload';. $saveCode
        Check 'idle stale reason cannot override a new filesystem trigger' ($pending -and $pendingReason -eq 'save')
        $pending=$true;$pendingReason='reload';. $saveCode
        Check 'save event cannot downgrade a genuinely pending reload' ($pendingReason -eq 'reload')
        $progressFingerprint='new-progress';$lastProgressFingerprint='old-progress';. $progressCode
        Check 'progress event cannot downgrade a genuinely pending reload' ($pendingReason -eq 'reload')

        $script:syncResult=$false;$lastChangeUtc=[DateTime]::UtcNow.AddSeconds(-10)
        $lastFingerprint='before-failed-save';$lastProgressFingerprint='before-failed-progress'
        . $dispatchCode
        Check 'failed reload retains its reason and bounded retry' ($pending -and $pendingReason -eq 'reload' -and $lastChangeUtc -gt [DateTime]::UtcNow)
        Check 'failed helper cannot advance either trigger baseline' ($lastFingerprint -eq 'before-failed-save' -and $lastProgressFingerprint -eq 'before-failed-progress')
        . $saveCode
        Check 'new save while retrying still preserves reload priority' ($pendingReason -eq 'reload')
        $script:syncResult=$true;$lastChangeUtc=[DateTime]::UtcNow.AddSeconds(-10);. $dispatchCode
        Check 'successful retry clears reload priority and updates baselines' (-not $pending -and $pendingReason -eq 'save' -and $lastFingerprint -eq 'after-save')

        $pending=$true;$pendingReason='reload';$lastChangeUtc=[DateTime]::UtcNow.AddSeconds(-10)
        $script:queueDuringRun=$true;. $dispatchCode;$script:queueDuringRun=$false
        Check 'new reload arriving during synchronization remains on disk' (-not $pending -and (Test-Path -LiteralPath $script:requestPath))
        $reloadRequests=@(Take-RadarEventQueue $script:requestPath);. $reloadCode
        Check 'next iteration adopts the new reload after the earlier one completed' ($pending -and $pendingReason -eq 'reload' -and $reloadRequests[0] -eq 'reason=second-real-reload')

        $pending=$true;$pendingReason='mnm-progress';. $saveCode
        Check 'save confirmation supersedes pending progress-only work' ($pendingReason -eq 'save')
        $pending=$false;$pendingReason='save';$progressFingerprint='progress-b';$lastProgressFingerprint='progress-a';. $progressCode
        $lastChangeUtc=[DateTime]::UtcNow.AddSeconds(-10);. $dispatchCode
        Check 'standalone progress refresh remains progress-only and then returns idle' ($script:calls[$script:calls.Count-1] -eq 'mnm-progress' -and -not $pending -and $pendingReason -eq 'save')
    }
    @{passed=$true;baseline_bug_expected=[bool]$ExpectOldBug;checks=$script:checks;calls=$script:calls;trace=$script:messages;source_sha256=(Get-FileHash -LiteralPath $WatcherPath -Algorithm SHA256).Hash.ToLowerInvariant();runtime=$PSVersionTable.PSVersion.ToString();game_runtime_executed=$false}|ConvertTo-Json -Depth 6|Set-Content -LiteralPath $OutputPath -Encoding utf8
    Write-Output ('PASS: '+$script:checks.Count+' dispatch checks; baseline='+[bool]$ExpectOldBug)
}finally{Remove-Item -LiteralPath $temp -Recurse -Force}
