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
    [ValidateSet('build','status','queue','projects','open','config','doctor','help')]
    [string]$Command = 'help',

    [string]$Project = '',
    [ValidateSet('apk','aab')]    [string]$Format = 'apk',
    [ValidateSet('dev','release')][string]$Config = 'dev',
    [switch]$Force
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

    $job = Add-CiJob -Config $root -Sha $git.Sha -Branch $git.Branch -Subject $git.Subject `
                     -Format $Format -BuildConfig $Config -By 'cli' -VersionCode $git.CommitCount `
                     -Project $proj.name -Platform 'android' `
                     -GitRemote $remoteUrl -UnityVersion "$($proj.unityVersion)"

    Write-Host ''
    Write-Ok "Da xep hang: $($job.id)  [$($proj.name)]"

    if (Test-CiIsAgent $root) {
        if (Test-CiRunnerBusy) {
            Write-Info 'Dang co build khac chay - job nay se tu chay tiep sau.'
        } else {
            Start-CiRunner
            Write-Info 'Runner da khoi dong chay nen. Ban cu lam viec tiep binh thuong.'
        }
    } else {
        $agents = @(Get-CiAgents $root) | Where-Object { $_.Alive -and (@($_.canBuild) -contains 'android') }
        if ($agents.Count -gt 0) {
            Write-Info ("Da gui sang may build: {0}" -f (($agents | ForEach-Object { $_.name }) -join ', '))
        } else {
            Write-Miss 'Khong thay may build nao dang chay.'
            Write-Hint 'Job van nam trong queue, agent bat len la chay tiep.'
            Write-Hint 'Tren may build: bat agent.bat hoac kiem tra Scheduled Task.'
        }
    }
    Write-Info "Theo doi: .\ci.ps1 status"
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
        $mark  = if ($r.success) { 'OK  ' } else { 'HONG' }
        $color = if ($r.success) { 'Green' } else { 'Red' }
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
  .\ci.ps1 build -Format aab -Config release
  .\ci.ps1 projects                     liet ke project da khai bao
  .\ci.ps1 status                       xem dang build gi / ket qua gan day
  .\ci.ps1 queue                        xem hang doi
  .\ci.ps1 open                         mo thu muc chua file build
  .\ci.ps1 config                       xem / doi duong dan, khong can cai lai
  .\ci.ps1 doctor                       kiem tra lai he thong

  Hoac double-click build.bat de build nhanh ban dev.
'@ -ForegroundColor Gray
}

}
