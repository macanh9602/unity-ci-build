# ============================================================
#  ci.ps1 - dong lenh dieu khien
#    .\ci.ps1 build                          APK dev, project mac dinh
#    .\ci.ps1 build -Project SE-001          chon project khac
#    .\ci.ps1 build -Format aab -Config release
#    .\ci.ps1 projects                       liet ke project da khai bao
#    .\ci.ps1 status                         dang build gi, xong cai gi
#    .\ci.ps1 queue                          dang xep hang nhung gi
#    .\ci.ps1 open                           mo thu muc chua file build
#    .\ci.ps1 config                         xem / doi duong dan
#    .\ci.ps1 doctor                         kiem tra lai he thong
# ============================================================
[CmdletBinding()]
param(
    [Parameter(Position=0)]
    [ValidateSet('build','cancel','status','queue','projects','branches','open','config','doctor','help')]
    [string]$Command = 'help',

    [Parameter(Position=1)][string]$JobId = '',
    [switch]$All,

    [string]$Project = '',
    [string]$Branch  = '',
    [ValidateSet('apk','aab')]    [string]$Format = 'apk',
    [ValidateSet('dev','release')][string]$Config = 'dev',
    [switch]$Force,
    [switch]$Local,    # ep build ngay tai may nay, khong hoi
    [switch]$Queue     # ep de trong queue cho may build, khong hoi
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib\Common.ps1')
. (Join-Path $PSScriptRoot 'lib\Queue.ps1')
Set-ConsoleUtf8

if (-not (Test-CiInstalled)) {
    Write-Bad 'Chua cai dat. Chay install.bat truoc da.'
    exit 1
}
$root  = Read-CiConfig
$paths = Get-CiPaths $root

switch ($Command) {

'build' {
    $proj = Get-CiProject $root $Project
    if (-not $proj) { Write-Bad 'Chua co project nao. Chay install.bat.'; exit 1 }
    if ($Project -and $proj.name -ne $Project) {
        Write-Bad "Khong co project ten '$Project'. Dang co: $((Get-CiProjectNames $root) -join ', ')"
        exit 1
    }

    Write-Title "Dat lenh build - $($proj.name)"

    $git = Get-GitInfo $proj.projectPath
    if (-not $git) { Write-Bad "Khong doc duoc git tai $($proj.projectPath)"; exit 1 }

    # Chon branch khac ma KHONG doi working copy - ban van code tiep binh thuong
    if ($Branch -and $Branch -ne $git.Branch) {
        Invoke-Git $proj.projectPath @('fetch','--quiet') | Out-Null
        $tip = Resolve-CiBranchTip $proj.projectPath $Branch
        if (-not $tip) {
            Write-Bad "Khong tim thay branch '$Branch'"
            Write-Info 'Cac branch dang co:'
            foreach ($b in @(Get-CiBranches $proj.projectPath)) { Write-Info "  $b" }
            exit 1
        }
        $git = $tip
        Write-Ok "Build branch '$Branch' - working copy cua ban giu nguyen"
    }

    Write-Info "Branch  : $($git.Branch)"
    Write-Info "Commit  : $($git.ShaShort)  $($git.Subject)"
    Write-Info "Loai    : $($Format.ToUpper()) / $Config"

    if ($git.IsDirty) {
        Write-Host ''
        Write-Miss "Co $($git.DirtyCount) file thay doi CHUA COMMIT."
        Write-Hint 'Build lay dung commit HEAD, nen nhung thay doi nay SE KHONG co trong ban build.'
        if (-not $Force) {
            if (-not (Read-YesNo 'Van build tu HEAD?' $true)) { Write-Info 'Da huy.'; exit 0 }
        }
    }

    # Doi branch so voi lan build truoc thuong la nham, khong phai co y
    $lastBranch = Get-CiLastBuiltBranch $root $proj.name
    if ($lastBranch -and $lastBranch -ne $git.Branch -and -not $Force) {
        Write-Host ''
        Write-Miss "Lan build truoc cua $($proj.name) la branch '$lastBranch', gio dang o '$($git.Branch)'."
        if (-not (Read-YesNo "Van build branch '$($git.Branch)'?" $true)) { Write-Info 'Da huy.'; exit 0 }
    }

    # versionCode = so commit -> hai branch rat de trung nhau
    $clash = Get-CiVersionCodeConflict -Config $root -ProjectName $proj.name -VersionCode $git.CommitCount -Sha $git.Sha
    if ($clash) {
        Write-Host ''
        Write-Miss "versionCode $($git.CommitCount) da dung cho commit $($clash.shaShort) (branch $($clash.branch))."
        Write-Hint 'Android coi hai ban nay la MOT: cai chong len may test se KHONG update.'
        Write-Hint 'Go ban cu tren may test truoc khi cai ban moi, neu khong ban se test nham ban cu.'
    }

    # May build clone code tu remote -> commit chua push la no khong the thay.
    # Kiem tra ngay tai day, dung de build chay roi moi chet vi ly do nay.
    $remoteUrl = Get-GitRemoteUrl $proj.projectPath
    if (-not (Test-CiIsAgent $root)) {
        if (-not $remoteUrl) {
            Write-Bad 'Repo nay chua co remote git.'
            Write-Hint 'May build lay code tu remote. Them remote roi push truoc: git remote add origin <url>'
            exit 1
        }
        Write-Info 'Dang kiem tra commit da push chua...'
        if (-not (Test-CiShaOnRemote -RepoPath $proj.projectPath -Sha $git.Sha)) {
            Write-Host ''
            Write-Bad "Commit $($git.ShaShort) chua co tren remote."
            Write-Hint 'May build clone tu remote nen se khong thay commit nay.'
            Write-Hint "Chay:  git push"
            exit 1
        }
        Write-Ok 'Commit da co tren remote'
    }

    # ---------- Build o dau? ----------
    $buildHere  = Test-CiIsAgent $root      # standalone / agent -> luon tai cho
    $cap        = $null

    if (-not $buildHere) {
        $live = @(Get-CiLiveAgents $root 'android')

        if ($live.Count -gt 0) {
            Write-Ok ("May build san sang: {0}" -f (($live | ForEach-Object { $_.name }) -join ', '))
        }
        elseif ($Local)  { $buildHere = $true }
        elseif ($Queue)  { Write-Info 'De job trong queue theo yeu cau.' }
        else {
            # Khong tu y build tai cho: may dev se bi an het CPU ma khong hieu vi sao
            $cap = Test-CiCanBuildLocally $root $proj
            Write-Host ''
            Write-Miss 'Khong thay may build nao dang chay.'
            Write-Host ''
            Write-Host '    [1] De job trong queue - may build bat len la tu chay' -ForegroundColor Gray
            if ($cap.Ok) {
                if ($cap.NeedsWorktree) {
                    Write-Host '    [2] Build ngay tai may nay' -ForegroundColor Yellow
                    Write-Hint 'Lan dau phai tao ban sao project + import lai toan bo asset:'
                    Write-Hint 'mat 20-40 phut va an gan het CPU. Doi may build co khi con nhanh hon.'
                } else {
                    Write-Host '    [2] Build ngay tai may nay (da co san ban sao project)' -ForegroundColor Yellow
                }
            } else {
                Write-Host ('    [2] Build tai may nay - KHONG duoc: ' + $cap.Reason) -ForegroundColor DarkGray
            }
            Write-Host ''
            $pick = Read-Choice 'Chon' '1'
            if ($pick -eq '2') {
                if (-not $cap.Ok) { Write-Bad $cap.Reason; exit 1 }
                $buildHere = $true
            }
        }
    }

    # Build tai may client -> ghim job cho may nay, khong de agent khac cuop
    $targetAgent = ''
    if ($buildHere -and -not (Test-CiIsAgent $root)) { $targetAgent = "$($root.agentName)" }

    # Tao ban sao project neu chon build tai cho ma chua co
    if ($buildHere -and -not (Test-Path (Join-CiPath $proj.worktreePath '.git'))) {
        Write-Info 'Dang tao ban sao project (worktree)...'
        $r = Invoke-Git $proj.projectPath @('worktree','add','--detach',$proj.worktreePath,'HEAD')
        if ($r.ExitCode -eq 0) { Write-Ok "Da tao: $($proj.worktreePath)" }
        else {
            Write-Bad 'Tao worktree that bai:'
            Write-Info $r.Output
            exit 1
        }
    }

    $job = Add-CiJob -Config $root -Sha $git.Sha -Branch $git.Branch -Subject $git.Subject `
                     -Format $Format -BuildConfig $Config -By 'cli' -VersionCode $git.CommitCount `
                     -Project $proj.name -Platform 'android' -TargetAgent $targetAgent `
                     -GitRemote $remoteUrl -UnityVersion "$($proj.unityVersion)"

    Write-Host ''
    Write-Ok "Da xep hang: $($job.id)  [$($proj.name)]"

    if ($buildHere) {
        if (Test-CiRunnerBusy) {
            Write-Info 'Dang co build khac chay tren may nay - job nay se chay tiep sau.'
        } else {
            Start-CiRunner
            Write-Info 'Build chay nen ngay tai may nay.'
        }
    } elseif ((@(Get-CiLiveAgents $root 'android')).Count -gt 0) {
        Write-Info 'Da gui sang may build.'
    } else {
        Write-Info 'Job nam trong queue - may build bat len la tu chay.'
        Write-Hint 'Tren may build: bat agent.bat hoac kiem tra Scheduled Task.'
        Write-Hint 'Muon build ngay tai day: .\ci.ps1 build -Local'
    }
    Write-Info "Theo doi: .\ci.ps1 status"
}

'cancel' {
    Write-Title 'Huy build'
    $q   = @(Get-CiQueue $root)
    $run = @(Get-CiRunningJobs $root)

    if ($All) {
        $n = 0
        foreach ($j in $q)   { if (Remove-CiQueuedJob $root $j.id) { Write-Ok "Da bo khoi queue: $($j.id)"; $n++ } }
        foreach ($j in $run) { Request-CiCancel $root $j.id; Write-Ok "Da yeu cau dung: $($j.id) [$($j._agent)]"; $n++ }
        if ($n -eq 0) { Write-Info 'Khong co gi de huy.' }
        else { Write-Info 'Build dang chay se dung trong vai giay.' }
        break
    }

    if (-not $JobId) {
        if ($q.Count -eq 0 -and $run.Count -eq 0) { Write-Info 'Khong co job nao.'; break }
        Write-Info 'Chua chon job nao. Dang co:'
        foreach ($j in $run) { Write-Host ('  DANG CHAY  ' + $j.id) -ForegroundColor Yellow -NoNewline; Write-Host ("  [{0}]  {1}@{2}" -f $j._agent, $j.branch, $j.shaShort) }
        foreach ($j in $q)   { Write-Host ('  DANG CHO   ' + $j.id) -ForegroundColor Gray   -NoNewline; Write-Host ("  {0}@{1}" -f $j.branch, $j.shaShort) }
        Write-Host ''
        Write-Hint '.\ci.ps1 cancel <id>    huy mot job'
        Write-Hint '.\ci.ps1 cancel -All    huy tat ca'
        break
    }

    $inRun = $run | Where-Object { $_.id -eq $JobId } | Select-Object -First 1
    if ($inRun) {
        Request-CiCancel $root $JobId
        Write-Ok "Da yeu cau dung $JobId tren $($inRun._agent)"
        Write-Info 'Runner nhat duoc trong vai giay roi tu giet Unity.'
        break
    }
    if (Remove-CiQueuedJob $root $JobId) { Write-Ok "Da bo khoi queue: $JobId"; break }

    Write-Bad "Khong tim thay job '$JobId'"
    Write-Hint 'Chay .\ci.ps1 cancel (khong kem id) de xem danh sach.'
}

'branches' {
    $proj = Get-CiProject $root $Project
    if (-not $proj) { Write-Bad 'Chua co project nao.'; exit 1 }
    Write-Title "Branch - $($proj.name)"
    $cur = (Get-GitInfo $proj.projectPath)
    foreach ($b in @(Get-CiBranches $proj.projectPath)) {
        if ($cur -and $b -eq $cur.Branch) { Write-Host ('  * ' + $b) -ForegroundColor Green }
        else                              { Write-Host ('    ' + $b) -ForegroundColor Gray }
    }
    Write-Host ''
    Write-Info '* = branch working copy dang dung'
    Write-Hint '.\ci.ps1 build -Branch <ten>   build branch khac, khong doi working copy'
}

'projects' {
    Write-Title 'Project da khai bao'
    $names = @(Get-CiProjectNames $root)
    if ($names.Count -eq 0) { Write-Info 'Chua co project nao.'; break }
    foreach ($p in $root.projects) {
        $star = if ($p.name -eq $root.defaultProject) { '*' } else { ' ' }
        Write-Host ("  {0} {1}" -f $star, $p.name) -ForegroundColor White
        Write-Hint $p.projectPath
        Write-Hint "Unity $($p.unityVersion)"
    }
    Write-Host ''
    Write-Info "* = mac dinh khi khong go -Project"
    Write-Info "Them project moi: chay install.bat"
}

'status' {
    Write-Title 'Trang thai'

    Write-Info "Vai tro may nay: $($root.role)"

    $agents = @(Get-CiAgents $root)
    if ($agents.Count -gt 0) {
        Write-Host ''
        Write-Host '  MAY BUILD' -ForegroundColor Cyan
        foreach ($a in $agents) {
            if ($a.Alive) {
                $txt = if ($a.state -eq 'building') { "dang build $($a.jobId)" } else { 'ranh' }
                Write-Ok ("{0,-16} {1}" -f $a.name, $txt)
            } else {
                Write-Miss ("{0,-16} khong thay phan hoi {1} truoc" -f $a.name, (Format-Duration $a.AgeSeconds))
            }
        }
        Write-Host ''
    } elseif (-not (Test-CiIsAgent $root)) {
        Write-Miss 'Chua thay may build nao bao danh.'
    }

    if (Test-CiIsAgent $root) {
        if (Test-CiRunnerBusy) { Write-Host '  May nay: ' -NoNewline; Write-Host 'DANG BUILD' -ForegroundColor Yellow }
        else                   { Write-Host '  May nay: ' -NoNewline; Write-Host 'RANH' -ForegroundColor Green }
    }

    $q = @(Get-CiQueue $root)
    Write-Info "Dang xep hang: $($q.Count) job"

    $recent = @(Get-ChildItem -Path $paths.Results -Filter '*.json' -ErrorAction SilentlyContinue |
                Sort-Object Name -Descending | Select-Object -First 10)
    if ($recent.Count -eq 0) { Write-Info 'Chua co build nao.'; break }

    Write-Host ''
    Write-Host '  KET QUA GAN DAY' -ForegroundColor Cyan
    Write-Host ('  ' + ('-' * 62)) -ForegroundColor DarkCyan
    foreach ($f in $recent) {
        $r = Read-JsonFile $f.FullName
        if (-not $r) { continue }
        $mark  = if ($r.success) { 'OK  ' } elseif ($r.cancelled) { 'HUY ' } else { 'HONG' }
        $color = if ($r.success) { 'Green' } elseif ($r.cancelled) { 'DarkGray' } else { 'Red' }
        Write-Host ('  {0}  ' -f $mark) -ForegroundColor $color -NoNewline
        Write-Host ('{0,-18} {1}@{2}  {3}/{4}  {5}' -f `
            "$($r.project)", $r.branch, $r.shaShort, "$($r.format)".ToUpper(), $r.config, (Format-Duration $r.durationSec))
        if ($r.success -and $r.outputPath) { Write-Hint (Split-Path -Leaf $r.outputPath) }
        elseif ($r.failReason)             { Write-Hint $r.failReason }
    }
}

