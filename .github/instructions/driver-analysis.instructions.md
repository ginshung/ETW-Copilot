---
description: "Use when analyzing driver performance, DPC latency, ISR latency, PnP enumeration, USB4, Thunderbolt, WDF, device driver init, or kernel-mode driver issues from ETL traces."
---
# Driver / DPC / ISR Analysis

## Data Extraction

Run the generic analyzer with these parameters:

```powershell
.\analyzers\Invoke-GenericAnalyzer.ps1 -EtlPath "<etl>" -AnalyzerName "Driver / DPC / ISR Analysis" -XperfAction dpcisr -WpaProfile DpcIsr-Export -Prefix DRV_ -MetricName "Duration (us)" -ApplyThresholds @{ ThresholdSection = 'Driver' }
```

- **xperf action**: `dpcisr` — outputs DPC/ISR per-module statistics (uses `-symbols` automatically)
- **WPA profile**: `DpcIsr-Export.wpaProfile` (custom, in `profiles/export/`)
- **CSV prefix**: `DRV_`

## Thresholds (from `config/thresholds.json`)

| Metric | Warning | Critical |
|--------|---------|----------|
| DPC Duration (ms) | > 1 | > 10 |
| ISR Duration (µs) | > 100 | > 1000 |
| Driver Init (s) | > 5 | > 15 |
| PnP Enum (s) | > 3 | > 10 |

## How to Interpret Results

### DPC/ISR Output (from xperf -a dpcisr)
- The output contains sections for DPC and ISR, each listing driver modules (.sys)
- `CsvData.DpcIsrEntries` contains parsed entries with: Module, Type (DPC/ISR), Count, MaxUs, TotalUs
- **MaxUs** is the key metric — a single long DPC/ISR blocks the entire CPU
- DPC > 1ms → audio glitching, UI stuttering
- DPC > 10ms → system unresponsiveness, watchdog violations

### Driver Module Classification

| Pattern | Category | Action |
|---------|----------|--------|
| `ntoskrnl.exe!Ke*`, `Ki*` | Kernel scheduling/interrupt | Check DPC/ISR latency |
| `NETIO.SYS`, `tcpip.sys`, `ndis.sys` | Network stack | Check network latency, interrupt moderation |
| `storport.sys`, `stornvme.sys` | Storage stack | Check disk throughput |
| `dxgkrnl.sys`, `dxgmms*.sys` | Graphics kernel | Check GPU scheduling |
| `usb4hrd.sys`, `usb4drd.sys` | USB4 host/device router | Check USB4 topology, tunnels, HRR |
| `usbxhci.sys`, `ucx01000.sys` | USB host controller | Check USB transfers |
| `e1*.sys`, `rt*.sys`, `ath*.sys` | Network adapter drivers | Check interrupt coalescing |
| Unknown 3rd-party `.sys` | OEM/vendor driver | Flag as potential root cause |

### USB4/Thunderbolt Investigation
When USB4/TB drivers appear in top offenders:
- Check for HRR (Host Router Reset) failure patterns
- Check CL0 entry/exit timing (physical link training)
- Check tunnel establishment (USB, DP, PCIe)
- Reference USB4 v2 Rev 1.0 specification
- Look for `0xC000009D` (STATUS_DEVICE_NOT_CONNECTED) or `0xC00000A3` (STATUS_DEVICE_NOT_READY)

### PnP Enumeration Timing
If boot trace, check PnP device enumeration from xperf boot XML:
- Devices > 200ms are noteworthy
- Devices > 500ms are critical
- Slow enumerators: USB hubs, Thunderbolt controllers, GPU, storage controllers

## Known Patterns to Check

- `known-issues.json` pattern `high-dpc-network` — network driver DPC issues
- `known-issues.json` pattern `gpu-driver-init` — GPU driver initialization time
- Match all `.sys` modules against known-issues.json patterns
- Cross-reference functions with `knowledge/watch-functions.txt`

## Recommendation Templates

- "URGENT: Driver '<module>' has DPC max Xms — contact driver vendor for fix"
- "Driver '<module>' ISR max Xµs exceeds threshold — update driver"
- "Network driver causing high DPC — check interrupt moderation settings"
- "Use WPA DPC/ISR Duration view for detailed per-interrupt analysis"
- "Open trace: `wpa.exe \"<etl>\" -profile \"DpcIsr-Export.wpaProfile\"`"
