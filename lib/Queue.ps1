# ============================================================
#  Queue.ps1 - hang doi job + khoa runner
#  Queue la drop-folder: ghi file .tmp roi rename -> atomic,
#  nhieu nguon ghi cung luc khong dung nhau.
# ============================================================

function New-CiJobId {
    (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + ([guid]::NewGuid().ToString('N').Substring(0,4))
}

function Add-CiJob {
    param(
        $Config,
        [string]$Sha,
        [string]$Branch,
        [string]$Subject,
        [ValidateSet('apk','aab')][string]$Format = 'apk',
        [ValidateSet('dev','release')][string]$BuildConfig = 'dev',
        [string]$By = 'cli',
        [int]$VersionCode = 0,
        [string]$Project = ''
    )
    $paths = Get-CiPaths $Config
    if (-not (Test-Path $paths.Queue)) { New-Item -ItemType Directory -Force -Path $paths.Queue | Out-Null }

    $id  = New-CiJobId
    $job = [ordered]@{
        id          = $id
        project     = $Project
        sha         = $Sha
        shaShort    = $Sha.Substring(0,7)
        branch      = $Branch
        subject     = $Subject
        format      = $Format
        config      = $BuildConfig
        by          = $By
        versionCode = $VersionCode
        versionName = ''
        outputPath  = ''
        createdAt   = (Get-Date).ToString('o')
    }

    $tmp = Join-CiPath $paths.Queue "$id.json.tmp"
    $fin = Join-CiPath $paths.Queue "$id.json"
    Write-JsonFile $tmp ([pscustomobject]$job)
    Move-Item -LiteralPath $tmp -Destination $fin -Force
    return [pscustomobject]$job
}

function Get-CiQueue($Config) {
    $paths = Get-CiPaths $Config
    if (-not (Test-Path $paths.Queue)) { return @() }
    Get-ChildItem -Path $paths.Queue -Filter '*.json' -ErrorAction SilentlyContinue |
        Sort-Object Name |
        ForEach-Object { $j = Read-JsonFile $_.FullName; if ($j) { $j | Add-Member -NotePropertyName _file -NotePropertyValue $_.FullName -Force; $j } }
}

function Move-CiJobToProcessing($Config, $Job) {
    $paths = Get-CiPaths $Config
    if (-not (Test-Path $paths.Processing)) { New-Item -ItemType Directory -Force -Path $paths.Processing | Out-Null }
    $dest = Join-CiPath $paths.Processing ("{0}.json" -f $Job.id)
    Move-Item -LiteralPath $Job._file -Destination $dest -Force
    return $dest
}

function Clear-CiQueue($Config) {
    $paths = Get-CiPaths $Config
    if (Test-Path $paths.Queue) {
        Get-ChildItem -Path $paths.Queue -Filter '*.json' -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
    }
}

# ------------------------------------------------------------
#  Khoa runner: dung named Mutex thay vi lock file.
#  Ly do: Windows tu thu hoi mutex khi process chet ->
#  khong bao gio con lock "mo coi" phai don tay.
# ------------------------------------------------------------
$script:CiMutexName = 'UnityCiBuildRunner_SingleInstance'

function Enter-CiRunnerLock {
    $created = $false
    $m = New-Object System.Threading.Mutex($true, $script:CiMutexName, [ref]$created)
    if ($created) { return $m }
    $acquired = $false
    try { $acquired = $m.WaitOne(0) }
    catch [System.Threading.AbandonedMutexException] { $acquired = $true }   # chu cu chet -> ta duoc quyen
    catch { $acquired = $false }
    if ($acquired) { return $m }
    $m.Dispose()
    return $null
}

function Exit-CiRunnerLock($Mutex) {
    if (-not $Mutex) { return }
    try { $Mutex.ReleaseMutex() } catch {}
    try { $Mutex.Dispose() } catch {}
}

function Test-CiRunnerBusy {
    # KHONG duoc hoi bang Enter-CiRunnerLock: mutex cho phep chinh thread dang
    # giu no lay lai lan nua (re-entrant), nen se tra ve "ranh" nham.
    # Chi can biet kernel object con ton tai hay khong - runner giu handle suot
    # doi song cua no, chet la Windows huy object ngay.
    try {
        $m = [System.Threading.Mutex]::OpenExisting($script:CiMutexName)
        $m.Dispose()
        return $true
    } catch [System.Threading.WaitHandleCannotBeOpenedException] {
        return $false
    } catch {
        return $false
    }
}

function Start-CiRunner {
    param([switch]$Visible)
    $runner = Join-Path (Get-ToolDir) 'runner.ps1'
    if (-not (Test-Path $runner)) { throw "Khong tim thay runner.ps1" }
    $style = if ($Visible) { 'Normal' } else { 'Hidden' }
    Start-Process -FilePath 'powershell.exe' `
        -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File', ('"{0}"' -f $runner)) `
        -WindowStyle $style | Out-Null
}
