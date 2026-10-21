# GameMemDiag

Traces "out of memory" crashes in PC games. It records RAM, page file and VRAM usage while you play, then packages everything needed to diagnose the crash into one zip.

It only reads information: nothing is installed or changed. It needs only the Windows PowerShell 5.1 that ships with Windows 10/11.

## Usage

Double-click `Run-GameMemDiag.bat`:

| Option | When | What it does |
|---|---|---|
| **1 Monitor** | Before launching the game | Samples every 5 s until **Q** is pressed, then builds the report |
| **2 Collect** | After a crash, freeze/reboot, or if the monitor window was closed | Builds the report from what's already on disk, including any monitor sessions from the last 7 days |

The report is saved as `GameMemDiag_<PC>_<date>.zip` on the Desktop. `README.txt` holds the same steps written for the person running it.

Command line:

```powershell
powershell -ExecutionPolicy Bypass -File GameMemDiag.ps1 -Mode Monitor [-IntervalSeconds 5] [-DurationSeconds 0]
powershell -ExecutionPolicy Bypass -File GameMemDiag.ps1 -Mode Collect [-Days 7] [-SkipDxDiag] [-OutDir <path>] [-NoOpen]
```

## What's in the report

| File | Contents |
|---|---|
| `summary.txt` | Ranked findings: VRAM full or spilling into system RAM, commit near its limit, low-memory events, GPU driver resets, out-of-memory lines in game logs, page file problems |
| `report.html` | Charts of VRAM, commit and free RAM for each session, with dashed markers at the logged events |
| `sessions/<time>/samples.csv` | One row per sample: commit/limit, free RAM, page file %, VRAM dedicated/shared, plus nvidia-smi load/temp/clock/power on NVIDIA cards and the top RAM and VRAM process |
| `sessions/<time>/processes.csv` | The top 8 RAM users and top 5 VRAM users at every sample |
| `sessions/<time>/markers.csv` | VRAM FULL, COMMIT HIGH, a heavy process starting, and a heavy process exiting (the crash moment) |
| `system.txt` | Windows build, CPU/board/BIOS, memory modules with rated vs running speed, GPU and driver, page file setup and peak use, drives, power plan, top processes, startup programs |
| `events.txt` | Resource-Exhaustion (low memory), nvlddmkm/amdkmdag, TDR 4101, Kernel-Power 41, 6008, WHEA, bugchecks, app crashes/hangs, WER |
| `game-logs/` | Unreal Engine `Saved/Logs` and `Saved/Crashes` (including minidumps) from `%LOCALAPPDATA%`, `Documents\My Games`, `Saved Games` and Microsoft Store/Game Pass packages |
| `wer/` | Windows Error Report files and a list of crash dumps |
| `dxdiag.txt` | A full DxDiag |

The report includes the PC name and the names and paths of running programs. It does not include passwords, browsing data or personal files.

## Notes

- VRAM figures come from the Windows `GPU Adapter Memory` / `GPU Process Memory` performance counters, so they work on any vendor. nvidia-smi adds extra columns when it's present.
- Every CSV number uses invariant culture, so reports from comma-decimal locales parse the same way.
- The zip is built one entry at a time with `/` separators, because PS 5.1's `Compress-Archive` writes backslash paths.
