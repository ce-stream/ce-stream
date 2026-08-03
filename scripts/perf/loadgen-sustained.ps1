# Sustained loadgen: insert TargetOpsPerSec rows each second for DurationSec.
# ASCII-only (Windows PowerShell 5.1).

param(
    [int]$OpsPerSec = 300,
    [int]$DurationSec = 60,
    [int]$BatchSize = 50,
    [string]$MysqlDefaults = "D:\Work\ITART Repos\axialdb\my.cnf",
    [string]$Table = "ce_stream_spike.t1",
    [string]$Prefix = "sust"
)

$ErrorActionPreference = "Stop"
if ($OpsPerSec -lt 1) { throw "OpsPerSec must be >= 1" }
if ($DurationSec -lt 1) { throw "DurationSec must be >= 1" }
if ($BatchSize -lt 1) { throw "BatchSize must be >= 1" }

$utf8NoBom = New-Object System.Text.UTF8Encoding $false
$total = 0
$tick = 0
$swAll = [System.Diagnostics.Stopwatch]::StartNew()

while ($tick -lt $DurationSec) {
    $tickSw = [System.Diagnostics.Stopwatch]::StartNew()
    $remaining = $OpsPerSec
    $sb = New-Object System.Text.StringBuilder
    while ($remaining -gt 0) {
        $n = [Math]::Min($BatchSize, $remaining)
        [void]$sb.Append("INSERT INTO $Table(name) VALUES ")
        for ($i = 0; $i -lt $n; $i++) {
            if ($i -gt 0) { [void]$sb.Append(",") }
            $val = "{0}-{1}-{2}" -f $Prefix, ($tick + 1), ($total + $i + 1)
            $valSql = $val.Replace("'", "''")
            [void]$sb.Append("('")
            [void]$sb.Append($valSql)
            [void]$sb.Append("')")
        }
        [void]$sb.AppendLine(";")
        $remaining -= $n
        $total += $n
    }

    $tmp = Join-Path $env:TEMP ("ce-stream-perf-sust-{0}.sql" -f [guid]::NewGuid().ToString("N"))
    try {
        [System.IO.File]::WriteAllText($tmp, $sb.ToString(), $utf8NoBom)
        Get-Content -LiteralPath $tmp -Raw | & mysql --defaults-extra-file=$MysqlDefaults
        if ($LASTEXITCODE -ne 0) { throw ("mysql sustained loadgen failed at tick {0}" -f $tick) }
    }
    finally {
        if (Test-Path $tmp) { Remove-Item -Force $tmp }
    }

    $tickSw.Stop()
    $sleepMs = 1000 - [int]$tickSw.ElapsedMilliseconds
    if ($sleepMs -gt 0) {
        Start-Sleep -Milliseconds $sleepMs
    }
    else {
        Write-Host ("warn: tick {0} took {1}ms (>1s); falling behind target rate" -f $tick, $tickSw.ElapsedMilliseconds)
    }
    $tick++
    if (($tick % 10) -eq 0 -or $tick -eq $DurationSec) {
        Write-Host ("sustained progress tick={0}/{1} rows={2}" -f $tick, $DurationSec, $total)
    }
}

$swAll.Stop()
Write-Host ("sustained loadgen done rows={0} target_ops_per_sec={1} duration_sec={2} wall_ms={3}" -f $total, $OpsPerSec, $DurationSec, $swAll.ElapsedMilliseconds)
[pscustomobject]@{
    rows = $total
    ops_per_sec_target = $OpsPerSec
    duration_sec = $DurationSec
    elapsed_ms = $swAll.ElapsedMilliseconds
}
