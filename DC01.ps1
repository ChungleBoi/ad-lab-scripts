###############################################################################
# FINAL WORKAROUND SCRIPT USING New-GPLink
#  1. Creates OUs & GPOs with simpler names (no plus signs).
#  2. Uses New-GPLink to link them.
#  3. Configures SMB signing off (2nd GPO), disables Defender, enables ICMP.
#  4. Renames OUs & GPOs to final plus-sign names.
###############################################################################

$CheckpointFile = "C:\DC-Setup-Checkpoint.txt"

# If this is the first run (checkpoint file doesn't exist), prompt the user.
if (-not (Test-Path $CheckpointFile)) {
    Read-Host "Ensure you only have one Network Adapter in VMWare (set to VMNet1). Press ENTER to confirm."
    Read-Host "This script will reboot your device several times. Continue running the script after your computer reboots. When the setup is complete, the script will output 'Setup Complete'. Press ENTER to confirm."
}

function Set-Checkpoint($step) {
    $step | Out-File -FilePath $CheckpointFile -Force
}
function Get-Checkpoint {
    if (Test-Path $CheckpointFile) {
        return Get-Content -Path $CheckpointFile -ErrorAction SilentlyContinue
    } else {
        return 0
    }
}

$currentStep = [int](Get-Checkpoint)
Write-Host "Current checkpoint is: $currentStep"

# --------------------------------------------------------------------------------
# STEP 1: SET STATIC IP
# --------------------------------------------------------------------------------
if ($currentStep -lt 1) {
    Write-Host "`n[Step 1] Setting static IP (Ethernet0 -> 10.10.14.1/24)..."
    Remove-NetIPAddress -InterfaceAlias "Ethernet0" -Confirm:$false -ErrorAction SilentlyContinue | Out-Null
    New-NetIPAddress -InterfaceAlias "Ethernet0" -IPAddress "10.10.14.1" -PrefixLength 24 -ErrorAction Stop
    Set-DnsClientServerAddress -InterfaceAlias "Ethernet0" -ServerAddresses "10.10.14.1"

    Set-Checkpoint 1
    Write-Host "Step 1 complete. Re-run script to proceed."
    return
}


# --------------------------------------------------------------------------------
# STEP 2: RENAME COMPUTER -> DC01, REBOOT
# --------------------------------------------------------------------------------
if ($currentStep -lt 2) {
    if ($env:COMPUTERNAME -eq "DC01") {
        Write-Host "[Step 2] Already named DC01. Skipping rename."
        Set-Checkpoint 2
    }
    else {
        Write-Host "`n[Step 2] Renaming computer to DC01..."
        Rename-Computer -NewName "DC01" -Force
        Set-Checkpoint 2
        Write-Host "Rebooting..."
        Restart-Computer -Force
    }
    return
}


# --------------------------------------------------------------------------------
# STEP 3: INSTALL AD DS + DNS
# --------------------------------------------------------------------------------
if ($currentStep -lt 3) {
    Write-Host "`n[Step 3] Installing AD DS + DNS..."
    Install-WindowsFeature -Name AD-Domain-Services -IncludeManagementTools -ErrorAction Stop
    Install-WindowsFeature -Name DNS -IncludeManagementTools -ErrorAction Stop

    Set-Checkpoint 3
    Write-Host "Step 3 complete. Re-run script to proceed."
    return
}


# --------------------------------------------------------------------------------
# STEP 4: PROMOTE TO DC (ad.lab), REBOOT
# --------------------------------------------------------------------------------
if ($currentStep -lt 4) {
    Write-Host "`n[Step 4] Promoting to DC (new forest ad.lab)..."

    $safeMode = ConvertTo-SecureString "P@ssw0rd123" -AsPlainText -Force

    Install-ADDSForest `
        -DomainName "ad.lab" `
        -DomainNetbiosName "AD" `
        -SafeModeAdministratorPassword $safeMode `
        -InstallDNS:$true `
        -NoRebootOnCompletion:$false `
        -Force:$true

    Write-Host "Domain promotion complete, server will reboot."
    Set-Checkpoint 4
    return
}


