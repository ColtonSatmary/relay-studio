[CmdletBinding()]
param([switch]$NoBrowser, [string]$ExportRoot, [string]$WorkspaceDirectory, [ValidateRange(1024,65535)][int]$Port = 47833)

$ErrorActionPreference = 'Stop'
$origin = "http://127.0.0.1:$Port"
# Captured by the service at startup. New static UI files must not silently use
# an older listener whose loaded PowerShell functions have not been updated.
$runtimeBuild = '2026.11.19.2'
$studioIsMac = [Environment]::OSVersion.Platform -eq [PlatformID]::Unix
if ($studioIsMac -and -not $IsMacOS) { throw 'This launcher supports Windows and macOS.' }
if ($studioIsMac -and ($PSVersionTable.PSVersion -lt [version]'7.5' -or [Environment]::Version.Major -lt 9)) { throw 'Relay Studio for macOS requires PowerShell 7.5 or newer on .NET 9 or newer. Install a currently supported PowerShell release, then reopen Relay.' }
$configRoot = if ($studioIsMac) { Join-Path ([Environment]::GetFolderPath('UserProfile')) 'Library/Application Support/Relay Studio/ViPlex Config' } else { Join-Path $env:ProgramData 'ViPlexExpress\Config' }
if (-not $ExportRoot) {
    $documents=if($studioIsMac){Join-Path ([Environment]::GetFolderPath('UserProfile')) 'Documents'}else{[Environment]::GetFolderPath('MyDocuments')}
    $ExportRoot = Join-Path $documents 'Relay Studio Exports'
}
$ExportRoot = [IO.Path]::GetFullPath($ExportRoot)
if (-not $WorkspaceDirectory) {
    $WorkspaceDirectory = if ($studioIsMac) { Join-Path ([Environment]::GetFolderPath('UserProfile')) 'Library/Application Support/Relay Studio' } else { Join-Path $env:LOCALAPPDATA 'Relay Studio' }
}
$projectPath = Join-Path ([IO.Path]::GetFullPath($WorkspaceDirectory)) 'workspace.json'
$mediaRoot = Join-Path ([IO.Path]::GetFullPath($WorkspaceDirectory)) 'Media'
. (Join-Path $PSScriptRoot 'StudioCatalog.ps1')
. (Join-Path $PSScriptRoot 'StudioProject.ps1')
. (Join-Path $PSScriptRoot 'StudioMedia.ps1')
. (Join-Path $PSScriptRoot 'StudioSolutionPreview.ps1')
. (Join-Path $PSScriptRoot 'StudioUsb.ps1')
. (Join-Path $PSScriptRoot 'StudioUsbEject.ps1')
. (Join-Path $PSScriptRoot 'ViplexUsb.ps1')
. (Join-Path $PSScriptRoot 'StudioUsbApi.ps1')
. (Join-Path $PSScriptRoot 'StudioNetworkCatalog.ps1')
. (Join-Path $PSScriptRoot 'StudioNetwork.ps1')
. (Join-Path $PSScriptRoot 'StudioSettings.ps1')

function Open-StudioWindow {
    if ($NoBrowser) { return }
    if ($studioIsMac) { $null=Invoke-StudioMacTool '/usr/bin/open' @("$origin/"); return }
    $programRoots = @(${env:ProgramFiles(x86)}, $env:ProgramFiles, $env:LOCALAPPDATA)
    foreach ($root in $programRoots) {
        if (-not $root) { continue }
        $edge = Join-Path $root 'Microsoft\Edge\Application\msedge.exe'
        if ([IO.File]::Exists($edge)) {
            Start-Process -FilePath $edge -ArgumentList "--app=$origin/"
            return
        }
    }
    Start-Process "$origin/"
}

function Write-StudioBytes($Response, [string]$Type, [byte[]]$Bytes, [int]$Status = 200) {
    $Response.StatusCode = $Status
    $Response.ContentType = $Type
    $Response.ContentLength64 = $Bytes.Length
    $Response.OutputStream.Write($Bytes, 0, $Bytes.Length)
}

