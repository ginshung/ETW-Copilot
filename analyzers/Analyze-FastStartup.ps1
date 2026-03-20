<#
.SYNOPSIS
    Analyzes Fast Startup (boot/shutdown/hibernate/resume) ETW traces.
.DESCRIPTION
    Uses xperf -a boot (XML output) for boot timing and services, then
    wpaexporter with FastStartup.wpaprofile for detailed Regions of Interest,
    CPU usage by process, Disk I/O by process, and process lifetimes.
#>

param(
    [Parameter(Mandatory)]
    [string]$EtlPath,

    [string]$OutputFolder
)

$ErrorActionPreference = 'Continue'

# Import modules
$moduleRoot = Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $moduleRoot 'EtwAnalysis.psm1') -Force -DisableNameChecking -Global

$config = Initialize-EtwEnvironment
$thresholds = Get-EtwThresholds

Write-Host "[FastStartup] Symbol path: $($env:_NT_SYMBOL_PATH)" -ForegroundColor Gray

if (-not $OutputFolder) {
    $OutputFolder = Join-Path (Split-Path $EtlPath -Parent) 'etw_analysis_output'
}
if (-not (Test-Path $OutputFolder)) {
    New-Item -Path $OutputFolder -ItemType Directory -Force | Out-Null
}

Write-Host "[FastStartup] Analyzing: $EtlPath" -ForegroundColor Cyan

$result = [PSCustomObject]@{
    AnalyzerName    = 'Fast Startup / Boot Analysis'
    Summary         = ''
    Phases          = @()
    TopOffenders    = @()
    MetricName      = 'CPU Weight (ms)'
    Findings        = @()
    Recommendations = @()
    CsvFiles        = @()
    RawData         = $null
    CsvData         = $null   # wpaexporter CSV tables
}

# ── Step 1: Run xperf -a boot for phase timing (XML output) ──
Write-Host "[FastStartup] Running xperf -a boot (this may take 30-60s)..." -ForegroundColor Gray
$bootAction = Invoke-XperfAction -EtlPath $EtlPath -Action 'boot'

if ($bootAction.Success -and $bootAction.Parsed) {
    $boot = $bootAction.Parsed
    $result.RawData = $boot

    # ── Boot Timing Summary ──
    $explorerMs = $boot.BootDoneViaExplorerMs
    $postBootMs = $boot.BootDoneViaPostBootMs
    $totalBootSec = [math]::Round($postBootMs / 1000, 2)

    # Check overall boot time against thresholds
    if ($totalBootSec -gt $thresholds.FastStartup.BootTotalSeconds.Critical) {
        $result.Findings += [PSCustomObject]@{
            Severity = 'Critical'
            Category = 'Boot Time'
            Message  = "Total boot time ${totalBootSec}s exceeds critical threshold ($($thresholds.FastStartup.BootTotalSeconds.Critical)s)"
        }
    } elseif ($totalBootSec -gt $thresholds.FastStartup.BootTotalSeconds.Warning) {
        $result.Findings += [PSCustomObject]@{
            Severity = 'Warning'
            Category = 'Boot Time'
            Message  = "Total boot time ${totalBootSec}s exceeds warning threshold ($($thresholds.FastStartup.BootTotalSeconds.Warning)s)"
        }
    }

    # ── Service Analysis (from xperf XML) ──
    if ($boot.TopServicesByTime -and $boot.TopServicesByTime.Count -gt 0) {
        $slowServices = $boot.TopServicesByTime | Where-Object {
            $_.TotalTimeMs -gt ($thresholds.FastStartup.ServiceDelaySeconds.Warning * 1000)
        }

        foreach ($svc in $slowServices) {
            $svcSec = [math]::Round($svc.TotalTimeMs / 1000, 2)
            $severity = if ($svcSec -gt $thresholds.FastStartup.ServiceDelaySeconds.Critical) { 'Critical' } else { 'Warning' }
            $result.Findings += [PSCustomObject]@{
                Severity = $severity
                Category = 'Slow Service'
                Message  = "Service '$($svc.Name)' ($($svc.Transition)) took ${svcSec}s (container: $($svc.Container))"
            }
            $result.Recommendations += "Service '$($svc.Name)' took ${svcSec}s during $($svc.Transition) - consider delayed start or investigate root cause"
        }
    }

    # ── PnP Device Analysis (from xperf XML) ──
    if ($boot.PnpDevices -and $boot.PnpDevices.Count -gt 0) {
        $slowPnp = $boot.PnpDevices | Where-Object { $_.DurationMs -gt 100 }
        foreach ($pnp in $slowPnp | Select-Object -First 5) {
            $pnpMs = $pnp.DurationMs
            if ($pnpMs -gt ($thresholds.Driver.DriverInitSeconds.Warning * 1000)) {
                $result.Findings += [PSCustomObject]@{
                    Severity = 'Warning'
                    Category = 'PnP Device'
                    Message  = "Device '$($pnp.Description)' PnP enumeration took ${pnpMs}ms"
                }
            }
        }
    }
} else {
    Write-Host "[FastStartup] xperf -a boot failed or returned no data" -ForegroundColor Yellow
}

