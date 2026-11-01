#Requires -Version 5.1
<#
    DefenderTune-Watch.ps1  --  drift monitor (no UI)
    ------------------------------------------------------------------
    Run by the scheduled task. Compares DefenderTune.expected.json with the
    live Defender settings; on mismatch it shows a toast and writes a log.

    No admin needed: all nine values below are readable as a normal user.

    Exit codes:
      0 = check finished (drift or not)
      2 = expected-state file missing, skipped
      3 = could not read Defender settings

    With -DriftExitCode, drift returns 1. Only the main menu uses that; the
    task does not, because Task Scheduler records any non-zero as "last run
    failed" - real drift would then show red and look like a broken tool.

    Test the toast on demand:
      powershell -NoProfile -ExecutionPolicy Bypass -File .\DefenderTune-Watch.ps1 -TestToast
#>

[CmdletBinding()]
param(
    [switch]$TestToast,
    [switch]$DriftExitCode
)

$ErrorActionPreference = 'Stop'

$root = $PSScriptRoot
if ([string]::IsNullOrEmpty($root)) {
    $root = Split-Path -Parent $MyInvocation.MyCommand.Path
}

$expectedFile = Join-Path $root 'DefenderTune.expected.json'
$logFile      = Join-Path $root 'DefenderTune.drift.log'
$stateFile    = Join-Path $root 'DefenderTune.drift.state'

# The nine watched values. Exclusions need admin, so they are not compared.
$monitoredKeys = @(
    'ScanAvgCPULoadFactor'
    'EnableLowCpuPriority'
    'ScanScheduleTime'
    'ScanScheduleDay'
    'DisableCatchupQuickScan'
    'DisableCatchupFullScan'
    'MAPSReporting'
    'SubmitSamplesConsent'
    'DisableBlockAtFirstSeen'
)

# ------------------------------------------------------------------
function Write-Log {
    param([string]$Message)
    try {
        $line = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss') + '  ' + $Message
        Add-Content -LiteralPath $logFile -Value $line -Encoding UTF8
    } catch { }
}

function Show-Toast {
    param([string]$Title, [string]$Text, [int]$Seconds = 10)

    # NotifyIcon balloon: no module dependency, lands in Action Center on Win10/11.
    # The process must outlive the balloon, hence the Sleep below.
    try {
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
        Add-Type -AssemblyName System.Drawing -ErrorAction Stop

        $ni = New-Object System.Windows.Forms.NotifyIcon
        $ni.Icon = [System.Drawing.SystemIcons]::Warning
        $ni.BalloonTipTitle = $Title
        $ni.BalloonTipText = $Text
        $ni.BalloonTipIcon = [System.Windows.Forms.ToolTipIcon]::Warning
        $ni.Visible = $true
        $ni.ShowBalloonTip(15000)

        Start-Sleep -Seconds $Seconds
        $ni.Dispose()
        return $true
    } catch {
        Write-Log ('toast failed:  /  通知发送失败: ' + $_.Exception.Message)
        return $false
    }
}

function Get-CurrentState {
    $pf = Get-MpPreference -ErrorAction Stop
    $result = [ordered]@{}
    foreach ($k in $monitoredKeys) {
        switch ($k) {
            'ScanAvgCPULoadFactor'    { $result[$k] = [string][int]$pf.ScanAvgCPULoadFactor }
            'EnableLowCpuPriority'    { $result[$k] = [string][bool]$pf.EnableLowCpuPriority }
            'ScanScheduleTime'        { $result[$k] = if ($null -eq $pf.ScanScheduleTime) { '' } else { $pf.ScanScheduleTime.ToString('hh\:mm\:ss') } }
            'ScanScheduleDay'         { $result[$k] = [string][int]$pf.ScanScheduleDay }
            'DisableCatchupQuickScan' { $result[$k] = [string][bool]$pf.DisableCatchupQuickScan }
            'DisableCatchupFullScan'  { $result[$k] = [string][bool]$pf.DisableCatchupFullScan }
            'MAPSReporting'           { $result[$k] = [string][int]$pf.MAPSReporting }
            'SubmitSamplesConsent'    { $result[$k] = [string][int]$pf.SubmitSamplesConsent }
            'DisableBlockAtFirstSeen' { $result[$k] = [string][bool]$pf.DisableBlockAtFirstSeen }
        }
    }
    return $result
}

