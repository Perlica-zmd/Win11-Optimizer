#Requires -Version 5.1
<#
    DefenderTune.ps1  --  Windows Defender performance tuner (console)
    ------------------------------------------------------------------
    Windows 10 / 11. Requires administrator rights.

    Three jobs only:
      1. Lower the cost of scheduled scans (low priority / CPU cap / night slot / no catch-up)
      2. Manage exclusions (fewer watched files = less overhead)
      3. Save and restore a settings snapshot

    It does NOT disable real-time protection and does NOT touch tamper protection.
    Every change can be reverted with "restore snapshot".

    Usage:
      Right-click Run.cmd, "Run as administrator"
      or: powershell -ExecutionPolicy Bypass -File .\DefenderTune.ps1
#>

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$Script:SnapshotFile  = Join-Path $PSScriptRoot 'DefenderTune.snapshot.json'
$Script:ExpectedFile  = Join-Path $PSScriptRoot 'DefenderTune.expected.json'
$Script:WatchScript   = Join-Path $PSScriptRoot 'DefenderTune-Watch.ps1'
$Script:DriftLog      = Join-Path $PSScriptRoot 'DefenderTune.drift.log'
$Script:WatchTaskName = 'DefenderTune-DriftWatch'

# ==================================================================
#  Console UI helpers
# ==================================================================

function Write-Head {
    param([string]$Text)
    Write-Host ''
    Write-Host ('-' * 60) -ForegroundColor DarkGray
    Write-Host ('  ' + $Text) -ForegroundColor Cyan
    Write-Host ('-' * 60) -ForegroundColor DarkGray
}

function Write-Ok      { param([string]$Text) Write-Host ('  [OK] ' + $Text) -ForegroundColor Green }
function Write-Note    { param([string]$Text) Write-Host ('  ---- ' + $Text) -ForegroundColor Gray }
function Write-Caution { param([string]$Text) Write-Host ('  [!!] ' + $Text) -ForegroundColor Yellow }
function Write-Fail    { param([string]$Text) Write-Host ('  [XX] ' + $Text) -ForegroundColor Red }

function Pause-Ui {
    Write-Host ''
    [void](Read-Host '  Press Enter to continue  /  按回车继续')
}

function Confirm-Yes {
    param([string]$Prompt = '  Continue? [y/N]  /  确认执行?[y/N] ')
    $a = Read-Host $Prompt
    return ($a -match '^(y|Y|yes|YES)$')
}

function Confirm-Strong {
    param([string]$Prompt = '  This weakens protection. Type YES to confirm:  /  此项会降低防护,输入 YES 确认: ')
    $a = Read-Host $Prompt
    return ($a -ceq 'YES')
}

function Write-StatusRow {
    param([string]$Label, $Value)
    $line = '  ' + $Label + ': '
    $color = 'White'
    if ($Value -is [bool]) {
        if ($Value) { $line = $line + 'on  /  已开启'; $color = 'Green' }
        else        { $line = $line + 'off  /  未开启'; $color = 'DarkYellow' }
    } else {
        $line = $line + [string]$Value
    }
    Write-Host $line -ForegroundColor $color
}

# ==================================================================
#  Startup checks
# ==================================================================

function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal -ArgumentList $id
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Initialize-Admin {
    if (Test-Admin) { return $true }
    Write-Caution 'Not elevated - requesting administrator rights...  /  当前不是管理员,正在请求提权重启...'
    try {
        $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"' + $PSCommandPath + '"'))
        Start-Process -FilePath 'powershell.exe' -ArgumentList $argList -Verb RunAs | Out-Null
    } catch {
        Write-Fail 'Elevation cancelled or failed. Right-click Run.cmd and pick "Run as administrator".  /  提权被取消或失败。请右键 Run.cmd,选择「以管理员身份运行」。'
        Pause-Ui
    }
    return $false
}

function Test-DefenderModule {
    return [bool](Get-Command -Name 'Get-MpPreference' -ErrorAction SilentlyContinue)
}

# ==================================================================
#  Defender read/write wrappers
# ==================================================================

function Get-ExclusionList {
    param([string]$Kind = 'Path')
    $pf = Get-MpPreference -ErrorAction Stop
    $raw = switch ($Kind) {
        'Path'      { $pf.ExclusionPath }
        'Process'   { $pf.ExclusionProcess }
        'Extension' { $pf.ExclusionExtension }
    }
    # Without admin rights Defender returns a placeholder string here. Drop it.
    return @($raw | Where-Object { $_ -and (([string]$_) -notmatch '^N/A') })
}

# Get-MpPreference returns TimeSpan for ScanScheduleTime, but
# Set-MpPreference -ScanScheduleTime takes DateTime. Convert both ways explicitly.
function ConvertTo-SafeDate {
    param($Value)
    if ($null -eq $Value) { return $null }
    if ($Value -is [datetime]) { return $Value }
    if ($Value -is [timespan]) { return [datetime]::Today.Add($Value) }
    if ([string]::IsNullOrWhiteSpace([string]$Value)) { return $null }

    $text = ([string]$Value).Trim()
    # Time-only form (HH:mm or HH:mm:ss): attach to today.
    if ($text -match '^\d{1,2}:\d{2}(:\d{2})?$') {
        return [datetime]::Today.Add([timespan]::Parse($text, [Globalization.CultureInfo]::InvariantCulture))
    }
    return [datetime]::Parse($text, [Globalization.CultureInfo]::InvariantCulture)
}

