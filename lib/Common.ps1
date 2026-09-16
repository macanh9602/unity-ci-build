# ============================================================
#  Common.ps1 - helper dung chung cho toan bo tool
# ============================================================
$ErrorActionPreference = 'Stop'
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}

$script:LibDir  = $PSScriptRoot
$script:ToolDir = Split-Path -Parent $PSScriptRoot

function Get-ToolDir    { $script:ToolDir }
function Get-ConfigPath { Join-Path $script:ToolDir 'config.json' }
function Get-SecretsPath{ Join-Path $script:ToolDir 'secrets.json' }

# ---------- console ----------
function Set-ConsoleUtf8 {
    try {
        [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
        $global:OutputEncoding    = [System.Text.Encoding]::UTF8
    } catch {}
}

function Write-Title([string]$Text) {
    Write-Host ''
    Write-Host ('  ' + $Text.ToUpper()) -ForegroundColor Cyan
    Write-Host ('  ' + ('-' * 58)) -ForegroundColor DarkCyan
}
function Write-Ok   ([string]$m) { Write-Host '  [OK]    ' -ForegroundColor Green   -NoNewline; Write-Host $m }
function Write-Miss ([string]$m) { Write-Host '  [THIEU] ' -ForegroundColor Yellow  -NoNewline; Write-Host $m }
function Write-Bad  ([string]$m) { Write-Host '  [LOI]   ' -ForegroundColor Red     -NoNewline; Write-Host $m }
function Write-Info ([string]$m) { Write-Host '  ' -NoNewline; Write-Host $m -ForegroundColor Gray }
function Write-Hint ([string]$m) { Write-Host '          -> ' -ForegroundColor DarkGray -NoNewline; Write-Host $m -ForegroundColor DarkGray }

function Read-Choice {
    param([string]$Prompt, [string]$Default = '')
    if ($Default) { $p = "  $Prompt [$Default]: " } else { $p = "  $Prompt : " }
    Write-Host $p -ForegroundColor White -NoNewline
    $v = Read-Host
    if ([string]::IsNullOrWhiteSpace($v)) { return $Default }
    return $v.Trim()
}

function Read-YesNo {
    param([string]$Prompt, [bool]$Default = $true)
    $d = if ($Default) { 'Y/n' } else { 'y/N' }
    while ($true) {
        Write-Host "  $Prompt [$d]: " -ForegroundColor White -NoNewline
        $v = (Read-Host).Trim().ToLower()
        if ($v -eq '') { return $Default }
        if ($v -in @('y','yes','c','co')) { return $true }
        if ($v -in @('n','no','k','khong')) { return $false }
    }
}

# ---------- file io ----------
function Set-Utf8NoBom {
    param([string]$Path, [string]$Text)
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    $enc = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $Text, $enc)
}

function Read-JsonFile([string]$Path) {
    if (-not (Test-Path $Path)) { return $null }
    $raw = [System.IO.File]::ReadAllText($Path)
    if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
    return ($raw | ConvertFrom-Json)
}

function Write-JsonFile([string]$Path, $Object) {
    Set-Utf8NoBom -Path $Path -Text ($Object | ConvertTo-Json -Depth 10)
}

# ---------- config (v2: nhieu project) ----------
#  config.json v2:
#    { version, ciRoot, reserveCoresForEditor, buildTimeoutMinutes, useNographics,
#      discord:{enabled}, defaultProject, projects:[ {name, projectPath, unityExe,
#      unityVersion, worktreePath, buildsPath, drive:{}, android:{}} ] }
#
#  Cai dat CHUNG (o dia, so core, timeout, Discord) dung chung moi project.
#  Rieng tung project: duong dan, Unity, noi do file, keystore.

function Test-CiHasProp { param($Obj, [string]$Name) if (-not $Obj) { return $false } ; return ($Obj.PSObject.Properties.Name -contains $Name) }

