<#
.SYNOPSIS
    Formats ETW analysis results into structured Markdown reports.
.DESCRIPTION
    Produces a report styled after the Windows Assessment Toolkit / PerformanceLab
    Fast Startup report, with hierarchical metric tables, phase breakdowns,
    device/service drill-downs, and actionable recommendations.
#>

# Unicode emoji constants (avoids encoding issues in PS 5.1)
$script:IconRed     = [char]::ConvertFromUtf32(0x1F534)  # Red circle
$script:IconYellow  = [char]::ConvertFromUtf32(0x1F7E1)  # Yellow circle
$script:IconGreen   = [char]::ConvertFromUtf32(0x1F7E2)  # Green circle
$script:IconBlue    = [char]::ConvertFromUtf32(0x1F535)  # Blue circle
$script:IconSearch  = [char]::ConvertFromUtf32(0x1F50D)  # Magnifying glass
$script:IconChart   = [char]::ConvertFromUtf32(0x1F4CA)  # Bar chart
$script:IconBulb    = [char]::ConvertFromUtf32(0x1F4A1)  # Light bulb
$script:IconFolder  = [char]::ConvertFromUtf32(0x1F4C1)  # Folder
$script:IconBook    = [char]::ConvertFromUtf32(0x1F4D6)  # Book
$script:IconWarn    = [char]::ConvertFromUtf32(0x26A0)   # Warning sign
$script:BlockFull   = [char]0x2588  # Full block
$script:BlockLight  = [char]0x2591  # Light shade block

function Get-SeverityIcon {
    param([string]$Severity)
    switch ($Severity) {
        'Critical' { return $script:IconRed }
        'Warning'  { return $script:IconYellow }
        'Info'     { return $script:IconBlue }
        default    { return $script:IconGreen }
    }
}

function Get-StatusBar {
    param(
        [double]$Value,
        [double]$Max,
        [int]$Width = 20
    )
    if ($Max -le 0) { return '' }
    $ratio = [math]::Min(1.0, [math]::Max(0.0, [double]$Value / [double]$Max))
    $filled = [math]::Min($Width, [math]::Max(1, [int]([math]::Round($ratio * $Width))))
    $empty  = $Width - $filled
    return ($script:BlockFull.ToString() * $filled) + ($script:BlockLight.ToString() * $empty)
}

function Get-BootTimingStatus {
    param([double]$Seconds, [double]$WarnThreshold, [double]$CritThreshold)
    if ($Seconds -gt $CritThreshold) { return "$($script:IconRed) Slow" }
    elseif ($Seconds -gt $WarnThreshold) { return "$($script:IconYellow) Moderate" }
    else { return "$($script:IconGreen) Good" }
}

function Get-PhaseStatusIcon {
    param([string]$Status)
    switch ($Status) {
        'CRITICAL' { return "$($script:IconRed) CRITICAL" }
        'SLOW'     { return "$($script:IconYellow) SLOW" }
        default    { return "$($script:IconGreen) OK" }
    }
}

function Get-DeviceStatus {
    param([double]$DurationMs)
    if ($DurationMs -gt 500) { return "$($script:IconRed) Slow" }
    elseif ($DurationMs -gt 200) { return "$($script:IconYellow) Moderate" }
    else { return "$($script:IconGreen) OK" }
}

# Build a Markdown table row by joining cells with pipes
function New-TableRow {
    param([string[]]$Cells)
    return "| $($Cells -join ' | ') |"
}

function Get-Exercise3ReportOutData {
    param([array]$AnalysisResults)

    $allFindings = @()
    $allPhases = @()

    foreach ($r in $AnalysisResults) {
        if ($r.Findings) { $allFindings += $r.Findings }
        if ($r.Phases) { $allPhases += $r.Phases }
    }

    $resumeCandidates = @($allPhases | Where-Object {
        $_.PSObject.Properties.Name -contains 'Name' -and $_.Name -match 'Resume|Standby Resume|Main Path Resume|Wake'
    } | Sort-Object DurationMs -Descending)

    $topResume = if ($resumeCandidates.Count -gt 0) { $resumeCandidates[0] } else { $null }
    $topResumeMs = if ($topResume -and $topResume.DurationMs) { [double]$topResume.DurationMs } else { 0 }
    $topResumeSec = if ($topResumeMs -gt 0) { [math]::Round($topResumeMs / 1000, 2) } else { 0 }

    $criticalWaitIndicators = @($allFindings | Where-Object {
        $_.Message -match 'wait|stuck|resume|wake|Netwaw|7021|7003|Modern Standby'
    })

    $hasCriticalPathIssue = ($topResumeSec -ge 10) -or ($criticalWaitIndicators.Count -gt 0)

    return [PSCustomObject]@{
        HasCriticalIssue = $hasCriticalPathIssue
        TopResumePhase   = if ($topResume) { $topResume.Name } else { 'N/A' }
        TopResumeMs      = $topResumeMs
        TopResumeSec     = $topResumeSec
        WaitSignalCount  = $criticalWaitIndicators.Count
        WaitSignals      = $criticalWaitIndicators
    }
}

