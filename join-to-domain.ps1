<#
  1. Save on the WORKSTATION you want to join.
  2. Edit the variables to match your environment.
  3. Run in an elevated PowerShell prompt on the workstation.
#>

[CmdletBinding()]
param(
    # ====== NETWORK SETTINGS ======
    [string]$InterfaceName   = "Ethernet0",
    [string]$NewIPAddress    = "10.10.14.2",
    [int]$PrefixLength       = 24,                  # 24 => 255.255.255.0
    [string]$DefaultGateway  = "10.10.14.1",
    [string]$DNSServer       = "10.10.14.1",

    # ====== DOMAIN INFO ======
    [string]$DomainName      = "AD.LAB",
    [string]$ComputerName    = "FILES02",

    # ====== CREDENTIALS ======
    [string]$DomainAdminUser = "AD\\Administrator",    # e.g. "AD.LAB\\Administrator"
    [string]$DomainAdminPass = "SecretPassword123",    # Replace with real password

    # ====== DOMAIN CONTROLLER HOSTNAME ======
    [string]$DCName          = "dc01.ad.lab",          # Must match DNS name of your DC

    # ====== TARGET OU DN ======
    [string]$TargetOU        = "OU=MyComputers,DC=AD,DC=LAB"
)

### 1) Build the credential object (non-interactive, no prompt)
$SecurePass = ConvertTo-SecureString $DomainAdminPass -AsPlainText -Force
$Cred       = New-Object System.Management.Automation.PSCredential($DomainAdminUser, $SecurePass)

Write-Host "`n[1/6] Disabling DHCP and removing any existing IPv4 addresses/routes on '$InterfaceName'..."
try {
    Set-NetIPInterface -InterfaceAlias $InterfaceName -DHCP Disabled -ErrorAction SilentlyContinue

    # Remove all IPv4 addresses
    Get-NetIPAddress -InterfaceAlias $InterfaceName -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Remove-NetIPAddress -Confirm:$false -ErrorAction SilentlyContinue

    # Remove default routes (0.0.0.0/0) on this interface
    Get-NetRoute -InterfaceAlias $InterfaceName -ErrorAction SilentlyContinue |
        Where-Object { $_.DestinationPrefix -eq '0.0.0.0/0' } |
        Remove-NetRoute -Confirm:$false -ErrorAction SilentlyContinue
}
catch {
    Write-Host "WARNING: An error occurred cleaning interface config: $($_.Exception.Message)"
}

Write-Host "`n[2/6] Assigning new IP $NewIPAddress/$PrefixLength, Gateway $DefaultGateway on '$InterfaceName'..."
try {
    New-NetIPAddress -InterfaceAlias $InterfaceName `
                     -IPAddress $NewIPAddress `
                     -PrefixLength $PrefixLength `
                     -DefaultGateway $DefaultGateway `
                     -ErrorAction Stop

    Set-DnsClientServerAddress -InterfaceAlias $InterfaceName -ServerAddresses $DNSServer -ErrorAction Stop
}
catch {
    Write-Host "ERROR creating new IP config: $($_.Exception.Message)"
    exit 1
}

Write-Host "`n[3/6] Attempting to rename computer to '$ComputerName'..."
try {
    Rename-Computer -NewName $ComputerName -Force -ErrorAction Stop
    Write-Host "Rename operation completed or system already has that name."
}
catch {
    $msg = $_.Exception.Message
    if ($msg -like "*the new name is the same as the current name*") {
        Write-Host "Skipping rename - It's already named '$ComputerName'."
    }
    else {
        Write-Host "ERROR renaming computer: $msg"
        exit 1
    }
}

Write-Host "`n[4/6] Joining Domain '$DomainName' (non-interactive, no prompt)..."
try {
    Add-Computer -DomainName $DomainName -Credential $Cred -Force -ErrorAction Stop
    Write-Host "Domain join command completed successfully."
}
catch {
    Write-Host "ERROR joining domain: $($_.Exception.Message)"
    exit 1
}

Write-Host "`n[5/6] Remotely moving computer object into OU '$TargetOU' on '$DCName'..."
try {
    Invoke-Command -ComputerName $DCName -Credential $Cred -ScriptBlock {
        param($ComputerToMove, $OUPath)
        Import-Module ActiveDirectory
        
        # Try desired name first:
        $comp = Get-ADComputer -Identity $ComputerToMove -ErrorAction SilentlyContinue
        if (-not $comp) {
            # fallback: $env:COMPUTERNAME if rename hasn't fully applied in AD
            $fallback = $env:COMPUTERNAME
            Write-Host "Couldn't find '$ComputerToMove'; trying '$fallback'..."
            $comp = Get-ADComputer -Identity $fallback -ErrorAction Stop
        }
        $dn = $comp.DistinguishedName

        Move-ADObject -Identity $dn -TargetPath $OUPath -ErrorAction Stop
        "Successfully moved '$($comp.Name)' to OU: $OUPath"
    } -ArgumentList $ComputerName, $TargetOU -ErrorAction Stop
}
catch {
    Write-Host "ERROR moving computer in AD: $($_.Exception.Message)"
    exit 1
}

Write-Host "`n[6/6] Rebooting now to finalize domain join..."
try {
    Restart-Computer -Force
}
catch {
    Write-Host "ERROR rebooting: $($_.Exception.Message)"
    exit 1
}
