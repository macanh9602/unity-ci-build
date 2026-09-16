# Agent bootstrap helpers: SMB, firewall, Scheduled Task, pairing and readiness.

function Get-BestCiRoot {
    $candidates = @()
    foreach ($d in (Get-CimInstance Win32_LogicalDisk -Filter "DriveType=3" -ErrorAction SilentlyContinue)) {
        $free = [math]::Floor(([double]$d.FreeSpace / 1GB))
        if ($free -lt 80) { continue }
        $candidates += [pscustomobject]@{ Letter = "$($d.DeviceID)"; FreeGB = $free; System = ($d.DeviceID -eq $env:SystemDrive) }
    }
    $pick = $candidates | Sort-Object @{Expression='System';Descending=$false}, @{Expression='FreeGB';Descending=$true} | Select-Object -First 1
    if (-not $pick) {
        $pick = @(Get-CimInstance Win32_LogicalDisk -Filter "DriveType=3" -ErrorAction SilentlyContinue |
                  ForEach-Object { [pscustomobject]@{ Letter="$($_.DeviceID)"; FreeGB=[math]::Floor(([double]$_.FreeSpace / 1GB)); System=($_.DeviceID -eq $env:SystemDrive) } } |
                  Sort-Object FreeGB -Descending | Select-Object -First 1)
    }
    if (-not $pick) { return (Join-CiPath $env:SystemDrive '\UnityCI') }
    return (Join-CiPath $pick.Letter '\UnityCI')
}

function Ensure-CiSmbFirewall {
    try {
        $rules = @(Get-NetFirewallRule -DisplayGroup 'File and Printer Sharing' -ErrorAction Stop)
        if ($rules.Count -gt 0) {
            $rules | Where-Object Enabled -ne 'True' | Enable-NetFirewallRule -ErrorAction Stop | Out-Null
            return [pscustomobject]@{ Success=$true; Message='SMB firewall: enabled' }
        }
        return [pscustomobject]@{ Success=$false; Message='File and Printer Sharing firewall rules not found' }
    } catch { return [pscustomobject]@{ Success=$false; Message=$_.Exception.Message } }
}

function Ensure-CiRootAcl {
    param([string]$CiRoot)
    try {
        $dirs = @('queue','cancel','pairing','builds','results','logs','agents','worktree','processing')
        foreach ($d in $dirs) {
            $path = Join-CiPath $CiRoot $d
            if (-not (Test-Path -LiteralPath $path)) { New-Item -ItemType Directory -Force -Path $path | Out-Null }
        }
        $auth = 'Authenticated Users'
        $buildUser = "$env:USERDOMAIN\$env:USERNAME"
        # Remove the old broad grant if this machine was bootstrapped by an older version.
        & icacls.exe $CiRoot '/remove:g' $auth '/T' '/C' 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) { return [pscustomobject]@{ Success=$false; Message='icacls cleanup failed' } }
        foreach ($d in @('queue','cancel','pairing')) {
            & icacls.exe (Join-CiPath $CiRoot $d) '/grant' "${auth}:(OI)(CI)(M)" '/T' '/C' 2>&1 | Out-Null
            if ($LASTEXITCODE -ne 0) { return [pscustomobject]@{ Success=$false; Message="ACL failed: $d" } }
        }
        foreach ($d in @('builds','results','logs','agents')) {
            & icacls.exe (Join-CiPath $CiRoot $d) '/grant' "${auth}:(OI)(CI)(RX)" '/T' '/C' 2>&1 | Out-Null
            if ($LASTEXITCODE -ne 0) { return [pscustomobject]@{ Success=$false; Message="ACL failed: $d" } }
        }
        & icacls.exe (Join-CiPath $CiRoot 'processing') '/grant' "${auth}:(OI)(CI)(RX)" '/T' '/C' 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) { return [pscustomobject]@{ Success=$false; Message='ACL failed: processing client read' } }
        foreach ($d in @('worktree','processing')) {
            & icacls.exe (Join-CiPath $CiRoot $d) '/grant:r' "${buildUser}:(OI)(CI)(F)" 'SYSTEM:(OI)(CI)(F)' '/T' '/C' 2>&1 | Out-Null
            if ($LASTEXITCODE -ne 0) { return [pscustomobject]@{ Success=$false; Message="ACL failed: $d" } }
        }
        return [pscustomobject]@{ Success=$true; Message='CI root ACL ready (scoped)' }
    } catch { return [pscustomobject]@{ Success=$false; Message=$_.Exception.Message } }
}

