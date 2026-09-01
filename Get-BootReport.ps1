<#
.SYNOPSIS
    Generates an HTML report of Windows boot performance.
.DESCRIPTION
    Collects Last BIOS time (registry FwPOSTTime), overall startup time and
    per-phase boot durations (Diagnostics-Performance event 100, including the
    fine-grained v2 session/logon fields), boot degradation culprits (events
    101-110), and boot type (Kernel-Boot event 27 + User32 event 1074
    shutdown reason), then writes a
    self-contained HTML report to the Reports subfolder and opens it.
    Reading the Diagnostics-Performance log requires Administrator rights;
    the script self-elevates with a UAC prompt if needed.
#>

[CmdletBinding()]
param(
    [int]$HistoryCount = 20
)

# --- Self-elevate -----------------------------------------------------------
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
    ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Host "Not elevated - relaunching with administrator rights (UAC prompt)..."
    $exe = (Get-Process -Id $PID).Path
    Start-Process -FilePath $exe -Verb RunAs -ArgumentList @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"",
        '-HistoryCount', $HistoryCount
    )
    exit
}

$ErrorActionPreference = 'Stop'
$scriptDir = Split-Path -Parent $PSCommandPath

# --- Helpers ----------------------------------------------------------------
function Get-EventDataMap {
    param([System.Diagnostics.Eventing.Reader.EventRecord]$Event)
    $map = @{}
    foreach ($d in ([xml]$Event.ToXml()).Event.EventData.Data) {
        $map[$d.Name] = $d.'#text'
    }
    return $map
}

function Format-Sec {
    param($Ms)
    if ($null -eq $Ms -or $Ms -eq '') { return '&mdash;' }
    return ('{0:N1}s' -f ([double]$Ms / 1000))
}

function ConvertTo-SafeHtml {
    param($Text)
    if ($null -eq $Text) { return '' }
    return [System.Net.WebUtility]::HtmlEncode([string]$Text)
}

# --- Collect: Last BIOS time (current boot only) -----------------------------
$fwPostMs = $null
try {
    $fwPostMs = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power').FwPOSTTime
} catch {}

# --- Collect: boot performance events (ID 100) -------------------------------
function Get-BootPerfEvents {
    try {
        return @(Get-WinEvent -FilterHashtable @{
            LogName = 'Microsoft-Windows-Diagnostics-Performance/Operational'; Id = 100
        } -MaxEvents $HistoryCount -ErrorAction Stop)
    } catch { return @() }
}

Write-Host "Reading boot performance events..."
$osBootTime = (Get-CimInstance Win32_OperatingSystem).LastBootUpTime
$bootEvents = Get-BootPerfEvents
$perfLogNotice = $null

function Test-HasCurrentBoot {
    param($Events)
    foreach ($ev in $Events) {
        # Event 100's BootStartTime matches the OS boot; allow 2 min tolerance.
        $d = Get-EventDataMap $ev
        $start = [datetime]::Parse($d['BootStartTime'], $null, [System.Globalization.DateTimeStyles]::RoundtripKind).ToLocalTime()
        if ([math]::Abs(($start - $osBootTime).TotalMinutes) -le 2) { return $true }
    }
    return $false
}

# Windows writes event 100 only after post-boot activity settles, which can be
# minutes after logon. If we're early in the current boot, wait for it.
$uptimeMin = ((Get-Date) - $osBootTime).TotalMinutes
if (-not (Test-HasCurrentBoot $bootEvents) -and $uptimeMin -lt 15) {
    Write-Host "Current boot not yet logged (uptime $([math]::Round($uptimeMin,1)) min); waiting for event 100..."
    $deadline = (Get-Date).AddMinutes(5)
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 15
        $bootEvents = Get-BootPerfEvents
        if (Test-HasCurrentBoot $bootEvents) {
            Write-Host "Current boot event found."
            break
        }
    }
    if (-not (Test-HasCurrentBoot $bootEvents)) {
        $perfLogNotice = "The performance event for the current boot had not been written yet " +
            "(waited 5 minutes). The 'Latest Boot' section below shows the previous boot."
    }
}

