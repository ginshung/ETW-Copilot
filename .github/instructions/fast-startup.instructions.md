---
description: "Use when analyzing boot, fast startup, shutdown, hibernate, or resume ETL traces. Covers boot phase timing, service start delays, PnP device enumeration, disk I/O during boot, and post-boot performance."
---
# Fast Startup / Boot Analysis

## Data Extraction

Run the generic analyzer with these parameters:

```powershell
.\analyzers\Invoke-GenericAnalyzer.ps1 -EtlPath "<etl>" -AnalyzerName "Fast Startup / Boot Analysis" -XperfAction boot -WpaProfile FastStartup -Prefix FS_ -MetricName "CPU Weight (ms)" -ApplyThresholds @{ ThresholdSection = 'FastStartup' }
```

- **xperf action**: `boot` — outputs XML with boot phases, services, PnP, disk I/O
- **WPA profile**: `FastStartup.wpaprofile` (catalog) — exports Regions of Interest, CPU Usage, Disk Summary, Processes, Memory
- **CSV prefix**: `FS_`

## Thresholds (from `config/thresholds.json`)

| Metric | Warning | Critical |
|--------|---------|----------|
| Total Boot Time | > 30s | > 60s |
| Shutdown Total | > 15s | > 30s |
| Resume Phase | > 10s | > 20s |
| Service Delay | > 5s | > 15s |
| Driver Init | > 3s | > 10s |

## How to Interpret Results

### Boot Phase Hierarchy (from Regions of Interest CSV)
- The `FS_Regions_of_Interest*.csv` contains hierarchical boot regions
- Backslash-separated paths indicate parent/child (e.g., `Main Path\Boot\Post Boot`)
- Duration column shows time in seconds
- Focus on phases > 5s for optimization opportunities
- Status: OK (≤10s), SLOW (10-20s), CRITICAL (>20s)

### Boot Timing (from xperf -a boot XML)
- `BootDoneViaExplorerMs` — time until Explorer shell is ready (user sees desktop)
- `BootDoneViaPostBootMs` — time until all post-boot activity completes (total boot)
- `OSLoaderDurationMs` — BIOS/firmware time before OS takes over

### Service Analysis
- `TopServicesByTime` from xperf XML shows services sorted by transition duration
- Check `Transition` field: Start, Stop, or Demand
- Services > 5s should be reviewed for delayed start or dependency issues
- `Container` field shows which svchost group hosts the service

### PnP Device Enumeration
- `PnpDevices` from xperf XML shows device enumeration timing
- Devices > 200ms warning, > 500ms critical
- Check `Description` and `FriendlyName` for device identification
- Look for USB, storage, and GPU drivers as common slow enumerators

### CPU Usage by Process (from `FS_CPU_Usage*.csv`)
- Weight column indicates CPU time in ms during the boot window
- Filter out `Idle` process
- Top consumers: services, antivirus (MsMpEng.exe), search indexer

### Disk I/O by Process (from `FS_Disk_Summary*.csv`)
- Size column shows total bytes per process
- Processes > 50 MB I/O during boot are noteworthy
- Common offenders: Windows Defender, SuperFetch/SysMain, registry hive flush

## Known Patterns to Check

- **Registry hive flushing**: Look for `HvSyncHive`, `CmpFlushHive`, `NtFlushKey` in watch-functions.txt
- **Antivirus filter drivers**: Match against `known-issues.json` pattern `av-filter-driver`
- **OEM bloatware services**: Match against `known-issues.json` pattern `oem-bloatware-service`
- **Windows Update during boot**: `wuauserv`, `TrustedInstaller` in service list
- **SuperFetch/SysMain**: Normal but can cause excessive I/O on slow disks

## Recommendation Templates

- "Total boot time is Xs — investigate the longest phases for optimization"
- "Service '<name>' took Xs during <transition> — consider delayed start"
- "Phase '<name>' took Xs — check processes active during this phase in WPA Timeline view"
- "Device '<name>' PnP enumeration took Xms — update driver or check hardware"
- "Open in WPA: `wpa.exe \"<etl>\" -profile \"<FastStartup.wpaprofile>\"`"
