<#
.SYNOPSIS
  GameMemDiag - traces "out of memory" crashes in games.

  Monitor mode records RAM, page file and VRAM usage every few seconds while you
  play (including which processes are using the most), then packages a report.
  Collect mode packages the report straight away: system info, Windows event logs,
  Unreal Engine game logs / crash folders, Windows Error Reports, DxDiag, and any
  monitor sessions from the last few days.

  Everything ends up in one zip on the Desktop. Nothing is changed on the PC.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File GameMemDiag.ps1 -Mode Monitor
  powershell -ExecutionPolicy Bypass -File GameMemDiag.ps1 -Mode Collect
#>
[CmdletBinding()]
param(
    [ValidateSet('Monitor', 'Collect')]
    [string]$Mode = 'Collect',
    [ValidateRange(1, 300)]
    [int]$IntervalSeconds = 5,
    [int]$DurationSeconds = 0,          # 0 = run until Q is pressed
    [ValidateRange(1, 60)]
    [int]$Days = 7,                     # how far back to look for events, logs and sessions
    [string]$OutDir = [Environment]::GetFolderPath('Desktop'),
    [switch]$SkipDxDiag,
    [switch]$NoOpen
)

# A diagnostic tool must never stop halfway because one query failed.
$ErrorActionPreference = 'SilentlyContinue'
$ProgressPreference = 'SilentlyContinue'

$ToolVersion = '1.0'
$Inv = [Globalization.CultureInfo]::InvariantCulture
$Root = Join-Path $env:LOCALAPPDATA 'GameMemDiag'
$SessionsDir = Join-Path $Root 'sessions'
$ReportsDir = Join-Path $Root 'reports'

$CounterPaths = @(
    '\Memory\Committed Bytes',
    '\Memory\Commit Limit',
    '\Memory\Available MBytes',
    '\Paging File(_Total)\% Usage',
    '\GPU Adapter Memory(*)\Dedicated Usage',
    '\GPU Adapter Memory(*)\Shared Usage',
    '\GPU Process Memory(*)\Dedicated Usage'
)

$LogPattern = 'out of video memory|ran out of memory|out of memory|OutOfMemory|LowLevelFatalError|DXGI_ERROR_DEVICE_(REMOVED|HUNG|RESET)|device (was )?removed|GPU crash|Fatal error|EXCEPTION_ACCESS_VIOLATION|Unhandled Exception|Assertion failed|<ErrorMessage>'

# ---------------------------------------------------------------- helpers

# Numbers are always written with invariant culture so the CSV/SVG parse the same on every locale.
function N([double]$Value, [string]$Format = '0.##') { $Value.ToString($Format, $Inv) }

function ConvertTo-Number($Text) {
    $d = 0.0
    if ([double]::TryParse([string]$Text, [Globalization.NumberStyles]::Float, $Inv, [ref]$d)) { return $d }
    return $null
}

function Get-Pct([double]$Part, [double]$Whole) { if ($Whole -gt 0) { 100.0 * $Part / $Whole } else { 0 } }

function Write-Step([string]$Text) { Write-Host "  - $Text" -ForegroundColor Cyan }

function Add-Section([string]$File, [string]$Title, $Body) {
    Add-Content -Path $File -Encoding UTF8 -Value "`r`n===== $Title ====="
    $text = if ($Body -is [string]) { $Body } else { $Body | Out-String -Width 300 }
    Add-Content -Path $File -Encoding UTF8 -Value $text.Trim("`r", "`n")
}

function HtmlEncode([string]$Text) { [System.Net.WebUtility]::HtmlEncode($Text) }

function Get-NvidiaSmiPath {
    $cmd = Get-Command nvidia-smi.exe
    if ($cmd) { return $cmd.Source }
    $p = Join-Path $env:WINDIR 'System32\nvidia-smi.exe'
    if (Test-Path $p) { return $p }
    return $null
}
$NvSmi = Get-NvidiaSmiPath

function Get-NvidiaStats {
    if (-not $NvSmi) { return $null }
    try {
        $line = & $NvSmi --query-gpu=memory.used,memory.total,utilization.gpu,temperature.gpu,clocks.gr,power.draw --format=csv,noheader,nounits 2>$null | Select-Object -First 1
        if (-not $line) { return $null }
        $f = @($line -split ',' | ForEach-Object { $_.Trim() })
        return [pscustomobject]@{
            UsedMB  = ConvertTo-Number $f[0]
            TotalMB = ConvertTo-Number $f[1]
            Util    = ConvertTo-Number $f[2]
            TempC   = ConvertTo-Number $f[3]
            ClockMHz = ConvertTo-Number $f[4]
            PowerW  = ConvertTo-Number $f[5]
        }
    } catch { return $null }
}

function Get-VramTotalMB {
    $nv = Get-NvidiaStats
    if ($nv -and $nv.TotalMB) { return $nv.TotalMB }
    # Win32_VideoController.AdapterRAM caps at 4 GB, so read the driver's 64-bit value instead.
    $max = 0
    Get-ChildItem 'HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}' | ForEach-Object {
        $v = (Get-ItemProperty $_.PSPath -Name 'HardwareInformation.qwMemorySize').'HardwareInformation.qwMemorySize'
        if ($v -and [double]$v -gt $max) { $max = [double]$v }
    }
    if ($max -gt 0) { return [math]::Round($max / 1MB) }
    return 0
}

# ---------------------------------------------------------------- monitor

