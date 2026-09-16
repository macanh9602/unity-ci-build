# ============================================================
#  Discord.ps1 - bao ket qua build qua webhook
#  Webhook = chi can 1 URL, khong can bot, khong can daemon.
# ============================================================

function Send-DiscordRaw {
    param([string]$WebhookUrl, $Payload, [switch]$ReturnId)
    if ([string]::IsNullOrWhiteSpace($WebhookUrl)) { return $(if ($ReturnId) { '' } else { $false }) }
    try {
        $json  = $Payload | ConvertTo-Json -Depth 12 -Compress
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
        # wait=true buoc Discord tra ve object tin nhan -> co id de sua lai sau
        $uri = if ($ReturnId) { $WebhookUrl + $(if ($WebhookUrl.Contains('?')) { '&' } else { '?' }) + 'wait=true' } else { $WebhookUrl }
        $res = Invoke-RestMethod -Uri $uri -Method Post `
            -ContentType 'application/json; charset=utf-8' -Body $bytes
        if ($ReturnId) { return "$($res.id)" }
        return $true
    } catch {
        return $(if ($ReturnId) { '' } else { $false })
    }
}

# Sua lai chinh tin nhan da gui, thay vi gui tin moi -> kenh khong bi spam
function Edit-DiscordMessage {
    param([string]$WebhookUrl, [string]$MessageId, $Payload)
    if ([string]::IsNullOrWhiteSpace($WebhookUrl) -or [string]::IsNullOrWhiteSpace($MessageId)) { return $false }
    try {
        $json  = $Payload | ConvertTo-Json -Depth 12 -Compress
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
        $uri   = $WebhookUrl.Split('?')[0] + '/messages/' + $MessageId
        Invoke-RestMethod -Uri $uri -Method Patch `
            -ContentType 'application/json; charset=utf-8' -Body $bytes | Out-Null
        return $true
    } catch { return $false }
}

# Thanh bar chay theo thoi gian, KHONG phai tien do that cua Unity.
# Unity khong he bao phan tram o batchmode - day thuan tuy la
# "da chay bao lau so voi cac lan truoc", nen luon ghi ro la uoc tinh.
function Format-CiProgressBar {
    param([double]$Ratio, [int]$Cells = 12)
    if ($Ratio -lt 0) { $Ratio = 0 }
    if ($Ratio -gt 1) { $Ratio = 1 }
    $full = [int][Math]::Round($Ratio * $Cells)
    # Chua xong thi khong bao gio duoc ve bar day.
    # Lam tron co the keo 0.97 len thanh day o bar ngan.
    if ($Ratio -lt 1 -and $full -ge $Cells) { $full = $Cells - 1 }
    return ('#' * $full) + ('.' * ($Cells - $full))
}

