# Player control data stays in memory. Only explicitly selected display fields
# are returned to the browser; unknown firmware fields survive configuration edits.

function Get-StudioBoardProperty($Value,[string]$Name) {
    if ($null -eq $Value) { return $null }
    if ($Value -is [Collections.IDictionary]) { return ,$Value[$Name] }
    $property=$Value.PSObject.Properties[$Name]
    if ($null -ne $property) { return ,$property.Value }
    return $null
}

function Set-StudioBoardProperty($Value,[string]$Name,$PropertyValue) {
    if ($Value -is [Collections.IDictionary]) { $Value[$Name]=$PropertyValue }
    else { $Value | Add-Member -NotePropertyName $Name -NotePropertyValue $PropertyValue -Force }
}

function Get-StudioBoardFields($Value) {
    if ($null -eq $Value -or $Value -is [string] -or $Value -is [ValueType] -or $Value -is [array]) {
        throw 'Control values must be an object.'
    }
    if ($Value -is [Collections.IDictionary]) { return @($Value.Keys) }
    return @($Value.PSObject.Properties.Name)
}

function Assert-StudioBoardFields($Value,[string[]]$Allowed) {
    $fields=@(Get-StudioBoardFields $Value)
    if ($fields.Count -eq 0) { throw 'Choose at least one setting to change.' }
    foreach($field in $fields) {
        if ($Allowed -cnotcontains $field) { throw 'This control contains an unsupported setting.' }
    }
    return ,$fields
}

function Get-StudioBoardNumber($Value,[double]$Minimum,[double]$Maximum,[string]$Label,[switch]$Integer) {
    if ($null -eq $Value -or $Value -is [bool] -or $Value -is [string] -or $Value -isnot [ValueType]) {
        throw "$Label must be a number."
    }
    try { $number=[double]$Value } catch { throw "$Label must be a number." }
    if ([double]::IsNaN($number) -or [double]::IsInfinity($number) -or $number -lt $Minimum -or $number -gt $Maximum -or
        ($Integer -and $number -ne [math]::Truncate($number))) { throw "$Label is outside the supported range." }
    return $number
}

function Read-StudioBoardData($Session,[string]$Section) {
    $data=$Session.ReadControl($Section) | ConvertFrom-Json -ErrorAction Stop
    $null=Get-StudioBoardFields $data
    return $data
}

function Test-StudioBoardAutomaticTime($Data) {
    if ((Get-StudioBoardProperty $Data 'enable') -eq $true) { return $true }
    foreach($kind in @('ntp','gps','lora')) {
        if ((Get-StudioBoardProperty (Get-StudioBoardProperty $Data $kind) 'enable') -eq $true) { return $true }
    }
    return $false
}

function Get-StudioBoardTimeZone([string]$Zone,[long]$UtcTimeMillis) {
    if ([Environment]::OSVersion.Platform -eq [PlatformID]::Unix) { return Get-StudioMacBoardTimeZone $Zone $UtcTimeMillis }
    # Use the same pure time-zone database shipped with ViPlex, without loading
    # vendor device/session code. NodaTime also rejects misspelled IANA zone IDs.
    if (-not ('NodaTime.DateTimeZoneProviders' -as [type])) {
        $library=Join-Path ([Environment]::GetFolderPath('ProgramFilesX86')) 'Nova Star\ViPlex Express\Bin\NodaTime.dll'
        if (-not [IO.File]::Exists($library)) { throw 'The installed time-zone database could not be found. Change the time zone in ViPlex.' }
        try { $null=[Reflection.Assembly]::LoadFrom($library) } catch { throw 'The installed time-zone database could not be loaded.' }
    }
    try { $resolved=[NodaTime.DateTimeZoneProviders]::Tzdb[$Zone] }
    catch { throw 'Unknown IANA time zone. Use a zone such as America/Los_Angeles.' }
    if ($null -eq $resolved) { throw 'Unknown IANA time zone. Use a zone such as America/Los_Angeles.' }
    $interval=$resolved.GetZoneInterval([NodaTime.Instant]::FromUnixTimeMilliseconds($UtcTimeMillis))
    $seconds=[int]$interval.StandardOffset.Seconds
    $sign=if ($seconds -lt 0) {'-'} else {'+'}
    $minutes=[int]([math]::Abs($seconds)/60)
    $hours=[int][math]::Floor($minutes/60)
    return @{timeZone=$Zone;gmt=('GTM{0}{1:00}:{2:00}' -f $sign,$hours,($minutes%60))}
}