# v3 them khai niem VAI TRO, de mot may co the chi dat lenh con may khac build.
#   standalone - mot may lam ca hai (nhu truoc gio)
#   client     - chi day job vao queue, khong build
#   agent      - chi build, khong dat lenh
function ConvertTo-CiConfigV3 {
    param($Cfg)
    if (-not $Cfg) { return $null }
    if (-not (Test-CiHasProp $Cfg 'role')) {
        Add-Member -InputObject $Cfg -NotePropertyName role      -NotePropertyValue 'standalone' -Force
    }
    if (-not (Test-CiHasProp $Cfg 'agentName')) {
        Add-Member -InputObject $Cfg -NotePropertyName agentName -NotePropertyValue $env:COMPUTERNAME -Force
    }
    if (-not (Test-CiHasProp $Cfg 'canBuild')) {
        Add-Member -InputObject $Cfg -NotePropertyName canBuild  -NotePropertyValue @('android') -Force
    }
    if (-not (Test-CiHasProp $Cfg 'pollSeconds')) {
        Add-Member -InputObject $Cfg -NotePropertyName pollSeconds -NotePropertyValue 5 -Force
    }
    foreach ($name in @('autoProvisionUnity','autoShareCiRoot','autoCreateTask')) {
        if (-not (Test-CiHasProp $Cfg $name)) {
            Add-Member -InputObject $Cfg -NotePropertyName $name -NotePropertyValue $true -Force
        }
    }
    foreach ($p in $Cfg.projects) {
        if (-not (Test-CiHasProp $p 'gitRemote')) {
            Add-Member -InputObject $p -NotePropertyName gitRemote -NotePropertyValue '' -Force
        }
    }
    Add-Member -InputObject $Cfg -NotePropertyName version -NotePropertyValue 3 -Force
    return $Cfg
}

function ConvertTo-CiConfigV2 {
    param($Cfg)
    if (-not $Cfg) { return $null }
    if ($Cfg.PSObject.Properties.Name -contains 'projects') { return $Cfg }

    # config v1 - goi ca cau hinh cu vao lam project dau tien, khong mat gi
    [pscustomobject]@{
        version               = 2
        ciRoot                = $Cfg.ciRoot
        reserveCoresForEditor = $Cfg.reserveCoresForEditor
        buildTimeoutMinutes   = $Cfg.buildTimeoutMinutes
        useNographics         = $Cfg.useNographics
        autoProvisionUnity    = $Cfg.autoProvisionUnity
        autoShareCiRoot       = $Cfg.autoShareCiRoot
        autoCreateTask        = $Cfg.autoCreateTask
        discord               = $Cfg.discord
        defaultProject        = $Cfg.projectName
        projects              = @(
            [pscustomobject]@{
                name         = $Cfg.projectName
                projectPath  = $Cfg.projectPath
                unityExe     = $Cfg.unityExe
                unityVersion = $Cfg.unityVersion
                worktreePath = $Cfg.worktreePath
                buildsPath   = $Cfg.buildsPath
                drive        = $Cfg.drive
                android      = $Cfg.android
            }
        )
    }
}

function Read-CiConfig {
    $p = Get-ConfigPath
    $c = Read-JsonFile $p
    if (-not $c) { throw "Chua cai dat. Chay install.bat truoc." }

    $needMigrate = (-not (Test-CiHasProp $c 'projects')) -or (-not (Test-CiHasProp $c 'role'))
    $c = ConvertTo-CiConfigV2 $c
    $c = ConvertTo-CiConfigV3 $c
    if ($needMigrate) { try { Write-JsonFile $p $c } catch {} }   # ghi lai mot lan
    return $c
}

function Write-CiConfig { param($Cfg) Write-JsonFile (Get-ConfigPath) $Cfg }

function Test-CiInstalled { Test-Path (Get-ConfigPath) }

function Get-CiProjectNames { param($Cfg) @($Cfg.projects | ForEach-Object { $_.name }) }

function Get-CiProject {
    param($Cfg, [string]$Name = '')
    if (-not $Cfg.projects -or @($Cfg.projects).Count -eq 0) { return $null }
    if (-not $Name) { $Name = "$($Cfg.defaultProject)" }
    $p = $Cfg.projects | Where-Object { $_.name -eq $Name } | Select-Object -First 1
    if (-not $p) { $p = @($Cfg.projects)[0] }
    return $p
}

