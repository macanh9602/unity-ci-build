# ============================================================
#  runner.ps1 - bo phan thuc su build. Chay nen, mot job mot luc.
#  Khong goi truc tiep - ci.ps1 / Unity Editor tu spawn file nay.
# ============================================================
[CmdletBinding()]
param(
    [switch]$Once,     # chi xu ly het queue mot lan roi thoat
    [switch]$Watch     # che do agent: chay thuong truc, cu vai giay ngo queue
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib\Common.ps1')
. (Join-Path $PSScriptRoot 'lib\Queue.ps1')
. (Join-Path $PSScriptRoot 'lib\UnityLog.ps1')
. (Join-Path $PSScriptRoot 'lib\Discord.ps1')
. (Join-Path $PSScriptRoot 'lib\Drive.ps1')
. (Join-Path $PSScriptRoot 'lib\Unity.ps1')
Set-ConsoleUtf8

$root    = Read-CiConfig          # cau hinh goc: cai dat chung + danh sach project
$secrets = Read-CiSecrets
$paths   = Get-CiPaths $root
Initialize-CiDirs $root

$webhook = ''
if ($root.discord -and $root.discord.enabled) { $webhook = Get-Secret $secrets 'discordWebhook' }

$env:UNITY_NO_CONSENT_PROMPT = '1'

function Normalize-CiGitRemote {
    param([string]$Remote)
    return ("$Remote".Trim() -replace '/+$','')
}

function Get-CiGitFailureCode {
    param([string]$Message)
    if ("$Message" -match '(?i)authentication|auth|credential|permission denied|access denied|403|401|could not read username|repository not found') { return 'GIT_AUTH_REQUIRED' }
    return 'GIT_FAILURE'
}

function Get-CiBuildResourcePolicy {
    param($Config)
    $total = [Environment]::ProcessorCount
    $mode = "$($Config.buildPerformanceMode)"
    if ($mode -notin @('editor-friendly','balanced','max-speed')) {
        $mode = if ("$($Config.role)" -eq 'agent') { 'max-speed' } else { 'balanced' }
    }
    $reserve = switch ($mode) {
        'editor-friendly' { [Math]::Max(1, [int][Math]::Ceiling($total * 0.25)) }
        'balanced' { if ($total -le 4) { 1 } else { 2 } }
        default { 0 }
    }
    if ($Config.reserveCoresForEditor -ne $null -and [int]$Config.reserveCoresForEditor -gt 0 -and $mode -eq 'editor-friendly') {
        $reserve = [int]$Config.reserveCoresForEditor
    }
    if ($reserve -ge $total) { $reserve = [Math]::Max(0, $total - 1) }
    [pscustomobject]@{ Mode=$mode; PriorityClass=$(if($mode -eq 'editor-friendly'){'BelowNormal'}else{'Normal'}); ReserveCores=$reserve; ProcessorAffinity=$null; AffinityApplied=$false }
}

function Apply-CiBuildResourcePolicy {
    param($Process, $Config)
    $policy = Get-CiBuildResourcePolicy $Config
    try {
        if ($policy.PriorityClass -eq 'BelowNormal') {
            $Process.PriorityClass = [System.Diagnostics.ProcessPriorityClass]::BelowNormal
        } else {
            $Process.PriorityClass = [System.Diagnostics.ProcessPriorityClass]::Normal
        }
    } catch {}
    if ([Environment]::ProcessorCount -gt 63) {
        Write-RunnerLog $Config "RESOURCE POLICY [$($policy.Mode)] priority=$($policy.PriorityClass) reserve=$($policy.ReserveCores); affinity skipped for >63 logical processors"
        return $policy
    }
    try {
        $usable = [Environment]::ProcessorCount - $policy.ReserveCores
        if ($policy.ReserveCores -gt 0 -and $usable -gt 0) {
            [long]$mask = 0
            for ($i = 0; $i -lt $usable; $i++) { $mask = $mask -bor ([long]1 -shl $i) }
            $Process.ProcessorAffinity = [IntPtr]$mask
            $policy.ProcessorAffinity = $mask
            $policy.AffinityApplied = $true
        }
    } catch {}
    Write-RunnerLog $Config "RESOURCE POLICY [$($policy.Mode)] priority=$($policy.PriorityClass) reserve=$($policy.ReserveCores) affinity=$($policy.AffinityApplied)"
    return $policy
}

function Test-CiGitRemoteAllowed {
    param($Root, [string]$ProjectName, [string]$Remote)
    $value = Normalize-CiGitRemote $Remote
    if (-not $value -or $value -match '[;&|<>]' -or $value -match '\s' -or $value.StartsWith('-')) { return $false }
    if ($value -notmatch '(?i)^(https?|ssh)://[^/\s]+/.+|^git@[^:\s]+:.+') { return $false }
    $known = @($Root.projects | Where-Object { "$($_.name)" -eq $ProjectName } | Select-Object -First 1)
    if ($known -and "$($known[0].gitRemote)" -and
        -not [string]::Equals((Normalize-CiGitRemote "$($known[0].gitRemote)"), $value, [StringComparison]::OrdinalIgnoreCase)) { return $false }
    if ($known) { return $true }
    $prefixes = @()
    if (Test-CiHasProp $Root 'allowedGitRemotePrefixes') { $prefixes = @($Root.allowedGitRemotePrefixes) }
    foreach ($prefix in $prefixes) {
        $safePrefix = "$prefix".Trim()
        if ($safePrefix -and ($safePrefix.EndsWith('/') -or $safePrefix.EndsWith(':')) -and
            $value.StartsWith($safePrefix, [StringComparison]::OrdinalIgnoreCase)) { return $true }
    }
    return $false
}

# ------------------------------------------------------------
function Sync-Worktree {
    param($Config, [string]$Sha, [string]$GitRemote = '', [int]$RecoveryAttempt = 0)
    $wt = $Config.worktreePath
    if (-not (Test-CiRootValid $wt)) {
        throw ("Cau hinh hong: worktreePath '$wt' khong phai duong dan tuyet doi. " +
               "Chay lai install.bat va nhap duong dan day du nhu E:\UnityCI (dung go moi chu 'E').")
    }
    # Standalone clone/worktree hop le duoc dung lai binh thuong.
    # Neu worktree cua standalone co source repo, dung helper self-healing.
    if (-not (Test-CiWorktreeUsable $wt)) {
        $sourceUsable = Test-CiWorktreeUsable $Config.projectPath
        if ($sourceUsable -and (Test-CiOwnedWorktreePath $Config.ciRoot $Config.projectName $Config.projectPath $wt)) {
            if (-not (Ensure-CiWorktree -CiRoot $Config.ciRoot -ProjectName $Config.projectName `
                                      -ProjectPath $Config.projectPath -WorktreePath $wt)) {
                throw "Khong the repair/recreate worktree: $wt"
            }
        }
    }

    if (Test-CiWorktreeUsable $wt) {
        Write-RunnerLog $Config "WORKTREE REUSE [$($Config.projectName)]"
    }

    # May build khong co repo goc cua may dev -> clone tu remote.
    if (-not (Test-CiWorktreeUsable $wt)) {
        $remote = if ($GitRemote) { $GitRemote } else { "$($Config.gitRemote)" }
        if (-not $remote) {
            throw ("Khong tim thay worktree: $wt" + [Environment]::NewLine +
                   "Va khong biet clone tu dau (job khong kem gitRemote). Chay lai install.bat.")
        }
        $parent = Split-Path -Parent $wt
        if ($parent -and -not (Test-Path $parent)) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }

        if (Test-Path -LiteralPath $wt) {
            if (-not (Test-CiOwnedWorktreePath $Config.ciRoot $Config.projectName $Config.projectPath $wt)) {
                throw "Worktree path khong an toan, khong xoa: $wt"
            }
            Remove-Item -LiteralPath $wt -Recurse -Force -ErrorAction Stop
        }
        if (-not (Test-CiGitRemoteAllowed $root $Config.projectName $remote)) {
            throw "REMOTE_NOT_TRUSTED | gitRemote khong duoc phep cho project '$($Config.projectName)': $remote"
        }
        $cloneOutput = ''
        for ($attempt = 1; $attempt -le 2; $attempt++) {
            $old = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
            try { $cloneOutput = ((& git clone --quiet $remote $wt 2>&1) | ForEach-Object { "$_" }) -join "`n" }
            finally { $ErrorActionPreference = $old }
            if (Test-CiWorktreeUsable $wt) { break }
            if ($attempt -eq 1 -and (Test-CiOwnedWorktreePath $Config.ciRoot $Config.projectName $Config.projectPath $wt)) {
                if (Test-Path -LiteralPath $wt) { Remove-Item -LiteralPath $wt -Recurse -Force -ErrorAction Stop }
            }
        }
        if (-not (Test-CiWorktreeUsable $wt)) {
            if ($cloneOutput) { Write-RunnerLog $Config "CLONE ERROR [$($Config.projectName)]: $cloneOutput" }
            throw "$(Get-CiGitFailureCode $cloneOutput) | Clone that bai tu: $remote`n$cloneOutput"
        }
    }

    # Clone/worktree co san van co the chua co commit moi nhat
    $r = Invoke-Git $wt @('fetch','--all','--prune','--quiet')
    if ($r.ExitCode -ne 0) {
        $code = Get-CiGitFailureCode $r.Output
        if ($code -eq 'GIT_AUTH_REQUIRED') { throw "$code | Git fetch failed for BUILD Windows user" }
        Write-RunnerLog $Config "canh bao: git fetch exit $($r.ExitCode)"
    }

    # --force + reset --hard: bat buoc, vi build truoc do da sua ProjectSettings.asset
    # (bundleVersionCode, keystore...) -> checkout thuong se bi tu choi.
    $r = Invoke-Git $wt @('checkout','--detach','--force',$Sha)
    if ($r.ExitCode -ne 0) {
        if (-not (Test-CiWorktreeUsable $wt) -and $RecoveryAttempt -lt 1) {
            Write-RunnerLog $Config 'WORKTREE CORRUPT - recreate va retry sync'
            Remove-CiRunnerWorktreeForRecovery $Config
            Sync-Worktree -Config $Config -Sha $Sha -GitRemote $GitRemote -RecoveryAttempt 1
            return
        }
        throw "git checkout that bai:`n$($r.Output)"
    }

    $r = Invoke-Git $wt @('reset','--hard',$Sha)
    if ($r.ExitCode -ne 0) {
        if (-not (Test-CiWorktreeUsable $wt) -and $RecoveryAttempt -lt 1) {
            Write-RunnerLog $Config 'WORKTREE CORRUPT - recreate va retry sync'
            Remove-CiRunnerWorktreeForRecovery $Config
            Sync-Worktree -Config $Config -Sha $Sha -GitRemote $GitRemote -RecoveryAttempt 1
            return
        }
        throw "git reset that bai:`n$($r.Output)"
    }

    # Xoa rac nhung GIU Library/Temp -> build sau chi can import tang dan
    $r = Invoke-Git $wt @('clean','-xdf','-q','-e','Library','-e','Temp','-e','obj','-e','Logs','-e','UserSettings','-e','Builds')
    if ($r.ExitCode -ne 0) { Write-RunnerLog $Config "canh bao: git clean exit $($r.ExitCode)" }

    # Git LFS neu repo co dung
    if (Test-Path (Join-CiPath $wt '.gitattributes')) {
        $ga = Get-Content (Join-CiPath $wt '.gitattributes') -Raw -ErrorAction SilentlyContinue
        if ($ga -and $ga -match 'filter=lfs') {
            $r = Invoke-Git $wt @('lfs','checkout')
            if ($r.ExitCode -ne 0) { Write-RunnerLog $Config "canh bao: git lfs checkout exit $($r.ExitCode)" }
        }
    }
}

function Remove-CiRunnerWorktreeForRecovery {
    param($Config)
    $wt = $Config.worktreePath
    $sourceUsable = Test-CiWorktreeUsable $Config.projectPath
    if ($sourceUsable) {
        if (-not (Remove-StaleCiWorktree -CiRoot $Config.ciRoot -ProjectName $Config.projectName `
                                      -ProjectPath $Config.projectPath -WorktreePath $wt)) {
            throw "Khong the cleanup worktree: $wt"
        }
        return
    }
    if (-not (Test-CiOwnedWorktreePath $Config.ciRoot $Config.projectName $Config.projectPath $wt)) {
        throw "Worktree path khong an toan, khong xoa: $wt"
    }
    if (Test-Path -LiteralPath $wt) {
        Remove-Item -LiteralPath $wt -Recurse -Force -ErrorAction Stop
    }
    if (Test-Path -LiteralPath $wt) { throw "Khong the xoa worktree: $wt" }
}

# ------------------------------------------------------------
# Unity Library cache invalidation.
# Fingerprint duoc luu NGOAI worktree de git clean khong xoa mat.
# Moi agent co fingerprint rieng vi moi may co Library rieng.
function Get-CiUnityEditorVersion {
    param($Config)
    try {
        $v = [System.Diagnostics.FileVersionInfo]::GetVersionInfo($Config.unityExe)
        if ($v.ProductVersion) { return "$($v.ProductVersion)".Trim() }
        if ($v.FileVersion)    { return "$($v.FileVersion)".Trim() }
    } catch {}
    return "$($Config.unityVersion)".Trim()
}

function Get-CiCacheFingerprint {
    param($Config)

    $files = @(
        [pscustomobject]@{ Name = 'ProjectVersion.txt'; Path = Join-CiPath $Config.worktreePath 'ProjectSettings\ProjectVersion.txt' },
        [pscustomobject]@{ Name = 'manifest.json';      Path = Join-CiPath $Config.worktreePath 'Packages\manifest.json' },
        [pscustomobject]@{ Name = 'packages-lock.json'; Path = Join-CiPath $Config.worktreePath 'Packages\packages-lock.json' }
    )
    $sha = [System.Security.Cryptography.SHA256]::Create()
    $stream = New-Object System.IO.MemoryStream
    $writer = New-Object System.IO.BinaryWriter($stream, [System.Text.Encoding]::UTF8)
    try {
        $writer.Write('UnityCiLibraryFingerprintV1')
        $writer.Write((Get-CiUnityEditorVersion $Config))
        foreach ($f in $files) {
            $writer.Write($f.Name)
            $exists = Test-Path -LiteralPath $f.Path
            $writer.Write([bool]$exists)
            if ($exists) {
                $bytes = [System.IO.File]::ReadAllBytes($f.Path)
                $writer.Write([int]$bytes.Length)
                $writer.Write($bytes)
            }
        }
        $writer.Flush()
        $hash = $sha.ComputeHash($stream.ToArray())
        return ([BitConverter]::ToString($hash) -replace '-', '').ToLowerInvariant()
    } finally {
        $writer.Dispose()
        $stream.Dispose()
        $sha.Dispose()
    }
}

function Sync-CiUnityCache {
    param($Config)

    $library = Join-CiPath $Config.worktreePath 'Library'
    $temp    = Join-CiPath $Config.worktreePath 'Temp'
    $obj     = Join-CiPath $Config.worktreePath 'obj'
    $fpDir   = Join-CiPath $Config.ciRoot 'cache-fingerprints' $Config.agentName
    $fpPath  = Join-CiPath $fpDir ("{0}.fingerprint" -f $Config.projectName)

    if (-not (Test-Path $fpDir)) { New-Item -ItemType Directory -Force -Path $fpDir | Out-Null }

    $current = Get-CiCacheFingerprint $Config
    $previous = ''
    if (Test-Path -LiteralPath $fpPath) {
        $previous = (Get-Content -LiteralPath $fpPath -Raw -ErrorAction SilentlyContinue).Trim()
    }

    $libraryExists = Test-Path -LiteralPath $library
    $hit = $libraryExists -and $previous -and ($previous -eq $current)
    if ($hit) {
        Write-RunnerLog $Config "CACHE HIT  [$($Config.projectName)] fp=$($current.Substring(0,12)) - giu nguyen Library/Temp/obj"
        return [pscustomobject]@{ State='hit'; Reason='fingerprint matched'; Fingerprint=$current; Path=$fpPath; NeedsSave=$false }
    }

    $initialize = -not $previous
    if ($initialize) {
        $reason = if ($libraryExists) { 'chua co fingerprint' } else { 'Library not present' }
        Write-RunnerLog $Config "CACHE INITIALIZE [$($Config.projectName)] ($reason)"
    } elseif ($previous -ne $current) {
        $reason = 'fingerprint changed'
        Write-RunnerLog $Config "CACHE MISS [$($Config.projectName)] reason=fingerprint changed - xoa Library/Temp/obj"
    } else {
        $reason = 'Library missing'
        Write-RunnerLog $Config "CACHE MISS [$($Config.projectName)] reason=Library missing - xoa Library/Temp/obj"
    }
    foreach ($dir in @($library, $temp, $obj)) {
        if (Test-Path -LiteralPath $dir) {
            Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction Stop
        }
    }

    return [pscustomobject]@{ State=$(if($initialize){'initialize'}else{'miss'}); Reason=$reason; Fingerprint=$current; Path=$fpPath; NeedsSave=$true }
}

function Save-CiUnityCacheFingerprint {
    param($CacheState, $Config)
    if (-not $CacheState -or -not $CacheState.NeedsSave -or -not $CacheState.Fingerprint -or -not $CacheState.Path) { return }
    Set-Content -LiteralPath $CacheState.Path -Value $CacheState.Fingerprint -Encoding ASCII
    Write-RunnerLog $Config "CACHE FINGERPRINT SAVED [$($Config.projectName)] fp=$($CacheState.Fingerprint.Substring(0,12))"
}

function Ensure-ProjectBuildCredentials {
    param($Config, $Job, $Secrets)
    if ("$($Job.config)" -ne 'release') { return $true }
    $android = $Config.android
    $pass = Get-ProjectSecret $Secrets $Config.projectName 'keystorePass'
    $aliasPass = Get-ProjectSecret $Secrets $Config.projectName 'keyaliasPass'
    if (-not $android -or -not $android.keystorePath -or -not (Test-Path -LiteralPath $android.keystorePath) `
        -or -not $android.keyaliasName -or -not $pass -or -not $aliasPass) {
        throw "PROJECT SECRET REQUIRED [$($Config.projectName)] - release keystore/alias/password chua san sang"
    }
    return $true
}

# ------------------------------------------------------------
#  Bom CIBuild.cs vao worktree SAU khi checkout/clean.
#  Nho vay build duoc ca nhung commit cu chua he co script CI,
#  va nguoi dung khong can commit gi truoc khi build lan dau.
function Copy-CiScript {
    param($Config)
    $src = Join-Path (Get-ToolDir) 'unity\CIBuild.cs'
    if (-not (Test-Path $src)) { throw "Khong tim thay unity\CIBuild.cs trong thu muc tool" }
    $dstDir = Join-CiPath $Config.worktreePath 'Assets\Editor\CI'
    if (-not (Test-Path $dstDir)) { New-Item -ItemType Directory -Force -Path $dstDir | Out-Null }
    Copy-Item $src (Join-Path $dstDir 'CIBuild.cs') -Force
}

# ------------------------------------------------------------
function Invoke-UnityBuild {
    param($Config, $Job, [string]$JobFile, [string]$LogPath, $Secrets,
          [string]$Webhook = '', [string]$MessageId = '', [double]$EtaSeconds = 0, $StartedAt = $null)

    $argList = @(
        '-batchmode',
        '-projectPath', ('"{0}"' -f $Config.worktreePath),
        '-logFile',     ('"{0}"' -f $LogPath),
        '-buildTarget', 'Android',
        '-executeMethod','VTL.CI.CIBuild.Run',
        '-ciJob',       ('"{0}"' -f $JobFile)
    )
    if ($Config.useNographics) { $argList += '-nographics' }

    if (-not $Config.unityExe -or -not (Test-Path $Config.unityExe)) {
        throw "Khong tim thay Unity.exe tai: $($Config.unityExe)  (chay .\ci.ps1 doctor)"
    }

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName        = $Config.unityExe
    $psi.Arguments       = ($argList -join ' ')
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow  = $true

    # Bi mat di qua bien moi truong, KHONG ghi ra dia
    if ($Job.config -eq 'release' -and $Config.android -and $Config.android.keystorePath) {
        $psi.EnvironmentVariables['CI_KEYSTORE_PATH']  = [string]$Config.android.keystorePath
        $psi.EnvironmentVariables['CI_KEYALIAS_NAME']  = [string]$Config.android.keyaliasName
        $psi.EnvironmentVariables['CI_KEYSTORE_PASS']  = (Get-ProjectSecret $Secrets $Config.projectName 'keystorePass')
        $psi.EnvironmentVariables['CI_KEYALIAS_PASS']  = (Get-ProjectSecret $Secrets $Config.projectName 'keyaliasPass')
    }

    $proc = [System.Diagnostics.Process]::Start($psi)

    $resourcePolicy = Apply-CiBuildResourcePolicy -Process $proc -Config $Config

    # Vong cho co nhip: vua canh timeout, vua doc giai doan tu log,
    # vua sua lai tin nhan Discord. Khong dung WaitForExit chan cung
    # vi nhu vay thi suot qua trinh build khong bao duoc gi.
    if (-not $StartedAt) { $StartedAt = Get-Date }
    $timeoutAt = $StartedAt.AddMinutes([int]$Config.buildTimeoutMinutes)
    $tracker   = New-CiPhaseTracker
    $lastPush  = Get-Date

    while (-not $proc.HasExited) {
        Start-Sleep -Seconds 3

        if ((Get-Date) -gt $timeoutAt) {
            try { $proc.Kill() } catch {}
            try { $proc.WaitForExit(15000) | Out-Null } catch {}
            Complete-CiPhaseTracker $tracker
            return [pscustomobject]@{ Started = $true; ExitCode = -1; TimedOut = $true; Cancelled = $false; Phase = $tracker.Name; PhaseTimings=$tracker.Durations; ResourcePolicy=$resourcePolicy }
        }

        # Nguoi dung bam huy -> giet Unity ngay, khong doi het timeout
        if (Test-CiCancelRequested $Config $Job.id) {
            try { $proc.Kill() } catch {}
            try { $proc.WaitForExit(15000) | Out-Null } catch {}
            Complete-CiPhaseTracker $tracker
            return [pscustomobject]@{ Started = $true; ExitCode = -2; TimedOut = $false; Cancelled = $true; Phase = $tracker.Name; PhaseTimings=$tracker.Durations; ResourcePolicy=$resourcePolicy }
        }

        $tracker = Update-CiPhaseTracker $tracker $LogPath

        if ($MessageId -and ((Get-Date) - $lastPush).TotalSeconds -ge 20) {
            $lastPush = Get-Date
            Update-DiscordBuildProgress -WebhookUrl $Webhook -MessageId $MessageId -Job $Job `
                -Phase $tracker.Name `
                -ElapsedSeconds ((Get-Date) - $StartedAt).TotalSeconds `
                -EtaSeconds $EtaSeconds
        }
    }
    $proc.WaitForExit()
    $tracker = Update-CiPhaseTracker $tracker $LogPath
    Complete-CiPhaseTracker $tracker
    return [pscustomobject]@{ Started = $true; ExitCode = $proc.ExitCode; TimedOut = $false; Cancelled = $false; Phase = $tracker.Name; PhaseTimings=$tracker.Durations; ResourcePolicy=$resourcePolicy }
}

# ------------------------------------------------------------
function Invoke-CiJob {
    param($Config, $Job, $Secrets, [string]$Webhook, [string]$JobFile, [string]$MessageId = '', [datetime]$StartedAt, [switch]$WorktreeSynced)

    $paths   = Get-CiPaths $Config
    Initialize-CiDirs $Config
    $started = if ($StartedAt) { $StartedAt } else { Get-Date }
    $logPath = Join-CiPath $paths.Logs   ("{0}.log"        -f $Job.id)
    $errPath = Join-CiPath $paths.Logs   ("{0}.errors.txt" -f $Job.id)
    if (-not $JobFile) { throw "PREPARATION_FAILURE | missing processing job file" }

    Write-RunnerLog $Config "BAT DAU $($Job.id)  [$($Config.projectName)]  $($Job.branch)@$($Job.shaShort)  $($Job.format)/$($Job.config)"

    # Uoc tinh tu cac lan build thanh cong truoc do cua dung loai nay
    $eta = Get-CiEtaSeconds -Config $Config -ProjectName $Config.projectName `
                            -Format "$($Job.format)" -BuildConfig "$($Job.config)" -DevelopmentBuild ([bool]$Job.developmentBuild)
    $msgId = $MessageId

    $success = $false; $cancelled = $false; $failReason = ''; $sizeBytes = 0; $link = ''; $errInfo = $null
    $timings = [ordered]@{}
    $cacheState = $null
    $previousSize = $null
    $publishError = ''

    try {
        # Huy ngay tu truoc khi Unity kip chay
        if (Test-CiCancelRequested $Config $Job.id) {
            $cancelled = $true
            throw 'Da huy truoc khi build bat dau'
        }
        $stageStarted = Get-Date
        if (-not $WorktreeSynced) { Sync-Worktree -Config $Config -Sha $Job.sha -GitRemote "$($Job.gitRemote)" }
        $timings.gitSyncSeconds = [math]::Round(((Get-Date) - $stageStarted).TotalSeconds, 1)
        Update-CiDiscordPhase -Webhook $Webhook -MessageId $msgId -Job $Job -Phase 'Kiem tra Library cache' -StartedAt $started
        $stageStarted = Get-Date
        $cacheState = Sync-CiUnityCache -Config $Config
        $timings.cacheSeconds = [math]::Round(((Get-Date) - $stageStarted).TotalSeconds, 1)
        Copy-CiScript  -Config $Config

        # versionCode = so commit tinh den sha nay. Deterministic, khong can file state.
        if (-not $Job.versionCode -or $Job.versionCode -le 0) {
            $c = (& git -C $Config.worktreePath rev-list --count $Job.sha 2>$null)
            if ($LASTEXITCODE -eq 0 -and $c) { $Job.versionCode = [int]("$c".Trim()) }
        }

        $ext = if ($Job.format -eq 'aab') { 'aab' } else { 'apk' }
        # Kem ten branch vao ten file: hai branch co the co cung so commit
        # -> cung versionCode, nhin ten file khong the phan biet duoc
        $brSafe = ConvertTo-CiSafeName "$($Job.branch)"
        $profileSuffix = "$($Job.config)"
        if ([bool]$Job.developmentBuild) { $profileSuffix += '-development' }
        $Job.outputPath = Join-CiPath $paths.Builds ("{0}-{1}-{2}-{3}.{4}" -f $Job.id, $brSafe, $Job.shaShort, $profileSuffix, $ext)
        $Job | Add-Member -NotePropertyName resultPath -NotePropertyValue (Join-CiPath $paths.Logs ("{0}.unity-result.json" -f $Job.id)) -Force
        Write-JsonFile $jobFile $Job

        $stageStarted = Get-Date
        $run = Invoke-UnityBuild -Config $Config -Job $Job -JobFile $jobFile -LogPath $logPath -Secrets $Secrets `
                                 -Webhook $Webhook -MessageId $msgId -EtaSeconds $eta -StartedAt $started
        $timings.unitySeconds = [math]::Round(((Get-Date) - $stageStarted).TotalSeconds, 1)
        if ($run.PhaseTimings) { $timings.phases = $run.PhaseTimings }

        # Cache validity depends on Unity completing its process, not on APK success.
        # Compile/package failures still leave a fully imported Library usable next run.
        if ($cacheState -and $run.Started -and -not $run.TimedOut -and -not $run.Cancelled) {
            Save-CiUnityCacheFingerprint -CacheState $cacheState -Config $Config
        }

        if ($run.Cancelled) {
            $cancelled  = $true
            $failReason = "Da huy (dang o chang: $($run.Phase))"
        } elseif ($run.TimedOut) {
            $failReason = "Qua $($Config.buildTimeoutMinutes) phut - da buoc dung Unity (dang o chang: $($run.Phase))"
        } elseif ($run.ExitCode -ne 0) {
            $failReason = "Unity thoat voi ma $($run.ExitCode)"
        } elseif (-not (Test-Path $Job.outputPath)) {
            $failReason = 'Unity bao thanh cong nhung khong thay file output'
        } else {
            $success   = $true
            $sizeBytes = (Get-Item $Job.outputPath).Length
            $previousSize = Get-CiPreviousSameProfileSize -Config $Config -ProjectName $Config.projectName `
                -Format $Job.format -BuildConfig $Job.config -DevelopmentBuild ([bool]$Job.developmentBuild)
        }
    } catch {
        $failReason = $_.Exception.Message
    }

    $duration = ((Get-Date) - $started).TotalSeconds

    if ($success -and $Config.drive -and "$($Config.drive.mode)" -notin @('', 'none')) {
        $up = Publish-CiArtifact -Config $Config -FilePath $Job.outputPath
        if ($up.Published) {
            # Uu tien link that; neu chi copy vao folder dong bo thi hien duong dan folder
            if ($up.Link)        { $link = $up.Link }
            elseif ($up.Target)  { $link = '`' + $up.Target + '`' }
            Write-RunnerLog $Config "da dua file den: $($up.Target)"
        } else {
            # Build xong ma file khong toi duoc tester thi coi nhu chua xong viec.
            # Phai bao len Discord, khong duoc de chim trong runner.log.
            $publishError = if ($up.Message) { "$($up.Message)" } else { 'khong ro nguyen nhan' }
            Write-RunnerLog $Config "dua file di that bai: $publishError"
        }
    }

    if (-not $success -and -not $cancelled) {
        $errInfo = Write-CiErrorReport -LogPath $logPath -OutPath $errPath -Job $Job -Reason $failReason
    }

    $sizeDeltaPercent = $null
    if ($previousSize -and [long]$previousSize.sizeBytes -gt 0) {
        $sizeDeltaPercent = [math]::Round((($sizeBytes - [double]$previousSize.sizeBytes) / [double]$previousSize.sizeBytes) * 100, 1)
    }
    $result = [pscustomobject]@{
        id          = $Job.id
        project     = $Config.projectName
        success     = $success
        cancelled   = $cancelled
        branch      = $Job.branch
        sha         = $Job.sha
        shaShort    = $Job.shaShort
        subject     = $Job.subject
        format      = $Job.format
        config      = $Job.config
        developmentBuild = [bool]$Job.developmentBuild
        profile     = ("{0}/{1}/{2}" -f $Job.format.ToUpper(), $Job.config, $(if($Job.developmentBuild){'development'}else{'quick'}))
        by          = $Job.by
        versionCode = $Job.versionCode
        outputPath  = $(if ($success) { $Job.outputPath } else { '' })
        sizeBytes   = $sizeBytes
        previousSizeBytes = $(if($previousSize){[long]$previousSize.sizeBytes}else{$null})
        sizeDeltaPercent = $sizeDeltaPercent
        cacheState  = $(if($cacheState){$cacheState.State}else{''})
        cacheReason = $(if($cacheState){$cacheState.Reason}else{''})
        timings     = [pscustomobject]$timings
        driveLink   = $link
        publishError= $publishError
        durationSec = [math]::Round($duration, 1)
        finishedAt  = (Get-Date).ToString('o')
        failReason  = $failReason
        logPath     = $logPath
        errorsPath  = $(if ($success -or $cancelled) { '' } else { $errPath })
    }
    Write-JsonFile (Join-CiPath $paths.Results ("{0}.json" -f $Job.id)) $result
    Remove-Item -LiteralPath $jobFile -Force -ErrorAction SilentlyContinue
    Clear-CiCancelFlag $Config $Job.id

    if ($Webhook) {
        # Uu tien loi compile (cu the hon). Neu build chet truoc khi Unity kip chay
        # thi khong co loi compile nao - luc do phai day failReason len,
        # neu khong Discord bao "that bai" ma khong noi vi sao.
        $summaryText = Get-CiErrorSummary $errInfo
        if (-not $summaryText) { $summaryText = $failReason }

        Send-DiscordBuildResult -WebhookUrl $Webhook -Job $Job -Success $success -Cancelled $cancelled `
            -DurationSeconds $duration -OutputPath $Job.outputPath -SizeBytes $sizeBytes `
            -ShareLink $link -ErrorSummary $(if ($cancelled) { '' } else { $summaryText }) `
            -ErrorFile $(if ($success -or $cancelled) { '' } else { Split-Path -Leaf $errPath }) `
            -PublishError $publishError -MessageId $msgId
    }

    $tag = if ($success) { 'XONG' } elseif ($cancelled) { 'HUY ' } else { 'HONG' }
    Write-RunnerLog $Config "$tag  $($Job.id)  [$($Config.projectName)]  $(Format-Duration $duration)  $failReason"
    return $success
}

# ------------------------------------------------------------
#  Tu nhan project la
#  May build khong duoc cau hinh san tung project. Khi gap job cua
#  mot project chua biet, no tu clone tu gitRemote trong job, doc
#  ProjectVersion.txt de biet ban Unity, roi ghi vao config cua chinh no.
#  Nho vay them project moi chi phai cau hinh o may dev.
# ------------------------------------------------------------
function Register-CiProjectFromJob {
    param($Root, $Job, [string]$Webhook = '', [string]$MessageId = '', [datetime]$StartedAt)

    $name = "$($Job.project)"
    if (-not $name) { throw "Job khong co ten project" }

    $wt     = Join-CiPath $Root.ciRoot 'worktree' $name
    $builds = Join-CiPath $Root.ciRoot 'builds'   $name
    $remote = "$($Job.gitRemote)"
    $knownProject = @($Root.projects | Where-Object { "$($_.name)" -eq $name } | Select-Object -First 1)
    if (-not $remote -and $knownProject) { $remote = "$($knownProject[0].gitRemote)" }

    if (-not (Test-CiGitRemoteAllowed $Root $name $remote)) {
        throw "REMOTE_NOT_TRUSTED | gitRemote khong duoc phep cho project '$name': $remote"
    }

    if (-not (Test-CiWorktreeUsable $wt)) {
        if (-not $remote) { throw "Project '$name' chua duoc cau hinh va job khong kem gitRemote" }
        Write-RunnerLog $Root "tu nhan project moi '$name' - dang clone tu $remote"
        $parent = Split-Path -Parent $wt
        if ($parent -and -not (Test-Path $parent)) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
        if (Test-Path -LiteralPath $wt) {
            if (-not (Test-CiOwnedWorktreePath $Root.ciRoot $name '' $wt)) { throw "Worktree path khong an toan, khong xoa: $wt" }
            Remove-Item -LiteralPath $wt -Recurse -Force -ErrorAction Stop
        }
        $old = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
        $cloneOutput = ''
        try { $cloneOutput = ((& git clone --quiet $remote $wt 2>&1) | ForEach-Object { "$_" }) -join "`n" } finally { $ErrorActionPreference = $old }
        if (-not (Test-CiWorktreeUsable $wt)) { throw "$(Get-CiGitFailureCode $cloneOutput) | Clone that bai tu: $remote`n$cloneOutput" }
    }

    Update-CiDiscordPhase -Webhook $Webhook -MessageId $MessageId -Job $Job -Phase 'Dong bo Git' -StartedAt $StartedAt
    $syncConfig = [pscustomobject]@{ ciRoot=$Root.ciRoot; projectName=$name; projectPath=''; worktreePath=$wt; gitRemote=$remote }
    try { Sync-Worktree -Config $syncConfig -Sha "$($Job.sha)" -GitRemote $remote }
    catch {
        $message = "$($_.Exception.Message)"
        if ($message -match '^GIT_(AUTH_REQUIRED|FAILURE)\s*\|') { throw $message }
        throw "$(Get-CiGitFailureCode $message) | $message"
    }

    try { $ver = Get-CiUnityVersionAtCommit -WorktreePath $wt -Sha "$($Job.sha)" }
    catch { throw "PREFLIGHT_FAILURE | $($_.Exception.Message)" }
    Write-RunnerLog $Root (Format-UnityEditorResolution $ver)
    Update-CiDiscordPhase -Webhook $Webhook -MessageId $MessageId -Job $Job -Phase "Kiem tra Unity $ver" -StartedAt $StartedAt
    $autoProvision = $true
    if (Test-CiHasProp $Root 'autoProvisionUnity') { $autoProvision = [bool]$Root.autoProvisionUnity }
    Update-CiDiscordPhase -Webhook $Webhook -MessageId $MessageId -Job $Job -Phase 'Cai Unity/Android modules' -StartedAt $StartedAt
        $provision = Ensure-UnityEditor -Version $ver -NeedAndroid $true -AutoInstall $autoProvision
        Write-RunnerLog $Root "ANDROID TOOLCHAIN [$name]: $($provision.Reason)"
        if ($provision.RawOutput) { Write-RunnerLog $Root "PROVISIONING RAW OUTPUT [$name]: $($provision.RawOutput)" }
        if (-not $provision.Success) {
        throw "PROVISIONING_FAILED | Required Unity: $ver | Stage: $($provision.Stage) | Reason: $($provision.Reason)"
    }
    $exe = $provision.Exe

    $entry = [pscustomobject]@{
        name         = $name
        projectPath  = ''          # may build khong co repo goc cua may dev
        gitRemote    = $remote
        unityExe     = $exe
        unityVersion = $ver
        worktreePath = $wt
        buildsPath   = $builds
        drive        = [pscustomobject]@{ mode='none'; folderPath=''; shareUrl=''; rclonePath=''; remote=''; folder=''; rootFolderId=''; makeLink=$true }
        android      = [pscustomobject]@{ keystorePath=''; keyaliasName='' }
    }

    $list = New-Object System.Collections.ArrayList
    foreach ($p in $Root.projects) { if ($p.name -ne $name) { [void]$list.Add($p) } }
    [void]$list.Add($entry)
    $Root.projects = $list.ToArray()
    try { Write-CiConfig $Root } catch {}

    Write-RunnerLog $Root "da dang ky project '$name' voi Unity $ver"
    return (Get-EffectiveConfig $Root $name)
}

function Get-CiUnityVersionAtCommit {
    param([string]$WorktreePath, [string]$Sha)
    $spec = '{0}:ProjectSettings/ProjectVersion.txt' -f $Sha
    $r = Invoke-Git $WorktreePath @('show','--format=',$spec)
    if ($r.ExitCode -ne 0) { throw "Khong doc duoc Unity version tu target commit $Sha`n$($r.Output)" }
    if ($r.Output -match 'm_EditorVersion:\s*(\S+)') { return $Matches[1] }
    throw "Target commit $Sha khong co m_EditorVersion trong ProjectVersion.txt"
}

function Assert-CiJobCredentials {
    param($Root, $Job, $Secrets)
    if ("$($Job.config)" -ne 'release') { return }
    $p = @($Root.projects | Where-Object { "$($_.name)" -eq "$($Job.project)" } | Select-Object -First 1)
    if (-not $p) { throw "CREDENTIALS_REQUIRED | release project '$($Job.project)' is not configured on this agent" }
    try { Ensure-ProjectBuildCredentials -Config (Get-EffectiveConfig $Root "$($Job.project)") -Job $Job -Secrets $Secrets | Out-Null }
    catch { throw "CREDENTIALS_REQUIRED | $($_.Exception.Message)" }
}

function Write-CiPreflightFailureResult {
    param($Root, $Job, [string]$Message, [datetime]$StartedAt, [bool]$Cancelled = $false)
    $stage = 'preflight'
    if ($Message -match '^REMOTE_NOT_TRUSTED|^GIT_FAILURE|^GIT_AUTH_REQUIRED') { $stage = 'git' }
    elseif ($Message -match '^PROVISIONING_FAILED') { $stage = 'provisioning' }
    elseif ($Message -match '^CREDENTIALS_REQUIRED') { $stage = 'credentials' }
    Write-JsonFile (Join-CiPath $Root.ciRoot 'results' ("{0}.json" -f $Job.id)) ([pscustomobject]@{
        id=$Job.id; project=$Job.project; success=$false; cancelled=$Cancelled; branch=$Job.branch
        sha=$Job.sha; shaShort=$Job.shaShort; format=$Job.format; config=$Job.config; developmentBuild=[bool]$Job.developmentBuild
        failureStage=$stage; failReason=$Message; durationSec=[math]::Round(((Get-Date) - $StartedAt).TotalSeconds, 1); finishedAt=(Get-Date).ToString('o')
    })
}

function Update-CiDiscordPhase {
    param([string]$Webhook, [string]$MessageId, $Job, [string]$Phase, [datetime]$StartedAt, [double]$EtaSeconds = 0)
    if (-not $Webhook -or -not $MessageId) { return }
    Update-DiscordBuildProgress -WebhookUrl $Webhook -MessageId $MessageId -Job $Job -Phase $Phase `
        -ElapsedSeconds ((Get-Date) - $StartedAt).TotalSeconds -EtaSeconds $EtaSeconds
}

function Resolve-CiJobConfig {
    param($Root, $Job, [string]$Webhook = '', [string]$MessageId = '', [datetime]$StartedAt)
    $p = $Root.projects | Where-Object { $_.name -eq "$($Job.project)" } | Select-Object -First 1
    if ($p -and (Test-CiWorktreeUsable $p.worktreePath)) {
        $cfg = Get-EffectiveConfig $Root "$($Job.project)"
        Update-CiDiscordPhase -Webhook $Webhook -MessageId $MessageId -Job $Job -Phase 'Dong bo Git' -StartedAt $StartedAt
        try { Sync-Worktree -Config $cfg -Sha "$($Job.sha)" -GitRemote "$($Job.gitRemote)" }
        catch {
            $message = "$($_.Exception.Message)"
            if ($message -match '^GIT_(AUTH_REQUIRED|FAILURE)\s*\|') { throw $message }
            throw "$(Get-CiGitFailureCode $message) | $message"
        }
        try { $ver = Get-CiUnityVersionAtCommit -WorktreePath $cfg.worktreePath -Sha "$($Job.sha)" }
        catch { throw "PREFLIGHT_FAILURE | $($_.Exception.Message)" }
        Write-RunnerLog $Root (Format-UnityEditorResolution $ver)
        Update-CiDiscordPhase -Webhook $Webhook -MessageId $MessageId -Job $Job -Phase "Kiem tra Unity $ver" -StartedAt $StartedAt
        $autoProvision = if (Test-CiHasProp $Root 'autoProvisionUnity') { [bool]$Root.autoProvisionUnity } else { $true }
        Update-CiDiscordPhase -Webhook $Webhook -MessageId $MessageId -Job $Job -Phase 'Cai Unity/Android modules' -StartedAt $StartedAt
        $provision = Ensure-UnityEditor -Version $ver -NeedAndroid $true -AutoInstall $autoProvision
        Write-RunnerLog $Root "ANDROID TOOLCHAIN [$($Job.project)]: $($provision.Reason)"
        if ($provision.RawOutput) { Write-RunnerLog $Root "PROVISIONING RAW OUTPUT [$($Job.project)]: $($provision.RawOutput)" }
        if (-not $provision.Success) { throw "PROVISIONING_FAILED | Required Unity: $ver | Stage: $($provision.Stage) | Reason: $($provision.Reason)" }
        $p.unityVersion = $ver
        $p.unityExe = $provision.Exe
        Write-CiConfig $Root
        return (Get-EffectiveConfig $Root "$($Job.project)")
    }
    return (Register-CiProjectFromJob $Root $Job -Webhook $Webhook -MessageId $MessageId -StartedAt $StartedAt)
}

# Nhip tim cua agent - de may dev biet agent con song hay da chet
function Write-CiHeartbeat {
    param($Root, [string]$State = 'idle', [string]$JobId = '')
    try {
        $dir = Join-CiPath $Root.ciRoot 'agents'
        if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
        Write-JsonFile (Join-CiPath $dir ("{0}.json" -f $Root.agentName)) ([pscustomobject]@{
            name     = $Root.agentName
            state    = $State
            jobId    = $JobId
            canBuild = @($Root.canBuild)
            lastSeen = (Get-Date).ToString('o')
        })
    } catch {}
}

# ------------------------------------------------------------
#  Vong chinh
# ------------------------------------------------------------
if ("$($root.role)" -eq 'client') {
    Write-RunnerLog $root 'May nay dat vai tro client - khong build. Thoat.'
    exit 0
}

$lock = Enter-CiRunnerLock
if (-not $lock) {
    Write-RunnerLog $root 'Da co runner khac dang chay - job van nam trong queue'
    exit 0
}

$stopFlag = Join-CiPath $root.ciRoot 'agent-stop.flag'
$poll     = [int]$root.pollSeconds
if ($poll -lt 2) { $poll = 5 }

try {
    if ($Watch) { Write-RunnerLog $root "AGENT '$($root.agentName)' bat dau - build duoc: $(@($root.canBuild) -join ', ')" }

    while ($true) {
        if ($Watch -and (Test-Path $stopFlag)) {
            Write-RunnerLog $root 'Thay agent-stop.flag - dung agent'
            break
        }

        $queue = @(Get-CiQueue $root)
        $job   = Select-CiJobForAgent $root $queue

        if (-not $job) {
            if (-not $Watch) { break }
            Write-CiHeartbeat $root 'idle'
            Start-Sleep -Seconds $poll
            # nap lai config moi vong: doi cai dat khong phai khoi dong lai agent
            try { $root = Read-CiConfig } catch {}
            continue
        }

        $jobFile = Move-CiJobToProcessing -Config $root -Job $job -AgentName "$($root.agentName)"
        if (-not $jobFile) { continue }
        $job | Add-Member -NotePropertyName _file -NotePropertyValue $jobFile -Force
        $startedAt = Get-Date
        $messageId = if ($webhook) { Send-DiscordBuildStarted -WebhookUrl $webhook -Job $job -EtaSeconds 0 } else { '' }
        Write-CiHeartbeat $root 'preparing' $job.id
        Update-CiDiscordPhase -Webhook $webhook -MessageId $messageId -Job $job -Phase 'Kiem tra credential' -StartedAt $startedAt
        try {
            $secrets = Read-CiSecrets
            Assert-CiJobCredentials -Root $root -Job $job -Secrets $secrets
            if (Test-CiCancelRequested $root $job.id) { throw 'PREPARATION_FAILURE | job cancelled before preparation' }
            $jobCfg = Resolve-CiJobConfig $root $job -Webhook $webhook -MessageId $messageId -StartedAt $startedAt
            if (Test-CiCancelRequested $root $job.id) { throw 'PREPARATION_FAILURE | job cancelled during preparation' }
        } catch {
            $message = $_.Exception.Message
            Write-RunnerLog $root "BO QUA $($job.id): $message"
            $cancelledPrep = $message -match '(?i)cancel|huy'
            Write-CiPreflightFailureResult -Root $root -Job $job -Message $message -StartedAt $startedAt -Cancelled $cancelledPrep
            $discordFailure = $message
            if ($message -match '(PROVISIONING_NETWORK_FAILED[^\r\n]*)') { $discordFailure = $Matches[1] }
            Send-DiscordBuildResult -WebhookUrl $webhook -Job $job -Success $false -Cancelled $cancelledPrep `
                -DurationSeconds ((Get-Date) - $startedAt).TotalSeconds -ErrorSummary $discordFailure -MessageId $messageId
            # day sang failed/ de khong lap vo han tren cung mot job hong
            try {
                $failDir = Join-CiPath $root.ciRoot 'failed'
                if (-not (Test-Path $failDir)) { New-Item -ItemType Directory -Force -Path $failDir | Out-Null }
                Move-Item -LiteralPath $job._file -Destination (Join-CiPath $failDir ("{0}.json" -f $job.id)) -Force
            } catch {}
            continue
        }

        Write-CiHeartbeat $root 'building' $job.id
        Invoke-CiJob -Config $jobCfg -Job $job -Secrets $secrets -Webhook $webhook -JobFile $jobFile `
            -MessageId $messageId -StartedAt $startedAt -WorktreeSynced | Out-Null
        Write-CiHeartbeat $root 'idle'

        if ($Once) { break }
    }
} catch {
    Write-RunnerLog $root "RUNNER LOI: $($_.Exception.Message)"
} finally {
    Exit-CiRunnerLock $lock
}