# --------------------------------------------------------------------------------
# STEP 5: CREATE SELF-SIGNED CERT -> NTDS
# --------------------------------------------------------------------------------
if ($currentStep -lt 5) {
    Write-Host "`n[Step 5] Creating self-signed cert for dc01.ad.lab & assigning to NTDS..."

    $cert = New-SelfSignedCertificate `
        -DnsName "dc01.ad.lab" `
        -CertStoreLocation "Cert:\LocalMachine\My" `
        -KeyUsage DigitalSignature, KeyEncipherment `
        -KeySpec KeyExchange `
        -TextExtension "2.5.29.37={text}1.3.6.1.5.5.7.3.1,1.3.6.1.5.5.7.3.2"

    $thumb = $cert.Thumbprint
    Write-Host "Cert Thumbprint: $thumb"

    Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Services\NTDS\Parameters" -Name "Certificate" -Value $thumb

    $container = $cert.PrivateKey.CspKeyContainerInfo.UniqueKeyContainerName
    $keyPath   = "$($env:ProgramData)\Microsoft\Crypto\RSA\MachineKeys"
    $keyFile   = Get-ChildItem -Path $keyPath | Where-Object { $_.Name -like "*$container*" }
    icacls $keyFile.FullName /grant "NT AUTHORITY\SYSTEM:R" | Out-Null

    Write-Host "Private key ACL updated."

    Set-Checkpoint 5
    Write-Host "Step 5 complete. Re-run script to proceed."
    return
}


# --------------------------------------------------------------------------------
# STEP 6: IMPORT CERT INTO TRUSTED ROOT
# --------------------------------------------------------------------------------
if ($currentStep -lt 6) {
    Write-Host "`n[Step 6] Importing cert to Trusted Root..."

    $cert = Get-ChildItem "Cert:\LocalMachine\My" | Where-Object { $_.Subject -like "*dc01.ad.lab*" }
    if (-not $cert) {
        Write-Warning "No certificate found matching dc01.ad.lab"
    }
    else {
        $exportPath = "C:\dc01_certificate.cer"
        Export-Certificate -Cert $cert -FilePath $exportPath | Out-Null
        Import-Certificate -FilePath $exportPath -CertStoreLocation "Cert:\LocalMachine\Root" | Out-Null
        Write-Host "Cert imported to Trusted Root."
    }

    Set-Checkpoint 6
    Write-Host "Step 6 complete. Re-run script to proceed."
    return
}


# --------------------------------------------------------------------------------
# STEP 7: CREATE AD USERS
# --------------------------------------------------------------------------------
if ($currentStep -lt 7) {
    Write-Host "`n[Step 7] Creating AD users..."

    function Create-ADUserIfMissing($Name, $Sam, $UPN, $Password) {
        $exists = Get-ADUser -Filter "SamAccountName -eq '$Sam'" -ErrorAction SilentlyContinue
        if ($exists) {
            Write-Host "User '$Sam' already exists."
        } else {
            Write-Host "Creating user '$Sam'..."
            New-ADUser `
                -Name $Name `
                -SamAccountName $Sam `
                -UserPrincipalName $UPN `
                -Path "CN=Users,DC=ad,DC=lab" `
                -AccountPassword (ConvertTo-SecureString $Password -AsPlainText -Force) `
                -Enabled $true
        }
    }

    Create-ADUserIfMissing "Aaron"      "Aaron"      "aaron@ad.lab"      "tt.r.2006"
    Create-ADUserIfMissing "Betty"      "Betty"      "betty@ad.lab"      "pinky.1995"
    Create-ADUserIfMissing "Chris"      "Chris"      "chris@ad.lab"      "abcABC123!@#"
    Create-ADUserIfMissing "Daniela"    "Daniela"    "daniela@ad.lab"    "c/o2010"
    Create-ADUserIfMissing "Ernesto"    "Ernesto"    "ernesto@ad.lab"    "lucky#1"
    Create-ADUserIfMissing "Francesca"  "Francesca"  "francesca@ad.lab"  "bubbelinbunny_1"
    Create-ADUserIfMissing "Gregory"    "Gregory"    "gregory@ad.lab"    "mc_monkey_1"
    Create-ADUserIfMissing "Helen"      "Helen"      "helen@ad.lab"      "chase#1"
    Create-ADUserIfMissing "Issac"      "Issac"      "issac@ad.lab"      "passw0rd!!"
    Create-ADUserIfMissing "Jamie"      "Jamie"      "jamie@ad.lab"      "digital99.3"
    Create-ADUserIfMissing "iis_service" "iis_service" "iis_service@ad.lab" "daisy_3"

    Set-Checkpoint 7
    Write-Host "Step 7 complete. Re-run script to proceed."
    return
}


