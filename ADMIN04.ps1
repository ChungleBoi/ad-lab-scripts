# OpenFirewallRules.ps1
# This script creates firewall rules to allow inbound TCP traffic on ports 139 and 445.
# Run this script with administrative privileges.

# Create firewall rule for TCP port 139
New-NetFirewallRule -DisplayName "Open Port 139" -Direction Inbound -Protocol TCP -LocalPort 139 -Action Allow

# Create firewall rule for TCP port 445
New-NetFirewallRule -DisplayName "Open Port 445" -Direction Inbound -Protocol TCP -LocalPort 445 -Action Allow
