# Read the user's authored schedules. Studio owns its own project and never
# updates these records. ViPlex uses a separate, numbered playlist relation
# for each row, including rows for items that have not been scheduled.
. (Join-Path $PSScriptRoot 'ViplexExport.ps1')
$playlistModule = Join-Path $PSScriptRoot 'NativePlaylist.ps1'
if ([IO.File]::Exists($playlistModule)) { . $playlistModule }

function Read-ViplexScheduleRows([string]$Database) {
    $query = @'
WITH schedule_names AS (
  SELECT DISTINCT name, replace(replace(replace(name, ' ', ''), '-', ''), '_', '') AS normalized
  FROM nova_schedule_constraint WHERE coalesce(isdelete, 0)=0
), relation_names AS (
  SELECT DISTINCT scheduleName, replace(replace(replace(scheduleName, ' ', ''), '-', ''), '_', '') AS normalized
  FROM nova_relation_schedule2playlist
), unique_names AS (
  SELECT normalized, min(scheduleName) AS scheduleName FROM relation_names GROUP BY normalized HAVING count(*)=1
), bindings AS (
  SELECT n.name, coalesce(exact.scheduleName, u.scheduleName) AS relationName FROM schedule_names n
  LEFT JOIN relation_names exact ON exact.scheduleName=n.name
  LEFT JOIN unique_names u ON u.normalized=n.normalized AND n.normalized IN
    (SELECT normalized FROM schedule_names GROUP BY normalized HAVING count(*)=1)
), links AS (
  SELECT scheduleName, scheduleuuid, playlistuuid FROM nova_relation_schedule2playlist
  GROUP BY scheduleName, scheduleuuid HAVING count(DISTINCT hex(playlistuuid))=1
), unique_solutions AS (
  SELECT name, width, height, uuid FROM nova_playlist WHERE coalesce(isdelete,0)=0
  GROUP BY name, width, height HAVING count(*)=1
)
SELECT s.name AS scheduleName, s.width, s.height, s.desktop_updateTime AS modified,
       hex(s.uuid) AS cueKey, hex(coalesce(p.uuid, named.uuid)) AS playlistKey,
       CASE WHEN p.uuid IS NULL AND named.uuid IS NOT NULL THEN 1 ELSE 0 END AS relinked,
       s.constraintStartTime AS beginValue, s.constraintEndTime AS endValue,
       s.constrainCron AS weekdays, s.constraintPriority AS priority
FROM nova_schedule_constraint AS s
LEFT JOIN bindings b ON b.name=s.name
LEFT JOIN links r ON r.scheduleName=b.relationName AND r.scheduleuuid=s.reservedField1
LEFT JOIN nova_playlist p ON p.uuid=r.playlistuuid AND coalesce(p.isdelete,0)=0
LEFT JOIN unique_solutions named ON p.uuid IS NULL AND r.playlistuuid IS NOT NULL
  AND named.name=s.constraintName AND named.width=s.width AND named.height=s.height
WHERE coalesce(s.isdelete, 0) = 0 AND length(s.name) > 0
ORDER BY s.desktop_updateTime DESC, s.name, CAST(s.constraintPriority AS INTEGER)
'@
    foreach ($row in (Read-StudioRows $Database $query)) {
        $row | Add-Member -NotePropertyName playlistId -NotePropertyValue (ConvertTo-StudioGuid $row.playlistKey)
        $row
    }
}

# Published single solutions have an unnumbered schedule_constraint.json.
# A named schedule has a numbered constraint file and a relation that maps
# each constraint to a playlist. Prefer the newest complete snapshot per name.
function Read-ViplexSnapshotSchedules([string]$ConfigRoot) {
    $folder = Join-Path $ConfigRoot 'Publish'
    if (-not [IO.Directory]::Exists($folder)) { return }
    $seen = @{}
    $directories = Get-ChildItem -LiteralPath $folder -Directory | Where-Object Name -Match '^\d+$' | Sort-Object LastWriteTimeUtc -Descending
    foreach ($dir in $directories) {
        if (-not [IO.File]::Exists((Join-Path $dir.FullName 'schedule_constraint0.json'))) { continue }
        try {
            $plan = [IO.File]::ReadAllText((Join-Path $dir.FullName 'planlist.json')) | ConvertFrom-Json -ErrorAction Stop
            if (-not $plan.name -or $seen.ContainsKey($plan.name)) { continue }
            $relations = [IO.File]::ReadAllText((Join-Path $dir.FullName 'playSolutionRelation.json')) | ConvertFrom-Json -ErrorAction Stop
            $lists = @{}
            foreach ($list in $plan.playlists) {
                if ($list.fileName -notmatch '^playlist\d+\.json$') { throw 'Unknown playlist file' }
                $lists[$list.fileName] = [IO.File]::ReadAllText((Join-Path $dir.FullName $list.fileName)) | ConvertFrom-Json -ErrorAction Stop
            }
            $rules = @{}
            foreach ($entry in $plan.scheduleConstraints) {
                if ($entry.fileName -notmatch '^schedule_constraint\d+\.json$') { throw 'Unknown constraint file' }
                $file = [IO.File]::ReadAllText((Join-Path $dir.FullName $entry.fileName)) | ConvertFrom-Json -ErrorAction Stop
                foreach ($rule in $file.constraints) { $rules["$($entry.fileName)/$($rule.id)"] = $rule }
            }
            $rows = @(foreach ($relation in $relations.relations) {
                foreach ($reference in $relation.scheduleConstraints) {
                    $key = "$($reference.constraintSource)/$($reference.constraintId)"
                    $rule = $rules[$key]
                    if ($reference.playlists.Count -eq 0 -and $rule.startTime -like '1640-02-01T*' -and $rule.endTime -like '1791-02-01T*') {
                        continue
                    }
                    $list = $lists[$reference.playlists[0].playlistSource]
                    if (-not $list -or -not $rule -or $reference.playlists.Count -ne 1) { throw 'Invalid schedule relation' }
                    [pscustomobject]@{
                        scheduleName = $plan.name; width = $list.width; height = $list.height
                        modified = $dir.LastWriteTime.ToString('s'); cueKey = $key; playlistId = $list.uuid
                        beginValue = $rule.startTime; endValue = $rule.endTime; weekdays = $rule.cron; priority = $rule.priority
                    }
                }
            })
            $seen[$plan.name] = $true
            $rows
        } catch { continue }
    }
}

