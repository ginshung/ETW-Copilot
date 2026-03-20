---
description: "Use when analyzing memory usage, working set, hard faults, pool usage, heap allocation, memory leak, page faults, or out-of-memory conditions from ETL traces."
---
# Memory Analysis

## Data Extraction

Run the generic analyzer with these parameters:

```powershell
.\analyzers\Invoke-GenericAnalyzer.ps1 -EtlPath "<etl>" -AnalyzerName "Memory Analysis" -XperfAction hardfault -WpaProfile Memory-Export -WpaProfileFallbacks @('WindowsStoreAppMemoryAnalysis') -Prefix Memory_ -MetricName "Hard Faults / Working Set" -ApplyThresholds @{ ThresholdSection = 'Memory' }
```

- **xperf action**: `hardfault` — outputs hard fault statistics per module (uses `-symbols` automatically)
- **WPA profile**: `Memory-Export.wpaProfile` (custom, in `profiles/export/`), fallback to `WindowsStoreAppMemoryAnalysis` (Catalog)
- **CSV prefix**: `Memory_`

## Thresholds (from `config/thresholds.json`)

| Metric | Warning | Critical |
|--------|---------|----------|
| Hard Faults (total) | > 1000 | > 5000 |
| Working Set (MB) | > 500 | > 2000 |
| Pool Usage (MB) | > 200 | > 500 |
| Commit Charge (%) | > 80 | > 95 |

## How to Interpret Results

### Hard Fault Output (from xperf -a hardfault)
- The output lists modules causing hard page faults
- `CsvData.HardfaultEntries` contains parsed entries with: Module, FaultCount
- Hard faults = disk reads to satisfy page faults (slow — 1-50ms each)
- High hard fault counts indicate memory pressure (working set too small)
- Sort by FaultCount descending to find top offenders

### Hard Fault Root Causes

| Cause | Indicator | Action |
|-------|-----------|--------|
| Too many processes | High total commit | Reduce concurrent processes |
| Memory leak | Growing working set over time | Find leaking process/module |
| Large binary loading | Hard faults in DLL/EXE modules | Pre-fetch or optimize loading order |
| Antivirus scanning | Hard faults in MsMpEng.exe regions | Add exclusions |
| Insufficient RAM | Commit charge > physical RAM | Upgrade memory |

### Working Set Analysis (from WPA CSV)
- Per-process working set snapshots
- Look for processes with unusually large or growing working sets
- Compare private vs shared working set
- Private working set growth = potential memory leak

### Pool Analysis
- Paged pool: kernel allocations that can be paged out
- Non-paged pool: kernel allocations always in physical memory
- High non-paged pool = driver leak (use pool tagging to identify driver)
- Look for pool tag patterns to identify the driver module

### Memory Pressure Indicators

| Indicator | Severity | Meaning |
|-----------|----------|---------|
| Available MB < 100 | Critical | System is thrashing |
| Modified list > 500MB | Warning | Write-behind can't keep up |
| Standby list near 0 | Warning | No cached memory available |
| Commit charge > physical | Warning | Relying heavily on page file |
| Hard faults/sec > 100 | Warning | Significant paging activity |

## Investigation Flow

1. **Check total hard faults** — if > 1000, memory pressure exists
2. **Identify top hard-faulting modules** — which DLLs/EXEs are being paged in
3. **Check working set per process** — find largest consumers
4. **Check commit charge** — is the system over-committed?
5. **Check pool usage** — is any driver leaking kernel pool?
6. **Correlate with boot/app timing** — does memory pressure explain slowness?

## Known Patterns to Check

- `known-issues.json` for known memory-hungry drivers or processes
- `knowledge/watch-functions.txt` for known allocation hot functions
- Common offenders: antivirus, search indexer, browser processes

## Recommendation Templates

- "Process '<name>' hard faults: X — reduce working set or increase system RAM"
- "Module '<module>' is the top hard fault contributor — optimize load order or pre-fetch"
- "System commit charge at X% — consider increasing page file or adding RAM"
- "Non-paged pool at XMB — investigate driver pool leak using pool tagging"
- "Open trace: `wpa.exe \"<etl>\" -profile \"Memory-Export.wpaProfile\"`"