# Store as fixed HH:mm:ss so it is locale-independent.
function ConvertTo-TimeText {
    param($Value)
    if ($null -eq $Value) { return $null }
    if ($Value -is [timespan]) { return $Value.ToString('hh\:mm\:ss') }
    if ($Value -is [datetime]) { return $Value.ToString('HH:mm:ss', [Globalization.CultureInfo]::InvariantCulture) }
    return [string]$Value
}

function Set-DefenderPreference {
    param([string]$Name, $Value)
    switch ($Name) {
        'ScanAvgCPULoadFactor'    { Set-MpPreference -ScanAvgCPULoadFactor ([int]$Value) }
        'EnableLowCpuPriority'    { Set-MpPreference -EnableLowCpuPriority ([bool]$Value) }
        'ScanScheduleTime'        { Set-MpPreference -ScanScheduleTime (ConvertTo-SafeDate $Value) }
        'ScanScheduleDay'         { Set-MpPreference -ScanScheduleDay ([int]$Value) }
        'DisableCatchupQuickScan' { Set-MpPreference -DisableCatchupQuickScan ([bool]$Value) }
        'DisableCatchupFullScan'  { Set-MpPreference -DisableCatchupFullScan ([bool]$Value) }
        'MAPSReporting'           { Set-MpPreference -MAPSReporting ([int]$Value) }
        'SubmitSamplesConsent'    { Set-MpPreference -SubmitSamplesConsent ([int]$Value) }
        'DisableBlockAtFirstSeen' { Set-MpPreference -DisableBlockAtFirstSeen ([bool]$Value) }
        default { throw ('unknown setting:  /  未知设置项: ' + $Name) }
    }
}

function Add-ExclusionValue {
    param([string]$Kind, [string]$Value)
    switch ($Kind) {
        'Path'      { Add-MpPreference -ExclusionPath $Value }
        'Process'   { Add-MpPreference -ExclusionProcess $Value }
        'Extension' { Add-MpPreference -ExclusionExtension $Value }
    }
}

function Remove-ExclusionValue {
    param([string]$Kind, [string]$Value)
    switch ($Kind) {
        'Path'      { Remove-MpPreference -ExclusionPath $Value }
        'Process'   { Remove-MpPreference -ExclusionProcess $Value }
        'Extension' { Remove-MpPreference -ExclusionExtension $Value }
    }
}

# ==================================================================
#  1) Status
# ==================================================================

function Show-Status {
    Write-Head 'Current status  /  当前状态'

    $st = $null
    $pf = $null
    try { $st = Get-MpComputerStatus -ErrorAction Stop } catch { }
    try { $pf = Get-MpPreference -ErrorAction Stop } catch { }

    if ($null -eq $pf) {
        Write-Fail 'Could not read Defender settings. Maybe absent or policy-managed.  /  读取 Defender 设置失败。可能未安装 Defender,或被组策略接管。'
        return
    }

    $rt = 'unknown  /  未知'; $bm = 'unknown  /  未知'; $tp = 'unknown  /  未知'
    $eng = 'unknown  /  未知'; $sig = 'unknown  /  未知'; $sigTime = 'unknown  /  未知'
    if ($null -ne $st) {
        $rt = $st.RealTimeProtectionEnabled
        $bm = $st.BehaviorMonitorEnabled
        $tp = $st.IsTamperProtected
        $eng = $st.AMEngineVersion
        $sig = $st.AntivirusSignatureVersion
        $sigTime = $st.AntivirusSignatureLastUpdated
    }

    $cloud = [string]$pf.MAPSReporting
    switch ([int]$pf.MAPSReporting) {
        0 { $cloud = '0 (off)  /  0 (已关闭)' }
        1 { $cloud = '1 (basic)  /  1 (基本)' }
        2 { $cloud = '2 (advanced)  /  2 (高级)' }
    }

    $pathCount = @(Get-ExclusionList -Kind 'Path').Count
    $procCount = @(Get-ExclusionList -Kind 'Process').Count

    Write-Host ''
    Write-StatusRow 'Real-time protection  /  实时防护' $rt
    Write-StatusRow 'Behavior monitoring  /  行为监控' $bm
    Write-StatusRow 'Tamper protection  /  篡改防护' $tp
    Write-StatusRow 'Cloud protection (MAPS)  /  云保护(MAPS)' $cloud
    Write-StatusRow 'Engine version  /  引擎版本' $eng
    Write-StatusRow 'Signature version  /  特征库版本' $sig
    Write-StatusRow 'Signatures updated  /  特征库更新时间' $sigTime
    Write-Host ''
    Write-StatusRow 'Scan CPU cap  /  扫描 CPU 上限' ([string]$pf.ScanAvgCPULoadFactor + ' %')
    Write-StatusRow 'Low-priority scans  /  扫描低优先级' $pf.EnableLowCpuPriority
    Write-StatusRow 'Scheduled scan time  /  计划扫描时间' ([string]$pf.ScanScheduleTime)
    Write-StatusRow 'Scheduled scan day  /  计划扫描星期' ([string]$pf.ScanScheduleDay + '  (0=daily, 1-7=Sun..Sat, 8=never)  /  (0=每天, 1-7=周日..周六, 8=从不)')
    Write-StatusRow 'Catch-up scans (quick/full)  /  关闭补扫(快/全)' ([string]$pf.DisableCatchupQuickScan + ' / ' + [string]$pf.DisableCatchupFullScan)
    Write-StatusRow 'Path exclusions  /  排除目录数' ([string]$pathCount)
    Write-StatusRow 'Process exclusions  /  排除进程数' ([string]$procCount)

    $avs = @()
    try {
        $avs = @(Get-CimInstance -Namespace 'root\SecurityCenter2' -ClassName AntiVirusProduct -ErrorAction Stop)
    } catch { }

    if ($avs.Count -gt 0) {
        Write-Host ''
        Write-Note 'Security products registered with Security Center:  /  已向安全中心注册的安全产品:'
        foreach ($a in $avs) { Write-Host ('      - ' + $a.displayName) -ForegroundColor Gray }
    }
}

