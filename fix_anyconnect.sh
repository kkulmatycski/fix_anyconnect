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

# Create a symbolic link to the XML parser interfaces
echo "Creating symbolic links for XML parser interfaces..."
mkdir -p /opt/cisco/anyconnect/libxml/include
cp -r include/libxml /opt/cisco/anyconnect/libxml/include/

# Create necessary CustomerExperienceFeedback directory
echo "Creating CustomerExperienceFeedback directory..."
mkdir -p /opt/cisco/secureclient/CustomerExperienceFeedback
touch /opt/cisco/secureclient/CustomerExperienceFeedback/config
chmod -R 755 /opt/cisco/secureclient/CustomerExperienceFeedback
chown -R root:root /opt/cisco/secureclient/CustomerExperienceFeedback

# Create a custom launch script for vpnagentd
echo "Creating custom launch script for vpnagentd..."
cat > /opt/cisco/secureclient/bin/vpnagentd-wrapper.sh << 'EOF'
#!/bin/bash
# Wrapper script for vpnagentd to ensure proper library loading
export LD_LIBRARY_PATH=/opt/cisco/anyconnect/libxml:$LD_LIBRARY_PATH
export LD_PRELOAD=/opt/cisco/anyconnect/libxml/libxml2.so.2
exec /opt/cisco/secureclient/bin/vpnagentd "$@"
EOF

chmod +x /opt/cisco/secureclient/bin/vpnagentd-wrapper.sh

# Step 6: Configure the VPN daemon service
echo "[6/7] Configuring VPN daemon service..."
cat > /etc/systemd/system/vpnagentd.service << 'EOF'
[Unit]
Description=Cisco Secure Client VPN Agent
Requires=NetworkManager.service
After=NetworkManager.service

[Service]
Type=forking
ExecStart=/opt/cisco/secureclient/bin/vpnagentd-wrapper.sh -execv_instance
ExecStop=/opt/cisco/secureclient/bin/vpn disconnect
PIDFile=/run/vpnagentd.pid
KillMode=process
TimeoutStartSec=300
TimeoutStopSec=60
Restart=on-failure
RestartSec=10s

[Install]
WantedBy=multi-user.target
EOF

# Create watchdog script
echo "[6.1/7] Creating VPN agent watchdog service..."
cat > /usr/local/bin/vpnagentd-watchdog.sh << 'EOF'
#!/bin/bash
# Watchdog script for Cisco Secure Client VPN Agent
# This script monitors the vpnagentd service and restarts it if it dies

LOG_FILE="/var/log/vpnagentd-watchdog.log"

log() {
    echo "$(date): $1" >> "$LOG_FILE"
}

# Wait for any existing vpndownloader process to complete
wait_for_downloader() {
    log "Checking for vpndownloader processes..."
    for i in {1..30}; do
        if ! pgrep -f "vpndownloader" > /dev/null; then
            log "No vpndownloader processes running."
            return 0
        fi
        log "Waiting for vpndownloader to finish (attempt $i/30)..."
        sleep 1
    done
    
    # If still running after timeout, kill it
    log "Timeout waiting for vpndownloader, killing processes..."
    pkill -f "vpndownloader"
    sleep 2
    return 0
}

restart_service() {
    log "Restarting vpnagentd service..."
    wait_for_downloader
    systemctl restart vpnagentd.service
    
    if [ $? -eq 0 ]; then
        log "Successfully restarted vpnagentd service."
    else
        log "Failed to restart vpnagentd service."
    fi
}

log "Starting VPN Agent watchdog service"

while true; do
    # Check if vpnagentd is running
    if ! systemctl is-active --quiet vpnagentd.service; then
        log "VPN Agent service is not running."
        restart_service
    fi
    
    # Check for XML parsing errors in the logs
    if journalctl -u vpnagentd.service --since "1 minute ago" | grep -q "xmlCreateFileParserCtxt"; then
        log "Detected XML parsing error, restarting service."
        restart_service
    fi
    
    # Sleep for 30 seconds before checking again
    sleep 30
done
EOF

chmod +x /usr/local/bin/vpnagentd-watchdog.sh

# Create watchdog service
cat > /etc/systemd/system/vpnagentd-watchdog.service << 'EOF'
[Unit]
Description=Watchdog for Cisco Secure Client VPN Agent
After=vpnagentd.service

[Service]
Type=simple
ExecStart=/usr/local/bin/vpnagentd-watchdog.sh
Restart=always
RestartSec=10s

[Install]
WantedBy=multi-user.target
EOF

# Enable watchdog service
systemctl enable vpnagentd-watchdog.service

# Step 7: Create desktop file for GNOME
echo "[7/7] Configuring desktop files..."

