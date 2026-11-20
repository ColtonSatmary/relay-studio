# Synthetic sessions only: no network traffic, hardware changes, or credentials.
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'StudioBoardControls.ps1')
function Assert-Board([bool]$Condition,[string]$Message) { if (-not $Condition) { throw "Test failed: $Message" } }
function Assert-BoardReject([scriptblock]$Action,[string]$Expected) {
    $message='';try { & $Action | Out-Null } catch {$message=$_.Exception.Message}
    Assert-Board ($message -like "*$Expected*") "Expected '$Expected'; got '$message'."
}
function New-BoardFixture {
    $session=[pscustomobject]@{
        Device=[pscustomobject]@{Width=320;Height=1080}
        Data=@{
            brightness='{"ratio":70,"brightness":178,"firmwareOnly":{"keep":true},"password":"never-return"}'
            brightnessMode='{"mode":"MANUALLY","type":"SCREEN_BRIGHTNESS","extra":9}'
            colorTemperature='{"colorTemperature":6500,"extra":7}'
            mosaic='{"enable":true,"info":{"direction":0,"mode":0,"totalLength":1920,"spliceHdmiConfig":{"autoSpliceHdmiConfig":{"maxNum":10}},"futureField":true}}'
            time='{"utcTimeMillis":1795000000000,"timeZone":"America/Los_Angeles","isTimeOffsetEnable":true,"timeOffsetValue":3600000,"beginTime":"03-08","endTime":"11-01","zoneOffset":"-08:00","dstEnable":true,"orderId":-1}'
            timeSync='{"enable":false,"ntp":{"enable":false},"gps":{"enable":false},"lora":{"enable":false}}'
            ethernet='{"ethernets":[{"name":"eth0","scopeId":-1,"dhcp":true,"ip":"192.168.1.24","mask":"255.255.255.0","gateWay":"192.168.1.1","dns":["192.168.1.1","0.0.0.0"],"mtu":1500},{"name":"eth1","scopeId":3,"dhcp":true,"ip":"10.0.0.8","mask":"255.255.255.0","gateWay":"10.0.0.1","dns":["10.0.0.1"]}],"future":true}'
            wifiState='{"state":1,"password":"never-return"}'
            wifiNetworks='{"result":[{"ssid":"Fixture Wi-Fi","bssid":"fixture","frequency":2412,"level":4,"security":"PSK:WPA2","state":5,"password":"never-return"}]}'
        }
        Writes=[Collections.Generic.List[object]]::new()
        FailRead=@();FailWrite=@();IgnoreWrite=@();BrightnessReply=$null;DisconnectAfterWrite=$false;Reads=[Collections.Generic.List[string]]::new()
    }
    $session | Add-Member ScriptMethod ReadControl {
        param($section)
        $this.Reads.Add($section)
        if ($this.FailRead -contains $section) { throw 'Synthetic remote error with private-token' }
        return $this.Data[$section]
    }
    $session | Add-Member ScriptMethod WriteControl {
        param($section,$json)
        if ($this.FailWrite -contains $section) { throw 'Synthetic remote error with private-token' }
        $this.Writes.Add(@{section=$section;value=($json | ConvertFrom-Json)})
        if ($this.IgnoreWrite -notcontains $section) {
            if ($section -eq 'brightness') {
                $received=$json|ConvertFrom-Json
                $current=$this.Data[$section]|ConvertFrom-Json
                # Model the actual output separately from the UI percentage.
                # A stale raw field takes priority, exposing the former bug.
                if($received.PSObject.Properties['brightness']) {
                    $current.brightness=$received.brightness
                    $current.ratio=[math]::Round($received.brightness*100.0/255.0,1)
                } else {
                    $current.ratio=$received.ratio
                    $current.brightness=[math]::Floor($received.ratio*255.0/100.0)
                }
                $this.Data[$section]=if($null -ne $this.BrightnessReply){$this.BrightnessReply}else{$current|ConvertTo-Json -Depth 8 -Compress}
            } else {$this.Data[$section]=$json}
        }
        if ($this.DisconnectAfterWrite) { $this.FailRead=@('brightness','brightnessMode','colorTemperature','mosaic','time','timeSync','ethernet','wifiState','wifiNetworks') }
        return '{}'
    }
    return $session
}

$s=New-BoardFixture
$controls=Invoke-StudioBoardRead $s
Assert-Board ($controls.brightness.available -and $controls.brightness.value.ratio -eq 70) 'Brightness not exposed.'
Assert-Board ($controls.wifi.readOnly -and $controls.wifi.value.networks[0].state -eq 5) 'Wi-Fi status missing.'
Assert-Board (($controls | ConvertTo-Json -Depth 20) -notmatch 'never-return|password|firmwareOnly|futureField') 'Unknown/private fields leaked to browser.'
$s.FailRead=@('colorTemperature','wifiNetworks')
$controls=Invoke-StudioBoardRead $s
Assert-Board (-not $controls.colorTemperature.available -and $controls.brightness.available -and $controls.wifi.available) 'One unavailable endpoint disabled all controls.'
Assert-Board (($controls | ConvertTo-Json -Depth 20) -notmatch 'private-token') 'Remote error leaked.'