# ==================================================================
#  2) Tier A: low-impact preset
# ==================================================================

function Invoke-LowImpactPreset {
    Write-Head 'Tier A: low-impact preset (no loss of protection)  /  A 档:低干扰预设(不影响防护强度)'
    Write-Host '  Settings to apply  /  将应用以下设置:'
    Write-Host '    1) Low CPU priority  /  扫描使用低 CPU 优先级            EnableLowCpuPriority    = true'
    Write-Host '    2) Scan CPU cap 20% (default 50)  /  扫描 CPU 上限 20%   ScanAvgCPULoadFactor     = 20'
    Write-Host '    3) Scheduled scan at 03:00  /  计划扫描改到每天 03:00    ScanScheduleTime         = 03:00'
    Write-Host '    4) Skip catch-up scans  /  关闭错过后的补扫              DisableCatchupQuickScan  = true'
    Write-Host '                                                             DisableCatchupFullScan   = true'
    Write-Host ''
    Write-Ok 'None of these weaken real-time protection or touch tamper protection.  /  以上均不降低实时防护强度,也不涉及篡改防护。'
    if (-not (Confirm-Yes)) { return }
    if (-not (Ensure-Snapshot)) { return }

    $items = [ordered]@{
        EnableLowCpuPriority    = $true
        ScanAvgCPULoadFactor    = 20
        ScanScheduleTime        = (Get-Date).Date.AddHours(3)
        DisableCatchupQuickScan = $true
        DisableCatchupFullScan  = $true
    }

    $ok = 0
    $bad = 0
    foreach ($k in $items.Keys) {
        try {
            Set-DefenderPreference -Name $k -Value $items[$k]
            Write-Ok ($k + ' = ' + [string]$items[$k])
            $ok++
        } catch {
            Write-Fail ($k + ' failed  /  失败: ' + $_.Exception.Message)
            $bad++
        }
    }

    Write-Host ''
    Write-Note ('Done: ' + $ok + ' applied, ' + $bad + ' failed.  /  完成:成功 ' + $ok + ' 项,失败 ' + $bad + ' 项。')
    if ($bad -gt 0) {
        Write-Caution 'Failures usually mean the value is controlled by policy.  /  设置失败通常意味着这些项被组策略接管。'
    }
    if ($ok -gt 0) { [void](Save-ExpectedState -Quiet) }
}

# ==================================================================
#  3) Tier B: exclusions
# ==================================================================

function Show-ExclusionList {
    $kinds = @('Path', 'Process', 'Extension')
    $names = @{ Path = 'path  /  路径'; Process = 'process  /  进程'; Extension = 'extension  /  扩展名' }

    Write-Head 'Current exclusions  /  当前排除项'
    foreach ($k in $kinds) {
        $items = @(Get-ExclusionList -Kind $k)
        Write-Host ('  [' + $names[$k] + ']  total ' + $items.Count) -ForegroundColor Cyan
        if ($items.Count -eq 0) {
            Write-Host '        (empty)  /  (空)' -ForegroundColor DarkGray
        } else {
            for ($i = 0; $i -lt $items.Count; $i++) {
                Write-Host ('    ' + ($i + 1) + '. ' + $items[$i])
            }
        }
    }
}

function Add-ExclusionInteractive {
    param([ValidateSet('Path', 'Process', 'Extension')][string]$Kind)

    $labels = @{
        Path      = 'Full path to a folder or file  /  目录或文件的完整路径'
        Process   = 'Process file name (e.g. node.exe)  /  进程文件名(如 node.exe)'
        Extension = 'Extension (e.g. .log)  /  扩展名(如 .log)'
    }

    Write-Head ('Add exclusion:  /  添加排除: ' + $Kind)
    $v = Read-Host ('  Enter  /  请输入: ' + $labels[$Kind])
    if ([string]::IsNullOrWhiteSpace($v)) {
        Write-Caution 'Empty input - cancelled.  /  输入为空,已取消。'
        return
    }
    $v = $v.Trim().Trim('"')

    if ($Kind -eq 'Path' -and -not (Test-Path -LiteralPath $v)) {
        Write-Caution 'That path does not exist.  /  该路径当前不存在。'
        if (-not (Confirm-Yes '  Add anyway? [y/N]  /  仍然添加?[y/N] ')) { return }
    }
    if (-not (Ensure-Snapshot)) { return }

    try {
        Add-ExclusionValue -Kind $Kind -Value $v
        Write-Ok ('added:  /  已添加: ' + $v)
        if ($Kind -eq 'Path') {
            Write-Note 'This path and its subfolders are no longer scanned in real time.  /  该路径及其子目录不再被实时扫描。'
        }
    } catch {
        Write-Fail ('add failed:  /  添加失败: ' + $_.Exception.Message)
    }
}

