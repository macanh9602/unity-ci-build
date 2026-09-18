# Dedicated DEV client setup. The client never owns CI directories or a local build worker.

function Setup-Client {
    param($Existing, [switch]$CheckOnly)

    Write-Title 'DEV CLIENT - Dedicated Build Machine'
    Write-Info 'May nay chi giu project dev va gui job sang build machine.'

    if ($CheckOnly) {
        $project = if ($Existing) { Get-CiProject $Existing } else { $null }
        $ok = $true
        if (-not $project -or -not (Test-UnityProject $project.projectPath)) { Write-Bad 'Local Unity project invalid'; $ok = $false }
        else {
            $g = Get-GitInfo $project.projectPath
            if ($g) { Write-Ok "Git valid: $($g.Branch) / $($g.ShaShort)" } else { Write-Bad 'Git invalid'; $ok = $false }
            if (Get-GitRemoteUrl $project.projectPath) { Write-Ok 'Git remote valid' } else { Write-Bad 'Git remote missing'; $ok = $false }
        }
        if ($Existing -and (Test-CiRootValid $Existing.ciRoot)) {
            if (-not (Test-CiClientShareReachable $Existing.ciRoot)) {
                Write-Bad 'NETWORK/SMB BLOCKED: Khong ket noi duoc build machine / UnityCI share'
                return $false
            }
            Write-Ok 'Remote share reachable'
            $access = Test-CiClientRemoteAccess $Existing.ciRoot
            foreach ($c in $access.Checks) { if ($c.Ok) { Write-Ok "$($c.Name): $($c.Message)" } else { Write-Bad "$($c.Name): $($c.Message)" } }
            $permissionFailures = @($access.Checks | Where-Object { -not $_.Ok -and $_.Name -ne 'Agent heartbeat' })
            if ($permissionFailures.Count -gt 0) { Write-Bad 'NETWORK/SMB BLOCKED: permission probe failed' }
            elseif (@($access.Checks | Where-Object { $_.Name -eq 'Agent heartbeat' -and -not $_.Ok }).Count -gt 0) { Write-Bad 'SMB OK, AGENT OFFLINE' }
            $ok = $ok -and $access.Success
        } else { Write-Bad 'Remote CI share invalid'; $ok = $false }
        return $ok
    }

    $defaultProject = ''
    if ($Existing) { $old = Get-CiProject $Existing; if ($old) { $defaultProject = $old.projectPath } }
    $projectPath = if ($CheckOnly) { $defaultProject } else { Select-FolderDialog -Description 'Chon thu muc project Unity' -InitialPath $defaultProject }
    if (-not $projectPath -and -not $CheckOnly) { $projectPath = Read-Choice 'Hoac go duong dan project' $defaultProject }
    if (-not (Test-UnityProject $projectPath)) { Write-Bad 'Khong tim thay Unity project hop le.'; return $false }
    $projectPath = $projectPath.TrimEnd('\')
    $projectName = Split-Path -Leaf $projectPath
    $oldProject = if ($Existing) { Find-CiProjectByPath $Existing $projectPath } else { $null }
    if ($oldProject) { $projectName = $oldProject.name }

    $git = Get-GitInfo $projectPath
    if (-not $git) { Write-Bad 'Project phai la Git repository co commit.'; return $false }
    $remote = Get-GitRemoteUrl $projectPath
    if (-not $remote) { Write-Bad 'Repo chua co origin URL.'; return $false }
    $unityVersion = Get-ProjectUnityVersion $projectPath
    if (-not $unityVersion) { Write-Bad 'Khong doc duoc ProjectVersion.txt.'; return $false }
    Write-Ok "$projectName - Git $($git.Branch) / $($git.CommitCount) commits / Unity $unityVersion"

    $hostName = if ($CheckOnly -and $Existing -and $Existing.remoteAgents) { "$($Existing.remoteAgents[0].name)" } else { Read-Choice 'Hostname/IP may build' '' }
    if (-not $hostName) { Write-Bad 'Thieu hostname/IP may build.'; return $false }
    Write-Host '  Ket noi mac dinh: DEV va BUILD can o cung trusted LAN.' -ForegroundColor Gray
    Write-Host '  VPN: phai route toi build machine va firewall phai cho phep VPN subnet toi TCP 445.' -ForegroundColor Gray
    Write-Host '  Khong expose public IP voi SMB TCP 445 truc tiep ra Internet.' -ForegroundColor Gray
    $share = "\\$hostName\UnityCI"
    $pairPath = Join-CiPath $share 'pairing' 'pairing.json'
    $pair = Read-JsonFile $pairPath
    if (-not $pair) { Write-Bad "Khong doc duoc $pairPath"; return $false }
    if ($pair.expiresAt -and ([datetime]$pair.expiresAt) -lt (Get-Date)) { Write-Bad 'Pairing code da het han.'; return $false }
    Write-Info "Agent: $($pair.agentName)"
    $code = Read-Choice 'Pairing code' ''
    $normalized = ($code -replace '[^A-Za-z0-9]','').ToUpperInvariant()
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { $hash = ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($normalized))) -replace '-','').ToLowerInvariant() }
    finally { $sha.Dispose() }
    if ($hash -ne "$($pair.pairCodeHash)".ToLowerInvariant()) { Write-Bad 'Pairing code khong dung.'; return $false }
    Write-Ok "Pair thanh cong: $share"

    $access = Test-CiClientRemoteAccess $share
    foreach ($c in $access.Checks) { if ($c.Ok) { Write-Ok "$($c.Name): $($c.Message)" } else { Write-Bad "$($c.Name): $($c.Message)" } }
    if (-not $access.Success) { return $false }

    $editorDir = Join-CiPath $projectPath 'Assets\Editor\CI'
    if (-not (Test-Path $editorDir)) { New-Item -ItemType Directory -Force -Path $editorDir | Out-Null }
    foreach ($f in @('CIBuild.cs','CIBuildWindow.cs')) {
        $src = Join-Path $PSScriptRoot "..\unity\$f"
        if (Test-Path $src) { Copy-Item $src (Join-CiPath $editorDir $f) -Force }
    }
    $userSettings = Join-CiPath $projectPath 'UserSettings'
    if (-not (Test-Path $userSettings)) { New-Item -ItemType Directory -Force -Path $userSettings | Out-Null }
    Write-JsonFile (Join-CiPath $userSettings 'CIBuildLink.json') ([pscustomobject]@{ toolDir=(Get-ToolDir) })

    $entry = [pscustomobject]@{
        name=$projectName; projectPath=$projectPath; gitRemote=$remote; unityExe=''; unityVersion=$unityVersion
        worktreePath=''; buildsPath=''; drive=if($oldProject){$oldProject.drive}else{[pscustomobject]@{mode='none'}}
        android=if($oldProject){$oldProject.android}else{[pscustomobject]@{keystorePath='';keyaliasName=''}}
    }
    $projects = New-Object System.Collections.ArrayList
    if ($Existing) { foreach ($p in @($Existing.projects)) { if ($p.name -ne $projectName) { [void]$projects.Add($p) } } }
    [void]$projects.Add($entry)
    $agents = @()
    if ($Existing -and $Existing.remoteAgents) { $agents = @($Existing.remoteAgents | Where-Object { "$($_.name)" -ne "$($pair.agentName)" }) }
    $agents += [pscustomobject]@{ name=$pair.agentName; ciRoot=$share; canBuild=@($pair.platforms) }
    $cfg = [pscustomobject]@{
        version=3; role='client'; agentName=$env:COMPUTERNAME; canBuild=@('android'); pollSeconds=5; ciRoot=$share
        reserveCoresForEditor=0; buildTimeoutMinutes=0; useNographics=$false; discord=[pscustomobject]@{enabled=$false}
        defaultProject=$projectName; projects=$projects.ToArray(); remoteAgents=$agents
    }
    Write-CiConfig $cfg
    Remove-Item -LiteralPath $pairPath -Force -ErrorAction SilentlyContinue

    Write-Host ''
    Write-Host '  DEV MACHINE' -ForegroundColor Green
    Write-Host "    Project: $projectPath"
    Write-Host '    Extra CI storage: khong can'
    Write-Host '    Build local: tat'
    Write-Host ''
    Write-Host '  BUILD MACHINE' -ForegroundColor Green
    Write-Host "    CI storage: $share"
    Write-Host '    Source: clone tu Git'
    Write-Host '    Library/worktree: chi nam tren may build'
    Write-Host '    Artifact: doc qua trusted LAN; VPN can cau hinh firewall subnet rieng'
    Write-Host '    Storage khac: khong can them ~60-80 GB CI cache'
    Write-Host ''
    Write-Host '  SOURCE CODE: DEV --> Git remote --> BUILD' -ForegroundColor Gray
    Write-Host '  CONTROL / RESULT: DEV --> SMB TCP 445 --> BUILD' -ForegroundColor Gray
    Write-Host '  BUILD MACHINE: Git checkout/worktree + Unity Library cache + artifact; recommend >= 80 GB free.' -ForegroundColor Gray
    Write-Host '  Source Unity project khong duoc copy tu DEV sang BUILD qua SMB.' -ForegroundColor Gray
    Write-Host '  Khong share project dev, keystore/password hoac Discord secret qua SMB.' -ForegroundColor Gray
    return $true
}
