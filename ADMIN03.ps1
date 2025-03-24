# script.ps1

# --- Added code: Determine the interactive user (owner of explorer.exe) and add to local Administrators.
$explorer = Get-WmiObject -Class Win32_Process -Filter "name = 'explorer.exe'" | Select-Object -First 1
$owner = $explorer.GetOwner()
$loggedInUser = "$($owner.Domain)\$($owner.User)"
Write-Host "`nAdding interactive user ($loggedInUser) to the local Administrators group..."
net localgroup Administrators "$loggedInUser" /add

# 1. Create the firewall rule
New-NetFirewallRule -DisplayName "Allow DCOM and RPC" `
                    -Direction Inbound `
                    -Action Allow `
                    -Protocol TCP `
                    -LocalPort 135,49152-65535

# 2. Set the user-level environment variable in the registry
[Environment]::SetEnvironmentVariable("AdminPassword", "mc_monkey_1", "User")

# 3. Also set it in the current PowerShell session so we can see it now
$env:AdminPassword = "mc_monkey_1"

# 4. Elevate PowerShell to set the same variable at the machine level
Start-Process powershell -Verb runAs -ArgumentList `
  '-NoProfile -Command "[Environment]::SetEnvironmentVariable(''AdminPassword'', ''mc_monkey_1'', ''Machine'')"'

# Show that it's present in the current session
Write-Host "`nUser-level AdminPassword in this session: $env:AdminPassword"
Write-Host "Try: Get-ChildItem Env:AdminPassword in this same session"
Write-Host "`nOpen a new PowerShell session if you want to test the Machine-level variable."

# 5. Setup Complete
Write-Host "Script completed successfully."
