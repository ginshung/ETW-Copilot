---
description: "Use when analyzing Modern Standby, Connected Standby, DRIPS residency, sleep transitions, power management, wake sources, low-power idle, or S0ix from ETL traces."
---
# Modern Standby / Connected Standby Analysis

## Data Extraction

Run the generic analyzer with these parameters:

```powershell
.\analyzers\Invoke-GenericAnalyzer.ps1 -EtlPath "<etl>" -AnalyzerName "Modern Standby / Connected Standby Analysis" -WpaProfile Standby -WpaProfileFallbacks @('Hibernate') -Prefix Standby_ -MetricName "Active Time" -ApplyThresholds @{ ThresholdSection = 'ModernStandby' }
```

- **xperf action**: None (Modern Standby is primarily analyzed via WPA profiles and power-specific providers)
- **WPA profile**: `Standby.wpaProfile` (Catalog), fallback to `Hibernate` (Catalog)
- **CSV prefix**: `Standby_`

## Thresholds (from `config/thresholds.json`)

| Metric | Warning | Critical |
|--------|---------|----------|
| Active Time (%) | > 5 | > 20 |
| DRIPS Residency (%) | < 80 | < 50 |
| Wake Count (per hour) | > 10 | > 30 |
| Transition Time (s) | > 3 | > 10 |
| Resume Time (s) | > 5 | > 15 |

## How to Interpret Results

### DRIPS (Deepest Runtime Idle Platform State)
- DRIPS residency = % time the SoC is in its deepest idle state
- Target: > 95% DRIPS during screen-off standby
- Low DRIPS = something is keeping the system active (activator, device, or software)
- Check `powercfg /sleepstudy` for a user-friendly overview

### Modern Standby Phases
1. **Entry**: Screen off → system enters low-power idle
2. **Maintenance**: Periodic wake for updates, sync, notifications
3. **Exit**: User interaction → screen on, full resume

### Key Analysis Areas

#### Activators (Wake Sources)
- **Network**: WiFi/Ethernet wake events (WoL, keep-alive)
- **USB**: USB device interrupts (mouse, keyboard, dock)
- **Audio**: Audio stream activity
- **Timer**: Scheduled tasks, maintenance windows
- **BI (Broker Infrastructure)**: App background tasks

#### Device Power State Issues

| Pattern | Meaning | Action |
|---------|---------|--------|
| Device stuck in D0 | Not entering low power | Check driver power management |
| Frequent D0/D3 transitions | Device cycling | Check wake source, interrupt pattern |
| Power-gating failure | BIOS/firmware issue | Update BIOS, check ACPI tables |
| CLx asymmetry (USB4/TB) | Firmware misconfiguration | Check USB4 link PM settings |

#### Common DRIPS Blockers

| Blocker | Category | Action |
|---------|----------|--------|
| Network adapter (active scanning) | Device | Disable WiFi scanning in standby |
| USB composite device | Device | Check selective suspend support |
| Audio endpoint (active) | Device | Check audio driver power management |
| Background app (sync/update) | Software | Review background task registration |
| Third-party service | Software | Identify and optimize or disable |
| USB4/TB controller not in CLx | Device | Check firmware CLx configuration |

### Power Transition Analysis
- Entry time: Time from screen-off to DRIPS achieved
- Exit time: Time from wake trigger to screen-on + interactive
- Long entry → driver not handling power IRP promptly
- Long exit → driver slow to resume or PnP re-enumeration

### Battery Drain Investigation
If battery drains during standby:
1. Check DRIPS residency — if low, identify blockers
2. Check wake count — frequent wakes drain battery
3. Check per-component active time — find the hardware keeping system out of DRIPS
4. Check software activators — background tasks preventing idle

## Hardware-Specific Indicators

| Indicator | Possible Cause |
|-----------|---------------|
| HRR failure on resume | USB4 controller not recovering |
| CL0 entry failure | Physical link not entering low-power |
| Gen 2 fallback on resume | Signal integrity after power transition |
| D0 Entry failure | Device unreachable after sleep |

## Investigation Flow

1. **Check DRIPS residency** — if < 95%, something is blocking deep idle
2. **Identify active components** — which device(s) prevent DRIPS
3. **Check wake sources** — what triggers wakes during standby
4. **Check transition times** — are entry/exit times reasonable?
5. **Check per-device D-state** — are all devices in D3 when expected?
6. **Correlate with driver findings** — do DPC/ISR issues affect standby?

## Known Patterns to Check

- `known-issues.json` for known problematic drivers in standby
- USB4/Thunderbolt power management patterns
- Network adapter power management settings
- Audio driver power management

## Recommendation Templates

- "DRIPS residency X% — device '<device>' preventing deep idle"
- "Wake count X/hr exceeds threshold — investigate wake source '<source>'"
- "Standby entry time Xs — driver '<driver>' slow to handle power IRP"
- "Resume time Xs — PnP re-enumeration of '<device>' is slow"
- "USB4 controller not entering CLx — check firmware power management"
- "Open trace: `wpa.exe \"<etl>\" -profile \"Standby.wpaProfile\"`"
