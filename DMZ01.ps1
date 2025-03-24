# ------------------------------------------------------------------------ 
# Setup-BetaService.ps1
# ------------------------------------------------------------------------

# --- Added code: Determine the interactive user (owner of explorer.exe) and add to local Administrators.
$explorer = Get-WmiObject -Class Win32_Process -Filter "name = 'explorer.exe'" | Select-Object -First 1
$owner = $explorer.GetOwner()
$loggedInUser = "$($owner.Domain)\$($owner.User)"
Write-Host "`nAdding interactive user ($loggedInUser) to the local Administrators group..."
net localgroup Administrators "$loggedInUser" /add
net localgroup "Remote Management Users" betty /add

Write-Host "===== Step 1: Update network connection profiles from Public to Private =====" -ForegroundColor Cyan

function Wait-ForNetworkIdentification {
    param(
        [Parameter(Mandatory = $true)]
        [string]$InterfaceAlias,
        [int]$TimeoutSeconds = 60
    )
    $startTime = Get-Date
    while ($true) {
        $profile = Get-NetConnectionProfile -InterfaceAlias $InterfaceAlias -ErrorAction SilentlyContinue
        if ($profile -and ($profile.NetworkCategory -ne 'Unknown' -and $profile.NetworkCategory -ne 'Identifying')) {
            return $true
        }
        if ((Get-Date) -gt $startTime.AddSeconds($TimeoutSeconds)) {
            Write-Error "Timeout waiting for network identification on interface $InterfaceAlias"
            return $false
        }
        Start-Sleep -Seconds 2
    }
}

$publicProfiles = Get-NetConnectionProfile | Where-Object { $_.NetworkCategory -eq 'Public' }
if ($publicProfiles) {
    foreach ($profile in $publicProfiles) {
        if (-not (Wait-ForNetworkIdentification -InterfaceAlias $profile.InterfaceAlias -TimeoutSeconds 60)) {
            Write-Error "Network identification did not complete for interface '$($profile.InterfaceAlias)'. Exiting script."
            return
        }
        Write-Host "Changing network profile for interface '$($profile.InterfaceAlias)' from Public to Private."
        try {
            Set-NetConnectionProfile -InterfaceAlias $profile.InterfaceAlias -NetworkCategory Private
        }
        catch {
            Write-Error "Failed to change network category for interface '$($profile.InterfaceAlias)': $_"
            return
        }
    }
}
else {
    Write-Host "No Public network profiles found. Proceeding..."
}
Start-Sleep 1

Write-Host "`n===== Step 2: Enable WinRM (auto-confirm prompts) =====" -ForegroundColor Cyan
winrm quickconfig -q
Start-Sleep 1

Write-Host "`n===== Step 3: Create application directory and add a Windows Defender exclusion =====" -ForegroundColor Cyan
$betaDir = "C:\MyApps\Beta Program"
if (-not (Test-Path $betaDir)) {
    New-Item -Path $betaDir -ItemType Directory -Force | Out-Null
}
Start-Sleep 1

Write-Host "`n===== Step 4: Create betaservice.exe if it does not exist in the current directory =====" -ForegroundColor Cyan
$exeSource = Join-Path (Get-Location) "betaservice.exe"
if (-not (Test-Path $exeSource)) {
    Write-Host "betaservice.exe not found in the current directory. Creating betaservice.exe..."
    
    # Create a temporary C# source file for BetaService
    $betaSource = @"
using System;
using System.ServiceProcess;

public class BetaService : ServiceBase {
    public static void Main() {
        ServiceBase.Run(new BetaService());
    }
    public BetaService() {
        this.ServiceName = "BetaService";
    }
    protected override void OnStart(string[] args) {
        // TODO: Add service start code here.
    }
    protected override void OnStop() {
        // TODO: Add service stop code here.
    }
}
"@
    $csFile = Join-Path (Get-Location) "betaservice.cs"
    $betaSource | Out-File -FilePath $csFile -Encoding ASCII
    
    # Locate the C# compiler (csc.exe)
    $cscPath = "C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe"
    if (-not (Test-Path $cscPath)) {
        Write-Host "csc.exe not found at $cscPath. Trying system path..."
        $cscPath = "csc.exe"
    }
    
    # Compile the C# code to create betaservice.exe
    & $cscPath /nologo /target:exe /out:"betaservice.exe" $csFile
    
    if (Test-Path "betaservice.exe") {
        Write-Host "betaservice.exe created successfully."
    }
    else {
        Write-Error "Failed to create betaservice.exe."
        return
    }
    
    # Clean up temporary source file
    Remove-Item $csFile -Force
}
else {
    Write-Host "betaservice.exe found in the current directory. Proceeding..."
}
Start-Sleep 1

