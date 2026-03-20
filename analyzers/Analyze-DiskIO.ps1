<#
.SYNOPSIS
    Analyzes Disk I/O from ETW traces.
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

Write-Host "[DiskIO] Symbol path: $($env:_NT_SYMBOL_PATH)" -ForegroundColor Gray

if (-not $OutputFolder) {
    $OutputFolder = Join-Path (Split-Path $EtlPath -Parent) 'etw_analysis_output'
}
if (-not (Test-Path $OutputFolder)) {
    New-Item -Path $OutputFolder -ItemType Directory -Force | Out-Null
}

Write-Host "[DiskIO] Analyzing: $EtlPath" -ForegroundColor Cyan

$result = [PSCustomObject]@{
    AnalyzerName    = 'Disk I/O Analysis'
    Summary         = ''
    Phases          = @()
    TopOffenders    = @()
    MetricName      = 'I/O Size (bytes)'
    Findings        = @()
    Recommendations = @()
    CsvFiles        = @()
    RawData         = $null
}

# ── Step 1: xperf -a diskio ──
Write-Host "[DiskIO] Running xperf -a diskio..." -ForegroundColor Gray
$diskAction = Invoke-XperfAction -EtlPath $EtlPath -Action 'diskio'

if ($diskAction.Success) {
    $result.RawData = $diskAction
    $rawOutput = $diskAction.RawOutput

    # Parse disk I/O summary from xperf output
    $lines = $rawOutput -split "`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' }
    $ioEntries = @()

    foreach ($line in $lines) {
        # Look for process-based I/O lines
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

    # Check for flush keywords
    $flushLines = ($lines | Where-Object { $_ -match 'flush|Flush|FLUSH' }).Count
    if ($flushLines -gt 0) {
        $result.Findings += [PSCustomObject]@{
            Severity = if ($flushLines -gt 10) { 'Warning' } else { 'Info' }
            Category = 'Disk Flush'
            Message  = "Detected $flushLines flush-related entries in disk I/O output"
        }
    }

    $result.Summary = "Disk I/O analysis from xperf completed. $($ioEntries.Count) I/O entries parsed."
} else {
    Write-Host "[DiskIO] xperf -a diskio not available for this trace" -ForegroundColor Yellow
    $result.Summary = "xperf disk I/O action not available. Trace may not contain disk I/O events."
}

# ── Step 2: Try wpaexporter with DiskIO profile ──
$customProfile = Join-Path $moduleRoot 'profiles\export\DiskIO-Export.wpaProfile'
if (Test-Path $customProfile) {
    Write-Host "[DiskIO] Exporting via wpaexporter..." -ForegroundColor Gray
    try {
        $exportResult = Export-EtwData -EtlPath $EtlPath -ProfilePath $customProfile -OutputFolder $OutputFolder -Prefix 'DiskIO_'
        if ($exportResult.CsvFiles.Count -gt 0) {
            $result.CsvFiles = $exportResult.CsvFiles
            foreach ($csvFile in $exportResult.CsvFiles) {
                $data = Import-EtwCsv -CsvPath $csvFile -MaxRows 500
                if ($data.Count -gt 0) {
                    $columns = $data[0].PSObject.Properties.Name
                    $processCol = $columns | Where-Object { $_ -match 'Process' } | Select-Object -First 1
                    $sizeCol = $columns | Where-Object { $_ -match 'Size|Bytes|IO' } | Select-Object -First 1
                    if ($processCol -and $sizeCol) {
                        $topIO = Find-TopOffenders -Data $data -GroupBy $processCol -MetricColumn $sizeCol -TopN 10
                        if ($topIO.Count -gt 0) {
                            $result.TopOffenders = $topIO
                        }
                    }
                }
            }
        }
    }
    catch {
        Write-Host "[DiskIO] wpaexporter failed: $_" -ForegroundColor Yellow
    }
}

# Recommendations
$result.Recommendations += "Open trace in WPA and review Disk I/O tables for per-file breakdown"
if ($result.TopOffenders.Count -gt 0) {
    foreach ($o in $result.TopOffenders | Select-Object -First 3) {
        $result.Recommendations += "Investigate '$($o.Name)' - top disk I/O contributor"
    }
}

Write-Host "[DiskIO] Analysis complete." -ForegroundColor Cyan
return $result