function Get-Sample([double]$VramTotalMB) {
    $now = Get-Date
    $cs = @()
    try { $cs = (Get-Counter -Counter $CounterPaths).CounterSamples } catch { }

    $commit = 0; $limit = 0; $availMB = 0; $pf = 0; $ded = 0; $shared = 0
    $procVram = @{}
    foreach ($c in $cs) {
        $path = $c.Path
        $v = $c.CookedValue
        if ($path -like '*\memory\committed bytes') { $commit = $v }
        elseif ($path -like '*\memory\commit limit') { $limit = $v }
        elseif ($path -like '*\memory\available mbytes') { $availMB = $v }
        elseif ($path -like '*\paging file(_total)\% usage') { $pf = $v }
        elseif ($path -like '*\gpu adapter memory(*)\dedicated usage') { if ($v -gt $ded) { $ded = $v } }
        elseif ($path -like '*\gpu adapter memory(*)\shared usage') { if ($v -gt $shared) { $shared = $v } }
        elseif ($path -like '*\gpu process memory(*)\dedicated usage') {
            if ($c.InstanceName -match '^pid_(\d+)_') {
                $procId = [int]$Matches[1]
                $procVram[$procId] = [double]$procVram[$procId] + $v
            }
        }
    }

    $nv = Get-NvidiaStats
    $procs = @(Get-Process)
    $byPid = @{}
    foreach ($p in $procs) { $byPid[$p.Id] = $p }

    $topRam = @($procs | Where-Object { $_.Id -ne 0 } | Sort-Object PrivateMemorySize64 -Descending | Select-Object -First 8)
    $topVramIds = @($procVram.GetEnumerator() | Where-Object { $_.Value -gt 0 } | Sort-Object Value -Descending | Select-Object -First 5 | ForEach-Object { $_.Key })
    $ids = @(@($topRam | ForEach-Object { $_.Id }) + $topVramIds | Select-Object -Unique)

    $stamp = $now.ToString('yyyy-MM-dd HH:mm:ss')
    $procRows = foreach ($id in $ids) {
        $p = $byPid[$id]
        [pscustomobject]@{
            Time         = $stamp
            Pid          = $id
            Name         = if ($p) { $p.ProcessName } else { "pid$id" }
            PrivateMB    = if ($p) { N ($p.PrivateMemorySize64 / 1MB) '0' } else { '' }
            WorkingSetMB = if ($p) { N ($p.WorkingSet64 / 1MB) '0' } else { '' }
            VramMB       = N ([double]$procVram[$id] / 1MB) '0'
        }
    }

    # Heavy processes are tracked so we can log the moment one disappears (a crash or exit).
    $heavy = @{}
    foreach ($p in $procs) {
        $ramMB = $p.PrivateMemorySize64 / 1MB
        $vramMB = [double]$procVram[$p.Id] / 1MB
        if ($p.Id -ne 0 -and ($ramMB -ge 2048 -or $vramMB -ge 1024)) {
            $heavy[$p.Id] = [pscustomobject]@{ Name = $p.ProcessName; RamMB = $ramMB; VramMB = $vramMB }
        }
    }

    $topR = $topRam | Select-Object -First 1
    $topV = $topVramIds | Select-Object -First 1
    $topVName = ''
    if ($topV) { $topVName = if ($byPid[$topV]) { $byPid[$topV].ProcessName } else { "pid$topV" } }
    $vramUsedMB = $ded / 1MB

    $row = [pscustomobject]@{
        Time             = $stamp
        CommitGB         = N ($commit / 1GB)
        CommitLimitGB    = N ($limit / 1GB)
        CommitPct        = N (Get-Pct $commit $limit) '0.#'
        AvailRamGB       = N ($availMB / 1024)
        PagefileUsePct   = N $pf '0.#'
        VramUsedMB       = N $vramUsedMB '0'
        VramSharedMB     = N ($shared / 1MB) '0'
        VramTotalMB      = N $VramTotalMB '0'
        VramPct          = N (Get-Pct $vramUsedMB $VramTotalMB) '0.#'
        NvSmiUsedMB      = if ($nv) { N $nv.UsedMB '0' } else { '' }
        GpuUtilPct       = if ($nv) { N $nv.Util '0' } else { '' }
        GpuTempC         = if ($nv) { N $nv.TempC '0' } else { '' }
        GpuClockMHz      = if ($nv) { N $nv.ClockMHz '0' } else { '' }
        GpuPowerW        = if ($nv) { N $nv.PowerW '0.#' } else { '' }
        TopRamProcess    = if ($topR) { $topR.ProcessName } else { '' }
        TopRamProcessMB  = if ($topR) { N ($topR.PrivateMemorySize64 / 1MB) '0' } else { '' }
        TopVramProcess   = $topVName
        TopVramProcessMB = if ($topV) { N ([double]$procVram[$topV] / 1MB) '0' } else { '' }
    }

    return @{ Row = $row; ProcRows = @($procRows); Heavy = $heavy; ByPid = $byPid }
}

function Test-QuitKey {
    try {
        while ([Console]::KeyAvailable) {
            if ([Console]::ReadKey($true).Key -eq [ConsoleKey]::Q) { return $true }
        }
    } catch { }   # no console attached (e.g. redirected input)
    return $false
}