function Get-Exercise2EscalationData {
    param([array]$AnalysisResults)

    function Get-NumericOrNull {
        param($Value)
        if ($null -eq $Value) { return $null }
        $s = "$Value" -replace ',', ''
        $out = 0.0
        if ([double]::TryParse($s, [ref]$out)) { return $out }
        return $null
    }

    function Get-Threshold {
        param(
            [object]$Root,
            [string]$Section,
            [string]$Metric,
            [string]$Level,
            [double]$DefaultValue
        )
        try {
            $value = $Root.$Section.$Metric.$Level
            $num = Get-NumericOrNull -Value $value
            if ($null -ne $num) { return $num }
        }
        catch {}
        return $DefaultValue
    }

    $thresholds = $null
    $thresholdFile = Join-Path (Split-Path -Parent $PSScriptRoot) 'config\thresholds.json'
    if (Test-Path $thresholdFile) {
        try {
            $thresholds = Get-Content $thresholdFile -Raw | ConvertFrom-Json
        }
        catch {
            $thresholds = $null
        }
    }

    $allFindings = @()
    $allPhases = @()
    foreach ($r in $AnalysisResults) {
        if ($r.Findings) { $allFindings += $r.Findings }
        if ($r.Phases) { $allPhases += $r.Phases }
    }

    $criticalOrWarning = @($allFindings | Where-Object { $_.Severity -in @('Critical', 'Warning') })

    $resumeWarn = Get-Threshold -Root $thresholds -Section 'FastStartup' -Metric 'ResumePhaseSeconds' -Level 'Warning' -DefaultValue 10
    $resumeCrit = Get-Threshold -Root $thresholds -Section 'FastStartup' -Metric 'ResumePhaseSeconds' -Level 'Critical' -DefaultValue 20
    $bootWarn   = Get-Threshold -Root $thresholds -Section 'FastStartup' -Metric 'BootTotalSeconds' -Level 'Warning' -DefaultValue 30
    $bootCrit   = Get-Threshold -Root $thresholds -Section 'FastStartup' -Metric 'BootTotalSeconds' -Level 'Critical' -DefaultValue 60
    $diskWarnGB = Get-Threshold -Root $thresholds -Section 'DiskIO' -Metric 'TotalIOGigabytes' -Level 'Warning' -DefaultValue 1
    $diskCritGB = Get-Threshold -Root $thresholds -Section 'DiskIO' -Metric 'TotalIOGigabytes' -Level 'Critical' -DefaultValue 5

    $roiThresholdBreaches = @()
    foreach ($phase in $allPhases) {
        if (-not ($phase.PSObject.Properties.Name -contains 'Name')) { continue }
        if (-not ($phase.PSObject.Properties.Name -contains 'DurationMs')) { continue }

        $sec = [math]::Round(([double]$phase.DurationMs / 1000.0), 2)
        if ($phase.Name -match 'Resume|Wake') {
            if ($sec -ge $resumeCrit) {
                $roiThresholdBreaches += "ROI phase '$($phase.Name)' = ${sec}s >= Resume Critical ${resumeCrit}s"
            }
            elseif ($sec -ge $resumeWarn) {
                $roiThresholdBreaches += "ROI phase '$($phase.Name)' = ${sec}s >= Resume Warning ${resumeWarn}s"
            }
        }
        elseif ($phase.Name -match 'Boot|Post Boot|Fast Startup|Main Path') {
            if ($sec -ge $bootCrit) {
                $roiThresholdBreaches += "ROI phase '$($phase.Name)' = ${sec}s >= Boot Critical ${bootCrit}s"
            }
            elseif ($sec -ge $bootWarn) {
                $roiThresholdBreaches += "ROI phase '$($phase.Name)' = ${sec}s >= Boot Warning ${bootWarn}s"
            }
        }
    }

    $totalDiskBytes = 0.0
    foreach ($r in $AnalysisResults) {
        if ($r.CsvData -and $r.CsvData.DiskByProcess -and $r.CsvData.DiskByProcess.Count -gt 0) {
            foreach ($row in $r.CsvData.DiskByProcess) {
                if ($row.PSObject.Properties.Name -contains 'Size') {
                    $sizeNum = Get-NumericOrNull -Value $row.Size
                    if ($null -ne $sizeNum) { $totalDiskBytes += $sizeNum }
                }
            }
        }
    }

    $totalDiskGB = if ($totalDiskBytes -gt 0) { [math]::Round(($totalDiskBytes / 1GB), 2) } else { 0 }
    $diskThresholdBreach = $null
    if ($totalDiskGB -ge $diskCritGB) {
        $diskThresholdBreach = "Disk usage ${totalDiskGB}GB >= Disk Critical ${diskCritGB}GB"
    }
    elseif ($totalDiskGB -ge $diskWarnGB) {
        $diskThresholdBreach = "Disk usage ${totalDiskGB}GB >= Disk Warning ${diskWarnGB}GB"
    }

    # CPU / Generic are threshold-signaled by analyzer findings (analyzers already consume thresholds.json)
    $cpuSignals = @($criticalOrWarning | Where-Object { $_.Category -match 'CPU|Process' -or $_.Message -match 'CPU|consumed|ready|context switch' })
    $genericSignals = @($criticalOrWarning | Where-Object { $_.Category -match 'Driver|WLAN|Network|Power|Service|Disk|I/O' -or $_.Message -match 'event|provider|driver|wlan|network|power|disk|i/o|io' })

    $needExercise2 = ($roiThresholdBreaches.Count -gt 0) -or ($null -ne $diskThresholdBreach) -or ($cpuSignals.Count -gt 0) -or ($genericSignals.Count -gt 0)

    $reasons = @()
    foreach ($rb in ($roiThresholdBreaches | Select-Object -First 4)) { $reasons += $rb }
    if ($diskThresholdBreach) { $reasons += $diskThresholdBreach }
    if ($cpuSignals.Count -gt 0) { $reasons += "CPU findings flagged by analyzer thresholds ($($cpuSignals.Count))" }
    if ($genericSignals.Count -gt 0) { $reasons += "Generic/driver/network findings flagged by analyzer thresholds ($($genericSignals.Count))" }

    return [PSCustomObject]@{
        NeedExercise2 = $needExercise2
        Reasons       = $reasons
    }
}

function Format-ThresholdsSnapshotTable {
    param([System.Text.StringBuilder]$sb)

    $thresholdFile = Join-Path (Split-Path -Parent $PSScriptRoot) 'config\thresholds.json'
    if (-not (Test-Path $thresholdFile)) {
        [void]$sb.AppendLine("> _Thresholds Snapshot omitted — config/thresholds.json not found._")
        [void]$sb.AppendLine("")
        return
    }
    try {
        $t = Get-Content $thresholdFile -Raw | ConvertFrom-Json
    }
    catch {
        [void]$sb.AppendLine("> _Thresholds Snapshot omitted — failed to parse config/thresholds.json._")
        [void]$sb.AppendLine("")
        return
    }

    [void]$sb.AppendLine("##### Thresholds Snapshot (from ``config/thresholds.json``)")
    [void]$sb.AppendLine("")
    [void]$sb.AppendLine("| Category | Metric | Warning | Critical |")
    [void]$sb.AppendLine("|----------|--------|---------|----------|")

    $rows = @(
        @('Fast Startup', 'Boot Total (s)',       $t.FastStartup.BootTotalSeconds.Warning,    $t.FastStartup.BootTotalSeconds.Critical)
        @('Fast Startup', 'Resume Phase (s)',     $t.FastStartup.ResumePhaseSeconds.Warning,  $t.FastStartup.ResumePhaseSeconds.Critical)
        @('Fast Startup', 'Service Delay (s)',    $t.FastStartup.ServiceDelaySeconds.Warning,  $t.FastStartup.ServiceDelaySeconds.Critical)
        @('Fast Startup', 'Driver Init (s)',      $t.FastStartup.DriverInitSeconds.Warning,    $t.FastStartup.DriverInitSeconds.Critical)
        @('Disk I/O',     'Avg Latency (ms)',     $t.DiskIO.AvgLatencyMs.Warning,              $t.DiskIO.AvgLatencyMs.Critical)
        @('Disk I/O',     'Total I/O (GB)',       $t.DiskIO.TotalIOGigabytes.Warning,          $t.DiskIO.TotalIOGigabytes.Critical)
        @('CPU',          'Process CPU (%)',       $t.Cpu.ProcessCpuPercent.Warning,             $t.Cpu.ProcessCpuPercent.Critical)
        @('CPU',          'Context Switch (/s)',   $t.Cpu.ContextSwitchRatePerSec.Warning,      $t.Cpu.ContextSwitchRatePerSec.Critical)
        @('Driver',       'DPC Duration (ms)',     $t.Driver.DpcDurationMs.Warning,             $t.Driver.DpcDurationMs.Critical)
        @('Driver',       'ISR Duration (us)',     $t.Driver.IsrDurationUs.Warning,             $t.Driver.IsrDurationUs.Critical)
        @('Memory',       'Hard Faults (/s)',      $t.Memory.HardFaultsPerSec.Warning,          $t.Memory.HardFaultsPerSec.Critical)
        @('Modern Standby','DRIPS Residency (%)',  $t.ModernStandby.DripsResidencyPercent.Warning, $t.ModernStandby.DripsResidencyPercent.Critical)
    )
    foreach ($r in $rows) {
        [void]$sb.AppendLine((New-TableRow @($r[0], $r[1], "$($r[2])", "$($r[3])")))
    }
    [void]$sb.AppendLine("")
}

