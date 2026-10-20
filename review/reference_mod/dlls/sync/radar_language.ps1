# DSWorldRadar v1.0 language selection. Windows PowerShell 5.1 compatible.
# Definitions only: dot-sourced by bootstrap before the native language file is read.

function Normalize-RadarLanguage([string]$raw) {
    if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
    $v = $raw.Trim().Trim('"').Trim("'").ToLowerInvariant().Replace('_', '-')
    $v = $v -replace '^.*::', ''
    switch ($v) {
        'koreana' { return 'ko' }
        'korean' { return 'ko' }
        'english' { return 'en' }
        'japanese' { return 'ja' }
        'schinese' { return 'zh-cn' }
        'simplified chinese' { return 'zh-cn' }
        'simplified-chinese' { return 'zh-cn' }
        'chinese-simplified' { return 'zh-cn' }
        'cn' { return 'zh-cn' }
        'tchinese' { return 'zh-tw' }
        'traditional chinese' { return 'zh-tw' }
        'traditional-chinese' { return 'zh-tw' }
        'chinese-traditional' { return 'zh-tw' }
        'german' { return 'de' }
        'french' { return 'fr' }
        'spanish' { return 'es' }
        'latam' { return 'es' }
        'brazilian' { return 'pt-br' }
        'portuguese' { return 'pt-br' }
        'russian' { return 'ru' }
        'thai' { return 'th' }
    }
    # Explicit Chinese script takes precedence over a regional suffix.
    if ($v -match '^zh-hans(?:-[a-z0-9]+)*$') { return 'zh-cn' }
    if ($v -match '^zh-hant(?:-[a-z0-9]+)*$') { return 'zh-tw' }
    if ($v -match '^zh-(?:tw|hk|mo)(?:-[a-z0-9]+)*$') { return 'zh-tw' }
    if ($v -match '^zh(?:-(?:cn|sg))?$') { return 'zh-cn' }
    if ($v -match '^(ko|en|ja|de|fr|es|ru|th)(?:-[a-z0-9]+)*$') {
        return $Matches[1]
    }
    # The game's supported Portuguese localization is pt_BR.
    if ($v -match '^pt(?:-[a-z0-9]+)*$') { return 'pt-br' }
    # Unknown tokens must not prevent a later, valid fallback from being tried.
    return $null
}

function Map-DragonSwordLanguageText([int]$value) {
    # Settings use the zero-based EBILanguageType order, confirmed against the
    # supplied UE4SS_ObjectDump. Do not use the one-based DS.ELanguageType table.
    switch ($value) {
        0 { return 'ko' }
        1 { return 'en' }
        2 { return 'ja' }
        3 { return 'zh-cn' }
        4 { return 'zh-tw' }
        5 { return 'de' }
        6 { return 'fr' }
        7 { return 'es' }
        8 { return 'pt-br' }
        9 { return 'ru' }
        10 { return 'th' }
        default { return $null }
    }
}

function Get-RadarConfigFiles([string]$gameRoot, [switch]$SettingsOnly) {
    foreach ($platform in @('Windows', 'WindowsClient')) {
        $dir = Join-Path $gameRoot ('DS/Saved/Config/' + $platform)
        Join-Path $dir 'GameUserSettings.ini'
        if (-not $SettingsOnly) {
            Join-Path $dir 'Engine.ini'
            Join-Path $dir 'Game.ini'
        }
    }
}

function Get-RadarIniLanguageEntries([string]$path, [string]$keys) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return }
    try {
        $text = Get-Content -LiteralPath $path -Raw -Encoding UTF8 -ErrorAction Stop
        $pattern = '(?im)^[ \t]*(' + $keys + ')[ \t]*=[ \t]*(?:"([^"\r\n]*)"|''([^''\r\n]*)''|([^;#\r\n]*?))[ \t]*(?:[;#][^\r\n]*)?\r?$'
        $entries = [regex]::Matches($text, $pattern)
        $seen = @{}
        # Unreal configuration permits repeated keys; use the last value per key.
        for ($i = $entries.Count - 1; $i -ge 0; $i--) {
            $entry = $entries[$i]
            $key = $entry.Groups[1].Value.ToLowerInvariant()
            if ($seen.ContainsKey($key)) { continue }
            $seen[$key] = $true
            $token = if ($entry.Groups[2].Success) { $entry.Groups[2].Value } elseif ($entry.Groups[3].Success) { $entry.Groups[3].Value } else { $entry.Groups[4].Value }
            [pscustomobject]@{ Key=$key; Token=$token.Trim(); Source=$path }
        }
    } catch { }
}

