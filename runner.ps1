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
            throw "Clone that bai tu: $remote`n$cloneOutput"
        }
    }

    # Clone/worktree co san van co the chua co commit moi nhat
    $r = Invoke-Git $wt @('fetch','--all','--prune','--quiet')
    if ($r.ExitCode -ne 0) { Write-RunnerLog $Config "canh bao: git fetch exit $($r.ExitCode)" }

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
        return
    }

    $initialize = -not $previous
    if ($initialize) {
        $reason = if ($libraryExists) { 'chua co fingerprint' } else { 'Library not present' }
        Write-RunnerLog $Config "CACHE INITIALIZE [$($Config.projectName)] ($reason)"
    } elseif ($previous -ne $current) {
        Write-RunnerLog $Config "CACHE MISS [$($Config.projectName)] reason=fingerprint changed - xoa Library/Temp/obj"
    } else {
        Write-RunnerLog $Config "CACHE MISS [$($Config.projectName)] reason=Library missing - xoa Library/Temp/obj"
    }
    foreach ($dir in @($library, $temp, $obj)) {
        if (Test-Path -LiteralPath $dir) {
            Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction Stop
        }
    }

    return [pscustomobject]@{ Fingerprint = $current; Path = $fpPath }
}

function Save-CiUnityCacheFingerprint {
    param($CacheState, $Config)
    if (-not $CacheState -or -not $CacheState.Fingerprint -or -not $CacheState.Path) { return }
    Set-Content -LiteralPath $CacheState.Path -Value $CacheState.Fingerprint -Encoding ASCII
    Write-RunnerLog $Config "CACHE FINGERPRINT SAVED [$($Config.projectName)] fp=$($CacheState.Fingerprint.Substring(0,12))"
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

    # Nhuong CPU cho Editor: uu tien thap + chua lai vai core
    try { $proc.PriorityClass = [System.Diagnostics.ProcessPriorityClass]::BelowNormal } catch {}
    try {
        $total   = [Environment]::ProcessorCount
        $reserve = [int]$Config.reserveCoresForEditor
        if ($reserve -gt 0 -and $total -gt $reserve -and $total -le 63) {
            $mask = 0
            for ($i = 0; $i -lt ($total - $reserve); $i++) { $mask = $mask -bor (1 -shl $i) }
            $proc.ProcessorAffinity = [IntPtr]$mask
        }
    } catch {}

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
            return [pscustomobject]@{ Started = $true; ExitCode = -1; TimedOut = $true; Cancelled = $false; Phase = $tracker.Name }
        }

        # Nguoi dung bam huy -> giet Unity ngay, khong doi het timeout
        if (Test-CiCancelRequested $Config $Job.id) {
            try { $proc.Kill() } catch {}
            try { $proc.WaitForExit(15000) | Out-Null } catch {}
            return [pscustomobject]@{ Started = $true; ExitCode = -2; TimedOut = $false; Cancelled = $true; Phase = $tracker.Name }
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
    return [pscustomobject]@{ Started = $true; ExitCode = $proc.ExitCode; TimedOut = $false; Cancelled = $false; Phase = $tracker.Name }
}