'queue' {
    Write-Title 'Hang doi'
    $q = @(Get-CiQueue $root)
    if ($q.Count -eq 0) { Write-Info 'Trong.'; break }
    foreach ($j in $q) {
        Write-Info ('{0}  [{1}]  {2}@{3}  {4}/{5}  (goi tu {6})' -f `
            $j.id, $j.project, $j.branch, $j.shaShort, "$($j.format)".ToUpper(), $j.config, $j.by)
    }
}

'open' {
    $eff = Get-EffectiveConfig $root $Project
    if (Test-Path $eff.buildsPath) { Start-Process explorer.exe $eff.buildsPath }
    else { Write-Bad "Chua co thu muc $($eff.buildsPath)" }
}

'config' {
    Write-Title 'Cau hinh chung'
    Write-Info "Thu muc CI   : $($root.ciRoot)"
    Write-Info "Chua lai core: $($root.reserveCoresForEditor)"
    Write-Info "Timeout      : $($root.buildTimeoutMinutes) phut"
    Write-Info "Discord      : $(if ($root.discord.enabled) { 'bat' } else { 'tat' })"

    foreach ($p in $root.projects) {
        Write-Host ''
        Write-Host ("  PROJECT: " + $p.name) -ForegroundColor Cyan
        Write-Info "  Duong dan  : $($p.projectPath)"
        Write-Info "  Unity      : $($p.unityVersion)"
        Write-Info "  Worktree   : $($p.worktreePath)"
        Write-Info "  File build : $($p.buildsPath)"
        $mode = "$($p.drive.mode)"
        switch ($mode) {
            'folder' {
                Write-Info "  Copy den   : $($p.drive.folderPath)"
                if ($p.drive.shareUrl) { Write-Info "  Link share : $($p.drive.shareUrl)" }
            }
            'rclone' {
                Write-Info "  Upload den : $($p.drive.remote)$($p.drive.folder)"
                if ($p.drive.rootFolderId) { Write-Info "  Ghim folder: $($p.drive.rootFolderId)" }
            }
            default  { Write-Info '  Copy den   : (khong bat)' }
        }
    }

    Write-Host ''
    Write-Info 'Doi duong dan thi sua thang trong config.json roi luu - khong can cai lai.'
    Write-Hint 'projects[].drive.folderPath   = noi copy den (che do folder)'
    Write-Hint 'projects[].drive.rootFolderId = ID folder Drive muon ghim (lay tu link)'
    Write-Hint 'projects[].buildsPath         = noi chua ban goc tren may nay'
    Write-Hint 'defaultProject                = project dung khi khong go -Project'
    Write-Host ''
    if (Read-YesNo 'Mo config.json ngay?' $true) { Start-Process notepad.exe (Get-ConfigPath) }
}

'doctor' {
    & (Join-Path $PSScriptRoot 'setup.ps1') -CheckOnly
}

default {
    Write-Title 'Unity CI Build'
    Write-Host @'
  .\ci.ps1 build                        build APK ban dev (project mac dinh)
  .\ci.ps1 build -Project SE-001        build project khac
  .\ci.ps1 build -Branch release/1.2    build branch khac, KHONG doi working copy
  .\ci.ps1 branches                     liet ke branch
  .\ci.ps1 build -Local                 ep build ngay tai may nay
  .\ci.ps1 build -Queue                 ep de trong queue, khong hoi
  .\ci.ps1 build -Format aab -Config release
  .\ci.ps1 projects                     liet ke project da khai bao
  .\ci.ps1 status                       xem dang build gi / ket qua gan day
  .\ci.ps1 cancel                       xem job dang cho / dang chay
  .\ci.ps1 cancel <id>                  huy mot job
  .\ci.ps1 cancel -All                  huy tat ca
  .\ci.ps1 queue                        xem hang doi
  .\ci.ps1 open                         mo thu muc chua file build
  .\ci.ps1 config                       xem / doi duong dan, khong can cai lai
  .\ci.ps1 doctor                       kiem tra lai he thong

  Hoac double-click build.bat de build nhanh ban dev.
'@ -ForegroundColor Gray
}

}
