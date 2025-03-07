# ------------------------------------------------------------------------ 
# Setup-BetaService.ps1
# ------------------------------------------------------------------------

# Step 1: Update network connection profiles from Public to Private
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

# Step 2: Enable WinRM (auto-confirm prompts)
winrm quickconfig -q

# Step 3: Create application directory and add a Windows Defender exclusion
$betaDir = "C:\MyApps\Beta Program"
if (-not (Test-Path $betaDir)) {
    New-Item -Path $betaDir -ItemType Directory -Force | Out-Null
}
Add-MpPreference -ExclusionPath "C:\MyApps"

# Step 4: Create betaservice.exe if it does not exist in the current directory
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

# Step 5: Copy betaservice.exe from the current directory to the application directory
Copy-Item -Path (Join-Path (Get-Location) "betaservice.exe") -Destination $betaDir -Force
Write-Host "Copied betaservice.exe to $betaDir."
Set-Location $betaDir

# Step 6: Modify Registry Keys for BetaService
$registryPath = "HKLM:\SYSTEM\CurrentControlSet\Services\BetaService"
New-Item -Path $registryPath -Force | Out-Null
Set-ItemProperty -Path $registryPath -Name ImagePath -Value 'C:\MyApps\Beta Program\betaservice.exe'

# Step 7: Create BetaService using sc.exe
sc.exe create BetaService binPath= "C:\MyApps\Beta Program\betaservice.exe" type= own start= auto

# Step 8: Confirm BetaService status
Get-CimInstance -ClassName Win32_Service | Where-Object { $_.Name -eq "BetaService" }
Get-Service BetaService

# Step 9: Create a Scheduled Task to restart BetaService every minute
schtasks /create /tn "RunBetaServiceEveryMinute" /sc minute /mo 1 /tr "powershell -NoProfile -ExecutionPolicy Bypass -Command Restart-Service BetaService" /ru "NT AUTHORITY\SYSTEM" /f

# Step 10: Create a Scheduled Task to start BetaService on system boot
schtasks /create /tn "StartBetaServiceOnBoot" /sc onstart /tr "powershell.exe -NoProfile -ExecutionPolicy Bypass -Command Restart-Service BetaService" /ru "NT AUTHORITY\SYSTEM" /f

# Step 11: Relay an Email to DEV01 (command saved in PowerShell history)
Write-Host "===== Step 11: Relay an Email to DEV01 ====="
Write-Host "you must run the following command manually in your interactive PowerShell session to capture it in history:"
Write-Host "`nSend-MailMessage -SmtpServer 'MAIL01' -From 'administrator@ad.lab' -To 'daniela@ad.lab' -Subject 'Test SMTP Relay' -Body 'Hello from Windows Server SMTP!'`n"
Write-Host "Copy and paste the above command at the PowerShell prompt, then press ENTER."