# ------------------------------------------------------------
function Invoke-CiJob {
    param($Config, $Job, $Secrets, [string]$Webhook)

    $paths   = Get-CiPaths $Config
    Initialize-CiDirs $Config
    $started = Get-Date
    $logPath = Join-CiPath $paths.Logs   ("{0}.log"        -f $Job.id)
    $errPath = Join-CiPath $paths.Logs   ("{0}.errors.txt" -f $Job.id)
    $jobFile = Move-CiJobToProcessing -Config $Config -Job $Job -AgentName "$($Config.agentName)"
    if (-not $jobFile) {
        Write-RunnerLog $Config "BO QUA $($Job.id): agent khac da nhan truoc"
        return $false
    }

    Write-RunnerLog $Config "BAT DAU $($Job.id)  [$($Config.projectName)]  $($Job.branch)@$($Job.shaShort)  $($Job.format)/$($Job.config)"

    # Uoc tinh tu cac lan build thanh cong truoc do cua dung loai nay
    $eta = Get-CiEtaSeconds -Config $Config -ProjectName $Config.projectName `
                            -Format "$($Job.format)" -BuildConfig "$($Job.config)"
    $msgId = ''
    if ($Webhook) { $msgId = Send-DiscordBuildStarted -WebhookUrl $Webhook -Job $Job -EtaSeconds $eta }

    $success = $false; $cancelled = $false; $failReason = ''; $sizeBytes = 0; $link = ''; $errInfo = $null
    $publishError = ''

    try {
        # Huy ngay tu truoc khi Unity kip chay
        if (Test-CiCancelRequested $Config $Job.id) {
            $cancelled = $true
            throw 'Da huy truoc khi build bat dau'
        }
        Sync-Worktree -Config $Config -Sha $Job.sha -GitRemote "$($Job.gitRemote)"
        $cacheState = Sync-CiUnityCache -Config $Config
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
        $Job.outputPath = Join-CiPath $paths.Builds ("{0}-{1}-{2}-{3}.{4}" -f $Job.id, $brSafe, $Job.shaShort, $Job.config, $ext)
        $Job | Add-Member -NotePropertyName resultPath -NotePropertyValue (Join-CiPath $paths.Logs ("{0}.unity-result.json" -f $Job.id)) -Force
        Write-JsonFile $jobFile $Job

        $run = Invoke-UnityBuild -Config $Config -Job $Job -JobFile $jobFile -LogPath $logPath -Secrets $Secrets `
                                 -Webhook $Webhook -MessageId $msgId -EtaSeconds $eta -StartedAt $started

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
        by          = $Job.by
        versionCode = $Job.versionCode
        outputPath  = $(if ($success) { $Job.outputPath } else { '' })
        sizeBytes   = $sizeBytes
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
    param($Root, $Job)

    $name = "$($Job.project)"
    if (-not $name) { throw "Job khong co ten project" }

    $wt     = Join-CiPath $Root.ciRoot 'worktree' $name
    $builds = Join-CiPath $Root.ciRoot 'builds'   $name
    $remote = "$($Job.gitRemote)"

    if (-not (Test-Path (Join-CiPath $wt '.git'))) {
        if (-not $remote) { throw "Project '$name' chua duoc cau hinh va job khong kem gitRemote" }
        Write-RunnerLog $Root "tu nhan project moi '$name' - dang clone tu $remote"
        $parent = Split-Path -Parent $wt
        if ($parent -and -not (Test-Path $parent)) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
        $old = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
        try { & git clone --quiet $remote $wt 2>&1 | Out-Null } finally { $ErrorActionPreference = $old }
        if (-not (Test-Path (Join-CiPath $wt '.git'))) { throw "Clone that bai tu: $remote" }
    }

    $ver = Get-ProjectUnityVersion $wt
    if (-not $ver) { $ver = "$($Job.unityVersion)" }
    $exe = Resolve-UnityExe $ver
    if (-not $exe) {
        throw ("May nay chua cai Unity $ver (project '$name' can ban do). " +
               "Mo Unity Hub cai dung ban, kem Android Build Support.")
    }

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

function Resolve-CiJobConfig {
    param($Root, $Job)
    $p = $Root.projects | Where-Object { $_.name -eq "$($Job.project)" } | Select-Object -First 1
    if ($p -and $p.unityExe -and (Test-Path $p.unityExe) -and (Test-Path (Join-CiPath $p.worktreePath '.git'))) {
        return (Get-EffectiveConfig $Root "$($Job.project)")
    }
    return (Register-CiProjectFromJob $Root $Job)
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

        try {
            $jobCfg = Resolve-CiJobConfig $root $job
        } catch {
            Write-RunnerLog $root "BO QUA $($job.id): $($_.Exception.Message)"
            # day sang failed/ de khong lap vo han tren cung mot job hong
            try {
                $failDir = Join-CiPath $root.ciRoot 'failed'
                if (-not (Test-Path $failDir)) { New-Item -ItemType Directory -Force -Path $failDir | Out-Null }
                Move-Item -LiteralPath $job._file -Destination (Join-CiPath $failDir ("{0}.json" -f $job.id)) -Force
            } catch {}
            continue
        }

        Write-CiHeartbeat $root 'building' $job.id
        Invoke-CiJob -Config $jobCfg -Job $job -Secrets $secrets -Webhook $webhook | Out-Null
        Write-CiHeartbeat $root 'idle'

        if ($Once) { break }
    }
} catch {
    Write-RunnerLog $root "RUNNER LOI: $($_.Exception.Message)"
} finally {
    Exit-CiRunnerLock $lock
}
