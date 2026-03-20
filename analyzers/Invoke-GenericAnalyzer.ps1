<#
.SYNOPSIS
    Generic ETW Analyzer — data extraction engine for all analysis types.
.DESCRIPTION
    Consolidates the common data extraction logic from all individual analyzers
    into a single parameterized script. Runs xperf actions and wpaexporter
    exports, parses results, and returns a standardized result object.

    Analysis-type-specific interpretation, threshold checking, and finding
    generation are handled by Copilot via .instructions.md files, or by
    the CLI auto-analysis path with -ApplyThresholds.

.PARAMETER EtlPath
    Path to the ETL trace file.

.PARAMETER OutputFolder
    Directory for CSV output.

.PARAMETER AnalyzerName
    Human-readable name for this analysis (appears in report).

.PARAMETER XperfAction
    Optional xperf -a action to run (boot, shutdown, dpcisr, diskio, hardfault, etc.)

.PARAMETER WpaProfile
    WPA profile path or catalog name for wpaexporter CSV export.
    Can be: full path, catalog filename, or custom profile filename in profiles/export/.

.PARAMETER WpaProfileFallbacks
    Optional array of fallback WPA profile names if primary is not found.

.PARAMETER Prefix
    CSV file prefix for wpaexporter output (e.g., 'FS_', 'CPU_', 'DRV_').

.PARAMETER MetricName
    Label for the primary metric (e.g., 'CPU Weight (ms)', 'I/O Size (bytes)').

.PARAMETER ApplyThresholds
    Optional hashtable of threshold configs for CLI auto-analysis mode.
    When provided, the script generates findings based on thresholds.
    Format: @{ ThresholdSection = 'FastStartup'; Rules = @(...) }

.EXAMPLE
    & .\analyzers\Invoke-GenericAnalyzer.ps1 -EtlPath "trace.etl" -AnalyzerName "Boot Analysis" -XperfAction boot -WpaProfile FastStartup -Prefix FS_

.EXAMPLE
    & .\analyzers\Invoke-GenericAnalyzer.ps1 -EtlPath "trace.etl" -AnalyzerName "CPU Analysis" -WpaProfile CpuSampling-Export -Prefix CPU_
#>

param(
    [Parameter(Mandatory)]
    [string]$EtlPath,

    [string]$OutputFolder,

    [string]$AnalyzerName = 'Generic Analysis',

    [string]$XperfAction,

    [string]$WpaProfile,

    [string[]]$WpaProfileFallbacks = @(),

    [string]$Prefix = '',

    [string]$MetricName = 'Value',

    [hashtable]$ApplyThresholds
)

$ErrorActionPreference = 'Continue'
$moduleRoot = Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $moduleRoot 'EtwAnalysis.psm1') -Force -DisableNameChecking -Global

$config = Initialize-EtwEnvironment
$thresholds = Get-EtwThresholds

Write-Host "[$AnalyzerName] Symbol path: $($env:_NT_SYMBOL_PATH)" -ForegroundColor Gray

if (-not $OutputFolder) {
    $OutputFolder = Join-Path (Split-Path $EtlPath -Parent) 'etw_analysis_output'
}
if (-not (Test-Path $OutputFolder)) {
    New-Item -Path $OutputFolder -ItemType Directory -Force | Out-Null
}

Write-Host "[$AnalyzerName] Analyzing: $EtlPath" -ForegroundColor Cyan

# ── Initialize result object ────────────────────────────────────────────────
$result = [PSCustomObject]@{
    AnalyzerName    = $AnalyzerName
    Summary         = ''
    Phases          = @()
    TopOffenders    = @()
    MetricName      = $MetricName
    Findings        = @()
    Recommendations = @()
    CsvFiles        = @()
    RawData         = $null
    CsvData         = $null
}

