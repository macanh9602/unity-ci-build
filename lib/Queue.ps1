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
        [string]$Project = '',
        [string]$Platform = 'android',
        [string]$GitRemote = '',
        [string]$UnityVersion = '',
        [string]$TargetAgent = '',
        [switch]$DevelopmentBuild
    )
    $paths = Get-CiPaths $Config
    if (-not (Test-Path $paths.Queue)) { New-Item -ItemType Directory -Force -Path $paths.Queue | Out-Null }

    $id  = New-CiJobId
    $job = [ordered]@{
        id          = $id
        project     = $Project
        platform    = $Platform
        targetAgent = $TargetAgent
        gitRemote   = $GitRemote
        unityVersion= $UnityVersion
        sha         = $Sha
        shaShort    = $Sha.Substring(0,7)
        branch      = $Branch
        subject     = $Subject
        format      = $Format
        config      = $BuildConfig
        developmentBuild = [bool]$DevelopmentBuild
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

# Gianh job bang cach DOI TEN file sang thu muc rieng cua agent.
# Rename la thao tac nguyen tu ca tren o mang, nen hai agent cung nhay vao
# mot job thi mot cai that bai -> tra ve $null va bo qua job do.
# Khoa mutex khong dung duoc o day vi no chi co tac dung trong mot may.
function Move-CiJobToProcessing {
    param($Config, $Job, [string]$AgentName = '')
    $paths = Get-CiPaths $Config
    $dir = if ($AgentName) { Join-CiPath $paths.Processing $AgentName } else { $paths.Processing }
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    $dest = Join-CiPath $dir ("{0}.json" -f $Job.id)
    try {
        if (-not (Test-Path $Job._file)) { return $null }   # agent khac vua lay mat
        Move-Item -LiteralPath $Job._file -Destination $dest -ErrorAction Stop
        return $dest
    } catch {
        return $null
    }
}

# Agent chi nhat job ma no build duoc (Windows khong build duoc iOS).
# Job khong ghi platform la job doi cu -> coi nhu android.
function Select-CiJobForAgent {
    param($Config, $Queue)
    $can = @($Config.canBuild)
    if ($can.Count -eq 0) { $can = @('android') }
    $me = "$($Config.agentName)"
    foreach ($j in $Queue) {
        # Job ghim cho mot may cu the (nguoi dung chon "build ngay tai may nay")
        # thi may khac khong duoc cuop
        $target = "$($j.targetAgent)"
        if ($target -and $target -ne $me) { continue }

        $plat = "$($j.platform)"
        if (-not $plat) { $plat = 'android' }
        if ($can -contains $plat) { return $j }
    }
    return $null
}

function Clear-CiQueue($Config) {
    $paths = Get-CiPaths $Config
    if (Test-Path $paths.Queue) {
        Get-ChildItem -Path $paths.Queue -Filter '*.json' -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
    }
}

# ------------------------------------------------------------
#  Huy build
#  Job dang CHO  -> xoa file la xong.
#  Job dang CHAY -> khong giet tien trinh tu xa duoc (co the o may khac),
#                   nen dat mot file co; runner tu nhat o vong poll 3 giay
#                   san co cua no roi tu giet Unity.
# ------------------------------------------------------------
function Get-CiCancelFlagPath {
    param($Config, [string]$JobId)
    Join-CiPath (Get-CiPaths $Config).Root 'cancel' ("{0}.flag" -f $JobId)
}

function Request-CiCancel {
    param($Config, [string]$JobId)
    $f = Get-CiCancelFlagPath $Config $JobId
    $dir = Split-Path -Parent $f
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    Set-Utf8NoBom -Path $f -Text ((Get-Date).ToString('o'))
}

function Test-CiCancelRequested {
    param($Config, [string]$JobId)
    Test-Path (Get-CiCancelFlagPath $Config $JobId)
}

function Clear-CiCancelFlag {
    param($Config, [string]$JobId)
    Remove-Item -LiteralPath (Get-CiCancelFlagPath $Config $JobId) -Force -ErrorAction SilentlyContinue
}

# Job dang chay = file nam trong processing/<agent>/
function Get-CiRunningJobs {
    param($Config)
    $paths = Get-CiPaths $Config
    if (-not (Test-Path $paths.Processing)) { return @() }
    $out = New-Object System.Collections.ArrayList
    foreach ($f in (Get-ChildItem -Path $paths.Processing -Filter '*.json' -Recurse -ErrorAction SilentlyContinue)) {
        $j = Read-JsonFile $f.FullName
        if (-not $j) { continue }
        Add-Member -InputObject $j -NotePropertyName _file  -NotePropertyValue $f.FullName -Force
        Add-Member -InputObject $j -NotePropertyName _agent -NotePropertyValue (Split-Path -Leaf (Split-Path -Parent $f.FullName)) -Force
        [void]$out.Add($j)
    }
    return $out.ToArray()
}

function Remove-CiQueuedJob {
    param($Config, [string]$JobId)
    $paths = Get-CiPaths $Config
    $f = Join-CiPath $paths.Queue ("{0}.json" -f $JobId)
    if (Test-Path $f) { Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue; return $true }
    return $false
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