function Write-StudioText($Response, [string]$Type, [string]$Value, [int]$Status = 200) {
    Write-StudioBytes $Response $Type ([Text.Encoding]::UTF8.GetBytes($Value)) $Status
}

function Write-StudioJson($Response, $Value, [int]$Status = 200) {
    Write-StudioText $Response 'application/json; charset=utf-8' (ConvertTo-Json -InputObject $Value -Depth 32 -Compress) $Status
}

function Get-StudioCachedCatalog {
    if (-not $script:catalog -or ([DateTime]::UtcNow - $script:catalogReadAt).TotalSeconds -gt 5) {
        $script:catalog = Get-StudioCatalog $configRoot
        $script:catalogReadAt = [DateTime]::UtcNow
    }
    return $script:catalog
}

function Get-StudioExportLabel([string]$Name) {
    $label = ($Name -replace '[<>:"/\\|?*\x00-\x1f]', '-').Trim().TrimEnd('.')
    if ($label.Length -gt 48) { $label = $label.Substring(0,48).TrimEnd(' ','.') }
    return $label
}

function Test-StudioWriteRequest($Request, $Response) {
    if ($Request.Headers['Origin'] -cne $origin -or $Request.Headers['X-Studio-Token'] -cne $exportToken) {
        Write-StudioJson $Response @{error='Refresh Studio and try again.'} 403
        return $false
    }
    return $true
}

function Read-StudioJsonRequest($Request, $Response) {
    if (-not (Test-StudioWriteRequest $Request $Response)) { return }
    if ($Request.ContentType -notmatch '^application/json(?:\s*;|$)') {
        Write-StudioJson $Response @{error='Send a JSON Studio project.'} 415
        return
    }
    $maxBytes = 16MB
    if ($Request.ContentLength64 -gt $maxBytes) {
        Write-StudioJson $Response @{error='The project exceeds the 16 MB request limit.'} 413
        return
    }
    $body = [IO.MemoryStream]::new()
    try {
        $buffer = [byte[]]::new(16384)
        while (($count = $Request.InputStream.Read($buffer, 0, $buffer.Length)) -gt 0) {
            if ($body.Length + $count -gt $maxBytes) {
                Write-StudioJson $Response @{error='The project exceeds the 16 MB request limit.'} 413
                return
            }
            $body.Write($buffer, 0, $count)
        }
        $payload = [Text.UTF8Encoding]::new($false,$true).GetString($body.ToArray()) | ConvertFrom-Json -ErrorAction Stop
        if ($payload -isnot [pscustomobject]) { throw 'Expected a JSON object.' }
        return $payload
    } catch {
        Write-StudioJson $Response @{error='The request must contain a valid JSON object.'} 400
        return
    } finally { $body.Dispose() }
}

