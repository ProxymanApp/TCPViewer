# Sample per-process CPU cycles for electron.exe while a bench runs, writing CSV for scripts/print-results.js.
# GetProcessTimes (and so Electron's getAppMetrics) charges CPU in 15.6 ms ticks, which misses short timer- or
# vsync-driven work almost entirely; QueryProcessCycleTime counts cycles precisely instead.
param(
    [string]$Out = 'results\cpu-samples.csv',
    [int]$IntervalMs = 500,
    [int]$MaxSeconds = 600
)

$ErrorActionPreference = 'Stop'

Add-Type -TypeDefinition @'
using System;
using System.Diagnostics;
using System.Runtime.InteropServices;

public static class SpikeCycles {
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern IntPtr OpenProcess(uint access, bool inherit, int pid);
    [DllImport("kernel32.dll")]
    static extern bool CloseHandle(IntPtr handle);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool QueryProcessCycleTime(IntPtr handle, out ulong cycles);
    [DllImport("kernel32.dll")]
    static extern bool QueryThreadCycleTime(IntPtr handle, out ulong cycles);
    [DllImport("kernel32.dll")]
    static extern IntPtr GetCurrentThread();

    // Total cycles a process has used, or 0 when it cannot be opened.
    public static ulong ForProcess(int pid) {
        IntPtr handle = OpenProcess(0x1000, false, pid); // PROCESS_QUERY_LIMITED_INFORMATION
        if (handle == IntPtr.Zero) return 0;
        ulong cycles;
        bool ok = QueryProcessCycleTime(handle, out cycles);
        CloseHandle(handle);
        return ok ? cycles : 0;
    }

    // Spin this thread for the given time and return cycles per second for one fully busy core.
    public static double CyclesPerCoreSecond(int milliseconds) {
        IntPtr thread = GetCurrentThread();
        ulong before, after;
        QueryThreadCycleTime(thread, out before);
        Stopwatch watch = Stopwatch.StartNew();
        while (watch.ElapsedMilliseconds < milliseconds) { }
        QueryThreadCycleTime(thread, out after);
        return (after - before) / watch.Elapsed.TotalSeconds;
    }
}
'@

# Map an Electron command line to the same process kinds getAppMetrics reports.
function Get-ProcessKind([string]$commandLine) {
    if ($commandLine -notmatch '--type=') { return 'Browser' }
    if ($commandLine -match '--type=renderer') { return 'Tab' }
    if ($commandLine -match '--type=gpu-process') { return 'GPU' }
    if ($commandLine -match 'node\.mojom\.NodeService') { return 'Utility:TCPViewer Engine' }
    if ($commandLine -match 'network\.mojom\.NetworkService') { return 'Utility:Network Service' }
    return 'Other'
}

$calibration = [SpikeCycles]::CyclesPerCoreSecond(1000)
New-Item -ItemType Directory -Force -Path (Split-Path $Out) | Out-Null
$writer = [System.IO.StreamWriter]::new($Out, $false)
$writer.WriteLine("calibration,$calibration")
$writer.WriteLine('at,pid,kind,cycles')

$kinds = @{}
$deadline = (Get-Date).AddSeconds($MaxSeconds)
$seenElectron = $false
try {
    while ((Get-Date) -lt $deadline) {
        $processes = @(Get-Process -Name electron -ErrorAction SilentlyContinue)
        if ($processes.Count -eq 0) {
            if ($seenElectron) { break }
            Start-Sleep -Milliseconds 200
            continue
        }
        $seenElectron = $true
        $at = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
        foreach ($process in $processes) {
            if (-not $kinds.ContainsKey($process.Id)) {
                $commandLine = (Get-CimInstance Win32_Process -Filter "ProcessId=$($process.Id)").CommandLine
                $kinds[$process.Id] = Get-ProcessKind $commandLine
            }
            $writer.WriteLine("$at,$($process.Id),$($kinds[$process.Id]),$([SpikeCycles]::ForProcess($process.Id))")
        }
        $writer.Flush()
        Start-Sleep -Milliseconds $IntervalMs
    }
} finally {
    $writer.Dispose()
}
"calibration $([math]::Round($calibration / 1e6, 1)) M cycles per core-second; wrote $Out"
