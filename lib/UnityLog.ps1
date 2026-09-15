# ============================================================
#  UnityLog.ps1 - doc log Unity, tach LOI COMPILE va LOI BUILD
#  Hai loai nay hong khac nhau hoan toan nen phai bao khac nhau.
# ============================================================

$script:CompileRx = '^(?<file>.+?\.(cs|hlsl|shader|cginc))\((?<line>\d+),(?<col>\d+)\):\s*error\s+(?<code>[A-Za-z]+\d+):\s*(?<msg>.+)$'

$script:BuildFailMarkers = @(
    'BuildFailedException',
    'Error building Player',
    'Build completed with a result of ''Failed''',
    'UnityEditor.BuildPlayerWindow+BuildMethodException',
    'FAILURE: Build failed with an exception',
    'CommandInvokationFailure',
    'Gradle build failed',
    'UnityException:',
    'Unable to locate Android SDK',
    'Android SDK is missing',
    'NDK is missing',
    'no valid keystore',
    'Keystore file',
    'Failed to sign'
)

# ------------------------------------------------------------
#  Doc giai doan build tu log Unity.
#  Unity KHONG bao phan tram o batchmode, cung khong co API nao.
#  Thu duy nhat co that la cac dong log danh dau tung chang.
#  Bang nay co y tach rieng de de chinh khi gap log thuc te khac.
# ------------------------------------------------------------
$script:CiPhases = @(
    @{ Rank=1; Name='Khoi dong Unity';    Markers=@('Initialize engine version','Refreshing native plugins','Loading GUID') },
    @{ Rank=2; Name='Import asset';       Markers=@('Import Asset','AssetDatabase','Initial Refresh','Refresh completed') },
    @{ Rank=3; Name='Compile script';     Markers=@('Begin MonoManager','Starting compile','Finished compile','Compilation total') },
    @{ Rank=4; Name='Compile shader';     Markers=@('Compiling shader','Compiled shader','shader variants') },
    @{ Rank=5; Name='Build player';       Markers=@('Building Player','BuildPipeline.BuildPlayer','Tundra build','Start importing') },
    @{ Rank=6; Name='IL2CPP (bien ma)';   Markers=@('il2cpp','Building native binary') },
    @{ Rank=7; Name='Dong goi (gradle)';  Markers=@('> Task :','Building Gradle project','gradlew','Packaging') },
    @{ Rank=8; Name='Hoan tat';           Markers=@('Build completed with a result of','Total build time') }
)

function New-CiPhaseTracker {
    [pscustomobject]@{ Pos = [long]0; Rank = 0; Name = 'Chuan bi' }
}

# Chi doc phan MOI cua log moi lan goi, khong doc lai tu dau.
# Giai doan chi tien len, khong lui -> tranh nhay qua nhay lai khi
# cac dong log cua nhieu chang xen ke nhau.
function Update-CiPhaseTracker {
    param($Tracker, [string]$LogPath)
    if (-not $Tracker -or -not (Test-Path $LogPath)) { return $Tracker }
    $chunk = ''
    try {
        $fs = [System.IO.File]::Open($LogPath, 'Open', 'Read', 'ReadWrite')
        try {
            if ($fs.Length -lt $Tracker.Pos) { $Tracker.Pos = 0 }
            $len = $fs.Length - $Tracker.Pos
            if ($len -le 0) { return $Tracker }
            $cap = 4MB
            if ($len -gt $cap) { $Tracker.Pos = $fs.Length - $cap; $len = $cap }
            [void]$fs.Seek($Tracker.Pos, 'Begin')
            $buf  = New-Object byte[] ([int]$len)
            $read = $fs.Read($buf, 0, [int]$len)
            $chunk = [System.Text.Encoding]::UTF8.GetString($buf, 0, $read)
            $Tracker.Pos = $Tracker.Pos + $read
        } finally { $fs.Dispose() }
    } catch { return $Tracker }

    if (-not $chunk) { return $Tracker }
    foreach ($ph in $script:CiPhases) {
        if ($ph.Rank -le $Tracker.Rank) { continue }
        foreach ($m in $ph.Markers) {
            if ($chunk.IndexOf($m, [StringComparison]::OrdinalIgnoreCase) -ge 0) {
                $Tracker.Rank = $ph.Rank
                $Tracker.Name = $ph.Name
                break
            }
        }
    }
    return $Tracker
}

