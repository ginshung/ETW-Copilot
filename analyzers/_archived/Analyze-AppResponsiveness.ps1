<#
.SYNOPSIS
    Analyzes app responsiveness from ETW traces - UI delays, app launch, rendering.
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

Write-Host "[AppResp] Symbol path: $($env:_NT_SYMBOL_PATH)" -ForegroundColor Gray

if (-not $OutputFolder) {
    $OutputFolder = Join-Path (Split-Path $EtlPath -Parent) 'etw_analysis_output'
}
if (-not (Test-Path $OutputFolder)) {
    New-Item -Path $OutputFolder -ItemType Directory -Force | Out-Null
}

Write-Host "[AppResp] Analyzing: $EtlPath" -ForegroundColor Cyan

$result = [PSCustomObject]@{
    AnalyzerName    = 'App Responsiveness Analysis'
    Summary         = ''
    Phases          = @()
    TopOffenders    = @()
    MetricName      = 'Duration (ms)'
    Findings        = @()
    Recommendations = @()
    CsvFiles        = @()
    RawData         = $null
}

# Try AppLaunch profile from catalog
$catalogPath = $config.CatalogPath
$appLaunchProfile = Join-Path $catalogPath 'AppLaunch.wpaProfile'
$htmlProfile = Join-Path $catalogPath 'HtmlResponsivenessAnalysis.wpaprofile'
$xamlProfile = Join-Path $catalogPath 'XamlAppResponsivenessAnalysis.wpaprofile'

$profilesToTry = @($appLaunchProfile, $htmlProfile, $xamlProfile) | Where-Object { Test-Path $_ }

foreach ($wpaProfile in $profilesToTry) {
    $profileName = Split-Path $wpaProfile -Leaf
    Write-Host "[AppResp] Trying wpaexporter with: $profileName" -ForegroundColor Gray

    try {
        $exportResult = Export-EtwData -EtlPath $EtlPath -ProfilePath $wpaProfile -OutputFolder $OutputFolder -Prefix 'AppResp_'
        if ($exportResult.CsvFiles.Count -gt 0) {
            $result.CsvFiles += $exportResult.CsvFiles
            Write-Host "[AppResp] Exported $($exportResult.CsvFiles.Count) CSV file(s) from $profileName" -ForegroundColor Green

            foreach ($csvFile in $exportResult.CsvFiles) {
                $data = Import-EtwCsv -CsvPath $csvFile -MaxRows 500
                if ($data.Count -eq 0) { continue }

                $columns = $data[0].PSObject.Properties.Name
                $processCol = $columns | Where-Object { $_ -match 'Process|App' } | Select-Object -First 1
                $durationCol = $columns | Where-Object { $_ -match 'Duration|Time|Delay|ms' } | Select-Object -First 1

                if ($processCol -and $durationCol) {
                    $topItems = Find-TopOffenders -Data $data -GroupBy $processCol -MetricColumn $durationCol -TopN 10
                    if ($topItems.Count -gt 0 -and $result.TopOffenders.Count -eq 0) {
                        $result.TopOffenders = $topItems
                    }
                }
            }
        }
    }
    catch {
        Write-Host "[AppResp] Export failed: $_" -ForegroundColor Yellow
    }
}

# Check top offenders for UI hang thresholds
foreach ($offender in $result.TopOffenders) {
    if ($offender.Value -gt $thresholds.AppResponsiveness.UIHangMs.Critical) {
        $result.Findings += [PSCustomObject]@{
            Severity = 'Critical'
            Category = 'UI Responsiveness'
            Message  = "'$($offender.Name)' has UI delay/duration of $($offender.Value)ms (critical: $($thresholds.AppResponsiveness.UIHangMs.Critical)ms)"
        }
    } elseif ($offender.Value -gt $thresholds.AppResponsiveness.UIHangMs.Warning) {
        $result.Findings += [PSCustomObject]@{
            Severity = 'Warning'
            Category = 'UI Responsiveness'
            Message  = "'$($offender.Name)' has UI delay/duration of $($offender.Value)ms (warning: $($thresholds.AppResponsiveness.UIHangMs.Warning)ms)"
        }
    }
}

$result.Summary = "App responsiveness analysis completed. $($result.CsvFiles.Count) data file(s) exported, $($result.Findings.Count) findings."
$result.Recommendations += "Use WPA with HtmlResponsivenessAnalysis or XamlAppResponsivenessAnalysis profile for visual drill-down"
$result.Recommendations += "Check UI thread stacks for lock contention using Wait Analysis view"

Write-Host "[AppResp] Analysis complete." -ForegroundColor Cyan
return $result
