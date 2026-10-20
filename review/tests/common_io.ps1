param([string]$CommonPath,[string]$OutputPath)
$ErrorActionPreference='Stop'
. (Resolve-Path $CommonPath)
$checks=[Collections.Generic.List[object]]::new()
function Check($name,$ok){$checks.Add(@{name=$name;passed=[bool]$ok});if(-not $ok){throw $name}}
$temp=Join-Path ([IO.Path]::GetTempPath()) ('dswr-common-'+[guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($temp)|Out-Null
try{
    $queue=Join-Path $temp 'events.queue'
    [IO.File]::WriteAllText($queue+'.drain',"old-event`n")
    [IO.File]::WriteAllText($queue,"event-appended-after-claim`n")
    $first=@(Take-RadarEventQueue $queue)
    $second=@(Take-RadarEventQueue $queue)
    Check 'atomic queue claim preserves append at original path' ($first.Count -eq 1 -and $first[0] -eq 'old-event' -and $second.Count -eq 1 -and $second[0] -eq 'event-appended-after-claim')
    [IO.File]::WriteAllText($queue+'.drain',"held-event`n")
    $lock=[IO.File]::Open($queue+'.drain',[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
    $blocked=@(Take-RadarEventQueue $queue)
    Check 'queue read sharing failure retains claimed batch' ($blocked.Count -eq 0 -and [IO.File]::Exists($queue+'.drain'))
    $lock.Dispose()
    $retried=@(Take-RadarEventQueue $queue)
    Check 'claimed batch can be retried after writer closes' ($retried.Count -eq 1 -and $retried[0] -eq 'held-event')

    Add-Type -TypeDefinition @'
public static class RadarQueueProducer {
    public static System.Threading.Tasks.Task Start(string path,int count) {
        return System.Threading.Tasks.Task.Run(()=>{
            for(int i=0;i<count;i++){
                bool done=false;
                while(!done){
                    try { System.IO.File.AppendAllText(path,i.ToString()+"\n");done=true; }
                    catch(System.IO.IOException){System.Threading.Thread.Sleep(1);}
                }
                if(i%20==0) System.Threading.Thread.Sleep(1);
            }
        });
    }
}
'@
    $producer=[RadarQueueProducer]::Start($queue,2000)
    $seen=[Collections.Generic.List[string]]::new()
    while(-not $producer.IsCompleted){foreach($line in @(Take-RadarEventQueue $queue)){$seen.Add($line)};Start-Sleep -Milliseconds 1}
    $producer.GetAwaiter().GetResult()
    for($i=0;$i -lt 3;$i++){foreach($line in @(Take-RadarEventQueue $queue)){$seen.Add($line)}}
    Check '2000 concurrent event appends are delivered once each' ($seen.Count -eq 2000 -and @($seen|Sort-Object -Unique).Count -eq 2000)

    $file=Join-Path $temp 'atomic.txt'
    Check 'atomic text initial create works' (Write-RadarTextAtomic $file 'first')
    Check 'atomic replacement works and removes temp files' ((Write-RadarTextAtomic $file 'second') -and [IO.File]::ReadAllText($file) -eq 'second' -and @(Get-ChildItem $temp -Filter '*.tmp.*').Count -eq 0)
    $scriptPath='H:\Game With Spaces\DS\Binaries\Win64\ue4ss\Mods\DSWorldRadar\dlls\sync\live_chest_watcher.ps1'
    Check 'process cleanup accepts exact quoted current script' (Test-RadarWatcherCommandLine ('powershell.exe -NoProfile -File "'+$scriptPath+'"') $scriptPath)
    Check 'process cleanup accepts case and slash variants' (Test-RadarWatcherCommandLine ('powershell.exe -File "'+$scriptPath.ToLowerInvariant().Replace('\','/')+'"') $scriptPath)
    Check 'process cleanup rejects a different installation with same filename' (-not (Test-RadarWatcherCommandLine ('powershell.exe -File "'+$scriptPath.Replace('H:\Game With Spaces','J:\Other Game')+'"') $scriptPath))
    Check 'process cleanup rejects mentions outside the File argument' (-not (Test-RadarWatcherCommandLine ('powershell.exe -Command "echo '+$scriptPath+'"') $scriptPath))
    $log=Join-Path $temp 'bounded.log'
    [IO.File]::WriteAllText($log,('x'*(4MB+1)))
    Write-RadarLog $log 'new session log'
    Check 'own runtime log rotates at four MiB with one previous file' ([IO.File]::Exists($log+'.previous') -and (Get-Item $log).Length -lt 1KB -and [IO.File]::ReadAllText($log).Contains('new session log'))
    $root=Join-Path $temp 'dlls/sync';[IO.Directory]::CreateDirectory((Join-Path $root 'cache'))|Out-Null
    $watcherPath=Join-Path $root 'live_chest_watcher.ps1';[IO.File]::WriteAllText($watcherPath,'test-watcher')
    $nodesPath=Join-Path (Split-Path -Parent $root) 'mnm_nodes.csv';[IO.File]::WriteAllText($nodesPath,'test-catalog')
    $catalogHash=(Get-FileHash $nodesPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $body=@('DSWR_STATE_V1',('revision='+('a'*32)),('catalog_sha256='+$catalogHash),('slot_b64='+[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes('slot-a.db'))),'chests=DSC_11230106','areas=')-join "`n"
    [IO.File]::WriteAllText((Join-Path $root 'cache/authority_state.v1.txt'),$body)
    $readyPath=Join-Path $root 'bootstrap_ready.json'
    $ready=@{version='1.0.6';game_pid=42;watcher_pid=900;watcher_sha256=(Get-FileHash $watcherPath -Algorithm SHA256).Hash.ToLowerInvariant()}
    [IO.File]::WriteAllText($readyPath,($ready|ConvertTo-Json -Compress))
    $script:fakeGameStart=[DateTime]::UtcNow.AddMinutes(-1);$script:fakeWatcherAlive=$true
    function Get-Process {
        param($Name,$Id,$ErrorAction)
        if($Name -eq 'DSClient-Win64-Shipping'){return [pscustomobject]@{Id=42;StartTime=$script:fakeGameStart;ProcessName='DSClient-Win64-Shipping'}}
        if($Id -eq 900 -and $script:fakeWatcherAlive){return [pscustomobject]@{Id=900;ProcessName='powershell'}}
    }
    Check 'bootstrap launch health requires matching process hash and complete snapshot' (Test-RadarBootstrapReady $root)
    $script:fakeWatcherAlive=$false
    Check 'dead live watcher cannot be reported healthy' (-not (Test-RadarBootstrapReady $root))
    $script:fakeWatcherAlive=$true
    [IO.File]::WriteAllText((Join-Path $root 'cache/authority_state.v1.txt'),'DSWR_STATE_V1')
    Check 'fresh incomplete authority cannot be reported healthy' (-not (Test-RadarBootstrapReady $root))
    [IO.File]::WriteAllText((Join-Path $root 'cache/authority_state.v1.txt'),$body)
    $ready.game_pid=43;[IO.File]::WriteAllText($readyPath,($ready|ConvertTo-Json -Compress))
    Check 'previous game process launch marker is rejected' (-not (Test-RadarBootstrapReady $root))
    $ready.game_pid=42;[IO.File]::WriteAllText($readyPath,($ready|ConvertTo-Json -Compress))
    [IO.File]::WriteAllText($watcherPath,'updated-watcher')
    Check 'outdated live watcher launch marker is rejected' (-not (Test-RadarBootstrapReady $root))
    @{passed=$true;checks=$checks;runtime=$PSVersionTable.PSVersion.ToString();windows_execution=$false}|ConvertTo-Json -Depth 5|Set-Content -LiteralPath $OutputPath -Encoding utf8
    Write-Output ('PASS: '+$checks.Count+' shared IO checks; 2000 concurrent events')
}finally{Remove-Item -LiteralPath $temp -Recurse -Force}