function Compare-State {
    param($Expected, $Current)

    $diffs = @()
    foreach ($p in $Expected.PSObject.Properties) {
        $k = $p.Name
        if (-not $Current.Contains($k)) { continue }
        $exp = [string]$p.Value
        $cur = [string]$Current[$k]
        if ($exp -ne $cur) {
            $diffs += [pscustomobject]@{ Name = $k; Expected = $exp; Actual = $cur }
        }
    }
    return $diffs
}

function Get-Signature {
    param($Diffs)
    return (($Diffs | ForEach-Object { $_.Name + '=' + $_.Expected + '>' + $_.Actual } | Sort-Object) -join ';')
}

# Toast once per 12h for the same drift, instead of firing every 6h.
function Test-ShouldToast {
    param([string]$Signature)

    if (-not (Test-Path -LiteralPath $stateFile)) { return $true }
    try {
        $st = Get-Content -LiteralPath $stateFile -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($st.Signature -ne $Signature) { return $true }
        $last = [datetime]::Parse($st.At, [Globalization.CultureInfo]::InvariantCulture)
        if (((Get-Date) - $last).TotalHours -ge 12) { return $true }
        return $false
    } catch {
        return $true
    }
}

function Save-State {
    param([string]$Signature)
    try {
        $o = [ordered]@{ Signature = $Signature; At = (Get-Date).ToString('s') }
        ($o | ConvertTo-Json) | Set-Content -LiteralPath $stateFile -Encoding UTF8
    } catch { }
}

# ------------------------------------------------------------------
#  Entry point
# ------------------------------------------------------------------

if ($TestToast) {
    $ok = Show-Toast 'DefenderTune test notification  /  DefenderTune 测试通知' "If you can see this, the toast channel works.`nIf a setting changes, this is how you will be told.`n如果你能看到这条消息,说明漂移监控的通知通道可用。`n检测到设置被改动时,会用它提醒你。"
    if ($ok) { exit 0 } else { exit 3 }
}

try {
    if (-not (Test-Path -LiteralPath $expectedFile)) {
        Write-Log 'no expected-state file, skipped  /  没有期望值文件,跳过检查'
        exit 2
    }

    $expected = Get-Content -LiteralPath $expectedFile -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($null -eq $expected.Prefs) {
        Write-Log 'expected-state file malformed (missing Prefs)  /  期望值文件格式不对(缺 Prefs)'
        exit 2
    }

    $current = Get-CurrentState
} catch {
    Write-Log ('check failed:  /  检查失败: ' + $_.Exception.Message)
    exit 3
}

$diffs = @(Compare-State -Expected $expected.Prefs -Current $current)

if ($diffs.Count -eq 0) {
    Write-Log 'settings match, no notification  /  设置一致,无需通知'
    exit 0
}

$detail = ($diffs | ForEach-Object { $_.Name + ': ' + $_.Expected + ' -> ' + $_.Actual }) -join ' | '
Write-Log ('Drift: ' + $diffs.Count + ' item(s)  /  检测到 ' + $diffs.Count + ' 项漂移 -> ' + $detail)

$sig = Get-Signature $diffs
if (-not (Test-ShouldToast -Signature $sig)) {
    Write-Log 'same drift already toasted within 12h; log only  /  同一漂移 12 小时内已通知过,本次只记日志'
    if ($DriftExitCode) { exit 1 }
    exit 0
}

$lines = @($diffs | ForEach-Object { $_.Name + ': ' + $_.Expected + ' -> ' + $_.Actual })
$body = ($lines | Select-Object -First 4) -join "`n"
if ($lines.Count -gt 4) {
    $body += "`n...  /  ... 还有 " + ($lines.Count - 4) + ' 项'
}
$body += "`nOpen DefenderTune to revert  /  打开 DefenderTune 可一键改回"

$shown = Show-Toast ('DefenderTune: ' + $diffs.Count + ' setting(s) changed  /  有 ' + $diffs.Count + ' 项设置被改动') $body
if ($shown) { Write-Log 'system notification sent  /  已发送系统通知' } else { Write-Log 'system notification failed  /  系统通知发送失败' }
Save-State -Signature $sig

if ($DriftExitCode) { exit 1 }
exit 0
