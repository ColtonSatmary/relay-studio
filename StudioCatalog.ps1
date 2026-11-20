# ViPlex keeps editable solutions in SQLite. Use Windows' bundled SQLite in
# read-only mode so the original application can continue to edit its library.
function Initialize-StudioSqlite {
    if ('StudioSqlite' -as [type]) { return }
    $source=@'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;

public static class StudioSqlite {
    private const string Dll = "winsqlite3.dll";
    [DllImport(Dll, CallingConvention=CallingConvention.Cdecl)]
    static extern int sqlite3_open_v2(byte[] file, out IntPtr db, int flags, IntPtr vfs);
    [DllImport(Dll, CallingConvention=CallingConvention.Cdecl)]
    static extern int sqlite3_close(IntPtr db);
    [DllImport(Dll, CallingConvention=CallingConvention.Cdecl)]
    static extern int sqlite3_busy_timeout(IntPtr db, int milliseconds);
    [DllImport(Dll, CallingConvention=CallingConvention.Cdecl, CharSet=CharSet.Unicode)]
    static extern int sqlite3_prepare16_v2(IntPtr db, string sql, int bytes, out IntPtr stmt, IntPtr tail);
    [DllImport(Dll, CallingConvention=CallingConvention.Cdecl)]
    static extern int sqlite3_finalize(IntPtr stmt);
    [DllImport(Dll, CallingConvention=CallingConvention.Cdecl)]
    static extern int sqlite3_step(IntPtr stmt);
    [DllImport(Dll, CallingConvention=CallingConvention.Cdecl)]
    static extern int sqlite3_column_count(IntPtr stmt);
    [DllImport(Dll, CallingConvention=CallingConvention.Cdecl)]
    static extern IntPtr sqlite3_column_name16(IntPtr stmt, int column);
    [DllImport(Dll, CallingConvention=CallingConvention.Cdecl)]
    static extern int sqlite3_column_type(IntPtr stmt, int column);
    [DllImport(Dll, CallingConvention=CallingConvention.Cdecl)]
    static extern long sqlite3_column_int64(IntPtr stmt, int column);
    [DllImport(Dll, CallingConvention=CallingConvention.Cdecl)]
    static extern double sqlite3_column_double(IntPtr stmt, int column);
    [DllImport(Dll, CallingConvention=CallingConvention.Cdecl)]
    static extern IntPtr sqlite3_column_text16(IntPtr stmt, int column);
    [DllImport(Dll, CallingConvention=CallingConvention.Cdecl)]
    static extern IntPtr sqlite3_column_blob(IntPtr stmt, int column);
    [DllImport(Dll, CallingConvention=CallingConvention.Cdecl)]
    static extern int sqlite3_column_bytes(IntPtr stmt, int column);
    [DllImport(Dll, CallingConvention=CallingConvention.Cdecl)]
    static extern IntPtr sqlite3_errmsg16(IntPtr db);

    static object Value(IntPtr stmt, int index) {
        switch (sqlite3_column_type(stmt, index)) {
            case 1: return sqlite3_column_int64(stmt, index);
            case 2: return sqlite3_column_double(stmt, index);
            case 3: return Marshal.PtrToStringUni(sqlite3_column_text16(stmt, index));
            case 4:
                var bytes = new byte[sqlite3_column_bytes(stmt, index)];
                if (bytes.Length > 0) Marshal.Copy(sqlite3_column_blob(stmt, index), bytes, 0, bytes.Length);
                return BitConverter.ToString(bytes).Replace("-", "");
            default: return null;
        }
    }

    public static List<Dictionary<string, object>> Read(string path, string query) {
        IntPtr db = IntPtr.Zero, stmt = IntPtr.Zero;
        var rows = new List<Dictionary<string, object>>();
        try {
            // SQLITE_OPEN_READONLY is 1.
            if (sqlite3_open_v2(Encoding.UTF8.GetBytes(path + "\0"), out db, 1, IntPtr.Zero) != 0)
                throw new InvalidOperationException("Could not open the ViPlex catalog for reading.");
            sqlite3_busy_timeout(db, 1500);
            if (sqlite3_prepare16_v2(db, query, -1, out stmt, IntPtr.Zero) != 0)
                throw new InvalidOperationException(Marshal.PtrToStringUni(sqlite3_errmsg16(db)));
            int result;
            while ((result = sqlite3_step(stmt)) == 100) {
                var row = new Dictionary<string, object>(StringComparer.OrdinalIgnoreCase);
                for (int i = 0; i < sqlite3_column_count(stmt); i++)
                    row[Marshal.PtrToStringUni(sqlite3_column_name16(stmt, i))] = Value(stmt, i);
                rows.Add(row);
            }
            if (result != 101) throw new InvalidOperationException(Marshal.PtrToStringUni(sqlite3_errmsg16(db)));
            return rows;
        } finally {
            if (stmt != IntPtr.Zero) sqlite3_finalize(stmt);
            if (db != IntPtr.Zero) sqlite3_close(db);
        }
    }
}
'@
    if ([Environment]::OSVersion.Platform -eq [PlatformID]::Unix) { $source=$source.Replace('winsqlite3.dll','/usr/lib/libsqlite3.dylib') }
    Add-Type -TypeDefinition $source
}

