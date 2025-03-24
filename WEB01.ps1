# ============================================================
# Deploy_XAMPP_LoginSystem_Setup.ps1 (Updated)
#
# This updated script automates parts of the XAMPP login system setup,
# configures Apache and MySQL to run as Windows services at startup
# under the 'aaron' user account (instead of NT AUTHORITY\SYSTEM),
# and pre-validates/fixes the Apache configuration as well as grants the
# necessary “Log on as a service” right to the user.
#
# NOTE: Run this script as Administrator.
# ============================================================

# Function to pause for manual step confirmation.
function Confirm-ManualStep($stepDescription) {
    Write-Host ""
    Write-Host "MANUAL STEP REQUIRED: $stepDescription" -ForegroundColor Yellow
    do {
        $response = Read-Host "After completing the above step, type 'Y' to continue"
    } while ($response -notin @("Y", "y"))
    Write-Host ""
}

# Function to test Apache configuration
function Check-ApacheConfig {
    $httpdExe = "C:\xampp\apache\bin\httpd.exe"
    Write-Host "Testing Apache configuration using: $httpdExe -t"
    $testOutput = & $httpdExe -t 2>&1
    Write-Host "Apache config test output:" $testOutput
    return $testOutput
}

# Function to fix Apache configuration errors (e.g. missing ServerName)
function Fix-ApacheConfig {
    $httpdConfPath = "C:\xampp\apache\conf\httpd.conf"
    if (Test-Path $httpdConfPath) {
        Write-Host "Reviewing $httpdConfPath for ServerName directive..."
        $confContent = Get-Content $httpdConfPath
        $hasServerName = $false
        foreach ($line in $confContent) {
            if ($line -match "^\s*ServerName\s+") {
                $hasServerName = $true
                break
            }
        }
        if (-not $hasServerName) {
            Write-Host "ServerName directive not found in httpd.conf. Appending 'ServerName localhost'..."
            Add-Content -Path $httpdConfPath -Value "`nServerName localhost`n"
        }
        else {
            # If found but commented, attempt to uncomment it.
            $confContentModified = $confContent -replace "^\s*#\s*(ServerName\s+.+)", '$1'
            Set-Content -Path $httpdConfPath -Value $confContentModified -Encoding UTF8
            Write-Host "Uncommented any commented ServerName directive in httpd.conf."
        }
    }
    else {
        Write-Error "httpd.conf not found at $httpdConfPath. Exiting."
        exit
    }
}

# Function to grant "Log on as a service" right to a user account.
function Grant-LogonAsServiceRight {
    param(
        [Parameter(Mandatory=$true)]
        [string]$Account
    )
    Write-Host "Granting 'Log on as a service' right to $Account..."
    $tempInf = "$env:TEMP\temp.inf"
    $tempSdb = "$env:TEMP\temp.sdb"
    # Export current security settings to a temp file.
    secedit /export /cfg $tempInf | Out-Null
    $content = Get-Content $tempInf
    $modifiedContent = $content | ForEach-Object {
        if ($_ -match "^SeServiceLogonRight") {
            if ($_ -notmatch $Account) {
                if ($_ -match "=") {
                    $_ = $_ + ",$Account"
                }
                else {
                    $_ = "SeServiceLogonRight = $Account"
                }
            }
        }
        $_
    }
    $modifiedContent | Set-Content $tempInf
    # Reapply the modified security settings.
    secedit /configure /db $tempSdb /cfg $tempInf /areas USER_RIGHTS | Out-Null
    Remove-Item $tempInf, $tempSdb -Force
    Write-Host "'Log on as a service' right granted to $Account."
}

# --- Ensure the script is running with elevated privileges ---
if (-not ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")) {
    Write-Error "This script must be run as Administrator. Exiting."
    exit
}

# ------------------- Step 4: Check for Existing XAMPP Services -------------------
$apacheService = Get-Service -Name "Apache2.4" -ErrorAction SilentlyContinue
$mysqlService = Get-Service -Name "mysql" -ErrorAction SilentlyContinue

