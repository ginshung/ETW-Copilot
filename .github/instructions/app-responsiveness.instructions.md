---
description: "Use when analyzing app responsiveness, UI hangs, app launch time, rendering delays, input latency, jank, or window message pump issues from ETL traces."
---
# App Responsiveness Analysis

## Data Extraction

Run the generic analyzer with these parameters:

```powershell
.\analyzers\Invoke-GenericAnalyzer.ps1 -EtlPath "<etl>" -AnalyzerName "App Responsiveness Analysis" -WpaProfile AppLaunch -WpaProfileFallbacks @('HtmlResponsivenessAnalysis','XamlAppResponsivenessAnalysis') -Prefix AppResp_ -MetricName "Duration (ms)" -ApplyThresholds @{ ThresholdSection = 'AppResponsiveness' }
```

- **xperf action**: None (responsiveness is primarily analyzed via WPA profiles)
- **WPA profile**: `AppLaunch.wpaProfile` (Catalog), with fallbacks to `HtmlResponsivenessAnalysis`, `XamlAppResponsivenessAnalysis`
- **CSV prefix**: `AppResp_`

## Thresholds (from `config/thresholds.json`)

| Metric | Warning | Critical |
|--------|---------|----------|
| UI Hang Duration (ms) | > 200 | > 1000 |
| App Launch Time (s) | > 5 | > 15 |
| Frame Duration (ms) | > 33 | > 100 |
| Input Latency (ms) | > 50 | > 200 |

## How to Interpret Results

### App Launch Analysis
- The WPA AppLaunch profile exports process launch timing
- Key columns: Process Name, Start Time, Duration, CPU Usage
- Look for the gap between process creation and first window message
- Long gaps indicate either CPU contention, disk I/O, or network waits during init

### UI Hang Detection
- A "hang" is when a window message pump stops processing messages (> 200ms)
- The thread is typically blocked on: disk I/O, lock contention, CPU-bound computation, or waiting for network
- Use CPU Sampling data to find what the blocked thread was doing
- Cross-reference with wait analysis (context switch data) to find the blocking resource

### Investigation Flow

1. **Identify the hung/slow process** from the responsiveness CSV data
2. **Find the time range** of the hang (start time + duration)
3. **Run CPU analysis** for that time range to find hot functions in the process
4. **Check context switches** to find what the thread was waiting on
5. **Check disk I/O** if the thread was blocked on file operations
6. **Check lock contention** if the thread was waiting on a synchronization object

### Process & Thread Anomalies

| Indicator | Possible Cause |
|-----------|---------------|
| Process consuming > 20% CPU sustained | CPU-bound hot loop or inefficient algorithm |
| `svchost.exe` high CPU | Identify hosted service via `-k` group |
| `System (4)` high disk I/O | Kernel-mode driver I/O (antivirus, storage filter) |
| `MsMpEng.exe` high CPU/disk | Windows Defender scanning |
| Thread blocked > 1s on lock | Lock contention — check wait analysis |
| Frequent hard faults | Working set too small, memory pressure |

## Supplementary Analysis

When responsiveness issues are found, often need to combine with:
- **CPU Performance** analysis to find hot functions in the hung process
- **Disk I/O** analysis if blocked on file operations
- **Memory** analysis if hard faults are contributing to delays

## Known Patterns to Check

- `known-issues.json` pattern matching for processes involved in hangs
- `knowledge/watch-functions.txt` for known problematic functions
- `knowledge/watch-locks.txt` for known contention points

## Recommendation Templates

- "Process '<name>' UI hang of Xms detected at T+Ys — investigate blocking call stack"
- "App launch time Xs exceeds threshold — check disk I/O during initialization"
- "Frame rendering > 33ms indicates dropped frames — check GPU driver / composition engine"
- "Open trace: `wpa.exe \"<etl>\" -profile \"AppLaunch.wpaProfile\"`"
