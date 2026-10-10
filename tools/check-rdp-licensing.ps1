<#
  webrdp - target-side diagnostic: RDP licensing / RD Session Host state.

  WHY
    When a browser client fails with
        LicensingErrorMessage { error_code: InvalidClient, state_transition: TotalAbort }
    the rejection happens AFTER the credentials were accepted, during the RDP
    license negotiation step (MS-RDPELE). Per MS-RDPELE 3.2.5.5 cases 2 and 3
    plus 3.2.5.8, that ERROR + ST_TOTAL_ABORT combination is produced only when
    either (a) the RD Session Host's 120-day grace period has been exceeded, or
    (b) the client sent a malformed / out-of-sequence licensing PDU.
    Telling (a) and (b) apart needs the server-side facts this script collects.
    The two decisive numbers are section 2 GracePeriodDaysLeft and the decoded
    grace-period deadline in section 4.

  RUN ON THE TARGET MACHINE, IN AN ELEVATED PS PROMPT
    powershell -ExecutionPolicy Bypass -File .\check-rdp-licensing.ps1

  COMPATIBILITY
    Windows PS 3.0+ (Server 2012 / 2012 R2). ASCII only on purpose, so the
    output survives any console codepage and can be pasted back verbatim.

  CHANGELOG
    v2  GetGracePeriodDays / GetSpecifiedLicenseServerList now have three
        fallbacks each. v1 called Invoke-CimMethod on a Get-WmiObject object,
        which always fails ("Cannot convert ... ManagementObject ... to type
        CimInstance"), so both values always printed n/a. Dropped the incorrect
        hint that n/a means "not an RD Session Host", widened the event window
        from 7 to 180 days, and added section 7 so you can see whether the box
        is really shared (which decides whether the RD Session Host role may go).
    v3  Section 4 now decodes the RCM\GracePeriod blob as a FILETIME. That read
        needs no WMI provider at all, so it still yields the grace-period
        deadline on hosts where GetGracePeriodDays cannot be called.
    v4  Section 4 no longer claims the RCM\GracePeriod value is a FILETIME. On a
        real RD Session Host it turned out to be a 230-byte DPAPI-encrypted blob
        (version 1 + provider GUID d08c9ddf-0115-11d1-8c7a-00c04fc297eb) and the
        old code threw while decoding it. Now only an exactly 8-byte value is
        decoded; anything else is reported as undecodable and the hex dump is
        truncated to the first 16 bytes. Section 2 remains authoritative.
#>

# Overridable only so the decode routine can be exercised against a known value.
param(
    [string]$GraceKey = 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\RCM\GracePeriod'
)

$ErrorActionPreference = 'Continue'

function Section([string]$title) {
    Write-Host ''
    Write-Host ('=== ' + $title + ' ===') -ForegroundColor Cyan
}

# Call a WMI method whose result comes back through an [out] parameter.
# Three strategies, because no single one works everywhere:
#   1) direct call  - the form Microsoft documents
#   2) InvokeMethod - the .NET signature (methodName, inParams, options)
#   3) CIM instance + Invoke-CimMethod
function Get-WmiOut {
    param($Instance, [string]$Method, [string]$Param)
    if ($null -eq $Instance) { return $null }

    try {
        $r = $Instance.$Method()
        if ($null -ne $r) {
            try { if ($null -ne $r.$Param) { return $r.$Param } } catch { }
            try {
                if ($null -ne $r.Properties) {
                    if ($null -ne $r.Properties[$Param]) { return $r.Properties[$Param].Value }
                }
            } catch { }
        }
    } catch { }

    try {
        $mb = $Instance.InvokeMethod($Method, $null, $null)
        if ($null -ne $mb) {
            try {
                if ($null -ne $mb.Properties) {
                    if ($null -ne $mb.Properties[$Param]) { return $mb.Properties[$Param].Value }
                }
            } catch { }
            try { if ($null -ne $mb[$Param]) { return $mb[$Param] } } catch { }
        }
    } catch { }

    try {
        $ci = Get-CimInstance -Namespace 'root/CIMV2/TerminalServices' -ClassName 'Win32_TerminalServiceSetting' -ErrorAction Stop
        $rc = Invoke-CimMethod -InputObject $ci -MethodName $Method -ErrorAction Stop
        if ($null -ne $rc) {
            try { if ($null -ne $rc.$Param) { return $rc.$Param } } catch { }
        }
    } catch { }

    return $null
}

# Decode the 8-byte little-endian FILETIME stored in RCM\GracePeriod.
# Heuristic: the value is a deadline, so a plausible decode lands in 2000..2100.
# The raw bytes are printed next to it so a wrong guess is visible, not hidden.
function Show-GracePeriodBlob {
    param([string]$KeyPath)

    if (-not (Test-Path $KeyPath)) {
        Write-Host ('  key absent: ' + $KeyPath)
        return
    }
    try {
        $item = Get-Item -LiteralPath $KeyPath -ErrorAction Stop
    } catch {
        Write-Host ('  cannot open key: ' + $_.Exception.Message)
        return
    }
    $names = @($item.GetValueNames())
    if ($names.Count -eq 0) {
        Write-Host '  key exists but holds no values'
        return
    }
    foreach ($n in $names) {
        $v = $null
        try { $v = $item.GetValue($n) } catch { }
        if ($v -is [byte[]]) {
            $hex = (($v[0..([Math]::Min(15, $v.Length - 1))] | ForEach-Object { $_.ToString('x2') }) -join ' ')
            $suffix = '  (' + $v.Length + ' bytes)'
            if ($v.Length -ne 8) { $suffix = $suffix + '  full value not shown' }
            Write-Host ('  ' + $n + $suffix)
            if ($v.Length -ne 8) {
                Write-Host ('    first bytes: ' + $hex)
                if ($v.Length -gt 12 -and $v[0] -eq 1 -and $v[1] -eq 0 -and $v[2] -eq 0 -and $v[3] -eq 0) {
                    Write-Host '    this is a DPAPI-encrypted blob (version 1 + provider GUID), it cannot be'
                    Write-Host '    decoded offline - section 2 GracePeriodDaysLeft is the real answer.'
                } else {
                    Write-Host '    not an 8-byte FILETIME - no deadline can be derived from it.'
                }
            }
            if ($v.Length -eq 8) {
                try {
                    $lo = [uint64]$v[0] + ([uint64]$v[1] * 256) + ([uint64]$v[2] * 65536) + ([uint64]$v[3] * 16777216)
                    $hi = [uint64]$v[4] + ([uint64]$v[5] * 256) + ([uint64]$v[6] * 65536) + ([uint64]$v[7] * 16777216)
                    $ft = $hi * 4294967296 + $lo
                    if ($ft -lt 1 -or $ft -gt 2650467743999999999) { throw 'value is outside the FILETIME range (0001-01-01 .. 9999-12-31)' }
                    $dt = [DateTime]::FromFileTime([int64]$ft)
                    if ($dt.Year -ge 2000 -and $dt.Year -le 2100) {
                        $left = [int][Math]::Floor(($dt - (Get-Date)).TotalDays)
                        Write-Host ('    decoded as FILETIME -> ' + $dt.ToString('yyyy-MM-dd HH:mm:ss') + '  (local time)')
                        if ($left -le 0) {
                            Write-Host ('    -> ' + $left + ' day(s) left : GRACE PERIOD ALREADY EXPIRED')
                        } else {
                            Write-Host ('    -> ' + $left + ' day(s) left : still inside the grace period')
                        }
                    } else {
                        Write-Host ('    not a plausible FILETIME (decoded year ' + $dt.Year + ') - ignore this line')
                    }
                } catch {
                    Write-Host ('    decode failed: ' + $_.Exception.Message)
                }
            }
        } else {
            Write-Host ('  ' + $n + ' = ' + [string]$v)
        }
    }
}

Section '0. Host / OS'
Write-Host ('  ComputerName  : ' + $env:COMPUTERNAME)
try {
    $os = Get-WmiObject -Class Win32_OperatingSystem
    Write-Host ('  Caption       : ' + $os.Caption)
    Write-Host ('  Version       : ' + $os.Version)
} catch {
    Write-Host ('  OS query failed: ' + $_.Exception.Message)
}
try {
    $cs = Get-WmiObject -Class Win32_ComputerSystem
    Write-Host ('  PartOfDomain  : ' + $cs.PartOfDomain)
    if ($cs.PartOfDomain) { Write-Host ('  Domain        : ' + $cs.Domain) }
} catch { }
Write-Host ('  PSVersion     : ' + $PSVersionTable.PSVersion.ToString())
try {
    $elevated = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    Write-Host ('  IsElevated    : ' + $elevated)
} catch { }

Section '1. Remote Desktop Services features'
try {
    Get-WindowsFeature RDS* |
        Select-Object Name, DisplayName, InstallState |
        Format-Table -AutoSize
    Write-Host '  RDS-RD-Server = RD Session Host role service (the one that needs a CAL)'
    Write-Host '  RDS-Licensing = RD Licensing role service (the license server itself)'
    Write-Host '  InstallState "Available" means NOT installed.'
} catch {
    Write-Host ('  feature query failed: ' + $_.Exception.Message)
}

Section '2. Licensing mode / grace period'
$ts = $null
try {
    $ts = Get-WmiObject -Namespace 'root/CIMV2/TerminalServices' -Class 'Win32_TerminalServiceSetting' -ErrorAction Stop
} catch {
    Write-Host ('  WMI query failed: ' + $_.Exception.Message)
}

if ($null -ne $ts) {
    $map = @{
        0 = 'Personal Terminal Server'
        1 = 'Remote Desktop for Administration  (no CAL needed)'
        2 = 'Per Device'
        4 = 'Per User'
        5 = 'Not configured'
    }
    try {
        $lt = [int]$ts.LicensingType
        $nm = $map[$lt]
        if ($null -eq $nm) { $nm = 'unknown' }
        Write-Host ('  LicensingType       : ' + $lt + '  (' + $nm + ')')
    } catch {
        Write-Host ('  LicensingType       : read failed - ' + $_.Exception.Message)
    }
    try { Write-Host ('  LicensingName       : [' + [string]$ts.LicensingName + ']') } catch { }
    try {
        Write-Host ('  TerminalServerMode  : ' + $ts.TerminalServerMode + '  (0 = Remote Desktop for Administration, 1 = Application Server / multi-user)')
    } catch { }

    $days = Get-WmiOut -Instance $ts -Method 'GetGracePeriodDays' -Param 'DaysLeft'
    if ($null -eq $days) {
        Write-Host '  GracePeriodDaysLeft : COULD NOT READ (see section 4 for the same fact)'
    } else {
        Write-Host ('  GracePeriodDaysLeft : ' + $days)
        if ([int]$days -le 0) {
            Write-Host '                        -> grace period is OVER: this host refuses new clients'
        } else {
            Write-Host '                        -> grace period is still running'
        }
    }

    $srv = Get-WmiOut -Instance $ts -Method 'GetSpecifiedLicenseServerList' -Param 'LicenseServerList'
    if ($null -eq $srv) {
        Write-Host '  LicenseServerList   : COULD NOT READ'
    } else {
        if ($srv -is [string]) { $srv = @($srv) }
        Write-Host ('  LicenseServerList   : [' + (($srv) -join ', ') + ']')
    }
    Write-Host '  NOTE: GracePeriodDaysLeft is the decisive value. MS-RDPELE 3.2.5.5'
    Write-Host '        cases 2 and 3 only abort the connection once it has expired.'
}

Section '3. Group Policy overrides'
try {
    $p = Get-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services' -ErrorAction Stop
    if ($null -ne $p.LicensingMode) { Write-Host ('  LicensingMode (GPO)  : ' + $p.LicensingMode) } else { Write-Host '  LicensingMode (GPO)  : not set' }
    if ($null -ne $p.LicenseServers) { Write-Host ('  LicenseServers (GPO) : ' + (($p.LicenseServers) -join ', ')) } else { Write-Host '  LicenseServers (GPO) : not set' }
    Write-Host '  NOTE: a GPO here overrides the GUI/WMI settings, so ChangeMode() would not stick.'
} catch {
    Write-Host '  no Terminal Services policy key (normal)'
}
try {
    $rc = Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\RCM\Licensing Core' -ErrorAction Stop
    if ($null -ne $rc.LicensingMode) { Write-Host ('  LicensingMode (RCM)  : ' + $rc.LicensingMode + '   (2 = Per Device, 4 = Per User)') } else { Write-Host '  LicensingMode (RCM)  : not set' }
} catch {
    Write-Host '  RCM\Licensing Core key absent'
}

Section '4. Grace-period registry blob (best effort, needs no WMI provider)'
Show-GracePeriodBlob $GraceKey
Write-Host '  Interpretation: a past date means the 120-day grace period is over and'
Write-Host '  this host will refuse new clients that hold no license of their own.'

Section '5. Licensing events (System log, last 180 days)'
try {
    $ids = 1088, 1004, 1010, 1005, 1067, 4105
    $e1 = Get-WinEvent -FilterHashtable @{ LogName = 'System'; StartTime = (Get-Date).AddDays(-180); Id = $ids } -MaxEvents 20 -ErrorAction Stop
    $e1 | Select-Object TimeCreated, Id, ProviderName, LevelDisplayName | Format-Table -AutoSize
    Write-Host '  Looking for "grace period has expired" / cannot-issue-a-license messages.'
} catch {
    Write-Host '  no matching events in the last 180 days'
}
try {
    $e2 = Get-WinEvent -FilterHashtable @{ LogName = 'System'; StartTime = (Get-Date).AddDays(-30); Level = 2, 3 } -MaxEvents 400 -ErrorAction Stop |
        Where-Object { $_.Message -match 'licens|grace period|Remote Desktop Services' } |
        Select-Object -Last 8 TimeCreated, Id, ProviderName
    if ($e2) { $e2 | Format-Table -AutoSize } else { Write-Host '  no licensing-related warnings/errors in the last 30 days' }
} catch {
    Write-Host '  secondary event scan failed'
}

Section '6. RDP listener settings'
try {
    Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp' |
        Select-Object PortNumber, fEnableWinStation, UserAuthentication, SecurityLayer |
        Format-List
    Write-Host '  UserAuthentication : 0 = NLA not required, 1 = NLA required'
    Write-Host '  SecurityLayer      : 0 = RDP security, 1 = Negotiate, 2 = TLS'
} catch {
    Write-Host ('  registry query failed: ' + $_.Exception.Message)
}

Section '7. Is this box really used by several people?'
Write-Host '  -- current sessions (qwinsta) --'
try {
    & qwinsta 2>$null | ForEach-Object { Write-Host ('    ' + $_) }
} catch {
    Write-Host '    qwinsta unavailable'
}
Write-Host '  -- remote logon / logoff events, last 30 days --'
try {
    $se = Get-WinEvent -FilterHashtable @{
        LogName   = 'Microsoft-Windows-TerminalServices-LocalSessionManager/Operational'
        StartTime = (Get-Date).AddDays(-30)
        Id        = 21, 22, 23, 24, 25
    } -MaxEvents 15 -ErrorAction Stop
    $se | Select-Object TimeCreated, Id, @{ n = 'Message'; e = {
        $m = [string]$_.Message
        $m = $m -replace "`r", ' ' -replace "`n", ' '
        if ($m.Length -gt 100) { $m = $m.Substring(0, 100) }
        $m
    } } | Format-Table -AutoSize
    Write-Host '  21/22/23/24/25 = remote logon events - shows how many people really use it.'
} catch {
    Write-Host '  no session events found'
}
Write-Host '  NOTE: if several users log in here, the RD Session Host role has to stay.'
Write-Host '        Blank out user names before pasting this section back, if you like.'

Write-Host ''
Write-Host 'Done. Paste the whole output back for analysis.' -ForegroundColor Yellow
