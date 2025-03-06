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
   - Select "Mixed Mode", set a Password.
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
Write-Host "Download and install SSMS from:`nhttps://learn.microsoft.com/en-us/sql/ssms/download-sql-server-management-studio-ssms?view=sql-server-ver16`nRestart your system after installation." -ForegroundColor Cyan
Read-Host "Press 'Y' once completed"

# Step 9-12: SQL Operations
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
$sqlCommands | Out-File "$env:TEMP\setup.sql" -Encoding ASCII
Invoke-Sqlcmd -InputFile "$env:TEMP\setup.sql" -ServerInstance "WEB02"

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
$serverName = Read-Host "Enter the server name (e.g., web02)"
$saPassword = Read-Host "Enter the SA password" -AsSecureString
$plainSaPassword = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($saPassword))

$loginAspContent = @"
<%
Option Explicit

Dim username, password
username = Request.Form("username")
password = Request.Form("password")

Dim sqlQuery
sqlQuery = "SELECT * FROM dbo.Users WHERE username = '" & username & "' AND password = '" & password & "'"

Dim conn, rs
Set conn = Server.CreateObject("ADODB.Connection")
Set rs   = Server.CreateObject("ADODB.Recordset")

On Error Resume Next
conn.Open "Provider=SQLOLEDB;Data Source=$serverName;Initial Catalog=master;User ID=sa;Password=$plainSaPassword;"

If Err.Number <> 0 Then
    Response.Write "<h3>Connection Error: " & Err.Description & "</h3>"
    Response.End
End If
On Error GoTo 0

If username <> "" Or password <> "" Then
    Set rs = conn.Execute(sqlQuery)
    If Not rs.EOF Then
        Response.Write "<h3>Login success!</h3>"
    Else
        Response.Write "<h3>Login failed.</h3>"
    End If
    rs.Close
End If
conn.Close
Set rs = Nothing
Set conn = Nothing
%>

<html>
<body>
  <form method="POST" action="login.asp">
    Username: <input type="text" name="username"><br/>
    Password: <input type="password" name="password"><br/>
    <input type="submit" value="Login">
  </form>
</body>
</html>
"@
Set-Content -Path "C:\inetpub\wwwroot\login.asp" -Value $loginAspContent -Force
Write-Host "login.asp created at C:\inetpub\wwwroot\login.asp"

# Step 16: Open Port 80
New-NetFirewallRule -DisplayName "Open Port 80" -Direction Inbound -Protocol TCP -LocalPort 80 -Action Allow

# Step 17: Set IIS Default Application Pool Identity
Write-Host (@"
In IIS Manager:
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
   - Add "Negotiate:Kerberos"
e. Right-click "Windows Authentication" -> "Advanced Settings"
   - Disable "Enable Kernel-mode authentication"
Click "OK" to save settings.
"@) -ForegroundColor Cyan
Read-Host "Press 'Y' once completed"
