#!/bin/bash
# Script to implement Cisco AnyConnect libxml2 fix on Ubuntu 24.10
# This script must be run with sudo privileges

set -e  # Exit immediately if a command exits with a non-zero status

# Display banner
echo "==============================================="
echo "  Cisco AnyConnect libxml2 Fix for Ubuntu 24.10"
echo "==============================================="

# Check if script is running with sudo
if [ "$EUID" -ne 0 ]; then
  echo "Please run this script with sudo privileges."
  exit 1
fi

# Step 1: Install build dependencies
echo "[1/7] Installing build dependencies..."
apt update
apt install -y build-essential git autoconf libtool pkg-config python3-dev \
    libicu-dev libreadline-dev liblzma-dev zlib1g-dev

# Step 2: Create a temporary working directory
echo "[2/7] Creating temporary directory..."
TEMP_DIR=$(mktemp -d)
cd "$TEMP_DIR"

# Step 3: Get the libxml2 source code and build it
echo "[3/7] Downloading and building libxml2 v2.11.5..."
git clone https://gitlab.gnome.org/GNOME/libxml2.git
cd libxml2/
git checkout v2.11.5
./autogen.sh
./configure
make

# Step 4: Create directory for AnyConnect
echo "[4/7] Creating libxml directory for AnyConnect..."
mkdir -p /opt/cisco/anyconnect/libxml

# Step 5: Copy the library files
echo "[5/7] Copying libxml2 library files..."
cp .libs/libxml2.so.2 /opt/cisco/anyconnect/libxml/
cp .libs/libxml2.so.2.11.5 /opt/cisco/anyconnect/libxml/

# Step 6: Configure the VPN daemon service
echo "[6/7] Configuring VPN daemon service..."
cat > /etc/systemd/system/vpnagentd.service << 'EOF'
[Unit]
Description=Cisco AnyConnect Secure Mobility Agent for Linux
Requires=NetworkManager.service
After=NetworkManager.service

[Service]
Type=forking
ExecStart=env 'LD_LIBRARY_PATH=/opt/cisco/anyconnect/libxml:$LD_LIBRARY_PATH' /opt/cisco/secureclient/bin/vpnagentd -execv_instance
ExecStop=/opt/cisco/secureclient/bin/vpn disconnect
PIDFile=/var/run/vpnagentd.pid
KillMode=process

[Install]
WantedBy=multi-user.target
EOF

# Step 7: Create desktop file for GNOME
echo "[7/7] Configuring desktop files..."

# Create backup of original desktop file if it exists
if [ -f "/usr/share/applications/com.cisco.secureclient.gui.desktop" ]; then
    cp /usr/share/applications/com.cisco.secureclient.gui.desktop /usr/share/applications/com.cisco.secureclient.gui.desktop.bak
    # Update existing desktop file
    sed -i 's|^Exec=.*|Exec=env '\''LD_LIBRARY_PATH=/opt/cisco/anyconnect/libxml:$LD_LIBRARY_PATH'\'' /opt/cisco/secureclient/bin/vpnui|' /usr/share/applications/com.cisco.secureclient.gui.desktop
else
    # Create new desktop file if it doesn't exist
    cat > /usr/share/applications/com.cisco.secureclient.gui.desktop << 'EOF'
[Desktop Entry]
Type=Application
Name=Cisco Secure Client
Comment=Cisco Secure Client
Icon=/opt/cisco/secureclient/pixmaps/vpnui.png
Exec=env 'LD_LIBRARY_PATH=/opt/cisco/anyconnect/libxml:$LD_LIBRARY_PATH' /opt/cisco/secureclient/bin/vpnui
Terminal=false
Categories=Network;
EOF
fi

# Optional KDE desktop file (create in user's home, needs to be run for each user)
if [ -d "$HOME/.local/share/applications" ]; then
    if [ -f "$HOME/.local/share/applications/com.cisco.anyconnect.gui.desktop" ]; then
        cp "$HOME/.local/share/applications/com.cisco.anyconnect.gui.desktop" "$HOME/.local/share/applications/com.cisco.anyconnect.gui.desktop.bak"
        sed -i 's|^Exec=.*|Exec=env '\''LD_LIBRARY_PATH=/opt/cisco/anyconnect/libxml:$LD_LIBRARY_PATH'\'' /opt/cisco/secureclient/bin/vpnui|' "$HOME/.local/share/applications/com.cisco.anyconnect.gui.desktop"
    fi
fi

# Reload systemd and restart vpnagentd
echo "Reloading systemd and restarting vpnagentd service..."
systemctl daemon-reload
systemctl restart vpnagentd.service

# Cleanup
echo "Cleaning up temporary files..."
cd /
rm -rf "$TEMP_DIR"

echo "==============================================="
echo "  Fix installed successfully!"
echo "==============================================="
echo "You can now launch Cisco AnyConnect using:"
echo "1. The application menu"
echo "2. Terminal command: env 'LD_LIBRARY_PATH=/opt/cisco/anyconnect/libxml:\$LD_LIBRARY_PATH' /opt/cisco/secureclient/bin/vpnui"
echo "3. Verify the service is running: systemctl status vpnagentd.service"
echo "==============================================="
