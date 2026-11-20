# The default player password belongs to this Windows user. Keep it separate
# from project backups and exports, encrypted with Windows DPAPI CurrentUser.
function Get-StudioSettingsPath {
    Join-Path ([IO.Path]::GetFullPath($WorkspaceDirectory)) 'player-settings.json'
}

function Assert-StudioSettingsFile([string]$Path) {
    if ([IO.Directory]::Exists($Path)) { throw 'The saved player settings path is a directory. Choose another workspace or repair that path.' }
    if ([IO.File]::Exists($Path)) {
        $file=[IO.FileInfo]::new($Path)
        if ($file.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'The saved player settings file cannot be a link.' }
        if ($file.Length -gt 16384) { throw 'The saved player settings could not be read. Save a new default password or clear it.' }
    }
}

function Read-StudioPlayerSettings([string]$Path) {
    Assert-StudioSettingsFile $Path
    if (-not [IO.File]::Exists($Path)) { return $null }
    $stream=$null; $reader=$null
    try {
        $stream=[IO.File]::Open($Path,[IO.FileMode]::Open,[IO.FileAccess]::Read,([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
        if ($stream.Length -gt 16384) { throw 'Settings file is too large.' }
        $reader=[IO.StreamReader]::new($stream,[Text.UTF8Encoding]::new($false,$true))
        $value=$reader.ReadToEnd() | ConvertFrom-Json -ErrorAction Stop
        if ($value -isnot [pscustomobject] -or $value.version -ne 1 -or
            $value.defaultPlayerPassword -isnot [string] -or
            [string]::IsNullOrEmpty($value.defaultPlayerPassword) -or $value.defaultPlayerPassword.Length -gt 12000) {
            throw 'Invalid settings format.'
        }
        return $value
    } catch {
        throw 'The saved player settings could not be read. Save a new default password or clear it.'
    } finally {
        if ($reader) { $reader.Dispose() } elseif ($stream) { $stream.Dispose() }
    }
}

function Get-StudioDefaultPlayerPassword {
    if ([Environment]::OSVersion.Platform -eq [PlatformID]::Unix) { $account=Get-StudioMacPasswordAccount; return [RelayMacKeychain]::Read($account) }
    $settings=Read-StudioPlayerSettings (Get-StudioSettingsPath)
    if ($null -eq $settings) { return '' }
    $protected=$null; $plain=$null
    try {
        Add-Type -AssemblyName System.Security
        $protected=[Convert]::FromBase64String($settings.defaultPlayerPassword)
        $plain=[Security.Cryptography.ProtectedData]::Unprotect($protected,$null,[Security.Cryptography.DataProtectionScope]::CurrentUser)
        $password=[Text.UTF8Encoding]::new($false,$true).GetString($plain)
        if ($password.Length -lt 1 -or $password.Length -gt 256) { throw 'Invalid stored value.' }
        return $password
    } catch {
        throw 'The default player password could not be unlocked for this Windows user. Save it again or clear it.'
    } finally {
        if ($plain) { [Array]::Clear($plain,0,$plain.Length) }
        if ($protected) { [Array]::Clear($protected,0,$protected.Length) }
    }
}

function Set-StudioDefaultPlayerPassword([AllowEmptyString()][string]$Password) {
    if ($null -eq $Password -or $Password.Length -gt 256) { throw 'Use a player password of 256 characters or fewer.' }
    if ([Environment]::OSVersion.Platform -eq [PlatformID]::Unix) { $account=Get-StudioMacPasswordAccount; [RelayMacKeychain]::Write($account,$Password); return }
    $path=Get-StudioSettingsPath
    $directory=[IO.Path]::GetDirectoryName($path)
    $sha=[Security.Cryptography.SHA256]::Create()
    try { $key=[BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($path.ToUpperInvariant()))).Replace('-','') }
    finally { $sha.Dispose() }
    $mutex=[Threading.Mutex]::new($false,'Local\RelayStudioSettings-'+$key)
    $locked=$false; $plain=$null; $protected=$null; $temp=$null
    try {
        try { $locked=$mutex.WaitOne(5000) } catch [Threading.AbandonedMutexException] { $locked=$true }
        if (-not $locked) { throw 'The player settings are busy. Try saving again.' }
        # Explicit save/clear can repair malformed content, but never follows a
        # linked file or touches a project, backup, or unrelated workspace file.
        if ([IO.Directory]::Exists($path)) { throw 'The saved player settings path is a directory.' }
        if ([IO.File]::Exists($path) -and ([IO.FileInfo]::new($path).Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            throw 'The saved player settings file cannot be a link.'
        }
        if ($Password.Length -eq 0) {
            if ([IO.File]::Exists($path)) { [IO.File]::Delete($path) }
            return
        }
        Add-Type -AssemblyName System.Security
        $plain=[Text.UTF8Encoding]::new($false,$true).GetBytes($Password)
        $protected=[Security.Cryptography.ProtectedData]::Protect($plain,$null,[Security.Cryptography.DataProtectionScope]::CurrentUser)
        $value=[ordered]@{version=1;defaultPlayerPassword=[Convert]::ToBase64String($protected)}
        $bytes=[Text.UTF8Encoding]::new($false).GetBytes(($value | ConvertTo-Json -Compress))
        [void][IO.Directory]::CreateDirectory($directory)
        $temp=Join-Path $directory ('player-settings-'+[guid]::NewGuid().ToString('N')+'.tmp')
        $file=[IO.FileStream]::new($temp,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
        try { $file.Write($bytes,0,$bytes.Length);$file.Flush($true) } finally { $file.Dispose() }
        if ([IO.File]::Exists($path)) { [IO.File]::Replace($temp,$path,[Management.Automation.Language.NullString]::Value) }
        else { [IO.File]::Move($temp,$path) }
    } finally {
        if ($plain) { [Array]::Clear($plain,0,$plain.Length) }
        if ($protected) { [Array]::Clear($protected,0,$protected.Length) }
        if ($temp -and [IO.File]::Exists($temp)) { [IO.File]::Delete($temp) }
        if ($locked) { $mutex.ReleaseMutex() }
        $mutex.Dispose()
    }
}

function Invoke-StudioSettingsRequest($Request,$Response,[string]$Path) {
    $Response.Headers['Cache-Control']='no-store'
    $Response.Headers['Pragma']='no-cache'
    if ($Request.HttpMethod -eq 'GET' -and $Path -eq '/api/settings') {
        try {
            $password=Get-StudioDefaultPlayerPassword
            Write-StudioJson $Response @{hasDefaultPlayerPassword=[bool]($password.Length)}
        } catch { Write-StudioJson $Response @{error=$_.Exception.Message} 422 }
        finally { $password=$null }
        return
    }
    if ($Request.HttpMethod -ne 'POST' -or $Path -notin '/api/settings/player-password','/api/settings/player-password/read') {
        Write-StudioJson $Response @{error='Settings endpoint not found.'} 404
        return
    }
    $options=Read-StudioJsonRequest $Request $Response
    if ($null -eq $options) { return }
    try {
        if ($Path -eq '/api/settings/player-password/read') {
            $password=Get-StudioDefaultPlayerPassword
            Write-StudioJson $Response @{password=[string]$password}
        } else {
            if ($options.password -isnot [string] -or $options.password.Length -gt 256) { throw 'Enter a player password of 256 characters or fewer, or leave it empty to clear the default.' }
            Set-StudioDefaultPlayerPassword $options.password
            Write-StudioJson $Response @{hasDefaultPlayerPassword=($options.password.Length -gt 0)}
        }
    } catch { Write-StudioJson $Response @{error=$_.Exception.Message} 422 }
    finally {
        $password=$null
        if ($options.PSObject.Properties['password']) { $options.password=$null }
    }
}