# ── Step 2: wpaexporter with FastStartup profile for CSV data ──
$catalogPath = $config.CatalogPath
$fastStartupProfile = Join-Path $catalogPath 'FastStartup.wpaprofile'
$csvData = [PSCustomObject]@{
    Regions       = @()
    CpuByProcess  = @()
    DiskByProcess = @()
    Processes     = @()
    Memory        = @()
}

if (Test-Path $fastStartupProfile) {
    Write-Host "[FastStartup] Exporting data via wpaexporter..." -ForegroundColor Gray

    try {
        $exportResult = Export-EtwData -EtlPath $EtlPath -ProfilePath $fastStartupProfile -OutputFolder $OutputFolder -Prefix 'FS_'

        if ($exportResult.CsvFiles.Count -gt 0) {
            $result.CsvFiles = $exportResult.CsvFiles
            Write-Host "[FastStartup] Exported $($exportResult.CsvFiles.Count) CSV file(s)" -ForegroundColor Green

            # Parse each CSV type
            foreach ($csvFile in $exportResult.CsvFiles) {
                $csvName = Split-Path $csvFile -Leaf
                Write-Host "[FastStartup]   Parsing: $csvName" -ForegroundColor Gray

                if ($csvName -match 'Regions_of_Interest') {
                    $csvData.Regions = Import-EtwCsv -CsvPath $csvFile
                }
                elseif ($csvName -match 'CPU_Usage.*Sampled.*Process') {
                    $csvData.CpuByProcess = Import-EtwCsv -CsvPath $csvFile
                }
                elseif ($csvName -match 'Disk_Summary') {
                    $csvData.DiskByProcess = Import-EtwCsv -CsvPath $csvFile
                }
                elseif ($csvName -match 'Processes_Lifetime') {
                    $csvData.Processes = Import-EtwCsv -CsvPath $csvFile
                }
                elseif ($csvName -match 'Memory_Utilization') {
                    $csvData.Memory = Import-EtwCsv -CsvPath $csvFile
                }
            }
        } else {
            Write-Host "[FastStartup] wpaexporter produced no CSV files" -ForegroundColor Yellow
        }
    }
    catch {
        Write-Host "[FastStartup] wpaexporter failed: $_" -ForegroundColor Yellow
    }
}

$result.CsvData = $csvData

