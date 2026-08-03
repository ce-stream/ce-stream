# Phase 3 smoke: local HTTP listener + ce-stream (max 1 event).
# Set ce-stream.toml sink.kind=http and url=http://127.0.0.1:18080/events before running.
# ASCII-only (Windows PowerShell 5.1).

param(
    [string]$Config = "ce-stream.toml",
    [string]$MysqlDefaults = "",
    [string]$InsertSql = "INSERT INTO ce_stream_spike.t1(name) VALUES ('e2e-http');",
    [int]$Port = 18080
)

$ErrorActionPreference = "Stop"
$repo = Split-Path -Parent $PSScriptRoot
. (Join-Path $repo "scripts\perf\_common.ps1")
$MysqlDefaults = Resolve-MysqlDefaults -MysqlDefaults $MysqlDefaults
if (-not [System.IO.Path]::IsPathRooted($Config)) {
    $Config = Join-Path $repo $Config
}
$env:CARGO_TARGET_DIR = Join-Path $repo "target"
$env:RUST_LOG = "info"

$received = Join-Path $env:TEMP "ce-stream-e2e-http.json"
$outLog = Join-Path $env:TEMP "ce-stream-e2e-out.txt"
$errLog = Join-Path $env:TEMP "ce-stream-e2e-err.txt"
foreach ($f in @($received, $outLog, $errLog)) {
    if (Test-Path $f) { Remove-Item -Force $f }
}

Write-Host "Building ce-stream ..."
cargo build -p ce-stream-cli --release
if ($LASTEXITCODE -ne 0) { throw "cargo build failed" }

$exe = Join-Path $env:CARGO_TARGET_DIR "release\ce-stream.exe"
if (-not (Test-Path $exe)) { throw "missing $exe" }

Write-Host "Starting HttpListener on 127.0.0.1:$Port ..."
$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add("http://127.0.0.1:$Port/")
try {
    $listener.Start()
} catch {
    throw "Failed to bind port $Port (URL ACL or in use). $_"
}

$proc = $null
try {
    Write-Host "Starting ce-stream (max-events 1) ..."
    # Start-Process splits unquoted paths on spaces; pass one ArgumentList string.
    $argLine = '--config "{0}" --max-events 1' -f $Config
    $proc = Start-Process -FilePath $exe `
        -ArgumentList $argLine `
        -PassThru -NoNewWindow `
        -RedirectStandardOutput $outLog `
        -RedirectStandardError $errLog

    Start-Sleep -Seconds 3
    if ($proc.HasExited) {
        Write-Host "ce-stream exited early (code $($proc.ExitCode)). stderr:"
        if (Test-Path $errLog) { Get-Content $errLog }
        throw "ce-stream failed to stay running"
    }

    Write-Host "Arming HTTP wait, then inserting test row ..."
    $ar = $listener.BeginGetContext($null, $null)

    & mysql --defaults-extra-file=$MysqlDefaults -e $InsertSql
    if ($LASTEXITCODE -ne 0) { throw "mysql insert failed" }

    Write-Host "Waiting for HTTP POST (60s) ..."
    if (-not $ar.AsyncWaitHandle.WaitOne(60000)) {
        if (Test-Path $errLog) { Get-Content $errLog }
        throw "timeout waiting for HTTP CloudEvent"
    }
    $ctx = $listener.EndGetContext($ar)
    $reader = New-Object System.IO.StreamReader($ctx.Request.InputStream, [System.Text.Encoding]::UTF8)
    $body = $reader.ReadToEnd()
    $reader.Close()
    [System.IO.File]::WriteAllText($received, $body)

    $ok = [System.Text.Encoding]::UTF8.GetBytes('{"ok":true}')
    $ctx.Response.StatusCode = 200
    $ctx.Response.ContentType = "application/json"
    $ctx.Response.OutputStream.Write($ok, 0, $ok.Length)
    $ctx.Response.Close()

    Write-Host "Received:"
    Write-Host $body
    if ($body -notmatch "io.ce-stream.row") {
        throw "body does not look like a ce-stream CloudEvent"
    }
    Write-Host "E2E HTTP smoke PASS"
}
finally {
    if ($proc -and -not $proc.HasExited) {
        Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
    }
    try { $listener.Stop() } catch {}
    try { $listener.Close() } catch {}
}