# Event 100 is produced by WDI analysing the ReadyBoot ETW trace. That trace is
# captured by the ReadyBoot autologger and finalised by SysMain, so if either is
# disabled the log stays empty forever - a very different problem from "the log
# was just cleared". Check both so the report says which one it is.
function Test-BootTracingEnabled {
    $reasons = @()

    try {
        $sysMain = Get-Service SysMain -ErrorAction Stop
        if ($sysMain.StartType -eq 'Disabled') {
            $reasons += "the SysMain service is disabled"
        } elseif ($sysMain.Status -ne 'Running') {
            $reasons += "the SysMain service is not running (status: $($sysMain.Status))"
        }
    } catch {
        $reasons += "the SysMain service could not be queried"
    }

    try {
        $rb = Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\WMI\Autologger\ReadyBoot' -ErrorAction Stop
        if ($rb.Start -ne 1) { $reasons += "the ReadyBoot autologger is disabled (Start=$($rb.Start))" }
    } catch {
        $reasons += "the ReadyBoot autologger registry key could not be read"
    }

    return , $reasons
}

if ($bootEvents.Count -eq 0) {
    $tracingReasons = Test-BootTracingEnabled
    if ($tracingReasons.Count -gt 0) {
        $perfLogNotice = "Boot tracing is switched off, so Windows is not generating boot " +
            "performance events (ID 100) at all: " + ($tracingReasons -join "; ") + ". " +
            "Re-enable with 'Set-Service SysMain -StartupType Automatic; Start-Service SysMain' and " +
            "set HKLM\SYSTEM\CurrentControlSet\Control\WMI\Autologger\ReadyBoot\Start to 1, then " +
            "reboot. Report is limited to registry and System-log data until then."
    } else {
        $perfLogNotice = "No boot performance events (ID 100) could be read from the " +
            "Microsoft-Windows-Diagnostics-Performance/Operational log. Boot tracing looks " +
            "enabled, so the log has most likely just been cleared - data will reappear after " +
            "the next boot. Report is limited to registry and System-log data."
    }
}

# --- Collect: boot type (ID 27) and shutdown reason (ID 1074) ----------------
Write-Host "Reading boot type and shutdown events..."
$kernelBoots = @()
try {
    $kernelBoots = @(Get-WinEvent -FilterHashtable @{
        LogName = 'System'; ProviderName = 'Microsoft-Windows-Kernel-Boot'; Id = 27
    } -MaxEvents ($HistoryCount * 3) -ErrorAction Stop | ForEach-Object {
        [pscustomobject]@{
            Time     = $_.TimeCreated
            BootType = [int](Get-EventDataMap $_)['BootType']
        }
    })
} catch {}

$shutdowns = @()
try {
    $shutdowns = @(Get-WinEvent -FilterHashtable @{
        LogName = 'System'; ProviderName = 'User32'; Id = 1074
    } -MaxEvents ($HistoryCount * 3) -ErrorAction SilentlyContinue | ForEach-Object {
        # Property index 4 (param5) is the shutdown type: "restart", "power off", ...
        [pscustomobject]@{
            Time = $_.TimeCreated
            Type = [string]$_.Properties[4].Value
        }
    })
} catch {}

# --- Collect: boot degradation events (ID 101-110) ---------------------------
# Windows logs these alongside event 100 when something slowed the boot down.
# All carry StartTime (= the boot's BootStartTime), TotalTime and DegradationTime.
$degTypeLabels = @{
    101 = 'Application'; 102 = 'Driver'; 103 = 'Service'; 110 = 'Boot phase'
}
$degEvents = @()
try {
    $degEvents = @(Get-WinEvent -FilterHashtable @{
        LogName = 'Microsoft-Windows-Diagnostics-Performance/Operational'; Id = @(101..110)
    } -MaxEvents ($HistoryCount * 10) -ErrorAction Stop | ForEach-Object {
        $d = Get-EventDataMap $_
        [pscustomobject]@{
            Id            = $_.Id
            TypeLabel     = if ($degTypeLabels.ContainsKey($_.Id)) { $degTypeLabels[$_.Id] } else { "Other (event $($_.Id))" }
            BootStart     = [datetime]::Parse($d['StartTime'], $null, [System.Globalization.DateTimeStyles]::RoundtripKind).ToLocalTime()
            Name          = $d['Name']
            FriendlyName  = $d['FriendlyName']
            Path          = $d['Path']
            TotalMs       = if ($d['TotalTime']) { [double]$d['TotalTime'] } else { $null }
            DegradationMs = if ($d['DegradationTime']) { [double]$d['DegradationTime'] } else { $null }
        }
    })
} catch {}