function Remove-ExclusionInteractive {
    $kinds = @('Path', 'Process', 'Extension')
    $names = @{ Path = 'path  /  路径'; Process = 'process  /  进程'; Extension = 'extension  /  扩展名' }

    Write-Head 'Remove exclusions  /  删除排除项'
    $pick = Read-Host '  Which kind? 1=path 2=process 3=extension 0=cancel  /  要删除哪一类? 1=路径 2=进程 3=扩展名 0=取消'
    $idx = -1
    switch ($pick) {
        '1' { $idx = 0 }
        '2' { $idx = 1 }
        '3' { $idx = 2 }
        default { return }
    }

    $kind = $kinds[$idx]
    $items = @(Get-ExclusionList -Kind $kind)
    if ($items.Count -eq 0) {
        Write-Note ('No ' + $names[$kind] + ' exclusions to remove.  /  没有可删除的排除项。')
        return
    }

    for ($i = 0; $i -lt $items.Count; $i++) {
        Write-Host ('    ' + ($i + 1) + '. ' + $items[$i])
    }

    $num = Read-Host '  Enter index numbers to remove (comma-separated)  /  输入要删除的序号(多个用逗号分隔)'
    $targets = @()
    foreach ($t in ($num -split ',')) {
        $n = 0
        if ([int]::TryParse($t.Trim(), [ref]$n) -and $n -ge 1 -and $n -le $items.Count) {
            $targets += $items[$n - 1]
        }
    }

    if ($targets.Count -eq 0) {
        Write-Caution 'No valid index given.  /  没有有效序号。'
        return
    }

    Write-Note 'These exclusions will be removed (paths become protected again):  /  将删除以下排除项(删除后这些位置恢复受保护):'
    foreach ($t in $targets) { Write-Host ('    - ' + $t) }
    if (-not (Confirm-Yes)) { return }
    if (-not (Ensure-Snapshot)) { return }

    foreach ($t in $targets) {
        try {
            Remove-ExclusionValue -Kind $kind -Value $t
            Write-Ok ('deleted:  /  已删除: ' + $t)
        } catch {
            Write-Fail ('delete failed:  /  删除失败: ' + $t + ' -> ' + $_.Exception.Message)
        }
    }
}

function Show-ExclusionMenu {
    while ($true) {
        Write-Head 'Tier B: exclusions (biggest win)  /  B 档:排除项管理(对性能影响最大)'
        Write-Host '  1) List all exclusions  /  列出全部排除项'
        Write-Host '  2) Add folder / file exclusion  /  添加目录 / 文件排除'
        Write-Host '  3) Add process exclusion (e.g. node.exe)  /  添加进程排除(如 node.exe)'
        Write-Host '  4) Remove exclusions  /  删除排除项'
        Write-Host '  0) Back  /  返回'
        Write-Host ''
        Write-Note 'More exclusions means fewer watched files, so less overhead.  /  排除项越多,实时监控要扫的文件越少,机器越轻。'
        Write-Note 'Cost: excluded paths are no longer scanned in real time.  /  代价:被排除的路径不再受实时防护。'
        Write-Host ''
        $c = Read-Host '  Select  /  请选择'

        switch ($c) {
            '1' { Show-ExclusionList; Pause-Ui }
            '2' { Add-ExclusionInteractive -Kind 'Path'; Pause-Ui }
            '3' { Add-ExclusionInteractive -Kind 'Process'; Pause-Ui }
            '4' { Remove-ExclusionInteractive; Pause-Ui }
            '0' { return }
        }
    }
}

# ==================================================================
#  4) Tier C: switches that weaken protection
# ==================================================================

function Toggle-CloudProtection {
    $pf = Get-MpPreference
    if ([int]$pf.MAPSReporting -ne 0) {
        Write-Caution 'Disabling cloud protection and sample submission slows response to new samples.  /  关闭云保护和样本提交后,遇到新样本时响应会明显变慢。'
        if (Confirm-Strong) {
            if (-not (Ensure-Snapshot)) { return }
            try {
                Set-MpPreference -MAPSReporting 0
                Set-MpPreference -SubmitSamplesConsent 2
                Write-Ok 'Cloud protection disabled (restore it from this menu).  /  云保护已关闭(可在本菜单恢复)。'
                [void](Save-ExpectedState -Quiet)
            } catch {
                Write-Fail ('setting failed:  /  设置失败: ' + $_.Exception.Message)
            }
        }
    } else {
        Write-Note 'Currently off. Restore to Advanced and submit safe samples?  /  当前为关闭状态。恢复为「高级」并提交安全样本?'
        if (Confirm-Yes) {
            if (-not (Ensure-Snapshot)) { return }
            try {
                Set-MpPreference -MAPSReporting 2
                Set-MpPreference -SubmitSamplesConsent 1
                Write-Ok 'Cloud protection restored to Advanced.  /  云保护已恢复为高级。'
                [void](Save-ExpectedState -Quiet)
            } catch {
                Write-Fail ('setting failed:  /  设置失败: ' + $_.Exception.Message)
            }
        }
    }
}

function Toggle-BlockAtFirstSeen {
    $pf = Get-MpPreference
    if (-not [bool]$pf.DisableBlockAtFirstSeen) {
        Write-Caution 'Disabling block-at-first-sight lets unknown files run before a verdict.  /  关闭「首次见到即阻止」会让未知文件先跑起来再判定。'
        if (Confirm-Strong) {
            if (-not (Ensure-Snapshot)) { return }
            try {
                Set-MpPreference -DisableBlockAtFirstSeen $true
                Write-Ok 'Disabled.  /  已关闭。'
                [void](Save-ExpectedState -Quiet)
            } catch {
                Write-Fail ('setting failed:  /  设置失败: ' + $_.Exception.Message)
            }
        }
    } else {
        Write-Note 'Currently off. Turn it back on?  /  当前为关闭状态。恢复为开启?'
        if (Confirm-Yes) {
            if (-not (Ensure-Snapshot)) { return }
            try {
                Set-MpPreference -DisableBlockAtFirstSeen $false
                Write-Ok 'Re-enabled.  /  已恢复开启。'
                [void](Save-ExpectedState -Quiet)
            } catch {
                Write-Fail ('setting failed:  /  设置失败: ' + $_.Exception.Message)
            }
        }
    }
}

