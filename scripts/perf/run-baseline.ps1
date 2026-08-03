# Scenario 1: baseline - fast sink, N inserts, full payload.
# ASCII-only (Windows PowerShell 5.1).

param(
    [int]$Rows = 1000,
    [int]$BatchSize = 50,
    [int]$ListenPort = 18081,
    [ValidateSet("json", "avro")]
    [string]$Format = "json",
    [string]$MysqlDefaults = "D:\Work\ITART Repos\axialdb\my.cnf"
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "_common.ps1")

$repo = Get-RepoRoot
$env:CARGO_TARGET_DIR = Join-Path $repo "target"
$env:RUST_LOG = "info"
$outDir = Ensure-PerfOut
$sinkUrl = "http://127.0.0.1:$ListenPort/events"
$baseUrl = "http://127.0.0.1:$ListenPort"
$toml = Join-Path $outDir "baseline.toml"
$summaryPath = Join-Path $outDir ("baseline-{0}.json" -f (Get-Date -Format "yyyyMMdd-HHmmss"))

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
Write-PerfToml -Path $toml -SinkUrl $sinkUrl -PayloadMode "full" -ServerId 19201 -Format $Format

$sinkLog = Join-Path $outDir "baseline-sink.log"
$cliLog = Join-Path $outDir "baseline-cli.log"
$sinkErr = Join-Path $outDir "baseline-sink.err"
$cliErr = Join-Path $outDir "baseline-cli.err"

$sinkProc = $null
$cliProc = $null
try {
    Write-Host "Starting mock sink (delay_ms=0) ..."
    $sinkProc = Start-Process -FilePath $sinkExe `
        -ArgumentList ("--listen 127.0.0.1:{0} --delay-ms 0" -f $ListenPort) `
        -PassThru -NoNewWindow `
        -RedirectStandardOutput $sinkLog `
        -RedirectStandardError $sinkErr

    Start-Sleep -Seconds 1
    Reset-SinkStats -BaseUrl $baseUrl

    # Fresh checkpoint for this run
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
    $load = & (Join-Path $PSScriptRoot "loadgen.ps1") -Rows $Rows -BatchSize $BatchSize -MysqlDefaults $MysqlDefaults -Prefix "base"
    $stats = Wait-SinkCount -BaseUrl $baseUrl -Expected $Rows -TimeoutSec 180
    $sw.Stop()

    $eventsPerSec = 0.0
    if ($sw.Elapsed.TotalSeconds -gt 0) {
        $eventsPerSec = [math]::Round($Rows / $sw.Elapsed.TotalSeconds, 2)
    }

    $summary = [ordered]@{
        scenario = "baseline"
        format = $Format
        rows = $Rows
        received = [int]$stats.received
        bytes = [int64]$stats.bytes
        delay_ms = 0
        payload_mode = "full"
        wall_ms = $sw.ElapsedMilliseconds
        loadgen_ms = $load.elapsed_ms
        events_per_sec = $eventsPerSec
        match = ([int]$stats.received -ge $Rows)
        notes = "Fast sink baseline on lab MySQL 9.x. Compare to Debezium on same N when available."
    }

    $json = $summary | ConvertTo-Json -Depth 5
    $utf8NoBom = New-Object System.Text.UTF8Encoding $false
    [System.IO.File]::WriteAllText($summaryPath, $json, $utf8NoBom)
    Write-Host $json
    Write-Host ("Wrote {0}" -f $summaryPath)

    if (-not $summary.match) {
        throw "baseline mismatch: received < rows"
    }
    Write-Host "baseline PASS"
}
finally {
    if ($cliProc -and -not $cliProc.HasExited) { Stop-Process -Id $cliProc.Id -Force -ErrorAction SilentlyContinue }
    if ($sinkProc -and -not $sinkProc.HasExited) { Stop-Process -Id $sinkProc.Id -Force -ErrorAction SilentlyContinue }
}
