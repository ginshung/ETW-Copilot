<#
.SYNOPSIS
    ETW Auto-Analysis Toolset - Main Entry Point
.DESCRIPTION
    Analyzes ETW trace files (.etl) and produces a structured Markdown report
    identifying performance issues, root causes, and recommendations.

    Designed for use with VS Code Copilot via terminal execution.

.PARAMETER EtlPath
    Path to the .etl trace file to analyze.

.PARAMETER AnalysisType
    Type of analysis to perform. Default is 'Auto' which auto-detects based on trace content.
    Options: Auto, FastStartup, Cpu, DiskIO, Driver, AppResponsiveness, Memory, ModernStandby, All

.PARAMETER OutputPath
    Directory for report and CSV output. Default: <etl_dir>\etw_analysis_output\

.PARAMETER ReportFile
    Path to save the Markdown report. Default: <OutputPath>\EtwReport_<timestamp>.md

.EXAMPLE
    .\Invoke-EtwAnalysis.ps1 -EtlPath "C:\traces\boot.etl"

.EXAMPLE
    .\Invoke-EtwAnalysis.ps1 -EtlPath "C:\traces\boot.etl" -AnalysisType FastStartup

.EXAMPLE
    .\Invoke-EtwAnalysis.ps1 -EtlPath "C:\traces\perf.etl" -AnalysisType All -Verbose

.EXAMPLE
    .\Invoke-EtwAnalysis.ps1 -EtlPath "C:\traces\boot.etl" -Reason "Slow boot after BIOS update"
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory, Position = 0)]
    [ValidateScript({ Test-Path $_ })]
    [string]$EtlPath,

    [Parameter(Position = 1)]
    [ValidateSet('Auto', 'FastStartup', 'Cpu', 'DiskIO', 'Driver', 'AppResponsiveness', 'Memory', 'ModernStandby', 'All')]
    [string]$AnalysisType = 'Auto',

    [string]$OutputPath,

    [string]$ReportFile,

    # Free-text reason for this analysis — recorded in investigation_log.md and the report
    [string]$Reason = ''
)

$ErrorActionPreference = 'Continue'
$scriptRoot = $PSScriptRoot

# ════════════════════════════════════════════════
# Initialize
# ════════════════════════════════════════════════
Write-Host "═══════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host "  ETW Auto-Analysis Toolset (etw-copilot)" -ForegroundColor Cyan
Write-Host "═══════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host ""

# Import root module
Import-Module (Join-Path $scriptRoot 'EtwAnalysis.psm1') -Force -DisableNameChecking -Global

# Initialize environment (proxy, symbols, validate tools)
$config = Initialize-EtwEnvironment

# Resolve paths
$EtlPath = Resolve-Path $EtlPath | Select-Object -ExpandProperty Path

if (-not $OutputPath) {
    $OutputPath = Join-Path (Split-Path $EtlPath -Parent) 'etw_analysis_output'
}
if (-not (Test-Path $OutputPath)) {
    New-Item -Path $OutputPath -ItemType Directory -Force | Out-Null
}

if (-not $ReportFile) {
    $timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    $etlName = [System.IO.Path]::GetFileNameWithoutExtension($EtlPath)
    $ReportFile = Join-Path $OutputPath "EtwReport_${etlName}_${timestamp}.md"
}

Write-Host "ETL File    : $EtlPath" -ForegroundColor White
Write-Host "Output Dir  : $OutputPath" -ForegroundColor White
Write-Host "Analysis    : $AnalysisType" -ForegroundColor White
Write-Host ""

# ════════════════════════════════════════════════
# Step 1: Detect trace type
# ════════════════════════════════════════════════
Write-Host "[1/4] Detecting trace type..." -ForegroundColor Yellow
$traceInfo = Get-TraceInfo -EtlPath $EtlPath

Write-Host "  File Size       : $($traceInfo.FileSizeMB) MB" -ForegroundColor Gray
Write-Host "  Trace Type      : $($traceInfo.TraceType)" -ForegroundColor Gray
Write-Host "  Duration        : $(if ($traceInfo.Duration) { "$([math]::Round($traceInfo.Duration, 2))s" } else { 'N/A' })" -ForegroundColor Gray
Write-Host "  Events Lost     : $($traceInfo.EventsLost)" -ForegroundColor $(if ($traceInfo.EventsLost -gt 0) { 'Red' } else { 'Gray' })
Write-Host "  Capabilities    : $($traceInfo.Providers -join ', ')" -ForegroundColor Gray
Write-Host "  Recommended     : $($traceInfo.RecommendedAnalyzers -join ', ')" -ForegroundColor Gray
Write-Host ""

# ════════════════════════════════════════════════
# Step 2: Determine which analyzers to run
# ════════════════════════════════════════════════
Write-Host "[2/4] Selecting analyzers..." -ForegroundColor Yellow

