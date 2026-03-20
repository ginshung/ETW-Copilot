# Export Profiles

These `.wpaProfile` files are optimized for automated CSV export via `wpaexporter.exe`. They define minimal column layouts focused on data extraction rather than visual display.

## Profiles

| Profile | Purpose | Key Columns |
|---------|---------|-------------|
| `CpuSampling-Export.wpaProfile` | CPU usage by process/module/function | Process, Module, Function, Weight, Count |
| `DiskIO-Export.wpaProfile` | Disk I/O by process and file | Process, IO Type, Path, Size, Duration |
| `DpcIsr-Export.wpaProfile` | DPC/ISR duration by driver module | Module, Function, Type, Count, Duration stats |
| `Memory-Export.wpaProfile` | Virtual memory snapshots by process | Process, Working Set, Commit, Private, Shareable |
| `GenericEvents-Export.wpaProfile` | Generic ETW events by provider | Provider, Task, Opcode, Process, Fields |

## Creating New Profiles

1. Open an ETL in WPA (`wpa.exe trace.etl`)
2. Configure the table view to show exactly the columns you need
3. Save the profile: File → Save Profile
4. Place the `.wpaProfile` file in this directory
5. Reference it from the appropriate analyzer script

## Notes

- The GUIDs in column definitions must match WPA's internal column identifiers
- Export profiles should use `IsVisible="True"` only on columns to export
- `AggregationMode` determines how values are rolled up when data is grouped