function Get-ViplexClock([string]$Value, [switch]$End) {
    # ViPlex stores local wall time followed by Z and a numeric offset. Keep
    # the wall time as authored. Its end second is inclusive; Studio's isn't.
    if ($Value -notmatch '^(\d{4}-\d\d-\d\d)T(\d\d):(\d\d):(\d\d)(?:Z|$)') { throw 'Invalid native timestamp' }
    $date = [datetime]::ParseExact($Matches[1], 'yyyy-MM-dd', [cultureinfo]::InvariantCulture)
    $hour = [int]$Matches[2]; $minute = [int]$Matches[3]; $second = [int]$Matches[4]
    if ($hour -gt 24 -or $minute -gt 59 -or $second -gt 59 -or ($hour -eq 24 -and (-not $End -or $minute -or $second))) { throw 'Invalid native time' }
    $seconds = 3600 * $hour + 60 * $minute + $second
    if ($End -and $hour -ne 24) { $seconds++ }
    $nearest = [int][math]::Round($seconds / 60, [MidpointRounding]::AwayFromZero)
    [pscustomobject]@{ date=$date; minute=$nearest; rounded=($seconds % 60 -ne 0) }
}

function Get-ViplexDays($Weekdays) {
    $rules = if ($Weekdays -is [string] -and $Weekdays.StartsWith('[')) { ConvertFrom-Json -InputObject $Weekdays -ErrorAction Stop } else { $Weekdays }
    $days = @(foreach ($rule in $rules) {
        if ($rule -notmatch '^0 0 0 \? \* (\*|[1-7](?:,[1-7])*)$') { throw 'Unsupported native recurrence' }
        if ($Matches[1] -eq '*') { 0..6 } else { foreach ($n in $Matches[1].Split(',')) { [int]$n - 1 } }
    })
    if ($days.Count -eq 0) { throw 'Missing native recurrence' }
    $days | Sort-Object -Unique
}

function Format-ViplexMinute([int]$Minute) {
    '{0:D2}:{1:D2}' -f [int][math]::Floor($Minute / 60), ($Minute % 60)
}

# Split native priority overlays into the actual playback intervals. Date
# boundaries allow a dated override to start and expire without disturbing a
# recurring base schedule. Weekly intervals with the same source are grouped.
function ConvertTo-ViplexTimeline($Slots, $Warnings) {
    if (-not $Slots.Count) { return }
    $bounds = @(foreach ($slot in $Slots) {
        $slot.from
        if ($slot.until -lt [datetime]'9999-12-31') { $slot.until.AddDays(1) }
    }) | Sort-Object -Unique
    $bounds = @($bounds)
    for ($i = 0; $i -lt $bounds.Count; $i++) {
        $from = $bounds[$i]
        $until = if ($i + 1 -lt $bounds.Count) { $bounds[$i+1].AddDays(-1) } else { [datetime]'9999-12-31' }
        $candidates = @($Slots | Where-Object { $_.from -le $from -and $_.until -ge $from } | Sort-Object priority -Descending)
        if (-not $candidates.Count) { continue }
        $groups = [ordered]@{}
        foreach ($day in 0..6) {
            $offset = ($day - [int]$from.DayOfWeek + 7) % 7
            if (($until - $from).Days -lt $offset) { continue }
            $active = @($candidates | Where-Object { $_.days -contains $day })
            $times = @(foreach ($slot in $active) { $slot.begin; $slot.end }) | Sort-Object -Unique
            $times = @($times)
            $intervals = [Collections.ArrayList]::new()
            for ($n = 0; $n -lt $times.Count - 1; $n++) {
                $a = $times[$n]; $b = $times[$n+1]
                $matchesAtTime = @($active | Where-Object { $_.begin -le $a -and $_.end -gt $a })
                if (-not $matchesAtTime.Count) { continue }
                if ($matchesAtTime.Count -gt 1) { $Warnings['overlap'] = 'Overlapping ViPlex rules are shown in native priority order.' }
                $winner = $matchesAtTime[0]
                if ($intervals.Count -and $intervals[-1].slot -eq $winner -and $intervals[-1].b -eq $a) { $intervals[-1].b = $b }
                else { [void]$intervals.Add(@{slot=$winner; a=$a; b=$b}) }
            }
            foreach ($period in $intervals) {
                $key = "$($period.slot.key)/$($period.a)/$($period.b)"
                if (-not $groups.Contains($key)) {
                    $groups[$key] = [pscustomobject]@{
                        solutionId=$period.slot.solutionId; startDate=$from.ToString('yyyy-MM-dd')
                        endDate=$(if ($until -eq [datetime]'9999-12-31') { '' } else { $until.ToString('yyyy-MM-dd') })
                        start=(Format-ViplexMinute $period.a); end=(Format-ViplexMinute $period.b)
                        days=[Collections.ArrayList]::new(); source=$period.slot.source
                    }
                }
                [void]$groups[$key].days.Add($day)
            }
        }
        $groups.Values
    }
}