$analyzerMap = @{
    'FastStartup'       = 'Analyze-FastStartup.ps1'
    'Cpu'               = 'Analyze-CpuPerformance.ps1'
    'DiskIO'            = 'Analyze-DiskIO.ps1'
    'Driver'            = 'Analyze-Drivers.ps1'
    'AppResponsiveness' = 'Analyze-AppResponsiveness.ps1'
    'Memory'            = 'Analyze-Memory.ps1'
    'ModernStandby'     = 'Analyze-ModernStandby.ps1'
}

$analyzersToRun = @()

if ($AnalysisType -eq 'Auto') {
    $analyzersToRun = $traceInfo.RecommendedAnalyzers
    Write-Host "  Auto-detected: $($analyzersToRun -join ', ')" -ForegroundColor Gray
}
elseif ($AnalysisType -eq 'All') {
    $analyzersToRun = $analyzerMap.Keys
    Write-Host "  Running all analyzers" -ForegroundColor Gray
}
else {
    $analyzersToRun = @($AnalysisType)
    Write-Host "  Running: $AnalysisType" -ForegroundColor Gray
}

Write-Host ""

# ════════════════════════════════════════════════
# Step 3: Run selected analyzers
# ════════════════════════════════════════════════
Write-Host "[3/4] Running analysis..." -ForegroundColor Yellow
Write-Host ""

$analysisResults = @()
$analyzerIndex = 0

foreach ($analyzerName in $analyzersToRun) {
    $analyzerIndex++
    $scriptName = $analyzerMap[$analyzerName]

    if (-not $scriptName) {
        Write-Host "  Unknown analyzer: $analyzerName" -ForegroundColor Red
        continue
    }

    $scriptPath = Join-Path $scriptRoot "analyzers\$scriptName"

    if (-not (Test-Path $scriptPath)) {
        Write-Host "  Analyzer script not found: $scriptPath" -ForegroundColor Red
        continue
    }

    Write-Host "  [$analyzerIndex/$($analyzersToRun.Count)] Running $analyzerName..." -ForegroundColor White

    try {
        $analyzerResult = & $scriptPath -EtlPath $EtlPath -OutputFolder $OutputPath
        if ($analyzerResult) {
            $analysisResults += $analyzerResult
        }
    }
    catch {
        Write-Host "  ERROR in $analyzerName : $_" -ForegroundColor Red
        $analysisResults += [PSCustomObject]@{
            AnalyzerName    = $analyzerName
            Summary         = "Analyzer failed with error: $_"
            Phases          = @()
            TopOffenders    = @()
            MetricName      = ''
            Findings        = @([PSCustomObject]@{
                Severity = 'Warning'
                Category = 'Analyzer Error'
                Message  = "The $analyzerName analyzer encountered an error: $_"
            })
            Recommendations = @("Re-run with -Verbose for more details")
            CsvFiles        = @()
            RawData         = $null
        }
    }

    Write-Host ""
}

# ════════════════════════════════════════════════
# Step 4: Generate report
# ════════════════════════════════════════════════
Write-Host "[4/5] Generating report..." -ForegroundColor Yellow

$report = Format-EtwReport -TraceInfo $traceInfo -AnalysisResults $analysisResults -OutputPath $ReportFile

Write-Host ""
Write-Host "═══════════════════════════════════════════════════" -ForegroundColor Green
Write-Host "  Analysis Complete!" -ForegroundColor Green
Write-Host "═══════════════════════════════════════════════════" -ForegroundColor Green
Write-Host "Report saved: $ReportFile" -ForegroundColor White
Write-Host ""

# ════════════════════════════════════════════════
# Step 5: Consolidate learnings → knowledge base
# ════════════════════════════════════════════════
Write-Host "[5/5] Consolidating learnings into knowledge base..." -ForegroundColor Yellow

$knowledgePath = Join-Path $scriptRoot 'knowledge'
$consolidation = Consolidate-Learnings `
    -AnalysisResults $analysisResults `
    -TraceInfo       $traceInfo `
    -EtlPath         $EtlPath `
    -OutputPath      $OutputPath `
    -Reason          $Reason `
    -KnowledgePath   $knowledgePath

Write-Host ""
Write-Host "Investigation log : $($consolidation.InvestigationLog)" -ForegroundColor White
Write-Host "Learnings file    : $($consolidation.LearningsFile)"    -ForegroundColor White
if ($consolidation.NewPatternsAdded -gt 0) {
    Write-Host "New patterns added to knowledge base: $($consolidation.NewPatternsAdded)" -ForegroundColor Cyan
}
Write-Host ""

# Output the report to stdout so Copilot can read it
Write-Host "───────────────────────────────────────────────────" -ForegroundColor DarkGray
Write-Output $report
Write-Host "───────────────────────────────────────────────────" -ForegroundColor DarkGray