function Toggle-ScheduledScan {
    $pf = Get-MpPreference
    $day = [int]$pf.ScanScheduleDay
    if ($day -ne 8) {
        Write-Caution 'With scheduled scans off, only real-time protection remains.  /  彻底关闭计划扫描后,只剩实时防护在起作用。'
        Write-Caution 'If it is only noisy, use the Tier A night slot instead.  /  如果只是嫌它吵,建议改用 A 档的夜间扫描。'
        if (Confirm-Strong) {
            if (-not (Ensure-Snapshot)) { return }
            try {
                Set-MpPreference -ScanScheduleDay 8
                Write-Ok 'Scheduled scans disabled.  /  计划扫描已关闭。'
                [void](Save-ExpectedState -Quiet)
            } catch {
                Write-Fail ('setting failed:  /  设置失败: ' + $_.Exception.Message)
            }
        }
    } else {
        Write-Note 'Currently off. Restore daily scans?  /  当前为关闭状态。恢复为每天扫描?'
        if (Confirm-Yes) {
            if (-not (Ensure-Snapshot)) { return }
            try {
                Set-MpPreference -ScanScheduleDay 0
                Write-Ok 'Daily scans restored.  /  已恢复每天扫描。'
                [void](Save-ExpectedState -Quiet)
            } catch {
                Write-Fail ('setting failed:  /  设置失败: ' + $_.Exception.Message)
            }
        }
    }
}

function Show-AdvancedMenu {
    while ($true) {
        Write-Head 'Tier C: settings that weaken protection  /  C 档:会降低防护的设置'
        Write-Host '  Each one is a toggle; turn it back on here.  /  每一项都是开关,关掉之后可以在这里恢复。'
        Write-Host ''
        Write-Host '  1) Cloud protection (MAPSReporting / sample submission)  /  云保护(MAPSReporting / 样本提交)'
        Write-Host '  2) Block at first sight (DisableBlockAtFirstSeen)  /  首次见到即阻止(DisableBlockAtFirstSeen)'
        Write-Host '  3) Scheduled scan (ScanScheduleDay)  /  计划扫描(ScanScheduleDay)'
        Write-Host '  0) Back  /  返回'
        Write-Host ''
        $c = Read-Host '  Select  /  请选择'

        switch ($c) {
            '1' { Toggle-CloudProtection; Pause-Ui }
            '2' { Toggle-BlockAtFirstSeen; Pause-Ui }
            '3' { Toggle-ScheduledScan; Pause-Ui }
            '0' { return }
        }
    }
}

# ==================================================================
#  5) Snapshot and restore
# ==================================================================

# Writes the file only, no prompts. Shared by the menu and the auto-snapshot.
function Save-SnapshotCore {
    try {
        $pf = Get-MpPreference
        $snap = [ordered]@{
            Version   = 1
            CreatedAt = (Get-Date).ToString('s')
            Machine   = $env:COMPUTERNAME
            Prefs     = [ordered]@{
                ScanAvgCPULoadFactor    = [int]$pf.ScanAvgCPULoadFactor
                EnableLowCpuPriority    = [bool]$pf.EnableLowCpuPriority
                ScanScheduleTime        = ConvertTo-TimeText $pf.ScanScheduleTime
                ScanScheduleDay         = [int]$pf.ScanScheduleDay
                DisableCatchupQuickScan = [bool]$pf.DisableCatchupQuickScan
                DisableCatchupFullScan  = [bool]$pf.DisableCatchupFullScan
                MAPSReporting           = [int]$pf.MAPSReporting
                SubmitSamplesConsent    = [int]$pf.SubmitSamplesConsent
                DisableBlockAtFirstSeen = [bool]$pf.DisableBlockAtFirstSeen
            }
            ExclusionPath      = @(Get-ExclusionList -Kind 'Path')
            ExclusionProcess   = @(Get-ExclusionList -Kind 'Process')
            ExclusionExtension = @(Get-ExclusionList -Kind 'Extension')
        }

        ($snap | ConvertTo-Json -Depth 6) | Set-Content -LiteralPath $Script:SnapshotFile -Encoding UTF8
        Write-Ok ('Snapshot saved:  /  快照已保存: ' + $Script:SnapshotFile)
        Write-Note '"Restore snapshot" will always bring back this exact state.  /  以后任何时候执行「一键还原」都会回到这一刻的状态。'
        return $true
    } catch {
        Write-Fail ('save failed:  /  保存失败: ' + $_.Exception.Message)
        return $false
    }
}

function Save-Snapshot {
    Write-Head 'Save settings snapshot  /  保存当前设置快照'

    if (Test-Path -LiteralPath $Script:SnapshotFile) {
        Write-Caution ('Snapshot already exists:  /  已存在快照: ' + $Script:SnapshotFile)
        Write-Caution 'Continuing overwrites it.  /  继续会覆盖它。'
        if (-not (Confirm-Yes)) { return }
    }
    [void](Save-SnapshotCore)
}