if ($apacheService -and $mysqlService) {
    Write-Host "XAMPP services are already installed. Skipping installation steps."
} else {
    # ------------------- Verify XAMPP Installation -------------------
    while (-not ((Test-Path "C:\xampp\apache\bin\httpd.exe") -and (Test-Path "C:\xampp\mysql\bin\mysqld.exe"))) {
        Confirm-ManualStep "Install XAMPP for Windows:
a. Go to: https://www.apachefriends.org/
b. Click 'XAMPP for Windows' (the download may take a while to get started. Be patient).
c. Double-click the XAMPP installer in the Downloads folder (this may take a while, be patient).
d. Click 'Next' to choose the default options in the installer and confirm the UAC prompt that appears.
Please ensure XAMPP is properly installed before continuing."
    }

    # ------------------- Pre-check and Fix Apache Configuration -------------------
    $apacheTest = Check-ApacheConfig
    if ($apacheTest -notmatch "Syntax OK") {
        Write-Host "Apache configuration errors detected. Attempting automatic fix..."
        Fix-ApacheConfig
        # Re-test configuration
        $apacheTest = Check-ApacheConfig
        if ($apacheTest -notmatch "Syntax OK") {
            Write-Error "Apache configuration still has errors after automatic fix. Please review httpd.conf manually."
            exit
        }
    }
    else {
        Write-Host "Apache configuration syntax is OK."
    }

    # ------------------- Grant 'Log on as a service' Right to ad\aaron -------------------
    Grant-LogonAsServiceRight -Account "ad\aaron"

    # ------------------- Step 5: Enable Apache and MySQL at Startup -------------------
    Write-Host "Installing Apache service..."
    & "C:\xampp\apache\bin\httpd.exe" -k install

    Write-Host "Installing MySQL service..."
    & "C:\xampp\mysql\bin\mysqld.exe" --install

    Write-Host "Setting Apache service to start automatically..."
    Set-Service -Name "Apache2.4" -StartupType Automatic

    Write-Host "Setting MySQL service to start automatically..."
    Set-Service -Name "mysql" -StartupType Automatic

    # ------------------- Configure Services to Run as 'aaron' -------------------
    Write-Host "`nConfiguring services to run under the 'aaron' user account with the hard-coded password."
    $plainPassword = "tt.r.2006"

    Write-Host "Configuring Apache service to run as ad\aaron..."
    sc.exe config "Apache2.4" obj= "ad\aaron" password= $plainPassword

    Write-Host "Configuring MySQL service to run as ad\aaron..."
    sc.exe config "mysql" obj= "ad\aaron" password= $plainPassword

    Write-Host "Starting Apache service..."
    Start-Service -Name "Apache2.4"

    Write-Host "Starting MySQL service..."
    Start-Service -Name "mysql"

    Write-Host "Apache and MySQL services have been installed, reconfigured to run as 'aaron', and started with automatic startup."
}

# ------------------- Step 6: Create MySQL Database 'login_system' -------------------
Confirm-ManualStep "Create a MySQL database named 'login_system':
a. Close and Reopen XAMPP Control Panel.
b. Click 'Admin' next to 'MySQL' in XAMPP Control Panel.
c. Click 'Databases' in the phpMyAdmin window.
d. Type 'login_system' in the text entry box and click 'Create'."

# ------------------- Step 7: Create the Users Table -------------------
Write-Host "`nStep 7: Create the Users table by running the following SQL query in phpMyAdmin:"
Write-Host "  CREATE TABLE users (" -ForegroundColor Cyan
Write-Host "      id INT AUTO_INCREMENT PRIMARY KEY," -ForegroundColor Cyan
Write-Host "      username VARCHAR(50) NOT NULL UNIQUE," -ForegroundColor Cyan
Write-Host "      password VARCHAR(255) NOT NULL" -ForegroundColor Cyan
Write-Host "  );" -ForegroundColor Cyan

Confirm-ManualStep "Instructions:
  a. Click 'Query'
  b. Paste the above query into the code editor
  c. Click 'Submit Query' to execute the query."