function Invoke-StudioExport($Request, $Response) {
    $payload = Read-StudioJsonRequest $Request $Response
    if ($null -eq $payload) { return }
    $project = $payload.project
    if ($project.version -ne 1 -or
            $project.screens -isnot [array] -or $project.cues -isnot [array] -or $project.solutions -isnot [array]) {
        Write-StudioJson $Response @{error='Choose screens in a version 1 Studio project.'} 400
        return
    }
    if ($payload.screenIds -is [array] -and $payload.screenIds.Count -and $null -eq $payload.screenId) {
        $selectedIds = $payload.screenIds
    } elseif ($payload.screenId -is [string] -and $null -eq $payload.screenIds) {
        $selectedIds = @($payload.screenId)
    } else {
        Write-StudioJson $Response @{error='Select one or more screens to export.'} 400
        return
    }
    $trusted = Get-StudioCachedCatalog
    $known = @{}
    foreach ($solution in $trusted.data.solutions) { $known[$solution.id] = $solution }
    $selected = [Collections.Generic.List[object]]::new()
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $scheduleNames = @{}
    if ($null -ne $payload.scheduleNames) {
        if ($payload.scheduleNames -isnot [pscustomobject]) {
            Write-StudioJson $Response @{error='Supply a schedule name for each selected screen.'} 400
            return
        }
        $usedNames = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        $occupied = Get-ViplexOccupiedNames $configRoot $trusted.data.solutions
        foreach ($item in $payload.scheduleNames.PSObject.Properties) {
            if ($selectedIds -cnotcontains $item.Name -or $item.Value -isnot [string] -or $item.Value -cnotmatch '^[a-zA-Z0-9]+$') {
                Write-StudioJson $Response @{error='Use only letters and numbers for each selected ViPlex schedule name.'} 422
                return
            }
            if ($occupied.Contains($item.Value) -or -not $usedNames.Add($item.Value)) {
                Write-StudioJson $Response @{error="The ViPlex name '$($item.Value)' is already in use. Give each screen a new name."} 422
                return
            }
            $scheduleNames[$item.Name] = $item.Value
        }
    }
    foreach ($id in $selectedIds) {
        $matching = @($project.screens | Where-Object { $_.id -ceq $id })
        if ($id -isnot [string] -or -not $seen.Add($id) -or $matching.Count -ne 1 -or
                $matching[0].name -isnot [string] -or -not $matching[0].name.Trim()) {
            Write-StudioJson $Response @{error='Select each named screen only once.'} 422
            return
        }
        $screen = $matching[0]
        $selected.Add($screen)
        $cues = @($project.cues | Where-Object { $_.screenId -ceq $id })
        if (-not $cues.Count) {
            Write-StudioJson $Response @{error="Add a cue to '$($screen.name)' before exporting."} 422
            return
        }
        foreach ($cue in $cues) {
            if ($cue.solutionId -isnot [string] -or -not $known.ContainsKey($cue.solutionId)) {
                Write-StudioJson $Response @{error="'$($screen.name)' uses a missing solution. Reimport its media or reconnect its ViPlex solution before exporting."} 422
                return
            }
        }
    }
    # Resolve all source information from the local catalog, including when
    # the request came from a shared or previously downloaded Studio project.
    $project.solutions = $trusted.data.solutions

    [void][IO.Directory]::CreateDirectory($exportRoot)
    $identifier = [guid]::NewGuid().ToString('N')
    $label = if ($selected.Count -eq 1) { Get-StudioExportLabel $selected[0].name } else { "$($selected.Count) screens" }
    $name = '{0} {1} {2}' -f (Get-Date -Format 'yyyy-MM-dd HHmmss'), $label, $identifier.Substring(0,8)
    $finalPath = Join-Path $exportRoot $name
    $staging = Join-Path $exportRoot ('.pending-' + $identifier)
    [void][IO.Directory]::CreateDirectory($staging)
    $failure = $null
    try {
        $packages = @(for ($i = 0; $i -lt $selected.Count; $i++) {
            $screen = $selected[$i]
            $output = $staging
            if ($selected.Count -gt 1) {
                $folder = '{0:D2} {1}' -f ($i + 1), (Get-StudioExportLabel $screen.name)
                $output = [IO.Directory]::CreateDirectory((Join-Path $staging $folder)).FullName
            }
            try {
                $options = @{ConfigRoot=$configRoot; Project=$project; ScreenId=$screen.id; OutputDirectory=$output}
                if ($scheduleNames.ContainsKey($screen.id)) { $options.ScheduleName = $scheduleNames[$screen.id] }
                Export-ViplexSchedule @options
                if (-not [IO.File]::Exists((Join-Path $output 'nova\command.json'))) { throw 'The ViPlex package is incomplete.' }
            } catch { throw "Could not export '$($screen.name)'. $($_.Exception.Message)" }
        })
        [IO.Directory]::Move($staging,$finalPath)
    } catch {
        $failure = $_.Exception.Message
    } finally {
        # Only clean the unique staging directory allocated by this request.
        if ([IO.Directory]::Exists($staging)) {
            $expectedParent = [IO.Path]::GetFullPath($exportRoot)
            $absolute = [IO.Path]::GetFullPath($staging)
            if ([IO.Path]::GetDirectoryName($absolute) -eq $expectedParent -and [IO.Path]::GetFileName($absolute) -ceq ('.pending-' + $identifier)) {
                [IO.Directory]::Delete($absolute, $true)
            }
        }
    }
    if ($failure) {
        Write-StudioJson $Response @{error=$failure} 422
        return
    }
    $result = @{path=$finalPath; name=$name; screenCount=$selected.Count; metadata=$packages}
    if ($selected.Count -eq 1) { $result.metadata = $packages[0] }
    Write-StudioJson $Response $result 201
}