function ConvertTo-StudioBoardSection([string]$Section,$Data) {
    $value=[ordered]@{}
    switch -CaseSensitive ($Section) {
        'brightness' {
            $value.ratio=Get-StudioBoardProperty $Data 'ratio'
            $value.brightness=Get-StudioBoardProperty $Data 'brightness'
        }
        'colorTemperature' { $value.colorTemperature=Get-StudioBoardProperty $Data 'colorTemperature' }
        'mosaic' {
            $value.enable=Get-StudioBoardProperty $Data 'enable'
            $info=Get-StudioBoardProperty $Data 'info'
            $value.info=[ordered]@{}
            foreach($field in @('direction','mode','totalLength')) { $value.info[$field]=Get-StudioBoardProperty $info $field }
            $config=Get-StudioBoardProperty $info 'spliceHdmiConfig'
            $auto=Get-StudioBoardProperty $config 'autoSpliceHdmiConfig'
            if ($null -eq $auto) { $auto=Get-StudioBoardProperty $config 'autospliceHdmiConfig' }
            $value.maxNum=Get-StudioBoardProperty $auto 'maxNum'
        }
        'time' {
            foreach($field in @('utcTimeMillis','currentTime','timeZone','isTimeOffsetEnable','timeOffsetValue')) {
                $value[$field]=Get-StudioBoardProperty $Data $field
            }
        }
        'ethernet' {
            $value.ethernets=@(foreach($item in (Get-StudioBoardProperty $Data 'ethernets')) {
                $entry=[ordered]@{}
                foreach($field in @('name','scopeId','dhcp','ip','mask','gateWay','dns')) { $entry[$field]=Get-StudioBoardProperty $item $field }
                $entry
            })
        }
        default { throw 'Unsupported player control.' }
    }
    return @{available=$true;value=$value}
}

function Invoke-StudioBoardRead($Session,[string[]]$Sections=@('brightness','colorTemperature','mosaic','time','ethernet','wifi')) {
    $controls=[ordered]@{}
    foreach($section in $Sections | Where-Object {$_ -cne 'wifi'}) {
        try { $controls[$section]=ConvertTo-StudioBoardSection $section (Read-StudioBoardData $Session $section) }
        catch { $controls[$section]=@{available=$false;error='This setting could not be read from the player.'} }
    }
    if ($controls.brightness.available) {
        try { $mode=Read-StudioBoardData $Session 'brightnessMode';$controls.brightness.value.mode=Get-StudioBoardProperty $mode 'mode' }
        catch { $controls.brightness.value.mode=$null }
    }
    if ($controls.time.available) {
        try { $sync=Read-StudioBoardData $Session 'timeSync';$controls.time.automaticSync=Test-StudioBoardAutomaticTime $sync }
        catch { $controls.time.automaticSync=$null }
    }
    if ($Sections -ccontains 'wifi') {
        $wifi=@{available=$false;readOnly=$true;value=@{state=$null;networks=@()}}
        try { $state=Read-StudioBoardData $Session 'wifiState';$wifi.value.state=Get-StudioBoardProperty $state 'state';$wifi.available=$true } catch { }
        try {
            $networks=Read-StudioBoardData $Session 'wifiNetworks'
            $wifi.value.networks=@(foreach($network in (Get-StudioBoardProperty $networks 'result')) {
                $entry=[ordered]@{}
                foreach($field in @('ssid','bssid','frequency','level','security','state')) { $entry[$field]=Get-StudioBoardProperty $network $field }
                $entry
            })
            $wifi.available=$true
        } catch { }
        if (-not $wifi.available) { $wifi.error='Wi-Fi status could not be read from the player.' }
        $controls.wifi=$wifi
    }
    return $controls
}