# ── Step 3: Build phase hierarchy from Regions CSV ──
if ($csvData.Regions -and $csvData.Regions.Count -gt 0) {
    # Build a clean phase hierarchy (deduplicate, filter zero-duration entries)
    $seenPhases = @{}
    $phases = @()
    foreach ($region in $csvData.Regions) {
        $regionName = $region.Region
        if (-not $regionName) { continue }

        # Get duration
        $durationSec = 0
        $durProp = $region.PSObject.Properties | Where-Object { $_.Name -match 'Duration' } | Select-Object -First 1
        if ($durProp) { $durationSec = [double]$durProp.Value }

        # Skip zero-duration duplicate entries
        if ($durationSec -le 0.0001) { continue }

        # Deduplicate by full region path — keep the first occurrence
        if ($seenPhases.ContainsKey($regionName)) { continue }
        $seenPhases[$regionName] = $true

        # Calculate depth from backslash separators
        $depth = ($regionName.ToCharArray() | Where-Object { $_ -eq '\' }).Count
        $shortName = if ($regionName -match '\\([^\\]+)$') { $matches[1] } else { $regionName }

        $durationMs = [math]::Round($durationSec * 1000, 0)
        $status = 'OK'
        if ($durationMs -gt 10000) { $status = 'SLOW' }
        if ($durationMs -gt 20000) { $status = 'CRITICAL' }

        $phases += [PSCustomObject]@{
            Name       = $shortName
            FullPath   = $regionName
            Depth      = $depth
            DurationMs = $durationMs
            DurationS  = [math]::Round($durationSec, 3)
            Status     = $status
        }
    }

    # Replace xperf phases with the richer Regions data
    $result.Phases = $phases
}

# ── Step 4: Build CPU top processes from wpaexporter CSV ──
if ($csvData.CpuByProcess -and $csvData.CpuByProcess.Count -gt 0) {
    # Find the weight column (may have different names)
    $weightCol = $csvData.CpuByProcess[0].PSObject.Properties.Name | Where-Object { $_ -match 'Weight' } | Select-Object -First 1

    if ($weightCol) {
        $cpuProcs = $csvData.CpuByProcess |
            Where-Object { $_.Process -and $_.Process -notmatch '^Idle' -and $_.$weightCol -gt 0 } |
            Sort-Object { $_.$weightCol } -Descending |
            Select-Object -First 15

        $topCpu = @()
        foreach ($proc in $cpuProcs) {
            $topCpu += [PSCustomObject]@{
                Name  = $proc.Process
                Value = [math]::Round($_.$weightCol, 1)
                Count = if ($proc.Count) { [int]$proc.Count } else { 1 }
            }
        }

        # Fix: re-read the weight properly
        $topCpu = @()
        foreach ($proc in $cpuProcs) {
            $weight = [double]$proc.$weightCol
            $topCpu += [PSCustomObject]@{
                Name  = $proc.Process
                Value = [math]::Round($weight, 1)
                Count = if ($proc.Count) { [int]$proc.Count } else { 1 }
            }
        }

        if ($topCpu.Count -gt 0) {
            $result.TopOffenders = $topCpu
        }
    }
}

# Fall back to xperf CPU data if wpaexporter didn't provide it
if ($result.TopOffenders.Count -eq 0 -and $result.RawData -and $result.RawData.TopProcessesByCpu) {
    $boot = $result.RawData
    if ($boot.TopProcessesByCpu.Count -gt 0) {
        $procCpu = $boot.TopProcessesByCpu |
            Group-Object ProcessName |
            ForEach-Object {
                [PSCustomObject]@{
                    Name  = $_.Name
                    Value = ($_.Group | Measure-Object -Property CpuTimeMs -Sum).Sum
                    Count = $_.Count
                }
            } |
            Sort-Object Value -Descending |
            Select-Object -First 10
        $result.TopOffenders = $procCpu
    }
}

# ── Step 5: Analyze disk I/O by process ──
if ($csvData.DiskByProcess -and $csvData.DiskByProcess.Count -gt 0) {
    # Find the Size column
    $sizeCol = $csvData.DiskByProcess[0].PSObject.Properties.Name | Where-Object { $_ -match 'Size' } | Select-Object -First 1
    $diskSvcCol = $csvData.DiskByProcess[0].PSObject.Properties.Name | Where-Object { $_ -match 'Disk Service' } | Select-Object -First 1

    if ($sizeCol) {
        $topDiskProcesses = $csvData.DiskByProcess |
            Where-Object { $_.Process -and $_.$sizeCol -gt 0 } |
            Sort-Object { $_.$sizeCol } -Descending |
            Select-Object -First 5

        foreach ($dp in $topDiskProcesses) {
            $sizeMB = [math]::Round([double]$dp.$sizeCol / 1MB, 2)
            if ($sizeMB -gt 50) {
                $result.Findings += [PSCustomObject]@{
                    Severity = 'Info'
                    Category = 'Disk I/O'
                    Message  = "Process '$($dp.Process)' performed ${sizeMB} MB of disk I/O during boot"
                }
            }
        }
    }
}

# ── Step 6: Generate recommendations ──
if ($result.Phases.Count -gt 0) {
    $slowPhases = $result.Phases | Where-Object { $_.DurationMs -gt 5000 -and $_.Depth -ge 1 } | Sort-Object DurationMs -Descending
    foreach ($phase in $slowPhases | Select-Object -First 3) {
        $result.Recommendations += "Phase '$($phase.Name)' took $([math]::Round($phase.DurationMs / 1000, 1))s - investigate processes active during this phase"
    }
}

if ($result.TopOffenders.Count -gt 0) {
    foreach ($p in $result.TopOffenders | Select-Object -First 3) {
        $result.Recommendations += "Process '$($p.Name)' consumed $($p.Value)ms CPU during boot"
    }
}

# Cross-reference with known issues
$knownIssuesFile = Join-Path $moduleRoot 'knowledge\known-issues.json'
if (Test-Path $knownIssuesFile) {
    $knownIssues = Get-Content $knownIssuesFile -Raw | ConvertFrom-Json
    $allNames = ($result.TopOffenders | ForEach-Object { $_.Name }) -join ' '
    foreach ($ki in $knownIssues.patterns) {
        if ($allNames -match $ki.pattern) {
            $result.Recommendations += "[$($ki.category)] $($ki.recommendation)"
        }
    }
}

$result.Recommendations += "Open in WPA: wpa.exe `"$EtlPath`" -profile `"$fastStartupProfile`""

Write-Host "[FastStartup] Analysis complete." -ForegroundColor Cyan
return $result
