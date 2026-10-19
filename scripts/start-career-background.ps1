$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$privateDir = Join-Path $projectRoot 'data\career-private'
$node = (Get-Command node -ErrorAction Stop).Source
$listener = Get-NetTCPConnection -State Listen -LocalPort 4176 -ErrorAction SilentlyContinue
if ($listener) {
    $health = Invoke-RestMethod -Uri 'http://127.0.0.1:4176/health' -TimeoutSec 5
    if ($health.service -ne 'daylight-career') { throw 'Port 4176 is used by another service.' }
    Write-Output 'Career service is already running on 127.0.0.1:4176.'
    exit 0
}
New-Item -ItemType Directory -Path $privateDir -Force | Out-Null
$nodeArgs = @('--use-env-proxy')
if (Test-Path -LiteralPath (Join-Path $privateDir 'search.env')) { $nodeArgs += '--env-file=data/career-private/search.env' }
$nodeArgs += 'scripts/career-service-runtime.cjs'
$process = Start-Process -FilePath $node -ArgumentList $nodeArgs -WorkingDirectory $projectRoot -WindowStyle Hidden -PassThru -RedirectStandardOutput (Join-Path $privateDir 'service.stdout.log') -RedirectStandardError (Join-Path $privateDir 'service.stderr.log')
for ($attempt = 0; $attempt -lt 20; $attempt++) {
    Start-Sleep -Milliseconds 500
    $process.Refresh()
    if ($process.HasExited) { throw 'Career service stopped. See data/career-private/service.stderr.log.' }
    try {
        $health = Invoke-RestMethod -Uri 'http://127.0.0.1:4176/health' -TimeoutSec 2
        if ($health.service -eq 'daylight-career') { Write-Output "Career service ready. PID=$($process.Id), address=127.0.0.1:4176"; exit 0 }
    } catch {}
}
throw 'Career service did not become ready. Check the private service logs.'
