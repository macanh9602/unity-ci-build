# ============================================================
#  Unity.ps1 - do tim Unity Hub / Editor / module Android
#  Tach rieng vi CA setup.ps1 LAN runner.ps1 deu can:
#  runner tu nhan project la thi phai tu tim ban Unity khop.
# ============================================================

$env:UNITY_NO_CONSENT_PROMPT = '1'

function Find-UnityHub {
    foreach ($p in @(
        (Join-Path $env:ProgramFiles 'Unity Hub\Unity Hub.exe'),
        (Join-Path ${env:ProgramFiles(x86)} 'Unity Hub\Unity Hub.exe')
    )) { if ($p -and (Test-Path $p)) { return $p } }
    return $null
}

function Find-UnityCli {
    $command = Get-Command unity -ErrorAction SilentlyContinue
    if ($command) { return [pscustomobject]@{ Available=$true; Path=$command.Source; Version='' } }
    foreach ($name in @('unity-cli.exe','UnityCli.exe','unity-cli')) {
        $c = Get-Command $name -ErrorAction SilentlyContinue
        if ($c) { return [pscustomobject]@{ Available=$true; Path=$c.Source; Version='' } }
    }
    foreach ($p in @(
        (Join-Path $env:ProgramFiles 'Unity Hub\UnityCli.exe'),
        (Join-Path $env:ProgramFiles 'Unity Hub\Unity CLI.exe')
    )) {
        if ($p -and (Test-Path $p)) { return [pscustomobject]@{ Available=$true; Path=$p; Version='' } }
    }
    return [pscustomobject]@{ Available=$false; Path=''; Version='' }
}

function Invoke-UnityProvisionCommand {
    param([string]$FilePath, [string[]]$Arguments, [int]$TimeoutMinutes = 120)
    $outFile = Join-Path $env:TEMP ("unity-ci-provision-{0}.out" -f ([guid]::NewGuid().ToString('N')))
    $errFile = Join-Path $env:TEMP ("unity-ci-provision-{0}.err" -f ([guid]::NewGuid().ToString('N')))
    try {
        $argText = ($Arguments | ForEach-Object { if ("$_" -match '[\s"]') { '"' + ("$_" -replace '"','\\"') + '"' } else { "$_" } }) -join ' '
        $p = Start-Process -FilePath $FilePath -ArgumentList $argText -PassThru -WindowStyle Hidden `
             -RedirectStandardOutput $outFile -RedirectStandardError $errFile
        if (-not $p.WaitForExit($TimeoutMinutes * 60 * 1000)) {
            try { $p.Kill() } catch {}
            return [pscustomobject]@{ ExitCode=-1; TimedOut=$true; Output='Provisioning timeout' }
        }
        $out = ''
        if (Test-Path $outFile) { $out += Get-Content $outFile -Raw -ErrorAction SilentlyContinue }
        if (Test-Path $errFile) { $out += "`n" + (Get-Content $errFile -Raw -ErrorAction SilentlyContinue) }
        return [pscustomobject]@{ ExitCode=$p.ExitCode; TimedOut=$false; Output=$out.Trim() }
    } catch {
        return [pscustomobject]@{ ExitCode=-2; TimedOut=$false; Output=$_.Exception.Message }
    } finally {
        Remove-Item -LiteralPath $outFile,$errFile -Force -ErrorAction SilentlyContinue
    }
}

function Get-UnityAuthStatus {
    param($Backend)
    if (-not $Backend -or $Backend.Name -eq 'none') {
        return [pscustomobject]@{ Known=$false; Authenticated=$false; ExitCode=-1; Output=''; Message='AUTH REQUIRED - no provisioning backend' }
    }
    if ($Backend.Name -eq 'unity-cli') {
        $r = Invoke-UnityProvisionCommand -FilePath $Backend.Path -Arguments @('auth','status') -TimeoutMinutes 1
        if ($r.ExitCode -eq 0 -and $r.Output -match '(?i)logged[ -]?in|authenticated|signed[ -]?in') {
            return [pscustomobject]@{ Known=$true; Authenticated=$true; ExitCode=$r.ExitCode; Output=$r.Output; Message='Unity authentication OK' }
        }
        return [pscustomobject]@{ Known=$true; Authenticated=$false; ExitCode=$r.ExitCode; Output=$r.Output; Message='AUTH REQUIRED - run Unity CLI/Hub login once' }
    }
    return [pscustomobject]@{ Known=$false; Authenticated=$false; ExitCode=-1; Output=''; Message='AUTH REQUIRED - login in Unity Hub before first provision' }
}