Write-Host "`n===== Step 5: Move betaservice.exe to the application directory =====" -ForegroundColor Cyan
Move-Item -Path $exeSource -Destination $betaDir -Force
Write-Host "Moved betaservice.exe to $betaDir."
Set-Location $betaDir
Start-Sleep 1

Write-Host "`n===== Step 6: Modify Registry Keys for BetaService =====" -ForegroundColor Cyan
$registryPath = "HKLM:\SYSTEM\CurrentControlSet\Services\BetaService"
New-Item -Path $registryPath -Force | Out-Null
Set-ItemProperty -Path $registryPath -Name ImagePath -Value 'C:\MyApps\Beta Program\betaservice.exe'
Start-Sleep 1

Write-Host "`n===== Step 7: Create BetaService using sc.exe =====" -ForegroundColor Cyan
sc.exe create BetaService binPath= "C:\MyApps\Beta Program\betaservice.exe" type= own start= auto
Start-Sleep 1

Write-Host "`n===== Step 8: Confirm BetaService status =====" -ForegroundColor Cyan
Get-CimInstance -ClassName Win32_Service | Where-Object { $_.Name -eq "BetaService" } | Out-Host
Get-Service BetaService | Out-Host
Start-Sleep 1

Write-Host "`n===== Step 9: Create a Scheduled Task to restart BetaService every minute =====" -ForegroundColor Cyan
schtasks /create /tn "RunBetaServiceEveryMinute" /sc minute /mo 1 /tr "powershell -NoProfile -ExecutionPolicy Bypass -Command Restart-Service BetaService" /ru "NT AUTHORITY\SYSTEM" /f
Start-Sleep 1

Write-Host "`n===== Step 10: Create a Scheduled Task to start BetaService on system boot =====" -ForegroundColor Cyan
schtasks /create /tn "StartBetaServiceOnBoot" /sc onstart /tr "powershell.exe -NoProfile -ExecutionPolicy Bypass -Command Restart-Service BetaService" /ru "NT AUTHORITY\SYSTEM" /f
Start-Sleep 1

Write-Host "`n===== Step 11: Defender exclusion =====" -ForegroundColor Cyan
try {
    Add-MpPreference -ExclusionPath "C:\MyApps" -ErrorAction Stop
    Write-Host "Action Needed: Confirm the Windows Defender Exclusion for C:\MyApps"
}
catch {
    Write-Host "Unable to add Windows Defender Exclusion. Give Windows Security (Virus and Threat Protection) some more time to startup. Once it is started, run: Add-MpPreference -ExclusionPath 'C:\MyApps'" -ForegroundColor Yellow
}

# =========================
# FINAL STEP
# =========================
Write-Host "`n===== Step 12: Relay an Email to DEV01 (final step) =====" -ForegroundColor Magenta
Write-Host "Run the following command manually in your interactive PowerShell session" -ForegroundColor Magenta
Write-Host "" -ForegroundColor Magenta
Write-Host "Send-MailMessage -SmtpServer 'MAIL01' -From 'administrator@ad.lab' -To 'daniela@ad.lab' -Subject 'Test SMTP Relay' -Body 'Hello from Windows Server SMTP!'" -ForegroundColor Yellow
Write-Host "" -ForegroundColor Magenta
Write-Host "Copy and paste the above command at your PowerShell prompt, then press ENTER." -ForegroundColor Magenta
Write-Host "This ensures it appears in your PSReadLine console history." -ForegroundColor Magenta

# ------------------- Step 13. Script Complete -------------------
Write-Host "Script completed successfully."
