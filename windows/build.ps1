[CmdletBinding()]
param([switch]$Test,[switch]$Smoke,[switch]$RechargeSmoke,[switch]$LauncherSmoke,[switch]$VerifyLogin,[switch]$Package,[switch]$Installer,[switch]$Run,[switch]$NoProxy,[switch]$Sign)
$ErrorActionPreference = 'Stop'
$project = Join-Path $PSScriptRoot 'YConnect\YConnect.csproj'
$version = (Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\VERSION') -Raw).Trim()
if ($version -notmatch '^\d+\.\d+\.\d+$') { throw 'VERSION must be a stable semantic version' }
if ($Installer) { $Package = $true }
$configuration = 'Release'
dotnet build $project -c $configuration --verbosity minimal
if ($LASTEXITCODE -ne 0) { throw 'Native WPF build failed' }
$binaryDirectory = Join-Path $PSScriptRoot 'YConnect\bin\Release\net48'
$executable = Join-Path $binaryDirectory 'YConnect.exe'
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$testRoot = Join-Path $PSScriptRoot ".test-output\$stamp"
if ($Test -or $LauncherSmoke) {
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
    if ($checkProcess.ExitCode -ne 0) {
        Get-ChildItem -LiteralPath $checkOutput -Filter '*results.txt' -File -ErrorAction SilentlyContinue | ForEach-Object { Get-Content -LiteralPath $_.FullName }
        throw "$Name failed; see $checkOutput"
    }
}
if ($Smoke) { Invoke-NativeCheck '--smoke' 'native-ui' }
if ($RechargeSmoke) { Invoke-NativeCheck '--verify-recharge' 'recharge-native-ui' }
if ($VerifyLogin) { Invoke-NativeCheck '--verify-login' 'official-login' }
function Invoke-LauncherCheck([string]$Runner,[string]$Name) {
    $checkOutput = Join-Path $testRoot $Name
    $harness = Join-Path $PSScriptRoot 'YConnect.LauncherTests\bin\Release\net48\YConnect.LauncherTests.exe'
    $fixture = Join-Path $PSScriptRoot 'YConnect.Tests\bin\Release\net48\YConnect.Tests.exe'
    $check = Start-Process -FilePath $harness -ArgumentList @(('"{0}"' -f $checkOutput),('"{0}"' -f $fixture),('"{0}"' -f $Runner)) -PassThru -WindowStyle Hidden
    $deadline = [DateTime]::UtcNow.AddMinutes(3)
    while (-not $check.WaitForExit(1000)) { if ([DateTime]::UtcNow -gt $deadline) { $check.Kill(); throw "Launcher test timed out: $checkOutput" } }
    Get-Content -LiteralPath (Join-Path $checkOutput 'result.txt')
    if ($check.ExitCode -ne 0) { throw "Launcher verification failed: $checkOutput" }
}
if ($LauncherSmoke) {
    dotnet build (Join-Path $PSScriptRoot 'YConnect.LauncherTests\YConnect.LauncherTests.csproj') -c $configuration --verbosity minimal
    if ($LASTEXITCODE -ne 0) { throw 'WPF launcher test build failed' }
    Invoke-LauncherCheck (Join-Path $binaryDirectory 'YConnect.Launcher.exe') 'interactive-launchers'
}
if ($Sign) {
    if (-not $Package -and -not $Installer) { throw '-Sign requires -Package or -Installer' }
    dotnet build $project -c $configuration --verbosity minimal -p:YConnectSignRelease=true
    if ($LASTEXITCODE -ne 0) { throw 'Signed release build failed' }
}
if ($Package) {
    $portable = Join-Path $PSScriptRoot "artifacts\YConnect-$version-windows-x64-$stamp"
    [void][System.IO.Directory]::CreateDirectory($portable)
    # No framework, browser runtime, PDBs, tests or companion repositories.
    $files = @('YConnect.exe','YConnect.exe.config','YConnect.Launcher.exe','YConnect.Launcher.exe.config','Newtonsoft.Json.dll','QRCoder.dll','Tomlyn.dll','YamlDotNet.dll','Microsoft.Web.WebView2.Core.dll','Microsoft.Web.WebView2.Wpf.dll','WebView2Loader.dll')
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
        $compilerArguments = @("/DAppVersion=$version", "/DPayloadDirectory=$portable", "/DReleaseDirectory=$releaseDirectory")
        if ($Sign) {
            $signScript = Join-Path $PSScriptRoot 'azure-sign.ps1'
            $signCommand = 'pwsh.exe -NoProfile -File $q' + $signScript + '$q -File $f'
            $compilerArguments += @('/DSignRelease=1', ('/SYConnect=' + $signCommand))
        }
        & $compiler @compilerArguments (Join-Path $PSScriptRoot 'installer\YConnect.iss')
        if ($LASTEXITCODE -ne 0) { throw 'Windows installer build failed' }
    }
    if ($Smoke) {
        $executable = Join-Path $portable 'YConnect.exe'
        Invoke-NativeCheck '--smoke' 'packaged-native-ui'
    }
    if ($RechargeSmoke) {
        $executable = Join-Path $portable 'YConnect.exe'
        Invoke-NativeCheck '--verify-recharge' 'packaged-recharge-native-ui'
    }
    if ($LauncherSmoke) { Invoke-LauncherCheck (Join-Path $portable 'YConnect.Launcher.exe') 'packaged-interactive-launchers' }
    if ($Run) { $executable = Join-Path $portable 'YConnect.exe' }
}
if ($Run) { if ($NoProxy) { Start-Process -FilePath $executable -ArgumentList '--no-proxy' -WindowStyle Hidden } else { Start-Process -FilePath $executable -WindowStyle Hidden } }
