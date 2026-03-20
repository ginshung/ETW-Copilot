# ETW Analysis Learnings

## Session: 2026-03-19 — Modern Standby WiFi Failure (0828_Fail_with WiFi)

### System
- Alienware Desktop, DESKTOP-0T0VVHD, Intel Core Ultra 7 265K (Arrow Lake), Win 11 26100 (24H2)
- UTC-7 (PDT). S0 Low Power Idle (Network Connected) only. No S3/S2/S1.
- WiFi: Intel Killer BE200NGW (Wi-Fi 7 BE1750x), Service=`Netwaw16`, PCIe=`\_SB.PC02.RP03.PXSX`
- Ethernet: Killer E3100G 2.5 GbE, Service=`e3k25cx21x64`, PCIe=`\_SB.PC02.RP01.PXSX`
- GPU: Intel Arc + NVIDIA (dual-GPU); USB4 present; Remote Desktop ENABLED

### Key Findings

1. **74ms Modern Standby abort = Netwaw16 failing PDC callback** — System entered CS at 21:24:00Z (Kernel-Power ID:506) and exited at 21:24:01Z (ID:566) only 73ms later with "Transition To Sleep". Sleep Study Session 132 confirms Duration=73,934µs. The `\_SB.PC02.RP03` PCIe root port (hosting the WiFi adapter) remained active, blocking the PDC from achieving DRIPS state.

2. **Netwaw16 service failures on wake** — SCM events ID:7021 (service hung) and ID:7003 (dependency failed) at T+69s and T+4min after CS abort, confirming the driver service was completely broken and unable to reinitialize after the CS failure.

3. **Sleep Study TopBlockers JSON is the fastest way to find PCIe DRIPS blockers** — Parsing the sleep study HTML's embedded JSON blob reveals device-to-PCIe-path mapping AND which PCIe root ports were blocking DRIPS during prior sessions. This is faster than running wpaexporter for initial triage.

4. **Sleep Study `RegisteredDevices` is the definitive device→service→PCIe mapping** — The JSON array maps device friendly name, service name, hardware IDs, and ACPI path in one object. Use this to confirm which driver owns a PCIe root port appearing in TopBlockers.

5. **WPA3 group key rotation (GTK/11004→11010→11005)** every ~3-4 min is a known Killer driver pattern — The double-reauthentication within seconds at certain intervals (race condition) is a Killer driver 802.11 state machine bug. This breaks DRIPS epochs, capping them at ~8 min in histogram. AP GTK rotation interval too short at default 180s also contributes.

6. **Remote Desktop Services (RDS) enabled can prevent WiFi D3-Cold** — `RemoteDesktopEnabled:true` + WCM engaged time >700s during standby means WCM keeps the network live for RDP availability, preventing WiFi from transitioning to D3-Cold required for DRIPS. Always check `Settings.RemoteDesktopEnabled` in sleepstudy JSON.

7. **DripsHistogram capped at 8-minute epochs = WiFi reauthentication interval** — If DRIPS histogram shows only 4m/8m buckets and nothing longer, the DRIPS cycle is broken every ~8-12 minutes. Cross-reference with WLAN-AutoConfig events to confirm WiFi is the blocker.

8. **MSExitPerformance.ResiliencyExitTime dominant in MS exit** — If ResiliencyExitTime >> ScreenOnExitTime, the slowness is in OS+network state restoration (network resync, not monitor/display). WiFi adapter not maintaining state across D-states causes extended resiliency time.

9. **wrt-os ETL from Intel WRT2 does NOT include DPC/ISR keywords** — `xperf -a dpcisr` returns "No DPC/Interrupt available in the trace". The sub-trace uses OS-focused keywords but not CPU sampling. For DPC/ISR data, use the main `Wprtrace_08_28.etl` in WPA GUI.

10. **`UserConnectivityPolicy=1` means WiFi disconnection is NOT allowed during standby** — This is set when network-dependent apps (like RDS) are present. Results in WCM never sending disconnect command to WiFi adapter, keeping it active during sleep.

### Investigation Techniques

- **For instant CS failure (<100ms)**: Start with Sleep Study JSON (Sessions table → Duration field). Confirm via Kernel-Power ID:506 (entry) and ID:566 (exit) timestamps in System.evtx. No need to open 2GB ETL files first.
- **Sleep Study HTML JSON extraction**: `$html = Get-Content file.html -Raw; $match = [regex]::Match($html, 'PowerReportData = ({.*});')` — the JSON covers sessions, blockers, devices, settings.
- **Device-to-ACPI path mapping**: Look in `RegisteredDevices` JSON array for `"Service Name"`, `"Friendly Device Name"`, and ACPI path fields. This maps service (Netwaw16) to PCIe location (`\_SB.PC02.RP03.PXSX`).
- **Killer BE200NGW CS diagnosis checklist**: (1) Check SCM events 7021/7003 for Netwaw16 wake failures; (2) Check TopBlockers for `\_SB.PC02.RP03`; (3) Check WLAN for 11004/11010/11005 cycles; (4) Sessions table for Duration<1s; (5) RemoteDesktopEnabled.
- **wpaexporter DeadLock avoidance**: Do NOT pass `-sympath` CLI arg. Set `$env:_NT_SYMBOL_PATH` before the call. Do NOT redirect stdout/stderr. Set 5-minute process timeout.

### Useful Commands

