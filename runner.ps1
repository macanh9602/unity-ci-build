# ============================================================
#  runner.ps1 - bo phan thuc su build. Chay nen, mot job mot luc.
#  Khong goi truc tiep - ci.ps1 / Unity Editor tu spawn file nay.
# ============================================================
[CmdletBinding()]
param([switch]$Once)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib\Common.ps1')
. (Join-Path $PSScriptRoot 'lib\Queue.ps1')
. (Join-Path $PSScriptRoot 'lib\UnityLog.ps1')
. (Join-Path $PSScriptRoot 'lib\Discord.ps1')
. (Join-Path $PSScriptRoot 'lib\Drive.ps1')
Set-ConsoleUtf8

$root    = Read-CiConfig          # cau hinh goc: cai dat chung + danh sach project
$secrets = Read-CiSecrets
$paths   = Get-CiPaths $root
Initialize-CiDirs $root

$webhook = ''
if ($root.discord -and $root.discord.enabled) { $webhook = Get-Secret $secrets 'discordWebhook' }

# ------------------------------------------------------------
function Sync-Worktree {
    param($Config, [string]$Sha)
    $wt = $Config.worktreePath
    if (-not (Test-CiRootValid $wt)) {
        throw ("Cau hinh hong: worktreePath '$wt' khong phai duong dan tuyet doi. " +
               "Chay lai install.bat va nhap duong dan day du nhu E:\UnityCI (dung go moi chu 'E').")
    }
    if (-not (Test-Path $wt)) {
        throw ("Khong tim thay worktree: $wt" + [Environment]::NewLine +
               "Chay lai install.bat de tao lai.")
    }

    # --force + reset --hard: bat buoc, vi build truoc do da sua ProjectSettings.asset
    # (bundleVersionCode, keystore...) -> checkout thuong se bi tu choi.
    $r = Invoke-Git $wt @('checkout','--detach','--force',$Sha)
    if ($r.ExitCode -ne 0) { throw "git checkout that bai:`n$($r.Output)" }

    $r = Invoke-Git $wt @('reset','--hard',$Sha)
    if ($r.ExitCode -ne 0) { throw "git reset that bai:`n$($r.Output)" }

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
            return [pscustomobject]@{ ExitCode = -1; TimedOut = $true; Phase = $tracker.Name }
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
    return [pscustomobject]@{ ExitCode = $proc.ExitCode; TimedOut = $false; Phase = $tracker.Name }
}