# ════════════════════════════════════════════════════════════════════════════
# Step 1: Run xperf action (if specified)
# ════════════════════════════════════════════════════════════════════════════
if ($XperfAction) {
    Write-Host "[$AnalyzerName] Running xperf -a $XperfAction..." -ForegroundColor Gray
    $xperfResult = Invoke-XperfAction -EtlPath $EtlPath -Action $XperfAction

    if ($xperfResult.Success) {
        $result.RawData = $xperfResult

        # ── Parse boot XML (structured) ──────────────────────────────────
        if ($XperfAction -in @('boot', 'shutdown') -and $xperfResult.Parsed) {
            $boot = $xperfResult.Parsed

            # Build phase hierarchy from boot intervals
            if ($boot.Intervals -and $boot.Intervals.Count -gt 0) {
                foreach ($interval in $boot.Intervals) {
                    $result.Phases += [PSCustomObject]@{
                        Name       = $interval.Name
                        FullPath   = $interval.Name
                        Depth      = 0
                        DurationMs = $interval.DurationMs
                        DurationS  = [math]::Round($interval.DurationMs / 1000, 3)
                        Status     = if ($interval.DurationMs -gt 20000) { 'CRITICAL' }
                                     elseif ($interval.DurationMs -gt 10000) { 'SLOW' }
                                     else { 'OK' }
                    }
                }
            }

            # Top processes by CPU
            if ($boot.TopProcessesByCpu -and $boot.TopProcessesByCpu.Count -gt 0) {
                $procCpu = $boot.TopProcessesByCpu |
                    Group-Object ProcessName |
                    ForEach-Object {
                        [PSCustomObject]@{
                            Name  = $_.Name
                            Value = ($_.Group | ForEach-Object { $_.CpuTimeMs } | Measure-Object -Sum).Sum
                            Count = $_.Count
                        }
                    } |
                    Sort-Object Value -Descending |
                    Select-Object -First 10
                $result.TopOffenders = $procCpu
            }
        }

        # ── Parse DPC/ISR text output ────────────────────────────────────
        if ($XperfAction -eq 'dpcisr' -and $xperfResult.RawOutput) {
            $rawOutput = $xperfResult.RawOutput
            $lines = $rawOutput -split "`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' }

            $dpcEntries = @()
            $currentSection = 'Unknown'

            foreach ($line in $lines) {
                if ($line -match 'DPC\s' -or $line -match '\bDPC\b') { $currentSection = 'DPC' }
                if ($line -match 'ISR\s' -or $line -match '\bISR\b') { $currentSection = 'ISR' }

                if ($line -match '(\S+\.sys)\s+(.+)') {
                    $moduleName = $Matches[1]
                    $restOfLine = $Matches[2].Trim()
                    $numbers = [regex]::Matches($restOfLine, '(\d+[\.\d]*)') | ForEach-Object { [double]$_.Value }

                    $dpcEntries += [PSCustomObject]@{
                        Module   = $moduleName
                        Type     = $currentSection
                        Count    = if ($numbers.Count -ge 1) { $numbers[0] } else { 0 }
                        MaxUs    = if ($numbers.Count -ge 2) { $numbers[-1] } else { 0 }
                        TotalUs  = if ($numbers.Count -ge 3) { $numbers[1] } else { 0 }
                    }
                }
            }

            if ($dpcEntries.Count -gt 0) {
                $result.TopOffenders = $dpcEntries |
                    Sort-Object { $_.Count } -Descending |
                    Select-Object -First 10 |
                    ForEach-Object {
                        [PSCustomObject]@{
                            Name  = "$($_.Module) ($($_.Type))"
                            Value = $_.Count
                            Count = 1
                        }
                    }

                # Store raw DPC/ISR entries in CsvData for instructions to analyze
                $result.CsvData = [PSCustomObject]@{ DpcIsrEntries = $dpcEntries }
            }
        }

        # ── Parse diskio text output ─────────────────────────────────────
        if ($XperfAction -eq 'diskio' -and $xperfResult.RawOutput) {
            $rawOutput = $xperfResult.RawOutput
            $lines = $rawOutput -split "`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' }
            $ioEntries = @()

            foreach ($line in $lines) {
                if ($line -match '(.+?)\s{2,}(\d+)\s+(\d+)') {
                    $ioEntries += [PSCustomObject]@{
                        Name  = $Matches[1].Trim()
                        Value = [double]$Matches[2]
                        Count = [int]$Matches[3]
                    }
                }
            }

            if ($ioEntries.Count -gt 0) {
                $result.TopOffenders = $ioEntries | Sort-Object Value -Descending | Select-Object -First 10
            }

            # Detect flush keywords
            $flushLines = ($lines | Where-Object { $_ -match 'flush|Flush|FLUSH' }).Count
            if ($flushLines -gt 0) {
                $result.CsvData = [PSCustomObject]@{ FlushCount = $flushLines }
            }
        }

        # ── Parse hardfault text output ──────────────────────────────────
        if ($XperfAction -eq 'hardfault' -and $xperfResult.RawOutput) {
            $rawOutput = $xperfResult.RawOutput
            $lines = $rawOutput -split "`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' }
            $hfEntries = @()

            foreach ($line in $lines) {
                if ($line -match '(\S+\.exe|\S+\.dll)\s+(\d+)') {
                    $hfEntries += [PSCustomObject]@{
                        Name  = $Matches[1]
                        Value = [double]$Matches[2]
                        Count = 1
                    }
                }
            }

            if ($hfEntries.Count -gt 0) {
                $result.TopOffenders = $hfEntries | Sort-Object Value -Descending | Select-Object -First 10
            }
        }

        Write-Host "[$AnalyzerName] xperf -a $XperfAction completed." -ForegroundColor Gray
    } else {
        Write-Host "[$AnalyzerName] xperf -a $XperfAction failed or not available." -ForegroundColor Yellow
    }
}