# --------------------------------------------------------------------------------
# STEP 8: SET SPN FOR iis_service
# --------------------------------------------------------------------------------
if ($currentStep -lt 8) {
    Write-Host "`n[Step 8] Setting SPN for iis_service..."

    setspn -S "HTTP/web02.ad.lab" "AD\iis_service" | Out-Null
    Write-Host "SPN set. Checking with setspn -L AD\iis_service..."
    setspn -L "AD\iis_service"

    Set-Checkpoint 8
    Write-Host "Step 8 complete. Re-run script to proceed."
    return
}


# --------------------------------------------------------------------------------
# STEP 9: ADJUST AD USERS (Ernesto no preauth, Jamie -> Domain Admins)
# --------------------------------------------------------------------------------
if ($currentStep -lt 9) {
    Write-Host "`n[Step 9] Adjusting AD user properties..."

    $ernesto = Get-ADUser -Identity "Ernesto" -Properties userAccountControl
    $uac = $ernesto.userAccountControl -bor 4194304  # 4194304 = DONT_REQUIRE_PREAUTH
    Set-ADUser -Identity "Ernesto" -Replace @{userAccountControl = $uac}

    Add-ADGroupMember -Identity "Domain Admins" -Members "Jamie"

    Set-Checkpoint 9
    Write-Host "Step 9 complete. Re-run script to proceed."
    return
}


# --------------------------------------------------------------------------------
# Function to disable Defender in a GPO
# (Ensures "Allow antimalware service to startup with normal priority" is disabled)
# --------------------------------------------------------------------------------
function Disable-Defender($gpoName) {
    # Disable AntiSpyware
    Set-GPRegistryValue -Name $gpoName `
        -Key "HKLM\SOFTWARE\Policies\Microsoft\Windows Defender" `
        -ValueName "DisableAntiSpyware" -Type DWord -Value 1

    # Disable "Allow antimalware service to startup with normal priority"
    New-Item -Path "HKLM\SOFTWARE\Policies\Microsoft\Windows Defender\Real-Time Protection" -Force -ErrorAction SilentlyContinue | Out-Null
    Set-GPRegistryValue -Name $gpoName `
        -Key "HKLM\SOFTWARE\Policies\Microsoft\Windows Defender\Real-Time Protection" `
        -ValueName "DisableMsSenseStartupNormalPriority" -Type DWord -Value 1

    # ServiceKeepAlive -> 0
    Set-GPRegistryValue -Name $gpoName `
        -Key "HKLM\SOFTWARE\Policies\Microsoft\Windows Defender" `
        -ValueName "ServiceKeepAlive" -Type DWord -Value 0

    # Disable real-time monitoring
    Set-GPRegistryValue -Name $gpoName `
        -Key "HKLM\SOFTWARE\Policies\Microsoft\Windows Defender\Real-Time Protection" `
        -ValueName "DisableRealtimeMonitoring" -Type DWord -Value 1
}


