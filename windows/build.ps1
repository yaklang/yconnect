[CmdletBinding()]
param([switch]$Test,[switch]$Smoke,[switch]$VerifyLogin,[switch]$Package,[switch]$Run,[switch]$NoProxy)
$ErrorActionPreference = 'Stop'
$project = Join-Path $PSScriptRoot 'YConnect\YConnect.csproj'
$configuration = 'Release'
dotnet build $project -c $configuration --verbosity minimal
if ($LASTEXITCODE -ne 0) { throw 'Native WPF build failed' }
$binaryDirectory = Join-Path $PSScriptRoot 'YConnect\bin\Release\net48'
$executable = Join-Path $binaryDirectory 'YConnect.exe'
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$testRoot = Join-Path $PSScriptRoot ".test-output\$stamp"
if ($Test) {
    dotnet build (Join-Path $PSScriptRoot 'YConnect.Tests\YConnect.Tests.csproj') -c $configuration --verbosity minimal
    if ($LASTEXITCODE -ne 0) { throw 'Test build failed' }
    & (Join-Path $PSScriptRoot 'YConnect.Tests\bin\Release\net48\YConnect.Tests.exe') (Join-Path $testRoot 'core')
    if ($LASTEXITCODE -ne 0) { throw 'Core verification failed' }
}
function Invoke-NativeCheck([string]$Flag,[string]$Name) {
    $checkOutput = Join-Path $testRoot $Name
    Write-Host "Running $Name with isolated data: $checkOutput"
    $checkArguments = @($Flag,('"--output={0}"' -f $checkOutput))
    if ($NoProxy) { $checkArguments += '--no-proxy' }
    $checkProcess = Start-Process -FilePath $executable -ArgumentList $checkArguments -PassThru -WindowStyle Hidden
    $deadline = [DateTime]::UtcNow.AddMinutes(2)
    while (-not $checkProcess.WaitForExit(1000)) {
        if ([DateTime]::UtcNow -gt $deadline) {
            # This exact child was started solely for this diagnostic run.
            $checkProcess.Kill()
            throw "$Name timed out; see $checkOutput"
        }
    }
    if ($checkProcess.ExitCode -ne 0) { throw "$Name failed; see $checkOutput" }
}
if ($Smoke) { Invoke-NativeCheck '--smoke' 'native-ui' }
if ($VerifyLogin) { Invoke-NativeCheck '--verify-login' 'official-login' }
if ($Package) {
    $portable = Join-Path $PSScriptRoot "artifacts\YConnect-0.2.0-windows-x64-$stamp"
    [void][System.IO.Directory]::CreateDirectory($portable)
    # No framework, browser runtime, PDBs, tests or companion repositories.
    $files = @('YConnect.exe','YConnect.exe.config','Newtonsoft.Json.dll','Tomlyn.dll','YamlDotNet.dll','Microsoft.Web.WebView2.Core.dll','Microsoft.Web.WebView2.Wpf.dll','WebView2Loader.dll')
    foreach ($file in $files) { Copy-Item -LiteralPath (Join-Path $binaryDirectory $file) -Destination $portable }
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'README.md') -Destination $portable
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'THIRD-PARTY-NOTICES.md') -Destination $portable
    $zip = "$portable.zip"
    Compress-Archive -LiteralPath $portable -DestinationPath $zip
    Write-Host "Portable app: $portable"
    Write-Host "ZIP: $zip"
    if ($Smoke) {
        $executable = Join-Path $portable 'YConnect.exe'
        Invoke-NativeCheck '--smoke' 'packaged-native-ui'
    }
    if ($Run) { $executable = Join-Path $portable 'YConnect.exe' }
}
if ($Run) { if ($NoProxy) { Start-Process -FilePath $executable -ArgumentList '--no-proxy' -WindowStyle Hidden } else { Start-Process -FilePath $executable -WindowStyle Hidden } }
