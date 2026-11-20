# All secrets and files in this test are synthetic; the real workspace is untouched.
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'StudioSettings.ps1')
function Assert-Settings([bool]$Condition,[string]$Message) { if (-not $Condition) { throw ('Test failed: '+$Message) } }
function Assert-SettingsThrows([scriptblock]$Action,[string]$Expected) {
    $message=''
    try { $null=& $Action } catch { $message=$_.Exception.Message }
    Assert-Settings ($message -like ('*'+$Expected+'*')) 'Expected settings refusal was not returned.'
}

$tempParent=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')
$WorkspaceDirectory=Join-Path $tempParent ('RelaySettingsTest-'+[guid]::NewGuid().ToString('N'))
$testDirectory=[IO.Directory]::CreateDirectory($WorkspaceDirectory).FullName
$settingsPath=Join-Path $testDirectory 'player-settings.json'
$sentinelPath=Join-Path $testDirectory 'workspace.json'
[IO.File]::WriteAllText($sentinelPath,'{"fixture":"preserve"}')
try {
    Assert-Settings ([string]::IsNullOrEmpty((Get-StudioDefaultPlayerPassword))) 'Empty settings should return no password.'
    $secretA='Synthetic settings test only '+[char]0x4E2D+[char]0x6587+[char]0x00E9
    $secretB='Second synthetic company '+[guid]::NewGuid().ToString('N')
    Set-StudioDefaultPlayerPassword $secretA
    $saved=[IO.File]::ReadAllText($settingsPath)
    Assert-Settings (-not $saved.Contains($secretA)) 'Plaintext was written to disk.'
    $stored=$saved | ConvertFrom-Json
    Assert-Settings ($stored.version -eq 1 -and @($stored.PSObject.Properties).Count -eq 2) 'Unexpected storage fields.'
    Assert-Settings (([Convert]::FromBase64String($stored.defaultPlayerPassword)).Length -gt 0) 'Encrypted payload is missing.'
    Assert-Settings ((Get-StudioDefaultPlayerPassword) -ceq $secretA) 'Unicode DPAPI round trip failed.'
    Assert-Settings (-not [IO.File]::Exists($settingsPath+'.bak')) 'Settings must not retain password backups.'

    # Reload the definitions to establish that the value is read from the file,
    # not held in a module variable or tied to the lifetime of the request.
    . (Join-Path $PSScriptRoot 'StudioSettings.ps1')
    Assert-Settings ((Get-StudioDefaultPlayerPassword) -ceq $secretA) 'Reload did not preserve the default password.'
    $restartScript=Join-Path $testDirectory 'verify-restart.ps1'
    [IO.File]::WriteAllText($restartScript,@'
param($SettingsScript,$WorkspaceDirectory,$ExpectedHash)
$ErrorActionPreference='Stop'
. $SettingsScript
$password=Get-StudioDefaultPlayerPassword
$sha=[Security.Cryptography.SHA256]::Create()
try { $actual=[Convert]::ToBase64String($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($password))) }
finally { $sha.Dispose();$password=$null }
if ($actual -cne $ExpectedHash) { throw 'The saved default did not survive a process restart.' }
'Restarted-process DPAPI read passed.'
'@,[Text.UTF8Encoding]::new($false))
    $hash=[Security.Cryptography.SHA256]::Create()
    try { $expectedHash=[Convert]::ToBase64String($hash.ComputeHash([Text.Encoding]::UTF8.GetBytes($secretA))) }
    finally { $hash.Dispose() }
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $restartScript -SettingsScript (Join-Path $PSScriptRoot 'StudioSettings.ps1') -WorkspaceDirectory $WorkspaceDirectory -ExpectedHash $expectedHash
    Assert-Settings ($LASTEXITCODE -eq 0) 'Password persistence failed in another process.'
    Set-StudioDefaultPlayerPassword $secretB
    Assert-Settings ((Get-StudioDefaultPlayerPassword) -ceq $secretB) 'Replacing a company password failed.'
    Assert-Settings (-not ([IO.File]::ReadAllText($settingsPath)).Contains($secretB)) 'Replacement plaintext was written to disk.'
    $before=[IO.File]::ReadAllText($settingsPath)
    Assert-SettingsThrows { Set-StudioDefaultPlayerPassword ('x'*257) } '256'
    Assert-Settings ([IO.File]::ReadAllText($settingsPath) -ceq $before) 'An invalid save changed the existing default.'

    [IO.File]::WriteAllText($settingsPath,'not valid settings')
    Assert-SettingsThrows { Get-StudioDefaultPlayerPassword } 'could not be read'
    Assert-Settings ([IO.File]::ReadAllText($settingsPath) -ceq 'not valid settings') 'A corrupt read changed the file.'
    [IO.File]::WriteAllText($settingsPath,'{"version":1,"defaultPlayerPassword":"AQID"}')
    Assert-SettingsThrows { Get-StudioDefaultPlayerPassword } 'could not be unlocked'
    Set-StudioDefaultPlayerPassword $secretA
    Assert-Settings ((Get-StudioDefaultPlayerPassword) -ceq $secretA) 'Explicit save could not repair corrupt data.'

    function Write-StudioJson($Response,$Value,[int]$Status=200) { $script:lastReply=@{body=$Value;status=$Status} }
    function Read-StudioJsonRequest($Request,$Response) {
        if (-not $script:authorized) { Write-StudioJson $Response @{error='Not authorized.'} 403;return }
        return $script:body
    }
    $response=[pscustomobject]@{Headers=@{}}
    $get=[pscustomobject]@{HttpMethod='GET'}
    $post=[pscustomobject]@{HttpMethod='POST'}
    $script:authorized=$true
    Invoke-StudioSettingsRequest $get $response '/api/settings'
    Assert-Settings ($script:lastReply.status -eq 200 -and $script:lastReply.body.hasDefaultPlayerPassword -and $script:lastReply.body.Count -eq 1) 'Metadata exposed unexpected fields.'
    Assert-Settings ($response.Headers['Cache-Control'] -ceq 'no-store' -and $response.Headers['Pragma'] -ceq 'no-cache') 'Settings response could be cached.'
    Invoke-StudioSettingsRequest $get $response '/api/settings/player-password/read'
    Assert-Settings ($script:lastReply.status -eq 404) 'Password read was available as an unauthenticated GET.'

    $script:authorized=$false
    $script:body=[pscustomobject]@{}
    Invoke-StudioSettingsRequest $post $response '/api/settings/player-password/read'
    Assert-Settings ($script:lastReply.status -eq 403 -and -not $script:lastReply.body.ContainsKey('password')) 'Unauthorized read exposed credentials.'
    $script:body=[pscustomobject]@{password=$secretB}
    Invoke-StudioSettingsRequest $post $response '/api/settings/player-password'
    Assert-Settings ($script:lastReply.status -eq 403 -and (Get-StudioDefaultPlayerPassword) -ceq $secretA) 'Unauthorized save modified settings.'

    $script:authorized=$true
    $script:body=[pscustomobject]@{}
    Invoke-StudioSettingsRequest $post $response '/api/settings/player-password/read'
    Assert-Settings ($script:lastReply.status -eq 200 -and $script:lastReply.body.password -ceq $secretA) 'Authenticated read failed.'
    $script:lastReply=$null
    $script:body=[pscustomobject]@{}
    Invoke-StudioSettingsRequest $post $response '/api/settings/player-password'
    Assert-Settings ($script:lastReply.status -eq 422) 'Malformed save was accepted.'
    $script:body=[pscustomobject]@{password=$secretB}
    Invoke-StudioSettingsRequest $post $response '/api/settings/player-password'
    Assert-Settings ($script:lastReply.status -eq 200 -and $script:lastReply.body.hasDefaultPlayerPassword -and -not $script:lastReply.body.ContainsKey('password')) 'Save response exposed the password or failed.'
    Assert-Settings ($null -eq $script:body.password) 'Request password was retained after saving.'
    $script:body=[pscustomobject]@{password=''}
    Invoke-StudioSettingsRequest $post $response '/api/settings/player-password'
    Assert-Settings ($script:lastReply.status -eq 200 -and -not $script:lastReply.body.hasDefaultPlayerPassword) 'Clear did not return empty metadata.'
    Assert-Settings (-not [IO.File]::Exists($settingsPath) -and [IO.File]::ReadAllText($sentinelPath) -ceq '{"fixture":"preserve"}') 'Clear removed an unrelated file or retained the secret.'
    $script:body=[pscustomobject]@{}
    Invoke-StudioSettingsRequest $post $response '/api/settings/player-password/read'
    Assert-Settings ($script:lastReply.status -eq 200 -and $script:lastReply.body.password -ceq '') 'Cleared default should autofill an empty string.'
    Assert-Settings (@(Get-ChildItem -LiteralPath $testDirectory -Filter '*.tmp').Count -eq 0) 'Atomic-write temporary files remain.'
    'Settings tests passed: DPAPI storage, Unicode/replacement/clear, corruption handling, authentication and no-store responses.'
} finally {
    $secretA=$null;$secretB=$null;$saved=$null;$stored=$null;$before=$null;$script:body=$null;$script:lastReply=$null
    $resolved=[IO.Path]::GetFullPath($testDirectory).TrimEnd('\')
    if ([IO.Path]::GetDirectoryName($resolved) -cne $tempParent -or [IO.Path]::GetFileName($resolved) -cnotmatch '^RelaySettingsTest-[a-f0-9]{32}$') { throw 'Invalid test cleanup target.' }
    foreach($leaf in @('player-settings.json','workspace.json','verify-restart.ps1')) {
        $file=Join-Path $resolved $leaf
        if ([IO.File]::Exists($file)) { [IO.File]::Delete($file) }
    }
    [IO.Directory]::Delete($resolved,$false)
}