function Get-GameLanguageText([string]$gameRoot) {
    foreach ($cfg in (Get-RadarConfigFiles $gameRoot -SettingsOnly)) {
        foreach ($entry in (Get-RadarIniLanguageEntries $cfg 'LanguageText')) {
            $number = 0
            $language = if ([int]::TryParse($entry.Token, [ref]$number)) {
                Map-DragonSwordLanguageText $number
            } else { Normalize-RadarLanguage $entry.Token }
            if ($language) {
                return [pscustomobject]@{ Token=$entry.Token; Language=$language; Source=$entry.Source; Kind='LanguageText' }
            }
        }
    }
    return $null
}

function Get-TextualGameLanguageToken([string]$gameRoot) {
    # Saved LanguageText has priority. These sources are fallbacks only.
    try {
        $proc = Get-CimInstance Win32_Process -Filter "Name='DSClient-Win64-Shipping.exe'" -ErrorAction Stop | Select-Object -First 1
        if ($proc -and $proc.CommandLine) {
            $entries = [regex]::Matches($proc.CommandLine, '(?i)(?:^|\s)-(?:culture|language|locale)(?:=|\s+)(?:"([^"\r\n]+)"|''([^''\r\n]+)''|([^\s]+))')
            for ($i = $entries.Count - 1; $i -ge 0; $i--) {
                $entry = $entries[$i]
                $token = if ($entry.Groups[1].Success) { $entry.Groups[1].Value } elseif ($entry.Groups[2].Success) { $entry.Groups[2].Value } else { $entry.Groups[3].Value }
                $language = Normalize-RadarLanguage $token
                if ($language) { return [pscustomobject]@{ Token=$token; Language=$language; Source='game command line'; Kind='text fallback' } }
            }
        }
    } catch { }

    foreach ($cfg in (Get-RadarConfigFiles $gameRoot)) {
        foreach ($entry in (Get-RadarIniLanguageEntries $cfg 'Culture|Language|Locale|CurrentCulture|CurrentLanguage|SelectedLanguage')) {
            $language = Normalize-RadarLanguage $entry.Token
            if ($language) { return [pscustomobject]@{ Token=$entry.Token; Language=$language; Source=$entry.Source; Kind='text fallback' } }
        }
    }

    try {
        $steamApps = Split-Path -Parent (Split-Path -Parent $gameRoot)
        $manifest = Join-Path $steamApps 'appmanifest_4570720.acf'
        if (Test-Path -LiteralPath $manifest -PathType Leaf) {
            $acf = Get-Content -LiteralPath $manifest -Raw -Encoding UTF8 -ErrorAction Stop
            foreach ($entry in [regex]::Matches($acf, '(?im)"language"\s+"([^"]+)"')) {
                $token = $entry.Groups[1].Value.Trim()
                $language = Normalize-RadarLanguage $token
                if ($language) { return [pscustomobject]@{ Token=$token; Language=$language; Source=$manifest; Kind='Steam fallback' } }
            }
        }
    } catch { }
    return $null
}

function Apply-AutoRadarLanguage([string]$syncRoot) {
    $dllsRoot = Split-Path -Parent $syncRoot
    $languePath = Join-Path $dllsRoot 'langue.txt'
    $gameRoot = $dllsRoot
    for ($i = 0; $i -lt 7; $i++) { $gameRoot = Split-Path -Parent $gameRoot }

    $detected = Get-GameLanguageText $gameRoot
    if (-not $detected) { $detected = Get-TextualGameLanguageToken $gameRoot }
    $radarLang = if ($detected) { $detected.Language } else { 'en' }
    if (-not (Test-Path -LiteralPath (Join-Path $dllsRoot ('lang/' + $radarLang + '.txt')) -PathType Leaf)) {
        Log ("Auto language: missing lang/" + $radarLang + ".txt; falling back to en.")
        $radarLang = 'en'
    }
    if (-not (Test-Path -LiteralPath (Join-Path $dllsRoot 'lang/en.txt') -PathType Leaf)) {
        throw 'Required radar fallback language file lang/en.txt is missing.'
    }
    Set-Content -LiteralPath $languePath -Value $radarLang -Encoding ASCII
    if ($detected) {
        Log ("Auto language: " + $detected.Kind + "='" + $detected.Token + "' -> radar='" + $radarLang + "' | source=" + $detected.Source)
    } else {
        Log 'Auto language: no supported game-language setting found; radar defaults to en.'
    }
    return $radarLang
}