# Call before any change. Creates a snapshot when missing, so rollback
# never depends on the user remembering to press menu 5 first.
function Ensure-Snapshot {
    if (Test-Path -LiteralPath $Script:SnapshotFile) { return $true }
    Write-Host ''
    Write-Caution 'No snapshot yet. Saving the current state first, otherwise this cannot be undone.  /  还没有快照。修改之前先自动保存当前状态,否则之后无法还原。'
    if (Save-SnapshotCore) {
        Write-Ok 'Snapshot saved automatically.  /  已自动保存快照。'
        return $true
    }
    Write-Fail 'Snapshot failed - change cancelled.  /  快照保存失败,已取消本次修改。'
    return $false
}

function Restore-ExclusionSet {
    param([string]$Kind, $Snapshot)

    $targets = @($Snapshot | Where-Object { $_ })
    $current = @(Get-ExclusionList -Kind $Kind)

    $toAdd = @($targets | Where-Object { $current -notcontains $_ })
    $toDel = @($current | Where-Object { $targets -notcontains $_ })

    foreach ($v in $toAdd) {
        try {
            Add-ExclusionValue -Kind $Kind -Value $v
            Write-Ok ('Re-added exclusion  /  补回排除项: ' + $v)
        } catch {
            Write-Fail ('Re-add failed  /  补回失败: ' + $v)
        }
    }

    if ($toDel.Count -gt 0) {
        Write-Caution ('Added after the snapshot  /  快照之后新增的排除项:')
        foreach ($v in $toDel) { Write-Host ('    - ' + $v) }
        if (Confirm-Yes '  Delete them too and fully match the snapshot? [y/N]  /  一并删除,完全回到快照状态?[y/N] ') {
            foreach ($v in $toDel) {
                try {
                    Remove-ExclusionValue -Kind $Kind -Value $v
                    Write-Ok ('deleted:  /  已删除: ' + $v)
                } catch {
                    Write-Fail ('delete failed:  /  删除失败: ' + $v)
                }
            }
        }
    }
}

function Restore-Snapshot {
    Write-Head 'Restore snapshot  /  一键还原到快照'

    if (-not (Test-Path -LiteralPath $Script:SnapshotFile)) {
        Write-Caution 'No snapshot yet. Run "Save settings snapshot" first.  /  还没有快照。请先执行「保存当前设置快照」。'
        return
    }

    try {
        $snap = Get-Content -LiteralPath $Script:SnapshotFile -Raw -Encoding UTF8 | ConvertFrom-Json
    } catch {
        Write-Fail ('could not read snapshot:  /  读取快照失败: ' + $_.Exception.Message)
        return
    }

    Write-Host ('  Snapshot time:  /  快照时间: ' + $snap.CreatedAt)
    Write-Host ('  Snapshot machine:  /  快照机器: ' + $snap.Machine)
    if ($snap.Machine -ne $env:COMPUTERNAME) {
        Write-Caution 'This snapshot came from another machine - confirm you really want it.  /  这个快照来自另一台机器,请确认你真的要还原。'
    }

    Write-Host ''
    Write-Note 'These values will be written:  /  将写入以下设置:'
    foreach ($p in $snap.Prefs.PSObject.Properties) {
        Write-Host ('      ' + $p.Name + ' = ' + [string]$p.Value)
    }

    $kinds = @(
        @{ Prop = 'ExclusionPath';      Kind = 'Path' },
        @{ Prop = 'ExclusionProcess';   Kind = 'Process' },
        @{ Prop = 'ExclusionExtension'; Kind = 'Extension' }
    )
    $snapProps = @($snap.PSObject.Properties.Name)
    $missing = @($kinds | Where-Object { $snapProps -notcontains $_.Prop })
    foreach ($k in $missing) {
        Write-Note ($k.Prop + ' not in snapshot, left as is.  /  快照里没有 ' + $k.Prop + ' 记录,该类排除项保持现状。')
    }

    Write-Host ''
    if (-not (Confirm-Yes '  Restore? [y/N]  /  确认还原?[y/N] ')) { return }

    $fail = 0
    foreach ($p in $snap.Prefs.PSObject.Properties) {
        if ($null -eq $p.Value) { continue }
        try {
            Set-DefenderPreference -Name $p.Name -Value $p.Value
            Write-Ok ($p.Name + ' restored  /  已还原')
        } catch {
            Write-Fail ($p.Name + ' restore failed  /  还原失败: ' + $_.Exception.Message)
            $fail++
        }
    }

    # Restore only the exclusion kinds the snapshot actually recorded.
    foreach ($k in $kinds) {
        if ($snapProps -contains $k.Prop) {
            Restore-ExclusionSet -Kind $k.Kind -Snapshot $snap.($k.Prop)
        }
    }

    Write-Host ''
    if ($fail -eq 0) {
        Write-Ok 'Restore complete.  /  还原完成。'
    } else {
        Write-Caution ('Restore finished with ' + $fail + ' failure(s).  /  还原完成,但有 ' + $fail + ' 项失败。')
    }
}

# ==================================================================
#  7) Drift monitor
# ==================================================================

function Get-MonitoredState {
    $pf = Get-MpPreference -ErrorAction Stop
    $r = [ordered]@{}
    $r['ScanAvgCPULoadFactor']    = [int]$pf.ScanAvgCPULoadFactor
    $r['EnableLowCpuPriority']    = [bool]$pf.EnableLowCpuPriority
    $r['ScanScheduleTime']        = if ($null -eq $pf.ScanScheduleTime) { '' } else { $pf.ScanScheduleTime.ToString('hh\:mm\:ss') }
    $r['ScanScheduleDay']         = [int]$pf.ScanScheduleDay
    $r['DisableCatchupQuickScan'] = [bool]$pf.DisableCatchupQuickScan
    $r['DisableCatchupFullScan']  = [bool]$pf.DisableCatchupFullScan
    $r['MAPSReporting']           = [int]$pf.MAPSReporting
    $r['SubmitSamplesConsent']    = [int]$pf.SubmitSamplesConsent
    $r['DisableBlockAtFirstSeen'] = [bool]$pf.DisableBlockAtFirstSeen
    return $r
}