function Get-StudioBoardIPv4([string]$Value,[string]$Label,[switch]$AllowZero,[switch]$Mask) {
    if ($Value -cnotmatch '^(?:0|[1-9][0-9]{0,2})(?:\.(?:0|[1-9][0-9]{0,2})){3}$') { throw "$Label must be an IPv4 address." }
    $address=$null
    if (-not [Net.IPAddress]::TryParse($Value,[ref]$address)) { throw "$Label must be an IPv4 address." }
    $bytes=$address.GetAddressBytes()
    $number=([uint64]$bytes[0]*16777216)+([uint64]$bytes[1]*65536)+([uint64]$bytes[2]*256)+[uint64]$bytes[3]
    if ($Mask) {
        $inverse=4294967295L - $number
        if ($number -eq 0 -or $inverse -lt 3 -or (($inverse -band ($inverse+1)) -ne 0)) { throw 'Subnet mask must be a contiguous IPv4 mask.' }
    } elseif (-not ($AllowZero -and $number -eq 0)) {
        if ($bytes[0] -eq 0 -or $bytes[0] -eq 127 -or $bytes[0] -ge 224) { throw "$Label must be a unicast IPv4 address." }
    }
    return $number
}

function Edit-StudioBoardEthernet($Original,$Values) {
    $null=Assert-StudioBoardFields $Values @('ethernets')
    $edits=Get-StudioBoardProperty $Values 'ethernets'
    if ($edits -isnot [array] -or $edits.Count -eq 0 -or $edits.Count -gt 16) { throw 'Choose one or more existing Ethernet interfaces.' }
    $existing=Get-StudioBoardProperty $Original 'ethernets'
    $seen=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach($edit in $edits) {
        $fields=Assert-StudioBoardFields $edit @('name','scopeId','dhcp','ip','mask','gateWay','dns')
        $name=Get-StudioBoardProperty $edit 'name'
        if ($name -isnot [string] -or -not $seen.Add($name)) { throw 'Choose each Ethernet interface only once.' }
        $matches=@($existing | Where-Object { (Get-StudioBoardProperty $_ 'name') -ceq $name })
        if ($matches.Count -ne 1) { throw 'The Ethernet interface has changed. Refresh before applying settings.' }
        $target=$matches[0]
        if ($fields -ccontains 'scopeId') {
            $scope=Get-StudioBoardNumber (Get-StudioBoardProperty $edit 'scopeId') -1 2147483647 'Interface identity' -Integer
            if ($scope -ne (Get-StudioBoardProperty $target 'scopeId')) { throw 'The Ethernet interface identity has changed.' }
        }
        foreach($field in $fields | Where-Object { $_ -cnotin @('name','scopeId') }) {
            $v=Get-StudioBoardProperty $edit $field
            if ($field -eq 'dhcp') { if ($v -isnot [bool]) { throw 'DHCP must be enabled or disabled.' } }
            elseif ($field -eq 'dns') {
                if ($v -isnot [array] -or $v.Count -lt 1 -or $v.Count -gt 3) { throw 'Enter one to three IPv4 DNS servers.' }
                foreach($dns in $v) { if ($dns -isnot [string]) { throw 'DNS server must be an IPv4 address.' };$null=Get-StudioBoardIPv4 $dns 'DNS server' -AllowZero }
            } else {
                if ($v -isnot [string]) { throw 'Network addresses must be strings.' }
                $null=Get-StudioBoardIPv4 $v $field -AllowZero:($field -eq 'gateWay') -Mask:($field -eq 'mask')
            }
            Set-StudioBoardProperty $target $field $v
        }
        if ((Get-StudioBoardProperty $target 'dhcp') -ne $true) {
            $ip=Get-StudioBoardIPv4 (Get-StudioBoardProperty $target 'ip') 'IP address'
            $mask=Get-StudioBoardIPv4 (Get-StudioBoardProperty $target 'mask') 'Subnet mask' -Mask
            $gateway=Get-StudioBoardIPv4 (Get-StudioBoardProperty $target 'gateWay') 'Gateway' -AllowZero
            $hostPart=$ip -band (4294967295L - $mask)
            if ($hostPart -eq 0 -or $hostPart -eq (4294967295L - $mask)) { throw 'IP address cannot be the subnet or broadcast address.' }
            if ($gateway -ne 0 -and (($ip -band $mask) -ne ($gateway -band $mask))) { throw 'Gateway must be on the same subnet as the player.' }
        }
    }
    return $Original
}

