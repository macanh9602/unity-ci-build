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
                & $exe copy $FilePath $dest --no-traverse @extra 2>&1 | Out-Null
                if ($LASTEXITCODE -ne 0) { $r.Message = "rclone copy loi (exit $LASTEXITCODE)"; return $r }
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
