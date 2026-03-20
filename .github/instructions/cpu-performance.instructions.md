---
description: "Use when analyzing CPU performance, CPU sampling, scheduling, context switches, ready time, process CPU usage, or hot functions from ETL traces."
---
# CPU Performance Analysis

## Data Extraction

Run the generic analyzer with these parameters:

```powershell
.\analyzers\Invoke-GenericAnalyzer.ps1 -EtlPath "<etl>" -AnalyzerName "CPU Performance Analysis" -WpaProfile CpuSampling-Export -Prefix CPU_ -MetricName "CPU Weight (ms)" -ApplyThresholds @{ ThresholdSection = 'Cpu' }
```

- **xperf action**: None (CPU sampling data is best extracted via wpaexporter)
- **WPA profile**: `CpuSampling-Export.wpaProfile` (custom, in `profiles/export/`)
- **Fallback profile**: `PresetsForComparativeAnalysis.wpaProfile` (catalog)
- **CSV prefix**: `CPU_`

## Thresholds (from `config/thresholds.json`)

| Metric | Warning | Critical |
|--------|---------|----------|
| Process CPU % | > 25% | > 50% |
| Ready Time (ms) | > 50 | > 200 |
| Context Switch Rate/s | > 50,000 | > 100,000 |

## How to Interpret Results

### CPU Sampling (Weight)
- Weight = number of samples × sample interval — approximates CPU time
- Higher weight = more CPU consumed
- Group by Process first, then drill into Module → Function for hot path
- Compare process CPU against total to calculate percentage

### Top CPU Consumers
- Filter out `Idle` process (expected to consume remaining CPU)
- `System` process high CPU → kernel-mode driver activity
- `MsMpEng.exe` → Windows Defender real-time scanning
- `svchost.exe` high CPU → identify hosted service via `-k` group
- `SearchIndexer.exe` → Windows Search indexing activity

### Context Switch Analysis
- High context switch rate (>50K/s) indicates scheduling contention
- Look at Ready Time (time thread waited in ready queue before getting CPU)
- Ready Time > 50ms suggests CPU saturation or priority issues
- Use WPA's "CPU Precise" (Context Switching) view for per-thread analysis

### Hot Function Identification
- Check function names against `knowledge/watch-functions.txt`
- Functions in ntoskrnl.exe:
  - `Ke*`, `Ki*` → scheduling/interrupt handling
  - `Ex*` → executive/locks → check for lock contention
  - `Mm*` → memory manager → check for paging pressure
  - `Io*`, `Cc*` → I/O/cache manager → check disk activity
- Functions in driver `.sys` files → potential driver issue

### Wait Analysis
- If CPU usage is low but app is slow → thread is **waiting**, not running
- Check Wait Analysis view: what lock/resource is the thread waiting on?
- Cross-reference with `knowledge/watch-locks.txt` for known problematic locks:
  - `ExpWaitForResource` → kernel executive resource
  - `RtlpWaitOnCriticalSection` → user-mode critical section
  - `EnterCrit` → Win32k big lock

## Known Patterns to Check

- Cross-reference top offenders against `knowledge/known-issues.json`
- Compare hot functions against `knowledge/watch-functions.txt`
- Check important threads from `knowledge/important-threads.txt`:
  - `CTray::MainThreadProc` — Explorer tray
  - `RawInputThread`, `xxxDesktopThread` — csrss (input processing)
  - `CDesktopManager::DwmEventThreadProc` — DWM compositor

## Recommendation Templates

- "Process '<name>' is consuming X% CPU — profile with CPU Sampling view in WPA"
- "High context switch rate (X/s) — check for lock contention in Wait Analysis view"
- "Hot function '<module>!<function>' — investigate if this is expected behavior"
- "Check wait analysis for blocked threads using `knowledge/watch-locks.txt` patterns"
- "Open trace: `wpa.exe \"<etl>\" -profile \"CpuSampling-Export.wpaProfile\"`"
