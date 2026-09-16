# ============================================================
#  Drive.ps1 - dua file build den cho tester tai
#  Ba che do:
#    none   - khong lam gi, file chi nam local
#    folder - copy vao mot folder khac (Google Drive Desktop / MEGA /
#             OneDrive / o mang). Khong can OAuth, chi can 1 duong dan.
#    rclone - upload thang qua rclone, tu sinh link chia se tung file.
# ============================================================

function Find-Rclone {
    param([string]$Preferred = '')
    if ($Preferred -and (Test-Path $Preferred)) { return $Preferred }
    $cmd = Get-Command rclone.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    foreach ($p in @(
        "$env:LOCALAPPDATA\Microsoft\WinGet\Links\rclone.exe",
        "$env:ProgramFiles\rclone\rclone.exe",
        "C:\rclone\rclone.exe"
    )) { if (Test-Path $p) { return $p } }
    return $null
}

function Get-RcloneRemotes {
    param([string]$RclonePath)
    $exe = Find-Rclone $RclonePath
    if (-not $exe) { return @() }
    $old = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try {
        $out = & $exe listremotes 2>$null
        if ($LASTEXITCODE -ne 0) { return @() }
        return @($out | Where-Object { $_ } | ForEach-Object { "$_".Trim() })
    } catch { return @() } finally { $ErrorActionPreference = $old }
}

# Lay folder ID tu link Google Drive.
# Link co dang https://drive.google.com/drive/u/0/folders/<ID>?usp=...
function Get-DriveFolderId {
    param([string]$Url)
    if (-not $Url) { return '' }
    $m = [regex]::Match($Url, 'folders/([A-Za-z0-9_\-]{10,})')
    if ($m.Success) { return $m.Groups[1].Value }
    # nguoi dung co the dan thang ID
    if ($Url -match '^[A-Za-z0-9_\-]{20,}$') { return $Url }
    return ''
}

# Tao ket noi Google Drive bang MOT lenh.
# 'rclone config create' tu lay gia tri mac dinh cho moi cau hoi cau hinh,
# nen ca cuoc phong van ~10 buoc cua 'rclone config' rut lai con
# dung mot buoc: bam Allow tren trinh duyet.
function New-RcloneDriveRemote {
    param([string]$RclonePath = '', [string]$Name = 'gdrive')
    $exe = Find-Rclone $RclonePath
    if (-not $exe) { return $false }
    $old = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try {
        & $exe config create $Name drive scope=drive
        return ($LASTEXITCODE -eq 0)
    } catch { return $false } finally { $ErrorActionPreference = $old }
}