# Create a custom launch script for vpnui
echo "Creating custom launch script for vpnui..."
cat > /opt/cisco/secureclient/bin/vpnui-wrapper.sh << 'EOF'
#!/bin/bash
# Wrapper script for vpnui to ensure proper library loading
export LD_LIBRARY_PATH=/opt/cisco/anyconnect/libxml:$LD_LIBRARY_PATH
export LD_PRELOAD=/opt/cisco/anyconnect/libxml/libxml2.so.2
exec /opt/cisco/secureclient/bin/vpnui "$@"
EOF

chmod +x /opt/cisco/secureclient/bin/vpnui-wrapper.sh

# Update desktop file for GNOME
if [ -f "/usr/share/applications/com.cisco.secureclient.gui.desktop" ]; then
    cp /usr/share/applications/com.cisco.secureclient.gui.desktop /usr/share/applications/com.cisco.secureclient.gui.desktop.bak
    # Update existing desktop file
    sed -i 's|^Exec=.*|Exec=/opt/cisco/secureclient/bin/vpnui-wrapper.sh|' /usr/share/applications/com.cisco.secureclient.gui.desktop
else
    # Create new desktop file if it doesn't exist
    cat > /usr/share/applications/com.cisco.secureclient.gui.desktop << 'EOF'
[Desktop Entry]
Type=Application
Name=Cisco Secure Client
Comment=Cisco Secure Client
Icon=/opt/cisco/secureclient/pixmaps/vpnui.png
Exec=/opt/cisco/secureclient/bin/vpnui-wrapper.sh
Terminal=false
Categories=Network;
EOF
fi

# Optional KDE desktop file (create in user's home, needs to be run for each user)
if [ -d "$HOME/.local/share/applications" ]; then
    if [ -f "$HOME/.local/share/applications/com.cisco.anyconnect.gui.desktop" ]; then
        cp "$HOME/.local/share/applications/com.cisco.anyconnect.gui.desktop" "$HOME/.local/share/applications/com.cisco.anyconnect.gui.desktop.bak"
        sed -i 's|^Exec=.*|Exec=/opt/cisco/secureclient/bin/vpnui-wrapper.sh|' "$HOME/.local/share/applications/com.cisco.anyconnect.gui.desktop"
    fi
fi

# Disable Auto Update in AnyConnect's local policy
echo "Disabling Auto Update in AnyConnect's local policy..."
if [ -f "/opt/cisco/secureclient/vpn/AnyConnectLocalPolicy.xml" ]; then
    # Back up the original file
    cp /opt/cisco/secureclient/vpn/AnyConnectLocalPolicy.xml /opt/cisco/secureclient/vpn/AnyConnectLocalPolicy.xml.bak
    
    # Check if AutoUpdate tag exists and update it
    if grep -q "<AutoUpdate>" /opt/cisco/secureclient/vpn/AnyConnectLocalPolicy.xml; then
        sed -i 's|<AutoUpdate>true</AutoUpdate>|<AutoUpdate>false</AutoUpdate>|g' /opt/cisco/secureclient/vpn/AnyConnectLocalPolicy.xml
    else
        # If AutoUpdate tag doesn't exist, add it under ClientInitialization
        if grep -q "</ClientInitialization>" /opt/cisco/secureclient/vpn/AnyConnectLocalPolicy.xml; then
            sed -i 's|</ClientInitialization>|  <AutoUpdate>false</AutoUpdate>\n</ClientInitialization>|g' /opt/cisco/secureclient/vpn/AnyConnectLocalPolicy.xml
        else
            echo "Could not find ClientInitialization tag in policy file. Manual update of AutoUpdate setting required."
        fi
    fi
fi

# Reload systemd and restart vpnagentd
echo "Reloading systemd and starting vpnagentd service..."
systemctl daemon-reload
systemctl stop vpnagentd.service
pkill -f vpndownloader 2>/dev/null || true
sleep 2
systemctl start vpnagentd.service

# Start the watchdog service in the background
echo "Starting vpnagentd-watchdog service in the background..."
systemctl start vpnagentd-watchdog.service &

# Wait a moment to ensure service starts properly
sleep 2

# Verify the watchdog service status without hanging
echo "Checking service status (non-blocking)..."
systemctl is-active --quiet vpnagentd-watchdog.service && echo "Watchdog service started successfully" || echo "Watchdog service may have failed to start - check logs for details"

# Cleanup
echo "Cleaning up temporary files..."
cd /
rm -rf "$TEMP_DIR"

echo "==============================================="
echo "  Fix installed successfully!"
echo "==============================================="
echo "You can now launch Cisco AnyConnect using:"
echo "1. The application menu"
echo "2. Terminal command: /opt/cisco/secureclient/bin/vpnui-wrapper.sh"
echo "3. Verify the service is running: systemctl status vpnagentd.service"
echo ""
echo "A watchdog service has been installed to automatically restart"
echo "the VPN agent if it crashes. You can check its status with:"
echo "systemctl status vpnagentd-watchdog.service"
echo ""
echo "Logs from the watchdog will be written to /var/log/vpnagentd-watchdog.log"
echo "==============================================="
