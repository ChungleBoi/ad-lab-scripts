# ------------------------------------------------------------------------
# Setup-AdminDocs-WinRM.ps1
# ------------------------------------------------------------------------

# 0. Check that Instructions.docx is in the current directory
$docPath = Join-Path (Get-Location) "Instructions.docx"
if (-not (Test-Path $docPath)) {
    Write-Host "Unable to run script. Add 'Instructions.docx' to the current directory first and re-run the script."
    exit
}

# 1. Create C:\AdminDocs folder (if it doesn't already exist)
New-Item -Path "C:\AdminDocs" -ItemType Directory -Force | Out-Null

# 2. Copy Instructions.docx into C:\AdminDocs
Copy-Item -Path $docPath -Destination "C:\AdminDocs" -Force

# 3. Share the folder so only user Gregory can access it
New-SMBShare -Name "AdminDocs" `
             -Path "C:\AdminDocs" `
             -FullAccess "Gregory" `
             -Description "AdminDocs Share" | Out-Null

# Remove any existing "Everyone" access
Revoke-SmbShareAccess -Name "AdminDocs" -AccountName "Everyone" -Force | Out-Null

# 4. Enable PowerShell Remoting (WMI/WinRM setup)
Enable-PSRemoting -Force

# 5. Add 10.10.14.140 to TrustedHosts
Set-Item WSMan:\localhost\Client\TrustedHosts -Value "10.10.14.140" -Force

# 6. Confirm the change
Get-Item WSMan:\localhost\Client\TrustedHosts

# 7. Enable Windows Remote Management through the firewall
netsh advfirewall firewall set rule group="Windows Remote Management" new enable=Yes

Write-Host "Script completed successfully."