function Ensure-CiSecureAcl {
    param([string]$SecurePath)
    try {
        if (-not (Test-Path -LiteralPath $SecurePath)) { New-Item -ItemType Directory -Force -Path $SecurePath | Out-Null }
        $auth = 'Authenticated Users'
        $buildUser = "$env:USERDOMAIN\$env:USERNAME"
        & icacls.exe $SecurePath '/inheritance:r' '/C' 2>&1 | Out-Null
        & icacls.exe $SecurePath '/remove:g' $auth '/T' '/C' 2>&1 | Out-Null
        & icacls.exe $SecurePath '/grant:r' "${buildUser}:(OI)(CI)(F)" 'SYSTEM:(OI)(CI)(F)' '/T' '/C' 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) { return [pscustomobject]@{ Success=$false; Message='secure ACL failed' } }
        return [pscustomobject]@{ Success=$true; Message='secure ACL ready' }
    } catch { return [pscustomobject]@{ Success=$false; Message=$_.Exception.Message } }
}

function Ensure-CiSmbShare {
    param([string]$CiRoot, [string]$ShareName = 'UnityCI')
    try {
        $share = Get-SmbShare -Name $ShareName -ErrorAction SilentlyContinue
        if ($share) {
            if ((Get-CiNormalizedPath $share.Path) -ne (Get-CiNormalizedPath $CiRoot)) {
                return [pscustomobject]@{ Success=$false; Conflict=$true; Message="Share '$ShareName' dang tro vao $($share.Path)" }
            }
            return [pscustomobject]@{ Success=$true; Conflict=$false; Message="SMB share reuse: \\$env:COMPUTERNAME\$ShareName" }
        }
        New-SmbShare -Name $ShareName -Path $CiRoot -ChangeAccess 'Authenticated Users' -ErrorAction Stop | Out-Null
        return [pscustomobject]@{ Success=$true; Conflict=$false; Message="SMB share ready: \\$env:COMPUTERNAME\$ShareName" }
    } catch { return [pscustomobject]@{ Success=$false; Conflict=$false; Message=$_.Exception.Message } }
}

function Ensure-CiAgentScheduledTask {
    param([string]$ToolDir)
    $taskName = 'UnityCIBuildAgent'
    $runner = Join-Path $ToolDir 'runner.ps1'
    try {
        $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument ('-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}" -Watch' -f $runner)
        $trigger = New-ScheduledTaskTrigger -AtLogOn -User "$env:USERDOMAIN\$env:USERNAME"
        $principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive -RunLevel Highest
        $task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
        if ($task) {
            Set-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Principal $principal -ErrorAction Stop | Out-Null
        } else {
            Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Principal $principal -Description 'Unity CI build agent' -ErrorAction Stop | Out-Null
        }
        return [pscustomobject]@{ Success=$true; Name=$taskName; Message='Scheduled Task ready' }
    } catch { return [pscustomobject]@{ Success=$false; Name=$taskName; Message=$_.Exception.Message } }
}

function New-CiPairingFile {
    param([string]$CiRoot, [string]$AgentName, [string[]]$Platforms = @('android'))
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try {
        $bytes = New-Object byte[] 8; $rng.GetBytes($bytes)
        $alphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789'
        $raw = -join ($bytes | ForEach-Object { $alphabet[($_ % $alphabet.Length)] })
    } finally { $rng.Dispose() }
    $code = $raw.Substring(0,4) + '-' + $raw.Substring(4,4)
    $now = Get-Date
    $normalized = ($code -replace '[^A-Za-z0-9]','').ToUpperInvariant()
    $hash = [System.Security.Cryptography.SHA256]::Create()
    try { $codeHash = ([BitConverter]::ToString($hash.ComputeHash([Text.Encoding]::UTF8.GetBytes($normalized))) -replace '-','').ToLowerInvariant() }
    finally { $hash.Dispose() }
    $pair = [pscustomobject]@{
        agentName=$AgentName; host=$env:COMPUTERNAME; share="\\$env:COMPUTERNAME\UnityCI"
        platforms=$Platforms; pairCodeHash=$codeHash; createdAt=$now.ToString('o'); expiresAt=$now.AddMinutes(20).ToString('o')
    }
    Write-JsonFile (Join-CiPath $CiRoot 'pairing' 'pairing.json') $pair
    # Return the plaintext only to the local bootstrap caller; never serialize it.
    Add-Member -InputObject $pair -NotePropertyName pairCode -NotePropertyValue $code -Force
    return $pair
}

function Write-CiAgentReady {
    param([string]$CiRoot, [string]$AgentName, [bool]$Ready, [string]$Message = '')
    Write-JsonFile (Join-CiPath $CiRoot 'agent-ready.json') ([pscustomobject]@{
        agentName=$AgentName; ready=$Ready; platforms=@('android'); runnerVersion='1';
        lastDoctor=(Get-Date).ToString('o'); share="\\$env:COMPUTERNAME\UnityCI"; message=$Message
    })
}