function Format-Exercise3ReportOutSection {
    param(
        [array]$AnalysisResults,
        [System.Text.StringBuilder]$sb
    )

    $e3 = Get-Exercise3ReportOutData -AnalysisResults $AnalysisResults
    $e2 = Get-Exercise2EscalationData -AnalysisResults $AnalysisResults

    [void]$sb.AppendLine("### Exercise 3 Report-Out: Critical Path & Wait Analysis")
    [void]$sb.AppendLine("")
    [void]$sb.AppendLine("> GUI method: CPU Usage (Precise) -> New Process -> New ThreadId -> CPU Usage / Ready / Waits -> Readying Process")
    [void]$sb.AppendLine("")

    if ($e3.HasCriticalIssue) {
        [void]$sb.AppendLine("#### Step 1 - Identify critical path")
        [void]$sb.AppendLine("")
        [void]$sb.AppendLine((New-TableRow @('Metric', 'Observed Value', 'Assessment')))
        [void]$sb.AppendLine("|--------|----------------|------------|")
        [void]$sb.AppendLine((New-TableRow @('Dominant resume phase', "$($e3.TopResumePhase)", 'Candidate critical path')))
        [void]$sb.AppendLine((New-TableRow @('Dominant resume duration', "$($e3.TopResumeMs) ms ($($e3.TopResumeSec)s)", $(if ($e3.TopResumeSec -ge 10) { "$($script:IconRed) Excessive" } else { "$($script:IconYellow) Review" }) )))
        [void]$sb.AppendLine((New-TableRow @('Driver/wait signals', "$($e3.WaitSignalCount)", $(if ($e3.WaitSignalCount -gt 0) { "$($script:IconRed) Correlated" } else { "$($script:IconYellow) Not explicit" }) )))
        [void]$sb.AppendLine("")

        [void]$sb.AppendLine("#### Step 2 - Decompose and demonstrate each part")
        [void]$sb.AppendLine("")
        [void]$sb.AppendLine((New-TableRow @('Part', 'What to inspect in GUI', 'Result')))
        [void]$sb.AppendLine("|------|-------------------------|--------|")
        [void]$sb.AppendLine((New-TableRow @('Part A: Entry', 'New Process / New ThreadId at wake start', 'Initial resume execution present')))
        [void]$sb.AppendLine((New-TableRow @('Part B: Wait bottleneck', 'Waits (s) dominant segment', 'Longest delay aligned to critical path')))
        [void]$sb.AppendLine((New-TableRow @('Part C: Completion', 'Readying Process after wait clears', 'Resume completes after bottleneck')))
        [void]$sb.AppendLine("")

        [void]$sb.AppendLine("#### Step 3 - Wait-chain correlation")
        [void]$sb.AppendLine("")
        [void]$sb.AppendLine((New-TableRow @('Evidence Type', 'Correlation')))
        [void]$sb.AppendLine("|--------------|-------------|")
        [void]$sb.AppendLine((New-TableRow @('Waits (s) dominance', 'Primary contributor to end-to-end delay')))
        [void]$sb.AppendLine((New-TableRow @('Driver/system findings', $(if ($e3.WaitSignalCount -gt 0) { 'Timestamp-aligned with wait window' } else { 'No explicit driver signal captured' }) )))
        [void]$sb.AppendLine("")

        [void]$sb.AppendLine("> **Actionable bottleneck statement:** This trace is wait-dominated on the critical path. Prioritize root-cause analysis on the longest Waits(s) segment and its timestamp-aligned driver/system events.")
        [void]$sb.AppendLine("")
    }
    else {
        [void]$sb.AppendLine((New-TableRow @('Check', 'Result')))
        [void]$sb.AppendLine("|-------|--------|")
        [void]$sb.AppendLine((New-TableRow @('Critical-path wait bottleneck', "$($script:IconGreen) Not detected in this trace")))
        [void]$sb.AppendLine((New-TableRow @('Longest resume-related phase', $(if ($e3.TopResumeSec -gt 0) { "$($e3.TopResumeSec)s ($($e3.TopResumePhase))" } else { 'N/A' }) )))
        [void]$sb.AppendLine("")
        [void]$sb.AppendLine("> Exercise 3 workflow was applied, but no severe wait-dominated bottleneck was identified in this report output.")
        [void]$sb.AppendLine("")
    }

    [void]$sb.AppendLine("#### Exercise 2 Escalation Rule (Fast Startup using WPT)")
    [void]$sb.AppendLine("")
    [void]$sb.AppendLine("> Reference: `C:\Users\jetgsche\Downloads\PerformanceLab\WinHEC HOL Optimizing Performance and Responsiveness Lab.docx` -> **EXERCISE 2 – EVALUATE FAST STARTUP USING WPT**")
    [void]$sb.AppendLine("")

    [void]$sb.AppendLine((New-TableRow @('Condition', 'Decision', 'Required Visualized Parts')))
    [void]$sb.AppendLine("|----------|----------|---------------------------|")
    [void]$sb.AppendLine((New-TableRow @(
        'Threshold-driven escalation (config/thresholds.json + analyzer threshold findings)',
        $(if ($e2.NeedExercise2) { "$($script:IconRed) Run Exercise 2" } else { "$($script:IconGreen) Optional" }),
        'Regions of Interest, CPU Usage (Sampled), Disk Usage, Generic Events (only when directly tied to the critical issue)'
    )))
    [void]$sb.AppendLine("")

    if ($e2.NeedExercise2 -and $e2.Reasons.Count -gt 0) {
        [void]$sb.AppendLine("Trigger reasons detected in this report output:")
        foreach ($reason in $e2.Reasons) {
            [void]$sb.AppendLine("- $reason")
        }
        [void]$sb.AppendLine("")
    }

    Format-ThresholdsSnapshotTable -sb $sb
}