# ------------------- Step 8: Add a User to the Table -------------------
Write-Host "`nStep 8: Add a user to the table by running the following SQL query in phpMyAdmin:"
Write-Host "  INSERT INTO users (username, password)" -ForegroundColor Cyan
Write-Host "  VALUES ('mysql', MD5('MySQLPassword123'));" -ForegroundColor Cyan

Confirm-ManualStep "Instructions:
  a. Paste the above query into the code editor
  b. Click 'Submit Query' to execute the query."

# ------------------- Step 9: Update the Root User's Password -------------------
Write-Host "`nStep 9: Update the Root user's password by running the following SQL query in phpMyAdmin:"
Write-Host "  ALTER USER 'root'@'localhost' IDENTIFIED BY 'tt.r.2006';" -ForegroundColor Cyan

Confirm-ManualStep "Instructions:
  a. Paste the above query into the code editor
  b. Click 'Submit Query' to execute the query."

# ------------------- Step 10: Update the MySQL Configuration File -------------------
Confirm-ManualStep "Update the MySQL configuration file with the new password:
a. Open the file C:\xampp\phpMyAdmin\config.inc.php using the command: notepad C:\xampp\phpMyAdmin\config.inc.php
b. Add 'tt.r.2006' as the password in the configuration file (e.g., \$cfg['Servers'][\$i]['password'] = 'tt.r.2006';).
c. Save and close the file.
d. Click 'Query' to reload the page and confirm the SQL connection."

# ------------------- Step 11: Create index.php -------------------
$indexPhpContent = @'
<?php
// Database configuration
$dbHost = "localhost";
$dbUser = "root";
$dbPass = "tt.r.2006";
$dbName = "login_system";

// Create connection
$conn = new mysqli($dbHost, $dbUser, $dbPass, $dbName);

// Check connection
if ($conn->connect_error) {
    die("Connection failed: " . $conn->connect_error);
}

// Intentionally vulnerable code
if ($_SERVER["REQUEST_METHOD"] === "POST") {
    // Directly using user input in the query, no sanitization
    $username = $_POST["username"];
    $password = $_POST["password"];

    // This query remains vulnerable to SQL injection: "' OR '1'='1" etc.
    $sql = "SELECT * FROM users WHERE username='$username' AND password=MD5('$password')";

    // For debugging only, do not enable on a real server:
    // echo "<pre>Query: $sql</pre>";

    $result = $conn->query($sql);

    if ($result && $result->num_rows > 0) {
        echo "Login successful! Welcome, " . htmlspecialchars($username) . ".";
    } else {
        echo "Invalid username or password.";
    }
}

$conn->close();
?>
'@

Write-Host "Step 11: Creating index.php in C:\xampp\htdocs\index.php..."
Set-Content -Path "C:\xampp\htdocs\index.php" -Value $indexPhpContent -Encoding UTF8

# ------------------- Step 12: Create index.html -------------------
$indexHtmlContent = @'
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Vulnerable Login</title>
</head>
<body>
    <h2>Vulnerable Login</h2>
    <form action="index.php" method="POST">
        <label for="username">Username:</label>
        <input type="text" id="username" name="username" required><br><br>

        <label for="password">Password:</label>
        <input type="password" id="password" name="password" required><br><br>

        <button type="submit">Login</button>
    </form>
</body>
</html>
'@

Write-Host "Step 12: Creating index.html in C:\xampp\htdocs\index.html..."
Set-Content -Path "C:\xampp\htdocs\index.html" -Value $indexHtmlContent -Encoding UTF8

# ------------------- Step 13: Add Windows Defender Exclusion -------------------
try {
    Add-MpPreference -ExclusionPath "C:\xampp\htdocs" -ErrorAction Stop
    Write-Host "Step 13: Windows Defender Exclusion for C:\xampp\htdocs added."
}
catch {
    Write-Host "Unable to add Windows Defender Exclusion. Give Windows Security time to startup. Once it is started, run: Add-MpPreference -ExclusionPath 'C:\xampp\htdocs'" -ForegroundColor Yellow
}

# ------------------- Step 14: Setup Complete -------------------
Write-Host "Script completed successfully."
