# ETW Analysis Learnings

---

## Session: 2026-03-24 — USB4 FAIL vs PASS Connection Analysis (FAIL_USB4 vs PASS_USB4)

### System
- Platform: Acer (SubVendor 0x1025, SubSystem 0x203D)
- USB4 Host Router: Intel PTL/TDM1 — VEN_8086 DEV_E434 REV_01, ACPI `\_SB_.PC00.TDM1`, PCI 0.13.3
- OS Policy: USB4 v2 enabled; Driver bundle 2504; CLx not disabled
- Trace format: Pre-exported text ETW (not raw .ETL)

### Key Findings

1. **RouterDetected bit (PORT_CS_18) is THE primary gate in FAIL/PASS discrimination** — If `RouterDetected=0`, the PSM goes to `WaitingForRouterConnect` indefinitely. If `RouterDetected=1` at the first CS[18] readout (within ~1.2s of PrepareHW completion), the connection proceeds to tunnel establishment. No RouterDetected → no tunnels, ever.

2. **AdapterState=7 means Training/No-CL0 — physical link not active** — PORT_CS_1 AdapterState field: 7=Training (link not yet in CL0), 2=CL0 (active). FAIL shows 7 throughout; PASS shows 2 immediately. If AdapterState=7 persists beyond PrepareHW, the downstream device is absent or not training.

3. **BondingEnabled and RS_FEC_Gen3_Enabled confirm dual-lane Gen3 operation** — In PASS: BondingEnabled=1 and RS_FEC_Gen3_Enabled=1. In FAIL: both=0. NegotiatedLinkWidth in CS[1] shows 2 (bonded) vs 1 (single). TargetLinkWidth=3 in PASS, =1 in FAIL (hint: FAIL was targeting single-lane even in its target config).

4. **ErrAddr on Adapter 11 is structural (both traces) — non-fatal** — The root USB4 router has a config space hole at Adapter 11. The RSM correctly handles it (CheckingIfUnusedAdapterNumber→Yes). Present in BOTH FAIL and PASS. Do NOT confuse this with the connection failure.

5. **ErrConn in PASS is a graceful disconnect — NOT a PASS failure** — PASS at T=69s shows 24 TRACE_LEVEL_ERROR events (all ErrConn + topology read failures) but these are caused by the dock physically being removed. ErrConn = "Error Connection" — the device rejected config space access because it is no longer electrically present. This is the correct behavior for device removal.

6. **FAIL has 5 S0-idle sleep/wake cycles with no device** — Each cycle: DomainPowerDown → RouterPoweredDown → FDOD0Entry → CheckIfDeviceWasRemovedInSleep(No) → still RouterDetected=0. WakeOnConnect is correctly enabled (EnableWakeOnConnect=1 in CS[19]) but never fires because no device generates a wake signal.

7. **PASS has ZERO sleep cycles** — Because the device was connected before/during PrepareHW, the PSM proceeds directly to tunnel establishment. Time from PrepareHW → PCIe tunnel active = ~4.8 seconds.

8. **RS_FEC_Gen3_Request=1 in FAIL CS[19] shows host is requesting Gen3 FEC** — Even though no device is present, the host adapter has `RS_FEC_Gen3_Request=1` in CS[19]. This means the firmware/driver IS capable of Gen3 and is advertising it. The failure is purely absence of downstream device, not a capability mismatch.

9. **TargetLinkWidth=1 (x1) in FAIL CS[1] vs TargetLinkWidth=3 (x2) in PASS** — Interesting: the FAIL trace shows TargetLinkWidth=1, as if either the host or the link negotiated single-lane as target. This may indicate the host dropped to x1 target after link training timeout. PASS correctly shows TargetLinkWidth=3 (x2 = two lanes). This may indicate the FAIL scenario went through a prior failed bonding attempt.

### USB4 Spec Key Sections
- **USB4 v2 §5.3.1** — PORT_CS register definitions (CS[1]: link speed/width/AdapterState; CS[18]: RouterDetected/BondingEnabled/RS-FEC; CS[19]: wake settings/RS-FEC requests)
- **USB4 v2 §3.2** — Physical Layer link training: CL0 requires both sides, RS-FEC Gen3 required for Gen3
- **USB4 v2 §6.4.2** — Config space responses: ErrAddr (address not found), ErrConn (connection failed/device gone)
- **USB4 Connection Manager Guide §4.2** — PSM states: `WaitingForRouterConnect`, `IsRouterDetectedSet`, `ReadingRouterDetected`

### Investigation Techniques

- **First check for USB4 FAIL**: Grep for `RouterDetected.*0` vs `RouterDetected.*1` in DFP CS[18] — this is the single fastest discriminator
- **Second check**: DFP CS[1] `AdapterState` value — 2=good, 7=bad (training/absent)
- **Third check**: Count `DomainPowerDown` events — many cycles with no connection = device absent
- **Don't be misled by TRACE_LEVEL_ERROR count** — PASS had 24 errors (all graceful disconnect), FAIL had only 1 error (non-fatal ErrAddr). Low error count ≠ success!
- **Always check both CS[18] and CS[1]** for a complete picture: CS[18] gives router-level indicators; CS[1] gives physical link state

### Useful Commands (USB4 Text Trace Analysis)
```powershell
# Load trace
$lines = Get-Content "FAIL_USB4.txt"

# Critical: RouterDetected check (most important discriminator)
$lines | Where-Object { $_ -match 'DFP_1.*\[18\]' }

# Link speed and adapter state
$lines | Where-Object { $_ -match 'DFP_1.*\[1\].*TargetLinkSpeed' }

# All TRACE_LEVEL_ERROR events
$lines | Where-Object { $_ -match 'TRACE_LEVEL_ERROR' }

# Sleep/wake cycle count
$lines | Where-Object { $_ -match 'DomainPowerDown|RouterPoweredDown|FDOD0Entry' } | Measure-Object

# PSM router connect wait
$lines | Where-Object { $_ -match 'IsRouterDetectedSet' }

# Tunnel establishment (PASS success indicator)
$lines | Where-Object { $_ -match 'tunnel.*success|Successfully configured.*tunnel' }
```

---

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