function Invoke-StudioProject($Request, $Response) {
    try {
        if ($Request.HttpMethod -eq 'GET') {
            $state = Get-StudioProject $projectPath
            Write-StudioJson $Response $state
            return
        }
        $payload = Read-StudioJsonRequest $Request $Response
        if ($null -eq $payload) { return }
        if (-not $payload.PSObject.Properties['baseRevision'] -or
                ($null -ne $payload.baseRevision -and ($payload.baseRevision -isnot [string] -or $payload.baseRevision -notmatch '^[a-f0-9]{64}$')) -or
                -not (Test-StudioProject $payload.project)) {
            Write-StudioJson $Response @{error='Saving requires a version 1 project and its current revision.'} 400
            return
        }
        $state = Save-StudioProject $projectPath $payload.baseRevision $payload.project
        if ($state.conflict) {
            Write-StudioJson $Response @{error='Another window saved this workspace. Reload its latest changes.'; revision=$state.revision} 409
            return
        }
        Write-StudioJson $Response @{revision=$state.revision}
    } catch {
        Write-StudioJson $Response @{error="Studio could not access its saved workspace. $($_.Exception.Message)"} 500
    }
}

function Invoke-StudioRequest($Context, [ref]$Streaming) {
    $req = $Context.Request
    $res = $Context.Response
    $res.Headers['X-Content-Type-Options'] = 'nosniff'
    $res.Headers['Cross-Origin-Resource-Policy'] = 'same-origin'
    $res.Headers['X-Frame-Options'] = 'DENY'
    $res.Headers['Cache-Control'] = 'no-store'
    $path = $req.Url.AbsolutePath
    if ($req.Headers['Host'] -ne "127.0.0.1:$Port" -or $req.Headers['Sec-Fetch-Site'] -eq 'cross-site' -or
        ($req.Headers['Origin'] -and $req.Headers['Origin'] -ne $origin)) {
        Write-StudioText $res 'text/plain' 'Open the Studio launcher on this computer.' 403
        return
    }
    if ($path -eq '/api/export-viplex' -and $req.HttpMethod -eq 'POST') {
        Invoke-StudioExport $req $res
        return
    }
    if ($path -eq '/api/export-usb' -and $req.HttpMethod -eq 'POST') {
        Invoke-StudioUsbExport $req $res
        return
    }
    if ($path -eq '/api/eject-usb' -and $req.HttpMethod -eq 'POST') {
        Invoke-StudioUsbEject $req $res
        return
    }
    if ($path.StartsWith('/api/network/')) {
        Invoke-StudioNetworkRequest $req $res $path
        return
    }
    if ($path -eq '/api/settings' -or $path.StartsWith('/api/settings/')) {
        Invoke-StudioSettingsRequest $req $res $path
        return
    }
    if ($path -eq '/api/project' -and $req.HttpMethod -in 'GET','POST') {
        Invoke-StudioProject $req $res
        return
    }
    if ($path -eq '/api/media' -and $req.HttpMethod -eq 'POST') {
        if (-not (Test-StudioWriteRequest $req $res)) { return }
        if ($req.ContentType -notmatch '^(application/octet-stream|video/[a-z0-9.+-]+|image/jpeg)(;|$)') {
            Write-StudioJson $res @{error='Upload one video or JPG image as a binary file.'} 415
            return
        }
        try {
            if ($req.Url.Query -notmatch '(?:^\?|&)name=([^&]+)') { throw 'The media filename is missing.' }
            $fileName = [uri]::UnescapeDataString($Matches[1].Replace('+',' '))
            $solution = Import-StudioMedia $req.InputStream $fileName $req.QueryString['sourceName']
            $script:catalog = $null
            Write-StudioJson $res @{solution=$solution} 201
        } catch { Write-StudioJson $res @{error=$_.Exception.Message} 422 }
        return
    }
    if ($path -cmatch '^/api/solutions/(viplex-[a-f0-9-]{36}|(?:video|image)-[a-f0-9]{64}-[a-f0-9]{16})(?:/media/(\d+))?$' -and
        ($req.HttpMethod -eq 'GET' -or ($req.HttpMethod -eq 'HEAD' -and $Matches[2]))) {
        Invoke-StudioSolutionPreview $req $res $Matches[1] $Matches[2] $Streaming
        return
    }
    if ($req.HttpMethod -ne 'GET') {
        Write-StudioText $res 'text/plain' 'Method not allowed.' 405
        return
    }
    if ($path -eq '/api/health') {
        Write-StudioText $res 'text/plain' $instanceId
        return
    }
    if ($path -eq '/api/usb-drives') {
        Write-StudioJson $res @{drives=@(Get-StudioUsbChoices)}
        return
    }
    if ($path -eq '/api/session') {
        Write-StudioJson $res @{exportToken=$exportToken; runtimeBuild=$runtimeBuild; projectStoreVersion=1; mediaStoreVersion=1; usbPlaybackVersion=1; usbEjectVersion=1; solutionPreviewVersion=1; networkPlaybackVersion=1}
        return
    }
    if ($path -eq '/api/catalog') {
        $current = Get-StudioCachedCatalog
        Write-StudioText $res 'application/json; charset=utf-8' (ConvertTo-Json $current.data -Depth 32 -Compress)
        return
    }
    if ($path -cmatch '^/api/media-preview/([a-f0-9]{64})$') {
        $asset = Get-StudioMediaAsset $Matches[1]
        if ($asset) {
            Write-StudioBytes $res 'image/png' ([IO.File]::ReadAllBytes($asset.thumbnailPath))
            return
        }
    }
    if ($path -match '^/api/thumbnail/(viplex-[a-f0-9-]{36})$') {
        $id = $Matches[1]
        if (-not $script:catalog) { $null = Get-StudioCachedCatalog }
        $imagePath = $script:catalog.thumbnails[$id]
        if ($imagePath -and [IO.File]::Exists($imagePath)) {
            # ViPlex also stores JPEG-encoded thumbnails under .png filenames.
            $bytes = [IO.File]::ReadAllBytes($imagePath)
            $type = if ($bytes.Length -ge 3 -and $bytes[0] -eq 255 -and $bytes[1] -eq 216 -and $bytes[2] -eq 255) { 'image/jpeg' }
                    elseif ($bytes.Length -ge 8 -and [BitConverter]::ToString($bytes,0,8) -eq '89-50-4E-47-0D-0A-1A-0A') { 'image/png' }
            if ($type) {
                Write-StudioBytes $res $type $bytes
                return
            }
        }
    }
    if ($staticFiles.ContainsKey($path)) {
        $file = $staticFiles[$path]
        $filename = Join-Path $PSScriptRoot $file[0]
        if ([IO.File]::Exists($filename)) {
            Write-StudioBytes $res $file[1] ([IO.File]::ReadAllBytes($filename))
            return
        }
    }
    Write-StudioText $res 'text/plain' 'File not found.' 404
}

