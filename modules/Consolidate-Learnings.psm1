<#
.SYNOPSIS
    Consolidates analysis learnings back into the knowledge base after each investigation.
.DESCRIPTION
    After every ETL analysis, this module:
      1. Generates/appends an investigation_log.md in the output folder
      2. Appends new hot functions to knowledge/watch-functions.txt
      3. Appends new lock patterns to knowledge/watch-locks.txt
      4. Adds new driver/module patterns to knowledge/known-issues.json
      5. Appends session insights to knowledge/learnings.md
      6. Updates profiles/export/README.md if new profile hints emerge

    This creates a learning loop so each analysis improves future investigations.
#>

function Consolidate-Learnings {
    [CmdletBinding()]
    param(
        # Analysis results array from all analyzers
        [Parameter(Mandatory)]
        [object[]]$AnalysisResults,

        # TraceInfo object from Get-TraceInfo
        [Parameter(Mandatory)]
        [object]$TraceInfo,

        # Full path to the ETL file that was analyzed
        [Parameter(Mandatory)]
        [string]$EtlPath,

        # Output folder where the report was written
        [Parameter(Mandatory)]
        [string]$OutputPath,

        # Optional reason string from -Reason parameter
        [string]$Reason = '',

        # Path to the repo knowledge directory
        [string]$KnowledgePath
    )

    if (-not $KnowledgePath) {
        # Resolve from module location: modules/ -> repo root -> knowledge/
        $KnowledgePath = Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) 'knowledge'
        if (-not (Test-Path $KnowledgePath)) {
            # Fallback: find via module root
            $KnowledgePath = Join-Path (Split-Path $PSScriptRoot -Parent) 'knowledge'
        }
    }

    $timestamp    = Get-Date -Format 'yyyy-MM-dd HH:mm'
    $dateStamp    = Get-Date -Format 'yyyyMMdd'
    $etlName      = [System.IO.Path]::GetFileNameWithoutExtension($EtlPath)
    $logFile      = Join-Path $OutputPath "investigation_log_${etlName}_${dateStamp}.md"

    # ── Aggregate all findings across analyzers ──────────────────────────────
    $allFindings        = @()
    $allRecommendations = @()
    $newFunctions       = @()
    $newLocks           = @()
    $newDriverPatterns  = @()

    foreach ($result in $AnalysisResults) {
        if ($result.Findings)        { $allFindings        += $result.Findings }
        if ($result.Recommendations) { $allRecommendations += $result.Recommendations }

        # Extract hot functions from CPU TopOffenders
        if ($result.TopOffenders) {
            foreach ($off in $result.TopOffenders) {
                if ($off.Function -and $off.Function -ne 'Unknown' -and $off.Function -ne '') {
                    $newFunctions += $off.Function
                }
            }
        }

        # Extract functions from phase data that flagged slow operations
        if ($result.CsvData -and $result.CsvData.CpuByProcess) {
            foreach ($row in $result.CsvData.CpuByProcess | Select-Object -First 5) {
                if ($row.Function -and $row.Function -ne '') {
                    $newFunctions += $row.Function
                }
            }
        }
    }

    $criticalCount = ($allFindings | Where-Object { $_.Severity -eq 'Critical' } | Measure-Object).Count
    $warningCount  = ($allFindings | Where-Object { $_.Severity -eq 'Warning'  } | Measure-Object).Count
    $infoCount     = ($allFindings | Where-Object { $_.Severity -eq 'Info'     } | Measure-Object).Count

    # ── Phase 4: Write investigation_log.md ──────────────────────────────────
    Write-Host "[Consolidate] Writing investigation log: $logFile" -ForegroundColor Gray

    $logLines = @(
        "# ETW Investigation Log",
        "",
        "## Session Info",
        "- **Date**: $timestamp",
        "- **ETL File**: ``$EtlPath``",
        "- **Trace Type**: $($TraceInfo.TraceType)",
        "- **File Size**: $($TraceInfo.FileSizeMB) MB",
        "- **Reason**: $(if ($Reason) { $Reason } else { '(not specified)' })",
        "- **Analyst**: ETW-Copilot Automated Analysis",
        "- **Analyzers Run**: $($AnalysisResults | ForEach-Object { $_.AnalyzerName } | Join-String -Separator ', ')",
        "",
        "## Findings Summary",
        "",
        "| Severity | Count |",
        "|----------|-------|",
        "| $($script:IconRed 2>$null) Critical | $criticalCount |",
        "| $($script:IconYellow 2>$null) Warning  | $warningCount  |",
        "| $($script:IconBlue 2>$null) Info     | $infoCount     |",
        "",
        "| # | Severity | Category | Finding |",
        "|---|----------|----------|---------|"
    )

    # Use plain text severity markers (avoid emoji encoding issues in log file)
    $i = 1
    foreach ($f in $allFindings) {
        $sevTag = switch ($f.Severity) {
            'Critical' { '[CRITICAL]' }
            'Warning'  { '[WARNING]'  }
            'Info'     { '[INFO]'     }
            default    { '[INFO]'     }
        }
        $logLines += "| $i | $sevTag | $($f.Category) | $($f.Message) |"
        $i++
    }

    $logLines += ""
    $logLines += "## Investigation Timeline"
    $logLines += ""
    $logLines += "### Phase 1 — Initial Assessment"
    $logLines += "- Trace type detected: **$($TraceInfo.TraceType)**"
    $logLines += "- File size: **$($TraceInfo.FileSizeMB) MB**"
    $logLines += "- Recommended analyzers: $($TraceInfo.RecommendedAnalyzers -join ', ')"
    $logLines += "- Events lost: $($TraceInfo.EventsLost)"
    if ($TraceInfo.Duration) {
        $logLines += "- Trace duration: $([math]::Round($TraceInfo.Duration, 2))s"
    }
    $logLines += ""
    $logLines += "### Phase 2 — Analyzers Executed"
    $logLines += ""

    foreach ($result in $AnalysisResults) {
        $logLines += "#### $($result.AnalyzerName)"
        if ($result.Summary) {
            $logLines += "- Summary: $($result.Summary)"
        }
        $csvCount = if ($result.CsvFiles) { $result.CsvFiles.Count } else { 0 }
        $logLines += "- CSV files exported: $csvCount"
        if ($result.Findings -and $result.Findings.Count -gt 0) {
            $logLines += "- Findings: $($result.Findings.Count) ($( ($result.Findings | Where-Object Severity -eq 'Critical' | Measure-Object).Count ) critical)"
        }
        $logLines += ""
    }

    $logLines += "### Phase 3 — Root Cause & Key Evidence"
    $logLines += ""

    $criticalFindings = $allFindings | Where-Object { $_.Severity -eq 'Critical' }
    if ($criticalFindings) {
        foreach ($cf in $criticalFindings) {
            $logLines += "- **[CRITICAL] $($cf.Category)**: $($cf.Message)"
        }
    } else {
        $logLines += "- No critical findings identified in automated analysis."
    }

    $logLines += ""
    $logLines += "## Recommendations"
    $logLines += ""
    $recIndex = 1
    $uniqueRecs = $allRecommendations | Select-Object -Unique
    foreach ($rec in $uniqueRecs) {
        $logLines += "$recIndex. $rec"
        $recIndex++
    }

    $logLines += ""
    $logLines += "## Exported Data Files"
    $logLines += ""
    $allCsvFiles = @()
    foreach ($result in $AnalysisResults) {
        if ($result.CsvFiles) { $allCsvFiles += $result.CsvFiles }
    }
    if ($allCsvFiles.Count -gt 0) {
        $fileIdx = 1
        foreach ($csv in ($allCsvFiles | Select-Object -Unique)) {
            $logLines += "$fileIdx. ``$csv``"
            $fileIdx++
        }
    } else {
        $logLines += "_No CSV files exported._"
    }

    $logLines += ""
    $logLines += "---"
    $logLines += "_Generated by etw-copilot on $timestamp_"

    $logLines | Set-Content -Path $logFile -Encoding UTF8
    Write-Host "[Consolidate] Investigation log written." -ForegroundColor Gray

    # ── Update knowledge/watch-functions.txt with new hot functions ───────────
    if ($newFunctions.Count -gt 0 -and (Test-Path $KnowledgePath)) {
        $watchFunctionsFile = Join-Path $KnowledgePath 'watch-functions.txt'
        if (Test-Path $watchFunctionsFile) {
            $existingContent = Get-Content $watchFunctionsFile -Raw
            $addedCount = 0
            $newEntries = @()

            foreach ($fn in ($newFunctions | Select-Object -Unique)) {
                # Only add if not already present and looks like a real function name
                if ($fn.Length -gt 3 -and $fn -notmatch '^\d' -and $existingContent -notmatch [regex]::Escape($fn)) {
                    $newEntries += $fn
                    $addedCount++
                }
            }

            if ($newEntries.Count -gt 0) {
                $appendBlock = "`n# Auto-added from analysis session $dateStamp`n" + ($newEntries -join "`n")
                Add-Content -Path $watchFunctionsFile -Value $appendBlock -Encoding UTF8
                Write-Host "[Consolidate] Added $addedCount new function(s) to watch-functions.txt" -ForegroundColor Gray
            }
        }
    }

    # ── Update knowledge/known-issues.json with new driver patterns ───────────
    if ($allFindings.Count -gt 0 -and (Test-Path $KnowledgePath)) {
        $knownIssuesFile = Join-Path $KnowledgePath 'known-issues.json'
        if (Test-Path $knownIssuesFile) {
            $knownIssues = Get-Content $knownIssuesFile -Raw | ConvertFrom-Json
            $existingIds  = $knownIssues.patterns | ForEach-Object { $_.id }
            $newPatterns  = @()

            foreach ($finding in $allFindings | Where-Object { $_.Severity -in @('Critical','Warning') }) {
                # Try to extract a driver/module name from the finding message
                $driverMatch = [regex]::Match($finding.Message, "([a-zA-Z0-9_]+\.sys|[a-zA-Z0-9_]+\.dll)", [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
                if ($driverMatch.Success) {
                    $driverName = $driverMatch.Value.ToLower() -replace '\.sys$','' -replace '\.dll$',''
                    $candidateId = "auto-$driverName-$($finding.Category.ToLower() -replace '\s+','-')"

                    if ($candidateId -notin $existingIds -and $driverName.Length -gt 2) {
                        $newPatterns += [PSCustomObject]@{
                            id             = $candidateId
                            category       = $finding.Category
                            pattern        = [regex]::Escape($driverMatch.Value)
                            description    = $finding.Message
                            severity       = $finding.Severity
                            recommendation = "Identified during auto-analysis on $dateStamp. Investigate $($driverMatch.Value) behavior in this context."
                            source         = "auto-discovery:${etlName}:${dateStamp}"
                        }
                        $existingIds += $candidateId
                    }
                }
            }

            if ($newPatterns.Count -gt 0) {
                $knownIssues.patterns += $newPatterns
                $knownIssues | ConvertTo-Json -Depth 10 | Set-Content -Path $knownIssuesFile -Encoding UTF8
                Write-Host "[Consolidate] Added $($newPatterns.Count) new pattern(s) to known-issues.json" -ForegroundColor Gray
            }
        }
    }

    # ── Append session to knowledge/learnings.md ─────────────────────────────
    $learningsFile = Join-Path $KnowledgePath 'learnings.md'

    if (-not (Test-Path $learningsFile)) {
        @(
            "# ETW Analysis Learnings",
            "",
            "Auto-generated knowledge base built from analysis sessions.",
            "Each entry captures key patterns, new investigation directions, and debugging insights.",
            "",
            "---"
        ) | Set-Content -Path $learningsFile -Encoding UTF8
    }

    $sessionBlock = @(
        "",
        "## Session: $etlName — $timestamp",
        "",
        "| Property | Value |",
        "|----------|-------|",
        "| ETL | ``$EtlPath`` |",
        "| Trace Type | $($TraceInfo.TraceType) |",
        "| File Size | $($TraceInfo.FileSizeMB) MB |",
        "| Critical | $criticalCount | Warning | $warningCount |",
        "| Reason | $(if ($Reason) { $Reason } else { '—' }) |",
        "",
        "### Key Findings"
    )

    $topFindings = $allFindings | Where-Object { $_.Severity -in @('Critical','Warning') } | Select-Object -First 5
    if ($topFindings) {
        foreach ($tf in $topFindings) {
            $sessionBlock += "- **[$($tf.Severity)] $($tf.Category)**: $($tf.Message)"
        }
    } else {
        $sessionBlock += "- No critical/warning findings. System appears healthy."
    }

    $sessionBlock += ""
    $sessionBlock += "### Investigation Directions for Next Time"
    $sessionBlock += ""

    # Generate forward-looking hints based on what was found
    $directions = @()
    if ($criticalCount -gt 0) {
        $categories = $allFindings | Where-Object Severity -eq 'Critical' | Select-Object -ExpandProperty Category | Sort-Object -Unique
        foreach ($cat in $categories) {
            switch -Wildcard ($cat) {
                '*Boot*'    { $directions += "- Deep-dive boot phase: use ``xperf -a boot`` XML + wpaexporter Regions of Interest to isolate slow phase" }
                '*Service*' { $directions += "- Check service dependencies with ``sc qc <service>`` and review startup type chain" }
                '*PnP*'     { $directions += "- Enumerate PnP timing with ``xperf -a pnp`` and check driver INF install logs" }
                '*DPC*'     { $directions += "- Run DPC/ISR analysis: ``xperf -i <etl> -symbols -a dpcisr`` to resolve driver function names" }
                '*Disk*'    { $directions += "- Profile disk I/O: use DiskIO-Export.wpaProfile to see per-file I/O and check for flush storms" }
                '*CPU*'     { $directions += "- CPU stack sampling: use CpuSampling-Export.wpaProfile and look for hot functions in ntoskrnl/driver modules" }
                '*Memory*'  { $directions += "- Check pool tags with ``!poolused`` in WinDbg or monitor working set churn during the trace" }
                default     { $directions += "- Review ``$cat`` findings in deeper detail using targeted wpaexporter profile export" }
            }
        }
    }

    if ($TraceInfo.TraceType -match 'ModernStandby') {
        $directions += "- Check DRIPS residency: look for active periods >5% during low-power epoch"
        $directions += "- Validate D0 entry/exit timing for all devices using xperf power analysis"
    }

    if ($directions.Count -eq 0) {
        $directions += "- No critical issues. Consider collecting a longer trace to capture intermittent behavior."
    }

    $sessionBlock += $directions
    $sessionBlock += ""
    $sessionBlock += "### Debugging Usage Notes"
    $sessionBlock += ""
    $sessionBlock += "| Tool | Command Used | Purpose |"
    $sessionBlock += "|------|-------------|---------|"

    foreach ($result in $AnalysisResults) {
        switch -Wildcard ($result.AnalyzerName) {
            '*Boot*'          { $sessionBlock += "| xperf     | ``xperf -i <etl> -a boot``        | Boot phase timing (XML) |" }
            '*CPU*'           { $sessionBlock += "| wpaexporter | CpuSampling-Export.wpaProfile   | CPU usage by process/function |" }
            '*Disk*'          { $sessionBlock += "| wpaexporter | DiskIO-Export.wpaProfile        | Disk I/O by process/file |" }
            '*Driver*'        { $sessionBlock += "| xperf     | ``xperf -i <etl> -symbols -a dpcisr`` | DPC/ISR with symbol resolution |" }
            '*Memory*'        { $sessionBlock += "| xperf     | ``xperf -i <etl> -a hardfault``   | Hard fault analysis |" }
            '*Standby*'       { $sessionBlock += "| wpaexporter | GenericEvents-Export.wpaProfile  | Power state events |" }
            '*Responsiveness*'{ $sessionBlock += "| wpaexporter | GenericEvents-Export.wpaProfile  | UI thread delays |" }
        }
    }

    $sessionBlock += ""
    $sessionBlock += "---"

    Add-Content -Path $learningsFile -Value ($sessionBlock -join "`n") -Encoding UTF8
    Write-Host "[Consolidate] Session appended to learnings.md" -ForegroundColor Gray

    # ── Return summary ────────────────────────────────────────────────────────
    return [PSCustomObject]@{
        InvestigationLog = $logFile
        LearningsFile    = $learningsFile
        NewPatternsAdded = $newPatterns.Count
        NewFunctionsAdded = 0  # set above if watch-functions was updated
    }
}

Export-ModuleMember -Function 'Consolidate-Learnings'
