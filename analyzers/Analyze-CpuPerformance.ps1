<#
.SYNOPSIS
    Analyzes CPU performance from ETW traces - sampling, context switches, waits.
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

Write-Host "[CPU] Symbol path: $($env:_NT_SYMBOL_PATH)" -ForegroundColor Gray

if (-not $OutputFolder) {
    $OutputFolder = Join-Path (Split-Path $EtlPath -Parent) 'etw_analysis_output'
}
if (-not (Test-Path $OutputFolder)) {
    New-Item -Path $OutputFolder -ItemType Directory -Force | Out-Null
}

Write-Host "[CPU] Analyzing: $EtlPath" -ForegroundColor Cyan

$result = [PSCustomObject]@{
    AnalyzerName    = 'CPU Performance Analysis'
    Summary         = ''
    Phases          = @()
    TopOffenders    = @()
    MetricName      = 'CPU Usage'
    Findings        = @()
    Recommendations = @()
    CsvFiles        = @()
    RawData         = $null
}

# ── Step 1: Try wpaexporter with a CPU-focused profile ──
$customProfile = Join-Path $moduleRoot 'profiles\export\CpuSampling-Export.wpaProfile'
$catalogPath = $config.CatalogPath

# Try our custom profile first, fall back to catalog profiles
$profilesToTry = @($customProfile)
$presetsProfile = Join-Path $catalogPath 'PresetsForComparativeAnalysis.wpaProfile'
if (Test-Path $presetsProfile) { $profilesToTry += $presetsProfile }

foreach ($wpaProfile in $profilesToTry) {
    if (-not (Test-Path $wpaProfile)) { continue }

    Write-Host "[CPU] Trying wpaexporter with: $(Split-Path $wpaProfile -Leaf)" -ForegroundColor Gray
    try {
        $exportResult = Export-EtwData -EtlPath $EtlPath -ProfilePath $wpaProfile -OutputFolder $OutputFolder -Prefix 'CPU_'
        if ($exportResult.CsvFiles.Count -gt 0) {
            $result.CsvFiles += $exportResult.CsvFiles
            Write-Host "[CPU] Exported $($exportResult.CsvFiles.Count) CSV file(s)" -ForegroundColor Green

            foreach ($csvFile in $exportResult.CsvFiles) {
                $csvName = Split-Path $csvFile -Leaf
                $data = Import-EtwCsv -CsvPath $csvFile -MaxRows 1000

                if ($data.Count -eq 0) { continue }
                $columns = $data[0].PSObject.Properties.Name

                $processCol = $columns | Where-Object { $_ -match 'Process|Module' } | Select-Object -First 1
                $metricCol = $columns | Where-Object { $_ -match 'Weight|CPU|Usage|Count|Duration|Time' } | Select-Object -First 1

                if ($processCol -and $metricCol) {
                    $topItems = Find-TopOffenders -Data $data -GroupBy $processCol -MetricColumn $metricCol -TopN 10
                    if ($topItems.Count -gt 0) {
                        $result.TopOffenders = $topItems
                        $result.MetricName = $metricCol
                        break
                    }
                }
            }
            break
        }
    }
    catch {
        Write-Host "[CPU] Export failed with $($wpaProfile): $_" -ForegroundColor Yellow
    }
}

# ── Step 2: Parse xperf trace info for CPU summary ──
Write-Host "[CPU] Reading trace metadata..." -ForegroundColor Gray
$traceInfo = Get-TraceInfo -EtlPath $EtlPath
$result.RawData = $traceInfo

# ── Step 3: Load wait classification data ──
$watchFunctionsFile = Join-Path $moduleRoot 'knowledge\watch-functions.txt'
$watchFunctions = @()
if (Test-Path $watchFunctionsFile) {
    $watchFunctions = Get-Content $watchFunctionsFile | Where-Object { $_ -notmatch '^\s*#' -and $_ -match '\S' } | ForEach-Object { $_.Trim().Split()[0] }
}

# ── Step 4: Analyze exported CSVs for CPU insights ──
if ($result.TopOffenders.Count -gt 0) {
    foreach ($offender in $result.TopOffenders | Select-Object -First 5) {
        $cpuPercent = $offender.Value
        if ($cpuPercent -gt $thresholds.Cpu.ProcessCpuPercent.Critical) {
            $result.Findings += [PSCustomObject]@{
                Severity = 'Critical'
                Category = 'High CPU'
                Message  = "Process '$($offender.Name)' has very high CPU usage: $($offender.Value)"
            }
        } elseif ($cpuPercent -gt $thresholds.Cpu.ProcessCpuPercent.Warning) {
            $result.Findings += [PSCustomObject]@{
                Severity = 'Warning'
                Category = 'High CPU'
                Message  = "Process '$($offender.Name)' has elevated CPU usage: $($offender.Value)"
            }
        }
    }
}

# ── Step 5: Recommendations ──
if ($result.TopOffenders.Count -gt 0) {
    $topProc = $result.TopOffenders | Select-Object -First 3
    foreach ($p in $topProc) {
        $result.Recommendations += "Investigate '$($p.Name)' - top CPU consumer ($($p.Value))"
    }
}

if ($watchFunctions.Count -gt 0) {
    $result.Recommendations += "Check for wait-analysis issues (lock contention, page faults) using WPA CPU Precise view"
}
$result.Recommendations += "Open trace in WPA for CPU Sampling & Context Switch analysis"

$result.Summary = "CPU analysis completed. $($result.TopOffenders.Count) processes profiled, $($result.Findings.Count) findings."

Write-Host "[CPU] Analysis complete." -ForegroundColor Cyan
return $result