# Doan duong dan folder dong bo cua cac dich vu pho bien, de wizard goi y san
function Find-SyncFolders {
    $found = New-Object System.Collections.ArrayList
    $home_ = $env:USERPROFILE
    $cands = New-Object System.Collections.ArrayList
    if ($env:OneDrive) { [void]$cands.Add(@{ Name = 'OneDrive'; Path = $env:OneDrive }) }
    if ($home_) {
        foreach ($pair in @(
            @('Google Drive', 'My Drive'),
            @('Google Drive', 'Google Drive'),
            @('OneDrive',     'OneDrive'),
            @('Dropbox',      'Dropbox'),
            @('MEGA',         'Documents\MEGA')
        )) { [void]$cands.Add(@{ Name = $pair[0]; Path = (Join-Path $home_ $pair[1]) }) }
    }
    foreach ($c in $cands) {
        if ($c.Path -and (Test-Path $c.Path)) {
            if (-not ($found | Where-Object { $_.Path -eq $c.Path })) {
                [void]$found.Add([pscustomobject]@{ Name = $c.Name; Path = $c.Path })
            }
        }
    }
    # Google Drive Desktop hay mount thanh o dia rieng (G:, H:...)
    try {
        foreach ($d in (Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3 OR DriveType=4' -ErrorAction Stop)) {
            if ($d.VolumeName -and $d.VolumeName -match 'Google Drive') {
                [void]$found.Add([pscustomobject]@{ Name = 'Google Drive (o dia)'; Path = ($d.DeviceID + '\') })
            }
        }
    } catch {}
    return $found.ToArray()
}

# Thu dich den TRUOC khi build, thay vi de phat hien sau 20 phut.
function Test-CiPublishTarget {
    param($Config)
    $r = [pscustomobject]@{ Ok = $true; Mode = 'none'; Detail = ''; Message = '' }
    if (-not $Config.drive) { return $r }
    $mode = "$($Config.drive.mode)"
    if (-not $mode -or $mode -eq 'none') { return $r }
    $r.Mode = $mode

    if ($mode -eq 'folder') {
        $dst = "$($Config.drive.folderPath)"
        $r.Detail = $dst
        if (-not $dst) { $r.Ok = $false; $r.Message = 'Chua cau hinh folderPath'; return $r }
        try {
            if (-not (Test-Path $dst)) { New-Item -ItemType Directory -Force -Path $dst -ErrorAction Stop | Out-Null }
            $probe = Join-CiPath $dst ('.ci-write-test-' + [guid]::NewGuid().ToString('N').Substring(0,6))
            Set-Utf8NoBom -Path $probe -Text 'x'
            Remove-Item -LiteralPath $probe -Force -ErrorAction SilentlyContinue
        } catch { $r.Ok = $false; $r.Message = $_.Exception.Message }
        return $r
    }

    if ($mode -eq 'rclone') {
        $exe = Find-Rclone $Config.drive.rclonePath
        if (-not $exe) { $r.Ok = $false; $r.Message = 'Khong tim thay rclone'; return $r }
        $remote = "$($Config.drive.remote)"
        if ($remote -and -not $remote.EndsWith(':')) { $remote += ':' }
        $folder = "$($Config.drive.folder)"
        $dest   = if ($folder) { "$remote$folder" } else { $remote }
        $r.Detail = $dest

        $extra = @()
        $rid = "$($Config.drive.rootFolderId)"
        if ($rid) { $extra += @('--drive-root-folder-id', $rid); $r.Detail += "  (folder ID $rid)" }

        $old = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
        try {
            $out = & $exe lsd $dest @extra 2>&1
            if ($LASTEXITCODE -ne 0) {
                $r.Ok = $false
                $raw = (($out | ForEach-Object { "$_" }) -join ' ').Trim()
                $raw = $raw -replace '\d{4}/\d{2}/\d{2} \d{2}:\d{2}:\d{2} ', ''
                if (-not $raw) { $raw = "rclone lsd exit $LASTEXITCODE" }
                $hint = Get-CiRcloneHint $raw
                $r.Message = if ($hint) { $raw + "  ->  " + $hint } else { $raw }
            }
        } catch { $r.Ok = $false; $r.Message = $_.Exception.Message }
        finally { $ErrorActionPreference = $old }
        return $r
    }

    $r.Ok = $false; $r.Message = "Che do khong hop le: $mode"
    return $r
}

# rclone bao loi bang tieng Anh kem chi tiet; doi chieu sang viec can lam
# Liet ke remote KEM LOAI. Quan trong: --drive-root-folder-id chi co tac dung
# voi remote loai 'drive'. Remote loai khac thi co ma bi BO QUA IM LANG,
# file se di lac cho ma khong bao gi.
function Get-RcloneRemoteList {
    param([string]$RclonePath)
    $exe = Find-Rclone $RclonePath
    if (-not $exe) { return @() }
    $old = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    $out = New-Object System.Collections.ArrayList
    try {
        $lines = & $exe listremotes --long 2>$null
        if ($LASTEXITCODE -eq 0 -and $lines) {
            foreach ($l in $lines) {
                $t = ("$l").Trim()
                if (-not $t) { continue }
                $parts = $t -split '\s+', 2
                $name = $parts[0].TrimEnd(':')
                $type = if ($parts.Count -gt 1) { $parts[1].Trim() } else { '' }
                [void]$out.Add([pscustomobject]@{ Name = $name; Type = $type })
            }
            return $out.ToArray()
        }
        # rclone doi cu khong co --long -> hoi tung remote mot
        $names = & $exe listremotes 2>$null
        foreach ($n in $names) {
            $name = ("$n").Trim().TrimEnd(':')
            if (-not $name) { continue }
            $type = ''
            $cfg = & $exe config show $name 2>$null
            foreach ($c in $cfg) { if ("$c" -match '^\s*type\s*=\s*(\S+)') { $type = $Matches[1]; break } }
            [void]$out.Add([pscustomobject]@{ Name = $name; Type = $type })
        }
        return $out.ToArray()
    } catch { return @() } finally { $ErrorActionPreference = $old }
}

function Get-RcloneRemoteType {
    param([string]$RclonePath, [string]$Remote)
    $n = ("$Remote").TrimEnd(':')
    $r = @(Get-RcloneRemoteList $RclonePath) | Where-Object { $_.Name -eq $n } | Select-Object -First 1
    if ($r) { return $r.Type }
    return ''
}

function Get-CiRcloneHint {
    param([string]$Message)
    if (-not $Message) { return '' }
    $m = $Message.ToLower()
    if ($m -match "didn't find section|couldn't find remote|unknown remote") {
        return "Khong co remote do trong rclone. Chay: rclone listremotes"
    }
    if ($m -match 'directory not found|404|not found') {
        return "Khong vao duoc folder. Neu no nam trong 'Shared with me' thi phai tao shortcut vao My Drive truoc (chuot phai folder > Organise > Add shortcut to Drive)."
    }
    if ($m -match '403|permission|forbidden|insufficient') {
        return 'Khong co quyen ghi vao folder do. Xin quyen Editor tu chu folder.'
    }
    if ($m -match 'quota|storage.*full|limit') {
        return 'Drive het dung luong hoac cham gioi han upload trong ngay.'
    }
    if ($m -match 'token|oauth|unauthenticated|401') {
        return 'Token het han. Chay lai: rclone config reconnect <ten-remote>:'
    }
    return ''
}

function Publish-CiArtifact {
    param($Config, [string]$FilePath)

    $r = [pscustomobject]@{ Published = $false; Link = ''; Target = ''; Message = '' }
    if (-not $Config.drive) { return $r }

    $mode = "$($Config.drive.mode)"
    if (-not $mode -or $mode -eq 'none') { return $r }
    if (-not (Test-Path $FilePath)) { $r.Message = 'Khong tim thay file de dua di'; return $r }

    switch ($mode) {

        'folder' {
            $dst = "$($Config.drive.folderPath)"
            if (-not $dst) { $r.Message = 'Chua cau hinh folderPath'; return $r }
            try {
                if (-not (Test-Path $dst)) { New-Item -ItemType Directory -Force -Path $dst | Out-Null }
                Copy-Item -LiteralPath $FilePath -Destination $dst -Force
                $r.Published = $true
                $r.Target    = $dst
                # Link chia se la link TINH do nguoi dung dan vao mot lan luc cai,
                # khong phai link rieng cua tung file - khong can OAuth.
                $r.Link      = "$($Config.drive.shareUrl)"
            } catch { $r.Message = $_.Exception.Message }
        }

        'rclone' {
            $exe = Find-Rclone $Config.drive.rclonePath
            if (-not $exe) { $r.Message = 'Khong tim thay rclone'; return $r }
            $remote = "$($Config.drive.remote)"
            if ($remote -and -not $remote.EndsWith(':')) { $remote += ':' }
            $folder = "$($Config.drive.folder)"
            $dest   = if ($folder) { "$remote$folder" } else { $remote }
            # Ghim vao dung mot folder bang ID lay tu link, thay vi di theo ten thu muc.
            # Dat o luc goi lenh chu khong nhung vao remote -> doi folder dich sau nay
            # chi can sua config.json, khong phai dang nhap Google lai.
            $extra = @()
            $rid = "$($Config.drive.rootFolderId)"
            if ($rid) { $extra += @('--drive-root-folder-id', $rid) }

            $old = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
            try {
                # GIU output cua rclone lai. Truoc day doan nay day thang vao
                # Out-Null roi chi bao exit code - tuc la vut dung cai thong bao
                # loi di roi phan nan la khong biet vi sao hong.
                $out = & $exe copy $FilePath $dest --no-traverse @extra 2>&1
                if ($LASTEXITCODE -ne 0) {
                    $raw = (($out | ForEach-Object { "$_" }) -join ' ').Trim()
                    # bo phan tien to thoi gian cua rclone cho de doc
                    $raw = $raw -replace '\d{4}/\d{2}/\d{2} \d{2}:\d{2}:\d{2} ', ''
                    if ($raw.Length -gt 600) { $raw = $raw.Substring(0, 600) + '...' }
                    if (-not $raw) { $raw = "rclone copy exit $LASTEXITCODE" }
                    $hint = Get-CiRcloneHint $raw
                    $r.Message = if ($hint) { $raw + "  ->  " + $hint } else { $raw }
                    return $r
                }
                $r.Published = $true
                $r.Target    = $dest
                if ($Config.drive.makeLink) {
                    $leaf = Split-Path -Leaf $FilePath
                    $target = if ($dest.EndsWith(':')) { $dest + $leaf } else { $dest + '/' + $leaf }
                    $link = & $exe link $target @extra 2>$null
                    if ($LASTEXITCODE -eq 0 -and $link) { $r.Link = (("$link" -join '')).Trim() }
                }
            } catch { $r.Message = $_.Exception.Message }
            finally { $ErrorActionPreference = $old }
        }

        default { $r.Message = "Che do khong hop le: $mode" }
    }
    return $r
}
