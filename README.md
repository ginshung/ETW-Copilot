# ETW Copilot

Automated Windows ETW (Event Tracing for Windows) trace analysis powered by **VS Code GitHub Copilot** and **Windows Performance Toolkit (WPT)**.

Drop an `.etl` trace file into your workspace, open VS Code, and ask Copilot to analyze it. Copilot acts as a Windows performance expert — running xperf/wpaexporter commands, interpreting results, and producing a structured root cause report with actionable recommendations.

---

## Prerequisites

| Requirement | Details |
|-------------|---------|
| **Windows** | Windows 10 or later |
| **VS Code** | [Download](https://code.visualstudio.com/) |
| **GitHub Copilot** | VS Code extension with active subscription ([Marketplace](https://marketplace.visualstudio.com/items?itemName=GitHub.copilot)) |
| **Windows Performance Toolkit** | Provides `xperf.exe`, `wpaexporter.exe`, `wpa.exe`, `wpr.exe`. Install from the [Windows ADK](https://learn.microsoft.com/en-us/windows-hardware/get-started/adk-install) or [Windows SDK](https://developer.microsoft.com/en-us/windows/downloads/windows-sdk/). |
| **PowerShell** | Windows PowerShell 5.1+ (built into Windows) |
| **Disk Space** | Enough for your ETL trace + ~500 MB for symbol cache (`C:\SymCache`) |

> **Note:** The toolset expects WPT at the default path:
> `C:\Program Files (x86)\Windows Kits\10\Windows Performance Toolkit\`
> If yours is elsewhere, edit `config/settings.json`.

---

## Setup

### 1. Clone the Repository

```bash
git clone https://github.com/jlee52tw/etw-copilot.git
cd etw-copilot
```

### 2. Install Windows Performance Toolkit

If you don't already have `xperf.exe` and `wpaexporter.exe` installed:

1. Download the [Windows ADK](https://learn.microsoft.com/en-us/windows-hardware/get-started/adk-install)
2. During installation, select **"Windows Performance Toolkit"**
3. Verify installation:
   ```powershell
   Test-Path "C:\Program Files (x86)\Windows Kits\10\Windows Performance Toolkit\xperf.exe"
   ```

### 3. Configure Proxy (if needed)

Edit `config/settings.json` and update the proxy section:

```json
{
  "Proxy": {
    "HttpProxy": "http://your-proxy-server:port",
    "HttpsProxy": "http://your-proxy-server:port",
    "NoProxy": "localhost,127.0.0.1"
  }
}
```

The proxy is used to download debug symbols from Microsoft's symbol server (`msdl.microsoft.com`). Set values to `""` if you have direct internet access.

### 4. Place Your ETL Trace File

Copy your `.etl` trace file anywhere accessible on your system. For example:

```
C:\Traces\
└── FastStartup_Analysis_1.etl    <-- your ETL trace file
```

> **Tip:** ETL files can be very large (100 MB – 2+ GB). They are excluded from git via `.gitignore`.

### 5. Open in VS Code

```bash
code etw-copilot
```

---

## Usage

### Quick Start

1. Open the project in VS Code
2. Open **Copilot Chat** (`Ctrl+Alt+I` or click the Copilot icon)
3. Switch to **Agent mode** (click the mode selector at the top of the chat panel)
4. Type:
   ```
   Analyze the ETL trace at C:\Traces\FastStartup_Analysis_1.etl and generate a report
   ```

Copilot will automatically:
- Detect the trace type (boot, standby, CPU, disk, USB4, etc.)
- Run the appropriate analyzers via `Invoke-EtwAnalysis.ps1`
- Execute xperf and wpaexporter to extract detailed data
- Parse results and cross-reference known issues
- Generate a structured 9-section Markdown report
- Create an investigation log with traceable evidence

### CLI Usage (Without Copilot)

You can also run the toolset directly from PowerShell:

```powershell
# Auto-detect trace type and analyze
.\Invoke-EtwAnalysis.ps1 -EtlPath "C:\Traces\boot.etl"

# Specify analysis type explicitly
.\Invoke-EtwAnalysis.ps1 -EtlPath "C:\Traces\boot.etl" -AnalysisType FastStartup

# Custom output directory
.\Invoke-EtwAnalysis.ps1 -EtlPath "C:\Traces\perf.etl" -AnalysisType All -OutputPath "C:\Reports"
```

### Example Copilot Prompts

| Prompt | What It Does |
|--------|-------------|
| `Analyze the ETL trace and find the root cause` | Full end-to-end analysis with report |
| `What is causing the slow boot in this trace?` | Focused boot performance investigation |
| `Analyze the Modern Standby trace for power issues` | Modern Standby / DRIPS analysis |
| `Check for USB4 driver failures in this trace` | USB4/Thunderbolt driver investigation |
| `What processes are using the most CPU?` | CPU sampling & scheduling analysis |
| `Investigate disk I/O bottlenecks` | Disk throughput & latency analysis |
| `Check DPC/ISR latency for driver issues` | DPC/ISR timing analysis |
| `Run the analysis with reason: slow boot after BIOS update` | Analysis with documented context |

### Analysis Types

| Type | Description | Auto-Detect Pattern |
|------|-------------|---------------------|
| **FastStartup** | Boot / Fast Startup phase analysis | `*boot*`, `*startup*`, `*faststartup*` |
| **Cpu** | CPU sampling & scheduling | `*cpu*`, `*perf*`, `*hang*`, `*slow*` |
| **DiskIO** | Disk I/O throughput & latency | `*disk*`, `*io*`, `*storage*` |
| **Driver** | Driver init, DPC/ISR, PnP | `*usb*`, `*thunderbolt*`, `*usb4*` |
| **AppResponsiveness** | UI delay, hang, and responsiveness | `*uidel*`, `*response*`, `*jank*` |
| **Memory** | Memory usage, pool, working set | `*memory*`, `*oom*`, `*leak*` |
| **ModernStandby** | Modern Standby / Connected Standby | `*standby*`, `*sleep*`, `*drips*` |
| **Auto** | Auto-detect from filename (default) | — |
| **All** | Run all analyzers | — |

---

## How It Works

```
┌──────────────┐     ┌─────────────────────┐     ┌──────────────────┐
│  You (User)  │────>│  VS Code + Copilot  │────>│  WPT Tools       │
│  "Analyze    │     │  (Agent Mode)       │     │  ├─ xperf.exe    │
│   the trace" │     │                     │     │  ├─ wpaexporter   │
└──────────────┘     │  Reads custom       │     │  └─ wpa.exe      │
                     │  instructions from  │     │                  │
                     │  .github/copilot-   │     │  Analyzes        │
                     │  instructions.md    │     │  .etl trace      │
                     │                     │     │                  │
                     │  Uses ETW-Copilot   │<────│  Returns XML/CSV │
                     │  PowerShell toolset │     └──────────────────┘
                     │                     │
                     │  Interprets results │
                     │  Iterates deeper    │
                     │  Writes report      │
                     └─────────┬───────────┘
                               │
                               v
                     ┌─────────────────────────┐
                     │  output/                │
                     │  ├─ ETW_Analysis_       │
                     │  │  Report.md           │
                     │  ├─ investigation_      │
                     │  │  log.md              │
                     │  ├─ FS_Regions_*.csv    │
                     │  ├─ FS_CPU_Usage_*.csv  │
                     │  └─ FS_Disk_*.csv       │
                     └─────────────────────────┘
```

### 5-Phase Investigation Workflow

Copilot follows a systematic 5-phase workflow defined in `.github/copilot-instructions.md`:

1. **Phase 1 — Exploration**: Detect trace type, run initial automated analysis, form hypotheses
2. **Phase 2 — Deep Investigation**: Iteratively follow clues, export targeted data, cross-reference known issues
3. **Phase 3 — Possible Cause**: Confirm possible cause with evidence chain (timestamp → event → module → impact)
4. **Phase 4 — Investigation Log**: Produce a traceable investigation trail (`investigation_log.md`)
5. **Phase 5 — Report**: Generate the structured 9-section analysis report

### Report Output

Every analysis produces a **9-section structured Markdown report**:

| Section | Content |
|---------|---------|
| 1. ETL Summary | Problem, possible cause, impact, recommended action |
| 2. Possible Cause | One-line possible cause statement |
| 3. System Information | Machine, CPU, memory, OS, tool versions |
| 4. Trace Information | ETL path, file size, trace type, detected providers |
| 5. Analysis Details | Critical issues, WPA investigation, phase/service/device tables |
| 6. Analysis Findings | Severity counts and finding table with WPA evidence |
| 7. Recommendations | Prioritized action items (High / Medium / Low) |
| 8. Exported Data Files | List of all CSV files produced |
| 9. Reference Resources | Links to specs and documentation |

---

## Project Structure

```
etw-copilot/
├── .github/
│   └── copilot-instructions.md    # Copilot custom instructions (auto-loaded by VS Code)
├── analyzers/
│   ├── Analyze-FastStartup.ps1    # Boot / Fast Startup analysis
│   ├── Analyze-CpuPerformance.ps1 # CPU sampling & scheduling
│   ├── Analyze-DiskIO.ps1         # Disk I/O throughput & latency
│   ├── Analyze-Drivers.ps1        # Driver init, DPC/ISR, PnP
│   ├── Analyze-AppResponsiveness.ps1  # UI delay & hang detection
│   ├── Analyze-Memory.ps1         # Memory usage, pool, working set
│   └── Analyze-ModernStandby.ps1  # Modern Standby / Connected Standby
├── config/
│   ├── settings.json              # Tool paths, proxy, symbol path
│   └── thresholds.json            # Warning/Critical thresholds per analysis type
├── knowledge/
│   ├── known-issues.json          # Known driver/firmware issues database
│   ├── watch-functions.txt        # Functions to flag during investigation
│   ├── watch-locks.txt            # Lock objects to monitor
│   └── important-threads.txt      # Threads of interest
├── modules/
│   ├── Export-EtwData.psm1        # wpaexporter wrapper (CSV export)
│   ├── Format-Report.psm1        # Markdown report generation
│   ├── Get-TraceInfo.psm1        # Trace type detection & metadata
│   ├── Invoke-XperfAction.psm1   # xperf -a action wrapper (boot/shutdown/dpcisr)
│   └── Parse-CsvResults.psm1     # wpaexporter CSV parser
├── profiles/
│   └── export/                    # Custom wpaexporter profiles (.wpaProfile)
│       ├── CpuSampling-Export.wpaProfile
│       ├── DiskIO-Export.wpaProfile
│       ├── DpcIsr-Export.wpaProfile
│       ├── GenericEvents-Export.wpaProfile
│       └── Memory-Export.wpaProfile
├── output/                        # Generated reports and CSV data (git-ignored)
├── EtwAnalysis.psm1               # Root module — loads config, sets up environment
├── Invoke-EtwAnalysis.ps1         # Main entry point script
└── README.md
```

---

## Supported Analysis Scenarios

### Boot / Fast Startup

Analyzes Windows boot and Fast Startup traces using xperf `-a boot` (XML) and wpaexporter (CSV):

- **Boot Phase Breakdown** — 26 hierarchical regions of interest (BIOS Init → Post Boot)
- **Service Start Duration** — Identifies slow services during boot
- **PnP Device Enumeration** — Detects slow driver init and hardware enumeration
- **Process CPU Usage** — Top CPU consumers during boot
- **Disk I/O by Process** — Identifies disk-heavy boot processes

### CPU Performance

- CPU sampling with hot function identification
- Scheduling analysis (ready time, context switches)
- Process-level CPU utilization breakdown

### Disk I/O

- Throughput and latency analysis by process
- Top I/O paths and file-level breakdown
- Disk queue depth and flush counts

### Driver Analysis

- DPC/ISR duration and latency measurement
- Driver initialization timing
- USB4/Thunderbolt topology and tunnel analysis
- PnP enumeration delays

### App Responsiveness

- UI hang detection and duration
- Application launch time analysis
- Message pump delays

### Memory

- Working set and commit charge analysis
- Hard fault rates and paging activity
- Pool usage and potential leak detection

### Modern Standby

- DRIPS residency analysis
- Active time vs. idle time ratio
- Wake source identification
- Power transition timing

---

## Configuration

### Tool Paths (`config/settings.json`)

```json
{
  "WptPath": "C:\\Program Files (x86)\\Windows Kits\\10\\Windows Performance Toolkit",
  "SymbolPath": "srv*C:\\SymCache*https://msdl.microsoft.com/download/symbols",
  "Proxy": {
    "HttpProxy": "http://your-proxy:port",
    "HttpsProxy": "http://your-proxy:port",
    "NoProxy": "localhost,127.0.0.1"
  }
}
```

### Thresholds (`config/thresholds.json`)

Customizable warning/critical thresholds per analysis type:

| Category | Metric | Warning | Critical |
|----------|--------|---------|----------|
| FastStartup | Boot Total (s) | 30 | 60 |
| FastStartup | Service Delay (s) | 5 | 15 |
| Driver | DPC Duration (ms) | 1 | 10 |
| Driver | ISR Duration (µs) | 100 | 1000 |
| Cpu | Process CPU (%) | 25 | 50 |
| DiskIO | Avg Latency (ms) | 10 | 50 |
| Memory | Hard Faults/s | 1000 | 5000 |
| ModernStandby | DRIPS Residency (%) | 80 | 50 |

Edit `config/thresholds.json` to adjust thresholds for your environment.

---

## Troubleshooting

| Issue | Solution |
|-------|----------|
| `xperf.exe not found` | Install Windows Performance Toolkit from the Windows ADK, or update the path in `config/settings.json` |
| `wpaexporter hangs` | Ensure you are NOT using `-exporterconfig` JSON mode. The toolset uses CLI flags (`-i`, `-profile`, `-outputfolder`) to avoid this. If still hanging, check the 5-minute timeout in `modules/Export-EtwData.psm1`. |
| Symbols not loading | Check proxy settings in `config/settings.json`. Ensure `C:\SymCache` directory exists. First run may take several minutes to download symbols. |
| Copilot doesn't know about the tools | Make sure you're in **Agent mode** (not Ask or Edit mode). The `.github/copilot-instructions.md` file must be present in the workspace. |
| Analysis produces empty report | Verify the ETL file is valid and not corrupted. Try running `xperf -i <file>.etl -a boot` manually to test. |
| PowerShell execution policy error | Run: `Set-ExecutionPolicy -ExecutionPolicy Bypass -Scope CurrentUser` |
| Large ETL files (>1 GB) | Analysis may take several minutes. The toolset applies 5-minute timeouts on wpaexporter. Avoid using `xperf -i` on files >100 MB (can hang). |
| CSV export produces no data | Ensure the wpaexporter profile matches the trace type. Boot profiles won't produce data from a CPU-only trace. |

---

## Known Limitations

- **wpaexporter stdout/stderr redirection** causes deadlocks on large traces — intentionally disabled in this toolset
- **xperf `-i` on large files** (>100 MB) can hang — the toolset uses filename heuristics to select the right xperf action
- **Catalog profiles** are version-dependent — ensure your WPT version matches the profiles in `profiles/export/`
- Analysis quality depends on what ETW providers were enabled when the trace was captured

---

## License

This project is provided as-is for educational and diagnostic purposes.

---

## Contributing

Contributions welcome! Ideas for improvement:

- Add more wpaexporter profiles for specialized scenarios
- Enhance USB4/Thunderbolt analysis with topology visualization
- Add support for custom ETW provider decoding
- Integrate with Windows Update catalog for driver/BIOS recommendations
- Add automated regression testing against reference traces
