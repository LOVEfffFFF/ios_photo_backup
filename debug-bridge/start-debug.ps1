param([int]$Port = 18081)
$ErrorActionPreference = 'Stop'
if ($Port -lt 1024 -or $Port -gt 65535) {throw 'Invalid port'}
$taskNode = (Get-Command node -ErrorAction Stop).Source
$taskData = Join-Path $PSScriptRoot ('data\live-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + [guid]::NewGuid().ToString('N').Substring(0, 6))
New-Item -ItemType Directory -Path $taskData -Force | Out-Null
$taskServer = Join-Path $PSScriptRoot 'server.cjs'
$taskProcess = Start-Process -FilePath $taskNode -ArgumentList @(('"' + $taskServer + '"'), $Port, ('"' + $taskData + '"')) -WindowStyle Hidden -PassThru -RedirectStandardOutput (Join-Path $taskData 'bridge.log') -RedirectStandardError (Join-Path $taskData 'bridge-error.log')
$taskConnection = Join-Path $taskData 'connection.json'
for ($taskTry = 0; $taskTry -lt 25; $taskTry++) {
    if (Test-Path -LiteralPath $taskConnection) {break}
    Start-Sleep -Milliseconds 200
}
if (!(Test-Path -LiteralPath $taskConnection)) {throw ('Debug bridge did not start. See ' + (Join-Path $taskData 'bridge-error.log'))}
$taskInfo = Get-Content -LiteralPath $taskConnection -Raw | ConvertFrom-Json
$taskLatest = @{connectionFile=$taskConnection;pid=$taskProcess.Id} | ConvertTo-Json
[IO.File]::WriteAllText((Join-Path $PSScriptRoot 'data\latest.json'), $taskLatest, [Text.UTF8Encoding]::new($false))
$taskAddresses = @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object {$_.IPAddress -notlike '127.*' -and $_.IPAddress -notlike '169.254.*'} | Select-Object -ExpandProperty IPAddress)
Write-Output 'Debug bridge started (separate from the backup receiver).'
foreach ($taskAddress in $taskAddresses) {Write-Output ('Phone address: http://' + $taskAddress + ':' + $Port)}
Write-Output ('Connection code: ' + $taskInfo.pairToken)
Write-Output ('Connection file: ' + $taskConnection)
Write-Output ('Expires: ' + [DateTimeOffset]::FromUnixTimeMilliseconds($taskInfo.expiresAt).ToLocalTime())