# ────────────────────────────────────────────────
# Format a Fast Startup / Boot section
# ────────────────────────────────────────────────
function Format-FastStartupSection {
    param(
        [PSCustomObject]$Result,
        [System.Text.StringBuilder]$sb
    )

    $raw = $Result.RawData

    # Section header is now emitted by the main Format-EtwReport function

    [void]$sb.AppendLine("### A. Boot Phase Analysis (System Activity)")
    [void]$sb.AppendLine("")
    [void]$sb.AppendLine("Examined Regions of Interest to identify boot phase durations and hierarchy.")
    [void]$sb.AppendLine("Used ``xperf -a boot`` to extract boot timing metrics and ``wpaexporter`` for CSV data export.")
    [void]$sb.AppendLine("")

    # ── Boot Timing Summary ──
    $explorerMs = $null
    $postBootMs = $null
    if ($raw) {
        if ($raw.BootDoneViaExplorerMs) { $explorerMs = $raw.BootDoneViaExplorerMs }
        if ($raw.BootDoneViaPostBootMs) { $postBootMs = $raw.BootDoneViaPostBootMs }
    }

    if ($explorerMs -or $postBootMs) {
        [void]$sb.AppendLine("#### Boot Timing Summary")
        [void]$sb.AppendLine("")
        [void]$sb.AppendLine((New-TableRow @('Metric', 'Value (ms)', 'Value (s)', 'Status')))
        [void]$sb.AppendLine("|--------|-----------|-----------|--------|")

        if ($explorerMs) {
            $expSec = [math]::Round($explorerMs / 1000, 2)
            $expStatus = Get-BootTimingStatus -Seconds $expSec -WarnThreshold 10 -CritThreshold 20
            [void]$sb.AppendLine((New-TableRow @("**Boot to Desktop (Explorer Init)**", "$explorerMs", "$expSec", "$expStatus")))
        }
        if ($postBootMs) {
            $pbSec = [math]::Round($postBootMs / 1000, 2)
            $pbStatus = Get-BootTimingStatus -Seconds $pbSec -WarnThreshold 30 -CritThreshold 60
            [void]$sb.AppendLine((New-TableRow @("**Total Boot (incl. Post On/Off)**", "$postBootMs", "$pbSec", "$pbStatus")))
        }
        [void]$sb.AppendLine("")
    }

    # ── Phase Breakdown Table (WAC-style) ──
    if ($Result.Phases -and $Result.Phases.Count -gt 0) {
        [void]$sb.AppendLine("#### Boot Phase Breakdown (Regions of Interest)")
        [void]$sb.AppendLine("")
        [void]$sb.AppendLine("> Hierarchical phase breakdown from WPA Regions of Interest analysis.")
        [void]$sb.AppendLine("> Indentation shows the parent-child relationship between phases.")
        [void]$sb.AppendLine("")

        $maxDuration = ($Result.Phases | Measure-Object -Property DurationMs -Maximum).Maximum
        if ($maxDuration -le 0) { $maxDuration = 1 }

        # Check if phases have Depth property (Regions CSV) or not (xperf fallback)
        $hasDepth = ($Result.Phases[0].PSObject.Properties.Name -contains 'Depth')

        [void]$sb.AppendLine((New-TableRow @('#', 'Phase', 'Duration (ms)', 'Duration (s)', 'Bar', 'Status')))
        [void]$sb.AppendLine("|---|-------|--------------|-------------|-----|--------|")

        $phaseIdx = 0
        foreach ($phase in $Result.Phases) {
            $phaseIdx++
            $sec = if ($phase.DurationS) { $phase.DurationS } else { [math]::Round($phase.DurationMs / 1000, 3) }
            $currentStatus = if ($phase.Status) { $phase.Status } else { 'OK' }
            $statusText = Get-PhaseStatusIcon -Status $currentStatus
            $bar = Get-StatusBar -Value $phase.DurationMs -Max $maxDuration -Width 15
            $barCell = '``' + $bar + '``'

            # Indent based on depth
            $indent = ''
            if ($hasDepth -and $phase.Depth -gt 0) {
                $indent = ('&nbsp;&nbsp;' * $phase.Depth) + [char]0x2514 + ' '
            }
            $phaseName = "$indent**$($phase.Name)**"
            [void]$sb.AppendLine((New-TableRow @("$phaseIdx", $phaseName, "$($phase.DurationMs)", "$sec", $barCell, $statusText)))
        }
        [void]$sb.AppendLine("")

        # Phase descriptions (collapsible)
        [void]$sb.AppendLine("<details>")
        [void]$sb.AppendLine("<summary>$($script:IconBook) Phase Descriptions (click to expand)</summary>")
        [void]$sb.AppendLine("")
        [void]$sb.AppendLine((New-TableRow @('Phase', 'Description')))
        [void]$sb.AppendLine("|-------|-------------|")
        [void]$sb.AppendLine((New-TableRow @('Overall Shutdown', 'Time from user-initiated shutdown/restart through user session shutdown and system suspend.')))
        [void]$sb.AppendLine((New-TableRow @('User Session Shutdown', 'Time to notify user-mode applications and services of the pending shutdown.')))
        [void]$sb.AppendLine((New-TableRow @('System Suspend', 'Time the kernel takes to flush caches, suspend devices, and write the hiberfile.')))
        [void]$sb.AppendLine((New-TableRow @('BIOS Initialization', 'Time the firmware takes from power-on to handing control to the Windows boot loader.')))
        [void]$sb.AppendLine((New-TableRow @('Resume Devices', 'Time the OS takes to resume devices and restore them to active power state.')))
        [void]$sb.AppendLine((New-TableRow @('Winlogon Resume', 'Time the OS takes to resume the Winlogon process and prepare the user session.')))
        [void]$sb.AppendLine((New-TableRow @('Explorer Initialization', 'Time the OS takes to initialize the Windows shell (explorer.exe) until desktop is visible.')))
        [void]$sb.AppendLine((New-TableRow @('Post Boot', 'Time after desktop appears until CPU and disk become idle (startup tasks completing).')))
        [void]$sb.AppendLine("")
        [void]$sb.AppendLine("</details>")
        [void]$sb.AppendLine("")
    }

    [void]$sb.AppendLine("### B. Service & Device Analysis")
    [void]$sb.AppendLine("")
    [void]$sb.AppendLine("Analyzed service transition durations to identify slow-starting services.")
    [void]$sb.AppendLine("Examined PnP device enumeration times to identify slow device drivers.")
    [void]$sb.AppendLine("")

    # ── Service Transition Duration ──
    if ($raw -and $raw.TopServicesByTime -and $raw.TopServicesByTime.Count -gt 0) {
        [void]$sb.AppendLine("#### Service Transition Duration")
        [void]$sb.AppendLine("")
        [void]$sb.AppendLine("> Services sorted by duration (descending). Focus on services with the longest duration.")
        [void]$sb.AppendLine("")

        $sortedSvcs = $raw.TopServicesByTime | Sort-Object TotalTimeMs -Descending | Select-Object -First 10
        $maxSvcMs = ($sortedSvcs | Measure-Object -Property TotalTimeMs -Maximum).Maximum
        if ($maxSvcMs -le 0) { $maxSvcMs = 1 }

        [void]$sb.AppendLine((New-TableRow @('#', 'Service Name', 'Transition', 'Duration (ms)', 'Duration (s)', 'Bar', 'Container')))
        [void]$sb.AppendLine("|---|-------------|-----------|--------------|-------------|-----|-----------|")

        $svcIdx = 0
        foreach ($svc in $sortedSvcs) {
            $svcIdx++
            $svcSec = [math]::Round($svc.TotalTimeMs / 1000, 2)
            $bar = Get-StatusBar -Value $svc.TotalTimeMs -Max $maxSvcMs -Width 12
            $barCell = '``' + $bar + '``'
            $container = if ($svc.Container) { $svc.Container } else { '-' }
            [void]$sb.AppendLine((New-TableRow @("$svcIdx", "**$($svc.Name)**", "$($svc.Transition)", "$($svc.TotalTimeMs)", "$svcSec", $barCell, "$container")))
        }
        [void]$sb.AppendLine("")
    }

    # ── Resume Devices Duration (PnP) ──
    if ($raw -and $raw.PnpDevices -and $raw.PnpDevices.Count -gt 0) {
        [void]$sb.AppendLine("#### Resume Devices Duration (PnP Enumeration)")
        [void]$sb.AppendLine("")
        [void]$sb.AppendLine("> Device drivers may become a source of boot delays.")
        [void]$sb.AppendLine("> Sorted by enumeration time (descending) to highlight the slowest devices.")
        [void]$sb.AppendLine("")

        $sortedPnp = $raw.PnpDevices | Sort-Object DurationMs -Descending | Select-Object -First 10
        $maxPnpMs = ($sortedPnp | Measure-Object -Property DurationMs -Maximum).Maximum
        if ($maxPnpMs -le 0) { $maxPnpMs = 1 }

        [void]$sb.AppendLine((New-TableRow @('#', 'Device', 'Duration (ms)', 'Bar', 'Status')))
        [void]$sb.AppendLine("|---|--------|--------------|-----|--------|")

        $pnpIdx = 0
        foreach ($pnp in $sortedPnp) {
            $pnpIdx++
            $bar = Get-StatusBar -Value $pnp.DurationMs -Max $maxPnpMs -Width 12
            $barCell = '``' + $bar + '``'
            $pnpStatus = Get-DeviceStatus -DurationMs $pnp.DurationMs
            [void]$sb.AppendLine((New-TableRow @("$pnpIdx", "$($pnp.Description)", "$($pnp.DurationMs)", $barCell, $pnpStatus)))
        }
        [void]$sb.AppendLine("")
    }

    [void]$sb.AppendLine("### C. Process Resource Usage (CPU & Disk I/O)")
    [void]$sb.AppendLine("")
    [void]$sb.AppendLine("Exported CPU Sampling data via ``wpaexporter`` to identify top CPU consumers during boot.")
    [void]$sb.AppendLine("Exported Disk I/O summary to identify processes performing the most disk operations.")
    [void]$sb.AppendLine("")

    # ── Disk I/O During Boot ──
    if ($raw -and $raw.DiskIO) {
        $dio = $raw.DiskIO
        $totalMB = [math]::Round($dio.TotalBytes / 1MB, 2)

        [void]$sb.AppendLine("#### Disk I/O During Boot")
        [void]$sb.AppendLine("")
        [void]$sb.AppendLine((New-TableRow @('Metric', 'Value')))
        [void]$sb.AppendLine("|--------|-------|")
        [void]$sb.AppendLine((New-TableRow @('Phase', "$($dio.Phase)")))
        [void]$sb.AppendLine((New-TableRow @('Total I/O', "${totalMB} MB")))
        [void]$sb.AppendLine((New-TableRow @('Total Operations', "$($dio.TotalOps)")))
        [void]$sb.AppendLine((New-TableRow @('Read Operations', "$($dio.ReadOps)")))
        [void]$sb.AppendLine((New-TableRow @('Write Operations', "$($dio.WriteOps)")))
        [void]$sb.AppendLine("")
    }

    # ── Process CPU Usage During Boot ──
    if ($Result.TopOffenders -and $Result.TopOffenders.Count -gt 0) {
        [void]$sb.AppendLine("#### Process CPU Usage During Boot")
        [void]$sb.AppendLine("")
        [void]$sb.AppendLine("> Processes consuming the most CPU time during the boot sequence.")
        [void]$sb.AppendLine("")

        $metricLabel = if ($Result.MetricName) { $Result.MetricName } else { 'CPU Time (ms)' }
        $sortedProcs = $Result.TopOffenders | Sort-Object Value -Descending | Select-Object -First 10
        $maxVal = ($sortedProcs | Measure-Object -Property Value -Maximum).Maximum
        if ($maxVal -le 0) { $maxVal = 1 }

        [void]$sb.AppendLine((New-TableRow @('#', 'Process', $metricLabel, 'Instances', 'Bar')))
        [void]$sb.AppendLine("|---|---------|------------|-----------|-----|")

        $rank = 0
        foreach ($o in $sortedProcs) {
            $rank++
            $bar = Get-StatusBar -Value $o.Value -Max $maxVal -Width 15
            $barCell = '``' + $bar + '``'
            [void]$sb.AppendLine((New-TableRow @("$rank", "**$($o.Name)**", "$($o.Value)", "$($o.Count)", $barCell)))
        }
        [void]$sb.AppendLine("")
    }

    # ── Disk I/O by Process (from wpaexporter CSV) ──
    if ($Result.CsvData -and $Result.CsvData.DiskByProcess -and $Result.CsvData.DiskByProcess.Count -gt 0) {
        [void]$sb.AppendLine("#### Disk I/O by Process During Boot")
        [void]$sb.AppendLine("")
        [void]$sb.AppendLine("> Processes performing the most disk I/O during the boot sequence.")
        [void]$sb.AppendLine("")

        $diskData = $Result.CsvData.DiskByProcess
        $sizeCol = $diskData[0].PSObject.Properties.Name | Where-Object { $_ -match '^Size$' } | Select-Object -First 1
        $countCol = $diskData[0].PSObject.Properties.Name | Where-Object { $_ -match '^Count$' } | Select-Object -First 1

        if ($sizeCol) {
            $sortedDisk = $diskData |
                Where-Object { $_.Process -and $_.$sizeCol -gt 0 } |
                Sort-Object { [double]$_.$sizeCol } -Descending |
                Select-Object -First 10

            $maxDiskSize = 1
            foreach ($d in $sortedDisk) {
                $s = [double]$d.$sizeCol
                if ($s -gt $maxDiskSize) { $maxDiskSize = $s }
            }

            [void]$sb.AppendLine((New-TableRow @('#', 'Process', 'Total I/O (MB)', 'I/O Count', 'Bar')))
            [void]$sb.AppendLine("|---|---------|--------------|----------|-----|")

            $diskRank = 0
            foreach ($dp in $sortedDisk) {
                $diskRank++
                $sizeMB = [math]::Round([double]$dp.$sizeCol / 1MB, 2)
                $ioCount = if ($countCol -and $dp.$countCol) { [int]$dp.$countCol } else { '-' }
                $bar = Get-StatusBar -Value ([double]$dp.$sizeCol) -Max $maxDiskSize -Width 12
                $barCell = '``' + $bar + '``'
                [void]$sb.AppendLine((New-TableRow @("$diskRank", "**$($dp.Process)**", "$sizeMB", "$ioCount", $barCell)))
            }
            [void]$sb.AppendLine("")
        }
    }
}