function Get-UnityLicenseStatus {
    param($Backend)
    if (-not $Backend -or $Backend.Name -ne 'unity-cli') {
        return [pscustomobject]@{ Known=$false; Ready=$false; ExitCode=-1; Output=''; Message='UNITY LICENSE REQUIRED - Unity CLI license status unavailable' }
    }
    $r = Invoke-UnityProvisionCommand -FilePath $Backend.Path -Arguments @('license','status') -TimeoutMinutes 1
    $notReady = $r.Output -match '(?i)no active license|not activated|license required|no license|unlicensed|inactive'
    if ($r.ExitCode -eq 0 -and -not $notReady) {
        return [pscustomobject]@{ Known=$true; Ready=$true; ExitCode=$r.ExitCode; Output=$r.Output; Message='Unity license OK' }
    }
    return [pscustomobject]@{ Known=$true; Ready=$false; ExitCode=$r.ExitCode; Output=$r.Output; Message='UNITY LICENSE REQUIRED' }
}

function Invoke-UnityAuthLogin {
    param($Backend)
    if (-not $Backend -or $Backend.Name -ne 'unity-cli') {
        return [pscustomobject]@{ ExitCode=-1; TimedOut=$false; Output='AUTH REQUIRED - Unity CLI backend unavailable' }
    }
    return (Invoke-UnityProvisionCommand -FilePath $Backend.Path -Arguments @('auth','login') -TimeoutMinutes 30)
}

function Get-UnityProvisioningBackend {
    $cli = Find-UnityCli
    if ($cli.Available) { return [pscustomobject]@{ Name='unity-cli'; Path=$cli.Path } }
    $hub = Find-UnityHub
    if ($hub) { return [pscustomobject]@{ Name='unity-hub'; Path=$hub } }
    return [pscustomobject]@{ Name='none'; Path='' }
}

function Get-UnityEditors {
    $roots = New-Object System.Collections.ArrayList
    [void]$roots.Add((Join-Path $env:ProgramFiles 'Unity\Hub\Editor'))
    $sec = Join-Path $env:APPDATA 'UnityHub\secondaryInstallPath.json'
    if (Test-Path $sec) {
        $p = (Get-Content $sec -Raw -ErrorAction SilentlyContinue)
        if ($p) { $p = $p.Trim().Trim('"'); if ($p) { [void]$roots.Add($p) } }
    }
    $found = New-Object System.Collections.ArrayList
    foreach ($r in $roots) {
        if (-not (Test-Path $r)) { continue }
        foreach ($d in (Get-ChildItem -Path $r -Directory -ErrorAction SilentlyContinue)) {
            $exe = Join-Path $d.FullName 'Editor\Unity.exe'
            if (Test-Path $exe) {
                [void]$found.Add([pscustomobject]@{
                    Version = $d.Name
                    Exe     = $exe
                    Root    = $d.FullName
                })
            }
        }
    }
    return $found.ToArray()
}

function Get-AndroidModuleState([string]$EditorRoot) {
    $ap = Join-Path $EditorRoot 'Editor\Data\PlaybackEngines\AndroidPlayer'
    [pscustomobject]@{
        Installed = Test-Path $ap
        Jdk       = Test-Path (Join-Path $ap 'OpenJDK')
        Sdk       = Test-Path (Join-Path $ap 'SDK')
        Ndk       = Test-Path (Join-Path $ap 'NDK')
    }
}

function Get-ProjectUnityVersion([string]$ProjectPath) {
    $f = Join-Path $ProjectPath 'ProjectSettings\ProjectVersion.txt'
    if (-not (Test-Path $f)) { return $null }
    $t = Get-Content $f -Raw
    if ($t -match 'm_EditorVersion:\s*(\S+)') { return $Matches[1] }
    return $null
}

function Test-UnityProject([string]$P) {
    if (-not $P -or -not (Test-Path $P)) { return $false }
    (Test-Path (Join-Path $P 'Assets')) -and (Test-Path (Join-Path $P 'ProjectSettings'))
}

# Tim duong dan Unity.exe khop voi mot phien ban cu the
function Resolve-UnityExe {
    param([string]$Version)
    if (-not $Version) { return '' }
    $e = @(Get-UnityEditors) | Where-Object { $_.Version -eq $Version } | Select-Object -First 1
    if ($e) { return $e.Exe }
    return ''
}