# Tim project theo duong dan thu muc (cho Unity Editor tu nhan dung project)
function Find-CiProjectByPath {
    param($Cfg, [string]$Path)
    if (-not $Path) { return $null }
    $norm = $Path.TrimEnd('\','/').ToLower()
    $Cfg.projects | Where-Object { "$($_.projectPath)".TrimEnd('\','/').ToLower() -eq $norm } | Select-Object -First 1
}

# Gop cai dat chung + cai dat cua mot project thanh mot object phang,
# dung y het hinh dang config v1 -> runner va Drive.ps1 khong phai sua gi.
function Get-EffectiveConfig {
    param($Cfg, [string]$ProjectName = '')
    $p = Get-CiProject $Cfg $ProjectName
    if (-not $p) { throw "Chua co project nao trong config. Chay install.bat." }
    [pscustomobject]@{
        version               = 2
        projectName           = $p.name
        projectPath           = $p.projectPath
        unityExe              = $p.unityExe
        unityVersion          = $p.unityVersion
        worktreePath          = $p.worktreePath
        buildsPath            = $p.buildsPath
        gitRemote             = $p.gitRemote
        drive                 = $p.drive
        android               = $p.android
        role                  = $Cfg.role
        agentName             = $Cfg.agentName
        pollSeconds           = $Cfg.pollSeconds
        ciRoot                = $Cfg.ciRoot
        reserveCoresForEditor = $Cfg.reserveCoresForEditor
        buildTimeoutMinutes   = $Cfg.buildTimeoutMinutes
        useNographics         = $Cfg.useNographics
        autoProvisionUnity    = $Cfg.autoProvisionUnity
        autoShareCiRoot       = $Cfg.autoShareCiRoot
        autoCreateTask        = $Cfg.autoCreateTask
        discord               = $Cfg.discord
    }
}

# ---------- secrets (DPAPI - chi giai ma duoc boi chinh user nay tren chinh may nay) ----------
function Protect-CiString([string]$Plain) {
    if ([string]::IsNullOrEmpty($Plain)) { return '' }
    return (ConvertTo-SecureString $Plain -AsPlainText -Force | ConvertFrom-SecureString)
}

function Unprotect-CiString([string]$Cipher) {
    if ([string]::IsNullOrEmpty($Cipher)) { return '' }
    try {
        $ss = ConvertTo-SecureString $Cipher
        $b  = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($ss)
        try   { return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($b) }
        finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($b) }
    } catch { return '' }
}

function Read-CiSecrets {
    $s = Read-JsonFile (Get-SecretsPath)
    if (-not $s) {
        $s = [pscustomobject]@{ discordWebhook=''; projects=[pscustomobject]@{} }
    }
    return $s
}

# Keystore la cua tung project, khong dung chung -> luu long theo ten project.
# secrets.json: { discordWebhook, projects: { <ten>: { keystorePass, keyaliasPass } } }
function Get-ProjectSecretRaw {
    param($Secrets, [string]$ProjectName, [string]$Name)
    if (-not $Secrets) { return '' }
    if ($ProjectName -and $Secrets.PSObject.Properties.Name -contains 'projects' -and $Secrets.projects) {
        $p = $Secrets.projects.$ProjectName
        if ($p -and $p.$Name) { return "$($p.$Name)" }
    }
    # secrets.json doi cu chi co mot project -> van doc duoc
    if ($Secrets.PSObject.Properties.Name -contains $Name -and $Secrets.$Name) { return "$($Secrets.$Name)" }
    return ''
}

function Get-ProjectSecret {
    param($Secrets, [string]$ProjectName, [string]$Name)
    Unprotect-CiString (Get-ProjectSecretRaw $Secrets $ProjectName $Name)
}

function Save-CiSecrets {
    param(
        $Secrets,
        [string]$DiscordCipher = '',
        [string]$ProjectName   = '',
        [string]$KeystorePass  = '',
        [string]$KeyaliasPass  = ''
    )
    $bag = @{}
    if ($Secrets -and $Secrets.PSObject.Properties.Name -contains 'projects' -and $Secrets.projects) {
        foreach ($prop in $Secrets.projects.PSObject.Properties) { $bag[$prop.Name] = $prop.Value }
    }
    if ($ProjectName) {
        $bag[$ProjectName] = [pscustomobject]@{ keystorePass = $KeystorePass; keyaliasPass = $KeyaliasPass }
    }
    Write-JsonFile (Get-SecretsPath) ([pscustomobject]@{
        discordWebhook = $DiscordCipher
        projects       = [pscustomobject]$bag
    })
}

function Get-Secret($secrets, [string]$Name) {
    if (-not $secrets) { return '' }
    $v = $secrets.$Name
    if (-not $v) { return '' }
    return (Unprotect-CiString $v)
}

# ---------- paths ----------
# Noi duong dan bang chuoi thuan.
# Join-Path cua PowerShell di qua provider -> no CO GANG resolve o dia,
# nen nem loi voi duong dan Windows tren may khong co o do, va lam
# code khong test duoc ngoai Windows. Duong dan o day chi la du lieu.
function Join-CiPath {
    param([string]$Base, [Parameter(ValueFromRemainingArguments=$true)][string[]]$Parts)
    $b = "$Base"
    # Giu nguyen kieu dau phan cach cua chinh duong dan goc
    $sep = if ($b.StartsWith('/')) { '/' } else { '\' }
    $p = $b.TrimEnd('\','/')
    foreach ($x in $Parts) {
        if (-not $x) { continue }
        $p = $p + $sep + ("$x").Trim('\','/')
    }
    return $p
}

function Get-CiPaths($cfg) {
    [pscustomobject]@{
        Root       = $cfg.ciRoot
        Queue      = Join-CiPath $cfg.ciRoot 'queue'
        Processing = Join-CiPath $cfg.ciRoot 'processing'
        Results    = Join-CiPath $cfg.ciRoot 'results'
        Logs       = Join-CiPath $cfg.ciRoot 'logs'
        Worktree   = $cfg.worktreePath
        Builds     = $cfg.buildsPath
        RunnerLog  = Join-CiPath $cfg.ciRoot 'runner.log'
    }
}

function Initialize-CiDirs($cfg) {
    $p = Get-CiPaths $cfg
    foreach ($d in @($p.Root,$p.Queue,$p.Processing,$p.Results,$p.Logs,$p.Builds)) {
        if ($d -and -not (Test-Path $d)) { New-Item -ItemType Directory -Force -Path $d | Out-Null }
    }
}

function Write-RunnerLog($cfg, [string]$Message) {
    try {
        $p = Get-CiPaths $cfg
        $line = '[{0}] {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
        Add-Content -Path $p.RunnerLog -Value $line -Encoding UTF8
    } catch {}
}

# ---------- git ----------
function Invoke-Git {
    param([string]$RepoPath, [string[]]$GitArgs)
    # git ghi thong tin ra stderr ca khi thanh cong -> phai ha ErrorAction,
    # neu khong PowerShell se nem NativeCommandError va giet ca runner.
    $old = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $all = @('-C', $RepoPath) + $GitArgs
        $out = & git @all 2>&1
        return [pscustomobject]@{
            ExitCode = $LASTEXITCODE
            Output   = (($out | ForEach-Object { "$_" }) -join "`n")
        }
    } finally { $ErrorActionPreference = $old }
}

function ConvertTo-IntSafe {
    param($Value, [int]$Default = 0)
    $n = 0
    if ([int]::TryParse(("$Value").Trim(), [ref]$n)) { return $n }
    return $Default
}

function Get-GitInfo([string]$RepoPath) {
    $old = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
    $sha     = (& git -C $RepoPath rev-parse HEAD 2>$null)
    if ($LASTEXITCODE -ne 0 -or -not $sha) { return $null }
    $branch  = (& git -C $RepoPath rev-parse --abbrev-ref HEAD 2>$null)
    $subject = (& git -C $RepoPath log -1 --pretty=%s 2>$null)
    $dirty   = (& git -C $RepoPath status --porcelain 2>$null)
    $count   = (& git -C $RepoPath rev-list --count HEAD 2>$null)
    [pscustomobject]@{
        Sha        = "$sha".Trim()
        ShaShort   = "$sha".Trim().Substring(0, 7)
        Branch     = "$branch".Trim()
        Subject    = "$subject".Trim()
        IsDirty    = -not [string]::IsNullOrWhiteSpace(($dirty -join ''))
        DirtyCount = @($dirty).Where({ $_ }).Count
        CommitCount= (ConvertTo-IntSafe $count 0)
    }
    } finally { $ErrorActionPreference = $old }
}

# Chuan hoa duong dan goc cua CI.
# Bay da dinh: go 'E' hoac 'E:' deu KHONG phai duong dan tuyet doi.
#   'E'   -> duong dan tuong doi, folder ten E nam canh script
#   'E:'  -> "thu muc hien hanh cua o E", khong phai goc o E
# Ca hai deu tao ra worktree sai cho ma khong bao loi gi.
#
# Luat duong dan Windows viet thang bang regex chu khong goi [System.IO.Path],
# vi cac API do doi hanh vi theo he dieu hanh -> khong test duoc ngoai Windows.
function Test-CiRootValid {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    if ($Path -match '^[A-Za-z]:\\') { return $true }          # E:\...
    if ($Path -match '^\\\\[^\\]+\\[^\\]+') { return $true }    # \\server\share\...
    return $false
}

function Resolve-CiRootPath {
    param([string]$InputPath, [string]$LeafName = 'UnityCI')
    $p = ("$InputPath").Trim().Trim('"').Trim("'")
    if (-not $p) { return '' }

    # Chi go chu cai o dia: E / e / E: / E:\  -> <X>:\<LeafName>
    if ($p -match '^([A-Za-z]):?\\?$') {
        return ($Matches[1].ToUpper() + ':\' + $LeafName)
    }
    # Go 'E:something' (thieu gach cheo) -> 'E:\something'
    if ($p -match '^([A-Za-z]):([^\\/].*)$') {
        $p = $Matches[1].ToUpper() + ':\' + $Matches[2]
    }
    $p = $p -replace '/', '\'
    if (-not (Test-CiRootValid $p)) { return '' }
    return $p.TrimEnd('\')
}

# ---------- worktree safety / recovery ----------
function Get-CiNormalizedPath {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return '' }
    try {
        return ([System.IO.Path]::GetFullPath($Path)).TrimEnd('\','/').ToLowerInvariant()
    } catch { return '' }
}

function Test-CiOwnedWorktreePath {
    param(
        [string]$CiRoot,
        [string]$ProjectName,
        [string]$ProjectPath,
        [string]$WorktreePath
    )
    $expected = Get-CiNormalizedPath (Join-CiPath $CiRoot 'worktree' $ProjectName)
    $target   = Get-CiNormalizedPath $WorktreePath
    $source   = Get-CiNormalizedPath $ProjectPath
    return ($target -and $expected -and $target -eq $expected -and $target -ne $source)
}

function Test-GitWorktreeRegistered {
    param(
        [string]$ProjectPath,
        [string]$WorktreePath
    )
    if (-not (Test-CiWorktreeUsable -WorktreePath $ProjectPath)) { return $false }
    $r = Invoke-Git $ProjectPath @('worktree','list','--porcelain')
    if ($r.ExitCode -ne 0) { return $false }
    $target = Get-CiNormalizedPath $WorktreePath
    foreach ($line in ($r.Output -split "`r?`n")) {
        if ($line -match '^worktree\s+(.+)$' -and (Get-CiNormalizedPath $Matches[1]) -eq $target) {
            return $true
        }
    }
    return $false
}

function Test-CiWorktreeUsable {
    param([string]$WorktreePath)
    if (-not (Test-Path -LiteralPath $WorktreePath -PathType Container)) { return $false }
    $r = Invoke-Git $WorktreePath @('rev-parse','--is-inside-work-tree')
    return ($r.ExitCode -eq 0 -and $r.Output -match 'true')
}

function Repair-CiWorktree {
    param(
        [string]$ProjectPath,
        [string]$WorktreePath
    )
    Write-Host '  WORKTREE REPAIR - attempting' -ForegroundColor Yellow
    $r = Invoke-Git $ProjectPath @('worktree','repair',$WorktreePath)
    $ok = ($r.ExitCode -eq 0) -and
          (Test-GitWorktreeRegistered $ProjectPath $WorktreePath) -and
          (Test-CiWorktreeUsable $WorktreePath)
    return [pscustomobject]@{ Success = $ok; Output = $r.Output }
}

function Remove-StaleCiWorktree {
    param(
        [string]$CiRoot,
        [string]$ProjectName,
        [string]$ProjectPath,
        [string]$WorktreePath
    )
    if (-not (Test-CiOwnedWorktreePath $CiRoot $ProjectName $ProjectPath $WorktreePath)) {
        Write-Host "  WORKTREE FAIL - unsafe cleanup path: $WorktreePath" -ForegroundColor Red
        return $false
    }

    try {
        $r = Invoke-Git $ProjectPath @('worktree','remove','--force',$WorktreePath)
        # Metadata may already be damaged; unregister failure is non-fatal.
        $null = $r
    } catch {}
    try { Invoke-Git $ProjectPath @('worktree','prune') | Out-Null } catch {}
    try {
        if (Test-Path -LiteralPath $WorktreePath) {
            Remove-Item -LiteralPath $WorktreePath -Recurse -Force -ErrorAction Stop
        }
        if (Test-Path -LiteralPath $WorktreePath) {
            Write-Host '  WORKTREE CLEANUP ERROR: target still exists after delete' -ForegroundColor Red
            return $false
        }
    } catch {
        Write-Host "  WORKTREE CLEANUP ERROR: $($_.Exception.Message)" -ForegroundColor Red
        return $false
    }
    return $true
}

function New-CiWorktree {
    param(
        [string]$ProjectPath,
        [string]$WorktreePath
    )
    try {
        $parent = Split-Path -Parent $WorktreePath
        if ($parent -and -not (Test-Path -LiteralPath $parent -PathType Container)) {
            New-Item -ItemType Directory -Force -Path $parent | Out-Null
        }
        if (Test-Path -LiteralPath $WorktreePath) {
            $items = @(Get-ChildItem -LiteralPath $WorktreePath -Force -ErrorAction Stop)
            if ($items.Count -gt 0) {
                return [pscustomobject]@{ Success = $false; Output = 'target directory is not empty' }
            }
        }
    } catch {
        return [pscustomobject]@{ Success = $false; Output = "filesystem error: $($_.Exception.Message)" }
    }
    $r = Invoke-Git $ProjectPath @('worktree','add','--detach',$WorktreePath,'HEAD')
    $ok = ($r.ExitCode -eq 0) -and
          (Test-GitWorktreeRegistered $ProjectPath $WorktreePath) -and
          (Test-CiWorktreeUsable $WorktreePath)
    return [pscustomobject]@{ Success = $ok; Output = $r.Output }
}

function Ensure-CiWorktree {
    param(
        [string]$CiRoot,
        [string]$ProjectName,
        [string]$ProjectPath,
        [string]$WorktreePath
    )
    if (-not (Test-CiOwnedWorktreePath $CiRoot $ProjectName $ProjectPath $WorktreePath)) {
        Write-Host "  WORKTREE FAIL - unsafe target: $WorktreePath" -ForegroundColor Red
        return $false
    }
    if (-not (Test-CiWorktreeUsable $ProjectPath)) {
        Write-Host '  WORKTREE FAIL - source repo unusable' -ForegroundColor Red
        return $false
    }

    $exists = Test-Path -LiteralPath $WorktreePath -PathType Container
    $registered = Test-GitWorktreeRegistered $ProjectPath $WorktreePath
    $usable = Test-CiWorktreeUsable $WorktreePath
    if ($exists -and $registered -and $usable) {
        Write-Host '  WORKTREE REUSE' -ForegroundColor Green
        return $true
    }

    if ($exists) {
        $repair = Repair-CiWorktree $ProjectPath $WorktreePath
        if ($repair.Success) {
            Write-Host '  WORKTREE REPAIR SUCCESS' -ForegroundColor Green
            return $true
        }
        if ($repair.Output) { Write-Host "  WORKTREE REPAIR ERROR: $($repair.Output)" -ForegroundColor DarkYellow }
        Write-Host '  WORKTREE RECREATE' -ForegroundColor Yellow
        if (-not (Remove-StaleCiWorktree $CiRoot $ProjectName $ProjectPath $WorktreePath)) { return $false }
    } else {
        try { Invoke-Git $ProjectPath @('worktree','prune') | Out-Null } catch {}
    }

    for ($attempt = 1; $attempt -le 2; $attempt++) {
        $created = New-CiWorktree $ProjectPath $WorktreePath
        if ($created.Success) {
            Write-Host '  WORKTREE RECREATE SUCCESS' -ForegroundColor Green
            return $true
        }
        if ($created.Output) { Write-Host "  WORKTREE CREATE ERROR: $($created.Output)" -ForegroundColor DarkYellow }
        if ($attempt -eq 1) {
            if (-not (Remove-StaleCiWorktree $CiRoot $ProjectName $ProjectPath $WorktreePath)) { return $false }
        }
    }
    Write-Host '  WORKTREE FAIL' -ForegroundColor Red
    return $false
}

# Uoc tinh thoi gian build tu cac lan THANH CONG truoc do cua dung
# project + dung loai build. Dung trung vi de mot lan bat thuong
# (may ban, build lan dau import lai tu dau) khong keo lech.
function Test-CiIsAgent  { param($Cfg) "$($Cfg.role)" -in @('agent','standalone') }
function Test-CiIsClient { param($Cfg) "$($Cfg.role)" -in @('client','standalone') }

# Lay dia chi remote cua repo (de may build biet clone tu dau)
function Get-GitRemoteUrl {
    param([string]$RepoPath, [string]$Name = 'origin')
    $old = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try {
        $u = & git -C $RepoPath remote get-url $Name 2>$null
        if ($LASTEXITCODE -ne 0) { return '' }
        return ("$u").Trim()
    } catch { return '' } finally { $ErrorActionPreference = $old }
}

# May build clone tu remote, nen commit CHUA PUSH thi no khong the thay.
# Phai kiem tra truoc khi xep hang, khong de build chay roi moi chet.
function Test-CiShaOnRemote {
    param([string]$RepoPath, [string]$Sha, [switch]$SkipFetch)
    $old = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try {
        if (-not $SkipFetch) { & git -C $RepoPath fetch --quiet 2>$null | Out-Null }
        $out = & git -C $RepoPath branch -r --contains $Sha 2>$null
        if ($LASTEXITCODE -ne 0) { return $false }
        return (@($out | Where-Object { "$_".Trim() }).Count -gt 0)
    } catch { return $false } finally { $ErrorActionPreference = $old }
}

# Doc nhip tim cua cac agent tren o chung -> biet may build con song khong
# May nay co du do nghe de tu build khong (dung khi may build chet)
function Test-CiCanBuildLocally {
    param($Root, $Proj)
    $r = [pscustomobject]@{ Ok = $false; NeedsWorktree = $false; Reason = '' }
    if (-not $Proj) { $r.Reason = 'Chua cau hinh project tren may nay'; return $r }
    if (-not $Proj.unityExe -or -not (Test-Path $Proj.unityExe)) {
        $r.Reason = "May nay chua cai Unity $($Proj.unityVersion)"
        return $r
    }
    if (-not (Test-Path (Join-CiPath $Proj.worktreePath '.git'))) { $r.NeedsWorktree = $true }
    $r.Ok = $true
    return $r
}

function Get-CiLiveAgents {
    param($Cfg, [string]$Platform = 'android')
    @(Get-CiAgents $Cfg) | Where-Object { $_.Alive -and (@($_.canBuild) -contains $Platform) }
}

function Get-CiAgents {
    param($Cfg)
    try {
        $dir = Join-CiPath $Cfg.ciRoot 'agents'
        if (-not (Test-Path $dir)) { return @() }
        $out = New-Object System.Collections.ArrayList
        foreach ($f in (Get-ChildItem -Path $dir -Filter '*.json' -ErrorAction SilentlyContinue)) {
            $a = Read-JsonFile $f.FullName
            if (-not $a) { continue }
            $age = 99999
            try { $age = ((Get-Date) - [datetime]$a.lastSeen).TotalSeconds } catch {}
            Add-Member -InputObject $a -NotePropertyName AgeSeconds -NotePropertyValue $age -Force
            Add-Member -InputObject $a -NotePropertyName Alive      -NotePropertyValue ($age -lt 60) -Force
            [void]$out.Add($a)
        }
        return $out.ToArray()
    } catch { return @() }
}

# Branch cua lan build gan nhat cua project -> de canh bao khi doi branch
# Liet ke branch (local + remote), bo tien to origin/ va gop trung
function Get-CiBranches {
    param([string]$RepoPath)
    $old = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try {
        $out = & git -C $RepoPath for-each-ref --format='%(refname:short)' refs/heads refs/remotes 2>$null
        if ($LASTEXITCODE -ne 0) { return @() }
        $seen = New-Object 'System.Collections.Generic.HashSet[string]'
        $list = New-Object System.Collections.ArrayList
        foreach ($r in $out) {
            $n = ("$r").Trim()
            if (-not $n -or $n.EndsWith('/HEAD')) { continue }
            if ($n.StartsWith('origin/')) { $n = $n.Substring(7) }
            if ($seen.Add($n)) { [void]$list.Add($n) }
        }
        return $list.ToArray()
    } catch { return @() } finally { $ErrorActionPreference = $old }
}

# Lay dinh cua mot branch MA KHONG doi working copy cua nguoi dung.
# Thu branch local truoc, khong co thi thu origin/<branch>.
function Resolve-CiBranchTip {
    param([string]$RepoPath, [string]$Branch)
    $old = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try {
        foreach ($ref in @($Branch, "origin/$Branch")) {
            $sha = & git -C $RepoPath rev-parse --verify --quiet ($ref + '^{commit}') 2>$null
            if ($LASTEXITCODE -ne 0 -or -not $sha) { continue }
            $sha = ("$sha").Trim()
            if ($sha.Length -lt 7) { continue }
            $subject = & git -C $RepoPath log -1 --pretty=%s $sha 2>$null
            $count   = & git -C $RepoPath rev-list --count $sha 2>$null
            return [pscustomobject]@{
                Sha         = $sha
                ShaShort    = $sha.Substring(0,7)
                Branch      = $Branch
                Subject     = ("$subject").Trim()
                CommitCount = (ConvertTo-IntSafe $count 0)
                IsDirty     = $false     # build branch khac -> file chua commit khong lien quan
                DirtyCount  = 0
                Ref         = $ref
            }
        }
        return $null
    } catch { return $null } finally { $ErrorActionPreference = $old }
}

function Get-CiLastBuiltBranch {
    param($Config, [string]$ProjectName)
    try {
        $paths = Get-CiPaths $Config
        if (-not (Test-Path $paths.Results)) { return '' }
        foreach ($f in @(Get-ChildItem -Path $paths.Results -Filter '*.json' -ErrorAction SilentlyContinue |
                         Sort-Object Name -Descending | Select-Object -First 30)) {
            $r = Read-JsonFile $f.FullName
            if ($r -and "$($r.project)" -eq $ProjectName -and $r.branch) { return "$($r.branch)" }
        }
    } catch {}
    return ''
}

# versionCode = so commit, ma hai branch rat de co cung so commit.
# Trung versionCode nhung khac commit thi Android coi la cung mot ban,
# cai chong len khong update -> ngoi test nham ban cu ma khong biet.
function Get-CiVersionCodeConflict {
    param($Config, [string]$ProjectName, [int]$VersionCode, [string]$Sha)
    try {
        if ($VersionCode -le 0) { return $null }
        $paths = Get-CiPaths $Config
        if (-not (Test-Path $paths.Results)) { return $null }
        foreach ($f in @(Get-ChildItem -Path $paths.Results -Filter '*.json' -ErrorAction SilentlyContinue |
                         Sort-Object Name -Descending | Select-Object -First 50)) {
            $r = Read-JsonFile $f.FullName
            if (-not $r -or -not $r.success) { continue }
            if ("$($r.project)" -ne $ProjectName) { continue }
            if ([int]$r.versionCode -ne $VersionCode) { continue }
            if ("$($r.sha)" -eq $Sha) { continue }     # cung commit thi khong sao
            return $r
        }
    } catch {}
    return $null
}

# Ten branch dung lam ten file: bo ky tu Windows khong cho
function ConvertTo-CiSafeName {
    param([string]$Name, [int]$Max = 24)
    $s = ("$Name") -replace '[\\/:*?"<>|\s]', '-'
    $s = $s -replace '-+', '-'
    $s = $s.Trim('-')
    if ($s.Length -gt $Max) { $s = $s.Substring(0, $Max).Trim('-') }
    if (-not $s) { $s = 'nobranch' }
    return $s
}

function Get-CiEtaSeconds {
    param($Config, [string]$ProjectName, [string]$Format, [string]$BuildConfig, [int]$Samples = 5)
    try {
        $paths = Get-CiPaths $Config
        if (-not (Test-Path $paths.Results)) { return 0 }
        $files = @(Get-ChildItem -Path $paths.Results -Filter '*.json' -ErrorAction SilentlyContinue |
                   Sort-Object Name -Descending | Select-Object -First 50)
        $vals = New-Object System.Collections.ArrayList
        foreach ($f in $files) {
            $r = Read-JsonFile $f.FullName
            if (-not $r -or -not $r.success) { continue }
            if ("$($r.project)" -ne $ProjectName) { continue }
            if ("$($r.format)"  -ne $Format)      { continue }
            if ("$($r.config)"  -ne $BuildConfig) { continue }
            [void]$vals.Add([double]$r.durationSec)
            if ($vals.Count -ge $Samples) { break }
        }
        if ($vals.Count -eq 0) { return 0 }
        $sorted = @($vals | Sort-Object)
        return [double]$sorted[[int][Math]::Floor($sorted.Count / 2)]
    } catch { return 0 }
}

function Format-Bytes([long]$Bytes) {
    if ($Bytes -ge 1GB) { return ('{0:N1} GB' -f ($Bytes / 1GB)) }
    if ($Bytes -ge 1MB) { return ('{0:N1} MB' -f ($Bytes / 1MB)) }
    if ($Bytes -ge 1KB) { return ('{0:N0} KB' -f ($Bytes / 1KB)) }
    return "$Bytes B"
}

function Format-Duration([double]$Seconds) {
    $ts = [TimeSpan]::FromSeconds($Seconds)
    if ($ts.TotalHours -ge 1) { return ('{0}h {1}m' -f [int]$ts.TotalHours, $ts.Minutes) }
    if ($ts.TotalMinutes -ge 1) { return ('{0}m {1}s' -f [int]$ts.TotalMinutes, $ts.Seconds) }
    return ('{0}s' -f [int]$ts.TotalSeconds)
}
