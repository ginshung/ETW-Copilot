<#
.SYNOPSIS
    Parses CSV files exported by wpaexporter into PowerShell objects.
.DESCRIPTION
    Handles wpaexporter CSV quirks: quoted fields with commas inside,
    locale-specific number formatting (e.g. "1,234.56" with thousands separators).
#>

function Import-EtwCsv {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$CsvPath,

        [int]$MaxRows = 0
    )

    if (-not (Test-Path $CsvPath)) {
        Write-Warning "CSV file not found: $CsvPath"
        return @()
    }

    # Use Import-Csv which properly handles quoted fields
    try {
        $raw = Import-Csv -Path $CsvPath -Encoding UTF8
    }
    catch {
        Write-Warning "Failed to parse CSV: $CsvPath - $_"
        return @()
    }

    if ($MaxRows -gt 0 -and $raw.Count -gt $MaxRows) {
        $raw = $raw | Select-Object -First $MaxRows
    }

    # Post-process: convert numeric strings with thousands separators
    $results = @()
    foreach ($row in $raw) {
        $obj = [ordered]@{}
        foreach ($prop in $row.PSObject.Properties) {
            $val = $prop.Value
            if ($val -is [string] -and $val -match '^\s*-?[\d,]+(\.\d+)?\s*$') {
                # Remove thousands separators and parse as number
                $cleanVal = $val -replace ',', ''
                $numVal = 0.0
                if ([double]::TryParse($cleanVal, [ref]$numVal)) {
                    $obj[$prop.Name] = $numVal
                } else {
                    $obj[$prop.Name] = $val
                }
            } else {
                $obj[$prop.Name] = $val
            }
        }
        $results += [PSCustomObject]$obj
    }

    return $results
}

function Find-TopOffenders {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [array]$Data,

        [Parameter(Mandatory)]
        [string]$GroupBy,

        [Parameter(Mandatory)]
        [string]$MetricColumn,

        [string]$AggregateFunction = 'Sum',

        [int]$TopN = 10
    )

    if ($Data.Count -eq 0) { return @() }

    $grouped = $Data | Group-Object -Property $GroupBy | ForEach-Object {
        $group = $_
        $metricValues = $group.Group | ForEach-Object { $_.$MetricColumn } | Where-Object { $_ -ne $null }

        $aggValue = switch ($AggregateFunction) {
            'Sum'     { ($metricValues | Measure-Object -Sum).Sum }
            'Average' { ($metricValues | Measure-Object -Average).Average }
            'Max'     { ($metricValues | Measure-Object -Maximum).Maximum }
            'Count'   { $metricValues.Count }
        }

        [PSCustomObject]@{
            Name   = $group.Name
            Value  = [math]::Round($aggValue, 4)
            Count  = $group.Count
        }
    }

    return ($grouped | Sort-Object -Property Value -Descending | Select-Object -First $TopN)
}

Export-ModuleMember -Function @('Import-EtwCsv', 'Find-TopOffenders')
