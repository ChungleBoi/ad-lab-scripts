<#
  Automated Domain Join Script
  - Prompts user to confirm Tamper Protection is disabled (Y/N).
  - Configures static IP.
  - Renames the computer (if needed).
  - Joins the domain and moves computer to the specified OU.
  - Adds "AD\daniela" to local Administrators group.
  - Syncs time with the domain controller.
  - Gives final login instructions.
  - Reboots at the end.
#>

[CmdletBinding()]
param(
    # ====== NETWORK SETTINGS ======
    [string]$InterfaceName   = "Ethernet0",
    [string]$NewIPAddress    = "10.10.14.3",
    [int]$PrefixLength       = 24,
    [string]$DefaultGateway  = "10.10.14.1",
    [string]$DNSServer       = "10.10.14.1",

    # ====== DOMAIN INFO ======
    [string]$DomainName      = "AD.LAB",      # e.g. AD.LAB
    [string]$ComputerName    = "FILES03",

    # ====== DOMAIN CREDENTIALS ======
    [string]$DomainAdminUser = "Administrator",
    [string]$DomainAdminPass = "SecretPassword123",

    # ====== LOCAL ADMIN CREDENTIALS (REQUIRED FOR RENAMING) ======
    [string]$LocalAdminUser  = "LocalUser",
    [string]$LocalAdminPass  = "password123!!",

    # ====== DOMAIN CONTROLLER HOSTNAME ======
    [string]$DCName          = "dc01.ad.lab",

    # ====== TARGET OU DN (OPTIONAL) ======
    [string]$TargetOU        = "OU=DisableDefender\+EnableICMP_Policy,DC=AD,DC=LAB"
)

### 1) Confirm Tamper Protection Disabled
Write-Host "Have you disabled Tamper Protection in Windows Security? (Y/N)"
$tpResponse = Read-Host
if ($tpResponse.ToUpper() -ne "Y") {
    Write-Host "Tamper Protection is not confirmed disabled. Exiting script."
    exit 1
}

### 2) Ensure Script is Running as Administrator
$CurrentUser = [Security.Principal.WindowsIdentity]::GetCurrent()
$AdminRole   = [Security.Principal.WindowsPrincipal]::new($CurrentUser)
if (-not $AdminRole.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "ERROR: This script must be run as Administrator. Right-click PowerShell and choose 'Run as Administrator'."
    exit 1
}

### 3) Build Credential Objects
Write-Host "`n==> Creating Credential Objects..."
$FullDomainUser = "$DomainName\$DomainAdminUser"
$SecurePass     = ConvertTo-SecureString $DomainAdminPass -AsPlainText -Force
$Cred           = New-Object System.Management.Automation.PSCredential($FullDomainUser, $SecurePass)

$LocalSecurePass = ConvertTo-SecureString $LocalAdminPass -AsPlainText -Force
$LocalCred       = New-Object System.Management.Automation.PSCredential($LocalAdminUser, $LocalSecurePass)

### 4) Configure Network Settings
Write-Host "`n==> Configuring network settings for '$InterfaceName'..."
try {
    Set-NetIPInterface -InterfaceAlias $InterfaceName -DHCP Disabled -ErrorAction SilentlyContinue
    
    Get-NetIPAddress -InterfaceAlias $InterfaceName -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Remove-NetIPAddress -Confirm:$false -ErrorAction SilentlyContinue
    
    Get-NetRoute -InterfaceAlias $InterfaceName -ErrorAction SilentlyContinue |
        Where-Object { $_.DestinationPrefix -eq "0.0.0.0/0" } |
        Remove-NetRoute -Confirm:$false -ErrorAction SilentlyContinue
}
catch {
    Write-Host "WARNING: Failed to reset network settings: $($_.Exception.Message)"
}

Write-Host "`n==> Assigning Static IP: $NewIPAddress, Gateway: $DefaultGateway, DNS: $DNSServer..."
try {
    New-NetIPAddress -InterfaceAlias $InterfaceName `
                     -IPAddress $NewIPAddress `
                     -PrefixLength $PrefixLength `
                     -DefaultGateway $DefaultGateway `
                     -ErrorAction Stop

    Set-DnsClientServerAddress -InterfaceAlias $InterfaceName -ServerAddresses $DNSServer -ErrorAction Stop
}
catch {
    Write-Host "ERROR setting IP config: $($_.Exception.Message)"
    exit 1
}

Write-Host "`n==> Waiting for network to stabilize..."
Start-Sleep -Seconds 5