function Test-CiAgentDoctor {
    param([string]$CiRoot, [string]$ToolDir = '', [string]$AgentName = $env:COMPUTERNAME)
    $checks = New-Object System.Collections.ArrayList
    $add = { param($Name,$Ok,$Message) [void]$checks.Add([pscustomobject]@{Name=$Name;Ok=$Ok;Message=$Message}) }
    $git = Get-Command git.exe -ErrorAction SilentlyContinue
    & $add 'Git' ([bool]$git) $(if ($git) { $git.Source } else { 'missing' })
    $rootOk = (Test-Path $CiRoot) -and ((Get-Item $CiRoot -ErrorAction SilentlyContinue).PSIsContainer)
    & $add 'CI root' $rootOk $CiRoot
    $write = $false
    try { $probe=Join-CiPath $CiRoot '.doctor-write'; Set-Content -LiteralPath $probe -Value 'ok' -ErrorAction Stop; Remove-Item -LiteralPath $probe -Force -ErrorAction Stop; $write=$true } catch {}
    & $add 'CI root writable' $write 'queue/results/worktree root'
    $task = Get-ScheduledTask -TaskName 'UnityCIBuildAgent' -ErrorAction SilentlyContinue
    $taskOk = $false
    if ($task) {
        $runner = if ($ToolDir) { Join-Path $ToolDir 'runner.ps1' } else { '' }
        $action = @($task.Actions) | Select-Object -First 1
        $taskOk = $action -and $action.Execute -match '(?i)powershell([.]exe)?$' -and $action.Arguments -match '(?i)-Watch'
        if ($runner) { $taskOk = $taskOk -and ($action.Arguments -like "*$runner*") }
    }
    & $add 'Scheduled Task' $taskOk 'UnityCIBuildAgent action/path'
    $share = Get-SmbShare -Name 'UnityCI' -ErrorAction SilentlyContinue
    $shareOk = $share -and (Get-CiNormalizedPath $share.Path) -eq (Get-CiNormalizedPath $CiRoot)
    & $add 'SMB share' $shareOk "\\localhost\UnityCI -> $CiRoot"
    $agentConfig = $null
    try { $agentConfig = Read-CiConfig } catch {}
    $backend = Get-UnityProvisioningBackend
    $backendOk = $backend -and $backend.Name -ne 'none'
    & $add 'Unity provisioning backend' $backendOk $(if ($backendOk) { "$($backend.Name): $($backend.Path)" } else { 'missing' })
    if ($agentConfig) {
        foreach ($project in @($agentConfig.projects)) {
            if ($project.unityVersion) { & $add "Unity $($project.name)" $true (Format-UnityEditorResolution "$($project.unityVersion)") }
        }
    }
    if ($backendOk) {
        $auth = Get-UnityAuthStatus $backend
        & $add 'Unity authentication' $auth.Authenticated $auth.Message
        $license = Get-UnityLicenseStatus $backend
        & $add 'Unity license' $license.Ready $license.Message
    } else {
        & $add 'Unity authentication' $false 'AUTH REQUIRED - install Unity CLI or login/configure Unity Hub'
        & $add 'Unity license' $false 'UNITY LICENSE REQUIRED - Unity CLI license status unavailable'
    }
    $trustedPrefixes = if ($agentConfig -and (Test-CiHasProp $agentConfig 'allowedGitRemotePrefixes')) { @($agentConfig.allowedGitRemotePrefixes | Where-Object { "$_".Trim() }) } else { @() }
    & $add 'Unknown project trust' ($trustedPrefixes.Count -gt 0) $(if ($trustedPrefixes.Count -gt 0) { "$($trustedPrefixes.Count) trusted Git prefix(es)" } else { 'BLOCKED FOR UNKNOWN PROJECTS - configure allowedGitRemotePrefixes' })
    $heartbeat = @(Get-ChildItem -LiteralPath (Join-CiPath $CiRoot 'agents') -Filter '*.json' -ErrorAction SilentlyContinue |
                   Where-Object { $_.LastWriteTime -gt (Get-Date).AddSeconds(-20) } |
                   ForEach-Object { Read-JsonFile $_.FullName } |
                   Where-Object { $_ -and "$($_.name)" -eq $AgentName })
    & $add 'Agent heartbeat' ($heartbeat.Count -gt 0) 'last 20 seconds'
    $fail = @($checks | Where-Object { -not $_.Ok })
    return [pscustomobject]@{ Ready=($fail.Count -eq 0); Checks=$checks }
}
