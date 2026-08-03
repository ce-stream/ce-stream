# Loadgen: insert N rows into ce_stream_spike.t1 (batch inserts).
# ASCII-only (Windows PowerShell 5.1).

param(
    [int]$Rows = 1000,
    [int]$BatchSize = 50,
    [string]$MysqlDefaults = "D:\Work\ITART Repos\axialdb\my.cnf",
    [string]$Table = "ce_stream_spike.t1",
    [string]$Prefix = "perf"
)

$ErrorActionPreference = "Stop"
if ($BatchSize -lt 1) { throw "BatchSize must be >= 1" }
if ($Rows -lt 1) { throw "Rows must be >= 1" }

$utf8NoBom = New-Object System.Text.UTF8Encoding $false
$tmp = Join-Path $env:TEMP ("ce-stream-perf-loadgen-{0}.sql" -f [guid]::NewGuid().ToString("N"))

try {
    $sb = New-Object System.Text.StringBuilder
    $done = 0
    $batch = 0
    while ($done -lt $Rows) {
        $n = [Math]::Min($BatchSize, $Rows - $done)
        [void]$sb.Append("INSERT INTO $Table(name) VALUES ")
        for ($i = 0; $i -lt $n; $i++) {
            if ($i -gt 0) { [void]$sb.Append(",") }
            $val = "{0}-{1}" -f $Prefix, ($done + $i + 1)
            # Single-quoted SQL string; escape single quotes by doubling.
            $valSql = $val.Replace("'", "''")
            [void]$sb.Append("('")
            [void]$sb.Append($valSql)
            [void]$sb.Append("')")
        }
        [void]$sb.AppendLine(";")
        $done += $n
        $batch++
    }

    [System.IO.File]::WriteAllText($tmp, $sb.ToString(), $utf8NoBom)
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    Get-Content -LiteralPath $tmp -Raw | & mysql --defaults-extra-file=$MysqlDefaults
    if ($LASTEXITCODE -ne 0) { throw "mysql loadgen failed" }
    $sw.Stop()

    Write-Host ("loadgen done rows={0} batches={1} elapsed_ms={2}" -f $Rows, $batch, $sw.ElapsedMilliseconds)
    [pscustomobject]@{
        rows = $Rows
        batches = $batch
        elapsed_ms = $sw.ElapsedMilliseconds
    }
}
finally {
    if (Test-Path $tmp) { Remove-Item -Force $tmp }
}
