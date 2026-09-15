# ============================================================
#  Unity.ps1 - do tim Unity Hub / Editor / module Android
#  Tach rieng vi CA setup.ps1 LAN runner.ps1 deu can:
#  runner tu nhan project la thi phai tu tim ban Unity khop.
# ============================================================

function Find-UnityHub {
    foreach ($p in @(
        (Join-Path $env:ProgramFiles 'Unity Hub\Unity Hub.exe'),
        (Join-Path ${env:ProgramFiles(x86)} 'Unity Hub\Unity Hub.exe')
    )) { if ($p -and (Test-Path $p)) { return $p } }
    return $null
}

function Get-UnityEditors {
    $roots = New-Object System.Collections.ArrayList
    [void]$roots.Add((Join-Path $env:ProgramFiles 'Unity\Hub\Editor'))
    $sec = Join-Path $env:APPDATA 'UnityHub\secondaryInstallPath.json'
    if (Test-Path $sec) {
        $p = (Get-Content $sec -Raw -ErrorAction SilentlyContinue)
        if ($p) { $p = $p.Trim().Trim('"'); if ($p) { [void]$roots.Add($p) } }
    }
    $found = New-Object System.Collections.ArrayList
    foreach ($r in $roots) {
        if (-not (Test-Path $r)) { continue }
        foreach ($d in (Get-ChildItem -Path $r -Directory -ErrorAction SilentlyContinue)) {
            $exe = Join-Path $d.FullName 'Editor\Unity.exe'
            if (Test-Path $exe) {
                [void]$found.Add([pscustomobject]@{
                    Version = $d.Name
                    Exe     = $exe
                    Root    = $d.FullName
                })
            }
        }
    }
    return $found.ToArray()
}

function Get-AndroidModuleState([string]$EditorRoot) {
    $ap = Join-Path $EditorRoot 'Editor\Data\PlaybackEngines\AndroidPlayer'
    [pscustomobject]@{
        Installed = Test-Path $ap
        Jdk       = Test-Path (Join-Path $ap 'OpenJDK')
        Sdk       = Test-Path (Join-Path $ap 'SDK')
        Ndk       = Test-Path (Join-Path $ap 'NDK')
    }
}

function Get-ProjectUnityVersion([string]$ProjectPath) {
    $f = Join-Path $ProjectPath 'ProjectSettings\ProjectVersion.txt'
    if (-not (Test-Path $f)) { return $null }
    $t = Get-Content $f -Raw
    if ($t -match 'm_EditorVersion:\s*(\S+)') { return $Matches[1] }
    return $null
}

function Test-UnityProject([string]$P) {
    if (-not $P -or -not (Test-Path $P)) { return $false }
    (Test-Path (Join-Path $P 'Assets')) -and (Test-Path (Join-Path $P 'ProjectSettings'))
}

# Tim duong dan Unity.exe khop voi mot phien ban cu the
function Resolve-UnityExe {
    param([string]$Version)
    if (-not $Version) { return '' }
    $e = @(Get-UnityEditors) | Where-Object { $_.Version -eq $Version } | Select-Object -First 1
    if ($e) { return $e.Exe }
    return ''
}
