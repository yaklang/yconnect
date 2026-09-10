$ErrorActionPreference = 'Stop'
function Get-Sha256([string]$File) {
    $hash = [Security.Cryptography.SHA256]::Create()
    $stream = [IO.File]::OpenRead($File)
    try { return [BitConverter]::ToString($hash.ComputeHash($stream)).Replace('-', '') }
    finally { $stream.Dispose(); $hash.Dispose() }
}
$root = Join-Path $PSScriptRoot '.dependencies\WinSparkle-0.9.4'
$dll = Join-Path $root 'x64\Release\WinSparkle.dll'
if (Test-Path -LiteralPath $dll) {
    if ((Get-Sha256 $dll) -eq '9B43B1C16EE39FB9A91B5BD75138767898779510E0836BE2919250607CDBE8AB') { return }
    throw 'Cached WinSparkle DLL checksum mismatch; remove windows/.dependencies and rebuild'
}
$temporary = Join-Path ([IO.Path]::GetTempPath()) ('yconnect-winsparkle-' + [Guid]::NewGuid())
[void][IO.Directory]::CreateDirectory($temporary)
try {
    $zip = Join-Path $temporary 'WinSparkle.zip'
    Invoke-WebRequest 'https://github.com/vslavik/winsparkle/releases/download/v0.9.4/WinSparkle-0.9.4.zip' -OutFile $zip
    if ((Get-Sha256 $zip) -ne '6037DF37FC263BD1650A1C4949681A9D40FFE991D01F35892A406CB5D103C976') { throw 'WinSparkle distribution checksum mismatch' }
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [IO.Compression.ZipFile]::ExtractToDirectory($zip, $temporary)
    [void][IO.Directory]::CreateDirectory((Split-Path $root))
    Move-Item -LiteralPath (Join-Path $temporary 'WinSparkle-0.9.4') -Destination $root
    if (-not (Test-Path -LiteralPath $dll)) { throw 'WinSparkle x64 binary missing' }
} finally { Remove-Item -LiteralPath $temporary -Recurse -Force }
