<#
.SYNOPSIS
    Detects ETW trace type and metadata using lightweight heuristics.
.DESCRIPTION
    Uses file name patterns and file size to recommend appropriate analyzers.
    Avoids calling xperf -i which can be extremely slow on large ETL files.
#>

function Get-TraceInfo {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$EtlPath,

        [string]$XperfExe
    )

    if (-not (Test-Path $EtlPath)) {
        throw "ETL file not found: $EtlPath"
    }

    $fileInfo = Get-Item $EtlPath
    $fileName = $fileInfo.Name.ToLower()
    $fileSizeMB = [math]::Round($fileInfo.Length / 1MB, 2)

    $info = [PSCustomObject]@{
        EtlPath              = $EtlPath
        FileSizeMB           = $fileSizeMB
        TraceType            = 'Unknown'
        RecommendedAnalyzers = @()
        Duration             = $null
        StartTime            = $null
        EndTime              = $null
        EventsLost           = 0
        BuffersLost          = 0
        Providers            = @()
        HasBootData          = $false
        HasCpuSampling       = $false
        HasDiskIO            = $false
        HasMemory            = $false
        HasCSwitch           = $false
        HasDpcIsr            = $false
        HasStandbyData       = $false
        RawOutput            = ''
    }

    # ── Heuristic detection based on filename ──
    $analyzers = @()

    # Boot / Fast Startup traces
    if ($fileName -match 'boot|startup|faststartup|onoff|shutdown|hibernate|resume|hiberboot') {
        $info.TraceType = 'Boot'
        $info.HasBootData = $true
        $analyzers += 'FastStartup'
        $info.Providers += 'Boot/Shutdown'
        $info.Providers += 'Winlogon'
    }

    # Standby / Connected Standby / Modern Standby
    if ($fileName -match 'standby|sleep|drips|cs_|connected') {
        $info.TraceType = 'ModernStandby'
        $info.HasStandbyData = $true
        $analyzers += 'ModernStandby'
        $info.Providers += 'Standby'
    }

    # General performance traces typically have CPU, Disk, Memory
    if ($fileName -match 'perf|general|cpu|sample|profile') {
        $info.TraceType = 'Performance'
        $info.HasCpuSampling = $true
        $info.HasCSwitch = $true
        $analyzers += 'Cpu'
    }

    if ($fileName -match 'disk|io|storage') {
        $info.HasDiskIO = $true
        $analyzers += 'DiskIO'
    }

    if ($fileName -match 'mem|heap|pool|workingset|pagefault') {
        $info.HasMemory = $true
        $analyzers += 'Memory'
    }

    if ($fileName -match 'dpc|isr|driver|interrupt|latency') {
        $info.HasDpcIsr = $true
        $analyzers += 'Driver'
    }

    if ($fileName -match 'app|launch|responsive|ui|xaml|html') {
        $analyzers += 'AppResponsiveness'
    }

    # If we matched boot, also assume common boot trace capabilities
    if ($info.HasBootData) {
        $info.HasCpuSampling = $true
        $info.HasDiskIO = $true
        $info.HasMemory = $true
        $info.HasDpcIsr = $true
        $info.Providers += @('CpuSampling', 'DiskIO', 'Memory', 'DpcIsr')
        # Boot traces often have all data — add supplementary analyzers
        if ('Cpu' -notin $analyzers)    { $analyzers += 'Cpu' }
        if ('DiskIO' -notin $analyzers) { $analyzers += 'DiskIO' }
        if ('Driver' -notin $analyzers) { $analyzers += 'Driver' }
    }

    # For unknown type, recommend running all analyzers
    if ($analyzers.Count -eq 0) {
        $info.TraceType = 'General'
        $info.HasCpuSampling = $true
        $info.HasDiskIO = $true
        $info.HasMemory = $true
        $info.HasDpcIsr = $true
        $info.Providers += @('CpuSampling', 'DiskIO', 'Memory', 'DpcIsr')
        $analyzers = @('FastStartup', 'Cpu', 'DiskIO', 'Driver', 'Memory')
    }

    $info.RecommendedAnalyzers = $analyzers
    $info.RawOutput = "Trace type detected via filename heuristics. File: $fileName, Size: ${fileSizeMB}MB"

    Write-Verbose "Trace type: $($info.TraceType), Recommended: $($analyzers -join ', ')"

    return $info
}

Export-ModuleMember -Function 'Get-TraceInfo'
