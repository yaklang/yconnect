param([Parameter(Mandatory = $true, Position = 0)][string]$File)
$ErrorActionPreference = 'Stop'
if (-not (Test-Path -LiteralPath $File -PathType Leaf)) { throw "Signing target missing: $File" }
foreach ($name in @('WINDOWS_CODE_SIGN_KEY_VAULT_URI', 'WINDOWS_CODE_SIGN_CLIENT_ID', 'WINDOWS_CODE_SIGN_CLIENT_SECRET', 'WINDOWS_CODE_SIGN_CERT_NAME', 'WINDOWS_CODE_SIGN_TENANT_ID')) {
    if ([string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable($name))) { throw "Required signing credential missing: $name" }
}
$tool = Get-Command AzureSignTool -ErrorAction Stop
$timestamp = $env:WINDOWS_CODE_SIGN_TIMESTAMP_URL
if ([string]::IsNullOrWhiteSpace($timestamp)) { $timestamp = 'http://timestamp.digicert.com' }
& $tool.Source sign -kvu $env:WINDOWS_CODE_SIGN_KEY_VAULT_URI -kvi $env:WINDOWS_CODE_SIGN_CLIENT_ID `
    -kvt $env:WINDOWS_CODE_SIGN_TENANT_ID -kvs $env:WINDOWS_CODE_SIGN_CLIENT_SECRET `
    -kvc $env:WINDOWS_CODE_SIGN_CERT_NAME -fd sha256 -tr $timestamp -td sha256 $File
if ($LASTEXITCODE -ne 0) { throw "AzureSignTool failed: $LASTEXITCODE" }
$signature = Get-AuthenticodeSignature -LiteralPath $File
if ($signature.Status -ne 'Valid' -or -not $signature.TimeStamperCertificate) { throw "Invalid or untimestamped signature: $File ($($signature.Status))" }
Write-Host "Authenticode verified: $File; status=$($signature.Status); timestamped=True"
