[CmdletBinding()]
param([switch]$CheckOnly)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'lib\Common.ps1')
. (Join-Path $PSScriptRoot 'lib\Queue.ps1')
. (Join-Path $PSScriptRoot 'lib\Agent.ps1')
. (Join-Path $PSScriptRoot 'lib\Unity.ps1')
Set-ConsoleUtf8

function Test-AgentAdmin {
    $id=[Security.Principal.WindowsIdentity]::GetCurrent()
    return (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}
if (-not (Test-AgentAdmin)) {
    $arg = '-NoProfile -ExecutionPolicy Bypass -File "{0}"' -f $PSCommandPath
    Start-Process powershell.exe -Verb RunAs -ArgumentList $arg -Wait
    exit $LASTEXITCODE
}

if ($CheckOnly) {
    $cfg = Read-CiConfig
    $doctor = Test-CiAgentDoctor -CiRoot $cfg.ciRoot -ToolDir $PSScriptRoot -AgentName $cfg.agentName
    foreach ($c in $doctor.Checks) { if ($c.Ok) { Write-Ok "$($c.Name): $($c.Message)" } else { Write-Bad "$($c.Name): $($c.Message)" } }
    exit $(if($doctor.Ready){0}else{1})
}

Write-Title 'Unity CI Build Agent Bootstrap'

$network = @(Get-NetConnectionProfile -ErrorAction SilentlyContinue)
if (@($network | Where-Object { $_.NetworkCategory -eq 'Public' }).Count -gt 0) {
    Write-Bad 'Network dang o Public; khong mo SMB de tranh expose ra ngoai.'
    Write-Hint 'Windows Settings > Network & Internet > Wi-Fi/Ethernet > Properties > Network profile: Private.'
    exit 1
}

function Get-TrustedGitPrefix {
    param([string]$Remote)
    $value = "$Remote".Trim().TrimEnd('/')
    if ($value -match '^(.*\/)[^\/]+$') { return $Matches[1] }
    return ''
}

$git=Get-Command git.exe -ErrorAction SilentlyContinue
if (-not $git) {
    $winget=Get-Command winget.exe -ErrorAction SilentlyContinue
    if ($winget) {
        Write-Info 'Git missing - installing Git.Git...'
        & winget install --id Git.Git --exact --silent --accept-package-agreements --accept-source-agreements
        $env:Path=[Environment]::GetEnvironmentVariable('Path','Machine')+';'+[Environment]::GetEnvironmentVariable('Path','User')
        $git=Get-Command git.exe -ErrorAction SilentlyContinue
    }
}
if (-not $git) { Write-Bad 'Git chua san sang. Cai Git roi chay lai install.bat va chon BUILD AGENT.'; exit 1 }
Write-Ok 'GIT READY'

$unityCli = Find-UnityCli
if (-not $unityCli.Available) {
    $winget=Get-Command winget.exe -ErrorAction SilentlyContinue
    if ($winget) {
        Write-Info 'Unity CLI missing - installing Unity.CLI...'
        & winget install --id Unity.CLI --exact --silent --accept-package-agreements --accept-source-agreements
        $env:Path=[Environment]::GetEnvironmentVariable('Path','Machine')+';'+[Environment]::GetEnvironmentVariable('Path','User')
        $unityCli=Find-UnityCli
    }
}
if ($unityCli.Available) { Write-Ok "UNITY CLI READY: $($unityCli.Path)" }
else { Write-Miss 'Unity CLI unavailable - doctor will require Unity Hub/auth before provisioning' }

if ($unityCli.Available) {
    $cliBackend = [pscustomobject]@{ Name='unity-cli'; Path=$unityCli.Path }
    $auth = Get-UnityAuthStatus $cliBackend
    if (-not $auth.Authenticated) {
        Write-Miss $auth.Message
        Write-Info 'Dang mo Unity auth login... hoan tat browser flow neu duoc hoi.'
        $login = Invoke-UnityAuthLogin $cliBackend
        $auth = Get-UnityAuthStatus $cliBackend
        if ($auth.Authenticated) { Write-Ok 'UNITY AUTH READY' }
        else { Write-Miss "AUTH REQUIRED: $($login.Output)" }
    } else { Write-Ok 'UNITY AUTH READY' }
    $license = Get-UnityLicenseStatus $cliBackend
    if ($license.Ready) { Write-Ok 'UNITY LICENSE READY' }
    else { Write-Miss "$($license.Message) - login/activate the license once, then rerun install.bat and choose BUILD AGENT" }
}

$oldConfig=Read-JsonFile (Get-ConfigPath)
$ciRoot=if ($oldConfig -and $oldConfig.role -eq 'agent' -and (Test-CiRootValid $oldConfig.ciRoot)) { $oldConfig.ciRoot } else { Get-BestCiRoot }
if (-not $oldConfig -or -not (Test-CiRootValid $oldConfig.ciRoot)) {
    $inputRoot = Read-Choice 'CI root (local path, Enter de dung goi y)' $ciRoot
    $resolvedRoot = Resolve-CiRootPath $inputRoot
    if ($resolvedRoot) { $ciRoot = $resolvedRoot }
}
if (-not (Test-Path $ciRoot)) { New-Item -ItemType Directory -Force -Path $ciRoot | Out-Null }
Write-RunnerLog ([pscustomobject]@{ ciRoot=$ciRoot }) 'BOOTSTRAP START'
Initialize-CiDirs ([pscustomobject]@{ciRoot=$ciRoot; worktreePath=''; buildsPath=''})
$trusted = if ($oldConfig -and $oldConfig.allowedGitRemotePrefixes) { @($oldConfig.allowedGitRemotePrefixes) } else { @() }
if ($trusted.Count -eq 0) {
    Write-Info 'Khai bao Git namespace trusted cho agent (vi du https://github.com/AMZG-Game/)'
    $prefix = Read-Choice 'Trusted Git prefix (bo trong de block repo moi)' ''
    if ($prefix) { $trusted = @($prefix.Trim().TrimEnd('/') + '/') }
}
$config=[pscustomobject]@{
    version=3; role='agent'; agentName=$(if ($oldConfig -and $oldConfig.agentName) { $oldConfig.agentName } else { $env:COMPUTERNAME })
    canBuild=$(if ($oldConfig -and $oldConfig.canBuild) { @($oldConfig.canBuild) } else { @('android') })
    pollSeconds=$(if ($oldConfig -and $oldConfig.pollSeconds) { $oldConfig.pollSeconds } else { 5 })
    ciRoot=$ciRoot
    reserveCoresForEditor=$(if ($oldConfig -and $oldConfig.reserveCoresForEditor -ne $null) { $oldConfig.reserveCoresForEditor } else { 0 })
    buildPerformanceMode=$(if ($oldConfig -and $oldConfig.buildPerformanceMode) { "$($oldConfig.buildPerformanceMode)" } else { 'max-speed' })
    buildTimeoutMinutes=$(if ($oldConfig -and $oldConfig.buildTimeoutMinutes) { $oldConfig.buildTimeoutMinutes } else { 90 })
    useNographics=$(if ($oldConfig -and $oldConfig.useNographics -ne $null) { $oldConfig.useNographics } else { $false })
    autoProvisionUnity=$true; autoShareCiRoot=$true; autoCreateTask=$true
    allowedGitRemotePrefixes=$trusted
    discord=$(if ($oldConfig -and $oldConfig.discord) { $oldConfig.discord } else { [pscustomobject]@{enabled=$false} })
    projects=$(if ($oldConfig -and $oldConfig.projects) { @($oldConfig.projects) } else { @() })
    remoteAgents=$(if ($oldConfig -and $oldConfig.remoteAgents) { @($oldConfig.remoteAgents) } else { @() })
}
$agentName = "$($config.agentName)"
Write-CiConfig $config
Write-Ok "CI ROOT READY: $ciRoot"
if (@($config.allowedGitRemotePrefixes).Count -eq 0) {
    Write-Miss 'BLOCKED FOR UNKNOWN PROJECTS - configure allowedGitRemotePrefixes in config.json'
}
foreach ($project in @($config.projects)) {
    if ($project.unityVersion) { Write-Info (Format-UnityEditorResolution "$($project.unityVersion)") }
}

$acl=Ensure-CiRootAcl $ciRoot; if ($acl.Success) { Write-Ok $acl.Message } else { Write-Miss "ACL: $($acl.Message)" }
$secureDir = Join-Path (Split-Path -Parent $ciRoot) 'UnityCISecure'
$secure = Ensure-CiSecureAcl $secureDir; if ($secure.Success) { Write-Ok "UnityCISecure: $($secure.Message)" } else { Write-Miss "UnityCISecure: $($secure.Message)" }
$fw=Ensure-CiSmbFirewall; if ($fw.Success) { Write-Ok $fw.Message } else { Write-Miss "Firewall: $($fw.Message)"; if($fw.PublicNetwork){ exit 1 } }
$share=Ensure-CiSmbShare -CiRoot $ciRoot
if ($share.Success) { Write-Ok 'SMB SHARE READY' } else { Write-Bad "SMB: $($share.Message)" }
$task=Ensure-CiAgentScheduledTask -ToolDir $PSScriptRoot
if ($task.Success) { Write-Ok 'SCHEDULED TASK READY' } else { Write-Miss "Task: $($task.Message)" }
if ($task.Success) {
    try { Start-ScheduledTask -TaskName 'UnityCIBuildAgent' -ErrorAction Stop } catch { Write-Miss "Khong start agent ngay duoc: $($_.Exception.Message)" }
}
if ($task.Success) {
    for ($i=0; $i -lt 10; $i++) {
        if (Test-Path -LiteralPath (Join-CiPath $ciRoot 'agents' "$agentName.json")) { break }
        Start-Sleep -Seconds 2
    }
}
$pair=New-CiPairingFile -CiRoot $ciRoot -AgentName $agentName
Write-Ok "PAIRING CODE: $($pair.pairCode) (expires $($pair.expiresAt))"
$doctor=Test-CiAgentDoctor -CiRoot $ciRoot -ToolDir $PSScriptRoot -AgentName $agentName
foreach ($c in $doctor.Checks) { if ($c.Ok) { Write-Ok "$($c.Name): $($c.Message)" } else { Write-Miss "$($c.Name): $($c.Message)" } }
Write-CiAgentReady -CiRoot $ciRoot -AgentName $agentName -Ready $doctor.Ready -Message $(if($doctor.Ready){'READY'}else{'doctor has blockers'})
if (-not $doctor.Ready) { Write-Bad 'BUILD AGENT BLOCKED - xem cac muc [THIEU]'; exit 1 }
Write-Ok 'BUILD AGENT READY'
Write-Host "  Share: \\$env:COMPUTERNAME\UnityCI" -ForegroundColor Gray
Write-Host '  SMB scope: trusted LAN/VPN only (Private/Domain + LocalSubnet), not Internet-facing.' -ForegroundColor Gray
Write-Host '  Unity Editor: on-demand' -ForegroundColor Gray
Write-RunnerLog ([pscustomobject]@{ ciRoot=$ciRoot }) 'BOOTSTRAP COMPLETE'
