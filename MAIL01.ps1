# Install SMTP Server Feature
Install-WindowsFeature SMTP-Server -IncludeManagementTools

# Confirm SMTP service installation
Get-Service *smtp*

# Confirm port 25 is listening
netstat -an | findstr ":25"

# Confirm Hostname
([System.Net.Dns]::GetHostByName(($env:COMPUTERNAME))).Hostname

# Set SMTP service to start automatically at boot
Set-Service SMTPSVC -StartupType Automatic

# Manual configuration required
Write-Host @"
==========================================
MANUAL CONFIGURATION REQUIRED IN IIS MANAGER:
Perform the following steps explicitly:

1. Open Server Manager, select "Tools" > "Internet Information Services (IIS) 6.0 Manager"
2. Expand MAIL01 > SMTP Virtual Server #1 > Domains
3. Right-click the domain "MAIL01.ad.lab", select "Rename", enter "local.mail"
4. Right-click under "local.mail", select "New" > "Domain"
5. In the wizard, select "Remote", click "Next", enter "ad.lab", and click "Finish"
6. Right-click "ad.lab", select "Properties", enable:
    - "Allow incoming mail to be relayed to this domain"
    - Select "Forward all mail to smart host"
    - Enter [10.10.14.100] as SmartHost and click "OK"

AFTER completing the above manual steps exactly, press Enter here to continue:
"@
Read-Host "Press Enter once you've completed the above manual steps"

# Restart SMTP service to apply configuration changes
Write-Host "Restarting SMTP service to apply configuration changes..."
try {
    Restart-Service SMTPSVC -Force -ErrorAction Stop
    Write-Host "SMTP service restarted successfully."
}
catch {
    Write-Error "Failed to restart SMTP service. $_"
    exit 1
}

# Explicitly test SMTP Relay configuration
Write-Host "Testing SMTP Relay configuration..."
try {
    Send-MailMessage -SmtpServer "MAIL01" `
        -From "administrator@ad.lab" `
        -To "daniela@ad.lab" `
        -Subject "Test SMTP Relay" `
        -Body "Hello from Windows Server SMTP!"

    Write-Host "SMTP Relay test email sent successfully."
}
catch {
    Write-Error "SMTP Relay test email failed to send. $_"
    exit 1
}

# Setup Complete
Write-Host "Script completed successfully."
