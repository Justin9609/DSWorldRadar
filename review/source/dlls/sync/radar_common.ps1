# DSWorldRadar shared IO. Windows PowerShell 5.1 compatible; definitions only.

function Get-RadarInstallKey([string]$root) {
    $sha=[Security.Cryptography.SHA256]::Create()
    try{
        $hash=$sha.ComputeHash([Text.Encoding]::UTF8.GetBytes([IO.Path]::GetFullPath($root).ToLowerInvariant()))
        return ((-join ($hash|ForEach-Object {$_.ToString('x2')})).Substring(0,24))
    }finally{$sha.Dispose()}
}

function Test-RadarBootstrapReady([string]$root) {
    try{
        $ready=Join-Path $root 'bootstrap_ready.json'
        if(-not [IO.File]::Exists($ready)){return $false}
        $state=[IO.File]::ReadAllText($ready)|ConvertFrom-Json -ErrorAction Stop
        if([string]$state.version -cne '1.0.6'){return $false}
        $game=Get-Process -Name 'DSClient-Win64-Shipping' -ErrorAction SilentlyContinue|Sort-Object StartTime -Descending|Select-Object -First 1
        if($null -eq $game -or [int]$state.game_pid -ne $game.Id){return $false}
        if((Get-Item -LiteralPath $ready).LastWriteTimeUtc -lt $game.StartTime.ToUniversalTime()){return $false}
        $watcher=Get-Process -Id ([int]$state.watcher_pid) -ErrorAction SilentlyContinue
        if($null -eq $watcher -or $watcher.ProcessName -notin @('powershell','pwsh')){return $false}
        $expected=(Get-FileHash -LiteralPath (Join-Path $root 'live_chest_watcher.ps1') -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant()
        if([string]$state.watcher_sha256 -cne $expected){return $false}
        $catalog=(Get-FileHash -LiteralPath (Join-Path (Split-Path -Parent $root) 'mnm_nodes.csv') -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant()
        return $null -ne (Read-RadarAuthoritySnapshot (Join-Path $root 'cache/authority_state.v1.txt') $catalog)
    }catch{return $false}
}

function Write-RadarTextAtomic([string]$path,[string]$text) {
    $temp=$path+'.tmp.'+[guid]::NewGuid().ToString('N')
    try {
        $parent=Split-Path -Parent $path
        if(-not (Test-Path -LiteralPath $parent)){[void][IO.Directory]::CreateDirectory($parent)}
        [IO.File]::WriteAllText($temp,$text,(New-Object Text.UTF8Encoding($false)))
        if([IO.File]::Exists($path)){[IO.File]::Replace($temp,$path,[NullString]::Value)}
        else{[IO.File]::Move($temp,$path)}
        return $true
    } catch {
        return $false
    } finally {
        if([IO.File]::Exists($temp)){try{[IO.File]::Delete($temp)}catch{}}
    }
}

function Read-RadarAuthoritySnapshot([string]$path,[string]$catalogHash) {
    try {
        if([string]::IsNullOrWhiteSpace($catalogHash) -or -not [IO.File]::Exists($path)){return $null}
        $lines=[IO.File]::ReadAllLines($path,[Text.Encoding]::UTF8)
        if($lines.Count -ne 6 -or $lines[0] -cne 'DSWR_STATE_V1'){return $null}
        $map=@{}
        foreach($line in $lines[1..5]){
            $eq=$line.IndexOf('=');if($eq -le 0){return $null}
            $key=$line.Substring(0,$eq)
            if($map.ContainsKey($key)){return $null}
            $map[$key]=$line.Substring($eq+1)
        }
        foreach($key in @('revision','catalog_sha256','slot_b64','chests','areas')){if(-not $map.ContainsKey($key)){return $null}}
        if($map['catalog_sha256'] -cne $catalogHash -or $map['revision'] -notmatch '^[a-f0-9]{32}$'){return $null}
        $slot=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($map['slot_b64'])).Trim().ToLowerInvariant()
        if([string]::IsNullOrWhiteSpace($slot) -or $slot -match '[\r\n]'){return $null}
        $chests=@{};$areas=@{}
        if($map['chests'].Length){foreach($id in $map['chests'].Split(',')){
            if($id -notmatch '^DSC_[0-9]+$' -or $chests.ContainsKey($id)){return $null};$chests[$id]=$true
        }}
        if($map['areas'].Length){foreach($id in $map['areas'].Split(',')){
            if($id -notmatch '^[0-9]+$' -or $areas.ContainsKey($id)){return $null};$areas[$id]=$true
        }}
        return @{Slot=$slot;Chests=$chests;Areas=$areas;Revision=$map['revision'];CatalogHash=$map['catalog_sha256']}
    } catch {return $null}
}

function Take-RadarEventQueue([string]$path) {
    # Rename separates the producer's next append from the batch being consumed.
    # An exclusive open ensures a producer still writing to a renamed handle has
    # finished before the batch is read. Failed claims/reads remain for retry.
    $claimed=$path+'.drain'
    $stream=$null;$reader=$null
    try {
        if(-not [IO.File]::Exists($claimed)){
            if(-not [IO.File]::Exists($path)){return @()}
            [IO.File]::Move($path,$claimed)
        }
        $stream=New-Object IO.FileStream($claimed,[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
        $reader=New-Object IO.StreamReader($stream,[Text.Encoding]::UTF8,$true,4096,$true)
        $lines=New-Object Collections.Generic.List[string]
        while(-not $reader.EndOfStream){$lines.Add($reader.ReadLine())}
        $reader.Dispose();$reader=$null
        $stream.SetLength(0);$stream.Dispose();$stream=$null
        [IO.File]::Delete($claimed)
        return $lines.ToArray()
    } catch {return @()}
    finally {
        if($null -ne $reader){$reader.Dispose()}
        if($null -ne $stream){$stream.Dispose()}
    }
}

function Write-RadarLog([string]$path,[string]$text) {
    try {
        if($null -eq $script:radarLogRotationChecks){$script:radarLogRotationChecks=@{}}
        $now=[DateTime]::UtcNow
        if(-not $script:radarLogRotationChecks.ContainsKey($path) -or ($now-$script:radarLogRotationChecks[$path]).TotalSeconds -ge 30){
            $script:radarLogRotationChecks[$path]=$now
            if([IO.File]::Exists($path) -and (Get-Item -LiteralPath $path).Length -ge (4 * 1024 * 1024)){
                $old=$path+'.previous'
                if([IO.File]::Exists($old)){[IO.File]::Delete($old)}
                [IO.File]::Move($path,$old)
            }
        }
        Add-Content -LiteralPath $path -Value ('{0:yyyy-MM-dd HH:mm:ss.fff} {1}' -f (Get-Date),$text) -Encoding UTF8 -ErrorAction Stop
    } catch {}
}

function Test-RadarWatcherCommandLine([string]$commandLine,[string]$scriptPath) {
    if([string]::IsNullOrWhiteSpace($commandLine)){return $false}
    $m=[regex]::Match($commandLine,'(?i)(?:^|\s)-File\s+(?:"([^"]+)"|''([^'']+)''|(\S+))')
    if(-not $m.Success){return $false}
    $candidate=if($m.Groups[1].Success){$m.Groups[1].Value}elseif($m.Groups[2].Success){$m.Groups[2].Value}else{$m.Groups[3].Value}
    return $candidate.Replace('/','\').TrimEnd('\') -ieq $scriptPath.Replace('/','\').TrimEnd('\')
}