$s=New-BoardFixture
$s.Data.brightnessMode='{"mode":"AUTO","type":"SCREEN_BRIGHTNESS","future":true}'
$result=Invoke-StudioBoardApply $s 'brightness' @{ratio=42.5}
Assert-Board ($result.verified -and $s.Writes.Count -eq 2 -and $s.Writes[0].section -eq 'brightnessMode') 'Manual brightness mode not applied before ratio.'
Assert-Board ($result.controls.Count -eq 1 -and $result.controls.brightness.available) 'Apply unnecessarily reread unrelated controls.'
Assert-Board (@($s.Writes[1].value.PSObject.Properties.Name).Count -eq 1 -and $s.Writes[1].value.ratio -eq 42.5) 'Brightness setter resent stale raw output or read-only metadata.'
Assert-Board (($s.Writes[0].value.PSObject.Properties.Name|Sort-Object) -join ',' -ceq 'mode,source,type') 'Manual mode setter does not match the native command.'
Assert-Board ($s.Writes[0].value.source.platform -eq 2) 'Manual mode source missing.'
foreach($bad in @(-1,101,[double]::NaN,'50',$true)) {
    $s=New-BoardFixture;Assert-BoardReject { Invoke-StudioBoardApply $s 'brightness' @{ratio=$bad} } 'Brightness';Assert-Board ($s.Writes.Count -eq 0) 'Invalid ratio wrote to player.'
}
$s=New-BoardFixture;Assert-BoardReject { Invoke-StudioBoardApply $s 'brightness' @{ratio=50;password='x'} } 'unsupported';Assert-Board ($s.Writes.Count -eq 0) 'Unknown field reached player.'
$s=New-BoardFixture;Assert-BoardReject { Invoke-StudioBoardApply $s 'colorTemperature' @{colorTemperature=7000} } 'Choose 4700';Assert-Board ($s.Writes.Count -eq 0) 'Unsupported temperature reached player.'
foreach($temp in @(4700,6500,9300)) {$s=New-BoardFixture;$r=Invoke-StudioBoardApply $s 'colorTemperature' @{colorTemperature=$temp};Assert-Board $r.verified 'Supported temperature failed.'}

$s=New-BoardFixture
$result=Invoke-StudioBoardApply $s 'mosaic' @{enable=$true;direction=1;mode=0;totalLength=2560}
Assert-Board ($result.verified -and $s.Writes[0].value.info.futureField -and $s.Writes[0].value.info.spliceHdmiConfig.autoSpliceHdmiConfig.maxNum -eq 10) 'Mosaic update lost firmware metadata.'
foreach($length in @(0,1921,3520,4097)) {
    $s=New-BoardFixture;Assert-BoardReject {Invoke-StudioBoardApply $s 'mosaic' @{totalLength=$length}} 'Mosaic';Assert-Board ($s.Writes.Count -eq 0) 'Invalid mosaic written.'
}

$s=New-BoardFixture
$result=Invoke-StudioBoardApply $s 'time' @{utcTimeMillis=1795000100000L}
$saved=$s.Writes[0].value
Assert-Board ($result.verified -and $saved.timeZone -eq 'America/Los_Angeles' -and $saved.isTimeOffsetEnable -and $saved.timeOffsetValue -eq 3600000 -and $saved.beginTime -eq '03-08' -and $saved.dstEnable) 'Manual time reset time-zone/DST settings.'
$s=New-BoardFixture;$s.Data.timeSync='{"enable":false,"ntp":{"enable":true}}'
Assert-BoardReject {Invoke-StudioBoardApply $s 'time' @{utcTimeMillis=1795000100000L}} 'Automatic time';Assert-Board ($s.Writes.Count -eq 0) 'Manual time applied with automatic sync.'
$result=Invoke-StudioBoardApply $s 'time' @{timeZone='America/New_York'}
Assert-Board ($result.verified -and $s.Writes[0].value.utcTimeMillis -eq 0L) 'Zone-only edit omitted native leave-clock-alone sentinel or was blocked by NTP.'
Assert-Board ($s.Writes[0].value.gmt -eq 'GTM-05:00' -and $s.Writes[0].value.dstEnable -and $s.Writes[0].value.timeOffsetValue -eq 3600000) 'Zone change used wrong standard offset or cleared DST.'
$s=New-BoardFixture;$s.FailRead=@('timeSync');Assert-BoardReject {Invoke-StudioBoardApply $s 'time' @{utcTimeMillis=1795000100000L}} 'could not be checked'
$s=New-BoardFixture;Assert-BoardReject {Invoke-StudioBoardApply $s 'time' @{timeZone='../../private'}} 'IANA'
$s=New-BoardFixture;Assert-BoardReject {Invoke-StudioBoardApply $s 'time' @{timeZone='America/Not_A_Real_Zone'}} 'Unknown IANA';Assert-Board ($s.Writes.Count -eq 0) 'Unknown IANA zone reached player.'
$summer=Get-StudioBoardTimeZone 'America/Los_Angeles' 1784000000000L
Assert-Board ($summer.gmt -eq 'GTM-08:00') 'Summer DST offset was used in the standard GMT field.'
$fractional=Get-StudioBoardTimeZone 'Asia/Kathmandu' 1795000000000L
Assert-Board ($fractional.gmt -eq 'GTM+05:45') 'Fractional-hour zone offset was lost.'

