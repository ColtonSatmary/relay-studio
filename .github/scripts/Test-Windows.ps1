# Synthetic fixtures and loopback services only. No connected players or USB.
param([string]$NodePath = 'node')
$ErrorActionPreference = 'Stop'
$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$windowsPowerShell = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
if (-not [IO.File]::Exists($windowsPowerShell)) { throw 'These checks require Windows PowerShell 5.1.' }

Push-Location -LiteralPath $repoRoot
try {
    $javascriptTests = @(Get-ChildItem -LiteralPath $repoRoot -Filter '*.test.cjs' -File | Sort-Object Name)
    if ($javascriptTests.Count -eq 0) { throw 'No JavaScript tests were found.' }
    foreach ($test in $javascriptTests) {
        Write-Host ('Running ' + $test.Name)
        & $NodePath $test.FullName
        if ($LASTEXITCODE -ne 0) { throw ($test.Name + ' failed.') }
    }

    # Keep this allowlist explicit: the installed-library tests are opt-in.
    $windowsTests = @(
        'image-import.test.ps1',
        'image-export.test.ps1',
        'network-api.test.ps1',
        'network-batch.test.ps1',
        'network-batch-server.test.ps1',
        'network-transport.test.ps1',
        'player-directory.test.ps1',
        'player-discovery.test.ps1',
        'player-preview.test.ps1',
        'settings.test.ps1',
        'solution-preview.test.ps1',
        'usb-drive.test.ps1',
        'usb-eject.test.ps1'
    )
    foreach ($test in $windowsTests) {
        Write-Host ('Running ' + $test)
        & $windowsPowerShell -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File (Join-Path $repoRoot $test)
        if ($LASTEXITCODE -ne 0) { throw ($test + ' failed.') }
    }
    Write-Host ('Passed {0} JavaScript files and {1} isolated Windows test files.' -f $javascriptTests.Count, $windowsTests.Count)
} finally { Pop-Location }