function Get-ViplexSchedules([string]$ConfigRoot, $Solutions) {
    $db = Join-Path $ConfigRoot 'DB.SQLite'
    $snapshotOnly = $false
    $rows = if ([IO.File]::Exists($db)) {
        try { Read-ViplexScheduleRows $db }
        catch {
            $snapshotOnly = $true
            $fallback = @(Read-ViplexSnapshotSchedules $ConfigRoot)
            if (-not $fallback.Count) { throw }
            $fallback
        }
    } else {
        $snapshotOnly = $true
        Read-ViplexSnapshotSchedules $ConfigRoot
    }
    $solutionIds = @{}
    foreach ($solution in $Solutions) { $solutionIds[$solution.id] = $true }
    $schedules = foreach ($group in ($rows | Group-Object scheduleName)) {
        $warnings = [ordered]@{}
        if ($snapshotOnly) { $warnings['snapshot'] = 'Loaded from the most recent available ViPlex publish snapshot.' }
        $entries = @(foreach ($row in $group.Group) {
            # ViPlex creates a dormant, centuries-old row when a solution is
            # added to a schedule's library, even before it gets a time slot.
            if ($row.beginValue -like '1640-02-01T*' -and $row.endValue -like '1791-02-01T*') { continue }
            try {
                $begin = Get-ViplexClock $row.beginValue
                $end = Get-ViplexClock $row.endValue -End
                $solutionId = "viplex-$($row.playlistId)"
                if (-not $solutionIds.ContainsKey($solutionId)) { throw 'An active rule references an unavailable solution' }
                if ($row.relinked) { $warnings['relinked'] = 'ViPlex changed a solution ID. Studio matched its current name and resolution.' }
                $days = @(Get-ViplexDays $row.weekdays)
                $last = if ($end.date -eq [datetime]'4012-01-01') { [datetime]'9999-12-31' } else { $end.date }
                if ($begin.date -gt $last -or $begin.minute -eq $end.minute -or $begin.minute -eq 1440) { throw 'Invalid range' }
                if ($begin.rounded -or $end.rounded) { $warnings['seconds'] = 'Sub-minute times are rounded to the nearest minute.' }
                $source = [ordered]@{ nativeRule=$row.cueKey; priority=[long]$row.priority; startTime=$row.beginValue; endTime=$row.endValue }
                $wrap = $begin.minute -gt $end.minute
                [pscustomobject]@{
                    key=$row.cueKey; solutionId=$solutionId; priority=$source.priority; source=$source
                    from=$begin.date; until=$last; days=$days; begin=$begin.minute; end=$(if ($wrap) { 1440 } else { $end.minute })
                }
                if ($wrap -and $end.minute -gt 0) {
                    [pscustomobject]@{
                        key=$row.cueKey; solutionId=$solutionId; priority=$source.priority; source=$source
                        from=$begin.date.AddDays(1); until=$(if ($last.Year -eq 9999) { $last } else { $last.AddDays(1) })
                        days=@(foreach ($day in $days) { ($day + 1) % 7 }); begin=0; end=$end.minute
                    }
                }
            } catch { $warnings['unavailable'] = 'Some native rules could not be imported. Check this schedule in ViPlex.' }
        })
        $cues = @(ConvertTo-ViplexTimeline $entries $warnings)
        $first = $group.Group[0]
        $id = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($group.Name)).TrimEnd('=').Replace('/','_').Replace('+','-')
        if ($first.width -le 0 -or $first.height -le 0) { continue }
        [pscustomobject]@{
            id="viplex-schedule-$id"; name=$group.Name; width=[int]$first.width; height=[int]$first.height
            updatedAt=([string]$first.modified).Replace(' ','T'); cues=$cues; warning=($warnings.Values -join ' ')
        }
    }
    $schedules | Sort-Object updatedAt -Descending
}
