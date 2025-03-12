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

# Create necessary customer experience feedback directory
echo "Creating CustomerExperienceFeedback directory..."
mkdir -p /opt/cisco/secureclient/CustomerExperienceFeedback
touch /opt/cisco/secureclient/CustomerExperienceFeedback/config
chmod -R 755 /opt/cisco/secureclient/CustomerExperienceFeedback
chown -R root:root /opt/cisco/secureclient/CustomerExperienceFeedback

# Create a custom launch script for vpnagentd
echo "[6/7] Creating startup scripts..."
cat > /usr/local/bin/vpnagentd-wrapper.sh << 'EOF'
#!/bin/bash
# Wrapper script for vpnagentd to ensure proper library loading

# Kill any existing vpnagentd processes
pkill -f vpnagentd 2>/dev/null || true

# Wait for processes to terminate
sleep 2

# Environment setup
export LD_LIBRARY_PATH=/opt/cisco/anyconnect/libxml:$LD_LIBRARY_PATH
export LD_PRELOAD=/opt/cisco/anyconnect/libxml/libxml2.so.2

# Start vpnagentd in the background
/opt/cisco/secureclient/bin/vpnagentd &

# Store the PID
echo $! > /run/vpnagentd.pid

# Wait for agent to initialize
sleep 3

echo "Cisco Secure Client VPN Agent started at $(date)"
EOF

chmod +x /usr/local/bin/vpnagentd-wrapper.sh

# Create an auto-restart monitor script
cat > /usr/local/bin/vpnagentd-monitor.sh << 'EOF'
#!/bin/bash
# Monitor script to ensure vpnagent stays running

LOG_FILE="/var/log/vpnagentd-monitor.log"

log() {
    echo "$(date): $1" | tee -a "$LOG_FILE"
}

restart_vpnagent() {
    log "Restarting VPN agent..."
    
    # Kill any existing vpndownloader processes
    pkill -f vpndownloader 2>/dev/null || true
    sleep 1
    
    # Start the wrapper
    /usr/local/bin/vpnagentd-wrapper.sh
    
    log "VPN agent restarted"
}

# Initial startup
log "Starting VPN agent monitor"
restart_vpnagent

# Main monitoring loop
while true; do
    # Check if vpnagentd is running
    if ! pgrep -f "vpnagentd" > /dev/null; then
        log "VPN Agent process not found, restarting..."
        restart_vpnagent
    fi
    
    # Sleep for 30 seconds between checks
    sleep 30
done
EOF

chmod +x /usr/local/bin/vpnagentd-monitor.sh

# Disable systemd service if it exists
if [ -f "/etc/systemd/system/vpnagentd.service" ]; then
    echo "Disabling systemd service for vpnagentd..."
    systemctl stop vpnagentd.service 2>/dev/null || true
    systemctl disable vpnagentd.service 2>/dev/null || true
fi

# Create a startup script for VPN UI
echo "Creating custom launch script for vpnui..."
cat > /usr/local/bin/vpnui-wrapper.sh << 'EOF'
#!/bin/bash
# Wrapper script for vpnui to ensure proper library loading

export LD_LIBRARY_PATH=/opt/cisco/anyconnect/libxml:$LD_LIBRARY_PATH
export LD_PRELOAD=/opt/cisco/anyconnect/libxml/libxml2.so.2

# Check if vpnagentd is running, start it if not
if ! pgrep -f "vpnagentd" > /dev/null; then
    echo "VPN Agent is not running, starting it..."
    sudo /usr/local/bin/vpnagentd-wrapper.sh
    sleep 2
fi

# Start the UI
exec /opt/cisco/secureclient/bin/vpnui "$@"
EOF

chmod +x /usr/local/bin/vpnui-wrapper.sh

# Step 7: Configure autostart and desktop files
echo "[7/7] Configuring desktop files and autostart..."

# Create Desktop entry
if [ -f "/usr/share/applications/com.cisco.secureclient.gui.desktop" ]; then
    cp /usr/share/applications/com.cisco.secureclient.gui.desktop /usr/share/applications/com.cisco.secureclient.gui.desktop.bak
    # Update existing desktop file
    sed -i 's|^Exec=.*|Exec=/usr/local/bin/vpnui-wrapper.sh|' /usr/share/applications/com.cisco.secureclient.gui.desktop
else
    # Create new desktop file if it doesn't exist
    cat > /usr/share/applications/com.cisco.secureclient.gui.desktop << 'EOF'
[Desktop Entry]
Type=Application
Name=Cisco Secure Client
Comment=Cisco Secure Client
Icon=/opt/cisco/secureclient/pixmaps/vpnui.png
Exec=/usr/local/bin/vpnui-wrapper.sh
Terminal=false
Categories=Network;
EOF
fi

# Create autostart entry for the monitor script
mkdir -p /etc/xdg/autostart
cat > /etc/xdg/autostart/cisco-vpn-monitor.desktop << 'EOF'
[Desktop Entry]
Type=Application
Name=Cisco VPN Monitor
Comment=Keeps Cisco VPN Agent running
Exec=sudo /usr/local/bin/vpnagentd-monitor.sh
Terminal=false
Hidden=false
X-GNOME-Autostart-enabled=true
EOF

# Add sudoers entry to allow running the monitor without password
cat > /etc/sudoers.d/cisco-vpn << 'EOF'
# Allow users to start/stop VPN agent without password
%sudo ALL=(ALL) NOPASSWD: /usr/local/bin/vpnagentd-wrapper.sh
%sudo ALL=(ALL) NOPASSWD: /usr/local/bin/vpnagentd-monitor.sh
EOF
chmod 440 /etc/sudoers.d/cisco-vpn

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

# Start the VPN agent
echo "Starting Cisco VPN Agent..."
/usr/local/bin/vpnagentd-wrapper.sh

# Start the monitor process in the background
echo "Starting VPN Agent monitor in the background..."
nohup /usr/local/bin/vpnagentd-monitor.sh > /var/log/vpnagentd-monitor.log 2>&1 &

# Cleanup
echo "Cleaning up temporary files..."
cd /
rm -rf "$TEMP_DIR"

echo "==============================================="
echo "  Fix installed successfully!"
echo "==============================================="
echo "The Cisco VPN Agent is now running as a standalone process"
echo "and will automatically restart if it crashes."
echo ""
echo "You can start the Cisco Secure Client using:"
echo "1. The application menu"
echo "2. Terminal command: /usr/local/bin/vpnui-wrapper.sh"
echo ""
echo "The agent monitor is running in the background and"
echo "will restart automatically if needed."
echo ""
echo "Monitor logs are written to: /var/log/vpnagentd-monitor.log"
echo "==============================================="