function Get-UnityCompileErrors {
    param([string]$LogPath, [int]$Max = 40)
    if (-not (Test-Path $LogPath)) { return @() }
    $seen = New-Object 'System.Collections.Generic.HashSet[string]'
    $out  = New-Object System.Collections.ArrayList
    foreach ($line in [System.IO.File]::ReadLines($LogPath)) {
        $m = [regex]::Match($line, $script:CompileRx)
        if (-not $m.Success) { continue }
        $file = $m.Groups['file'].Value
        # rut gon duong dan cho de doc: bo phan truoc Assets/
        $idx = $file.IndexOf('Assets', [StringComparison]::OrdinalIgnoreCase)
        if ($idx -ge 0) { $file = $file.Substring($idx) }
        $key = '{0}|{1}|{2}' -f $file, $m.Groups['line'].Value, $m.Groups['code'].Value
        if (-not $seen.Add($key)) { continue }
        [void]$out.Add([pscustomobject]@{
            File = $file.Replace('\','/')
            Line = [int]$m.Groups['line'].Value
            Col  = [int]$m.Groups['col'].Value
            Code = $m.Groups['code'].Value
            Msg  = $m.Groups['msg'].Value.Trim()
        })
        if ($out.Count -ge $Max) { break }
    }
    return $out.ToArray()
}

function Get-UnityBuildFailure {
    param([string]$LogPath, [int]$Context = 25)
    if (-not (Test-Path $LogPath)) { return @() }
    $lines = [System.IO.File]::ReadAllLines($LogPath)
    for ($i = 0; $i -lt $lines.Length; $i++) {
        foreach ($mk in $script:BuildFailMarkers) {
            if ($lines[$i].IndexOf($mk, [StringComparison]::OrdinalIgnoreCase) -ge 0) {
                $from = [Math]::Max(0, $i - 3)
                $to   = [Math]::Min($lines.Length - 1, $i + $Context)
                return $lines[$from..$to]
            }
        }
    }
    # khong thay marker -> tra ve duoi log, thuong co nguyen nhan
    $from = [Math]::Max(0, $lines.Length - 40)
    return $lines[$from..($lines.Length - 1)]
}

function Write-CiErrorReport {
    param(
        [string]$LogPath,
        [string]$OutPath,
        $Job,
        [string]$Reason = ''
    )
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine('==============================================================')
    [void]$sb.AppendLine(" BUILD THAT BAI - $($Job.id)")
    [void]$sb.AppendLine('==============================================================')
    [void]$sb.AppendLine(" Branch  : $($Job.branch)")
    [void]$sb.AppendLine(" Commit  : $($Job.shaShort)  $($Job.subject)")
    [void]$sb.AppendLine(" Loai    : $($Job.format.ToUpper()) / $($Job.config)")
    [void]$sb.AppendLine(" Log day : $LogPath")
    if ($Reason) { [void]$sb.AppendLine(" Ghi chu : $Reason") }
    [void]$sb.AppendLine('')

    if (-not (Test-Path $LogPath)) {
        [void]$sb.AppendLine('--------------------------------------------------------------')
        [void]$sb.AppendLine(' UNITY CHUA TUNG CHAY')
        [void]$sb.AppendLine('--------------------------------------------------------------')
        [void]$sb.AppendLine(' Khong co file log nao duoc sinh ra, nghia la build chet TRUOC khi')
        [void]$sb.AppendLine(' Unity kip khoi dong. Nguyen nhan nam o dong "Ghi chu" phia tren.')
        [void]$sb.AppendLine('')
        [void]$sb.AppendLine(' Thuong la mot trong may cai nay:')
        [void]$sb.AppendLine('   - Duong dan trong config.json khong phai duong dan tuyet doi')
        [void]$sb.AppendLine('     (go "E" thay vi "E:\UnityCI") -> chay lai install.bat')
        [void]$sb.AppendLine('   - Chua tao duoc worktree -> chay lai install.bat')
        [void]$sb.AppendLine('   - Sai duong dan Unity.exe -> chay .\ci.ps1 doctor')
        [void]$sb.AppendLine('   - git checkout that bai -> xem runner.log')
        [void]$sb.AppendLine('')
        Set-Utf8NoBom -Path $OutPath -Text $sb.ToString()
        return @{ CompileErrorCount = 0; CompileErrors = @() }
    }

    $compile = Get-UnityCompileErrors -LogPath $LogPath
    if ($compile.Count -gt 0) {
        [void]$sb.AppendLine('--------------------------------------------------------------')
        [void]$sb.AppendLine(" LOI COMPILE ($($compile.Count))  <- code khong build duoc")
        [void]$sb.AppendLine('--------------------------------------------------------------')
        foreach ($e in $compile) {
            [void]$sb.AppendLine((' {0}({1},{2})' -f $e.File, $e.Line, $e.Col))
            [void]$sb.AppendLine(('     {0}: {1}' -f $e.Code, $e.Msg))
        }
        [void]$sb.AppendLine('')
    } else {
        [void]$sb.AppendLine('--------------------------------------------------------------')
        [void]$sb.AppendLine(' KHONG CO LOI COMPILE - hong o khau dong goi player')
        [void]$sb.AppendLine('--------------------------------------------------------------')
        foreach ($l in (Get-UnityBuildFailure -LogPath $LogPath)) { [void]$sb.AppendLine(" $l") }
        [void]$sb.AppendLine('')
    }

    Set-Utf8NoBom -Path $OutPath -Text $sb.ToString()
    return @{
        CompileErrorCount = $compile.Count
        CompileErrors     = $compile
    }
}

function Get-CiErrorSummary {
    param($ErrorInfo, [int]$MaxChars = 1400)
    if (-not $ErrorInfo -or $ErrorInfo.CompileErrorCount -eq 0) { return '' }
    $sb = New-Object System.Text.StringBuilder
    foreach ($e in $ErrorInfo.CompileErrors) {
        $line = '{0}({1}) {2}: {3}' -f $e.File, $e.Line, $e.Code, $e.Msg
        if (($sb.Length + $line.Length + 1) -gt $MaxChars) { [void]$sb.AppendLine('... (con nua, xem file errors.txt)'); break }
        [void]$sb.AppendLine($line)
    }
    return $sb.ToString()
}