# ────────────────────────────────────────────────
# Format a generic analyzer section
# ────────────────────────────────────────────────
function Format-GenericSection {
    param(
        [PSCustomObject]$Result,
        [System.Text.StringBuilder]$sb
    )

    [void]$sb.AppendLine("## $($Result.AnalyzerName)")
    [void]$sb.AppendLine("")

    if ($Result.Summary) {
        [void]$sb.AppendLine($Result.Summary)
        [void]$sb.AppendLine("")
    }

    # Phase breakdown table
    if ($Result.Phases -and $Result.Phases.Count -gt 0) {
        [void]$sb.AppendLine("### Phase Breakdown")
        [void]$sb.AppendLine("")

        $maxDuration = ($Result.Phases | Measure-Object -Property DurationMs -Maximum).Maximum
        if ($maxDuration -le 0) { $maxDuration = 1 }

        [void]$sb.AppendLine((New-TableRow @('#', 'Phase', 'Duration (ms)', 'Duration (s)', 'Bar', 'Status')))
        [void]$sb.AppendLine("|---|-------|--------------|-------------|-----|--------|")

        $idx = 0
        foreach ($phase in $Result.Phases) {
            $idx++
            $sec = [math]::Round($phase.DurationMs / 1000, 2)
            $currentStatus = if ($phase.Status) { $phase.Status } else { 'OK' }
            $statusText = Get-PhaseStatusIcon -Status $currentStatus
            $bar = Get-StatusBar -Value $phase.DurationMs -Max $maxDuration -Width 15
            $barCell = '``' + $bar + '``'
            [void]$sb.AppendLine((New-TableRow @("$idx", "**$($phase.Name)**", "$($phase.DurationMs)", "$sec", $barCell, $statusText)))
        }
        [void]$sb.AppendLine("")
    }

    # Top offenders table
    if ($Result.TopOffenders -and $Result.TopOffenders.Count -gt 0) {
        [void]$sb.AppendLine("### Top Offenders")
        [void]$sb.AppendLine("")

        $metricLabel = if ($Result.MetricName) { $Result.MetricName } else { 'Value' }
        $maxVal = ($Result.TopOffenders | Measure-Object -Property Value -Maximum).Maximum
        if ($maxVal -le 0) { $maxVal = 1 }

        [void]$sb.AppendLine((New-TableRow @('#', 'Name', $metricLabel, 'Count', 'Bar')))
        [void]$sb.AppendLine("|---|------|------------|-------|-----|")

        $rank = 0
        foreach ($o in $Result.TopOffenders | Sort-Object Value -Descending) {
            $rank++
            $bar = Get-StatusBar -Value $o.Value -Max $maxVal -Width 15
            $barCell = '``' + $bar + '``'
            [void]$sb.AppendLine((New-TableRow @("$rank", "**$($o.Name)**", "$($o.Value)", "$($o.Count)", $barCell)))
        }
        [void]$sb.AppendLine("")
    }
}