# --------------------------------------------------------------------------------
# STEP 10: CREATE OUs/GPOs w/ simpler names, LINK via New-GPLink, THEN rename
# --------------------------------------------------------------------------------
if ($currentStep -lt 10) {
    Write-Host "`n[Step 10] Creating simpler OUs/GPOs, linking them, then renaming to plus-sign names..."
    Import-Module GroupPolicy -ErrorAction Stop

    # OUs with simpler names (no plus signs)
    $tempOuName1 = "DisableDefender_And_EnableICMP_Policy"
    $tempOuName2 = "DisableSMBSigning_DisableDefender_EnableICMP_Policy"

    # If they don't exist, create them
    if (-not (Get-ADOrganizationalUnit -LDAPFilter "(ou=$tempOuName1)" -ErrorAction SilentlyContinue)) {
        New-ADOrganizationalUnit -Name $tempOuName1 -Path "DC=ad,DC=lab" | Out-Null
    }
    if (-not (Get-ADOrganizationalUnit -LDAPFilter "(ou=$tempOuName2)" -ErrorAction SilentlyContinue)) {
        New-ADOrganizationalUnit -Name $tempOuName2 -Path "DC=ad,DC=lab" | Out-Null
    }

    # Grab their DNs
    $ou1DN = (Get-ADOrganizationalUnit -LDAPFilter "(ou=$tempOuName1)").DistinguishedName
    $ou2DN = (Get-ADOrganizationalUnit -LDAPFilter "(ou=$tempOuName2)").DistinguishedName

    Write-Host "Temporary OU1 DN: $ou1DN"
    Write-Host "Temporary OU2 DN: $ou2DN"

    # GPOs with simpler names
    $tempGpoName1 = "DisableDefender_And_EnableICMP_Policy"
    $tempGpoName2 = "DisableSMBSigning_DisableDefender_EnableICMP_Policy"

    # Create them if missing
    if (-not (Get-GPO -Name $tempGpoName1 -ErrorAction SilentlyContinue)) {
        New-GPO -Name $tempGpoName1 | Out-Null
    }
    if (-not (Get-GPO -Name $tempGpoName2 -ErrorAction SilentlyContinue)) {
        New-GPO -Name $tempGpoName2 | Out-Null
    }

    # Link them forcibly using New-GPLink
    New-GPLink -Name $tempGpoName1 -Target $ou1DN -LinkEnabled Yes | Out-Null
    New-GPLink -Name $tempGpoName2 -Target $ou2DN -LinkEnabled Yes | Out-Null

    # ----------------------------------------------------------------------------
    # SMB signing OFF in the 2nd GPO (both "always" & "if client agrees")
    # Note: This *does* disable SMB signing. But it may show up under "Extra Registry
    # Settings" in the GPO Editor, rather than in Security Options with "Disabled."
    # That's normal with Set-GPRegistryValue.
    # ----------------------------------------------------------------------------
    Set-GPRegistryValue -Name $tempGpoName2 `
        -Key "HKLM\SYSTEM\CurrentControlSet\Services\LanmanServer\Parameters" `
        -ValueName "RequireSecuritySignature" -Type DWord -Value 0

    Set-GPRegistryValue -Name $tempGpoName2 `
        -Key "HKLM\SYSTEM\CurrentControlSet\Services\LanmanServer\Parameters" `
        -ValueName "EnableSecuritySignature" -Type DWord -Value 0

    # Disable Defender in both
    Disable-Defender $tempGpoName1
    Disable-Defender $tempGpoName2

    # Enable ICMP inbound on both GPOs
    $domainFQDN = "ad.lab"
    $store1 = "$domainFQDN\$tempGpoName1"
    $store2 = "$domainFQDN\$tempGpoName2"

    New-NetFirewallRule -Name "Allow ICMP (Ping)" -DisplayName "Allow ICMP (Ping)" -Protocol ICMPv4 -IcmpType 8 -Action Allow -Profile Domain,Private -PolicyStore $store1 -ErrorAction SilentlyContinue | Out-Null
    New-NetFirewallRule -Name "Allow ICMP (Ping)" -DisplayName "Allow ICMP (Ping)" -Protocol ICMPv4 -IcmpType 8 -Action Allow -Profile Domain,Private -PolicyStore $store2 -ErrorAction SilentlyContinue | Out-Null

    # Rename OUs to have plus signs
    Rename-ADObject -Identity $ou1DN -NewName "DisableDefender+EnableICMP_Policy"
    Rename-ADObject -Identity $ou2DN -NewName "DisableSMBSigning+DisableDefender+EnableICMP_Policy"

    # Rename GPOs to have plus signs
    Rename-GPO -Name $tempGpoName1 -TargetName "DisableDefender+EnableICMP_Policy"
    Rename-GPO -Name $tempGpoName2 -TargetName "DisableSMBSigning+DisableDefender+EnableICMP_Policy"

    Write-Host "`n[Step 10] OUs & GPOs created/linked with simpler names, then renamed to plus-sign names."
    Set-Checkpoint 10
    Write-Host "Setup Complete. You may now add a NAT network adapter."
    return
}

# --------------------------------------------------------------------------------
# STEP 11: DISABLE WINDOWS FIREWALL
# --------------------------------------------------------------------------------
if ($currentStep -lt 11) {
    Write-Host "`n[Step 11] Disabling Windows Firewall on all profiles (Domain, Private, Public)..."

    Set-NetFirewallProfile -Profile Domain,Public,Private -Enabled False

    Set-Checkpoint 11
    Write-Host "Step 11 complete. Windows Firewall is now disabled on all profiles."
    Write-Host "Setup Fully Complete."
    return
}