### 5) Connectivity Checks
Write-Host "`n==> Checking connectivity to Domain Controller '$DCName'..."
if (-not (Test-Connection -ComputerName $DCName -Count 2 -Quiet)) {
    Write-Host "ERROR: Cannot reach domain controller '$DCName'. Check network settings."
    exit 1
}

Write-Host "`n==> Checking DNS resolution for Domain '$DomainName'..."
try {
    $ResolveDomain = Resolve-DnsName $DomainName -ErrorAction Stop
    Write-Host "DNS Resolution Successful: $($ResolveDomain.NameHost)"
}
catch {
    Write-Host "ERROR: Failed to resolve '$DomainName'. Check DNS settings."
    exit 1
}

### 6) Rename the Computer (Checkpoint: Skip if name already matches)
Write-Host "`n==> Checking if computer name is already '$ComputerName'..."
if ($env:COMPUTERNAME -eq $ComputerName) {
    Write-Host "Skipping rename - It's already '$ComputerName'."
}
else {
    Write-Host "Renaming computer to '$ComputerName' using local admin credentials..."
    try {
        Rename-Computer -NewName $ComputerName -LocalCredential $LocalCred -Force
        Write-Host "Computer renamed. (Will fully take effect after reboot.)"
    }
    catch {
        Write-Host "ERROR renaming computer: $($_.Exception.Message)"
        exit 1
    }
}

### 7) Join the Domain
Write-Host "`n==> Joining Domain '$DomainName' using '$FullDomainUser' with name '$ComputerName'..."
try {
    Add-Computer -DomainName $DomainName -Credential $Cred -NewName $ComputerName -Force -ErrorAction Stop -WarningAction SilentlyContinue
    Write-Host "Domain join succeeded (pending reboot)."
}
catch {
    Write-Host "ERROR joining domain: $($_.Exception.Message)"
    exit 1
}

### 8) Move Computer Object to Target OU (If Specified)
if (-not [string]::IsNullOrWhiteSpace($TargetOU)) {
    Write-Host "`n==> Attempting to move computer object '$ComputerName' to '$TargetOU'..."
    try {
        Invoke-Command -ComputerName $DCName -Credential $Cred -ScriptBlock {
            param($ComputerToMove, $OUPath)

            Import-Module ActiveDirectory -ErrorAction Stop

            # Validate that the OU exists
            $OU = Get-ADOrganizationalUnit -Filter "DistinguishedName -eq '$OUPath'" -ErrorAction Stop
            if (-not $OU) {
                Write-Host "ERROR: Specified OU '$OUPath' does not exist. Computer will remain in default location."
                exit 1
            }

            # Ensure the computer object exists in AD (using the new name)
            $comp = Get-ADComputer -Filter { Name -eq $ComputerToMove } -ErrorAction SilentlyContinue
            if (-not $comp) {
                Write-Host "ERROR: Computer object '$ComputerToMove' not found in AD. Check AD replication."
                exit 1
            }

            Move-ADObject -Identity $comp.DistinguishedName -TargetPath $OUPath -ErrorAction Stop
            Write-Host "Successfully moved '$ComputerToMove' to OU: $OUPath"
        } -ArgumentList $ComputerName, $TargetOU -ErrorAction Stop
    }
    catch {
        Write-Host "ERROR moving AD object: $($_.Exception.Message)"
        exit 1
    }
}

### 9) Add AD\daniela to Local Administrators
Write-Host "`n==> Adding 'AD\daniela' to the local Administrators group..."
try {
    net localgroup Administrators "AD\daniela" /add
    Write-Host "Command completed. Verifying membership..."

    $localAdmins = net localgroup Administrators | Out-String
    if ($localAdmins -match "AD\\daniela") {
        Write-Host "Successfully verified that 'AD\daniela' is in local Administrators."
    }
    else {
        Write-Host "ERROR: 'AD\daniela' not found in local Administrators after adding."
    }
}
catch {
    Write-Host "ERROR adding 'AD\daniela' to local Administrators group: $($_.Exception.Message)"
}

### 10) Time Sync with Domain Controller
Write-Host "`n==> Syncing time with the domain..."
try {
    w32tm /resync
    Write-Host "Time sync command issued successfully."
}
catch {
    Write-Host "WARNING: Failed to sync time. $($_.Exception.Message)"
}

### 11) Final Instructions, Prompt & Reboot
Write-Host "`n=============================================================="
Write-Host "After joining this member workstation to the domain, on the login screen"
Write-Host "click 'Other User' and enter the credentials: AD\daniela to log in."
Write-Host "=============================================================="

Write-Host "`n==> Press ENTER to reboot and complete domain membership..."
Read-Host
Restart-Computer -Force
