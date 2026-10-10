<#
  webrdp - target-side diagnostic: RDP licensing / RD Session Host state.

  WHY: when a browser client fails with a licensing error such as
       LicensingErrorMessage { error_code: InvalidClient, state_transition: TotalAbort }
       the rejection happens AFTER CredSSP/NLA, i.e. the server accepted the
       credentials and then refused the client during license negotiation.
       This script collects the server-side facts needed to tell apart
         (a) RD Session Host with an expired/absent license, vs
         (b) no RDS role at all -> the error is a client-implementation gap.

  RUN ON THE TARGET MACHINE, IN AN ELEVATED POWERSHELL:
       powershell -ExecutionPolicy Bypass -File .\check-rdp-licensing.ps1

  Compatible with Windows PowerShell 3.0+ (Server 2012) - no PS5-only syntax.
  ASCII only on purpose: pasted/redirected output survives any console codepage.
#>

$ErrorActionPreference = 'Continue'

function Section([string]$title) {
    Write-Host ''
    Write-Host ('=== ' + $title + ' ===') -ForegroundColor Cyan
}

Section '0. Host / OS'
Write-Host ('  ComputerName : ' + $env:COMPUTERNAME)
try {
    $os = Get-WmiObject -Class Win32_OperatingSystem
    Write-Host ('  Caption      : ' + $os.Caption)
    Write-Host ('  Version      : ' + $os.Version)
} catch {
    Write-Host ('  OS query failed: ' + $_.Exception.Message)
}
Write-Host ('  PowerShell   : ' + $PSVersionTable.PSVersion.ToString())
Write-Host ('  IsElevated   : ' + ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator))

Section '1. Remote Desktop Services features'
try {
    Get-WindowsFeature RDS* |
        Select-Object Name, DisplayName, InstallState |
        Format-Table -AutoSize
    Write-Host '  RDS-RD-Server  = Remote Desktop Session Host role service'
    Write-Host '  RDS-Licensing  = Remote Desktop Licensing role service'
    Write-Host '  InstallState "Available" means NOT installed.'
} catch {
    Write-Host ('  feature query failed: ' + $_.Exception.Message)
}

Section '2. Licensing mode / grace period'
try {
    $ts = Get-WmiObject -Namespace 'root/CIMV2/TerminalServices' -Class Win32_TerminalServiceSetting
    $map = @{
        0 = 'Personal Terminal Server'
        1 = 'Remote Desktop for Administration'
        2 = 'Per Device'
        4 = 'Per User'
        5 = 'Not configured'
    }
    $lt = [int]$ts.LicensingType
    $name = $map[$lt]
    if ($null -eq $name) { $name = 'unknown' }
    Write-Host ('  LicensingType       : ' + $lt + '  (' + $name + ')')
    Write-Host ('  LicensingName       : ' + $ts.LicensingName)
    Write-Host ('  TerminalServerMode  : ' + $ts.TerminalServerMode + '  (0=Remote Desktop for Administration, 1=Application Server)')
    try {
        $g = Invoke-CimMethod -InputObject $ts -MethodName GetGracePeriodDays
        Write-Host ('  GracePeriodDaysLeft : ' + $g.DaysLeft + '   (<=0 or missing = grace period over)')
    } catch {
        Write-Host '  GracePeriodDaysLeft : n/a  (host is not an RD Session Host)'
    }
    try {
        $srv = Invoke-CimMethod -InputObject $ts -MethodName GetSpecifiedLicenseServerList
        $list = $srv.LicenseServerList
        if ($null -eq $list) { $list = @() }
        Write-Host ('  LicenseServerList   : ' + (($list) -join ', '))
    } catch {
        Write-Host '  LicenseServerList   : n/a'
    }
} catch {
    Write-Host ('  WMI query failed: ' + $_.Exception.Message)
}

Section '3. Group Policy overrides'
try {
    $p = Get-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services' -ErrorAction Stop
    if ($null -ne $p.LicensingMode)  { Write-Host ('  LicensingMode (GPO)  : ' + $p.LicensingMode) }  else { Write-Host '  LicensingMode (GPO)  : not set' }
    if ($null -ne $p.LicenseServers) { Write-Host ('  LicenseServers (GPO) : ' + (($p.LicenseServers) -join ', ')) } else { Write-Host '  LicenseServers (GPO) : not set' }
    Write-Host '  NOTE: if a GPO pins these, WMI ChangeMode() will not stick.'
} catch {
    Write-Host '  no Terminal Services policy key (normal)'
}

Section '4. Grace-period registry marker'
$gp = 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\RCM\GracePeriod'
Write-Host ('  GracePeriod key exists : ' + (Test-Path $gp))

Section '5. Licensing events (System log, last 7 days)'
try {
    Get-EventLog -LogName System -After (Get-Date).AddDays(-7) -ErrorAction Stop |
        Where-Object { (1004, 1010, 1088, 1089) -contains $_.EventID } |
        Select-Object -Last 10 TimeGenerated, EventID, Source, EntryType |
        Format-Table -AutoSize
    Write-Host '  1088 = grace period expired | 1004/1010 = cannot issue / cannot find license server'
} catch {
    Write-Host ('  event query failed: ' + $_.Exception.Message)
}

Section '6. RDP listener settings'
try {
    Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp' |
        Select-Object PortNumber, fEnableWinStation, UserAuthentication, SecurityLayer |
        Format-List
    Write-Host '  UserAuthentication 1 = NLA required | SecurityLayer 2 = TLS'
} catch {
    Write-Host ('  registry query failed: ' + $_.Exception.Message)
}

Write-Host ''
Write-Host 'Done. Copy the whole output back for analysis.' -ForegroundColor Yellow
