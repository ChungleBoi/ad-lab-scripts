# Define the SSMS install path to check
$ssmsPath = "C:\Program Files (x86)\Microsoft SQL Server Management Studio 20\Common7\IDE\Ssms.exe"

if (Test-Path $ssmsPath) {
    Write-Host "SSMS is already installed. Skipping steps 5-8."
    Write-Host "Proceeding to steps 9-12 (SQL Operations)..." -ForegroundColor Cyan

    # Steps 9-12: SQL Operations (wrapped in try/catch)
    try {
        $sqlCommands = @"
USE master;
CREATE TABLE dbo.Users
(
    ID INT IDENTITY(1,1) PRIMARY KEY,
    Username VARCHAR(50) NOT NULL,
    Password VARCHAR(50) NOT NULL
);
INSERT INTO dbo.Users (Username, Password)
VALUES ('sa', 'Password123');
SELECT * FROM master.information_schema.tables WHERE table_name = 'Users';
"@

        # Write the SQL commands to a temporary file
        $sqlPath = Join-Path $env:TEMP "setup.sql"
        $sqlCommands | Out-File $sqlPath -Encoding ASCII

        # Attempt to invoke the commands against the instance "WEB02"
        Invoke-Sqlcmd -InputFile $sqlPath -ServerInstance "WEB02" -ErrorAction Stop

        Write-Host "SQL operations (steps 9-12) completed successfully."
    }
    catch {
        Write-Error "Error encountered while executing SQL commands. Exiting script."
        Exit
    }
}
else {
    # Step 5: Download MS SQL Server 2022 - Developer Edition
    Write-Host "Download 'SQL Server 2022 - Developer' from:`nhttps://www.microsoft.com/en-us/sql-server/sql-server-downloads" -ForegroundColor Cyan
    Read-Host "Press 'Y' once download is complete"

    # Step 6: Install MS SQL Server 2022 - Developer Edition
    Write-Host (@"
Manually perform the following:
a. Double-click the installation file in the "Downloads" folder
b. Select "Custom" as Installation Type and click "Install"
c. Click "Installation" -> "New SQL Server standalone installation"
d. Click "Next", accept the license terms, and click "Next"
e. Click "Next" until "Feature Selection"; select "Database Engine Services"
f. Click "Next" until "Server Configuration"
g. Set "Startup Type" to "Automatic" for "SQL Server Agent", "SQL Server Database Engine", and "SQL Server Browser", then click "Next"
h. On "Database Engine Configuration":
   - Select "Mixed Mode"
   - Set the SQL Administrator account password to "Password123"
   - Under "Specify SQL Server administrators" click "Add Current User" to add iis_service.
   - Click "Next" and "Install" to finish.
"@) -ForegroundColor Cyan
    Read-Host "Press 'Y' once completed"

    # Step 7: Start SQL Server services
    Set-Service 'MSSQLSERVER' -StartupType Automatic
    Set-Service 'SQLSERVERAGENT' -StartupType Automatic
    Start-Service 'MSSQLSERVER'
    Start-Service 'SQLSERVERAGENT'

    # Step 8: Install SSMS
    Write-Host "Download and install SSMS from:`nhttps://learn.microsoft.com/en-us/sql/ssms/download-sql-server-management-studio-ssms?view=sql-server-ver16" -ForegroundColor Cyan
    Write-Host "Press Restart once the SSMS installation is complete (the SSMS installer typically offers a Restart button)."
    # Immediately exit so the user can restart without continuing further steps
    return
}

# Steps 13–18 run only if we have successfully completed (or skipped) steps 9–12.

# Step 13: Enable IIS Management Console, ASP, Windows Authentication
Write-Host (@"
a. Open 'Run', type 'optionalfeatures'
b. Enable:
  - Internet Information Services -> Web Management Tools -> IIS Management Console
  - Internet Information Services -> World Wide Web Services -> Application Development Features -> ASP
  - Internet Information Services -> World Wide Web Services -> Security -> Windows Authentication
Click 'OK' to apply changes.
"@) -ForegroundColor Cyan
Read-Host "Press 'Y' once completed"

# Step 14: Defender exclusion
Add-MpPreference -ExclusionPath "C:\Users\Public"

# Step 15: Create login.asp within script
# We define the ASP variables at the top so they won't be 'undefined'
$loginAspContent = @"
<%
Option Explicit

' ============================
'  Declare Connection Variables
' ============================
Dim dbServer, dbPassword
dbServer = "web02"
dbPassword = "Password123"

' ============================
'  Step 1: Grab User Input
' ============================
Dim username, password
username = Request.Form("username")
password = Request.Form("password")

' ============================
'  Step 2: Build (Insecure) SQL Query
' ============================
' WARNING: This is deliberately vulnerable to SQL injection.
Dim sqlQuery
sqlQuery = "SELECT * FROM dbo.Users WHERE username = '" & username & _
           "' AND password = '" & password & "'"

' ============================
'  Step 3: Create ADO Objects
' ============================
Dim conn, rs
Set conn = Server.CreateObject("ADODB.Connection")
Set rs   = Server.CreateObject("ADODB.Recordset")

' ============================
'  Step 4: Connect to SQL Server
' ============================
On Error Resume Next
conn.Open "Provider=SQLOLEDB;Data Source=" & dbServer & ";Initial Catalog=master;User ID=sa;Password=" & dbPassword & ";"

If Err.Number <> 0 Then
    Response.Write "<h3>Connection Error: " & Err.Description & "</h3>"
    Response.End
End If
On Error GoTo 0

' ============================
'  Step 5: Execute the Query
' ============================
Dim loginAttempted
loginAttempted = False

If username <> "" Or password <> "" Then
    loginAttempted = True
    On Error Resume Next
    Set rs = conn.Execute(sqlQuery)
    If Err.Number <> 0 Then
        Response.Write "<h3>Query Error: " & Err.Description & "</h3>"
        conn.Close
        Set conn = Nothing
        Response.End
    End If
    On Error GoTo 0
End If

' ============================
'  Step 6: Check for Results
' ============================
If loginAttempted Then
    If Not rs.EOF Then
        Response.Write "<h3>Login success!</h3>"
    Else
        Response.Write "<h3>Login failed.</h3>"
    End If
End If

' ============================
'  Step 7: Clean up
' ============================
If loginAttempted Then
    rs.Close
    conn.Close
    Set rs = Nothing
    Set conn = Nothing
End If
%>

<html>
<head>
  <title>Very Insecure Login Form</title>
</head>
<body>
  <h1>Very Insecure Login Form</h1>
  <form method="POST" action="login.asp">
    Username: <input type="text" name="username"><br/>
    Password: <input type="password" name="password"><br/>
    <input type="submit" value="Login">
  </form>
</body>
</html>
"@

# Define the output path
$outputPath = "C:\inetpub\wwwroot\login.asp"
Set-Content -Path $outputPath -Value $loginAspContent -Force
Write-Host "login.asp has been created at $outputPath"

# Step 16: Open Port 80
New-NetFirewallRule -DisplayName "Open Port 80" -Direction Inbound -Protocol TCP -LocalPort 80 -Action Allow

# Step 17: Set IIS Default Application Pool Identity
Write-Host (@"
Open IIS Manager:
a. Expand "WEB02 (AD\iis_service)", click "Application Pools"
b. Right-click "DefaultAppPool", choose "Advanced Settings"
c. Under "Process Model", click the three dots next to "Identity"
d. Select "Custom account", click "Set", enter "ad\iis_service" and password "daisy_3", then click "OK" twice.
"@) -ForegroundColor Cyan
Read-Host "Press 'Y' once completed"

# Step 18: Configure Windows Authentication Method
Write-Host (@"
In IIS Manager:
a. Click "Sites" -> "Default Web Site" -> "Authentication"
b. Disable "Anonymous Authentication"
c. Enable "Windows Authentication"
d. Right-click "Windows Authentication" -> "Providers"
   - Remove "Negotiate" and "NTLM"
   - Add "Negotiate:Kerberos" and click "OK"
e. Right-click "Windows Authentication" -> "Advanced Settings"
   - Disable "Enable Kernel-mode authentication"
Click "OK" to save settings.
"@) -ForegroundColor Cyan
Read-Host "Press 'Y' once completed"
