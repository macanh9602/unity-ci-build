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

Write-Title 'Unity CI Build Agent Bootstrap'

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
if (-not $git) { Write-Bad 'Git chua san sang. Cai Git roi chay lai install-agent.bat.'; exit 1 }
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
    else { Write-Miss "$($license.Message) - login/activate the license once, then rerun install-agent.bat" }
}

$oldConfig=Read-JsonFile (Get-ConfigPath)
$ciRoot=if ($oldConfig -and (Test-CiRootValid $oldConfig.ciRoot)) { $oldConfig.ciRoot } else { Get-BestCiRoot }
if (-not (Test-Path $ciRoot)) { New-Item -ItemType Directory -Force -Path $ciRoot | Out-Null }
Write-RunnerLog ([pscustomobject]@{ ciRoot=$ciRoot }) 'BOOTSTRAP START'
Initialize-CiDirs ([pscustomobject]@{ciRoot=$ciRoot; worktreePath=''; buildsPath=''})
$config=[pscustomobject]@{
    version=3; role='agent'; agentName=$(if ($oldConfig -and $oldConfig.agentName) { $oldConfig.agentName } else { $env:COMPUTERNAME })
    canBuild=$(if ($oldConfig -and $oldConfig.canBuild) { @($oldConfig.canBuild) } else { @('android') })
    pollSeconds=$(if ($oldConfig -and $oldConfig.pollSeconds) { $oldConfig.pollSeconds } else { 5 })
    ciRoot=$ciRoot
    reserveCoresForEditor=$(if ($oldConfig -and $oldConfig.reserveCoresForEditor -ne $null) { $oldConfig.reserveCoresForEditor } else { 0 })
    buildTimeoutMinutes=$(if ($oldConfig -and $oldConfig.buildTimeoutMinutes) { $oldConfig.buildTimeoutMinutes } else { 90 })
    useNographics=$(if ($oldConfig -and $oldConfig.useNographics -ne $null) { $oldConfig.useNographics } else { $false })
    autoProvisionUnity=$true; autoShareCiRoot=$true; autoCreateTask=$true
    allowedGitRemotePrefixes=$(if ($oldConfig -and $oldConfig.allowedGitRemotePrefixes) { @($oldConfig.allowedGitRemotePrefixes) } else { @($oldConfig.projects | Where-Object { $_.gitRemote } | ForEach-Object { Get-TrustedGitPrefix $_.gitRemote } | Where-Object { $_ }) })
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

$acl=Ensure-CiRootAcl $ciRoot; if ($acl.Success) { Write-Ok $acl.Message } else { Write-Miss "ACL: $($acl.Message)" }
$fw=Ensure-CiSmbFirewall; if ($fw.Success) { Write-Ok $fw.Message } else { Write-Miss "Firewall: $($fw.Message)" }
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
Write-Host '  Unity Editor: on-demand' -ForegroundColor Gray
Write-RunnerLog ([pscustomobject]@{ ciRoot=$ciRoot }) 'BOOTSTRAP COMPLETE'
