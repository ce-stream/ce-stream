# Shared helpers for perf runners. Dot-source from run-*.ps1.
# ASCII-only.

function Get-RepoRoot {
    Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
}

function Ensure-PerfOut {
    $outDir = Join-Path $PSScriptRoot "out"
    if (-not (Test-Path $outDir)) {
        New-Item -ItemType Directory -Path $outDir | Out-Null
    }
    return $outDir
}

function Write-PerfToml {
    param(
        [string]$Path,
        [string]$SinkUrl,
        [string]$PayloadMode = "full",
        [int]$QueueCapacity = 64,
        [int]$ServerId = 19201,
        [ValidateSet("json", "avro")]
        [string]$Format = "json"
    )
    $content = @"
[source]
adapter = "mysql"
source_id = "mysql://127.0.0.1:3306/ce-stream-perf"
host = "127.0.0.1"
port = 3306
user = "ce_stream"
password = "CeStreamSpike9!"
server_id = $ServerId
tls = true
payload_mode = "$PayloadMode"
queue_capacity = $QueueCapacity
include_tables = ["ce_stream_spike.t1"]

[checkpoint]
path = ".ce-stream/perf-checkpoint.json"

[sink]
kind = "http"
url = "$SinkUrl"
format = "$Format"
"@
    $utf8NoBom = New-Object System.Text.UTF8Encoding $false
    [System.IO.File]::WriteAllText($Path, $content, $utf8NoBom)
}

function Get-SinkStats {
    param([string]$BaseUrl)
    $r = Invoke-WebRequest -Uri ($BaseUrl.TrimEnd("/") + "/stats") -UseBasicParsing -TimeoutSec 5
    return $r.Content | ConvertFrom-Json
}

function Reset-SinkStats {
    param([string]$BaseUrl)
    Invoke-WebRequest -Uri ($BaseUrl.TrimEnd("/") + "/reset") -Method POST -UseBasicParsing -TimeoutSec 5 | Out-Null
}

function Wait-SinkCount {
    param(
        [string]$BaseUrl,
        [int]$Expected,
        [int]$TimeoutSec = 120
    )
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    $last = 0
    while ((Get-Date) -lt $deadline) {
        $s = Get-SinkStats -BaseUrl $BaseUrl
        $last = [int]$s.received
        if ($last -ge $Expected) {
            return $s
        }
        Start-Sleep -Milliseconds 200
    }
    throw ("timeout waiting for sink count>={0} (last={1})" -f $Expected, $last)
}
