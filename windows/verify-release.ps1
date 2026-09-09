param([Parameter(Mandatory = $true)][string]$InstallDirectory)
$ErrorActionPreference = 'Stop'
$version = (Get-Content (Join-Path $PSScriptRoot '..\VERSION') -Raw).Trim()
$release = Join-Path $PSScriptRoot 'artifacts\release'
$temporary = Join-Path $env:RUNNER_TEMP ('yconnect-signature-check-' + [Guid]::NewGuid())
[void][IO.Directory]::CreateDirectory($temporary)
try {
    Expand-Archive -LiteralPath (Join-Path $release "YConnect-$version-windows-x64.zip") -DestinationPath $temporary
    $portableExe = @(Get-ChildItem $temporary -Filter YConnect.exe -Recurse)
    if ($portableExe.Count -ne 1) { throw 'Expected one portable executable' }
    $assembly = [Reflection.Assembly]::Load([IO.File]::ReadAllBytes($portableExe[0].FullName))
    if ($assembly.GetName().Version.ToString(3) -ne $version) { throw 'Packaged assembly version mismatch' }
    $helper = Join-Path $temporary 'YConnect.CredentialReader.exe'
    $resource = $assembly.GetManifestResourceStream('YConnect.CredentialReader.exe')
    if (-not $resource) { throw 'Embedded credential reader missing' }
    $output = [IO.File]::Create($helper)
    try { $resource.CopyTo($output) } finally { $output.Dispose(); $resource.Dispose() }
    $files = @(
        $portableExe[0].FullName,
        (Join-Path $portableExe[0].DirectoryName 'YConnect.Launcher.exe'),
        $helper,
        (Join-Path $release "YConnect-$version-windows-x64-setup.exe"),
        (Join-Path $InstallDirectory 'YConnect.exe'),
        (Join-Path $InstallDirectory 'YConnect.Launcher.exe'),
        (Join-Path $InstallDirectory 'unins000.exe')
    )
    $thumbprint = $null
    foreach ($file in $files) {
        $signature = Get-AuthenticodeSignature -LiteralPath $file
        if ($signature.Status -ne 'Valid' -or -not $signature.TimeStamperCertificate) { throw "Invalid or untimestamped signature: $file ($($signature.Status))" }
        if ($thumbprint -and $signature.SignerCertificate.Thumbprint -ne $thumbprint) { throw "Unexpected signing certificate: $file" }
        $thumbprint = $signature.SignerCertificate.Thumbprint
        Write-Host "Authenticode verified: $file; status=Valid; timestamped=True"
    }
    foreach ($name in @('YConnect.exe', 'YConnect.Launcher.exe')) {
        if ((Get-FileHash (Join-Path $portableExe[0].DirectoryName $name)).Hash -ne (Get-FileHash (Join-Path $InstallDirectory $name)).Hash) { throw "Installer/ZIP payload mismatch: $name" }
    }
} finally { Remove-Item -LiteralPath $temporary -Recurse -Force }
