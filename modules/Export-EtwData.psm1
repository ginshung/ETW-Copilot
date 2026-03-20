<#
.SYNOPSIS
    Wraps wpaexporter.exe for automated CSV/XML data extraction from ETL files.
.DESCRIPTION
    Uses the wpaexporter CLI (-i, -profile, -outputfolder, ...) to extract
    table data from ETL traces using WPA profile files.
#>

function Export-EtwData {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$EtlPath,

        [Parameter(Mandatory)]
        [string]$ProfilePath,

        [string]$OutputFolder,
        [string]$RangeStart,
        [string]$RangeEnd,
        [string]$Format = 'CSV',
        [string]$Prefix = '',
        [string]$WpaExporterExe
    )

    if (-not (Test-Path $EtlPath)) {
        throw "ETL file not found: $EtlPath"
    }

    if (-not (Test-Path $ProfilePath)) {
        throw "Profile file not found: $ProfilePath"
    }

    if (-not $WpaExporterExe) {
        $config = Get-EtwConfig
        $WpaExporterExe = $config.WpaExporterExe
    }

    if (-not $OutputFolder) {
        $OutputFolder = Join-Path (Split-Path $EtlPath -Parent) 'etw_analysis_output'
    }

    if (-not (Test-Path $OutputFolder)) {
        New-Item -Path $OutputFolder -ItemType Directory -Force | Out-Null
    }

    # Build CLI arguments
    $args = @(
        '-i', "`"$EtlPath`""
        '-profile', "`"$ProfilePath`""
        '-outputfolder', "`"$OutputFolder`""
        '-outputformat', $Format
        '-delimiter', ','
    )

    # Symbol resolution: wpaexporter reads _NT_SYMBOL_PATH env var automatically.
    # DO NOT pass -sympath via CLI — it causes wpaexporter to exit 0 but produce
    # 0 CSV files (silent failure). Just ensure the env var is set before calling.
    if ($env:_NT_SYMBOL_PATH) {
        Write-Verbose "  Symbols (via env): $env:_NT_SYMBOL_PATH"
    } else {
        Write-Verbose "  Symbols: _NT_SYMBOL_PATH not set — no symbol resolution"
    }

    if ($Prefix) {
        $args += '-prefix'
        $args += $Prefix
    }

    if ($RangeStart -and $RangeEnd) {
        $args += '-range'
        $args += $RangeStart
        $args += $RangeEnd
    }

    Write-Verbose "Running wpaexporter.exe with CLI flags..."
    Write-Verbose "  Profile: $ProfilePath"
    Write-Verbose "  Output:  $OutputFolder"

    # Snapshot existing CSVs so we can detect new ones
    $existingCsvs = @()
    if (Test-Path $OutputFolder) {
        $existingCsvs = @(Get-ChildItem -Path $OutputFolder -Filter '*.csv' -File | Select-Object -ExpandProperty FullName)
    }

    # Run wpaexporter using & operator to avoid redirect deadlock
    # wpaexporter produces LOTS of verbose output on stderr which can deadlock
    # System.Diagnostics.Process with synchronous ReadToEnd()
    $argString = $args -join ' '
    Write-Verbose "  Command: wpaexporter.exe $argString"

    $stderrFile = Join-Path $OutputFolder "_wpaexporter_stderr.txt"
    $stdoutFile = Join-Path $OutputFolder "_wpaexporter_stdout.txt"

    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $WpaExporterExe
    $startInfo.Arguments = $argString
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardOutput = $false
    $startInfo.RedirectStandardError = $false
    $startInfo.CreateNoWindow = $true

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $startInfo
    $process.Start() | Out-Null

    # Wait for wpaexporter to complete (timeout after 5 minutes for large traces)
    $timeoutMs = 300000
    $completed = $process.WaitForExit($timeoutMs)
    if (-not $completed) {
        Write-Warning "wpaexporter timed out after $($timeoutMs / 1000)s - killing process"
        try { $process.Kill() } catch {}
    }
    $exitCode = if ($completed) { $process.ExitCode } else { -1 }

    if ($exitCode -ne 0) {
        Write-Warning "wpaexporter exited with code $exitCode"
    }

    # Detect newly created CSV files
    $allCsvs = @(Get-ChildItem -Path $OutputFolder -Filter '*.csv' -File | Select-Object -ExpandProperty FullName)
    $newCsvs = @($allCsvs | Where-Object { $_ -notin $existingCsvs })

    return [PSCustomObject]@{
        ExitCode   = $exitCode
        OutputDir  = $OutputFolder
        CsvFiles   = $newCsvs
        AllCsvFiles = $allCsvs
    }
}

Export-ModuleMember -Function 'Export-EtwData'
