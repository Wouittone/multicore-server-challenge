param(
    [string]$PostgresBin = "$PSScriptRoot\bin\tools\postgres\pgsql\bin",
    [string]$Go = "$PSScriptRoot\bin\tools\golang\go\bin\go.exe",
    [ValidateRange(1, 1000000)][int[]]$Users = @(500, 2000, 5000, 10000),
    [switch]$UseExistingSeed,
    [ValidateRange(0, 1000000)][int]$HoldUsers = 0,
    [ValidateRange(0, 3600)][int]$CooldownSeconds = 240
)
$ErrorActionPreference = 'Stop'
$root = (Resolve-Path "$PSScriptRoot\..\..").Path
$out = "$PSScriptRoot\bin\local-performance"
$cluster = "$PSScriptRoot\bin\local-postgres"
New-Item -ItemType Directory -Force $out | Out-Null
function Checked([string]$Command, [string[]]$Arguments) {
    & $Command @Arguments
    if ($LASTEXITCODE -ne 0) { throw "$Command exited $LASTEXITCODE" }
}
if (-not (Test-Path "$PSScriptRoot\bin\conduit.exe")) { throw 'Run build.ps1 first' }
if (-not (Test-Path "$PostgresBin\initdb.exe")) { throw 'Provide PostgreSQL 18 binaries using -PostgresBin' }
if (-not (Test-Path $Go)) { throw 'Provide Go >= 1.27.1 using -Go' }
if ((Test-Path $cluster) -and -not (Test-Path "$cluster\PG_VERSION")) {
    throw 'Cluster directory exists but is not initialized; refusing to overwrite it'
}
$env:PATH = "$PostgresBin;C:\Program Files\Git\ucrt64\bin;$env:PATH"
if (-not (Test-Path "$cluster\PG_VERSION")) {
    Checked "$PostgresBin\initdb.exe" @('-D', $cluster, '-U', 'postgres', '-A', 'trust', '--encoding=UTF8', '--locale=C')
}
$startup = Start-Process "$PostgresBin\pg_ctl.exe" -ArgumentList @('-D', "`"$cluster`"", '-l', "`"$out\postgres.log`"", '-o', '"-h 127.0.0.1 -p 55439"', '-w', 'start') -PassThru -RedirectStandardOutput "$out\postgres-start.log" -RedirectStandardError "$out\postgres-start-errors.log"
$startup.WaitForExit()
if ($startup.ExitCode -ne 0) { throw 'PostgreSQL startup failed; see postgres-start logs' }
$server = $null
try {
    Push-Location "$root\bench"
    try {
        Checked $Go @('build', '-o', "$out\seedgen.exe", './cmd/seedgen')
        Checked $Go @('build', '-o', "$out\loadgen.exe", './cmd/loadgen')
    } finally { Pop-Location }
    $psql = "$PostgresBin\psql.exe"
    $connect = @('-X', '-q', '-v', 'ON_ERROR_STOP=1', '-h', '127.0.0.1', '-p', '55439', '-U', 'postgres')
    if (-not $UseExistingSeed) {
        Checked "$out\seedgen.exe" @('-out', "$out\seed", '-scale', '0.02')
        Checked $psql ($connect + @('-d', 'postgres', '-c', 'CREATE DATABASE conduit_local'))
        Checked $psql ($connect + @('-d', 'conduit_local', '-f', "$root\schema.sql"))
        $tables = @(
            @('tags', 'id,name', 'tags.tsv'),
            @('users', 'id,username,email,password_hash,bio,image,created_at', 'users.tsv'),
            @('articles', 'id,slug,author_id,title,description,body,created_at,updated_at', 'articles.*.tsv'),
            @('article_tags', 'article_id,tag_id', 'article_tags.*.tsv'),
            @('favorites', 'user_id,article_id,created_at', 'favorites.*.tsv'),
            @('comments', 'article_id,author_id,body,created_at,updated_at', 'comments.*.tsv'),
            @('follows', 'follower_id,followee_id,created_at', 'follows.*.tsv')
        )
        foreach ($table in $tables) {
            foreach ($file in Get-ChildItem "$out\seed" -Filter $table[2] | Sort-Object Name) {
                $path = $file.FullName.Replace('\', '/').Replace("'", "''")
                Checked $psql ($connect + @('-d', 'conduit_local', '-c', "\copy $($table[0]) ($($table[1])) FROM '$path'"))
            }
        }
        foreach ($table in @('users', 'articles', 'tags', 'comments')) {
            Checked $psql ($connect + @('-d', 'conduit_local', '-c', "SELECT setval(pg_get_serial_sequence('$table','id'), (SELECT max(id) FROM $table))"))
        }
        Checked $psql ($connect + @('-d', 'conduit_local', '-c', 'VACUUM (FREEZE, ANALYZE)'))
    } else {
        Checked $psql ($connect + @('-d', 'conduit_local', '-c', 'SELECT count(*) FROM articles'))
    }
    Get-CimInstance Win32_Processor | Select-Object Name, NumberOfCores, NumberOfLogicalProcessors | Format-List | Out-File "$out\environment.txt"
    Get-CimInstance Win32_OperatingSystem | Select-Object Caption, TotalVisibleMemorySize | Format-List | Out-File "$out\environment.txt" -Append
    'Dev seed (10,000 articles); direct HTTP; co-located generator; no CPU isolation.' | Out-File "$out\environment.txt" -Append
    "Retained database reused: $UseExistingSeed" | Out-File "$out\environment.txt" -Append
    & $psql @connect -d conduit_local -At -c 'SELECT count(*) FROM articles' |
        Out-File "$out\environment.txt" -Append
    if ($LASTEXITCODE -ne 0) { throw 'Could not record database size' }
    $env:DATABASE_URL = 'postgres://postgres@127.0.0.1:55439/conduit_local'
    $env:JWT_SECRET = 'local-performance-only'
    $env:HOST = '127.0.0.1'
    $env:PORT = '3110'
    $server = Start-Process "$PSScriptRoot\bin\conduit.exe" -PassThru -RedirectStandardOutput "$out\server.log" -RedirectStandardError "$out\server-errors.log"
    $ready = $false
    for ($i = 0; $i -lt 60; $i++) {
        curl.exe -fsS -o NUL http://127.0.0.1:3110/api/tags 2>$null
        if ($LASTEXITCODE -eq 0) { $ready = $true; break }
        if ($server.HasExited) { throw 'Server exited before readiness' }
        Start-Sleep -Seconds 1
    }
    if (-not $ready) { throw 'Server did not become ready' }
    $best = $HoldUsers
    $run = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    if ($HoldUsers -gt 0) { $Users = @() }
    foreach ($count in $Users) {
        Start-Sleep -Seconds $CooldownSeconds
        Checked "$out\loadgen.exe" @('run', '-target', 'http://127.0.0.1:3110', '-users', "$count",
            '-ramp', '30s', '-measure', '60s', '-tail', '5s', '-articles', '10000',
            '-secret', $env:JWT_SECRET, '-run-id', "local-$run-$count", '-out', "$out\probe-$count.json")
        & "$out\loadgen.exe" merge -o "$out\probe-$count-merged.json" "$out\probe-$count.json" *> "$out\probe-$count.txt"
        if ($LASTEXITCODE -notin @(0, 3)) { throw 'Loadgen merge failed' }
        Get-Content "$out\probe-$count.txt"
        $result = Get-Content "$out\probe-$count-merged.json" -Raw | ConvertFrom-Json
        if (-not $result.verdict.pass -or $result.verdict.lg_limited) { break }
        $best = $count
    }
    if ($best -gt 0) {
        Start-Sleep -Seconds $CooldownSeconds
        Checked "$out\loadgen.exe" @('run', '-target', 'http://127.0.0.1:3110', '-users', "$best",
            '-ramp', '60s', '-measure', '300s', '-tail', '5s', '-articles', '10000',
            '-secret', $env:JWT_SECRET, '-run-id', "local-$run-hold", '-out', "$out\hold.json")
        & "$out\loadgen.exe" merge -o "$out\hold-merged.json" "$out\hold.json" *> "$out\hold.txt"
        if ($LASTEXITCODE -notin @(0, 3)) { throw 'Loadgen hold merge failed' }
        Get-Content "$out\hold.txt"
    }
} finally {
    if ($server -and -not $server.HasExited) { Stop-Process -Id $server.Id }
    Checked "$PostgresBin\pg_ctl.exe" @('-D', $cluster, '-m', 'fast', '-w', 'stop')
}
