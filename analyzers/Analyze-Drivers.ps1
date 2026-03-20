<#
.SYNOPSIS
    Analyzes driver performance from ETW traces - DPC, ISR, PnP, WDF.
#>

param(
    [Parameter(Mandatory)]
    [string]$EtlPath,

    [string]$OutputFolder
)

$ErrorActionPreference = 'Continue'
$moduleRoot = Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $moduleRoot 'EtwAnalysis.psm1') -Force -DisableNameChecking

$config = Initialize-EtwEnvironment
$thresholds = Get-EtwThresholds

Write-Host "[Driver] Symbol path: $($env:_NT_SYMBOL_PATH)" -ForegroundColor Gray

if (-not $OutputFolder) {
    $OutputFolder = Join-Path (Split-Path $EtlPath -Parent) 'etw_analysis_output'
}
if (-not (Test-Path $OutputFolder)) {
    New-Item -Path $OutputFolder -ItemType Directory -Force | Out-Null
}

Write-Host "[Driver] Analyzing: $EtlPath" -ForegroundColor Cyan

$result = [PSCustomObject]@{
    AnalyzerName    = 'Driver / DPC / ISR Analysis'
    Summary         = ''
    Phases          = @()
    TopOffenders    = @()
    MetricName      = 'Duration (us)'
    Findings        = @()
    Recommendations = @()
    CsvFiles        = @()
    RawData         = $null
}

# ── Step 1: xperf -a dpcisr ──
Write-Host "[Driver] Running xperf -a dpcisr..." -ForegroundColor Gray
$dpcAction = Invoke-XperfAction -EtlPath $EtlPath -Action 'dpcisr'

if ($dpcAction.Success -and $dpcAction.RawOutput) {
    $result.RawData = $dpcAction
    $rawOutput = $dpcAction.RawOutput
    $lines = $rawOutput -split "`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' }

    # Parse DPC/ISR output
    # Typical xperf dpcisr output has module name, count, min/max/avg durations
    $dpcEntries = @()
    $currentSection = 'Unknown'

    foreach ($line in $lines) {
        if ($line -match 'DPC\s' -or $line -match '\bDPC\b') { $currentSection = 'DPC' }
        if ($line -match 'ISR\s' -or $line -match '\bISR\b') { $currentSection = 'ISR' }

        # Match lines with .sys module names and numeric data
        if ($line -match '(\S+\.sys)\s+(.+)') {
            $moduleName = $Matches[1]
            $restOfLine = $Matches[2].Trim()

            # Try to extract numbers
            $numbers = [regex]::Matches($restOfLine, '(\d+[\.\d]*)') | ForEach-Object { [double]$_.Value }

            $entry = [PSCustomObject]@{
                Module   = $moduleName
                Type     = $currentSection
                Count    = if ($numbers.Count -ge 1) { $numbers[0] } else { 0 }
                MaxUs    = if ($numbers.Count -ge 2) { $numbers[-1] } else { 0 }
                TotalUs  = if ($numbers.Count -ge 3) { $numbers[1] } else { 0 }
                RawLine  = $line
            }

            $dpcEntries += $entry

            # Check against thresholds
            $maxMs = $entry.MaxUs / 1000
            if ($currentSection -eq 'DPC' -and $maxMs -gt $thresholds.Driver.DpcDurationMs.Critical) {
                $result.Findings += [PSCustomObject]@{
                    Severity = 'Critical'
                    Category = 'DPC Latency'
                    Message  = "Driver '$moduleName' has DPC max duration ${maxMs}ms (critical threshold: $($thresholds.Driver.DpcDurationMs.Critical)ms)"
                }
            } elseif ($currentSection -eq 'DPC' -and $maxMs -gt $thresholds.Driver.DpcDurationMs.Warning) {
                $result.Findings += [PSCustomObject]@{
                    Severity = 'Warning'
                    Category = 'DPC Latency'
                    Message  = "Driver '$moduleName' has DPC max duration ${maxMs}ms (warning threshold: $($thresholds.Driver.DpcDurationMs.Warning)ms)"
                }
            }

            if ($currentSection -eq 'ISR' -and $entry.MaxUs -gt $thresholds.Driver.IsrDurationUs.Critical) {
                $result.Findings += [PSCustomObject]@{
                    Severity = 'Critical'
                    Category = 'ISR Latency'
                    Message  = "Driver '$moduleName' has ISR max duration $($entry.MaxUs)us (critical threshold: $($thresholds.Driver.IsrDurationUs.Critical)us)"
                }
            } elseif ($currentSection -eq 'ISR' -and $entry.MaxUs -gt $thresholds.Driver.IsrDurationUs.Warning) {
                $result.Findings += [PSCustomObject]@{
                    Severity = 'Warning'
                    Category = 'ISR Latency'
                    Message  = "Driver '$moduleName' has ISR max duration $($entry.MaxUs)us (warning threshold: $($thresholds.Driver.IsrDurationUs.Warning)us)"
                }
            }
        }
    }

    # Top offenders by estimated total
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

    $result.Summary = "DPC/ISR analysis completed. Found $($dpcEntries.Count) driver entries. $($result.Findings.Count) issues detected."
} else {
    Write-Host "[Driver] xperf -a dpcisr not available or failed" -ForegroundColor Yellow
    $result.Summary = "DPC/ISR data not available in this trace. Ensure trace was captured with DPC/ISR ETW keywords enabled."
}

# ── Step 2: Try wpaexporter with DPC/ISR profile ──
$customProfile = Join-Path $moduleRoot 'profiles\export\DpcIsr-Export.wpaProfile'
if (Test-Path $customProfile) {
    Write-Host "[Driver] Exporting DPC/ISR data via wpaexporter..." -ForegroundColor Gray
    try {
        $exportResult = Export-EtwData -EtlPath $EtlPath -ProfilePath $customProfile -OutputFolder $OutputFolder -Prefix 'Driver_'
        if ($exportResult.CsvFiles.Count -gt 0) {
            $result.CsvFiles = $exportResult.CsvFiles
        }
    }
    catch {
        Write-Host "[Driver] wpaexporter failed: $_" -ForegroundColor Yellow
    }
}

# Recommendations
if ($result.Findings.Count -gt 0) {
    $criticalDrivers = $result.Findings | Where-Object { $_.Severity -eq 'Critical' }
    foreach ($f in $criticalDrivers) {
        $result.Recommendations += "URGENT: $($f.Message) - contact driver vendor for fix"
    }
}

$result.Recommendations += "Use WPA DPC/ISR Duration view for detailed per-interrupt analysis"
$result.Recommendations += "Check if problematic drivers have updated versions available"

Write-Host "[Driver] Analysis complete." -ForegroundColor Cyan
return $result
