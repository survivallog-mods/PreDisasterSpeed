# ============ Per-mod release pipeline (self-contained) ============
# Usage: .\release.ps1 [-Yes] [-PackageOnly]
#   -PackageOnly  build+package+update.json only (suite publish uses this); no gate/tag/release
# Version authority: csproj <Version> (author-edited); Plugin.cs const must match.
param([switch]$Yes, [switch]$PackageOnly)
$ErrorActionPreference = 'Stop'
$repoDir = $PSScriptRoot
$root    = Split-Path $PSScriptRoot -Parent
$modName = Split-Path $repoDir -Leaf
$proj    = Join-Path $repoDir ('SurvivalLog.' + $modName)
$game    = 'E:\SteamLibrary\steamapps\common\Survival Log'
$dotnet  = Join-Path $root 'sdk\dotnet\dotnet.exe'
$ghExe   = Join-Path $root 'suite\tools\gh\bin\gh.exe'
$org     = 'survivallog-mods'

# ---- 1. version authority: csproj ----
$csproj = Join-Path $proj ('SurvivalLog.' + $modName + '.csproj')
$t = [IO.File]::ReadAllText($csproj)
$ver = [regex]::Match($t, '<Version>([\d.]+)</Version>').Groups[1].Value
if (-not $ver) { throw 'cannot read <Version> from csproj' }
$plug = Get-ChildItem $proj -Filter '*Plugin.cs' | Select-Object -First 1
if ($plug -and (([IO.File]::ReadAllText($plug.FullName)) -notmatch ('public const string Version\s*=\s*"' + [regex]::Escape($ver) + '"'))) {
    throw ($plug.Name + ' Version const != csproj ' + $ver)
}

# ---- 2. gates (release mode only) ----
# CHANGELOG.md lives inside the project dir in this mirror-repo layout (synced from mod_stack)
$logPath = Join-Path $proj 'CHANGELOG.md'
$logTxt = [IO.File]::ReadAllText($logPath)
if (-not $PackageOnly) {
    if ($logTxt -notmatch (('##\s*v' + [regex]::Escape($ver)) + '\b')) { throw ('CHANGELOG.md has no v' + $ver + ' section') }
    $dirty = @(git -C $repoDir status --porcelain)
    $blocking = @($dirty | Where-Object { $_ -notmatch 'CHANGELOG\.md\s*$' })
    if ($blocking.Count -gt 0) { $blocking | ForEach-Object { Write-Host ('  ' + $_) }; throw 'uncommitted changes - commit or stash first (CHANGELOG.md allowed)' }
    if (-not $Yes) { $a = Read-Host ('Release ' + $modName + ' v' + $ver + ' ? [Y/N]'); if ($a -notmatch '^[Yy]') { throw 'cancelled' } }
}

# ---- 3. build ----
$env:DOTNET_MULTILEVEL_LOOKUP = '0'; $env:DOTNET_CLI_TELEMETRY_OPTOUT = '1'; $env:DOTNET_NOLOGO = '1'
& $dotnet build $proj -c Release --nologo | Out-Host
if ($LASTEXITCODE -ne 0) { throw ('build failed: ' + $modName) }
$dll = Join-Path $proj ('bin\Release\SurvivalLog.' + $modName + '.dll')
if (-not (Test-Path $dll)) { throw ('dll missing: ' + $dll) }

# ---- 4. package ----
$pkg = Join-Path $env:TEMP ('slpkg_' + $modName + '_v' + $ver)
if (Test-Path $pkg) { Remove-Item $pkg -Recurse -Force }
New-Item (Join-Path $pkg 'BepInEx\plugins') -ItemType Directory -Force | Out-Null
New-Item (Join-Path $pkg 'BepInEx\config')  -ItemType Directory -Force | Out-Null
Copy-Item $dll (Join-Path $pkg 'BepInEx\plugins') -Force
# no preset cfg (first run generates defaults)
Copy-Item (Join-Path $repoDir 'ReleaseREADME.md') (Join-Path $pkg 'README.md') -Force
$relDir = Join-Path $repoDir 'release'
New-Item $relDir -ItemType Directory -Force | Out-Null
$zip = Join-Path $relDir ('SurvivalLog.' + $modName + '_v' + $ver + '.zip')
if (Test-Path $zip) { Remove-Item $zip -Force }
Compress-Archive -Path (Join-Path $pkg '*') -DestinationPath $zip -CompressionLevel Optimal

# ---- 5. update.json (contract: mod/version/asset/md5/gamekb) ----
$md5 = (Get-FileHash $zip -Algorithm MD5).Hash.ToLower()
$gk = Get-ChildItem (Join-Path $root 'gamekb') -Directory | Where-Object { $_.Name -match '^\d{4}-\d{2}-\d{2}_\d+$' } | Sort-Object Name -Descending | Select-Object -First 1
if (-not $gk) { throw 'no gamekb snapshot under <root>\gamekb' }
$uj = @{ mod = $modName; version = $ver; asset = (Split-Path $zip -Leaf); md5 = $md5; gamekb = $gk.Name } | ConvertTo-Json
$updatePath = Join-Path $env:TEMP 'update.json'
[IO.File]::WriteAllText($updatePath, $uj, (New-Object Text.UTF8Encoding($false)))
Write-Host $uj
if ($PackageOnly) { Write-Host ('package-only done: ' + $zip); exit 0 }

# ---- 6. release notes + tag + GitHub release ----
$notes = [regex]::Match($logTxt, ('(?s)##\s*v' + [regex]::Escape($ver) + '\b.*?(?=\r?\n(---|#{1,2}\s)|\z)')).Value.Trim()
$notesFile = Join-Path $env:TEMP ('relnotes_' + $modName + '_v' + $ver + '.md')
[IO.File]::WriteAllText($notesFile, $notes, (New-Object Text.UTF8Encoding($false)))
& $ghExe release create ('v' + $ver) --repo ($org + '/' + $modName) --title ('v' + $ver) --notes-file $notesFile $zip $updatePath
if ($LASTEXITCODE -ne 0) { throw ('gh release create failed: ' + $modName) }
Write-Host ('=== ' + $modName + ' v' + $ver + ' released ===')
Write-Host 'Nexus Mods stays a separate author-confirmed step (docs/08). Not automated.'