# Explicit routes keep local source, backups and user files outside the web root.
$staticFiles = @{
    '/' = @('index.html','text/html; charset=utf-8')
    '/index.html' = @('index.html','text/html; charset=utf-8')
    '/app.js' = @('app.js','text/javascript; charset=utf-8')
    '/timeline-edit.js' = @('timeline-edit.js','text/javascript; charset=utf-8')
    '/lane-reorder.js' = @('lane-reorder.js','text/javascript; charset=utf-8')
    '/model.js' = @('model.js','text/javascript; charset=utf-8')
    '/dialogs.js' = @('dialogs.js','text/javascript; charset=utf-8')
    '/usb-playback.js' = @('usb-playback.js','text/javascript; charset=utf-8')
    '/network-playback.js' = @('network-playback.js','text/javascript; charset=utf-8')
    '/board-controls.js' = @('board-controls.js','text/javascript; charset=utf-8')
    '/board-controls.css' = @('board-controls.css','text/css; charset=utf-8')
    '/player-management.js' = @('player-management.js','text/javascript; charset=utf-8')
    '/player-management.css' = @('player-management.css','text/css; charset=utf-8')
    '/network-batch.js' = @('network-batch.js','text/javascript; charset=utf-8')
    '/network-batch.css' = @('network-batch.css','text/css; charset=utf-8')
    '/bulk-controls.js' = @('bulk-controls.js','text/javascript; charset=utf-8')
    '/bulk-controls.css' = @('bulk-controls.css','text/css; charset=utf-8')
    '/settings.js' = @('settings.js','text/javascript; charset=utf-8')
    '/settings.css' = @('settings.css','text/css; charset=utf-8')
    '/theme.js' = @('theme.js','text/javascript; charset=utf-8')
    '/theme.css' = @('theme.css','text/css; charset=utf-8')
    '/solution-viewer.js' = @('solution-viewer.js','text/javascript; charset=utf-8')
    '/cue-dialogs.js' = @('cue-dialogs.js','text/javascript; charset=utf-8')
    '/media-import.js' = @('media-import.js','text/javascript; charset=utf-8')
    '/style.css' = @('style.css','text/css; charset=utf-8')
    '/favicon.svg' = @('favicon.svg','image/svg+xml')
}

