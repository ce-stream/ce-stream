# Scenario: sustained - fixed inserts/sec for DurationSec; assert sink keeps up.
# Narrative aligned with Debezium Server MySQL streaming posts: track source rate.
# ASCII-only (Windows PowerShell 5.1).

param(
    [int]$OpsPerSec = 300,
    [int]$DurationSec = 60,
    [int]$BatchSize = 50,
    [int]$ListenPort = 18083,
    [int]$CatchUpTimeoutSec = 120,
    [double]$KeepUpRatio = 0.85,
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
$toml = Join-Path $outDir "sustained.toml"
$summaryPath = Join-Path $outDir ("sustained-{0}.json" -f (Get-Date -Format "yyyyMMdd-HHmmss"))

$expected = $OpsPerSec * $DurationSec

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
Write-PerfToml -Path $toml -SinkUrl $sinkUrl -PayloadMode "full" -ServerId 19203 -Format $Format

$sinkLog = Join-Path $outDir "sustained-sink.log"
$cliLog = Join-Path $outDir "sustained-cli.log"
$sinkErr = Join-Path $outDir "sustained-sink.err"
$cliErr = Join-Path $outDir "sustained-cli.err"

$sinkProc = $null
$cliProc = $null
$samples = New-Object System.Collections.ArrayList

try {
    Write-Host "Starting mock sink (delay_ms=0) ..."
    $sinkProc = Start-Process -FilePath $sinkExe `
        -ArgumentList ("--listen 127.0.0.1:{0} --delay-ms 0" -f $ListenPort) `
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

    Write-Host ("Sustained loadgen ops_per_sec={0} duration_sec={1} expected_rows={2} ..." -f $OpsPerSec, $DurationSec, $expected)
    $sw = [System.Diagnostics.Stopwatch]::StartNew()

    # Sample sink in background while loadgen runs
    $sampleJob = Start-Job -ScriptBlock {
        param($BaseUrl, $DurationSec)
        $list = @()
        $t0 = Get-Date
        while (((Get-Date) - $t0).TotalSeconds -lt ($DurationSec + 2)) {
            try {
                $r = Invoke-WebRequest -Uri ($BaseUrl.TrimEnd("/") + "/stats") -UseBasicParsing -TimeoutSec 2
                $s = $r.Content | ConvertFrom-Json
                $list += [pscustomobject]@{
                    t_ms = [int]((Get-Date) - $t0).TotalMilliseconds
                    received = [int]$s.received
                }
            }
            catch { }
            Start-Sleep -Seconds 1
        }
        return $list
    } -ArgumentList $baseUrl, $DurationSec

    $load = & (Join-Path $PSScriptRoot "loadgen-sustained.ps1") `
        -OpsPerSec $OpsPerSec `
        -DurationSec $DurationSec `
        -BatchSize $BatchSize `
        -MysqlDefaults $MysqlDefaults `
        -Prefix "sust"

    $sampleOut = Receive-Job -Job $sampleJob -Wait
    Remove-Job -Job $sampleJob -Force -ErrorAction SilentlyContinue
    if ($sampleOut) {
        foreach ($row in @($sampleOut)) { [void]$samples.Add($row) }
    }

    Write-Host "Waiting for sink catch-up ..."
    $stats = Wait-SinkCount -BaseUrl $baseUrl -Expected $expected -TimeoutSec $CatchUpTimeoutSec
    $sw.Stop()

    $catchUpMs = $sw.ElapsedMilliseconds - [int]$load.elapsed_ms
    if ($catchUpMs -lt 0) { $catchUpMs = 0 }

    # Second-half sink rate from samples (if we have enough points)
    $halfRate = $null
    if ($samples.Count -ge 4) {
        $mid = [int]($samples.Count / 2)
        $a = $samples[$mid]
        $b = $samples[$samples.Count - 1]
        $dt = ($b.t_ms - $a.t_ms) / 1000.0
        if ($dt -gt 0) {
            $halfRate = [math]::Round(($b.received - $a.received) / $dt, 2)
        }
    }

    $overallEps = 0.0
    if ($sw.Elapsed.TotalSeconds -gt 0) {
        $overallEps = [math]::Round($expected / $sw.Elapsed.TotalSeconds, 2)
    }

    $keepUp = $false
    if ($null -ne $halfRate) {
        $keepUp = ($halfRate -ge ($OpsPerSec * $KeepUpRatio))
    }
    else {
        # Fallback: catch-up after loadgen shorter than DurationSec (did not dig a deep hole)
        $keepUp = ($catchUpMs -le ($DurationSec * 1000))
    }

    $match = ([int]$stats.received -ge $expected)

    $summary = [ordered]@{
        scenario = "sustained"
        format = $Format
        ops_per_sec_target = $OpsPerSec
        duration_sec = $DurationSec
        rows_expected = $expected
        received = [int]$stats.received
        bytes = [int64]$stats.bytes
        loadgen_ms = $load.elapsed_ms
        wall_ms = $sw.ElapsedMilliseconds
        catch_up_ms = $catchUpMs
        overall_events_per_sec = $overallEps
        second_half_sink_eps = $halfRate
        keep_up_ratio_gate = $KeepUpRatio
        keep_up = $keepUp
        match = $match
        notes = "Sustained rate test (Debezium-style: does CDC track source write rate?). Fast local HTTP sink."
    }

    $json = $summary | ConvertTo-Json -Depth 5
    $utf8NoBom = New-Object System.Text.UTF8Encoding $false
    [System.IO.File]::WriteAllText($summaryPath, $json, $utf8NoBom)
    Write-Host $json
    Write-Host ("Wrote {0}" -f $summaryPath)

    if (-not $match) {
        throw ("sustained mismatch: received={0} expected={1}" -f $stats.received, $expected)
    }
    if (-not $keepUp) {
        throw ("sustained did not keep up: second_half_sink_eps={0} target={1} ratio_gate={2}" -f $halfRate, $OpsPerSec, $KeepUpRatio)
    }
    Write-Host "sustained PASS"
}
finally {
    Get-Job -ErrorAction SilentlyContinue | Where-Object { $_.State -ne "Completed" } | Stop-Job -ErrorAction SilentlyContinue
    Get-Job -ErrorAction SilentlyContinue | Remove-Job -Force -ErrorAction SilentlyContinue
    if ($cliProc -and -not $cliProc.HasExited) { Stop-Process -Id $cliProc.Id -Force -ErrorAction SilentlyContinue }
    if ($sinkProc -and -not $sinkProc.HasExited) { Stop-Process -Id $sinkProc.Id -Force -ErrorAction SilentlyContinue }
}
