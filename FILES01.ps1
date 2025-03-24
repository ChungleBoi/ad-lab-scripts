# ------------------------------------------------------------------------
# Setup-DomainAdminsShare.ps1
# ------------------------------------------------------------------------

# --- Added code: Determine the interactive user (owner of explorer.exe) and add to local Administrators.
$explorer = Get-WmiObject -Class Win32_Process -Filter "name = 'explorer.exe'" | Select-Object -First 1
$owner = $explorer.GetOwner()
$loggedInUser = "$($owner.Domain)\$($owner.User)"
Write-Host "`nAdding interactive user ($loggedInUser) to the local Administrators group..."
net localgroup Administrators "$loggedInUser" /add

# 4. Open SMB Ports (139 and 445)
Write-Host "`nOpening SMB Ports (139 and 445)..."
New-NetFirewallRule -DisplayName "Open Port 139" -Direction Inbound -Protocol TCP -LocalPort 139 -Action Allow
New-NetFirewallRule -DisplayName "Open Port 445" -Direction Inbound -Protocol TCP -LocalPort 445 -Action Allow

# 5. Create and Configure Share for Domain Admins
Write-Host "`nCreating folder C:\DomainAdminsShare..."
New-Item -Path "C:\DomainAdminsShare" -ItemType Directory -Force | Out-Null

Write-Host "Creating share for DomainAdminsShare..."
# Create the share using net share (adjust if you prefer New-SmbShare)
net share DomainAdminsShare="C:\DomainAdminsShare" /GRANT:"Domain Admins",FULL

Write-Host "Creating flag.txt in C:\DomainAdminsShare..."
Set-Content -Path "C:\DomainAdminsShare\flag.txt" -Value "H@6K3RS3C101TheKing!@#$"

# 6. Limit access to the flag.txt to only Domain Admins
Write-Host "`nRemoving inheritance from flag.txt..."
icacls "C:\DomainAdminsShare\flag.txt" /inheritance:r

Write-Host "Removing access for Everyone, BUILTIN\Administrators, and BUILTIN\Users from flag.txt..."
icacls "C:\DomainAdminsShare\flag.txt" /remove:g "Everyone" "BUILTIN\Administrators" "BUILTIN\Users"

Write-Host "Granting Domain Admins full control on flag.txt..."
icacls "C:\DomainAdminsShare\flag.txt" /grant "AD\Domain Admins:(F)"

Write-Host "`nVerifying ACL for flag.txt..."
icacls "C:\DomainAdminsShare\flag.txt"

# 7. Setup Complete
Write-Host "`nScript completed successfully."