function Ensure-UnityEditor {
    param([string]$Version, [bool]$NeedAndroid = $true, [bool]$AutoInstall = $true, [int]$TimeoutMinutes = 120)
    $existing = @(Get-UnityEditors) | Where-Object { $_.Version -eq $Version } | Select-Object -First 1
    if ($existing) {
        $modules = Get-AndroidModuleState $existing.Root
        if (-not $NeedAndroid -or ($modules.Installed -and $modules.Sdk -and $modules.Ndk -and $modules.Jdk)) {
            return [pscustomobject]@{ Success=$true; Stage='hit'; Exe=$existing.Exe; Reason='' }
        }
    }
    if (-not $AutoInstall) { return [pscustomobject]@{ Success=$false; Stage='blocked'; Exe=''; Reason="Unity $Version chua san sang va autoProvisionUnity dang tat" } }
    $backend = Get-UnityProvisioningBackend
    if ($backend.Name -eq 'none') { return [pscustomobject]@{ Success=$false; Stage='blocked'; Exe=''; Reason='Khong tim thay Unity CLI/Hub' } }
    $mutexName = "Global\UnityCiProvision_$Version"
    $created = $false
    $mutex = New-Object System.Threading.Mutex($false, $mutexName, [ref]$created)
    try {
        $mutex.WaitOne() | Out-Null
        $existing = @(Get-UnityEditors) | Where-Object { $_.Version -eq $Version } | Select-Object -First 1
        if (-not $existing) {
            if ($backend.Name -eq 'unity-cli') {
                $args = @('install',$Version,'-m','android','--cm','--non-interactive','--yes','--accept-eula')
                $p = Invoke-UnityProvisionCommand -FilePath $backend.Path -Arguments $args -TimeoutMinutes $TimeoutMinutes
            } else {
                $args = @('--','--headless','install','--version',$Version,'--module','android','--module','android-sdk-ndk-tools','--module','android-open-jdk')
                $p = Invoke-UnityProvisionCommand -FilePath $backend.Path -Arguments $args -TimeoutMinutes $TimeoutMinutes
            }
            if ($p.TimedOut) { return [pscustomobject]@{ Success=$false; Stage='provisioning'; Exe=''; Reason=$p.Output } }
            if ($p.ExitCode -ne 0) { return [pscustomobject]@{ Success=$false; Stage='provisioning'; Exe=''; Reason="Backend $($backend.Name) exit $($p.ExitCode): $($p.Output)" } }
        } elseif ($existing) {
            $args = @('--','--headless','install-modules','--version',$Version,'--module','android','--module','android-sdk-ndk-tools','--module','android-open-jdk')
            if ($backend.Name -eq 'unity-cli') { $args = @('install-modules','-e',$Version,'-m','android','--cm','--non-interactive','--yes','--accept-eula') }
            $p = Invoke-UnityProvisionCommand -FilePath $backend.Path -Arguments $args -TimeoutMinutes $TimeoutMinutes
            if ($p.TimedOut) { return [pscustomobject]@{ Success=$false; Stage='provisioning'; Exe=''; Reason=$p.Output } }
            if ($p.ExitCode -ne 0) { return [pscustomobject]@{ Success=$false; Stage='provisioning'; Exe=''; Reason="Backend $($backend.Name) exit $($p.ExitCode): $($p.Output)" } }
        }
    } catch { return [pscustomobject]@{ Success=$false; Stage='provisioning'; Exe=''; Reason=$_.Exception.Message } }
    finally { try { $mutex.ReleaseMutex() } catch {}; $mutex.Dispose() }
    $existing = @(Get-UnityEditors) | Where-Object { $_.Version -eq $Version } | Select-Object -First 1
    if (-not $existing) { return [pscustomobject]@{ Success=$false; Stage='provisioning'; Exe=''; Reason="Khong tim thay Unity $Version sau provisioning" } }
    $modules = Get-AndroidModuleState $existing.Root
    if ($NeedAndroid -and (-not ($modules.Installed -and $modules.Sdk -and $modules.Ndk -and $modules.Jdk))) {
        return [pscustomobject]@{ Success=$false; Stage='provisioning'; Exe=''; Reason='Android Build Support/SDK/NDK/OpenJDK chua day du' }
    }
    return [pscustomobject]@{ Success=$true; Stage='installed'; Exe=$existing.Exe; Reason='' }
}