```powershell
# Extract Sleep Study JSON and find TopBlockers
$html = Get-Content "sleepstudy-report.html" -Raw
$match = [regex]::Match($html, 'PowerReportData\s*=\s*(\{.+?\});', [System.Text.RegularExpressions.RegexOptions]::Singleline)
$json = $match.Groups[1].Value | ConvertFrom-Json
# TopBlockers for a session:
$json.Sessions[N].TopBlockers
# Device → service → PCIe path:
$json.RegisteredDevices | Select FriendlyDeviceName, ServiceName, AcpiPath | Sort AcpiPath

# Find CS entry/exit events in System.evtx
$sysLog = Get-WinEvent -Path "System.evtx" -Oldest -ErrorAction SilentlyContinue
$csEvents = $sysLog | Where-Object { $_.Id -in @(506,507,530,531,539,566) }
$csEvents | Select-Object TimeCreated, Id, Message | Format-Table

# Check Netwaw16 service dependencies
sc.exe qc Netwaw16

# WPA commands for CS analysis
$wpa = "C:\Program Files (x86)\Windows Kits\10\Windows Performance Toolkit\wpa.exe"
# Open with time range covering CS entry:
& $wpa "Wprtrace_08_28.etl"  # Then: View → New Analysis View → Modern Standby
```

---

## Session: 2026-03-18 — Modern Standby Resume Failure (pass2 vs fail2)

### System
- Lenovo ThinkPad 21BWS0U917, Intel Core i7-1270P (Alder Lake), Win 11 24H2
- BIOS N3MET23W 1.22, Hyper-V enabled
- S0 Low Power Idle (Modern Standby), no S3 available

### Key Findings

1. **Power button wake bypasses PDC entirely** — pass2 (power button) had ZERO PDC events and none of the CS-specific Kernel-Power events (506/536/544/581/582/585/586). The power button wake is a direct, simple ACPI Fixed Event path that doesn't go through the PDC activator machinery.

2. **LID wake goes through full PDC → CS exit pipeline** — fail2 (LID open) had 136 PDC events, 23 unique Kernel-Power event types not present in pass2. The LID wake triggers GPE → EC `_Q51` → `LID0._LID` → PDC activators → CS exit → device enum, creating many failure points.

3. **PDC Activator V1_018 "V1_Unknown"** — Registered with infinite timeout (0xFFFFFFFF) but DID complete (1406ms). The stall occurs AFTER activator completion, during device power transitions.

4. **Intel PCIe Root Port DEV_64A0** — BusScan constraint stuck at False in SleepStudy Event 30/31. This Alder Lake PCIe controller is a D-state transition bottleneck on LID wake.

5. **EnablePowerButtonSuppression=1** — This registry setting suppresses power button events during CS. If LID wake fails, user cannot recover via power button.

### Resolution

**Fix**: Disable `EnablePowerButtonSuppression` (`reg add HKLM\SYSTEM\CurrentControlSet\Control\Power /v EnablePowerButtonSuppression /t REG_DWORD /d 0 /f`). The system was connected to an **external display** — with lid closed on AC set to "Do nothing", the power button was the only valid wake input, but suppression was blocking it during CS.

### Missed Clue: External Display

The external display connection was NOT explicitly identified during ETL analysis. Clues that should have led there:
- **Lid close AC = "Do nothing"** — only makes sense with external display
- **3 extra devices in fail2** (40 vs 37) — likely includes external display adapter
- **"Monitor Off" constraint stuck False** — display framework handling both internal+external panels
- Should have checked `Standby-ImagesList.csv` for display driver instances and compared device lists between traces

**Action item for future MS analysis**: Always check device count differences, investigate "Do nothing" lid policies, and look for display driver/adapter entries in Images Summary CSV.

### Investigation Techniques

- **Get-WinEvent XPath for provider-specific queries doesn't work on WPR traces** — WPR ETL files have different internal structure than evtx logs. Use MaxEvents with post-filter instead.
- **tracerpt on large ETL files (>300MB) is extremely slow** — Avoid full XML conversion. Use wpaexporter with profiles instead.
- **wpaexporter `-sympath` CLI arg causes silent failure** — Exit code 0 but 0 CSV output. Use `$env:_NT_SYMBOL_PATH` instead.
- **ACPI WakeUp registry** (`HKLM\...\Services\ACPI\Parameters\WakeUp`) reveals last wake source — FixedEventStatus for power button, GenericEventStatus for GPE-based (LID).
- **Kernel-Power event ID comparison** between pass/fail is highly valuable — unique event IDs reveal which code path was taken.

### Useful Commands

```powershell
# Check Modern Standby configuration
powercfg /a
powercfg /qh SCHEME_CURRENT SUB_BUTTONS
reg query "HKLM\SYSTEM\CurrentControlSet\Control\Power"
reg query "HKLM\SYSTEM\CurrentControlSet\Services\ACPI\Parameters\WakeUp"

# Load events from WPR ETL (bypassing XPath limitation)
$events = Get-WinEvent -Path <etl> -Oldest -MaxEvents 100000 -ErrorAction SilentlyContinue
$events | Where-Object { $_.ProviderName -like "*PDC*" } | Group-Object Id

# PDC Activator details
$pdc | Where-Object {$_.Id -eq 111} | ForEach-Object { "$($_.TimeCreated.ToString('HH:mm:ss.fff')) $(($_.Properties|%{$_.Value})-join ',')" }
```
