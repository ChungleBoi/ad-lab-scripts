<#
  Automated Domain Join Script - Fully Updated
  - Uses a local admin credential for renaming.
  - Ensures the script runs with administrator privileges.
  - Fixes the Rename-Computer issue by running it with local credentials.
  - Moves the computer to the correct OU if specified.
  - WAIT for user confirmation before rebooting.
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
    [string]$DomainName      = "AD.LAB",
    [string]$ComputerName    = "FILES03",

    # ====== DOMAIN CREDENTIALS ======
    [string]$DomainAdminUser = "Administrator",
    [string]$DomainAdminPass = "SecretPassword123",

    # ====== LOCAL ADMIN CREDENTIALS (REQUIRED FOR RENAMING) ======
    [string]$LocalAdminUser = "LocalUser",   # Local Admin Username
    [string]$LocalAdminPass = "password123!!",  # Local Admin Password

    # ====== DOMAIN CONTROLLER HOSTNAME ======
    [string]$DCName          = "dc01.ad.lab",

    # ====== TARGET OU DN (OPTIONAL) ======
    [string]$TargetOU        = "OU=DisableSMBSigning+DisableDefender+EnableICMP_Policy,DC=AD,DC=LAB"  # Example: "OU=DisableSMBSigning+DisableDefender+EnableICMP_Policy,DC=AD,DC=LAB"
)

### 1) Ensure Script is Running as Administrator
$CurrentUser = [Security.Principal.WindowsIdentity]::GetCurrent()
$AdminRole = [Security.Principal.WindowsPrincipal]::new($CurrentUser)
if (-not $AdminRole.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "ERROR: This script must be run as Administrator. Right-click PowerShell and choose 'Run as Administrator'."
    exit 1
}

### 2) Build Credential Objects
Write-Host "`n==> Creating Credential Objects..."
$FullDomainUser = "$DomainName\$DomainAdminUser"
$SecurePass = ConvertTo-SecureString $DomainAdminPass -AsPlainText -Force
$Cred = New-Object System.Management.Automation.PSCredential($FullDomainUser, $SecurePass)

$LocalSecurePass = ConvertTo-SecureString $LocalAdminPass -AsPlainText -Force
$LocalCred = New-Object System.Management.Automation.PSCredential($LocalAdminUser, $LocalSecurePass)

### 3) Remove Existing IP and Set Static IP
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

### 4) Ensure Network is Stabilized
Write-Host "`n==> Waiting for network to stabilize..."
Start-Sleep -Seconds 5

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

### 5) Rename Computer Using Local Admin Account
Write-Host "`n==> Renaming computer to '$ComputerName'..."
try {
    $CurrentName = $env:COMPUTERNAME
    if ($CurrentName -eq $ComputerName) {
        Write-Host "Skipping rename - It's already '$ComputerName'."
    }
    else {
        Start-Process -FilePath "powershell.exe" -Credential $LocalCred -ArgumentList "-Command Rename-Computer -NewName $ComputerName -Force" -NoNewWindow -Wait
        Write-Host "Computer renamed successfully."
    }
}
catch {
    Write-Host "ERROR renaming computer: $($_.Exception.Message)"
    exit 1
}

### 6) Join Domain (Runs After Reboot)
Write-Host "`n==> Joining Domain '$DomainName' using '$FullDomainUser'..."
try {
    Add-Computer -DomainName $DomainName -Credential $Cred -Force -ErrorAction Stop
    Write-Host "Domain join succeeded."
}
catch {
    Write-Host "ERROR joining domain: $($_.Exception.Message)"
    exit 1
}

### 7) Move Computer Object to Correct OU (If Specified)
if (-not [string]::IsNullOrWhiteSpace($TargetOU)) {
    Write-Host "`n==> Moving computer object to '$TargetOU' via '$DCName'..."
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

            # Ensure the computer object exists in AD
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

### 8) Wait for User Confirmation Before Reboot
Write-Host "`n==> Press ENTER to reboot and complete domain membership..."
Read-Host
Restart-Computer -Force
