[CmdletBinding()]
param([switch]$Test,[switch]$Smoke,[switch]$VerifyLogin,[switch]$Package,[switch]$Installer,[switch]$Run,[switch]$NoProxy)
$ErrorActionPreference = 'Stop'
$project = Join-Path $PSScriptRoot 'YConnect\YConnect.csproj'
$version = (Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\VERSION') -Raw).Trim()
if ($version -notmatch '^\d+\.\d+\.\d+$') { throw 'VERSION must be a stable semantic version' }
$projectXml = [xml](Get-Content -LiteralPath $project -Raw)
if ($projectXml.Project.PropertyGroup.Version -ne $version) { throw 'Windows project version differs from VERSION' }
if ($Installer) { $Package = $true }
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
    $deadline = [DateTime]::UtcNow.AddMinutes(3)
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
    $portable = Join-Path $PSScriptRoot "artifacts\YConnect-$version-windows-x64-$stamp"
    [void][System.IO.Directory]::CreateDirectory($portable)
    # No framework, browser runtime, PDBs, tests or companion repositories.
    $files = @('YConnect.exe','YConnect.exe.config','Newtonsoft.Json.dll','Tomlyn.dll','YamlDotNet.dll','Microsoft.Web.WebView2.Core.dll','Microsoft.Web.WebView2.Wpf.dll','WebView2Loader.dll')
    foreach ($file in $files) { Copy-Item -LiteralPath (Join-Path $binaryDirectory $file) -Destination $portable }
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'README.md') -Destination $portable
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'UX.md') -Destination $portable
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'PORTING.md') -Destination $portable
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'THIRD-PARTY-NOTICES.md') -Destination $portable
    $zip = "$portable.zip"
    Compress-Archive -LiteralPath $portable -DestinationPath $zip
    Write-Host "Portable app: $portable"
    Write-Host "ZIP: $zip"
    if ($Installer) {
        $compiler = Join-Path ${env:ProgramFiles(x86)} 'Inno Setup 6\ISCC.exe'
        if (-not (Test-Path -LiteralPath $compiler)) { $compiler = (Get-Command ISCC.exe -ErrorAction Stop).Source }
        $releaseDirectory = Join-Path $PSScriptRoot 'artifacts\release'
        [void][System.IO.Directory]::CreateDirectory($releaseDirectory)
        Copy-Item -LiteralPath $zip -Destination (Join-Path $releaseDirectory "YConnect-$version-windows-x64.zip")
        & $compiler "/DAppVersion=$version" "/DPayloadDirectory=$portable" "/DReleaseDirectory=$releaseDirectory" (Join-Path $PSScriptRoot 'installer\YConnect.iss')
        if ($LASTEXITCODE -ne 0) { throw 'Windows installer build failed' }
    }
    if ($Smoke) {
        $executable = Join-Path $portable 'YConnect.exe'
        Invoke-NativeCheck '--smoke' 'packaged-native-ui'
    }
    if ($Run) { $executable = Join-Path $portable 'YConnect.exe' }
}
if ($Run) { if ($NoProxy) { Start-Process -FilePath $executable -ArgumentList '--no-proxy' -WindowStyle Hidden } else { Start-Process -FilePath $executable -WindowStyle Hidden } }