function Get-BootTypeLabel {
    param([datetime]$BootStart)
    # Kernel-Boot 27 fires at boot; find the record closest to boot start (within 10 min).
    $kb = $kernelBoots | Where-Object { [math]::Abs(($_.Time - $BootStart).TotalMinutes) -le 10 } |
        Sort-Object { [math]::Abs(($_.Time - $BootStart).TotalTicks) } | Select-Object -First 1
    if ($kb) {
        switch ($kb.BootType) {
            1 { return 'Fast startup (hybrid)' }
            2 { return 'Resume from hibernation' }
        }
    }
    # Full boot (type 0 or no event): classify by the preceding shutdown event.
    $sd = $shutdowns | Where-Object { $_.Time -lt $BootStart } |
        Sort-Object Time -Descending | Select-Object -First 1
    if ($sd -and ($BootStart - $sd.Time).TotalDays -le 30) {
        if ($sd.Type -match 'restart')   { return 'Restart' }
        if ($sd.Type -match 'power off') { return 'Cold power-up' }
    }
    if ($kb) { return 'Full boot (unknown trigger)' }
    return 'Unknown'
}

# --- Parse boot records -------------------------------------------------------
$phaseDefs = [ordered]@{
    BootKernelInitTime               = 'Kernel initialization'
    BootDriverInitTime               = 'Driver initialization'
    BootDevicesInitTime              = 'Device initialization'
    BootPrefetchInitTime             = 'Prefetch initialization'
    BootSmssInitTime                 = 'Session manager (Smss) init (Login appears at phase end)'
    BootCriticalServicesInitTime     = 'Critical services init'
    BootMachineProfileProcessingTime = 'Machine profile processing'
    BootUserProfileProcessingTime    = 'User profile processing'
    BootExplorerInitTime             = 'Explorer initialization (Desktop icons appear at phase end)'
    BootPostBootTime                 = 'Post-boot (background activity)'
}

# Fine-grained main-path timeline (event 100 version 2 fields).
$detailDefs = [ordered]@{
    OSLoaderDuration               = 'OS loader'
    BootPNPInitDuration            = 'Plug and Play init (boot devices)'
    OtherKernelInitDuration        = 'Other kernel init'
    SystemPNPInitDuration          = 'Plug and Play init (system devices)'
    Session0InitDuration           = 'Session 0 init (services)'
    Session1InitDuration           = 'Session 1 init (user session)'
    SessionInitOtherDuration       = 'Session init &mdash; other'
    OtherLogonInitActivityDuration = 'Other logon activity'
    UserLogonWaitDuration          = 'User logon wait'
}

$boots = @(foreach ($ev in $bootEvents) {
    $d = Get-EventDataMap $ev
    $start = [datetime]::Parse($d['BootStartTime'], $null, [System.Globalization.DateTimeStyles]::RoundtripKind).ToLocalTime()
    [pscustomobject]@{
        Start        = $start
        BootTimeMs   = [double]$d['BootTime']
        MainPathMs   = [double]$d['MainPathBootTime']
        PostBootMs   = [double]$d['BootPostBootTime']
        StartupApps  = $d['BootNumStartupApps']
        Degradation  = $ev.LevelDisplayName
        TypeLabel    = Get-BootTypeLabel $start
        Data         = $d
    }
}) | Sort-Object Start -Descending

