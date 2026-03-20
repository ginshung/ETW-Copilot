<#
.SYNOPSIS
    Wraps xperf.exe -a (action) commands for quick ETW trace analysis.
.DESCRIPTION
    Runs xperf built-in analysis actions and parses their XML/text output into
    structured PowerShell objects. xperf -a boot/shutdown outputs XML.
#>

function Invoke-XperfAction {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$EtlPath,

        [Parameter(Mandatory)]
        [ValidateSet('boot','shutdown','dpcisr','diskio','filename','hardfault','cpudisk','registry','drivers','services')]
        [string]$Action,

        [string[]]$ExtraArgs = @(),

        [string]$XperfExe
    )

    if (-not (Test-Path $EtlPath)) {
        throw "ETL file not found: $EtlPath"
    }

    if (-not $XperfExe) {
        $config = Get-EtwConfig
        $XperfExe = $config.XperfExe
    }

    # Add -symbols flag for actions that benefit from symbol resolution
    $symbolActions = @('dpcisr', 'cpudisk', 'hardfault', 'filename')
    $useSymbols = $symbolActions -contains $Action

    if ($useSymbols) {
        Write-Verbose "Running: xperf -i `"$EtlPath`" -symbols -a $Action (symbol resolution enabled)"
    } else {
        Write-Verbose "Running: xperf -i `"$EtlPath`" -a $Action"
    }

    try {
        # Capture stdout separately from stderr
        # Pass -symbols for actions that resolve stack addresses to function names
        if ($useSymbols) {
            $output = & $XperfExe -i $EtlPath -symbols -a $Action @ExtraArgs 2>$null | Out-String
        } else {
            $output = & $XperfExe -i $EtlPath -a $Action @ExtraArgs 2>$null | Out-String
        }
    }
    catch {
        Write-Warning "xperf -a $Action failed: $_"
        return [PSCustomObject]@{
            Action    = $Action
            Success   = $false
            RawOutput = ''
            Parsed    = $null
            Error     = $_.ToString()
        }
    }

    # Parse based on action type
    $parsed = $null

    switch ($Action) {
        'boot' {
            $parsed = Parse-BootXml $output
        }
        'shutdown' {
            $parsed = Parse-BootXml $output
        }
        default {
            $parsed = $output
        }
    }

    return [PSCustomObject]@{
        Action    = $Action
        Success   = $true
        RawOutput = $output
        Parsed    = $parsed
        Error     = $null
    }
}

function Parse-BootXml {
    param([string]$Output)

    $result = [PSCustomObject]@{
        BootDoneViaExplorerMs = 0
        BootDoneViaPostBootMs = 0
        OSLoaderDurationMs    = 0
        Intervals             = @()
        TopProcessesByCpu     = @()
        TopServicesByTime     = @()
        PnpDevices            = @()
        DiskIO                = $null
        Phases                = @()
        TotalTimeMs           = 0
    }

    # Try to parse as XML
    try {
        $xml = [xml]$Output
        $boot = $xml.results.boot

        if (-not $boot) {
            Write-Verbose "No <boot> element found in xperf output"
            return $result
        }

        # Timing summary
        if ($boot.timing) {
            $result.BootDoneViaExplorerMs = [int]($boot.timing.bootDoneViaExplorer)
            $result.BootDoneViaPostBootMs = [int]($boot.timing.bootDoneViaPostBoot)
            $result.OSLoaderDurationMs    = [int]($boot.timing.OSLoaderDuration)
            $result.TotalTimeMs           = $result.BootDoneViaPostBootMs
        }

        # Intervals (boot phases)
        if ($boot.interval) {
            foreach ($interval in @($boot.interval)) {
                $phase = [PSCustomObject]@{
                    Name       = $interval.name
                    StartTime  = [int]($interval.startTime)
                    EndTime    = [int]($interval.endTime)
                    DurationMs = [int]($interval.duration)
                }
                $result.Intervals += $phase
                $result.Phases += [PSCustomObject]@{
                    Name       = $interval.name
                    DurationMs = [int]($interval.duration)
                    Status     = 'OK'
                }

                # Extract per-process CPU usage from each interval
                if ($interval.perProcess -and $interval.perProcess.perProcessCPUUsage) {
                    foreach ($proc in @($interval.perProcess.perProcessCPUUsage)) {
                        if ($proc.name -eq 'Idle') { continue }
                        $result.TopProcessesByCpu += [PSCustomObject]@{
                            Phase          = $interval.name
                            ProcessName    = $proc.name
                            CpuTimeMs      = [int]($proc.time)
                            PercentOfPhase = [double]($proc.percentOfInterval)
                        }
                    }
                }
            }
        }

        # Services
        if ($boot.services -and $boot.services.serviceTransition) {
            foreach ($svc in @($boot.services.serviceTransition)) {
                $result.TopServicesByTime += [PSCustomObject]@{
                    Name            = $svc.name
                    Transition      = $svc.transition
                    TotalTimeMs     = [int]($svc.totalTransitionTimeDelta)
                    ProcessingTimeMs = [int]($svc.processingTimeDelta)
                    Container       = $svc.container
                }
            }
            $result.TopServicesByTime = $result.TopServicesByTime | Sort-Object TotalTimeMs -Descending
        }

        # PnP devices
        if ($boot.pnp -and $boot.pnp.phase) {
            foreach ($phase in @($boot.pnp.phase)) {
                if ($phase.pnpObject) {
                    foreach ($pnp in @($phase.pnpObject)) {
                        $result.PnpDevices += [PSCustomObject]@{
                            DeviceId    = $pnp.name
                            Description = $pnp.description
                            FriendlyName = $pnp.friendlyName
                            DurationMs  = [int]($pnp.duration)
                            Activity    = $pnp.activity
                        }
                    }
                }
            }
            $result.PnpDevices = $result.PnpDevices | Sort-Object DurationMs -Descending
        }

        # Overall disk IO from first interval that has it
        if ($boot.interval) {
            foreach ($interval in @($boot.interval)) {
                if ($interval.diskIO) {
                    $dio = $interval.diskIO
                    $result.DiskIO = [PSCustomObject]@{
                        Phase      = $interval.name
                        ReadBytes  = [long]($dio.readBytes)
                        ReadOps    = [int]($dio.readOps)
                        WriteBytes = [long]($dio.writeBytes)
                        WriteOps   = [int]($dio.writeOps)
                        TotalBytes = [long]($dio.totalBytes)
                        TotalOps   = [int]($dio.totalOps)
                    }
                    break
                }
            }
        }

    }
    catch {
        Write-Warning "Failed to parse xperf boot XML: $_"
    }

    return $result
}

Export-ModuleMember -Function 'Invoke-XperfAction'
