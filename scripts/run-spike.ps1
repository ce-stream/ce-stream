# Phase 1 spike runner (local lab). Do not commit secrets.
# Requires: MySQL 9.x on 3306 with scripts/spike-setup.sql applied.
# After vendor patch: StartPosition::Latest works (SHOW BINARY LOG STATUS).

$ErrorActionPreference = "Stop"
$env:CARGO_TARGET_DIR = "D:\Work\ITART Repos\ce-stream\target"

# URL-encode '!' in password as %21
$env:CE_STREAM_DB_URL = "mysql://ce_stream:CeStreamSpike9%21@127.0.0.1:3306?ssl-mode=required"
$env:CE_STREAM_SERVER_ID = "19001"
$env:CE_STREAM_INCLUDE = "ce_stream_spike.t1"
$env:CE_STREAM_MAX_EVENTS = "3"
# Empty GTID = Latest (uses patched SHOW BINARY LOG STATUS)
Remove-Item Env:CE_STREAM_GTID -ErrorAction SilentlyContinue
$env:RUST_LOG = "info"

Write-Host "Building ce-stream-spike..."
cargo build -p ce-stream-spike --release
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

Write-Host @"

In another shell, generate DML while the spike waits, e.g.:

  mysql --defaults-extra-file="D:\Work\ITART Repos\axialdb\my.cnf" -e "INSERT INTO ce_stream_spike.t1(name) VALUES ('a'),('b'),('c');"

Starting spike (TLS required, Latest)...
"@

cargo run -p ce-stream-spike --release -- --timeout-secs 120