function Invoke-StudioBoardApply($Session,[string]$Section,$Values) {
    if ($Section -cnotin @('brightness','colorTemperature','mosaic','time','ethernet')) { throw 'This setting is read-only or unsupported.' }
    # Read from the player, never trust a browser-supplied original configuration.
    try { $original=Read-StudioBoardData $Session $Section } catch { throw 'Read the current player setting before applying changes.' }
    $fields=@();$modeToWrite=$null;$writePayload=$original
    switch -CaseSensitive ($Section) {
        'brightness' {
            $fields=Assert-StudioBoardFields $Values @('ratio')
            $ratio=Get-StudioBoardNumber (Get-StudioBoardProperty $Values 'ratio') 0 100 'Brightness'
            # The native scalar setter sends only ratio. GET also contains the
            # previous raw brightness and read-only metadata; reposting those
            # can override the percentage or stop the update from taking effect.
            $writePayload=[ordered]@{ratio=$ratio}
            try { $modeToWrite=Read-StudioBoardData $Session 'brightnessMode' } catch { throw 'Read the brightness mode before applying manual brightness.' }
            if ((Get-StudioBoardProperty $modeToWrite 'mode') -ceq 'MANUALLY') { $modeToWrite=$null }
            else {
                $modeToWrite=[ordered]@{source=[ordered]@{type=1;platform=2};type='SCREEN_BRIGHTNESS';mode='MANUALLY'}
            }
        }
        'colorTemperature' {
            $fields=Assert-StudioBoardFields $Values @('colorTemperature')
            $temperature=Get-StudioBoardNumber (Get-StudioBoardProperty $Values 'colorTemperature') 4700 9300 'Color temperature' -Integer
            if ($temperature -notin @(4700,6500,9300)) { throw 'Choose 4700 K, 6500 K, or 9300 K.' }
            Set-StudioBoardProperty $original 'colorTemperature' ([int]$temperature)
        }
        'mosaic' {
            $fields=Assert-StudioBoardFields $Values @('enable','direction','mode','totalLength')
            $info=Get-StudioBoardProperty $original 'info'
            if ($null -eq $info) { throw 'The player did not return mosaic configuration.' }
            foreach($field in $fields) {
                $v=Get-StudioBoardProperty $Values $field
                if ($field -ceq 'enable') {
                    if ($v -isnot [bool]) { throw 'Mosaic must be enabled or disabled.' }
                    Set-StudioBoardProperty $original $field $v
                } else {
                    $maximum=if ($field -eq 'totalLength') {4096} else {1}
                    $minimum=if ($field -eq 'totalLength') {1} else {0}
                    $v=Get-StudioBoardNumber $v $minimum $maximum 'Mosaic setting' -Integer
                    Set-StudioBoardProperty $info $field ([int]$v)
                }
            }
            if ((Get-StudioBoardProperty $original 'enable') -eq $true) {
                $length=Get-StudioBoardNumber (Get-StudioBoardProperty $info 'totalLength') 1 4096 'Mosaic width' -Integer
                $mode=Get-StudioBoardNumber (Get-StudioBoardProperty $info 'mode') 0 1 'Mosaic mode' -Integer
                $width=Get-StudioBoardProperty $Session.Device 'Width'
                if ($mode -eq 0 -and $width -gt 0) {
                    if (($length % $width) -ne 0) { throw 'Screen-count mosaic width must be a multiple of this player output width.' }
                    $safe=ConvertTo-StudioBoardSection 'mosaic' $original
                    $maxNum=$safe.value.maxNum
                    if ($maxNum -gt 0 -and ($length / $width) -gt $maxNum) { throw 'Mosaic screen count exceeds the limit reported by the player.' }
                }
            }
        }
        'time' {
            $fields=Assert-StudioBoardFields $Values @('utcTimeMillis','timeZone')
            if ($fields -ccontains 'utcTimeMillis') {
                try { $sync=Read-StudioBoardData $Session 'timeSync' } catch { throw 'Automatic time synchronization could not be checked. Refresh before changing the clock.' }
                if (Test-StudioBoardAutomaticTime $sync) { throw 'Automatic time synchronization is enabled. Disable it in ViPlex before setting the clock manually.' }
                $utc=Get-StudioBoardNumber (Get-StudioBoardProperty $Values 'utcTimeMillis') 946684800000 4133980799999 'Date and time' -Integer
                Set-StudioBoardProperty $original 'utcTimeMillis' ([long]$utc)
            }
            if ($fields -ccontains 'timeZone') {
                $zone=Get-StudioBoardProperty $Values 'timeZone'
                if ($zone -isnot [string] -or $zone.Length -gt 100 -or $zone -cnotmatch '^(?:UTC|GMT|[A-Za-z][A-Za-z0-9_+-]*(?:/[A-Za-z0-9_+-]+){1,3})$') { throw 'Use an IANA time zone such as America/Los_Angeles.' }
                $reference=Get-StudioBoardProperty $original 'utcTimeMillis'
                if ($null -eq $reference -or $reference -le 0) { $reference=[DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() }
                $zoneInfo=Get-StudioBoardTimeZone $zone ([long]$reference)
                Set-StudioBoardProperty $original 'timeZone' $zone
                Set-StudioBoardProperty $original 'gmt' $zoneInfo.gmt
                # The installed ViPlex setter uses zero to leave the clock alone
                # when only selecting a time zone; do not resend stale read time.
                if ($fields -cnotcontains 'utcTimeMillis') { Set-StudioBoardProperty $original 'utcTimeMillis' 0L }
            }
        }
        'ethernet' { $original=Edit-StudioBoardEthernet $original $Values }
    }
    try {
        if ($null -ne $modeToWrite) { $null=$Session.WriteControl('brightnessMode',($modeToWrite | ConvertTo-Json -Depth 32 -Compress)) }
        $null=$Session.WriteControl($Section,($writePayload | ConvertTo-Json -Depth 32 -Compress))
    } catch {
        if ($Section -eq 'ethernet') { throw 'The network change could not be confirmed. Reconnect to the player before retrying.' }
        throw 'The player did not confirm the setting change. Refresh its current settings before retrying.'
    }
    # Avoid a cascade of unrelated timeouts after changing an interface address.
    # The browser merges this affected-section readback into its existing view.
    $controls=Invoke-StudioBoardRead $Session @($Section)
    $verified=$controls[$Section].available
    if ($verified) {
        $actual=$controls[$Section].value
        if ($Section -eq 'brightness') {
            if ($actual.mode -cne 'MANUALLY') { $verified=$false }
            try {
                $reportedRatio=Get-StudioBoardNumber $actual.ratio 0 100 'Reported brightness'
                if ([math]::Abs($reportedRatio-[double]$Values.ratio) -gt 0.5) { $verified=$false }
                if ($null -ne $actual.brightness) {
                    $raw=Get-StudioBoardNumber $actual.brightness 0 255 'Reported output brightness' -Integer
                    if ([math]::Abs($raw-255.0*[double]$Values.ratio/100.0) -gt 1) { $verified=$false }
                }
            } catch { $verified=$false }
        }
        if ($Section -eq 'ethernet') {
            foreach($edit in (Get-StudioBoardProperty $Values 'ethernets')) {
                $entry=@($actual.ethernets | Where-Object {$_.name -ceq (Get-StudioBoardProperty $edit 'name')})
                if ($entry.Count -ne 1) { $verified=$false;break }
                foreach($field in (Get-StudioBoardFields $edit)) {
                    if ($field -in @('name','scopeId')) { continue }
                    if ($entry[0].dhcp -eq $true -and $field -ne 'dhcp') { continue }
                    if ((Get-StudioBoardProperty $entry[0] $field | ConvertTo-Json -Compress) -cne (Get-StudioBoardProperty $edit $field | ConvertTo-Json -Compress)) { $verified=$false }
                }
            }
        } else {
            foreach($field in $fields) {
                $readValue=if ($Section -eq 'mosaic' -and $field -ne 'enable') {Get-StudioBoardProperty $actual.info $field} else {Get-StudioBoardProperty $actual $field}
                $wanted=Get-StudioBoardProperty $Values $field
                if ($field -eq 'utcTimeMillis') { if ([math]::Abs([double]$readValue-[double]$wanted) -gt 120000) { $verified=$false } }
                elseif ($field -eq 'ratio') { if ([math]::Abs([double]$readValue-[double]$wanted) -gt 0.5) { $verified=$false } }
                elseif ($readValue -cne $wanted) { $verified=$false }
            }
        }
    }
    $message=if ($verified) {'Settings saved and read back from the player.'} elseif ($Section -eq 'ethernet') {'Settings were accepted; reconnect to verify the player at its new address.'} else {'Settings were accepted, but the readback did not confirm the requested values. Refresh before retrying.'}
    return @{controls=$controls;appliedSection=$Section;verified=$verified;reconnectRequired=($Section -eq 'ethernet' -and -not $verified);message=$message}
}