# ------------------------------------------------------------
function Invoke-CiJob {
    param($Config, $Job, $Secrets, [string]$Webhook)

    $paths   = Get-CiPaths $Config
    Initialize-CiDirs $Config
    $started = Get-Date
    $logPath = Join-CiPath $paths.Logs   ("{0}.log"        -f $Job.id)
    $errPath = Join-CiPath $paths.Logs   ("{0}.errors.txt" -f $Job.id)
    $jobFile = Move-CiJobToProcessing $Config $Job

    Write-RunnerLog $Config "BAT DAU $($Job.id)  [$($Config.projectName)]  $($Job.branch)@$($Job.shaShort)  $($Job.format)/$($Job.config)"

    # Uoc tinh tu cac lan build thanh cong truoc do cua dung loai nay
    $eta = Get-CiEtaSeconds -Config $Config -ProjectName $Config.projectName `
                            -Format "$($Job.format)" -BuildConfig "$($Job.config)"
    $msgId = ''
    if ($Webhook) { $msgId = Send-DiscordBuildStarted -WebhookUrl $Webhook -Job $Job -EtaSeconds $eta }

    $success = $false; $failReason = ''; $sizeBytes = 0; $link = ''; $errInfo = $null

    try {
        Sync-Worktree -Config $Config -Sha $Job.sha
        Copy-CiScript  -Config $Config

        # versionCode = so commit tinh den sha nay. Deterministic, khong can file state.
        if (-not $Job.versionCode -or $Job.versionCode -le 0) {
            $c = (& git -C $Config.worktreePath rev-list --count $Job.sha 2>$null)
            if ($LASTEXITCODE -eq 0 -and $c) { $Job.versionCode = [int]("$c".Trim()) }
        }

        $ext = if ($Job.format -eq 'aab') { 'aab' } else { 'apk' }
        $Job.outputPath = Join-CiPath $paths.Builds ("{0}-{1}-{2}.{3}" -f $Job.id, $Job.shaShort, $Job.config, $ext)
        $Job | Add-Member -NotePropertyName resultPath -NotePropertyValue (Join-CiPath $paths.Logs ("{0}.unity-result.json" -f $Job.id)) -Force
        Write-JsonFile $jobFile $Job

        $run = Invoke-UnityBuild -Config $Config -Job $Job -JobFile $jobFile -LogPath $logPath -Secrets $Secrets `
                                 -Webhook $Webhook -MessageId $msgId -EtaSeconds $eta -StartedAt $started

        if ($run.TimedOut) {
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
            Write-RunnerLog $Config "dua file di that bai: $($up.Message)"
        }
    }

    if (-not $success) {
        $errInfo = Write-CiErrorReport -LogPath $logPath -OutPath $errPath -Job $Job -Reason $failReason
    }

    $result = [pscustomobject]@{
        id          = $Job.id
        project     = $Config.projectName
        success     = $success
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
        durationSec = [math]::Round($duration, 1)
        finishedAt  = (Get-Date).ToString('o')
        failReason  = $failReason
        logPath     = $logPath
        errorsPath  = $(if ($success) { '' } else { $errPath })
    }
    Write-JsonFile (Join-CiPath $paths.Results ("{0}.json" -f $Job.id)) $result
    Remove-Item -LiteralPath $jobFile -Force -ErrorAction SilentlyContinue

    if ($Webhook) {
        # Uu tien loi compile (cu the hon). Neu build chet truoc khi Unity kip chay
        # thi khong co loi compile nao - luc do phai day failReason len,
        # neu khong Discord bao "that bai" ma khong noi vi sao.
        $summaryText = Get-CiErrorSummary $errInfo
        if (-not $summaryText) { $summaryText = $failReason }

        Send-DiscordBuildResult -WebhookUrl $Webhook -Job $Job -Success $success `
            -DurationSeconds $duration -OutputPath $Job.outputPath -SizeBytes $sizeBytes `
            -ShareLink $link -ErrorSummary $summaryText `
            -ErrorFile $(if ($success) { '' } else { Split-Path -Leaf $errPath }) `
            -MessageId $msgId
    }

    $tag = if ($success) { 'XONG' } else { 'HONG' }
    Write-RunnerLog $Config "$tag  $($Job.id)  [$($Config.projectName)]  $(Format-Duration $duration)  $failReason"
    return $success
}

# ------------------------------------------------------------
#  Vong chinh
# ------------------------------------------------------------
$lock = Enter-CiRunnerLock
if (-not $lock) {
    Write-RunnerLog $root 'Da co runner khac dang chay - job van nam trong queue'
    exit 0
}

try {
    while ($true) {
        $queue = @(Get-CiQueue $root)
        if ($queue.Count -eq 0) { break }
        $job = $queue[0]

        # Mot queue chung cho moi project, mot runner, mot khoa.
        # Co y nhu vay: hai ban Unity build cung luc tren mot may thi
        # giành CPU va o cung, ca hai deu cham hon la chay lan luot.
        try {
            $jobCfg = Get-EffectiveConfig $root "$($job.project)"
        } catch {
            Write-RunnerLog $root "BO QUA $($job.id): khong tra duoc project '$($job.project)'"
            Remove-Item -LiteralPath $job._file -Force -ErrorAction SilentlyContinue
            continue
        }

        Invoke-CiJob -Config $jobCfg -Job $job -Secrets $secrets -Webhook $webhook | Out-Null
        if ($Once) { break }
    }
} catch {
    Write-RunnerLog $root "RUNNER LOI: $($_.Exception.Message)"
} finally {
    Exit-CiRunnerLock $lock
}
