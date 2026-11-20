function Test-StudioProject($Project) {
    return ($Project -is [pscustomobject] -and $Project.version -eq 1 -and
            $Project.screens -is [array] -and $Project.solutions -is [array] -and $Project.cues -is [array])
}

function Get-StudioRevision([byte[]]$Bytes) {
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return [BitConverter]::ToString($sha.ComputeHash($Bytes)).Replace('-','').ToLowerInvariant() }
    finally { $sha.Dispose() }
}

function Read-StudioProjectFile([string]$Path) {
    # Allow another listener to atomically rename the file while a reader
    # finishes reading this particular version.
    $sharing = [IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete
    $file = [IO.File]::Open($Path,[IO.FileMode]::Open,[IO.FileAccess]::Read,$sharing)
    $memory = [IO.MemoryStream]::new()
    try { $file.CopyTo($memory); $bytes = $memory.ToArray() }
    finally { $memory.Dispose(); $file.Dispose() }
    try {
        $json = [Text.UTF8Encoding]::new($false,$true).GetString($bytes).TrimStart([char]0xFEFF)
        $project = ConvertFrom-Json -InputObject $json -ErrorAction Stop
        if (-not (Test-StudioProject $project)) { throw 'Invalid or unsupported Studio project.' }
    } catch {
        throw [IO.InvalidDataException]::new("Studio could not read the project format in '$Path'.", $_.Exception)
    }
    return @{revision=(Get-StudioRevision $bytes); project=$project; recovered=$false}
}

function Get-StudioProject([string]$Path) {
    $backup = "$Path.bak"
    if ([IO.File]::Exists($Path)) {
        try { return Read-StudioProjectFile $Path }
        catch [IO.InvalidDataException] { if (-not [IO.File]::Exists($backup)) { throw } }
    }
    if ([IO.File]::Exists($backup)) {
        $state = Read-StudioProjectFile $backup
        $state.recovered = $true
        return $state
    }
    return @{revision=$null; project=$null; recovered=$false}
}

function Write-StudioProject([string]$Path, $BaseRevision, $Project) {
    $current = Get-StudioProject $Path
    if ($BaseRevision -cne $current.revision) {
        return @{conflict=$true; revision=$current.revision}
    }
    $text = ConvertTo-Json -InputObject $Project -Depth 100 -Compress
    $bytes = [Text.UTF8Encoding]::new($false).GetBytes($text)
    $revision = Get-StudioRevision $bytes
    if ($revision -ceq $current.revision -and -not $current.recovered) {
        return @{conflict=$false; revision=$revision}
    }
    $directory = [IO.Path]::GetDirectoryName($Path)
    [void][IO.Directory]::CreateDirectory($directory)
    $temp = Join-Path $directory ('workspace-' + [guid]::NewGuid().ToString('N') + '.tmp')
    try {
        $stream = [IO.FileStream]::new($temp, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        try { $stream.Write($bytes,0,$bytes.Length); $stream.Flush($true) } finally { $stream.Dispose() }
        if ([IO.File]::Exists($Path)) {
            if ($current.recovered) {
                # Keep the good backup when replacing a damaged primary.
                [IO.File]::Replace($temp, $Path, [Management.Automation.Language.NullString]::Value)
            } else { [IO.File]::Replace($temp, $Path, "$Path.bak") }
        } else { [IO.File]::Move($temp, $Path) }
    } finally { if ([IO.File]::Exists($temp)) { [IO.File]::Delete($temp) } }
    return @{conflict=$false; revision=$revision}
}

function Save-StudioProject([string]$Path, $BaseRevision, $Project) {
    # Alternate local listeners can point at the same directory. Hold the
    # revision check and replacement together across Windows processes.
    $key = Get-StudioRevision ([Text.Encoding]::UTF8.GetBytes([IO.Path]::GetFullPath($Path).ToUpperInvariant()))
    $mutex = [Threading.Mutex]::new($false, "Local\RelayStudioProject-$key")
    $acquired = $false
    try {
        try { $acquired = $mutex.WaitOne(5000) }
        catch [Threading.AbandonedMutexException] { $acquired = $true }
        if (-not $acquired) { throw 'The workspace is busy. Try saving again.' }
        return Write-StudioProject $Path $BaseRevision $Project
    } finally {
        if ($acquired) { $mutex.ReleaseMutex() }
        $mutex.Dispose()
    }
}
