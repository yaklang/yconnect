# Only run on a disposable CI runner: installs 0.4.0 then upgrades to this build.
$ErrorActionPreference = 'Stop'
if ($env:CI -ne 'true') { throw 'Upgrade fixture requires an isolated CI runner' }
$root = Join-Path $env:RUNNER_TEMP ('yconnect-upgrade-' + [Guid]::NewGuid())
$install = Join-Path $root 'app'
[void][IO.Directory]::CreateDirectory($root)
$baseline = Join-Path $root 'baseline.exe'
$sentinel = Join-Path $env:LOCALAPPDATA ('YConnect\upgrade-fixture-' + [Guid]::NewGuid() + '.txt')
$expected = 'Account data and external client configuration remain outside the application payload.'
function Install-Package([string]$Path,[string[]]$Arguments) {
    $process = Start-Process -FilePath $Path -ArgumentList $Arguments -PassThru
    if (-not $process.WaitForExit(120000)) { $process.Kill(); throw 'Upgrade installer timed out' }
    if ($process.ExitCode -ne 0) { throw "Upgrade installer failed: $($process.ExitCode)" }
}
try {
    Invoke-WebRequest 'https://aliyun-oss.yaklang.com/yconnect/0.4.0/YConnect-0.4.0-windows-x64-setup.exe' -OutFile $baseline
    if ((Get-FileHash $baseline).Hash -ne 'E98EAC1B8AC40F024918E2FD0F4A212F3DAA0AD7E4355292F6761F8379FDC409') { throw 'Baseline release checksum mismatch' }
    Install-Package $baseline @('/VERYSILENT','/NORESTART',('/DIR="{0}"' -f $install))
    [void][IO.Directory]::CreateDirectory((Split-Path $sentinel)); [IO.File]::WriteAllText($sentinel, $expected)
    $setups = @(Get-ChildItem (Join-Path $PSScriptRoot 'artifacts\release\*-setup.exe'))
    if ($setups.Count -ne 1) { throw 'Expected exactly one new installer' }
    Install-Package $setups[0].FullName @('/SILENT','/SP-','/NORESTART','/NOFORCECLOSEAPPLICATIONS','/YCONNECTUPDATE=1',('/DIR="{0}"' -f $install))
    $exe = Join-Path $install 'YConnect.exe'
    if ((Get-FileHash $exe).Hash -ne (Get-FileHash (Join-Path $PSScriptRoot 'YConnect\bin\Release\net48\YConnect.exe')).Hash) { throw 'Upgrade installed the wrong executable' }
    $deadline = [DateTime]::UtcNow.AddSeconds(20); $reopened = @()
    do {
        $reopened = @(Get-Process -Name YConnect -ErrorAction SilentlyContinue | Where-Object { $_.Path -eq $exe })
        if (-not $reopened) { Start-Sleep -Milliseconds 250 }
    } while (-not $reopened -and [DateTime]::UtcNow -lt $deadline)
    if (-not $reopened) { throw 'Updated client was not reopened' }
    if ([IO.File]::ReadAllText($sentinel) -ne $expected) { throw 'Upgrade changed account data' }
    Write-Host 'Upgrade from signed 0.4.0, replacement, automatic relaunch and account-data preservation verified'
} finally {
    $exe = Join-Path $install 'YConnect.exe'
    Get-Process -Name YConnect -ErrorAction SilentlyContinue | Where-Object { $_.Path -eq $exe } | Stop-Process -Force
    $uninstaller = Join-Path $install 'unins000.exe'
    if (Test-Path $uninstaller) { Install-Package $uninstaller @('/VERYSILENT','/NORESTART') }
    Remove-Item -LiteralPath $sentinel -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $root -Recurse -Force
}