function New-CiProgressPayload {
    param($Job, [string]$Phase, [double]$ElapsedSeconds, [double]$EtaSeconds)

    $lines = New-Object System.Collections.ArrayList
    [void]$lines.Add("Giai doan: $Phase")

    if ($EtaSeconds -gt 0) {
        $ratio = $ElapsedSeconds / $EtaSeconds
        if ($ratio -gt 0.97) { $ratio = 0.97 }   # chua xong thi dung bao day
        [void]$lines.Add(('[{0}]  {1} / ~{2} (uoc tinh)' -f `
            (Format-CiProgressBar $ratio), (Format-Duration $ElapsedSeconds), (Format-Duration $EtaSeconds)))
    } else {
        [void]$lines.Add(('Da chay: {0}  (chua co so lieu de uoc tinh)' -f (Format-Duration $ElapsedSeconds)))
    }

    $desc = ''
    if ($Job.subject) { $desc = '**' + $Job.subject + '**' + "`n" }
    $desc += '```' + "`n" + ($lines -join "`n") + "`n" + '```'

    @{
        embeds = @(@{
            title       = 'Dang build...'
            description = $desc
            color       = 10197915
            fields      = @(
                @{ name='Project'; value="$($Job.project)"; inline=$true },
                @{ name='Branch';  value="$($Job.branch)";  inline=$true },
                @{ name='Commit';  value="$($Job.shaShort)";inline=$true },
                @{ name='Loai';    value=("{0} / {1}" -f "$($Job.format)".ToUpper(), $Job.config); inline=$true }
            )
            footer = @{ text = "Unity CI Build - $($Job.id)" }
        })
    }
}

function Send-DiscordTest {
    param([string]$WebhookUrl)
    $payload = @{
        embeds = @(@{
            title       = 'Unity CI Build da ket noi'
            description = 'Tu gio moi ket qua build se bao vao kenh nay.'
            color       = 5814783
        })
    }
    return (Send-DiscordRaw -WebhookUrl $WebhookUrl -Payload $payload)
}

# Tra ve message id de cac buoc sau sua lai chinh tin nhan nay
function Send-DiscordBuildStarted {
    param([string]$WebhookUrl, $Job, [double]$EtaSeconds = 0)
    $payload = New-CiProgressPayload -Job $Job -Phase 'Chuan bi' -ElapsedSeconds 0 -EtaSeconds $EtaSeconds
    $payload.embeds[0].title = 'Bat dau build...'
    return (Send-DiscordRaw -WebhookUrl $WebhookUrl -Payload $payload -ReturnId)
}

function Update-DiscordBuildProgress {
    param([string]$WebhookUrl, [string]$MessageId, $Job, [string]$Phase,
          [double]$ElapsedSeconds, [double]$EtaSeconds = 0)
    if (-not $MessageId) { return }
    $payload = New-CiProgressPayload -Job $Job -Phase $Phase -ElapsedSeconds $ElapsedSeconds -EtaSeconds $EtaSeconds
    Edit-DiscordMessage -WebhookUrl $WebhookUrl -MessageId $MessageId -Payload $payload | Out-Null
}

function Send-DiscordBuildResult {
    param(
        [string]$WebhookUrl,
        $Job,
        [bool]$Success,
        [bool]$Cancelled = $false,
        [double]$DurationSeconds,
        [string]$OutputPath = '',
        [long]$SizeBytes = 0,
        [string]$ShareLink = '',
        [string]$ErrorSummary = '',
        [string]$ErrorFile = '',
        [string]$MessageId = ''
    )
    if ([string]::IsNullOrWhiteSpace($WebhookUrl)) { return }

    # Build bi huy khong phai that bai - to mau khac de khoi hoang
    $color = if ($Success) { 3066993 } elseif ($Cancelled) { 9807270 } else { 15158332 }
    $title = if ($Success) { 'BUILD THANH CONG' } elseif ($Cancelled) { 'BUILD DA HUY' } else { 'BUILD THAT BAI' }

    $branchText = if ($Job.branch) { $Job.branch } else { '-' }
    $fields = @()
    if ($Job.project) { $fields += @{ name='Project'; value=$Job.project; inline=$true } }
    $fields += @(
        @{ name='Branch';    value=$branchText; inline=$true },
        @{ name='Commit';    value=$Job.shaShort;                                   inline=$true },
        @{ name='Loai';      value=("{0} / {1}" -f $Job.format.ToUpper(), $Job.config); inline=$true },
        @{ name='Thoi gian'; value=(Format-Duration $DurationSeconds);               inline=$true }
    )

    if ($Success) {
        if ($SizeBytes -gt 0) { $fields += @{ name='Dung luong'; value=(Format-Bytes $SizeBytes); inline=$true } }
        if ($Job.versionCode -gt 0) { $fields += @{ name='versionCode'; value=[string]$Job.versionCode; inline=$true } }
        if ($OutputPath) { $fields += @{ name='File'; value=('`' + (Split-Path -Leaf $OutputPath) + '`'); inline=$false } }
        if ($ShareLink)  { $fields += @{ name='Tester lay o day'; value=$ShareLink; inline=$false } }
    } else {
        if ($ErrorFile) { $fields += @{ name='Chi tiet loi'; value=('`' + $ErrorFile + '`'); inline=$false } }
    }

    $desc = ''
    if ($Job.subject) { $desc = '**' + $Job.subject + '**' }
    if (-not $Success -and $ErrorSummary) {
        $desc += "`n``````" + "`n" + $ErrorSummary.TrimEnd() + "`n" + '``````'
    }
    if ($desc.Length -gt 4000) { $desc = $desc.Substring(0, 4000) + '...' }

    $payload = @{
        embeds = @(@{
            title       = $title
            description = $desc
            color       = $color
            fields      = $fields
            footer      = @{ text = "Unity CI Build - $($Job.id) - goi tu $($Job.by)" }
            timestamp   = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
        })
    }
    # Mot build = mot card: sua chinh tin nhan tien do thanh ket qua cuoi
    if ($MessageId) {
        if (Edit-DiscordMessage -WebhookUrl $WebhookUrl -MessageId $MessageId -Payload $payload) { return }
    }
    Send-DiscordRaw -WebhookUrl $WebhookUrl -Payload $payload | Out-Null
}