# Records the expected state used as the drift baseline.
function Save-ExpectedState {
    param([switch]$Quiet)
    try {
        $state = Get-MonitoredState
        $o = [ordered]@{
            Version   = 1
            CreatedAt = (Get-Date).ToString('s')
            Machine   = $env:COMPUTERNAME
            Prefs     = $state
        }
        ($o | ConvertTo-Json -Depth 5) | Set-Content -LiteralPath $Script:ExpectedFile -Encoding UTF8
        if (-not $Quiet) {
            Write-Ok ('Expected state recorded:  /  期望值已记录: ' + $Script:ExpectedFile)
            Write-Note 'If any of these change later, the watch task will toast.  /  之后这些值一旦被改动,监控任务就会弹通知。'
        }
        return $true
    } catch {
        if (-not $Quiet) { Write-Fail ('record failed:  /  记录失败: ' + $_.Exception.Message) }
        return $false
    }
}

function Get-WatchTaskInfo {
    $t = Get-ScheduledTask -TaskName $Script:WatchTaskName -ErrorAction SilentlyContinue
    if ($null -eq $t) { return $null }
    $i = Get-ScheduledTaskInfo -TaskName $Script:WatchTaskName -ErrorAction SilentlyContinue
    return [pscustomobject]@{
        State  = [string]$t.State
        Last   = if ($i) { [string]$i.LastRunTime } else { 'unknown  /  未知' }
        Result = if ($i) { ('0x{0:X8}' -f [uint32]$i.LastTaskResult) } else { 'unknown  /  未知' }
        Next   = if ($i) { [string]$i.NextRunTime } else { 'unknown  /  未知' }
    }
}

# Runs the watch script; it compares, de-dupes, notifies and logs.
function Invoke-DriftCheck {
    param([switch]$TestToast)
    if (-not (Test-Path -LiteralPath $Script:WatchScript)) {
        Write-Fail ('watch script not found:  /  找不到监控脚本: ' + $Script:WatchScript)
        return $null
    }
    if ($TestToast) {
        & $Script:WatchScript -TestToast
        if ($LASTEXITCODE -eq 0) { Write-Ok 'Test toast sent - check the bottom-right corner.  /  测试通知已发送,请看屏幕右下角。' }
        else { Write-Fail 'Test toast failed; check that System.Windows.Forms is available.  /  测试通知发送失败,检查 System.Windows.Forms 是否可用。' }
        return $LASTEXITCODE
    }
    if (-not (Test-Path -LiteralPath $Script:ExpectedFile)) {
        Write-Caution 'No expected state recorded yet - nothing to compare.  /  还没有记录期望值,无法比较。'
        return $null
    }
    & $Script:WatchScript -DriftExitCode
    return $LASTEXITCODE
}

function Show-DriftNow {
    $code = Invoke-DriftCheck
    if ($null -eq $code) { return }
    switch ($code) {
        0 { Write-Ok 'Settings match the expected state.  /  设置与期望值一致。' }
        1 {
            Write-Caution 'Drift detected; notification sent.  /  检测到漂移,已发送通知。'
            $tail = Get-Content -LiteralPath $Script:DriftLog -Tail 1 -ErrorAction SilentlyContinue
            if ($tail) { Write-Host ('      ' + $tail) -ForegroundColor DarkYellow }
        }
        2 { Write-Caution 'Expected-state file missing or malformed.  /  期望值文件缺失或格式不对。' }
        default { Write-Fail ('check failed, exit code  /  检查失败,退出码 ' + $code) }
    }
}

