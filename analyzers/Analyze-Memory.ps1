<#
.SYNOPSIS
    Analyzes memory usage from ETW traces - working sets, hard faults, pool, heap.
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

Write-Host "[Memory] Symbol path: $($env:_NT_SYMBOL_PATH)" -ForegroundColor Gray

if (-not $OutputFolder) {
    $OutputFolder = Join-Path (Split-Path $EtlPath -Parent) 'etw_analysis_output'
}
if (-not (Test-Path $OutputFolder)) {
    New-Item -Path $OutputFolder -ItemType Directory -Force | Out-Null
}

Write-Host "[Memory] Analyzing: $EtlPath" -ForegroundColor Cyan

$result = [PSCustomObject]@{
    AnalyzerName    = 'Memory Analysis'
    Summary         = ''
    Phases          = @()
    TopOffenders    = @()
    MetricName      = 'Hard Faults / Working Set'
    Findings        = @()
    Recommendations = @()
    CsvFiles        = @()
    RawData         = $null
}

# ── Step 1: xperf -a hardfault ──
Write-Host "[Memory] Running xperf -a hardfault..." -ForegroundColor Gray
$hfAction = Invoke-XperfAction -EtlPath $EtlPath -Action 'hardfault'

if ($hfAction.Success -and $hfAction.RawOutput) {
    $result.RawData = $hfAction
    $rawOutput = $hfAction.RawOutput
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

        foreach ($entry in $result.TopOffenders | Select-Object -First 5) {
            if ($entry.Value -gt $thresholds.Memory.HardFaultsPerSec.Critical) {
                $result.Findings += [PSCustomObject]@{
                    Severity = 'Critical'
                    Category = 'Hard Faults'
                    Message  = "'$($entry.Name)' has $($entry.Value) hard faults (critical threshold: $($thresholds.Memory.HardFaultsPerSec.Critical))"
                }
            } elseif ($entry.Value -gt $thresholds.Memory.HardFaultsPerSec.Warning) {
                $result.Findings += [PSCustomObject]@{
                    Severity = 'Warning'
                    Category = 'Hard Faults'
                    Message  = "'$($entry.Name)' has $($entry.Value) hard faults (warning threshold: $($thresholds.Memory.HardFaultsPerSec.Warning))"
                }
            }
        }
    }
}

# ── Step 2: Try wpaexporter with Memory profile ──
$catalogPath = $config.CatalogPath
$memProfile = Join-Path $catalogPath 'WindowsStoreAppMemoryAnalysis.wpaProfile'
$customProfile = Join-Path $moduleRoot 'profiles\export\Memory-Export.wpaProfile'

$profilesToTry = @($customProfile, $memProfile) | Where-Object { Test-Path $_ }

foreach ($wpaProfile in $profilesToTry) {
    Write-Host "[Memory] Trying wpaexporter with: $(Split-Path $wpaProfile -Leaf)" -ForegroundColor Gray
    try {
        $exportResult = Export-EtwData -EtlPath $EtlPath -ProfilePath $wpaProfile -OutputFolder $OutputFolder -Prefix 'Memory_'
        if ($exportResult.CsvFiles.Count -gt 0) {
            $result.CsvFiles += $exportResult.CsvFiles
            Write-Host "[Memory] Exported $($exportResult.CsvFiles.Count) CSV file(s)" -ForegroundColor Green
            break
        }
    }
    catch {
        Write-Host "[Memory] wpaexporter failed: $_" -ForegroundColor Yellow
    }
}

$result.Summary = "Memory analysis completed. $($result.TopOffenders.Count) processes with hard fault data, $($result.Findings.Count) findings."
$result.Recommendations += "Use WPA Virtual Memory Snapshots view for working set timeline analysis"
$result.Recommendations += "Check Pool allocations view for NonPaged/Paged pool leak candidates"
$result.Recommendations += "Review Hard Faults view grouped by Process for memory pressure indicators"

Write-Host "[Memory] Analysis complete." -ForegroundColor Cyan
return $result