function Read-StudioRows([string]$Database, [string]$Query) {
    Initialize-StudioSqlite
    foreach ($row in [StudioSqlite]::Read($Database, $Query)) {
        $record = [ordered]@{}
        foreach ($item in $row.GetEnumerator()) { $record[$item.Key] = $item.Value }
        [pscustomobject]$record
    }
}

function ConvertTo-StudioGuid([string]$Hex) {
    if ($Hex -match '^[a-f0-9]{8}(-[a-f0-9]{4}){3}-[a-f0-9]{12}$') { return ([guid]$Hex).ToString('D') }
    if ($Hex -notmatch '^[0-9a-fA-F]{32}$') { return $null }
    $bytes = [byte[]]::new(16)
    for ($i = 0; $i -lt 16; $i++) { $bytes[$i] = [Convert]::ToByte($Hex.Substring($i * 2, 2), 16) }
    return [Guid]::new($bytes).ToString('D')
}

function Get-StudioSnapshots([string]$ConfigRoot) {
    $entries = @{}
    $publishRoot = Join-Path $ConfigRoot 'Publish'
    if (-not [IO.Directory]::Exists($publishRoot)) { return $entries }
    $directories = Get-ChildItem -LiteralPath $publishRoot -Directory | Where-Object { $_.Name -match '^\d+$' } | Sort-Object LastWriteTimeUtc -Descending
    foreach ($dir in $directories) {
        foreach ($file in $dir.EnumerateFiles('playlist*.json')) {
            if ($file.Name -notmatch '^playlist\d+\.json$') { continue }
            try {
                $list = [IO.File]::ReadAllText($file.FullName) | ConvertFrom-Json -ErrorAction Stop
                $uuid = ([guid]$list.uuid).ToString('D')
                if ($list.name -and -not $entries.ContainsKey($uuid)) {
                    $scenes = @($list.sceneItems)
                    $containers = @($scenes[0].page.widgetContainers)
                    $widgets = @($containers[0].contents.widgets)
                    $fingerprint = $null
                    if ($scenes.Count -eq 1 -and $containers.Count -eq 1 -and $widgets.Count -eq 1 -and
                        $widgets[0].type -eq 'VIDEO' -and $widgets[0].dataSource -match '^([0-9a-f]{32})\.[a-z0-9]+$') { $fingerprint = $Matches[1].ToLowerInvariant() }
                    $entries[$uuid] = [pscustomobject]@{
                        name=$list.name; width=$list.width; height=$list.height; uuid=$uuid
                        thumbpath=$list.thumbpath; snapshot=$dir.Name; playlist=$file.Name
                        modified=$file.LastWriteTime.ToString('s'); fingerprint=$fingerprint
                    }
                }
            } catch { continue }  # A snapshot may still be in the process of publishing.
        }
    }
    return $entries
}