function Install-WatchTask {
    if (-not (Test-Path -LiteralPath $Script:WatchScript)) {
        Write-Fail ('watch script not found:  /  找不到监控脚本: ' + $Script:WatchScript)
        return
    }
    $arg = '-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "' + $Script:WatchScript + '"'
    try {
        $act     = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $arg
        $tLogon  = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
        $tRepeat = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(3) `
                       -RepetitionInterval (New-TimeSpan -Hours 6)
        # Do NOT pass -RepetitionDuration ([TimeSpan]::MaxValue): it emits
        # P99999999DT..., above the Task Scheduler Duration limit, and the
        # registration fails. Omitting it means "repeat forever".
        # Must be Interactive - a toast only renders inside the user session.
        # SYSTEM or "run whether logged on" lands in Session 0 and stays invisible.
        $prn = New-ScheduledTaskPrincipal -UserId ("$env:USERDOMAIN\$env:USERNAME") -LogonType Interactive -RunLevel Limited
        $set = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
                   -StartWhenAvailable -MultipleInstances IgnoreNew `
                   -ExecutionTimeLimit (New-TimeSpan -Minutes 5) -Hidden

        Register-ScheduledTask -TaskName $Script:WatchTaskName -Action $act -Trigger @($tLogon, $tRepeat) `
            -Settings $set -Principal $prn `
            -Description 'DefenderTune drift monitor - toast when Defender settings change  /  DefenderTune 设置漂移监控:Defender 设置被改动时弹系统通知' `
            -Force -ErrorAction Stop | Out-Null

        Write-Ok ('Watch task installed:  /  监控任务已安装: ' + $Script:WatchTaskName)
        Write-Note 'Triggers: at logon + every 6h, running as the current user (required for toasts).  /  触发:登录时 + 每 6 小时。以当前用户身份运行(才弹得出通知)。'
        Write-Note 'The same drift toasts once per 12h, so no repeated nagging.  /  同一个漂移 12 小时内只提醒一次,不会反复骚扰。'
    } catch {
        Write-Fail ('install failed:  /  安装失败: ' + $_.Exception.Message)
    }
}

function Uninstall-WatchTask {
    $t = Get-ScheduledTask -TaskName $Script:WatchTaskName -ErrorAction SilentlyContinue
    if ($null -eq $t) { Write-Note 'The watch task is not installed.  /  监控任务本来就没安装。'; return }
    try {
        Unregister-ScheduledTask -TaskName $Script:WatchTaskName -Confirm:$false -ErrorAction Stop
        Write-Ok 'Watch task removed.  /  监控任务已卸载。'
    } catch {
        Write-Fail ('uninstall failed:  /  卸载失败: ' + $_.Exception.Message)
    }
}

function Show-MonitorMenu {
    while ($true) {
        Write-Head 'Drift monitor  /  设置漂移监控'
        $info = Get-WatchTaskInfo
        if ($null -eq $info) {
            Write-Host '  Watch task: not installed  /  自动监控任务: 未安装' -ForegroundColor DarkGray
        } else {
            Write-Host ('  Watch task:  /  自动监控任务: ' + $info.State) -ForegroundColor Green
            Write-Host ('      Last run:  /  上次运行: ' + $info.Last + '   Result:  /  结果: ' + $info.Result)
            Write-Host ('      Next run:  /  下次运行: ' + $info.Next)
        }
        if (Test-Path -LiteralPath $Script:ExpectedFile) {
            Write-Host '  Expected state: recorded  /  期望值基准: 已记录' -ForegroundColor Green
        } else {
            Write-Host '  Expected state: not recorded (monitoring is inert without it)  /  期望值基准: 未记录(没有它监控不会生效)' -ForegroundColor DarkYellow
        }

        Write-Host ''
        Write-Host '    1) Record current state as expected  /  把当前状态记为期望值'
        Write-Host '    2) Check now  /  立即校验一次'
        Write-Host '    3) Install watch task (at logon + every 6h)  /  安装自动监控任务(登录时 + 每 6 小时)'
        Write-Host '    4) Remove watch task  /  卸载自动监控任务'
        Write-Host '    5) Send a test notification  /  发送一条测试通知'
        Write-Host '    0) Back  /  返回'
        Write-Host ''

        $c = Read-Host '  Select  /  请选择'
        switch ($c) {
            '1' { [void](Save-ExpectedState); Pause-Ui }
            '2' { Show-DriftNow; Pause-Ui }
            '3' { Install-WatchTask; Pause-Ui }
            '4' { Uninstall-WatchTask; Pause-Ui }
            '5' { [void](Invoke-DriftCheck -TestToast); Pause-Ui }
            '0' { return }
        }
    }
}

# ==================================================================
#  Main menu
# ==================================================================

function Show-MainMenu {
    while ($true) {
        Write-Host ''
        Write-Host '  DefenderTune  --  Windows Defender performance tuner  /  性能调节工具' -ForegroundColor White
        Write-Host '  Cuts scan overhead only, never real-time protection. Everything is reversible.  /  只降低扫描干扰,不关闭实时防护。所有改动可还原。' -ForegroundColor DarkGray
        Write-Host ''
        Write-Host '    1) View current status  /  查看当前状态'
        Write-Host '    2) Apply low-impact preset (Tier A)  /  应用「低干扰」预设 (A 档)'
        Write-Host '    3) Exclusions (Tier B, biggest win)  /  排除项管理 (B 档,效果最大)'
        Write-Host '    4) Advanced settings (Tier C, weakens protection)  /  高级设置 (C 档,会降低防护)'
        Write-Host '    5) Save settings snapshot  /  保存当前设置快照'
        Write-Host '    6) Restore snapshot  /  一键还原到快照'
        Write-Host '    7) Drift monitor (toast when reverted)  /  设置漂移监控(被改回时弹通知)'
        Write-Host '    0) Exit  /  退出'
        Write-Host ''

        $c = Read-Host '  Select  /  请选择'
        switch ($c) {
            '1' { Show-Status; Pause-Ui }
            '2' { Invoke-LowImpactPreset; Pause-Ui }
            '3' { Show-ExclusionMenu }
            '4' { Show-AdvancedMenu }
            '5' { Save-Snapshot; Pause-Ui }
            '6' { Restore-Snapshot; Pause-Ui }
            '7' { Show-MonitorMenu }
            '0' { return }
        }
    }
}

# ==================================================================
#  Entry point
# ==================================================================

try {
    if (-not (Initialize-Admin)) { return }
    if (-not (Test-DefenderModule)) {
        Write-Fail 'Get-MpPreference not found. Is Microsoft Defender installed?  /  未找到 Get-MpPreference。请确认这台机器装了 Microsoft Defender。'
        Pause-Ui
        return
    }
    Show-MainMenu
} catch {
    Write-Host ''
    Write-Fail ('unhandled exception:  /  未处理异常: ' + $_.Exception.Message)
    Write-Host ($_.ScriptStackTrace) -ForegroundColor DarkGray
    Pause-Ui
}