# ════════════════════════════════════════════════════════════════════════════
# Step 2: Run wpaexporter with WPA profile (if specified)
# ════════════════════════════════════════════════════════════════════════════
if ($WpaProfile) {
    $resolvedProfile = $null
    $catalogPath = $config.CatalogPath
    $customProfileDir = Join-Path $moduleRoot 'profiles\export'

    # Try resolving the profile path in this order:
    # 1. Full path as given
    # 2. Custom profiles/export/ directory
    # 3. WPT Catalog directory
    $candidates = @(
        $WpaProfile
        (Join-Path $customProfileDir $WpaProfile)
        (Join-Path $customProfileDir "$WpaProfile.wpaProfile")
        (Join-Path $catalogPath $WpaProfile)
        (Join-Path $catalogPath "$WpaProfile.wpaProfile")
        (Join-Path $catalogPath "$WpaProfile.wpaprofile")
    )

    foreach ($candidate in $candidates) {
        if (Test-Path $candidate) {
            $resolvedProfile = $candidate
            break
        }
    }

    # Try fallbacks if primary not found
    if (-not $resolvedProfile -and $WpaProfileFallbacks.Count -gt 0) {
        foreach ($fb in $WpaProfileFallbacks) {
            $fbCandidates = @(
                $fb
                (Join-Path $customProfileDir $fb)
                (Join-Path $customProfileDir "$fb.wpaProfile")
                (Join-Path $catalogPath $fb)
                (Join-Path $catalogPath "$fb.wpaProfile")
                (Join-Path $catalogPath "$fb.wpaprofile")
            )
            foreach ($fbc in $fbCandidates) {
                if (Test-Path $fbc) {
                    $resolvedProfile = $fbc
                    Write-Host "[$AnalyzerName] Using fallback profile: $(Split-Path $fbc -Leaf)" -ForegroundColor Gray
                    break
                }
            }
            if ($resolvedProfile) { break }
        }
    }

    if ($resolvedProfile) {
        Write-Host "[$AnalyzerName] Exporting data via wpaexporter: $(Split-Path $resolvedProfile -Leaf)" -ForegroundColor Gray

        try {
            $exportResult = Export-EtwData -EtlPath $EtlPath -ProfilePath $resolvedProfile -OutputFolder $OutputFolder -Prefix $Prefix

            if ($exportResult.CsvFiles.Count -gt 0) {
                $result.CsvFiles = $exportResult.CsvFiles
                Write-Host "[$AnalyzerName] Exported $($exportResult.CsvFiles.Count) CSV file(s)" -ForegroundColor Green

                # Parse all CSVs and build CsvData
                $csvTables = @{}
                foreach ($csvFile in $exportResult.CsvFiles) {
                    $csvName = Split-Path $csvFile -Leaf
                    Write-Host "[$AnalyzerName]   Parsing: $csvName" -ForegroundColor Gray

                    $data = Import-EtwCsv -CsvPath $csvFile -MaxRows 500
                    if ($data.Count -gt 0) {
                        # Store with a clean key derived from filename
                        $key = ($csvName -replace '^[^_]+_', '' -replace '\.csv$', '' -replace '\s+', '_')
                        $csvTables[$key] = $data

                        # Auto-detect top offenders from first CSV if none set yet
                        if ($result.TopOffenders.Count -eq 0) {
                            $columns = $data[0].PSObject.Properties.Name
                            $processCol = $columns | Where-Object { $_ -match 'Process|Module|Component|Device|Name|Region' } | Select-Object -First 1
                            $metricCol = $columns | Where-Object { $_ -match 'Weight|CPU|Usage|Count|Duration|Time|Size|Bytes|Active' } | Select-Object -First 1

                            if ($processCol -and $metricCol) {
                                $topItems = Find-TopOffenders -Data $data -GroupBy $processCol -MetricColumn $metricCol -TopN 10
                                if ($topItems.Count -gt 0) {
                                    $result.TopOffenders = $topItems
                                }
                            }
                        }
                    }
                }

                # Merge csvTables into CsvData
                if (-not $result.CsvData) { $result.CsvData = [PSCustomObject]@{} }
                foreach ($key in $csvTables.Keys) {
                    $result.CsvData | Add-Member -NotePropertyName $key -NotePropertyValue $csvTables[$key] -Force
                }

                # ── FastStartup-specific: Build phase hierarchy from Regions CSV ──
                if ($XperfAction -eq 'boot') {
                    $regionsData = $csvTables.Keys | Where-Object { $_ -match 'Regions' } | Select-Object -First 1
                    if ($regionsData -and $csvTables[$regionsData].Count -gt 0) {
                        $seenPhases = @{}
                        $phases = @()
                        foreach ($region in $csvTables[$regionsData]) {
                            $regionName = $region.Region
                            if (-not $regionName) { continue }

                            $durationSec = 0
                            $durProp = $region.PSObject.Properties | Where-Object { $_.Name -match 'Duration' } | Select-Object -First 1
                            if ($durProp) { $durationSec = [double]$durProp.Value }
                            if ($durationSec -le 0.0001) { continue }
                            if ($seenPhases.ContainsKey($regionName)) { continue }
                            $seenPhases[$regionName] = $true

                            $depth = ($regionName.ToCharArray() | Where-Object { $_ -eq '\' }).Count
                            $shortName = if ($regionName -match '\\([^\\]+)$') { $matches[1] } else { $regionName }
                            $durationMs = [math]::Round($durationSec * 1000, 0)

                            $phases += [PSCustomObject]@{
                                Name       = $shortName
                                FullPath   = $regionName
                                Depth      = $depth
                                DurationMs = $durationMs
                                DurationS  = [math]::Round($durationSec, 3)
                                Status     = if ($durationMs -gt 20000) { 'CRITICAL' }
                                             elseif ($durationMs -gt 10000) { 'SLOW' }
                                             else { 'OK' }
                            }
                        }
                        if ($phases.Count -gt 0) { $result.Phases = $phases }
                    }

                    # Build CPU top processes from wpaexporter CPU CSV (override xperf data)
                    $cpuData = $csvTables.Keys | Where-Object { $_ -match 'CPU_Usage|Sampled' } | Select-Object -First 1
                    if ($cpuData -and $csvTables[$cpuData].Count -gt 0) {
                        $weightCol = $csvTables[$cpuData][0].PSObject.Properties.Name | Where-Object { $_ -match 'Weight' } | Select-Object -First 1
                        if ($weightCol) {
                            $cpuProcs = $csvTables[$cpuData] |
                                Where-Object { $_.Process -and $_.Process -notmatch '^Idle' } |
                                Sort-Object { [double]$_.$weightCol } -Descending |
                                Select-Object -First 15

                            $topCpu = @()
                            foreach ($proc in $cpuProcs) {
                                $weight = [double]$proc.$weightCol
                                if ($weight -gt 0) {
                                    $topCpu += [PSCustomObject]@{
                                        Name  = $proc.Process
                                        Value = [math]::Round($weight, 1)
                                        Count = if ($proc.Count) { [int]$proc.Count } else { 1 }
                                    }
                                }
                            }
                            if ($topCpu.Count -gt 0) { $result.TopOffenders = $topCpu }
                        }
                    }
                }
            } else {
                Write-Host "[$AnalyzerName] wpaexporter produced no CSV files" -ForegroundColor Yellow
            }
        }
        catch {
            Write-Host "[$AnalyzerName] wpaexporter failed: $_" -ForegroundColor Yellow
        }
    } else {
        Write-Host "[$AnalyzerName] No WPA profile found for: $WpaProfile" -ForegroundColor Yellow
    }
}

# ════════════════════════════════════════════════════════════════════════════
# Step 3: Apply thresholds (CLI auto-analysis mode)
# ════════════════════════════════════════════════════════════════════════════
if ($ApplyThresholds -and $ApplyThresholds.ThresholdSection) {
    $section = $ApplyThresholds.ThresholdSection
    $th = $thresholds.$section

    if ($th) {
        # Boot-specific threshold checks
        if ($XperfAction -eq 'boot' -and $result.RawData -and $result.RawData.Parsed) {
            $boot = $result.RawData.Parsed
            $totalBootSec = [math]::Round($boot.BootDoneViaPostBootMs / 1000, 2)

            if ($totalBootSec -gt $th.BootTotalSeconds.Critical) {
                $result.Findings += [PSCustomObject]@{
                    Severity = 'Critical'; Category = 'Boot Time'
                    Message  = "Total boot time ${totalBootSec}s exceeds critical threshold ($($th.BootTotalSeconds.Critical)s)"
                }
            } elseif ($totalBootSec -gt $th.BootTotalSeconds.Warning) {
                $result.Findings += [PSCustomObject]@{
                    Severity = 'Warning'; Category = 'Boot Time'
                    Message  = "Total boot time ${totalBootSec}s exceeds warning threshold ($($th.BootTotalSeconds.Warning)s)"
                }
            }

            # Service delays
            if ($boot.TopServicesByTime) {
                foreach ($svc in $boot.TopServicesByTime) {
                    $svcSec = [math]::Round($svc.TotalTimeMs / 1000, 2)
                    if ($svcSec -gt $th.ServiceDelaySeconds.Critical) {
                        $result.Findings += [PSCustomObject]@{
                            Severity = 'Critical'; Category = 'Slow Service'
                            Message  = "Service '$($svc.Name)' ($($svc.Transition)) took ${svcSec}s"
                        }
                    } elseif ($svcSec -gt $th.ServiceDelaySeconds.Warning) {
                        $result.Findings += [PSCustomObject]@{
                            Severity = 'Warning'; Category = 'Slow Service'
                            Message  = "Service '$($svc.Name)' ($($svc.Transition)) took ${svcSec}s"
                        }
                    }
                }
            }
        }

        # DPC/ISR threshold checks
        if ($XperfAction -eq 'dpcisr' -and $result.CsvData -and $result.CsvData.DpcIsrEntries) {
            foreach ($entry in $result.CsvData.DpcIsrEntries) {
                $maxMs = $entry.MaxUs / 1000
                if ($entry.Type -eq 'DPC') {
                    if ($maxMs -gt $th.DpcDurationMs.Critical) {
                        $result.Findings += [PSCustomObject]@{
                            Severity = 'Critical'; Category = 'DPC Latency'
                            Message  = "Driver '$($entry.Module)' DPC max ${maxMs}ms (threshold: $($th.DpcDurationMs.Critical)ms)"
                        }
                    } elseif ($maxMs -gt $th.DpcDurationMs.Warning) {
                        $result.Findings += [PSCustomObject]@{
                            Severity = 'Warning'; Category = 'DPC Latency'
                            Message  = "Driver '$($entry.Module)' DPC max ${maxMs}ms (threshold: $($th.DpcDurationMs.Warning)ms)"
                        }
                    }
                }
                if ($entry.Type -eq 'ISR') {
                    if ($entry.MaxUs -gt $th.IsrDurationUs.Critical) {
                        $result.Findings += [PSCustomObject]@{
                            Severity = 'Critical'; Category = 'ISR Latency'
                            Message  = "Driver '$($entry.Module)' ISR max $($entry.MaxUs)us (threshold: $($th.IsrDurationUs.Critical)us)"
                        }
                    } elseif ($entry.MaxUs -gt $th.IsrDurationUs.Warning) {
                        $result.Findings += [PSCustomObject]@{
                            Severity = 'Warning'; Category = 'ISR Latency'
                            Message  = "Driver '$($entry.Module)' ISR max $($entry.MaxUs)us (threshold: $($th.IsrDurationUs.Warning)us)"
                        }
                    }
                }
            }
        }

        # Hard fault threshold checks
        if ($XperfAction -eq 'hardfault' -and $result.TopOffenders.Count -gt 0 -and $th.HardFaultsPerSec) {
            foreach ($entry in $result.TopOffenders | Select-Object -First 5) {
                if ($entry.Value -gt $th.HardFaultsPerSec.Critical) {
                    $result.Findings += [PSCustomObject]@{
                        Severity = 'Critical'; Category = 'Hard Faults'
                        Message  = "'$($entry.Name)' has $($entry.Value) hard faults (threshold: $($th.HardFaultsPerSec.Critical))"
                    }
                } elseif ($entry.Value -gt $th.HardFaultsPerSec.Warning) {
                    $result.Findings += [PSCustomObject]@{
                        Severity = 'Warning'; Category = 'Hard Faults'
                        Message  = "'$($entry.Name)' has $($entry.Value) hard faults (threshold: $($th.HardFaultsPerSec.Warning))"
                    }
                }
            }
        }
    }
}

# ════════════════════════════════════════════════════════════════════════════
# Step 4: Cross-reference with knowledge base
# ════════════════════════════════════════════════════════════════════════════
$knowledgePath = Join-Path $moduleRoot 'knowledge'
$knownIssuesFile = Join-Path $knowledgePath 'known-issues.json'

if ((Test-Path $knownIssuesFile) -and $result.TopOffenders.Count -gt 0) {
    $ki = Get-Content $knownIssuesFile -Raw | ConvertFrom-Json
    foreach ($offender in $result.TopOffenders) {
        foreach ($pattern in $ki.patterns) {
            if ($offender.Name -match $pattern.pattern) {
                $result.Findings += [PSCustomObject]@{
                    Severity = $pattern.severity
                    Category = $pattern.category
                    Message  = "[$($pattern.id)] $($pattern.description): $($offender.Name)"
                }
                $result.Recommendations += "[$($pattern.category)] $($pattern.recommendation)"
                break
            }
        }
    }
}

# ── Summary ──────────────────────────────────────────────────────────────────
$parts = @("$AnalyzerName completed.")
if ($result.TopOffenders.Count -gt 0) { $parts += "$($result.TopOffenders.Count) top offenders." }
if ($result.Phases.Count -gt 0)       { $parts += "$($result.Phases.Count) phases." }
if ($result.CsvFiles.Count -gt 0)     { $parts += "$($result.CsvFiles.Count) CSV files." }
if ($result.Findings.Count -gt 0)     { $parts += "$($result.Findings.Count) findings." }
$result.Summary = $parts -join ' '

Write-Host "[$AnalyzerName] $($result.Summary)" -ForegroundColor Cyan
return $result
