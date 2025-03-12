#!/bin/bash
# Simple script to fix Cisco AnyConnect libxml2 issue on Ubuntu 24.10

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
echo "[1/5] Installing build dependencies..."
apt update
apt install -y build-essential git autoconf libtool pkg-config python3-dev \
    libicu-dev libreadline-dev liblzma-dev zlib1g-dev

# Step 2: Create a temporary working directory
echo "[2/5] Creating temporary directory..."
TEMP_DIR=$(mktemp -d)
cd "$TEMP_DIR"

# Step 3: Get the libxml2 source code and build it
echo "[3/5] Downloading and building libxml2 v2.11.5..."
git clone https://gitlab.gnome.org/GNOME/libxml2.git
cd libxml2/
git checkout v2.11.5
./autogen.sh
./configure
make

# Step 4: Create directory for AnyConnect and copy files
echo "[4/5] Creating libxml directory for AnyConnect..."
mkdir -p /opt/cisco/anyconnect/libxml
cp .libs/libxml2.so.2 /opt/cisco/anyconnect/libxml/
cp .libs/libxml2.so.2.11.5 /opt/cisco/anyconnect/libxml/

# Create a symbolic link to the XML parser interfaces
echo "Creating symbolic links for XML parser interfaces..."
mkdir -p /opt/cisco/anyconnect/libxml/include
cp -r include/libxml /opt/cisco/anyconnect/libxml/include/

# Step 5: Create simple wrapper scripts
echo "[5/5] Creating wrapper scripts..."

# Wrapper script for vpnagentd
cat > /usr/local/bin/run-vpnagentd.sh << 'EOF'
#!/bin/bash
# Simple wrapper script for vpnagentd with libxml2 fix

export LD_LIBRARY_PATH=/opt/cisco/anyconnect/libxml:$LD_LIBRARY_PATH
export LD_PRELOAD=/opt/cisco/anyconnect/libxml/libxml2.so.2

echo "Starting Cisco Secure Client VPN Agent..."
exec /opt/cisco/secureclient/bin/vpnagentd
EOF
chmod +x /usr/local/bin/run-vpnagentd.sh

# Wrapper script for vpnui
cat > /usr/local/bin/run-vpnui.sh << 'EOF'
#!/bin/bash
# Simple wrapper script for vpnui with libxml2 fix

export LD_LIBRARY_PATH=/opt/cisco/anyconnect/libxml:$LD_LIBRARY_PATH
export LD_PRELOAD=/opt/cisco/anyconnect/libxml/libxml2.so.2

echo "Starting Cisco Secure Client VPN UI..."
exec /opt/cisco/secureclient/bin/vpnui "$@"
EOF
chmod +x /usr/local/bin/run-vpnui.sh

# Update desktop file
if [ -f "/usr/share/applications/com.cisco.secureclient.gui.desktop" ]; then
    cp /usr/share/applications/com.cisco.secureclient.gui.desktop /usr/share/applications/com.cisco.secureclient.gui.desktop.bak
    sed -i 's|^Exec=.*|Exec=/usr/local/bin/run-vpnui.sh|' /usr/share/applications/com.cisco.secureclient.gui.desktop
else
    cat > /usr/share/applications/com.cisco.secureclient.gui.desktop << 'EOF'
[Desktop Entry]
Type=Application
Name=Cisco Secure Client
Comment=Cisco Secure Client
Icon=/opt/cisco/secureclient/pixmaps/vpnui.png
Exec=/usr/local/bin/run-vpnui.sh
Terminal=false
Categories=Network;
EOF
fi

# Cleanup
echo "Cleaning up temporary files..."
cd /
rm -rf "$TEMP_DIR"

echo "==============================================="
echo "  Fix installed successfully!"
echo "==============================================="
echo "Usage instructions:"
echo ""
echo "1. First, start the VPN agent in a terminal:"
echo "   $ sudo /usr/local/bin/run-vpnagentd.sh"
echo ""
echo "2. Then start the VPN UI from the application menu"
echo "   or run directly with:"
echo "   $ /usr/local/bin/run-vpnui.sh"
echo ""
echo "Note: Keep the terminal with vpnagentd running"
echo "while you use the VPN client."
echo "==============================================="