function Get-StudioCatalog([string]$ConfigRoot) {
    $snapshotIndex = Get-StudioSnapshots $ConfigRoot
    $database = Join-Path $ConfigRoot 'DB.SQLite'
    $fromDatabase = $false
    $messages = @()
    if ([IO.File]::Exists($database)) {
        try {
            $rows = @(Read-StudioRows $database 'SELECT uuid AS identifier, name, width, height, thumbpath, desktop_updateTime AS modified FROM nova_playlist WHERE coalesce(isdelete, 0) = 0 ORDER BY name COLLATE NOCASE')
            $fromDatabase = $true
        } catch { $messages += 'The editable ViPlex library could not be read. Available publish snapshots are shown.' }
    }
    if (-not $fromDatabase) { $rows = @($snapshotIndex.Values | Sort-Object name) }
    $fingerprints = @{}
    if ($fromDatabase) {
        # Only a single full-screen video with an identifiable content hash
        # can safely corroborate the identity of a previous solution.
        $fingerprintSql = @'
SELECT l.uuid AS identifier, w.dataSource AS media
FROM nova_playlist l
JOIN nova_relation_playlist2scene ls ON ls.playlistuuid=l.uuid
JOIN nova_relation_scene2page sp ON sp.sceneuuid=ls.sceneuuid
JOIN nova_relation_page2widget pc ON pc.pageuuid=sp.pageuuid
JOIN nova_relation_widgetContainer2widget cw ON cw.widgetContaineruuid=pc.widgetContaineruuid
JOIN nova_widget w ON w.uuid=cw.widgetuuid AND coalesce(w.isdelete,0)=0
WHERE coalesce(l.isdelete,0)=0
GROUP BY l.uuid HAVING count(*)=1 AND upper(w.type)='VIDEO'
'@
        try {
            foreach ($item in (Read-StudioRows $database $fingerprintSql)) {
                if ($item.media -match '^([0-9a-f]{32})\.[a-z0-9]+$') { $fingerprints[(ConvertTo-StudioGuid $item.identifier)] = $Matches[1].ToLowerInvariant() }
            }
        } catch { Write-Verbose 'Native media fingerprints are unavailable for this library version.' }
    }

    $colors = @('#137d67','#6854ad','#b46327','#3077a6','#a15179','#718242')
    $thumbnailFiles = @{}
    $solutions = @(foreach ($row in $rows) {
        $uuid = if ($fromDatabase) { ConvertTo-StudioGuid $row.identifier } else { $row.uuid }
        if (-not $uuid -or -not $row.name -or $row.width -le 0 -or $row.height -le 0) { continue }
        $id = "viplex-$uuid"
        $snapshot = $snapshotIndex[$uuid]
        $thumbnail = $null
        $filename = if ($row.thumbpath) { [IO.Path]::GetFileName($row.thumbpath) }
        if ($filename -match '^[a-fA-F0-9-]{32,36}\.(png|jpe?g)$') {
            $path = Join-Path $ConfigRoot $filename
            if ([IO.File]::Exists($path)) {
                $thumbnailFiles[$id] = $path
                $thumbnail = "/api/thumbnail/$id"
            }
        }
        [pscustomobject]@{
            id=$id; name=[string]$row.name; width=[int]$row.width; height=[int]$row.height
            color=$colors[([Convert]::ToUInt32($uuid.Substring(0,8),16) % $colors.Length)]
            thumbnail=$thumbnail
            source=[ordered]@{ playlistUuid=$uuid; snapshot=$snapshot.snapshot; playlist=$snapshot.playlist; modified=$row.modified
                mediaFingerprint=$(if ($fromDatabase) { $fingerprints[$uuid] } else { $row.fingerprint }); aliases=@() }
        }
    })
    $schedules = @()
    if (Get-Command Get-ViplexSchedules -CommandType Function -ErrorAction SilentlyContinue) {
        try { $schedules = @(Get-ViplexSchedules -ConfigRoot $ConfigRoot -Solutions $solutions) }
        catch { $messages += 'The ViPlex schedule library could not be read.' }
    }
    if (Get-Command Get-StudioMediaSolutions -CommandType Function -ErrorAction SilentlyContinue) { $solutions += @(Get-StudioMediaSolutions) }
    $currentIds = @{}
    foreach ($solution in $solutions) { $currentIds[$solution.id] = $true }
    foreach ($solution in $solutions) {
        $fingerprint = $solution.source.mediaFingerprint
        if (-not $fingerprint) { continue }
        $solution.source.aliases = @(foreach ($previous in $snapshotIndex.Values) {
            if (-not $currentIds.ContainsKey("viplex-$($previous.uuid)") -and $previous.name -eq $solution.name -and
               $previous.width -eq $solution.width -and $previous.height -eq $solution.height -and $previous.fingerprint -eq $fingerprint) { $previous.uuid }
        })
    }
    return @{
        data=[ordered]@{solutions=$solutions; schedules=$schedules; messages=$messages}
        thumbnails=$thumbnailFiles
    }
}