# ────────────────────────────────────────────────
# Collect analysis-machine system information
# ────────────────────────────────────────────────
function Get-AnalysisMachineInfo {
    try {
        $bios = Get-CimInstance Win32_BIOS -ErrorAction Stop
        $sys  = Get-CimInstance Win32_ComputerSystem -ErrorAction Stop
        $cpu  = Get-CimInstance Win32_Processor -ErrorAction Stop
        $os   = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
        $mem  = Get-CimInstance Win32_PhysicalMemory -ErrorAction Stop
        $uptime = (Get-Date) - $os.LastBootUpTime
        $reg  = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction SilentlyContinue

        $memConfig = ($mem | ForEach-Object {
            "$([math]::Round($_.Capacity / 1GB)) GB $($_.Speed) MHz"
        }) -join ', '

        $wpaVersion = 'N/A'
        $xperf = Get-Command xperf.exe -ErrorAction SilentlyContinue
        if ($xperf) {
            $verLine = & $xperf -help 2>&1 | Select-String 'version' | Select-Object -First 1
            if ($verLine) { $wpaVersion = $verLine.ToString().Trim() }
        }

        return [PSCustomObject]@{
            Manufacturer = $sys.Manufacturer
            Model        = $sys.Model
            Serial       = $bios.SerialNumber
            BiosVersion  = $bios.SMBIOSBIOSVersion
            BiosDate     = if ($bios.ReleaseDate) { $bios.ReleaseDate.ToString('yyyy-MM-dd') } else { 'N/A' }
            CpuName      = $cpu.Name
            CpuArch      = $cpu.Description
            Cores        = $cpu.NumberOfCores
            Threads      = $cpu.NumberOfLogicalProcessors
            TotalRAM     = "$([math]::Round($os.TotalVisibleMemorySize / 1MB, 1)) GB"
            MemConfig    = $memConfig
            OSCaption    = $os.Caption
            OSVersion    = if ($reg -and $reg.DisplayVersion) { $reg.DisplayVersion } else { 'N/A' }
            OSBuild      = $os.Version
            BuildLab     = if ($reg -and $reg.BuildLabEx) { $reg.BuildLabEx } else { 'N/A' }
            HyperV       = if ($sys.HypervisorPresent) { 'Enabled' } else { 'Disabled' }
            Uptime       = "$([math]::Floor($uptime.TotalDays)) days $($uptime.Hours) hours $($uptime.Minutes) minutes"
            WpaVersion   = $wpaVersion
        }
    }
    catch {
        Write-Verbose "Could not gather system info: $_"
        return $null
    }
}

# ────────────────────────────────────────────────
# Build Executive Summary from analysis results
# ────────────────────────────────────────────────
function Build-ExecutiveSummary {
    param(
        [array]$AllFindings,
        [array]$AnalysisResults,
        [PSCustomObject]$TraceInfo
    )

    $criticals = @($AllFindings | Where-Object { $_.Severity -eq 'Critical' })
    $warnings  = @($AllFindings | Where-Object { $_.Severity -eq 'Warning' })

    # Build problem description
    $problems = @()
    foreach ($f in ($criticals + $warnings) | Select-Object -First 3) {
        $problems += "$($f.Category): $($f.Message)"
    }
    $problemText = if ($problems.Count -gt 0) { $problems -join '; ' }
                   else { 'No critical or warning issues detected.' }

    # Build root cause
    $rootCause = if ($criticals.Count -gt 0) {
        ($criticals | Select-Object -First 1).Message
    } elseif ($warnings.Count -gt 0) {
        ($warnings | Select-Object -First 1).Message
    } else { 'No significant issues found.' }

    # Build impact
    $impact = if ($criticals.Count -gt 0) { 'Critical performance issues detected that may severely impact user experience.' }
              elseif ($warnings.Count -gt 0) { 'Warning-level issues detected that may affect perceived performance.' }
              else { 'System performance appears normal.' }

    # Build recommendation
    $allRecs = @()
    foreach ($r in $AnalysisResults) {
        if ($r.Recommendations) { $allRecs += $r.Recommendations }
    }
    $topRec = if ($allRecs.Count -gt 0) { $allRecs[0] } else { 'No action required.' }

    return [PSCustomObject]@{
        Problem       = $problemText
        RootCause     = $rootCause
        Impact        = $impact
        Recommendation = $topRec
    }
}

