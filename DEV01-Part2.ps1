# Step 1: Instruct the user to complete the manual Python installation steps
Write-Host "Before proceeding, please complete the following manual steps:"
Write-Host "1. Download Python from: https://www.python.org/downloads/ by clicking 'Download Python 3.13.2'."
Write-Host "2. Double-click the installer."
Write-Host "3. Click 'Add python.exe to PATH' and click 'Install Now.'"
Write-Host "4. Once the installation is complete, close the PowerShell window, and reopen a new Non-Elevated PowerShell session."

# Immediately check if Python is properly installed by verifying its version string.
try {
    $pythonVersionOutput = & python --version 2>&1
    # Use a regex that matches a proper version string like "Python 3.13.2"
    if ($pythonVersionOutput -notmatch "^Python\s+\d+\.\d+\.\d+") {
        exit
    }
} catch {
    exit
}

# Step 2: Automatically install aiosmtpd via pip
Write-Host "Installing aiosmtpd via pip..."
python -m pip install aiosmtpd

# Step 3: Prompt the user for the listening IP
$ip = Read-Host "Enter your listening IP (e.g. 10.10.14.100)"

# Step 4: Define the Python SMTP server script as a multiline string
$pythonScript = @'
import asyncio
import os
import subprocess
from aiosmtpd.controller import Controller
from email.parser import BytesParser
from email.policy import default

class CustomSMTPHandler:
    async def handle_DATA(self, server, session, envelope):
        print(f"Connection from: {session.peer}")
        print(f"Message from: {envelope.mail_from}")
        print(f"Message to: {envelope.rcpt_tos}")
        print("Message content:")

        try:
            # Parse the message
            msg = BytesParser(policy=default).parsebytes(envelope.content)

            # Walk through each MIME part
            for part in msg.walk():
                # Skip if not an attachment
                if part.get_content_disposition() != 'attachment':
                    continue

                filename = part.get_filename()
                if not filename:
                    continue

                file_data = part.get_payload(decode=True)
                with open(filename, 'wb') as f:
                    f.write(file_data)

                print(f"[+] Attachment saved to disk: {filename}")

                # If it's a .lnk file, execute it automatically
                if filename.lower().endswith('.lnk'):
                    print(f"[!] Executing shortcut: {filename}")
                    try:
                        os.startfile(filename)
                    except Exception as ex:
                        print(f"Error executing {filename}: {ex}")

            print("End of message")
        except Exception as e:
            print(f"Error parsing email: {e}")

        return '250 Message accepted for delivery'


if __name__ == "__main__":
    handler = CustomSMTPHandler()

    try:
        controller_local = Controller(handler, hostname='127.0.0.1', port=25)
        controller_local.start()
        print("SMTP server is running on localhost (127.0.0.1) on port 25...")
    except Exception as e:
        print(f"Failed to bind to localhost: {e}")

    try:
        controller_external = Controller(handler, hostname='EXTERNAL_IP_PLACEHOLDER', port=25)
        controller_external.start()
        print("SMTP server is running on external IP (EXTERNAL_IP_PLACEHOLDER) on port 25...")
    except Exception as e:
        print(f"Failed to bind to external IP: {e}")

    try:
        asyncio.run(asyncio.Event().wait())
    except KeyboardInterrupt:
        print("Shutting down...")
        if 'controller_local' in globals():
            controller_local.stop()
        if 'controller_external' in globals():
            controller_external.stop()
'@

# Step 5: Replace the placeholder with the actual IP provided by the user
$pythonScript = $pythonScript -replace 'EXTERNAL_IP_PLACEHOLDER', $ip

# Step 6: Create the receiver.py file with the updated Python script
Set-Content -Path "receiver.py" -Value $pythonScript

Write-Host "receiver.py created successfully with external IP set to $ip."

# Step 7: Setup Complete
Write-Host "Script completed successfully."
