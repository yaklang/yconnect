$ErrorActionPreference = 'Stop'
$root = Join-Path $PSScriptRoot '.dependencies\WinSparkle-0.9.4'
$dll = Join-Path $root 'x64\WinSparkle.dll'
if (Test-Path -LiteralPath $dll) { return }
$temporary = Join-Path ([IO.Path]::GetTempPath()) ('yconnect-winsparkle-' + [Guid]::NewGuid())
[void][IO.Directory]::CreateDirectory($temporary)
try {
    $zip = Join-Path $temporary 'WinSparkle.zip'
    Invoke-WebRequest 'https://github.com/vslavik/winsparkle/releases/download/v0.9.4/WinSparkle-0.9.4.zip' -OutFile $zip
    if ((Get-FileHash $zip -Algorithm SHA256).Hash -ne '6037DF37FC263BD1650A1C4949681A9D40FFE991D01F35892A406CB5D103C976') { throw 'WinSparkle distribution checksum mismatch' }
    Expand-Archive -LiteralPath $zip -DestinationPath $temporary
    [void][IO.Directory]::CreateDirectory((Split-Path $root))
    Move-Item -LiteralPath (Join-Path $temporary 'WinSparkle-0.9.4') -Destination $root
    if (-not (Test-Path -LiteralPath $dll)) { throw 'WinSparkle x64 binary missing' }
} finally { Remove-Item -LiteralPath $temporary -Recurse -Force }
