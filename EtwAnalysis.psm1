<#
.SYNOPSIS
    ETW Auto-Analysis Toolset - Root Module
.DESCRIPTION
    Provides automated ETW trace analysis for boot performance, CPU, disk I/O,
    driver analysis, app responsiveness, memory, and Modern Standby scenarios.
    Designed for VS Code Copilot integration via CLI.
#>

# Module root path
$script:ModuleRoot = $PSScriptRoot

# Load configuration
function Get-EtwConfig {
    [CmdletBinding()]
    param()
    $settingsPath = Join-Path $script:ModuleRoot 'config\settings.json'
    if (-not (Test-Path $settingsPath)) {
        throw "Settings file not found: $settingsPath"
    }
    $script:Config = Get-Content $settingsPath -Raw | ConvertFrom-Json
    return $script:Config
}

function Get-EtwThresholds {
    [CmdletBinding()]
    param()
    $threshPath = Join-Path $script:ModuleRoot 'config\thresholds.json'
    if (-not (Test-Path $threshPath)) {
        throw "Thresholds file not found: $threshPath"
    }
    $script:Thresholds = Get-Content $threshPath -Raw | ConvertFrom-Json
    return $script:Thresholds
}

function Initialize-EtwEnvironment {
    [CmdletBinding()]
    param()

    $config = Get-EtwConfig

    # Set proxy environment variables FIRST — required before any symbol downloads
    if ($config.Proxy) {
        if ($config.Proxy.HttpProxy)  { $env:http_proxy  = $config.Proxy.HttpProxy }
        if ($config.Proxy.HttpsProxy) { $env:https_proxy = $config.Proxy.HttpsProxy }
        if ($config.Proxy.NoProxy)    { $env:no_proxy    = $config.Proxy.NoProxy }
        Write-Host "[Init] Proxy configured: $($config.Proxy.HttpProxy)" -ForegroundColor Gray
    }

    # Set symbol path and ensure all cache directories exist
    if ($config.SymbolPath) {
        $env:_NT_SYMBOL_PATH = $config.SymbolPath
        # Extract ALL local cache paths from srv*<cache>*<server> segments and create if needed
        $segments = $config.SymbolPath -split ';'
        foreach ($seg in $segments) {
            if ($seg -match 'srv\*([^*]+)\*') {
                $symCacheDir = $Matches[1]
                if (-not (Test-Path $symCacheDir)) {
                    New-Item -Path $symCacheDir -ItemType Directory -Force | Out-Null
                    Write-Host "[Init] Created symbol cache directory: $symCacheDir" -ForegroundColor Gray
                }
            }
        }
        Write-Host "[Init] Symbol path: $($env:_NT_SYMBOL_PATH)" -ForegroundColor Gray
    }

    # Validate WPT tools exist
    $tools = @($config.WpaExporterExe, $config.XperfExe)
    foreach ($tool in $tools) {
        if (-not (Test-Path $tool)) {
            Write-Warning "WPT tool not found: $tool"
        }
    }

    Write-Verbose "ETW environment initialized. Symbol path: $($env:_NT_SYMBOL_PATH)"
    return $config
}

# Dot-source all module files
$moduleFiles = @(
    'modules\Get-TraceInfo.psm1',
    'modules\Export-EtwData.psm1',
    'modules\Invoke-XperfAction.psm1',
    'modules\Parse-CsvResults.psm1',
    'modules\Format-Report.psm1',
    'modules\Consolidate-Learnings.psm1'
)

foreach ($mf in $moduleFiles) {
    $fullPath = Join-Path $script:ModuleRoot $mf
    if (Test-Path $fullPath) {
        Import-Module $fullPath -Force -DisableNameChecking -Global
    }
}

# Export functions
Export-ModuleMember -Function @(
    'Get-EtwConfig',
    'Get-EtwThresholds',
    'Initialize-EtwEnvironment',
    'Get-TraceInfo',
    'Export-EtwData',
    'Invoke-XperfAction',
    'Import-EtwCsv',
    'Find-TopOffenders',
    'Format-EtwReport',
    'Consolidate-Learnings'
)