# --- Build HTML ---------------------------------------------------------------
Write-Host "Building report..."
$genTime = Get-Date
$pc = $env:COMPUTERNAME
$html = [System.Text.StringBuilder]::new()

[void]$html.AppendLine(@"
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>Boot Report - $pc - $($genTime.ToString('yyyy-MM-dd HH:mm'))</title>
<style>
  body { font-family: 'Segoe UI', sans-serif; margin: 0; background: #f4f6f8; color: #222; }
  .wrap { max-width: 960px; margin: 0 auto; padding: 24px; }
  h1 { font-size: 1.5em; margin-bottom: 4px; }
  h2 { font-size: 1.15em; margin-top: 32px; border-bottom: 2px solid #d0d7de; padding-bottom: 6px; }
  .sub { color: #666; margin-top: 0; }
  .cards { display: flex; flex-wrap: wrap; gap: 12px; margin: 16px 0; }
  .card { background: #fff; border: 1px solid #d0d7de; border-radius: 8px; padding: 14px 18px; min-width: 150px; flex: 1; }
  .card .label { font-size: 0.78em; text-transform: uppercase; letter-spacing: 0.05em; color: #667; }
  .card .value { font-size: 1.6em; font-weight: 600; margin-top: 2px; }
  .card .note { font-size: 0.75em; color: #889; }
  .badge { display: inline-block; padding: 3px 10px; border-radius: 12px; font-size: 0.85em; font-weight: 600; background: #dbeafe; color: #1d4ed8; }
  table { border-collapse: collapse; width: 100%; background: #fff; border: 1px solid #d0d7de; border-radius: 8px; overflow: hidden; }
  th, td { text-align: center; padding: 8px 12px; border-bottom: 1px solid #e5e9ee; font-size: 0.9em; }
  th { background: #eef1f4; font-weight: 600; }
  tr:last-child td { border-bottom: none; }
  th.num, td.num { font-variant-numeric: tabular-nums; }
  .bar-cell { width: 45%; }
  .bar { height: 14px; background: #3b82f6; border-radius: 3px; min-width: 2px; }
  .bar.post { background: #94a3b8; }
  .fastest { background: #d1fae5; }
  .fastest td:first-child { border-left: 4px solid #10b981; }
  .slowest { background: #fecaca; }
  .slowest td:first-child { border-left: 4px solid #ef4444; }
  .notice { background: #fffbeb; border: 1px solid #f5d97a; border-radius: 8px; padding: 12px 16px; margin: 16px 0; font-size: 0.9em; }
  .legend { font-size: 0.8em; color: #667; margin-top: 6px; }
</style>
</head>
<body>
<div class="wrap">
<h1>Windows Boot Report &mdash; $pc</h1>
<p class="sub">Generated $($genTime.ToString('dddd, dd MMMM yyyy HH:mm:ss'))</p>
"@)

if ($perfLogNotice) {
    [void]$html.AppendLine("<div class='notice'>$perfLogNotice</div>")
}

# --- Latest boot section ---
$latest = $boots | Select-Object -First 1
if ($latest) {
    $latestIsCurrent = [math]::Abs(($latest.Start - $osBootTime).TotalMinutes) -le 2
    $biosNote = if ($fwPostMs -and $latestIsCurrent) { Format-Sec $fwPostMs } else { '&mdash;' }
    [void]$html.AppendLine(@"
<h2>Latest Boot &mdash; $($latest.Start.ToString('dddd, dd MMMM yyyy HH:mm:ss')) <span class="badge">$($latest.TypeLabel)</span></h2>
<div class="cards">
  <div class="card"><div class="label">Last BIOS time</div><div class="value">$biosNote</div><div class="note">Firmware POST (as in Task Manager)</div></div>
  <div class="card"><div class="label">Overall startup time</div><div class="value">$(Format-Sec $latest.BootTimeMs)</div><div class="note">Windows total (event 100 BootTime)</div></div>
  <div class="card"><div class="label">Main boot path</div><div class="value">$(Format-Sec $latest.MainPathMs)</div><div class="note">To usable desktop</div></div>
  <div class="card"><div class="label">Post-boot activity</div><div class="value">$(Format-Sec $latest.PostBootMs)</div><div class="note">Background settle time</div></div>
  <div class="card"><div class="label">Startup apps</div><div class="value">$($latest.StartupApps)</div><div class="note">Counted at boot</div></div>
</div>

<h2>Phase Breakdown (latest boot)</h2>
<table>
<tr><th>Phase</th><th class="num">Duration</th><th class="bar-cell">Relative</th></tr>
"@)
    $phaseVals = @{}
    $maxMs = 1
    foreach ($k in $phaseDefs.Keys) {
        $v = $latest.Data[$k]
        if ($null -ne $v -and $v -ne '') {
            $phaseVals[$k] = [double]$v
            if ([double]$v -gt $maxMs) { $maxMs = [double]$v }
        }
    }
    foreach ($k in $phaseDefs.Keys) {
        if (-not $phaseVals.ContainsKey($k)) { continue }
        $ms = $phaseVals[$k]
        $pct = [math]::Round($ms / $maxMs * 100, 1)
        $cls = if ($k -eq 'BootPostBootTime') { 'bar post' } else { 'bar' }
        [void]$html.AppendLine("<tr><td>$($phaseDefs[$k])</td><td class='num' title='$ms ms'>$(Format-Sec $ms)</td><td class='bar-cell'><div class='$cls' style='width:${pct}%'></div></td></tr>")
    }
    [void]$html.AppendLine("</table><p class='legend'>Blue = main boot path phases; grey = post-boot background activity. Hover a duration for raw milliseconds.</p>")

    # --- Fine-grained timeline (event 100 v2 fields) ---
    $detailVals = @{}
    $detailMax = 1
    foreach ($k in $detailDefs.Keys) {
        $v = $latest.Data[$k]
        if ($null -ne $v -and $v -ne '') {
            $detailVals[$k] = [double]$v
            if ([double]$v -gt $detailMax) { $detailMax = [double]$v }
        }
    }
    if ($detailVals.Count -gt 0) {
        [void]$html.AppendLine(@"
<h2>Main Path Detail (latest boot)</h2>
<table>
<tr><th>Stage</th><th class="num">Duration</th><th class="bar-cell">Relative</th></tr>
"@)
        foreach ($k in $detailDefs.Keys) {
            if (-not $detailVals.ContainsKey($k)) { continue }
            $ms = $detailVals[$k]
            $pct = [math]::Round($ms / $detailMax * 100, 1)
            [void]$html.AppendLine("<tr><td>$($detailDefs[$k])</td><td class='num' title='$ms ms'>$(Format-Sec $ms)</td><td class='bar-cell'><div class='bar' style='width:${pct}%'></div></td></tr>")
        }
        [void]$html.AppendLine("</table><p class='legend'>Fine-grained stages within the main boot path. 'Session init &mdash; other' is time inside session manager init not attributed to session 0/1 &mdash; typically where large Smss delays hide.</p>")
    }

    # --- Slow boot culprits (events 101-110) ---
    $latestDeg = @($degEvents | Where-Object { [math]::Abs(($_.BootStart - $latest.Start).TotalMinutes) -le 2 } |
        Sort-Object DegradationMs -Descending)
    [void]$html.AppendLine("<h2>Slow Boot Culprits (latest boot)</h2>")
    if ($latestDeg.Count -gt 0) {
        [void]$html.AppendLine(@"
<table>
<tr><th>Type</th><th>Name</th><th class="num">Total time</th><th class="num">Slower than usual by</th></tr>
"@)
        foreach ($de in $latestDeg) {
            $dispName = if ($de.FriendlyName) { "$(ConvertTo-SafeHtml $de.FriendlyName) ($(ConvertTo-SafeHtml $de.Name))" } else { ConvertTo-SafeHtml $de.Name }
            $tip = if ($de.Path) { " title='$(ConvertTo-SafeHtml $de.Path)'" } else { '' }
            [void]$html.AppendLine("<tr><td>$($de.TypeLabel)</td><td$tip>$dispName</td><td class='num' title='$($de.TotalMs) ms'>$(Format-Sec $de.TotalMs)</td><td class='num' title='$($de.DegradationMs) ms'>$(Format-Sec $de.DegradationMs)</td></tr>")
        }
        [void]$html.AppendLine("</table><p class='legend'>Items Windows flagged (events 101&ndash;110) as taking longer than their historical baseline this boot. Hover a name for its file path.</p>")
    } else {
        [void]$html.AppendLine("<p class='legend'>Windows flagged nothing as degrading this boot (no events 101&ndash;110 recorded for it).</p>")
    }
}

# --- History section ---
# $boots is sorted most-recent-first, so the first 10 are the last 10 startups.
$historyBoots = @($boots | Select-Object -First 10)
if ($historyBoots.Count -gt 1) {
    $fastest = ($historyBoots | Sort-Object BootTimeMs | Select-Object -First 1).Start
    $slowest = ($historyBoots | Sort-Object BootTimeMs -Descending | Select-Object -First 1).Start
    [void]$html.AppendLine(@"
<h2>Boot History (last $($historyBoots.Count) boots)</h2>
<table>
<tr><th>Boot time</th><th>Boot type</th><th class="num">Total</th><th class="num">Main path</th><th class="num">Post-boot</th><th class="num">BIOS time</th></tr>
"@)
    foreach ($b in $historyBoots) {
        $rowCls = if ($b.Start -eq $fastest) { " class='fastest'" } elseif ($b.Start -eq $slowest) { " class='slowest'" } else { '' }
        $isCurrent = [math]::Abs(($b.Start - $osBootTime).TotalMinutes) -le 2
        $bios = if ($isCurrent -and $fwPostMs) { Format-Sec $fwPostMs } else { '&mdash;' }
        [void]$html.AppendLine("<tr$rowCls><td>$($b.Start.ToString('yyyy-MM-dd HH:mm:ss'))</td><td>$($b.TypeLabel)</td><td class='num' title='$($b.BootTimeMs) ms'>$(Format-Sec $b.BootTimeMs)</td><td class='num'>$(Format-Sec $b.MainPathMs)</td><td class='num'>$(Format-Sec $b.PostBootMs)</td><td class='num'>$bios</td></tr>")
    }
    [void]$html.AppendLine("</table><p class='legend'>Green row = fastest boot; red row = slowest. BIOS time is only recorded for the current boot (Windows keeps no POST history).</p>")
}

# --- Fallback if no event 100 data at all ---
if (-not $latest) {
    $lastKb = $kernelBoots | Sort-Object Time -Descending | Select-Object -First 1
    $typeLabel = if ($lastKb) { Get-BootTypeLabel $lastKb.Time } else { 'Unknown' }
    $biosNote = if ($fwPostMs) { Format-Sec $fwPostMs } else { '&mdash;' }
    [void]$html.AppendLine(@"
<h2>Latest Boot (limited data)</h2>
<div class="cards">
  <div class="card"><div class="label">Last BIOS time</div><div class="value">$biosNote</div><div class="note">Firmware POST (as in Task Manager)</div></div>
  <div class="card"><div class="label">Boot type</div><div class="value">$typeLabel</div><div class="note">From Kernel-Boot event 27</div></div>
</div>
"@)
}

[void]$html.AppendLine("</div></body></html>")

# --- Save & open --------------------------------------------------------------
$reportDir = Join-Path $scriptDir 'Reports'
if (-not (Test-Path $reportDir)) { New-Item -ItemType Directory -Path $reportDir | Out-Null }
$reportPath = Join-Path $reportDir ("BootReport_{0}.html" -f $genTime.ToString('yyyy-MM-dd_HHmmss'))
$html.ToString() | Set-Content -Path $reportPath -Encoding UTF8

Write-Host "Report saved: $reportPath"
Invoke-Item $reportPath
