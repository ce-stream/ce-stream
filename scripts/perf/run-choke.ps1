# Scenario 2: choke - slow sink; expect received == rows (no drops).
# ASCII-only (Windows PowerShell 5.1).

param(
    [int]$Rows = 500,
    [int]$BatchSize = 25,
    [int]$DelayMs = 10,
    [int]$ListenPort = 18082,
    [int]$QueueCapacity = 32,
    [ValidateSet("json", "avro")]
    [string]$Format = "json",
    [string]$MysqlDefaults = ""
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "_common.ps1")
$MysqlDefaults = Resolve-MysqlDefaults -MysqlDefaults $MysqlDefaults

$repo = Get-RepoRoot
$env:CARGO_TARGET_DIR = Join-Path $repo "target"
$env:RUST_LOG = "info"
$outDir = Ensure-PerfOut
$sinkUrl = "http://127.0.0.1:$ListenPort/events"
$baseUrl = "http://127.0.0.1:$ListenPort"
$toml = Join-Path $outDir "choke.toml"
$summaryPath = Join-Path $outDir ("choke-{0}.json" -f (Get-Date -Format "yyyyMMdd-HHmmss"))

Write-Host "Building perf sink + ce-stream ..."
Push-Location $repo
try {
    cargo build -p ce-stream-perf-sink -p ce-stream-cli --release
    if ($LASTEXITCODE -ne 0) { throw "cargo build failed" }
}
finally {
    Pop-Location
}

$sinkExe = Join-Path $env:CARGO_TARGET_DIR "release\ce-stream-perf-sink.exe"
$cliExe = Join-Path $env:CARGO_TARGET_DIR "release\ce-stream.exe"
Write-PerfToml -Path $toml -SinkUrl $sinkUrl -PayloadMode "full" -QueueCapacity $QueueCapacity -ServerId 19202 -Format $Format

$sinkLog = Join-Path $outDir "choke-sink.log"
$cliLog = Join-Path $outDir "choke-cli.log"
$sinkErr = Join-Path $outDir "choke-sink.err"
$cliErr = Join-Path $outDir "choke-cli.err"

$sinkProc = $null
$cliProc = $null
try {
    Write-Host ("Starting mock sink (delay_ms={0}) ..." -f $DelayMs)
    $sinkProc = Start-Process -FilePath $sinkExe `
        -ArgumentList ("--listen 127.0.0.1:{0} --delay-ms {1}" -f $ListenPort, $DelayMs) `
        -PassThru -NoNewWindow `
        -RedirectStandardOutput $sinkLog `
        -RedirectStandardError $sinkErr

    Start-Sleep -Seconds 1
    Reset-SinkStats -BaseUrl $baseUrl

    $cp = Join-Path $repo ".ce-stream\perf-checkpoint.json"
    if (Test-Path $cp) { Remove-Item -Force $cp }

    Write-Host "Starting ce-stream ..."
    $argLine = '--config "{0}"' -f $toml
    $cliProc = Start-Process -FilePath $cliExe `
        -ArgumentList $argLine `
        -PassThru -NoNewWindow `
        -RedirectStandardOutput $cliLog `
        -RedirectStandardError $cliErr `
        -WorkingDirectory $repo

    Start-Sleep -Seconds 3
    if ($cliProc.HasExited) {
        Get-Content $cliErr -ErrorAction SilentlyContinue
        throw "ce-stream exited early"
    }

    Write-Host "Loadgen rows=$Rows ..."
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $load = & (Join-Path $PSScriptRoot "loadgen.ps1") -Rows $Rows -BatchSize $BatchSize -MysqlDefaults $MysqlDefaults -Prefix "choke"
    # Allow sink delay: rough lower bound Rows*DelayMs plus catch-up margin
    $timeout = [Math]::Max(180, [int](($Rows * $DelayMs / 1000.0) + 120))
    $stats = Wait-SinkCount -BaseUrl $baseUrl -Expected $Rows -TimeoutSec $timeout
    $sw.Stop()

    $eventsPerSec = 0.0
    if ($sw.Elapsed.TotalSeconds -gt 0) {
        $eventsPerSec = [math]::Round($Rows / $sw.Elapsed.TotalSeconds, 2)
    }

    $summary = [ordered]@{
        scenario = "choke"
        format = $Format
        rows = $Rows
        received = [int]$stats.received
        bytes = [int64]$stats.bytes
        delay_ms = $DelayMs
        queue_capacity = $QueueCapacity
        payload_mode = "full"
        wall_ms = $sw.ElapsedMilliseconds
        loadgen_ms = $load.elapsed_ms
        events_per_sec = $eventsPerSec
        match = ([int]$stats.received -eq $Rows)
        notes = "Choke: backpressure must not drop. received==rows is the pass gate. Lag should rise under delay."
    }

    $json = $summary | ConvertTo-Json -Depth 5
    $utf8NoBom = New-Object System.Text.UTF8Encoding $false
    [System.IO.File]::WriteAllText($summaryPath, $json, $utf8NoBom)
    Write-Host $json
    Write-Host ("Wrote {0}" -f $summaryPath)

    if (-not $summary.match) {
        throw ("choke mismatch: received={0} rows={1}" -f $stats.received, $Rows)
    }
    Write-Host "choke PASS"
}
finally {
    if ($cliProc -and -not $cliProc.HasExited) { Stop-Process -Id $cliProc.Id -Force -ErrorAction SilentlyContinue }
    if ($sinkProc -and -not $sinkProc.HasExited) { Stop-Process -Id $sinkProc.Id -Force -ErrorAction SilentlyContinue }
}
