<#
  Automated Domain Join Script
  * Prompts user to confirm Tamper Protection is disabled (Y/N).
  * Prompts user to enter the computer name and IP address.
  * Configures static IP.
  * Renames the computer (if needed).
  * Joins the domain and moves computer to the specified OU.
  * Syncs time with the domain controller.
  * Gives final login instructions.
  * Reboots at the end.
#>

[CmdletBinding()]
param(
    # ====== NETWORK SETTINGS ======
    [string]$InterfaceName   = "Ethernet0",
    [int]   $PrefixLength    = 24,
    [string]$DefaultGateway  = "10.10.14.1",
    [string]$DNSServer       = "10.10.14.1",

    # ====== DOMAIN INFO ======
    [string]$DomainName      = "AD.LAB",          # e.g. AD.LAB

    # ====== DOMAIN CREDENTIALS ======
    [string]$DomainAdminUser = "Administrator",
    [string]$DomainAdminPass = "SecretPassword123",

    # ====== LOCAL ADMIN CREDENTIALS (FOR RENAMING) ======
    [string]$LocalAdminUser  = "LocalUser",
    [string]$LocalAdminPass  = "password123!!",

    # ====== DOMAIN CONTROLLER HOSTNAME ======
    [string]$DCName          = "dc01.ad.lab"
)

# ──────────────────────────────────────────────────────────────────────────────
### 0) Ask for Computer Name and IP
# ──────────────────────────────────────────────────────────────────────────────
$ComputerName = Read-Host "Enter the desired computer name"
$NewIPAddress = Read-Host "Enter the new IP address"

# OU path selection based on new, shorter OU names
if ($ComputerName.ToUpper() -eq 'ADMIN04') {
    $TargetOU = "OU=DisSMBSig+DisPwdChg+DisDef+EnICMP,DC=AD,DC=LAB"
}
else {
    $TargetOU = "OU=DisPwdChg+DisDef+EnICMP,DC=AD,DC=LAB"
}

# ──────────────────────────────────────────────────────────────────────────────
### 1) Confirm Tamper Protection Disabled
# ──────────────────────────────────────────────────────────────────────────────
Write-Host "Have you disabled Tamper Protection in Windows Security? (Y/N)"
if ((Read-Host).ToUpper() -ne 'Y') {
    Write-Host "Tamper Protection is not confirmed disabled. Exiting."
    exit 1
}

# ──────────────────────────────────────────────────────────────────────────────
### 2) Require Admin Privileges
# ──────────────────────────────────────────────────────────────────────────────
if (-not ([Security.Principal.WindowsPrincipal] `
          [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole('Administrator')) {
    Write-Host "ERROR: Run this script from an elevated PowerShell window."
    exit 1
}

# ──────────────────────────────────────────────────────────────────────────────
### 3) Build Credential Objects
# ──────────────────────────────────────────────────────────────────────────────
$Cred = New-Object pscredential `
    ("$DomainName\$DomainAdminUser", (ConvertTo-SecureString $DomainAdminPass -AsPlainText -Force))

$LocalCred = New-Object pscredential `
    ($LocalAdminUser, (ConvertTo-SecureString $LocalAdminPass -AsPlainText -Force))

# ──────────────────────────────────────────────────────────────────────────────
### 4) Configure Static IP
# ──────────────────────────────────────────────────────────────────────────────
Write-Host "`n==> Configuring network settings..."
try {
    Set-NetIPInterface -InterfaceAlias $InterfaceName -Dhcp Disabled -ErrorAction SilentlyContinue

    Get-NetIPAddress -InterfaceAlias $InterfaceName -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Remove-NetIPAddress -Confirm:$false -ErrorAction SilentlyContinue

    Get-NetRoute -InterfaceAlias $InterfaceName -ErrorAction SilentlyContinue |
        Where-Object DestinationPrefix -eq '0.0.0.0/0' |
        Remove-NetRoute -Confirm:$false -ErrorAction SilentlyContinue
}
catch { Write-Host "WARNING resetting IP: $($_.Exception.Message)" }

New-NetIPAddress -InterfaceAlias $InterfaceName `
                 -IPAddress $NewIPAddress -PrefixLength $PrefixLength `
                 -DefaultGateway $DefaultGateway -ErrorAction Stop
Set-DnsClientServerAddress -InterfaceAlias $InterfaceName -ServerAddresses $DNSServer -ErrorAction Stop
Start-Sleep 5

# ──────────────────────────────────────────────────────────────────────────────
### 5) Connectivity Checks
# ──────────────────────────────────────────────────────────────────────────────
Write-Host "`n==> Testing connectivity to $DCName ..."
if (-not (Test-Connection $DCName -Count 2 -Quiet)) {
    Write-Host "ERROR: Domain controller unreachable."
    exit 1
}

try {
    Resolve-DnsName $DomainName -ErrorAction Stop | Out-Null
}
catch {
    Write-Host "ERROR: Cannot resolve domain name $DomainName."
    exit 1
}

# ──────────────────────────────────────────────────────────────────────────────
### 6) Rename Computer (if needed)
# ──────────────────────────────────────────────────────────────────────────────
if ($env:COMPUTERNAME -ne $ComputerName) {
    Rename-Computer -NewName $ComputerName -LocalCredential $LocalCred -Force
    Write-Host "Renamed to $ComputerName (final on reboot)."
}

# ──────────────────────────────────────────────────────────────────────────────
### 7) Join Domain
# ──────────────────────────────────────────────────────────────────────────────
Write-Host "`n==> Joining domain $DomainName ..."
Add-Computer -DomainName $DomainName -Credential $Cred -NewName $ComputerName -Force

# ──────────────────────────────────────────────────────────────────────────────
### 8) Move to Target OU
# ──────────────────────────────────────────────────────────────────────────────
Write-Host "Moving computer to target OU: $TargetOU"
try {
    Invoke-Command -ComputerName $DCName -Credential $Cred -ScriptBlock {
        param($CompName,$OUdn)
        Import-Module ActiveDirectory
        $comp = Get-ADComputer -Filter { Name -eq $CompName }
        if ($comp) { Move-ADObject $comp.DistinguishedName -TargetPath $OUdn }
        else { throw "Computer object not yet in AD (replication lag?)" }
    } -ArgumentList $ComputerName,$TargetOU -ErrorAction Stop
}
catch { Write-Host "WARNING: Could not move object now; it will stay in default OU." }

# ──────────────────────────────────────────────────────────────────────────────
### 9) Sync Time
# ──────────────────────────────────────────────────────────────────────────────
w32tm /resync | Out-Null

# ──────────────────────────────────────────────────────────────────────────────
### 10) Final message & Reboot
# ──────────────────────────────────────────────────────────────────────────────
Write-Host "`n=============================================================="
Write-Host "Domain join staged. On next boot, log in with domain creds."
Write-Host "=============================================================="
Read-Host "Press ENTER to reboot..."
Restart-Computer -Force