function Start-Monitor {
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $dir = Join-Path $SessionsDir $stamp
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    $samplesCsv = Join-Path $dir 'samples.csv'
    $procsCsv = Join-Path $dir 'processes.csv'
    $markersCsv = Join-Path $dir 'markers.csv'
    $script:SampleIndex = 0

    $addMarker = {
        param([string]$Text, [string]$Color = 'Yellow')
        $t = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
        [pscustomobject]@{ Time = $t; Sample = $script:SampleIndex; Text = $Text } |
            Export-Csv -Path $markersCsv -Append -NoTypeInformation -Encoding UTF8
        Write-Host "  >> [$t] $Text" -ForegroundColor $Color
    }

    $vramTotal = Get-VramTotalMB
    Write-Host ''
    Write-Host '  MONITORING. Leave this window open and play as normal.' -ForegroundColor Green
    Write-Host '  When the game crashes (or you are done), come back here and press Q.' -ForegroundColor Green
    Write-Host "  Sampling every $IntervalSeconds s. Data is saved as it goes, so a hard freeze or reboot loses nothing:" -ForegroundColor DarkGray
    Write-Host '  after a reboot just run the tool again and choose option 2.' -ForegroundColor DarkGray
    Write-Host ''
    & $addMarker ("Session started on {0}, interval {1}s, VRAM {2} MB" -f $env:COMPUTERNAME, $IntervalSeconds, $vramTotal) 'DarkGray'

    $watch = @{}
    $vramFull = $false; $commitHigh = $false
    $started = Get-Date
    $stop = $false
    while (-not $stop) {
        $tick = Get-Date
        $s = Get-Sample $vramTotal
        $r = $s.Row
        $r | Export-Csv -Path $samplesCsv -Append -NoTypeInformation -Encoding UTF8
        if ($s.ProcRows.Count) { $s.ProcRows | Export-Csv -Path $procsCsv -Append -NoTypeInformation -Encoding UTF8 }

        foreach ($id in @($watch.Keys)) {
            if (-not $s.ByPid.ContainsKey($id)) {
                $w = $watch[$id]
                & $addMarker ("EXITED: {0} (pid {1}) - last RAM {2} MB, VRAM {3} MB" -f $w.Name, $id, (N $w.RamMB '0'), (N $w.VramMB '0')) 'Red'
            }
        }
        foreach ($id in @($s.Heavy.Keys)) {
            if (-not $watch.ContainsKey($id)) {
                $h = $s.Heavy[$id]
                & $addMarker ("HEAVY PROCESS: {0} (pid {1}) RAM {2} MB, VRAM {3} MB" -f $h.Name, $id, (N $h.RamMB '0'), (N $h.VramMB '0')) 'DarkYellow'
            }
        }
        $watch = $s.Heavy

        $vp = ConvertTo-Number $r.VramPct
        $cp = ConvertTo-Number $r.CommitPct
        if ($vp -ge 95 -and -not $vramFull) { $vramFull = $true; & $addMarker ("VRAM FULL: {0} of {1} MB used, {2} MB spilled to shared" -f $r.VramUsedMB, $r.VramTotalMB, $r.VramSharedMB) 'Red' }
        elseif ($vp -lt 90) { $vramFull = $false }
        if ($cp -ge 90 -and -not $commitHigh) { $commitHigh = $true; & $addMarker ("COMMIT HIGH: {0} of {1} GB (RAM + page file) in use" -f $r.CommitGB, $r.CommitLimitGB) 'Red' }
        elseif ($cp -lt 85) { $commitHigh = $false }

        $color = 'Gray'
        if ($vp -ge 95 -or $cp -ge 90) { $color = 'Red' } elseif ($vp -ge 85 -or $cp -ge 80) { $color = 'Yellow' }
        Write-Host ('  {0}  RAM commit {1}/{2} GB ({3}%)  free {4} GB | VRAM {5}/{6} MB ({7}%) | top RAM: {8} {9} MB | top VRAM: {10} {11} MB' -f `
                $r.Time.Substring(11), $r.CommitGB, $r.CommitLimitGB, $r.CommitPct, $r.AvailRamGB, $r.VramUsedMB, $r.VramTotalMB, $r.VramPct,
                $r.TopRamProcess, $r.TopRamProcessMB, $r.TopVramProcess, $r.TopVramProcessMB) -ForegroundColor $color

        $script:SampleIndex++
        $next = $tick.AddSeconds($IntervalSeconds)
        while ((Get-Date) -lt $next) {
            if (Test-QuitKey) { $stop = $true; break }
            Start-Sleep -Milliseconds 200
        }
        if ($DurationSeconds -gt 0 -and ((Get-Date) - $started).TotalSeconds -ge $DurationSeconds) { $stop = $true }
    }
    & $addMarker 'Session stopped' 'DarkGray'
    Write-Host ''
}

# ---------------------------------------------------------------- report: data gathering

function Get-SystemInfo {
    $i = @{}
    $i.OS = Get-CimInstance Win32_OperatingSystem
    $i.CS = Get-CimInstance Win32_ComputerSystem
    $i.CPU = @(Get-CimInstance Win32_Processor)
    $i.Board = Get-CimInstance Win32_BaseBoard
    $i.BIOS = Get-CimInstance Win32_BIOS
    $i.RAM = @(Get-CimInstance Win32_PhysicalMemory)
    $i.GPU = @(Get-CimInstance Win32_VideoController)
    $i.PageSettings = @(Get-CimInstance Win32_PageFileSetting)
    $i.PageUsage = @(Get-CimInstance Win32_PageFileUsage)
    $i.Disks = @(Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3')
    $i.VramTotalMB = Get-VramTotalMB
    $i.Hags = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers' -Name HwSchMode).HwSchMode
    $i.WinVer = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
    return $i
}

function Write-SystemInfo($Info, [string]$File) {
    $os = $Info.OS
    Add-Section $File 'GameMemDiag' ("Version {0}  |  report created {1}  |  mode {2}" -f $ToolVersion, (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Mode)

    Add-Section $File 'Windows' ([pscustomobject]@{
            Edition      = $os.Caption
            Version      = $Info.WinVer.DisplayVersion
            Build        = '{0}.{1}' -f $os.BuildNumber, $Info.WinVer.UBR
            LastBoot     = $os.LastBootUpTime
            UptimeHours  = N ((Get-Date) - $os.LastBootUpTime).TotalHours '0.#'
            ComputerName = $env:COMPUTERNAME
        } | Format-List)

    Add-Section $File 'CPU / motherboard' (@(
            $Info.CPU | Select-Object Name, NumberOfCores, NumberOfLogicalProcessors, MaxClockSpeed | Format-List | Out-String
            [pscustomobject]@{ Board = '{0} {1}' -f $Info.Board.Manufacturer, $Info.Board.Product; BIOS = $Info.BIOS.SMBIOSBIOSVersion; BIOSDate = $Info.BIOS.ReleaseDate } | Format-List | Out-String
        ) -join '')

    $ram = $Info.RAM | Select-Object BankLabel, DeviceLocator, Manufacturer, PartNumber,
        @{ n = 'GB'; e = { N ($_.Capacity / 1GB) '0' } }, @{ n = 'RatedMTs'; e = { $_.Speed } }, @{ n = 'RunningMTs'; e = { $_.ConfiguredClockSpeed } }
    Add-Section $File 'Memory modules' (@(
            'Total installed: {0} GB in {1} module(s)' -f (N (($Info.RAM | Measure-Object Capacity -Sum).Sum / 1GB) '0'), $Info.RAM.Count
            ($ram | Format-Table -AutoSize | Out-String)
        ) -join "`r`n")

    $gpus = $Info.GPU | Select-Object Name, DriverVersion, DriverDate, VideoModeDescription, CurrentRefreshRate | Format-List | Out-String
    $hags = switch ($Info.Hags) { 2 { 'On' } 1 { 'Off' } default { 'Unknown/default' } }
    $gpuText = "{0}`r`nVRAM total: {1} MB`r`nHardware-accelerated GPU scheduling: {2}" -f $gpus.TrimEnd(), $Info.VramTotalMB, $hags
    if ($NvSmi) { $gpuText += "`r`n`r`nnvidia-smi:`r`n" + ((& $NvSmi 2>&1) | Out-String) }
    Add-Section $File 'Graphics' $gpuText

    $pfMode = if ($Info.CS.AutomaticManagedPagefile) { 'System managed (automatic)' } else { 'Manually configured' }
    $settings = if ($Info.PageSettings.Count) { $Info.PageSettings | Select-Object Name, @{ n = 'InitialMB'; e = { $_.InitialSize } }, @{ n = 'MaximumMB'; e = { $_.MaximumSize } } | Format-Table -AutoSize | Out-String } else { '(no per-drive settings)' }
    $usage = if ($Info.PageUsage.Count) { $Info.PageUsage | Select-Object Name, @{ n = 'AllocatedMB'; e = { $_.AllocatedBaseSize } }, @{ n = 'CurrentUseMB'; e = { $_.CurrentUsage } }, @{ n = 'PeakUseMB'; e = { $_.PeakUsage } } | Format-Table -AutoSize | Out-String } else { 'NO PAGE FILE IS ACTIVE' }
    Add-Section $File 'Page file' ("Mode: {0}`r`nCommit limit (RAM + page file): {1} GB`r`n`r`nSettings:{2}`r`nUsage since boot:{3}" -f `
            $pfMode, (N ($os.TotalVirtualMemorySize / 1MB) '0.#'), $settings, $usage)

    Add-Section $File 'Drives' ($Info.Disks | Select-Object DeviceID, VolumeName, @{ n = 'SizeGB'; e = { N ($_.Size / 1GB) '0' } }, @{ n = 'FreeGB'; e = { N ($_.FreeSpace / 1GB) '0.#' } } | Format-Table -AutoSize)

    Add-Section $File 'Power plan' ((powercfg /getactivescheme) | Out-String)

    Add-Section $File 'Top 30 processes by committed memory (right now)' (Get-Process | Sort-Object PrivateMemorySize64 -Descending | Select-Object -First 30 `
            Name, Id, @{ n = 'PrivateMB'; e = { N ($_.PrivateMemorySize64 / 1MB) '0' } }, @{ n = 'WorkingSetMB'; e = { N ($_.WorkingSet64 / 1MB) '0' } }, Path | Format-Table -AutoSize)

    Add-Section $File 'Startup programs' (Get-CimInstance Win32_StartupCommand | Select-Object Name, Location, Command | Format-List)
}

function Get-DiagEvents([datetime]$Since) {
    $queries = @(
        @{ Tag = 'LowMemory';          Log = 'System';      Provider = 'Microsoft-Windows-Resource-Exhaustion-Detector' },
        @{ Tag = 'NvidiaDriver';       Log = 'System';      Provider = 'nvlddmkm' },
        @{ Tag = 'AmdDriver';          Log = 'System';      Provider = 'amdkmdag' },
        @{ Tag = 'GpuReset';           Log = 'System';      Provider = 'Display'; Id = 4101 },
        @{ Tag = 'HardReset';          Log = 'System';      Provider = 'Microsoft-Windows-Kernel-Power'; Id = 41 },
        @{ Tag = 'UnexpectedShutdown'; Log = 'System';      Provider = 'EventLog'; Id = 6008 },
        @{ Tag = 'HardwareError';      Log = 'System';      Provider = 'Microsoft-Windows-WHEA-Logger' },
        @{ Tag = 'BlueScreen';         Log = 'System';      Provider = 'Microsoft-Windows-WER-SystemErrorReporting' },
        @{ Tag = 'AppCrash';           Log = 'Application'; Provider = 'Application Error'; Id = 1000 },
        @{ Tag = 'AppHang';            Log = 'Application'; Provider = 'Application Hang'; Id = 1002 },
        @{ Tag = 'ErrorReport';        Log = 'Application'; Provider = 'Windows Error Reporting'; Id = 1001 }
    )
    $all = foreach ($q in $queries) {
        $filter = @{ LogName = $q.Log; ProviderName = $q.Provider; StartTime = $Since }
        if ($q.Id) { $filter.Id = $q.Id }
        Get-WinEvent -FilterHashtable $filter -MaxEvents 150 | ForEach-Object {
            $msg = $_.Message
            if (-not $msg) { $msg = ($_.Properties | ForEach-Object { $_.Value }) -join ' | ' }
            [pscustomobject]@{
                Time     = $_.TimeCreated
                Tag      = $q.Tag
                Provider = $_.ProviderName
                Id       = $_.Id
                Level    = $_.LevelDisplayName
                Message  = $msg
            }
        }
    }
    return @($all | Sort-Object Time -Descending)
}

function Write-Events($Events, [string]$File) {
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add("Windows events since $((Get-Date).AddDays(-$Days).ToString('yyyy-MM-dd HH:mm')) (newest first)")
    $lines.Add('')
    $lines.Add('Counts by type:')
    foreach ($g in ($Events | Group-Object Tag | Sort-Object Count -Descending)) { $lines.Add(('  {0,-20} {1}' -f $g.Name, $g.Count)) }
    $lines.Add('')
    foreach ($e in $Events) {
        $lines.Add(('[{0}] {1}  {2} #{3} ({4})' -f $e.Time.ToString('yyyy-MM-dd HH:mm:ss'), $e.Tag, $e.Provider, $e.Id, $e.Level))
        $msg = [string]$e.Message
        if ($msg.Length -gt 4000) { $msg = $msg.Substring(0, 4000) + ' ...' }
        foreach ($l in ($msg -split "`r?`n")) { if ($l.Trim()) { $lines.Add('    ' + $l.TrimEnd()) } }
        $lines.Add('')
    }
    $lines | Out-File -FilePath $File -Encoding UTF8
}

# Unreal Engine games write logs and crash folders to <somewhere>\<Game>\Saved\{Logs,Crashes}.
function Get-UnrealSavedDirs {
    $found = New-Object System.Collections.Generic.List[object]
    $bases = @(
        $env:LOCALAPPDATA,
        (Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'My Games'),
        (Join-Path $env:USERPROFILE 'Saved Games')
    )
    foreach ($base in $bases) {
        if (-not (Test-Path $base)) { continue }
        foreach ($d in (Get-ChildItem -Path $base -Directory)) {
            if ($d.Name -in 'EpicGamesLauncher', 'UnrealEngine', 'UnrealEngineLauncher') { continue }   # launchers/editor, not games
            $saved = Join-Path $d.FullName 'Saved'
            if ((Test-Path (Join-Path $saved 'Logs')) -or (Test-Path (Join-Path $saved 'Crashes'))) {
                $found.Add([pscustomobject]@{ Game = $d.Name; Saved = $saved })
            }
        }
    }
    # Microsoft Store / Game Pass titles keep their data inside the app package.
    foreach ($pkg in (Get-ChildItem -Path (Join-Path $env:LOCALAPPDATA 'Packages') -Directory)) {
        $local = Join-Path $pkg.FullName 'LocalCache\Local'
        if (-not (Test-Path $local)) { continue }
        foreach ($d in (Get-ChildItem -Path $local -Directory)) {
            $saved = Join-Path $d.FullName 'Saved'
            if ((Test-Path (Join-Path $saved 'Logs')) -or (Test-Path (Join-Path $saved 'Crashes'))) {
                $found.Add([pscustomobject]@{ Game = 'Store-' + $d.Name; Saved = $saved })
            }
        }
    }
    return $found
}

function Copy-LimitedFile([string]$Source, [string]$Dest, [long]$MaxBytes) {
    $f = Get-Item -LiteralPath $Source
    if ($f.Length -le $MaxBytes) { Copy-Item -LiteralPath $Source -Destination $Dest -Force; return }
    # Too big to send whole: keep the end, which is where a crash is written.
    $tail = Get-Content -LiteralPath $Source -Tail 25000
    @("[GameMemDiag: file was $(N ($f.Length / 1MB) '0') MB, only the last 25000 lines are included]") + $tail | Out-File -FilePath $Dest -Encoding UTF8
}

function Copy-GameLogs([datetime]$Since, [string]$Dest) {
    $hits = New-Object System.Collections.Generic.List[object]
    $games = New-Object System.Collections.Generic.List[string]
    foreach ($g in (Get-UnrealSavedDirs)) {
        $logs = @(Get-ChildItem -Path (Join-Path $g.Saved 'Logs') -File -Filter '*.log' | Where-Object { $_.LastWriteTime -ge $Since } | Sort-Object LastWriteTime -Descending | Select-Object -First 6)
        $crashes = @(Get-ChildItem -Path (Join-Path $g.Saved 'Crashes') -Directory | Where-Object { $_.LastWriteTime -ge $Since } | Sort-Object LastWriteTime -Descending | Select-Object -First 8)
        if (-not $logs.Count -and -not $crashes.Count) { continue }

        $gameDir = Join-Path $Dest ($g.Game -replace '[^\w\.-]', '_')
        New-Item -ItemType Directory -Path $gameDir -Force | Out-Null
        "Source: $($g.Saved)" | Out-File -FilePath (Join-Path $gameDir '_source.txt') -Encoding UTF8
        $games.Add($g.Game)

        $scan = New-Object System.Collections.Generic.List[string]
        if ($logs.Count) {
            $logDir = Join-Path $gameDir 'Logs'
            New-Item -ItemType Directory -Path $logDir -Force | Out-Null
            foreach ($l in $logs) {
                $target = Join-Path $logDir $l.Name
                Copy-LimitedFile $l.FullName $target 40MB
                $scan.Add($target)
            }
        }
        foreach ($c in $crashes) {
            $cDir = Join-Path $gameDir ('Crashes\' + $c.Name)
            New-Item -ItemType Directory -Path $cDir -Force | Out-Null
            foreach ($f in (Get-ChildItem -Path $c.FullName -File)) {
                if ($f.Length -le 150MB) { Copy-Item -LiteralPath $f.FullName -Destination $cDir -Force }
                else { "Skipped $($f.Name): $(N ($f.Length / 1MB) '0') MB" | Out-File -FilePath (Join-Path $cDir '_skipped.txt') -Append -Encoding UTF8 }
                if ($f.Extension -in '.log', '.xml', '.txt' -or $f.Name -like '*.runtime-xml') { $scan.Add((Join-Path $cDir $f.Name)) }
            }
        }

        foreach ($file in $scan) {
            Select-String -LiteralPath $file -Pattern $LogPattern | Select-Object -First 40 | ForEach-Object {
                $text = $_.Line.Trim()
                if ($text.Length -gt 400) { $text = $text.Substring(0, 400) + ' ...' }
                $hits.Add([pscustomobject]@{ Game = $g.Game; File = $file.Substring($Dest.Length + 1); Line = $_.LineNumber; Text = $text })
            }
        }
    }
    return [pscustomobject]@{ Games = $games; Hits = $hits }
}

function Copy-WerReports([datetime]$Since, [string]$Dest) {
    New-Item -ItemType Directory -Path $Dest -Force | Out-Null
    $roots = @(
        (Join-Path $env:ProgramData 'Microsoft\Windows\WER\ReportArchive'),
        (Join-Path $env:ProgramData 'Microsoft\Windows\WER\ReportQueue'),
        (Join-Path $env:LOCALAPPDATA 'Microsoft\Windows\WER\ReportArchive'),
        (Join-Path $env:LOCALAPPDATA 'Microsoft\Windows\WER\ReportQueue')
    )
    $reports = foreach ($r in $roots) { Get-ChildItem -Path $r -Directory | Where-Object { $_.LastWriteTime -ge $Since -and (Test-Path (Join-Path $_.FullName 'Report.wer')) } }
    foreach ($rep in @($reports | Sort-Object LastWriteTime -Descending | Select-Object -First 60)) {
        Copy-Item -LiteralPath (Join-Path $rep.FullName 'Report.wer') -Destination (Join-Path $Dest ($rep.Name + '.txt')) -Force
    }

    # Dumps can be huge, so only list them; they can be fetched separately if needed.
    $listing = New-Object System.Collections.Generic.List[string]
    foreach ($d in @((Join-Path $env:LOCALAPPDATA 'CrashDumps'), (Join-Path $env:WINDIR 'LiveKernelReports'), (Join-Path $env:WINDIR 'Minidump'))) {
        $listing.Add("== $d")
        Get-ChildItem -Path $d -Recurse -File | Where-Object { $_.LastWriteTime -ge $Since } | Sort-Object LastWriteTime -Descending | ForEach-Object {
            $listing.Add(('  {0}  {1,10} KB  {2}' -f $_.LastWriteTime.ToString('yyyy-MM-dd HH:mm'), (N ($_.Length / 1KB) '0'), $_.FullName))
        }
    }
    $listing | Out-File -FilePath (Join-Path $Dest '_dump-files.txt') -Encoding UTF8
}

function Get-SessionStats([string]$Dir) {
    $rows = @(Import-Csv -Path (Join-Path $Dir 'samples.csv'))
    if (-not $rows.Count) { return $null }
    $markers = @(Import-Csv -Path (Join-Path $Dir 'markers.csv'))
    $peak = { param($col) ($rows | ForEach-Object { ConvertTo-Number $_.$col } | Measure-Object -Maximum).Maximum }
    $topRam = $rows | Sort-Object { ConvertTo-Number $_.TopRamProcessMB } -Descending | Select-Object -First 1
    $topVram = $rows | Sort-Object { ConvertTo-Number $_.TopVramProcessMB } -Descending | Select-Object -First 1
    return [pscustomobject]@{
        Name          = Split-Path $Dir -Leaf
        Dir           = $Dir
        Rows          = $rows
        Markers       = $markers
        Start         = $rows[0].Time
        End           = $rows[-1].Time
        Samples       = $rows.Count
        VramTotalMB   = ConvertTo-Number $rows[0].VramTotalMB
        PeakVramMB    = & $peak 'VramUsedMB'
        PeakVramPct   = & $peak 'VramPct'
        PeakSharedMB  = & $peak 'VramSharedMB'
        PeakCommitGB  = & $peak 'CommitGB'
        CommitLimitGB = & $peak 'CommitLimitGB'
        PeakCommitPct = & $peak 'CommitPct'
        MinAvailGB    = ($rows | ForEach-Object { ConvertTo-Number $_.AvailRamGB } | Measure-Object -Minimum).Minimum
        PeakTempC     = & $peak 'GpuTempC'
        TopRam        = '{0} {1} MB' -f $topRam.TopRamProcess, $topRam.TopRamProcessMB
        TopVram       = '{0} {1} MB' -f $topVram.TopVramProcess, $topVram.TopVramProcessMB
    }
}

function Invoke-DxDiag([string]$File) {
    $p = Start-Process -FilePath (Join-Path $env:WINDIR 'System32\dxdiag.exe') -ArgumentList "/whql:off /t `"$File`"" -PassThru -WindowStyle Hidden
    $deadline = (Get-Date).AddSeconds(120)
    while ((Get-Date) -lt $deadline -and -not $p.HasExited) { Start-Sleep -Milliseconds 500 }
    if (-not $p.HasExited) { $p | Stop-Process -Force }
}

# ---------------------------------------------------------------- report: analysis

function Get-Findings($Info, $Events, $LogResult, $Sessions) {
    $f = New-Object System.Collections.Generic.List[object]
    $add = { param($Sev, $Text) $f.Add([pscustomobject]@{ Severity = $Sev; Text = $Text }) }

    foreach ($s in $Sessions) {
        $label = "Session $($s.Start) to $($s.End.Substring(11))"
        & $add 'INFO' ("{0}: peak VRAM {1}/{2} MB, peak commit {3}/{4} GB, biggest RAM user {5}, biggest VRAM user {6}." -f `
                $label, (N $s.PeakVramMB '0'), (N $s.VramTotalMB '0'), (N $s.PeakCommitGB '0.#'), (N $s.CommitLimitGB '0.#'), $s.TopRam, $s.TopVram)
        if ($s.PeakVramPct -ge 95) {
            & $add 'HIGH' ("{0}: VRAM was full - peak {1} of {2} MB ({3}%). Top VRAM user: {4}." -f $label, (N $s.PeakVramMB '0'), (N $s.VramTotalMB '0'), (N $s.PeakVramPct '0'), $s.TopVram)
        } elseif ($s.PeakVramPct -ge 85) {
            & $add 'WARN' ("{0}: VRAM ran close to full - peak {1} of {2} MB ({3}%)." -f $label, (N $s.PeakVramMB '0'), (N $s.VramTotalMB '0'), (N $s.PeakVramPct '0'))
        }
        if ($s.PeakSharedMB -ge 1024 -and $s.PeakVramPct -ge 90) {
            & $add 'HIGH' ("{0}: {1} MB of graphics data spilled into system RAM (shared GPU memory) - the card ran out of its own memory." -f $label, (N $s.PeakSharedMB '0'))
        }
        if ($s.PeakCommitPct -ge 90) {
            & $add 'HIGH' ("{0}: system commit hit {1}% ({2} of {3} GB). RAM + page file nearly exhausted - check page file size and the top RAM process ({4})." -f $label, (N $s.PeakCommitPct '0'), (N $s.PeakCommitGB '0.#'), (N $s.CommitLimitGB '0.#'), $s.TopRam)
        }
        if ($s.MinAvailGB -lt 2) {
            & $add 'WARN' ("{0}: free physical RAM dropped to {1} GB." -f $label, (N $s.MinAvailGB '0.##'))
        }
        if ($s.PeakTempC -ge 85) {
            & $add 'WARN' ("{0}: GPU reached {1} C." -f $label, (N $s.PeakTempC '0'))
        }
        foreach ($m in ($s.Markers | Where-Object { $_.Text -like 'EXITED:*' })) {
            & $add 'INFO' ("{0}: {1} at {2}" -f $label, $m.Text, $m.Time)
        }
    }
    if (-not $Sessions.Count) { & $add 'INFO' 'No monitor session recorded yet. Run option 1 before playing to capture RAM/VRAM usage up to the crash.' }

    $byTag = @{}
    foreach ($g in ($Events | Group-Object Tag)) { $byTag[$g.Name] = @($g.Group) }
    if ($byTag['LowMemory']) {
        & $add 'HIGH' ("Windows logged {0} low-memory warning(s) (Resource-Exhaustion-Detector). These name the processes using the most memory - see events.txt. Latest: {1}" -f $byTag['LowMemory'].Count, $byTag['LowMemory'][0].Time)
    }
    if ($byTag['GpuReset'] -or $byTag['NvidiaDriver'] -or $byTag['AmdDriver']) {
        $n = @($byTag['GpuReset']).Count + @($byTag['NvidiaDriver']).Count + @($byTag['AmdDriver']).Count
        & $add 'HIGH' "Graphics driver errors/resets logged: $n (TDR / nvlddmkm / amdkmdag). A crashing driver can show up in games as an out-of-memory error."
    }
    if ($byTag['HardReset']) { & $add 'HIGH' ("{0} unexpected power loss / hard reset(s) (Kernel-Power 41)." -f $byTag['HardReset'].Count) }
    if ($byTag['BlueScreen']) { & $add 'HIGH' ("{0} blue screen(s) logged." -f $byTag['BlueScreen'].Count) }
    if ($byTag['HardwareError']) { & $add 'WARN' ("{0} WHEA hardware error(s) logged (CPU/RAM/PCIe)." -f $byTag['HardwareError'].Count) }

    $hits = @($LogResult.Hits)
    $vramHits = @($hits | Where-Object { $_.Text -match 'video memory' })
    $ramHits = @($hits | Where-Object { $_.Text -match 'ran out of memory|OutOfMemory|out of memory' -and $_.Text -notmatch 'video memory' })
    $devHits = @($hits | Where-Object { $_.Text -match 'DXGI_ERROR_DEVICE|device (was )?removed|GPU crash' })
    if ($vramHits.Count) { & $add 'HIGH' ("Game log says OUT OF VIDEO MEMORY ({0} line(s), {1}). Fix: lower texture quality / ray tracing, enable DLSS, close OBS/browser while playing." -f $vramHits.Count, (($vramHits | Select-Object -ExpandProperty Game -Unique) -join ', ')) }
    if ($ramHits.Count) { & $add 'HIGH' ("Game log says out of (system) memory ({0} line(s), {1})." -f $ramHits.Count, (($ramHits | Select-Object -ExpandProperty Game -Unique) -join ', ')) }
    if ($devHits.Count) { & $add 'HIGH' ("Game log reports the GPU device was removed/hung ({0} line(s), {1}) - driver crash, unstable GPU clock, or power." -f $devHits.Count, (($devHits | Select-Object -ExpandProperty Game -Unique) -join ', ')) }
    if ($LogResult.Games.Count) { & $add 'INFO' ("Unreal game logs collected for: {0}" -f ($LogResult.Games -join ', ')) }
    else { & $add 'INFO' "No Unreal game logs from the last $Days days were found in the usual places." }

    if (-not $Info.PageUsage.Count) {
        & $add 'HIGH' 'No page file is active. Games can fail to allocate memory even with lots of RAM free. Set it back to "System managed".'
    } elseif (-not $Info.CS.AutomaticManagedPagefile) {
        $maxMB = ($Info.PageSettings | Measure-Object MaximumSize -Sum).Sum
        if ($maxMB -gt 0 -and $maxMB -lt 16384) { & $add 'WARN' "Page file is manually capped at $maxMB MB. Consider 'System managed' or at least 16-32 GB." }
    }
    $sysDrive = $Info.Disks | Where-Object { $_.DeviceID -eq $env:SystemDrive }
    if ($sysDrive -and $sysDrive.FreeSpace -lt 15GB) { & $add 'WARN' ("Only {0} GB free on {1} - the page file cannot grow." -f (N ($sysDrive.FreeSpace / 1GB) '0.#'), $env:SystemDrive) }

    $order = @{ HIGH = 0; WARN = 1; INFO = 2 }
    return @($f | Sort-Object @{ e = { $order[$_.Severity] } }, @{ e = { $f.IndexOf($_) } })
}

# ---------------------------------------------------------------- report: output

# Rounds an axis maximum up so the four gridlines land on 1/2/2.5/5 x 10^n steps.
function Get-NiceMax([double]$Value) {
    if ($Value -le 0) { return 1 }
    $raw = $Value / 4
    $mag = [math]::Pow(10, [math]::Floor([math]::Log10($raw)))
    foreach ($m in 1, 2, 2.5, 5, 10) { if ($m * $mag -ge $raw) { return 4 * $m * $mag } }
}

function New-SvgChart {
    param([string]$Title, [string[]]$Labels, [object[]]$Series, [double]$MaxY, [double]$RefY, [string]$RefLabel, [int[]]$MarkerIdx, [string]$Unit)
    $w = 960; $h = 250; $l = 64; $r = 16; $t = 34; $b = 28
    $pw = $w - $l - $r; $ph = $h - $t - $b
    $n = $Labels.Count
    $MaxY = Get-NiceMax $MaxY
    $x = { param($i) if ($n -le 1) { $l } else { $l + $pw * $i / ($n - 1) } }
    $y = { param($v) $t + $ph - $ph * [math]::Min([double]$v, $MaxY) / $MaxY }

    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append("<figure><figcaption>$(HtmlEncode $Title)</figcaption><svg viewBox='0 0 $w $h' role='img' aria-label='$(HtmlEncode $Title)'>")
    foreach ($frac in 0, 0.25, 0.5, 0.75, 1) {
        $yy = N (& $y ($MaxY * $frac))
        [void]$sb.Append("<line class='grid' x1='$l' x2='$($w - $r)' y1='$yy' y2='$yy'/><text class='axis' x='$($l - 8)' y='$yy' dy='4' text-anchor='end'>$(N ($MaxY * $frac) '0.#')</text>")
    }
    [void]$sb.Append("<text class='axis' x='$l' y='$($t - 20)'>$(HtmlEncode $Unit)</text>")
    foreach ($i in @(0, [math]::Floor(($n - 1) / 2), ($n - 1)) | Select-Object -Unique) {
        if ($i -lt 0) { continue }
        $anchor = if ($i -eq 0) { 'start' } elseif ($i -eq $n - 1) { 'end' } else { 'middle' }
        [void]$sb.Append("<text class='axis' x='$(N (& $x $i))' y='$($h - 8)' text-anchor='$anchor'>$(HtmlEncode $Labels[$i])</text>")
    }
    foreach ($m in $MarkerIdx) {
        $mx = N (& $x ([math]::Min($m, $n - 1)))
        [void]$sb.Append("<line class='marker' x1='$mx' x2='$mx' y1='$t' y2='$($t + $ph)'/>")
    }
    if ($RefY -gt 0) {
        $ry = N (& $y $RefY)
        [void]$sb.Append("<line class='ref' x1='$l' x2='$($w - $r)' y1='$ry' y2='$ry'/><text class='axis' x='$($w - $r)' y='$ry' dy='-5' text-anchor='end'>$(HtmlEncode $RefLabel)</text>")
    }
    $lx = $l + 60
    foreach ($s in $Series) {
        $pts = for ($i = 0; $i -lt $n; $i++) { '{0},{1}' -f (N (& $x $i) '0.#'), (N (& $y $s.Values[$i]) '0.#') }
        [void]$sb.Append("<polyline class='$($s.Class)' points='$($pts -join ' ')'/>")
        [void]$sb.Append("<rect class='key $($s.Class)' x='$lx' y='$($t - 30)' width='12' height='4' rx='2'/><text class='axis' x='$($lx + 18)' y='$($t - 24)'>$(HtmlEncode $s.Name)</text>")
        $lx += 30 + 7 * $s.Name.Length
    }
    [void]$sb.Append('</svg></figure>')
    return $sb.ToString()
}

function Write-HtmlReport([string]$File, $Findings, $Sessions, $Events) {
    $sevClass = @{ HIGH = 'high'; WARN = 'warn'; INFO = 'info' }
    $items = ($Findings | ForEach-Object { "<li class='$($sevClass[$_.Severity])'><b>$($_.Severity)</b> $(HtmlEncode $_.Text)</li>" }) -join "`n"

    $sessionHtml = foreach ($s in ($Sessions | Select-Object -First 4)) {
        $rows = $s.Rows
        $labels = @($rows | ForEach-Object { $_.Time.Substring(11, 5) })
        $markerIdx = @($s.Markers | Where-Object { $_.Text -notlike 'Session*' } | ForEach-Object { [int]$_.Sample })
        $col = { param($name) , @($rows | ForEach-Object { [double](ConvertTo-Number $_.$name) }) }
        $vramMax = [math]::Max($s.VramTotalMB, [math]::Max($s.PeakVramMB, $s.PeakSharedMB)) * 1.08
        $markerRows = ($s.Markers | ForEach-Object { "<tr><td>$(HtmlEncode $_.Time)</td><td>$(HtmlEncode $_.Text)</td></tr>" }) -join ''
        @"
<section>
<h2>Monitor session $(HtmlEncode $s.Start) &rarr; $(HtmlEncode $s.End.Substring(11))</h2>
<p class='meta'>$($s.Samples) samples &middot; peak VRAM $(N $s.PeakVramMB '0') / $(N $s.VramTotalMB '0') MB &middot; peak commit $(N $s.PeakCommitGB '0.#') / $(N $s.CommitLimitGB '0.#') GB &middot; lowest free RAM $(N $s.MinAvailGB '0.#') GB &middot; biggest RAM user $(HtmlEncode $s.TopRam) &middot; biggest VRAM user $(HtmlEncode $s.TopVram)</p>
$(New-SvgChart -Title 'Graphics card memory (VRAM)' -Labels $labels -Series @(@{ Name = 'Dedicated VRAM used'; Class = 's1'; Values = (& $col 'VramUsedMB') }, @{ Name = 'Spilled to system RAM'; Class = 's2'; Values = (& $col 'VramSharedMB') }) -MaxY $vramMax -RefY $s.VramTotalMB -RefLabel 'card limit' -MarkerIdx $markerIdx -Unit 'MB')
$(New-SvgChart -Title 'System commit (RAM + page file)' -Labels $labels -Series @(@{ Name = 'Committed'; Class = 's1'; Values = (& $col 'CommitGB') }) -MaxY ($s.CommitLimitGB * 1.08) -RefY $s.CommitLimitGB -RefLabel 'commit limit' -MarkerIdx $markerIdx -Unit 'GB')
$(New-SvgChart -Title 'Free physical RAM' -Labels $labels -Series @(@{ Name = 'Available'; Class = 's1'; Values = (& $col 'AvailRamGB') }) -MaxY ($(($rows | ForEach-Object { ConvertTo-Number $_.AvailRamGB } | Measure-Object -Maximum).Maximum) * 1.1) -MarkerIdx $markerIdx -Unit 'GB')
<details><summary>Events during this session (dashed lines on the charts)</summary><table><tr><th>Time</th><th>Event</th></tr>$markerRows</table></details>
</section>
"@
    }
    if (-not $sessionHtml) { $sessionHtml = "<section><p class='meta'>No monitor session in this report. Run option 1 before playing to record usage up to the crash.</p></section>" }

    $eventRows = ($Events | Where-Object { $_.Tag -ne 'ErrorReport' } | Select-Object -First 40 | ForEach-Object {
            $msg = ([string]$_.Message -split "`r?`n" | Where-Object { $_.Trim() } | Select-Object -First 2) -join ' '
            "<tr><td>$($_.Time.ToString('yyyy-MM-dd HH:mm'))</td><td>$($_.Tag)</td><td>$(HtmlEncode $msg)</td></tr>"
        }) -join "`n"

    $html = @"
<!doctype html>
<html lang='en'><head><meta charset='utf-8'><meta name='viewport' content='width=device-width, initial-scale=1'>
<title>GameMemDiag Report</title>
<style>
:root { --bg:#f7f7f5; --panel:#ffffff; --text:#1d1d1b; --muted:#6b6b66; --line:#e2e2dc; --c1:#2f6fd6; --c2:#d9822b; --ref:#c23b3b; --high:#c23b3b; --warn:#b7791f; --info:#6b6b66; }
@media (prefers-color-scheme: dark) { :root { --bg:#161615; --panel:#1f1f1d; --text:#ececea; --muted:#a3a39d; --line:#34342f; --c1:#6ea2ff; --c2:#f0a24f; --ref:#ff7070; --high:#ff7070; --warn:#e8b04b; --info:#a3a39d; } }
body { margin:0; background:var(--bg); color:var(--text); font:15px/1.5 system-ui, 'Segoe UI', sans-serif; }
main { max-width:1000px; margin:0 auto; padding:24px 16px 48px; }
h1 { font-size:22px; margin:0 0 4px; } h2 { font-size:17px; margin:0 0 6px; }
.meta { color:var(--muted); font-size:13px; margin:0 0 12px; }
section { background:var(--panel); border:1px solid var(--line); border-radius:10px; padding:16px; margin:16px 0; }
ul.findings { list-style:none; padding:0; margin:0; } ul.findings li { padding:6px 0; border-bottom:1px solid var(--line); }
ul.findings li:last-child { border-bottom:0; } li b { display:inline-block; min-width:48px; font-size:12px; }
li.high b { color:var(--high); } li.warn b { color:var(--warn); } li.info b { color:var(--info); }
figure { margin:12px 0 0; } figcaption { font-size:13px; font-weight:600; }
svg { width:100%; height:auto; display:block; }
.grid { stroke:var(--line); } .axis { fill:var(--muted); font-size:11px; }
polyline { fill:none; stroke-width:1.6; stroke-linejoin:round; } polyline.s1 { stroke:var(--c1); } polyline.s2 { stroke:var(--c2); }
rect.s1 { fill:var(--c1); } rect.s2 { fill:var(--c2); }
.ref { stroke:var(--ref); stroke-dasharray:6 4; } .marker { stroke:var(--muted); stroke-dasharray:2 3; }
table { width:100%; border-collapse:collapse; font-size:13px; } td, th { text-align:left; padding:4px 6px; border-bottom:1px solid var(--line); vertical-align:top; }
details { margin-top:10px; } summary { cursor:pointer; color:var(--muted); font-size:13px; }
</style></head><body><main>
<h1>GameMemDiag report &mdash; $(HtmlEncode $env:COMPUTERNAME)</h1>
<p class='meta'>Created $(Get-Date -Format 'yyyy-MM-dd HH:mm') &middot; looks back $Days days &middot; full details in summary.txt, system.txt, events.txt, game-logs\ and sessions\</p>
<section><h2>Findings</h2><ul class='findings'>
$items
</ul></section>
$($sessionHtml -join "`n")
<section><h2>Recent Windows events</h2><table><tr><th>Time</th><th>Type</th><th>Message</th></tr>
$eventRows
</table></section>
</main></body></html>
"@
    $html | Out-File -FilePath $File -Encoding UTF8
}

function Write-Summary([string]$File, $Findings, $Sessions, $Events, $LogResult) {
    $o = New-Object System.Collections.Generic.List[string]
    $o.Add("GameMemDiag $ToolVersion - $env:COMPUTERNAME - $(Get-Date -Format 'yyyy-MM-dd HH:mm')")
    $o.Add("Looked back $Days days. Open report.html for charts.")
    $o.Add('')
    $o.Add('FINDINGS')
    foreach ($f in $Findings) { $o.Add(('  [{0,-4}] {1}' -f $f.Severity, $f.Text)) }
    $o.Add('')
    $o.Add('MONITOR SESSIONS')
    if (-not $Sessions.Count) { $o.Add('  (none)') }
    foreach ($s in $Sessions) {
        $o.Add(("  {0} -> {1}  ({2} samples)" -f $s.Start, $s.End, $s.Samples))
        $o.Add(("    VRAM peak {0}/{1} MB ({2}%), shared peak {3} MB | commit peak {4}/{5} GB ({6}%) | min free RAM {7} GB" -f `
                    (N $s.PeakVramMB '0'), (N $s.VramTotalMB '0'), (N $s.PeakVramPct '0'), (N $s.PeakSharedMB '0'), (N $s.PeakCommitGB '0.#'), (N $s.CommitLimitGB '0.#'), (N $s.PeakCommitPct '0'), (N $s.MinAvailGB '0.#')))
        $o.Add(("    biggest RAM user {0} | biggest VRAM user {1}" -f $s.TopRam, $s.TopVram))
        foreach ($m in $s.Markers) { $o.Add(("      {0}  {1}" -f $m.Time, $m.Text)) }
    }
    $o.Add('')
    $o.Add('GAME LOG LINES OF INTEREST')
    if (-not @($LogResult.Hits).Count) { $o.Add('  (none)') }
    foreach ($h in ($LogResult.Hits | Select-Object -First 80)) { $o.Add(("  {0}:{1}  {2}" -f $h.File, $h.Line, $h.Text)) }
    $o.Add('')
    $o.Add('EVENT COUNTS (details in events.txt)')
    foreach ($g in ($Events | Group-Object Tag | Sort-Object Count -Descending)) { $o.Add(('  {0,-20} {1}' -f $g.Name, $g.Count)) }
    $o | Out-File -FilePath $File -Encoding UTF8
}

function New-Report {
    $since = (Get-Date).AddDays(-$Days)
    $name = 'GameMemDiag_{0}_{1}' -f $env:COMPUTERNAME, (Get-Date -Format 'yyyyMMdd-HHmm')
    $dir = Join-Path $ReportsDir $name
    Remove-Item -LiteralPath $dir -Recurse -Force
    New-Item -ItemType Directory -Path $dir -Force | Out-Null

    Write-Host '  Building report...' -ForegroundColor Green
    Write-Step 'System information'
    $info = Get-SystemInfo
    Write-SystemInfo $info (Join-Path $dir 'system.txt')

    Write-Step 'Windows event logs'
    $events = Get-DiagEvents $since
    Write-Events $events (Join-Path $dir 'events.txt')

    Write-Step 'Game logs and crash folders'
    $logResult = Copy-GameLogs $since (Join-Path $dir 'game-logs')

    Write-Step 'Windows error reports'
    Copy-WerReports $since (Join-Path $dir 'wer')

    Write-Step 'Monitor sessions'
    $sessions = @()
    $sessionDirs = @(Get-ChildItem -Path $SessionsDir -Directory | Where-Object { $_.LastWriteTime -ge $since } | Sort-Object Name -Descending)
    if ($sessionDirs.Count) {
        $dest = Join-Path $dir 'sessions'
        New-Item -ItemType Directory -Path $dest -Force | Out-Null
        foreach ($sd in $sessionDirs) {
            Copy-Item -LiteralPath $sd.FullName -Destination $dest -Recurse -Force
            $st = Get-SessionStats $sd.FullName
            if ($st) { $sessions += $st }
        }
    }

    if (-not $SkipDxDiag) {
        Write-Step 'DxDiag (can take up to a minute)'
        Invoke-DxDiag (Join-Path $dir 'dxdiag.txt')
    }

    Write-Step 'Analysing'
    $findings = Get-Findings $info $events $logResult $sessions
    Write-Summary (Join-Path $dir 'summary.txt') $findings $sessions $events $logResult
    Write-HtmlReport (Join-Path $dir 'report.html') $findings $sessions $events

    if (-not (Test-Path $OutDir)) { $script:OutDir = $Root }
    $zip = Join-Path $OutDir ($name + '.zip')
    Remove-Item -LiteralPath $zip -Force
    # Built entry by entry: under PS 5.1 both Compress-Archive and ZipFile write backslash paths, which other unzippers mangle.
    try {
        Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
        $archive = [System.IO.Compression.ZipFile]::Open($zip, [System.IO.Compression.ZipArchiveMode]::Create)
        try {
            foreach ($f in (Get-ChildItem -LiteralPath $dir -Recurse -File)) {
                $entry = $f.FullName.Substring($dir.Length + 1).Replace('\', '/')
                [void][System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile($archive, $f.FullName, $entry, [System.IO.Compression.CompressionLevel]::Optimal)
            }
        } finally { $archive.Dispose() }
    } catch {
        Remove-Item -LiteralPath $zip -Force
        Compress-Archive -Path (Join-Path $dir '*') -DestinationPath $zip
    }

    Write-Host ''
    if (Test-Path $zip) {
        Write-Host '  DONE. Send this file:' -ForegroundColor Green
        Write-Host "  $zip" -ForegroundColor White
        Write-Host ("  ({0} MB)" -f (N ((Get-Item $zip).Length / 1MB) '0.#')) -ForegroundColor DarkGray
        if (-not $NoOpen) { Start-Process explorer.exe -ArgumentList "/select,`"$zip`"" }
    } else {
        Write-Host "  Could not create the zip. Send the folder instead: $dir" -ForegroundColor Yellow
        if (-not $NoOpen) { Start-Process explorer.exe -ArgumentList "`"$dir`"" }
    }
    Write-Host ''
    Write-Host '  Quick look:' -ForegroundColor Green
    foreach ($f in ($findings | Select-Object -First 8)) {
        $c = switch ($f.Severity) { 'HIGH' { 'Red' } 'WARN' { 'Yellow' } default { 'Gray' } }
        Write-Host ("   [{0}] {1}" -f $f.Severity, $f.Text) -ForegroundColor $c
    }
    return $zip
}

# ---------------------------------------------------------------- main

New-Item -ItemType Directory -Path $SessionsDir, $ReportsDir -Force | Out-Null
Write-Host ''
Write-Host "  GameMemDiag $ToolVersion" -ForegroundColor White
if ($Mode -eq 'Monitor') { Start-Monitor }
[void](New-Report)
