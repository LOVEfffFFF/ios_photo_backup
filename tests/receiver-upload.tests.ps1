param([string]$TestRoot)
$ErrorActionPreference = 'Stop'
# The receiver script is not tracked in Git; it usually sits in
# <workspace>\windows-receiver\, i.e. one level above this repository.
$candidates = @(
    (Join-Path $PSScriptRoot '..\..\windows-receiver\PhotoBackupReceiver.ps1'),
    (Join-Path $PSScriptRoot '..\windows-receiver\PhotoBackupReceiver.ps1'),
    (Join-Path (Get-Location) 'windows-receiver\PhotoBackupReceiver.ps1')
)
$receiver = $candidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
if (-not $receiver) {
    throw "PhotoBackupReceiver.ps1 not found. Expected it in <workspace>\windows-receiver\."
}
$tokens = $null; $errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($receiver, [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw ($errors | Out-String) }
# Extract production functions without running the listener, ACL or firewall setup.
foreach ($definition in $ast.FindAll({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] }, $true)) {
    Invoke-Expression $definition.Extent.Text
}
if (-not $TestRoot) { $TestRoot = Join-Path ([IO.Path]::GetTempPath()) 'photo-backup-openai-tests' }
$script:SavePath = Join-Path $TestRoot ([Guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($script:SavePath)
$script:ManifestPath = Join-Path $script:SavePath 'manifest.jsonl'
$script:LogFile = $null
$script:Utf8NoBom = New-Object Text.UTF8Encoding($false)
$script:ManifestIndex = @{}
$script:statFiles = 0; $script:statBytes = 0L; $script:statSkipped = 0
$script:statManifest = 0; $script:statVerified = 0; $script:statMismatch = 0
$NoHash = $false
$script:failures = 0; $script:checks = 0
function Assert-True($Condition, [string]$Label) {
    $script:checks++
    if (-not $Condition) { $script:failures++; Write-Host "FAIL: $Label" } else { Write-Host "PASS: $Label" }
}
function Invoke-Upload([string]$Path, [string]$Content = 'AAAA', [string]$Hash = '', [long]$Length = -1, [string]$Role = 'main') {
    $bytes = [Text.Encoding]::UTF8.GetBytes($Content)
    if (-not $Hash) {
        $sha = [Security.Cryptography.SHA256]::Create()
        try { $Hash = ([BitConverter]::ToString($sha.ComputeHash($bytes)) -replace '-', '').ToLowerInvariant() } finally { $sha.Dispose() }
    }
    if ($Length -lt 0) { $Length = $bytes.Length }
    $inputStream = New-Object IO.MemoryStream
    $inputStream.Write($bytes, 0, $bytes.Length); $inputStream.Position = 0
    $outputStream = New-Object IO.MemoryStream
    $context = [pscustomobject]@{
        Request = [pscustomobject]@{
            Headers = @{'X-File-Path'=[Uri]::EscapeDataString($Path); 'X-Content-Sha256'=$Hash; 'X-Asset-Id'='synthetic'; 'X-Pair-Key'='synthetic'; 'X-Role'=$Role; 'X-Resource-Total'='1'}
            ContentLength64 = $Length; InputStream = $inputStream
        }
        Response = [pscustomobject]@{StatusCode=0; ContentType=''; ContentLength64=0L; OutputStream=$outputStream}
    }
    try {
        Receive-Upload $context
        return [pscustomobject]@{Code=$context.Response.StatusCode; Body=([Text.Encoding]::UTF8.GetString($outputStream.ToArray()) | ConvertFrom-Json)}
    } finally { $inputStream.Dispose(); $outputStream.Dispose() }
}
function Read-Rows { return @([IO.File]::ReadLines($script:ManifestPath) | ForEach-Object { try { $_ | ConvertFrom-Json } catch {} }) }

$r = Invoke-Upload '2026/10/sample.bin'
Assert-True ($r.Code -eq 200 -and $r.Body.status -eq 'ok' -and $r.Body.manifestCommitted -eq $true -and $r.Body.verifyState -eq 'verified' -and $r.Body.size -eq 4 -and $r.Body.path -eq '2026/10/sample.bin' -and $r.Body.sha256 -eq (Read-Rows)[0].sha256) 'new upload acknowledges verified content and manifest'
$r = Invoke-Upload '2026/10/sample.bin'
Assert-True ($r.Code -eq 200 -and $r.Body.skipped -eq $true -and @(Read-Rows).Count -eq 1) 'identical retry is idempotent'
Load-ManifestIndex
$r = Invoke-Upload '2026/10/sample.bin'
Assert-True ($r.Code -eq 200 -and @(Read-Rows).Count -eq 1) 'idempotency survives index reload'
$r = Invoke-Upload '2026/10/sample.bin' 'BBBB'
Assert-True ($r.Code -eq 409 -and [IO.File]::ReadAllText((Join-Path $script:SavePath '2026/10/sample.bin')) -eq 'AAAA') 'same-length different content never overwrites or skips'
$r = Invoke-Upload '2026/10/sample.bin' 'CCCCC'
Assert-True ($r.Code -eq 409) 'different-length collision is rejected'
Assert-True (@(Get-ChildItem -LiteralPath $script:SavePath -Recurse -File | Where-Object Name -like '*.conflict-*').Count -eq 2) 'both conflicts preserve incoming content separately'
$r = Invoke-Upload '2026/10/mismatch.bin' 'DDDD' ('0' * 64)
Assert-True ($r.Code -eq 422 -and -not [IO.File]::Exists((Join-Path $script:SavePath '2026/10/mismatch.bin'))) 'checksum mismatch is rejected before promotion'
$r = Invoke-Upload '2026/10/sample.bin' 'BBBB' (Read-Rows)[0].sha256
Assert-True ($r.Code -eq 422) 'existing file cannot conceal corrupt request body'
$r = Invoke-Upload '2026/10/short.bin' 'AAAA' '' 8
Assert-True ($r.Code -ne 200 -and -not [IO.File]::Exists((Join-Path $script:SavePath '2026/10/short.bin'))) 'truncated upload is not promoted'
$r = Invoke-Upload '2026/10/invalid.bin' 'AAAA' 'invalid-hash'
Assert-True ($r.Code -eq 400) 'malformed checksum is rejected'
$NoHash = $true
$r = Invoke-Upload '2026/10/nohash.bin' 'AAAA' ('0' * 64)
Assert-True ($r.Code -eq 422) 'NoHash cannot bypass supplied checksum'
$NoHash = $false
$validManifest = $script:ManifestPath
$script:ManifestPath = $script:SavePath
$r = Invoke-Upload '2026/10/repair.bin'
Assert-True ($r.Code -ne 200) 'manifest write failure cannot acknowledge success'
$script:ManifestPath = $validManifest
$r = Invoke-Upload '2026/10/repair.bin'
Assert-True ($r.Code -eq 200 -and @(Read-Rows | Where-Object serverPath -eq '2026/10/repair.bin').Count -eq 1) 'retry repairs missing manifest after file was saved'
$before = @(Read-Rows).Count
$r = Invoke-Upload '2026/10/repair.bin' 'AAAA' '' -1 'render'
Assert-True ($r.Code -eq 200 -and @(Read-Rows).Count -eq ($before + 1) -and (Read-Rows)[-1].role -eq 'render') 'same bytes with changed metadata refresh manifest'
[IO.File]::Delete((Join-Path $script:SavePath '2026/10/repair.bin'))
$r = Invoke-Upload '2026/10/repair.bin' 'AAAA' '' -1 'render'
Assert-True ($r.Code -eq 200 -and [IO.File]::Exists((Join-Path $script:SavePath '2026/10/repair.bin'))) 'deleted disk file is repaired despite cached manifest'
[IO.File]::Delete($script:ManifestPath)
$r = Invoke-Upload '2026/10/sample.bin'
Assert-True ($r.Code -eq 200 -and @(Read-Rows).Count -eq 1) 'deleted manifest is rebuilt despite cached index'
[IO.File]::AppendAllText($script:ManifestPath, '{"interrupted":', $script:Utf8NoBom)
$r = Invoke-Upload '2026/10/after-crash.bin'
Assert-True ($r.Code -eq 200 -and @(Read-Rows | Where-Object serverPath -eq '2026/10/after-crash.bin').Count -eq 1) 'partial trailing manifest line cannot swallow next committed row'
foreach ($path in @('../escape.bin', 'C:/escape.bin', '2026/10/test.bin:stream', 'manifest.jsonl')) {
    $r = Invoke-Upload $path
    Assert-True ($r.Code -eq 400) "unsafe or reserved path rejected: $path"
}

# Reproduce a ProRAW sidecar in a deep save directory. Its final path fits
# Windows PowerShell's legacy limit; appending a GUID to the full name does not.
$longDirectoryName = 'p' * [Math]::Max(1, (158 - $script:SavePath.Length - 1))
$longRelativeDirectory = $longDirectoryName + '/2026/10'
$longRelative = $longRelativeDirectory + '/20260101_000000_' + ('1' * 32) + '.adjustment-r0.plist'
$longTarget = Join-Path $script:SavePath ($longRelative -replace '/', '\')
Assert-True ($longTarget.Length -lt 260 -and ($longTarget.Length + 45) -ge 260) 'fixture reproduces a valid sidecar path whose old temporary name exceeds MAX_PATH'
$originalSidecar = '<plist><string>AAAA</string></plist>'
$differentSidecar = '<plist><string>BBBB</string></plist>'
$r = Invoke-Upload $longRelative $originalSidecar '' -1 'adjustment'
Assert-True ($r.Code -eq 200 -and $r.Body.manifestCommitted -eq $true -and [IO.File]::Exists($longTarget) -and [IO.File]::ReadAllText($longTarget) -eq $originalSidecar) 'long ProRAW sidecar is stored and committed'
$r = Invoke-Upload $longRelative $originalSidecar '' -1 'adjustment'
Assert-True ($r.Code -eq 200 -and $r.Body.skipped -eq $true -and @(Read-Rows | Where-Object serverPath -eq $longRelative).Count -eq 1) 'long sidecar retry is idempotent'
$r = Invoke-Upload $longRelative $differentSidecar '' -1 'adjustment'
$longConflicts = @(Get-ChildItem -LiteralPath ([IO.Path]::GetDirectoryName($longTarget)) -File | Where-Object Name -like '*.conflict-*')
Assert-True ($r.Code -eq 409 -and [IO.File]::ReadAllText($longTarget) -eq $originalSidecar -and $longConflicts.Count -eq 1 -and [IO.File]::ReadAllText($longConflicts[0].FullName) -eq $differentSidecar) 'long sidecar conflict preserves original and incoming content'
$r = Invoke-Upload $longRelative $differentSidecar ('0' * 64) -1 'adjustment'
Assert-True ($r.Code -eq 422 -and [IO.File]::ReadAllText($longTarget) -eq $originalSidecar) 'long sidecar checksum mismatch never changes existing content'
$longEnvelope = $longRelativeDirectory + '/20260101_000000_' + ('2' * 32) + '.adjustmentAAE-r1.aae'
$r = Invoke-Upload $longEnvelope $originalSidecar '' -1 'adjustmentAAE'
Assert-True ($r.Code -eq 200 -and $r.Body.manifestCommitted -eq $true) 'long AAE envelope is stored and committed'
Assert-True (@(Get-ChildItem -LiteralPath $script:SavePath -Recurse -File | Where-Object Name -like '*.part').Count -eq 0) 'no temporary upload files remain'
Write-Host "$script:checks checks; $script:failures failures. Synthetic fixtures: $script:SavePath"
if ($script:failures) { exit 1 }
