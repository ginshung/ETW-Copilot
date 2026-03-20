<#
.SYNOPSIS
    Analyzes Modern Standby / Connected Standby ETW traces.
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

Write-Host "[ModernStandby] Symbol path: $($env:_NT_SYMBOL_PATH)" -ForegroundColor Gray

if (-not $OutputFolder) {
    $OutputFolder = Join-Path (Split-Path $EtlPath -Parent) 'etw_analysis_output'
}
if (-not (Test-Path $OutputFolder)) {
    New-Item -Path $OutputFolder -ItemType Directory -Force | Out-Null
}

Write-Host "[ModernStandby] Analyzing: $EtlPath" -ForegroundColor Cyan

$result = [PSCustomObject]@{
    AnalyzerName    = 'Modern Standby / Connected Standby Analysis'
    Summary         = ''
    Phases          = @()
    TopOffenders    = @()
    MetricName      = 'Active Time (ms)'
    Findings        = @()
    Recommendations = @()
    CsvFiles        = @()
    RawData         = $null
}

# ── Step 1: Try wpaexporter with Standby/ConnectedStandby profiles ──
$catalogPath = $config.CatalogPath
$standbyProfile = Join-Path $catalogPath 'Standby.wpaProfile'
$hibernateProfile = Join-Path $catalogPath 'Hibernate.wpaProfile'

$profilesToTry = @($standbyProfile, $hibernateProfile) | Where-Object { Test-Path $_ }

foreach ($wpaProfile in $profilesToTry) {
    $profileName = Split-Path $wpaProfile -Leaf
    Write-Host "[ModernStandby] Trying wpaexporter with: $profileName" -ForegroundColor Gray

    try {
        $exportResult = Export-EtwData -EtlPath $EtlPath -ProfilePath $wpaProfile -OutputFolder $OutputFolder -Prefix 'Standby_'
        if ($exportResult.CsvFiles.Count -gt 0) {
            $result.CsvFiles += $exportResult.CsvFiles
            Write-Host "[ModernStandby] Exported $($exportResult.CsvFiles.Count) CSV file(s) from $profileName" -ForegroundColor Green

            foreach ($csvFile in $exportResult.CsvFiles) {
                $data = Import-EtwCsv -CsvPath $csvFile -MaxRows 500
                if ($data.Count -eq 0) { continue }

                $columns = $data[0].PSObject.Properties.Name
                $componentCol = $columns | Where-Object { $_ -match 'Component|Device|Process|Name|Region' } | Select-Object -First 1
                $activeCol = $columns | Where-Object { $_ -match 'Active|Duration|Time|Count' } | Select-Object -First 1

                if ($componentCol -and $activeCol) {
                    $topItems = Find-TopOffenders -Data $data -GroupBy $componentCol -MetricColumn $activeCol -TopN 10
                    if ($topItems.Count -gt 0 -and $result.TopOffenders.Count -eq 0) {
                        $result.TopOffenders = $topItems
                    }
                }
            }
        }
    }
    catch {
        Write-Host "[ModernStandby] Export failed: $_" -ForegroundColor Yellow
    }
}

# Check findings against thresholds
foreach ($offender in $result.TopOffenders) {
    if ($offender.Value -gt 0) {
        $result.Findings += [PSCustomObject]@{
            Severity = 'Warning'
            Category = 'Standby Activator'
            Message  = "'$($offender.Name)' shows significant active time during standby: $($offender.Value)"
        }
    }
}

$result.Summary = "Modern Standby analysis completed. $($result.CsvFiles.Count) data file(s) exported, $($result.Findings.Count) findings."
$result.Recommendations += "Use WPA with Standby.wpaProfile for visual DRIPS residency analysis"
$result.Recommendations += "Check PDC phases for components preventing deep low-power states"
$result.Recommendations += "Review network activity and timer-based wakes during standby sessions"

Write-Host "[ModernStandby] Analysis complete." -ForegroundColor Cyan
return $result
