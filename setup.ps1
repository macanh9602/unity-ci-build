# ============================================================
#  setup.ps1 - trinh cai dat. Dung double-click install.bat.
# ============================================================
[CmdletBinding()]
param([switch]$CheckOnly)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib\Common.ps1')
. (Join-Path $PSScriptRoot 'lib\Queue.ps1')
. (Join-Path $PSScriptRoot 'lib\Discord.ps1')
. (Join-Path $PSScriptRoot 'lib\Drive.ps1')
. (Join-Path $PSScriptRoot 'lib\Unity.ps1')
Set-ConsoleUtf8

$REQUIRED_GB = 60

# ============================================================
#  DO TIM
# ============================================================
function Test-Admin {
    try {
        $id = [Security.Principal.WindowsIdentity]::GetCurrent()
        (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole(
            [Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch { $false }
}

function Find-Exe([string]$Name) {
    $c = Get-Command $Name -ErrorAction SilentlyContinue
    if ($c) { return $c.Source }
    return $null
}

function Install-WithWinget {
    param([string]$Id, [string]$Label)
    if (-not (Find-Exe 'winget.exe')) {
        Write-Hint "Khong co winget - tu cai $Label roi chay lai install.bat"
        return $false
    }
    Write-Info "Dang cai $Label (co the hien cua so xac nhan cua Windows)..."
    try {
        & winget install --id $Id -e --source winget --silent `
            --accept-package-agreements --accept-source-agreements 2>&1 | Out-Null
    } catch {}
    Start-Sleep -Seconds 2
    $env:Path = [Environment]::GetEnvironmentVariable('Path','Machine') + ';' +
                [Environment]::GetEnvironmentVariable('Path','User')
    return $true
}

function Get-DiskTable {
    $rows = New-Object System.Collections.ArrayList
    try {
        $disks = Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3' -ErrorAction Stop
        foreach ($d in $disks) {
            [void]$rows.Add([pscustomobject]@{
                Letter  = $d.DeviceID
                Label   = $d.VolumeName
                FreeGB  = [math]::Round($d.FreeSpace / 1GB, 1)
                TotalGB = [math]::Round($d.Size / 1GB, 1)
            })
        }
    } catch {
        foreach ($d in (Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue)) {
            if ($null -eq $d.Free) { continue }
            [void]$rows.Add([pscustomobject]@{
                Letter  = "$($d.Name):"
                Label   = ''
                FreeGB  = [math]::Round($d.Free / 1GB, 1)
                TotalGB = [math]::Round(($d.Free + $d.Used) / 1GB, 1)
            })
        }
    }
    return ($rows | Sort-Object -Property FreeGB -Descending)
}

function Select-FolderDialog {
    param([string]$Description, [string]$InitialPath = '', [switch]$AllowNewFolder)
    try {
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
        $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
        $dlg.Description = $Description
        $dlg.ShowNewFolderButton = [bool]$AllowNewFolder
        if ($InitialPath -and (Test-Path $InitialPath)) { $dlg.SelectedPath = $InitialPath }
        if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { return $dlg.SelectedPath }
    } catch {}
    return ''
}

function Select-FileDialog {
    param([string]$Title, [string]$Filter = 'All files (*.*)|*.*')
    try {
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
        $dlg = New-Object System.Windows.Forms.OpenFileDialog
        $dlg.Title = $Title
        $dlg.Filter = $Filter
        if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { return $dlg.FileName }
    } catch {}
    return ''
}

# ============================================================
#  MAN HINH MO DAU
# ============================================================
Clear-Host
Write-Host ''
Write-Host '  ============================================================' -ForegroundColor Cyan
Write-Host '    UNITY CI BUILD - build game chay nen, Editor van ranh' -ForegroundColor Cyan
Write-Host '  ============================================================' -ForegroundColor Cyan

$existing = $null
if (Test-CiInstalled) { try { $existing = Read-CiConfig } catch {} }
$isFirst  = -not $existing

if (-not $CheckOnly) {
    if ($isFirst) {
        Write-Host ''
        Write-Host '  BAN CAN CHUAN BI' -ForegroundColor White
        Write-Host '    1. Thu muc project Unity (da la git repo)' -ForegroundColor Gray
        Write-Host "    2. Mot o dia con trong khoang $REQUIRED_GB GB" -ForegroundColor Gray
        Write-Host '    3. (tuy chon) Duong dan webhook cua kenh Discord' -ForegroundColor Gray
        Write-Host '    4. (tuy chon) Noi de tester tai file ve' -ForegroundColor Gray
        Write-Host ''
        Write-Host '  SAU KHI CAI XONG BAN DUOC GI' -ForegroundColor White
        Write-Host '    - Trong Unity co menu  CI Build > Build Android' -ForegroundColor Gray
        Write-Host '    - Bam mot phat la build chay nen, Editor dung yen cho ban lam tiep' -ForegroundColor Gray
        Write-Host '    - Xong co file APK/AAB trong thu muc rieng + bao ve Discord' -ForegroundColor Gray
        Write-Host '    - Build hong thi co file errors.txt liet ke dung dong loi' -ForegroundColor Gray
        Write-Host ''
        if (-not (Read-YesNo 'Bat dau cai dat?' $true)) { exit 0 }
    } else {
        Write-Host ''
        Write-Host '  DANG CO SAN' -ForegroundColor White
        foreach ($p in $existing.projects) {
            $star = if ($p.name -eq $existing.defaultProject) { '*' } else { ' ' }
            Write-Host ("    {0} {1}" -f $star, $p.name) -ForegroundColor Gray
            Write-Host ("      {0}" -f $p.projectPath) -ForegroundColor DarkGray
        }
        Write-Host ''
        Write-Info 'Chon lai project o buoc sau: project cu -> sua, project moi -> them vao.'
        Write-Host ''
    }
}

# ============================================================
#  BUOC 1 - KIEM TRA MAY
# ============================================================
Write-Title 'Buoc 1/6 - Kiem tra may'
$blockers = New-Object System.Collections.ArrayList

if ($PSVersionTable.PSVersion.Major -lt 5) {
    Write-Bad "PowerShell $($PSVersionTable.PSVersion) - can 5.1 tro len"
    [void]$blockers.Add('PowerShell qua cu')
} else {
    Write-Ok "PowerShell $($PSVersionTable.PSVersion)"
}

if (Find-Exe 'winget.exe') { Write-Ok 'winget (dung de tu cai git / rclone)' }
else { Write-Miss 'winget - se phai cai tay git/rclone neu thieu' }

$gitExe = Find-Exe 'git.exe'
if ($gitExe) {
    $gv = (& git --version) -replace 'git version ',''
    Write-Ok "Git $gv"
} else {
    Write-Miss 'Git - chua cai'
    if (-not $CheckOnly -and (Read-YesNo '  Cai Git ngay bay gio?' $true)) {
        Install-WithWinget -Id 'Git.Git' -Label 'Git' | Out-Null
        $gitExe = Find-Exe 'git.exe'
        if ($gitExe) { Write-Ok 'Da cai Git' } else { Write-Bad 'Cai Git chua xong - dong cua so nay va chay lai install.bat' }
    }
    if (-not $gitExe) { [void]$blockers.Add('Git') }
}

$hub = Find-UnityHub
if ($hub) { Write-Ok 'Unity Hub' }
else {
    Write-Miss 'Unity Hub - chua cai'
    Write-Hint 'Tai tai https://unity.com/download (khong tu cai ho duoc vi phai dang nhap license)'
    [void]$blockers.Add('Unity Hub')
}

# ============================================================
#  VAI TRO CUA MAY NAY
# ============================================================
Write-Title 'May nay dong vai gi'
Write-Host '    [1] May dev   - chi dat lenh build, may khac build ho' -ForegroundColor Gray
Write-Host '    [2] May build - chay build, khong dat lenh' -ForegroundColor Gray
Write-Host '    [3] Ca hai    - mot may lam tat (nhu mac dinh truoc gio)' -ForegroundColor Green
Write-Host ''

$defRole = if ($existing) { "$($existing.role)" } else { 'standalone' }
$defPick = switch ($defRole) { 'client' { '1' } 'agent' { '2' } default { '3' } }
$rolePick = if ($CheckOnly) { $defPick } else { Read-Choice 'Chon' $defPick }
$role = switch ($rolePick) { '1' { 'client' } '2' { 'agent' } default { 'standalone' } }
Write-Ok "Vai tro: $role"

# ============================================================
#  DUONG RIENG CHO MAY BUILD
#  May build khong can cau hinh tung project: gap job cua project la,
#  no tu clone tu gitRemote kem trong job roi tu tim ban Unity khop.
# ============================================================
if ($role -eq 'agent' -and -not $CheckOnly) {

    Write-Title 'Cai dat may build'
    Write-Info 'May build khong can chon project - no tu clone khi nhan job dau tien.'
    Write-Host ''

    $agentName = Read-Choice 'Ten may build (hien trong Discord va ci.ps1 status)' $(if ($existing) { "$($existing.agentName)" } else { $env:COMPUTERNAME })

    Write-Host ''
    Write-Info 'Thu muc lam viec - se chua queue, worktree va file build.'
    Write-Hint 'Day la thu muc ban se CHIA SE ra mang cho may dev thay.'
    $agentRoot = ''
    $defRoot = if ($existing -and (Test-CiRootValid $existing.ciRoot)) { $existing.ciRoot } else { 'C:\UnityCI' }
    while (-not $agentRoot) {
        $agentRoot = Resolve-CiRootPath (Read-Choice 'Duong dan' $defRoot)
        if (-not (Test-CiRootValid $agentRoot)) {
            Write-Bad 'Can duong dan tuyet doi co o dia, vd C:\UnityCI'
            $agentRoot = ''
        }
    }

    $pollSec = ConvertTo-IntSafe (Read-Choice 'Bao nhieu giay ngo queue mot lan' $(if ($existing) { $existing.pollSeconds } else { 5 })) 5
    if ($pollSec -lt 2) { $pollSec = 2 }

    $cores = [Environment]::ProcessorCount
    Write-Host ''
    Write-Info "May nay co $cores core. Vi la may build chuyen dung, nen chua lai it thoi."
    $agentReserve = ConvertTo-IntSafe (Read-Choice 'Chua lai bao nhieu core' $(if ($existing) { $existing.reserveCoresForEditor } else { 0 })) 0
    if ($agentReserve -lt 0) { $agentReserve = 0 }
    if ($agentReserve -ge $cores) { $agentReserve = $cores - 1 }

    $agentTimeout = ConvertTo-IntSafe (Read-Choice 'Toi da bao nhieu phut thi coi nhu build treo' $(if ($existing) { $existing.buildTimeoutMinutes } else { 90 })) 90
    if ($agentTimeout -lt 10) { $agentTimeout = 10 }

    # Discord: chinh MAY BUILD la ben gui thong bao, nen webhook phai o day
    Write-Host ''
    Write-Info 'Discord: may build la ben gui thong bao, nen webhook cau hinh o day.'
    $oldSec = Read-CiSecrets
    $agentDiscord = $false; $agentCipher = ''
    if (Read-YesNo 'Bat thong bao Discord?' $true) {
        $cur = Get-Secret $oldSec 'discordWebhook'
        $url = Read-Choice ("Dan duong dan webhook " + $(if ($cur) { '(Enter de giu cai cu)' } else { '' })) ''
        if (-not $url -and $cur) { $url = $cur }
        if ($url -match '^https://discord(app)?\.com/api/webhooks/') {
            Write-Info 'Dang gui thu...'
            if (Send-DiscordTest -WebhookUrl $url) { Write-Ok 'Da gui' } else { Write-Miss 'Gui that bai - van luu' }
            $agentDiscord = $true; $agentCipher = Protect-CiString $url
        } elseif ($url) { Write-Bad 'Khong dung dinh dang webhook - bo qua' }
    }

    # --- ghi cau hinh ---
    $agentCfg = [pscustomobject]@{
        version               = 3
        role                  = 'agent'
        agentName             = $agentName
        canBuild              = @('android')
        pollSeconds           = $pollSec
        ciRoot                = $agentRoot
        reserveCoresForEditor = $agentReserve
        buildTimeoutMinutes   = $agentTimeout
        useNographics         = $false
        discord               = [pscustomobject]@{ enabled = $agentDiscord }
        defaultProject        = ''
        projects              = @()
    }
    Initialize-CiDirs $agentCfg
    Write-CiConfig $agentCfg
    Save-CiSecrets -Secrets $oldSec -DiscordCipher $agentCipher
    Write-Ok "Da ghi cau hinh, thu muc lam viec: $agentRoot"

    # --- Scheduled Task ---
    Write-Host ''
    $taskName = 'UnityCIBuildAgent'
    $runnerPs = Join-CiPath (Get-ToolDir) 'runner.ps1'
    $taskOk = $false
    if (Read-YesNo 'Tao Scheduled Task de agent tu chay khi dang nhap?' $true) {
        try {
            $act  = New-ScheduledTaskAction -Execute 'powershell.exe' `
                        -Argument ('-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}" -Watch' -f $runnerPs)
            $trg  = New-ScheduledTaskTrigger -AtLogOn
            $set  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero)
            Register-ScheduledTask -TaskName $taskName -Action $act -Trigger $trg -Settings $set -Force -ErrorAction Stop | Out-Null
            Write-Ok "Da tao Scheduled Task '$taskName'"
            $taskOk = $true
        } catch {
            Write-Bad "Tao Scheduled Task that bai: $($_.Exception.Message)"
            Write-Hint 'Khong sao - van chay tay bang agent.bat duoc.'
        }
    }

    Write-Host ''
    Write-Host '  ============================================================' -ForegroundColor Green
    Write-Host '    MAY BUILD DA SAN SANG' -ForegroundColor Green
    Write-Host '  ============================================================' -ForegroundColor Green
    Write-Host ''
    Write-Host '  CON MOT VIEC PHAI LAM TAY: chia se thu muc ra mang' -ForegroundColor White
    Write-Host "    1. Chuot phai $agentRoot > Properties > Sharing > Share..." -ForegroundColor Gray
    Write-Host '    2. Them tai khoan may dev, cap quyen Read/Write' -ForegroundColor Gray
    Write-Host ("    3. Tren may dev, dat thu muc CI la:  \\{0}\{1}" -f $env:COMPUTERNAME, (Split-Path -Leaf $agentRoot)) -ForegroundColor Gray
    Write-Host ''
    if ($taskOk) {
        Write-Host '  Agent se tu chay moi lan DANG NHAP vao may nay.' -ForegroundColor Gray
        Write-Host '  Nen bat auto-login cho may build, vi Unity can mot phien dang nhap that' -ForegroundColor Gray
        Write-Host '  moi build on dinh - chay nhu dich vu nen de vo o khau compile shader.' -ForegroundColor Gray
    }
    Write-Host '  Chay tay / xem log truc tiep: double-click agent.bat' -ForegroundColor Gray
    Write-Host '  Dung agent: tao file agent-stop.flag trong thu muc lam viec' -ForegroundColor Gray
    Write-Host ''
    exit 0
}

# ============================================================
#  BUOC 2 - PROJECT UNITY
# ============================================================
Write-Title 'Buoc 2/6 - Project Unity'

$defaultProjPath = ''
if ($existing) {
    $dp = Get-CiProject $existing
    if ($dp) { $defaultProjPath = $dp.projectPath }
}

$projectPath = ''
if ($CheckOnly) { $projectPath = $defaultProjPath }

while (-not (Test-UnityProject $projectPath)) {
    if ($CheckOnly) { break }
    Write-Info 'Chon thu muc goc cua project (thu muc chua Assets va ProjectSettings)'
    $projectPath = Select-FolderDialog -Description 'Chon thu muc project Unity' -InitialPath $defaultProjPath
    if (-not $projectPath) { $projectPath = Read-Choice 'Hoac go duong dan' '' }
    if (-not $projectPath) { Write-Bad 'Chua chon gi - thoat.'; exit 1 }
    if (-not (Test-UnityProject $projectPath)) { Write-Bad "Khong phai project Unity: $projectPath" }
}

if (-not (Test-UnityProject $projectPath)) {
    Write-Bad 'Khong xac dinh duoc project Unity.'
    Write-Hint 'Chay install.bat de cai dat lai tu dau.'
    exit 1
}
$projectPath = $projectPath.TrimEnd('\')
$projectName = Split-Path -Leaf $projectPath

# Da khai bao roi hay la project moi?
$existingProj = $null
if ($existing) { $existingProj = Find-CiProjectByPath $existing $projectPath }
if ($existingProj) {
    Write-Ok "Project: $($existingProj.name)  (da khai bao - se cap nhat)"
    $projectName = $existingProj.name
} else {
    Write-Ok "Project: $projectName  (moi - se them vao)"
}
Write-Info $projectPath

$git = Get-GitInfo $projectPath
if (-not $git) {
    Write-Bad 'Thu muc nay chua phai git repo (hoac chua co commit nao)'
    Write-Hint 'Build lay code tu commit, nen bat buoc phai co git. Chay: git init && git add . && git commit -m "init"'
    [void]$blockers.Add('git repo')
} else {
    Write-Ok "Git OK - branch $($git.Branch), $($git.CommitCount) commit"
}

$projVer = Get-ProjectUnityVersion $projectPath
if ($projVer) { Write-Ok "Project dung Unity $projVer" }
else { Write-Miss 'Khong doc duoc ProjectVersion.txt' }

# ============================================================
#  BUOC 3 - UNITY EDITOR + ANDROID
# ============================================================
Write-Title 'Buoc 3/6 - Unity Editor'
$editors = @(Get-UnityEditors)
$unityExe = ''; $unityVer = ''; $editorRoot = ''

if ($editors.Count -eq 0) {
    Write-Bad 'Khong tim thay ban Unity Editor nao'
    Write-Hint 'Mo Unity Hub > Installs > Install Editor'
    [void]$blockers.Add('Unity Editor')
} else {
    $match = $editors | Where-Object { $_.Version -eq $projVer } | Select-Object -First 1
    if ($match) {
        $unityExe = $match.Exe; $unityVer = $match.Version; $editorRoot = $match.Root
        Write-Ok "Unity $unityVer (khop voi project)"
    } else {
        Write-Miss "Khong co ban Unity $projVer khop voi project. Cac ban dang co:"
        for ($i = 0; $i -lt $editors.Count; $i++) { Write-Info ("  [{0}] {1}" -f ($i+1), $editors[$i].Version) }
        if ($CheckOnly) {
            [void]$blockers.Add("Unity $projVer")
        } else {
            Write-Hint "Nen cai dung $projVer qua Unity Hub. Mo bang ban khac co the lam Unity nang cap project."
            $pick = Read-Choice 'Chon so de dung tam (Enter de bo qua)' ''
            if ($pick -match '^\d+$' -and [int]$pick -ge 1 -and [int]$pick -le $editors.Count) {
                $e = $editors[[int]$pick - 1]
                $unityExe = $e.Exe; $unityVer = $e.Version; $editorRoot = $e.Root
                Write-Ok "Dung Unity $unityVer"
            } else { [void]$blockers.Add("Unity $projVer") }
        }
    }
}

if ($editorRoot) {
    $am = Get-AndroidModuleState $editorRoot
    if ($am.Installed) {
        Write-Ok 'Android Build Support'
        if (-not $am.Jdk) { Write-Miss '  thieu OpenJDK' }
        if (-not $am.Sdk) { Write-Miss '  thieu Android SDK' }
        if (-not $am.Ndk) { Write-Miss '  thieu Android NDK (can cho IL2CPP)' }
    } else {
        Write-Bad 'Chua co Android Build Support'
        Write-Hint "Unity Hub > Installs > bam banh rang cua ban $unityVer > Add modules"
        Write-Hint 'Tich: Android Build Support + Android SDK & NDK Tools + OpenJDK'
        [void]$blockers.Add('Android Build Support')
    }
}

if ($CheckOnly) {
    if ($existing) {
        Write-Title 'Cau hinh'
        if (Test-CiRootValid $existing.ciRoot) {
            Write-Ok "Thu muc CI: $($existing.ciRoot)"
        } else {
            Write-Bad "Thu muc CI khong hop le: '$($existing.ciRoot)' - thieu o dia"
            Write-Hint 'Chay install.bat va nhap lai, vd E:\UnityCI'
            [void]$blockers.Add('duong dan thu muc CI')
        }
        foreach ($p in $existing.projects) {
            if (Test-Path $p.worktreePath) { Write-Ok "Worktree $($p.name): $($p.worktreePath)" }
            else {
                Write-Bad "Worktree $($p.name) khong ton tai: $($p.worktreePath)"
                [void]$blockers.Add("worktree $($p.name)")
            }
        }

        # Hai project do file vao cung mot cho la gan nhu chac chan dan nham link
        $seen = @{}
        foreach ($p in $existing.projects) {
            $key = "$($p.drive.rootFolderId)|$($p.drive.folderPath)"
            if ($key -eq '|') { continue }
            if ($seen.ContainsKey($key)) {
                Write-Bad "Project '$($p.name)' va '$($seen[$key])' dang do file vao CUNG MOT cho"
                Write-Hint 'Gan nhu chac chan la dan nham link. Sua drive.rootFolderId trong config.json.'
            } else { $seen[$key] = $p.name }
        }

        # Thu dich den that su - de biet TRUOC khi ton 20 phut build
        Write-Title 'Noi dua file cho tester'
        foreach ($p in $existing.projects) {
            $eff = Get-EffectiveConfig $existing $p.name
            $t = Test-CiPublishTarget $eff
            if ($t.Mode -eq 'none') { Write-Info "$($p.name): khong bat"; continue }
            if ($t.Ok) { Write-Ok "$($p.name) -> $($t.Detail)" }
            else {
                Write-Bad "$($p.name) -> $($t.Detail)"
                Write-Hint $t.Message
                if ($t.Message -match 'not found|404|shortcut|permission|403') {
                    Write-Hint 'Folder trong muc "Shared with me"? Phai tao shortcut vao My Drive truoc.'
                }
                [void]$blockers.Add("noi dua file cua $($p.name)")
            }
        }
    }

    Write-Title 'Ket qua kiem tra'
    if ($blockers.Count -eq 0) { Write-Ok 'Moi thu san sang.' }
    else { foreach ($b in $blockers) { Write-Bad "Con thieu: $b" } }
    exit ($(if ($blockers.Count -eq 0) { 0 } else { 1 }))
}

if ($blockers.Count -gt 0) {
    Write-Host ''
    Write-Bad 'Con thieu cac thu sau, xu ly xong roi chay lai install.bat:'
    foreach ($b in $blockers) { Write-Info "  - $b" }
    Write-Host ''
    if (-not (Read-YesNo 'Van muon ghi cau hinh de lat nua quay lai?' $false)) { exit 1 }
}

# ============================================================
#  BUOC 4 - CAI DAT CHUNG (dung chung moi project)
# ============================================================
Write-Title 'Buoc 4/6 - Cai dat chung'

$ciRoot = ''; $reserve = 0; $timeout = 90
$discordEnabled = $false; $discordCipher = ''
$oldSecrets = Read-CiSecrets
$keepShared = $false

if ($existing) {
    $sharedOk = Test-CiRootValid $existing.ciRoot

    Write-Info "Thu muc CI    : $($existing.ciRoot)"
    if (-not $sharedOk) {
        Write-Bad   "  ^ duong dan nay KHONG hop le - thieu o dia (vd phai la E:\UnityCI)"
        Write-Hint  'Day la nguyen nhan build bao "Worktree khong ton tai". Phai chon lai.'
    }
    Write-Info "Chua lai core : $($existing.reserveCoresForEditor)"
    Write-Info "Timeout       : $($existing.buildTimeoutMinutes) phut"
    Write-Info "Discord       : $(if ($existing.discord.enabled) { 'bat' } else { 'tat' })"
    Write-Host ''

    # Cau hinh hong thi khong duoc phep Enter cho qua
    if ($sharedOk) {
        $keepShared = Read-YesNo 'Giu nguyen nhung cai nay?' $true
    } else {
        Write-Info 'Bo qua cau hoi giu nguyen - se hoi lai thu muc CI ngay sau day.'
        $keepShared = $false
    }

    if ($keepShared) {
        $ciRoot         = $existing.ciRoot
        $reserve        = $existing.reserveCoresForEditor
        $timeout        = $existing.buildTimeoutMinutes
        $discordEnabled = [bool]$existing.discord.enabled
        $discordCipher  = $oldSecrets.discordWebhook
    }
}

if (-not $keepShared) {
    Write-Host ''
    Write-Info 'Tool can mot ban sao thu hai cua project (worktree) + thu muc chua file build.'
    Write-Info "Ban sao nay la ly do Editor cua ban khong bi khoa khi dang build. Can khoang $REQUIRED_GB GB."
    Write-Host ''

    $disks = @(Get-DiskTable)
    if ($disks.Count -eq 0) { Write-Miss 'Khong doc duoc danh sach o dia - ban se phai go duong dan bang tay.' }
    $sysDrive = $env:SystemDrive
    Write-Host ('   {0,-4} {1,-16} {2,10} {3,10}   {4}' -f 'O', 'Ten', 'Trong', 'Tong', '') -ForegroundColor DarkGray
    for ($i = 0; $i -lt $disks.Count; $i++) {
        $d = $disks[$i]
        $ok = $d.FreeGB -ge $REQUIRED_GB
        $note = if (-not $ok) { 'khong du cho' } elseif ($d.Letter -eq $sysDrive) { 'du, nhung la o he thong' } else { 'nen dung' }
        $col  = if (-not $ok) { 'DarkGray' } elseif ($d.Letter -eq $sysDrive) { 'Yellow' } else { 'Green' }
        Write-Host ('   [{0}] {1,-4} {2,-16} {3,8} GB {4,8} GB   {5}' -f `
            ($i+1), $d.Letter, $d.Label, $d.FreeGB, $d.TotalGB, $note) -ForegroundColor $col
    }
    Write-Host ''

    $suggest = ($disks | Where-Object { $_.FreeGB -ge $REQUIRED_GB -and $_.Letter -ne $sysDrive } | Select-Object -First 1)
    if (-not $suggest) { $suggest = ($disks | Where-Object { $_.FreeGB -ge $REQUIRED_GB } | Select-Object -First 1) }
    $defaultRoot = if ($existing -and (Test-CiRootValid $existing.ciRoot)) { $existing.ciRoot }
                   elseif ($suggest) { $suggest.Letter.TrimEnd('\') + '\UnityCI' }
                   else { 'C:\UnityCI' }

    while (-not $ciRoot) {
        $ans = Read-Choice "Chon so o dia, hoac go thang duong dan" $defaultRoot
        if ($ans -match '^\d+$' -and [int]$ans -ge 1 -and [int]$ans -le $disks.Count) {
            # DeviceID cua Windows la 'E:' (khong gach cheo) - phai tu them,
            # vi 'E:' tran nghia la "thu muc hien hanh cua o E", khong phai goc o E.
            $ciRoot = $disks[[int]$ans - 1].Letter.TrimEnd('\') + '\UnityCI'
        } else {
            $ciRoot = Resolve-CiRootPath $ans
            if (-not $ciRoot) {
                Write-Bad "Khong hieu duong dan: $ans"
                Write-Hint 'Phai la duong dan tuyet doi, vd: E:\UnityCI - hoac go moi chu cai o dia, vd: E'
                continue
            }
        }
        if (-not (Test-CiRootValid $ciRoot)) {
            Write-Bad "Duong dan khong hop le: $ciRoot"
            Write-Hint 'Can duong dan tuyet doi co goc o dia, vd: E:\UnityCI'
            $ciRoot = ''; continue
        }
        $rootOfPath = $ciRoot.Substring(0, 2)
        $dd = $disks | Where-Object { $_.Letter -eq $rootOfPath } | Select-Object -First 1
        if ($dd -and $dd.FreeGB -lt $REQUIRED_GB) {
            Write-Miss "O $($dd.Letter) chi con $($dd.FreeGB) GB, can khoang $REQUIRED_GB GB."
            if (-not (Read-YesNo '  Van dung o nay?' $false)) { $ciRoot = ''; continue }
        }
    }
    Write-Ok "Thu muc CI: $ciRoot"
    Write-Info "  worktree  : $ciRoot\worktree\..."
    Write-Info "  file build: $ciRoot\builds\..."

    Write-Host ''
    $cores = [Environment]::ProcessorCount
    $defReserve = if ($existing) { $existing.reserveCoresForEditor } else { [Math]::Max(2, [int]($cores / 4)) }
    Write-Info "May co $cores core. Build se chay uu tien thap va chua lai vai core cho Editor."
    $reserve = ConvertTo-IntSafe (Read-Choice 'Chua lai bao nhieu core cho Editor' $defReserve) $defReserve
    if ($reserve -lt 0) { $reserve = 0 }
    if ($reserve -ge $cores) { $reserve = $cores - 1 }

    $defTimeout = if ($existing) { $existing.buildTimeoutMinutes } else { 90 }
    $timeout = ConvertTo-IntSafe (Read-Choice 'Toi da bao nhieu phut thi coi nhu build treo' $defTimeout) $defTimeout
    if ($timeout -lt 10) { $timeout = 10 }

    Write-Host ''
    Write-Info 'Discord: bao ket qua build vao kenh chat. Dung chung cho moi project.'
    Write-Hint 'Lay tai: Discord > chuot phai vao kenh > Edit Channel > Integrations > Webhooks > New Webhook > Copy URL'
    if (Read-YesNo 'Bat thong bao Discord?' $true) {
        $cur = Get-Secret $oldSecrets 'discordWebhook'
        $hint = if ($cur) { '(Enter de giu cai cu)' } else { '' }
        $url = Read-Choice "Dan duong dan webhook $hint" ''
        if (-not $url -and $cur) { $url = $cur }
        if ($url -match '^https://discord(app)?\.com/api/webhooks/') {
            Write-Info 'Dang gui thu mot tin nhan...'
            if (Send-DiscordTest -WebhookUrl $url) {
                Write-Ok 'Da gui - kiem tra kenh Discord xem co tin nhan chua'
                $discordEnabled = $true; $discordCipher = Protect-CiString $url
            } else {
                Write-Bad 'Gui that bai - kiem tra lai duong dan'
                if (Read-YesNo '  Van luu lai?' $false) { $discordEnabled = $true; $discordCipher = Protect-CiString $url }
            }
        } elseif ($url) { Write-Bad 'Duong dan khong dung dinh dang webhook cua Discord - bo qua' }
    }
}

# ============================================================
#  BUOC 5 - RIENG CHO PROJECT NAY
# ============================================================
Write-Title "Buoc 5/6 - Rieng cho $projectName"

$pd = $null
if ($existingProj) { $pd = $existingProj.drive }

Write-Host ''
Write-Info 'Sau khi build xong, file APK/AAB co can di dau nua khong?'
Write-Host '    [1] Khong can - file chi nam tren may nay' -ForegroundColor Gray
Write-Host '    [2] Copy sang mot folder khac (Google Drive Desktop / MEGA / OneDrive / o mang)' -ForegroundColor Green
Write-Host '        -> don gian nhat, chi can 1 duong dan, khong phai dang nhap gi ca' -ForegroundColor DarkGray
Write-Host '    [3] rclone - upload thang len Google Drive, tu tao link rieng cho tung file' -ForegroundColor Gray
Write-Host '        -> can dang nhap Google mot lan qua trinh duyet' -ForegroundColor DarkGray
Write-Host ''

$driveMode = 'none'; $driveFolderPath = ''; $driveShareUrl = ''
$driveRemote = ''; $driveFolder = 'UnityBuilds'; $rclonePath = ''; $driveRootId = ''

$defMode = if ($pd -and $pd.mode -eq 'folder') { '2' } elseif ($pd -and $pd.mode -eq 'rclone') { '3' } else { '2' }
$modePick = Read-Choice 'Chon' $defMode

if ($modePick -eq '2') {
    $syncs = @(Find-SyncFolders)
    if ($syncs.Count -gt 0) {
        Write-Info 'Tim thay may folder dong bo tren may:'
        for ($i = 0; $i -lt $syncs.Count; $i++) {
            Write-Info ("  [{0}] {1}  -  {2}" -f ($i+1), $syncs[$i].Name, $syncs[$i].Path)
        }
        Write-Info '  [0] Go duong dan khac'
    }
    $base = ''
    while (-not $base) {
        $ans = Read-Choice 'Chon so hoac go duong dan folder' $(if ($syncs.Count -gt 0) { '1' } else { '' })
        if ($ans -match '^\d+$' -and [int]$ans -ge 1 -and [int]$ans -le $syncs.Count) {
            $base = $syncs[[int]$ans - 1].Path
        } elseif ($ans -eq '0' -or -not $ans) {
            $sel = Select-FolderDialog -Description 'Chon folder de chua file build (tao moi duoc)' -AllowNewFolder
            if ($sel) { $base = $sel }
        } else { $base = $ans }
    }
    $defSub = if ($pd -and $pd.folderPath) { $pd.folderPath } else { Join-CiPath $base ('Builds_' + $projectName) }
    Write-Host ''
    Write-Info 'Go duong dan day du neu ban muon cho khac - long bao nhieu cap cung duoc.'
    Write-Hint "Vi du: $base\Builds\$projectName\Android"
    $driveFolderPath = Read-Choice 'Folder cu the de do file vao' $defSub
    $driveMode = 'folder'
    if (Test-Path $driveFolderPath) { Write-Ok "Folder da co san: $driveFolderPath" }
    else { Write-Ok "Se tu tao khi build xong: $driveFolderPath" }

    Write-Host ''
    Write-Info 'Neu ban da share san folder do va co link, dan vao day thi Discord se kem link luon.'
    Write-Hint 'Day la link TINH, dan mot lan - khong phai link rieng cua tung file.'
    $defUrl = if ($pd) { "$($pd.shareUrl)" } else { '' }
    $u = Read-Choice 'Link share (Enter de bo qua)' $defUrl
    if ($u -match '^https?://') { $driveShareUrl = $u; Write-Ok 'Da luu link' }
    elseif ($u) { Write-Miss 'Khong phai link hop le - bo qua' }

} elseif ($modePick -eq '3') {
    $rclonePath = Find-Rclone $(if ($pd) { "$($pd.rclonePath)" } else { '' })
    if (-not $rclonePath) {
        Write-Miss 'Chua co rclone (cong cu noi voi Google Drive)'
        if (Read-YesNo '  Cai rclone ngay?' $true) {
            Install-WithWinget -Id 'Rclone.Rclone' -Label 'rclone' | Out-Null
            $rclonePath = Find-Rclone
        }
    }
    if ($rclonePath) {
        Write-Ok "rclone: $rclonePath"
        $remotes = @(Get-RcloneRemotes $rclonePath)
        if ($remotes.Count -eq 0) {
            Write-Miss 'Chua noi tai khoan Google Drive nao vao rclone.'
            Write-Host ''
            Write-Info 'Toi co the noi ngay bay gio - chi mat 1 buoc:'
            Write-Hint 'Trinh duyet se tu mo -> dang nhap Google -> bam Allow -> xong.'
            if (Read-YesNo '  Noi tai khoan Google Drive ngay?' $true) {
                Write-Host ''
                Write-Info 'Dang mo trinh duyet... (neu khong tu mo, copy duong dan rclone in ra ben duoi)'
                Write-Host ''
                New-RcloneDriveRemote -RclonePath $rclonePath -Name 'gdrive' | Out-Null
                Write-Host ''
                $remotes = @(Get-RcloneRemotes $rclonePath)
                if ($remotes.Count -gt 0) { Write-Ok 'Da noi xong' }
                else { Write-Miss 'Chua noi duoc - co the ban da dong trinh duyet giua chung' }
            }
        }
        if ($remotes.Count -eq 0) {
            Write-Hint 'Bo qua muc nay cung duoc - chon [2] hoac [1] de build truoc, lat nua chay lai install.bat de them sau.'
        } else {
            Write-Info 'Cac tai khoan rclone dang co:'
            for ($i = 0; $i -lt $remotes.Count; $i++) { Write-Info ("  [{0}] {1}" -f ($i+1), $remotes[$i]) }
            $pick = Read-Choice 'Chon so' '1'
            if ($pick -match '^\d+$' -and [int]$pick -ge 1 -and [int]$pick -le $remotes.Count) {
                $driveRemote = $remotes[[int]$pick - 1]
                Write-Host ''
                Write-Info 'Muon do file vao dung MOT folder co san? Dan link folder do vao day.'
                Write-Hint 'Mo folder tren drive.google.com roi copy nguyen link tren thanh dia chi.'
                $defLink = if ($pd -and $pd.rootFolderId) { "https://drive.google.com/drive/folders/$($pd.rootFolderId)" } else { '' }
                $folderUrl = Read-Choice 'Link folder Drive (Enter de bo qua)' $defLink
                if ($folderUrl) {
                    $driveRootId = Get-DriveFolderId $folderUrl
                    if ($driveRootId) {
                        Write-Ok "Da lay folder ID: $driveRootId"
                        Write-Host ''
                        Write-Miss 'LUU Y neu folder do nam trong muc "Shared with me" (nguoi khac share cho ban):'
                        Write-Hint 'Google KHONG cho tro thang vao do. Phai tao shortcut truoc:'
                        Write-Hint 'Chuot phai folder tren Drive > Organise > Add shortcut to Drive > chon My Drive'
                        Write-Host ''
                        $driveFolder = Read-Choice 'Thu muc con ben trong folder do (Enter = do thang vao)' ''
                    } else {
                        Write-Bad 'Khong doc duoc folder ID tu link do - bo qua'
                        $driveFolder = Read-Choice 'Thu muc tren Drive' $driveFolder
                    }
                } else {
                    Write-Hint 'Go duoc duong dan long nhau, vd: Builds/WoolLoop/Android - rclone tu tao.'
                    $driveFolder = Read-Choice 'Thu muc tren Drive' $driveFolder
                }
                $driveMode = 'rclone'
                Write-Ok ("Se upload vao " + $driveRemote + $driveFolder + $(if ($driveRootId) { "  (ghim folder ID $driveRootId)" } else { '' }))
            }
        }
    }
} else {
    Write-Info 'Bo qua - file build chi nam tren may nay.'
}

# --- Keystore (rieng tung project) ---
Write-Host ''
Write-Info 'Keystore: chi can neu ban build ban RELEASE de gui publisher / len store.'
$ksPath=''; $ksAlias=''; $ksPassCipher=''; $kaPassCipher=''
if ($existingProj -and $existingProj.android -and $existingProj.android.keystorePath) {
    $ksPath  = "$($existingProj.android.keystorePath)"
    $ksAlias = "$($existingProj.android.keyaliasName)"
    $ksPassCipher = Get-ProjectSecretRaw $oldSecrets $projectName 'keystorePass'
    $kaPassCipher = Get-ProjectSecretRaw $oldSecrets $projectName 'keyaliasPass'
    Write-Info "Dang co: $ksPath (alias $ksAlias)"
}
if (Read-YesNo 'Cau hinh keystore cho ban release?' $(if ($ksPath) { $false } else { $false })) {
    $sel = Select-FileDialog -Title 'Chon file keystore' -Filter 'Keystore (*.keystore;*.jks)|*.keystore;*.jks|All files (*.*)|*.*'
    if (-not $sel) { $sel = Read-Choice 'Hoac go duong dan file keystore' '' }
    if ($sel -and (Test-Path $sel)) {
        $ksPath  = $sel
        $ksAlias = Read-Choice 'Ten alias' $ksAlias
        $p1 = Read-Host '  Mat khau keystore' -AsSecureString
        $p2 = Read-Host '  Mat khau alias'    -AsSecureString
        $b1 = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($p1)
        $b2 = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($p2)
        try {
            $ksPassCipher = Protect-CiString ([Runtime.InteropServices.Marshal]::PtrToStringBSTR($b1))
            $kaPassCipher = Protect-CiString ([Runtime.InteropServices.Marshal]::PtrToStringBSTR($b2))
        } finally {
            [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($b1)
            [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($b2)
        }
        Write-Ok 'Da luu (ma hoa bang Windows DPAPI - chi may nay + tai khoan nay mo duoc)'
    } else { Write-Miss 'Bo qua keystore' }
}

# ============================================================
#  BUOC 6 - TIEN HANH
# ============================================================
Write-Title 'Buoc 6/6 - Dang cai dat'

$worktreePath = Join-CiPath $ciRoot "worktree" $projectName
$buildsPath   = Join-CiPath $ciRoot "builds"   $projectName

$projEntry = [pscustomobject]@{
    name         = $projectName
    projectPath  = $projectPath
    gitRemote    = (Get-GitRemoteUrl $projectPath)
    unityExe     = $unityExe
    unityVersion = $unityVer
    worktreePath = $worktreePath
    buildsPath   = $buildsPath
    drive   = [pscustomobject]@{
        mode = $driveMode; folderPath = $driveFolderPath; shareUrl = $driveShareUrl
        rclonePath = $rclonePath; remote = $driveRemote; folder = $driveFolder
        rootFolderId = $driveRootId; makeLink = $true
    }
    android = [pscustomobject]@{ keystorePath = $ksPath; keyaliasName = $ksAlias }
}

# Gop vao danh sach: trung ten thi thay, chua co thi them
$projects = New-Object System.Collections.ArrayList
if ($existing) {
    foreach ($p in $existing.projects) {
        if ($p.name -ne $projectName) { [void]$projects.Add($p) }
    }
}
[void]$projects.Add($projEntry)

$cfg = [pscustomobject]@{
    version               = 3
    role                  = $role
    agentName             = $(if ($existing) { "$($existing.agentName)" } else { $env:COMPUTERNAME })
    canBuild              = @('android')
    pollSeconds           = $(if ($existing) { $existing.pollSeconds } else { 5 })
    ciRoot                = $ciRoot
    reserveCoresForEditor = $reserve
    buildTimeoutMinutes   = $timeout
    useNographics         = $false
    discord               = [pscustomobject]@{ enabled = $discordEnabled }
    defaultProject        = $projectName
    projects              = $projects.ToArray()
}

Initialize-CiDirs (Get-EffectiveConfig $cfg $projectName)
Write-Ok "Da tao thu muc tai $ciRoot"

# --- worktree ---
# Vai tro client thi may khac build, khong can ban sao thu hai o day
if ($git -and $role -ne 'client') {
    $exists = $false
    try {
        $wl = (& git -C $projectPath worktree list 2>$null) -join "`n"
        if ($wl -and $wl.ToLower().Contains($worktreePath.ToLower())) { $exists = $true }
    } catch {}

    if ($exists -and (Test-Path $worktreePath)) {
        Write-Ok 'Worktree da co san - dung lai (giu nguyen Library, build sau se nhanh)'
    } else {
        # Don dang ky cu tro vao cho khong con ton tai
        try { & git -C $projectPath worktree prune 2>&1 | Out-Null } catch {}

        Write-Info 'Dang tao ban sao thu hai cua project (worktree)...'
        if ((Test-Path $worktreePath) -and (Get-ChildItem $worktreePath -Force -ErrorAction SilentlyContinue)) {
            Write-Bad "Thu muc $worktreePath da ton tai va khong rong."
            Write-Hint 'Xoa thu muc do roi chay lai, hoac chon o dia khac.'
            [void]$blockers.Add('worktree')
        } else {
            $r = Invoke-Git $projectPath @('worktree','add','--detach',$worktreePath,'HEAD')
            if ($r.ExitCode -eq 0 -and (Test-Path $worktreePath)) {
                Write-Ok "Da tao worktree: $worktreePath"
            } else {
                Write-Bad "Tao worktree that bai tai: $worktreePath"
                if ($r.Output) { Write-Info $r.Output }
                if (-not (Test-CiRootValid $worktreePath)) {
                    Write-Hint 'Duong dan khong co o dia - chay lai install.bat va nhap vd E:\UnityCI'
                }
                [void]$blockers.Add('worktree')
            }
        }
    }
}

# --- script Unity ---
$editorDir = Join-CiPath $projectPath 'Assets\Editor\CI'
if (-not (Test-Path $editorDir)) { New-Item -ItemType Directory -Force -Path $editorDir | Out-Null }
foreach ($f in @('CIBuild.cs','CIBuildWindow.cs')) {
    $src = Join-Path $PSScriptRoot "unity\$f"
    if (Test-Path $src) { Copy-Item $src (Join-Path $editorDir $f) -Force }
}
Write-Ok 'Da chep script vao Assets/Editor/CI/'

# Bao cho Unity biet tool nam o dau (UserSettings mac dinh khong len git)
$userSettings = Join-CiPath $projectPath 'UserSettings'
if (-not (Test-Path $userSettings)) { New-Item -ItemType Directory -Force -Path $userSettings | Out-Null }
Write-JsonFile (Join-CiPath $userSettings 'CIBuildLink.json') ([pscustomobject]@{ toolDir = (Get-ToolDir) })

# --- ghi cau hinh ---
Write-CiConfig $cfg
Save-CiSecrets -Secrets $oldSecrets -DiscordCipher $discordCipher `
               -ProjectName $projectName -KeystorePass $ksPassCipher -KeyaliasPass $kaPassCipher
Write-Ok 'Da ghi config.json + secrets.json'

# ============================================================
#  XONG
# ============================================================
Write-Host ''
Write-Host '  ============================================================' -ForegroundColor Green
Write-Host '    CAI DAT XONG' -ForegroundColor Green
Write-Host '  ============================================================' -ForegroundColor Green
Write-Host ''
Write-Host '  PROJECT DANG CO' -ForegroundColor White
foreach ($p in $cfg.projects) {
    $star = if ($p.name -eq $cfg.defaultProject) { '*' } else { ' ' }
    Write-Host ("    {0} {1}" -f $star, $p.name) -ForegroundColor Gray
}
Write-Host '    (* = mac dinh khi khong go -Project)' -ForegroundColor DarkGray
Write-Host ''
Write-Host '  CACH DUNG' -ForegroundColor White
Write-Host '    Trong Unity : menu  CI Build > Build Android   (tu nhan dung project)' -ForegroundColor Gray
Write-Host '    Khong mo Unity : double-click build.bat' -ForegroundColor Gray
Write-Host '    Project khac   : .\ci.ps1 build -Project <ten>' -ForegroundColor Gray
Write-Host '    Xem tinh hinh  : .\ci.ps1 status' -ForegroundColor Gray
Write-Host ''
Write-Host '  FILE BUILD NAM TAI' -ForegroundColor White
Write-Host "    $buildsPath" -ForegroundColor Gray
Write-Host ''
Write-Host '  LUU Y LAN BUILD DAU' -ForegroundColor White
Write-Host '    Lan dau Unity phai import lai toan bo asset cho ban sao thu hai,' -ForegroundColor Gray
Write-Host '    nen co the mat 20-40 phut. Nhung lan sau chi con vai phut.' -ForegroundColor Gray
Write-Host ''

if ($blockers.Count -gt 0) {
    Write-Bad 'Van con thieu, build se chua chay duoc:'
    foreach ($b in $blockers) { Write-Info "  - $b" }
    Write-Host ''
} elseif (Read-YesNo 'Chay thu mot ban build dev ngay bay gio?' $false) {
    & (Join-Path $PSScriptRoot 'ci.ps1') build -Project $projectName -Format apk -Config dev -Force
}