# Reopening the launcher should return to the same browser origin and drafts.
# Only reuse a service presenting the marker for this user and workspace.
$sid = if ($studioIsMac) { [Environment]::UserName+'|'+[Environment]::GetFolderPath('UserProfile') } else { [Security.Principal.WindowsIdentity]::GetCurrent().User.Value }
$hash = [Security.Cryptography.SHA256]::Create()
try { $marker = $hash.ComputeHash([Text.Encoding]::UTF8.GetBytes("$sid|$($PSScriptRoot.ToLowerInvariant())")) }
finally { $hash.Dispose() }
$instanceId = 'viplex-schedule-studio/' + [Convert]::ToBase64String($marker)
$tokenBytes = [byte[]]::new(32)
$random = [Security.Cryptography.RandomNumberGenerator]::Create()
try { $random.GetBytes($tokenBytes) } finally { $random.Dispose() }
$exportToken = [Convert]::ToBase64String($tokenBytes)
$listener = New-Object Net.HttpListener
$listener.Prefixes.Add("$origin/")
try {
    $integration = Join-Path $PSScriptRoot 'Viplex.ps1'
    if ([IO.File]::Exists($integration)) { . $integration }
    try { $listener.Start() }
    catch {
        $sameInstance = $false
        try {
            $probe = [Net.HttpWebRequest]::Create("$origin/api/health")
            $probe.Timeout = 1500
            $probe.Proxy = $null
            $probe.AllowAutoRedirect = $false
            $result = $probe.GetResponse()
            try {
                $reader = [IO.StreamReader]::new($result.GetResponseStream())
                try { $sameInstance = ($reader.ReadLine() -ceq $instanceId) } finally { $reader.Dispose() }
            } finally { $result.Dispose() }
        } catch { $sameInstance = $false }
        if (-not $sameInstance) { throw "Studio could not open its local port ($Port). Close the program using that port and try again." }
        Open-StudioWindow
        return
    }
    Open-StudioWindow
    $pendingContext=$listener.GetContextAsync()
    while ($listener.IsListening) {
        if(-not $pendingContext.Wait(500)) {
            # Continue queued uploads even when every browser window is closed.
            try {Update-StudioNetworkJobs} catch {Write-Warning ('Background network status: '+$_.Exception.Message)}
            continue
        }
        $context = $pendingContext.GetAwaiter().GetResult()
        $streaming = $false
        try { Invoke-StudioRequest $context ([ref]$streaming) }
        catch {
            Write-Warning $_.Exception.Message
            try { Write-StudioText $context.Response 'text/plain' 'Studio could not complete this request.' 500 } catch {}
        } finally { if (-not $streaming) { $context.Response.Close() } }
        $pendingContext=$listener.GetContextAsync()
    }
} catch {
    if ($NoBrowser -or $studioIsMac) { throw }
    Add-Type -AssemblyName System.Windows.Forms
    [void][Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Schedule Studio')
} finally { $listener.Close() }
