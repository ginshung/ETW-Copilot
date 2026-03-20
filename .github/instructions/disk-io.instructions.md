---
description: "Use when analyzing disk I/O, storage latency, throughput, flush counts, file-level I/O, or disk queue depth from ETL traces."
---
# Disk I/O Analysis

## Data Extraction

Run the generic analyzer with these parameters:

```powershell
.\analyzers\Invoke-GenericAnalyzer.ps1 -EtlPath "<etl>" -AnalyzerName "Disk I/O Analysis" -XperfAction diskio -WpaProfile DiskIO-Export -Prefix DIO_ -MetricName "I/O Size (bytes)" -ApplyThresholds @{ ThresholdSection = 'DiskIO' }
```

- **xperf action**: `diskio` — outputs text with per-process I/O summary
- **WPA profile**: `DiskIO-Export.wpaProfile` (custom, in `profiles/export/`)
- **CSV prefix**: `DIO_`

## Thresholds (from `config/thresholds.json`)

| Metric | Warning | Critical |
|--------|---------|----------|
| Flush Count | > 100 | > 500 |
| Avg Latency (ms) | > 10 | > 50 |
| Total I/O (GB) | > 1 | > 5 |

## How to Interpret Results

### Per-Process I/O (from xperf -a diskio)
- xperf outputs text lines with process name, size, and count
- TopOffenders ranked by total I/O size (bytes)
- Large I/O consumers during boot/standby are investigation targets

### Flush Detection
- Flush operations force data to disk (bypassing write cache)
- High flush count (>100) during boot significantly increases boot time
- CsvData.FlushCount stores the detected flush count
- Common flush sources: registry hive, NTFS metadata, database apps

### Disk I/O by File (from wpaexporter CSV)
- CSV contains per-process and per-file I/O breakdown
- Group by Process column, sum Size/Bytes column
- Look for:
  - `$MFT`, `$LogFile`, `$Bitmap` — NTFS metadata (indicates fragmented/full disk)
  - `pagefile.sys` — paging (indicates memory pressure)
  - `*.etl` files — trace logging overhead
  - Large `.dll`/`.exe` reads — cold-start page faults

### Latency Analysis
- Average latency > 10ms suggests slow storage or queue saturation
- Per-file latency breakdown identifies which files are causing delays
- SSD: expect < 1ms average; HDD: expect 5-15ms average
- Queue depth > 4 sustained indicates storage bottleneck

### Storage Stack Indicators
- `storport.sys`, `stornvme.sys` — storage miniport drivers
- `ntfs.sys` — file system operations
- `fltmgr.sys` — filter manager (antivirus, encryption, backup filters)
- High I/O in `fltmgr.sys` → identify which minifilter is causing delays

## Known Patterns to Check

- `known-issues.json` pattern `storage-driver-flush` — storage driver flush issues
- `known-issues.json` pattern `registry-hive-flush` — registry flush storms during boot
- `known-issues.json` pattern `ntfs-metadata` — NTFS metadata I/O
- `known-issues.json` pattern `av-filter-driver` — antivirus filter causing I/O delays

## Recommendation Templates

- "Total disk I/O is X GB — review per-file breakdown in WPA Disk I/O table"
- "X flush operations detected — check for registry hive flush storms"
- "Process '<name>' performed X MB of I/O — investigate file access patterns"
- "Average disk latency is Xms — check if storage is SSD or HDD, update firmware"
- "Open trace: `wpa.exe \"<etl>\" -profile \"DiskIO-Export.wpaProfile\"`"