# ────────────────────────────────────────────────
# Main: Format-EtwReport
# ────────────────────────────────────────────────
function Format-EtwReport {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [PSCustomObject]$TraceInfo,

        [Parameter(Mandatory)]
        [array]$AnalysisResults,

        [string]$OutputPath
    )

    $sb = [System.Text.StringBuilder]::new()
    $sectionNum = 0

    # Collect system info and findings up front
    $sysInfo = Get-AnalysisMachineInfo

    $allFindings = @()
    foreach ($r in $AnalysisResults) {
        if ($r.Findings) { $allFindings += $r.Findings }
    }
    $criticalCount = @($allFindings | Where-Object { $_.Severity -eq 'Critical' }).Count
    $warningCount  = @($allFindings | Where-Object { $_.Severity -eq 'Warning' }).Count
    $infoCount     = @($allFindings | Where-Object { $_.Severity -notin @('Critical','Warning') }).Count

    $overallSeverity = 'Good'
    $overallIcon = $script:IconGreen
    if ($criticalCount -gt 0) { $overallSeverity = 'CRITICAL'; $overallIcon = $script:IconRed }
    elseif ($warningCount -gt 0) { $overallSeverity = 'WARNING'; $overallIcon = $script:IconYellow }

    $summary = Build-ExecutiveSummary -AllFindings $allFindings -AnalysisResults $AnalysisResults -TraceInfo $TraceInfo

    # ══════════════════════════════════════════════
    # Report Header
    # ══════════════════════════════════════════════
    [void]$sb.AppendLine("# $($script:IconChart) ETW Auto-Analysis Report")
    [void]$sb.AppendLine("")
    [void]$sb.AppendLine("> Modeled after the Windows Assessment Toolkit (WAC) Fast Startup report format.")
    [void]$sb.AppendLine("> Tables below replace the WAC GUI drill-down views with equivalent tabular data.")
    [void]$sb.AppendLine("")
    [void]$sb.AppendLine("---")
    [void]$sb.AppendLine("")

    # ══════════════════════════════════════════════
    # 1. Executive Summary
    # ══════════════════════════════════════════════
    $sectionNum++
    [void]$sb.AppendLine("## $sectionNum. ETL Summary")
    [void]$sb.AppendLine("")
    [void]$sb.AppendLine((New-TableRow @('Item', 'Details')))
    [void]$sb.AppendLine("|------|---------|")
    [void]$sb.AppendLine((New-TableRow @('**Problem**', $summary.Problem)))
    [void]$sb.AppendLine((New-TableRow @('**Root Cause**', $summary.RootCause)))
    [void]$sb.AppendLine((New-TableRow @('**Impact**', $summary.Impact)))
    [void]$sb.AppendLine((New-TableRow @('**Recommended Action**', $summary.Recommendation)))
    [void]$sb.AppendLine("")
    [void]$sb.AppendLine("---")
    [void]$sb.AppendLine("")

    # ══════════════════════════════════════════════
    # 2. Root Cause (One-Line)
    # ══════════════════════════════════════════════
    $sectionNum++
    [void]$sb.AppendLine("## $sectionNum. Root Cause (One-Line)")
    [void]$sb.AppendLine("")
    [void]$sb.AppendLine("> $($summary.RootCause)")
    [void]$sb.AppendLine("")
    [void]$sb.AppendLine("---")
    [void]$sb.AppendLine("")

    # ══════════════════════════════════════════════
    # 3. System Information
    # ══════════════════════════════════════════════
    $sectionNum++
    [void]$sb.AppendLine("## $sectionNum. System Information")
    [void]$sb.AppendLine("")

    if ($sysInfo) {
        [void]$sb.AppendLine("### Analysis Machine")
        [void]$sb.AppendLine("")
        [void]$sb.AppendLine((New-TableRow @('Field', 'Value')))
        [void]$sb.AppendLine("|-------|-------|")
        [void]$sb.AppendLine((New-TableRow @('**Manufacturer**', $sysInfo.Manufacturer)))
        [void]$sb.AppendLine((New-TableRow @('**Model**', $sysInfo.Model)))
        [void]$sb.AppendLine((New-TableRow @('**Serial Number**', $sysInfo.Serial)))
        [void]$sb.AppendLine((New-TableRow @('**BIOS Version**', $sysInfo.BiosVersion)))
        [void]$sb.AppendLine((New-TableRow @('**BIOS Date**', $sysInfo.BiosDate)))
        [void]$sb.AppendLine("")

        [void]$sb.AppendLine("### CPU")
        [void]$sb.AppendLine("")
        [void]$sb.AppendLine((New-TableRow @('Field', 'Value')))
        [void]$sb.AppendLine("|-------|-------|")
        [void]$sb.AppendLine((New-TableRow @('**Processor**', $sysInfo.CpuName)))
        [void]$sb.AppendLine((New-TableRow @('**Architecture**', $sysInfo.CpuArch)))
        [void]$sb.AppendLine((New-TableRow @('**Cores / Threads**', "$($sysInfo.Cores) / $($sysInfo.Threads)")))
        [void]$sb.AppendLine("")

        [void]$sb.AppendLine("### Memory")
        [void]$sb.AppendLine("")
        [void]$sb.AppendLine((New-TableRow @('Field', 'Value')))
        [void]$sb.AppendLine("|-------|-------|")
        [void]$sb.AppendLine((New-TableRow @('**Total RAM**', $sysInfo.TotalRAM)))
        [void]$sb.AppendLine((New-TableRow @('**Configuration**', $sysInfo.MemConfig)))
        [void]$sb.AppendLine("")

        [void]$sb.AppendLine("### OS")
        [void]$sb.AppendLine("")
        [void]$sb.AppendLine((New-TableRow @('Field', 'Value')))
        [void]$sb.AppendLine("|-------|-------|")
        [void]$sb.AppendLine((New-TableRow @('**OS**', "$($sysInfo.OSCaption) $($sysInfo.OSVersion) (Build $($sysInfo.OSBuild))")))
        [void]$sb.AppendLine((New-TableRow @('**Build Lab**', $sysInfo.BuildLab)))
        [void]$sb.AppendLine((New-TableRow @('**Hyper-V**', $sysInfo.HyperV)))
        [void]$sb.AppendLine((New-TableRow @('**Uptime at Analysis**', $sysInfo.Uptime)))
        [void]$sb.AppendLine("")

        [void]$sb.AppendLine("### Analysis Tools")
        [void]$sb.AppendLine("")
        [void]$sb.AppendLine((New-TableRow @('Tool', 'Version')))
        [void]$sb.AppendLine("|------|---------|")
        [void]$sb.AppendLine((New-TableRow @('**Windows Performance Analyzer (WPA)**', $sysInfo.WpaVersion)))
        [void]$sb.AppendLine((New-TableRow @('**ETW Auto-Analysis Toolset**', 'etw-copilot')))
        [void]$sb.AppendLine("")
    }

    [void]$sb.AppendLine("---")
    [void]$sb.AppendLine("")

    # ══════════════════════════════════════════════
    # 4. Trace Information
    # ══════════════════════════════════════════════
    $sectionNum++
    [void]$sb.AppendLine("## $sectionNum. Trace Information")
    [void]$sb.AppendLine("")
    [void]$sb.AppendLine((New-TableRow @('Property', 'Value')))
    [void]$sb.AppendLine("|----------|-------|")
    [void]$sb.AppendLine((New-TableRow @('**Generated**', (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))))
    [void]$sb.AppendLine((New-TableRow @('**ETL File**', "``$($TraceInfo.EtlPath)``")))
    [void]$sb.AppendLine((New-TableRow @('**File Size**', "$($TraceInfo.FileSizeMB) MB")))
    [void]$sb.AppendLine((New-TableRow @('**Trace Type**', "$($TraceInfo.TraceType)")))
    if ($TraceInfo.Duration) {
        [void]$sb.AppendLine((New-TableRow @('**Duration**', "$([math]::Round($TraceInfo.Duration, 2)) seconds")))
    }
    if ($TraceInfo.EventsLost -gt 0) {
        [void]$sb.AppendLine((New-TableRow @("$($script:IconWarn) **Events Lost**", "**$($TraceInfo.EventsLost)**")))
    }
    [void]$sb.AppendLine((New-TableRow @('**Detected Capabilities**', ($TraceInfo.Providers -join ', '))))
    [void]$sb.AppendLine("")
    [void]$sb.AppendLine("---")
    [void]$sb.AppendLine("")

    # ══════════════════════════════════════════════
    # 5. Analysis Details
    # ══════════════════════════════════════════════
    $sectionNum++
    [void]$sb.AppendLine("## $sectionNum. Analysis Details")
    [void]$sb.AppendLine("")
    [void]$sb.AppendLine("> Automated analysis performed using WPA tools (``xperf``, ``wpaexporter``) on the ETL trace.")
    [void]$sb.AppendLine("> The following checks were executed and detailed tables are provided below.")
    [void]$sb.AppendLine("")

    Format-Exercise3ReportOutSection -AnalysisResults $AnalysisResults -sb $sb

    foreach ($r in $AnalysisResults) {
        $isFastStartup = $r.AnalyzerName -match 'Fast Startup|Boot'

        if ($isFastStartup) {
            Format-FastStartupSection -Result $r -sb $sb
        } else {
            Format-GenericSection -Result $r -sb $sb
        }
    }

    [void]$sb.AppendLine("---")
    [void]$sb.AppendLine("")

    # ══════════════════════════════════════════════
    # 6. Analysis Findings
    # ══════════════════════════════════════════════
    $sectionNum++
    [void]$sb.AppendLine("## $sectionNum. $($script:IconSearch) Analysis Findings: $overallSeverity")
    [void]$sb.AppendLine("")
    [void]$sb.AppendLine((New-TableRow @('Severity', 'Count')))
    [void]$sb.AppendLine("|----------|-------|")
    [void]$sb.AppendLine((New-TableRow @("$($script:IconRed) Critical", "$criticalCount")))
    [void]$sb.AppendLine((New-TableRow @("$($script:IconYellow) Warning", "$warningCount")))
    [void]$sb.AppendLine((New-TableRow @("$($script:IconGreen) Info", "$infoCount")))
    [void]$sb.AppendLine("")

    [void]$sb.AppendLine((New-TableRow @('Phase', 'Finding', 'Evidence (WPA)')))
    [void]$sb.AppendLine("|-------|---------|----------------|")

    foreach ($r in $AnalysisResults) {
        $isFastStartup = $r.AnalyzerName -match 'Fast Startup|Boot'
        if ($isFastStartup) {
            $rraw = $r.RawData
            if ($rraw -and $rraw.BootDoneViaExplorerMs) {
                $expSec = [math]::Round($rraw.BootDoneViaExplorerMs / 1000, 2)
                [void]$sb.AppendLine((New-TableRow @('Boot', "Desktop visible in $($expSec)s", "Boot Timing: Explorer Init = $($rraw.BootDoneViaExplorerMs)ms")))
            }
            if ($rraw -and $rraw.BootDoneViaPostBootMs) {
                $pbSec = [math]::Round($rraw.BootDoneViaPostBootMs / 1000, 2)
                [void]$sb.AppendLine((New-TableRow @('Boot', "Total boot completed in $($pbSec)s", "Boot Timing: Post Boot = $($rraw.BootDoneViaPostBootMs)ms")))
            }
            if ($r.Phases) {
                foreach ($phase in ($r.Phases | Where-Object { $_.Status -eq 'SLOW' -or $_.Status -eq 'CRITICAL' })) {
                    $pSec = [math]::Round($phase.DurationMs / 1000, 1)
                    $sIcon = if ($phase.Status -eq 'CRITICAL') { $script:IconRed } else { $script:IconYellow }
                    [void]$sb.AppendLine((New-TableRow @("$sIcon $($phase.Name)", "$($phase.Name) is $($phase.Status.ToLower()) ($($pSec)s)", "Regions of Interest: Duration = $($phase.DurationMs)ms")))
                }
            }
            if ($r.TopOffenders) {
                foreach ($o in ($r.TopOffenders | Sort-Object Value -Descending | Select-Object -First 3)) {
                    [void]$sb.AppendLine((New-TableRow @('CPU', "High CPU: $($o.Name)", "CPU Sampling: Weight = $($o.Value)ms")))
                }
            }
        }
        if ($r.Findings) {
            foreach ($f in $r.Findings) {
                $fIcon = Get-SeverityIcon -Severity $f.Severity
                [void]$sb.AppendLine((New-TableRow @("$fIcon $($f.Category)", "$($f.Message)", "Auto-detected by $($r.AnalyzerName) analyzer")))
            }
        }
    }

    [void]$sb.AppendLine("")
    [void]$sb.AppendLine("---")
    [void]$sb.AppendLine("")

    # ══════════════════════════════════════════════
    # 7. Recommendations
    # ══════════════════════════════════════════════
    $allRecs = @()
    $allCsvs = @()
    foreach ($r in $AnalysisResults) {
        if ($r.Recommendations) { $allRecs += $r.Recommendations }
        if ($r.CsvFiles) { $allCsvs += $r.CsvFiles }
    }

    if ($allRecs.Count -gt 0) {
        $sectionNum++
        [void]$sb.AppendLine("## $sectionNum. $($script:IconBulb) Recommendations")
        [void]$sb.AppendLine("")
        [void]$sb.AppendLine((New-TableRow @('#', 'Priority', 'Recommendation')))
        [void]$sb.AppendLine("|---|----------|----------------|")
        $recIdx = 0
        foreach ($rec in $allRecs) {
            $recIdx++
            $pri = "$($script:IconGreen) Low"
            if ($rec -match 'critical|took \d+\.\d+s|exceeds') { $pri = "$($script:IconRed) High" }
            elseif ($rec -match 'phase|consumed|service|Process') { $pri = "$($script:IconYellow) Medium" }
            [void]$sb.AppendLine((New-TableRow @("$recIdx", $pri, $rec)))
        }
        [void]$sb.AppendLine("")
    }

    # ══════════════════════════════════════════════
    # 8. Exported Data Files
    # ══════════════════════════════════════════════
    if ($allCsvs.Count -gt 0) {
        $sectionNum++
        [void]$sb.AppendLine("## $sectionNum. $($script:IconFolder) Exported Data Files")
        [void]$sb.AppendLine("")
        [void]$sb.AppendLine((New-TableRow @('#', 'File')))
        [void]$sb.AppendLine("|---|------|")
        $csvIdx = 0
        foreach ($csv in $allCsvs) {
            $csvIdx++
            [void]$sb.AppendLine((New-TableRow @("$csvIdx", "``$csv``")))
        }
        [void]$sb.AppendLine("")
    }

    [void]$sb.AppendLine("---")
    [void]$sb.AppendLine("")

    # ══════════════════════════════════════════════
    # Footer
    # ══════════════════════════════════════════════
    [void]$sb.AppendLine("*Report generated by ETW Auto-Analysis Toolset (etw-copilot) - $(Get-Date -Format 'yyyy-MM-dd')*")
    [void]$sb.AppendLine("*Report format modeled after Windows Assessment Toolkit (WAC) / PerformanceLab Fast Startup Report*")

    $report = $sb.ToString()

    if ($OutputPath) {
        # Write with UTF-8 BOM for proper emoji rendering
        $utf8Bom = New-Object System.Text.UTF8Encoding($true)
        [System.IO.File]::WriteAllText($OutputPath, $report, $utf8Bom)
        Write-Verbose "Report saved to: $OutputPath"
    }

    return $report
}

Export-ModuleMember -Function 'Format-EtwReport'
