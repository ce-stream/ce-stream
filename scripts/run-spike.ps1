# Phase 1 spike runner (local lab). Do not commit secrets.
# Requires: MySQL 9.x on 3306 with scripts/spike-setup.sql applied.
# Set CE_STREAM_PASSWORD (and optional MYSQL_DEFAULTS_FILE for the tip below).
# After vendor patch: StartPosition::Latest works (SHOW BINARY LOG STATUS).

$ErrorActionPreference = "Stop"
$repo = Split-Path -Parent $PSScriptRoot
$env:CARGO_TARGET_DIR = Join-Path $repo "target"

$pw = $env:CE_STREAM_PASSWORD
if ([string]::IsNullOrWhiteSpace($pw)) {
    throw "Set CE_STREAM_PASSWORD to the ce_stream MySQL user password before running."
}
$pwEnc = [uri]::EscapeDataString($pw)
$env:CE_STREAM_DB_URL = "mysql://ce_stream:${pwEnc}@127.0.0.1:3306?ssl-mode=required"
$env:CE_STREAM_SERVER_ID = "19001"
$env:CE_STREAM_INCLUDE = "ce_stream_spike.t1"
$env:CE_STREAM_MAX_EVENTS = "3"
# Empty GTID = Latest (uses patched SHOW BINARY LOG STATUS)
Remove-Item Env:CE_STREAM_GTID -ErrorAction SilentlyContinue
$env:RUST_LOG = "info"

Write-Host "Building ce-stream-spike..."
cargo build -p ce-stream-spike --release
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

$mysqlTip = "mysql -e `"INSERT INTO ce_stream_spike.t1(name) VALUES ('a'),('b'),('c');`""
if (-not [string]::IsNullOrWhiteSpace($env:MYSQL_DEFAULTS_FILE)) {
    $mysqlTip = "mysql --defaults-extra-file=`"$($env:MYSQL_DEFAULTS_FILE)`" -e `"INSERT INTO ce_stream_spike.t1(name) VALUES ('a'),('b'),('c');`""
}

Write-Host @"

In another shell, generate DML while the spike waits, e.g.:

  $mysqlTip

Starting spike (TLS required, Latest)...
"@

cargo run -p ce-stream-spike --release -- --timeout-secs 120