$s=New-BoardFixture
$change=@{ethernets=@(@{name='eth0';scopeId=-1;dhcp=$false;ip='192.168.1.26';mask='255.255.255.0';gateWay='192.168.1.1';dns=@('1.1.1.1','0.0.0.0')})}
$result=Invoke-StudioBoardApply $s 'ethernet' $change
Assert-Board ($result.verified -and $s.Writes[0].value.ethernets[0].mtu -eq 1500 -and $s.Writes[0].value.ethernets[1].ip -eq '10.0.0.8' -and $s.Writes[0].value.future) 'Ethernet update dropped untouched interfaces or fields.'
foreach($case in @(
    @{edit=@{name='missing';dhcp=$true};error='interface has changed'},
    @{edit=@{name='eth0';scopeId=4;dhcp=$true};error='identity has changed'},
    @{edit=@{name='eth0';dhcp=$false;mask='255.0.255.0'};error='contiguous'},
    @{edit=@{name='eth0';dhcp=$false;ip='192.168.1.255'};error='broadcast'},
    @{edit=@{name='eth0';dhcp=$false;gateWay='10.0.0.1'};error='same subnet'},
    @{edit=@{name='eth0';dhcp='true'};error='DHCP'}
)) {$s=New-BoardFixture;Assert-BoardReject {Invoke-StudioBoardApply $s 'ethernet' @{ethernets=@($case.edit)}} $case.error;Assert-Board ($s.Writes.Count -eq 0) 'Invalid network setting written.'}
$s=New-BoardFixture;$s.IgnoreWrite=@('brightness');$result=Invoke-StudioBoardApply $s 'brightness' @{ratio=40};Assert-Board (-not $result.verified) 'Nonmatching readback reported success.'
$s=New-BoardFixture;$s.BrightnessReply='{"ratio":50,"brightness":255}';$result=Invoke-StudioBoardApply $s 'brightness' @{ratio=50};Assert-Board (-not $result.verified) 'Matching percentage hid unchanged raw output.'
foreach($reply in @('{"brightness":0}','{"ratio":null,"brightness":0}','{"ratio":true,"brightness":0}','{"ratio":"0","brightness":0}')) {
    $s=New-BoardFixture;$s.BrightnessReply=$reply;$result=Invoke-StudioBoardApply $s 'brightness' @{ratio=0};Assert-Board (-not $result.verified) 'Invalid percentage was coerced to zero and verified.'
}
foreach($ratio in @(0,50,100)) {
    $s=New-BoardFixture;$result=Invoke-StudioBoardApply $s 'brightness' @{ratio=$ratio};Assert-Board $result.verified 'Native raw output rounding was rejected.'
}
$s=New-BoardFixture;$s.Data.brightnessMode='{"mode":"AUTO"}';$s.IgnoreWrite=@('brightnessMode');$result=Invoke-StudioBoardApply $s 'brightness' @{ratio=40};Assert-Board (-not $result.verified) 'Automatic mode remained active but manual brightness claimed verified.'
$s=New-BoardFixture;$s.DisconnectAfterWrite=$true;$result=Invoke-StudioBoardApply $s 'ethernet' $change
Assert-Board (-not $result.verified -and $result.reconnectRequired -and $s.Reads.Count -eq 2 -and $s.Writes.Count -eq 1) 'Network disconnect caused retries or unrelated timeout requests.'
$s=New-BoardFixture;$s.FailWrite=@('ethernet');Assert-BoardReject {Invoke-StudioBoardApply $s 'ethernet' $change} 'Reconnect';Assert-Board ($s.Writes.Count -eq 0) 'Failed network write retried.'
$s=New-BoardFixture;Assert-BoardReject {Invoke-StudioBoardApply $s 'wifi' @{state=0}} 'read-only';Assert-Board ($s.Writes.Count -eq 0) 'Wi-Fi write occurred.'
Write-Output 'Board controls: all synthetic read, preservation, validation, and readback checks passed.'
