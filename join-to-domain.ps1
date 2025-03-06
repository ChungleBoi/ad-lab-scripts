<#
  Automated Domain Join Script - Fully Fixed
  - Uses a local admin credential for renaming.
  - Ensures the script runs with administrator privileges.
  - Fixes the Rename-Computer issue by running it with local credentials.
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

    # ====== LOCAL ADMIN CREDENTIALS (REQUIRED FOR RENAMING COMPUTER) ======
    [string]$LocalAdminUser = "LocalUser",   # Local Admin Username
    [string]$LocalAdminPass = "password123!!",  # Local Admin Password

    # ====== DOMAIN CONTROLLER HOSTNAME ======
    [string]$DCName          = "dc01.ad.lab",

    # ====== TARGET OU DN ======
    [string]$TargetOU        = "OU=MyComputers,DC=AD,DC=LAB"
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
        Write-Host "Computer renamed successfully. A reboot is required."
        Restart-Computer -Force
        exit 0  # Ensures script stops and runs again after reboot
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

### 7) Move Computer Object to Correct OU
Write-Host "`n==> Moving computer object to '$TargetOU' via '$DCName'..."
try {
    Invoke-Command -ComputerName $DCName -Credential $Cred -ScriptBlock {
        param($ComputerToMove, $OUPath)

        Import-Module ActiveDirectory -ErrorAction Stop

        # Attempt to find by the desired name first
        $comp = Get-ADComputer -Identity $ComputerToMove -ErrorAction SilentlyContinue
        if (-not $comp) {
            $fallback = $env:COMPUTERNAME
            Write-Host "Not found: '$ComputerToMove'; trying '$fallback'..."
            $comp = Get-ADComputer -Identity $fallback -ErrorAction Stop
        }

        Move-ADObject -Identity $comp.DistinguishedName -TargetPath $OUPath -ErrorAction Stop
        Write-Host "Successfully moved '$($comp.Name)' to OU: $OUPath"
    } -ArgumentList $ComputerName, $TargetOU -ErrorAction Stop
}
catch {
    Write-Host "ERROR moving AD object: $($_.Exception.Message)"
    exit 1
}

### 8) Final Reboot
Write-Host "`n==> Rebooting now to complete domain membership..."
try {
    Restart-Computer -Force
}
catch {
    Write-Host "ERROR rebooting: $($_.Exception.Message)"
    exit 1
}
